//! Haven networking — an iroh-backed P2P node that carries opaque payloads (in
//! practice, `haven_p2p::social::SealedEnvelope` bytes) between peers over QUIC.
//!
//! Connections are **kept alive and reused bidirectionally**: each message is a uni
//! stream on a cached connection keyed by the remote's node id. Whoever can reach the
//! other dials once; both then send over that same connection. This is what lets
//! delivery flow both ways even when one peer is behind a NAT that can't be dialed
//! directly. The bytes on the wire are already end-to-end encrypted by `haven-p2p`.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Result};
use data_encoding::BASE32_NOPAD;
use iroh::{
    endpoint::{presets::N0, Connection, Endpoint},
    EndpointAddr, EndpointId, SecretKey,
};

pub mod blobstore;
pub mod httprelay;
pub mod livedelivery;
pub mod relay;
pub mod s3tunnel;

const ALPN: &[u8] = b"haven/social/0";
const MAX_PAYLOAD: usize = 256 * 1024 * 1024;

/// Called for each inbound payload (sealed envelope / protocol frame bytes).
/// Inbound frame callback: `(sender_node_id, payload)`. The sender id is the AUTHENTICATED iroh
/// endpoint id of the connection the frame arrived on (proof of key possession at the transport
/// layer) — all-zeros when the origin isn't a direct peer connection (e.g. a relay-delivered
/// routing frame, where the immediate peer is the forwarder, not the author).
pub type InboundHandler = Arc<dyn Fn([u8; 32], Vec<u8>) + Send + Sync>;

type Conns = Arc<Mutex<HashMap<EndpointId, Connection>>>;

/// Lock that tolerates poisoning (a panic in one task must not cascade-abort others).
fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

trait IntoAnyhow<T> {
    fn ah(self) -> Result<T>;
}
impl<T, E: std::fmt::Debug> IntoAnyhow<T> for std::result::Result<T, E> {
    fn ah(self) -> Result<T> {
        self.map_err(|e| anyhow!("{e:?}"))
    }
}

/// Optional in-process relay (blob mailbox) attached to THIS node's endpoint. Hosting a relay used to
/// spin up a SECOND iroh node in the same process, which made iroh's per-remote path manager churn
/// unboundedly (tens-of-GB leak). Now ONE endpoint serves both the social ALPN and the blob ALPN.
#[derive(Clone)]
struct RelayCfg {
    root: std::path::PathBuf,
    auth: Arc<Mutex<blobstore::RelayAuth>>,
    /// Plain-HTTP interface to the same store — the default cross-NAT media transport
    /// (the iroh blob ALPN drops datagrams over pure-relay cross-NAT paths).
    http: Option<Arc<httprelay::HttpRelay>>,
    /// Operator-chosen retention. Defaults to today's behavior (30d mailbox TTL, media
    /// never deleted) — app-embedded relays never set it, so they change nothing.
    retention: blobstore::Retention,
}

/// Per-peer dial backoff after failed connects. Without it the app's 20s sync loop re-dials every
/// unreachable id (a friend's pre-multidevice ACCOUNT id resolves to NO node — kept in the dial set
/// by design; offline devices; stale relay entries) forever, keeping ~10 doomed handshakes in flight
/// at all times. That constant path churn floods our own home-relay connection so badly that INBOUND
/// relay-path handshakes never complete (proven: a quiet scratch node accepts relay dials in ~200ms
/// while the churning app times out every dial at 30s), on top of the CPU/battery/warn-spam cost.
struct DialGate {
    fails: u32,
    until: std::time::Instant,
}

/// A peer-to-peer node.
pub struct Node {
    endpoint: Endpoint,
    conns: Conns,
    handler: InboundHandler,
    relay: Arc<Mutex<Option<RelayCfg>>>,
    dial_gate: Arc<Mutex<HashMap<EndpointId, DialGate>>>,
    /// Single-flight per-peer dial locks (see `conn_for`). The gate alone can't stop a burst:
    /// it's checked BEFORE `endpoint.connect` and only updated when a dial FINISHES — a dead id
    /// takes ~30s to time out, so every send queued in that window sailed through the check and
    /// opened its own doomed `Connecting`. A busy sync cycle fans out dozens of concurrent sends
    /// per peer (device-id expansion), so one offline device meant an unbounded pile of parallel
    /// handshakes, each churning iroh's per-peer path actor (`open_path_on_all_conns`) — the
    /// tens-of-GB / watchdog-panic leak in build 174.
    dialing: Arc<Mutex<HashMap<EndpointId, Arc<tokio::sync::Mutex<()>>>>>,
    /// Dials actually handed to `endpoint.connect` (diagnostics + the single-flight unit test).
    dial_attempts: Arc<std::sync::atomic::AtomicU64>,
    secret: [u8; 32], // this node's key — also the in-process relay's identity (one shared node)
}

