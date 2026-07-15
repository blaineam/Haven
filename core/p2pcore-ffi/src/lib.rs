//! `haven_ffi` — the UniFFI surface that bridges `p2pcore` to Swift (and Kotlin).
//!
//! Keeps the exposed API tiny and Swift-friendly: an [`Account`] object, a couple of
//! free functions, and plain records. All the security-critical logic stays in
//! `p2pcore`; this is only the boundary.

use std::sync::{Arc, Mutex};

use std::collections::{HashMap, HashSet};

use haven_net::Node;
use haven_net::blobstore::BlobClient;
use std::path::PathBuf;
use p2pcore::crypto::{decapsulate, encapsulate_to, open, seal, Encapsulation};
use p2pcore::device::{recipients_with_devices, ContactDevices, DeviceCredential, DeviceList};
use p2pcore::identity::{Identity, HavenId};
use p2pcore::link::HavenLink;
use p2pcore::social::{
    build_feed, open_bytes, open_event, seal_bytes, seal_event, Event, EventKind, FeedPoll, Group,
    SealedEnvelope, TrackRef,
};
use p2pcore::groupkey::{
    mailbox_prefix, new_circle_secret, new_epoch_key, open_event_in_epoch, open_key_commit,
    seal_event_in_epoch, seal_key_commit, EpochEnvelope,
};

/// Wire tags prefixed to an envelope so `receive` can route it. Legacy (untagged) envelopes are raw
/// JSON beginning with `{` (0x7b), so any tag byte we choose that isn't `{` is unambiguous.
const TAG_EPOCH_EVENT: u8 = 0x02; // an EpochEnvelope (event sealed under a circle epoch key)
const TAG_KEY_COMMIT: u8 = 0x03; // a SealedEnvelope carrying a circle epoch key (KeyCommit)
const TAG_DEVICE_ROSTER: u8 = 0x04; // an account's signed device roster (DeviceList + DeviceCredentials)

uniffi::setup_scaffolding!();

/// DIAGNOSTIC: install a tracing subscriber that appends iroh/noq connection-level logs to
/// `<dir>/iroh-trace.log`, so a specific relay dial can be watched step-by-step (candidate paths,
/// hole-punch attempts, DERP fallback, connect, and the blob accept/serve on the far side). Idempotent;
/// safe no-op if a subscriber is already set. Never panics (falls back to a sink on file error).
#[uniffi::export]
pub fn init_logging(dir: String) {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let path = std::path::PathBuf::from(&dir).join("iroh-trace.log");
        // Cap the file: it appends debug-level connection logs for the app's whole life and had
        // grown unbounded (370MB observed on a daily-driver Mac). Start fresh past ~16MB.
        if std::fs::metadata(&path).map(|m| m.len() > 16 * 1024 * 1024).unwrap_or(false) {
            let _ = std::fs::remove_file(&path);
        }
        let filter = tracing_subscriber::EnvFilter::new(
            "iroh=debug,iroh_relay=debug,iroh_net=debug,noq=info,haven_net=debug",
        );
        // One shared handle (Mutex<File> is a MakeWriter) — the previous per-line open/append/close
        // was needless I/O churn during connection storms (exactly when this log is busiest).
        let file: Box<dyn std::io::Write + Send> =
            match std::fs::OpenOptions::new().create(true).append(true).open(&path) {
                Ok(f) => Box::new(f),
                Err(_) => Box::new(std::io::sink()),
            };
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_ansi(false)
            .with_writer(std::sync::Mutex::new(file))
            .try_init();
    });
}

/// Multi-device (D16): device-credential + account-state self-sync FFI surface.
/// `pub` so the desktop backend (which links this crate directly) can call the shared
/// circle encoder + S3 helpers without going through UniFFI.
pub mod multidevice;

/// Android only: receive the app's `Context` (and, via it, the `JavaVM`) from Kotlin and hand
/// both to `ndk-context`. iroh's TLS stack (rustls platform verifier) reads the system trust
/// store through JNI, which panics with "android context was not initialized" if this isn't done.
/// Called once at startup by `com.blaineam.haven.core.NativeBridge.nativeInitAndroidContext`.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_blaineam_haven_core_NativeBridge_nativeInitAndroidContext<'local>(
    env: jni::JNIEnv<'local>,
    _class: jni::objects::JClass<'local>,
    context: jni::objects::JObject<'local>,
) {
    if let Ok(vm) = env.get_java_vm() {
        if let Ok(global) = env.new_global_ref(&context) {
            unsafe {
                ndk_context::initialize_android_context(
                    vm.get_java_vm_pointer() as *mut std::ffi::c_void,
                    global.as_obj().as_raw() as *mut std::ffi::c_void,
                );
            }
            // Leak the global ref so the Context stays valid for the whole process.
            std::mem::forget(global);
        }
    }
}

/// Errors crossing the FFI boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HavenError {
    #[error("{msg}")]
    Invalid { msg: String },
}

/// A Haven account: a no-PII identity backed by a hybrid post-quantum keypair.
/// Wraps `p2pcore::identity::Identity`.
#[derive(uniffi::Object)]
pub struct Account {
    inner: Identity,
}

#[uniffi::export]
impl Account {
    /// Create a brand-new account (random master seed).
    #[uniffi::constructor]
    pub fn generate() -> Arc<Self> {
        Arc::new(Self { inner: Identity::generate() })
    }

    /// Restore an account from its 32-byte master seed (e.g. read from the Keychain).
    #[uniffi::constructor]
    pub fn from_seed(seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be exactly 32 bytes".into() })?;
        Ok(Arc::new(Self { inner: Identity::from_seed(&seed) }))
    }

    /// The 32-byte master seed — the secret to persist in the Keychain / Secure
    /// Enclave and to back up for recovery. Reconstructs the whole identity.
    pub fn secret_seed(&self) -> Vec<u8> {
        self.inner.secret_seed().to_vec()
    }

    /// The routable node id (Ed25519 public key) as hex.
    pub fn node_id_hex(&self) -> String {
        hex(&self.inner.public().node_id_bytes())
    }

    /// Tamper-check fingerprint of the full hybrid public bundle, as hex.
    pub fn verification_hex(&self) -> String {
        hex(&self.inner.public().verification())
    }

    /// `haven://u/<id>#<verify>` — the deep-link / QR form of the reach-me link.
    pub fn haven_uri(&self) -> String {
        HavenLink::from_identity(&self.inner.public()).to_uri()
    }

    /// `https://<domain>/u/<id>#<verify>` — the website form of the reach-me link.
    pub fn haven_link(&self, domain: String) -> String {
        HavenLink::from_identity(&self.inner.public()).to_web(&domain)
    }

    /// The full public identity bundle (for publishing to discovery).
    pub fn public_bundle(&self) -> Vec<u8> {
        self.inner.public().to_bytes()
    }

    /// Sign a push-registration challenge so the blind push worker can verify a registration really
    /// comes from this identity (audit F5) — stops anyone registering their device token under another
    /// node id (token hijack / eviction). Domain-separated + purpose-specific (NOT a raw signing
    /// oracle). Returns the Ed25519 signature (the worker verifies it against the node id, which IS
    /// the Ed25519 public key) over a message binding the node id, the token, and a timestamp.
    pub fn sign_push_registration(&self, token: String, ts_secs: u64) -> Vec<u8> {
        let node_hex = hex(&self.inner.public().node_id_bytes());
        let msg = format!("haven-push-register-v1:{node_hex}:{token}:{ts_secs}");
        let sig = self.inner.sign(msg.as_bytes());
        sig[..64.min(sig.len())].to_vec() // the Ed25519 half — what the worker can verify
    }

    // NOTE: a raw `sign(msg)` was deliberately removed (audit H3). Exposing an unrestricted hybrid
    // signing oracle over the FFI let any caller obtain a signature over chosen bytes, which could be
    // replayed into a domain that expects a signature of the same shape. Signing now happens only
    // through purpose-specific, domain-separated paths inside the engine (envelopes, profile cards,
    // key commits, device lists), never over arbitrary input.
}

/// Parsed contents of a reach-me link.
#[derive(uniffi::Record)]
pub struct LinkInfo {
    pub id_hex: String,
    pub verification_hex: String,
    pub uri: String,
}

/// Parse a `haven://` or `https://…/u/…#…` reach-me link.
#[uniffi::export]
pub fn parse_link(s: String) -> Result<LinkInfo, HavenError> {
    let link = HavenLink::parse(&s).map_err(|e| HavenError::Invalid { msg: format!("{e}") })?;
    Ok(LinkInfo {
        id_hex: hex(&link.id),
        verification_hex: hex(&link.verification),
        uri: link.to_uri(),
    })
}

/// Result of the on-device cryptographic self-test.
#[derive(uniffi::Record)]
pub struct SelfTestReport {
    pub identity_ok: bool,
    pub hybrid_kem_ok: bool,
    pub signature_ok: bool,
    pub link_ok: bool,
    pub all_ok: bool,
    pub node_id_hex: String,
    pub summary: String,
}

/// Run the full hybrid-PQ pipeline **on this device** and report what passed:
/// generate an identity, seal a payload to itself (X25519+ML-KEM-768 → AES-256-GCM)
/// and reopen it, sign+verify (Ed25519+ML-DSA), and round-trip a reach-me link.
#[uniffi::export]
pub fn self_test() -> SelfTestReport {
    let id = Identity::generate();
    let pubid = id.public();
    let payload = b"on-device hybrid post-quantum self-test";

    let identity_ok = pubid.node_id_bytes() != [0u8; 32];

    let hybrid_kem_ok = match encapsulate_to(&pubid) {
        Ok((enc, key)) => {
            let sealed = seal(&key, payload);
            match decapsulate(&id, &enc) {
                Ok(k2) => open(&k2, &sealed).map(|p| p == payload).unwrap_or(false),
                Err(_) => false,
            }
        }
        Err(_) => false,
    };

    let sig = id.sign(payload);
    let signature_ok = pubid.verify(payload, &sig).is_ok()
        && pubid.verify(b"different message", &sig).is_err();

    let link = HavenLink::from_identity(&pubid);
    let link_ok = HavenLink::parse(&link.to_uri()).map(|l| l == link).unwrap_or(false);

    let all_ok = identity_ok && hybrid_kem_ok && signature_ok && link_ok;
    let summary = if all_ok {
        "All hybrid post-quantum checks passed on this device.".to_string()
    } else {
        "One or more on-device checks failed.".to_string()
    };

    SelfTestReport {
        identity_ok,
        hybrid_kem_ok,
        signature_ok,
        link_ok,
        all_ok,
        node_id_hex: hex(&pubid.node_id_bytes()),
        summary,
    }
}

/// Open a blob sealed to us by `seal_media`, using ONLY our 32-byte master seed —
/// no loaded circle/account state required. This is for the iOS Notification Service
/// Extension, which runs in its own process (often on the lock screen) with nothing
/// but the seed read from the shared Keychain: it must decrypt the push payload and
/// rewrite the alert without spinning up the whole engine or touching disk.
///
/// The wire layout matches `seal_media` exactly:
/// `[32 eph_x_pub][u32 LE pq_len][pq_ct][aes-gcm ciphertext]`. Returns the plaintext,
/// or `None` if the seed is the wrong length, the blob is malformed, or it wasn't
/// sealed to us (decapsulation/AEAD fails) — the NSE then shows a generic alert.
#[uniffi::export]
pub fn open_sealed_with_seed(seed: Vec<u8>, sealed: Vec<u8>) -> Option<Vec<u8>> {
    let seed: [u8; 32] = seed.try_into().ok()?;
    let me = Identity::from_seed(&seed);
    if sealed.len() < 36 {
        return None;
    }
    let eph_x_pub: [u8; 32] = sealed[0..32].try_into().ok()?;
    let pq_len = u32::from_le_bytes(sealed[32..36].try_into().ok()?) as usize;
    if sealed.len() < 36 + pq_len {
        return None;
    }
    let pq_ct = sealed[36..36 + pq_len].to_vec();
    let ct = &sealed[36 + pq_len..];
    let enc = Encapsulation { eph_x_pub, pq_ct };
    let key = decapsulate(&me, &enc).ok()?;
    open(&key, ct).ok()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// An opened, sender-authenticated push notification (audit H2).
/// A contact's signed device roster, wire-tagged for sharing, plus the contact's account hex so a
/// receiving own-device can key it in self-sync (one entry per known contact roster).
#[derive(uniffi::Record)]
pub struct ContactRosterWire {
    pub account_hex: String,
    pub wire: Vec<u8>,
}

/// A circle-sealed blob opened together with its authenticated sender (a member's account id hex) —
/// for callers that must judge the ANNOUNCER, not just read the payload (owner-gated relay announces).
#[derive(uniffi::Record)]
pub struct OpenedCircleBlobFfi {
    pub sender_hex: String,
    pub data: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct SignedNotification {
    /// The verified author's node id (hex). The receiver should still confirm it's a known contact
    /// before trusting the display name — the signature proves authenticity, not authorization.
    pub sender_hex: String,
    pub data: Vec<u8>,
}

/// The bytes a notification signature covers: a domain tag ‖ the recipient node id ‖ the plaintext.
/// Binding the recipient stops a captured notification being replayed at a different user.
fn notif_signing_bytes(recipient_hex: &str, plaintext: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(14 + recipient_hex.len() + plaintext.len());
    v.extend_from_slice(b"haven-notif-v1");
    v.extend_from_slice(recipient_hex.as_bytes());
    v.extend_from_slice(plaintext);
    v
}

/// NSE/recipient side: open a SIGNED push notification with the seed alone, verifying the carried
/// sender bundle actually authored it. Defeats the spoof where anyone holding the recipient's public
/// key seals an arbitrary "Alice|…" alert — a forger can only sign as *themselves*, never as a
/// contact, and the bound recipient prevents replay. Layout:
/// [u32 bundle_len][bundle][u32 sig_len][sig][seal_media output].
#[uniffi::export]
pub fn open_signed_notification_with_seed(seed: Vec<u8>, blob: Vec<u8>) -> Option<SignedNotification> {
    let seed_arr: [u8; 32] = seed.clone().try_into().ok()?;
    let me = Identity::from_seed(&seed_arr);
    let recipient_hex = hex(&me.public().node_id_bytes());
    if blob.len() < 4 {
        return None;
    }
    let blen = u32::from_le_bytes(blob[0..4].try_into().ok()?) as usize;
    if blob.len() < 8 + blen {
        return None;
    }
    let bundle = &blob[4..4 + blen];
    let slen = u32::from_le_bytes(blob[4 + blen..8 + blen].try_into().ok()?) as usize;
    if blob.len() < 8 + blen + slen {
        return None;
    }
    let sig = &blob[8 + blen..8 + blen + slen];
    let sealed = blob[8 + blen + slen..].to_vec();
    let plaintext = open_sealed_with_seed(seed, sealed)?;
    let sender = HavenId::from_bytes(bundle).ok()?;
    sender.verify(&notif_signing_bytes(&recipient_hex, &plaintext), sig).ok()?;
    Some(SignedNotification { sender_hex: hex(&sender.node_id_bytes()), data: plaintext })
}

// ===== Circle relay / mailbox (haven-relay blob store over Haven Net) =====

/// A parsed relay link: which circle, and the member node ids the relay serves.
#[derive(uniffi::Record)]
pub struct RelayLinkInfo {
    pub circle: String,
    pub members: Vec<String>,
}

/// Build a `haven-relay://circle#<base32(json)>` link to hand to a relay (the Mac app's
/// built-in relay, or a standalone `haven-relay`). Mirrors `haven-relay`'s `RelayLink` format.
#[uniffi::export]
pub fn make_relay_link(circle: String, members: Vec<String>) -> String {
    let v = serde_json::json!({ "v": 1, "c": circle, "m": members });
    let json = serde_json::to_vec(&v).unwrap_or_default();
    format!("haven-relay://circle#{}", data_encoding::BASE32_NOPAD.encode(&json))
}

/// Parse a relay link (the `haven-relay://` form or a bare base32 payload).
#[uniffi::export]
pub fn parse_relay_link(uri: String) -> Option<RelayLinkInfo> {
    let s = uri.trim();
    let payload = s.rsplit_once('#').map(|(_, f)| f).unwrap_or(s);
    if payload.is_empty() {
        return None;
    }
    let json = data_encoding::BASE32_NOPAD.decode(payload.as_bytes()).ok()?;
    let v: serde_json::Value = serde_json::from_slice(&json).ok()?;
    if v.get("v").and_then(|x| x.as_u64()) != Some(1) {
        return None;
    }
    let circle = v.get("c")?.as_str()?.to_string();
    let members = v
        .get("m")?
        .as_array()?
        .iter()
        .filter_map(|x| x.as_str().map(String::from))
        .collect();
    Some(RelayLinkInfo { circle, members })
}

/// Build the `Authorization` header value for ONE request to a relay's HTTP media interface
/// (`http://<relay>:8674`) — the default cross-NAT media transport.
///
/// Every HTTP client on every platform must call this per request; there is no longer a static
/// credential to reuse. `seed` is the account master seed (the node key is derived from it, so the
/// relay sees the same identity it sees over iroh); `token` is the relay's shared secret from the
/// sealed relay announce; `method` is the HTTP verb; `key` is the STORE KEY, i.e. the request path
/// with its `/k/`, `/l/`, or `/t/` prefix removed; `body` is the exact request body (empty for
/// GET/HEAD/LIST). The result goes in `Authorization:` verbatim.
///
/// The signature is bound to method+key+body+time+nonce, so it authorizes that one request and
/// nothing else: it cannot be replayed, retargeted at another key, or reused after ~5 minutes.
/// Requests must therefore be signed at send time, not cached.
#[uniffi::export]
pub fn http_auth_header(seed: Vec<u8>, token: String, method: String, key: String, body: Vec<u8>) -> Result<String, HavenError> {
    let seed: [u8; 32] = seed.try_into().map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
    let id = Identity::from_seed(&seed);
    Ok(haven_net::httprelay::auth_header(&id.node_secret_bytes(), &token, &method, &key, &body))
}

/// Client to a circle's blob mailbox (a relay's local-disk store, reached over Haven Net /
/// iroh). Used to upload a circle-sealed media blob and fetch it later — no shared bucket
/// credentials, just the relay's node id. The relay never sees content (blobs are sealed).
#[derive(uniffi::Object)]
pub struct RelayClient {
    inner: BlobClient,
}

#[uniffi::export(async_runtime = "tokio")]
impl RelayClient {
    /// Connect to a relay by its node id (from the relay link). `seed` is this device's
    /// 32-byte identity (its own transport key).
    #[uniffi::constructor]
    pub async fn connect(seed: Vec<u8>, relay_node_hex: String) -> Result<Arc<Self>, HavenError> {
        let s: [u8; 32] = seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        let inner = BlobClient::connect(s, &relay_node_hex)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("relay connect: {e}") })?;
        Ok(Arc::new(Self { inner }))
    }

    /// Store a sealed blob under `key` (e.g. `mailbox/<circle>/<hash>`).
    pub async fn put(&self, key: String, data: Vec<u8>) -> Result<(), HavenError> {
        self.inner
            .put(&key, &data)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("relay put: {e}") })
    }

    /// Fetch a sealed blob (None if the relay doesn't have it).
    pub async fn get(&self, key: String) -> Option<Vec<u8>> {
        self.inner.get(&key).await.ok().flatten()
    }

    pub async fn has(&self, key: String) -> bool {
        self.inner.has(&key).await.unwrap_or(false)
    }

    /// List keys under a prefix (e.g. `mailbox/<circle>`) to poll the mailbox.
    pub async fn list(&self, prefix: String) -> Vec<String> {
        self.inner.list(&prefix).await.unwrap_or_default()
    }

    /// Refresh the liveness of `keys` (all under `prefix`, one circle's mailbox path) so the
    /// relay's mailbox GC keeps them; returns the keys the relay does NOT hold — re-PUT those
    /// (the daily refresh doubles as repair). Errors against an unreachable or pre-GC relay.
    pub async fn touch(&self, prefix: String, keys: Vec<String>) -> Result<Vec<String>, HavenError> {
        self.inner
            .touch(&prefix, &keys)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("relay touch: {e}") })
    }
}

