//! Key packages — a device's own leaf key and a ONE-TIME Welcome key
//! (`docs/formal/PROTOCOL-SPEC.md` §12 F-b/F-c, §16).
//!
//! In the first tree wiring the committer chose every device's leaf secret and wrapped each
//! Welcome to the device's long-term KEM key. Both tie tree secrecy to things that outlive an
//! epoch: the committer knows every leaf secret, and a recorded Welcome opens for as long as
//! the device's long-term key exists. A key package removes both:
//!
//!   * the DEVICE draws its own leaf secret and publishes only the public leaf key, with a
//!     device-signed binding, so no one else ever holds the leaf secret;
//!   * the DEVICE draws a throwaway *init identity* from a random seed and publishes its public
//!     bundle. A Welcome is sealed to that bundle with the ordinary [`crate::social::seal_bytes`]
//!     rail, and the device deletes the seed once it has joined. After that, nothing the device
//!     still holds — long-term seed included — opens the Welcome.
//!
//! The init key is a full [`Identity`] rather than a bare KEM key on purpose: it lets the
//! Welcome reuse the audited seal/open path unchanged instead of adding a second hybrid-KEM
//! code path. Only its KEM half is ever used.
//!
//! PURE, like `treekem.rs`: no engine state. Randomness enters only through
//! [`KeyPackage::generate`]; [`KeyPackage::build`] is deterministic for tests and vectors.

use rand::rngs::OsRng;
use rand::RngCore;

use crate::device::DeviceCredential;
use crate::identity::{HavenId, Identity};
use crate::social::{open_bytes, seal_bytes, Group, SealedEnvelope};
use crate::treekem::{self, LeafNode};
use crate::wire::{lp, Reader, WireTag};
use crate::{CoreError, Result};

/// Signed by the DEVICE over `KEYPACKAGE_DOMAIN ‖ version ‖ lp(group_id) ‖ kp_id ‖ lp(leaf)
/// ‖ lp(init_bundle)`.
pub const KEYPACKAGE_DOMAIN: &[u8] = b"haven-mls-kp-v1";

/// The only key-package version this build writes or accepts.
pub const KEYPACKAGE_VERSION: u8 = 1;

/// Length of the random key-package id.
pub const KP_ID_LEN: usize = 16;

const WIRE: WireTag = WireTag::new(
    "key package: unexpected end of input",
    "key package: length overflow",
    "key package: invalid utf-8",
);

/// A device's signed offer to be added to one circle's tree.
///
/// Wire: `version(1) ‖ lp(group_id) ‖ kp_id(16) ‖ lp(LeafNode) ‖ lp(init_bundle) ‖ lp(sig)`.
/// Terminal: trailing bytes are rejected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyPackage {
    /// The circle this package is for. A package is never valid in another circle.
    pub group_id: Vec<u8>,
    /// Random id. Lets the device match a Welcome to the secrets it kept, and lets a committer
    /// use each package once.
    pub kp_id: [u8; KP_ID_LEN],
    /// The leaf the committer adds verbatim: the device's own leaf public key, its
    /// account-signed credential, and the device-signed leaf binding.
    pub leaf: LeafNode,
    /// The one-time init identity's public bundle ([`HavenId::to_bytes`]), carried opaquely.
    pub init_bundle: Vec<u8>,
    /// Hybrid signature by the DEVICE over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

/// What the device keeps for a published key package. Wiped on drop.
///
/// `init_seed` must be deleted as soon as the device has joined and the fork window on that
/// entry point has closed; `leaf_secret` then lives on only as the device's current leaf
/// secret in its tree state, until its next own Update replaces it.
pub struct KeyPackageSecret {
    pub kp_id: [u8; KP_ID_LEN],
    pub leaf_secret: [u8; 32],
    pub init_seed: [u8; 32],
}

impl Drop for KeyPackageSecret {
    fn drop(&mut self) {
        treekem::wipe_secret(&mut self.leaf_secret);
        treekem::wipe_secret(&mut self.init_seed);
    }
}

impl KeyPackage {
    /// Draw fresh secrets from the OS RNG and build a signed key package for `group_id`.
    pub fn generate(
        device: &Identity,
        credential: &DeviceCredential,
        group_id: &[u8],
    ) -> Result<(Self, KeyPackageSecret)> {
        let mut kp_id = [0u8; KP_ID_LEN];
        let mut leaf_secret = [0u8; 32];
        let mut init_seed = [0u8; 32];
        OsRng.fill_bytes(&mut kp_id);
        OsRng.fill_bytes(&mut leaf_secret);
        OsRng.fill_bytes(&mut init_seed);
        let secret = KeyPackageSecret { kp_id, leaf_secret, init_seed };
        let kp = Self::build(device, credential, group_id, &secret)?;
        Ok((kp, secret))
    }

