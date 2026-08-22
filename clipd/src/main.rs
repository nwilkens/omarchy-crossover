mod clip;
mod config;
mod proto;
mod tls;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use config::Config;
use proto::Payload;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Semaphore};
use tokio::time::{timeout, Duration};
use tokio_rustls::{TlsAcceptor, TlsConnector};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(20);
/// An inbound slot is held from accept() onward, so an unauthenticated peer
/// that opens sockets and never speaks would otherwise hold one for the full
/// exchange budget. The handshake gets its own, much shorter deadline.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
/// Caps concurrent inbound sessions so a peer, or anything that reached the
/// port, cannot exhaust file descriptors by opening connections it never uses.
const MAX_INFLIGHT: usize = 8;

#[derive(Parser, Debug)]
#[command(
    name = "crossover-clipd",
    version,
    about = "Encrypted clipboard sync for Omarchy Crossover"
)]
struct Cli {
    /// A lan-mouse config to import peer addresses from.
    #[arg(long, global = true)]
    peer_config: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Run the sync daemon (default).
    Run,
    /// Print this machine's certificate fingerprint.
    Fingerprint,
    /// Trust a peer's fingerprint.
    Pair { fingerprint: String },
    /// Stop trusting a fingerprint.
    Revoke { fingerprint: String },
    /// Add a peer address to push the clipboard to.
    AddPeer { host: String },
    /// Show configuration and trust state.
    Status,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("failed to install the ring crypto provider"))?;

    let cli = Cli::parse();
    let dir = config::config_dir()?;
    tls::ensure_dir(&dir)?;

    let mut cfg = Config::load(&dir)?;
    let identity = tls::Identity::load_or_create(&dir)?;

    match cli.command.unwrap_or(Command::Run) {
        Command::Fingerprint => {
            println!("{}", identity.fingerprint());
            Ok(())
        }
        Command::Pair { fingerprint } => {
            if !tls::is_valid_fingerprint(&fingerprint) {
                bail!("not a sha256 fingerprint: {fingerprint}");
            }
            if cfg.trust(&fingerprint) {
                cfg.save(&dir)?;
                println!("paired {fingerprint}");
            } else {
                println!("already paired");
            }
            Ok(())
        }
        Command::Revoke { fingerprint } => {
            if cfg.revoke(&fingerprint) {
                cfg.save(&dir)?;
                println!("revoked {fingerprint}");
            } else {
                println!("not paired");
            }
            Ok(())
        }
        Command::AddPeer { host } => {
            if cfg.add_peer(&host) {
                cfg.save(&dir)?;
                println!("added peer {host}");
            } else {
                println!("peer already present");
            }
            Ok(())
        }
        Command::Status => {
            println!("fingerprint : {}", identity.fingerprint());
            println!("listen      : {}:{}", cfg.bind, cfg.port);
            println!("peers       : {}", cfg.peers.join(", "));
            println!("paired      : {}", cfg.authorized.len());
            Ok(())
        }
        Command::Run => run(cfg, identity, dir, cli.peer_config).await,
    }
}

async fn run(
    mut cfg: Config,
    identity: tls::Identity,
    dir: PathBuf,
    peer_config: Option<PathBuf>,
) -> Result<()> {
    let import_path = peer_config
        .map(Ok)
        .unwrap_or_else(config::lan_mouse_config)?;
    match cfg.import_lan_mouse_peers(&import_path) {
        Ok(0) => {}
        Ok(count) => {
            log::info!(
                "imported {count} peer address(es) from {}",
                import_path.display()
            );
            cfg.save(&dir)?;
        }
        Err(err) => log::warn!("could not read {}: {err}", import_path.display()),
    }

    // Deliberately not fatal. An unpaired daemon is harmless: the verifier
    // refuses every certificate and there is nobody to push to. Exiting here
    // instead meant a fresh install looked broken until the user happened to
    // pair, because the thing that reports "not running" is the same thing
    // pairing is supposed to fix.
    if cfg.authorized.is_empty() {
        log::warn!(
            "no paired peers yet; run `crossover-clipd pair <fingerprint>` to start syncing"
        );
    }

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let pinned = Arc::new(tls::PinnedPeers::new(cfg.authorized.clone(), provider));
    let server = Arc::new(tls::server_config(&identity, pinned.clone())?);
    let client = Arc::new(tls::client_config(&identity, pinned)?);

    // One digest guards both directions: the watcher will not rebroadcast what
    // the receiver just applied, and the receiver ignores an echo of its own
    // payload. Without it two machines ping-pong a single copy forever.
    let last_digest: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    log::info!("fingerprint {}", identity.fingerprint());
    log::info!("listening on {}:{}", cfg.bind, cfg.port);

    let listener = TcpListener::bind(format!("{}:{}", cfg.bind, cfg.port))
        .await
        .with_context(|| format!("binding {}:{}", cfg.bind, cfg.port))?;

    let inbound = tokio::spawn(accept_loop(
        listener,
        TlsAcceptor::from(server),
        cfg.max_bytes,
        last_digest.clone(),
    ));

    let outbound = tokio::spawn(watch_loop(
        cfg.clone(),
        TlsConnector::from(client),
        last_digest,
    ));

    tokio::select! {
        _ = tokio::signal::ctrl_c() => log::info!("shutting down"),
        result = inbound => result??,
        result = outbound => result??,
    }
    Ok(())
}

