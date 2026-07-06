//! Per-device credentials & signed device lists — the trust foundation for
//! **multi-device** (roadmap D16).
//!
//! The model (see `docs/MULTI-DEVICE.md`): a user is **one account identity** with a
//! set of **authorized devices**, each holding its *own* keypair that never leaves the
//! device. The account identity key (the long-term key contacts pin) **signs**:
//!
//!   * a [`DeviceCredential`] per device — `{account_id, device bundle, name, created_at}`
//!     signed by the account, proving "this device is authorized by this account"; and
//!   * a versioned, signed [`DeviceList`] — the current roster (active + revoked) that
//!     contacts honor so a relay can't inject a rogue device or hide a revocation.
//!
//! This layer is deliberately **independent of MLS** (D3). A device credential is just a
//! signed binding; messages reach a device because its full `HavenId` bundle is published
//! in the credential, so the existing per-recipient hybrid-KEM sealing can encrypt to it.
//! The MLS-specific hardening (forward secrecy + post-compromise rekey on Add/Remove
//! *commits*) layers on top once MLS lands — it does not change these signatures.
//!
//! Everything here is **pure** (no clock, no RNG of its own): `created_at` / `updated_at`
//! / `version` are supplied by the caller, keeping the module deterministic and trivially
//! testable on every platform (incl. WASM).

use crate::identity::{HavenId, Identity};
use crate::{CoreError, Result};

/// Domain-separation tag for the bytes an account signs to issue a device credential.
const CRED_DOMAIN: &[u8] = b"haven-device-cred-v1";
/// Domain-separation tag for the bytes an account signs over a device list.
const LIST_DOMAIN: &[u8] = b"haven-device-list-v1";

/// A device authorized by an account.
///
/// The `sig` is a **hybrid** (Ed25519 + ML-DSA) signature **by the account identity** over
/// the canonical encoding of `{account_id, device, device_name, created_at}`. A contact who
/// has pinned the account's `HavenId` (from the first QR/link verification) can therefore
/// verify that this device legitimately belongs to that account — no relay or third party
/// can forge it.
///
/// (No `PartialEq`/`Debug` derive: it embeds a [`HavenId`], a minimal core type that
/// derives neither. Compare credentials by [`Self::to_bytes`] when needed.)
#[derive(Clone)]
pub struct DeviceCredential {
    /// The account's 32-byte node id (Ed25519 public key) this device belongs to.
    pub account_id: [u8; 32],
    /// The device's full public bundle — peers seal to this so the device can decrypt.
    pub device: HavenId,
    /// Human-readable device label (e.g. "Blaine's iPhone"). Advisory only.
    pub device_name: String,
    /// Unix seconds the credential was issued (caller-supplied; not trusted for security).
    pub created_at: u64,
    /// Hybrid signature by the **account** identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl DeviceCredential {
    /// The canonical bytes the account signs / a verifier re-derives. Stable layout:
    /// `domain ‖ account_id(32) ‖ created_at(8 LE) ‖ name_len(4 LE) ‖ name ‖ device_bundle`.
    fn signing_bytes(account_id: &[u8; 32], device: &HavenId, name: &str, created_at: u64) -> Vec<u8> {
        let dev = device.to_bytes();
        let name_b = name.as_bytes();
        let mut v = Vec::with_capacity(CRED_DOMAIN.len() + 32 + 8 + 4 + name_b.len() + dev.len());
        v.extend_from_slice(CRED_DOMAIN);
        v.extend_from_slice(account_id);
        v.extend_from_slice(&created_at.to_le_bytes());
        v.extend_from_slice(&(name_b.len() as u32).to_le_bytes());
        v.extend_from_slice(name_b);
        v.extend_from_slice(&dev);
        v
    }

    /// Issue a credential: the **account** identity vouches for `device`.
    pub fn issue(account: &Identity, device: &HavenId, name: &str, created_at: u64) -> Self {
        let account_id = account.public().node_id_bytes();
        let msg = Self::signing_bytes(&account_id, device, name, created_at);
        let sig = account.sign(&msg);
        Self { account_id, device: device.clone(), device_name: name.to_string(), created_at, sig }
    }

