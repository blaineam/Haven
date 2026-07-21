//! On-device persistence: the master seed in the OS secure store (Windows Credential
//! Manager / macOS Keychain / Linux Secret Service) — keys never leave the device, the
//! same rule the iOS Keychain and Android Keystore enforce — plus a small JSON prefs file
//! and the binary social-state blob on disk in the app data directory.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use serde::{Deserialize, Serialize};

const SERVICE: &str = "com.blaineam.haven";
const SEED_ACCOUNT: &str = "master-seed";
const S3_SECRET_ACCOUNT: &str = "s3-secret-key";

/// Resolved app-data paths. `base` is the global Haven data dir (holds the cross-identity
/// `identities.json`); `root` is the *active identity's* data dir (its state/prefs/media/relay).
/// For the first/legacy identity `root == base` so existing installs keep their files in place;
/// additional identities live under `base/identities/<node_hex>/`.
#[derive(Clone)]
pub struct Paths {
    pub base: PathBuf,
    pub root: PathBuf,
}

impl Paths {
    pub fn resolve() -> Result<Self> {
        Self::resolve_for("")
    }

    /// Resolve paths for a specific identity data subdir (relative to `base`; `""` = legacy root).
    pub fn resolve_for(dir_rel: &str) -> Result<Self> {
        let base = dirs::data_dir().ok_or_else(|| anyhow!("no data dir"))?.join("Haven");
        fs::create_dir_all(&base).with_context(|| format!("create {}", base.display()))?;
        let root = if dir_rel.is_empty() { base.clone() } else { base.join(dir_rel) };
        fs::create_dir_all(&root).with_context(|| format!("create {}", root.display()))?;
        Ok(Self { base, root })
    }

    /// The cross-identity roster file (always at `base`, never per-identity).
    pub fn identities_file(&self) -> PathBuf {
        self.base.join("identities.json")
    }
    pub fn state_file(&self) -> PathBuf {
        self.root.join("haven_social_state.bin")
    }
    pub fn prefs_file(&self) -> PathBuf {
        self.root.join("prefs.json")
    }
    pub fn scheduled_file(&self) -> PathBuf {
        self.root.join("scheduled.json")
    }
    pub fn relay_dir(&self) -> PathBuf {
        self.root.join("relay")
    }
    pub fn media_dir(&self) -> PathBuf {
        self.root.join("media")
    }
    /// Last-converged self-sync `AccountState` (binary CRDT blob) for change detection.
    pub fn selfsync_state_file(&self) -> PathBuf {
        self.root.join("selfsync-state.bin")
    }
    /// This device's stable 32-byte self-sync id (random, generated once, NEVER synced).
    pub fn selfsync_device_file(&self) -> PathBuf {
        self.root.join("selfsync-device.bin")
    }
}

/// The user's chosen, signed-at-broadcast business card.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Profile {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub bio: String,
    #[serde(default)]
    pub link: String,
    #[serde(default)]
    pub emoji: String,
    /// Base64 JPEG/PNG avatar (small), empty if none.
    #[serde(default)]
    pub avatar: String,
}

/// A known contact (their verified identity + display name).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Contact {
    pub id_hex: String,
    pub name: String,
    pub verify_hex: String,
}

/// One configured relay's metadata (deactivate-not-erase model — mirrors iOS `RelayEntry`).
///
/// `hex` is the iroh node id (64-hex) for a Haven relay, or a synthetic `s3:<bucket>` id for an
/// S3 bucket relay, so the same `relays` association map can address both kinds. The *associations*
/// (which circle uses which relay) still live in `Prefs::relays`; this record layers the per-relay
/// metadata (name / active / last-seen / isS3) on top. "Removing" a relay flips `active=false`
/// (keeping its config) instead of erasing it; only `purge_stale` truly deletes — and only entries
/// that are BOTH inactive AND unseen for > 7 days.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RelayEntry {
    pub hex: String,
    pub name: String,
    pub active: bool,
    #[serde(default)]
    pub last_seen_ms: u64,
    #[serde(default)]
    pub is_s3: bool,
    /// Plain-HTTP interface of this relay (LAN + optional public URLs) — the DEFAULT cross-NAT
    /// media transport (the iroh blob ALPN drops datagrams on pure-relay cross-NAT paths).
    /// Learned from the sealed frame-19 announce; empty = iroh-only relay.
    #[serde(default)]
    pub http_urls: Vec<String>,
    /// Shared relay secret folded into each request signature (travels ONLY inside sealed
    /// announces, and is never put on the wire — see `Engine::http_auth`).
    #[serde(default)]
    pub http_token: String,
    /// When this relay was last (re-)ADOPTED (unix ms). Rides the announce so a member who FORGOT it
    /// earlier reactivates only on a NEWER re-add (LWW); a stale echo carries the older stamp and loses.
    /// 0 = unknown (legacy). Mirrors iOS/Android `addedAtMs`.
    #[serde(default)]
    pub added_at_ms: u64,
    /// Public HTTPS URL of this relay's embedded iroh-relay (DERP) fabric role. When set, peers
    /// prefer it over n0 for NAT fallback. Empty = use n0 (or another relay's DERP).
    #[serde(default)]
    pub derp_url: String,
    /// Public TURN URLs for WebRTC ICE (`turn:host:port`). When fabric is active and non-empty,
    /// clients use these for WebRTC media ICE (else STUN for srflx).
    #[serde(default)]
    pub turn_urls: Vec<String>,
    /// TURN username (default `haven`).
    #[serde(default)]
    pub turn_user: String,
    /// TURN password (long-lived secret from the relay). Travels only inside sealed announces.
    #[serde(default)]
    pub turn_pass: String,
}

/// Erase an inactive+unseen relay entry after this long (7 days), matching iOS `staleAfterMs`.
pub const RELAY_STALE_AFTER_MS: u64 = 7 * 24 * 3600 * 1000;

/// Default short display name for a relay hex (Haven node or `s3:` synthetic id).
pub fn relay_short_name(hex: &str) -> String {
    if let Some(bucket) = hex.strip_prefix("s3:") {
        format!("S3 · {}", &bucket[..bucket.len().min(16)])
    } else {
        format!("Relay · {}…", &hex[..hex.len().min(8)])
    }
}

/// Non-secret config for a BYO S3/R2/B2 bucket (the secret key lives in the keychain).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct S3Public {
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub access_key: String,
    #[serde(default)]
    pub prefix: String,
}

/// One kept story — a snapshot of a story held on the author's own profile past the 24h window.
///
/// Music is FLATTENED rather than holding the FFI track type: that is generated binding glue, not a
/// storage format, and pinning a persisted format to it would break on the next regeneration.
///
/// Field names are camelCase to match iOS `KeptStoriesStore.Kept` — this struct's JSON IS the
/// cross-platform self-sync wire, so the names must not drift. Optionals are skipped when absent,
/// matching Swift's JSONEncoder, so a record written here round-trips through a phone unchanged.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KeptStory {
    /// The original event id, so a story is kept at most once.
    pub id: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub media: Vec<String>,
    #[serde(default)]
    pub created_at: u64,
    /// When it was kept — the LWW clock for merging this entry against a sibling's tombstone.
    /// Optional so records written before syncing existed still decode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kept_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub music_catalog_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub music_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub music_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub music_artwork_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub music_duration_ms: Option<u64>,
}

/// The `setting:keptStories` self-sync payload: the collection PLUS its tombstones, so the merge is
/// per-entry rather than a wholesale collection swap. Mirrors iOS `KeptStoriesStore.Wire`.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct KeptStoriesWire {
    #[serde(default)]
    pub kept: Vec<KeptStory>,
    #[serde(default)]
    pub removed: std::collections::HashMap<String, u64>,
}

