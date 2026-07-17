//! FFI surface for **multi-device** (D16): device credentials (Phase 1, [`haven_p2p::device`])
//! and account-state self-sync (Phase 3, [`haven_p2p::selfsync`]).
//!
//! Follows the rest of the FFI's seed-taking free-function style (cf. `open_sealed_with_seed`):
//! the account seed comes in, the account-only secrets (signing key, self-sync key) are derived
//! internally and **never cross the boundary**. The only object is [`AccountStateHandle`], a
//! mutable handle the clients build up and then seal.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use haven_p2p::device::{
    open_self_sync_key, open_self_sync_key_epoch, seal_self_sync_key, seal_self_sync_key_epoch,
    DeviceCredential, DeviceList,
};
use haven_p2p::identity::{HavenId, Identity};
use haven_p2p::selfsync::{AccountState, Stamp};
use haven_p2p::social::SealedEnvelope;

use crate::{hex, HavenError};

fn seed32(v: Vec<u8>) -> Result<[u8; 32], HavenError> {
    v.try_into().map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })
}
fn bundle(b: &[u8]) -> Result<HavenId, HavenError> {
    HavenId::from_bytes(b).map_err(|e| HavenError::Invalid { msg: format!("bad public bundle: {e}") })
}
fn id32(v: &[u8], what: &str) -> Result<[u8; 32], HavenError> {
    v.try_into().map_err(|_| HavenError::Invalid { msg: format!("{what} must be 32 bytes") })
}

// ── Phase 1: device credentials ──────────────────────────────────────────────────────────

/// Issue a device credential: the account (by seed) vouches for `device_bundle` (the new
/// device's public `HavenId` bytes). Returns the signed credential bytes to hand to the device.
#[uniffi::export]
pub fn issue_device_credential(
    account_seed: Vec<u8>,
    device_bundle: Vec<u8>,
    name: String,
    created_at: u64,
) -> Result<Vec<u8>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let dev = bundle(&device_bundle)?;
    Ok(DeviceCredential::issue(&acct, &dev, &name, created_at).to_bytes())
}

/// Verify a credential against the **pinned account public bundle**. On success returns the
/// authorized device's node id (hex); errors if forged, tampered, or for a different account.
#[uniffi::export]
pub fn verify_device_credential(account_bundle: Vec<u8>, credential: Vec<u8>) -> Result<String, HavenError> {
    let acct = bundle(&account_bundle)?;
    let cred = DeviceCredential::from_bytes(&credential)
        .map_err(|e| HavenError::Invalid { msg: format!("bad credential: {e}") })?;
    cred.verify(&acct).map_err(|e| HavenError::Invalid { msg: format!("credential rejected: {e}") })?;
    Ok(hex(&cred.device_id()))
}

/// Build + sign the account's device list. `devices`/`revoked` are 32-byte node ids.
#[uniffi::export]
pub fn sign_device_list(
    account_seed: Vec<u8>,
    version: u64,
    updated_at: u64,
    devices: Vec<Vec<u8>>,
    revoked: Vec<Vec<u8>>,
) -> Result<Vec<u8>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let devs = devices.iter().map(|d| id32(d, "device id")).collect::<Result<Vec<_>, _>>()?;
    let revs = revoked.iter().map(|d| id32(d, "revoked id")).collect::<Result<Vec<_>, _>>()?;
    Ok(DeviceList::signed(&acct, version, updated_at, devs, revs).to_bytes())
}

/// Verify a device list against the pinned account bundle. Returns its version on success.
#[uniffi::export]
pub fn verify_device_list(account_bundle: Vec<u8>, list: Vec<u8>) -> Result<u64, HavenError> {
    let acct = bundle(&account_bundle)?;
    let dl = DeviceList::from_bytes(&list)
        .map_err(|e| HavenError::Invalid { msg: format!("bad device list: {e}") })?;
    dl.verify(&acct).map_err(|e| HavenError::Invalid { msg: format!("device list rejected: {e}") })?;
    Ok(dl.version)
}

/// Is `device_id` (32 bytes) currently authorized by this (already-verified) device list?
#[uniffi::export]
pub fn device_list_is_authorized(list: Vec<u8>, device_id: Vec<u8>) -> Result<bool, HavenError> {
    let dl = DeviceList::from_bytes(&list)
        .map_err(|e| HavenError::Invalid { msg: format!("bad device list: {e}") })?;
    Ok(dl.is_authorized(&id32(&device_id, "device id")?))
}