impl Node {
    /// Bind a node using the owning identity's Ed25519 key (so `node_id_hex()` equals
    /// that identity's `node_id_bytes`), with the n0 preset: free public discovery +
    /// relays. Starts an accept loop that keeps each inbound connection alive.
    pub async fn spawn(secret: [u8; 32], handler: InboundHandler) -> Result<Self> {
        // Bind ONE endpoint for BOTH protocols — social messaging and the blob relay mailbox — so an
        // in-process relay never needs a second iroh node (the source of the path-churn leak).
        // ENABLE QUIC MULTIPATH. iroh defaults it OFF, but iroh's own DERP+hole-punch path manager ASSUMES
        // it's on: when a connection has a working relay path and iroh tries to add a direct path, multipath
        // isn't negotiated → `MultipathNotNegotiated` → it drops the outbound datagrams instead of using the
        // relay path. That made every cross-network relay GET 30s-time-out (proven by iroh trace) even though
        // the DERP relay was forwarding both ways. Enabling multipath (min 13) lets path negotiation succeed
        // so the blob request actually goes out. Both peers must enable it — they do, via this one spawn path.
        // Stock iroh transport: the IP/UDP transport is ENABLED, so peers on the same LAN connect
        // DIRECTLY (fast, no cloud round-trip), and iroh's default path selector prefers the
        // lowest-RTT path (the direct LAN one when it exists), falling back to the DERP relay only
        // when no direct path can form. We previously forced relay-only (`clear_ip_transports` +
        // a relay-pinning PathSelector) to dodge the noq/iroh multipath datagram-drop between two
        // devices on ISOLATED subnets — but that also disabled direct LAN for EVERY pair, so two
        // phones on the same wifi still bounced through a DERP relay in the cloud (and Android↔iOS,
        // which can't use Apple's Multipeer LAN mesh, had NO local path at all). Media no longer
        // rides this path (it uses the relay HTTP / S3 transports), so cross-NAT reliability no
        // longer depends on suppressing direct paths — keep them, and let the LAN be the LAN.
        // Multipath stays on (min 13) so a connection can hold a relay + a direct path at once.
        let endpoint = Endpoint::builder(N0)
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![ALPN.to_vec(), blobstore::BLOB_ALPN.to_vec()])
            .transport_config(iroh::endpoint::QuicTransportConfig::builder().max_concurrent_multipath_paths(16).build())
            .bind()
            .await
            .ah()?;
        let conns: Conns = Arc::new(Mutex::new(HashMap::new()));
        let relay: Arc<Mutex<Option<RelayCfg>>> = Arc::new(Mutex::new(None));
        let ep = endpoint.clone();
        let c = conns.clone();
        let h = handler.clone();
        let r = relay.clone();
        tokio::spawn(async move { accept_loop(ep, c, h, r).await });
        Ok(Self {
            endpoint,
            conns,
            handler,
            relay,
            dial_gate: Arc::new(Mutex::new(HashMap::new())),
            dialing: Arc::new(Mutex::new(HashMap::new())),
            dial_attempts: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            secret,
        })
    }

    /// This node's id (== the owning identity's `node_id_bytes`), as hex.
    pub fn node_id_hex(&self) -> String {
        hex(self.endpoint.id().as_bytes())
    }

    /// A relay/blob client that dials `node_hex` over THIS node's LONG-LIVED, DERP-established endpoint,
    /// instead of `BlobClient::connect` binding a fresh endpoint per fetch (which cold-starts DERP every
    /// time → cross-network relay GETs time out while warm messaging works). Reuses the same endpoint that
    /// keeps the "Connected · Relay" path alive, so media fetches ride the established relay path.
    pub fn blob_client(&self, node_hex: &str) -> Result<crate::blobstore::BlobClient> {
        let bytes = decode_hex32(node_hex)?;
        let id = EndpointId::from_bytes(&bytes).map_err(|e| anyhow!("{e:?}"))?;
        crate::blobstore::BlobClient::over_endpoint(self.endpoint.clone(), self.dial_addr(id))
    }

    /// Diagnostic-only: a blob client that dials `node_hex` at an explicit `ip:port` direct
    /// address (no relay, no discovery) — used to bisect identity vs routing failures.
    pub fn blob_client_direct(&self, node_hex: &str, direct: &str) -> Result<crate::blobstore::BlobClient> {
        let bytes = decode_hex32(node_hex)?;
        let id = EndpointId::from_bytes(&bytes).map_err(|e| anyhow!("{e:?}"))?;
        let sock: std::net::SocketAddr = direct.parse().map_err(|e| anyhow!("bad DIAG_DIRECT: {e}"))?;
        let addr = EndpointAddr::new(id).with_ip_addr(sock);
        crate::blobstore::BlobClient::over_endpoint(self.endpoint.clone(), addr)
    }

    /// Build a dial address for `id` that includes OUR home relay, so the outbound connection can use the
    /// DERP relay path immediately. Without it iroh starts the connect with relay_url=None and only tries
    /// direct hole-punch candidates — which ALL fail when two peers are behind ONE NAT on isolated subnets
    /// (same public IP won't hairpin; cross-subnet LAN is blocked) → a 30s TimedOut instead of relaying.
    /// n0 relays forward between each other, so our home relay reaches the peer even if theirs differs.
    fn dial_addr(&self, id: EndpointId) -> EndpointAddr {
        use iroh::Watcher as _;
        let mut addr = EndpointAddr::new(id);
        if let Some(s) = self.endpoint.home_relay_status().get().first() {
            addr = addr.with_relay_url(s.url().clone());
        }
        addr
    }

    /// Our current home relay URL (the DERP relay we're registered on), if established. Peers can be told
    /// this so they seed their own address book and never depend on pkarr/DNS resolving us.
    pub fn home_relay_url(&self) -> Option<String> {
        use iroh::Watcher as _;
        self.endpoint
            .home_relay_status()
            .get()
            .first()
            .map(|s| s.url().to_string())
    }


    // ---- In-process relay (blob mailbox) on THIS node's endpoint (no second iroh node) ----

    /// Start hosting the circle relay/mailbox in-process, rooted at `root`. Idempotent. The relay is
    /// served on this node's existing endpoint under the blob ALPN, so its node id == this node's id.
    /// Default retention — 30d mailbox TTL, media never deleted — i.e. exactly the pre-retention
    /// behavior; every app-embedded relay (FFI RelayHost) comes through here unchanged.
    pub fn enable_relay(&self, root: std::path::PathBuf) {
        self.enable_relay_with_retention(root, blobstore::Retention::default());
    }

    /// [`Self::enable_relay`] with an OPERATOR-chosen [`blobstore::Retention`] (the headless
    /// `haven-relay` binary's `--mailbox-ttl-days` / `--media-max-age-days` / `--media-max-bytes`).
    pub fn enable_relay_with_retention(&self, root: std::path::PathBuf, retention: blobstore::Retention) {
        let mut g = lock(&self.relay);
        if g.is_none() {
            *g = Some(RelayCfg {
                root: root.clone(),
                auth: Arc::new(Mutex::new(blobstore::RelayAuth::default())),
                http: None,
                retention,
            });
            // Stamp the GC-enabled marker(s) now so the 48h first-enable grace clock starts.
            let _ = blobstore::gc_sweep_with(&root, &retention, blobstore::GC_GRACE);
            // Hourly GC for the in-process store. A plain thread (not a tokio task):
            // `RelayServerHandle.attach` calls this from outside any async runtime on the app
            // platforms. Wakes every minute so it exits promptly once the relay is disabled.
            let holder = Arc::downgrade(&self.relay);
            std::thread::spawn(move || {
                let mut slept = std::time::Duration::ZERO;
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(60));
                    slept += std::time::Duration::from_secs(60);
                    let Some(relay) = holder.upgrade() else { return };
                    let Some((root, retention)) =
                        lock(&relay).as_ref().map(|c| (c.root.clone(), c.retention))
                    else {
                        return;
                    };
                    if slept >= blobstore::GC_INTERVAL {
                        slept = std::time::Duration::ZERO;
                        let stats = blobstore::gc_sweep_with(&root, &retention, blobstore::GC_GRACE);
                        // Operator visibility, but ONLY when a media limit is configured —
                        // default (app-embedded) relays keep the existing no-output posture.
                        if retention.media_limited() {
                            println!(
                                "▸ retention sweep: {} media aged out, {} evicted for size, {} freed \
                                 ({} mailbox pruned) — media store now {}.",
                                stats.media_deleted_age,
                                stats.media_deleted_size,
                                blobstore::fmt_bytes(stats.media_bytes_freed),
                                stats.mailbox_deleted,
                                blobstore::fmt_bytes(stats.media_bytes_total),
                            );
                        }
                    }
                }
            });
        }
    }
    /// Stop hosting (drop the relay attachment — also stops the HTTP interface if serving).
    pub fn disable_relay(&self) {
        *lock(&self.relay) = None;
    }

    /// Serve the hosted relay's store over plain HTTP on `bind` (see [`httprelay`]) — the default
    /// cross-NAT media transport. `token` is the shared relay secret clients fold into each request
    /// signature (distributed to circle members inside the sealed relay announce). Returns the bound
    /// port. Idempotent while already serving (returns the existing port). Errors if no relay is
    /// hosted here.
    pub async fn relay_serve_http(&self, bind: &str, token: &str) -> Result<u16> {
        let (root, auth) = {
            let g = lock(&self.relay);
            let Some(cfg) = g.as_ref() else { return Err(anyhow!("relay not hosted")) };
            if let Some(h) = cfg.http.as_ref() {
                return Ok(h.port());
            }
            // The HTTP transport shares the iroh path's membership map — one relay, one policy,
            // whichever port a member arrives on (audit F2).
            (cfg.root.clone(), cfg.auth.clone())
        };
        let server = httprelay::serve(root, bind, token.to_string(), auth).await?;
        let port = server.port();
        if let Some(cfg) = lock(&self.relay).as_mut() {
            cfg.http = Some(Arc::new(server));
        }
        Ok(port)
    }
    pub fn relay_enabled(&self) -> bool {
        lock(&self.relay).is_some()
    }
    /// Authorize a circle's mailbox to exactly `members` + sibling `relays` (membership enforcement).
    pub fn relay_authorize(&self, circle_id: &str, members: Vec<String>, relays: Vec<String>) {
        if let Some(cfg) = lock(&self.relay).as_ref() {
            lock(&cfg.auth).authorize(circle_id, members, relays);
            // authorize() sets the member set fresh (account ids only). Re-expand to the accounts'
            // DEVICE ids from any device rosters already stored on this relay, so a headless relay
            // that (re)authorizes circles on startup doesn't drop device authorization until the apps
            // re-publish. Signature-verified inside; safe to call on every authorize.
            blobstore::rehydrate_device_rosters(&cfg.root, &cfg.auth);
        }
    }
    pub fn relay_deauthorize(&self, circle_id: &str) {
        if let Some(cfg) = lock(&self.relay).as_ref() {
            lock(&cfg.auth).deauthorize(circle_id);
        }
    }
    /// Store the host's OWN sealed event/media directly into the relay store — NO iroh self-connection
    /// (which is what blew up iroh's path machinery). Returns false if the relay isn't hosted here.
    pub fn relay_local_put(&self, key: &str, data: &[u8]) -> bool {
        let root = lock(&self.relay).as_ref().map(|c| c.root.clone());
        root.map(|r| blobstore::local_put(&r, key, data).is_ok()).unwrap_or(false)
    }
    /// True if the in-process relay store already holds `key`.
    pub fn relay_local_has(&self, key: &str) -> bool {
        let root = lock(&self.relay).as_ref().map(|c| c.root.clone());
        root.map(|r| blobstore::local_has(&r, key)).unwrap_or(false)
    }
    /// Read a blob from the in-process relay store — the HOST reading its OWN mailbox (a sibling device's
    /// or a friend's upload) without dialing itself. None if not hosting or the key is absent.
    pub fn relay_local_get(&self, key: &str) -> Option<Vec<u8>> {
        let root = lock(&self.relay).as_ref().map(|c| c.root.clone())?;
        blobstore::local_get(&root, key)
    }
    /// Every key under `prefix` the in-process relay store holds (host enumerating its OWN mailbox to
    /// ingest what others uploaded to it). Empty if not hosting.
    pub fn relay_local_list(&self, prefix: &str) -> Vec<String> {
        let root = lock(&self.relay).as_ref().map(|c| c.root.clone());
        root.map(|r| blobstore::local_list(&r, prefix)).unwrap_or_default()
    }

    /// Refresh the liveness stamp of `keys` in the in-process relay store (the HOST's own daily
    /// mailbox refresh — it can't TOUCH itself over iroh, self-dial guard). Returns the keys the
    /// store does NOT hold so the caller re-PUTs them; all keys back if not hosting (caller treats
    /// that like an unreachable relay and skips).
    pub fn relay_local_touch(&self, keys: &[String]) -> Vec<String> {
        let Some(root) = lock(&self.relay).as_ref().map(|c| c.root.clone()) else {
            return keys.to_vec();
        };
        blobstore::local_touch(&root, keys)
    }

    /// Mesh anti-entropy: pull every sealed blob a SIBLING relay holds that our in-process relay lacks,
    /// into our store (idempotent set-union). No-op if we don't host a relay. Returns blobs pulled.
    pub async fn relay_sync_from(&self, peer_node_hex: &str) -> usize {
        let Some((root, retention)) =
            lock(&self.relay).as_ref().map(|c| (c.root.clone(), c.retention))
        else {
            return 0;
        };
        // Reuse THIS node's endpoint — a fresh `BlobClient::connect(self.secret, …)` endpoint shares
        // our node id, so it STEALS our DERP relay registration every mesh tick (home-relay flap) and
        // refuses all inbound handshakes while it lives. That single line made relay-path INBOUND to
        // any relay-hosting device effectively dead (dials timed out at 30s; direct dials took ~5ms).
        let Ok(client) = self.blob_client(peer_node_hex) else { return 0 };
        // Age-preserving pull (shared with BlobServer::sync_pull_from): entries past OUR
        // retention (mailbox TTL; media under the operator's own limits) are never pulled
        // back, and pulled files keep the peer's idle age — so a GC'd entry can't ping-pong
        // between sibling relays forever.
        let pulled = blobstore::pull_missing_from_peer(&root, &client, &retention).await;
        let _ = client.close().await;
        pulled
    }

    /// Send a payload to a contact by their hex node id. Discovery resolves the live
    /// address; an existing (dialed or accepted) connection is reused if present.
    pub async fn send_to_node(&self, node_id_hex: &str, payload: &[u8]) -> Result<()> {
        let bytes = decode_hex32(node_id_hex)?;
        let id = EndpointId::from_bytes(&bytes).map_err(|e| anyhow!("{e:?}"))?;
        self.send(self.dial_addr(id), payload).await
    }

    /// Send a payload to a peer address (reusing a live connection if one exists).
    pub async fn send(&self, to: EndpointAddr, payload: &[u8]) -> Result<()> {
        let conn = self.conn_for(to).await?;
        let mut s = conn.open_uni().await.ah()?;
        s.write_all(payload).await.ah()?;
        s.finish().ah()?;
        Ok(())
    }

    /// Reuse a live connection to this peer, or dial a fresh one (and start reading
    /// replies on it).
    async fn conn_for(&self, addr: EndpointAddr) -> Result<Connection> {
        let id = addr.id;
        // NEVER open a connection to our OWN endpoint id. A node dialing itself sends iroh's path
        // discovery into an unbounded loop (open_path_on_all_conns → tens of GB — THE self-connect leak).
        // Guard it here at the single messaging dial chokepoint so NO caller (roster announce, hello,
        // relay originate, a stale self entry in any target list) can trigger it, under any transport id.
        if id == self.endpoint.id() {
            anyhow::bail!("refusing to dial our own node id (self-connect guard)");
        }
        if let Some(c) = lock(&self.conns).get(&id).cloned() {
            if c.close_reason().is_none() {
                return Ok(c);
            }
        }
        // SINGLE-FLIGHT: at most ONE in-flight dial per peer id. Concurrent senders queue on the
        // per-id lock; when the winner finishes they re-check the live-conn map (reuse its
        // connection) and the dial gate (its failure gates them out) instead of each opening
        // their own parallel `Connecting`. Without this, a burst of sends to an offline device
        // all passed the gate check while the first 30s dial was still in flight — hundreds of
        // simultaneous doomed handshakes churning iroh's path machinery (the build-174 leak).
        let dial_lock = lock(&self.dialing).entry(id).or_insert_with(|| Arc::new(tokio::sync::Mutex::new(()))).clone();
        let _guard = dial_lock.lock().await;
        // A queued sender wakes here after the winner's dial resolved: reuse its connection…
        if let Some(c) = lock(&self.conns).get(&id).cloned() {
            if c.close_reason().is_none() {
                return Ok(c);
            }
        }
        // Per-peer backoff: an id that just failed to connect is NOT redialed until its cooldown
        // expires (30s doubling to 10min). A live connection resets it; ids that are permanently
        // dead (account ids under device-seed transport) settle at one cheap attempt per 10min
        // instead of a continuous handshake storm that drowns our own relay path.
        // (…or, if the winner FAILED, its strike below is now visible and gates the whole queue.)
        {
            let gate = lock(&self.dial_gate);
            if let Some(g) = gate.get(&id) {
                if std::time::Instant::now() < g.until {
                    anyhow::bail!("dial backoff: {} unreachable, retry later", hex(id.as_bytes()));
                }
            }
        }
        self.dial_attempts.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        match self.endpoint.connect(addr, ALPN).await.ah() {
            Ok(conn) => {
                // Do NOT clear the dial gate here: a connect that succeeds but dies young (a
                // FLAPPING peer — e.g. a node whose key is bound by two endpoints trading the DERP
                // registration) would otherwise reset its backoff on every redial, and each
                // short-lived connection leaves iroh's per-peer path actor churning
                // (close → open_path → close, ~30MB/min of fresh QUIC state — the 3GB jetsam).
                // read_loop clears the gate once the connection proves healthy (lives ≥ 30s),
                // and records a strike if it dies younger.
                lock(&self.conns).insert(id, conn.clone());
                let c = self.conns.clone();
                let h = self.handler.clone();
                let g = self.dial_gate.clone();
                let cc = conn.clone();
                tokio::spawn(async move { read_loop(cc, c, h, Some(g)).await });
                Ok(conn)
            }
            Err(e) => {
                let mut gate = lock(&self.dial_gate);
                let g = gate.entry(id).or_insert(DialGate { fails: 0, until: std::time::Instant::now() });
                g.fails = g.fails.saturating_add(1);
                let secs = (30u64 << (g.fails.min(5) - 1)).min(600); // 30s, 60s, … capped at 10min
                g.until = std::time::Instant::now() + std::time::Duration::from_secs(secs);
                if gate.len() > 512 {
                    // Bound the map (stale entries for ids we no longer dial).
                    let now = std::time::Instant::now();
                    gate.retain(|_, g| g.until > now);
                }
                drop(gate);
                // Bound the single-flight map the same way: entries nobody currently holds
                // (strong_count == 1 → only the map's own Arc) are stale and safe to drop —
                // a racing sender simply re-inserts a fresh lock.
                let mut dialing = lock(&self.dialing);
                if dialing.len() > 512 {
                    dialing.retain(|_, m| Arc::strong_count(m) > 1);
                }
                Err(e)
            }
        }
    }

    /// How many dials were actually handed to `endpoint.connect` over this node's lifetime.
    /// Diagnostics + the single-flight regression test (a send burst to one dead id must
    /// produce ONE attempt, not one per sender).
    pub fn dial_attempt_count(&self) -> u64 {
        self.dial_attempts.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Send a sealed payload to `final_dest` **via a relay**: wrap it in a mesh-relay
    /// frame addressed to the destination(s), then hand that frame to the relay node
    /// (by the relay's hex node id). The relay forwards the opaque payload onward; it
    /// can read only the destination ids, never the sealed bytes.
    pub async fn send_via_relay(
        &self,
        relay_node_hex: &str,
        final_dest: Vec<[u8; 32]>,
        payload: &[u8],
    ) -> Result<()> {
        let frame = relay::RoutingFrame::new(final_dest, payload.to_vec(), relay::DEFAULT_TTL);
        self.send_to_node(relay_node_hex, &frame.to_bytes()).await
    }

    /// Same-machine dial address (loopback + this node's port), for local tests.
    pub async fn local_dial_addr(&self) -> Result<EndpointAddr> {
        let addr = wait_for_direct_addr(&self.endpoint).await?;
        let port = addr
            .ip_addrs()
            .next()
            .map(|a| a.port())
            .ok_or_else(|| anyhow!("no direct port yet"))?;
        Ok(EndpointAddr::new(addr.id).with_ip_addr(SocketAddr::from(([127, 0, 0, 1], port))))
    }

    /// A shareable ticket (base32 of this node's address) for a peer to dial.
    pub async fn ticket(&self) -> Result<String> {
        let addr = wait_for_direct_addr(&self.endpoint).await?;
        Ok(BASE32_NOPAD.encode(&serde_json::to_vec(&addr).ah()?))
    }

    /// Send a payload to a peer identified by their [`Node::ticket`].
    pub async fn send_ticket(&self, ticket: &str, payload: &[u8]) -> Result<()> {
        let bytes = BASE32_NOPAD
            .decode(ticket.trim().as_bytes())
            .map_err(|_| anyhow!("bad ticket"))?;
        let addr: EndpointAddr = serde_json::from_slice(&bytes).map_err(|_| anyhow!("bad ticket"))?;
        self.send(addr, payload).await
    }

    pub async fn close(self) {
        self.endpoint.close().await;
    }
}

