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
//!   ENROLL haven/enroll/<circle> + members → teach the relay a circle it wasn't linked for
//! ```
//!
//! ## Why ENROLL exists (the frozen-relay incident)
//!
//! A relay used to learn its circles EXACTLY ONCE, from the link the operator pasted at startup —
//! `authorized 1 circle(s) from the link`, forever. Every circle created afterwards (above all the
//! `dm:` circles, which are minted on demand the first time two people message) was answered with
//! `ERR forbidden`, so those circles had **no store-and-forward at all**: a DM only landed if both
//! devices happened to be online simultaneously, which the user experienced as "received DMs only
//! show up on one of my devices". Re-pasting a fresh link was the only cure, and it was undone on
//! the next container restart (see `relay/docker/entrypoint.sh`).
//!
//! ENROLL turns the link into a *pairing handshake* rather than a frozen policy: once a member is
//! trusted, that member can keep teaching the relay which circles it belongs to. See
//! [`RelayAuth::learn`] for the authorization rule and why it is drawn where it is.
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
    endpoint::{Connection, Endpoint},
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

/// Cap on an ENROLL body — 256 members × 65 bytes, rounded up. Sized from `MAX_ENROLL_MEMBERS` so
/// an over-long body is rejected before it is buffered, not after.
const MAX_ENROLL_BODY: u64 = 24 * 1024;
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
/// Teach the relay an ADDITIONAL circle + members (key = `haven/enroll/<circle>`, body =
/// newline-joined member node hexes). Reply `OK` | `ERR …`. An older relay binary does not know
/// this verb and answers `ERR verb`, which is exactly the "degrade to today's behaviour" path a
/// new client needs — so callers must treat any error here as non-fatal.
///
/// Iroh-only, deliberately: the HTTP transport ([`crate::httprelay`]) has a closed set of routes
/// (`/k/`, `/l/`, `/t/`) and none of them map to this verb, so it cannot widen a relay's policy.
/// Every client already speaks iroh (that is how it learned the relay's node id), and keeping a
/// policy-mutating op on the QUIC-authenticated path means the caller's identity is the endpoint
/// key itself rather than a per-request signature over a shared token.
pub(crate) const VERB_ENROLL: u8 = b'E';
/// Teach the relay WHO ELSE serves a circle (key = `haven/enroll/<circle>`, body = newline-joined
/// relay node hexes), so it can mesh-replicate with its siblings.
///
/// The apps mesh automatically — they know every relay in the circle and pull from each one. A
/// HEADLESS relay knew only the `--peer` hexes its operator typed, so replication ran one way: the
/// app pulled from the NAS, the NAS never pulled back, and anything uploaded while it was offline
/// stayed missing there forever. It already auto-learns CIRCLES from paired members; this is the
/// same idea for siblings. An older relay answers `ERR verb` — the same degrade path ENROLL has.
pub(crate) const VERB_ENROLL_RELAYS: u8 = b'R';

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
    /// account hex → its VERIFIED device hexes, recorded whenever an account-signed devroster is
    /// accepted ([`Self::authorize_devices`] — verified PUTs on both transports + startup
    /// rehydrate). This is what lets a device touch its OWN account's `haven/self/…` slots under
    /// device-id-everywhere: the verified peer is a DEVICE id, the slot names the ACCOUNT, and
    /// only the stored account-signed roster can connect the two. Discloses nothing the relay
    /// doesn't already hold — the roster blob itself is stored (and served) at
    /// `haven/devroster/<acct>`.
    account_devices: HashMap<String, HashSet<String>>,
}

impl RelayAuth {
    /// Authorize a circle's mailbox to exactly `members` + the circle's sibling `relays`. Idempotent.
    /// Member / relay hexes are lowercased so HTTP-signed peers (always lowercase) match file-driven
    /// QA authorize lists and mixed-case account dumps (matrix: device id present but still REFUSED).
    pub fn authorize(&mut self, circle_id: &str, members: Vec<String>, relays: Vec<String>) {
        let members: HashSet<String> = members.into_iter().map(|m| m.to_lowercase()).collect();
        self.members.insert(circle_id.to_string(), members);
        for r in relays {
            self.relays.insert(r.to_lowercase());
        }
    }
    /// Expand every circle this account is a member of to ALSO include its DEVICE ids — called after a
    /// device roster written to `haven/devroster/<account>` is cryptographically verified. A device
    /// connects to a relay AS its device id, but a HEADLESS relay only knows account ids (from the
    /// operator's link), so without this it `ERR forbidden`s every one of the account's devices. The
    /// device ids come from an account-SIGNED DeviceList (see `verify_devroster`), so a stranger can't
    /// inject ids for someone else's account. Idempotent (HashSet insert).
    pub(crate) fn authorize_devices(&mut self, account_hex: &str, device_hexes: &[String]) {
        let acct = account_hex.to_lowercase();
        // Record the verified account→devices mapping REGARDLESS of circle membership — it backs
        // the `haven/self/…` owner gate (see `is_self_sync_owner`), which, like the old bare
        // `self/` gate, never required the account to be in a circle this relay serves.
        let set = self.account_devices.entry(acct.clone()).or_default();
        for d in device_hexes {
            set.insert(d.to_lowercase());
        }
        for members in self.members.values_mut() {
            if members.contains(&acct) {
                for d in device_hexes {
                    members.insert(d.to_lowercase());
                }
            }
        }
    }

    /// Drop explicitly-REVOKED device ids from this account's verified union — the in-memory set
    /// AND every circle expansion [`Self::authorize_devices`] made. Revocation is a positive,
    /// account-signed fact carried by a verified roster; ABSENCE never prunes (each device
    /// publishes its own partial roster, and a sibling missing from it must not be evicted — see
    /// [`save_devroster_devices`], where this distinction keeps the persisted union honest).
    pub(crate) fn revoke_devices(&mut self, account_hex: &str, revoked_hexes: &[String]) {
        let acct = account_hex.to_lowercase();
        for d in revoked_hexes {
            let d = d.to_lowercase();
            if d == acct {
                continue; // the account id comes from the operator's link, never from a roster
            }
            if let Some(set) = self.account_devices.get_mut(&acct) {
                set.remove(&d);
            }
            for members in self.members.values_mut() {
                if members.contains(&acct) {
                    members.remove(&d);
                }
            }
        }
    }

    /// Snapshot every account's VERIFIED device union — the persistence input for
    /// [`save_devroster_devices`]. Sorted (and empty accounts omitted) so the file is
    /// deterministic. Discloses nothing new: the same ids are served at `haven/devroster/<acct>`.
    pub(crate) fn device_unions(&self) -> Vec<(String, Vec<String>)> {
        let mut out: Vec<(String, Vec<String>)> = self
            .account_devices
            .iter()
            .filter(|(_, d)| !d.is_empty())
            .map(|(a, d)| {
                let mut ds: Vec<String> = d.iter().cloned().collect();
                ds.sort();
                (a.clone(), ds)
            })
            .collect();
        out.sort();
        out
    }

    /// May `peer` touch `account_hex`'s self-sync slots? Yes for the account id itself, and for
    /// any device named in the account's stored account-signed devroster. Device-id-everywhere is
    /// why the roster half exists: clients connect under their DEVICE ids (the account id is only
    /// the contact handle), so "peer == acct" alone silently killed the whole self-sync lane.
    pub(crate) fn is_self_sync_owner(&self, account_hex: &str, peer: &str) -> bool {
        let acct = account_hex.to_lowercase();
        let p = peer.to_lowercase();
        p == acct || self.account_devices.get(&acct).map(|d| d.contains(&p)).unwrap_or(false)
    }

    pub(crate) fn deauthorize(&mut self, circle_id: &str) {
        self.members.remove(circle_id);
    }

    /// True if `peer` is a member of at least ONE circle this relay serves — the "already paired"
    /// predicate. Same test `blob_forbidden` uses to let a caller past the front door.
    /// Union `members` into `circle_id` with NO caller checks — for replaying grants this relay
    /// already accepted (see [`rehydrate_learned_grants`]). Never call this on wire input; wire
    /// input goes through [`Self::learn`], which is where the authorization rule lives.
    pub(crate) fn merge_members(&mut self, circle_id: &str, members: &[String]) {
        let set = self.members.entry(circle_id.to_string()).or_default();
        for m in members {
            set.insert(m.clone());
        }
    }

    pub(crate) fn is_known(&self, peer: &str) -> bool {
        let p = peer.to_lowercase();
        self.members.values().any(|m| m.contains(&p))
    }

    /// True if `peer` is a member of THIS specific circle.
    pub(crate) fn is_member_of(&self, circle_id: &str, peer: &str) -> bool {
        let p = peer.to_lowercase();
        self.members.get(circle_id).map(|m| m.contains(&p)).unwrap_or(false)
    }

    pub(crate) fn knows_circle(&self, circle_id: &str) -> bool {
        self.members.contains_key(circle_id)
    }

    /// Number of circles currently authorized (link + learned) — bound-checking and operator output.
    pub(crate) fn circle_count(&self) -> usize {
        self.members.len()
    }

