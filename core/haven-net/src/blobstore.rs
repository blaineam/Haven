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
//!   TOUCH <prefix> + keys → refresh liveness of the listed keys → reply: OK [+ missing keys]
//!   AGES <prefix>       → "<age-secs> <key>" lines under prefix (for age-aware mesh sync)
//! ```
//!
//! ## Mailbox garbage collection (TOUCH + TTL)
//!
//! Event envelopes now seal deterministically, but the mailbox had already accumulated
//! thousands of legacy duplicates (a fresh random-sealed copy of every event per backfill
//! run, plus a full stale copy per epoch rotation) — ~6,700 entries for an 88-event circle,
//! re-LISTed on every 30s poll and re-circulated forever by mesh sync. Entries are opaque
//! to the relay and live keys are never re-PUT (`has()` hits skip the write), so a naive
//! mtime TTL would delete live history. GC therefore works on **client-declared liveness**:
//!
//! - Each member's app periodically (daily) sends `TOUCH` with the refs of every envelope
//!   it can deterministically re-seal (its OWN events + current key commit + roster) — one
//!   ~key-list request, not one round-trip per key. The relay bumps those files' mtimes and
//!   replies with the keys it does NOT hold, which the client re-PUTs (refresh = repair).
//!   `HAS` hits refresh mtime too.
//! - [`gc_sweep`] runs hourly on every relay host and deletes `haven/mailbox/**` entries
//!   whose mtime is older than [`MAILBOX_TTL`] (30 days). Live entries are touched daily by
//!   each active author; legacy duplicates, stale-epoch copies, and retention-expired
//!   events are never touched again, so they age out everywhere. By DEFAULT media
//!   (`haven/media/…`) and self-sync slots are NEVER swept; a relay OPERATOR may opt media
//!   into an age limit and/or a total-size cap via [`Retention`] (see [`gc_sweep_with`]) —
//!   age applies first, then oldest-first size eviction, so whichever rule frees more wins.
//! - Mesh sync is **age-preserving** so a deletion isn't resurrected: `AGES` reports each
//!   key's idle age, a puller skips mailbox entries already older than the TTL, and it
//!   back-dates the pulled file's mtime by the peer's age — dead entries age monotonically
//!   across the whole mesh instead of ping-ponging between relays with fresh mtimes.
//! - A first-enable grace ([`GC_GRACE`], 48h, tracked by a `.haven-gc-enabled` marker in
//!   the store root) gives every member a daily-refresh cycle to stamp live entries before
//!   the first sweep may delete anything (pre-GC stores have ancient mtimes on LIVE keys).
//!
//! Tradeoff (accepted, documented): an author inactive on ALL devices for > TTL stops
//! refreshing; their envelopes fall off relays until they return (their next refresh
//! re-PUTs every miss). Members' local stores are the source of truth — the relay is a
//! store-and-forward mailbox, not an archive.
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

/// Bound how long ANY single blob-client op may block. Without this a relay that accepts the QUIC
/// connection but then never replies hangs the `await` forever — so the caller's serial fan-out
/// stalls on that one relay and never records a failure (so backoff never engages). One dead/hung
/// relay could therefore freeze posting/polling for ALL relays. A 30s ceiling on data ops (put/get)
/// and a faster 12s dial cap bound the hang so a bad relay fails fast, records a strike, and gets
/// backed off — isolating it from the healthy relays.
const OP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
const DIAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(12);

/// Run a blob-client op under `OP_TIMEOUT`, turning a hang into a prompt error (so the caller records
/// a relay failure and backs it off instead of stalling forever).
async fn with_timeout<F, T>(what: &str, fut: F) -> Result<T>
where
    F: std::future::Future<Output = Result<T>>,
{
    match tokio::time::timeout(OP_TIMEOUT, fut).await {
        Ok(r) => r,
        Err(_) => bail!("relay {what} timed out"),
    }
}
/// Hard cap on a key length (keys are short content-addressed paths).
const MAX_KEY: usize = 512;
/// Hard cap on a TOUCH request body (newline-joined keys — thousands of refs fit easily).
const MAX_TOUCH_BODY: u64 = 256 * 1024;

/// The namespace mailbox GC applies to. Self-sync slots are never swept; media is swept
/// ONLY when the operator opts into a limit (see [`Retention`]).
pub(crate) const MAILBOX_PREFIX: &str = "haven/mailbox/";
/// The namespace operator-chosen media retention applies to.
pub(crate) const MEDIA_PREFIX: &str = "haven/media/";
/// A mailbox entry idle (no PUT / HAS hit / TOUCH) longer than this is garbage-collected.
/// Clients refresh their live refs daily, so 30 days tolerates a month of total inactivity.
pub const MAILBOX_TTL: std::time::Duration = std::time::Duration::from_secs(30 * 24 * 3600);
/// After GC is first enabled on a store, wait this long before the first deletion — every
/// member gets a daily-refresh cycle to stamp its live entries (pre-GC mtimes are ancient).
pub const GC_GRACE: std::time::Duration = std::time::Duration::from_secs(48 * 3600);
/// How often a relay host runs [`gc_sweep`].
pub const GC_INTERVAL: std::time::Duration = std::time::Duration::from_secs(3600);

/// Operator-chosen retention policy for a relay store. **The default is exactly today's
/// behavior** — mailbox entries age out after [`MAILBOX_TTL`], media is NEVER deleted — so
/// an app-embedded relay that never touches this changes nothing. A relay operator may:
///
/// * override the mailbox TTL,
/// * cap media by AGE (idle time, same TOUCH/HAS-refresh liveness clock the mailbox uses),
/// * cap media by TOTAL SIZE (oldest-first eviction until under the cap),
///
/// or any combination. Age applies before size in a sweep, so when both are set whichever
/// rule deletes more wins — the operator's "least amount of space" intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Retention {
    /// Idle TTL for `haven/mailbox/**` entries.
    pub mailbox_ttl: std::time::Duration,
    /// Idle TTL for `haven/media/**` blobs. `None` = never age out (today's behavior).
    pub media_max_age: Option<std::time::Duration>,
    /// Total-size cap on `haven/media/**`. `None` = unbounded (today's behavior).
    pub media_max_bytes: Option<u64>,
}

impl Default for Retention {
    fn default() -> Self {
        Self { mailbox_ttl: MAILBOX_TTL, media_max_age: None, media_max_bytes: None }
    }
}

impl Retention {
    /// True when the operator opted into ANY media limit (the media sweep runs at all).
    pub fn media_limited(&self) -> bool {
        self.media_max_age.is_some() || self.media_max_bytes.is_some()
    }
}

/// What one [`gc_sweep_with`] pass did — the operator-visibility numbers a relay host logs.
#[derive(Clone, Copy, Debug, Default)]
pub struct GcStats {
    /// Mailbox entries (+ stale `.part` temps) deleted by the TTL sweep.
    pub mailbox_deleted: usize,
    /// Media blobs deleted because they exceeded `media_max_age`.
    pub media_deleted_age: usize,
    /// Media blobs evicted (oldest-first) to get under `media_max_bytes`.
    pub media_deleted_size: usize,
    /// Media bytes freed this pass (age + size deletions combined).
    pub media_bytes_freed: u64,
    /// Media store total AFTER the pass (only measured when a media limit is set).
    pub media_bytes_total: u64,
}

/// Human-readable byte count for operator output ("1.5 GB", "512 MB", "980 B").
pub fn fmt_bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{:.1} {}", v, UNITS[i])
    }
}

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

pub(crate) const VERB_PUT: u8 = b'P';
pub(crate) const VERB_GET: u8 = b'G';
pub(crate) const VERB_HAS: u8 = b'H';
pub(crate) const VERB_LIST: u8 = b'L';
/// Refresh liveness of a batch of keys (body = newline-joined keys under the header prefix).
pub(crate) const VERB_TOUCH: u8 = b'T';
/// LIST with idle ages ("<age-secs> <key>" lines) — for age-preserving mesh sync.
pub(crate) const VERB_AGES: u8 = b'A';

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