/// The built-in relay/mailbox the app runs in-process. It now ATTACHES to the messaging node's
/// existing endpoint (one iroh node, two ALPNs) instead of spawning its own — running a second
/// in-process iroh node made iroh's path manager churn unboundedly (the tens-of-GB leak). Its
/// `node_id_hex` is therefore the ACCOUNT node id; that's the `volunteer_node_id` for the relay link.
/// Hold the object to keep serving; drop it (or call `disable`) to stop.
#[derive(uniffi::Object)]
pub struct RelayServerHandle {
    node: Arc<HavenNode>,
}

#[uniffi::export(async_runtime = "tokio")]
impl RelayServerHandle {
    /// Attach the relay/mailbox to a running [`HavenNode`], serving blobs from `dir` on that node's
    /// endpoint (under the blob ALPN). No second iroh node, no self-connection, no path-churn leak.
    #[uniffi::constructor]
    pub fn attach(node: Arc<HavenNode>, dir: String) -> Arc<Self> {
        node.node.enable_relay(PathBuf::from(dir));
        Arc::new(Self { node })
    }

    /// The relay's node id (hex) — now equal to the account/messaging node id. Put it in the relay link.
    pub fn node_id_hex(&self) -> String {
        self.node.node.node_id_hex()
    }

    /// Authorize a circle's mailbox to exactly `members` (node hexes) + its sibling `relays` (audit
    /// transport-F4). Call on attach and on every membership change.
    pub fn authorize_circle(&self, circle_id: String, members: Vec<String>, relays: Vec<String>) {
        self.node.node.relay_authorize(&circle_id, members, relays);
    }

    /// Stop serving a circle's mailbox (we left it / no longer host it).
    pub fn deauthorize_circle(&self, circle_id: String) {
        self.node.node.relay_deauthorize(&circle_id);
    }

    /// Store the host's OWN sealed event/media directly into the local mailbox — no iroh self-connection
    /// (the thing that exploded). Returns true on success. Idempotent (content-addressed keys).
    pub fn local_put(&self, key: String, data: Vec<u8>) -> bool {
        self.node.node.relay_local_put(&key, &data)
    }

    /// True if our mailbox already holds `key`.
    pub fn local_has(&self, key: String) -> bool {
        self.node.node.relay_local_has(&key)
    }

    /// Read a blob from our OWN mailbox (what a sibling device or a friend uploaded to us), without
    /// dialing ourselves. None if absent. Lets the host ingest its own relay store.
    pub fn local_get(&self, key: String) -> Option<Vec<u8>> {
        self.node.node.relay_local_get(&key)
    }

    /// Every key under `prefix` our OWN mailbox holds — so the host can enumerate + ingest blobs others
    /// uploaded to it (it can't poll itself over iroh).
    pub fn local_list(&self, prefix: String) -> Vec<String> {
        self.node.node.relay_local_list(&prefix)
    }

    /// Refresh the liveness of `keys` in our OWN hosted mailbox (the host's daily refresh can't
    /// TOUCH itself over iroh — self-dial guard). Returns the keys the store does NOT hold so the
    /// caller re-PUTs them via `local_put`.
    pub fn local_touch(&self, keys: Vec<String>) -> Vec<String> {
        self.node.node.relay_local_touch(&keys)
    }

    /// Serve this relay's store over plain HTTP on `bind` (e.g. "0.0.0.0:8674"; port 0 =
    /// ephemeral) — the DEFAULT cross-NAT media transport (the iroh blob ALPN drops datagrams on
    /// pure-relay cross-NAT paths). Returns the bound port. Idempotent while serving.
    ///
    /// Requests are authorized by the caller's per-request node-key signature against this relay's
    /// circle membership — the same gate as the iroh path. `token` is the shared relay secret from
    /// the sealed relay announce, folded into each signature (never sent). Clients build their
    /// header with [`http_auth_header`]. `self/…` keys are never served over HTTP.
    pub async fn serve_http(&self, bind: String, token: String) -> Result<u16, HavenError> {
        self.node
            .node
            .relay_serve_http(&bind, &token)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("serve http: {e}") })
    }

    /// Stop hosting the relay on this node (drops the attachment).
    pub fn disable(&self) {
        self.node.node.disable_relay();
    }

    /// Mesh anti-entropy: pull every sealed blob a SIBLING relay holds that we lack. Returns the
    /// number of new blobs pulled (0 if unreachable). Content-addressed + sealed → conflict-free.
    pub async fn sync_from(&self, peer_node_hex: String) -> u32 {
        self.node.node.relay_sync_from(&peer_node_hex).await as u32
    }
}

// ===== Live social demo =====
//
// A local, on-device demonstration of the social engine: every post / comment /
// reaction is really sealed end-to-end to the group and reopened (loopback), then
// reduced into a feed. It pairs your real account with a deterministic "friend"
// identity so you can see two-party interaction. (Networking between real devices
// is the next milestone; the crypto and feed logic here are the real thing.)

const FRIEND_SEED: [u8; 32] = *b"haven-demo-friend-seed-v1-padxxx";

struct DemoState {
    me: Identity,
    friend: Identity,
    group: Group,
    events: Vec<Event>,
}

/// A live local social session over the real hybrid-PQ social engine.
#[derive(uniffi::Object)]
pub struct SocialDemo {
    state: Mutex<DemoState>,
}

#[uniffi::export]
impl SocialDemo {
    /// Start a demo session from your account seed (your real identity) paired with a
    /// stable demo "friend".
    #[uniffi::constructor]
    pub fn new(account_seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        let me = Identity::from_seed(&seed);
        let friend = Identity::from_seed(&FRIEND_SEED);
        let group = Group::new("demo", vec![me.public(), friend.public()]);
        Ok(Arc::new(Self { state: Mutex::new(DemoState { me, friend, group, events: vec![] }) }))
    }

    pub fn my_node_hex(&self) -> String {
        hex(&self.state.lock().unwrap().me.public().node_id_bytes())
    }

    pub fn post(
        &self,
        body: String,
        media: Vec<String>,
        music: Option<TrackRefFfi>,
        retention_secs: Option<u64>,
        created_at: u64,
    ) -> String {
        let music = music.map(|m| m.into_core());
        self.author_event(true, created_at, EventKind::Post { body, media, music, retention_secs, story: false, mute_video: false })
    }
    pub fn friend_post(&self, body: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Post { body, media: vec![], music: None, retention_secs: None, story: false, mute_video: false })
    }
    pub fn comment(&self, target: String, body: String, media: Vec<String>, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Comment { target, body, media })
    }
    pub fn friend_comment(&self, target: String, body: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Comment { target, body, media: vec![] })
    }
    pub fn react(&self, target: String, emoji: String, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Reaction { target, emoji })
    }
    pub fn unreact(&self, target: String, emoji: String, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Unreact { target, emoji })
    }
    pub fn friend_react(&self, target: String, emoji: String, created_at: u64) -> String {
        self.author_event(false, created_at, EventKind::Reaction { target, emoji })
    }
    pub fn edit(&self, target: String, body: String, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Edit { target, body, media: vec![], music: None, mute_video: false })
    }
    pub fn unsend(&self, target: String, created_at: u64) -> String {
        self.author_event(true, created_at, EventKind::Unsend { target })
    }

    /// The current feed (newest first), with comments and reactions resolved.
    pub fn feed(&self, now_ms: u64, viewer_retention_secs: Option<u64>) -> Vec<FeedItemFfi> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me.public().node_id_bytes());
        build_feed(st.events.clone(), now_ms, viewer_retention_secs, None)
            .into_iter()
            .map(|it| FeedItemFfi {
                id: it.id,
                author_short: short(&it.author),
                is_me: it.author == me,
                created_at: it.created_at,
                body: it.body,
                media: it.media,
                music: it.music.map(TrackRefFfi::from_core),
                edited: it.edited,
                unsent: it.unsent,
                story: it.story,
                mute_video: it.mute_video,
                comments: it
                    .comments
                    .into_iter()
                    .map(|c| FeedCommentFfi {
                        id: c.id,
                        author_short: short(&c.author),
                        is_me: c.author == me,
                        created_at: c.created_at,
                        body: c.body,
                        media: c.media,
                        edited: c.edited,
                        unsent: c.unsent,
                        reactions: c.reactions.into_iter().map(|r| ReactionFfi {
                            emoji: r.emoji, count: r.count, mine: r.authors.contains(&me), authors: r.authors,
                        }).collect(),
                    })
                    .collect(),
                reactions: it
                    .reactions
                    .into_iter()
                    .map(|r| ReactionFfi {
                        emoji: r.emoji,
                        count: r.count,
                        mine: r.authors.contains(&me),
                        authors: r.authors,
                    })
                    .collect(),
                poll: it.poll.map(|p| poll_ffi(&p, &me)),
            })
            .collect()
    }

}

// Non-exported helpers (kept out of the UniFFI surface).
impl SocialDemo {
    /// Author an event as me or the friend: really seal it E2E to the group and
    /// reopen it (proving the crypto), then record it. Returns the event id.
    fn author_event(&self, as_me: bool, created_at: u64, kind: EventKind) -> String {
        let mut st = self.state.lock().unwrap();
        let author_pub = if as_me { st.me.public() } else { st.friend.public() };
        let event = Event::new(&author_pub.node_id_bytes(), created_at, kind);
        // Seal to the whole group, then reopen as me — the real E2E round-trip.
        let opened = {
            let author = if as_me { &st.me } else { &st.friend };
            let env = seal_event(author, &st.group, &event).expect("seal");
            open_event(&st.me, &author_pub, &env).expect("open")
        };
        let id = opened.id.clone();
        st.events.push(opened);
        id
    }
}

/// A reaction aggregate for the UI.
#[derive(uniffi::Record)]
pub struct ReactionFfi {
    pub emoji: String,
    pub count: u32,
    pub mine: bool,
    /// Node-id hexes of who reacted with this emoji (so the UI can show names).
    pub authors: Vec<String>,
}

/// A comment for the UI.
#[derive(uniffi::Record)]
pub struct FeedCommentFfi {
    pub id: String,
    pub author_short: String,
    pub is_me: bool,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub edited: bool,
    pub unsent: bool,
    pub reactions: Vec<ReactionFfi>,
}

/// An attached Apple Music track (reference only — never audio).
#[derive(uniffi::Record, Clone)]
pub struct TrackRefFfi {
    pub catalog_id: String,
    pub title: String,
    pub artist: String,
    pub artwork_url: String,
    pub duration_ms: u64,
}

impl TrackRefFfi {
    fn into_core(self) -> TrackRef {
        TrackRef {
            catalog_id: self.catalog_id,
            title: self.title,
            artist: self.artist,
            artwork_url: self.artwork_url,
            duration_ms: self.duration_ms,
        }
    }
    fn from_core(t: TrackRef) -> Self {
        Self {
            catalog_id: t.catalog_id,
            title: t.title,
            artist: t.artist,
            artwork_url: t.artwork_url,
            duration_ms: t.duration_ms,
        }
    }
}

/// A feed item (post/message) for the UI.
#[derive(uniffi::Record)]
pub struct FeedItemFfi {
    pub id: String,
    pub author_short: String,
    pub is_me: bool,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub music: Option<TrackRefFfi>,
    pub edited: bool,
    pub unsent: bool,
    pub story: bool,
    pub mute_video: bool,
    pub comments: Vec<FeedCommentFfi>,
    pub reactions: Vec<ReactionFfi>,
    /// Present when this item is a poll.
    pub poll: Option<PollFfi>,
}

/// One poll option with its tally for the UI.
#[derive(uniffi::Record)]
pub struct PollOptionFfi {
    pub text: String,
    pub votes: u32,
}

/// A poll on a feed item for the UI.
#[derive(uniffi::Record)]
pub struct PollFfi {
    pub question: String,
    pub options: Vec<PollOptionFfi>,
    pub total_votes: u32,
    /// Epoch millis the poll closes (0 = never). After close, results are locked.
    pub close_at_ms: u64,
    pub closed: bool,
    /// The option index the viewer voted for, if any.
    pub my_vote: Option<u32>,
}

/// Map a reduced poll to the UI record, resolving the viewer's own vote from the option authors.
fn poll_ffi(p: &FeedPoll, me_hex: &str) -> PollFfi {
    let mut my_vote = None;
    for (i, o) in p.options.iter().enumerate() {
        if o.authors.iter().any(|a| a == me_hex) {
            my_vote = Some(i as u32);
        }
    }
    PollFfi {
        question: p.question.clone(),
        options: p.options.iter().map(|o| PollOptionFfi { text: o.text.clone(), votes: o.votes }).collect(),
        total_votes: p.total_votes,
        close_at_ms: p.close_at_ms,
        closed: p.closed,
        my_vote,
    }
}

/// A member-filed content report for the UI (see `EventKind::Report`). Circles have no owner, so
/// every member receives every report and acts with the power they already hold.
#[derive(uniffi::Record)]
pub struct ReportFfi {
    /// The report event's own id.
    pub id: String,
    /// Who filed it (FULL node hex + 8-char display prefix for contact lookup).
    pub reporter: String,
    pub reporter_short: String,
    /// The reported event id.
    pub target: String,
    /// The reported event's author — FULL node hex, usable directly for block().
    pub author: String,
    pub reason: String,
    pub comment: String,
    pub created_at: u64,
}

fn short(node_hex: &str) -> String {
    node_hex.chars().take(8).collect()
}


// ===== Networking: a live P2P node =====

/// Foreign listener that receives inbound sealed-envelope bytes.
#[uniffi::export(with_foreign)]
pub trait InboundListener: Send + Sync {
    /// `from_hex` is the sender's AUTHENTICATED transport node id (the iroh connection's remote
    /// endpoint id — proof of key possession), or "" when the frame wasn't received over a direct
    /// peer connection. Apps use it to learn a dialable DEVICE id for a contact from any frame they
    /// deliver (the reply-path bootstrap: an invitee holds no dial hints for the initiator, so
    /// their hello-back/DMs otherwise depend on roster propagation that itself needs a route).
    fn on_inbound(&self, from_hex: String, payload: Vec<u8>);
}

/// A live peer-to-peer node: listens for inbound sealed posts and dials peers by
/// ticket. The bytes it moves are already E2E-encrypted by `p2pcore`.
#[derive(uniffi::Object)]
pub struct HavenNode {
    node: Node,
}