    /// Deterministic build from caller-supplied secrets (tests, vectors, and re-deriving the
    /// public half from stored secrets).
    pub fn build(
        device: &Identity,
        credential: &DeviceCredential,
        group_id: &[u8],
        secret: &KeyPackageSecret,
    ) -> Result<Self> {
        if credential.device_id() != device.public().node_id_bytes() {
            return Err(CoreError::Crypto("key package: credential is for another device"));
        }
        let leaf_kp = treekem::node_keypair_from_path_secret(&secret.leaf_secret);
        let binding = treekem::leaf_binding_payload(group_id, &leaf_kp.kem_x, &leaf_kp.kem_pq);
        let leaf = LeafNode {
            leaf_kem_x: leaf_kp.kem_x,
            leaf_kem_pq: leaf_kp.kem_pq,
            device_credential: credential.to_bytes(),
            leaf_binding_sig: device.sign(&binding),
        };
        let init_bundle = Identity::from_seed(&secret.init_seed).public().to_bytes();
        let mut kp = Self { group_id: group_id.to_vec(), kp_id: secret.kp_id, leaf, init_bundle, sig: Vec::new() };
        kp.sig = device.sign(&kp.signing_bytes());
        Ok(kp)
    }

    /// The bytes the device signs: everything except the signature, domain-separated.
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(KEYPACKAGE_DOMAIN.len() + 64 + self.init_bundle.len());
        v.extend_from_slice(KEYPACKAGE_DOMAIN);
        self.encode_body(&mut v);
        v
    }

    fn encode_body(&self, out: &mut Vec<u8>) {
        out.push(KEYPACKAGE_VERSION);
        lp(out, &self.group_id);
        out.extend_from_slice(&self.kp_id);
        lp(out, &self.leaf.to_bytes());
        lp(out, &self.init_bundle);
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::new();
        self.encode_body(&mut v);
        lp(&mut v, &self.sig);
        v
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b, WIRE);
        if r.u8()? != KEYPACKAGE_VERSION {
            return Err(CoreError::Encoding("key package: unknown version"));
        }
        let group_id = r.bytes_lp()?.to_vec();
        let kp_id = r.array::<KP_ID_LEN>()?;
        let leaf = LeafNode::from_bytes(r.bytes_lp()?)?;
        let init_bundle = r.bytes_lp()?.to_vec();
        let sig = r.bytes_lp()?.to_vec();
        if !r.done() {
            return Err(CoreError::Encoding("key package: trailing bytes"));
        }
        Ok(Self { group_id, kp_id, leaf, init_bundle, sig })
    }

    /// Content hash of the full signed bytes — a stable handle for "this exact package".
    pub fn hash(&self) -> [u8; 32] {
        *blake3::hash(&self.to_bytes()).as_bytes()
    }

    /// The one-time init identity's public bundle, parsed.
    pub fn init_public(&self) -> Result<HavenId> {
        HavenId::from_bytes(&self.init_bundle)
    }

    /// Verify the whole chain against the PINNED account key and the expected circle:
    /// account → device credential → (device-signed leaf binding, device-signed key package).
    ///
    /// Returns the verified credential so the caller can apply its roster rule (the device
    /// must be currently authorized by that account) — that is engine policy, not checked here.
    pub fn verify(&self, account_pub: &HavenId, group_id: &[u8]) -> Result<DeviceCredential> {
        if self.group_id != group_id {
            return Err(CoreError::Crypto("key package: wrong circle"));
        }
        let cred = verify_leaf(&self.leaf, account_pub, group_id)?;
        cred.device.verify(&self.signing_bytes(), &self.sig)?;
        self.init_public()?;
        Ok(cred)
    }
}

/// Verify a leaf's credential chain and its DEVICE-signed binding to `group_id`: the leaf key
/// was chosen by the device the credential names, for this circle. Used for a key package's
/// leaf and for the leaf a member publishes in its own Update.
pub fn verify_leaf(leaf: &LeafNode, account_pub: &HavenId, group_id: &[u8]) -> Result<DeviceCredential> {
    let cred = DeviceCredential::from_bytes(&leaf.device_credential)?;
    cred.verify(account_pub)?;
    let binding = treekem::leaf_binding_payload(group_id, &leaf.leaf_kem_x, &leaf.leaf_kem_pq);
    cred.device.verify(&binding, &leaf.leaf_binding_sig)?;
    Ok(cred)
}

/// Seal a Welcome payload to a key package's one-time init key. `sender` signs the envelope
/// (the committing device), exactly as for any other sealed bytes.
pub fn seal_welcome(sender: &Identity, kp: &KeyPackage, plaintext: &[u8]) -> Result<SealedEnvelope> {
    let init = kp.init_public()?;
    seal_bytes(sender, &Group::new("mls-welcome-v2", vec![init]), plaintext)
}