/// An always-on **connection relay**: a node that forwards mesh-relay frames toward
/// circle members it can reach, without ever reading the sealed payload.
///
/// It binds its own iroh identity (so members can dial it / it can dial them), keeps a
/// bounded RAM-only dedup set, and on each inbound [`relay::RoutingFrame`]:
///   1. drops it if the `msg_id` was already seen (loop/replay guard),
///   2. drops it if `ttl == 0`,
///   3. otherwise decrements the ttl and forwards the *same opaque payload* to every
///      destination node id in the header (except itself), re-wrapped in a fresh frame.
///
/// The relay never opens, stores, or logs the payload. It only moves ciphertext.
pub struct RelayNode {
    node: Arc<Node>,
    me_hex: String,
    seen: Arc<Mutex<relay::SeenSet>>,
    /// Node hexes this relay will forward for / toward (see [`RelayNode::authorize_forwarding`]).
    fwd_members: Arc<Mutex<std::collections::HashSet<String>>>,
}

impl RelayNode {
    /// Spawn a relay bound to `secret` (its own identity key). `on_frame`, if provided,
    /// is invoked with each *destination-matches-me* payload — i.e. when this relay is
    /// itself a listed recipient — so a relay that is also a normal member can still
    /// receive. Pure forwarders pass `None`.
    pub async fn spawn(
        secret: [u8; 32],
        on_frame: Option<InboundHandler>,
    ) -> Result<Arc<Self>> {
        // Late-bound self-reference so the inbound handler can forward via the node.
        let holder: Arc<Mutex<Option<Arc<RelayNode>>>> = Arc::new(Mutex::new(None));
        let seen: Arc<Mutex<relay::SeenSet>> = Arc::new(Mutex::new(relay::SeenSet::default()));

        let h = holder.clone();
        let handler: InboundHandler = Arc::new(move |from: [u8; 32], bytes: Vec<u8>| {
            let this = lock(&h).clone();
            if let Some(this) = this {
                let deliver = on_frame.clone();
                tokio::spawn(async move {
                    this.handle_inbound(from, bytes, deliver).await;
                });
            }
        });

        let node = Arc::new(Node::spawn(secret, handler).await?);
        let me_hex = node.node_id_hex();
        let relay = Arc::new(RelayNode { node, me_hex, seen, fwd_members: Arc::new(Mutex::new(Default::default())) });
        *lock(&holder) = Some(relay.clone());
        Ok(relay)
    }