/// Everything that lives in `prefs.json` (mirrors the Android SharedPreferences set).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Prefs {
    #[serde(default)]
    pub profile: Profile,
    #[serde(default)]
    pub contacts: Vec<Contact>,
    #[serde(default)]
    pub blocked: Vec<String>,
    /// Members explicitly removed from a circle, as "circleId|hex". Severances — propagated to our own
    /// devices as intentional `removal:` = 1 records (not inferred from absence) and used to suppress
    /// re-adding the member on an additive re-sync, and to hide their posts/calls. Mirrors iOS/Android.
    #[serde(default)]
    pub circle_removals: Vec<String>,
    /// Removals we deliberately CLEARED (re-added the person). Kept — not deleted — so self-sync can
    /// publish the clear as `removal:<key>` = 0, an explicit newer LWW write that supersedes the stale
    /// removal on our other devices (grow-only removals re-severed a re-added friend on every pass).
    #[serde(default)]
    pub circle_removals_cleared: Vec<String>,
    /// Legacy single-relay-per-circle map (migrated into `relays` on load; kept for back-compat).
    #[serde(default)]
    pub relay_nodes: std::collections::HashMap<String, String>,
    /// circleId -> ordered list of relay node hexes. Posts are mirrored to every relay
    /// (redundancy) and read from all of them (graceful fallback if one is down).
    #[serde(default)]
    pub relays: std::collections::HashMap<String, Vec<String>>,
    /// Relays the user explicitly FORGOT/deactivated — auto-learn (frame-19 announce / self-sync) must
    /// not resurrect a user-forgotten relay while it's inactive, or Forget is a visible no-op. A deliberate
    /// re-announce DOES reactivate it (handle_relay_node clears the suppression + active=true). Cleared on
    /// explicit re-adoption / reactivation. Mirrors iOS/Android.
    #[serde(default)]
    pub suppressed_relays: Vec<String>,
    /// When each relay was FORGOTTEN (unix ms), for LWW against a re-announce's addedAt. A re-add newer
    /// than the forget reactivates; a forget newer than the last add keeps it dead — so a relay's owner
    /// merely REOPENING the app (re-announcing the relay's older adoption time) can't resurrect a relay
    /// the user deleted. Mirrors iOS/Android `forgotAt`.
    #[serde(default)]
    pub forgot_at_relays: std::collections::HashMap<String, u64>,
    /// When each relay was RE-ADDED after a delete (unix ms), for the self-sync LWW gate against a
    /// sibling's deletion. Published as `relay-readd:<hex>`; a re-add NEWER than a sibling's
    /// `relay-removal:` un-forgets the relay fleet-wide, while a delete newer than the last re-add keeps
    /// it dead — so a stale re-add can't resurrect a relay the user has since deleted. Mirrors iOS
    /// `clearedRelayForgets` (UserDefaults `haven.relay.forgotAt.cleared`).
    #[serde(default)]
    pub cleared_relay_forgets: std::collections::HashMap<String, u64>,
    /// Per-relay metadata (name / active / last-seen / isS3), keyed by hex. The config survives a
    /// deactivation here so a relay can be turned back on without re-pasting anything. Mirrors iOS
    /// `RelayMailboxStore.entries` (UserDefaults key `haven.relay.entries`).
    #[serde(default)]
    pub relay_entries: std::collections::HashMap<String, RelayEntry>,
    /// Shared relay secret for OUR hosted relay's plain-HTTP interface (generated once at first
    /// host). A pre-filter mixed into request signatures — membership is what authorizes.
    #[serde(default)]
    pub relay_http_token: String,
    /// Long-lived TURN password for OUR hosted relay (username `haven`). Generated once, like
    /// [`relay_http_token`]. Travels only inside sealed frame-19 / interface.json.
    #[serde(default)]
    pub relay_turn_token: String,
    /// Optional public URL for OUR hosted relay's HTTP interface (port-forward / reverse proxy /
    /// tunnel) — announced ahead of the LAN address when set.
    #[serde(default)]
    pub relay_public_url: String,
    /// When true and `relay_public_url` is empty, start a Cloudflare Quick Tunnel so remote
    /// members can fetch media over HTTPS without port-forwarding. Default true.
    /// `Option` so older prefs files without the field resolve to ON via [`Prefs::auto_tunnel`].
    #[serde(default)]
    pub relay_auto_tunnel: Option<bool>,
    /// Cloudflare Zero Trust tunnel install token. Paired with `relay_public_url` so bundled
    /// cloudflared runs a **named** connector for a stable custom domain.
    #[serde(default)]
    pub relay_cf_tunnel_token: String,
    /// Front-door mode: `"auto"` | `"manual"` | `"bundled"`.
    /// - **manual** — operator runs tunnel/proxy; Haven only announces `relay_public_url`
    ///   (proper path if free/token Cloudflare options go away).
    /// - **bundled** — Haven runs cloudflared with token + custom domain.
    /// - **auto** — free trycloudflare when no URL; infer manual/bundled from fields.
    #[serde(default)]
    pub relay_front_door: Option<String>,
    /// Optional dedicated public HTTPS base for OUR hosted iroh-relay (DERP) fabric role.
    /// Distinct from [`relay_public_url`] (media `:8674`) when the operator uses a sibling
    /// hostname or separate path-routed front door for `:3340`. Empty → named/manual reuse the
    /// media URL; free auto still spins a second trycloudflare origin.
    #[serde(default)]
    pub relay_derp_url: String,
    /// Local notification preview detail: "full" | "private" | "minimal" (Apple/Android parity).
    #[serde(default)]
    pub notification_detail: Option<String>,
    /// Super data saver — device-local (Apple parity).
    #[serde(default)]
    pub super_data_saver: bool,
    /// Also send original media companions when attaching (Apple parity).
    #[serde(default)]
    pub send_original: bool,
    /// The all-circles DEFAULT relay hex (every present + future circle inherits it). Empty = none.
    /// Mirrors iOS `haven.relay.default`.
    #[serde(default)]
    pub default_relay: String,
    /// Device ids learned from a contact's INVITE LINK (`?d=` dial hints), keyed by lowercased
    /// account hex. The only dialable ids for a device-seed friend until their signed roster
    /// (frame 27) arrives — which the hint itself makes possible. Mirrors iOS/Android.
    #[serde(default)]
    pub device_hints: std::collections::HashMap<String, Vec<String>>,
    /// Retention window in seconds for the viewer's own auto-prune (None = keep all).
    #[serde(default)]
    pub retention_secs: Option<u64>,
    /// BYO bucket config (non-secret); `None` until configured.
    #[serde(default)]
    pub s3: Option<S3Public>,
    /// Auto-host the in-process relay on app launch (so launch-on-login = always-on relay).
    #[serde(default)]
    pub host_on_launch: bool,
    /// Global "play video sound" toggle (iOS parity): feed videos start muted; flipping this unmutes all.
    #[serde(default)]
    pub video_sound_on: bool,
    /// Per-DM "cleared before" watermark (circleId -> epoch ms). Deleting a conversation records now() here;
    /// because a DM's circle id is deterministic, a re-started/re-synced DM would otherwise restore old
    /// messages (true network deletion is impossible in P2P). The watermark hides everything older, so a
    /// re-started DM shows fresh. Mirrors iOS `haven.dm.clearedBefore`.
    #[serde(default)]
    pub dm_cleared_before: std::collections::HashMap<String, u64>,
    /// Per-DM READ watermark (circleId -> epoch ms). A message is unread when it's inbound and newer
    /// than its conversation's watermark; only actually viewing the thread advances it. Monotonic
    /// (never moves backward), which makes the cross-device merge trivial: per-key MAX via the
    /// `setting:dmLastRead` self-sync key. Mirrors iOS `DMReadStore`.
    #[serde(default)]
    pub dm_last_read: std::collections::HashMap<String, u64>,
    /// Watermark for DMs with no `dm_last_read` entry yet — stamped ONCE at first run so the day
    /// this feature ships, pre-existing history doesn't light every conversation up as unread.
    #[serde(default)]
    pub dm_read_seeded_at: u64,
    /// DEVICE-LOCAL "keep on this device" set (#2): media refs the user asked to retain here, exempt
    /// from EVERY cleanup path (orphan sweep, the age/size limit sweep, and the cleanup screen marks
    /// them ineligible). NOT synced to other devices. Refs stored verbatim; callers union each ref's
    /// on-disk storage_name into the sweep keep-sets. Mirrors iOS `PinnedMediaStore`.
    #[serde(default)]
    pub pinned_media: Vec<String>,
    /// DON'T-RETRY set for "re-optimize media I already shared" (see `reoptimize.rs`): refs whose
    /// re-encode FAILED, or came back no smaller than the original.
    ///
    /// Persisted because otherwise every scan would re-decide the same thing forever, burning a
    /// decrypt-and-probe per blob per tap for an answer we already have. BOUNDED
    /// (`reoptimize::SKIP_SET_LIMIT`) because an unbounded don't-retry list is just a slower leak.
    /// DEVICE-LOCAL and never synced: it records what THIS machine's encoder could not improve, which
    /// is not a fact about the account.
    #[serde(default)]
    pub reoptimize_skipped: Vec<String>,
    /// Stories the user chose to KEEP — held on their own profile after the 24h story window closes.
    ///
    /// A story is an ordinary post with a 24h retention, so the event itself is purged on schedule
    /// everywhere, for everyone. Keeping one therefore can't mean "stop it expiring": it means
    /// holding our OWN snapshot of it, which is why this stores the story's content rather than a
    /// reference to an event that is about to stop existing. Keep does NOT re-publish — a kept story
    /// still leaves everyone's story row on schedule; only profile surfaces revive the snapshot.
    ///
    /// Keeping also PINS the media (see `pinned_media`), or the cleanup sweeps reclaim the blobs once
    /// the event is gone and a kept story becomes a row of "no longer available" placeholders.
    ///
    /// SYNCED per ENTRY with tombstones (`kept_stories_removed`), NOT last-writer-wins: keeping story
    /// A on the phone and story B here must end with BOTH kept. Mirrors iOS `KeptStoriesStore`; the
    /// JSON field names below are that type's wire format and must not drift from it.
    #[serde(default)]
    pub kept_stories: Vec<KeptStory>,
    /// Un-kept story ids and WHEN. Absence is NOT removal — a lesson this codebase already paid for
    /// once, when additive-only self-sync silently resurrected deleted things. Without a tombstone a
    /// sibling's stale copy would quietly re-add every story the user un-kept. Bounded on write.
    #[serde(default)]
    pub kept_stories_removed: std::collections::HashMap<String, u64>,
    /// DEVICE-LOCAL "deliberately evicted, do-not-auto-refetch" set (#3/#4): refs whose LOCAL blob was
    /// removed on purpose (cleanup screen selection of a still-referenced item, or the age/size limit
    /// sweep) while the EVENT still lives. The missing-media sweep must NOT auto-refetch these (that
    /// would silently undo the freed space) — they render as an explicit "Download N" placeholder and
    /// re-fetch only on tap. Keyed by ref/bare-hash storage_name -> last-known bytes. Mirrors iOS
    /// `EvictedMediaStore`.
    #[serde(default)]
    pub evicted_media: std::collections::HashMap<String, u64>,
    /// Media we've asked an AUTHOR to put back (frame 31), awaiting their "it's back" (frame 32).
    ///
    /// A relay sweeps media on the operator's retention and a post outlives its blob, so "No longer
    /// available" is a permanent dead end even though the author usually still holds the original.
    /// This records that we want it — and gates acting on frame 32, so an unsolicited "it's back"
    /// from a contact can't make us fetch things we never asked about. Device-local, never synced.
    /// Insertion-ordered by convention and bounded on write. Mirrors iOS `MediaWantedStore`.
    #[serde(default)]
    pub media_wanted: Vec<String>,
    /// How much of your circles' media THIS host is willing to keep, and for how long — the in-app
    /// equivalent of the headless relay's `--media-max-age-days` / `--media-max-bytes`. Volunteering
    /// a machine shouldn't mean volunteering the whole disk, and until these existed the in-app relay
    /// always ran unlimited media.
    ///
    /// `0` on either means "no limit" for that dimension, so either can be set independently; with
    /// both set the sweep applies whichever frees space first. The mailbox TTL is deliberately NOT
    /// exposed — undelivered messages are a delivery guarantee, not disposable cache.
    ///
    /// Read at ATTACH time, so a change applies when the relay next starts.
    ///
    /// `Option`, resolved through [`Prefs::relay_media_limits`], specifically so `derive(Default)`
    /// can't silently mean "unlimited" on a fresh install: `None` is "the user hasn't chosen", which
    /// resolves to the generous-but-finite defaults, while `Some(0)` is a deliberate "no limit".
    /// A plain `u32` here would have made every new install host without a cap.
    #[serde(default)]
    pub relay_media_max_age_days: Option<u32>,
    #[serde(default)]
    pub relay_media_max_bytes: Option<u64>,
    /// LOCAL media age cap in DAYS (#4): delete this device's cached blobs older than N days
    /// (0 = no age limit, the default). The event stays; the blob becomes a re-downloadable
    /// placeholder. Mirrors iOS `SettingsStore.localMediaMaxDays`.
    #[serde(default)]
    pub local_media_max_days: u32,
    /// LOCAL media size cap in GB (#4): keep this device's cached blobs under this many GB
    /// (0 = no size limit, the default). Oldest-first eviction; pinned blobs are never evicted.
    /// Mirrors iOS `SettingsStore.localMediaMaxGB`.
    #[serde(default)]
    pub local_media_max_gb: u32,
    /// FEED circle ids this device CREATED (Switch-Flip 1.0.7 §2): the local user is the authority
    /// root (creator) of these circles, so we re-pin `set_circle_creator(id, me)` on every launch and
    /// the pin propagates to members via the account-signed self-grant on the control lane. Only
    /// circles created here (never ones a friend invited us into) belong here. Device-local.
    #[serde(default)]
    pub created_circles: Vec<String>,
    /// One-time migration latch (Switch-Flip 1.0.7 §1): set once `retire_account_leaf()` has
    /// successfully shed this account's legacy bare `{account}` roster leaf, so an existing
    /// multi-device upgrader reaches the device-only shape live MLS keying + seed-drop retirement
    /// require. Sticky — never re-run once true; a fresh device-only install never needs it.
    #[serde(default)]
    pub account_leaf_retired: bool,
    /// One-time latch (1.0.8 media recovery): set once we've force-re-sealed + re-uploaded THIS
    /// account's own posted media, overwriting blobs a 1.0.7 build device-signed and froze so a
    /// friend could never open them. Sticky — a fresh 1.0.8+ install never posted a bad blob.
    #[serde(default)]
    pub media_resealed_v108: bool,
    /// Refs already confirmed overwritten on ≥1 destination by the recovery (resumable — a content-
    /// addressed blob is only repairable by the force-overwrite, which lands only on reachable dests,
    /// so we retry across launches until every held ref is confirmed).
    #[serde(default)]
    pub media_reseal_refs: Vec<String>,
    /// How many recovery passes have run — caps the retry so a user with no reachable destination
    /// (nothing was ever uploaded, nothing to repair) still stops.
    #[serde(default)]
    pub media_reseal_attempts: u32,
    /// LWW circle-member removal timestamps (key "circleId|hex" -> unix ms). Source of truth for a
    /// severance: a member is currently removed iff removed_at > readded_at. Replaces the grow-only
    /// `circle_removals` / `circle_removals_cleared` verdict with newest-wins, so a fresh removal beats a
    /// stale re-add and a fresh re-add beats an old removal (the fix for "removals don't stick / re-adds
    /// get re-severed" across a multi-device account). Published as `circle-removed:` / `circle-readd:`
    /// (8-byte LE ms), with the legacy `removal:` = 1/0 kept for older peers. Mirrors iOS ConnectionsStore.
    #[serde(default)]
    pub circle_removed_at: std::collections::HashMap<String, u64>,
    #[serde(default)]
    pub circle_readded_at: std::collections::HashMap<String, u64>,
    /// LWW contact-removal timestamps (idHex -> unix ms). Contacts sync additive-only, so a delete needs
    /// an explicit newest-wins tombstone to stick fleet-wide. Published as `contact-removed:` /
    /// `contact-readd:`. Mirrors iOS ContactsStore.
    #[serde(default)]
    pub contact_removed_at: std::collections::HashMap<String, u64>,
    #[serde(default)]
    pub contact_readded_at: std::collections::HashMap<String, u64>,
    /// LWW whole-circle / DM deletion timestamps (circleId -> unix ms). A circle is currently deleted iff
    /// deleted_at > recreated_at; self-sync honors it so deleting a DM/circle on one device deletes it on
    /// all of them instead of a sibling's `circle:` record resurrecting it. Published as `circle-deleted:`
    /// / `circle-recreated:`. Mirrors iOS CircleDeletionStore.
    #[serde(default)]
    pub circle_deleted_at: std::collections::HashMap<String, u64>,
    #[serde(default)]
    pub circle_recreated_at: std::collections::HashMap<String, u64>,
    /// LWW per-field profile-edit timestamps (field -> unix ms) for name/emoji/bio/link. A remote profile
    /// value wins only if it was edited more recently than ours (ends the profile ping-pong where
    /// "non-empty always wins" = "whoever synced last wins"). Published as `profile-at:<field>`. Mirrors
    /// iOS ProfileStore.fieldTs.
    #[serde(default)]
    pub profile_field_ts: std::collections::HashMap<String, u64>,
    /// LWW per-key synced-setting timestamps (setting key -> unix ms). Published as `setting-at:<key>`.
    /// Mirrors iOS SettingsStore.settingTs.
    #[serde(default)]
    pub setting_ts: std::collections::HashMap<String, u64>,
}