/// Open a Welcome sealed to the key package whose secrets are `secret`, verifying the sender.
/// Fails for any other package's secrets — and for this one once `init_seed` is gone.
pub fn open_welcome(secret: &KeyPackageSecret, sender_pub: &HavenId, env: &SealedEnvelope) -> Result<Vec<u8>> {
    open_bytes(&Identity::from_seed(&secret.init_seed), sender_pub, env)
}

/// The secret payload of a v2 Welcome (PROTOCOL-SPEC §16.2), sealed to a key package's one-time
/// init key. It carries NO leaf secret — the joiner drew its own and never sent it anywhere.
///
/// Wire: `commit_hash(32) ‖ epoch(8) ‖ leaf_index(4) ‖ joiner_secret(32) ‖ cth(32) ‖ kp_id(16)
/// ‖ lp(tree_bytes)`. Terminal: trailing bytes are rejected. Wiped on drop.
#[derive(Clone)]
pub struct WelcomeV2 {
    /// The commit this Welcome enters at (the tip the tree and schedule belong to).
    pub commit_hash: [u8; 32],
    pub epoch: u64,
    pub leaf_index: u32,
    pub joiner_secret: [u8; 32],
    /// `confirmed_transcript_hash` at `epoch`.
    pub cth: [u8; 32],
    /// Which of the joiner's key packages the committer used.
    pub kp_id: [u8; KP_ID_LEN],
    /// The full public tree at `epoch` ([`treekem::RatchetTree::to_bytes`]). Always present.
    pub tree_bytes: Vec<u8>,
}

impl Drop for WelcomeV2 {
    fn drop(&mut self) {
        treekem::wipe_secret(&mut self.joiner_secret);
    }
}

impl WelcomeV2 {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(32 + 8 + 4 + 32 + 32 + KP_ID_LEN + 4 + self.tree_bytes.len());
        v.extend_from_slice(&self.commit_hash);
        v.extend_from_slice(&self.epoch.to_le_bytes());
        v.extend_from_slice(&self.leaf_index.to_le_bytes());
        v.extend_from_slice(&self.joiner_secret);
        v.extend_from_slice(&self.cth);
        v.extend_from_slice(&self.kp_id);
        lp(&mut v, &self.tree_bytes);
        v
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b, WIRE);
        let w = Self {
            commit_hash: r.array32()?,
            epoch: r.u64()?,
            leaf_index: r.u32()?,
            joiner_secret: r.array32()?,
            cth: r.array32()?,
            kp_id: r.array::<KP_ID_LEN>()?,
            tree_bytes: r.bytes_lp()?.to_vec(),
        };
        if !r.done() {
            return Err(CoreError::Encoding("welcome v2: trailing bytes"));
        }
        Ok(w)
    }
}

/// Enter a tree through a v2 Welcome. FAILS CLOSED unless the Welcome names this key package
/// and the delivered tree carries, at `leaf_index`, exactly the leaf key this device drew for
/// it — so a device whose leaf was removed (or swapped) in the meantime cannot enter, and a
/// committer cannot seat the device on a key the device does not hold.
///
/// The Welcome is also BOUND TO THE PUBLIC COMMIT it enters at: `commit_bytes` must hash to the
/// Welcome's `commit_hash`, be for this circle and epoch, and claim exactly the delivered tree.
/// So a joiner only ever enters a state the rest of the circle can see and check, never one
/// described by the Welcome alone. That includes the SECRETS: the epoch schedule the Welcome
/// yields must key the commit's confirmation MAC, so a Welcome cannot carry a `joiner_secret` (or
/// transcript hash) other than the one every member at that epoch derived.
///
/// Returns the public tree, the epoch schedule every member at that epoch derives, and the
/// joiner's private state. Pure; the envelope's sender, the commit's signature and the
/// committer's authority are the caller's checks (they need the roster).
pub fn enter_via_welcome_v2(
    secret: &KeyPackageSecret,
    group_id: &[u8],
    welcome: &WelcomeV2,
    commit_bytes: &[u8],
) -> Result<(treekem::RatchetTree, treekem::EpochSchedule, treekem::TreePrivate)> {
    if welcome.kp_id != secret.kp_id {
        return Err(CoreError::Crypto("welcome v2: for another key package"));
    }
    if treekem::commit_hash(commit_bytes) != welcome.commit_hash {
        return Err(CoreError::Crypto("welcome v2: not the commit this welcome names"));
    }
    let commit = treekem::Commit::from_bytes(commit_bytes)?;
    if commit.group_id != group_id || commit.epoch != welcome.epoch {
        return Err(CoreError::Crypto("welcome v2: commit is for another circle or epoch"));
    }
    let tree = treekem::RatchetTree::from_bytes(&welcome.tree_bytes)?;
    if treekem::tree_hash(&tree) != commit.tree_hash {
        return Err(CoreError::Crypto("welcome v2: tree is not the one the commit produced"));
    }
    let leaf = tree.leaf(welcome.leaf_index).ok_or(CoreError::Crypto("welcome v2: leaf absent from tree"))?;
    let mine = treekem::node_keypair_from_path_secret(&secret.leaf_secret);
    if mine.kem_x != leaf.leaf_kem_x || mine.kem_pq[..] != leaf.leaf_kem_pq[..] {
        return Err(CoreError::Crypto("welcome v2: leaf key is not the one this device published"));
    }
    let th = treekem::tree_hash(&tree);
    let schedule = treekem::welcome_epoch_schedule(&welcome.joiner_secret, group_id, welcome.epoch, &th, &welcome.cth);
    // The delivered `joiner_secret` and transcript hash must be the ones the commit was confirmed
    // under: the confirmation MAC in the (signed, public) commit is keyed by this epoch's schedule.
    // Without this a Welcome naming a real commit could seat the joiner in an epoch whose secrets
    // its sender chose — and anyone can seal to the published one-time key.
    if !treekem::ct_eq(&treekem::confirmation_mac(&schedule.confirm_key, &welcome.cth), &commit.confirmation_mac) {
        return Err(CoreError::Crypto("welcome v2: secrets are not the ones the commit confirmed"));
    }
    Ok((tree, schedule, treekem::TreePrivate::new(welcome.leaf_index, secret.leaf_secret)))
}