    /// LEARN a circle from a member instead of from the operator's link — the write half of the
    /// pairing handshake. Returns the circle's resulting member set (to persist) or `None` if the
    /// request is refused.
    ///
    /// ## The authorization rule, and why it is drawn here
    ///
    /// An arbitrary caller must never be able to enroll a circle, or every relay on the internet
    /// becomes free storage for strangers: the relay stores opaque sealed bytes, so "a circle" is
    /// nothing but a directory it will hold and serve for whoever it names. The trust anchor is
    /// therefore the one the operator already established by pasting the link:
    ///
    ///   1. **The caller must already be a member of some circle this relay serves.** This is the
    ///      *pairing* — it means the operator (or a circle they authorized) deliberately handed this
    ///      node the relay. A caller who fails this is refused before we ever get here
    ///      (`blob_forbidden`), so a stranger cannot enroll anything, ever.
    ///   2. **The caller must include ITSELF in the members it enrolls.** Without this, a trusted
    ///      member could point the relay at a circle of pure strangers and walk away — the relay
    ///      would then be serving people it has no relationship with, which is exactly the "free
    ///      storage for strangers" failure with one extra hop. Requiring self-inclusion keeps every
    ///      learned circle anchored to a node the operator already serves, and makes the co-members
    ///      *that member's own circle* — precisely who the operator meant to help.
    ///   3. **Enrolling into a circle the relay ALREADY knows requires membership OF THAT CIRCLE.**
    ///      This is the escalation guard. Without it, a member of circle A could insert themselves
    ///      (or friends) into circle B — including a circle the OPERATOR granted by link — and read
    ///      its mailbox. A new circle may be created freely by a trusted caller; an existing one may
    ///      only be *extended*, and only from the inside.
    ///
    /// Learning is **additive**: members are unioned in, never replaced. `authorize()` replaces a
    /// circle's set (it is the operator's authority speaking), so if learning replaced too, one
    /// device's partial view of a roster would silently evict everybody else — and, worse, a member
    /// could evict the operator's own link grant. Additive-only means the worst a misbehaving member
    /// can do is name people the relay then also serves, bounded by the caps below.
    pub(crate) fn learn(&mut self, circle_id: &str, peer: &str, members: &[String]) -> Option<Vec<String>> {
        // (1) pairing. `blob_forbidden` already refuses an unpaired caller before the body is read,
        // but this function IS the rule, so it re-checks: a future call site that forgets the front
        // door must not be able to open the relay to strangers. Fails closed on an empty map — a
        // relay that has been told about nobody can be taught by nobody.
        if !self.is_known(peer) {
            return None;
        }
        if circle_id.is_empty() || circle_id.len() > MAX_CIRCLE_ID {
            return None;
        }
        // (2) self-inclusion. The caller names itself or the request is meaningless.
        if !members.iter().any(|m| m == peer) {
            return None;
        }
        if members.len() > MAX_ENROLL_MEMBERS {
            return None;
        }
        for m in members {
            if m.len() != 64 || !m.bytes().all(|b| b.is_ascii_hexdigit()) {
                return None;
            }
        }
        if self.knows_circle(circle_id) {
            // (3) extend from the inside only.
            if !self.is_member_of(circle_id, peer) {
                return None;
            }
        } else {
            // A brand-new circle costs a map entry that lives until restart, so cap how many a
            // relay will accept. Without a cap, one trusted-but-compromised member could mint
            // circles in a loop and grow the auth map (and the persisted file) without bound.
            if self.circle_count() >= MAX_LEARNED_CIRCLES {
                return None;
            }
        }
        let set = self.members.entry(circle_id.to_string()).or_default();
        for m in members {
            if set.len() >= MAX_CIRCLE_MEMBERS && !set.contains(m) {
                continue; // same reasoning as MAX_LEARNED_CIRCLES, per circle
            }
            set.insert(m.clone());
        }
        let mut out: Vec<String> = set.iter().cloned().collect();
        out.sort();
        Some(out)
    }
}

/// Longest circle tag a relay will learn. Circle ids are opaque labels the apps mint
/// (`c1ABC…`, `dm:<a>-<b>`); a pathological one would only bloat the persisted grants file.
const MAX_CIRCLE_ID: usize = 128;
/// Most member ids one ENROLL may carry.
const MAX_ENROLL_MEMBERS: usize = 256;
/// Most members one learned circle may accumulate across many ENROLLs.
const MAX_CIRCLE_MEMBERS: usize = 1024;
/// Most circles a relay will hold in its auth map at all (link grants included). A relay serving a
/// household is nowhere near this; a member trying to mint circles in a loop hits it immediately.
const MAX_LEARNED_CIRCLES: usize = 1024;

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
    /// The server's own key. Retained so the server's identity is inspectable alongside its
    /// endpoint; nothing reads it today.
    #[allow(dead_code)]
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
        // Transport policy + multipath: `haven_endpoint_builder` (see endpoint_builder.rs).
        let endpoint = crate::haven_endpoint_builder()
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![BLOB_ALPN.to_vec()])
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
/// Chunk count declared by a `HVCHUNK1` chunk manifest, or None for a plain unchunked blob.
///
/// Deliberately a byte scan rather than a JSON parse: the body is written by exactly one producer
/// (`SharedStore.makeManifest`) as `{"v":1,"chunks":<n>,"total":<n>,"sizes":[…]}`, and a store-layer
/// integrity check should not need a serde dependency to read one integer. Anything that doesn't
/// match is treated as "not a manifest", which is the safe direction — it stores the blob as-is.
fn manifest_chunks(blob: &[u8]) -> Option<usize> {
    let rest = blob.strip_prefix(b"HVCHUNK1\n")?;
    let needle = b"\"chunks\":";
    let at = rest.windows(needle.len()).position(|w| w == needle)? + needle.len();
    let digits: String = rest[at..]
        .iter()
        .take_while(|b| b.is_ascii_digit())
        .map(|b| *b as char)
        .collect();
    digits.parse::<usize>().ok().filter(|n| *n > 0)
}

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
    // Cap pulls per mesh pass. Unbounded set-union against a large sibling (or a "dead" NAS that
    // still answers LIST) loaded multi‑hundred‑MB blobs into RAM every tick — Mac host sample
    // 4.6 GB peak / unresponsive while serving. Remainder is picked up on later passes.
    // Prefer mailbox keys first so event history converges before multi‑MB media.
    const MAX_MESH_PULLS_PER_PASS: usize = 24;
    let mut want = keys_to_pull(root, &peer_keys, retention);
    want.sort_by(|a, b| {
        let rank = |k: &str| {
            if k.starts_with("haven/mailbox/") {
                0
            } else if k.starts_with("haven/media/") {
                // Chunk WINDOWS before MANIFESTS. These are unrelated keys to this loop, and
                // `haven/media/<ref>` sorts lexicographically before `haven/media/<ref>.p/0`, so the
                // ~100-byte manifest was always pulled first and the 8 MiB windows came after — the
                // ones most likely to be cut off by the per-pass cap or to fail outright over a
                // cross-NAT dial. The reliable outcome was a manifest promising N chunks over a store
                // holding fewer, which readers stall on forever and the author's backup probe reads
                // as a finished upload. Windows first, and the manifest only once they are all here
                // (see the completeness gate in the pull loop below).
                if k.contains(".p/") {
                    2
                } else {
                    3
                }
            } else {
                1
            }
        };
        rank(&a.0).cmp(&rank(&b.0)).then_with(|| a.0.cmp(&b.0))
    });
    let mut pulled = 0usize;
    for (key, age) in want.into_iter().take(MAX_MESH_PULLS_PER_PASS) {
        let Ok(local) = safe_path(root, &key) else { continue };
        // Prefer mailbox / small keys first for liveness; still allow media within the cap.
        // `get` caps the read at MAX_BLOB, so an oversized body can't blow up memory.
        let Ok(Some(blob)) = client.get(&key).await else { continue };
        if blob.is_empty() {
            continue;
        }
        // A chunked blob's manifest is only useful once its windows are local. Storing one over a
        // partial chunk set is worse than storing nothing: readers treat a manifest as authoritative,
        // resume at the first absent window and fail there identically on every retry until the post
        // gives up as "no longer available" — and the AUTHOR's backup probe, which asks only whether
        // the manifest key exists, then reports the upload as safely landed and never re-sends the
        // missing windows. Windows are ranked ahead of manifests above so they arrive first; this is
        // the guarantee behind that preference. A skipped manifest costs nothing — a later pass takes
        // it once its chunks are here.
        if let Some(n) = manifest_chunks(&blob) {
            let complete = (0..n).all(|i| {
                safe_path(root, &format!("{key}.p/{i}"))
                    .map(|p| p.is_file())
                    .unwrap_or(false)
            });
            if !complete {
                continue;
            }
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
            | "haven/self"
            | "haven/self/"
    )
}

/// The owning `<acct>` of a self-sync slot key (`haven/self/<acct>/…`) — the namespace the apps
/// actually write (core `selfsync::slot_key` + the clients' `"haven/" + …` prefix, so the slots
/// ride relay mesh replication like every other `haven/` key). The namespace roots return None,
/// keeping them behind the broad-prefix / catch-all deny (F3: no cross-account enumeration).
fn self_sync_account(key: &str) -> Option<&str> {
    let rest = key.strip_prefix("haven/self/")?;
    let acct = rest.split('/').next().unwrap_or("");
    (!acct.is_empty()).then_some(acct)
}

/// The `haven/media/…`-style key prefix under which a device publishes its account-signed device
/// roster so a headless relay can authorize its device ids. Permissive to WRITE (not a mailbox key);
/// the trust comes from the signature check in [`verify_devroster`], never from the write gate — so
/// EVERY transport must verify the body before storing it (see [`verify_devroster_put`]).
pub(crate) const DEVROSTER_PREFIX: &str = "haven/devroster/";

/// Key prefix for the ENROLL control op: `haven/enroll/<circle>`. Nothing is ever STORED under it —
/// it is a control channel that happens to ride the same header shape as the storage verbs, so it
/// inherits `handle_request`'s namespace gate for free instead of inventing a second one.
pub(crate) const ENROLL_PREFIX: &str = "haven/enroll/";
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
/// account nor inject device ids for it. Returns `(account, live_devices, revoked_devices)` —
/// revoked ids are excluded from the live list and carried separately, because revocation is a
/// positive signed fact the union persistence must honor (see [`record_devroster`]).
fn verify_devroster(expect_account: &str, body: &[u8]) -> Option<(String, Vec<String>, Vec<String>)> {
    let (account, devices, revoked, _version) = verify_devroster_full(expect_account, body)?;
    Some((account, devices, revoked))
}

/// Like [`verify_devroster`] but also returns the DeviceList `version`, so a write gate can enforce
/// rollback defense (higher-version-wins; a replayed OLD roster must never overwrite a newer one).
fn verify_devroster_full(
    expect_account: &str,
    body: &[u8],
) -> Option<(String, Vec<String>, Vec<String>, u64)> {
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
    let revoked = dl.revoked.iter().map(|d| hex(d)).collect();
    Some((expect_account.to_string(), devices, revoked, dl.version))
}