impl Prefs {
    /// BOUND the kept-story tombstones: they only need to outlive a sibling being offline, not
    /// forever. Trimmed to the newest 250 once past 500.
    pub fn trim_kept_tombstones(&mut self) {
        if self.kept_stories_removed.len() <= 500 {
            return;
        }
        let mut all: Vec<(String, u64)> = self.kept_stories_removed.drain().collect();
        all.sort_by(|a, b| b.1.cmp(&a.1));
        self.kept_stories_removed = all.into_iter().take(250).collect();
    }

    /// Merge a sibling's kept stories. Per ENTRY, not wholesale: keeping story A on the phone and
    /// story B here must end with BOTH kept, which a last-writer-wins collection swap would not do.
    ///
    /// An entry applies unless a NEWER tombstone exists for it; a tombstone applies unless the local
    /// copy was kept more recently — so re-keeping something later still wins in BOTH directions.
    ///
    /// Newly-arrived entries PIN their media here, so a story kept on another device survives THIS
    /// device's cleanup sweeps — otherwise it would sync in and then be silently reclaimed, leaving
    /// a row of "no longer available" placeholders. Dropped entries release only the blobs no other
    /// kept story still needs (a story shared twice can share refs).
    ///
    /// Lives on `Prefs` rather than the engine because `selfsync::apply_local` holds only `&mut
    /// Prefs`, and pinning is itself just a `Prefs` field.
    pub fn merge_kept_stories(&mut self, data: &[u8]) -> bool {
        let Ok(wire) = serde_json::from_slice::<KeptStoriesWire>(data) else { return false };
        let mut changed = false;
        for (id, ts) in wire.removed {
            if self.kept_stories_removed.get(&id).copied().unwrap_or(0) < ts {
                self.kept_stories_removed.insert(id, ts);
                changed = true;
            }
        }
        let mut to_pin: Vec<String> = Vec::new();
        for entry in wire.kept {
            let entry_at = entry.kept_at.unwrap_or(entry.created_at);
            // Un-kept more recently than it was kept — the tombstone wins.
            if self.kept_stories_removed.get(&entry.id).copied().unwrap_or(0) > entry_at {
                continue;
            }
            match self.kept_stories.iter().position(|k| k.id == entry.id) {
                Some(i) => {
                    if self.kept_stories[i].kept_at.unwrap_or(0) < entry_at {
                        self.kept_stories[i] = entry;
                        changed = true;
                    }
                }
                None => {
                    to_pin.extend(entry.media.iter().cloned());
                    self.kept_stories.push(entry);
                    changed = true;
                }
            }
        }
        // Apply tombstones newer than our own copy.
        let mut dropped: Vec<String> = Vec::new();
        for (id, ts) in self.kept_stories_removed.clone() {
            if let Some(i) = self.kept_stories.iter().position(|k| k.id == id) {
                if self.kept_stories[i].kept_at.unwrap_or(0) < ts {
                    dropped.extend(self.kept_stories.remove(i).media);
                    changed = true;
                }
            }
        }
        let still_needed: std::collections::HashSet<String> =
            self.kept_stories.iter().flat_map(|k| k.media.iter().cloned()).collect();
        for r in to_pin {
            if !self.pinned_media.contains(&r) {
                self.pinned_media.push(r);
            }
        }
        for r in dropped {
            if !still_needed.contains(&r) {
                self.pinned_media.retain(|p| *p != r);
            }
        }
        self.trim_kept_tombstones();
        changed
    }