// ── Phase 3: account-state self-sync ─────────────────────────────────────────────────────

/// One live record in an account state. Clients enumerate these (via
/// [`AccountStateHandle::entries`]) to reconcile **set-like** state — e.g. contacts and the
/// blocked list — where the keys aren't known ahead of time.
#[derive(uniffi::Record)]
pub struct SelfSyncEntry {
    pub key: String,
    pub value: Vec<u8>,
}

/// A mutable handle to a user's own [`AccountState`] CRDT. Build it up on a device, `seal` it
/// for the mailbox, `open` peers' blobs, and `merge` them to converge.
#[derive(uniffi::Object)]
pub struct AccountStateHandle {
    inner: Mutex<AccountState>,
}

#[uniffi::export]
impl AccountStateHandle {
    /// A fresh, empty account state.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self { inner: Mutex::new(AccountState::default()) })
    }

    /// Decode from the plaintext wire bytes (use `open_account_state` for sealed blobs).
    #[uniffi::constructor]
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Arc<Self>, HavenError> {
        let st = AccountState::from_bytes(&bytes)
            .map_err(|e| HavenError::Invalid { msg: format!("bad account state: {e}") })?;
        Ok(Arc::new(Self { inner: Mutex::new(st) }))
    }

    /// Set `key` to `value`, stamped by this device (`ts` = wall-clock ms, `device` = 32-byte
    /// node id). Returns true if this write won (newer than what we held).
    pub fn set(&self, key: String, value: Vec<u8>, ts: u64, device: Vec<u8>) -> Result<bool, HavenError> {
        let stamp = Stamp::new(ts, id32(&device, "device id")?);
        Ok(self.inner.lock().unwrap().set(&key, value, stamp))
    }

    /// Tombstone `key` (remove it), stamped by this device. Returns true if applied.
    pub fn remove(&self, key: String, ts: u64, device: Vec<u8>) -> Result<bool, HavenError> {
        let stamp = Stamp::new(ts, id32(&device, "device id")?);
        Ok(self.inner.lock().unwrap().remove(&key, stamp))
    }

    /// The current value for `key`, or null if absent/removed.
    pub fn get(&self, key: String) -> Option<Vec<u8>> {
        self.inner.lock().unwrap().get(&key).map(|v| v.to_vec())
    }

    /// Advance the read position for `name` to at least `ts` (grow-only). Returns true if moved.
    pub fn bump_cursor(&self, name: String, ts: u64) -> bool {
        self.inner.lock().unwrap().bump_cursor(&name, ts)
    }

    /// The read position for `name` (0 if unset).
    pub fn cursor(&self, name: String) -> u64 {
        self.inner.lock().unwrap().cursor(&name)
    }

    /// Merge another handle's state into this one (CRDT converge). No-op if it's the same handle.
    pub fn merge(self: Arc<Self>, other: Arc<AccountStateHandle>) {
        if Arc::ptr_eq(&self, &other) {
            return; // merging into itself is a no-op; also avoids a double-lock deadlock
        }
        let snapshot = other.inner.lock().unwrap().clone();
        self.inner.lock().unwrap().merge(&snapshot);
    }

    /// Plaintext wire bytes (for `from_bytes`; persist sealed via `seal_account_state`).
    pub fn to_bytes(&self) -> Vec<u8> {
        self.inner.lock().unwrap().to_bytes()
    }

    /// All live (non-tombstoned) records as `(key, value)` pairs, sorted by key. Lets a client
    /// enumerate set-like state (e.g. every `contact:<hex>` / `blocked:<hex>`) to reconcile it
    /// against the local stores after a merge.
    pub fn entries(&self) -> Vec<SelfSyncEntry> {
        self.inner
            .lock()
            .unwrap()
            .entries()
            .map(|(k, v)| SelfSyncEntry { key: k.to_string(), value: v.to_vec() })
            .collect()
    }
}

/// Seal this account state for the mailbox with the account's seed-derived self-sync key —
/// only the user's own devices (sharing the seed) can later `open` it.
#[uniffi::export]
pub fn seal_account_state(account_seed: Vec<u8>, state: Arc<AccountStateHandle>) -> Result<Vec<u8>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let st = state.inner.lock().unwrap();
    Ok(st.seal(&acct.self_sync_key()))
}

// ── Gap 3: shared circle-sync encoding (byte-identical across all platforms) ──────────────