/// Outcome of gating a device-roster PUT to `haven/devroster/<account>` (see
/// [`verify_devroster_put`]). BOTH transports (iroh + HTTP) branch on this so neither can drift.
pub(crate) enum DevrosterPut {
    /// Unsigned, malformed, or wrong-account body — refuse the write, authorize nothing.
    Refused,
    /// Account-signed AND `version` ≥ the stored blob's: STORE the bytes and record the full
    /// effect — authorize `devices`, apply the explicit `revoked` set.
    Store { account: String, devices: Vec<String>, revoked: Vec<String> },
    /// Account-signed but `version` STRICTLY OLDER than the stored blob's. The newer blob stays on
    /// disk (never downgraded), but the hybrid signature proves `devices` genuinely belong to
    /// `account`, so authorizing them discloses nothing and cannot be spoofed by a non-account
    /// party — add them to the authorization union anyway. This is the chicken-and-egg fix: a
    /// device that comes online AFTER a sibling published a higher-versioned roster (that omits it)
    /// can't self-heal by GET+merge+republish (devroster GET is member-gated and it isn't a member
    /// yet), so its own signed — but version-losing — PUT is the only proof of membership the relay
    /// will ever see. `devices` is PURELY ADDITIVE: any id the NEWER stored roster EXPLICITLY
    /// REVOKES has already been filtered out (a stale replay must never resurrect a revoked device),
    /// and the stale roster's OWN `revoked` set is dropped entirely (an older roster must never prune
    /// newer state — that would reopen the roster flip-flop). Absence never revokes; only the newest
    /// stored roster's explicit signed revocation prunes.
    AuthOnly { account: String, devices: Vec<String> },
}

/// Gate a device-roster PUT to `haven/devroster/<expect_account>` BEFORE the bytes are stored.
/// Returns a [`DevrosterPut`] telling the caller whether to store the blob and which verified
/// device ids to feed [`record_devroster`].
///
/// This is the write-side twin of the read gate, and it fails CLOSED exactly the same way: an
/// unsigned, malformed, or wrong-account body → [`DevrosterPut::Refused`]. The write is deliberately
/// un-gated by [`blob_forbidden`] (a device the relay has never heard of must be able to publish its
/// first roster), so this signature check is the ONLY thing standing between a stranger and a
/// victim's roster on disk. Without it a self-minted key could rename garbage over any account's
/// roster (audit R6).
///
/// Rollback defense (the roster flip-flop bug — see `DeviceList::adopt_if_newer`): a validly-signed
/// body whose `version` is strictly OLDER than the roster already on disk NEVER overwrites the newer
/// blob, and never contributes its own revocations. A same-version re-publish is accepted (only the
/// account key could produce a different signed list at one version, so the bytes are effectively
/// identical) — that keeps a device's routine re-publish to a freshly-dialed relay working.
///
/// The older-signed body still yields [`DevrosterPut::AuthOnly`] so its listed device ids expand the
/// authorization union (the account signature vouches for them), MINUS anything the newer stored
/// roster explicitly revokes. This is what lets a late-joining linked device escape the chicken-and-
/// egg lockout without ever letting a stale roster downgrade the stored blob or resurrect a revoked
/// device.
pub(crate) fn verify_devroster_put(
    root: &Path,
    expect_account: &str,
    body: &[u8],
) -> DevrosterPut {
    let Some((account, devices, revoked, version)) = verify_devroster_full(expect_account, body)
    else {
        return DevrosterPut::Refused;
    };
    // Compare against the stored blob (if any). Versions only grow and both bodies are
    // account-signed, so "newer wins" can't be forged and a replay can only lose the DISK — but a
    // signed replay's device ids are still genuine, so they join the auth union (minus ids the
    // newer stored roster explicitly revokes) rather than being dropped on the floor.
    if let Ok(path) = safe_path(root, &format!("{DEVROSTER_PREFIX}{expect_account}")) {
        if let Ok(existing) = std::fs::read(&path) {
            if let Some((_, _, stored_revoked, cur)) = verify_devroster_full(expect_account, &existing)
            {
                if version < cur {
                    let revoked_by_newer: HashSet<String> =
                        stored_revoked.iter().map(|d| d.to_lowercase()).collect();
                    let live: Vec<String> = devices
                        .into_iter()
                        .filter(|d| !revoked_by_newer.contains(&d.to_lowercase()))
                        .collect();
                    return DevrosterPut::AuthOnly { account, devices: live };
                }
            }
        }
    }
    DevrosterPut::Store { account, devices, revoked }
}

/// Re-apply every stored `haven/devroster/<account>` blob to `auth` — so a relay that authorizes
/// circles fresh on startup/reconfigure (account ids only) re-expands to the accounts' device ids
/// without waiting for the apps to re-publish. Best-effort; unverifiable blobs are skipped.
///
/// The stored blob alone is NOT enough: it is the LAST WRITER'S view (each device publishes its
/// own account-signed list, and the newest wholesale-replaces the file), while the authorization
/// this relay actually granted is the UNION of every verified PUT. That union is persisted
/// separately (see [`DEVROSTER_DEVICES_FILE`]) and merged back here — minus any id the stored
/// blob REVOKES, so a revocation that arrived by mesh replication (a blob synced from a sibling,
/// never PUT here) still prunes, and a stale union can never resurrect a revoked device.
pub(crate) fn rehydrate_device_rosters(root: &Path, auth: &Arc<Mutex<RelayAuth>>) {
    let mut revoked_by_acct: HashMap<String, HashSet<String>> = HashMap::new();
    if let Ok(dir) = safe_path(root, DEVROSTER_PREFIX) {
        if let Ok(entries) = std::fs::read_dir(&dir) {
            for e in entries.flatten() {
                let acct = e.file_name().to_string_lossy().to_string();
                if let Ok(body) = std::fs::read(e.path()) {
                    if let Some((account, devices, revoked)) = verify_devroster(&acct, &body) {
                        auth.lock().unwrap().authorize_devices(&account, &devices);
                        revoked_by_acct
                            .insert(account.to_lowercase(), revoked.into_iter().collect());
                    }
                }
            }
        }
    }
    for (account, devices) in load_devroster_devices(root) {
        let revoked = revoked_by_acct.get(&account.to_lowercase());
        let live: Vec<String> = devices
            .into_iter()
            .filter(|d| revoked.map_or(true, |r| !r.contains(&d.to_lowercase())))
            .collect();
        if !live.is_empty() {
            auth.lock().unwrap().authorize_devices(&account, &live);
        }
    }
}

// --- devroster union persistence (restart survival for multi-device fleets) -------------------

/// Where a relay remembers the UNION of verified device ids per account. The blob at
/// `haven/devroster/<acct>` is one device's own account-signed list and is wholesale-replaced by
/// the last writer — correct for the blob (it must stay byte-for-byte signature-verifiable, and a
/// relay-synthesized merge could never be), but the AUTHORIZATION built up from every verified PUT
/// is the union, and it lived only in memory. After a restart, rehydrate replayed the last
/// writer's partial view alone, so the account's OTHER devices answered `ERR forbidden`/403 until
/// their own heal re-published — a NAS relay that restarts nightly broke half the fleet every
/// morning. This file persists the verified device-id SET separately from the blobs (never an
/// unverifiable synthesized "signed" roster): it is the relay's own record of what it verified,
/// exactly what `RelayAuth::account_devices` holds, disclosing nothing the served blob doesn't.
///
/// Like [`LEARNED_GRANTS_FILE`], it lives at the store ROOT and **not** under `haven/`: no member
/// can read or overwrite it over the wire, and mesh sync can never replicate one relay's
/// authorization memory into another's.
const DEVROSTER_DEVICES_FILE: &str = "devroster-devices.json";

fn devroster_devices_path(root: &Path) -> PathBuf {
    root.join(DEVROSTER_DEVICES_FILE)
}

/// Read the persisted device unions: `(account, devices)` pairs. Best-effort — a missing or
/// corrupt file means "no union remembered", never a startup failure (the stored blobs still
/// rehydrate the last writer, and each device's heal re-publishes the rest).
pub(crate) fn load_devroster_devices(root: &Path) -> Vec<(String, Vec<String>)> {
    let Ok(bytes) = std::fs::read(devroster_devices_path(root)) else { return Vec::new() };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return Vec::new() };
    let Some(arr) = v.get("accounts").and_then(|a| a.as_array()) else { return Vec::new() };
    let mut out = Vec::new();
    for e in arr {
        let Some(acct) = e.get("a").and_then(|a| a.as_str()) else { continue };
        let Some(ds) = e.get("d").and_then(|d| d.as_array()) else { continue };
        // Re-validate on the way IN as well as on the way out, same as the learned grants: a relay
        // that trusts its own disk blindly would turn a corrupted byte into an authorized node id.
        if acct.len() != 64 || !acct.bytes().all(|b| b.is_ascii_hexdigit()) {
            continue;
        }
        let devices: Vec<String> = ds
            .iter()
            .filter_map(|d| d.as_str())
            .filter(|d| d.len() == 64 && d.bytes().all(|b| b.is_ascii_hexdigit()))
            .map(String::from)
            .collect();
        if devices.is_empty() {
            continue;
        }
        out.push((acct.to_string(), devices));
    }
    out
}

