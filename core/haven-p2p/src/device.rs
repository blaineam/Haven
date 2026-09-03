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
use crate::social::{self, Group, SealedEnvelope};
use crate::{CoreError, Result};

/// Domain-separation tag for the bytes an account signs to issue a device credential.
const CRED_DOMAIN: &[u8] = b"haven-device-cred-v1";
/// Domain-separation tag for the bytes an account signs over a device list.
const LIST_DOMAIN: &[u8] = b"haven-device-list-v1";

/// Domain-separation tail folded into a [`DeviceList`]'s signed preimage **only** when the account has
/// retired its bare account-id leaf (migration path, docs/SWITCH-FLIP-1.0.7.md §1). Appended solely in
/// the retired case, so a NON-retired list's signed bytes — and therefore its signature — are
/// byte-for-byte identical to a pre-1.0.7 roster (legacy sigs keep verifying; the account leaf is
/// dropped ONLY via this signed flag, NEVER by its absence).
const LEAF_RETIRE_DOMAIN: &[u8] = b"haven-device-list-acct-leaf-retired-v1";

/// Wire suffix that marks a serialized [`DeviceList`] as carrying the account-leaf-retired flag.
/// Appended AFTER the signature and present ONLY when retired. Rationale for this framing:
///   * A NON-retired list has no suffix, so [`DeviceList::to_bytes`] stays byte-identical to today
///     (the roster byte-equality the FFI tests assert, and legacy on-wire compatibility).
///   * A pre-1.0.7 decoder reads the signature as the trailing bytes (`sig = rest()`), so this suffix
///     folds into its `sig` and verification fails — the legacy peer simply REJECTS the retired roster
///     and keeps the account's PRIOR ({account, device}) roster (higher-version-wins). That is safe: a
///     circle containing a legacy peer is never fully seed-drop-capable, so the account leaf is never
///     dropped for anyone regardless.
///   * A 1.0.7 decoder recognizes the suffix, sets the flag, and verifies the signature over the exact
///     retired preimage the signer used. A ~2^-64 chance that a non-retired signature happens to END in
///     these 8 bytes is fail-closed: the decoder would set retired=true, verify() would recompute the
///     retired preimage over a truncated sig and reject the list — never a false authorization.
const LEAF_RETIRE_WIRE_SUFFIX: &[u8; 8] = b"HVNLEAF1";

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
        let mut r = Reader::new(b, WIRE);
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
    /// **Account-leaf retirement** (migration path, docs/SWITCH-FLIP-1.0.7.md §1). A POSITIVE,
    /// account-signed, sticky-by-version fact: the bare account-id leaf is no longer an authorized
    /// recipient/leaf (its DEVICE leaves remain — `devices` is untouched, grow-only). When set,
    /// [`Self::is_authorized`] returns false for `account_id`, so both the tree-leaf set and the
    /// device-only sealing set shed the bare account, letting an already-multi-device upgrader reach the
    /// device-only roster shape live MLS keying + retirement require. Governed EXACTLY like the
    /// `revoked` set's stickiness: it can only be LEARNED (via a higher-version account-signed list),
    /// never inferred from absence — a legacy roster has it `false`, and a stale roster can never
    /// resurrect the account leaf (`merge` unions it; `adopt_if_newer` is version-monotone). The account
    /// leaf is dropped ONLY via this signed flag, NEVER by absence.
    pub account_leaf_retired: bool,
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
        account_leaf_retired: bool,
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
        // The retirement tail is folded in ONLY when set — so a non-retired list's preimage (and thus
        // its signature) is byte-identical to a pre-1.0.7 roster's. Absence of the tail is never
        // "retired"; the account leaf is dropped ONLY via this positive, signed flag.
        if account_leaf_retired {
            v.extend_from_slice(LEAF_RETIRE_DOMAIN);
        }
        v
    }

    /// Build and sign a NON-retired device list with the account identity (byte-identical to the
    /// pre-1.0.7 constructor — every existing caller keeps producing the exact same bytes).
    pub fn signed(
        account: &Identity,
        version: u64,
        updated_at: u64,
        devices: Vec<[u8; 32]>,
        revoked: Vec<[u8; 32]>,
    ) -> Self {
        Self::signed_inner(account, version, updated_at, devices, revoked, false)
    }

    /// Build and sign a device list, choosing whether the account-leaf-retired flag is set. The public
    /// [`Self::signed`] delegates here with `false`; retirement mints its list via
    /// [`Self::with_account_leaf_retired`], which passes `true`.
    fn signed_inner(
        account: &Identity,
        version: u64,
        updated_at: u64,
        devices: Vec<[u8; 32]>,
        revoked: Vec<[u8; 32]>,
        account_leaf_retired: bool,
    ) -> Self {
        let account_id = account.public().node_id_bytes();
        let msg = Self::signing_bytes(&account_id, version, updated_at, &devices, &revoked, account_leaf_retired);
        let sig = account.sign(&msg);
        Self { account_id, version, updated_at, devices, revoked, account_leaf_retired, sig }
    }

    /// Verify the list against the pinned account key (id match + hybrid signature). The signed preimage
    /// includes the retirement tail iff the flag is set, so a tampered flag (flipped either way without
    /// the account re-signing) fails here.
    pub fn verify(&self, account_pub: &HavenId) -> Result<()> {
        if account_pub.node_id_bytes() != self.account_id {
            return Err(CoreError::Crypto("device list: account id mismatch"));
        }
        let msg = Self::signing_bytes(
            &self.account_id,
            self.version,
            self.updated_at,
            &self.devices,
            &self.revoked,
            self.account_leaf_retired,
        );
        account_pub.verify(&msg, &self.sig)
    }

    /// Is `device_id` currently authorized? (present and not revoked). Once the account has SIGNED the
    /// account-leaf retirement, the bare account id is no longer authorized — its DEVICE leaves remain.
    /// The account leaf is dropped ONLY via this signed higher-version flag, NEVER by absence.
    pub fn is_authorized(&self, device_id: &[u8; 32]) -> bool {
        if self.account_leaf_retired && device_id == &self.account_id {
            return false;
        }
        !self.revoked.contains(device_id) && self.devices.contains(device_id)
    }

    /// Merge rule across devices/replicas: **higher `version` wins**. Returns `true` if
    /// `other` is newer and was adopted. Both must already be `verify()`-ed by the caller.
    ///
    /// This carries the account-leaf-retired flag along in the adopted (strictly-newer, account-signed)
    /// clone, and it is the rollback defense for retirement: a stale roster (version ≤ ours) is refused,
    /// so a copy that still authorizes the account leaf can never DOWNGRADE a retired one back. (The
    /// account only ever retires forward at a higher version, so no un-retire clone exists to adopt.)
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
        // Account-leaf retirement is STICKY exactly like a revocation: once EITHER copy has retired the
        // bare account leaf, the union keeps it retired. A stale (older) roster that still authorizes the
        // account leaf can therefore never resurrect it through a merge — the same "revoked only grows"
        // discipline, extended to this one flag. (It only ever goes false→true; the account never
        // un-retires, so there is no un-retire branch to get wrong.)
        let account_leaf_retired = self.account_leaf_retired || other.account_leaf_retired;
        // No membership change AND no retirement change → don't churn a new signed version (idempotent
        // convergence). Retirement is part of "membership" here: flipping it on IS a change worth signing.
        let mut cur_dev = self.devices.clone();
        cur_dev.sort_unstable();
        let mut cur_rev = self.revoked.clone();
        cur_rev.sort_unstable();
        if devices == cur_dev && revoked == cur_rev && account_leaf_retired == self.account_leaf_retired {
            return None;
        }
        let version = self.version.max(other.version) + 1;
        Some(DeviceList::signed_inner(account, version, updated_at, devices, revoked, account_leaf_retired))
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
        // Retirement is STICKY across a self-registration: adding another device must NOT un-retire the
        // account leaf (that would silently re-open the bare account as a recipient). Carry it forward.
        Some(DeviceList::signed_inner(account, self.version + 1, updated_at, devices, revoked, self.account_leaf_retired))
    }

    /// Re-sign this roster with the **account-leaf-retired** flag SET, bumping the version. The bare
    /// account id stays in `devices` (grow-only device set is untouched) but stops being *authorized* —
    /// so the roster settles at the DEVICE-ONLY shape that live MLS keying + seed-drop retirement need,
    /// letting an already-multi-device upgrader migrate (docs/SWITCH-FLIP-1.0.7.md §1). Returns `None`
    /// when already retired — the flag is monotone/sticky, so re-retiring is a no-op (no needless
    /// version bump / epoch rotation). Only the account key can produce this (the account signs it), so
    /// a device that lacks the account seed can never mint it — roster authority is unchanged.
    pub fn with_account_leaf_retired(&self, account: &Identity, updated_at: u64) -> Option<DeviceList> {
        if self.account_leaf_retired {
            return None;
        }
        Some(DeviceList::signed_inner(
            account,
            self.version + 1,
            updated_at,
            self.devices.clone(),
            self.revoked.clone(),
            true,
        ))
    }

    /// Wire encoding: `account_id(32) ‖ version(8) ‖ updated_at(8) ‖ n_dev(4) ‖ dev*32 ‖
    /// n_rev(4) ‖ rev*32 ‖ sig` — and, ONLY when the account leaf is retired, a trailing
    /// [`LEAF_RETIRE_WIRE_SUFFIX`]. A non-retired list is thus byte-for-byte identical to a pre-1.0.7
    /// roster (the account leaf is carried ONLY as a positive suffix, never inferred from its absence).
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
        if self.account_leaf_retired {
            v.extend_from_slice(LEAF_RETIRE_WIRE_SUFFIX);
        }
        v
    }

    /// Inverse of [`Self::to_bytes`]. The OPTIONAL account-leaf-retired suffix is detected FIRST, off the
    /// tail: present ⇒ retired (a positive signal); absent ⇒ not retired (never inferred as a downgrade).
    /// A legacy encoder never appends it, so a legacy roster decodes with `account_leaf_retired = false`.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let (body, account_leaf_retired) = if b.len() >= LEAF_RETIRE_WIRE_SUFFIX.len()
            && &b[b.len() - LEAF_RETIRE_WIRE_SUFFIX.len()..] == LEAF_RETIRE_WIRE_SUFFIX.as_slice()
        {
            (&b[..b.len() - LEAF_RETIRE_WIRE_SUFFIX.len()], true)
        } else {
            (b, false)
        };
        let mut r = Reader::new(body, WIRE);
        let account_id = r.array32()?;
        let version = r.u64()?;
        let updated_at = r.u64()?;
        // UNTRUSTED COUNTS. `with_capacity(n)` reserves 32·n bytes BEFORE a single entry is read,
        // so a 4-byte wire field could ask for 137 GB; the allocator fails and the process ABORTS
        // rather than returning an error. Rosters arrive from peers, so that is a remote DoS — one
        // crafted blob kills the app, and no `Result` ever comes back to reject it. Found by
        // `tests/fuzz_wire_parsers.rs` on Linux CI (a 114 GB reservation); macOS had masked it,
        // because an over-large mapping that is never touched succeeds there.
        //
        // Every entry is exactly 32 bytes, so a count the remaining buffer cannot possibly hold is
        // malformed by definition — reject it before reserving anything. The loop below would have
        // failed on its first short read; the point is to get there without allocating first.
        let n_dev = r.u32()? as usize;
        if n_dev > r.rest().len() / 32 {
            return Err(CoreError::Encoding("device list: device count exceeds remaining input"));
        }
        let mut devices = Vec::with_capacity(n_dev);
        for _ in 0..n_dev {
            devices.push(r.array32()?);
        }
        let n_rev = r.u32()? as usize;
        if n_rev > r.rest().len() / 32 {
            return Err(CoreError::Encoding("device list: revoked count exceeds remaining input"));
        }
        let mut revoked = Vec::with_capacity(n_rev);
        for _ in 0..n_rev {
            revoked.push(r.array32()?);
        }
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("device list: missing signature"));
        }
        Ok(Self { account_id, version, updated_at, devices, revoked, account_leaf_retired, sig })
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
        // PLUS each currently-authorized device bundle, so a LINK-FLOW device can also open.
        //
        // ⚠️ This is the LEGACY DUAL-SEAL path, and it is the compatibility fallback as of 1.0.7 — not
        // the live one. Because it always seals to the bare account key above, dropping a device from
        // here closes only the device-key path: revocation still cuts off a device that does NOT hold
        // the account seed, and is advisory against one whose seed was extracted. The live path is
        // [`recipients_with_devices_gated`], which retires the bare account-key seal once the retirement
        // switch is ON *and* every member affirmatively advertises seed-drop capability — that makes
        // revocation a cryptographic cut even against a seed-holding member. A circle with even one
        // un-upgraded member falls back to this function so everyone keeps reading, which is exactly
        // what the gate is for (`docs/SWITCH-FLIP-1.0.7.md`). Seedless enrollment ships on all four
        // clients: a device linked that way holds only its device key + credential and never receives
        // the master seed. See MULTI-DEVICE.md and SEED-DROP-DESIGN.md.
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

