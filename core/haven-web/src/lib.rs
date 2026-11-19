//! Haven in a browser tab.
//!
//! A tab cannot be a full Haven peer: it cannot bind UDP, accept inbound connections, or
//! hole-punch. What it *can* do is hold an outbound WebSocket to a circle's relay. So the web
//! client is a **relay-only** node — the same iroh endpoint the native apps run, with every
//! transport except the relay (DERP) path absent — speaking the unchanged `haven/social/0` wire
//! (one uni stream per sealed frame) to native peers, and the unchanged signed-HTTP mailbox
//! protocol to the relay. Nothing about the protocol, the sealing, or the relay's authorization
//! is special-cased for the web; a browser device is a seedless linked device like any other.
//!
//! This crate is empty on every target but `wasm32`.
#![cfg(target_arch = "wasm32")]

mod session;

pub use session::WebSession;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use iroh::endpoint::{presets, Connection, Endpoint, QuicTransportConfig};
use iroh::{EndpointAddr, EndpointId, RelayMap, RelayMode, RelayUrl, SecretKey};
use wasm_bindgen::prelude::*;

/// Same ALPN as `haven_net` — a browser node is a peer on the same protocol, not a gateway client.
const ALPN: &[u8] = b"haven/social/0";
/// Same per-frame cap as `haven_net`.
const MAX_PAYLOAD: usize = 256 * 1024 * 1024;
/// Must match `haven_net::endpoint_builder` — both ends negotiate multipath or neither does.
const MAX_MULTIPATH: u32 = 9;

fn err(e: impl std::fmt::Debug) -> JsError {
    JsError::new(&format!("{e:?}"))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex32(s: &str) -> Result<[u8; 32], JsError> {
    if s.len() != 64 || !s.is_ascii() {
        return Err(JsError::new("node id must be 64 hex characters"));
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).map_err(|_| JsError::new("node id is not hex"))?;
    }
    Ok(out)
}

fn secret32(bytes: &[u8]) -> Result<[u8; 32], JsError> {
    bytes.try_into().map_err(|_| JsError::new("secret must be 32 bytes"))
}