    /// This relay's node id (hex) — the value that goes in a circle's "relays" list.
    pub fn node_id_hex(&self) -> String {
        self.me_hex.clone()
    }

    /// The underlying node — so a standalone daemon can host the blob mailbox on THIS endpoint
    /// (`enable_relay`/`relay_authorize`/`relay_sync_from`) instead of spawning a second iroh
    /// endpoint under the same key, which steals the DERP home-relay registration and makes the
    /// relay flap between reachable and unreachable (the same-key second-endpoint bug).
    pub fn node(&self) -> Arc<Node> {
        self.node.clone()
    }

    /// Same-machine dial address (loopback), for local/integration tests.
    pub async fn local_dial_addr(&self) -> Result<EndpointAddr> {
        self.node.local_dial_addr().await
    }

    /// Forward a frame on behalf of a member who can't reach the destinations directly.
    /// (Members call this by sending the relay a [`relay::RoutingFrame`]; this is also
    /// the programmatic entry used in tests / when wrapping locally.)
    pub async fn forward(&self, frame: relay::RoutingFrame) {
        self.handle_inbound([0u8; 32], frame.to_bytes(), None).await;
    }

    /// Restrict forwarding to this circle's members (audit F10). Until this is called the relay
    /// forwards for anyone — which is only safe for a relay nobody else knows the node id of, so
    /// every shipped host calls it. Idempotent; call again to replace the set.
    pub fn authorize_forwarding(&self, members: Vec<String>) {
        *lock(&self.fwd_members) = members.into_iter().collect();
    }

