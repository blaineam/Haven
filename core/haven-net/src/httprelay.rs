//! **Plain-HTTP interface to the relay blob store** — the default cross-NAT media transport.
//!
//! The iroh blob ALPN (`haven/blob/1`) drops its outbound datagrams over a pure-relay
//! cross-NAT path (noq/iroh 1.0 fork bug), so large media transfers stall and die even
//! while messaging works. This module serves the SAME on-disk blob store over ordinary
//! HTTP/1.1, which traverses any NAT the moment the host is reachable (LAN, port-forward,
//! reverse proxy, or tunnel). Every blob is E2E-sealed before it reaches the store, so the
//! wire carries only ciphertext; TLS is delegated to a fronting proxy/tunnel when the
//! relay is exposed to the internet.
//!
//! ## Protocol (mirrors the blob verbs)
//!
//! ```text
//!   GET  /k/<key>      → 200 <body>          | 404
//!   HEAD /k/<key>      → 200                 | 404          (HAS; a hit refreshes liveness)
//!   PUT  /k/<key>      → 200 "OK"            | 4xx/5xx      (body = blob, ≤ 256 MiB)
//!   GET  /l/<prefix>   → 200 newline-joined keys            (LIST)
//!   POST /t/<prefix>   → 200 newline-joined MISSING keys    (TOUCH; body = keys to refresh)
//! ```
//!
//! TOUCH is the mailbox-GC liveness refresh (see `blobstore` module docs): the body lists
//! the caller's live keys under `<prefix>` (one circle's mailbox), the relay bumps their
//! mtimes, and the reply names the keys it does NOT hold so the caller re-PUTs them.
//!
//! `<key>`/`<prefix>` are percent-encoded store keys and pass through the same
//! [`super::blobstore::safe_path`] validation as the iroh path (no traversal, no NUL).
//!
//! ## Authorization
//!
//! One bearer token per relay: every request must carry `Authorization: Bearer <token>`.
//! The Haven apps distribute the token to circle members inside the *sealed* relay
//! announce (frame 19), so only members ever hold it. Unlike the iroh path there is no
//! verified peer identity here, therefore:
//!   - `self/…` keys (account self-sync slots) are REFUSED outright — self-sync stays on
//!     the identity-verified iroh path;
//!   - everything else is confined to the `haven/` namespace (mailbox + media), which
//!     holds only circle-sealed ciphertext.
//! An empty token disables auth (explicit self-host choice, e.g. behind an authenticating
//! proxy) — the Haven apps always set one.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, bail, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

use crate::blobstore::{local_get, local_list, local_put, local_touch, safe_path};

/// Hard cap on a single blob — matches the iroh blob path (256 MiB).
const MAX_BLOB: u64 = 256 * 1024 * 1024;
/// Cap on the request head (request line + headers).
const MAX_HEAD: usize = 16 * 1024;
/// Cap on a TOUCH body (newline-joined keys) — matches the iroh TOUCH verb.
const MAX_TOUCH_BODY: u64 = 256 * 1024;

/// A running HTTP relay server. Dropping it (or calling [`HttpRelay::stop`]) stops serving.
pub struct HttpRelay {
    port: u16,
    handle: tokio::task::JoinHandle<()>,
}

impl HttpRelay {
    /// The port actually bound (useful when `bind` asked for `:0`).
    pub fn port(&self) -> u16 {
        self.port
    }
    pub fn stop(&self) {
        self.handle.abort();
    }
}

impl Drop for HttpRelay {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

/// Serve the blob store at `root` over HTTP on `bind` (e.g. `0.0.0.0:8674`, port 0 = ephemeral).
/// `token` is the bearer token every request must present (empty = no auth).
pub async fn serve(root: PathBuf, bind: &str, token: String) -> Result<HttpRelay> {
    let addr: SocketAddr = bind.parse().map_err(|e| anyhow!("bad http bind {bind}: {e}"))?;
    let listener = TcpListener::bind(addr).await.map_err(|e| anyhow!("http bind {bind}: {e}"))?;
    let port = listener.local_addr()?.port();
    let token = Arc::new(token);
    let root = Arc::new(root);
    let handle = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { continue };
            let root = root.clone();
            let token = token.clone();
            tokio::spawn(async move {
                // Serial requests per connection (keep-alive); any parse error drops it.
                let _ = handle_conn(stream, &root, &token).await;
            });
        }
    });
    Ok(HttpRelay { port, handle })
}