#[uniffi::export(async_runtime = "tokio")]
impl HavenNode {
    /// Start a node bound to the given transport seed (so its node id == that seed's Haven id); inbound
    /// payloads are delivered to `listener`. NOTE: callers will pass the per-DEVICE transport seed
    /// (Apple: DeviceKeyStore) once the device-id dialing path lands, so every device gets a distinct,
    /// collision-free iroh node id; the account identity stays the trust/sealing anchor in HavenSocial.
    #[uniffi::constructor]
    pub async fn start(account_seed: Vec<u8>, listener: Arc<dyn InboundListener>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        let identity = Identity::from_seed(&seed);
        let l = listener.clone();
        let handler: haven_net::InboundHandler = Arc::new(move |from: [u8; 32], payload| {
            // All-zeros = not a direct peer connection (relay-routed) → empty sender hex.
            let from_hex = if from == [0u8; 32] { String::new() } else { hex(&from) };
            // Never let a panic cross back into the foreign (Swift) callback and abort.
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| l.on_inbound(from_hex.clone(), payload)));
        });
        let node = Node::spawn(identity.node_secret_bytes(), handler)
            .await
            .map_err(|e| HavenError::Invalid { msg: e.to_string() })?;
        Ok(Arc::new(Self { node }))
    }

    /// This node's id (== the account's Haven id), as hex.
    pub fn node_id_hex(&self) -> String {
        self.node.node_id_hex()
    }

    /// A relay client that dials `relay_node_hex` over THIS node's WARM, DERP-established endpoint, instead
    /// of RelayClient::connect binding a fresh endpoint that cold-starts DERP on every fetch (the reason a
    /// cross-network relay GET timed out at 30s while messaging showed "Connected · Relay"). Reuses the
    /// same endpoint that keeps the messaging/relay path alive, so media fetches actually complete.
    pub fn relay_client(&self, relay_node_hex: String) -> Result<Arc<RelayClient>, HavenError> {
        let inner = self
            .node
            .blob_client(&relay_node_hex)
            .map_err(|e| HavenError::Invalid { msg: format!("relay client: {e}") })?;
        Ok(Arc::new(RelayClient { inner }))
    }

    /// A shareable ticket a peer dials to reach this node (full address form).
    pub async fn ticket(&self) -> Result<String, HavenError> {
        self.node.ticket().await.map_err(|e| HavenError::Invalid { msg: e.to_string() })
    }

    /// Send sealed bytes to a contact by their hex node id (== their Haven id),
    /// resolving the live address via discovery.
    pub async fn send_to_node(&self, node_id_hex: String, payload: Vec<u8>) -> Result<(), HavenError> {
        self.node
            .send_to_node(&node_id_hex, &payload)
            .await
            .map_err(|e| HavenError::Invalid { msg: e.to_string() })
    }

    /// Send sealed bytes to a peer identified by their full-address ticket.
    pub async fn send(&self, ticket: String, payload: Vec<u8>) -> Result<(), HavenError> {
        self.node
            .send_ticket(&ticket, &payload)
            .await
            .map_err(|e| HavenError::Invalid { msg: e.to_string() })
    }
}

// ===== Real networked social store =====

/// Maps the core feed reducer output into the UI record type.
fn map_feed(events: Vec<Event>, me: &str, now_ms: u64, viewer_retention_secs: Option<u64>, keep_own: bool) -> Vec<FeedItemFfi> {
    build_feed(events, now_ms, viewer_retention_secs, if keep_own { Some(me) } else { None })
        .into_iter()
        .map(|it| FeedItemFfi {
            id: it.id,
            author_short: short(&it.author),
            is_me: it.author == me,
            created_at: it.created_at,
            body: it.body,
            media: it.media,
            music: it.music.map(TrackRefFfi::from_core),
            edited: it.edited,
            unsent: it.unsent,
            story: it.story,
            mute_video: it.mute_video,
            comments: it
                .comments
                .into_iter()
                .map(|c| FeedCommentFfi {
                    id: c.id,
                    author_short: short(&c.author),
                    is_me: c.author == me,
                        created_at: c.created_at,
                    body: c.body,
                    media: c.media,
                    edited: c.edited,
                    unsent: c.unsent,
                    reactions: c.reactions.into_iter().map(|r| ReactionFfi {
                        emoji: r.emoji, count: r.count, mine: r.authors.contains(&me.to_string()), authors: r.authors,
                    }).collect(),
                })
                .collect(),
            reactions: it
                .reactions
                .into_iter()
                .map(|r| ReactionFfi {
                    emoji: r.emoji,
                    count: r.count,
                    mine: r.authors.contains(&me.to_string()),
                    authors: r.authors,
                })
                .collect(),
            poll: it.poll.map(|p| poll_ffi(&p, me)),
        })
        .collect()
}

/// One circle: its own membership, event log, and dedup set, plus the **sender-keys** epoch ratchet
/// (see `docs/GROUP-KEYING.md`). Each member runs their OWN epoch sequence: I seal my posts under my
/// current key (`my_epoch` / `my_epoch_keys`) and distribute it in a key commit; I store each PEER's
/// keys by `(author_hex, epoch)` so I can open their epoch events. Removing a member rotates MY epoch
/// (the new commit excludes them), so my future posts are unreadable to them. `pending_epoch` buffers
/// epoch events that arrived before their author's key commit (eventual consistency).
struct Circle {
    id: String,
    name: String,
    members: Vec<HavenId>,
    events: Vec<Event>,
    seen: HashSet<String>,
    my_epoch: u64,
    my_epoch_keys: HashMap<u64, [u8; 32]>,
    peer_epoch_keys: HashMap<(String, u64), [u8; 32]>,
    pending_epoch: Vec<Vec<u8>>,
    /// My STABLE circle secret (zeros = not yet generated) — derives opaque storage-key prefixes for
    /// my blobs; distributed in my key commits. Peers' secrets are stored so I can find their blobs.
    my_circle_secret: [u8; 32],
    peer_circle_secrets: HashMap<String, [u8; 32]>,
    /// Session cache of the last sealed key commit: (context hash over epoch/key/secret/recipients,
    /// tagged wire bytes). The KEM inside a commit is necessarily random, so re-sealing one for the
    /// SAME context produces different bytes — and the content-addressed mailbox then stores a new
    /// copy per backfill run. Reusing the cached bytes while the context is unchanged keeps the
    /// mailbox key stable (events are handled separately: their sealing is fully deterministic).
    cached_commit: Option<([u8; 32], Vec<u8>)>,
}

impl Circle {
    fn bare(id: String, name: String) -> Self {
        Circle {
            id,
            name,
            members: vec![],
            events: vec![],
            seen: HashSet::new(),
            my_epoch: 0,
            my_epoch_keys: HashMap::new(),
            peer_epoch_keys: HashMap::new(),
            pending_epoch: vec![],
            my_circle_secret: [0u8; 32],
            peer_circle_secrets: HashMap::new(),
            cached_commit: None,
        }
    }
    /// Ensure I have a current epoch key for my own posts AND a stable circle secret (bootstrap on
    /// first use).
    fn ensure_epoch(&mut self) {
        if self.my_epoch_keys.is_empty() {
            self.my_epoch = 0;
            self.my_epoch_keys.insert(0, new_epoch_key());
        }
        if self.my_circle_secret == [0u8; 32] {
            self.my_circle_secret = new_circle_secret();
        }
    }
    /// The circle secret to derive `member_hex`'s opaque storage prefix — mine or a stored peer's.
    fn circle_secret_for(&self, me_hex: &str, member_hex: &str) -> Option<[u8; 32]> {
        if member_hex == me_hex {
            (self.my_circle_secret != [0u8; 32]).then_some(self.my_circle_secret)
        } else {
            self.peer_circle_secrets.get(member_hex).copied()
        }
    }
    /// Advance MY epoch on a membership change — my next key commit seals only to the remaining
    /// members, so a removed node can't read my future posts.
    fn rotate_epoch(&mut self) {
        self.ensure_epoch();
        self.my_epoch += 1;
        self.my_epoch_keys.insert(self.my_epoch, new_epoch_key());
        self.prune_epoch_keys();
    }

    /// Bounded forward secrecy (audit C2): keep only the most recent epoch keys (mine + each peer's)
    /// and DELETE the rest. A later seed/device compromise then can't decrypt OLD ciphertext captured
    /// from the wire/relay under a now-deleted key. My own posts always re-seal under the current
    /// epoch on sync, so dropping old keys never blocks re-delivery.
    fn prune_epoch_keys(&mut self) {
        const KEEP_EPOCHS: usize = 4;
        if self.my_epoch_keys.len() > KEEP_EPOCHS {
            let mut epochs: Vec<u64> = self.my_epoch_keys.keys().copied().collect();
            epochs.sort_unstable();
            for e in &epochs[..epochs.len() - KEEP_EPOCHS] {
                self.my_epoch_keys.remove(e);
            }
        }
        let mut by_peer: HashMap<String, Vec<u64>> = HashMap::new();
        for (peer, epoch) in self.peer_epoch_keys.keys() {
            by_peer.entry(peer.clone()).or_default().push(*epoch);
        }
        for (peer, mut epochs) in by_peer {
            if epochs.len() > KEEP_EPOCHS {
                epochs.sort_unstable();
                for e in &epochs[..epochs.len() - KEEP_EPOCHS] {
                    self.peer_epoch_keys.remove(&(peer.clone(), *e));
                }
            }
        }
    }
    fn current_key(&self) -> Option<[u8; 32]> {
        self.my_epoch_keys.get(&self.my_epoch).copied()
    }
    /// The epoch key to open an event authored by `author_hex` at `epoch` — mine or a stored peer's.
    fn key_for(&self, me_hex: &str, author_hex: &str, epoch: u64) -> Option<[u8; 32]> {
        if author_hex == me_hex {
            self.my_epoch_keys.get(&epoch).copied()
        } else {
            self.peer_epoch_keys.get(&(author_hex.to_string(), epoch)).copied()
        }
    }
}

struct NetState {
    /// My ACCOUNT identity: authorship, my node id, the contact id friends pin, roster signing, AND the
    /// fallback opener for older account-sealed content (dual-open).
    me: Identity,
    /// This DEVICE's identity (Option 1). `None` until the app calls `use_device_identity` (then every
    /// device on the account has a distinct transport id and opens content sealed to its own bundle, so a
    /// revoked device is cut off cryptographically). Content is dual-opened: device key first, then `me`.
    device: Option<Identity>,
    circles: Vec<Circle>,
    /// Verified multi-device rosters keyed by account node id — MINE (so my own linked devices receive
    /// content) and each contact's (so I seal to their devices, never a revoked one). Empty for any
    /// account whose devices I haven't learned yet → that member falls back to its account key, so
    /// pre-multidevice peers keep working. See `recipients_with_devices`.
    device_lists: std::collections::HashMap<[u8; 32], ContactDevices>,
    /// Viewer preference: keep MY OWN posts in the feed even when viewer auto-delete would age them
    /// out for others (my personal archive). Read by `feed`; set via `set_keep_own_posts`. Not
    /// persisted here — the app owns the toggle and re-applies it on launch.
    keep_own_posts: bool,
}

const DEFAULT_CIRCLE: &str = "default";

/// The event id a kind points at (a comment/reaction/edit/unsend/sensitive-flag target), if any.
fn event_target(kind: &EventKind) -> Option<&str> {
    match kind {
        EventKind::Comment { target, .. }
        | EventKind::Reaction { target, .. }
        | EventKind::Unreact { target, .. }
        | EventKind::Edit { target, .. }
        | EventKind::Unsend { target }
        | EventKind::SensitiveFlag { target }
        | EventKind::Report { target, .. }
        | EventKind::Vote { target, .. } => Some(target.as_str()),
        EventKind::Post { .. } | EventKind::Message { .. } | EventKind::Poll { .. } => None,
    }
}

/// Remove a member from a circle **completely** — their membership, every event they authored,
/// and (transitively) every event that targets one of those: other members' comments, reactions,
/// edits, and flags on the removed member's now-gone posts. Without the transitive sweep those
/// orphans linger in the log, so the circle is left in a fragmented state at the time of removal.
///
/// The `seen` dedup set is intentionally left intact: a still-present member could re-deliver one
/// of these orphan events, and keeping its id in `seen` makes `receive` drop it instead of
/// resurrecting the fragment.
fn purge_member_from_circle(c: &mut Circle, node_hex: &str) {
    let was_member = c.members.iter().any(|m| hex(&m.node_id_bytes()) == node_hex);
    c.members.retain(|m| hex(&m.node_id_bytes()) != node_hex);
    // Removing a member advances the circle to a fresh epoch whose key is sealed (in the next key
    // commit) only to the REMAINING members — so the removed node can never open content posted
    // afterward. This is the cryptographic revocation the audit required.
    if was_member {
        c.rotate_epoch();
    }
    let mut doomed: HashSet<String> = c
        .events
        .iter()
        .filter(|e| e.author == node_hex)
        .map(|e| e.id.clone())
        .collect();
    if doomed.is_empty() {
        return;
    }
    // Fixpoint: keep dooming events that point at an already-doomed event (a reaction on a comment
    // on their post, etc.) until nothing new is caught.
    loop {
        let before = doomed.len();
        for e in &c.events {
            if !doomed.contains(&e.id) {
                if let Some(t) = event_target(&e.kind) {
                    if doomed.contains(t) {
                        doomed.insert(e.id.clone());
                    }
                }
            }
        }
        if doomed.len() == before {
            break;
        }
    }
    c.events.retain(|e| !doomed.contains(&e.id));
}

/// Apply a received key commit: store the epoch key (if new) and unlock any buffered events.
fn receive_key_commit(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    let env = SealedEnvelope::from_bytes(body)
        .map_err(|e| HavenError::Invalid { msg: format!("bad commit: {e}") })?;
    let sender_hex = env.sender_hex();
    let me_hex = hex(&st.me.public().node_id_bytes());
    let committer = if sender_hex == me_hex {
        Some(st.me.public()) // my own re-synced commit (e.g. multi-device / backfill)
    } else if let Some(m) = st.circles[idx].members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex) {
        Some(m.clone())
    } else {
        // Or an AUTHORIZED DEVICE of a member: its credential chain was verified against the member's
        // account when the roster was ingested, so a device acting for a member is accepted here.
        authorized_device_bundle(st, idx, &sender_hex)
    };
    let Some(committer) = committer else { return Ok(false) };
    // Dual-open: try this DEVICE's key first (content sealed to my device bundle — Option 1), then fall
    // back to the ACCOUNT key (older account-sealed content, or peers who don't know my roster yet).
    let opened = match st.device.as_ref().and_then(|d| open_key_commit(d, &committer, &env).ok()) {
        Some(o) => o,
        None => match open_key_commit(&st.me, &committer, &env) {
            Ok(o) => o,
            Err(_) => return Ok(false), // not addressed to me, or I was excluded from this epoch
        },
    };
    let is_new;
    {
        let c = &mut st.circles[idx];
        if sender_hex == me_hex {
            // OWN-DEVICE convergence. `ensure_epoch` mints a RANDOM key per epoch on each device, so my
            // iPhone and Mac each generated a DIFFERENT key for the same circle+epoch. A plain `or_insert`
            // kept my stale key and refused my other device's — so I could never open my sibling's events
            // (the "my Mac never shows my iPhone's latest post / a received DM" bug: every event was
            // buffered forever). Deterministically converge on the numerically-larger key — both devices
            // pick the SAME winner independently — and count an adopted change as `new` so buffered events
            // drain and future re-seals use the agreed key. The media circle-secret converges the same way.
            let winner = match c.my_epoch_keys.get(&opened.epoch).copied() {
                Some(k) if k >= opened.epoch_key => k,
                _ => opened.epoch_key,
            };
            is_new = c.my_epoch_keys.get(&opened.epoch).copied() != Some(winner);
            c.my_epoch_keys.insert(opened.epoch, winner);
            if opened.circle_secret != [0u8; 32]
                && (c.my_circle_secret == [0u8; 32] || opened.circle_secret > c.my_circle_secret)
            {
                c.my_circle_secret = opened.circle_secret;
            }
            if opened.epoch > c.my_epoch {
                c.my_epoch = opened.epoch;
            }
        } else {
            let key = (sender_hex.clone(), opened.epoch);
            is_new = !c.peer_epoch_keys.contains_key(&key);
            c.peer_epoch_keys.entry(key).or_insert(opened.epoch_key);
            // Store the committer's stable circle secret so I can derive their opaque storage prefix.
            if opened.circle_secret != [0u8; 32] {
                c.peer_circle_secrets.insert(sender_hex.clone(), opened.circle_secret);
            }
        }
        c.prune_epoch_keys(); // bounded forward secrecy: drop stale keys
    }
    if is_new {
        drain_pending(st, idx); // a newly-learned key may unlock events that arrived early
    }
    Ok(is_new)
}