/// Resolve a **sender/committer device id** to the account it is authorized to act for, plus that
/// device's routable public bundle (seed-drop S3, D16 Phase 2 §4.2).
///
/// Scans the caller's verified `devices_by_account` — each entry's [`DeviceList`] and
/// [`DeviceCredential`]s were checked against the contact's *pinned account key* at ingest — and returns
/// `(account_id, device_bundle)` for the first account whose roster currently **authorizes** `device_id`
/// (present, not revoked) and carries its credential. This is the **sender-authorization oracle** the
/// receive side uses to (a) obtain the device's public bundle to verify a device-signed envelope's
/// hybrid signature, and (b) compute the `expected_author` account for
/// [`crate::groupkey::open_event_in_epoch_authored`] and to resolve the committer of a device-signed
/// [`crate::groupkey::open_key_commit`]. Returns `None` for a device in no known roster — so a device the
/// account never authorized (or one it revoked) can never be treated as an authorized sender.
pub fn author_and_bundle_for_device(
    device_id: &[u8; 32],
    devices_by_account: &std::collections::HashMap<[u8; 32], ContactDevices>,
) -> Option<([u8; 32], HavenId)> {
    for (account_id, cd) in devices_by_account {
        if cd.list.is_authorized(device_id) {
            if let Some(cred) = cd.credentials.iter().find(|c| &c.device_id() == device_id) {
                return Some((*account_id, cred.device.clone()));
            }
        }
    }
    None
}

// ── Seed-drop S0: capability negotiation + dual-seal gating scaffold (D16 Phase 2) ───────────────
//
// These are STRICTLY ADDITIVE and shipped OFF: nothing here changes who signs or what a circle seals
// to in this release. They land the rails that a later release flips on. See docs/SEED-DROP-DESIGN.md.

/// Domain-separation tag for the bytes an account signs over a seed-drop capability marker.
const CAP_DOMAIN: &[u8] = b"haven-seeddrop-cap-v1";

