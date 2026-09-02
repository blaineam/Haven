//! `haven_ffi` — the UniFFI surface that bridges `haven-p2p` to Swift (and Kotlin).
//!
//! Keeps the exposed API tiny and Swift-friendly: an [`Account`] object, a couple of
//! free functions, and plain records. All the security-critical logic stays in
//! `haven-p2p`; this is only the boundary.

use std::sync::{Arc, Mutex};

use std::collections::{HashMap, HashSet};

use haven_net::Node;
use haven_net::blobstore::BlobClient;
use std::path::PathBuf;
use haven_p2p::crypto::{decapsulate, encapsulate_to, open, seal, Encapsulation};
use haven_p2p::device::{
    admin_closure, circle_fully_compact_wire_capable, circle_fully_mls_capable,
    circle_fully_seed_drop_capable, circle_id_binds_creator,
    mint_owned_circle_id, recipients_with_devices, recipients_with_devices_gated, AdminGrant,
    CircleUpgrade, ContactDevices, DeviceCredential, DeviceList, SeedDropCapability,
};
use haven_p2p::treekem;
use haven_p2p::transport;
use haven_p2p::identity::{Identity, HavenId};
use haven_p2p::link::HavenLink;
use haven_p2p::social::{
    open_bytes_with_epoch, seal_bytes_with_epoch,
    build_activity, build_feed, is_expired, open_bytes, open_event, seal_bytes, seal_event, Event,
    EventKind, FeedPoll, Group, SealedEnvelope, TrackRef,
};
use haven_p2p::groupkey::{
    mailbox_prefix, new_circle_secret, new_epoch_key, open_event_in_epoch_authored, open_key_commit,
    seal_event_in_epoch, seal_event_ratcheted, seal_key_commit, EpochEnvelope,
};

/// The seed-drop protocol version this build advertises (S0). A build with the S1 receive-side verifier
/// advertises v1 so peers can NEGOTIATE the migration; nothing in this release *acts* on it to change
/// what gets sealed or who signs — it is the rail a later release flips on.
const SEED_DROP_VERSION: u32 = 1;

/// The MLS (TreeKEM) protocol version this build advertises (M0, docs/TREEKEM-DESIGN.md §7.1). Rides
/// the signed profile beside `sd` so peers can NEGOTIATE the per-circle migration; nothing in this
/// release *acts* on it to change what gets sealed or who signs — it is the rail a later release
/// flips on. Advertised in the PROFILE only: the roster trailer is not appendable
/// (`SeedDropCapability::from_bytes` consumes the rest as signature, so appending would break every
/// existing peer's seed-drop verify mid-migration).
const MLS_VERSION: u32 = 1;

/// Compact-envelope capability version (`docs/SATELLITE-DESIGN.md` §6, S0 write-side). Advertised as
/// `cw` in the account-signed profile card, exactly like `sd` and `ml`. `1` means "this build can
/// READ the tagged binary `EpochEnvelope` container"; a circle whose every member advertises it
/// starts being WRITTEN that container, which is ~3.5x smaller on the wire.
const COMPACT_WIRE_VERSION: u32 = 1;

/// Wire tags prefixed to an envelope so `receive` can route it. Legacy (untagged) envelopes are raw
/// JSON beginning with `{` (0x7b), so any tag byte we choose that isn't `{` is unambiguous.
const TAG_EPOCH_EVENT: u8 = 0x02; // an EpochEnvelope (event sealed under a circle epoch key)
const TAG_KEY_COMMIT: u8 = 0x03; // a SealedEnvelope carrying a circle epoch key (KeyCommit)
const TAG_DEVICE_ROSTER: u8 = 0x04; // an account's signed device roster (DeviceList + DeviceCredentials)
// TreeKEM M2 SHADOW wire tags (docs/TREEKEM-DESIGN.md §3.4, continuing 0x02/0x03/0x04). They ride
// the same mailbox as everything else and are only EMITTED for fully-MLS-capable circles (§7.3), so
// a legacy/non-MLS peer essentially never fetches one; if it does, its tag byte isn't `{` (0x7b) so
// the raw-JSON `receive_legacy` arm fails the parse and returns a harmless per-envelope error — the
// exact unknown-tag behavior every corrupt envelope already gets. An M2 peer routes them to the
// SHADOW handlers below, which never touch content state (the tree is compared, never consumed).
const TAG_MLS_COMMIT: u8 = 0x05; // a treekem::Commit (a ratchet-tree commit; genesis carries the Adds)
const TAG_MLS_WELCOME: u8 = 0x06; // a SealedEnvelope delivering a joiner's shadow secrets to its device
const TAG_MLS_PROPOSAL: u8 = 0x07; // a treekem::Proposal (reserved; unbundled proposals — M4 roster path)
// MLS M3 wire tags (docs/TREEKEM-DESIGN.md §7.2 join gate, §4.3 authority). Same additive contract:
// any non-`{` tag a legacy peer fetches fails its raw-JSON parse and errors per-envelope harmlessly.
const TAG_MLS_JOIN: u8 = 0x08; // a signed join ack: "device D holds genesis G's Welcome" (the §7.2 gate)
const TAG_ADMIN_GRANT: u8 = 0x09; // an account-signed device::AdminGrant riding the circle control lane
const TAG_CIRCLE_UPGRADE: u8 = 0x0a; // a device::CircleUpgrade offer: legacy circle → creator-bound successor

/// An upgrade offer awaiting the user's decision: "`from_hex` says this legacy circle's creator-bound
/// successor is `new_circle_id`". The signature and the successor's binding to `from_hex` are already
/// verified; what CANNOT be verified is that `from_hex` created the legacy circle, because legacy
/// circles never recorded an owner. Show who is claiming it and let the user choose.
#[derive(uniffi::Record, Clone, Debug)]
pub struct CircleUpgradeOffer {
    pub legacy_circle_id: String,
    pub new_circle_id: String,
    /// The account offering the upgrade — show this identity to the user before they accept.
    pub from_hex: String,
    pub name: String,
    /// True when I authored this offer (my own circle) — no confirmation needed.
    pub mine: bool,
}

/// Content-epoch namespace for MLS-keyed circles (M3, §4.5). When the keying flip is live, the
/// circle's content seals under `MLS_EPOCH_BASE + tree_epoch` instead of a legacy sender-keys epoch.
/// The huge offset keeps tree epochs from ever colliding with the small legacy epoch numbers already
/// in `my_epoch_keys` — so PARK (revert to legacy) never confuses a stale legacy key with a tree key,
/// and the two epoch spaces coexist in the SAME maps with zero change to the content path's lookups.
const MLS_EPOCH_BASE: u64 = 1 << 40;

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

/// Install known circle DERP HTTPS URLs as the process-wide iroh fabric policy.
///
/// Empty → stock n0 only. Non-empty → Haven-only (n0 off). Call **before** [`HavenNode::start`]
/// when prefs already know a fabric, and again whenever frame 19 / adopt learns a `derp` URL.
///
/// **Limit:** iroh binds `RelayMap` at endpoint construct time. This updates the process policy
/// for the *next* bind. Live messaging nodes must be stopped and re-started (see
/// [`HavenNode::shutdown`]) to pick up a new map — desktop does this via soft rebind when fabric
/// is first learned mid-session. WebRTC ICE still follows app-side fabric prefs
/// (Apple `HavenFabric` / Android `haven.fabric`).
#[uniffi::export]
pub fn apply_derp_urls(urls: Vec<String>) {
    haven_net::apply_derp_urls(urls);
}

/// True when ≥1 Haven DERP URL is installed in the process policy (n0 is not sole fabric).
#[uniffi::export]
pub fn haven_fabric_active() -> bool {
    haven_net::haven_fabric_active()
}

/// Active custom DERP URLs from the process policy (empty when n0-only).
#[uniffi::export]
pub fn active_derp_urls() -> Vec<String> {
    haven_net::active_derp_urls()
}

// ── Low-data mode (docs/SATELLITE-DESIGN.md §5) ──────────────────────────────────────────────────
//
// The policy lives in `haven_p2p::transport` and is mirrored here rather than reimplemented on each
// client. Apple detects the constraint with `NWPath` and Android with `NetworkCapabilities`, but
// BOTH then ask `low_data_allowance` what may cross — so the two platforms cannot drift into
// different ideas of what low-data mode means, which is the failure mode the parity rule exists to
// prevent.

/// How little bandwidth the current path can be trusted with. Mirrors
/// [`haven_p2p::transport::LinkConstraint`].
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum LinkConstraint {
    /// Ordinary Wi-Fi or cellular — nothing is withheld.
    Normal,
    /// Low Data Mode, a metered hotspot, or a bandwidth-constrained cell.
    Low,
    /// A carrier satellite bearer or anything else the OS calls ultra-constrained.
    Ultra,
}

/// A kind of traffic the app is about to generate. Mirrors [`haven_p2p::transport::Traffic`].
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Traffic {
    Text,
    KeyConvergence,
    Presence,
    /// The 512px AVIF preview tier — the only media that crosses a satellite link.
    Preview,
    Media,
    Thumbnail,
    LinkPreview,
    Story,
    Call,
    HistoryBackfill,
    SelfSync,
    Enrollment,
}

/// What the policy permits. Mirrors [`haven_p2p::transport::Allowance`].
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Allowance {
    /// Proceed.
    Allow,
    /// Proceed only behind an explicit per-item user action, having shown the cost.
    AskFirst,
    /// Emit no bytes. A refusal, not a throttle.
    Deny,
}

impl From<LinkConstraint> for transport::LinkConstraint {
    fn from(v: LinkConstraint) -> Self {
        match v {
            LinkConstraint::Normal => transport::LinkConstraint::Normal,
            LinkConstraint::Low => transport::LinkConstraint::Low,
            LinkConstraint::Ultra => transport::LinkConstraint::Ultra,
        }
    }
}

impl From<Traffic> for transport::Traffic {
    fn from(v: Traffic) -> Self {
        match v {
            Traffic::Text => transport::Traffic::Text,
            Traffic::KeyConvergence => transport::Traffic::KeyConvergence,
            Traffic::Presence => transport::Traffic::Presence,
            Traffic::Preview => transport::Traffic::Preview,
            Traffic::Media => transport::Traffic::Media,
            Traffic::Thumbnail => transport::Traffic::Thumbnail,
            Traffic::LinkPreview => transport::Traffic::LinkPreview,
            Traffic::Story => transport::Traffic::Story,
            Traffic::Call => transport::Traffic::Call,
            Traffic::HistoryBackfill => transport::Traffic::HistoryBackfill,
            Traffic::SelfSync => transport::Traffic::SelfSync,
            Traffic::Enrollment => transport::Traffic::Enrollment,
        }
    }
}

impl From<transport::Allowance> for Allowance {
    fn from(v: transport::Allowance) -> Self {
        match v {
            transport::Allowance::Allow => Allowance::Allow,
            transport::Allowance::AskFirst => Allowance::AskFirst,
            transport::Allowance::Deny => Allowance::Deny,
        }
    }
}

/// The process-wide current link constraint, as last reported by the platform. `u8` so the read is
/// a relaxed atomic load: core paths (self-sync scheduling, history backfill) consult it often and
/// must never take a lock to do it.
static LINK_CONSTRAINT: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// Report the current path constraint. Called by the platform's path monitor whenever it changes:
/// `NWPathMonitor` on Apple, a `ConnectivityManager.NetworkCallback` on Android.
#[uniffi::export]
pub fn set_link_constraint(link: LinkConstraint) {
    let v = match link {
        LinkConstraint::Normal => 0,
        LinkConstraint::Low => 1,
        LinkConstraint::Ultra => 2,
    };
    LINK_CONSTRAINT.store(v, std::sync::atomic::Ordering::Relaxed);
}

/// The constraint last reported by the platform.
#[uniffi::export]
pub fn link_constraint() -> LinkConstraint {
    match LINK_CONSTRAINT.load(std::sync::atomic::Ordering::Relaxed) {
        1 => LinkConstraint::Low,
        2 => LinkConstraint::Ultra,
        _ => LinkConstraint::Normal,
    }
}

/// What the policy permits for this traffic kind on the link the platform last reported.
///
/// This is the call sites' entry point: ask before generating traffic, not after.
#[uniffi::export]
pub fn low_data_allowance(traffic: Traffic) -> Allowance {
    transport::allowance(link_constraint().into(), traffic.into()).into()
}

/// [`low_data_allowance`] against an explicitly supplied link, for callers that already hold one
/// (and for tests that must not depend on process state).
#[uniffi::export]
pub fn low_data_allowance_on(link: LinkConstraint, traffic: Traffic) -> Allowance {
    transport::allowance(link.into(), traffic.into()).into()
}

/// True when low-data behaviour applies at all right now — for the UI banner.
#[uniffi::export]
pub fn low_data_active() -> bool {
    !matches!(link_constraint(), LinkConstraint::Normal)
}

/// Multi-device (D16): device-credential + account-state self-sync FFI surface.
/// `pub` so the desktop backend (which links this crate directly) can call the shared
/// circle encoder + S3 helpers without going through UniFFI.
pub mod multidevice;

/// `pub` so the desktop backend can call the shared seed-drop S4 enrollment codec directly.
pub mod enroll;
pub mod friend_invite;

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
/// Wraps `haven_p2p::identity::Identity`.
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

/// Parse a 64-char lowercase-hex account/node id into 32 bytes (the inverse of [`hex`] for ids).
fn decode_hex32(s: &str) -> Result<[u8; 32], ()> {
    if s.len() != 64 {
        return Err(());
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).map_err(|_| ())?;
    }
    Ok(out)
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

/// A call-signaling frame opened + cryptographically verified: the PROVEN sender account hex and the
/// plaintext body. The caller still gates the sender against its roster / contact list (that is
/// *authorization*), but `sender_hex` is now proven by an Ed25519 signature, not a self-declared
/// prefix a relay could forge (audit R1).
#[derive(uniffi::Record)]
pub struct SignedCallFrame {
    pub sender_hex: String,
    pub data: Vec<u8>,
}

/// The bytes a call-frame signature covers: a domain tag ‖ the recipient node id ‖ the wire frame
/// type ‖ the plaintext. Binding the recipient stops a captured frame being replayed at a different
/// user; binding the frame type stops a captured offer (16) being replayed as, say, a hangup (12) or
/// an answer (17). Distinct domain tag from `notif_signing_bytes` so the two signature families can
/// never be cross-replayed.
fn call_signing_bytes(recipient_hex: &str, frame_type: u8, plaintext: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(13 + 1 + recipient_hex.len() + plaintext.len());
    v.extend_from_slice(b"haven-call-v1");
    v.extend_from_slice(recipient_hex.as_bytes());
    v.push(frame_type);
    v.extend_from_slice(plaintext);
    v
}

/// Version marker for the APNs-sized notification envelope. v1 (no marker) began with a u32
/// bundle length whose first byte was 0x80, so the two can never be confused: a v1 blob reaching a
/// v2 reader is refused here, and a v2 blob reaching a v1 reader fails its length check. Both drop
/// rather than misparse — acceptable because v1 blobs were never delivered at all (APNs 413'd every
/// one; see `seal_signed_notification`), so there is no working traffic to stay compatible with.
const NOTIF_V2: u8 = 0x02;
/// `[version 1][node id 32][ed25519 sig 64]`.
const NOTIF_V2_PREFIX_LEN: usize = 1 + 32 + 64;

/// NSE/recipient side: open a SIGNED push notification with the seed alone, verifying the sender
/// named by the carried node id actually authored it. Defeats the spoof where anyone holding the
/// recipient's public key seals an arbitrary "Alice|…" alert — a forger can only sign as
/// *themselves*, never as a contact, and the bound recipient prevents replay. Ed25519-only, for
/// the payload-size reason documented on `seal_signed_notification`.
/// Layout: `[NOTIF_V2][sender node id (32)][ed25519 sig (64)][seal_media output]`.
#[uniffi::export]
pub fn open_signed_notification_with_seed(seed: Vec<u8>, blob: Vec<u8>) -> Option<SignedNotification> {
    let seed_arr: [u8; 32] = seed.clone().try_into().ok()?;
    let me = Identity::from_seed(&seed_arr);
    let recipient_hex = hex(&me.public().node_id_bytes());
    if blob.len() <= NOTIF_V2_PREFIX_LEN || blob[0] != NOTIF_V2 {
        return None;
    }
    let node_id: [u8; 32] = blob[1..33].try_into().ok()?;
    let sig = &blob[33..NOTIF_V2_PREFIX_LEN];
    let sealed = blob[NOTIF_V2_PREFIX_LEN..].to_vec();
    let plaintext = open_sealed_with_seed(seed, sealed)?;
    // Verify BEFORE trusting anything inside the plaintext (the caller name / `h` field the UI
    // renders): the signature is what promotes a self-declared sender into a proven one.
    HavenId::verify_ed25519_only(&node_id, &notif_signing_bytes(&recipient_hex, &plaintext), sig).ok()?;
    Some(SignedNotification { sender_hex: hex(&node_id), data: plaintext })
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

/// A relay link granting MANY circles at once — parallel arrays, one entry per circle.
///
/// A relay authorizes exactly what its link grants, and the apps let a user point every circle at
/// one relay. A single-circle link therefore left every OTHER circle permanently `ERR forbidden`,
/// with no way to recover: publishing a device roster only expands device ids into circles the
/// relay already knows, so a circle it was never granted has nothing to expand into. That is what
/// made media unreachable on a relay that was holding it.
///
/// v2 keeps `c`/`m` set to the FIRST circle so a link pasted into an older relay binary still
/// authorizes that one rather than failing outright.
#[uniffi::export]
pub fn make_relay_link_multi(circles: Vec<String>, members_per_circle: Vec<String>) -> String {
    // `members_per_circle[i]` is circle i's members, comma-separated — UniFFI has no Vec<Vec<String>>.
    let grants: Vec<serde_json::Value> = circles
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let m: Vec<&str> = members_per_circle
                .get(i)
                .map(|s| s.split(',').filter(|x| !x.is_empty()).collect())
                .unwrap_or_default();
            serde_json::json!({ "c": c, "m": m })
        })
        .collect();
    let first_c = circles.first().cloned().unwrap_or_default();
    let first_m: Vec<&str> = members_per_circle
        .first()
        .map(|s| s.split(',').filter(|x| !x.is_empty()).collect())
        .unwrap_or_default();
    let v = serde_json::json!({ "v": 2, "c": first_c, "m": first_m, "g": grants });
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
    Ok(haven_net::httprelay::auth_header(&auth_node_secret(&seed), &token, &method, &key, &body))
}

/// seed → node-signing-secret, cached. `Identity::from_seed` derives the FULL hybrid identity —
/// classical + post-quantum keypairs, real CPU and a burst of small allocations — and clients sign
/// EVERY HTTP request (per-request transcripts are the design; see `http_auth_header`). Deriving
/// per call put `Identity::from_seed` at the top of a main-thread beachball sample while a client
/// drained a large mailbox backlog (hundreds of signed GETs per poll, ~10 GB of Malloc-Small churn).
/// Only the derivation is cached — the SIGNATURE stays strictly per-request. Bounded: an app holds
/// at most its account seed + device seed (+ QA stubs), so four slots cover everyone.
fn auth_node_secret(seed: &[u8; 32]) -> [u8; 32] {
    static CACHE: std::sync::Mutex<Vec<([u8; 32], [u8; 32])>> = std::sync::Mutex::new(Vec::new());
    let mut cache = CACHE.lock().unwrap();
    if let Some((_, sec)) = cache.iter().find(|(s, _)| s == seed) {
        return *sec;
    }
    let sec = Identity::from_seed(seed).node_secret_bytes();
    if cache.len() >= 4 {
        cache.remove(0);
    }
    cache.push((*seed, sec));
    sec
}

/// Client to a circle's blob mailbox (a relay's local-disk store, reached over Haven Net /
/// iroh). Used to upload a circle-sealed media blob and fetch it later — no shared bucket
/// credentials, just the relay's node id. The relay never sees content (blobs are sealed).
#[derive(uniffi::Object)]
pub struct RelayClient {
    /// Shared with the node's per-peer cache (`blob_client_cached`) so the app and the relay mesh use
    /// ONE warm connection per relay instead of each holding their own. A connection that keeps being
    /// rebuilt never lives long enough for iroh to promote it to a direct path, which is what left the
    /// mailbox unable to cross NAT at all.
    inner: Arc<BlobClient>,
}

#[uniffi::export(async_runtime = "tokio")]
impl RelayClient {
    /// Tell this relay who ELSE serves `circleId`, so it mesh-replicates with them instead of only
    /// with hexes its operator typed by hand. Best-effort and silent on failure: an older relay has
    /// no such verb, and a relay that refuses simply keeps its existing peer set.
    ///
    /// This is what makes replication symmetric. The apps already pull from every relay they know;
    /// a headless relay knew nobody, so anything uploaded while it was offline stayed missing there.
    pub async fn teach_relays(&self, circle_id: String, relays: Vec<String>) -> bool {
        self.inner.enroll_relays(&circle_id, &relays).await.is_ok()
    }

    /// Tell this relay who the MEMBERS of `circleId` are, so a peer the operator never typed into
    /// the relay link can still be served. Best-effort and silent on failure, like `teach_relays`.
    ///
    /// The relay half of this (`RelayAuth::learn`) was already written, with its authorization rules
    /// spelled out: a caller the relay already serves may enroll a circle additively, must include
    /// ITSELF in the member list, and may only extend an existing circle from the inside. What was
    /// missing is this — the client half was never exported through the FFI, so no app on any
    /// platform could reach the verb. The result was that circle membership only ever reached a
    /// relay through the operator pasting a link: invite a new person and the relay refuses them
    /// forever, which reads as "media never loads and DMs never send" rather than as a permissions
    /// gap. `members` must include our own id or the relay declines by rule (2).
    pub async fn enroll_members(&self, circle_id: String, members: Vec<String>) -> bool {
        self.inner.enroll(&circle_id, &members).await.is_ok()
    }

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
        Ok(Arc::new(Self { inner: Arc::new(inner) }))
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

    /// Does the relay hold `key`? Failures SURFACE — same contract, and same reason, as `list`
    /// below. `unwrap_or(false)` reported an unreachable relay as "reachable, and it does not have
    /// this blob", which is the most expensive lie this API can tell: the media backfill read that
    /// as a genuine miss, queued an upload, and the put then bailed instantly on the very dial
    /// cooldown the failed probe had just re-armed. Each pass re-sealed the whole file (~2× its
    /// size in RAM) to reach a relay it had already been told was down, and since the author's own
    /// in-process relay counted as `landed`, the job was reported a SUCCESS and dropped. Callers
    /// must treat an error as "unknown, try later", never as "missing".
    pub async fn has(&self, key: String) -> Result<bool, HavenError> {
        self.inner
            .has(&key)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("relay has: {e}") })
    }

    /// List keys under a prefix (e.g. `mailbox/<circle>`) to poll the mailbox.
    ///
    /// Failures SURFACE as an error — an empty Vec means the relay really holds nothing under
    /// the prefix. The old `unwrap_or_default()` made every transport failure (dial cooldown,
    /// unreachable relay) indistinguishable from an empty mailbox, so callers with an HTTP
    /// fallback rung never took it: an HTTP-only device "polled successfully" forever while
    /// its mailbox sat full on the relay. Kotlin call sites already `runCatching` this.
    pub async fn list(&self, prefix: String) -> Result<Vec<String>, HavenError> {
        self.inner
            .list(&prefix)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("relay list: {e}") })
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

    /// [`Self::attach`] with the limits the HOST chose for how much of their circles' media they're
    /// willing to keep, and for how long — the in-app equivalent of the headless binary's
    /// `--media-max-age-days` / `--media-max-bytes`. Someone volunteering a laptop should be able to
    /// say "help my circles, but not with my whole disk", and until now the app-hosted relay had no
    /// way to say it: it always ran unlimited media.
    ///
    /// `0` means "no limit" for that dimension, so either can be set independently. When BOTH are
    /// set the sweep applies whichever frees space first — an old blob goes on age even if there's
    /// room, and a fresh one goes on size if the cap is hit. The mailbox TTL is deliberately not
    /// exposed: it's a delivery guarantee for undelivered messages, not disposable cache.
    #[uniffi::constructor]
    pub fn attach_with_limits(
        node: Arc<HavenNode>,
        dir: String,
        media_max_age_days: u32,
        media_max_bytes: u64,
    ) -> Arc<Self> {
        let mut retention = haven_net::blobstore::Retention::default();
        if media_max_age_days > 0 {
            retention.media_max_age =
                Some(std::time::Duration::from_secs(u64::from(media_max_age_days) * 86_400));
        }
        if media_max_bytes > 0 {
            retention.media_max_bytes = Some(media_max_bytes);
        }
        node.node.enable_relay_with_retention(PathBuf::from(dir), retention);
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
    /// header with [`http_auth_header`]. Canonical self-sync slots (`haven/self/…`) are served
    /// under the owner-or-roster-device gate (same rule as iroh); legacy bare `self/…` keys stay
    /// iroh-only.
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

/// Embedded circle-hosted iroh-relay (DERP) — Haven fabric NAT fallback.
///
/// Separate listen socket from the messaging node (same-key second-endpoint scar). Hold this
/// object while hosting; drop stops the server. Desktop / macOS hosts call this; iOS usually does not.
#[derive(uniffi::Object)]
pub struct DerpServerHandle {
    public_url: String,
    local_addr: String,
    local_port: u16,
    _server: haven_net::DerpServer,
}

#[uniffi::export(async_runtime = "tokio")]
impl DerpServerHandle {
    /// Start DERP on `bind` (e.g. `127.0.0.1:3340`). `public_url` may be empty until a tunnel is up.
    #[uniffi::constructor]
    pub async fn spawn(bind: String, public_url: String) -> Result<Arc<Self>, HavenError> {
        let cfg = haven_net::DerpConfig {
            enabled: true,
            bind,
            public_url: public_url.trim().trim_end_matches('/').to_string(),
        };
        let server = haven_net::DerpServer::spawn(&cfg)
            .await
            .map_err(|e| HavenError::Invalid {
                msg: format!("derp spawn: {e}"),
            })?
            .ok_or_else(|| HavenError::Invalid {
                msg: "derp disabled".into(),
            })?;
        let local_addr = server.local_addr.to_string();
        let local_port = server.local_port();
        let public_url = server.public_url.clone();
        Ok(Arc::new(Self {
            public_url,
            local_addr,
            local_port,
            _server: server,
        }))
    }

    /// Public HTTPS base for RelayMap / frame-19 `derp` (may be empty until tunnel assigns one).
    pub fn public_url(&self) -> String {
        self.public_url.clone()
    }

    /// Local bind address actually used.
    pub fn local_addr(&self) -> String {
        self.local_addr.clone()
    }

    /// Local TCP port for a second cloudflared quick tunnel.
    pub fn local_port(&self) -> u16 {
        self.local_port
    }
}

/// Local path-based reverse proxy: one public origin → media mailbox + iroh DERP by path.
///
/// `/relay`, `/derp`, `/ping` → DERP backend; everything else → media. Used so free trycloudflare
/// and single-hostname named tunnels front both roles without a second cloudflared process.
#[derive(uniffi::Object)]
pub struct PathRouterHandle {
    local_addr: String,
    local_port: u16,
    _router: haven_net::PathRouter,
}

#[uniffi::export(async_runtime = "tokio")]
impl PathRouterHandle {
    /// Bind `bind` (e.g. `127.0.0.1:8675`) and proxy to media/derp host:port backends.
    /// Also serves `/webrtc/hairpin` WebSocket call-media hairpin (free Cloudflare OK).
    /// `http_token` optional: if join JSON includes `token`, it must match.
    #[uniffi::constructor]
    pub async fn spawn(
        bind: String,
        media_backend: String,
        derp_backend: String,
        http_token: String,
    ) -> Result<Arc<Self>, HavenError> {
        let cfg = haven_net::PathRouterConfig {
            bind,
            media_backend,
            derp_backend,
            http_token,
        };
        let router = haven_net::PathRouter::spawn(&cfg)
            .await
            .map_err(|e| HavenError::Invalid {
                msg: format!("path router spawn: {e}"),
            })?
            .ok_or_else(|| HavenError::Invalid {
                msg: "path router disabled".into(),
            })?;
        let local_addr = router.local_addr.to_string();
        let local_port = router.local_port();
        Ok(Arc::new(Self {
            local_addr,
            local_port,
            _router: router,
        }))
    }

    pub fn local_addr(&self) -> String {
        self.local_addr.clone()
    }

    pub fn local_port(&self) -> u16 {
        self.local_port
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

/// One activity row for the UI — who did what to my content, and where (see
/// `HavenSocial::activity`).
#[derive(uniffi::Record)]
pub struct ActivityItemFfi {
    /// The originating event's id.
    pub id: String,
    /// `"react" | "comment" | "vote" | "post" | "story" | "dm"`.
    pub kind: String,
    /// Which circle it happened in (`dm:`-prefixed for DMs).
    pub circle_id: String,
    /// The actor's FULL node hex + 8-char display prefix for contact lookup.
    pub actor_hex: String,
    pub actor_short: String,
    /// The parent post/comment/poll id where applicable (reactions, comments, votes).
    pub target_id: Option<String>,
    /// Body prefix (~120 chars) for the preview line.
    pub snippet: String,
    pub created_at: u64,
    /// The reaction emoji (kind == "react").
    pub emoji: Option<String>,
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
/// ticket. The bytes it moves are already E2E-encrypted by `haven-p2p`.
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

    /// Close the underlying iroh endpoint so a same-seed restart is safe (no dual endpoint
    /// under one key). Await this, drop all app references, then call [`HavenNode::start`] again
    /// after [`apply_derp_urls`] when fabric is learned mid-session.
    pub async fn shutdown(&self) {
        self.node.shutdown().await;
    }

    /// This node's id (== the account's Haven id), as hex.
    pub fn node_id_hex(&self) -> String {
        self.node.node_id_hex()
    }

    /// A relay client that dials `relay_node_hex` over THIS node's WARM, DERP-established endpoint, instead
    /// of RelayClient::connect binding a fresh endpoint that cold-starts DERP on every fetch (the reason a
    /// cross-network relay GET timed out at 30s while messaging showed "Connected · Relay"). Reuses the
    /// same endpoint that keeps the messaging/relay path alive, so media fetches actually complete.
    pub async fn relay_client(&self, relay_node_hex: String) -> Result<Arc<RelayClient>, HavenError> {
        // The CACHED client — see `Node::blob_client_cached`. Building a fresh one per call meant the
        // connection restarted cold (on the DERP relay path) whenever the caller's own cache dropped
        // it, and a cold blob connection that is torn down before it can hole-punch never carries
        // anything cross-NAT.
        let inner = self
            .node
            .blob_client_cached(&relay_node_hex)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("relay client: {e}") })?;
        Ok(Arc::new(RelayClient { inner }))
    }

    /// Publish MY account's device ids to the public pkarr directory, keyed by my ACCOUNT id.
    ///
    /// This is what makes relays optional. A contact holds my account id (that's what an invite/QR
    /// carries) but dials my DEVICE ids — and until now the only ways to learn those were my signed
    /// roster or an invite `?d=` hint, both of which need a route to arrive in the first place. If
    /// the two of us shared no relay, that route never existed and nothing flowed, even with both
    /// devices online and iroh perfectly able to hole-punch between them. Publishing the mapping
    /// under the account key closes the loop: account id → device ids → iroh's own address lookup.
    ///
    /// Idempotent and cheap — call it on launch and whenever the roster changes. Returns the ids
    /// published (empty on a seedless device, which has no account key: its primary publishes).
    pub async fn publish_account_devices(&self, social: Arc<HavenSocial>) -> Result<Vec<String>, HavenError> {
        let Some(secret) = social.account_secret_bytes() else { return Ok(Vec::new()) };
        let ids = social.discovery_device_ids();
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        self.node
            .publish_account_devices(&secret, &ids)
            .map_err(|e| HavenError::Invalid { msg: format!("publish devices: {e}") })?;
        Ok(ids)
    }

    /// Look up a contact's device ids by their ACCOUNT id. Empty when they've never published (any
    /// build older than this one), so callers must keep every existing dial path — this only ADDS
    /// targets when we'd otherwise have none.
    ///
    /// The record is a pkarr signed packet under the account key, so only that account can write it.
    /// Even so, treat the result as a dial HINT, never an authorization: content stays sealed to the
    /// circle epoch key and inbound frames stay gated on the signed roster, so a stale or hostile
    /// record costs a wasted connect attempt and nothing else.
    pub async fn resolve_account_devices(&self, account_hex: String) -> Result<Vec<String>, HavenError> {
        self.node
            .resolve_account_devices(&account_hex)
            .await
            .map_err(|e| HavenError::Invalid { msg: format!("resolve devices: {e}") })
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
/// MLS M6 (§6.5): per-circle in-session state for the DM/live-lane per-message ratchet. NOT
/// persisted — a pure session cache like `cached_commit`/`mls_live_epoch`. Keeping it out of the
/// state blob is BOTH the OFF-byte-identical guarantee (persistence is untouched) AND a stronger FS
/// posture: skipped keys never hit disk, and a restart re-derives the in-order chain from the
/// (persisted) epoch `sender_key` while any window missed while offline is recovered by the
/// epoch-keyed re-seal backstop (§6.1). Chains are keyed by CONTENT epoch, so an epoch rotation
/// naturally strands the old chain for pruning ("epoch rotation resets the chain").
#[derive(Default)]
struct RatchetLanes {
    /// My OUTGOING DM ratchet per content epoch (`SenderChain`).
    send: HashMap<u64, treekem::SenderChain>,
    /// A peer's INCOMING DM ratchet per (peer account hex, content epoch) — the skipped-key cache
    /// lives here, bounded per `treekem::RATCHET_MAX_SKIPPED`.
    recv: HashMap<(String, u64), treekem::RatchetReceiver>,
}

struct Circle {
    /// Set when this circle's epoch ADVANCES, cleared by `take_epoch_moved`. Deliberately absent
    /// from `PersistCircle`: it is a signal about THIS session, and a restart re-seals anyway.
    epoch_moved: bool,
    /// Tree envelopes (MLS commit / welcome / join) that arrived and did NOT apply — usually
    /// out-of-order under churn. The THIRD instance of the mark-seen-on-failure trap: content got
    /// `pending_epoch`, rosters got a status code, and tree envelopes had NOTHING — a burned commit
    /// forked the fleet (A's devices sealing at epoch N while the joiner sat at N+1, each side
    /// parking the other's content forever). Replayed by `drain_pending_tree` whenever any tree
    /// envelope APPLIES or a roster is stored. Bounded + deduped; persisted like `pending_epoch`.
    pending_tree: Vec<Vec<u8>>,
    /// Per-poll replay attempts since the buffer last CHANGED — bounds the poll-driven retry.
    pending_tree_retries: u8,
    id: String,
    name: String,
    members: Vec<HavenId>,
    /// Members explicitly removed from this circle — a durable tombstone the ENGINE honors, so a
    /// removal survives a state merge instead of being silently re-grown. `members` is unioned on
    /// every `merge_circle` (multi-device sync / reload), and without this a member you removed on one
    /// device reappears the moment another device's still-has-them state merges back. Removal adds to
    /// this set; an explicit re-add (`add_contact_bundle` / `add_existing_to_circle`) clears it.
    removed_members: Vec<HavenId>,
    events: Vec<Event>,
    seen: HashSet<String>,
    my_epoch: u64,
    my_epoch_keys: HashMap<u64, [u8; 32]>,
    peer_epoch_keys: HashMap<(String, u64), [u8; 32]>,
    /// LOSING candidates for an epoch slot, kept so content sealed under them still opens.
    /// Since device-signed commits (seed-drop S3), an account's devices each mint a RANDOM key for
    /// the same (account, epoch) until they converge on the numerically-larger one — so COMPETING
    /// commits for one slot are the NORM, not a glitch. The primary maps hold the deterministic
    /// winner (max), these hold the bounded losers ([`ALT_KEYS_PER_SLOT`]). Adopting last-writer
    /// into the primary instead used to FLIP the slot on every re-offered commit and report
    /// "changed" each time — the relay-hosting Mac turned that into an infinite re-ingest storm
    /// (16.8 GB / 5 min) and every other platform silently kept whichever key polled last.
    my_epoch_keys_alt: HashMap<u64, Vec<[u8; 32]>>,
    peer_epoch_keys_alt: HashMap<(String, u64), Vec<[u8; 32]>>,
    pending_epoch: Vec<Vec<u8>>,
    /// My STABLE circle secret (zeros = not yet generated) — derives opaque storage-key prefixes for
    /// my blobs; distributed in my key commits. Peers' secrets are stored so I can find their blobs.
    my_circle_secret: [u8; 32],
    peer_circle_secrets: HashMap<String, [u8; 32]>,
    /// Unix seconds when my epoch last advanced (0 = not yet stamped — legacy state, or a circle that
    /// has never rotated). Drives the periodic rotation in [`Circle::rotate_if_stale`]; persisted, so
    /// relaunching doesn't restart the window.
    rotated_at: u64,
    /// Session cache of the last sealed key commit: (context hash over epoch/key/secret/recipients,
    /// tagged wire bytes). The KEM inside a commit is necessarily random, so re-sealing one for the
    /// SAME context produces different bytes — and the content-addressed mailbox then stores a new
    /// copy per backfill run. Reusing the cached bytes while the context is unchanged keeps the
    /// mailbox key stable (events are handled separately: their sealing is fully deterministic).
    cached_commit: Option<([u8; 32], Vec<u8>)>,
    /// MLS M3: the PINNED circle creator (root of Remove/Add authority, §4.3), as an account node id.
    /// `None` on a circle whose creator we haven't learned. Set locally when we create a circle and
    /// carried on the control lane; every member agrees on it (or the authority set is empty and no
    /// tree Remove is accepted). Persisted (additive).
    creator: Option<[u8; 32]>,
    /// AUDIT M2: is `creator` bound to the AUTHENTICATED circle definition (established at creation /
    /// via `set_circle_creator` / adopted from a signed circle-sync record), rather than TOFU-learned
    /// from the first admin grant? A grant can only ever *weakly* TOFU-learn a creator when we hold
    /// none (and never sets this flag); it can NEVER override a definition-pinned creator. This closes
    /// the first-grant-wins wedge (`receive_admin_grant`): a malicious member can no longer race a
    /// self-signed grant to install itself as a victim's authority root and permanently reject the real
    /// creator. Persisted (additive; defaults false so old state = today's TOFU semantics).
    creator_pinned: bool,
    /// MLS M3: verified [`AdminGrant`] wire bytes riding the roster/control lane — the delegation edges
    /// `admin_closure` walks from the creator. Higher-version-wins per (admin_account); a forged/stale
    /// grant never reaches this vec (verified at ingest). Persisted (additive) and re-broadcast.
    admin_grants: Vec<Vec<u8>>,
    /// Verified [`CircleUpgrade`] offers seen on THIS (legacy) circle's lane — "my creator-bound
    /// successor is X". Each is signature-verified and successor-binding-checked at ingest, but is
    /// deliberately NOT acted on: a legacy circle has no authority root, so nothing can prove the
    /// offerer owned it. They are surfaced for the user to accept (`accept_circle_upgrade`), and more
    /// than one competing offer is a legitimate state the UI must show rather than resolve. Persisted
    /// (additive); an offer I authored also rides the bundle so members receive it.
    upgrade_offers: Vec<Vec<u8>>,
    /// The successor I FOLLOWED for this circle, if any — set only by my own `accept_circle_upgrade`.
    /// An offer is hidden on this and nothing else. Inferring "followed" from the successor merely
    /// existing with its creator pinned looked equivalent but wasn't: both of those are things a peer
    /// can arrange (it can hand me a circle id to stand up, and a grant naming the real creator pins
    /// it), which let a member permanently bury the offer they least want followed. Only my own act
    /// counts. Persisted (additive) so a restart doesn't resurface an offer I already took.
    followed_upgrade: Option<String>,
    /// MLS M3: the live tree-derived content epoch (`MLS_EPOCH_BASE + tree_epoch`) when the keying flip
    /// is active for this circle (§4.5), else `None` (shadow or parked). Set by `mls_refresh_keying`,
    /// read by the author/re-seal paths so content seals under the tree key. NOT persisted — it is a
    /// pure function of the tree chain + the master switch, recomputed every bundle/receive.
    mls_live_epoch: Option<u64>,
    /// MLS M6 (§6.5): DM/live-lane per-message ratchet chains. NOT persisted (see [`RatchetLanes`]).
    mls_ratchet: RatchetLanes,
}

/// How long an epoch may live before the periodic rotation retires it (audit C2). SEVEN DAYS —
/// chosen against the delivery model, not for feel:
///
/// * **Floor — it must not outrun the full re-seal.** Only a full-history bundle carries the new key
///   commit *and* every one of my events re-sealed under it. Between a rotation and the next full
///   bundle, a relay-only peer holds mailbox envelopes sealed under an epoch whose commit it may not
///   have (they sit in `pending_epoch`). Clients run the full bundle roughly daily, so a weekly
///   rotation leaves ~7x margin. Rotating *faster* than the re-seal cadence would strand readers.
/// * **Offline peers are safe at any cadence.** A peer gone for weeks is handed the CURRENT commit
///   plus my whole history re-sealed under it — it never needs a key it slept through. That's what
///   frees the interval to be conservative; correctness doesn't pull it shorter.
/// * **Ceiling — cost.** Every rotation re-seals and re-uploads my history (a hybrid signature per
///   event, then a fresh content-addressed mailbox entry per envelope). Weekly keeps that bounded on
///   phone batteries and metered data; daily would pay it 7x to shrink a window that
///   `prune_epoch_keys` (KEEP_EPOCHS = 4) already bounds.
///
/// Net effect: a later seed compromise decrypts at most the current epoch plus the 3 retained ones
/// (~4 weeks) of captured wire/relay ciphertext, instead of the circle's entire history.
const ROTATE_INTERVAL_SECS: u64 = 7 * 24 * 60 * 60;

/// Wall clock in unix seconds (0 if the clock predates the epoch — treated as "unstamped").
/// Rotation is time-driven, so tests override this to jump weeks ahead without sleeping.
fn now_secs() -> u64 {
    let real = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    #[cfg(test)]
    {
        real + TEST_CLOCK_SKEW.load(std::sync::atomic::Ordering::Relaxed)
    }
    #[cfg(not(test))]
    real
}

/// Test-only clock offset in seconds — lets the rotation tests advance time deliberately.
#[cfg(test)]
mod low_data_ffi_tests {
    use super::*;

    const LINKS: [LinkConstraint; 3] =
        [LinkConstraint::Normal, LinkConstraint::Low, LinkConstraint::Ultra];
    const TRAFFIC: [Traffic; 12] = [
        Traffic::Text,
        Traffic::KeyConvergence,
        Traffic::Presence,
        Traffic::Preview,
        Traffic::Media,
        Traffic::Thumbnail,
        Traffic::LinkPreview,
        Traffic::Story,
        Traffic::Call,
        Traffic::HistoryBackfill,
        Traffic::SelfSync,
        Traffic::Enrollment,
    ];

    /// The FFI enums are a hand-written mirror of `haven_p2p::transport`, so the one thing that can
    /// rot is the mapping. Sweep the whole cross-product and require the mirror to agree with the
    /// source table on every cell — a mis-wired `From` arm cannot survive this.
    #[test]
    fn the_ffi_mirror_agrees_with_the_core_table_on_every_cell() {
        for link in LINKS {
            for t in TRAFFIC {
                let via_ffi = low_data_allowance_on(link, t);
                let via_core: Allowance = transport::allowance(link.into(), t.into()).into();
                assert_eq!(via_ffi, via_core, "{link:?} x {t:?}");
            }
        }
    }

    /// The reported constraint round-trips, and drives the no-argument entry point the call sites
    /// actually use.
    #[test]
    fn reported_constraint_drives_the_default_entry_point() {
        set_link_constraint(LinkConstraint::Normal);
        assert_eq!(link_constraint(), LinkConstraint::Normal);
        assert!(!low_data_active());
        assert_eq!(low_data_allowance(Traffic::Story), Allowance::Allow);

        set_link_constraint(LinkConstraint::Ultra);
        assert_eq!(link_constraint(), LinkConstraint::Ultra);
        assert!(low_data_active());
        assert_eq!(low_data_allowance(Traffic::Story), Allowance::Deny);
        assert_eq!(low_data_allowance(Traffic::Text), Allowance::Allow);
        assert_eq!(low_data_allowance(Traffic::Media), Allowance::AskFirst);

        // Leave the process as we found it — this is global state shared with every other test.
        set_link_constraint(LinkConstraint::Normal);
    }
}

#[cfg(test)]
static TEST_CLOCK_SKEW: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

impl Circle {
    fn bare(id: String, name: String) -> Self {
        Circle {
            epoch_moved: false,
            pending_tree: vec![],
            pending_tree_retries: 0,
            id,
            name,
            members: vec![],
            removed_members: vec![],
            events: vec![],
            seen: HashSet::new(),
            my_epoch: 0,
            my_epoch_keys: HashMap::new(),
            peer_epoch_keys: HashMap::new(),
            my_epoch_keys_alt: HashMap::new(),
            peer_epoch_keys_alt: HashMap::new(),
            pending_epoch: vec![],
            my_circle_secret: [0u8; 32],
            peer_circle_secrets: HashMap::new(),
            rotated_at: 0,
            cached_commit: None,
            creator: None,
            creator_pinned: false,
            admin_grants: vec![],
            upgrade_offers: vec![],
            followed_upgrade: None,
            mls_live_epoch: None,
            mls_ratchet: RatchetLanes::default(),
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
        self.epoch_moved = true;
        self.my_epoch_keys.insert(self.my_epoch, new_epoch_key());
        // ANY rotation restarts the periodic window — a membership change already gave us a fresh
        // epoch, so the timer shouldn't immediately hand out another.
        self.rotated_at = now_secs();
        self.prune_epoch_keys();
    }

    /// Advance the epoch if the current one has outlived [`ROTATE_INTERVAL_SECS`] — the PERIODIC case
    /// of forward secrecy (audit C2). Returns true if it rotated.
    ///
    /// Callers must only invoke this where a FULL re-seal of my history follows in the same bundle
    /// (see [`HavenSocial::epoch_sync_bundle_inner`]); rotating anywhere else publishes an epoch
    /// without the re-seal that makes old content readable under it.
    fn rotate_if_stale(&mut self) -> bool {
        self.ensure_epoch();
        let now = now_secs();
        // Not yet stamped (legacy state / first bundle), or a wall clock that jumped BACKWARDS: start
        // the window here. Without the backwards guard a clock skew would rotate on every call.
        if self.rotated_at == 0 || self.rotated_at > now {
            self.rotated_at = now;
            return false;
        }
        if now - self.rotated_at < ROTATE_INTERVAL_SECS {
            return false;
        }
        self.rotate_epoch(); // stamps rotated_at
        true
    }

    /// PCS cadence window (§6.4): true iff the current epoch has outlived [`ROTATE_INTERVAL_SECS`] —
    /// the SAME weekly window `rotate_if_stale` uses, so the MLS leaf-Update cadence inherits the one
    /// safe chokepoint with no new timer. Mirrors `rotate_if_stale`'s handling of an unstamped /
    /// backwards clock (stamp here, don't fire) but performs NO legacy rotation: when the tree keys
    /// content the committer authors a leaf Update instead of minting a random epoch key. Shares
    /// `rotated_at` with the legacy path and with roster commits, so the two never double-rotate.
    fn pcs_window_elapsed(&mut self) -> bool {
        self.ensure_epoch();
        let now = now_secs();
        if self.rotated_at == 0 || self.rotated_at > now {
            self.rotated_at = now;
            return false;
        }
        now - self.rotated_at >= ROTATE_INTERVAL_SECS
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
        // Alt (loser) keys live and die with their slot's primary — same retention window.
        self.my_epoch_keys_alt.retain(|e, _| self.my_epoch_keys.contains_key(e));
        self.peer_epoch_keys_alt.retain(|k, _| self.peer_epoch_keys.contains_key(k));
        // M6 (§6.5): drop any ratchet chain whose content epoch fell out of the retained window —
        // the chains age out on the SAME pruner as their epoch key, and dropping wipes them (the
        // `Drop` impls on `SenderChain`/`RatchetReceiver` zero every held key, incl. cached skipped
        // keys). This is the FS + bounded-memory discipline: no chain (and no skipped-key cache) can
        // outlive its epoch. `send` is keyed by my own content epoch; `recv` by (peer, content
        // epoch), matching the pruned key stores above.
        self.mls_ratchet.send.retain(|e, _| self.my_epoch_keys.contains_key(e));
        self.mls_ratchet
            .recv
            .retain(|(peer, e), _| self.peer_epoch_keys.contains_key(&(peer.clone(), *e)));
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
    /// LOSING keys retained for the slot (see the alt maps on [`Circle`]): tried in order when the
    /// primary fails to open a non-ratcheted envelope — content sealed pre-convergence stays readable.
    fn alt_keys_for(&self, me_hex: &str, author_hex: &str, epoch: u64) -> Vec<[u8; 32]> {
        if author_hex == me_hex {
            self.my_epoch_keys_alt.get(&epoch).cloned().unwrap_or_default()
        } else {
            self.peer_epoch_keys_alt.get(&(author_hex.to_string(), epoch)).cloned().unwrap_or_default()
        }
    }
}

/// Losers kept per epoch slot. Two devices per account is the norm, three the realistic ceiling —
/// beyond that the weekly rotation + re-seal backstop recovers anything sealed under a dropped key.
const ALT_KEYS_PER_SLOT: usize = 4;

/// Deterministically converge an epoch-key slot on a new candidate: the numerically-larger key wins
/// the primary (every device applies the same rule, so all replicas agree without coordination); the
/// loser is retained in `alts` (bounded) so envelopes sealed under it still open. Returns whether
/// this candidate taught us anything new (primary changed, or a previously-unknown loser was kept) —
/// re-applying a known key is a reported no-op, which is what makes mailbox re-offers convergent
/// instead of an infinite "state changed" loop.
fn converge_epoch_key(primary: &mut Option<[u8; 32]>, alts: &mut Vec<[u8; 32]>, candidate: [u8; 32]) -> bool {
    match *primary {
        None => {
            *primary = Some(candidate);
            true
        }
        Some(cur) if cur == candidate => false,
        Some(cur) => {
            let (winner, loser) = if candidate > cur { (candidate, cur) } else { (cur, candidate) };
            let mut changed = false;
            if winner != cur {
                *primary = Some(winner);
                changed = true;
            }
            if !alts.contains(&loser) {
                if alts.len() >= ALT_KEYS_PER_SLOT {
                    alts.remove(0);
                }
                alts.push(loser);
                changed = true;
            }
            changed
        }
    }
}

struct NetState {
    /// My ACCOUNT public bundle — ALWAYS present: authorship id, my node id, the contact id friends pin,
    /// the roster verification anchor, and every `hex(...)` display site. Seed-drop S4 split the old
    /// `me: Identity` into this always-present public half plus [`Self::me_secret`], so every account
    /// *private-key* use became a compile-checked decision (see `me_secret_or`).
    me_pub: HavenId,
    /// My ACCOUNT signing identity: `Some` on a primary/legacy device (holds the master seed), `None` on a
    /// SEEDLESS device (seed-drop S4 — enrolled with a device key + credential + granted self-sync key, but
    /// NEVER the account seed). A seedless device therefore cannot sign a roster, mint a profile card, or
    /// author under the account key — every such site branches on this `Option`, which is the whole point of
    /// the refactor (a missed guard is a compile error, not a runtime forgery).
    me_secret: Option<Identity>,
    /// The primary-signed roster WIRE bytes (tagged `TAG_DEVICE_ROSTER`, incl. the SeedDropCapability
    /// trailer) that a SEEDLESS device holds for its OWN account (A3). A seedless device cannot re-mint this
    /// (no account key), so it persists + rebroadcasts these exact bytes VERBATIM — re-encoding would strip
    /// the primary-signed trailer and stall the circle's capability convergence (§7). `None` on a primary
    /// (which signs its roster fresh at each emit) and until the grant/sync delivers my roster.
    seedless_roster_wire: Option<Vec<u8>>,
    /// My signed profile "business card" — cached so a SEEDLESS device (which cannot sign one, D8) can
    /// rebroadcast the primary's card verbatim, and so a primary re-serves the same bytes across launches.
    /// The primary mints + caches it in `my_signed_profile`; a seedless device receives the primary's card
    /// via self-sync / full-state push and installs it with `set_cached_profile`. `None` until first set.
    cached_profile: Option<Vec<u8>>,
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
    /// Accounts we have AFFIRMATIVELY verified as seed-drop-capable (their signed `seedDrop` marker
    /// checked out), keyed by account node id (D16 Phase 2 / S0). **Monotonic — insert only, never
    /// remove**: a missing entry means "unknown, treat as legacy," never "downgraded" (absence is never
    /// information). Populated as signed rosters/profiles arrive; consulted by the dual-seal GATE, which is
    /// OFF this release, so nothing here changes what a circle seals to yet. Not persisted — it rebuilds
    /// as rosters/profiles re-sync.
    seed_drop_capable: std::collections::HashSet<[u8; 32]>,
    /// Accounts we have AFFIRMATIVELY verified as MLS(TreeKEM)-capable — their signed profile carried
    /// `ml >= 1` (TreeKEM M0, docs/TREEKEM-DESIGN.md §7.1) — keyed by account node id. **Monotonic —
    /// insert only, never remove**: a missing entry means "unknown, treat as legacy," never
    /// "downgraded" (absence is never information). Carried in the signed PROFILE only, never the
    /// roster trailer (see `MLS_VERSION`). Consulted by nothing in production yet
    /// (`circle_fully_mls_capable` ships OFF); populated so the fleet's capability picture is already
    /// converged when a later release flips the gate. Not persisted — rebuilds as profiles re-sync.
    mls_capable: std::collections::HashSet<[u8; 32]>,
    /// Accounts we have AFFIRMATIVELY verified as able to READ the compact envelope container —
    /// their signed profile carried `cw >= 1` (docs/SATELLITE-DESIGN.md §6). Keyed by account node
    /// id. **Monotonic — insert only, never remove**: a missing entry means "unknown, treat as
    /// legacy," never "downgraded." Unlike `seed_drop_capable` / `mls_capable`, this one is LIVE:
    /// `circle_fully_compact_wire_capable` consults it on every send, and a single unknown member
    /// keeps that circle on JSON. Not persisted — it rebuilds as profiles re-sync, and rebuilding
    /// empty is the safe direction (we fall back to the container everyone can read).
    compact_wire_capable: std::collections::HashSet<[u8; 32]>,
    /// Viewer preference: keep MY OWN posts in the feed even when viewer auto-delete would age them
    /// out for others (my personal archive). Read by `feed`; set via `set_keep_own_posts`. Not
    /// persisted here — the app owns the toggle and re-applies it on launch.
    keep_own_posts: bool,
    /// Seed-drop RETIREMENT master switch (D16 Phase 2 / S5). When true, a circle whose every member is
    /// affirmatively seed-drop-capable (`circle_fully_seed_drop_capable`) stops sealing to the bare
    /// per-member ACCOUNT key and seals ONLY to authorized device bundles — so a revoked device is cut off
    /// even from a member who still holds the account seed. Defaults **false**: the sealing set is then
    /// byte-identical to today's dual-seal, keeping the wiring strictly additive. Flipped on (per staged
    /// beta, after a dual-seal soak) via `set_seed_drop_retire`; a mixed-version circle with a single
    /// non-capable member never drops the account key regardless (all-present-positive gate). Not persisted
    /// — the app re-applies it on launch, same as `keep_own_posts`.
    retire_account_key: bool,
    /// TreeKEM M2 SHADOW state, per circle id (`docs/TREEKEM-DESIGN.md` §9 row M2). For a circle
    /// where `circle_fully_mls_capable` holds, the elected creator builds a ratchet tree from the
    /// SAME roster/membership the sender-keys epoch runs on, and every device derives the tree's
    /// epoch secret in PARALLEL. It is **never consumed for content keys** (that flip is M3) — it
    /// exists only to be COMPARED via `mls_shadow_status` telemetry (the soak signal). Empty for a
    /// non-capable circle (shadow doesn't run). Not persisted: it rebuilds from the commit + welcome
    /// re-emitted in every bundle, exactly like `mls_capable`/`seed_drop_capable` rebuild from sync.
    shadow_trees: std::collections::HashMap<String, ShadowTree>,
    /// MLS M3 KEYING master switch (docs/TREEKEM-DESIGN.md §4.5/§7.2). Mirrors `retire_account_key`
    /// EXACTLY: default **false**, NOT persisted, the app re-applies it on launch. When false the tree
    /// runs in M2 shadow only and content is byte-identical to today (the no-regression proof). When
    /// true, a circle that is fully-MLS-capable AND all-joined (§7.2) draws its content epoch key from
    /// the tree (§4.5) and STOPS emitting the legacy KeyCommit; a circle that isn't all-joined stays
    /// dual-stack, and one a legacy device (re)joins PARKS back to KeyCommit within one bundle (§7.3).
    /// Ships DARK so this lands like seed-drop retirement; flipped ON per staged cohort after soak.
    mls_keying: bool,
    /// MLS M6 (§6.5): circle ids the app has marked as the DM / LIVE lane — the ONLY lane the
    /// per-message ratchet engages on (feed circles stay epoch-keyed, per the task scope). Session
    /// state, NOT persisted: the app re-marks its DM circles on launch, mirroring `mls_keying` /
    /// `retire_account_key`. Consulted ONLY inside the `mls_keying`-ON author path, so with the
    /// master switch OFF this set is never read and content is byte-identical to today.
    live_lane_circles: std::collections::HashSet<String>,
}

impl NetState {
    /// My account public bundle — always present (authorship id, contact id, roster verification anchor).
    /// The `st.me.public()` sites collapse to `st.me()`; sites needing an owned bundle use `st.me().clone()`.
    fn me(&self) -> &HavenId {
        &self.me_pub
    }

    /// The identity that signs outgoing content when the account key is available — the ACCOUNT key on a
    /// primary/legacy device, the DEVICE key on a seedless one (which holds no account key). Preferring the
    /// account key when present keeps a seeded device's output byte-identical AND readable by pre-S4 peers;
    /// a seedless device has only its device key, so account-attributed artifacts it signs need the S4.4/S4.5
    /// receive-side device→account acceptance to be openable (a documented, bounded follow-on).
    fn account_or_device_signer(&self) -> &Identity {
        self.me_secret
            .as_ref()
            .or(self.device.as_ref())
            .expect("a seedless device always holds its device identity")
    }

    /// My own roster wire to broadcast. A primary re-signs it fresh (minting the capability trailer live);
    /// a SEEDLESS device (no account key) rebroadcasts the primary-signed wire it was granted, VERBATIM, so
    /// the trailer survives (§7 capability fidelity). `None` until I hold my roster.
    fn own_roster_wire(&self) -> Option<Vec<u8>> {
        match &self.me_secret {
            Some(me) => {
                let me_pub = self.me_pub.clone();
                self.device_lists
                    .get(&me_pub.node_id_bytes())
                    .map(|cd| my_roster_wire(me, &me_pub, cd))
            }
            None => self.seedless_roster_wire.clone(),
        }
    }
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
    let removed_id = c.members.iter().find(|m| hex(&m.node_id_bytes()) == node_hex).cloned();
    let was_member = removed_id.is_some();
    c.members.retain(|m| hex(&m.node_id_bytes()) != node_hex);
    // Tombstone the removal so a later state merge can't silently re-grow them (multi-device sync).
    if let Some(id) = removed_id {
        if !c.removed_members.iter().any(|m| m.node_id_bytes() == id.node_id_bytes()) {
            c.removed_members.push(id);
        }
    }
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

/// The media content-refs an event carries — what a purge must hand back for blob GC.
fn event_media_refs(kind: &EventKind) -> &[String] {
    match kind {
        EventKind::Post { media, .. }
        | EventKind::Comment { media, .. }
        | EventKind::Edit { media, .. } => media,
        _ => &[],
    }
}

/// REAL deletion behind auto-delete. `build_feed` only HIDES expired items; without this sweep
/// they sit in `Circle.events` forever and get re-sealed into every sync/backfill bundle —
/// "deleted" content that still ships to every peer breaks the feature's privacy promise.
///
/// Sender-set retention (`Post.retention_secs`) purges unconditionally: it's the author's promise
/// to the whole circle. `viewer_retention_secs` is the circle's configured auto-delete (the app
/// passes its per-circle setting, NOT an individual viewer's whim), and `keep_own_author` mirrors
/// the feed's keep-my-posts exemption so a personal archive isn't destroyed by the circle default.
/// The effective window is the shorter of the two — the same `is_expired` the feed hides with, so
/// purge and display can never disagree. Messages and Polls carry no sender retention and get no
/// keep-own exemption, exactly as in `build_feed` (DMs are Messages — circle retention cleans them
/// too). Events targeting a purged event (comments, reactions, edits, unsends, votes, flags…) go
/// transitively via the same fixpoint as [`purge_member_from_circle`], and — same reasoning as
/// there — the `seen` dedup set is left intact so a re-delivered purged event is dropped by
/// `receive`, not resurrected.
///
/// Returns the purged events' media content-refs so the caller can GC blobs (blob deletion itself
/// is outside the core). Persistence needs nothing extra: `export_state` serializes
/// `Circle.events` (see `PersistCircle`), so the next save simply writes the smaller log.
fn purge_expired_from_circle(
    c: &mut Circle,
    viewer_retention_secs: Option<u64>,
    keep_own_author: Option<&str>,
    now_ms: u64,
) -> Vec<String> {
    let mut doomed: HashSet<String> = c
        .events
        .iter()
        .filter(|e| match &e.kind {
            EventKind::Post { retention_secs, .. } => {
                let viewer = if keep_own_author == Some(e.author.as_str()) {
                    None
                } else {
                    viewer_retention_secs
                };
                is_expired(e.created_at, *retention_secs, viewer, now_ms)
            }
            EventKind::Message { .. } | EventKind::Poll { .. } => {
                is_expired(e.created_at, None, viewer_retention_secs, now_ms)
            }
            // Targeted kinds live and die with their target — the fixpoint below catches them.
            _ => false,
        })
        .map(|e| e.id.clone())
        .collect();
    if doomed.is_empty() {
        return vec![];
    }
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
    let mut refs: Vec<String> = c
        .events
        .iter()
        .filter(|e| doomed.contains(&e.id))
        .flat_map(|e| event_media_refs(&e.kind).iter().cloned())
        .collect();
    refs.sort();
    refs.dedup();
    c.events.retain(|e| !doomed.contains(&e.id));
    refs
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// TreeKEM M2 — SHADOW mode (docs/TREEKEM-DESIGN.md §4, §5, §7, §9 row M2).
//
// For a circle where `circle_fully_mls_capable` holds, an elected creator builds a ratchet tree
// over the SAME roster the sender-keys epoch runs on, and every device derives the tree's epoch
// secret IN PARALLEL. That secret is NEVER consumed for content keys — content still seals under
// today's sender-keys + epochs (M0/M1/seed-drop, untouched). The tree is compared against reality
// via `mls_shadow_status` telemetry; the keying flip is M3. Every function below is inert with
// respect to content: it stores/derives shadow state and returns `false` from `receive` (no
// content change), so zero existing behavior moves.
//
// Genesis shape (§4.1, simplified for shadow): the creator builds an add-only commit (empty tree
// → one Add per authorized device of every member, no UpdatePath ⇒ commit_secret = 0, RFC 9420
// §12.4) and Welcomes every device its epoch's `joiner_secret`. A receiver reconstructs the tree
// from the commit's Adds (verifying `tree_hash`) and derives the identical epoch secret from the
// delivered `joiner_secret` — `treekem::welcome_epoch_schedule`. No UpdatePath decryption is on
// the wiring path: path-based key agreement is proven exhaustively in the pure M1 tests; M2's job
// is the chain/fork/welcome/telemetry plumbing. Creator election is per §4.1 (lowest ACCOUNT id);
// when the lowest account has multiple devices they each create, which forks at genesis and
// resolves via §5.1 `select_chain` — a real, observable soak signal, not an error.
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// One received (or self-authored) Welcome: the secrets a device needs to derive the epoch secret
/// of the commit it is keyed to. In M2/M3 this is a GENESIS Welcome (`tree_bytes` empty ⇒ the tree
/// is reconstructed from the genesis Adds). M4 adds SELF-CONTAINED entry (`docs/TREEKEM-DESIGN.md`
/// §4.2 mid-life Add, §5.5 sleeper re-entry): a mid-chain / re-entry Welcome carries `cth` (the
/// confirmed transcript hash at its epoch) and `tree_bytes` (the public tree as a content-addressed
/// blob) so a joiner enters at the LIVE epoch WITHOUT replaying the chain — never a genesis rebuild.
struct ShadowWelcome {
    epoch: u64,
    leaf_index: u32,
    /// The epoch's `joiner_secret` (§3.3) — with the public context this yields `epoch_secret`.
    joiner_secret: [u8; 32],
    /// This device's leaf secret (for participating in future path updates/removes).
    leaf_secret: [u8; 32],
    /// M4: the confirmed transcript hash at this Welcome's epoch. Empty-array for a genesis Welcome
    /// (reconstructed instead); set for a self-contained mid-chain / re-entry Welcome.
    cth: [u8; 32],
    /// M4: the serialized public tree at this epoch (a content-addressed blob, §4.6/design point 4).
    /// Empty for a genesis Welcome. Present ⇒ the joiner bootstraps epoch n directly from it (§5.5),
    /// so a sleeper past the mailbox TTL — which can no longer replay the pruned chain — still enters.
    tree_bytes: Vec<u8>,
}

/// Per-circle shadow ratchet-tree state. Holds the known genesis commit(s) — more than one is a
/// §5 fork — and the Welcomes this device holds. `mls_shadow_status` resolves the fork with
/// `select_chain` and derives the winner's epoch secret. Not persisted (rebuilds from re-emitted
/// commit + welcome), matching `mls_capable`/`seed_drop_capable`.
struct ShadowTree {
    /// The TreeKEM group id = the circle id bytes.
    group_id: Vec<u8>,
    /// Known genesis commits by `commit_hash` → full signed bytes. Two+ = a fork at epoch 1.
    commits: std::collections::BTreeMap<[u8; 32], Vec<u8>>,
    /// Welcomes I hold, keyed by the genesis commit hash they belong to.
    my_welcomes: std::collections::BTreeMap<[u8; 32], ShadowWelcome>,
    /// The genesis commit I authored (as elected creator), so I don't re-create every bundle.
    my_genesis: Option<[u8; 32]>,
    /// Cached tagged wire bytes I re-emit each bundle. Byte-stable so the content-addressed
    /// mailbox doesn't accumulate a copy per backfill (Welcomes wrap via a random KEM, so they
    /// MUST be cached — the same reasoning as `Circle::cached_commit`).
    emit_cache: Vec<Vec<u8>>,
    /// MLS M3: device ids that have emitted a JOIN ack for a genesis they hold the Welcome to — the
    /// §7.2 all-joined gate. A device joins by broadcasting `TAG_MLS_JOIN` once it holds its Welcome;
    /// the creator auto-joins on build. `all-joined` = every device leaf in the CURRENT tree is here.
    /// This is the second all-present-positive gate on top of `circle_fully_mls_capable`, so a member
    /// who never fetched its Welcome can never strand the circle in the flipped state.
    joined: std::collections::HashSet<[u8; 32]>,
    /// Which genesis each joined device announced (JOIN ack `gh`). A device not on the winning
    /// genesis is on the losing branch of an election fork; the committer re-Welcomes it. Not persisted.
    joined_genesis: std::collections::HashMap<[u8; 32], [u8; 32]>,
    /// MLS M3: the secret keying root this device uses when it is the committer (creator/admin) —
    /// derived from its DEVICE seed (§ leaf-secret secrecy), so leaf secrets + the genesis init are
    /// unknowable to a removed device even though the commit is public. Set at genesis build; unused
    /// by a pure receiver. Empty until built.
    my_secret_root: Option<[u8; 32]>,
    /// MLS M3: the sorted device-id leaf set my_genesis was built over. When the authorized device
    /// set GROWS (a straggler upgrades → §7.3 resume), this differs and the creator rebuilds genesis
    /// so the newcomer is Welcomed and the circle can re-flip. (A Remove SHRINKS the tree via a
    /// chained commit, not a rebuild, so the removed device stays cryptographically excluded.)
    genesis_devices: Vec<[u8; 32]>,
}

impl ShadowTree {
    fn new(group_id: Vec<u8>) -> Self {
        Self {
            group_id,
            commits: std::collections::BTreeMap::new(),
            my_welcomes: std::collections::BTreeMap::new(),
            my_genesis: None,
            emit_cache: Vec::new(),
            joined: std::collections::HashSet::new(),
            joined_genesis: std::collections::HashMap::new(),
            my_secret_root: None,
            genesis_devices: Vec::new(),
        }
    }
}

/// Deterministic per-group genesis constants (§5.1/§3.3): the genesis parent hash the first
/// commit chains to, the base transcript hash, and the base init secret. All must be identical on
/// every device, so each is a pure function of the group id alone.
fn shadow_domain_hash(domain: &[u8], gid: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(domain);
    h.update(gid);
    *h.finalize().as_bytes()
}
fn shadow_genesis_parent(gid: &[u8]) -> [u8; 32] {
    shadow_domain_hash(b"haven-mls-shadow-genesis-parent-v1", gid)
}
fn shadow_genesis_cth(gid: &[u8]) -> [u8; 32] {
    shadow_domain_hash(b"haven-mls-shadow-genesis-cth-v1", gid)
}
/// A committer's SECRET keying root, derived from its DEVICE secret seed (M3). Unlike the public
/// per-group genesis constants above, this is the secrecy anchor the removal re-key rests on: the
/// leaf secrets and genesis init the creator derives from it are UNKNOWABLE to a removed device,
/// even though the genesis commit itself is public. It stays DETERMINISTIC (a pure function of the
/// creator's device seed + group id), so the creator reproduces the same genesis across relaunches
/// (no self-fork); two different creator devices produce different roots ⇒ a §5.1 fork that resolves.
fn keying_secret_root(device_secret_seed: &[u8; 32], gid: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(b"haven-mls-keying-root-v1");
    h.update(device_secret_seed);
    h.update(gid);
    *h.finalize().as_bytes()
}
/// The SECRET leaf secret the committer assigns to `device_id` (derived from its secret root). Known
/// only to the committer (who generated it) and the device it is Welcomed to — so a removed device
/// cannot derive any OTHER remaining leaf's key and is excluded from the re-key path (§4.3).
fn keying_leaf_secret(secret_root: &[u8; 32], device_id: &[u8; 32]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(b"haven-mls-keying-leaf-v1");
    h.update(secret_root);
    h.update(device_id);
    *h.finalize().as_bytes()
}
/// The SECRET genesis init secret (`init_secret_0`) the committer feeds `build_commit` — secret, so
/// the genesis `joiner_secret` is delivered ONLY via the Welcome and is NOT derivable from the public
/// commit (contrast the shadow's public constant). This is what makes epoch 2's one-way link real.
fn keying_base_init(secret_root: &[u8; 32]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(b"haven-mls-keying-init-v1");
    h.update(secret_root);
    *h.finalize().as_bytes()
}
/// A committer's fresh leaf secret + encapsulation entropy for the UpdatePath it builds at `epoch`
/// (M3 removal re-key). Deterministic from its secret root + epoch so a REPLAY of its own commit
/// reproduces identical bytes (the rebuild-each-bundle model has no separate stored build state).
fn keying_update_material(secret_root: &[u8; 32], epoch: u64) -> ([u8; 32], [u8; 32]) {
    let mut h = blake3::Hasher::new();
    h.update(b"haven-mls-keying-upd-leaf-v1");
    h.update(secret_root);
    h.update(&epoch.to_le_bytes());
    let leaf = *h.finalize().as_bytes();
    let mut h = blake3::Hasher::new();
    h.update(b"haven-mls-keying-upd-ent-v1");
    h.update(secret_root);
    h.update(&epoch.to_le_bytes());
    (leaf, *h.finalize().as_bytes())
}

/// The account members whose devices populate the shadow tree (me + circle members).
fn circle_mls_accounts(st: &NetState, idx: usize) -> Vec<HavenId> {
    let mut accounts = vec![st.me().clone()];
    accounts.extend(st.circles[idx].members.iter().cloned());
    accounts
}

/// Does the all-present-positive MLS gate hold for this circle? (§7.2.) Composes seed-drop
/// capability (nested) with `ml`-capability + a known roster for every member.
/// Should this circle's outbound envelopes use the COMPACT container?
///
/// Only when every member has affirmatively advertised `cw` (docs/SATELLITE-DESIGN.md §6). One
/// unknown member — a contact still on an older build, or one whose profile has not reached us yet —
/// keeps the whole circle on JSON, because a client that cannot parse the container loses the
/// message outright and there is no renegotiation once the bytes are in the mailbox.
///
/// Note this also moves the circle's mailbox keys, which are `SHA256` over the envelope's exact wire
/// bytes. That is safe precisely BECAUSE the flip is all-or-nothing per circle: the author computes
/// the key from the bytes it uploads and seals that key into the push hint, so author and reader
/// agree, and event-id dedupe (`seen`) absorbs the one-time re-upload of anything re-sealed across
/// the boundary.
fn circle_is_compact_wire_capable(st: &NetState, idx: usize) -> bool {
    let accounts: Vec<HavenId> = st.circles[idx].members.clone();
    circle_fully_compact_wire_capable(&accounts, &st.compact_wire_capable)
}

fn circle_is_mls_capable(st: &NetState, idx: usize) -> bool {
    let accounts = circle_mls_accounts(st, idx);
    circle_fully_mls_capable(&accounts, &st.device_lists, &st.seed_drop_capable, &st.mls_capable)
}

/// Every authorized device (bundle + credential) of every member, deterministically ordered by
/// device node id — the tree's leaf set. Ordering is identical on all devices, so the leaf
/// indices agree.
fn shadow_device_leaves(st: &NetState, idx: usize) -> Vec<(HavenId, DeviceCredential)> {
    let accounts = circle_mls_accounts(st, idx);
    let mut out: Vec<(HavenId, DeviceCredential)> = Vec::new();
    let mut seen: HashSet<[u8; 32]> = HashSet::new();
    for a in &accounts {
        if let Some(cd) = st.device_lists.get(&a.node_id_bytes()) {
            for c in &cd.credentials {
                if cd.list.is_authorized(&c.device_id()) && seen.insert(c.device_id()) {
                    out.push((c.device.clone(), c.clone()));
                }
            }
        }
    }
    out.sort_by(|a, b| a.0.node_id_bytes().cmp(&b.0.node_id_bytes()));
    out
}

/// Am I the elected genesis creator for this circle? Per §4.1: the member with the
/// lexicographically-smallest ACCOUNT id creates. (A member with multiple devices under the
/// lowest account has each device create; the resulting genesis fork resolves via §5.1.)
fn am_shadow_creator(st: &NetState, idx: usize) -> bool {
    let my_acct = st.me().node_id_bytes();
    circle_mls_accounts(st, idx)
        .iter()
        .map(|a| a.node_id_bytes())
        .min()
        == Some(my_acct)
}

/// Encode a Welcome's secret payload (delivered sealed to a joiner's device bundle):
/// `commit_hash(32) ‖ epoch(8) ‖ leaf_index(4) ‖ joiner_secret(32) ‖ leaf_secret(32) ‖ cth(32)
/// ‖ u32 tree_len ‖ tree_bytes` (M4 appended `cth` + the content-addressed tree blob).
fn encode_shadow_welcome(commit_hash: &[u8; 32], w: &ShadowWelcome) -> Vec<u8> {
    let mut v = Vec::with_capacity(32 + 8 + 4 + 32 + 32 + 32 + 4 + w.tree_bytes.len());
    v.extend_from_slice(commit_hash);
    v.extend_from_slice(&w.epoch.to_le_bytes());
    v.extend_from_slice(&w.leaf_index.to_le_bytes());
    v.extend_from_slice(&w.joiner_secret);
    v.extend_from_slice(&w.leaf_secret);
    v.extend_from_slice(&w.cth);
    v.extend_from_slice(&(w.tree_bytes.len() as u32).to_le_bytes());
    v.extend_from_slice(&w.tree_bytes);
    v
}
fn decode_shadow_welcome(b: &[u8]) -> Option<([u8; 32], ShadowWelcome)> {
    // Fixed head + a length-prefixed tree blob; exact-consumption (no trailing bytes) so a
    // tampered/truncated payload fails closed rather than decoding into a plausible Welcome.
    const HEAD: usize = 32 + 8 + 4 + 32 + 32 + 32 + 4;
    if b.len() < HEAD {
        return None;
    }
    let commit_hash: [u8; 32] = b[0..32].try_into().ok()?;
    let epoch = u64::from_le_bytes(b[32..40].try_into().ok()?);
    let leaf_index = u32::from_le_bytes(b[40..44].try_into().ok()?);
    let joiner_secret: [u8; 32] = b[44..76].try_into().ok()?;
    let leaf_secret: [u8; 32] = b[76..108].try_into().ok()?;
    let cth: [u8; 32] = b[108..140].try_into().ok()?;
    let tree_len = u32::from_le_bytes(b[140..144].try_into().ok()?) as usize;
    if b.len() != HEAD + tree_len {
        return None;
    }
    let tree_bytes = b[HEAD..].to_vec();
    Some((commit_hash, ShadowWelcome { epoch, leaf_index, joiner_secret, leaf_secret, cth, tree_bytes }))
}

/// Resolve a shadow commit/welcome signer's device/account hex to its verifying bundle — the
/// same three-case resolution `receive_key_commit` uses (my account, a member account, or an
/// authorized device of a member/mine).
fn resolve_shadow_sender(st: &NetState, idx: usize, sender_hex: &str) -> Option<HavenId> {
    let me_hex = hex(&st.me().node_id_bytes());
    if sender_hex == me_hex {
        return Some(st.me().clone());
    }
    if let Some(m) =
        st.circles[idx].members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex).cloned()
    {
        return Some(m);
    }
    authorized_device_and_account(st, idx, sender_hex).map(|(bundle, _)| bundle)
}

/// Build (once) the elected creator's genesis commit + a Welcome for every device, and cache the
/// tagged wire bytes for idempotent re-emission. SHADOW — the derived epoch secret is stored for
/// telemetry only, never consumed for content. No-op if a genesis is already cached.
fn build_shadow_genesis(st: &mut NetState, idx: usize) {
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let devices = shadow_device_leaves(st, idx);
    if devices.len() < 2 {
        return; // a 1-leaf shadow group carries no signal; wait for the roster to fill in
    }
    let device_ids: Vec<[u8; 32]> = devices.iter().map(|(b, _)| b.node_id_bytes()).collect();
    // Idempotent. With KEYING ON (M4), build the genesis ONCE: when the authorized device set later
    // GROWS we no longer rebuild a superseding genesis (which reset the epoch and re-Welcomed the whole
    // fleet) — `mls_grow_tree` chains an Add+Welcome at the NEXT epoch instead, so a newcomer enters the
    // LIVE tree at the current epoch and existing members keep their epoch continuity (§4.2, §9 M4).
    // With keying OFF (M2 SHADOW), the superseding-genesis rebuild-on-growth is PRESERVED so OFF stays
    // byte-identical to pre-M4 (the switch-gated no-regression guarantee).
    if let Some(s) = st.shadow_trees.get(&circle_id) {
        if s.my_genesis.is_some() && (st.mls_keying || s.genesis_devices == device_ids) {
            return;
        }
    }
    // Own an Identity to sign with, so the immutable borrow of `st` ends before we mutate it.
    // Sign with THIS DEVICE's key (leaves are devices, §3.1): it scopes the genesis so two sibling
    // devices of one account produce DISTINCT commits (a real §5 fork that resolves), and it lets a
    // receiver resolve the creator device→account via the roster. Falls back to the account key only
    // on a seeded device that never adopted a device identity (an edge case; not a capable fleet).
    let signer = match &st.device {
        Some(d) => Identity::from_seed(&d.secret_seed()),
        None => Identity::from_seed(&st.account_or_device_signer().secret_seed()),
    };
    // Creator scope for leaf secrets + my own leaf: the signing device's id.
    let creator_id = signer.public().node_id_bytes();
    let my_device_id = Some(creator_id);
    // SECRET keying root (from my device seed) — the anchor the removal re-key rests on (§4.3).
    let secret_root = keying_secret_root(&signer.secret_seed(), &gid);

    // One Add per device, in the deterministic leaf order. leaf_index = position in the order.
    let mut adds: Vec<treekem::Proposal> = Vec::with_capacity(devices.len());
    let mut leaf_secrets: Vec<[u8; 32]> = Vec::with_capacity(devices.len());
    for (li, (bundle, cred)) in devices.iter().enumerate() {
        let ls = keying_leaf_secret(&secret_root, &bundle.node_id_bytes());
        leaf_secrets.push(ls);
        let kp = treekem::node_keypair_from_path_secret(&ls);
        let payload = treekem::leaf_binding_payload(&gid, &kp.kem_x, &kp.kem_pq);
        // SHADOW: the leaf binding is not DEVICE-signed (the creator generated these leaf
        // secrets; a device can't sign a key it doesn't hold). M2 does not verify it — that is a
        // later stage where each device publishes its own leaf. The account-signed
        // DeviceCredential still travels, so the leaf→account chain is present for the future.
        let leaf = treekem::LeafNode {
            leaf_kem_x: kp.kem_x,
            leaf_kem_pq: kp.kem_pq,
            device_credential: cred.to_bytes(),
            leaf_binding_sig: signer.sign(&payload),
        };
        adds.push(treekem::build_add_proposal(&gid, 0, li as u32, leaf, |m| signer.sign(m)));
    }
    // The creator's own leaf index (its device's position in the order). Fall back to 0 if this
    // build has no device identity (shouldn't happen for a capable circle).
    let creator_leaf = my_device_id
        .and_then(|d| devices.iter().position(|(b, _)| b.node_id_bytes() == d))
        .unwrap_or(0) as u32;

    let parent = shadow_genesis_parent(&gid);
    let base_cth = shadow_genesis_cth(&gid);
    let base_init = keying_base_init(&secret_root);
    let build = match treekem::build_commit(
        &treekem::RatchetTree { slots: vec![] },
        &gid,
        1,
        parent,
        &base_cth,
        &base_init,
        creator_leaf,
        adds,
        None, // add-only ⇒ commit_secret = 0
        |m| signer.sign(m),
        |m| signer.sign(m),
    ) {
        Ok(b) => b,
        Err(_) => return,
    };
    let commit_bytes = build.commit.to_bytes();
    let commit_hash = treekem::commit_hash(&commit_bytes);
    let joiner_secret = build.schedule.joiner_secret;

    // Cache the tagged commit + a Welcome sealed to each device's bundle (except my own device,
    // whose Welcome I store directly so my status is converged without a round-trip). A GENESIS
    // Welcome carries no `tree_bytes` — every holder reconstructs the tree from the genesis Adds.
    let mut emit_cache: Vec<Vec<u8>> = vec![tagged(TAG_MLS_COMMIT, &commit_bytes)];
    let mut my_welcome: Option<ShadowWelcome> = None;
    for (li, (bundle, _)) in devices.iter().enumerate() {
        let w = ShadowWelcome {
            epoch: 1,
            leaf_index: li as u32,
            joiner_secret,
            leaf_secret: leaf_secrets[li],
            cth: build.confirmed_transcript_hash,
            tree_bytes: Vec::new(),
        };
        if my_device_id == Some(bundle.node_id_bytes()) {
            my_welcome = Some(w);
            continue; // stored directly below
        }
        let plaintext = encode_shadow_welcome(&commit_hash, &w);
        let group = Group::new("mls-welcome", vec![bundle.clone()]);
        if let Ok(env) = seal_bytes(&signer, &group, &plaintext) {
            emit_cache.push(tagged(TAG_MLS_WELCOME, &env.to_bytes()));
        }
    }

    // Commit shadow state (the signer borrow of `st` has ended).
    let shadow = st.shadow_trees.entry(circle_id).or_insert_with(|| ShadowTree::new(gid.clone()));
    shadow.group_id = gid;
    shadow.commits.insert(commit_hash, commit_bytes);
    shadow.my_genesis = Some(commit_hash);
    shadow.my_secret_root = Some(secret_root);
    shadow.genesis_devices = device_ids;
    // The creator auto-joins its own genesis (§7.2): it holds the Welcome by construction.
    shadow.joined.insert(creator_id);
    if let Some(w) = my_welcome {
        shadow.my_welcomes.insert(commit_hash, w);
    }
    shadow.emit_cache = emit_cache;
}

/// The tagged shadow wire bytes to append to a circle's sync bundle (§4.5 — alongside, never
/// replacing, today's key commit). Gated on `circle_fully_mls_capable`; empty otherwise, so a
/// non-capable circle emits nothing and behaves exactly as today.
fn shadow_emit_bundle(st: &mut NetState, idx: usize, full_bundle: bool) -> Vec<Vec<u8>> {
    if !circle_is_mls_capable(st, idx) {
        return vec![];
    }
    if am_shadow_creator(st, idx) {
        build_shadow_genesis(st, idx);
        // M4 roster automation: once a genesis exists, reconcile the LIVE tree with the roster —
        // chained Add for a newly-authorized device, authority-checked Remove for a revoked one.
        // Gated inside on `mls_am_committer`, so this is inert with the keying switch OFF (M2/M3).
        mls_sync_roster_to_tree(st, idx);
        // M5 PCS cadence (§6.4): on a FULL bundle only (the same chokepoint as `rotate_if_stale`),
        // if no roster change already re-keyed my leaf this bundle and the weekly window elapsed, the
        // committer authors a leaf Update so a past leaf compromise heals. Must land BEFORE the
        // `emit_cache` clone below so the new commit rides THIS bundle. Gated inside on the switch +
        // live-keying, so it is inert with keying OFF (byte-identical to M4).
        if full_bundle {
            mls_pcs_leaf_update(st, idx);
        }
    }
    let circle_id = st.circles[idx].id.clone();
    st.shadow_trees.get(&circle_id).map(|s| s.emit_cache.clone()).unwrap_or_default()
}

/// Ingest a shadow Commit (§5.2): store it under its hash so `mls_shadow_status` can resolve the
/// chain/fork. SHADOW — returns `false` (no content change) always. Ignored harmlessly for a
/// non-capable circle or malformed bytes (no panic, no state change) — the legacy-peer contract.
fn receive_mls_commit(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    if !circle_is_mls_capable(st, idx) {
        return Ok(false); // shadow doesn't run here; ignore harmlessly
    }
    let Ok(commit) = treekem::Commit::from_bytes(body) else { return Ok(false) };
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    if commit.group_id != gid {
        return Ok(false);
    }
    let is_genesis = commit.epoch == 1 && commit.parent_commit_hash == shadow_genesis_parent(&gid);
    if is_genesis {
        // AUDIT L1 — authenticate the genesis to the elected creator/admin. Selection is otherwise by
        // leaf-count (`keying_winning_genesis`) with NO signer check, so any mls-capable member could
        // inject a competing genesis. Require the genesis commit's hybrid signature to verify under an
        // authorized device (or the account key) of the ELECTED creator — the lowest-account member
        // that §4.1 elects to build — or of a current admin. An unauthenticated genesis is dropped and
        // never enters the shadow store, closing the door the all-joined gate only guarded.
        if !genesis_signer_authorized(st, idx, &commit) {
            return Ok(false);
        }
    } else {
        // A chained commit (M3 Remove, §4.3). It participates only if (a) it extends a commit we
        // already hold (a known parent — otherwise it is an orphan we can't place) AND (b) it is
        // AUTHORIZED: its committer must be the circle creator or a current admin, or the commit must
        // remove only the committer's own account (self-removal). A Remove from a non-admin is
        // REJECTED here by EVERY receiver — the authority guarantee — so it never enters the chain.
        let parent_known = st
            .shadow_trees
            .get(&circle_id)
            .map(|s| s.commits.contains_key(&commit.parent_commit_hash))
            .unwrap_or(false);
        if !parent_known {
            // ORPHAN: extends a commit we don't hold yet. The ONE commit outcome worth retrying —
            // its parent may be in flight. Everything else that returns false here is terminal
            // (wrong circle, unauthorized, not capable) or is a SUCCESSFUL store that reports false
            // by design, and parking those poisoned the retry buffer with entries that can never
            // change outcome: gate 3 measured ~20 permanent residents per leg, re-verified under
            // the engine lock on every poll.
            TREE_RETRYABLE.with(|f| f.set(true));
            return Ok(false);
        }
        if !mls_commit_authorized(st, idx, &commit) {
            return Ok(false);
        }
    }
    let h = treekem::commit_hash(body);
    let shadow = st.shadow_trees.entry(circle_id).or_insert_with(|| ShadowTree::new(gid));
    shadow.commits.entry(h).or_insert_with(|| body.to_vec());
    Ok(false)
}

/// Authorize a chained (non-genesis) commit (§4.3): resolve the committer device→account from its
/// UpdatePath leaf credential (verified against the account's pinned bundle + roster), verify the
/// commit's hybrid signature under that device bundle, then require the account to be a current admin
/// (creator or creator-delegated) — UNLESS the commit removes only its own account's leaves (leave).
/// Any failure (no path, forged credential, bad signature, non-admin) is `false` ⇒ the commit is
/// dropped by this receiver, exactly as a corrupt envelope is.
fn mls_commit_authorized(st: &NetState, idx: usize, commit: &treekem::Commit) -> bool {
    let Some(up) = &commit.update_path else { return false }; // a Remove always re-keys (carries a path)
    let Ok(cred) = DeviceCredential::from_bytes(&up.leaf_node.device_credential) else { return false };
    // The committer's account must be a member (or me) with a known, verifying bundle + roster.
    let acct = cred.account_id;
    let Some(acct_bundle) = mls_account_bundle(st, idx, &acct) else { return false };
    if cred.verify(&acct_bundle).is_err() {
        return false; // the device→account credential must chain to the pinned account key
    }
    let device_bundle = cred.device.clone();
    // The committing device must be currently authorized by that account's roster (not revoked).
    let authorized_device = st
        .device_lists
        .get(&acct)
        .map(|cd| cd.list.is_authorized(&device_bundle.node_id_bytes()))
        .unwrap_or(false);
    if !authorized_device {
        return false;
    }
    // The commit's hybrid signature must verify under the committing device's bundle.
    if device_bundle.verify(&treekem::commit_signing_bytes(commit), &commit.sig).is_err() {
        return false;
    }
    // Self-removal (leave) is always allowed: every removed leaf belongs to the committer's account.
    let removes: Vec<u32> = commit
        .proposals
        .iter()
        .filter_map(|p| match &p.body {
            treekem::ProposalBody::Remove { leaf_index } => Some(*leaf_index),
            _ => None,
        })
        .collect();
    // Otherwise the committer must be a current admin (creator or creator-delegated).
    match circle_admin_set(st, idx) {
        Some(admins) if admins.contains(&acct) => true,
        _ => {
            // Not an admin: only a self-removal is allowed. Resolve each removed leaf's account from
            // the reconstructed genesis tree; all must equal the committer's account.
            !removes.is_empty()
                && removes.iter().all(|li| {
                    committer_removes_own_leaf(st, idx, &commit.parent_commit_hash, *li, &acct)
                })
        }
    }
}

/// AUDIT L1 — is this GENESIS commit signed by the elected creator (or a current admin)?
///
/// The genesis commit (epoch 1, `parent = genesis_parent`) is add-only and carries no UpdatePath, so
/// `mls_commit_authorized`'s device→account resolution (which reads the UpdatePath leaf) does not apply.
/// Instead we authenticate the SIGNER directly: gather the verifying bundles of the elected creator
/// account (§4.1: the lowest-account member, the one that legitimately builds genesis) plus every
/// current admin, and require the commit's hybrid signature to verify under one of them — an authorized
/// device bundle of that account (the normal device-signed genesis) or the account key itself (the
/// seeded-no-device-identity fallback `build_shadow_genesis` uses). Any genesis signed by anyone else is
/// unauthenticated and rejected. Legitimate §5.1 forks (two sibling devices of the elected-creator
/// account each building) still pass — both sign under authorized devices of that account.
fn genesis_signer_authorized(st: &NetState, idx: usize, commit: &treekem::Commit) -> bool {
    // Elected creator = lowest ACCOUNT id among the circle's mls accounts (me + members), matching
    // `am_shadow_creator`. `None` only for an empty account set (never, since me is always present).
    let Some(elected) = circle_mls_accounts(st, idx).iter().map(|a| a.node_id_bytes()).min() else {
        return false;
    };
    // Candidate signer accounts: the elected creator plus any current admin (creator-delegated).
    let mut candidates: HashSet<[u8; 32]> = HashSet::new();
    candidates.insert(elected);
    if let Some(admins) = circle_admin_set(st, idx) {
        candidates.extend(admins);
    }
    let msg = treekem::commit_signing_bytes(commit);
    for acct in &candidates {
        // The account key itself (seeded fallback).
        if let Some(acct_bundle) = mls_account_bundle(st, idx, acct) {
            if acct_bundle.verify(&msg, &commit.sig).is_ok() {
                return true;
            }
        }
        // Any device the account currently authorizes (the normal device-signed genesis).
        if let Some(cd) = st.device_lists.get(acct) {
            for cred in &cd.credentials {
                if cd.list.is_authorized(&cred.device_id())
                    && cred.device.verify(&msg, &commit.sig).is_ok()
                {
                    return true;
                }
            }
        }
    }
    false
}

/// Whether removed leaf `li` (as located in the tree at `parent_hash`) belongs to `acct` — used to
/// permit self-removal by a non-admin. Reconstructs the tree by replaying the chain from genesis.
fn committer_removes_own_leaf(
    st: &NetState,
    idx: usize,
    parent_hash: &[u8; 32],
    li: u32,
    acct: &[u8; 32],
) -> bool {
    let circle_id = st.circles[idx].id.clone();
    let Some(shadow) = st.shadow_trees.get(&circle_id) else { return false };
    // A pure-receiver replay (no device seed) reconstructs the public tree up to the parent.
    let Some(state) = mls_replay(shadow, None) else { return false };
    // Walk is bounded to the current tip; if the parent is the current tip the tree matches.
    if state.tip_hash != *parent_hash {
        // Fall back to the genesis tree (the common case: first Remove chains off genesis).
        let Some((gh, gbytes)) = keying_winning_genesis(shadow) else { return false };
        if gh != *parent_hash {
            return false;
        }
        let Ok(gc) = treekem::Commit::from_bytes(&gbytes) else { return false };
        let mut leaves = Vec::new();
        for p in &gc.proposals {
            if let treekem::ProposalBody::Add { leaf_node } = &p.body {
                leaves.push(leaf_node.clone());
            }
        }
        let tree = treekem::RatchetTree::from_leaves(leaves);
        return tree
            .leaf(li)
            .and_then(|l| DeviceCredential::from_bytes(&l.device_credential).ok())
            .map(|c| c.account_id == *acct)
            .unwrap_or(false);
    }
    state
        .tree
        .leaf(li)
        .and_then(|l| DeviceCredential::from_bytes(&l.device_credential).ok())
        .map(|c| c.account_id == *acct)
        .unwrap_or(false)
}

/// Ingest a shadow Welcome (§4.2): open it with my device/account key and store the delivered
/// secrets under the genesis commit hash they belong to. SHADOW — returns `false` always;
/// unopenable (not addressed to me) or non-capable circles are ignored harmlessly.
fn receive_mls_welcome(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    if !circle_is_mls_capable(st, idx) {
        return Ok(false);
    }
    let Ok(env) = SealedEnvelope::from_bytes(body) else { return Ok(false) };
    let sender_hex = env.sender_hex();
    let Some(sender) = resolve_shadow_sender(st, idx, &sender_hex) else {
        // Roster lag: we can't verify the sender YET. Retryable — the roster may be in flight.
        TREE_RETRYABLE.with(|f| f.set(true));
        return Ok(false);
    };
    // Dual-open: my device key first (the Welcome is sealed to my device bundle), then account key.
    // An OPEN failure below is NOT retryable: the overwhelmingly common cause is a Welcome sealed to
    // a DIFFERENT device sharing our mailbox prefix — someone else's mail, never ours to apply.
    let opened = st
        .device
        .as_ref()
        .and_then(|d| open_bytes(d, &sender, &env).ok())
        .or_else(|| st.me_secret.as_ref().and_then(|m| open_bytes(m, &sender, &env).ok()));
    let Some(plaintext) = opened else { return Ok(false) };
    let Some((commit_hash, welcome)) = decode_shadow_welcome(&plaintext) else { return Ok(false) };
    // FAIL CLOSED (§4.2 revoked-in-the-meantime): reject a SELF-CONTAINED Welcome unless MY device is
    // still authorized in my own roster (not revoked) AND my leaf is present in the delivered tree
    // with a key matching the delivered secret. A device revoked while its Welcome was in flight
    // cannot enter — the tree does not admit it, and I never store a Welcome that would key me to a
    // membership I've been cut from. (A genesis Welcome carries no tree; the genesis path re-checks.)
    if !welcome.tree_bytes.is_empty() {
        let my_dev = st.device.as_ref().map(|d| d.public().node_id_bytes());
        let my_acct = st.me().node_id_bytes();
        let authorized_here = my_dev
            .map(|d| {
                st.device_lists.get(&my_acct).map(|cd| cd.list.is_authorized(&d)).unwrap_or(true)
            })
            .unwrap_or(false);
        let leaf_ok = treekem::RatchetTree::from_bytes(&welcome.tree_bytes)
            .ok()
            .and_then(|t| t.leaf(welcome.leaf_index).cloned())
            .map(|l| {
                let kp = treekem::node_keypair_from_path_secret(&welcome.leaf_secret);
                kp.kem_x == l.leaf_kem_x && kp.kem_pq[..] == l.leaf_kem_pq[..]
            })
            .unwrap_or(false);
        if !authorized_here || !leaf_ok {
            return Ok(false);
        }
    }
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let shadow = st.shadow_trees.entry(circle_id).or_insert_with(|| ShadowTree::new(gid));
    shadow.my_welcomes.entry(commit_hash).or_insert(welcome);
    Ok(false)
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MLS M3 — the KEYING FLIP + removal RE-KEY + creator/admin authority
// (docs/TREEKEM-DESIGN.md §4.3 Remove, §4.5 keying flip, §7.2 all-joined gate, §7.3 park/resume).
//
// Everything below is gated behind the `mls_keying` master switch (default OFF ⇒ these paths are
// inert and content is byte-identical to M2). When ON, and a circle is fully-MLS-capable AND
// all-joined, the tree's per-account `sender_key_n` fills `my/peer_epoch_keys` and the legacy
// KeyCommit stops (§4.5); the content path (seal/open/dedup/feed) is UNCHANGED — only the key
// source moves. A removed device is cut off by a chained Remove+UpdatePath commit whose
// `commit_secret` it cannot derive (its leaf is excluded from the path encryption). If a legacy or
// not-yet-joined device (re)joins, the gate recomputes false and the circle PARKS back to KeyCommit
// within one bundle (§7.3) — both gate directions are recomputed from verified state, never edge-
// triggered, so park/resume is idempotent and crash-safe.
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// Resolve an account node id to its verifying public bundle (me or a circle member).
fn mls_account_bundle(st: &NetState, idx: usize, acct: &[u8; 32]) -> Option<HavenId> {
    if *acct == st.me().node_id_bytes() {
        return Some(st.me().clone());
    }
    st.circles[idx].members.iter().find(|m| m.node_id_bytes() == *acct).cloned()
}

/// The current admin set for a circle (§4.3): the pinned creator plus every account reachable by a
/// chain of VERIFIED admin grants (`admin_closure`). `None` when no creator is pinned — then no tree
/// Remove is authorized by anyone (a circle with no established authority root can't cut members).
/// Can this circle be carried onto a successor at all? ONLY when it has no provable owner.
///
/// The whole reason following an offer is left to the user is that a legacy circle's creator can't be
/// established from anything — so a signed claim is all anyone has, and a person must judge it. That
/// argument holds only where it's true. On a circle whose id already binds a creator, the app CAN
/// check, and any other member's claim is provably not the creator's — so the offer must never be
/// authored, ingested, surfaced, or followed there. Without this the flow would let a member ask
/// others to follow them off a circle that is demonstrably someone else's.
fn upgradable_circle(st: &NetState, idx: usize) -> bool {
    !st.circles[idx].id.starts_with(haven_p2p::device::OWNED_CIRCLE_PREFIX)
        && circle_admin_set(st, idx).is_none()
}

/// Ingest a [`CircleUpgrade`] offer on a legacy circle's control lane: "my creator-bound successor to
/// this circle is X". Verified here (the signer authored it; the successor id binds the signer; the
/// signer is a member of this circle), then STORED AS AN OFFER ONLY — never acted on.
///
/// This is the load-bearing restraint. A legacy circle has no authority root, so no signature can
/// prove the offerer created it; auto-following one would just re-introduce first-claim-wins with
/// extra steps. Competing offers from different members are both legitimate records — the user picks
/// via `accept_circle_upgrade`. Higher-version-wins per (legacy circle, offerer) so a re-offer
/// supersedes rather than duplicating. Control lane ⇒ never touches content, returns `false`.
fn receive_circle_upgrade(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    let Ok(up) = CircleUpgrade::from_bytes(body) else { return Ok(false) };
    if up.legacy_circle_id != st.circles[idx].id.as_bytes() {
        return Ok(false); // not an offer for this circle
    }
    // This circle already names its creator ⇒ there is nothing to carry it onto, and an offer here is
    // a member trying to draw others off a circle provably not theirs. Drop it before it can be shown.
    if !upgradable_circle(st, idx) {
        return Ok(false);
    }
    // The offerer must be someone in this circle (me or a member) with a known, pinned bundle, and
    // `verify` re-checks that the successor id actually binds them.
    let Some(offerer) = mls_account_bundle(st, idx, &up.creator) else { return Ok(false) };
    if up.verify(&offerer).is_err() {
        return Ok(false);
    }
    let offers = &mut st.circles[idx].upgrade_offers;
    for w in offers.iter_mut() {
        if let Ok(existing) = CircleUpgrade::from_bytes(w) {
            if existing.legacy_circle_id == up.legacy_circle_id && existing.creator == up.creator {
                if up.version > existing.version {
                    *w = up.to_bytes();
                }
                return Ok(false); // known offerer — superseded or stale, either way no content change
            }
        }
    }
    offers.push(up.to_bytes());
    Ok(false)
}

fn circle_admin_set(st: &NetState, idx: usize) -> Option<std::collections::HashSet<[u8; 32]>> {
    let creator = st.circles[idx].creator?;
    // Creator/admin authority is honored only when the circle id cryptographically binds to the
    // creator (an owned `c1…` id). A legacy/ownerless circle has no such binding and therefore
    // confers no admin authority — those circles use the legacy (roster / block) removal path; the
    // cryptographic-eviction path is available on owned circles, whose creator is fixed by the id.
    if !circle_id_binds_creator(&st.circles[idx].id, &creator) {
        return None;
    }
    let gid = st.circles[idx].id.as_bytes().to_vec();
    let mut edges: Vec<([u8; 32], [u8; 32])> = Vec::new();
    for w in &st.circles[idx].admin_grants {
        let Ok(g) = AdminGrant::from_bytes(w) else { continue };
        // Bind the grant to THIS circle + THIS authority root; verify against the grantor's bundle.
        if g.circle_id != gid || g.creator != creator {
            continue;
        }
        let Some(grantor_pub) = mls_account_bundle(st, idx, &g.grantor_account) else { continue };
        if g.verify(&grantor_pub).is_ok() {
            edges.push((g.grantor_account, g.admin_account));
        }
    }
    Some(admin_closure(creator, &edges))
}

/// Ingest an admin grant riding the control lane (§4.3): verify it against the grantor's pinned
/// bundle, bind it to this circle, learn the pinned creator if we don't have one, and store the wire
/// (higher-version-wins per admin_account). A forged/unverifiable/wrong-circle grant is dropped.
/// SHADOW-lane: never touches content, returns `false`.
fn receive_admin_grant(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    let Ok(g) = AdminGrant::from_bytes(body) else { return Ok(false) };
    let gid = st.circles[idx].id.as_bytes().to_vec();
    if g.circle_id != gid {
        return Ok(false);
    }
    let Some(grantor_pub) = mls_account_bundle(st, idx, &g.grantor_account) else { return Ok(false) };
    if g.verify(&grantor_pub).is_err() {
        return Ok(false);
    }
    // AUDIT M2 — bind the creator to the authenticated circle DEFINITION, never first-grant-wins TOFU:
    //   * A grant that DISAGREES with a creator we already hold is rejected outright — and if that
    //     creator is DEFINITION-pinned (established at creation / via `set_circle_creator` / a signed
    //     circle-sync record), the grant can never dislodge it. This is the wedge fix: a self-signed
    //     `AdminGrant{creator=Mallory}` reaching a victim who already knows the real creator is dropped.
    //   * Only when we hold NO creator at all do we *weakly* TOFU-learn one from the grant (the legacy
    //     fallback the audit permits) — but WITHOUT marking it definition-pinned, so a later authentic
    //     definition can still override it (see `set_circle_creator` / `merge_circle`). A grant never
    //     sets `creator_pinned`.
    // A creator is learned from a grant only if the circle id cryptographically binds to it (an
    // owned `c1…` id). A grant on a legacy/ownerless circle, or one whose claimed creator doesn't
    // match the id commitment, never establishes a creator — the id is the source of authority.
    match st.circles[idx].creator {
        None => {
            if circle_id_binds_creator(&st.circles[idx].id, &g.creator) {
                st.circles[idx].creator = Some(g.creator);
                st.circles[idx].creator_pinned = true; // id-bound ⇒ authenticated
            }
        }
        Some(c) if c == g.creator => {}
        Some(_) => return Ok(false), // a grant for a different authority root is not ours
    }
    // Higher-version-wins per (admin_account): replace a stale stored grant, else append a new one.
    let grants = &mut st.circles[idx].admin_grants;
    let mut replaced = false;
    for w in grants.iter_mut() {
        if let Ok(mut existing) = AdminGrant::from_bytes(w) {
            if existing.circle_id == g.circle_id
                && existing.creator == g.creator
                && existing.admin_account == g.admin_account
            {
                if existing.adopt_if_newer(&g) {
                    *w = existing.to_bytes();
                }
                replaced = true;
                break;
            }
        }
    }
    if !replaced {
        grants.push(g.to_bytes());
    }
    Ok(false)
}

/// The device ids present as leaves in `tree` (parsing each leaf's account-signed credential). Used
/// by the all-joined gate and by sender-key derivation to enumerate the circle's live devices.
fn tree_leaf_device_ids(tree: &treekem::RatchetTree) -> Vec<[u8; 32]> {
    let mut out = Vec::new();
    for slot in &tree.slots {
        if let treekem::TreeSlot::Leaf(l) = slot {
            if let Ok(c) = DeviceCredential::from_bytes(&l.device_credential) {
                out.push(c.device.node_id_bytes());
            }
        }
    }
    out
}

/// The distinct ACCOUNT ids present as leaves in `tree` (a member's leaves resolve to its account —
/// the account-keyed slot the content path already uses). Resolving §3.3's per-leaf sender key to a
/// per-ACCOUNT key here is the deliberate simplification (§4.5 ambiguity) that keeps `my/peer_epoch_keys`
/// keyed by `(account, epoch)` BYTE-IDENTICALLY: every member derives the same shared `sender_root`, so
/// every member computes the identical account-scoped key, and the content path needs no map widening.
fn tree_leaf_accounts(tree: &treekem::RatchetTree) -> Vec<[u8; 32]> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for slot in &tree.slots {
        if let treekem::TreeSlot::Leaf(l) = slot {
            if let Ok(c) = DeviceCredential::from_bytes(&l.device_credential) {
                if seen.insert(c.account_id) {
                    out.push(c.account_id);
                }
            }
        }
    }
    out
}

/// The winning genesis commit for the KEYING layer. Among the epoch-1 commits (parent =
/// genesis_parent), prefer the one with the MOST leaves, then the larger hash. The leaf-count
/// preference makes §7.3 RESUME deterministic: when a straggler upgrades, the creator rebuilds a
/// genesis that is a strict SUPERSET, and that larger genesis wins on every device — so the newcomer
/// is never stranded behind a smaller stale genesis. (The M2 `mls_shadow_status` telemetry keeps its
/// own pure `select_chain` view, unchanged, so nothing about the shadow soak signal moves.)
/// How many chained commits extend `tip` in this shadow store (longest path).
///
/// The genesis election needs it: every device of the creator ACCOUNT validly authors a competing
/// genesis (the authority check binds to the account, and multi-master means several devices race
/// at circle birth), so a store commonly holds 2–4 candidates. Electing by (adds, hash) alone
/// ignored which candidate the chain actually GREW on — a committer's epoch-2 Add extends one
/// specific genesis, and when that one lost the election every member's chain walk found no child
/// of the winner and froze at epoch 1, while any device holding a direct Welcome onto the grown
/// branch entered at epoch 2. One leg at 778, three at 777, both directions dark: the gauntlet's
/// recurring fork. Chain height is shared state (same commit set ⇒ same heights on every leg), so
/// preferring it keeps the election deterministic AND pointed at the branch that is actually alive.
fn keying_chain_height(shadow: &ShadowTree, tip: [u8; 32], epoch: u64) -> usize {
    let mut best = 0usize;
    for (h, b) in shadow.commits.iter() {
        let Ok(c) = treekem::Commit::from_bytes(b) else { continue };
        if c.epoch == epoch + 1 && c.parent_commit_hash == tip {
            best = best.max(1 + keying_chain_height(shadow, *h, c.epoch));
        }
    }
    best
}

fn keying_winning_genesis(shadow: &ShadowTree) -> Option<([u8; 32], Vec<u8>)> {
    let gid = &shadow.group_id;
    let parent = shadow_genesis_parent(gid);
    // (chain height, leaf count, hash) — height FIRST. See keying_chain_height for why.
    let mut best: Option<(usize, usize, [u8; 32], Vec<u8>)> = None;
    for b in shadow.commits.values() {
        let Ok(c) = treekem::Commit::from_bytes(b) else { continue };
        if c.epoch != 1 || c.parent_commit_hash != parent || &c.group_id != gid {
            continue;
        }
        let adds = c
            .proposals
            .iter()
            .filter(|p| matches!(p.body, treekem::ProposalBody::Add { .. }))
            .count();
        let h = treekem::commit_hash(b);
        let height = keying_chain_height(shadow, h, 1);
        let better = match &best {
            None => true,
            Some((bht, bn, bh, _)) => {
                height > *bht
                    || (height == *bht && adds > *bn)
                    || (height == *bht && adds == *bn && h > *bh)
            }
        };
        if better {
            best = Some((height, adds, h, b.clone()));
        }
    }
    best.map(|(_, _, h, b)| (h, b))
}

/// This device's keying state after replaying the tree commit chain from its Welcome (§4.5, §5.1).
struct KeyingState {
    /// Tree epoch (1 = genesis; +1 per applied Add/Remove commit).
    epoch: u64,
    tree: treekem::RatchetTree,
    /// My private tree state at the current epoch, or `None` if I was removed / can't derive.
    my_private: Option<treekem::TreePrivate>,
    /// The current epoch's `sender_root` — `None` if I am the removed device (cut off from the epoch).
    sender_root: Option<[u8; 32]>,
    /// The current epoch's `init_secret` (feeds the next commit's advance).
    init_secret: Option<[u8; 32]>,
    /// M4: the current epoch's `joiner_secret` — what a committer re-delivers to Welcome a mid-life
    /// joiner or re-admit a sleeper AT the live epoch (§4.2/§5.5). `None` if I can't derive the epoch.
    joiner_secret: Option<[u8; 32]>,
    cth: [u8; 32],
    tip_hash: [u8; 32],
    /// Set when a Remove in this chain targeted THIS device. Retained for diagnosis and for the
    /// symmetry of the struct; nothing reads it yet.
    #[allow(dead_code)]
    removed_me: bool,
    /// M4: device ids ever cut from this chain by a Remove (removal-STICKY, the LWW-removal shape the
    /// codebase uses elsewhere). The roster→Add automation skips these so a deliberately-removed device
    /// is never silently re-Added just because it is still "authorized" in a stale roster view. Only
    /// meaningful when replayed from genesis (the creator's vantage); a mid-chain entrant leaves it empty.
    removed_devices: std::collections::HashSet<[u8; 32]>,
}

/// Deletion discipline (§6.2, the commit-CHAIN row of the M5 pruner extension). `mls_replay` walks
/// the chain by REPLACING `cur` at each epoch (`cur = KeyingState { .. }`); the superseded epoch's
/// state drops here. Its `init_secret`/`sender_root`/`joiner_secret` are live epoch secrets — a
/// dropped-not-wiped `Option<[u8; 32]>` would leave the prior epoch's material in freed memory,
/// exactly the "pruned-epoch's material must be wiped, not just dropped" obligation. `tree`/`cth`/
/// `tip_hash` are public and need no wipe; `my_private` (a `TreePrivate`) wipes itself via its own
/// Drop. Nothing downstream needs the superseded epoch: the replay has already advanced past it.
impl Drop for KeyingState {
    fn drop(&mut self) {
        for s in [&mut self.sender_root, &mut self.init_secret, &mut self.joiner_secret] {
            if let Some(v) = s.as_mut() {
                treekem::wipe_secret(v);
            }
        }
    }
}

/// Rebuild MY OWN commit deterministically to recover its post-commit tree/schedule/private state
/// (`apply_commit` refuses self-application, and the rebuild-each-bundle model stores no build). The
/// fresh leaf secret + entropy come from `keying_update_material` (the exact material used when the
/// commit was authored), so the tree + schedule + transcript reproduce EXACTLY; the signature is
/// irrelevant to state (the transcript blanks it), so a dummy signer is used.
fn keying_rebuild_own_commit(
    prev: &KeyingState,
    gid: &[u8],
    target: &treekem::Commit,
    my_leaf: u32,
    my_secret_root: &[u8; 32],
) -> Option<treekem::CommitBuild> {
    let up = target.update_path.as_ref()?;
    let cred = up.leaf_node.device_credential.clone();
    let (new_leaf, entropy) = keying_update_material(my_secret_root, target.epoch);
    let init = prev.init_secret?;
    // Reproduce the EXACT commit CONTENT so the schedule matches the real broadcast commit (which
    // receivers apply): the confirmed-transcript hash covers the proposals AND the UpdatePath's
    // leaf-binding signature, so both must be byte-identical. We reuse the stored proposals as-is
    // and feed back the stored leaf-binding signature (a hybrid sig need not be deterministic, so
    // re-signing could diverge). Only the commit's OWN signature is outside the transcript ⇒ dummy.
    let props: Vec<treekem::Proposal> = target.proposals.clone();
    let stored_leaf_sig = up.leaf_node.leaf_binding_sig.clone();
    treekem::build_commit(
        &prev.tree,
        gid,
        target.epoch,
        prev.tip_hash,
        &prev.cth,
        &init,
        my_leaf,
        props,
        Some((&new_leaf, &cred, &entropy)),
        move |_| stored_leaf_sig,
        |_| Vec::new(),
    )
    .ok()
}

/// Replay the tree commit chain to the current epoch (§5.1, §4.2/§5.5). Pure function of {known
/// commits, my Welcomes, my device seed}. Two entry modes, unified:
///   * SELF-CONTAINED (M4): if I hold a mid-chain / re-entry Welcome carrying `tree_bytes` (the
///     highest-epoch one wins), I bootstrap at THAT epoch directly from the delivered tree +
///     `joiner_secret` + `cth` — no chain replay. This is how a mid-life joiner enters at the LIVE
///     epoch (never a genesis rebuild) and how a sleeper past the mailbox TTL re-enters (§5.5).
///   * GENESIS (M2/M3): else I bootstrap from the winning genesis Welcome and reconstruct its tree
///     from the genesis Adds — the original path, byte-identical.
/// Either way I then walk each subsequent epoch's winning commit — applying it (or rebuilding it if
/// I authored it) — until the chain ends. Returns `None` if I hold no usable Welcome (I haven't
/// joined), or if a self-contained Welcome FAILS CLOSED (my leaf absent / key mismatch ⇒ revoked).
fn mls_replay(shadow: &ShadowTree, my_device_seed: Option<[u8; 32]>) -> Option<KeyingState> {
    let gid = shadow.group_id.clone();
    let my_secret_root = my_device_seed.map(|s| keying_secret_root(&s, &gid));
    // Prefer the highest-epoch SELF-CONTAINED Welcome I hold (a mid-life Add or a re-entry). It lets
    // me enter at the live epoch without the chain; the genesis path is the fallback.
    let self_contained = shadow
        .my_welcomes
        .iter()
        .filter(|(_, w)| !w.tree_bytes.is_empty())
        .max_by_key(|(h, w)| (w.epoch, **h));
    let mut cur = if let Some((tip_hash, welcome)) = self_contained {
        let tree = treekem::RatchetTree::from_bytes(&welcome.tree_bytes).ok()?;
        let th = treekem::tree_hash(&tree);
        // FAIL CLOSED (§4.2 revoked-in-the-meantime): my leaf must be present AND its public key must
        // match the delivered leaf secret. A removed device (blanked leaf) or a mismatched secret is
        // rejected here — the tree refuses to admit it, no separate policy check to forget.
        let leaf_ok = tree
            .leaf(welcome.leaf_index)
            .map(|l| {
                let kp = treekem::node_keypair_from_path_secret(&welcome.leaf_secret);
                kp.kem_x == l.leaf_kem_x && kp.kem_pq[..] == l.leaf_kem_pq[..]
            })
            .unwrap_or(false);
        if !leaf_ok {
            return None;
        }
        let sched =
            treekem::welcome_epoch_schedule(&welcome.joiner_secret, &gid, welcome.epoch, &th, &welcome.cth);
        KeyingState {
            epoch: welcome.epoch,
            tree,
            my_private: Some(treekem::TreePrivate::new(welcome.leaf_index, welcome.leaf_secret)),
            sender_root: Some(sched.sender_root),
            init_secret: Some(sched.init_secret),
            joiner_secret: Some(sched.joiner_secret),
            cth: welcome.cth,
            tip_hash: *tip_hash,
            removed_me: false,
            removed_devices: std::collections::HashSet::new(),
        }
    } else {
        let (gh, gbytes) = keying_winning_genesis(shadow)?;
        let welcome = shadow.my_welcomes.get(&gh)?;
        let gc = treekem::Commit::from_bytes(&gbytes).ok()?;
        // Reconstruct the genesis tree from its Add proposals (add-only ⇒ from_leaves).
        let mut leaves = Vec::new();
        for p in &gc.proposals {
            if let treekem::ProposalBody::Add { leaf_node } = &p.body {
                leaves.push(leaf_node.clone());
            }
        }
        let tree = treekem::RatchetTree::from_leaves(leaves);
        if treekem::tree_hash(&tree) != gc.tree_hash {
            return None;
        }
        let cth1 = treekem::next_confirmed_transcript_hash(&shadow_genesis_cth(&gid), &gc);
        let sched1 =
            treekem::welcome_epoch_schedule(&welcome.joiner_secret, &gid, 1, &gc.tree_hash, &cth1);
        KeyingState {
            epoch: 1,
            tree,
            my_private: Some(treekem::TreePrivate::new(welcome.leaf_index, welcome.leaf_secret)),
            sender_root: Some(sched1.sender_root),
            init_secret: Some(sched1.init_secret),
            joiner_secret: Some(sched1.joiner_secret),
            cth: cth1,
            tip_hash: gh,
            removed_me: false,
            removed_devices: std::collections::HashSet::new(),
        }
    };
    loop {
        let next = cur.epoch + 1;
        // Children of the current tip at the next epoch (a §5 fork at this level is resolved by hash).
        let mut children: Vec<Vec<u8>> = shadow
            .commits
            .values()
            .filter(|b| {
                treekem::Commit::from_bytes(b)
                    .map(|c| c.epoch == next && c.parent_commit_hash == cur.tip_hash)
                    .unwrap_or(false)
            })
            .cloned()
            .collect();
        if children.is_empty() {
            break;
        }
        children.sort_by(|a, b| treekem::commit_hash(a).cmp(&treekem::commit_hash(b)));
        let cbytes = children.last().unwrap().clone();
        let Ok(c) = treekem::Commit::from_bytes(&cbytes) else { break };
        let tip = treekem::commit_hash(&cbytes);
        // Removal-sticky (M4): before this commit mutates the tree, record the device id of every leaf
        // it Removes (resolved against the PRE-commit tree) so the roster→Add automation never re-Adds it.
        let mut removed_devices = cur.removed_devices.clone();
        for p in &c.proposals {
            if let treekem::ProposalBody::Remove { leaf_index } = &p.body {
                if let Some(l) = cur.tree.leaf(*leaf_index) {
                    if let Ok(dc) = DeviceCredential::from_bytes(&l.device_credential) {
                        removed_devices.insert(dc.device.node_id_bytes());
                    }
                }
            }
        }
        let i_committed = cur.my_private.as_ref().map(|p| p.leaf_index) == Some(c.sender_leaf);
        if i_committed {
            let (Some(sroot), Some(mp)) = (my_secret_root, cur.my_private.as_ref()) else { break };
            let my_leaf = mp.leaf_index;
            let Some(build) = keying_rebuild_own_commit(&cur, &gid, &c, my_leaf, &sroot) else { break };
            cur = KeyingState {
                epoch: next,
                tree: build.tree,
                sender_root: Some(build.schedule.sender_root),
                init_secret: Some(build.schedule.init_secret),
                joiner_secret: Some(build.schedule.joiner_secret),
                cth: build.confirmed_transcript_hash,
                tip_hash: tip,
                my_private: Some(build.my_private),
                removed_me: false,
                removed_devices,
            };
        } else {
            let Some(init) = cur.init_secret else { break };
            let applied =
                match treekem::apply_commit(&cur.tree, &gid, &cur.cth, &init, &c, cur.my_private.as_ref()) {
                    Ok(a) => a,
                    Err(_) => break, // a commit we can't apply cleanly: stop at the current epoch
                };
            if applied.removed_me {
                // I am the removed device: I cannot derive this epoch. Freeze cut off from here.
                cur = KeyingState {
                    epoch: next,
                    tree: applied.tree,
                    sender_root: None,
                    init_secret: None,
                    joiner_secret: None,
                    cth: applied.confirmed_transcript_hash,
                    tip_hash: tip,
                    my_private: None,
                    removed_me: true,
                    removed_devices,
                };
                break;
            }
            let Some(sched) = applied.schedule else { break };
            cur = KeyingState {
                epoch: next,
                tree: applied.tree,
                sender_root: Some(sched.sender_root),
                init_secret: Some(sched.init_secret),
                joiner_secret: Some(sched.joiner_secret),
                cth: applied.confirmed_transcript_hash,
                tip_hash: tip,
                my_private: applied.my_private,
                removed_me: false,
                removed_devices,
            };
        }
    }
    Some(cur)
}

/// The §7.2 all-joined gate: every device leaf in the CURRENT tree has broadcast a join ack. A
/// device that never fetched its Welcome (and so never joined) keeps this false, so it can never
/// strand the circle in the flipped state. Empty tree ⇒ false.
fn keying_all_joined(shadow: &ShadowTree, tree: &treekem::RatchetTree) -> bool {
    let leaves = tree_leaf_device_ids(tree);
    !leaves.is_empty() && leaves.iter().all(|d| shadow.joined.contains(d))
}

/// The join-ack signing preimage: `domain ‖ genesis_hash ‖ device_id`.
fn keying_join_payload(genesis_hash: &[u8; 32], device_id: &[u8; 32]) -> Vec<u8> {
    let mut v = Vec::with_capacity(20 + 64);
    v.extend_from_slice(b"haven-mls-join-v1");
    v.extend_from_slice(genesis_hash);
    v.extend_from_slice(device_id);
    v
}

/// Emit my join ack for the winning genesis (§7.2), and mark myself joined locally, once I can
/// DERIVE the current epoch. The ack is keyed by the (public) genesis hash — a stable per-group
/// anchor all members agree on — but M4 attests on "I can replay to an active deriving membership,"
/// not "I hold the genesis Welcome," so a device that entered mid-life (or re-entered as a sleeper,
/// §5.5) via a self-contained Welcome — and so holds no GENESIS Welcome — can still join the gate.
/// `None` if there is no genesis, I can't derive the epoch, or I have no device identity.
fn keying_emit_join(st: &mut NetState, idx: usize) -> Option<Vec<u8>> {
    if !st.mls_keying {
        return None; // join acks only flow once keying is switched on — OFF stays byte-identical to M2
    }
    let circle_id = st.circles[idx].id.clone();
    let seed = st.device.as_ref().map(|d| d.secret_seed())?;
    let shadow = st.shadow_trees.get(&circle_id)?;
    let (gh, _) = keying_winning_genesis(shadow)?;
    // I attest only if I can actually derive the live epoch (active member, not removed) — via the
    // genesis Welcome OR a self-contained mid-chain / re-entry Welcome.
    let can_derive = mls_replay(shadow, Some(seed))
        .map(|s| s.my_private.is_some() && s.sender_root.is_some())
        .unwrap_or(false);
    if !can_derive {
        return None;
    }
    let signer = Identity::from_seed(&seed);
    let did = signer.public().node_id_bytes();
    let sig = signer.sign(&keying_join_payload(&gh, &did));
    let mut body = Vec::with_capacity(64 + sig.len());
    body.extend_from_slice(&gh);
    body.extend_from_slice(&did);
    body.extend_from_slice(&sig);
    st.shadow_trees.get_mut(&circle_id)?.joined.insert(did);
    Some(tagged(TAG_MLS_JOIN, &body))
}

/// Ingest a join ack (§7.2): verify the device's signature against its authorized bundle and record
/// it joined. SHADOW-lane: never touches content, returns `false`. Malformed / unauthorized / bad
/// signature are all ignored harmlessly (the legacy-peer contract).
fn receive_mls_join(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    if !circle_is_mls_capable(st, idx) || body.len() < 64 {
        return Ok(false);
    }
    let gh: [u8; 32] = body[0..32].try_into().unwrap();
    let did: [u8; 32] = body[32..64].try_into().unwrap();
    let sig = &body[64..];
    let did_hex = hex(&did);
    let Some(bundle) = resolve_shadow_sender(st, idx, &did_hex) else {
        TREE_RETRYABLE.with(|f| f.set(true));
        return Ok(false);
    };
    if bundle.verify(&keying_join_payload(&gh, &did), sig).is_err() {
        return Ok(false);
    }
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let shadow = st.shadow_trees.entry(circle_id).or_insert_with(|| ShadowTree::new(gid));
    shadow.joined.insert(did);
    shadow.joined_genesis.insert(did, gh);
    Ok(false)
}

/// Author a creator/admin Remove commit that re-keys the tree so the removed device is cut off
/// (§4.3): a chained Remove+UpdatePath at the next epoch. Returns `false` (no-op) if I'm not an
/// active member, not authorized (creator/admin — or removing my own leaf, always allowed), or the
/// circle isn't running the tree. The removed device cannot derive the new `commit_secret` (its leaf
/// is excluded from the path encryption) so it cannot open any content sealed at the new epoch.
fn mls_build_remove(st: &mut NetState, idx: usize, removed_leaves: &[u32]) -> bool {
    if removed_leaves.is_empty() {
        return false;
    }
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let Some(seed) = st.device.as_ref().map(|d| d.secret_seed()) else { return false };
    let signer = Identity::from_seed(&seed);
    let my_secret_root = keying_secret_root(&seed, &gid);
    let Some(shadow) = st.shadow_trees.get(&circle_id) else { return false };
    let Some(cur) = mls_replay(shadow, Some(seed)) else { return false };
    let Some(mp) = &cur.my_private else { return false }; // I must be an active member
    let Some(init) = cur.init_secret else { return false };
    let my_leaf = mp.leaf_index;
    // Authority: I must be the creator/an admin, OR every removed leaf is my OWN account's (self-
    // removal / leave, always allowed). Accounts come from the tree's leaf credentials, so this is
    // checked against the same verified chain receivers use.
    let my_account = st.me().node_id_bytes();
    let removed_accounts: Vec<Option<[u8; 32]>> = removed_leaves
        .iter()
        .map(|li| {
            cur.tree
                .leaf(*li)
                .and_then(|l| DeviceCredential::from_bytes(&l.device_credential).ok().map(|c| c.account_id))
        })
        .collect();
    let authorized = match circle_admin_set(st, idx) {
        Some(admins) if admins.contains(&my_account) => true,
        _ => removed_accounts.iter().all(|a| *a == Some(my_account)),
    };
    if !authorized {
        return false;
    }
    let next = cur.epoch + 1;
    let (new_leaf, entropy) = keying_update_material(&my_secret_root, next);
    let Some(cred) = cur.tree.leaf(my_leaf).map(|l| l.device_credential.clone()) else { return false };
    let props: Vec<treekem::Proposal> = removed_leaves
        .iter()
        .map(|li| treekem::build_remove_proposal(&gid, next, my_leaf, *li, |m| signer.sign(m)))
        .collect();
    let build = match treekem::build_commit(
        &cur.tree,
        &gid,
        next,
        cur.tip_hash,
        &cur.cth,
        &init,
        my_leaf,
        props,
        Some((&new_leaf, &cred, &entropy)),
        |m| signer.sign(m),
        |m| signer.sign(m),
    ) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let cbytes = build.commit.to_bytes();
    let ch = treekem::commit_hash(&cbytes);
    let shadow = st.shadow_trees.get_mut(&circle_id).unwrap();
    if shadow.commits.contains_key(&ch) {
        return false; // already authored (idempotent)
    }
    shadow.commits.insert(ch, cbytes.clone());
    shadow.emit_cache.push(tagged(TAG_MLS_COMMIT, &cbytes));
    // A Remove re-keys the committer's own leaf too, so it resets the PCS window (§6.4): the leaf
    // was just refreshed — the periodic leaf Update shouldn't also fire this bundle.
    st.circles[idx].rotated_at = now_secs();
    true
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MLS M4 — offline / mid-chain Welcomes + roster→Add/Remove automation
// (docs/TREEKEM-DESIGN.md §4.2 Add, §4.3 Remove, §4.4/§5.5 Welcome + sleeper re-entry, §9 row M4).
//
// This is the roster INTEGRATION: `register_device`/revocation, which already drive today's
// sender-keys `rotate_epoch`, now ALSO drive the tree — the creator chains an Add+Welcome for a
// newly-authorized device (entering it at the LIVE epoch, not a superseding genesis) and an
// authority-checked Remove for a revoked one. All of it is GATED: it fires only for a circle with
// the keying switch ON that is fully-MLS-capable and has a live tree; an OFF / shadow / non-capable
// circle is byte-identical to before (M3). Idempotent + crash-safe: it is recomputed each bundle
// from verified state (the "absence is never information" discipline), never edge-triggered.
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// True iff I am the tree's committing authority (the elected creator) for this circle AND the
/// keying switch is ON — the gate on every M4 automation write. Only the creator maintains the tree
/// (chained Add/Remove), so two admins never race concurrent membership commits (§4.1 election).
fn mls_am_committer(st: &NetState, idx: usize) -> bool {
    st.mls_keying && circle_is_mls_capable(st, idx) && am_shadow_creator(st, idx)
}

/// Build one chained Add+Welcome commit admitting `new_devices` (bundle + credential) to the LIVE
/// tree at the next epoch (§4.2): the creator adds each device's leaf, re-keys its own path, and
/// Welcomes each newcomer a SELF-CONTAINED Welcome (GroupInfo epoch n + the tree blob) so the
/// joiner enters at epoch n WITHOUT replaying the chain — the replacement for M3's superseding
/// genesis. The added leaf secrets derive from the creator's secret root (as at genesis), so a
/// replay of this own commit reproduces identical bytes. No-op (returns false) if I'm not the
/// committer, can't derive the epoch, or the build fails.
fn mls_grow_tree(st: &mut NetState, idx: usize, new_devices: &[(HavenId, DeviceCredential)]) -> bool {
    if new_devices.is_empty() || !mls_am_committer(st, idx) {
        return false;
    }
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let Some(seed) = st.device.as_ref().map(|d| d.secret_seed()) else { return false };
    let signer = Identity::from_seed(&seed);
    let my_secret_root = keying_secret_root(&seed, &gid);
    let Some(shadow) = st.shadow_trees.get(&circle_id) else { return false };
    let Some(cur) = mls_replay(shadow, Some(seed)) else { return false };
    let Some(mp) = &cur.my_private else { return false }; // I must be an active member to commit
    let Some(init) = cur.init_secret else { return false };
    let my_leaf = mp.leaf_index;
    let next = cur.epoch + 1;

    // One Add proposal per new device; the leaf secret is derived from MY secret root (I generate it
    // and deliver it in the Welcome), so a device can't be admitted with a key it doesn't receive.
    let mut adds: Vec<treekem::Proposal> = Vec::with_capacity(new_devices.len());
    let mut joiners: Vec<(HavenId, [u8; 32])> = Vec::with_capacity(new_devices.len()); // (bundle, leaf_secret)
    for (bundle, cred) in new_devices {
        let ls = keying_leaf_secret(&my_secret_root, &bundle.node_id_bytes());
        let kp = treekem::node_keypair_from_path_secret(&ls);
        let payload = treekem::leaf_binding_payload(&gid, &kp.kem_x, &kp.kem_pq);
        let leaf = treekem::LeafNode {
            leaf_kem_x: kp.kem_x,
            leaf_kem_pq: kp.kem_pq,
            device_credential: cred.to_bytes(),
            leaf_binding_sig: signer.sign(&payload),
        };
        adds.push(treekem::build_add_proposal(&gid, next, my_leaf, leaf, |m| signer.sign(m)));
        joiners.push((bundle.clone(), ls));
    }
    let (new_leaf, entropy) = keying_update_material(&my_secret_root, next);
    let Some(cred) = cur.tree.leaf(my_leaf).map(|l| l.device_credential.clone()) else { return false };
    let build = match treekem::build_commit(
        &cur.tree, &gid, next, cur.tip_hash, &cur.cth, &init, my_leaf, adds,
        Some((&new_leaf, &cred, &entropy)), |m| signer.sign(m), |m| signer.sign(m),
    ) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let cbytes = build.commit.to_bytes();
    let ch = treekem::commit_hash(&cbytes);
    let tree_bytes = build.tree.to_bytes();
    let joiner_secret = build.schedule.joiner_secret;
    let cth = build.confirmed_transcript_hash;
    // A Welcome per newcomer: self-contained (carries the tree blob + epoch n context) so a joiner —
    // or a sleeper past the TTL — enters at epoch n without the chain (§4.2/§5.5).
    let mut welcome_wires: Vec<Vec<u8>> = Vec::new();
    for (bundle, ls) in &joiners {
        // The leaf index the Add placed this device at, located by its (unique) leaf key.
        let kp = treekem::node_keypair_from_path_secret(ls);
        let Some(li) = build.tree.slots.iter().enumerate().find_map(|(i, s)| match s {
            treekem::TreeSlot::Leaf(l) if l.leaf_kem_x == kp.kem_x => Some((i / 2) as u32),
            _ => None,
        }) else { continue };
        let w = ShadowWelcome {
            epoch: next,
            leaf_index: li,
            joiner_secret,
            leaf_secret: *ls,
            cth,
            tree_bytes: tree_bytes.clone(),
        };
        let plaintext = encode_shadow_welcome(&ch, &w);
        let group = Group::new("mls-welcome", vec![bundle.clone()]);
        if let Ok(env) = seal_bytes(&signer, &group, &plaintext) {
            welcome_wires.push(tagged(TAG_MLS_WELCOME, &env.to_bytes()));
        }
    }
    let shadow = st.shadow_trees.get_mut(&circle_id).unwrap();
    if shadow.commits.contains_key(&ch) {
        return false; // already authored (idempotent across bundles)
    }
    shadow.commits.insert(ch, cbytes.clone());
    shadow.emit_cache.push(tagged(TAG_MLS_COMMIT, &cbytes));
    shadow.emit_cache.extend(welcome_wires);
    // An Add re-keys the committer's own leaf (its UpdatePath rides the commit), so it resets the
    // PCS window (§6.4): the periodic leaf Update shouldn't also fire this same bundle.
    st.circles[idx].rotated_at = now_secs();
    true
}

/// Re-Welcome a device that is STILL in the tree but can no longer derive the live epoch — a sleeper
/// past the mailbox TTL whose chain was pruned and whose private tree state lapsed (§5.5). The
/// creator hands it a FRESH self-contained Welcome at the CURRENT epoch (the tree blob + the live
/// `joiner_secret` it already holds in its replay + the device's leaf secret, which the creator
/// re-derives from its secret root), so the sleeper jumps straight to the live epoch and reads
/// history from the ordinary re-seal backfill — no chain replay. No-op if I'm not the committer, the
/// device isn't a current tree leaf, or I can't derive the live epoch.
fn mls_rewelcome_device(st: &mut NetState, idx: usize, device_id: &[u8; 32]) -> bool {
    if !mls_am_committer(st, idx) {
        return false;
    }
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let Some(seed) = st.device.as_ref().map(|d| d.secret_seed()) else { return false };
    let signer = Identity::from_seed(&seed);
    let my_secret_root = keying_secret_root(&seed, &gid);
    let Some(shadow) = st.shadow_trees.get(&circle_id) else { return false };
    let Some(cur) = mls_replay(shadow, Some(seed)) else { return false };
    let Some(joiner_secret) = cur.joiner_secret else { return false }; // I must derive the live epoch
    // The device must be a CURRENT leaf (still admitted), and its leaf key must match the secret I
    // re-derive — the same fail-closed binding the joiner re-checks (a revoked device is blanked).
    let ls = keying_leaf_secret(&my_secret_root, device_id);
    let kp = treekem::node_keypair_from_path_secret(&ls);
    let Some(li) = cur.tree.slots.iter().enumerate().find_map(|(i, s)| match s {
        treekem::TreeSlot::Leaf(l)
            if i % 2 == 0 && l.leaf_kem_x == kp.kem_x && l.leaf_kem_pq[..] == kp.kem_pq[..] =>
        {
            Some((i / 2) as u32)
        }
        _ => None,
    }) else { return false };
    let Some(bundle) = mls_device_bundle(st, idx, device_id) else { return false };
    let w = ShadowWelcome {
        epoch: cur.epoch,
        leaf_index: li,
        joiner_secret,
        leaf_secret: ls,
        cth: cur.cth,
        tree_bytes: cur.tree.to_bytes(),
    };
    let plaintext = encode_shadow_welcome(&cur.tip_hash, &w);
    let group = Group::new("mls-welcome", vec![bundle]);
    let Ok(env) = seal_bytes(&signer, &group, &plaintext) else { return false };
    let shadow = st.shadow_trees.get_mut(&circle_id).unwrap();
    shadow.emit_cache.push(tagged(TAG_MLS_WELCOME, &env.to_bytes()));
    true
}

/// Resolve a device node id to its public bundle among the circle's authorized devices (mine or a
/// member's) — the seal target for a re-Welcome.
fn mls_device_bundle(st: &NetState, idx: usize, device_id: &[u8; 32]) -> Option<HavenId> {
    for (bundle, _) in shadow_device_leaves(st, idx) {
        if bundle.node_id_bytes() == *device_id {
            return Some(bundle);
        }
    }
    None
}

/// Reconcile the LIVE tree with the verified roster (§4.2/§4.3 roster automation), creator-driven and
/// recomputed each bundle. Adds authorized devices missing from the tree (chained Add+Welcome) and
/// Removes tree leaves whose device is no longer authorized (revoked) via the authority-checked
/// re-key. One structural change per call (Removes first, then Adds) — the sync loop converges over
/// successive bundles. Gated on `mls_am_committer`, so OFF/shadow/non-capable circles are untouched.
fn mls_sync_roster_to_tree(st: &mut NetState, idx: usize) {
    if !mls_am_committer(st, idx) {
        return;
    }
    let circle_id = st.circles[idx].id.clone();
    let Some(shadow) = st.shadow_trees.get(&circle_id) else { return };
    if shadow.my_genesis.is_none() {
        return; // no live tree yet — genesis builds first, growth follows
    }
    let seed = st.device.as_ref().map(|d| d.secret_seed());
    let Some(cur) = mls_replay(shadow, seed) else { return };
    let tree_devices: HashSet<[u8; 32]> = tree_leaf_device_ids(&cur.tree).into_iter().collect();
    let authorized = shadow_device_leaves(st, idx);
    let auth_ids: HashSet<[u8; 32]> = authorized.iter().map(|(b, _)| b.node_id_bytes()).collect();

    // REVOKED first: any tree leaf whose device is no longer authorized is Removed (re-key). This is
    // the revocation→Remove wiring; `mls_build_remove` enforces the same authority gate receivers do.
    let mut revoked_leaves: Vec<u32> = Vec::new();
    let mut revoked_accounts: HashSet<[u8; 32]> = HashSet::new();
    for (i, slot) in cur.tree.slots.iter().enumerate() {
        if i % 2 != 0 {
            continue;
        }
        if let treekem::TreeSlot::Leaf(l) = slot {
            if let Ok(c) = DeviceCredential::from_bytes(&l.device_credential) {
                if !auth_ids.contains(&c.device.node_id_bytes()) {
                    revoked_leaves.push((i / 2) as u32);
                    revoked_accounts.insert(c.account_id);
                }
            }
        }
    }
    if !revoked_leaves.is_empty() {
        if mls_build_remove(st, idx, &revoked_leaves) {
            // Keep membership consistent (§4.3): a member whose devices are ALL revoked has no remaining
            // authorized device — drop it from circle membership so the circle recomputes capability over
            // the members that remain (and the growth pass never tries to re-Add a device-less member).
            let still_authorized: HashSet<[u8; 32]> =
                shadow_device_leaves(st, idx).iter().map(|(_, cred)| cred.account_id).collect();
            for acct in &revoked_accounts {
                if !still_authorized.contains(acct) {
                    purge_member_from_circle(&mut st.circles[idx], &hex(acct));
                }
            }
        }
        return; // one structural change per call
    }

    // Then ADD authorized devices missing from the tree (the register_device→Add wiring) — but NEVER
    // a device that was deliberately Removed (removal-sticky): re-admitting a cut-off device is an
    // explicit act, not an automation side effect of it still lingering in a roster view.
    let missing: Vec<(HavenId, DeviceCredential)> = authorized
        .into_iter()
        .filter(|(b, _)| {
            !tree_devices.contains(&b.node_id_bytes()) && !cur.removed_devices.contains(&b.node_id_bytes())
        })
        .collect();
    if !missing.is_empty() {
        mls_grow_tree(st, idx, &missing);
    }
}

/// PCS leaf-Update cadence (§6.4) — the M5 headline. Piggybacks the `rotate_if_stale` chokepoint
/// (no new timer): when a LIVE MLS circle's weekly window elapses, the committer authors a LEAF-ONLY
/// Update commit — a fresh leaf secret + UpdatePath, NO membership proposals — at the next epoch.
/// This HEALS a past compromise of the committer's leaf: the fresh leaf secret is entropy an attacker
/// who exfiltrated the old tree state does not hold, so the fresh `commit_secret` it induces mixes
/// into `epoch_secret_{n+1}` and the stolen epoch-n state opens nothing from n+1 on (the PCS test).
///
/// Fires only on the FULL bundle that also re-seals my history under the new epoch (the caller gates
/// `full_bundle`), so a leaf Update never strands a relay-only reader — the exact reason
/// `rotate_if_stale` is the one safe rotation point. No-op (returns false) unless I am the committer,
/// the window has elapsed, the circle is actually LIVE (all-joined — in shadow mode content isn't
/// tree-keyed, so a leaf Update would heal nothing and just add epoch noise), and I can derive the
/// current epoch. The leaf/entropy come from `keying_update_material` (deterministic per epoch), so a
/// replay reconstructs this own commit byte-identically via `keying_rebuild_own_commit`.
fn mls_pcs_leaf_update(st: &mut NetState, idx: usize) -> bool {
    if !mls_am_committer(st, idx) {
        return false; // switch OFF / not capable / not the committer ⇒ inert (byte-identical to M4)
    }
    // Reuse the legacy rotation window + stamp: a roster Add/Remove already re-keyed my leaf and
    // stamped `rotated_at`, so the two paths never double-commit in one bundle.
    if !st.circles[idx].pcs_window_elapsed() {
        return false;
    }
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let Some(seed) = st.device.as_ref().map(|d| d.secret_seed()) else { return false };
    let signer = Identity::from_seed(&seed);
    let my_secret_root = keying_secret_root(&seed, &gid);
    let Some(shadow) = st.shadow_trees.get(&circle_id) else { return false };
    let Some(cur) = mls_replay(shadow, Some(seed)) else { return false };
    // Only heal a circle that is actually LIVE-keying — shadow content isn't tree-keyed, so there is
    // nothing for a leaf Update to heal and advancing the shadow epoch would be pure noise.
    if !keying_all_joined(shadow, &cur.tree) {
        return false;
    }
    let Some(mp) = &cur.my_private else { return false }; // I must be an active member
    let Some(init) = cur.init_secret else { return false };
    let my_leaf = mp.leaf_index;
    let next = cur.epoch + 1;
    let (new_leaf, entropy) = keying_update_material(&my_secret_root, next);
    let Some(cred) = cur.tree.leaf(my_leaf).map(|l| l.device_credential.clone()) else { return false };
    // A LEAF-ONLY Update: empty proposal set, path = Some(fresh) ⇒ a fresh UpdatePath over my direct
    // path (§6.4). Every other member decrypts it and advances; the fresh leaf secret is the healing
    // entropy. `build_commit` already covers this shape (no dedicated helper needed).
    let build = match treekem::build_commit(
        &cur.tree, &gid, next, cur.tip_hash, &cur.cth, &init, my_leaf, vec![],
        Some((&new_leaf, &cred, &entropy)), |m| signer.sign(m), |m| signer.sign(m),
    ) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let cbytes = build.commit.to_bytes();
    let ch = treekem::commit_hash(&cbytes);
    let shadow = st.shadow_trees.get_mut(&circle_id).unwrap();
    if shadow.commits.contains_key(&ch) {
        return false; // already authored (idempotent across bundles)
    }
    shadow.commits.insert(ch, cbytes.clone());
    shadow.emit_cache.push(tagged(TAG_MLS_COMMIT, &cbytes));
    // Stamp the window so the next bundle doesn't immediately re-Update — the weekly cadence.
    st.circles[idx].rotated_at = now_secs();
    true
}

/// The keying flip (§4.5) / park-resume (§7.3), recomputed every bundle and receive. Returns the
/// live content epoch when the circle is flipped (switch ON + fully-MLS-capable + all-joined + I can
/// derive the current epoch), else `None` (shadow or parked). When live it fills `my/peer_epoch_keys`
/// with the tree-derived, ACCOUNT-scoped sender keys under `MLS_EPOCH_BASE + tree_epoch`, so the
/// unchanged content path seals/opens under the tree — and it sets `Circle::mls_live_epoch`, which
/// the author + re-seal paths read. When NOT live it clears `mls_live_epoch`, so content reverts to
/// the legacy sender-keys epoch within one bundle (park). Idempotent: pure function of verified state.
fn mls_refresh_keying(st: &mut NetState, idx: usize) -> Option<u64> {
    let clear = |st: &mut NetState, idx: usize| {
        st.circles[idx].mls_live_epoch = None;
    };
    if !st.mls_keying || !circle_is_mls_capable(st, idx) {
        clear(st, idx);
        return None;
    }
    // Tree keying requires a circle whose authority root is established by its id (an owned circle).
    // Without one there are no admins, so `mls_build_remove` refuses and the roster→Remove wiring
    // (`mls_sync_roster_to_tree`) cannot cut a removed member's leaf — they would keep deriving epoch
    // keys and reading new content. A legacy/ownerless circle therefore stays on the KeyCommit path,
    // where removal rotates the epoch and cuts them off exactly as it does today.
    if circle_admin_set(st, idx).is_none() {
        clear(st, idx);
        return None;
    }
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let seed = st.device.as_ref().map(|d| d.secret_seed());
    let Some(shadow) = st.shadow_trees.get(&circle_id) else {
        clear(st, idx);
        return None;
    };
    let Some(cur) = mls_replay(shadow, seed) else {
        clear(st, idx);
        return None;
    };
    if !keying_all_joined(shadow, &cur.tree) {
        clear(st, idx);
        return None;
    }
    let Some(sender_root) = cur.sender_root else {
        clear(st, idx);
        return None;
    };
    let content_epoch = MLS_EPOCH_BASE + cur.epoch;
    // The TREE drives the epoch on a keying-live circle — `rotate_epoch` is gated off there — so this
    // is where "the epoch moved" actually happens for MLS, and it is the case that was stranding
    // peers: content sealed at N while a member who joined or advanced sits at N+1, holding envelopes
    // it can never open. Flag it so the client re-seals its history under the new epoch.
    if st.circles[idx].my_epoch < content_epoch && !st.circles[idx].my_epoch_keys.contains_key(&content_epoch) {
        st.circles[idx].epoch_moved = true;
    }
    let me_acct = st.me().node_id_bytes();
    // Derive the account-scoped content key for every account still present in the tree. Every member
    // holds the same `sender_root`, so every member computes the identical key for each account.
    for acct in tree_leaf_accounts(&cur.tree) {
        let key = treekem::sender_key(&sender_root, &acct, &gid, cur.epoch);
        if acct == me_acct {
            st.circles[idx].my_epoch_keys.insert(content_epoch, key);
        } else {
            st.circles[idx].peer_epoch_keys.insert((hex(&acct), content_epoch), key);
        }
    }
    st.circles[idx].mls_live_epoch = Some(content_epoch);
    // FORK HEALING (committer only). A JOIN ack names the genesis its sender is on; any admitted
    // device announcing a DIFFERENT genesis than my current tip's chain joined the LOSING branch of
    // a genesis election and holds a Welcome my epoch chain will never reach. It seals at its branch
    // epoch, I seal at mine, and both sides park each other's content forever — the gauntlet's
    // signature (one leg at 778, three at 777, every cross-account step red both ways).
    //
    // The M4 re-Welcome (`mls_rewelcome_device`) already hands a device a self-contained Welcome at
    // MY live epoch; it was only ever invoked manually, for sleepers. Fire it automatically here for
    // every join-acked device whose genesis disagrees with the winning one, and for any device whose
    // announced genesis I don't even hold. Once per divergent (device, genesis) sighting: the
    // re-Welcome rides the next sync bundle, the laggard's Welcome-first entry door then takes the
    // HIGHER epoch, and the fleet converges instead of splitting.
    if mls_am_committer(st, idx) {
        let winning = {
            let shadow = st.shadow_trees.get(&st.circles[idx].id.clone());
            shadow.and_then(keying_winning_genesis).map(|(h, _)| h)
        };
        if let Some(win) = winning {
            let divergent: Vec<[u8; 32]> = st
                .shadow_trees
                .get(&st.circles[idx].id.clone())
                .map(|sh| {
                    sh.joined_genesis
                        .iter()
                        .filter(|(_, gh)| **gh != win)
                        .map(|(did, _)| *did)
                        .collect()
                })
                .unwrap_or_default();
            for did in divergent {
                if mls_rewelcome_device(st, idx, &did) {
                    // Record the heal against the winning tip so we do not re-emit every refresh:
                    // point the device at the genesis we just welcomed it toward.
                    if let Some(sh) = st.shadow_trees.get_mut(&st.circles[idx].id.clone()) {
                        sh.joined_genesis.insert(did, win);
                    }
                }
            }
        }
    }
    Some(content_epoch)
}

/// Apply a received key commit: store the epoch key (if new) and unlock any buffered events.
fn receive_key_commit(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    let env = SealedEnvelope::from_bytes(body)
        .map_err(|e| HavenError::Invalid { msg: format!("bad commit: {e}") })?;
    let sender_hex = env.sender_hex();
    let me_hex = hex(&st.me().node_id_bytes());
    // Resolve the committer to its verifying bundle AND the ACCOUNT it commits for. The epoch key is keyed
    // by the committer's ACCOUNT, never the signing device — so a device-signed commit (seed-drop S3) lands
    // in the very slot the account's own commits fill, and the read path (which looks the key up by the
    // event's author account) finds it. Three cases:
    let (committer, committer_account_hex) = if sender_hex == me_hex {
        (st.me().clone(), me_hex.clone()) // my own account-key re-synced commit (multi-device / backfill)
    } else if let Some(m) =
        st.circles[idx].members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex).cloned()
    {
        (m, sender_hex.clone()) // a member's own account key: account == sender
    } else if let Some((bundle, acct)) = authorized_device_and_account(st, idx, &sender_hex) {
        // An AUTHORIZED DEVICE of a member — or of MINE. Its credential chain to `acct` was verified at
        // roster ingest, so it commits FOR `acct`; store under `acct`. My own sibling device resolves to MY
        // account here, so its device-signed commit converges into my own-device epoch keys (below), not a
        // peer slot — preserving multi-device convergence now that siblings sign commits under device keys.
        (bundle, hex(&acct))
    } else {
        return Ok(false);
    };
    // Dual-open: try this DEVICE's key first (content sealed to my device bundle — Option 1), then fall
    // back to the ACCOUNT key (older account-sealed content, or peers who don't know my roster yet). On a
    // SEEDLESS device the account arm is simply ABSENT (`me_secret` is `None`) — everything relevant is
    // sealed to its device bundle (C), so device-only opening is complete (§2.2 E).
    let opened = st
        .device
        .as_ref()
        .and_then(|d| open_key_commit(d, &committer, &env).ok())
        .or_else(|| st.me_secret.as_ref().and_then(|m| open_key_commit(m, &committer, &env).ok()));
    let Some(opened) = opened else {
        return Ok(false); // not addressed to me, or I was excluded from this epoch
    };
    let is_new;
    {
        let c = &mut st.circles[idx];
        if committer_account_hex == me_hex {
            // OWN-DEVICE convergence — my own account key OR one of my authorized devices (seed-drop S3).
            // `ensure_epoch` mints a RANDOM key per epoch on each device, so my iPhone and Mac each
            // generated a DIFFERENT key for the same circle+epoch. Converge on the numerically-larger
            // key (both devices pick the SAME winner independently) and RETAIN the loser as an alt so
            // events my sibling sealed pre-convergence still open. Re-applying a known key is a
            // reported no-op — see `converge_epoch_key`.
            let mut primary = c.my_epoch_keys.get(&opened.epoch).copied();
            let alts = c.my_epoch_keys_alt.entry(opened.epoch).or_default();
            is_new = converge_epoch_key(&mut primary, alts, opened.epoch_key);
            if let Some(k) = primary {
                c.my_epoch_keys.insert(opened.epoch, k);
            }
            if opened.circle_secret != [0u8; 32]
                && (c.my_circle_secret == [0u8; 32] || opened.circle_secret > c.my_circle_secret)
            {
                c.my_circle_secret = opened.circle_secret;
            }
            if opened.epoch > c.my_epoch {
                c.my_epoch = opened.epoch;
            }
        } else {
            // A contact's epoch key, stored under their ACCOUNT (whether they committed under their
            // account key or an authorized device) — the same slot the read path looks up by the
            // event's author. Since device-signed commits (S3), a contact's OWN devices routinely
            // mint different keys for the same (account, epoch), and BOTH commits sit in the
            // content-addressed mailbox forever. The old last-writer-wins insert flipped this slot on
            // every re-offer — each flip reported "state changed", which the relay-hosting Mac
            // amplified into an endless re-ingest storm — and left every replica holding whichever
            // key it happened to apply last. Converge exactly like the own-device path: larger key
            // wins the primary (the committer's own devices agree on the same winner and seal future
            // content under it), losers are retained as alts so pre-convergence seals still open.
            let slot = (committer_account_hex.clone(), opened.epoch);
            let mut primary = c.peer_epoch_keys.get(&slot).copied();
            let alts = c.peer_epoch_keys_alt.entry(slot.clone()).or_default();
            is_new = converge_epoch_key(&mut primary, alts, opened.epoch_key);
            if let Some(k) = primary {
                c.peer_epoch_keys.insert(slot, k);
            }
            // The committer's stable circle secret (opaque storage-prefix derivation). Converge by
            // the same larger-wins rule the account's own devices use for their secret — a plain
            // overwrite flip-flopped between two devices' secrets on every competing commit.
            if opened.circle_secret != [0u8; 32] {
                match c.peer_circle_secrets.get(&committer_account_hex) {
                    Some(cur) if *cur >= opened.circle_secret => {}
                    _ => {
                        c.peer_circle_secrets.insert(committer_account_hex.clone(), opened.circle_secret);
                    }
                }
            }
        }
        c.prune_epoch_keys(); // bounded forward secrecy: drop stale keys
    }
    if is_new {
        drain_pending(st, idx); // a newly-learned key may unlock events that arrived early
    }
    Ok(is_new)
}

/// Park an epoch-sealed envelope in the circle's durable pending buffer (capped + de-duped).
/// EVICT-OLDEST when full: the old `if len < 512` drop-NEWEST policy guaranteed that once a
/// circle wedged at cap (hundreds of permanently-dead entries starved by epoch-key skew — the
/// live field state of both stuck DM circles), every FRESH event — the DM just sent, whose key
/// commit lands seconds later — was the one silently discarded, while its mailbox key was still
/// marked seen: deterministic permanent loss of exactly the newest content.
fn park_pending(c: &mut Circle, body: &[u8]) {
    if c.pending_epoch.iter().any(|p| p == body) {
        return;
    }
    if c.pending_epoch.len() >= 512 {
        c.pending_epoch.remove(0);
    }
    c.pending_epoch.push(body.to_vec());
}

/// Apply (or buffer, if its epoch key hasn't arrived yet) an epoch-sealed event.
fn receive_epoch_event(st: &mut NetState, idx: usize, body: &[u8]) -> Result<bool, HavenError> {
    let env = EpochEnvelope::from_bytes(body)
        .map_err(|e| HavenError::Invalid { msg: format!("bad epoch envelope: {e}") })?;
    let sender_hex = env.sender_hex();
    let me_hex = hex(&st.me().node_id_bytes());
    // Resolve the SENDER to (verifying bundle, expected author account). Three cases, all preserving today's
    // behavior for existing traffic (no contact device signs in this release):
    //   • my own account/device  → self-forward: the event's internal author (me or a friend I forwarded) is
    //     preserved, no author bind (`expected_author = None`).
    //   • a circle member's ACCOUNT key → strict bind, author must == that account (unchanged).
    //   • a circle member's AUTHORIZED DEVICE (seed-drop S1) → the device signs for its account, so bind
    //     author == that account. The credential chain proving device→account was checked at roster ingest.
    let (sender, expected_author): (Option<HavenId>, Option<String>) = if sender_hex == me_hex {
        (Some(st.me().clone()), None)
    } else if let Some(m) = st.circles[idx]
        .members
        .iter()
        .find(|m| hex(&m.node_id_bytes()) == sender_hex)
        .cloned()
    {
        (Some(m), Some(sender_hex.clone()))
    } else if let Some((bundle, acct_id)) = authorized_device_and_account(st, idx, &sender_hex) {
        (Some(bundle), Some(hex(&acct_id)))
    } else {
        (None, None)
    };
    let Some(sender) = sender else {
        // Unknown sender — most often a member's authorized device whose signed ROSTER hasn't
        // reached us yet (multi-device roster lag). Previously we DROPPED here; combined with the
        // mailbox marking the key seen at fetch time, the event was then lost forever even after we
        // learned their roster. Buffer it instead — `verify_and_store_roster`/import drains pending,
        // so once the roster arrives the event is recovered. (A genuinely-removed sender's event
        // simply never opens and ages out of the buffer.)
        let c = &mut st.circles[idx];
        park_pending(c, body);
        return Ok(false);
    };
    // The epoch key is keyed by the ACCOUNT (the committer), not the signing device — so a device-signed
    // event (S1) looks up under its account (`expected_author`), the same slot the account's key commit
    // filled. For a member's own account key or my own device this is unchanged (account == sender / me).
    let key_author_hex = expected_author.as_deref().unwrap_or(&me_hex);
    let Some(key) = st.circles[idx].key_for(&me_hex, key_author_hex, env.epoch) else {
        // Epoch key not learned yet — buffer (capped + de-duped); a later key commit unlocks it.
        let c = &mut st.circles[idx];
        park_pending(c, body);
        return Ok(false);
    };
    // M6 (§6.5): a DM sealed under the sender ratchet carries an AUTHENTICATED index. Re-derive its
    // per-message key `MK_i` from the epoch sender `key` via a per-(sender account, epoch)
    // `RatchetReceiver`, whose bounded skipped-key cache tolerates OUT-OF-ORDER and DAYS-LATE
    // delivery (the mailbox contract). A non-ratcheted envelope — feed post, the epoch-keyed re-seal
    // backstop, or any legacy/OFF traffic — opens under `key` unchanged (the switch-OFF no-op).
    let mut open_key = key;
    if let Some(i) = env.ratchet_index() {
        let gid = st.circles[idx].id.as_bytes().to_vec();
        let recv = st.circles[idx]
            .mls_ratchet
            .recv
            .entry((key_author_hex.to_string(), env.epoch))
            .or_insert_with(|| treekem::RatchetReceiver::new(&key, &gid, env.epoch));
        match recv.message_key(i) {
            Some(mk) => open_key = mk,
            None => {
                // Beyond the cache horizon, or a rejected out-of-cap jump: this ratcheted copy can't
                // open, and re-buffering would deterministically miss again. Drop it — the
                // epoch-keyed re-seal backstop (§6.1) recovers the content under the plain epoch key
                // on the next backfill. (Honest reliability caveat: a DM that is BOTH beyond the
                // ratchet horizon AND never re-sealed is unreadable — the horizon is documented on
                // `RATCHET_MAX_SKIPPED`.)
                return Ok(false);
            }
        }
    }
    // The device's hybrid signature is verified inside; the author is then bound to `expected_author`
    // (its authorizing account for a contact device, itself for a member account, or unbound for my own
    // self-forwards). A device of account A can only produce author==A, so no re-attribution is possible.
    let opened = open_event_in_epoch_authored(&sender, &open_key, &env, expected_author.as_deref());
    // FS: wipe the derived per-message key the instant it has been used (or failed). A no-op-ish
    // wipe of the plain epoch-key copy in the non-ratcheted path is harmless (the map still holds it).
    if env.ratchet_index().is_some() {
        treekem::wipe_secret(&mut open_key);
    }
    let event = match opened {
        Ok(e) => e,
        Err(_) => {
            // Pre-convergence seal: the author used a key that LOST the slot convergence (its
            // sibling's larger key won the primary). Try the bounded alt (loser) keys before giving
            // up. Ratcheted lanes stay primary-only — their chain derives from the slot winner, and
            // the epoch-keyed re-seal backstop recovers anything the ratchet can't.
            if env.ratchet_index().is_some() {
                return Ok(false);
            }
            let alts = st.circles[idx].alt_keys_for(&me_hex, key_author_hex, env.epoch);
            match alts
                .iter()
                .find_map(|k| open_event_in_epoch_authored(&sender, k, &env, expected_author.as_deref()).ok())
            {
                Some(e) => e,
                None => return Ok(false),
            }
        }
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
    // Dual-open: device key (Option 1), then account key (legacy account-sealed). Seedless: no account arm.
    let event = match st.device.as_ref().and_then(|d| open_event(d, &sender, &env).ok()) {
        Some(e) => e,
        None => st
            .me_secret
            .as_ref()
            .and_then(|m| open_event(m, &sender, &env).ok())
            .ok_or_else(|| HavenError::Invalid { msg: "open failed".into() })?,
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
    // GC provably-DEAD parked entries so they can't starve the 512-slot buffer. An envelope
    // sealed at epoch E is unrecoverable once every key-holder has pruned past E: senders keep
    // only the last KEEP_EPOCHS(4) epochs (`prune_epoch_keys`), so when the newest epoch we know
    // for that sender is > E + 4, the commit that opens E can never be re-offered. The field
    // failure state was two circles wedged AT cap with exactly such fossils (peer events at
    // epoch 5 against a held window of 7–10) while fresh DMs bounced off the full buffer.
    let me_hex = hex(&st.me().node_id_bytes());
    let c = &mut st.circles[idx];
    let my_epoch = c.my_epoch;
    let newest_by_author: std::collections::HashMap<String, u64> = {
        let mut m: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
        for ((acct, e), _) in c.peer_epoch_keys.iter() {
            let cur = m.entry(acct.clone()).or_insert(0);
            if *e > *cur {
                *cur = *e;
            }
        }
        m.insert(me_hex.clone(), my_epoch);
        m
    };
    c.pending_epoch.retain(|raw| {
        let Ok(env) = EpochEnvelope::from_bytes(raw) else { return false };
        let author = env.sender_hex();
        match newest_by_author.get(&author) {
            // Keep anything whose sealing epoch is still within (or ahead of) the recoverable
            // window; drop fossils more than KEEP_EPOCHS behind the newest key we hold.
            Some(&newest) => env.epoch + 4 >= newest,
            // Unknown author (roster not learned yet) — keep; the roster drain recovers it.
            None => true,
        }
    });
}

thread_local! {
    /// Set by the tree handlers when a false return is RETRYABLE (orphan commit, roster lag) rather
    /// than terminal (not mine, unauthorized, stored-by-design). Consumed by the receive() arms to
    /// decide parking. Thread-local because the handlers' public signatures are stable API.
    static TREE_RETRYABLE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Park an unapplied TREE envelope (raw, tagged) for replay. Deduped, capped at 128 — tree traffic
/// is a few dozen envelopes per membership change, not a content stream.
fn park_pending_tree(c: &mut Circle, raw: &[u8]) {
    if c.pending_tree.iter().any(|p| p == raw) {
        return;
    }
    if c.pending_tree.len() >= 128 {
        c.pending_tree.remove(0);
    }
    c.pending_tree.push(raw.to_vec());
    c.pending_tree_retries = 0;   // new material — the poll-driven retry gets a fresh allowance
}

/// Replay parked tree envelopes until a full pass applies nothing. Each application can unlock the
/// next (commits are ordered by epoch), so loop-while-progress rather than single-pass. Envelopes
/// that still don't apply go back in the buffer and wait for the next trigger.
fn drain_pending_tree(st: &mut NetState, idx: usize) {
    for _ in 0..16 {
        let pending = std::mem::take(&mut st.circles[idx].pending_tree);
        if pending.is_empty() {
            return;
        }
        let mut progressed = false;
        for raw in pending {
            TREE_RETRYABLE.with(|f| f.set(false));
            let applied = match raw.first() {
                Some(&TAG_MLS_COMMIT) => receive_mls_commit(st, idx, &raw[1..]).unwrap_or(false),
                Some(&TAG_MLS_WELCOME) => receive_mls_welcome(st, idx, &raw[1..]).unwrap_or(false),
                Some(&TAG_MLS_JOIN) => receive_mls_join(st, idx, &raw[1..]).unwrap_or(false),
                _ => false,
            };
            if applied {
                progressed = true;
            } else if TREE_RETRYABLE.with(|f| f.get()) {
                park_pending_tree(&mut st.circles[idx], &raw);
            } else {
                // Terminal on replay too (e.g. its roster arrived and revealed it as someone
                // else's, or it stored) — drop it from the buffer rather than churn forever.
                progressed = true;
            }
        }
        if progressed {
            mls_refresh_keying(st, idx);
            drain_pending(st, idx);
        } else {
            return;
        }
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

/// TreeKEM M2 SHADOW telemetry (`docs/TREEKEM-DESIGN.md` §9 row M2) — the soak signal. Reports
/// this device's view of the parallel ratchet tree for a circle: the epoch it resolved, the
/// winning tree's hash (hex), whether it converged (holds the winning genesis's Welcome and could
/// derive its epoch secret), and how many extra genesis commits it saw (a §5 fork count). NONE of
/// this is consumed for content keys — it exists only to be compared across the fleet during the
/// M2 beta soak. `converged=false` with an empty hash means the shadow tree isn't running here (a
/// non-capable circle, or no genesis yet).
#[derive(uniffi::Record)]
pub struct MlsShadowStatusFfi {
    pub epoch: u64,
    pub tree_hash_hex: String,
    pub converged: bool,
    pub fork_count: u32,
}

/// TreeKEM M3 KEYING telemetry (`docs/TREEKEM-DESIGN.md` §4.5/§7.2/§7.3). Reports which keying regime
/// a circle is in on THIS device and the tree epoch that keys its content:
///   * `"off"`    — the master switch is off (M2 shadow only, if capable), or the circle isn't MLS.
///   * `"shadow"` — switch on + capable, but not yet all-joined ⇒ dual-stack (KeyCommit still keys).
///   * `"parked"` — was flippable but a non-capable / not-yet-joined device is present ⇒ reverted to
///                  KeyCommit within one bundle (§7.3), tree state preserved for a later re-flip.
///   * `"live"`   — flipped: content is keyed by the tree (§4.5), the legacy KeyCommit has stopped.
/// `epoch` is the tree epoch (1 = genesis; +1 per applied Remove) when live, else 0.
#[derive(uniffi::Record)]
pub struct MlsKeyingStatusFfi {
    pub state: String,
    pub epoch: u64,
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
    /// Removed-member tombstones (bundle bytes). Defaulted so older state files load with none.
    #[serde(default)]
    removed_members: Vec<Vec<u8>>,
    events: Vec<Event>,
    /// Sender-keys epoch ratchet (defaulted so pre-epoch state files still load → bootstrap on next post).
    #[serde(default)]
    my_epoch: u64,
    #[serde(default)]
    my_epoch_keys: Vec<(u64, [u8; 32])>,
    #[serde(default)]
    peer_epoch_keys: Vec<(String, u64, [u8; 32])>,
    /// Losing candidates per epoch slot (see `Circle::my_epoch_keys_alt`). Defaulted so state files
    /// from before slot convergence load with none; older builds simply ignore the field.
    #[serde(default)]
    my_epoch_keys_alt: Vec<(u64, [u8; 32])>,
    #[serde(default)]
    peer_epoch_keys_alt: Vec<(String, u64, [u8; 32])>,
    #[serde(default)]
    my_circle_secret: [u8; 32],
    #[serde(default)]
    peer_circle_secrets: Vec<(String, [u8; 32])>,
    /// Unix seconds of the last epoch advance, so the periodic rotation window survives a relaunch
    /// (otherwise every launch would restart the week and a frequently-restarted client would never
    /// rotate). Defaulted to 0 on older state files: the next full bundle stamps it and starts the
    /// window rather than rotating every existing circle at once on upgrade.
    #[serde(default)]
    rotated_at: u64,
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
    #[serde(default)]
    pending_tree: Vec<Vec<u8>>,
    /// MLS M3: the pinned circle creator (Remove/Add authority root, §4.3). Defaulted so old state
    /// files load with no creator (⇒ no tree Remove is accepted until one is learned).
    #[serde(default)]
    creator: Option<[u8; 32]>,
    /// AUDIT M2: whether `creator` is DEFINITION-bound (authoritative) vs weakly TOFU-learned. Defaulted
    /// false so old state files load with today's TOFU semantics (an authentic definition re-pins it).
    #[serde(default)]
    creator_pinned: bool,
    /// MLS M3: verified admin-grant wire bytes (the delegation edges). Defaulted so old state loads.
    #[serde(default)]
    admin_grants: Vec<Vec<u8>>,
}
#[derive(serde::Serialize, serde::Deserialize)]
struct PersistState {
    circles: Vec<PersistCircle>,
    /// Verified device rosters (account_bundle, device_list_bytes, credential_bytes), so multi-device
    /// state survives restarts WITHOUT re-rotating epochs (those persist alongside in PersistCircle).
    #[serde(default)]
    device_rosters: Vec<(Vec<u8>, Vec<u8>, Vec<Vec<u8>>)>,
    /// A3: the primary-signed roster WIRE (incl. capability trailer) a SEEDLESS device rebroadcasts
    /// verbatim (it has no account key to re-mint one). `None` on a primary. Defaulted so old state loads.
    #[serde(default)]
    seedless_roster_wire: Option<Vec<u8>>,
    /// D8: my signed profile card, cached so a seedless device serves the primary's card verbatim (and a
    /// primary re-serves the same bytes). Defaulted so old state loads.
    #[serde(default)]
    cached_profile: Option<Vec<u8>>,
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
    /// Outer-bytes hashes of envelopes `receive` has already processed, per circle. Envelopes
    /// seal deterministically, and peers re-blast full histories on a timer — so the same bytes
    /// arrive over and over, and proving "duplicate" used to cost a full unseal UNDER THE ENGINE
    /// LOCK per envelope. Session-scoped ON PURPOSE (never persisted): a restart re-ingests each
    /// envelope once, so a cleared circle or imported state can never be wedged by a stale set.
    seen_envelopes: Mutex<std::collections::HashMap<String, std::collections::HashSet<[u8; 32]>>>,
}

#[uniffi::export]
impl HavenSocial {
    #[uniffi::constructor]
    pub fn new(account_seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let seed: [u8; 32] = account_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })?;
        let me = Identity::from_seed(&seed);
        let me_pub = me.public();
        Ok(Arc::new(Self {
            state: Mutex::new(NetState {
                me_pub: me_pub.clone(),
                me_secret: Some(me),
                seedless_roster_wire: None,
                cached_profile: None,
                device: None,
                circles: vec![Circle::bare(DEFAULT_CIRCLE.to_string(), "My Circle".to_string())],
                device_lists: std::collections::HashMap::new(),
                // I ship the S1 verifier, so I'm seed-drop-capable — seed my own account so a fully-upgraded
                // circle (including me) computes as such. Nothing consumes this in production yet.
                seed_drop_capable: {
                    let mut s = std::collections::HashSet::new();
                    s.insert(me_pub.node_id_bytes());
                    s
                },
                // Same self-seeding for the MLS marker (M0): this build advertises `ml`, so my own
                // account must count as capable or a circle containing me could never compute as
                // fully MLS-capable. Nothing consumes this in production yet.
                mls_capable: {
                    let mut s = std::collections::HashSet::new();
                    s.insert(me_pub.node_id_bytes());
                    s
                },
                // This build reads the compact container, so my own account must count as capable or
                // a circle containing me could never compute as fully capable and would stay on JSON
                // forever.
                compact_wire_capable: {
                    let mut s = std::collections::HashSet::new();
                    s.insert(me_pub.node_id_bytes());
                    s
                },
                keep_own_posts: false,
                retire_account_key: false,
                shadow_trees: std::collections::HashMap::new(),
                mls_keying: false,
                live_lane_circles: std::collections::HashSet::new(),
            }),
            seen_envelopes: Mutex::new(std::collections::HashMap::new()),
        }))
    }

    /// A SEEDLESS engine (seed-drop S4): a NEW device that holds its own device key + an account-signed
    /// credential + a granted self-sync key, but NEVER the account master seed. It is constructed from the
    /// account's PUBLIC bundle (the authorship id / contact id / roster verification anchor) and a device
    /// seed — the device identity is therefore ALWAYS present here (enforced below), because a seedless
    /// device with no transport/open identity could neither dial nor open anything sealed to it.
    ///
    /// `me_secret` is `None`, so every account private-key site (roster signing, profile card, account-key
    /// authorship, dual-open account fallback) branches off — the `Option` refactor makes each a compile
    /// error until handled. Mirrors [`Self::new`] otherwise: self-seeds the account into `seed_drop_capable`
    /// + `mls_capable` (this build ships the S1 verifier + advertises `ml`), so a circle of fully-upgraded
    /// members that includes this account computes as fully capable — the S4 precondition for a seedless
    /// device to author readable, device-signed content.
    #[uniffi::constructor]
    pub fn new_seedless(account_public_bundle: Vec<u8>, device_seed: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let me_pub = HavenId::from_bytes(&account_public_bundle)
            .map_err(|e| HavenError::Invalid { msg: format!("bad account bundle: {e}") })?;
        let dev_seed: [u8; 32] = device_seed
            .try_into()
            .map_err(|_| HavenError::Invalid { msg: "device seed must be 32 bytes".into() })?;
        let account_id = me_pub.node_id_bytes();
        Ok(Arc::new(Self {
            state: Mutex::new(NetState {
                me_pub,
                me_secret: None,
                seedless_roster_wire: None,
                cached_profile: None,
                device: Some(Identity::from_seed(&dev_seed)),
                circles: vec![Circle::bare(DEFAULT_CIRCLE.to_string(), "My Circle".to_string())],
                device_lists: std::collections::HashMap::new(),
                seed_drop_capable: {
                    let mut s = std::collections::HashSet::new();
                    s.insert(account_id);
                    s
                },
                mls_capable: {
                    let mut s = std::collections::HashSet::new();
                    s.insert(account_id);
                    s
                },
                // This build reads the compact container; self-seed so a circle containing this
                // account can compute as fully capable (mirrors `Self::new`).
                compact_wire_capable: {
                    let mut s = std::collections::HashSet::new();
                    s.insert(account_id);
                    s
                },
                keep_own_posts: false,
                retire_account_key: false,
                shadow_trees: std::collections::HashMap::new(),
                mls_keying: false,
                live_lane_circles: std::collections::HashSet::new(),
            }),
            seen_envelopes: Mutex::new(std::collections::HashMap::new()),
        }))
    }

    /// Install the primary's signed profile "business card" so a SEEDLESS device (which cannot mint one,
    /// D8) can serve it to contacts. The card arrives via self-sync / the full-state push; the client hands
    /// it here. Stored + persisted, then returned by `my_signed_profile`. No verification here — the card is
    /// self-verifying (contacts check its signature against the account bundle via `verify_profile_card`).
    pub fn set_cached_profile(&self, blob: Vec<u8>) {
        self.state.lock().unwrap().cached_profile = if blob.is_empty() { None } else { Some(blob) };
    }

    /// True on a SEEDLESS device (no account master seed) — the app skips `register_device` + push
    /// registration and drives the enroll/self-sync-grant flow instead. False on a primary/legacy device.
    pub fn is_seedless(&self) -> bool {
        self.state.lock().unwrap().me_secret.is_none()
    }

    /// Viewer preference: keep MY OWN posts even when viewer auto-delete would drop them (personal
    /// archive). A sender-set expiry on my own post still applies. Set on launch + when the toggle flips.
    pub fn set_keep_own_posts(&self, on: bool) {
        self.state.lock().unwrap().keep_own_posts = on;
    }

    /// Flip the seed-drop RETIREMENT master switch (S5). Default OFF. When ON, a circle every member of
    /// which is affirmatively seed-drop-capable seals ONLY to authorized device bundles (the bare account
    /// key is dropped) so a revoked device is cut off cryptographically; a circle with any non-capable
    /// member keeps today's dual-seal. The app sets this on launch (staged rollout: OFF during the
    /// dual-seal soak, ON once the fleet has converged). Rotates nothing by itself — the change takes
    /// effect at the next key commit / epoch re-seal.
    pub fn set_seed_drop_retire(&self, on: bool) {
        self.state.lock().unwrap().retire_account_key = on;
    }

    /// Flip the MLS KEYING master switch (M3, docs/TREEKEM-DESIGN.md §4.5). Default OFF; NOT persisted;
    /// the app re-applies it on launch — mirrors `set_seed_drop_retire` exactly. Ships DARK. When ON, a
    /// circle that is fully-MLS-capable AND all-joined (§7.2) draws its content epoch key from the tree
    /// and STOPS emitting the legacy KeyCommit; a not-yet-all-joined circle stays dual-stack, and one a
    /// non-capable/not-yet-joined device (re)joins PARKS back to KeyCommit within one bundle (§7.3).
    /// Changes nothing by itself — the flip/park is recomputed at the next bundle / receive.
    pub fn set_mls_keying(&self, on: bool) {
        self.state.lock().unwrap().mls_keying = on;
    }

    /// Mark a circle as the DM / LIVE lane (M6, docs/TREEKEM-DESIGN.md §6.5) — the app calls this for
    /// its one-to-one and live-traffic circles. ONLY a marked, keying-LIVE circle uses the
    /// per-message sender ratchet; feed circles stay epoch-keyed (the task scope). Session state, NOT
    /// persisted; the app re-marks on launch, like `set_mls_keying`. Consulted only under the
    /// `mls_keying`-ON author path, so this is a no-op for content while the master switch is OFF.
    pub fn set_circle_live_lane(&self, circle_id: String, on: bool) {
        let mut st = self.state.lock().unwrap();
        if on {
            st.live_lane_circles.insert(circle_id);
        } else {
            st.live_lane_circles.remove(&circle_id);
        }
    }

    /// Pin the circle CREATOR — the root of Remove/Add authority (§4.3). If `account_hex` is my own
    /// account and I hold the account key, this also issues a self-admin grant so the pin propagates to
    /// (and is verifiable by) every member on the control lane. Returns false for an unknown circle.
    ///
    /// AUDIT M2: this is the AUTHENTICATED establishment of the creator (the app calls it at circle
    /// creation and when the creator is learned out-of-band). It marks the pin DEFINITION-bound, which
    /// (a) overrides any weakly-TOFU'd creator a hostile grant may have raced in, and (b) makes every
    /// subsequent disagreeing grant unable to dislodge it (`receive_admin_grant`).
    pub fn set_circle_creator(&self, circle_id: String, account_hex: String) -> bool {
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return false };
        let Ok(creator) = decode_hex32(&account_hex) else { return false };
        // The creator is authoritative only when the circle id cryptographically binds to it (an
        // owned `c1…` id from `create_circle_owned`). On a legacy/ownerless circle the id binds no
        // one, so this is a no-op returning false: those circles have no cryptographic creator and
        // use the legacy removal path.
        if !circle_id_binds_creator(&circle_id, &creator) {
            return false;
        }
        st.circles[idx].creator = Some(creator);
        st.circles[idx].creator_pinned = true;
        // Announce the creator to peers via a self-grant (creator→creator), signed by my account key,
        // so a receiver learns + verifies the pin. Only possible when I AM the creator and hold the key.
        let me = st.me().node_id_bytes();
        if creator == me {
            if let Some(acct) = st.me_secret.as_ref().map(|m| Identity::from_seed(&m.secret_seed())) {
                let gid = circle_id.as_bytes().to_vec();
                let g = AdminGrant::issue(&acct, &gid, creator, creator, 1);
                let w = g.to_bytes();
                if !st.circles[idx].admin_grants.iter().any(|e| *e == w) {
                    st.circles[idx].admin_grants.push(w);
                }
            }
        }
        true
    }

    /// Offer to carry a LEGACY circle onto a creator-bound successor, so it can gain an authority root
    /// (and therefore authenticated eviction + tree keying, which a legacy id can never have).
    ///
    /// Mints an owned successor, creates it locally carrying the same name + members, pins me as its
    /// creator, and stores an account-signed offer on the legacy circle's lane so members receive it.
    /// Returns the successor id, or `None` if this circle is already owned / unknown / I hold no
    /// account key. Members do NOT follow automatically — see `pending_circle_upgrades`.
    pub fn upgrade_circle(&self, legacy_circle_id: String) -> Option<String> {
        let mut st = self.state.lock().unwrap();
        let idx = st.circles.iter().position(|c| c.id == legacy_circle_id)?;
        let me = st.me().node_id_bytes();
        // Only a circle with NO provable owner can be upgraded. An owned id already names its creator,
        // so an "offer" there isn't a migration — it's one member asking others to follow them off a
        // circle that is demonstrably someone else's. Refuse to author that.
        if !upgradable_circle(&st, idx) {
            return None;
        }
        // Idempotent: if I've already offered, hand back the successor I already minted rather than
        // stranding another orphan circle behind every tap.
        if let Some(existing) = st.circles[idx]
            .upgrade_offers
            .iter()
            .filter_map(|w| CircleUpgrade::from_bytes(w).ok())
            .find(|u| u.creator == me)
        {
            return String::from_utf8(existing.new_circle_id).ok();
        }
        let acct = st.me_secret.as_ref().map(|m| Identity::from_seed(&m.secret_seed()))?;
        let name = st.circles[idx].name.clone();
        let members = st.circles[idx].members.clone();
        // Carry my LOCAL view of the circle's history onto the successor so the upgraded circle isn't
        // empty. These are already-opened events in my log; copying them makes the successor render the
        // same feed I see today. Each member who follows carries their OWN decrypted view forward the
        // same way — no re-broadcast of anyone else's posts, no key gymnastics. New posts land under the
        // successor's (eventually tree-keyed) lane. `seen` rides along so re-sync can't double-add them.
        let events = st.circles[idx].events.clone();
        let seen = st.circles[idx].seen.clone();
        let new_id = mint_owned_circle_id(&me);
        // Highest offer I've made for this circle before, so a re-offer supersedes.
        let version = st.circles[idx]
            .upgrade_offers
            .iter()
            .filter_map(|w| CircleUpgrade::from_bytes(w).ok())
            .filter(|u| u.creator == me)
            .map(|u| u.version)
            .max()
            .unwrap_or(0)
            + 1;
        let offer = CircleUpgrade::issue(&acct, legacy_circle_id.as_bytes(), new_id.as_bytes(), &name, version);
        let wire = offer.to_bytes();
        st.circles[idx].upgrade_offers.retain(|w| {
            CircleUpgrade::from_bytes(w).map(|u| u.creator != me).unwrap_or(true)
        });
        st.circles[idx].upgrade_offers.push(wire);
        // Stand the successor up locally, carrying membership over.
        if !st.circles.iter().any(|c| c.id == new_id) {
            let mut c = Circle::bare(new_id.clone(), name);
            c.members = members;
            c.events = events;
            c.seen = seen;
            c.creator = Some(me);
            c.creator_pinned = true;
            st.circles.push(c);
        }
        drop(st);
        // Announce me as the successor's creator (issues the propagating self-grant).
        let _ = self.set_circle_creator(new_id.clone(), self.my_node_hex());
        Some(new_id)
    }

    /// Upgrade offers seen on `circle_id` that I haven't followed: "`from_hex` says this circle's
    /// creator-bound successor is `new_circle_id`". Each is signature-verified and the successor is
    /// proven to bind its offerer — but NOT that the offerer created this circle, which no signature
    /// can establish. Surface these for the user to choose; more than one is a legitimate state.
    pub fn pending_circle_upgrades(&self, circle_id: String) -> Vec<CircleUpgradeOffer> {
        let st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return vec![] };
        if !upgradable_circle(&st, idx) {
            return vec![]; // an owned circle has nothing to be carried onto
        }
        st.circles[idx]
            .upgrade_offers
            .iter()
            .filter_map(|w| CircleUpgrade::from_bytes(w).ok())
            // Hide an offer ONLY on my own recorded accept. Anything inferred from the successor's
            // presence or its pinned creator is arrangeable by a peer — it can hand me the id to stand
            // up (that's how joining any circle works) and a grant naming the true creator pins it — so
            // inferring would let a member bury the offer they least want me to follow, permanently.
            .filter(|u| {
                st.circles[idx].followed_upgrade.as_deref().map(str::as_bytes) != Some(&u.new_circle_id)
            })
            .map(|u| CircleUpgradeOffer {
                legacy_circle_id: circle_id.clone(),
                new_circle_id: String::from_utf8_lossy(&u.new_circle_id).to_string(),
                from_hex: hex(&u.creator),
                name: u.name.clone(),
                mine: u.creator == st.me().node_id_bytes(),
            })
            .collect()
    }

    /// Follow an upgrade offer: stand up the successor locally, carrying this circle's members, and pin
    /// the offerer as its (binding-verified) creator. This is the deliberate human step — the caller
    /// MUST have shown the user who is claiming the circle. Returns false if the offer is unknown or
    /// its successor doesn't bind the offerer.
    pub fn accept_circle_upgrade(&self, circle_id: String, new_circle_id: String) -> bool {
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return false };
        // Re-check at the point of action: never follow anyone off a circle that already names its
        // creator (an offer can't legitimately exist there, and the user has no way to judge one).
        if !upgradable_circle(&st, idx) {
            return false;
        }
        let Some(up) = st.circles[idx]
            .upgrade_offers
            .iter()
            .filter_map(|w| CircleUpgrade::from_bytes(w).ok())
            .find(|u| u.new_circle_id == new_circle_id.as_bytes())
        else {
            return false;
        };
        // Re-check the binding at the point of action (never trust it was checked at ingest alone).
        if !circle_id_binds_creator(&new_circle_id, &up.creator) {
            return false;
        }
        let members = st.circles[idx].members.clone();
        // Carry my local history onto the successor so following an upgrade doesn't drop the feed to
        // empty (see `upgrade_circle`). My own view only — every follower carries their own.
        let events = st.circles[idx].events.clone();
        let seen = st.circles[idx].seen.clone();
        let creator_hex = hex(&up.creator);
        if !st.circles.iter().any(|c| c.id == new_circle_id) {
            let mut c = Circle::bare(new_circle_id.clone(), up.name.clone());
            c.members = members;
            c.events = events;
            c.seen = seen;
            st.circles.push(c);
        }
        // Record MY act — this, and only this, hides the offer from now on.
        st.circles[idx].followed_upgrade = Some(new_circle_id.clone());
        drop(st);
        // Pin the offerer as the successor's creator — binding-verified, so this is authenticated.
        self.set_circle_creator(new_circle_id, creator_hex)
    }

    /// Legacy circles I've COMMITTED to a successor for — so the app can collapse the duplicate out of
    /// the circle picker and show only the upgraded (owned) circle in its place. A circle is superseded
    /// for me when either I FOLLOWED someone's offer off it (`followed_upgrade`), or I AUTHORED an
    /// upgrade for it and the successor now exists locally. Both mean "there's a newer circle carrying
    /// this one's name + members + history that I'm now using" — the legacy id lingers only to keep
    /// receiving/relaying the offer to stragglers, and should never appear as a second row to me.
    pub fn superseded_circle_ids(&self) -> Vec<String> {
        let st = self.state.lock().unwrap();
        let me = st.me().node_id_bytes();
        let mut out = vec![];
        for c in &st.circles {
            if c.followed_upgrade.is_some() {
                out.push(c.id.clone());
                continue;
            }
            let mine = c
                .upgrade_offers
                .iter()
                .filter_map(|w| CircleUpgrade::from_bytes(w).ok())
                .find(|u| u.creator == me);
            if let Some(u) = mine {
                if st.circles.iter().any(|x| x.id.as_bytes() == u.new_circle_id.as_slice()) {
                    out.push(c.id.clone());
                }
            }
        }
        out
    }

    /// The owned successor a superseded legacy circle was migrated onto (mine or one I followed), so the
    /// app can move a user sitting on a now-superseded circle straight to its replacement. `None` if the
    /// circle isn't superseded for me. Mirror of [`superseded_circle_ids`].
    pub fn circle_successor(&self, circle_id: String) -> Option<String> {
        let st = self.state.lock().unwrap();
        let me = st.me().node_id_bytes();
        let c = st.circles.iter().find(|c| c.id == circle_id)?;
        if let Some(f) = &c.followed_upgrade {
            return Some(f.clone());
        }
        c.upgrade_offers
            .iter()
            .filter_map(|w| CircleUpgrade::from_bytes(w).ok())
            .find(|u| u.creator == me)
            .and_then(|u| String::from_utf8(u.new_circle_id).ok())
            .filter(|id| st.circles.iter().any(|x| &x.id == id))
    }

    /// Delegate circle admin to `admin_hex` (§4.3). Requires that I am currently an admin (the creator
    /// or a creator-delegated admin) AND hold my account key. The grant is account-signed, versioned
    /// (higher-wins), stored, and re-broadcast on the control lane. Returns false if unauthorized.
    pub fn grant_circle_admin(&self, circle_id: String, admin_hex: String) -> bool {
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return false };
        let Ok(admin) = decode_hex32(&admin_hex) else { return false };
        let Some(creator) = st.circles[idx].creator else { return false };
        let me = st.me().node_id_bytes();
        // I must currently be an admin to delegate.
        match circle_admin_set(&st, idx) {
            Some(admins) if admins.contains(&me) => {}
            _ => return false,
        }
        let Some(acct) = st.me_secret.as_ref().map(|m| Identity::from_seed(&m.secret_seed())) else { return false }; // grant must be account-signed
        let gid = circle_id.as_bytes().to_vec();
        // Next version for this (admin) key: one past the highest we hold.
        let mut version = 1u64;
        for w in &st.circles[idx].admin_grants {
            if let Ok(g) = AdminGrant::from_bytes(w) {
                if g.admin_account == admin && g.creator == creator {
                    version = version.max(g.version + 1);
                }
            }
        }
        let g = AdminGrant::issue(&acct, &gid, creator, admin, version);
        let w = g.to_bytes();
        // Replace any older stored grant for this admin, else append.
        let grants = &mut st.circles[idx].admin_grants;
        if let Some(slot) = grants.iter_mut().find(|e| {
            AdminGrant::from_bytes(e).map(|x| x.admin_account == admin && x.creator == creator).unwrap_or(false)
        }) {
            *slot = w;
        } else {
            grants.push(w);
        }
        true
    }

    /// The current admin accounts of a circle (hex) — the creator plus every creator-delegated admin
    /// (`admin_closure`). Empty when no creator is pinned.
    pub fn circle_admins(&self, circle_id: String) -> Vec<String> {
        let st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return vec![] };
        match circle_admin_set(&st, idx) {
            Some(admins) => {
                let mut v: Vec<String> = admins.iter().map(|a| hex(a)).collect();
                v.sort();
                v
            }
            None => vec![],
        }
    }

    /// Remove a MEMBER's devices from the MLS tree, re-keying so they are cryptographically cut off
    /// (§4.3, the headline). Authorized only for the creator/an admin (checked inside `mls_build_remove`
    /// against the same verified chain receivers use); a non-admin call is a no-op. Builds ONE chained
    /// Remove+UpdatePath commit removing every leaf of `account_hex` at the next epoch; the removed
    /// device cannot derive the new `commit_secret` and so cannot open content sealed afterward. On a
    /// successful Remove it ALSO drops the account from circle membership (M4: keeps the roster and the
    /// tree consistent — a member cut from the tree is cut from the circle, not silently re-Added by the
    /// growth automation). Returns whether a Remove commit was authored.
    pub fn mls_remove_member(&self, circle_id: String, account_hex: String) -> bool {
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return false };
        let Ok(target) = decode_hex32(&account_hex) else { return false };
        let seed = st.device.as_ref().map(|d| d.secret_seed());
        let Some(shadow) = st.shadow_trees.get(&circle_id) else { return false };
        let Some(cur) = mls_replay(shadow, seed) else { return false };
        // Every current leaf of the target account (a member may run multiple devices).
        let mut leaves: Vec<u32> = Vec::new();
        for (i, slot) in cur.tree.slots.iter().enumerate() {
            if let treekem::TreeSlot::Leaf(l) = slot {
                if i % 2 == 0 {
                    if let Ok(c) = DeviceCredential::from_bytes(&l.device_credential) {
                        if c.account_id == target {
                            leaves.push((i / 2) as u32);
                        }
                    }
                }
            }
        }
        if leaves.is_empty() {
            return false;
        }
        let removed = mls_build_remove(&mut st, idx, &leaves);
        if removed {
            // Drop the member from circle membership so the roster automation (`mls_grow_tree`) does
            // not immediately re-Add them: a tree Remove and a circle removal are one act (§4.3).
            let target_hex = hex(&target);
            purge_member_from_circle(&mut st.circles[idx], &target_hex);
        }
        removed
    }

    /// Re-Welcome a device that slept past the mailbox TTL (§5.5): hand it a FRESH self-contained
    /// Welcome at the CURRENT epoch so it re-enters without replaying the (pruned) chain and reads
    /// history from the ordinary re-seal backfill. Creator/keying-gated inside; a no-op otherwise.
    /// Returns whether a re-Welcome was emitted (it rides the next sync bundle to the sleeper).
    pub fn mls_rewelcome(&self, circle_id: String, device_hex: String) -> bool {
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return false };
        let Ok(device_id) = decode_hex32(&device_hex) else { return false };
        mls_rewelcome_device(&mut st, idx, &device_id)
    }

    /// M3 keying telemetry (§4.5/§7.2/§7.3): `{state, epoch}` — see [`MlsKeyingStatusFfi`].
    pub fn mls_keying_status(&self, circle_id: String) -> MlsKeyingStatusFfi {
        let mut st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else {
            return MlsKeyingStatusFfi { state: "off".into(), epoch: 0 };
        };
        if !st.mls_keying || !circle_is_mls_capable(&st, idx) {
            return MlsKeyingStatusFfi { state: "off".into(), epoch: 0 };
        }
        // Recompute the flip. Some ⇒ live; None ⇒ shadow (not yet all-joined) or parked (a genesis
        // exists but the gate went false). We distinguish by whether the tree has run at all here.
        if let Some(content_epoch) = mls_refresh_keying(&mut st, idx) {
            return MlsKeyingStatusFfi { state: "live".into(), epoch: content_epoch - MLS_EPOCH_BASE };
        }
        let has_tree = st
            .shadow_trees
            .get(&circle_id)
            .map(|s| !s.commits.is_empty())
            .unwrap_or(false);
        let seed = st.device.as_ref().map(|d| d.secret_seed());
        let all_joined = st.shadow_trees.get(&circle_id).and_then(|s| {
            mls_replay(s, seed).map(|cur| keying_all_joined(s, &cur.tree))
        }).unwrap_or(false);
        // "parked": the tree could carry keying (genesis + all-joined) but the gate refused this bundle
        // (e.g. a non-capable device present) — though if we reached here the circle IS capable, so a
        // false gate with an all-joined tree means we couldn't derive (removed). Otherwise "shadow".
        let state = if has_tree && all_joined { "parked" } else { "shadow" };
        MlsKeyingStatusFfi { state: state.into(), epoch: 0 }
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
            None => hex(&st.me().node_id_bytes()),
        }
    }

    /// This device's public bundle (for `register_device` — the routable bundle contacts seal to).
    pub fn my_device_bundle(&self) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        match &st.device {
            Some(d) => d.public().to_bytes(),
            None => st.me().to_bytes(),
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

    /// Create a circle you OWN — its id cryptographically binds to your account, so its creator is
    /// fixed by the id and established by every member without relying on an unauthenticated claim.
    /// Returns the new id. This is the path every user-created circle should take so its members share
    /// a verifiable creator for eviction authority; `create_circle` (caller-chosen id) stays for the
    /// default/dm/legacy circles that have no owner. Idempotent on the returned id.
    pub fn create_circle_owned(&self, name: String) -> String {
        let me = { self.state.lock().unwrap().me().node_id_bytes() };
        let id = mint_owned_circle_id(&me);
        {
            let mut st = self.state.lock().unwrap();
            if !st.circles.iter().any(|c| c.id == id) {
                st.circles.push(Circle::bare(id.clone(), name));
            }
        }
        // Pin + announce me as the (binding-verified) creator, issuing the propagating self-grant.
        let _ = self.set_circle_creator(id.clone(), self.my_node_hex());
        id
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
        drop(st);
        // Re-joining must be able to re-ingest the history this circle held.
        self.seen_envelopes.lock().unwrap().remove(&id);
    }

    /// Remove a member from ONE circle (their membership + their events there) without
    /// blocking them globally — they stay in your other circles and your default circle.
    pub fn remove_from_circle(&self, circle_id: String, node_hex: String) {
        let mut st = self.state.lock().unwrap();
        if let Some(c) = st.circles.iter_mut().find(|c| c.id == circle_id) {
            purge_member_from_circle(c, &node_hex);
        }
        drop(st);
        // Their events were just purged; if they're re-added, their re-sent history must be able
        // to land again rather than be skipped as already-seen.
        self.seen_envelopes.lock().unwrap().remove(&circle_id);
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
        hex(&self.state.lock().unwrap().me().node_id_bytes())
    }

    /// The OPAQUE storage-key prefix for `member_hex`'s blobs of `kind` ("mailbox"/"media"/"presign")
    /// in a circle (audit transport-F4). The platform storage layer uses this instead of the cleartext
    /// circle id, so a blind relay can't tell circles apart and a non-member — lacking the member's
    /// circle secret — can't name/list/fetch the blobs. Returns nil if I don't hold that member's
    /// circle secret yet (a peer's arrives in their key commit; mine is generated on demand).
    pub fn storage_prefix(&self, circle_id: String, member_hex: String, kind: String) -> Option<String> {
        let mut st = self.state.lock().unwrap();
        let me_hex = hex(&st.me().node_id_bytes());
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
        self.state.lock().unwrap().me().to_bytes()
    }

    pub fn verification_hex(&self) -> String {
        hex(&self.state.lock().unwrap().me().verification())
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
        let mut st = self.state.lock().unwrap();
        // D8: a SEEDLESS device holds no account key, so it cannot MINT a card. It serves the primary's
        // card (installed via `set_cached_profile` when it arrives over self-sync / full-state push), or
        // empty until then — never a fabricated/unsigned one.
        let Some(me) = st.me_secret.as_ref() else {
            return st.cached_profile.clone().unwrap_or_default();
        };
        // `sd` is the seed-drop capability version (S0) and `ml` the MLS/TreeKEM capability version
        // (M0), both carried INSIDE the account-signed payload so neither can be forged or stripped by
        // a relay. An older client ignores the unknown JSON keys (proven in the field by `sd` shipping
        // the same way), so both are strictly additive; a missing marker always means "legacy," never
        // "downgraded."
        let payload = serde_json::json!({ "n": name, "b": bio, "l": link, "a": avatar, "e": emoji, "sd": SEED_DROP_VERSION, "ml": MLS_VERSION, "cw": COMPACT_WIRE_VERSION }).to_string();
        // Domain-separate so a profile signature can never be confused with another signed object
        // (audit H3). The tag is part of the SIGNED bytes; the wire blob still carries only `payload`.
        let sig = me.sign(&profile_signing_bytes(payload.as_bytes()));
        let mut out = (sig.len() as u32).to_le_bytes().to_vec();
        out.extend_from_slice(&sig);
        out.extend_from_slice(payload.as_bytes());
        // Cache my own card too, so it rides `export_state` and a seedless sibling can adopt it verbatim.
        st.cached_profile = Some(out.clone());
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
        // Verify the domain-separated signature; fall back to the legacy untagged form so cards signed by
        // older builds still validate during rollout; and (seed-drop S1) accept a card signed by one of the
        // account's AUTHORIZED DEVICES, chaining through the verified roster — the receive-side verifier for
        // when a later release signs profiles under the device key. The device path is additive: it's only
        // reached after the account-key verifies fail, which for today's account-signed cards never matches.
        let ok = id.verify(&profile_signing_bytes(payload), sig).is_ok()
            || id.verify(payload, sig).is_ok()
            || profile_signed_by_authorized_device(&self.state.lock().unwrap(), &id, &profile_signing_bytes(payload), sig);
        if !ok {
            return None;
        }
        // The signature is good, so the markers inside are the account's own claim. Learning here —
        // rather than only in `profile_seed_drop_version` — is what makes the compact-wire gate
        // converge on iOS and Android, which call this entry point and not that one.
        learn_capabilities(&mut self.state.lock().unwrap(), id.node_id_bytes(), payload);
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

    /// The seed-drop capability version a contact advertises in their SIGNED profile (S0), or 0 if the
    /// profile is legacy / carries no marker / fails verification. A missing marker is 0 = "legacy," NEVER
    /// treated as a downgrade (absence is never information). On an affirmatively-verified marker (>= 1) we
    /// monotonically record the account as seed-drop-capable — real negotiation, learned never inferred.
    /// The MLS/TreeKEM `ml` marker (M0) riding the same signed payload is learned here too, under the
    /// same rules; it does not affect the returned `sd` version.
    pub fn profile_seed_drop_version(&self, bundle: Vec<u8>, blob: Vec<u8>) -> u32 {
        if blob.len() < 4 {
            return 0;
        }
        let sig_len = u32::from_le_bytes([blob[0], blob[1], blob[2], blob[3]]) as usize;
        if blob.len() < 4 + sig_len {
            return 0;
        }
        let sig = &blob[4..4 + sig_len];
        let payload = &blob[4 + sig_len..];
        let Ok(id) = HavenId::from_bytes(&bundle) else { return 0 };
        // The marker is only inside the domain-separated (tagged) payload; verify against the account key or
        // an authorized device. An unsigned / forged marker is ignored → 0.
        let signed = profile_signing_bytes(payload);
        if !(id.verify(&signed, sig).is_ok()
            || profile_signed_by_authorized_device(&self.state.lock().unwrap(), &id, &signed, sig))
        {
            return 0;
        }
        let card = serde_json::from_slice::<serde_json::Value>(payload).ok();
        // The `ml` (MLS/TreeKEM, M0) marker rides the same verified payload and is learned the same
        // way: monotonic insert on an affirmatively-verified marker only. Piggybacking on this call —
        // the one place incoming signed profiles are already consumed — means the capability picture
        // converges with zero new app wiring, while the return value (the `sd` version) is untouched
        // for every existing caller.
        let ml = card
            .as_ref()
            .and_then(|v| v.get("ml").and_then(|x| x.as_u64()))
            .unwrap_or(0) as u32;
        if ml >= 1 {
            self.state.lock().unwrap().mls_capable.insert(id.node_id_bytes());
        }
        // `cw` — can this account's client READ the compact envelope container? Learned the same
        // monotonic, affirmative-only way. Unlike `sd`/`ml` this one IS consumed in production: it
        // gates what we WRITE, so a missing marker must keep us on JSON.
        let cw = card
            .as_ref()
            .and_then(|v| v.get("cw").and_then(|x| x.as_u64()))
            .unwrap_or(0) as u32;
        if cw >= 1 {
            self.state.lock().unwrap().compact_wire_capable.insert(id.node_id_bytes());
        }
        let version = card
            .as_ref()
            .and_then(|v| v.get("sd").and_then(|x| x.as_u64()))
            .unwrap_or(0) as u32;
        if version >= 1 {
            self.state.lock().unwrap().seed_drop_capable.insert(id.node_id_bytes());
        }
        version
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
        // The removal tombstone is AUTHORITATIVE: an automatic path (a handshake in `handleHello`, a
        // self-synced roster) must NEVER resurrect a member the user removed — that's exactly why
        // removal "never stuck". Refuse to re-add a tombstoned member and leave the tombstone intact.
        // Only an EXPLICIT re-add (which calls `clear_circle_removal` first) lifts it. This makes
        // removal robust even if a client-side guard misses (hex case, an unsynced client tombstone).
        if circle.removed_members.iter().any(|m| m.node_id_bytes() == id.node_id_bytes()) {
            return Ok(node_hex);
        }
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
        // Authoritative tombstone (see add_contact_bundle): refuse to resurrect a removed member; only
        // an explicit `clear_circle_removal` lifts it. The tombstone is left intact here.
        if circle.removed_members.iter().any(|m| m.node_id_bytes() == bundle.node_id_bytes()) {
            return Ok(());
        }
        if !circle.members.iter().any(|m| m.node_id_bytes() == bundle.node_id_bytes()) {
            circle.members.push(bundle);
        }
        Ok(())
    }

    /// Lift a member's removal tombstone in a circle — the ENGINE side of an EXPLICIT re-add. The add
    /// paths (`add_contact_bundle` / `add_existing_to_circle`) now REFUSE to resurrect a tombstoned
    /// member, so a deliberate re-add must call this FIRST. Automatic paths (handshake, self-sync)
    /// never call it, so a removed member can only return by the user's explicit action — which is why
    /// removal now sticks across ticks. No-op if the circle or tombstone is absent.
    pub fn clear_circle_removal(&self, circle_id: String, node_hex: String) {
        let mut st = self.state.lock().unwrap();
        if let Some(c) = st.circles.iter_mut().find(|c| c.id == circle_id) {
            c.removed_members.retain(|m| hex(&m.node_id_bytes()) != node_hex);
        }
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

    /// Resolve an authenticated transport DEVICE id back to the ACCOUNT id that authorized it, using
    /// the signed device rosters we hold. Returns the account hex, or `None` if we don't (yet) know
    /// which account owns this device. A device id that IS an account id we know (a pre-multidevice
    /// peer) resolves to itself. Used as a defense-in-depth cross-check that a directly-delivered call
    /// frame's cryptographically-proven sender matches the transport it arrived on (audit R1 rec a).
    pub fn account_for_device(&self, device_hex: String) -> Option<String> {
        let dev = device_hex.to_lowercase();
        let st = self.state.lock().unwrap();
        for (id, cd) in st.device_lists.iter() {
            let acct = hex(id);
            if acct == dev {
                return Some(acct);
            }
            if cd.authorized_bundles().iter().any(|b| hex(&b.node_id_bytes()) == dev) {
                return Some(acct);
            }
        }
        None
    }

    /// Export every CONTACT device roster I currently hold, each as tagged wire + the contact's account
    /// hex. My OTHER devices fold these into self-sync so a freshly-linked device learns which device ids
    /// to dial/seal for each friend WITHOUT first having to reach that friend itself — the bootstrap gap
    /// that left a linked Mac dialing dead account ids and timing out. Excludes my own roster.
    pub fn export_contact_rosters(&self) -> Vec<ContactRosterWire> {
        let st = self.state.lock().unwrap();
        let my_id = st.me().node_id_bytes();
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
    /// The `haven/self/…` self-sync slots are served to the account's own fleet by any relay (incl. a
    /// headless one — the owner gate needs no circle membership, only the account's devroster), so this
    /// converges over any shared relay both devices can reach — no relay change required.
    /// Returns 0 or 1 entries (empty until this device has registered itself).
    pub fn export_own_roster(&self) -> Vec<ContactRosterWire> {
        let st = self.state.lock().unwrap();
        let my_id = st.me().node_id_bytes();
        // A3: a primary re-signs its roster fresh; a seedless device rebroadcasts the primary-signed wire
        // it holds VERBATIM (trailer intact). `own_roster_wire` picks the right one.
        match st.own_roster_wire() {
            Some(wire) => vec![ContactRosterWire { account_hex: hex(&my_id), wire }],
            None => Vec::new(),
        }
    }

    /// Ingest a contact's device roster from tagged wire (what `export_contact_rosters` produces). Same
    /// verification as `receive`'s TAG_DEVICE_ROSTER path, but account-level so no circle context is
    /// needed. Verified against the account bundle carried in the wire.
    ///
    /// Answers only "does the engine now know this roster?". Callers that need to know whether it
    /// CHANGED — to keep querying other relays for a newer copy, or to re-seal history under the new
    /// epoch — must use [`Self::ingest_roster_wire_status`].
    /// Has any circle's epoch ADVANCED since the last call? Consumes the flag.
    ///
    /// Clients poll this and, when true, re-seal their own history under the new epoch (the full
    /// `export_my_envelopes` bundle). Anyone who joined or advanced past the old epoch can then read
    /// what was sealed under it; without that they hold content they can never open, and it looks
    /// exactly like a delivery failure from both ends.
    ///
    /// This replaces triggering on a roster change, which was only a PROXY for the epoch moving. The
    /// proxy passed in isolation and then missed in a longer run — the epoch also advances on
    /// periodic rotation and on tree commits carrying no roster change, and each of those stranded a
    /// peer on 27 unopenable envelopes. Ask the real question instead of a correlated one.
    /// Forensic dump of the parked TREE buffer: tag, signer (when parseable), and byte size of each
    /// entry, per circle. Diagnostic-only; exists because a forked fleet's parked commits are the
    /// only artifact that says WHO authored the branch each side is rejecting.
    pub fn debug_pending_tree_json(&self) -> String {
        let st = self.state.lock().unwrap();
        let mut out = Vec::new();
        for c in st.circles.iter() {
            if c.pending_tree.is_empty() { continue; }
            let rows: Vec<String> = c.pending_tree.iter().map(|raw| {
                let tag = raw.first().copied().unwrap_or(0);
                // Both commit and welcome carry a signer hint early; fall back to a hex sniff of the
                // first 32 bytes after the tag.
                let hint = raw.get(1..33).map(hex).unwrap_or_default();
                format!("{{\"tag\":{},\"len\":{},\"head\":\"{}\"}}", tag, raw.len(), &hint[..hint.len().min(16)])
            }).collect();
            out.push(format!("{{\"id\":\"{}\",\"tree\":[{}]}}", c.id, rows.join(",")));
        }
        format!("[{}]", out.join(","))
    }

    /// Forensic: every stored tree commit per circle — epoch, committer, proposal kinds, parent
    /// known-ness — plus this device's applied tree epoch. The artifact that names WHO authored the
    /// branch each side of a fork is the chain itself; nothing else records it.
    pub fn debug_tree_chain_json(&self) -> String {
        let st = self.state.lock().unwrap();
        let mut out = Vec::new();
        for c in st.circles.iter() {
            let Some(shadow) = st.shadow_trees.get(&c.id) else { continue };
            let rows: Vec<String> = shadow.commits.values().map(|b| {
                match treekem::Commit::from_bytes(b) {
                    Ok(cm) => {
                        let kinds: Vec<&str> = cm.proposals.iter().map(|p| match p.body {
                            treekem::ProposalBody::Add { .. } => "add",
                            treekem::ProposalBody::Remove { .. } => "remove",
                            _ => "other",
                        }).collect();
                        let parent_known = shadow.commits.contains_key(&cm.parent_commit_hash);
                        format!("{{\"epoch\":{},\"sender_leaf\":{},\"props\":\"{}\",\"parent_known\":{}}}",
                                cm.epoch, cm.sender_leaf, kinds.join("+"), parent_known)
                    }
                    Err(_) => "{\"epoch\":0}".into(),
                }
            }).collect();
            out.push(format!("{{\"id\":\"{}\",\"commits\":[{}]}}", &c.id[..c.id.len().min(20)], rows.join(",")));
        }
        format!("[{}]", out.join(","))
    }

    /// The circle ids whose epoch ADVANCED since the last call — consuming, like the bool form.
    ///
    /// The bool form made every client re-seal EVERY circle on any advance; on the Android leg that
    /// measured 96s for an own-device echo, nearly all of it hybrid-PQ re-signing of circles whose
    /// epoch had not moved at all. Scoping the re-seal to the circles actually affected is the
    /// whole difference.
    pub fn take_epoch_moved_circles(&self) -> Vec<String> {
        let mut st = self.state.lock().unwrap();
        for i in 0..st.circles.len() {
            if !st.circles[i].pending_tree.is_empty() && st.circles[i].pending_tree_retries < 8 {
                st.circles[i].pending_tree_retries += 1;
                drain_pending_tree(&mut st, i);
            }
        }
        let mut moved = Vec::new();
        for c in st.circles.iter_mut() {
            if c.epoch_moved {
                c.epoch_moved = false;
                moved.push(c.id.clone());
            }
        }
        moved
    }

    pub fn take_epoch_moved(&self) -> bool {
        let mut st = self.state.lock().unwrap();
        // Piggyback ONE bounded tree-buffer replay attempt per poll — but only while the buffer is
        // plausibly convergeable. Gate 3 measured the ungated version: on a genuinely forked fleet
        // the buffer never empties, so every poll re-verified ~20 MLS envelopes UNDER THE ENGINE
        // LOCK — the desktop dump froze for 10+ minutes and every leg slowed. Retry a few times,
        // then leave the buffer for event-driven triggers (a new tree envelope, a roster store, an
        // import); a fork needs resolution, not a hot loop.
        for i in 0..st.circles.len() {
            if !st.circles[i].pending_tree.is_empty() && st.circles[i].pending_tree_retries < 8 {
                st.circles[i].pending_tree_retries += 1;
                drain_pending_tree(&mut st, i);
            }
        }
        let mut moved = false;
        for c in st.circles.iter_mut() {
            if c.epoch_moved {
                c.epoch_moved = false;
                moved = true;
            }
        }
        moved
    }

    pub fn ingest_roster_wire(&self, wire: Vec<u8>) -> bool {
        self.ingest_roster_wire_status(wire) >= 0
    }

    /// As [`Self::ingest_roster_wire`], but says WHAT happened: `-1` refused (forged, or an attempted
    /// rollback to an older version), `0` already current, `1` stored — the roster changed.
    ///
    /// The three cases drive different client behaviour, and collapsing them is how two separate bugs
    /// got in. `0` must not read as failure (that made a healthy device log "INGEST REJECTED" on every
    /// poll and skip its post-roster recovery), and `0` must not read as success-and-stop either (that
    /// left a device pinned to a stale roster because the first relay it asked happened to hold the
    /// same version, while its siblings had moved on). Only `1` means the circle's epoch moved.
    pub fn ingest_roster_wire_status(&self, wire: Vec<u8>) -> i8 {
        if wire.first() != Some(&TAG_DEVICE_ROSTER) {
            return RosterIngest::Refused.code();
        }
        let mut st = self.state.lock().unwrap();
        match decode_roster(&wire[1..]).and_then(|(acct, list, creds, trailer)| {
            HavenId::from_bytes(&acct).ok().map(|a| (a, list, creds, trailer))
        }) {
            Some((account, list, creds, trailer)) => {
                let outcome = verify_and_store_roster(&mut st, &account, &list, &creds);
                note_roster_capability(&mut st, &account, &trailer); // S0: learn capability, never infer absence
                note_seedless_own_roster_wire(&mut st, &account, &wire); // A3: keep MY primary-signed wire verbatim
                // PARITY with the mailbox arm (`receive` → TAG_DEVICE_ROSTER, which has always done
                // this): a roster — freshly stored OR already held — may make a parked "unknown
                // sender" envelope openable, so replay the durable buffer here too. Without it the
                // two ways of learning the same bytes had different consequences, and the PULL arm
                // is the only one a contact's roster ever takes on Android. Draining is idempotent
                // and cheap: still-locked events go straight back into the buffer.
                let drained = drain_all_pending(&mut st);
                if drained { RosterIngest::Stored.code() } else { outcome.code() }
            }
            None => RosterIngest::Refused.code(),
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

    /// The id of the event *I* authored in `circle_id` at `created_at` — how the author learns the
    /// engine-derived id of a post it just created (ids are content-addressed inside `Event::new`:
    /// BLAKE3(author ‖ created_at ‖ kind), so no caller can predict one). Exact because `author()`
    /// pushes the event into the circle's log before returning its envelope; `created_at` (pass the
    /// same timestamp you gave `post`) pins the lookup so an own-device event landing via sync in
    /// the same instant can't be mistaken for it. Newest match wins. `None` for an unknown circle
    /// or no match — callers treat this as best-effort (e.g. the sealed push banner's `p` deep-link
    /// tag simply stays absent, keeping the legacy circle route).
    pub fn last_authored_event_id(&self, circle_id: String, created_at: u64) -> Option<String> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me().node_id_bytes());
        st.circles
            .iter()
            .find(|c| c.id == circle_id)
            .and_then(|c| c.events.iter().rev().find(|e| e.author == me && e.created_at == created_at))
            .map(|e| e.id.clone())
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
        let me_pub = st.me().clone();
        verify_and_store_roster(&mut st, &me_pub, &list, &credentials).known()
    }

    /// Record a CONTACT's signed device roster (verified against their pinned account bundle) so I seal
    /// to their devices and honor revocations. False on a forged / stale (rolled-back) roster.
    pub fn ingest_device_roster(&self, account_bundle: Vec<u8>, list: Vec<u8>, credentials: Vec<Vec<u8>>) -> bool {
        let Ok(account) = HavenId::from_bytes(&account_bundle) else { return false };
        let mut st = self.state.lock().unwrap();
        verify_and_store_roster(&mut st, &account, &list, &credentials).known()
    }

    /// My own device roster, wire-encoded for sharing with contacts (rides the sync bundle so peers
    /// learn which of my devices to seal to). Empty if I haven't enrolled any devices yet.
    pub fn my_device_roster_wire(&self) -> Vec<u8> {
        // A3: primary re-signs; seedless rebroadcasts the granted wire verbatim (trailer intact).
        self.state.lock().unwrap().own_roster_wire().unwrap_or_default()
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
        // A1: only the primary (seed-holder) authors its own roster. A SEEDLESS device NEVER mints or
        // re-signs a DeviceList / DeviceCredential — the primary is the sole roster authority (the enroll
        // grant delivers its credential + verbatim roster instead). Clients call this unconditionally at
        // boot; the `Option` on `me_secret` turns a missed skip into an explicit early return, not a panic.
        if st.me_secret.is_none() {
            return vec![];
        }
        let me_pub = st.me().clone();
        let acct_id = me_pub.node_id_bytes();
        let dev_id = device.node_id_bytes();
        let base = st.device_lists.get(&acct_id).map(|cd| cd.list.clone());
        let updated = match &base {
            Some(b) => b.with_self_added(dev_id, st.me_secret.as_ref().unwrap(), created_at),
            None => Some(DeviceList::signed(st.me_secret.as_ref().unwrap(), 1, created_at, vec![dev_id], vec![])),
        };
        if let Some(new_list) = updated {
            let mut creds =
                st.device_lists.get(&acct_id).map(|cd| cd.credentials.clone()).unwrap_or_default();
            if !creds.iter().any(|c| c.device_id() == dev_id) {
                creds.push(DeviceCredential::issue(st.me_secret.as_ref().unwrap(), &device, &name, created_at));
            }
            st.device_lists.insert(acct_id, ContactDevices { list: new_list, credentials: creds });
            for c in st.circles.iter_mut() {
                c.rotate_epoch();
            }
            // M4 roster→Add automation: a newly-registered device of a member drives a chained
            // Add into the LIVE tree (gated inside on the keying committer — inert with the switch
            // OFF, so this is a no-op unless I am the elected creator of a keying-live circle).
            for i in 0..st.circles.len() {
                mls_sync_roster_to_tree(&mut st, i);
            }
        }
        st.own_roster_wire().unwrap_or_default()
    }

    /// **Migration: retire the bare account-id leaf** from my own signed roster (docs/SWITCH-FLIP-1.0.7.md
    /// §1). An account that registered a legacy `{account, device}` roster before 1.0.7 cannot otherwise
    /// shed its bare account leaf — the own-roster merge is grow-only union — so the all-joined gate never
    /// completes and the circle settles permanently at `shadow` (dual-stack, legacy-keyed). Calling this
    /// mints a HIGHER-VERSION, account-signed roster with the account-leaf-retired flag set: the account
    /// id STAYS in `devices` (grow-only device set untouched) but stops being authorized, so the roster
    /// settles at the DEVICE-ONLY shape live MLS keying + seed-drop retirement require. Rebroadcast the
    /// returned-wire (`my_device_roster_wire`) to contacts so they drop my account leaf from their sealing
    /// set + tree.
    ///
    /// GATED, mirroring `self_sync_key_should_rotate` / the retirement switch — returns `false` and
    /// changes NOTHING unless the retirement path is actually being enabled AND the account is fully
    /// device-capable:
    ///   * I hold the account seed (only the account key can re-sign a roster — a seedless device never
    ///     mints one; A1, same guard as `register_device`),
    ///   * I have adopted a device identity (`use_device_identity`) — a device key to key content to, so
    ///     retiring the account leaf never strands the account with zero authorized leaves,
    ///   * the retirement switch is ON (`set_seed_drop_retire(true)`), and
    ///   * my own account is affirmatively seed-drop-capable.
    /// Idempotent: a no-op (returns `false`) once already retired — the flag is monotone/sticky, so this
    /// never churns a needless version bump / epoch rotation. With the gate unmet it is byte-identical to
    /// today (the account leaf is never dropped by absence).
    pub fn retire_account_leaf(&self) -> bool {
        let mut st = self.state.lock().unwrap();
        // Gate — all four conditions, else inert (byte-identical to today).
        if st.me_secret.is_none() || st.device.is_none() || !st.retire_account_key {
            return false;
        }
        let acct_id = st.me().node_id_bytes();
        if !st.seed_drop_capable.contains(&acct_id) {
            return false; // my own account not yet marked capable — don't retire prematurely
        }
        let Some(cd) = st.device_lists.get(&acct_id) else {
            return false; // no roster registered yet — nothing to retire (call register_device first)
        };
        let me = st.me_secret.as_ref().unwrap();
        // POSITIVE, versioned, account-signed retirement. `None` ⇒ already retired ⇒ sticky no-op.
        let Some(new_list) = cd.list.with_account_leaf_retired(me, now_secs()) else {
            return false;
        };
        let creds = cd.credentials.clone();
        st.device_lists.insert(acct_id, ContactDevices { list: new_list, credentials: creds });
        // The authorized-leaf set shrank (account leaf dropped) — rotate every epoch so the change takes
        // effect at the next key commit, exactly like register_device / a revocation.
        for c in st.circles.iter_mut() {
            c.rotate_epoch();
        }
        // Roster→tree: the retired account leaf is now unauthorized, so `mls_sync_roster_to_tree` Removes
        // it from any LIVE tree (gated inside on the keying committer — inert on an OFF/shadow circle).
        for i in 0..st.circles.len() {
            mls_sync_roster_to_tree(&mut st, i);
        }
        true
    }

    /// Whether MY OWN signed roster has retired the bare account-id leaf (the migration flag above).
    /// `false` on every legacy / not-yet-migrated account (absence is never "retired").
    pub fn account_leaf_retired(&self) -> bool {
        let st = self.state.lock().unwrap();
        let acct_id = st.me().node_id_bytes();
        st.device_lists.get(&acct_id).map(|cd| cd.list.account_leaf_retired).unwrap_or(false)
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
        self.epoch_sync_bundle_inner(circle_id, mine_only, limit, false, 0)
    }

    /// `before_ms` pages BACKWARDS through history: only events strictly older than it are
    /// considered, and `limit` then keeps the newest of those. 0 means "from the top". Together they
    /// are a cursor — a receiver asks for the page older than the oldest post it holds, and keeps
    /// asking until a page comes back empty.
    fn epoch_sync_bundle_inner(
        &self, circle_id: &str, mine_only: bool, limit: u32, head_only: bool, before_ms: u64,
    ) -> Vec<Vec<u8>> {
        let mut st = self.state.lock().unwrap();
        let me_hex = hex(&st.me().node_id_bytes());
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return vec![] };
        // SENDER-expired content must never ride another bundle: a lapsed `retention_secs` is the
        // author's promise to the whole circle, so it purges here even if the app never calls
        // `purge_expired`. Viewer/circle retention is deliberately NOT applied — this path has no
        // viewer input, and a display preference must not destroy data it never promised to
        // delete. Wall clock is how `rotate_if_stale` keys its window too; the core has no
        // injected clock on this path.
        //
        // 48h RE-SEAL GRACE: the purge is evaluated against (now − 48h), NOT now. This path runs
        // on every epoch-head export — i.e. on the author's very next post and every launch — so
        // an exact-deadline purge deleted a 24h STORY from the author's engine the moment its
        // window lapsed, before the daily full-history backfill could ever re-deliver it to a
        // receiver that stalled (commit lag, offline). Display still hides expired content at the
        // exact deadline everywhere (`build_feed` is_expired + the app-driven purge_expired), so
        // the promise the viewer sees is unchanged — the grace only keeps the bytes exportable
        // long enough for late receivers to reconcile history.
        let grace_ms: u64 = 48 * 60 * 60 * 1000;
        purge_expired_from_circle(
            &mut st.circles[idx], None, None,
            now_secs().saturating_mul(1000).saturating_sub(grace_ms),
        );
        // TreeKEM tree wires (genesis commit + Welcomes for the creator; cached Remove commits) go on
        // the bundle regardless of the keying decision — a receiver needs them to build the tree AND
        // (M3) to derive the content epoch. Built BEFORE the flip decision so the tree exists when we
        // compute it. Plus my join ack (§7.2) and a re-broadcast of the verified admin grants (§4.3).
        // A FULL bundle (mine-only, unlimited, not head-only) is the one place a rotation is safe —
        // it re-seals my whole history under the new epoch in the same batch. Both the legacy
        // `rotate_if_stale` and the M5 PCS leaf-Update cadence gate on exactly this predicate.
        let full_bundle = !head_only && mine_only && limit == 0;
        let shadow_wires = shadow_emit_bundle(&mut st, idx, full_bundle);
        let join_wire = keying_emit_join(&mut st, idx);
        let admin_wires: Vec<Vec<u8>> =
            st.circles[idx].admin_grants.iter().map(|g| tagged(TAG_ADMIN_GRANT, g)).collect();
        // Upgrade offers ride the legacy circle's lane so its members see them. Only re-broadcast the
        // ones I authored: relaying someone else's would lend it my circulation, and an offer is a
        // claim to be judged, not a fact to spread.
        let my_acct = st.me().node_id_bytes();
        let upgrade_wires: Vec<Vec<u8>> = st.circles[idx]
            .upgrade_offers
            .iter()
            .filter(|w| CircleUpgrade::from_bytes(w).map(|u| u.creator == my_acct).unwrap_or(false))
            .map(|u| tagged(TAG_CIRCLE_UPGRADE, u))
            .collect();
        // THE KEYING FLIP / PARK DECISION (§4.5/§7.3), recomputed every bundle from verified state.
        // `Some(content_epoch)` ⇒ the circle is flipped: content seals under the tree-derived key and
        // the legacy KeyCommit STOPS. `None` ⇒ shadow or parked ⇒ legacy KeyCommit + sender-keys epoch.
        let mls_live = mls_refresh_keying(&mut st, idx);
        // PERIODIC forward-secrecy rotation (audit C2) — the trigger for `rotate_if_stale`. This is the
        // only safe place for it: a full bundle (`sync_envelopes` on the P2P path, `export_my_envelopes`
        // on the relay backfill) emits the new key commit AND re-seals my entire history under it in the
        // same batch, so no peer is ever left with an event whose key it can't obtain. Both are reached
        // by every client on a schedule, so no platform timer is needed and no client can forget to
        // rotate. head-only/limited bundles must NOT rotate — they'd publish an epoch without the
        // re-seal and strand relay-only readers until the next backfill. When the tree is LIVE, legacy
        // rotation is gated OFF (the tree drives the epoch); content keys come from `mls_live` instead.
        let (epoch, key) = match mls_live {
            Some(content_epoch) => {
                let key = st.circles[idx]
                    .my_epoch_keys
                    .get(&content_epoch)
                    .copied()
                    .expect("mls_refresh_keying populated my content key");
                (content_epoch, key)
            }
            None => {
                if full_bundle {
                    st.circles[idx].rotate_if_stale();
                } else {
                    st.circles[idx].ensure_epoch();
                }
                let e = st.circles[idx].my_epoch;
                let Some(k) = st.circles[idx].current_key() else { return vec![] };
                (e, k)
            }
        };
        let secret = st.circles[idx].my_circle_secret;
        let mut accounts = vec![st.me().clone()];
        accounts.extend(st.circles[idx].members.iter().cloned());
        // Expand each account member to its AUTHORIZED devices (mine + each contact's), so the circle's
        // key commit seals to every trusted device and NEVER a revoked one. Members whose device roster
        // we haven't learned fall back to their account key — pre-multidevice peers keep working.
        // Seed-drop S5 GATE: when retirement is ON *and* every member is affirmatively capable, the bare
        // per-member account key is dropped (seal to device bundles only), cutting off a revoked device
        // even from a seed-holding member. Default (retire=false) is byte-identical to the ungated call.
        let members = recipients_with_devices_gated(
            &accounts,
            &st.device_lists,
            &st.seed_drop_capable,
            st.retire_account_key,
        );
        // Seed-drop S3: author the commit + events under this DEVICE's key (`signer_of`) — BUT only once the
        // whole circle is affirmatively seed-drop-capable. This is the backwards-compat gate: a device-signed
        // envelope's sender is the device, which a pre-S1 peer can't chain to the account, so it would be
        // unreadable there (SEED-DROP-DESIGN §8/§4.2). Until every member advertises the S1 verifier (and we
        // hold their rosters), keep signing as the ACCOUNT — a fully-capable circle has no such peer. The S5
        // retirement gate above is a further, separately-flipped step on top of this. Seedless devices (no
        // account seed) can only reach this once their circle is capable, which is exactly the S4 precondition.
        let author_under_device = st.device.is_some()
            && circle_fully_seed_drop_capable(&accounts, &st.device_lists, &st.seed_drop_capable);
        let mut out: Vec<Vec<u8>> = Vec::new();
        // Share my OWN device roster so peers seal their content to all my devices (and never a revoked
        // one). Idempotent: a same-version roster is ignored on the receiver, so this can't rotation-storm.
        // A3: a primary re-signs its wire; a seedless device emits the primary-signed wire it holds VERBATIM
        // (trailer intact) — it cannot re-mint it.
        if let Some(wire) = st.own_roster_wire() {
            out.push(wire);
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
            // The signer is part of the context: adopting a device key changes who signs the commit, so a
            // cached account-signed commit must not be reused after `use_device_identity`.
            h.update(&signer_of(&st, author_under_device).public().node_id_bytes());
            let mut ids: Vec<[u8; 32]> = members.iter().map(|m| m.node_id_bytes()).collect();
            ids.sort_unstable();
            for id in &ids {
                h.update(id);
            }
            *h.finalize().as_bytes()
        };
        // §4.5: when the tree is LIVE the KeyCommit STOPS — the commit IS the key distribution, and
        // content keys come from the tree. When shadow/parked, emit the KeyCommit exactly as today.
        if mls_live.is_none() {
            match &st.circles[idx].cached_commit {
                Some((ctx, bytes)) if *ctx == commit_ctx => out.push(bytes.clone()),
                _ => {
                    if let Ok(commit) = seal_key_commit(signer_of(&st, author_under_device), &members, circle_id, epoch, &key, &secret) {
                        let bytes = tagged(TAG_KEY_COMMIT, &commit.to_bytes());
                        st.circles[idx].cached_commit = Some((commit_ctx, bytes.clone()));
                        out.push(bytes);
                    }
                }
            }
        }
        // The tree wires + join ack + admin grants ride EVERY bundle (incl. head-only) so relay-only
        // readers and late joiners converge on the tree and the §7.2 gate; strictly additive.
        let append_tree = |out: &mut Vec<Vec<u8>>| {
            for w in &shadow_wires {
                out.push(w.clone());
            }
            if let Some(j) = &join_wire {
                out.push(j.clone());
            }
            for w in &admin_wires {
                out.push(w.clone());
            }
            for w in &upgrade_wires {
                out.push(w.clone());
            }
        };
        if head_only {
            append_tree(&mut out);
            return out; // roster + current key commit (or the tree) — no event re-seals
        }
        let mut events: Vec<Event> = st.circles[idx]
            .events
            .iter()
            .filter(|e| !mine_only || e.author == me_hex)
            // The paging cursor. Strictly older, so a receiver can pass the created_at of the
            // oldest post it holds and never be handed that same post back forever.
            .filter(|e| before_ms == 0 || e.created_at < before_ms)
            .cloned()
            .collect();
        if limit > 0 {
            let n = limit as usize;
            if events.len() > n {
                events = events.split_off(events.len() - n); // keep the most recent N
            }
        }
        let compact = circle_is_compact_wire_capable(&st, idx);
        for e in &events {
            if let Ok(env) = seal_event_in_epoch(signer_of(&st, author_under_device), circle_id, epoch, &key, e) {
                out.push(tagged(TAG_EPOCH_EVENT, &env.to_bytes_gated(compact)));
            }
        }
        // Tree wires + join ack + admin grants (built up front). In M2/parked they ride ALONGSIDE the
        // KeyCommit (shadow); when LIVE they ARE the key distribution (§4.5). Additive either way.
        append_tree(&mut out);
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
        self.epoch_sync_bundle_inner(&circle_id, true, 0, true, 0)
    }

    /// TreeKEM M2 SHADOW telemetry (`docs/TREEKEM-DESIGN.md` §9 row M2). Resolves this device's
    /// known genesis commits for a circle with the §5.1 fork rule (`select_chain`), derives the
    /// winning epoch secret from the Welcome it holds, and reports `{epoch, tree_hash_hex,
    /// converged, fork_count}`. Read-only and inert: the derived secret is compared/logged, never
    /// consumed for content. This is the M2 soak signal — every device in a fully-capable circle
    /// should report `converged=true` with an equal `tree_hash_hex` once sync has quiesced.
    pub fn mls_shadow_status(&self, circle_id: String) -> MlsShadowStatusFfi {
        let st = self.state.lock().unwrap();
        let none = MlsShadowStatusFfi { epoch: 0, tree_hash_hex: String::new(), converged: false, fork_count: 0 };
        let Some(shadow) = st.shadow_trees.get(&circle_id) else { return none };
        if shadow.commits.is_empty() {
            return none;
        }
        let gid = shadow.group_id.clone();
        // Resolve the fork: every device sees the same candidate set at quiescence and picks the
        // same winner (largest tip hash), the §5.1 convergence property.
        let candidates: Vec<Vec<Vec<u8>>> = shadow.commits.values().map(|b| vec![b.clone()]).collect();
        let Some(win) = treekem::select_chain(&shadow_genesis_parent(&gid), 1, &gid, &candidates) else {
            return none;
        };
        let wbytes = &candidates[win][0];
        let Ok(wc) = treekem::Commit::from_bytes(wbytes) else { return none };
        let wh = treekem::commit_hash(wbytes);
        let cth = treekem::next_confirmed_transcript_hash(&shadow_genesis_cth(&gid), &wc);
        let fork_count = (shadow.commits.len() - 1) as u32;
        // Converged iff I hold the WINNER's Welcome and can derive its epoch secret. Deriving it
        // proves agreement on the whole schedule; the value is logged, not consumed.
        let converged = match shadow.my_welcomes.get(&wh) {
            Some(w) if w.epoch == wc.epoch => {
                let sched = treekem::welcome_epoch_schedule(&w.joiner_secret, &gid, wc.epoch, &wc.tree_hash, &cth);
                tracing::info!(
                    circle = %circle_id,
                    epoch = wc.epoch,
                    tree_hash = %hex(&wc.tree_hash),
                    epoch_secret = %hex(&sched.epoch_secret),
                    fork_count,
                    "mls shadow: converged on winning tree"
                );
                true
            }
            _ => {
                tracing::info!(
                    circle = %circle_id,
                    epoch = wc.epoch,
                    tree_hash = %hex(&wc.tree_hash),
                    fork_count,
                    "mls shadow: winning tree known but no matching welcome yet"
                );
                false
            }
        };
        MlsShadowStatusFfi { epoch: wc.epoch, tree_hash_hex: hex(&wc.tree_hash), converged, fork_count }
    }

    /// Ingest a sealed envelope received from the network. Routes by wire tag: a key commit (stores
    /// the circle epoch key, then unlocks any buffered events), an epoch-sealed event, or a legacy
    /// per-recipient envelope (read-path compatibility during migration). Returns true if it changed
    /// state (a new event, or a newly-learned epoch key).
    pub fn receive(&self, circle_id: String, envelope: Vec<u8>) -> Result<bool, HavenError> {
        if envelope.is_empty() {
            return Ok(false);
        }
        // Identical bytes can't change state (sealing is deterministic; the engine's own dedupe
        // returns false for them) — but proving that costs a full unseal under the engine lock,
        // and peers re-blast entire histories (key commit + epoch events) every few minutes.
        // Reject those re-deliveries by outer hash BEFORE the engine lock, so a history blast
        // costs N hash lookups, not N unseals. ONLY these two tags dedupe: an epoch event that
        // can't open yet parks in the DURABLE pending buffer (persisted; drains when its key
        // arrives) and a key commit re-applies as a convergent no-op — so skipping a re-delivery
        // loses nothing. Every other tag (MLS commit/welcome/join, rosters, legacy JSON) may
        // legitimately park with NO durable buffer and complete via re-delivery once its
        // prerequisites land — those keep paying the unseal, and they're rare control traffic.
        // An envelope for an UNKNOWN circle is never recorded, so the same bytes still apply
        // once the circle exists.
        let dedupe = matches!(envelope[0], TAG_KEY_COMMIT | TAG_EPOCH_EVENT);
        let outer = *blake3::hash(&envelope).as_bytes();
        if dedupe {
            let seen = self.seen_envelopes.lock().unwrap();
            if seen.get(&circle_id).is_some_and(|s| s.contains(&outer)) {
                return Ok(false);
            }
        }
        let Some(result) = self.receive_locked(&circle_id, &envelope) else { return Ok(false) };
        // Record ONLY outcomes that are durable. `result.is_ok()` was too broad: a KEY COMMIT
        // rejected at the sender-authorization gate (:3627 — we cannot yet name the committer,
        // because their roster or circle membership has not landed) returns Ok(false) WITHOUT
        // applying and WITHOUT parking anywhere. Caching that hash meant the peer's byte-identical
        // re-emit (`cached_commit`) short-circuited here forever, so the commit could never be
        // re-attempted once the missing prerequisite DID arrive — every later retry was free and
        // useless. Measured: 126 retries doing zero authorization work, and a mid-run membership
        // repair that could not take effect until the process was relaunched (seen_envelopes is
        // in-memory). That is what made this failure look permanent and un-selfhealing.
        //
        // An EPOCH EVENT answering Ok(false) is different: it parked in the DURABLE pending buffer
        // (or was a duplicate), so it genuinely never needs the bytes again.
        let durable = match (&result, envelope[0]) {
            (Ok(true), _) => true,                    // applied
            (Ok(false), TAG_EPOCH_EVENT) => true,     // parked durably / duplicate
            _ => false,                               // rejected commit — must stay re-processable
        };
        if dedupe && durable {
            let mut seen = self.seen_envelopes.lock().unwrap();
            let set = seen.entry(circle_id).or_default();
            // Growth guard only — clearing merely re-prices those envelopes at one unseal each.
            if set.len() >= 65_536 {
                set.clear();
            }
            set.insert(outer);
        }
        result
    }

    /// Re-seal everything **I** authored to a circle — to sync a peer that just
    /// connected. Only my own events (relaying others' would forge authorship).
    pub fn sync_envelopes(&self, circle_id: String) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle(&circle_id)
    }

    /// One PAGE of what I authored, for history that is fetched as it is looked at rather than
    /// blasted the moment someone is added.
    ///
    /// Adding a friend used to hand them everything: `sync_envelopes` re-seals my entire history —
    /// real cryptography per event — and sends the lot. For an account carrying an imported archive
    /// that is hundreds of envelopes on the sender, hundreds of unseals on the receiver, and the
    /// whole media backlog pulled behind it, all before the new member has looked at anything. The
    /// first screenful is what they actually need; the rest is a backlog they may never scroll to.
    ///
    /// So: `limit` newest events older than `before_ms` (0 = from the top). The receiver asks for
    /// the page older than the oldest post it holds and keeps asking as it scrolls back, exactly the
    /// way media is already fetched only when a tile appears. An empty page means it has reached the
    /// beginning.
    ///
    /// Every page still carries the roster, the key commit and the tree wires, so a page is
    /// self-sufficient: a receiver can open it without having seen any other page. `sync_envelopes`
    /// stays as it is, and stays the eventual-consistency backstop — nothing here can strand a peer,
    /// because the periodic full re-send still reconciles anything the paging missed.
    pub fn sync_envelopes_page(&self, circle_id: String, before_ms: u64, limit: u32) -> Vec<Vec<u8>> {
        self.epoch_sync_bundle_inner(&circle_id, true, limit, false, before_ms)
    }

    /// The oldest event I authored in a circle, in ms — 0 when I have authored none.
    ///
    /// A receiver cannot otherwise tell "you have reached the beginning of their history" from "the
    /// page was dropped", and would either stop early or ask forever. Cheap: one pass over the
    /// circle's events, no sealing.
    pub fn my_oldest_event_ms(&self, circle_id: String) -> u64 {
        let st = self.state.lock().unwrap();
        let me_hex = hex(&st.me().node_id_bytes());
        st.circles
            .iter()
            .find(|c| c.id == circle_id)
            .map(|c| {
                c.events
                    .iter()
                    .filter(|e| e.author == me_hex)
                    .map(|e| e.created_at)
                    .min()
                    .unwrap_or(0)
            })
            .unwrap_or(0)
    }

    pub fn feed(&self, circle_id: String, now_ms: u64, viewer_retention_secs: Option<u64>) -> Vec<FeedItemFfi> {
        let st = self.state.lock().unwrap();
        let me = hex(&st.me().node_id_bytes());
        let keep_own = st.keep_own_posts;
        let events = st
            .circles
            .iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.events.clone())
            .unwrap_or_default();
        map_feed(events, &me, now_ms, viewer_retention_secs, keep_own)
    }

    /// Activity rows across ALL circles, newest-first — who reacted to / commented on / voted on
    /// MY events, plus others' posts, stories and DMs (see `build_activity`). ONE pass under the
    /// state lock clones each circle's events out; the reduce runs with the lock released, so a
    /// large history can't stall every other caller (the mac beachball lesson).
    pub fn activity(&self, since_ms: u64, now_ms: u64) -> Vec<ActivityItemFfi> {
        let (me, circles) = {
            let st = self.state.lock().unwrap();
            let me = hex(&st.me().node_id_bytes());
            let circles: Vec<(String, Vec<Event>)> =
                st.circles.iter().map(|c| (c.id.clone(), c.events.clone())).collect();
            (me, circles)
        };
        let mut out: Vec<ActivityItemFfi> = Vec::new();
        for (circle_id, events) in circles {
            for it in build_activity(events, &me, &circle_id, since_ms, now_ms) {
                let actor_short = short(&it.actor_hex);
                out.push(ActivityItemFfi {
                    id: it.id,
                    kind: it.kind,
                    circle_id: circle_id.clone(),
                    actor_hex: it.actor_hex,
                    actor_short,
                    target_id: it.target_id,
                    snippet: it.snippet,
                    created_at: it.created_at,
                    emoji: it.emoji,
                });
            }
        }
        // Each per-circle reduce is newest-first; merge them into one global newest-first list.
        out.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(a.id.cmp(&b.id)));
        out
    }

    /// Really delete expired content from a circle's event log. `feed` only hides expired items —
    /// this drops them (plus their orphaned comments/reactions/votes…) so they stop riding
    /// sync/backfill bundles and shrink from the persisted store on the next `export_state`.
    /// `viewer_retention_secs` = this circle's configured auto-delete, the SAME value the app
    /// passes to `feed`; my own posts honor the keep-my-posts toggle exactly as the feed does,
    /// while sender-set expiries purge unconditionally. Call on feed refresh. Returns the purged
    /// events' media content-refs so the app can GC the blobs (blob deletion is the app's job).
    pub fn purge_expired(&self, circle_id: String, viewer_retention_secs: Option<u64>, now_ms: u64) -> Vec<String> {
        let mut st = self.state.lock().unwrap();
        let me = hex(&st.me().node_id_bytes());
        let keep_own = st.keep_own_posts;
        let Some(c) = st.circles.iter_mut().find(|c| c.id == circle_id) else { return vec![] };
        purge_expired_from_circle(c, viewer_retention_secs, if keep_own { Some(&me) } else { None }, now_ms)
    }

    /// Seal a media blob to one contact (hybrid KEM → AES-256-GCM). The recipient
    /// opens it with `open_media`. Layout: [32 eph_x_pub][u32 pq_len][pq_ct][ciphertext].
    pub fn seal_media(&self, recipient_node_hex: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let st = self.state.lock().unwrap();
        // OWN account is a valid recipient — own-device media sync (a linked Mac/phone) seals media to the
        // account so any of the user's own devices (sharing the seed) can open it. The member-list lookup
        // alone failed here, since you aren't a member of your own circle, which silently broke ALL
        // own-device media transfer (the seal threw → the chunk send loop bailed before broadcasting).
        let recipient: HavenId = if hex(&st.me().node_id_bytes()) == recipient_node_hex {
            st.me().clone()
        } else if let Some(m) = st
            .circles
            .iter()
            .flat_map(|c| c.members.iter())
            .find(|m| hex(&m.node_id_bytes()) == recipient_node_hex)
            .cloned()
        {
            m
        } else {
            // C7: media requests arrive from DEVICE transports, so the recipient hex may be a device id,
            // not an account id. Resolve it against the known verified device bundles (mine + contacts');
            // otherwise a seedless requester — whose only id IS a device id — could never open the chunks.
            st.device_lists
                .values()
                .flat_map(|cd| cd.authorized_bundles())
                .find(|b| hex(&b.node_id_bytes()) == recipient_node_hex)
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
    /// per-chunk signature). Layout: `[NOTIF_V2][sender node id (32)][ed25519 sig (64)][seal_media]`.
    ///
    /// **Why this one route is Ed25519-only.** v1 carried the sender's full hybrid bundle (3,200 B)
    /// and a hybrid signature (3,373 B). Base64'd into an APNs payload that is ~10 KiB against a
    /// 4 KiB ceiling (5 KiB for VoIP), so Apple 413'd EVERY push: no DMs, no posts, and no call
    /// doorbell — which is also why calls never rang and no fallback banner appeared. The bundle
    /// alone exceeded the entire budget, so this could not be trimmed, only restructured.
    ///
    /// A node id already IS an Ed25519 public key, so the sender needs no bundle: 32 bytes both
    /// identify and verify. Authentication against forgery by a classical attacker is unchanged.
    /// What is given up is post-quantum authentication OF THE DOORBELL only — a future quantum
    /// adversary could ring a phone or fake a preview, but cannot read or forge content, which
    /// stays hybrid-sealed by `seal_media` and is re-verified through the normal path on open.
    /// Do not reuse this construction anywhere the payload is not APNs-capped: call SIGNALING
    /// (`seal_call_frame`) travels over iroh with no such limit and keeps the hybrid signature.
    pub fn seal_signed_notification(&self, recipient_node_hex: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let sealed = self.seal_media(recipient_node_hex.clone(), data.clone())?;
        let st = self.state.lock().unwrap();
        // D9: sign as the ACCOUNT when we hold the account key; a SEEDLESS device signs as itself.
        // The recipient resolves either from the 32-byte id it carries, exactly as before.
        let signer = st.account_or_device_signer();
        let node_id = signer.public().node_id_bytes();
        let sig = signer.sign_ed25519_only(&notif_signing_bytes(&recipient_node_hex, &data));
        let mut out = Vec::with_capacity(NOTIF_V2_PREFIX_LEN + sealed.len());
        out.push(NOTIF_V2);
        out.extend_from_slice(&node_id);
        out.extend_from_slice(&sig);
        out.extend_from_slice(&sealed);
        Ok(out)
    }

    /// Seal + sign a WebRTC call-signaling frame to ONE recipient (their account node hex). This is
    /// the ONLY call-signaling send path (audit R1): the SDP / ICE / control body is encrypted to the
    /// recipient — so a relay on the frame-9 forward path can neither read candidate IP addresses nor
    /// rewrite the DTLS-SRTP fingerprint inside an offer — AND signed by us, so the recipient
    /// cryptographically verifies who sent it instead of trusting a self-declared 64-hex prefix a
    /// relay could forge. Same construction as [`Self::seal_signed_notification`]; the signature is
    /// purpose-specific + domain-separated + binds the recipient and the wire frame type (NOT a raw
    /// signing oracle, audit H3). Recipient-per-frame, so a group call (one sealed frame per pairwise
    /// peer) is covered exactly like a 1:1. Layout:
    /// `[u32 bundle_len][sender bundle][u32 sig_len][sig][seal_media output]`.
    pub fn seal_call_frame(&self, recipient_node_hex: String, frame_type: u8, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let sealed = self.seal_media(recipient_node_hex.clone(), data.clone())?;
        let st = self.state.lock().unwrap();
        // D9: account key when held (byte-identical, pre-S4-openable); a seedless device signs + carries its
        // DEVICE bundle (openable once the S4.4/S4.5 receive-side device→account acceptance lands).
        let signer = st.account_or_device_signer();
        let bundle = signer.public().to_bytes();
        let sig = signer.sign(&call_signing_bytes(&recipient_node_hex, frame_type, &data));
        let mut out = Vec::with_capacity(8 + bundle.len() + sig.len() + sealed.len());
        out.extend_from_slice(&(bundle.len() as u32).to_le_bytes());
        out.extend_from_slice(&bundle);
        out.extend_from_slice(&(sig.len() as u32).to_le_bytes());
        out.extend_from_slice(&sig);
        out.extend_from_slice(&sealed);
        Ok(out)
    }

    /// Open + verify a call frame sealed to us with [`Self::seal_call_frame`]. Returns the PROVEN
    /// sender account hex + plaintext, or `None` if the blob can't be decrypted, or the carried
    /// signature doesn't verify against the carried sender bundle for THIS recipient + frame type.
    /// A malicious relay that (a) forged the sender, (b) rewrote the sealed body (e.g. swapped the
    /// DTLS-SRTP fingerprint), or (c) replayed a captured offer under a different frame type all fail
    /// here — the frame is dropped before any signaling logic sees it. Works identically on the direct
    /// iroh path and the frame-9 relay-forward path, because authentication rests on the signature,
    /// not on a transport-verified sender the relay path lacks.
    pub fn open_call_frame(&self, frame_type: u8, blob: Vec<u8>) -> Option<SignedCallFrame> {
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
        let plaintext = self.open_media(sealed)?;
        // The sender signs over the hex it ADDRESSED. Under device-id transport that may be one of
        // our DEVICE ids rather than our account id — a linked device dials and is dialed as itself.
        // Verifying only against the account id therefore rejected genuine frames as forgeries, which
        // is why a call could ring, be answered, and never connect: every invite (21) and hangup (12)
        // was discarded at this line.
        //
        // Accepting either identity does NOT weaken the recipient binding. Its purpose is to stop a
        // frame captured for one USER being replayed at another; both hexes here are OURS, so a frame
        // addressed to either is addressed to us. A frame addressed to anyone else still fails both.
        let (me_hex, my_device_hex) = {
            let st = self.state.lock().unwrap();
            (
                hex(&st.me().node_id_bytes()),
                st.device.as_ref().map(|d| hex(&d.public().node_id_bytes())),
            )
        };
        let sender = HavenId::from_bytes(bundle).ok()?;
        let addressed_to_us = sender
            .verify(&call_signing_bytes(&me_hex, frame_type, &plaintext), sig)
            .is_ok()
            || my_device_hex.as_deref().is_some_and(|dev| {
                sender.verify(&call_signing_bytes(dev, frame_type, &plaintext), sig).is_ok()
            });
        if !addressed_to_us {
            return None;
        }
        Some(SignedCallFrame { sender_hex: hex(&sender.node_id_bytes()), data: plaintext })
    }

    /// Why [`Self::open_call_frame`] refused a frame. Diagnostics only — it changes nothing and
    /// decides nothing; the caller logs the string when the real open returns None.
    ///
    /// The two failures mean OPPOSITE things and were previously indistinguishable, which is how
    /// "call frame DROPPED — seal/signature did not verify" could be either a fatal bug or entirely
    /// expected traffic:
    ///   * `decrypt-failed` — the blob was not sealed to a key we hold. Either the frame is simply
    ///     not for this device (a sibling device's copy), or the sender sealed to an identity we
    ///     can't open under (the account-leaf / seedless-device case).
    ///   * `sig-failed` — we DECRYPTED it, so it was addressed to us, but the signature doesn't
    ///     verify for `(me, frame_type, plaintext)`. The sender signs over the hex it ADDRESSED,
    ///     while we verify over our ACCOUNT hex — so a frame addressed to one of our DEVICE ids can
    ///     never verify here no matter how genuine it is. That asymmetry is a real bug, and this is
    ///     the string that proves it rather than inferring it.
    /// Diagnostic: why a circle's feed is emptier than its traffic, as JSON.
    ///
    /// `pending_epoch` is a DURABLE buffer. An envelope that arrives before the key that opens it —
    /// or before the roster that resolves its sender — parks there and waits to be replayed. The
    /// mailbox drain deliberately marks such a key SEEN (the bytes are already held; re-fetching
    /// identical bytes forever is the re-ingest storm this codebase has fought before), so from the
    /// outside a PARKED envelope and one that NEVER ARRIVED look exactly alike: the feed is short
    /// and nothing is logged. The two have opposite fixes — parked means "deliver the key/roster",
    /// absent means "fix the transport" — and nothing exposed which one was happening.
    ///
    /// That gap is what made a QA leg sit on a full buffer while reading as a delivery failure: the
    /// engine held 87 envelopes it could not open and reported a one-item feed, identically to a
    /// device whose relay was simply dead.
    ///
    /// Purely observational — it takes the lock, reads counters, and decides nothing.
    pub fn diag_delivery_json(&self) -> String {
        let st = self.state.lock().unwrap();
        let st_me_id = st.me().node_id_bytes();
        let mut circles = Vec::with_capacity(st.circles.len());
        for c in st.circles.iter() {
            let peers: std::collections::BTreeSet<&String> =
                c.peer_epoch_keys.keys().map(|(acct, _)| acct).collect();
            // WHICH key is missing, not merely how many are parked. A parked envelope names the
            // (author, epoch) slot that would open it; the held slots say whether we have it. Any
            // parked slot absent from the held set is the exact key that never converged — the
            // question every parked-buffer investigation actually needs answered.
            // Decode a BOUNDED prefix of the buffer. `parked` above is the exact count (a len());
            // this only names the distinct slots, and the caps below print 12 of them. The buffer
            // holds up to 512 envelopes and this runs on every QA dump, so decoding all of them
            // under the state lock would make the dump itself the slow thing being measured.
            const SLOTS_SCANNED: usize = 64;
            let mut want: std::collections::BTreeSet<String> = Default::default();
            for raw in c.pending_epoch.iter().take(SLOTS_SCANNED) {
                if let Ok(env) = EpochEnvelope::from_bytes(raw) {
                    let a = env.sender_hex();
                    want.insert(format!("{}@{}", &a[..a.len().min(8)], env.epoch));
                }
            }
            let mut held: std::collections::BTreeSet<String> = Default::default();
            for (acct, ep) in c.peer_epoch_keys.keys() {
                held.insert(format!("{}@{}", &acct[..acct.len().min(8)], ep));
            }
            let me_short = hex(&st_me_id);
            for ep in c.my_epoch_keys.keys() {
                held.insert(format!("{}@{}", &me_short[..me_short.len().min(8)], ep));
            }
            let missing: Vec<&String> = want.difference(&held).collect();
            let q = |v: &std::collections::BTreeSet<String>| -> String {
                v.iter().take(12).map(|x| format!("\"{x}\"")).collect::<Vec<_>>().join(",")
            };
            circles.push(format!(
                "{{\"parked_slots\":[{}],\"held_slots\":[{}],\"missing_keys\":[{}],\"id\":\"{}\",\"events\":{},\"parked\":{},\"parked_tree\":{},\"my_epoch\":{},\"my_epoch_keys\":{},\"peer_epoch_keys\":{},\"peers_keyed\":{},\"members\":{}}}",
                q(&want),
                q(&held),
                missing.iter().take(12).map(|x| format!("\"{x}\"")).collect::<Vec<_>>().join(","),
                c.id.replace('"', ""),
                c.events.len(),
                c.pending_epoch.len(),
                c.pending_tree.len(),
                c.my_epoch,
                c.my_epoch_keys.len(),
                c.peer_epoch_keys.len(),
                peers.len(),
                c.members.len(),
            ));
        }
        // Known device rosters, by account — an unresolvable sender is the OTHER reason an
        // envelope parks, and it is invisible from the feed alone.
        let mut rosters = Vec::with_capacity(st.device_lists.len());
        for (acct, cd) in st.device_lists.iter() {
            rosters.push(format!(
                "{{\"account\":\"{}\",\"version\":{},\"devices\":{},\"credentials\":{}}}",
                hex(acct),
                cd.list.version,
                cd.list.devices.len(),
                cd.credentials.len(),
            ));
        }
        format!("{{\"circles\":[{}],\"rosters\":[{}]}}", circles.join(","), rosters.join(","))
    }

    pub fn diagnose_call_frame(&self, frame_type: u8, blob: Vec<u8>) -> String {
        if blob.len() < 4 {
            return "malformed:short".into();
        }
        let Some(blen) = blob[0..4].try_into().ok().map(u32::from_le_bytes).map(|v| v as usize) else {
            return "malformed:len".into();
        };
        if blob.len() < 8 + blen {
            return "malformed:bundle".into();
        }
        let bundle = &blob[4..4 + blen];
        let Some(slen) = blob[4 + blen..8 + blen].try_into().ok().map(u32::from_le_bytes).map(|v| v as usize) else {
            return "malformed:siglen".into();
        };
        if blob.len() < 8 + blen + slen {
            return "malformed:sig".into();
        }
        let sig = &blob[8 + blen..8 + blen + slen];
        let sealed = blob[8 + blen + slen..].to_vec();
        let Some(plaintext) = self.open_media(sealed) else {
            return "decrypt-failed (not sealed to a key this device holds)".into();
        };
        let (me_hex, my_device) = {
            let st = self.state.lock().unwrap();
            (hex(&st.me().node_id_bytes()), st.device.as_ref().map(|d| hex(&d.public().node_id_bytes())))
        };
        let Some(sender) = HavenId::from_bytes(bundle).ok() else {
            return "bad-sender-bundle".into();
        };
        if sender.verify(&call_signing_bytes(&me_hex, frame_type, &plaintext), sig).is_ok() {
            return "ok".into();
        }
        // Decrypted fine but won't verify as addressed-to-our-account. If it verifies against our
        // DEVICE hex, the sender addressed the device and the receive side is checking the wrong id.
        if let Some(dev) = &my_device {
            if sender.verify(&call_signing_bytes(dev, frame_type, &plaintext), sig).is_ok() {
                return format!(
                    "sig-failed AS ACCOUNT but VERIFIES AS DEVICE {} — frame was addressed to our device id, receive side checks the account id",
                    &dev[..8.min(dev.len())]
                );
            }
        }
        format!("sig-failed for account {} (and device {:?}) — sender {}",
            &me_hex[..8.min(me_hex.len())],
            my_device.as_ref().map(|d| d[..8.min(d.len())].to_string()),
            &hex(&sender.node_id_bytes())[..8])
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
        // Dual-open: device key (Option 1), then account key (legacy account-sealed media). Seedless: the
        // account arm is absent, and media addressed to a seedless device is sealed to its device bundle (C7).
        //
        // Branch on the AEAD open, NOT on `decapsulate(..).ok()`. ML-KEM decapsulation applies implicit
        // rejection: given a ciphertext it cannot decapsulate, it returns a PSEUDORANDOM shared secret
        // rather than an error (FIPS-203). So the device arm always returned `Some(garbage_key)`, the
        // `or_else` account arm was unreachable dead code, and `open` then failed — meaning a device
        // that had adopted a device identity could no longer open ANYTHING sealed to its account.
        // For calls that is every invite (21) and hangup (12): the phone rings, the callee answers,
        // and the call never connects. Only a successful AEAD open proves we used the right key.
        let try_open = |id: &Identity| decapsulate(id, &enc).ok().and_then(|k| open(&k, ct).ok());
        st.device
            .as_ref()
            .and_then(|d| try_open(d))
            .or_else(|| st.me_secret.as_ref().and_then(|m| try_open(m)))
    }

    /// Seal a media blob to the WHOLE circle (any member can open it). The shared
    /// store host stores the result opaquely — it can't read it. Returns the sealed
    /// envelope bytes to upload.
    pub fn seal_circle_media(&self, circle_id: String, data: Vec<u8>) -> Result<Vec<u8>, HavenError> {
        let st = self.state.lock().unwrap();
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else {
            return Err(HavenError::Invalid { msg: "unknown circle".into() });
        };
        // Media is ALWAYS dual-sealed (account bundles + authorized devices) and, when a seed is held,
        // account-SIGNED — never device-only. The media ref lives inside the post event, which is itself
        // epoch/tree-keyed and retirement-gated, so anyone who can't open the post never learns the ref
        // to fetch the media: device-only-sealing the blob adds no confidentiality over the post's own
        // gating, while it introduced a fragile per-blob dependency on holding the author's current
        // device roster — and since a sealed blob is cached once and never re-sealed, any roster skew
        // froze a friend's media as permanently unopenable. Account-signing keeps it openable by any
        // authorized reader (the 1.0.6 robustness). Only a SEEDLESS device (no account key) signs under
        // its device, as it must — its media still needs peers to hold its roster, which is inherent.
        let under_device = st.me_secret.is_none();
        let mut accounts = vec![st.me().clone()];
        accounts.extend(st.circles[idx].members.iter().cloned());
        let recipients = recipients_with_devices(&accounts, &st.device_lists);
        let group = Group::new(circle_id, recipients);
        // Wrap the content key to the recipient list AND to the circle EPOCH. The list keeps a
        // friend whose epoch keys have not converged working exactly as before; the epoch entry is
        // what finally lets a member who joined AFTER this blob was sealed open it, which the list
        // alone can never do because content-addressed media is never re-sealed.
        let sealed = match st.circles[idx].current_key() {
            Some(key) => seal_bytes_with_epoch(signer_of(&st, under_device), &group, &key, &data),
            None => seal_bytes(signer_of(&st, under_device), &group, &data),
        };
        sealed
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
            let idx = st.circles.iter().position(|c| c.id == circle_id)?;
            // Account-signed + dual-sealed, mirroring `seal_circle_media` (see the rationale there):
            // media must stay openable by any authorized reader, not gated on holding a device roster.
            let under_device = st.me_secret.is_none();
            let mut accounts = vec![st.me().clone()];
            accounts.extend(st.circles[idx].members.iter().cloned());
            let recipients = recipients_with_devices(&accounts, &st.device_lists);
            let group = Group::new(circle_id.clone(), recipients);
            // Dual-wrapped, as in `seal_circle_media` — this is the variant used for large media and
            // for every repair re-seal.
            match st.circles[idx].current_key() {
                Some(key) => seal_bytes_with_epoch(signer_of(&st, under_device), &group, &key, &data),
                None => seal_bytes(signer_of(&st, under_device), &group, &data),
            }
            .ok()
            .map(|env| env.to_bytes())
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
    /// Why did [`Self::open_circle_media`] refuse this blob? It returns a bare `None` for three very
    /// different failures — unknown circle, unresolvable sealer, or no key that opens it — and that
    /// single answer sent a whole debugging session chasing corrupt bytes, missing epoch keys and
    /// roster skew in turn. Report the stage, and whether we are even in the recipient list.
    pub fn media_open_diagnosis(&self, circle_id: String, sealed: Vec<u8>) -> String {
        let st = self.state.lock().unwrap();
        let Ok(env) = SealedEnvelope::from_bytes(&sealed) else {
            return format!("PARSE-FAIL bytes={} head={:?}", sealed.len(),
                           String::from_utf8_lossy(&sealed[..sealed.len().min(8)]));
        };
        let sender_hex = env.sender_hex();
        let me_hex = hex(&st.me().node_id_bytes());
        let dev_hex = st.device.as_ref().map(|d| hex(&d.public().node_id_bytes()));
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else {
            return format!("NO-SUCH-CIRCLE circle={circle_id} sender={}", &sender_hex[..16]);
        };
        let recips = env.recipient_ids_hex();
        let me_listed = recips.iter().any(|r| *r == me_hex);
        let dev_listed = dev_hex.as_ref().map_or(false, |d| recips.iter().any(|r| r == d));
        let sender_kind = if sender_hex == me_hex {
            "self"
        } else if st.circles[idx].members.iter().any(|m| hex(&m.node_id_bytes()) == sender_hex) {
            "member"
        } else if authorized_device_and_account(&st, idx, &sender_hex).is_some() {
            "authorized-device"
        } else {
            "UNRESOLVABLE"
        };
        format!(
            "sender={} kind={sender_kind} recipients={} me_listed={me_listed} dev_listed={dev_listed} \
have_seed={} have_device={} members={}",
            &sender_hex[..16], recips.len(), st.me_secret.is_some(), st.device.is_some(),
            st.circles[idx].members.len())
    }

    pub fn open_circle_media(&self, circle_id: String, sealed: Vec<u8>) -> Option<Vec<u8>> {
        let st = self.state.lock().unwrap();
        let env = SealedEnvelope::from_bytes(&sealed).ok()?;
        let sender_hex = env.sender_hex();
        let me_hex = hex(&st.me().node_id_bytes());
        let idx = st.circles.iter().position(|c| c.id == circle_id)?;
        // EPOCH entry first. It needs no sender resolution and no place on the recipient list, so it
        // is the path that works for a member who joined after this blob was sealed — and for one
        // whose device roster cannot resolve the sealer, which otherwise fails below at the `?`.
        let mut epoch_keys: Vec<[u8; 32]> = Vec::new();
        if let Some(k) = st.circles[idx].current_key() { epoch_keys.push(k); }
        epoch_keys.extend(st.circles[idx].my_epoch_keys.values().copied());
        for k in &epoch_keys {
            if let Some(p) = open_bytes_with_epoch(k, &env) { return Some(p); }
        }
        // C6: the sender may be a member's ACCOUNT, mine, or an authorized DEVICE (seed-drop signs media
        // under the device in a fully-capable circle). Resolve a device sender via the verified roster.
        let sender_pub = if sender_hex == me_hex {
            st.me().clone()
        } else if let Some(m) =
            st.circles[idx].members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex)
        {
            m.clone()
        } else {
            authorized_device_and_account(&st, idx, &sender_hex).map(|(bundle, _)| bundle)?
        };
        // Dual-open: device key (Option 1), then account key (legacy). Seedless: account arm absent.
        st.device.as_ref().and_then(|d| open_bytes(d, &sender_pub, &env).ok())
            .or_else(|| st.me_secret.as_ref().and_then(|m| open_bytes(m, &sender_pub, &env).ok()))
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
            // EPOCH entry first, across every circle's keys — see `open_circle_media`.
            for c in st.circles.iter() {
                let mut ks: Vec<[u8; 32]> = Vec::new();
                if let Some(k) = c.current_key() { ks.push(k); }
                ks.extend(c.my_epoch_keys.values().copied());
                for k in &ks {
                    if let Some(p) = open_bytes_with_epoch(k, &env) { return Some(p); }
                }
            }
            let sender_hex = env.sender_hex();
            let me_hex = hex(&st.me().node_id_bytes());
            // The circle the media is tagged to (passed) first, then any other circle we're in.
            let ordered = std::iter::once(circle_id.as_str())
                .chain(st.circles.iter().map(|c| c.id.as_str()).filter(|id| *id != circle_id));
            for cid in ordered {
                let Some(cidx) = st.circles.iter().position(|c| c.id == cid) else { continue };
                // C6: account sender (member/me) or an authorized DEVICE sender (fully-capable circle).
                let sender_pub = if sender_hex == me_hex {
                    st.me().clone()
                } else if let Some(m) =
                    st.circles[cidx].members.iter().find(|m| hex(&m.node_id_bytes()) == sender_hex)
                {
                    m.clone()
                } else {
                    match authorized_device_and_account(&st, cidx, &sender_hex) {
                        Some((bundle, _)) => bundle,
                        None => continue,
                    }
                };
                // Dual-open device then account (seedless: account arm absent).
                if let Some(p) = st.device.as_ref().and_then(|d| open_bytes(d, &sender_pub, &env).ok())
                    .or_else(|| st.me_secret.as_ref().and_then(|m| open_bytes(m, &sender_pub, &env).ok()))
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
                removed_members: c.removed_members.iter().map(|m| m.to_bytes()).collect(),
                events: c.events.clone(),
                my_epoch: c.my_epoch,
                my_epoch_keys: c.my_epoch_keys.iter().map(|(e, k)| (*e, *k)).collect(),
                peer_epoch_keys: c.peer_epoch_keys.iter().map(|((a, e), k)| (a.clone(), *e, *k)).collect(),
                my_epoch_keys_alt: c
                    .my_epoch_keys_alt
                    .iter()
                    .flat_map(|(e, ks)| ks.iter().map(move |k| (*e, *k)))
                    .collect(),
                peer_epoch_keys_alt: c
                    .peer_epoch_keys_alt
                    .iter()
                    .flat_map(|((a, e), ks)| ks.iter().map(move |k| (a.clone(), *e, *k)))
                    .collect(),
                my_circle_secret: c.my_circle_secret,
                peer_circle_secrets: c.peer_circle_secrets.iter().map(|(a, s)| (a.clone(), *s)).collect(),
                rotated_at: c.rotated_at,
                cached_commit: c.cached_commit.clone(),
                pending_epoch: c.pending_epoch.clone(),
                pending_tree: c.pending_tree.clone(),
                creator: c.creator,
                creator_pinned: c.creator_pinned,
                admin_grants: c.admin_grants.clone(),
            }).collect(),
            seedless_roster_wire: st.seedless_roster_wire.clone(),
            cached_profile: st.cached_profile.clone(),
            device_rosters: {
                let me_id = st.me().node_id_bytes();
                let me_bundle = st.me().to_bytes();
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
            // A3/D8: restore the seedless verbatim roster wire + cached profile card (additive — never
            // clobber one we already hold this session with a `None` from an older-format state file).
            if let Some(wire) = ps.seedless_roster_wire {
                st.seedless_roster_wire = Some(wire);
            }
            if let Some(card) = ps.cached_profile {
                st.cached_profile = Some(card);
            }
            // A restored buffer may already be openable with the keys/rosters we just loaded.
            drain_all_pending(&mut st);
        } else if let Ok(old) = serde_json::from_slice::<LegacyPersistState>(&data) {
            Self::merge_circle(&mut st, PersistCircle {
                id: DEFAULT_CIRCLE.to_string(),
                name: "My Circle".to_string(),
                members: old.contacts,
                removed_members: vec![],
                events: old.events,
                my_epoch: 0,
                my_epoch_keys: vec![],
                peer_epoch_keys: vec![],
                my_epoch_keys_alt: vec![],
                peer_epoch_keys_alt: vec![],
                my_circle_secret: [0u8; 32],
                peer_circle_secrets: vec![],
                rotated_at: 0,
                cached_commit: None,
                pending_epoch: vec![],
                pending_tree: vec![],
                creator: None,
                creator_pinned: false,
                admin_grants: vec![],
            });
        }
    }
}

impl HavenSocial {
    /// The ACCOUNT signing secret, for the in-process uses that must assert the account key itself.
    /// Today that is exactly one caller: signing the public device-discovery record, which is
    /// published under the account id because the account id is the only thing a contact holds.
    ///
    /// NOT exported — the seed must never cross the FFI boundary a second time. `None` on a seedless
    /// device (seed-drop S4), which therefore cannot publish; the primary publishes for the account.
    pub(crate) fn account_secret_bytes(&self) -> Option<[u8; 32]> {
        let st = self.state.lock().unwrap();
        st.me_secret.as_ref().map(|id| id.node_secret_bytes())
    }

    /// MY dialable device ids for the public discovery record — this device first (it is the one
    /// definitely running), then the rest of my authorized roster. Excludes the account id: an
    /// account key is an identity, never a transport address, so publishing it as a dial target
    /// would only buy contacts a connect timeout.
    pub(crate) fn discovery_device_ids(&self) -> Vec<String> {
        let acct = self.my_node_hex().to_lowercase();
        let mut out = vec![self.my_device_node_hex()];
        for d in self.device_node_ids_for(acct.clone()) {
            let l = d.to_lowercase();
            if l != acct && !out.iter().any(|o| o.to_lowercase() == l) {
                out.push(d);
            }
        }
        out
    }

    /// The dispatch half of `receive`, under the engine lock. `None` means the circle doesn't
    /// exist (yet) — the caller must NOT record the envelope as seen in that case.
    fn receive_locked(&self, circle_id: &str, envelope: &[u8]) -> Option<Result<bool, HavenError>> {
        let mut st = self.state.lock().unwrap();
        let idx = st.circles.iter().position(|c| c.id == circle_id)?;
        Some(match envelope[0] {
            TAG_KEY_COMMIT => receive_key_commit(&mut st, idx, &envelope[1..]),
            TAG_EPOCH_EVENT => receive_epoch_event(&mut st, idx, &envelope[1..]),
            // TreeKEM tree tags. In M2 shadow (keying switch OFF) these never touch content. In M3
            // (switch ON, fully-joined) a commit/welcome/join can change which tree epoch keys the
            // content, so after ingesting one we recompute the flip (`mls_refresh_keying`) and drain
            // the pending buffer — a Remove that advances the epoch, or a Welcome/join that completes
            // the all-joined gate, then unlocks content immediately. Still returns the handler's value
            // (no direct content change from the wire itself); a non-capable circle ignores them.
            TAG_MLS_COMMIT => {
                TREE_RETRYABLE.with(|f| f.set(false));
                let r = receive_mls_commit(&mut st, idx, &envelope[1..]);
                match r {
                    // Applied: this may be the envelope the buffer was waiting on.
                    Ok(true) => drain_pending_tree(&mut st, idx),
                    // Park ONLY the retryable outcomes (orphan / roster lag). Terminal falses —
                    // someone else's welcome, an unauthorized commit, a store-that-reports-false —
                    // poisoned the buffer with permanent residents when parked indiscriminately.
                    _ => {
                        if TREE_RETRYABLE.with(|f| f.get()) {
                            park_pending_tree(&mut st.circles[idx], envelope);
                        }
                    }
                }
                mls_refresh_keying(&mut st, idx);
                drain_pending(&mut st, idx);
                r
            }
            TAG_MLS_WELCOME => {
                TREE_RETRYABLE.with(|f| f.set(false));
                let r = receive_mls_welcome(&mut st, idx, &envelope[1..]);
                match r {
                    // Applied: this may be the envelope the buffer was waiting on.
                    Ok(true) => drain_pending_tree(&mut st, idx),
                    // Park ONLY the retryable outcomes (orphan / roster lag). Terminal falses —
                    // someone else's welcome, an unauthorized commit, a store-that-reports-false —
                    // poisoned the buffer with permanent residents when parked indiscriminately.
                    _ => {
                        if TREE_RETRYABLE.with(|f| f.get()) {
                            park_pending_tree(&mut st.circles[idx], envelope);
                        }
                    }
                }
                mls_refresh_keying(&mut st, idx);
                drain_pending(&mut st, idx);
                r
            }
            TAG_MLS_JOIN => {
                TREE_RETRYABLE.with(|f| f.set(false));
                let r = receive_mls_join(&mut st, idx, &envelope[1..]);
                match r {
                    // Applied: this may be the envelope the buffer was waiting on.
                    Ok(true) => drain_pending_tree(&mut st, idx),
                    // Park ONLY the retryable outcomes (orphan / roster lag). Terminal falses —
                    // someone else's welcome, an unauthorized commit, a store-that-reports-false —
                    // poisoned the buffer with permanent residents when parked indiscriminately.
                    _ => {
                        if TREE_RETRYABLE.with(|f| f.get()) {
                            park_pending_tree(&mut st.circles[idx], envelope);
                        }
                    }
                }
                mls_refresh_keying(&mut st, idx);
                drain_pending(&mut st, idx);
                r
            }
            TAG_ADMIN_GRANT => receive_admin_grant(&mut st, idx, &envelope[1..]),
            TAG_CIRCLE_UPGRADE => receive_circle_upgrade(&mut st, idx, &envelope[1..]),
            // Unbundled proposals (§4.2 roster path) are reserved for M4; a stray one is inert.
            TAG_MLS_PROPOSAL => Ok(false),
            TAG_DEVICE_ROSTER => {
                // Account-level (not circle-specific) — verify against the carried account bundle, store,
                // and rotate affected epochs. Forged/stale rosters are rejected inside the verifier.
                match decode_roster(&envelope[1..]).and_then(|(acct, list, creds, trailer)| {
                    HavenId::from_bytes(&acct).ok().map(|a| (a, list, creds, trailer))
                }) {
                    Some((account, list, creds, trailer)) => {
                        let stored = verify_and_store_roster(&mut st, &account, &list, &creds).known();
                        note_roster_capability(&mut st, &account, &trailer); // S0: learn capability (absence-safe)
                        note_seedless_own_roster_wire(&mut st, &account, envelope); // A3: verbatim primary wire
                        // A newly-learned roster may make a previously "unknown sender" event openable —
                        // drain the durable buffer so multi-device roster lag no longer loses posts.
                        let drained = drain_all_pending(&mut st);
                        for i in 0..st.circles.len() {
                            drain_pending_tree(&mut st, i);
                        }
                        Ok(stored || drained)
                    }
                    None => Ok(false),
                }
            }
            _ => receive_legacy(&mut st, idx, envelope), // untagged JSON `{…}` = legacy envelope
        })
    }

    fn merge_circle(st: &mut NetState, pc: PersistCircle) {
        let idx = match st.circles.iter().position(|c| c.id == pc.id) {
            Some(i) => i,
            None => {
                st.circles.push(Circle::bare(pc.id.clone(), pc.name.clone()));
                st.circles.len() - 1
            }
        };
        // Union the removal tombstones FIRST (grow-only across devices), so the member union below
        // can never re-admit someone a peer device removed.
        for mb in &pc.removed_members {
            if let Ok(id) = HavenId::from_bytes(mb) {
                if !st.circles[idx].removed_members.iter().any(|m| m.node_id_bytes() == id.node_id_bytes()) {
                    st.circles[idx].removed_members.push(id);
                }
            }
        }
        for mb in pc.members {
            if let Ok(id) = HavenId::from_bytes(&mb) {
                let removed = st.circles[idx].removed_members.iter().any(|m| m.node_id_bytes() == id.node_id_bytes());
                let present = st.circles[idx].members.iter().any(|m| m.node_id_bytes() == id.node_id_bytes());
                if !removed && !present {
                    st.circles[idx].members.push(id);
                }
            }
        }
        // Belt-and-suspenders: drop any current member that the merged tombstone set now covers (a
        // removal that arrived after they were already present locally).
        let removed_ids: HashSet<[u8; 32]> =
            st.circles[idx].removed_members.iter().map(|m| m.node_id_bytes()).collect();
        st.circles[idx].members.retain(|m| !removed_ids.contains(&m.node_id_bytes()));
        for e in pc.events {
            if !st.circles[idx].seen.contains(&e.id) {
                st.circles[idx].seen.insert(e.id.clone());
                st.circles[idx].events.push(e);
            }
        }
        // Union epoch keys + keep the highest epoch (multi-device sync / reload must not lose any key
        // or we'd be unable to open content sealed under an epoch another device advanced to).
        // Slots CONVERGE (larger key wins, loser kept as alt) exactly like live commit ingest — the
        // old first-wins `or_insert` let whichever state imported first pin a loser forever, one of
        // the ways linked devices ended up holding different keys for the same slot.
        for (e, k) in pc.my_epoch_keys {
            let c = &mut st.circles[idx];
            let mut primary = c.my_epoch_keys.get(&e).copied();
            let alts = c.my_epoch_keys_alt.entry(e).or_default();
            converge_epoch_key(&mut primary, alts, k);
            if let Some(w) = primary {
                c.my_epoch_keys.insert(e, w);
            }
        }
        if pc.my_epoch > st.circles[idx].my_epoch {
            st.circles[idx].my_epoch = pc.my_epoch;
        }
        for (a, e, k) in pc.peer_epoch_keys {
            let c = &mut st.circles[idx];
            let slot = (a, e);
            let mut primary = c.peer_epoch_keys.get(&slot).copied();
            let alts = c.peer_epoch_keys_alt.entry(slot.clone()).or_default();
            converge_epoch_key(&mut primary, alts, k);
            if let Some(w) = primary {
                c.peer_epoch_keys.insert(slot, w);
            }
        }
        // Alt (loser) keys ride the state blob too — union them as alts (never displacing a primary).
        for (e, k) in pc.my_epoch_keys_alt {
            let c = &mut st.circles[idx];
            if c.my_epoch_keys.get(&e) == Some(&k) {
                continue; // already the winner here
            }
            let alts = c.my_epoch_keys_alt.entry(e).or_default();
            if !alts.contains(&k) {
                if alts.len() >= ALT_KEYS_PER_SLOT {
                    alts.remove(0);
                }
                alts.push(k);
            }
        }
        for (a, e, k) in pc.peer_epoch_keys_alt {
            let c = &mut st.circles[idx];
            let slot = (a, e);
            if c.peer_epoch_keys.get(&slot) == Some(&k) {
                continue;
            }
            let alts = c.peer_epoch_keys_alt.entry(slot).or_default();
            if !alts.contains(&k) {
                if alts.len() >= ALT_KEYS_PER_SLOT {
                    alts.remove(0);
                }
                alts.push(k);
            }
        }
        if pc.my_circle_secret != [0u8; 32] && st.circles[idx].my_circle_secret == [0u8; 32] {
            st.circles[idx].my_circle_secret = pc.my_circle_secret;
        }
        for (a, s) in pc.peer_circle_secrets {
            st.circles[idx].peer_circle_secrets.entry(a).or_insert(s);
        }
        // Keep the LATEST rotation stamp (multi-device: my other device may have rotated more
        // recently). Taking the max can only delay the next rotation, never skip one.
        if pc.rotated_at > st.circles[idx].rotated_at {
            st.circles[idx].rotated_at = pc.rotated_at;
        }
        // Restore the sealed-commit cache so a daily backfill reuses the same commit bytes across
        // launches (context-hash-gated: a stale one is simply ignored and re-sealed on next export).
        if st.circles[idx].cached_commit.is_none() {
            st.circles[idx].cached_commit = pc.cached_commit;
        }
        // Restore the durable retry buffer (capped + deduped). A drain runs after this whole import
        // (import_state → drain_all_pending) so any key/roster we already hold unlocks it immediately.
        for raw in pc.pending_epoch {
            // Evict-oldest on overflow (same policy as park_pending) — an import must not
            // silently discard restored entries past the cap and re-wedge a healed buffer.
            park_pending(&mut st.circles[idx], &raw);
        }
        for raw in pc.pending_tree {
            park_pending_tree(&mut st.circles[idx], &raw);
        }
        // A restart is a natural convergence point: the keys/rosters we already hold may open what
        // was parked, and a restored tree buffer may contain the very commit whose loss forked us.
        drain_pending_tree(st, idx);
        // MLS M3 / AUDIT M2 authority: adopt the creator, giving a DEFINITION-pinned creator priority.
        // A signed circle-sync record (or another of my devices) carrying a definition-pinned creator is
        // authoritative — it re-pins even over a creator we only weakly TOFU-learned from a grant, which
        // un-wedges a victim a hostile grant may have raced. Absent a definition, we still learn-once
        // (TOFU carry) so nothing regresses. Admin grants are unioned (re-verified where they are used).
        if pc.creator_pinned && pc.creator.is_some() && !st.circles[idx].creator_pinned {
            st.circles[idx].creator = pc.creator;
            st.circles[idx].creator_pinned = true;
        } else if st.circles[idx].creator.is_none() {
            st.circles[idx].creator = pc.creator;
        }
        for g in pc.admin_grants {
            if !st.circles[idx].admin_grants.iter().any(|e| *e == g) {
                st.circles[idx].admin_grants.push(g);
            }
        }
        // §6.3-5: import UNIONS epoch keys, so an OLD exported blob could re-inject keys the pruner
        // already deleted — benign redundancy today, but a regression under the one-way-schedule
        // claim (a resurrected old key widens the exposure window past KEEP_EPOCHS). Re-prune after
        // the union so the retained window stays bounded at 4 regardless of what a stale blob carried.
        st.circles[idx].prune_epoch_keys();
    }

    fn author(&self, circle_id: &str, created_at: u64, kind: EventKind) -> Result<Vec<u8>, HavenError> {
        let mut st = self.state.lock().unwrap();
        let me_pub = st.me().clone();
        let event = Event::new(&me_pub.node_id_bytes(), created_at, kind);
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else {
            return Err(HavenError::Invalid { msg: "unknown circle".into() });
        };
        // B4: the live post/DM path now routes through `signer_of` with the SAME capable-circle gate the
        // sync/backfill bundle already uses (`epoch_sync_bundle_inner`), so author + backfill agree on the
        // signer. `under_device` = a device is adopted AND every member is affirmatively seed-drop-capable;
        // only then is a device-signed envelope chainable back to the account by every peer.
        let mut accounts = vec![me_pub.clone()];
        accounts.extend(st.circles[idx].members.iter().cloned());
        let under_device = st.device.is_some()
            && circle_fully_seed_drop_capable(&accounts, &st.device_lists, &st.seed_drop_capable);
        // A SEEDLESS device holds NO account key — its only signer is the device. In a circle that is not
        // yet fully capable, a device-signed post can't be chained to the account by peers, and there is no
        // account fallback: REFUSE rather than emit content no one can attribute (the gate is an enrollment
        // precondition, §7). A seeded device is unaffected — it always has the account key to fall back to.
        if st.me_secret.is_none() && !under_device {
            return Err(HavenError::Invalid {
                msg: "seedless device cannot author until its circle is fully seed-drop-capable".into(),
            });
        }
        // Seal under the circle's CURRENT epoch key (bootstrapping epoch 0 the first time). The key
        // commit that lets members open it rides `sync_envelopes`/`export_my_envelopes` (no separate
        // transport needed). Removed members lack the current epoch key → can't open this.
        //
        // M3: when the keying flip is LIVE (switch ON + fully-joined), seal under the TREE-derived
        // content key instead — the rest of this path (seal/store/feed) is byte-identical, only the
        // KEY SOURCE moves (§4.5). `mls_refresh_keying` (re)derives it and sets `mls_live_epoch`; when
        // shadow/parked it returns `None` and we fall back to the legacy sender-keys epoch.
        st.circles[idx].ensure_epoch();
        let content_epoch_live = mls_refresh_keying(&mut st, idx);
        let (epoch, key) = match content_epoch_live {
            Some(content_epoch) => {
                let key = st.circles[idx]
                    .my_epoch_keys
                    .get(&content_epoch)
                    .copied()
                    .expect("mls_refresh_keying populated my content key");
                (content_epoch, key)
            }
            None => {
                let epoch = st.circles[idx].my_epoch;
                (epoch, st.circles[idx].current_key().expect("epoch key exists after ensure_epoch"))
            }
        };
        // M6 (§6.5): the DM / LIVE lane gets a per-message ratchet — but ONLY when the tree is
        // live-keying (`content_epoch_live.is_some()`, which already implies `mls_keying` ON) AND
        // the app marked this circle a live lane. Feed circles + every OFF/shadow/parked circle fall
        // through to the unchanged epoch-key seal, so switch-OFF content is byte-identical.
        let ratchet_lane =
            content_epoch_live.is_some() && st.live_lane_circles.contains(circle_id);
        let env = if ratchet_lane {
            // Chain FROM the epoch sender key (§6.5). The per-epoch `SenderChain` is created lazily
            // and advanced once per DM; `MK_i` seals this message and its index `i` rides the
            // (authenticated) envelope. FS: the sender wipes its `MK_i` copy after sealing, and the
            // chain wiped `CK_i` on advance.
            let (i, mut mk) = {
                let gid = circle_id.as_bytes().to_vec();
                let chain = st.circles[idx]
                    .mls_ratchet
                    .send
                    .entry(epoch)
                    .or_insert_with(|| treekem::SenderChain::new(&key, &gid, epoch));
                chain.next_key()
            };
            let sealed =
                seal_event_ratcheted(signer_of(&st, under_device), circle_id, epoch, &mk, i, &event);
            treekem::wipe_secret(&mut mk);
            sealed
        } else {
            seal_event_in_epoch(signer_of(&st, under_device), circle_id, epoch, &key, &event)
        }
        .map_err(|e| HavenError::Invalid { msg: format!("seal failed: {e}") })?;
        st.circles[idx].seen.insert(event.id.clone());
        st.circles[idx].events.push(event);
        let compact = circle_is_compact_wire_capable(&st, idx);
        Ok(tagged(TAG_EPOCH_EVENT, &env.to_bytes_gated(compact)))
    }
}

/// Learn the capability markers from an ALREADY-SIGNATURE-VERIFIED profile payload.
///
/// Monotonic and affirmative-only: a marker present and >= 1 inserts, anything else does nothing, so
/// absence is never read as a downgrade. Called from BOTH profile entry points —
/// `verify_profile_card` (what the Apple and Android clients actually call) and
/// `profile_seed_drop_version` (what desktop calls) — because a capability learned on only one of
/// them is a capability that never converges on the platforms using the other. That split is exactly
/// how the compact-wire gate would have shipped as a silent no-op on iOS and Android.
///
/// The caller MUST have verified the signature first; this trusts its input.
fn learn_capabilities(st: &mut NetState, account: [u8; 32], payload: &[u8]) {
    let Ok(card) = serde_json::from_slice::<serde_json::Value>(payload) else { return };
    let marker = |k: &str| card.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
    if marker("sd") >= 1 {
        st.seed_drop_capable.insert(account);
    }
    if marker("ml") >= 1 {
        st.mls_capable.insert(account);
    }
    if marker("cw") >= 1 {
        st.compact_wire_capable.insert(account);
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
/// What ingesting a device roster actually DID. A bool could not say, and the difference matters
/// in three separate places:
///
///   * `Refused` — forged, unverifiable, or an attempted ROLLBACK to an older version. Keep looking
///     on other relays; this copy is worthless.
///   * `AlreadyCurrent` — we hold exactly this version. The overwhelmingly common steady-state
///     answer, and a SUCCESS: the roster is known, so post-roster recovery may run. But it is NOT a
///     reason to stop querying other relays, which may hold a NEWER one, and it must NOT trigger the
///     expensive re-seal below.
///   * `Stored` — the roster CHANGED. This is the only outcome that means the circle's epoch moved,
///     and therefore the only one that must re-seal history under the new epoch.
///
/// Collapsing the first two into `false` made a healthy device log "INGEST REJECTED" on every poll.
/// Collapsing the last two into `true` made it stop at the first relay holding a stale-but-equal
/// copy, so a device could sit a version behind forever while its siblings moved on.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RosterIngest {
    Refused,
    AlreadyCurrent,
    Stored,
}

impl RosterIngest {
    /// Legacy bool: "does the engine now know this roster?"
    fn known(self) -> bool {
        !matches!(self, RosterIngest::Refused)
    }
    fn code(self) -> i8 {
        match self {
            RosterIngest::Refused => -1,
            RosterIngest::AlreadyCurrent => 0,
            RosterIngest::Stored => 1,
        }
    }
}

fn verify_and_store_roster(st: &mut NetState, account: &HavenId, list_bytes: &[u8], cred_bytes: &[Vec<u8>]) -> RosterIngest {
    let Ok(list) = DeviceList::from_bytes(list_bytes) else { return RosterIngest::Refused };
    if list.verify(account).is_err() {
        return RosterIngest::Refused;
    }
    let mut credentials = Vec::with_capacity(cred_bytes.len());
    for cb in cred_bytes {
        let Ok(cred) = DeviceCredential::from_bytes(cb) else { return RosterIngest::Refused };
        if cred.verify(account).is_err() {
            return RosterIngest::Refused; // every credential must be signed by THIS account — no smuggling a rogue device.
        }
        credentials.push(cred);
    }
    let acct_id = account.node_id_bytes();
    let my_id = st.me().node_id_bytes();

    if acct_id == my_id {
        if let Some(me) = st.me_secret.as_ref() {
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
                Some(b) => b.merge(&list, me, list.updated_at),
                None => Some(list.clone()),
            };
            return match merged {
                Some(new_list) => {
                    st.device_lists.insert(acct_id, ContactDevices { list: new_list, credentials: creds });
                    for c in st.circles.iter_mut() {
                        c.rotate_epoch();
                    }
                    RosterIngest::Stored
                }
                None => {
                    if creds_grew {
                        if let Some(cd) = st.device_lists.get_mut(&acct_id) {
                            cd.credentials = creds;
                        }
                    }
                    if creds_grew { RosterIngest::Stored } else { RosterIngest::AlreadyCurrent }
                }
            };
        }
        // A2 SEEDLESS: my own roster, but I hold NO account key — so I can NEVER re-sign / union-merge it.
        // The PRIMARY is the sole multi-master resolver. Move forward ONLY via verified `adopt_if_newer`
        // (higher-version-wins; the list was already `verify()`-ed above) and union the credentials. There
        // is no self-re-sign path here at all — the `Option` on `me_secret` makes that a compile guarantee.
        let mut creds: Vec<DeviceCredential> =
            st.device_lists.get(&acct_id).map(|cd| cd.credentials.clone()).unwrap_or_default();
        let mut creds_grew = false;
        for c in &credentials {
            if !creds.iter().any(|e| e.device_id() == c.device_id()) {
                creds.push(c.clone());
                creds_grew = true;
            }
        }
        let adopted = match st.device_lists.get_mut(&acct_id) {
            Some(cd) => {
                let moved = cd.list.adopt_if_newer(&list);
                cd.credentials = creds;
                moved
            }
            None => {
                st.device_lists.insert(acct_id, ContactDevices { list, credentials: creds });
                true
            }
        };
        if adopted {
            for c in st.circles.iter_mut() {
                c.rotate_epoch();
            }
        }
        return if adopted || creds_grew { RosterIngest::Stored } else { RosterIngest::AlreadyCurrent };
    }

    // A CONTACT's roster: they re-sign their own union, so higher-version-wins with rollback defense.
    if let Some(existing) = st.device_lists.get(&acct_id) {
        if existing.list.version > list.version {
            return RosterIngest::Refused; // rollback / replay of an OLDER roster — ignore.
        }
        if existing.list.version == list.version {
            // ALREADY CURRENT — the overwhelmingly common case in steady state, and a SUCCESS, not a
            // refusal. Callers read this bool as "is this account's roster known to the engine?" and
            // gate their post-roster recovery on it (re-opening quarantined media, replaying the
            // durable `pending_epoch` buffer). Answering `false` here meant a perfectly healthy
            // device logged "devroster INGEST REJECTED … the engine refused them" on EVERY poll and
            // skipped that recovery forever, which is how an Android leg sat on 8 parked envelopes
            // it already had the roster for.
            return RosterIngest::AlreadyCurrent;
        }
    }
    st.device_lists.insert(acct_id, ContactDevices { list, credentials });
    for c in st.circles.iter_mut() {
        if c.members.iter().any(|m| m.node_id_bytes() == acct_id) {
            c.rotate_epoch();
        }
    }
    // M4 roster→Add/Remove automation: a contact's roster change — a newly-authorized device, or a
    // revocation — drives the LIVE tree to Add or authority-checked-Remove. Gated inside on the
    // keying committer, so an OFF/shadow circle is untouched (a non-admin's roster change can never
    // produce an accepted Remove: it is only ever authored by the circle's elected creator).
    for i in 0..st.circles.len() {
        mls_sync_roster_to_tree(st, i);
    }
    RosterIngest::Stored
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

/// The identity that signs outgoing commits + events (seed-drop S3). When `under_device` (an adopted device
/// key AND a fully seed-drop-capable circle — computed by the caller), sign under the DEVICE key; a device
/// signer is resolved back to its account by recipients via the verified roster, so authorship still binds
/// to the account. Otherwise sign under the ACCOUNT key (pre-adoption, or a circle with any peer that can't
/// yet verify a device→account chain). Borrowed as a temporary at each seal site — never held across a
/// mutable circle write.
fn signer_of(st: &NetState, under_device: bool) -> &Identity {
    if under_device {
        // Device-signed (fully-capable circle). Fall back to the account only on a seeded device that
        // somehow hasn't adopted a device key; a seedless device always has the device.
        st.device.as_ref().or(st.me_secret.as_ref()).expect("a signing identity exists")
    } else {
        // Account-signed (pre-adoption, or a circle with a peer that can't verify a device→account chain).
        // B5: on a SEEDLESS device there is NO account key, so the DEVICE signs — never a dummy identity.
        // (Callers gate the seedless not-fully-capable case in `author`; the backfill path has no account
        // fallback either, so the device is the only correct signer.)
        st.me_secret.as_ref().or(st.device.as_ref()).expect("a signing identity exists")
    }
}

/// If `sender_hex` is an AUTHORIZED device of a member of circle `idx` (or of me), return that device's
/// verifying bundle AND the ACCOUNT id that authorizes it — the account whose credential chain (verified at
/// roster ingest) vouches for `sender_hex`. Seed-drop needs the account to (a) bind a device-signed event's
/// `author` to that account (S1) and (b) key the epoch commit/lookup by the account, not the signing device
/// (S3). The device's account being a circle member (or mine) is the only remaining check.
fn authorized_device_and_account(st: &NetState, idx: usize, sender_hex: &str) -> Option<(HavenId, [u8; 32])> {
    let my_id = st.me().node_id_bytes();
    for (acct_id, cd) in &st.device_lists {
        let acct_in_circle =
            *acct_id == my_id || st.circles[idx].members.iter().any(|m| m.node_id_bytes() == *acct_id);
        if !acct_in_circle {
            continue;
        }
        for bundle in cd.authorized_bundles() {
            if hex(&bundle.node_id_bytes()) == sender_hex {
                return Some((bundle, *acct_id));
            }
        }
    }
    None
}

/// My own roster wire (tagged) with the signed seed-drop capability TRAILER appended (S0). The trailer is
/// account-signed (forge/strip-proof) and IGNORED by older clients — [`decode_roster`] stops after the
/// credentials — so carrying it is strictly additive: a 1.0.4 peer reads the roster and skips the trailer.
/// Only emitted for MY OWN roster (I can only sign my own capability); a contact's re-broadcast roster
/// carries no trailer, and their capability travels in their own roster + signed profile instead.
fn my_roster_wire(me: &Identity, me_pub: &HavenId, cd: &ContactDevices) -> Vec<u8> {
    let mut body = encode_roster(me_pub, cd);
    body.extend_from_slice(&SeedDropCapability::issue(me, SEED_DROP_VERSION).to_bytes());
    tagged(TAG_DEVICE_ROSTER, &body)
}

/// Record a seed-drop capability TRAILER carried alongside a received roster (S0). Verifies the
/// account-signed marker and, if valid and >= v1, MONOTONICALLY records the account as capable. A
/// missing / short / forged trailer is simply ignored — never treated as "downgraded" (absence is never
/// information). This is real negotiation input; the dual-seal gate that would consume it is OFF this
/// release, so nothing acts on it to change what a circle seals to yet.
fn note_roster_capability(st: &mut NetState, account: &HavenId, trailer: &[u8]) {
    if let Some(cap) = SeedDropCapability::from_bytes(trailer) {
        if cap.version >= 1 && cap.verify(account).is_ok() {
            st.seed_drop_capable.insert(account.node_id_bytes());
        }
    }
}

/// A3: when MY OWN account's roster arrives on a SEEDLESS device (from the enroll grant or a self-sync
/// rebroadcast), stash the exact tagged wire bytes — trailer and all. A seedless device has no account key
/// to re-mint this, so `own_roster_wire` hands these VERBATIM bytes back out at every emit site; re-encoding
/// would strip the primary-signed `SeedDropCapability` trailer and stall the circle's capability convergence
/// (§7 capability fidelity). No-op on a primary (it signs its own wire fresh) or for a contact's roster.
fn note_seedless_own_roster_wire(st: &mut NetState, account: &HavenId, wire: &[u8]) {
    if st.me_secret.is_none() && account.node_id_bytes() == st.me_pub.node_id_bytes() {
        st.seedless_roster_wire = Some(wire.to_vec());
    }
}

/// Wire layout: `lp(account_bundle) ‖ lp(device_list) ‖ u32 n ‖ lp(credential)*n` (all u32-LE lengths),
/// optionally followed by a seed-drop capability TRAILER (S0, see [`my_roster_wire`]).
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

/// Inverse of [`encode_roster`]: returns `(account_bundle, device_list_bytes, credential_bytes, trailer)`
/// where `trailer` is any bytes AFTER the credentials — a seed-drop capability marker (S0) on a newer
/// peer, empty on an older one. Kept optional/trailing so an old client (which never reads past the
/// credentials) still decodes a new roster and a new client still decodes an old one.
fn decode_roster(b: &[u8]) -> Option<(Vec<u8>, Vec<u8>, Vec<Vec<u8>>, Vec<u8>)> {
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
    let trailer = b[i..].to_vec();
    Some((account, list, creds, trailer))
}

/// Seed-drop S1: does one of `account`'s AUTHORIZED devices sign `signed_bytes`? Chains through the
/// roster verified at ingest (every credential was checked against the pinned account key), so a device
/// acting for the account is trusted. False when we hold no roster for the account. Additive — callers try
/// it only after the account-key verify fails, which for today's account-signed content never matches.
fn profile_signed_by_authorized_device(st: &NetState, account: &HavenId, signed_bytes: &[u8], sig: &[u8]) -> bool {
    match st.device_lists.get(&account.node_id_bytes()) {
        Some(cd) => cd.authorized_bundles().iter().any(|dev| dev.verify(signed_bytes, sig).is_ok()),
        None => false,
    }
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

    // ── Compact wire, write-side (docs/SATELLITE-DESIGN.md §6, S0) ───────────────────────────────

    /// The safety property, and the reason the flip is gated at all: until every member has
    /// affirmatively advertised `cw`, we keep emitting the container everyone can read. A client that
    /// cannot parse what we send loses the message outright — there is no renegotiation once the
    /// bytes are in the mailbox — so silence must mean JSON.
    #[test]
    fn a_circle_with_an_unadvertised_member_stays_on_json() {
        let alice = HavenSocial::new([11u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([12u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Alice has never seen Bob's profile card, so she knows nothing about what he can read.
        let env = alice
            .post(cid.clone(), "still json".into(), vec![], None, None, false, false, 1_000)
            .unwrap();
        assert_eq!(env[0], TAG_EPOCH_EVENT, "wire tag");
        assert_eq!(env[1], b'{', "an unknown member must keep the circle on the JSON container");
    }

    /// Once every member has advertised, the circle flips and the savings are real — and the message
    /// still arrives, decrypts and reads correctly on the far side.
    #[test]
    fn a_fully_advertised_circle_emits_the_compact_container_and_still_delivers() {
        let alice = HavenSocial::new([13u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([14u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Baseline: JSON before Alice learns anything about Bob.
        let before = alice
            .post(cid.clone(), "before".into(), vec![], None, None, false, false, 900)
            .unwrap();
        assert_eq!(before[1], b'{');

        // Bob's SIGNED card carries `cw`; consuming it is what teaches Alice he can read the
        // container. This is the same call the app already makes for `sd` and `ml`.
        let card = bob.my_signed_profile("Bob".into(), String::new(), String::new(), String::new(), String::new());
        alice.profile_seed_drop_version(bob.my_bundle(), card);

        let after = alice
            .post(cid.clone(), "after — compact".into(), vec![], None, None, false, false, 1_000)
            .unwrap();
        assert_eq!(after[0], TAG_EPOCH_EVENT, "wire tag is unchanged");
        assert_eq!(&after[1..6], b"HVEP1", "a fully-capable circle emits the compact container");

        // The whole point: materially fewer bytes for the same message.
        assert!(
            after.len() * 3 < before.len(),
            "compact {} B should be >3x smaller than json {} B",
            after.len(),
            before.len()
        );

        // And it must actually arrive. Bob buffers until the key commit, then reads it.
        assert!(!bob.receive(cid.clone(), after.clone()).unwrap());
        sync(&alice, &bob, &cid);
        let feed = bob.feed(cid.clone(), 2_000, None);
        assert!(
            feed.iter().any(|e| e.body == "after — compact"),
            "the compact-container post must decrypt and land in the feed: {:?}",
            feed.iter().map(|e| &e.body).collect::<Vec<_>>()
        );
    }

    /// A LEGACY circle — no MLS, no device rosters, no seed-drop capability, and no way to ever get
    /// them — still gets the smaller wire.
    ///
    /// This is deliberate and load-bearing. `circle_fully_compact_wire_capable` is intentionally NOT
    /// composed with `circle_fully_seed_drop_capable` or `circle_fully_mls_capable`, because being
    /// able to parse a container is a property of the app BUILD, not of key management. Composing
    /// them would have stranded every legacy circle on the 3.5x-larger encoding permanently, for no
    /// safety gain — the circles least likely to ever upgrade their keying would have been the ones
    /// paying the most bytes.
    #[test]
    fn a_legacy_non_mls_circle_still_gets_the_compact_container() {
        let alice = HavenSocial::new([31u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([32u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Establish that this really is a legacy circle: nobody has exchanged a device roster, so
        // the MLS gate cannot hold and never will until rosters appear.
        {
            let st = alice.state.lock().unwrap();
            let idx = st.circles.iter().position(|c| c.id == cid).unwrap();
            assert!(st.device_lists.is_empty(), "no device rosters — this is a legacy circle");
            assert!(!circle_is_mls_capable(&st, idx), "a roster-less circle is not MLS-capable");
        }

        // Only the compact-wire marker is exchanged. No roster, no seed-drop, no MLS.
        let card = bob.my_signed_profile("Bob".into(), String::new(), String::new(), String::new(), String::new());
        assert!(alice.verify_profile_card(bob.my_bundle(), card).is_some());

        // Still not MLS-capable...
        {
            let st = alice.state.lock().unwrap();
            let idx = st.circles.iter().position(|c| c.id == cid).unwrap();
            assert!(!circle_is_mls_capable(&st, idx), "still not MLS-capable");
            assert!(circle_is_compact_wire_capable(&st, idx), "...but compact-wire capable");
        }

        // ...and the wire is compact anyway, and the message still arrives.
        let env = alice
            .post(cid.clone(), "legacy circle, small wire".into(), vec![], None, None, false, false, 1_000)
            .unwrap();
        assert_eq!(&env[1..6], b"HVEP1", "a legacy circle must still get the compact container");

        assert!(!bob.receive(cid.clone(), env).unwrap());
        sync(&alice, &bob, &cid);
        assert!(
            bob.feed(cid.clone(), 2_000, None).iter().any(|e| e.body == "legacy circle, small wire"),
            "and it must still decrypt on the far side"
        );
    }

    /// The gate has to open through the call the CLIENTS actually make.
    ///
    /// iOS and Android consume profiles via `verify_profile_card`; only desktop calls
    /// `profile_seed_drop_version`. Learning the markers in just one of them means the compact
    /// container never gets emitted on the two platforms that matter most, and it would fail
    /// silently — the app works, it is merely 3.5x more expensive forever. Both paths must teach.
    #[test]
    fn both_profile_entry_points_open_the_gate() {
        for use_card_path in [true, false] {
            let seed = if use_card_path { 21u8 } else { 23u8 };
            let alice = HavenSocial::new([seed; 32].to_vec()).unwrap();
            let bob = HavenSocial::new([seed + 1; 32].to_vec()).unwrap();
            let cid = DEFAULT_CIRCLE.to_string();
            alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();

            let card = bob.my_signed_profile("Bob".into(), String::new(), String::new(), String::new(), String::new());
            if use_card_path {
                // What iOS and Android call.
                assert!(alice.verify_profile_card(bob.my_bundle(), card).is_some());
            } else {
                // What desktop calls.
                alice.profile_seed_drop_version(bob.my_bundle(), card);
            }

            let env = alice
                .post(cid.clone(), "compact?".into(), vec![], None, None, false, false, 1_000)
                .unwrap();
            assert_eq!(
                &env[1..6],
                b"HVEP1",
                "the gate must open via {}",
                if use_card_path { "verify_profile_card (iOS/Android)" } else { "profile_seed_drop_version (desktop)" }
            );
        }
    }

    /// The capability must ride the ACCOUNT-SIGNED payload, so a relay can neither forge it (which
    /// would push a circle onto a container a member cannot read) nor strip it (which would only ever
    /// cost bytes, never correctness).
    #[test]
    fn the_compact_marker_is_signed_and_a_forged_card_teaches_nothing() {
        let alice = HavenSocial::new([15u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([16u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();

        let card = bob.my_signed_profile("Bob".into(), String::new(), String::new(), String::new(), String::new());
        let sig_len = u32::from_le_bytes([card[0], card[1], card[2], card[3]]) as usize;
        let payload: serde_json::Value =
            serde_json::from_slice(&card[4 + sig_len..]).expect("card payload is JSON");
        assert_eq!(payload.get("cw").and_then(|x| x.as_u64()), Some(1), "`cw` rides the signed payload");

        // A tampered card is rejected outright, so it cannot flip the circle.
        let mut forged = card.clone();
        let n = forged.len();
        forged[n - 2] ^= 0xff;
        alice.profile_seed_drop_version(bob.my_bundle(), forged);
        let env = alice
            .post(cid.clone(), "unchanged".into(), vec![], None, None, false, false, 1_100)
            .unwrap();
        assert_eq!(env[1], b'{', "a forged card must not flip the container");
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
    fn envelope_outer_dedupe_skips_re_deliveries_but_never_wedges() {
        let alice = HavenSocial::new([3u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([4u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid, alice.my_bundle()).unwrap();

        // An envelope for a circle Bob doesn't have yet is ignored AND not recorded as seen —
        // the identical bytes must still land once the circle exists.
        alice.create_circle("fam".into(), "Family".into());
        alice.add_contact_bundle("fam".into(), bob.my_bundle()).unwrap();
        let fam_env = alice.post("fam".into(), "family only".into(), vec![], None, None, false, false, 1_000).unwrap();
        assert!(!bob.receive("fam".into(), fam_env.clone()).unwrap(), "unknown circle is ignored");
        bob.create_circle("fam".into(), "Family".into());
        bob.add_contact_bundle("fam".into(), alice.my_bundle()).unwrap();
        let _ = bob.receive("fam".into(), fam_env.clone()); // buffers until the key commit arrives
        sync(&alice, &bob, "fam");
        assert_eq!(bob.feed("fam".into(), 2_000, None).len(), 1, "post lands once the circle exists");

        // Re-blasting the full history (what peers do on a timer) is rejected by outer hash
        // before the engine lock — and stays exactly as much of a no-op as engine dedupe was.
        sync(&alice, &bob, "fam");
        assert!(!bob.receive("fam".into(), fam_env.clone()).unwrap(), "identical bytes skip early");
        assert_eq!(bob.feed("fam".into(), 2_000, None).len(), 1, "re-blast stays deduped");

        // Leaving a circle clears its seen-set: a re-join re-ingests the same bytes.
        bob.leave_circle("fam".into());
        bob.create_circle("fam".into(), "Family".into());
        bob.add_contact_bundle("fam".into(), alice.my_bundle()).unwrap();
        sync(&alice, &bob, "fam");
        assert_eq!(bob.feed("fam".into(), 2_000, None).len(), 1, "history re-lands after leave + re-join");
    }

    #[test]
    fn last_authored_event_id_matches_the_feed() {
        let alice = HavenSocial::new([50u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([51u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Author a post → the FFI hands back the engine-derived id (BLAKE3 over
        // author ‖ created_at ‖ kind, computed inside Event::new — the caller can't
        // predict it), and it is exactly the id feed() shows for that post.
        alice.post(cid.clone(), "hello".into(), vec![], None, None, false, false, 1_000).unwrap();
        let id = alice.last_authored_event_id(cid.clone(), 1_000).expect("id of the post just created");
        let feed = alice.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].id, id, "the returned id is what feed() shows for the post");

        // Content-addressed → the RECIPIENT computes the same id, so a sealed banner's
        // `p` deep-link tag resolves on their device too.
        sync(&alice, &bob, &cid);
        assert_eq!(bob.feed(cid.clone(), 2_000, None)[0].id, id, "recipient sees the same id");

        // Each timestamp resolves to its own event; earlier posts stay addressable.
        alice.post(cid.clone(), "again".into(), vec![], None, None, false, false, 1_500).unwrap();
        let id2 = alice.last_authored_event_id(cid.clone(), 1_500).expect("second post's id");
        assert_ne!(id2, id);
        assert_eq!(alice.last_authored_event_id(cid.clone(), 1_000), Some(id));

        // Only MY authored events answer: Bob holds Alice's post at ts 1000, but he
        // authored nothing — a received event must never masquerade as his.
        assert_eq!(bob.last_authored_event_id(cid.clone(), 1_000), None);
        // Unknown circle / no event at that timestamp → None (best-effort contract).
        assert_eq!(alice.last_authored_event_id("nope".into(), 1_000), None);
        assert_eq!(alice.last_authored_event_id(cid, 999), None);
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

    /// APNs rejects any payload over 4 KiB (5 KiB for VoIP) with 413 PayloadTooLarge, and the push
    /// worker discarded that status — so an oversized envelope silently killed EVERY notification:
    /// DMs, posts, and the call doorbell alike. That is what "calls never ring and no banner ever
    /// appears" actually was. v1 carried a 3,200-byte hybrid bundle plus a 3,373-byte hybrid
    /// signature and base64'd to ~10 KiB — the bundle alone exceeded the whole budget.
    ///
    /// Assert the budget here, where a failure is one red test, instead of in a 413 that nothing
    /// logs and no user can report. If this trips, do NOT raise the limit: APNs sets it.
    #[test]
    fn signed_notification_fits_in_an_apns_payload() {
        const APNS_ALERT_LIMIT: usize = 4096;
        let alice = HavenSocial::new([30u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([31u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        let bob_hex = alice.add_contact_bundle(cid, bob.my_bundle()).unwrap();

        // A generous worst case: a long display name plus a full-length DM preview.
        let body = format!(
            r#"{{"t":"{}","b":"{}"}}"#,
            "A Fairly Long Display Name Indeed",
            "x".repeat(400)
        );
        let blob = alice.seal_signed_notification(bob_hex, body.into_bytes()).unwrap();
        // The client base64s the envelope into the APNs JSON, so that is the length Apple measures.
        let b64_len = blob.len().div_ceil(3) * 4;
        assert!(
            b64_len < APNS_ALERT_LIMIT,
            "notification envelope is {b64_len} B base64; APNs caps at {APNS_ALERT_LIMIT} B"
        );
    }

    // A minimal SDP offer body in the on-wire call-frame shape `[hex64][…][json]`; only the DTLS
    // fingerprint matters for the MITM test.
    fn offer_body(from_hex: &str, fingerprint: &str) -> Vec<u8> {
        let mut v = from_hex.as_bytes().to_vec();
        let json = format!(r#"{{"t":"offer","sdp":"a=fingerprint:sha-256 {fingerprint}"}}"#);
        v.extend_from_slice(json.as_bytes());
        v
    }

    /// A call frame addressed to one of our DEVICE ids must open. Under device-id transport a linked
    /// device dials and is dialed AS ITSELF, so the sender signs over the device hex it addressed —
    /// while `open_call_frame` verified only against the ACCOUNT hex and threw the frame away as a
    /// forgery. Field symptom: the callee's phone rings, they answer, and the call never connects,
    /// because every invite (21) and hangup (12) was discarded at that check.
    ///
    /// This is the cross-peer case `141bb57` called out as untested when the same class of bug hit
    /// media ("this path had NO cross-peer test, which is why it shipped"). It asserts BOTH halves:
    /// a device-addressed frame is accepted, and widening to device ids does not accept a frame
    /// addressed to somebody else.
    #[test]
    fn a_call_frame_addressed_to_our_device_id_opens() {
        const INVITE: u8 = 21;
        let alice = HavenSocial::new([60u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([61u8; 32].to_vec()).unwrap();
        let carol = HavenSocial::new([62u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        let bob_account = alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        let carol_account = alice.add_contact_bundle(cid.clone(), carol.my_bundle()).unwrap();

        // Bob is a linked device: he transports as his DEVICE id, not his account id.
        assert!(bob.use_device_identity([63u8; 32].to_vec()));
        let bob_device = bob.my_device_node_hex();
        assert_ne!(bob_device, bob_account, "device identity must differ from the account id");

        // Alice can only ADDRESS a device she knows about, so Bob publishes a roster authorizing his
        // account + his linked device, and Alice ingests it. This ordering is the whole point: before
        // the roster lands Alice seals to Bob's ACCOUNT and everything works, which is why this bug
        // hides until rosters actually propagate — and `52c3e01` made them propagate.
        let bob_dev_bundle = bob.my_device_bundle();
        let bob_acct_id = Identity::from_seed(&[61u8; 32]).public().node_id_bytes().to_vec();
        let bob_dev_id = HavenId::from_bytes(&bob_dev_bundle).unwrap().node_id_bytes().to_vec();
        let acct_cred =
            crate::multidevice::issue_device_credential([61u8; 32].to_vec(), bob.my_bundle(), "bob-primary".into(), 0).unwrap();
        let dev_cred =
            crate::multidevice::issue_device_credential([61u8; 32].to_vec(), bob_dev_bundle, "bob-linked".into(), 1).unwrap();
        let roster = crate::multidevice::sign_device_list(
            [61u8; 32].to_vec(),
            1,
            0,
            vec![bob_acct_id, bob_dev_id],
            vec![],
        )
        .unwrap();
        assert!(bob.set_my_device_roster(roster.clone(), vec![acct_cred.clone(), dev_cred.clone()]));
        assert!(alice.ingest_device_roster(bob.my_bundle(), roster, vec![acct_cred, dev_cred]));

        // Alice invites the DEVICE (what device-id transport actually addresses).
        let to_device = alice.seal_call_frame(bob_device.clone(), INVITE, b"invite-body".to_vec()).unwrap();
        let opened = bob
            .open_call_frame(INVITE, to_device)
            .expect("a frame addressed to our own device id must open — this is the call-connect bug");
        assert_eq!(opened.sender_hex, alice.my_node_hex(), "sender still cryptographically proven");
        assert_eq!(opened.data, b"invite-body");

        // The account-addressed form keeps working — a seeded peer still addresses the account.
        let to_account = alice.seal_call_frame(bob_account, INVITE, b"invite-body".to_vec()).unwrap();
        assert!(
            bob.open_call_frame(INVITE, to_account.clone()).is_some(),
            "account-addressed frames still open — diagnosis: {}",
            bob.diagnose_call_frame(INVITE, to_account)
        );

        // And the recipient binding still binds: a frame for CAROL must not open for Bob, or
        // accepting device ids would have widened this into a cross-user replay.
        let for_carol = alice.seal_call_frame(carol_account, INVITE, b"invite-body".to_vec()).unwrap();
        assert!(
            bob.open_call_frame(INVITE, for_carol).is_none(),
            "a frame addressed to another user must still be refused"
        );
    }

    /// R1: a WebRTC call frame is now sealed + signed, so the relay-MITM (rewrite the DTLS-SRTP
    /// fingerprint in a plaintext offer to intercept the media) and the caller-ID spoof are both dead.
    /// This exercises the frame-9 relay-forward path specifically: the relay (Mallory) sees only the
    /// opaque sealed blob it must forward, and every tamper/forge she can attempt is REJECTED, while
    /// the genuine signed frame is ACCEPTED.
    #[test]
    fn call_frame_seal_defeats_relay_mitm() {
        const OFFER: u8 = 16;
        let alice = HavenSocial::new([40u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([41u8; 32].to_vec()).unwrap();
        let mallory = HavenSocial::new([42u8; 32].to_vec()).unwrap(); // a circle-member relay (e.g. a Pi)
        let cid = DEFAULT_CIRCLE.to_string();
        // Everyone is in the same circle (Mallory is an ordinary member who also runs the relay).
        let bob_hex = alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        alice.add_contact_bundle(cid.clone(), mallory.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), mallory.my_bundle()).unwrap();
        mallory.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        mallory.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();

        let good_fpr = "AA:BB:CC"; // Alice's real DTLS-SRTP fingerprint
        let evil_fpr = "EE:VV:IL"; // the attacker's — accepting it terminates DTLS at the attacker

        // Alice → Bob: the genuine sealed+signed offer. This is the exact blob a relay must forward.
        let blob = alice
            .seal_call_frame(bob_hex.clone(), OFFER, offer_body(&alice.my_node_hex(), good_fpr))
            .unwrap();

        // (0) ACCEPT: Bob opens the genuine frame, the sender is PROVEN to be Alice, and the
        //     fingerprint he'll pin is Alice's real one.
        let opened = bob.open_call_frame(OFFER, blob.clone()).expect("genuine frame accepted");
        assert_eq!(opened.sender_hex, alice.my_node_hex(), "sender cryptographically proven to be Alice");
        assert!(
            String::from_utf8_lossy(&opened.data).contains(good_fpr),
            "Bob pins Alice's real fingerprint"
        );

        // (1) The relay can't even READ the offer: the fingerprint is not present anywhere in the
        //     forwarded bytes (it's inside the seal), so candidate IPs + the fingerprint stay private.
        assert!(
            !String::from_utf8_lossy(&blob).contains(good_fpr),
            "sealed frame does not expose the fingerprint to the relay"
        );

        // (2) MITM REJECTED — the relay flips bytes in the sealed body to try to rewrite the
        //     fingerprint. The AEAD seal fails to open → dropped, so Bob never sees the evil fingerprint.
        let mut rewritten = blob.clone();
        let n = rewritten.len() - 1;
        rewritten[n] ^= 0xff;
        assert!(bob.open_call_frame(OFFER, rewritten).is_none(), "relay-rewritten offer rejected");

        // (3) SPOOF REJECTED — Mallory forges her OWN sealed+signed offer to Bob carrying the evil
        //     fingerprint but claims (in the plaintext `from` prefix) to be Alice. open_call_frame
        //     returns MALLORY as the proven sender, never Alice: she cannot sign as Alice. Bob's
        //     roster gate then sees the sender is not the claimed contact and drops it.
        let forged = mallory
            .seal_call_frame(bob_hex.clone(), OFFER, offer_body(&alice.my_node_hex(), evil_fpr))
            .unwrap();
        let opened = bob.open_call_frame(OFFER, forged).expect("Mallory's own frame opens");
        assert_eq!(
            opened.sender_hex,
            mallory.my_node_hex(),
            "the proven sender is Mallory, NOT the Alice she impersonated in the plaintext"
        );
        assert_ne!(opened.sender_hex, alice.my_node_hex());
        let claimed = String::from_utf8_lossy(&opened.data[..64]);
        assert_eq!(claimed, alice.my_node_hex(), "she DID claim to be Alice in the body…");
        assert_ne!(opened.sender_hex, claimed, "…but the crypto exposes the lie");

        // (4) REPLAY-AS-OTHER-TYPE REJECTED — the captured genuine offer replayed under a different
        //     frame type (e.g. 17 answer) fails, because the frame type is bound into the signature.
        assert!(bob.open_call_frame(17, blob.clone()).is_none(), "offer replayed as answer rejected");

        // (5) WRONG-RECIPIENT REJECTED — the frame sealed to Bob can't be opened by anyone else, and
        //     an OLD unsealed frame (the pre-R1 spoofable form) is refused outright.
        assert!(mallory.open_call_frame(OFFER, blob.clone()).is_none(), "frame sealed to Bob unreadable by the relay");
        let raw_unsealed = offer_body(&alice.my_node_hex(), good_fpr);
        assert!(bob.open_call_frame(OFFER, raw_unsealed).is_none(), "legacy unsealed frame refused (no downgrade)");
    }

    /// The shared skew-serialization lock. EVERY clock-sensitive test participates through it:
    /// `with_clock_advanced` takes it EXCLUSIVE (write) while it perturbs the global skew, and
    /// `clock_guard` takes it SHARED (read) for a test that must not observe a parallel test's skew.
    /// A RwLock (not a Mutex) so the many clock-sensitive readers — the M5 PCS cadence made every
    /// LIVE-MLS full bundle read the global clock, enrolling all the live-MLS epoch tests — still run
    /// concurrently with each other, blocking only for the brief window an advancer holds the write.
    static CLOCK_LOCK: std::sync::RwLock<()> = std::sync::RwLock::new(());

    /// Advance the test clock by `secs` for the duration of the closure, then restore it. Takes the
    /// EXCLUSIVE lock so no clock-sensitive reader observes the transient skew.
    fn with_clock_advanced<T>(secs: u64, f: impl FnOnce() -> T) -> T {
        use std::sync::atomic::Ordering;
        let _g = CLOCK_LOCK.write().unwrap_or_else(|e| e.into_inner());
        TEST_CLOCK_SKEW.fetch_add(secs, Ordering::Relaxed);
        let out = f();
        TEST_CLOCK_SKEW.fetch_sub(secs, Ordering::Relaxed);
        out
    }

    /// RAII form: hold the skew lock SHARED (read) for the caller's scope. Add
    /// `let _clk = clock_guard();` at the top of a rotation-/PCS-sensitive test so a parallel
    /// clock-advancing test can't leak a week of skew into it and spuriously fire a rotation or a PCS
    /// leaf Update. Readers share, so guarded tests still run in parallel; one line, no re-indentation.
    fn clock_guard() -> std::sync::RwLockReadGuard<'static, ()> {
        CLOCK_LOCK.read().unwrap_or_else(|e| e.into_inner())
    }

    /// The PERIODIC rotation (audit C2): a circle with NO membership churn must still advance its
    /// epoch once `ROTATE_INTERVAL_SECS` passes, driven by the ordinary sync bundle rather than by any
    /// platform timer — and a peer must keep reading straight through the rotation.
    #[test]
    fn quiet_circle_rotates_on_schedule_and_peer_still_reads() {
        let alice = HavenSocial::new([44u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([45u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        alice.post(cid.clone(), "before".into(), vec![], None, None, false, false, 1).unwrap();
        let sync = |from: &HavenSocial, to: &HavenSocial| {
            for env in from.sync_envelopes(cid.clone()) {
                to.receive(cid.clone(), env).unwrap();
            }
        };
        // rotate_if_stale reads the GLOBAL test clock skew, so serialize this no-rotation window against
        // any parallel clock-advancing test by holding the same lock `with_clock_advanced` uses (adding
        // zero skew) — otherwise another test's transient skew could spuriously rotate this quiet circle.
        let epoch_before = with_clock_advanced(0, || {
            sync(&alice, &bob);
            let e = alice.state.lock().unwrap().circles[0].my_epoch;
            // A sync BEFORE the interval elapses must not rotate — otherwise every sync would re-seal
            // history and the epoch would run away.
            sync(&alice, &bob);
            assert_eq!(
                alice.state.lock().unwrap().circles[0].my_epoch,
                e,
                "a quiet circle must not rotate before the interval elapses"
            );
            e
        });

        // Cross the interval with NO membership change at all: the next sync bundle must rotate.
        with_clock_advanced(ROTATE_INTERVAL_SECS + 1, || {
            alice.post(cid.clone(), "after".into(), vec![], None, None, false, false, 2).unwrap();
            sync(&alice, &bob);
        });
        let epoch_after = alice.state.lock().unwrap().circles[0].my_epoch;
        assert!(
            epoch_after > epoch_before,
            "quiet circle rotated on schedule ({epoch_before} -> {epoch_after})"
        );

        // The whole point: Bob reads ACROSS the rotation. The post from the old epoch is still
        // readable (re-sealed forward under the new one), and so is the new post.
        let texts: Vec<String> = bob.feed(cid.clone(), 9_000, None).into_iter().map(|e| e.body).collect();
        assert!(texts.iter().any(|t| t == "before"), "pre-rotation post survived: {texts:?}");
        assert!(texts.iter().any(|t| t == "after"), "post-rotation post readable: {texts:?}");

        // And a peer that slept through the ENTIRE rotation still catches up from cold: rotation
        // frequency can't strand an offline member, because history re-seals under the current epoch.
        let carol = HavenSocial::new([46u8; 32].to_vec()).unwrap();
        alice.add_contact_bundle(cid.clone(), carol.my_bundle()).unwrap();
        carol.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        with_clock_advanced(ROTATE_INTERVAL_SECS + 1, || sync(&alice, &carol));
        let seen: Vec<String> = carol.feed(cid.clone(), 9_000, None).into_iter().map(|e| e.body).collect();
        assert!(seen.iter().any(|t| t == "before"), "late peer got pre-rotation history: {seen:?}");
        assert!(seen.iter().any(|t| t == "after"), "late peer got post-rotation content: {seen:?}");
    }

    /// A head-only bundle must NEVER rotate: it carries no re-seal, so bumping the epoch there would
    /// strand relay-only readers on `pending_epoch` until the next full backfill.
    #[test]
    fn head_only_bundle_does_not_rotate() {
        let alice = HavenSocial::new([47u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.post(cid.clone(), "x".into(), vec![], None, None, false, false, 1).unwrap();
        let _ = alice.sync_envelopes(cid.clone()); // stamps the rotation window
        let epoch = alice.state.lock().unwrap().circles[0].my_epoch;
        with_clock_advanced(ROTATE_INTERVAL_SECS * 3, || {
            let _ = alice.export_epoch_head(cid.clone());
            let _ = alice.export_recent_envelopes(cid.clone(), 5);
        });
        assert_eq!(
            alice.state.lock().unwrap().circles[0].my_epoch,
            epoch,
            "head-only / limited bundles carry no re-seal, so they must not rotate"
        );
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
        use haven_p2p::device::{DeviceCredential, DeviceList};
        let account = Identity::from_seed(&[1u8; 32]);
        let phone = Identity::from_seed(&[2u8; 32]);
        let imposter = Identity::from_seed(&[9u8; 32]);

        let list = DeviceList::signed(&account, 1, 0, vec![phone.public().node_id_bytes()], vec![]);
        let cred = DeviceCredential::issue(&account, &phone.public(), "phone", 1);
        let cd = ContactDevices { list: list.clone(), credentials: vec![cred.clone()] };

        // Wire round-trip.
        let (acct_b, list_b, creds_b, trailer) = decode_roster(&encode_roster(&account.public(), &cd)).expect("decode");
        assert_eq!(acct_b, account.public().to_bytes());
        assert_eq!(list_b, list.to_bytes());
        assert_eq!(creds_b, vec![cred.to_bytes()]);
        assert!(trailer.is_empty(), "a bare (no-capability) roster has an empty trailer");

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

    /// Seed-drop S1 receive verifier, end-to-end over the FFI: a contact's AUTHORIZED device signs an
    /// event on the account's behalf (sender = device, author = account) and the peer ACCEPTS it by
    /// chaining the device→account credential through the verified roster; an event signed by a device
    /// with no valid credential is NOT accepted. (No device *authors* under its device key in this
    /// release — the test crafts device-signed content to prove the verifier that must ship first.)
    #[test]
    fn receive_verifier_accepts_device_signed_event_rejects_uncredentialed() {
        use haven_p2p::device::{DeviceCredential, DeviceList};
        let cid = DEFAULT_CIRCLE.to_string();
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = Identity::from_seed(&[2u8; 32]); // a contact account
        let bob_dev = Identity::from_seed(&[77u8; 32]); // an authorized device of Bob
        let rogue = Identity::from_seed(&[88u8; 32]); // a device with NO credential in Bob's roster

        // Alice knows Bob, and learns Bob's roster: his account + his authorized device.
        alice.add_contact_bundle(cid.clone(), bob.public().to_bytes()).unwrap();
        let list = DeviceList::signed(
            &bob, 1, 0,
            vec![bob.public().node_id_bytes(), bob_dev.public().node_id_bytes()],
            vec![],
        );
        let creds = vec![
            DeviceCredential::issue(&bob, &bob.public(), "bob-primary", 0).to_bytes(),
            DeviceCredential::issue(&bob, &bob_dev.public(), "bob-mac", 1).to_bytes(),
        ];
        assert!(alice.ingest_device_roster(bob.public().to_bytes(), list.to_bytes(), creds));

        // Bob's key commit teaches Alice the epoch key (commits stay account-signed this release). Sealed to
        // Alice's account; committer is Bob (a circle member), so Alice opens it and stores it under Bob's account.
        let epoch = 0u64;
        let key = new_epoch_key();
        let secret = new_circle_secret();
        let alice_pub = Identity::from_seed(&[1u8; 32]).public();
        let commit = seal_key_commit(&bob, &[alice_pub], &cid, epoch, &key, &secret).unwrap();
        assert!(alice.receive(cid.clone(), tagged(TAG_KEY_COMMIT, &commit.to_bytes())).unwrap());

        // ACCEPT: a device-signed event whose author is Bob's account and whose signer is Bob's credentialed device.
        let ev = Event::new(&bob.public().node_id_bytes(), 100, EventKind::Message { body: "from bob's mac".into() });
        let env = seal_event_in_epoch(&bob_dev, &cid, epoch, &key, &ev).unwrap();
        assert!(alice.receive(cid.clone(), tagged(TAG_EPOCH_EVENT, &env.to_bytes())).unwrap(),
                "device-signed event, credentialed to a member, is accepted");
        assert!(alice.feed(cid.clone(), 200, None).iter().any(|m| m.body == "from bob's mac"));

        // REJECT: same author claim, but signed by a device with no valid account credential.
        let ev2 = Event::new(&bob.public().node_id_bytes(), 101, EventKind::Message { body: "forged".into() });
        let env2 = seal_event_in_epoch(&rogue, &cid, epoch, &key, &ev2).unwrap();
        assert!(!alice.receive(cid.clone(), tagged(TAG_EPOCH_EVENT, &env2.to_bytes())).unwrap(),
                "an uncredentialed signer is not accepted");
        assert!(alice.feed(cid.clone(), 200, None).iter().all(|m| m.body != "forged"));
    }

    /// Envelope sender hexes of the epoch EVENTS in an outgoing sync bundle (tag 0x02).
    fn epoch_event_senders(bundle: &[Vec<u8>]) -> Vec<String> {
        bundle
            .iter()
            .filter(|e| e.first() == Some(&TAG_EPOCH_EVENT))
            .filter_map(|e| EpochEnvelope::from_bytes(&e[1..]).ok())
            .map(|env| env.sender_hex())
            .collect()
    }
    /// Envelope sender hexes of the KEY COMMITS in an outgoing sync bundle (tag 0x03).
    fn key_commit_senders(bundle: &[Vec<u8>]) -> Vec<String> {
        bundle
            .iter()
            .filter(|e| e.first() == Some(&TAG_KEY_COMMIT))
            .filter_map(|e| SealedEnvelope::from_bytes(&e[1..]).ok())
            .map(|env| env.sender_hex())
            .collect()
    }
    /// Sign a v1 roster {account, device} for `seed`'s account and install it locally; returns the wire +
    /// creds so a peer can ingest the same. `dev_seed` is the adopted device key's seed.
    fn install_two_device_roster(
        s: &HavenSocial,
        seed: [u8; 32],
        dev_seed: [u8; 32],
    ) -> (Vec<u8>, Vec<Vec<u8>>) {
        let acct_id = Identity::from_seed(&seed).public().node_id_bytes().to_vec();
        let dev_id = Identity::from_seed(&dev_seed).public().node_id_bytes().to_vec();
        let acct_cred =
            crate::multidevice::issue_device_credential(seed.to_vec(), s.my_bundle(), "primary".into(), 0).unwrap();
        let dev_cred =
            crate::multidevice::issue_device_credential(seed.to_vec(), s.my_device_bundle(), "device".into(), 1).unwrap();
        let list = crate::multidevice::sign_device_list(seed.to_vec(), 1, 0, vec![acct_id, dev_id], vec![]).unwrap();
        let creds = vec![acct_cred, dev_cred];
        assert!(s.set_my_device_roster(list.clone(), creds.clone()));
        (list, creds)
    }

    /// Seed-drop S3 (SEND side), end-to-end over the FFI: once a device key is adopted, this client SIGNS
    /// its own posts AND key commits under the DEVICE key (envelope sender = device), while the event's
    /// author still binds to the ACCOUNT. A contact resolves device→account via the verified roster (S1) and
    /// attributes the opened post to the account. This is the authoring switch S1 was shipped ahead of.
    #[test]
    fn seed_drop_s3_signs_under_device_key_contact_attributes_to_account() {
        let cid = DEFAULT_CIRCLE.to_string();
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        let bob_acct_hex = hex(&Identity::from_seed(&[2u8; 32]).public().node_id_bytes());

        // BOTH adopt device keys + exchange rosters and capability markers, so Bob's circle computes as fully
        // seed-drop-capable — the precondition for device-key authoring (a partly-legacy circle stays on
        // account signing so no peer is stranded). Capability rides the roster wire, so it's delivered by a
        // sync, not by direct ingest.
        assert!(alice.use_device_identity([98u8; 32].to_vec()));
        assert!(bob.use_device_identity([99u8; 32].to_vec()));
        let bob_dev_hex = bob.my_device_node_hex();
        assert_ne!(bob_dev_hex, bob_acct_hex, "device transport id differs from the account id");
        let (al_list, al_creds) = install_two_device_roster(&alice, [1u8; 32], [98u8; 32]);
        let (bo_list, bo_creds) = install_two_device_roster(&bob, [2u8; 32], [99u8; 32]);
        assert!(alice.ingest_device_roster(bob.my_bundle(), bo_list, bo_creds));
        assert!(bob.ingest_device_roster(alice.my_bundle(), al_list, al_creds));
        sync(&alice, &bob, &cid); // Alice's capability marker → Bob (his circle is now fully capable)

        // Bob posts. His OUTGOING bundle is signed under the DEVICE key: both the epoch event and the key
        // commit carry sender = Bob's device id, never his account id. (Pre-S3 these were account-signed.)
        bob.post(cid.clone(), "hello from bob's mac".into(), vec![], None, None, false, false, 1_000).unwrap();
        let bundle = bob.sync_envelopes(cid.clone());
        let ev_senders = epoch_event_senders(&bundle);
        let commit_senders = key_commit_senders(&bundle);
        assert!(!ev_senders.is_empty(), "bundle carries the posted event");
        assert!(ev_senders.iter().all(|s| *s == bob_dev_hex),
                "S3: events are signed under the DEVICE key, not the account key");
        assert!(!commit_senders.is_empty() && commit_senders.iter().all(|s| *s == bob_dev_hex),
                "S3: the key commit is also signed under the DEVICE key");

        // Alice opens the device-signed post and attributes it to Bob's ACCOUNT (author binds to account).
        sync(&bob, &alice, &cid);
        let feed = alice.feed(cid.clone(), 2_000, None);
        let post = feed.iter().find(|m| m.body == "hello from bob's mac").expect("alice opens the device-signed post");
        assert_eq!(post.author_short, short(&bob_acct_hex), "authorship binds to the ACCOUNT…");
        assert_ne!(post.author_short, short(&bob_dev_hex), "…not to the signing device");
    }

    /// Seed-drop S5 GATE, end-to-end: with retirement OFF (the shipping default) a circle keeps today's
    /// dual-seal, so an opener holding ONLY the account key still reads. Flip retirement ON in a
    /// fully-capable circle and the bare account key is dropped — the same account-only opener is cut off,
    /// while the device opens fine. This is the switch that makes a revoked device's account seed useless.
    #[test]
    fn seed_drop_s5_gate_drops_account_key_only_when_retire_on_and_fully_capable() {
        let cid = DEFAULT_CIRCLE.to_string();
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap(); // Bob's DEVICE (adopts a device key)
        // Two FRESH account-only witnesses (same account as Bob, NO device key), one per era. Fresh matters:
        // the gate governs who can OBTAIN an epoch key, so a witness that already learned the key under
        // dual-seal would keep opening the same epoch — the cut-off only bites a witness that never held it.
        let acct_off = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let acct_on = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        acct_off.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        acct_on.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Both real participants adopt device keys + rosters so the circle can compute as fully capable.
        assert!(alice.use_device_identity([98u8; 32].to_vec()));
        assert!(bob.use_device_identity([99u8; 32].to_vec()));
        let (al_list, al_creds) = install_two_device_roster(&alice, [1u8; 32], [98u8; 32]);
        // Bob's FULLY-UPGRADED roster authorizes ONLY his device bundle, NOT his bare account id: in a
        // retired circle the account is the pinned contact id + roster signer, never a content recipient.
        // That is what lets the gate's drop path (which seals to authorized bundles) exclude a seed-only
        // holder — while a roster still listing the account would keep sealing to it.
        let bob_dev_id = Identity::from_seed(&[99u8; 32]).public().node_id_bytes().to_vec();
        let bob_dev_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), bob.my_device_bundle(), "device".into(), 1).unwrap();
        let bo_list = crate::multidevice::sign_device_list([2u8; 32].to_vec(), 1, 0, vec![bob_dev_id], vec![]).unwrap();
        let bo_creds = vec![bob_dev_cred];
        assert!(bob.set_my_device_roster(bo_list.clone(), bo_creds.clone()));
        assert!(bob.ingest_device_roster(alice.my_bundle(), al_list, al_creds));
        assert!(alice.ingest_device_roster(bob.my_bundle(), bo_list, bo_creds));
        // Deliver Bob's roster to Alice via SYNC so the capability trailer rides along and Alice marks Bob
        // seed-drop-capable (the gate's all-present-positive input); direct ingest carries no trailer.
        sync(&bob, &alice, &cid); // carries Bob's roster-wire trailer → alice.seed_drop_capable += bob

        // (1) Retirement OFF (default): dual-seal. A fresh account-only witness obtains the key and reads.
        alice.set_seed_drop_retire(false);
        alice.post(cid.clone(), "dual-seal era".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&alice, &acct_off, &cid);
        assert!(acct_off.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "dual-seal era"),
                "with the gate OFF, the account key still opens content (backwards compatible)");

        // (2) Retirement ON + fully capable: the bare account key is dropped, so the fresh account-only
        //     witness never obtains the epoch key and is cut off; the authorized DEVICE still reads. This is
        //     the cryptographic retirement of the account seal — a revoked device's seed becomes useless.
        alice.set_seed_drop_retire(true);
        alice.post(cid.clone(), "device-only era".into(), vec![], None, None, false, false, 3_000).unwrap();
        sync(&alice, &acct_on, &cid); // fresh witness only ever sees the device-only commit
        sync(&alice, &bob, &cid);
        assert!(acct_on.feed(cid.clone(), 4_000, None).iter().all(|m| m.body != "device-only era"),
                "gate ON in a fully-capable circle: an account-only key can no longer obtain the epoch key");
        assert!(bob.feed(cid.clone(), 4_000, None).iter().any(|m| m.body == "device-only era"),
                "the authorized DEVICE still opens it");
    }

    /// Trap-B guard (own-device convergence under device-key commits): two of Bob's devices each author AND
    /// commit under their OWN device key. Each must resolve the other's device→Bob's account and converge
    /// the epoch key into its own-device slot — otherwise a sibling's device-committed key lands in a peer
    /// slot the read path never consults, and sibling content buffers forever.
    #[test]
    fn seed_drop_own_device_content_converges_under_device_key_commits() {
        let cid = DEFAULT_CIRCLE.to_string();
        let mac = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let phone = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        assert!(mac.use_device_identity([99u8; 32].to_vec()));
        assert!(phone.use_device_identity([88u8; 32].to_vec()));

        // Both install the SAME roster listing Bob's account + BOTH devices, so each resolves the sibling
        // device to Bob's account locally (no exchange needed — identical own roster).
        let acct_id = Identity::from_seed(&[2u8; 32]).public().node_id_bytes().to_vec();
        let mac_id = Identity::from_seed(&[99u8; 32]).public().node_id_bytes().to_vec();
        let phone_id = Identity::from_seed(&[88u8; 32]).public().node_id_bytes().to_vec();
        let mac_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), mac.my_device_bundle(), "mac".into(), 1).unwrap();
        let phone_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), phone.my_device_bundle(), "phone".into(), 2).unwrap();
        let acct_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), mac.my_bundle(), "primary".into(), 0).unwrap();
        let list = crate::multidevice::sign_device_list([2u8; 32].to_vec(), 1, 0, vec![acct_id, mac_id, phone_id], vec![]).unwrap();
        let creds = vec![acct_cred, mac_cred, phone_cred];
        assert!(mac.set_my_device_roster(list.clone(), creds.clone()));
        assert!(phone.set_my_device_roster(list, creds));

        // Each posts under its OWN device key. Storing a roster rotates the epoch (verify_and_store_roster),
        // so both minted independent epoch keys and must converge on the numerically-larger one; convergence
        // takes a few bidirectional rounds (each device re-seals its events under the agreed key on its next
        // bundle) — exactly the own-device sync production runs continuously. Trap-B is what makes this
        // converge AT ALL: a sibling's device-signed commit must land in the own-device key slot, not a peer
        // slot the read path never consults — if it didn't, no number of rounds would ever open the content.
        mac.post(cid.clone(), "from the mac".into(), vec![], None, None, false, false, 1_000).unwrap();
        phone.post(cid.clone(), "from the phone".into(), vec![], None, None, false, false, 3_000).unwrap();
        for _ in 0..4 {
            sync(&mac, &phone, &cid);
            sync(&phone, &mac, &cid);
        }

        let pf = phone.feed(cid.clone(), 5_000, None);
        let mf = mac.feed(cid.clone(), 5_000, None);
        let seen = pf.iter().find(|m| m.body == "from the mac").expect("phone opens the mac's device-signed post");
        assert!(seen.is_me, "own-account content reads as mine on the sibling device");
        assert!(pf.iter().any(|m| m.body == "from the phone"), "phone sees its own post");
        assert!(mf.iter().any(|m| m.body == "from the mac"), "mac opens the phone→converged content");
        assert!(mf.iter().any(|m| m.body == "from the phone"), "mac sees its own post — siblings converge");
    }

    /// A pre-seed-drop (legacy) peer is unaffected by the new capability marker: the profile/roster still
    /// carry the same fields, posts still flow (the dual-seal account-key path is untouched — the gate is
    /// OFF), and a forged/absent marker reads as legacy (0), never as a downgrade.
    #[test]
    fn legacy_peer_unaffected_by_seed_drop_marker() {
        let cid = DEFAULT_CIRCLE.to_string();
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        // Profile: same name reads back (additive), the signed marker is observed as v1, a forged marker is 0.
        let prof = alice.my_signed_profile("Alice".into(), "bio".into(), "".into(), "".into(), "".into());
        assert_eq!(bob.verify_profile(alice.my_bundle(), prof.clone()).as_deref(), Some("Alice"));
        assert_eq!(bob.profile_seed_drop_version(alice.my_bundle(), prof.clone()), 1, "signed marker is observed");
        let mut forged = prof.clone();
        let l = forged.len() - 1;
        forged[l] ^= 0xff;
        assert_eq!(bob.profile_seed_drop_version(alice.my_bundle(), forged), 0,
                   "a forged marker is ignored (absence-safe, never a downgrade)");

        // Zero behavior change: posts still flow (the account-key seal is intact, gate OFF).
        alice.post(cid.clone(), "hello".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&alice, &bob, &cid);
        assert!(bob.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "hello"),
                "a peer that never acts on the marker still receives everything");

        // Roster wire is additive: it carries the signed capability trailer, yet the roster fields decode
        // unchanged and the peer still ingests it.
        assert!(!alice.register_device(alice.my_bundle(), "alice-primary".into(), 0).is_empty());
        let wire = alice.my_device_roster_wire();
        assert_eq!(wire.first(), Some(&TAG_DEVICE_ROSTER));
        let (_a, _list, _creds, trailer) = decode_roster(&wire[1..]).expect("new roster decodes");
        assert!(!trailer.is_empty(), "a seed-drop build's roster carries the signed capability trailer");
        assert!(bob.ingest_roster_wire(wire), "peer ingests the roster despite the trailer (additive)");
    }

    /// TreeKEM M0: the `ml` capability marker rides the SAME signed profile as `sd` and is just as
    /// additive — a profile carrying BOTH markers verifies and the feed still flows, a forged profile
    /// marks nothing, and a legacy (marker-less) card still parses with nothing learned (absence is
    /// never a downgrade). Mirrors `legacy_peer_unaffected_by_seed_drop_marker`.
    #[test]
    fn legacy_peer_unaffected_by_mls_marker() {
        let cid = DEFAULT_CIRCLE.to_string();
        let alice = HavenSocial::new([81u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([82u8; 32].to_vec()).unwrap();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        let alice_id = HavenId::from_bytes(&alice.my_bundle()).unwrap().node_id_bytes();

        // Self-seeding: this build advertises `ml`, so my own account counts as capable from birth
        // (a circle containing me could otherwise never compute as fully MLS-capable).
        assert!(alice.state.lock().unwrap().mls_capable.contains(&alice_id));
        assert!(!bob.state.lock().unwrap().mls_capable.contains(&alice_id), "peers start unknown");

        // The signed card carries BOTH markers inside the one account-signed payload (round-trip:
        // what `my_signed_profile` embeds is what a verifier reads back).
        let prof = alice.my_signed_profile("Alice".into(), "bio".into(), "".into(), "".into(), "".into());
        let sig_len = u32::from_le_bytes(prof[..4].try_into().unwrap()) as usize;
        let card: serde_json::Value = serde_json::from_slice(&prof[4 + sig_len..]).unwrap();
        assert_eq!(card.get("ml").and_then(|x| x.as_u64()), Some(1), "`ml` rides the signed payload");
        assert_eq!(card.get("sd").and_then(|x| x.as_u64()), Some(1), "`sd` still rides beside it");

        // FORGED/tampered first: a flipped byte fails signature verification, so NOTHING is learned —
        // the marker only counts when the profile signature verifies.
        let mut forged = prof.clone();
        let l = forged.len() - 1;
        forged[l] ^= 0xff;
        assert_eq!(bob.profile_seed_drop_version(alice.my_bundle(), forged), 0);
        assert!(!bob.state.lock().unwrap().mls_capable.contains(&alice_id),
                "a forged profile must not mark the account mls-capable");

        // The genuine both-marker profile: existing callers see the same card and the same `sd`
        // version as before (zero behavior change), and the account is now learned mls-capable.
        assert_eq!(bob.verify_profile(alice.my_bundle(), prof.clone()).as_deref(), Some("Alice"),
                   "a profile carrying `ml` still parses on the current parser");
        assert_eq!(bob.profile_seed_drop_version(alice.my_bundle(), prof.clone()), 1,
                   "the returned `sd` version is untouched by the new marker");
        assert!(bob.state.lock().unwrap().mls_capable.contains(&alice_id));
        assert!(bob.state.lock().unwrap().seed_drop_capable.contains(&alice_id));

        // LEGACY-shaped card (an older build: no `sd`, no `ml`) — signed by the real account key. It
        // still parses, and a fresh observer learns NO capability from it: absence is never information.
        let legacy_payload = serde_json::json!({ "n": "OldAlice", "b": "", "l": "" }).to_string();
        let legacy_sig = alice.state.lock().unwrap().me_secret.as_ref().unwrap().sign(&profile_signing_bytes(legacy_payload.as_bytes()));
        let mut legacy = (legacy_sig.len() as u32).to_le_bytes().to_vec();
        legacy.extend_from_slice(&legacy_sig);
        legacy.extend_from_slice(legacy_payload.as_bytes());
        let carol = HavenSocial::new([83u8; 32].to_vec()).unwrap();
        assert_eq!(carol.verify_profile(alice.my_bundle(), legacy.clone()).as_deref(), Some("OldAlice"),
                   "a legacy-shaped profile still parses");
        assert_eq!(carol.profile_seed_drop_version(alice.my_bundle(), legacy), 0);
        assert!(!carol.state.lock().unwrap().mls_capable.contains(&alice_id),
                "an absent marker is legacy, never a downgrade — and never an upgrade either");

        // Zero behavior change end-to-end: after the both-marker profile was ingested, posts still flow.
        alice.post(cid.clone(), "hello-ml".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&alice, &bob, &cid);
        assert!(bob.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "hello-ml"),
                "a peer that ingested a profile carrying both markers still receives everything");
    }

    /// Wall clock in unix millis. The purge tests must use REAL timestamps: the automatic
    /// sender-expiry sweep in `epoch_sync_bundle_inner` runs against the wall clock, so a post
    /// stamped 1970 with a retention would be swept before the test ever exercised the interesting
    /// path.
    fn wall_ms() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
    }

    /// Sealed EVENTS in a bundle (excludes the roster + key-commit envelopes that ride along).
    fn epoch_event_count(envs: &[Vec<u8>]) -> usize {
        envs.iter().filter(|e| e.first() == Some(&TAG_EPOCH_EVENT)).count()
    }

    #[test]
    fn sender_retention_purges_the_post_its_orphans_and_the_bundles() {
        // Bundle building auto-purges against the GLOBAL test clock, and this test keeps a live
        // 10s retention across several bundle builds — hold the skew lock (zero skew) so a
        // parallel clock-advancing test can't expire the post mid-setup.
        with_clock_advanced(0, || {
        let alice = HavenSocial::new([60u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([61u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        let now = wall_ms();
        // "vanishes" carries a 10s sender expiry + a media ref; "stays" has no retention (control).
        alice.post(cid.clone(), "vanishes".into(), vec!["ref-a".into()], None, Some(10), false, false, now).unwrap();
        alice.post(cid.clone(), "stays".into(), vec![], None, None, false, false, now + 1).unwrap();
        sync(&alice, &bob, &cid);

        // A different member replies on the expiring post — these must go transitively with it.
        let post_id = bob.feed(cid.clone(), now + 100, None).iter().find(|m| m.body == "vanishes").unwrap().id.clone();
        bob.comment(cid.clone(), post_id.clone(), "cute!".into(), vec!["ref-c".into()], now + 100).unwrap();
        bob.react(cid.clone(), post_id.clone(), "❤️".into(), now + 200).unwrap();
        sync(&bob, &alice, &cid);

        let feed = alice.feed(cid.clone(), now + 500, None);
        assert_eq!(feed.len(), 2);
        let item = feed.iter().find(|m| m.body == "vanishes").unwrap();
        assert_eq!(item.comments.len(), 1);
        assert_eq!(item.reactions.len(), 1);

        // The raw log ships 4 events (2 posts + comment + reaction) before the purge, and the
        // mine-only sync bundle ships alice's 2.
        assert_eq!(epoch_event_count(&alice.export_recent_envelopes(cid.clone(), 0)), 4);
        assert_eq!(epoch_event_count(&alice.sync_envelopes(cid.clone())), 2);

        // Past the sender expiry: the post, its comment, AND its reaction leave the log; the media
        // refs of everything purged (the post's and the comment's) come back for blob GC.
        let refs = alice.purge_expired(cid.clone(), None, now + 11_000);
        assert_eq!(refs, vec!["ref-a".to_string(), "ref-c".to_string()]);
        assert_eq!(epoch_event_count(&alice.export_recent_envelopes(cid.clone(), 0)), 1, "only 'stays' still ships");
        assert_eq!(epoch_event_count(&alice.sync_envelopes(cid.clone())), 1, "expired content no longer rides sync bundles");
        let after = alice.feed(cid.clone(), now + 11_000, None);
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].body, "stays");
        });
    }

    #[test]
    fn bundles_auto_drop_sender_expired_content_after_the_reseal_grace() {
        let alice = HavenSocial::new([62u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        let now = wall_ms();
        let grace_ms: u64 = 48 * 60 * 60 * 1000;
        // Three posts: one lapsed but INSIDE the 48h re-seal grace, one lapsed well OUTSIDE it, and a
        // fresh control.
        alice.post(cid.clone(), "just lapsed".into(), vec![], None, Some(10), false, false, now - 60_000).unwrap();
        alice.post(cid.clone(), "long gone".into(), vec![], None, Some(10), false, false, now - grace_ms - 60_000).unwrap();
        alice.post(cid.clone(), "fresh".into(), vec![], None, None, false, false, now).unwrap();

        // The app never calls purge_expired — building a bundle alone must do the purging. Only the
        // post past the GRACE leaves: the 48h window is what lets a receiver that stalled (commit lag,
        // offline) still reconcile a story from history instead of losing it the instant it lapsed.
        assert_eq!(
            epoch_event_count(&alice.sync_envelopes(cid.clone())), 2,
            "a just-lapsed post stays exportable through the 48h re-seal grace"
        );
        assert_eq!(
            epoch_event_count(&alice.export_recent_envelopes(cid.clone(), 0)), 2,
            "the post past the grace was removed from the log, not just filtered"
        );

        // The promise the VIEWER sees is unchanged: display hides expired content at the exact
        // deadline, grace or no grace. That separation is the whole point — the bytes linger only so
        // late receivers can reconcile; nobody is shown them.
        let feed = alice.feed(cid.clone(), now, None);
        assert_eq!(feed.len(), 1, "only the un-expired post is displayed");
        assert_eq!(feed[0].body, "fresh");
    }

    #[test]
    fn circle_retention_purge_honors_keep_own_posts_and_returns_media_refs() {
        let alice = HavenSocial::new([63u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([64u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        let now = wall_ms();
        // Both posts are 100s old with no sender retention; the circle's auto-delete is 50s.
        bob.post(cid.clone(), "friend's old".into(), vec!["ref-b".into()], None, None, false, false, now - 100_000).unwrap();
        sync(&bob, &alice, &cid);
        alice.post(cid.clone(), "my archive".into(), vec![], None, None, false, false, now - 100_000).unwrap();

        // keep-my-posts ON: the friend's stale post purges (media ref returned), mine survives.
        alice.set_keep_own_posts(true);
        let refs = alice.purge_expired(cid.clone(), Some(50), now);
        assert_eq!(refs, vec!["ref-b".to_string()]);
        // Read back with NO viewer filter — proves the friend's post is gone from the log while
        // mine is genuinely retained, not merely displayed.
        let feed = alice.feed(cid.clone(), now, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].body, "my archive");

        // keep-my-posts OFF: the circle retention now takes my own post too.
        alice.set_keep_own_posts(false);
        let refs = alice.purge_expired(cid.clone(), Some(50), now);
        assert!(refs.is_empty(), "my post carried no media");
        assert!(alice.feed(cid.clone(), now, None).is_empty());
    }

    #[test]
    fn dm_messages_purge_under_circle_retention() {
        let alice = HavenSocial::new([65u8; 32].to_vec()).unwrap();
        let cid = "dm-test".to_string();
        alice.create_circle(cid.clone(), "DM".into());
        let now = wall_ms();
        alice.author(&cid, now - 100_000, EventKind::Message { body: "stale dm".into() }).unwrap();
        alice.author(&cid, now, EventKind::Message { body: "fresh dm".into() }).unwrap();
        assert_eq!(alice.feed(cid.clone(), now, None).len(), 2);

        // keep-my-posts must NOT shield a Message — same as the feed, the exemption is Posts-only.
        alice.set_keep_own_posts(true);
        alice.purge_expired(cid.clone(), Some(50), now);
        let feed = alice.feed(cid.clone(), now, None);
        assert_eq!(feed.len(), 1, "the stale DM is really deleted, not display-hidden");
        assert_eq!(feed[0].body, "fresh dm");
    }

    #[test]
    fn purged_event_redelivery_does_not_resurrect_it() {
        // Same live-retention-across-bundles shape as the sender-retention test: hold the skew
        // lock so a parallel clock jump can't purge the post before it's delivered.
        with_clock_advanced(0, || {
        let alice = HavenSocial::new([66u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([67u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();

        let now = wall_ms();
        let env = alice.post(cid.clone(), "ephemeral".into(), vec![], None, Some(10), false, false, now).unwrap();
        sync(&alice, &bob, &cid);
        assert_eq!(epoch_event_count(&bob.export_recent_envelopes(cid.clone(), 0)), 1);

        bob.purge_expired(cid.clone(), None, now + 11_000);
        assert_eq!(epoch_event_count(&bob.export_recent_envelopes(cid.clone(), 0)), 0, "receiver purged it too");

        // A relay/mailbox re-delivering the identical sealed event must hit the intact seen-set.
        assert!(!bob.receive(cid.clone(), env).unwrap(), "re-delivery is deduped, not resurrected");
        assert_eq!(epoch_event_count(&bob.export_recent_envelopes(cid.clone(), 0)), 0);
        });
    }

    // ── Seed-drop S4.3: seedless enrollment integration (FFI) ──────────────────────────────────
    //
    // The FFI sibling of the core proof `device.rs::s4_seedless_new_device_is_credentialed_but_cannot_
    // forge_a_roster`: drive the whole enroll handshake through the exposed wires, stand up a real seedless
    // `HavenSocial`, and prove it authors readable, ACCOUNT-attributed content in a fully-capable circle
    // while holding no account key.

    /// The GRANT half of enrollment, entirely over the enroll FFI: mint ticket → build/verify request →
    /// primary unions the device into Alice's roster + assembles the grant → seedless opens + installs it.
    /// Returns `(primary, seedless, primary_signed_roster_wire, granted_self_sync_key)`.
    fn grant_seedless(dev_seed: [u8; 32]) -> (Arc<HavenSocial>, Arc<HavenSocial>, Vec<u8>, Vec<u8>) {
        let primary = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let account_bundle = primary.my_bundle();
        let seedless = HavenSocial::new_seedless(account_bundle.clone(), dev_seed.to_vec()).unwrap();
        assert!(seedless.is_seedless() && !primary.is_seedless());
        // (1) Ticket minted by the primary.
        let primary_dev = Identity::from_seed(&[1u8; 32]).public().node_id_bytes().to_vec();
        let ticket = crate::enroll::enroll_issue_ticket(
            account_bundle, primary_dev, 1_000, vec!["https://relay.example".into()],
        ).unwrap();
        // (2) Request built by the seedless device, verified by the primary (MAC + freshness).
        let req_wire = crate::enroll::enroll_build_request(
            ticket.secret.clone(), seedless.my_device_bundle(), "Blaine's iPad".into(), 1_000,
        ).unwrap();
        let req = crate::enroll::enroll_verify_request(ticket.secret.clone(), req_wire, 1_000, 600).unwrap();
        assert_eq!(req.device_bundle, seedless.my_device_bundle());
        // (3) Primary unions the device into Alice's roster (issuing its credential + rotating epochs) and
        //     assembles the grant — credential + verbatim roster wire + sealed self-sync grant, all MAC'd.
        let alice_roster_wire = primary.register_device(req.device_bundle.clone(), req.name.clone(), 1);
        assert!(!alice_roster_wire.is_empty(), "primary emits its signed roster wire");
        let grant_wire = crate::enroll::enroll_assemble_grant(
            [1u8; 32].to_vec(), ticket.secret.clone(), req.device_bundle, "Blaine's iPad".into(), 1,
            alice_roster_wire, vec!["https://relay.example".into()],
        ).unwrap();
        // The seedless device accepts ONLY after all four checks pass; installs its verbatim roster wire.
        let grant = crate::enroll::enroll_open_grant(dev_seed.to_vec(), ticket, grant_wire).unwrap();
        assert_eq!(grant.self_sync_key.len(), 32, "a 32-byte self-sync key is granted");
        assert_eq!(grant.roster_wire.first(), Some(&TAG_DEVICE_ROSTER), "roster wire is the tagged form");
        assert!(seedless.ingest_roster_wire(grant.roster_wire.clone()), "seedless installs its own roster");
        (primary, seedless, grant.roster_wire, grant.self_sync_key)
    }

    /// Full enrollment: the grant, plus a contact (Bob) with a capable roster, returning
    /// `(primary, seedless, bob, cid, granted_self_sync_key)` with the seedless device's default circle
    /// FULLY seed-drop-capable (its S4 authoring precondition).
    fn enroll_seedless() -> (Arc<HavenSocial>, Arc<HavenSocial>, Arc<HavenSocial>, String, Vec<u8>) {
        let cid = DEFAULT_CIRCLE.to_string();
        let (primary, seedless, roster_wire, key) = grant_seedless([98u8; 32]);
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();

        // ── Wire the circle so the seedless device's circle computes as FULLY capable ──
        // Bob adopts a device + registers, and both sides learn each other's rosters (carrying the signed
        // capability trailer). Alice's account is self-seeded capable in `new_seedless`.
        seedless.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), primary.my_bundle()).unwrap(); // Bob knows Alice's ACCOUNT
        assert!(bob.use_device_identity([99u8; 32].to_vec()));
        let bob_roster_wire = bob.register_device(bob.my_device_bundle(), "Bob's phone".into(), 0);
        // Seedless learns Bob's roster + capability (trailer); Bob learns Alice's roster (to attribute the
        // seedless device's device-signed content back to Alice's account).
        assert!(seedless.ingest_roster_wire(bob_roster_wire), "seedless learns Bob's roster + capability");
        assert!(bob.ingest_roster_wire(roster_wire), "Bob learns Alice's roster");
        (primary, seedless, bob, cid, key)
    }

    /// S4 headline (FFI): a seedless device authors in a fully-capable circle; a contact reads it and
    /// attributes it to the ACCOUNT; the seedless device's `register_device` returns empty (A1); and a
    /// forged roster for the account is rejected by the contact.
    #[test]
    fn s4_ffi_seedless_enrollment_end_to_end() {
        let (primary, seedless, bob, cid, _key) = enroll_seedless();

        // A1: a seedless device NEVER mints/re-signs a roster — the primary is the sole authority.
        assert!(seedless.register_device(seedless.my_device_bundle(), "iPad".into(), 5).is_empty(),
                "register_device returns empty on a seedless device");

        // The seedless device authors (device-signed, since its circle is fully capable) and Bob reads it,
        // ATTRIBUTED to Alice's account — the seedless device holds no account key, yet its post is the
        // account's post.
        let env = seedless.post(cid.clone(), "hi from the seedless iPad".into(), vec![], None, None, false, false, 2_000)
            .expect("seedless authors in a fully-capable circle");
        assert!(env.first() == Some(&TAG_EPOCH_EVENT));
        sync(&seedless, &bob, &cid);
        let feed = bob.feed(cid.clone(), 3_000, None);
        let item = feed.iter().find(|m| m.body == "hi from the seedless iPad")
            .expect("contact reads the seedless device's post");
        assert!(!item.is_me, "the post is Alice's, read by Bob");
        assert_eq!(item.author_short, short(&primary.my_node_hex()),
                   "attributed to the ACCOUNT, not the seedless device's transport id");

        // A forged roster — signed by an IMPOSTER, presented as Alice's — cannot move Alice's roster
        // forward on the contact (verification is anchored to Alice's pinned account bundle).
        let imposter = Identity::from_seed(&[66u8; 32]);
        let forged = DeviceList::signed(&imposter, 99, 9, vec![Identity::from_seed(&[77u8; 32]).public().node_id_bytes()], vec![]);
        assert!(!bob.ingest_device_roster(primary.my_bundle(), forged.to_bytes(), vec![]),
                "a roster not signed by the account key is rejected");
    }

    /// F11 (FFI): the GRANTED self-sync key is exactly the account's seed-derived key, so a seedless
    /// device seals/opens the same account-state slots as the primary — self-sync converges without a seed.
    #[test]
    fn s4_ffi_seedless_self_sync_via_granted_key() {
        let (_primary, _seedless, _bob, _cid, granted_key) = enroll_seedless();

        // Primary seals account state from the SEED; the seedless device opens it with the GRANTED key.
        let on_primary = crate::multidevice::AccountStateHandle::new();
        on_primary.set("contact:xyz".into(), b"bob".to_vec(), 10, [98u8; 32].to_vec()).unwrap();
        let sealed_by_seed = crate::multidevice::seal_account_state([1u8; 32].to_vec(), on_primary).unwrap();
        let opened = crate::multidevice::open_account_state_with_key(granted_key.clone(), sealed_by_seed).unwrap();
        assert_eq!(opened.get("contact:xyz".into()), Some(b"bob".to_vec()),
                   "the granted key opens what the seed sealed — same key, so devices converge");

        // And the reverse: the seedless device seals with the granted key; the primary opens with the seed.
        let on_seedless = crate::multidevice::AccountStateHandle::new();
        on_seedless.set("pin:1".into(), b"post".to_vec(), 20, [98u8; 32].to_vec()).unwrap();
        let sealed_by_key = crate::multidevice::seal_account_state_with_key(granted_key, on_seedless).unwrap();
        let back = crate::multidevice::open_account_state([1u8; 32].to_vec(), sealed_by_key).unwrap();
        assert_eq!(back.get("pin:1".into()), Some(b"post".to_vec()),
                   "the primary opens what the seedless device sealed");
    }

    /// AUDIT M1 (FFI): ROTATING the self-sync key on revocation cuts a revoked device off the
    /// account-state channel — it can neither open the post-rotation state NOR have its stale-epoch write
    /// accepted — while a still-authorized device converges; and with the switch OFF the self-sync path
    /// is byte-identical to today (legacy v0, no epoch tag, opens with the seed).
    #[test]
    fn m1_ffi_rotation_cuts_revoked_device_from_self_sync() {
        use crate::multidevice::{
            mint_self_sync_key, open_account_state_dual, open_self_sync_key_epoch_grant,
            seal_account_state, seal_account_state_with_key_epoch, self_sync_key_should_rotate,
            seal_self_sync_key_epoch_grant, self_sync_key_epoch_of, AccountStateHandle,
        };
        // The gate mirrors retire_account_key EXACTLY: rotate only when the switch is ON and every own
        // device is seed-drop-capable; OFF or mixed ⇒ stay on v0 (byte-identical to today).
        assert!(!self_sync_key_should_rotate(false, true), "switch OFF ⇒ no rotation (byte-identical)");
        assert!(!self_sync_key_should_rotate(true, false), "a non-capable own device keeps v0");
        assert!(self_sync_key_should_rotate(true, true), "fully capable + switch ON ⇒ rotate");
        let acct_seed = [1u8; 32];
        let account_bundle = Identity::from_seed(&acct_seed).public().to_bytes();
        let stays_seed = [98u8; 32]; // a device that stays authorized
        let revoked_seed = [97u8; 32]; // a device that will be revoked
        let stays_bundle = Identity::from_seed(&stays_seed).public().to_bytes();
        let revoked_bundle = Identity::from_seed(&revoked_seed).public().to_bytes();
        let dev_id = |s: [u8; 32]| Identity::from_seed(&s).public().node_id_bytes().to_vec();

        // ── Epoch 1: the primary grants the current self-sync key to BOTH devices. ──
        let k1 = mint_self_sync_key();
        let g1_stays = seal_self_sync_key_epoch_grant(acct_seed.to_vec(), stays_bundle.clone(), 1, k1.clone()).unwrap();
        let g1_revoked = seal_self_sync_key_epoch_grant(acct_seed.to_vec(), revoked_bundle.clone(), 1, k1.clone()).unwrap();
        let held_stays = open_self_sync_key_epoch_grant(stays_seed.to_vec(), account_bundle.clone(), g1_stays).unwrap();
        let held_revoked = open_self_sync_key_epoch_grant(revoked_seed.to_vec(), account_bundle.clone(), g1_revoked).unwrap();
        assert_eq!((held_stays.epoch, &held_stays.key), (1, &k1));
        assert_eq!((held_revoked.epoch, &held_revoked.key), (1, &k1), "both devices hold the epoch-1 key");

        // ── Revocation: mint a fresh key at epoch 2, re-grant it ONLY to the still-authorized device. ──
        let k2 = mint_self_sync_key();
        let g2_stays = seal_self_sync_key_epoch_grant(acct_seed.to_vec(), stays_bundle.clone(), 2, k2.clone()).unwrap();
        let held_stays2 = open_self_sync_key_epoch_grant(stays_seed.to_vec(), account_bundle.clone(), g2_stays).unwrap();
        assert_eq!((held_stays2.epoch, &held_stays2.key), (2, &k2));
        // The revoked device is NOT a grant recipient — it keeps only k1.

        // The primary seals the CURRENT account state under the epoch-2 key (retirement ON ⇒ no v0 seal).
        let st = AccountStateHandle::new();
        st.set("circle:home".into(), b"home".to_vec(), 10, dev_id(stays_seed)).unwrap();
        let post_rotation = seal_account_state_with_key_epoch(k2.clone(), 2, st).unwrap();
        assert_eq!(self_sync_key_epoch_of(post_rotation.clone()), Some(2), "the blob is stamped epoch 2");

        // (a) The revoked device (k1 only, v0 retired ⇒ empty seed_key) CANNOT open the post-rotation state.
        assert!(
            open_account_state_dual(post_rotation.clone(), 1, k1.clone(), vec![]).is_err(),
            "a revoked device cannot open account state sealed under the post-rotation key"
        );
        // A still-authorized device (k2) opens it and converges.
        let opened = open_account_state_dual(post_rotation, 2, k2.clone(), vec![]).unwrap();
        assert_eq!(opened.get("circle:home".into()), Some(b"home".to_vec()));

        // (b) The revoked device seals a NEWER-stamped write under its STALE key k1…
        let hijack = AccountStateHandle::new();
        hijack.set("circle:home".into(), b"HIJACK".to_vec(), 9_999, dev_id(revoked_seed)).unwrap();
        let revoked_write = seal_account_state_with_key_epoch(k1.clone(), 1, hijack).unwrap();
        // …and an authorized device (accepts only epoch 2, v0 retired) REJECTS it.
        assert!(
            open_account_state_dual(revoked_write, 2, k2.clone(), vec![]).is_err(),
            "an authorized device rejects the revoked device's stale-epoch write — the channel is cut"
        );

        // ── Switch OFF ⇒ byte-identical to today: legacy v0 seal (no epoch tag), opens with the seed. ──
        let off = AccountStateHandle::new();
        off.set("profile".into(), b"me".to_vec(), 5, dev_id(stays_seed)).unwrap();
        let off_blob = seal_account_state(acct_seed.to_vec(), off).unwrap();
        assert_eq!(self_sync_key_epoch_of(off_blob.clone()), None, "OFF path is the untagged legacy v0 blob");
        let back = crate::multidevice::open_account_state(acct_seed.to_vec(), off_blob).unwrap();
        assert_eq!(back.get("profile".into()), Some(b"me".to_vec()), "OFF path round-trips unchanged");
    }

    /// C6 (FFI): a seedless device OPENS circle media sealed by a contact (Bob) — the media is sealed to
    /// the seedless device's bundle (the contact holds the account roster), and its device-signed sender
    /// resolves back to the account.
    #[test]
    fn s4_ffi_seedless_opens_circle_media_from_contact() {
        let (_primary, seedless, bob, cid, _key) = enroll_seedless();

        let sealed = bob.seal_circle_media(cid.clone(), b"a photo for the circle".to_vec())
            .expect("contact seals circle media");
        let opened = seedless.open_circle_media(cid.clone(), sealed)
            .expect("seedless device opens circle media sealed by a contact");
        assert_eq!(opened, b"a photo for the circle");
    }

    /// B4 gate (FFI): a seedless device has NO account key, so in a circle that is NOT fully
    /// seed-drop-capable it must REFUSE to author — a device-signed post there is unattributable by peers
    /// and there is no account fallback. We assert the REFUSE (over emitting into the void), because
    /// signing account-less content nobody can read is strictly worse than a surfaced precondition error.
    #[test]
    fn s4_ffi_seedless_refuses_to_author_when_circle_not_fully_capable() {
        let cid = DEFAULT_CIRCLE.to_string();
        let account_bundle = HavenSocial::new([1u8; 32].to_vec()).unwrap().my_bundle();
        let seedless = HavenSocial::new_seedless(account_bundle, [98u8; 32].to_vec()).unwrap();
        // A contact with NO known roster + no learned capability keeps the circle NOT fully capable.
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        seedless.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();

        let err = seedless.post(cid.clone(), "into the void".into(), vec![], None, None, false, false, 2_000);
        assert!(err.is_err(), "seedless must refuse to author in a not-fully-capable circle");
        assert!(seedless.feed(cid.clone(), 3_000, None).is_empty(), "and nothing is recorded locally");
    }

    /// §7 capability-trailer fidelity (A3): a seedless device rebroadcasts the primary-signed roster wire
    /// BYTE-FOR-BYTE — trailer intact — and it survives an `export_state`/`import_state` round-trip. If it
    /// re-encoded instead, the `SeedDropCapability` trailer would be stripped and the circle's capability
    /// convergence (and therefore S5 retirement) would stall.
    #[test]
    fn s4_ffi_seedless_rebroadcasts_roster_wire_verbatim() {
        let (_primary, seedless, primary_wire, _key) = grant_seedless([98u8; 32]);
        // The wire a seedless device emits everywhere (broadcast, sync bundle, self-sync) is the EXACT
        // primary-signed grant wire — never a re-mint.
        assert_eq!(seedless.my_device_roster_wire(), primary_wire, "rebroadcast is byte-identical");
        assert_eq!(seedless.export_own_roster()[0].wire, primary_wire, "own-roster export is byte-identical");

        // And it persists: a restarted seedless engine (new_seedless + import_state) still holds the exact
        // bytes — the verbatim wire rides `PersistState`, not a re-encode on load.
        let state = seedless.export_state();
        let account_bundle = HavenSocial::new([1u8; 32].to_vec()).unwrap().my_bundle();
        let restarted = HavenSocial::new_seedless(account_bundle, [98u8; 32].to_vec()).unwrap();
        restarted.import_state(state);
        assert_eq!(restarted.my_device_roster_wire(), primary_wire, "verbatim wire survives a restart");
    }

    /// §7 / risk: a seedless device's roster only ever moves FORWARD, and only via verified
    /// `adopt_if_newer` — there is NO self-re-sign path (the `Option<Identity>` on `me_secret` makes one a
    /// compile impossibility). Re-ingesting the same roster is a no-op; a stale (older-version) roster is
    /// rejected; a genuinely newer primary-signed roster is adopted.
    #[test]
    fn s4_ffi_seedless_roster_only_moves_forward() {
        let (primary, seedless, primary_wire, _key) = grant_seedless([98u8; 32]);
        // Re-ingesting the very same wire changes nothing (adopt_if_newer sees no higher version).
        // Assert on the STATUS: `ingest_roster_wire` is "not refused" (`>= 0`), so it is true here
        // by design — `0` (already current) must not read as failure (see
        // `ingest_roster_wire_status`). "Did not move forward" is exactly status 0.
        assert_eq!(seedless.ingest_roster_wire_status(primary_wire.clone()), 0,
                   "re-ingesting the same roster does not move forward");
        assert_eq!(seedless.my_device_roster_wire(), primary_wire, "and the held wire is unchanged");

        // A genuinely NEWER primary-signed roster (the primary registers a second device, bumping the
        // version) IS adopted — forward motion, driven only by the primary.
        let second_device = Identity::from_seed(&[97u8; 32]).public().to_bytes();
        let newer_wire = primary.register_device(second_device, "Alice's Mac".into(), 2);
        assert!(seedless.ingest_roster_wire(newer_wire.clone()), "a newer primary-signed roster is adopted");
        assert_eq!(seedless.my_device_roster_wire(), newer_wire, "and becomes the new verbatim wire");
        assert_ne!(newer_wire, primary_wire, "the newer roster really is different bytes");
    }

    // ── TreeKEM M2 SHADOW wiring (docs/TREEKEM-DESIGN.md §9 row M2) ───────────────────────────

    /// Empty five-field profile card for `s`, signed — carries `sd` + `ml`, so an observer that
    /// runs it through `profile_seed_drop_version` learns `s` is BOTH seed-drop- and MLS-capable.
    fn card(s: &HavenSocial, name: &str) -> Vec<u8> {
        s.my_signed_profile(name.into(), String::new(), String::new(), String::new(), String::new())
    }

    /// §9 M2 proof (a): a 3-account × 2-device fleet, every member MLS-capable. After arbitrary
    /// all-to-all sync/redelivery, `mls_shadow_status` reports converged=true with an EQUAL tree
    /// hash across every instance — the shadow tree agreed on the fleet, single-creator (no fork).
    #[test]
    fn mls_shadow_converges_across_fully_capable_three_account_fleet() {
        let cid = DEFAULT_CIRCLE.to_string();
        let a = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let b = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let c = HavenSocial::new([3u8; 32].to_vec()).unwrap();
        assert!(a.use_device_identity([11u8; 32].to_vec()));
        assert!(b.use_device_identity([12u8; 32].to_vec()));
        assert!(c.use_device_identity([13u8; 32].to_vec()));
        let insts = [&a, &b, &c];
        let seeds = [[1u8; 32], [2u8; 32], [3u8; 32]];
        let devs = [[11u8; 32], [12u8; 32], [13u8; 32]];
        let bundles: Vec<Vec<u8>> = insts.iter().map(|s| s.my_bundle()).collect();

        // Everyone adds everyone; installs its own 2-device roster (account + device leaves).
        let mut rosters = Vec::new();
        for i in 0..3 {
            for j in 0..3 {
                if i != j {
                    insts[i].add_contact_bundle(cid.clone(), bundles[j].clone()).unwrap();
                }
            }
            rosters.push(install_two_device_roster(insts[i], seeds[i], devs[i]));
        }
        // Cross-ingest rosters (device_lists) and cross-learn capability via signed profiles.
        let cards: Vec<Vec<u8>> = insts.iter().enumerate().map(|(i, s)| card(s, &format!("m{i}"))).collect();
        for i in 0..3 {
            for j in 0..3 {
                if i != j {
                    assert!(insts[i].ingest_device_roster(bundles[j].clone(), rosters[j].0.clone(), rosters[j].1.clone()));
                    insts[i].profile_seed_drop_version(bundles[j].clone(), cards[j].clone());
                }
            }
        }

        // Before any MLS sync, the shadow tree hasn't run anywhere.
        assert!(!a.mls_shadow_status(cid.clone()).converged, "no genesis before sync");

        // Arbitrary redelivery: several all-to-all rounds (the creator's genesis + welcomes ride
        // its bundle; everyone else stores them). Order-independent by construction.
        for _ in 0..4 {
            for i in 0..3 {
                for j in 0..3 {
                    if i != j {
                        sync(insts[i], insts[j], &cid);
                    }
                }
            }
        }

        let reference = a.mls_shadow_status(cid.clone());
        assert!(reference.converged, "the creator converged");
        assert_eq!(reference.epoch, 1);
        assert_eq!(reference.fork_count, 0, "one elected creator ⇒ no fork");
        assert!(!reference.tree_hash_hex.is_empty());
        for (i, s) in insts.iter().enumerate() {
            let st = s.mls_shadow_status(cid.clone());
            assert!(st.converged, "instance {i} converged");
            assert_eq!(st.tree_hash_hex, reference.tree_hash_hex, "instance {i} tree hash agrees");
            assert_eq!(st.epoch, reference.epoch);
            assert_eq!(st.fork_count, 0);
        }

        // SHADOW invariant: content still flows under sender-keys, untouched by any of the above.
        a.post(cid.clone(), "hi fleet".into(), vec![], None, None, false, false, 1_000).unwrap();
        for _ in 0..2 {
            sync(&a, &b, &cid);
            sync(&a, &c, &cid);
        }
        assert!(b.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "hi fleet"));
        assert!(c.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "hi fleet"));
    }

    /// §9 M2 proof (a + concurrency): two SIBLING devices of one account are both the elected
    /// (lowest-account) creator, so each issues its own genesis — a §5.1 same-parent FORK. After
    /// sync both resolve it to the identical winner (larger tip hash): converged=true, equal tree
    /// hash, fork_count=1 on both. This is the wiring-level fork-and-converge signal.
    #[test]
    fn mls_shadow_two_siblings_fork_and_converge() {
        let cid = DEFAULT_CIRCLE.to_string();
        let mac = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let phone = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        assert!(mac.use_device_identity([99u8; 32].to_vec()));
        assert!(phone.use_device_identity([88u8; 32].to_vec()));

        // Both install the SAME roster (account + both devices), so each computes the circle as
        // fully MLS-capable and resolves the sibling device locally.
        let acct_id = Identity::from_seed(&[2u8; 32]).public().node_id_bytes().to_vec();
        let mac_id = Identity::from_seed(&[99u8; 32]).public().node_id_bytes().to_vec();
        let phone_id = Identity::from_seed(&[88u8; 32]).public().node_id_bytes().to_vec();
        let mac_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), mac.my_device_bundle(), "mac".into(), 1).unwrap();
        let phone_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), phone.my_device_bundle(), "phone".into(), 2).unwrap();
        let acct_cred = crate::multidevice::issue_device_credential([2u8; 32].to_vec(), mac.my_bundle(), "primary".into(), 0).unwrap();
        let list = crate::multidevice::sign_device_list([2u8; 32].to_vec(), 1, 0, vec![acct_id, mac_id, phone_id], vec![]).unwrap();
        let creds = vec![acct_cred, mac_cred, phone_cred];
        assert!(mac.set_my_device_roster(list.clone(), creds.clone()));
        assert!(phone.set_my_device_roster(list, creds));

        for _ in 0..4 {
            sync(&mac, &phone, &cid);
            sync(&phone, &mac, &cid);
        }

        let sm = mac.mls_shadow_status(cid.clone());
        let sp = phone.mls_shadow_status(cid.clone());
        assert!(sm.converged, "mac resolved the fork and holds the winner's welcome");
        assert!(sp.converged, "phone resolved the fork and holds the winner's welcome");
        assert_eq!(sm.tree_hash_hex, sp.tree_hash_hex, "both siblings pick the same winning tree");
        assert_eq!(sm.fork_count, 1, "two creators ⇒ exactly one fork");
        assert_eq!(sp.fork_count, 1);
        assert!(!sm.tree_hash_hex.is_empty());
    }

    /// §9 M2 proof (b + c): a NON-capable member means the shadow tree simply doesn't run (no
    /// tree, converged=false), content flows normally; and a legacy/non-participating peer fed a
    /// `TAG_MLS_*` blob handles it harmlessly (no panic, no state change) with its feed intact.
    #[test]
    fn mls_shadow_absent_for_noncapable_and_legacy_blob_is_harmless() {
        let cid = DEFAULT_CIRCLE.to_string();
        // Alice is fully upgraded; Bob is a legacy account (no device key, no `ml` marker).
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        assert!(alice.use_device_identity([11u8; 32].to_vec()));
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
        install_two_device_roster(&alice, [1u8; 32], [11u8; 32]);

        // Bob never advertised capability, so Alice's circle is NOT fully MLS-capable → no shadow.
        alice.post(cid.clone(), "normal post".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync(&alice, &bob, &cid);
        assert!(bob.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "normal post"), "content flows normally");
        let sa = alice.mls_shadow_status(cid.clone());
        assert!(!sa.converged, "shadow doesn't run in a non-capable circle");
        assert!(sa.tree_hash_hex.is_empty());
        assert_eq!(sa.fork_count, 0);
        // No shadow wire was ever emitted (Alice's bundle carried only legacy tags).
        assert!(
            alice.sync_envelopes(cid.clone()).iter().all(|e| e.first() != Some(&TAG_MLS_COMMIT) && e.first() != Some(&TAG_MLS_WELCOME)),
            "a non-capable circle emits no MLS wire"
        );

        // Feed Bob (a legacy/non-participating peer) each TAG_MLS_* blob: harmless, no state change.
        let before = bob.feed(cid.clone(), 2_000, None).len();
        for tag in [TAG_MLS_COMMIT, TAG_MLS_WELCOME, TAG_MLS_PROPOSAL] {
            let blob = tagged(tag, &[0xEE; 40]);
            let r = bob.receive(cid.clone(), blob);
            assert!(matches!(r, Ok(false)), "a TAG_MLS_* blob is a harmless no-op for a non-participant");
        }
        // A genuinely UNKNOWN tag still hits the legacy arm and errors harmlessly (no panic).
        assert!(bob.receive(cid.clone(), tagged(0x7F, &[1, 2, 3])).is_err(), "unknown tag → harmless per-envelope error");
        assert_eq!(bob.feed(cid.clone(), 2_000, None).len(), before, "the legacy peer's feed is unchanged");
    }

    // ── TreeKEM M3: keying flip + removal re-key + admin authority (§4.3/§4.5/§7.2/§7.3) ──────

    /// The wire for a ONE-device roster (the running device is the only tree leaf) — every tree leaf
    /// maps to a live, joining device, the topology the §7.2 all-joined gate needs. Does NOT install.
    fn device_only_roster_wire(s: &HavenSocial, seed: [u8; 32]) -> (Vec<u8>, Vec<Vec<u8>>) {
        let dev_bundle = s.my_device_bundle();
        let dev_id = HavenId::from_bytes(&dev_bundle).unwrap().node_id_bytes().to_vec();
        let dev_cred =
            crate::multidevice::issue_device_credential(seed.to_vec(), dev_bundle, "device".into(), 1).unwrap();
        let list = crate::multidevice::sign_device_list(seed.to_vec(), 1, 0, vec![dev_id], vec![]).unwrap();
        (list, vec![dev_cred])
    }

    /// [`device_only_roster_wire`] + install it on `s`.
    fn install_device_only_roster(s: &HavenSocial, seed: [u8; 32]) -> (Vec<u8>, Vec<Vec<u8>>) {
        let (list, creds) = device_only_roster_wire(s, seed);
        assert!(s.set_my_device_roster(list.clone(), creds.clone()));
        (list, creds)
    }

    /// Build a fully-MLS-capable fleet (device-only rosters, cross-learned capability + rosters, a
    /// pinned creator). Does NOT flip the keying switch — the caller decides. Returns the instances.
    fn mls_capable_fleet(seeds: &[[u8; 32]], devs: &[[u8; 32]], creator_idx: usize) -> (Vec<Arc<HavenSocial>>, String) {
        // AUDIT F1 — creator authority now requires an OWNED circle id that binds to the creator, so
        // the shared fleet uses an id minted from the creator's account (not the ownerless "default").
        let creator_acct = Identity::from_seed(&seeds[creator_idx]).public().node_id_bytes();
        let cid = mint_owned_circle_id(&creator_acct);
        let insts: Vec<Arc<HavenSocial>> =
            seeds.iter().map(|s| HavenSocial::new(s.to_vec()).unwrap()).collect();
        let n = insts.len();
        for (i, d) in devs.iter().enumerate() {
            assert!(insts[i].use_device_identity(d.to_vec()));
        }
        // AUDIT F1 — the owned `c1…` id names no auto-created circle (unlike the legacy "default"),
        // so register it on every instance before the contact/roster wiring binds members to it.
        for s in &insts {
            s.create_circle(cid.clone(), "fleet".into());
        }
        let bundles: Vec<Vec<u8>> = insts.iter().map(|s| s.my_bundle()).collect();
        let mut rosters = Vec::new();
        for i in 0..n {
            for j in 0..n {
                if i != j {
                    insts[i].add_contact_bundle(cid.clone(), bundles[j].clone()).unwrap();
                }
            }
            rosters.push(install_device_only_roster(&insts[i], seeds[i]));
        }
        let cards: Vec<Vec<u8>> = insts.iter().enumerate().map(|(i, s)| card(s, &format!("m{i}"))).collect();
        for i in 0..n {
            for j in 0..n {
                if i != j {
                    assert!(insts[i].ingest_device_roster(bundles[j].clone(), rosters[j].0.clone(), rosters[j].1.clone()));
                    insts[i].profile_seed_drop_version(bundles[j].clone(), cards[j].clone());
                }
            }
        }
        // Pin the creator on every instance (agreed out of band); the creator also broadcasts a
        // self-grant so the pin is verifiable on the lane.
        let creator_hex = hex(&Identity::from_seed(&seeds[creator_idx]).public().node_id_bytes());
        for s in &insts {
            assert!(s.set_circle_creator(cid.clone(), creator_hex.clone()));
        }
        (insts, cid)
    }

    /// Flip the keying switch on the whole fleet and sync all-to-all until it goes live everywhere.
    fn flip_and_join(insts: &[Arc<HavenSocial>], cid: &str) {
        for s in insts {
            s.set_mls_keying(true);
        }
        for _ in 0..6 {
            for i in 0..insts.len() {
                for j in 0..insts.len() {
                    if i != j {
                        sync(&insts[i], &insts[j], cid);
                    }
                }
            }
        }
    }

    /// §9 M3 — the KEYING FLIP: switch OFF is byte-identical (KeyCommit keys content); switch ON, once
    /// all-joined, flips to tree-derived keys, STOPS the KeyCommit, and content round-trips for all.
    #[test]
    fn mls_keying_flips_when_all_joined_and_content_round_trips() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        let (insts, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32], [3u8; 32]], &[[11u8; 32], [12u8; 32], [13u8; 32]], 0);
        let (a, b, c) = (&insts[0], &insts[1], &insts[2]);

        // SWITCH OFF: shadow only. A KeyCommit is emitted and content flows (the legacy path).
        for _ in 0..4 {
            for i in 0..3 {
                for j in 0..3 {
                    if i != j {
                        sync(&insts[i], &insts[j], &cid);
                    }
                }
            }
        }
        assert_ne!(a.mls_keying_status(cid.clone()).state, "live", "off ⇒ not live");
        assert!(a.sync_envelopes(cid.clone()).iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)), "off ⇒ KeyCommit still keys content");
        a.post(cid.clone(), "legacy-keyed".into(), vec![], None, None, false, false, 900).unwrap();
        for _ in 0..2 { sync(a, b, &cid); sync(a, c, &cid); }
        assert!(b.feed(cid.clone(), 1_000, None).iter().any(|m| m.body == "legacy-keyed"), "off content flows");

        // SWITCH ON + all-joined ⇒ LIVE everywhere, KeyCommit stops, tree keys content.
        flip_and_join(&insts, &cid);
        for s in &insts {
            let ks = s.mls_keying_status(cid.clone());
            assert_eq!(ks.state, "live", "every all-joined member flips live");
            assert_eq!(ks.epoch, 1, "at the genesis epoch");
        }
        assert!(a.sync_envelopes(cid.clone()).iter().all(|e| e.first() != Some(&TAG_KEY_COMMIT)), "a live circle STOPS the KeyCommit (§4.5)");

        a.post(cid.clone(), "tree-keyed".into(), vec![], None, None, false, false, 2_000).unwrap();
        b.post(cid.clone(), "tree-keyed-from-b".into(), vec![], None, None, false, false, 2_100).unwrap();
        for _ in 0..3 {
            for i in 0..3 {
                for j in 0..3 {
                    if i != j {
                        sync(&insts[i], &insts[j], &cid);
                    }
                }
            }
        }
        for (name, s) in [("b", b), ("c", c)] {
            assert!(s.feed(cid.clone(), 3_000, None).iter().any(|m| m.body == "tree-keyed"), "{name} reads A's tree-keyed post");
        }
        assert!(a.feed(cid.clone(), 3_000, None).iter().any(|m| m.body == "tree-keyed-from-b"), "A reads B's tree-keyed post");
        assert!(c.feed(cid.clone(), 3_000, None).iter().any(|m| m.body == "tree-keyed-from-b"), "C reads B's tree-keyed post");
    }

    /// Parse the ratchet index carried by a `post()` wire (tagged epoch envelope). `None` ⇒ the DM
    /// was NOT ratcheted (feed / OFF / legacy).
    fn wire_ratchet_index(wire: &[u8]) -> Option<u32> {
        assert_eq!(wire.first(), Some(&TAG_EPOCH_EVENT), "a post is a tagged epoch envelope");
        EpochEnvelope::from_bytes(&wire[1..]).unwrap().ratchet_index()
    }

    /// §9 M6 (§6.5) — the DM/live-lane per-message ratchet, wired behind the switch. Proves: (a) with
    /// the master switch ON but the circle NOT marked a live lane, a post is epoch-keyed (index
    /// absent) — feed traffic is untouched; (b) once marked a live lane, each DM carries a
    /// MONOTONIC ratchet index and round-trips; (c) DMs delivered OUT OF ORDER (the ratcheted wires
    /// fed directly, no epoch-keyed backstop) all open via the receiver's skipped-key cache — the
    /// mailbox days-late/out-of-order contract holds end-to-end.
    #[test]
    fn mls_m6_dm_ratchet_rides_the_lane_and_opens_out_of_order() {
        let _clk = clock_guard();
        // A 2-party circle = a DM. Flip it live (tree-keyed content).
        let (insts, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32]], &[[11u8; 32], [12u8; 32]], 0);
        let (a, b) = (&insts[0], &insts[1]);
        flip_and_join(&insts, &cid);
        assert_eq!(a.mls_keying_status(cid.clone()).state, "live", "the pair is keying-live");

        // (a) SWITCH ON, but the circle is NOT yet a live lane → a post stays epoch-keyed (feed
        // scope: the ratchet does not engage on unmarked circles).
        let feedish = a.post(cid.clone(), "not-a-dm".into(), vec![], None, None, false, false, 2_000).unwrap();
        assert_eq!(wire_ratchet_index(&feedish), None, "an unmarked circle is NOT ratcheted");

        // Mark the DM lane on both ends.
        a.set_circle_live_lane(cid.clone(), true);
        b.set_circle_live_lane(cid.clone(), true);

        // (b) Each DM now carries a monotonically increasing ratchet index, and round-trips.
        let w0 = a.post(cid.clone(), "dm-0".into(), vec![], None, None, false, false, 3_000).unwrap();
        let w1 = a.post(cid.clone(), "dm-1".into(), vec![], None, None, false, false, 3_100).unwrap();
        let w2 = a.post(cid.clone(), "dm-2".into(), vec![], None, None, false, false, 3_200).unwrap();
        assert_eq!(wire_ratchet_index(&w0), Some(0), "first DM is ratchet index 0");
        assert_eq!(wire_ratchet_index(&w1), Some(1), "second DM is ratchet index 1");
        assert_eq!(wire_ratchet_index(&w2), Some(2), "third DM is ratchet index 2");

        // (c) OUT OF ORDER: deliver the ratcheted wires directly (NO sync — so the epoch-keyed
        // re-seal backstop cannot mask the ratchet path) in the shuffled order [w2, w0, w1]. The
        // receiver's skipped-key cache derives + caches the jumped-over keys so every one opens.
        assert!(b.receive(cid.clone(), w2).unwrap(), "the out-of-order tip (index 2) opens, caching 0..2");
        assert!(b.receive(cid.clone(), w0).unwrap(), "the late index 0 opens from the skipped cache");
        assert!(b.receive(cid.clone(), w1).unwrap(), "the late index 1 opens from the skipped cache");
        let feed = b.feed(cid.clone(), 4_000, None);
        for body in ["dm-0", "dm-1", "dm-2"] {
            assert!(feed.iter().any(|m| m.body == body), "B reads {body} despite out-of-order delivery");
        }
    }

    /// §9 M6 — SWITCH-OFF byte-identity at the DM lane: even with a circle marked a live lane, a
    /// circle whose keying is NOT live (master switch OFF ⇒ shadow) posts a plain epoch-keyed
    /// envelope with NO ratchet field. The ratchet engages ONLY when the tree actually keys content.
    #[test]
    fn mls_m6_off_switch_dm_is_not_ratcheted() {
        let _clk = clock_guard();
        let (insts, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32]], &[[11u8; 32], [12u8; 32]], 0);
        let a = &insts[0];
        // Mark the lane, but never flip the keying switch → not live.
        a.set_circle_live_lane(cid.clone(), true);
        assert_ne!(a.mls_keying_status(cid.clone()).state, "live", "switch OFF ⇒ not live");
        let wire = a.post(cid.clone(), "off-dm".into(), vec![], None, None, false, false, 1_000).unwrap();
        assert_eq!(wire_ratchet_index(&wire), None, "no live keying ⇒ no ratchet (byte-identical to today)");
    }

    /// §9 M3 — THE HEADLINE (evolves `s5_revoked_seedless_device_cannot_reenter_or_decrypt`). In a
    /// fully-joined, keying-LIVE circle a creator/admin removes a device: (a) the removed device
    /// cannot derive the new epoch and cannot open any content posted after the Remove, while
    /// remaining members can; (b) the removed device cannot re-enter (it is not an admin, so it cannot
    /// author an authorized Add/Remove).
    #[test]
    fn s5_mls_removed_device_cannot_derive_or_reenter() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        // A is the creator/admin; B stays; C is removed.
        let (insts, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32], [3u8; 32]], &[[11u8; 32], [12u8; 32], [13u8; 32]], 0);
        let (a, b, c) = (&insts[0], &insts[1], &insts[2]);
        flip_and_join(&insts, &cid);
        assert_eq!(a.mls_keying_status(cid.clone()).state, "live");

        // CONTROL: pre-Remove content is readable by C.
        a.post(cid.clone(), "before-removal".into(), vec![], None, None, false, false, 2_000).unwrap();
        for _ in 0..3 { for i in 0..3 { for j in 0..3 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }
        assert!(c.feed(cid.clone(), 3_000, None).iter().any(|m| m.body == "before-removal"), "C reads pre-removal content");

        // A (creator/admin) removes C — a re-key (§4.3): builds a chained Remove+UpdatePath commit.
        let c_acct = hex(&Identity::from_seed(&[3u8; 32]).public().node_id_bytes());
        assert!(a.mls_remove_member(cid.clone(), c_acct.clone()), "the creator's Remove is authored");
        for _ in 0..4 { for i in 0..3 { for j in 0..3 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }

        // A and B advanced to the new epoch; C is cut off (cannot derive it).
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 2, "A re-keyed to epoch 2");
        assert_eq!(b.mls_keying_status(cid.clone()).epoch, 2, "B re-keyed to epoch 2");
        assert_ne!(c.mls_keying_status(cid.clone()).state, "live", "the removed device cannot derive the new epoch");

        // (a) Post-Remove content: readable by B, NOT by C.
        a.post(cid.clone(), "after-removal".into(), vec![], None, None, false, false, 4_000).unwrap();
        for _ in 0..4 { for i in 0..3 { for j in 0..3 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }
        assert!(b.feed(cid.clone(), 5_000, None).iter().any(|m| m.body == "after-removal"), "a remaining member reads post-Remove content");
        assert!(!c.feed(cid.clone(), 5_000, None).iter().any(|m| m.body == "after-removal"), "the removed device CANNOT open content posted after the Remove");

        // (b) C cannot re-enter: it is not an admin, so it cannot author an authorized Remove/Add.
        assert!(!c.mls_remove_member(cid.clone(), c_acct), "a removed non-admin cannot author a tree Remove to force its way back");
        assert!(!c.circle_admins(cid.clone()).contains(&hex(&Identity::from_seed(&[3u8; 32]).public().node_id_bytes())), "the removed device is not an admin");
    }

    /// §9 M3 — AUTHORITY: a Remove authored by a NON-admin is rejected by every receiver; a
    /// creator/admin Remove is accepted; and a delegated admin (creator-granted) can then remove.
    #[test]
    fn mls_remove_authority_is_enforced_by_receivers() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        // A creator; B a plain member; C a plain member; D the removal target.
        let (insts, cid) = mls_capable_fleet(
            &[[1u8; 32], [2u8; 32], [3u8; 32], [4u8; 32]],
            &[[11u8; 32], [12u8; 32], [13u8; 32], [14u8; 32]],
            0,
        );
        let (a, b, d) = (&insts[0], &insts[1], &insts[3]);
        flip_and_join(&insts, &cid);
        let d_acct = hex(&Identity::from_seed(&[4u8; 32]).public().node_id_bytes());
        let b_acct = hex(&Identity::from_seed(&[2u8; 32]).public().node_id_bytes());

        // NON-ADMIN: B tries to remove D. B is not the creator and holds no grant → its own client
        // refuses to author the commit (the committer-side check), so no unauthorized commit exists.
        assert!(!b.mls_remove_member(cid.clone(), d_acct.clone()), "a non-admin cannot author a Remove");

        // Forge one anyway (bypassing the committer check) and feed it to A: A REJECTS it (receiver
        // authority gate). A's epoch is unchanged and D still reads.
        let forged = forge_remove_commit(b, &cid, &d_acct);
        assert!(matches!(a.receive(cid.clone(), forged.clone()), Ok(false)), "a receiver returns no-content for an unauthorized Remove");
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 1, "A did not apply the non-admin Remove");
        a.post(cid.clone(), "still-here".into(), vec![], None, None, false, false, 2_000).unwrap();
        for _ in 0..4 { for i in 0..4 { for j in 0..4 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }
        assert!(d.feed(cid.clone(), 3_000, None).iter().any(|m| m.body == "still-here"), "D is NOT cut off by a non-admin Remove");

        // CREATOR grants B admin → B is now a current admin on every instance that ingests the grant.
        assert!(a.grant_circle_admin(cid.clone(), b_acct.clone()), "the creator delegates admin to B");
        for _ in 0..4 { for i in 0..4 { for j in 0..4 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }
        assert!(a.circle_admins(cid.clone()).contains(&b_acct), "B is an admin after the grant");
        assert!(b.circle_admins(cid.clone()).contains(&b_acct), "B learns it is an admin");

        // DELEGATED ADMIN: B now removes D — accepted by receivers, and D is cut off.
        assert!(b.mls_remove_member(cid.clone(), d_acct.clone()), "a delegated admin authors a Remove");
        for _ in 0..5 { for i in 0..4 { for j in 0..4 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }
        a.post(cid.clone(), "post-remove".into(), vec![], None, None, false, false, 6_000).unwrap();
        for _ in 0..4 { for i in 0..4 { for j in 0..4 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }
        assert!(insts[2].feed(cid.clone(), 7_000, None).iter().any(|m| m.body == "post-remove"), "a remaining member reads content after the admin Remove");
        assert!(!d.feed(cid.clone(), 7_000, None).iter().any(|m| m.body == "post-remove"), "D is cut off by the admin Remove");
    }

    /// AUDIT M2 — the circle creator (authority root) is bound to the AUTHENTICATED definition, not
    /// first-grant-wins TOFU. A self-signed grant naming a false creator that disagrees with the pinned
    /// definition creator is rejected; the legitimate creator's authority holds; delegation still works.
    #[test]
    fn m2_forged_creator_grant_rejected_when_creator_is_definition_pinned() {
        let real = Identity::from_seed(&[2u8; 32]);
        let cid = mint_owned_circle_id(&real.public().node_id_bytes()); // creator-bound id
        let victim = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        victim.create_circle(cid.clone(), "grp".into());
        let mallory = Identity::from_seed(&[9u8; 32]);
        let alice = Identity::from_seed(&[3u8; 32]);
        let real_hex = hex(&real.public().node_id_bytes());
        let alice_hex = hex(&alice.public().node_id_bytes());
        let mallory_hex = hex(&mallory.public().node_id_bytes());
        // Mallory, Real, and Alice are members so `receive_admin_grant` can resolve them as grantors.
        victim.add_contact_bundle(cid.clone(), real.public().to_bytes()).unwrap();
        victim.add_contact_bundle(cid.clone(), mallory.public().to_bytes()).unwrap();
        victim.add_contact_bundle(cid.clone(), alice.public().to_bytes()).unwrap();
        let gid = cid.as_bytes();
        let feed_grant = |g: &AdminGrant| victim.receive(cid.clone(), tagged(TAG_ADMIN_GRANT, &g.to_bytes()));

        // The victim pins the REAL creator via the authenticated definition (out-of-band agreement).
        assert!(victim.set_circle_creator(cid.clone(), real_hex.clone()));
        assert!(victim.circle_admins(cid.clone()).contains(&real_hex), "the real creator is an admin");

        // WEDGE ATTEMPT: Mallory self-signs a grant naming HERSELF as the creator/root. It verifies as a
        // signature, but it disagrees with the definition-pinned creator → dropped, and Mallory never
        // becomes the victim's authority root.
        let forged = AdminGrant::issue(&mallory, gid, mallory.public().node_id_bytes(), mallory.public().node_id_bytes(), 1);
        assert!(matches!(feed_grant(&forged), Ok(false)), "a grant naming a false creator is dropped");
        assert!(!victim.circle_admins(cid.clone()).contains(&mallory_hex), "Mallory cannot wedge herself as the root");
        assert!(victim.circle_admins(cid.clone()).contains(&real_hex), "the real creator's authority still holds");

        // DELEGATION still works: the real creator delegates admin to Alice (grantor=creator, creator matches).
        let g_alice_v1 = AdminGrant::issue(&real, gid, real.public().node_id_bytes(), alice.public().node_id_bytes(), 1);
        assert!(matches!(feed_grant(&g_alice_v1), Ok(false))); // control-lane ⇒ no content change
        assert!(victim.circle_admins(cid.clone()).contains(&alice_hex), "the creator's delegation is honored");

        // HIGHER-VERSION-WINS still holds: a v2 re-grant for Alice supersedes v1 (a stale v1 replay loses).
        let g_alice_v2 = AdminGrant::issue(&real, gid, real.public().node_id_bytes(), alice.public().node_id_bytes(), 2);
        feed_grant(&g_alice_v2).unwrap();
        feed_grant(&g_alice_v1).unwrap(); // stale replay
        assert!(victim.circle_admins(cid.clone()).contains(&alice_hex), "Alice remains admin (rollback refused)");
        // And a delegation grant naming a DIFFERENT creator (Mallory's root) is still ignored.
        let g_wrong_root = AdminGrant::issue(&mallory, gid, mallory.public().node_id_bytes(), alice.public().node_id_bytes(), 5);
        assert!(matches!(feed_grant(&g_wrong_root), Ok(false)));
        assert!(!victim.circle_admins(cid.clone()).contains(&mallory_hex), "a foreign-root grant grants no authority");
    }

    /// A friend's posted media opens even when you don't hold that friend's device roster. 1.0.7
    /// device-signed media in a fully-capable circle, so opening it required the author's up-to-date
    /// roster — and because a sealed blob is cached once and never re-sealed, any roster skew froze a
    /// friend's media as permanently unopenable. Media is account-signed + dual-sealed again, so any
    /// authorized reader opens it regardless of roster state.
    #[test]
    fn a_friends_media_opens_without_holding_the_authors_device_roster() {
        let cid = "fam".to_string();
        let alice = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        assert!(alice.use_device_identity([11u8; 32].to_vec()));
        assert!(bob.use_device_identity([12u8; 32].to_vec()));
        let (_al, _ac) = install_device_only_roster(&alice, [1u8; 32]);
        let (b_list, b_creds) = install_device_only_roster(&bob, [2u8; 32]);
        let a_bundle = alice.my_bundle();
        let b_bundle = bob.my_bundle();
        let b_card = card(&bob, "bob");

        for s in [&alice, &bob] {
            s.create_circle(cid.clone(), "Family".into());
        }
        alice.add_contact_bundle(cid.clone(), b_bundle.clone()).unwrap();
        bob.add_contact_bundle(cid.clone(), a_bundle.clone()).unwrap();

        // ALICE becomes fully seed-drop-capable in her view (own device + Bob's roster & capability).
        // Under 1.0.7 this made her DEVICE-SIGN her media — the exact condition that broke it.
        assert!(alice.ingest_device_roster(b_bundle.clone(), b_list, b_creds));
        alice.profile_seed_drop_version(b_bundle, b_card);

        // BOB deliberately never ingests Alice's device roster — the skew that froze media forever.
        let sealed = alice.seal_circle_media(cid.clone(), b"a sunset photo".to_vec()).expect("seal");
        let opened = bob.open_circle_media(cid.clone(), sealed);
        assert_eq!(opened.as_deref(), Some(&b"a sunset photo"[..]),
                   "a friend's media opens by account-sender resolution — no device roster required");

        // 1.0.8 RECOVERY: the client re-seals the SAME plaintext and overwrites the frozen blob at its
        // content-addressed key. The re-seal must still open for Bob (who still lacks Alice's roster) —
        // proving the force-overwrite the recovery does replaces a bad blob with a good, openable one.
        let resealed = alice.seal_circle_media(cid.clone(), b"a sunset photo".to_vec()).expect("re-seal");
        let reopened = bob.open_circle_media(cid.clone(), resealed);
        assert_eq!(reopened.as_deref(), Some(&b"a sunset photo"[..]),
                   "the recovery re-seal of the same media opens for a friend lacking the device roster");
    }

    /// COMPETING key commits for the same (account, epoch) — the norm since device-signed commits:
    /// a friend's iPhone and Mac each mint a random key for the same slot, and BOTH commits sit in
    /// the content-addressed mailbox forever. The old last-writer-wins adoption flipped the stored
    /// key on every re-offer and reported "state changed" each time; the relay-hosting Mac's
    /// control-envelope re-offer amplified that into an endless re-ingest storm (16.8 GB in 5 min,
    /// main thread pinned on the engine lock, a push notification per re-ingested envelope). Slots
    /// must converge: re-applying a known commit is a reported no-op, and content sealed under the
    /// losing key still opens via the retained alt.
    #[test]
    fn competing_key_commits_converge_instead_of_flip_flopping() {
        let cid = "fam".to_string();
        // The same account restored on two devices (multi-master): each instance mints its OWN
        // random epoch-0 key for the circle, producing two competing commits for one slot.
        let alice1 = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let alice2 = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let a_bundle = alice1.my_bundle();
        let b_bundle = bob.my_bundle();
        for s in [&alice1, &alice2, &bob] {
            s.create_circle(cid.clone(), "Family".into());
        }
        alice1.add_contact_bundle(cid.clone(), b_bundle.clone()).unwrap();
        alice2.add_contact_bundle(cid.clone(), b_bundle).unwrap();
        bob.add_contact_bundle(cid.clone(), a_bundle).unwrap();

        // One post per device, then each device's bundle (its key commit + its re-sealed events).
        alice1.post(cid.clone(), "from device one".into(), vec![], None, None, false, false, 1_000).unwrap();
        alice2.post(cid.clone(), "from device two".into(), vec![], None, None, false, false, 2_000).unwrap();
        let env1 = alice1.sync_envelopes(cid.clone());
        let env2 = alice2.sync_envelopes(cid.clone());
        let commit1 = env1.iter().find(|e| e.first() == Some(&TAG_KEY_COMMIT)).expect("d1 commit").clone();
        let commit2 = env2.iter().find(|e| e.first() == Some(&TAG_KEY_COMMIT)).expect("d2 commit").clone();
        assert_ne!(commit1, commit2, "two devices must have minted competing commits");

        // First sight of each distinct key may legitimately report a change…
        let _ = bob.receive(cid.clone(), commit1.clone()).unwrap();
        let _ = bob.receive(cid.clone(), commit2.clone()).unwrap();
        // …but from here on, RE-OFFERING either commit must be a reported no-op, in any order.
        // This is the storm regression: any `true` below re-triggered a full circle re-ingest.
        for round in 0..3 {
            for (name, c) in [("commit1", &commit1), ("commit2", &commit2)] {
                assert!(
                    !bob.receive(cid.clone(), c.clone()).unwrap(),
                    "re-offered {name} reported a state change on round {round} — flip-flop is back"
                );
            }
        }

        // Content sealed by BOTH devices opens: one sealed under the slot winner, one under the
        // retained alt (loser) key. Losing either would resurrect \"my friend's post never shows\".
        for env in env1.iter().chain(env2.iter()).filter(|e| e.first() != Some(&TAG_KEY_COMMIT)) {
            let _ = bob.receive(cid.clone(), env.clone());
        }
        let feed = bob.feed(cid.clone(), 10_000, None);
        let texts: Vec<&str> = feed.iter().map(|i| i.body.as_str()).collect();
        assert!(texts.contains(&"from device one"), "post sealed under one competing key must open");
        assert!(texts.contains(&"from device two"), "post sealed under the other competing key must open");
    }

    /// A member you remove stays removed after a state merge that still lists them — the multi-device
    /// bug where removing someone on your phone was undone by your Mac's still-has-them state syncing
    /// back. The removal tombstone lives in the engine, so `merge_circle` can't silently re-grow it.
    #[test]
    fn a_removed_member_is_not_resurrected_by_a_state_merge() {
        let me = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        let bob = Identity::from_seed(&[2u8; 32]);
        let carol = Identity::from_seed(&[3u8; 32]);
        let bob_hex = hex(&bob.public().node_id_bytes());
        me.create_circle("fam".into(), "Family".into());
        me.add_contact_bundle("fam".into(), bob.public().to_bytes()).unwrap();
        me.add_contact_bundle("fam".into(), carol.public().to_bytes()).unwrap();

        // Capture the pre-removal state — this is exactly what another of my devices still holds.
        let stale = me.export_state();

        // Remove Bob on THIS device.
        me.remove_from_circle("fam".into(), bob_hex.clone());
        assert!(!me.contact_node_ids("fam".into()).contains(&bob_hex), "Bob is gone locally");

        // My other device's state (still listing Bob) merges back in — a normal multi-device sync.
        me.import_state(stale);
        assert!(!me.contact_node_ids("fam".into()).contains(&bob_hex),
                "Bob must STAY removed — the merge cannot resurrect a tombstoned member");
        // Carol, who was never removed, is unaffected.
        assert!(me.contact_node_ids("fam".into()).contains(&hex(&carol.public().node_id_bytes())));

        // THE TICK BUG: an AUTOMATIC re-add (a handshake in `handleHello`, or a peer's roster applied by
        // self-sync — both land on `add_contact_bundle`) must NOT bring Bob back. The tombstone is
        // authoritative in the engine, so the add is refused and Bob stays gone even without any
        // client-side guard. This is the exact path that made "remove someone" not stick on each tick.
        me.add_contact_bundle("fam".into(), bob.public().to_bytes()).unwrap();
        assert!(!me.contact_node_ids("fam".into()).contains(&bob_hex),
                "an automatic re-add must NOT resurrect a removed member");
        // Same for the compose-from-existing-contacts path.
        me.add_existing_to_circle("fam".into(), bob_hex.clone()).ok();
        assert!(!me.contact_node_ids("fam".into()).contains(&bob_hex),
                "add_existing_to_circle must also refuse a tombstoned member");

        // Only an EXPLICIT re-add — which lifts the tombstone first — brings Bob back, and then a merge
        // does NOT re-strip him.
        me.clear_circle_removal("fam".into(), bob_hex.clone());
        me.add_contact_bundle("fam".into(), bob.public().to_bytes()).unwrap();
        assert!(me.contact_node_ids("fam".into()).contains(&bob_hex),
                "explicit re-add (tombstone cleared) brings Bob back");
        let with_bob = me.export_state();
        me.import_state(with_bob);
        assert!(me.contact_node_ids("fam".into()).contains(&bob_hex), "re-added Bob survives a merge");
    }

    /// A legacy circle gains an authority root only by being carried onto a creator-bound successor,
    /// and only when the member deliberately follows the offer. The offer is never self-executing: a
    /// second member can sign an equally-valid competing offer, and both are surfaced for the user —
    /// so following one is a human decision, not a race the first claimer wins.
    #[test]
    fn a_legacy_circle_upgrades_only_by_a_followed_offer() {
        let legacy = "fam".to_string();
        let alice = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([3u8; 32].to_vec()).unwrap();
        let mallory = Identity::from_seed(&[9u8; 32]);
        let alice_hex = alice.my_node_hex();

        for s in [&alice, &bob] {
            s.create_circle(legacy.clone(), "Family".into());
        }
        alice.add_contact_bundle(legacy.clone(), bob.my_bundle()).unwrap();
        bob.add_contact_bundle(legacy.clone(), alice.my_bundle()).unwrap();
        bob.add_contact_bundle(legacy.clone(), mallory.public().to_bytes()).unwrap();

        // A legacy circle has no authority root — that's exactly why it needs upgrading.
        assert!(alice.circle_admins(legacy.clone()).is_empty());
        assert!(!alice.set_circle_creator(legacy.clone(), alice_hex.clone()), "can't pin a creator in place");

        // Alice (who made the circle) offers a creator-bound successor.
        let new_id = alice.upgrade_circle(legacy.clone()).expect("owner mints a successor");
        assert!(new_id.starts_with("c1"), "the successor is creator-bound");
        assert!(alice.circle_admins(new_id.clone()).contains(&alice_hex), "Alice roots the successor");
        assert!(alice.upgrade_circle(new_id.clone()).is_none(), "an owned circle has nothing to upgrade");

        // Bob receives it — and it does NOT take effect on its own.
        let offer = alice.circles().iter().find(|c| c.id == legacy).map(|_| ()).map(|_| {
            let st = alice.state.lock().unwrap();
            let i = st.circles.iter().position(|c| c.id == legacy).unwrap();
            st.circles[i].upgrade_offers[0].clone()
        }).unwrap();
        assert!(matches!(bob.receive(legacy.clone(), tagged(TAG_CIRCLE_UPGRADE, &offer)), Ok(false)));
        assert!(!bob.circles().iter().any(|c| c.id == new_id), "an offer never joins me to anything");

        // Mallory signs a competing, equally-valid offer for the same circle. Neither wins by arriving.
        let mallory_id = mint_owned_circle_id(&mallory.public().node_id_bytes());
        let hostile = CircleUpgrade::issue(&mallory, legacy.as_bytes(), mallory_id.as_bytes(), "Family", 1);
        assert!(matches!(bob.receive(legacy.clone(), tagged(TAG_CIRCLE_UPGRADE, &hostile.to_bytes())), Ok(false)));
        let pending = bob.pending_circle_upgrades(legacy.clone());
        assert_eq!(pending.len(), 2, "BOTH claims are surfaced — the user decides, nothing auto-resolves");
        assert!(pending.iter().any(|o| o.from_hex == alice_hex && o.new_circle_id == new_id));

        // Bob follows Alice's — the successor stands up with Alice as its verified creator.
        assert!(bob.accept_circle_upgrade(legacy.clone(), new_id.clone()));
        assert!(bob.circles().iter().any(|c| c.id == new_id), "Bob joins the successor");
        assert!(bob.circle_admins(new_id.clone()).contains(&alice_hex), "Alice is the successor's root for Bob");
        // Mallory's successor grants her nothing over the circle Bob followed.
        assert!(!bob.circle_admins(new_id.clone()).contains(&hex(&mallory.public().node_id_bytes())));
        // The legacy circle is untouched — it keeps working on its existing path.
        assert!(bob.circles().iter().any(|c| c.id == legacy));
        assert!(bob.circle_admins(legacy.clone()).is_empty(), "the legacy circle still has no root");
    }

    /// An upgrade offer is only meaningful where a circle has NO provable owner. On a circle whose id
    /// already names its creator, another member's "upgrade" is just an invitation to follow them off
    /// someone else's circle — and unlike the legacy case the app CAN tell, so it must refuse rather
    /// than ask the user to judge a claim that is already disproven.
    #[test]
    fn an_owned_circle_cannot_be_upgraded_away_by_a_member() {
        let alice = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let dave = HavenSocial::new([4u8; 32].to_vec()).unwrap();
        let mallory = Identity::from_seed(&[9u8; 32]);
        let alice_hex = alice.my_node_hex();
        let mallory_hex = hex(&mallory.public().node_id_bytes());

        // Alice's circle names her as its creator, and Dave can verify that.
        let owned = alice.create_circle_owned("Owned".into());
        dave.create_circle(owned.clone(), "Owned".into());
        dave.add_contact_bundle(owned.clone(), alice.my_bundle()).unwrap();
        dave.add_contact_bundle(owned.clone(), mallory.public().to_bytes()).unwrap();
        assert!(dave.set_circle_creator(owned.clone(), alice_hex.clone()));
        assert!(dave.circle_admins(owned.clone()).contains(&alice_hex));

        // Mallory, an ordinary member, tries to draw people onto a successor of her own.
        let m_succ = mint_owned_circle_id(&mallory.public().node_id_bytes());
        let hostile = CircleUpgrade::issue(&mallory, owned.as_bytes(), m_succ.as_bytes(), "Owned", 1);
        assert!(matches!(dave.receive(owned.clone(), tagged(TAG_CIRCLE_UPGRADE, &hostile.to_bytes())), Ok(false)));
        assert!(dave.pending_circle_upgrades(owned.clone()).is_empty(),
                "an owned circle never surfaces an upgrade offer — the claim is already disproven");
        assert!(!dave.accept_circle_upgrade(owned.clone(), m_succ.clone()),
                "and following one is refused outright");
        assert!(!dave.circles().iter().any(|c| c.id == m_succ), "Dave is not drawn onto her circle");
        assert!(dave.circle_admins(owned.clone()).contains(&alice_hex), "Alice remains the root");
        assert!(!dave.circle_admins(owned.clone()).contains(&mallory_hex));

        // Nor can a member author one for someone else's owned circle in the first place.
        let bob = HavenSocial::new([9u8; 32].to_vec()).unwrap();
        bob.create_circle(owned.clone(), "Owned".into());
        bob.add_contact_bundle(owned.clone(), alice.my_bundle()).unwrap();
        assert!(bob.set_circle_creator(owned.clone(), alice_hex.clone()));
        assert!(bob.upgrade_circle(owned.clone()).is_none(), "an owned circle can't be offered away");
        // Alice can't "upgrade" her own owned circle either — it already has what an upgrade grants.
        assert!(alice.upgrade_circle(owned.clone()).is_none());
    }

    /// The guard must hold in the window where the creator ISN'T known locally yet — a fresh member
    /// hasn't learned the owner's bundle, so the admin-set check can't refuse on its own. What saves
    /// it is that the circle id itself is owned, which is a local, immutable fact needing no bundle,
    /// grant, or roster. (The sibling test pins the creator first, so it passes even with this guard
    /// removed — it exercises the redundant half. This one fails without it.)
    #[test]
    fn an_owned_circle_is_unupgradable_even_before_its_creator_is_known() {
        let alice = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let dave = HavenSocial::new([4u8; 32].to_vec()).unwrap();
        let mallory = Identity::from_seed(&[9u8; 32]);
        let owned = alice.create_circle_owned("Owned".into());

        // Dave holds the circle but has NOT learned Alice as its creator.
        dave.create_circle(owned.clone(), "Owned".into());
        dave.add_contact_bundle(owned.clone(), mallory.public().to_bytes()).unwrap();
        assert!(dave.circle_admins(owned.clone()).is_empty(), "no creator known yet — the redundant half can't refuse");

        let m_succ = mint_owned_circle_id(&mallory.public().node_id_bytes());
        let hostile = CircleUpgrade::issue(&mallory, owned.as_bytes(), m_succ.as_bytes(), "Owned", 1);
        assert!(matches!(dave.receive(owned.clone(), tagged(TAG_CIRCLE_UPGRADE, &hostile.to_bytes())), Ok(false)));
        assert!(dave.pending_circle_upgrades(owned.clone()).is_empty(), "the owned id alone refuses it");
        assert!(!dave.accept_circle_upgrade(owned.clone(), m_succ.clone()));
        assert!(!dave.circles().iter().any(|c| c.id == m_succ), "Dave is never drawn onto her circle");
    }

    /// A member must not be able to bury the offer they least want followed. Hiding an offer keys on
    /// MY recorded accept — never on the successor merely existing with a pinned creator, both of
    /// which a peer can arrange (it hands me the id to stand up, then a grant naming the true creator
    /// pins it), which would let the member facing eviction block the upgrade that enables it.
    #[test]
    fn a_member_cannot_bury_an_offer_by_pre_creating_its_successor() {
        let legacy = "fam".to_string();
        let alice = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        let dave = HavenSocial::new([4u8; 32].to_vec()).unwrap();
        let mallory = Identity::from_seed(&[9u8; 32]);
        let alice_hex = alice.my_node_hex();

        for s in [&alice, &dave] { s.create_circle(legacy.clone(), "Family".into()); }
        alice.add_contact_bundle(legacy.clone(), dave.my_bundle()).unwrap();
        dave.add_contact_bundle(legacy.clone(), alice.my_bundle()).unwrap();
        dave.add_contact_bundle(legacy.clone(), mallory.public().to_bytes()).unwrap();

        let new_id = alice.upgrade_circle(legacy.clone()).expect("Alice offers");
        let offer = {
            let st = alice.state.lock().unwrap();
            let i = st.circles.iter().position(|c| c.id == legacy).unwrap();
            st.circles[i].upgrade_offers[0].clone()
        };
        assert!(matches!(dave.receive(legacy.clone(), tagged(TAG_CIRCLE_UPGRADE, &offer)), Ok(false)));
        assert_eq!(dave.pending_circle_upgrades(legacy.clone()).len(), 1, "Alice's offer is shown");

        // Mallory learns the successor id off the shared lane, gets Dave to stand it up (the ordinary
        // way any circle is shared), then pins its true creator with a grant naming Alice.
        dave.create_circle(new_id.clone(), "Family".into());
        dave.add_contact_bundle(new_id.clone(), alice.my_bundle()).unwrap();
        let alice_acct = Identity::from_seed(&[2u8; 32]).public().node_id_bytes();
        let g = AdminGrant::issue(&mallory, new_id.as_bytes(), alice_acct, alice_acct, 1);
        let _ = dave.receive(new_id.clone(), tagged(TAG_ADMIN_GRANT, &g.to_bytes()));

        // Alice's offer must STILL be shown — Dave never followed it.
        assert_eq!(dave.pending_circle_upgrades(legacy.clone()).len(), 1,
                   "a peer arranging the successor's existence must not bury a real offer");
        // And following it still works, after which it's hidden — because Dave acted.
        assert!(dave.accept_circle_upgrade(legacy.clone(), new_id.clone()));
        assert!(dave.circle_admins(new_id.clone()).contains(&alice_hex), "Alice roots the successor for Dave");
        assert!(dave.pending_circle_upgrades(legacy.clone()).is_empty(), "hidden only once I followed it");
    }

    /// Offering twice hands back the SAME successor instead of stranding another orphan circle.
    #[test]
    fn offering_an_upgrade_twice_is_idempotent() {
        let alice = HavenSocial::new([2u8; 32].to_vec()).unwrap();
        alice.create_circle("fam".into(), "Family".into());
        let first = alice.upgrade_circle("fam".into()).expect("offer");
        let again = alice.upgrade_circle("fam".into()).expect("offering again returns the same successor");
        assert_eq!(first, again, "a second tap must not mint a second successor");
        assert_eq!(alice.circles().iter().filter(|c| c.id.starts_with("c1")).count(), 1,
                   "exactly one successor exists");
    }

    /// Circle authority is bound to the circle id. On an OWNED circle a grant that names a false
    /// creator installs nothing (no first-grant-wins learning), and on a legacy/ownerless circle no
    /// grant confers creator authority at all. Both foreclose an insider racing a self-signed grant to
    /// become the authority root — for owned and legacy circles alike.
    #[test]
    fn creator_binding_forecloses_a_false_authority_root() {
        let real = Identity::from_seed(&[2u8; 32]);
        let mallory = Identity::from_seed(&[9u8; 32]);
        let real_hex = hex(&real.public().node_id_bytes());
        let mallory_hex = hex(&mallory.public().node_id_bytes());

        // ── OWNED circle (id binds `real`): a raced hostile grant installs NO creator. ──
        let owned = mint_owned_circle_id(&real.public().node_id_bytes());
        let victim = HavenSocial::new([1u8; 32].to_vec()).unwrap();
        victim.create_circle(owned.clone(), "grp".into());
        victim.add_contact_bundle(owned.clone(), real.public().to_bytes()).unwrap();
        victim.add_contact_bundle(owned.clone(), mallory.public().to_bytes()).unwrap();
        // Mallory races a self-signed grant naming herself the root, before the victim learns anyone.
        let forged = AdminGrant::issue(&mallory, owned.as_bytes(), mallory.public().node_id_bytes(), mallory.public().node_id_bytes(), 1);
        assert!(matches!(victim.receive(owned.clone(), tagged(TAG_ADMIN_GRANT, &forged.to_bytes())), Ok(false)));
        assert!(victim.circle_admins(owned.clone()).is_empty(), "a raced grant installs no creator on an owned circle");
        // The real creator is established from the binding-verified definition, and is the only root.
        assert!(victim.set_circle_creator(owned.clone(), real_hex.clone()));
        assert!(victim.circle_admins(owned.clone()).contains(&real_hex));
        assert!(!victim.circle_admins(owned.clone()).contains(&mallory_hex));
        assert!(matches!(victim.receive(owned.clone(), tagged(TAG_ADMIN_GRANT, &forged.to_bytes())), Ok(false)));
        assert!(!victim.circle_admins(owned.clone()).contains(&mallory_hex), "the bound creator cannot be dislodged");

        // ── LEGACY/ownerless circle (arbitrary id): no creator authority can be established at all. ──
        let legacy = "team".to_string();
        let v2 = HavenSocial::new([5u8; 32].to_vec()).unwrap();
        v2.create_circle(legacy.clone(), "team".into());
        v2.add_contact_bundle(legacy.clone(), mallory.public().to_bytes()).unwrap();
        assert!(!v2.set_circle_creator(legacy.clone(), mallory_hex.clone()), "no creator can be pinned on an ownerless circle");
        let g = AdminGrant::issue(&mallory, legacy.as_bytes(), mallory.public().node_id_bytes(), mallory.public().node_id_bytes(), 1);
        let _ = v2.receive(legacy.clone(), tagged(TAG_ADMIN_GRANT, &g.to_bytes()));
        assert!(v2.circle_admins(legacy.clone()).is_empty(), "an ownerless circle grants no creator authority");
    }

    /// AUDIT L1 — a genesis commit NOT signed by the elected creator (or an admin) is rejected at ingest
    /// and never enters the shadow store, so it cannot become the winning genesis. Legitimate geneses
    /// (which the fleet converged on through this same gate) are admitted.
    #[test]
    fn m1_low_unauthenticated_genesis_is_rejected() {
        let (insts, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32], [3u8; 32]], &[[11u8; 32], [12u8; 32], [13u8; 32]], 0);
        // Converge the shadow tree — every instance accepts the elected creator's genesis (the gate admits it).
        for _ in 0..4 { for i in 0..3 { for j in 0..3 { if i != j { sync(&insts[i], &insts[j], &cid); } } } }
        let b = &insts[1];
        let before = b.mls_shadow_status(cid.clone());
        assert!(before.converged && before.fork_count == 0, "the legitimate genesis converged with no fork");

        // Capture the winning genesis and FORGE a competitor: identical content, but re-signed by a
        // FOREIGN key (an account/device that is neither the elected creator nor any admin).
        let real_genesis = {
            let st = b.state.lock().unwrap();
            let shadow = st.shadow_trees.get(&cid).expect("shadow present");
            shadow
                .commits
                .values()
                .find(|bytes| treekem::Commit::from_bytes(bytes).map(|c| c.epoch == 1).unwrap_or(false))
                .expect("a genesis commit is stored")
                .clone()
        };
        let mut forged = treekem::Commit::from_bytes(&real_genesis).unwrap();
        let foreign = Identity::from_seed(&[222u8; 32]);
        forged.sig = foreign.sign(&treekem::commit_signing_bytes(&forged));
        let forged_bytes = forged.to_bytes();
        assert_ne!(forged_bytes, real_genesis, "the forgery is a distinct (different-signer) genesis");

        // Feed the forged genesis to B: REJECTED at ingest (unauthenticated signer). No new fork appears,
        // and B's converged tree hash is unchanged.
        assert!(matches!(b.receive(cid.clone(), tagged(TAG_MLS_COMMIT, &forged_bytes)), Ok(false)));
        let after = b.mls_shadow_status(cid.clone());
        assert_eq!(after.fork_count, 0, "the unauthenticated genesis did not enter the store as a fork");
        assert_eq!(after.tree_hash_hex, before.tree_hash_hex, "B's genesis is unchanged");
    }

    /// Craft a Remove commit signed by a NON-admin (bypassing the committer-side authority check) to
    /// exercise the RECEIVER-side gate. Mirrors `mls_build_remove` minus the authority check.
    fn forge_remove_commit(inst: &HavenSocial, cid: &str, target_acct_hex: &str) -> Vec<u8> {
        let st = inst.state.lock().unwrap();
        let gid = cid.as_bytes().to_vec();
        let seed = st.device.as_ref().map(|d| d.secret_seed()).unwrap();
        let signer = Identity::from_seed(&seed);
        let my_secret_root = keying_secret_root(&seed, &gid);
        let shadow = st.shadow_trees.get(&cid.to_string()).unwrap();
        let cur = mls_replay(shadow, Some(seed)).unwrap();
        let mp = cur.my_private.as_ref().unwrap();
        let my_leaf = mp.leaf_index;
        let target = decode_hex32(target_acct_hex).unwrap();
        let mut leaves = Vec::new();
        for (i, slot) in cur.tree.slots.iter().enumerate() {
            if let treekem::TreeSlot::Leaf(l) = slot {
                if i % 2 == 0 {
                    if let Ok(dc) = DeviceCredential::from_bytes(&l.device_credential) {
                        if dc.account_id == target {
                            leaves.push((i / 2) as u32);
                        }
                    }
                }
            }
        }
        let next = cur.epoch + 1;
        let (new_leaf, entropy) = keying_update_material(&my_secret_root, next);
        let cred = cur.tree.leaf(my_leaf).map(|l| l.device_credential.clone()).unwrap();
        let props: Vec<treekem::Proposal> = leaves
            .iter()
            .map(|li| treekem::build_remove_proposal(&gid, next, my_leaf, *li, |m| signer.sign(m)))
            .collect();
        let build = treekem::build_commit(
            &cur.tree, &gid, next, cur.tip_hash, &cur.cth, &cur.init_secret.unwrap(), my_leaf, props,
            Some((&new_leaf, &cred, &entropy)), |m| signer.sign(m), |m| signer.sign(m),
        )
        .unwrap();
        tagged(TAG_MLS_COMMIT, &build.commit.to_bytes())
    }

    /// §9 M3 — PARK/RESUME (§7.3): a legacy (non-capable) device joining a flipped circle reverts it
    /// to the KeyCommit path within one bundle, and everyone (incl. the newcomer) still reads; when
    /// the newcomer upgrades + joins, the circle re-flips.
    #[test]
    fn mls_legacy_join_parks_then_reflips() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        let (insts, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32]], &[[11u8; 32], [12u8; 32]], 0);
        let (a, b) = (&insts[0], &insts[1]);
        flip_and_join(&insts, &cid);
        assert_eq!(a.mls_keying_status(cid.clone()).state, "live", "the pair flips live");

        // A LEGACY newcomer joins: an account with no device key / no `ml` marker.
        let legacy = HavenSocial::new([9u8; 32].to_vec()).unwrap();
        legacy.create_circle(cid.clone(), "fleet".into()); // the owned id names no auto-created circle
        a.add_contact_bundle(cid.clone(), legacy.my_bundle()).unwrap();
        b.add_contact_bundle(cid.clone(), legacy.my_bundle()).unwrap();
        legacy.add_contact_bundle(cid.clone(), a.my_bundle()).unwrap();
        legacy.add_contact_bundle(cid.clone(), b.my_bundle()).unwrap();

        // The circle is no longer fully-MLS-capable ⇒ it PARKS back to KeyCommit within one bundle.
        assert_ne!(a.mls_keying_status(cid.clone()).state, "live", "a non-capable newcomer parks the flip (§7.3)");
        assert!(a.sync_envelopes(cid.clone()).iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)), "KeyCommit resumes on park");

        // Everyone — including the legacy newcomer — still reads content (legacy sender-keys path).
        a.post(cid.clone(), "parked-post".into(), vec![], None, None, false, false, 3_000).unwrap();
        for _ in 0..3 { sync(a, b, &cid); sync(a, &legacy, &cid); sync(b, &legacy, &cid); }
        assert!(b.feed(cid.clone(), 4_000, None).iter().any(|m| m.body == "parked-post"), "a member reads parked content");
        assert!(legacy.feed(cid.clone(), 4_000, None).iter().any(|m| m.body == "parked-post"), "the legacy newcomer reads parked content");

        // The newcomer UPGRADES: adopts a device, installs its roster, advertises capability, and both
        // directions cross-learn rosters + capability. Once it is capable AND joined, the circle
        // RE-FLIPS (§7.3 resume — the parked tree grows to add it via a superseding genesis).
        assert!(legacy.use_device_identity([19u8; 32].to_vec()));
        install_device_only_roster(&legacy, [9u8; 32]); // the newcomer installs its (fresh) roster
        let up = [a, b, &legacy];
        let up_seeds = [[1u8; 32], [2u8; 32], [9u8; 32]];
        // Roster WIRES for cross-ingest (a/b already have theirs installed — don't re-install).
        let rosters: Vec<(Vec<u8>, Vec<Vec<u8>>)> =
            up.iter().enumerate().map(|(i, s)| device_only_roster_wire(s, up_seeds[i])).collect();
        let bundles: Vec<Vec<u8>> = up.iter().map(|s| s.my_bundle()).collect();
        for i in 0..3 {
            for j in 0..3 {
                if i != j {
                    // Idempotent: a same-version roster a/b already hold returns false harmlessly; the
                    // NEW pairs (involving the newcomer) are the ones that matter.
                    let _ = up[i].ingest_device_roster(bundles[j].clone(), rosters[j].0.clone(), rosters[j].1.clone());
                    up[i].profile_seed_drop_version(
                        bundles[j].clone(),
                        up[j].my_signed_profile("m".into(), String::new(), String::new(), String::new(), String::new()),
                    );
                }
            }
        }
        legacy.set_circle_creator(cid.clone(), hex(&Identity::from_seed(&[1u8; 32]).public().node_id_bytes()));
        legacy.set_mls_keying(true);
        for _ in 0..8 {
            for i in 0..3 {
                for j in 0..3 {
                    if i != j {
                        sync(up[i], up[j], &cid);
                    }
                }
            }
        }
        // The circle re-flips: A is live again on the superseding (3-leaf) genesis.
        assert_eq!(a.mls_keying_status(cid.clone()).state, "live", "re-flips once the straggler is capable + joined");
        a.post(cid.clone(), "reflipped".into(), vec![], None, None, false, false, 6_000).unwrap();
        for _ in 0..4 {
            for i in 0..3 {
                for j in 0..3 {
                    if i != j {
                        sync(up[i], up[j], &cid);
                    }
                }
            }
        }
        assert!(legacy.feed(cid.clone(), 7_000, None).iter().any(|m| m.body == "reflipped"), "the re-added device reads tree-keyed content");
    }

    // ── TreeKEM M4: offline / mid-chain Welcomes + roster→Add/Remove automation (§4.2/§4.3/§5.5) ──

    /// Wire a brand-new capable member `newcomer` into an already-live `fleet` mid-life: contact
    /// bundles both ways, its own device roster, cross-ingest of every roster + capability card, the
    /// creator pin, and the keying switch. Returns the full instance list (fleet + newcomer). After
    /// this the creator's roster automation will chain an Add+Welcome for the newcomer on its bundle.
    fn wire_new_member(
        fleet: &[Arc<HavenSocial>],
        fleet_seeds: &[[u8; 32]],
        newcomer: &Arc<HavenSocial>,
        newcomer_seed: [u8; 32],
        creator_seed: [u8; 32],
        cid: &str,
    ) {
        newcomer.create_circle(cid.to_string(), "fleet".into()); // the owned id names no auto-created circle
        install_device_only_roster(newcomer, newcomer_seed);
        let mut all: Vec<&Arc<HavenSocial>> = fleet.iter().collect();
        all.push(newcomer);
        let mut seeds: Vec<[u8; 32]> = fleet_seeds.to_vec();
        seeds.push(newcomer_seed);
        let bundles: Vec<Vec<u8>> = all.iter().map(|s| s.my_bundle()).collect();
        for i in 0..all.len() {
            for j in 0..all.len() {
                if i != j {
                    let _ = all[i].add_contact_bundle(cid.to_string(), bundles[j].clone());
                }
            }
        }
        let rosters: Vec<(Vec<u8>, Vec<Vec<u8>>)> =
            all.iter().enumerate().map(|(i, s)| device_only_roster_wire(s, seeds[i])).collect();
        let cards: Vec<Vec<u8>> = all.iter().enumerate().map(|(i, s)| card(s, &format!("n{i}"))).collect();
        for i in 0..all.len() {
            for j in 0..all.len() {
                if i != j {
                    let _ =
                        all[i].ingest_device_roster(bundles[j].clone(), rosters[j].0.clone(), rosters[j].1.clone());
                    all[i].profile_seed_drop_version(bundles[j].clone(), cards[j].clone());
                }
            }
        }
        let creator_hex = hex(&Identity::from_seed(&creator_seed).public().node_id_bytes());
        assert!(newcomer.set_circle_creator(cid.to_string(), creator_hex));
        newcomer.set_mls_keying(true);
    }

    fn sync_all(insts: &[&Arc<HavenSocial>], cid: &str, rounds: usize) {
        for _ in 0..rounds {
            for i in 0..insts.len() {
                for j in 0..insts.len() {
                    if i != j {
                        sync(insts[i], insts[j], cid);
                    }
                }
            }
        }
    }

    /// §9 M4 proof — a device that becomes authorized MID-LIFE gets a chained Add+Welcome, enters at
    /// the CURRENT epoch (epoch CONTINUITY — NOT a genesis rebuild), and reads full history via the
    /// re-seal backfill. This is also the `register_device`→Add roster automation: the creator issues
    /// the Add off the newcomer's roster arriving, with no explicit tree call anywhere.
    #[test]
    fn mls_mid_life_add_enters_at_live_epoch_and_reads_history() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        // A (creator) + B go live at the genesis epoch; A posts history BEFORE C exists.
        let (base, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32]], &[[11u8; 32], [12u8; 32]], 0);
        let (a, b) = (base[0].clone(), base[1].clone());
        flip_and_join(&base, &cid);
        assert_eq!(a.mls_keying_status(cid.clone()).state, "live");
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 1, "the pair is at the genesis epoch");
        a.post(cid.clone(), "history-1".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync_all(&[&a, &b], &cid, 3);
        assert!(b.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "history-1"));

        // C becomes authorized mid-life. Its register_device roster propagates to the creator, whose
        // automation chains an Add+Welcome at epoch 2 (no explicit mls_* call).
        let c = HavenSocial::new([3u8; 32].to_vec()).unwrap();
        assert!(c.use_device_identity([13u8; 32].to_vec()));
        wire_new_member(&base, &[[1u8; 32], [2u8; 32]], &c, [3u8; 32], [1u8; 32], &cid);
        let trio = [&a, &b, &c];
        sync_all(&trio, &cid, 12);

        // EPOCH CONTINUITY: the fleet chained to epoch 2 — it did NOT reset to a fresh genesis (which
        // would have put everyone back at epoch 1). C entered at the LIVE epoch.
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 2, "a chained Add advanced to epoch 2, not a rebuild");
        assert_eq!(b.mls_keying_status(cid.clone()).epoch, 2, "B stayed on the same chain, now epoch 2");
        assert_eq!(c.mls_keying_status(cid.clone()).state, "live", "C joined the live tree");
        assert_eq!(c.mls_keying_status(cid.clone()).epoch, 2, "C entered at the LIVE epoch (not a genesis)");

        // C reads FULL HISTORY (a post from before it joined) via the ordinary re-seal backfill.
        assert!(
            c.feed(cid.clone(), 3_000, None).iter().any(|m| m.body == "history-1"),
            "the mid-life joiner reads pre-join history via backfill"
        );

        // New epoch-2 content round-trips for all three, and A still reads B's.
        a.post(cid.clone(), "after-add".into(), vec![], None, None, false, false, 4_000).unwrap();
        b.post(cid.clone(), "b-after-add".into(), vec![], None, None, false, false, 4_100).unwrap();
        sync_all(&trio, &cid, 4);
        assert!(c.feed(cid.clone(), 5_000, None).iter().any(|m| m.body == "after-add"), "C reads new content");
        assert!(a.feed(cid.clone(), 5_000, None).iter().any(|m| m.body == "b-after-add"), "A reads B's new content");
        assert!(c.feed(cid.clone(), 5_000, None).iter().any(|m| m.body == "b-after-add"), "C reads B's new content");
    }

    /// §9 M4 proof — SLEEPER (§5.5): a device offline past the mailbox TTL, whose private tree state
    /// has lapsed so it can no longer replay the chain, re-enters via a FRESH self-contained Welcome
    /// at the current epoch, converges to the live epoch secret, and reads history via the backfill.
    #[test]
    fn mls_sleeper_reenters_via_welcome_after_ttl() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        // A(creator), B, C, D live at the genesis epoch. C is the sleeper; D is a throwaway removed
        // to advance the epoch while C is offline.
        let (insts, cid) = mls_capable_fleet(
            &[[1u8; 32], [2u8; 32], [3u8; 32], [4u8; 32]],
            &[[11u8; 32], [12u8; 32], [13u8; 32], [14u8; 32]],
            0,
        );
        let (a, b, c, d) = (&insts[0], &insts[1], &insts[2], &insts[3]);
        flip_and_join(&insts, &cid);
        a.post(cid.clone(), "history-1".into(), vec![], None, None, false, false, 1_000).unwrap();
        sync_all(&[a, b, c, d], &cid, 3);
        assert!(c.feed(cid.clone(), 2_000, None).iter().any(|m| m.body == "history-1"), "C reads history while awake");

        // The epoch advances while C sleeps: A removes D. Sync only among A and B (C stays offline).
        let d_acct = hex(&Identity::from_seed(&[4u8; 32]).public().node_id_bytes());
        assert!(a.mls_remove_member(cid.clone(), d_acct), "A removes the throwaway D");
        sync_all(&[a, b], &cid, 4);
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 2, "A advanced to epoch 2 while C slept");

        // Simulate 45+ days past the mailbox TTL: C's private entry (its Welcome) lapsed — it can no
        // longer replay to derive ANY epoch. (Its public commit knowledge is irrelevant without it.)
        c.state.lock().unwrap().shadow_trees.get_mut(&cid).unwrap().my_welcomes.clear();
        assert_ne!(c.mls_keying_status(cid.clone()).state, "live", "the sleeper can't derive after its state lapses");

        // The creator re-Welcomes C at the CURRENT epoch — a fresh, self-contained Welcome.
        let c_dev = hex(&Identity::from_seed(&[13u8; 32]).public().node_id_bytes());
        assert!(a.mls_rewelcome(cid.clone(), c_dev), "A issues a fresh Welcome to the sleeper");
        sync_all(&[a, b, c], &cid, 8);

        // C re-entered at the LIVE epoch and converges to the live epoch secret; it reads history via
        // the re-seal backfill — never having replayed the (pruned) chain.
        assert_eq!(c.mls_keying_status(cid.clone()).state, "live", "the sleeper re-enters live");
        assert_eq!(c.mls_keying_status(cid.clone()).epoch, 2, "at the current epoch");
        assert!(c.feed(cid.clone(), 3_000, None).iter().any(|m| m.body == "history-1"), "the sleeper reads history via backfill");
        a.post(cid.clone(), "post-reentry".into(), vec![], None, None, false, false, 4_000).unwrap();
        sync_all(&[a, b, c], &cid, 4);
        assert!(c.feed(cid.clone(), 5_000, None).iter().any(|m| m.body == "post-reentry"), "the sleeper reads live content");
    }

    /// §9 M4 proof — a Welcome addressed to a device REVOKED in the meantime FAILS CLOSED. A joiner is
    /// added mid-life (Welcome issued at epoch n), then removed at epoch n+1; it cannot enter the live
    /// tree — the forward walk applies the Remove and cuts it off — and the creator refuses to re-Welcome
    /// a device the tree no longer admits.
    #[test]
    fn mls_revoked_device_welcome_fails_closed() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        let (base, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32]], &[[11u8; 32], [12u8; 32]], 0);
        let (a, b) = (base[0].clone(), base[1].clone());
        flip_and_join(&base, &cid);

        // N joins mid-life (Add+Welcome at epoch 2) and goes live.
        let n = HavenSocial::new([5u8; 32].to_vec()).unwrap();
        assert!(n.use_device_identity([15u8; 32].to_vec()));
        wire_new_member(&base, &[[1u8; 32], [2u8; 32]], &n, [5u8; 32], [1u8; 32], &cid);
        let trio = [&a, &b, &n];
        sync_all(&trio, &cid, 12);
        assert_eq!(n.mls_keying_status(cid.clone()).state, "live", "N joined at epoch 2");
        assert_eq!(n.mls_keying_status(cid.clone()).epoch, 2);

        // N is REVOKED: the creator removes it → epoch 3, N's leaf blanked, N dropped from membership.
        let n_acct = hex(&Identity::from_seed(&[5u8; 32]).public().node_id_bytes());
        assert!(a.mls_remove_member(cid.clone(), n_acct), "the creator revokes N");
        sync_all(&trio, &cid, 6);

        // FAILS CLOSED: N cannot enter the live tree — the Remove it just received cuts it off, so it
        // can't derive the new epoch, even though it once held a valid Welcome for the (now stale) epoch.
        assert_ne!(n.mls_keying_status(cid.clone()).state, "live", "the revoked device can't derive the live epoch");
        a.post(cid.clone(), "after-revoke".into(), vec![], None, None, false, false, 6_000).unwrap();
        sync_all(&trio, &cid, 6);
        assert!(b.feed(cid.clone(), 7_000, None).iter().any(|m| m.body == "after-revoke"), "a remaining member reads post-revoke content");
        assert!(!n.feed(cid.clone(), 7_000, None).iter().any(|m| m.body == "after-revoke"), "the revoked device is cut off from post-revoke content");

        // The creator will NOT re-Welcome a device the tree no longer admits (its leaf is blanked).
        let n_dev = hex(&Identity::from_seed(&[15u8; 32]).public().node_id_bytes());
        assert!(!a.mls_rewelcome(cid.clone(), n_dev), "the tree does not admit a revoked device — no Welcome is issued");
    }

    /// §9 M4 proof — ROSTER automation drives an authority-checked Remove: a member whose device is
    /// revoked in the DEVICE roster is auto-Removed by the CREATOR (a re-key the removed device can't
    /// derive), while a NON-admin ingesting the same revocation authors NO accepted Remove.
    #[test]
    fn mls_roster_revocation_drives_authority_checked_remove() {
        let _clk = clock_guard(); // §6.4 PCS cadence reads the global clock; hold it steady (see clock_guard)
        // A(creator), B, C all live. C will be revoked via its own roster (a lost-device scenario).
        let (insts, cid) = mls_capable_fleet(&[[1u8; 32], [2u8; 32], [3u8; 32]], &[[11u8; 32], [12u8; 32], [13u8; 32]], 0);
        let (a, b, c) = (&insts[0], &insts[1], &insts[2]);
        flip_and_join(&insts, &cid);
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 1, "genesis epoch");

        // C's device is revoked in a NEWER signed roster (version 2, C's device in the revoked set).
        let c_dev_id = Identity::from_seed(&[13u8; 32]).public().node_id_bytes().to_vec();
        let revoked_list =
            crate::multidevice::sign_device_list([3u8; 32].to_vec(), 2, 10, vec![], vec![c_dev_id]).unwrap();

        // NON-ADMIN FIRST: B (not the creator) ingests the revocation. B rotates its sender-keys epoch
        // but authors NO tree Remove — the automation is creator-gated, so no accepted Remove exists.
        assert!(b.ingest_device_roster(c.my_bundle(), revoked_list.clone(), vec![]));
        for _ in 0..3 { sync(b, a, &cid); }
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 1, "a non-admin's roster ingest produces no accepted Remove");

        // CREATOR: A ingests the same revocation → its automation authors the authority-checked Remove,
        // re-keying to epoch 2. C (the revoked device) is cut off; B (a remaining member) is not.
        assert!(a.ingest_device_roster(c.my_bundle(), revoked_list, vec![]));
        sync_all(&[a, b, c], &cid, 6);
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 2, "the creator's roster-driven Remove re-keyed to epoch 2");
        assert_ne!(c.mls_keying_status(cid.clone()).state, "live", "the revoked device cannot derive the new epoch");

        a.post(cid.clone(), "post-revoke".into(), vec![], None, None, false, false, 3_000).unwrap();
        sync_all(&[a, b, c], &cid, 6);
        assert!(b.feed(cid.clone(), 4_000, None).iter().any(|m| m.body == "post-revoke"), "a remaining member reads post-revoke content");
        assert!(!c.feed(cid.clone(), 4_000, None).iter().any(|m| m.body == "post-revoke"), "the revoked device is cut off");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    // MLS M5 — PCS cadence + the §6.3 forward-secrecy proof obligations at the engine level.
    // (The pure schedule-level PCS + FS-bug tests live in `treekem.rs`; these drive the wired
    // cadence and the FFI-only obligations — reseal lane, merge import, welcome retention.)
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// A device's live tree-deriving state (what an attacker exfiltrates), captured by replaying the
    /// committer's own chain — `(tree epoch, sender_root, init_secret, joiner_secret)`.
    fn mls_capture_state(s: &HavenSocial, cid: &str) -> (u64, [u8; 32], [u8; 32], [u8; 32]) {
        let st = s.state.lock().unwrap();
        let seed = st.device.as_ref().unwrap().secret_seed();
        let shadow = st.shadow_trees.get(cid).expect("live circle has a shadow tree");
        let ks = mls_replay(shadow, Some(seed)).expect("committer replays its chain");
        (
            ks.epoch,
            ks.sender_root.expect("active member has a sender_root"),
            ks.init_secret.expect("active member has an init_secret"),
            ks.joiner_secret.expect("active member has a joiner_secret"),
        )
    }

    /// §9 M5 — THE PCS TEST, wired end to end (§6.4). Exfiltrate the committer's full epoch-1
    /// deriving state, let the weekly `rotate_if_stale` chokepoint fire (no manual Remove/Add — the
    /// PCS leaf-Update PIGGYBACKS it), and assert the stolen epoch-1 `sender_root` opens nothing at
    /// the healed epoch 2, while the circle keeps working. The razor-sharp converse (init_1 WOULD
    /// open n+1 absent a fresh Update) is proven at the schedule level in `treekem.rs`.
    #[test]
    fn mls_pcs_cadence_heals_committer_leaf_on_the_rotate_chokepoint() {
        let (insts, cid) = mls_capable_fleet(&[[71u8; 32], [72u8; 32]], &[[81u8; 32], [82u8; 32]], 0);
        let (a, b) = (&insts[0], &insts[1]);
        flip_and_join(&insts, &cid);
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 1, "the pair is live at the genesis epoch");

        // Exfiltrate A's (the committer's) FULL epoch-1 state, and the epoch-1 content key it derives.
        let gidbytes = cid.as_bytes().to_vec();
        let acct_a = Identity::from_seed(&[71u8; 32]).public().node_id_bytes();
        let (e1, root1, _init1, _js1) = mls_capture_state(a, &cid);
        assert_eq!(e1, 1);
        let content_key_1 = treekem::sender_key(&root1, &acct_a, &gidbytes, 1);
        let live_key_1 = a.state.lock().unwrap().circles.iter().find(|c| c.id == cid).unwrap()
            .my_epoch_keys.get(&(MLS_EPOCH_BASE + 1)).copied().unwrap();
        assert_eq!(content_key_1, live_key_1, "the captured sender_root reproduces the live epoch-1 content key");

        // Let a week pass and run ordinary full bundles — the PCS leaf Update fires on the SAME
        // chokepoint as the legacy rotation, with NO membership change.
        with_clock_advanced(ROTATE_INTERVAL_SECS + 1, || {
            sync_all(&[a, b], &cid, 4);
        });
        assert_eq!(a.mls_keying_status(cid.clone()).epoch, 2, "the PCS leaf Update advanced the epoch on the stale window");
        assert_eq!(b.mls_keying_status(cid.clone()).epoch, 2, "B converged on the healed epoch");

        // HEALED: the stolen epoch-1 sender_root cannot derive the epoch-2 content key, but A holds it.
        let real_key_2 = a.state.lock().unwrap().circles.iter().find(|c| c.id == cid).unwrap()
            .my_epoch_keys.get(&(MLS_EPOCH_BASE + 2)).copied().unwrap();
        assert_ne!(
            treekem::sender_key(&root1, &acct_a, &gidbytes, 2), real_key_2,
            "the exfiltrated epoch-1 sender_root opens NOTHING at epoch 2 (the compromise window closed)",
        );

        // The circle keeps working across the heal: content posted at epoch 2 round-trips.
        a.post(cid.clone(), "healed".into(), vec![], None, None, false, false, 5_000).unwrap();
        sync_all(&[a, b], &cid, 3);
        assert!(b.feed(cid.clone(), 6_000, None).iter().any(|m| m.body == "healed"), "post-heal content round-trips");
    }

    /// §9 M5 / §6.3-3 — Welcome retention is BOUNDED, not pinned forever. The committer issues a fresh
    /// `joiner_secret` per epoch and does not keep serving the old one: once the weekly cadence
    /// advances the epoch, the prior epoch's joiner material no longer keys the live epoch, so an
    /// un-consumed Welcome goes stale within the rotation window (tighter than the 30-day mailbox TTL)
    /// and re-entry needs a fresh, current-epoch Welcome.
    #[test]
    fn fs_bug_3_welcome_joiner_secret_retention_is_bounded() {
        let (insts, cid) = mls_capable_fleet(&[[73u8; 32], [74u8; 32]], &[[83u8; 32], [84u8; 32]], 0);
        let (a, b) = (&insts[0], &insts[1]);
        flip_and_join(&insts, &cid);
        let (e1, root1, _i1, js1) = mls_capture_state(a, &cid);
        assert_eq!(e1, 1);

        with_clock_advanced(ROTATE_INTERVAL_SECS + 1, || {
            sync_all(&[a, b], &cid, 4);
        });
        let (e2, root2, _i2, js2) = mls_capture_state(a, &cid);
        assert_eq!(e2, 2, "the epoch advanced via the PCS cadence");
        // The committer does NOT pin/reuse the old joiner_secret — it derives a fresh one per epoch.
        assert_ne!(js1, js2, "a fresh joiner_secret per epoch — the old one is not pinned");
        // A Welcome carrying the epoch-1 joiner_secret keys only epoch-1 material, which is superseded
        // at the live epoch: retaining it past the epoch admits no one at epoch 2.
        assert_ne!(root1, root2, "the epoch-1 Welcome material does not key the live epoch (retention bounded)");
    }

    /// §9 M5 / §6.3-4 — the re-seal lane is not a hidden long-lived archive key. History authored at
    /// epoch 0 is re-sealed under the CURRENT epoch on every full bundle; after enough weekly
    /// rotations the epoch-0 key is PRUNED (deleted) from the author, yet a peer still reads the old
    /// post — because it rides the current epoch key, exactly as §6.1 claims, with no archive key
    /// preserving old-epoch readability.
    #[test]
    fn fs_bug_4_reseal_reads_history_under_the_current_epoch_only() {
        let a = HavenSocial::new([92u8; 32].to_vec()).unwrap();
        let b = HavenSocial::new([93u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        a.add_contact_bundle(cid.clone(), b.my_bundle()).unwrap();
        b.add_contact_bundle(cid.clone(), a.my_bundle()).unwrap();
        with_clock_advanced(0, || {
            a.post(cid.clone(), "authored-at-epoch-0".into(), vec![], None, None, false, false, 1).unwrap();
            sync(&a, &b, &cid);
            sync(&a, &b, &cid);
            assert!(
                b.feed(cid.clone(), 10_000, None).iter().any(|m| m.body == "authored-at-epoch-0"),
                "control: the post is readable at epoch 0",
            );
        });
        // Roll the clock forward one week at a time so a full bundle rotates once per step (each stamps
        // `rotated_at`), past the KEEP_EPOCHS window — this DELETES the epoch-0 key from the author.
        for wk in 1..=6u64 {
            with_clock_advanced(ROTATE_INTERVAL_SECS * wk + 1, || {
                sync(&a, &b, &cid);
                sync(&a, &b, &cid);
            });
        }
        let epoch_now = a.state.lock().unwrap().circles[0].my_epoch;
        assert!(epoch_now >= 5, "the author rotated well past the 4-epoch window (was {epoch_now})");
        assert!(
            !a.state.lock().unwrap().circles[0].my_epoch_keys.contains_key(&0),
            "the epoch-0 key is genuinely DELETED — no long-lived archive key survives",
        );
        // Yet the epoch-0 post is still readable: it was re-sealed under the CURRENT epoch each bundle.
        assert!(
            b.feed(cid.clone(), 10_000, None).iter().any(|m| m.body == "authored-at-epoch-0"),
            "history re-sealed under the current epoch stays readable after the old key is deleted",
        );
    }

    /// §9 M5 / §6.3-5 — `merge_circle` (import) UNIONS epoch keys, then RE-PRUNES, so a stale exported
    /// blob carrying keys the pruner already deleted cannot resurrect the window past KEEP_EPOCHS = 4.
    #[test]
    fn fs_bug_5_merge_does_not_resurrect_pruned_epoch_keys() {
        let _clk = clock_guard();
        let a = HavenSocial::new([94u8; 32].to_vec()).unwrap();
        let b = HavenSocial::new([95u8; 32].to_vec()).unwrap();
        let cid = DEFAULT_CIRCLE.to_string();
        a.add_contact_bundle(cid.clone(), b.my_bundle()).unwrap();
        b.add_contact_bundle(cid.clone(), a.my_bundle()).unwrap();
        a.post(cid.clone(), "seed".into(), vec![], None, None, false, false, 1).unwrap();

        // Craft an OLD exported blob whose circle carries SIX epoch keys — as if it predates a prune
        // or was unioned across devices — well past the 4-epoch window.
        let mut ps: PersistState = serde_json::from_slice(&a.export_state()).unwrap();
        let ci = ps.circles.iter().position(|c| c.id == cid).unwrap();
        ps.circles[ci].my_epoch_keys = (10u64..16).map(|e| (e, [e as u8; 32])).collect();
        let blob = serde_json::to_vec(&ps).unwrap();

        // A fresh instance (same identity) imports the stale blob; the union is immediately re-pruned.
        let c = HavenSocial::new([94u8; 32].to_vec()).unwrap();
        c.import_state(blob);
        let keys: Vec<u64> = {
            let st = c.state.lock().unwrap();
            let cc = st.circles.iter().find(|cc| cc.id == cid).unwrap();
            cc.my_epoch_keys.keys().copied().collect()
        };
        assert_eq!(keys.len(), 4, "import unions then RE-PRUNES: the retained window stays 4, no resurrection");
        assert!(!keys.contains(&10) && !keys.contains(&11), "the oldest injected epochs are NOT resurrected");
        assert!(keys.contains(&14) && keys.contains(&15), "the newest epochs within the window are retained");
    }
}
