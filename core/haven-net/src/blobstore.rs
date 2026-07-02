//! Native **blob mailbox over iroh** (HAVEN-NET-RELAY.md Design B) — the simplest
//! decentralized media store-and-forward.
//!
//! Where the S3-over-iroh tunnel ([`crate::s3tunnel`]) carries the full S3 protocol
//! inside iroh, this is a tiny purpose-built request/response that a relay can serve
//! straight from a **local directory** with no `rclone`, no S3, no external process —
//! ideal for the "download → run → paste link → done" relay. It speaks three verbs over
//! ALPN `haven/blob/1`:
//!
//! ```text
//!   PUT <key>  + body   → stores body at <key>           → reply: OK
//!   GET <key>           → returns the stored body         → reply: OK <len> <bytes> | MISS
//!   HAS <key>           → existence check                 → reply: HIT | MISS
//!   LIST <prefix>       → newline-joined keys under prefix → reply: OK <len> <bytes>
//! ```
//!
//! ## Content-addressed, relay-opaque
//!
//! A `<key>` is the circle's existing media ref — in practice a content hash of the
//! **already-sealed** blob (e.g. `mailbox/<circle>/<blake3-hex>`). The relay stores the
//! bytes verbatim and serves them verbatim; it never has a content key, so it can never
//! read a blob. It learns only: the (opaque) key string, the blob's byte length, and
//! that *some* node asked to put/get it. That is strictly the metadata the routing
//! header already exposes — never plaintext.
//!
//! Keys are validated and confined to the store directory (no `..`, no absolute paths,
//! no NUL), so a malicious peer cannot escape the store root.
//!
//! ```text
//!  consumer device                         relay / volunteer device
//!  ┌──────────────┐   iroh QUIC bi-stream  ┌──────────────────────────────┐
//!  │ BlobClient ──┼──── PUT/GET/HAS ──────►│ accept (ALPN "haven/blob/1")  │
//!  │ (sealed blob)│◄──── reply ────────────│   └─► <store_dir>/<key>       │
//!  └──────────────┘                        └──────────────────────────────┘
//! ```

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, bail, Result};
use iroh::{
    endpoint::{presets::N0, Connection, Endpoint},
    EndpointAddr, EndpointId, SecretKey,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// ALPN for the native blob mailbox.
pub const BLOB_ALPN: &[u8] = b"haven/blob/1";

/// Hard cap on a single blob (matches the social transport's 256 MiB ceiling).
const MAX_BLOB: u64 = 256 * 1024 * 1024;
/// Hard cap on a key length (keys are short content-addressed paths).
const MAX_KEY: usize = 512;

// --- request framing ----------------------------------------------------------------
//
// Each request is a single iroh bi-stream:
//   verb : 1 byte  (b'P' put, b'G' get, b'H' has, b'L' list)
//   klen : u16 BE
//   key  : klen bytes (utf-8, validated)
//   blen : u64 BE   (PUT only; 0 for others)
//   body : blen bytes (PUT only)
// The reply is read to end-of-stream:
//   PUT  -> b"OK"        | b"ERR" + reason
//   GET  -> body bytes   | b"\0MISS"   (a real blob never starts with a NUL byte we
//                                        emit; MISS is disambiguated by the sentinel)
//   HAS  -> b"HIT" | b"MISS"
//   LIST -> newline-joined keys (may be empty)
//
// GET/LIST stream the body directly (the body *is* the reply), so there is no length
// prefix to read on the happy path; a MISS is the 5-byte sentinel `\0MISS`.

const VERB_PUT: u8 = b'P';
const VERB_GET: u8 = b'G';
const VERB_HAS: u8 = b'H';
const VERB_LIST: u8 = b'L';

/// Sentinel returned by GET when the key is absent. Chosen to be distinguishable from a
/// stored blob: it begins with a NUL and is exactly these 5 bytes.
const MISS: &[u8] = b"\0MISS";

trait IntoAnyhow<T> {
    fn ah(self) -> Result<T>;
}
impl<T, E: std::fmt::Debug> IntoAnyhow<T> for std::result::Result<T, E> {
    fn ah(self) -> Result<T> {
        self.map_err(|e| anyhow!("{e:?}"))
    }
}

/// Validate a blob key and resolve it to a concrete path **inside** `root`, refusing any
/// key that could escape the store directory. Returns the joined path.
/// Pure mesh-sync decision: of the keys a peer advertises, which should we pull? Those that
/// (a) stay inside our namespace (no traversal / absolute / `..`), and (b) we don't already
/// hold — capped at `MAX_SYNC_PULL`. Factored out so the set-difference + safety logic is
/// unit-testable without a live network.
pub(crate) fn keys_to_pull(root: &Path, peer_keys: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for key in peer_keys {
        if out.len() >= MAX_SYNC_PULL {
            break;
        }
        match safe_path(root, key) {
            Ok(p) if !p.is_file() => out.push(key.clone()),
            _ => {} // already have it, or it escapes our namespace → never pull
        }
    }
    out
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub(crate) fn safe_path(root: &Path, key: &str) -> Result<PathBuf> {
    if key.is_empty() || key.len() > MAX_KEY {
        bail!("bad key length");
    }
    if key.contains('\0') || key.starts_with('/') || key.starts_with('\\') {
        bail!("illegal key");
    }
    let mut out = root.to_path_buf();
    for comp in key.split(['/', '\\']) {
        if comp.is_empty() || comp == "." || comp == ".." {
            bail!("illegal key component");
        }
        // Reject Windows drive / device-ish components defensively.
        if comp.contains(':') {
            bail!("illegal key component");
        }
        out.push(comp);
    }
    // Final guard: the resolved path must remain under root once we strip non-existent
    // tail components (we can't canonicalize a not-yet-created file).
    debug_assert!(out.starts_with(root));
    if !out.starts_with(root) {
        bail!("key escapes store root");
    }
    Ok(out)
}

// --- server side ---------------------------------------------------------------------

/// A relay-side **local-disk blob store** served over iroh. Stores and serves
/// content-addressed sealed blobs from `root`; it never decrypts them.
/// Most blobs to pull from a single peer in one anti-entropy pass — a backstop against a
/// misbehaving/over-eager peer flooding our disk. The pass simply resumes next tick.
const MAX_SYNC_PULL: usize = 20_000;

/// Key prefix the mailbox + media blobs all live under, so a sync only ever touches Haven's
/// own namespace (never arbitrary peer-supplied paths). `LIST` forbids an empty key, so this
/// non-empty root is also required by the wire protocol.
pub(crate) const SYNC_PREFIX: &str = "haven";

/// Per-circle authorization for the mailbox (audit transport-F4). When a host populates this (the
/// Haven apps do, from each circle's known membership), the relay serves a circle's mailbox keys ONLY
/// to that circle's members — a stranger who merely learns the relay's node id can no longer enumerate
/// or fetch a circle's blobs. Sibling relays are allowed broad LIST so mesh anti-entropy still works.
/// An EMPTY map means "unconfigured" → fully permissive (a standalone/self-host relay is unchanged).
#[derive(Default)]
pub(crate) struct RelayAuth {
    /// circleId → authorized member node hexes.
    members: HashMap<String, HashSet<String>>,
    /// Sibling relay node hexes allowed to replicate via broad LIST (mesh anti-entropy).
    relays: HashSet<String>,
}

impl RelayAuth {
    /// Authorize a circle's mailbox to exactly `members` + the circle's sibling `relays`. Idempotent.
    pub(crate) fn authorize(&mut self, circle_id: &str, members: Vec<String>, relays: Vec<String>) {
        self.members.insert(circle_id.to_string(), members.into_iter().collect());
        for r in relays {
            self.relays.insert(r);
        }
    }
    pub(crate) fn deauthorize(&mut self, circle_id: &str) {
        self.members.remove(circle_id);
    }
}

/// Store a sealed blob into a relay root directly (the in-process host's OWN events — NO iroh
/// self-connection). Atomic temp+rename, mirrors the PUT path in `handle_request`.
pub(crate) fn local_put(root: &Path, key: &str, data: &[u8]) -> Result<()> {
    let path = safe_path(root, key)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let tmp = path.with_extension("part");
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// True if a relay root already holds `key` (content-addressed → idempotent puts).
pub(crate) fn local_has(root: &Path, key: &str) -> bool {
    safe_path(root, key).map(|p| p.exists()).unwrap_or(false)
}

/// Read a sealed blob the in-process relay holds — the HOST reading its OWN store (e.g. a sibling device's
/// upload, or a friend's post landed while we were offline). No iroh self-connection.
pub(crate) fn local_get(root: &Path, key: &str) -> Option<Vec<u8>> {
    let path = safe_path(root, key).ok()?;
    std::fs::read(&path).ok()
}

/// Every store-relative key the in-process relay holds under `prefix` (host enumerating its OWN store, so
/// it can ingest blobs others uploaded to it without dialing itself). Best-effort; `.part` writes skipped.
pub(crate) fn local_list(root: &Path, prefix: &str) -> Vec<String> {
    let start = safe_path(root, prefix).unwrap_or_else(|_| root.to_path_buf());
    let mut out = Vec::new();
    collect_keys(root, &start, &mut out);
    out
}

pub struct BlobServer {
    endpoint: Endpoint,
    secret: [u8; 32],
    root: PathBuf,
    auth: Arc<Mutex<RelayAuth>>,
}

impl BlobServer {
    /// Spawn the store. `secret` is the relay's identity key, so the store is addressed
    /// by the relay's stable node id (the `volunteer_node_id` the app references). `root`
    /// is the local directory blobs live in (created if missing).
    pub async fn spawn(secret: [u8; 32], root: PathBuf) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&root).map_err(|e| anyhow!("create store {}: {e}", root.display()))?;
        // Stock transport (see Node::spawn): IP transport ENABLED so a same-LAN peer fetches blobs
        // over a direct local path instead of bouncing through the DERP cloud.
        let endpoint = Endpoint::builder(N0)
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![BLOB_ALPN.to_vec()])
            .bind()
            .await
            .ah()?;
        let srv = Arc::new(Self { endpoint, secret, root: root.clone(), auth: Arc::new(Mutex::new(RelayAuth::default())) });
        let acc = srv.clone();
        tokio::spawn(async move { acc.accept_loop(root).await });
        Ok(srv)
    }

    /// Authorize a circle's mailbox to exactly `members` (their node hexes), plus the circle's sibling
    /// `relays` (allowed to replicate). Idempotent; call again on any membership change to update the
    /// set. Once ANY circle is authorized, the relay enforces membership on every mailbox request (and
    /// rejects strangers); before that it stays permissive for backward compatibility (audit
    /// transport-F4).
    pub fn authorize(&self, circle_id: &str, members: Vec<String>, relays: Vec<String>) {
        let mut a = self.auth.lock().unwrap();
        a.members.insert(circle_id.to_string(), members.into_iter().collect());
        for r in relays {
            a.relays.insert(r);
        }
    }

    /// Forget a circle's authorization (e.g., we stopped serving it / left it).
    pub fn deauthorize(&self, circle_id: &str) {
        self.auth.lock().unwrap().members.remove(circle_id);
    }

    /// Mesh anti-entropy: pull every sealed blob a PEER relay holds (under Haven's prefix)
    /// that we lack, into our own store. Because keys are content-addressed and bodies are
    /// E2E-sealed, this is an idempotent, conflict-free set-union — the relay never inspects
    /// content, so replication discloses nothing a peer adopting the same relay didn't already
    /// hold. Returns how many new blobs we pulled. Best-effort: a peer that's down is skipped.
    ///
    /// Run this against each sibling relay on a timer and the mailbox replicates across the
    /// mesh: any relay can join (one pass makes it a full replica) or leave (peers already have
    /// copies) freely, making the circle's mailbox far more resilient.
    pub async fn sync_pull_from(self: &Arc<Self>, peer_node_hex: &str) -> Result<usize> {
        let client = BlobClient::connect(self.secret, peer_node_hex).await?;
        let mut pulled = 0usize;
        let peer_keys = client.list(SYNC_PREFIX).await.unwrap_or_default();
        for key in keys_to_pull(&self.root, &peer_keys) {
            let Ok(local) = safe_path(&self.root, &key) else { continue };
            // `get` caps the read at MAX_BLOB, so an oversized body can't blow up memory.
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
        Ok(pulled)
    }

    /// This store's node id (hex) — the `volunteer_node_id` for the circle's storage.
    pub fn node_id_hex(&self) -> String {
        self.endpoint.id().as_bytes().iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Loopback dial address (for same-machine tests).
    pub async fn local_dial_addr(&self) -> Result<EndpointAddr> {
        for _ in 0..50 {
            let addr = self.endpoint.addr();
            if let Some(a) = addr.ip_addrs().next() {
                return Ok(EndpointAddr::new(addr.id)
                    .with_ip_addr(std::net::SocketAddr::from(([127, 0, 0, 1], a.port()))));
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        Err(anyhow!("no direct address yet"))
    }

    async fn accept_loop(self: Arc<Self>, root: PathBuf) {
        while let Some(incoming) = self.endpoint.accept().await {
            let root = root.clone();
            let auth = self.auth.clone();
            tokio::spawn(async move {
                let Ok(connecting) = incoming.accept() else { return };
                let Ok(conn) = connecting.await else { return };
                // The verified iroh node id of the peer — used to enforce per-account self-sync slot
                // ownership and circle-membership authorization (audit F3/transport-F4). Equals the
                // peer's Haven node hex (same key).
                let peer = hex(conn.remote_id().as_bytes());
                loop {
                    match conn.accept_bi().await {
                        Ok((send, recv)) => {
                            let root = root.clone();
                            let peer = peer.clone();
                            let auth = auth.clone();
                            tokio::spawn(async move {
                                // A handler error must never poison the connection; just
                                // drop the stream. Nothing is logged (no-log posture).
                                let _ = handle_request(root, peer, auth, send, recv).await;
                            });
                        }
                        Err(_) => break,
                    }
                }
            });
        }
    }
}

/// The circle id in a `haven/mailbox/<circle>/...` key, or None for non-mailbox / too-broad keys.
fn mailbox_circle(key: &str) -> Option<&str> {
    let rest = key.strip_prefix("haven/mailbox/")?;
    let circle = rest.split('/').next().unwrap_or("");
    (!circle.is_empty()).then_some(circle)
}

/// A LIST prefix that spans more than one circle's mailbox — mesh-sync territory (sibling relays only).
fn is_broad_mailbox_prefix(key: &str) -> bool {
    matches!(key, "haven" | "haven/" | "haven/mailbox" | "haven/mailbox/")
}

/// Circle-membership authorization (audit transport-F4). Returns true if `peer` may NOT touch `key`.
/// Permissive while no circle is authorized; once the host configures membership, a mailbox key is
/// served only to that circle's members (or a sibling relay replicating); a broad cross-circle LIST is
/// restricted to sibling relays; `self/` and content-addressed `media`/other keys are handled elsewhere
/// / left permissive (media refs are opaque content hashes, self slots are owner-gated above).
fn mailbox_forbidden(auth: &Arc<Mutex<RelayAuth>>, peer: &str, verb: u8, key: &str) -> bool {
    let a = auth.lock().unwrap();
    if a.members.is_empty() {
        return false; // unconfigured / standalone relay → unchanged behavior
    }
    if a.relays.contains(peer) {
        return false; // sibling relay → may sync freely (mesh anti-entropy)
    }
    if verb == VERB_LIST && is_broad_mailbox_prefix(key) {
        return true; // a non-relay may not enumerate across circles
    }
    match mailbox_circle(key) {
        Some(circle) => !a.members.get(circle).map(|m| m.contains(peer)).unwrap_or(false),
        None => false, // not a circle mailbox key
    }
}

/// Serve one request stream against the on-disk store. Pure ciphertext I/O — the body is
/// stored and returned verbatim, never inspected.
pub(crate) async fn handle_request(
    root: PathBuf,
    peer: String,
    auth: Arc<Mutex<RelayAuth>>,
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
) -> Result<()> {
    let verb = recv.read_u8().await.ah()?;
    let klen = recv.read_u16().await.ah()? as usize;
    if klen == 0 || klen > MAX_KEY {
        let _ = send.write_all(b"ERR bad key").await;
        let _ = send.finish();
        return Ok(());
    }
    let mut kbuf = vec![0u8; klen];
    recv.read_exact(&mut kbuf).await.ah()?;
    let key = match std::str::from_utf8(&kbuf) {
        Ok(k) => k.to_string(),
        Err(_) => {
            let _ = send.write_all(b"ERR key utf8").await;
            let _ = send.finish();
            return Ok(());
        }
    };

    // Self-sync slots (`self/<accountHex>/state/<device>`) are private to their owning account — only
    // the account owner (the verified connecting peer) may read/write/list them (audit F3). Without
    // this, any node that learns the relay id could enumerate + fetch another account's device slots.
    if let Some(rest) = key.strip_prefix("self/") {
        let account = rest.split('/').next().unwrap_or("");
        if account != peer {
            let _ = send.write_all(b"ERR forbidden").await;
            let _ = send.finish();
            return Ok(());
        }
    }

    // Circle-membership authorization: once the host configures any circle's membership, only that
    // circle's members (or a sibling relay) may touch its mailbox; strangers are refused (audit
    // transport-F4). No-op while unconfigured.
    if mailbox_forbidden(&auth, &peer, verb, &key) {
        let _ = send.write_all(b"ERR forbidden").await;
        let _ = send.finish();
        return Ok(());
    }

    match verb {
        VERB_PUT => {
            let blen = recv.read_u64().await.ah()?;
            if blen > MAX_BLOB {
                let _ = send.write_all(b"ERR too big").await;
                let _ = send.finish();
                return Ok(());
            }
            let path = match safe_path(&root, &key) {
                Ok(p) => p,
                Err(_) => {
                    let _ = send.write_all(b"ERR bad key").await;
                    let _ = send.finish();
                    return Ok(());
                }
            };
            // Read the (opaque) body fully, then write atomically via a temp file +
            // rename so a concurrent GET never sees a half-written blob.
            let mut body = vec![0u8; blen as usize];
            recv.read_exact(&mut body).await.ah()?;
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).ok();
            }
            let tmp = path.with_extension("part");
            let write_res = (|| -> std::io::Result<()> {
                std::fs::write(&tmp, &body)?;
                std::fs::rename(&tmp, &path)?;
                Ok(())
            })();
            match write_res {
                Ok(()) => {
                    let _ = send.write_all(b"OK").await;
                }
                Err(_) => {
                    let _ = std::fs::remove_file(&tmp);
                    let _ = send.write_all(b"ERR write").await;
                }
            }
            let _ = send.finish();
        }
        VERB_GET => {
            let path = match safe_path(&root, &key) {
                Ok(p) => p,
                Err(_) => {
                    let _ = send.write_all(MISS).await;
                    let _ = send.finish();
                    return Ok(());
                }
            };
            match std::fs::read(&path) {
                Ok(bytes) => {
                    let _ = send.write_all(&bytes).await;
                }
                Err(_) => {
                    let _ = send.write_all(MISS).await;
                }
            }
            let _ = send.finish();
        }
        VERB_HAS => {
            let exists = safe_path(&root, &key).map(|p| p.is_file()).unwrap_or(false);
            let _ = send.write_all(if exists { b"HIT" } else { b"MISS" }).await;
            let _ = send.finish();
        }
        VERB_LIST => {
            // `key` is treated as a prefix directory under the store root.
            let mut keys = Vec::new();
            if let Ok(base) = safe_path(&root, &key) {
                collect_keys(&root, &base, &mut keys);
            }
            keys.sort();
            let body = keys.join("\n");
            let _ = send.write_all(body.as_bytes()).await;
            let _ = send.finish();
        }
        _ => {
            let _ = send.write_all(b"ERR verb").await;
            let _ = send.finish();
        }
    }
    Ok(())
}

/// Recursively collect store-relative key strings under `dir` (best-effort).
fn collect_keys(root: &Path, dir: &Path, out: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_keys(root, &path, out);
        } else if path.is_file() {
            if path.extension().map(|e| e == "part").unwrap_or(false) {
                continue; // skip in-progress writes
            }
            if let Ok(rel) = path.strip_prefix(root) {
                out.push(rel.to_string_lossy().replace('\\', "/"));
            }
        }
    }
}