    /// Verify this credential against the **pinned account public key**.
    ///
    /// Fails if the credential names a different account than `account_pub`, or if the
    /// account's hybrid signature does not check out (tamper / forgery).
    pub fn verify(&self, account_pub: &HavenId) -> Result<()> {
        if account_pub.node_id_bytes() != self.account_id {
            return Err(CoreError::Crypto("device credential: account id mismatch"));
        }
        let msg = Self::signing_bytes(&self.account_id, &self.device, &self.device_name, self.created_at);
        account_pub.verify(&msg, &self.sig)
    }

    /// The device's 32-byte node id (its routable id / device-list key).
    pub fn device_id(&self) -> [u8; 32] {
        self.device.node_id_bytes()
    }

    /// Wire encoding: `account_id(32) ‖ created_at(8) ‖ name_len(4) ‖ name ‖
    /// dev_len(4) ‖ device_bundle ‖ sig`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let dev = self.device.to_bytes();
        let name_b = self.device_name.as_bytes();
        let mut v = Vec::with_capacity(32 + 8 + 4 + name_b.len() + 4 + dev.len() + self.sig.len());
        v.extend_from_slice(&self.account_id);
        v.extend_from_slice(&self.created_at.to_le_bytes());
        v.extend_from_slice(&(name_b.len() as u32).to_le_bytes());
        v.extend_from_slice(name_b);
        v.extend_from_slice(&(dev.len() as u32).to_le_bytes());
        v.extend_from_slice(&dev);
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let account_id = r.array32()?;
        let created_at = r.u64()?;
        let name = r.str_lp()?;
        let dev = r.bytes_lp()?;
        let device = HavenId::from_bytes(dev)?;
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("device credential: missing signature"));
        }
        Ok(Self { account_id, device, device_name: name, created_at, sig })
    }
}