fn now_secs() -> u64 {
    web_time::SystemTime::now().duration_since(web_time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// 32 fresh bytes from the page's CSPRNG — a device seed. A browser device is *seedless* in the
/// account sense: this is its own device key material, never the account's master seed.
#[wasm_bindgen(js_name = generateDeviceSeed)]
pub fn generate_device_seed() -> Vec<u8> {
    let mut s = [0u8; 32];
    // getrandom's `js` backend: `crypto.getRandomValues`.
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut s);
    s.to_vec()
}

/// The `Authorization: Haven …` value for one signed mailbox request (`GET|HEAD|PUT /k/<key>`,
/// `GET /l/<prefix>`, `POST /t/<prefix>`), signed with this node's Ed25519 node secret. Built by
/// the same `haven_p2p::httpauth` code the relay's verifier shares, so it cannot drift.
#[wasm_bindgen(js_name = httpAuthHeader)]
pub fn http_auth_header(node_secret: &[u8], token: &str, method: &str, key: &str, body: &[u8]) -> Result<String, JsError> {
    Ok(haven_p2p::httpauth::auth_header_at(&secret32(node_secret)?, token, method, key, body, now_secs()))
}

/// The engine's own self-test (hybrid KEM round-trip, signatures, sealing), run in this tab — proof
/// that the page is running the same core the native apps run.
#[wasm_bindgen(js_name = engineSelfTest)]
pub fn engine_self_test() -> bool {
    haven_ffi::self_test().all_ok
}

type Conns = Rc<RefCell<HashMap<EndpointId, Connection>>>;

/// A relay-only Haven node living in a tab.
#[wasm_bindgen]
pub struct WebNode {
    endpoint: Endpoint,
    relay: RelayUrl,
    conns: Conns,
    on_inbound: js_sys::Function,
}

#[wasm_bindgen]
impl WebNode {
    /// Bind a node under `node_secret` (32 bytes) whose only path is `relay_url` — the circle
    /// relay's public front door (`https://…`, the path proxy's DERP route). `on_inbound` is called
    /// as `(senderNodeIdHex, Uint8Array)` for every frame a peer delivers; the sender id is the
    /// transport-authenticated endpoint id of the connection it arrived on.
    pub async fn spawn(node_secret: &[u8], relay_url: String, on_inbound: js_sys::Function) -> Result<WebNode, JsError> {
        let relay: RelayUrl = relay_url.parse().map_err(err)?;
        let endpoint = Endpoint::builder(presets::Minimal)
            .secret_key(SecretKey::from_bytes(&secret32(node_secret)?))
            .alpns(vec![ALPN.to_vec()])
            .relay_mode(RelayMode::Custom(RelayMap::from(relay.clone())))
            .transport_config(QuicTransportConfig::builder().max_concurrent_multipath_paths(MAX_MULTIPATH).build())
            .bind()
            .await
            .map_err(err)?;
        let conns: Conns = Rc::new(RefCell::new(HashMap::new()));
        {
            let (ep, conns, cb) = (endpoint.clone(), conns.clone(), on_inbound.clone());
            wasm_bindgen_futures::spawn_local(async move {
                while let Some(incoming) = ep.accept().await {
                    let (conns, cb) = (conns.clone(), cb.clone());
                    wasm_bindgen_futures::spawn_local(async move {
                        let Ok(connecting) = incoming.accept() else { return };
                        let Ok(conn) = connecting.await else { return };
                        conns.borrow_mut().insert(conn.remote_id(), conn.clone());
                        read_loop(conn, conns, cb).await;
                    });
                }
            });
        }
        Ok(WebNode { endpoint, relay, conns, on_inbound })
    }

    /// This node's id (its Ed25519 public key) as hex.
    #[wasm_bindgen(js_name = nodeIdHex)]
    pub fn node_id_hex(&self) -> String {
        hex(self.endpoint.id().as_bytes())
    }

    /// Resolves once the relay connection is up — the point at which peers can reach this node.
    pub async fn online(&self) {
        self.endpoint.online().await;
    }

    /// Deliver one frame to a peer, reusing a live connection or dialing through the relay.
    #[wasm_bindgen(js_name = sendToNode)]
    pub async fn send_to_node(&self, node_id_hex: String, payload: Vec<u8>) -> Result<(), JsError> {
        let id = EndpointId::from_bytes(&unhex32(&node_id_hex)?).map_err(err)?;
        // Same guard as the native node: dialing our own id sends iroh's path discovery into a loop.
        if id == self.endpoint.id() {
            return Err(JsError::new("refusing to dial our own node id"));
        }
        let live = self.conns.borrow().get(&id).filter(|c| c.close_reason().is_none()).cloned();
        let conn = match live {
            Some(c) => c,
            None => {
                let addr = EndpointAddr::new(id).with_relay_url(self.relay.clone());
                let conn = self.endpoint.connect(addr, ALPN).await.map_err(err)?;
                self.conns.borrow_mut().insert(id, conn.clone());
                wasm_bindgen_futures::spawn_local(read_loop(conn.clone(), self.conns.clone(), self.on_inbound.clone()));
                conn
            }
        };
        let mut s = conn.open_uni().await.map_err(err)?;
        s.write_all(&payload).await.map_err(err)?;
        s.finish().map_err(err)?;
        // Wait for the peer to take the stream, so a resolved promise means "delivered", and a
        // dead path is evicted instead of swallowing the next send too.
        if s.stopped().await.is_err() {
            self.conns.borrow_mut().remove(&id);
            return Err(JsError::new("peer did not acknowledge the frame"));
        }
        Ok(())
    }

    /// Close every connection and the endpoint.
    pub async fn close(&self) {
        self.conns.borrow_mut().clear();
        self.endpoint.close().await;
    }
}

async fn read_loop(conn: Connection, conns: Conns, cb: js_sys::Function) {
    let from = hex(conn.remote_id().as_bytes());
    while let Ok(mut recv) = conn.accept_uni().await {
        let (cb, from) = (cb.clone(), from.clone());
        wasm_bindgen_futures::spawn_local(async move {
            if let Ok(payload) = recv.read_to_end(MAX_PAYLOAD).await {
                let bytes = js_sys::Uint8Array::from(payload.as_slice());
                // A throwing page callback must not take the read loop down with it.
                let _ = cb.call2(&JsValue::NULL, &JsValue::from_str(&from), &bytes);
            }
        });
    }
    let id = conn.remote_id();
    let mut map = conns.borrow_mut();
    if map.get(&id).map(|c| c.close_reason().is_some()).unwrap_or(false) {
        map.remove(&id);
    }
}
