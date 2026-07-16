//! The run loop: start the connection relay, optionally the media store (local-disk,
//! rclone, or S3-over-iroh), print the link/QR, then idle until Ctrl-C.

use std::net::SocketAddr;
use std::process::{Child, Command, Stdio};

use anyhow::{anyhow, Result};
use haven_net::s3tunnel::S3Server;
use haven_net::RelayNode;
use haven_p2p::identity::Identity;

use crate::config::{Config, StoreBackend};

/// A guard that kills the rclone child on drop.
struct RcloneChild(Child);
impl Drop for RcloneChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

pub async fn run(cfg: Config) -> Result<()> {
    let id = Identity::from_seed(&cfg.seed);
    let my_hex = hex32(&id.public().node_id_bytes());

    println!("▸ Haven relay starting (no logs are written).");
    println!("  circle tag : {}", cfg.link.circle);
    println!("  members    : {}", cfg.link.members.len());
    println!("  data dir   : {}", cfg.data_dir.display());
    println!("  relay node : {my_hex}");

    // --- Connection relay (always on) ---------------------------------------------
    // Pure forwarder: no member handler, so it can never deliver content to itself.
    let relay = RelayNode::spawn(id.node_secret_bytes(), None)
        .await
        .map_err(|e| anyhow!("start relay: {e}"))?;
    // Forward only for/toward this circle's members — the link the operator pasted defines them.
    // Without this the relay is an open reflector for anyone who learns its node id (audit F10).
    relay.authorize_forwarding(cfg.link.members.clone());
    println!("✓ connection relay live — forwarding sealed frames toward circle members.");

    // --- Media store-and-forward --------------------------------------------------
    // Keep the started servers/guards alive for the process lifetime.
    let mut _s3_guard: Option<std::sync::Arc<S3Server>> = None;
    let mut _rclone_guard: Option<RcloneChild> = None;

    match &cfg.backend {
        StoreBackend::Local => {
            // Default: serve sealed blobs straight off local disk over haven/blob/1 — on the
            // RELAY'S OWN endpoint (one node, two ALPNs). A separate BlobServer::spawn under the
            // same key bound a SECOND iroh endpoint that stole this node id's DERP home-relay
            // registration, so inbound dials flapped between the two endpoints and members saw
            // the relay as "Unreachable — retrying" (the same-key second-endpoint bug, again).
            let store = cfg.data_dir.join("store");
            let node = relay.node();
            node.enable_relay(store.clone());
            println!(
                "✓ media store live — local-disk blob mailbox at {} over Haven Net (haven/blob/1, shared endpoint).",
                store.display()
            );
            println!("  storage node id (volunteer_node_id): {my_hex}");
            println!(
                "  mailbox GC on — event entries not refreshed by any member for 30 days are pruned \
                 (media is never pruned; first sweep waits 48h after enabling)."
            );

            // Lock the mailbox to the circle's members (+ sibling relays) so only members can read or
            // enumerate it — a stranger who learns this relay's node id gets nothing (audit
            // transport-F4). The link the operator pasted defines the membership.
            node.relay_authorize(&cfg.link.circle, cfg.link.members.clone(), cfg.peers.clone());

            // Mesh replication: pull from each sibling relay every 30s so the mailbox
            // self-heals across the mesh (peers do the same in reverse → eventual set-union).
            if !cfg.peers.is_empty() {
                println!("  meshing with {} sibling relay(s) — mailbox self-replicates.", cfg.peers.len());
                let mesh_node = node.clone();
                let peers = cfg.peers.clone();
                tokio::spawn(async move {
                    loop {
                        for peer in &peers {
                            let _ = mesh_node.relay_sync_from(peer).await;
                        }
                        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                    }
                });
            }

            // Plain-HTTP blob interface — the DEFAULT cross-NAT media transport (the iroh blob
            // ALPN drops datagrams on pure-relay cross-NAT paths). Served through the node so it
            // shares the membership map authorized just above: same circle gate as the iroh path,
            // per-request signatures instead of a shared bearer token (audit F2/F9). Blobs are
            // E2E-sealed, so the wire still carries only ciphertext.
            if let Some(bind) = &cfg.http_bind {
                let port = node
                    .relay_serve_http(bind, &cfg.http_token)
                    .await
                    .map_err(|e| anyhow!("start http blob interface: {e}"))?;
                println!("✓ http media interface live on {bind} (port {port}).");
                match &cfg.http_url {
                    Some(url) => println!("  public URL : {url}"),
                    None => println!(
                        "  reachable at http://<this-host>:{port} — port-forward / reverse-proxy \
                         (TLS) / tunnel it to serve members across the internet, then pass \
                         --http-url <public url>."
                    ),
                }
                println!("  http token : {}", cfg.http_token);
            }
        }
        StoreBackend::S3 | StoreBackend::Rclone { .. } => {
            // Opt-in: rclone serve s3 (local dir or a named remote) over haven/s3/1.
            let s3_local: SocketAddr = SocketAddr::from(([127, 0, 0, 1], cfg.s3_port));
            match start_rclone(&cfg, s3_local) {
                Ok(child) => {
                    _rclone_guard = Some(child);
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    // The S3 tunnel gets its OWN derived identity: a second endpoint under the
                    // RELAY'S key would steal the DERP registration (same-key second-endpoint bug)
                    // and make both flap unreachable. Deterministic (seed-derived), so the printed
                    // volunteer_node_id is stable across restarts.
                    let s3_id = Identity::from_seed(&derive_subseed(&cfg.seed, b"haven-relay/s3/1"));
                    let s3 = S3Server::spawn(s3_id.node_secret_bytes(), s3_local)
                        .await
                        .map_err(|e| anyhow!("start s3-over-iroh: {e}"))?;
                    match &cfg.backend {
                        StoreBackend::Rclone { remote } => println!(
                            "✓ media store live — rclone serve s3 of remote '{}' on 127.0.0.1:{} over iroh (haven/s3/1).",
                            remote, cfg.s3_port
                        ),
                        _ => println!(
                            "✓ media store live — rclone serve s3 on 127.0.0.1:{} over iroh (haven/s3/1).",
                            cfg.s3_port
                        ),
                    }
                    println!("  storage node id (volunteer_node_id): {}", s3.node_id_hex());
                    _s3_guard = Some(s3);
                }
                Err(e) => {
                    eprintln!("⚠ media store disabled: {e}");
                    eprintln!("  (install rclone, or drop the --s3/--rclone-remote flag to use the local-disk store.)");
                }
            }
        }
        StoreBackend::None => {
            println!("• media store-and-forward disabled (--no-storage).");
        }
    }

    println!("\n═══════════════════════════════════════════════════════════════");
    println!("✓ Relay online. The Haven app already knows this relay from the link;");
    println!("  if it asks, the relay's node id (public routing data, not a secret) is:");
    println!("     {my_hex}");
    println!("  The relay only ever moves ciphertext. Stop with Ctrl-C.");
    println!("═══════════════════════════════════════════════════════════════\n");

    // Idle until Ctrl-C; the relay's accept/forward loops run in the background.
    let _ = &relay;
    tokio::signal::ctrl_c().await.ok();
    println!("▸ shutting down.");
    Ok(())
}

