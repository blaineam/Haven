//! The run loop: start the connection relay, optionally the media store (local-disk,
//! rclone, or S3-over-iroh), print the link/QR, then idle until Ctrl-C.

use std::net::SocketAddr;
use std::process::{Child, Command, Stdio};

use anyhow::{anyhow, Result};
use haven_net::blobstore::fmt_bytes;
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

    // Union across EVERY grant — a v2 link carries several circles, and forwarding/authorizing for
    // only the first is what left every other circle permanently forbidden.
    let link_grants = cfg.link.all_grants();
    let all_members: Vec<String> = {
        let mut seen = std::collections::BTreeSet::new();
        for g in &link_grants { for m in &g.members { seen.insert(m.clone()); } }
        seen.into_iter().collect()
    };

    println!("▸ Haven relay starting (no logs are written).");
    println!("  circles    : {}", link_grants.len());
    for g in &link_grants { println!("    · {} ({} members)", g.circle, g.members.len()); }
    println!("  members    : {} unique", all_members.len());
    println!("  data dir   : {}", cfg.data_dir.display());
    println!("  relay node : {my_hex}");

    // --- Connection relay (always on) ---------------------------------------------
    // Pure forwarder: no member handler, so it can never deliver content to itself.
    let relay = RelayNode::spawn(id.node_secret_bytes(), None)
        .await
        .map_err(|e| anyhow!("start relay: {e}"))?;
    // Forward only for/toward this circle's members — the link the operator pasted defines them.
    // Without this the relay is an open reflector for anyone who learns its node id (audit F10).
    relay.authorize_forwarding(all_members.clone());
    println!("✓ connection relay live — forwarding sealed frames toward circle members.");

    // --- Media store-and-forward --------------------------------------------------
    // Keep the started servers/guards alive for the process lifetime.
    let mut _s3_guard: Option<std::sync::Arc<S3Server>> = None;
    let mut _rclone_guard: Option<RcloneChild> = None;
    let mut _quick_tunnel: Option<haven_net::cfquicktunnel::QuickTunnel> = None;
    // Legacy second free trycloudflare for DERP when path-router is off (sibling hostname mode).
    let mut _derp_tunnel: Option<haven_net::cfquicktunnel::QuickTunnel> = None;
    let mut _derp_guard: Option<crate::derp::DerpServer> = None;
    let mut _path_router: Option<haven_net::PathRouter> = None;
    let mut _turn_guard: Option<haven_net::TurnServer> = None;
    let mut derp_public: Option<String> = cfg.derp_url.clone();
    let mut turn_public: Vec<String> = cfg.turn_urls.clone();
    let mut turn_user = haven_net::DEFAULT_TURN_USER.to_string();
    let mut turn_pass = cfg.turn_token.clone();

    match &cfg.backend {
        StoreBackend::Local => {
            // Default: serve sealed blobs straight off local disk over haven/blob/1 — on the
            // RELAY'S OWN endpoint (one node, two ALPNs). A separate BlobServer::spawn under the
            // same key bound a SECOND iroh endpoint that stole this node id's DERP home-relay
            // registration, so inbound dials flapped between the two endpoints and members saw
            // the relay as "Unreachable — retrying" (the same-key second-endpoint bug, again).
            let store = cfg.data_dir.join("store");
            let node = relay.node();
            node.enable_relay_with_retention(store.clone(), cfg.retention);
            println!(
                "✓ media store live — local-disk blob mailbox at {} over Haven Net (haven/blob/1, shared endpoint).",
                store.display()
            );
            println!("  storage node id (volunteer_node_id): {my_hex}");
            println!(
                "  mailbox GC on — event entries not refreshed by any member for {} days are pruned \
                 (first sweep waits 48h after enabling).",
                cfg.retention.mailbox_ttl.as_secs() / (24 * 3600)
            );
            // Retention is the OPERATOR'S choice: without limits media is kept forever
            // (today's behavior); with limits, the hourly sweep applies age first, then
            // oldest-first size eviction — whichever rule frees more space wins.
            match (cfg.retention.media_max_age, cfg.retention.media_max_bytes) {
                (None, None) => println!("  media retention: unlimited — media is never pruned."),
                (age, cap) => {
                    let mut rules = Vec::new();
                    if let Some(a) = age {
                        rules.push(format!("older than {} days", a.as_secs() / (24 * 3600)));
                    }
                    if let Some(c) = cap {
                        rules.push(format!("oldest-first over {}", fmt_bytes(c)));
                    }
                    println!(
                        "  media retention: pruning media {} (hourly sweep; TOUCH/HAS keeps a blob live; \
                         first media sweep waits 48h after enabling limits).",
                        rules.join(", then ")
                    );
                }
            }

            // Lock the mailbox to the circle's members (+ sibling relays) so only members can read or
            // enumerate it — a stranger who learns this relay's node id gets nothing (audit
            // transport-F4). The link the operator pasted defines the membership.
            // EVERY circle the link grants, not just the first — a relay serves exactly what it is
            // authorized for, and the apps let a user point every circle at one relay. Honouring one
            // grant is what produced permanent `ERR forbidden` on all the others. See RelayLink.
            for g in &link_grants {
                node.relay_authorize(&g.circle, g.members.clone(), cfg.peers.clone());
            }
            // The link is a PAIRING HANDSHAKE, not a frozen policy. Circles the members taught this
            // relay (ENROLL — see `RelayAuth::learn`) were merged back in by `relay_authorize`, and
            // they persist in the data dir across restarts. Before that, a relay authorized its
            // circles exactly once and answered `ERR forbidden` on every circle created afterwards —
            // including every `dm:`, which meant DMs had no store-and-forward at all.
            let learned = node.relay_learned_grants();
            if !learned.is_empty() {
                println!("  learned {} additional circle(s) from paired members:", learned.len());
                for (c, m) in &learned {
                    println!("    · {} ({} members)", c, m.len());
                }
            }
            println!(
                "  serving {} circle(s): {} from the link + {} learned. Members may teach this relay \
                 new circles at any time — no re-pasting.",
                node.relay_circle_count(),
                link_grants.len(),
                learned.len()
            );

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

                // Haven fabric: embed iroh-relay BEFORE the public front door so a single-origin
                // path router can front media + DERP on one cloudflared process.
                let mut derp_local_port: Option<u16> = None;
                if cfg.derp_enabled {
                    let seed = cfg.derp_url.clone().unwrap_or_default();
                    let dcfg = crate::derp::DerpConfig {
                        enabled: true,
                        bind: cfg.derp_bind.clone(),
                        public_url: seed,
                    };
                    match crate::derp::DerpServer::spawn(&dcfg).await {
                        Ok(Some(srv)) => {
                            derp_local_port = Some(srv.local_port());
                            println!(
                                "✓ iroh DERP fabric live on {} (port {})",
                                srv.local_addr,
                                srv.local_port()
                            );
                            _derp_guard = Some(srv);
                        }
                        Ok(None) => {}
                        Err(e) => {
                            eprintln!("⚠ iroh DERP failed to start: {e:#}");
                            eprintln!(
                                "  media still works; live NAT falls back to n0 until DERP is up."
                            );
                        }
                    }
                }

                // Path proxy (default): one public origin routes by path —
                //   /k /l /t     → media
                //   /relay /derp /ping → fabric (DERP)
                //   /  /_haven   → status JSON
                // Sibling --derp-url (≠ media URL) skips the proxy for dual-origin setups.
                let sibling_derp = cfg
                    .derp_url
                    .as_ref()
                    .map(|u| u.trim().trim_end_matches('/').to_string())
                    .filter(|u| !u.is_empty())
                    .filter(|u| {
                        let media = cfg
                            .http_url
                            .as_ref()
                            .map(|m| m.trim().trim_end_matches('/').to_string())
                            .unwrap_or_default();
                        media.is_empty() || u != &media
                    });
                let mut front_port = port;
                let mut path_routed = false;
                let want_proxy = cfg.proxy_bind.is_some() && sibling_derp.is_none();
                if want_proxy {
                    let proxy_bind = cfg
                        .proxy_bind
                        .clone()
                        .unwrap_or_else(|| haven_net::DEFAULT_PATH_ROUTER_BIND.into());
                    let derp_backend = derp_local_port
                        .map(|p| format!("127.0.0.1:{p}"))
                        .unwrap_or_default();
                    let rcfg = haven_net::PathRouterConfig {
                        bind: proxy_bind,
                        media_backend: format!("127.0.0.1:{port}"),
                        derp_backend,
                        http_token: cfg.http_token.clone(),
                    };
                    match haven_net::PathRouter::spawn(&rcfg).await {
                        Ok(Some(router)) => {
                            front_port = router.local_port();
                            path_routed = true;
                            println!(
                                "✓ path proxy on {} — route by path:\n\
                                 \t media   /k/* /l/* /t/*     → 127.0.0.1:{port}\n\
                                 \t fabric  /relay /derp /ping → {}\n\
                                 \t hairpin /webrtc/hairpin    → WebSocket call media (free CF OK)\n\
                                 \t status  /  /_haven         → (local)",
                                router.local_addr,
                                if derp_local_port.is_some() {
                                    format!(
                                        "127.0.0.1:{}",
                                        derp_local_port.unwrap()
                                    )
                                } else {
                                    "(offline)".into()
                                }
                            );
                            _path_router = Some(router);
                        }
                        Ok(None) => {}
                        Err(e) => {
                            eprintln!("⚠ path proxy failed: {e:#}");
                            eprintln!(
                                "  falling back to dual-origin / media-only tunnel; \
                                 set --derp-url or multi-ingress if DERP must be public"
                            );
                        }
                    }
                }

                let mut public = cfg.http_url.clone();
                // Manual (--http-url only) / bundled token / free quick — see FrontDoorMode.
                // When path-routed, tunnel targets the router port (media + DERP by path).
                match start_front_door(front_port, &cfg) {
                    Ok(FrontDoorRun::Spawned(t)) => {
                        if t.kind == "named" {
                            println!("✓ cloudflare named tunnel: {}", t.public_url);
                            if path_routed {
                                println!(
                                    "  set Zero Trust origin to http://127.0.0.1:{front_port} \
                                     (path proxy — media + fabric on one hostname)"
                                );
                            } else {
                                println!(
                                    "  stable custom domain — connector authenticated with --tunnel-token"
                                );
                            }
                        } else {
                            println!(
                                "✓ cloudflare quick tunnel{}: {}",
                                if path_routed {
                                    " (media + fabric via path proxy)"
                                } else {
                                    " (media)"
                                },
                                t.public_url
                            );
                            println!(
                                "  ephemeral — hostname changes when this process restarts \
                                 (use --http-url alone for manual, or + --tunnel-token for bundled)."
                            );
                        }
                        public = Some(t.public_url.clone());
                        _quick_tunnel = Some(t);
                    }
                    Ok(FrontDoorRun::AnnounceOnly(u)) => {
                        println!("✓ manual front door (you run the tunnel/proxy): {u}");
                        if path_routed {
                            println!(
                                "  point your proxy at http://127.0.0.1:{front_port} \
                                 (path proxy: /k… → media, /relay → fabric)"
                            );
                        } else {
                            println!(
                                "  Haven will not spawn cloudflared — point your proxy at \
                                 http://127.0.0.1:{port} (media) and derp bind for fabric"
                            );
                        }
                        public = Some(u);
                    }
                    Ok(FrontDoorRun::LanOnly) => {}
                    Err(e) => {
                        eprintln!("⚠ front door unavailable: {e}");
                        eprintln!(
                            "  media still works on the LAN / iroh. Fix cloudflared or pass \
                             --http-url (manual) / --tunnel-token (bundled) / --no-tunnel."
                        );
                    }
                }

                // Resolve public DERP URL for frame-19 / interface.json.
                if let Some(srv) = _derp_guard.as_mut() {
                    if let Some(sib) = sibling_derp.clone() {
                        // Dual-origin: dedicated sibling hostname (or free second tunnel).
                        srv.public_url = sib;
                        // Free auto + sibling not set via --derp-url already handled; if operator
                        // wanted dual free tunnels without path router they set --derp-url empty
                        // but sibling_derp is None when path router works. Only open a second
                        // tunnel when path router is off and we still lack a public URL.
                    } else if path_routed {
                        // Single origin: same public URL as media — call signaling / live frames
                        // hairpin over HTTPS fabric on this host.
                        if let Some(ref u) = public {
                            srv.public_url = u.clone();
                        }
                    } else if srv.public_url.is_empty() {
                        if let Some(ref u) = public {
                            // Named/manual without path router: assume operator multi-ingress.
                            if !u.contains("trycloudflare") {
                                srv.public_url = u.clone();
                            }
                        }
                    }
                    // Last resort for free quick without path router: second origin.
                    if srv.public_url.is_empty() {
                        match start_quick_tunnel_for_port(srv.local_port(), &cfg) {
                            Ok(t) => {
                                println!(
                                    "✓ cloudflare quick tunnel (DERP fabric, dual-origin): {}",
                                    t.public_url
                                );
                                srv.public_url = t.public_url.clone();
                                _derp_tunnel = Some(t);
                            }
                            Err(e) => {
                                eprintln!("⚠ DERP quick tunnel failed: {e:#}");
                                eprintln!(
                                    "  set --derp-url or enable path router for single-tunnel fabric"
                                );
                            }
                        }
                    }
                    if !srv.public_url.is_empty() {
                        derp_public = Some(srv.public_url.clone());
                        println!("  derp public : {}", srv.public_url);
                        if path_routed {
                            println!(
                                "  path-proxied fabric — call signaling hairpins over this HTTPS host \
                                 (/relay WebSocket); clients drop n0 once they learn it (frame 19)."
                            );
                        } else {
                            println!(
                                "  clients prefer this DERP over n0 once they learn it (frame 19 / paste)."
                            );
                        }
                    } else {
                        println!(
                            "  derp local only ({}) — set --derp-url or open a public front door",
                            srv.local_addr
                        );
                    }
                }

                // Circle TURN: own UDP socket for WebRTC ICE (not a second iroh Endpoint).
                if cfg.turn_enabled {
                    let lan = primary_lan_ip();
                    let public_ip = cfg
                        .turn_public_ip
                        .clone()
                        .or_else(|| lan.clone())
                        .or_else(|| {
                            public
                                .as_ref()
                                .and_then(|u| haven_net::host_from_http_url(u))
                                .filter(|h| !h.contains("trycloudflare.com"))
                        })
                        .unwrap_or_else(|| "127.0.0.1".into());
                    let media_list: Vec<String> = public.iter().cloned().collect();
                    let suggested = if cfg.turn_urls.is_empty() {
                        haven_net::suggest_turn_urls(
                            &media_list,
                            lan.as_deref(),
                            // Port from bind string if present, else default 3478.
                            cfg.turn_bind
                                .rsplit(':')
                                .next()
                                .and_then(|p| p.parse().ok())
                                .unwrap_or(3478),
                        )
                    } else {
                        cfg.turn_urls.clone()
                    };
                    let tcfg = haven_net::TurnConfig {
                        enabled: true,
                        bind: cfg.turn_bind.clone(),
                        public_ip: public_ip.clone(),
                        secret: cfg.turn_token.clone(),
                        public_urls: suggested,
                    };
                    match haven_net::TurnServer::spawn(&tcfg).await {
                        Ok(Some(srv)) => {
                            turn_public = srv.public_urls.clone();
                            turn_user = srv.username.clone();
                            turn_pass = srv.password.clone();
                            println!(
                                "✓ circle TURN live on {} (UDP) — preferred WebRTC ICE media relay",
                                srv.local_addr
                            );
                            if !turn_public.is_empty() {
                                println!("  turn urls   : {}", turn_public.join(", "));
                                println!(
                                    "  turn auth   : user={} (password in turn_token / interface.json)",
                                    turn_user
                                );
                            } else {
                                println!(
                                    "  turn local only — set --turn-url or open UDP {} to peers",
                                    public_ip
                                );
                            }
                            println!(
                                "  note: free trycloudflare cannot front UDP TURN; port-forward 3478 for WAN. \
                                 Without TURN, clients use STUN + host ICE; call signaling still uses fabric."
                            );
                            _turn_guard = Some(srv);
                        }
                        Ok(None) => {}
                        Err(e) => {
                            eprintln!("⚠ circle TURN failed to start: {e:#}");
                            eprintln!(
                                "  clients fall back to STUN + host ICE; call signaling still hairpins over fabric."
                            );
                        }
                    }
                }

                match &public {
                    Some(url) => println!("  public URL : {url}"),
                    None => println!(
                        "  reachable at http://<this-host>:{port} — options:\n\
                            manual:  --http-url https://relay.example.com  (you run tunnel/proxy)\n\
                            bundled: --http-url https://… --tunnel-token <token>\n\
                            free:    omit --http-url (trycloudflare) or --no-tunnel for LAN only"
                    ),
                }
                if path_routed {
                    println!(
                        "  front door  : path proxy :{front_port} (CF/Manual origin → this port)"
                    );
                    println!(
                        "  probe       : GET http://127.0.0.1:{front_port}/_haven  (route table JSON)"
                    );
                }
                println!("  http token : {}", cfg.http_token);

                // Write a paste-ready interface blob so the app learns media URL + DERP fabric +
                // TURN in one adopt (then re-announces frame 19 to the circle). Also on disk.
                let mut interface = serde_json::json!({
                    "node": my_hex,
                    "urls": public.as_ref().map(|u| vec![u.clone()]).unwrap_or_default(),
                    "token": cfg.http_token,
                    "derp": derp_public.clone().unwrap_or_default(),
                });
                if !turn_public.is_empty() {
                    interface["turn"] = serde_json::json!(turn_public);
                    interface["turnUser"] = serde_json::json!(turn_user);
                    interface["turnPass"] = serde_json::json!(turn_pass);
                }
                let path = cfg.data_dir.join("interface.json");
                if let Ok(bytes) = serde_json::to_vec_pretty(&interface) {
                    let _ = std::fs::write(&path, bytes);
                }
                if let Ok(line) = serde_json::to_string(&interface) {
                    println!("\n  ── paste this into Haven (Storage → Connect external relay) ──");
                    println!("  {line}");
                    println!("  (also written to {})", path.display());
                }
                // ALSO publish the interface into the relay's own blob store under the reserved
                // key, generation-stamped. A client that can still dial us over iroh fetches this
                // to learn the CURRENT front door (free quick-tunnel URLs rotate on every restart,
                // and the paste-string flow only ever ran once at adopt time) and then re-announces
                // frame 19 to the circle — self-healing instead of "media waits forever while the
                // blob sits right here". Served read-only behind the members-only gate
                // (`blob_forbidden`), the same audience the sealed announces already reach.
                interface["v"] = serde_json::json!(1);
                interface["gen"] = serde_json::json!(
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_millis() as u64)
                        .unwrap_or(0)
                );
                if let Ok(bytes) = serde_json::to_vec(&interface) {
                    if node.relay_local_put(haven_net::blobstore::RELAY_INTERFACE_KEY, &bytes) {
                        println!("  interface  : published to fleet/members over the relay channel");
                    }
                }
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
    // Tunnel Drop kills cloudflared on exit.
    let _ = (&relay, &_quick_tunnel, &_derp_tunnel, &_derp_guard, &_turn_guard);
    tokio::signal::ctrl_c().await.ok();
    println!("▸ shutting down.");
    Ok(())
}

