//! Integration: path proxy status routes + WebSocket call-media hairpin pairing.
//!
//! This is the automated stand-in for “Mac + peers use a Haven relay fabric”:
//! free-CF-compatible WSS hairpin and `/_haven` route table without UDP TURN.
//!
//! Run: `cargo test -p haven-net --test path_proxy_hairpin`

use std::time::Duration;

use anyhow::{bail, Result};
use haven_net::{PathRouter, PathRouterConfig};
use sha1::{Digest, Sha1};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;

const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn accept_key(key: &str) -> String {
    let mut h = Sha1::new();
    h.update(key.as_bytes());
    h.update(WS_GUID.as_bytes());
    data_encoding::BASE64.encode(&h.finalize())
}

async fn http_get(addr: &str, path: &str) -> Result<(u16, String)> {
    let mut s = TcpStream::connect(addr).await?;
    let req = format!("GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    s.write_all(req.as_bytes()).await?;
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).await?;
    let text = String::from_utf8_lossy(&buf);
    let status = text
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse().ok())
        .unwrap_or(0);
    Ok((status, text.into_owned()))
}

async fn ws_client(addr: &str, path: &str) -> Result<TcpStream> {
    let mut s = TcpStream::connect(addr).await?;
    let key = data_encoding::BASE64.encode(b"haven-test-nonce-12");
    let req = format!(
        "GET {path} HTTP/1.1\r\n\
         Host: x\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: {key}\r\n\
         Sec-WebSocket-Version: 13\r\n\
         \r\n"
    );
    s.write_all(req.as_bytes()).await?;
    let mut head = Vec::new();
    let mut buf = [0u8; 512];
    loop {
        let n = s.read(&mut buf).await?;
        if n == 0 {
            bail!("eof during handshake");
        }
        head.extend_from_slice(&buf[..n]);
        if head.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    let text = String::from_utf8_lossy(&head);
    if !text.starts_with("HTTP/1.1 101") {
        bail!("expected 101, got: {}", text.lines().next().unwrap_or(""));
    }
    let want = accept_key(&key);
    if !text.contains(&want) {
        bail!("bad Sec-WebSocket-Accept");
    }
    Ok(s)
}

fn mask_key() -> [u8; 4] {
    [0x11, 0x22, 0x33, 0x44]
}

async fn ws_send_text(s: &mut TcpStream, text: &str) -> Result<()> {
    let payload = text.as_bytes();
    let mask = mask_key();
    let mut frame = Vec::new();
    frame.push(0x81); // FIN + text
    let n = payload.len();
    if n < 126 {
        frame.push(0x80 | (n as u8));
    } else {
        frame.push(0x80 | 126);
        frame.extend_from_slice(&(n as u16).to_be_bytes());
    }
    frame.extend_from_slice(&mask);
    for (i, b) in payload.iter().enumerate() {
        frame.push(b ^ mask[i % 4]);
    }
    s.write_all(&frame).await?;
    Ok(())
}

async fn ws_send_binary(s: &mut TcpStream, data: &[u8]) -> Result<()> {
    let mask = mask_key();
    let mut frame = Vec::new();
    frame.push(0x82); // FIN + binary
    let n = data.len();
    if n < 126 {
        frame.push(0x80 | (n as u8));
    } else {
        frame.push(0x80 | 126);
        frame.extend_from_slice(&(n as u16).to_be_bytes());
    }
    frame.extend_from_slice(&mask);
    for (i, b) in data.iter().enumerate() {
        frame.push(b ^ mask[i % 4]);
    }
    s.write_all(&frame).await?;
    Ok(())
}

async fn ws_read_message(s: &mut TcpStream) -> Result<(u8, Vec<u8>)> {
    let mut b0 = [0u8; 2];
    s.read_exact(&mut b0).await?;
    let opcode = b0[0] & 0x0f;
    let masked = b0[1] & 0x80 != 0;
    let mut len = (b0[1] & 0x7f) as usize;
    if len == 126 {
        let mut ext = [0u8; 2];
        s.read_exact(&mut ext).await?;
        len = u16::from_be_bytes(ext) as usize;
    }
    let mut mask = [0u8; 4];
    if masked {
        s.read_exact(&mut mask).await?;
    }
    let mut payload = vec![0u8; len];
    if len > 0 {
        s.read_exact(&mut payload).await?;
    }
    if masked {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= mask[i % 4];
        }
    }
    Ok((opcode, payload))
}

