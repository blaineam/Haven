//! **WebSocket call-media hairpin** — TCP/TLS-friendly media path through free Cloudflare.
//!
//! Free trycloudflare and named HTTP tunnels carry **HTTPS + WebSocket**, not UDP TURN.
//! This module pairs two peers in a call session and bipipes opaque binary frames so
//! call media can hairpin over the same public origin as the path proxy:
//!
//! ```text
//! peer A ──WSS /webrtc/hairpin──► path-proxy ──WSS──► peer B
//!           (free CF tunnel OK)      (pair by session)
//! ```
//!
//! ## Protocol (v1)
//!
//! 1. Client opens WebSocket to `wss://<fabric-or-media-host>/webrtc/hairpin`
//!    (or `/webrtc`).
//! 2. First **text** frame is JSON:
//!    ```json
//!    {"v":1,"session":"<callSessionId>","peer":"<myNodeHex>","remote":"<otherNodeHex>"}
//!    ```
//! 3. Server replies text `{"ok":true}` when paired (or `{"ok":true,"waiting":true}` while
//!    waiting for the remote). On error: `{"ok":false,"err":"…"}` then close.
//! 4. After pair, both sides send **binary** frames (opaque media / DTLS / app codec).
//!    The proxy re-frames them WebSocket-to-WebSocket (no interpretation).
//!
//! Pairing key: `session` + sorted(`peer`,`remote`). First arrival waits up to
//! [`PAIR_TIMEOUT`]; second completes the pair. Drop unpaired slots on timeout.
//!
//! Auth is deliberately light: knowing the session id (from sealed call signaling) is the
//! gate — same trust model as learning a DERP URL via frame 19. Optional `token` field may
//! match the relay `http_token` when configured.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use data_encoding::BASE64;
use sha1::{Digest, Sha1};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{oneshot, Mutex};
use tokio::time::timeout;

/// How long the first peer waits for its remote before giving up.
pub const PAIR_TIMEOUT: Duration = Duration::from_secs(90);

/// WebSocket magic GUID (RFC 6455).
const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ── Hub ──────────────────────────────────────────────────────────────────────

struct Waiting {
    peer: String,
    /// Receives the partner stream once the second peer joins.
    deliver: oneshot::Sender<TcpStream>,
}

/// Shared pairing registry for one path-proxy instance.
#[derive(Default)]
pub struct HairpinHub {
    inner: Mutex<HashMap<String, Waiting>>,
}

impl HairpinHub {
    pub fn new() -> Self {
        Self::default()
    }

    fn pair_key(session: &str, a: &str, b: &str) -> String {
        let a = a.trim().to_lowercase();
        let b = b.trim().to_lowercase();
        let session = session.trim();
        if a <= b {
            format!("{session}\0{a}\0{b}")
        } else {
            format!("{session}\0{b}\0{a}")
        }
    }
}

// ── Public entry ─────────────────────────────────────────────────────────────