/// This machine's primary LAN IPv4 (UDP-connect trick — no packet is actually sent).
fn primary_lan_ip() -> Option<String> {
    let s = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("8.8.8.8:80").ok()?;
    let ip = s.local_addr().ok()?.ip();
    if ip.is_loopback() {
        return None;
    }
    Some(ip.to_string())
}

/// Second free trycloudflare for the DERP bind (media already has its own origin).
fn start_quick_tunnel_for_port(port: u16, cfg: &Config) -> Result<haven_net::cfquicktunnel::QuickTunnel> {
    use haven_net::cfquicktunnel::{ensure_cloudflared, executable_dir, QuickTunnel, TunnelSpec};
    let local = format!("http://127.0.0.1:{port}");
    let mut search = Vec::new();
    if let Ok(exe_dir) = executable_dir() {
        search.push(exe_dir.clone());
    }
    search.push(cfg.data_dir.join("bin"));
    let install = executable_dir()
        .ok()
        .filter(|d| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(d.join(".haven-write-test"))
                .map(|f| {
                    drop(f);
                    let _ = std::fs::remove_file(d.join(".haven-write-test"));
                    true
                })
                .unwrap_or(false)
        })
        .unwrap_or_else(|| cfg.data_dir.join("bin"));
    let bin = ensure_cloudflared(&search, &install, true)?;
    QuickTunnel::start_spec(&bin, TunnelSpec::Quick { local_http: local })
}

