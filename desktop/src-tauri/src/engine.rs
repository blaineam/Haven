//! The desktop counterpart of the iOS `FeedStore` / Android `HavenNet` networking core:
//! owns the [`HavenSocial`] engine and the [`HavenNode`] iroh transport, speaks the
//! byte-exact [`crate::wire`] protocol, drives the Hello/Event handshake, persists state,
//! and runs the circle relay/mailbox so a Windows PC forms circles and exchanges posts
//! with an iPhone or Android phone.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use base64::Engine as _; // for `.encode` on the base64 engine (this module's `Engine` is unrelated)
use haven_ffi::{
    parse_link, Account, CircleUpgradeOffer, FeedItemFfi, HavenNode, HavenSocial, InboundListener,
    RelayClient, RelayServerHandle, TrackRefFfi,
};
use haven_s3::{S3Config, S3Mailbox};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex as TokioMutex;

use crate::callwire;
use crate::localmedia::LocalMedia;
use crate::store::{self, Contact, Paths, Prefs, Profile};
use crate::wire;

pub const DEFAULT_CIRCLE: &str = "default";

/// The push Worker — also hosts the content-free moderation ledger (`/flag`).
pub const PUSH_RELAY: &str = "https://haven-push.blaineams3.workers.dev";

/// One configured relay's full state for the Relays hub UI (active + inactive).
#[derive(Clone)]
pub struct RelayDetail {
    pub node_hex: String,
    pub name: String,
    pub active: bool,
    pub is_s3: bool,
    pub is_default: bool,
    pub hosted: bool,
    pub reachable: bool,
}

/// Someone who said hello but we haven't approved yet.
#[derive(Clone)]
pub struct PendingRequest {
    pub id_hex: String,
    pub name: String,
    pub verify_hex: String,
    pub bundle: Vec<u8>,
}

#[derive(Default)]
struct DynState {
    pending: Vec<PendingRequest>,
    /// node ids we initiated a connect to (scanned their QR) → expected verify hash.
    initiated: HashMap<String, String>,
    /// Mailbox keys already ingested or confirmed uploaded — PERSISTED to `mailbox-seen.txt`
    /// (loaded at engine start, flushed after each poll/backfill that added keys). In-memory
    /// only, every cold start re-pulled + re-verified the ENTIRE mailbox — thousands of
    /// duplicate envelopes on a mature circle, all burned on crypto the engine then dropped.
    seen_mailbox: HashSet<String>,
    /// seen_mailbox holds keys not yet flushed to disk.
    seen_mailbox_dirty: bool,
    /// ref -> partial chunks while a media transfer is in flight.
    incoming_media: HashMap<String, IncomingMedia>,
    requested_refs: HashSet<String>,
    /// ref -> last direct (peer) media-request ms. THROTTLE: a missing ref must not be re-blasted to
    /// every contact on every sweep (that floods the network with hundreds of thousands of frames and
    /// buries real delivery — the iOS "nothing communicates" flood). The relay/mailbox restore is the
    /// real, idempotent path; direct peer re-requests are capped + cooled-down to fill gaps only.
    media_req_at: HashMap<String, u64>,
    /// last time we mirrored our OWN media to the circle relays (idempotent backfill, ~every 2 min).
    last_media_backfill_ms: u64,
    /// last time we TOUCH-refreshed our event envelopes on the circle relays (mailbox-GC liveness,
    /// daily). In-memory: 0 at start → first loop tick refreshes, then every 24h of uptime.
    last_event_refresh_ms: u64,
    /// "<circle>:<item id>" keys already notified about — PERSISTED to `notified.txt` so a
    /// relaunch can't re-notify the same message (see notify_circle).
    notified: HashSet<String>,
    notified_dirty: bool,
    /// "<dest>|<ref>" pairs whose media blob is CONFIRMED on that destination (relay node hex, or
    /// "s3") — PERSISTED to `media-backed-up.txt`. Media keys are content-addressed so a confirmed
    /// upload is permanent (no staleness). Without this, every 2-min backfill re-read each of MY
    /// media files from disk into RAM (a 600 MB video per pass) and re-uploaded blobs the relays
    /// already held. iOS `MediaBackupLedger` / Android `backedUp` parity.
    media_backed_up: HashSet<String>,
    media_backed_up_dirty: bool,
    internet_active: bool,
    relay_active: bool,
    started: bool,
    hosting: bool,
    foreground: bool,
    /// Coalesces overlapping self-sync passes (the loop must never run two at once).
    self_syncing: bool,
    /// Adaptive sync cadence (device-heat control) — see start_mailbox_loop. `last_activity_ms` is
    /// stamped by bump_activity on any real activity (foreground, an authored post, an arriving
    /// message, a peer connecting); the two due timestamps gate the expensive poll/fan-out work so an
    /// idle app backs off (sync 20s->60s->120s, poll 30s->90s->180s). iOS FeedStore parity (build 178).
    last_activity_ms: u64,
    next_sync_due_ms: u64,
    next_poll_due_ms: u64,
    /// #4 local-limit sweep throttle: last run (ms) + in-flight guard, so the age/size cap enforcement
    /// runs at most ~every 10 min off the sync tick (a `force` from a settings change bypasses the
    /// throttle). iOS `FeedStore.lastLimitSweepAt` / `limitSweepInFlight`.
    last_limit_sweep_ms: u64,
    limit_sweep_in_flight: bool,
}

/// Where a self-sync slot can be read/written: a Haven relay (by node hex) or the user's S3.
enum SelfSyncTransport {
    Relay(String),
    S3(Arc<S3Mailbox>),
}

struct IncomingMedia {
    total: u32,
    chunks: HashMap<u32, Vec<u8>>,
}

/// One row of the #1 "Manage media" cleanup screen: a stored blob, its size, and the post/DM it
/// belongs to (best-effort). `is_orphan` = no live event references it (free to delete). `is_pinned`
/// = kept on this device (shown ineligible for cleanup). The command layer serializes this for the UI.
pub struct MediaRow {
    /// The on-disk storage name (bare hash) — also the handle passed back to pin/delete/download.
    pub reference: String,
    pub bytes: u64,
    pub mtime_ms: u64,
    /// "image" | "video" | "audio".
    pub kind: &'static str,
    pub circle_name: String,
    pub snippet: Option<String>,
    pub is_orphan: bool,
    pub is_pinned: bool,
}

/// PRIMARY side: a minted enrollment ticket kept in memory until it's consumed or expires. The
/// `secret` keys both handshake MACs; `consumed` guards single-use once a grant is sent.
struct PendingEnrollTicket {
    secret: [u8; 32],
    issued_at: u64,
    consumed: bool,
}

/// PRIMARY side: a frame-28 request that passed MAC + freshness, waiting on the user's confirm sheet.
#[derive(Clone)]
struct PendingEnrollRequest {
    /// The requesting device's full public bundle.
    device_bundle: Vec<u8>,
    /// The requesting device's transport node id hex (the frame-29 dial target).
    device_hex: String,
    /// The device name it advertised (shown in the confirm sheet).
    name: String,
    /// The ticket secret this request authenticated against (MACs the grant).
    secret: [u8; 32],
}

pub struct Engine {
    /// The account master seed — `Some` on a primary/legacy device, `None` on a SEEDLESS device
    /// (seed-drop S4). Making it an `Option` turns every account-key use into a compile-checked
    /// decision, so a missed seedless guard is a build error, not a runtime forge/panic.
    seed: Option<[u8; 32]>,
    social: Arc<HavenSocial>,
    paths: Paths,
    media: LocalMedia,
    app: StdMutex<Option<AppHandle>>,
    node: StdMutex<Option<Arc<HavenNode>>>,
    relay_host: StdMutex<Option<Arc<RelayServerHandle>>>,
    prefs: StdMutex<Prefs>,
    dyn_state: StdMutex<DynState>,
    scheduled: StdMutex<crate::scheduled::ScheduledStore>,
    roster: StdMutex<crate::roster::DeviceRoster>,
    /// Device-local seedless state (account public bundle + granted self-sync key + verbatim roster).
    /// `enabled=false` on a primary/legacy device.
    seedless: StdMutex<crate::roster::Seedless>,
    /// PRIMARY side: live `haven-enroll:` tickets awaiting a frame-28 request (in-memory, short-lived).
    enroll_tickets: StdMutex<Vec<PendingEnrollTicket>>,
    /// PRIMARY side: verified frame-28 requests awaiting the user's confirm (surfaced to the UI).
    enroll_requests: StdMutex<Vec<PendingEnrollRequest>>,
    sched_counter: std::sync::atomic::AtomicU64,
    /// True while a contact-roster pull pass is running, and when each contact was last ASKED.
    /// Both bound the pull: a contact whose roster is on NO relay never becomes resolvable, so
    /// without them the sync tick re-dials them forever, passes overlap, and iroh answers the
    /// resulting dial storm with unbounded path-discovery churn. It took a Mac to 28 GB.
    roster_pull_in_flight: std::sync::atomic::AtomicBool,
    roster_pull_at: StdMutex<HashMap<String, std::time::Instant>>,
    relay_clients: TokioMutex<HashMap<String, Arc<RelayClient>>>,
    /// Per-relay backoff health, keyed by node hex — drives graceful fallback.
    relay_health: StdMutex<HashMap<String, crate::relayhealth::RelayHealth>>,
    s3: TokioMutex<Option<Arc<S3Mailbox>>>,
    /// Client for relays' plain-HTTP media interfaces — the DEFAULT cross-NAT media transport.
    http: reqwest::Client,
    /// HTTP relay URLs that recently failed to answer → retry-after epoch ms (2-min backoff), so a
    /// dead LAN address doesn't cost a connect-timeout per chunk.
    http_url_bad: StdMutex<HashMap<String, u64>>,
    /// Frame-9 mesh-relay msgIds already seen (dedup / loop protection, parity with iOS seenRelay).
    seen_relay: StdMutex<std::collections::HashSet<String>>,
    /// Circles whose expired events were already really-purged this app session (purging is
    /// idempotent; once per session is plenty — see `maybe_purge_expired_media`).
    media_purged: StdMutex<std::collections::HashSet<String>>,
    /// Relays that refused us since our roster last reached them (see `note_refused`).
    roster_needed: StdMutex<std::collections::HashSet<String>>,
    /// Last `heal_forbidden_relays` publish, epoch ms — rate-limits the self-heal to one per 30s.
    last_heal_ms: StdMutex<u64>,
    /// Relays that already hold this exact roster: node → (wire content hash, confirmed at epoch ms).
    /// A roster is ~30 KB and this ran against every relay on every sync tick regardless of change —
    /// which is what produced `relay put timed out` / ConnectionLost. See `publish_device_roster`.
    roster_published: StdMutex<HashMap<String, (u64, u64)>>,
}

/// Why a relay HTTP request failed. The two demand OPPOSITE remedies — a dead endpoint should be
/// backed off, a refusal should trigger a device-roster publish and a retry — and folding them
/// together is what made a permissions problem present as MISSING media: the 403 became a plain
/// failure, the relay was marked bad and skipped, and the blob was reported absent while it sat on
/// that relay's disk the whole time. Mirrors iOS `SharedStore.RelayForbidden`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RelayErr {
    Unreachable,
    Forbidden,
}

/// Peer-to-peer iroh frame chunk — 32 KB, matching iOS/Android (`HavenNet.kt:2173`). Theirs is the
/// deliberate number: larger frames overflowed the reliable-send buffer on a BLE-only nearby link
/// and were silently dropped. Desktop has no BLE, so 512 KB was never wrong here — but it was
/// unintentional, and one number means one tested reassembly path instead of a desktop-only size
/// mobile receivers never see from each other. The cost is the per-chunk hybrid-KEM seal (~1.1 KB of
/// ML-KEM ct + ephemeral pubkey): ~3.5% overhead at 32 KB vs ~0.2% at 512 KB. Mobile already pays it
/// on far weaker hardware, and a few % on a LAN/QUIC transfer is worth cross-platform uniformity.
const MEDIA_CHUNK_SIZE: usize = 32 * 1024;
/// Relay/S3 media chunk size — 8 MB, well under blobstore's MAX_BLOB (256 MB) and memory-safe.
/// (Distinct from MEDIA_CHUNK_SIZE above, which is the peer-to-peer iroh frame chunk.)
const MEDIA_CHUNK_BYTES: usize = 8 * 1024 * 1024;
/// 9-byte ASCII magic marking a chunk manifest blob. A sealed envelope is JSON starting with '{',
/// so it can never collide. Must be byte-identical across iOS/macOS + Android.
const MEDIA_MANIFEST_MAGIC: &[u8] = b"HVCHUNK1\n";
/// The marker an owned circle's id carries. The core mints and verifies these ids — nothing here
/// should ever try to construct one; this only tells "already owned" from "still legacy".
const OWNED_CIRCLE_PREFIX: &str = "c1";

fn hex_to_bytes32(hex: &str) -> Option<Vec<u8>> {
    if hex.len() != 64 {
        return None;
    }
    (0..32).map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()).collect()
}