    /// Generous but finite. An unbounded default is how a helpful relay quietly fills a disk, and
    /// whoever volunteers a machine is the least likely to go looking for a setting first.
    pub const DEFAULT_MEDIA_MAX_AGE_DAYS: u32 = 30;
    pub const DEFAULT_MEDIA_MAX_BYTES: u64 = 32 * 1024 * 1024 * 1024; // 32 GB

    /// The host's chosen media limits as the relay wants them: `(days, bytes)`, where `0` on either
    /// means "no limit" for that dimension. Unset resolves to the defaults, NOT to unlimited.
    pub fn relay_media_limits(&self) -> (u32, u64) {
        (
            self.relay_media_max_age_days.unwrap_or(Self::DEFAULT_MEDIA_MAX_AGE_DAYS),
            self.relay_media_max_bytes.unwrap_or(Self::DEFAULT_MEDIA_MAX_BYTES),
        )
    }

    /// Cloudflare Quick Tunnel when no stable public URL is configured. Default ON.
    pub fn auto_tunnel(&self) -> bool {
        self.relay_auto_tunnel.unwrap_or(true)
    }

    /// Explicit front-door policy (see `haven_net::cfquicktunnel::FrontDoorMode`).
    pub fn front_door_mode(&self) -> haven_net::cfquicktunnel::FrontDoorMode {
        use haven_net::cfquicktunnel::FrontDoorMode;
        match self.relay_front_door.as_deref() {
            Some(s) if !s.trim().is_empty() => FrontDoorMode::parse(s),
            // Legacy: URL without token → manual; token+url → bundled; else auto.
            None if !self.relay_public_url.trim().is_empty()
                && self.relay_cf_tunnel_token.trim().is_empty() =>
            {
                FrontDoorMode::Manual
            }
            None if !self.relay_public_url.trim().is_empty()
                && !self.relay_cf_tunnel_token.trim().is_empty() =>
            {
                FrontDoorMode::Bundled
            }
            _ => FrontDoorMode::Auto,
        }
    }

