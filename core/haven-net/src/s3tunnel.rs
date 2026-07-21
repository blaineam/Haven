//! S3-over-iroh tunnel (HAVEN-NET-RELAY.md Design A) — the **media store-and-forward**
//! transport.
//!
//! A circle's shared store is an S3-compatible endpoint (`rclone serve s3`) holding
//! **circle-sealed** blobs. Design A carries that exact S3 traffic *inside* the iroh
//! overlay so the store is reachable only over the authenticated P2P tunnel — never on
//! the open internet, and with no public host.
//!
//! ```text
//!  consumer device                              relay / volunteer device
//!  ┌──────────────┐   iroh QUIC   ┌───────────────────────────────┐
//!  │ S3Client  ───┼──► local  ───►│ accept (ALPN "haven/s3/1")    │
//!  │ (SigV4 HTTP) │   127.0.0.1   │   └─► 127.0.0.1:<rclone s3>    │
//!  └──────────────┘   :PORT       └───────────────────────────────┘
//! ```
//!
//! * **`serve_s3_over_iroh`** (relay side): for each inbound iroh bi-stream, open a TCP
//!   socket to the local `rclone serve s3` and splice bytes both ways. The relay is a
//!   pure byte-pump — rclone never knows it isn't a normal client, and the blobs are
//!   already circle-sealed, so the relay host can't read the media.
//! * **`tunnel_to`** (consumer side): run a loopback TCP listener; each accepted
//!   connection opens an iroh bi-stream to the volunteer node and splices. The app
//!   points `S3Client.endpoint` at `http://127.0.0.1:<port>` — zero SigV4 changes.
//!
//! The relay host sees: opaque S3 requests (PUT/GET/LIST by content hash) for ciphertext
//! blobs, and the iroh connection metadata (which node is talking to it). It never sees
//! plaintext media or any content key.

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// ALPN for the S3-over-iroh media tunnel.
pub const S3_ALPN: &[u8] = b"haven/s3/1";

/// The relay/volunteer side: accept iroh connections on `S3_ALPN` and splice each
/// inbound bi-stream to the local `rclone serve s3` at `local_s3`. Runs until the
/// returned guard is dropped (the endpoint is closed).
///
/// `secret` is the relay's identity key, so the served store is addressed by the
/// relay's stable node id (the `volunteer_node_id` the app's `BucketConfig` references).
pub struct S3Server {
    endpoint: Endpoint,
}

impl S3Server {
    pub async fn spawn(secret: [u8; 32], local_s3: SocketAddr) -> Result<Arc<Self>> {
        let endpoint = crate::haven_endpoint_builder()
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![S3_ALPN.to_vec()])
            .bind()
            .await
            .map_err(|e| anyhow!("{e:?}"))?;
        let srv = Arc::new(Self { endpoint });
        let acc = srv.clone();
        tokio::spawn(async move { acc.accept_loop(local_s3).await });
        Ok(srv)
    }

    pub fn node_id_hex(&self) -> String {
        self.endpoint.id().as_bytes().iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Loopback dial address (for same-machine tests).
    pub async fn local_dial_addr(&self) -> Result<EndpointAddr> {
        for _ in 0..50 {
            let addr = self.endpoint.addr();
            if let Some(a) = addr.ip_addrs().next() {
                return Ok(EndpointAddr::new(addr.id)
                    .with_ip_addr(SocketAddr::from(([127, 0, 0, 1], a.port()))));
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        Err(anyhow!("no direct address yet"))
    }

    async fn accept_loop(self: Arc<Self>, local_s3: SocketAddr) {
        while let Some(incoming) = self.endpoint.accept().await {
            tokio::spawn(async move {
                let Ok(connecting) = incoming.accept() else { return };
                let Ok(conn) = connecting.await else { return };
                loop {
                    match conn.accept_bi().await {
                        Ok((send, recv)) => {
                            tokio::spawn(async move {
                                let _ = splice_to_local(send, recv, local_s3).await;
                            });
                        }
                        Err(_) => break,
                    }
                }
            });
        }
    }
}

/// Splice one iroh bi-stream to a fresh TCP connection to the local rclone S3 server.
async fn splice_to_local(
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
    local_s3: SocketAddr,
) -> Result<()> {
    let tcp = TcpStream::connect(local_s3).await?;
    let (mut tcp_r, mut tcp_w) = tcp.into_split();

    // iroh recv → tcp write
    let up = async move {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match recv.read(&mut buf).await {
                Ok(Some(n)) if n > 0 => {
                    if tcp_w.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        let _ = tcp_w.shutdown().await;
    };
    // tcp read → iroh send
    let down = async move {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match tcp_r.read(&mut buf).await {
                Ok(n) if n > 0 => {
                    if send.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        let _ = send.finish();
    };
    tokio::join!(up, down);
    Ok(())
}

/// The consumer side: bind a loopback TCP listener and, for each accepted connection,
/// open an iroh bi-stream to `volunteer` and splice. Returns the bound loopback address
/// the app should point `S3Client.endpoint` at. Runs until the process exits.
///
/// Discovery (n0/DHT) resolves the volunteer node id to a live address — the same way a
/// reach-me link's node id resolves.
pub async fn tunnel_to(secret: [u8; 32], volunteer_node_hex: &str) -> Result<SocketAddr> {
    let dest = EndpointAddr::new(parse_node_id(volunteer_node_hex)?);
    tunnel_to_addr(secret, dest).await
}

/// Parse a 64-hex node id into an iroh `EndpointId`.
pub fn parse_node_id(hex: &str) -> Result<EndpointId> {
    let h = hex.trim();
    if h.len() != 64 {
        return Err(anyhow!("volunteer node id must be 64 hex chars"));
    }
    let mut id = [0u8; 32];
    for i in 0..32 {
        id[i] = u8::from_str_radix(&h[i * 2..i * 2 + 2], 16).map_err(|_| anyhow!("bad hex"))?;
    }
    EndpointId::from_bytes(&id).map_err(|e| anyhow!("{e:?}"))
}

/// As [`tunnel_to`], but dial an explicit [`EndpointAddr`] (e.g. a loopback address for
/// same-machine tests, or a discovery-resolved address).
pub async fn tunnel_to_addr(secret: [u8; 32], dest: EndpointAddr) -> Result<SocketAddr> {
    let endpoint = crate::haven_endpoint_builder()
        .secret_key(SecretKey::from_bytes(&secret))
        .alpns(vec![])
        .bind()
        .await
        .map_err(|e| anyhow!("{e:?}"))?;

    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0))).await?;
    let local = listener.local_addr()?;

    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else { break };
            let endpoint = endpoint.clone();
            let dest = dest.clone();
            tokio::spawn(async move {
                let Ok(conn) = endpoint.connect(dest, S3_ALPN).await else {
                    return;
                };
                let Ok((send, recv)) = conn.open_bi().await else { return };
                let _ = splice_from_local(tcp, send, recv).await;
            });
        }
    });

    Ok(local)
}

async fn splice_from_local(
    tcp: TcpStream,
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
) -> Result<()> {
    let (mut tcp_r, mut tcp_w) = tcp.into_split();
    let up = async move {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match tcp_r.read(&mut buf).await {
                Ok(n) if n > 0 => {
                    if send.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        let _ = send.finish();
    };
    let down = async move {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match recv.read(&mut buf).await {
                Ok(Some(n)) if n > 0 => {
                    if tcp_w.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        let _ = tcp_w.shutdown().await;
    };
    tokio::join!(up, down);
    Ok(())
}