    /// May we forward this frame? A relay is a switchboard for ITS circle, not for the internet:
    /// without this, one 256 MB frame from any stranger who learned the node id became up to 32
    /// outbound sends (~8 GB) aimed at node ids of the stranger's choosing — a DoS reflector
    /// pointed at third parties (audit F10). Either end must belong to us: we forward what a
    /// member sends, and we forward toward a member. A locally-injected frame (`from` all-zeros,
    /// i.e. our own `forward()`) is ours by definition.
    fn may_forward(&self, from: [u8; 32], frame: &relay::RoutingFrame) -> bool {
        let members = lock(&self.fwd_members);
        if members.is_empty() {
            return true; // unconfigured forwarder — no membership to check against
        }
        if from == [0u8; 32] || members.contains(&relay::RoutingFrame::dest_hex(&from)) {
            return true;
        }
        frame.dest.iter().any(|d| members.contains(&relay::RoutingFrame::dest_hex(d)))
    }

    async fn handle_inbound(&self, from: [u8; 32], bytes: Vec<u8>, deliver: Option<InboundHandler>) {
        let Some(frame) = relay::RoutingFrame::parse(&bytes) else {
            // Not a relay frame: a bare payload addressed straight to us — the sender IS the
            // authenticated connection peer, so pass its id through (a relay-hosting member
            // otherwise never learns reply-path hints from direct hellos). Pure forwarders
            // (no member handler) ignore.
            if let Some(d) = deliver {
                d(from, bytes);
            }
            return;
        };

        // Loop / replay guard (RAM-only, bounded).
        if !lock(&self.seen).insert(frame.msg_id) {
            return;
        }

        // If we're one of the destinations and we're acting as a member too, deliver
        // the inner payload locally.
        let me_is_dest = frame
            .dest
            .iter()
            .any(|d| relay::RoutingFrame::dest_hex(d) == self.me_hex);
        if me_is_dest {
            if let Some(d) = &deliver {
                // Zero sender: the payload was relay-routed — the immediate peer is the
                // forwarder, not the author, so no id here is author-authenticated.
                d([0u8; 32], frame.payload.clone());
            }
        }

        if frame.ttl == 0 {
            return;
        }
        // Amplification gates (audit F10). Local delivery above already happened — these bound only
        // what we re-send on someone else's behalf.
        if !self.may_forward(from, &frame) {
            return;
        }
        if frame.payload.len() > relay::MAX_RELAY_PAYLOAD {
            return; // media rides the HTTP/S3 transports; a routed frame this big is not a message
        }
        let next_ttl = frame.ttl - 1;

        // Forward the SAME opaque payload to every other destination. We re-wrap with a
        // fresh single-dest frame per hop, preserving the original msg_id so downstream
        // relays dedup the whole multicast as one message.
        for d in &frame.dest {
            let dh = relay::RoutingFrame::dest_hex(d);
            if dh == self.me_hex {
                continue;
            }
            let fwd = relay::RoutingFrame {
                ttl: next_ttl,
                msg_id: frame.msg_id,
                dest: vec![*d],
                payload: frame.payload.clone(),
            };
            // Best-effort: a destination we can't reach right now is simply skipped; the
            // member will get it from the storage mailbox or a later online overlap.
            let _ = self.node.send_to_node(&dh, &fwd.to_bytes()).await;
        }
    }