/// A circle's portable structure for multi-device sync. Built/parsed by [`encode_circle_sync`]
/// / [`decode_circle_sync`] so every platform emits **identical bytes** (the cross-platform
/// convergence contract) — no per-platform JSON escaping / key-order / base64 drift.
#[derive(uniffi::Record)]
pub struct CircleSyncRecord {
    pub name: String,
    /// Each member's full public bundle bytes (the FFI base64-encodes them on the wire).
    pub member_bundles: Vec<Vec<u8>>,
    pub relays: Vec<String>,
    /// AUDIT M2: the circle's DEFINITION-bound creator account id (32 bytes), or null for a legacy
    /// circle with no recorded creator. Carried here so the authority root travels with the
    /// authenticated (self-sealed) circle definition instead of being TOFU-learned from the first admin
    /// grant. A consumer pins this as `creator_pinned`, so a hostile grant can never wedge a wrong root.
    pub creator: Option<Vec<u8>>,
}

// Field order is ALPHABETICAL so serde_json's declaration-order output matches Apple's
// JSONEncoder(.sortedKeys): {"creator":"...",?"members":[...],"name":"...","relays":[...]}.
// `creator` is skip-if-none, so a legacy circle (no creator) serializes BYTE-IDENTICALLY to before
// this field existed — the cross-platform convergence contract is preserved for existing circles.
#[derive(serde::Serialize, serde::Deserialize)]
struct CircleWire {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    creator: Option<String>,
    members: Vec<String>,
    name: String,
    relays: Vec<String>,
}

/// Deterministically encode a circle: standard-padding base64 of each member bundle (sorted),
/// sorted relays, compact JSON with alphabetical keys. Identical on iOS/Android/desktop. The
/// optional `creator` (32-byte account id, base64) binds the authority root to the definition (M2);
/// pass null for a legacy circle and the bytes are byte-identical to the pre-M2 encoding.
#[uniffi::export]
pub fn encode_circle_sync(
    name: String,
    member_bundles: Vec<Vec<u8>>,
    relays: Vec<String>,
    creator: Option<Vec<u8>>,
) -> Vec<u8> {
    let mut members: Vec<String> =
        member_bundles.iter().map(|b| data_encoding::BASE64.encode(b)).collect();
    members.sort();
    let mut relays = relays;
    relays.sort();
    let creator = creator.map(|c| data_encoding::BASE64.encode(&c));
    serde_json::to_vec(&CircleWire { creator, members, name, relays }).unwrap_or_default()
}

/// Inverse of [`encode_circle_sync`].
#[uniffi::export]
pub fn decode_circle_sync(bytes: Vec<u8>) -> Option<CircleSyncRecord> {
    let w: CircleWire = serde_json::from_slice(&bytes).ok()?;
    let member_bundles = w
        .members
        .iter()
        .filter_map(|b| data_encoding::BASE64.decode(b.as_bytes()).ok())
        .collect();
    let creator = w.creator.and_then(|c| data_encoding::BASE64.decode(c.as_bytes()).ok());
    Some(CircleSyncRecord { name: w.name, member_bundles, relays: w.relays, creator })
}

// ── Gap 1: S3 transport over the FFI (so Android — which has no native S3 — can self-sync
// over a BYO bucket, and any client can share the one tested SigV4 implementation) ──────────

/// A BYO S3-compatible bucket config (AWS / R2 / B2 / MinIO / rclone serve s3).
#[derive(uniffi::Record)]
pub struct S3ConfigFfi {
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub access_key: String,
    pub secret_key: String,
}

fn s3_mailbox(c: &S3ConfigFfi) -> Result<haven_s3::S3Mailbox, HavenError> {
    haven_s3::S3Mailbox::new(haven_s3::S3Config {
        endpoint: c.endpoint.clone(),
        region: c.region.clone(),
        bucket: c.bucket.clone(),
        access_key: c.access_key.clone(),
        secret_key: c.secret_key.clone(),
        prefix: String::new(), // self-sync passes fully-qualified keys
    })
    .map_err(|e| HavenError::Invalid { msg: format!("s3 config: {e}") })
}

/// PUT a blob to `key` in the bucket.
#[uniffi::export(async_runtime = "tokio")]
pub async fn s3_put(config: S3ConfigFfi, key: String, data: Vec<u8>) -> Result<(), HavenError> {
    s3_mailbox(&config)?
        .put(&key, &data)
        .await
        .map_err(|e| HavenError::Invalid { msg: format!("s3 put: {e}") })
}