/// The account's **signed, versioned device roster**. Contacts honor the highest `version`
/// they've seen whose signature chains to the pinned account key; this is the anti-rogue /
/// anti-rollback-of-revocation mechanism. A device is trusted iff it is in `devices` and
/// not in `revoked`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceList {
    /// The account this roster belongs to (its 32-byte node id).
    pub account_id: [u8; 32],
    /// Monotonic version — a verifier keeps the highest it has seen (rollback defense).
    pub version: u64,
    /// Unix seconds of this update (caller-supplied; advisory).
    pub updated_at: u64,
    /// Active device node ids.
    pub devices: Vec<[u8; 32]>,
    /// Revoked device node ids (kept so an old credential can't be replayed as live).
    pub revoked: Vec<[u8; 32]>,
    /// Hybrid signature by the **account** identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl DeviceList {
    fn signing_bytes(
        account_id: &[u8; 32],
        version: u64,
        updated_at: u64,
        devices: &[[u8; 32]],
        revoked: &[[u8; 32]],
    ) -> Vec<u8> {
        let mut v = Vec::with_capacity(LIST_DOMAIN.len() + 32 + 8 + 8 + 8 + (devices.len() + revoked.len()) * 32);
        v.extend_from_slice(LIST_DOMAIN);
        v.extend_from_slice(account_id);
        v.extend_from_slice(&version.to_le_bytes());
        v.extend_from_slice(&updated_at.to_le_bytes());
        v.extend_from_slice(&(devices.len() as u64).to_le_bytes());
        for d in devices {
            v.extend_from_slice(d);
        }
        v.extend_from_slice(&(revoked.len() as u64).to_le_bytes());
        for d in revoked {
            v.extend_from_slice(d);
        }
        v
    }

    /// Build and sign a device list with the account identity.
    pub fn signed(
        account: &Identity,
        version: u64,
        updated_at: u64,
        devices: Vec<[u8; 32]>,
        revoked: Vec<[u8; 32]>,
    ) -> Self {
        let account_id = account.public().node_id_bytes();
        let msg = Self::signing_bytes(&account_id, version, updated_at, &devices, &revoked);
        let sig = account.sign(&msg);
        Self { account_id, version, updated_at, devices, revoked, sig }
    }

    /// Verify the list against the pinned account key (id match + hybrid signature).
    pub fn verify(&self, account_pub: &HavenId) -> Result<()> {
        if account_pub.node_id_bytes() != self.account_id {
            return Err(CoreError::Crypto("device list: account id mismatch"));
        }
        let msg = Self::signing_bytes(&self.account_id, self.version, self.updated_at, &self.devices, &self.revoked);
        account_pub.verify(&msg, &self.sig)
    }

    /// Is `device_id` currently authorized? (present and not revoked).
    pub fn is_authorized(&self, device_id: &[u8; 32]) -> bool {
        !self.revoked.contains(device_id) && self.devices.contains(device_id)
    }

    /// Merge rule across devices/replicas: **higher `version` wins**. Returns `true` if
    /// `other` is newer and was adopted. Both must already be `verify()`-ed by the caller.
    pub fn adopt_if_newer(&mut self, other: &DeviceList) -> bool {
        if other.account_id == self.account_id && other.version > self.version {
            *self = other.clone();
            true
        } else {
            false
        }
    }

    /// UNION merge for multi-master accounts: when several devices each hold the account signing key
    /// (e.g. they all restored the same account from iCloud) and each self-registers its own device id,
    /// a plain higher-version-wins replace ([`adopt_if_newer`]) lets two devices clobber each other's
    /// registration. Instead take a **2P-set union**: union the `devices` sets and union the `revoked`
    /// sets — EXCEPT that where the two lists disagree about a revocation, the HIGHER-version list's
    /// verdict wins. A pure grow-only `revoked` made un-revocation impossible: `with_self_added`
    /// deliberately clears its own tombstone (explicit re-authorization, version-bumped), but every
    /// union with any older copy of the roster re-added it — so a device that ever got revoked
    /// flip-flopped forever (each flip re-signing + rotating every circle epoch: the roster/epoch
    /// churn bug). Both lists carry the account's signature and versions only grow, so "newer verdict
    /// wins" cannot be forged and a replayed old list can only lose. On a version TIE a revocation
    /// stays (safe default). Returns `None` when the merge wouldn't change our membership (no
    /// needless re-sign / rotation storm). Both inputs must already be `verify()`-ed by the caller.
    pub fn merge(&self, other: &DeviceList, account: &Identity, updated_at: u64) -> Option<DeviceList> {
        if other.account_id != self.account_id {
            return None;
        }
        let (newer, older) = if other.version > self.version { (other, self) } else { (self, other) };
        let mut revoked: Vec<[u8; 32]> = Vec::new();
        for r in self.revoked.iter().chain(other.revoked.iter()) {
            if revoked.contains(r) {
                continue;
            }
            // Revoked only in the older list + explicitly re-authorized by the strictly-newer one
            // (present in its devices, absent from its revoked) → the re-authorization wins.
            let reauthorized = newer.version > older.version
                && older.revoked.contains(r)
                && !newer.revoked.contains(r)
                && newer.devices.contains(r);
            if !reauthorized {
                revoked.push(*r);
            }
        }
        let mut devices: Vec<[u8; 32]> = Vec::new();
        for d in self.devices.iter().chain(other.devices.iter()) {
            if !revoked.contains(d) && !devices.contains(d) {
                devices.push(*d);
            }
        }
        devices.sort_unstable();
        revoked.sort_unstable();
        // No membership change → don't churn a new signed version (idempotent convergence).
        let mut cur_dev = self.devices.clone();
        cur_dev.sort_unstable();
        let mut cur_rev = self.revoked.clone();
        cur_rev.sort_unstable();
        if devices == cur_dev && revoked == cur_rev {
            return None;
        }
        let version = self.version.max(other.version) + 1;
        Some(DeviceList::signed(account, version, updated_at, devices, revoked))
    }

    /// Add this device's own id to the roster (self-registration on launch) and re-sign. Returns `None`
    /// if `device_id` is already present (and not revoked) — no needless version bump.
    pub fn with_self_added(&self, device_id: [u8; 32], account: &Identity, updated_at: u64) -> Option<DeviceList> {
        if self.devices.contains(&device_id) && !self.revoked.contains(&device_id) {
            return None;
        }
        let mut devices = self.devices.clone();
        if !devices.contains(&device_id) {
            devices.push(device_id);
        }
        // Re-adding a previously-revoked device id is an explicit re-authorization: clear its tombstone.
        let revoked: Vec<[u8; 32]> = self.revoked.iter().copied().filter(|r| r != &device_id).collect();
        Some(DeviceList::signed(account, self.version + 1, updated_at, devices, revoked))
    }

    /// Wire encoding: `account_id(32) ‖ version(8) ‖ updated_at(8) ‖ n_dev(4) ‖ dev*32 ‖
    /// n_rev(4) ‖ rev*32 ‖ sig`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(32 + 16 + 8 + (self.devices.len() + self.revoked.len()) * 32 + self.sig.len());
        v.extend_from_slice(&self.account_id);
        v.extend_from_slice(&self.version.to_le_bytes());
        v.extend_from_slice(&self.updated_at.to_le_bytes());
        v.extend_from_slice(&(self.devices.len() as u32).to_le_bytes());
        for d in &self.devices {
            v.extend_from_slice(d);
        }
        v.extend_from_slice(&(self.revoked.len() as u32).to_le_bytes());
        for d in &self.revoked {
            v.extend_from_slice(d);
        }
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let account_id = r.array32()?;
        let version = r.u64()?;
        let updated_at = r.u64()?;
        let n_dev = r.u32()? as usize;
        let mut devices = Vec::with_capacity(n_dev);
        for _ in 0..n_dev {
            devices.push(r.array32()?);
        }
        let n_rev = r.u32()? as usize;
        let mut revoked = Vec::with_capacity(n_rev);
        for _ in 0..n_rev {
            revoked.push(r.array32()?);
        }
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("device list: missing signature"));
        }
        Ok(Self { account_id, version, updated_at, devices, revoked, sig })
    }
}