/// Pure mesh-sync decision: of the `(key, idle-age-secs)` pairs a peer advertises, which
/// should we pull? Those that (a) stay inside our namespace (no traversal / absolute /
/// `..`), (b) we don't already hold, and (c) aren't already past OUR OWN retention limits —
/// pulling one of those would RESURRECT an entry we just deleted (or are about to delete),
/// which is exactly how dead entries used to circulate forever. For mailbox entries the
/// limit is the mailbox TTL; for media it's the operator's `media_max_age` (when set) plus
/// the size-eviction horizon (see [`read_media_horizon`] — everything at or older than the
/// newest blob the size cap evicted stays evicted, otherwise a size-capped relay would
/// re-pull the oldest blobs every mesh tick just to evict them again next sweep). Each
/// relay filters by its OWN policy only — siblings with laxer limits keep their copies;
/// absence here is a local cutoff, never a tombstone. Capped at `MAX_SYNC_PULL`. Factored
/// out so the set-difference + safety + age logic is unit-testable without a live network.
/// (A legacy peer that can't report ages advertises age 0, i.e. "fresh" — old
/// pull-everything behavior during the transition.)
pub(crate) fn keys_to_pull(
    root: &Path,
    peer_keys: &[(String, u64)],
    retention: &Retention,
) -> Vec<(String, u64)> {
    let mailbox_ttl = retention.mailbox_ttl.as_secs();
    let media_ttl = retention.media_max_age.map(|d| d.as_secs());
    let horizon = read_media_horizon(root);
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut out = Vec::new();
    for (key, age) in peer_keys {
        if out.len() >= MAX_SYNC_PULL {
            break;
        }
        if *age >= mailbox_ttl && key.starts_with(MAILBOX_PREFIX) {
            continue; // expired on the peer's clock → never resurrect
        }
        if key.starts_with(MEDIA_PREFIX) {
            if media_ttl.is_some_and(|ttl| *age >= ttl) {
                continue; // past OUR media age limit → we'd delete it next sweep anyway
            }
            // Older (by write time) than the newest blob the size cap already evicted →
            // pulling it would just be evicted again next sweep (pull/evict churn loop).
            // The slack absorbs age-granularity/clock skew between us and the peer: a peer's
            // copy of the very blob we evicted computes a hair "newer" than our recorded
            // horizon, which would defeat the guard without it.
            const HORIZON_SLACK_SECS: u64 = 600;
            if horizon > 0
                && now_secs.saturating_sub(*age) <= horizon.saturating_add(HORIZON_SLACK_SECS)
            {
                continue;
            }
        }
        match safe_path(root, key) {
            Ok(p) if !p.is_file() => out.push((key.clone(), *age)),
            _ => {} // already have it, or it escapes our namespace → never pull
        }
    }
    out
}

/// Bump a stored blob's mtime to "now" — the liveness stamp GC ages against.
fn touch_now(path: &Path) {
    let _ = std::fs::File::options()
        .write(true)
        .open(path)
        .and_then(|f| f.set_modified(std::time::SystemTime::now()));
}

/// Back-date a just-pulled blob's mtime by the peer's reported idle age, so replication
/// preserves age instead of resetting it (resetting is what resurrected dead entries).
fn backdate(path: &Path, age_secs: u64) {
    if age_secs == 0 {
        return; // already "now"
    }
    let then = std::time::SystemTime::now() - std::time::Duration::from_secs(age_secs);
    let _ = std::fs::File::options().write(true).open(path).and_then(|f| f.set_modified(then));
}

/// Seconds since a file was last written/touched (0 on any error → treated as fresh, so a
/// filesystem hiccup can never make an entry look expired).
fn idle_age_secs(path: &Path) -> u64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| std::time::SystemTime::now().duration_since(t).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Escape a key component for on-disk storage: `%` → `%25`, `:` → `%3A`. Colons are illegal in
/// NTFS names (alternate data streams) and used to be REJECTED outright here — which silently made
/// every DM mailbox key (`haven/mailbox/dm:<a>-<b>/<hash>`) unstorable on EVERY platform: DMs
/// never landed on any relay, so an offline recipient only ever saw the push banner, never the
/// message. Keys keep their colons on the wire; only the disk mapping is escaped.
pub(crate) fn encode_comp(comp: &str) -> String {
    comp.replace('%', "%25").replace(':', "%3A")
}

/// Reverse of [`encode_comp`] (order matters: `%3A` first, then `%25`).
pub(crate) fn decode_comp(name: &str) -> String {
    name.replace("%3A", ":").replace("%25", "%")
}

