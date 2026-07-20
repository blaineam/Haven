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
//! ## Authorization — a signed request, not a shared secret
//!
//! This transport used to gate on one shared bearer token per relay. That token is handed to
//! every member of every circle a relay serves, so holding it proved only "somebody let me in
//! somewhere" — never *which* circle. A security audit turned that into a live probe: a caller
//! in no circle, holding only the token, enumerated every circle, read another circle's blob,
//! and wrote into its mailbox. Membership cannot be expressed by a credential that every
//! member shares, so the token is no longer what authorizes a request.
//!
//! Each request now carries the caller's own node-key signature, giving HTTP the same verified
//! peer identity QUIC gives the iroh path:
//!
//! ```text
//!   Authorization: Haven <node-id-hex>.<unix-ts>.<nonce-hex>.<blake3(body)-hex>.<ed25519-sig-hex>
//! ```
//!
//! The signature covers [`REQUEST_DOMAIN`] ‖ token ‖ method ‖ key ‖ ts ‖ nonce ‖ blake3(body),
//! so it authenticates the caller *and* binds the request: a capture cannot be replayed against
//! a different key, verb, or body, and cannot be replayed at all (the nonce is remembered for
//! [`SKEW`] and the timestamp must be inside it). The body digest travels in the header so the
//! whole request can be authorized from the head alone — a PUT body is only read (and only
//! allocated) once its signer is known, and is then checked against the digest it signed.
//!
//! The node id is an Ed25519 public key, so it is self-authenticating — verifying the signature
//! IS establishing who the caller is. That identity then goes through the exact same
//! `blobstore::blob_forbidden` circle-membership check as the iroh path; there is no second
//! authorization system, and no policy that is weaker on this port than on the other.
//!
//! The token survives, demoted to what it always actually was: a shared relay secret, now
//! folded into the signed transcript rather than sent. It proves the caller received the sealed
//! relay announce (frame 19), keeps unrelated internet scanners from reaching the verify path,
//! and — because it is mixed in, never transmitted — it no longer crosses the wire in cleartext
//! for an on-path attacker to lift (audit F9). It is a coarse pre-filter. Membership is the
//! authorization, and only the signature can establish it.
//!
//! `self/…` keys (account self-sync slots) stay refused outright here — self-sync has no reason
//! to leave the iroh path. An empty token still means "no shared secret", NOT "no auth": the
//! signature and the membership check are unconditional.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

use crate::blobstore::{
    blob_forbidden, local_get, local_list, local_put, local_touch, safe_path, verify_devroster_put,
    RelayAuth, DEVROSTER_PREFIX, VERB_GET, VERB_HAS, VERB_LIST, VERB_PUT, VERB_TOUCH,
};

/// Hard cap on a single blob — matches the iroh blob path (256 MiB).
const MAX_BLOB: u64 = 256 * 1024 * 1024;
/// Cap on the request head (request line + headers).
const MAX_HEAD: usize = 16 * 1024;
/// Cap on a TOUCH body (newline-joined keys) — matches the iroh TOUCH verb.
const MAX_TOUCH_BODY: u64 = 256 * 1024;

/// Domain tag on the request signature, so a node-key signature minted for Haven's HTTP relay can
/// never be lifted from (or replayed into) any other context that signs with the same key.
pub const REQUEST_DOMAIN: &str = "haven-httprelay-v1";
/// Accepted clock skew, and therefore how long a nonce must be remembered to make a signed
/// request one-shot. Wide enough for a phone with a lazy clock, short enough to bound the cache.
const SKEW: u64 = 300;

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len() / 2).map(|i| u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()).collect()
}

/// The exact bytes a request signature covers. Every field that decides what the request DOES is
/// in here — flip the verb, the key, or a byte of the body and the signature stops verifying.
fn transcript(token: &str, method: &str, key: &str, ts: u64, nonce: &str, body_hex: &str) -> Vec<u8> {
    format!("{REQUEST_DOMAIN}\n{token}\n{method}\n{key}\n{ts}\n{nonce}\n{body_hex}").into_bytes()
}

fn body_digest(body: &[u8]) -> String {
    hex(blake3::hash(body).as_bytes())
}