/// A contact's verified multi-device info: their signed [`DeviceList`] plus the per-device
/// [`DeviceCredential`]s (which carry the routable device bundles peers seal to). The client builds
/// this after verifying BOTH against the contact's pinned account key, then uses it to seal to the
/// contact's *devices* instead of (only) their account key.
#[derive(Clone)]
pub struct ContactDevices {
    pub list: DeviceList,
    pub credentials: Vec<DeviceCredential>,
}

impl ContactDevices {
    /// The device bundles currently authorized to receive this account's content (present in the list,
    /// not revoked). A revoked device's credential is dropped here, so it never becomes a recipient.
    pub fn authorized_bundles(&self) -> Vec<HavenId> {
        self.credentials
            .iter()
            .filter(|c| self.list.is_authorized(&c.device_id()))
            .map(|c| c.device.clone())
            .collect()
    }
}

/// Expand a circle's account-level member set into the actual KEY-COMMIT recipients: each member's
/// currently-authorized **device** bundles, so a circle's epoch key seals to every device the user
/// trusts and **never** to a revoked one. A member with no known device info falls back to its own
/// account key, so pre-multidevice contacts (and your own not-yet-enrolled devices) keep working.
/// Stable order, de-duplicated by node id. Pair with epoch rotation on any device add/revoke so the
/// dropped device can't open content sealed afterward — the same revocation the audit already relies on.
pub fn recipients_with_devices(
    members: &[HavenId],
    devices_by_account: &std::collections::HashMap<[u8; 32], ContactDevices>,
) -> Vec<HavenId> {
    let mut out: Vec<HavenId> = Vec::new();
    let mut seen: std::collections::HashSet<[u8; 32]> = std::collections::HashSet::new();
    for m in members {
        let acct = m.node_id_bytes();
        // ALWAYS seal to the account key: any holder of the account seed (the user's own iCloud-synced
        // devices) opens it robustly, WITHOUT depending on full device-roster propagation. This is what
        // makes sibling devices reliably read each other's content — a device that only knows its own id
        // would otherwise seal to itself alone and strand its siblings.
        if seen.insert(acct) {
            out.push(m.clone());
        }
        // PLUS each currently-authorized device bundle, so a LINK-FLOW device (which does NOT hold the
        // account seed) can also open — and revocation still cuts it off: a revoked device is dropped from
        // here AND lacks the account seed, so it can open neither path.
        if let Some(d) = devices_by_account.get(&acct) {
            for b in d.authorized_bundles() {
                if seen.insert(b.node_id_bytes()) {
                    out.push(b);
                }
            }
        }
    }
    out
}

