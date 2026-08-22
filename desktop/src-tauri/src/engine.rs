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
    /// Half-finished chunked media transfers — which chunks of which ref are already on disk.
    /// PERSISTED to `media-reassembly.txt` (see `mediaresume`), so a 99%-complete transfer resumes
    /// where it stopped instead of restarting at chunk 0. This replaced an in-memory
    /// `HashMap<u32, Vec<u8>>` of chunk plaintexts that died with the process — the reason large
    /// media "never loaded": it wasn't failing once, it was restarting forever.
    reassembly: crate::mediaresume::ReassemblyIndex,
    /// Refs with a frame-33 resume ask outstanding, so a burst of re-requests can't spawn a fallback
    /// task each. Bounded by the reassembly index's own 512-record cap.
    resume_fallback: HashSet<String>,
    requested_refs: HashSet<String>,
    /// ref -> last direct (peer) media-request ms. THROTTLE: a missing ref must not be re-blasted to
    /// every contact on every sweep (that floods the network with hundreds of thousands of frames and
    /// buries real delivery — the iOS "nothing communicates" flood). The relay/mailbox restore is the
    /// real, idempotent path; direct peer re-requests are capped + cooled-down to fill gaps only.
    media_req_at: HashMap<String, u64>,
    /// last time we mirrored our OWN media to the circle relays (idempotent backfill, ~every 2 min).
    last_media_backfill_ms: u64,
    /// last own-device catch-up sweep, and whether one is still running. Throttled HARD (5 min) and
    /// single-flight: the sweep RE-SEALS every envelope it hands over, so it is real CPU per item
    /// and must never ride the sync tick or be allowed to overlap itself. See `sync_with_contacts`.
    last_own_device_catchup_ms: u64,
    own_device_catchup_in_flight: bool,
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
    /// Refs whose relay backup a DIRECT peer ask has already prompted us to re-check, and when.
    /// In-session only and throttled to once an hour per ref — see
    /// [`Engine::reverify_backup_after_direct_ask`].
    backup_reverified_at: HashMap<String, u64>,
    /// Refs whose stored copy on every relay was FOUND but could not be opened — the bytes are bad,
    /// not missing (see `accept_fetched_blob`). Deliberately in-session only: a restart, or an author
    /// who re-seals and overwrites the blob, both deserve another attempt. Its whole job is to stop
    /// the 20-second sweep re-downloading the same unopenable bytes forever.
    media_unopenable: HashSet<String>,
    /// How far a chunked upload of a ref got on ONE destination, and from WHICH sealed bytes:
    /// `"<dest>|<ref>"` -> `"<sha256 of the seal>:<windows written>"`. PERSISTED to
    /// `media-upload-progress.txt`.
    ///
    /// Per DESTINATION, not per ref, because progress is per destination — and the fingerprint travels
    /// with it because windows written from a DIFFERENT seal must never be counted. This is what makes
    /// a resumed chunked upload safe: see `mediaresume::trusted_prefix` for the silent corruption a
    /// bare "does the relay hold window i?" probe would cause. Persisted because the interruption
    /// resume exists for is the process being KILLED — an in-memory record would be empty exactly when
    /// the decision gets made.
    media_upload_progress: HashMap<String, String>,
    /// ref -> when we last re-uploaded it for a frame-31 ask, and the refs an upload is in flight
    /// for. Serving one full-blob upload per inbound frame with no bound is a bandwidth amplifier a
    /// circle member could aim at us; these bound it. In-memory on purpose — the cooldown is about
    /// the current session's bandwidth, and a restart re-serving once is fine.
    media_served_at: HashMap<String, u64>,
    /// Refs genuinely RE-SEALED since launch. The serve cache may only answer for these — a ref we
    /// never re-sealed has nothing to answer WITH, and claiming "it's back" about bytes we did not
    /// touch is what let a broken photo stay broken while both sides reported success.
    media_resealed_session: std::collections::HashSet<String>,
    /// Refs probed for readability at least once since launch — a second probe answers the same
    /// question at the same cost, so each ref is tested once and the library converges in minutes.
    media_probed_session: std::collections::HashSet<String>,
    media_serving: HashSet<String>,
    /// Last-seen LIST digest per `"<relay>|<circle>"` (delta-LIST, `X-Haven-List-Digest`):
    /// echoing it turns an unchanged mailbox LIST into a bodiless 204 — the idle radio saver.
    /// In-memory on purpose: a fresh process re-lists once and re-caches. Only committed once a
    /// listing's GET batch finished WITHOUT deferrals, or a 204 on the next poll would skip keys
    /// we listed but never fetched (iOS `mailboxListDigests` parity).
    mailbox_list_digests: HashMap<String, String>,
    /// mailbox key -> last time a control blob (0x03/0x04) there was fetched and found NOT yet
    /// applicable (ms). It stays UNSEEN so it can still apply later, but the loop head skips the
    /// GET until this ages out: a commit can be unauthorizable for a long time (126 attempts in
    /// one observed run) and re-fetching + re-verifying it every poll is pure tax.
    control_retry_at: HashMap<String, u64>,
    /// circle id -> last time we re-queued its mailbox after a key commit unlocked it (ms).
    /// DAMPER for the repair below: competing (account, epoch) commits are NORMAL, so an
    /// undamped re-queue would re-fetch and re-decrypt a circle's whole mailbox on every poll
    /// forever — the shape that once ran a relay-hosting Mac to 16.8 GB (iOS parity).
    seen_requeued_at: HashMap<String, u64>,
    /// FRESH-lane retry state for missing media of events < 5 min old: ref -> (round, next-due ms).
    /// 5s/10s/20s/45s/90s then parked — a just-posted photo must not wait out the 5-min direct
    /// throttle while its author is right there uploading it (iOS `fastReq` parity).
    fast_req: HashMap<String, (u8, u64)>,
    /// True while a fresh-lane re-sweep timer is armed (single-flight — the 5s re-arm must not stack).
    fast_sweep_armed: bool,
    /// Per-ref throttle for `thumb:` companion prefetches (plain 90s — tiny by contract, no lanes).
    thumb_req_at: HashMap<String, u64>,
    /// Per-ref throttle for acting on unsolicited frame-32 announces (the author push-ahead).
    announced_media_at: HashMap<String, u64>,
    /// Chunk serves currently streaming, keyed `ref|requester`.
    ///
    /// A serve is slow by construction, so the requester re-asks while it waits — and that second
    /// request happily started ANOTHER full serve of the same file. Three or four pile up, compete for
    /// the same link, and none finishes, so the media never arrives and the requester asks again,
    /// indefinitely. (iOS hit exactly this — one video re-requested 16 times in 20 minutes — and fixed
    /// it in c67226c.) During a transfer, doing NOTHING is the correct response: the bytes are already
    /// on their way, and if they stop, the resume request asks for the holes.
    chunk_serving: HashSet<String>,
    internet_active: bool,
    relay_active: bool,
    started: bool,
    hosting: bool,
    foreground: bool,
    /// Coalesces overlapping self-sync passes (the loop must never run two at once).
    self_syncing: bool,
    /// Debounced "self-sync now" nudge (0 = none armed). A LOCAL mutation of self-sync-carried
    /// state (profile edit, circle create/membership, DM pin, read watermark, synced setting) arms
    /// a short deadline via `nudge_self_sync`; the heartbeat honors it with ONE forced pass, so
    /// the edit reaches the user's other devices in seconds instead of waiting out the adaptive
    /// poll cadence (30s base, stretched to minutes when idle). Each further mutation slides the
    /// deadline (a burst coalesces into a single pass); no mutation, no extra pass — the periodic
    /// cadence itself is untouched (the heat fixes stand).
    selfsync_nudge_at_ms: u64,
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

impl SelfSyncTransport {
    /// Short PII-free label for pass logging ("relay:fe263256" / "s3").
    fn label(&self) -> String {
        match self {
            SelfSyncTransport::Relay(hex) => {
                format!("relay:{}", hex.chars().take(8).collect::<String>())
            }
            SelfSyncTransport::S3(_) => "s3".into(),
        }
    }
}

/// One row of the in-app activity list (the bell). Core rows come from `social.activity()` — who
/// reacted to / commented on / voted on MY events, plus others' posts and DMs; APP rows are the
/// deep-linked notifications this device raised ("media is back"), appended by `notify_with_link`.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct ActivityRow {
    pub id: String,
    /// `"react" | "comment" | "vote" | "post" | "story" | "dm" | "app"`.
    pub kind: String,
    pub circle_id: String,
    /// Display name for the row's actor (resolved here — the UI holds no contact table).
    pub actor_name: String,
    /// Body/preview line.
    pub snippet: String,
    pub created_at: u64,
    /// The reaction emoji (kind == "react").
    pub emoji: Option<String>,
    /// `haven://…` link the row jumps to (same route table as a pasted link).
    pub link: Option<String>,
}

/// Load the persisted app-layer activity rows (bounded — see `append_app_activity`).
fn load_app_activity(paths: &Paths) -> Vec<ActivityRow> {
    std::fs::read(paths.root.join("activity-app.json"))
        .ok()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default()
}