/// Apply (or buffer, if its epoch key hasn't arrived yet) an epoch-sealed event.
fn receive_epoch_event(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    let env = EpochEnvelope::from_bytes(body)
        .map_err(|e| HavenError::Invalid { msg: format!("bad epoch envelope: {e}") })?;
    let sender_hex = env.sender_hex();
    let me_hex = hex(&st.me.public().node_id_bytes());
    let sender = if sender_hex == me_hex {
        // OWN-DEVICE sync: a linked device re-broadcasts events sealed by MY OWN account (both my posts and
        // ones I RECEIVED from friends, forwarded via export_recent_envelopes). My account is NOT in the
        // circle's member list (members are contacts), so without this those forwards were dropped — which
        // is why a linked Mac never showed my latest post or a received DM. The event's INTERNAL author
        // (me or the friend) is preserved on ingest. Mirrors receive_key_commit's self-acceptance.
        Some(st.me.public())
    } else {
        match st.circles[idx]
            .members
            .iter()
            .find(|m| hex(&m.node_id_bytes()) == sender_hex)
            .cloned()
        {
            Some(m) => Some(m),
            None => authorized_device_bundle(st, idx, &sender_hex), // a member's authorized device
        }
    };
    let Some(sender) = sender else {
        // Unknown sender — most often a member's authorized device whose signed ROSTER hasn't
        // reached us yet (multi-device roster lag). Previously we DROPPED here; combined with the
        // mailbox marking the key seen at fetch time, the event was then lost forever even after we
        // learned their roster. Buffer it instead — `verify_and_store_roster`/import drains pending,
        // so once the roster arrives the event is recovered. (A genuinely-removed sender's event
        // simply never opens and ages out of the buffer.)
        let c = &mut st.circles[idx];
        if c.pending_epoch.len() < 512 && !c.pending_epoch.iter().any(|p| p == body) {
            c.pending_epoch.push(body.to_vec());
        }
        return Ok(false);
    };
    let Some(key) = st.circles[idx].key_for(&me_hex, &sender_hex, env.epoch) else {
        // Epoch key not learned yet — buffer (capped + de-duped); a later key commit unlocks it.
        let c = &mut st.circles[idx];
        if c.pending_epoch.len() < 512 && !c.pending_epoch.iter().any(|p| p == body) {
            c.pending_epoch.push(body.to_vec());
        }
        return Ok(false);
    };
    // allow_forwarded only for MY OWN self-forwards (own-device sync): a re-sealed friend event has
    // author=friend but sender=me, which the author/sender bind would otherwise reject.
    let event = match open_event_in_epoch(&sender, &key, &env, sender_hex == me_hex) {
        Ok(e) => e,
        Err(_) => return Ok(false),
    };
    let c = &mut st.circles[idx];
    if c.seen.contains(&event.id) {
        return Ok(false);
    }
    c.seen.insert(event.id.clone());
    c.events.push(event);
    Ok(true)
}

/// Legacy per-recipient envelope (read-path compatibility while older clients/posts migrate).
fn receive_legacy(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    let env = SealedEnvelope::from_bytes(body)
        .map_err(|e| HavenError::Invalid { msg: format!("bad envelope: {e}") })?;
    let sender_hex = env.sender_hex();
    let sender = st.circles[idx]
        .members
        .iter()
        .find(|m| hex(&m.node_id_bytes()) == sender_hex)
        .cloned();
    let Some(sender) = sender else { return Ok(false) };
    // Dual-open: device key (Option 1), then account key (legacy account-sealed).
    let event = match st.device.as_ref().and_then(|d| open_event(d, &sender, &env).ok()) {
        Some(e) => e,
        None => open_event(&st.me, &sender, &env)
            .map_err(|e| HavenError::Invalid { msg: format!("open failed: {e}") })?,
    };
    let c = &mut st.circles[idx];
    if c.seen.contains(&event.id) {
        return Ok(false);
    }
    c.seen.insert(event.id.clone());
    c.events.push(event);
    Ok(true)
}

/// Re-process buffered epoch events after learning a new epoch key (single pass; still-locked
/// events return to the buffer).
fn drain_pending(st: &mut NetState, idx: usize) {
    let pending = std::mem::take(&mut st.circles[idx].pending_epoch);
    for raw in pending {
        let _ = receive_epoch_event(st, idx, &raw);
    }
}

/// Drain the retry buffer of EVERY circle — called after a roster is learned (a member's newly-known
/// device can now be matched as a valid sender) and after a state import (a persisted buffer meets
/// the keys/rosters we already hold). Returns whether anything newly ingested.
fn drain_all_pending(st: &mut NetState) -> bool {
    let before: usize = st.circles.iter().map(|c| c.events.len()).sum();
    for idx in 0..st.circles.len() {
        drain_pending(st, idx);
    }
    let after: usize = st.circles.iter().map(|c| c.events.len()).sum();
    after > before
}

/// A circle summary for the UI.
#[derive(uniffi::Record)]
pub struct CircleInfoFfi {
    pub id: String,
    pub name: String,
    pub member_count: u32,
}

/// A verified profile "business card": the authoritative display name plus an optional
/// one-line bio and a link the user chose to show. Bio/link are empty for legacy peers.
#[derive(uniffi::Record)]
pub struct ProfileCardFfi {
    pub name: String,
    pub bio: String,
    pub link: String,
    /// Base64 of a small JPEG avatar (empty if none).
    pub avatar: String,
    /// The peer's chosen emoji (empty if none).
    pub emoji: String,
}

/// On-disk form, per circle, so circles/posts/contacts survive restarts and updates.
#[derive(serde::Serialize, serde::Deserialize)]
struct PersistCircle {
    id: String,
    name: String,
    /// Members as their public-bundle bytes (HavenId isn't directly Serialize).
    members: Vec<Vec<u8>>,
    events: Vec<Event>,
    /// Sender-keys epoch ratchet (defaulted so pre-epoch state files still load → bootstrap on next post).
    #[serde(default)]
    my_epoch: u64,
    #[serde(default)]
    my_epoch_keys: Vec<(u64, [u8; 32])>,
    #[serde(default)]
    peer_epoch_keys: Vec<(String, u64, [u8; 32])>,
    #[serde(default)]
    my_circle_secret: [u8; 32],
    #[serde(default)]
    peer_circle_secrets: Vec<(String, [u8; 32])>,
    /// The last sealed key commit (context hash, tagged wire bytes) — persisted so a daily backfill
    /// re-uses the SAME commit bytes across launches while the context (epoch/key/secret/recipient
    /// devices) is unchanged. Without this the KEM's randomness minted a new content-addressed
    /// mailbox entry per backfill run. Defaulted so older state files load (re-seal once).
    #[serde(default)]
    cached_commit: Option<([u8; 32], Vec<u8>)>,
    /// Epoch events received before their key commit / the sender's roster arrived. Persisted so
    /// the retry buffer SURVIVES a restart — without this, an event fetched from the mailbox (which
    /// marks its content-key seen the moment the bytes are in hand) but not yet openable was buffered
    /// only in memory; killing the app dropped the buffer, and the mailbox never re-served the key
    /// (deterministic re-seal ⇒ same key ⇒ filtered by the seen-set). That was THE cause of "a random
    /// circle member never gets a post". Now the buffer is durable and re-drained on every key-commit
    /// AND roster arrival, so late keys/rosters still unlock it. Defaulted so old state files load.
    #[serde(default)]
    pending_epoch: Vec<Vec<u8>>,
}
#[derive(serde::Serialize, serde::Deserialize)]
struct PersistState {
    circles: Vec<PersistCircle>,
    /// Verified device rosters (account_bundle, device_list_bytes, credential_bytes), so multi-device
    /// state survives restarts WITHOUT re-rotating epochs (those persist alongside in PersistCircle).
    #[serde(default)]
    device_rosters: Vec<(Vec<u8>, Vec<u8>, Vec<Vec<u8>>)>,
}
/// Legacy single-circle on-disk form — migrated into the default circle on load.
#[derive(serde::Deserialize)]
struct LegacyPersistState {
    events: Vec<Event>,
    contacts: Vec<Vec<u8>>,
}

/// The real networked social store: your identity + your contacts' public bundles +
/// the event log. Unlike `SocialDemo` it seals to your actual circle and ingests posts
/// received from contacts over the network. Transport-agnostic: the same sealed
/// envelope bytes ride iroh (internet) or MultipeerConnectivity (nearby Bluetooth/Wi-Fi).
#[derive(uniffi::Object)]
pub struct HavenSocial {
    state: Mutex<NetState>,
}

#[uniffi::export]
impl HavenSocial {
    #[uniffi::constructor]
    pub fn new(account_seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        Ok(Arc::new(Self {
            state: Mutex::new(NetState {
                me: Identity::from_seed(&seed),
                device: None,
                circles: vec![Circle::bare(DEFAULT_CIRCLE.to_string(), "My Circle".to_string())],
                device_lists: std::collections::HashMap::new(),
                keep_own_posts: false,
            }),
        }))
    }

    /// Viewer preference: keep MY OWN posts even when viewer auto-delete would drop them (personal
    /// archive). A sender-set expiry on my own post still applies. Set on launch + when the toggle flips.
    pub fn set_keep_own_posts(&self, on: bool) {
        self.state.lock().unwrap().keep_own_posts = on;
    }

    /// Adopt this DEVICE's transport/open identity (Option 1). The app passes its device-local seed
    /// (Apple: `DeviceKeyStore`); the engine then opens content sealed to this device's bundle, while the
    /// ACCOUNT identity stays the author/contact id + roster signer + fallback opener for older content.
    /// Pair with `register_device` so contacts learn to seal to this device. Idempotent.
    pub fn use_device_identity(&self, device_seed: Vec<u8>) -> bool {
        let Ok(seed): Result<[u8; 32], _> = device_seed.try_into() else { return false };
        self.state.lock().unwrap().device = Some(Identity::from_seed(&seed));
        true
    }

    /// This device's transport node id hex (its device-key id when `use_device_identity` was set, else my
    /// account id). This is what to bind the iroh node to / register in my roster / dial.
    pub fn my_device_node_hex(&self) -> String {
        let st = self.state.lock().unwrap();
        match &st.device {
            Some(d) => hex(&d.public().node_id_bytes()),
            None => hex(&st.me.public().node_id_bytes()),
        }
    }

