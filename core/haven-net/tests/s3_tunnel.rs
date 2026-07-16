//! The media store-and-forward proof: bytes flow consumer → loopback → iroh tunnel →
//! relay → local "store", and back, with the relay acting as a pure byte-pump.
//!
//! We stand in a trivial echo TCP server for `rclone serve s3` (the tunnel doesn't care
//! what speaks S3 on the other end — it only splices bytes). A real deployment points it
//! at `rclone serve s3 127.0.0.1:8333`.

use haven_net::s3tunnel::{tunnel_to_addr, S3Server};
use haven_p2p::identity::Identity;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn s3_bytes_round_trip_through_the_iroh_tunnel() {
    // 1. A local "store" (echo server) the relay will splice to — stands in for rclone.
    let store = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let store_addr = store.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = store.accept().await else { break };
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                loop {
                    match sock.read(&mut buf).await {
                        Ok(n) if n > 0 => {
                            // Echo an "S3 response" prefix + the request back.
                            let mut out = b"HTTP/1.1 200 OK\r\n\r\n".to_vec();
                            out.extend_from_slice(&buf[..n]);
                            if sock.write_all(&out).await.is_err() {
                                break;
                            }
                        }
                        _ => break,
                    }
                }
            });
        }
    });

    // 2. Relay side: serve the local store over iroh (haven/s3/1), using its identity key.
    let relay_id = Identity::generate();
    let server = S3Server::spawn(relay_id.node_secret_bytes(), store_addr).await.unwrap();
    // Same-machine: dial the relay's loopback address directly (no discovery needed).
    let relay_addr = server.local_dial_addr().await.unwrap();

    // 3. Consumer side: open a loopback tunnel to the relay.
    let consumer_id = Identity::generate();
    let local = tunnel_to_addr(consumer_id.node_secret_bytes(), relay_addr).await.unwrap();

    // 4. The "S3 client" connects to the loopback and sends an S3-shaped request.
    let req = b"PUT /haven/media/abc123 HTTP/1.1\r\nHost: x\r\n\r\nSEALED-BLOB-BYTES";
    let mut client = TcpStream::connect(local).await.unwrap();
    client.write_all(req).await.unwrap();

    let mut resp = Vec::new();
    let read = timeout(Duration::from_secs(10), async {
        let mut buf = [0u8; 4096];
        // Read until we have the echoed payload back.
        loop {
            let n = client.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            resp.extend_from_slice(&buf[..n]);
            if resp.windows(req.len()).any(|w| w == req) {
                break;
            }
        }
    })
    .await;
    read.expect("tunnel round-trip timed out");

    assert!(
        resp.windows(req.len()).any(|w| w == req),
        "the sealed S3 request must travel through the iroh tunnel to the store and back"
    );
    assert!(resp.starts_with(b"HTTP/1.1 200 OK"), "store response framing preserved");

    let _ = &server;
}