/// GET a blob (None if absent).
#[uniffi::export(async_runtime = "tokio")]
pub async fn s3_get(config: S3ConfigFfi, key: String) -> Result<Option<Vec<u8>>, HavenError> {
    s3_mailbox(&config)?
        .get(&key)
        .await
        .map_err(|e| HavenError::Invalid { msg: format!("s3 get: {e}") })
}

/// LIST keys under `prefix`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn s3_list(config: S3ConfigFfi, prefix: String) -> Result<Vec<String>, HavenError> {
    s3_mailbox(&config)?
        .list(&prefix)
        .await
        .map_err(|e| HavenError::Invalid { msg: format!("s3 list: {e}") })
}

/// Canonical relay-mailbox key for this device's self-sync slot — `self/<account>/state/<device>`.
/// Every client MUST use this so a user's devices converge cross-platform.
///
/// Push recipe: `relay.put(self_sync_slot_key(acct, dev), seal_account_state(seed, state))`.
/// Pull recipe: for each key in `relay.list(self_sync_slot_prefix(acct))`, `open_account_state`
/// the blob and `state.merge(...)` it; then re-push your own slot.
#[uniffi::export]
pub fn self_sync_slot_key(account_node_hex: String, device_node_hex: String) -> String {
    haven_p2p::selfsync::slot_key(&account_node_hex, &device_node_hex)
}

/// Canonical prefix to list all of an account's self-sync slots — `self/<account>/state/`.
#[uniffi::export]
pub fn self_sync_slot_prefix(account_node_hex: String) -> String {
    haven_p2p::selfsync::slot_prefix(&account_node_hex)
}

/// Canonical mailbox slot for a rotated self-sync KEY GRANT sealed to one device (M1 revocation
/// rotation) — `self/<account>/keygrant/<device>`. SINGLE SOURCE OF TRUTH: every client must derive the
/// grant slot here so a rotated key crosses platforms; the grant blob comes from
/// `seal_self_sync_key_epoch_grant` and is opened by the recipient via `open_self_sync_key_epoch_grant`.
#[uniffi::export]
pub fn self_sync_grant_slot_key(account_node_hex: String, device_node_hex: String) -> String {
    haven_p2p::selfsync::grant_slot_key(&account_node_hex, &device_node_hex)
}

/// Canonical prefix to list all of an account's rotated-key-grant slots — `self/<account>/keygrant/`.
#[uniffi::export]
pub fn self_sync_grant_slot_prefix(account_node_hex: String) -> String {
    haven_p2p::selfsync::grant_slot_prefix(&account_node_hex)
}

/// Open a blob produced by `seal_account_state` (fails on wrong account / tamper).
#[uniffi::export]
pub fn open_account_state(account_seed: Vec<u8>, sealed: Vec<u8>) -> Result<Arc<AccountStateHandle>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let st = AccountState::open(&acct.self_sync_key(), &sealed)
        .map_err(|e| HavenError::Invalid { msg: format!("open account state failed: {e}") })?;
    Ok(Arc::new(AccountStateHandle { inner: Mutex::new(st) }))
}

// ── Seed-drop S4 / F11: self-sync WITHOUT the seed ─────────────────────────────────────────
//
// `seal_account_state` / `open_account_state` derive the self-sync key from the account seed. A
// SEEDLESS device (seed-drop S4) never holds the seed — the primary GRANTS it the 32-byte key
// (`seal_self_sync_key_grant` → `open_self_sync_key_grant`), and the device then seals/opens its
// own self-sync slots with that bare key. These are the FFI wrappers over `selfsync::AccountState`'s
// bare-key `seal`/`open` and `device::{seal,open}_self_sync_key`.

/// Seal an account state for the mailbox with a BARE 32-byte self-sync key (not derived from a seed).
/// Used by a seedless device with the GRANTED key; identical output to `seal_account_state` for the same
/// key, so a seeded and a seedless device converge on the same slots.
#[uniffi::export]
pub fn seal_account_state_with_key(self_sync_key: Vec<u8>, state: Arc<AccountStateHandle>) -> Result<Vec<u8>, HavenError> {
    let key = id32(&self_sync_key, "self-sync key")?;
    let st = state.inner.lock().unwrap();
    Ok(st.seal(&key))
}

/// Open a `seal_account_state`/`seal_account_state_with_key` blob with a BARE 32-byte self-sync key.
#[uniffi::export]
pub fn open_account_state_with_key(self_sync_key: Vec<u8>, sealed: Vec<u8>) -> Result<Arc<AccountStateHandle>, HavenError> {
    let key = id32(&self_sync_key, "self-sync key")?;
    let st = AccountState::open(&key, &sealed)
        .map_err(|e| HavenError::Invalid { msg: format!("open account state failed: {e}") })?;
    Ok(Arc::new(AccountStateHandle { inner: Mutex::new(st) }))
}

