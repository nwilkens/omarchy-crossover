use anyhow::{Context, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName, Error as TlsError, SignatureScheme};
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// A long-lived self-signed identity. Both ends pin each other's certificate
/// fingerprint, which is the same trust model lan-mouse uses, so a user pairs
/// machines once and reasons about one kind of secret.
pub struct Identity {
    pub cert: CertificateDer<'static>,
    pub key: PrivateKeyDer<'static>,
}

impl Identity {
    pub fn load_or_create(dir: &Path) -> Result<Self> {
        let cert_path = dir.join("identity.crt");
        let key_path = dir.join("identity.key");

        if cert_path.exists() && key_path.exists() {
            let cert = CertificateDer::from(fs::read(&cert_path)?);
            let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(fs::read(&key_path)?));
            return Ok(Self { cert, key });
        }

        fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;

        let key_pair = rcgen::KeyPair::generate()?;
        let params = rcgen::CertificateParams::new(vec!["crossover".to_string()])?;
        let cert = params.self_signed(&key_pair)?;

        let cert_der = cert.der().to_vec();
        let key_der = key_pair.serialize_der();

        fs::write(&cert_path, &cert_der)?;
        write_private(&key_path, &key_der)?;

        Ok(Self {
            cert: CertificateDer::from(cert_der),
            key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der)),
        })
    }

    pub fn fingerprint(&self) -> String {
        fingerprint_of(&self.cert)
    }

    pub fn clone_key(&self) -> PrivateKeyDer<'static> {
        self.key.clone_key()
    }
}

fn write_private(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    fs::write(path, bytes)?;
    // The private key is the whole of this machine's identity, so it is never
    // left group- or world-readable, not even briefly.
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

/// Colon-separated lowercase hex, matching how lan-mouse prints fingerprints
/// so the two pairing flows look like one flow to the user.
pub fn fingerprint_of(cert: &CertificateDer<'_>) -> String {
    let digest = Sha256::digest(cert.as_ref());
    digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<Vec<_>>()
        .join(":")
}

#[derive(Debug)]
pub struct PinnedPeers {
    fingerprints: Vec<String>,
    provider: Arc<CryptoProvider>,
}

impl PinnedPeers {
    pub fn new(fingerprints: Vec<String>, provider: Arc<CryptoProvider>) -> Self {
        Self {
            fingerprints: fingerprints
                .into_iter()
                .map(|f| f.trim().to_lowercase())
                .filter(|f| !f.is_empty())
                .collect(),
            provider,
        }
    }

    fn accepts(&self, cert: &CertificateDer<'_>) -> Result<(), TlsError> {
        let seen = fingerprint_of(cert);
        if self.fingerprints.iter().any(|pinned| pinned == &seen) {
            return Ok(());
        }
        // Deliberately not trust-on-first-use: an unknown peer is refused and
        // must be added by the user out of band.
        Err(TlsError::General(format!(
            "peer certificate {seen} is not paired"
        )))
    }

    fn verify12(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify13(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

impl ServerCertVerifier for PinnedPeers {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        self.accepts(end_entity)?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        self.verify12(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        self.verify13(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes()
    }
}

impl ClientCertVerifier for PinnedPeers {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, TlsError> {
        self.accepts(end_entity)?;
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        self.verify12(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        self.verify13(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes()
    }
}

pub fn server_config(identity: &Identity, peers: Arc<PinnedPeers>) -> Result<rustls::ServerConfig> {
    let config = rustls::ServerConfig::builder()
        .with_client_cert_verifier(peers)
        .with_single_cert(vec![identity.cert.clone()], identity.clone_key())?;
    Ok(config)
}

pub fn client_config(identity: &Identity, peers: Arc<PinnedPeers>) -> Result<rustls::ClientConfig> {
    let config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(peers)
        .with_client_auth_cert(vec![identity.cert.clone()], identity.clone_key())?;
    Ok(config)
}

pub fn is_valid_fingerprint(value: &str) -> bool {
    let parts: Vec<&str> = value.trim().split(':').collect();
    if parts.len() != 32 {
        return false;
    }
    parts
        .iter()
        .all(|p| p.len() == 2 && p.chars().all(|c| c.is_ascii_hexdigit()))
}

pub fn ensure_dir(dir: &Path) -> Result<()> {
    if !dir.exists() {
        fs::create_dir_all(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