/// Build the `Authorization` value for one request, signing with this node's Ed25519 node secret
/// (`Identity::node_secret_bytes`) — the same key the iroh transport authenticates the node under,
/// so the relay's membership check sees one identity per node regardless of transport.
///
/// This is the client half of the protocol; it lives here so every platform's HTTP client signs
/// byte-identically to what the server verifies.
pub fn auth_header(node_secret: &[u8; 32], token: &str, method: &str, key: &str, body: &[u8]) -> String {
    use ed25519_dalek::{Signer, SigningKey};
    let sk = SigningKey::from_bytes(node_secret);
    let node = hex(sk.verifying_key().as_bytes());
    let ts = now();
    let mut n = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut n);
    let nonce = hex(&n);
    let digest = body_digest(body);
    let sig = sk.sign(&transcript(token, method, key, ts, &nonce, &digest));
    format!("Haven {node}.{ts}.{nonce}.{digest}.{}", hex(&sig.to_bytes()))
}

/// Verify an `Authorization: Haven …` value against the request head it claims to authorize.
/// Returns `(caller's node hex, the body digest they signed)` — i.e. WHO they are and what body
/// they committed to — or None. Everything here fails closed: a malformed header, an out-of-window
/// timestamp, a replayed nonce, or a bad signature all yield None.
///
/// Head-only by design: the caller checks the returned digest against the body afterwards, so an
/// unauthenticated peer can never make us read or allocate one.
fn verify_header(
    value: &str,
    token: &str,
    method: &str,
    key: &str,
    nonces: &Mutex<HashMap<String, u64>>,
) -> Option<(String, String)> {
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    let rest = value.trim().strip_prefix("Haven ")?;
    let mut parts = rest.trim().split('.');
    let (node, ts, nonce, digest, sig) =
        (parts.next()?, parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let ts: u64 = ts.parse().ok()?;
    let now = now();
    // Bound the window in BOTH directions: a far-future timestamp would otherwise mint a
    // credential valid long after the signer left the circle.
    if ts.abs_diff(now) > SKEW {
        return None;
    }
    if nonce.len() != 32 || unhex(nonce).is_none() || digest.len() != 64 || unhex(digest).is_none() {
        return None;
    }

    let vk = VerifyingKey::from_bytes(&unhex(node)?.try_into().ok()?).ok()?;
    let sig = Signature::from_slice(&unhex(sig)?).ok()?;
    vk.verify(&transcript(token, method, key, ts, nonce, digest), &sig).ok()?;

    // Signature is good — burn the nonce so this exact request can't be replayed inside the
    // skew window. Recorded per-signer, so one node can't invalidate another's nonces.
    let mut seen = nonces.lock().unwrap();
    seen.retain(|_, t| now.saturating_sub(*t) <= SKEW);
    if seen.insert(format!("{node}.{nonce}"), ts).is_some() {
        return None;
    }
    Some((node.to_string(), digest.to_string()))
}

/// Map an HTTP route onto the iroh path's verb, so both transports ask
/// [`blob_forbidden`] the same question.
fn verb_of(route: &Route) -> u8 {
    match route {
        Route::Get(_) => VERB_GET,
        Route::Head(_) => VERB_HAS,
        Route::Put(_) => VERB_PUT,
        Route::List(_) => VERB_LIST,
        Route::Touch(_) => VERB_TOUCH,
        Route::Bad => 0,
    }
}

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
/// `token` is the shared relay secret folded into each request signature (empty = none); `auth`
/// is the SAME circle-membership map the iroh path enforces, so the two transports cannot drift.
pub async fn serve(root: PathBuf, bind: &str, token: String, auth: Arc<Mutex<RelayAuth>>) -> Result<HttpRelay> {
    let addr: SocketAddr = bind.parse().map_err(|e| anyhow!("bad http bind {bind}: {e}"))?;
    let listener = TcpListener::bind(addr).await.map_err(|e| anyhow!("http bind {bind}: {e}"))?;
    let port = listener.local_addr()?.port();
    let token = Arc::new(token);
    let root = Arc::new(root);
    // Replay window, shared across connections (a nonce burnt on one socket must be burnt on all).
    let nonces: Arc<Mutex<HashMap<String, u64>>> = Arc::new(Mutex::new(HashMap::new()));
    let handle = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { continue };
            let (root, token, auth, nonces) = (root.clone(), token.clone(), auth.clone(), nonces.clone());
            tokio::spawn(async move {
                // Serial requests per connection (keep-alive); any parse error drops it.
                let _ = handle_conn(stream, &root, &token, &auth, &nonces).await;
            });
        }
    });
    Ok(HttpRelay { port, handle })
}

