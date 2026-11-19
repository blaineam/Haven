//! The network objects the engine drives: the node that carries live frames, a relay's blob
//! mailbox over the node, and the handle of a relay hosted in-process.
//!
//! Natively these are `haven_ffi`'s (the iroh node and its blob ALPN). In a browser the node is
//! relay-only and supplied by the page's build (`haven-web`), the mailbox is reached over signed
//! HTTPS rather than the blob ALPN, and nothing can be hosted — see [`web`].

#[cfg(not(target_arch = "wasm32"))]
pub use haven_ffi::{HavenNode, InboundListener, RelayClient, RelayServerHandle};

#[cfg(target_arch = "wasm32")]
pub use web::*;

/// The browser's transport. A tab cannot bind UDP, accept inbound connections or hole-punch, so
/// its node reaches peers only through relays (a circle's own DERP when one is known, n0's
/// otherwise) — the same `haven/social/0` wire, one uni stream per frame.
#[cfg(target_arch = "wasm32")]
pub mod web {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    use haven_ffi::{HavenError, HavenSocial};
    use haven_p2p::identity::Identity;
    use iroh::endpoint::{presets, Connection, Endpoint, QuicTransportConfig};
    use iroh::{EndpointAddr, EndpointId, RelayConfig, RelayMode, RelayUrl, SecretKey};

    /// Same ALPN as `haven_net` — a browser node is a peer on the same protocol.
    const ALPN: &[u8] = b"haven/social/0";
    /// Same per-frame cap as `haven_net`.
    const MAX_PAYLOAD: usize = 256 * 1024 * 1024;
    /// Must match `haven_net::endpoint_builder` — both ends negotiate multipath or neither does.
    const MAX_MULTIPATH: u32 = 9;