/// Launch `rclone serve s3` bound to loopback only (never a public interface), with
/// hardened, low-noise flags. The source is either a named rclone remote (so rclone owns
/// the provider auth — Haven holds no OAuth) or a plain local data dir. Returns a
/// kill-on-drop guard.
fn start_rclone(cfg: &Config, addr: SocketAddr) -> Result<RcloneChild> {
    let bin = cfg.rclone_bin.clone().unwrap_or_else(|| "rclone".to_string());

    // Source path: a remote (`remote:path`) for the rclone backend, else a local dir.
    let source = match &cfg.backend {
        StoreBackend::Rclone { remote } => remote.clone(),
        _ => {
            let data = cfg.data_dir.join("store");
            std::fs::create_dir_all(&data).map_err(|e| anyhow!("create store dir: {e}"))?;
            data.to_string_lossy().to_string()
        }
    };

    // Stable per-relay S3 creds (the tunnel is the real auth; these just satisfy rclone).
    let key = format!("haven{}", &hex32(&cfg.seed)[..18]);
    let secret = hex32(&cfg.seed)[18..50].to_string();

    let mut cmd = Command::new(&bin);
    cmd.arg("serve")
        .arg("s3")
        .arg(&source)
        .arg("--addr")
        .arg(addr.to_string()) // loopback only
        .arg("--auth-key")
        .arg(format!("{key},{secret}"))
        // Hardened / quiet: no request log, no transaction log.
        .arg("--log-level")
        .arg("ERROR")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(conf) = &cfg.rclone_config {
        cmd.arg("--config").arg(conf);
    }

    let child = cmd.spawn().map_err(|e| anyhow!("spawn rclone ({bin}): {e}"))?;
    Ok(RcloneChild(child))
}

fn hex32(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Derive a deterministic sub-identity seed from the relay seed for an auxiliary endpoint (the S3
/// tunnel), so it never shares the relay's node id — two live endpoints under one key fight over
/// the DERP home-relay registration and both flap unreachable.
fn derive_subseed(seed: &[u8; 32], label: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(seed);
    h.update(label);
    h.finalize().into()
}
