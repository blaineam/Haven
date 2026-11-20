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

#[tokio::test]
async fn a_client_that_accepts_gzip_gets_the_compressed_body_and_others_get_it_plain() {
    use std::io::Read;
    let script: Vec<u8> = b"export const haven = 'private little place';\n".iter().cycle().take(60_000).copied().collect();
    let mut b = WebBundle::new();
    assert!(b.insert("index.html", b"<!doctype html>".to_vec()));
    assert!(b.insert("app.js", script.clone()));
    let r = router(Some(Arc::new(b))).await;

    let (status, headers, body) = request(&r, "GET /app/app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br, gzip;q=0.9\r\n\r\n").await;
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert!(headers.contains("content-encoding: gzip") && headers.contains("vary: accept-encoding"));
    assert!(body.len() < script.len() / 2, "compressed on the wire");
    let mut plain = Vec::new();
    flate2::read::GzDecoder::new(&body[..]).read_to_end(&mut plain).unwrap();
    assert_eq!(plain, script);
    let gz_etag = headers.lines().find_map(|l| l.strip_prefix("etag: ")).unwrap().to_string();

    let (status, headers, body) = request(&r, &get("/app/app.js")).await;
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert!(!headers.contains("content-encoding"));
    assert_eq!(body, script);
    let plain_etag = headers.lines().find_map(|l| l.strip_prefix("etag: ")).unwrap().to_string();
    assert_ne!(gz_etag, plain_etag, "the two representations have different validators");

    // Revalidation works per representation.
    let (status, _, _) = request(&r, &format!("GET /app/app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nIf-None-Match: {gz_etag}\r\n\r\n")).await;
    assert_eq!(status, "HTTP/1.1 304 Not Modified");
    let (status, _, _) = request(&r, &format!("GET /app/app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nIf-None-Match: {plain_etag}\r\n\r\n")).await;
    assert_eq!(status, "HTTP/1.1 200 OK");

    // A small file is served as it is, whatever the client accepts.
    let (_, headers, _) = request(&r, "GET /app/ HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n").await;
    assert!(!headers.contains("content-encoding"));
}
