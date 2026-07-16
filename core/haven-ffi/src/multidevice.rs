//! FFI surface for **multi-device** (D16): device credentials (Phase 1, [`haven_p2p::device`])
//! and account-state self-sync (Phase 3, [`haven_p2p::selfsync`]).
//!
//! Follows the rest of the FFI's seed-taking free-function style (cf. `open_sealed_with_seed`):
//! the account seed comes in, the account-only secrets (signing key, self-sync key) are derived
//! internally and **never cross the boundary**. The only object is [`AccountStateHandle`], a
//! mutable handle the clients build up and then seal.

use std::sync::{Arc, Mutex};

use haven_p2p::device::{DeviceCredential, DeviceList};
use haven_p2p::identity::{HavenId, Identity};
use haven_p2p::selfsync::{AccountState, Stamp};

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
}

// Field order is ALPHABETICAL so serde_json's declaration-order output matches Apple's
// JSONEncoder(.sortedKeys): {"members":[...],"name":"...","relays":[...]}.
#[derive(serde::Serialize, serde::Deserialize)]
struct CircleWire {
    members: Vec<String>,
    name: String,
    relays: Vec<String>,
}

/// Deterministically encode a circle: standard-padding base64 of each member bundle (sorted),
/// sorted relays, compact JSON with alphabetical keys. Identical on iOS/Android/desktop.
#[uniffi::export]
pub fn encode_circle_sync(name: String, member_bundles: Vec<Vec<u8>>, relays: Vec<String>) -> Vec<u8> {
    let mut members: Vec<String> =
        member_bundles.iter().map(|b| data_encoding::BASE64.encode(b)).collect();
    members.sort();
    let mut relays = relays;
    relays.sort();
    serde_json::to_vec(&CircleWire { members, name, relays }).unwrap_or_default()
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
    Some(CircleSyncRecord { name: w.name, member_bundles, relays: w.relays })
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

/// Open a blob produced by `seal_account_state` (fails on wrong account / tamper).
#[uniffi::export]
pub fn open_account_state(account_seed: Vec<u8>, sealed: Vec<u8>) -> Result<Arc<AccountStateHandle>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let st = AccountState::open(&acct.self_sync_key(), &sealed)
        .map_err(|e| HavenError::Invalid { msg: format!("open account state failed: {e}") })?;
    Ok(Arc::new(AccountStateHandle { inner: Mutex::new(st) }))
}