    pub async fn close(self: Arc<Self>) {
        // Drop our reference; the underlying endpoint closes when the last Arc to the
        // inner Node is gone. We expose an explicit no-panic close for symmetry.
        if let Ok(node) = Arc::try_unwrap(self) {
            if let Ok(inner) = Arc::try_unwrap(node.node) {
                inner.close().await;
            }
        }
    }
}

async fn accept_loop(
    endpoint: Endpoint,
    conns: Conns,
    handler: InboundHandler,
    relay: Arc<Mutex<Option<RelayCfg>>>,
) {
    while let Some(incoming) = endpoint.accept().await {
        let conns = conns.clone();
        let handler = handler.clone();
        let relay = relay.clone();
        tokio::spawn(async move {
            let Ok(connecting) = incoming.accept() else { return };
            let Ok(conn) = connecting.await else { return };
            // Dispatch by negotiated ALPN: the blob mailbox vs social messaging — ONE endpoint, two
            // protocols, so the relay needs no second iroh node.
            if conn.alpn() == blobstore::BLOB_ALPN {
                let Some(cfg) = lock(&relay).clone() else { return }; // relay not hosted here → ignore
                let peer = hex(conn.remote_id().as_bytes());
                loop {
                    match conn.accept_bi().await {
                        Ok((send, recv)) => {
                            let (root, peer, auth) = (cfg.root.clone(), peer.clone(), cfg.auth.clone());
                            tokio::spawn(async move {
                                let _ = blobstore::handle_request(root, peer, auth, send, recv).await;
                            });
                        }
                        Err(_) => break,
                    }
                }
                return;
            }
            // Social: keep the inbound connection so we can send back to a peer who dialed us
            // (they may be unreachable for us to dial directly). No dial gate: backoff applies
            // to OUR outbound dials, not to who may dial us.
            lock(&conns).insert(conn.remote_id(), conn.clone());
            read_loop(conn, conns, handler, None).await;
        });
    }
}

