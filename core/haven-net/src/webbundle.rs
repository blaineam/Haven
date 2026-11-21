//! The web client's files, as a relay serves them: a fixed, in-memory set of `path → bytes` handed
//! to the path proxy when it starts.
//!
//! Deliberately not a directory. The proxy never reads the filesystem (it has a test that says
//! so), so what a relay serves is exactly what its host put in this value — the bytes the app or
//! `haven-relay` shipped with — and a request can never be turned into a path on the host's disk.
//! There is nothing to traverse: a lookup is an exact match against names fixed at start-up.
//!
//! Serving the page is one of the two ways a browser comes to use a circle's relay (the other is
//! a page from an ordinary web site, which the mailbox answers across origins — see
//! `httprelay::CORS_ANSWER`), and it is the web client's trust boundary: whoever serves these
//! bytes can change them. See `docs/WEB-PARITY.md` § "What the web client trusts".

use std::collections::HashMap;

/// URL prefix the bundle is served under on the relay's public origin.
pub const APP_PREFIX: &str = "/app/";

/// Sent with every bundle response. The page may run its own script and WebAssembly and nothing
/// injected; it may connect out (other relays, n0, a user's S3 bucket) only over TLS or to its own
/// origin; it cannot be framed, and it sends no referrer.
pub const CONTENT_SECURITY_POLICY: &str = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; \
style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob:; font-src 'self'; \
connect-src 'self' https: wss:; worker-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; \
frame-ancestors 'none'";

/// One servable file.
#[derive(Clone, Debug)]
pub struct WebFile {
    pub content_type: &'static str,
    pub body: Vec<u8>,
    /// Strong validator: lower-hex BLAKE3 of the body, quoted.
    pub etag: String,
    /// The body gzip-compressed, when that is meaningfully smaller — made once, at insert. Served
    /// to a client that accepts gzip (a 10 MB WebAssembly module is about a third of that).
    pub gzip: Option<Vec<u8>>,
}

/// gzip `body` if it is a compressible type and the result saves at least a tenth.
fn gzip_if_worth_it(content_type: &str, body: &[u8]) -> Option<Vec<u8>> {
    use std::io::Write;
    let compressible = content_type.starts_with("text/")
        || content_type.starts_with("application/json")
        || content_type == "application/wasm"
        || content_type == "image/svg+xml";
    if !compressible || body.len() < 1024 {
        return None;
    }
    let mut enc = flate2::write::GzEncoder::new(Vec::with_capacity(body.len() / 3), flate2::Compression::best());
    enc.write_all(body).ok()?;
    let out = enc.finish().ok()?;
    (out.len() * 10 <= body.len() * 9).then_some(out)
}

/// The files of one build of the web client.
#[derive(Clone, Debug, Default)]
pub struct WebBundle {
    files: HashMap<String, WebFile>,
}

/// The content type for a bundle file name, by extension — a closed list. A name outside it is not
/// served at all, so nothing can be made to render as HTML or run as script by its content.
pub fn content_type_for(name: &str) -> Option<&'static str> {
    let ext = name.rsplit_once('.')?.1.to_ascii_lowercase();
    Some(match ext.as_str() {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "wasm" => "application/wasm",
        "json" | "webmanifest" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "txt" => "text/plain; charset=utf-8",
        _ => return None,
    })
}

/// A bundle file name is relative, `/`-separated, and made only of plain segments.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 256
        && name.split('/').all(|seg| {
            !seg.is_empty()
                && seg != "."
                && seg != ".."
                && seg.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
        })
}