    /// This device's public bundle (for `register_device` — the routable bundle contacts seal to).
    pub fn my_device_bundle(&self) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        match &st.device {
            Some(d) => d.public().to_bytes(),
            None => st.me.public().to_bytes(),
        }
    }

    /// All circles (id, name, member count) for the UI switcher.
    pub fn circles(&self) -> Vec<CircleInfoFfi> {
        self.state.lock().unwrap().circles.iter().map(|c| CircleInfoFfi {
            id: c.id.clone(),
            name: c.name.clone(),
            member_count: c.members.len() as u32,
        }).collect()
    }

    /// Create a circle (no-op if the id already exists).
    pub fn create_circle(&self, id: String, name: String) {
        let mut st = self.state.lock().unwrap();
        if !st.circles.iter().any(|c| c.id == id) {
            st.circles.push(Circle::bare(id, name));
        }
    }

    pub fn rename_circle(&self, id: String, name: String) {
        if let Some(c) = self.state.lock().unwrap().circles.iter_mut().find(|c| c.id == id) {
            c.name = name;
        }
    }

    /// Leave/delete a circle (you keep the default one).
    pub fn leave_circle(&self, id: String) {
        let mut st = self.state.lock().unwrap();
        st.circles.retain(|c| c.id != id || c.id == DEFAULT_CIRCLE);
    }

    /// Remove a member from ONE circle (their membership + their events there) without
    /// blocking them globally — they stay in your other circles and your default circle.
    pub fn remove_from_circle(&self, circle_id: String, node_hex: String) {
        let mut st = self.state.lock().unwrap();
        if let Some(c) = st.circles.iter_mut().find(|c| c.id == circle_id) {
            purge_member_from_circle(c, &node_hex);
        }
    }

    /// Block a node: remove them from every circle (members + their events) so their
    /// posts vanish and they can no longer be a sealed recipient. The caller also keeps
    /// a blocklist that drops their inbound frames and prevents re-add on handshake.
    pub fn block_member(&self, node_hex: String) {
        let mut st = self.state.lock().unwrap();
        for c in st.circles.iter_mut() {
            purge_member_from_circle(c, &node_hex);
        }
    }

    /// Force a fresh epoch for a circle — periodic forward-secrecy rotation (audit C2). My next key
    /// commit seals a new key to the current members; the previous key ages out of the retained
    /// window, so wire/relay ciphertext sealed under it can't be decrypted by a future compromise.
    /// Safe to call on a schedule (e.g. daily).
    pub fn rotate_circle(&self, circle_id: String) {
        let mut st = self.state.lock().unwrap();
        if let Some(c) = st.circles.iter_mut().find(|c| c.id == circle_id) {
            c.rotate_epoch();
        }
    }

    pub fn my_node_hex(&self) -> String {
        hex(&self.state.lock().unwrap().me.public().node_id_bytes())
    }

    /// The OPAQUE storage-key prefix for `member_hex`'s blobs of `kind` ("mailbox"/"media"/"presign")
    /// in a circle (audit transport-F4). The platform storage layer uses this instead of the cleartext
    /// circle id, so a blind relay can't tell circles apart and a non-member — lacking the member's
    /// circle secret — can't name/list/fetch the blobs. Returns nil if I don't hold that member's
    /// circle secret yet (a peer's arrives in their key commit; mine is generated on demand).
    pub fn storage_prefix(&self, circle_id: String, member_hex: String, kind: String) -> Option<String> {
        let mut st = self.state.lock().unwrap();
        let me_hex = hex(&st.me.public().node_id_bytes());
        let idx = st.circles.iter().position(|c| c.id == circle_id)?;
        if member_hex == me_hex {
            st.circles[idx].ensure_epoch(); // make sure my own circle secret exists
        }
        let secret = st.circles[idx].circle_secret_for(&me_hex, &member_hex)?;
        Some(mailbox_prefix(&secret, &circle_id, &kind))
    }

    /// Our public bundle to send in the handshake (Hello). Contains the keys a contact
    /// needs to seal posts *to* us — which the reach-me link/QR does not carry.
    pub fn my_bundle(&self) -> Vec<u8> {
        self.state.lock().unwrap().me.public().to_bytes()
    }

    pub fn verification_hex(&self) -> String {
        hex(&self.state.lock().unwrap().me.public().verification())
    }

    /// BLAKE3 verification hex of a received bundle — check it against the link's hash
    /// before trusting it (MITM guard).
    pub fn bundle_verification_hex(&self, bundle: Vec<u8>) -> Result<String, HavenError> {
        let id = HavenId::from_bytes(&bundle)
            .map_err(|e| HavenError::Invalid { msg: format!("bad bundle: {e}") })?;
        Ok(hex(&id.verification()))
    }

    /// A signed "business card": your chosen name + an optional one-line bio + an optional
    /// link, signed by your identity key so contacts display what **you** chose (a relay
    /// can't tamper). Layout: [u32 sig_len][hybrid signature][payload utf8], where the
    /// signed payload is JSON `{"n":name,"b":bio,"l":link}`. A name-only legacy blob (raw
    /// name after the signature, not JSON) is still accepted by the verifiers below.
    pub fn my_signed_profile(&self, name: String, bio: String, link: String, avatar: String, emoji: String) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let payload = serde_json::json!({ "n": name, "b": bio, "l": link, "a": avatar, "e": emoji }).to_string();
        // Domain-separate so a profile signature can never be confused with another signed object
        // (audit H3). The tag is part of the SIGNED bytes; the wire blob still carries only `payload`.
        let sig = st.me.sign(&profile_signing_bytes(payload.as_bytes()));
        let mut out = (sig.len() as u32).to_le_bytes().to_vec();
        out.extend_from_slice(&sig);
        out.extend_from_slice(payload.as_bytes());
        out
    }

    /// Verify a contact's signed profile and return the authoritative **name** only (for
    /// callers that just need the display name). Accepts both the JSON card and the legacy
    /// name-only blob.
    pub fn verify_profile(&self, bundle: Vec<u8>, blob: Vec<u8>) -> Option<String> {
        self.verify_profile_card(bundle, blob).map(|c| c.name)
    }

    /// Verify a contact's signed business card against their bundle. Returns name/bio/link
    /// only if the hybrid signature checks out. A legacy name-only blob yields the name with
    /// empty bio/link.
    pub fn verify_profile_card(&self, bundle: Vec<u8>, blob: Vec<u8>) -> Option<ProfileCardFfi> {
        if blob.len() < 4 {
            return None;
        }
        let sig_len = u32::from_le_bytes([blob[0], blob[1], blob[2], blob[3]]) as usize;
        if blob.len() < 4 + sig_len {
            return None;
        }
        let sig = &blob[4..4 + sig_len];
        let payload = &blob[4 + sig_len..];
        let id = HavenId::from_bytes(&bundle).ok()?;
        // Verify the domain-separated signature; fall back to the legacy untagged form so cards
        // signed by older builds still validate during rollout.
        id.verify(&profile_signing_bytes(payload), sig)
            .or_else(|_| id.verify(payload, sig))
            .ok()?;
        let text = String::from_utf8(payload.to_vec()).ok()?;
        // New card is JSON; anything else is a legacy name-only profile.
        match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(v) if v.get("n").is_some() => Some(ProfileCardFfi {
                name: v.get("n").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                bio: v.get("b").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                link: v.get("l").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                avatar: v.get("a").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                emoji: v.get("e").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            }),
            _ => Some(ProfileCardFfi { name: text, bio: String::new(), link: String::new(), avatar: String::new(), emoji: String::new() }),
        }
    }

    /// Add a contact's verified public bundle to a circle. Returns their node id hex.
    pub fn add_contact_bundle(&self, circle_id: String, bundle: Vec<u8>) -> Result<String, HavenError> {
        let id = HavenId::from_bytes(&bundle)
            .map_err(|e| HavenError::Invalid { msg: format!("bad bundle: {e}") })?;
        let node_hex = hex(&id.node_id_bytes());
        let mut st = self.state.lock().unwrap();
        let circle = st
            .circles
            .iter_mut()
            .find(|c| c.id == circle_id)
            .ok_or_else(|| HavenError::Invalid { msg: "unknown circle".into() })?;
        if !circle.members.iter().any(|c| c.node_id_bytes() == id.node_id_bytes()) {
            circle.members.push(id);
        }
        Ok(node_hex)
    }

    /// Add an already-known contact (bundle held in some circle) to another circle —
    /// for composing a new circle out of your existing contacts.
    pub fn add_existing_to_circle(&self, circle_id: String, node_hex: String) -> Result<(), HavenError> {
        let mut st = self.state.lock().unwrap();
        let bundle = st
            .circles
            .iter()
            .flat_map(|c| c.members.iter())
            .find(|m| hex(&m.node_id_bytes()) == node_hex)
            .cloned()
            .ok_or_else(|| HavenError::Invalid { msg: "unknown contact".into() })?;
        let circle = st
            .circles
            .iter_mut()
            .find(|c| c.id == circle_id)
            .ok_or_else(|| HavenError::Invalid { msg: "unknown circle".into() })?;
        if !circle.members.iter().any(|m| m.node_id_bytes() == bundle.node_id_bytes()) {
            circle.members.push(bundle);
        }
        Ok(())
    }

    /// Node ids of the members of a circle (who to broadcast that circle's posts to).
    pub fn contact_node_ids(&self, circle_id: String) -> Vec<String> {
        self.state
            .lock()
            .unwrap()
            .circles
            .iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.members.iter().map(|m| hex(&m.node_id_bytes())).collect())
            .unwrap_or_default()
    }

    /// Like `contact_node_ids`, but expanded to each member's currently-AUTHORIZED **device** ids (from
    /// their signed roster), so a post is delivered to whichever of a contact's devices is online — not a
    /// single shared account node id (which two of their devices would both answer to, breaking discovery).
    /// Members whose roster we haven't learned yet fall back to their account id (pre-multidevice peers
    /// keep working). De-duplicated; this is the transport dial set, distinct from the sealing set.
    pub fn contact_device_node_ids(&self, circle_id: String) -> Vec<String> {
        let st = self.state.lock().unwrap();
        let Some(c) = st.circles.iter().find(|c| c.id == circle_id) else { return vec![] };
        let members: Vec<HavenId> = c.members.clone();
        recipients_with_devices(&members, &st.device_lists)
            .iter()
            .map(|h| hex(&h.node_id_bytes()))
            .collect()
    }

    /// The transport node ids to DIAL to reach ONE account: that account's currently-authorized device ids
    /// (from its roster), or — if we haven't learned its roster — the account id itself (pre-multidevice
    /// fallback). Lets a sender keep its social/allow logic on account ids and expand to devices only at the
    /// transport edge. Always includes the account id too, so an un-upgraded peer still on its account node
    /// stays reachable during the rollout. De-duplicated.
    pub fn device_node_ids_for(&self, account_hex: String) -> Vec<String> {
        let acct = account_hex.to_lowercase();
        let st = self.state.lock().unwrap();
        for (id, cd) in st.device_lists.iter() {
            if hex(id) == acct {
                let mut ids: Vec<String> =
                    cd.authorized_bundles().iter().map(|b| hex(&b.node_id_bytes())).collect();
                // Keep the account id in the dial set too. Dropping it (the regression) stranded any peer
                // still on its pre-multidevice account node, and — worse — a freshly-linked device that has
                // only PARTIALLY learned a contact's roster. A dead account id only costs a connect timeout;
                // omitting it can mean total unreachability.
                if !ids.iter().any(|i| *i == acct) {
                    ids.push(acct);
                }
                return ids;
            }
        }
        // No roster known → the contact is still on its account node (pre-multidevice). Dial that.
        vec![acct]
    }

    /// Export every CONTACT device roster I currently hold, each as tagged wire + the contact's account
    /// hex. My OTHER devices fold these into self-sync so a freshly-linked device learns which device ids
    /// to dial/seal for each friend WITHOUT first having to reach that friend itself — the bootstrap gap
    /// that left a linked Mac dialing dead account ids and timing out. Excludes my own roster.
    pub fn export_contact_rosters(&self) -> Vec<ContactRosterWire> {
        let st = self.state.lock().unwrap();
        let my_id = st.me.public().node_id_bytes();
        // Recover each contact's full account bundle (needed to wire-encode their roster) from circle members.
        let mut bundles: HashMap<[u8; 32], HavenId> = HashMap::new();
        for c in st.circles.iter() {
            for m in c.members.iter() {
                bundles.insert(m.node_id_bytes(), m.clone());
            }
        }
        let mut out = Vec::new();
        for (acct_id, cd) in st.device_lists.iter() {
            if *acct_id == my_id {
                continue;
            }
            if let Some(acct_pub) = bundles.get(acct_id) {
                out.push(ContactRosterWire {
                    account_hex: hex(acct_id),
                    wire: tagged(TAG_DEVICE_ROSTER, &encode_roster(acct_pub, cd)),
                });
            }
        }
        out
    }

    /// My OWN device roster, wire-encoded for self-sync — the fix for the own-device "bootstrap
    /// deadlock". Two of my devices that are never nearby and share no relay never learned each
    /// other's DEVICE id, because a device connects to a relay AS its device id and a relay only
    /// authorizes device ids it already holds in `device_lists[myAccount]`; the account id binds no
    /// endpoint, so there was no fallback and each device rejected the other with `ERR forbidden`
    /// forever (and relay-deletion tombstones, riding the same dead channel, never propagated → the
    /// deleted relay kept coming back). `export_contact_rosters` deliberately EXCLUDES my own roster,
    /// so self-sync never carried it. This does — self-sync publishes it under `roster:<myAccountHex>`
    /// and the peer ingests it via [`Self::ingest_roster_wire`], whose `acct_id == my_id` branch
    /// union-merges the sibling's device id into this device's own list → the relay then authorizes it.
    /// The `haven/self/…` self-sync slots are served permissively by any relay (incl. a headless one),
    /// so this converges over any shared relay both devices can reach — no relay change required.
    /// Returns 0 or 1 entries (empty until this device has registered itself).
    pub fn export_own_roster(&self) -> Vec<ContactRosterWire> {
        let st = self.state.lock().unwrap();
        let me_pub = st.me.public();
        let my_id = me_pub.node_id_bytes();
        match st.device_lists.get(&my_id) {
            Some(cd) => vec![ContactRosterWire {
                account_hex: hex(&my_id),
                wire: tagged(TAG_DEVICE_ROSTER, &encode_roster(&me_pub, cd)),
            }],
            None => Vec::new(),
        }
    }

    /// Ingest a contact's device roster from tagged wire (what `export_contact_rosters` produces). Same
    /// verification as `receive`'s TAG_DEVICE_ROSTER path, but account-level so no circle context is needed.
    /// Verified against the account bundle carried in the wire; false on a forged / stale (rolled-back) roster.
    pub fn ingest_roster_wire(&self, wire: Vec<u8>) -> bool {
        if wire.first() != Some(&TAG_DEVICE_ROSTER) {
            return false;
        }
        let mut st = self.state.lock().unwrap();
        match decode_roster(&wire[1..]).and_then(|(acct, list, creds)| {
            HavenId::from_bytes(&acct).ok().map(|a| (a, list, creds))
        }) {
            Some((account, list, creds)) => verify_and_store_roster(&mut st, &account, &list, &creds),
            None => false,
        }
    }

    /// The full public **bundles** of a circle's members — for multi-device sync. Another of the
    /// user's devices replays these through [`add_contact_bundle`] to reconstruct the circle and
    /// seal to every member. Bundles are public keys; replicating them (sealed to the user's own
    /// devices) leaks nothing.
    pub fn circle_member_bundles(&self, circle_id: String) -> Vec<Vec<u8>> {
        self.state
            .lock()
            .unwrap()
            .circles
            .iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.members.iter().map(|m| m.to_bytes()).collect())
            .unwrap_or_default()
    }

    pub fn post(
        &self,
        circle_id: String,
        body: String,
        media: Vec<String>,
        music: Option<TrackRefFfi>,
        retention_secs: Option<u64>,
        story: bool,
        mute_video: bool,
        created_at: u64,
    ) -> Result<Vec<u8>, HavenError> {
        let music = music.map(|m| m.into_core());
        self.author(&circle_id, created_at, EventKind::Post { body, media, music, retention_secs, story, mute_video })
    }
    pub fn comment(&self, circle_id: String, target: String, body: String, media: Vec<String>, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Comment { target, body, media })
    }
    pub fn react(&self, circle_id: String, target: String, emoji: String, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Reaction { target, emoji })
    }
    pub fn unreact(&self, circle_id: String, target: String, emoji: String, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Unreact { target, emoji })
    }
    /// Create a poll: a question + options, optionally auto-closing at `close_at_ms` (0 = never).
    pub fn create_poll(&self, circle_id: String, question: String, options: Vec<String>, close_at_ms: u64, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Poll { question, options, close_at_ms })
    }
    /// Vote for option `option` of poll `target` (changeable until it closes; latest wins).
    pub fn vote(&self, circle_id: String, target: String, option: u32, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Vote { target, option })
    }
    /// Flag a media content-ref as sensitive for the whole circle (e.g. on-device SCA flagged it).
    /// Returns the sealed envelope to broadcast; once any member flags a ref, every client blurs it.
    pub fn flag_sensitive(&self, circle_id: String, target: String, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::SensitiveFlag { target })
    }
    /// Media content-refs flagged sensitive in this circle's event log (by any member). The viewer
    /// blurs these regardless of whether their own platform has Sensitive Content Analysis.
    pub fn sensitive_refs(&self, circle_id: String) -> Vec<String> {
        let st = self.state.lock().unwrap();
        let Some(c) = st.circles.iter().find(|c| c.id == circle_id) else { return vec![] };
        let mut out: Vec<String> = c.events.iter().filter_map(|e| {
            if let EventKind::SensitiveFlag { target } = &e.kind { Some(target.clone()) } else { None }
        }).collect();
        out.sort();
        out.dedup();
        out
    }
    /// File a report against event `target` (objectionable content / abuse). The reported author's
    /// FULL node hex is resolved from the local event log and embedded in the report, then the
    /// report is sealed + broadcast to the whole circle like any event — every member sees it and
    /// acts with the power they already hold (hide, remove-from-circle, block). Returns the
    /// envelope to broadcast.
    pub fn report(&self, circle_id: String, target: String, reason: String, comment: String, created_at: u64) -> Result<Vec<u8>, HavenError> {
        let author = {
            let st = self.state.lock().unwrap();
            let Some(c) = st.circles.iter().find(|c| c.id == circle_id) else {
                return Err(HavenError::Invalid { msg: "unknown circle".into() });
            };
            match c.events.iter().find(|e| e.id == target) {
                Some(e) => e.author.clone(),
                None => return Err(HavenError::Invalid { msg: "unknown target event".into() }),
            }
        };
        self.author(&circle_id, created_at, EventKind::Report { target, author, reason, comment })
    }

    /// Every report filed in this circle (by any member), in event-log order.
    pub fn reports(&self, circle_id: String) -> Vec<ReportFfi> {
        let st = self.state.lock().unwrap();
        let Some(c) = st.circles.iter().find(|c| c.id == circle_id) else { return vec![] };
        c.events
            .iter()
            .filter_map(|e| {
                if let EventKind::Report { target, author, reason, comment } = &e.kind {
                    Some(ReportFfi {
                        id: e.id.clone(),
                        reporter: e.author.clone(),
                        reporter_short: short(&e.author),
                        target: target.clone(),
                        author: author.clone(),
                        reason: reason.clone(),
                        comment: comment.clone(),
                        created_at: e.created_at,
                    })
                } else {
                    None
                }
            })
            .collect()
    }

    pub fn edit(&self, circle_id: String, target: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>, mute_video: bool, created_at: u64) -> Result<Vec<u8>, HavenError> {
        let music = music.map(|m| m.into_core());
        self.author(&circle_id, created_at, EventKind::Edit { target, body, media, music, mute_video })
    }
    pub fn unsend(&self, circle_id: String, target: String, created_at: u64) -> Result<Vec<u8>, HavenError> {
        self.author(&circle_id, created_at, EventKind::Unsend { target })
    }

    /// Re-seal every event *I* authored in a circle into mailbox envelopes. Used to BACKFILL a
    /// mailbox set up after I'd already posted: the relay/S3 mailbox never saw those posts, so a
    /// member who wasn't online when I sent them can't fetch them. The app uploads each envelope
    /// to the new mailbox; envelopes are content-addressed, so re-uploading is idempotent.
    pub fn export_my_envelopes(&self, circle_id: String) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle(&circle_id)
    }

    // ---- Multi-device (D16/Phase 4): seal circles to authorized devices, revoke by dropping one ----

    /// Record THIS account's own signed device roster (my linked devices) so my circles' key commits
    /// seal to all of them. Verified against my own account key; rotates my epochs so it takes effect.
    pub fn set_my_device_roster(&self, list: Vec<u8>, credentials: Vec<Vec<u8>>) -> bool {
        let mut st = self.state.lock().unwrap();
        let me_pub = st.me.public();
        verify_and_store_roster(&mut st, &me_pub, &list, &credentials)
    }

    /// Record a CONTACT's signed device roster (verified against their pinned account bundle) so I seal
    /// to their devices and honor revocations. False on a forged / stale (rolled-back) roster.
    pub fn ingest_device_roster(&self, account_bundle: Vec<u8>, list: Vec<u8>, credentials: Vec<Vec<u8>>) -> bool {
        let Ok(account) = HavenId::from_bytes(&account_bundle) else { return false };
        let mut st = self.state.lock().unwrap();
        verify_and_store_roster(&mut st, &account, &list, &credentials)
    }

    /// My own device roster, wire-encoded for sharing with contacts (rides the sync bundle so peers
    /// learn which of my devices to seal to). Empty if I haven't enrolled any devices yet.
    pub fn my_device_roster_wire(&self) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let me_pub = st.me.public();
        match st.device_lists.get(&me_pub.node_id_bytes()) {
            Some(cd) => tagged(TAG_DEVICE_ROSTER, &encode_roster(&me_pub, cd)),
            None => vec![],
        }
    }

    /// Self-register THIS device (its routable bundle) into my own signed roster so contacts learn to dial
    /// + seal to it. Each device calls this on launch with its own bundle (`my_device_bundle`). Issues an
    /// account-signed credential, UNIONS its id into my `DeviceList` (re-signing with my account key — so
    /// several iCloud-restored devices each accumulate rather than clobber), and returns my roster wire to
    /// broadcast to contacts. Idempotent: a no-op when already present, but still returns the current wire
    /// so the caller can (re)publish. Empty only if the bundle is invalid.
    pub fn register_device(&self, device_bundle: Vec<u8>, name: String, created_at: u64) -> Vec<u8> {
        let Ok(device) = HavenId::from_bytes(&device_bundle) else { return vec![] };
        let mut st = self.state.lock().unwrap();
        let me_pub = st.me.public();
        let acct_id = me_pub.node_id_bytes();
        let dev_id = device.node_id_bytes();
        let base = st.device_lists.get(&acct_id).map(|cd| cd.list.clone());
        let updated = match &base {
            Some(b) => b.with_self_added(dev_id, &st.me, created_at),
            None => Some(DeviceList::signed(&st.me, 1, created_at, vec![dev_id], vec![])),
        };
        if let Some(new_list) = updated {
            let mut creds =
                st.device_lists.get(&acct_id).map(|cd| cd.credentials.clone()).unwrap_or_default();
            if !creds.iter().any(|c| c.device_id() == dev_id) {
                creds.push(DeviceCredential::issue(&st.me, &device, &name, created_at));
            }
            st.device_lists.insert(acct_id, ContactDevices { list: new_list, credentials: creds });
            for c in st.circles.iter_mut() {
                c.rotate_epoch();
            }
        }
        let me_pub = st.me.public();
        match st.device_lists.get(&acct_id) {
            Some(cd) => tagged(TAG_DEVICE_ROSTER, &encode_roster(&me_pub, cd)),
            None => vec![],
        }
    }

    /// Everything a freshly-synced peer (or the relay mailbox) needs to read my contributions to a
    /// circle: the current epoch **key commit** (so they can open my epoch events) followed by my own
    /// events re-sealed under that epoch. Tagged for `receive`'s router. This is the *only* transport
    /// the key commits need — they ride the same sync/backfill path as events, so no platform
    /// networking change is required.
    fn epoch_sync_bundle(&self, circle_id: &str) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle_impl(circle_id, true, 0)
    }

    /// `mine_only=false` re-seals EVERY member's events (not just mine) — for OWN-DEVICE sync, so a linked
    /// device gets the posts/DMs I RECEIVED from friends too, which sync_envelopes (mine-only) never sent.
    /// Re-sealing under my epoch preserves each event's own author + signature (the epoch seal is symmetric,
    /// not per-author), so a forwarded friend event still verifies + displays as theirs. `limit` caps to the
    /// most recent N events so this stays cheap when called periodically.
    fn epoch_sync_bundle_impl(&self, circle_id: &str, mine_only: bool, limit: u32) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle_inner(circle_id, mine_only, limit, false)
    }

    fn epoch_sync_bundle_inner(&self, circle_id: &str, mine_only: bool, limit: u32, head_only: bool) -> Vec<Vec<u8>> {
        let mut st = self.state.lock().unwrap();
        let me_hex = hex(&st.me.public().node_id_bytes());
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return vec![] };
        st.circles[idx].ensure_epoch();
        let epoch = st.circles[idx].my_epoch;
        let Some(key) = st.circles[idx].current_key() else { return vec![] };
        let secret = st.circles[idx].my_circle_secret;
        let mut accounts = vec![st.me.public()];
        accounts.extend(st.circles[idx].members.iter().cloned());
        // Expand each account member to its AUTHORIZED devices (mine + each contact's), so the circle's
        // key commit seals to every trusted device and NEVER a revoked one. Members whose device roster
        // we haven't learned fall back to their account key — pre-multidevice peers keep working.
        let members = recipients_with_devices(&accounts, &st.device_lists);
        let mut out: Vec<Vec<u8>> = Vec::new();
        // Share my OWN device roster so peers seal their content to all my devices (and never a revoked
        // one). Idempotent: a same-version roster is ignored on the receiver, so this can't rotation-storm.
        let me_pub = st.me.public();
        if let Some(cd) = st.device_lists.get(&me_pub.node_id_bytes()) {
            out.push(tagged(TAG_DEVICE_ROSTER, &encode_roster(&me_pub, cd)));
        }
        // Key commit: the hybrid KEM is random, so a re-seal for the SAME context yields new bytes
        // and the content-addressed mailbox would accumulate a copy per backfill. Reuse the cached
        // sealed commit while (epoch, key, secret, recipient devices) are unchanged.
        let commit_ctx: [u8; 32] = {
            let mut h = blake3::Hasher::new();
            h.update(b"haven-commit-ctx-v1");
            h.update(&epoch.to_le_bytes());
            h.update(&key);
            h.update(&secret);
            let mut ids: Vec<[u8; 32]> = members.iter().map(|m| m.node_id_bytes()).collect();
            ids.sort_unstable();
            for id in &ids {
                h.update(id);
            }
            *h.finalize().as_bytes()
        };
        match &st.circles[idx].cached_commit {
            Some((ctx, bytes)) if *ctx == commit_ctx => out.push(bytes.clone()),
            _ => {
                if let Ok(commit) = seal_key_commit(&st.me, &members, circle_id, epoch, &key, &secret) {
                    let bytes = tagged(TAG_KEY_COMMIT, &commit.to_bytes());
                    st.circles[idx].cached_commit = Some((commit_ctx, bytes.clone()));
                    out.push(bytes);
                }
            }
        }
        if head_only {
            return out; // roster + current key commit only — no event re-seals
        }
        let mut events: Vec<Event> = st.circles[idx]
            .events
            .iter()
            .filter(|e| !mine_only || e.author == me_hex)
            .cloned()
            .collect();
        if limit > 0 {
            let n = limit as usize;
            if events.len() > n {
                events = events.split_off(events.len() - n); // keep the most recent N
            }
        }
        for e in &events {
            if let Ok(env) = seal_event_in_epoch(&st.me, circle_id, epoch, &key, e) {
                out.push(tagged(TAG_EPOCH_EVENT, &env.to_bytes()));
            }
        }
        out
    }

    /// Recent events from EVERY member of a circle (mine + received), re-sealed under my epoch, capped to
    /// `limit` — for own-device catch-up over nearby (a sibling gets friends' posts/DMs I received, not just
    /// my own). NOT for sending to friends (that stays mine-only via sync_envelopes).
    pub fn export_recent_envelopes(&self, circle_id: String, limit: u32) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle_impl(&circle_id, false, limit)
    }

    /// Just the epoch HEAD — my device roster + the current key commit, NO event re-seals. Cheap
    /// (the commit is cached until the epoch/recipient set changes) and idempotent to receive.
    /// Upload this alongside every posted event: with the full-history backfill throttled to daily,
    /// a relay-only peer could otherwise receive an event sealed under a fresh epoch long before the
    /// commit that opens it arrives (the event would sit in `pending_epoch` until the next backfill).
    pub fn export_epoch_head(&self, circle_id: String) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle_inner(&circle_id, true, 0, true)
    }

    /// Ingest a sealed envelope received from the network. Routes by wire tag: a key commit (stores
    /// the circle epoch key, then unlocks any buffered events), an epoch-sealed event, or a legacy
    /// per-recipient envelope (read-path compatibility during migration). Returns true if it changed
    /// state (a new event, or a newly-learned epoch key).
    pub fn receive(&self, circle_id: String, envelope: Vec<u8>) -> Result<bool, HavenError> {
        if envelope.is_empty() {
            return Ok(false);
        }
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return Ok(false) };
        match envelope[0] {
            TAG_KEY_COMMIT => receive_key_commit(&mut st, idx, &envelope[1..]),
            TAG_EPOCH_EVENT => receive_epoch_event(&mut st, idx, &envelope[1..]),
            TAG_DEVICE_ROSTER => {
                // Account-level (not circle-specific) — verify against the carried account bundle, store,
                // and rotate affected epochs. Forged/stale rosters are rejected inside the verifier.
                match decode_roster(&envelope[1..]).and_then(|(acct, list, creds)| {
                    HavenId::from_bytes(&acct).ok().map(|a| (a, list, creds))
                }) {
                    Some((account, list, creds)) => {
                        let stored = verify_and_store_roster(&mut st, &account, &list, &creds);
                        // A newly-learned roster may make a previously "unknown sender" event openable —
                        // drain the durable buffer so multi-device roster lag no longer loses posts.
                        let drained = drain_all_pending(&mut st);
                        Ok(stored || drained)
                    }
                    None => Ok(false),
                }
            }
            _ => receive_legacy(&mut st, idx, &envelope), // untagged JSON `{…}` = legacy envelope
        }
    }

    /// Re-seal everything **I** authored to a circle — to sync a peer that just
    /// connected. Only my own events (relaying others' would forge authorship).
    pub fn sync_envelopes(&self, circle_id: String) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle(&circle_id)
    }

    pub fn feed(&self, circle_id: String, now_ms: u64, viewer_retention_secs: Option<u64>) -> Vec<FeedItemFfi> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me.public().node_id_bytes());
        let keep_own = st.keep_own_posts;
        let events = st
            .circles
            .iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.events.clone())
            .unwrap_or_default();
        map_feed(events, &me, now_ms, viewer_retention_secs, keep_own)
    }

    /// Seal a media blob to one contact (hybrid KEM → AES-256-GCM). The recipient
    /// opens it with `open_media`. Layout: [32 eph_x_pub][u32 pq_len][pq_ct][ciphertext].
    pub fn seal_media(&self, recipient_node_hex: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let st = self.state.lock().unwrap();
        // OWN account is a valid recipient — own-device media sync (a linked Mac/phone) seals media to the
        // account so any of the user's own devices (sharing the seed) can open it. The member-list lookup
        // alone failed here, since you aren't a member of your own circle, which silently broke ALL
        // own-device media transfer (the seal threw → the chunk send loop bailed before broadcasting).
        let me_pub = st.me.public();
        let recipient: HavenId = if hex(&me_pub.node_id_bytes()) == recipient_node_hex {
            me_pub
        } else {
            st.circles
                .iter()
                .flat_map(|c| c.members.iter())
                .find(|m| hex(&m.node_id_bytes()) == recipient_node_hex)
                .cloned()
                .ok_or_else(|| HavenError::Invalid { msg: "unknown recipient".into() })?
        };
        let (enc, key) =
            encapsulate_to(&recipient).map_err(|e| HavenError::Invalid { msg: format!("{e}") })?;
        let ct = seal(&key, &data);
        let mut out = Vec::with_capacity(36 + enc.pq_ct.len() + ct.len());
        out.extend_from_slice(&enc.eph_x_pub);
        out.extend_from_slice(&(enc.pq_ct.len() as u32).to_le_bytes());
        out.extend_from_slice(&enc.pq_ct);
        out.extend_from_slice(&ct);
        Ok(out)
    }

    /// Seal a push notification payload to a recipient AND sign it, so the recipient's NSE can prove
    /// who sent it (audit H2 — defeats the "anyone with my public key forges an alert" spoof). Used
    /// only for the small notification payload, NOT for media chunks (which would balloon with a
    /// per-chunk signature). Layout: [u32 bundle_len][sender bundle][u32 sig_len][sig][seal_media].
    pub fn seal_signed_notification(&self, recipient_node_hex: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let sealed = self.seal_media(recipient_node_hex.clone(), data.clone())?;
        let st = self.state.lock().unwrap();
        let bundle = st.me.public().to_bytes();
        let sig = st.me.sign(&notif_signing_bytes(&recipient_node_hex, &data));
        let mut out = Vec::with_capacity(8 + bundle.len() + sig.len() + sealed.len());
        out.extend_from_slice(&(bundle.len() as u32).to_le_bytes());
        out.extend_from_slice(&bundle);
        out.extend_from_slice(&(sig.len() as u32).to_le_bytes());
        out.extend_from_slice(&sig);
        out.extend_from_slice(&sealed);
        Ok(out)
    }

    /// Open a media blob sealed to us by a contact. Returns the plaintext bytes.
    pub fn open_media(&self, sealed: Vec<u8>) -> Option<Vec<u8>> {
        if sealed.len() < 36 {
            return None;
        }
        let eph_x_pub: [u8; 32] = sealed[0..32].try_into().ok()?;
        let pq_len = u32::from_le_bytes(sealed[32..36].try_into().ok()?) as usize;
        if sealed.len() < 36 + pq_len {
            return None;
        }
        let pq_ct = sealed[36..36 + pq_len].to_vec();
        let ct = &sealed[36 + pq_len..];
        let enc = Encapsulation { eph_x_pub, pq_ct };
        let st = self.state.lock().unwrap();
        // Dual-open: device key (Option 1), then account key (legacy account-sealed media).
        let key = st.device.as_ref().and_then(|d| decapsulate(d, &enc).ok())
            .or_else(|| decapsulate(&st.me, &enc).ok())?;
        open(&key, ct).ok()
    }

    /// Seal a media blob to the WHOLE circle (any member can open it). The shared
    /// store host stores the result opaquely — it can't read it. Returns the sealed
    /// envelope bytes to upload.
    pub fn seal_circle_media(&self, circle_id: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let st = self.state.lock().unwrap();
        let Some(circle) = st.circles.iter().find(|c| c.id == circle_id) else {
            return Err(HavenError::Invalid { msg: "unknown circle".into() });
        };
        let mut members = vec![st.me.public()];
        members.extend(circle.members.iter().cloned());
        let group = Group::new(circle_id, members);
        seal_bytes(&st.me, &group, &data)
            .map(|env| env.to_bytes())
            .map_err(|e| HavenError::Invalid { msg: format!("{e}") })
    }

    /// Seal a media blob from a FILE to another FILE, entirely in NATIVE (off-heap) memory —
    /// symmetric to [`Self::open_circle_media_file`]. A large video (hundreds of MB) sealed via the
    /// in-memory [`Self::seal_circle_media`] forces the whole plaintext AND the whole sealed envelope
    /// through the caller's managed heap as one contiguous buffer; on iOS that single Swift `Data`
    /// allocation TRAPS (EXC_BREAKPOINT in `__DataStorage.init`) once it can't be satisfied, crashing
    /// the app the moment a big video is posted. Reading + sealing + writing here keeps every large
    /// buffer in native memory (bounded by physical RAM, not the small managed heap), and the caller
    /// then streams the sealed FILE to the mailbox in fixed windows — never holding it whole. Returns
    /// whether it succeeded; writes atomically via a `.part` rename.
    pub fn seal_circle_media_file(&self, circle_id: String, in_path: String, out_path: String) -> bool {
        let Ok(data) = std::fs::read(&in_path) else { return false };
        let sealed: Option<Vec<u8>> = (|| {
            let st = self.state.lock().unwrap();
            let circle = st.circles.iter().find(|c| c.id == circle_id)?;
            let mut members = vec![st.me.public()];
            members.extend(circle.members.iter().cloned());
            let group = Group::new(circle_id.clone(), members);
            seal_bytes(&st.me, &group, &data).ok().map(|env| env.to_bytes())
        })();
        drop(data); // free the plaintext before allocating no further large buffers
        let Some(sealed) = sealed else { return false };
        let tmp = format!("{out_path}.part");
        let ok = std::fs::write(&tmp, &sealed)
            .and_then(|_| std::fs::rename(&tmp, &out_path))
            .is_ok();
        if !ok {
            let _ = std::fs::remove_file(&tmp);
        }
        ok
    }

    /// Open a circle-sealed media blob fetched from the shared store. Verifies the
    /// sender (read from the envelope) against the circle roster.
    pub fn open_circle_media(&self, circle_id: String, sealed: Vec<u8>) -> Option<Vec<u8>> {
        let st = self.state.lock().unwrap();
        let env = SealedEnvelope::from_bytes(&sealed).ok()?;
        let sender_hex = env.sender_hex();
        let me_hex = hex(&st.me.public().node_id_bytes());
        let circle = st.circles.iter().find(|c| c.id == circle_id)?;
        let sender_pub = if sender_hex == me_hex {
            st.me.public()
        } else {
            circle.members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex)?.clone()
        };
        // Dual-open: device key (Option 1), then account key (legacy account-sealed media).
        st.device.as_ref().and_then(|d| open_bytes(d, &sender_pub, &env).ok())
            .or_else(|| open_bytes(&st.me, &sender_pub, &env).ok())
    }

    /// [`Self::open_circle_media`] that ALSO returns who sealed the blob (the envelope's verified
    /// sender, a circle member's account id hex). Callers that must make a trust decision about the
    /// announcement itself — e.g. "only the relay's OWNER may reactivate a deactivated relay" — need
    /// the authenticated sender, not just the plaintext.
    pub fn open_circle_media_sender(&self, circle_id: String, sealed: Vec<u8>) -> Option<OpenedCircleBlobFfi> {
        let sender_hex = SealedEnvelope::from_bytes(&sealed).ok()?.sender_hex();
        let data = self.open_circle_media(circle_id, sealed)?;
        Some(OpenedCircleBlobFfi { sender_hex, data })
    }

    /// Decrypt a circle-sealed media blob from a FILE and write the plaintext to another FILE, doing
    /// the whole decryption in NATIVE memory. A large video (hundreds of MB) sealed to the circle
    /// would OOM a phone's small managed heap (Android's ART heap is capped ~512 MB) if it went
    /// through `open_circle_media` as a byte array — but the sealed blob + plaintext live here in
    /// native (off-heap) memory, which is bound only by the device's physical RAM, so the video
    /// decrypts and a player can then stream it from `out_path`. Returns whether it succeeded.
    /// Tries `circle_id` first; on failure tries every known circle (media may be tagged to another).
    pub fn open_circle_media_file(&self, circle_id: String, sealed_path: String, out_path: String) -> bool {
        let Ok(sealed) = std::fs::read(&sealed_path) else { return false };
        let plaintext: Option<Vec<u8>> = (|| {
            let st = self.state.lock().unwrap();
            let env = SealedEnvelope::from_bytes(&sealed).ok()?;
            let sender_hex = env.sender_hex();
            let me_hex = hex(&st.me.public().node_id_bytes());
            // The circle the media is tagged to (passed) first, then any other circle we're in.
            let ordered = std::iter::once(circle_id.as_str())
                .chain(st.circles.iter().map(|c| c.id.as_str()).filter(|id| *id != circle_id));
            for cid in ordered {
                let Some(circle) = st.circles.iter().find(|c| c.id == cid) else { continue };
                let sender_pub = if sender_hex == me_hex {
                    st.me.public()
                } else {
                    match circle.members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex) {
                        Some(m) => m.clone(),
                        None => continue,
                    }
                };
                if let Some(p) = st.device.as_ref().and_then(|d| open_bytes(d, &sender_pub, &env).ok())
                    .or_else(|| open_bytes(&st.me, &sender_pub, &env).ok())
                {
                    return Some(p);
                }
            }
            None
        })();
        drop(sealed); // free the sealed bytes before writing the (equally large) plaintext
        let Some(plaintext) = plaintext else { return false };
        let tmp = format!("{out_path}.part");
        let ok = std::fs::write(&tmp, &plaintext)
            .and_then(|_| std::fs::rename(&tmp, &out_path))
            .is_ok();
        if !ok {
            let _ = std::fs::remove_file(&tmp);
        }
        ok
    }

    /// Serialize all circles (members + events) for on-disk persistence.
    pub fn export_state(&self) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let ps = PersistState {
            circles: st.circles.iter().map(|c| PersistCircle {
                id: c.id.clone(),
                name: c.name.clone(),
                members: c.members.iter().map(|m| m.to_bytes()).collect(),
                events: c.events.clone(),
                my_epoch: c.my_epoch,
                my_epoch_keys: c.my_epoch_keys.iter().map(|(e, k)| (*e, *k)).collect(),
                peer_epoch_keys: c.peer_epoch_keys.iter().map(|((a, e), k)| (a.clone(), *e, *k)).collect(),
                my_circle_secret: c.my_circle_secret,
                peer_circle_secrets: c.peer_circle_secrets.iter().map(|(a, s)| (a.clone(), *s)).collect(),
                cached_commit: c.cached_commit.clone(),
                pending_epoch: c.pending_epoch.clone(),
            }).collect(),
            device_rosters: {
                let me_id = st.me.public().node_id_bytes();
                let me_bundle = st.me.public().to_bytes();
                st.device_lists.iter().filter_map(|(acct_id, cd)| {
                    // Resolve the account's FULL bundle (needed to re-verify on import) from me or a member.
                    let account_bundle = if *acct_id == me_id {
                        me_bundle.clone()
                    } else {
                        st.circles.iter().flat_map(|c| c.members.iter())
                            .find(|m| m.node_id_bytes() == *acct_id)
                            .map(|m| m.to_bytes())?
                    };
                    Some((account_bundle, cd.list.to_bytes(), cd.credentials.iter().map(|c| c.to_bytes()).collect()))
                }).collect()
            },
        };
        serde_json::to_vec(&ps).unwrap_or_default()
    }

    /// Merge a previously-exported store back in (dedup by event id / member node id),
    /// so circles, posts, and connections survive restarts and updates. Migrates the
    /// legacy single-circle format into the default circle.
    pub fn import_state(&self, data: Vec<u8>) {
        let mut st = self.state.lock().unwrap();
        if let Ok(ps) = serde_json::from_slice::<PersistState>(&data) {
            for pc in ps.circles {
                Self::merge_circle(&mut st, pc);
            }
            // Restore device rosters AFTER circles (no epoch rotation — the restored epochs already
            // reflect them; re-verified against the carried account bundle, higher-version-wins).
            for (acct, list, creds) in ps.device_rosters {
                restore_roster(&mut st, &acct, &list, &creds);
            }
            // A restored buffer may already be openable with the keys/rosters we just loaded.
            drain_all_pending(&mut st);
        } else if let Ok(old) = serde_json::from_slice::<LegacyPersistState>(&data) {
            Self::merge_circle(&mut st, PersistCircle {
                id: DEFAULT_CIRCLE.to_string(),
                name: "My Circle".to_string(),
                members: old.contacts,
                events: old.events,
                my_epoch: 0,
                my_epoch_keys: vec![],
                peer_epoch_keys: vec![],
                my_circle_secret: [0u8; 32],
                peer_circle_secrets: vec![],
                cached_commit: None,
                pending_epoch: vec![],
            });
        }
    }
}

