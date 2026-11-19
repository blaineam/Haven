//! Secret ("screenshot-protected") messages. Byte-compatible with the iOS app
//! (`SecretMessages.swift`): the secret flag rides in the message body behind a single
//! U+0002 (STX) control char, so a secret DM authored on desktop is recognised as secret on
//! iPhone and vice-versa. The conceal/reveal/auto-hide behaviour is presentation-only and
//! lives in the WebView; the backend only needs to (a) keep the marker on the wire and
//! (b) never surface secret content in thread previews or notifications.

/// The control char iOS prefixes secret message bodies with (`"\u{2}"`).
pub const MARKER: char = '\u{2}';

/// Wrap plaintext as a secret message body.
pub fn encode(text: &str) -> String {
    let mut s = String::with_capacity(text.len() + 1);
    s.push(MARKER);
    s.push_str(text);
    s
}

/// Is this body a secret message?
pub fn is_secret(body: &str) -> bool {
    body.starts_with(MARKER)
}

/// The plaintext behind a (possibly secret) body.
pub fn strip(body: &str) -> &str {
    body.strip_prefix(MARKER).unwrap_or(body)
}

/// What to show in a thread preview / notification for a (possibly secret) body — never the
/// concealed content itself.
pub fn preview(body: &str) -> String {
    if is_secret(body) {
        "🔒 Secret message".to_string()
    } else {
        body.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marker_is_stx_u0002() {
        // Must match iOS `SecretMessages.marker = "\u{2}"` exactly for cross-platform interop.
        assert_eq!(MARKER as u32, 0x0002);
        assert_eq!(encode("").as_bytes(), &[0x02]);
    }

    #[test]
    fn round_trip() {
        let enc = encode("meet me at 7");
        assert!(is_secret(&enc));
        assert_eq!(strip(&enc), "meet me at 7");
    }

    #[test]
    fn plain_text_is_not_secret() {
        assert!(!is_secret("hello"));
        assert_eq!(strip("hello"), "hello");
        assert_eq!(preview("hello"), "hello");
    }

    #[test]
    fn preview_hides_secret_content() {
        let enc = encode("the password is hunter2");
        assert_eq!(preview(&enc), "🔒 Secret message");
        assert!(!preview(&enc).contains("hunter2"));
    }

    #[test]
    fn empty_body_is_plain() {
        assert!(!is_secret(""));
        assert_eq!(strip(""), "");
    }
}