pub(crate) fn safe_path(root: &Path, key: &str) -> Result<PathBuf> {
    if key.is_empty() || key.len() > MAX_KEY {
        bail!("bad key length");
    }
    if key.contains('\0') || key.starts_with('/') || key.starts_with('\\') {
        bail!("illegal key");
    }
    // A LIST prefix legitimately ends in "/" ("haven/mailbox/<circle>/"); the empty trailing
    // component must not fail the whole key.
    let key = key.strip_suffix('/').or_else(|| key.strip_suffix('\\')).unwrap_or(key);
    let mut out = root.to_path_buf();
    for comp in key.split(['/', '\\']) {
        if comp.is_empty() || comp == "." || comp == ".." {
            bail!("illegal key component");
        }
        // Store components escaped (`:`/`%` → percent form) so keys like `dm:<a>-<b>` are
        // representable on every filesystem, Windows included.
        out.push(encode_comp(comp));
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

/// Per-circle authorization for the whole `haven/` namespace (audit F2/F4). The relay serves a
/// circle's keys ONLY to that circle's members — a stranger who merely learns the relay's node id
/// (or captures its shared token off the wire) can no longer enumerate or fetch anything. Sibling
/// relays are allowed broad LIST so mesh anti-entropy still works.
///
/// **This fails CLOSED.** An empty map does not mean "permissive", it means the relay has no
/// members yet and therefore serves nobody: a relay that has not been told who belongs cannot
/// possibly know that a caller does. (The pre-F4 code returned "allowed" for every unclassified
/// key and for the unconfigured map, which is exactly how the auditor read `haven/devroster/**`
/// with no token at all.) The only ungated verb is a devroster PUT — see [`verify_devroster`],
/// where an account signature, not the write gate, is the trust.
#[derive(Default)]
pub struct RelayAuth {
    /// circleId → authorized member node hexes.
    members: HashMap<String, HashSet<String>>,
    /// Sibling relay node hexes allowed to replicate via broad LIST (mesh anti-entropy).
    relays: HashSet<String>,
}

impl RelayAuth {
    /// Authorize a circle's mailbox to exactly `members` + the circle's sibling `relays`. Idempotent.
    pub fn authorize(&mut self, circle_id: &str, members: Vec<String>, relays: Vec<String>) {
        self.members.insert(circle_id.to_string(), members.into_iter().collect());
        for r in relays {
            self.relays.insert(r);
        }
    }
    /// Expand every circle this account is a member of to ALSO include its DEVICE ids — called after a
    /// device roster written to `haven/devroster/<account>` is cryptographically verified. A device
    /// connects to a relay AS its device id, but a HEADLESS relay only knows account ids (from the
    /// operator's link), so without this it `ERR forbidden`s every one of the account's devices. The
    /// device ids come from an account-SIGNED DeviceList (see `verify_devroster`), so a stranger can't
    /// inject ids for someone else's account. Idempotent (HashSet insert).
    pub(crate) fn authorize_devices(&mut self, account_hex: &str, device_hexes: &[String]) {
        for members in self.members.values_mut() {
            if members.contains(account_hex) {
                for d in device_hexes {
                    members.insert(d.clone());
                }
            }
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

/// Like [`local_list`] but with each key's idle age in seconds — the AGES verb / age-aware
/// mesh sync read their inventory through this.
pub(crate) fn local_list_ages(root: &Path, prefix: &str) -> Vec<(String, u64)> {
    local_list(root, prefix)
        .into_iter()
        .filter_map(|key| safe_path(root, &key).ok().map(|p| (key, idle_age_secs(&p))))
        .collect()
}

/// Refresh the liveness stamp (mtime) of every key in `keys` the store holds; returns the
/// keys it does NOT hold so the caller can re-PUT them (refresh doubles as repair). The
/// in-process host calls this directly for its own store (no iroh self-dial); remote
/// clients reach it via the TOUCH verb / `POST /t/`.
pub(crate) fn local_touch(root: &Path, keys: &[String]) -> Vec<String> {
    let mut misses = Vec::new();
    for key in keys {
        match safe_path(root, key) {
            Ok(p) if p.is_file() => touch_now(&p),
            Ok(_) => misses.push(key.clone()),
            Err(_) => {} // unsafe key: neither touched nor reported (don't invite a re-PUT)
        }
    }
    misses
}

/// Garbage-collect the mailbox namespace: delete `haven/mailbox/**` entries idle longer
/// than `ttl`, plus abandoned `.part` temp files (> 1h old), then prune empty directories.
/// Returns how many entries were deleted. ONLY the mailbox is swept — media and self-sync
/// slots are permanent until explicitly erased. (Compat wrapper: a host with operator media
/// limits calls [`gc_sweep_with`] instead — this wrapper IS today's default behavior.)
pub fn gc_sweep(root: &Path, ttl: std::time::Duration, grace: std::time::Duration) -> usize {
    let retention = Retention { mailbox_ttl: ttl, ..Retention::default() };
    gc_sweep_with(root, &retention, grace).mailbox_deleted
}

/// One retention pass: the mailbox TTL sweep (always), then — ONLY when the operator set a
/// media limit — the media sweep: age first, then oldest-first size eviction, so with both
/// set whichever deletes more wins ("least amount of space"). Runs from the existing hourly
/// GC tick; nothing here is triggered mid-request.
///
/// Grace markers (both delayed by `grace` after first enable, created on first call):
/// * `.haven-gc-enabled` — the original mailbox marker (already ancient on live relays).
/// * `.haven-media-gc-enabled` — created the first time a MEDIA limit is active. Separate
///   from the mailbox marker on purpose: an operator adding a media limit to a relay that
///   has run for months must still get the 48h window for members' HAS/TOUCH traffic to
///   stamp live media before anything may be deleted.
pub fn gc_sweep_with(root: &Path, retention: &Retention, grace: std::time::Duration) -> GcStats {
    let mut stats = GcStats::default();

    // --- mailbox TTL sweep (unchanged semantics) -----------------------------------
    if marker_past_grace(&root.join(".haven-gc-enabled"), grace) {
        if let Ok(mailbox_root) = safe_path(root, MAILBOX_PREFIX) {
            let mut freed = 0u64; // mailbox bytes aren't reported; media accounting only
            sweep_dir(&mailbox_root, retention.mailbox_ttl.as_secs(), &mut stats.mailbox_deleted, &mut freed);
        }
    }

    // --- operator-chosen media retention (opt-in; absent limits = never touch media) --
    if !retention.media_limited() {
        return stats;
    }
    let Ok(media_root) = safe_path(root, MEDIA_PREFIX) else { return stats };
    if marker_past_grace(&root.join(".haven-media-gc-enabled"), grace) {
        // Age first: same idle clock as the mailbox (PUT / HAS hit / TOUCH refresh mtime),
        // so live media a member still references keeps getting its clock reset.
        if let Some(max_age) = retention.media_max_age {
            sweep_dir(&media_root, max_age.as_secs(), &mut stats.media_deleted_age, &mut stats.media_bytes_freed);
        }
        // Then size: evict oldest-first until under the cap. Applying age before size means
        // the size pass sees the already-thinned store — the "least space wins" order.
        if let Some(cap) = retention.media_max_bytes {
            let (n, freed) = evict_media_to_cap(root, &media_root, cap);
            stats.media_deleted_size = n;
            stats.media_bytes_freed += freed;
        }
    }
    stats.media_bytes_total = media_files(&media_root).iter().map(|(_, _, len)| len).sum();
    stats
}

/// True when `marker` exists and is older than `grace`. Creates it (and returns false) on
/// first sight — that creation is what starts the first-enable grace clock.
fn marker_past_grace(marker: &Path, grace: std::time::Duration) -> bool {
    if !marker.is_file() {
        if let Some(parent) = marker.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let _ = std::fs::write(marker, b"");
        return false;
    }
    idle_age_secs(marker) >= grace.as_secs()
}

/// Recursive TTL sweep under `dir`; removes directories that end up empty (best-effort).
fn sweep_dir(dir: &Path, ttl_secs: u64, deleted: &mut usize, bytes_freed: &mut u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            sweep_dir(&path, ttl_secs, deleted, bytes_freed);
            let _ = std::fs::remove_dir(&path); // only succeeds if now empty
        } else if path.is_file() {
            let is_part = path.extension().map(|e| e == "part").unwrap_or(false);
            let age = idle_age_secs(&path);
            // Abandoned temp writes go after an hour; real entries after the TTL.
            if (is_part && age > 3600) || (!is_part && age > ttl_secs) {
                let len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                if std::fs::remove_file(&path).is_ok() {
                    *deleted += 1;
                    *bytes_freed += len;
                }
            }
        }
    }
}

/// Every media blob under `media_root` as `(path, mtime-unix-secs, len)`. `.part` temps are
/// excluded — an in-flight PUT's temp must never be yanked out from under the rename (the
/// age sweep already reaps abandoned ones after an hour).
fn media_files(media_root: &Path) -> Vec<(PathBuf, u64, u64)> {
    fn walk(dir: &Path, out: &mut Vec<(PathBuf, u64, u64)>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, out);
            } else if path.is_file() && path.extension().map(|e| e != "part").unwrap_or(true) {
                let Ok(meta) = std::fs::metadata(&path) else { continue };
                let mtime = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                out.push((path, mtime, meta.len()));
            }
        }
    }
    let mut out = Vec::new();
    walk(media_root, &mut out);
    out
}

/// Size-cap eviction: while the media store exceeds `cap`, delete the OLDEST blob (by the
/// same mtime clock the age sweep uses — TOUCH/HAS refreshes push a blob toward the back of
/// the eviction line). Records the newest evicted mtime as the store's size-eviction
/// horizon so mesh sync won't immediately re-pull what was just evicted (see
/// [`keys_to_pull`]). Returns `(blobs deleted, bytes freed)`.
fn evict_media_to_cap(root: &Path, media_root: &Path, cap: u64) -> (usize, u64) {
    let mut files = media_files(media_root);
    let mut total: u64 = files.iter().map(|(_, _, len)| len).sum();
    if total <= cap {
        return (0, 0);
    }
    files.sort_by_key(|(_, mtime, _)| *mtime); // oldest first
    let mut deleted = 0usize;
    let mut freed = 0u64;
    let mut horizon = 0u64;
    for (path, mtime, len) in files {
        if total <= cap {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(len);
            freed += len;
            deleted += 1;
            horizon = horizon.max(mtime);
        }
    }
    if horizon > 0 {
        write_media_horizon(root, horizon);
    }
    prune_empty_dirs(media_root);
    (deleted, freed)
}

/// Remove now-empty directories under `dir` (best-effort, like the TTL sweep does).
fn prune_empty_dirs(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            prune_empty_dirs(&path);
            let _ = std::fs::remove_dir(&path); // only succeeds if now empty
        }
    }
}

/// The size-eviction horizon: unix-seconds mtime of the NEWEST media blob the size cap has
/// ever evicted from this store. Mesh sync refuses to pull media written at or before it —
/// a local cutoff under this operator's own cap, NOT a tombstone (siblings with more room
/// keep and serve their copies). 0 = no size eviction has happened.
fn read_media_horizon(root: &Path) -> u64 {
    std::fs::read_to_string(root.join(".haven-media-horizon"))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0)
}