/// Persist the CURRENT in-memory device unions (every account). A snapshot of memory rather than
/// a file read-modify-write: memory is the serving truth, so the file can never disagree with it,
/// and concurrent verified PUTs for different accounts can't lose each other's entry the way two
/// interleaved file merges could. Atomic temp+rename, same as [`save_learned_grant`].
pub(crate) fn save_devroster_devices(root: &Path, auth: &Arc<Mutex<RelayAuth>>) {
    let unions = auth.lock().unwrap().device_unions();
    let doc = serde_json::json!({
        "v": 1,
        "accounts": unions
            .iter()
            .map(|(a, d)| serde_json::json!({ "a": a, "d": d }))
            .collect::<Vec<_>>(),
    });
    let Ok(bytes) = serde_json::to_vec(&doc) else { return };
    let path = devroster_devices_path(root);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("part");
    if std::fs::write(&tmp, &bytes).and_then(|_| std::fs::rename(&tmp, &path)).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// Apply one VERIFIED devroster's effect — expand the account's device authorization, drop its
/// explicitly-revoked ids — and persist the resulting union. The single post-PUT chokepoint for
/// BOTH transports (iroh + HTTP), so neither can drift: same expansion, same prune, same file.
/// Only ever call this with `verify_devroster_put` output, never with raw wire input — the file
/// must never contain a device id no account signature vouched for.
pub(crate) fn record_devroster(
    root: &Path,
    auth: &Arc<Mutex<RelayAuth>>,
    account: &str,
    devices: &[String],
    revoked: &[String],
) {
    {
        let mut a = auth.lock().unwrap();
        a.authorize_devices(account, devices);
        a.revoke_devices(account, revoked);
    }
    save_devroster_devices(root, auth);
}

// --- learned circle grants (the pairing handshake's persistent half) --------------------------

/// Where a relay remembers the circles its MEMBERS taught it (as opposed to the ones its operator
/// pasted in a link).
///
/// Deliberately at the store ROOT and **not** under `haven/`: keys under `haven/` are LISTable by
/// sibling relays and mesh-replicate between them, so a grants file living there would let one
/// relay in a mesh inject circles into every other relay's policy. Membership must only ever be
/// widened by a member that authenticated to THIS relay. It is also outside the namespace
/// `blob_forbidden` gates, so no member can read or overwrite it over the wire either.
const LEARNED_GRANTS_FILE: &str = "enrolled-circles.json";

fn learned_grants_path(root: &Path) -> PathBuf {
    root.join(LEARNED_GRANTS_FILE)
}

/// Read the persisted learned grants: `(circle, members)` pairs. Best-effort — a missing or corrupt
/// file simply means "nothing learned yet", never a startup failure. A relay that cannot read its
/// learned grants must still serve everything its LINK grants.
pub fn load_learned_grants(root: &Path) -> Vec<(String, Vec<String>)> {
    let Ok(bytes) = std::fs::read(learned_grants_path(root)) else { return Vec::new() };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return Vec::new() };
    let Some(arr) = v.get("grants").and_then(|g| g.as_array()) else { return Vec::new() };
    let mut out = Vec::new();
    for g in arr {
        let Some(circle) = g.get("c").and_then(|c| c.as_str()) else { continue };
        let Some(ms) = g.get("m").and_then(|m| m.as_array()) else { continue };
        // Re-validate on the way IN as well as on the way out. The file is ours, but a relay that
        // trusts its own disk blindly would turn a corrupted byte into an authorized node id.
        let members: Vec<String> = ms
            .iter()
            .filter_map(|m| m.as_str())
            .filter(|m| m.len() == 64 && m.bytes().all(|b| b.is_ascii_hexdigit()))
            .map(String::from)
            .collect();
        if circle.is_empty() || circle.len() > MAX_CIRCLE_ID || members.is_empty() {
            continue;
        }
        out.push((circle.to_string(), members));
    }
    out
}

/// Persist one learned grant (upserting the circle's full member set). Atomic temp+rename so a
/// crash mid-write can never leave a half-written policy file that reads as "no grants".
pub fn save_learned_grant(root: &Path, circle: &str, members: &[String]) {
    let mut grants = load_learned_grants(root);
    match grants.iter_mut().find(|(c, _)| c == circle) {
        Some(entry) => entry.1 = members.to_vec(),
        None => grants.push((circle.to_string(), members.to_vec())),
    }
    let doc = serde_json::json!({
        "v": 1,
        "grants": grants
            .iter()
            .map(|(c, m)| serde_json::json!({ "c": c, "m": m }))
            .collect::<Vec<_>>(),
    });
    let Ok(bytes) = serde_json::to_vec(&doc) else { return };
    let path = learned_grants_path(root);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("part");
    if std::fs::write(&tmp, &bytes).and_then(|_| std::fs::rename(&tmp, &path)).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// MERGE the persisted learned grants back into `auth`. Called after the link grants are applied,
/// never instead of them: `authorize()` REPLACES a circle's member set, so a learned expansion of a
/// link circle would be silently dropped on every restart (and on every reconfigure) if we did not
/// re-union it here. Same shape, and the same reason, as [`rehydrate_device_rosters`].
fn learned_relays_path(root: &Path) -> std::path::PathBuf {
    root.join("learned-relays.json")
}

/// Sibling relays this relay has been taught (see [`VERB_ENROLL_RELAYS`]). Re-validated on read:
/// the file is ours, but a relay that trusts its own disk blindly would turn a corrupted byte into
/// a host it dials on a timer.
pub fn load_learned_relays(root: &Path) -> Vec<String> {
    let Ok(bytes) = std::fs::read(learned_relays_path(root)) else { return Vec::new() };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return Vec::new() };
    let Some(arr) = v.get("relays").and_then(|r| r.as_array()) else { return Vec::new() };
    arr.iter()
        .filter_map(|r| r.as_str())
        .filter(|r| r.len() == 64 && r.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(|r| r.to_lowercase())
        .take(MAX_LEARNED_RELAYS)
        .collect()
}

/// Union `relays` into the learned-siblings file (idempotent, capped).
pub fn save_learned_relays(root: &Path, relays: &[String]) {
    let mut all = load_learned_relays(root);
    for r in relays {
        let r = r.to_lowercase();
        if r.len() == 64 && !all.contains(&r) && all.len() < MAX_LEARNED_RELAYS {
            all.push(r);
        }
    }
    let doc = serde_json::json!({ "v": 1, "relays": all });
    let Ok(bytes) = serde_json::to_vec(&doc) else { return };
    let path = learned_relays_path(root);
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, bytes);
}

/// Cap on remembered siblings. A circle's relay pool is a handful of hosts; the cap exists only so
/// a compromised member can't grow the file (and our dial loop) without bound.
const MAX_LEARNED_RELAYS: usize = 32;

