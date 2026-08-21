use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub const DEFAULT_PORT: u16 = 4243;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Listen port. Distinct from lan-mouse's 4242 so the two are independent.
    pub port: u16,
    /// Addresses to push the clipboard to.
    pub peers: Vec<String>,
    /// Certificate fingerprints allowed to connect, in either direction.
    pub authorized: Vec<String>,
    /// Hard ceiling on a single clipboard transfer.
    pub max_bytes: u64,
    /// Local clipboard poll interval.
    pub poll_ms: u64,
    pub bind: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: DEFAULT_PORT,
            peers: Vec::new(),
            authorized: Vec::new(),
            max_bytes: 4 * 1024 * 1024,
            poll_ms: 400,
            bind: "0.0.0.0".to_string(),
        }
    }
}

impl Config {
    pub fn path(dir: &Path) -> PathBuf {
        dir.join("config.toml")
    }

    pub fn load(dir: &Path) -> Result<Self> {
        let path = Self::path(dir);
        if !path.exists() {
            let config = Self::default();
            config.save(dir)?;
            return Ok(config);
        }
        let text = fs::read_to_string(&path)
            .with_context(|| format!("reading {}", path.display()))?;
        Ok(toml::from_str(&text)?)
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        fs::create_dir_all(dir)?;
        fs::write(Self::path(dir), toml::to_string_pretty(self)?)?;
        Ok(())
    }

    pub fn trust(&mut self, fingerprint: &str) -> bool {
        let value = fingerprint.trim().to_lowercase();
        if self.authorized.iter().any(|f| f == &value) {
            return false;
        }
        self.authorized.push(value);
        true
    }

    pub fn revoke(&mut self, fingerprint: &str) -> bool {
        let value = fingerprint.trim().to_lowercase();
        let before = self.authorized.len();
        self.authorized.retain(|f| f != &value);
        before != self.authorized.len()
    }

    pub fn add_peer(&mut self, host: &str) -> bool {
        let value = host.trim().to_string();
        if value.is_empty() || self.peers.iter().any(|p| p == &value) {
            return false;
        }
        self.peers.push(value);
        true
    }

    /// Pull peer addresses out of a lan-mouse config so a user who has already
    /// paired their machines for input does not pair them again for clipboard.
    pub fn import_lan_mouse_peers(&mut self, path: &Path) -> Result<usize> {
        if !path.exists() {
            return Ok(0);
        }
        let text = fs::read_to_string(path)?;
        let parsed: LanMouseConfig = toml::from_str(&text)?;
        let mut added = 0;
        for client in parsed.clients {
            if let Some(hostname) = client.hostname.as_deref() {
                if self.add_peer(hostname) {
                    added += 1;
                }
            }
            for ip in client.ips {
                if self.add_peer(&ip) {
                    added += 1;
                }
            }
        }
        Ok(added)
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct LanMouseConfig {
    clients: Vec<LanMouseClient>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct LanMouseClient {
    hostname: Option<String>,
    ips: Vec<String>,
}

pub fn config_dir() -> Result<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .context("neither XDG_CONFIG_HOME nor HOME is set")?;
    Ok(base.join("crossover"))
}

pub fn lan_mouse_config() -> Result<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .context("neither XDG_CONFIG_HOME nor HOME is set")?;
    Ok(base.join("lan-mouse").join("config.toml"))
}

/// Peers may be written as `host` or `host:port`, with bracketed IPv6 as
/// `[::1]:4243`. A bare IPv6 literal has colons but no port, so the split only
/// treats a trailing colon group as a port when it is unambiguous.
pub fn split_host_port(peer: &str, default_port: u16) -> (String, u16) {
    let value = peer.trim();

    if let Some(rest) = value.strip_prefix('[') {
        if let Some((host, tail)) = rest.split_once(']') {
            let port = tail
                .strip_prefix(':')
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or(default_port);
            return (host.to_string(), port);
        }
    }

    match value.rsplit_once(':') {
        // More than one colon means a bare IPv6 literal, not host:port.
        Some((host, port)) if !host.contains(':') => match port.parse::<u16>() {
            Ok(parsed) => (host.to_string(), parsed),
            Err(_) => (value.to_string(), default_port),
        },
        _ => (value.to_string(), default_port),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_bare_host() {
        assert_eq!(split_host_port("iridium", 4243), ("iridium".into(), 4243));
    }

    #[test]
    fn splits_host_and_port() {
        assert_eq!(split_host_port("10.0.0.4:9000", 4243), ("10.0.0.4".into(), 9000));
    }

    #[test]
    fn keeps_bare_ipv6_intact() {
        assert_eq!(split_host_port("fe80::1", 4243), ("fe80::1".into(), 4243));
    }

    #[test]
    fn splits_bracketed_ipv6() {
        assert_eq!(split_host_port("[fe80::1]:9000", 4243), ("fe80::1".into(), 9000));
        assert_eq!(split_host_port("[fe80::1]", 4243), ("fe80::1".into(), 4243));
    }

    #[test]
    fn falls_back_when_port_is_not_a_number() {
        assert_eq!(split_host_port("host:abc", 4243), ("host:abc".into(), 4243));
    }

    #[test]
    fn trust_is_idempotent_and_case_insensitive() {
        let mut cfg = Config::default();
        assert!(cfg.trust("AB:CD"));
        assert!(!cfg.trust("ab:cd"));
        assert_eq!(cfg.authorized.len(), 1);
    }
}