/// Persist the size-eviction horizon (monotonic max — a later sweep never lowers it).
fn write_media_horizon(root: &Path, mtime_secs: u64) {
    let cur = read_media_horizon(root);
    if mtime_secs > cur {
        let _ = std::fs::write(root.join(".haven-media-horizon"), mtime_secs.to_string());
    }
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
            // Multipath on (parity with Node::spawn / connect_addr): without it a multipath-enabled
            // client's dial to this relay dies with MultipathNotNegotiated on cross-network paths.
            .transport_config(iroh::endpoint::QuicTransportConfig::builder().max_concurrent_multipath_paths(16).build())
            .bind()
            .await
            .ah()?;
        let srv = Arc::new(Self { endpoint, secret, root: root.clone(), auth: Arc::new(Mutex::new(RelayAuth::default())) });
        let acc = srv.clone();
        tokio::spawn(async move { acc.accept_loop(root).await });
        // Hourly mailbox GC (see the module docs): entries idle > MAILBOX_TTL age out; the
        // task holds only a Weak so a dropped server stops sweeping.
        let weak = Arc::downgrade(&srv);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(GC_INTERVAL).await;
                let Some(srv) = weak.upgrade() else { break };
                let _ = gc_sweep(&srv.root, MAILBOX_TTL, GC_GRACE);
            }
        });
        Ok(srv)
    }

    /// Authorize a circle's mailbox to exactly `members` (their node hexes), plus the circle's sibling
    /// `relays` (allowed to replicate). Idempotent; call again on any membership change to update the
    /// set.
    ///
    /// A relay serves ONLY what it has been authorized to serve — until this is called it has no
    /// members and therefore serves nobody (audit F4: "not configured yet" used to mean "allow
    /// everyone", which is how a stranger read a circle's blobs). Every host calls it: the daemon
    /// from the pasted link, the apps from each circle's roster.
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
        // Reuse THIS relay's existing endpoint — NEVER bind a fresh one with the same secret.
        // `BlobClient::connect(self.secret, …)` created an ephemeral endpoint under our OWN node id
        // every mesh tick: it STOLE our DERP relay registration (home-relay flapped true→false every
        // ~20s), refused every inbound handshake meanwhile (its ALPN list is empty), and died
        // ungracefully after the dial — so relay-path INBOUND to this node was effectively dead
        // (a friend's dial timed out at 30s while a direct-addressed dial worked in ~5ms).
        let client = BlobClient::over_endpoint(
            self.endpoint.clone(),
            EndpointAddr::new(parse_node_id(peer_node_hex)?),
        )?;
        // A standalone BlobServer has no operator retention knobs — default policy (media
        // unlimited), exactly today's behavior. The configurable host is Node::relay_sync_from.
        let pulled = pull_missing_from_peer(&self.root, &client, &Retention::default()).await;
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

/// One age-preserving anti-entropy pass: pull every blob the peer behind `client` holds
/// (under the Haven namespace) that `root` lacks. Shared by [`BlobServer::sync_pull_from`]
/// and the in-node relay attachment (`Node::relay_sync_from`) so the age semantics can't
/// drift apart. Entries past OUR retention limits are never pulled (mailbox TTL always;
/// media only under the operator's own limits), and a pulled file keeps the peer's idle
/// age (see [`keys_to_pull`] / [`backdate`]) — that pair is what stops mesh sync from
/// resurrecting GC'd entries forever.
pub(crate) async fn pull_missing_from_peer(
    root: &Path,
    client: &BlobClient,
    retention: &Retention,
) -> usize {
    // Age-aware inventory when the peer speaks AGES; a pre-GC peer only speaks LIST, so
    // everything it advertises counts as fresh (the old pull-everything behavior).
    let peer_keys = match client.list_ages(SYNC_PREFIX).await {
        Ok(v) => v,
        Err(_) => client
            .list(SYNC_PREFIX)
            .await
            .unwrap_or_default()
            .into_iter()
            .map(|k| (k, 0))
            .collect(),
    };
    let mut pulled = 0usize;
    for (key, age) in keys_to_pull(root, &peer_keys, retention) {
        let Ok(local) = safe_path(root, &key) else { continue };
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
            backdate(&local, age);
            pulled += 1;
        } else {
            let _ = std::fs::remove_file(&tmp);
        }
    }
    pulled
}

/// The circle id in a `haven/mailbox/<circle>/...` key, or None for non-mailbox / too-broad keys.
fn mailbox_circle(key: &str) -> Option<&str> {
    let rest = key.strip_prefix("haven/mailbox/")?;
    let circle = rest.split('/').next().unwrap_or("");
    (!circle.is_empty()).then_some(circle)
}

/// A prefix that spans more than one circle (or a whole namespace) — enumerating it is mesh-sync
/// territory, so only a sibling relay may. Naming a namespace ROOT is what makes a LIST broad;
/// `haven/mailbox/<circle>/` is narrow and stays member-gated.
fn is_broad_prefix(key: &str) -> bool {
    matches!(
        key,
        "haven"
            | "haven/"
            | "haven/mailbox"
            | "haven/mailbox/"
            | "haven/media"
            | "haven/media/"
            | "haven/devroster"
            | "haven/devroster/"
    )
}

/// The `haven/media/…`-style key prefix under which a device publishes its account-signed device
/// roster so a headless relay can authorize its device ids. Permissive to WRITE (not a mailbox key);
/// the trust comes from the signature check in [`verify_devroster`], never from the write gate — so
/// EVERY transport must verify the body before storing it (see [`verify_devroster_put`]).
pub(crate) const DEVROSTER_PREFIX: &str = "haven/devroster/";
/// Tag byte on the self-sync roster wire (mirror of haven-ffi `TAG_DEVICE_ROSTER`).
const TAG_DEVICE_ROSTER: u8 = 0x04;

/// Parse + CRYPTOGRAPHICALLY VERIFY a self-describing device-roster blob written to
/// `haven/devroster/<account>`. The blob is the same wire self-sync publishes under `roster:<acct>`:
/// a `TAG_DEVICE_ROSTER` byte, then `lp(account_bundle) ‖ lp(device_list) ‖ …` (u32-LE lengths).
/// Returns the account's currently-authorized device hexes ONLY when the carried bundle's node id
/// equals `expect_account` (the key) AND the DeviceList carries a valid HYBRID (ed25519+ML-DSA)
/// account signature. The relay holds only account NODE ids (from the link), which are insufficient
/// to verify the hybrid signature, so the blob is self-describing (carries the full bundle); binding
/// bundle→account via the key + verifying the signature means a stranger can neither impersonate the
/// account nor inject device ids for it. Revoked device ids are excluded.
fn verify_devroster(expect_account: &str, body: &[u8]) -> Option<(String, Vec<String>)> {
    let (account, devices, _version) = verify_devroster_full(expect_account, body)?;
    Some((account, devices))
}

/// Like [`verify_devroster`] but also returns the DeviceList `version`, so a write gate can enforce
/// rollback defense (higher-version-wins; a replayed OLD roster must never overwrite a newer one).
fn verify_devroster_full(expect_account: &str, body: &[u8]) -> Option<(String, Vec<String>, u64)> {
    use haven_p2p::device::DeviceList;
    use haven_p2p::identity::HavenId;
    let body = match body.split_first() {
        Some((&TAG_DEVICE_ROSTER, rest)) => rest,
        _ => return None,
    };
    fn lp(b: &[u8]) -> Option<(&[u8], &[u8])> {
        if b.len() < 4 {
            return None;
        }
        let n = u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize;
        let b = &b[4..];
        if b.len() < n {
            return None;
        }
        Some((&b[..n], &b[n..]))
    }
    let (bundle_bytes, rest) = lp(body)?;
    let (dl_bytes, _) = lp(rest)?;
    let bundle = HavenId::from_bytes(bundle_bytes).ok()?;
    if hex(&bundle.node_id_bytes()) != expect_account {
        return None; // the bundle must be the very account named in the key
    }
    let dl = DeviceList::from_bytes(dl_bytes).ok()?;
    dl.verify(&bundle).ok()?; // hybrid account signature — unforgeable
    let devices = dl
        .devices
        .iter()
        .filter(|d| !dl.revoked.contains(d))
        .map(|d| hex(d))
        .collect();
    Some((expect_account.to_string(), devices, dl.version))
}

/// Gate a device-roster PUT to `haven/devroster/<expect_account>` BEFORE the bytes are stored.
/// Returns the verified `(account, device_hexes)` to expand membership with when the write MAY
/// proceed, or `None` to REFUSE it entirely.
///
/// This is the write-side twin of the read gate, and it fails CLOSED exactly the same way: an
/// unsigned, malformed, or wrong-account body → `None`. The write is deliberately un-gated by
/// [`blob_forbidden`] (a device the relay has never heard of must be able to publish its first
/// roster), so this signature check is the ONLY thing standing between a stranger and a victim's
/// roster on disk. Without it a self-minted key could rename garbage over any account's roster
/// (audit R6).
///
/// Rollback defense (the roster flip-flop bug — see `DeviceList::adopt_if_newer`): a validly-signed
/// body whose `version` is strictly OLDER than the roster already on disk is refused, so a replayed
/// stale roster can only lose. A same-version re-publish is accepted (only the account key could
/// produce a different signed list at one version, so the bytes are effectively identical) — that
/// keeps a device's routine re-publish to a freshly-dialed relay working.
pub(crate) fn verify_devroster_put(
    root: &Path,
    expect_account: &str,
    body: &[u8],
) -> Option<(String, Vec<String>)> {
    let (account, devices, version) = verify_devroster_full(expect_account, body)?;
    // Never let an older signed version clobber a newer stored one. Both are account-signed and
    // versions only grow, so "newer wins" can't be forged and a replay can only be rejected.
    if let Ok(path) = safe_path(root, &format!("{DEVROSTER_PREFIX}{expect_account}")) {
        if let Ok(existing) = std::fs::read(&path) {
            if let Some((_, _, cur)) = verify_devroster_full(expect_account, &existing) {
                if version < cur {
                    return None;
                }
            }
        }
    }
    Some((account, devices))
}

