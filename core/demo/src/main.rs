//! Milestone 1b proof — move a sealed photo over the wire.
//!
//! Two independent iroh endpoints (Alice + Bob) on real QUIC, relays disabled so it
//! runs fully offline/local. Alice generates a real PNG, seals it to Bob with the
//! hybrid post-quantum KEM from `haven-p2p`, and ships it over a QUIC stream. Bob
//! accepts, decapsulates, opens, and verifies the bytes match the original by
//! BLAKE3. Nothing on the wire is ever plaintext.
//!
//!     cargo run -p haven-demo --release

use std::io::Cursor;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use image::{ImageFormat, Rgb, RgbImage};
use iroh::{
    endpoint::{presets::Empty, Endpoint},
    EndpointAddr, RelayMode,
};
use haven_p2p::crypto::{decapsulate, encapsulate_to, open, seal, Encapsulation};
use haven_p2p::identity::{Identity, HavenId};

/// Application protocol id for this transfer.
const ALPN: &[u8] = b"haven/photo/0";
/// Generous ceiling for `read_to_end` (a 100 GB file would stream in chunks; this
/// one-shot demo reads the whole sealed payload at once).
const MAX_READ: usize = 256 * 1024 * 1024;

/// Convert any `Debug` error into `anyhow` so iroh's varied error types compose.
trait IntoAnyhow<T> {
    fn ah(self) -> anyhow::Result<T>;
}
impl<T, E: std::fmt::Debug> IntoAnyhow<T> for Result<T, E> {
    fn ah(self) -> anyhow::Result<T> {
        self.map_err(|e| anyhow::anyhow!("{e:?}"))
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("── Haven M1b: move a sealed photo over the wire ──\n");

    // 1. Identities (no PII; Bob's public id is all Alice needs to seal to him).
    let bob = Identity::generate();
    let bob_pub = bob.public();
    println!("Bob's Haven id: {}", short_id(&bob_pub));

    // 2. Make a real photo and remember its hash.
    let photo = make_photo()?;
    let orig_hash = blake3::hash(&photo);
    std::fs::write("alice_original.png", &photo)?;
    println!(
        "Alice's photo: alice_original.png  ({} KB, blake3 {})",
        photo.len() / 1024,
        short_hash(orig_hash.as_bytes())
    );

    // 3. Bob's endpoint accepts; relays disabled → pure local QUIC, works offline.
    //    The `Empty` preset sets no crypto provider, so we supply iroh's `ring`.
    let bob_ep = Endpoint::builder(Empty)
        .crypto_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .alpns(vec![ALPN.to_vec()])
        .relay_mode(RelayMode::Disabled)
        .bind()
        .await
        .ah()?;
    // With relays off, wait until iroh has discovered local direct addresses so the
    // addr Alice dials actually contains a reachable socket.
    let bob_addr = wait_for_direct_addr(&bob_ep).await?;
    let dials: Vec<String> = bob_addr.ip_addrs().map(|a| a.to_string()).collect();
    println!("Bob   → listening on {}", dials.join(", "));

    // Bob binds all interfaces (incl. loopback) but only advertises LAN/Tailscale
    // IPs, which a local firewall may drop. For this same-machine demo, dial Bob's
    // port on 127.0.0.1 directly. (Real peers use the full advertised addr + relays.)
    let port = bob_addr
        .ip_addrs()
        .next()
        .map(|a| a.port())
        .ok_or_else(|| anyhow::anyhow!("no port"))?;
    let dial_addr = EndpointAddr::new(bob_addr.id).with_ip_addr(SocketAddr::from(([127, 0, 0, 1], port)));

    let bob_task = tokio::spawn(async move { receive(bob_ep, bob).await });

    // 4. Alice's endpoint, also relay-disabled.
    let alice_ep = Endpoint::builder(Empty)
        .crypto_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .relay_mode(RelayMode::Disabled)
        .bind()
        .await
        .ah()?;

    // 5. Alice seals the photo to Bob and sends it over QUIC.
    println!("\nAlice → dialing Bob over QUIC (relays disabled, direct UDP)…");
    let sent = send_photo(&alice_ep, dial_addr, &bob_pub, &photo).await?;
    println!("Alice → sealed {} KB and sent it over the wire.", sent / 1024);

    // 6. Collect Bob's result and verify.
    let received = bob_task.await??;
    let recv_hash = blake3::hash(&received);
    std::fs::write("bob_received.png", &received)?;

    println!("\nBob   → decrypted {} KB → bob_received.png", received.len() / 1024);
    println!("Bob   → blake3 {}", short_hash(recv_hash.as_bytes()));

    let ok = recv_hash == orig_hash;
    println!(
        "\n{}  end-to-end: original == received: {}",
        if ok { "✅" } else { "❌" },
        ok
    );
    println!("   (the QUIC stream only ever carried hybrid-PQ ciphertext)");

    alice_ep.close().await;
    anyhow::ensure!(ok, "received photo did not match original");
    Ok(())
}

/// Poll the endpoint's address until iroh has populated a direct (local) socket
/// address. `online()` can't be used here because it waits for a relay, which is
/// disabled.
async fn wait_for_direct_addr(ep: &Endpoint) -> anyhow::Result<EndpointAddr> {
    for _ in 0..50 {
        let addr = ep.addr();
        if addr.ip_addrs().next().is_some() {
            return Ok(addr);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    anyhow::bail!("no direct addresses discovered within 5s")
}

/// Bob's side: accept one connection, read the sealed payload, decapsulate + open.
async fn receive(ep: Endpoint, identity: Identity) -> anyhow::Result<Vec<u8>> {
    let incoming = ep.accept().await.ok_or_else(|| anyhow::anyhow!("no inbound"))?;
    let conn = incoming.accept().ah()?.await.ah()?;
    println!("Bob   → accepted QUIC connection from {}", conn.remote_id());

    let (mut send, mut recv) = conn.accept_bi().await.ah()?;
    let framed = recv.read_to_end(MAX_READ).await.ah()?;

    let (enc, sealed) = unframe(&framed)?;
    let key = decapsulate(&identity, &enc)?; // hybrid X25519 + ML-KEM-768
    let photo = open(&key, &sealed)?; // AES-256-GCM

    send.write_all(b"ok").await.ah()?;
    send.finish().ah()?;
    conn.closed().await;
    ep.close().await;
    Ok(photo)
}

/// Alice's side: seal the photo to Bob and stream it. Returns bytes sent.
async fn send_photo(
    ep: &Endpoint,
    bob_addr: EndpointAddr,
    bob_pub: &HavenId,
    photo: &[u8],
) -> anyhow::Result<usize> {
    let (enc, key) = encapsulate_to(bob_pub)?; // derive a content key *to* Bob
    let sealed = seal(&key, photo); // AES-256-GCM
    let framed = frame(&enc, &sealed);

    let conn = ep.connect(bob_addr, ALPN).await.ah()?;
    let (mut send, mut recv) = conn.open_bi().await.ah()?;
    send.write_all(&framed).await.ah()?;
    send.finish().ah()?;

    let ack = recv.read_to_end(16).await.ah()?;
    anyhow::ensure!(ack == b"ok", "Bob did not ack");
    conn.close(0u32.into(), b"done");
    Ok(framed.len())
}

/// Wire framing: eph_x_pub(32) ‖ pq_len(4) ‖ pq_ct ‖ sealed_len(4) ‖ sealed.
fn frame(enc: &Encapsulation, sealed: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(32 + 4 + enc.pq_ct.len() + 4 + sealed.len());
    v.extend_from_slice(&enc.eph_x_pub);
    v.extend_from_slice(&(enc.pq_ct.len() as u32).to_le_bytes());
    v.extend_from_slice(&enc.pq_ct);
    v.extend_from_slice(&(sealed.len() as u32).to_le_bytes());
    v.extend_from_slice(sealed);
    v
}

fn unframe(b: &[u8]) -> anyhow::Result<(Encapsulation, Vec<u8>)> {
    anyhow::ensure!(b.len() >= 40, "frame too short");
    let eph_x_pub: [u8; 32] = b[0..32].try_into()?;
    let pq_len = u32::from_le_bytes(b[32..36].try_into()?) as usize;
    let pq_end = 36 + pq_len;
    anyhow::ensure!(b.len() >= pq_end + 4, "frame truncated (pq)");
    let pq_ct = b[36..pq_end].to_vec();
    let s_len = u32::from_le_bytes(b[pq_end..pq_end + 4].try_into()?) as usize;
    let s_start = pq_end + 4;
    anyhow::ensure!(b.len() >= s_start + s_len, "frame truncated (sealed)");
    let sealed = b[s_start..s_start + s_len].to_vec();
    Ok((Encapsulation { eph_x_pub, pq_ct }, sealed))
}

/// Generate a real PNG so there's an openable artifact at both ends.
fn make_photo() -> anyhow::Result<Vec<u8>> {
    let (w, h) = (1280u32, 960u32);
    let mut img = RgbImage::new(w, h);
    for y in 0..h {
        for x in 0..w {
            let r = (x * 255 / w) as u8;
            let g = (y * 255 / h) as u8;
            let b = (((x + y) * 255) / (w + h)) as u8;
            img.put_pixel(x, y, Rgb([r, g, b]));
        }
    }
    let mut buf = Vec::new();
    img.write_to(&mut Cursor::new(&mut buf), ImageFormat::Png).ah()?;
    Ok(buf)
}

fn short_id(id: &HavenId) -> String {
    short_hash(&id.node_id_bytes())
}

fn short_hash(bytes: &[u8]) -> String {
    let h: String = bytes.iter().take(6).map(|b| format!("{b:02x}")).collect();
    format!("{h}…")
}
