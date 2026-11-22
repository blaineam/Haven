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

/// A relay address as a browser must be given it: without the trailing dot of a fully qualified
/// name (`relay.example.com.`). iroh's public relays are named with one, and native code is right
/// to keep it, but Safari refuses the TLS handshake to such a name ("The server did not accept the
/// certificate"), so a page in Safari could reach no public relay and never showed a code.
/// The dotless name is the same server. Anything that is not `scheme://host…` is returned as is.
pub fn browser_relay_url(url: &str) -> String {
    let Some(scheme_end) = url.find("://") else { return url.to_string() };
    let rest = &url[scheme_end + 3..];
    let host_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..host_end];
    // `host` or `host:port`; an IPv6 literal (`[::1]`) has no name to trim.
    let (host, port) = match authority.rfind(':') {
        Some(i) if !authority.ends_with(']') && authority[i + 1..].bytes().all(|b| b.is_ascii_digit()) => {
            (&authority[..i], &authority[i..])
        }
        _ => (authority, ""),
    };
    let Some(trimmed) = host.strip_suffix('.') else { return url.to_string() };
    if trimmed.is_empty() || trimmed.ends_with('.') {
        return url.to_string();
    }
    format!("{}{}{}{}", &url[..scheme_end + 3], trimmed, port, &rest[host_end..])
}

#[cfg(test)]
mod browser_relay_url_tests {
    use super::browser_relay_url;

    #[test]
    fn a_fully_qualified_relay_name_loses_its_trailing_dot_and_nothing_else() {
        assert_eq!(browser_relay_url("https://usw1-1.relay.n0.iroh.link./"), "https://usw1-1.relay.n0.iroh.link/");
        assert_eq!(browser_relay_url("https://relay.example.com."), "https://relay.example.com");
        assert_eq!(browser_relay_url("https://relay.example.com.:8443/x?y#z"), "https://relay.example.com:8443/x?y#z");
        // Already fine, or not ours to touch.
        for same in [
            "https://relay.example.com/",
            "http://127.0.0.1:8674",
            "http://[::1]:8674/",
            "https://a.b/path.with.dot./",
            "https://./",
            "https://double../",
            "not a url.",
        ] {
            assert_eq!(browser_relay_url(same), same);
        }
    }
}

/// Per-peer dial backoff for the browser node. Without one the engine's sync loop re-dialed every
/// unreachable device of every contact on every pass, and each dial costs an address lookup and a
/// relay handshake: a linked browser sat issuing hundreds of failing requests a minute for as long
/// as the tab was open. One failed dial closes the gate for a minute, doubling to fifteen; a
/// success, or fresh evidence the peer is there ([`DialGate::forgive`]), opens it.
#[derive(Default)]
pub struct DialGate {
    peers: std::collections::HashMap<[u8; 32], (u64, u32)>, // id → (closed until ms, failures)
}

impl DialGate {
    const BASE_MS: u64 = 60_000;
    const CAP_MS: u64 = 900_000;

    /// May this peer be dialed at `now_ms`?
    pub fn open(&self, id: &[u8; 32], now_ms: u64) -> bool {
        self.peers.get(id).is_none_or(|(until, _)| now_ms >= *until)
    }
    /// A dial failed: close the gate, for longer each time.
    pub fn strike(&mut self, id: [u8; 32], now_ms: u64) {
        let fails = self.peers.get(&id).map_or(0, |(_, f)| *f).saturating_add(1);
        let wait = (Self::BASE_MS << (fails.min(5) - 1)).min(Self::CAP_MS);
        self.peers.insert(id, (now_ms + wait, fails));
        if self.peers.len() > 4096 {
            self.peers.retain(|_, (until, _)| *until > now_ms);
        }
    }
    /// The peer answered, or there is fresh evidence it is there. Returns whether a gate was closed.
    pub fn forgive(&mut self, id: &[u8; 32]) -> bool {
        self.peers.remove(id).is_some()
    }
    /// The network changed: every closed gate opens once, keeping its count, so a peer that is
    /// really gone fails once more and goes straight back to its long wait.
    pub fn forgive_all(&mut self, now_ms: u64) -> u32 {
        let mut n = 0;
        for (until, _) in self.peers.values_mut() {
            if *until > now_ms {
                *until = now_ms;
                n += 1;
            }
        }
        n
    }
}

#[cfg(test)]
mod dial_gate_tests {
    use super::DialGate;

