//! Haven networking — an iroh-backed P2P node that carries opaque payloads (in
//! practice, `p2pcore::social::SealedEnvelope` bytes) between peers over QUIC.
//!
//! Connections are **kept alive and reused bidirectionally**: each message is a uni
//! stream on a cached connection keyed by the remote's node id. Whoever can reach the
//! other dials once; both then send over that same connection. This is what lets
//! delivery flow both ways even when one peer is behind a NAT that can't be dialed
//! directly. The bytes on the wire are already end-to-end encrypted by `p2pcore`.

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
pub mod relay;
pub mod s3tunnel;

const ALPN: &[u8] = b"haven/social/0";
const MAX_PAYLOAD: usize = 256 * 1024 * 1024;

/// Called for each inbound payload (sealed envelope / protocol frame bytes).
pub type InboundHandler = Arc<dyn Fn(Vec<u8>) + Send + Sync>;

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
}

/// A peer-to-peer node.
pub struct Node {
    endpoint: Endpoint,
    conns: Conns,
    handler: InboundHandler,
    relay: Arc<Mutex<Option<RelayCfg>>>,
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
        Ok(Self { endpoint, conns, handler, relay, secret })
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
    pub fn enable_relay(&self, root: std::path::PathBuf) {
        let mut g = lock(&self.relay);
        if g.is_none() {
            *g = Some(RelayCfg { root, auth: Arc::new(Mutex::new(blobstore::RelayAuth::default())), http: None });
        }
    }
    /// Stop hosting (drop the relay attachment — also stops the HTTP interface if serving).
    pub fn disable_relay(&self) {
        *lock(&self.relay) = None;
    }

    /// Serve the hosted relay's store over plain HTTP on `bind` (see [`httprelay`]) — the default
    /// cross-NAT media transport. `token` is the bearer token clients must present (distributed to
    /// circle members inside the sealed relay announce). Returns the bound port. Idempotent while
    /// already serving (returns the existing port). Errors if no relay is hosted here.
    pub async fn relay_serve_http(&self, bind: &str, token: &str) -> Result<u16> {
        let root = {
            let g = lock(&self.relay);
            let Some(cfg) = g.as_ref() else { return Err(anyhow!("relay not hosted")) };
            if let Some(h) = cfg.http.as_ref() {
                return Ok(h.port());
            }
            cfg.root.clone()
        };
        let server = httprelay::serve(root, bind, token.to_string()).await?;
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

    /// Mesh anti-entropy: pull every sealed blob a SIBLING relay holds that our in-process relay lacks,
    /// into our store (idempotent set-union). No-op if we don't host a relay. Returns blobs pulled.
    pub async fn relay_sync_from(&self, peer_node_hex: &str) -> usize {
        let Some(root) = lock(&self.relay).as_ref().map(|c| c.root.clone()) else { return 0 };
        let Ok(client) = blobstore::BlobClient::connect(self.secret, peer_node_hex).await else { return 0 };
        let mut pulled = 0usize;
        let peer_keys = client.list(blobstore::SYNC_PREFIX).await.unwrap_or_default();
        for key in blobstore::keys_to_pull(&root, &peer_keys) {
            let Ok(local) = blobstore::safe_path(&root, &key) else { continue };
            let Ok(Some(blob)) = client.get(&key).await else { continue };
            if blob.is_empty() {
                continue;
            }
            if let Some(parent) = local.parent() {
                std::fs::create_dir_all(parent).ok();
            }
            let tmp = local.with_extension("part");
            if std::fs::write(&tmp, &blob).and_then(|_| std::fs::rename(&tmp, &local)).is_ok() {
                pulled += 1;
            } else {
                let _ = std::fs::remove_file(&tmp);
            }
        }
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
        let conn = self.endpoint.connect(addr, ALPN).await.ah()?;
        lock(&self.conns).insert(id, conn.clone());
        let c = self.conns.clone();
        let h = self.handler.clone();
        let cc = conn.clone();
        tokio::spawn(async move { read_loop(cc, c, h).await });
        Ok(conn)
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
        let handler: InboundHandler = Arc::new(move |bytes: Vec<u8>| {
            let this = lock(&h).clone();
            if let Some(this) = this {
                let deliver = on_frame.clone();
                tokio::spawn(async move {
                    this.handle_inbound(bytes, deliver).await;
                });
            }
        });

        let node = Arc::new(Node::spawn(secret, handler).await?);
        let me_hex = node.node_id_hex();
        let relay = Arc::new(RelayNode { node, me_hex, seen });
        *lock(&holder) = Some(relay.clone());
        Ok(relay)
    }

    /// This relay's node id (hex) — the value that goes in a circle's "relays" list.
    pub fn node_id_hex(&self) -> String {
        self.me_hex.clone()
    }

    /// Same-machine dial address (loopback), for local/integration tests.
    pub async fn local_dial_addr(&self) -> Result<EndpointAddr> {
        self.node.local_dial_addr().await
    }

    /// Forward a frame on behalf of a member who can't reach the destinations directly.
    /// (Members call this by sending the relay a [`relay::RoutingFrame`]; this is also
    /// the programmatic entry used in tests / when wrapping locally.)
    pub async fn forward(&self, frame: relay::RoutingFrame) {
        self.handle_inbound(frame.to_bytes(), None).await;
    }

    async fn handle_inbound(&self, bytes: Vec<u8>, deliver: Option<InboundHandler>) {
        let Some(frame) = relay::RoutingFrame::parse(&bytes) else {
            // Not a relay frame: a bare payload addressed straight to us. Deliver if we
            // have a member handler; otherwise (pure forwarder) ignore.
            if let Some(d) = deliver {
                d(bytes);
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
                d(frame.payload.clone());
            }
        }

        if frame.ttl == 0 {
            return;
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
            // (they may be unreachable for us to dial directly).
            lock(&conns).insert(conn.remote_id(), conn.clone());
            read_loop(conn, conns, handler).await;
        });
    }
}

/// Read every uni stream on a connection as one message, for the connection's life.
async fn read_loop(conn: Connection, conns: Conns, handler: InboundHandler) {
    loop {
        match conn.accept_uni().await {
            Ok(mut recv) => {
                let handler = handler.clone();
                tokio::spawn(async move {
                    if let Ok(payload) = recv.read_to_end(MAX_PAYLOAD).await {
                        // The handler crosses into a foreign (Swift) callback — a panic
                        // there would abort the whole app, so contain it.
                        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            handler(payload);
                        }));
                    }
                });
            }
            Err(_) => break,
        }
    }
    let id = conn.remote_id();
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