    fn invalid(e: impl std::fmt::Debug) -> HavenError {
        HavenError::Invalid { msg: format!("{e:?}") }
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn endpoint_id(node_hex: &str) -> Result<EndpointId, HavenError> {
        let bytes = hex::decode(node_hex.trim()).map_err(invalid)?;
        let bytes: [u8; 32] = bytes.try_into().map_err(|_| invalid("node id must be 32 bytes"))?;
        EndpointId::from_bytes(&bytes).map_err(invalid)
    }

    /// Inbound frame callback — the same contract as the native listener: `from_hex` is the
    /// transport-authenticated node id of the connection the frame arrived on.
    pub trait InboundListener: Send + Sync {
        fn on_inbound(&self, from_hex: String, payload: Vec<u8>);
    }

    type Conns = Arc<Mutex<HashMap<EndpointId, Connection>>>;

    fn lock(c: &Conns) -> std::sync::MutexGuard<'_, HashMap<EndpointId, Connection>> {
        c.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A relay-only Haven node.
    pub struct HavenNode {
        endpoint: Endpoint,
        /// The circle DERP this node was bound with, used as the dial hint for peers on it.
        home: Option<RelayUrl>,
        conns: Conns,
        listener: Arc<dyn InboundListener>,
    }

    impl HavenNode {
        /// Bind a node under `seed`'s node key. The relay map is the circle's DERP URLs known at
        /// bind time (`crate::net::apply_derp_urls`) on top of n0's public relays, mirroring the
        /// native "Haven preferred, n0 as the fallback rendezvous" policy.
        pub async fn start(seed: Vec<u8>, listener: Arc<dyn InboundListener>) -> Result<Arc<Self>, HavenError> {
            let seed: [u8; 32] = seed.try_into().map_err(|_| invalid("seed must be 32 bytes"))?;
            let secret = Identity::from_seed(&seed).node_secret_bytes();
            let customs: Vec<RelayUrl> =
                crate::net::active_derp_urls().iter().filter_map(|u| u.parse::<RelayUrl>().ok()).collect();
            let map = RelayMode::Default.relay_map();
            for url in &customs {
                map.insert(url.clone(), Arc::new(RelayConfig::new(url.clone(), None)));
            }
            let endpoint = Endpoint::builder(presets::N0)
                .secret_key(SecretKey::from_bytes(&secret))
                .alpns(vec![ALPN.to_vec()])
                .relay_mode(RelayMode::Custom(map))
                .transport_config(QuicTransportConfig::builder().max_concurrent_multipath_paths(MAX_MULTIPATH).build())
                .bind()
                .await
                .map_err(invalid)?;
            let conns: Conns = Arc::new(Mutex::new(HashMap::new()));
            {
                let (ep, conns, listener) = (endpoint.clone(), conns.clone(), listener.clone());
                crate::rt::spawn(async move {
                    while let Some(incoming) = ep.accept().await {
                        let (conns, listener) = (conns.clone(), listener.clone());
                        crate::rt::spawn(async move {
                            let Ok(connecting) = incoming.accept() else { return };
                            let Ok(conn) = connecting.await else { return };
                            lock(&conns).insert(conn.remote_id(), conn.clone());
                            read_loop(conn, conns, listener).await;
                        });
                    }
                });
            }
            Ok(Arc::new(Self { endpoint, home: customs.into_iter().next(), conns, listener }))
        }

        /// Resolves once a relay connection is up — the point at which peers can reach this node.
        pub async fn online(&self) {
            self.endpoint.online().await;
        }

        pub async fn shutdown(&self) {
            lock(&self.conns).clear();
            self.endpoint.close().await;
        }

        pub fn node_id_hex(&self) -> String {
            hex(self.endpoint.id().as_bytes())
        }

        /// The browser node keeps no dial backoff, so there is never a gate to forgive.
        pub fn forgive_dial(&self, _node_hex: String) -> bool {
            false
        }

        pub fn forgive_all_dials(&self) -> u32 {
            0
        }

        /// A relay's mailbox over the node's blob ALPN is not offered in a browser: the same
        /// mailbox is reached over the relay's signed HTTPS interface instead.
        pub async fn relay_client(&self, _relay_node_hex: String) -> Result<Arc<RelayClient>, HavenError> {
            Err(invalid("the blob transport is not available in a browser; use the relay's HTTPS interface"))
        }

        /// Account → device discovery records are published by an account's seed-holding devices.
        /// A browser device is seedless, so it has nothing to publish.
        pub async fn publish_account_devices(&self, _social: Arc<HavenSocial>) -> Result<Vec<String>, HavenError> {
            Ok(Vec::new())
        }

        /// Not available yet in a browser: device ids come from rosters and inbound frames.
        pub async fn resolve_account_devices(&self, _account_hex: String) -> Result<Vec<String>, HavenError> {
            Ok(Vec::new())
        }

        /// Deliver one frame to a peer, reusing a live connection or dialing through a relay.
        pub async fn send_to_node(&self, node_id_hex: String, payload: Vec<u8>) -> Result<(), HavenError> {
            let id = endpoint_id(&node_id_hex)?;
            // Same guard as the native node: dialing our own id sends path discovery into a loop.
            if id == self.endpoint.id() {
                return Err(invalid("refusing to dial our own node id"));
            }
            let live = lock(&self.conns).get(&id).filter(|c| c.close_reason().is_none()).cloned();
            let conn = match live {
                Some(c) => c,
                None => {
                    let mut addr = EndpointAddr::new(id);
                    if let Some(home) = &self.home {
                        addr = addr.with_relay_url(home.clone());
                    }
                    let conn = self.endpoint.connect(addr, ALPN).await.map_err(invalid)?;
                    lock(&self.conns).insert(id, conn.clone());
                    crate::rt::spawn(read_loop(conn.clone(), self.conns.clone(), self.listener.clone()));
                    conn
                }
            };
            let mut s = conn.open_uni().await.map_err(invalid)?;
            s.write_all(&payload).await.map_err(invalid)?;
            s.finish().map_err(invalid)?;
            // Wait for the peer to take the stream, so Ok means "delivered" and a dead path is
            // evicted instead of swallowing the next send too.
            if s.stopped().await.is_err() {
                lock(&self.conns).remove(&id);
                return Err(invalid("peer did not acknowledge the frame"));
            }
            Ok(())
        }
    }

    async fn read_loop(conn: Connection, conns: Conns, listener: Arc<dyn InboundListener>) {
        let from = hex(conn.remote_id().as_bytes());
        while let Ok(mut recv) = conn.accept_uni().await {
            let (listener, from) = (listener.clone(), from.clone());
            crate::rt::spawn(async move {
                if let Ok(payload) = recv.read_to_end(MAX_PAYLOAD).await {
                    listener.on_inbound(from, payload);
                }
            });
        }
        let id = conn.remote_id();
        let mut map = lock(&conns);
        if map.get(&id).map(|c| c.close_reason().is_some()).unwrap_or(false) {
            map.remove(&id);
        }
    }

    /// The blob-ALPN mailbox client. Never constructed in a browser (see
    /// [`HavenNode::relay_client`]); the type exists so the engine's relay paths compile unchanged
    /// and fall through to the HTTPS interface.
    pub struct RelayClient {
        never: std::convert::Infallible,
    }

    impl RelayClient {
        pub async fn connect(_seed: Vec<u8>, _relay_node_hex: String) -> Result<Arc<Self>, HavenError> {
            Err(invalid("the blob transport is not available in a browser; use the relay's HTTPS interface"))
        }
        pub async fn teach_relays(&self, _circle_id: String, _relays: Vec<String>) -> bool {
            match self.never {}
        }
        pub async fn enroll_members(&self, _circle_id: String, _members: Vec<String>) -> bool {
            match self.never {}
        }
        pub async fn enroll_members_replace(&self, _circle_id: String, _members: Vec<String>) -> bool {
            match self.never {}
        }
        pub async fn put(&self, _key: String, _data: Vec<u8>) -> Result<(), HavenError> {
            match self.never {}
        }
        pub async fn get(&self, _key: String) -> Option<Vec<u8>> {
            match self.never {}
        }
        pub async fn has(&self, _key: String) -> Result<bool, HavenError> {
            match self.never {}
        }
        pub async fn list(&self, _prefix: String) -> Result<Vec<String>, HavenError> {
            match self.never {}
        }
        pub async fn touch(&self, _prefix: String, _keys: Vec<String>) -> Result<Vec<String>, HavenError> {
            match self.never {}
        }
    }

    /// A relay hosted in this process. A tab cannot host one: attaching yields a handle whose
    /// store is always empty and whose HTTP interface refuses to start.
    pub struct RelayServerHandle {
        node_hex: String,
    }

    impl RelayServerHandle {
        pub fn attach(node: Arc<HavenNode>, _dir: String) -> Arc<Self> {
            Arc::new(Self { node_hex: node.node_id_hex() })
        }
        pub fn attach_with_limits(node: Arc<HavenNode>, dir: String, _max_age_days: u32, _max_bytes: u64) -> Arc<Self> {
            Self::attach(node, dir)
        }
        pub fn node_id_hex(&self) -> String {
            self.node_hex.clone()
        }
        pub fn authorize_circle(&self, _circle_id: String, _members: Vec<String>, _relays: Vec<String>) {}
        pub fn deauthorize_circle(&self, _circle_id: String) {}
        pub fn local_put(&self, _key: String, _data: Vec<u8>) -> bool {
            false
        }
        pub fn local_has(&self, _key: String) -> bool {
            false
        }
        pub fn local_get(&self, _key: String) -> Option<Vec<u8>> {
            None
        }
        pub fn local_list(&self, _prefix: String) -> Vec<String> {
            Vec::new()
        }
        pub fn local_touch(&self, keys: Vec<String>) -> Vec<String> {
            keys // "missing": nothing is held here
        }
        pub async fn serve_http(&self, _bind: String, _token: String) -> Result<u16, HavenError> {
            Err(invalid(crate::net::hosting::NOT_IN_A_BROWSER))
        }
        pub fn disable(&self) {}
        pub async fn sync_from(&self, _peer_node_hex: String) -> u32 {
            0
        }
    }
}