/// Handle a client that requested `/webrtc…` — must already have the HTTP request head.
///
/// `http_token` when non-empty: if the join JSON includes `token`, it must match.
pub async fn handle_hairpin(
    mut client: TcpStream,
    head: &[u8],
    hub: Arc<HairpinHub>,
    http_token: &str,
) -> Result<()> {
    if !is_websocket_upgrade(head) {
        write_http(
            &mut client,
            426,
            "Upgrade Required",
            b"WebSocket upgrade required (use /webrtc/hairpin)\n",
        )
        .await?;
        return Ok(());
    }
    let key = sec_websocket_key(head).ok_or_else(|| anyhow!("missing Sec-WebSocket-Key"))?;
    complete_websocket_handshake(&mut client, &key).await?;

    // First text frame = join message.
    let join = match read_ws_text(&mut client).await {
        Ok(t) => t,
        Err(e) => {
            let _ = send_ws_text(&mut client, &format!(r#"{{"ok":false,"err":"join read: {e}"}}"#)).await;
            let _ = send_ws_close(&mut client).await;
            return Err(e);
        }
    };
    let (session, peer, remote, token) = parse_join(&join)?;
    if session.is_empty() || peer.is_empty() || remote.is_empty() {
        let _ = send_ws_text(&mut client, r#"{"ok":false,"err":"session, peer, remote required"}"#).await;
        let _ = send_ws_close(&mut client).await;
        bail!("invalid join");
    }
    // Bound join fields — reject pathological / probe garbage before parking a slot.
    if session.len() > 128 || peer.len() > 128 || remote.len() > 128 {
        let _ = send_ws_text(&mut client, r#"{"ok":false,"err":"field too long"}"#).await;
        let _ = send_ws_close(&mut client).await;
        bail!("join field too long");
    }
    if peer.eq_ignore_ascii_case(&remote) {
        let _ = send_ws_text(&mut client, r#"{"ok":false,"err":"peer cannot equal remote"}"#).await;
        let _ = send_ws_close(&mut client).await;
        bail!("self join");
    }
    if !http_token.is_empty() {
        // Optional: if client sends token it must match; if omitted, session knowledge is enough.
        if !token.is_empty() && token != http_token {
            let _ = send_ws_text(&mut client, r#"{"ok":false,"err":"bad token"}"#).await;
            let _ = send_ws_close(&mut client).await;
            bail!("bad token");
        }
    }

    let key = HairpinHub::pair_key(&session, &peer, &remote);
    let partner = {
        let mut map = hub.inner.lock().await;
        if let Some(waiting) = map.remove(&key) {
            // Second peer must be the first peer's `remote`.
            if !waiting.peer.eq_ignore_ascii_case(&remote) {
                map.insert(key, waiting);
                drop(map);
                let _ = send_ws_text(
                    &mut client,
                    r#"{"ok":false,"err":"peer mismatch for session"}"#,
                )
                .await;
                let _ = send_ws_close(&mut client).await;
                bail!("peer mismatch");
            }
            // Hand our stream to the waiter; their task bipipes both sides.
            if waiting.deliver.send(client).is_err() {
                bail!("partner gone");
            }
            return Ok(());
        }
        // First peer — park and wait for remote.
        let (tx, rx) = oneshot::channel();
        map.insert(
            key.clone(),
            Waiting {
                peer: peer.clone(),
                deliver: tx,
            },
        );
        drop(map);
        let _ = send_ws_text(&mut client, r#"{"ok":true,"waiting":true}"#).await;
        match timeout(PAIR_TIMEOUT, rx).await {
            Ok(Ok(partner)) => partner,
            Ok(Err(_)) => {
                hub.inner.lock().await.remove(&key);
                let _ = send_ws_text(&mut client, r#"{"ok":false,"err":"cancelled"}"#).await;
                let _ = send_ws_close(&mut client).await;
                bail!("pair cancelled");
            }
            Err(_) => {
                hub.inner.lock().await.remove(&key);
                let _ = send_ws_text(&mut client, r#"{"ok":false,"err":"pair timeout"}"#).await;
                let _ = send_ws_close(&mut client).await;
                bail!("pair timeout");
            }
        }
    };

    let _ = send_ws_text(&mut client, r#"{"ok":true,"paired":true}"#).await;
    bipipe_ws(client, partner).await
}

// ── WebSocket framing ────────────────────────────────────────────────────────

fn is_websocket_upgrade(head: &[u8]) -> bool {
    let s = std::str::from_utf8(head).unwrap_or("");
    let lower = s.to_ascii_lowercase();
    lower.contains("upgrade: websocket") && lower.contains("connection:") && lower.contains("upgrade")
}

fn sec_websocket_key(head: &[u8]) -> Option<String> {
    let s = std::str::from_utf8(head).ok()?;
    for line in s.lines() {
        let line = line.trim();
        if let Some(rest) = line
            .strip_prefix("Sec-WebSocket-Key:")
            .or_else(|| line.strip_prefix("sec-websocket-key:"))
        {
            return Some(rest.trim().to_string());
        }
    }
    None
}

fn accept_key(client_key: &str) -> String {
    let mut h = Sha1::new();
    h.update(client_key.as_bytes());
    h.update(WS_GUID.as_bytes());
    BASE64.encode(&h.finalize())
}

async fn complete_websocket_handshake(client: &mut TcpStream, key: &str) -> Result<()> {
    let accept = accept_key(key);
    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Accept: {accept}\r\n\
         \r\n"
    );
    client.write_all(resp.as_bytes()).await?;
    Ok(())
}

async fn write_http(client: &mut TcpStream, status: u16, reason: &str, body: &[u8]) -> Result<()> {
    let resp = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n",
        body.len()
    );
    client.write_all(resp.as_bytes()).await?;
    client.write_all(body).await?;
    let _ = client.shutdown().await;
    Ok(())
}

/// Read one complete WebSocket message (text). Handles continuation, rejects binary for join.
async fn read_ws_text(stream: &mut TcpStream) -> Result<String> {
    let mut assembled = Vec::new();
    loop {
        let (opcode, payload, fin) = read_ws_frame(stream).await?;
        match opcode {
            0x1 => {
                // text
                assembled.extend_from_slice(&payload);
                if fin {
                    return String::from_utf8(assembled).map_err(|e| anyhow!("utf8: {e}"));
                }
            }
            0x0 => {
                // continuation
                assembled.extend_from_slice(&payload);
                if fin {
                    return String::from_utf8(assembled).map_err(|e| anyhow!("utf8: {e}"));
                }
            }
            0x2 => bail!("expected text join frame, got binary"),
            0x8 => bail!("peer closed during join"),
            0x9 => {
                // ping → pong
                send_ws_frame(stream, 0xA, &payload).await?;
            }
            0xA => {}
            _ => {}
        }
    }
}

async fn send_ws_text(stream: &mut TcpStream, text: &str) -> Result<()> {
    send_ws_frame(stream, 0x1, text.as_bytes()).await
}

async fn send_ws_close(stream: &mut TcpStream) -> Result<()> {
    send_ws_frame(stream, 0x8, &[]).await
}

/// Server→client frame (unmasked).
async fn send_ws_frame(stream: &mut TcpStream, opcode: u8, payload: &[u8]) -> Result<()> {
    let mut hdr = Vec::with_capacity(10 + payload.len());
    hdr.push(0x80 | (opcode & 0x0f)); // FIN + opcode
    let n = payload.len();
    if n < 126 {
        hdr.push(n as u8);
    } else if n <= 65535 {
        hdr.push(126);
        hdr.extend_from_slice(&(n as u16).to_be_bytes());
    } else {
        hdr.push(127);
        hdr.extend_from_slice(&(n as u64).to_be_bytes());
    }
    hdr.extend_from_slice(payload);
    stream.write_all(&hdr).await?;
    Ok(())
}

async fn read_ws_frame(stream: &mut TcpStream) -> Result<(u8, Vec<u8>, bool)> {
    let mut b0 = [0u8; 2];
    stream.read_exact(&mut b0).await?;
    let fin = b0[0] & 0x80 != 0;
    let opcode = b0[0] & 0x0f;
    let masked = b0[1] & 0x80 != 0;
    let mut len = (b0[1] & 0x7f) as u64;
    if len == 126 {
        let mut ext = [0u8; 2];
        stream.read_exact(&mut ext).await?;
        len = u16::from_be_bytes(ext) as u64;
    } else if len == 127 {
        let mut ext = [0u8; 8];
        stream.read_exact(&mut ext).await?;
        len = u64::from_be_bytes(ext);
    }
    if len > 16 * 1024 * 1024 {
        bail!("ws frame too large ({len})");
    }
    let mut mask = [0u8; 4];
    if masked {
        stream.read_exact(&mut mask).await?;
    }
    let mut payload = vec![0u8; len as usize];
    if len > 0 {
        stream.read_exact(&mut payload).await?;
    }
    if masked {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= mask[i % 4];
        }
    }
    Ok((opcode, payload, fin))
}

/// Relay WebSocket messages both ways until either side closes.
async fn bipipe_ws(mut a: TcpStream, mut b: TcpStream) -> Result<()> {
    // Notify B it is paired (A already got paired:true before calling us).
    let _ = send_ws_text(&mut b, r#"{"ok":true,"paired":true}"#).await;

    let (mut ar, aw) = a.split();
    let (mut br, bw) = b.split();
    // Mutex so each direction can pong on its own write half without aliasing borrows.
    let aw = Arc::new(Mutex::new(aw));
    let bw = Arc::new(Mutex::new(bw));

    let a2b = {
        let aw = Arc::clone(&aw);
        let bw = Arc::clone(&bw);
        async move { relay_one_way(&mut ar, bw, aw).await }
    };
    let b2a = {
        let aw = Arc::clone(&aw);
        let bw = Arc::clone(&bw);
        async move { relay_one_way(&mut br, aw, bw).await }
    };

    tokio::select! {
        r = a2b => { let _ = r; }
        r = b2a => { let _ = r; }
    }
    Ok(())
}

/// `fwd` = write half toward the peer; `pong` = write half back to the reader side.
async fn relay_one_way<R, W, W2>(
    reader: &mut R,
    fwd: Arc<Mutex<W>>,
    pong: Arc<Mutex<W2>>,
) -> Result<()>
where
    R: AsyncReadExt + Unpin,
    W: AsyncWriteExt + Unpin,
    W2: AsyncWriteExt + Unpin,
{
    loop {
        let (opcode, payload, _fin) = read_ws_frame_rw(reader).await?;
        match opcode {
            0x8 => {
                let mut w = fwd.lock().await;
                let _ = send_ws_frame_rw(&mut *w, 0x8, &payload).await;
                break;
            }
            0x9 => {
                let mut w = pong.lock().await;
                let _ = send_ws_frame_rw(&mut *w, 0xA, &payload).await;
            }
            0xA => {}
            0x1 | 0x2 | 0x0 => {
                let op = if opcode == 0x0 { 0x2 } else { opcode };
                let mut w = fwd.lock().await;
                send_ws_frame_rw(&mut *w, op, &payload).await?;
            }
            _ => {}
        }
    }
    Ok(())
}

async fn read_ws_frame_rw<R: AsyncReadExt + Unpin>(stream: &mut R) -> Result<(u8, Vec<u8>, bool)> {
    let mut b0 = [0u8; 2];
    stream.read_exact(&mut b0).await?;
    let fin = b0[0] & 0x80 != 0;
    let opcode = b0[0] & 0x0f;
    let masked = b0[1] & 0x80 != 0;
    let mut len = (b0[1] & 0x7f) as u64;
    if len == 126 {
        let mut ext = [0u8; 2];
        stream.read_exact(&mut ext).await?;
        len = u16::from_be_bytes(ext) as u64;
    } else if len == 127 {
        let mut ext = [0u8; 8];
        stream.read_exact(&mut ext).await?;
        len = u64::from_be_bytes(ext);
    }
    if len > 16 * 1024 * 1024 {
        bail!("ws frame too large ({len})");
    }
    let mut mask = [0u8; 4];
    if masked {
        stream.read_exact(&mut mask).await?;
    }
    let mut payload = vec![0u8; len as usize];
    if len > 0 {
        stream.read_exact(&mut payload).await?;
    }
    if masked {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= mask[i % 4];
        }
    }
    Ok((opcode, payload, fin))
}

async fn send_ws_frame_rw<W: AsyncWriteExt + Unpin>(
    stream: &mut W,
    opcode: u8,
    payload: &[u8],
) -> Result<()> {
    let mut hdr = Vec::with_capacity(10 + payload.len());
    hdr.push(0x80 | (opcode & 0x0f));
    let n = payload.len();
    if n < 126 {
        hdr.push(n as u8);
    } else if n <= 65535 {
        hdr.push(126);
        hdr.extend_from_slice(&(n as u16).to_be_bytes());
    } else {
        hdr.push(127);
        hdr.extend_from_slice(&(n as u64).to_be_bytes());
    }
    hdr.extend_from_slice(payload);
    stream.write_all(&hdr).await?;
    Ok(())
}

fn parse_join(text: &str) -> Result<(String, String, String, String)> {
    let v: serde_json::Value =
        serde_json::from_str(text).map_err(|e| anyhow!("join json: {e}"))?;
    let session = v
        .get("session")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let peer = v
        .get("peer")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let remote = v
        .get("remote")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let token = v
        .get("token")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    Ok((session, peer, remote, token))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pair_key_symmetric() {
        let k1 = HairpinHub::pair_key("sess", "aaa", "bbb");
        let k2 = HairpinHub::pair_key("sess", "bbb", "aaa");
        assert_eq!(k1, k2);
    }

    #[test]
    fn accept_key_known_vector() {
        // RFC 6455 example: key dGhlIHNhbXBsZSBub25jZQ== → accept s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
        let a = accept_key("dGhlIHNhbXBsZSBub25jZQ==");
        assert_eq!(a, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    }

    #[test]
    fn parse_join_ok() {
        let (s, p, r, t) = parse_join(
            r#"{"v":1,"session":"abc","peer":"aa","remote":"bb","token":"tok"}"#,
        )
        .unwrap();
        assert_eq!(s, "abc");
        assert_eq!(p, "aa");
        assert_eq!(r, "bb");
        assert_eq!(t, "tok");
    }
}