/// Is `commit` a valid MEMBER UPDATE on `prev_tree` (PROTOCOL-SPEC §16.4)? Any current leaf may
/// author one, so a device can heal itself instead of waiting for the committer.
///
/// Checks, all fail-closed:
///   1. it carries NO proposals and DOES carry an UpdatePath — it changes no membership;
///   2. the sender's leaf exists, and the new leaf names the SAME device and account as the leaf
///      it replaces — a member can re-key only its own leaf;
///   3. the new leaf key actually differs from the old one (an update that keeps the key heals
///      nothing and would only add epoch noise);
///   4. the credential chains to the pinned account key (`account_for`), the leaf binding is
///      signed by that device for this circle, and the commit signature verifies under it.
///
/// Returns the verified credential; the caller still applies its roster rule (the device must be
/// currently authorized). Pure: the tree application itself is [`treekem::apply_commit`].
pub fn verify_member_update(
    prev_tree: &treekem::RatchetTree,
    commit: &treekem::Commit,
    account_for: impl FnOnce(&[u8; 32]) -> Option<HavenId>,
) -> Result<DeviceCredential> {
    if !commit.proposals.is_empty() {
        return Err(CoreError::Crypto("member update: carries proposals"));
    }
    let path = commit.update_path.as_ref().ok_or(CoreError::Crypto("member update: no update path"))?;
    let old = prev_tree.leaf(commit.sender_leaf).ok_or(CoreError::Crypto("member update: sender is not a leaf"))?;
    let old_cred = DeviceCredential::from_bytes(&old.device_credential)?;
    let new_cred = DeviceCredential::from_bytes(&path.leaf_node.device_credential)?;
    if old_cred.device_id() != new_cred.device_id() || old_cred.account_id != new_cred.account_id {
        return Err(CoreError::Crypto("member update: leaf belongs to another device"));
    }
    if old.leaf_kem_x == path.leaf_node.leaf_kem_x && old.leaf_kem_pq[..] == path.leaf_node.leaf_kem_pq[..] {
        return Err(CoreError::Crypto("member update: leaf key unchanged"));
    }
    let account = account_for(&new_cred.account_id).ok_or(CoreError::Crypto("member update: unknown account"))?;
    let cred = verify_leaf(&path.leaf_node, &account, &commit.group_id)?;
    cred.device.verify(&treekem::commit_signing_bytes(commit), &commit.sig)?;
    Ok(cred)
}

#[cfg(test)]
mod tests {
    use super::*;

    const GID: &[u8] = b"kp-test-circle";

    fn seed(tag: u8) -> [u8; 32] {
        *blake3::hash(&[b'k', b'p', tag]).as_bytes()
    }

    struct Fixture {
        account: Identity,
        device: Identity,
        cred: DeviceCredential,
    }

    fn fixture(tag: u8) -> Fixture {
        let account = Identity::from_seed(&seed(tag));
        let device = Identity::from_seed(&seed(tag.wrapping_add(100)));
        let cred = DeviceCredential::issue(&account, &device.public(), "test device", 1_700_000_000);
        Fixture { account, device, cred }
    }