fn bytes_to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The payload of a `data:` URL, or the string unchanged if it isn't one. The frontend stores
/// avatars as `data:image/jpeg;base64,…` (that's what `img src` wants), but the profile card on the
/// wire is bare base64 — iOS feeds it straight to `Data(base64Encoded:)`, which rejects the prefix.
fn raw_base64(s: &str) -> String {
    match s.split_once(";base64,") {
        Some((head, payload)) if head.starts_with("data:") => payload.to_string(),
        _ => s.to_string(),
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The exact `/flag` body desktop POSTs for a report — pure, so a test can sign one and put it on
/// the wire without a live engine. `None` = we can't sign, so we don't send (an unsigned flag is
/// just a 401).
///
/// Signed with the identity key (audit F1): TERMS.md attaches real consequences to a ledger row, so
/// an unsigned POST must not be able to plant one. The signed material binds subject + action +
/// category, so a captured flag can't be re-aimed at someone else. It reuses the one
/// purpose-specific signer core exposes rather than growing a second (no raw signing oracle, audit
/// H3), and `flag-v1:…` is deliberately non-hex — that's what keeps it disjoint from the
/// `/register` token space, which the worker's `hexToken` enforces. Parity with ReportUI.swift and
/// Moderation.kt.
fn flag_body(seed: &[u8; 32], subject: &str, reason: &str, ts: u64) -> Option<serde_json::Value> {
    if subject.is_empty() {
        return None;
    }
    let acct = Account::from_seed(seed.to_vec()).ok()?;
    let category: String = reason.chars().take(64).collect(); // category only, as the worker slices it
    let sig = acct.sign_push_registration(format!("flag-v1:{subject}:report:{category}"), ts);
    Some(serde_json::json!({
        // The worker verifies against `actor` (a node id IS the Ed25519 public key it checks) but
        // stores no actor — the "A reported B" edge never lands in KV. Sent, never recorded.
        "actor": acct.node_id_hex(),
        "subject": subject,
        "action": "report",   // report-only server-side: a block is unrepresentable here
        "reason": category,
        "ts": ts,
        "sig": base64::engine::general_purpose::STANDARD.encode(sig),
    }))
}

/// NEW DEVICE onboarding for a seedless link (seed-drop S4): parse a scanned/pasted `haven-enroll:`
/// ticket, register a seedless identity (keyed by the account node id, NO account seed), mint this
/// device's stable transport key, and persist the linking state. The caller then relaunches — the
/// GUI boot resolver picks `Engine::new_seedless`, which brings up the handshake. Runs with no engine
/// (parity with `onboard_link` for the legacy seed path).
pub fn onboard_seedless(ticket_text: &str) -> std::result::Result<(), String> {
    let ticket = haven_ffi::enroll::enroll_ticket_parse(ticket_text.trim().to_string())
        .map_err(|e| format!("not a valid device-link code: {e}"))?;
    if ticket.account_id.len() != 32 || ticket.secret.len() != 32 || ticket.primary_device.len() != 32 {
        return Err("device-link code is malformed".into());
    }
    // Reject an expired ticket up front (10-min TTL; clock skew earlier than issue is NOT expired).
    let now = now_ms() / 1000;
    if now > ticket.issued_at && now.saturating_sub(ticket.issued_at) > 600 {
        return Err("this link has expired — generate a fresh one on your other device".into());
    }
    let account_hex = bytes_to_hex(&ticket.account_id);
    let base = Paths::resolve().map_err(|e| e.to_string())?;
    let mut ids = store::Identities::load(&base);
    ids.add(&account_hex, "Linked device (seedless)");
    ids.save(&base).map_err(|e| e.to_string())?;
    let entry_dir = ids.find(&account_hex).map(|e| e.dir.clone()).unwrap_or_default();
    let paths = Paths::resolve_for(&entry_dir).map_err(|e| e.to_string())?;
    // Mint (or load) this device's stable transport key in the identity's data dir.
    let _ = crate::roster::DeviceRoster::load(&paths);
    // Persist the seedless LINKING state (0600). The grant acceptance is the only writer that flips
    // `linked` and installs the account bundle / self-sync key.
    let mut s = crate::roster::Seedless::load(&paths);
    s.enabled = true;
    s.linked = false;
    s.relays = ticket.relays.clone();
    s.pending_ticket = Some(crate::roster::PendingTicketRec {
        account_id: ticket.account_id.clone(),
        verification: ticket.verification.clone(),
        secret: ticket.secret.clone(),
        primary_device: ticket.primary_device.clone(),
        issued_at: ticket.issued_at,
        relays: ticket.relays.clone(),
    });
    s.save(&paths).map_err(|e| e.to_string())?;
    Ok(())
}

impl Engine {
    /// Build the engine for an existing or freshly-created seed. Loads prefs + restores state.
    pub fn new(paths: Paths, seed: [u8; 32]) -> Result<Arc<Self>> {
        let social = HavenSocial::new(seed.to_vec())
            .map_err(|e| anyhow::anyhow!("HavenSocial::new: {e}"))?;
        if let Some(state) = store::read_state(&paths) {
            social.import_state(state);
        }
        let prefs = Prefs::load(&paths);
        let media = LocalMedia::new(paths.media_dir());
        let scheduled = crate::scheduled::ScheduledStore::load(&paths.scheduled_file());
        let roster = crate::roster::DeviceRoster::load(&paths);
        // Engine acts under this device's UNIQUE transport identity (parity with iOS configure() /
        // Android init): the account id stays the sealing/trust anchor + the contact handle friends
        // pin; friends resolve it to this device's node id via the signed roster (frame 27), so any
        // number of devices can run under one account without colliding on iroh discovery.
        let _ = social.use_device_identity(roster.device_seed.clone());
        let _ = social.register_device(
            roster.device_bundle(),
            crate::roster::DeviceRoster::device_name(),
            now_ms() / 1000,
        );
        // Switch-Flip 1.0.7: turn the new crypto ON (seed-drop retirement + MLS keying). Both are
        // GATED in-core — inert (byte-identical to 1.0.6) until a circle is fully capable — and NOT
        // persisted, so they're set here after `register_device` and re-applied every launch in
        // `reapply_crypto_switches` (start()). Docs: `docs/SWITCH-FLIP-1.0.7.md` §3/§4.
        social.set_mls_keying(true);
        social.set_seed_drop_retire(true);
        let dyn_state = DynState {
            seen_mailbox: std::fs::read_to_string(paths.root.join("mailbox-seen.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            notified: std::fs::read_to_string(paths.root.join("notified.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            media_backed_up: std::fs::read_to_string(paths.root.join("media-backed-up.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            ..DynState::default()
        };
        Ok(Arc::new(Self {
            seed: Some(seed),
            social,
            paths,
            media,
            app: StdMutex::new(None),
            node: StdMutex::new(None),
            relay_host: StdMutex::new(None),
            prefs: StdMutex::new(prefs),
            dyn_state: StdMutex::new(dyn_state),
            scheduled: StdMutex::new(scheduled),
            roster: StdMutex::new(roster),
            seedless: StdMutex::new(crate::roster::Seedless::default()),
            enroll_tickets: StdMutex::new(Vec::new()),
            enroll_requests: StdMutex::new(Vec::new()),
            sched_counter: std::sync::atomic::AtomicU64::new(0),
            roster_pull_in_flight: std::sync::atomic::AtomicBool::new(false),
            roster_pull_at: StdMutex::new(HashMap::new()),
            relay_clients: TokioMutex::new(HashMap::new()),
            relay_health: StdMutex::new(HashMap::new()),
            s3: TokioMutex::new(None),
            http: reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(4))
                .build()
                .unwrap_or_default(),
            http_url_bad: StdMutex::new(HashMap::new()),
            seen_relay: StdMutex::new(std::collections::HashSet::new()),
            media_purged: StdMutex::new(std::collections::HashSet::new()),
            roster_needed: StdMutex::new(std::collections::HashSet::new()),
            last_heal_ms: StdMutex::new(0),
            roster_published: StdMutex::new(HashMap::new()),
        }))
    }

    /// Build the engine for a **SEEDLESS** identity (seed-drop S4): no account master seed. The account
    /// identity is the granted PUBLIC bundle; this device authors + opens under its own device key plus
    /// the account-signed credential. Two sub-states, both handled here:
    ///   - **linked** (`seedless.account_bundle` present): `new_seedless(account_bundle, device_seed)`,
    ///     ingest the primary-signed roster wire verbatim (A3), run with the granted self-sync key.
    ///   - **linking** (bundle not yet granted): a provisional engine under the device's own bundle so
    ///     the transport comes up and the frame-28 request can be sent; it flips to linked on frame-29.
    /// `register_device` + push registration are always SKIPPED (A1: only the primary authors a roster).
    pub fn new_seedless(paths: Paths) -> Result<Arc<Self>> {
        let roster = crate::roster::DeviceRoster::load(&paths);
        let seedless = crate::roster::Seedless::load(&paths);
        // Linked: the real account bundle; linking: a placeholder (the device's own bundle) so the
        // constructor's invariants hold — it's never used to seal real content before the relaunch.
        let account_bundle = if seedless.account_bundle.len() >= 32 {
            seedless.account_bundle.clone()
        } else {
            roster.device_bundle()
        };
        let social = HavenSocial::new_seedless(account_bundle, roster.device_seed.clone())
            .map_err(|e| anyhow::anyhow!("HavenSocial::new_seedless: {e}"))?;
        if let Some(state) = store::read_state(&paths) {
            social.import_state(state);
        }
        // Rebroadcast the primary's roster wire VERBATIM (A3) — installs our credential + capability
        // trailer without re-signing (a seedless device cannot mint a roster).
        if seedless.linked && !seedless.roster_wire.is_empty() {
            let _ = social.ingest_roster_wire(seedless.roster_wire.clone());
        }
        // Switch-Flip 1.0.7 (seedless): the keying + retirement gates are computed fleet-wide, so a
        // seedless device flips the same master switches (both gated in-core). It never performs a
        // primary-only op — no `register_device`, `retire_account_leaf`, or roster re-sign.
        social.set_mls_keying(true);
        social.set_seed_drop_retire(true);
        let prefs = Prefs::load(&paths);
        let media = LocalMedia::new(paths.media_dir());
        let scheduled = crate::scheduled::ScheduledStore::load(&paths.scheduled_file());
        // NB: NO register_device — the primary is the sole roster authority (guarded in-core too, but
        // we never even call it here). The transport still binds to the device seed in `start()`.
        let dyn_state = DynState {
            seen_mailbox: std::fs::read_to_string(paths.root.join("mailbox-seen.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            notified: std::fs::read_to_string(paths.root.join("notified.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            media_backed_up: std::fs::read_to_string(paths.root.join("media-backed-up.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            ..DynState::default()
        };
        Ok(Arc::new(Self {
            seed: None,
            social,
            paths,
            media,
            app: StdMutex::new(None),
            node: StdMutex::new(None),
            relay_host: StdMutex::new(None),
            prefs: StdMutex::new(prefs),
            dyn_state: StdMutex::new(dyn_state),
            scheduled: StdMutex::new(scheduled),
            roster: StdMutex::new(roster),
            seedless: StdMutex::new(seedless),
            enroll_tickets: StdMutex::new(Vec::new()),
            enroll_requests: StdMutex::new(Vec::new()),
            sched_counter: std::sync::atomic::AtomicU64::new(0),
            roster_pull_in_flight: std::sync::atomic::AtomicBool::new(false),
            roster_pull_at: StdMutex::new(HashMap::new()),
            relay_clients: TokioMutex::new(HashMap::new()),
            relay_health: StdMutex::new(HashMap::new()),
            s3: TokioMutex::new(None),
            http: reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(4))
                .build()
                .unwrap_or_default(),
            http_url_bad: StdMutex::new(HashMap::new()),
            seen_relay: StdMutex::new(std::collections::HashSet::new()),
            media_purged: StdMutex::new(std::collections::HashSet::new()),
            roster_needed: StdMutex::new(std::collections::HashSet::new()),
            last_heal_ms: StdMutex::new(0),
            roster_published: StdMutex::new(HashMap::new()),
        }))
    }

    /// True on a seedless device (no account master seed). Drives the enroll / self-sync-grant flow.
    pub fn is_seedless(&self) -> bool {
        self.seed.is_none()
    }

    /// (seedless, linked, linking) for the UI — `linking` = seedless but the grant hasn't landed yet.
    pub fn seedless_status(&self) -> (bool, bool, bool) {
        let seedless = self.is_seedless();
        let linked = self.seedless.lock().unwrap().linked;
        (seedless, linked, seedless && !linked)
    }

    /// The self-sync key: derived from the account seed on a primary/legacy device, or the granted
    /// 32-byte key on a seedless device. `None` on a seedless device whose grant hasn't landed yet.
    fn self_sync_key(&self) -> Option<[u8; 32]> {
        match &self.seed {
            Some(seed) => Some(haven_p2p::identity::Identity::from_seed(seed).self_sync_key()),
            None => self.seedless.lock().unwrap().self_sync_key32(),
        }
    }

    pub fn set_app(&self, app: AppHandle) {
        *self.app.lock().unwrap() = Some(app);
    }

    pub fn set_foreground(&self, fg: bool) {
        self.dyn_state.lock().unwrap().foreground = fg;
        if fg {
            self.bump_activity(); // back to foreground → snap sync cadence tight
        }
    }

    fn emit_changed(&self) {
        if let Some(app) = self.app.lock().unwrap().clone() {
            let _ = app.emit("haven:changed", ());
        }
    }

    fn notify(&self, title: &str, body: &str) {
        if self.dyn_state.lock().unwrap().foreground {
            return;
        }
        if let Some(app) = self.app.lock().unwrap().clone() {
            // Native OS notification (Action Center / toast)…
            use tauri_plugin_notification::NotificationExt;
            let _ = app.notification().builder().title(title).body(body).show();
            // …and an in-app event for a toast if a window is open.
            let _ = app.emit("haven:notify", serde_json::json!({ "title": title, "body": body }));
        }
    }

    // ---- identity / profile -----------------------------------------------------------

    pub fn node_id_hex(&self) -> String {
        self.social.my_node_hex()
    }

    /// The account's reach-me `HavenLink`, derived from its PUBLIC bundle. Works without the account
    /// seed (a seedless device shares the same account id), so it's built from the bundle either way.
    fn reach_link(&self) -> Option<haven_p2p::link::HavenLink> {
        let bundle = self.account_bundle();
        if bundle.len() < 32 {
            return None;
        }
        let id = haven_p2p::identity::HavenId::from_bytes(&bundle).ok()?;
        Some(haven_p2p::link::HavenLink::from_identity(&id))
    }

    pub fn invite_uri(&self) -> String {
        let base = self.reach_link().map(|l| l.to_uri()).unwrap_or_default();
        self.embed_invite_hints(base)
    }

    pub fn invite_link(&self, domain: &str) -> String {
        let base = self.reach_link().map(|l| l.to_web(domain)).unwrap_or_default();
        self.embed_invite_hints(base)
    }

    // ---- invite device-id hints (roster-bootstrap bridge) --------------------------------
    //
    // Under the device-seed transport a friend's ACCOUNT id resolves to no node, and their signed
    // roster (frame 27) can only arrive over a path that itself needs a device id — the bootstrap
    // deadlock. The invite link therefore carries my device node id(s) as a `?d=` query BEFORE the
    // `#` fragment (an old parser reads only the fragment, so the link stays compatible); the
    // scanner dials the hints until the real roster supersedes them. Mirrors iOS/Android.

    /// Insert `?d=<my device ids>` before the link's `#` fragment.
    fn embed_invite_hints(&self, link: String) -> String {
        let acct = self.social.my_node_hex().to_lowercase();
        let mut ids: Vec<String> = vec![self.social.my_device_node_hex()];
        for d in self.social.device_node_ids_for(acct.clone()) {
            let l = d.to_lowercase();
            if l != acct && !ids.iter().any(|i| i.to_lowercase() == l) {
                ids.push(d);
            }
        }
        ids.retain(|i| i.len() == 64);
        ids.truncate(4);
        let Some(hash) = link.find('#') else { return link };
        if ids.is_empty() || link.contains('?') {
            return link;
        }
        format!("{}?d={}{}", &link[..hash], ids.join(","), &link[hash..])
    }

    /// The `d=` device ids from a pasted/scanned link (empty when absent). Only 64-hex ids pass.
    fn extract_invite_hints(link: &str) -> Vec<String> {
        let Some(q_start) = link.find('?') else { return vec![] };
        let end = link.find('#').unwrap_or(link.len());
        if q_start >= end {
            return vec![];
        }
        for pair in link[q_start + 1..end].split('&') {
            let Some((k, v)) = pair.split_once('=') else { continue };
            if k != "d" {
                continue;
            }
            return v
                .split(',')
                .map(|s| s.to_lowercase())
                .filter(|s| s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit()))
                .take(4)
                .collect();
        }
        vec![]
    }

    /// Remember a contact's invite-hint device ids (dialed until their signed roster lands).
    fn record_device_hints(&self, account_hex: &str, ids: Vec<String>) {
        if ids.is_empty() {
            return;
        }
        let key = account_hex.to_lowercase();
        let mut p = self.prefs.lock().unwrap();
        let cur = p.device_hints.entry(key).or_default();
        for d in ids {
            if !cur.contains(&d) {
                cur.push(d);
            }
        }
        let excess = cur.len().saturating_sub(8);
        if excess > 0 {
            cur.drain(..excess);
        }
        let _ = p.save(&self.paths);
    }

    fn device_hints_for(&self, account_hex: &str) -> Vec<String> {
        self.prefs.lock().unwrap().device_hints.get(&account_hex.to_lowercase()).cloned().unwrap_or_default()
    }

    pub fn get_profile(&self) -> Profile {
        self.prefs.lock().unwrap().profile.clone()
    }

    pub fn set_profile(self: &Arc<Self>, profile: Profile) {
        {
            let mut p = self.prefs.lock().unwrap();
            // Stamp each field the user actually CHANGED (LWW), so a remote sibling edit only overrides
            // ours when it's newer. Mirrors iOS ProfileStore.stamp on each edited field.
            if p.profile.name != profile.name {
                p.stamp_profile_field("name");
            }
            if p.profile.emoji != profile.emoji {
                p.stamp_profile_field("emoji");
            }
            if p.profile.bio != profile.bio {
                p.stamp_profile_field("bio");
            }
            if p.profile.link != profile.link {
                p.stamp_profile_field("link");
            }
            p.profile = profile;
            let _ = p.save(&self.paths);
        }
        // Re-greet contacts so the new name/card propagates.
        self.sync_with_contacts();
        self.emit_changed();
    }

    // ---- multi-identity -----------------------------------------------------------------

    /// (node_hex, label, is_active) for every identity on this device.
    pub fn identities(&self) -> Vec<(String, String, bool)> {
        let ids = store::Identities::load(&self.paths);
        ids.items
            .iter()
            .map(|e| (e.node_hex.clone(), e.label.clone(), e.node_hex == ids.active))
            .collect()
    }

    /// Mint a brand-new identity (its seed goes to the secure store). Does not switch to it.
    pub fn add_identity(&self, label: &str) -> Result<String> {
        let acct = Account::generate();
        let seed: [u8; 32] = acct
            .secret_seed()
            .try_into()
            .map_err(|_| anyhow::anyhow!("generated seed not 32 bytes"))?;
        let hex = acct.node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        let mut ids = store::Identities::load(&self.paths);
        ids.add(&hex, label);
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(hex)
    }

    /// Adopt an existing identity from a 32-byte seed (e.g. a transfer from another device).
    pub fn import_identity(&self, label: &str, seed: [u8; 32]) -> Result<String> {
        let acct = Account::from_seed(seed.to_vec()).map_err(|e| anyhow::anyhow!("bad seed: {e}"))?;
        let hex = acct.node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        let mut ids = store::Identities::load(&self.paths);
        ids.add(&hex, label);
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(hex)
    }

    pub fn rename_identity(&self, node_hex: &str, label: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        if !ids.rename(node_hex, label) {
            return Err(anyhow::anyhow!("unknown identity"));
        }
        ids.save(&self.paths)?;
        self.emit_changed();
        Ok(())
    }

    /// Make `node_hex` the active identity. Mirrors its seed to the legacy `master-seed` so the
    /// headless relay follows it too. The caller must relaunch the app to rebuild the engine.
    pub fn set_active_identity(&self, node_hex: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        if !ids.set_active(node_hex) {
            return Err(anyhow::anyhow!("unknown identity"));
        }
        if let Some(seed) = store::load_identity_seed(node_hex)? {
            store::save_seed(&seed)?;
            // Switching to a DIFFERENT identity: clear the self-sync base so the rebuilt engine doesn't
            // diff the new (empty-until-synced) account against the old identity's base and tombstone it.
            store::remove_if_exists(&self.paths.selfsync_state_file());
        }
        ids.save(&self.paths)?;
        Ok(())
    }

    pub fn remove_identity(&self, node_hex: &str) -> Result<()> {
        let mut ids = store::Identities::load(&self.paths);
        match ids.remove(node_hex) {
            Some(dir) => {
                ids.save(&self.paths)?;
                store::delete_identity_seed(node_hex);
                if !dir.is_empty() {
                    let _ = std::fs::remove_dir_all(self.paths.base.join(dir));
                }
                self.emit_changed();
                Ok(())
            }
            None => Err(anyhow::anyhow!("cannot remove the active or an unknown identity")),
        }
    }

    // ---- start --------------------------------------------------------------------------

    /// Start the iroh node and begin syncing. Safe to call repeatedly.
    pub async fn start(self: &Arc<Self>) {
        {
            if self.node.lock().unwrap().is_some() {
                return;
            }
        }
        // Switch-Flip 1.0.7 §§2-5: re-apply the non-persisted crypto switches every launch (master
        // keying/retire + per-circle creator pin + DM live-lane). Cheap, gated in-core.
        self.reapply_crypto_switches();
        let listener: Arc<dyn InboundListener> = Arc::new(NodeListener {
            engine: Arc::downgrade(self),
        });
        // Bind the transport to the per-DEVICE seed (unique node/relay id per install, parity with
        // iOS/Android device-seed transport) — never the account id, which is identity-only.
        let device_seed = self.roster.lock().unwrap().device_seed.clone();
        match HavenNode::start(device_seed, listener).await {
            Ok(node) => {
                *self.node.lock().unwrap() = Some(node);
                self.dyn_state.lock().unwrap().started = true;
                self.emit_changed();
                self.sync_with_contacts();
                // Seedless LINKING device: fire the frame-28 request now that the transport is up (the
                // mailbox loop keeps re-sending until the grant lands).
                self.send_seedless_enroll_request();
                self.poll_mailbox().await;
                self.request_missing_media();
                // Launch-time media drain: finish uploading any of MY media a relay never received —
                // e.g. a story posted the instant before the app last closed, whose blob upload was cut
                // off mid-flight. The set of what still needs uploading is re-derived from the feed and
                // the confirmed-on-relay ledger is persisted (media-backed-up.txt, reloaded in
                // Engine::new), so this just re-attempts every not-yet-confirmed ref NOW instead of
                // waiting for the first ~10s sync tick — an unfinished upload can't sit stranded. Fully
                // idempotent (confirmed refs are skipped before any read). Mirrors iOS
                // MediaBackupQueue.drainPersisted / Android drainPersistedBackups.
                self.backfill_media_to_relays().await;
                self.dyn_state.lock().unwrap().last_media_backfill_ms = now_ms();
            }
            Err(e) => {
                log::error!("node start failed: {e}");
            }
        }
        // Switch-Flip 1.0.7 §1 migration: an existing multi-device upgrader sheds its legacy bare
        // account leaf ONCE (gated + idempotent) so the roster reaches the device-only shape live
        // keying + retirement require. No-op for a fresh device-only install or until fully capable.
        self.maybe_migrate_retire_account_leaf().await;
        self.maybe_reseal_own_media().await; // 1.0.8: overwrite my media a 1.0.7 build froze (once)
        self.reconcile_superseded_circles(); // collapse any upgraded/duplicated circle at launch (LWW tombstone)
        self.fire_due_scheduled(); // flush anything overdue from while the app was closed
        self.purge_stale_relays().await; // erase relays inactive AND unseen > 7 days (config else survives)
        self.maybe_weekly_media_sweep(); // orphaned media blobs (at most once a week; runs off-thread)
        self.enforce_local_limits(false); // #4 device-local age/size caps (throttled; no-op if both off)
        self.bump_activity(); // seed activity NOW so launch starts at tight cadence (idle=huge would else max-back-off)
        self.start_mailbox_loop();
    }

    // ---- Switch-Flip 1.0.7 crypto enablers (docs/SWITCH-FLIP-1.0.7.md) -------------------------

    /// Re-apply the NON-PERSISTED 1.0.7 crypto switches — the master keying/retirement switches
    /// (§3/§4), the per-circle creator pin (§2, for circles this device created), and the DM
    /// live-lane mark (§5). All are gated in-core, so this is a cheap no-op for content until a
    /// circle is fully capable. Called on every launch (start()) and after create/DM-open.
    fn reapply_crypto_switches(self: &Arc<Self>) {
        self.social.set_mls_keying(true);
        // Retirement is a fleet-wide gate; a seedless device flips it too (it never runs a
        // primary-only op). Both switches are inert until every member is affirmatively capable.
        self.social.set_seed_drop_retire(true);
        let my_hex = self.node_id_hex();
        let created: Vec<String> = self.prefs.lock().unwrap().created_circles.clone();
        for c in self.social.circles() {
            if c.id.starts_with("dm:") {
                self.pin_dm_authority(&c.id);
            } else if created.iter().any(|x| x == &c.id) {
                // §2: I am the authority root of the circles I created. The pin issues an
                // account-signed self-grant that propagates to members on the control lane.
                self.social.set_circle_creator(c.id.clone(), my_hex.clone());
            }
        }
    }

    /// §2 + §5 for a `dm:` circle: pin the creator DETERMINISTICALLY (both endpoints agree on the
    /// lexicographically-smallest member node hex encoded in the id) so admin authority is consistent,
    /// and mark it a LIVE LANE so — once keying-live — each message carries the per-message forward-
    /// secrecy ratchet. A no-op on content while the master switch / capability gate is unmet.
    fn pin_dm_authority(&self, circle_id: &str) {
        self.social.set_circle_live_lane(circle_id.to_string(), true);
        // "dm:<a>-<b>" (ids sorted at construction) → the first member is the deterministic creator.
        if let Some(first) = circle_id.trim_start_matches("dm:").split('-').next() {
            if first.len() == 64 {
                self.social.set_circle_creator(circle_id.to_string(), first.to_string());
            }
        }
    }

    /// §1 migration — shed the legacy bare `{account}` roster leaf exactly ONCE for an existing
    /// multi-device account, so the roster settles at the device-only shape live keying + retirement
    /// require (without it a migrated `{account, device}` roster is stranded permanently at `shadow`).
    /// Primary-only, gated + idempotent in-core: a no-op (returns false) until the fleet is fully
    /// device-capable and the retire switch is on. New device-only installs skip it (roster not
    /// enabled). Latched via a sticky prefs flag so it never churns once done.
    async fn maybe_migrate_retire_account_leaf(self: &Arc<Self>) {
        if self.seed.is_none() {
            return; // seedless never mints/re-signs a roster (A1)
        }
        // Only an EXISTING multi-device account carries the legacy bare-account leaf. A fresh
        // device-only install (roster never enabled) has nothing to retire.
        if !self.roster.lock().unwrap().is_enabled() {
            return;
        }
        if self.prefs.lock().unwrap().account_leaf_retired {
            return; // already migrated (sticky)
        }
        // Gated in-core: false until retire switch ON + own account seed-drop-capable + device
        // identity adopted. Safe to retry each launch; latch only once it actually succeeds.
        if self.social.retire_account_leaf() {
            {
                let mut p = self.prefs.lock().unwrap();
                p.account_leaf_retired = true;
                let _ = p.save(&self.paths);
            }
            // Rebroadcast the higher-version, device-only roster wire so contacts drop my account
            // leaf from their sealing set + tree (frame 27 to contacts + relays + the headless relay).
            self.sync_with_contacts();
            self.publish_device_roster().await;
            self.emit_changed();
            log::info!("account-leaf migration complete — roster is now device-only (1.0.7 §1)");
        }
    }

    /// 1.0.8 media recovery — run ONCE. A 1.0.7 build device-signed my posted media and, because a
    /// blob is content-addressed + write-once, froze it so friends could never open it. The core fix
    /// re-seals account-signed; this force-re-uploads my OWN media (only what I still hold the
    /// plaintext for) to overwrite the stale frozen blob on every reachable destination. Sticky latch,
    /// off the launch path. Mirrors iOS `MediaRecovery` / Android `runMediaRecoveryOnceIfNeeded`.
    async fn maybe_reseal_own_media(self: &Arc<Self>) {
        const MAX_ATTEMPTS: u32 = 10;
        if self.prefs.lock().unwrap().media_resealed_v108 {
            return;
        }
        // Enumerate my OWN posted media I STILL hold the plaintext for (the re-seal reads the original
        // file); anything the storage sweep cleared is gone and must not block the latch.
        let mut held: Vec<(String, String)> = vec![]; // (circle_id, ref)
        let mut seen: HashSet<String> = HashSet::new();
        for c in self.social.circles() {
            for item in self.social.feed(c.id.clone(), now_ms(), None) {
                if !item.is_me { continue; }
                for r in item.media {
                    if !LocalMedia::is_synthetic(&r) && self.media.has(&r) && seen.insert(r.clone()) {
                        held.push((c.id.clone(), r));
                    }
                }
                for cm in item.comments {
                    if !cm.is_me { continue; }
                    for r in cm.media {
                        if !LocalMedia::is_synthetic(&r) && self.media.has(&r) && seen.insert(r.clone()) {
                            held.push((c.id.clone(), r));
                        }
                    }
                }
            }
        }
        let mut done: HashSet<String> =
            self.prefs.lock().unwrap().media_reseal_refs.iter().cloned().collect();
        // Collect the not-yet-confirmed refs first so the loop can mutate `done` without holding an
        // immutable borrow of it through the filter iterator.
        let todo: Vec<(String, String)> =
            held.iter().filter(|(_, r)| !done.contains(r)).cloned().collect();
        for (circle_id, r) in &todo {
            // A destination accepted the fresh blob → this ref is repaired.
            if self.upload_media_inner(circle_id, r, true).await {
                done.insert(r.clone());
            }
        }
        let attempts = self.prefs.lock().unwrap().media_reseal_attempts + 1;
        // Latch when every repairable ref is confirmed, or after enough tries that a still-failing ref
        // is almost certainly un-repairable (its destination is gone / was never reachable).
        let latched = held.iter().all(|(_, r)| done.contains(r)) || attempts >= MAX_ATTEMPTS;
        {
            let mut p = self.prefs.lock().unwrap();
            p.media_reseal_refs = done.iter().cloned().collect();
            p.media_reseal_attempts = attempts;
            p.media_resealed_v108 = latched;
            let _ = p.save(&self.paths);
        }
        if !held.is_empty() {
            log::info!("media recovery: {}/{} authored blobs re-sealed + overwritten (attempt {attempts})", done.len(), held.len());
        }
    }

    /// Base cadence stretched by how long the app has sat idle. Idle <3min = base; <15min = ×3; else ×6.
    fn adaptive_interval(now: u64, last_activity_ms: u64, base: u64) -> u64 {
        let idle = now.saturating_sub(last_activity_ms);
        if idle < 180_000 {
            base
        } else if idle < 900_000 {
            base * 3
        } else {
            base * 6
        }
    }

    /// Mark "something is happening" → snap both timers back to their tight base cadence immediately.
    fn bump_activity(&self) {
        let mut st = self.dyn_state.lock().unwrap();
        st.last_activity_ms = now_ms();
        st.next_sync_due_ms = 0;
        st.next_poll_due_ms = 0;
    }

    // Adaptive sync cadence (device-heat control). The loop keeps a cheap 10s heartbeat, but the
    // EXPENSIVE work (mailbox poll, mesh dials, relay re-announce, media retry/backfill) only runs
    // when it's DUE. When the app is idle — foregrounded but nothing arriving/authored — the due
    // interval STRETCHES, so an idle machine isn't blasting the network every 15s (the main heat
    // source). Any real activity resets it to the tight base cadence (see bump_activity), and pushes
    // still wake the app for immediacy either way. iOS FeedStore parity: sync base 20s, poll base 30s.
    fn start_mailbox_loop(self: &Arc<Self>) {
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                let now = now_ms();
                // Scheduled posts are time-sensitive — check every heartbeat so they fire punctually
                // regardless of the adaptive back-off below (cheap: just compares due timestamps).
                me.fire_due_scheduled();

                // Poll bucket (base 30s): pull the circle mailbox so posts arrive even when peers
                // aren't both online, then converge this user's OWN devices over the same relays.
                let poll_due = {
                    let mut st = me.dyn_state.lock().unwrap();
                    if now >= st.next_poll_due_ms {
                        st.next_poll_due_ms = now + Self::adaptive_interval(now, st.last_activity_ms, 30_000);
                        true
                    } else {
                        false
                    }
                };
                if poll_due {
                    me.poll_mailbox().await;
                    me.poll_self_sync().await;
                }

                // Sync bucket (base 20s): the network fan-out that runs the radio hot, so it backs off
                // hardest when idle. Retry incomplete media (relay first, then peers), mesh-dial sibling
                // relays, re-emit our own relay id (frame 19 was a one-shot at relay start; no-op unless
                // we host), the ~2-min media backfill + daily mailbox refresh (own inner gates), and GC
                // relays inactive + unseen > 7 days.
                let sync_due = {
                    let mut st = me.dyn_state.lock().unwrap();
                    if now >= st.next_sync_due_ms {
                        st.next_sync_due_ms = now + Self::adaptive_interval(now, st.last_activity_ms, 20_000);
                        true
                    } else {
                        false
                    }
                };
                if sync_due {
                    // Seedless LINKING device: keep re-sending frame-28 until the primary grants (the
                    // handshake is idempotent; the primary de-dups a pending request by device hex).
                    me.send_seedless_enroll_request();
                    me.request_missing_media();
                    me.mesh_sync().await;
                    me.reannounce_own_relay();
                    // Mirror our own media to the relays we know periodically (~every 2 min). The
                    // cross-device chunk path is unreliable; the relay is the durable convergence path.
                    let backfill_due = {
                        let mut st = me.dyn_state.lock().unwrap();
                        if now - st.last_media_backfill_ms > 120_000 {
                            st.last_media_backfill_ms = now;
                            true
                        } else {
                            false
                        }
                    };
                    if backfill_due {
                        me.backfill_media_to_relays().await;
                        // Re-publish our signed device roster to every relay so a headless relay
                        // (which only knows account ids) keeps authorizing this account's device ids.
                        me.publish_device_roster().await;
                    }
                    // Daily (first sync tick after launch, then every 24h of uptime): re-assert my event
                    // envelopes in every circle mailbox — upload what a relay never saw, TOUCH what it
                    // already holds so relay-side mailbox GC (30-day TTL) keeps live entries while legacy
                    // duplicates and stale-epoch copies age out.
                    let refresh_due = {
                        let mut st = me.dyn_state.lock().unwrap();
                        if now - st.last_event_refresh_ms > 86_400_000 {
                            st.last_event_refresh_ms = now;
                            true
                        } else {
                            false
                        }
                    };
                    if refresh_due {
                        for c in me.social.circles() {
                            me.backfill_mailbox(&c.id).await;
                        }
                    }
                    me.purge_stale_relays().await; // GC relays inactive + unseen > 7 days (config else survives)
                }
            }
        });
    }

    /// If we're hosting a relay, pull from every sibling relay so the mailbox self-replicates
    /// across the mesh — any relay can then join/leave freely without losing the circle's data.
    async fn mesh_sync(self: &Arc<Self>) {
        let Some(host) = self.relay_host.lock().unwrap().clone() else { return };
        let my_hex = host.node_id_hex();
        let peers: std::collections::BTreeSet<String> = {
            let p = self.prefs.lock().unwrap();
            p.relays.values().flatten().filter(|h| p.relay_is_active(h)).cloned().collect()
        };
        for peer in peers {
            if peer == my_hex || !self.relay_available(&peer) {
                continue;
            }
            if host.sync_from(peer.clone()).await > 0 {
                self.mark_relay_ok(&peer);
                self.dyn_state.lock().unwrap().relay_active = true;
                self.emit_changed();
            }
        }
    }

    // ---- scheduled messages -------------------------------------------------------------

    fn persist_scheduled(&self) {
        let snap = self.scheduled.lock().unwrap().clone();
        let _ = snap.save(&self.paths.scheduled_file());
    }

    /// Queue a post or DM to be sent at `send_at_ms`. Returns the generated item id.
    pub fn schedule(
        self: &Arc<Self>,
        kind: crate::scheduled::SchedKind,
        circle_id: String,
        body: String,
        media: Vec<String>,
        music: Option<crate::scheduled::SchedTrack>,
        mute_video: bool,
        send_at_ms: u64,
    ) -> String {
        let n = self.sched_counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = format!("sch-{}-{n}", now_ms());
        let item = crate::scheduled::ScheduledItem {
            id: id.clone(),
            kind,
            circle_id,
            body,
            media,
            music,
            mute_video,
            send_at_ms,
            created_at_ms: now_ms(),
        };
        self.scheduled.lock().unwrap().add(item);
        self.persist_scheduled();
        self.emit_changed();
        id
    }

    pub fn list_scheduled(&self) -> Vec<crate::scheduled::ScheduledItem> {
        self.scheduled.lock().unwrap().items.clone()
    }

    pub fn cancel_scheduled(self: &Arc<Self>, id: &str) {
        let removed = self.scheduled.lock().unwrap().remove(id);
        if removed {
            self.persist_scheduled();
            self.emit_changed();
        }
    }

    /// Send everything whose time has arrived, then persist the remaining queue.
    pub fn fire_due_scheduled(self: &Arc<Self>) {
        let due = self.scheduled.lock().unwrap().take_due(now_ms());
        if due.is_empty() {
            return;
        }
        for it in due {
            let music = it.music.map(|m| TrackRefFfi {
                catalog_id: m.catalog_id,
                title: m.title,
                artist: m.artist,
                artwork_url: m.artwork_url,
                duration_ms: m.duration_ms,
            });
            match it.kind {
                crate::scheduled::SchedKind::Post => {
                    self.post(it.circle_id, it.body, it.media, music, it.mute_video);
                }
                crate::scheduled::SchedKind::Dm => {
                    self.send_dm(it.circle_id, it.body, it.media, music);
                }
            }
        }
        self.persist_scheduled();
        self.emit_changed();
    }

    pub fn started(&self) -> bool {
        self.dyn_state.lock().unwrap().started
    }

    pub fn host_on_launch(&self) -> bool {
        self.prefs.lock().unwrap().host_on_launch
    }

    /// Composer reachability light for a circle: "synced" = a relay/bucket holds posts for offline
    /// members (this circle has a relay, or a global relay/bucket/self-host is configured); "local" =
    /// device-only, nothing will leave this machine until a transport is configured. (Desktop has no
    /// local proximity mesh, so there's no mesh-based "syncing" state.)
    pub fn sync_status(&self, circle_id: &str) -> String {
        let any_transport = {
            let prefs = self.prefs.lock().unwrap();
            !prefs.active_relays_for(circle_id).is_empty()
                || prefs.s3.is_some()
                || prefs.host_on_launch
                || prefs.relays.values().flatten().any(|h| prefs.relay_is_active(h))
        };
        if any_transport {
            return "synced".into();
        }
        // No relay/bucket configured: online = best-effort direct iroh delivery done (green, no nag);
        // only genuinely offline is the device-only warning. (Previously pinned a relay-less node to a
        // permanent "device only" red.)
        if self.dyn_state.lock().unwrap().internet_active { "synced".into() } else { "local".into() }
    }

    pub fn set_host_on_launch(self: &Arc<Self>, on: bool) {
        let mut p = self.prefs.lock().unwrap();
        if p.host_on_launch != on {
            p.stamp_setting("host_on_launch"); // LWW so two desktops don't ping-pong this toggle
        }
        p.host_on_launch = on;
        let _ = p.save(&self.paths);
    }

    pub fn video_sound_on(&self) -> bool {
        self.prefs.lock().unwrap().video_sound_on
    }

    pub fn set_video_sound(self: &Arc<Self>, on: bool) {
        let mut p = self.prefs.lock().unwrap();
        p.video_sound_on = on;
        let _ = p.save(&self.paths);
    }

    // ---- Multi-device roster (iOS/Android parity; the signed-credential crypto is in the shared core) ----

    fn account_bundle(&self) -> Vec<u8> {
        match &self.seed {
            Some(seed) => haven_ffi::Account::from_seed(seed.to_vec()).map(|a| a.public_bundle()).unwrap_or_default(),
            // Seedless: the account PUBLIC bundle was granted + persisted; `my_bundle()` also returns it
            // (me_pub) once the engine booted linked, but the persisted copy is the source of truth.
            None => {
                let b = self.seedless.lock().unwrap().account_bundle.clone();
                if b.len() >= 32 { b } else { self.social.my_bundle() }
            }
        }
    }

    /// Sign + push the current roster to the engine, then persist. A1: only a seed-holding primary
    /// signs a roster — a seedless device is never the authority and never reaches here.
    fn push_roster(self: &Arc<Self>) {
        let Some(seed) = self.seed else { return };
        let now = now_ms() / 1000;
        let signed = self.roster.lock().unwrap().resign(&seed, now);
        if let Some((list, creds)) = signed {
            self.social.set_my_device_roster(list, creds);
        }
        // §1: a fresh resign rebuilds the roster from the device entries WITH the bare account leaf
        // authorized. If this account already migrated to device-only, re-apply the retirement on top
        // (higher-version, sticky) so a revoke/enroll re-sign can't flip us back to the shadow shape.
        if self.prefs.lock().unwrap().account_leaf_retired {
            let _ = self.social.retire_account_leaf();
        }
        let _ = self.roster.lock().unwrap().save(&self.paths);
    }

    /// Turn THIS device into the primary (master-key holder) that authorizes/revokes the others.
    pub fn enable_device_roster(self: &Arc<Self>) {
        let bundle = self.account_bundle();
        let hex = self.node_id_hex();
        self.roster.lock().unwrap().enable(&bundle, &hex);
        self.push_roster();
        self.emit_changed();
    }

    /// Revoke a linked device — it can decrypt nothing posted afterward.
    pub fn revoke_device(self: &Arc<Self>, node_hex: String) {
        if !self.roster.lock().unwrap().revoke(&node_hex) {
            return;
        }
        self.push_roster();
        // §6: rotate the account-state self-sync key so the revoked device can no longer read/LWW-write
        // our account state (gated exactly like retirement — a no-op while on the v0 seed-derived path).
        self.rotate_self_sync_on_revocation();
        self.emit_changed();
    }

    /// §6 — on a device revocation, rotate the self-sync channel key IF the fleet is fully device-
    /// capable (`self_sync_key_should_rotate`). Mints a fresh epoch key, persists it (0600), and
    /// distributes an account-signed epoch-grant to every STILL-authorized device over the self-sync
    /// mailbox. While the gate is unmet (mixed capability / retire OFF) this is a no-op and the channel
    /// stays byte-identical to 1.0.6 (v0 seed-derived seal/open). Primary-only (holds the seed).
    fn rotate_self_sync_on_revocation(self: &Arc<Self>) {
        let Some(seed) = self.seed else { return };
        // The gate mirrors the circle dual-seal retirement: retire switch ON (we set it every launch)
        // AND every own device seed-drop-capable — proxied by `account_leaf_retired()`, which latches
        // exactly when the fleet reaches the device-only shape.
        let fully_capable = self.social.account_leaf_retired();
        if !haven_ffi::multidevice::self_sync_key_should_rotate(true, fully_capable) {
            return;
        }
        let mut rot = crate::selfsyncrot::SelfSyncRotation::load(&self.paths);
        rot.rotate_to(haven_p2p::selfsync::mint_self_sync_key());
        let _ = rot.save(&self.paths);
        let epoch = rot.epoch;
        let Some(key) = rot.key32() else { return };
        // Seal the rotated key to every still-authorized device bundle and publish it over the self-
        // sync mailbox (the revoked device is simply not a grant recipient → keeps only the stale key).
        let survivors: Vec<Vec<u8>> = {
            let r = self.roster.lock().unwrap();
            let me = r.device_node_hex();
            r.entries
                .iter()
                .filter(|(hex, e)| {
                    !e.is_primary // the bare account leaf isn't a self-sync recipient
                        && *hex != &me // this device already holds the key locally
                        && !r.revoked.iter().any(|x| x == *hex)
                })
                .map(|(_, e)| e.bundle.clone())
                .collect()
        };
        if survivors.is_empty() {
            return;
        }
        let account_hex = self.node_id_hex();
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            me.distribute_self_sync_grants(&seed, &account_hex, epoch, &key, survivors).await;
            // Re-publish our own slot under the rotated key straight away so authorized devices pick
            // up the new epoch without waiting a full poll cycle.
            me.poll_self_sync().await;
        });
    }

    /// §6 — seal the rotated `(epoch, key)` to each still-authorized device bundle and put each grant
    /// in the self-sync mailbox at `self/<account>/keygrant/<device>` (all configured relays / S3), so
    /// a seedless survivor opens it on its next pass and adopts the rotated key. Account-signed, so a
    /// device verifies provenance; sealed to its bundle, so only it can open its grant.
    async fn distribute_self_sync_grants(
        self: &Arc<Self>,
        seed: &[u8; 32],
        account_hex: &str,
        epoch: u64,
        key: &[u8; 32],
        survivors: Vec<Vec<u8>>,
    ) {
        use haven_p2p::selfsync::grant_slot_key;
        let transports = self.gather_self_sync_transports().await;
        if transports.is_empty() {
            return;
        }
        for bundle in survivors {
            let dev_hex = wire::node_hex(&bundle);
            if dev_hex.len() != 64 {
                continue;
            }
            let Ok(env) = haven_ffi::multidevice::seal_self_sync_key_epoch_grant(
                seed.to_vec(),
                bundle,
                epoch,
                key.to_vec(),
            ) else {
                continue;
            };
            // Canonical grant slot via core so it can never drift across platforms.
            let mailbox_key = format!("haven/{}", grant_slot_key(account_hex, &dev_hex));
            for t in &transports {
                self.self_sync_put(t, &mailbox_key, &env).await;
            }
        }
    }

    /// Step this device down from being the primary (e.g. the wrong device claimed the role).
    pub fn step_down_as_primary(self: &Arc<Self>) {
        {
            let mut r = self.roster.lock().unwrap();
            r.step_down();
            let _ = r.save(&self.paths);
        }
        self.emit_changed();
    }

    /// Ask the primary (over iroh, to my own node id) to authorize this device with its own key.
    pub fn request_device_enrollment(self: &Arc<Self>) {
        let (bundle, name, hex) = {
            let r = self.roster.lock().unwrap();
            (r.device_bundle(), crate::roster::DeviceRoster::device_name(), r.device_node_hex())
        };
        let mut payload = Vec::new();
        wire::lp_append(&mut payload, &bundle);
        wire::lp_append(&mut payload, name.as_bytes());
        wire::lp_append(&mut payload, hex.as_bytes());
        let me = self.node_id_hex();
        self.send_frame(wire::DEVICE_ENROLL, &payload, &me);
    }

    /// I hold the master seed → authorize the requesting device: issue its credential, add it to my
    /// signed roster, and send the grant back. Legacy (type 24/25) path — seedless links use 28/29.
    fn handle_enrollment_request(self: &Arc<Self>, payload: &[u8]) {
        let Some(seed) = self.seed else { return }; // A1: only a seed-holder authorizes
        let mut r = wire::Reader::new(payload);
        let Some(bundle) = r.lp() else { return };
        let name = r.lp().map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_else(|| "Device".into());
        let Some(hex_b) = r.lp() else { return };
        let hex = String::from_utf8_lossy(&hex_b).into_owned();
        let my_dev = self.roster.lock().unwrap().device_node_hex();
        if hex.is_empty() || hex == my_dev {
            return; // not my own device's request
        }
        let account_bundle = self.account_bundle();
        let account_hex = self.node_id_hex();
        let now = now_ms() / 1000;
        let cred = {
            let mut rr = self.roster.lock().unwrap();
            rr.enable(&account_bundle, &account_hex);
            rr.add_linked_device(&bundle, &hex, &name, &seed, now)
        };
        let Some(cred) = cred else { return };
        self.push_roster();
        let mut grant = Vec::new();
        wire::lp_append(&mut grant, hex.as_bytes());
        wire::lp_append(&mut grant, &cred);
        let me = self.node_id_hex();
        self.send_frame(wire::DEVICE_GRANT, &grant, &me);
    }

    /// I'm the requesting device → store the credential the primary issued for my key.
    fn handle_device_grant(self: &Arc<Self>, payload: &[u8]) {
        let mut r = wire::Reader::new(payload);
        let Some(hex_b) = r.lp() else { return };
        let hex = String::from_utf8_lossy(&hex_b).into_owned();
        let Some(cred) = r.lp() else { return };
        let mut rr = self.roster.lock().unwrap();
        if hex != rr.device_node_hex() {
            return; // not for me
        }
        rr.credential = Some(cred);
        let _ = rr.save(&self.paths);
    }

    /// (isEnabled, thisDeviceAuthorized, devices) for the Authorized-Devices UI.
    pub fn device_roster_dto(&self) -> (bool, bool, Vec<crate::roster::RosterDeviceDto>) {
        let r = self.roster.lock().unwrap();
        (r.is_enabled(), r.is_authorized(), r.devices(&self.node_id_hex()))
    }

    // ---- seedless enrollment (seed-drop S4, plan §3/§4) --------------------------------------
    //
    // Frames 28 (SEEDLESS_ENROLL_REQ) / 29 (SEEDLESS_ENROLL_GRANT) mirror the legacy 24/25 rails but
    // carry self-authenticating bytes: the request is MAC'd under the one-time ticket secret (no seed
    // to already "be" the account), and the grant carries everything a seedless device needs
    // (credential + verbatim roster + sealed self-sync key). The whole request/grant body IS the core
    // `enroll_*_wire` — no extra desktop framing.

    /// PRIMARY: mint a `haven-enroll:` ticket for a new seedless device. Requires the account seed +
    /// an enabled roster (this device must actually be the primary authority). Returns the QR/copy text.
    pub fn mint_enroll_ticket(self: &Arc<Self>) -> Result<String> {
        let Some(_seed) = self.seed else {
            return Err(anyhow::anyhow!("this device holds no account seed — a seedless device can't authorize links"));
        };
        // Ensure this device is registered as the primary (idempotent) so its roster exists to grant.
        {
            let bundle = self.account_bundle();
            let hex = self.node_id_hex();
            self.roster.lock().unwrap().enable(&bundle, &hex);
        }
        self.push_roster();
        let account_bundle = self.account_bundle();
        // The primary's DEVICE transport id — the directed dial target the new device sends frame-28 to.
        let primary_device = hex_to_bytes32(&self.social.my_device_node_hex())
            .ok_or_else(|| anyhow::anyhow!("no device transport id"))?;
        let relays = self.active_relay_hexes();
        let now = now_ms() / 1000;
        let ticket = haven_ffi::enroll::enroll_issue_ticket(account_bundle, primary_device, now, relays)
            .map_err(|e| anyhow::anyhow!("issue ticket: {e}"))?;
        // Remember the secret so a frame-28 request can be verified against it (single-use, 10-min TTL).
        let secret: [u8; 32] = ticket.secret.clone().try_into().map_err(|_| anyhow::anyhow!("bad secret"))?;
        {
            let mut t = self.enroll_tickets.lock().unwrap();
            t.retain(|p| now.saturating_sub(p.issued_at) < 600 && !p.consumed); // prune stale/used
            t.push(PendingEnrollTicket { secret, issued_at: now, consumed: false });
        }
        haven_ffi::enroll::enroll_ticket_encode(ticket).map_err(|e| anyhow::anyhow!("encode ticket: {e}"))
    }

    /// Active relay node hexes (bootstrap relays carried in the ticket + grant, so the new device can
    /// reach the primary's self-sync slot). Excludes S3 pseudo-relays (not iroh-dialable by hex).
    fn active_relay_hexes(&self) -> Vec<String> {
        let prefs = self.prefs.lock().unwrap();
        let mut out: Vec<String> = prefs
            .relays
            .values()
            .flatten()
            .filter(|h| prefs.relay_is_active(h) && !h.starts_with("s3:"))
            .cloned()
            .collect();
        out.sort();
        out.dedup();
        out
    }

    /// PRIMARY: a frame-28 request arrived. Verify its MAC + freshness against every live ticket; on
    /// success stash it as a pending request and surface a confirm sheet to the UI (only the user's
    /// explicit approval issues the grant). `sender_device` is the authenticated transport id.
    fn handle_seedless_enroll_request(self: &Arc<Self>, sender_device: Option<&str>, wire: &[u8]) {
        if self.seed.is_none() {
            return; // only a seed-holding primary answers (a seedless device ignores 28)
        }
        let now = now_ms() / 1000;
        let secrets: Vec<[u8; 32]> = {
            let mut t = self.enroll_tickets.lock().unwrap();
            t.retain(|p| now.saturating_sub(p.issued_at) < 600 && !p.consumed);
            t.iter().map(|p| p.secret).collect()
        };
        for secret in secrets {
            let Ok(req) = haven_ffi::enroll::enroll_verify_request(secret.to_vec(), wire.to_vec(), now, 600) else {
                continue;
            };
            // Derive the requester's transport hex from its bundle (fallback: the authenticated sender).
            let device_hex = wire::node_hex(&req.device_bundle);
            let device_hex = if device_hex.len() == 64 {
                device_hex
            } else {
                sender_device.unwrap_or_default().to_lowercase()
            };
            {
                let mut reqs = self.enroll_requests.lock().unwrap();
                if reqs.iter().any(|r| r.device_hex == device_hex) {
                    return; // already pending confirm — ignore the resend
                }
                reqs.push(PendingEnrollRequest {
                    device_bundle: req.device_bundle.clone(),
                    device_hex: device_hex.clone(),
                    name: req.name.clone(),
                    secret,
                });
            }
            if let Some(app) = self.app.lock().unwrap().clone() {
                let _ = app.emit(
                    "haven:enroll-request",
                    serde_json::json!({ "deviceHex": device_hex, "name": req.name }),
                );
            }
            self.emit_changed();
            return; // matched one ticket; done
        }
    }

    /// PRIMARY-side UI query: the seedless-enroll requests awaiting the user's confirm.
    pub fn enroll_pending(&self) -> Vec<(String, String)> {
        self.enroll_requests.lock().unwrap().iter().map(|r| (r.device_hex.clone(), r.name.clone())).collect()
    }

    /// PRIMARY: the user CONFIRMED a pending seedless-enroll request → issue the credential, union the
    /// device into the roster, seal the self-sync-key grant, send frame-29 to the requester, and push
    /// full state (self-sync slot) so the new device can prime its base.
    pub fn approve_enroll(self: &Arc<Self>, device_hex: String) -> Result<()> {
        let Some(seed) = self.seed else {
            return Err(anyhow::anyhow!("no account seed"));
        };
        let req = {
            let mut reqs = self.enroll_requests.lock().unwrap();
            let idx = reqs.iter().position(|r| r.device_hex.eq_ignore_ascii_case(&device_hex));
            match idx {
                Some(i) => reqs.remove(i),
                None => return Err(anyhow::anyhow!("no such pending enrollment")),
            }
        };
        let now = now_ms() / 1000;
        // 1. Union the device into my signed roster (the existing register/resign path).
        {
            let bundle = self.account_bundle();
            let hex = self.node_id_hex();
            let mut rr = self.roster.lock().unwrap();
            rr.enable(&bundle, &hex);
            let _ = rr.add_linked_device(&req.device_bundle, &req.device_hex, &req.name, &seed, now);
        }
        self.push_roster();
        // 2. The primary-signed roster WIRE, verbatim (incl. capability trailer) — rides the grant (A3).
        let roster_wire = self.social.my_device_roster_wire();
        let relays = self.active_relay_hexes();
        // 3. Assemble frame-29: credential + verbatim roster + sealed self-sync grant, all MAC'd.
        let grant = haven_ffi::enroll::enroll_assemble_grant(
            seed.to_vec(),
            req.secret.to_vec(),
            req.device_bundle.clone(),
            req.name.clone(),
            now,
            roster_wire,
            relays,
        )
        .map_err(|e| anyhow::anyhow!("assemble grant: {e}"))?;
        // 4. Send the grant directed to the requesting device (both rails: directed + roster-expanded).
        self.send_frame(wire::SEEDLESS_ENROLL_GRANT, &grant, &req.device_hex);
        // 5. Consume the ticket (single-use).
        {
            let mut t = self.enroll_tickets.lock().unwrap();
            for p in t.iter_mut() {
                if p.secret == req.secret {
                    p.consumed = true;
                }
            }
        }
        // 6. Push full state so the new device can prime its self-sync base from my pushed slot.
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            me.poll_self_sync().await;
        });
        self.emit_changed();
        Ok(())
    }

    /// PRIMARY: the user DISMISSED a pending seedless-enroll request.
    pub fn reject_enroll(self: &Arc<Self>, device_hex: String) {
        self.enroll_requests.lock().unwrap().retain(|r| !r.device_hex.eq_ignore_ascii_case(&device_hex));
        self.emit_changed();
    }

    /// NEW DEVICE: (re)send the frame-28 request to the primary, using the pending ticket. Broadcast on
    /// both rails — directed iroh to the primary's device id AND the account id (roster-expanded) — so
    /// whichever path resolves reaches the primary. No-op once linked or without a pending ticket.
    fn send_seedless_enroll_request(self: &Arc<Self>) {
        let ticket = {
            let s = self.seedless.lock().unwrap();
            if s.linked {
                return;
            }
            s.pending_ticket.clone()
        };
        let Some(ticket) = ticket else { return };
        let device_bundle = self.roster.lock().unwrap().device_bundle();
        let name = crate::roster::DeviceRoster::device_name();
        let now = now_ms() / 1000;
        let Ok(req) = haven_ffi::enroll::enroll_build_request(ticket.secret.clone(), device_bundle, name, now) else {
            return;
        };
        let primary_device = bytes_to_hex(&ticket.primary_device);
        if primary_device.len() == 64 {
            self.send_frame(wire::SEEDLESS_ENROLL_REQ, &req, &primary_device);
        }
        // Also address the account id (the send-frame layer expands it to authorized device ids).
        let account_hex = bytes_to_hex(&ticket.account_id);
        if account_hex.len() == 64 && account_hex != primary_device {
            self.send_frame(wire::SEEDLESS_ENROLL_REQ, &req, &account_hex);
        }
    }

    /// NEW DEVICE: a frame-29 grant arrived. Open it against the pending ticket (all-positive: MAC,
    /// account tamper, credential-names-me, roster authorizes me, self-sync grant opens). On success:
    /// persist EVERYTHING, initialize the self-sync base from the primary's pushed slot BEFORE any
    /// local diff (the absence-as-deletion guard), then signal the frontend to relaunch into seedless
    /// mode. A partial/failed grant is a no-op — the device stays linking (idempotent, re-scannable).
    async fn handle_seedless_enroll_grant(self: &Arc<Self>, wire: &[u8]) {
        // Only a linking device accepts a grant, and only once.
        let (ticket, device_seed) = {
            let s = self.seedless.lock().unwrap();
            if s.linked {
                return;
            }
            let Some(t) = s.pending_ticket.clone() else { return };
            (t, self.roster.lock().unwrap().device_seed.clone())
        };
        let ticket_ffi = haven_ffi::enroll::EnrollTicketFfi {
            account_id: ticket.account_id.clone(),
            verification: ticket.verification.clone(),
            secret: ticket.secret.clone(),
            primary_device: ticket.primary_device.clone(),
            issued_at: ticket.issued_at,
            relays: ticket.relays.clone(),
        };
        let grant = match haven_ffi::enroll::enroll_open_grant(device_seed, ticket_ffi, wire.to_vec()) {
            Ok(g) => g,
            Err(e) => {
                log::warn!("seedless enroll grant rejected: {e}");
                return; // stay in linking mode — re-scannable
            }
        };
        // Persist the granted credential (roster credential store).
        {
            let mut rr = self.roster.lock().unwrap();
            rr.credential = Some(grant.credential.clone());
            let _ = rr.save(&self.paths);
        }
        // Persist the seedless identity state (0600). This is the ONLY writer of these secrets.
        {
            let mut s = self.seedless.lock().unwrap();
            s.enabled = true;
            s.linked = true;
            s.account_bundle = grant.account_bundle.clone();
            s.self_sync_key = grant.self_sync_key.clone();
            s.roster_wire = grant.roster_wire.clone();
            // Union the ticket's relays with the grant's so we can reach the primary's slot.
            let mut relays = ticket.relays.clone();
            for r in &grant.relays {
                if !relays.contains(r) {
                    relays.push(r.clone());
                }
            }
            s.relays = relays.clone();
            s.pending_ticket = None;
            let _ = s.save(&self.paths);
        }
        // Adopt the grant's relays into prefs so the self-sync transport can reach the primary's slot.
        self.adopt_bootstrap_relays(&grant.relays).await;
        // Install the verbatim roster so we rebroadcast it (A3) — even before the relaunch.
        if !grant.roster_wire.is_empty() {
            let _ = self.social.ingest_roster_wire(grant.roster_wire.clone());
        }
        // *** Absence-as-deletion guard *** — initialize the self-sync base from the primary's pushed
        // slot BEFORE any local diff/push runs, so a freshly-empty engine never tombstones the account's
        // circles/contacts (plan §7). Uses the granted key (equals the account self-sync key).
        if let Some(key) = grant.self_sync_key.clone().try_into().ok() {
            self.prime_self_sync_base(key).await;
        }
        log::info!("seedless enrollment complete — device credentialed under account {}", &wire::node_hex(&grant.account_bundle));
        if let Some(app) = self.app.lock().unwrap().clone() {
            let _ = app.emit("haven:enrolled", ());
        }
        self.emit_changed();
    }

    /// Adopt bootstrap relay node hexes into prefs (best-effort) so a freshly-enrolled seedless device
    /// has a self-sync transport before its first pass. Idempotent.
    async fn adopt_bootstrap_relays(self: &Arc<Self>, relays: &[String]) {
        for hex in relays {
            if hex.len() != 64 || hex.starts_with("s3:") {
                continue;
            }
            let _ = self.adopt_relay(hex.clone()).await;
        }
    }

    /// Pull the account's self-sync slots (opened with `self_key`), merge them, apply locally, and
    /// WRITE the converged state as the self-sync base — all BEFORE any local diff. This is the ordered
    /// grant-acceptance step that stops a just-enrolled empty device from tombstoning the account.
    async fn prime_self_sync_base(self: &Arc<Self>, self_key: [u8; 32]) {
        use haven_p2p::selfsync::{slot_prefix, AccountState};
        let account_hex = wire::node_hex(&self.account_bundle());
        if account_hex.len() != 64 {
            return;
        }
        let transports = self.gather_self_sync_transports().await;
        if transports.is_empty() {
            return; // no relay/bucket yet — the loop will prime on the first pass with the base guard
        }
        let mut base = AccountState::default();
        let prefix = format!("haven/{}", slot_prefix(&account_hex));
        let mut got_any = false;
        for t in &transports {
            for key in self.self_sync_list(t, &prefix).await {
                let Some(blob) = self.self_sync_fetch(t, &key).await else { continue };
                if let Ok(peer) = AccountState::open(&self_key, &blob) {
                    base.merge(&peer);
                    got_any = true;
                }
            }
        }
        if !got_any {
            return; // nothing pushed yet; the loop's empty-base guard keeps the first pass additive
        }
        // Apply the primary's converged state locally (circles/contacts/settings) + persist as the base.
        let entries: Vec<(String, Vec<u8>)> =
            base.entries().map(|(k, v)| (k.to_string(), v.to_vec())).collect();
        {
            let mut prefs = self.prefs.lock().unwrap();
            if crate::selfsync::apply_local(&entries, &mut prefs, &self.social) {
                let _ = prefs.save(&self.paths);
            }
        }
        self.persist();
        let _ = std::fs::write(self.paths.selfsync_state_file(), base.to_bytes());
        log::info!("seedless self-sync base primed from primary slot ({} keys)", entries.len());
    }

    // ---- circles ------------------------------------------------------------------------

    pub fn feed_circles(&self) -> Vec<haven_ffi::CircleInfoFfi> {
        let p = self.prefs.lock().unwrap();
        self.social
            .circles()
            .into_iter()
            // Belt-and-suspenders: never surface a tombstone-deleted circle (a sync race can
            // re-materialize one before its `circle-deleted:` record applies).
            .filter(|c| !c.id.starts_with("dm:") && !p.is_circle_deleted(&c.id))
            .collect()
    }

    /// Collapse any SUPERSEDED legacy circle (one carried onto a creator-bound successor via
    /// upgrade/follow) into a single row, and heal duplicates that already exist. Converts the engine's
    /// per-device `superseded_circle_ids()` signal into the SAME synced, LWW deletion tombstone used for
    /// deleting a circle — so self-sync honors it on every device and can never resurrect the legacy row.
    /// Mirrors iOS FeedStore.refreshCircles. Runs on every self-sync pass (and once at startup).
    pub fn reconcile_superseded_circles(self: &Arc<Self>) {
        let superseded = self.social.superseded_circle_ids();
        if superseded.is_empty() {
            return;
        }
        let mut changed = false;
        for legacy in superseded {
            let already = self.prefs.lock().unwrap().is_circle_deleted(&legacy);
            if already {
                continue;
            }
            {
                let mut p = self.prefs.lock().unwrap();
                p.mark_circle_deleted(&legacy); // LWW tombstone → syncs to all my devices
                let _ = p.save(&self.paths);
            }
            self.social.leave_circle(legacy.clone()); // drop the duplicate row from the engine
            changed = true;
        }
        if changed {
            self.persist();
            self.emit_changed();
        }
    }

    pub fn create_circle(self: &Arc<Self>, name: String) -> String {
        // Mint a creator-BOUND id: it commits to this account, so every member establishes the circle's
        // creator from the id itself rather than from a claim on the wire. This also pins + announces
        // the creator (the propagating self-grant), so no separate set_circle_creator is needed here.
        let id = self.social.create_circle_owned(name);
        // §2: remember it (device-local) so the pin is re-applied every launch.
        {
            let mut p = self.prefs.lock().unwrap();
            if !p.created_circles.iter().any(|c| c == &id) {
                p.created_circles.push(id.clone());
            }
            // A freshly-created circle is NOT deleted (LWW) — lift any stale deletion for a reused id.
            p.mark_circle_recreated(&id);
            let _ = p.save(&self.paths);
        }
        self.persist();
        self.emit_changed();
        id
    }

    /// Upgrade offers on `circle_id` I haven't followed — "so-and-so says this circle's replacement is
    /// theirs". Each is verified as genuinely from its signer, but NOT as proof they made the circle:
    /// legacy circles never recorded an owner, so nothing can establish that. The user decides, and
    /// every competing offer is returned — the pick is never made here.
    pub fn pending_circle_upgrades(&self, circle_id: String) -> Vec<CircleUpgradeOffer> {
        self.social.pending_circle_upgrades(circle_id)
    }

    /// Can I offer to carry this circle onto an owned one? Only a shared circle I made — the
    /// created-here set is device-local (prefs), so the UI can't answer this on its own. `default` is
    /// your own personal circle and `dm:` threads are two-party (both sides derive the same id, and
    /// there's nobody to remove), so neither has anything to gain here.
    pub fn can_offer_circle_upgrade(&self, circle_id: String) -> bool {
        if circle_id.starts_with(OWNED_CIRCLE_PREFIX) || circle_id == "default" || circle_id.starts_with("dm:") {
            return false;
        }
        // Empty admins = the core's authoritative "no verified owner yet" signal. No device records
        // who made a pre-1.0.7 circle, so the offer is shown to ANY member (the follow side names each
        // claimant); the core still refuses to author one on a circle that already names its creator.
        // (Previously this required a per-device created-circles record that legacy circles never had,
        // so the offer never appeared at all.)
        if !self.circle_admins(&circle_id).is_empty() {
            return false;
        }
        !self.social.pending_circle_upgrades(circle_id).iter().any(|o| o.mine)
    }

    /// Offer to carry a circle I made onto its replacement: mints the replacement, carries the members
    /// over, and puts the signed offer on the old circle's lane. Returns the replacement's id.
    pub fn upgrade_circle(self: &Arc<Self>, circle_id: String) -> Option<String> {
        let id = self.social.upgrade_circle(circle_id)?;
        // §2: remember it (device-local) so the pin is re-applied every launch, like any circle I made.
        {
            let mut p = self.prefs.lock().unwrap();
            if !p.created_circles.iter().any(|c| c == &id) {
                p.created_circles.push(id.clone());
                let _ = p.save(&self.paths);
            }
        }
        self.persist();
        self.emit_changed();
        Some(id)
    }

    /// Follow someone's offer: stand up the replacement and pin them as its verified owner. Only ever
    /// reached from an explicit click — the banner has already named who is claiming the circle,
    /// because nothing can prove the claim and whoever is followed can remove people.
    pub fn accept_circle_upgrade(self: &Arc<Self>, circle_id: String, new_circle_id: String) -> bool {
        let ok = self.social.accept_circle_upgrade(circle_id, new_circle_id);
        if ok {
            self.persist();
            self.emit_changed();
        }
        ok
    }

    pub fn rename_circle(self: &Arc<Self>, id: String, name: String) {
        self.social.rename_circle(id, name);
        self.persist();
        self.emit_changed();
    }

    /// §2 — delegate circle admin to a member (creator/admin only, requires my account key). The grant
    /// is account-signed + versioned and propagates on the control lane; it's what lets that member
    /// author an MLS Remove. Returns false if I'm not authorized to delegate. Re-pins the creator first
    /// so the authority root is established even if this is the first authority action this launch.
    pub fn grant_circle_admin(self: &Arc<Self>, circle_id: String, admin_hex: String) -> bool {
        let created = self.prefs.lock().unwrap().created_circles.iter().any(|c| c == &circle_id);
        if created {
            self.social.set_circle_creator(circle_id.clone(), self.node_id_hex());
        }
        let ok = self.social.grant_circle_admin(circle_id, admin_hex);
        if ok {
            self.persist();
            self.emit_changed();
        }
        ok
    }

    /// The current admin accounts (hex) of a circle — the creator + creator-delegated admins.
    pub fn circle_admins(&self, circle_id: &str) -> Vec<String> {
        self.social.circle_admins(circle_id.to_string())
    }

    pub fn leave_circle(self: &Arc<Self>, id: String) {
        if id == DEFAULT_CIRCLE {
            return;
        }
        {
            // LWW deletion tombstone so a sibling's `circle:` record can't re-create it every sync.
            // Mirrors iOS CircleDeletionStore.markDeleted on delete.
            let mut p = self.prefs.lock().unwrap();
            p.mark_circle_deleted(&id);
            let _ = p.save(&self.paths);
        }
        self.social.leave_circle(id);
        self.persist();
        self.emit_changed();
    }

    /// Add an existing contact to a circle + greet them there so it forms on their side.
    pub fn add_to_circle(self: &Arc<Self>, circle_id: String, contact_id_hex: String) {
        self.clear_circle_removal(&circle_id, &contact_id_hex); // deliberate re-add un-bans them
        let _ = self.social.add_existing_to_circle(circle_id.clone(), contact_id_hex.clone());
        self.persist();
        self.emit_changed();
        self.send_hello(&circle_id, &contact_id_hex);
    }

    /// Remove a member from a circle (without blocking). Records the severance so it propagates to our
    /// own devices as an INTENTIONAL removal and survives the additive re-sync (apply_local won't re-add
    /// anyone in `circle_removals`), then re-keys the relay mailbox to the remaining members so the
    /// removed person can't pull future media.
    pub fn remove_from_circle(self: &Arc<Self>, circle_id: String, contact_id_hex: String) {
        {
            let mut p = self.prefs.lock().unwrap();
            // LWW severance: stamp the removal NOW so it beats any stale sibling re-add (and a later
            // deliberate re-add beats this). Mirrors iOS ConnectionsStore.removeFromCircle.
            let entry = format!("{circle_id}|{}", contact_id_hex.to_lowercase());
            p.mark_circle_member_removed(&entry);
            let _ = p.save(&self.paths);
        }
        self.social.remove_from_circle(circle_id, contact_id_hex);
        self.persist();
        self.authorize_membership();
        self.emit_changed();
    }

    /// Was this member explicitly removed from this circle? (Blocks their unsolicited handshake rejoin.)
    /// LWW: removed iff the removal is newer than any re-add.
    fn is_removed_from_circle(&self, circle_id: &str, id_hex: &str) -> bool {
        let entry = format!("{circle_id}|{}", id_hex.to_lowercase());
        self.prefs.lock().unwrap().is_circle_member_removed(&entry)
    }

    /// Re-allow a member into a circle — ONLY on a deliberate re-add (approve / add / invite connect).
    /// Stamps the re-add NOW (LWW), so the clear propagates via self-sync as an explicit newer write
    /// instead of silently losing to a stale removal record.
    fn clear_circle_removal(&self, circle_id: &str, id_hex: &str) {
        let entry = format!("{circle_id}|{}", id_hex.to_lowercase());
        {
            let mut p = self.prefs.lock().unwrap();
            p.mark_circle_member_readded(&entry);
            let _ = p.save(&self.paths);
        }
        // Lift the ENGINE tombstone too — the add paths now REFUSE a tombstoned member, so a deliberate
        // re-add must clear it in the engine or the member could never be added back.
        self.social.clear_circle_removal(circle_id.to_string(), id_hex.to_lowercase());
    }

    // ---- feed / authoring ---------------------------------------------------------------

    pub fn feed(&self, circle_id: &str) -> Vec<FeedItemFfi> {
        let retention = self.prefs.lock().unwrap().retention_secs;
        self.social.feed(circle_id.to_string(), now_ms(), retention)
    }

    // ---- media GC (purge-linked deletion + orphan sweep) ---------------------------------
    // `feed()` only HIDES expired posts; `purge_expired` really drops the events and returns their
    // media refs so the blobs finally leave disk too. Deletion is gated on an in-use check — the
    // same photo may ride another live post (any circle, DMs included), a comment, or a scheduled
    // send, and those keep their bytes.

    /// Really delete expired content for a circle and GC the blobs the purge orphaned. Called from
    /// the feed/messages commands — throttled to once per circle per app session so a refreshing
    /// frontend never re-runs engine purges. Runs off the command thread.
    pub fn maybe_purge_expired_media(self: &Arc<Self>, circle_id: &str) {
        if !self.media_purged.lock().unwrap().insert(circle_id.to_string()) {
            return;
        }
        let me = self.clone();
        let cid = circle_id.to_string();
        tauri::async_runtime::spawn_blocking(move || {
            // Same retention the display paths pass to `feed`: the global pref for circles, none
            // for DM threads (`messages` renders without a viewer window).
            let retention = if cid.starts_with("dm:") {
                None
            } else {
                me.prefs.lock().unwrap().retention_secs
            };
            let purged = me.social.purge_expired(cid.clone(), retention, now_ms());
            if purged.is_empty() {
                return;
            }
            // Persist FIRST: once the blobs are gone, the purged events must not resurrect from a
            // stale state file and re-request their (now deleted) media forever.
            me.persist();
            // Built AFTER the purge, so this circle's dropped events no longer count as users.
            // Device-pinned blobs (#2) are already unioned into `media_in_use_names`, so "keep on this
            // device" survives a purge that orphaned them.
            let in_use = me.media_in_use_names();
            let mut freed = 0u64;
            for r in &purged {
                if LocalMedia::is_synthetic(r) {
                    continue;
                }
                if !in_use.contains(&LocalMedia::storage_name(r)) {
                    freed += me.media.delete(r);
                }
            }
            if freed > 0 {
                log::info!("media GC purge {cid}: freed {freed}B");
            }
        });
    }

    /// The on-disk name of every media ref a live event still references — every circle's feed
    /// (retention None: expired-but-unpurged events keep their bytes until purged), every comment,
    /// and every scheduled send. Blocking (`feed` re-opens every envelope) — never call on the UI
    /// path directly.
    fn media_in_use_names(&self) -> std::collections::HashSet<String> {
        let mut names = std::collections::HashSet::new();
        fn add(names: &mut std::collections::HashSet<String>, r: &str) {
            if !LocalMedia::is_synthetic(r) {
                names.insert(LocalMedia::storage_name(r));
            }
        }
        for c in self.social.circles() {
            for item in self.social.feed(c.id, now_ms(), None) {
                for r in &item.media {
                    add(&mut names, r);
                }
                for cm in &item.comments {
                    for r in &cm.media {
                        add(&mut names, r);
                    }
                }
            }
        }
        for s in &self.scheduled.lock().unwrap().items {
            for r in &s.media {
                add(&mut names, r);
            }
        }
        // Device-pinned blobs (#2) are cleanup-exempt everywhere: fold their storage names into the
        // keep-set so neither the orphan sweep nor the purge-linked GC can ever delete a pinned blob,
        // whatever its age or referencedness. CRITICAL: this union is what makes "Keep on this device"
        // safe against the automatic sweeps (parity with the limit-sweep skip-set below).
        names.extend(self.pinned_names());
        names
    }

    /// The on-disk names a LIVE feed/comment event still references — NOT counting scheduled sends or
    /// device pins. This narrower set decides which deliberately-deleted blobs become re-downloadable
    /// "evicted" placeholders (a still-referenced deletion) vs a plain orphan removal. iOS
    /// `FeedStore.mediaInUseStems`. Blocking (`feed` re-opens every envelope).
    fn media_referenced_names(&self) -> std::collections::HashSet<String> {
        let mut names = std::collections::HashSet::new();
        for c in self.social.circles() {
            for item in self.social.feed(c.id, now_ms(), None) {
                for r in &item.media {
                    if !LocalMedia::is_synthetic(r) {
                        names.insert(LocalMedia::storage_name(r));
                    }
                }
                for cm in &item.comments {
                    for r in &cm.media {
                        if !LocalMedia::is_synthetic(r) {
                            names.insert(LocalMedia::storage_name(r));
                        }
                    }
                }
            }
        }
        names
    }

    /// Delete every stored blob no event anywhere references (Settings' "Clean up unused media"
    /// and the weekly sweep). Blocking. Returns (bytes_freed, files_removed).
    pub fn cleanup_unused_media(&self) -> (u64, usize) {
        let keep = self.media_in_use_names();
        let res = self.media.sweep_orphans(&keep, 48 * 3600);
        if res.1 > 0 {
            log::info!("media GC sweep: freed {}B across {} files", res.0, res.1);
        }
        res
    }

    /// Run the orphan sweep at most once a week (persisted stamp), kicked from startup.
    fn maybe_weekly_media_sweep(self: &Arc<Self>) {
        if !self.media.gc_due(7 * 24 * 3600) {
            return;
        }
        let me = self.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let _ = me.cleanup_unused_media();
            me.media.touch_gc_stamp();
        });
    }

    // ---- #2 device pin ("keep on this device") -------------------------------------------
    // A DEVICE-LOCAL retention exemption (never synced): pinned media is skipped by EVERY cleanup
    // path. `pinned_names()` (the storage names of every pinned ref) is unioned into both the orphan/
    // purge keep-set (media_in_use_names) and the limit-sweep skip-set — the one guarantee that
    // "Keep on this device" is honored against the automatic sweeps.

    /// The storage names (on-disk basenames) of every device-pinned ref.
    fn pinned_names(&self) -> std::collections::HashSet<String> {
        self.prefs
            .lock()
            .unwrap()
            .pinned_media
            .iter()
            .filter(|r| !LocalMedia::is_synthetic(r))
            .map(|r| LocalMedia::storage_name(r))
            .collect()
    }

    /// True if the ref (or its bare-hash storage name) is device-pinned.
    pub fn is_pinned(&self, reference: &str) -> bool {
        self.pinned_names().contains(&LocalMedia::storage_name(reference))
    }

    pub fn pinned_count(&self) -> usize {
        self.prefs.lock().unwrap().pinned_media.len()
    }

    /// Pin refs so no cleanup ever removes them (skips synthetic geo refs; deduped).
    pub fn pin_media(self: &Arc<Self>, refs: Vec<String>) {
        let mut p = self.prefs.lock().unwrap();
        for r in refs {
            if !LocalMedia::is_synthetic(&r) && !p.pinned_media.contains(&r) {
                p.pinned_media.push(r);
            }
        }
        let _ = p.save(&self.paths);
    }

    /// Un-pin refs (matches on the exact ref stored).
    pub fn unpin_media(self: &Arc<Self>, refs: Vec<String>) {
        let mut p = self.prefs.lock().unwrap();
        let drop: std::collections::HashSet<&String> = refs.iter().collect();
        p.pinned_media.retain(|r| !drop.contains(r));
        let _ = p.save(&self.paths);
    }

    // ---- #3/#4 evicted set (deliberately removed, do-not-auto-refetch) --------------------

    /// True if this ref's blob was deliberately evicted (matches the ref AND its bare-hash storage
    /// name, so an event ref `img_<hash>`/`v:<hash>` resolves an eviction recorded under either key).
    /// CRITICAL: `request_missing_media` gates on this, or a deliberate cleanup is silently undone.
    pub fn evicted_contains(&self, reference: &str) -> bool {
        let p = self.prefs.lock().unwrap();
        p.evicted_media.contains_key(reference)
            || p.evicted_media.contains_key(&LocalMedia::storage_name(reference))
    }

    /// Last-known bytes of an evicted ref (for the "Download N" placeholder), by ref or storage name.
    pub fn evicted_size(&self, reference: &str) -> Option<u64> {
        let p = self.prefs.lock().unwrap();
        p.evicted_media
            .get(reference)
            .or_else(|| p.evicted_media.get(&LocalMedia::storage_name(reference)))
            .copied()
    }

    /// Record a ref as deliberately evicted (bounded map — prune to 4000 newest-ish when it grows past
    /// 8000, matching iOS). Persists prefs.
    fn mark_evicted(&self, reference: &str, bytes: u64) {
        let mut p = self.prefs.lock().unwrap();
        p.evicted_media.insert(reference.to_string(), bytes);
        if p.evicted_media.len() > 8000 {
            let keep: std::collections::HashMap<String, u64> =
                p.evicted_media.iter().take(4000).map(|(k, v)| (k.clone(), *v)).collect();
            p.evicted_media = keep;
        }
        let _ = p.save(&self.paths);
    }

    /// Clear an eviction (both the ref and its bare-hash key). Persists prefs if anything changed.
    fn clear_evicted(&self, reference: &str) {
        let mut p = self.prefs.lock().unwrap();
        let mut changed = p.evicted_media.remove(reference).is_some();
        if p.evicted_media.remove(&LocalMedia::storage_name(reference)).is_some() {
            changed = true;
        }
        if changed {
            let _ = p.save(&self.paths);
        }
    }

    // ---- #1 cleanup screen (size-sorted inventory + multi-select delete) ------------------

    /// Every stored media blob joined to the post/DM/comment that references it (best-effort), sorted
    /// by size DESCENDING for the "Manage media" screen. A blob no live event names is an ORPHAN
    /// (labelled "Unused", or "Scheduled to send" if a pending scheduled send holds it). Deleting a
    /// row frees only the LOCAL bytes; the event stays and re-renders as a downloadable placeholder.
    /// Blocking (walks every circle's feed). iOS `FeedStore.mediaInventory`.
    pub fn media_inventory(&self) -> Vec<MediaRow> {
        let circle_names: std::collections::HashMap<String, String> =
            self.social.circles().into_iter().map(|c| (c.id, c.name)).collect();
        fn kind_of(r: &str) -> &'static str {
            if LocalMedia::is_video(r) {
                "video"
            } else if LocalMedia::is_audio(r) {
                "audio"
            } else {
                "image"
            }
        }
        // storage_name -> kind (a bare on-disk name carries no prefix, so kind must come from the
        // referencing ref); and the set of names a pending scheduled send holds.
        let mut ref_kind: std::collections::HashMap<String, &'static str> = std::collections::HashMap::new();
        let mut scheduled_names: std::collections::HashSet<String> = std::collections::HashSet::new();
        for s in &self.scheduled.lock().unwrap().items {
            for r in &s.media {
                if LocalMedia::is_synthetic(r) {
                    continue;
                }
                let n = LocalMedia::storage_name(r);
                scheduled_names.insert(n.clone());
                ref_kind.entry(n).or_insert_with(|| kind_of(r));
            }
        }
        // storage_name -> the event that references it (first/newest wins).
        struct Own {
            circle_id: String,
            snippet: String,
        }
        let mut owner: std::collections::HashMap<String, Own> = std::collections::HashMap::new();
        for c in self.social.circles() {
            for item in self.social.feed(c.id.clone(), now_ms(), None) {
                let snip: String = item.body.chars().take(80).collect();
                for r in &item.media {
                    if LocalMedia::is_synthetic(r) {
                        continue;
                    }
                    let n = LocalMedia::storage_name(r);
                    ref_kind.entry(n.clone()).or_insert_with(|| kind_of(r));
                    owner.entry(n).or_insert_with(|| Own { circle_id: c.id.clone(), snippet: snip.clone() });
                }
                for cm in &item.comments {
                    let csnip: String = cm.body.chars().take(80).collect();
                    for r in &cm.media {
                        if LocalMedia::is_synthetic(r) {
                            continue;
                        }
                        let n = LocalMedia::storage_name(r);
                        ref_kind.entry(n.clone()).or_insert_with(|| kind_of(r));
                        owner.entry(n).or_insert_with(|| Own { circle_id: c.id.clone(), snippet: csnip.clone() });
                    }
                }
            }
        }
        let pinned = self.pinned_names();
        let mut rows: Vec<MediaRow> = self
            .media
            .stored_blobs()
            .into_iter()
            .map(|(name, bytes, mtime_secs)| {
                let kind = *ref_kind.get(&name).unwrap_or(&"image");
                let is_pinned = pinned.contains(&name);
                let mtime_ms = mtime_secs.saturating_mul(1000);
                if let Some(o) = owner.get(&name) {
                    let is_dm = o.circle_id.starts_with("dm:");
                    MediaRow {
                        reference: name.clone(),
                        bytes,
                        mtime_ms,
                        kind,
                        circle_name: if is_dm {
                            "Direct message".to_string()
                        } else {
                            circle_names.get(&o.circle_id).cloned().unwrap_or_else(|| "A circle".to_string())
                        },
                        snippet: if o.snippet.is_empty() { None } else { Some(o.snippet.clone()) },
                        is_orphan: false,
                        is_pinned,
                    }
                } else {
                    let scheduled = scheduled_names.contains(&name);
                    MediaRow {
                        reference: name,
                        bytes,
                        mtime_ms,
                        kind,
                        circle_name: if scheduled { "Scheduled to send".to_string() } else { "Unused".to_string() },
                        snippet: None,
                        is_orphan: !scheduled,
                        is_pinned,
                    }
                }
            })
            .collect();
        rows.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        rows
    }

    /// Delete the LOCAL blobs for these refs (the event/metadata stays). A ref a LIVE feed/comment
    /// event still references is recorded in the evicted set with its size, so it re-renders as a
    /// "Download N" placeholder instead of being auto-refetched (which would undo the cleanup). Pinned
    /// rows are skipped. Returns freed bytes. iOS `FeedStore.deleteSelectedMedia`.
    pub fn media_delete_selected(self: &Arc<Self>, refs: Vec<String>) -> u64 {
        let referenced = self.media_referenced_names();
        let pinned = self.pinned_names();
        let mut freed = 0u64;
        for reference in refs {
            let name = LocalMedia::storage_name(&reference);
            if pinned.contains(&name) {
                continue; // "Keep on this device" — never delete
            }
            let bytes = self.media.delete(&reference);
            freed += bytes;
            // A ref a LIVE event still references becomes a re-downloadable placeholder (recorded
            // evicted so the missing-media sweep won't silently refetch it); a pure orphan just goes.
            if referenced.contains(&name) {
                self.mark_evicted(&reference, bytes);
            }
        }
        if freed > 0 {
            self.emit_changed();
        }
        freed
    }

    // ---- #3 on-demand download of an evicted blob ----------------------------------------

    /// User tapped "Download" on an evicted placeholder: clear the eviction (so the normal missing-
    /// media path may fetch it), then fetch this one ref now — relay/S3 first (idempotent), peer
    /// fallback second — like `request_missing_media`'s per-ref path. iOS `FeedStore.downloadEvicted`.
    pub fn media_download(self: &Arc<Self>, reference: String) {
        self.clear_evicted(&reference);
        if self.media.has(&reference) {
            self.emit_changed();
            return;
        }
        // Find a circle that references it (drives relay selection); media is permission-free so any
        // circle's relays can serve it, but the owning circle is the best first try.
        let mut circle_id: Option<String> = None;
        for c in self.social.circles() {
            for item in self.social.feed(c.id.clone(), now_ms(), None) {
                if item.media.iter().any(|r| r == &reference)
                    || item.comments.iter().any(|cm| cm.media.iter().any(|r| r == &reference))
                {
                    circle_id = Some(c.id.clone());
                    break;
                }
            }
            if circle_id.is_some() {
                break;
            }
        }
        let circle_id = circle_id
            .or_else(|| self.social.circles().first().map(|c| c.id.clone()))
            .unwrap_or_default();
        let me = self.clone();
        let my_hex = self.node_id_hex();
        tauri::async_runtime::spawn(async move {
            if me.fetch_media_healing(&circle_id, &reference).await {
                me.emit_changed();
                return;
            }
            // Relay couldn't serve it → ask peers directly (same payload shape as request_missing_media).
            me.dyn_state.lock().unwrap().requested_refs.insert(reference.clone());
            let mut payload = my_hex.into_bytes();
            payload.extend_from_slice(reference.as_bytes());
            let ids: Vec<String> = me.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
            for id_hex in ids {
                me.send_frame(wire::MEDIA_REQ, &payload, &id_hex);
            }
        });
    }

    // ---- #4 local limits (age/size caps) -------------------------------------------------

    pub fn get_media_limits(&self) -> (u32, u32) {
        let p = self.prefs.lock().unwrap();
        (p.local_media_max_days, p.local_media_max_gb)
    }

    /// Persist the device-local age/size caps and enforce them immediately (bypassing the throttle).
    pub fn set_media_limits(self: &Arc<Self>, days: u32, gb: u32) {
        {
            let mut p = self.prefs.lock().unwrap();
            p.local_media_max_days = days;
            p.local_media_max_gb = gb;
            let _ = p.save(&self.paths);
        }
        self.enforce_local_limits(true);
    }

    /// Enforce the device-local age/size caps (Settings ▸ Storage): delete local blobs (metadata stays
    /// → placeholder) oldest-first, skipping pinned + in-flight media. `force` bypasses the ~10-min
    /// throttle (used on a settings change). No-op when both caps are off. Runs off-thread.
    /// iOS `FeedStore.enforceLocalLimits`.
    pub fn enforce_local_limits(self: &Arc<Self>, force: bool) {
        let (max_days, max_gb) = self.get_media_limits();
        if max_days == 0 && max_gb == 0 {
            return;
        }
        {
            let mut st = self.dyn_state.lock().unwrap();
            if st.limit_sweep_in_flight {
                return;
            }
            let now = now_ms();
            if !force && now.saturating_sub(st.last_limit_sweep_ms) < 600_000 {
                return; // at most every 10 min otherwise
            }
            st.last_limit_sweep_ms = now;
            st.limit_sweep_in_flight = true;
        }
        let me = self.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let pinned = me.pinned_names();
            let in_use = me.media_referenced_names();
            let (bytes, files, evict) = me.media.perform_limit_sweep(max_days, max_gb, &pinned, &in_use, 48 * 3600);
            me.dyn_state.lock().unwrap().limit_sweep_in_flight = false;
            if files > 0 {
                for (name, b) in &evict {
                    me.mark_evicted(name, *b);
                }
                me.emit_changed();
                log::info!("media limit sweep: freed {bytes}B across {files} files");
            }
        });
    }

    /// Media refs any circle member flagged sensitive. Desktop has no on-device classifier (Apple's
    /// SCA has no equivalent here), so we author no flags — but we HONOR the federated ones, which is
    /// the whole point of `SensitiveFlag` riding the event log. See `apple/HavenApp/SensitiveContent.swift`.
    pub fn sensitive_refs(&self, circle_id: &str) -> Vec<String> {
        self.social.sensitive_refs(circle_id.to_string())
    }

    pub fn post(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>, mute_video: bool) {
        if body.trim().is_empty() && media.is_empty() && music.is_none() {
            return;
        }
        match self.social.post(circle_id.clone(), body, media.clone(), music, None, false, mute_video, now_ms()) {
            Ok(env) => {
                self.after_author(&circle_id, &env);
                let me = self.clone();
                tauri::async_runtime::spawn(async move {
                    for r in media {
                        me.upload_media(&circle_id, &r).await;
                    }
                });
            }
            Err(e) => log::error!("post failed: {e}"),
        }
    }

    pub fn post_story(self: &Arc<Self>, body: String, media: Option<String>, music: Option<TrackRefFfi>) {
        if body.trim().is_empty() && media.is_none() && music.is_none() {
            return;
        }
        let media_vec: Vec<String> = media.iter().cloned().collect();
        match self.social.post(DEFAULT_CIRCLE.to_string(), body, media_vec, music, Some(86_400), true, false, now_ms()) {
            Ok(env) => {
                self.after_author(DEFAULT_CIRCLE, &env);
                if let Some(r) = media {
                    let me = self.clone();
                    tauri::async_runtime::spawn(async move { me.upload_media(DEFAULT_CIRCLE, &r).await; });
                }
            }
            Err(e) => log::error!("post_story failed: {e}"),
        }
    }

    pub fn comment(self: &Arc<Self>, circle_id: String, target: String, body: String) {
        if body.trim().is_empty() {
            return;
        }
        if let Ok(env) = self.social.comment(circle_id.clone(), target, body, vec![], now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn react(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        if let Ok(env) = self.social.react(circle_id.clone(), target, emoji, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn unreact(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        if let Ok(env) = self.social.unreact(circle_id.clone(), target, emoji, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn edit_post(self: &Arc<Self>, circle_id: String, target: String, body: String) {
        if let Ok(env) = self.social.edit(circle_id.clone(), target, body, vec![], None, false, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    pub fn unsend_post(self: &Arc<Self>, circle_id: String, target: String) {
        if let Ok(env) = self.social.unsend(circle_id.clone(), target, now_ms()) {
            self.after_author(&circle_id, &env);
        }
    }

    // ---- reports (decentralized moderation) -----------------------------------------------

    /// File a report against event `target`: seal + broadcast it to the whole circle (every member
    /// sees it and acts with the power they already hold) and append a content-free entry to the
    /// developer ledger. Returns the reported author's FULL node hex — resolved by the core from
    /// the event log — so the caller can offer block-in-the-same-motion. The caller hides the post
    /// locally (the reporter never sees it again).
    pub fn report(self: &Arc<Self>, circle_id: String, target: String, reason: String, comment: String) -> Option<String> {
        match self.social.report(circle_id.clone(), target.clone(), reason.clone(), comment, now_ms()) {
            Ok(env) => {
                self.after_author(&circle_id, &env);
                let author = self
                    .social
                    .reports(circle_id)
                    .into_iter()
                    .find(|r| r.target == target)
                    .map(|r| r.author);
                self.moderation_report(author.clone().unwrap_or_default(), reason);
                author
            }
            Err(e) => {
                log::error!("report failed: {e}");
                None
            }
        }
    }

    /// Every report filed in this circle (by any member), straight from the core event log.
    pub fn reports(&self, circle_id: &str) -> Vec<haven_ffi::ReportFfi> {
        self.social.reports(circle_id.to_string())
    }

    /// Fire-and-forget, content-free entry to the developer moderation ledger on the push Worker
    /// (App Review 1.2 parity with Apple/Android): subject × action × offense category — opaque
    /// node hexes only, never content. Free-text comments stay sealed to the circle.
    ///
    /// Only an explicit REPORT comes here (audit F1). **Blocking never touches the network**: it is
    /// a private, local decision to stop seeing someone, and it stays on the device. `action` is
    /// report-only server-side, so a block is unrepresentable here by construction.
    fn moderation_report(&self, subject: String, reason: String) {
        // The moderation flag is signed with the account identity key. A seedless device holds no
        // account seed, so it can't sign one (the primary owns this, like push registration — S6).
        let Some(seed) = self.seed else { return };
        let Some(body) = flag_body(&seed, &subject, &reason, now_ms() / 1000) else {
            return;
        };
        let http = self.http.clone();
        tauri::async_runtime::spawn(async move {
            // Manual JSON body — this crate's reqwest is built without the `json` feature
            // (default-features = false), which is what broke the beta.30 release build.
            let _ = http
                .post(format!("{PUSH_RELAY}/flag"))
                .header("content-type", "application/json")
                .body(body.to_string())
                .send()
                .await;
        });
    }

    /// Persist, bump the UI, and broadcast a freshly-authored sealed envelope to members.
    fn after_author(self: &Arc<Self>, circle_id: &str, env: &[u8]) {
        self.bump_activity(); // I just posted/messaged → keep sync tight
        self.persist();
        self.emit_changed();
        let payload = wire::event_payload(circle_id, env);
        for id_hex in self.social.contact_node_ids(circle_id.to_string()) {
            self.send_frame(wire::EVENT, &payload, &id_hex);
        }
        let me = self.clone();
        let cid = circle_id.to_string();
        let env = env.to_vec();
        tauri::async_runtime::spawn(async move {
            // The epoch HEAD (roster + current key commit) rides along with every authored event:
            // a relay-only peer could otherwise pull the event long before the commit that opens it
            // (it would sit in their pending-epoch buffer until the next full backfill). Cheap —
            // the commit is cached until the epoch/recipient set changes, and the persisted
            // seen-set dedupes the re-upload. iOS/Android parity.
            for head in me.social.export_epoch_head(cid.clone()) {
                me.upload_event(&cid, &head).await;
            }
            me.upload_event(&cid, &env).await;
            me.flush_seen_mailbox();
        });
    }

    // ---- DMs ----------------------------------------------------------------------------

    pub fn dm_circle_id(&self, id_hex: &str) -> String {
        let mut pair = [self.node_id_hex(), id_hex.to_string()];
        pair.sort();
        format!("dm:{}-{}", pair[0], pair[1])
    }

    fn dm_allows(circle_id: &str, node_hex: &str) -> bool {
        // 2+ members so group DMs are admitted too; the sender must be one of the encoded members.
        let parts: Vec<&str> = circle_id.trim_start_matches("dm:").split('-').collect();
        parts.len() >= 2 && parts.contains(&node_hex)
    }

    /// Deterministic GROUP-DM circle id — sorted node ids of every member (me + others).
    pub fn group_dm_circle_id(&self, other_hexes: &[String]) -> String {
        let mut all: Vec<String> = other_hexes.iter().map(|h| h.to_lowercase()).collect();
        all.push(self.node_id_hex());
        all.sort();
        all.dedup();
        format!("dm:{}", all.join("-"))
    }

    pub fn start_dm(self: &Arc<Self>, contact_id_hex: String, contact_name: String) -> String {
        let id = self.dm_circle_id(&contact_id_hex);
        self.social.create_circle(id.clone(), contact_name);
        let _ = self.social.add_existing_to_circle(id.clone(), contact_id_hex.clone());
        self.pin_dm_authority(&id); // §5 live-lane + §2 deterministic creator pin
        self.persist();
        self.send_hello(&id, &contact_id_hex);
        id
    }

    /// Open (or create) a GROUP DM with 2+ contacts (each `(id_hex, name)`); returns the dm circle id.
    pub fn start_group_dm(self: &Arc<Self>, members: Vec<(String, String)>) -> String {
        if members.len() == 1 {
            return self.start_dm(members[0].0.clone(), members[0].1.clone());
        }
        let hexes: Vec<String> = members.iter().map(|(h, _)| h.clone()).collect();
        let id = self.group_dm_circle_id(&hexes);
        let title = members.iter().map(|(_, n)| n.clone()).collect::<Vec<_>>().join(", ");
        self.social.create_circle(id.clone(), title);
        for (hex, _) in &members {
            let _ = self.social.add_existing_to_circle(id.clone(), hex.clone());
        }
        self.pin_dm_authority(&id); // §5 live-lane + §2 deterministic creator pin
        self.persist();
        for (hex, _) in &members {
            self.send_hello(&id, hex);
        }
        id
    }

    pub fn messages(&self, circle_id: &str) -> Vec<FeedItemFfi> {
        let mut m = self.social.feed(circle_id.to_string(), now_ms(), None);
        // Hide anything exchanged before this DM was cleared (see `delete_conversation`). A DM's circle id is
        // deterministic, so a re-started/re-synced thread would otherwise resurrect the old messages.
        if let Some(&cutoff) = self.prefs.lock().unwrap().dm_cleared_before.get(circle_id) {
            m.retain(|i| i.created_at >= cutoff);
        }
        m.sort_by_key(|i| i.created_at);
        m
    }

    /// Delete a whole DM conversation locally: record a "cleared before" watermark (so re-syncing or
    /// re-starting this deterministic-id DM won't restore old messages — true network deletion is
    /// impossible in P2P) and leave the circle. Mirrors iOS `FeedStore.deleteConversation`.
    pub fn delete_conversation(self: &Arc<Self>, circle_id: String) {
        if !circle_id.starts_with("dm:") {
            return;
        }
        {
            let mut p = self.prefs.lock().unwrap();
            p.dm_cleared_before.insert(circle_id.clone(), now_ms());
            let _ = p.save(&self.paths);
        }
        self.leave_circle(circle_id);
    }

    /// A DM carries a song exactly like a post does — the core's `post` has always taken a track
    /// (see `Engine::post`), this wrapper just never passed one, so the DM composer had no Song
    /// row and a SCHEDULED DM silently dropped the track the scheduler had already built for it.
    pub fn send_dm(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>) {
        // A song alone is a valid message — mirrors `post`'s guard.
        if body.trim().is_empty() && media.is_empty() && music.is_none() {
            return;
        }
        if let Ok(env) = self.social.post(circle_id.clone(), body, media.clone(), music, None, false, false, now_ms()) {
            self.after_author(&circle_id, &env);
            let me = self.clone();
            tauri::async_runtime::spawn(async move {
                for r in media {
                    me.upload_media(&circle_id, &r).await;
                }
            });
        }
    }

    /// A DM's read watermark: its `dm_last_read` entry, else the first-run seed (so pre-feature
    /// history doesn't badge). Mirrors iOS `DMReadStore.watermark`.
    fn dm_watermark(&self, circle_id: &str) -> u64 {
        let p = self.prefs.lock().unwrap();
        p.dm_last_read.get(circle_id).copied().unwrap_or(p.dm_read_seeded_at)
    }

    /// The user is viewing a DM thread: advance its watermark to "now or the newest visible message,
    /// whichever is later". Taking the message time into account absorbs sender clock skew — a
    /// message stamped slightly in our future would otherwise stay "unread" forever. Monotonic; the
    /// new watermark reaches our other devices via self-sync (`setting:dmLastRead`, per-key MAX).
    /// Deliberately does NOT emit `haven:changed` — the caller is mid-render (feedback loop).
    pub fn mark_dm_read(&self, circle_id: String) {
        let newest = self.messages(&circle_id).iter().map(|m| m.created_at).max().unwrap_or(0);
        let mark = now_ms().max(newest);
        let mut p = self.prefs.lock().unwrap();
        if mark <= p.dm_last_read.get(&circle_id).copied().unwrap_or(0) {
            return;
        }
        p.dm_last_read.insert(circle_id, mark);
        let _ = p.save(&self.paths);
    }

    /// DM threads as (circleId, partnerName, lastBody, lastAt, memberCount, unread). Sorted
    /// most-recently-active first. `memberCount` lets the UI tell a group DM (2+ others) from a 1:1;
    /// `unread` = inbound messages newer than the thread's read watermark (row/pin badge).
    pub fn dm_threads(&self) -> Vec<(String, String, String, u64, u32, u32)> {
        let (cleared, reads, seed) = {
            let p = self.prefs.lock().unwrap();
            (p.dm_cleared_before.clone(), p.dm_last_read.clone(), p.dm_read_seeded_at)
        };
        let mut out = vec![];
        for c in self.social.circles() {
            if !c.id.starts_with("dm:") {
                continue;
            }
            let cutoff = cleared.get(&c.id).copied();
            let wm = reads.get(&c.id).copied().unwrap_or(seed);
            let feed = self.social.feed(c.id.clone(), now_ms(), None);
            let visible: Vec<_> =
                feed.iter().filter(|i| cutoff.map_or(true, |cut| i.created_at >= cut)).collect();
            let (last_body, last_at) = visible
                .iter()
                .max_by_key(|i| i.created_at)
                .map(|i| (crate::secret::preview(&i.body), i.created_at))
                .unwrap_or_default();
            let unread =
                visible.iter().filter(|i| !i.is_me && !i.unsent && i.created_at > wm).count() as u32;
            out.push((c.id.clone(), c.name.clone(), last_body, last_at, c.member_count, unread));
        }
        out.sort_by(|a, b| b.3.cmp(&a.3));
        out
    }

    // ---- connect / handshake ------------------------------------------------------------

    pub fn connect_by_link(self: &Arc<Self>, uri: String) -> bool {
        let trimmed = uri.trim().to_string();
        let info = match parse_link(trimmed.clone()) {
            Ok(i) => i,
            Err(_) => return false,
        };
        // Scanning/pasting an invite is a DELIBERATE add: clear any old removal tombstone, or their
        // hellos stay dropped (handshake guard) and self-sync re-severs them (re-add never sticks).
        self.clear_circle_removal(DEFAULT_CIRCLE, &info.id_hex);
        // Store the invite's device-id hints BEFORE the hello, so the very first dial can reach
        // their device (their account id resolves to no node post-device-seed).
        self.record_device_hints(&info.id_hex, Self::extract_invite_hints(&trimmed));
        self.dyn_state
            .lock()
            .unwrap()
            .initiated
            .insert(info.id_hex.clone(), info.verification_hex.clone());
        self.send_hello(DEFAULT_CIRCLE, &info.id_hex);
        true
    }

    pub fn pending(&self) -> Vec<PendingRequest> {
        self.dyn_state.lock().unwrap().pending.clone()
    }

    pub fn approve(self: &Arc<Self>, id_hex: String) {
        let req = {
            let mut st = self.dyn_state.lock().unwrap();
            let idx = st.pending.iter().position(|p| p.id_hex == id_hex);
            idx.map(|i| st.pending.remove(i))
        };
        if let Some(req) = req {
            // Approving IS a deliberate re-add — clear any old removal tombstone or their hellos
            // stay dropped (handshake guard) and self-sync re-severs them on every pass.
            self.clear_circle_removal(DEFAULT_CIRCLE, &req.id_hex);
            self.accept_contact(DEFAULT_CIRCLE, &req.bundle, &req.id_hex, &req.name, &req.verify_hex, true);
            self.emit_changed();
        }
    }

    pub fn dismiss(self: &Arc<Self>, id_hex: String) {
        self.dyn_state.lock().unwrap().pending.retain(|p| p.id_hex != id_hex);
        self.emit_changed();
    }

    pub fn contacts(&self) -> Vec<Contact> {
        self.prefs.lock().unwrap().contacts.clone()
    }

    pub fn blocked(&self) -> Vec<String> {
        self.prefs.lock().unwrap().blocked.clone()
    }

    /// Blocking is local and private (audit F1) — it sends NOTHING to the network. No ledger flag,
    /// no developer notification: stopping seeing someone is nobody's business but the user's.
    pub fn block(self: &Arc<Self>, id_hex: String) {
        self.social.block_member(id_hex.clone());
        {
            let mut p = self.prefs.lock().unwrap();
            p.contacts.retain(|c| c.id_hex != id_hex);
            // LWW contact tombstone so the removal sticks fleet-wide (a sibling's additive `contact:`
            // record can't resurrect them). Mirrors iOS ContactsStore.remove.
            p.mark_contact_removed(&id_hex);
            if !p.blocked.contains(&id_hex) {
                p.blocked.push(id_hex.clone());
            }
            let _ = p.save(&self.paths);
        }
        self.dyn_state.lock().unwrap().pending.retain(|r| r.id_hex != id_hex);
        self.persist();
        self.emit_changed();
    }

    pub fn unblock(self: &Arc<Self>, id_hex: String) {
        let mut p = self.prefs.lock().unwrap();
        p.blocked.retain(|b| *b != id_hex);
        let _ = p.save(&self.paths);
    }

    fn accept_contact(self: &Arc<Self>, circle_id: &str, bundle: &[u8], id_hex: &str, name: &str, verify_hex: &str, hello_back: bool) {
        self.bump_activity(); // a peer just connected → sync tight for the catch-up burst
        let _ = self.social.add_contact_bundle(circle_id.to_string(), bundle.to_vec());
        {
            let mut p = self.prefs.lock().unwrap();
            // A deliberate (re-)add lifts any contact tombstone (LWW), so a previously-removed person can
            // be added back and a stale removal can't re-drop them. Mirrors iOS ContactsStore.add.
            p.mark_contact_readded(id_hex);
            if !p.contacts.iter().any(|c| c.id_hex == id_hex) {
                p.contacts.push(Contact {
                    id_hex: id_hex.to_string(),
                    name: name.to_string(),
                    verify_hex: verify_hex.to_string(),
                });
            }
            let _ = p.save(&self.paths);
        }
        self.persist();
        if hello_back {
            self.send_hello(circle_id, id_hex);
            // I'm the accepter sharing history → make sure the relay holds it ASAP so the new member
            // can pull it from the relay if the direct back-fill doesn't reach them.
            let me = self.clone();
            let cid = circle_id.to_string();
            tauri::async_runtime::spawn(async move { me.backfill_history_to_relay(&cid).await; });
        }
    }

    /// Ensure the relay holds this circle's FULL history (every event + every media blob I hold, not
    /// just my own) ASAP, so a newly-added member who can't receive it directly can pull it from the
    /// relay — no fragmented posts. Parity with iOS/Android. No-op without a mailbox.
    async fn backfill_history_to_relay(self: &Arc<Self>, circle_id: &str) {
        let has_relay = !self.relays_for(circle_id).is_empty();
        let has_s3 = self.prefs.lock().unwrap().s3.is_some();
        if !has_relay && !has_s3 {
            return;
        }
        for env in self.social.sync_envelopes(circle_id.to_string()) {
            self.upload_event(circle_id, &env).await;
        }
        let feed = self.social.feed(circle_id.to_string(), now_ms(), None);
        let mut refs: Vec<String> = vec![];
        for item in feed {
            for r in item.media {
                if !refs.contains(&r) {
                    refs.push(r);
                }
            }
            for cm in item.comments {
                for r in cm.media {
                    if !refs.contains(&r) {
                        refs.push(r);
                    }
                }
            }
        }
        for r in refs {
            if self.media.has(&r) {
                self.upload_media(circle_id, &r).await;
            }
        }
    }

    /// Resolve a feed item's short author id (8 hex) to a contact's display name.
    pub fn display_name(&self, author_short: &str) -> String {
        let p = self.prefs.lock().unwrap();
        p.contacts
            .iter()
            .find(|c| c.id_hex.starts_with(author_short))
            .map(|c| c.name.clone())
            .unwrap_or_else(|| {
                if author_short.len() >= 6 {
                    format!("Someone ({})", &author_short[..6])
                } else {
                    author_short.to_string()
                }
            })
    }

    // ---- outbound helpers ---------------------------------------------------------------

    fn hello_payload(&self, circle_id: &str) -> Option<Vec<u8>> {
        let profile = self.prefs.lock().unwrap().profile.clone();
        let name = if profile.name.trim().is_empty() { "Someone".to_string() } else { profile.name.clone() };
        let circle_name = self
            .social
            .circles()
            .into_iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.name)
            .unwrap_or_else(|| "My Circle".to_string());
        let bundle = self.social.my_bundle();
        // The avatar rides the signed card, same as iOS (`Profile.swift:90`) and Android
        // (`HavenNet.kt:1105`). The UI already caps it at 192px / JPEG q0.7 (`avatarDataUrl`), so
        // it's the same handful of KB those two send — but we store it as a `data:` URL and the
        // wire is RAW base64 (iOS decodes with `Data(base64Encoded:)`), hence the strip.
        let signed =
            self.social.my_signed_profile(name, profile.bio, profile.link, raw_base64(&profile.avatar), profile.emoji);
        Some(wire::hello_payload(circle_id, &circle_name, &bundle, &signed))
    }

    /// Send our Hello + back-fill this circle's events to one node.
    fn send_hello(self: &Arc<Self>, circle_id: &str, to_node_hex: &str) {
        let Some(hello) = self.hello_payload(circle_id) else { return };
        self.send_frame(wire::HELLO, &hello, to_node_hex);
        for env in self.social.sync_envelopes(circle_id.to_string()) {
            self.send_frame(wire::EVENT, &wire::event_payload(circle_id, &env), to_node_hex);
        }
        // Tell this peer about every relay I know for the circle, so we share all mailboxes.
        for node_hex in self.relays_for(circle_id) {
            if let Ok(sealed) = self.social.seal_circle_media(circle_id.to_string(), node_hex.into_bytes()) {
                self.send_frame(wire::RELAY_NODE, &wire::event_payload(circle_id, &sealed), to_node_hex);
            }
        }
    }

    pub fn sync_with_contacts(self: &Arc<Self>) {
        let ids: Vec<String> = self.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
        for id_hex in &ids {
            self.send_hello(DEFAULT_CIRCLE, id_hex);
        }
        // Proactively announce MY device roster (frame 27) every greet cycle — under device-id
        // transport a friend can only dial + authorize this desktop once they hold its signed
        // roster (iOS/Android parity; small, signed, receiver version-checks + dedups).
        let roster_wire = self.social.my_device_roster_wire();
        if !roster_wire.is_empty() {
            for id_hex in &ids {
                self.send_frame(wire::DEVICE_ROSTER, &roster_wire, id_hex);
            }
            // Bootstrap the device-id exchange over the RELAY too: when a friend flips to the
            // per-device transport their account id stops resolving, so a direct send can't carry
            // my roster — but their relay node IS reachable. Never announce to ourselves (a
            // self-dial sends iroh path discovery into the runaway loop).
            let my_acct = self.social.my_node_hex().to_lowercase();
            let my_dev = self.social.my_device_node_hex().to_lowercase();
            for c in self.social.circles() {
                for relay_hex in self.relays_for(&c.id) {
                    let h = relay_hex.to_lowercase();
                    if h == my_acct || h == my_dev || h.starts_with("s3:") {
                        continue;
                    }
                    self.send_frame(wire::DEVICE_ROSTER, &roster_wire, &relay_hex);
                }
            }
        }
        // PULL the rosters we're MISSING. Announcing ours (frame 27, above) only works when the
        // contact is DIRECTLY reachable; between two CGNAT networks it never lands in either
        // direction, so neither side can resolve the other's devices — and a device-signed call
        // frame, the ACCEPT included, then fails the declared-vs-signer check and is dropped as a
        // forgery. Their roster is already sitting on the relay, so ask for it. Cheap and idempotent:
        // only contacts we currently can't resolve, and the ingest is a no-op once we hold it.
        let unresolved: Vec<String> = ids
            .iter()
            .filter(|hex| {
                self.social
                    .device_node_ids_for((*hex).clone())
                    .iter()
                    .all(|d| d.eq_ignore_ascii_case(hex))
            })
            .cloned()
            .collect();
        // STRICTLY BOUNDED — see the note on `roster_pull_in_flight`. One pass at a time, a few
        // contacts per pass, and a long per-contact backoff, so an unresolvable contact costs
        // almost nothing instead of being re-dialled on every tick forever.
        const ROSTER_PULL_PER_PASS: usize = 3;
        const ROSTER_PULL_BACKOFF: std::time::Duration = std::time::Duration::from_secs(600);
        let due: Vec<String> = {
            let seen = self.roster_pull_at.lock().unwrap();
            unresolved
                .into_iter()
                .filter(|hex| {
                    seen.get(&hex.to_lowercase())
                        .map(|t| t.elapsed() > ROSTER_PULL_BACKOFF)
                        .unwrap_or(true)
                })
                .take(ROSTER_PULL_PER_PASS)
                .collect()
        };
        if !due.is_empty()
            && !self
                .roster_pull_in_flight
                .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            log::info!("devroster: pulling {} contact roster(s) from relays", due.len());
            let me = self.clone();
            tauri::async_runtime::spawn(async move {
                for hex in due {
                    me.roster_pull_at
                        .lock()
                        .unwrap()
                        .insert(hex.to_lowercase(), std::time::Instant::now());
                    me.fetch_contact_roster(&hex).await;
                }
                me.roster_pull_in_flight
                    .store(false, std::sync::atomic::Ordering::SeqCst);
            });
        }
        // Re-emit our own relay id whenever we re-greet contacts, so a peer that just came online surfaces
        // our relay instead of missing the one-shot announce.
        self.reannounce_own_relay();
    }

    fn send_frame(self: &Arc<Self>, t: u8, payload: &[u8], to_node_hex: &str) {
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        let frame = wire::frame(t, payload);
        // Transport edge (parity with iOS sendIroh / Android sendFrame): callers address an ACCOUNT
        // id so the social/allow logic stays on account ids; expand to that account's authorized
        // DEVICE ids here — under device-seed transport the account id alone resolves to NO node.
        // device_node_ids_for is identity for an unknown/device-id input, so pre-expanded callers
        // stay correct.
        let mut targets = self.social.device_node_ids_for(to_node_hex.to_string());
        if targets.is_empty() {
            targets.push(to_node_hex.to_string());
        }
        // Invite-link dial hints bridge the roster bootstrap: until this contact's signed roster
        // lands, their account id resolves to no node — the hint is the only real id.
        for h in self.device_hints_for(to_node_hex) {
            if !targets.iter().any(|t| t.eq_ignore_ascii_case(&h)) {
                targets.push(h);
            }
        }
        for to in targets {
            let node = node.clone();
            let frame = frame.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = node.send_to_node(to.clone(), frame).await {
                    log::debug!("send type={t} to {} failed: {e}", &to.chars().take(8).collect::<String>());
                }
            });
        }
    }

    // ---- inbound dispatch ---------------------------------------------------------------

    fn dispatch(self: &Arc<Self>, payload: Vec<u8>) {
        self.dispatch_from(None, payload)
    }

    /// `sender_device` = the AUTHENTICATED transport id the frame arrived from (None when relayed/
    /// unknown). A direct HELLO teaches us a dialable device id for its account — the reply-path
    /// bootstrap (an invitee holds no invite hints for the initiator).
    fn dispatch_from(self: &Arc<Self>, sender_device: Option<String>, payload: Vec<u8>) {
        if payload.is_empty() {
            return;
        }
        let t = payload[0];
        let body = payload[1..].to_vec();
        // Call/media frames lead with a 64-char sender hex — drop blocked senders early.
        if matches!(t, wire::MEDIA_REQ | wire::CALL_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE | wire::GROUP_INVITE) {
            if body.len() >= 64 {
                let head = String::from_utf8_lossy(&body[..64]).into_owned();
                if head.len() == 64 && self.prefs.lock().unwrap().blocked.contains(&head) {
                    return;
                }
            }
        }
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            me.dyn_state.lock().unwrap().internet_active = true;
            match t {
                wire::HELLO => me.handle_hello_from(sender_device.as_deref(), &body),
                wire::EVENT => me.handle_event(&body),
                wire::RELAY_NODE => me.handle_relay_node(&body).await,
                wire::MEDIA_REQ => me.handle_media_request(&body).await,
                wire::MEDIA_CHUNK => me.handle_media_chunk(&body),
                // CALL_HANDLED (30) rides the same sealed+signed path: it can silence a ringing
                // device, so it must be no more forgeable than an invite or a hangup.
                wire::CALL_INVITE | wire::GROUP_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP
                | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE | wire::CALL_HANDLED => me.handle_call(t, &body),
                wire::DEVICE_ENROLL => me.handle_enrollment_request(&body),
                wire::DEVICE_GRANT => me.handle_device_grant(&body),
                wire::SEEDLESS_ENROLL_REQ => me.handle_seedless_enroll_request(sender_device.as_deref(), &body),
                wire::SEEDLESS_ENROLL_GRANT => me.handle_seedless_enroll_grant(&body).await,
                wire::DEVICE_ROSTER => me.handle_device_roster_announce(&body),
                wire::RELAY => me.handle_relay(&body),
                _ => log::debug!("ignoring frame type {t} (not yet handled)"),
            }
            me.emit_changed();
        });
    }

    fn handle_hello(self: &Arc<Self>, payload: &[u8]) {
        self.handle_hello_from(None, payload)
    }

    fn handle_hello_from(self: &Arc<Self>, sender_device: Option<&str>, payload: &[u8]) {
        let Some(hello) = wire::parse_hello(payload) else { return };
        let id_hex = wire::node_hex(&hello.bundle);
        if self.prefs.lock().unwrap().blocked.contains(&id_hex) {
            return;
        }
        // A hello delivered DIRECTLY teaches us the sender's dialable device id for this account —
        // the reply-path bootstrap. The signed roster (frame 27) supersedes; a hint can at worst
        // misroute sealed frames (they stay unreadable), same trust as invite-link hints.
        if let Some(dev) = sender_device {
            if dev.len() == 64 && !dev.eq_ignore_ascii_case(&id_hex) {
                self.record_device_hints(&id_hex, vec![dev.to_lowercase()]);
            }
        }
        let Ok(actual_verify) = self.social.bundle_verification_hex(hello.bundle.clone()) else { return };
        // Switch-Flip 1.0.7 §0/§1: learn this peer's seed-drop + MLS capability from their signed
        // profile card (verified in-core; a forged/absent marker reads as legacy 0). This is the
        // affirmative signal every gate depends on — a circle stays legacy until ALL members are seen
        // capable. Piggybacks on the hello we already consume, so no extra round-trip.
        let _ = self.social.profile_seed_drop_version(hello.bundle.clone(), hello.signed_profile.clone());
        let name = self
            .social
            .verify_profile(hello.bundle.clone(), hello.signed_profile.clone())
            .unwrap_or_else(|| "Someone".to_string());

        if hello.circle_id.starts_with("dm:") && !Self::dm_allows(&hello.circle_id, &id_hex) {
            return;
        }
        // A member you explicitly removed from THIS circle must NOT auto-rejoin on their handshake
        // (parity with iOS/Android). Deliberate re-adds (approve / add_to_circle / connect_by_link)
        // clear the tombstone first, so this only blocks the unsolicited rejoin.
        if self.is_removed_from_circle(&hello.circle_id, &id_hex) {
            return;
        }
        self.social.create_circle(hello.circle_id.clone(), hello.circle_name.clone());
        if hello.circle_id.starts_with("dm:") {
            self.pin_dm_authority(&hello.circle_id); // §5 live-lane + §2 deterministic creator pin
        }

        let expected = self.dyn_state.lock().unwrap().initiated.get(&id_hex).cloned();
        if let Some(expected) = expected {
            if !expected.is_empty() && expected != actual_verify {
                log::warn!("verify mismatch for {id_hex} — dropping (possible MITM)");
                return;
            }
            self.accept_contact(&hello.circle_id, &hello.bundle, &id_hex, &name, &actual_verify, true);
            self.dyn_state.lock().unwrap().initiated.remove(&id_hex);
            return;
        }
        if self.prefs.lock().unwrap().contacts.iter().any(|c| c.id_hex == id_hex) {
            let _ = self.social.add_contact_bundle(hello.circle_id.clone(), hello.bundle.clone());
            return;
        }
        // A hello carrying a DEVICE bundle of an account we ALREADY know is not a new person. A linked
        // (seedless) device signs with its own key and carries its OWN bundle, so without this it
        // lands as a SECOND contact for someone we're already connected to: a connection request from
        // an identity we're already connected to, which — once accepted — shows as "Someone" and is
        // never online, because a contact record built from a device id names no account to route to.
        //
        // The device→account mapping comes from their ACCOUNT-SIGNED roster (`verify_devroster`), so a
        // stranger cannot claim to be somebody's device; an unknown device id maps to nothing and
        // still takes the normal approval path below.
        if let Some(account) = self.social.account_for_device(id_hex.clone()) {
            let account = account.to_lowercase();
            if !account.eq_ignore_ascii_case(&id_hex) {
                self.record_device_hints(&account, vec![id_hex.to_lowercase()]);
                log::info!(
                    "hello from {} is a DEVICE of known account {} — recorded as their device, not a new contact",
                    &id_hex.chars().take(8).collect::<String>(),
                    &account.chars().take(8).collect::<String>()
                );
                return;
            }
        }
        if !hello.circle_id.starts_with("dm:") {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.pending.iter().any(|p| p.id_hex == id_hex) {
                st.pending.push(PendingRequest { id_hex, name, verify_hex: actual_verify, bundle: hello.bundle });
            }
        }
    }

    fn handle_event(self: &Arc<Self>, payload: &[u8]) {
        let Some(ev) = wire::parse_event(payload) else { return };
        let changed = self.social.receive(ev.circle_id.clone(), ev.envelope).unwrap_or(false);
        if changed {
            self.bump_activity(); // a live event arrived → keep sync tight while the conversation is active
            self.persist();
            self.emit_changed();
            self.request_missing_media();
            // Freshness + persisted dedupe: a re-delivered / re-sealed old envelope (history
            // resend, epoch churn, key commit) must not re-notify (see notify_circle).
            self.notify_circle(&ev.circle_id);
        }
    }

    // ---- relay / mailbox ----------------------------------------------------------------

    async fn handle_relay_node(self: &Arc<Self>, body: &[u8]) {
        let mut r = wire::Reader::new(body);
        let Some(cid) = r.lp() else { return };
        let circle_id = String::from_utf8_lossy(&cid).into_owned();
        let sealed = r.rest();
        if circle_id.is_empty() || sealed.is_empty() {
            return;
        }
        let Some(opened) = self.social.open_circle_media_sender(circle_id.clone(), sealed) else { return };
        let announcer_hex = opened.sender_hex.to_lowercase(); // authenticated envelope sender (account id)
        let text = String::from_utf8_lossy(&opened.data).trim().to_string();
        // Extended announce: JSON {node, urls, token} also carries the relay's plain-HTTP media
        // interface (the reliable cross-NAT path). Legacy announces are the bare 64-hex id.
        let mut announced_urls: Vec<String> = Vec::new();
        let mut announced_token = String::new();
        let mut announced_added_at: u64 = 0;
        let node_hex = if text.starts_with('{') {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else { return };
            announced_urls = v["urls"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|u| u.as_str())
                        .filter(|u| u.starts_with("http"))
                        .map(|u| u.to_string())
                        .collect()
                })
                .unwrap_or_default();
            announced_token = v["token"].as_str().unwrap_or_default().to_string();
            announced_added_at = v["addedAt"].as_u64().unwrap_or(0);
            v["node"].as_str().unwrap_or_default().trim().to_lowercase()
        } else {
            text.to_lowercase()
        };
        if node_hex.len() != 64 {
            return;
        }
        {
            // A contact RE-ANNOUNCED a circle relay. Reactivating a deactivated/forgotten entry is
            // allowed ONLY when the announce comes from the relay's OWNER — the announced id is one of
            // the sender's own authorized device ids (their in-app relay; that's what lets your PC's
            // relay come back on your phone when the PC itself re-announces it), or their account id
            // (legacy account-id relay). A THIRD-PARTY echo must never resurrect it: every member
            // re-announces every relay they hold proof-of-life for, so a relay the user deliberately
            // deleted — but which is still RUNNING somewhere (an old docker container, a forgotten
            // daemon) — bounced back within one sync tick, forever. Non-owner announces of a tombstoned
            // relay are dropped; brand-new relays still auto-pool below. iOS/Android parity.
            let announcer_owns_relay = node_hex == announcer_hex
                || self
                    .social
                    .device_node_ids_for(announcer_hex.clone())
                    .iter()
                    .any(|d| d.to_lowercase() == node_hex);
            let mut p = self.prefs.lock().unwrap();
            let is_forgotten = p.suppressed_relays.contains(&node_hex);
            let is_inactive = !p.relay_is_active(&node_hex);
            let mut was_reactivated = false;
            if is_forgotten {
                // The user DELIBERATELY DELETED this relay. It comes back ONLY on a genuine re-add whose
                // adoption stamp is NEWER than our deletion (pure LWW) — NOT because its owner merely
                // reopened the app (that re-announces the relay's ORIGINAL, older adoption time). A stale
                // third-party echo and a legacy announce (addedAt=0) also lose. iOS/Android parity (the
                // "deleted relays came back when mom opened the app" fix).
                if announced_added_at <= p.relay_forgotten_at_ms(&node_hex) {
                    return;
                }
                // Clear the forget AND record a re-add timestamp so this legit newer re-add propagates
                // to my other devices via self-sync (relay-readd) — else a sibling keeps it deleted.
                p.relay_clear_forget(&node_hex);
                was_reactivated = true;
            } else if is_inactive {
                // Merely INACTIVE (deactivated, not deleted) — the owner may bring it back, or a newer
                // re-add. Keeps a PC's relay coming back on the phone when the PC re-announces it.
                let newer_re_add = announced_added_at > 0 && announced_added_at > p.relay_forgotten_at_ms(&node_hex);
                if !announcer_owns_relay && !newer_re_add {
                    return;
                }
                was_reactivated = true;
            }
            p.ensure_relay_entry(&node_hex, None, node_hex.starts_with("s3:"), was_reactivated);
            // Propagate the announced adoption stamp (not now()) so the freshest legit re-add flows across
            // the circle without any echo fabricating a new timestamp.
            p.set_relay_added_at(&node_hex, announced_added_at);
            let was_suppressed_or_inactive = was_reactivated;
            let list = p.relays.entry(circle_id.clone()).or_default();
            if !list.contains(&node_hex) {
                list.push(node_hex.clone());
            }
            // Record the relay's announced HTTP media interface (the reliable cross-NAT path).
            if !announced_urls.is_empty() && !announced_token.is_empty() {
                p.set_relay_http(&node_hex, announced_urls.clone(), announced_token.clone());
            }
            let _ = p.save(&self.paths);
            // Clear any stale backoff so a just-reactivated relay is retried immediately.
            if was_suppressed_or_inactive {
                drop(p);
                self.relay_health.lock().unwrap().remove(&node_hex);
            }
        }
        self.backfill_mailbox(&circle_id).await;
        self.poll_mailbox().await;
    }

    pub fn relay_status(&self) -> (bool, bool, bool, bool, bool) {
        let st = self.dyn_state.lock().unwrap();
        let prefs = self.prefs.lock().unwrap();
        // Only ACTIVE relays count — a fully-deactivated set means "no relay" even though configs linger.
        let has_relay = prefs
            .relays
            .values()
            .flatten()
            .any(|h| prefs.relay_is_active(h))
            || (!prefs.default_relay.is_empty() && prefs.relay_is_active(&prefs.default_relay))
            || prefs.s3.is_some();
        (st.hosting, has_relay, st.relay_active, st.internet_active, st.started)
    }

    /// The relay's node id (64-hex), which a friend pastes into "Adopt relay" so we share a
    /// mailbox. `None` unless we're currently hosting.
    pub fn relay_link(&self) -> Option<String> {
        self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex())
    }

    /// Start serving the circle's mailbox from this device + adopt it for every circle.
    pub async fn start_hosting(self: &Arc<Self>) -> Result<String> {
        {
            if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                return Ok(h.node_id_hex());
            }
        }
        // Attach the relay to the EXISTING messaging node's endpoint (one iroh node, two ALPNs) — a
        // second in-process iroh node made iroh churn paths unboundedly (the tens-of-GB leak). The relay
        // id is therefore the account node id.
        let Some(node) = self.node.lock().unwrap().clone() else {
            return Err(anyhow::anyhow!("relay host: messaging node not started yet"));
        };
        let dir = self.paths.relay_dir();
        std::fs::create_dir_all(&dir).ok();
        let handle = RelayServerHandle::attach(node, dir.to_string_lossy().to_string());
        let node_hex = handle.node_id_hex();
        *self.relay_host.lock().unwrap() = Some(handle.clone());
        self.dyn_state.lock().unwrap().hosting = true;
        // Lock the mailbox to circle members before announcing it (audit transport-F4).
        self.authorize_membership();
        // Plain-HTTP media interface — the DEFAULT cross-NAT media transport (the iroh blob ALPN
        // drops datagrams on pure-relay cross-NAT paths). Token-gated; the token travels only
        // inside the sealed frame-19 announce.
        self.start_relay_http(&handle, &node_hex).await;
        self.adopt_relay(node_hex.clone()).await;
        self.emit_changed();
        Ok(node_hex)
    }

    /// Serve the hosted relay's store over HTTP and record our URLs+token on our own RelayEntry so
    /// every announce carries them. URLs = the optional configured public URL first, then the LAN IP.
    async fn start_relay_http(self: &Arc<Self>, handle: &Arc<RelayServerHandle>, node_hex: &str) {
        let token = {
            let mut p = self.prefs.lock().unwrap();
            if p.relay_http_token.is_empty() {
                use rand::RngCore;
                let mut bytes = [0u8; 16];
                rand::rngs::OsRng.fill_bytes(&mut bytes);
                p.relay_http_token = bytes.iter().map(|b| format!("{b:02x}")).collect();
                let _ = p.save(&self.paths);
            }
            p.relay_http_token.clone()
        };
        let port = match handle.serve_http("0.0.0.0:8674".into(), token.clone()).await {
            Ok(p) => p,
            Err(_) => match handle.serve_http("0.0.0.0:0".into(), token.clone()).await {
                Ok(p) => p,
                Err(e) => {
                    log::warn!("relay http serve failed: {e}");
                    return;
                }
            },
        };
        let mut urls = Vec::new();
        {
            let p = self.prefs.lock().unwrap();
            if p.relay_public_url.starts_with("http") {
                urls.push(p.relay_public_url.trim_end_matches('/').to_string());
            }
        }
        if let Some(ip) = Self::primary_lan_ip() {
            urls.push(format!("http://{ip}:{port}"));
        }
        log::info!("relay http on :{port} urls={urls:?}");
        if urls.is_empty() {
            return;
        }
        let mut p = self.prefs.lock().unwrap();
        if p.set_relay_http(node_hex, urls, token) {
            let _ = p.save(&self.paths);
        }
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

    /// The frame-19 announce body for one relay: the legacy bare 64-hex node id, or — once the
    /// relay's plain-HTTP interface is known — JSON `{"node":hex,"urls":[…],"token":…}` so members
    /// also learn the reliable cross-NAT media path. A legacy receiver ignores the JSON form.
    fn relay_announce_body(&self, hex: &str) -> Vec<u8> {
        let p = self.prefs.lock().unwrap();
        let added_at = p.relay_entries.get(hex).map(|e| e.added_at_ms).unwrap_or(0);
        let http = p.relay_http(hex);
        drop(p);
        // Always carry the adoption timestamp so receivers can LWW a stale tombstone. Use the JSON form
        // whenever we have EITHER an HTTP interface or a non-zero adoption stamp; a legacy receiver ignores
        // JSON it can't read as a bare hex (wrong length), so mixed versions stay compatible.
        if http.is_some() || added_at > 0 {
            let mut obj = serde_json::json!({ "node": hex, "addedAt": added_at });
            if let Some((urls, token)) = http {
                obj["urls"] = serde_json::json!(urls);
                obj["token"] = serde_json::json!(token);
            }
            if let Ok(json) = serde_json::to_vec(&obj) {
                return json;
            }
        }
        hex.as_bytes().to_vec()
    }

    /// A contact's signed device roster (frame 27): learn which DEVICE ids to dial/seal for them,
    /// then re-authorize our hosted relay so those devices can read their mailboxes (iOS/Android
    /// parity — without this a friend's device-seed phone stays "forbidden" at this relay).
    fn handle_device_roster_announce(self: &Arc<Self>, body: &[u8]) {
        if self.social.ingest_roster_wire(body.to_vec()) {
            self.persist();
            self.authorize_membership();
        }
    }

    /// Push current circle membership to the in-process relay so each circle's mailbox is served ONLY
    /// to its members (+ sibling relays for mesh sync) — a stranger who learns the relay id gets
    /// nothing (audit transport-F4). Idempotent; call on host start and whenever membership changes.
    pub fn authorize_membership(self: &Arc<Self>) {
        let Some(handle) = self.relay_host.lock().unwrap().clone() else { return };
        let me = self.social.my_node_hex();
        for c in self.social.circles() {
            let mut accounts = self.social.contact_node_ids(c.id.clone());
            if !me.is_empty() && !accounts.contains(&me) {
                accounts.push(me.clone());
            }
            // Authorize each member at the TRANSPORT layer by their DEVICE ids (peers connect as
            // their device under device-seed transport), keeping the account id too for any
            // pre-multidevice peer. Includes MY OWN device ids so a sibling device can read this
            // host's mailbox. De-duplicated. Parity with iOS circleMemberships().
            let mut members: Vec<String> = Vec::new();
            for a in &accounts {
                if !members.contains(a) {
                    members.push(a.clone());
                }
                for d in self.social.device_node_ids_for(a.clone()) {
                    if !members.contains(&d) {
                        members.push(d);
                    }
                }
            }
            let relays = self.relays_for(&c.id);
            handle.authorize_circle(c.id.clone(), members, relays);
        }
    }

    pub fn stop_hosting(self: &Arc<Self>) {
        *self.relay_host.lock().unwrap() = None;
        self.dyn_state.lock().unwrap().hosting = false;
        self.emit_changed();
    }

    /// Re-emit THIS host's own relay id (frame 19) to every circle's contacts, WITHOUT adopt_relay's heavy
    /// backfill. Frame 19 used to fire only once at relay start, so a sibling/friend that wasn't reachable
    /// at that instant never learned the relay (the iPhone "sees the PC but won't show its relay"). Cheap
    /// (one sealed announce per circle per contact), so it's safe to run every sync tick. No-op unless we're
    /// hosting. (Desktop has no nearby/Bluetooth mesh, so this is the iroh-only subset of the iOS fix.)
    pub fn reannounce_own_relay(self: &Arc<Self>) {
        // Re-emit EVERY relay this device knows for each circle — not just the one it hosts. A
        // frame-19 announce used to fire once at relay start / adopt time, so a member who wasn't
        // reachable at that instant never learned an adopted EXTERNAL relay (NAS docker daemon).
        // Android re-announces all circle relays per hello; this is that parity (iOS too).
        let own_hex = self
            .relay_host
            .lock()
            .unwrap()
            .as_ref()
            .map(|h| h.node_id_hex())
            .filter(|h| h.len() == 64);
        for c in self.social.circles() {
            // ONLY announce relays WE have proof of life for (a successful op within 5 min) or the
            // one we host. Re-announcing everything ever LEARNED made dead relay ids echo around
            // the mesh forever (each member re-broadcast them; receivers reactivated them).
            let now = now_ms();
            let mut hexes: Vec<String> = {
                let p = self.prefs.lock().unwrap();
                let health = self.relay_health.lock().unwrap();
                p.relays
                    .get(&c.id)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|h| {
                        h.len() == 64
                            && !h.starts_with("s3:")
                            && p.relay_is_active(h)
                            && health.get(h).map(|hh| hh.proven_alive(now, 300_000)).unwrap_or(false)
                    })
                    .collect()
            };
            if let Some(own) = &own_hex {
                if !hexes.iter().any(|h| h == own) {
                    hexes.push(own.clone());
                }
            }
            if hexes.is_empty() {
                continue;
            }
            let members = self.social.contact_node_ids(c.id.clone());
            for hex in &hexes {
                let body = self.relay_announce_body(hex);
                let Ok(sealed) = self.social.seal_circle_media(c.id.clone(), body.clone()) else { continue };
                let frame = wire::event_payload(&c.id, &sealed);
                for id_hex in &members {
                    self.send_frame(wire::RELAY_NODE, &frame, id_hex);
                }
            }
        }
    }

    /// Periodically mirror MY OWN media to every circle relay I know (idempotent backup). The cross-device
    /// chunk request/response path is unreliable, so instead each device durably mirrors its own media to
    /// the relays it knows — including a sibling's hosted relay — and the other side reads it back during
    /// its normal poll/restore. upload_media is content-addressed + idempotent (re-puts are cheap), so this
    /// just fills gaps. Throttled to ~once per 2 min by the caller.
    async fn backfill_media_to_relays(self: &Arc<Self>) {
        let circle_ids: Vec<String> = self.social.circles().into_iter().map(|c| c.id).collect();
        for circle_id in circle_ids {
            // Broaden to media_dests (every known relay, not just the circle's own) so media still
            // backs up when a circle's own relays are all offline but some OTHER relay is reachable.
            let has_relay = !self.media_dests(&circle_id).is_empty();
            let has_s3 = self.prefs.lock().unwrap().s3.is_some();
            if !has_relay && !has_s3 {
                continue;
            }
            let feed = self.social.feed(circle_id.clone(), now_ms(), None);
            let mut refs: Vec<String> = vec![];
            for item in feed {
                if !item.is_me {
                    continue; // only MY media — others' media is mirrored by their own devices
                }
                for r in item.media {
                    if !LocalMedia::is_synthetic(&r) && self.media.has(&r) && !refs.contains(&r) {
                        refs.push(r);
                    }
                }
                for cm in item.comments {
                    for r in cm.media {
                        if !LocalMedia::is_synthetic(&r) && self.media.has(&r) && !refs.contains(&r) {
                            refs.push(r);
                        }
                    }
                }
            }
            for r in refs {
                self.upload_media(&circle_id, &r).await;
            }
        }
    }

    /// Publish THIS account's account-SIGNED device roster to EVERY known relay under the permission-free
    /// key `haven/devroster/<accountHex>`. A device connects to a relay AS its DEVICE id, but a HEADLESS
    /// relay only knows ACCOUNT ids (from its operator's link), so without this it `ERR forbidden`s every
    /// one of the account's devices' mailbox ops — "my own NAS relay rejects my PC". The wire (from
    /// `export_own_roster`) carries the account bundle + an account-signed DeviceList, so the relay
    /// verifies it WITHOUT decrypting anything and then authorizes the account's device ids. The key is
    /// permission-free, so this bootstrap write is allowed BEFORE authorization. Idempotent + cheap;
    /// called on the sync timer so a restarted relay re-learns our devices promptly. Mirrors iOS
    /// `publishDeviceRoster(social:)`.
    async fn publish_device_roster(self: &Arc<Self>) {
        self.publish_device_roster_inner(false).await
    }

    /// `force` = publish even to a relay we believe already holds these exact bytes. Required by
    /// `heal_forbidden_relays`: a refusal means the relay does NOT have a usable roster from us, so
    /// the content-hash skip must not suppress the very publish that fixes it.
    ///
    /// A roster is ~30 KB (hybrid PQ credentials are simply that big) and this ran on the sync tick
    /// against every relay regardless of change — tens of KB per relay every couple of minutes,
    /// forever, which is what produced `relay put timed out` / ConnectionLost in the field logs and
    /// starved the rest of sync. Content is what matters, so key on the wire's hash: an unchanged
    /// roster is re-sent only after ROSTER_REPUBLISH_MS as liveness, and any CHANGE publishes at once.
    async fn publish_device_roster_inner(self: &Arc<Self>, force: bool) {
        const ROSTER_REPUBLISH_MS: u64 = 1_800_000; // 30 min
        let Some(r) = self.social.export_own_roster().into_iter().next() else { return };
        let key = format!("haven/devroster/{}", r.account_hex);
        let wire = r.wire;
        if wire.is_empty() {
            return;
        }
        let wire_hash = {
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            wire.hash(&mut h);
            h.finish()
        };
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        let nodes: Vec<String> = {
            let p = self.prefs.lock().unwrap();
            p.all_active_relay_hexes().into_iter().filter(|h| !h.starts_with("s3:")).collect()
        };
        let mut skipped = 0usize;
        for node_hex in nodes {
            // Our OWN hosted relay: write straight into the local store (no iroh self-dial).
            if hosted.as_deref() == Some(node_hex.as_str()) {
                if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                    h.local_put(key.clone(), wire.clone());
                }
                continue;
            }
            // Already holds these exact bytes and confirmed recently → nothing to say.
            if !force {
                let seen = self.roster_published.lock().unwrap().get(&node_hex).copied();
                if let Some((hash, at)) = seen {
                    if hash == wire_hash && now_ms().saturating_sub(at) < ROSTER_REPUBLISH_MS {
                        skipped += 1;
                        continue;
                    }
                }
            }
            // Plain-HTTP interface first (the reliable cross-NAT path), else the iroh dial.
            let http_iface = self.prefs.lock().unwrap().relay_http(&node_hex);
            if let Some((urls, token)) = http_iface {
                let mut done = false;
                for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                    if self.http_put(base, &token, &key, wire.clone()).await {
                        self.mark_relay_ok(&node_hex);
                        self.roster_published.lock().unwrap().insert(node_hex.clone(), (wire_hash, now_ms()));
                        done = true;
                        break;
                    }
                    self.mark_http_url_bad(base);
                }
                if done {
                    continue;
                }
            }
            if let Some(client) = self.relay_client_for(&node_hex).await {
                match client.put(key.clone(), wire.clone()).await {
                    Ok(()) => {
                        self.mark_relay_ok(&node_hex);
                        self.roster_published.lock().unwrap().insert(node_hex.clone(), (wire_hash, now_ms()));
                    }
                    Err(e) => {
                        self.relay_failed(&node_hex).await;
                        log::info!("devroster put FAIL relay={}: {e}", &node_hex.chars().take(8).collect::<String>());
                        self.adopt_newer_own_roster_and_retry(&node_hex, &key, &wire, &e.to_string()).await;
                    }
                }
            }
        }
        if skipped > 0 {
            log::info!("devroster: {skipped} relay(s) already hold this exact roster — not re-sending {} B each", wire.len());
        }
    }

    /// Recover from a REFUSED publish of our own roster.
    ///
    /// `verify_devroster_put` applies a rollback defense: a validly-signed roster whose version is
    /// strictly OLDER than the one already stored is refused (audit R6). Correct against replay, but a
    /// deadlock for a device that has simply fallen behind another of its own: the publish IS the
    /// bootstrap that authorizes the device, so a refused publish means it can never become
    /// authorized, and every later op (media PUT, media GET, frame-9 forwarding of a call accept) is
    /// forbidden too — the call never connects and blobs never land. `heal_forbidden_relays` cannot
    /// help: it answers a refusal by re-publishing, and the publish is what is refused.
    ///
    /// So adopt what we are being out-versioned by, then publish again at that version. Pulling our
    /// own roster back is safe for the same reason the relay's check is: `ingest_roster_wire` verifies
    /// the ACCOUNT signature, and only our account key could have produced it — a relay can serve it,
    /// never forge it. Mirrors iOS `SharedStore.adoptNewerOwnRosterAndRetry`.
    async fn adopt_newer_own_roster_and_retry(self: &Arc<Self>, node_hex: &str, key: &str, sent: &[u8], error: &str) {
        if !error.to_lowercase().contains("forbidden") {
            return;
        }
        let Some(acct) = self.social.export_own_roster().into_iter().next().map(|r| r.account_hex) else { return };
        let short = node_hex.chars().take(8).collect::<String>();
        log::info!("devroster refused by {short} — pulling the newer roster it holds and re-publishing");
        if !self.fetch_contact_roster(&acct).await {
            log::info!("devroster: could not read our own stored roster back from any relay — still unauthorized on {short}");
            return;
        }
        let Some(fresh) = self.social.export_own_roster().into_iter().next() else { return };
        if fresh.wire == sent {
            log::info!("devroster: adopted roster is identical to the one refused — refusal is NOT a version rollback on {short}");
            return;
        }
        let Some(client) = self.relay_client_for(node_hex).await else { return };
        match client.put(key.to_string(), fresh.wire).await {
            Ok(()) => {
                self.mark_relay_ok(node_hex);
                log::info!("devroster put OK relay={short} after adopting its newer roster — this device is authorized again");
            }
            Err(e) => log::info!("devroster STILL refused by {short} after adopting: {e}"),
        }
    }

    /// PULL a CONTACT's device roster from the relays and ingest it — the missing half of
    /// `publish_device_roster`, which only ever PUSHED our own.
    ///
    /// The only other way to learn a contact's roster is frame 27, sent over a DIRECT iroh send on the
    /// periodic sweep. That never arrives when neither peer is directly reachable — two CGNAT
    /// networks, Starlink being the everyday case. Without their roster `account_for_device` cannot map
    /// their signing device to their account, so every device-signed call frame they send us fails the
    /// declared-vs-signer check in `handle_call` and is discarded as a forgery. That is precisely "the
    /// callee answers, the caller sits on Calling forever": their ACCEPT arrives and we throw it away.
    /// The relay held their roster the whole time — nobody ever asked it for one.
    ///
    /// Safe against a hostile relay: `ingest_roster_wire` verifies the ACCOUNT signature over the
    /// DeviceList and refuses anything not bound to the account named in the key, so a relay can serve
    /// these bytes but cannot forge or alter them. Mirrors iOS `SharedStore.fetchContactRoster`.
    async fn fetch_contact_roster(self: &Arc<Self>, account_hex: &str) -> bool {
        let acct = account_hex.to_lowercase();
        if acct.len() != 64 {
            return false;
        }
        let key = format!("haven/devroster/{acct}");
        let short = acct.chars().take(8).collect::<String>();
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        // Our own hosted store first — no dial, and a relay-hosting device usually already holds it.
        if hosted.is_some() {
            let local = self.relay_host.lock().unwrap().as_ref().and_then(|h| h.local_get(key.clone()));
            if let Some(w) = local {
                if !w.is_empty() && self.social.ingest_roster_wire(w) {
                    log::info!("devroster PULLED {short} from own store — their devices are now resolvable");
                    self.authorize_membership();
                    return true;
                }
            }
        }
        let nodes: Vec<String> = {
            let p = self.prefs.lock().unwrap();
            p.all_active_relay_hexes().into_iter().filter(|h| !h.starts_with("s3:")).collect()
        };
        for node_hex in nodes {
            if hosted.as_deref() == Some(node_hex.as_str()) {
                continue;
            }
            let http_iface = self.prefs.lock().unwrap().relay_http(&node_hex);
            if let Some((urls, token)) = http_iface {
                for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                    match self.http_get(base, &token, &key).await {
                        Ok(Some(w)) => {
                            if !w.is_empty() && self.social.ingest_roster_wire(w) {
                                self.mark_relay_ok(&node_hex);
                                log::info!("devroster PULLED {short} from relay {}", &node_hex.chars().take(8).collect::<String>());
                                self.authorize_membership();
                                return true;
                            }
                        }
                        // A refusal routes through note_refused, so a relay that doesn't know us yet
                        // triggers a roster publish rather than a backoff — same self-heal as media.
                        Err(RelayErr::Forbidden) => self.note_refused(&node_hex, &format!("devroster read for {short}")),
                        Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                        _ => {}
                    }
                }
            }
            if let Some(client) = self.relay_client_for(&node_hex).await {
                if let Some(w) = client.get(key.clone()).await {
                    if !w.is_empty() && self.social.ingest_roster_wire(w) {
                        self.mark_relay_ok(&node_hex);
                        log::info!("devroster PULLED {short} from relay {} (dial)", &node_hex.chars().take(8).collect::<String>());
                        self.authorize_membership();
                        return true;
                    }
                }
            }
        }
        false
    }

    /// Adopt a relay node for all circles (ADDED to the redundant set, not replacing existing
    /// relays) + tell contacts via frame 19. Adopt several for redundancy.
    pub async fn adopt_relay(self: &Arc<Self>, node_hex: String) {
        let hex = node_hex.trim().to_lowercase();
        if hex.len() != 64 {
            return;
        }
        {
            // Explicit adoption overrides a prior Forget AND reactivates the entry — re-adding a
            // previously-deactivated relay always works. Mirrors iOS `add(circleId:nodeHex:)`.
            let mut p = self.prefs.lock().unwrap();
            p.relay_clear_forget(&hex);        // explicit adoption clears the deletion stamp + records re-add
            p.ensure_relay_entry(&hex, None, false, true);
            p.set_relay_added_at(&hex, 0);     // fresh adoption stamp = now()
            let _ = p.save(&self.paths);
        }
        for c in self.social.circles() {
            {
                let mut p = self.prefs.lock().unwrap();
                let list = p.relays.entry(c.id.clone()).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
                let _ = p.save(&self.paths);
            }
            if let Ok(sealed) = self.social.seal_circle_media(c.id.clone(), self.relay_announce_body(&hex)) {
                let frame = wire::event_payload(&c.id, &sealed);
                for id_hex in self.social.contact_node_ids(c.id.clone()) {
                    self.send_frame(wire::RELAY_NODE, &frame, &id_hex);
                }
            }
            self.backfill_mailbox(&c.id).await;
        }
        self.poll_mailbox().await;
    }

    /// Normalize a relay hex: lower/trim a Haven node id, but leave a synthetic `s3:<bucket>` id as-is.
    fn norm_relay_hex(node_hex: &str) -> String {
        if node_hex.starts_with("s3:") {
            node_hex.to_string()
        } else {
            node_hex.trim().to_lowercase()
        }
    }

    /// DEACTIVATE a relay across EVERY circle (the old "forget" entry point, now non-destructive):
    /// flip active=false, KEEP its name + circle associations, suppress auto-relearn while inactive, and
    /// drop its cached connection + health. The config survives so it can be reactivated later.
    /// `relays_for` already filters inactive entries out, so it stops being dialed/served immediately.
    /// Mirrors iOS `forget(nodeHex:)`.
    pub async fn forget_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            let is_s3 = hex.starts_with("s3:");
            p.ensure_relay_entry(&hex, None, is_s3, false);
            if let Some(e) = p.relay_entries.get_mut(&hex) {
                e.active = false;
            }
            if !p.suppressed_relays.contains(&hex) {
                p.suppressed_relays.push(hex.clone());
            }
            p.relay_stamp_forgot(&hex);   // LWW: stamp forgot now (+ syncs the deletion), re-add only wins if newer
            let _ = p.save(&self.paths);
        }
        self.relay_clients.lock().await.remove(&hex);
        self.relay_health.lock().unwrap().remove(&hex);
        // A forgotten relay may be wiped — drop its media confirmations so a re-adopted one is re-mirrored.
        self.forget_media_backed_up(&hex);
        self.flush_media_backed_up();
        self.emit_changed();
    }

    /// Reactivate a deactivated relay: flip active=true and clear its suppression + backoff so it's
    /// dialed again. Mirrors iOS `reactivate`.
    pub async fn reactivate_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            p.relay_clear_forget(&hex);        // explicit reactivation clears the deletion stamp + records re-add
            p.ensure_relay_entry(&hex, None, hex.starts_with("s3:"), true);
            p.set_relay_added_at(&hex, 0);     // fresh adoption stamp = now()
            let _ = p.save(&self.paths);
        }
        self.relay_health.lock().unwrap().remove(&hex);
        self.emit_changed();
    }

    /// Rename a relay (user-facing label only). Mirrors iOS `rename`.
    pub fn rename_relay(self: &Arc<Self>, node_hex: String, name: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return;
        }
        let mut p = self.prefs.lock().unwrap();
        if let Some(e) = p.relay_entries.get_mut(&hex) {
            e.name = trimmed.to_string();
            let _ = p.save(&self.paths);
            drop(p);
            self.emit_changed();
        }
    }

    /// Pick the all-circles default relay (every present + future circle inherits it). Empty = unset.
    /// Mirrors iOS `setDefault`.
    pub fn set_default_relay(self: &Arc<Self>, node_hex: String) {
        let mut p = self.prefs.lock().unwrap();
        if node_hex.is_empty() {
            p.default_relay.clear();
        } else {
            let hex = Self::norm_relay_hex(&node_hex);
            p.ensure_relay_entry(&hex, None, hex.starts_with("s3:"), true);
            p.default_relay = hex;
        }
        let _ = p.save(&self.paths);
        drop(p);
        self.emit_changed();
    }

    /// ERASE a relay for good — removes its associations across every circle, its entry, the default, and
    /// its caches. Used by "Delete now" + purge_stale. Mirrors iOS `eraseNow`.
    pub async fn erase_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            for list in p.relays.values_mut() {
                list.retain(|h| h != &hex);
            }
            p.relays.retain(|_, v| !v.is_empty());
            if p.default_relay == hex {
                p.default_relay.clear();
            }
            p.relay_entries.remove(&hex);
            if !p.suppressed_relays.contains(&hex) {
                p.suppressed_relays.push(hex.clone());
            }
            p.relay_stamp_forgot(&hex);   // LWW deletion stamp (+ syncs the deletion to my other devices)
            let _ = p.save(&self.paths);
        }
        self.relay_clients.lock().await.remove(&hex);
        self.relay_health.lock().unwrap().remove(&hex);
        self.emit_changed();
    }

    /// ERASE only relays that are BOTH inactive AND unseen for > 7 days. An ACTIVE relay that's merely
    /// unreachable is never purged. Called on launch + on the sync timer. Mirrors iOS `purgeStale`.
    pub async fn purge_stale_relays(self: &Arc<Self>) {
        let dead = self.prefs.lock().unwrap().stale_relay_hexes();
        for hex in dead {
            self.erase_relay(hex).await;
        }
    }

    /// Add or remove a single relay's ASSOCIATION with exactly one circle (the per-circle override).
    /// Mirrors iOS `setCircleRelay`.
    pub async fn set_circle_relay(self: &Arc<Self>, node_hex: String, circle_id: String, on: bool) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            if on {
                p.relay_clear_forget(&hex);   // turning a relay on for a circle is an explicit re-add
                p.ensure_relay_entry(&hex, None, hex.starts_with("s3:"), true);
                let list = p.relays.entry(circle_id.clone()).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
            } else if let Some(list) = p.relays.get_mut(&circle_id) {
                list.retain(|h| h != &hex);
                if list.is_empty() {
                    p.relays.remove(&circle_id);
                }
            }
            let _ = p.save(&self.paths);
        }
        if on {
            self.backfill_mailbox(&circle_id).await;
        }
        self.poll_mailbox().await;
        self.emit_changed();
    }

    /// Add an S3 bucket as a (store-and-forward) relay: validate + persist its creds (secret → keychain
    /// via the existing s3_configure path), record an `s3:<bucket>` RelayEntry so it shows in the Relays
    /// list, associate it with every circle, and optionally make it the default. Returns its synthetic id.
    /// Mirrors iOS `addS3Relay`.
    pub async fn add_s3_relay(
        self: &Arc<Self>,
        pub_cfg: store::S3Public,
        secret_key: String,
        name: String,
        set_default: bool,
    ) -> Result<String> {
        let bucket = pub_cfg.bucket.clone();
        let hex = format!("s3:{bucket}");
        // s3_configure validates connectivity, stores the secret in the keychain, and sets prefs.s3.
        self.s3_configure(pub_cfg, secret_key).await?;
        {
            let mut p = self.prefs.lock().unwrap();
            let label = if name.trim().is_empty() { format!("S3 · {bucket}") } else { name.trim().to_string() };
            p.ensure_relay_entry(&hex, Some(&label), true, true);
            for c in self.social.circles() {
                let list = p.relays.entry(c.id).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
            }
            if set_default {
                p.default_relay = hex.clone();
            }
            let _ = p.save(&self.paths);
        }
        for c in self.social.circles() {
            self.backfill_mailbox(&c.id).await;
        }
        self.poll_mailbox().await;
        self.emit_changed();
        Ok(hex)
    }

    /// Full per-relay detail (active + inactive) for the Relays hub. One row per configured RelayEntry,
    /// sorted active-first then by name. Mirrors iOS `allEntries`.
    pub fn relays_detail(&self) -> Vec<RelayDetail> {
        let now = now_ms();
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        let prefs = self.prefs.lock().unwrap();
        let health = self.relay_health.lock().unwrap();
        let mut out: Vec<RelayDetail> = prefs
            .relay_entries
            .values()
            .map(|e| RelayDetail {
                node_hex: e.hex.clone(),
                name: e.name.clone(),
                active: e.active,
                is_s3: e.is_s3,
                is_default: prefs.default_relay == e.hex,
                hosted: hosted.as_deref() == Some(e.hex.as_str()),
                reachable: health.get(&e.hex).map(|h| h.available(now)).unwrap_or(true),
            })
            .collect();
        out.sort_by(|a, b| match (a.active, b.active) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
        });
        out
    }

    /// The set of relay hexes explicitly associated with a circle (INCLUDING inactive) — for the
    /// per-circle override toggles. Mirrors iOS `explicitRelays(forCircle:)`.
    pub fn circle_relay_hexes(&self, circle_id: &str) -> Vec<String> {
        self.prefs.lock().unwrap().relays.get(circle_id).cloned().unwrap_or_default()
    }

    /// The redundant ACTIVE relay set for a circle (mirrored writes, fallback reads). Deactivated relays
    /// are filtered out so they aren't dialed/served, but their config survives. Includes the all-circles
    /// default. Mirrors iOS `relays(forCircle:)`.
    fn relays_for(&self, circle_id: &str) -> Vec<String> {
        self.prefs.lock().unwrap().active_relays_for(circle_id)
    }

    /// Relay hexes to MIRROR media to / FETCH media from — the circle's own active relays PLUS every
    /// OTHER active relay this device knows (s3 excluded, deduped). Media keys (`haven/media/<ref>`) are
    /// content-addressed AND permission-free on a relay (unlike membership-gated mailbox keys — a relay
    /// can `ERR forbidden` a device for messages while still storing its media), so a blob may safely
    /// live on ANY relay the members can reach. Broadening beyond the circle's own (possibly all-NAT'd)
    /// relays is what lands media when those are offline but some OTHER known relay is reachable; content
    /// addressing keeps the extra puts idempotent and mesh anti-entropy replicates it back later. Mirrors
    /// iOS `mediaDests(_:)`. Leave MAILBOX (message) paths on `relays_for` — those are membership-gated.
    fn media_dests(&self, circle_id: &str) -> Vec<String> {
        let p = self.prefs.lock().unwrap();
        let mut out: Vec<String> = p
            .active_relays_for(circle_id)
            .into_iter()
            .filter(|h| !h.starts_with("s3:"))
            .collect();
        for h in p.all_active_relay_hexes() {
            if !h.starts_with("s3:") && !out.contains(&h) {
                out.push(h);
            }
        }
        out
    }

    fn relay_available(&self, node_hex: &str) -> bool {
        let now = now_ms();
        self.relay_health.lock().unwrap().get(node_hex).map(|h| h.available(now)).unwrap_or(true)
    }

    fn mark_relay_ok(&self, node_hex: &str) {
        self.relay_health.lock().unwrap().entry(node_hex.to_string()).or_default().record_success_at(now_ms());
        // Stamp the relay's last-seen so purge_stale never reaps a relay that's actually working, and
        // an inactive relay's stale-clock only counts time since it last succeeded. Mirrors iOS markSeen.
        let mut p = self.prefs.lock().unwrap();
        if p.relay_entries.contains_key(node_hex) {
            p.relay_mark_seen(node_hex);
            let _ = p.save(&self.paths);
        }
    }

    fn mark_relay_fail(&self, node_hex: &str) {
        let now = now_ms();
        self.relay_health.lock().unwrap().entry(node_hex.to_string()).or_default().record_failure(now);
    }

    async fn relay_client_for(self: &Arc<Self>, node_hex: &str) -> Option<Arc<RelayClient>> {
        // An `s3:<bucket>` relay is a store-and-forward bucket, NOT a dialable iroh node — it's served
        // by the separate `s3_client()` path in upload_event/backfill. Never try to iroh-dial it.
        if node_hex.starts_with("s3:") {
            return None;
        }
        {
            let clients = self.relay_clients.lock().await;
            if let Some(c) = clients.get(node_hex) {
                return Some(c.clone());
            }
        }
        // NEVER dial our OWN node ids (account id — a pre-device-seed leftover in a relay list — or
        // our device id). A self-dial sends iroh's path discovery into a tight loop
        // (open_path_on_all_conns), exploding memory by tens of GB — THE runaway leak. We never need
        // a client to ourselves. Same root cause + fix as iOS/macOS.
        if self.social.my_node_hex().eq_ignore_ascii_case(node_hex)
            || self.social.my_device_node_hex().eq_ignore_ascii_case(node_hex)
        {
            return None;
        }
        if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
            if h.node_id_hex() == node_hex {
                return None;
            }
        }
        // Skip a relay that's in its backoff window — try the others instead.
        if !self.relay_available(node_hex) {
            return None;
        }
        // Warm path (parity with iOS): dial over the messaging node's LONG-LIVED, DERP-established
        // endpoint instead of RelayClient::connect binding a fresh endpoint per client — the cold
        // endpoint restarts DERP discovery every time, which is exactly the cross-NAT 30s timeout
        // while messaging on the same relay path works.
        let warm = self.node.lock().unwrap().clone().and_then(|n| n.relay_client(node_hex.to_string()).ok());
        let res = match warm {
            Some(c) => Ok(c),
            // No messaging node yet → cold connect under the DEVICE seed (never the account seed:
            // the account id is identity-only and must not appear as a transport node).
            None => {
                let device_seed = self.roster.lock().unwrap().device_seed.clone();
                RelayClient::connect(device_seed, node_hex.to_string()).await
            }
        };
        match res {
            Ok(c) => {
                self.relay_clients.lock().await.insert(node_hex.to_string(), c.clone());
                Some(c)
            }
            Err(e) => {
                log::debug!("relay connect failed ({node_hex}): {e}");
                self.mark_relay_fail(node_hex);
                None
            }
        }
    }

    /// On a put/list/get failure: back the relay off and drop its cached connection.
    async fn relay_failed(self: &Arc<Self>, node_hex: &str) {
        self.mark_relay_fail(node_hex);
        self.relay_clients.lock().await.remove(node_hex);
    }

    fn mailbox_key(circle_id: &str, env: &[u8]) -> String {
        let mut h = Sha256::new();
        h.update(env);
        let hex: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        format!("haven/mailbox/{circle_id}/{hex}")
    }

    /// Record a mailbox key as ingested/uploaded; [`Self::flush_seen_mailbox`] persists the set
    /// (call it once after a poll/backfill pass) so the cursor survives restarts.
    fn mark_mailbox_seen(&self, key: String) {
        let mut st = self.dyn_state.lock().unwrap();
        if st.seen_mailbox.insert(key) {
            st.seen_mailbox_dirty = true;
        }
    }
    fn flush_seen_mailbox(&self) {
        let snapshot = {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.seen_mailbox_dirty {
                return;
            }
            st.seen_mailbox_dirty = false;
            st.seen_mailbox.iter().cloned().collect::<Vec<_>>().join("\n")
        };
        let _ = std::fs::write(self.paths.root.join("mailbox-seen.txt"), snapshot);
    }

    /// Is `reference` confirmed present on `dest` (relay node hex, or "s3")? See DynState docs.
    fn media_backed_up_has(&self, dest: &str, reference: &str) -> bool {
        self.dyn_state.lock().unwrap().media_backed_up.contains(&format!("{dest}|{reference}"))
    }
    fn mark_media_backed_up(&self, dest: &str, reference: &str) {
        let mut st = self.dyn_state.lock().unwrap();
        if st.media_backed_up.insert(format!("{dest}|{reference}")) {
            st.media_backed_up_dirty = true;
        }
    }
    fn flush_media_backed_up(&self) {
        let snapshot = {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.media_backed_up_dirty {
                return;
            }
            st.media_backed_up_dirty = false;
            st.media_backed_up.iter().cloned().collect::<Vec<_>>().join("\n")
        };
        let _ = std::fs::write(self.paths.root.join("media-backed-up.txt"), snapshot);
    }
    /// Forget a destination's media confirmations (relay forgotten/erased) so we re-mirror to it
    /// if it ever comes back. iOS `MediaBackupLedger.forgetDest` parity.
    fn forget_media_backed_up(&self, dest: &str) {
        let mut st = self.dyn_state.lock().unwrap();
        let before = st.media_backed_up.len();
        let prefix = format!("{dest}|");
        st.media_backed_up.retain(|k| !k.starts_with(&prefix));
        if st.media_backed_up.len() != before {
            st.media_backed_up_dirty = true;
        }
    }

    /// Build (and cache) the BYO S3 mailbox client from prefs + the keychain secret, if configured.
    async fn s3_client(self: &Arc<Self>) -> Option<Arc<S3Mailbox>> {
        if let Some(c) = self.s3.lock().await.as_ref() {
            return Some(c.clone());
        }
        let pub_cfg = self.prefs.lock().unwrap().s3.clone()?;
        let secret = store::load_s3_secret()?;
        let cfg = S3Config {
            endpoint: pub_cfg.endpoint,
            region: pub_cfg.region,
            bucket: pub_cfg.bucket,
            access_key: pub_cfg.access_key,
            secret_key: secret,
            prefix: pub_cfg.prefix,
        };
        let client = Arc::new(S3Mailbox::new(cfg).ok()?);
        *self.s3.lock().await = Some(client.clone());
        Some(client)
    }

    async fn upload_event(self: &Arc<Self>, circle_id: &str, env: &[u8]) {
        let key = Self::mailbox_key(circle_id, env);
        // Skip anything already confirmed in a mailbox: event envelopes re-seal deterministically
        // now, so a backfill reproduces the same content-addressed key and the persisted seen-set
        // turns the whole re-upload into a no-op instead of a network sweep.
        if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
            return;
        }
        let mut landed = false;
        // 1) Mirror to EVERY configured Haven relay (redundancy). Content-addressed keys make
        //    re-puts idempotent, and a relay in backoff is skipped — graceful fallback.
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        for node_hex in self.relays_for(circle_id) {
            // Our OWN hosted relay: store directly into the local mailbox (no iroh self-dial).
            if hosted.as_deref() == Some(node_hex.as_str()) {
                if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                    h.local_put(key.clone(), env.to_vec());
                    self.dyn_state.lock().unwrap().relay_active = true;
                    landed = true;
                }
                continue;
            }
            if let Some(client) = self.relay_client_for(&node_hex).await {
                match client.put(key.clone(), env.to_vec()).await {
                    Ok(()) => {
                        self.mark_relay_ok(&node_hex);
                        self.dyn_state.lock().unwrap().relay_active = true;
                        landed = true;
                    }
                    Err(e) => {
                        log::debug!("mailbox put failed ({node_hex}): {e}");
                        self.relay_failed(&node_hex).await;
                    }
                }
            }
        }
        // 2) BYO S3 bucket — an additional, independent mailbox (also idempotent).
        if let Some(s3) = self.s3_client().await {
            if s3.put(&key, env).await.is_ok() {
                self.dyn_state.lock().unwrap().relay_active = true;
                landed = true;
            }
        }
        if landed {
            self.mark_mailbox_seen(key);
        }
    }

    async fn backfill_mailbox(self: &Arc<Self>, circle_id: &str) {
        let has_relay = !self.relays_for(circle_id).is_empty();
        let has_s3 = self.prefs.lock().unwrap().s3.is_some();
        if !has_relay && !has_s3 {
            return;
        }
        let envs = self.social.export_my_envelopes(circle_id.to_string());
        for env in &envs {
            self.upload_event(circle_id, env).await;
        }
        // TOUCH the same refs on every relay so mailbox GC keeps them (upload_event is
        // seen-set-skipped once an envelope landed ONCE — without this, nothing would ever
        // refresh a live entry and the relay's 30-day TTL would eat real history). Misses
        // are re-PUT inside, so the refresh also repairs a relay that lost our entries.
        self.refresh_mailbox(circle_id, &envs).await;
        self.flush_seen_mailbox();
        let feed = self.social.feed(circle_id.to_string(), now_ms(), None);
        for item in feed {
            if item.is_me {
                for r in item.media {
                    if self.media.has(&r) {
                        self.upload_media(circle_id, &r).await;
                    }
                }
            }
        }
    }

    /// Refresh the liveness of `envs` (my deterministically re-sealed envelopes) on every iroh
    /// relay serving `circle_id` — ONE batched TOUCH per relay bumps their mailbox-GC clocks;
    /// the relay replies with the keys it does NOT hold and those are re-PUT (refresh doubles
    /// as repair). Deliberately ignores the seen-set: "seen" means uploaded once, and this
    /// exists precisely to re-assert entries that already exist. Our own hosted relay is
    /// touched locally (no iroh self-dial); S3 mailboxes have no GC.
    async fn refresh_mailbox(self: &Arc<Self>, circle_id: &str, envs: &[Vec<u8>]) {
        if envs.is_empty() {
            return;
        }
        let by_key: HashMap<String, &Vec<u8>> =
            envs.iter().map(|e| (Self::mailbox_key(circle_id, e), e)).collect();
        let keys: Vec<String> = by_key.keys().cloned().collect();
        let prefix = format!("haven/mailbox/{circle_id}/");
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        for node_hex in self.relays_for(circle_id) {
            if hosted.as_deref() == Some(node_hex.as_str()) {
                let misses = match self.relay_host.lock().unwrap().as_ref() {
                    Some(h) => h.local_touch(keys.clone()),
                    None => continue,
                };
                if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                    for k in misses {
                        if let Some(env) = by_key.get(&k) {
                            h.local_put(k, env.to_vec());
                        }
                    }
                }
                continue;
            }
            let Some(client) = self.relay_client_for(&node_hex).await else { continue };
            match client.touch(prefix.clone(), keys.clone()).await {
                Ok(misses) => {
                    self.mark_relay_ok(&node_hex);
                    for k in misses {
                        if let Some(env) = by_key.get(&k) {
                            let _ = client.put(k, env.to_vec()).await;
                        }
                    }
                }
                // Unreachable, or a pre-GC relay without TOUCH — it isn't sweeping, skip safely.
                Err(e) => log::debug!("mailbox touch failed ({node_hex}): {e}"),
            }
        }
    }

    pub async fn poll_mailbox(self: &Arc<Self>) {
        let mut changed = false;
        // Circles whose engine state changed this pass — notified ONCE each, after ingest,
        // through notify_circle's freshness + dedupe guards. Notifying per changed ENVELOPE
        // (the old shape) fired for key commits and epoch-rotation re-seals of old history
        // too, so the same "new message" banner repeated forever on a churning circle.
        let mut changed_circles: std::collections::BTreeSet<String> = Default::default();
        // (circle_id, relay_node_hex) for every circle × every configured relay — reading from
        // all of them means a message present on any reachable relay still arrives.
        let relay_targets: Vec<(String, String)> = {
            let prefs = self.prefs.lock().unwrap();
            prefs
                .relays
                .iter()
                .flat_map(|(cid, list)| list.iter().map(move |hex| (cid.clone(), hex.clone())))
                .collect()
        };
        for (circle_id, node_hex) in relay_targets {
            let Some(client) = self.relay_client_for(&node_hex).await else { continue };
            let prefix = format!("haven/mailbox/{circle_id}/");
            let keys = client.list(prefix).await;
            self.mark_relay_ok(&node_hex);
            if !keys.is_empty() {
                self.dyn_state.lock().unwrap().relay_active = true;
            }
            for key in keys {
                // seen_mailbox is keyed by the content-addressed key, so the same envelope
                // mirrored on several relays is ingested exactly once.
                if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
                    continue;
                }
                let Some(env) = client.get(key.clone()).await else { continue };
                self.mark_mailbox_seen(key);
                if self.social.receive(circle_id.clone(), env).unwrap_or(false) {
                    changed = true;
                    changed_circles.insert(circle_id.clone());
                }
            }
        }
        // BYO S3 bucket mailbox (the same circle-sealed envelopes, in the user's own bucket).
        if let Some(s3) = self.s3_client().await {
            for c in self.social.circles() {
                let keys = s3.list(&format!("haven/mailbox/{}", c.id)).await.unwrap_or_default();
                if !keys.is_empty() {
                    self.dyn_state.lock().unwrap().relay_active = true;
                }
                for key in keys {
                    if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
                        continue;
                    }
                    let env = match s3.get(&key).await {
                        Ok(Some(e)) => e,
                        _ => continue,
                    };
                    self.mark_mailbox_seen(key);
                    if self.social.receive(c.id.clone(), env).unwrap_or(false) {
                        changed = true;
                        changed_circles.insert(c.id.clone());
                    }
                }
            }
        }
        for cid in changed_circles {
            self.notify_circle(&cid);
        }
        self.flush_seen_mailbox();
        if changed {
            self.bump_activity(); // a message arrived → keep sync tight while the conversation is live
            self.persist();
            self.emit_changed();
            self.request_missing_media();
        }
    }

    /// Notify about a circle whose state just changed — but only when its newest INBOUND item
    /// is genuinely fresh (< 10 min) and hasn't been notified before (persisted dedupe). The
    /// change signal alone also fires for key commits, backfilled history, and epoch-rotation
    /// re-seals of old events; none of those deserve a banner.
    fn notify_circle(&self, circle_id: &str) {
        let feed = self.social.feed(circle_id.to_string(), now_ms(), None);
        let Some(newest) = feed.iter().filter(|i| !i.is_me).max_by_key(|i| i.created_at) else { return };
        if now_ms().saturating_sub(newest.created_at) > 10 * 60 * 1000 {
            return;
        }
        let key = format!("{circle_id}:{}", newest.id);
        {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.notified.insert(key) {
                return;
            }
            // Cheap cap — the recency guard is what really stops ancient items re-notifying.
            if st.notified.len() > 2000 {
                st.notified.clear();
            }
            st.notified_dirty = true;
        }
        self.flush_notified();
        let is_dm = circle_id.starts_with("dm:");
        self.notify(
            if is_dm { "New message" } else { "New in your circle" },
            if is_dm { "You have a new Haven message" } else { "Someone posted in your circle" },
        );
    }

    fn flush_notified(&self) {
        let snapshot = {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.notified_dirty {
                return;
            }
            st.notified_dirty = false;
            st.notified.iter().cloned().collect::<Vec<_>>().join("\n")
        };
        let _ = std::fs::write(self.paths.root.join("notified.txt"), snapshot);
    }

    /// Configure (and verify) a BYO S3/R2/B2 bucket. Stores the secret in the keychain, the rest
    /// in prefs, caches the client, and back-fills + polls. Errors if the bucket can't be reached.
    pub async fn s3_configure(self: &Arc<Self>, pub_cfg: store::S3Public, secret_key: String) -> Result<()> {
        let cfg = S3Config {
            endpoint: pub_cfg.endpoint.clone(),
            region: pub_cfg.region.clone(),
            bucket: pub_cfg.bucket.clone(),
            access_key: pub_cfg.access_key.clone(),
            secret_key: secret_key.clone(),
            prefix: pub_cfg.prefix.clone(),
        };
        let client = S3Mailbox::new(cfg)?;
        // Connectivity / auth check.
        client.list("haven/mailbox").await.map_err(|e| anyhow::anyhow!("bucket unreachable: {e}"))?;
        store::save_s3_secret(&secret_key)?;
        {
            let mut p = self.prefs.lock().unwrap();
            p.s3 = Some(pub_cfg);
            p.save(&self.paths)?;
        }
        *self.s3.lock().await = Some(Arc::new(client));
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            for c in me.social.circles() {
                me.backfill_mailbox(&c.id).await;
            }
            me.poll_mailbox().await;
        });
        Ok(())
    }

    pub async fn s3_clear(self: &Arc<Self>) {
        {
            let mut p = self.prefs.lock().unwrap();
            p.s3 = None;
            let _ = p.save(&self.paths);
        }
        store::delete_s3_secret();
        *self.s3.lock().await = None;
        self.emit_changed();
    }

    pub fn s3_status(&self) -> Option<store::S3Public> {
        self.prefs.lock().unwrap().s3.clone()
    }

    // ---- cross-device media bytes (frame 3 request / frame 5 sealed chunks) -------------

    fn media_key(reference: &str) -> String {
        format!("haven/media/{reference}")
    }
    // Chunks live in a SIBLING dir "<ref>.p/", not nested under the manifest key "haven/media/<ref>":
    // a disk relay maps each key segment to a directory, so "<ref>/<i>" would force "<ref>" to be both a
    // manifest FILE and a chunk DIRECTORY (a collision that fails the manifest write). "<ref>.p" is distinct.
    fn media_chunk_key(reference: &str, i: usize) -> String {
        format!("haven/media/{reference}.p/{i}")
    }

    // ---- Chunked media transfer (large-blob fix) -----------------------------------------------
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB (core/haven-net). Large sealed videos (600 MB+)
    // stored as ONE blob under "haven/media/<ref>" exceed that → a GET truncates and the receiver can't
    // play them. Fix: slice the SEALED bytes into 8 MB chunks under "haven/media/<ref>/<i>" and store a
    // tiny manifest under "haven/media/<ref>". Download fetches chunks IN ORDER and appends to a temp file
    // on disk (streaming — never the whole blob in RAM). Small media (<= one chunk) stays a single sealed
    // blob (no manifest) for back-compat. BYTE-IDENTICAL to iOS/macOS + Android (same 8 MB size, key
    // scheme, and manifest bytes: a 9-byte magic then JSON).
    fn make_manifest(sizes: &[usize]) -> Vec<u8> {
        let total: usize = sizes.iter().sum();
        let json = serde_json::json!({ "v": 1, "chunks": sizes.len(), "total": total, "sizes": sizes });
        let mut out = MEDIA_MANIFEST_MAGIC.to_vec();
        out.extend_from_slice(&serde_json::to_vec(&json).unwrap_or_else(|_| b"{}".to_vec()));
        out
    }
    /// If `blob` is a chunk manifest, return its chunk count; else None (legacy/small single blob).
    fn parse_manifest(blob: &[u8]) -> Option<usize> {
        if blob.len() <= MEDIA_MANIFEST_MAGIC.len() || &blob[..MEDIA_MANIFEST_MAGIC.len()] != MEDIA_MANIFEST_MAGIC {
            return None;
        }
        let body = &blob[MEDIA_MANIFEST_MAGIC.len()..];
        let obj: serde_json::Value = serde_json::from_slice(body).ok()?;
        let n = obj.get("chunks")?.as_u64()? as usize;
        if n > 0 { Some(n) } else { None }
    }

    /// A symmetric key derived from the ACCOUNT seed — every one of the user's own devices derives the
    /// identical key, so own-device media chunks sealed with it always open on a sibling. KEM-sealing to
    /// your own account doesn't decap reliably (the engine's per-device identity makes it fail), which is
    /// why media between a user's own devices never decrypted. HKDF-SHA256(ikm=seed, salt="haven-own-
    /// media-v1", info="", len=32) — byte-identical to the iOS CryptoKit derivation, so a chunk sealed on
    /// the PC opens on the iPhone and vice-versa.
    fn own_media_key(&self) -> [u8; 32] {
        // Primary/legacy: IKM = account seed (every own device derives the identical key). Seedless: no
        // account seed, so IKM = the granted self-sync key (also account-derived + shared by all the
        // account's devices via the grant). NB: a seedless device's own-media key won't match a
        // seed-holding sibling's — cross-open of THIS legacy own-media path degrades on seedless; the
        // seed-drop C7 device-bundle sealing is the real cross-device media path there. (S4 follow-on.)
        let ikm: Vec<u8> = match &self.seed {
            Some(seed) => seed.to_vec(),
            None => self.self_sync_key().map(|k| k.to_vec()).unwrap_or_default(),
        };
        let hk = hkdf::Hkdf::<Sha256>::new(Some(b"haven-own-media-v1"), &ikm);
        let mut okm = [0u8; 32];
        hk.expand(&[], &mut okm).expect("32 is a valid HKDF length");
        okm
    }

    pub fn request_missing_media(self: &Arc<Self>) {
        let my_hex = self.node_id_hex();
        let mut missing: Vec<(String, String)> = vec![]; // (ref, circleId)
        for c in self.social.circles() {
            let feed = self.social.feed(c.id.clone(), now_ms(), None);
            for item in feed {
                // Skip synthetic refs (geo: location pins): they carry no fetchable bytes, so a sweep
                // would fire a doomed S3-404 + ~30s iroh dial for them every cycle and never converge.
                // Skip refs the user DELIBERATELY evicted (#3 cleanup screen / #4 limit sweep): auto-
                // refetching them would silently undo the space the user just freed — they re-download
                // only on an explicit "Download" tap (media_download clears the eviction first).
                for r in item.media {
                    if !LocalMedia::is_synthetic(&r) && !self.media.has(&r) && !self.evicted_contains(&r) && !missing.iter().any(|(rr, _)| rr == &r) {
                        missing.push((r, c.id.clone()));
                    }
                }
                for cm in item.comments {
                    for r in cm.media {
                        if !LocalMedia::is_synthetic(&r) && !self.media.has(&r) && !self.evicted_contains(&r) && !missing.iter().any(|(rr, _)| rr == &r) {
                            missing.push((r, c.id.clone()));
                        }
                    }
                }
            }
        }
        // THROTTLE the direct (peer) fallback. A missing ref used to be re-requested from EVERY contact
        // on every 15s sweep, so a backlog of missing media flooded the network with hundreds of thousands
        // of frames per cycle, drowning real delivery (the iOS "nothing communicates" flood). Direct-request
        // each ref at most once per 5 min, and only a handful per cycle — the relay/mailbox restore below is
        // the real, idempotent path and runs unthrottled.
        let now = now_ms();
        let mut direct_budget = 8;
        {
            let mut st = self.dyn_state.lock().unwrap();
            if st.media_req_at.len() > 4000 {
                st.media_req_at.clear(); // bound the throttle map
            }
        }
        for (reference, circle_id) in missing {
            // Decide direct-eligibility up front (cooldown + per-cycle budget) so the spawned task only
            // peer-blasts when the gate allows; the relay restore always runs.
            let direct_ok = {
                let mut st = self.dyn_state.lock().unwrap();
                let stale = st.media_req_at.get(&reference).map(|&t| now - t > 300_000).unwrap_or(true);
                if stale && direct_budget > 0 {
                    st.media_req_at.insert(reference.clone(), now);
                    direct_budget -= 1;
                    true
                } else {
                    false
                }
            };
            let me = self.clone();
            let my_hex = my_hex.clone();
            tauri::async_runtime::spawn(async move {
                // ALWAYS try the circle's mailbox (relay/S3) first — content-addressed + idempotent, no flood.
                if me.fetch_media_healing(&circle_id, &reference).await {
                    me.emit_changed();
                    return;
                }
                // Relay couldn't serve it → re-request from peers, but only when the throttle allowed it
                // (capped at 8/cycle with a 5-min per-ref cooldown). An interrupted peer transfer still
                // completes over successive sweeps; chunk re-sends just fill the gaps.
                if !direct_ok {
                    return;
                }
                me.dyn_state.lock().unwrap().requested_refs.insert(reference.clone());
                let mut payload = my_hex.into_bytes();
                payload.extend_from_slice(reference.as_bytes());
                // NOTE: we deliberately do NOT add our own account node id as a request target here. iroh
                // publishes this device's endpoint under the shared account id, so dialing it is a self-dial,
                // which sends iroh's QUIC path-discovery into an unbounded loop (the multi-GB leak the
                // RelayClient guard already prevents). Own-device media converges via the relay backfill
                // (each device mirrors its own media to the relays a sibling reads) — the reliable path.
                let ids: Vec<String> = me.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
                for id_hex in ids {
                    me.send_frame(wire::MEDIA_REQ, &payload, &id_hex);
                }
            });
        }
    }

    // ---- Relay plain-HTTP media interface (client side) -----------------------------------------
    // GET/PUT against a relay's HTTP interface (core httprelay.rs): `<base>/k/<key>` with the relay's
    // bearer token (learned from the sealed frame-19 announce). This is the DEFAULT cross-NAT media
    // transport; a URL that doesn't answer is backed off 2 minutes so a dead LAN address doesn't cost
    // a connect-timeout per chunk. Keys are already URL-path-safe (haven/media/… ascii), so no encoding.

    fn http_url_bad(&self, base: &str) -> bool {
        self.http_url_bad.lock().unwrap().get(base).map(|&t| t > now_ms()).unwrap_or(false)
    }
    fn mark_http_url_bad(&self, base: &str) {
        self.http_url_bad.lock().unwrap().insert(base.to_string(), now_ms() + 120_000);
    }
    fn http_key_url(base: &str, key: &str) -> String {
        format!("{}/k/{}", base.trim_end_matches('/'), key)
    }
    /// Sign ONE request to a relay's plain-HTTP media interface.
    ///
    /// The relay no longer accepts a shared bearer token: it verifies a signature over this
    /// device's transport key to learn WHO is asking, then runs the same circle-membership check
    /// the iroh path runs (core httprelay.rs). The frame-19 token is folded into the signed
    /// transcript rather than sent, so it never crosses the wire.
    ///
    /// The seed MUST be the same one `HavenNode::start` binds the transport to (the roster's
    /// per-device seed), or the relay sees a node id that is in no roster and answers 403.
    ///
    /// NEVER cache the returned header: it carries a timestamp, a one-shot nonce and a digest of
    /// THIS body, so reusing one is a replay and the relay refuses it.
    fn http_auth(&self, token: &str, method: &str, key: &str, body: &[u8]) -> Option<String> {
        let seed: [u8; 32] = self.roster.lock().unwrap().device_seed.clone().try_into().ok()?;
        let secret = haven_p2p::identity::Identity::from_seed(&seed).node_secret_bytes();
        Some(haven_net::httprelay::auth_header(&secret, token, method, key, body))
    }
    /// GET one key. `Ok(Some)` = bytes, `Ok(None)` = reachable but 404 (a real MISS — the iroh path
    /// serves the same store, so skip dialing it), `Err(Unreachable)` = dead endpoint,
    /// `Err(Forbidden)` = the relay REFUSED us.
    async fn http_get(&self, base: &str, token: &str, key: &str) -> Result<Option<Vec<u8>>, RelayErr> {
        let auth = self.http_auth(token, "GET", key, b"").ok_or(RelayErr::Unreachable)?;
        let resp = self
            .http
            .get(Self::http_key_url(base, key))
            .header("authorization", auth)
            .send()
            .await
            .map_err(|_| RelayErr::Unreachable)?;
        match resp.status().as_u16() {
            200..=299 => Ok(Some(resp.bytes().await.map_err(|_| RelayErr::Unreachable)?.to_vec())),
            404 => Ok(None),
            401 | 403 => Err(RelayErr::Forbidden),
            _ => Err(RelayErr::Unreachable),
        }
    }

    // ---- relay refusal self-heal (mirrors iOS SharedStore.noteRefused / healForbiddenRelays) ------

    /// Relays that have refused us since our roster last reached them. A refusal is NOT a dead
    /// endpoint — it means the relay has never been told this DEVICE id belongs to our account, so
    /// `blob_forbidden` denies us before it ever considers the key. (Audit F4 extended that gate to
    /// `haven/media/`, which is why media a few days old became unreachable while fresh media — whose
    /// author was usually still online to answer peer-to-peer — looked fine.) Publishing the
    /// account-signed roster is precisely the remedy, so record the refusal and fix the CAUSE rather
    /// than backing off from a relay that is working perfectly.
    fn note_refused(&self, node_hex: &str, what: &str) {
        self.roster_needed.lock().unwrap().insert(node_hex.to_string());
        log::info!(
            "relay {} REFUSED {what} — not an outage; our device id isn't authorized there yet",
            &node_hex.chars().take(8).collect::<String>()
        );
    }

    /// Re-publish our device roster to every relay that refused us, so the next attempt is allowed.
    /// True if anything was published (i.e. a retry is worth making). Rate-limited to 30s: a relay
    /// that refuses us for some OTHER reason must not turn every media miss into a publish storm.
    async fn heal_forbidden_relays(self: &Arc<Self>) -> bool {
        let nodes: Vec<String> = {
            let mut needed = self.roster_needed.lock().unwrap();
            let mut last = self.last_heal_ms.lock().unwrap();
            if needed.is_empty() || now_ms().saturating_sub(*last) < 30_000 {
                return false;
            }
            *last = now_ms();
            needed.drain().collect()
        };
        log::info!(
            "re-publishing device roster after refusal from [{}]",
            nodes.iter().map(|n| n.chars().take(8).collect::<String>()).collect::<Vec<_>>().join(",")
        );
        // force: a refusal means the relay does NOT have a usable roster from us, so the "already
        // holds these bytes" skip must not suppress the very publish that fixes it.
        self.publish_device_roster_inner(true).await;
        true
    }
    async fn http_put(&self, base: &str, token: &str, key: &str, body: Vec<u8>) -> bool {
        // Digest over the EXACT bytes sent — `.body(body)` puts this buffer on the wire verbatim.
        let Some(auth) = self.http_auth(token, "PUT", key, &body) else { return false };
        self.http
            .put(Self::http_key_url(base, key))
            .header("authorization", auth)
            .header("content-type", "application/octet-stream")
            .body(body)
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    async fn upload_media(self: &Arc<Self>, circle_id: &str, reference: &str) {
        self.upload_media_inner(circle_id, reference, false).await;
    }

    /// `force` = the 1.0.8 media-recovery path: skip every "already held?" probe and the persisted
    /// ledger, and OVERWRITE the blob on every reachable destination. A blob is content-addressed +
    /// write-once, so a 1.0.7 build that device-signed it froze it forever; the only cure is to
    /// re-seal (now account-signed, done by the core fix) and overwrite the stored copy.
    ///
    /// Returns whether some destination now holds the blob (a probe hit, or — under `force` — accepted
    /// the freshly re-sealed overwrite). The recovery migration uses this to know a ref is repaired.
    async fn upload_media_inner(self: &Arc<Self>, circle_id: &str, reference: &str, force: bool) -> bool {
        let key = Self::media_key(reference);
        let mut landed = false; // a destination holds it (probe hit) or accepted it (upload)

        // ---- Probe phase: NO blob read. The media key is content-addressed (independent of the
        // sealed bytes), so every unconfirmed destination can be asked "do you already hold it?"
        // BEFORE the sealed file is loaded into RAM — a large video used to be re-read from disk
        // AND re-uploaded on every 2-min backfill pass. Probe hits go into the persisted ledger;
        // only a destination that is REACHABLE and MISSING the blob justifies the read below, and
        // a relay that is unreachable or in its backoff window waits for a later pass.
        // `force` bypasses the probe entirely — every reachable dest is an upload (overwrite).
        let mut s3_needs = false;
        if let Some(s3) = self.s3_client().await {
            if force {
                s3_needs = true;
            } else if !self.media_backed_up_has("s3", reference) {
                match s3.get(&key).await {
                    Ok(Some(_)) => { self.mark_media_backed_up("s3", reference); landed = true; }
                    Ok(None) => s3_needs = true,
                    Err(_) => {} // bucket unreachable — don't read the blob on its behalf
                }
            } else {
                landed = true; // ledger already confirms it here
            }
        }
        let mut http_uploads: Vec<(String, String, String)> = vec![]; // (node, base url, token)
        let mut dial_uploads: Vec<(String, Arc<RelayClient>)> = vec![];
        for node_hex in self.media_dests(circle_id) {
            if node_hex.starts_with("s3:") { continue; }
            if !force && self.media_backed_up_has(&node_hex, reference) { landed = true; continue; }
            // Relay HTTP interface — a reachable relay is authoritative (the iroh path serves the
            // SAME store): hit → ledger, 404 → upload over HTTP; only unreachable falls to the dial.
            // Bind out of the lock FIRST so the MutexGuard is dropped before any `.await` below.
            let http_iface = self.prefs.lock().unwrap().relay_http(&node_hex);
            if let Some((urls, token)) = http_iface {
                if force {
                    // Overwrite over the first good HTTP base without asking whether it's held.
                    if let Some(base) = urls.iter().find(|u| !self.http_url_bad(u)) {
                        http_uploads.push((node_hex.clone(), base.clone(), token.clone()));
                        continue;
                    }
                } else {
                    let mut resolved = false;
                    for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                        match self.http_get(base, &token, &key).await {
                            Ok(Some(_)) => {
                                self.mark_relay_ok(&node_hex);
                                self.mark_media_backed_up(&node_hex, reference);
                                landed = true;
                                resolved = true;
                            }
                            Ok(None) => {
                                http_uploads.push((node_hex.clone(), base.clone(), token.clone()));
                                resolved = true;
                            }
                            // Reachable and healthy — it just doesn't know us. Backing off here would
                            // strand our media on a relay that would happily store it once authorized.
                            Err(RelayErr::Forbidden) => self.note_refused(&node_hex, "media probe"),
                            Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                        }
                        if resolved { break; }
                    }
                    if resolved { continue; }
                }
            }
            // iroh fallback — relay_client_for honors the backoff window (None = skip, no read).
            if let Some(client) = self.relay_client_for(&node_hex).await {
                if force {
                    dial_uploads.push((node_hex.clone(), client));
                } else if client.has(key.clone()).await {
                    self.mark_relay_ok(&node_hex);
                    self.mark_media_backed_up(&node_hex, reference);
                    landed = true;
                } else {
                    dial_uploads.push((node_hex.clone(), client));
                }
            }
        }
        if !s3_needs && http_uploads.is_empty() && dial_uploads.is_empty() {
            self.flush_media_backed_up();
            return landed;
        }

        // ---- Read the sealed blob, now known to be needed by at least one reachable destination.
        let Some(blob) = self.media.raw_sealed(reference) else { return landed };
        let chunked = blob.len() > MEDIA_CHUNK_BYTES;
        // S3/HTTP bucket FIRST — the DEFAULT media transport. Plain HTTPS traverses any NAT, whereas
        // the iroh blob ALPN (haven/blob/1) drops its outbound datagrams over a pure-relay cross-NAT
        // path (noq/iroh fork bug): blob transfers that must cross a NAT stall and die even while
        // messaging works over the same relay path.
        if s3_needs {
            if let Some(s3) = self.s3_client().await {
                let ok = if chunked {
                    let mut sizes = Vec::new();
                    let mut all = true;
                    for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                        if s3.put(&Self::media_chunk_key(reference, i), slice).await.is_err() { all = false; break; }
                        sizes.push(slice.len());
                    }
                    all && s3.put(&key, &Self::make_manifest(&sizes)).await.is_ok()
                } else {
                    s3.put(&key, &blob).await.is_ok()
                };
                if ok { self.mark_media_backed_up("s3", reference); landed = true; }
            }
        }
        // Then mirror to every relay that probed reachable-and-missing. Large blobs are sliced into
        // 8 MB chunks under "<key>.p/<i>" with a manifest at <key> so a GET never exceeds MAX_BLOB.
        // An HTTP interface that dies mid-upload falls back to the iroh dial (same store).
        for (node_hex, base, token) in http_uploads {
            let ok = if chunked {
                let mut sizes = Vec::new();
                let mut all = true;
                for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                    if !self.http_put(&base, &token, &Self::media_chunk_key(reference, i), slice.to_vec()).await {
                        all = false;
                        break;
                    }
                    sizes.push(slice.len());
                }
                all && self.http_put(&base, &token, &key, Self::make_manifest(&sizes)).await
            } else {
                self.http_put(&base, &token, &key, blob.clone()).await
            };
            if ok {
                self.mark_relay_ok(&node_hex);
                self.mark_media_backed_up(&node_hex, reference);
                landed = true;
            } else {
                self.mark_http_url_bad(&base);
                if let Some(client) = self.relay_client_for(&node_hex).await {
                    dial_uploads.push((node_hex, client));
                }
            }
        }
        for (node_hex, client) in dial_uploads {
            let res: Result<(), ()> = async {
                if chunked {
                    let mut sizes = Vec::new();
                    for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                        client.put(Self::media_chunk_key(reference, i), slice.to_vec()).await.map_err(|_| ())?;
                        sizes.push(slice.len());
                    }
                    client.put(key.clone(), Self::make_manifest(&sizes)).await.map_err(|_| ())
                } else {
                    client.put(key.clone(), blob.clone()).await.map_err(|_| ())
                }
            }
            .await;
            match res {
                Ok(()) => {
                    self.mark_relay_ok(&node_hex);
                    self.mark_media_backed_up(&node_hex, reference);
                    landed = true;
                }
                Err(()) => self.relay_failed(&node_hex).await,
            }
        }
        self.flush_media_backed_up();
        landed
    }

    async fn fetch_media_from_relay(self: &Arc<Self>, circle_id: &str, reference: &str) -> bool {
        let key = Self::media_key(reference);
        // S3/HTTP bucket FIRST — the DEFAULT media transport (see upload_media): an iroh blob dial
        // that must cross a NAT stalls ~30s and dies, so the bucket is tried before any dial.
        if let Some(s3) = self.s3_client().await {
            if let Ok(Some(head)) = s3.get(&key).await {
                if let Some(count) = Self::parse_manifest(&head) {
                    let part = self.media.new_sealed_part(reference);
                    let mut ok = true;
                    for i in 0..count {
                        match s3.get(&Self::media_chunk_key(reference, i)).await {
                            Ok(Some(chunk)) if self.media.append_sealed_part(&part, &chunk) => {}
                            _ => { ok = false; break; }
                        }
                    }
                    if ok && self.media.adopt_sealed_part(reference, &part) {
                        return true;
                    }
                    let _ = std::fs::remove_file(&part);
                } else {
                    self.media.write_raw_sealed(reference, &head);
                    return true;
                }
            }
        }
        // Then each relay in turn — the circle's own PLUS every other known relay (media is
        // permission-free, so a blob can be served by any reachable relay). Per relay, its plain-HTTP
        // interface is tried FIRST (the reliable cross-NAT path); the iroh blob dial is the fallback.
        for node_hex in self.media_dests(circle_id) {
            if node_hex.starts_with("s3:") { continue; }
            // Relay HTTP interface — the DEFAULT cross-NAT path. Bind out of the lock FIRST so the
            // MutexGuard is dropped before any `.await` below (a guard held across await isn't Send).
            let http_iface = self.prefs.lock().unwrap().relay_http(&node_hex);
            if let Some((urls, token)) = http_iface {
                let mut http_miss = false;
                for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                    match self.http_get(base, &token, &key).await {
                        // NOT a miss and NOT an outage: never mark the URL bad (the relay is healthy)
                        // and never set http_miss, or the iroh fallback below is skipped too and a
                        // refusal is laundered into "nobody has it".
                        Err(RelayErr::Forbidden) => {
                            self.note_refused(&node_hex, &format!("media fetch {}", &reference.chars().take(10).collect::<String>()));
                            continue;
                        }
                        Err(RelayErr::Unreachable) => { self.mark_http_url_bad(base); continue; }
                        Ok(None) => { http_miss = true; break; } // reachable, doesn't hold it
                        Ok(Some(head)) => {
                            if let Some(count) = Self::parse_manifest(&head) {
                                let part = self.media.new_sealed_part(reference);
                                let mut ok = true;
                                for i in 0..count {
                                    match self.http_get(base, &token, &Self::media_chunk_key(reference, i)).await {
                                        Ok(Some(chunk)) if self.media.append_sealed_part(&part, &chunk) => {}
                                        _ => { ok = false; break; }
                                    }
                                }
                                if ok && self.media.adopt_sealed_part(reference, &part) {
                                    self.mark_relay_ok(&node_hex);
                                    return true;
                                }
                                let _ = std::fs::remove_file(&part);
                            } else {
                                self.mark_relay_ok(&node_hex);
                                self.media.write_raw_sealed(reference, &head);
                                return true;
                            }
                            http_miss = true; // served the manifest but reassembly failed — don't dial
                            break;
                        }
                    }
                }
                // Reachable HTTP relay that answered 404 (or a completed HTTP attempt): the iroh path
                // serves the SAME store, so skip the ~30s doomed dial for this relay.
                if http_miss { continue; }
            }
            if let Some(client) = self.relay_client_for(&node_hex).await {
                if let Some(head) = client.get(key.clone()).await {
                    if let Some(count) = Self::parse_manifest(&head) {
                        // Stream each chunk to a temp file on disk — never the whole blob in RAM.
                        let part = self.media.new_sealed_part(reference);
                        let mut ok = true;
                        for i in 0..count {
                            match client.get(Self::media_chunk_key(reference, i)).await {
                                Some(chunk) if self.media.append_sealed_part(&part, &chunk) => {}
                                _ => { ok = false; break; }
                            }
                        }
                        if ok && self.media.adopt_sealed_part(reference, &part) {
                            self.mark_relay_ok(&node_hex);
                            return true;
                        }
                        let _ = std::fs::remove_file(&part);
                        continue;
                    }
                    self.mark_relay_ok(&node_hex);
                    self.media.write_raw_sealed(reference, &head);
                    return true;
                }
            }
        }
        // Say WHICH it was. Reporting a permissions failure as absence is what made this read as data
        // loss for days — the blob was on the relay the whole time and the device simply wasn't
        // allowed to ask for it.
        let refused = self.roster_needed.lock().unwrap().len();
        let short = reference.chars().take(12).collect::<String>();
        if refused == 0 {
            log::info!("media restore {short}: NOT FOUND on any relay/S3");
        } else {
            log::info!("media restore {short}: REFUSED by {refused} relay(s) — not missing; re-publishing our roster so the retry is allowed");
        }
        false
    }

    /// Fetch a blob, and if every relay REFUSED us rather than lacking it, publish our device roster
    /// to the refusers and try once more. Without this the fetch degrades to a peer ask that only
    /// works while the author happens to be online — which is exactly how media a few days old became
    /// permanently unreachable while fresh media (author still around) looked fine.
    async fn fetch_media_healing(self: &Arc<Self>, circle_id: &str, reference: &str) -> bool {
        if self.fetch_media_from_relay(circle_id, reference).await {
            return true;
        }
        self.heal_forbidden_relays().await && self.fetch_media_from_relay(circle_id, reference).await
    }

    async fn handle_media_request(self: &Arc<Self>, body: &[u8]) {
        if body.len() <= 64 {
            return;
        }
        let requester = String::from_utf8_lossy(&body[..64]).into_owned();
        if requester.len() != 64 {
            return;
        }
        let reference = String::from_utf8_lossy(&body[64..]).into_owned();
        if reference.is_empty() || !self.media.has(&reference) {
            return;
        }
        let Some(bytes) = self.media.load_any_circle(&self.social, &reference) else { return };
        self.send_media_chunks(&reference, &bytes, &requester).await;
    }

    async fn send_media_chunks(self: &Arc<Self>, reference: &str, bytes: &[u8], requester_hex: &str) {
        let total = ((bytes.len() + MEDIA_CHUNK_SIZE - 1) / MEDIA_CHUNK_SIZE).max(1) as u32;
        let ref_bytes = reference.as_bytes();
        // Own-device (the requester is MY OWN account) → seal each chunk with the symmetric account-key, which
        // a sibling can always open (KEM-to-self decap is unreliable). A friend requester → per-recipient KEM
        // seal as before. The receiver tries the symmetric open first, then falls back to the engine's KEM.
        let own = requester_hex == self.node_id_hex();
        let own_key = if own { Some(self.own_media_key()) } else { None };
        let mut index = 0u32;
        let mut offset = 0;
        while offset < bytes.len() {
            let end = (offset + MEDIA_CHUNK_SIZE).min(bytes.len());
            let chunk = &bytes[offset..end];
            let sealed = if let Some(key) = own_key.as_ref() {
                haven_p2p::crypto::seal(key, chunk)
            } else {
                match self.social.seal_media(requester_hex.to_string(), chunk.to_vec()) {
                    Ok(s) => s,
                    Err(_) => return,
                }
            };
            self.send_frame(wire::MEDIA_CHUNK, &wire::chunk_frame(ref_bytes, index, total, &sealed), requester_hex);
            offset = end;
            index += 1;
        }
    }

    fn handle_media_chunk(self: &Arc<Self>, body: &[u8]) {
        if body.len() < 2 {
            return;
        }
        let ref_len = (body[0] as usize) | ((body[1] as usize) << 8);
        if body.len() < 2 + ref_len + 8 {
            return;
        }
        let reference = String::from_utf8_lossy(&body[2..2 + ref_len]).into_owned();
        let mut off = 2 + ref_len;
        let index = u32::from_le_bytes([body[off], body[off + 1], body[off + 2], body[off + 3]]);
        off += 4;
        let total = u32::from_le_bytes([body[off], body[off + 1], body[off + 2], body[off + 3]]);
        off += 4;
        let sealed = &body[off..];
        if reference.is_empty() || total == 0 || self.media.has(&reference) {
            return;
        }
        // Own-device chunks are symmetric (account-key) sealed; friend chunks are KEM. Try the cheap
        // symmetric open first, then fall back to the engine's KEM open.
        let plain = haven_p2p::crypto::open(&self.own_media_key(), sealed)
            .ok()
            .or_else(|| self.social.open_media(sealed.to_vec()));
        let Some(plain) = plain else { return };
        let mut complete: Option<Vec<u8>> = None;
        {
            let mut st = self.dyn_state.lock().unwrap();
            let entry = st.incoming_media.entry(reference.clone()).or_insert(IncomingMedia { total, chunks: HashMap::new() });
            entry.chunks.insert(index, plain);
            if entry.chunks.len() as u32 >= entry.total {
                // Sanity cap: store_under_ref seals the whole media in memory (~2-3x its size). Skip
                // anything absurdly large (corrupt total, or media bigger than we should hold at once)
                // rather than risk an allocation blow-up. (Android, a low-heap phone, caps tighter.)
                let total_size: usize = entry.chunks.values().map(|c| c.len()).sum();
                const MAX_MEDIA: usize = 1024 * 1024 * 1024; // 1 GB
                if total_size > 0 && total_size <= MAX_MEDIA {
                    let mut full = Vec::with_capacity(total_size);
                    for i in 0..entry.total {
                        if let Some(c) = entry.chunks.get(&i) {
                            full.extend_from_slice(c);
                        }
                    }
                    complete = Some(full);
                }
                st.incoming_media.remove(&reference);
            }
        }
        if let Some(full) = complete {
            self.media.store_under_ref(&self.social, DEFAULT_CIRCLE, &reference, &full);
            self.emit_changed();
        }
    }

    // ---- local media (attach + display) -------------------------------------------------

    pub fn add_local_media(&self, circle_id: &str, bytes: &[u8], is_video: bool) -> String {
        self.media.store(&self.social, circle_id, bytes, is_video)
    }

    /// Stage a media FILE already on disk (drag-drop / file picker) sealed to the circle, via the core's
    /// off-heap file→file seal so a large video never doubles peak RAM as a plaintext + sealed `Vec` pair
    /// in this process. Returns the media ref, or `None` on an IO error. Mirrors iOS' file-based backup.
    pub fn add_local_media_file(&self, circle_id: &str, path: &str, is_video: bool) -> Option<String> {
        let kind = if is_video {
            crate::localmedia::MediaKind::Video
        } else {
            crate::localmedia::MediaKind::Image
        };
        self.media
            .store_file(&self.social, circle_id, std::path::Path::new(path), kind)
            .ok()
    }

    pub fn add_local_audio(&self, circle_id: &str, bytes: &[u8]) -> String {
        self.media.store_kind(&self.social, circle_id, bytes, crate::localmedia::MediaKind::Audio)
    }

    /// Decrypt a stored media ref for display, trying the given circle then any circle.
    pub fn media_bytes(&self, circle_id: &str, reference: &str) -> Option<Vec<u8>> {
        self.media
            .load(&self.social, circle_id, reference)
            .or_else(|| self.media.load_any_circle(&self.social, reference))
    }

    // ---- calls (signaling only; WebRTC media lives in the WebView) ----------------------

    /// Parse an inbound call frame and forward it to the UI's WebRTC mesh via `haven:call`.
    ///
    /// The frame is sealed + signed to us (audit R1). Open + verify BEFORE anything else: drop any
    /// frame we can't decrypt or whose Ed25519 signature doesn't verify against the carried sender
    /// bundle for this recipient + frame type (a relay-forged, relay-rewritten, or replayed-as-
    /// another-type frame all fail here), and drop one whose PROVEN sender doesn't match the
    /// self-declared `from` prefix the parsers key on. This runs identically for direct and
    /// frame-9-relayed frames — authentication is the signature, not a transport id.
    fn handle_call(self: &Arc<Self>, t: u8, sealed: &[u8]) {
        let Some(app) = self.app.lock().unwrap().clone() else { return };
        let Some(opened) = self.social.open_call_frame(t, sealed.to_vec()) else { return };
        let verified = opened.sender_hex.to_lowercase();
        let body = &opened.data;
        if verified.len() != 64 || body.len() < 64 {
            return;
        }
        let declared = String::from_utf8_lossy(&body[..64]).to_lowercase();
        if declared != verified {
            // D9: a SEEDLESS sender signs call frames with its DEVICE key, so the proven signer is the
            // device id while the body's `from` is the account id. Accept when the verified device
            // resolves (via the verified roster) to the declared account — otherwise it's a forgery.
            match self.social.account_for_device(verified.clone()) {
                Some(acct) if acct.eq_ignore_ascii_case(&declared) => {}
                _ => return, // proven sender must equal, or speak for, the self-declared `from`
            }
        }
        // Block by ACCOUNT id (`declared`), which for a device-signed frame is the account behind the
        // device, not the transient device hex.
        if self.prefs.lock().unwrap().blocked.contains(&declared) {
            return;
        }
        let body = body.as_slice();
        let ev = match t {
            wire::CALL_INVITE => callwire::parse_invite_name(body).map(|(from, name)| {
                serde_json::json!({ "kind": "invite", "from": from, "name": name, "sessionId": format!("legacy:{from}"), "roster": [from] })
            }),
            wire::GROUP_INVITE => callwire::parse_group_invite(body).and_then(|g| {
                // Optional 4th field (newer senders): the invite's send time. A copy older than
                // the caller's entire dialing window (180s, generous for clock skew) is a replay —
                // a relay hop or reconnect delivering it long after the caller gave up. It must
                // not reach the UI (ring or resurrect a session's roster).
                if let Some(ts) = g.sent_at {
                    let age = (now_ms() / 1000).saturating_sub(ts);
                    if age > 180 {
                        log::info!("dropping stale call invite (age={age}s session={})", &g.session_id.chars().take(12).collect::<String>());
                        return None;
                    }
                }
                Some(serde_json::json!({ "kind": "groupInvite", "from": g.from, "sessionId": g.session_id, "groupName": g.group_name, "roster": g.roster }))
            }),
            wire::CALL_ACCEPT => callwire::parse_accept(body).map(|a| {
                serde_json::json!({ "kind": "accept", "from": a.from, "sessionId": a.session_id })
            }),
            wire::CALL_HANGUP => callwire::parse_hangup(body).map(|from| {
                serde_json::json!({ "kind": "hangup", "from": from })
            }),
            wire::CALL_HANDLED => callwire::parse_accept(body).map(|a| {
                serde_json::json!({ "kind": "handledElsewhere", "from": a.from, "sessionId": a.session_id })
            }),
            wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE => callwire::parse_signal(body, "").map(|s| {
                let kind = match t { wire::SDP_OFFER => "offer", wire::SDP_ANSWER => "answer", _ => "ice" };
                serde_json::json!({ "kind": kind, "from": s.from, "sessionId": s.session_id, "json": String::from_utf8_lossy(&s.json) })
            }),
            _ => None,
        };
        if let Some(ev) = ev {
            // Only a known contact's call frames reach the UI — a stranger can't ring, inject, or
            // negotiate a call (audit F3, iOS/Android parity). These frames are unsealed, so the
            // self-asserted `from` is gated against the contact list here.
            let from = ev.get("from").and_then(|v| v.as_str()).unwrap_or("");
            // Frame 30 comes from MY OWN account, which is never in my contact list — gate it on that
            // instead. Narrow on purpose: only my own account may silence my ring, and the signature
            // verified above is what proves it. (The UI then refuses to act on one for a call it has
            // already answered, so a late copy can never hang up a live conversation.)
            if t == wire::CALL_HANDLED {
                if !from.eq_ignore_ascii_case(&self.social.my_node_hex()) {
                    return;
                }
            } else if !self.is_contact(from) {
                return;
            }
            let _ = app.emit("haven:call", ev);
        }
    }

    /// Whether `hex` is a known contact — gates unsealed call control frames.
    fn is_contact(&self, hex: &str) -> bool {
        self.prefs.lock().unwrap().contacts.iter().any(|c| c.id_hex == hex)
    }

    /// Send a call-signaling frame direct AND live-forwarded through the circle relays (frame 9 —
    /// the relay host unwraps and sends the inner frame onward over its own connections). Cross-NAT
    /// fallback: a callee whose direct dial back to the caller fails still lands the ACCEPT within
    /// the ring window. (The invite push rings the callee, but the answer path was direct-only.)
    fn send_call_frame(self: &Arc<Self>, t: u8, frame_body: &[u8], to_hex: &str) {
        // Seal + sign the frame to the recipient before it leaves the device (audit R1): the body is
        // encrypted (a relay on the frame-9 path can't read candidate IPs or rewrite the DTLS-SRTP
        // fingerprint) and signed (the recipient proves the sender). No plaintext fallback — if
        // sealing fails we send NOTHING, so a relay can't force a downgrade to the spoofable form.
        // `seal_media` can only seal to a recipient it can RESOLVE to a bundle: our own account, a
        // circle member, or a known device bundle. If none match this drops the frame silently —
        // nothing transmitted, nothing recorded. For an ACCEPT that is indistinguishable from the
        // network eating it: the callee has already flipped itself in-call, so it looks connected while
        // the caller waits out the full invite timer. Say so.
        let sealed = match self.social.seal_call_frame(to_hex.to_string(), t, frame_body.to_vec()) {
            Ok(s) if !s.is_empty() => s,
            other => {
                let known = self.social.device_node_ids_for(to_hex.to_string()).len();
                log::info!(
                    "call frame type={t} NOT SENT to {} — seal failed (recipient unresolvable: {known} known device id(s), {})",
                    &to_hex.chars().take(8).collect::<String>(),
                    if other.is_err() { "threw" } else { "empty" }
                );
                return;
            }
        };
        self.send_frame(t, &sealed, to_hex);
        let mut dests = self.social.device_node_ids_for(to_hex.to_string());
        if dests.is_empty() {
            dests.push(to_hex.to_string());
        }
        for h in self.device_hints_for(to_hex) {
            if !dests.iter().any(|d| d.eq_ignore_ascii_case(&h)) {
                dests.push(h);
            }
        }
        self.originate_relay_internet(&dests, &wire::frame(t, &sealed));
    }

    /// Originate a frame-9 live forward of `inner` to `dests` via up to 3 adopted internet relays.
    /// Wire format parity with iOS emitRelay: [16B msgId][1B ttl][1B destCount][32B×dest][inner].
    fn originate_relay_internet(self: &Arc<Self>, dests: &[String], inner: &[u8]) {
        let dest_bytes: Vec<Vec<u8>> = dests.iter().filter_map(|h| hex_to_bytes32(h)).collect();
        if dest_bytes.is_empty() {
            return;
        }
        let mut msg_id = [0u8; 16];
        {
            use rand::RngCore;
            rand::rngs::OsRng.fill_bytes(&mut msg_id);
        }
        self.seen_relay.lock().unwrap().insert(bytes_to_hex(&msg_id)); // don't reprocess our own
        let mut p = Vec::with_capacity(18 + dest_bytes.len() * 32 + inner.len());
        p.extend_from_slice(&msg_id);
        p.push(3); // ttl
        p.push(dest_bytes.len().min(255) as u8);
        for d in dest_bytes.iter().take(255) {
            p.extend_from_slice(d);
        }
        p.extend_from_slice(inner);
        let my_acct = self.social.my_node_hex().to_lowercase();
        let my_dev = self.social.my_device_node_hex().to_lowercase();
        let relays: Vec<String> = self.prefs.lock().unwrap().relays.values().flatten().cloned().collect();
        let mut used = std::collections::HashSet::new();
        let mut sent = 0;
        for r in relays {
            let h = r.to_lowercase();
            if h.starts_with("s3:") || h == my_acct || h == my_dev || !used.insert(h) {
                continue;
            }
            self.send_frame(wire::RELAY, &p, &r);
            sent += 1;
            if sent >= 3 {
                break;
            }
        }
    }

    /// Frame-9 mesh relay: process the inner frame if we're a destination, and forward it onward to
    /// the other destinations over our own connections (we may be the relay host the sender hopped
    /// through). Dedup by msgId (loop protection, parity with iOS handleRelay).
    fn handle_relay(self: &Arc<Self>, body: &[u8]) {
        if body.len() < 18 {
            return;
        }
        {
            let mut seen = self.seen_relay.lock().unwrap();
            if !seen.insert(bytes_to_hex(&body[..16])) {
                return;
            }
            if seen.len() > 2000 {
                seen.clear();
            }
        }
        let ttl = body[16];
        let dest_count = body[17] as usize;
        let mut off = 18;
        if body.len() < off + dest_count * 32 {
            return;
        }
        let mut dests = Vec::with_capacity(dest_count);
        for _ in 0..dest_count {
            dests.push(bytes_to_hex(&body[off..off + 32]));
            off += 32;
        }
        let inner = &body[off..];
        if inner.is_empty() {
            return;
        }
        let me_acct = self.social.my_node_hex().to_lowercase();
        let me_dev = self.social.my_device_node_hex().to_lowercase();
        let for_me = dests.iter().any(|d| {
            let l = d.to_lowercase();
            l == me_acct || l == me_dev
        });
        if for_me {
            self.dispatch(inner.to_vec());
        }
        if ttl == 0 {
            return;
        }
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        for dest in dests {
            let l = dest.to_lowercase();
            if l == me_acct || l == me_dev {
                continue;
            }
            let node = node.clone();
            let inner = inner.to_vec();
            tauri::async_runtime::spawn(async move {
                let _ = node.send_to_node(dest, inner).await;
            });
        }
    }

    pub fn call_group_invite(self: &Arc<Self>, session_id: String, group_name: String, roster: Vec<String>, to: Vec<String>) {
        let me = self.node_id_hex();
        let frame = callwire::group_invite(&me, &session_id, &group_name, &roster.join(","), now_ms() / 1000);
        for t in to {
            self.send_call_frame(wire::GROUP_INVITE, &frame, &t);
        }
    }

    pub fn call_accept(self: &Arc<Self>, session_id: String, to: Vec<String>) {
        let frame = callwire::accept(&self.node_id_hex(), &session_id);
        for t in to {
            self.send_call_frame(wire::CALL_ACCEPT, &frame, &t);
        }
    }

    /// Tell my OTHER devices this ringing call was handled here (answered or declined), so they stop
    /// ringing and never join.
    ///
    /// Every device of mine rings — that part is right. Nothing told the losers to stand down, so the
    /// one I didn't answer on kept its session live, completed signalling when the offer arrived, and
    /// joined the mesh: "I answered on my phone and my PC took the audio", then the reverse when I
    /// touched the PC. Two devices in one call also explains one of them sounding choppy — they were
    /// competing, not degraded.
    ///
    /// Sealed PER DEVICE rather than to my account, so a seedless device (which holds no account key)
    /// can open it too. Mirrors iOS `CallManager.notifyOwnDevicesHandled`.
    pub fn call_handled_elsewhere(self: &Arc<Self>, session_id: String) {
        if session_id.is_empty() {
            return;
        }
        let others = self.my_other_device_hexes();
        if others.is_empty() {
            return; // no roster yet = no way to address them; that is the honest answer
        }
        log::info!(
            "call {} handled here — standing down {} other device(s) of mine",
            &session_id.chars().take(8).collect::<String>(),
            others.len()
        );
        let frame = callwire::handled_elsewhere(&self.social.my_node_hex(), &session_id);
        for dev in others {
            self.send_call_frame(wire::CALL_HANDLED, &frame, &dev);
        }
    }

    /// My OWN other devices' node ids (excluding this one and my account id, which under per-device
    /// transport seeds resolves to no endpoint).
    fn my_other_device_hexes(&self) -> Vec<String> {
        let account = self.social.my_node_hex().to_lowercase();
        let mine = self.social.my_device_node_hex().to_lowercase();
        self.social
            .device_node_ids_for(account.clone())
            .into_iter()
            .map(|d| d.to_lowercase())
            .filter(|d| *d != mine && *d != account)
            .collect()
    }

    pub fn call_hangup(self: &Arc<Self>, to: Vec<String>) {
        let frame = callwire::hangup(&self.node_id_hex());
        for t in to {
            self.send_call_frame(wire::CALL_HANGUP, &frame, &t);
        }
    }

    pub fn call_signal(self: &Arc<Self>, kind: String, session_id: String, json: String, to: String) {
        let t = match kind.as_str() {
            "offer" => wire::SDP_OFFER,
            "answer" => wire::SDP_ANSWER,
            _ => wire::ICE,
        };
        let frame = callwire::signal(&self.node_id_hex(), &session_id, json.as_bytes());
        self.send_call_frame(t, &frame, &to);
    }

    // ---- persistence --------------------------------------------------------------------

    fn persist(&self) {
        if let Err(e) = store::write_state(&self.paths, &self.social.export_state()) {
            log::error!("persist failed: {e}");
        }
    }

    // ---- demo/screenshot seeding (debug builds only — see demo.rs) ----------------------
    //
    // The seeder drives this engine offline, which the public API can't express: authoring needs a
    // backdated `created_at` and a friend's sync bundle needs a raw `receive`, while every public
    // wrapper (`post`, `set_profile`, …) also talks to the wire. These hand out the internals it
    // needs; they compile out of release entirely, along with their only caller.

    #[cfg(debug_assertions)]
    pub(crate) fn demo_social(&self) -> &Arc<HavenSocial> {
        &self.social
    }

    #[cfg(debug_assertions)]
    pub(crate) fn demo_persist(&self) {
        self.persist();
    }

    /// Mutate + save prefs directly, skipping the networked broadcast `set_profile` does.
    #[cfg(debug_assertions)]
    pub(crate) fn demo_with_prefs(&self, f: impl FnOnce(&mut Prefs)) {
        let mut p = self.prefs.lock().unwrap();
        f(&mut p);
        if let Err(e) = p.save(&self.paths) {
            log::error!("demo prefs save failed: {e}");
        }
    }

    /// Report the node as started without one: demo mode never binds it, and the status dot reads
    /// `dyn_state`, so the UI would otherwise sit on "starting…" through every screenshot.
    #[cfg(debug_assertions)]
    pub(crate) fn demo_mark_started(&self) {
        self.dyn_state.lock().unwrap().started = true;
        self.emit_changed();
    }

    // ---- multi-device self-sync (D16, Phase 3 — port of iOS SelfSync.swift) -------------

    /// §6 — resolve the account-state self-sync crypto parameters for THIS device this pass:
    /// `(accepted, seed_key, seal_epoch)`.
    /// * `accepted` — the rotated `(epoch → key)` map we currently honor (empty on the v0 path). A v1
    ///   blob at any other epoch (a revoked device's stale write) is refused.
    /// * `seed_key` — the v0 seed-derived key to accept legacy blobs during the transition window, or
    ///   `None` once fully retired (which refuses legacy blobs and completes the revocation cut).
    /// * `seal_epoch` — `Some((epoch, key))` to seal our own slot v1, or `None` for the v0 seal.
    ///
    /// Primary: derives the v0 key from the seed; loads the rotated state; drops the seed key once
    /// `account_leaf_retired()` (the fully-capable proxy). Seedless: uses its granted key — the
    /// v0-equivalent grant (epoch 0) opens legacy blobs, a rotated grant (epoch > 0) means it's in the
    /// fully-retired regime and only its epoch is honored.
    fn self_sync_crypto(
        &self,
    ) -> (
        std::collections::BTreeMap<u64, [u8; 32]>,
        Option<[u8; 32]>,
        Option<(u64, [u8; 32])>,
    ) {
        use std::collections::BTreeMap;
        match &self.seed {
            Some(seed) => {
                let v0 = haven_p2p::identity::Identity::from_seed(seed).self_sync_key();
                let rot = crate::selfsyncrot::SelfSyncRotation::load(&self.paths);
                match rot.key32() {
                    Some(key) if rot.rotated() => {
                        // Rotation only ever fires when fully device-capable, so this is normally true;
                        // keep the seed key during the brief transition window, then drop it.
                        let seed_key = if self.social.account_leaf_retired() { None } else { Some(v0) };
                        (rot.accepted(), seed_key, Some((rot.epoch, key)))
                    }
                    _ => (BTreeMap::new(), Some(v0), None),
                }
            }
            None => {
                let s = self.seedless.lock().unwrap();
                let epoch = s.self_sync_epoch;
                match s.self_sync_key32() {
                    Some(key) if epoch > 0 => {
                        let mut accepted = BTreeMap::new();
                        accepted.insert(epoch, key);
                        (accepted, None, Some((epoch, key)))
                    }
                    Some(key) => (BTreeMap::new(), Some(key), None), // v0-equivalent grant
                    None => (BTreeMap::new(), None, None),           // not yet granted
                }
            }
        }
    }

    /// §6 (seedless survivor) — read the keygrant mailbox and adopt a NEWER rotated key/epoch the
    /// primary sealed to this device after a revocation. Verifies the account signature + that the
    /// grant was sealed to our device bundle; persists the higher epoch's key (guarded like a seed).
    async fn adopt_rotated_self_sync_grant(self: &Arc<Self>) {
        let device_seed = self.roster.lock().unwrap().device_seed.clone();
        let account_bundle = self.account_bundle();
        let cur_epoch = self.seedless.lock().unwrap().self_sync_epoch;
        let account_hex = wire::node_hex(&account_bundle);
        if account_hex.len() != 64 {
            return;
        }
        let transports = self.gather_self_sync_transports().await;
        if transports.is_empty() {
            return;
        }
        let prefix = format!("haven/{}", haven_p2p::selfsync::grant_slot_prefix(&account_hex));
        let mut best: Option<(u64, Vec<u8>)> = None;
        for t in &transports {
            for key in self.self_sync_list(t, &prefix).await {
                let Some(env) = self.self_sync_fetch(t, &key).await else { continue };
                if let Ok(grant) = haven_ffi::multidevice::open_self_sync_key_epoch_grant(
                    device_seed.clone(),
                    account_bundle.clone(),
                    env,
                ) {
                    let newer = best.as_ref().map(|(e, _)| grant.epoch > *e).unwrap_or(true);
                    if grant.epoch > cur_epoch && grant.key.len() == 32 && newer {
                        best = Some((grant.epoch, grant.key));
                    }
                }
            }
        }
        if let Some((epoch, key)) = best {
            let mut s = self.seedless.lock().unwrap();
            s.self_sync_epoch = epoch;
            s.self_sync_key = key;
            let _ = s.save(&self.paths);
            log::info!("adopted rotated self-sync key at epoch {epoch} (§6 revocation rotation)");
        }
    }

    /// One full self-sync pass across the user's OWN devices: fold local changes into the base
    /// CRDT with fresh stamps, merge every peer slot from every transport, apply the converged
    /// result locally, persist, and re-publish our own sealed slot. Coalesces if already running.
    /// No-op without any transport (a relay OR the user's S3 bucket).
    pub async fn poll_self_sync(self: &Arc<Self>) {
        use haven_p2p::selfsync::{slot_key, slot_prefix, AccountState, Stamp};

        // Coalesce concurrent passes (the 15s loop must never overlap itself).
        {
            let mut st = self.dyn_state.lock().unwrap();
            if st.self_syncing {
                return;
            }
            st.self_syncing = true;
        }
        // Always clear the in-flight flag on the way out.
        struct Guard<'a>(&'a Engine);
        impl Drop for Guard<'_> {
            fn drop(&mut self) {
                self.0.dyn_state.lock().unwrap().self_syncing = false;
            }
        }
        let _guard = Guard(self);

        let account_hex = self.node_id_hex();
        if account_hex.is_empty() {
            return;
        }
        let transports = self.gather_self_sync_transports().await;
        if transports.is_empty() {
            return; // needs a relay OR an S3 bucket
        }

        // §6: a seedless survivor first checks the keygrant mailbox — if the primary rotated the key
        // on a revocation, adopt the new epoch/key before reading (else it opens nothing at the new
        // epoch and silently falls off the channel).
        if self.is_seedless() {
            self.adopt_rotated_self_sync_grant().await;
        }

        // §6 dual-key crypto: `accepted` = the rotated epoch→key map we honor (a stale-epoch write from
        // a revoked device is refused); `seed_key` = the v0 seed-derived key during the transition
        // window, dropped to `None` once fully retired (completing the cut); `seal_epoch` = seal under
        // the rotated key/epoch, or None for the v0 path. Byte-identical to 1.0.6 until the first
        // rotation. A seedless device with no grant yet can't self-sync.
        let (accepted, seed_key, seal_epoch) = self.self_sync_crypto();
        if accepted.is_empty() && seed_key.is_none() {
            return; // seedless, not yet granted a key
        }

        // 1. Base = last converged state (or empty).
        let mut base = match std::fs::read(self.paths.selfsync_state_file()) {
            Ok(bytes) => AccountState::from_bytes(&bytes).unwrap_or_default(),
            Err(_) => AccountState::default(),
        };

        // 2. Fold in whatever changed locally since last sync (stamp = now, this device). Only
        //    stamp a key when its value actually differs from base, so stamps advance on real
        //    change (otherwise two devices ping-pong).
        let now = now_ms();
        let device = crate::selfsync::device_id(&self.paths);
        let stamp = Stamp::new(now, device);
        // Collapse any superseded/upgraded circle into a synced LWW deletion tombstone BEFORE snapshotting
        // local state, so the tombstone rides THIS pass's slot (mirrors iOS refreshCircles before export).
        self.reconcile_superseded_circles();
        let local = {
            let prefs = self.prefs.lock().unwrap();
            crate::selfsync::current_local(&prefs, &self.social)
        };
        for (key, value) in &local {
            if base.get(key) != Some(value.as_slice()) {
                base.set(key, value.clone(), stamp);
            }
        }
        // Detect local removals in dynamic namespaces and tombstone them — BUT NOT when the engine
        // looks freshly-empty (no circles locally while the base still has circles). That signature is
        // a just-restored / unready device, and tombstoning there is exactly what wiped accounts; in
        // that state we only ADD, never remove.
        let local_has_circle = local.keys().any(|k| k.starts_with("circle:"));
        let base_has_circle = base.entries().any(|(k, _)| k.starts_with("circle:"));
        if local_has_circle || !base_has_circle {
            let present_keys: Vec<String> = base.entries().map(|(k, _)| k.to_string()).collect();
            for key in present_keys {
                if crate::selfsync::DYNAMIC_PREFIXES.iter().any(|p| key.starts_with(p))
                    && !local.contains_key(&key)
                {
                    base.remove(&key, stamp);
                }
            }
        }

        // Snapshot post-fold so we can tell whether the merge below actually brought anything new.
        let pre_merge = base.to_bytes();

        // 3. Pull + merge every peer slot from every relay/bucket.
        let prefix = format!("haven/{}", slot_prefix(&account_hex));
        let own_key = format!(
            "haven/{}",
            slot_key(&account_hex, &hex::encode(device))
        );
        for t in &transports {
            let keys = self.self_sync_list(t, &prefix).await;
            for key in keys {
                if key == own_key {
                    continue;
                }
                let Some(blob) = self.self_sync_fetch(t, &key).await else { continue };
                if let Ok(peer) = AccountState::open_any(&blob, seed_key.as_ref(), &accepted) {
                    base.merge(&peer);
                }
            }
        }

        let changed = base.to_bytes() != pre_merge;

        // 4. Apply the converged state locally + persist the new base.
        let entries: Vec<(String, Vec<u8>)> =
            base.entries().map(|(k, v)| (k.to_string(), v.to_vec())).collect();
        let applied = {
            let mut prefs = self.prefs.lock().unwrap();
            let applied = crate::selfsync::apply_local(&entries, &mut prefs, &self.social);
            if applied {
                let _ = prefs.save(&self.paths);
            }
            applied
        };
        if applied {
            self.persist();
            self.emit_changed();
        }
        let _ = std::fs::write(self.paths.selfsync_state_file(), base.to_bytes());

        // 5. Re-publish our own slot (sealed) to every relay/bucket for redundancy. Seal under the
        //    rotated key/epoch (v1) once rotated, else the v0 seed-derived key — byte-identical to today.
        let sealed = match seal_epoch {
            Some((epoch, key)) => base.seal_epoch(&key, epoch),
            None => base.seal(&seed_key.expect("v0 path always has a seed key")),
        };
        for t in &transports {
            self.self_sync_put(t, &own_key, &sealed).await;
        }

        let _ = changed; // change-detection is folded into `applied`; kept for parity with iOS.
    }

    /// Every place this device can read/write its self-sync slots: all distinct configured relays
    /// plus the user's OWN S3 bucket (so sync works with no relay at all — BYO storage is enough).
    async fn gather_self_sync_transports(self: &Arc<Self>) -> Vec<SelfSyncTransport> {
        let mut out: Vec<SelfSyncTransport> = vec![];
        let relays: std::collections::BTreeSet<String> = {
            let prefs = self.prefs.lock().unwrap();
            prefs
                .relays
                .values()
                .flatten()
                .filter(|h| prefs.relay_is_active(h) && !h.starts_with("s3:"))
                .cloned()
                .collect()
        };
        for node_hex in relays {
            out.push(SelfSyncTransport::Relay(node_hex));
        }
        if let Some(s3) = self.s3_client().await {
            out.push(SelfSyncTransport::S3(s3));
        }
        out
    }

    async fn self_sync_list(self: &Arc<Self>, t: &SelfSyncTransport, prefix: &str) -> Vec<String> {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                let Some(client) = self.relay_client_for(node_hex).await else { return vec![] };
                let keys = client.list(prefix.to_string()).await;
                self.mark_relay_ok(node_hex);
                keys
            }
            SelfSyncTransport::S3(c) => c.list(prefix).await.unwrap_or_default(),
        }
    }

    async fn self_sync_fetch(self: &Arc<Self>, t: &SelfSyncTransport, key: &str) -> Option<Vec<u8>> {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                let client = self.relay_client_for(node_hex).await?;
                client.get(key.to_string()).await
            }
            SelfSyncTransport::S3(c) => c.get(key).await.ok().flatten(),
        }
    }

    async fn self_sync_put(self: &Arc<Self>, t: &SelfSyncTransport, key: &str, data: &[u8]) {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                if let Some(client) = self.relay_client_for(node_hex).await {
                    match client.put(key.to_string(), data.to_vec()).await {
                        Ok(()) => self.mark_relay_ok(node_hex),
                        Err(_) => self.relay_failed(node_hex).await,
                    }
                }
            }
            SelfSyncTransport::S3(c) => {
                let _ = c.put(key, data).await;
            }
        }
    }

    pub fn reset(self: &Arc<Self>) {
        {
            let mut p = self.prefs.lock().unwrap();
            *p = Prefs::default();
            // Re-stamp the unread seed for the next identity (0 would badge all of history).
            p.dm_read_seeded_at = now_ms();
            let _ = p.save(&self.paths);
        }
        {
            let mut st = self.dyn_state.lock().unwrap();
            *st = DynState::default();
        }
        self.media.clear();
        store::remove_if_exists(&self.paths.state_file());
        // A new identity must not inherit the old ingestion cursor.
        store::remove_if_exists(&self.paths.root.join("mailbox-seen.txt"));
        // Clear the self-sync base too, so adopting a new identity doesn't diff an empty engine against
        // a stale base and tombstone the account (the data-loss bug).
        store::remove_if_exists(&self.paths.selfsync_state_file());
        {
            let mut r = self.roster.lock().unwrap();
            *r = crate::roster::DeviceRoster::load(&self.paths);
            r.step_down();
            let _ = r.save(&self.paths);
        }
        store::delete_s3_secret();
        let _ = store::delete_seed();
        self.emit_changed();
    }
}