/// Read every uni stream on a connection as one message, for the connection's life.
/// `dial_gate` (outbound connections only) makes the per-peer backoff flap-aware: a connection
/// that dies within 30s counts as a FAILURE (strike → 30s..10min cooldown), one that lives
/// longer clears the gate. Without this, connect-success reset the backoff every time, so a
/// flapping peer was redialed each sync tick and every short-lived connection fed iroh's
/// path-churn loop (the +2.8GB-in-100s runaway).
async fn read_loop(
    conn: Connection,
    conns: Conns,
    handler: InboundHandler,
    dial_gate: Option<Arc<Mutex<HashMap<EndpointId, DialGate>>>>,
) {
    // The connection's remote endpoint id — the sender's AUTHENTICATED device transport id.
    // Surfacing it lets the app learn a dialable id for a contact from any frame they deliver
    // directly (the reply-path bootstrap: an invitee holds no dial hints for the initiator, so
    // without this their hello-back/DMs relied on roster propagation that itself needs a route).
    let from = *conn.remote_id().as_bytes();
    let started = std::time::Instant::now();
    loop {
        match conn.accept_uni().await {
            Ok(mut recv) => {
                let handler = handler.clone();
                tokio::spawn(async move {
                    if let Ok(payload) = recv.read_to_end(MAX_PAYLOAD).await {
                        // The handler crosses into a foreign (Swift) callback — a panic
                        // there would abort the whole app, so contain it.
                        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            handler(from, payload);
                        }));
                    }
                });
            }
            Err(_) => break,
        }
    }
    let id = conn.remote_id();
    if let Some(gate) = dial_gate {
        let mut gate = lock(&gate);
        if started.elapsed() >= std::time::Duration::from_secs(30) {
            gate.remove(&id); // proved healthy — a future dial starts fresh
        } else {
            let g = gate.entry(id).or_insert(DialGate { fails: 0, until: std::time::Instant::now() });
            g.fails = g.fails.saturating_add(1);
            let secs = (30u64 << (g.fails.min(5) - 1)).min(600);
            g.until = std::time::Instant::now() + std::time::Duration::from_secs(secs);
        }
    }
    let mut map = lock(&conns);
    if map.get(&id).map(|c| c.close_reason().is_some()).unwrap_or(false) {
        map.remove(&id);
    }
}

async fn wait_for_direct_addr(endpoint: &Endpoint) -> Result<EndpointAddr> {
    for _ in 0..50 {
        let addr = endpoint.addr();
        if addr.ip_addrs().next().is_some() {
            return Ok(addr);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(anyhow!("no direct addresses discovered within 5s"))
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn decode_hex32(s: &str) -> Result<[u8; 32]> {
    let s = s.trim();
    if s.len() != 64 {
        return Err(anyhow!("node id must be 64 hex chars"));
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).map_err(|_| anyhow!("bad hex"))?;
    }
    Ok(out)
}