impl HavenSocial {
    fn merge_circle(st: &mut NetState, pc: PersistCircle) {
        let idx = match st.circles.iter().position(|c| c.id == pc.id) {
            Some(i) => i,
            None => {
                st.circles.push(Circle::bare(pc.id.clone(), pc.name.clone()));
                st.circles.len() - 1
            }
        };
        for mb in pc.members {
            if let Ok(id) = HavenId::from_bytes(&mb) {
                if !st.circles[idx].members.iter().any(|m| m.node_id_bytes() == id.node_id_bytes()) {
                    st.circles[idx].members.push(id);
                }
            }
        }
        for e in pc.events {
            if !st.circles[idx].seen.contains(&e.id) {
                st.circles[idx].seen.insert(e.id.clone());
                st.circles[idx].events.push(e);
            }
        }
        // Union epoch keys + keep the highest epoch (multi-device sync / reload must not lose any key
        // or we'd be unable to open content sealed under an epoch another device advanced to).
        for (e, k) in pc.my_epoch_keys {
            st.circles[idx].my_epoch_keys.entry(e).or_insert(k);
        }
        if pc.my_epoch > st.circles[idx].my_epoch {
            st.circles[idx].my_epoch = pc.my_epoch;
        }
        for (a, e, k) in pc.peer_epoch_keys {
            st.circles[idx].peer_epoch_keys.entry((a, e)).or_insert(k);
        }
        if pc.my_circle_secret != [0u8; 32] && st.circles[idx].my_circle_secret == [0u8; 32] {
            st.circles[idx].my_circle_secret = pc.my_circle_secret;
        }
        for (a, s) in pc.peer_circle_secrets {
            st.circles[idx].peer_circle_secrets.entry(a).or_insert(s);
        }
        // Restore the sealed-commit cache so a daily backfill reuses the same commit bytes across
        // launches (context-hash-gated: a stale one is simply ignored and re-sealed on next export).
        if st.circles[idx].cached_commit.is_none() {
            st.circles[idx].cached_commit = pc.cached_commit;
        }
        // Restore the durable retry buffer (capped + deduped). A drain runs after this whole import
        // (import_state → drain_all_pending) so any key/roster we already hold unlocks it immediately.
        for raw in pc.pending_epoch {
            let c = &mut st.circles[idx];
            if c.pending_epoch.len() < 512 && !c.pending_epoch.iter().any(|p| *p == raw) {
                c.pending_epoch.push(raw);
            }
        }
    }

