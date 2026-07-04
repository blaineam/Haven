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
    /// Bearer token the relay's HTTP interface requires (travels ONLY inside sealed announces).
    #[serde(default)]
    pub http_token: String,
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
    /// Per-relay metadata (name / active / last-seen / isS3), keyed by hex. The config survives a
    /// deactivation here so a relay can be turned back on without re-pasting anything. Mirrors iOS
    /// `RelayMailboxStore.entries` (UserDefaults key `haven.relay.entries`).
    #[serde(default)]
    pub relay_entries: std::collections::HashMap<String, RelayEntry>,
    /// Bearer token for OUR hosted relay's plain-HTTP interface (generated once at first host).
    #[serde(default)]
    pub relay_http_token: String,
    /// Optional public URL for OUR hosted relay's HTTP interface (port-forward / reverse proxy /
    /// tunnel) — announced ahead of the LAN address when set.
    #[serde(default)]
    pub relay_public_url: String,
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
}

impl Prefs {
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
        prefs
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

    /// Create-or-update a RelayEntry. `activate` flips it on; last_seen is stamped on first creation so a
    /// freshly-added relay's stale-clock starts now. Mirrors iOS `ensureEntry`.
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