    fn secret(tag: u8) -> KeyPackageSecret {
        let mut kp_id = [0u8; KP_ID_LEN];
        kp_id.copy_from_slice(&seed(tag)[..KP_ID_LEN]);
        KeyPackageSecret { kp_id, leaf_secret: seed(tag.wrapping_add(1)), init_seed: seed(tag.wrapping_add(2)) }
    }

    #[test]
    fn key_package_round_trips_byte_stably_and_verifies() {
        let f = fixture(1);
        let kp = KeyPackage::build(&f.device, &f.cred, GID, &secret(10)).unwrap();
        let bytes = kp.to_bytes();
        let back = KeyPackage::from_bytes(&bytes).unwrap();
        assert_eq!(back, kp);
        assert_eq!(back.to_bytes(), bytes);
        let cred = back.verify(&f.account.public(), GID).unwrap();
        assert_eq!(cred.device_id(), f.device.public().node_id_bytes());
        // The published leaf key is the one the device's own secret derives.
        let pk = treekem::node_keypair_from_path_secret(&secret(10).leaf_secret);
        assert_eq!(kp.leaf.leaf_kem_x, pk.kem_x);
        assert_eq!(kp.leaf.leaf_kem_pq[..], pk.kem_pq[..]);
    }

    #[test]
    fn generate_draws_distinct_secrets_each_time() {
        let f = fixture(2);
        let (a, sa) = KeyPackage::generate(&f.device, &f.cred, GID).unwrap();
        let (b, sb) = KeyPackage::generate(&f.device, &f.cred, GID).unwrap();
        assert_ne!(a.kp_id, b.kp_id);
        assert_ne!(sa.leaf_secret, sb.leaf_secret);
        assert_ne!(sa.init_seed, sb.init_seed);
        assert_ne!(sa.leaf_secret, sa.init_seed);
        assert_ne!(a.init_bundle, b.init_bundle);
        a.verify(&f.account.public(), GID).unwrap();
        b.verify(&f.account.public(), GID).unwrap();
    }

    #[test]
    fn parser_rejects_trailing_bytes_truncation_and_unknown_version() {
        let f = fixture(3);
        let bytes = KeyPackage::build(&f.device, &f.cred, GID, &secret(20)).unwrap().to_bytes();
        let mut trailing = bytes.clone();
        trailing.push(0);
        assert!(KeyPackage::from_bytes(&trailing).is_err());
        for cut in [0, 1, 5, bytes.len() / 2, bytes.len() - 1] {
            assert!(KeyPackage::from_bytes(&bytes[..cut]).is_err(), "prefix {cut} must not parse");
        }
        let mut v2 = bytes.clone();
        v2[0] = 2;
        assert!(KeyPackage::from_bytes(&v2).is_err());
    }

    #[test]
    fn verify_rejects_wrong_circle_wrong_account_and_any_tampered_field() {
        let f = fixture(4);
        let other = fixture(5);
        let kp = KeyPackage::build(&f.device, &f.cred, GID, &secret(30)).unwrap();
        assert!(kp.verify(&f.account.public(), b"another-circle").is_err());
        assert!(kp.verify(&other.account.public(), GID).is_err());

        // Swap in a different one-time key: the device signature no longer covers it.
        let mut t = kp.clone();
        t.init_bundle = Identity::from_seed(&seed(99)).public().to_bytes();
        assert!(t.verify(&f.account.public(), GID).is_err());

        // Swap in a different leaf key (an attacker-chosen one): the leaf binding fails.
        let mut t = kp.clone();
        let evil = treekem::node_keypair_from_path_secret(&seed(98));
        t.leaf.leaf_kem_x = evil.kem_x;
        t.leaf.leaf_kem_pq = evil.kem_pq;
        assert!(t.verify(&f.account.public(), GID).is_err());

        // Change the id or the circle: the package signature fails.
        let mut t = kp.clone();
        t.kp_id[0] ^= 1;
        assert!(t.verify(&f.account.public(), GID).is_err());
        let mut t = kp.clone();
        t.group_id = b"another-circle".to_vec();
        assert!(t.verify(&f.account.public(), b"another-circle").is_err());

        // Garbage where the init bundle should be is refused even before signature checks matter.
        let mut t = kp.clone();
        t.init_bundle = vec![7u8; 12];
        assert!(t.verify(&f.account.public(), GID).is_err());
    }

