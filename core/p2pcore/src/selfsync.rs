//! Account-state **self-sync** across a user's own devices (multi-device D16, Phase 3).
//!
//! Phase 1 ([`crate::device`]) established *which* devices belong to an account. This module
//! is what actually makes those devices **converge**: a mergeable, self-encrypted snapshot of
//! the user's own account state — the roster (circles), contacts, profile, settings, blocked
//! list, and per-circle read positions — that each device writes to a per-account mailbox slot
//! and merges from its peers.
//!
//! ## Why a CRDT, not a snapshot
//!
//! `social::export_state`/`import_state` is a *whole-state replace* — fine for restoring one
//! device, wrong for two live devices (last writer clobbers the other's concurrent edits). Here
//! every logical record is a **last-write-wins register** keyed by a namespaced string
//! (`circle:<id>`, `contact:<hex>`, `profile`, `setting:<k>`, `blocked:<hex>`), and read
//! positions are **grow-only max** counters. [`AccountState::merge`] is therefore commutative,
//! associative, and idempotent, so devices reach the same state regardless of delivery order or
//! duplication — exactly what an eventually-consistent mailbox needs.
//!
//! ## Privacy
//!
//! The blob is sealed with [`Identity::self_sync_key`] — a symmetric key every one of the
//! user's devices derives from the shared seed and **no one else can**. The relay/mailbox only
//! ever holds ciphertext; it learns nothing about the roster or settings it carries.
//!
//! The module is **pure**: timestamps are caller-supplied (`stamp.ts` = wall-clock ms from the
//! writing device), so it is deterministic and unit-testable everywhere, including WASM.

use std::collections::BTreeMap;

use hkdf::Hkdf;
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::Sha256;

use crate::crypto;
use crate::{CoreError, Result};

/// Derive a fresh per-blob key from the long-lived self-sync key + a random salt, so the static key
/// is never used directly as an AES-GCM key (avoids random-nonce reuse across many seals — audit M1).
fn selfsync_subkey(self_key: &[u8; 32], salt: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(salt), self_key);
    let mut okm = [0u8; 32];
    hk.expand(b"haven-selfsync-msg-v1", &mut okm).expect("32 is a valid HKDF length");
    okm
}

/// A last-write-wins timestamp: the writing device's wall-clock (ms) with the device's 32-byte
/// id as a deterministic tiebreak when two writes claim the same instant. Ordering is
/// `(ts, device)` lexicographically — total and identical on every replica.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    /// Caller-supplied wall-clock milliseconds. Not trusted for security — only for ordering.
    pub ts: u64,
    /// The authoring device's node id (tiebreak; also makes equal-ts writes deterministic).
    pub device: [u8; 32],
}

impl Stamp {
    pub fn new(ts: u64, device: [u8; 32]) -> Self {
        Self { ts, device }
    }
    /// Strictly-after comparison used to decide whether an incoming write supersedes ours.
    fn after(&self, o: &Stamp) -> bool {
        (self.ts, self.device) > (o.ts, o.device)
    }
}

/// One LWW register: the value at the time of `stamp`. `val == None` is a **tombstone**
/// (the record was removed) — kept, not deleted, so a later replica can't resurrect it.
#[derive(Clone)]
struct Reg {
    stamp: Stamp,
    val: Option<Vec<u8>>,
}

/// The user's own account state, replicated across their devices. Construct empty with
/// [`Default`], mutate with [`set`](Self::set)/[`remove`](Self::remove)/
/// [`bump_cursor`](Self::bump_cursor), exchange via [`seal`](Self::seal)/[`open`](Self::open),
/// and converge with [`merge`](Self::merge).
#[derive(Clone, Default)]
pub struct AccountState {
    /// Namespaced LWW records (`circle:<id>`, `contact:<hex>`, `profile`, `setting:<k>`, …).
    records: BTreeMap<String, Reg>,
    /// Grow-only read positions (`<circle-id>` → max last-read ms). Monotonic by `max`.
    cursors: BTreeMap<String, u64>,
}