pub(crate) fn rehydrate_learned_grants(root: &Path, auth: &Arc<Mutex<RelayAuth>>) {
    let grants = load_learned_grants(root);
    if grants.is_empty() {
        return;
    }
    let mut a = auth.lock().unwrap();
    for (circle, members) in grants {
        a.merge_members(&circle, &members);
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
    // Self-sync slots (`haven/self/<acct>/…`) are private to their owning ACCOUNT: the verified
    // peer must be the account id itself OR a device in the account's stored account-signed
    // devroster (audit F3 — nobody else may read, write, or even enumerate them; the scoped LIST
    // prefix names the account, so it goes through this same gate). No circle membership is
    // required — same contract as the legacy bare `self/` gate: a fleet syncs itself through any
    // relay it can reach. These keys used to fall through to the catch-all deny below (clients
    // key `haven/self/…`, the old gate only knew bare `self/…`), which is why the self-sync lane
    // was dead over every relay. Storage verbs only — ENROLL keeps its "must name an enroll key"
    // rule below regardless of who the caller is.
    if matches!(verb, VERB_PUT | VERB_GET | VERB_HAS | VERB_LIST | VERB_TOUCH | VERB_AGES) {
        if let Some(acct) = self_sync_account(key) {
            return !a.is_self_sync_owner(acct, peer);
        }
    }
    // Everything below requires the caller to be a member of SOME circle this relay serves. This
    // is the check that was entirely absent on the HTTP transport, and it is what a shared bearer
    // token can never establish: the token says "someone gave me a secret", not "I am Alice".
    let known = a.is_known(peer);
    if !known {
        return true;
    }
    // ENROLL — the second half of the pairing handshake. Being *already served by this relay* is the
    // entire front-door test, and a stranger can never satisfy it: `known` is false for them and we
    // returned deny one line above. The substantive rules (the caller must name itself, may not
    // escalate into a circle it isn't in, and is bounded by per-relay caps) need the request BODY,
    // so they live in `RelayAuth::learn` rather than here.
    if verb == VERB_ENROLL || verb == VERB_ENROLL_RELAYS {
        // Same shape gate for both teaching verbs; ENROLL_RELAYS' substantive rule (the caller must
        // already be in the circle) needs the request body and lives in the handler.
        return !key.starts_with(ENROLL_PREFIX) || key.len() <= ENROLL_PREFIX.len();
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
        let p = peer.to_lowercase();
        return !a.members.get(circle).map(|m| m.contains(&p)).unwrap_or(false);
    }
    // Media refs and device rosters are not per-circle addressable (a ref is an opaque handle that
    // names no circle), so members-of-this-relay is the tightest boundary available here. It is
    // still the difference between "any stranger" and "someone we serve".
    if key.starts_with("haven/media/") || key.starts_with(DEVROSTER_PREFIX) {
        return false;
    }
    // The relay's own interface document (its public HTTP URLs + bearer token + DERP/TURN),
    // written LOCALLY by the relay process at startup — READ-ONLY to anyone we serve. This is how
    // a client that can still dial the relay over iroh learns the CURRENT front door after a
    // restart rotated the free-tunnel URL: without it, a CLI relay's HTTP interface only ever
    // reached clients as a pasted wire string, so every tunnel rotation stranded all media
    // ("Waiting for sender…" while the blob sat on the relay). Members already receive exactly
    // these fields via sealed frame-19 announces, so serving them behind the same members-only
    // floor widens nothing. Remote writes stay denied (fallthrough): only `relay_local_put`
    // from inside the relay process can publish it.
    if key == RELAY_INTERFACE_KEY && matches!(verb, VERB_GET | VERB_HAS) {
        return false;
    }
    true // unrecognized key under haven/ → deny
}

/// Reserved key under which a relay publishes its OWN current interface (JSON:
/// `{v, gen, node, urls, token, derp, turn, turnUser, turnPass}`). Written locally by the relay
/// process at startup / front-door change; served read-only to any peer the relay serves.
pub const RELAY_INTERFACE_KEY: &str = "haven/relay/__interface__";

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

    // Self-sync slots are private to their owning account — only the account's OWN fleet (the
    // account id, or a device in its stored account-signed devroster: device-id-everywhere means
    // the verified peer is a device id) may read/write/list them (audit F3). Without this, any
    // node that learns the relay id could enumerate + fetch another account's device slots.
    // The CANONICAL keys are `haven/self/<acct>/…` and gate inside `blob_forbidden`
    // (self_sync_account) so both transports share one policy; this branch keeps the legacy bare
    // `self/…` namespace on the identical owner-or-roster-device rule. A key in neither namespace
    // belongs to no one and is refused, so a new namespace can't arrive pre-authorized (audit F4).
    let allowed = if let Some(rest) = key.strip_prefix("self/") {
        let acct = rest.split('/').next().unwrap_or("");
        !acct.is_empty() && auth.lock().unwrap().is_self_sync_owner(acct, &peer)
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
                    DevrosterPut::Store { account, devices, revoked } => {
                        Some((account, devices, revoked))
                    }
                    DevrosterPut::AuthOnly { account, devices } => {
                        // Lost the version race: the newer stored roster stays on disk (do NOT
                        // overwrite it), but the body is account-SIGNED, so its device ids genuinely
                        // belong to `account` — add them to the authorization union so a device that
                        // came online after a sibling published a higher-versioned roster can still
                        // be authorized (the chicken-and-egg lockout). Additive only: no revocations
                        // from the stale roster, and ids the newer roster revokes were already
                        // filtered out. Report OK — the PUT was legitimate; the relay simply had a
                        // newer blob to keep.
                        if !devices.is_empty() {
                            eprintln!(
                                "[haven relay] devroster PUT lost version race but {} signed device ids added to auth union",
                                devices.len()
                            );
                            record_devroster(&root, &auth, &account, &devices, &[]);
                        }
                        let _ = send.write_all(b"OK").await;
                        let _ = send.finish();
                        return Ok(());
                    }
                    DevrosterPut::Refused => {
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
                    // ops. The blob mesh-replicates to siblings; the UNION of every verified PUT is
                    // persisted alongside so a restart re-authorizes the whole fleet, not just this
                    // (partial) last writer (see `record_devroster` / `rehydrate_device_rosters`).
                    if let Some((account, devices, revoked)) = roster {
                        record_devroster(&root, &auth, &account, &devices, &revoked);
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
        VERB_ENROLL => {
            // Body = newline-joined member node hexes for `haven/enroll/<circle>`. Nothing is
            // written to the store: this only widens the in-memory policy and appends to the
            // learned-grants file, so a relay's disk can't be filled through this verb.
            let blen = recv.read_u64().await.ah()?;
            if blen > MAX_ENROLL_BODY {
                let _ = send.write_all(b"ERR too big").await;
                let _ = send.finish();
                return Ok(());
            }
            let mut body = vec![0u8; blen as usize];
            recv.read_exact(&mut body).await.ah()?;
            let circle = key.strip_prefix(ENROLL_PREFIX).unwrap_or("").to_string();
            let members: Vec<String> = String::from_utf8_lossy(&body)
                .lines()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            // `learn` holds the authorization rule and returns the circle's resulting member set
            // only when it accepted. Persist EXACTLY what it accepted — never the raw request —
            // so the file can only ever contain grants that passed the gate.
            let learned = auth.lock().unwrap().learn(&circle, &peer, &members);
            match learned {
                Some(set) => {
                    save_learned_grant(&root, &circle, &set);
                    let _ = send.write_all(b"OK").await;
                }
                None => {
                    let _ = send.write_all(b"ERR forbidden").await;
                }
            }
            let _ = send.finish();
        }
        VERB_ENROLL_RELAYS => {
            // Body = newline-joined relay node hexes. Like ENROLL, nothing is stored: this only
            // records who else serves the circle so the mesh loop can pull from them.
            let blen = recv.read_u64().await.ah()?;
            if blen > MAX_ENROLL_BODY {
                let _ = send.write_all(b"ERR too big").await;
                let _ = send.finish();
                return Ok(());
            }
            let mut body = vec![0u8; blen as usize];
            recv.read_exact(&mut body).await.ah()?;
            let circle = key.strip_prefix(ENROLL_PREFIX).unwrap_or("").to_string();
            let relays: Vec<String> = String::from_utf8_lossy(&body)
                .lines()
                .map(|s| s.trim().to_lowercase())
                .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
                .take(MAX_ENROLL_MEMBERS)
                .collect();
            // Same trust rule as ENROLL: only someone ALREADY inside the circle may teach us about
            // it. Without this any stranger who learned our node id could point our mesh loop at
            // arbitrary hosts and make us dial them on a timer.
            let ok = !circle.is_empty()
                && !relays.is_empty()
                && auth.lock().unwrap().is_member_of(&circle, &peer);
            if ok {
                save_learned_relays(&root, &relays);
                let _ = send.write_all(b"OK").await;
            } else {
                let _ = send.write_all(b"ERR forbidden").await;
            }
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
    /// Consecutive dial failures to `dest` (reset on success). Drives escalating cooldown so a
    /// permanently-dead relay id doesn't re-enter path discovery every mailbox poll.
    dial_fails: Arc<std::sync::atomic::AtomicU32>,
    /// Circles we have already tried to ENROLL with this relay, so a relay that refuses (or an OLD
    /// relay that answers `ERR verb`) costs one extra round trip per circle per process — not one on
    /// every mailbox op forever.
    enrolled: Arc<std::sync::Mutex<HashSet<String>>>,
}

/// Base cooldown after a blob dial failure. Escalates with `dial_fails` (see `blob_dial_cooldown`).
/// Was 5s — short enough that a 20–45s mailbox poll re-armed doomed dials continuously.
const DIAL_COOLDOWN_BASE: std::time::Duration = std::time::Duration::from_secs(60);
const DIAL_COOLDOWN_CAP: std::time::Duration = std::time::Duration::from_secs(900);

fn blob_dial_cooldown(fails: u32) -> std::time::Duration {
    let f = fails.max(1);
    let secs = (DIAL_COOLDOWN_BASE.as_secs() << (f.min(5) - 1)).min(DIAL_COOLDOWN_CAP.as_secs());
    std::time::Duration::from_secs(secs)
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
        let endpoint = crate::haven_endpoint_builder()
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![])
            .bind()
            .await
            .ah()?;
        // NEVER dial our OWN id. The relay client connects under our ACCOUNT identity (`secret`), so a
        // relay-list entry equal to our account id (e.g. left over from the pre-device-seed transport, when
        // the relay WAS the account id) would be the account dialing itself → the iroh path-discovery leak.
        if endpoint.id() == dest.id {
            anyhow::bail!("refusing to dial our own node id (blob self-connect guard)");
        }
        Ok(Self {
            endpoint,
            dest,
            conn: Arc::new(tokio::sync::Mutex::new(None)),
            owns_endpoint: true,
            last_dial_fail: Arc::new(std::sync::Mutex::new(None)),
            dial_fails: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            enrolled: Arc::new(std::sync::Mutex::new(HashSet::new())),
        })
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
        Ok(Self {
            endpoint,
            dest,
            conn: Arc::new(tokio::sync::Mutex::new(None)),
            owns_endpoint: false,
            last_dial_fail: Arc::new(std::sync::Mutex::new(None)),
            dial_fails: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            enrolled: Arc::new(std::sync::Mutex::new(HashSet::new())),
        })
    }

    /// Drop (and close) the cached connection after a failed op. On an ASYMMETRICALLY dead path
    /// — inbound keep-alives still arrive, our outbound goes into a void — `close_reason()` stays
    /// `None` forever, so the reuse check in `conn()` keeps handing every retry the same doomed
    /// connection and every op burns its full timeout. Evicting on failure makes the next op
    /// re-dial (the dial-cooldown machinery still rate-limits a truly dead relay). App-level
    /// refusals (Forbidden) skip this: the connection demonstrably works.
    async fn evict_conn_after_failure(&self) {
        let mut guard = self.conn.lock().await;
        if let Some(c) = guard.take() {
            c.close(0u32.into(), b"op-failed");
        }
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
        // Escalating cooldown after failures — see `dial_fails` / `blob_dial_cooldown`.
        let fails = self.dial_fails.load(std::sync::atomic::Ordering::Relaxed);
        if fails > 0 {
            if let Ok(g) = self.last_dial_fail.lock() {
                if let Some(t) = *g {
                    if t.elapsed() < blob_dial_cooldown(fails) {
                        bail!("relay dial in cooldown");
                    }
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
                self.dial_fails.store(0, std::sync::atomic::Ordering::Relaxed);
                *guard = Some(c.clone());
                Ok(c)
            }
            Err(e) => {
                if let Ok(mut g) = self.last_dial_fail.lock() { *g = Some(std::time::Instant::now()); }
                let _ = self.dial_fails.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                Err(e)
            }
        }
    }

    /// Our own node id as hex — what an ENROLL must name (the self-inclusion rule).
    pub fn my_node_hex(&self) -> String {
        hex(self.endpoint.id().as_bytes())
    }

    /// Teach this relay a circle + members — the client half of the pairing handshake. The relay
    /// applies [`RelayAuth::learn`]'s rule: we must already be one of its members, we must name
    /// OURSELVES in `members`, and we may only extend a circle we are already in.
    ///
    /// Failure is informational, never fatal. An OLDER relay has no ENROLL verb and answers
    /// `ERR verb` — that is exactly the "new client, old relay" degrade path, and the caller simply
    /// keeps using whatever the relay's link already authorized, as it did before this verb existed.
    /// Tell a relay who ELSE serves `circle`, so it can mesh-replicate with them. Best-effort:
    /// an older relay has no such verb and answers `ERR verb`, which is not an error worth
    /// surfacing — it simply keeps meshing with whatever its operator configured.
    pub async fn enroll_relays(&self, circle: &str, relays: &[String]) -> Result<()> {
        let key = format!("{ENROLL_PREFIX}{circle}");
        let body = relays.join("\n");
        if body.is_empty() || body.len() as u64 > MAX_ENROLL_BODY {
            bail!("relay list empty or too large");
        }
        with_timeout("enroll_relays", async {
            let conn = self.conn().await?;
            let (mut send, mut recv) = conn.open_bi().await.ah()?;
            write_header(&mut send, VERB_ENROLL_RELAYS, &key).await?;
            send.write_u64(body.len() as u64).await.ah()?;
            send.write_all(body.as_bytes()).await.ah()?;
            send.finish().ah()?;
            let reply = recv.read_to_end(64).await.ah()?;
            if reply == b"OK" {
                Ok(())
            } else {
                bail!("relay refused sibling list: {}", String::from_utf8_lossy(&reply))
            }
        })
        .await
    }

    pub async fn enroll(&self, circle: &str, members: &[String]) -> Result<()> {
        let key = format!("{ENROLL_PREFIX}{circle}");
        let body = members.join("\n");
        if body.len() as u64 > MAX_ENROLL_BODY {
            bail!("enroll member list too large");
        }
        with_timeout("enroll", async {
            let conn = self.conn().await?;
            let (mut send, mut recv) = conn.open_bi().await.ah()?;
            write_header(&mut send, VERB_ENROLL, &key).await?;
            send.write_u64(body.len() as u64).await.ah()?;
            send.write_all(body.as_bytes()).await.ah()?;
            send.finish().ah()?;
            let reply = recv.read_to_end(64).await.ah()?;
            if reply == b"OK" {
                Ok(())
            } else {
                bail!("enroll refused: {}", String::from_utf8_lossy(&reply))
            }
        })
        .await
    }

    /// A mailbox op was refused. Before giving up, teach the relay this key's circle (naming only
    /// OURSELVES, which is all a transport-layer client can honestly assert) and report whether it
    /// is worth retrying.
    ///
    /// This is the self-healing path for the frozen-relay incident: a relay learned its circles once,
    /// from the operator's link, so every circle created afterwards — above all the `dm:` circles,
    /// which are minted the first time two people message — was refused forever and had NO
    /// store-and-forward. A DM then only arrived if both devices were online at the same moment.
    ///
    /// At most one attempt per circle per process (see `enrolled`), so an old relay that answers
    /// `ERR verb`, or one that legitimately refuses, costs one round trip rather than one per op.
    async fn recover_forbidden(&self, key: &str) -> bool {
        let Some(circle) = mailbox_circle(key) else { return false };
        let circle = circle.to_string();
        {
            let mut seen = match self.enrolled.lock() {
                Ok(g) => g,
                Err(_) => return false,
            };
            if !seen.insert(circle.clone()) {
                return false;
            }
        }
        let me = self.my_node_hex();
        self.enroll(&circle, std::slice::from_ref(&me)).await.is_ok()
    }

    /// Store a (sealed) blob at `key`. The relay stores it verbatim.
    ///
    /// If the relay refuses because it has never heard of this key's circle, teach it (ENROLL) and
    /// retry ONCE — see [`Self::recover_forbidden`]. That retry is the whole point of the pairing
    /// handshake: before it, a circle minted after the operator pasted their link was `ERR forbidden`
    /// forever and had no store-and-forward at all.
    pub async fn put(&self, key: &str, body: &[u8]) -> Result<()> {
        if body.len() as u64 > MAX_BLOB {
            bail!("blob too large");
        }
        let out = match self.put_once(key, body).await {
            Err(e) if is_forbidden(&e) && self.recover_forbidden(key).await => {
                self.put_once(key, body).await
            }
            other => other,
        };
        if let Err(e) = &out {
            if !is_forbidden(e) {
                self.evict_conn_after_failure().await;
            }
        }
        out
    }

    async fn put_once(&self, key: &str, body: &[u8]) -> Result<()> {
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
        let out = with_timeout("get", async {
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
        .await;
        if let Err(e) = &out {
            if !is_forbidden(e) {
                self.evict_conn_after_failure().await;
            }
        }
        out
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
        match self.touch_once(prefix, keys).await {
            Err(e) if is_forbidden(&e) && self.recover_forbidden(prefix).await => {
                self.touch_once(prefix, keys).await
            }
            other => other,
        }
    }

    async fn touch_once(&self, prefix: &str, keys: &[String]) -> Result<Vec<String>> {
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
        match self.list_once(prefix).await {
            Err(e) if is_forbidden(&e) && self.recover_forbidden(prefix).await => {
                self.list_once(prefix).await
            }
            other => other,
        }
    }

    async fn list_once(&self, prefix: &str) -> Result<Vec<String>> {
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
            let text = String::from_utf8_lossy(&bytes);
            // An error reply is NOT a key list. Before this check `list` handed the caller
            // `["ERR forbidden"]` as though the relay held a blob by that name, which is how a
            // refusal could look like an empty-but-healthy mailbox instead of a policy problem.
            // Store keys always begin with the `haven/` (or `self/`) namespace, so no real listing
            // can collide with this.
            if text.starts_with("ERR ") {
                bail!("list failed: {}", text.lines().next().unwrap_or("ERR"));
            }
            Ok(text.lines().map(|s| s.to_string()).collect())
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

/// Did the relay refuse this op on policy grounds (rather than fail on transport)? Only a policy
/// refusal is worth answering with an ENROLL — a timeout or a dead connection must not be turned
/// into a retry storm.
fn is_forbidden(e: &anyhow::Error) -> bool {
    e.to_string().contains("ERR forbidden")
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
    fn manifest_chunks_reads_the_declared_window_count() {
        // Exactly what SharedStore.makeManifest writes, including the real field order.
        let real = b"HVCHUNK1\n{\"v\":1,\"chunks\":5,\"total\":40342326,\"sizes\":[8388608]}";
        assert_eq!(manifest_chunks(real), Some(5));
        assert_eq!(manifest_chunks(b"HVCHUNK1\n{\"chunks\":137}"), Some(137));
        // Anything that isn't a manifest is stored as-is — the safe direction.
        assert_eq!(manifest_chunks(b"\x00\x01\x02 sealed bytes"), None);
        assert_eq!(manifest_chunks(b"HVCHUNK1\n{\"v\":1}"), None, "no chunks field");
        assert_eq!(manifest_chunks(b"HVCHUNK1\n{\"chunks\":0}"), None, "0 is not a chunked blob");
    }

    #[test]
    fn mesh_sync_ranks_chunk_windows_ahead_of_their_manifest() {
        // The ordering that stops a manifest landing before the windows it promises. Plain
        // lexicographic order puts `<ref>` before `<ref>.p/0`, which is exactly backwards.
        let rank = |k: &str| {
            if k.starts_with("haven/mailbox/") {
                0
            } else if k.starts_with("haven/media/") {
                if k.contains(".p/") { 2 } else { 3 }
            } else {
                1
            }
        };
        assert!(rank("haven/media/vid_a.p/0") < rank("haven/media/vid_a"));
        assert!(rank("haven/mailbox/fam/e1") < rank("haven/media/vid_a.p/0"));
        assert!("haven/media/vid_a" < "haven/media/vid_a.p/0", "the order the rank has to override");
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

        // ENROLL's front door: a member the relay already serves may reach the verb; a stranger
        // never does. This is the ONLY thing standing between "a relay learns its user's circles"
        // and "any relay on the internet is free storage for anybody who learns its node id".
        let ekey = "haven/enroll/dm:a-b";
        assert!(!blob_forbidden(&auth, &member, VERB_ENROLL, ekey));
        assert!(blob_forbidden(&auth, &stranger, VERB_ENROLL, ekey), "an unpaired caller may not enroll");
        // …and the key must actually name a circle.
        assert!(blob_forbidden(&auth, &member, VERB_ENROLL, ENROLL_PREFIX));
        assert!(blob_forbidden(&auth, &member, VERB_ENROLL, "haven/mailbox/fam/x"));
    }

    /// The self-sync lane: `haven/self/<acct>/**` serves the account's OWN fleet — the account id
    /// itself, or a device its stored account-signed devroster names — and nobody else. This is
    /// the gate whose absence killed self-sync on every platform: the clients key `haven/self/…`,
    /// which used to fall to the catch-all deny, and the legacy owner test (`peer == acct`) never
    /// matched a device-id peer.
    #[test]
    fn self_sync_slots_gate_on_account_or_roster_device() {
        let auth: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        let acct = "aa".repeat(32);
        let dev = "bb".repeat(32);
        let stranger = "cc".repeat(32);
        let key = format!("haven/self/{acct}/state/{dev}");
        let prefix = format!("haven/self/{acct}/state/");

        // The account itself passes — even on a relay that serves it in no circle (the old bare
        // `self/` contract), and before any roster has landed.
        assert!(!blob_forbidden(&auth, &acct, VERB_PUT, &key));
        assert!(!blob_forbidden(&auth, &acct, VERB_GET, &key));
        assert!(!blob_forbidden(&auth, &acct, VERB_LIST, &prefix));

        // A device the relay holds NO roster for is denied — device-id-everywhere without the
        // roster is exactly the dead lane, and the deny is what makes publishing the roster the
        // remedy (RelayForbidden → heal → retry).
        assert!(blob_forbidden(&auth, &dev, VERB_GET, &key));
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, &key));

        // The verified devroster lands (both transports call authorize_devices after
        // verify_devroster_put; rehydrate replays it on restart) → the listed device passes.
        auth.lock().unwrap().authorize_devices(&acct, &[dev.clone()]);
        assert!(!blob_forbidden(&auth, &dev, VERB_PUT, &key));
        assert!(!blob_forbidden(&auth, &dev, VERB_GET, &key));
        assert!(!blob_forbidden(&auth, &dev, VERB_LIST, &prefix), "scoped LIST works for the fleet");

        // …but a non-roster peer stays denied, and a roster device may not cross accounts.
        assert!(blob_forbidden(&auth, &stranger, VERB_GET, &key));
        assert!(blob_forbidden(&auth, &stranger, VERB_LIST, &prefix), "F3: no cross-account enumerate");
        let other = format!("haven/self/{}/state/{dev}", "dd".repeat(32));
        assert!(blob_forbidden(&auth, &dev, VERB_GET, &other));

        // The namespace ROOT is never enumerable by a non-relay — only mesh siblings (F3).
        assert!(blob_forbidden(&auth, &acct, VERB_LIST, "haven/self"));
        assert!(blob_forbidden(&auth, &acct, VERB_LIST, "haven/self/"));
        let sibling = "ee".repeat(32);
        auth.lock().unwrap().relays.insert(sibling.clone());
        assert!(!blob_forbidden(&auth, &sibling, VERB_LIST, "haven/self/"), "mesh anti-entropy still replicates");
    }

    // ---- the pairing handshake: learning circles after the link ----------------------------

    fn learn_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("haven-learn-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The authorization rule, clause by clause. Each rejected case here is a way the relay would
    /// otherwise become storage for people its operator never agreed to serve.
    #[test]
    fn learn_enforces_the_pairing_rule() {
        let mut auth = RelayAuth::default();
        let alice = "aa".repeat(32);
        let bob = "bb".repeat(32);
        let mallory = "cc".repeat(32);
        auth.authorize("default", vec![alice.clone()], vec![]);
        // Mallory is a legitimate user of this relay too — she is in a circle of her own. That is
        // what makes her the interesting attacker: she is PAIRED, so clause (1) doesn't stop her.
        auth.authorize("mal", vec![mallory.clone()], vec![]);

        // (1) an UNPAIRED caller is refused even though the wire gate would have caught them first.
        let nobody = "dd".repeat(32);
        assert!(auth.learn("free-storage", &nobody, &[nobody.clone()]).is_none());
        assert!(!auth.knows_circle("free-storage"));

        // (2) the enroller must name ITSELF — otherwise a trusted member could point the relay at a
        // circle of pure strangers and walk away.
        assert!(auth.learn("dm:a-b", &alice, &[bob.clone()]).is_none());

        // A NEW circle, anchored by the caller: accepted, and co-members come along.
        let set = auth.learn("dm:a-b", &alice, &[alice.clone(), bob.clone()]).expect("new circle");
        assert_eq!(set.len(), 2);
        assert!(auth.is_member_of("dm:a-b", &bob));

        // (3) an EXISTING circle may only be extended from the inside. Mallory is known to this
        // relay (we add her to a circle of her own below) but is not in dm:a-b, so she may not
        // insert herself into it — that would be reading someone else's mailbox by declaration.
        assert!(auth.learn("dm:a-b", &mallory, &[mallory.clone()]).is_none());
        assert!(!auth.is_member_of("dm:a-b", &mallory));
        // Nor may she extend the OPERATOR'S link-granted circle.
        assert!(auth.learn("default", &mallory, &[mallory.clone()]).is_none());
        assert!(!auth.is_member_of("default", &mallory));

        // A member of the circle may extend it, and learning is ADDITIVE — the operator's link
        // grant is never evicted by one device's partial view of the roster.
        assert!(auth.learn("default", &alice, &[alice.clone(), bob.clone()]).is_some());
        assert!(auth.is_member_of("default", &alice));
        assert!(auth.is_member_of("default", &bob));

        // Malformed ids and empty tags are refused outright.
        assert!(auth.learn("", &alice, &[alice.clone()]).is_none());
        assert!(auth.learn("x", &alice, &[alice.clone(), "nothex".into()]).is_none());
        assert!(auth.learn("x", &alice, &[alice.clone(), "aa".repeat(40)]).is_none());
    }

    /// A relay may not be minted into unbounded circles by one compromised-but-trusted member.
    #[test]
    fn learn_is_capped() {
        let mut auth = RelayAuth::default();
        let alice = "aa".repeat(32);
        auth.authorize("default", vec![alice.clone()], vec![]);
        let mut accepted = 0;
        for i in 0..(MAX_LEARNED_CIRCLES + 50) {
            if auth.learn(&format!("c{i}"), &alice, &[alice.clone()]).is_some() {
                accepted += 1;
            }
        }
        assert!(accepted < MAX_LEARNED_CIRCLES + 50, "circle minting must hit a cap");
        assert!(auth.circle_count() <= MAX_LEARNED_CIRCLES);
        // An over-long member list is refused rather than truncated silently.
        let many: Vec<String> =
            std::iter::once(alice.clone()).chain((0..MAX_ENROLL_MEMBERS).map(|i| format!("{:064x}", i))).collect();
        assert!(auth.learn("big", &alice, &many).is_none());
    }

    /// A learned circle must survive a restart, and must MERGE with (never be replaced by) the
    /// operator's link grants. A relay that forgot what it learned on every restart is the frozen
    /// relay again — and the Docker footgun re-applied the link on every container start.
    #[test]
    fn learned_grants_persist_and_merge_with_link_grants() {
        let dir = learn_dir("persist");
        let alice = "aa".repeat(32);
        let bob = "bb".repeat(32);

        // --- run 1: link grants "default", alice teaches it a new DM circle -------------
        let auth1: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        auth1.lock().unwrap().authorize("default", vec![alice.clone()], vec![]);
        let set = auth1.lock().unwrap().learn("dm:a-b", &alice, &[alice.clone(), bob.clone()]).unwrap();
        save_learned_grant(&dir, "dm:a-b", &set);
        // alice also widens the link circle to bob (she is in it, so she may).
        let set2 = auth1.lock().unwrap().learn("default", &alice, &[alice.clone(), bob.clone()]).unwrap();
        save_learned_grant(&dir, "default", &set2);

        // --- run 2: fresh process, link re-applied verbatim (the Docker case) ----------
        let auth2: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        auth2.lock().unwrap().authorize("default", vec![alice.clone()], vec![]);
        // Before the merge the restart has thrown bob out of "default" and forgotten dm:a-b —
        // exactly the regression this replay exists to prevent.
        assert!(!auth2.lock().unwrap().is_member_of("default", &bob));
        assert!(!auth2.lock().unwrap().knows_circle("dm:a-b"));
        rehydrate_learned_grants(&dir, &auth2);
        assert!(auth2.lock().unwrap().knows_circle("dm:a-b"), "learned circle survives restart");
        assert!(auth2.lock().unwrap().is_member_of("dm:a-b", &bob));
        assert!(auth2.lock().unwrap().is_member_of("default", &bob), "learned members merge into a link circle");
        assert!(auth2.lock().unwrap().is_member_of("default", &alice), "the link grant itself survives");

        // The grants file lives OUTSIDE `haven/`, so members can't read it and mesh sync can't
        // replicate one relay's policy into another's.
        assert!(dir.join(LEARNED_GRANTS_FILE).is_file());
        assert!(!dir.join("haven").join(LEARNED_GRANTS_FILE).exists());
        let mut keys = Vec::new();
        collect_keys(&dir, &dir.join("haven"), &mut keys);
        assert!(keys.is_empty(), "the grants file must not be enumerable as a store key");

        // A corrupt file degrades to "nothing learned", never to a startup failure.
        std::fs::write(dir.join(LEARNED_GRANTS_FILE), b"{ not json").unwrap();
        assert!(load_learned_grants(&dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Only what `learn` ACCEPTED may reach the file — the persisted policy can never be wider than
    /// the live one, or a restart would grant what the gate refused.
    #[test]
    fn only_accepted_grants_are_persisted() {
        let dir = learn_dir("accepted");
        let alice = "aa".repeat(32);
        let mallory = "cc".repeat(32);
        let mut auth = RelayAuth::default();
        auth.authorize("default", vec![alice.clone()], vec![]);
        // mallory has never been served by this relay → refused, so nothing is written. The handler
        // only calls `save_learned_grant` with the set `learn` RETURNED, so a refusal cannot leave a
        // grant behind that a restart would then honour.
        assert!(auth.learn("mal", &mallory, &[mallory.clone()]).is_none());
        assert!(load_learned_grants(&dir).is_empty(), "a refused enroll persists nothing");
        assert!(!auth.knows_circle("mal"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- devroster union persistence: a restart must keep the WHOLE fleet authorized ---------

    /// The self-sync roster wire exactly as `haven-ffi::encode_roster` builds it (and as
    /// `tests/http_relay_probe.rs` drives it over HTTP): a `TAG_DEVICE_ROSTER` byte, then
    /// `lp(account_bundle) ‖ lp(device_list) ‖ u32(n_creds = 0)`.
    fn signed_roster_wire(
        account: &haven_p2p::identity::Identity,
        version: u64,
        devices: Vec<[u8; 32]>,
        revoked: Vec<[u8; 32]>,
    ) -> Vec<u8> {
        let dl = haven_p2p::device::DeviceList::signed(account, version, 1000, devices, revoked);
        let lp = |out: &mut Vec<u8>, b: &[u8]| {
            out.extend_from_slice(&(b.len() as u32).to_le_bytes());
            out.extend_from_slice(b);
        };
        let mut body = vec![TAG_DEVICE_ROSTER];
        lp(&mut body, &account.public().to_bytes());
        lp(&mut body, &dl.to_bytes());
        body.extend_from_slice(&0u32.to_le_bytes());
        body
    }

    /// Drive one devroster PUT exactly as BOTH transports do: verify (with rollback defense),
    /// store the blob when it wins, record the verified effect. Returns whether the blob was STORED
    /// (a version-losing but signed roster still expands the auth union, but its bytes never
    /// overwrite the newer blob, so it returns `false`).
    fn put_roster(dir: &Path, auth: &Arc<Mutex<RelayAuth>>, acct: &str, body: &[u8]) -> bool {
        match verify_devroster_put(dir, acct, body) {
            DevrosterPut::Store { account, devices, revoked } => {
                local_put(dir, &format!("{DEVROSTER_PREFIX}{acct}"), body).unwrap();
                record_devroster(dir, auth, &account, &devices, &revoked);
                true
            }
            DevrosterPut::AuthOnly { account, devices } => {
                // Newer blob stays put; still authorize the (newer-revoked-filtered) signed ids.
                if !devices.is_empty() {
                    record_devroster(dir, auth, &account, &devices, &[]);
                }
                false
            }
            DevrosterPut::Refused => false,
        }
    }

    /// Two devices each publish their OWN partial account-signed roster. The last writer's blob
    /// wholesale-replaces the first on disk — correct for the blob (a relay-merged roster could
    /// never carry a verifiable signature) — but the relay's AUTHORIZATION is the union, and the
    /// union must survive a restart. Before it was persisted, rehydrate replayed only the last
    /// writer's partial view, so the account's other device answered forbidden on every gate
    /// until its own heal re-published — a nightly-restart NAS relay broke half the fleet every
    /// morning.
    #[test]
    fn devroster_union_survives_restart_for_both_devices() {
        let dir = learn_dir("roster-union");
        let account = haven_p2p::identity::Identity::generate();
        let acct_hex = hex(&account.public().node_id_bytes());
        let (dev_a, dev_b) = ([0xA5u8; 32], [0xB6u8; 32]);
        let (a_hex, b_hex) = (hex(&dev_a), hex(&dev_b));

        // --- run 1: each device publishes its own PARTIAL roster (B's is newer → owns the disk).
        let auth1: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        assert!(put_roster(&dir, &auth1, &acct_hex, &signed_roster_wire(&account, 1, vec![dev_a], vec![])));
        assert!(put_roster(&dir, &auth1, &acct_hex, &signed_roster_wire(&account, 2, vec![dev_b], vec![])));
        // The stored blob is the last writer's alone — exactly the bug's setup.
        let stored =
            std::fs::read(safe_path(&dir, &format!("{DEVROSTER_PREFIX}{acct_hex}")).unwrap()).unwrap();
        let (_, stored_devices, _) = verify_devroster(&acct_hex, &stored).unwrap();
        assert_eq!(stored_devices, vec![b_hex.clone()], "last writer wholesale-replaced the blob");
        assert!(auth1.lock().unwrap().is_self_sync_owner(&acct_hex, &a_hex));
        assert!(auth1.lock().unwrap().is_self_sync_owner(&acct_hex, &b_hex));

        // --- run 2 (restart): fresh auth, link re-applied (ACCOUNT ids only), rehydrate.
        let auth2: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        auth2.lock().unwrap().authorize("fam", vec![acct_hex.clone()], vec![]);
        rehydrate_device_rosters(&dir, &auth2);

        // BOTH devices pass the self-sync gate AND the mailbox gate — not just the last writer.
        let self_key = format!("haven/self/{acct_hex}/state/x");
        for d in [&a_hex, &b_hex] {
            assert!(
                auth2.lock().unwrap().is_self_sync_owner(&acct_hex, d),
                "device {d} lost self-sync across the restart"
            );
            assert!(!blob_forbidden(&auth2, d, VERB_GET, &self_key));
            assert!(!blob_forbidden(&auth2, d, VERB_PUT, &self_key));
            assert!(
                !blob_forbidden(&auth2, d, VERB_GET, "haven/mailbox/fam/msg1"),
                "device {d} lost the mailbox across the restart"
            );
        }
        // A stranger still gets nothing — the union widens the fleet, never the world.
        assert!(blob_forbidden(&auth2, &"cc".repeat(32), VERB_GET, &self_key));

        // The union file lives OUTSIDE `haven/`, so members can't touch it over the wire and mesh
        // sync can't replicate one relay's authorization memory into another's.
        assert!(dir.join(DEVROSTER_DEVICES_FILE).is_file());
        let mut keys = Vec::new();
        collect_keys(&dir, &dir.join("haven"), &mut keys);
        assert!(
            !keys.iter().any(|k| k.contains(DEVROSTER_DEVICES_FILE)),
            "the union file must not be enumerable as a store key"
        );

        // A corrupt union file degrades to "last writer only", never to a startup failure.
        std::fs::write(dir.join(DEVROSTER_DEVICES_FILE), b"{ not json").unwrap();
        assert!(load_devroster_devices(&dir).is_empty());
        let auth3: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        rehydrate_device_rosters(&dir, &auth3);
        assert!(auth3.lock().unwrap().is_self_sync_owner(&acct_hex, &b_hex));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Explicit revocation must prune the persisted union — an additive-forever file would keep a
    /// revoked device authorized across restarts, which is exactly the rollback the signed
    /// `revoked` set exists to prevent. ABSENCE stays non-destructive: a device's partial roster
    /// never evicts its siblings; only the positive, account-signed revoked entry prunes.
    #[test]
    fn devroster_union_prunes_revoked_but_not_absent_devices() {
        let dir = learn_dir("roster-revoke");
        let account = haven_p2p::identity::Identity::generate();
        let acct_hex = hex(&account.public().node_id_bytes());
        let (dev_a, dev_b, dev_c) = ([1u8; 32], [2u8; 32], [3u8; 32]);
        let (a_hex, b_hex, c_hex) = (hex(&dev_a), hex(&dev_b), hex(&dev_c));
        let auth: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        auth.lock().unwrap().authorize("fam", vec![acct_hex.clone()], vec![]);

        // A and B union; A's ABSENCE from B's newer partial roster prunes nothing…
        assert!(put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&account, 1, vec![dev_a], vec![])));
        assert!(put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&account, 2, vec![dev_b], vec![])));
        assert!(auth.lock().unwrap().is_self_sync_owner(&acct_hex, &a_hex));

        // …but an explicit account-signed REVOCATION prunes A everywhere: the live gates…
        assert!(put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&account, 3, vec![dev_b], vec![dev_a])));
        assert!(!auth.lock().unwrap().is_self_sync_owner(&acct_hex, &a_hex));
        assert!(
            blob_forbidden(&auth, &a_hex, VERB_GET, "haven/mailbox/fam/msg1"),
            "a revoked device kept its mailbox access"
        );
        assert!(auth.lock().unwrap().is_self_sync_owner(&acct_hex, &b_hex));

        // …the persisted union…
        assert_eq!(load_devroster_devices(&dir), vec![(acct_hex.clone(), vec![b_hex.clone()])]);

        // …and a restart (neither the blob nor the union file may resurrect A).
        let auth2: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        rehydrate_device_rosters(&dir, &auth2);
        assert!(!auth2.lock().unwrap().is_self_sync_owner(&acct_hex, &a_hex));
        assert!(auth2.lock().unwrap().is_self_sync_owner(&acct_hex, &b_hex));

        // A revocation that arrived by MESH SYNC (blob landed on disk, never PUT here, so the
        // union file was never updated) still prunes on rehydrate — the stale union must not
        // resurrect a device the newest signed blob revokes.
        let synced = signed_roster_wire(&account, 4, vec![dev_c], vec![dev_a, dev_b]);
        std::fs::write(safe_path(&dir, &format!("{DEVROSTER_PREFIX}{acct_hex}")).unwrap(), &synced)
            .unwrap();
        let auth3: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        rehydrate_device_rosters(&dir, &auth3);
        assert!(auth3.lock().unwrap().is_self_sync_owner(&acct_hex, &c_hex));
        assert!(
            !auth3.lock().unwrap().is_self_sync_owner(&acct_hex, &b_hex),
            "a stale union resurrected a mesh-revoked device"
        );
        assert!(!auth3.lock().unwrap().is_self_sync_owner(&acct_hex, &a_hex));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Only what `verify_devroster_put` ACCEPTED reaches the union file — a forged or stale
    /// roster must not leave device ids behind that a restart would then honour. The write-side
    /// twin of `only_accepted_grants_are_persisted`.
    #[test]
    fn refused_roster_puts_persist_no_devices() {
        let dir = learn_dir("roster-refused");
        let auth: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        let account = haven_p2p::identity::Identity::generate();
        let acct_hex = hex(&account.public().node_id_bytes());
        let (dev_a, dev_b) = ([1u8; 32], [2u8; 32]);

        // Unsigned garbage → refused; nothing stored, nothing persisted.
        assert!(!put_roster(&dir, &auth, &acct_hex, b"POISONED-NOT-A-SIGNED-ROSTER"));
        assert!(!dir.join(DEVROSTER_DEVICES_FILE).exists(), "a refused PUT persisted a union");

        // A validly-signed but STALE replay (v1 after v2 revoked its device) never overwrites the
        // newer blob, and — crucially — its version-losing device id is NOT re-authorized because
        // the newer stored roster EXPLICITLY revokes it. So the blob isn't stored (`false`) and the
        // union keeps exactly v2's effect: a stale replay can never resurrect a revoked device.
        assert!(put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&account, 2, vec![dev_b], vec![dev_a])));
        assert!(!put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&account, 1, vec![dev_a], vec![])));
        assert_eq!(load_devroster_devices(&dir), vec![(acct_hex.clone(), vec![hex(&dev_b)])]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The linked-device lockout (the live bug): a device that comes ONLINE at a relay AFTER a
    /// sibling published a higher-versioned account roster there could never get authorized for
    /// CUSTOM circles. The relay maps device→account only from the account-signed roster; the
    /// sibling's newer roster (its own device set) wins the version race and OMITS the late device,
    /// and the late device's own signed PUT LOSES the rollback check — yet it can't self-heal
    /// (devroster GET is member-gated and it isn't a member yet). Fix: a version-LOSING but
    /// account-signed PUT still contributes its listed device ids to the auth union (the signature
    /// proves they belong to the account), while the newer blob stays stored. ABSENCE — not
    /// revocation — is why the late device was missing, so it must be admitted.
    #[test]
    fn version_losing_signed_roster_still_authorizes_its_devices() {
        let dir = learn_dir("roster-late-join");
        let account = haven_p2p::identity::Identity::generate();
        let acct_hex = hex(&account.public().node_id_bytes());
        let (dev_b, dev_c) = ([0xB1u8; 32], [0xC2u8; 32]);
        let (b_hex, c_hex) = (hex(&dev_b), hex(&dev_c));
        let auth: Arc<Mutex<RelayAuth>> = Arc::new(Mutex::new(RelayAuth::default()));
        auth.lock().unwrap().authorize("fam", vec![acct_hex.clone()], vec![]);

        // Sibling B publishes the HIGHER-versioned roster first (its own device set, omitting C).
        assert!(put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&account, 2, vec![dev_b], vec![])));

        // Late device C publishes its OWN account-signed roster, but at a LOWER version → it loses
        // the rollback race, so the stored blob must stay B's v2 (never downgraded)…
        assert!(!put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&account, 1, vec![dev_c], vec![])));
        let stored =
            std::fs::read(safe_path(&dir, &format!("{DEVROSTER_PREFIX}{acct_hex}")).unwrap()).unwrap();
        let (_, stored_devices, _) = verify_devroster(&acct_hex, &stored).unwrap();
        assert_eq!(stored_devices, vec![b_hex.clone()], "a version-losing PUT must not downgrade the blob");

        // …yet BOTH B and C are now authorized — C escaped the chicken-and-egg lockout via its own
        // signed (but version-losing) PUT. Self-sync owner gate AND the custom-circle mailbox gate.
        let self_key = format!("haven/self/{acct_hex}/state/x");
        for d in [&b_hex, &c_hex] {
            assert!(auth.lock().unwrap().is_self_sync_owner(&acct_hex, d), "device {d} is not a self-sync owner");
            assert!(!blob_forbidden(&auth, d, VERB_GET, &self_key), "device {d} blocked from its self slot");
            assert!(!blob_forbidden(&auth, d, VERB_PUT, &self_key), "device {d} blocked from its self slot");
            assert!(
                !blob_forbidden(&auth, d, VERB_GET, "haven/mailbox/fam/msg1"),
                "device {d} blocked from the custom-circle mailbox"
            );
        }

        // The union PERSISTS both, so a restart keeps C authorized without a re-publish.
        assert_eq!(load_devroster_devices(&dir), vec![(acct_hex.clone(), vec![b_hex.clone(), c_hex.clone()])]);

        // A stranger still gets nothing — the union widens the fleet, never the world.
        assert!(blob_forbidden(&auth, &"dd".repeat(32), VERB_GET, &self_key));

        // An UNSIGNED older body contributes nothing (Refused, not AuthOnly).
        assert!(!put_roster(&dir, &auth, &acct_hex, b"POISONED-NOT-A-SIGNED-ROSTER"));

        // A WRONG-ACCOUNT older roster (validly self-signed, but by a DIFFERENT account, PUT under
        // acct's key) contributes nothing: the signature does not vouch for `acct`'s devices.
        let intruder = haven_p2p::identity::Identity::generate();
        let dev_x = [0x99u8; 32];
        let x_hex = hex(&dev_x);
        assert!(!put_roster(&dir, &auth, &acct_hex, &signed_roster_wire(&intruder, 1, vec![dev_x], vec![])));
        assert!(
            !auth.lock().unwrap().is_self_sync_owner(&acct_hex, &x_hex),
            "a wrong-account roster authorized a device it does not own"
        );
        // Union unchanged — still exactly {B, C}.
        assert_eq!(load_devroster_devices(&dir), vec![(acct_hex.clone(), vec![b_hex.clone(), c_hex.clone()])]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