    #[test]
    fn a_stolen_credential_cannot_be_put_on_another_devices_key_package() {
        // The attacker holds its own device key and a COPY of the victim's public credential.
        let victim = fixture(6);
        let attacker = fixture(7);
        assert!(KeyPackage::build(&attacker.device, &victim.cred, GID, &secret(40)).is_err());
        // Forcing the bytes together by hand fails verification: the leaf binding and the package
        // signature are checked against the device the credential names.
        let mut forged = KeyPackage::build(&attacker.device, &attacker.cred, GID, &secret(40)).unwrap();
        forged.leaf.device_credential = victim.cred.to_bytes();
        assert!(forged.verify(&victim.account.public(), GID).is_err());
    }

    #[test]
    fn welcome_opens_only_with_that_packages_one_time_secret() {
        let f = fixture(8);
        let committer = Identity::from_seed(&seed(50));
        let s = secret(60);
        let kp = KeyPackage::build(&f.device, &f.cred, GID, &s).unwrap();
        let env = seal_welcome(&committer, &kp, b"joiner secret payload").unwrap();

        assert_eq!(open_welcome(&s, &committer.public(), &env).unwrap(), b"joiner secret payload");
        // A different package's secrets do not open it.
        assert!(open_welcome(&secret(61), &committer.public(), &env).is_err());
        // The device's LONG-TERM key does not open it: this is the whole point of the one-time key.
        assert!(open_bytes(&f.device, &committer.public(), &env).is_err());
        assert!(open_bytes(&f.account, &committer.public(), &env).is_err());
        // A wrong claimed sender is refused.
        assert!(open_welcome(&s, &f.device.public(), &env).is_err());
    }

    #[test]
    fn verify_leaf_accepts_a_members_own_updated_leaf_and_rejects_a_foreign_binding() {
        let f = fixture(9);
        let other = fixture(11);
        let fresh = treekem::node_keypair_from_path_secret(&seed(70));
        let payload = treekem::leaf_binding_payload(GID, &fresh.kem_x, &fresh.kem_pq);
        let mut leaf = LeafNode {
            leaf_kem_x: fresh.kem_x,
            leaf_kem_pq: fresh.kem_pq,
            device_credential: f.cred.to_bytes(),
            leaf_binding_sig: f.device.sign(&payload),
        };
        assert!(verify_leaf(&leaf, &f.account.public(), GID).is_ok());
        assert!(verify_leaf(&leaf, &f.account.public(), b"another-circle").is_err());
        leaf.leaf_binding_sig = other.device.sign(&payload);
        assert!(verify_leaf(&leaf, &f.account.public(), GID).is_err());
    }

    // ── End to end at the primitive layer: genesis from key packages, v2 Welcome, member update ──

    struct Member {
        f: Fixture,
        secret: KeyPackageSecret,
        kp: KeyPackage,
    }

    fn member(tag: u8) -> Member {
        let f = fixture(tag);
        let secret = secret(tag.wrapping_add(50));
        let kp = KeyPackage::build(&f.device, &f.cred, GID, &secret).unwrap();
        Member { f, secret, kp }
    }

    fn welcome_for(build: &treekem::CommitBuild, leaf_index: u32, kp: &KeyPackage) -> WelcomeV2 {
        WelcomeV2 {
            commit_hash: treekem::commit_hash(&build.commit.to_bytes()),
            epoch: build.commit.epoch,
            leaf_index,
            joiner_secret: build.schedule.joiner_secret,
            cth: build.confirmed_transcript_hash,
            kp_id: kp.kp_id,
            tree_bytes: build.tree.to_bytes(),
        }
    }

    /// Genesis over three members' key packages. Returns the commit build and each member's
    /// starting private state + schedule, with B and C entering ONLY through their Welcome.
    fn genesis(ms: &[Member]) -> (treekem::CommitBuild, Vec<(treekem::TreePrivate, treekem::EpochSchedule)>) {
        let creator = &ms[0];
        let adds: Vec<treekem::Proposal> = ms
            .iter()
            .enumerate()
            .map(|(i, m)| {
                // The committer verifies every package before using its leaf verbatim.
                m.kp.verify(&m.f.account.public(), GID).unwrap();
                treekem::build_add_proposal(GID, 0, i as u32, m.kp.leaf.clone(), |b| creator.f.device.sign(b))
            })
            .collect();
        let build = treekem::build_commit(
            &treekem::RatchetTree { slots: vec![] }, GID, 1, seed(200), &seed(201), &seed(202), 0, adds, None,
            |b| creator.f.device.sign(b), |b| creator.f.device.sign(b),
        )
        .unwrap();
        let th = treekem::tree_hash(&build.tree);
        let mut out = Vec::new();
        for (i, m) in ms.iter().enumerate() {
            let joiner_secret = if i == 0 {
                build.schedule.joiner_secret
            } else {
                // The Welcome carries the joiner secret and NO leaf secret.
                let w = welcome_for(&build, i as u32, &m.kp);
                let env = seal_welcome(&creator.f.device, &m.kp, &w.to_bytes()).unwrap();
                let pt = open_welcome(&m.secret, &creator.f.device.public(), &env).unwrap();
                let w = WelcomeV2::from_bytes(&pt).unwrap();
                let (tree, sched, private) =
                    enter_via_welcome_v2(&m.secret, GID, &w, &build.commit.to_bytes()).unwrap();
                assert_eq!(treekem::tree_hash(&tree), th);
                out.push((private, sched));
                continue;
            };
            let sched = treekem::welcome_epoch_schedule(&joiner_secret, GID, 1, &th, &build.confirmed_transcript_hash);
            out.push((treekem::TreePrivate::new(i as u32, m.secret.leaf_secret), sched));
        }
        (build, out)
    }