enum FrontDoorRun {
    Spawned(haven_net::cfquicktunnel::QuickTunnel),
    AnnounceOnly(String),
    LanOnly,
}

/// Apply front-door mode: manual announce-only, or spawn bundled cloudflared.
fn start_front_door(port: u16, cfg: &Config) -> Result<FrontDoorRun> {
    use haven_net::cfquicktunnel::{
        ensure_cloudflared, executable_dir, resolve_front_door, FrontDoorAction, FrontDoorMode,
        QuickTunnel,
    };
    let local = format!("http://127.0.0.1:{port}");
    // CLI flags: --http-url alone → Manual; + token → Bundled; neither → Auto.
    let mode = if cfg.tunnel_token.as_ref().map(|t| !t.is_empty()).unwrap_or(false) {
        FrontDoorMode::Bundled
    } else if cfg.http_url.as_ref().map(|u| !u.is_empty()).unwrap_or(false) {
        FrontDoorMode::Manual
    } else {
        FrontDoorMode::Auto
    };
    match resolve_front_door(
        mode,
        cfg.http_url.as_deref(),
        cfg.tunnel_token.as_deref(),
        cfg.auto_tunnel,
        &local,
    )? {
        FrontDoorAction::AnnounceOnly { public_url } => Ok(FrontDoorRun::AnnounceOnly(public_url)),
        FrontDoorAction::LanOnly => Ok(FrontDoorRun::LanOnly),
        FrontDoorAction::Spawn(spec) => {
            let mut search = Vec::new();
            if let Ok(exe_dir) = executable_dir() {
                search.push(exe_dir.clone());
            }
            search.push(cfg.data_dir.join("bin"));
            let install = executable_dir()
                .ok()
                .filter(|d| {
                    std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(d.join(".haven-write-test"))
                        .map(|f| {
                            drop(f);
                            let _ = std::fs::remove_file(d.join(".haven-write-test"));
                            true
                        })
                        .unwrap_or(false)
                })
                .unwrap_or_else(|| cfg.data_dir.join("bin"));
            let bin = ensure_cloudflared(&search, &install, true)?;
            Ok(FrontDoorRun::Spawned(QuickTunnel::start_spec(&bin, spec)?))
        }
    }
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