    pub fn load(paths: &Paths) -> Self {
        let mut prefs: Prefs = match fs::read(paths.prefs_file()) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => Prefs::default(),
        };
        // Migrate the legacy single-relay-per-circle map into the redundant `relays` list.
        // Idempotent: re-runs harmlessly on every load until the next save clears `relay_nodes`.
        for (cid, hex) in std::mem::take(&mut prefs.relay_nodes) {
            let list = prefs.relays.entry(cid).or_default();
            if !list.contains(&hex) {
                list.push(hex);
            }
        }
        // Migrate every relay referenced by `relays` / `default_relay` into a RelayEntry (deactivate-not-
        // erase model). Pre-existing relays become active=true with last_seen=now so their stale-clock
        // starts now. Idempotent: only fills gaps. Mirrors iOS `migrateEntries`.
        prefs.migrate_relay_entries();
        // MIGRATION: relays deleted BEFORE the deletion-timestamp existed are in `suppressed_relays` but
        // have no `forgot_at_relays` entry. Without a deletion time the LWW gate can't tell a real re-add
        // from a mere reopen, so those old deletions leaked back. Stamp them "deleted now" so a re-announce
        // carrying the relay's ORIGINAL (older) adoption time loses. Mirrors iOS/Android.
        {
            let now = Self::now_ms();
            let mut migrated = false;
            for hex in prefs.suppressed_relays.clone() {
                prefs.forgot_at_relays.entry(hex).or_insert_with(|| { migrated = true; now });
            }
            if migrated {
                let _ = prefs.save(paths);
            }
        }
        // First run (or first run since this feature shipped): stamp the unread seed and PERSIST it,
        // so messages that arrive while the app is closed still count as unread on the next launch.
        if prefs.dm_read_seeded_at == 0 {
            prefs.dm_read_seeded_at = Self::now_ms();
            let _ = prefs.save(paths);
        }
        // One-time migration of the legacy grow-only circle-removal sets into LWW timestamps: old
        // records carry no time, so they land at ts=1 ("long ago") and any real, later action supersedes
        // them. Only when the timestamp maps are still empty (idempotent). Mirrors iOS ConnectionsStore.
        if prefs.circle_removed_at.is_empty() && prefs.circle_readded_at.is_empty() {
            for e in &prefs.circle_removals {
                prefs.circle_removed_at.insert(e.clone(), 1);
            }
            for e in &prefs.circle_removals_cleared {
                prefs.circle_readded_at.insert(e.clone(), 1);
            }
        }
        prefs
    }

    // ---- LWW circle-member removals (source of truth = the timestamp maps) -----------------------

    /// A member is currently removed from a circle iff their removal is NEWER than any re-add.
    pub fn is_circle_member_removed(&self, entry: &str) -> bool {
        self.circle_removed_at.get(entry).copied().unwrap_or(0)
            > self.circle_readded_at.get(entry).copied().unwrap_or(0)
    }
    /// Stamp a removal NOW (LWW — supersedes any older re-add).
    pub fn mark_circle_member_removed(&mut self, entry: &str) {
        self.circle_removed_at.insert(entry.to_string(), Self::now_ms());
    }
    /// Stamp a deliberate re-add NOW (LWW — supersedes any older removal).
    pub fn mark_circle_member_readded(&mut self, entry: &str) {
        self.circle_readded_at.insert(entry.to_string(), Self::now_ms());
    }
    /// Apply a REMOTE removal timestamp (self-sync LWW), keeping the newer. Returns the post-merge verdict.
    pub fn merge_circle_removed_at(&mut self, entry: &str, ms: u64) -> bool {
        if ms > self.circle_removed_at.get(entry).copied().unwrap_or(0) {
            self.circle_removed_at.insert(entry.to_string(), ms);
        }
        self.is_circle_member_removed(entry)
    }
    /// Apply a REMOTE re-add timestamp (self-sync LWW), keeping the newer. Returns the post-merge verdict.
    pub fn merge_circle_readded_at(&mut self, entry: &str, ms: u64) -> bool {
        if ms > self.circle_readded_at.get(entry).copied().unwrap_or(0) {
            self.circle_readded_at.insert(entry.to_string(), ms);
        }
        self.is_circle_member_removed(entry)
    }

    // ---- LWW contact removals -------------------------------------------------------------------

    pub fn is_contact_removed(&self, hex: &str) -> bool {
        self.contact_removed_at.get(hex).copied().unwrap_or(0)
            > self.contact_readded_at.get(hex).copied().unwrap_or(0)
    }
    pub fn mark_contact_removed(&mut self, hex: &str) {
        self.contact_removed_at.insert(hex.to_string(), Self::now_ms());
    }
    pub fn mark_contact_readded(&mut self, hex: &str) {
        self.contact_readded_at.insert(hex.to_string(), Self::now_ms());
    }
    pub fn merge_contact_removed_at(&mut self, hex: &str, ms: u64) -> bool {
        if ms > self.contact_removed_at.get(hex).copied().unwrap_or(0) {
            self.contact_removed_at.insert(hex.to_string(), ms);
        }
        self.is_contact_removed(hex)
    }
    pub fn merge_contact_readded_at(&mut self, hex: &str, ms: u64) -> bool {
        if ms > self.contact_readded_at.get(hex).copied().unwrap_or(0) {
            self.contact_readded_at.insert(hex.to_string(), ms);
        }
        self.is_contact_removed(hex)
    }

    // ---- LWW whole-circle / DM deletions --------------------------------------------------------

    pub fn is_circle_deleted(&self, id: &str) -> bool {
        self.circle_deleted_at.get(id).copied().unwrap_or(0)
            > self.circle_recreated_at.get(id).copied().unwrap_or(0)
    }
    pub fn mark_circle_deleted(&mut self, id: &str) {
        self.circle_deleted_at.insert(id.to_string(), Self::now_ms());
    }
    pub fn mark_circle_recreated(&mut self, id: &str) {
        self.circle_recreated_at.insert(id.to_string(), Self::now_ms());
    }
    pub fn merge_circle_deleted_at(&mut self, id: &str, ms: u64) -> bool {
        if ms > self.circle_deleted_at.get(id).copied().unwrap_or(0) {
            self.circle_deleted_at.insert(id.to_string(), ms);
        }
        self.is_circle_deleted(id)
    }
    pub fn merge_circle_recreated_at(&mut self, id: &str, ms: u64) -> bool {
        if ms > self.circle_recreated_at.get(id).copied().unwrap_or(0) {
            self.circle_recreated_at.insert(id.to_string(), ms);
        }
        self.is_circle_deleted(id)
    }

    // ---- LWW profile-field + setting edit stamps ------------------------------------------------

    /// When a profile field was last edited LOCALLY (0 = never). Namespaced per field name.
    pub fn profile_field_stamp(&self, field: &str) -> u64 {
        self.profile_field_ts.get(field).copied().unwrap_or(0)
    }
    pub fn stamp_profile_field(&mut self, field: &str) {
        self.profile_field_ts.insert(field.to_string(), Self::now_ms());
    }
    /// When a synced setting was last changed LOCALLY (0 = never). Namespaced per setting key.
    pub fn setting_stamp(&self, key: &str) -> u64 {
        self.setting_ts.get(key).copied().unwrap_or(0)
    }
    pub fn stamp_setting(&mut self, key: &str) {
        self.setting_ts.insert(key.to_string(), Self::now_ms());
    }

    fn now_ms() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    /// Ensure every relay referenced by `relays` / the default has a RelayEntry record.
    pub fn migrate_relay_entries(&mut self) {
        let now = Self::now_ms();
        let mut known: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for list in self.relays.values() {
            for h in list {
                known.insert(h.clone());
            }
        }
        if !self.default_relay.is_empty() {
            known.insert(self.default_relay.clone());
        }
        for hex in known {
            if !self.relay_entries.contains_key(&hex) {
                let is_s3 = hex.starts_with("s3:");
                self.relay_entries.insert(
                    hex.clone(),
                    RelayEntry {
                        name: relay_short_name(&hex),
                        active: true,
                        last_seen_ms: now,
                        is_s3,
                        http_urls: Vec::new(),
                        http_token: String::new(),
                        added_at_ms: now,
                        derp_url: String::new(),
                        turn_urls: Vec::new(),
                        turn_user: String::new(),
                        turn_pass: String::new(),
                        hex,
                    },
                );
            }
        }
    }

    /// True when this relay has no entry (freshly announced) OR has an active entry. An unknown hex is
    /// treated as active so nothing breaks before its entry lands. Mirrors iOS `isActive`.
    pub fn relay_is_active(&self, hex: &str) -> bool {
        self.relay_entries.get(hex).map(|e| e.active).unwrap_or(true)
    }

    /// When a relay was FORGOTTEN (0 if never), for the LWW reactivation gate.
    pub fn relay_forgotten_at_ms(&self, hex: &str) -> u64 {
        self.forgot_at_relays.get(hex).copied().unwrap_or(0)
    }

    /// When a relay was last RE-ADDED after a delete (0 if never), for the self-sync LWW gate.
    pub fn relay_cleared_forget_ms(&self, hex: &str) -> u64 {
        self.cleared_relay_forgets.get(hex).copied().unwrap_or(0)
    }

    /// A relay's adoption stamp (0 if unknown/no entry) — the newer-local-re-add side of the LWW gate.
    pub fn relay_added_at_ms(&self, hex: &str) -> u64 {
        self.relay_entries.get(hex).map(|e| e.added_at_ms).unwrap_or(0)
    }

    /// Every distinct ACTIVE relay this device knows (any circle + the all-circles default + every
    /// relay entry), regardless of which circle it's attached to. Media keys are content-addressed AND
    /// permission-free on a relay, so a blob may live on ANY reachable relay; and a device roster is
    /// published to every known relay. Deduped; inactive/forgotten excluded. Mirrors iOS `allRelays()`.
    pub fn all_active_relay_hexes(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for e in self.relay_entries.values() {
            if e.active && !out.contains(&e.hex) {
                out.push(e.hex.clone());
            }
        }
        // Defensive: fold in any relay referenced by a circle / the default that lacks an entry.
        for hex in self.relays.values().flatten() {
            if self.relay_is_active(hex) && !out.contains(hex) {
                out.push(hex.clone());
            }
        }
        if !self.default_relay.is_empty() && self.relay_is_active(&self.default_relay) && !out.contains(&self.default_relay) {
            out.push(self.default_relay.clone());
        }
        out
    }

    /// Clear a relay's FORGOTTEN state on an explicit/legit RE-ADD, recording a re-add timestamp (now)
    /// in `cleared_relay_forgets` so self-sync supersedes a sibling's stale deletion tombstone (LWW).
    /// Returns whether the relay had actually been forgotten. Mirrors iOS `unforget`.
    pub fn relay_clear_forget(&mut self, hex: &str) -> bool {
        let had_suppressed = self.suppressed_relays.iter().any(|h| h == hex);
        self.suppressed_relays.retain(|h| h != hex);
        let had_forget = self.forgot_at_relays.remove(hex).is_some();
        if had_suppressed || had_forget {
            let now = Self::now_ms();
            let e = self.cleared_relay_forgets.entry(hex.to_string()).or_insert(0);
            *e = (*e).max(now);
            true
        } else {
            false
        }
    }

    /// Stamp a relay as FORGOTTEN now (delete/deactivate), superseding any prior re-add clear so a
    /// fresh delete wins LWW — and so the deletion SYNCS to my other devices via `relay-removal:`.
    /// Mirrors iOS forget/eraseNow forgotAt stamping.
    pub fn relay_stamp_forgot(&mut self, hex: &str) {
        self.forgot_at_relays.insert(hex.to_string(), Self::now_ms());
        self.cleared_relay_forgets.remove(hex);
    }

    /// Apply a sibling's relay-DELETION tombstone from self-sync (LWW): forget the relay locally ONLY
    /// if the deletion is NEWER than our own re-add/adoption of it. Returns true if state changed (so
    /// the caller can persist + drop cached clients/health). Mirrors iOS `applyForgottenTombstone`.
    pub fn apply_forgotten_tombstone(&mut self, hex: &str, at_ms: u64) -> bool {
        if at_ms == 0 {
            return false;
        }
        // A newer local re-add wins (a fresh adoption stamp, or a re-add clear newer than this delete).
        if self.relay_added_at_ms(hex) > at_ms {
            return false;
        }
        if self.relay_cleared_forget_ms(hex) > at_ms {
            return false;
        }
        // Already forgotten at/after this time → nothing to do.
        if self.relay_forgotten_at_ms(hex) >= at_ms {
            return false;
        }
        if let Some(e) = self.relay_entries.get_mut(hex) {
            e.active = false;
        }
        if !self.suppressed_relays.iter().any(|h| h == hex) {
            self.suppressed_relays.push(hex.to_string());
        }
        self.forgot_at_relays.insert(hex.to_string(), at_ms);
        // Drop any stale re-add record so THIS device stops re-broadcasting a clear that this newer
        // deletion supersedes (otherwise the two ping-pong across the fleet).
        self.cleared_relay_forgets.remove(hex);
        true
    }

    /// Apply a sibling's relay RE-ADD from self-sync (LWW): un-forget the relay locally ONLY if the
    /// re-add is NEWER than our local deletion. Returns true if state changed. Mirrors iOS
    /// `applyClearedRelayForget`.
    pub fn apply_cleared_relay_forget(&mut self, hex: &str, at_ms: u64) -> bool {
        if at_ms == 0 {
            return false;
        }
        // Our local deletion is newer than this re-add → the delete wins; ignore the stale clear.
        if self.relay_forgotten_at_ms(hex) > at_ms {
            return false;
        }
        // Already cleared at/after this time (and not currently forgotten) → nothing to do.
        let suppressed = self.suppressed_relays.iter().any(|h| h == hex);
        if !suppressed
            && !self.forgot_at_relays.contains_key(hex)
            && self.relay_cleared_forget_ms(hex) >= at_ms
        {
            return false;
        }
        self.suppressed_relays.retain(|h| h != hex);
        self.forgot_at_relays.remove(hex);
        let e = self.cleared_relay_forgets.entry(hex.to_string()).or_insert(0);
        *e = (*e).max(at_ms);
        true
    }

    /// Move a relay's adoption stamp FORWARD (max) — set to now() for `ms == 0` (an explicit local
    /// adoption) or to the announced value otherwise (propagate a peer's stamp; never invent now() on an
    /// echo, or a stale re-announce would keep beating a user's forget = the zombie loop). Mirrors the
    /// `adoptedAtMs` handling in iOS/Android `ensureEntry`.
    pub fn set_relay_added_at(&mut self, hex: &str, ms: u64) {
        let stamp = if ms > 0 { ms } else { Self::now_ms() };
        if let Some(e) = self.relay_entries.get_mut(hex) {
            e.added_at_ms = e.added_at_ms.max(stamp);
        }
    }

    /// Create-or-update a RelayEntry. `activate` flips it on; last_seen + added_at are stamped now on first
    /// creation so a freshly-added relay's stale-clock (and adoption LWW clock) start now. Mirrors iOS
    /// `ensureEntry`. Callers propagate a peer's announced adoption stamp via `set_relay_added_at`.
    pub fn ensure_relay_entry(&mut self, hex: &str, name: Option<&str>, is_s3: bool, activate: bool) {
        let now = Self::now_ms();
        match self.relay_entries.get_mut(hex) {
            Some(e) => {
                if let Some(n) = name {
                    if !n.is_empty() {
                        e.name = n.to_string();
                    }
                }
                if activate {
                    e.active = true;
                }
            }
            None => {
                self.relay_entries.insert(
                    hex.to_string(),
                    RelayEntry {
                        hex: hex.to_string(),
                        name: name.filter(|n| !n.is_empty()).map(|n| n.to_string()).unwrap_or_else(|| relay_short_name(hex)),
                        active: true,
                        last_seen_ms: now,
                        is_s3,
                        http_urls: Vec::new(),
                        http_token: String::new(),
                        added_at_ms: now,
                        derp_url: String::new(),
                        turn_urls: Vec::new(),
                        turn_user: String::new(),
                        turn_pass: String::new(),
                    },
                );
            }
        }
    }

    /// Record a relay's plain-HTTP media interface (from our own host start or a sealed announce).
    /// Returns true when something changed (caller saves + may re-announce).
    pub fn set_relay_http(&mut self, hex: &str, urls: Vec<String>, token: String) -> bool {
        self.ensure_relay_entry(hex, None, hex.starts_with("s3:"), true);
        if let Some(e) = self.relay_entries.get_mut(hex) {
            if e.http_urls == urls && e.http_token == token {
                return false;
            }
            e.http_urls = urls;
            e.http_token = token;
            return true;
        }
        false
    }

    /// Record a relay's public iroh-relay (DERP) fabric URL. Empty clears it.
    pub fn set_relay_derp(&mut self, hex: &str, derp_url: &str) -> bool {
        self.ensure_relay_entry(hex, None, hex.starts_with("s3:"), true);
        let next = derp_url.trim().trim_end_matches('/').to_string();
        if let Some(e) = self.relay_entries.get_mut(hex) {
            if e.derp_url == next {
                return false;
            }
            e.derp_url = next;
            return true;
        }
        false
    }

    /// Every live DERP URL across active relays — Haven-first fabric map.
    pub fn all_derp_urls(&self) -> Vec<String> {
        let mut urls: Vec<String> = self
            .relay_entries
            .values()
            .filter(|e| e.active && !e.derp_url.is_empty())
            .map(|e| e.derp_url.clone())
            .collect();
        urls.sort();
        urls.dedup();
        urls
    }

    /// Record a relay's circle TURN URLs + credentials for WebRTC ICE.
    pub fn set_relay_turn(
        &mut self,
        hex: &str,
        urls: Vec<String>,
        user: &str,
        pass: &str,
    ) -> bool {
        self.ensure_relay_entry(hex, None, hex.starts_with("s3:"), true);
        let cleaned: Vec<String> = urls
            .into_iter()
            .map(|u| u.trim().to_string())
            .filter(|u| u.starts_with("turn:") || u.starts_with("turns:"))
            .collect();
        let user = user.trim().to_string();
        let pass = pass.trim().to_string();
        if let Some(e) = self.relay_entries.get_mut(hex) {
            if e.turn_urls == cleaned && e.turn_user == user && e.turn_pass == pass {
                return false;
            }
            e.turn_urls = cleaned;
            e.turn_user = user;
            e.turn_pass = pass;
            return true;
        }
        false
    }

    /// Union of live TURN URLs + first non-empty credentials across active relays.
    /// Returns `(urls, user, pass)`.
    pub fn all_turn_ice(&self) -> (Vec<String>, String, String) {
        let mut urls: Vec<String> = Vec::new();
        let mut user = String::new();
        let mut pass = String::new();
        for e in self.relay_entries.values() {
            if !e.active || e.turn_urls.is_empty() {
                continue;
            }
            for u in &e.turn_urls {
                if !urls.contains(u) {
                    urls.push(u.clone());
                }
            }
            if user.is_empty() && !e.turn_user.is_empty() && !e.turn_pass.is_empty() {
                user = e.turn_user.clone();
                pass = e.turn_pass.clone();
            }
        }
        urls.sort();
        urls.dedup();
        (urls, user, pass)
    }

    /// The relay's HTTP interface (urls, token), or None for an iroh-only relay.
    pub fn relay_http(&self, hex: &str) -> Option<(Vec<String>, String)> {
        let e = self.relay_entries.get(hex)?;
        if e.http_urls.is_empty() || e.http_token.is_empty() {
            return None;
        }
        Some((e.http_urls.clone(), e.http_token.clone()))
    }

    /// Stamp a relay as just-seen (a successful op). Mirrors iOS `markSeen`.
    pub fn relay_mark_seen(&mut self, hex: &str) {
        if let Some(e) = self.relay_entries.get_mut(hex) {
            e.last_seen_ms = Self::now_ms();
        }
    }

    /// Every distinct ACTIVE relay configured for a circle: its own list + the all-circles default
    /// (deduped, inactive filtered out). Mirrors iOS `relays(forCircle:)`.
    pub fn active_relays_for(&self, circle_id: &str) -> Vec<String> {
        let mut out: Vec<String> = self
            .relays
            .get(circle_id)
            .map(|v| v.iter().filter(|h| self.relay_is_active(h)).cloned().collect())
            .unwrap_or_default();
        if !self.default_relay.is_empty() && self.relay_is_active(&self.default_relay) && !out.contains(&self.default_relay) {
            out.push(self.default_relay.clone());
        }
        out
    }

    /// Entries that are BOTH inactive AND unseen for > 7 days — to be erased. Mirrors iOS `purgeStale`.
    pub fn stale_relay_hexes(&self) -> Vec<String> {
        let now = Self::now_ms();
        self.relay_entries
            .values()
            .filter(|e| !e.active && now.saturating_sub(e.last_seen_ms) > RELAY_STALE_AFTER_MS)
            .map(|e| e.hex.clone())
            .collect()
    }
    pub fn save(&self, paths: &Paths) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(self)?;
        fs::write(paths.prefs_file(), bytes).context("write prefs")
    }
}