impl WebBundle {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a file under its bundle-relative name (`index.html`, `pkg/haven_web_bg.wasm`). Returns
    /// false — and adds nothing — for a name that is not a plain relative path or whose extension
    /// has no known content type.
    pub fn insert(&mut self, name: &str, body: Vec<u8>) -> bool {
        let Some(content_type) = content_type_for(name) else { return false };
        if !valid_name(name) {
            return false;
        }
        let etag = format!("\"{}\"", blake3::hash(&body).to_hex());
        let gzip = gzip_if_worth_it(content_type, &body);
        self.files.insert(name.to_string(), WebFile { content_type, body, etag, gzip });
        true
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    pub fn len(&self) -> usize {
        self.files.len()
    }

    /// The file for a request path under [`APP_PREFIX`] (query string ignored). `/app/` is
    /// `index.html`. Anything that is not an exact, already-known name is `None`.
    pub fn lookup(&self, request_path: &str) -> Option<&WebFile> {
        let path = request_path.split(['?', '#']).next().unwrap_or(request_path);
        let rest = path.strip_prefix(APP_PREFIX)?;
        let name = if rest.is_empty() { "index.html" } else { rest };
        // Exact match only: no decoding, no normalisation — an encoded or dotted path is simply
        // not one of the names.
        self.files.get(name)
    }

    /// One digest over the whole bundle (names and bodies, in name order) — what a build of the
    /// web client "is". Shown by the relay's status route so a build can be compared by eye.
    pub fn digest(&self) -> String {
        let mut names: Vec<&String> = self.files.keys().collect();
        names.sort();
        let mut h = blake3::Hasher::new();
        for n in names {
            h.update(&(n.len() as u64).to_le_bytes());
            h.update(n.as_bytes());
            let body = &self.files[n].body;
            h.update(&(body.len() as u64).to_le_bytes());
            h.update(body);
        }
        h.finalize().to_hex().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bundle() -> WebBundle {
        let mut b = WebBundle::new();
        assert!(b.insert("index.html", b"<!doctype html>".to_vec()));
        assert!(b.insert("pkg/haven_web.js", b"export{}".to_vec()));
        assert!(b.insert("pkg/haven_web_bg.wasm", vec![0, 97, 115, 109]));
        b
    }

    #[test]
    fn serves_exact_names_and_index_at_the_prefix() {
        let b = bundle();
        assert_eq!(b.lookup("/app/").unwrap().content_type, "text/html; charset=utf-8");
        assert_eq!(b.lookup("/app/index.html").unwrap().body, b"<!doctype html>");
        assert_eq!(b.lookup("/app/pkg/haven_web_bg.wasm").unwrap().content_type, "application/wasm");
        assert_eq!(b.lookup("/app/pkg/haven_web.js?v=3").unwrap().content_type, "text/javascript; charset=utf-8");
        assert!(b.lookup("/app").is_none(), "the bare prefix is the proxy's redirect, not a file");
        assert!(b.lookup("/app/missing.js").is_none());
        assert!(b.lookup("/other/index.html").is_none());
    }

    #[test]
    fn a_request_can_never_name_anything_outside_the_bundle() {
        let b = bundle();
        for p in [
            "/app/../etc/passwd", "/app/pkg/../../secret", "/app/%2e%2e/index.html", "/app//index.html",
            "/app/./index.html", "/app/pkg/", "/app/pkg", "/app/index.html/", "/app/INDEX.HTML", "/app/\\index.html",
            "/app/pkg%2fhaven_web.js", "/app/index.html%00.js",
        ] {
            assert!(b.lookup(p).is_none(), "{p} must not resolve");
        }
    }

    #[test]
    fn only_plain_names_with_known_types_are_accepted() {
        let mut b = WebBundle::new();
        for bad in [
            "", "/index.html", "../index.html", "a/../b.js", "a//b.js", "./a.js", "a b.js", "a.exe", "noext",
            "pkg/.hidden", "a.html.gz", "a\\b.js", "é.js",
        ] {
            assert!(!b.insert(bad, b"x".to_vec()), "{bad:?} must be refused");
        }
        assert!(b.is_empty());
        assert!(b.insert("palette-icons/a-1_b.svg", b"<svg/>".to_vec()));
    }

    #[test]
    fn large_compressible_files_carry_a_gzip_body_that_inflates_to_the_original() {
        use std::io::Read;
        let mut b = WebBundle::new();
        let js: Vec<u8> = b"export function hello() { return 'haven'; }\n".iter().cycle().take(40_000).copied().collect();
        assert!(b.insert("app.js", js.clone()));
        assert!(b.insert("tiny.js", b"export{}".to_vec()));
        assert!(b.insert("icon.png", vec![7u8; 5000]));
        let f = b.lookup("/app/app.js").unwrap();
        let gz = f.gzip.as_ref().expect("a large script is pre-compressed");
        assert!(gz.len() * 10 <= js.len() * 9);
        let mut out = Vec::new();
        flate2::read::GzDecoder::new(&gz[..]).read_to_end(&mut out).unwrap();
        assert_eq!(out, js);
        assert!(b.lookup("/app/tiny.js").unwrap().gzip.is_none(), "not worth it for a tiny file");
        assert!(b.lookup("/app/icon.png").unwrap().gzip.is_none(), "images are already compressed");
    }

    #[test]
    fn etag_and_digest_follow_the_bytes() {
        let a = bundle();
        let mut b = bundle();
        assert_eq!(a.digest(), b.digest());
        assert_eq!(a.lookup("/app/").unwrap().etag, b.lookup("/app/").unwrap().etag);
        assert!(b.insert("index.html", b"<!doctype html><!-- changed -->".to_vec()));
        assert_ne!(a.digest(), b.digest());
        assert_ne!(a.lookup("/app/").unwrap().etag, b.lookup("/app/").unwrap().etag);
        let tag = &a.lookup("/app/").unwrap().etag;
        assert!(tag.starts_with('"') && tag.ends_with('"') && tag.len() == 66);
    }

    #[test]
    fn the_policy_forbids_injected_script_plaintext_connections_and_framing() {
        let csp = CONTENT_SECURITY_POLICY;
        assert!(csp.contains("script-src 'self' 'wasm-unsafe-eval'"));
        assert!(!csp.contains("'unsafe-eval'") || csp.contains("'wasm-unsafe-eval'"));
        assert!(!csp.split(';').any(|d| d.trim().starts_with("script-src") && d.contains("'unsafe-inline'")));
        assert!(csp.contains("connect-src 'self' https: wss:"));
        assert!(!csp.contains(" http:") && !csp.contains(" ws:"));
        assert!(csp.contains("frame-ancestors 'none'") && csp.contains("object-src 'none'") && csp.contains("base-uri 'none'"));
    }
}