    #[test]
    fn a_failed_dial_is_not_repeated_until_its_wait_is_over_and_the_wait_grows() {
        let (a, b) = ([1u8; 32], [2u8; 32]);
        let mut g = DialGate::default();
        assert!(g.open(&a, 0));
        g.strike(a, 0);
        assert!(!g.open(&a, 59_999) && g.open(&a, 60_000), "one minute after the first failure");
        assert!(g.open(&b, 1), "another peer is not held back");
        g.strike(a, 60_000);
        assert!(!g.open(&a, 60_000 + 119_999) && g.open(&a, 60_000 + 120_000), "two after the second");
        for _ in 0..10 {
            g.strike(a, 1_000_000);
        }
        assert!(!g.open(&a, 1_000_000 + 899_999) && g.open(&a, 1_000_000 + 900_000), "never more than fifteen");
        assert!(g.forgive(&a) && g.open(&a, 1_000_001) && !g.forgive(&a));
        g.strike(a, 0);
        g.strike(b, 0);
        assert_eq!(g.forgive_all(10), 2);
        assert!(g.open(&a, 10) && g.open(&b, 10));
        g.strike(a, 10);
        assert!(!g.open(&a, 10 + 119_999), "the count was kept: straight back to the longer wait");
    }
}

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
    use iroh::{EndpointAddr, EndpointId, RelayConfig, RelayMap, RelayMode, RelayUrl, SecretKey};

    /// Same ALPN as `haven_net` — a browser node is a peer on the same protocol.
    const ALPN: &[u8] = b"haven/social/0";
    /// The relay mailbox ALPN (`haven_net::blobstore::BLOB_ALPN`). A browser uses it for ONE
    /// thing: asking a relay how it is reached now ([`HavenNode::relay_get`]).
    const BLOB_ALPN: &[u8] = b"haven/blob/1";
    /// `haven_net::blobstore::VERB_GET`.
    const BLOB_VERB_GET: u8 = b'G';
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
        /// Per-peer dial backoff ([`super::DialGate`]).
        gate: Mutex<super::DialGate>,
    }

    impl HavenNode {
        /// Bind a node under `seed`'s node key. The relay map is the circle's DERP URLs known at
        /// bind time (`crate::net::apply_derp_urls`) on top of n0's public relays, mirroring the
        /// native "Haven preferred, n0 as the fallback rendezvous" policy.
        pub async fn start(seed: Vec<u8>, listener: Arc<dyn InboundListener>) -> Result<Arc<Self>, HavenError> {
            let seed: [u8; 32] = seed.try_into().map_err(|_| invalid("seed must be 32 bytes"))?;
            let secret = Identity::from_seed(&seed).node_secret_bytes();
            let customs: Vec<RelayUrl> = crate::net::active_derp_urls()
                .iter()
                .filter_map(|u| super::browser_relay_url(u).parse::<RelayUrl>().ok())
                .collect();
            // n0's relays are named with a trailing dot, which Safari will not connect to
            // (`browser_relay_url`): the map is rebuilt from the same names without it.
            let map = RelayMap::empty();
            for url in RelayMode::Default.relay_map().urls::<Vec<RelayUrl>>() {
                if let Ok(url) = super::browser_relay_url(url.as_str()).parse::<RelayUrl>() {
                    map.insert(url.clone(), Arc::new(RelayConfig::new(url, None)));
                }
            }
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
            Ok(Arc::new(Self { endpoint, home: customs.into_iter().next(), conns, listener, gate: Mutex::new(super::DialGate::default()) }))
        }

        /// Resolves once a relay connection is up — the point at which peers can reach this node.
        pub async fn online(&self) {
            self.endpoint.online().await;
        }

        /// The relay this node can be reached through right now: the circle relay it was bound
        /// with when there is one, otherwise whichever public rendezvous relay it settled on.
        /// `None` until [`online`](Self::online) has resolved.
        pub fn reachable_relay(&self) -> Option<String> {
            if let Some(home) = &self.home {
                return Some(home.to_string());
            }
            self.endpoint.addr().relay_urls().next().map(|u| u.to_string())
        }

        pub async fn shutdown(&self) {
            lock(&self.conns).clear();
            self.endpoint.close().await;
        }

        pub fn node_id_hex(&self) -> String {
            hex(self.endpoint.id().as_bytes())
        }

        /// Forgive one peer's dial backoff: there is fresh evidence it is reachable.
        pub fn forgive_dial(&self, node_hex: String) -> bool {
            endpoint_id(&node_hex).is_ok_and(|id| self.gate.lock().unwrap_or_else(|e| e.into_inner()).forgive(id.as_bytes()))
        }

        /// Re-open every held-back peer once (the network path changed).
        pub fn forgive_all_dials(&self) -> u32 {
            self.gate.lock().unwrap_or_else(|e| e.into_inner()).forgive_all(crate::engine::now_ms())
        }

        /// GET one small key from a relay over its blob ALPN, found through address lookup.
        ///
        /// A browser reaches a relay's mailbox over HTTPS and nothing else, so when that address
        /// stops answering (a free tunnel is given a new hostname every time its relay restarts)
        /// it had no way left to ask the relay anything, including where it had gone. The relay's
        /// NODE is still reachable: it is found by its id and dialed through a public rendezvous
        /// relay, like any peer. `None` on any failure, a miss, or a refusal.
        pub async fn relay_get(&self, relay_node_hex: String, key: String) -> Result<Option<Vec<u8>>, HavenError> {
            let id = endpoint_id(&relay_node_hex)?;
            if id == self.endpoint.id() || key.is_empty() || key.len() > 1024 {
                return Err(invalid("not a key to ask a relay for"));
            }
            // No relay hint: the one this node holds for a circle is the address that just failed.
            let conn = self.endpoint.connect(EndpointAddr::new(id), BLOB_ALPN).await.map_err(invalid)?;
            let (mut send, mut recv) = conn.open_bi().await.map_err(invalid)?;
            let mut head = vec![BLOB_VERB_GET];
            head.extend_from_slice(&(key.len() as u16).to_be_bytes());
            head.extend_from_slice(key.as_bytes());
            head.extend_from_slice(&0u64.to_be_bytes());
            send.write_all(&head).await.map_err(invalid)?;
            send.finish().map_err(invalid)?;
            let bytes = recv.read_to_end(64 * 1024).await.map_err(invalid)?;
            conn.close(0u32.into(), b"done");
            if bytes.starts_with(b"ERR ") {
                return Err(invalid(String::from_utf8_lossy(&bytes).into_owned()));
            }
            Ok((bytes != b"\0MISS").then_some(bytes))
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
            self.send_inner(node_id_hex, None, payload).await
        }

        /// [`send_to_node`](Self::send_to_node) to a node listening on a NAMED relay (same contract
        /// as the native node's method of this name).
        pub async fn send_to_node_via(
            &self,
            node_id_hex: String,
            relay_url: String,
            payload: Vec<u8>,
        ) -> Result<(), HavenError> {
            let url = super::browser_relay_url(relay_url.trim()).parse::<RelayUrl>().map_err(invalid)?;
            // Someone just scanned this device's code: always a real attempt (as natively).
            let _ = self.forgive_dial(node_id_hex.clone());
            self.send_inner(node_id_hex, Some(url), payload).await
        }

        async fn send_inner(
            &self,
            node_id_hex: String,
            via: Option<RelayUrl>,
            payload: Vec<u8>,
        ) -> Result<(), HavenError> {
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
                    let hinted = via.is_none() && self.home.is_some();
                    if let Some(relay) = via.or(self.home.clone()) {
                        addr = addr.with_relay_url(relay);
                    }
                    if !self.gate.lock().unwrap_or_else(|e| e.into_inner()).open(id.as_bytes(), crate::engine::now_ms()) {
                        return Err(invalid("dial backoff: peer unreachable, retry later"));
                    }
                    let conn = match self.endpoint.connect(addr, ALPN).await {
                        Ok(conn) => conn,
                        // The circle's own relay was only a hint, and it may be the thing that is
                        // down. Once more with no hint: the peer is then found by address lookup
                        // and reached through whichever public relay it is on.
                        Err(_) if hinted => match self.endpoint.connect(EndpointAddr::new(id), ALPN).await {
                            Ok(conn) => conn,
                            Err(e) => {
                                self.gate.lock().unwrap_or_else(|e| e.into_inner()).strike(*id.as_bytes(), crate::engine::now_ms());
                                return Err(invalid(e));
                            }
                        },
                        Err(e) => {
                            self.gate.lock().unwrap_or_else(|e| e.into_inner()).strike(*id.as_bytes(), crate::engine::now_ms());
                            return Err(invalid(e));
                        }
                    };
                    self.gate.lock().unwrap_or_else(|e| e.into_inner()).forgive(id.as_bytes());
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