/// Adapter so the Rust iroh node can deliver inbound bytes back into the engine without a
/// strong reference cycle (the engine owns the node).
struct NodeListener {
    engine: Weak<Engine>,
}

impl InboundListener for NodeListener {
    fn on_inbound(&self, from_hex: String, payload: Vec<u8>) {
        if let Some(engine) = self.engine.upgrade() {
            engine.dispatch_from(if from_hex.is_empty() { None } else { Some(from_hex) }, payload);
        }
    }
}

#[cfg(test)]
mod flag_tests {
    use crate::engine::flag_body;

    /// The moderation ledger row is signed (audit F1). Proven against a REAL worker rather than a
    /// mock, because the thing that broke was a contract mismatch a mock would have reproduced
    /// wrongly: desktop kept POSTing the old unsigned body and the worker's 401 went unnoticed
    /// behind fire-and-forget.
    ///
    /// Needs the worker running locally, so it's `#[ignore]` by default:
    ///     cd push && npx wrangler dev --port 8799 --local
    ///     cargo test --lib flag -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "needs `wrangler dev --port 8799` in push/"]
    async fn signed_report_is_accepted_and_unsigned_is_not() {
        let url = "http://127.0.0.1:8799/flag";
        let http = reqwest::Client::new();
        let seed = [7u8; 32];
        let subject = "a".repeat(64);
        let post = |body: String| {
            http.post(url).header("content-type", "application/json").body(body).send()
        };

        // BEFORE (the bug): the old unsigned body desktop shipped through beta.33.
        let old = serde_json::json!({
            "actor": "b".repeat(64), "subject": subject, "action": "report", "reason": "Spam or scam",
        });
        assert_eq!(post(old.to_string()).await.unwrap().status(), 401, "unsigned flag must be refused");

        // AFTER (the fix): the exact bytes moderation_report puts on the wire.
        let ts = crate::engine::now_ms() / 1000;
        let body = flag_body(&seed, &subject, "Spam or scam", ts).expect("signable");
        assert_eq!(post(body.to_string()).await.unwrap().status(), 200, "signed flag lands");

        // A flag can't be re-aimed: same signature, different victim.
        let mut stolen = body.clone();
        stolen["subject"] = serde_json::json!("c".repeat(64));
        assert_eq!(post(stolen.to_string()).await.unwrap().status(), 401, "signature binds the subject");

        // Block is unrepresentable server-side — belt to the braces of desktop never sending one.
        let mut blocked = body.clone();
        blocked["action"] = serde_json::json!("block");
        assert_eq!(post(blocked.to_string()).await.unwrap().status(), 400, "a block has no ledger row");
    }