/// Load the 32-byte master seed from the secure store, or `None` if there isn't one yet.
/// Distinguishes "no entry" (new device → caller generates) from a locked/error read, so
/// we never clobber an existing identity by treating a transient failure as "new".
pub fn load_seed() -> Result<Option<[u8; 32]>> {
    let entry = keyring::Entry::new(SERVICE, SEED_ACCOUNT).context("open keyring entry")?;
    match entry.get_password() {
        Ok(b64) => {
            let raw = base64::engine::general_purpose::STANDARD
                .decode(b64.trim())
                .context("decode stored seed")?;
            let seed: [u8; 32] = raw
                .try_into()
                .map_err(|_| anyhow!("stored seed is not 32 bytes"))?;
            Ok(Some(seed))
        }
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(anyhow!("keyring read failed: {e}")),
    }
}

/// Persist the master seed to the secure store.
pub fn save_seed(seed: &[u8; 32]) -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, SEED_ACCOUNT).context("open keyring entry")?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(seed);
    entry.set_password(&b64).context("write seed to keyring")
}

/// Wipe the stored seed (Start Over).
pub fn delete_seed() -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, SEED_ACCOUNT).context("open keyring entry")?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(anyhow!("keyring delete failed: {e}")),
    }
}

// ---- multi-identity roster ------------------------------------------------------------------