    #[test]
    fn genesis_from_key_packages_then_a_member_update_converges_for_everyone() {
        let ms = [member(21), member(22), member(23)];
        let (g, states) = genesis(&ms);
        for (_, sched) in &states {
            assert_eq!(sched.epoch_secret, g.schedule.epoch_secret, "every member reaches epoch 1");
        }
        let tip = treekem::commit_hash(&g.commit.to_bytes());

        // Member B (leaf 1, NOT the committer) re-keys its own leaf.
        let b = &ms[1];
        let upd = treekem::build_commit(
            &g.tree, GID, 2, tip, &g.confirmed_transcript_hash, &states[1].1.init_secret, 1, vec![],
            Some((&seed(210), &b.f.cred.to_bytes(), &seed(211))),
            |m| b.f.device.sign(m), |m| b.f.device.sign(m),
        )
        .unwrap();

        let accounts = |id: &[u8; 32]| ms.iter().map(|m| m.f.account.public()).find(|a| a.node_id_bytes() == *id);
        let cred = verify_member_update(&g.tree, &upd.commit, accounts).unwrap();
        assert_eq!(cred.device_id(), b.f.device.public().node_id_bytes());

        for i in [0usize, 2] {
            let a = treekem::apply_commit(
                &g.tree, GID, &g.confirmed_transcript_hash, &states[i].1.init_secret, &upd.commit, Some(&states[i].0),
            )
            .unwrap();
            assert_eq!(a.schedule.unwrap().epoch_secret, upd.schedule.epoch_secret, "member {i} follows B's update");
        }
        assert_ne!(upd.schedule.epoch_secret, g.schedule.epoch_secret);
    }

    #[test]
    fn member_update_is_refused_for_another_devices_leaf_and_for_membership_changes() {
        let ms = [member(31), member(32), member(33)];
        let (g, states) = genesis(&ms);
        let tip = treekem::commit_hash(&g.commit.to_bytes());
        let accounts = |id: &[u8; 32]| ms.iter().map(|m| m.f.account.public()).find(|a| a.node_id_bytes() == *id);
        let (b, c) = (&ms[1], &ms[2]);

        // C tries to replace B's leaf (leaf 1) with a key C controls, under C's own credential.
        let hijack = treekem::build_commit(
            &g.tree, GID, 2, tip, &g.confirmed_transcript_hash, &states[2].1.init_secret, 1, vec![],
            Some((&seed(220), &c.f.cred.to_bytes(), &seed(221))),
            |m| c.f.device.sign(m), |m| c.f.device.sign(m),
        )
        .unwrap();
        assert!(verify_member_update(&g.tree, &hijack.commit, accounts).is_err());

        // C tries again carrying B's (public) credential, but can only sign with C's key.
        let forged = treekem::build_commit(
            &g.tree, GID, 2, tip, &g.confirmed_transcript_hash, &states[2].1.init_secret, 1, vec![],
            Some((&seed(222), &b.f.cred.to_bytes(), &seed(223))),
            |m| c.f.device.sign(m), |m| c.f.device.sign(m),
        )
        .unwrap();
        assert!(verify_member_update(&g.tree, &forged.commit, accounts).is_err());

        // A real update by B whose commit signature was then swapped for C's.
        let mut resigned = treekem::build_commit(
            &g.tree, GID, 2, tip, &g.confirmed_transcript_hash, &states[1].1.init_secret, 1, vec![],
            Some((&seed(224), &b.f.cred.to_bytes(), &seed(225))),
            |m| b.f.device.sign(m), |m| b.f.device.sign(m),
        )
        .unwrap()
        .commit;
        assert!(verify_member_update(&g.tree, &resigned, accounts).is_ok());
        resigned.sig = c.f.device.sign(&treekem::commit_signing_bytes(&resigned));
        assert!(verify_member_update(&g.tree, &resigned, accounts).is_err());

        // A commit that removes someone is not a member update, whoever signs it.
        let rm = treekem::build_remove_proposal(GID, 2, 1, 2, |m| b.f.device.sign(m));
        let removal = treekem::build_commit(
            &g.tree, GID, 2, tip, &g.confirmed_transcript_hash, &states[1].1.init_secret, 1, vec![rm],
            Some((&seed(226), &b.f.cred.to_bytes(), &seed(227))),
            |m| b.f.device.sign(m), |m| b.f.device.sign(m),
        )
        .unwrap();
        assert!(verify_member_update(&g.tree, &removal.commit, accounts).is_err());

        // An "update" that keeps the same leaf key is refused.
        let same = treekem::build_commit(
            &g.tree, GID, 2, tip, &g.confirmed_transcript_hash, &states[1].1.init_secret, 1, vec![],
            Some((&b.secret.leaf_secret, &b.f.cred.to_bytes(), &seed(228))),
            |m| b.f.device.sign(m), |m| b.f.device.sign(m),
        )
        .unwrap();
        assert!(verify_member_update(&g.tree, &same.commit, accounts).is_err());

        // An account the verifier has not pinned is refused.
        let ok = treekem::build_commit(
            &g.tree, GID, 2, tip, &g.confirmed_transcript_hash, &states[1].1.init_secret, 1, vec![],
            Some((&seed(229), &b.f.cred.to_bytes(), &seed(230))),
            |m| b.f.device.sign(m), |m| b.f.device.sign(m),
        )
        .unwrap();
        assert!(verify_member_update(&g.tree, &ok.commit, |_| None).is_err());
    }

