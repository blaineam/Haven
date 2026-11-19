//! Uploads through the path proxy over a real socket: a request whose binary body arrives in the
//! same segment as its head must reach the media backend whole, and a request that cannot be
//! parsed is refused rather than answered with the proxy's status page.

use haven_net::{PathRouter, PathRouterConfig};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

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
    let r = PathRouter::spawn(&PathRouterConfig {
        bind: "127.0.0.1:0".into(),
        media_backend: String::new(),
        derp_backend: String::new(),
        http_token: String::new(),
        web_app: None,
    })
    .await
    .unwrap()
    .unwrap();
    let mut s = TcpStream::connect(r.local_addr).await.unwrap();
    s.write_all(b"\xff\xfe\xfd garbage\r\n\r\n").await.unwrap();
    let mut answer = Vec::new();
    s.read_to_end(&mut answer).await.unwrap();
    assert!(String::from_utf8_lossy(&answer).starts_with("HTTP/1.1 400"), "{}", String::from_utf8_lossy(&answer));
}