async fn ws_read_text(s: &mut TcpStream) -> Result<String> {
    loop {
        let (op, payload) = ws_read_message(s).await?;
        if op == 0x1 {
            return Ok(String::from_utf8(payload)?);
        }
        if op == 0x8 {
            bail!("closed");
        }
        // skip ping/pong
    }
}

#[tokio::test]
async fn path_proxy_status_lists_hairpin() -> Result<()> {
    let router = PathRouter::spawn(&PathRouterConfig {
        bind: "127.0.0.1:0".into(),
        media_backend: String::new(),
        derp_backend: String::new(),
        http_token: String::new(),
    })
    .await?
    .expect("router");
    let addr = format!("127.0.0.1:{}", router.local_port());

    let (status, body) = timeout(Duration::from_secs(5), http_get(&addr, "/_haven")).await??;
    assert_eq!(status, 200, "{body}");
    assert!(body.contains("haven-path-proxy"), "{body}");
    assert!(body.contains("hairpin"), "{body}");
    assert!(body.contains("/webrtc"), "{body}");
    Ok(())
}

#[tokio::test]
async fn hairpin_pairs_and_forwards_binary() -> Result<()> {
    let router = PathRouter::spawn(&PathRouterConfig {
        bind: "127.0.0.1:0".into(),
        media_backend: String::new(),
        derp_backend: String::new(),
        http_token: String::new(),
    })
    .await?
    .expect("router");
    let addr = format!("127.0.0.1:{}", router.local_port());
    let path = "/webrtc/hairpin";

    let mut a = timeout(Duration::from_secs(5), ws_client(&addr, path)).await??;
    let mut b = timeout(Duration::from_secs(5), ws_client(&addr, path)).await??;

    let session = "test-session-1";
    let peer_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let peer_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    ws_send_text(
        &mut a,
        &format!(r#"{{"v":1,"session":"{session}","peer":"{peer_a}","remote":"{peer_b}"}}"#),
    )
    .await?;
    // A should get waiting
    let t_a1 = timeout(Duration::from_secs(5), ws_read_text(&mut a)).await??;
    assert!(t_a1.contains("waiting") || t_a1.contains("ok"), "{t_a1}");

    ws_send_text(
        &mut b,
        &format!(r#"{{"v":1,"session":"{session}","peer":"{peer_b}","remote":"{peer_a}"}}"#),
    )
    .await?;

    // Both should see paired
    let t_a2 = timeout(Duration::from_secs(5), ws_read_text(&mut a)).await??;
    assert!(t_a2.contains("paired") || t_a2.contains("\"ok\":true"), "{t_a2}");
    let t_b = timeout(Duration::from_secs(5), ws_read_text(&mut b)).await??;
    assert!(t_b.contains("paired") || t_b.contains("\"ok\":true"), "{t_b}");

    // Binary A → B
    let payload = b"haven-hairpin-pcm-chunk";
    ws_send_binary(&mut a, payload).await?;
    let (op, got) = timeout(Duration::from_secs(5), ws_read_message(&mut b)).await??;
    assert_eq!(op, 0x2, "expected binary opcode");
    assert_eq!(got, payload);

    // Binary B → A
    let payload2 = b"reply-chunk";
    ws_send_binary(&mut b, payload2).await?;
    let (op2, got2) = timeout(Duration::from_secs(5), ws_read_message(&mut a)).await??;
    assert_eq!(op2, 0x2);
    assert_eq!(got2, payload2);

    Ok(())
}

#[test]
fn fabric_policy_haven_first() {
    // Empty → n0 fallback.
    haven_net::apply_derp_urls(vec![]);
    assert!(!haven_net::haven_fabric_active());
    let p = haven_net::endpoint_policy();
    assert!(p.use_n0_relays);

    // Non-empty → Haven only, n0 off.
    haven_net::apply_derp_urls(vec!["https://relay.example.com".into()]);
    assert!(haven_net::haven_fabric_active());
    let p = haven_net::endpoint_policy();
    assert!(!p.use_n0_relays);
    assert!(p.prefer_custom_relays);
    assert_eq!(p.custom_derp_urls, vec!["https://relay.example.com".to_string()]);

    // Restore n0 for other tests in the process.
    haven_net::apply_derp_urls(vec![]);
}