async fn handle_conn(
    stream: TcpStream,
    root: &PathBuf,
    token: &str,
    auth: &Arc<Mutex<RelayAuth>>,
    nonces: &Mutex<HashMap<String, u64>>,
) -> Result<()> {
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

        let route = route(&method, &path);
        let cap = match route {
            Route::Put(_) => MAX_BLOB,
            _ => MAX_TOUCH_BODY,
        };
        if clen > cap {
            discard(&mut r, clen.min(cap)).await.ok();
            respond(&mut w, 413, "too large", false, b"").await?;
            return Ok(()); // oversized body: drop the connection rather than drain it
        }

        // WHO is asking? A valid signature over this request's HEAD is the only answer; there is no
        // credential that merely asserts it. Unsigned/forged/replayed → 401 with no oracle about
        // whether the key exists. Answered before the body is touched, so an unauthenticated peer
        // cannot make us allocate a 256 MiB buffer.
        let signed = header(&headers, "authorization")
            .and_then(|v| verify_header(v, token, &method, route_key(&route), nonces));
        let Some((peer, digest)) = signed else {
            discard(&mut r, clen).await?;
            respond(&mut w, 401, "unauthorized", keep_alive, b"").await?;
            if !keep_alive { return Ok(()); }
            continue;
        };

        // MAY they? Same circle-membership gate as the iroh path, against the identity the
        // signature just proved.
        let key = checked(root, route_key(&route))
            .filter(|k| !blob_forbidden(auth, &peer, verb_of(&route), k));
        let Some(key) = key else {
            discard(&mut r, clen).await?;
            respond(&mut w, 403, "forbidden", keep_alive, b"").await?;
            if !keep_alive { return Ok(()); }
            continue;
        };

        // Now that we know the sender is a member, take the body — and hold them to the digest
        // they signed, so the authorized head and the stored bytes are one indivisible request.
        let mut body = vec![0u8; clen as usize];
        r.read_exact(&mut body).await?;
        if body_digest(&body) != digest {
            respond(&mut w, 400, "body mismatch", keep_alive, b"").await?;
            if !keep_alive { return Ok(()); }
            continue;
        }

        match route {
            Route::Get(_) => match local_get(root, &key) {
                Some(body) => respond(&mut w, 200, "OK", keep_alive, &body).await?,
                None => respond(&mut w, 404, "not found", keep_alive, b"").await?,
            },
            Route::Head(_) => {
                // A HAS hit refreshes the entry's liveness stamp (mailbox GC) — local_touch
                // returns the keys it did NOT find, so an empty result is a hit. Also avoids
                // local_get reading the whole blob just to answer an existence check.
                let hit = local_touch(root, &[key]).is_empty();
                head_respond(&mut w, if hit { 200 } else { 404 }, keep_alive).await?;
            }
            Route::Put(_) => {
                // A devroster PUT is deliberately un-gated by `blob_forbidden` (any signed peer may
                // publish, so a device the relay has never heard of can enroll) — which is ONLY safe
                // if the ACCOUNT SIGNATURE in the body is verified. The iroh path verifies; this path
                // did NOT, so a self-minted key could rename garbage over any account's roster over
                // plain HTTP (audit R6). Verify (with rollback defense) before storing, and expand
                // membership from the verified device ids just like the iroh path does.
                // A discovery record is un-gated by membership for the same reason and with the
                // same obligation: verify the body's SELF-signature (and its rollback defense)
                // before storing, or a self-minted key could shelve a forged address under any
                // node id. `verify_discovery_put` binds the record to the key and refuses a lower
                // `seq` than we already hold.
                if let Some(node) = crate::discovery::discovery_node(&key).map(str::to_string) {
                    match crate::discovery::verify_discovery_put(root, &node, &body) {
                        Some(_) => match local_put(root, &key, &body) {
                            Ok(()) => respond(&mut w, 200, "OK", keep_alive, b"OK").await?,
                            Err(_) => respond(&mut w, 500, "write failed", keep_alive, b"").await?,
                        },
                        None => respond(&mut w, 403, "forbidden", keep_alive, b"").await?,
                    }
                } else if let Some(acct) = key.strip_prefix(DEVROSTER_PREFIX) {
                    match verify_devroster_put(root, acct, &body) {
                        Some((account, devices)) => match local_put(root, &key, &body) {
                            Ok(()) => {
                                auth.lock().unwrap().authorize_devices(&account, &devices);
                                respond(&mut w, 200, "OK", keep_alive, b"OK").await?;
                            }
                            Err(_) => respond(&mut w, 500, "write failed", keep_alive, b"").await?,
                        },
                        // Unsigned/forged/wrong-account/stale roster → refuse, same as the read gate.
                        None => respond(&mut w, 403, "forbidden", keep_alive, b"").await?,
                    }
                } else {
                    match local_put(root, &key, &body) {
                        Ok(()) => respond(&mut w, 200, "OK", keep_alive, b"OK").await?,
                        Err(_) => respond(&mut w, 500, "write failed", keep_alive, b"").await?,
                    }
                }
            }
            Route::List(_) => {
                let mut keys = local_list(root, &key);
                keys.sort();
                respond(&mut w, 200, "OK", keep_alive, keys.join("\n").as_bytes()).await?;
            }
            Route::Touch(_) => {
                // Mailbox-GC liveness refresh: body = newline-joined keys; reply = the keys we do
                // NOT hold. Every listed key is re-authorized individually — the prefix was
                // authorized, but a body line is free to name anything.
                let want = if key.ends_with('/') { key.clone() } else { format!("{key}/") };
                let keys: Vec<String> = String::from_utf8_lossy(&body)
                    .lines()
                    .filter(|k| k.starts_with(&want) && checked(root, k).is_some())
                    .filter(|k| !blob_forbidden(auth, &peer, VERB_TOUCH, k))
                    .map(|k| k.to_string())
                    .collect();
                let misses = local_touch(root, &keys);
                respond(&mut w, 200, "OK", keep_alive, misses.join("\n").as_bytes()).await?;
            }
            Route::Bad => respond(&mut w, 404, "no route", keep_alive, b"").await?,
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

/// The store key/prefix a route names — the string the signature binds and the gate authorizes.
fn route_key(r: &Route) -> &str {
    match r {
        Route::Get(k) | Route::Head(k) | Route::Put(k) | Route::List(k) | Route::Touch(k) => k,
        Route::Bad => "",
    }
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

    /// A legitimate member's full round-trip — the path that must NOT regress. Everything here is
    /// what a real client does: sign each request with its node key, get served its own circle.
    #[tokio::test]
    async fn member_round_trip_and_stranger_refused() {
        use ed25519_dalek::SigningKey;

        let dir = std::env::temp_dir().join(format!("httprelay-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let member_sk = [7u8; 32];
        let stranger_sk = [9u8; 32];
        let member_hex = hex(SigningKey::from_bytes(&member_sk).verifying_key().as_bytes());

        let auth = Arc::new(Mutex::new(RelayAuth::default()));
        auth.lock().unwrap().authorize("fam", vec![member_hex], vec![]);

        let srv = serve(dir.clone(), "127.0.0.1:0", "tok".into(), auth).await.unwrap();
        let base = format!("127.0.0.1:{}", srv.port());

        // Raw client (std) — keep the test dependency-free.
        let req = move |verb: &str, path: &str, hdr: &str, body: &[u8]| {
            use std::io::{Read, Write};
            let mut s = std::net::TcpStream::connect(&base).unwrap();
            let head = format!(
                "{verb} {path} HTTP/1.1\r\nHost: x\r\n{hdr}Content-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            s.write_all(head.as_bytes()).unwrap();
            s.write_all(body).unwrap();
            let mut resp = Vec::new();
            s.read_to_end(&mut resp).unwrap();
            String::from_utf8_lossy(&resp).into_owned()
        };
        // Sign as `sk` would: the store key is the path minus its route prefix.
        let signed = |sk: &[u8; 32], verb: &str, path: &str, body: &[u8]| {
            let key = path.splitn(3, '/').nth(2).unwrap_or("");
            format!("Authorization: {}\r\n", auth_header(sk, "tok", verb, key, body))
        };

        let store = dir.clone();
        let blocking = tokio::task::spawn_blocking(move || {
            let m = &member_sk;
            let dir = store;

            // --- the legitimate member path ---
            assert!(req("PUT", "/k/haven/mailbox/fam/aa", &signed(m, "PUT", "/k/haven/mailbox/fam/aa", b"sealed"), b"sealed").starts_with("HTTP/1.1 200"));
            let got = req("GET", "/k/haven/mailbox/fam/aa", &signed(m, "GET", "/k/haven/mailbox/fam/aa", b""), b"");
            assert!(got.starts_with("HTTP/1.1 200") && got.ends_with("sealed"), "member reads own circle: {got}");
            assert!(req("PUT", "/k/haven/media/x", &signed(m, "PUT", "/k/haven/media/x", b"hello"), b"hello").starts_with("HTTP/1.1 200"));
            let got = req("GET", "/k/haven/media/x", &signed(m, "GET", "/k/haven/media/x", b""), b"");
            assert!(got.starts_with("HTTP/1.1 200") && got.ends_with("hello"), "member reads media: {got}");
            assert!(req("HEAD", "/k/haven/media/x", &signed(m, "HEAD", "/k/haven/media/x", b""), b"").starts_with("HTTP/1.1 200"));
            assert!(req("HEAD", "/k/haven/media/nope", &signed(m, "HEAD", "/k/haven/media/nope", b""), b"").starts_with("HTTP/1.1 404"));
            let l = req("GET", "/l/haven/mailbox/fam/", &signed(m, "GET", "/l/haven/mailbox/fam/", b""), b"");
            assert!(l.contains("haven/mailbox/fam/aa"), "member lists own circle: {l}");

            // TOUCH refreshes hits and reports misses (mailbox-GC liveness refresh).
            let tb = &b"haven/mailbox/fam/aa\nhaven/mailbox/fam/gone\nhaven/mailbox/other/bb"[..];
            let t = req("POST", "/t/haven/mailbox/fam/", &signed(m, "POST", "/t/haven/mailbox/fam/", tb), tb);
            assert!(t.starts_with("HTTP/1.1 200"), "{t}");
            assert!(t.ends_with("haven/mailbox/fam/gone"), "only the in-prefix miss is reported: {t}");
            assert!(!t.contains("other/bb"), "cross-circle keys are ignored: {t}");

            // --- what must not work ---
            // No signature at all.
            assert!(req("GET", "/k/haven/media/x", "", b"").starts_with("HTTP/1.1 401"));
            // A bearer token is no longer a credential — this is the pre-fix authorization.
            assert!(req("GET", "/k/haven/media/x", "Authorization: Bearer tok\r\n", b"").starts_with("HTTP/1.1 401"));
            // A validly-signed stranger who holds the token: authenticated, not authorized.
            let s = &stranger_sk;
            assert!(req("GET", "/k/haven/mailbox/fam/aa", &signed(s, "GET", "/k/haven/mailbox/fam/aa", b""), b"").starts_with("HTTP/1.1 403"));
            assert!(req("GET", "/k/haven/media/x", &signed(s, "GET", "/k/haven/media/x", b""), b"").starts_with("HTTP/1.1 403"));
            // Wrong shared secret → the signature does not verify (the token is mixed into it).
            let bad = format!("Authorization: {}\r\n", auth_header(m, "wrong", "GET", "haven/media/x", b""));
            assert!(req("GET", "/k/haven/media/x", &bad, b"").starts_with("HTTP/1.1 401"));
            // A signature is bound to its request: same header, different verb/key/body.
            let h = signed(m, "GET", "/k/haven/media/x", b"");
            assert!(req("GET", "/k/haven/media/other", &h, b"").starts_with("HTTP/1.1 401"), "key is bound");
            // Swapping the body under a signed head is caught by the digest it committed to.
            let h = signed(m, "PUT", "/k/haven/media/x", b"a");
            assert!(req("PUT", "/k/haven/media/x", &h, b"b").starts_with("HTTP/1.1 400"), "body is bound");
            assert_eq!(std::fs::read(dir.join("haven/media/x")).unwrap(), b"hello", "a mismatched body is not stored");
            // Replay of a byte-perfect capture.
            let h = signed(m, "GET", "/k/haven/media/x", b"");
            assert!(req("GET", "/k/haven/media/x", &h, b"").starts_with("HTTP/1.1 200"));
            assert!(req("GET", "/k/haven/media/x", &h, b"").starts_with("HTTP/1.1 401"), "nonce is one-shot");
            // Even a member may not enumerate across circles.
            assert!(req("GET", "/l/haven", &signed(m, "GET", "/l/haven", b""), b"").starts_with("HTTP/1.1 403"));
            // self/ refused outright — self-sync stays on the iroh path.
            assert!(req("GET", "/k/self/a/state/b", &signed(m, "GET", "/k/self/a/state/b", b""), b"").starts_with("HTTP/1.1 403"));
        });
        blocking.await.unwrap();
        srv.stop();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