    fn author(&self, circle_id: &str, created_at: u64, kind: EventKind) -> Result<Vec<u8>, HavenError> {
        let mut st = self.state.lock().unwrap();
        let me_pub = st.me.public();
        let event = Event::new(&me_pub.node_id_bytes(), created_at, kind);
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else {
            return Err(HavenError::Invalid { msg: "unknown circle".into() });
        };
        // Seal under the circle's CURRENT epoch key (bootstrapping epoch 0 the first time). The key
        // commit that lets members open it rides `sync_envelopes`/`export_my_envelopes` (no separate
        // transport needed). Removed members lack the current epoch key → can't open this.
        st.circles[idx].ensure_epoch();
        let epoch = st.circles[idx].my_epoch;
        let key = st.circles[idx].current_key().expect("epoch key exists after ensure_epoch");
        let env = seal_event_in_epoch(&st.me, circle_id, epoch, &key, &event)
            .map_err(|e| HavenError::Invalid { msg: format!("seal failed: {e}") })?;
        st.circles[idx].seen.insert(event.id.clone());
        st.circles[idx].events.push(event);
        Ok(tagged(TAG_EPOCH_EVENT, &env.to_bytes()))
    }
}

/// Prepend a 1-byte wire tag so `receive` can route an envelope. Legacy envelopes are untagged JSON.
fn tagged(tag: u8, body: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + body.len());
    v.push(tag);
    v.extend_from_slice(body);
    v
}

// ---- Multi-device device-roster storage + wire codec (D16/Phase 4) ------------------------------

/// Verify a signed device roster against `account` (the list AND every credential must chain to it),
/// store it (higher-version-wins, rollback-defended), and rotate every circle epoch this account is in
/// so the new device set takes effect — a revoked device can't open content sealed afterward, a new one
/// can. Returns false on a forged or stale roster.
fn verify_and_store_roster(st: &mut NetState, account: &HavenId, list_bytes: &[u8], cred_bytes: &[Vec<u8>]) -> bool {
    let Ok(list) = DeviceList::from_bytes(list_bytes) else { return false };
    if list.verify(account).is_err() {
        return false;
    }
    let mut credentials = Vec::with_capacity(cred_bytes.len());
    for cb in cred_bytes {
        let Ok(cred) = DeviceCredential::from_bytes(cb) else { return false };
        if cred.verify(account).is_err() {
            return false; // every credential must be signed by THIS account — no smuggling a rogue device.
        }
        credentials.push(cred);
    }
    let acct_id = account.node_id_bytes();
    let my_id = st.me.public().node_id_bytes();

    if acct_id == my_id {
        // MY OWN account's roster, possibly arriving from ANOTHER of my devices (multi-master: several
        // devices each restored the account from iCloud and self-register their own device id). A plain
        // higher-version-wins replace would let one device clobber another's registration, so UNION-merge
        // (grow-only devices + grow-only revoked) and re-sign with my account key. Union the credentials
        // too, so every device's routable bundle is kept. Revocations stay sticky (revoked only grows),
        // so this is rollback-safe without version-gating.
        let base = st.device_lists.get(&acct_id).map(|cd| cd.list.clone());
        let mut creds: Vec<DeviceCredential> =
            st.device_lists.get(&acct_id).map(|cd| cd.credentials.clone()).unwrap_or_default();
        let mut creds_grew = false;
        for c in &credentials {
            if !creds.iter().any(|e| e.device_id() == c.device_id()) {
                creds.push(c.clone());
                creds_grew = true;
            }
        }
        let merged = match &base {
            Some(b) => b.merge(&list, &st.me, list.updated_at),
            None => Some(list.clone()),
        };
        return match merged {
            Some(new_list) => {
                st.device_lists.insert(acct_id, ContactDevices { list: new_list, credentials: creds });
                for c in st.circles.iter_mut() {
                    c.rotate_epoch();
                }
                true
            }
            None => {
                if creds_grew {
                    if let Some(cd) = st.device_lists.get_mut(&acct_id) {
                        cd.credentials = creds;
                    }
                }
                creds_grew
            }
        };
    }

    // A CONTACT's roster: they re-sign their own union, so higher-version-wins with rollback defense.
    if let Some(existing) = st.device_lists.get(&acct_id) {
        if existing.list.version >= list.version {
            return false; // rollback / replay of an older roster — ignore.
        }
    }
    st.device_lists.insert(acct_id, ContactDevices { list, credentials });
    for c in st.circles.iter_mut() {
        if c.members.iter().any(|m| m.node_id_bytes() == acct_id) {
            c.rotate_epoch();
        }
    }
    true
}

/// Restore a persisted device roster on load: re-verify it against the carried account bundle and store
/// it WITHOUT rotating epochs (the saved epochs already reflect it). Higher-version-wins.
fn restore_roster(st: &mut NetState, account_bundle: &[u8], list_bytes: &[u8], cred_bytes: &[Vec<u8>]) {
    let Ok(account) = HavenId::from_bytes(account_bundle) else { return };
    let Ok(list) = DeviceList::from_bytes(list_bytes) else { return };
    if list.verify(&account).is_err() {
        return;
    }
    let mut credentials = Vec::new();
    for cb in cred_bytes {
        if let Ok(cred) = DeviceCredential::from_bytes(cb) {
            if cred.verify(&account).is_ok() {
                credentials.push(cred);
            }
        }
    }
    let acct_id = account.node_id_bytes();
    if let Some(existing) = st.device_lists.get(&acct_id) {
        if existing.list.version >= list.version {
            return;
        }
    }
    st.device_lists.insert(acct_id, ContactDevices { list, credentials });
}

/// If `sender_hex` is an AUTHORIZED device of a member of circle `idx` (or of me), return that device's
/// bundle — the verifying key for content the device authored on the account's behalf. The device's
/// credential chain was already verified when its roster was ingested, so the device's account being a
/// circle member is the only remaining check.
fn authorized_device_bundle(st: &NetState, idx: usize, sender_hex: &str) -> Option<HavenId> {
    let my_id = st.me.public().node_id_bytes();
    for (acct_id, cd) in &st.device_lists {
        let acct_in_circle =
            *acct_id == my_id || st.circles[idx].members.iter().any(|m| m.node_id_bytes() == *acct_id);
        if !acct_in_circle {
            continue;
        }
        for bundle in cd.authorized_bundles() {
            if hex(&bundle.node_id_bytes()) == sender_hex {
                return Some(bundle);
            }
        }
    }
    None
}

/// Wire layout: `lp(account_bundle) ‖ lp(device_list) ‖ u32 n ‖ lp(credential)*n` (all u32-LE lengths).
fn encode_roster(account: &HavenId, cd: &ContactDevices) -> Vec<u8> {
    fn lp(out: &mut Vec<u8>, b: &[u8]) {
        out.extend_from_slice(&(b.len() as u32).to_le_bytes());
        out.extend_from_slice(b);
    }
    let mut out = Vec::new();
    lp(&mut out, &account.to_bytes());
    lp(&mut out, &cd.list.to_bytes());
    out.extend_from_slice(&(cd.credentials.len() as u32).to_le_bytes());
    for c in &cd.credentials {
        lp(&mut out, &c.to_bytes());
    }
    out
}

/// Inverse of [`encode_roster`]: returns `(account_bundle, device_list_bytes, credential_bytes)`.
fn decode_roster(b: &[u8]) -> Option<(Vec<u8>, Vec<u8>, Vec<Vec<u8>>)> {
    let mut i = 0usize;
    fn u32_at(b: &[u8], i: &mut usize) -> Option<usize> {
        if *i + 4 > b.len() { return None; }
        let n = u32::from_le_bytes(b[*i..*i + 4].try_into().ok()?) as usize;
        *i += 4;
        Some(n)
    }
    fn lp(b: &[u8], i: &mut usize) -> Option<Vec<u8>> {
        let n = u32_at(b, i)?;
        if *i + n > b.len() { return None; }
        let v = b[*i..*i + n].to_vec();
        *i += n;
        Some(v)
    }
    let account = lp(b, &mut i)?;
    let list = lp(b, &mut i)?;
    let n = u32_at(b, &mut i)?;
    let mut creds = Vec::with_capacity(n);
    for _ in 0..n {
        creds.push(lp(b, &mut i)?);
    }
    Some((account, list, creds))
}

/// Domain-separated bytes for a profile-card signature (audit H3): a purpose tag prefixed to the JSON
/// payload, so the signature can never be reused as any other signed object.
fn profile_signing_bytes(payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(16 + payload.len());
    v.extend_from_slice(b"haven-profile-v1");
    v.extend_from_slice(payload);
    v
}

#[cfg(test)]
mod net_tests {
    use super::*;

    /// Deliver everything `from` authored in a circle (its key commit + epoch events) to `to`, the
    /// way the platform's sync/hello does — the commit teaches `to` the sender's epoch key.
    fn sync(from: &HavenSocial, to: &HavenSocial, cid: &str) {
        for env in from.sync_envelopes(cid.to_string()) {
            let _ = to.receive(cid.to_string(), env);
        }
    }