// --- client side ---------------------------------------------------------------------

/// A consumer-side client for a remote [`BlobServer`], reachable by the volunteer's node
/// id over iroh (discovery resolves it; same NAT-traversal as everything else).
pub struct BlobClient {
    endpoint: Endpoint,
    dest: EndpointAddr,
    /// ONE warm QUIC connection to `dest`, reused across every get/put/list. Without this, `conn()`
    /// re-dialed a fresh connection on EVERY call — a 297 MB chunked video is 1 manifest + 36 chunk gets =
    /// 37 cold dials to the relay, ×N videos = hundreds of connections, each spinning up iroh's connect +
    /// (failing) hole-punch machinery. That connection storm is what made cross-NAT media sync collapse
    /// under load (early fetches succeed, later ones TimedOut). Reuse keeps it to one connection per relay.
    conn: Arc<tokio::sync::Mutex<Option<Connection>>>,
}

impl BlobClient {
    /// Connect by the volunteer's hex node id (discovery resolves a live address).
    pub async fn connect(secret: [u8; 32], volunteer_node_hex: &str) -> Result<Self> {
        let dest = EndpointAddr::new(parse_node_id(volunteer_node_hex)?);
        Self::connect_addr(secret, dest).await
    }

    /// Connect to an explicit address (loopback for same-machine tests, or a resolved
    /// discovery address).
    pub async fn connect_addr(secret: [u8; 32], dest: EndpointAddr) -> Result<Self> {
        let endpoint = Endpoint::builder(N0)
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![])
            // Multipath on so a connection can hold a relay + a direct path at once. IP transport left
            // ENABLED (no clear_ip_transports) so a same-LAN blob fetch takes the direct local path.
            .transport_config(iroh::endpoint::QuicTransportConfig::builder().max_concurrent_multipath_paths(16).build())
            .bind()
            .await
            .ah()?;
        // NEVER dial our OWN id. The relay client connects under our ACCOUNT identity (`secret`), so a
        // relay-list entry equal to our account id (e.g. left over from the pre-device-seed transport, when
        // the relay WAS the account id) would be the account dialing itself → the iroh path-discovery leak.
        if endpoint.id() == dest.id {
            anyhow::bail!("refusing to dial our own node id (blob self-connect guard)");
        }
        Ok(Self { endpoint, dest, conn: Arc::new(tokio::sync::Mutex::new(None)) })
    }

    /// Reuse an EXISTING, warm endpoint (the messaging node's) instead of binding a fresh one. The
    /// fresh-per-connection endpoint (`connect_addr`) had to cold-start its OWN DERP relay handshake +
    /// discovery on every fetch, so a cross-network relay GET timed out (30s) even though the long-lived
    /// messaging endpoint on the SAME node was already DERP-connected ("Connected · Relay"). Dialing the
    /// blob ALPN over that warm endpoint uses the established DERP path, so media fetches actually complete.
    pub fn over_endpoint(endpoint: Endpoint, dest: EndpointAddr) -> Result<Self> {
        if endpoint.id() == dest.id {
            anyhow::bail!("refusing to dial our own node id (blob self-connect guard)");
        }
        Ok(Self { endpoint, dest, conn: Arc::new(tokio::sync::Mutex::new(None)) })
    }

    /// Return the ONE warm connection to `dest`, reusing it if still open, else dialing (and caching) a
    /// fresh one. Reusing avoids a cold dial per get/put — the connection storm that broke cross-NAT media.
    async fn conn(&self) -> Result<Connection> {
        let mut guard = self.conn.lock().await;
        if let Some(c) = guard.as_ref() {
            if c.close_reason().is_none() {
                return Ok(c.clone());
            }
        }
        let c = self.endpoint.connect(self.dest.clone(), BLOB_ALPN).await.ah()?;
        *guard = Some(c.clone());
        Ok(c)
    }

    /// Store a (sealed) blob at `key`. The relay stores it verbatim.
    pub async fn put(&self, key: &str, body: &[u8]) -> Result<()> {
        if body.len() as u64 > MAX_BLOB {
            bail!("blob too large");
        }
        let conn = self.conn().await?;
        let (mut send, mut recv) = conn.open_bi().await.ah()?;
        write_header(&mut send, VERB_PUT, key).await?;
        send.write_u64(body.len() as u64).await.ah()?;
        send.write_all(body).await.ah()?;
        send.finish().ah()?;
        let reply = recv.read_to_end(64).await.ah()?;
        if reply == b"OK" {
            Ok(())
        } else {
            bail!("put failed: {}", String::from_utf8_lossy(&reply))
        }
    }

    /// Fetch the (sealed) blob at `key`, or `None` if the relay doesn't have it.
    pub async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let conn = self.conn().await?;
        let (mut send, mut recv) = conn.open_bi().await.ah()?;
        write_header(&mut send, VERB_GET, key).await?;
        send.write_u64(0).await.ah()?;
        send.finish().ah()?;
        let bytes = recv.read_to_end(MAX_BLOB as usize).await.ah()?;
        if bytes == MISS {
            Ok(None)
        } else {
            Ok(Some(bytes))
        }
    }

    /// Existence check for `key`.
    pub async fn has(&self, key: &str) -> Result<bool> {
        let conn = self.conn().await?;
        let (mut send, mut recv) = conn.open_bi().await.ah()?;
        write_header(&mut send, VERB_HAS, key).await?;
        send.write_u64(0).await.ah()?;
        send.finish().ah()?;
        let reply = recv.read_to_end(16).await.ah()?;
        Ok(reply == b"HIT")
    }

    /// List stored keys under `prefix` (e.g. a circle's mailbox path). Used to poll the
    /// mailbox for new sealed posts.
    pub async fn list(&self, prefix: &str) -> Result<Vec<String>> {
        let conn = self.conn().await?;
        let (mut send, mut recv) = conn.open_bi().await.ah()?;
        write_header(&mut send, VERB_LIST, prefix).await?;
        send.write_u64(0).await.ah()?;
        send.finish().ah()?;
        let bytes = recv.read_to_end(MAX_BLOB as usize).await.ah()?;
        if bytes.is_empty() {
            return Ok(Vec::new());
        }
        Ok(String::from_utf8_lossy(&bytes).lines().map(|s| s.to_string()).collect())
    }

    pub async fn close(self) {
        self.endpoint.close().await;
    }
}