/// One identity the user keeps on this device. The 32-byte seed lives in the OS secure store
/// (keyring account `seed-<node_hex>`); only this non-secret descriptor is on disk.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct IdentityEntry {
    pub node_hex: String,
    pub label: String,
    /// Data subdir relative to `base` (`""` = legacy root, kept for the first identity).
    #[serde(default)]
    pub dir: String,
}

/// The roster of identities + which one is active. Persisted to `identities.json` at `base`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Identities {
    #[serde(default)]
    pub active: String,
    #[serde(default)]
    pub items: Vec<IdentityEntry>,
}

impl Identities {
    pub fn load(paths: &Paths) -> Self {
        match fs::read(paths.identities_file()) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => Identities::default(),
        }
    }

    pub fn save(&self, paths: &Paths) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(self)?;
        fs::write(paths.identities_file(), bytes).context("write identities")
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn find(&self, node_hex: &str) -> Option<&IdentityEntry> {
        self.items.iter().find(|i| i.node_hex == node_hex)
    }

    pub fn active_entry(&self) -> Option<&IdentityEntry> {
        self.find(&self.active)
    }

    /// Add an identity (no-op if its node_hex is already present). The first one added becomes
    /// active and keeps the legacy root (`dir = ""`); later ones get `identities/<hex>`.
    pub fn add(&mut self, node_hex: &str, label: &str) {
        if self.find(node_hex).is_some() {
            return;
        }
        let dir = if self.items.is_empty() { String::new() } else { format!("identities/{node_hex}") };
        let first = self.items.is_empty();
        self.items.push(IdentityEntry { node_hex: node_hex.to_string(), label: label.to_string(), dir });
        if first {
            self.active = node_hex.to_string();
        }
    }

    pub fn set_active(&mut self, node_hex: &str) -> bool {
        if self.find(node_hex).is_some() {
            self.active = node_hex.to_string();
            true
        } else {
            false
        }
    }

    pub fn rename(&mut self, node_hex: &str, label: &str) -> bool {
        if let Some(e) = self.items.iter_mut().find(|i| i.node_hex == node_hex) {
            e.label = label.to_string();
            true
        } else {
            false
        }
    }

    /// Remove an identity (refuses to remove the active one). Returns its data subdir if removed.
    pub fn remove(&mut self, node_hex: &str) -> Option<String> {
        if node_hex == self.active {
            return None;
        }
        let idx = self.items.iter().position(|i| i.node_hex == node_hex)?;
        Some(self.items.remove(idx).dir)
    }
}

