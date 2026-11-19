//! The path proxy serving the web client over a real socket: exact files with their types and
//! security headers, conditional requests, and nothing at all — bundle or not — for a path that
//! is not one of the bundle's names.

use std::sync::Arc;

use haven_net::webbundle::{WebBundle, CONTENT_SECURITY_POLICY};
use haven_net::{PathRouter, PathRouterConfig};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

async fn router(web_app: Option<Arc<WebBundle>>) -> PathRouter {
    PathRouter::spawn(&PathRouterConfig {
        bind: "127.0.0.1:0".into(),
        media_backend: String::new(),
        derp_backend: String::new(),
        http_token: String::new(),
        web_app,
    })
    .await
    .unwrap()
    .expect("router enabled")
}

fn bundle() -> Arc<WebBundle> {
    let mut b = WebBundle::new();
    assert!(b.insert("index.html", b"<!doctype html><title>Haven</title>".to_vec()));
    assert!(b.insert("pkg/haven_web_bg.wasm", vec![0, 97, 115, 109, 1, 0, 0, 0]));
    Arc::new(b)
}

/// One request; returns `(status line, lower-cased header block, body)`.
async fn request(r: &PathRouter, raw: &str) -> (String, String, Vec<u8>) {
    let mut s = TcpStream::connect(r.local_addr).await.unwrap();
    s.write_all(raw.as_bytes()).await.unwrap();
    let mut all = Vec::new();
    s.read_to_end(&mut all).await.unwrap();
    let split = all.windows(4).position(|w| w == b"\r\n\r\n").expect("a complete response head");
    let head = String::from_utf8(all[..split].to_vec()).unwrap();
    let (status, headers) = head.split_once("\r\n").unwrap_or((&head, ""));
    (status.to_string(), headers.to_ascii_lowercase(), all[split + 4..].to_vec())
}

fn get(path: &str) -> String {
    format!("GET {path} HTTP/1.1\r\nHost: relay.example\r\n\r\n")
}

#[tokio::test]
async fn serves_the_page_and_the_wasm_with_their_types_and_policy() {
    let r = router(Some(bundle())).await;
    let (status, headers, body) = request(&r, &get("/app/")).await;
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert_eq!(body, b"<!doctype html><title>Haven</title>");
    assert!(headers.contains("content-type: text/html; charset=utf-8"));
    assert!(headers.contains(&format!("content-security-policy: {}", CONTENT_SECURITY_POLICY.to_ascii_lowercase())));
    for h in [
        "x-content-type-options: nosniff", "referrer-policy: no-referrer", "cache-control: no-cache",
        "cross-origin-opener-policy: same-origin", "etag: \"",
    ] {
        assert!(headers.contains(h), "missing {h} in {headers}");
    }
    let (status, headers, body) = request(&r, &get("/app/pkg/haven_web_bg.wasm")).await;
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert!(headers.contains("content-type: application/wasm"), "streaming wasm compile needs the exact type");
    assert_eq!(body, [0, 97, 115, 109, 1, 0, 0, 0]);
}

#[tokio::test]
async fn head_sends_no_body_and_a_matching_etag_is_not_resent() {
    let r = router(Some(bundle())).await;
    let (status, headers, body) = request(&r, "HEAD /app/index.html HTTP/1.1\r\nHost: x\r\n\r\n").await;
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert!(body.is_empty() && headers.contains("content-length: 35"));
    let etag = headers.lines().find_map(|l| l.strip_prefix("etag: ")).unwrap().to_string();
    let (status, _, body) =
        request(&r, &format!("GET /app/index.html HTTP/1.1\r\nHost: x\r\nIf-None-Match: {etag}\r\n\r\n")).await;
    assert_eq!(status, "HTTP/1.1 304 Not Modified");
    assert!(body.is_empty());
    let (status, _, _) =
        request(&r, "GET /app/index.html HTTP/1.1\r\nHost: x\r\nIf-None-Match: \"stale\"\r\n\r\n").await;
    assert_eq!(status, "HTTP/1.1 200 OK");
}

#[tokio::test]
async fn the_bare_prefix_redirects_and_writes_are_refused() {
    let r = router(Some(bundle())).await;
    let (status, headers, _) = request(&r, &get("/app")).await;
    assert_eq!(status, "HTTP/1.1 308 Permanent Redirect");
    assert!(headers.contains("location: /app/"));
    for verb in ["POST", "PUT", "DELETE"] {
        let (status, _, _) = request(&r, &format!("{verb} /app/index.html HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")).await;
        assert_eq!(status, "HTTP/1.1 405 method not allowed", "{verb}");
    }
}