async fn handle_conn(stream: TcpStream, root: &PathBuf, token: &str) -> Result<()> {
    let (r, mut w) = stream.into_split();
    let mut r = BufReader::new(r);
    loop {
        let (method, path, headers) = match read_head(&mut r).await {
            Ok(Some(h)) => h,
            Ok(None) => return Ok(()), // clean close between requests
            Err(_) => return Ok(()),
        };
        let clen: u64 = header(&headers, "content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
        // Honor `Connection: close` — a client that reads to EOF (rather than by Content-Length)
        // waits for us to close, so we MUST close the socket after answering it, or it hangs. Also
        // HTTP/1.0 defaults to close. Otherwise keep the connection alive for the next request.
        let keep_alive = header(&headers, "connection")
            .map(|v| !v.eq_ignore_ascii_case("close"))
            .unwrap_or(true);

        // Bearer auth (constant across all verbs). Read+discard the body on failure so
        // keep-alive framing survives, then answer 401.
        let authed = token.is_empty()
            || header(&headers, "authorization").map(|v| v.trim() == format!("Bearer {token}")).unwrap_or(false);
        if !authed {
            discard(&mut r, clen).await?;
            respond(&mut w, 401, "unauthorized", keep_alive, b"").await?;
            if !keep_alive { return Ok(()); }
            continue;
        }

        match route(&method, &path) {
            Route::Get(key) => {
                match checked(root, &key) {
                    Some(k) => match local_get(root, &k) {
                        Some(body) => respond(&mut w, 200, "OK", keep_alive, &body).await?,
                        None => respond(&mut w, 404, "not found", keep_alive, b"").await?,
                    },
                    None => respond(&mut w, 403, "forbidden", keep_alive, b"").await?,
                }
            }
            Route::Head(key) => {
                // A HAS hit refreshes the entry's liveness stamp (mailbox GC) — local_touch
                // returns the keys it did NOT find, so an empty result is a hit. Also avoids
                // local_get reading the whole blob just to answer an existence check.
                let hit = checked(root, &key).map(|k| local_touch(root, &[k]).is_empty()).unwrap_or(false);
                head_respond(&mut w, if hit { 200 } else { 404 }, keep_alive).await?;
            }
            Route::Put(key) => {
                if clen > MAX_BLOB {
                    discard(&mut r, clen.min(MAX_BLOB)).await.ok();
                    respond(&mut w, 413, "too large", false, b"").await?;
                    return Ok(()); // oversized body: drop the connection rather than drain it
                }
                let mut body = vec![0u8; clen as usize];
                r.read_exact(&mut body).await?;
                match checked(root, &key) {
                    Some(k) if local_put(root, &k, &body).is_ok() => respond(&mut w, 200, "OK", keep_alive, b"OK").await?,
                    Some(_) => respond(&mut w, 500, "write failed", keep_alive, b"").await?,
                    None => respond(&mut w, 403, "forbidden", keep_alive, b"").await?,
                }
            }
            Route::List(prefix) => {
                match checked(root, &prefix) {
                    Some(p) => {
                        let mut keys = local_list(root, &p);
                        keys.sort();
                        respond(&mut w, 200, "OK", keep_alive, keys.join("\n").as_bytes()).await?;
                    }
                    None => respond(&mut w, 403, "forbidden", keep_alive, b"").await?,
                }
            }
            Route::Touch(prefix) => {
                // Mailbox-GC liveness refresh: body = newline-joined keys (each confined to
                // `<prefix>` and the haven/ namespace); reply = the keys we do NOT hold.
                if clen > MAX_TOUCH_BODY {
                    discard(&mut r, clen.min(MAX_TOUCH_BODY)).await.ok();
                    respond(&mut w, 413, "too large", false, b"").await?;
                    return Ok(());
                }
                let mut body = vec![0u8; clen as usize];
                r.read_exact(&mut body).await?;
                match checked(root, &prefix) {
                    Some(p) => {
                        // Confine to the prefix as a DIRECTORY ("fam" must not match "famX").
                        let want = if p.ends_with('/') { p.clone() } else { format!("{p}/") };
                        let keys: Vec<String> = String::from_utf8_lossy(&body)
                            .lines()
                            .filter(|k| k.starts_with(&want) && checked(root, k).is_some())
                            .map(|k| k.to_string())
                            .collect();
                        let misses = local_touch(root, &keys);
                        respond(&mut w, 200, "OK", keep_alive, misses.join("\n").as_bytes()).await?;
                    }
                    None => respond(&mut w, 403, "forbidden", keep_alive, b"").await?,
                }
            }
            Route::Bad => {
                discard(&mut r, clen).await?;
                respond(&mut w, 404, "no route", keep_alive, b"").await?;
            }
        }
        if !keep_alive { return Ok(()); }
    }
}

enum Route {
    Get(String),
    Head(String),
    Put(String),
    List(String),
    Touch(String),
    Bad,
}

fn route(method: &str, path: &str) -> Route {
    let decode = |p: &str| percent_decode(p);
    if let Some(k) = path.strip_prefix("/k/") {
        return match method {
            "GET" => Route::Get(decode(k)),
            "HEAD" => Route::Head(decode(k)),
            "PUT" => Route::Put(decode(k)),
            _ => Route::Bad,
        };
    }
    if let (Some(p), "GET") = (path.strip_prefix("/l/"), method) {
        return Route::List(decode(p));
    }
    if let (Some(p), "POST") = (path.strip_prefix("/t/"), method) {
        return Route::Touch(decode(p));
    }
    Route::Bad
}

/// Validate a key for HTTP exposure: must be safe (no traversal) AND inside the `haven/`
/// namespace — `self/…` slots and anything else are refused (identity-gated, iroh-only).
fn checked(root: &PathBuf, key: &str) -> Option<String> {
    if !(key == "haven" || key.starts_with("haven/")) {
        return None;
    }
    safe_path(root, key).ok()?;
    Some(key.to_string())
}

/// Read one request head. Ok(None) = connection closed cleanly before a new request.
async fn read_head<R: tokio::io::AsyncRead + Unpin>(
    r: &mut BufReader<R>,
) -> Result<Option<(String, String, Vec<(String, String)>)>> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match r.read(&mut byte).await {
            Ok(0) => return if head.is_empty() { Ok(None) } else { bail!("eof mid-head") },
            Ok(_) => head.push(byte[0]),
            Err(e) => return if head.is_empty() { Ok(None) } else { Err(e.into()) },
        }
        if head.ends_with(b"\r\n\r\n") {
            break;
        }
        if head.len() > MAX_HEAD {
            bail!("head too large");
        }
    }
    let text = String::from_utf8_lossy(&head);
    let mut lines = text.split("\r\n");
    let req = lines.next().unwrap_or("");
    let mut parts = req.split_whitespace();
    let method = parts.next().unwrap_or("").to_uppercase();
    let path = parts.next().unwrap_or("").to_string();
    if method.is_empty() || !path.starts_with('/') {
        bail!("bad request line");
    }
    let mut headers = Vec::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_lowercase(), v.trim().to_string()));
        }
    }
    Ok(Some((method, path, headers)))
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