/// A monotonic, account-signed **seed-drop capability marker** (S0). It advertises the seed-drop
/// protocol version a peer supports so contacts can NEGOTIATE the graceful migration.
///
/// It is **signed by the account key** so a relay can neither forge it (falsely claim a legacy account
/// is capable) nor strip it from a signed container undetectably. Critically, a **missing** marker
/// always means "unknown — treat as legacy," NEVER "downgraded/removed": absence is never information
/// (this codebase has been bitten by absence-as-removal more than once). Capability is monotonic — it is
/// only ever *learned*, never inferred-absent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeedDropCapability {
    /// The advertising account's 32-byte node id.
    pub account_id: [u8; 32],
    /// Seed-drop protocol version supported (>= 1). 0 is reserved for "no marker / legacy".
    pub version: u32,
    /// Hybrid signature by the **account** identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl SeedDropCapability {
    fn signing_bytes(account_id: &[u8; 32], version: u32) -> Vec<u8> {
        let mut v = Vec::with_capacity(CAP_DOMAIN.len() + 32 + 4);
        v.extend_from_slice(CAP_DOMAIN);
        v.extend_from_slice(account_id);
        v.extend_from_slice(&version.to_le_bytes());
        v
    }

    /// Issue a signed capability marker for `version` (>= 1) under the account identity.
    pub fn issue(account: &Identity, version: u32) -> Self {
        let account_id = account.public().node_id_bytes();
        let sig = account.sign(&Self::signing_bytes(&account_id, version));
        Self { account_id, version, sig }
    }

    /// Verify against the **pinned account key** (id match + hybrid signature). A forged or tampered
    /// marker fails here; a caller then treats the account as legacy (absence-safe).
    pub fn verify(&self, account_pub: &HavenId) -> Result<()> {
        if account_pub.node_id_bytes() != self.account_id {
            return Err(CoreError::Crypto("seed-drop capability: account id mismatch"));
        }
        account_pub.verify(&Self::signing_bytes(&self.account_id, self.version), &self.sig)
    }

    /// Wire encoding: `account_id(32) ‖ version(4 LE) ‖ sig`. Designed to be appended as a TRAILER after
    /// an existing roster body — an older client stops parsing at the end of the credentials and never
    /// reads these bytes, so carrying it is additive (a 1.0.4 peer ignores it).
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(32 + 4 + self.sig.len());
        v.extend_from_slice(&self.account_id);
        v.extend_from_slice(&self.version.to_le_bytes());
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`]. Returns `None` on a short/empty buffer (no marker present).
    pub fn from_bytes(b: &[u8]) -> Option<Self> {
        if b.len() < 32 + 4 + 1 {
            return None; // need id + version + a non-empty signature
        }
        let account_id: [u8; 32] = b[..32].try_into().ok()?;
        let version = u32::from_le_bytes(b[32..36].try_into().ok()?);
        let sig = b[36..].to_vec();
        Some(Self { account_id, version, sig })
    }
}

/// Domain-separation group id for a self-sync key grant (seed-drop S2). Never a real circle id.
const SELF_SYNC_GRANT_GROUP: &str = "haven-self-sync-grant-v1";

/// Seal the account's 32-byte `self_sync_key` to a **seedless device's bundle** (seed-drop S2, D16
/// Phase 2, §4.3).
///
/// A device that no longer holds the master seed cannot *derive* `self_sync_key`
/// ([`Identity::self_sync_key`]) and so could not participate in account-state self-sync (the
/// profile / contacts / settings / circles / pins convergence that makes "my devices show the same
/// thing" work). Instead the **primary** (the seed-holder) grants the key: it KEM-wraps the 32 bytes to
/// the device's published bundle over the exact same hybrid, PQ-preserving rail as an epoch
/// [`crate::groupkey::seal_key_commit`], signed by the account so the device can verify provenance
/// against its pinned account key.
///
/// The key is unchanged and identical across devices, so convergence is untouched — only its
/// *provenance on the granted device* changes from "derived from the seed" to "granted by the primary".
/// The device opens it with [`open_self_sync_key`] and stores the 32 bytes. No new crypto: this is the
/// same `seal_bytes`-to-device-bundle mechanism the epoch KeyCommit already uses.
pub fn seal_self_sync_key(
    account: &Identity,
    device_bundle: &HavenId,
    self_sync_key: &[u8; 32],
) -> Result<SealedEnvelope> {
    let group = Group::new(SELF_SYNC_GRANT_GROUP, vec![device_bundle.clone()]);
    social::seal_bytes(account, &group, self_sync_key)
}

/// Open the self-sync key granted to this device's bundle by [`seal_self_sync_key`], verifying the
/// granting account's hybrid signature against its pinned public bundle. Returns the 32-byte key, to be
/// stored and used with `seal_account_state` / `open_account_state` in place of a seed derivation. A
/// grant sealed to a different device (or a tampered/forged one) fails here.
pub fn open_self_sync_key(
    device: &Identity,
    account_pub: &HavenId,
    env: &SealedEnvelope,
) -> Result<[u8; 32]> {
    let bytes = social::open_bytes(device, account_pub, env)?;
    <[u8; 32]>::try_from(bytes.as_slice())
        .map_err(|_| CoreError::Encoding("self-sync grant must be exactly 32 bytes"))
}

/// Seal a ROTATED self-sync key to a device bundle AT a specific key-epoch (audit M1 rotation).
///
/// Same hybrid-KEM-to-device-bundle rail as [`seal_self_sync_key`], but the sealed payload carries the
/// KEY-EPOCH alongside the 32 bytes: `epoch(8 LE) ‖ key(32)`. On a revocation the primary mints a fresh
/// key, bumps the epoch, and re-grants it (this call) to every STILL-authorized device only — so a
/// device learns *which* rotated key it holds and reads/writes account state under it
/// ([`crate::selfsync::AccountState::seal_epoch`]/[`open_any`](crate::selfsync::AccountState::open_any)).
/// A revoked device is never a recipient of the new grant, so it retains only the stale key and is cut
/// off. Account-signed for provenance, exactly like the epoch-0 grant.
pub fn seal_self_sync_key_epoch(
    account: &Identity,
    device_bundle: &HavenId,
    epoch: u64,
    self_sync_key: &[u8; 32],
) -> Result<SealedEnvelope> {
    let mut payload = Vec::with_capacity(8 + 32);
    payload.extend_from_slice(&epoch.to_le_bytes());
    payload.extend_from_slice(self_sync_key);
    let group = Group::new(SELF_SYNC_GRANT_GROUP, vec![device_bundle.clone()]);
    social::seal_bytes(account, &group, &payload)
}

/// Open an epoch-tagged self-sync key grant from [`seal_self_sync_key_epoch`], verifying the granting
/// account's signature. Returns `(epoch, key)`. A grant sealed to another device (or tampered/forged)
/// fails here; a wrong-length payload is rejected (fail-closed).
pub fn open_self_sync_key_epoch(
    device: &Identity,
    account_pub: &HavenId,
    env: &SealedEnvelope,
) -> Result<(u64, [u8; 32])> {
    let bytes = social::open_bytes(device, account_pub, env)?;
    if bytes.len() != 8 + 32 {
        return Err(CoreError::Encoding("self-sync epoch grant must be exactly 40 bytes"));
    }
    let epoch = u64::from_le_bytes(bytes[..8].try_into().unwrap());
    let key: [u8; 32] = bytes[8..40].try_into().unwrap();
    Ok((epoch, key))
}

/// Is EVERY member of a circle seed-drop-capable? An **all-present positive** signal (never
/// absence-inferred): true only when every member account both appears in `capable` (we have
/// affirmatively verified its signed marker) AND has a known device roster. A single member we have not
/// seen capability from keeps the whole circle NOT-fully-capable, so the legacy account-key seal is
/// retained. This is the computation [`recipients_with_devices_gated`] consults before retiring the
/// account-key seal for a circle — LIVE since 1.0.7, so a circle flips to device-only sealing exactly
/// when this turns true, and falls back the moment a member we cannot vouch for is present.
pub fn circle_fully_seed_drop_capable(
    members: &[HavenId],
    devices_by_account: &std::collections::HashMap<[u8; 32], ContactDevices>,
    capable: &std::collections::HashSet<[u8; 32]>,
) -> bool {
    !members.is_empty()
        && members.iter().all(|m| {
            let a = m.node_id_bytes();
            capable.contains(&a) && devices_by_account.contains_key(&a)
        })
}

/// Is EVERY member of a circle able to READ the compact binary envelope container?
/// (`docs/SATELLITE-DESIGN.md` §6, stage S0 write-side.)
///
/// The same **all-present positive** computation as [`circle_fully_seed_drop_capable`], and the same
/// reading of silence: a member missing from `capable` is legacy, never downgraded, so a single
/// unknown member keeps the whole circle on the JSON container. That asymmetry is the safety
/// property — emitting the compact container to a client that cannot parse it costs that client the
/// message, and there is no negotiation to fall back to after the bytes are in the mailbox.
///
/// Deliberately NOT composed with seed-drop or device-roster capability: reading a container is a
/// property of the app build, not of key management, and requiring a roster would keep every legacy
/// circle on the wasteful encoding forever for no safety gain.
///
/// The known limitation, stated rather than hidden: the marker is an ACCOUNT claim carried in the
/// account-signed profile card, so an account whose devices straddle an upgrade can advertise from a
/// new device while an old one is still on JSON-only. That stale device errors the envelope per
/// envelope and misses the message; it does not corrupt anything. This is the identical exposure the
/// shipped `sd` and `ml` markers already carry, and it closes as the fleet converges.
pub fn circle_fully_compact_wire_capable(
    members: &[HavenId],
    capable: &std::collections::HashSet<[u8; 32]>,
) -> bool {
    !members.is_empty() && members.iter().all(|m| capable.contains(&m.node_id_bytes()))
}

/// Is EVERY member of a circle MLS(TreeKEM)-capable? (TreeKEM M0, `docs/TREEKEM-DESIGN.md` §7.2.)
///
/// The same **all-present positive** computation as [`circle_fully_seed_drop_capable`], composed
/// with it: MLS capability is NESTED inside seed-drop capability (`ml` v1 requires seed-drop v1 —
/// leaves *are* device keys, so a circle can only run TreeKEM if it could already retire the bare
/// account key). A member therefore counts only when we have affirmatively verified its signed
/// marker in BOTH capable sets AND hold its device roster; a single member missing from either set
/// (or roster-less) keeps the whole circle NOT-fully-capable — absence is never information, so a
/// missing marker means "legacy," never "downgraded." Consumed in production since 1.0.7: the author
/// path reaches this through `circle_is_mls_capable`, and with the `mls_keying` switch ON (every
/// client sets it at launch) a circle keys under the tree only when this is true, keeping legacy
/// epoch keying otherwise.
pub fn circle_fully_mls_capable(
    members: &[HavenId],
    devices_by_account: &std::collections::HashMap<[u8; 32], ContactDevices>,
    seed_drop_capable: &std::collections::HashSet<[u8; 32]>,
    mls_capable: &std::collections::HashSet<[u8; 32]>,
) -> bool {
    circle_fully_seed_drop_capable(members, devices_by_account, seed_drop_capable)
        && members.iter().all(|m| mls_capable.contains(&m.node_id_bytes()))
}

/// [`recipients_with_devices`] with the seed-drop dual-seal **gate** wired — the LIVE production sealing
/// path since 1.0.7. When `drop_account_key` is set AND the circle is fully seed-drop-capable, the bare
/// per-member account key is omitted so content seals ONLY to authorized device bundles (a revoked device
/// is then cut off cryptographically, even from a seed-holding member). Production passes
/// `drop_account_key = true`: every client re-applies the retirement switch at launch on a primary device
/// (`set_seed_drop_retire`; a seedless device holds no bare account key to retire). With
/// `drop_account_key = false`, or on a circle that is not fully capable, this is **byte-identical** to
/// [`recipients_with_devices`]: nothing is dropped, dual-seal (account key + device bundles) stays in
/// place, and a mixed-version circle keeps reading. The gate — not the caller — decides when the new path
/// activates, which is what makes shipping the switch ON safe (`docs/SWITCH-FLIP-1.0.7.md`).
pub fn recipients_with_devices_gated(
    members: &[HavenId],
    devices_by_account: &std::collections::HashMap<[u8; 32], ContactDevices>,
    capable: &std::collections::HashSet<[u8; 32]>,
    drop_account_key: bool,
) -> Vec<HavenId> {
    let drop = drop_account_key && circle_fully_seed_drop_capable(members, devices_by_account, capable);
    if !drop {
        // Gate closed (switch off, or a member not affirmatively capable): unchanged dual-seal.
        return recipients_with_devices(members, devices_by_account);
    }
    // Fully capable + gate ON: seal ONLY to authorized device bundles, no bare account key.
    let mut out: Vec<HavenId> = Vec::new();
    let mut seen: std::collections::HashSet<[u8; 32]> = std::collections::HashSet::new();
    for m in members {
        if let Some(d) = devices_by_account.get(&m.node_id_bytes()) {
            for b in d.authorized_bundles() {
                if seen.insert(b.node_id_bytes()) {
                    out.push(b);
                }
            }
        }
    }
    out
}

// ── MLS M3: circle admin authority (docs/TREEKEM-DESIGN.md §4.3) ─────────────────────────────────
//
// Circles have no owner today; MLS Remove is the first operation that needs one. The LOCKED decision:
// only a circle's CREATOR and CREATOR-delegated admins may remove a member. This is a minimal,
// signed, tamper-proof authority model built on the SAME account-key signing + higher-version-wins +
// absence-is-never-information discipline as `DeviceList` / `SeedDropCapability`. It holds NO one
// else's keys — an admin only signs authority records and authors tree commits (the Kith mandate):
// authority never becomes a key-escrow or a decryption bypass.
//
// Trust root: the creator is PINNED per circle (a bare 32-byte account id agreed out of band /
// carried on the roster lane, exactly like a member id). Admins are delegated by GRANTS: a grant is
// "grantor G says account X is admin of circle C at version V", account-signed by G. An account is an
// admin iff it is the creator OR it is reachable from the creator by a chain of VERIFIED grants
// (`admin_closure`) — so a grant whose grantor is not itself an admin injects nothing, even if its
// signature is perfectly valid for some non-authoritative signer. Grants are versioned per
// (circle, admin) and rollback-defended (`adopt_if_newer`), like the roster.

/// Domain-separation tag for the bytes an account signs to issue a circle admin grant.
const ADMIN_DOMAIN: &[u8] = b"haven-circle-admin-v1";

/// Domain for the creator commitment embedded in an **owned** circle id.
const CIRCLE_CREATOR_DOMAIN: &[u8] = b"haven-circle-creator-v1";
/// Prefix that marks a circle id as **creator-bound** (owned). A legacy/ownerless circle id
/// (`default`, `dm:…`, a bare UUID) never carries it, and is treated as having no cryptographic
/// creator — its removal authority uses the legacy (roster/block) path.
pub const OWNED_CIRCLE_PREFIX: &str = "c1";

/// The 16-byte one-way commitment to a circle's creator: `blake3(DOMAIN ‖ creator)[..16]`.
/// It reveals nothing about the creator, but a holder of a claimed creator can verify the binding.
fn circle_creator_tag(creator: &[u8; 32]) -> [u8; 16] {
    let mut h = blake3::Hasher::new();
    h.update(CIRCLE_CREATOR_DOMAIN);
    h.update(creator);
    let mut tag = [0u8; 16];
    tag.copy_from_slice(&h.finalize().as_bytes()[..16]);
    tag
}

/// Mint a **creator-bound** circle id: `c1 ‖ base32( creator_tag(16) ‖ random(16) )`.
/// The id cryptographically commits to `creator`, so a member establishes the circle's creator by
/// verifying it against the id itself rather than accepting an unauthenticated claim. Only the
/// account the id commits to can be its creator. The random tail keeps two circles the same account
/// creates distinct.
pub fn mint_owned_circle_id(creator: &[u8; 32]) -> String {
    use rand::RngCore;
    let mut raw = [0u8; 32];
    raw[..16].copy_from_slice(&circle_creator_tag(creator));
    rand::rngs::OsRng.fill_bytes(&mut raw[16..]);
    format!("{OWNED_CIRCLE_PREFIX}{}", data_encoding::BASE32_NOPAD.encode(&raw))
}

/// Does `circle_id` cryptographically bind to `creator`? True only for an owned (`c1…`) id whose
/// embedded tag equals `circle_creator_tag(creator)`. A legacy/ownerless id always returns false —
/// callers must treat that as "no authenticated creator" (never as "trust the claim").
pub fn circle_id_binds_creator(circle_id: &str, creator: &[u8; 32]) -> bool {
    let Some(rest) = circle_id.strip_prefix(OWNED_CIRCLE_PREFIX) else { return false };
    let Ok(raw) = data_encoding::BASE32_NOPAD.decode(rest.as_bytes()) else { return false };
    raw.len() == 32 && raw[..16] == circle_creator_tag(creator)
}

/// A monotonic, account-signed **circle admin grant** (§4.3). "Grantor G delegates admin of circle
/// C to account X at version V." Signed by the GRANTOR's account key so a relay can neither forge it
/// nor strip it undetectably; a receiver only turns it into authority if the grantor is itself the
/// creator or an already-established admin (`admin_closure`). Carries the pinned `creator` so a
/// receiver can bind the grant to a specific authority root (a grant naming a different creator is
/// for a different authority chain and is ignored).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdminGrant {
    /// The circle this grant applies to (its id bytes).
    pub circle_id: Vec<u8>,
    /// The PINNED creator = the root of authority this grant chains under.
    pub creator: [u8; 32],
    /// The account being granted admin.
    pub admin_account: [u8; 32],
    /// Monotonic version per (circle, admin_account) — higher wins (rollback defense).
    pub version: u64,
    /// The account that signed this grant (must be the creator or a current admin to have effect).
    pub grantor_account: [u8; 32],
    /// Hybrid signature by the GRANTOR's account identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl AdminGrant {
    fn signing_bytes(
        circle_id: &[u8],
        creator: &[u8; 32],
        admin_account: &[u8; 32],
        version: u64,
        grantor_account: &[u8; 32],
    ) -> Vec<u8> {
        let mut v = Vec::with_capacity(ADMIN_DOMAIN.len() + 4 + circle_id.len() + 32 + 32 + 8 + 32);
        v.extend_from_slice(ADMIN_DOMAIN);
        v.extend_from_slice(&(circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(circle_id);
        v.extend_from_slice(creator);
        v.extend_from_slice(admin_account);
        v.extend_from_slice(&version.to_le_bytes());
        v.extend_from_slice(grantor_account);
        v
    }

    /// Issue a signed grant under the `grantor` account identity. The caller is responsible for the
    /// grantor actually being an admin (the receiver re-checks that via `admin_closure`; a grant from
    /// a non-admin simply contributes no authority).
    pub fn issue(
        grantor: &Identity,
        circle_id: &[u8],
        creator: [u8; 32],
        admin_account: [u8; 32],
        version: u64,
    ) -> Self {
        let grantor_account = grantor.public().node_id_bytes();
        let sig = grantor.sign(&Self::signing_bytes(circle_id, &creator, &admin_account, version, &grantor_account));
        Self { circle_id: circle_id.to_vec(), creator, admin_account, version, grantor_account, sig }
    }

    /// Verify the grant against the grantor's pinned account bundle (id match + hybrid signature). A
    /// forged or tampered grant fails here and is dropped; a caller then treats it as no authority.
    pub fn verify(&self, grantor_pub: &HavenId) -> Result<()> {
        if grantor_pub.node_id_bytes() != self.grantor_account {
            return Err(CoreError::Crypto("admin grant: grantor id mismatch"));
        }
        let msg = Self::signing_bytes(&self.circle_id, &self.creator, &self.admin_account, self.version, &self.grantor_account);
        grantor_pub.verify(&msg, &self.sig)
    }

    /// Higher-version-wins replace for the same (circle, admin_account, creator) key. Returns `true`
    /// if `other` is strictly newer and was adopted. Both must already be `verify()`-ed by the caller.
    pub fn adopt_if_newer(&mut self, other: &AdminGrant) -> bool {
        if other.circle_id == self.circle_id
            && other.creator == self.creator
            && other.admin_account == self.admin_account
            && other.version > self.version
        {
            *self = other.clone();
            true
        } else {
            false
        }
    }

    /// Wire: `lp(circle_id) ‖ creator(32) ‖ admin_account(32) ‖ version(8) ‖ grantor(32) ‖ sig`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(4 + self.circle_id.len() + 32 + 32 + 8 + 32 + self.sig.len());
        v.extend_from_slice(&(self.circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(&self.circle_id);
        v.extend_from_slice(&self.creator);
        v.extend_from_slice(&self.admin_account);
        v.extend_from_slice(&self.version.to_le_bytes());
        v.extend_from_slice(&self.grantor_account);
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b, WIRE);
        let circle_id = r.bytes_lp()?.to_vec();
        let creator = r.array32()?;
        let admin_account = r.array32()?;
        let version = r.u64()?;
        let grantor_account = r.array32()?;
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("admin grant: missing signature"));
        }
        Ok(Self { circle_id, creator, admin_account, version, grantor_account, sig })
    }
}

const UPGRADE_DOMAIN: &[u8] = b"haven-circle-upgrade-v1";

/// An account-signed offer to carry a **legacy** circle onto a creator-bound **successor**.
///
/// Legacy circle ids (`default`, `dm:…`, a bare pre-1.0.7 id) are neither globally unique nor bound
/// to anyone, so they can't be a sound shared group: there is no authority root, which means no
/// authenticated eviction. A circle can't gain one in place — nothing in existing state records who
/// created it — so the owner instead offers a **successor** whose id commits to them
/// (`mint_owned_circle_id`), and each member decides whether to follow.
///
/// What the signature proves and what it does NOT: `verify` proves the offer really came from
/// `creator` and wasn't tampered with, and a receiver additionally checks `new_circle_id` binds
/// `creator`. Neither fact establishes that `creator` owned the LEGACY circle — nothing can, because
/// legacy circles never had an owner. That last step is a human one: a receiver MUST surface the
/// offer for confirmation and must never adopt it automatically. Two members can each sign a valid,
/// competing offer for the same legacy circle; both are legitimate records and the user picks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CircleUpgrade {
    /// The legacy circle being upgraded (its id bytes, as this member knows it).
    pub legacy_circle_id: Vec<u8>,
    /// The creator-bound successor id (`c1…`) — MUST bind `creator`; a receiver re-checks.
    pub new_circle_id: Vec<u8>,
    /// The account offering the upgrade, and the successor's cryptographic creator.
    pub creator: [u8; 32],
    /// Display name to carry over, so a member can show a meaningful prompt before accepting.
    pub name: String,
    /// Monotonic per (legacy_circle_id, creator) — higher wins, so a re-offer supersedes.
    pub version: u64,
    /// Hybrid signature by `creator`'s account identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl CircleUpgrade {
    fn signing_bytes(
        legacy_circle_id: &[u8],
        new_circle_id: &[u8],
        creator: &[u8; 32],
        name: &str,
        version: u64,
    ) -> Vec<u8> {
        let mut v = Vec::with_capacity(UPGRADE_DOMAIN.len() + 12 + legacy_circle_id.len() + new_circle_id.len() + name.len() + 32 + 8);
        v.extend_from_slice(UPGRADE_DOMAIN);
        v.extend_from_slice(&(legacy_circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(legacy_circle_id);
        v.extend_from_slice(&(new_circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(new_circle_id);
        v.extend_from_slice(creator);
        v.extend_from_slice(&(name.len() as u32).to_le_bytes());
        v.extend_from_slice(name.as_bytes());
        v.extend_from_slice(&version.to_le_bytes());
        v
    }

    /// Offer an upgrade under the `creator` account identity. `new_circle_id` must have been minted
    /// by `mint_owned_circle_id(creator)`; [`Self::verify`] refuses one that doesn't bind.
    pub fn issue(creator_id: &Identity, legacy_circle_id: &[u8], new_circle_id: &[u8], name: &str, version: u64) -> Self {
        let creator = creator_id.public().node_id_bytes();
        let sig = creator_id.sign(&Self::signing_bytes(legacy_circle_id, new_circle_id, &creator, name, version));
        Self {
            legacy_circle_id: legacy_circle_id.to_vec(),
            new_circle_id: new_circle_id.to_vec(),
            creator,
            name: name.to_string(),
            version,
            sig,
        }
    }

    /// Verify the offer: the signer is `creator`, the signature covers every field, and the successor
    /// id genuinely binds `creator`. A receiver still must NOT act on it without user confirmation —
    /// see the type docs.
    pub fn verify(&self, creator_pub: &HavenId) -> Result<()> {
        if creator_pub.node_id_bytes() != self.creator {
            return Err(CoreError::Crypto("circle upgrade: creator id mismatch"));
        }
        let Ok(new_id) = std::str::from_utf8(&self.new_circle_id) else {
            return Err(CoreError::Encoding("circle upgrade: successor id is not utf-8"));
        };
        if !circle_id_binds_creator(new_id, &self.creator) {
            return Err(CoreError::Crypto("circle upgrade: successor id does not bind the creator"));
        }
        let msg = Self::signing_bytes(&self.legacy_circle_id, &self.new_circle_id, &self.creator, &self.name, self.version);
        creator_pub.verify(&msg, &self.sig)
    }

    /// Wire: `lp(legacy) ‖ lp(new) ‖ creator(32) ‖ lp(name) ‖ version(8) ‖ sig`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(16 + self.legacy_circle_id.len() + self.new_circle_id.len() + self.name.len() + 32 + 8 + self.sig.len());
        v.extend_from_slice(&(self.legacy_circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(&self.legacy_circle_id);
        v.extend_from_slice(&(self.new_circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(&self.new_circle_id);
        v.extend_from_slice(&self.creator);
        v.extend_from_slice(&(self.name.len() as u32).to_le_bytes());
        v.extend_from_slice(self.name.as_bytes());
        v.extend_from_slice(&self.version.to_le_bytes());
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b, WIRE);
        let legacy_circle_id = r.bytes_lp()?.to_vec();
        let new_circle_id = r.bytes_lp()?.to_vec();
        let creator = r.array32()?;
        let name = String::from_utf8(r.bytes_lp()?.to_vec())
            .map_err(|_| CoreError::Encoding("circle upgrade: name is not utf-8"))?;
        let version = r.u64()?;
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("circle upgrade: missing signature"));
        }
        Ok(Self { legacy_circle_id, new_circle_id, creator, name, version, sig })
    }
}

/// Compute the transitive admin closure from the pinned `creator` and a set of ALREADY-VERIFIED
/// `(grantor_account, admin_account)` delegation edges (§4.3). Pure, monotone fixpoint: seed with the
/// creator, then repeatedly admit any account whose grantor is already an admin. An edge whose grantor
/// never becomes an admin contributes NOTHING — so an isolated (even validly-signed) grant from a
/// non-authority can never inject an admin. Convergence is monotone in the edge set: seeing more
/// grants can only grow the admin set, never shrink it, so every replica that holds the same verified
/// grants computes the same closure.
pub fn admin_closure(
    creator: [u8; 32],
    edges: &[([u8; 32], [u8; 32])],
) -> std::collections::HashSet<[u8; 32]> {
    let mut admins = std::collections::HashSet::new();
    admins.insert(creator);
    loop {
        let before = admins.len();
        for (grantor, admin) in edges {
            if admins.contains(grantor) {
                admins.insert(*admin);
            }
        }
        if admins.len() == before {
            break; // fixpoint: nothing new is reachable
        }
    }
    admins
}

// The wire cursor now lives in `crate::wire` — this module carried one of five
// byte-identical private copies, which is why the cursor-overflow guard had to be
// written five times. Only the error strings were ever module-specific, so those stay
// here as a tag and the cursor itself does not.
use crate::wire::{Reader, WireTag};

const WIRE: WireTag = WireTag::new(
    "device wire: unexpected end of input",
    "device wire: length overflow",
    "device wire: invalid utf-8 name",
);

#[cfg(test)]
mod tests {
    use super::*;

    /// A hostile element count must be REJECTED, not reserved for.
    ///
    /// `DeviceList::from_bytes` used to `Vec::with_capacity(n)` straight off a 4-byte wire field,
    /// so `n = u32::MAX` asked the allocator for 32 × 4.29e9 = 137 GB. On Linux that aborts the
    /// process (SIGABRT on allocation failure) — a remote DoS, because rosters come from peers and
    /// no `Result` is ever returned to reject the blob. macOS masked it: an over-large mapping that
    /// is never written succeeds there, which is why this only turned red in CI.
    ///
    /// Asserts the parser RETURNS (an error, promptly) instead of dying. If this regresses, the
    /// test process aborts rather than failing — that abort IS the signal.
    #[test]
    fn hostile_device_counts_are_rejected_without_allocating() {
        for count in [u32::MAX, 0x7FFF_FFFF, 0x0FFF_FFFF] {
            for which in ["devices", "revoked"] {
                let mut b = Vec::new();
                b.extend_from_slice(&[0u8; 32]); // account_id
                b.extend_from_slice(&7u64.to_le_bytes()); // version
                b.extend_from_slice(&0u64.to_le_bytes()); // updated_at
                if which == "devices" {
                    b.extend_from_slice(&count.to_le_bytes()); // hostile device count
                } else {
                    b.extend_from_slice(&0u32.to_le_bytes()); // no devices
                    b.extend_from_slice(&count.to_le_bytes()); // hostile revoked count
                }
                b.extend_from_slice(&[0xAB; 8]); // far less data than the count claims
                assert!(
                    DeviceList::from_bytes(&b).is_err(),
                    "{which} count {count:#x} backed by 8 bytes must be rejected, not reserved for"
                );
            }
        }
    }

    /// The bound must not reject a LEGITIMATE roster — the guard is `count > remaining/32`, so an
    /// honest list whose entries are all present still parses. Without this the fix could "pass"
    /// by rejecting everything.
    #[test]
    fn honest_device_list_still_round_trips_after_the_count_bound() {
        let l = DeviceList {
            account_id: [1u8; 32],
            version: 3,
            updated_at: 99,
            devices: vec![[2u8; 32], [3u8; 32]],
            revoked: vec![[4u8; 32]],
            account_leaf_retired: true,
            sig: vec![0xEE; 96],
        };
        let parsed = DeviceList::from_bytes(&l.to_bytes()).expect("honest roster must parse");
        assert_eq!(parsed, l);
    }

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
    fn account_leaf_retirement_drops_only_the_account_leaf_and_keeps_devices() {
        // A legacy {account, device} roster: the bare account id is enrolled as its OWN leaf alongside a
        // real device. Retiring drops the account leaf from authorization WITHOUT touching the device set
        // (grow-only devices preserved) — the device-only shape live keying + retirement require.
        let account = id(1);
        let acct_id = account.public().node_id_bytes();
        let dev = id(2).public().node_id_bytes();
        let legacy = DeviceList::signed(&account, 1, 0, vec![acct_id, dev], vec![]);
        assert!(!legacy.account_leaf_retired);
        assert!(legacy.is_authorized(&acct_id), "legacy roster authorizes the bare account leaf");
        assert!(legacy.is_authorized(&dev));

        let retired = legacy.with_account_leaf_retired(&account, 1).expect("retire bumps + re-signs");
        assert_eq!(retired.version, 2, "retirement bumps the version");
        assert!(retired.account_leaf_retired);
        assert!(retired.verify(&account.public()).is_ok(), "the retired roster is validly account-signed");
        assert!(!retired.is_authorized(&acct_id), "the bare account leaf is no longer authorized");
        assert!(retired.is_authorized(&dev), "the DEVICE leaf remains authorized");
        assert!(retired.devices.contains(&acct_id), "the account id STAYS in devices (grow-only set untouched)");

        // Re-retiring is a sticky no-op (no needless version bump / epoch churn).
        assert!(retired.with_account_leaf_retired(&account, 2).is_none(), "already-retired re-retire is a no-op");
    }

    #[test]
    fn non_retired_wire_is_byte_identical_and_flag_round_trips() {
        // The switch-OFF guarantee at the wire level: a non-retired list encodes EXACTLY as before, and a
        // retired one round-trips its flag while remaining verifiable.
        let account = id(1);
        let acct_id = account.public().node_id_bytes();
        let dev = id(2).public().node_id_bytes();
        let list = DeviceList::signed(&account, 3, 9, vec![acct_id, dev], vec![]);
        assert!(!list.to_bytes().ends_with(LEAF_RETIRE_WIRE_SUFFIX.as_slice()),
                "a non-retired list carries NO retirement suffix (byte-identical to pre-1.0.7)");
        let back = DeviceList::from_bytes(&list.to_bytes()).expect("decode non-retired");
        assert_eq!(list, back);
        assert!(!back.account_leaf_retired);

        let retired = list.with_account_leaf_retired(&account, 10).unwrap();
        let wire = retired.to_bytes();
        assert!(wire.ends_with(LEAF_RETIRE_WIRE_SUFFIX.as_slice()), "a retired list carries the suffix");
        let back = DeviceList::from_bytes(&wire).expect("decode retired");
        assert_eq!(retired, back, "retired flag survives the wire round-trip");
        assert!(back.account_leaf_retired);
        back.verify(&account.public()).expect("decoded retired list still verifies");
    }

    #[test]
    fn retirement_flag_is_signed_tamper_is_rejected() {
        // The flag is part of the SIGNED preimage: flipping it either direction without the account
        // re-signing must fail verify() — a relay can neither forge a retirement (to strand a seed-holder)
        // nor strip one (to resurrect the account leaf) undetectably.
        let account = id(1);
        let acct_id = account.public().node_id_bytes();
        // Forge a retirement onto a genuinely non-retired signature.
        let mut forged_on = DeviceList::signed(&account, 1, 0, vec![acct_id], vec![]);
        forged_on.account_leaf_retired = true;
        assert!(forged_on.verify(&account.public()).is_err(), "forging retirement onto a plain sig fails");
        // Strip a genuine retirement without re-signing.
        let mut stripped = account_leaf_retired_list(&account, 2, acct_id);
        stripped.account_leaf_retired = false;
        assert!(stripped.verify(&account.public()).is_err(), "stripping a signed retirement fails");
    }

    #[test]
    fn retirement_is_sticky_across_merge_and_rollback_defended() {
        // Mirrors `merge_keeps_revocations_sticky`: once EITHER copy has retired the account leaf, no
        // stale copy that still authorizes it can resurrect it — the same "grows, never shrinks" rule.
        let account = id(1);
        let acct_id = account.public().node_id_bytes();
        let dev = id(2).public().node_id_bytes();
        // v3 retired; a stale v2 still authorizes the account leaf.
        let retired = DeviceList::signed(&account, 3, 0, vec![acct_id, dev], vec![])
            .with_account_leaf_retired(&account, 0)
            .unwrap(); // version 4
        let stale_authorizing = DeviceList::signed(&account, 2, 0, vec![acct_id, dev], vec![]);

        // Merge in EITHER direction keeps the account leaf retired (never un-retires).
        let merged = stale_authorizing.merge(&retired, &account, 5).expect("stale picks up retirement");
        assert!(merged.account_leaf_retired && !merged.is_authorized(&acct_id), "retirement wins the merge");
        merged.verify(&account.public()).expect("merged roster is validly account-signed");
        if let Some(m2) = retired.merge(&stale_authorizing, &account, 5) {
            assert!(m2.account_leaf_retired, "the stale side can never un-retire the account leaf");
        } // None = no change, which also preserves retirement.

        // adopt_if_newer rollback defense: a stale (lower-version) authorizing copy is refused outright.
        let mut held = retired.clone();
        assert!(!held.adopt_if_newer(&stale_authorizing), "a stale roster loses the version race");
        assert!(held.account_leaf_retired, "the retired leaf is not resurrected by a rolled-back copy");
    }

    /// Helper: a validly-signed, account-leaf-retired list at `version` for `account`.
    fn account_leaf_retired_list(account: &Identity, version: u64, acct_id: [u8; 32]) -> DeviceList {
        DeviceList::signed(account, version, 0, vec![acct_id], vec![])
            .with_account_leaf_retired(account, 0)
            .unwrap()
    }

    #[test]
    fn retired_account_is_dropped_from_recipients_but_devices_still_seal() {
        // The end-to-end recipient effect: once retired, `authorized_bundles` (and so the device-only
        // gated seal) sheds the bare account bundle, while the device bundle stays a recipient.
        let account = id(1);
        let device = id(2);
        let list = DeviceList::signed(
            &account, 1, 0,
            vec![account.public().node_id_bytes(), device.public().node_id_bytes()],
            vec![],
        )
        .with_account_leaf_retired(&account, 1)
        .unwrap();
        let creds = vec![
            DeviceCredential::issue(&account, &account.public(), "account-as-leaf", 0),
            DeviceCredential::issue(&account, &device.public(), "device", 1),
        ];
        let cd = ContactDevices { list, credentials: creds };
        let bundles: std::collections::HashSet<[u8; 32]> =
            cd.authorized_bundles().iter().map(|b| b.node_id_bytes()).collect();
        assert!(!bundles.contains(&account.public().node_id_bytes()), "retired account bundle is dropped");
        assert!(bundles.contains(&device.public().node_id_bytes()), "the device bundle still seals");

        // The gated device-only recipient set excludes the bare account too.
        let mut map = std::collections::HashMap::new();
        map.insert(account.public().node_id_bytes(), cd);
        let mut capable = std::collections::HashSet::new();
        capable.insert(account.public().node_id_bytes());
        let gated = recipients_with_devices_gated(&[account.public()], &map, &capable, true);
        let gated_ids: std::collections::HashSet<[u8; 32]> = gated.iter().map(|b| b.node_id_bytes()).collect();
        assert!(!gated_ids.contains(&account.public().node_id_bytes()), "device-only seal cuts the account seed holder");
        assert!(gated_ids.contains(&device.public().node_id_bytes()));
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

    // ── Seed-drop S0 scaffold tests ──────────────────────────────────────────────────────────

    #[test]
    fn seed_drop_capability_round_trips_and_rejects_forgery() {
        let account = id(1);
        let cap = SeedDropCapability::issue(&account, 1);
        // A contact who pinned the account key trusts the marker.
        cap.verify(&account.public()).expect("valid capability must verify");
        assert_eq!(cap.version, 1);
        // Wire round-trip is stable.
        let back = SeedDropCapability::from_bytes(&cap.to_bytes()).expect("decode");
        assert_eq!(cap, back);
        back.verify(&account.public()).expect("decoded capability still verifies");

        // FORGED: a relay can't mint a marker for an account whose key it lacks (pin a different account).
        let imposter = id(9);
        assert!(cap.verify(&imposter.public()).is_err(), "capability for a foreign account must reject");

        // TAMPERED: bumping the advertised version without re-signing must fail (no forging a higher tier).
        let mut forged = cap.clone();
        forged.version = 2;
        assert!(forged.verify(&account.public()).is_err(), "tampered version must not verify");

        // STRIPPED / absent: an empty or truncated trailer decodes to None → caller treats as legacy,
        // never as "downgraded" (absence is never information).
        assert!(SeedDropCapability::from_bytes(&[]).is_none());
        assert!(SeedDropCapability::from_bytes(&cap.to_bytes()[..30]).is_none());
    }

    // ── TreeKEM M0 gate ──────────────────────────────────────────────────────────────────────

    /// `circle_fully_mls_capable` is all-present-positive with NESTED capability: a member counts
    /// only when it is in BOTH capable sets AND has a roster. Any single gap — an mls-less member,
    /// a seed-drop-less member (nesting: mls-capable ⊂ seed-drop-capable), a roster-less member,
    /// or an empty circle — keeps the whole circle off TreeKEM.
    #[test]
    fn mls_gate_requires_both_capability_sets_and_rosters() {
        let alice = id(21);
        let bob = id(22);
        let members = [alice.public(), bob.public()];
        let roster_for = |acct: &Identity, dev_seed: u8| {
            let dev = id(dev_seed);
            ContactDevices {
                list: DeviceList::signed(acct, 1, 0, vec![dev.public().node_id_bytes()], vec![]),
                credentials: vec![DeviceCredential::issue(acct, &dev.public(), "dev", 1)],
            }
        };
        let mut rosters = std::collections::HashMap::new();
        rosters.insert(alice.public().node_id_bytes(), roster_for(&alice, 23));
        rosters.insert(bob.public().node_id_bytes(), roster_for(&bob, 24));
        let both: std::collections::HashSet<[u8; 32]> =
            [alice.public().node_id_bytes(), bob.public().node_id_bytes()].into();
        let alice_only: std::collections::HashSet<[u8; 32]> = [alice.public().node_id_bytes()].into();

        // Fully capable: every member in BOTH sets, every member with a roster → true.
        assert!(circle_fully_mls_capable(&members, &rosters, &both, &both));

        // An empty circle is never "fully capable" (vacuous truth must not flip a gate).
        assert!(!circle_fully_mls_capable(&[], &rosters, &both, &both));

        // One member missing the `ml` marker → false, even though seed-drop is all-present.
        assert!(!circle_fully_mls_capable(&members, &rosters, &both, &alice_only));

        // NESTING: an `ml` marker without seed-drop capability counts for nothing — a member in
        // `mls_capable` but not `seed_drop_capable` keeps the circle off (leaves are device keys;
        // TreeKEM presupposes the account-key retirement machinery).
        assert!(!circle_fully_mls_capable(&members, &rosters, &alice_only, &both));

        // A member whose roster we haven't learned → false, even with both markers verified.
        let mut missing_roster = rosters.clone();
        missing_roster.remove(&bob.public().node_id_bytes());
        assert!(!circle_fully_mls_capable(&members, &missing_roster, &both, &both));
    }

    #[test]
    fn dual_seal_scaffold_gates_account_key_only_when_enabled() {
        use crate::groupkey::{open_key_commit, seal_key_commit};
        // A member (Bob) with a device roster authorizing ONE device key, DISTINCT from his account key —
        // the seedless-device shape, so dropping the bare account key is observable (an account key that is
        // itself enrolled as a device would legitimately remain a recipient).
        let bob = id(1);
        let bob_dev = id(2);
        let list = DeviceList::signed(&bob, 1, 0, vec![bob_dev.public().node_id_bytes()], vec![]);
        let creds = vec![DeviceCredential::issue(&bob, &bob_dev.public(), "bob-mac", 1)];
        let mut map = std::collections::HashMap::new();
        map.insert(bob.public().node_id_bytes(), ContactDevices { list, credentials: creds });
        let members = [bob.public()];

        // (a) DEFAULT (gate OFF) is byte-identical to `recipients_with_devices` — dual-seal stays: the
        //     account key AND the device bundle are both recipients.
        let mut capable = std::collections::HashSet::new();
        capable.insert(bob.public().node_id_bytes());
        let default = recipients_with_devices_gated(&members, &map, &capable, false);
        let baseline = recipients_with_devices(&members, &map);
        let ids = |v: &[HavenId]| v.iter().map(|h| h.node_id_bytes()).collect::<Vec<_>>();
        assert_eq!(ids(&default), ids(&baseline), "gate OFF must equal today's recipients exactly");
        let def_ids: std::collections::HashSet<[u8; 32]> = ids(&default).into_iter().collect();
        assert!(def_ids.contains(&bob.public().node_id_bytes()), "account key present (dual-seal)");
        assert!(def_ids.contains(&bob_dev.public().node_id_bytes()), "device bundle present (dual-seal)");

        // Dual-seal proof: a commit to the default recipients is openable by BOTH an account-key opener
        // and a device-key opener.
        let committer = id(7);
        let (e, s) = ([9u8; 32], [7u8; 32]);
        let commit = seal_key_commit(&committer, &default, "c", 1, &e, &s).expect("seal");
        assert_eq!(open_key_commit(&bob, &committer.public(), &commit).unwrap().epoch_key, e,
                   "account-key opener opens the dual-sealed commit");
        assert_eq!(open_key_commit(&bob_dev, &committer.public(), &commit).unwrap().epoch_key, e,
                   "device-key opener opens the dual-sealed commit");

        // (b) Gate ON + fully capable → the bare account key is DROPPED (device-only seal). The account
        //     key holder can no longer open; the device still can. (This is the future S5 behavior; here it
        //     only proves the scaffold works.)
        let gated = recipients_with_devices_gated(&members, &map, &capable, true);
        let gated_ids: std::collections::HashSet<[u8; 32]> = ids(&gated).into_iter().collect();
        assert!(!gated_ids.contains(&bob.public().node_id_bytes()), "gate ON drops the bare account key");
        assert!(gated_ids.contains(&bob_dev.public().node_id_bytes()), "device bundle stays a recipient");

        // (c) A member we have NOT seen capability from keeps the whole circle on the account key even with
        //     the gate ON — an all-present positive signal, never absence-inferred.
        let empty_caps = std::collections::HashSet::new();
        let not_capable = recipients_with_devices_gated(&members, &map, &empty_caps, true);
        let nc_ids: std::collections::HashSet<[u8; 32]> = ids(&not_capable).into_iter().collect();
        assert!(nc_ids.contains(&bob.public().node_id_bytes()),
                "not-fully-capable circle retains the account key (no premature drop)");
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

    #[test]
    fn s3_device_authors_and_commits_under_device_key_verified_via_roster() {
        // Seed-drop S3 (§4.2): a seedless DEVICE authors an event AND commits an epoch key under its
        // DEVICE key (sender = device, author = account). A contact holding the account's verified roster
        // resolves the signer device → its account + bundle and opens both; the dual-seal account-key
        // recipient keeps the content readable by a seed-holder / legacy peer. A device in no roster is
        // rejected as an authorized signer.
        use crate::groupkey::{
            new_circle_secret, new_epoch_key, open_event_in_epoch_authored, open_key_commit,
            seal_event_in_epoch, seal_key_commit,
        };
        use crate::social::{Event, EventKind};

        let account = id(1);
        let device = id(2); // an authorized device of `account`
        let contact = id(5); // a circle member who will read

        // The account's verified roster: device authorized + a credential carrying its routable bundle.
        let cred = DeviceCredential::issue(&account, &device.public(), "phone", 100);
        let list = DeviceList::signed(&account, 1, 100, vec![device.public().node_id_bytes()], vec![]);
        let mut roster = std::collections::HashMap::new();
        roster.insert(account.public().node_id_bytes(), ContactDevices { list, credentials: vec![cred] });

        // Sender-authorization oracle: the device resolves to its account + bundle; a foreign one doesn't.
        let (resolved_acct, bundle) =
            author_and_bundle_for_device(&device.public().node_id_bytes(), &roster).expect("device resolves");
        assert_eq!(resolved_acct, account.public().node_id_bytes());
        assert!(
            author_and_bundle_for_device(&id(9).public().node_id_bytes(), &roster).is_none(),
            "a device in no roster is not an authorized signer"
        );

        // Dual-seal recipients: account key (legacy path) + authorized device bundles.
        let members = recipients_with_devices(&[account.public(), contact.public()], &roster);
        let epoch = new_epoch_key();
        let secret = new_circle_secret();

        // The DEVICE commits the epoch key (signed by the device key).
        let commit = seal_key_commit(&device, &members, "c1", 0, &epoch, &secret).unwrap();
        // Contact opens it using the RESOLVED device bundle as committer_pub (device-key verify path).
        assert_eq!(open_key_commit(&contact, &bundle, &commit).unwrap().epoch_key, epoch);
        // Legacy / seed-holder path stays open: the account itself opens the same commit via its
        // account-key recipient (present because of dual-seal) — coexistence preserved.
        assert_eq!(open_key_commit(&account, &bundle, &commit).unwrap().epoch_key, epoch);

        // The DEVICE authors an event FOR ITS ACCOUNT; the contact resolves + opens it (device-signed,
        // account-authored). Binding to a different account is rejected (no re-attribution).
        let ev = Event::new(&account.public().node_id_bytes(), 200, EventKind::Message { body: "device-authored".into() });
        let env = seal_event_in_epoch(&device, "c1", 0, &epoch, &ev).unwrap();
        let acct_hex: String = resolved_acct.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            open_event_in_epoch_authored(&bundle, &epoch, &env, Some(&acct_hex)).unwrap(),
            ev,
            "a device-signed, account-authored event opens when bound to its account"
        );
        let stranger_hex: String = id(7).public().node_id_bytes().iter().map(|b| format!("{b:02x}")).collect();
        assert!(
            open_event_in_epoch_authored(&bundle, &epoch, &env, Some(&stranger_hex)).is_err(),
            "the device cannot author for an account it isn't credentialed to"
        );
    }

    #[test]
    fn s4_seedless_new_device_is_credentialed_but_cannot_forge_a_roster() {
        // Seed-drop S4 (§3.2 easy case): a NEW device holds only its own device key + an account-signed
        // credential (+ the granted self-sync key from S2) — never the master seed. The distinctive S4
        // property proven here: it CANNOT produce a DeviceList that verifies against the pinned account
        // key, so it can neither authorize itself nor add a rogue. Roster authority is the account key it
        // does not hold. (Author + sync are covered by S2/S3.)
        let account = id(1);
        let new_device = id(2); // seedless: only its own device key

        // The primary authorizes it: an account-signed credential + roster entry, both verifying.
        let cred = DeviceCredential::issue(&account, &new_device.public(), "new-ipad", 100);
        assert!(cred.verify(&account.public()).is_ok(), "the account-signed credential verifies");
        let list = DeviceList::signed(&account, 1, 100, vec![new_device.public().node_id_bytes()], vec![]);
        assert!(list.verify(&account.public()).is_ok() && list.is_authorized(&new_device.public().node_id_bytes()));

        // Forge attempt 1 — sign honestly with the device key: account_id becomes the DEVICE's id, so it
        // fails verify() against the real account on the id mismatch (it isn't even the account's roster).
        let honest_forge = DeviceList::signed(&new_device, 99, 200, vec![new_device.public().node_id_bytes(), id(9).public().node_id_bytes()], vec![]);
        assert!(honest_forge.verify(&account.public()).is_err(), "a device-signed roster is not the account's roster");

        // Forge attempt 2 — CLAIM the account's id but sign with the device key: the id now matches, so
        // verification reaches the SIGNATURE, which was made by the device, not the account → rejected.
        let mut claimed_forge = DeviceList::signed(&new_device, 99, 200, vec![new_device.public().node_id_bytes(), id(9).public().node_id_bytes()], vec![]);
        claimed_forge.account_id = account.public().node_id_bytes();
        assert!(claimed_forge.verify(&account.public()).is_err(), "a device signature can't stand in for the account key on a roster");
    }

    #[test]
    fn s5_revoked_seedless_device_cannot_reenter_or_decrypt() {
        // THE HEADLINE TEST (§7). A device holds ONLY its device key + credential (no account seed),
        // authorized in roster v1. After revocation + epoch rotation, with the account-key seal GATED OFF
        // (circle fully seed-drop-capable), it (a) cannot decrypt post-revocation content, and (b) cannot
        // re-add itself — roster authority is the account key it never held. This is the cryptographic cut
        // that "advisory revocation" was not: it now holds for a COMPROMISED device, not just a lost one.
        use crate::groupkey::{
            new_circle_secret, new_epoch_key, open_event_in_epoch, open_key_commit, seal_event_in_epoch,
            seal_key_commit,
        };
        use crate::social::{Event, EventKind};

        let account = id(1); // the primary / account (seed-holder, signs the roster)
        let compromised = id(2); // seedless device: only its device key + credential
        let good = id(3); // another authorized device that stays

        let cred_c = DeviceCredential::issue(&account, &compromised.public(), "compromised", 100);
        let cred_g = DeviceCredential::issue(&account, &good.public(), "good", 100);
        let mut roster = std::collections::HashMap::new();
        let mut capable = std::collections::HashSet::new();
        capable.insert(account.public().node_id_bytes());

        // Roster v1: both devices authorized. Fully seed-drop-capable → account-key seal GATED OFF.
        let list_v1 = DeviceList::signed(
            &account,
            1,
            100,
            vec![compromised.public().node_id_bytes(), good.public().node_id_bytes()],
            vec![],
        );
        roster.insert(account.public().node_id_bytes(), ContactDevices { list: list_v1.clone(), credentials: vec![cred_c.clone(), cred_g.clone()] });
        let secret = new_circle_secret();

        // Epoch 0 (pre-revocation): sealed ONLY to authorized device bundles (no bare account key).
        let e0 = new_epoch_key();
        let recips0 = recipients_with_devices_gated(&[account.public()], &roster, &capable, true);
        let commit0 = seal_key_commit(&account, &recips0, "c1", 0, &e0, &secret).unwrap();
        assert_eq!(open_key_commit(&compromised, &account.public(), &commit0).unwrap().epoch_key, e0, "pre-revocation, the device is a recipient");

        // REVOKE it: roster v2 (higher version, account-signed) + epoch rotation to e1.
        let list_v2 = DeviceList::signed(&account, 2, 200, vec![good.public().node_id_bytes()], vec![compromised.public().node_id_bytes()]);
        roster.insert(account.public().node_id_bytes(), ContactDevices { list: list_v2.clone(), credentials: vec![cred_c.clone(), cred_g.clone()] });
        let e1 = new_epoch_key();
        let recips1 = recipients_with_devices_gated(&[account.public()], &roster, &capable, true);
        let commit1 = seal_key_commit(&account, &recips1, "c1", 1, &e1, &secret).unwrap();

        // (a) CRYPTOGRAPHIC CUT: the revoked device is NOT a recipient of the epoch-1 commit, and the
        // account-key path is gated off, so no epoch-1 key ever reaches it. The good device still gets e1.
        assert!(open_key_commit(&compromised, &account.public(), &commit1).is_err(), "revoked seedless device cannot obtain the new epoch key");
        assert_eq!(open_key_commit(&good, &account.public(), &commit1).unwrap().epoch_key, e1);
        let ev = Event::new(&account.public().node_id_bytes(), 300, EventKind::Message { body: "after revoke".into() });
        let env = seal_event_in_epoch(&account, "c1", 1, &e1, &ev).unwrap();
        assert!(open_event_in_epoch(&account.public(), &e0, &env, false).is_err(), "the device's stale epoch key cannot open post-revocation content");

        // (b) CANNOT RE-ENTER: it forges a higher-version roster re-adding itself, but can only sign with
        // its device key — verify() against the pinned account key rejects it, so no honest peer adopts it.
        let mut forged = DeviceList::signed(&compromised, 99, 300, vec![compromised.public().node_id_bytes(), good.public().node_id_bytes()], vec![]);
        forged.account_id = account.public().node_id_bytes();
        assert!(forged.verify(&account.public()).is_err(), "the device cannot forge a roster that verifies against the account key");
        // The account's genuine v2 revocation is what an honest peer adopts (higher version, verified).
        let mut held = list_v1.clone();
        assert!(held.adopt_if_newer(&list_v2) && !held.is_authorized(&compromised.public().node_id_bytes()), "the account's revocation stands");
    }

    #[test]
    fn s5_legacy_account_key_device_still_reads_when_circle_not_fully_upgraded() {
        // Coexistence guard (§5): retiring the account-key seal is an ALL-PRESENT positive signal. If any
        // member is not yet seed-drop-capable, the gate does NOT drop the account key, so a legacy
        // account-key-only holder keeps opening the commit — we don't buy revocation by breaking interop.
        use crate::groupkey::{new_circle_secret, new_epoch_key, open_key_commit, seal_key_commit};

        let account = id(1);
        let device = id(2);
        let legacy_peer = id(6); // a circle member with NO roster / capability (still on the old app)

        let cred = DeviceCredential::issue(&account, &device.public(), "phone", 100);
        let list = DeviceList::signed(&account, 1, 100, vec![device.public().node_id_bytes()], vec![]);
        let mut roster = std::collections::HashMap::new();
        roster.insert(account.public().node_id_bytes(), ContactDevices { list, credentials: vec![cred] });
        // Only `account` is capable; `legacy_peer` is not → circle NOT fully capable → gate stays OFF.
        let mut capable = std::collections::HashSet::new();
        capable.insert(account.public().node_id_bytes());

        let e0 = new_epoch_key();
        let secret = new_circle_secret();
        let recips = recipients_with_devices_gated(&[account.public(), legacy_peer.public()], &roster, &capable, true);
        let commit = seal_key_commit(&account, &recips, "c1", 0, &e0, &secret).unwrap();
        // The legacy peer (account-key only, no devices) still opens the commit via its account-key recipient.
        assert_eq!(open_key_commit(&legacy_peer, &account.public(), &commit).unwrap().epoch_key, e0, "a straggler keeps the whole circle on dual-seal");
    }

    // ── MLS M3: circle admin authority (§4.3) ────────────────────────────────────────────────

    #[test]
    fn admin_grant_round_trips_verifies_and_rejects_forgery() {
        let creator = id(1);
        let alice = id(2);
        let mallory = id(9);
        let cid = b"circle-x";
        let creator_id = creator.public().node_id_bytes();
        let alice_id = alice.public().node_id_bytes();

        // Creator delegates admin to Alice. Round-trips byte-stably and verifies against the creator.
        let g = AdminGrant::issue(&creator, cid, creator_id, alice_id, 1);
        assert_eq!(AdminGrant::from_bytes(&g.to_bytes()).unwrap(), g, "grant round-trips");
        assert!(g.verify(&creator.public()).is_ok(), "a genuine grant verifies against its grantor");
        // Verifying against the WRONG account fails (grantor id mismatch).
        assert!(g.verify(&alice.public()).is_err(), "grant does not verify against a non-grantor");

        // FORGERY: Mallory signs a grant but relabels the grantor as the creator — the signature no
        // longer matches the creator's key, so verify() rejects it (a relay can't forge authority).
        let mut forged = AdminGrant::issue(&mallory, cid, creator_id, mallory.public().node_id_bytes(), 5);
        forged.grantor_account = creator_id;
        assert!(forged.verify(&creator.public()).is_err(), "a forged grantor id must not verify");
    }

    #[test]
    fn admin_grant_is_higher_version_wins() {
        let creator = id(1);
        let alice = id(2);
        let cid = b"c";
        let creator_id = creator.public().node_id_bytes();
        let alice_id = alice.public().node_id_bytes();
        let mut held = AdminGrant::issue(&creator, cid, creator_id, alice_id, 1);
        let newer = AdminGrant::issue(&creator, cid, creator_id, alice_id, 3);
        let stale = AdminGrant::issue(&creator, cid, creator_id, alice_id, 1);
        assert!(held.adopt_if_newer(&newer), "a strictly-newer grant is adopted");
        assert_eq!(held.version, 3);
        assert!(!held.adopt_if_newer(&stale), "a stale (lower/equal version) grant loses");
        assert_eq!(held.version, 3, "rollback is refused");
    }

    #[test]
    fn epoch_self_sync_grant_round_trips_and_is_device_scoped() {
        // Audit M1: the rotated key is granted WITH its epoch, to one device bundle only.
        let account = id(1);
        let device = id(2);
        let rotated = [7u8; 32];
        let grant = seal_self_sync_key_epoch(&account, &device.public(), 5, &rotated).expect("seal");
        let (epoch, key) = open_self_sync_key_epoch(&device, &account.public(), &grant).expect("open");
        assert_eq!(epoch, 5, "the key-epoch survives the grant");
        assert_eq!(key, rotated, "the granted key is the rotated key, byte-identical");
        // A different device (not the recipient) cannot open it.
        let stranger = id(3);
        assert!(
            open_self_sync_key_epoch(&stranger, &account.public(), &grant).is_err(),
            "an epoch grant sealed to one device is not openable by another"
        );
    }

    #[test]
    fn circle_upgrade_round_trips_and_binds_its_successor_to_the_signer() {
        let alice = Identity::from_seed(&[2u8; 32]);
        let mallory = Identity::from_seed(&[9u8; 32]);
        let alice_acct = alice.public().node_id_bytes();
        let new_id = mint_owned_circle_id(&alice_acct);

        let up = CircleUpgrade::issue(&alice, b"fam", new_id.as_bytes(), "Family", 1);
        let wire = CircleUpgrade::to_bytes(&up);
        let back = CircleUpgrade::from_bytes(&wire).expect("round-trips");
        assert_eq!(back, up);
        assert!(back.verify(&alice.public()).is_ok(), "a genuine offer verifies");

        // Signed by someone else ⇒ id mismatch.
        assert!(back.verify(&mallory.public()).is_err(), "the offer is bound to its signer");

        // Tampering with any covered field breaks the signature.
        let mut tampered = up.clone();
        tampered.name = "Not Family".into();
        assert!(tampered.verify(&alice.public()).is_err(), "the name is signed");
        let mut tampered = up.clone();
        tampered.legacy_circle_id = b"other".to_vec();
        assert!(tampered.verify(&alice.public()).is_err(), "the legacy id is signed");

        // The successor MUST bind the signer: Mallory can't offer a successor she owns while
        // claiming Alice as its creator, nor claim a successor bound to Alice as her own.
        let mallory_id = mint_owned_circle_id(&mallory.public().node_id_bytes());
        let cross = CircleUpgrade::issue(&mallory, b"fam", mallory_id.as_bytes(), "Family", 1);
        assert!(cross.verify(&mallory.public()).is_ok(), "Mallory may offer her OWN successor");
        // …but an offer whose successor doesn't bind the signer is refused outright.
        let forged = CircleUpgrade::issue(&mallory, b"fam", new_id.as_bytes(), "Family", 1);
        assert!(forged.verify(&mallory.public()).is_err(), "successor must bind the signer");
        // A legacy (unbound) id can never be a successor.
        let legacy_succ = CircleUpgrade::issue(&alice, b"fam", b"default", "Family", 1);
        assert!(legacy_succ.verify(&alice.public()).is_err(), "successor must be an owned id");
    }

    #[test]
    fn admin_closure_only_follows_chains_rooted_at_the_creator() {
        let creator = [1u8; 32];
        let alice = [2u8; 32];
        let bob = [3u8; 32];
        let mallory = [9u8; 32];
        let rando = [7u8; 32];

        // creator → alice, alice → bob (a delegated admin can further delegate), plus an ISOLATED
        // rando → mallory edge whose grantor is not (and never becomes) an admin.
        let edges = vec![(creator, alice), (alice, bob), (rando, mallory)];
        let admins = admin_closure(creator, &edges);
        assert!(admins.contains(&creator), "the creator is always an admin");
        assert!(admins.contains(&alice), "a creator-delegated admin is included");
        assert!(admins.contains(&bob), "a transitively-delegated admin is included");
        assert!(!admins.contains(&mallory), "a grant from a non-admin injects nothing");
        assert!(!admins.contains(&rando), "the isolated grantor is not itself an admin");
    }
}