    #[test]
    fn two_socials_exchange_a_post() {
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();

        let cid = DEFAULT_CIRCLE.to_string();

        // Handshake: each adds the other's verified bundle to their default circle.
        let bob_id = alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        let alice_id = bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        assert_eq!(bob_id, bob.my_node_hex());
        assert_eq!(alice_id, alice.my_node_hex());

        // Alice posts. The live epoch envelope can't open until Bob has Alice's epoch key → it buffers.
        let env = alice.post(cid.clone(), "hi mom 💜".into(), vec![], None, None, false, false, 1_000).unwrap();
        assert!(!bob.receive(cid.clone(), env.clone()).unwrap(), "epoch event buffers until its key commit");
        // Alice's sync delivers the key commit (+ her events) → Bob learns the key, drains the buffer.
        sync(&alice, &bob, &cid);
        assert!(!bob.receive(cid.clone(), env).unwrap(), "deduped after the key arrives");

        let feed = bob.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].body, "hi mom 💜");
        assert!(!feed[0].is_me, "the post is from Alice, not Bob");

        // A stranger Bob hasn't added cannot be opened (ignored, not an error).
        let eve = HavenSocial::new([9u8; 32].to_vec()).unwrap();
        eve.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        let eve_env = eve.post(cid.clone(), "spam".into(), vec![], None, None, false, false, 1_500).unwrap();
        assert!(!bob.receive(cid.clone(), eve_env).unwrap(), "unknown sender is ignored");
        assert_eq!(bob.feed(cid.clone(), 2_000, None).len(), 1, "stranger's post not in feed");

        // Signed business card: Bob reads Alice's authoritative name + bio + link; a tampered
        // payload is rejected.
        let prof = alice.my_signed_profile("Alice".into(), "Mom of two".into(), "alice.example".into(), String::new(), String::new());
        assert_eq!(bob.verify_profile(alice.my_bundle(), prof.clone()).as_deref(), Some("Alice"));
        let card = bob.verify_profile_card(alice.my_bundle(), prof.clone()).unwrap();
        assert_eq!(card.name, "Alice");
        assert_eq!(card.bio, "Mom of two");
        assert_eq!(card.link, "alice.example");
        let mut forged = prof;
        let last = forged.len() - 1;
        forged[last] ^= 0xff;
        assert!(bob.verify_profile(alice.my_bundle(), forged).is_none(), "tampered card rejected");

        // Media blob: Alice seals a photo to Bob; Bob opens it; a stranger can't.
        let photo = vec![7u8; 5000];
        let sealed = alice.seal_media(bob.my_node_hex(), photo.clone()).unwrap();
        assert_eq!(bob.open_media(sealed.clone()), Some(photo.clone()));
        assert!(eve.open_media(sealed).is_none(), "non-recipient can't open media");

        // NSE path: Bob's seed alone (no engine/circle state) opens the same blob; a
        // wrong seed can't. This is exactly what the Notification Service Extension does.
        let notif = alice.seal_media(bob.my_node_hex(), b"Alice|Sent you a message".to_vec()).unwrap();
        assert_eq!(
            open_sealed_with_seed([2u8; 32].to_vec(), notif.clone()),
            Some(b"Alice|Sent you a message".to_vec()),
            "NSE opens with Bob's seed only"
        );
        assert!(open_sealed_with_seed([9u8; 32].to_vec(), notif.clone()).is_none(), "wrong seed can't open");
        assert!(open_sealed_with_seed([2u8; 32].to_vec(), vec![0u8; 4]).is_none(), "malformed blob is rejected");
        assert!(open_sealed_with_seed([2u8; 31].to_vec(), notif).is_none(), "wrong-length seed is rejected");

        // Persistence: export Bob's store, reload into a fresh instance → posts survive.
        let saved = bob.export_state();
        let bob2 = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        bob2.import_state(saved);
        assert_eq!(bob2.feed(cid.clone(), 2_000, None).len(), 1, "posts survive a restart");
        assert_eq!(bob2.contact_node_ids(cid.clone()), bob.contact_node_ids(cid.clone()), "contacts survive too");

        // Multi-circle isolation: a post in a new circle stays out of the default circle.
        alice.create_circle("fam".into(), "Family".into());
        alice.add_contact_bundle("fam".into(), bob.my_bundle()).unwrap();
        bob.create_circle("fam".into(), "Family".into());
        bob.add_contact_bundle("fam".into(), alice.my_bundle()).unwrap();
        alice.post("fam".into(), "just family".into(), vec![], None, None, false, false, 3_000).unwrap();
        sync(&alice, &bob, "fam");
        assert_eq!(bob.feed("fam".into(), 4_000, None).len(), 1, "fam post lands in fam circle");
        assert_eq!(bob.feed(cid, 4_000, None).len(), 1, "default circle is unchanged");
        assert_eq!(alice.circles().len(), 2, "alice now has two circles");
    }

    #[test]
    fn reports_traverse_the_circle_and_carry_the_full_author_hex() {
        let alice = HavenSocial::new([21u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([22u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Bob posts; Alice receives it, then reports it.
        bob.post(cid.clone(), "rude thing".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&bob, &alice, &cid);
        let post_id = alice.feed(cid.clone(), 2_000, None)[0].id.clone();

        // Reporting an event we never received is an error, not a silent no-op.
        assert!(alice.report(cid.clone(), "nonexistent".into(), "spam".into(), String::new(), 2_000).is_err());

        alice.report(cid.clone(), post_id.clone(), "harassment".into(), "uncalled for".into(), 2_000).unwrap();

        // Alice sees her own report; the embedded author is Bob's FULL hex (directly blockable).
        let mine = alice.reports(cid.clone());
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].target, post_id);
        assert_eq!(mine[0].author, bob.my_node_hex());
        assert_eq!(mine[0].reporter, alice.my_node_hex());
        assert_eq!(mine[0].reason, "harassment");

        // The report traverses to every member like any sealed event — Bob sees it too.
        sync(&alice, &bob, &cid);
        let theirs = bob.reports(cid.clone());
        assert_eq!(theirs.len(), 1);
        assert_eq!(theirs[0].author, bob.my_node_hex());
        assert_eq!(theirs[0].comment, "uncalled for");

        // Reports are moderation signals, not feed content — the feed still has only the post.
        assert_eq!(bob.feed(cid, 3_000, None).len(), 1);
    }

    #[test]
    fn removing_a_member_purges_their_posts_and_the_orphaned_replies() {
        let alice = HavenSocial::new([10u8; 32].to_vec()).unwrap(); // does the removing
        let bob = HavenSocial::new([11u8; 32].to_vec()).unwrap(); // gets removed
        let carol = HavenSocial::new([12u8; 32].to_vec()).unwrap(); // stays
        let cid = DEFAULT_CIRCLE.to_string();

        let bob_hex = alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        alice.add_contact_bundle(cid.clone(), carol.my_bundle()).unwrap();
        // Bob + Carol must seal to Alice for her to open their events.
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        carol.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Bob posts; Alice receives it (via Bob's sync = key commit + his events).
        bob.post(cid.clone(), "bob's photo".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&bob, &alice, &cid);
        let post_id = alice.feed(cid.clone(), 5_000, None)[0].id.clone();

        // Carol (a different, still-present member) comments on + reacts to Bob's post.
        carol.comment(cid.clone(), post_id.clone(), "nice!".into(), vec![], 1_100).unwrap();
        carol.react(cid.clone(), post_id.clone(), "❤️".into(), 1_200).unwrap();
        sync(&carol, &alice, &cid);

        let feed = alice.feed(cid.clone(), 5_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].comments.len(), 1, "carol's comment is attached to bob's post");
        assert_eq!(feed[0].reactions.len(), 1, "carol's reaction is attached to bob's post");

        // Remove Bob → his post AND Carol's comment/reaction *on that post* must all vanish; the
        // circle is left with no fragments.
        alice.remove_from_circle(cid.clone(), bob_hex.clone());
        assert!(alice.feed(cid.clone(), 5_000, None).is_empty(), "no fragments left after removal");

        // Carol herself stays a member; only Bob is gone.
        let members = alice.contact_node_ids(cid.clone());
        assert!(members.contains(&carol.my_node_hex()), "carol remains a member");
        assert!(!members.contains(&bob_hex), "bob is removed");
    }

    #[test]
    fn event_before_key_commit_survives_a_restart_and_is_recovered() {
        // THE random-non-delivery bug: an event fetched before its key commit is buffered, but the
        // buffer used to be in-memory only. A restart lost it and the mailbox never re-served the key
        // (seen-set), so that member permanently missed the post. Now the buffer is durable.
        let alice = HavenSocial::new([40u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([41u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        alice.post(cid.clone(), "hi everyone".into(), vec![], None, None, false, false, 1_000).unwrap();

        // Split Alice's sync bundle into the key commit (tag 0x03) and the event (tag 0x02).
        let bundle = alice.sync_envelopes(cid.clone());
        let commits: Vec<Vec<u8>> = bundle.iter().filter(|e| e.first() == Some(&0x03)).cloned().collect();
        let events: Vec<Vec<u8>> = bundle.iter().filter(|e| e.first() == Some(&0x02)).cloned().collect();
        assert!(!commits.is_empty() && !events.is_empty(), "bundle has both a commit and an event");

        // Bob receives ONLY the event first → buffered, can't open yet.
        for e in &events { let _ = bob.receive(cid.clone(), e.clone()); }
        assert!(bob.feed(cid.clone(), 2_000, None).is_empty(), "event buffered, not yet openable");

        // Bob "restarts": persist → fresh instance from the SAME seed → import.
        let saved = bob.export_state();
        drop(bob);
        let bob2 = HavenSocial::new([41u8; 32].to_vec()).unwrap();
        bob2.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        bob2.import_state(saved);
        assert!(bob2.feed(cid.clone(), 2_000, None).is_empty(), "still buffered after restart");

        // NOW the key commit arrives → the persisted buffer drains → the post appears.
        for c in &commits { let _ = bob2.receive(cid.clone(), c.clone()); }
        let feed = bob2.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1, "the post is recovered after the late key commit");
        assert_eq!(feed[0].body, "hi everyone");
    }

    #[test]
    fn removed_member_cannot_read_posts_after_removal() {
        let alice = HavenSocial::new([20u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([21u8; 32].to_vec()).unwrap(); // gets removed
        let carol = HavenSocial::new([22u8; 32].to_vec()).unwrap(); // stays
        let cid = DEFAULT_CIRCLE.to_string();

        // Everyone in the circle, mutual membership so each can open the others' commits + events.
        let bob_hex = alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        alice.add_contact_bundle(cid.clone(), carol.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        carol.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Epoch 0: Alice posts; Bob and Carol both read it.
        alice.post(cid.clone(), "before".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&alice, &bob, &cid);
        sync(&alice, &carol, &cid);
        assert_eq!(bob.feed(cid.clone(), 2_000, None).len(), 1, "bob reads the pre-removal post");
        assert_eq!(carol.feed(cid.clone(), 2_000, None).len(), 1, "carol reads it too");

        // Alice removes Bob → her epoch rotates; the next key commit is sealed only to Carol (+ Alice).
        alice.remove_from_circle(cid.clone(), bob_hex.clone());
        alice.post(cid.clone(), "after".into(), vec![], None, None, false, false, 3_000).unwrap();
        sync(&alice, &carol, &cid); // Carol is still a member → gets epoch 1 + the post
        sync(&alice, &bob, &cid); // Bob: Alice's commit isn't sealed to him → he can't learn the key

        // Carol reads the post-removal post; Bob CANNOT (he never learns epoch 1's key).
        assert_eq!(
            carol.feed(cid.clone(), 4_000, None).iter().filter(|i| i.body == "after").count(),
            1,
            "carol reads the post-removal post"
        );
        assert_eq!(
            bob.feed(cid.clone(), 4_000, None).iter().filter(|i| i.body == "after").count(),
            0,
            "removed bob cannot read content posted after his removal (cryptographic revocation)"
        );
    }

    #[test]
    fn signed_notification_authenticates_the_sender() {
        let alice = HavenSocial::new([30u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([31u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        let bob_hex = alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Alice → signed notification to Bob; Bob's seed alone opens it AND proves it was really Alice.
        let blob = alice.seal_signed_notification(bob_hex, b"Alice|hey".to_vec()).unwrap();
        let opened = open_signed_notification_with_seed([31u8; 32].to_vec(), blob.clone()).unwrap();
        assert_eq!(opened.data, b"Alice|hey");
        assert_eq!(opened.sender_hex, alice.my_node_hex());

        // Tampering anywhere → rejected.
        let mut bad = blob.clone();
        let n = bad.len() - 1;
        bad[n] ^= 0xff;
        assert!(open_signed_notification_with_seed([31u8; 32].to_vec(), bad).is_none());

        // A plain (unsigned) seal_media blob — the old spoofable form — can't pass as signed.
        let plain = alice.seal_media(bob.my_node_hex(), b"spoof".to_vec()).unwrap();
        assert!(open_signed_notification_with_seed([31u8; 32].to_vec(), plain).is_none());
    }

    #[test]
    fn old_epoch_keys_are_pruned_for_forward_secrecy() {
        let alice = HavenSocial::new([40u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.post(cid.clone(), "bootstrap".into(), vec![], None, None, false, false, 1).unwrap();
        for _ in 0..10 {
            alice.rotate_circle(cid.clone());
        }
        let ps: PersistState = serde_json::from_slice(&alice.export_state()).unwrap();
        let circle = ps.circles.iter().find(|c| c.id == cid).unwrap();
        assert!(circle.my_epoch >= 10, "epoch advanced through the rotations");
        assert!(
            circle.my_epoch_keys.len() <= 4,
            "old epoch keys are pruned (bounded FS); retained {}",
            circle.my_epoch_keys.len()
        );
        // Posting still works after pruning (current epoch key is always retained).
        assert!(!alice.post(cid, "after rotations".into(), vec![], None, None, false, false, 2).unwrap().is_empty());
    }

    #[test]
    fn device_roster_wire_verification_and_rollback() {
        use p2pcore::device::{DeviceCredential, DeviceList};
        let account = Identity::from_seed(&[1u8; 32]);
        let phone = Identity::from_seed(&[2u8; 32]);
        let imposter = Identity::from_seed(&[9u8; 32]);

        let list = DeviceList::signed(&account, 1, 0, vec![phone.public().node_id_bytes()], vec![]);
        let cred = DeviceCredential::issue(&account, &phone.public(), "phone", 1);
        let cd = ContactDevices { list: list.clone(), credentials: vec![cred.clone()] };

        // Wire round-trip.
        let (acct_b, list_b, creds_b) = decode_roster(&encode_roster(&account.public(), &cd)).expect("decode");
        assert_eq!(acct_b, account.public().to_bytes());
        assert_eq!(list_b, list.to_bytes());
        assert_eq!(creds_b, vec![cred.to_bytes()]);

        let alice = HavenSocial::new([5u8; 32].to_vec()).unwrap();
        // A valid roster (list + creds both signed by the account) is accepted.
        assert!(alice.ingest_device_roster(account.public().to_bytes(), list.to_bytes(), vec![cred.to_bytes()]));
        // A roster NOT signed by the claimed account is rejected (anti-rogue-device).
        let forged = DeviceList::signed(&imposter, 2, 0, vec![phone.public().node_id_bytes()], vec![]);
        assert!(!alice.ingest_device_roster(account.public().to_bytes(), forged.to_bytes(), vec![]));
        // A credential signed by someone else can't be smuggled into a valid list.
        let rogue_cred = DeviceCredential::issue(&imposter, &phone.public(), "rogue", 1);
        let list2 = DeviceList::signed(&account, 2, 0, vec![phone.public().node_id_bytes()], vec![]);
        assert!(!alice.ingest_device_roster(account.public().to_bytes(), list2.to_bytes(), vec![rogue_cred.to_bytes()]));
        // Rollback defense: after storing v3, a v2 replay is rejected.
        let v3 = DeviceList::signed(&account, 3, 0, vec![phone.public().node_id_bytes()], vec![]);
        assert!(alice.ingest_device_roster(account.public().to_bytes(), v3.to_bytes(), vec![cred.to_bytes()]));
        let stale = DeviceList::signed(&account, 2, 0, vec![], vec![]);
        assert!(!alice.ingest_device_roster(account.public().to_bytes(), stale.to_bytes(), vec![]));

        // Roster survives an export/import round-trip (so restarts keep it, without re-rotating epochs).
        let v5 = DeviceList::signed(&account, 5, 0, vec![phone.public().node_id_bytes()], vec![]);
        let s = HavenSocial::new([6u8; 32].to_vec()).unwrap();
        s.add_contact_bundle(DEFAULT_CIRCLE.to_string(), account.public().to_bytes()).unwrap(); // member → export resolves the account bundle
        assert!(s.ingest_device_roster(account.public().to_bytes(), v5.to_bytes(), vec![cred.to_bytes()]));
        let reloaded = HavenSocial::new([6u8; 32].to_vec()).unwrap();
        reloaded.import_state(s.export_state());
        let v4 = DeviceList::signed(&account, 4, 0, vec![], vec![]);
        assert!(!reloaded.ingest_device_roster(account.public().to_bytes(), v4.to_bytes(), vec![]),
                "the restored v5 roster makes a v4 replay stale → it round-tripped");
    }

    /// End-to-end: a member's AUTHORIZED linked device receives the circle's content, and REVOKING it
    /// cuts it off from everything posted afterward. This is "revocable device linking" working.
    #[test]
    fn linked_device_receives_then_revocation_cuts_it_off() {
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let bob_phone = HavenSocial::new([22u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();

        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        bob_phone.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap(); // phone verifies Alice's commits

        let bob_acct_id = Identity::from_seed(&[2u8; 32]).public().node_id_bytes().to_vec();
        let phone_id = Identity::from_seed(&[22u8; 32]).public().node_id_bytes().to_vec();
        let acct_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), bob.my_bundle(), "bob-primary".into(), 0).unwrap();
        let phone_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), bob_phone.my_bundle(), "bob-phone".into(), 1).unwrap();

        // Bob's roster v1 authorizes his account + his phone. Alice learns it.
        let v1 = crate::multidevice::sign_device_list([2u8; 32].to_vec(), 1, 0, vec![bob_acct_id.clone(), phone_id.clone()], vec![]).unwrap();
        assert!(bob.set_my_device_roster(v1.clone(), vec![acct_cred.clone(), phone_cred.clone()]));
        assert!(alice.ingest_device_roster(bob.my_bundle(), v1, vec![acct_cred.clone(), phone_cred.clone()]));

        // Alice posts → her key commit seals to Bob's phone too → the phone receives it.
        let _ = alice.post(cid.clone(), "before revoke".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&alice, &bob_phone, &cid);
        let feed = bob_phone.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1, "linked device received the post");
        assert_eq!(feed[0].body, "before revoke");

        // Bob REVOKES the phone (roster v2: phone moved to revoked). Alice learns it (rotating her epoch).
        let v2 = crate::multidevice::sign_device_list([2u8; 32].to_vec(), 2, 1, vec![bob_acct_id], vec![phone_id]).unwrap();
        assert!(alice.ingest_device_roster(bob.my_bundle(), v2, vec![acct_cred]));

        // Alice posts again → her NEW key commit is sealed only to the remaining devices; the revoked
        // phone is not a recipient, so it can't learn the new epoch key and never sees this post.
        let _ = alice.post(cid.clone(), "after revoke".into(), vec![], None, None, false, false, 3_000).unwrap();
        sync(&alice, &bob_phone, &cid);
        let feed2 = bob_phone.feed(cid.clone(), 4_000, None);
        assert!(feed2.iter().all(|m| m.body != "after revoke"),
                "REVOKED device must not receive anything posted after revocation");
    }

    #[test]
    fn device_identity_dual_opens_old_account_and_new_device_sealed() {
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // (1) No device key yet → Alice's post is account-sealed; Bob opens it via the account key.
        alice.post(cid.clone(), "old account-sealed".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&alice, &bob, &cid);
        assert!(bob.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "old account-sealed"),
                "account-sealed content opens via the account key");

        // (2) Bob adopts his DEVICE key + self-registers; his roster reaches Alice (rides the sync bundle).
        assert!(bob.use_device_identity([99u8; 32].to_vec()));
        assert_ne!(bob.my_device_node_hex(), hex(&Identity::from_seed(&[2u8; 32]).public().node_id_bytes()),
                   "device transport id must differ from the account id");
        assert!(!bob.register_device(bob.my_device_bundle(), "bob-mac".into(), 1).is_empty());
        sync(&bob, &alice, &cid);

        // (3) Alice's new post now seals to Bob's DEVICE bundle; Bob opens it with his device key —
        //     while the older account-sealed post is STILL readable (dual-open).
        alice.post(cid.clone(), "new device-sealed".into(), vec![], None, None, false, false, 3_000).unwrap();
        sync(&alice, &bob, &cid);
        let feed = bob.feed(cid.clone(), 4_000, None);
        assert!(feed.iter().any(|m| m.body == "new device-sealed"),
                "device-sealed content opens via the device key (Option 1)");
        assert!(feed.iter().any(|m| m.body == "old account-sealed"),
                "dual-open keeps older account-sealed content readable");
    }
}