async fn discard<R: tokio::io::AsyncRead + Unpin>(r: &mut BufReader<R>, mut n: u64) -> Result<()> {
    let mut buf = [0u8; 8192];
    while n > 0 {
        let take = buf.len().min(n as usize);
        let got = r.read(&mut buf[..take]).await?;
        if got == 0 {
            break;
        }
        n -= got as u64;
    }
    Ok(())
}

async fn respond<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, code: u16, reason: &str, keep_alive: bool, body: &[u8]) -> Result<()> {
    let conn = if keep_alive { "keep-alive" } else { "close" };
    let head = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Length: {}\r\nContent-Type: application/octet-stream\r\nConnection: {conn}\r\n\r\n",
        body.len()
    );
    w.write_all(head.as_bytes()).await?;
    w.write_all(body).await?;
    w.flush().await?;
    Ok(())
}

async fn head_respond<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, code: u16, keep_alive: bool) -> Result<()> {
    let conn = if keep_alive { "keep-alive" } else { "close" };
    let head = format!("HTTP/1.1 {code} X\r\nContent-Length: 0\r\nConnection: {conn}\r\n\r\n");
    w.write_all(head.as_bytes()).await?;
    w.flush().await?;
    Ok(())
}

/// Minimal percent-decoding (UTF-8 lossy). Keys are ASCII-ish store paths.
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hi = (b[i + 1] as char).to_digit(16);
            let lo = (b[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode() {
        assert_eq!(percent_decode("haven/media/a%20b"), "haven/media/a b");
        assert_eq!(percent_decode("plain"), "plain");
        assert_eq!(percent_decode("%2e%2e/etc"), "../etc");
    }

    #[test]
    fn namespace_confinement() {
        let root = std::env::temp_dir();
        assert!(checked(&root, "haven/media/x").is_some());
        assert!(checked(&root, "self/abc/state/dev").is_none());
        assert!(checked(&root, "../etc/passwd").is_none());
        assert!(checked(&root, "haven/../self/x").is_none());
    }

    #[tokio::test]
    async fn put_get_list_roundtrip() {
        let dir = std::env::temp_dir().join(format!("httprelay-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let srv = serve(dir.clone(), "127.0.0.1:0", "tok".into()).await.unwrap();
        let port = srv.port();
        let base = format!("127.0.0.1:{port}");

        // Raw client (std) — keep the test dependency-free.
        let req = move |verb: &str, path: &str, auth: &str, body: &[u8]| {
            use std::io::{Read, Write};
            let mut s = std::net::TcpStream::connect(&base).unwrap();
            let head = format!(
                "{verb} {path} HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            s.write_all(head.as_bytes()).unwrap();
            s.write_all(body).unwrap();
            let mut resp = Vec::new();
            s.read_to_end(&mut resp).unwrap();
            String::from_utf8_lossy(&resp).into_owned()
        };
        let auth = "Authorization: Bearer tok\r\n";

        let blocking = tokio::task::spawn_blocking(move || {
            // Unauthorized → 401.
            assert!(req("GET", "/k/haven/media/x", "", b"").starts_with("HTTP/1.1 401"));
            // PUT then GET.
            assert!(req("PUT", "/k/haven/media/x", auth, b"hello").starts_with("HTTP/1.1 200"));
            let got = req("GET", "/k/haven/media/x", auth, b"");
            assert!(got.starts_with("HTTP/1.1 200") && got.ends_with("hello"));
            // HEAD hit / miss.
            assert!(req("HEAD", "/k/haven/media/x", auth, b"").starts_with("HTTP/1.1 200"));
            assert!(req("HEAD", "/k/haven/media/nope", auth, b"").starts_with("HTTP/1.1 404"));
            // LIST sees the key.
            let l = req("GET", "/l/haven/media", auth, b"");
            assert!(l.contains("haven/media/x"), "{l}");
            // TOUCH refreshes hits and reports misses (mailbox-GC liveness refresh).
            assert!(req("PUT", "/k/haven/mailbox/fam/aa", auth, b"sealed").starts_with("HTTP/1.1 200"));
            let t = req(
                "POST",
                "/t/haven/mailbox/fam/",
                auth,
                b"haven/mailbox/fam/aa\nhaven/mailbox/fam/gone\nhaven/mailbox/other/bb",
            );
            assert!(t.starts_with("HTTP/1.1 200"), "{t}");
            assert!(t.ends_with("haven/mailbox/fam/gone"), "only the in-prefix miss is reported: {t}");
            assert!(!t.contains("other/bb"), "cross-circle keys are ignored: {t}");
            // self/ refused even with the token.
            assert!(req("GET", "/k/self/a/state/b", auth, b"").starts_with("HTTP/1.1 403"));
        });
        blocking.await.unwrap();
        srv.stop();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