async fn write_header(send: &mut iroh::endpoint::SendStream, verb: u8, key: &str) -> Result<()> {
    if key.is_empty() || key.len() > MAX_KEY {
        bail!("bad key length");
    }
    send.write_u8(verb).await.ah()?;
    send.write_u16(key.len() as u16).await.ah()?;
    send.write_all(key.as_bytes()).await.ah()?;
    Ok(())
}

/// Parse a 64-hex node id into an iroh `EndpointId`.
pub fn parse_node_id(hex: &str) -> Result<EndpointId> {
    let h = hex.trim();
    if h.len() != 64 {
        bail!("volunteer node id must be 64 hex chars");
    }
    let mut id = [0u8; 32];
    for i in 0..32 {
        id[i] = u8::from_str_radix(&h[i * 2..i * 2 + 2], 16).map_err(|_| anyhow!("bad hex"))?;
    }
    EndpointId::from_bytes(&id).ah()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_path_confines_to_root() {
        let root = Path::new("/store");
        assert!(safe_path(root, "mailbox/fam/abc123").is_ok());
        assert!(safe_path(root, "../etc/passwd").is_err());
        assert!(safe_path(root, "/etc/passwd").is_err());
        assert!(safe_path(root, "a/../../b").is_err());
        assert!(safe_path(root, "").is_err());
        assert!(safe_path(root, "ok").is_ok());
        let resolved = safe_path(root, "mailbox/fam/abc123").unwrap();
        assert!(resolved.starts_with(root));
    }

    #[test]
    fn keys_to_pull_skips_local_and_unsafe() {
        let dir = std::env::temp_dir().join(format!("haven-sync-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("haven/mailbox/fam")).unwrap();
        // We already hold this one.
        std::fs::write(dir.join("haven/mailbox/fam/have"), b"x").unwrap();

        let peer = vec![
            "haven/mailbox/fam/have".to_string(),   // already local → skip
            "haven/mailbox/fam/missing".to_string(), // we lack it → pull
            "haven/media/blob1".to_string(),         // we lack it → pull
            "../etc/passwd".to_string(),             // path traversal → never
            "/abs/evil".to_string(),                 // absolute → never
        ];
        let want = keys_to_pull(&dir, &peer);
        assert_eq!(want, vec!["haven/mailbox/fam/missing".to_string(), "haven/media/blob1".to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn membership_auth_gates_strangers_but_allows_members_and_relays() {
        let auth: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        let member = "aa".repeat(32);
        let stranger = "bb".repeat(32);
        let sibling = "cc".repeat(32);
        let mbkey = format!("haven/mailbox/fam/{}", "00".repeat(32));

        // Unconfigured relay → permissive for everyone (standalone/self-host unchanged).
        assert!(!mailbox_forbidden(&auth, &stranger, VERB_GET, &mbkey));

        // Configure circle 'fam' with one member + one sibling relay.
        auth.lock().unwrap().members.insert("fam".into(), [member.clone()].into_iter().collect());
        auth.lock().unwrap().relays.insert(sibling.clone());

        // The member may read their circle; a stranger may not (read, nor scoped enumerate).
        assert!(!mailbox_forbidden(&auth, &member, VERB_GET, &mbkey));
        assert!(mailbox_forbidden(&auth, &stranger, VERB_GET, &mbkey));
        assert!(mailbox_forbidden(&auth, &stranger, VERB_LIST, "haven/mailbox/fam/"));

        // A stranger can't enumerate across circles; a sibling relay can (mesh anti-entropy).
        assert!(mailbox_forbidden(&auth, &stranger, VERB_LIST, "haven/"));
        assert!(!mailbox_forbidden(&auth, &sibling, VERB_LIST, "haven/"));
        assert!(!mailbox_forbidden(&auth, &sibling, VERB_GET, &mbkey));

        // Content-addressed media (opaque hash) stays permissive; an unknown circle is refused.
        assert!(!mailbox_forbidden(&auth, &stranger, VERB_GET, "haven/media/blob1"));
        assert!(mailbox_forbidden(&auth, &stranger, VERB_GET, "haven/mailbox/other/xyz"));
    }
}