async fn accept_loop(
    listener: TcpListener,
    acceptor: TlsAcceptor,
    max_bytes: u64,
    last_digest: Arc<Mutex<Option<String>>>,
) -> Result<()> {
    let permits = Arc::new(Semaphore::new(MAX_INFLIGHT));
    loop {
        let (stream, peer) = listener.accept().await?;
        let permit = match permits.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                log::warn!("refused {peer}: too many connections in flight");
                continue;
            }
        };
        let acceptor = acceptor.clone();
        let digest = last_digest.clone();
        tokio::spawn(async move {
            let _permit = permit;
            if let Err(err) = serve(stream, peer, acceptor, max_bytes, digest).await {
                log::debug!("session with {peer} ended: {err}");
            }
        });
    }
}

async fn serve(
    stream: TcpStream,
    peer: SocketAddr,
    acceptor: TlsAcceptor,
    max_bytes: u64,
    last_digest: Arc<Mutex<Option<String>>>,
) -> Result<()> {
    let mut tls = timeout(HANDSHAKE_TIMEOUT, acceptor.accept(stream)).await??;
    let payload = timeout(EXCHANGE_TIMEOUT, proto::read_payload(&mut tls, max_bytes)).await??;
    let digest = payload.digest();

    let echo = {
        let mut guard = last_digest.lock().await;
        let echo = guard.as_deref() == Some(digest.as_str());
        if !echo {
            *guard = Some(digest);
        }
        echo
    };

    if echo {
        log::debug!("ignoring echo from {peer}");
    } else {
        let text = payload.as_text()?;
        tokio::task::spawn_blocking(move || clip::write_text(&text)).await??;
        log::info!("clipboard updated from {peer}");
    }

    // Acknowledged either way: an echo was still delivered intact, and the
    // sender only needs to know it was not refused.
    timeout(EXCHANGE_TIMEOUT, proto::write_ack(&mut tls)).await??;
    Ok(())
}

async fn watch_loop(
    cfg: Config,
    connector: TlsConnector,
    last_digest: Arc<Mutex<Option<String>>>,
) -> Result<()> {
    let mut ticker = tokio::time::interval(Duration::from_millis(cfg.poll_ms.max(100)));
    loop {
        ticker.tick().await;

        let snapshot = tokio::task::spawn_blocking(|| {
            if clip::is_sensitive() {
                return Ok(None);
            }
            clip::read_text()
        })
        .await?;

        let text = match snapshot {
            Ok(Some(text)) => text,
            Ok(None) => continue,
            Err(err) => {
                log::debug!("clipboard read failed: {err}");
                continue;
            }
        };

        if text.len() as u64 > cfg.max_bytes {
            log::debug!("skipping {} byte clipboard, over the limit", text.len());
            continue;
        }

        let payload = Payload::text(&text);
        let digest = payload.digest();
        {
            let guard = last_digest.lock().await;
            if guard.as_deref() == Some(digest.as_str()) {
                continue;
            }
        }

        let mut delivered = cfg.peers.is_empty();
        for peer in &cfg.peers {
            let (host, port) = config::split_host_port(peer, cfg.port);
            match push(&host, port, &connector, &payload).await {
                Ok(()) => delivered = true,
                Err(err) => log::debug!("could not push to {peer}: {err}"),
            }
        }

        // Only remember it once somebody actually took it. Recording the digest
        // up front meant a copy made while the peer was asleep was skipped
        // forever, because the next tick saw the same unchanged clipboard.
        if delivered {
            let mut guard = last_digest.lock().await;
            *guard = Some(digest);
        }
    }
}

async fn push(host: &str, port: u16, connector: &TlsConnector, payload: &Payload) -> Result<()> {
    let stream = timeout(CONNECT_TIMEOUT, TcpStream::connect((host, port))).await??;
    stream.set_nodelay(true)?;

    // The certificate fingerprint is the identity that matters here, so the
    // name only has to be well formed; PinnedPeers ignores it deliberately.
    let name = rustls::pki_types::ServerName::try_from("crossover")?;
    let mut tls = timeout(HANDSHAKE_TIMEOUT, connector.connect(name, stream)).await??;

    timeout(EXCHANGE_TIMEOUT, proto::write_payload(&mut tls, payload)).await??;
    timeout(EXCHANGE_TIMEOUT, proto::read_ack(&mut tls)).await??;
    tls.shutdown().await.ok();
    log::info!("clipboard accepted by {host}");
    Ok(())
}