impl AccountState {
    /// Set (or overwrite) `key` to `value`, taking effect only if `stamp` is newer than what
    /// we already hold for `key`. Returns `true` if this write won and was applied.
    pub fn set(&mut self, key: &str, value: Vec<u8>, stamp: Stamp) -> bool {
        self.apply(key, Some(value), stamp)
    }

    /// Tombstone `key` (mark it removed) if `stamp` is newer than what we hold. Returns `true`
    /// if applied. A removal can itself be superseded by a *newer* `set` (and vice-versa).
    pub fn remove(&mut self, key: &str, stamp: Stamp) -> bool {
        self.apply(key, None, stamp)
    }

    fn apply(&mut self, key: &str, val: Option<Vec<u8>>, stamp: Stamp) -> bool {
        match self.records.get(key) {
            Some(existing) if !stamp.after(&existing.stamp) => false,
            _ => {
                self.records.insert(key.to_string(), Reg { stamp, val });
                true
            }
        }
    }

    /// The current value for `key`, or `None` if absent or tombstoned.
    pub fn get(&self, key: &str) -> Option<&[u8]> {
        self.records.get(key).and_then(|r| r.val.as_deref())
    }

    /// Iterate the live (non-tombstoned) records as `(key, value)` in sorted key order.
    pub fn entries(&self) -> impl Iterator<Item = (&str, &[u8])> {
        self.records
            .iter()
            .filter_map(|(k, r)| r.val.as_deref().map(|v| (k.as_str(), v)))
    }

    /// Advance the read position for `name` to at least `ts` (grow-only max — never rewinds,
    /// so a stale device can't mark things unread). Returns `true` if it advanced.
    pub fn bump_cursor(&mut self, name: &str, ts: u64) -> bool {
        let cur = self.cursors.get(name).copied().unwrap_or(0);
        if ts > cur {
            self.cursors.insert(name.to_string(), ts);
            true
        } else {
            false
        }
    }

    /// The read position for `name` (0 if never set).
    pub fn cursor(&self, name: &str) -> u64 {
        self.cursors.get(name).copied().unwrap_or(0)
    }

    /// Merge `other` into `self`. Per record: keep whichever side's `stamp` is newer (tombstones
    /// included). Per cursor: keep the max. Commutative, associative, idempotent → all devices
    /// converge. Both states must already be authenticated (decrypted with the self-sync key).
    pub fn merge(&mut self, other: &AccountState) {
        for (key, their) in &other.records {
            let take = match self.records.get(key) {
                Some(ours) => their.stamp.after(&ours.stamp),
                None => true,
            };
            if take {
                self.records.insert(key.clone(), their.clone());
            }
        }
        for (name, &ts) in &other.cursors {
            let cur = self.cursors.get(name).copied().unwrap_or(0);
            if ts > cur {
                self.cursors.insert(name.clone(), ts);
            }
        }
    }

    // ── wire format ──────────────────────────────────────────────────────────────────────
    // records: u32 count, then [key_lp ‖ ts(8) ‖ device(32) ‖ present(1) ‖ val_lp?]
    // cursors: u32 count, then [name_lp ‖ ts(8)].  BTreeMap iteration is sorted ⇒ canonical.