/// Per-identity seed in the OS secure store, keyed by node hex (distinct from the legacy
/// `master-seed`, which we keep mirrored to the active identity for the headless relay).
fn id_seed_account(node_hex: &str) -> String {
    format!("seed-{node_hex}")
}

pub fn save_identity_seed(node_hex: &str, seed: &[u8; 32]) -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, &id_seed_account(node_hex)).context("open id keyring")?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(seed);
    entry.set_password(&b64).context("write id seed")
}

pub fn load_identity_seed(node_hex: &str) -> Result<Option<[u8; 32]>> {
    let entry = keyring::Entry::new(SERVICE, &id_seed_account(node_hex)).context("open id keyring")?;
    match entry.get_password() {
        Ok(b64) => {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64.trim()).context("decode id seed")?;
            let seed: [u8; 32] = raw.try_into().map_err(|_| anyhow!("id seed not 32 bytes"))?;
            Ok(Some(seed))
        }
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(anyhow!("id keyring read failed: {e}")),
    }
}

pub fn delete_identity_seed(node_hex: &str) {
    if let Ok(entry) = keyring::Entry::new(SERVICE, &id_seed_account(node_hex)) {
        let _ = entry.delete_credential();
    }
}

/// Store / read / clear the S3 secret access key in the OS secure store (never in prefs.json).
pub fn save_s3_secret(secret: &str) -> Result<()> {
    let entry = keyring::Entry::new(SERVICE, S3_SECRET_ACCOUNT).context("open s3 keyring entry")?;
    entry.set_password(secret).context("write s3 secret")
}

pub fn load_s3_secret() -> Option<String> {
    let entry = keyring::Entry::new(SERVICE, S3_SECRET_ACCOUNT).ok()?;
    entry.get_password().ok()
}

pub fn delete_s3_secret() {
    if let Ok(entry) = keyring::Entry::new(SERVICE, S3_SECRET_ACCOUNT) {
        let _ = entry.delete_credential();
    }
}

/// Read the persisted social-state blob, if any.
pub fn read_state(paths: &Paths) -> Option<Vec<u8>> {
    fs::read(paths.state_file()).ok()
}

/// Write the social-state blob.
pub fn write_state(paths: &Paths, data: &[u8]) -> Result<()> {
    fs::write(paths.state_file(), data).context("write state")
}

/// Remove a file, ignoring "not found".
pub fn remove_if_exists(p: &Path) {
    let _ = fs::remove_file(p);
}

#[cfg(test)]
mod kept_story_tests {
    use super::*;

    fn entry(id: &str, kept_at: u64) -> KeptStory {
        KeptStory {
            id: id.into(),
            body: String::new(),
            media: vec![format!("m:{id}")],
            created_at: 1,
            kept_at: Some(kept_at),
            music_catalog_id: None,
            music_title: None,
            music_artist: None,
            music_artwork_url: None,
            music_duration_ms: None,
        }
    }

    fn wire(kept: Vec<KeptStory>, removed: &[(&str, u64)]) -> Vec<u8> {
        serde_json::to_vec(&KeptStoriesWire {
            kept,
            removed: removed.iter().map(|(k, v)| (k.to_string(), *v)).collect(),
        })
        .unwrap()
    }

    /// The whole reason this is not a last-writer-wins collection: keeping story A on one device and
    /// story B on another must converge to BOTH kept, not to whichever synced last.
    #[test]
    fn keeping_different_stories_on_two_devices_keeps_both() {
        let mut p = Prefs::default();
        p.kept_stories.push(entry("A", 100));
        assert!(p.merge_kept_stories(&wire(vec![entry("B", 200)], &[])));
        let mut ids: Vec<&str> = p.kept_stories.iter().map(|k| k.id.as_str()).collect();
        ids.sort();
        assert_eq!(ids, vec!["A", "B"]);
    }

    /// Un-keeping must PROPAGATE, not be silently undone by a sibling's stale copy — absence is not
    /// removal, which is why the tombstone exists at all.
    #[test]
    fn a_newer_tombstone_beats_a_siblings_stale_entry() {
        let mut p = Prefs::default();
        p.merge_kept_stories(&wire(vec![], &[("A", 300)]));
        // The sibling still holds A, kept BEFORE we un-kept it.
        p.merge_kept_stories(&wire(vec![entry("A", 200)], &[]));
        assert!(p.kept_stories.is_empty(), "a stale entry re-added an un-kept story");
    }

    /// ...and the converse: re-keeping something later still wins, in both directions.
    #[test]
    fn re_keeping_later_beats_an_older_tombstone() {
        let mut p = Prefs::default();
        p.merge_kept_stories(&wire(vec![], &[("A", 100)]));
        p.merge_kept_stories(&wire(vec![entry("A", 500)], &[]));
        assert_eq!(p.kept_stories.len(), 1);
        assert_eq!(p.kept_stories[0].id, "A");
    }

    /// A synced-in entry must PIN its media, or this device's cleanup sweeps reclaim the blobs and
    /// the kept story becomes a row of "no longer available" placeholders — kept in name only.
    #[test]
    fn a_synced_entry_pins_its_media() {
        let mut p = Prefs::default();
        p.merge_kept_stories(&wire(vec![entry("A", 100)], &[]));
        assert!(p.pinned_media.contains(&"m:A".to_string()));
    }

    /// Tombstones are BOUNDED — they only need to outlive a sibling being offline, not forever.
    #[test]
    fn tombstones_are_trimmed_past_the_cap() {
        let mut p = Prefs::default();
        for i in 0..600u64 {
            p.kept_stories_removed.insert(format!("s{i}"), i);
        }
        p.trim_kept_tombstones();
        assert_eq!(p.kept_stories_removed.len(), 250);
        // The NEWEST are the ones retained.
        assert!(p.kept_stories_removed.contains_key("s599"));
        assert!(!p.kept_stories_removed.contains_key("s0"));
    }

    /// The JSON is the cross-platform self-sync wire — the field names must stay camelCase and
    /// absent optionals must stay ABSENT, or a record written here won't round-trip through a phone.
    #[test]
    fn wire_field_names_match_the_apple_encoding() {
        let s = serde_json::to_string(&entry("A", 7)).unwrap();
        assert!(s.contains("\"createdAt\""), "{s}");
        assert!(s.contains("\"keptAt\""), "{s}");
        assert!(!s.contains("musicCatalogId"), "absent optionals must be omitted: {s}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_identity_is_active_and_uses_legacy_root() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        assert_eq!(ids.active, "aaaa");
        assert_eq!(ids.active_entry().unwrap().dir, ""); // legacy root, no migration
    }

    #[test]
    fn additional_identities_get_scoped_dirs_and_dont_steal_active() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("bbbb", "Alt");
        assert_eq!(ids.active, "aaaa"); // adding doesn't switch
        assert_eq!(ids.find("bbbb").unwrap().dir, "identities/bbbb");
    }

    #[test]
    fn add_is_idempotent() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("aaaa", "Me again");
        assert_eq!(ids.items.len(), 1);
    }

    #[test]
    fn set_active_only_for_known() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("bbbb", "Alt");
        assert!(ids.set_active("bbbb"));
        assert_eq!(ids.active, "bbbb");
        assert!(!ids.set_active("zzzz"));
        assert_eq!(ids.active, "bbbb");
    }

    #[test]
    fn cannot_remove_active_can_remove_others() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        ids.add("bbbb", "Alt");
        assert_eq!(ids.remove("aaaa"), None); // active is protected
        assert_eq!(ids.remove("bbbb"), Some("identities/bbbb".to_string()));
        assert!(ids.find("bbbb").is_none());
    }

    #[test]
    fn rename_identity() {
        let mut ids = Identities::default();
        ids.add("aaaa", "Me");
        assert!(ids.rename("aaaa", "Work"));
        assert_eq!(ids.find("aaaa").unwrap().label, "Work");
        assert!(!ids.rename("zzzz", "Nope"));
    }
}