/// Minimal length-prefixed byte reader for the wire formats above.
struct Reader<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Reader<'a> {
    fn new(b: &'a [u8]) -> Self {
        Self { b, i: 0 }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.i + n > self.b.len() {
            return Err(CoreError::Encoding("device wire: unexpected end of input"));
        }
        let s = &self.b[self.i..self.i + n];
        self.i += n;
        Ok(s)
    }
    fn array32(&mut self) -> Result<[u8; 32]> {
        Ok(self.take(32)?.try_into().unwrap())
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn bytes_lp(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn str_lp(&mut self) -> Result<String> {
        let b = self.bytes_lp()?;
        String::from_utf8(b.to_vec()).map_err(|_| CoreError::Encoding("device wire: invalid utf-8 name"))
    }
    fn rest(&self) -> &'a [u8] {
        &self.b[self.i..]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    fn id(seed: u8) -> Identity {
        Identity::from_seed(&[seed; 32])
    }

    #[test]
    fn merge_honors_newer_reauthorization() {
        // A device that was revoked and then explicitly re-authorized (with_self_added bumps the
        // version and clears the tombstone) must STAY re-authorized when merged with an older copy
        // that still carries the revocation — otherwise the tombstone flip-flops forever, re-signing
        // the roster and rotating every circle epoch on each flip.
        let account = id(1);
        let dev = id(2).public().node_id_bytes();
        let other_dev = id(3).public().node_id_bytes();
        // v2: dev revoked.
        let revoked_list = DeviceList::signed(&account, 2, 100, vec![other_dev], vec![dev]);
        // Self-registration re-authorizes dev at v3.
        let reauth = revoked_list.with_self_added(dev, &account, 200).expect("re-add clears tombstone");
        assert_eq!(reauth.version, 3);
        assert!(reauth.is_authorized(&dev));
        // Merging the newer (re-authorized) list with the stale revoked copy — in either direction —
        // must not resurrect the tombstone.
        if let Some(m) = reauth.merge(&revoked_list, &account, 300) {
            assert!(m.is_authorized(&dev), "newer re-authorization must win the merge");
        } // None = no membership change, which also preserves the re-authorization.
        let m2 = revoked_list.merge(&reauth, &account, 300).expect("stale side adopts the re-auth");
        assert!(m2.is_authorized(&dev));
        assert!(m2.verify(&account.public()).is_ok());
        // A revocation that is NEWER than the device list still sticks (revoke wins going forward).
        let re_revoked = DeviceList::signed(&account, m2.version + 1, 400, vec![other_dev], vec![dev]);
        let m3 = m2.merge(&re_revoked, &account, 500).expect("newer revocation adopted");
        assert!(!m3.is_authorized(&dev));
        // And a same-version disagreement keeps the revocation (safe default on ties).
        let tie_a = DeviceList::signed(&account, 10, 600, vec![dev, other_dev], vec![]);
        let tie_b = DeviceList::signed(&account, 10, 600, vec![other_dev], vec![dev]);
        if let Some(m4) = tie_a.merge(&tie_b, &account, 700) {
            assert!(!m4.is_authorized(&dev));
        }
    }

    #[test]
    fn issue_then_verify_against_pinned_account() {
        let account = id(1);
        let device = id(2);
        let cred = DeviceCredential::issue(&account, &device.public(), "iPhone", 1_700_000_000);
        // A contact who pinned the account key trusts the device.
        cred.verify(&account.public()).expect("valid credential must verify");
        assert_eq!(cred.device_id(), device.public().node_id_bytes());
    }

    #[test]
    fn credential_rejected_for_wrong_account() {
        let account = id(1);
        let imposter = id(9);
        let device = id(2);
        let cred = DeviceCredential::issue(&account, &device.public(), "iPhone", 1);
        // Pinning a different account key must reject it (id mismatch / bad sig).
        assert!(cred.verify(&imposter.public()).is_err());
    }

    #[test]
    fn credential_tamper_is_detected() {
        let account = id(1);
        let device = id(2);
        let mut cred = DeviceCredential::issue(&account, &device.public(), "iPhone", 1);
        cred.device_name = "Attacker's laptop".into(); // forge the label
        assert!(cred.verify(&account.public()).is_err());
    }

    #[test]
    fn credential_roundtrips_through_wire() {
        let account = id(7);
        let device = id(8);
        let cred = DeviceCredential::issue(&account, &device.public(), "MacBook Pro", 42);
        let back = DeviceCredential::from_bytes(&cred.to_bytes()).expect("decode");
        assert_eq!(cred.to_bytes(), back.to_bytes(), "wire round-trip must be stable");
        assert_eq!(cred.device_name, back.device_name);
        assert_eq!(cred.created_at, back.created_at);
        back.verify(&account.public()).expect("decoded credential still verifies");
    }

    #[test]
    fn merge_unions_self_registrations_from_two_devices() {
        let account = id(1);
        let dev_a = id(2).public().node_id_bytes();
        let dev_b = id(3).public().node_id_bytes();
        // Two iCloud-restored devices each self-register their own id off a common empty base.
        let base = DeviceList::signed(&account, 0, 0, vec![], vec![]);
        let a = base.with_self_added(dev_a, &account, 1).expect("a adds itself");
        let b = base.with_self_added(dev_b, &account, 1).expect("b adds itself");
        // A merges B's roster → union has BOTH devices (neither clobbers the other).
        let merged = a.merge(&b, &account, 2).expect("union changes membership");
        assert!(merged.is_authorized(&dev_a) && merged.is_authorized(&dev_b));
        merged.verify(&account.public()).expect("merged roster is validly account-signed");
        // Converged: merging the same rosters again is a no-op (no rotation storm).
        assert!(merged.merge(&a, &account, 3).is_none());
        assert!(merged.merge(&b, &account, 3).is_none());
    }

    #[test]
    fn merge_keeps_revocations_sticky() {
        let account = id(1);
        let dev_x = id(2).public().node_id_bytes();
        // One replica revoked X; another (stale) still lists X as active.
        let revoked_list = DeviceList::signed(&account, 5, 0, vec![], vec![dev_x]);
        let stale_active = DeviceList::signed(&account, 4, 0, vec![dev_x], vec![]);
        // The stale replica merging the revocation must DROP X, never resurrect it.
        let merged = stale_active.merge(&revoked_list, &account, 6).expect("stale picks up revocation");
        assert!(!merged.is_authorized(&dev_x));
        assert!(merged.revoked.contains(&dev_x) && !merged.devices.contains(&dev_x));
    }

    #[test]
    fn device_list_signs_verifies_and_gates_authorization() {
        let account = id(1);
        let phone = id(2).public().node_id_bytes();
        let mac = id(3).public().node_id_bytes();
        let lost = id(4).public().node_id_bytes();

        let list = DeviceList::signed(&account, 2, 100, vec![phone, mac], vec![lost]);
        list.verify(&account.public()).expect("valid list verifies");
        assert!(list.is_authorized(&phone));
        assert!(list.is_authorized(&mac));
        assert!(!list.is_authorized(&lost), "revoked device must not be authorized");
        let unknown = id(5).public().node_id_bytes();
        assert!(!list.is_authorized(&unknown), "unlisted device must not be authorized");
    }

    #[test]
    fn device_list_rejects_foreign_signer_and_tamper() {
        let account = id(1);
        let imposter = id(9);
        let phone = id(2).public().node_id_bytes();
        let mut list = DeviceList::signed(&account, 1, 0, vec![phone], vec![]);
        assert!(list.verify(&imposter.public()).is_err(), "foreign account must not verify");
        // Splice in an extra device without re-signing → must fail.
        list.devices.push(id(6).public().node_id_bytes());
        assert!(list.verify(&account.public()).is_err(), "tampered roster must not verify");
    }

    #[test]
    fn device_list_roundtrips_through_wire() {
        let account = id(1);
        let phone = id(2).public().node_id_bytes();
        let mac = id(3).public().node_id_bytes();
        let lost = id(4).public().node_id_bytes();
        let list = DeviceList::signed(&account, 5, 999, vec![phone, mac], vec![lost]);
        let back = DeviceList::from_bytes(&list.to_bytes()).expect("decode");
        assert_eq!(list, back);
        back.verify(&account.public()).expect("decoded list still verifies");
    }

    #[test]
    fn higher_version_wins_on_merge() {
        let account = id(1);
        let phone = id(2).public().node_id_bytes();
        let mac = id(3).public().node_id_bytes();
        let mut v1 = DeviceList::signed(&account, 1, 0, vec![phone], vec![]);
        let v3 = DeviceList::signed(&account, 3, 10, vec![phone, mac], vec![]);
        assert!(v1.adopt_if_newer(&v3), "newer version must be adopted");
        assert_eq!(v1.version, 3);
        assert!(v1.is_authorized(&mac));
        // An older replay must NOT be adopted (rollback defense).
        let stale = DeviceList::signed(&account, 2, 5, vec![phone], vec![mac]);
        assert!(!v1.adopt_if_newer(&stale));
        assert_eq!(v1.version, 3);
    }

    #[test]
    fn recipients_expand_to_authorized_devices_excluding_revoked() {
        let account = id(1);
        let phone = id(2);
        let mac = id(3);
        let stolen = id(4);
        let list = DeviceList::signed(
            &account, 2, 0,
            vec![phone.public().node_id_bytes(), mac.public().node_id_bytes()],
            vec![stolen.public().node_id_bytes()],
        );
        let creds = vec![
            DeviceCredential::issue(&account, &phone.public(), "phone", 1),
            DeviceCredential::issue(&account, &mac.public(), "mac", 1),
            DeviceCredential::issue(&account, &stolen.public(), "stolen", 1),
        ];
        let cd = ContactDevices { list, credentials: creds };
        let mut map = std::collections::HashMap::new();
        map.insert(account.public().node_id_bytes(), cd);

        let recips = recipients_with_devices(&[account.public()], &map);
        let ids: std::collections::HashSet<[u8; 32]> = recips.iter().map(|h| h.node_id_bytes()).collect();
        assert!(ids.contains(&phone.public().node_id_bytes()));
        assert!(ids.contains(&mac.public().node_id_bytes()));
        assert!(!ids.contains(&stolen.public().node_id_bytes()), "revoked device is not a recipient");
        // The account key is ALWAYS a recipient now, so any account-seed holder (the user's iCloud-synced
        // siblings) opens content robustly without waiting for full roster propagation. A revoked LINK-FLOW
        // device is still cut off: it's dropped above AND doesn't hold the account seed.
        assert!(ids.contains(&account.public().node_id_bytes()), "always seal to the account key (robust sibling open)");
    }

    #[test]
    fn no_device_info_falls_back_to_the_account_key() {
        let alice = id(5);
        let bob = id(6);
        let recips = recipients_with_devices(&[alice.public(), bob.public()], &std::collections::HashMap::new());
        let ids: std::collections::HashSet<[u8; 32]> = recips.iter().map(|h| h.node_id_bytes()).collect();
        assert!(ids.contains(&alice.public().node_id_bytes()));
        assert!(ids.contains(&bob.public().node_id_bytes()));
    }

    /// The end-to-end guarantee: a revoked device cannot open the circle's key commit, so it can decrypt
    /// nothing posted after revocation — exactly what "revoke a device" must mean.
    #[test]
    fn revoked_device_cannot_open_the_key_commit() {
        use crate::groupkey::{open_key_commit, seal_key_commit};
        let account = id(1);
        let phone = id(2);
        let stolen = id(4);
        let list = DeviceList::signed(
            &account, 2, 0,
            vec![phone.public().node_id_bytes()],
            vec![stolen.public().node_id_bytes()],
        );
        let creds = vec![
            DeviceCredential::issue(&account, &phone.public(), "phone", 1),
            DeviceCredential::issue(&account, &stolen.public(), "stolen", 1),
        ];
        let cd = ContactDevices { list, credentials: creds };
        let mut map = std::collections::HashMap::new();
        map.insert(account.public().node_id_bytes(), cd);
        let recips = recipients_with_devices(&[account.public()], &map);

        let committer = id(7);
        let epoch_key = [9u8; 32];
        let circle_secret = [7u8; 32];
        let commit = seal_key_commit(&committer, &recips, "circle", 1, &epoch_key, &circle_secret)
            .expect("seal");
        assert!(open_key_commit(&phone, &committer.public(), &commit).is_ok(),
                "authorized device opens the commit");
        assert!(open_key_commit(&stolen, &committer.public(), &commit).is_err(),
                "REVOKED device must not open the commit");
    }
}