    /// Deterministic serialization (sorted keys ⇒ byte-identical for equal states).
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&(self.records.len() as u32).to_le_bytes());
        for (key, reg) in &self.records {
            put_lp(&mut v, key.as_bytes());
            v.extend_from_slice(&reg.stamp.ts.to_le_bytes());
            v.extend_from_slice(&reg.stamp.device);
            match &reg.val {
                Some(val) => {
                    v.push(1);
                    put_lp(&mut v, val);
                }
                None => v.push(0),
            }
        }
        v.extend_from_slice(&(self.cursors.len() as u32).to_le_bytes());
        for (name, ts) in &self.cursors {
            put_lp(&mut v, name.as_bytes());
            v.extend_from_slice(&ts.to_le_bytes());
        }
        v
    }

    /// Inverse of [`Self::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let mut records = BTreeMap::new();
        let n = r.u32()?;
        for _ in 0..n {
            let key = r.str_lp()?;
            let ts = r.u64()?;
            let device = r.array32()?;
            let present = r.u8()?;
            let val = match present {
                0 => None,
                1 => Some(r.bytes_lp()?.to_vec()),
                _ => return Err(CoreError::Encoding("selfsync: bad presence byte")),
            };
            records.insert(key, Reg { stamp: Stamp { ts, device }, val });
        }
        let mut cursors = BTreeMap::new();
        let m = r.u32()?;
        for _ in 0..m {
            let name = r.str_lp()?;
            let ts = r.u64()?;
            cursors.insert(name, ts);
        }
        Ok(Self { records, cursors })
    }

    /// Self-encrypt for the mailbox. `self_key` is [`Identity::self_sync_key`]. Layout: salt(16) ‖
    /// AES-GCM(subkey). A fresh subkey per blob means the long-lived key is never reused directly.
    pub fn seal(&self, self_key: &[u8; 32]) -> Vec<u8> {
        let mut salt = [0u8; 16];
        OsRng.fill_bytes(&mut salt);
        let key = selfsync_subkey(self_key, &salt);
        let mut out = salt.to_vec();
        out.extend_from_slice(&crypto::seal(&key, &self.to_bytes()));
        out
    }

    /// Decrypt a blob produced by [`Self::seal`] (fails on a wrong key / tamper via the AEAD).
    pub fn open(self_key: &[u8; 32], sealed: &[u8]) -> Result<Self> {
        if sealed.len() < 16 {
            return Err(CoreError::Crypto("self-sync blob too short"));
        }
        let (salt, ct) = sealed.split_at(16);
        let key = selfsync_subkey(self_key, salt);
        Self::from_bytes(&crypto::open(&key, ct)?)
    }
}

/// Canonical relay-mailbox key for **one device's** self-sync slot. Every client MUST use
/// this exact layout so a user's devices converge cross-platform — each device owns its slot
/// (keyed by its node id), and a puller merges all slots under [`slot_prefix`]. Keeping the
/// scheme in shared core prevents the divergent-key bugs that silently break cross-device sync.
///
/// Layout: `self/<account-node-hex>/state/<device-node-hex>`.
pub fn slot_key(account_node_hex: &str, device_node_hex: &str) -> String {
    format!("self/{account_node_hex}/state/{device_node_hex}")
}

/// Canonical prefix listing **all** of an account's self-sync slots (for pull-and-merge):
/// `self/<account-node-hex>/state/`.
pub fn slot_prefix(account_node_hex: &str) -> String {
    format!("self/{account_node_hex}/state/")
}

fn put_lp(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u32).to_le_bytes());
    out.extend_from_slice(b);
}