    /// No subject / no signable identity → we send nothing at all, rather than a flag the worker
    /// would refuse anyway.
    #[test]
    fn unsignable_or_subjectless_reports_are_not_sent() {
        assert!(flag_body(&[7u8; 32], "", "Spam or scam", 1).is_none(), "no subject, no row");
        assert!(flag_body(&[7u8; 32], &"a".repeat(64), "x", 1).is_some());
    }
}

#[cfg(test)]
mod round_trip_tests {
    use crate::wire;
    use haven_ffi::HavenSocial;

    /// The frontend hands us `data:` URLs; peers expect bare base64. Getting this backwards ships
    /// an avatar that every Apple client silently drops (`Data(base64Encoded:)` returns nil).
    #[test]
    fn avatar_rides_the_card_as_bare_base64() {
        assert_eq!(crate::engine::raw_base64("data:image/jpeg;base64,AQID"), "AQID");
        assert_eq!(crate::engine::raw_base64("AQID"), "AQID", "already-bare base64 is untouched");
        assert_eq!(crate::engine::raw_base64(""), "", "no avatar stays empty");

        // ...and it survives the sign/verify round trip the Hello actually performs.
        let alice = HavenSocial::new([11u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([22u8; 32].to_vec()).unwrap();
        let signed = alice.my_signed_profile(
            "Alice".into(),
            String::new(),
            String::new(),
            crate::engine::raw_base64("data:image/jpeg;base64,AQID"),
            String::new(),
        );
        let hello = wire::hello_payload("default", "My Circle", &alice.my_bundle(), &signed);
        let parsed = wire::parse_hello(&wire::frame(wire::HELLO, &hello)[1..]).expect("hello parses");
        assert_eq!(
            bob.verify_profile(parsed.bundle, parsed.signed_profile).as_deref(),
            Some("Alice"),
            "the card still verifies with an avatar aboard"
        );
    }

    /// Two parties handshake and exchange a post + a sealed media chunk through the exact
    /// `wire` framing the engine moves over iroh — a stand-in for a real cross-device test
    /// (Windows ↔ iPhone ↔ Android) that doesn't need two machines or the network.
    #[test]
    fn two_parties_exchange_post_and_media_over_wire() {
        let alice = HavenSocial::new([11u8; 32].to_vec()).unwrap();
        let bob = HavenSocial::new([22u8; 32].to_vec()).unwrap();
        let cid = "default".to_string();

        // --- Hello handshake (frame 0) ---
        let hello = wire::hello_payload(
            &cid,
            "My Circle",
            &alice.my_bundle(),
            &alice.my_signed_profile("Alice".into(), String::new(), String::new(), String::new(), String::new()),
        );
        let frame = wire::frame(wire::HELLO, &hello);
        assert_eq!(frame[0], wire::HELLO);
        let parsed = wire::parse_hello(&frame[1..]).expect("hello parses");
        assert_eq!(
            bob.verify_profile(parsed.bundle.clone(), parsed.signed_profile.clone()).as_deref(),
            Some("Alice"),
            "bob reads alice's signed name"
        );
        bob.add_contact_bundle(cid.clone(), parsed.bundle).unwrap();
        alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();

        // --- Post (frame 1) ---
        let env = alice.post(cid.clone(), "hello from windows".into(), vec![], None, None, false, false, 1_000).unwrap();
        // The EVENT wire frame still round-trips through the codec.
        let ev_frame = wire::frame(wire::EVENT, &wire::event_payload(&cid, &env));
        let ev = wire::parse_event(&ev_frame[1..]).expect("event parses");
        assert_eq!(ev.circle_id, cid, "event frame carries the circle id");
        // Posts are sealed under Alice's epoch key (group-keying), so Bob must receive her key commit
        // before he can open them. Her sync bundle carries the commit + the event — deliver it the way
        // the live sync path does (mirrors the core net_tests `sync` helper).
        let mut got_new = false;
        for envelope in alice.sync_envelopes(cid.clone()) {
            if bob.receive(cid.clone(), envelope).unwrap() { got_new = true; }
        }
        assert!(got_new, "bob ingests new content on first sync");
        let feed = bob.feed(cid.clone(), 2_000, None);
        assert_eq!(feed.len(), 1);
        assert_eq!(feed[0].body, "hello from windows");
        assert!(!feed[0].is_me);

        // --- Sealed media chunk (frame 5) ---
        let blob = vec![9u8; 1000];
        let sealed = alice.seal_media(bob.my_node_hex(), blob.clone()).unwrap();
        let chunk = wire::chunk_frame(b"v:abc", 0, 1, &sealed);
        let ref_len = (chunk[0] as usize) | ((chunk[1] as usize) << 8);
        assert_eq!(String::from_utf8_lossy(&chunk[2..2 + ref_len]), "v:abc");
        let mut off = 2 + ref_len;
        let index = u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        off += 4;
        let total = u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        off += 4;
        assert_eq!((index, total), (0, 1));
        assert_eq!(bob.open_media(chunk[off..].to_vec()), Some(blob), "bob reassembles + decrypts the media");
    }
}