/// PRIMARY side (holds the seed): seal the account's self-sync key to a seedless device's public bundle,
/// signed by the account so the device can verify provenance. Returns the sealed grant envelope bytes to
/// ride the enroll grant / a directed transfer. Wrapper over `device::seal_self_sync_key`.
#[uniffi::export]
pub fn seal_self_sync_key_grant(account_seed: Vec<u8>, device_bundle: Vec<u8>) -> Result<Vec<u8>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let dev = bundle(&device_bundle)?;
    let env = seal_self_sync_key(&acct, &dev, &acct.self_sync_key())
        .map_err(|e| HavenError::Invalid { msg: format!("seal self-sync grant failed: {e}") })?;
    Ok(env.to_bytes())
}

/// SEEDLESS-DEVICE side: open a grant sealed by `seal_self_sync_key_grant`, verifying the account's
/// signature against its pinned public bundle, and return the 32-byte self-sync key to store + use with
/// `seal_account_state_with_key` / `open_account_state_with_key`. A grant sealed to another device (or a
/// tampered / forged one) fails here. Wrapper over `device::open_self_sync_key`.
#[uniffi::export]
pub fn open_self_sync_key_grant(device_seed: Vec<u8>, account_bundle: Vec<u8>, envelope: Vec<u8>) -> Result<Vec<u8>, HavenError> {
    let dev = Identity::from_seed(&seed32(device_seed)?);
    let acct = bundle(&account_bundle)?;
    let env = SealedEnvelope::from_bytes(&envelope)
        .map_err(|e| HavenError::Invalid { msg: format!("bad grant envelope: {e}") })?;
    let key = open_self_sync_key(&dev, &acct, &env)
        .map_err(|e| HavenError::Invalid { msg: format!("open self-sync grant failed: {e}") })?;
    Ok(key.to_vec())
}

// ── Audit M1: ROTATABLE self-sync key (rotate on revocation) ────────────────────────────────────
//
// The channel above hands each device a STATIC self-sync key, so a revoked seedless device kept
// reading AND LWW-writing the account-state stream forever. These wrappers add the rotatable, versioned
// key: on a device revocation the primary `mint_self_sync_key`s a fresh key, bumps the epoch, and
// `seal_self_sync_key_epoch_grant`s it to every STILL-authorized device only. Account state is then
// sealed with `seal_account_state_with_key_epoch` and opened with `open_account_state_dual`, which
// refuses a stale-epoch (revoked) write. This is gated EXACTLY like the circle dual-seal retirement:
// while the retirement switch is OFF, clients keep calling `seal_account_state`/`open_account_state`
// (v0, seed-derived) and every byte on the wire is unchanged. See `docs/SEED-DROP-DESIGN.md` §5.3.

/// An epoch-tagged self-sync key grant: the rotated `key` and the `epoch` it belongs to.
#[derive(uniffi::Record)]
pub struct SelfSyncKeyGrant {
    pub epoch: u64,
    pub key: Vec<u8>,
}

/// Mint a fresh 32-byte self-sync key from the OS CSPRNG. Called by the PRIMARY on a device revocation
/// to rotate the account-state channel (then re-granted to every still-authorized device bundle).
#[uniffi::export]
pub fn mint_self_sync_key() -> Vec<u8> {
    haven_p2p::selfsync::mint_self_sync_key().to_vec()
}

/// The self-sync rotation GATE — shaped EXACTLY like the circle dual-seal retirement
/// (`recipients_with_devices_gated`). Returns whether the account-state channel should run on the
/// ROTATED (v1) key and DROP v0 seed-key authority: only when the retirement switch is ON **and** every
/// one of the account's OWN authorized devices is seed-drop-capable (so no device still depends on the
/// seed-derived key). OFF or mixed-capability ⇒ false ⇒ clients keep sealing with `seal_account_state`
/// and opening with `open_account_state` (v0) and every byte is byte-identical to today. Until this
/// returns true a reader must keep passing the seed key to `open_account_state_dual`, so the dual-key
/// transition window (§5.2) never strands a device — mirroring the account-key dual-seal window.
#[uniffi::export]
pub fn self_sync_key_should_rotate(retire_switch_on: bool, own_devices_all_seed_drop_capable: bool) -> bool {
    retire_switch_on && own_devices_all_seed_drop_capable
}