/// Load the persisted seen-mailbox set, with a ONE-SHOT repair (latched by a marker file): builds
/// before the control-plane routing fix marked `/__hello__/` keys seen while DROPPING their blobs,
/// and builds before the claim-filter fix marked hellos addressed to our DEVICE id (or to anyone
/// else) seen without ever routing them — either way a connection request stored-and-forwarded to
/// this account never surfaced. Forget hello keys once so the next poll re-routes what's ours;
/// foreign hellos are no longer marked seen at all (they're skipped pre-GET, unfetched).
/// (`/__relay__/` keys need no repair — the pre-fix build fed them to `receive()`, which refused
/// them, so they were never marked seen.) Latch v2: installs that latched v1 under the
/// account-only claim filter must forget once more.
fn load_seen_mailbox(paths: &Paths) -> HashSet<String> {
    let mut set: HashSet<String> = std::fs::read_to_string(paths.root.join("mailbox-seen.txt"))
        .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
        .unwrap_or_default();
    let latch = paths.root.join("seen-hello-repair-2.done");
    if !latch.exists() {
        let before = set.len();
        set.retain(|k| !k.contains("/__hello__/"));
        if set.len() != before {
            log::info!(
                "mailbox seen: one-shot repair forgot {} hello key(s) a pre-fix build marked-and-dropped",
                before - set.len()
            );
            let _ = std::fs::write(
                paths.root.join("mailbox-seen.txt"),
                set.iter().cloned().collect::<Vec<_>>().join("\n"),
            );
        }
        let _ = std::fs::write(&latch, b"1");
    }
    set
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

/// One post or comment OF MINE that carries media — everything an Edit needs to be written back
/// unchanged except for the media array. Mirrors Apple's `ReoptimizeTarget`.
#[derive(Clone)]
pub struct ReoptimizeTarget {
    pub circle_id: String,
    pub event_id: String,
    pub body: String,
    pub media: Vec<String>,
    pub music: Option<TrackRefFfi>,
    pub mute_video: bool,
    pub created_at: u64,
}

/// One still of mine whose stored bytes are above target.
pub struct ReoptimizeCandidate {
    pub reference: String,
    /// The circle this blob is sealed to — the re-encode is re-sealed to the same one.
    pub circle_id: String,
    /// PLAINTEXT length, which is what the new encode is compared against.
    pub bytes: u64,
    pub width: u32,
    pub height: u32,
    pub format: String,
    /// Why this is being offered ("4032px, target 1600px"), for the detail line.
    pub reason: String,
    /// Timestamp of the oldest post/comment of mine that names it.
    pub first_shared_ms: u64,
    /// Shared before the encoder rewrite landed — REPORTED, not used as a gate (see reoptimize.rs).
    pub legacy_by_age: bool,
}

/// The result of a scan: what this device can shrink, and what it deliberately won't touch.
pub struct ReoptimizeScan {
    pub candidates: Vec<ReoptimizeCandidate>,
    /// My own videos/voice notes that are above target but which THIS platform must not re-encode
    /// (WebM/VP8 out of a WebView would be unplayable on Apple). Surfaced so the user is told the
    /// truth rather than shown a clean bill of health.
    pub videos_above_target: usize,
    pub video_bytes: u64,
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

/// Result of applying front-door prefs when the relay HTTP interface starts.
enum DeskFrontDoor {
    Spawned(haven_net::cfquicktunnel::QuickTunnel),
    AnnounceOnly(String),
    LanOnly,
}

pub struct Engine {
    /// A coalesced state write is already scheduled — see `persist_coalesced`.
    persist_pending: std::sync::atomic::AtomicBool,
    /// QA-visible call state pushed from the webview: bit0 = ringing, bit1 = in_call. See
    /// `set_qa_call_state` for why this exists.
    qa_call: std::sync::atomic::AtomicU8,
    /// When the epoch-change re-seal last ran, so a burst of roster changes coalesces into one pass.
    last_epoch_reseal: std::sync::Mutex<u64>,
    /// The account master seed — `Some` on a primary/legacy device, `None` on a SEEDLESS device
    /// (seed-drop S4). Making it an `Option` turns every account-key use into a compile-checked
    /// decision, so a missed seedless guard is a build error, not a runtime forge/panic.
    seed: Option<[u8; 32]>,
    social: Arc<HavenSocial>,
    paths: Paths,
    media: LocalMedia,
    app: StdMutex<Option<AppHandle>>,
    node: StdMutex<Option<Arc<HavenNode>>>,
    /// Accounts we have asked the public directory about, and when (`resolve_missing_device_ids`).
    discovery_asked: StdMutex<HashMap<String, u64>>,
    /// Cursor last asked for per circle (lazy history) — scrolling past the end must not re-ask the
    /// same page. Session-scoped, like the rest of the sync bookkeeping.
    history_asked_before: StdMutex<HashMap<String, u64>>,
    relay_host: StdMutex<Option<Arc<RelayServerHandle>>>,
    /// Live cloudflared process (quick or named) for the **public front door** (media, or
    /// path-router when fabric is unified). Dropped when hosting stops. Manual never sets this.
    quick_tunnel: StdMutex<Option<haven_net::cfquicktunnel::QuickTunnel>>,
    /// Second free trycloudflare only when dual-origin DERP (sibling hostname / path-router off).
    derp_tunnel: StdMutex<Option<haven_net::cfquicktunnel::QuickTunnel>>,
    /// Embedded iroh-relay (DERP) — separate listen socket; drop stops the fabric role.
    derp_server: StdMutex<Option<haven_net::DerpServer>>,
    /// Local path router: one origin → media + DERP by path (`/relay` → fabric).
    path_router: StdMutex<Option<haven_net::PathRouter>>,
    /// True while hosting with path proxy active (one public origin / one free cloudflared).
    path_routed: StdMutex<bool>,
    /// Embedded circle TURN for WebRTC ICE — own UDP socket (not a second Endpoint).
    turn_server: StdMutex<Option<haven_net::TurnServer>>,
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
    /// Last `haven/relay/__interface__` fetch attempt per relay (epoch ms), so a media-miss storm
    /// can't hammer the same relay — one attempt per relay per 5 min (iOS relayInterfaceRefreshMs).
    relay_interface_refresh_ms: StdMutex<HashMap<String, u64>>,
    /// App-layer activity rows (deep-linked notifications raised on this device) — the bell's
    /// non-core half, persisted to `activity-app.json` and bounded on append.
    app_activity: StdMutex<Vec<ActivityRow>>,
    /// Frame-9 mesh-relay msgIds already seen (dedup / loop protection, parity with iOS seenRelay).
    seen_relay: StdMutex<std::collections::HashSet<String>>,
    /// Circles whose expired events were already really-purged this app session (purging is
    /// idempotent; once per session is plenty — see `maybe_purge_expired_media`).
    media_purged: StdMutex<std::collections::HashSet<String>>,
    /// Relays that refused us since our roster last reached them (see `note_refused`).
    roster_needed: StdMutex<std::collections::HashSet<String>>,
    /// `"<relay>|<key>"` hello offers that LANDED (see `offer_hello_mailbox`). Per (relay, key) —
    /// never per key alone — so a relay learned AFTER the first offer still gets the hello on the
    /// next greet cycle. In-memory: a relaunch re-PUTs one idempotent content-addressed blob per
    /// relay, which is cheaper than another persisted set.
    hello_offered: StdMutex<std::collections::HashSet<String>>,
    /// Last `heal_forbidden_relays` publish, epoch ms — rate-limits the self-heal to one per 30s.
    last_heal_ms: StdMutex<u64>,
    /// Relays that already hold this exact roster: node → (wire content hash, confirmed at epoch ms).
    /// A roster is ~30 KB and this ran against every relay on every sync tick regardless of change —
    /// which is what produced `relay put timed out` / ConnectionLost. See `publish_device_roster`.
    roster_published: StdMutex<HashMap<String, (u64, u64)>>,
    /// Live iroh soft-rebind when Haven fabric DERP URLs are learned mid-session (RelayMap is bind-time).
    fabric_rebind: StdMutex<FabricRebindState>,
}

/// Tracks messaging-node fabric rebind so we never dual-bind the same key or flap forever.
#[derive(Default)]
struct FabricRebindState {
    /// True while stop+start is running (blocks concurrent rebind).
    in_flight: bool,
    /// Debounce generation — each schedule bumps; only the latest gen runs after 2s.
    debounce_gen: u64,
    /// DERP URLs the live messaging `HavenNode` was last bound with (empty = n0-only bind).
    bound_derp_urls: Vec<String>,
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
const MEDIA_CHUNK_BYTES: usize = crate::mediaresume::UPLOAD_CHUNK_BYTES;
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

/// First 10 chars of an id/ref, for logs — long enough to correlate, short enough not to dump a
/// full identifier into a log file.
fn short(s: &str) -> String {
    s.chars().take(10).collect()
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
        // Matrix QA: dump account + device hex so the linked-device harness can authorize THIS
        // desktop on HavenStub (HTTP signs as the device id; without it Tauri gets REFUSED forever).
        {
            let acct = social.my_node_hex();
            let dev = social.my_device_node_hex();
            let _ = std::fs::write(paths.root.join("qa-account-hex.txt"), &acct);
            let _ = std::fs::write(paths.root.join("qa-device-hex.txt"), &dev);
            eprintln!(
                "qa-identity account={} device={}",
                &acct[..acct.len().min(12)],
                &dev[..dev.len().min(12)]
            );
        }
        // Matrix QA: optional peer public bundle at `qa-peer-bundle.bin` (parity with Android
        // `ingestQaPeerBundleIfPresent`). Lets circle crypto form when HELLO cannot dial and the
        // Mac is a second device of the iOS account that needs the Android friend in members.
        if let Ok(bundle) = std::fs::read(paths.root.join("qa-peer-bundle.bin")) {
            if bundle.len() >= 32 {
                if let Ok(hex) = social.add_contact_bundle("default".into(), bundle) {
                    let name = std::fs::read_to_string(paths.root.join("qa-peer-name.txt"))
                        .ok()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "QA Peer".into());
                    eprintln!("qa-peer-bundle ingested contact={} name={name}", &hex[..hex.len().min(8)]);
                }
            }
        }
        // Switch-Flip 1.0.7: turn the new crypto ON (seed-drop retirement + MLS keying). Both are
        // GATED in-core — inert (byte-identical to 1.0.6) until a circle is fully capable — and NOT
        // persisted, so they're set here after `register_device` and re-applied every launch in
        // `reapply_crypto_switches` (start()). Docs: `docs/SWITCH-FLIP-1.0.7.md` §3/§4.
        social.set_mls_keying(true);
        social.set_seed_drop_retire(true);
        // See `reapply_crypto_switches`: my own posts are exempt from the auto-delete window. Set
        // here too so no feed refresh can run against a false default before `start()`.
        social.set_keep_own_posts(true);
        let app_activity = load_app_activity(&paths);
        let dyn_state = DynState {
            seen_mailbox: load_seen_mailbox(&paths),
            notified: std::fs::read_to_string(paths.root.join("notified.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            media_backed_up: std::fs::read_to_string(paths.root.join("media-backed-up.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            media_unopenable: HashSet::new(),
            media_upload_progress: std::fs::read_to_string(paths.root.join("media-upload-progress.txt"))
                .map(|t| {
                    t.lines()
                        .filter_map(|l| l.split_once('\t'))
                        .map(|(k, v)| (k.to_string(), v.to_string()))
                        .collect()
                })
                .unwrap_or_default(),
            // Pick half-finished media transfers back up rather than restarting them. `load` prunes
            // as it reads (expired, or part file gone), so nothing here can resume into bytes that
            // aren't there.
            reassembly: crate::mediaresume::ReassemblyIndex::load(
                paths.root.join("media-reassembly.txt"),
                paths.media_dir(),
            ),
            ..DynState::default()
        };
        Ok(Arc::new(Self {
            persist_pending: std::sync::atomic::AtomicBool::new(false),
            qa_call: std::sync::atomic::AtomicU8::new(0),
            last_epoch_reseal: std::sync::Mutex::new(0),
            seed: Some(seed),
            social,
            paths,
            media,
            app: StdMutex::new(None),
            node: StdMutex::new(None),
            discovery_asked: StdMutex::new(HashMap::new()),
            history_asked_before: StdMutex::new(HashMap::new()),
            relay_host: StdMutex::new(None),
            quick_tunnel: StdMutex::new(None),
            derp_tunnel: StdMutex::new(None),
            derp_server: StdMutex::new(None),
            path_router: StdMutex::new(None),
            path_routed: StdMutex::new(false),
            turn_server: StdMutex::new(None),
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
            relay_interface_refresh_ms: StdMutex::new(HashMap::new()),
            app_activity: StdMutex::new(app_activity),
            seen_relay: StdMutex::new(std::collections::HashSet::new()),
            media_purged: StdMutex::new(std::collections::HashSet::new()),
            roster_needed: StdMutex::new(std::collections::HashSet::new()),
            hello_offered: StdMutex::new(std::collections::HashSet::new()),
            last_heal_ms: StdMutex::new(0),
            roster_published: StdMutex::new(HashMap::new()),
            fabric_rebind: StdMutex::new(FabricRebindState::default()),
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
        // See `reapply_crypto_switches`: my own posts are exempt from the auto-delete window. Set
        // here too so no feed refresh can run against a false default before `start()`.
        social.set_keep_own_posts(true);
        let prefs = Prefs::load(&paths);
        let media = LocalMedia::new(paths.media_dir());
        let scheduled = crate::scheduled::ScheduledStore::load(&paths.scheduled_file());
        // NB: NO register_device — the primary is the sole roster authority (guarded in-core too, but
        // we never even call it here). The transport still binds to the device seed in `start()`.
        let app_activity = load_app_activity(&paths);
        let dyn_state = DynState {
            seen_mailbox: load_seen_mailbox(&paths),
            notified: std::fs::read_to_string(paths.root.join("notified.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            media_backed_up: std::fs::read_to_string(paths.root.join("media-backed-up.txt"))
                .map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
                .unwrap_or_default(),
            media_unopenable: HashSet::new(),
            media_upload_progress: std::fs::read_to_string(paths.root.join("media-upload-progress.txt"))
                .map(|t| {
                    t.lines()
                        .filter_map(|l| l.split_once('\t'))
                        .map(|(k, v)| (k.to_string(), v.to_string()))
                        .collect()
                })
                .unwrap_or_default(),
            // Pick half-finished media transfers back up rather than restarting them. `load` prunes
            // as it reads (expired, or part file gone), so nothing here can resume into bytes that
            // aren't there.
            reassembly: crate::mediaresume::ReassemblyIndex::load(
                paths.root.join("media-reassembly.txt"),
                paths.media_dir(),
            ),
            ..DynState::default()
        };
        Ok(Arc::new(Self {
            persist_pending: std::sync::atomic::AtomicBool::new(false),
            qa_call: std::sync::atomic::AtomicU8::new(0),
            last_epoch_reseal: std::sync::Mutex::new(0),
            seed: None,
            social,
            paths,
            media,
            app: StdMutex::new(None),
            node: StdMutex::new(None),
            discovery_asked: StdMutex::new(HashMap::new()),
            history_asked_before: StdMutex::new(HashMap::new()),
            relay_host: StdMutex::new(None),
            quick_tunnel: StdMutex::new(None),
            derp_tunnel: StdMutex::new(None),
            derp_server: StdMutex::new(None),
            path_router: StdMutex::new(None),
            path_routed: StdMutex::new(false),
            turn_server: StdMutex::new(None),
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
            relay_interface_refresh_ms: StdMutex::new(HashMap::new()),
            app_activity: StdMutex::new(app_activity),
            seen_relay: StdMutex::new(std::collections::HashSet::new()),
            media_purged: StdMutex::new(std::collections::HashSet::new()),
            roster_needed: StdMutex::new(std::collections::HashSet::new()),
            hello_offered: StdMutex::new(std::collections::HashSet::new()),
            last_heal_ms: StdMutex::new(0),
            roster_published: StdMutex::new(HashMap::new()),
            fabric_rebind: StdMutex::new(FabricRebindState::default()),
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

    pub(crate) fn emit_changed(&self) {
        if let Some(app) = self.app.lock().unwrap().clone() {
            let _ = app.emit("haven:changed", ());
        }
    }

    /// Emit an arbitrary frontend event. The archive importer runs on its own thread for minutes at
    /// a time and pushes progress with this rather than making the UI poll — and it is a no-op in
    /// headless mode, where there is no window to tell.
    pub(crate) fn emit_event(&self, name: &str, payload: serde_json::Value) {
        if let Some(app) = self.app.lock().unwrap().clone() {
            let _ = app.emit(name, payload);
        }
    }

    /// This identity's data directory (the archive importer's resume checkpoint lives beside
    /// `prefs.json` / `scheduled.json`).
    pub(crate) fn paths(&self) -> &Paths {
        &self.paths
    }

    /// [`Self::notify`] with an optional `haven://…` deep link describing what the notification is
    /// ABOUT, so acting on it can open that rather than just raising the window.
    ///
    /// The link rides the in-app `haven:notify` event, which the frontend routes through the same
    /// `DeepLink` parser as a pasted or shared link — one route table, one set of rules about what a
    /// link may open. It is NOT attached to the OS toast: tauri-plugin-notification has no
    /// cross-platform click payload here, so a click on the native toast still only raises the app.
    /// That's an honest limitation rather than a silently-broken affordance — the in-app toast is
    /// clickable, and the fetch happens either way.
    fn notify_with_link(&self, title: &str, body: &str, deep_link: Option<&str>) {
        // Every deep-linked notification is also an ACTIVITY row, so the bell holds what a missed
        // toast said (the toast is ephemeral; the bell is where you catch up).
        if deep_link.is_some() {
            self.append_app_activity(title, body, deep_link);
        }
        // A deep-linked notification is worth showing while FOREGROUND too — "your media is back"
        // silently doing nothing for someone already looking at the app is the case this exists for.
        if deep_link.is_none() && self.dyn_state.lock().unwrap().foreground {
            return;
        }
        if let Some(app) = self.app.lock().unwrap().clone() {
            // Native OS notification (Action Center / toast) — skipped while frontmost, where the
            // in-app toast below is the better surface.
            if !self.dyn_state.lock().unwrap().foreground {
                use tauri_plugin_notification::NotificationExt;
                let _ = app.notification().builder().title(title).body(body).show();
            }
            // …and an in-app event for a toast if a window is open.
            let _ = app.emit(
                "haven:notify",
                serde_json::json!({ "title": title, "body": body, "deepLink": deep_link }),
            );
        }
    }

    /// Append one app-layer row to the activity list (bounded, persisted). Called from
    /// `notify_with_link` — the bell mirrors every deep-linked notification this device raises.
    fn append_app_activity(&self, title: &str, body: &str, deep_link: Option<&str>) {
        let snapshot = {
            let mut rows = self.app_activity.lock().unwrap();
            rows.insert(0, ActivityRow {
                id: format!("app-{}", now_ms()),
                kind: "app".into(),
                circle_id: String::new(),
                actor_name: title.to_string(),
                snippet: body.to_string(),
                created_at: now_ms(),
                emoji: None,
                link: deep_link.map(str::to_string),
            });
            rows.truncate(200);
            rows.clone()
        };
        if let Ok(d) = serde_json::to_vec(&snapshot) {
            let _ = std::fs::write(self.paths.root.join("activity-app.json"), d);
        }
    }

    /// The activity feed for the bell: core rows (reactions / comments / votes on MY events plus
    /// others' posts, stories and DMs, across every circle — `social.activity()`) merged with the
    /// app-layer rows, newest-first, capped. Names are resolved here; each row carries the
    /// interaction deep link the UI jumps to.
    pub fn activity(&self) -> Vec<ActivityRow> {
        let now = now_ms();
        let mut out: Vec<ActivityRow> = self
            .social
            .activity(0, now)
            .into_iter()
            .map(|it| {
                let link = if it.kind == "dm" {
                    Some(wire::interaction_link(&it.circle_id, Some(&it.id)))
                } else {
                    // Reactions/comments/votes link to the PARENT post; posts/stories to themselves.
                    let pid = it.target_id.clone().unwrap_or_else(|| it.id.clone());
                    Some(wire::interaction_link(&it.circle_id, Some(&pid)))
                };
                ActivityRow {
                    id: it.id,
                    kind: it.kind,
                    circle_id: it.circle_id,
                    actor_name: self.display_name(&it.actor_short),
                    snippet: it.snippet,
                    created_at: it.created_at,
                    emoji: it.emoji,
                    link,
                }
            })
            .collect();
        out.extend(self.app_activity.lock().unwrap().iter().cloned());
        out.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(a.id.cmp(&b.id)));
        out.truncate(200);
        out
    }

    /// The bell's "seen up to" watermark (unix ms) — rows newer than this badge.
    pub fn activity_seen_at(&self) -> u64 {
        self.prefs.lock().unwrap().activity_seen_at
    }

    /// Opening the bell marks everything current as seen. MONOTONIC — merged per-key MAX across my
    /// devices via `setting:activitySeenAt`, so this clears the badge fleet-wide.
    pub fn mark_activity_seen(&self) {
        {
            let mut p = self.prefs.lock().unwrap();
            let now = now_ms();
            if now <= p.activity_seen_at {
                return;
            }
            p.activity_seen_at = now;
            let _ = p.save(&self.paths);
        }
        self.nudge_self_sync(); // clear the bell badge on my other devices promptly
        self.emit_changed();
    }

    /// Pinned DM ids in pin order (synced via `setting:pinnedDMs`).
    pub fn pinned_dms(&self) -> Vec<String> {
        self.prefs.lock().unwrap().pinned_dms.clone()
    }

    /// Replace the pinned-DM list (the UI enforces the 6-cap; clamped here too).
    pub fn set_pinned_dms(&self, ids: Vec<String>) {
        let changed = {
            let mut p = self.prefs.lock().unwrap();
            let ids: Vec<String> = ids.into_iter().take(6).collect();
            let changed = ids != p.pinned_dms;
            p.pinned_dms = ids;
            let _ = p.save(&self.paths);
            changed
        };
        if changed {
            self.nudge_self_sync(); // pin/unpin reaches my other devices promptly
        }
    }

    /// One blind wake through the push Worker (`/notify`): `ciphertext` = a sealed+SIGNED banner
    /// only the recipient's device can open (the Worker forwards it blind); `event` inlines the
    /// sealed circle envelope for push-inline sync; `silent` delivers with no banner (syncSelf /
    /// republish traffic). Fire-and-forget — polling still carries everything if push is down.
    /// Parity with iOS `PushManager.wake` / `syncSelf`.
    fn push_wake(&self, node_hex: &str, ciphertext: Option<String>, event: Option<String>, silent: bool) {
        if node_hex.is_empty() {
            return;
        }
        let mut body = serde_json::json!({
            "nodeId": node_hex,
            "ciphertext": ciphertext.unwrap_or_else(|| "_".into()),
        });
        if let Some(e) = event {
            body["event"] = e.into();
        }
        if silent {
            body["silent"] = true.into();
        }
        let http = self.http.clone();
        tauri::async_runtime::spawn(async move {
            // Manual JSON body — this crate's reqwest is built without the `json` feature.
            let _ = http
                .post(format!("{PUSH_RELAY}/notify"))
                .header("content-type", "application/json")
                .body(body.to_string())
                .send()
                .await;
        });
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

    // ---- account device discovery (relay-optional reachability) --------------------------

    /// Publish my account -> device-id mapping to the public directory, so a contact who holds only
    /// my account id can dial one of my devices with NO relay in common. Fire-and-forget; the
    /// publisher re-publishes on its own TTL for as long as the node lives. iOS/Android parity.
    fn publish_account_devices(self: &Arc<Self>) {
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        let social = self.social.clone();
        tauri::async_runtime::spawn(async move {
            match node.publish_account_devices(social).await {
                Ok(ids) if !ids.is_empty() => log::info!("discovery published devices={}", ids.len()),
                Ok(_) => {}
                Err(e) => log::debug!("discovery publish failed: {e}"),   // additive - never fatal
            }
        });
    }

    /// Look up device ids for a contact we have NO way to dial — no signed roster, no invite hint,
    /// just an account id that is not a transport address. Results are recorded as dial HINTS, never
    /// as authorization: content stays sealed to the circle epoch key and inbound frames stay gated
    /// on the signed roster. Throttled per account (most contacts have simply never published, and
    /// an unthrottled lookup would fire a DNS round-trip per peer per sync tick to learn nothing).
    fn resolve_missing_device_ids(self: &Arc<Self>, account_hex: &str) {
        const RETRY_MS: u64 = 600_000; // 10 min
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        let key = account_hex.to_lowercase();
        {
            let mut asked = self.discovery_asked.lock().unwrap();
            let now = now_ms();
            if let Some(at) = asked.get(&key) {
                if now.saturating_sub(*at) < RETRY_MS {
                    return;
                }
            }
            asked.insert(key.clone(), now);
        }
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            let Ok(ids) = node.resolve_account_devices(key.clone()).await else { return };
            if ids.is_empty() {
                return;
            }
            log::info!("discovery resolved {} devices={}", &key[..8.min(key.len())], ids.len());
            me.record_device_hints(&key, ids);
            // A peer we could not reach a moment ago is reachable NOW. Don't make them wait for the
            // next sync tick and the announce cadence to find that out: re-announce our relays and
            // sync immediately — what a peer with no relay in common is missing is exactly that
            // announce.
            me.reannounce_own_relay();
            me.sync_with_contacts();
        });
    }

    pub fn get_profile(&self) -> Profile {
        self.prefs.lock().unwrap().profile.clone()
    }

    pub fn set_profile(self: &Arc<Self>, profile: Profile) {
        let edited = {
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
            let edited = p.profile.name != profile.name
                || p.profile.emoji != profile.emoji
                || p.profile.bio != profile.bio
                || p.profile.link != profile.link
                || p.profile.avatar != profile.avatar;
            p.profile = profile;
            let _ = p.save(&self.paths);
            edited
        };
        if edited {
            self.nudge_self_sync(); // reach my other devices in seconds, not next scheduled pass
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
        // Haven fabric BEFORE bind: iroh takes RelayMap at Endpoint construct time. Applying after
        // HavenNode::start left the main node on n0 for the whole session even when prefs already
        // knew circle DERP URLs. Late learns still call refresh_haven_fabric for the next bind.
        self.refresh_haven_fabric();
        let listener: Arc<dyn InboundListener> = Arc::new(NodeListener {
            engine: Arc::downgrade(self),
        });
        // Bind the transport to the per-DEVICE seed (unique node/relay id per install, parity with
        // iOS/Android device-seed transport) — never the account id, which is identity-only.
        let device_seed = self.roster.lock().unwrap().device_seed.clone();
        match HavenNode::start(device_seed, listener).await {
            Ok(node) => {
                *self.node.lock().unwrap() = Some(node);
                // Account id -> my device ids in the public directory, so a contact who holds only
                // my account id can dial me with NO relay in common (parity with iOS/Android).
                self.publish_account_devices();
                // Record which fabric map this bind used so mid-session learns can soft-rebind only
                // when the set actually changes (not on every refresh).
                self.fabric_rebind.lock().unwrap().bound_derp_urls = haven_net::active_derp_urls();
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
        // MY OWN posts are never aged out by the auto-delete window. The window exists so a member's
        // disk is not filled by OTHER people's history; my own feed is my archive, and deleting it
        // is not a storage policy, it is data loss. The core has always supported this
        // (`keep_own_posts`, honoured by `purge_expired`) and documents the app as owning the
        // toggle — but no client ever called it, so it sat false everywhere.
        //
        // That is what ate the Instagram import: every imported post is backdated years, so the
        // first feed refresh after publishing purged the lot and freed their blobs. Kept stories
        // survived only because pinning exempts them, which is exactly why stories were the one
        // thing that appeared.
        self.social.set_keep_own_posts(true);
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
            // A destination accepted the fresh blob → this ref is repaired. Heal + retry on a refusal
            // exactly as `upload_media` does: this migration latches after MAX_ATTEMPTS, so a ref that
            // is merely awaiting authorization would otherwise burn its attempts and be written off as
            // un-repairable while every relay was healthy the whole time.
            if self.upload_media_inner(circle_id, r, true).await
                || (self.heal_forbidden_relays().await
                    && self.upload_media_inner(circle_id, r, true).await)
            {
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

    /// qa-cmd v2 cadence contract (DEBUG driver only — see `qa.rs`): a qa op represents a user
    /// ACTIVELY using the app. A MUTATING op is the real user-activity hook verbatim
    /// (`bump_activity`) plus ONE immediate off-schedule mailbox pass, so freshly authored
    /// content uploads NOW instead of on the next 10s heartbeat (off-schedule polls already
    /// overlap the loop elsewhere — relay add, s3_configure — so this is the same tolerance).
    /// The non-mutating `dump` op resets the adaptive idle multiplier but must NOT force a
    /// poll — receivers converge at their real active-cadence poll, keeping measured
    /// convergence latency honest — so armed (possibly idle-stretched) due times are clamped
    /// down to the tight base, never to "now".
    #[cfg(debug_assertions)]
    pub fn qa_mark_user_active(self: &Arc<Self>, mutating: bool) {
        if mutating {
            self.bump_activity();
            let me = self.clone();
            tauri::async_runtime::spawn(async move {
                me.poll_mailbox().await;
                me.poll_self_sync().await;
            });
        } else {
            let now = now_ms();
            let mut st = self.dyn_state.lock().unwrap();
            st.last_activity_ms = now;
            // Base cadences from start_mailbox_loop: poll 30s, sync 20s.
            st.next_poll_due_ms = st.next_poll_due_ms.min(now + 30_000);
            st.next_sync_due_ms = st.next_sync_due_ms.min(now + 20_000);
        }
    }

    /// A LOCAL mutation of self-sync-carried state just happened (profile edit, circle
    /// create/membership, DM pin, read watermark, synced setting…) → arm a short debounced
    /// deadline; the heartbeat runs ONE self-sync pass when it expires (see `start_mailbox_loop`).
    /// Without this, an edit only propagated on the next scheduled pass — 30s base, stretched to
    /// minutes when idle — so a profile change took "never within 30s" to reach the user's other
    /// devices. Each call slides the deadline, coalescing an edit burst (renaming twice, pinning
    /// three DMs) into a single pass. Deliberately does NOT touch the periodic cadence.
    fn nudge_self_sync(&self) {
        self.dyn_state.lock().unwrap().selfsync_nudge_at_ms = now_ms() + 4_000;
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
                // Debounced "self-sync now" nudge (see nudge_self_sync): a local edit of synced
                // state armed a deadline — honor it here, off-schedule, so the edit reaches the
                // user's other devices in seconds. A due poll bucket clears any pending nudge too
                // (its own pass snapshots the same mutation), so a burst never runs twice.
                let nudge_due = {
                    let mut st = me.dyn_state.lock().unwrap();
                    let due = st.selfsync_nudge_at_ms != 0 && now >= st.selfsync_nudge_at_ms;
                    if due || poll_due {
                        st.selfsync_nudge_at_ms = 0;
                    }
                    due
                };
                if poll_due {
                    me.poll_mailbox().await;
                    me.poll_self_sync().await;
                } else if nudge_due {
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
                    // saturating_sub, not `-`. These are wall-clock millisecond stamps, and a
                    // u64 subtraction where the stored stamp is AHEAD of `now` underflows and
                    // panics in a debug build. It happens: the clock steps backwards (NTP
                    // correction, sleep/wake, a VM host resyncing), and the stamp written before
                    // the step is then in the future.
                    //
                    // That is not a hypothetical. This exact line aborted the desktop app:
                    //
                    //   thread 'tokio-rt-worker' panicked at engine.rs:1693: attempt to subtract with overflow
                    //   thread 'qa-driver'       panicked: PoisonError { .. }
                    //   thread 'main'            panicked: PoisonError { .. }
                    //   fatal runtime error: failed to initiate panic, aborting
                    //
                    // One arithmetic underflow poisoned `dyn_state`, and every later thread that
                    // touched it died on the poison — including the QA driver, whose death is what
                    // silently froze the dump file for the rest of a run. A stale timer is worth
                    // nothing; crashing over one is worth less.
                    let backfill_due = {
                        let mut st = me.dyn_state.lock().unwrap();
                        if now.saturating_sub(st.last_media_backfill_ms) > 120_000 {
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
                        // Same cadence: a relay that does not know a circle's members refuses them
                        // for everything, and only a member it already serves can teach it.
                        me.enroll_circle_members().await;
                    }
                    // Daily (first sync tick after launch, then every 24h of uptime): re-assert my event
                    // envelopes in every circle mailbox — upload what a relay never saw, TOUCH what it
                    // already holds so relay-side mailbox GC (30-day TTL) keeps live entries while legacy
                    // duplicates and stale-epoch copies age out.
                    let refresh_due = {
                        let mut st = me.dyn_state.lock().unwrap();
                        if now.saturating_sub(st.last_event_refresh_ms) > 86_400_000 {
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
    /// Hand each relay the circle's full relay list so replication is symmetric. Best-effort and
    /// silent: an older relay has no such verb and keeps whatever its operator configured.
    async fn teach_sibling_relays(self: &Arc<Self>, pool: &[String]) {
        if pool.len() < 2 {
            return; // nothing to teach when we're the only relay
        }
        let circle_ids: Vec<String> =
            self.social.circles().into_iter().map(|c| c.id).collect();
        if circle_ids.is_empty() {
            return;
        }
        for target in pool {
            let Some(client) = self.relay_client_for(target).await else { continue };
            let others: Vec<String> = pool.iter().filter(|h| *h != target).cloned().collect();
            for cid in &circle_ids {
                let _ = client.teach_relays(cid.clone(), others.clone()).await;
            }
        }
    }

    async fn mesh_sync(self: &Arc<Self>) {
        let Some(host) = self.relay_host.lock().unwrap().clone() else { return };
        let my_hex = host.node_id_hex();
        let peers: std::collections::BTreeSet<String> = {
            let p = self.prefs.lock().unwrap();
            p.relays.values().flatten().filter(|h| p.relay_is_active(h)).cloned().collect()
        };
        // Teach every relay in the pool about the others. We already pull from all of them; a
        // HEADLESS relay knew only the `--peer` hexes its operator typed, so it never pulled back
        // and anything uploaded while it was offline stayed missing there. Apple/Android parity.
        {
            let mut pool: Vec<String> = peers.iter().filter(|h| h.len() == 64).cloned().collect();
            if my_hex.len() == 64 && !pool.contains(&my_hex) {
                pool.push(my_hex.clone());
            }
            self.teach_sibling_relays(&pool).await;
        }
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
                // `None` retention: a scheduled item does not carry one — same as Apple, whose
                // ScheduledStore has no retention field either. Send-later and disappear-after are
                // independent features; combining them would need the schedule to store it.
                crate::scheduled::SchedKind::Post => {
                    self.post(it.circle_id, it.body, it.media, music, it.mute_video, None);
                }
                crate::scheduled::SchedKind::Dm => {
                    self.send_dm(it.circle_id, it.body, it.media, music, None);
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
        let changed = {
            let mut p = self.prefs.lock().unwrap();
            let changed = p.host_on_launch != on;
            if changed {
                p.stamp_setting("host_on_launch"); // LWW so two desktops don't ping-pong this toggle
            }
            p.host_on_launch = on;
            let _ = p.save(&self.paths);
            changed
        };
        if changed {
            self.nudge_self_sync(); // synced setting — reach my other devices promptly
        }
    }

    pub fn video_sound_on(&self) -> bool {
        self.prefs.lock().unwrap().video_sound_on
    }

    /// Device-local privacy prefs (notification lock-screen detail, super data saver, send original).
    pub fn privacy_prefs(&self) -> (String, bool, bool) {
        let p = self.prefs.lock().unwrap();
        (
            p.notification_detail
                .clone()
                .unwrap_or_else(|| "full".into()),
            p.super_data_saver,
            p.send_original,
        )
    }

    /// The low-data level in force (`"normal"` / `"low"` / `"ultra"`).
    ///
    /// Desktop has no path monitor (see `commands::low_data_state`), so this is the user's choice,
    /// held in the same device-local prefs as the manual data saver. `super_data_saver` still forces
    /// at least the `low` profile, so the existing switch keeps working and the two cannot disagree.
    pub fn low_data_level(self: &Arc<Self>) -> String {
        let p = self.prefs.lock().unwrap();
        let chosen = p.low_data_level.clone().unwrap_or_else(|| "normal".into());
        if chosen == "normal" && p.super_data_saver {
            "low".into()
        } else {
            chosen
        }
    }

    pub fn set_low_data_level(self: &Arc<Self>, level: &str) {
        let normalized = match level {
            "ultra" => "ultra",
            "low" => "low",
            _ => "normal",
        };
        let improved = {
            let mut p = self.prefs.lock().unwrap();
            let sev = |l: &str| match l { "ultra" => 2, "low" => 1, _ => 0 };
            let was = sev(p.low_data_level.as_deref().unwrap_or("normal"));
            p.low_data_level = Some(normalized.into());
            let _ = p.save(&self.paths);
            sev(normalized) < was
        };
        // The link just got better — complete the media that was held back, now. Mirrors
        // `LowDataMonitor.recompute` on iOS and Android (docs/PREVIEW-TIER-DESIGN.md §4.3).
        // Taken AFTER the prefs lock is dropped: `request_missing_media` reads them.
        if improved {
            self.request_missing_media();
        }
    }

    pub fn set_privacy_prefs(
        self: &Arc<Self>,
        notification_detail: Option<String>,
        super_data_saver: Option<bool>,
        send_original: Option<bool>,
    ) {
        let mut p = self.prefs.lock().unwrap();
        if let Some(d) = notification_detail {
            p.notification_detail = Some(match d.as_str() {
                "private" | "minimal" => d,
                _ => "full".into(),
            });
        }
        if let Some(v) = super_data_saver {
            p.super_data_saver = v;
        }
        if let Some(v) = send_original {
            p.send_original = v;
        }
        let _ = p.save(&self.paths);
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
        self.nudge_self_sync(); // the new circle rides a prompt pass to my other devices
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
        self.nudge_self_sync(); // replacement circle + legacy tombstone ride a prompt pass
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
            self.nudge_self_sync();
            self.emit_changed();
        }
        ok
    }

    pub fn rename_circle(self: &Arc<Self>, id: String, name: String) {
        self.social.rename_circle(id, name);
        self.persist();
        self.nudge_self_sync();
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
        self.nudge_self_sync(); // the deletion tombstone rides a prompt pass (delete here = delete everywhere)
        self.emit_changed();
    }

    /// Add an existing contact to a circle + greet them there so it forms on their side.
    pub fn add_to_circle(self: &Arc<Self>, circle_id: String, contact_id_hex: String) {
        self.clear_circle_removal(&circle_id, &contact_id_hex); // deliberate re-add un-bans them
        let _ = self.social.add_existing_to_circle(circle_id.clone(), contact_id_hex.clone());
        self.persist();
        self.nudge_self_sync();
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
        self.nudge_self_sync(); // the severance rides a prompt pass so no sibling re-adds them meanwhile
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
        // Expire first, THEN sweep with what's left alive. Order matters both ways: expiring first
        // means `live_parts` can't name a partial the sweep should have reclaimed, and sweeping
        // against that map means the sweep can't delete a 99%-complete download a record still
        // points at — which is exactly how resume died on Apple before this landed there.
        let live_parts = {
            let mut st = self.dyn_state.lock().unwrap();
            let dropped = st.reassembly.expire();
            if dropped > 0 {
                log::info!("media reassembly: dropped {dropped} abandoned or orphaned partial(s)");
            }
            st.reassembly.flush(); // land whatever the save debounce is still holding
            st.reassembly.live_parts()
        };
        let res = self.media.sweep_orphans(&keep, 48 * 3600, &live_parts);
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

    // ---- Kept stories (held on my profile past the 24h window) ---------------------------

    /// Every kept story, newest first.
    pub fn kept_stories(&self) -> Vec<crate::store::KeptStory> {
        let mut v = self.prefs.lock().unwrap().kept_stories.clone();
        v.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        v
    }

    pub fn is_story_kept(&self, id: &str) -> bool {
        self.prefs.lock().unwrap().kept_stories.iter().any(|k| k.id == id)
    }

    /// Keep a story: snapshot it and PIN its media, so the blobs survive the cleanup sweeps that
    /// would otherwise reclaim them once the event is gone. Without the pin a kept story becomes a
    /// row of "no longer available" placeholders — kept in name only.
    pub fn keep_story(self: &Arc<Self>, entry: crate::store::KeptStory) {
        let media = {
            let mut p = self.prefs.lock().unwrap();
            if p.kept_stories.iter().any(|k| k.id == entry.id) {
                return;
            }
            let media = entry.media.clone();
            let mut e = entry;
            e.kept_at = Some(now_ms());
            p.kept_stories_removed.remove(&e.id); // re-keeping clears the tombstone
            p.kept_stories.push(e);
            let _ = p.save(&self.paths);
            media
        };
        self.pin_media(media);
        self.nudge_self_sync(); // the kept entry rides a prompt pass to my other devices
    }

    /// Stop keeping it — and release the pin, so the blobs are eligible for cleanup again.
    pub fn unkeep_story(self: &Arc<Self>, id: &str) {
        let release = {
            let mut p = self.prefs.lock().unwrap();
            let Some(i) = p.kept_stories.iter().position(|k| k.id == id) else { return };
            let media = p.kept_stories.remove(i).media;
            p.kept_stories_removed.insert(id.to_string(), now_ms());
            p.trim_kept_tombstones();
            // Only release blobs no OTHER kept story still needs (a story shared twice shares refs).
            let still_needed: std::collections::HashSet<&String> =
                p.kept_stories.iter().flat_map(|k| k.media.iter()).collect();
            let release: Vec<String> =
                media.into_iter().filter(|r| !still_needed.contains(r)).collect();
            let _ = p.save(&self.paths);
            release
        };
        self.unpin_media(release);
        self.nudge_self_sync(); // the un-keep tombstone rides a prompt pass
    }

    /// The `setting:keptStories` payload, or None when there is nothing at all to say — never
    /// published empty, so a fresh device can't blank a sibling's collection.
    pub fn kept_stories_payload(&self) -> Option<Vec<u8>> {
        let p = self.prefs.lock().unwrap();
        if p.kept_stories.is_empty() && p.kept_stories_removed.is_empty() {
            return None;
        }
        serde_json::to_vec(&crate::store::KeptStoriesWire {
            kept: p.kept_stories.clone(),
            removed: p.kept_stories_removed.clone(),
        })
        .ok()
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

    // ---- Re-optimize media I already shared -----------------------------------------------
    //
    // The DESIGN lives in `reoptimize.rs` (and, upstream of it, in the header of
    // `apple/HavenApp/MediaReoptimize.swift`). What lives HERE is only the part that needs the
    // engine: which of my events carry media, what their blobs actually are, and writing the Edit.
    //
    // The orchestration — batching, cancel, the encode itself — is in the WebView (`app.js`),
    // because the encoder IS the WebView. Desktop covers STILLS ONLY; see the module header for why
    // re-encoding video here would replace playable media with media Apple cannot decode.

    /// Every post and comment I AUTHORED that carries media, across every circle including DMs.
    ///
    /// AUTHORED, because re-optimizing means re-publishing and an Edit is signed by the author: I
    /// cannot re-point someone else's post at new bytes and must not be able to. Media others sent me
    /// is left exactly as it arrived — the local caps and the cleanup sweep are the answer for that.
    ///
    /// Stories are excluded (they expire on their own, so a rewrite spends an encode and a re-upload
    /// on bytes that are about to be dropped anyway), and so are unsent/retracted items. Retention is
    /// passed as `None` deliberately: retention hides old posts from MY feed, but they are still live
    /// on everyone else's devices and still costing them the old bytes.
    pub fn reoptimize_targets(&self) -> Vec<ReoptimizeTarget> {
        let mut out = Vec::new();
        let now = now_ms();
        for c in self.social.circles() {
            for item in self.social.feed(c.id.clone(), now, None) {
                if item.is_me && !item.unsent && !item.story && !item.media.is_empty() {
                    out.push(ReoptimizeTarget {
                        circle_id: c.id.clone(),
                        event_id: item.id.clone(),
                        body: item.body.clone(),
                        media: item.media.clone(),
                        music: item.music.clone(),
                        mute_video: item.mute_video,
                        created_at: item.created_at,
                    });
                }
                for cm in &item.comments {
                    if cm.is_me && !cm.unsent && !cm.media.is_empty() {
                        out.push(ReoptimizeTarget {
                            circle_id: c.id.clone(),
                            event_id: cm.id.clone(),
                            body: cm.body.clone(),
                            media: cm.media.clone(),
                            // A comment carries neither a music attachment nor a mute flag.
                            music: None,
                            mute_video: false,
                            created_at: cm.created_at,
                        });
                    }
                }
            }
        }
        out
    }

    /// Find my shared STILLS that are above target, biggest first, plus a count of the video/audio
    /// this device deliberately cannot handle.
    ///
    /// Blocking and honest about it: judging a blob means DECRYPTING it (everything at rest is sealed
    /// to its circle), so this is O(my media). It is button-driven and never runs on its own, which is
    /// what makes that acceptable — see the bounding rules in the Apple header.
    pub fn reoptimize_scan(&self) -> ReoptimizeScan {
        let skipped: std::collections::HashSet<String> =
            self.prefs.lock().unwrap().reoptimize_skipped.iter().cloned().collect();

        // Earliest time each ref was shared by me, and which circle it lives in. A ref used by
        // several posts is ONE encode.
        let mut first_shared: std::collections::HashMap<String, (u64, String)> = Default::default();
        // Refs that turn up under MORE THAN ONE circle. A blob is sealed to exactly one circle's key,
        // so a re-encode could only be re-sealed to one of them — the other circle's members would
        // receive an envelope they cannot open. Rather than half-fix that, such refs are left alone.
        let mut cross_circle: std::collections::HashSet<String> = Default::default();
        let mut videos_above_target = 0usize;
        let mut video_bytes = 0u64;

        for t in self.reoptimize_targets() {
            for r in &t.media {
                if LocalMedia::is_synthetic(r) {
                    continue; // `geo:` pins ride in the media array and carry no bytes
                }
                match first_shared.get_mut(r) {
                    Some((ms, circle)) => {
                        *ms = (*ms).min(t.created_at);
                        if *circle != t.circle_id {
                            cross_circle.insert(r.clone());
                        }
                    }
                    None => {
                        first_shared.insert(r.clone(), (t.created_at, t.circle_id.clone()));
                    }
                }
            }
        }

        let mut candidates: Vec<ReoptimizeCandidate> = Vec::new();
        for (reference, (since, circle_id)) in first_shared {
            // Video and audio are COUNTED so the user isn't told a 1.2 GB library is already optimal,
            // but never offered: this device's only encoder emits VP8/Opus in WebM, which would turn
            // a clip every member can play into one Apple cannot decode. Module header has the full
            // reasoning.
            if LocalMedia::is_video(&reference) || LocalMedia::is_audio(&reference) {
                if let Some(bytes) = self.media.raw_sealed(&reference) {
                    // No decrypt: the sealed size is within AEAD overhead of the plaintext size, and
                    // this figure is only ever shown as "N videos, X MB".
                    if bytes.len() as u64 >= crate::reoptimize::MINIMUM_INTERESTING_BYTES {
                        videos_above_target += 1;
                        video_bytes += bytes.len() as u64;
                    }
                }
                continue;
            }
            if skipped.contains(&reference) || cross_circle.contains(&reference) {
                continue;
            }
            // Only refs whose bytes are actually HERE. One that was evicted or never arrived cannot be
            // re-encoded from nothing, and re-downloading a blob in order to shrink it is a decision
            // for the user, not for a settings button.
            let Some(plain) = self.media_bytes(&circle_id, &reference) else { continue };
            let Some(shape) = crate::reoptimize::probe_image(&plain) else { continue };
            if !shape.above_target() {
                continue;
            }
            candidates.push(ReoptimizeCandidate {
                reference,
                circle_id,
                bytes: shape.bytes,
                width: shape.width,
                height: shape.height,
                format: shape.format.to_string(),
                reason: shape.above_target_reason.clone().unwrap_or_default(),
                first_shared_ms: since,
                legacy_by_age: crate::reoptimize::is_legacy_by_age(since),
            });
        }
        // Biggest first: the win is dominated by a handful of files, so a user who runs one batch and
        // stops should still have captured most of the saving.
        candidates.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        ReoptimizeScan { candidates, videos_above_target, video_bytes }
    }

    /// Judge a freshly re-encoded still and, only if it is a real win, store it and return its ref.
    ///
    /// THIS is where "never keep a re-encode that isn't smaller" is enforced, rather than in the
    /// WebView that produced the bytes: a rewrite that does not clearly win is WORSE than none,
    /// because every member of the circle pays a re-download for nothing. Keeping the rule next to
    /// `is_worth_adopting` (and its tests) means there is one definition of "clear win", not a
    /// constant copied into JS that can drift.
    ///
    /// Returns `Ok(None)` when the encode is rejected — the caller keeps the original, and the ref
    /// is added to the skip set so no future scan offers it again. Note the new blob is only written
    /// AFTER it has been accepted, so a rejected encode never mints a ref at all.
    pub fn reoptimize_accept(
        &self,
        circle_id: String,
        reference: String,
        bytes: Vec<u8>,
    ) -> Option<String> {
        // The ORIGINAL's authoritative plaintext length, read back from the store rather than taken
        // from the caller: the number the comparison turns on must not be one the WebView supplies.
        let Some(original) = self.media_bytes(&circle_id, &reference) else {
            self.reoptimize_skip(reference);
            return None;
        };
        let old_len = original.len() as u64;
        let new_len = bytes.len() as u64;

        // Whatever came back must still be a still we can parse. An encoder that emitted something
        // unreadable must never have its output published in place of a working photo.
        let Some(shape) = crate::reoptimize::probe_image(&bytes) else {
            log::warn!("reoptimize: re-encode of {} was unreadable — keeping the original", &reference[..reference.len().min(12)]);
            self.reoptimize_skip(reference);
            return None;
        };
        if !crate::reoptimize::is_worth_adopting(old_len, new_len) {
            log::info!(
                "reoptimize: {} came back no smaller ({new_len} vs {old_len}) — keeping the original",
                &reference[..reference.len().min(12)]
            );
            self.reoptimize_skip(reference);
            return None;
        }
        let new_ref = self.media.store(&self.social, &circle_id, &bytes, false);
        if new_ref == reference {
            // Identical bytes hash to an identical address, so there is nothing to swap.
            self.reoptimize_skip(reference);
            return None;
        }
        // The win is real, so it is adopted — but if the OUTPUT is itself still above target (a huge
        // dense source whose q0.62 copy is smaller yet still over the ceiling), record the NEW ref as
        // skipped. The user keeps the saving, and the next scan doesn't offer the same photo forever.
        // This is stricter than Apple, which relies on the encoder's targets alone for idempotence.
        if shape.above_target() {
            log::info!(
                "reoptimize: adopted {} -> {} ({old_len} -> {new_len}) but output is still {} at {}px; not offering it again",
                &reference[..reference.len().min(12)],
                &new_ref[..new_ref.len().min(12)],
                shape.format,
                shape.max_dimension()
            );
            self.reoptimize_skip(new_ref.clone());
        }
        Some(new_ref)
    }

    /// Record a ref as not-worth-retrying (encode failed, or came back no smaller). Bounded.
    pub fn reoptimize_skip(&self, reference: String) {
        let mut p = self.prefs.lock().unwrap();
        if crate::reoptimize::push_skip(&mut p.reoptimize_skipped, reference) {
            let _ = p.save(&self.paths);
        }
    }

    /// Would an encode of this size fit? Refuses on a nearly-full disk (Apple parity).
    pub fn reoptimize_has_headroom(&self, bytes: u64) -> bool {
        crate::reoptimize::has_disk_headroom(&self.paths.media_dir(), bytes)
    }

    /// Re-point one of my posts/comments at newly-encoded refs and re-share it.
    ///
    /// An ordinary EDIT — the same event the caption editor writes. It keeps the item's id, author,
    /// thread position and original timestamp, so nobody's feed reorders and no notification fires;
    /// only the media array changes. The new blob is then uploaded exactly as a fresh post's would
    /// be, so members who are offline right now still find it waiting for them.
    ///
    /// SILENT: `after_author` is passed `banner: None`, so the push leg sends content-available
    /// wakes only — the property Apple's `silent:` flag guarantees (25 re-shares must not fire 25
    /// alerts on every member's phone for content nobody wrote) holds here the same way.
    ///
    /// THE OLD BLOB IS DELIBERATELY NOT DELETED. A member who is offline right now still holds the
    /// PRE-edit post naming the old ref; if they ask for it while our copy is gone they get a
    /// permanently broken post. It is retired the ordinary way, by the orphan sweep, which already
    /// skips anything a live event references and gives everything a grace window.
    pub fn reoptimize_apply(
        self: &Arc<Self>,
        circle_id: String,
        event_id: String,
        media: Vec<String>,
    ) -> bool {
        // Re-read the target NOW rather than trusting what the caller scanned minutes ago: a post
        // edited or retracted in the meantime must be edited against its CURRENT state, or this
        // silently reverts the user's own change.
        let Some(current) = self
            .reoptimize_targets()
            .into_iter()
            .find(|t| t.circle_id == circle_id && t.event_id == event_id)
        else {
            return false;
        };
        // The array handed back must be the CURRENT one with only real media refs substituted:
        // same length, same order, and every synthetic entry (a `geo:` location pin, which rides in
        // the media array and carries no bytes) byte-identical. Anything else means either the feed
        // moved under us or the caller built an array the user never composed — and this writes a
        // SIGNED event, so it verifies rather than trusts.
        if media.len() != current.media.len() {
            return false;
        }
        for (was, now) in current.media.iter().zip(media.iter()) {
            if LocalMedia::is_synthetic(was) && was != now {
                log::error!("reoptimize: refusing to rewrite a synthetic ref ({was} -> {now})");
                return false;
            }
        }
        match self.social.edit(
            circle_id.clone(),
            event_id,
            current.body.clone(),
            media.clone(),
            current.music.clone(),
            current.mute_video,
            now_ms(),
        ) {
            Ok(env) => {
                self.after_author(&circle_id, &env, None, None);
                let me = self.clone();
                tauri::async_runtime::spawn(async move {
                    for r in media {
                        me.upload_media(&circle_id, &r).await;
                    }
                });
                true
            }
            Err(e) => {
                log::error!("reoptimize edit failed: {e}");
                false
            }
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
            } else if LocalMedia::is_file_ref(r) {
                "file"
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
            let mut payload = my_hex.clone().into_bytes();
            payload.extend_from_slice(reference.as_bytes());
            let ids: Vec<String> = me.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
            me.ask_for_media(&reference, &my_hex, payload, ids); // resumes from a partial when we have one
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

    /// `retention_secs` = disappearing messages. Desktop passed a hard-coded `None` here, so a
    /// desktop user could not set one at all — the control simply did not exist on this platform,
    /// while Apple and Android both had it. (A disappearing post authored elsewhere always expired
    /// correctly here; it is only authoring that was missing.)
    pub fn post(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>, mute_video: bool, retention_secs: Option<u64>) {
        if body.trim().is_empty() && media.is_empty() && music.is_none() {
            return;
        }
        let banner = {
            let refs: Vec<&str> = media.iter().map(|s| s.as_str()).collect();
            haven_p2p::pushbanner::for_post(&circle_id, &self.circle_name(&circle_id), &body, &refs, false)
        };
        // Hoist the timestamp so the engine-derived id of THIS post can be read back (ids are
        // content-addressed at author time) — the sealed banner's `p` tag. Apple FeedView parity.
        let ts = now_ms();
        match self.social.post(circle_id.clone(), body, media.clone(), music, retention_secs, false, mute_video, ts) {
            Ok(env) => {
                let post_id = self.social.last_authored_event_id(circle_id.clone(), ts);
                self.after_author(&circle_id, &env, Some(banner), post_id);
                self.upload_authored_media(circle_id, media);
            }
            Err(e) => log::error!("post failed: {e}"),
        }
    }

    /// Author a post that came from an ARCHIVE IMPORT (Instagram et al) — silent by construction.
    ///
    /// An import republishes a whole back-catalogue at once: a 900-post Instagram archive would fire
    /// 900 lock-screen banners at every member. That is the one case where the content genuinely is
    /// not news — the owner is backfilling history that is often years old, not saying something just
    /// happened. So this passes NO banner, which `after_author` already turns into a bannerless
    /// content-available wake (the same property the 25-re-shares note above depends on): the event
    /// still delivers, still syncs, still reaches offline members through the mailbox.
    ///
    /// Deliberately a SEPARATE entry point rather than a `silent` flag on `post`: silence is a
    /// property of importing, not a mode the user can leave switched on, so no normal authoring path
    /// can reach it. Apple `FeedStore.postImported` / Android `HavenNet.postImported` parity.
    ///
    /// `created_at` is the ORIGINAL capture time in ms (Instagram exports SECONDS — multiply). The
    /// feed orders by it, so backdating is what slots an imported archive into history instead of
    /// heaping it at today's date.
    pub fn post_imported(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>,
                         music: Option<TrackRefFfi>, story: bool, created_at: u64) {
        if body.trim().is_empty() && media.is_empty() && music.is_none() {
            return;
        }
        match self.social.post(circle_id.clone(), body, media.clone(), music, None, story, false, created_at) {
            Ok(env) => {
                self.after_author_bulk(&circle_id, &env, None, None); // silent wake, coalesced write
                self.upload_authored_media(circle_id, media);
            }
            Err(e) => log::error!("imported post failed: {e}"),
        }
    }

    /// The UI always passes `DEFAULT_CIRCLE` (stories live in the personal circle); the circle is
    /// a parameter so the qa-cmd driver can honor an explicit `circle_id` (docs/QA.md).
    pub fn post_story(self: &Arc<Self>, circle_id: String, body: String, media: Option<String>, music: Option<TrackRefFfi>) {
        if body.trim().is_empty() && media.is_none() && music.is_none() {
            return;
        }
        let media_vec: Vec<String> = media.iter().cloned().collect();
        let banner = {
            let refs: Vec<&str> = media_vec.iter().map(|s| s.as_str()).collect();
            haven_p2p::pushbanner::for_post(&circle_id, &self.circle_name(&circle_id), &body, &refs, true)
        };
        let ts = now_ms(); // hoisted for the `p` read-back (see `post`)
        match self.social.post(circle_id.clone(), body, media_vec.clone(), music, Some(86_400), true, false, ts) {
            Ok(env) => {
                let post_id = self.social.last_authored_event_id(circle_id.clone(), ts);
                self.after_author(&circle_id, &env, Some(banner), post_id);
                if media.is_some() {
                    self.upload_authored_media(circle_id, media_vec);
                }
            }
            Err(e) => log::error!("post_story failed: {e}"),
        }
    }

    pub fn comment(self: &Arc<Self>, circle_id: String, target: String, body: String) {
        if body.trim().is_empty() {
            return;
        }
        let banner = haven_p2p::pushbanner::for_comment(&body, &circle_id, &self.circle_name(&circle_id));
        if let Ok(env) = self.social.comment(circle_id.clone(), target.clone(), body, vec![], now_ms()) {
            // `p` = the PARENT post, so the tap opens the thread the comment landed on.
            self.after_author(&circle_id, &env, Some(banner), Some(target));
        }
    }

    pub fn react(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        let banner = haven_p2p::pushbanner::for_reaction(&emoji, &circle_id);
        if let Ok(env) = self.social.react(circle_id.clone(), target.clone(), emoji, now_ms()) {
            self.after_author(&circle_id, &env, Some(banner), Some(target)); // `p` = the reacted post
        }
    }

    pub fn unreact(self: &Arc<Self>, circle_id: String, target: String, emoji: String) {
        if let Ok(env) = self.social.unreact(circle_id.clone(), target, emoji, now_ms()) {
            self.after_author(&circle_id, &env, None, None); // taking a reaction back is not news
        }
    }

    /// Edit your own post, comment or message.
    ///
    /// An Edit carries a FULL media array and the reducer REPLACES with it (`EventKind::Edit` in
    /// haven-p2p `social.rs` — `it.media = media.clone()`, pinned by tests there). It is not a patch.
    /// This used to pass `vec![], None` unconditionally, and BOTH UI call sites used it, so fixing a
    /// typo in a caption silently detached every photo and song from that item for the whole circle.
    ///
    /// Two belts, because this failure is silent and permanent from the member's side:
    ///  - callers pass the item's current attachments explicitly (`Some(...)`), which is what the
    ///    feed and DM editors now do; and
    ///  - `None` does NOT mean "strip" — it means "look them up", so a future caller that forgets
    ///    the argument entirely still cannot destroy anyone's media.
    pub fn edit_post(
        self: &Arc<Self>,
        circle_id: String,
        target: String,
        body: String,
        media: Option<Vec<String>>,
        music: Option<TrackRefFfi>,
        // None = keep whatever the post already had. Passing an explicit media array used to force
        // this to false, so editing a caption silently un-muted the post's video for the whole
        // circle — a setting the author chose, changed by an edit that never mentioned it.
        mute_video: Option<bool>,
    ) -> Result<(), String> {
        // `reoptimize_targets` lists every one of my items that carries media (it is NOT filtered to
        // oversized ones — that happens later), so "absent" genuinely means "carries none".
        let looked_up = self
            .reoptimize_targets()
            .into_iter()
            .find(|t| t.circle_id == circle_id && t.event_id == target);
        let (media, music, mute_video) = match (media, looked_up) {
            (Some(m), found) => {
                let carried = found.as_ref().map(|t| t.mute_video).unwrap_or(false);
                (m, music.or_else(|| found.and_then(|t| t.music)), mute_video.unwrap_or(carried))
            }
            (None, Some(t)) => {
                let carried = t.mute_video;
                (t.media, t.music, mute_video.unwrap_or(carried))
            }
            (None, None) => (vec![], None, mute_video.unwrap_or(false)),
        };
        match self.social.edit(circle_id.clone(), target, body, media, music, mute_video, now_ms()) {
            Ok(env) => {
                self.after_author(&circle_id, &env, None, None); // edits keep their place — no banner
                Ok(())
            }
            // Surfaced rather than swallowed. An edit that fails looked EXACTLY like one that
            // worked — the dialog closed either way — so a save that did nothing was indis-
            // tinguishable from a save that did. The caller toasts this.
            Err(e) => {
                log::error!("edit_post failed: {e}");
                Err(format!("{e}"))
            }
        }
    }

    /// Someone asked for the page of MY history older than their cursor. Answer with ordinary EVENT
    /// frames — `sync_envelopes_page` re-seals only what I authored, so authorship is unchanged.
    fn handle_history_request(self: &Arc<Self>, body: &[u8]) {
        let Some((requester, before_ms, cid)) = wire::parse_history_req(body) else { return };
        // Members only. The reply is sealed to the circle epoch regardless, so a stranger could not
        // open it — but there is no reason to spend the sealing on them, and an unbounded
        // stranger-triggered re-seal is a free CPU drain.
        if !self.contacts().iter().any(|c| c.id_hex.eq_ignore_ascii_case(&requester)) {
            return;
        }
        let page = self.social.sync_envelopes_page(cid.clone(), before_ms, wire::HISTORY_PAGE);
        log::info!("history: serving {} envelopes before {} in {}", page.len(), before_ms, cid);
        for env in page {
            self.send_frame(wire::EVENT, &wire::event_payload(&cid, &env), &requester);
        }
    }

    /// Ask this circle's members for the page of history older than the oldest post we hold.
    ///
    /// Idempotent per cursor: asking again only happens once an older page has actually arrived and
    /// moved it. If nobody answers, the periodic full re-send still reconciles.
    pub fn request_older_history(self: &Arc<Self>, circle_id: String, oldest_created_at: u64) {
        if oldest_created_at == 0 {
            return;
        }
        {
            let mut asked = self.history_asked_before.lock().unwrap();
            if asked.get(&circle_id) == Some(&oldest_created_at) {
                return;
            }
            asked.insert(circle_id.clone(), oldest_created_at);
        }
        let me = self.social.my_node_hex();
        let payload = wire::history_req_payload(&me, oldest_created_at, &circle_id);
        for c in self.contacts() {
            self.send_frame(wire::HISTORY_REQ, &payload, &c.id_hex);
        }
        log::info!("history: asked for the page before {} in {}", oldest_created_at, circle_id);
    }

    /// Withdraw posts this device published more than once, keeping the oldest of each — the repair
    /// for an archive imported twice. Parity with iOS `sweepDuplicateImports` and Android
    /// `sweepDuplicateImportsOnce`, and it MUST agree with them: all three sweep the same circle, so
    /// a rule that differs would have one device withdrawing posts another keeps.
    ///
    /// The key is what an import cannot change — the backdated capture time, the caption, and how
    /// many items the post carries. Deliberately NOT the media refs: the importer re-encodes what it
    /// stages and re-encoding is not reproducible, so the same photo gets a different content hash on
    /// the second run. That is what made the first version of this find nothing at all.
    ///
    /// Desktop has no perceptual hash yet, so it uses the caption+count fallback that the other two
    /// use when a picture cannot be read — strictly more conservative: it merges less, never more.
    pub fn sweep_duplicate_imports(self: &Arc<Self>, circle_id: &str) -> usize {
        let mut mine: Vec<FeedItemFfi> = self
            .feed(circle_id)
            .into_iter()
            .filter(|i| i.is_me && !i.unsent && !i.story)
            .collect();
        mine.sort_by_key(|i| i.created_at);
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut doomed: Vec<String> = vec![];
        for item in &mine {
            let count = haven_p2p::mediavariants::display_refs(&item.media).len();
            if count == 0 {
                continue; // text-only: the key is weakest exactly where a repeat may be deliberate
            }
            let caption = item.body.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase();
            let signature = format!("{}|{}|{}", item.created_at, count, caption);
            if !seen.insert(signature) {
                doomed.push(item.id.clone());
            }
        }
        if doomed.is_empty() {
            log::info!("dedupe: nothing duplicated across {} of my posts", mine.len());
            return 0;
        }
        log::info!("dedupe: withdrawing {} duplicate posts of {}", doomed.len(), mine.len());
        for id in &doomed {
            self.clone().unsend_post(circle_id.to_string(), id.clone());
        }
        doomed.len()
    }

    pub fn unsend_post(self: &Arc<Self>, circle_id: String, target: String) {
        if let Ok(env) = self.social.unsend(circle_id.clone(), target, now_ms()) {
            self.after_author(&circle_id, &env, None, None);
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
                self.after_author(&circle_id, &env, None, None);
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
    ///
    /// `banner` is the lock-screen copy each recipient's device shows after decrypting the sealed
    /// notification — decided HERE at send time, sealed+SIGNED per recipient, forwarded blind by
    /// the push Worker (it never sees plaintext). `None` is SILENT: the event still delivers and
    /// syncs, but nobody's phone banners (re-optimize republishes / edits / unsends / un-reacts —
    /// content nobody just wrote). Mirrors iOS `broadcastEvent(_:banner:silent:)`.
    ///
    /// `post_id` is the banner's `p` deep-link tag — the authored post's engine-derived id (read
    /// back via `last_authored_event_id`, Apple parity) or the reaction/comment's PARENT post — so
    /// the recipient's tap opens THAT item. Best-effort: `None` keeps the legacy circle route.
    /// `bulk` = one of MANY posts authored back to back (an archive import).
    ///
    /// Two things that are right for one post are ruinous three hundred times over:
    ///
    ///   `persist()` serialises the ENTIRE engine state and writes it. Per post that is O(n^2)
    ///   across an import — by the last one it re-writes all 372 posts' worth of state, having
    ///   already done so 371 times. That is the work that made the window beachball.
    ///
    ///   `emit_changed()` tells the webview to rebuild the feed. Per post that is 372 rebuilds
    ///   racing the user's own scrolling and clicking.
    ///
    /// Bulk coalesces the write and leaves the UI nudge to the importer, which throttles it. Safe
    /// because the importer checkpoints separately: a crash between writes costs at most the last
    /// couple of seconds, and re-authored events dedupe by id.
    fn after_author(
        self: &Arc<Self>,
        circle_id: &str,
        env: &[u8],
        banner: Option<haven_p2p::pushbanner::BannerCopy>,
        post_id: Option<String>,
    ) {
        self.after_author_inner(circle_id, env, banner, post_id, false)
    }

    fn after_author_bulk(
        self: &Arc<Self>,
        circle_id: &str,
        env: &[u8],
        banner: Option<haven_p2p::pushbanner::BannerCopy>,
        post_id: Option<String>,
    ) {
        self.after_author_inner(circle_id, env, banner, post_id, true)
    }

    fn after_author_inner(
        self: &Arc<Self>,
        circle_id: &str,
        env: &[u8],
        banner: Option<haven_p2p::pushbanner::BannerCopy>,
        post_id: Option<String>,
        bulk: bool,
    ) {
        self.bump_activity(); // I just posted/messaged → keep sync tight
        if bulk {
            self.persist_coalesced();
        } else {
            self.persist();
            self.emit_changed();
        }
        let payload = wire::event_payload(circle_id, env);
        let members = self.social.contact_node_ids(circle_id.to_string());
        for id_hex in &members {
            self.send_frame(wire::EVENT, &payload, id_hex);
        }
        // Push leg (the desktop hole until now): a blind wake per member so their PHONES banner /
        // fetch even when no live path is up, plus a silent syncSelf wake so my own sleeping
        // devices ingest the inline event without a mailbox round-trip.
        let event_b64 = base64::engine::general_purpose::STANDARD.encode(env);
        self.push_wake(&self.node_id_hex(), None, Some(event_b64.clone()), true);
        let notif_json: Option<Vec<u8>> = banner.map(|b| {
            let my_name = self.prefs.lock().unwrap().profile.name.clone();
            let title = if my_name.is_empty() { "Someone".to_string() } else { my_name };
            // `{t,b,bp,c,k,e?,p?}` — the cross-platform sealed-banner wire (Apple PushBanner.jsonObject).
            let mut o = serde_json::json!({
                "t": title, "b": b.body, "bp": b.private_body, "c": circle_id, "k": b.kind,
            });
            if let Some(e) = &b.emoji {
                o["e"] = e.clone().into();
            }
            if let Some(p) = post_id.as_ref().filter(|p| !p.is_empty()) {
                o["p"] = p.clone().into();
            }
            serde_json::to_vec(&o).unwrap_or_default()
        });
        for member in &members {
            let sealed = notif_json.as_ref().filter(|j| !j.is_empty()).and_then(|j| {
                self.social.seal_signed_notification(member.clone(), j.clone()).ok()
            });
            let silent = sealed.is_none();
            self.push_wake(
                member,
                sealed.map(|sd| base64::engine::general_purpose::STANDARD.encode(sd)),
                Some(event_b64.clone()),
                silent,
            );
        }
        // Hand it to MY other devices too while they're online. contact_node_ids deliberately
        // excludes us, so before this a post authored here only reached my other devices via their
        // mailbox poll — the send-path half of the same cross-device gap the receive path had.
        // Strictly an optimisation: the upload_event below is unconditional and stays what a
        // sleeping / not-yet-linked device gets. iOS/Android parity.
        self.live_deliver_to_my_devices(wire::EVENT, &payload);
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

    /// Materialize a `dm:` thread this device doesn't hold yet when a LIVE-delivered event names
    /// it (see `handle_event`). The id is deterministic and names its participants, so this only
    /// fires when it names MY account and every OTHER participant is an existing CONTACT — the
    /// own-device echo and a friend's first DM both qualify; a stranger's id never does. The
    /// envelope still has to open/verify inside `receive`, so nothing is admitted that a (much
    /// slower) self-sync apply wouldn't have admitted anyway. Deliberately NO hello: the thread
    /// demonstrably exists on the sender's side already — this only creates the local circle,
    /// wires it to the active relays so the next mailbox poll covers it, and lets my own devices
    /// learn it over self-sync.
    fn adopt_unknown_dm_circle(self: &Arc<Self>, circle_id: &str) {
        if !circle_id.starts_with("dm:") {
            return;
        }
        if self.social.circles().iter().any(|c| c.id == circle_id) {
            return;
        }
        let me = self.node_id_hex().to_lowercase();
        let parts: Vec<String> =
            circle_id.trim_start_matches("dm:").split('-').map(str::to_lowercase).collect();
        if parts.len() < 2
            || parts.iter().any(|p| p.len() != 64 || !p.bytes().all(|b| b.is_ascii_hexdigit()))
            || !parts.contains(&me)
        {
            return;
        }
        let contacts = self.contacts();
        let mut members: Vec<(String, String)> = Vec::new(); // (hex, display name)
        for p in parts.iter().filter(|p| **p != me) {
            match contacts.iter().find(|c| c.id_hex.eq_ignore_ascii_case(p)) {
                Some(c) => members.push((p.clone(), c.name.clone())),
                None => return, // a non-contact participant → not ours to open
            }
        }
        if members.is_empty() {
            return;
        }
        let title = members.iter().map(|(_, n)| n.clone()).collect::<Vec<_>>().join(", ");
        self.social.create_circle(circle_id.to_string(), title);
        for (hex, _) in &members {
            let _ = self.social.add_existing_to_circle(circle_id.to_string(), hex.clone());
        }
        self.pin_dm_authority(circle_id);
        {
            let mut p = self.prefs.lock().unwrap();
            let actives = p.all_active_relay_hexes();
            let list = p.relays.entry(circle_id.to_string()).or_default();
            for hex in actives {
                if !list.contains(&hex) {
                    list.push(hex);
                }
            }
            let _ = p.save(&self.paths);
        }
        self.persist();
        self.nudge_self_sync(); // my other devices learn the thread on the next pass
        log::info!(
            "adopted live-delivered DM thread {}… ({} member(s))",
            &circle_id.chars().take(20).collect::<String>(),
            members.len()
        );
    }

    pub fn start_dm(self: &Arc<Self>, contact_id_hex: String, contact_name: String) -> String {
        let id = self.dm_circle_id(&contact_id_hex);
        self.social.create_circle(id.clone(), contact_name);
        let _ = self.social.add_existing_to_circle(id.clone(), contact_id_hex.clone());
        self.pin_dm_authority(&id); // §5 live-lane + §2 deterministic creator pin
        self.persist();
        self.nudge_self_sync(); // the new thread's `circle:` record rides a prompt pass
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
        self.nudge_self_sync(); // the new thread's `circle:` record rides a prompt pass
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
    pub fn send_dm(self: &Arc<Self>, circle_id: String, body: String, media: Vec<String>, music: Option<TrackRefFfi>, retention_secs: Option<u64>) {
        // A song alone is a valid message — mirrors `post`'s guard.
        if body.trim().is_empty() && media.is_empty() && music.is_none() {
            return;
        }
        let banner = {
            let refs: Vec<&str> = media.iter().map(|s| s.as_str()).collect();
            haven_p2p::pushbanner::for_post(&circle_id, &self.circle_name(&circle_id), &body, &refs, false)
        };
        let ts = now_ms(); // hoisted for the `p` read-back (see `post`)
        if let Ok(env) = self.social.post(circle_id.clone(), body, media.clone(), music, retention_secs, false, false, ts) {
            let post_id = self.social.last_authored_event_id(circle_id.clone(), ts);
            self.after_author(&circle_id, &env, Some(banner), post_id);
            self.upload_authored_media(circle_id, media);
        }
    }

    /// DM a post's author about that post, from the post's ⋯ menu. Returns the DM circle id (`None`
    /// when the author isn't a contact — you can't DM someone you don't hold).
    ///
    /// Carries the post's MEDIA and not its body: echoing someone's own words back at them reads as
    /// a quote they didn't write, while the media is the unambiguous "this post".
    ///
    /// Media can't simply be forwarded by reference: every blob is sealed under the circle it was
    /// posted to, so a ref carried into a DM would be undecryptable there. It's re-sealed under the
    /// DM's key, off the caller's thread — a blob is decrypted and re-encrypted whole, which is not
    /// an amount of work to do on the UI's round trip for a video.
    /// Open (or reuse) the DM with a post's author and return the thread id plus an UNSENT draft
    /// referencing the post.
    ///
    /// It used to SEND the post's media into the new conversation immediately — publishing something
    /// the user had not written yet, and re-sealing whole videos into the DM circle before they had
    /// decided to send anything at all. Now it sends nothing: the caller opens the thread with the
    /// draft waiting in the composer, so the message is still the user's to write.
    ///
    /// The reference is the post's LINK, not its media. The link opens the real post — with its
    /// media — for anyone already in the circle, and costs nothing to stage.
    pub fn message_author(
        self: &Arc<Self>,
        author_short: String,
        circle_id: String,
        post_id: String,
    ) -> Option<MessageAuthorTarget> {
        let (hex, name) = {
            let p = self.prefs.lock().unwrap();
            let c = p.contacts.iter().find(|c| c.id_hex.starts_with(&author_short))?;
            (c.id_hex.clone(), c.name.clone())
        };
        let dm = self.start_dm(hex, name.clone());
        Some(MessageAuthorTarget { dm, name, draft: wire::post_url(&circle_id, &post_id).unwrap_or_default() })
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
        {
            let mut p = self.prefs.lock().unwrap();
            if mark <= p.dm_last_read.get(&circle_id).copied().unwrap_or(0) {
                return;
            }
            p.dm_last_read.insert(circle_id, mark);
            let _ = p.save(&self.paths);
        }
        self.nudge_self_sync(); // clear the badge on my other devices promptly
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
            self.nudge_self_sync(); // the new contact (+ lifted tombstone) rides a prompt pass
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
        self.nudge_self_sync(); // block + contact tombstone reach my other devices promptly
        self.emit_changed();
    }

    pub fn unblock(self: &Arc<Self>, id_hex: String) {
        {
            let mut p = self.prefs.lock().unwrap();
            p.blocked.retain(|b| *b != id_hex);
            let _ = p.save(&self.paths);
        }
        self.nudge_self_sync();
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
    /// A circle's display name (falls back to the generic copy the banners use).
    fn circle_name(&self, circle_id: &str) -> String {
        self.social
            .circles()
            .into_iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.name)
            .unwrap_or_else(|| "your circle".into())
    }

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

    /// Content-addressed store-and-forward slot for a HELLO under a circle mailbox
    /// (membership-gated like events): `haven/mailbox/<circle>/__hello__/<toAcct>/<fromAcct>/<sha256>`.
    /// Both id slots are ACCOUNT hexes — a device id in the recipient slot rots the moment the
    /// peer rotates or relinks (the matrix "invite never arrived" shape: the hello sat in a slot
    /// none of their current ids match), while the account slot is claimed by every device they
    /// own. iOS `helloMailboxKey` parity.
    fn hello_mailbox_key(circle_id: &str, to_hex: &str, from_hex: &str, body: &[u8]) -> String {
        let mut h = Sha256::new();
        h.update(body);
        let digest: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        format!(
            "haven/mailbox/{circle_id}/__hello__/{}/{}/{digest}",
            to_hex.to_lowercase(),
            from_hex.to_lowercase()
        )
    }

    /// Store-and-forward leg of [`Self::send_hello`]: park the hello on every relay serving the
    /// circle, for when no direct iroh path to the peer ever comes up (matrix / cross-NAT — the
    /// exact case where the invite otherwise silently vanishes). Deduped per (relay, key), NOT
    /// per key alone, so a relay learned AFTER the first offer still receives it on a later greet
    /// cycle instead of being starved by an "any relay landed" latch. Only a landed PUT marks the
    /// pair, so a failed upload retries next tick.
    async fn offer_hello_mailbox(self: &Arc<Self>, circle_id: &str, to_hex: &str, hello: &[u8]) {
        let key = Self::hello_mailbox_key(circle_id, to_hex, &self.node_id_hex(), hello);
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        for node_hex in self.relays_for(circle_id) {
            // The S3 mailbox loop feeds receive() only — a hello parked there would never route.
            if node_hex.starts_with("s3:") {
                continue;
            }
            let offered = format!("{node_hex}|{key}");
            if self.hello_offered.lock().unwrap().contains(&offered) {
                continue;
            }
            // Our OWN hosted relay: store directly into the local mailbox (no iroh self-dial).
            if hosted.as_deref() == Some(node_hex.as_str()) {
                let ok = match self.relay_host.lock().unwrap().as_ref() {
                    Some(h) => h.local_put(key.clone(), hello.to_vec()),
                    None => false,
                };
                if ok {
                    self.hello_offered.lock().unwrap().insert(offered);
                }
                continue;
            }
            // Plain-HTTP first (an HTTP-mailbox-only host never iroh-dials), then the warm iroh
            // client — the same ladder the mailbox poll runs, in the same order.
            let mut landed = false;
            if let Some((bases, token)) = self.relay_http_reachable(&node_hex) {
                for base in &bases {
                    if self.http_url_bad(base) {
                        continue;
                    }
                    match self.http_put(base, &token, &key, hello.to_vec()).await {
                        Ok(()) => {
                            self.mark_relay_ok(&node_hex);
                            landed = true;
                            break;
                        }
                        Err(RelayErr::Forbidden) => {
                            self.note_refused(&node_hex, "hello put");
                            break; // same store behind every URL — the refusal stands
                        }
                        Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                    }
                }
            }
            if !landed {
                if let Some(client) = self.relay_client_for(&node_hex).await {
                    match client.put(key.clone(), hello.to_vec()).await {
                        Ok(()) => {
                            self.mark_relay_ok(&node_hex);
                            landed = true;
                        }
                        Err(e) => {
                            log::debug!("hello put failed ({node_hex}): {e}");
                            self.relay_failed(&node_hex).await;
                        }
                    }
                }
            }
            if landed {
                log::info!(
                    "hello offered to={} relay={}",
                    &to_hex.chars().take(8).collect::<String>(),
                    &node_hex.chars().take(8).collect::<String>()
                );
                self.hello_offered.lock().unwrap().insert(offered);
            }
        }
    }

    /// Send our Hello + back-fill this circle's events to one node.
    fn send_hello(self: &Arc<Self>, circle_id: &str, to_node_hex: &str) {
        let Some(hello) = self.hello_payload(circle_id) else { return };
        self.send_frame(wire::HELLO, &hello, to_node_hex);
        // Park the same hello on the circle's relays for a peer no direct path reaches. Callers
        // hand this an ACCOUNT id (the transport expansion to device ids happens in send_frame),
        // which is exactly what the recipient slot must carry.
        {
            let me = self.clone();
            let cid = circle_id.to_string();
            let to = to_node_hex.to_string();
            let hello = hello.clone();
            tauri::async_runtime::spawn(async move {
                me.offer_hello_mailbox(&cid, &to, &hello).await;
            });
        }
        // A PAGE, not the whole history — parity with iOS/Android "lazy history".
        //
        // This is the moment someone is added, and it used to re-seal and ship every event ever
        // authored to the circle: real cryptography per event here, an unseal per event there, and
        // the media backlog dragged along behind it. They get the newest page now and ask for older
        // ones (wire::HISTORY_REQ) as they scroll. DMs are read from the beginning and small, so they
        // keep the full send.
        let first_page = if circle_id.starts_with("dm:") {
            self.social.sync_envelopes(circle_id.to_string())
        } else {
            self.social.sync_envelopes_page(circle_id.to_string(), 0, wire::HISTORY_PAGE)
        };
        for env in first_page {
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
        // Contacts come from prefs (this device's own add-contact flow) UNION every circle's
        // members. A LINKED DEVICE never runs add-contact — it adopts the account seed and learns
        // circles over self-sync — so prefs.contacts is EMPTY on it (measured: 0 on the QA desktop).
        // Driving roster announce/pull from prefs alone therefore did nothing at all there: it
        // never announced its roster and, worse, never PULLED the peer's. With the peer's devices
        // unresolvable, receive_key_commit can never authorize their commit, so every envelope they
        // author parks in pending_epoch forever while our own posts keep arriving over self-sync.
        // That is exactly the "desktop gets my content but never my friend's" blackout.
        let ids: Vec<String> = {
            let mut out: Vec<String> = self
                .prefs
                .lock()
                .unwrap()
                .contacts
                .iter()
                .map(|c| c.id_hex.clone())
                .collect();
            let me = self.social.my_node_hex().to_lowercase();
            for c in self.social.circles() {
                for m in self.social.contact_node_ids(c.id.clone()) {
                    if m.to_lowercase() != me {
                        out.push(m);
                    }
                }
            }
            out.iter_mut().for_each(|h| *h = h.to_lowercase());
            out.sort();
            out.dedup();
            out
        };
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
        // Diagnostic: distinguishes "we know nobody" from "everyone already resolves". Without it,
        // a silent sync_with_contacts is ambiguous — and that ambiguity is what made the desktop
        // blackout so hard to place (zero devroster lines could mean either).
        log::info!(
            "devroster: contacts={} unresolved-due={} (pull fires only when due>0)",
            ids.len(),
            due.len()
        );
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
        // Own-device catch-up over the INTERNET. The receive-time fan-out in `handle_event` only
        // helps events arriving from NOW ON — a DM already sitting on one device and missing from
        // another stays missing, because handle_event never runs for it again. Desktop has no local
        // proximity transport at all, so without this two of the user's devices on different
        // networks never reconciled and anything that reached only one of them stayed there.
        //
        // BOUNDED, deliberately, and it must stay that way:
        //  - only when I actually HAVE other devices (no targets → no work at all),
        //  - at most OWN_DEVICE_CATCHUP_LIMIT events per circle,
        //  - no more often than every 5 minutes — this RE-SEALS per envelope, so it is real CPU and
        //    must not ride the sync tick,
        //  - single-flight, so a slow pass cannot overlap itself and pile up (the roster-pull
        //    dial-storm shape guarded above),
        //  - batched into ONE task per sweep, not one dial per envelope.
        // Siblings dedupe on receive, so repeating a sweep is harmless.
        const OWN_DEVICE_CATCHUP_LIMIT: u32 = 50;
        let catchup_due = {
            let mut st = self.dyn_state.lock().unwrap();
            let now = now_ms();
            if !st.own_device_catchup_in_flight
                && now.saturating_sub(st.last_own_device_catchup_ms) > 300_000
            {
                st.last_own_device_catchup_ms = now;
                st.own_device_catchup_in_flight = true;
                true
            } else {
                false
            }
        };
        if catchup_due {
            if self.my_other_device_hexes().is_empty() {
                self.dyn_state.lock().unwrap().own_device_catchup_in_flight = false;
            } else {
                let me = self.clone();
                tauri::async_runtime::spawn(async move {
                    for c in me.social.circles() {
                        // ALL authors — the point is my friends' messages that reached one device only.
                        let envs = me
                            .social
                            .export_recent_envelopes(c.id.clone(), OWN_DEVICE_CATCHUP_LIMIT);
                        if !envs.is_empty() {
                            let payloads: Vec<Vec<u8>> =
                                envs.iter().map(|e| wire::event_payload(&c.id, e)).collect();
                            me.live_deliver_many_to_my_devices(wire::EVENT, payloads);
                        }
                    }
                    me.dyn_state.lock().unwrap().own_device_catchup_in_flight = false;
                });
            }
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
        let hints = self.device_hints_for(to_node_hex);
        for h in &hints {
            if !targets.iter().any(|t| t.eq_ignore_ascii_case(h)) {
                targets.push(h.clone());
            }
        }
        // Nothing but the account id, which is an identity and not an address: this peer is
        // unreachable except through a relay we happen to share. Ask the public directory for their
        // devices — the answer lands in the hint store above and the NEXT send can dial it.
        if hints.is_empty() && targets.iter().all(|t| t.eq_ignore_ascii_case(to_node_hex)) {
            self.resolve_missing_device_ids(to_node_hex);
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
        // 33 (resume) sits here with frame 3 rather than in the sealed call-frame set below: it asks
        // for a strict SUBSET of what frame 3 already asks for in the clear, so sealing it would buy
        // nothing while making it fail in exactly the places its own frame-3 fallback still works.
        if matches!(t, wire::MEDIA_REQ | wire::HISTORY_REQ | wire::MEDIA_RESUME_REQ | wire::CALL_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE | wire::GROUP_INVITE | wire::CALL_CAMERA | wire::MEDIA_WANTED | wire::MEDIA_AVAILABLE) {
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
                wire::EVENT => me.handle_event(&body, sender_device.as_deref()),
                wire::RELAY_NODE => me.handle_relay_node(&body).await,
                wire::MEDIA_REQ => me.handle_media_request(&body).await,
                wire::MEDIA_RESUME_REQ => me.handle_media_resume_request(&body).await,
                wire::MEDIA_CHUNK => me.handle_media_chunk(&body),
                // CALL_HANDLED (30) rides the same sealed+signed path: it can silence a ringing
                // device, so it must be no more forgeable than an invite or a hangup.
                wire::CALL_INVITE | wire::GROUP_INVITE | wire::CALL_ACCEPT | wire::CALL_HANGUP
                | wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE | wire::CALL_HANDLED
                | wire::CALL_ENDED_ELSEWHERE
                | wire::CALL_CAMERA => me.handle_call(t, &body),
                // 31/32 are media frames, not call signaling, so they're handled here rather than
                // emitted to the UI — but they borrow the call path's sealing, because one asks an
                // author to spend upload bandwidth and the other triggers a notification and a fetch.
                wire::MEDIA_WANTED => me.handle_media_wanted(&body).await,
                wire::HISTORY_REQ => me.handle_history_request(&body),
                wire::MEDIA_AVAILABLE => me.handle_media_available(&body),
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
        // A hello from an account the ENGINE already lists as a member of one of my circles is not a
        // stranger — we have an established relationship (I invited or approved them, possibly on a
        // LINKED DEVICE before this device's own contact list ever converged). Re-gating them as a
        // stranger strands every hello they send: it becomes a connection request nobody sees, the
        // roster exchange never completes, so `st.device_lists` never learns their devices, so
        // `receive_key_commit` can never authorize their DEVICE-signed commit, and every envelope
        // they author parks in pending_epoch forever. Our own account's content keeps arriving over
        // self-sync, which is what made it look like a mailbox bug for so long.
        //
        // This branch exists on Apple (FeedView.swift:6156) and Android (HavenNet.kt:1453) and was
        // simply missing here — a seed-adopted desktop has an EMPTY prefs.contacts (measured: 0), so
        // the known-contact branch above never fires for it either. Same principle as the
        // device-of-known-account rule above, at account level.
        let engine_knows = !self.prefs.lock().unwrap().is_contact_removed(&id_hex)
            && self.social.circles().iter().any(|c| {
                self.social
                    .contact_node_ids(c.id.clone())
                    .iter()
                    .any(|m| m.eq_ignore_ascii_case(&id_hex))
            });
        if engine_knows {
            let _ = self.social.add_contact_bundle(hello.circle_id.clone(), hello.bundle.clone());
            {
                let mut p = self.prefs.lock().unwrap();
                if !p.contacts.iter().any(|c| c.id_hex == id_hex) {
                    p.contacts.push(Contact {
                        id_hex: id_hex.clone(),
                        name: name.clone(),
                        verify_hex: actual_verify.clone(),
                    });
                    let _ = p.save(&self.paths);
                }
            }
            log::info!(
                "hello from {} is an engine-known circle member — adopted as contact, handshake continues",
                &id_hex.chars().take(8).collect::<String>()
            );
            self.persist();
            return;
        }
        if !hello.circle_id.starts_with("dm:") {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.pending.iter().any(|p| p.id_hex == id_hex) {
                st.pending.push(PendingRequest { id_hex, name, verify_hex: actual_verify, bundle: hello.bundle });
            }
        }
    }

    /// `sender_device` = the authenticated transport id this frame arrived from (None when relayed
    /// or unknown), used to tell a CONTACT's delivery apart from one of my own devices'.
    fn handle_event(self: &Arc<Self>, payload: &[u8], sender_device: Option<&str>) {
        let Some(ev) = wire::parse_event(payload) else { return };
        // Did this come from one of MY devices? Those already have it, and re-sharing it back is how
        // a fan-out becomes a loop.
        let from_own_device = sender_device
            .map(|s| {
                let l = s.to_lowercase();
                l == self.social.my_node_hex().to_lowercase()
                    || self.my_other_device_hexes().iter().any(|d| *d == l)
            })
            .unwrap_or(false);
        // A live-delivered event for a DM thread this device hasn't learned yet was silently
        // DROPPED: `social.receive` returns Ok(false) for an unknown circle id, and a dm:<a>-<b>
        // circle only reached this device via a (minutes-slow) self-sync apply — the "dm echo
        // (own devices) never lands inside the budget" E2E RED. A DM circle id is deterministic
        // and names its participants, so when it names MY account and every other participant is
        // an existing CONTACT (the own-device echo and a friend's first DM both qualify — a
        // stranger's cannot), create the thread first and let the envelope ingest now. The
        // envelope itself still has to open/verify inside `receive`, so this admits no content a
        // later self-sync apply wouldn't have admitted anyway.
        self.adopt_unknown_dm_circle(&ev.circle_id);
        let changed = match self.social.receive(ev.circle_id.clone(), ev.envelope) {
            Ok(c) => c,
            Err(e) => {
                log::warn!(
                    "live event receive FAILED circle={}: {e}",
                    &ev.circle_id.chars().take(12).collect::<String>()
                );
                false
            }
        };
        if changed {
            // FAN OUT to my other devices. A sender dials the device ids ITS copy of my roster
            // resolves — often just one — so a DM delivered straight to one device never reached the
            // others, which were left waiting on a mailbox poll (and got nothing at all if the relay
            // refused them). The send path does this for my OWN posts (after_author); the receive
            // path did not, so anything a CONTACT sent stopped at whichever device they reached.
            //
            // Cannot loop: `receive` returns true only for a genuinely NEW event, so a sibling that
            // already holds it stops here — and a frame that came FROM one of my devices is never
            // re-shared at all. Volume is bounded by real new-event traffic. Deliberately NO push
            // amplification: a push per inbound event would storm during a sync burst.
            if !from_own_device {
                self.live_deliver_to_my_devices(wire::EVENT, payload);
            }
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
        let Some(circle_id) = self.ingest_relay_announce(body) else { return };
        self.refresh_haven_fabric();
        self.backfill_mailbox(&circle_id).await;
        self.poll_mailbox().await;
    }

    /// Decode + apply one sealed frame-19 relay announce (live frame OR a durable `__relay__/`
    /// mailbox blob — the bytes are identical). Pure state: learns/reactivates the relay, records
    /// its HTTP/DERP/TURN interface. Returns the circle id on success so the LIVE path can chase
    /// it with a backfill+poll; the mailbox path must NOT (it is already inside a poll).
    fn ingest_relay_announce(&self, body: &[u8]) -> Option<String> {
        let mut r = wire::Reader::new(body);
        let cid = r.lp()?;
        let circle_id = String::from_utf8_lossy(&cid).into_owned();
        let sealed = r.rest();
        if circle_id.is_empty() || sealed.is_empty() {
            return None;
        }
        let opened = self.social.open_circle_media_sender(circle_id.clone(), sealed)?;
        let announcer_hex = opened.sender_hex.to_lowercase(); // authenticated envelope sender (account id)
        let text = String::from_utf8_lossy(&opened.data).trim().to_string();
        // Extended announce: JSON {node, urls, token, derp, turn, turnUser, turnPass}.
        // Legacy announces are the bare 64-hex id.
        let mut announced_urls: Vec<String> = Vec::new();
        let mut announced_token = String::new();
        let mut announced_added_at: u64 = 0;
        let mut announced_derp: Option<String> = None;
        let mut announced_turn: Vec<String> = Vec::new();
        let mut announced_turn_user = String::new();
        let mut announced_turn_pass = String::new();
        let node_hex = if text.starts_with('{') {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else { return None };
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
            if let Some(d) = v["derp"].as_str() {
                let d = d.trim().trim_end_matches('/');
                if d.starts_with("http") {
                    announced_derp = Some(d.to_string());
                }
            }
            announced_turn = haven_net::parse_turn_urls(&v["turn"]);
            announced_turn_user = v["turnUser"].as_str().unwrap_or_default().to_string();
            announced_turn_pass = v["turnPass"].as_str().unwrap_or_default().to_string();
            // Fallback: reuse media token as TURN password when user/pass omitted.
            if announced_turn_user.is_empty() && !announced_turn.is_empty() {
                announced_turn_user = haven_net::DEFAULT_TURN_USER.to_string();
            }
            if announced_turn_pass.is_empty() && !announced_turn.is_empty() && !announced_token.is_empty()
            {
                announced_turn_pass = announced_token.clone();
            }
            v["node"].as_str().unwrap_or_default().trim().to_lowercase()
        } else {
            text.to_lowercase()
        };
        if node_hex.len() != 64 {
            return None;
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
                    return None;
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
                    return None;
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
            if let Some(derp) = announced_derp {
                p.set_relay_derp(&node_hex, &derp);
            }
            if !announced_turn.is_empty() {
                p.set_relay_turn(
                    &node_hex,
                    announced_turn,
                    &announced_turn_user,
                    &announced_turn_pass,
                );
            }
            let _ = p.save(&self.paths);
            // Clear any stale backoff so a just-reactivated relay is retried immediately.
            if was_suppressed_or_inactive {
                drop(p);
                self.relay_health.lock().unwrap().remove(&node_hex);
            }
        }
        Some(circle_id)
    }

    /// Fetch a relay's SELF-PUBLISHED interface (`haven/relay/__interface__` — its current public
    /// HTTP URLs + token + DERP/TURN, written by the relay process at startup) over the iroh
    /// channel that still works, and adopt it exactly like a frame-19 announce. This is the
    /// self-heal for the failure that stranded media while posts flowed: a CLI relay restart
    /// rotates its free-tunnel URL, every client keeps polling the mailbox over iroh (fine) and
    /// fetching media over a front door that no longer exists (dead) — and the paste-wire flow
    /// only ever ran once at adopt time. After adopting we re-announce, so members with no iroh
    /// reach — including builds older than this one — learn the URL from the mailbox.
    /// iOS `FeedStore.refreshRelayInterfaceIfNeeded` parity.
    fn refresh_relay_interface_if_needed(self: &Arc<Self>, node_hex: &str) {
        let lower = node_hex.to_lowercase();
        // Only when we hold no usable HTTP interface, or every URL we hold is in its bad window.
        if let Some((urls, _)) = self.relay_http_reachable(&lower) {
            if urls.iter().any(|u| !self.http_url_bad(u)) {
                return;
            }
        }
        let now = now_ms();
        {
            let mut m = self.relay_interface_refresh_ms.lock().unwrap();
            if let Some(&last) = m.get(&lower) {
                if now.saturating_sub(last) < 300_000 {
                    return;
                }
            }
            m.insert(lower.clone(), now);
        }
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            // relay_client_for self-guards (own node) and honors the backoff window.
            let Some(client) = me.relay_client_for(&lower).await else { return };
            let Some(data) = client.get(haven_net::blobstore::RELAY_INTERFACE_KEY.to_string()).await
            else {
                return;
            };
            let Ok(v) = serde_json::from_slice::<serde_json::Value>(&data) else { return };
            // A relay may only describe ITSELF — the key is served from its own store, but never
            // adopt a doc whose node field disagrees with who we asked.
            if v["node"].as_str().unwrap_or_default().trim().to_lowercase() != lower {
                return;
            }
            let urls: Vec<String> = v["urls"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|u| u.as_str())
                        .filter(|u| u.starts_with("http"))
                        .map(|u| u.to_string())
                        .collect()
                })
                .unwrap_or_default();
            let token = v["token"].as_str().unwrap_or_default().to_string();
            if urls.is_empty() || token.is_empty() {
                return;
            }
            let mut derp: Option<String> = None;
            if let Some(d) = v["derp"].as_str() {
                let d = d.trim().trim_end_matches('/');
                if d.starts_with("http") {
                    derp = Some(d.to_string());
                }
            }
            let turn = haven_net::parse_turn_urls(&v["turn"]);
            let turn_user = v["turnUser"].as_str().unwrap_or_default().to_string();
            let turn_pass = v["turnPass"].as_str().unwrap_or_default().to_string();
            log::info!(
                "relay interface {}: learned {} url(s) over iroh — adopting + re-announcing",
                &lower.chars().take(10).collect::<String>(),
                urls.len()
            );
            let circles: Vec<String> = {
                let mut p = me.prefs.lock().unwrap();
                p.set_relay_http(&lower, urls.clone(), token);
                if let Some(d) = &derp {
                    p.set_relay_derp(&lower, d);
                }
                if !turn.is_empty() {
                    p.set_relay_turn(&lower, turn, &turn_user, &turn_pass);
                }
                let _ = p.save(&me.paths);
                p.relays
                    .iter()
                    .filter(|(_, list)| list.iter().any(|h| h == &lower))
                    .map(|(cid, _)| cid.clone())
                    .collect()
            };
            for u in &urls {
                me.clear_http_url_bad(u);
            }
            me.refresh_haven_fabric();
            // React like a frame-19 that taught us a public URL: pull what we were missing and
            // push what the circle was missing, then re-announce so everyone else learns it too.
            if !circles.is_empty() {
                for cid in &circles {
                    me.backfill_mailbox(cid).await;
                }
                me.backfill_media_to_relays().await;
                me.dyn_state.lock().unwrap().last_media_backfill_ms = now_ms();
            }
            me.poll_mailbox().await;
            me.reannounce_own_relay();
        });
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

    /// The host's media limits, `(days, bytes)`; `0` on either = no limit for that dimension.
    pub fn relay_media_limits(&self) -> (u32, u64) {
        self.prefs.lock().unwrap().relay_media_limits()
    }

    /// Set the host's media limits. Takes effect when the relay NEXT STARTS — the retention is handed
    /// to the store at attach time, so the UI says so rather than pretending a live change applied.
    pub fn set_relay_media_limits(&self, max_age_days: u32, max_bytes: u64) {
        let mut p = self.prefs.lock().unwrap();
        p.relay_media_max_age_days = Some(max_age_days);
        p.relay_media_max_bytes = Some(max_bytes);
        let _ = p.save(&self.paths);
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
        // attach_with_limits, not attach: plain `attach` runs media UNLIMITED, so hosting meant
        // volunteering the whole disk with no way to say otherwise.
        let (max_age_days, max_bytes) = self.prefs.lock().unwrap().relay_media_limits();
        let handle = RelayServerHandle::attach_with_limits(
            node,
            dir.to_string_lossy().to_string(),
            max_age_days,
            max_bytes,
        );
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
        // A configured public URL wins OUTRIGHT — the LAN address is not appended to it. The operator
        // has said how members reach this box; adding `192.168.x` behind that only gives every remote
        // member something to try and time out on, which is precisely the failure the CLI relay never
        // had: it announces nothing unless told, so callers go straight to the path that works.
        //
        // With no public URL we still announce the LAN address, because a member on the SAME network
        // should use it — that is the fast local path and it genuinely works. Remote members discard it
        // on receipt (`relay_http_reachable` keeps a private address only when we are on that /24), so
        // the useless case is filtered by the side that can actually tell.
        let (mode, configured_public, tunnel_token, auto_tunnel, configured_derp) = {
            let p = self.prefs.lock().unwrap();
            let mode = p.front_door_mode();
            let pub_url = p.relay_public_url.trim();
            let pub_url = if !pub_url.is_empty() {
                Some(pub_url.trim_end_matches('/').to_string())
            } else {
                None
            };
            let tok = p.relay_cf_tunnel_token.trim().to_string();
            let tok = if tok.is_empty() { None } else { Some(tok) };
            let d = p.relay_derp_url.trim().trim_end_matches('/').to_string();
            let derp = if d.is_empty() { None } else { Some(d) };
            (mode, pub_url, tok, p.auto_tunnel(), derp)
        };

        // Start DERP first so the path router can unify media + fabric on one public origin.
        let derp_local = self.spawn_desktop_derp_local().await;

        // Sibling hostname = dedicated derp URL that differs from media public URL.
        let sibling_derp: Option<String> = configured_derp.as_ref().and_then(|d| {
            let is_sibling = configured_public
                .as_ref()
                .map(|m| m != d)
                .unwrap_or(true);
            if is_sibling {
                Some(d.clone())
            } else {
                None
            }
        });
        let mut front_port = port;
        let mut path_routed = false;
        if let Some(dport) = derp_local {
            if sibling_derp.is_none() {
                let rcfg = haven_net::PathRouterConfig {
                    bind: haven_net::DEFAULT_PATH_ROUTER_BIND.into(),
                    media_backend: format!("127.0.0.1:{port}"),
                    derp_backend: format!("127.0.0.1:{dport}"),
                    http_token: token.clone(),
                };
                // Prefer path proxy (one free cloudflared). Retry once on ephemeral bind if :8675 busy.
                for attempt in 1u8..=2 {
                    let bind = if attempt == 1 {
                        haven_net::DEFAULT_PATH_ROUTER_BIND.to_string()
                    } else {
                        "127.0.0.1:0".into()
                    };
                    let mut try_cfg = rcfg.clone();
                    try_cfg.bind = bind;
                    match haven_net::PathRouter::spawn(&try_cfg).await {
                        Ok(Some(router)) => {
                            front_port = router.local_port();
                            path_routed = true;
                            log::info!(
                                "path router on {} — single origin media+DERP (one cloudflared)",
                                router.local_addr
                            );
                            *self.path_router.lock().unwrap() = Some(router);
                            break;
                        }
                        Ok(None) => {}
                        Err(e) => {
                            log::warn!("path router attempt {attempt} failed: {e:#}");
                            if attempt == 1 {
                                tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                            }
                        }
                    }
                }
                if !path_routed {
                    log::warn!(
                        "path proxy unavailable — free auto will use dual trycloudflare \
                         (media + DERP); both URLs are exposed to the UI"
                    );
                }
            }
        }
        *self.path_routed.lock().unwrap() = path_routed;

        let mut urls = Vec::new();
        // Manual = announce-only. Bundled/Auto may spawn cloudflared → path router when unified.
        match Self::start_desktop_front_door(
            front_port,
            mode,
            configured_public.as_deref(),
            tunnel_token.as_deref(),
            auto_tunnel,
        ) {
            Ok(DeskFrontDoor::Spawned(t)) => {
                log::info!(
                    "relay {} tunnel{}: {}",
                    t.kind,
                    if path_routed { " (media+DERP path router)" } else { " (media)" },
                    t.public_url
                );
                urls.push(t.public_url.clone());
                *self.quick_tunnel.lock().unwrap() = Some(t);
            }
            Ok(DeskFrontDoor::AnnounceOnly(u)) => {
                log::info!(
                    "relay manual front door (no cloudflared): {u}{}",
                    if path_routed {
                        format!(" — point proxy at http://127.0.0.1:{front_port}")
                    } else {
                        String::new()
                    }
                );
                urls.push(u);
            }
            Ok(DeskFrontDoor::LanOnly) => {
                if let Some(ip) = Self::primary_lan_ip() {
                    urls.push(format!("http://{ip}:{port}"));
                }
            }
            Err(e) => {
                log::warn!("relay front door unavailable: {e}");
                if let Some(u) = configured_public {
                    if let Ok(n) = haven_net::cfquicktunnel::normalize_public_url(&u) {
                        urls.push(n);
                    } else {
                        urls.push(u);
                    }
                } else if let Some(ip) = Self::primary_lan_ip() {
                    urls.push(format!("http://{ip}:{port}"));
                }
            }
        }
        log::info!("relay http on :{port} front=:{front_port} path_routed={path_routed} urls={urls:?}");

        // Resolve public DERP URL (single-origin shares media URL so call signaling hairpins).
        let derp_url = self
            .finalize_desktop_derp_public(
                path_routed,
                urls.first().cloned(),
                configured_derp,
                sibling_derp,
            )
            .await;

        let turn_info = self.start_desktop_turn(&urls).await;

        // Always record HTTP when we have URLs; DERP can land even on LAN-only media
        // (local DERP still useful, public DERP only if we resolved a URL).
        if urls.is_empty() && derp_url.is_none() && turn_info.is_none() {
            return;
        }
        let mut p = self.prefs.lock().unwrap();
        let mut changed = if !urls.is_empty() {
            p.set_relay_http(node_hex, urls.clone(), token.clone())
        } else {
            false
        };
        if let Some(ref d) = derp_url {
            changed |= p.set_relay_derp(node_hex, d);
        }
        if let Some((ref turn_urls, ref user, ref pass)) = turn_info {
            changed |= p.set_relay_turn(node_hex, turn_urls.clone(), user, pass);
        }
        if changed {
            let _ = p.save(&self.paths);
        }
        drop(p);
        self.refresh_haven_fabric();
        self.write_host_interface_json(
            node_hex,
            &urls,
            &token,
            derp_url.as_deref(),
            turn_info.as_ref(),
        );
        // Free trycloudflare rotates hostname on every restart — burst frame-19 so peers
        // drop the dead URL and learn the new one (parity with Apple RelayHost.reannounceBurst).
        self.reannounce_own_relay();
        let me = Arc::clone(self);
        tauri::async_runtime::spawn(async move {
            for secs in [2u64, 5, 12, 25] {
                tokio::time::sleep(std::time::Duration::from_secs(secs)).await;
                if !me.dyn_state.lock().unwrap().hosting {
                    return;
                }
                me.reannounce_own_relay();
            }
        });
    }

    /// Paste-ready interface blob (CLI parity) so headless / operators can copy media + DERP + TURN.
    fn write_host_interface_json(
        &self,
        node_hex: &str,
        urls: &[String],
        token: &str,
        derp: Option<&str>,
        turn: Option<&(Vec<String>, String, String)>,
    ) {
        let mut interface = serde_json::json!({
            "node": node_hex,
            "urls": urls,
            "token": token,
            "derp": derp.unwrap_or(""),
        });
        if let Some((turn_urls, user, pass)) = turn {
            if !turn_urls.is_empty() {
                interface["turn"] = serde_json::json!(turn_urls);
                interface["turnUser"] = serde_json::json!(user);
                interface["turnPass"] = serde_json::json!(pass);
            }
        }
        let path = self.paths.relay_dir().join("interface.json");
        if let Ok(bytes) = serde_json::to_vec_pretty(&interface) {
            let _ = std::fs::write(&path, bytes);
            log::info!("relay interface written to {}", path.display());
        }
    }

    /// Bind local iroh-relay only; public URL is filled after the front door / path router is up.
    async fn spawn_desktop_derp_local(self: &Arc<Self>) -> Option<u16> {
        let dcfg = haven_net::DerpConfig {
            enabled: true,
            bind: haven_net::DEFAULT_DERP_BIND.into(),
            public_url: String::new(),
        };
        match haven_net::DerpServer::spawn(&dcfg).await {
            Ok(Some(srv)) => {
                let port = srv.local_port();
                log::info!("iroh DERP fabric on {}", srv.local_addr);
                *self.derp_server.lock().unwrap() = Some(srv);
                Some(port)
            }
            Ok(None) => None,
            Err(e) => {
                log::warn!("iroh DERP failed to start: {e:#}");
                None
            }
        }
    }

    /// Set public DERP URL for frame-19: path-routed single origin shares media URL (call hairpin);
    /// sibling hostname uses configured URL; free dual-origin only when path router is off.
    async fn finalize_desktop_derp_public(
        self: &Arc<Self>,
        path_routed: bool,
        media_public: Option<String>,
        configured_derp: Option<String>,
        sibling_derp: Option<String>,
    ) -> Option<String> {
        let mut guard = self.derp_server.lock().unwrap();
        let Some(srv) = guard.as_mut() else {
            return None;
        };
        if let Some(sib) = sibling_derp {
            srv.public_url = sib;
        } else if path_routed {
            if let Some(u) = media_public {
                srv.public_url = u;
            }
        } else if let Some(d) = configured_derp {
            srv.public_url = d;
        } else if let Some(u) = media_public.clone() {
            if !u.contains("trycloudflare") {
                srv.public_url = u;
            }
        }
        if srv.public_url.is_empty() {
            let port = srv.local_port();
            drop(guard);
            match Self::start_desktop_derp_quick_tunnel(port) {
                Ok(t) => {
                    log::info!(
                        "relay dual free tunnels — DERP trycloudflare: {} (media uses separate origin; both shown in UI)",
                        t.public_url
                    );
                    let url = t.public_url.clone();
                    *self.derp_tunnel.lock().unwrap() = Some(t);
                    *self.path_routed.lock().unwrap() = false;
                    if let Some(srv) = self.derp_server.lock().unwrap().as_mut() {
                        srv.public_url = url.clone();
                    }
                    return Some(url);
                }
                Err(e) => {
                    log::warn!("DERP quick tunnel failed: {e:#}");
                    return None;
                }
            }
        }
        let out = if srv.public_url.is_empty() {
            None
        } else {
            Some(srv.public_url.clone())
        };
        if path_routed {
            if let Some(ref u) = out {
                log::info!(
                    "DERP public={u} (single-tunnel fabric — call signaling hairpins over HTTPS /relay)"
                );
            }
        }
        out
    }

    /// Start embedded TURN for WebRTC ICE. Own UDP socket — not a second iroh Endpoint.
    /// Returns `(urls, user, pass)` when running.
    async fn start_desktop_turn(
        self: &Arc<Self>,
        media_urls: &[String],
    ) -> Option<(Vec<String>, String, String)> {
        let secret = {
            let mut p = self.prefs.lock().unwrap();
            if p.relay_turn_token.is_empty() {
                use rand::RngCore;
                let mut bytes = [0u8; 16];
                rand::rngs::OsRng.fill_bytes(&mut bytes);
                p.relay_turn_token = bytes.iter().map(|b| format!("{b:02x}")).collect();
                let _ = p.save(&self.paths);
            }
            p.relay_turn_token.clone()
        };
        let lan = Self::primary_lan_ip();
        let public_ip = lan
            .clone()
            .or_else(|| {
                media_urls
                    .iter()
                    .find_map(|u| haven_net::host_from_http_url(u))
                    .filter(|h| !h.contains("trycloudflare.com"))
            })
            .unwrap_or_else(|| "127.0.0.1".into());
        let public_urls =
            haven_net::suggest_turn_urls(media_urls, lan.as_deref(), 3478);
        let tcfg = haven_net::TurnConfig {
            enabled: true,
            bind: haven_net::DEFAULT_TURN_BIND.into(),
            public_ip,
            secret,
            public_urls,
        };
        match haven_net::TurnServer::spawn(&tcfg).await {
            Ok(Some(srv)) => {
                log::info!(
                    "circle TURN on {} urls={:?}",
                    srv.local_addr,
                    srv.public_urls
                );
                let out = (
                    srv.public_urls.clone(),
                    srv.username.clone(),
                    srv.password.clone(),
                );
                *self.turn_server.lock().unwrap() = Some(srv);
                Some(out)
            }
            Ok(None) => None,
            Err(e) => {
                log::warn!("circle TURN failed to start: {e:#}");
                None
            }
        }
    }

    fn start_desktop_derp_quick_tunnel(
        port: u16,
    ) -> anyhow::Result<haven_net::cfquicktunnel::QuickTunnel> {
        use haven_net::cfquicktunnel::{
            ensure_cloudflared, executable_dir, QuickTunnel, TunnelSpec,
        };
        let local = format!("http://127.0.0.1:{port}");
        let mut search = Vec::new();
        if let Ok(exe) = std::env::current_exe() {
            if let Some(d) = exe.parent() {
                search.push(d.to_path_buf());
            }
        }
        if let Ok(d) = executable_dir() {
            search.push(d);
        }
        let install = search
            .first()
            .cloned()
            .unwrap_or_else(|| std::env::temp_dir().join("haven-cloudflared"));
        let bin = ensure_cloudflared(&search, &install, true)?;
        QuickTunnel::start_spec(&bin, TunnelSpec::Quick { local_http: local })
    }

    /// Locate bundled/PATH cloudflared and apply front-door mode (manual never spawns).
    fn start_desktop_front_door(
        port: u16,
        mode: haven_net::cfquicktunnel::FrontDoorMode,
        public_url: Option<&str>,
        tunnel_token: Option<&str>,
        auto_quick: bool,
    ) -> anyhow::Result<DeskFrontDoor> {
        use haven_net::cfquicktunnel::{
            ensure_cloudflared, executable_dir, resolve_front_door, FrontDoorAction, QuickTunnel,
        };
        let local = format!("http://127.0.0.1:{port}");
        match resolve_front_door(mode, public_url, tunnel_token, auto_quick, &local)? {
            FrontDoorAction::AnnounceOnly { public_url } => {
                Ok(DeskFrontDoor::AnnounceOnly(public_url))
            }
            FrontDoorAction::LanOnly => Ok(DeskFrontDoor::LanOnly),
            FrontDoorAction::Spawn(spec) => {
                let mut search = Vec::new();
                if let Ok(exe) = executable_dir() {
                    search.push(exe.clone());
                    search.push(exe.join("binaries"));
                    search.push(exe.join("../Resources"));
                    search.push(exe.join("../Helpers"));
                }
                if let Ok(res) = std::env::var("TAURI_RESOURCE_DIR") {
                    search.push(std::path::PathBuf::from(res));
                }
                let install = executable_dir()
                    .unwrap_or_else(|_| std::env::temp_dir())
                    .join("haven-cloudflared");
                let bin = ensure_cloudflared(&search, &install, true)?;
                Ok(DeskFrontDoor::Spawned(QuickTunnel::start_spec(&bin, spec)?))
            }
        }
    }

    /// Public HTTPS front door settings (device-local prefs).
    /// Returns `(media_url, tunnel_token, auto_tunnel, front_door, derp_url)`.
    pub fn relay_public_settings(&self) -> (String, String, bool, String, String) {
        let p = self.prefs.lock().unwrap();
        (
            p.relay_public_url.clone(),
            p.relay_cf_tunnel_token.clone(),
            p.auto_tunnel(),
            p.front_door_mode().as_str().to_string(),
            p.relay_derp_url.clone(),
        )
    }

    pub fn set_relay_public_settings(
        self: &Arc<Self>,
        public_url: String,
        tunnel_token: String,
        auto_tunnel: bool,
        front_door: String,
        derp_url: String,
    ) {
        let mut p = self.prefs.lock().unwrap();
        p.relay_public_url = public_url.trim().trim_end_matches('/').to_string();
        p.relay_cf_tunnel_token = tunnel_token.trim().to_string();
        p.relay_auto_tunnel = Some(auto_tunnel);
        let mode = haven_net::cfquicktunnel::FrontDoorMode::parse(&front_door);
        p.relay_front_door = Some(mode.as_str().to_string());
        p.relay_derp_url = derp_url.trim().trim_end_matches('/').to_string();
        let _ = p.save(&self.paths);
    }

    /// A relay's HTTP interface as seen FROM HERE — `None` means "iroh-only", which is the honest
    /// answer rather than a fast path that cannot work.
    ///
    /// PRIVATE addresses are dropped unless we are on that subnet ourselves. A relay hosted inside the
    /// app announces every LAN IPv4 it has, which is right for a member on the same network and
    /// useless to everyone else — a `192.168.4.x` URL cannot be reached from a `10.0.0.x` network,
    /// ever. Those URLs are tried FIRST anyway (HTTP is the preferred media path), so every remote
    /// member burned a connect attempt and a timeout per operation on an address that could never
    /// work, then fell through to iroh in a worse state. In one 20-minute field window every single
    /// media failure was this.
    ///
    /// It is also why the Dockerised NAS relay behaved better than the in-app relays: it announces no
    /// HTTP interface at all, so callers go straight to the path that works. iOS
    /// `RelayMailboxStore.httpInterface` parity.
    fn relay_http_reachable(&self, hex: &str) -> Option<(Vec<String>, String)> {
        let (urls, token) = self.prefs.lock().unwrap().relay_http(hex)?;
        let usable: Vec<String> = urls.into_iter().filter(|u| Self::url_plausibly_reachable(u)).collect();
        if usable.is_empty() {
            return None;
        }
        Some((usable, token))
    }

    /// Is this URL worth trying from where we are? Public hosts always; a private address only when
    /// our own interface sits on the same /24. Unlike Apple/Android (which enumerate every interface)
    /// std gives us only the route-to-internet address, so a machine on several private subnets keeps
    /// just the one — under-claiming, which costs at most an iroh fallback rather than a timeout.
    fn url_plausibly_reachable(url: &str) -> bool {
        let host = match url.split("://").nth(1).and_then(|r| r.split('/').next()) {
            Some(h) => h.rsplit_once(':').map(|(h, _)| h).unwrap_or(h).to_string(),
            None => return false,
        };
        let parts: Vec<u8> = host.split('.').filter_map(|p| p.parse::<u8>().ok()).collect();
        if parts.len() != 4 || host.split('.').count() != 4 {
            return true; // a hostname/domain — assume routable
        }
        let is_private = parts[0] == 10
            || (parts[0] == 172 && (16..=31).contains(&parts[1]))
            || (parts[0] == 192 && parts[1] == 168);
        if !is_private {
            return true;
        }
        match Self::primary_lan_ip() {
            Some(ip) => {
                let ours: Vec<&str> = ip.split('.').take(3).collect();
                let theirs: Vec<String> = parts.iter().take(3).map(|p| p.to_string()).collect();
                ours == theirs
            }
            None => false,
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

    /// The frame-19 announce body for one relay: bare 64-hex, or JSON
    /// `{"node","urls","token","derp","turn","turnUser","turnPass"}` when media/fabric/TURN known.
    fn relay_announce_body(&self, hex: &str) -> Vec<u8> {
        let p = self.prefs.lock().unwrap();
        let added_at = p.relay_entries.get(hex).map(|e| e.added_at_ms).unwrap_or(0);
        let http = p.relay_http(hex);
        let entry = p.relay_entries.get(hex);
        let derp = entry
            .map(|e| e.derp_url.clone())
            .filter(|u| !u.is_empty());
        let turn_urls = entry.map(|e| e.turn_urls.clone()).unwrap_or_default();
        let turn_user = entry.map(|e| e.turn_user.clone()).unwrap_or_default();
        let turn_pass = entry.map(|e| e.turn_pass.clone()).unwrap_or_default();
        drop(p);
        // Always carry the adoption timestamp so receivers can LWW a stale tombstone. Use the JSON form
        // whenever we have HTTP, DERP, TURN, or a non-zero adoption stamp; a legacy receiver ignores
        // JSON it can't read as a bare hex (wrong length), so mixed versions stay compatible.
        if http.is_some() || derp.is_some() || !turn_urls.is_empty() || added_at > 0 {
            let mut obj = serde_json::json!({ "node": hex, "addedAt": added_at });
            if let Some((urls, token)) = http {
                obj["urls"] = serde_json::json!(urls);
                obj["token"] = serde_json::json!(token);
            }
            if let Some(d) = derp {
                obj["derp"] = serde_json::json!(d);
            }
            if !turn_urls.is_empty() {
                obj["turn"] = serde_json::json!(turn_urls);
                if !turn_user.is_empty() {
                    obj["turnUser"] = serde_json::json!(turn_user);
                }
                if !turn_pass.is_empty() {
                    obj["turnPass"] = serde_json::json!(turn_pass);
                }
            }
            if let Ok(json) = serde_json::to_vec(&obj) {
                return json;
            }
        }
        hex.as_bytes().to_vec()
    }

    /// Apply known circle DERP URLs as the process-wide Haven fabric (n0 off when non-empty)
    /// and surface them to the WebView for WebRTC ICE policy.
    ///
    /// Safe anytime (launch, frame-19 learn, adopt, host DERP start). Process policy updates
    /// immediately. When fabric becomes active (or the DERP URL set changes) while a messaging
    /// node is already running, schedules a debounced soft rebind so the next bind uses Haven
    /// RelayMap without requiring a full app restart.
    pub fn refresh_haven_fabric(self: &Arc<Self>) {
        let urls = self.prefs.lock().unwrap().all_derp_urls();
        haven_net::apply_derp_urls(urls.clone());
        let target = if haven_net::haven_fabric_active() {
            haven_net::active_derp_urls()
        } else {
            Vec::new()
        };
        let node_up = self.node.lock().unwrap().is_some();
        let (bound, in_flight) = {
            let st = self.fabric_rebind.lock().unwrap();
            (st.bound_derp_urls.clone(), st.in_flight)
        };
        // Soft-rebind only when we have a non-empty fabric the live node was not bound with.
        // Empty → n0: do not rebind mid-session (disruptive; cold start is fine).
        let need_rebind = node_up && !target.is_empty() && target != bound && !in_flight;
        let rebind_pending = need_rebind || in_flight;
        self.emit_haven_fabric(&urls, rebind_pending);
        if need_rebind {
            self.schedule_fabric_rebind();
        }
    }

    fn emit_haven_fabric(&self, urls: &[String], rebind_pending: bool) {
        let (turn_urls, turn_user, turn_pass) = self.prefs.lock().unwrap().all_turn_ice();
        if let Some(app) = self.app.lock().unwrap().as_ref() {
            let _ = app.emit(
                "haven-fabric",
                serde_json::json!({
                    "derpUrls": urls,
                    "turnUrls": turn_urls,
                    "turnUser": turn_user,
                    "turnPass": turn_pass,
                    "rebindPending": rebind_pending,
                }),
            );
        }
    }

    /// Debounce 2s so flapping frame-19 / multi-relay learn coalesces into one stop+start.
    fn schedule_fabric_rebind(self: &Arc<Self>) {
        let gen = {
            let mut st = self.fabric_rebind.lock().unwrap();
            st.debounce_gen = st.debounce_gen.wrapping_add(1);
            st.debounce_gen
        };
        let eng = Arc::clone(self);
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if eng.fabric_rebind.lock().unwrap().debounce_gen != gen {
                return; // superseded by a newer schedule
            }
            eng.rebind_transport_for_fabric().await;
        });
    }

    /// Stop the messaging node cleanly, re-apply fabric policy, start again with the same device
    /// seed, re-attach relay host if we were hosting, re-authorize membership and re-announce.
    ///
    /// Guarantees: old endpoint is fully shut down before the new spawn (no same-key dual endpoint).
    pub async fn rebind_transport_for_fabric(self: &Arc<Self>) {
        {
            let mut st = self.fabric_rebind.lock().unwrap();
            if st.in_flight {
                return;
            }
            st.in_flight = true;
        }
        let urls = self.prefs.lock().unwrap().all_derp_urls();
        self.emit_haven_fabric(&urls, true);

        let outcome = self.rebind_transport_for_fabric_inner().await;

        let urls_after = self.prefs.lock().unwrap().all_derp_urls();
        match outcome {
            Ok(()) => {
                log::info!(
                    "fabric rebind ok — messaging node on Haven RelayMap ({})",
                    haven_net::active_derp_urls().join(", ")
                );
                self.fabric_rebind.lock().unwrap().in_flight = false;
                self.emit_haven_fabric(&urls_after, false);
                self.emit_changed();
                // Learns that arrived while we were rebound: schedule another pass if the map moved.
                self.refresh_haven_fabric();
            }
            Err(e) => {
                log::error!("fabric rebind failed: {e:#}");
                self.fabric_rebind.lock().unwrap().in_flight = false;
                // Still pending so UI can hint; a later refresh or next launch recovers.
                self.emit_haven_fabric(&urls_after, true);
            }
        }
    }

    async fn rebind_transport_for_fabric_inner(self: &Arc<Self>) -> Result<()> {
        let target = {
            haven_net::apply_derp_urls(self.prefs.lock().unwrap().all_derp_urls());
            if haven_net::haven_fabric_active() {
                haven_net::active_derp_urls()
            } else {
                Vec::new()
            }
        };
        if target.is_empty() {
            return Ok(()); // nothing to rebind onto
        }
        {
            let bound = self.fabric_rebind.lock().unwrap().bound_derp_urls.clone();
            if bound == target {
                return Ok(()); // already on this map (debounce race)
            }
        }
        if self.node.lock().unwrap().is_none() {
            // Not started yet — next `start()` applies fabric before bind.
            self.fabric_rebind.lock().unwrap().bound_derp_urls = target;
            return Ok(());
        }

        // Detach relay host first (same endpoint as messaging — must not outlive the node).
        // Keep cloudflared + embedded DERP: they are separate sockets and still front the same ports.
        let was_hosting = {
            let mut g = self.relay_host.lock().unwrap();
            if let Some(h) = g.take() {
                h.disable();
                true
            } else {
                false
            }
        };

        // Drop warm relay clients (bound to the old endpoint).
        self.relay_clients.lock().await.clear();

        // Fully close the old endpoint before same-seed spawn.
        let old = self.node.lock().unwrap().take();
        if let Some(old) = old {
            old.shutdown().await;
            // Brief pause so OS UDP / iroh internals finish teardown.
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }

        // Policy again (may have learned more during debounce), then bind.
        haven_net::apply_derp_urls(self.prefs.lock().unwrap().all_derp_urls());
        let listener: Arc<dyn InboundListener> = Arc::new(NodeListener {
            engine: Arc::downgrade(self),
        });
        let device_seed = self.roster.lock().unwrap().device_seed.clone();
        let node = HavenNode::start(device_seed, listener)
            .await
            .map_err(|e| anyhow::anyhow!("HavenNode::start after fabric rebind: {e}"))?;
        *self.node.lock().unwrap() = Some(node);
        self.fabric_rebind.lock().unwrap().bound_derp_urls = haven_net::active_derp_urls();
        self.dyn_state.lock().unwrap().started = true;

        if was_hosting {
            if let Err(e) = self.reattach_hosting_after_rebind().await {
                log::error!("fabric rebind: re-attach relay host failed: {e:#}");
                self.dyn_state.lock().unwrap().hosting = false;
            }
        }

        // Re-push membership + announce so peers learn we are back on fabric.
        self.authorize_membership();
        self.reannounce_own_relay();
        // Warm path again after a brief settle.
        self.sync_with_contacts();
        Ok(())
    }

    /// Re-attach in-process mailbox to the new messaging node without re-spawning tunnels/DERP.
    async fn reattach_hosting_after_rebind(self: &Arc<Self>) -> Result<()> {
        let Some(node) = self.node.lock().unwrap().clone() else {
            return Err(anyhow::anyhow!("messaging node missing after rebind"));
        };
        let dir = self.paths.relay_dir();
        std::fs::create_dir_all(&dir).ok();
        let (max_age_days, max_bytes) = self.prefs.lock().unwrap().relay_media_limits();
        let handle = RelayServerHandle::attach_with_limits(
            node,
            dir.to_string_lossy().to_string(),
            max_age_days,
            max_bytes,
        );
        let node_hex = handle.node_id_hex();
        let token = self.prefs.lock().unwrap().relay_http_token.clone();
        if !token.is_empty() {
            // Prefer the well-known port so existing cloudflared front doors keep working.
            if let Err(e) = handle.serve_http("0.0.0.0:8674".into(), token.clone()).await {
                log::warn!("reattach http :8674 failed ({e}); trying ephemeral");
                let _ = handle
                    .serve_http("0.0.0.0:0".into(), token.clone())
                    .await
                    .map_err(|e| anyhow::anyhow!("reattach http: {e}"))?;
            }
        }
        // Re-publish media URLs from the *live* tunnel. Without this, fabric rebind left
        // LAN-only media URLs while DERP still had trycloudflare → iroh works, media never does.
        let mut urls: Vec<String> = Vec::new();
        if let Some(t) = self.quick_tunnel.lock().unwrap().as_ref() {
            let u = t.public_url.trim().trim_end_matches('/').to_string();
            if !u.is_empty() {
                urls.push(u);
            }
        }
        if urls.is_empty() {
            let pub_url = self.prefs.lock().unwrap().relay_public_url.clone();
            let t = pub_url.trim().trim_end_matches('/');
            if !t.is_empty() {
                if let Ok(n) = haven_net::cfquicktunnel::normalize_public_url(t) {
                    urls.push(n);
                } else {
                    urls.push(t.to_string());
                }
            }
        }
        if urls.is_empty() {
            if let Some(ip) = Self::primary_lan_ip() {
                urls.push(format!("http://{ip}:8674"));
            }
        }
        if !urls.is_empty() && !token.is_empty() {
            let path_routed = *self.path_routed.lock().unwrap();
            let mut p = self.prefs.lock().unwrap();
            let mut changed = p.set_relay_http(&node_hex, urls.clone(), token);
            // Path-proxy single origin: keep DERP on the same public URL.
            if path_routed {
                if let Some(u) = urls.first() {
                    changed |= p.set_relay_derp(&node_hex, u);
                }
            }
            if changed {
                let _ = p.save(&self.paths);
            }
            log::info!("reattach media announce urls={urls:?}");
        }
        *self.relay_host.lock().unwrap() = Some(handle);
        self.dyn_state.lock().unwrap().hosting = true;
        Ok(())
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
        // Drop kills cloudflared; the trycloudflare hostname dies with it.
        *self.quick_tunnel.lock().unwrap() = None;
        *self.derp_tunnel.lock().unwrap() = None;
        *self.derp_server.lock().unwrap() = None;
        *self.path_router.lock().unwrap() = None;
        *self.path_routed.lock().unwrap() = false;
        *self.turn_server.lock().unwrap() = None;
        // Also sweep orphans — lost Process/Child refs leave dual free tunnels that make the
        // public URL look like "Iroh Relay only" or 401 after toggle off/on.
        haven_net::cfquicktunnel::kill_orphan_cloudflareds(&[]);
        self.dyn_state.lock().unwrap().hosting = false;
        self.emit_changed();
    }

    /// Live free/named front-door URLs for the Settings UI (media + optional dual DERP).
    /// `(live_media, live_derp, path_routed)`.
    pub fn live_front_door(&self) -> (Option<String>, Option<String>, bool) {
        let media = self
            .quick_tunnel
            .lock()
            .unwrap()
            .as_ref()
            .map(|t| t.public_url.clone());
        let derp = self
            .derp_tunnel
            .lock()
            .unwrap()
            .as_ref()
            .map(|t| t.public_url.clone());
        let path_routed = *self.path_routed.lock().unwrap();
        (media, derp, path_routed)
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
    /// Tell every relay serving a circle who its MEMBERS are.
    ///
    /// Publishing our own roster says "these are MY devices"; it cannot say "this new person belongs
    /// here". So a contact invited AFTER the operator pasted the relay link was refused by that relay
    /// forever — every media fetch, mailbox put and devroster read forbidden — which presents as
    /// broken sync rather than a permissions gap. `RelayAuth::learn` has always accepted this from a
    /// caller the relay already serves; the verb simply had no caller here. We must name ourselves or
    /// the relay declines by rule (2). iOS `enrollMembers` / Android `enrollCircleMembers` parity.
    async fn enroll_circle_members(self: &Arc<Self>) {
        let me = self.social.my_node_hex();
        let my_dev = self.node_id_hex();
        for c in self.social.circles() {
            let relays: Vec<String> = self
                .relays_for(&c.id)
                .into_iter()
                .filter(|h| !h.starts_with("s3:") && h.len() == 64)
                .collect();
            if relays.is_empty() {
                continue;
            }
            let mut members: std::collections::BTreeSet<String> =
                self.social.contact_node_ids(c.id.clone()).into_iter().map(|m| m.to_lowercase()).collect();
            members.insert(me.to_lowercase());
            members.insert(my_dev.to_lowercase());
            if members.len() <= 1 {
                continue;
            }
            let list: Vec<String> = members.into_iter().collect();
            for hex in relays {
                let Some(client) = self.relay_client_for(&hex).await else { continue };
                if client.enroll_members(c.id.clone(), list.clone()).await {
                    log::info!("enrolled {} members of {} at {}", list.len(), c.id, &hex[..8.min(hex.len())]);
                }
            }
        }
    }

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
            let http_iface = self.relay_http_reachable(&node_hex);
            if let Some((urls, token)) = http_iface {
                let mut done = false;
                let mut refused = false;
                for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                    match self.http_put(base, &token, &key, wire.clone()).await {
                        Ok(()) => {
                            self.mark_relay_ok(&node_hex);
                            self.roster_published.lock().unwrap().insert(node_hex.clone(), (wire_hash, now_ms()));
                            done = true;
                            break;
                        }
                        // The devroster key is permission-FREE, so a refusal here is the relay rejecting
                        // our roster BODY (rollback defense: it already holds a NEWER version of our own
                        // account's roster, usually published by a sibling device) — `note_refused` would
                        // only schedule a heal that repeats this very publish. Still never back the URL
                        // off: this is the one write that authorizes all the others, and sealing it for
                        // two minutes is how a device stays unauthorized far longer than it needs to.
                        Err(RelayErr::Forbidden) => {
                            refused = true;
                            log::info!(
                                "devroster http-put REFUSED relay={} — out-versioned or rejected, adopting theirs",
                                &node_hex.chars().take(8).collect::<String>()
                            );
                        }
                        Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                    }
                }
                if done {
                    continue;
                }
                if refused {
                    // The deadlock-breaker (see `adopt_newer_own_roster_and_retry`): this used to fall
                    // through to the iroh dial with the SAME stale wire — refused again (or lost to a
                    // dial cooldown on an HTTP-only relay), so the device stayed unauthorized until a
                    // SIBLING happened to republish a roster containing it. On the matrix fleet that
                    // was a ~20-minute mailbox blackout for every circle on the stub.
                    self.adopt_newer_own_roster_and_retry(&node_hex, &key, &wire, "forbidden").await;
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
        // Retry over the SAME transport ladder as the publish: plain HTTP first (an HTTP-only
        // relay — the matrix stub, a free-CF NAS — never accepts an iroh dial, so retrying only
        // via dial left the recovery dead exactly where it was needed), then the iroh client.
        if let Some((urls, token)) = self.relay_http_reachable(node_hex) {
            for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                match self.http_put(base, &token, key, fresh.wire.clone()).await {
                    Ok(()) => {
                        self.mark_relay_ok(node_hex);
                        log::info!("devroster put OK relay={short} after adopting its newer roster — this device is authorized again");
                        return;
                    }
                    Err(RelayErr::Forbidden) => {
                        log::info!("devroster STILL refused by {short} over http after adopting");
                        return;
                    }
                    Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                }
            }
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
        // -1 refused, 0 already current, 1 stored (changed). `known` records that we HAVE the
        // roster while still letting the loop ask the remaining relays: stopping at the first one
        // holding a stale-but-equal copy pins this device a version behind its siblings forever.
        let mut known = false;
        let mut ingest = |me: &Arc<Self>, w: Vec<u8>, node: Option<&str>| -> bool {
            let status = me.social.ingest_roster_wire_status(w);
            if status < 0 {
                log::warn!("devroster REFUSED {short} — forged, or a rollback to an older version");
                return false;
            }
            known = true;
            if let Some(n) = node {
                me.mark_relay_ok(n);
            }
            me.authorize_membership();
            if status == 0 {
                return false; // already current — keep looking for a NEWER copy
            }
            log::info!("devroster PULLED {short} — roster CHANGED");
            // The roster changed, so the circle epoch moved. Content already sealed under the
            // PREVIOUS epoch is unreadable to a member who joins or advances past it; the full
            // bundle re-seals my history under the new one. The mechanism existed, nothing
            // triggered it here, so the repair waited for the next periodic backfill.
            me.reseal_after_epoch_change();
            true
        };

        // Our own hosted store first — no dial, and a relay-hosting device usually already holds it.
        if hosted.is_some() {
            let local = self.relay_host.lock().unwrap().as_ref().and_then(|h| h.local_get(key.clone()));
            if let Some(w) = local {
                if !w.is_empty() && ingest(self, w, None) {
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
            let http_iface = self.relay_http_reachable(&node_hex);
            if let Some((urls, token)) = http_iface {
                for base in urls.iter().filter(|u| !self.http_url_bad(u)) {
                    match self.http_get(base, &token, &key).await {
                        Ok(Some(w)) => {
                            if !w.is_empty() && ingest(self, w, Some(&node_hex)) {
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
                    if !w.is_empty() && ingest(self, w, Some(&node_hex)) {
                        return true;
                    }
                }
            }
        }
        known
    }

    /// Re-seal my history under the circle's NEW epoch after a roster change. Throttled: each pass
    /// is a hybrid PQ signature per event, so a burst of roster changes coalesces into one.
    fn reseal_after_epoch_change(self: &Arc<Self>) {
        const MIN_INTERVAL_MS: u64 = 30_000;
        {
            let mut last = self.last_epoch_reseal.lock().unwrap();
            let now = now_ms();
            if now.saturating_sub(*last) < MIN_INTERVAL_MS {
                return;
            }
            *last = now;
        }
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            let cids: Vec<String> = me.social.circles().into_iter().map(|c| c.id).collect();
            for cid in cids {
                me.backfill_mailbox(&cid).await;
            }
        });
    }

    /// Adopt a relay node for all circles (ADDED to the redundant set, not replacing existing
    /// relays) + tell contacts via frame 19. Accepts a bare 64-hex id **or** the JSON interface
    /// blob printed by `haven-relay` (`{"node","urls","token","derp","turn",…}`) so one paste
    /// learns media HTTP + Haven DERP fabric + TURN and re-announces them to the circle.
    pub async fn adopt_relay(self: &Arc<Self>, node_hex: String) {
        let raw = node_hex.trim();
        let mut hex = raw.to_lowercase();
        let mut urls: Vec<String> = Vec::new();
        let mut token = String::new();
        let mut derp = String::new();
        let mut turn_urls: Vec<String> = Vec::new();
        let mut turn_user = String::new();
        let mut turn_pass = String::new();
        if raw.starts_with('{') {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else { return };
            hex = v["node"].as_str().unwrap_or_default().trim().to_lowercase();
            urls = v["urls"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|u| u.as_str())
                        .filter(|u| u.starts_with("http"))
                        .map(|u| u.to_string())
                        .collect()
                })
                .unwrap_or_default();
            token = v["token"].as_str().unwrap_or_default().to_string();
            if let Some(d) = v["derp"].as_str() {
                derp = d.trim().trim_end_matches('/').to_string();
            }
            turn_urls = haven_net::parse_turn_urls(&v["turn"]);
            turn_user = v["turnUser"].as_str().unwrap_or_default().to_string();
            turn_pass = v["turnPass"].as_str().unwrap_or_default().to_string();
            if turn_user.is_empty() && !turn_urls.is_empty() {
                turn_user = haven_net::DEFAULT_TURN_USER.to_string();
            }
            if turn_pass.is_empty() && !turn_urls.is_empty() && !token.is_empty() {
                turn_pass = token.clone();
            }
        }
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
            if !urls.is_empty() && !token.is_empty() {
                p.set_relay_http(&hex, urls, token);
            }
            if !derp.is_empty() {
                p.set_relay_derp(&hex, &derp);
            }
            if !turn_urls.is_empty() {
                p.set_relay_turn(&hex, turn_urls, &turn_user, &turn_pass);
            }
            let _ = p.save(&self.paths);
        }
        self.refresh_haven_fabric();
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
        self.nudge_self_sync(); // the relay deletion (LWW) rides a prompt pass to my other devices
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
        self.nudge_self_sync(); // the re-add (LWW) rides a prompt pass
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
            let served: Vec<String> =
                p.relays.iter().filter(|(_, v)| v.contains(&hex)).map(|(k, _)| k.clone()).collect();
            for list in p.relays.values_mut() {
                list.retain(|h| h != &hex);
            }
            p.relays.retain(|_, v| !v.is_empty());
            // Archive BEFORE the entry and its associations are gone — afterwards there is nothing
            // left to reconstruct it from. Capped at 12 / 30 days: enough to undo a mistake, not a
            // permanent record of every relay the app ever auto-purged.
            if let Some(e) = p.relay_entries.remove(&hex) {
                let now = now_ms();
                let was_default = p.default_relay == hex;
                p.erased_relays.insert(
                    hex.clone(),
                    crate::store::ErasedRelay { entry: e, circles: served, was_default, erased_at: now },
                );
                let cutoff = now.saturating_sub(30 * 24 * 60 * 60 * 1000);
                p.erased_relays.retain(|_, r| r.erased_at > cutoff);
                while p.erased_relays.len() > 12 {
                    if let Some(oldest) = p.erased_relays.values().min_by_key(|r| r.erased_at).map(|r| r.entry.hex.clone()) {
                        p.erased_relays.remove(&oldest);
                    } else {
                        break;
                    }
                }
            }
            if p.default_relay == hex {
                p.default_relay.clear();
            }
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

    /// Deleted relays that can still be brought back, newest deletion first (the "Deleted relays"
    /// disclosure on the Relays screen). Mirrors iOS `erasedRelays` / Android `erasedRelayList`.
    pub fn erased_relays(&self) -> Vec<crate::store::ErasedRelay> {
        let p = self.prefs.lock().unwrap();
        let cutoff = now_ms().saturating_sub(30 * 24 * 60 * 60 * 1000);
        let mut out: Vec<_> = p.erased_relays.values().filter(|r| r.erased_at > cutoff).cloned().collect();
        out.sort_by(|a, b| b.erased_at.cmp(&a.erased_at));
        out
    }

    /// Undo a "Delete now": put the entry, its circle associations and (if it held it) the default
    /// pick back, clearing the suppression + deletion stamps so the next self-sync pass cannot read
    /// our own tombstone and delete it again.
    pub async fn restore_erased_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        {
            let mut p = self.prefs.lock().unwrap();
            let Some(rec) = p.erased_relays.remove(&hex) else { return };
            let now = now_ms();
            let mut entry = rec.entry.clone();
            entry.active = true;
            entry.last_seen_ms = now;
            entry.added_at_ms = now;   // a re-add stamped NOW beats any sibling's older removal record
            p.relay_entries.insert(hex.clone(), entry);
            for cid in &rec.circles {
                let list = p.relays.entry(cid.clone()).or_default();
                if !list.contains(&hex) {
                    list.push(hex.clone());
                }
            }
            if rec.was_default && p.default_relay.is_empty() {
                p.default_relay = hex.clone();
            }
            p.relay_clear_forget(&hex);   // publish an explicit CLEAR so a sibling's tombstone loses
            let _ = p.save(&self.paths);
        }
        self.relay_health.lock().unwrap().remove(&hex);   // retry it immediately, not after a backoff
        log::info!("restored deleted relay {}", &hex[..8.min(hex.len())]);
        self.emit_changed();
        self.poll_mailbox().await;
    }

    /// Forget an archived deletion for good (the user chose not to keep the undo around).
    pub fn drop_erased_relay(self: &Arc<Self>, node_hex: String) {
        let hex = Self::norm_relay_hex(&node_hex);
        let mut p = self.prefs.lock().unwrap();
        if p.erased_relays.remove(&hex).is_some() {
            let _ = p.save(&self.paths);
        }
        drop(p);
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
        // Clone the node OUT of the lock before awaiting: `relay_client` is async, and holding a
        // std::sync MutexGuard across an await point is what makes the future non-Send.
        let node = self.node.lock().unwrap().clone();
        let warm = match node {
            Some(n) => n.relay_client(node_hex.to_string()).await.ok(),
            None => None,
        };
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
    /// Which destinations are confirmed to hold each of `refs`, plus every relay this circle
    /// publishes to (even ones holding nothing — that is the case you most need to see).
    ///
    /// Powers the "Where this is stored" sheet. Desktop had no way to answer this at all: the
    /// ledger was private to the engine, so the only route to "which relay actually has my photo"
    /// was reading the log. Apple has had `BackupDetailView` for this since the day the tick said
    /// yes and nobody could fetch anything. Returns `(destination, how many of refs it holds)`.
    pub fn media_backup_rows(&self, circle_id: String, refs: Vec<String>) -> Vec<(String, u32)> {
        let ledger = self.dyn_state.lock().unwrap().media_backed_up.clone();
        let mut dests: std::collections::BTreeSet<String> =
            self.relays_for(&circle_id).into_iter().collect();
        for entry in &ledger {
            if let Some((dest, reference)) = entry.rsplit_once('|') {
                if refs.iter().any(|r| r == reference) {
                    dests.insert(dest.to_string());
                }
            }
        }
        dests
            .into_iter()
            .map(|dest| {
                let have = refs
                    .iter()
                    .filter(|r| ledger.contains(&format!("{dest}|{r}")))
                    .count() as u32;
                (dest, have)
            })
            .collect()
    }

    /// The relay this app is hosting in-process, or "" when it hosts none. A copy that only ever
    /// reached THIS is a local file write — it looks backed up and nobody else can fetch it.
    pub fn own_hosted_relay_hex(&self) -> String {
        self.relay_link().unwrap_or_default()
    }

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
    /// How many leading windows to SKIP for one destination: the ones we ourselves wrote there from
    /// these exact sealed bytes (`mediaresume::trusted_prefix`) AND that it still holds. The probe is
    /// the second half — a relay may have swept the chunks since — and it stops at the first miss, so
    /// with no prior progress it costs at most ONE probe. That is what makes probing affordable on
    /// destinations (S3, a relay's HTTP interface) whose only existence check is a full GET.
    async fn resume_skip<F, Fut>(
        &self,
        dest: &str,
        reference: &str,
        fingerprint: &str,
        total: usize,
        force: bool,
        mut held: F,
    ) -> usize
    where
        F: FnMut(usize) -> Fut,
        Fut: std::future::Future<Output = bool>,
    {
        let prior = self.media_upload_progress(dest, reference);
        let trusted = crate::mediaresume::trusted_prefix(
            force,
            prior.as_ref().map(|(fp, _)| fp.as_str()),
            fingerprint,
            prior.as_ref().map(|(_, n)| *n).unwrap_or(0),
            total,
        );
        if trusted == 0 {
            return 0;
        }
        let mut probed = Vec::new();
        for i in 0..trusted {
            let h = held(i).await;
            probed.push(h);
            if !h {
                break;
            }
        }
        let skip = crate::mediaresume::upload_skip_count(&probed);
        if skip > 0 {
            log::info!("resumed upload to {}: {skip}/{total} windows already stored", &dest[..8.min(dest.len())]);
        }
        skip
    }

    /// `(fingerprint, windows)` this destination was last given for `reference`, or `None` if we have
    /// no record — which safely means "re-send everything".
    fn media_upload_progress(&self, dest: &str, reference: &str) -> Option<(String, usize)> {
        let st = self.dyn_state.lock().unwrap();
        let v = st.media_upload_progress.get(&format!("{dest}|{reference}"))?;
        let (fp, n) = v.rsplit_once(':')?;
        Some((fp.to_string(), n.parse().ok()?))
    }

    /// Remember that `windows` leading windows of THESE sealed bytes are now on `dest`. Written after
    /// each window — nothing beside the 8 MB PUT it follows. Losing the last write or two to a kill is
    /// harmless in the only direction that matters: it UNDERSTATES progress, costing a re-sent window,
    /// and can never overstate it. `windows == 0` clears the record (a finished upload needs none).
    fn record_media_upload_progress(&self, dest: &str, reference: &str, fingerprint: &str, windows: usize) {
        let snapshot = {
            let mut st = self.dyn_state.lock().unwrap();
            let k = format!("{dest}|{reference}");
            if windows == 0 {
                if st.media_upload_progress.remove(&k).is_none() {
                    return;
                }
            } else {
                let v = format!("{fingerprint}:{windows}");
                if st.media_upload_progress.get(&k) == Some(&v) {
                    return;
                }
                st.media_upload_progress.insert(k, v);
            }
            // Bounded like every other durable record here. Eviction only costs a full re-upload of a
            // long-idle ref (the safe direction), never correctness.
            while st.media_upload_progress.len() > 2_000 {
                let victim = match st.media_upload_progress.keys().next() {
                    Some(k) => k.clone(),
                    None => break,
                };
                st.media_upload_progress.remove(&victim);
            }
            st.media_upload_progress
                .iter()
                .map(|(k, v)| format!("{k}\t{v}"))
                .collect::<Vec<_>>()
                .join("\n")
        };
        let _ = std::fs::write(self.paths.root.join("media-upload-progress.txt"), snapshot);
    }

    /// Forget a destination's media confirmations (relay forgotten/erased) so we re-mirror to it
    /// if it ever comes back. iOS `MediaBackupLedger.forgetDest` parity.
    /// Forget every confirmation for ONE ref, so the next pass re-probes every destination instead of
    /// trusting a verdict that has since turned out to be wrong.
    ///
    /// The ledger is otherwise write-once, which is right while a stored blob is immutable AND
    /// complete — and wrong the moment one isn't. A relay copy missing chunks is never re-examined, so
    /// it stays broken forever while this device keeps reporting the post as safely backed up. The
    /// complement of [`Self::forget_media_backed_up`], which drops a whole destination.
    fn forget_media_backed_up_ref(&self, reference: &str) {
        let mut st = self.dyn_state.lock().unwrap();
        let before = st.media_backed_up.len();
        let suffix = format!("|{reference}");
        st.media_backed_up.retain(|k| !k.ends_with(&suffix));
        if st.media_backed_up.len() != before {
            st.media_backed_up_dirty = true;
        }
    }

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
        let mut landed = false;
        // 1) Mirror to EVERY configured Haven relay (redundancy). Content-addressed keys make
        //    re-puts idempotent, and a relay in backoff is skipped — graceful fallback.
        //    SYMMETRIC with poll_mailbox's ephemeral fallback: a selfsync-learned circle whose
        //    winning record carried an EMPTY relay list has NO key in prefs.relays (circle-sync
        //    records only ever learn real associations from announces/sync). Its explicit set is
        //    empty, so an authored event (post OR reaction/comment — all funnel through here via
        //    after_author) would upload to ZERO relays and relay-only members (cross-NAT peers,
        //    the matrix stub) would never receive it. So for such a circle, upload to every ACTIVE
        //    relay this device knows — exactly what the poll side reads from. Ephemeral by design:
        //    this never writes prefs.relays.
        let relay_hexes: Vec<String> = {
            let p = self.prefs.lock().unwrap();
            let explicit = p.active_relays_for(circle_id);
            if !explicit.is_empty() || p.relays.contains_key(circle_id) {
                explicit
            } else {
                p.all_active_relay_hexes()
                    .into_iter()
                    .filter(|h| !h.starts_with("s3:"))
                    .collect()
            }
        };
        // One info line per authored upload so a future empty-relay-set drop (relays=0 → nothing
        // reaches relay-only members) is visible in the log instead of silently vanishing.
        log::info!(
            "upload_event circle={} relays={}",
            &circle_id.chars().take(16).collect::<String>(),
            relay_hexes.len()
        );
        let hosted = self.relay_host.lock().unwrap().as_ref().map(|h| h.node_id_hex());
        // PER-(relay,key) skip (iOS parity): the old global "seen once anywhere -> skip forever"
        // starved every relay adopted, recovered, or GC-swept AFTER a key first landed. The
        // epoch-head KEY COMMIT has a stable content-addressed key, so it landed once long ago and
        // never reached the relay a peer actually polls -- their copy of every event sealed under
        // that epoch buffered in pending_epoch forever (the content blackout's sender half).
        let relay_hexes: Vec<String> = {
            let st = self.dyn_state.lock().unwrap();
            relay_hexes
                .into_iter()
                .filter(|n| !st.seen_mailbox.contains(&format!("put:{n}|{key}")))
                .collect()
        };
        for node_hex in relay_hexes {
            // Our OWN hosted relay: store directly into the local mailbox (no iroh self-dial).
            if hosted.as_deref() == Some(node_hex.as_str()) {
                if let Some(h) = self.relay_host.lock().unwrap().as_ref() {
                    h.local_put(key.clone(), env.to_vec());
                    self.dyn_state.lock().unwrap().relay_active = true;
                    landed = true;
                }
                self.mark_mailbox_seen(format!("put:{node_hex}|{key}"));
                continue;
            }
            // Plain-HTTP FIRST (an HTTP-mailbox-only host — a cloudflared / free-CF / LAN-NAS relay,
            // the DEFAULT cross-NAT transport — never iroh-dials), then the warm iroh client: the
            // SAME ladder the mailbox poll + hello-put run, in the same order. upload_event was the
            // one mailbox-WRITE path still iroh-only, so an authored envelope could only ride the
            // iroh blob ALPN — which drops on pure-relay cross-NAT paths — and never reached an
            // HTTP-only relay. That is the SEND half of the exact "iOS put via HTTP, Tauri polled
            // via iroh, nothing landed" gap poll_mailbox already fixed on the read side: relay-only
            // members (the matrix stub, cross-NAT peers) never saw this device's posts/reactions.
            let mut put_ok = false;
            if let Some((bases, token)) = self.relay_http_reachable(&node_hex) {
                for base in &bases {
                    if self.http_url_bad(base) {
                        continue;
                    }
                    match self.http_put(base, &token, &key, env.to_vec()).await {
                        Ok(()) => {
                            self.mark_relay_ok(&node_hex);
                            self.dyn_state.lock().unwrap().relay_active = true;
                            self.mark_mailbox_seen(format!("put:{node_hex}|{key}"));
                            put_ok = true;
                            landed = true;
                            break;
                        }
                        // Same store behind every URL — a membership refusal stands, don't fall
                        // through to iroh (it would be refused too) or hammer the other bases.
                        Err(RelayErr::Forbidden) => {
                            self.note_refused(&node_hex, "mailbox put");
                            put_ok = true; // "handled" — skip the iroh leg for a refusal
                            break;
                        }
                        Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                    }
                }
            }
            if !put_ok {
                if let Some(client) = self.relay_client_for(&node_hex).await {
                    match client.put(key.clone(), env.to_vec()).await {
                        Ok(()) => {
                            self.mark_relay_ok(&node_hex);
                            self.dyn_state.lock().unwrap().relay_active = true;
                            self.mark_mailbox_seen(format!("put:{node_hex}|{key}"));
                            landed = true;
                        }
                        Err(e) => {
                            log::debug!("mailbox put failed ({node_hex}): {e}");
                            self.relay_failed(&node_hex).await;
                        }
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
        // Mirror upload_event's fallback: a selfsync-learned circle with no explicit relay set
        // (no prefs.relays key) still has somewhere to land if this device knows any active relay,
        // so the catch-up sweep must not short-circuit it the way an S3-less, relay-less circle is.
        let has_relay = {
            let p = self.prefs.lock().unwrap();
            !p.active_relays_for(circle_id).is_empty()
                || (!p.relays.contains_key(circle_id)
                    && p.all_active_relay_hexes().iter().any(|h| !h.starts_with("s3:")))
        };
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
        // Content-envelope seen-marks, applied only AFTER persist() lands the engine state
        // holding their events (see the tail of this function).
        let mut pending_marks: Vec<String> = Vec::new();
        // Circles whose peer keys just became usable because a KEY COMMIT actually applied, plus
        // the control keys that did it. Content sitting in this circle's mailbox may have been
        // marked seen back when it could not be opened, so it has to be re-queued — see the
        // repair after the poll loop.
        let mut unlocked_circles: std::collections::HashSet<String> = Default::default();
        let mut applied_control_keys: std::collections::HashSet<String> = Default::default();
        // ONE-SHOT storm-burn repair (iOS/Android parity): earlier builds marked keys seen before
        // the engine state persisted; a kill in the gap burned keys whose events — including
        // friends' KEY COMMITS — never landed. Clear the whole mailbox seen-set once (live-call
        // lanes kept) so everything re-drains under the mark-after-persist contract above.
        // Publish every circle's epoch HEAD (roster + current key commit) once per launch (iOS
        // parity): a member who hasn't posted since a relay was adopted/recovered/GC-swept never
        // re-offers the commit, and peers buffer every event of theirs forever. Cheap: cached
        // commit + per-(relay,key) upload marks make repeats a no-op.
        static LAUNCH_HEADS_PUBLISHED: std::sync::atomic::AtomicBool =
            std::sync::atomic::AtomicBool::new(false);
        if !LAUNCH_HEADS_PUBLISHED.swap(true, std::sync::atomic::Ordering::SeqCst) {
            let cids: Vec<String> = self.social.circles().into_iter().map(|c| c.id).collect();
            for cid in cids {
                for head in self.social.export_epoch_head(cid.clone()) {
                    self.upload_event(&cid, &head).await;
                }
            }
        }
        let repair_marker = self.paths.root.join("repair-storm-burn-v1");
        if !repair_marker.exists() {
            let removed = {
                let mut st = self.dyn_state.lock().unwrap();
                let before = st.seen_mailbox.len();
                st.seen_mailbox.retain(|k| k.contains("/__live__/"));
                st.seen_mailbox_dirty = true;
                before - st.seen_mailbox.len()
            };
            let _ = std::fs::write(&repair_marker, b"1");
            if removed > 0 {
                self.flush_seen_mailbox();
                log::info!("mailbox seen: storm-burn repair forgot {removed} keys — full re-drain");
            }
        }
        // Control-plane blobs ROUTED this pass (hellos to me / durable frame-19 announces) — they
        // change engine/prefs state without being circle events, so they persist+emit on their own.
        let mut routed_control = false;
        let mut relay_announced = false;
        // Circles whose engine state changed this pass — notified ONCE each, after ingest,
        // through notify_circle's freshness + dedupe guards. Notifying per changed ENVELOPE
        // (the old shape) fired for key commits and epoch-rotation re-seals of old history
        // too, so the same "new message" banner repeated forever on a churning circle.
        let mut changed_circles: std::collections::BTreeSet<String> = Default::default();
        // NEW envelopes this pass — fan out to my other linked devices after ingest. Mailbox was
        // the hole in receive-time fan-out: a friend's post landed on whichever of my devices
        // polled first and never reached the rest when their mailbox auth/relay set differed.
        // (`handle_event` already live-delivers for direct/iroh paths.)
        let mut newly_ingested: Vec<(String, Vec<u8>)> = Vec::new();
        // Every id a stored hello can legitimately address to reach THIS device: the account hex
        // (the canonical slot addressing) plus my transport device id(s) — a legacy sender
        // addressed the recipient's TRANSPORT id, and the account-only claim filter dropped those
        // hellos forever (the "circle invite never arrived" leg of the dead hello lane).
        let my_hello_ids: Vec<String> = {
            let acct = self.node_id_hex().to_lowercase();
            let mut ids = vec![acct.clone(), self.social.my_device_node_hex().to_lowercase()];
            for d in self.social.device_node_ids_for(acct) {
                ids.push(d.to_lowercase());
            }
            ids.sort();
            ids.dedup();
            ids
        };
        // (circle_id, relay_node_hex) for every circle × every configured relay — reading from
        // all of them means a message present on any reachable relay still arrives.
        let relay_targets: Vec<(String, String)> = {
            let engine_circles: Vec<String> =
                self.social.circles().into_iter().map(|c| c.id).collect();
            let prefs = self.prefs.lock().unwrap();
            let mut out: Vec<(String, String)> = prefs
                .relays
                .iter()
                .flat_map(|(cid, list)| list.iter().map(move |hex| (cid.clone(), hex.clone())))
                .collect();
            // Circles the ENGINE holds but no relay announce / synced circle record has wired yet —
            // a fresh selfsync-learned circle whose winning record carried an empty relay list, or a
            // live-adopted DM thread. Un-polled they stay content-less forever (the "photo/DM never
            // lands on the linked desktop" E2E RED), so read them from every ACTIVE relay. Ephemeral
            // by design: prefs.relays (what circle-sync records export) only ever learns real
            // associations from announces/sync, never these fallback guesses.
            let actives: Vec<String> = prefs
                .all_active_relay_hexes()
                .into_iter()
                .filter(|h| !h.starts_with("s3:"))
                .collect();
            for cid in engine_circles {
                if !prefs.relays.contains_key(&cid) {
                    for hex in &actives {
                        out.push((cid.clone(), hex.clone()));
                    }
                }
            }
            out
        };
        for (circle_id, node_hex) in relay_targets {
            let prefix = format!("haven/mailbox/{circle_id}/");
            // Prefer plain-HTTP mailbox when the relay advertised URLs (matrix stub / free CF /
            // LAN NAS). iroh-only dial fails against an HTTP-mailbox-only host, which is exactly
            // the linked-device RED: iOS put via HTTP, Tauri polled via iroh, nothing landed.
            let mut keys: Vec<String> = Vec::new();
            let mut got_via_http = false;
            // Delta-LIST (the idle radio saver): echo the last digest for this (relay, circle) so
            // an unchanged mailbox is one bodiless 204 instead of a full key dump + N seen-set
            // walks. The fresh digest is only COMMITTED once this pass's GET batch finished with
            // no deferrals — otherwise a 204 next poll would skip keys we listed but never fetched.
            let digest_key = format!("{node_hex}|{circle_id}");
            let mut fresh_digest: Option<String> = None;
            if let Some((bases, token)) = self.relay_http_reachable(&node_hex) {
                let cached =
                    self.dyn_state.lock().unwrap().mailbox_list_digests.get(&digest_key).cloned();
                for base in &bases {
                    if self.http_url_bad(base) {
                        continue;
                    }
                    match self.http_list_delta(base, &token, &prefix, cached.as_deref()).await {
                        // 204: byte-identical key set — nothing to walk, nothing to GET.
                        Ok((None, _)) => {
                            got_via_http = true;
                            self.mark_relay_ok(&node_hex);
                            self.dyn_state.lock().unwrap().relay_active = true;
                            break;
                        }
                        Ok((Some(list), digest)) => {
                            keys = list;
                            fresh_digest = digest;
                            got_via_http = true;
                            self.mark_relay_ok(&node_hex);
                            break;
                        }
                        Err(RelayErr::Forbidden) => {
                            // Name the CIRCLE: a bare "mailbox list" hid WHICH prefix a relay was
                            // refusing (a stale circle vs the one the user is staring at).
                            self.note_refused(
                                &node_hex,
                                &format!(
                                    "mailbox list {}",
                                    &circle_id.chars().take(16).collect::<String>()
                                ),
                            );
                            let _ = self.heal_forbidden_relays().await;
                        }
                        Err(RelayErr::Unreachable) => {
                            self.mark_http_url_bad(base);
                        }
                    }
                }
            }
            if !got_via_http {
                let Some(client) = self.relay_client_for(&node_hex).await else { continue };
                // list() now surfaces transport errors (was unwrap_or_default, which hid a dead
                // dial as an empty mailbox); a failed iroh list here just means try the next relay.
                match client.list(prefix.clone()).await {
                    Ok(k) => { keys = k; self.mark_relay_ok(&node_hex); }
                    Err(_) => continue,
                }
                // We reached this relay over iroh but hold no usable HTTP interface for it —
                // exactly the state a restarted CLI relay (rotated free-tunnel URL) leaves every
                // client in, where mailbox flows and MEDIA silently dies (the blob dial drops
                // cross-NAT). Fetch its self-published interface and adopt + re-announce.
                self.refresh_relay_interface_if_needed(&node_hex);
            }
            if !keys.is_empty() {
                self.dyn_state.lock().unwrap().relay_active = true;
            }
            // Cap unopened keys processed per pass. A fat mailbox (matrix stub ~1k entries,
            // mostly `__live__` / history) used to GET+crypto every unseen key every poll →
            // multi-minute 90%+ CPU. 48 opens/pass drains backlog without melting the laptop.
            const MAX_FRESH_PER_PASS: usize = 48;
            let mut fresh = 0usize;
            // A deferral (cap hit, failed GET, or an envelope that only buffered) means listed
            // keys remain un-ingested — the fresh LIST digest must NOT be committed below.
            let mut deferred = false;
            for key in keys {
                if fresh >= MAX_FRESH_PER_PASS {
                    deferred = true;
                    break;
                }
                // seen_mailbox is keyed by the content-addressed key, so the same envelope
                // mirrored on several relays is ingested exactly once.
                if self.dyn_state.lock().unwrap().seen_mailbox.contains(&key) {
                    continue;
                }
                // A control blob we already fetched and could not apply yet: skip the GET until its
                // backoff ages out. It deliberately stays UNSEEN (so it can still apply later), and
                // `deferred` keeps the LIST digest uncommitted so we keep seeing the key.
                {
                    const CONTROL_RETRY_MS: u64 = 120_000;
                    let st = self.dyn_state.lock().unwrap();
                    if let Some(t) = st.control_retry_at.get(&key) {
                        if now_ms().saturating_sub(*t) < CONTROL_RETRY_MS {
                            drop(st);
                            deferred = true;
                            continue;
                        }
                    }
                }
                // Live-call frames are claimed by the in-call poll — never content; mark & skip.
                if key.contains("/__live__/") {
                    self.mark_mailbox_seen(key);
                    continue;
                }
                // Control-plane blobs are ROUTED below, not fed to receive() (iOS pullMailbox
                // parity): a `__hello__/` blob is a connection request and a `__relay__/` blob is
                // a durable frame-19 announce. Feeding them to receive() burned crypto budget
                // forever (announces never open) or dropped them on the floor (hellos to me).
                let is_hello = key.contains("/__hello__/");
                let is_relay_announce = key.contains("/__relay__/");
                // A hello names its recipient IN THE KEY, so filter BEFORE spending a GET: claim
                // it for any of MY ids, and skip one addressed to someone else WITHOUT marking it
                // seen — it isn't ours to retire (mark-and-drop was how this device buried hellos
                // it would recognize under a later claim set), and unfetched it costs nothing.
                if is_hello {
                    let parts: Vec<&str> = key.split('/').collect();
                    let to = parts
                        .iter()
                        .position(|p| *p == "__hello__")
                        .and_then(|i| parts.get(i + 1))
                        .map(|s| s.to_lowercase());
                    let mine =
                        to.map(|t| my_hello_ids.iter().any(|m| *m == t)).unwrap_or(false);
                    if !mine {
                        continue;
                    }
                }
                // Prefer HTTP GET when we listed over HTTP (same URL set).
                let env = if got_via_http {
                    if let Some((bases, token)) = self.relay_http_reachable(&node_hex) {
                        let mut got = None;
                        for base in &bases {
                            if self.http_url_bad(base) {
                                continue;
                            }
                            match self.http_get(base, &token, &key).await {
                                Ok(Some(bytes)) => {
                                    got = Some(bytes);
                                    break;
                                }
                                Ok(None) => {}
                                Err(RelayErr::Forbidden) => {
                                    self.note_refused(
                                        &node_hex,
                                        &format!(
                                            "mailbox get {}",
                                            key.rsplit('/').next().unwrap_or(&key)
                                                .chars().take(16).collect::<String>()
                                        ),
                                    );
                                }
                                Err(RelayErr::Unreachable) => {
                                    self.mark_http_url_bad(base);
                                }
                            }
                        }
                        got
                    } else {
                        None
                    }
                } else if let Some(client) = self.relay_client_for(&node_hex).await {
                    client.get(key.clone()).await
                } else {
                    None
                };
                let Some(env) = env else {
                    deferred = true;
                    continue;
                };
                // Only mark seen after a successful open (iOS parity). Marking first left
                // epoch-buffered envelopes permanently unretried — the linked-matrix
                // "story green / photo+video RED" shape when commit landed after the first poll.
                let env_len = env.len();
                fresh += 1; // count attempts (open or buffer) toward the pass budget
                if is_hello {
                    // Addressed to me (filtered above the GET) — route into the pending-request
                    // path (the rest of the circle's requests ride the same shared prefix).
                    self.handle_hello(&env);
                    routed_control = true;
                    log::info!(
                        "hello mailbox-ingest circle={}",
                        &circle_id.chars().take(12).collect::<String>()
                    );
                    self.mark_mailbox_seen(key);
                    continue;
                }
                if is_relay_announce {
                    // Durable frame-19: friends who can't iroh-dial the host still learn the relay
                    // (+ public media URLs/token) from the mailbox — iOS handleRelayNode parity.
                    if self.ingest_relay_announce(&env).is_some() {
                        routed_control = true;
                        relay_announced = true;
                    }
                    self.mark_mailbox_seen(key);
                    continue;
                }
                match self.social.receive(circle_id.clone(), env.clone()) {
                    Ok(true) => {
                        // A key commit that ACTUALLY applied unlocks this circle's peer keys —
                        // events already marked seen while unopenable can now be read, so flag the
                        // circle for the re-queue repair below.
                        if matches!(env.first(), Some(0x03)) {
                            unlocked_circles.insert(circle_id.clone());
                            applied_control_keys.insert(key.clone());
                        }
                        pending_marks.push(key);
                        changed = true;
                        changed_circles.insert(circle_id.clone());
                        newly_ingested.push((circle_id.clone(), env));
                        log::info!(
                            "mailbox ingest circle={} via_http={got_via_http} bytes={env_len}",
                            &circle_id.chars().take(12).collect::<String>(),
                        );
                    }
                    // A KEY COMMIT (0x03) or DEVICE ROSTER (0x04) that did NOT take effect must be
                    // retried, never retired. `receive()` answers Ok(false) for a commit whose
                    // committer this device cannot authorize YET — B's roster hasn't landed, or the
                    // commit arrived before it. Marking that key seen burns the ONE blob that would
                    // ever have opened B's content: it is content-addressed, so nothing re-publishes
                    // it, and from then on every envelope B authors parks in pending_epoch forever.
                    // That is the whole "desktop never receives peer-authored content" failure — and
                    // it is silent, because our own account's posts keep arriving over self-sync.
                    // Unfetched costs one LIST entry; burned costs the conversation.
                    Ok(false)
                        if matches!(env.first(), Some(0x03) | Some(0x04)) =>
                    {
                        // Leave it UNSEEN so a later pass can apply it — but BACK OFF. A commit can
                        // be unauthorizable for a long time (126 attempts in one observed run), and
                        // re-GETting + re-verifying it every poll is a measurable tax on a leg that
                        // is already the slowest in the fleet. Retry roughly every 2 minutes.
                        // Stamp it; the loop head skips the GET entirely until the stamp ages out.
                        self.dyn_state.lock().unwrap().control_retry_at.insert(key.clone(), now_ms());
                        log::debug!(
                            "mailbox control blob not yet applicable circle={} key={} — UNSEEN, retry later",
                            &circle_id.chars().take(12).collect::<String>(),
                            key.rsplit('/').next().unwrap_or(&key).chars().take(16).collect::<String>(),
                        );
                        deferred = true; // don't commit the LIST digest: we must see this key again
                    }
                    Ok(false) => {
                        // Duplicate (nothing changed) or BUFFERED until its key/roster arrives —
                        // mark seen EITHER way: the pending buffer is durable (persist() runs right
                        // after this loop), so the mailbox copy is redundant. Leaving false-returns
                        // unseen melted the relay-hosting Mac once convergence made re-applied
                        // commits honest no-ops: a storm-wiped seen-set re-fetched and re-decrypted
                        // thousands of envelopes on every poll, forever.
                        log::debug!(
                            "mailbox receive no-op circle={} key={} bytes={env_len} (buffered/dup) — marked seen",
                            &circle_id.chars().take(12).collect::<String>(),
                            key.rsplit('/').next().unwrap_or(&key).chars().take(16).collect::<String>(),
                        );
                        pending_marks.push(key);
                    }
                    Err(e) => {
                        // Hard per-key failure (malformed envelope, verify error). Re-fetching the
                        // SAME bytes cannot improve — mark seen; the deterministic re-seal backstop
                        // delivers a fresh copy under a new key if the content still matters.
                        log::warn!(
                            "mailbox receive FAILED circle={} key={} bytes={env_len}: {e} — marked seen",
                            &circle_id.chars().take(12).collect::<String>(),
                            key.rsplit('/').next().unwrap_or(&key).chars().take(16).collect::<String>(),
                        );
                        pending_marks.push(key);
                    }
                }
            }
            if !deferred {
                if let Some(d) = fresh_digest {
                    self.dyn_state.lock().unwrap().mailbox_list_digests.insert(digest_key, d);
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
                    match self.social.receive(c.id.clone(), env.clone()) {
                        Ok(true) => {
                            pending_marks.push(key);
                            changed = true;
                            changed_circles.insert(c.id.clone());
                            newly_ingested.push((c.id.clone(), env));
                        }
                        // Duplicate/buffered-durable/garbage: seen either way (see the relay-path
                        // comment above — unmarked false-returns re-fetch forever).
                        Ok(false) => pending_marks.push(key),
                        Err(e) => {
                            log::warn!(
                                "s3 mailbox receive FAILED circle={} key={}: {e} — marked seen",
                                &c.id.chars().take(12).collect::<String>(),
                                key.rsplit('/').next().unwrap_or(&key).chars().take(16).collect::<String>(),
                            );
                            pending_marks.push(key);
                        }
                    }
                }
            }
        }
        // A NEW key commit landed: re-queue that circle's mailbox content (minus the control keys
        // we just applied). Without this, a device that once marked an event seen while it could
        // not be opened never looks at it again — the key that would have opened it arrives later,
        // and the content stays dark forever even though it is still sitting on the relay. This is
        // the repair for installs already in that state; the two fixes above only stop NEW damage.
        // iOS FeedView parity, damper included: competing (account, epoch) commits are normal, so
        // an undamped re-queue would re-fetch and re-decrypt the whole mailbox every poll.
        // DISABLED (measured): re-queuing did NOT recover the content, because the key commit that
        // would open it is not merely missing — it is UNAUTHORIZABLE on this device (126 "control
        // blob not yet applicable" vs 2 unlocks in one run). So every re-queue re-fetched and
        // re-decrypted the circle's whole mailbox, everything re-buffered, all of it was marked
        // seen again, and the next unlock repeated it. That storm pushed own-account gates
        // (profile, story, music) past their budgets. Re-enable only once a peer's key commit can
        // actually apply — see the devroster note in the task; until then this is pure cost.
        if false && !unlocked_circles.is_empty() {
            const REQUEUE_DAMPER_MS: u64 = 10 * 60 * 1000;
            let now = now_ms();
            let mut requeued_any = false;
            for cid in &unlocked_circles {
                {
                    let mut st = self.dyn_state.lock().unwrap();
                    let due = st
                        .seen_requeued_at
                        .get(cid)
                        .map(|t| now.saturating_sub(*t) >= REQUEUE_DAMPER_MS)
                        .unwrap_or(true);
                    if !due {
                        continue;
                    }
                    st.seen_requeued_at.insert(cid.clone(), now);
                    let needle = format!("haven/mailbox/{cid}/");
                    let before = st.seen_mailbox.len();
                    // Keep the control keys just applied (re-reading them is pure waste) and the
                    // live-call lane (claimed by the in-call poll, never content).
                    st.seen_mailbox.retain(|k| {
                        !k.contains(&needle)
                            || k.contains("/__live__/")
                            || applied_control_keys.contains(k)
                    });
                    let dropped = before.saturating_sub(st.seen_mailbox.len());
                    if dropped > 0 {
                        requeued_any = true;
                        log::info!(
                            "key commit unlocked circle={} — re-queued {dropped} mailbox keys",
                            &cid.chars().take(12).collect::<String>()
                        );
                    }
                }
                // Drop the LIST digests for this circle too, or the next poll answers 204
                // ("unchanged") and we never re-list the keys we just un-marked.
                self.dyn_state
                    .lock()
                    .unwrap()
                    .mailbox_list_digests
                    .retain(|k, _| !k.ends_with(&format!("|{cid}")));
            }
            if requeued_any {
                self.flush_seen_mailbox();
            }
        }
        if relay_announced {
            self.refresh_haven_fabric();
        }
        for cid in changed_circles {
            self.notify_circle(&cid);
        }
        if routed_control && !changed {
            // A hello/announce changed engine/prefs state without any circle event ingesting.
            self.persist();
            self.emit_changed();
        }
        if changed {
            if !newly_ingested.is_empty() {
                let payloads: Vec<Vec<u8>> = newly_ingested
                    .iter()
                    .map(|(cid, env)| wire::event_payload(cid, env))
                    .collect();
                self.live_deliver_many_to_my_devices(wire::EVENT, payloads);
                // Push leg of the same fan-out: a silent syncSelf wake with the inline event so my
                // SLEEPING devices ingest without their own mailbox round-trip (iOS parity; capped
                // — a cold-drain backlog still converges via their poll).
                for (_cid, env) in newly_ingested.iter().take(10) {
                    self.push_wake(
                        &self.node_id_hex(),
                        None,
                        Some(base64::engine::general_purpose::STANDARD.encode(env)),
                        true,
                    );
                }
            }
            self.bump_activity(); // a message arrived → keep sync tight while the conversation is live
            self.persist();
            self.emit_changed();
            self.request_missing_media();
        }
        // Seen-marks STRICTLY AFTER the persist() calls above land the engine state (iOS parity):
        // marking (and flushing the seen file) ahead of the engine save let a kill burn keys whose
        // events — including friends' KEY COMMITS — never landed; all content beneath the push
        // layer went dark fleet-wide. Control-plane marks above are idempotent routes, and their
        // file flush also happens here, after the saves.
        //
        // ...but "after persist()" only holds when a persist actually RAN. Both branches above are
        // conditional: a pass whose envelopes merely BUFFERED (receive() -> Ok(false), waiting on
        // the author's key commit) leaves changed == false and routed_control == false, so nothing
        // was saved — while the buffered keys below are still written to the seen file. The engine
        // state holding pending_epoch dies with the process and those keys are never re-fetched.
        // It is self-reinforcing: the KEY COMMIT itself buffers, gets marked seen, is never fetched
        // again, and from then on nothing that peer authors can ever be opened. Own-account content
        // hides the damage because it also rides self-sync, which persists separately — which is
        // precisely the asymmetry the E2E fleet showed (peer posts/DMs/reactions/comments "never"
        // on desktop, everything from our own devices fine).
        //
        // REVERTED (measured): saving on every buffered-only pass costs more than it buys here.
        // Desktop's persist() writes the whole engine state, and doing it per poll pass took this
        // leg from 2.5s convergence to 57-68s and pushed own-account gates (story, music) past
        // their budgets — while NOT fixing the peer-content loss it was aimed at. The durability
        // hole it targeted is real but narrow (a kill in the window between buffering and the next
        // state-changing pass); the fix for it has to be a cheap targeted save of pending_epoch,
        // not a full-state write per poll. Tracked rather than papered over.
        //
        // What actually protects the content is NOT burning the key commit — see the Ok(false)
        // control-blob arm above, which leaves it unseen so a later pass can apply it.
        for k in pending_marks {
            self.mark_mailbox_seen(k);
        }
        self.flush_seen_mailbox();
    }

    /// Notify about a circle whose state just changed — but only when its newest INBOUND item
    /// is genuinely fresh (< 10 min) and hasn't been notified before (persisted dedupe). The
    /// change signal alone also fires for key commits, backfilled history, and epoch-rotation
    /// re-seals of old events; none of those deserve a banner.
    fn notify_circle(self: &Arc<Self>, circle_id: &str) {
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
        // Kind-aware copy (parity with Apple PushBanner / Android notifyInbound).
        let circle_name = self
            .social
            .circles()
            .into_iter()
            .find(|c| c.id == circle_id)
            .map(|c| c.name)
            .unwrap_or_else(|| "your circle".into());
        let author = self.display_name(&newest.author_short);
        let media_refs: Vec<&str> = newest.media.iter().map(|s| s.as_str()).collect();
        let copy = if newest.story {
            haven_p2p::pushbanner::for_post(circle_id, &circle_name, &newest.body, &media_refs, true)
        } else if newest.body.trim().is_empty()
            && newest.media.is_empty()
            && !newest.reactions.is_empty()
        {
            // Pure reaction bumps leave body empty with a reaction list (Android parity).
            let emoji = newest
                .reactions
                .first()
                .map(|r| r.emoji.as_str())
                .unwrap_or("");
            haven_p2p::pushbanner::for_reaction(emoji, circle_id)
        } else {
            haven_p2p::pushbanner::for_post(circle_id, &circle_name, &newest.body, &media_refs, false)
        };
        let detail = self
            .prefs
            .lock()
            .unwrap()
            .notification_detail
            .clone()
            .unwrap_or_else(|| "full".into());
        let (use_name, body) = haven_p2p::pushbanner::display_body(
            &copy.body,
            Some(&copy.private_body),
            Some(copy.kind),
            &detail,
        );
        let title: String = if use_name {
            if author.is_empty() { "Someone".into() } else { author }
        } else {
            "Haven".into()
        };
        // The tap target: DMs open the Messages thread, circle posts open the post — routed through
        // the same DeepLink table a pasted link uses. (The OS toast itself still only raises the
        // window — see notify_with_link — but the in-app toast and the bell row both jump.)
        let link = wire::interaction_link(circle_id, Some(&newest.id));
        // PREFETCH-BEFORE-NOTIFY: pull the item's small companions (thumbs, posters, images) so
        // that by the time the user acts on the banner the card has real pixels, not placeholders.
        // Bounded + time-capped; videos never prefetch here.
        let mut prefetch: Vec<String> = Self::thumb_refs(&newest.media);
        prefetch.extend(
            newest.media.iter().filter_map(|m| haven_p2p::mediavariants::parse_poster(m).map(|(_, p)| p.to_string())),
        );
        prefetch.extend(
            haven_p2p::mediavariants::display_refs(&newest.media)
                .into_iter()
                .filter(|r| r.starts_with("img_") || r.starts_with("i:")),
        );
        prefetch.dedup();
        prefetch.truncate(4);
        prefetch.retain(|r| !LocalMedia::is_synthetic(r) && !self.media.has(r) && !self.evicted_contains(r));
        let me = self.clone();
        let cid = circle_id.to_string();
        tauri::async_runtime::spawn(async move {
            for r in &prefetch {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_secs(5),
                    me.fetch_media_healing(&cid, r),
                )
                .await;
            }
            if !prefetch.is_empty() {
                me.emit_changed();
            }
            me.notify_with_link(&title, &body, Some(&link));
        });
    }

    // ---- `thumb:` companions (MediaVariants parity — tiny compose-time previews) ----------

    /// `thumb:<content>:<thumb>` → (content, thumb). Desktop mirror of Apple
    /// `MediaVariants.parseThumb` (the Rust core doesn't carry thumb helpers yet).
    fn parse_thumb_marker(r: &str) -> Option<(&str, &str)> {
        let rest = r.strip_prefix("thumb:")?;
        let colon = rest.rfind(':')?;
        let (content, thumb) = rest.split_at(colon);
        let thumb = &thumb[1..];
        if content.is_empty() || thumb.is_empty() {
            None
        } else {
            Some((content, thumb))
        }
    }

    /// Every thumb image ref a media list declares (≤32KB by contract — prefetched everywhere).
    fn thumb_refs(media: &[String]) -> Vec<String> {
        media.iter().filter_map(|r| Self::parse_thumb_marker(r).map(|(_, t)| t.to_string())).collect()
    }

    /// Relay-upload order for a fresh post's media: thumbs FIRST (tiny — they unblock every
    /// member's placeholder), then posters, then content in list order. Markers/synthetic refs
    /// (they carry no bytes) are dropped. Mirrors Apple `MediaVariants.uploadOrder`.
    fn upload_order(media: &[String]) -> Vec<String> {
        let thumbs = Self::thumb_refs(media);
        let posters: Vec<String> = media
            .iter()
            .filter_map(|r| haven_p2p::mediavariants::parse_poster(r).map(|(_, p)| p.to_string()))
            .collect();
        let rank = |r: &String| {
            if thumbs.contains(r) {
                0
            } else if posters.contains(r) {
                1
            } else {
                2
            }
        };
        // Thumbs ride only inside their marker, so surface them explicitly, then the real refs.
        let mut out: Vec<String> = thumbs.clone();
        out.extend(media.iter().filter(|r| !LocalMedia::is_synthetic(r)).cloned());
        out.dedup();
        let mut indexed: Vec<(usize, String)> = out.into_iter().enumerate().collect();
        indexed.sort_by_key(|(i, r)| (rank(r), *i));
        let mut seen = std::collections::HashSet::new();
        indexed.into_iter().map(|(_, r)| r).filter(|r| seen.insert(r.clone())).collect()
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

    /// Which key proves a destination holds a COMPLETE copy of `reference`, given whatever it returned
    /// for the manifest key. `None` = the presence of `head` alone is proof (a small, unchunked blob);
    /// `Some(key)` = that key must be present too.
    ///
    /// A probe that asks only "is `haven/media/<ref>` there?" cannot tell a finished upload from a
    /// manifest stranded over a partial chunk set, and answering yes to the second is PERMANENT: the
    /// ref goes into the backup ledger, no later pass revisits it, and the missing windows are never
    /// sent again. Readers then stall on the same absent chunk on every retry until the post gives up
    /// as "no longer available", while this device keeps reporting it as safely backed up. Field case
    /// (Apple, 2026-08-07): a 5-chunk video whose relay copy held chunks 0–2, stuck for days with the
    /// original sitting on the author's other device.
    ///
    /// The LAST window is the one to check: an upload that dies partway leaves a TAIL of missing
    /// chunks, so one probe catches that whole class at O(1) rather than N round-trips against a
    /// 137-window video. Mirrors iOS `SharedStore.holdsCompleteBlob` and Android `holdsCompleteBlob`;
    /// the guarantee that mesh replication never CREATES a mid-blob hole lives in
    /// `haven-net::pull_missing_from_peer`.
    fn completeness_probe_key(reference: &str, head: &[u8]) -> Option<String> {
        Self::parse_manifest(head).map(|n| Self::media_chunk_key(reference, n - 1))
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

    /// HELD is not the same as READABLE, and only one of those is what a user sees.
    ///
    /// A blob we hold but cannot open is excluded from [`Self::request_missing_media`] — the bytes
    /// ARE on disk — so nothing notices it and nothing repairs it. Media is sealed once to a fixed
    /// recipient list and never re-sealed, so a member who joined after a post can never open its
    /// media: the bytes arrive perfectly and decrypt to nothing, forever, while the post's TEXT
    /// renders fine. Observed on a real device sitting at "0 missing" with 23 broken tiles.
    ///
    /// So actually TEST a few held refs per pass and ask the author to re-seal the failures. Bounded
    /// per pass (an open is real crypto over real bytes) and once per ref per launch, so the cost is
    /// the size of the library rather than a rate. Apple/Android parity.
    fn verify_held_media(self: &Arc<Self>, limit: usize) {
        let mut tested = 0usize;
        for c in self.social.circles() {
            if tested >= limit { return; }
            for item in self.social.feed(c.id.clone(), now_ms(), None) {
                if tested >= limit { return; }
                for reference in item.media.iter() {
                    if tested >= limit { return; }
                    if LocalMedia::is_synthetic(reference) { continue; }
                    {
                        let st = self.dyn_state.lock().unwrap();
                        if st.media_probed_session.contains(reference) { continue; }
                    }
                    if !self.media.has(reference) { continue; }
                    self.dyn_state.lock().unwrap().media_probed_session.insert(reference.clone());
                    tested += 1;
                    if self.media.load_any_circle(&self.social, reference).is_some() { continue; }
                    log::warn!("held-but-unreadable {} — asking {} to re-seal",
                               short(reference), short(&item.author_short));
                    self.clone().request_media_when_available(
                        reference.clone(), c.id.clone(), item.id.clone(), item.author_short.clone(),
                        false);   // automatic repair — never notifies
                }
            }
        }
    }

    pub fn request_missing_media(self: &Arc<Self>) {
        self.clone().verify_held_media(6);   // held != readable; see verify_held_media
        let my_hex = self.node_id_hex();
        // Refs whose relay copy was found and could not be opened (see `accept_fetched_blob`). Fetching
        // them again this session just re-downloads the same unopenable bytes; only the author's
        // re-seal can fix them, and the set is dropped on restart so a repair is picked up.
        let unopenable = self.dyn_state.lock().unwrap().media_unopenable.clone();
        let now = now_ms();
        // A ref on an event < 5 min old rides the FRESH lane below: its author is right there
        // uploading it, so it retries at 5s..90s instead of waiting out the 5-min throttle.
        const FRESH_WINDOW_MS: u64 = 5 * 60 * 1000;
        // Older than this and a newly-ingested post is BACKFILL (archive import / history sync),
        // not news — its full-size media prefetch becomes lazy (see the `backfill` gate below).
        // A week is well past anything the live feed treats as recent, so normal posting and
        // catch-up after a few days offline are unaffected.
        const BACKFILL_LAZY_MS: u64 = 7 * 24 * 60 * 60 * 1000;
        let mut missing: Vec<(String, String, bool)> = vec![]; // (ref, circleId, fresh)
        let mut thumbs: Vec<(String, String)> = vec![]; // declared `thumb:` companions, missing
        for c in self.social.circles() {
            let feed = self.social.feed(c.id.clone(), now_ms(), None);
            for item in feed {
                // Skip synthetic refs (geo: location pins): they carry no fetchable bytes, so a sweep
                // would fire a doomed S3-404 + ~30s iroh dial for them every cycle and never converge.
                // Skip refs the user DELIBERATELY evicted (#3 cleanup screen / #4 limit sweep): auto-
                // refetching them would silently undo the space the user just freed — they re-download
                // only on an explicit "Download" tap (media_download clears the eviction first).
                let fresh = now.saturating_sub(item.created_at) < FRESH_WINDOW_MS;
                // BACKFILL IS LAZY (Apple/Android parity). A post whose creation date is far older
                // than now did not just happen — it arrived from an archive import or a history
                // sync. Prefetching those eagerly is how ONE member importing a back-catalogue turns
                // into every other member silently downloading gigabytes: an Instagram archive is
                // ~370 posts / 1100 files / 1.2 GB, and a viewer on the DEFAULT retention
                // (0 = forever) expires none of it. Thumbs and posters still prefetch below (≤32 KB
                // by contract), so backfilled history renders as browsable tiles and the full
                // photo/video downloads when it is actually opened. Fresh posts are untouched.
                let backfill = now.saturating_sub(item.created_at) > BACKFILL_LAZY_MS;
                for t in Self::thumb_refs(&item.media) {
                    if !self.media.has(&t) && !unopenable.contains(&t) && !thumbs.iter().any(|(tt, _)| tt == &t) {
                        thumbs.push((t, c.id.clone()));
                    }
                }
                if !backfill {
                    for r in item.media {
                        if !LocalMedia::is_synthetic(&r) && !self.media.has(&r) && !self.evicted_contains(&r) && !missing.iter().any(|(rr, _, _)| rr == &r) {
                            missing.push((r, c.id.clone(), fresh));
                        }
                    }
                    // Same lazy rule as the post — a backfilled thread's attachments load on tap.
                    for cm in item.comments {
                        let cm_fresh = now.saturating_sub(cm.created_at) < FRESH_WINDOW_MS;
                        for r in cm.media {
                            if !LocalMedia::is_synthetic(&r) && !self.media.has(&r) && !self.evicted_contains(&r) && !missing.iter().any(|(rr, _, _)| rr == &r) {
                                missing.push((r, c.id.clone(), cm_fresh));
                            }
                        }
                    }
                }
            }
        }
        // THROTTLE the direct (peer) fallback. A missing ref used to be re-requested from EVERY contact
        // on every 15s sweep, so a backlog of missing media flooded the network with hundreds of thousands
        // of frames per cycle, drowning real delivery (the iOS "nothing communicates" flood). Direct-request
        // each ref at most once per 5 min, and only a handful per cycle — the relay/mailbox restore below is
        // the real, idempotent path and runs unthrottled. FRESH refs ride their own 5s..90s lane
        // instead (then park and age into this throttle naturally).
        const FAST_STEPS: [u64; 5] = [5_000, 10_000, 20_000, 45_000, 90_000];
        let mut direct_budget = 8;
        {
            let mut st = self.dyn_state.lock().unwrap();
            if st.media_req_at.len() > 4000 {
                st.media_req_at.clear(); // bound the throttle map
            }
            if st.fast_req.len() > 500 {
                st.fast_req.clear();
            }
        }
        // Thumbs: no lanes, no data-saver gate — tiny by contract; a plain 90s per-ref throttle.
        for (t, cid) in thumbs {
            {
                let mut st = self.dyn_state.lock().unwrap();
                if st.thumb_req_at.get(&t).is_some_and(|&at| now.saturating_sub(at) < 90_000) {
                    continue;
                }
                st.thumb_req_at.insert(t.clone(), now);
                if st.thumb_req_at.len() > 2000 {
                    st.thumb_req_at.clear();
                }
            }
            let me = self.clone();
            tauri::async_runtime::spawn(async move {
                if me.fetch_media_healing(&cid, &t).await {
                    me.emit_changed();
                }
            });
        }
        // Fresh refs first so the shared per-cycle budget favors the post someone is watching land.
        let mut missing = missing;
        missing.sort_by_key(|(_, _, fresh)| !*fresh);
        let mut fast_active = false;
        for (reference, circle_id, fresh) in missing {
            // Decide direct-eligibility up front (cooldown + per-cycle budget) so the spawned task only
            // peer-blasts when the gate allows; the relay restore always runs.
            let direct_ok = {
                let mut st = self.dyn_state.lock().unwrap();
                if fresh {
                    // FRESH lane: 5s/10s/20s/45s/90s, then park (the ref ages into the old lane).
                    let (n, due) = st.fast_req.get(&reference).copied().unwrap_or((0, 0));
                    if (n as usize) < FAST_STEPS.len() {
                        fast_active = true;
                    }
                    if (n as usize) < FAST_STEPS.len() && now >= due && direct_budget > 0 {
                        st.fast_req.insert(reference.clone(), (n + 1, now + FAST_STEPS[n as usize]));
                        st.media_req_at.insert(reference.clone(), now);
                        direct_budget -= 1;
                        true
                    } else {
                        false
                    }
                } else {
                    // AN ACTIVE PEER TRANSFER GETS A FASTER HEARTBEAT THAN THE 5-MINUTE COOLDOWN.
                    //
                    // That cooldown is sized for a ref nobody is sending: don't nag. A partial that is
                    // still GROWING is the opposite case — the bytes are arriving, but a serve is ONE
                    // pass over the file and then it ends, so the remainder only moves if we ask again.
                    // At five minutes a large video crawls, and if a pass ends near the tail it can
                    // look stopped entirely. (Apple: a transfer sat at 1101/1231 with the sender online
                    // and holding the rest, because nothing re-asked.) `ask_for_media` upgrades to
                    // frame 33, so each heartbeat costs the sender only the windows we still lack.
                    let in_flight = st
                        .reassembly
                        .progress(&reference)
                        .is_some_and(|held| held > 0);
                    let cooldown: u64 = if in_flight { 10_000 } else { 300_000 };
                    let stale = st.media_req_at.get(&reference).map(|&t| now.saturating_sub(t) > cooldown).unwrap_or(true);
                    if stale && direct_budget > 0 {
                        st.media_req_at.insert(reference.clone(), now);
                        direct_budget -= 1;
                        true
                    } else {
                        false
                    }
                }
            };
            let me = self.clone();
            let my_hex = my_hex.clone();
            let skip_relay = unopenable.contains(&reference);
            tauri::async_runtime::spawn(async move {
                // ALWAYS try the circle's mailbox (relay/S3) first — content-addressed + idempotent, no flood.
                //
                // Except for a ref whose stored copy we already downloaded and could not decrypt:
                // re-pulling it repairs nothing and costs a full download every sweep. That flag used
                // to gate the whole SCAN, which also silenced the peer ask below — and the peer lane
                // carries different bytes under a different key, so it is frequently the one that can
                // still succeed. (Apple hit exactly that: an own-device transfer died mid-flight at
                // 823/1231 chunks the instant a relay copy failed to open, with nothing left to
                // re-ask.) Gate the relay half only.
                if !skip_relay && me.fetch_media_healing(&circle_id, &reference).await {
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
                let mut payload = my_hex.clone().into_bytes();
                payload.extend_from_slice(reference.as_bytes());
                // NOTE: we deliberately do NOT add our own ACCOUNT node id as a request target here.
                // iroh publishes this device's endpoint under the shared account id, so dialing it is a
                // self-dial, which sends iroh's QUIC path-discovery into an unbounded loop (the multi-GB
                // leak the RelayClient guard already prevents).
                //
                // Sibling DEVICE ids are a different matter and `ask_for_media` now sends to them (see
                // `live_deliver_to_my_devices`, which excludes both the account id and this device). The
                // old claim here — that own-device media converges via the relay backfill, "the reliable
                // path" — does not survive contact: a relay copy can be incomplete, or sealed to a
                // recipient set a sibling isn't in, and then the backfill converges on nothing at all
                // while the device holding the original sits idle a metre away.
                let ids: Vec<String> = me.prefs.lock().unwrap().contacts.iter().map(|c| c.id_hex.clone()).collect();
                // A partial we already hold upgrades this to frame 33, so an interrupted transfer
                // finishes on its missing chunks instead of re-sending everything each sweep.
                me.ask_for_media(&reference, &my_hex, payload, ids);
            });
        }
        // Re-arm while any fresh-lane retry is pending — the ordinary sweeps run on a much coarser
        // cadence than 5s. Single-flight so bursts of calls can't stack timers.
        if fast_active {
            let arm = {
                let mut st = self.dyn_state.lock().unwrap();
                !std::mem::replace(&mut st.fast_sweep_armed, true)
            };
            if arm {
                let me = self.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    me.dyn_state.lock().unwrap().fast_sweep_armed = false;
                    me.request_missing_media();
                });
            }
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
    /// Forget a URL's bad window — a just-adopted relay interface must be tried immediately.
    fn clear_http_url_bad(&self, base: &str) {
        self.http_url_bad.lock().unwrap().remove(base);
    }
    fn http_key_url(base: &str, key: &str) -> String {
        format!("{}/k/{}", base.trim_end_matches('/'), key)
    }
    /// LIST URL: `GET /l/<prefix>` — signed over the raw store prefix (not the `/l/` route).
    /// Parity with iOS SharedStore / Android relayHttpList. Prefixes are ASCII store paths
    /// (`haven/mailbox/…`); only `/` and a few reserved chars need encoding.
    fn http_list_url(base: &str, prefix: &str) -> String {
        let enc = prefix
            .replace('%', "%25")
            .replace('/', "%2F")
            .replace(' ', "%20")
            .replace('?', "%3F")
            .replace('#', "%23");
        format!("{}/l/{}", base.trim_end_matches('/'), enc)
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

    /// Delta-LIST (the radio saver): echo the last-seen `X-Haven-List-Digest` for this prefix and
    /// an UNCHANGED key set comes back as a bodiless 204 (`keys == None`) instead of the same list
    /// again. A 200 carries the fresh keys plus the digest to echo next time. A relay that doesn't
    /// speak the header simply never answers 204 and never hands us a digest — today's behavior.
    async fn http_list_delta(
        &self,
        base: &str,
        token: &str,
        prefix: &str,
        digest: Option<&str>,
    ) -> Result<(Option<Vec<String>>, Option<String>), RelayErr> {
        let auth = self.http_auth(token, "GET", prefix, b"").ok_or(RelayErr::Unreachable)?;
        let mut req = self
            .http
            .get(Self::http_list_url(base, prefix))
            .header("authorization", auth);
        if let Some(d) = digest.filter(|d| !d.is_empty()) {
            req = req.header(haven_net::httprelay::LIST_DIGEST_HEADER, d);
        }
        let resp = req.send().await.map_err(|_| RelayErr::Unreachable)?;
        let resp_digest = resp
            .headers()
            .get(haven_net::httprelay::LIST_DIGEST_HEADER)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        match resp.status().as_u16() {
            204 => Ok((None, resp_digest)), // nothing new — skip the GETs
            200..=299 => {
                let text = resp.text().await.map_err(|_| RelayErr::Unreachable)?;
                Ok((
                    Some(
                        text.lines()
                            .map(str::trim)
                            .filter(|l| !l.is_empty())
                            .map(str::to_string)
                            .collect(),
                    ),
                    resp_digest,
                ))
            }
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
    /// PUT one key. `Ok` = stored; `Err(Forbidden)` = the relay is up and will take this write the
    /// moment it knows our device; `Err(Unreachable)` = a genuine transport failure. The same
    /// three-way split `http_get` needs, for the mirror-image reason: a device that has never been
    /// authorized cannot upload at all, and a 403 read as an outage backs off the very relay the write
    /// needs — so the blob never lands, and the damage surfaces much later as a fetch that genuinely
    /// 404s. A real absence, manufactured by a permissions problem.
    async fn http_put(&self, base: &str, token: &str, key: &str, body: Vec<u8>) -> Result<(), RelayErr> {
        // Digest over the EXACT bytes sent — `.body(body)` puts this buffer on the wire verbatim.
        let auth = self.http_auth(token, "PUT", key, &body).ok_or(RelayErr::Unreachable)?;
        let resp = self
            .http
            .put(Self::http_key_url(base, key))
            .header("authorization", auth)
            .header("content-type", "application/octet-stream")
            .body(body)
            .send()
            .await
            .map_err(|_| RelayErr::Unreachable)?;
        match resp.status().as_u16() {
            200..=299 => Ok(()),
            401 | 403 => Err(RelayErr::Forbidden),
            _ => Err(RelayErr::Unreachable),
        }
    }

    async fn upload_media(self: &Arc<Self>, circle_id: &str, reference: &str) -> bool {
        if self.upload_media_inner(circle_id, reference, false).await {
            return true;
        }
        // Nothing took the blob and at least one relay REFUSED it rather than being down: publish our
        // roster to the refusers and try once more, exactly as `fetch_media_healing` does for the read
        // side. A device that has never been authorized anywhere otherwise never gets its FIRST blob up
        // — and because that upload failure is invisible, the damage surfaces much later as a fetch
        // that genuinely 404s, an absence manufactured entirely by a permissions problem.
        if self.heal_forbidden_relays().await {
            return self.upload_media_inner(circle_id, reference, false).await;
        }
        false
    }

    /// PRIORITY LANE for a just-authored event's media: upload thumbs first, then posters, then
    /// content (see `upload_order` — the placeholder-feeding bytes land before the big blob starts),
    /// and ANNOUNCE each fresh blob to the circle the moment it lands (frame 32 + a silent push
    /// wake) so members prefetch NOW instead of on their next missing-media sweep. Mirrors iOS
    /// `MediaBackupQueue`'s priority lane + `announceMediaLanded`.
    fn upload_authored_media(self: &Arc<Self>, circle_id: String, media: Vec<String>) {
        if media.is_empty() {
            return;
        }
        let ordered = Self::upload_order(&media);
        let authored_at = now_ms();
        let me = self.clone();
        tauri::async_runtime::spawn(async move {
            for r in ordered {
                let landed = me.upload_media(&circle_id, &r).await;
                // Only a FRESH post's landing is worth announcing — a slow backlog drain isn't news.
                if landed && now_ms().saturating_sub(authored_at) < 600_000 {
                    me.announce_media_landed(&circle_id, &r);
                }
            }
        });
    }

    /// Author push-ahead (frame 32): tell every member a fresh post's blob is now on a relay, plus
    /// a silent push wake so a backgrounded phone fetches before its user opens the app. Unsolicited
    /// on the receiving side — their `handle_media_available` prefetches bounded + deduped.
    fn announce_media_landed(self: &Arc<Self>, circle_id: &str, reference: &str) {
        let post_id = self
            .social
            .feed(circle_id.to_string(), now_ms(), None)
            .into_iter()
            .find(|i| {
                i.is_me
                    && (i.media.iter().any(|m| m == reference)
                        || Self::thumb_refs(&i.media).iter().any(|t| t == reference)
                        || i.media
                            .iter()
                            .filter_map(|m| haven_p2p::mediavariants::parse_poster(m))
                            .any(|(_, po)| po == reference))
            })
            .map(|i| i.id)
            .unwrap_or_default();
        let body = self.media_frame_body(reference, circle_id, &post_id);
        for member in self.social.contact_node_ids(circle_id.to_string()) {
            self.send_call_frame(wire::MEDIA_AVAILABLE, &body, &member);
            self.push_wake(&member, None, None, true);
        }
        log::info!(
            "media-landed {} announced to circle {}",
            &reference.chars().take(10).collect::<String>(),
            &circle_id.chars().take(12).collect::<String>()
        );
    }

    /// `force` = the 1.0.8 media-recovery path: skip every "already held?" probe and the persisted
    /// ledger, and OVERWRITE the blob on every reachable destination. A blob is content-addressed +
    /// write-once, so a 1.0.7 build that device-signed it froze it forever; the only cure is to
    /// re-seal (now account-signed, done by the core fix) and overwrite the stored copy.
    ///
    /// Returns whether some destination now holds the blob (a probe hit, or — under `force` — accepted
    /// the freshly re-sealed overwrite). The recovery migration uses this to know a ref is repaired.
    async fn upload_media_inner(self: &Arc<Self>, circle_id: &str, reference: &str, force: bool) -> bool {
        self.upload_media_inner_reseal(circle_id, reference, force, false).await
    }

    /// `reseal` seals afresh from the plaintext rather than re-sending the stored seal. `force` only
    /// bypasses the "already uploaded" ledger — it re-PUTs the SAME bytes, which repairs nothing
    /// when what changed is the RECIPIENT SET. Media is sealed once and never re-sealed, so a member
    /// who joined after a blob was posted is not one of its recipients and can never open it;
    /// answering their ask with the old seal reports success while fixing nothing.
    async fn upload_media_inner_reseal(
        self: &Arc<Self>,
        circle_id: &str,
        reference: &str,
        force: bool,
        reseal: bool,
    ) -> bool {
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
                    Ok(Some(head)) => {
                        // COMPLETE, not merely present — see `completeness_probe_key`.
                        let complete = match Self::completeness_probe_key(reference, &head) {
                            None => true,
                            Some(k) => matches!(s3.get(&k).await, Ok(Some(_))),
                        };
                        if complete { self.mark_media_backed_up("s3", reference); landed = true; }
                        else {
                            log::info!("backup probe ref={reference} s3: manifest present but chunks INCOMPLETE — re-uploading");
                            s3_needs = true;
                        }
                    }
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
            let http_iface = self.relay_http_reachable(&node_hex);
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
                            Ok(Some(head)) => {
                                self.mark_relay_ok(&node_hex);
                                // COMPLETE, not merely present — see `completeness_probe_key`. The
                                // extra GET of the final window is paid at most once per (ref, relay):
                                // a copy that checks out goes into the ledger and is never re-probed.
                                let complete = match Self::completeness_probe_key(reference, &head) {
                                    None => true,
                                    Some(k) => matches!(self.http_get(base, &token, &k).await, Ok(Some(_))),
                                };
                                if complete {
                                    self.mark_media_backed_up(&node_hex, reference);
                                    landed = true;
                                } else {
                                    log::info!("backup probe ref={reference} relay={}: manifest present but chunks INCOMPLETE — re-uploading",
                                               &node_hex[..8.min(node_hex.len())]);
                                    http_uploads.push((node_hex.clone(), base.clone(), token.clone()));
                                }
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
                } else {
                    // An Err here is a FAILED DIAL, not "the relay lacks the blob" — the two used to
                    // be conflated by `unwrap_or(false)`, which queued an upload the put then bailed
                    // on, burning a full re-seal (~2x file size) every pass. Unreachable ⇒ skip this
                    // relay and retry next pass, after its backoff. (Parity with the Apple path.)
                    match client.has(key.clone()).await {
                        Ok(true) => {
                            self.mark_relay_ok(&node_hex);
                            // COMPLETE, not merely present — see `completeness_probe_key`. `has`
                            // carries no bytes, so the manifest is only fetched once chunk 0 proves
                            // the blob is chunked (and its manifest key therefore tiny rather than a
                            // whole media file).
                            let chunked = client
                                .has(Self::media_chunk_key(reference, 0))
                                .await
                                .unwrap_or(false);
                            let head = if chunked { client.get(key.clone()).await } else { None };
                            let probe = head
                                .as_deref()
                                .and_then(|h| Self::completeness_probe_key(reference, h));
                            let complete = match probe {
                                None => true,
                                Some(k) => client.has(k).await.unwrap_or(false),
                            };
                            if complete {
                                self.mark_media_backed_up(&node_hex, reference);
                                landed = true;
                            } else {
                                log::info!("backup probe ref={reference} relay={}: manifest present but chunks INCOMPLETE — re-uploading",
                                           &node_hex[..8.min(node_hex.len())]);
                                dial_uploads.push((node_hex.clone(), client.clone()));
                            }
                        }
                        Ok(false) => {
                            self.mark_relay_ok(&node_hex);   // it answered — it just lacks it
                            dial_uploads.push((node_hex.clone(), client));
                        }
                        Err(e) => {
                            log::debug!("backup probe SKIP ref={reference} relay={} — dial failed: {e}",
                                        &node_hex[..8.min(node_hex.len())]);
                            self.mark_relay_fail(&node_hex);
                        }
                    }
                }
            }
        }
        if !s3_needs && http_uploads.is_empty() && dial_uploads.is_empty() {
            self.flush_media_backed_up();
            return landed;
        }

        // ---- Read the sealed blob, now known to be needed by at least one reachable destination.
        // A repair must produce NEW bytes: open our own copy and seal it again so the fresh envelope
        // addresses the circle's CURRENT members (and carries the epoch entry). Re-sending
        // raw_sealed() hands back the very recipient list that already excluded the asker.
        let resealed: Option<Vec<u8>> = if reseal {
            match self.media.load_any_circle(&self.social, reference) {
                Some(plain) => match self.social.seal_circle_media(circle_id.to_string(), plain) {
                    Ok(fresh) => {
                        self.media.write_raw_sealed(reference, &fresh);
                        log::info!("reseal {}: sealed afresh for the circle's current members ({} B)",
                                   short(reference), fresh.len());
                        Some(fresh)
                    }
                    Err(e) => { log::warn!("reseal {} failed: {e} — sending the stored seal", short(reference)); None }
                },
                None => { log::info!("reseal {}: cannot open our own copy — sending the stored seal", short(reference)); None }
            }
        } else { None };
        let Some(blob) = resealed.or_else(|| self.media.raw_sealed(reference)) else { return landed };
        let chunked = blob.len() > MEDIA_CHUNK_BYTES;
        // Identity of the exact bytes being uploaded. A destination's stored windows may only be
        // skipped if WE put them there from THESE bytes: the at-rest blob for a ref is not immutable
        // (re-storing the same plaintext, or repairing a blob that won't decrypt, re-seals it under the
        // same ref with a fresh nonce and usually an identical length), and another device of this
        // account may have uploaded the same ref from a seal of its own. Splicing across two seals
        // yields a blob of exactly the right length that decrypts to nothing — silently, and
        // permanently, since the key is content-addressed and write-once. See `mediaresume`.
        let seal_fp = if chunked { crate::mediaresume::seal_fingerprint(&blob) } else { String::new() };
        let window_count = crate::mediaresume::upload_windows(blob.len(), MEDIA_CHUNK_BYTES).len();
        // S3/HTTP bucket FIRST — the DEFAULT media transport. Plain HTTPS traverses any NAT, whereas
        // the iroh blob ALPN (haven/blob/1) drops its outbound datagrams over a pure-relay cross-NAT
        // path (noq/iroh fork bug): blob transfers that must cross a NAT stall and die even while
        // messaging works over the same relay path.
        if s3_needs {
            if let Some(s3) = self.s3_client().await {
                let ok = if chunked {
                    let mut sizes = Vec::new();
                    let mut all = true;
                    // Borrowed, not moved: `async move` on the probe closure would swallow the client
                    // the upload loop below still needs.
                    let s3_ref = &s3;
                    let skip = self
                        .resume_skip("s3", reference, &seal_fp, window_count, force, |i| async move {
                            s3_ref.get(&Self::media_chunk_key(reference, i)).await.ok().flatten().is_some()
                        })
                        .await;
                    for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                        if i >= skip
                            && s3.put(&Self::media_chunk_key(reference, i), slice).await.is_err()
                        {
                            all = false;
                            break;
                        }
                        sizes.push(slice.len());
                        self.record_media_upload_progress("s3", reference, &seal_fp, i + 1);
                    }
                    let done = all && s3.put(&key, &Self::make_manifest(&sizes)).await.is_ok();
                    if done {
                        self.record_media_upload_progress("s3", reference, &seal_fp, 0);
                    }
                    done
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
            let res = if chunked {
                let mut sizes = Vec::new();
                let mut acc = Ok(());
                // A relay already holding a leading run of windows (an earlier attempt that was cut
                // short) is asked rather than re-sent: `<ref>.p/<i>` is content-addressed, so the bytes
                // up there are already ours. The manifest is still written at the end — it is what makes
                // the blob readable, and an interrupted attempt never got that far.
                let (base_ref, token_ref) = (&base, &token);
                let skip = self
                    .resume_skip(&node_hex, reference, &seal_fp, window_count, force, |i| async move {
                        self.http_get(base_ref, token_ref, &Self::media_chunk_key(reference, i))
                            .await
                            .ok()
                            .flatten()
                            .is_some()
                    })
                    .await;
                for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                    if i >= skip {
                        acc = self.http_put(&base, &token, &Self::media_chunk_key(reference, i), slice.to_vec()).await;
                        if acc.is_err() {
                            break;
                        }
                    }
                    sizes.push(slice.len());
                    self.record_media_upload_progress(&node_hex, reference, &seal_fp, i + 1);
                }
                match acc {
                    Ok(()) => {
                        let r = self.http_put(&base, &token, &key, Self::make_manifest(&sizes)).await;
                        if r.is_ok() {
                            self.record_media_upload_progress(&node_hex, reference, &seal_fp, 0);
                        }
                        r
                    }
                    Err(e) => Err(e),
                }
            } else {
                self.http_put(&base, &token, &key, blob.clone()).await
            };
            match res {
                Ok(()) => {
                    self.mark_relay_ok(&node_hex);
                    self.mark_media_backed_up(&node_hex, reference);
                    landed = true;
                }
                // Reachable and healthy — it just doesn't know this device yet. Neither remedy below
                // applies: backing the URL off strands the blob on a relay that would store it, and the
                // iroh dial goes through the SAME membership gate, so it only repeats the refusal.
                // Record it and let the heal + retry in `upload_media` publish our roster first.
                Err(RelayErr::Forbidden) => {
                    self.note_refused(&node_hex, &format!("media upload {}", &reference.chars().take(10).collect::<String>()));
                }
                Err(RelayErr::Unreachable) => {
                    self.mark_http_url_bad(&base);
                    if let Some(client) = self.relay_client_for(&node_hex).await {
                        dial_uploads.push((node_hex, client));
                    }
                }
            }
        }
        for (node_hex, client) in dial_uploads {
            let res: Result<(), ()> = async {
                if chunked {
                    let mut sizes = Vec::new();
                    // `has` is an exact, cheap existence check here — no download, unlike the S3/HTTP probes.
                    let client_ref = &client;
                    let skip = self
                        .resume_skip(&node_hex, reference, &seal_fp, window_count, force, |i| async move {
                            // A failed probe means "unknown", and the safe reading of unknown here is
                            // "not stored" — re-putting a window we already have is idempotent, while
                            // skipping one we don't have leaves a hole that reassembles to garbage.
                            client_ref.has(Self::media_chunk_key(reference, i)).await.unwrap_or(false)
                        })
                        .await;
                    for (i, slice) in blob.chunks(MEDIA_CHUNK_BYTES).enumerate() {
                        if i >= skip {
                            client.put(Self::media_chunk_key(reference, i), slice.to_vec()).await.map_err(|_| ())?;
                        }
                        sizes.push(slice.len());
                        self.record_media_upload_progress(&node_hex, reference, &seal_fp, i + 1);
                    }
                    client.put(key.clone(), Self::make_manifest(&sizes)).await.map_err(|_| ())?;
                    self.record_media_upload_progress(&node_hex, reference, &seal_fp, 0);
                    Ok(())
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

    // ---- Resumable chunked RESTORE bookkeeping ------------------------------------------------
    // A chunked relay download used to be all-or-nothing: any chunk miss threw the part file away,
    // so a 600 MB video over a flaky tunnel restarted from chunk 0 every retry — the mirror image
    // of the upload-resume problem (`mediaresume` fixed the peer path). Chunks are fetched IN
    // ORDER and appended, so resume state is just "how many leading chunks are in the part file",
    // persisted in a sidecar next to it. The manifest's chunk count keys validity: a mismatch
    // (a different seal uploaded meanwhile) discards the partial. iOS SharedStore parity.

    fn restore_meta_path(part: &std::path::Path) -> std::path::PathBuf {
        let name = part.file_name().and_then(|n| n.to_str()).unwrap_or("part");
        part.with_file_name(format!("{name}.resume"))
    }

    /// How many leading chunks of `reference` are already on disk (0 = no valid partial).
    /// Identity of the exact sealed bytes a manifest describes.
    ///
    /// Two seals of the SAME media are not byte-identical — the envelope carries per-recipient key
    /// material and a fresh nonce — and their chunk COUNT is normally identical, so the count cannot
    /// tell them apart. A partial built from one seal must never be continued from another: the
    /// result reassembles to a plausible length and decrypts to nothing. (Observed on Apple: windows
    /// 0–2 from one relay's seal plus 3–4 from another's produced 40,352,062 bytes against a manifest
    /// declaring 40,342,326, and failed to open for every circle.) The manifest encodes the per-window
    /// sizes and the total, so hashing it distinguishes the seals. Mirror of iOS
    /// `SharedStore.manifestFingerprint`.
    fn manifest_fingerprint(head: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        let d = Sha256::digest(head);
        d.iter().take(8).map(|b| format!("{b:02x}")).collect()
    }

    /// How many leading windows of THIS seal are already on disk. `fp` is what makes that "of this
    /// seal" rather than merely "of something with the same number of windows" — see
    /// [`Self::manifest_fingerprint`]. A sidecar written by an older build carries no fingerprint and
    /// therefore fails the match and restarts, which is the safe direction.
    fn restore_resume_load(&self, reference: &str, chunks: usize, fp: &str) -> usize {
        let part = self.media.sealed_part_path(reference);
        let Ok(txt) = std::fs::read_to_string(Self::restore_meta_path(&part)) else { return 0 };
        let mut it = txt.split_whitespace();
        let (Some(c), Some(g)) = (
            it.next().and_then(|v| v.parse::<usize>().ok()),
            it.next().and_then(|v| v.parse::<usize>().ok()),
        ) else {
            return 0;
        };
        let recorded_fp = it.next().unwrap_or("");
        if c == chunks && recorded_fp == fp && g > 0 && g <= chunks && part.exists() {
            g
        } else {
            0
        }
    }

    fn restore_resume_save(&self, reference: &str, chunks: usize, got: usize, fp: &str) {
        let part = self.media.sealed_part_path(reference);
        let _ = std::fs::write(Self::restore_meta_path(&part), format!("{chunks} {got} {fp}"));
    }

    fn restore_resume_clear(&self, reference: &str) {
        let part = self.media.sealed_part_path(reference);
        let _ = std::fs::remove_file(Self::restore_meta_path(&part));
    }

    /// Open (or start) the resumable part file for `reference` given the manifest's chunk count.
    /// Returns (part path, chunks already held).
    fn restore_resume_open(&self, reference: &str, chunks: usize, fp: &str) -> (std::path::PathBuf, usize) {
        let have = self.restore_resume_load(reference, chunks, fp);
        if have == 0 {
            (self.media.new_sealed_part(reference), 0)
        } else {
            log::info!(
                "media restore {}: resuming at chunk {have}/{chunks}",
                &reference.chars().take(12).collect::<String>()
            );
            (self.media.sealed_part_path(reference), have)
        }
    }

    async fn fetch_media_from_relay(self: &Arc<Self>, circle_id: &str, reference: &str) -> bool {
        let key = Self::media_key(reference);
        // S3/HTTP bucket FIRST — the DEFAULT media transport (see upload_media): an iroh blob dial
        // that must cross a NAT stalls ~30s and dies, so the bucket is tried before any dial.
        if let Some(s3) = self.s3_client().await {
            if let Ok(Some(head)) = s3.get(&key).await {
                if let Some(count) = Self::parse_manifest(&head) {
                    let fp = Self::manifest_fingerprint(&head);
                    let (part, have) = self.restore_resume_open(reference, count, &fp);
                    let mut ok = true;
                    for i in have..count {
                        match s3.get(&Self::media_chunk_key(reference, i)).await {
                            Ok(Some(chunk)) if self.media.append_sealed_part(&part, &chunk) => {
                                self.restore_resume_save(reference, count, i + 1, &fp);
                            }
                            _ => { ok = false; break; }
                        }
                    }
                    if ok && self.media.adopt_sealed_part(reference, &part) {
                        self.restore_resume_clear(reference);
                        return true;
                    }
                    // KEEP the partial + sidecar — the next attempt resumes where this one stalled.
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
            let http_iface = self.relay_http_reachable(&node_hex);
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
                    let fp = Self::manifest_fingerprint(&head);
                                let (part, have) = self.restore_resume_open(reference, count, &fp);
                                let mut ok = true;
                                for i in have..count {
                                    match self.http_get(base, &token, &Self::media_chunk_key(reference, i)).await {
                                        Ok(Some(chunk)) if self.media.append_sealed_part(&part, &chunk) => {
                                            self.restore_resume_save(reference, count, i + 1, &fp);
                                        }
                                        _ => { ok = false; break; }
                                    }
                                }
                                if ok && self.media.adopt_sealed_part(reference, &part) {
                                    self.restore_resume_clear(reference);
                                    self.mark_relay_ok(&node_hex);
                                    return true;
                                }
                                // Partial + sidecar kept — the retry resumes on the missing chunks.
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
                    let fp = Self::manifest_fingerprint(&head);
                        // Stream each chunk to the resumable part file on disk — never the whole
                        // blob in RAM, never chunk 0 again after a stall.
                        let (part, have) = self.restore_resume_open(reference, count, &fp);
                        let mut ok = true;
                        for i in have..count {
                            match client.get(Self::media_chunk_key(reference, i)).await {
                                Some(chunk) if self.media.append_sealed_part(&part, &chunk) => {
                                    self.restore_resume_save(reference, count, i + 1, &fp);
                                }
                                _ => { ok = false; break; }
                            }
                        }
                        if ok && self.media.adopt_sealed_part(reference, &part) {
                            self.restore_resume_clear(reference);
                            self.mark_relay_ok(&node_hex);
                            return true;
                        }
                        // Partial + sidecar kept for the next attempt.
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
            // A full miss is ALSO the signature of a relay whose HTTP front door we can't use
            // (rotated tunnel / never learned): the blob may sit on a relay we only failed to
            // ASK properly. Try to fetch each dest relay's self-published interface over iroh —
            // if one lands, the retry path finds the blob and the URL gets re-announced. (Our own
            // hosted relay is skipped by relay_client_for's self-guard; media_dests excludes s3.)
            for node_hex in self.media_dests(circle_id) {
                self.refresh_relay_interface_if_needed(&node_hex);
            }
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
            return self.accept_fetched_blob(reference);
        }
        if self.heal_forbidden_relays().await && self.fetch_media_from_relay(circle_id, reference).await {
            return self.accept_fetched_blob(reference);
        }
        false
    }

    /// Gate a just-fetched sealed blob on it actually OPENING before we call the fetch a success.
    ///
    /// A relay serves opaque bytes, so "the GET returned 200" is not "the media arrived". When the
    /// bytes are there and cannot be decrypted for ANY of our circles, the stored copy is BAD, not
    /// missing — and until now that was a permanent, silent dead end on this platform: the unopenable
    /// blob was written to disk, `LocalMedia::has` began answering true, the ref dropped out of
    /// `request_missing_media`, and the post kept a broken placeholder forever with nothing logged.
    ///
    /// The most likely way a blob gets into this state is a resumed chunked upload that stitched
    /// windows from two DIFFERENT seals: sealing is not byte-stable (per-recipient key material plus a
    /// fresh nonce), so the result reassembles to exactly the right length and decrypts to nothing.
    /// That is fixed at the source now (a seal is reused across retries), but blobs written during the
    /// window are still out there.
    ///
    /// So: say what actually happened, drop the bad bytes rather than let them masquerade as held
    /// media, and remember the ref for this session so the 20-second sweep stops re-downloading the
    /// same unopenable blob every cycle. Only the AUTHOR can really repair it — they still hold the
    /// plaintext and their forced re-seal (`maybe_reseal_own_media`) overwrites the stored copy — and
    /// because the skip is in-session only, a repaired blob is picked up on the next run.
    /// iOS `SharedStore.restore`'s "found … but OPEN FAILED" branch.
    fn accept_fetched_blob(self: &Arc<Self>, reference: &str) -> bool {
        let Some(path) = self.media.sealed_path(reference) else { return false };
        let circles = self.social.circles();
        if circles.is_empty() {
            return true; // nothing to judge it against — under-claiming corruption is the safe direction
        }
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        // Above ~64 MB decrypt file→file (native, streaming) rather than pulling the blob — and a copy
        // of it per circle — into RAM. "Too big to check in memory" must never become "declared
        // corrupt": that would delete perfectly good video.
        let opened = if size > 64 * 1024 * 1024 {
            let probe = path.with_extension("openprobe");
            let ok = circles.iter().any(|c| {
                self.social.open_circle_media_file(
                    c.id.clone(),
                    path.to_string_lossy().into_owned(),
                    probe.to_string_lossy().into_owned(),
                )
            });
            let _ = std::fs::remove_file(&probe);
            ok
        } else {
            let Some(stored) = self.media.raw_sealed(reference) else { return false };
            circles
                .iter()
                .any(|c| self.social.open_circle_media(c.id.clone(), stored.clone()).is_some())
        };
        if opened {
            return true;
        }
        let short = reference.chars().take(12).collect::<String>();
        log::warn!(
            "media restore {short}: found ({size}B) but OPEN FAILED for all {} circles — the stored copy is bad, not missing; dropping it and not re-fetching this session",
            circles.len()
        );
        self.media.delete(reference);
        self.dyn_state.lock().unwrap().media_unopenable.insert(reference.to_string());
        false
    }

    /// Ask `targets` for `reference`: frame 33 with our bitmap when we hold a partial of it, else the
    /// plain frame 3 the callers already built.
    ///
    /// The frame-3 path is byte-for-byte what it always was, deliberately — a FIRST request has no
    /// bitmap to send, and keeping it identical is what keeps the common case compatible with every
    /// peer in the field. Only a RE-request for a ref we're part-way through upgrades to 33.
    ///
    /// An un-upgraded peer drops frame 33 on the floor and says nothing, so silence is the only
    /// signal we get: fall back to a full frame 3 after 8s if no chunk arrived. That fallback is
    /// bounded to ONE pending task per ref — never one per incoming request, or a peer could make us
    /// spawn tasks by re-asking.
    fn ask_for_media(self: &Arc<Self>, reference: &str, my_hex: &str, plain: Vec<u8>, targets: Vec<String>) {
        // MY OWN DEVICES GET THE ASK TOO. `targets` is the contact list, and my own devices are not
        // contacts — they live in the account's device roster. Without this a desktop and a phone on
        // the same account could each be holding what the other needs, both online, with no lane
        // between them: the fetch just kept "asking peers" that could never answer. (Apple parity:
        // `FeedStore.askForMedia`; Android: `askForMedia`.)
        let hint = self.dyn_state.lock().unwrap().reassembly.resume_hint(reference);
        let Some((total, got)) = hint else {
            for id_hex in &targets {
                self.send_frame(wire::MEDIA_REQ, &plain, id_hex);
            }
            self.live_deliver_to_my_devices(wire::MEDIA_REQ, &plain);
            return;
        };
        let before = got.len() as u32;
        let resume = wire::resume_frame(my_hex, reference, total, &got);
        log::debug!(
            "media RESUME asking for {}: have {}/{}",
            &reference[..reference.len().min(12)],
            before,
            total
        );
        for id_hex in &targets {
            self.send_frame(wire::MEDIA_RESUME_REQ, &resume, id_hex);
        }
        self.live_deliver_to_my_devices(wire::MEDIA_RESUME_REQ, &resume);
        if !self.dyn_state.lock().unwrap().resume_fallback.insert(reference.to_string()) {
            return; // a fallback for this ref is already armed
        }
        let me = self.clone();
        let reference = reference.to_string();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(8)).await;
            let progressed = {
                let mut st = me.dyn_state.lock().unwrap();
                st.resume_fallback.remove(&reference);
                st.reassembly.progress(&reference).map(|n| n != before).unwrap_or(true)
            };
            if progressed || me.media.has(&reference) {
                return; // chunks arrived (or the whole thing did) — the peer understood 33
            }
            log::debug!(
                "media RESUME {}: no answer to frame 33 — falling back to a full request",
                &reference[..reference.len().min(12)]
            );
            for id_hex in &targets {
                me.send_frame(wire::MEDIA_REQ, &plain, id_hex);
            }
            me.live_deliver_to_my_devices(wire::MEDIA_REQ, &plain);
        });
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
        // They had to come to US for bytes we already backed up — so no relay served them. That is a
        // signal about our own backup, not just a request to answer.
        self.reverify_backup_after_direct_ask(&reference).await;
        let Some(bytes) = self.media.load_any_circle(&self.social, &reference) else { return };
        // Frame 3 means "send everything" and always has — see `wire::MEDIA_RESUME_REQ`.
        self.serve_chunks_once(&reference, &requester, &bytes, None).await;
    }

    /// A peer asked us DIRECTLY for a blob we hold — meaning they could not fetch it from any relay we
    /// share. That is the only signal in the system that a STORED copy has gone bad, and until now
    /// nothing listened to it: the backup ledger is write-once, so a relay copy that is missing chunks
    /// stays missing forever while this device goes on showing the post as safely backed up.
    ///
    /// Throttled to once an hour per ref — an unreachable peer re-asks on a timer, and a re-verify
    /// must never become a re-upload storm. Deliberately not a FORCED backup: this is a probe, and it
    /// re-uploads only the windows a destination actually turns out to lack (see
    /// [`Self::completeness_probe_key`]). Apple parity: `FeedStore.reverifyBackupAfterDirectAsk`;
    /// Android: `reverifyBackupAfterDirectAsk`.
    async fn reverify_backup_after_direct_ask(self: &Arc<Self>, reference: &str) {
        const INTERVAL_MS: u64 = 3_600_000;
        let now = now_ms();
        {
            let mut st = self.dyn_state.lock().unwrap();
            if let Some(at) = st.backup_reverified_at.get(reference) {
                if now.saturating_sub(*at) < INTERVAL_MS {
                    return;
                }
            }
            st.backup_reverified_at.insert(reference.to_string(), now);
            if st.backup_reverified_at.len() > 2_000 {
                st.backup_reverified_at.clear();
            }
        }
        // The circle whose feed references this blob — the one whose relays should hold its bytes.
        let mut circle_id: Option<String> = None;
        'outer: for c in self.social.circles() {
            for item in self.social.feed(c.id.clone(), now_ms(), None) {
                let hit = item.media.iter().any(|m| m == reference)
                    || item.comments.iter().any(|cm| cm.media.iter().any(|m| m == reference));
                if hit {
                    circle_id = Some(c.id.clone());
                    break 'outer;
                }
            }
        }
        let Some(circle_id) = circle_id else { return };
        self.forget_media_backed_up_ref(reference); // the verdict we're re-testing
        log::info!(
            "media REQ {}: asked directly for media we backed up — re-probing its relay copies",
            &reference[..reference.len().min(10)]
        );
        self.upload_media(&circle_id, reference).await;
    }

    /// Frame 33 — a RESUME request carrying a bitmap of what the requester already holds, so the
    /// serve can skip it. A transfer that died on chunk 1,599 of 1,600 costs one chunk to finish
    /// rather than the whole file again. See `wire::MEDIA_RESUME_REQ` for why frame 3 is untouched.
    async fn handle_media_resume_request(self: &Arc<Self>, body: &[u8]) {
        let Some(req) = wire::parse_resume_frame(body) else { return };
        if !self.media.has(&req.reference) {
            return;
        }
        let Some(bytes) = self.media.load_any_circle(&self.social, &req.reference) else { return };
        let total = ((bytes.len() + MEDIA_CHUNK_SIZE - 1) / MEDIA_CHUNK_SIZE).max(1) as u32;
        // A total that disagrees with ours means their partial was built against different bytes, so
        // their bitmap indexes something else and honouring it would leave permanent holes. Send the
        // whole file and let the content-address check at adoption sort out which copy is real.
        // Expanding their bitmap only HERE — after the totals agree — is what bounds the work by a
        // file we hold rather than by the chunk count the peer declared (see wire::ResumeReq).
        let missing: HashSet<u32> = if total == req.total {
            let theirs = wire::bitmap_indices(&req.bitmap, total);
            (0..total).filter(|i| !theirs.contains(i)).collect()
        } else {
            (0..total).collect()
        };
        if missing.is_empty() {
            return; // they have it all; the last chunk is presumably still in flight
        }
        log::debug!(
            "media RESUME {}: {}/{} chunks still needed by {}",
            &req.reference[..req.reference.len().min(12)],
            missing.len(),
            total,
            &req.requester_hex[..8]
        );
        self.serve_chunks_once(&req.reference, &req.requester_hex, &bytes, Some(&missing)).await;
    }

    /// Run the ONE serve for this (ref, requester), or do nothing if one is already streaming.
    /// See [`DynState::chunk_serving`] for why doing nothing is the correct answer mid-transfer.
    async fn serve_chunks_once(
        self: &Arc<Self>,
        reference: &str,
        requester_hex: &str,
        bytes: &[u8],
        missing: Option<&HashSet<u32>>,
    ) {
        let key = format!("{reference}|{requester_hex}");
        {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.chunk_serving.insert(key.clone()) {
                log::debug!(
                    "media serve {}: already streaming to {}, ignoring",
                    &reference[..reference.len().min(12)],
                    &requester_hex[..requester_hex.len().min(8)]
                );
                return;
            }
        }
        self.send_media_chunks(reference, bytes, requester_hex, missing).await;
        // Cleared however the serve ends — a seal failure returns early mid-file, and leaving the key
        // behind would lock this pair out of ever being served again this session.
        self.dyn_state.lock().unwrap().chunk_serving.remove(&key);
    }

    /// Send a frame and WAIT for it, rather than spawning a task that outlives the caller.
    ///
    /// [`Self::send_frame`] spawns per target, which is right for one-off frames and very wrong for a
    /// serve loop: a 200 MB video is ~6,400 chunks, each spawning a task per device holding its own
    /// 32 KB frame clone. Nothing awaited them, so the loop finished in milliseconds and left tens of
    /// thousands of queued sends holding the whole file in memory — an unbounded backlog that gets
    /// worse the slower the link is.
    ///
    /// Awaiting makes the serve loop self-pacing: it cannot outrun the transport, memory stays at one
    /// chunk, and the rate follows the actual link instead of a fixed sleep (which would be slower
    /// than necessary on a fast link and still unbounded on a slow one).
    async fn send_frame_awaited(self: &Arc<Self>, t: u8, payload: &[u8], to_node_hex: &str) {
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        let frame = wire::frame(t, payload);
        let mut targets = self.social.device_node_ids_for(to_node_hex.to_string());
        if targets.is_empty() {
            targets.push(to_node_hex.to_string());
        }
        for h in self.device_hints_for(to_node_hex) {
            if !targets.iter().any(|t| t.eq_ignore_ascii_case(&h)) {
                targets.push(h);
            }
        }
        for to in targets {
            if let Err(e) = node.send_to_node(to.clone(), frame.clone()).await {
                log::debug!("send type={t} to {} failed: {e}", &to.chars().take(8).collect::<String>());
            }
        }
    }

    /// Stream a media file to the requester as individually-sealed 32 KB chunks.
    ///
    /// `missing` (from a resume request, frame 33) restricts the stream to the chunks the requester
    /// says it still needs. Skipping one is FREE — no seal, no frame, no send — which is the whole
    /// economy of resume. `None` sends everything, which is what a frame-3 first request means.
    async fn send_media_chunks(
        self: &Arc<Self>,
        reference: &str,
        bytes: &[u8],
        requester_hex: &str,
        missing: Option<&HashSet<u32>>,
    ) {
        let total = ((bytes.len() + MEDIA_CHUNK_SIZE - 1) / MEDIA_CHUNK_SIZE).max(1) as u32;
        let ref_bytes = reference.as_bytes();
        // Own-device (the requester is MY OWN account) → seal each chunk with the symmetric account-key, which
        // a sibling can always open (KEM-to-self decap is unreliable). A friend requester → per-recipient KEM
        // seal as before. The receiver tries the symmetric open first, then falls back to the engine's KEM.
        let own = requester_hex == self.node_id_hex();
        let own_key = if own { Some(self.own_media_key()) } else { None };
        for index in 0..total {
            if missing.is_some_and(|m| !m.contains(&index)) {
                continue; // requester already has it
            }
            let offset = index as usize * MEDIA_CHUNK_SIZE;
            let end = (offset + MEDIA_CHUNK_SIZE).min(bytes.len());
            if offset >= end {
                break;
            }
            let chunk = &bytes[offset..end];
            let sealed = if let Some(key) = own_key.as_ref() {
                haven_p2p::crypto::seal(key, chunk)
            } else {
                match self.social.seal_media(requester_hex.to_string(), chunk.to_vec()) {
                    Ok(s) => s,
                    Err(_) => return,
                }
            };
            self.send_frame_awaited(wire::MEDIA_CHUNK, &wire::chunk_frame(ref_bytes, index, total, &sealed), requester_hex)
                .await;
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
        // `total` is peer-controlled and now sizes a bitmap, so it is bounded here as well as at the
        // frame-33 parse: believed, `u32::MAX` would ask for a 536 MB `Vec` of bits.
        if reference.is_empty() || total == 0 || total > wire::MAX_RESUME_CHUNKS || index >= total {
            return;
        }
        if self.media.has(&reference) {
            return;
        }
        // Own-device chunks are symmetric (account-key) sealed; friend chunks are KEM. Try the cheap
        // symmetric open first, then fall back to the engine's KEM open.
        let plain = haven_p2p::crypto::open(&self.own_media_key(), sealed)
            .ok()
            .or_else(|| self.social.open_media(sealed.to_vec()));
        let Some(plain) = plain else { return };
        // Reassembly is POSITIONAL and ON DISK: chunk N's plaintext goes at offset N*chunkSize, so
        // the partial is a valid sparse file with holes exactly where the missing chunks are. That is
        // what makes it resumable — and it removes the old in-memory accumulation (with its silent
        // 1 GB cap, above which a fully-received transfer was simply dropped).
        let part_name = {
            let mut st = self.dyn_state.lock().unwrap();
            if st.reassembly.get(&reference).map(|r| r.got.contains(&index)).unwrap_or(false) {
                return; // already on disk — a re-send filling someone else's gap, or our own resume
            }
            let (name, is_new) = st.reassembly.begin(&reference, LocalMedia::part_name(&reference), total);
            if is_new {
                // Truncate ONLY for a transfer starting from nothing: a RESUMED one must never lose
                // the 99% already on disk. Done under the same lock as the record it belongs to —
                // chunks arrive concurrently, and a truncate racing another chunk's positional write
                // would erase bytes the bitmap already claims, the one direction it must never lie in.
                self.media.new_plain_part(&reference);
            }
            name
        };
        let part = self.media.part_path(&part_name);
        if !self.media.write_part_at(&part, index as u64 * MEDIA_CHUNK_SIZE as u64, &plain) {
            // A chunk whose bytes did NOT land must not enter the bitmap. Understating progress costs
            // one re-sent chunk; overstating it leaves a hole nothing will ever ask for again.
            return;
        }
        let complete = {
            let mut st = self.dyn_state.lock().unwrap();
            st.reassembly.mark(&reference, index).unwrap_or(false)
        };
        if !complete {
            return;
        }
        // Adoption verifies the content address (streamed) before sealing. Either way the reassembly
        // is over: on rejection the partial is already discarded, so leaving the record behind would
        // resurrect a bitmap whose bytes are gone and stall the ref forever.
        let ok = self.media.adopt_plain_part(&self.social, DEFAULT_CIRCLE, &reference, &part);
        {
            let mut st = self.dyn_state.lock().unwrap();
            st.reassembly.clear(&reference);
            st.resume_fallback.remove(&reference);
        }
        if ok {
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

    /// Mint the 512px AVIF preview for an image and store it, returning its ref.
    ///
    /// Desktop's composer downscales and re-encodes in the WEBVIEW, but Chromium's canvas cannot
    /// write AVIF — only PNG, JPEG and WebP — so this one encode has to happen in Rust
    /// (`docs/PREVIEW-TIER-DESIGN.md` §2). The caller hands over the same sanitized bytes it is
    /// about to attach; we decode, fit to 512 on the longest edge, and encode to the shared byte
    /// budget.
    ///
    /// `None` means "no preview for this item" — a picture we cannot decode, or one the encoder
    /// could not fit. It is never a reason to send full media on a constrained link.
    pub fn mint_preview(&self, circle_id: &str, bytes: &[u8]) -> Option<String> {
        let avif = crate::preview::encode_image_bytes(bytes)?;
        Some(self.media.store(&self.social, circle_id, &avif, false))
    }

    pub fn add_local_audio(&self, circle_id: &str, bytes: &[u8]) -> String {
        self.media.store_kind(&self.social, circle_id, bytes, crate::localmedia::MediaKind::Audio)
    }

    /// Zip / file attachment (`file_` prefix) — Apple/Android parity.
    pub fn add_local_file(&self, circle_id: &str, bytes: &[u8]) -> String {
        self.media
            .store_kind(&self.social, circle_id, bytes, crate::localmedia::MediaKind::File)
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
        // The verified sender is re-derived per frame type below, from the parser's own `from` field
        // — `open_sealed_frame` has already proven the two agree.
        let Some((_declared, body)) = self.open_sealed_frame(t, sealed) else { return };
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
            wire::CALL_HANGUP => callwire::parse_hangup(body).map(|(from, sid)| {
                // Carry the session up to the UI so it can ignore a BYE for a call it is not in.
                serde_json::json!({ "kind": "hangup", "from": from, "sessionId": sid })
            }),
            wire::CALL_HANDLED => callwire::parse_accept(body).map(|a| {
                serde_json::json!({ "kind": "handledElsewhere", "from": a.from, "sessionId": a.session_id })
            }),
            // 35: my account ENDED this session elsewhere. Distinct from handledElsewhere, which the
            // UI deliberately applies only while still ringing — this one must also end a call this
            // device has already answered, which is the case that left desktop in a dead call.
            wire::CALL_ENDED_ELSEWHERE => callwire::parse_accept(body).map(|a| {
                serde_json::json!({ "kind": "endedElsewhere", "from": a.from, "sessionId": a.session_id })
            }),
            wire::SDP_OFFER | wire::SDP_ANSWER | wire::ICE => callwire::parse_signal(body, "").map(|s| {
                let kind = match t { wire::SDP_OFFER => "offer", wire::SDP_ANSWER => "answer", _ => "ice" };
                serde_json::json!({ "kind": kind, "from": s.from, "sessionId": s.session_id, "json": String::from_utf8_lossy(&s.json) })
            }),
            // Frame 22 — a peer's camera went on/off. Without it a peer who stops their video
            // leaves everyone staring at a frozen last frame instead of their avatar.
            wire::CALL_CAMERA => callwire::parse_camera_state(body).map(|(from, on)| {
                serde_json::json!({ "kind": "camera", "from": from, "on": on })
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

    // ---- "Tell me when this media is back" (frames 31/32) --------------------------------

    /// Body of both media frames, addressed from us. The format itself lives in `wire`.
    fn media_frame_body(&self, reference: &str, circle_id: &str, post_id: &str) -> Vec<u8> {
        wire::media_frame(&self.social.my_node_hex(), reference, circle_id, post_id)
    }

    /// Whether a PERSON is waiting to hear that `reference` is back.
    ///
    /// The manual list, not `media_wanted`: the automatic sweep writes to the latter, and telling
    /// someone "we'll tell you when it's back" about a repair that deliberately never notifies both
    /// promises something that won't happen and hides the button that would earn it.
    pub fn media_is_wanted(&self, reference: &str) -> bool {
        self.prefs.lock().unwrap().media_wanted_manual.iter().any(|r| r == reference)
    }

    /// Ask a post's AUTHOR to re-upload media a relay has swept, and remember that we asked.
    ///
    /// The request rides the sealed frame path, which means the circle mailbox carries it: an author
    /// offline for a week gets it the moment they next sync. That is the whole mechanism — nothing is
    /// parked on a relay by hand, and no relay-side change was needed.
    /// `manual` = a PERSON asked ("Notify me when it's back"). The held-but-unreadable sweep calls
    /// this too, on its own, and those asks must stay silent — see `Prefs::media_wanted_manual`.
    pub fn request_media_when_available(
        self: &Arc<Self>,
        reference: String,
        circle_id: String,
        post_id: String,
        author_short: String,
        manual: bool,
    ) {
        let Some(author_hex) = self.id_hex_for(&author_short) else {
            log::info!("media-wanted {}: author not resolvable — cannot ask", short(&reference));
            return;
        };
        {
            let mut p = self.prefs.lock().unwrap();
            if manual && !p.media_wanted_manual.iter().any(|r| *r == reference) {
                p.media_wanted_manual.push(reference.clone());
                while p.media_wanted_manual.len() > 500 {
                    p.media_wanted_manual.remove(0);
                }
                let _ = p.save(&self.paths);
            }
            if !p.media_wanted.iter().any(|r| *r == reference) {
                p.media_wanted.push(reference.clone());
                // Bounded: someone who taps this on everything shouldn't grow an unbounded list, and
                // the oldest asks are the least likely to still matter.
                while p.media_wanted.len() > 500 {
                    p.media_wanted.remove(0);
                }
                let _ = p.save(&self.paths);
            }
        }
        let body = self.media_frame_body(&reference, &circle_id, &post_id);
        self.send_call_frame(wire::MEDIA_WANTED, &body, &author_hex);
        log::info!("media-wanted {} → author {}", short(&reference), short(&author_hex));
        self.emit_changed();
    }

    /// Author side: someone wants media from a post of ours that a relay no longer holds. If we still
    /// have the original, put it back on a relay we share and tell them when it lands.
    ///
    /// This is the point of the feature: media stays reachable for as long as its AUTHOR keeps a copy,
    /// rather than for as long as a relay's retention window.
    async fn handle_media_wanted(self: &Arc<Self>, sealed: &[u8]) {
        let Some((from, body)) = self.open_sealed_frame(wire::MEDIA_WANTED, sealed) else { return };
        let Some((reference, circle_id, post_id)) = wire::parse_media_frame(&body) else { return };
        if !self.is_contact(&from) {
            return; // only our circle may ask
        }
        // Only serve a circle they're actually IN — a request names a circle, and naming one is not
        // the same as belonging to it.
        let members = self.social.contact_node_ids(circle_id.clone());
        if !members.iter().any(|m| m.eq_ignore_ascii_case(&from)) {
            log::info!(
                "media-wanted {} from {} — not a member of {}, ignoring",
                short(&reference), short(&from), short(&circle_id)
            );
            return;
        }
        if !self.media.has(&reference) {
            log::info!("media-wanted {} from {} — we don't hold it either", short(&reference), short(&from));
            return;
        }
        // Holding the SEALED blob is not enough to REPAIR it. An asker who cannot open a blob is
        // almost always not one of its recipients — media is sealed once to a fixed list and never
        // re-sealed, so anyone who joined later is excluded permanently. Fixing that needs a FRESH
        // seal, which needs the PLAINTEXT. Re-uploading a sealed copy someone else produced puts the
        // same recipient list back and then answers "it's back": true, and useless. Stay quiet so
        // the ask reaches a device that can actually repair it. (Apple/Android parity.)
        if self.media.load_any_circle(&self.social, &reference).is_none() {
            log::info!(
                "media-wanted {} from {} — cannot open our own copy; cannot re-seal, not answering",
                short(&reference), short(&from)
            );
            return;
        }
        // A frame 31 costs the RECIPIENT a full blob upload, so serving one per inbound frame with no
        // bound is a bandwidth amplifier any circle member could aim at us. Inside the cooldown we
        // answer from what we already did: the blob really is on the relay, which is all 32 claims,
        // so re-sending it is both cheaper and honest. An in-flight guard collapses concurrent asks
        // for the same ref into one upload.
        const RESERVE_COOLDOWN_MS: u64 = 10 * 60 * 1000;
        let now = now_ms();
        // The cache may only answer for a ref we have actually RE-SEALED this session. A timer alone
        // swallows the very first repair: a peer that could not open a blob asks, we served that ref
        // minutes ago for an unrelated reason, and we reply "it's back" without re-sealing. Nothing
        // changed, they re-fetch identical bytes and fail identically — so whether a photo is ever
        // repaired depends on where its ask lands in the window, which reads as "some media loads,
        // some doesn't, at random". Observed on a real pair of devices.
        let resealed_before = {
            let st = self.dyn_state.lock().unwrap();
            st.media_resealed_session.contains(&reference)
        };
        let served_recently = resealed_before && {
            let st = self.dyn_state.lock().unwrap();
            st.media_served_at.get(&reference).is_some_and(|at| now.saturating_sub(*at) < RESERVE_COOLDOWN_MS)
        };
        if served_recently {
            let body = self.media_frame_body(&reference, &circle_id, &post_id);
            self.send_call_frame(wire::MEDIA_AVAILABLE, &body, &from);
            log::info!("media-wanted {}: served recently — re-answering without re-upload", short(&reference));
            return;
        }
        {
            let mut st = self.dyn_state.lock().unwrap();
            if !st.media_serving.insert(reference.clone()) {
                log::info!("media-wanted {}: re-upload already in flight — dropping duplicate ask", short(&reference));
                return;
            }
        }
        log::info!("media-wanted {} from {} — re-uploading to a shared relay", short(&reference), short(&from));
        // force: true — the "already has it" probe consults a ledger and the relay's own answer, and a
        // relay that has SWEPT the blob is exactly the case where both can say "held" and skip the
        // upload the asker is waiting for.
        let ok = self.upload_media_inner_reseal(&circle_id, &reference, true, true).await;
        if ok {
            let mut st = self.dyn_state.lock().unwrap();
            st.media_resealed_session.insert(reference.clone());
        }
        {
            let mut st = self.dyn_state.lock().unwrap();
            st.media_serving.remove(&reference);
            if ok {
                st.media_served_at.insert(reference.clone(), now);
                if st.media_served_at.len() > 500 {
                    st.media_served_at.clear();
                }
            }
        }
        if !ok {
            log::info!("media-wanted {}: re-upload failed — they'll re-ask", short(&reference));
            return;
        }
        let body = self.media_frame_body(&reference, &circle_id, &post_id);
        self.send_call_frame(wire::MEDIA_AVAILABLE, &body, &from);
        log::info!("media-wanted {}: back on a relay, told {}", short(&reference), short(&from));
    }

    /// Requester side: media we asked about is back. Notify with a deep link straight to the post,
    /// and re-fetch immediately, while the blob is known to be present.
    fn handle_media_available(self: &Arc<Self>, sealed: &[u8]) {
        let Some((from, body)) = self.open_sealed_frame(wire::MEDIA_AVAILABLE, sealed) else { return };
        let Some((reference, circle_id, post_id)) = wire::parse_media_frame(&body) else { return };
        if !self.is_contact(&from) {
            return;
        }
        // Something we asked for → the full "it's back" flow below. Anything else is the author's
        // push-ahead announce (their fresh post's media just landed on a relay): prefetch it
        // quietly — bounded, deduped, data-saver aware — with NO notification; the post's own
        // banner is the news, this is just its media arriving on time.
        {
            let mut p = self.prefs.lock().unwrap();
            match p.media_wanted.iter().position(|r| *r == reference) {
                Some(i) => {
                    p.media_wanted.remove(i);
                    let _ = p.save(&self.paths);
                }
                None => {
                    drop(p);
                    self.prefetch_announced_media(&reference, &circle_id);
                    return;
                }
            }
        }
        self.clear_evicted(&reference);
        self.media_download(reference.clone()); // pull it now, while we know it's there
        // Silent unless the user personally asked. The sweep asks on its own for media nobody has
        // heard of; the fetch above still runs, which is the part that matters — the picture
        // appears either way.
        let person_asked = {
            let mut p = self.prefs.lock().unwrap();
            match p.media_wanted_manual.iter().position(|r| *r == reference) {
                Some(i) => { p.media_wanted_manual.remove(i); let _ = p.save(&self.paths); true }
                None => false,
            }
        };
        if !person_asked {
            log::info!("media-wanted {}: author says it's back — fetching (automatic, no notification)",
                       short(&reference));
            self.emit_changed();
            return;
        }
        let who = self.display_name(&from[..from.len().min(8)]);
        // The on-device link form: it never leaves this machine, so routing it through the web
        // landing page would be a pointless round trip.
        let link = (!post_id.is_empty()).then(|| format!("haven://p/{circle_id}/{post_id}"));
        self.notify_with_link(
            "Media is available again",
            &format!("{who} put back the media you asked for."),
            link.as_deref(),
        );
        log::info!("media-wanted {}: author says it's back — fetching", short(&reference));
        self.emit_changed();
    }

    /// Act on an UNSOLICITED frame-32 announce (author push-ahead): fetch the just-landed blob so
    /// it's here before the user opens the post. Bounded: per-ref 60s throttle, skip held/evicted/
    /// synthetic refs, and under super data saver only small kinds prefetch (videos stay
    /// tap-to-play). Mirrors the iOS `handleMediaAvailable` push-ahead branch.
    fn prefetch_announced_media(self: &Arc<Self>, reference: &str, circle_id: &str) {
        if LocalMedia::is_synthetic(reference)
            || self.media.has(reference)
            || self.evicted_contains(reference)
        {
            return;
        }
        // Ask the SHARED policy table, not a local bool — this is the same ruling the iPhone and
        // Android clients get for the same link (docs/SATELLITE-DESIGN.md §5). A speculative
        // prefetch is exactly the traffic low-data mode exists to stop, so anything short of a
        // plain `Allow` means don't.
        let level = match self.low_data_level().as_str() {
            "ultra" => haven_p2p::transport::LinkConstraint::Ultra,
            "low" => haven_p2p::transport::LinkConstraint::Low,
            _ => haven_p2p::transport::LinkConstraint::Normal,
        };
        let small = reference.starts_with("img_")
            || reference.starts_with("i:")
            || reference.starts_with("aud_")
            || reference.starts_with("a:")
            || reference.starts_with("file_");
        let kind = if small {
            haven_p2p::transport::Traffic::Thumbnail
        } else {
            haven_p2p::transport::Traffic::Media
        };
        if haven_p2p::transport::allowance(level, kind) != haven_p2p::transport::Allowance::Allow {
            return;
        }
        {
            let mut st = self.dyn_state.lock().unwrap();
            let now = now_ms();
            if st.announced_media_at.get(reference).is_some_and(|&at| now.saturating_sub(at) < 60_000) {
                return;
            }
            st.announced_media_at.insert(reference.to_string(), now);
            if st.announced_media_at.len() > 1000 {
                st.announced_media_at.clear();
            }
        }
        let me = self.clone();
        let reference = reference.to_string();
        let circle_id = circle_id.to_string();
        tauri::async_runtime::spawn(async move {
            if me.fetch_media_healing(&circle_id, &reference).await {
                me.emit_changed();
                log::info!(
                    "media push-ahead {}: prefetched on announce",
                    &reference.chars().take(10).collect::<String>()
                );
            }
        });
    }

    /// A contact's FULL node id from the short (8-hex) author id a feed item carries — the short id
    /// is all a post has, but anything addressed to a person needs the full hex. Mirrors iOS
    /// `ContactsStore.idHex(forNodePrefix:)`.
    fn id_hex_for(&self, author_short: &str) -> Option<String> {
        if author_short.is_empty() {
            return None;
        }
        self.prefs
            .lock()
            .unwrap()
            .contacts
            .iter()
            .find(|c| c.id_hex.starts_with(author_short))
            .map(|c| c.id_hex.clone())
    }

    /// Open + verify a sealed+signed frame, returning `(declared sender hex, plaintext body)`.
    ///
    /// The ONE verification implementation for every sealed frame type — call signaling and the
    /// media frames 31/32 alike — so a guard tightened here is tightened for all of them. Drops any
    /// frame we can't decrypt, whose signature doesn't verify for this recipient AND frame type (a
    /// relay-forged, relay-rewritten, or replayed-as-another-type frame all fail), or whose PROVEN
    /// sender doesn't match the self-declared `from` the parsers key on.
    fn open_sealed_frame(&self, t: u8, sealed: &[u8]) -> Option<(String, Vec<u8>)> {
        let opened = self.social.open_call_frame(t, sealed.to_vec())?;
        let verified = opened.sender_hex.to_lowercase();
        let body = opened.data;
        if verified.len() != 64 || body.len() < 64 {
            return None;
        }
        let declared = String::from_utf8_lossy(&body[..64]).to_lowercase();
        if declared != verified {
            // D9: a SEEDLESS sender signs with its DEVICE key, so the proven signer is the device id
            // while the body's `from` is the account id. Accept when the verified device resolves
            // (via the verified roster) to the declared account — otherwise it's a forgery.
            match self.social.account_for_device(verified) {
                Some(acct) if acct.eq_ignore_ascii_case(&declared) => {}
                _ => return None, // proven sender must equal, or speak for, the self-declared `from`
            }
        }
        // Block by ACCOUNT id (`declared`), which for a device-signed frame is the account behind the
        // device, not the transient device hex.
        if self.prefs.lock().unwrap().blocked.contains(&declared) {
            return None;
        }
        Some((declared, body))
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

    /// Push a frame straight to my own other devices while they're online. Best-effort BY CONTRACT:
    /// a sibling that's asleep is the EXPECTED case, not an error — every caller's durable mailbox
    /// path runs regardless of what happens here. iOS `liveDeliverToMyDevices` parity.
    fn live_deliver_to_my_devices(self: &Arc<Self>, t: u8, payload: &[u8]) {
        for dev in self.my_other_device_hexes() {
            self.send_frame(t, payload, &dev);
        }
    }

    /// Batched [`live_deliver_to_my_devices`] — ONE task for MANY frames rather than one per frame.
    /// The catch-up sweep hands over dozens of envelopes at once, and `send_frame` spawns a task per
    /// call: spawning one each would be a needless pile of concurrent dials at the same few devices,
    /// which is exactly the shape that drives iroh path-discovery churn. Sends sequentially inside a
    /// single task instead.
    fn live_deliver_many_to_my_devices(self: &Arc<Self>, t: u8, payloads: Vec<Vec<u8>>) {
        let targets = self.my_other_device_hexes();
        if targets.is_empty() || payloads.is_empty() {
            return;
        }
        let node = self.node.lock().unwrap().clone();
        let Some(node) = node else { return };
        let frames: Vec<Vec<u8>> = payloads.iter().map(|p| wire::frame(t, p)).collect();
        tauri::async_runtime::spawn(async move {
            for dev in targets {
                for f in &frames {
                    let _ = node.send_to_node(dev.clone(), f.clone()).await;
                }
            }
        });
    }

    /// My OWN other devices' node ids (excluding this one and my account id, which under per-device
    /// transport seeds resolves to no endpoint). Invite/device hints for MY account are included
    /// too: until self-sync merges the signed own-roster, a freshly-linked sibling is otherwise
    /// invisible to fan-out and never gets contact events that only this device received.
    fn my_other_device_hexes(&self) -> Vec<String> {
        let account = self.social.my_node_hex().to_lowercase();
        let mine = self.social.my_device_node_hex().to_lowercase();
        let mut out: Vec<String> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut add = |h: String| {
            let l = h.to_lowercase();
            if l.len() == 64 && l != mine && l != account && seen.insert(l.clone()) {
                out.push(l);
            }
        };
        for d in self.social.device_node_ids_for(account.clone()) {
            add(d);
        }
        for h in self.device_hints_for(&account) {
            add(h);
        }
        out
    }

    /// Frame 22 — tell the other participants my camera just went on or off. Without it, disabling
    /// the local video track leaves every peer staring at a frozen last frame instead of my avatar.
    /// Bounded by the call roster the caller passes; this is a user action, not a tick.
    pub fn call_camera_state(self: &Arc<Self>, session_id: String, on: bool, to: Vec<String>) {
        let frame = callwire::camera_state(&self.node_id_hex(), &session_id, on);
        for t in to {
            self.send_call_frame(wire::CALL_CAMERA, &frame, &t);
        }
    }

    /// QA-visible call state, pushed from the webview.
    ///
    /// Desktop's call UI lives entirely in JS, so the Rust-built qa-dump could not report whether
    /// this leg was ringing or in a call — and the e2e call step only ever asserted on ios and stub.
    /// That blind spot let an established call ended on iOS strand THIS leg in a dead call while the
    /// suite reported green; only someone looking at the screen could tell. Two bools close it.
    pub fn set_qa_call_state(self: &Arc<Self>, ringing: bool, in_call: bool) {
        // bit2 = KNOWN. Set on the first push and never cleared.
        self.qa_call.store(
            0b100 | (ringing as u8) | ((in_call as u8) << 1),
            std::sync::atomic::Ordering::Relaxed,
        );
    }

    /// `None` until the webview has pushed at least once.
    ///
    /// This must NOT default to "not in a call". It did, and that made a leg which never reported at
    /// all — stale bundle, failed invoke, anything — indistinguishable from one that had cleanly hung
    /// up. The e2e assertion passed on desktop at the same moment desktop was visibly sitting in a
    /// live call. A default that reads as healthy turns "not measuring" into "working".
    /// What the engine is HOLDING BACK — parked (received-but-unopenable) envelopes per circle plus
    /// the rosters we know. A short feed alone cannot distinguish "never arrived" from "arrived and
    /// could not be opened", and those have opposite fixes.
    pub fn diag_delivery_json(&self) -> String {
        self.social.diag_delivery_json()
    }

    pub fn qa_call_state(&self) -> Option<(bool, bool)> {
        let v = self.qa_call.load(std::sync::atomic::Ordering::Relaxed);
        if v & 0b100 == 0 { return None; }
        Some((v & 1 != 0, v & 2 != 0))
    }

    pub fn call_hangup(self: &Arc<Self>, to: Vec<String>, session_id: String) {
        let frame = callwire::hangup(&self.node_id_hex(), &session_id);
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

    /// Write the engine state at most once every few seconds instead of once per authored post.
    ///
    /// Only ever used for bulk authoring — see `after_author_inner`. The flag is the whole
    /// mechanism: a write is already scheduled, so this call is a no-op rather than another
    /// full serialisation of a state that is growing with every post.
    fn persist_coalesced(self: &Arc<Self>) {
        if self.persist_pending.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        let me = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(3));
            me.persist_pending.store(false, std::sync::atomic::Ordering::SeqCst);
            me.persist();
        });
    }

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
            // Permanent breadcrumb: the silent early return here is what made the dead lane
            // undebuggable (an empty transport list looks identical to a healthy no-op pass).
            log::info!("selfsync: no transport (no active relay, no S3) — pass skipped");
            return; // needs a relay OR an S3 bucket
        }
        log::info!(
            "selfsync pass: account={} transports=[{}]",
            &account_hex.chars().take(8).collect::<String>(),
            transports.iter().map(|t| t.label()).collect::<Vec<_>>().join(",")
        );

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
            let listed = keys.len();
            let (mut fetched, mut opened) = (0usize, 0usize);
            for key in keys {
                if key == own_key {
                    continue;
                }
                let Some(blob) = self.self_sync_fetch(t, &key).await else { continue };
                fetched += 1;
                if let Ok(peer) = AccountState::open_any(&blob, seed_key.as_ref(), &accepted) {
                    opened += 1;
                    base.merge(&peer);
                }
            }
            // Per-transport outcome (counts only, never contents): `opened < fetched` is a key-
            // derivation/epoch mismatch, `fetched < listed-1` a GET failure, `listed == 0` an
            // empty/refused LIST — each of which previously failed in total silence.
            log::info!(
                "selfsync {}: listed={listed} peer_slots_fetched={fetched} opened={opened}",
                t.label()
            );
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
        log::info!(
            "selfsync converged: entries={} merged_change={changed} applied={applied}",
            entries.len()
        );
        // Membership just arrived (or moved), so the set of peers we need device rosters for has
        // changed. sync_with_contacts is otherwise only called ONCE, at startup — on a linked
        // device that runs BEFORE self-sync delivers any circle, so it saw no members, pulled no
        // rosters, and the peer's key commit stayed unauthorizable forever. It is cheap to repeat:
        // single-flighted, capped at 3 contacts per pass, with a 10-minute per-contact backoff, and
        // the roster ingest is a no-op once we hold it.
        // NOT gated on `applied`: that means "this pass merged NEW state", which is false on the
        // steady-state passes (measured: 0 of 5 passes applied) — yet those are exactly the passes
        // where we already hold the membership and still have never pulled the peer's roster.
        // Unconditional is safe: sync_with_contacts single-flights, takes at most 3 contacts per
        // pass, backs off 10 minutes per contact, and skips anyone already resolvable.
        self.sync_with_contacts();
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

        // A refusal anywhere above means a relay doesn't know this DEVICE id yet — publish the
        // roster to the refusers now (rate-limited; no-op when nothing refused) so the NEXT pass
        // converges instead of 403ing forever.
        let _ = self.heal_forbidden_relays().await;
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

    /// Our in-process hosted relay's handle when `node_hex` IS that relay. Its store must be
    /// served locally: `relay_client_for` self-guards (a self-dial is THE runaway leak), so the
    /// iroh path can never reach it, and the self-sync ladder would otherwise silently skip the
    /// one relay a hosting desktop always has.
    fn hosted_relay_for(&self, node_hex: &str) -> Option<Arc<RelayServerHandle>> {
        let g = self.relay_host.lock().unwrap();
        g.as_ref().filter(|h| h.node_id_hex() == node_hex).cloned()
    }

    // The three self-sync transport ops run the SAME ladder as the mailbox poll, in the same
    // order: own hosted store → signed plain-HTTP → warm iroh client. Iroh-only was the
    // desktop leg of the dead self-sync lane: an HTTP-mailbox-only relay (matrix stub, free-CF
    // NAS) never iroh-dials, so two linked devices sharing only such a relay never converged.

    async fn self_sync_list(self: &Arc<Self>, t: &SelfSyncTransport, prefix: &str) -> Vec<String> {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                if let Some(h) = self.hosted_relay_for(node_hex) {
                    return h.local_list(prefix.to_string());
                }
                if let Some((bases, token)) = self.relay_http_reachable(node_hex) {
                    for base in &bases {
                        if self.http_url_bad(base) {
                            continue;
                        }
                        // No digest echo — a slot prefix is a handful of keys, not a fat mailbox.
                        match self.http_list_delta(base, &token, prefix, None).await {
                            Ok((keys, _)) => {
                                self.mark_relay_ok(node_hex);
                                return keys.unwrap_or_default();
                            }
                            Err(RelayErr::Forbidden) => {
                                // The refusal stands for the WHOLE relay (same store + same gate
                                // behind every URL AND the iroh path), so don't fall through to an
                                // iroh dial that will be refused too — a slow-failing dial here
                                // stalls the coalesced pass for minutes. The roster heal at the end
                                // of the pass is the remedy; the NEXT pass converges. (Android's
                                // selfSyncHttpList returns null on 403 for the same reason.)
                                self.note_refused(node_hex, "selfsync list");
                                return vec![];
                            }
                            Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                        }
                    }
                }
                let Some(client) = self.relay_client_for(node_hex).await else { return vec![] };
                match client.list(prefix.to_string()).await {
                    Ok(keys) => { self.mark_relay_ok(node_hex); keys }
                    Err(_) => vec![],
                }
            }
            SelfSyncTransport::S3(c) => c.list(prefix).await.unwrap_or_default(),
        }
    }

    async fn self_sync_fetch(self: &Arc<Self>, t: &SelfSyncTransport, key: &str) -> Option<Vec<u8>> {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                if let Some(h) = self.hosted_relay_for(node_hex) {
                    return h.local_get(key.to_string());
                }
                if let Some((bases, token)) = self.relay_http_reachable(node_hex) {
                    for base in &bases {
                        if self.http_url_bad(base) {
                            continue;
                        }
                        match self.http_get(base, &token, key).await {
                            // Some = bytes; None = a REAL miss — the iroh path serves the same
                            // store, so don't burn a dial re-asking it.
                            Ok(found) => {
                                self.mark_relay_ok(node_hex);
                                return found;
                            }
                            Err(RelayErr::Forbidden) => {
                                // Same-gate refusal — the iroh path would 403 too; heal, next pass.
                                self.note_refused(node_hex, "selfsync get");
                                return None;
                            }
                            Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                        }
                    }
                }
                let client = self.relay_client_for(node_hex).await?;
                client.get(key.to_string()).await
            }
            SelfSyncTransport::S3(c) => c.get(key).await.ok().flatten(),
        }
    }

    async fn self_sync_put(self: &Arc<Self>, t: &SelfSyncTransport, key: &str, data: &[u8]) {
        match t {
            SelfSyncTransport::Relay(node_hex) => {
                if let Some(h) = self.hosted_relay_for(node_hex) {
                    h.local_put(key.to_string(), data.to_vec());
                    return;
                }
                if let Some((bases, token)) = self.relay_http_reachable(node_hex) {
                    for base in &bases {
                        if self.http_url_bad(base) {
                            continue;
                        }
                        match self.http_put(base, &token, key, data.to_vec()).await {
                            Ok(()) => {
                                self.mark_relay_ok(node_hex);
                                return;
                            }
                            Err(RelayErr::Forbidden) => {
                                // Same-gate refusal — the iroh path would 403 too; heal, next pass.
                                self.note_refused(node_hex, "selfsync put");
                                return;
                            }
                            Err(RelayErr::Unreachable) => self.mark_http_url_bad(base),
                        }
                    }
                }
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

/// Where "Message the author" should take the user, and what should be WAITING there — the thread id,
/// the contact's name for the header, and an UNSENT draft naming the post. Nothing is sent.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageAuthorTarget {
    pub dm: String,
    pub name: String,
    pub draft: String,
}

// ---- qa-cmd v2 driver support (DEBUG builds only — see qa.rs / docs/QA.md) ----------------

#[cfg(debug_assertions)]
impl Engine {
    /// The active identity's data dir — where `qa-cmd.json` / `qa-dump.json` live (next to the
    /// `qa-account-hex.txt` / `qa-device-hex.txt` the matrix harness already reads).
    pub(crate) fn data_root(&self) -> std::path::PathBuf {
        self.paths.root.clone()
    }

    /// The dump's media-blob gate for one ref: real refs are "present" when the sealed blob is on
    /// disk; synthetic refs (geo pins etc.) are vacuously present — nothing can ever fetch them,
    /// so gating on them would fail every media check forever.
    pub(crate) fn media_present(&self, reference: &str) -> bool {
        LocalMedia::is_synthetic(reference) || self.media.has(reference)
    }

    /// A circle's member account ids (excludes me) — the dump's `members` array.
    pub(crate) fn circle_member_ids(&self, circle_id: &str) -> Vec<String> {
        self.social.contact_node_ids(circle_id.to_string())
    }
}
