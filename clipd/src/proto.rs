use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const PROTOCOL_VERSION: u32 = 1;
pub const TEXT_MIME: &str = "text/plain;charset=utf-8";

/// Headers are bounded well below any legitimate size so a hostile peer cannot
/// make the receiver buffer on the strength of a length field alone.
const MAX_HEADER_BYTES: u32 = 4096;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Header {
    pub v: u32,
    pub mime: String,
    pub len: u64,
    pub sha256: String,
}

#[derive(Debug, Clone)]
pub struct Payload {
    pub mime: String,
    pub bytes: Vec<u8>,
}

impl Payload {
    pub fn text(text: &str) -> Self {
        Self {
            mime: TEXT_MIME.to_string(),
            bytes: text.as_bytes().to_vec(),
        }
    }

    pub fn digest(&self) -> String {
        hex(&Sha256::digest(&self.bytes))
    }

    pub fn as_text(&self) -> Result<String> {
        Ok(String::from_utf8(self.bytes.clone())?)
    }
}

pub fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

pub async fn write_payload<W>(stream: &mut W, payload: &Payload) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let header = Header {
        v: PROTOCOL_VERSION,
        mime: payload.mime.clone(),
        len: payload.bytes.len() as u64,
        sha256: payload.digest(),
    };
    let encoded = serde_json::to_vec(&header)?;
    if encoded.len() as u32 > MAX_HEADER_BYTES {
        bail!("header too large to send");
    }

    stream
        .write_all(&(encoded.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(&encoded).await?;
    stream.write_all(&payload.bytes).await?;
    stream.flush().await?;
    Ok(())
}

pub async fn read_payload<R>(stream: &mut R, max_bytes: u64) -> Result<Payload>
where
    R: AsyncRead + Unpin,
{
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let header_len = u32::from_be_bytes(len_buf);
    if header_len == 0 || header_len > MAX_HEADER_BYTES {
        bail!("refused header of {header_len} bytes");
    }

    let mut header_buf = vec![0u8; header_len as usize];
    stream.read_exact(&mut header_buf).await?;
    let header: Header = serde_json::from_slice(&header_buf)?;

    if header.v != PROTOCOL_VERSION {
        bail!("unsupported protocol version {}", header.v);
    }
    if header.len > max_bytes {
        bail!(
            "refused payload of {} bytes (limit {})",
            header.len,
            max_bytes
        );
    }

    // Allocation follows the cap check, never the peer's claim on its own.
    let mut bytes = vec![0u8; header.len as usize];
    stream.read_exact(&mut bytes).await?;

    let payload = Payload {
        mime: header.mime,
        bytes,
    };
    if payload.digest() != header.sha256 {
        bail!("payload digest mismatch");
    }
    Ok(payload)
}

/// Sent by the receiver once a payload has been accepted. TLS 1.3 lets a
/// client finish writing before the server has validated its certificate, so
/// without this the sender would report success for payloads that were in fact
/// refused.
const ACK: u8 = 0x06;

pub async fn write_ack<W>(stream: &mut W) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    stream.write_all(&[ACK]).await?;
    stream.flush().await?;
    Ok(())
}

pub async fn read_ack<R>(stream: &mut R) -> Result<()>
where
    R: AsyncRead + Unpin,
{
    let mut byte = [0u8; 1];
    stream.read_exact(&mut byte).await?;
    if byte[0] != ACK {
        bail!("peer did not acknowledge the payload");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn roundtrips_a_payload() {
        let (mut a, mut b) = tokio::io::duplex(64 * 1024);
        let sent = Payload::text("hello from the other side");
        write_payload(&mut a, &sent).await.unwrap();
        let got = read_payload(&mut b, 1024).await.unwrap();
        assert_eq!(got.as_text().unwrap(), "hello from the other side");
        assert_eq!(got.digest(), sent.digest());
    }

    #[tokio::test]
    async fn refuses_a_payload_over_the_cap() {
        let (mut a, mut b) = tokio::io::duplex(64 * 1024);
        let sent = Payload::text(&"x".repeat(2048));
        write_payload(&mut a, &sent).await.unwrap();
        let err = read_payload(&mut b, 1024).await.unwrap_err();
        assert!(err.to_string().contains("refused payload"), "{err}");
    }

    #[tokio::test]
    async fn refuses_an_absurd_header_length() {
        let (mut a, mut b) = tokio::io::duplex(64);
        a.write_all(&u32::MAX.to_be_bytes()).await.unwrap();
        let err = read_payload(&mut b, 1024).await.unwrap_err();
        assert!(err.to_string().contains("refused header"), "{err}");
    }

    #[tokio::test]
    async fn detects_a_tampered_payload() {
        let (mut a, mut b) = tokio::io::duplex(64 * 1024);
        let header = Header {
            v: PROTOCOL_VERSION,
            mime: TEXT_MIME.to_string(),
            len: 4,
            sha256: hex(&Sha256::digest(b"good")),
        };
        let encoded = serde_json::to_vec(&header).unwrap();
        a.write_all(&(encoded.len() as u32).to_be_bytes())
            .await
            .unwrap();
        a.write_all(&encoded).await.unwrap();
        a.write_all(b"evil").await.unwrap();
        let err = read_payload(&mut b, 1024).await.unwrap_err();
        assert!(err.to_string().contains("digest mismatch"), "{err}");
    }

    #[tokio::test]
    async fn rejects_an_unknown_protocol_version() {
        let (mut a, mut b) = tokio::io::duplex(64 * 1024);
        let header = Header {
            v: 99,
            mime: TEXT_MIME.to_string(),
            len: 0,
            sha256: hex(&Sha256::digest(b"")),
        };
        let encoded = serde_json::to_vec(&header).unwrap();
        a.write_all(&(encoded.len() as u32).to_be_bytes())
            .await
            .unwrap();
        a.write_all(&encoded).await.unwrap();
        let err = read_payload(&mut b, 1024).await.unwrap_err();
        assert!(
            err.to_string().contains("unsupported protocol version"),
            "{err}"
        );
    }
}