/// The key-epoch stamped on a sealed account-state blob, or null for a legacy (v0, seed-derived) blob.
/// Lets the mailbox layer route a pulled slot to the right rotated key without decrypting it.
#[uniffi::export]
pub fn self_sync_key_epoch_of(sealed: Vec<u8>) -> Option<u64> {
    AccountState::peek_epoch(&sealed)
}

/// Seal an account state under a rotated self-sync `key` at `epoch` (the v1 path). Used once the
/// account has rotated (retirement ON + fully seed-drop-capable); produces a versioned blob that a
/// stale-key (revoked) device cannot open.
#[uniffi::export]
pub fn seal_account_state_with_key_epoch(
    self_sync_key: Vec<u8>,
    epoch: u64,
    state: Arc<AccountStateHandle>,
) -> Result<Vec<u8>, HavenError> {
    let key = id32(&self_sync_key, "self-sync key")?;
    let st = state.inner.lock().unwrap();
    Ok(st.seal_epoch(&key, epoch))
}

/// DUAL-KEY open of any account-state blob (v0 legacy OR v1 rotatable) — the reader side of the M1 cut.
///
/// * `current_epoch`/`current_key` — the rotated key the reader currently honors (a 32-byte key; pass an
///   empty `current_key` for a reader that only accepts v0). A v1 blob at any OTHER epoch (a revoked
///   device's stale write) is refused.
/// * `seed_key` — the seed-derived v0 key, or an EMPTY vec once v0 authority is retired (the
///   fully-capable + switch-ON state), which refuses legacy blobs and completes the revocation cut.
#[uniffi::export]
pub fn open_account_state_dual(
    sealed: Vec<u8>,
    current_epoch: u64,
    current_key: Vec<u8>,
    seed_key: Vec<u8>,
) -> Result<Arc<AccountStateHandle>, HavenError> {
    let mut accepted: BTreeMap<u64, [u8; 32]> = BTreeMap::new();
    if !current_key.is_empty() {
        accepted.insert(current_epoch, id32(&current_key, "current self-sync key")?);
    }
    let seed = if seed_key.is_empty() { None } else { Some(id32(&seed_key, "seed self-sync key")?) };
    let st = AccountState::open_any(&sealed, seed.as_ref(), &accepted)
        .map_err(|e| HavenError::Invalid { msg: format!("open account state failed: {e}") })?;
    Ok(Arc::new(AccountStateHandle { inner: Mutex::new(st) }))
}

/// PRIMARY side: seal a ROTATED self-sync key (with its epoch) to a still-authorized device's bundle,
/// account-signed. Returns the sealed grant bytes. Wrapper over `device::seal_self_sync_key_epoch`.
#[uniffi::export]
pub fn seal_self_sync_key_epoch_grant(
    account_seed: Vec<u8>,
    device_bundle: Vec<u8>,
    epoch: u64,
    self_sync_key: Vec<u8>,
) -> Result<Vec<u8>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let dev = bundle(&device_bundle)?;
    let key = id32(&self_sync_key, "self-sync key")?;
    let env = seal_self_sync_key_epoch(&acct, &dev, epoch, &key)
        .map_err(|e| HavenError::Invalid { msg: format!("seal epoch self-sync grant failed: {e}") })?;
    Ok(env.to_bytes())
}

/// SEEDLESS-DEVICE side: open an epoch-tagged grant from `seal_self_sync_key_epoch_grant`, verifying the
/// account's signature. Returns `(epoch, key)`. Wrapper over `device::open_self_sync_key_epoch`.
#[uniffi::export]
pub fn open_self_sync_key_epoch_grant(
    device_seed: Vec<u8>,
    account_bundle: Vec<u8>,
    envelope: Vec<u8>,
) -> Result<SelfSyncKeyGrant, HavenError> {
    let dev = Identity::from_seed(&seed32(device_seed)?);
    let acct = bundle(&account_bundle)?;
    let env = SealedEnvelope::from_bytes(&envelope)
        .map_err(|e| HavenError::Invalid { msg: format!("bad grant envelope: {e}") })?;
    let (epoch, key) = open_self_sync_key_epoch(&dev, &acct, &env)
        .map_err(|e| HavenError::Invalid { msg: format!("open epoch self-sync grant failed: {e}") })?;
    Ok(SelfSyncKeyGrant { epoch, key: key.to_vec() })
}
