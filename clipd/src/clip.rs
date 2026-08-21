use anyhow::Result;

/// Text pulled off the local clipboard, or None when there is nothing readable
/// there. An empty clipboard is a normal state, never an error.
pub fn read_text() -> Result<Option<String>> {
    backend::read_text()
}

pub fn write_text(text: &str) -> Result<()> {
    backend::write_text(text)
}

/// True when the current selection is marked as a secret by whatever put it
/// there. Password managers set this precisely so tools like this one leave it
/// alone, and honouring it is the difference between a clipboard bridge and a
/// credential exfiltration path.
pub fn is_sensitive() -> bool {
    backend::is_sensitive()
}

#[cfg(all(unix, not(target_os = "macos")))]
mod backend {
    use anyhow::Result;
    use std::io::Read;
    use wl_clipboard_rs::copy::{MimeType as CopyMime, Options, Source};
    use wl_clipboard_rs::paste::{
        get_contents, get_mime_types, ClipboardType, Error as PasteError, MimeType, Seat,
    };

    const CONCEALED_HINTS: [&str; 2] = ["x-kde-passwordManagerHint", "org.nspasteboard.ConcealedType"];

    pub fn read_text() -> Result<Option<String>> {
        match get_contents(ClipboardType::Regular, Seat::Unspecified, MimeType::Text) {
            Ok((mut pipe, _mime)) => {
                let mut buf = Vec::new();
                pipe.read_to_end(&mut buf)?;
                if buf.is_empty() {
                    return Ok(None);
                }
                Ok(Some(String::from_utf8_lossy(&buf).into_owned()))
            }
            Err(PasteError::NoSeats)
            | Err(PasteError::ClipboardEmpty)
            | Err(PasteError::NoMimeType) => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    pub fn write_text(text: &str) -> Result<()> {
        let opts = Options::new();
        opts.copy(
            Source::Bytes(text.as_bytes().to_vec().into_boxed_slice()),
            CopyMime::Text,
        )?;
        Ok(())
    }

    pub fn is_sensitive() -> bool {
        match get_mime_types(ClipboardType::Regular, Seat::Unspecified) {
            Ok(types) => types
                .iter()
                .any(|mime| CONCEALED_HINTS.iter().any(|hint| mime == hint)),
            // An unreadable MIME list is not evidence of safety, but it is also
            // the normal result of an empty clipboard, so this does not block.
            Err(_) => false,
        }
    }
}

#[cfg(target_os = "macos")]
mod backend {
    use anyhow::Result;
    use arboard::Clipboard;

    pub fn read_text() -> Result<Option<String>> {
        let mut clipboard = Clipboard::new()?;
        match clipboard.get_text() {
            Ok(text) if text.is_empty() => Ok(None),
            Ok(text) => Ok(Some(text)),
            Err(arboard::Error::ContentNotAvailable) => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    pub fn write_text(text: &str) -> Result<()> {
        let mut clipboard = Clipboard::new()?;
        clipboard.set_text(text.to_owned())?;
        Ok(())
    }

    pub fn is_sensitive() -> bool {
        // arboard does not surface NSPasteboard types, so the concealed-type
        // hint cannot be read here yet. Documented in the README rather than
        // silently pretended away.
        false
    }
}