/// Re-apply every stored `haven/devroster/<account>` blob to `auth` — so a relay that authorizes
/// circles fresh on startup/reconfigure (account ids only) re-expands to the accounts' device ids
/// without waiting for the apps to re-publish. Best-effort; unverifiable blobs are skipped.
pub(crate) fn rehydrate_device_rosters(root: &Path, auth: &Arc<Mutex<RelayAuth>>) {
    let Ok(dir) = safe_path(root, DEVROSTER_PREFIX) else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return;
    };
    for e in entries.flatten() {
        let acct = e.file_name().to_string_lossy().to_string();
        if let Ok(body) = std::fs::read(e.path()) {
            if let Some((account, devices)) = verify_devroster(&acct, &body) {
                auth.lock().unwrap().authorize_devices(&account, &devices);
            }
        }
    }
}

/// Authorization for one `haven/` blob op. Returns true if `peer` may NOT touch `key`.
///
/// Shared by BOTH transports: the iroh path passes the QUIC-verified `conn.remote_id()`, the HTTP
/// path passes the node hex proven by a per-request signature (see [`crate::httprelay`]). Neither
/// transport gets its own policy — a relay may not be a stronger boundary on one port than another.
///
/// Every branch is an explicit allow; the fallthrough is DENY (audit F4 — the old `None => false`
/// meant an unrecognized key, and every key outside `haven/mailbox/`, was public).
pub(crate) fn blob_forbidden(auth: &Arc<Mutex<RelayAuth>>, peer: &str, verb: u8, key: &str) -> bool {
    let a = auth.lock().unwrap();
    if a.relays.contains(peer) {
        return false; // sibling relay → may sync freely (mesh anti-entropy)
    }
    // A device roster is self-authenticating: `verify_devroster` refuses any blob whose signature
    // doesn't bind it to the account named in the key, so an unauthenticated write can inject
    // nothing. It must stay open — publishing the roster is how a device that the headless relay
    // has never heard of (it holds account ids only) becomes authorized in the first place.
    if verb == VERB_PUT && key.starts_with(DEVROSTER_PREFIX) && key.len() > DEVROSTER_PREFIX.len() {
        return false;
    }
    // A discovery record (`haven/disc/<node-hex>`) is self-authenticating for exactly the same
    // reason, and open for the same reason: a node no relay has heard of must be able to say where
    // it is, or it can never be found. Writes are re-verified by `verify_discovery_put` before any
    // bytes are stored; reads carry only routing hints the node published about ITSELF, which is
    // strictly less exposure than today's n0 DNS (where anyone on the internet may resolve any node
    // id). `discovery_node` matches ONE exact node key — never a prefix — so LIST/TOUCH/AGES fall
    // through to the membership + broad-prefix gates below and a relay cannot be enumerated for the
    // social graph.
    if matches!(verb, VERB_PUT | VERB_GET | VERB_HAS) && crate::discovery::discovery_node(key).is_some() {
        return false;
    }
    // Everything below requires the caller to be a member of SOME circle this relay serves. This
    // is the check that was entirely absent on the HTTP transport, and it is what a shared bearer
    // token can never establish: the token says "someone gave me a secret", not "I am Alice".
    let known = a.members.values().any(|m| m.contains(peer));
    if !known {
        return true;
    }
    if (verb == VERB_LIST || verb == VERB_AGES || verb == VERB_TOUCH) && is_broad_prefix(key) {
        return true; // a non-relay may not enumerate (or keep-alive) across circles
    }
    if let Some(circle) = mailbox_circle(key) {
        // DM mailboxes (`dm:<a>-<b>[-<c>…]`) are keyed by their PARTICIPANTS' account ids and are never
        // registered via authorize() on a SHARED/default relay whose host isn't a DM participant — so
        // `members.get("dm:…")` is None and every DM op returns ERR forbidden, silently breaking offline
        // DM store-and-forward. Gate DMs on known-membership instead (already established above). DM
        // bodies are E2E-sealed and keys are content-addressed, so a co-member can neither read nor forge
        // another member's DM — only relay it. (Real circle keys keep the exact per-circle check.)
        // Audit F18 tracks narrowing this to the participants via a keyed mailbox prefix.
        if circle.starts_with("dm:") {
            return false;
        }
        return !a.members.get(circle).map(|m| m.contains(peer)).unwrap_or(false);
    }
    // Media refs and device rosters are not per-circle addressable (a ref is an opaque handle that
    // names no circle), so members-of-this-relay is the tightest boundary available here. It is
    // still the difference between "any stranger" and "someone we serve".
    if key.starts_with("haven/media/") || key.starts_with(DEVROSTER_PREFIX) {
        return false;
    }
    true // unrecognized key under haven/ → deny
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
    // `self/` is owner-gated and `haven/` is membership-gated; a key in neither namespace belongs to
    // no one and is refused, so a new namespace can't arrive pre-authorized (audit F4).
    let allowed = if let Some(rest) = key.strip_prefix("self/") {
        rest.split('/').next().unwrap_or("") == peer
    } else if key == SYNC_PREFIX || key.starts_with("haven/") {
        // Circle-membership authorization: only a circle's members (or a sibling relay) may touch
        // its keys (audit F2/F4). `peer` here is the QUIC-verified endpoint id.
        !blob_forbidden(&auth, &peer, verb, &key)
    } else {
        false
    };
    if !allowed {
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

            // A devroster PUT is un-gated by `blob_forbidden` (any signed peer may publish, so a
            // never-seen device can enroll), so the ACCOUNT SIGNATURE — not the write gate — is the
            // trust. Verify it BEFORE renaming over the target, or a stranger clobbers a victim's
            // roster on disk (audit R6). Refuse an unsigned/forged/stale roster; carry the verified
            // devices forward to expand membership after the write.
            let roster = if let Some(acct) = key.strip_prefix(DEVROSTER_PREFIX) {
                match verify_devroster_put(&root, acct, &body) {
                    Some(v) => Some(v),
                    None => {
                        let _ = send.write_all(b"ERR forbidden").await;
                        let _ = send.finish();
                        return Ok(());
                    }
                }
            } else {
                None
            };

            // Same obligation for discovery records: `blob_forbidden` lets an unknown node PUT one,
            // so the record's SELF-signature is the only trust. Verify (with rollback defense) on
            // THIS transport too — a relay must never be a weaker boundary on iroh than on HTTP.
            if let Some(node) = crate::discovery::discovery_node(&key) {
                if crate::discovery::verify_discovery_put(&root, node, &body).is_none() {
                    let _ = send.write_all(b"ERR forbidden").await;
                    let _ = send.finish();
                    return Ok(());
                }
            }

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
                    // Device-roster authorization: expand this account's circle membership to include
                    // its (now-verified) device ids — so a HEADLESS relay (which only knows account
                    // ids from the operator's link) stops ERR-forbidding the account's devices' mailbox
                    // ops. The blob is persisted, so it also mesh-replicates to siblings and survives
                    // restart (see `rehydrate_device_rosters`).
                    if let Some((account, devices)) = roster {
                        auth.lock().unwrap().authorize_devices(&account, &devices);
                    }
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
            let exists = match safe_path(&root, &key) {
                Ok(p) if p.is_file() => {
                    // A HAS hit is proof the caller still cares about this entry —
                    // refresh its liveness stamp so mailbox GC keeps it.
                    touch_now(&p);
                    true
                }
                _ => false,
            };
            let _ = send.write_all(if exists { b"HIT" } else { b"MISS" }).await;
            let _ = send.finish();
        }
        VERB_TOUCH => {
            // Body = newline-joined keys to refresh; every key must live under the header
            // prefix (so per-circle membership auth above covers all of them). Reply:
            // "OK" + the keys we do NOT hold (the caller re-PUTs those — refresh = repair).
            let blen = recv.read_u64().await.ah()?;
            if blen > MAX_TOUCH_BODY {
                let _ = send.write_all(b"ERR too big").await;
                let _ = send.finish();
                return Ok(());
            }
            let mut body = vec![0u8; blen as usize];
            recv.read_exact(&mut body).await.ah()?;
            // Confine to the authorized prefix as a DIRECTORY ("fam" must not match "famX").
            let want = if key.ends_with('/') { key.clone() } else { format!("{key}/") };
            let keys: Vec<String> = String::from_utf8_lossy(&body)
                .lines()
                .filter(|k| k.starts_with(&want))
                .map(|k| k.to_string())
                .collect();
            let misses = local_touch(&root, &keys);
            let mut reply = String::from("OK");
            for m in &misses {
                reply.push('\n');
                reply.push_str(m);
            }
            let _ = send.write_all(reply.as_bytes()).await;
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
        VERB_AGES => {
            // LIST with idle ages: "<age-secs> <key>" per line — the age-preserving mesh
            // sync inventory. Same auth shape as LIST (checked above). A bad prefix yields
            // an empty reply — local_list's fall-back-to-root would enumerate self/ slots.
            let mut pairs =
                if safe_path(&root, &key).is_ok() { local_list_ages(&root, &key) } else { Vec::new() };
            pairs.sort();
            let body = pairs
                .into_iter()
                .map(|(k, age)| format!("{age} {k}"))
                .collect::<Vec<_>>()
                .join("\n");
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
                // Decode each on-disk component back to its wire form (see encode_comp).
                let key = rel
                    .components()
                    .map(|c| decode_comp(&c.as_os_str().to_string_lossy()))
                    .collect::<Vec<_>>()
                    .join("/");
                out.push(key);
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
    /// Whether WE bound `endpoint` (cold `connect_addr`) or borrowed a long-lived one
    /// (`over_endpoint`). `close()` must never shut down a borrowed endpoint — closing the
    /// node's shared messaging endpoint kills the whole transport.
    owns_endpoint: bool,
    /// When the last dial to `dest` failed, so a sick peer costs ONE dial per cooldown instead of one
    /// per operation. `conn()` re-dials whenever the cached connection has a close reason, and with a
    /// peer that is timing out that means every op starts a fresh dial: a field trace caught 1,320
    /// `haven/blob/1` connects in five minutes (~4-5/sec) plus 943 DNS lookups, each spinning up
    /// hole-punch machinery. That is why the phone ran hot. Failing fast during the cooldown also
    /// stops a doomed op from occupying its caller for the full 12s dial timeout.
    last_dial_fail: Arc<std::sync::Mutex<Option<std::time::Instant>>>,
}

/// How long to stop re-dialling a peer whose last dial failed.
const DIAL_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(5);

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
        Ok(Self { endpoint, dest, conn: Arc::new(tokio::sync::Mutex::new(None)), owns_endpoint: true, last_dial_fail: Arc::new(std::sync::Mutex::new(None)) })
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
        Ok(Self { endpoint, dest, conn: Arc::new(tokio::sync::Mutex::new(None)), owns_endpoint: false, last_dial_fail: Arc::new(std::sync::Mutex::new(None)) })
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
        // A recent dial failure means don't try again yet — see `last_dial_fail`.
        if let Ok(g) = self.last_dial_fail.lock() {
            if let Some(t) = *g {
                if t.elapsed() < DIAL_COOLDOWN {
                    bail!("relay dial in cooldown");
                }
            }
        }
        let dialed = tokio::time::timeout(DIAL_TIMEOUT, self.endpoint.connect(self.dest.clone(), BLOB_ALPN))
            .await
            .map_err(|_| anyhow!("relay dial timed out"))
            .and_then(|r| r.ah());
        match dialed {
            Ok(c) => {
                if let Ok(mut g) = self.last_dial_fail.lock() { *g = None; }
                *guard = Some(c.clone());
                Ok(c)
            }
            Err(e) => {
                if let Ok(mut g) = self.last_dial_fail.lock() { *g = Some(std::time::Instant::now()); }
                Err(e)
            }
        }
    }

    /// Store a (sealed) blob at `key`. The relay stores it verbatim.
    pub async fn put(&self, key: &str, body: &[u8]) -> Result<()> {
        if body.len() as u64 > MAX_BLOB {
            bail!("blob too large");
        }
        with_timeout("put", async {
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
        })
        .await
    }

    /// Fetch the (sealed) blob at `key`, or `None` if the relay doesn't have it.
    pub async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        with_timeout("get", async {
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
        })
        .await
    }

    /// Existence check for `key`.
    pub async fn has(&self, key: &str) -> Result<bool> {
        with_timeout("has", async {
            let conn = self.conn().await?;
            let (mut send, mut recv) = conn.open_bi().await.ah()?;
            write_header(&mut send, VERB_HAS, key).await?;
            send.write_u64(0).await.ah()?;
            send.finish().ah()?;
            let reply = recv.read_to_end(16).await.ah()?;
            Ok(reply == b"HIT")
        })
        .await
    }

    /// Refresh the liveness of `keys` (all under `prefix`, a single circle's mailbox path)
    /// so mailbox GC keeps them; returns the keys the relay does NOT hold — the caller
    /// re-PUTs those (refresh doubles as repair). One request for the whole batch.
    pub async fn touch(&self, prefix: &str, keys: &[String]) -> Result<Vec<String>> {
        let body = keys.join("\n");
        if body.len() as u64 > MAX_TOUCH_BODY {
            bail!("touch batch too large");
        }
        with_timeout("touch", async {
            let conn = self.conn().await?;
            let (mut send, mut recv) = conn.open_bi().await.ah()?;
            write_header(&mut send, VERB_TOUCH, prefix).await?;
            send.write_u64(body.len() as u64).await.ah()?;
            send.write_all(body.as_bytes()).await.ah()?;
            send.finish().ah()?;
            let reply = recv.read_to_end(MAX_TOUCH_BODY as usize + 16).await.ah()?;
            let text = String::from_utf8_lossy(&reply);
            let mut lines = text.lines();
            match lines.next() {
                Some("OK") => Ok(lines.map(|s| s.to_string()).collect()),
                other => bail!("touch failed: {}", other.unwrap_or("empty reply")),
            }
        })
        .await
    }

    /// Keys under `prefix` with idle ages ("seconds since last write/touch") — the
    /// age-preserving mesh-sync inventory. Errors against a pre-GC relay that doesn't
    /// speak AGES; callers fall back to [`Self::list`] (age 0 = fresh).
    pub async fn list_ages(&self, prefix: &str) -> Result<Vec<(String, u64)>> {
        with_timeout("ages", async {
            let conn = self.conn().await?;
            let (mut send, mut recv) = conn.open_bi().await.ah()?;
            write_header(&mut send, VERB_AGES, prefix).await?;
            send.write_u64(0).await.ah()?;
            send.finish().ah()?;
            let bytes = recv.read_to_end(MAX_BLOB as usize).await.ah()?;
            let text = String::from_utf8_lossy(&bytes);
            if text.starts_with("ERR") {
                bail!("ages failed: {text}");
            }
            let mut out = Vec::new();
            for line in text.lines() {
                let Some((age, key)) = line.split_once(' ') else { bail!("bad ages line") };
                out.push((key.to_string(), age.parse::<u64>().map_err(|_| anyhow!("bad age"))?));
            }
            Ok(out)
        })
        .await
    }

    /// List stored keys under `prefix` (e.g. a circle's mailbox path). Used to poll the
    /// mailbox for new sealed posts.
    pub async fn list(&self, prefix: &str) -> Result<Vec<String>> {
        with_timeout("list", async {
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
        })
        .await
    }

    pub async fn close(self) {
        if let Some(c) = self.conn.lock().await.take() {
            c.close(0u32.into(), b"done");
        }
        // Only shut down an endpoint WE bound. A borrowed (shared messaging) endpoint must
        // keep running — closing it would kill the node's whole transport.
        if self.owns_endpoint {
            self.endpoint.close().await;
        }
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
    fn dm_circle_keys_store_and_list() {
        // DM circle ids contain a colon ("dm:<a>-<b>") — previously REJECTED by safe_path, which
        // silently made every DM mailbox key unstorable on every relay. Keys keep the colon on the
        // wire; the disk mapping escapes it (Windows-safe).
        let root = Path::new("/store");
        let p = safe_path(root, "haven/mailbox/dm:aaa-bbb/hash1").unwrap();
        assert!(p.to_string_lossy().contains("dm%3Aaaa-bbb"));
        assert!(!p.to_string_lossy().contains(':'));
        // Round-trip through a real store: put under a dm key, list it back with the colon intact.
        let dir = std::env::temp_dir().join(format!("haven-dmkey-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        local_put(&dir, "haven/mailbox/dm:aaa-bbb/hash1", b"sealed").unwrap();
        let keys = local_list(&dir, "haven/mailbox/dm:aaa-bbb/");
        assert_eq!(keys, vec!["haven/mailbox/dm:aaa-bbb/hash1".to_string()]);
        // A trailing-slash LIST prefix must also work for ordinary circles.
        local_put(&dir, "haven/mailbox/fam/hash2", b"sealed").unwrap();
        assert_eq!(local_list(&dir, "haven/mailbox/fam/"), vec!["haven/mailbox/fam/hash2".to_string()]);
        // Escape round-trip sanity.
        assert_eq!(decode_comp(&encode_comp("dm:a%3Ab")), "dm:a%3Ab");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn keys_to_pull_skips_local_unsafe_and_expired() {
        let dir = std::env::temp_dir().join(format!("haven-sync-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("haven/mailbox/fam")).unwrap();
        // We already hold this one.
        std::fs::write(dir.join("haven/mailbox/fam/have"), b"x").unwrap();

        let ttl = MAILBOX_TTL.as_secs();
        let peer: Vec<(String, u64)> = vec![
            ("haven/mailbox/fam/have".to_string(), 0),    // already local → skip
            ("haven/mailbox/fam/missing".to_string(), 0), // we lack it → pull
            ("haven/media/blob1".to_string(), 0),         // we lack it → pull
            ("../etc/passwd".to_string(), 0),             // path traversal → never
            ("/abs/evil".to_string(), 0),                 // absolute → never
            // Mailbox entry already past the GC TTL on the peer → dying/deleted everywhere
            // else; pulling it would RESURRECT it. Never pull.
            ("haven/mailbox/fam/expired".to_string(), ttl + 5),
            // Media has no TTL by DEFAULT → an old age never blocks replication.
            ("haven/media/ancient".to_string(), ttl + 5),
        ];
        let want = keys_to_pull(&dir, &peer, &Retention::default());
        assert_eq!(
            want,
            vec![
                ("haven/mailbox/fam/missing".to_string(), 0),
                ("haven/media/blob1".to_string(), 0),
                ("haven/media/ancient".to_string(), ttl + 5),
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn touch_refreshes_ages_and_reports_misses() {
        let dir = std::env::temp_dir().join(format!("haven-touch-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        local_put(&dir, "haven/mailbox/fam/live", b"sealed").unwrap();
        let path = safe_path(&dir, "haven/mailbox/fam/live").unwrap();
        backdate(&path, 10 * 24 * 3600);
        assert!(idle_age_secs(&path) > 9 * 24 * 3600, "backdate applies");
        // local_list_ages reports the idle age alongside the key.
        let ages = local_list_ages(&dir, "haven/mailbox/fam/");
        assert_eq!(ages.len(), 1);
        assert!(ages[0].0 == "haven/mailbox/fam/live" && ages[0].1 > 9 * 24 * 3600);
        // TOUCH refreshes what exists, reports what doesn't, ignores unsafe keys.
        let misses = local_touch(
            &dir,
            &[
                "haven/mailbox/fam/live".to_string(),
                "haven/mailbox/fam/gone".to_string(),
                "../etc/passwd".to_string(),
            ],
        );
        assert_eq!(misses, vec!["haven/mailbox/fam/gone".to_string()]);
        assert!(idle_age_secs(&path) < 60, "touch resets the liveness clock");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn gc_sweeps_only_stale_mailbox_entries_after_grace() {
        let dir = std::env::temp_dir().join(format!("haven-gc-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        local_put(&dir, "haven/mailbox/fam/stale", b"x").unwrap();
        local_put(&dir, "haven/mailbox/dm:a-b/stale", b"x").unwrap();
        local_put(&dir, "haven/mailbox/fam/live", b"x").unwrap();
        local_put(&dir, "haven/media/ancient", b"x").unwrap();
        std::fs::write(dir.join("self-slot"), b"x").unwrap();
        let ttl_plus = MAILBOX_TTL.as_secs() + 24 * 3600;
        for key in ["haven/mailbox/fam/stale", "haven/mailbox/dm:a-b/stale", "haven/media/ancient"] {
            backdate(&safe_path(&dir, key).unwrap(), ttl_plus);
        }
        backdate(&dir.join("self-slot"), ttl_plus);
        // First call only plants the marker; nothing may be deleted inside the grace window.
        assert_eq!(gc_sweep(&dir, MAILBOX_TTL, GC_GRACE), 0);
        assert!(local_has(&dir, "haven/mailbox/fam/stale"));
        assert_eq!(gc_sweep(&dir, MAILBOX_TTL, GC_GRACE), 0, "still inside grace");
        // Age the marker past the grace → stale mailbox entries (and ONLY those) go.
        backdate(&dir.join(".haven-gc-enabled"), GC_GRACE.as_secs() + 3600);
        assert_eq!(gc_sweep(&dir, MAILBOX_TTL, GC_GRACE), 2);
        assert!(!local_has(&dir, "haven/mailbox/fam/stale"));
        assert!(!local_has(&dir, "haven/mailbox/dm:a-b/stale"));
        assert!(local_has(&dir, "haven/mailbox/fam/live"), "fresh entries survive");
        assert!(local_has(&dir, "haven/media/ancient"), "media is never swept");
        assert!(dir.join("self-slot").is_file(), "non-mailbox files are never swept");
        // The emptied dm circle directory is pruned; the still-populated one remains.
        assert!(!safe_path(&dir, "haven/mailbox/dm:a-b").unwrap().exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A fresh store with the given media entries at the given backdated ages; both grace
    /// markers pre-aged past the window so sweeps act immediately (the grace behavior itself
    /// is pinned by `gc_sweeps_only_stale_mailbox_entries_after_grace` +
    /// `media_age_sweep_waits_for_its_own_grace`).
    fn retention_store(tag: &str, entries: &[(&str, &[u8], u64)]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("haven-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for (key, body, age) in entries {
            local_put(&dir, key, body).unwrap();
            backdate(&safe_path(&dir, key).unwrap(), *age);
        }
        for marker in [".haven-gc-enabled", ".haven-media-gc-enabled"] {
            std::fs::write(dir.join(marker), b"").unwrap();
            backdate(&dir.join(marker), GC_GRACE.as_secs() + 3600);
        }
        dir
    }

    #[test]
    fn media_age_sweep_deletes_stale_spares_touched_and_fresh() {
        let day = 24 * 3600;
        let dir = retention_store(
            "media-age",
            &[
                ("haven/media/old", b"xxxx", 10 * day),     // past the limit → deleted
                ("haven/media/touched", b"xxxx", 10 * day), // past, but TOUCHed below → survives
                ("haven/media/fresh", b"xxxx", 1 * day),    // under the limit → survives
                ("haven/mailbox/fam/live", b"x", 0),        // mailbox untouched by media limits
            ],
        );
        // The TOUCH discipline: a client refreshing a ref resets its liveness clock, exactly
        // like the mailbox sweep honors.
        assert!(local_touch(&dir, &["haven/media/touched".to_string()]).is_empty());
        let ret = Retention {
            media_max_age: Some(std::time::Duration::from_secs(7 * day)),
            ..Retention::default()
        };
        let stats = gc_sweep_with(&dir, &ret, GC_GRACE);
        assert_eq!(stats.media_deleted_age, 1);
        assert_eq!(stats.media_deleted_size, 0);
        assert_eq!(stats.media_bytes_freed, 4);
        assert_eq!(stats.media_bytes_total, 8, "two 4-byte blobs remain");
        assert!(!local_has(&dir, "haven/media/old"));
        assert!(local_has(&dir, "haven/media/touched"), "TOUCH resets the eviction clock");
        assert!(local_has(&dir, "haven/media/fresh"));
        assert!(local_has(&dir, "haven/mailbox/fam/live"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn media_age_sweep_waits_for_its_own_grace() {
        // A relay that has run for months (ancient mailbox marker) and JUST enabled a media
        // limit must still give members 48h to stamp live media before anything is deleted.
        let dir = retention_store("media-grace", &[("haven/media/old", b"x", 400 * 24 * 3600)]);
        std::fs::remove_file(dir.join(".haven-media-gc-enabled")).unwrap();
        let ret = Retention {
            media_max_age: Some(std::time::Duration::from_secs(7 * 24 * 3600)),
            ..Retention::default()
        };
        // First sighting plants the media marker; nothing may be deleted yet.
        let stats = gc_sweep_with(&dir, &ret, GC_GRACE);
        assert_eq!(stats.media_deleted_age, 0);
        assert!(local_has(&dir, "haven/media/old"), "inside the media-enable grace window");
        // Past the grace → the stale blob goes.
        backdate(&dir.join(".haven-media-gc-enabled"), GC_GRACE.as_secs() + 3600);
        assert_eq!(gc_sweep_with(&dir, &ret, GC_GRACE).media_deleted_age, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn media_size_sweep_evicts_oldest_until_under_cap() {
        let day = 24 * 3600;
        let dir = retention_store(
            "media-size",
            &[
                ("haven/media/oldest", b"aaaa", 30 * day),
                ("haven/media/middle", b"bbbb", 20 * day),
                ("haven/media/newest", b"cccc", 10 * day),
            ],
        );
        // Under the cap → nothing deleted.
        let lax = Retention { media_max_bytes: Some(100), ..Retention::default() };
        let stats = gc_sweep_with(&dir, &lax, GC_GRACE);
        assert_eq!(stats.media_deleted_size, 0);
        assert_eq!(stats.media_bytes_total, 12);
        // Cap of 8 bytes with 12 stored → exactly the OLDEST blob is evicted.
        let capped = Retention { media_max_bytes: Some(8), ..Retention::default() };
        let stats = gc_sweep_with(&dir, &capped, GC_GRACE);
        assert_eq!(stats.media_deleted_size, 1);
        assert_eq!(stats.media_bytes_freed, 4);
        assert_eq!(stats.media_bytes_total, 8);
        assert!(!local_has(&dir, "haven/media/oldest"));
        assert!(local_has(&dir, "haven/media/middle"));
        assert!(local_has(&dir, "haven/media/newest"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn media_age_then_size_least_space_wins() {
        let day = 24 * 3600;
        let dir = retention_store(
            "media-both",
            &[
                ("haven/media/ancient", b"aaaa", 30 * day), // over the age limit
                ("haven/media/older", b"bbbb", 6 * day),    // under age; oldest survivor
                ("haven/media/newer", b"cccc", 2 * day),
                ("haven/media/newest", b"dddd", 1 * day),
            ],
        );
        let ret = Retention {
            media_max_age: Some(std::time::Duration::from_secs(7 * day)),
            media_max_bytes: Some(8),
            ..Retention::default()
        };
        let stats = gc_sweep_with(&dir, &ret, GC_GRACE);
        // Age deletes `ancient` (1 blob), THEN size sees 12 bytes > 8 and evicts the oldest
        // survivor (`older`). Net effect: the stricter combined rule — least space — wins.
        assert_eq!(stats.media_deleted_age, 1);
        assert_eq!(stats.media_deleted_size, 1);
        assert_eq!(stats.media_bytes_freed, 8);
        assert_eq!(stats.media_bytes_total, 8);
        assert!(local_has(&dir, "haven/media/newer") && local_has(&dir, "haven/media/newest"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn keys_to_pull_respects_own_media_retention() {
        let day = 24 * 3600;
        let dir = retention_store("media-pull", &[]);
        let ret = Retention {
            media_max_age: Some(std::time::Duration::from_secs(7 * day)),
            media_max_bytes: Some(1024),
            ..Retention::default()
        };
        let peer: Vec<(String, u64)> = vec![
            ("haven/media/fresh".to_string(), 1 * day),      // under our limit → pull
            ("haven/media/aged_out".to_string(), 10 * day),  // past OUR media age limit → never re-pull
            ("haven/mailbox/fam/ok".to_string(), 1 * day),   // mailbox unaffected by media limits
        ];
        assert_eq!(
            keys_to_pull(&dir, &peer, &ret),
            vec![
                ("haven/media/fresh".to_string(), 1 * day),
                ("haven/mailbox/fam/ok".to_string(), 1 * day),
            ],
            "an aged-out media key is not re-pulled under the same relay's config"
        );
        // The DEFAULT config (no media limits) still pulls ancient media — today's behavior.
        assert!(keys_to_pull(&dir, &peer, &Retention::default())
            .contains(&("haven/media/aged_out".to_string(), 10 * day)));

        // Size-eviction horizon: once the cap evicted blobs written up to time T, media at
        // or older than T is never re-pulled (otherwise every mesh tick would re-pull the
        // oldest blobs just for the next sweep to evict them again).
        local_put(&dir, "haven/media/big", &[0u8; 2000]).unwrap();
        backdate(&safe_path(&dir, "haven/media/big").unwrap(), 3 * day);
        let stats = gc_sweep_with(&dir, &ret, GC_GRACE);
        assert_eq!(stats.media_deleted_size, 1, "over the 1 KB cap → evicted");
        let peer2: Vec<(String, u64)> = vec![
            ("haven/media/big".to_string(), 3 * day),      // just evicted for size → don't re-pull
            ("haven/media/brand_new".to_string(), 0),      // newer than the horizon → pull
        ];
        assert_eq!(
            keys_to_pull(&dir, &peer2, &ret),
            vec![("haven/media/brand_new".to_string(), 0)]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn membership_auth_gates_strangers_but_allows_members_and_relays() {
        let auth: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        let member = "aa".repeat(32);
        let stranger = "bb".repeat(32);
        let sibling = "cc".repeat(32);
        let mbkey = format!("haven/mailbox/fam/{}", "00".repeat(32));

        // An unconfigured relay knows no members, so it serves nobody. (This asserted the
        // OPPOSITE before audit F4: "unconfigured" was read as "allow everything".)
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, &mbkey));

        // Configure circle 'fam' with one member + one sibling relay.
        auth.lock().unwrap().members.insert("fam".into(), [member.clone()].into_iter().collect());
        auth.lock().unwrap().relays.insert(sibling.clone());

        // The member may read their circle; a stranger may not (read, nor scoped enumerate).
        assert!(!blob_forbidden(&auth, &member, VERB_GET, &mbkey));
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, &mbkey));
        assert!(blob_forbidden(&auth, &stranger, VERB_LIST, "haven/mailbox/fam/"));

        // A stranger can't enumerate across circles; a sibling relay can (mesh anti-entropy).
        assert!(blob_forbidden(&auth, &stranger, VERB_LIST, "haven/"));
        assert!(!blob_forbidden(&auth, &sibling, VERB_LIST, "haven/"));
        assert!(!blob_forbidden(&auth, &sibling, VERB_GET, &mbkey));

        // A member may not enumerate a whole namespace either — only a sibling relay may.
        assert!(blob_forbidden(&auth, &member, VERB_LIST, "haven/media/"));
        assert!(blob_forbidden(&auth, &member, VERB_LIST, "haven/devroster/"));
        assert!(!blob_forbidden(&auth, &member, VERB_LIST, "haven/mailbox/fam/"));

        // Media and rosters are readable by the members this relay serves — and by no one else.
        // (F4: the stranger cases below both asserted "allowed" before the fix.)
        assert!(!blob_forbidden(&auth, &member, VERB_GET, "haven/media/blob1"));
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, "haven/media/blob1"));
        assert!(!blob_forbidden(&auth, &member, VERB_GET, "haven/devroster/deadbeef"));
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, "haven/devroster/deadbeef"));
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, "haven/mailbox/other/xyz"));

        // A roster WRITE stays open — that is how an unknown device becomes known, and
        // `verify_devroster` (not this gate) is what makes it unforgeable.
        assert!(!blob_forbidden(&auth, &stranger, VERB_PUT, "haven/devroster/deadbeef"));
        assert!(blob_forbidden(&auth, &stranger, VERB_PUT, DEVROSTER_PREFIX), "the prefix is not a roster");

        // Unrecognized keys under haven/ are denied rather than defaulted open.
        assert!(blob_forbidden(&auth, &member, VERB_GET, "haven/whatever/new"));

        // DMs are keyed by participant, never authorize()d, so they gate on known-membership.
        assert!(!blob_forbidden(&auth, &member, VERB_GET, "haven/mailbox/dm:a-b/x"));
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, "haven/mailbox/dm:a-b/x"));
    }
}