/// Minimal length-prefixed reader for the wire format above.
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
            return Err(CoreError::Encoding("selfsync: unexpected end of input"));
        }
        let s = &self.b[self.i..self.i + n];
        self.i += n;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn array32(&mut self) -> Result<[u8; 32]> {
        Ok(self.take(32)?.try_into().unwrap())
    }
    fn bytes_lp(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn str_lp(&mut self) -> Result<String> {
        let b = self.bytes_lp()?;
        String::from_utf8(b.to_vec()).map_err(|_| CoreError::Encoding("selfsync: invalid utf-8 key"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    const PHONE: [u8; 32] = [1u8; 32];
    const MAC: [u8; 32] = [2u8; 32];

    #[test]
    fn newer_write_wins_older_is_ignored() {
        let mut s = AccountState::default();
        assert!(s.set("profile", b"v2".to_vec(), Stamp::new(20, PHONE)));
        // An older write (ts 10) must not clobber the newer one (ts 20).
        assert!(!s.set("profile", b"v1".to_vec(), Stamp::new(10, MAC)));
        assert_eq!(s.get("profile"), Some(&b"v2"[..]));
    }

    #[test]
    fn equal_timestamp_breaks_by_device_deterministically() {
        let mut a = AccountState::default();
        let mut b = AccountState::default();
        // Same ts, different devices: the higher device id wins, on BOTH replicas.
        a.set("setting:theme", b"dark".to_vec(), Stamp::new(5, PHONE));
        a.set("setting:theme", b"light".to_vec(), Stamp::new(5, MAC)); // MAC > PHONE ⇒ wins
        b.set("setting:theme", b"light".to_vec(), Stamp::new(5, MAC));
        b.set("setting:theme", b"dark".to_vec(), Stamp::new(5, PHONE)); // ignored
        assert_eq!(a.get("setting:theme"), Some(&b"light"[..]));
        assert_eq!(b.get("setting:theme"), a.get("setting:theme"));
    }

    #[test]
    fn remove_tombstones_and_resists_stale_resurrection() {
        let mut s = AccountState::default();
        s.set("contact:abc", b"bundle".to_vec(), Stamp::new(10, PHONE));
        assert!(s.remove("contact:abc", Stamp::new(20, PHONE)));
        assert_eq!(s.get("contact:abc"), None, "removed contact is gone");
        // A stale re-add (older than the removal) must NOT bring it back.
        assert!(!s.set("contact:abc", b"bundle".to_vec(), Stamp::new(15, MAC)));
        assert_eq!(s.get("contact:abc"), None);
        // But a genuinely newer re-add does.
        assert!(s.set("contact:abc", b"bundle2".to_vec(), Stamp::new(30, MAC)));
        assert_eq!(s.get("contact:abc"), Some(&b"bundle2"[..]));
    }

    #[test]
    fn cursors_are_grow_only_max() {
        let mut s = AccountState::default();
        assert!(s.bump_cursor("circle:home", 100));
        assert!(!s.bump_cursor("circle:home", 50), "must not rewind read state");
        assert!(s.bump_cursor("circle:home", 150));
        assert_eq!(s.cursor("circle:home"), 150);
    }

    /// The core guarantee: concurrent edits on two devices converge to the SAME state
    /// regardless of merge direction (commutativity).
    #[test]
    fn concurrent_devices_converge_either_merge_order() {
        // Device A: edits profile (late) and adds circle:home.
        let mut a = AccountState::default();
        a.set("profile", b"A-profile".to_vec(), Stamp::new(30, PHONE));
        a.set("circle:home", b"home".to_vec(), Stamp::new(10, PHONE));
        a.bump_cursor("circle:home", 200);

        // Device B: edits profile (earlier ⇒ loses) and adds circle:work, removes a contact.
        let mut b = AccountState::default();
        b.set("profile", b"B-profile".to_vec(), Stamp::new(25, MAC));
        b.set("circle:work", b"work".to_vec(), Stamp::new(12, MAC));
        b.remove("contact:x", Stamp::new(40, MAC));
        b.bump_cursor("circle:home", 120);

        let mut ab = a.clone();
        ab.merge(&b);
        let mut ba = b.clone();
        ba.merge(&a);

        // Same bytes ⇒ identical converged state.
        assert_eq!(ab.to_bytes(), ba.to_bytes(), "merge must be commutative");
        // And the right winners:
        assert_eq!(ab.get("profile"), Some(&b"A-profile"[..]), "newer profile (ts 30) wins");
        assert_eq!(ab.get("circle:home"), Some(&b"home"[..]));
        assert_eq!(ab.get("circle:work"), Some(&b"work"[..]));
        assert_eq!(ab.get("contact:x"), None, "tombstone propagates");
        assert_eq!(ab.cursor("circle:home"), 200, "max read cursor wins");
    }

    #[test]
    fn merge_is_idempotent() {
        let mut s = AccountState::default();
        s.set("profile", b"p".to_vec(), Stamp::new(1, PHONE));
        s.bump_cursor("c", 9);
        let before = s.to_bytes();
        let snap = s.clone();
        s.merge(&snap);
        s.merge(&snap);
        assert_eq!(s.to_bytes(), before, "merging a copy changes nothing");
    }

    #[test]
    fn wire_roundtrips_with_tombstones_and_cursors() {
        let mut s = AccountState::default();
        s.set("circle:home", b"home".to_vec(), Stamp::new(10, PHONE));
        s.remove("contact:x", Stamp::new(20, MAC));
        s.bump_cursor("circle:home", 555);
        let back = AccountState::from_bytes(&s.to_bytes()).expect("decode");
        assert_eq!(s.to_bytes(), back.to_bytes());
        assert_eq!(back.get("circle:home"), Some(&b"home"[..]));
        assert_eq!(back.get("contact:x"), None);
        assert_eq!(back.cursor("circle:home"), 555);
    }

    #[test]
    fn canonical_slot_keys_are_stable_and_prefix_matches() {
        let acct = "aabb";
        let dev = "ccdd";
        assert_eq!(slot_key(acct, dev), "self/aabb/state/ccdd");
        assert_eq!(slot_prefix(acct), "self/aabb/state/");
        assert!(slot_key(acct, dev).starts_with(&slot_prefix(acct)), "slot must live under prefix");
    }

    #[test]
    fn seal_then_open_with_each_device_key() {
        // Both devices share the seed ⇒ derive the same self-sync key ⇒ both can read.
        let seed = [7u8; 32];
        let dev_a = Identity::from_seed(&seed);
        let dev_b = Identity::from_seed(&seed);
        let key_a = dev_a.self_sync_key();
        assert_eq!(key_a, dev_b.self_sync_key(), "shared seed ⇒ shared self-sync key");

        let mut s = AccountState::default();
        s.set("profile", b"me".to_vec(), Stamp::new(1, PHONE));
        let blob = s.seal(&key_a);
        let opened = AccountState::open(&dev_b.self_sync_key(), &blob).expect("device B reads it");
        assert_eq!(opened.get("profile"), Some(&b"me"[..]));

        // A different account (different seed) cannot decrypt.
        let outsider = Identity::from_seed(&[9u8; 32]).self_sync_key();
        assert!(AccountState::open(&outsider, &blob).is_err(), "outsider key must fail");
    }

    #[test]
    fn seedless_device_converges_from_granted_self_sync_key() {
        // Seed-drop S2 (§4.3): a device that holds NO account seed still converges account-state,
        // because the PRIMARY grants it the self-sync key sealed to its device bundle — instead of the
        // device deriving it from a seed it no longer has. Proof obligation: a device given ONLY the
        // granted key converges account state identically to a seed-holder.
        use crate::device::{open_self_sync_key, seal_self_sync_key};

        let account = Identity::from_seed(&[1u8; 32]); // the primary (seed-holder / account identity)
        let device = Identity::from_seed(&[2u8; 32]); // a SEEDLESS device: only its own device key
        let account_key = account.self_sync_key();

        // Primary grants the self-sync key to the device's bundle; the device opens it WITHOUT ever
        // touching the account seed, verifying provenance against the account's pinned public bundle.
        let grant = seal_self_sync_key(&account, &device.public(), &account_key).expect("seal grant");
        let granted = open_self_sync_key(&device, &account.public(), &grant).expect("device opens grant");
        assert_eq!(granted, account_key, "the granted key IS the account self-sync key, byte-identical");

        // End-to-end convergence: the primary seals account state; the seedless device opens it with the
        // GRANTED key (never a seed) and reads identical state.
        let mut s = AccountState::default();
        s.set("profile", b"me".to_vec(), Stamp::new(1, PHONE));
        let blob = s.seal(&account_key);
        let opened = AccountState::open(&granted, &blob).expect("seedless device converges");
        assert_eq!(opened.get("profile"), Some(&b"me"[..]));

        // The seedless device can also seal its OWN update with the granted key, and the primary reads it —
        // convergence works in both directions with no seed on the device.
        let mut s2 = AccountState::default();
        s2.set("pin:home", b"1".to_vec(), Stamp::new(2, PHONE));
        let blob2 = s2.seal(&granted);
        assert_eq!(
            AccountState::open(&account_key, &blob2).expect("primary reads device update").get("pin:home"),
            Some(&b"1"[..])
        );

        // A DIFFERENT device (not the grant recipient) cannot open the grant — it is device-scoped.
        let stranger = Identity::from_seed(&[3u8; 32]);
        assert!(
            open_self_sync_key(&stranger, &account.public(), &grant).is_err(),
            "a grant sealed to one device bundle is not openable by another"
        );
    }
}