#[tokio::test]
async fn nothing_outside_the_bundle_is_reachable() {
    let r = router(Some(bundle())).await;
    for p in [
        "/app/../etc/passwd", "/app/%2e%2e/%2e%2e/etc/passwd", "/app/pkg/../index.html", "/app//index.html",
        "/app/pkg/", "/app/missing.js", "/app/index.html/", "/app/.env",
    ] {
        let (status, _, body) = request(&r, &get(p)).await;
        assert_eq!(status, "HTTP/1.1 404 not found", "{p}");
        assert_eq!(body, b"not part of the web client\n", "{p}");
    }
}

#[tokio::test]
async fn a_relay_without_web_access_serves_no_app_and_says_so_in_status() {
    for off in [None, Some(Arc::new(WebBundle::new()))] {
        let r = router(off).await;
        let (status, _, body) = request(&r, &get("/app/")).await;
        assert_eq!(status, "HTTP/1.1 404 no route");
        assert_eq!(body, b"this relay does not offer web access\n");
        let (_, _, status_json) = request(&r, "GET /_haven HTTP/1.1\r\nHost: x\r\nAccept: application/json\r\n\r\n").await;
        assert!(String::from_utf8_lossy(&status_json).contains("\"web\":null"));
    }
    let b = bundle();
    let r = router(Some(b.clone())).await;
    let (_, _, status_json) = request(&r, "GET /_haven HTTP/1.1\r\nHost: x\r\nAccept: application/json\r\n\r\n").await;
    let text = String::from_utf8_lossy(&status_json).to_string();
    assert!(text.contains(&format!("\"web\":{{\"path\":\"/app/\",\"files\":2,\"digest\":\"{}\"}}", b.digest())), "{text}");
}

/// A backend that records one request (head + body by Content-Length) and answers `200 stored`.
async fn recording_backend() -> (String, tokio::sync::oneshot::Receiver<Vec<u8>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let (tx, rx) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        let (mut s, _) = listener.accept().await.unwrap();
        let mut got = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            let n = s.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            got.extend_from_slice(&buf[..n]);
            if let Some(end) = got.windows(4).position(|w| w == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&got[..end]).to_ascii_lowercase();
                let len: usize = head
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length:"))
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0);
                if got.len() >= end + 4 + len {
                    break;
                }
            }
        }
        s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nstored").await.unwrap();
        let _ = s.shutdown().await;
        let _ = tx.send(got);
    });
    (addr, rx)
}

/// The upload that was being lost: head and binary body in ONE write. It must reach the media
/// backend whole — not be answered by the proxy's own status page.
#[tokio::test]
async fn a_binary_upload_sent_in_one_segment_reaches_the_media_backend_intact() {
    let (backend, received) = recording_backend().await;
    let r = PathRouter::spawn(&PathRouterConfig {
        bind: "127.0.0.1:0".into(),
        media_backend: backend,
        derp_backend: String::new(),
        http_token: String::new(),
        web_app: None,
    })
    .await
    .unwrap()
    .unwrap();
    let body: Vec<u8> = (0u8..=255).rev().cycle().take(7259).collect();
    let mut req = format!(
        "PUT /k/haven/media/img_abc HTTP/1.1\r\nHost: relay.example\r\nContent-Length: {}\r\nAuthorization: Haven x\r\n\r\n",
        body.len()
    )
    .into_bytes();
    req.extend_from_slice(&body);

    let mut s = TcpStream::connect(r.local_addr).await.unwrap();
    s.write_all(&req).await.unwrap(); // one write: head + body together
    let mut answer = Vec::new();
    s.read_to_end(&mut answer).await.unwrap();
    let answer = String::from_utf8_lossy(&answer).to_string();
    assert!(answer.starts_with("HTTP/1.1 200") && answer.ends_with("stored"), "answered by the backend: {answer}");

    let got = tokio::time::timeout(std::time::Duration::from_secs(5), received).await.expect("the backend saw it").unwrap();
    let split = got.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
    assert!(String::from_utf8_lossy(&got[..split]).starts_with("PUT /k/haven/media/img_abc HTTP/1.1\r\n"));
    assert_eq!(&got[split..], &body[..], "every body byte arrived");
}

#[tokio::test]
async fn an_unparseable_request_is_a_400_not_the_status_page() {
    let r = router(None).await;
    let mut s = TcpStream::connect(r.local_addr).await.unwrap();
    s.write_all(b"\xff\xfe\xfd garbage\r\n\r\n").await.unwrap();
    let mut answer = Vec::new();
    s.read_to_end(&mut answer).await.unwrap();
    assert!(String::from_utf8_lossy(&answer).starts_with("HTTP/1.1 400"), "{}", String::from_utf8_lossy(&answer));
}