    #[test]
    fn welcome_v2_round_trips_and_entry_fails_closed() {
        let ms = [member(41), member(42), member(43)];
        let (g, _) = genesis(&ms);
        let b = &ms[1];
        let w = welcome_for(&g, 1, &b.kp);
        let bytes = w.to_bytes();
        assert_eq!(WelcomeV2::from_bytes(&bytes).unwrap().to_bytes(), bytes);
        let mut trailing = bytes.clone();
        trailing.push(0);
        assert!(WelcomeV2::from_bytes(&trailing).is_err());
        assert!(WelcomeV2::from_bytes(&bytes[..bytes.len() - 1]).is_err());

        let cb = g.commit.to_bytes();
        assert!(enter_via_welcome_v2(&b.secret, GID, &w, &cb).is_ok());
        // Seated at someone else's leaf: the key there is not the one B published.
        let mut wrong_leaf = w.clone();
        wrong_leaf.leaf_index = 2;
        assert!(enter_via_welcome_v2(&b.secret, GID, &wrong_leaf, &cb).is_err());
        // Names a different key package.
        let mut wrong_kp = w.clone();
        wrong_kp.kp_id[0] ^= 1;
        assert!(enter_via_welcome_v2(&b.secret, GID, &wrong_kp, &cb).is_err());
        // A tree the named commit did not produce (here: B's leaf removed) is refused.
        let mut tree = g.tree.clone();
        treekem::remove_leaf(&mut tree, 1).unwrap();
        let mut swapped = w.clone();
        swapped.tree_bytes = tree.to_bytes();
        assert!(enter_via_welcome_v2(&b.secret, GID, &swapped, &cb).is_err());
        // Another member's secrets cannot use B's Welcome.
        assert!(enter_via_welcome_v2(&ms[2].secret, GID, &w, &cb).is_err());
        // The Welcome must name the commit it is checked against, in this circle, at this epoch.
        let mut other_commit = g.commit.clone();
        other_commit.epoch = 2;
        assert!(enter_via_welcome_v2(&b.secret, GID, &w, &other_commit.to_bytes()).is_err());
        let mut renamed = w.clone();
        renamed.commit_hash = treekem::commit_hash(&other_commit.to_bytes());
        assert!(enter_via_welcome_v2(&b.secret, GID, &renamed, &other_commit.to_bytes()).is_err());
        assert!(enter_via_welcome_v2(&b.secret, b"another-circle", &w, &cb).is_err());
        assert!(enter_via_welcome_v2(&b.secret, GID, &w, &cb[..cb.len() - 1]).is_err());
        // Secrets the commit did not confirm: a joiner secret (or transcript hash) of the sender's
        // choosing is refused, even though every public field still matches the commit.
        let mut chosen = w.clone();
        chosen.joiner_secret = seed(250);
        assert!(enter_via_welcome_v2(&b.secret, GID, &chosen, &cb).is_err());
        let mut wrong_cth = w.clone();
        wrong_cth.cth = seed(251);
        assert!(enter_via_welcome_v2(&b.secret, GID, &wrong_cth, &cb).is_err());
    }
}
