//! Version 2 of the circle tree (docs/formal/PROTOCOL-SPEC.md §12 F-b/F-c, §16;
//! docs/formal/STAGE3-V2-TREE.md).
//!
//! The v1 tree has the committer choose every device's leaf secret and wrap each Welcome to the
//! device's long-term key. Here every device draws its OWN leaf secret and publishes a signed key
//! package; a Welcome is sealed to that package's ONE-TIME key and carries no leaf secret; and the
//! genesis init, every leaf secret and all path entropy come from the OS RNG. The device's
//! long-term key only signs.
//!
//! The chain machinery is shared with the v1 tree — a v2 tree is a [`ShadowTree`] with `is_v2`
//! set, kept in `NetState::v2_trees`, walked by the same `mls_replay` and checkpointed by the same
//! stage-1 pass. What is different lives in this file:
//!
//!   * its own wire tags (`TAG_MLS2_*`), so a build that only speaks the v1 tree never parses one;
//!   * key packages: minted, published, verified, used once ([`emit_bundle`], [`receive`]);
//!   * the genesis and every Add take leaves VERBATIM from key packages; re-entry of a device that
//!     lost its place is `Remove(old leaf) + Add(fresh package)` in one commit;
//!   * every commit is checked when it is stored against the PUBLIC tree it extends
//!     ([`public_state`]) — signer, authority, each added leaf's own device signature;
//!   * a Welcome is accepted only against the stored public commit it names;
//!   * the migration: the v1 tree keeps keying content until the v2 tree is all-joined, and only
//!     then is the v1 tree wiped ([`refresh`]).
//!   * member updates (§16.4, docs/formal/STAGE4-MEMBER-UPDATES.md): EVERY device re-keys its own
//!     leaf — accepted from any current leaf ([`check_commit`]), authored on the weekly chokepoint
//!     with a per-device offset and re-issued when it lost a fork ([`member_update`]);
//!   * a commit whose confirmation MAC fails for a device that opened its path is VOID for every
//!     device holding that epoch, and is never selected ([`note_void`]).

use super::*;
use haven_p2p::keypackage::{self, KeyPackage, KeyPackageSecret, WelcomeV2, KP_ID_LEN};
use std::collections::{BTreeMap, BTreeSet};

/// Domain of the v2 genesis parent hash / base transcript hash (never the v1 strings).
pub(crate) const GENESIS_PARENT_DOMAIN: &[u8] = b"haven-mls-genesis-parent-v2";
const GENESIS_CTH_DOMAIN: &[u8] = b"haven-mls-genesis-cth-v2";
/// Domain of the v2 join ack: `domain ‖ entry commit hash ‖ device id`.
const JOIN_DOMAIN: &[u8] = b"haven-mls-join-v2";

/// Key packages kept per other device (the newest ones; a device publishes one at a time).
const KEEP_PACKAGES_PER_DEVICE: usize = 3;
/// My own key packages' secrets kept at most (the newest ones).
const KEEP_OWN_PACKAGES: usize = 6;
/// Join acks remembered per device (one per entry; a device re-enters rarely).
const KEEP_ACKS_PER_DEVICE: usize = 4;
/// Commits held whose parent has not arrived (a Welcome may name one as its entry point).
const KEEP_ORPHANS: usize = 16;
/// Domain of the per-device offset added to the weekly Update window.
const UPDATE_JITTER_DOMAIN: &[u8] = b"haven-mls-update-jitter-v1";
/// The per-device offset is below this many seconds (24 h).
pub(crate) const UPDATE_JITTER_SECS: u64 = 24 * 60 * 60;
/// A device authors no Update on a tip that ends a run of this many commits of its own. A branch
/// only one device ever wrote to therefore never reaches [`KEYING_FINAL_DEPTH`], the depth at which
/// the fork rule makes it final and the device checkpoints past the fork point: a device cut off
/// from the circle for weeks cannot, by its own Updates alone, grow a branch it can no longer leave.
pub(crate) const MAX_OWN_RUN: usize = KEYING_FINAL_DEPTH - 1;

/// Own leaf keys remembered (the newest ones).
const KEEP_OWN_KEYS: usize = 8;
/// Domain of the delay before a device that is not a committer re-enters another device.
const REENTRY_DOMAIN: &[u8] = b"haven-mls-reentry-v1";
/// A non-committer waits this long, plus a per-(device, package) offset below
/// [`REENTRY_SPREAD_SECS`], before it re-enters a device whose package it holds: the committer
/// acts at once and normally gets there first.
const REENTRY_WAIT_SECS: u64 = 60 * 60;
const REENTRY_SPREAD_SECS: u64 = 6 * 60 * 60;
/// A device seated under a key package it holds waits this long for the Welcome before it takes
/// it for lost and asks to be seated again under a fresh package. A Welcome normally arrives in
/// the bundle that carries its commit; one that never does (its author lost its state, a mailbox
/// dropped it) would otherwise leave the device waiting for good, and the circle parked with it.
const WELCOME_WAIT_SECS: u64 = 60 * 60;

/// The weight of a chain of commits: `(authority, length)`, compared in that order.
type Weight = (u32, u32);

/// [`chain_index`]'s answer, with the (commit set size, void set size) it was computed for.
type IndexMemo = ((usize, usize), std::sync::Arc<ChainIndex>);

/// Of a commit: (its author's account, how many chained commits ending at it that account authored
/// in a row, the account that built the genesis it hangs off).
type Run = (Option<[u8; 32]>, u32, Option<[u8; 32]>);

/// One seat of a tree: (device, leaf index, account, leaf key id).
type Seat = ([u8; 32], u32, [u8; 32], [u8; 32]);

/// What the fork rule reads, computed once per (commit set, void set): for every commit that is
/// not void, the weight of the heaviest chain that starts at it, and its children.
#[derive(Default)]
pub(crate) struct ChainIndex {
    weight: HashMap<[u8; 32], Weight>,
    children: HashMap<[u8; 32], Vec<[u8; 32]>>,
}

/// A commit this device authored. Every commit re-keys its author's own leaf, so each of these
/// installed a leaf key for me — which only counts on a chain that carries it (PROTOCOL-SPEC §15,
/// FK4/FK5): my Update window is counted from the entry whose key is at my leaf on my tip.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) struct OwnUpdate {
    /// Id of the leaf key the commit installed for me ([`leaf_key_of`]). Public.
    leaf_key: [u8; 32],
    commit: [u8; 32],
    epoch: u64,
    /// When I authored it (unix seconds).
    at: u64,
}

/// One of MY key packages: the secrets only this device holds, and the signed bytes it publishes
/// (kept so every bundle re-emits the same bytes).
pub(crate) struct KpEntry {
    secret: KeyPackageSecret,
    wire: Vec<u8>,
}

impl KpEntry {
    fn leaf_key(&self) -> [u8; 32] {
        let kp = treekem::node_keypair_from_path_secret(&self.secret.leaf_secret);
        leaf_key_of(&kp.kem_x, &kp.kem_pq[..])
    }
}

/// The public facts of the chain at one commit, computed without any secret.
#[derive(Clone)]
pub(crate) struct PublicState {
    epoch: u64,
    tree: treekem::RatchetTree,
    /// Devices Removed along this chain and not Added again since (removal is sticky).
    removed: HashSet<[u8; 32]>,
    /// Every leaf key an Add on this chain has used: a key package is good for one Add.
    added: HashSet<[u8; 32]>,
    /// The commit that (last) Added each device — what that device's join ack must name.
    added_at: HashMap<[u8; 32], [u8; 32]>,
    /// Computed from the genesis, so `removed` / `added` / `added_at` are the chain's whole
    /// history. `false` when it starts at an entry point with the chain below not held.
    complete: bool,
}

/// [`canonical`]'s answer: the agreed tip and its public state, `None` while no genesis is held.
type CanonicalTip = Option<([u8; 32], PublicState)>;

/// What only a version-2 tree holds.
#[derive(Default)]
pub(crate) struct V2State {
    /// Verified key packages of OTHER devices, by device id, oldest first.
    key_packages: BTreeMap<[u8; 32], Vec<Vec<u8>>>,
    /// My own key packages, oldest first. The last is the one I publish.
    kp_secrets: Vec<KpEntry>,
    /// The key package my current place in the tree came from.
    entered_kp: Option<[u8; KP_ID_LEN]>,
    /// The commit my current place in the tree came from (what my join ack names when the chain
    /// below my entry point is not held).
    entered_commit: Option<[u8; 32]>,
    /// Join acks: device → the entry commits it has acked.
    joined_at: BTreeMap<[u8; 32], Vec<[u8; 32]>>,
    /// This circle's v2 tree has keyed content, and its v1 tree was wiped then.
    retired_v1: bool,
    /// When the leaf key of my current seat was drawn into the tree: the moment I entered (unix
    /// seconds). The start of my Update window until an Update of mine is adopted. 0 = not known
    /// (a state saved before member updates): the window starts at the first check.
    leaf_at: u64,
    /// The last commits I authored, oldest first — see [`OwnUpdate`]. At most [`KEEP_OWN_KEYS`].
    own_keys: Vec<OwnUpdate>,
    /// The agreed chain seats me under this leaf key — one of my own packages — and I cannot
    /// derive it: (leaf key id, when I first saw that). I am waiting for the Welcome; see
    /// [`WELCOME_WAIT_SECS`]. Persisted, so the wait survives a relaunch. Public.
    seat_wait: Option<([u8; 32], u64)>,
    /// When I first saw each key package of another device (by hash of its bytes). Session only:
    /// after a load the clock starts again.
    kp_seen: HashMap<[u8; 32], u64>,
    /// [`chain_index`]'s answer for a commit set and a void set of these sizes. Session only.
    index_memo: Mutex<Option<IndexMemo>>,
    /// Commits that passed every public check but whose confirmation MAC failed for me after I
    /// opened their path secret: void for every device holding that epoch, never selected by the
    /// fork rule. Public hashes; persisted, because once my checkpoint has passed the parent epoch
    /// I can no longer re-derive the verdict.
    void: BTreeSet<[u8; 32]>,
    /// Commits whose parent I do not hold yet. Session only: they also sit in `pending_tree`.
    orphans: BTreeMap<[u8; 32], Vec<u8>>,
    /// My signed join ack, by the entry commit it names. Session only.
    join_wire: Option<([u8; 32], Vec<u8>)>,
    /// [`public_state`] answers by tip. A tip's public state computed from the genesis never
    /// changes; one computed from an entry point (the chain below not held) is only good until
    /// more commits arrive — the missing chain may be among them — so each answer carries the size
    /// of the commit set it was computed from. Session only.
    public_memo: Mutex<HashMap<[u8; 32], (PublicState, usize)>>,
    /// [`canonical`]'s answer for a commit set and a void set of these sizes (both only grow).
    /// Session only.
    canon_memo: Mutex<Option<((usize, usize), CanonicalTip)>>,
}

// ── Void commits ───────────────────────────────────────────────────────────────────────────────

/// Is `hash` a commit this device found void? Always false on a v1 tree (its set stays empty).
pub(crate) fn is_void(shadow: &ShadowTree, hash: &[u8; 32]) -> bool {
    shadow.x.void.contains(hash)
}

/// Record the commits a replay found void (`replay_walk`), so the fork rule and the public view
/// ([`canonical`]) skip them from now on — also after the checkpoint has passed their parent.
pub(crate) fn note_void(shadow: &mut ShadowTree, void: &[[u8; 32]]) {
    for h in void {
        if shadow.commits.contains_key(h) {
            shadow.x.void.insert(*h);
        }
    }
}

// ── The fork rule ──────────────────────────────────────────────────────────────────────────────

/// Is this commit an AUTHORITY commit: does it Remove a leaf that is not its author's own, whose
/// device it does not Add back, and that the author could only remove with authority — a leaf of
/// ANOTHER account, or any leaf when the author is of the account that built the genesis (the
/// creator revoking one of its own devices)? A re-entry (`Remove(L) + Add(same device)`), a
/// path-only Update, an Add and a member's leave of its own account's leaves are not.
///
/// Only an admin can author one (`check_commit` refuses anything else when it is stored), so a
/// member that is being removed cannot produce one, with however many devices.
fn is_authority(shadow: &ShadowTree, c: &treekem::Commit) -> bool {
    let removes: Vec<u32> = c
        .proposals
        .iter()
        .filter_map(|p| match &p.body {
            treekem::ProposalBody::Remove { leaf_index } if *leaf_index != c.sender_leaf => Some(*leaf_index),
            _ => None,
        })
        .collect();
    if removes.is_empty() {
        return false;
    }
    let Some(prev) = public_state(shadow, &c.parent_commit_hash) else { return false };
    let ids = |li: u32| prev.tree.leaf(li).and_then(|l| leaf_credential_ids(&l.device_credential));
    let Some((_, author_account)) = ids(c.sender_leaf) else { return false };
    let creator = keying_genesis_of(shadow, c.parent_commit_hash)
        .and_then(|g| treekem::Commit::from_bytes(shadow.commits.get(&g)?).ok())
        .and_then(|g| genesis_author_account(&g));
    let added: HashSet<[u8; 32]> = c
        .proposals
        .iter()
        .filter_map(|p| match &p.body {
            treekem::ProposalBody::Add { leaf_node } => leaf_credential_ids(&leaf_node.device_credential).map(|(d, _)| d),
            _ => None,
        })
        .collect();
    removes.into_iter().filter_map(ids).any(|(device, account)| {
        !added.contains(&device) && (account != author_account || creator == Some(author_account))
    })
}

/// The account of the device that authored a genesis (the leaf at `sender_leaf` among its Adds).
fn genesis_author_account(c: &treekem::Commit) -> Option<[u8; 32]> {
    let mut li = 0u32;
    for p in &c.proposals {
        if let treekem::ProposalBody::Add { leaf_node } = &p.body {
            if li == c.sender_leaf {
                return leaf_credential_ids(&leaf_node.device_credential).map(|(_, a)| a);
            }
            li += 1;
        }
    }
    None
}

/// The weights and children of every commit that is not void — one bottom-up pass over the commit
/// set, memoized until the commit set or the void set grows.
fn chain_index(shadow: &ShadowTree) -> std::sync::Arc<ChainIndex> {
    let key = (shadow.commits.len(), shadow.x.void.len());
    {
        let memo = shadow.x.index_memo.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, hit)) = memo.as_ref() {
            if *at == key {
                return hit.clone();
            }
        }
    }
    let mut parsed: Vec<([u8; 32], treekem::Commit)> = shadow
        .commits
        .iter()
        .filter(|(h, _)| !shadow.x.void.contains(*h))
        .filter_map(|(h, b)| Some((*h, treekem::Commit::from_bytes(b).ok()?)))
        .collect();
    let epoch_of: HashMap<[u8; 32], u64> = parsed.iter().map(|(h, c)| (*h, c.epoch)).collect();
    // Parents before children: for every commit, how many chained commits ending at it were
    // authored in a row by the same ACCOUNT, and the account that built the genesis it hangs off.
    parsed.sort_by_key(|(_, c)| c.epoch);
    let mut runs: HashMap<[u8; 32], Run> = HashMap::new();
    for (h, c) in &parsed {
        let author = committer_account(c);
        let above = (epoch_of.get(&c.parent_commit_hash) == Some(&(c.epoch.wrapping_sub(1))))
            .then(|| runs.get(&c.parent_commit_hash))
            .flatten();
        let entry = match above {
            Some((prev_author, n, creator)) => {
                (author, if author.is_some() && *prev_author == author { n + 1 } else { 1 }, *creator)
            }
            None => (author, 1, (c.epoch == 1).then(|| genesis_author_account(c)).flatten()),
        };
        runs.insert(*h, entry);
    }
    // Children before parents.
    parsed.reverse();
    let mut index = ChainIndex::default();
    for (h, c) in &parsed {
        let below = index
            .children
            .get(h)
            .and_then(|cs| cs.iter().filter_map(|k| index.weight.get(k)).max().copied())
            .unwrap_or((0, 0));
        let own = is_authority(shadow, c) as u32;
        // LENGTH IS CAPPED PER ACCOUNT. A commit adds to its chain's length only while it is one
        // of the first [`MAX_OWN_RUN`] in a row by its author's account (any of its devices) —
        // unless it is an authority commit, or its author is of the account that built the
        // genesis. Length costs an author nothing, so uncapped a member with a modified client
        // could, from any old fork point, author a chain longer than the one the circle is on and
        // leave every device that had checkpointed past that point unable to follow. Capped, one
        // account can stretch a branch by at most `MAX_OWN_RUN` commits, and every checkpoint is
        // that far behind its device's tip: a fork one account can win is a fork every device can
        // still follow. The commit stays valid and is applied like any other; it only weighs 0.
        let counts = own == 1
            || runs.get(h).is_none_or(|(author, n, creator)| *n as usize <= MAX_OWN_RUN || (author.is_some() && author == creator));
        index.weight.insert(*h, (own + below.0, counts as u32 + below.1));
        // A child is the next epoch of its parent (a genesis hangs off the genesis constant).
        let linked = match epoch_of.get(&c.parent_commit_hash) {
            Some(parent_epoch) => c.epoch == parent_epoch + 1,
            None => true,
        };
        if linked {
            index.children.entry(c.parent_commit_hash).or_default().push(*h);
        }
    }
    let index = std::sync::Arc::new(index);
    *shadow.x.index_memo.lock().unwrap_or_else(|e| e.into_inner()) = Some((key, index.clone()));
    index
}

/// THE v2 FORK RULE (docs/formal/STAGE4-MEMBER-UPDATES.md §5): of the children of `tip` at epoch
/// `next` that are not void (nor in `skip`), the one with the heaviest chain under it — most
/// authority commits, then most commits — and on a tie the larger commit hash.
///
/// A pure function of the public commit set, so devices holding the same commits agree; and the
/// weight of the agreed tip's chain only ever rises as commits arrive. There is no depth at which
/// a branch becomes final: a device whose checkpoint has passed a fork point that the agreed
/// chain later leaves from cannot follow, and re-enters ([`wants_entry`]).
pub(crate) fn best_child(shadow: &ShadowTree, tip: &[u8; 32], next: u64, skip: &[[u8; 32]]) -> Option<([u8; 32], Vec<u8>)> {
    let index = chain_index(shadow);
    let best = index
        .children
        .get(tip)?
        .iter()
        .filter(|h| !skip.contains(*h))
        .filter_map(|h| Some((*index.weight.get(h)?, *h)))
        .max()?
        .1;
    let bytes = shadow.commits.get(&best)?;
    // (`next` is implied by the index for a chained commit; it still guards a genesis.)
    treekem::Commit::from_bytes(bytes).is_ok_and(|c| c.epoch == next).then(|| (best, bytes.clone()))
}

/// A device that enters through a Welcome holds its own leaf secret and nothing above it. The
/// commit that seated it re-keyed its author's direct path and wrapped each new path secret to
/// the entering leaf too — and marked nobody unmerged afterwards. So the secrets of the nodes the
/// two paths share are in the ENTRY COMMIT, and only there: without them the next UpdatePath from
/// a third device, wrapped to one of those nodes, does not open. (While only the committer ever
/// updated, every later path came from the same leaf and delivered them again; with member
/// updates it does not.) Open them here, from the public commit and the device's own leaf secret.
///
/// `k` is the state a Welcome start gives for `tip`. Nothing changes if the commit is not held,
/// has no path, or does not open (the walk then stops where it would have).
pub(crate) fn entry_path_secrets(shadow: &ShadowTree, tip: &[u8; 32], k: &mut KeyingState) {
    let Some(commit) = shadow.commits.get(tip).and_then(|b| treekem::Commit::from_bytes(b).ok()) else { return };
    let (Some(path), Some(mine)) = (commit.update_path.as_ref(), k.my_private.as_mut()) else { return };
    if commit.sender_leaf == mine.leaf_index {
        return;
    }
    // The delivered tree is the commit's result. The path was built on the tree before its merge,
    // which differs only on the author's own direct path — not in the copath resolutions the
    // decryption reads.
    if let Ok(opened) = treekem::decrypt_update_path(&k.tree, &shadow.group_id, commit.epoch, commit.sender_leaf, path, mine) {
        mine.path_secrets.extend(opened.path_secrets);
    }
}

/// The tip every device holding my commit set agrees on ([`canonical`]), without its state.
pub(crate) fn agreed_tip(shadow: &ShadowTree) -> Option<[u8; 32]> {
    canonical(shadow).map(|(tip, _)| tip)
}

/// Record every void commit the walk can find, until a replay finds no new one. Run before any
/// decision that compares my own tip with the agreed one: a void commit on the agreed chain that
/// I have not walked into yet would otherwise make the two differ for one pass.
fn settle_void(shadow: &mut ShadowTree) {
    for _ in 0..8 {
        let (_, _, void) = mls_replay_outcome(shadow, None);
        let before = shadow.x.void.len();
        note_void(shadow, &void);
        if shadow.x.void.len() == before {
            break;
        }
    }
}

/// The void set's share of the replay memo key.
pub(crate) fn digest_void(shadow: &ShadowTree, h: &mut blake3::Hasher) {
    h.update(&(shadow.x.void.len() as u64).to_le_bytes());
    for v in &shadow.x.void {
        h.update(v);
    }
}

fn leaf_key_of(kem_x: &[u8], kem_pq: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(b"haven-mls-leaf-key-id-v1");
    h.update(kem_x);
    h.update(kem_pq);
    *h.finalize().as_bytes()
}

fn leaf_key(leaf: &treekem::LeafNode) -> [u8; 32] {
    leaf_key_of(&leaf.leaf_kem_x, &leaf.leaf_kem_pq[..])
}

fn genesis_cth(gid: &[u8]) -> [u8; 32] {
    shadow_domain_hash(GENESIS_CTH_DOMAIN, gid)
}

/// (leaf index, leaf) of every populated leaf.
fn leaves_of(tree: &treekem::RatchetTree) -> Vec<(u32, &treekem::LeafNode)> {
    tree.slots
        .iter()
        .enumerate()
        .filter_map(|(i, s)| match s {
            treekem::TreeSlot::Leaf(l) if i % 2 == 0 => Some(((i / 2) as u32, l)),
            _ => None,
        })
        .collect()
}

/// The leaf of `device` in `tree`, if it has one.
fn leaf_of_device<'a>(tree: &'a treekem::RatchetTree, device: &[u8; 32]) -> Option<(u32, &'a treekem::LeafNode)> {
    leaves_of(tree)
        .into_iter()
        .find(|(_, l)| leaf_credential_ids(&l.device_credential).map(|(d, _)| d) == Some(*device))
}

// ── Gates ──────────────────────────────────────────────────────────────────────────────────────

/// May this device publish a key package for the circle, and take part in its v2 tree? The v1
/// gates (switch on, every member MLS-capable with a roster, an owned circle), every member ACCOUNT
/// advertising `ml >= 2`, and a device identity to sign with.
///
/// The marker is account-level, so this does NOT say every device runs the v2 tree: a device on an
/// older build never publishes a key package, and without one from every authorized device no
/// genesis is built and nothing ever keys from this tree.
pub(crate) fn gate(st: &NetState, idx: usize) -> bool {
    st.mls_keying
        && st.device.is_some()
        && circle_is_mls_capable(st, idx)
        && circle_mls_accounts(st, idx).iter().all(|a| st.mls2_capable.contains(&a.node_id_bytes()))
        && circle_admin_set(st, idx).is_some()
}

/// Positive evidence that a member account only speaks the v1 tree: it advertised `ml`, and what
/// it advertised was below 2. (An account whose profile has not arrived is unknown, not evidence.)
fn v1_only_evidence(st: &NetState, idx: usize) -> bool {
    circle_mls_accounts(st, idx).iter().any(|a| {
        let id = a.node_id_bytes();
        st.mls_capable.contains(&id) && !st.mls2_capable.contains(&id)
    })
}

/// Has the v2 tree taken this circle over from the v1 tree? Then no v1 genesis is built, no v1
/// wire is emitted and a v1 wire that still arrives is dropped — the v1 tree stays wiped. Ends only
/// on positive evidence of a v1-only member account ([`v1_only_evidence`]); a device without a key
/// package (an older build under an upgraded account) parks the circle on the sender-keys lane
/// instead, exactly as a legacy device joining a v1-keyed circle does.
pub(crate) fn v1_suppressed(st: &NetState, idx: usize) -> bool {
    st.v2_trees.get(&st.circles[idx].id).is_some_and(|t| t.x.retired_v1) && !v1_only_evidence(st, idx)
}

/// Am I a committer on the v2 tree? Same election as the v1 tree: the creator account's devices.
fn am_committer(st: &NetState, idx: usize) -> bool {
    gate(st, idx) && am_shadow_creator(st, idx)
}

fn my_device_id(st: &NetState) -> Option<[u8; 32]> {
    st.device.as_ref().map(|d| d.public().node_id_bytes())
}

/// My own account-signed device credential, if my roster currently authorizes this device.
fn my_credential(st: &NetState) -> Option<DeviceCredential> {
    let me = my_device_id(st)?;
    let cd = st.device_lists.get(&st.me().node_id_bytes())?;
    if !cd.list.is_authorized(&me) {
        return None;
    }
    cd.credentials.iter().find(|c| c.device_id() == me).cloned()
}

// ── The public view of the chain ───────────────────────────────────────────────────────────────

/// The public state a tree this device ENTERED at gives for `tip`, when the chain below is not
/// held: the Welcome's tree, or the checkpoint's. History before it is unknown, so `added` is just
/// the leaf keys present and `added_at` is empty.
fn anchor_state(shadow: &ShadowTree, tip: &[u8; 32]) -> Option<PublicState> {
    let (epoch, tree, removed) = if let Some(w) = shadow.my_welcomes.get(tip).filter(|w| !w.tree_bytes.is_empty()) {
        (w.epoch, treekem::RatchetTree::from_bytes(&w.tree_bytes).ok()?, HashSet::new())
    } else {
        let ck = shadow.checkpoint.as_ref().filter(|ck| ck.state.tip_hash == *tip)?;
        (ck.state.epoch, ck.state.tree.clone(), ck.state.removed_devices.clone())
    };
    let added = leaves_of(&tree).into_iter().map(|(_, l)| leaf_key(l)).collect();
    Some(PublicState { epoch, tree, removed, added, added_at: HashMap::new(), complete: false })
}

/// The public state of a genesis commit: add-only, the tree is exactly its Adds.
fn genesis_public(hash: &[u8; 32], c: &treekem::Commit) -> Option<PublicState> {
    if c.update_path.is_some() {
        return None;
    }
    let mut leaves = Vec::with_capacity(c.proposals.len());
    for p in &c.proposals {
        match &p.body {
            treekem::ProposalBody::Add { leaf_node } => leaves.push(leaf_node.clone()),
            _ => return None,
        }
    }
    let tree = treekem::RatchetTree::from_leaves(leaves);
    if treekem::tree_hash(&tree) != c.tree_hash {
        return None;
    }
    let mut added = HashSet::new();
    let mut added_at = HashMap::new();
    for (_, l) in leaves_of(&tree) {
        added.insert(leaf_key(l));
        if let Some((device, _)) = leaf_credential_ids(&l.device_credential) {
            added_at.insert(device, *hash);
        }
    }
    Some(PublicState { epoch: 1, tree, removed: HashSet::new(), added, added_at, complete: true })
}

/// One step of the public walk: `prev` plus commit `c` (whose hash is `hash`). `None` if the
/// commit does not follow `prev` or does not produce the tree it claims.
fn step_public(gid: &[u8], prev: &PublicState, hash: &[u8; 32], c: &treekem::Commit) -> Option<PublicState> {
    if c.epoch != prev.epoch + 1 {
        return None;
    }
    let mut removed = prev.removed.clone();
    let mut added = prev.added.clone();
    let mut added_at = prev.added_at.clone();
    for p in &c.proposals {
        match &p.body {
            treekem::ProposalBody::Remove { leaf_index } => {
                if let Some((device, _)) =
                    prev.tree.leaf(*leaf_index).and_then(|l| leaf_credential_ids(&l.device_credential))
                {
                    removed.insert(device);
                    added_at.remove(&device);
                }
            }
            treekem::ProposalBody::Add { leaf_node } => {
                added.insert(leaf_key(leaf_node));
                if let Some((device, _)) = leaf_credential_ids(&leaf_node.device_credential) {
                    // Added (back): a re-entry with a fresh key package, or an explicit re-admission.
                    removed.remove(&device);
                    added_at.insert(device, *hash);
                }
            }
            treekem::ProposalBody::Update { .. } => return None, // not used on a v2 chain
        }
    }
    // No private state: the tree is applied and its hash checked; no schedule is derived.
    let applied = treekem::apply_commit(&prev.tree, gid, &[0u8; 32], &[0u8; 32], c, None).ok()?;
    Some(PublicState { epoch: c.epoch, tree: applied.tree, removed, added, added_at, complete: prev.complete })
}

/// The public state at `tip`: the genesis' Adds, then every commit down to `tip` applied without
/// secrets — or, when the chain below is not held (a device that entered mid-chain), from the
/// tree it entered with.
pub(crate) fn public_state(shadow: &ShadowTree, tip: &[u8; 32]) -> Option<PublicState> {
    let parent0 = keying_genesis_parent(shadow);
    let mut memo = shadow.x.public_memo.lock().unwrap_or_else(|e| e.into_inner());
    // Walk back to something known: a memoized state, the genesis, or an entry point.
    let mut path: Vec<([u8; 32], treekem::Commit)> = Vec::new();
    let mut base: Option<PublicState> = None;
    let mut at = *tip;
    loop {
        // An answer that started at an entry point is reused only while the commit set is the
        // one it was computed from: it used to be kept for good, so a device that entered before
        // the chain below reached it went on believing every key package older than its entry
        // was unused, and no device's seat had an entry commit.
        if let Some((hit, _)) = memo.get(&at).filter(|(hit, n)| hit.complete || *n == shadow.commits.len()) {
            base = Some(hit.clone());
            break;
        }
        let Some(c) = shadow.commits.get(&at).and_then(|b| treekem::Commit::from_bytes(b).ok()) else {
            // The chain leaves what I hold: continue from the nearest entry point above the gap.
            let i = path.iter().position(|(h, _)| anchor_state(shadow, h).is_some())?;
            base = anchor_state(shadow, &path[i].0);
            path.truncate(i);
            break;
        };
        let genesis = c.epoch == 1 && c.parent_commit_hash == parent0;
        let parent = c.parent_commit_hash;
        path.push((at, c));
        if genesis || path.len() > 4096 {
            break;
        }
        at = parent;
    }
    let mut cur = base;
    for (h, c) in path.iter().rev() {
        cur = Some(match &cur {
            None => genesis_public(h, c)?,
            Some(prev) => step_public(&shadow.group_id, prev, h, c)?,
        });
    }
    let out = cur?;
    if memo.len() >= 32 {
        memo.clear();
    }
    memo.insert(*tip, (out.clone(), shadow.commits.len()));
    Some(out)
}

/// The tip every device holding the same commits agrees on: from the elected genesis, the fork
/// rule at every step. `None` while no genesis is held.
///
/// It is what a device compares its own (secret-bearing) state against to learn that it cannot
/// follow the chain any more — see [`wants_entry`].
fn canonical(shadow: &ShadowTree) -> CanonicalTip {
    let n = (shadow.commits.len(), shadow.x.void.len());
    {
        let memo = shadow.x.canon_memo.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, hit)) = memo.as_ref() {
            if *at == n {
                return hit.clone();
            }
        }
    }
    let out = (|| {
        let (gh, gbytes) = keying_winning_genesis(shadow)?;
        let gc = treekem::Commit::from_bytes(&gbytes).ok()?;
        let mut tip = gh;
        let mut state = genesis_public(&gh, &gc)?;
        while let Some((h, bytes)) = keying_best_child(shadow, &tip, state.epoch + 1) {
            let Ok(c) = treekem::Commit::from_bytes(&bytes) else { break };
            let Some(next) = step_public(&shadow.group_id, &state, &h, &c) else { break };
            tip = h;
            state = next;
        }
        Some((tip, state))
    })();
    *shadow.x.canon_memo.lock().unwrap_or_else(|e| e.into_inner()) = Some((n, out.clone()));
    out
}

// ── Checks on what other devices send ──────────────────────────────────────────────────────────

enum Refuse {
    /// Can never become valid here.
    Never,
    /// Needs an account bundle or roster I do not hold yet: worth one more try once it lands.
    Later,
}

/// A leaf some device claims as its own: the credential chains to the PINNED account key, the
/// leaf binding is signed by that device for this circle, and the device is currently authorized
/// in the account's verified roster.
fn check_leaf(st: &NetState, idx: usize, leaf: &treekem::LeafNode) -> Result<DeviceCredential, Refuse> {
    let gid = st.circles[idx].id.as_bytes();
    let cred = DeviceCredential::from_bytes(&leaf.device_credential).map_err(|_| Refuse::Never)?;
    let account = mls_account_bundle_ref(st, idx, &cred.account_id).ok_or(Refuse::Later)?;
    let cred = keypackage::verify_leaf(leaf, account, gid).map_err(|_| Refuse::Never)?;
    let authorized =
        st.device_lists.get(&cred.account_id).is_some_and(|cd| cd.list.is_authorized(&cred.device_id()));
    if !authorized {
        return Err(Refuse::Later); // the roster naming this device may be in flight
    }
    Ok(cred)
}

/// The device that authored a commit: the device of its UpdatePath leaf, or — a genesis has no
/// path — of the leaf at `sender_leaf` among its Adds.
fn committer_account(c: &treekem::Commit) -> Option<[u8; 32]> {
    match &c.update_path {
        Some(up) => leaf_credential_ids(&up.leaf_node.device_credential).map(|(_, a)| a),
        None => genesis_author_account(c),
    }
}

fn committer_device(c: &treekem::Commit) -> Option<[u8; 32]> {
    if let Some(up) = &c.update_path {
        return leaf_credential_ids(&up.leaf_node.device_credential).map(|(d, _)| d);
    }
    let mut li = 0u32;
    for p in &c.proposals {
        if let treekem::ProposalBody::Add { leaf_node } = &p.body {
            if li == c.sender_leaf {
                return leaf_credential_ids(&leaf_node.device_credential).map(|(d, _)| d);
            }
            li += 1;
        }
    }
    None
}

/// A v2 genesis: signed by the elected creator (or an admin), add-only, every leaf its own
/// device's, no device twice.
fn check_genesis(st: &NetState, idx: usize, c: &treekem::Commit) -> Result<(), Refuse> {
    if c.update_path.is_some() || c.proposals.is_empty() {
        return Err(Refuse::Never);
    }
    let mut seen = HashSet::new();
    for p in &c.proposals {
        let treekem::ProposalBody::Add { leaf_node } = &p.body else { return Err(Refuse::Never) };
        let cred = check_leaf(st, idx, leaf_node)?;
        if !seen.insert(cred.device_id()) {
            return Err(Refuse::Never);
        }
    }
    if !genesis_signer_authorized(st, idx, c) {
        return Err(Refuse::Later); // the creator's roster may not have landed
    }
    Ok(())
}

/// A chained v2 commit, checked against the public tree `prev` it extends. A commit with no
/// proposals is a MEMBER UPDATE and is valid from any current leaf (see the first branch). A
/// commit that changes membership:
///
///   * it re-keys its author's OWN leaf: the UpdatePath leaf names the device already at
///     `sender_leaf`, is signed by that device, and the commit signature verifies under it;
///   * that device is currently authorized, and its account is an admin — or the commit only
///     removes leaves of its own account (a leave);
///   * every Add is a leaf its own device signed for this circle, for a device that is authorized
///     and not already in the tree, with a leaf key never added on this chain before.
///
/// `standalone` skips the two checks that need the chain BELOW the commit (the author's previous
/// leaf, key reuse): it is how a device entering mid-chain checks the one commit its Welcome names,
/// against the tree that Welcome delivers.
fn check_commit(
    st: &NetState,
    idx: usize,
    c: &treekem::Commit,
    prev: Option<&PublicState>,
) -> Result<(), Refuse> {
    let up = c.update_path.as_ref().ok_or(Refuse::Never)?;
    if let (true, Some(prev)) = (c.proposals.is_empty(), prev) {
        // A MEMBER UPDATE (PROTOCOL-SPEC §16.4): no proposals, so no membership changes, and it
        // is valid from ANY current leaf — admin or not. `verify_member_update` checks that the
        // new leaf names the same device and account as the leaf it replaces, that the leaf key
        // really changes, that the credential chains to the pinned account key, and that the leaf
        // binding and the commit signature verify under that device. The roster rule is ours.
        let gid = st.circles[idx].id.as_bytes();
        if c.group_id != gid {
            return Err(Refuse::Never);
        }
        let claimed = DeviceCredential::from_bytes(&up.leaf_node.device_credential).map_err(|_| Refuse::Never)?;
        let account = mls_account_bundle_ref(st, idx, &claimed.account_id).ok_or(Refuse::Later)?;
        let cred = keypackage::verify_member_update(&prev.tree, c, |_| Some(account.clone())).map_err(|_| Refuse::Never)?;
        // The roster rule is LISTED, not "authorized right now": whether a device's Update is
        // valid must not depend on when a receiver learned of a revocation (a device that learned
        // it first would refuse a commit the rest of the fleet built on, and be left behind for
        // good). A revoked device is cut out by the Remove that follows — an authority commit,
        // which no number of Updates outweighs — not by refusing what it authored while seated.
        let device = cred.device_id();
        let listed = st
            .device_lists
            .get(&cred.account_id)
            .is_some_and(|cd| cd.list.devices.contains(&device) || cd.list.revoked.contains(&device));
        if !listed {
            return Err(Refuse::Later); // the roster naming this device may be in flight
        }
        return Ok(());
    }
    let cred = check_leaf(st, idx, &up.leaf_node)?;
    let device = cred.device_id();
    if cred.device.verify(&treekem::commit_signing_bytes(c), &c.sig).is_err() {
        return Err(Refuse::Never);
    }
    if let Some(prev) = prev {
        let at_sender = prev.tree.leaf(c.sender_leaf).and_then(|l| leaf_credential_ids(&l.device_credential));
        if at_sender != Some((device, cred.account_id)) {
            return Err(Refuse::Never); // a commit may replace only its author's own leaf
        }
    }
    let mut removes: Vec<u32> = Vec::new();
    let mut adds: Vec<&treekem::LeafNode> = Vec::new();
    for p in &c.proposals {
        match &p.body {
            treekem::ProposalBody::Remove { leaf_index } => removes.push(*leaf_index),
            treekem::ProposalBody::Add { leaf_node } => adds.push(leaf_node),
            treekem::ProposalBody::Update { .. } => return Err(Refuse::Never),
        }
    }
    let admin = circle_admin_set(st, idx).is_some_and(|a| a.contains(&cred.account_id));
    if !admin {
        // Not an admin. Two shapes are allowed, both judged against the parent tree — so a
        // device that does not hold it (it is entering through this very commit, with no chain
        // below) waits until it does, rather than take a member's word for what was removed:
        //   * a LEAVE: it removes leaves of its own account and nothing else;
        //   * a RE-ENTRY of other devices: pairs `Remove(L) + Add(leaf)` where the added leaf is
        //     for the SAME device and account as the leaf at L, and L is not the author's own.
        //     Membership is unchanged; each device comes back under the key it published itself.
        //     (The Add checks below still apply: roster-authorized, a package used once.)
        // (A member re-keying just its own leaf carries no proposals and was accepted above.)
        let Some(prev) = prev else { return Err(Refuse::Later) };
        let at = |li: &u32| prev.tree.leaf(*li).and_then(|l| leaf_credential_ids(&l.device_credential));
        let leave = !removes.is_empty() && adds.is_empty() && removes.iter().all(|li| at(li).map(|(_, a)| a) == Some(cred.account_id));
        let removed: Vec<Option<([u8; 32], [u8; 32])>> = removes.iter().map(at).collect();
        let reentry = !removes.is_empty()
            && removes.len() == adds.len()
            && !removes.contains(&c.sender_leaf)
            && removes.iter().collect::<HashSet<_>>().len() == removes.len()
            && adds.iter().all(|leaf| {
                let ids = leaf_credential_ids(&leaf.device_credential);
                ids.is_some() && removed.iter().filter(|r| **r == ids).count() == 1
            });
        if !leave && !reentry {
            return Err(Refuse::Never);
        }
    }
    let mut adding = HashSet::new();
    for leaf in adds {
        let added = check_leaf(st, idx, leaf)?;
        if !adding.insert(added.device_id()) {
            return Err(Refuse::Never);
        }
        if let Some(prev) = prev {
            if prev.added.contains(&leaf_key(leaf)) {
                return Err(Refuse::Never); // a key package is used once
            }
            // Already a leaf, and not removed by this very commit (a re-entry removes it first).
            if let Some((li, _)) = leaf_of_device(&prev.tree, &added.device_id()) {
                if !removes.contains(&li) {
                    return Err(Refuse::Never);
                }
            }
        }
    }
    Ok(())
}

fn refuse(r: Refuse) -> bool {
    if matches!(r, Refuse::Later) {
        TREE_RETRYABLE.with(|f| f.set(true));
    }
    false
}

// ── Receiving ──────────────────────────────────────────────────────────────────────────────────

/// Route one v2 wire. Returns whether it STORED something new (a later parked wire may then fit);
/// a refusal worth retrying sets `TREE_RETRYABLE`, as the v1 handlers do. Inert unless the circle
/// passes [`gate`] — in particular with the keying switch off.
pub(crate) fn receive(st: &mut NetState, idx: usize, tag: u8, body: &[u8]) -> bool {
    if !gate(st, idx) {
        // The switch is on and the circle is owned, but a member's capability or roster is not
        // known (yet — neither is persisted, both re-sync after a launch): worth a retry, because
        // a mailbox does not serve the same bytes twice and nothing re-issues a v2 Welcome. Not
        // when a member is known to speak only the v1 tree: then this can never become valid.
        if st.mls_keying && st.device.is_some() && circle_admin_set(st, idx).is_some() && !v1_only_evidence(st, idx) {
            TREE_RETRYABLE.with(|f| f.set(true));
        }
        return false;
    }
    match tag {
        TAG_MLS2_KEYPACKAGE => receive_key_package(st, idx, body),
        TAG_MLS2_COMMIT => receive_commit(st, idx, body),
        TAG_MLS2_WELCOME => receive_welcome(st, idx, body),
        TAG_MLS2_JOIN => receive_join(st, idx, body),
        _ => false,
    }
}

fn tree_mut<'a>(st: &'a mut NetState, circle_id: &str) -> &'a mut ShadowTree {
    st.v2_trees
        .entry(circle_id.to_string())
        .or_insert_with(|| ShadowTree::new_v2(circle_id.as_bytes().to_vec()))
}

/// A key package from another device: accepted only for THIS circle, with a credential chaining to
/// the pinned account key, from a device authorized in that account's verified roster, with the
/// leaf binding and the package signed by that device — and not one whose leaf this chain already
/// used. A package is an offer; nothing is derived from it until a commit uses it.
fn receive_key_package(st: &mut NetState, idx: usize, body: &[u8]) -> bool {
    let circle_id = st.circles[idx].id.clone();
    let Ok(kp) = KeyPackage::from_bytes(body) else { return false };
    if kp.group_id != circle_id.as_bytes() {
        return false;
    }
    let Ok(cred) = DeviceCredential::from_bytes(&kp.leaf.device_credential) else { return false };
    let device = cred.device_id();
    if Some(device) == my_device_id(st) {
        return false; // my own, echoed back: I hold it with its secrets
    }
    // Already held: nothing to verify again (a device re-emits its package in every bundle).
    if st.v2_trees.get(&circle_id).is_some_and(|t| t.x.key_packages.get(&device).is_some_and(|l| l.iter().any(|w| w == body))) {
        return false;
    }
    let Some(account) = mls_account_bundle_ref(st, idx, &cred.account_id) else {
        return refuse(Refuse::Later);
    };
    if kp.verify(account, circle_id.as_bytes()).is_err() {
        return false;
    }
    if !st.device_lists.get(&cred.account_id).is_some_and(|cd| cd.list.is_authorized(&device)) {
        return refuse(Refuse::Later);
    }
    let shadow = tree_mut(st, &circle_id);
    // Used already on the chain everyone agrees on: a replay of a spent package.
    if canonical(shadow).is_some_and(|(_, s)| s.added.contains(&leaf_key(&kp.leaf))) {
        return false;
    }
    shadow.x.kp_seen.entry(*blake3::hash(body).as_bytes()).or_insert_with(now_secs);
    let list = shadow.x.key_packages.entry(device).or_default();
    if list.len() >= KEEP_PACKAGES_PER_DEVICE {
        list.remove(0);
    }
    list.push(body.to_vec());
    true
}

/// A v2 commit: stored only if it passes [`check_genesis`] / [`check_commit`] against the public
/// tree it extends, and applies to it. A commit whose parent has not arrived is held aside (and
/// retried): a Welcome may name it as an entry point.
fn receive_commit(st: &mut NetState, idx: usize, body: &[u8]) -> bool {
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let Ok(commit) = treekem::Commit::from_bytes(body) else { return false };
    if commit.group_id != gid {
        return false;
    }
    let h = treekem::commit_hash(body);
    if st.v2_trees.get(&circle_id).is_some_and(|t| t.commits.contains_key(&h)) {
        return false;
    }
    let parent0 = shadow_domain_hash(GENESIS_PARENT_DOMAIN, &gid);
    if commit.epoch == 1 && commit.parent_commit_hash == parent0 {
        if let Err(r) = check_genesis(st, idx, &commit) {
            return refuse(r);
        }
        if genesis_public(&h, &commit).is_none() {
            return false;
        }
    } else {
        let prev = st.v2_trees.get(&circle_id).and_then(|t| public_state(t, &commit.parent_commit_hash));
        let Some(prev) = prev else {
            // ORPHAN: its parent (or the chain below it) has not arrived.
            let shadow = tree_mut(st, &circle_id);
            if shadow.x.orphans.len() >= KEEP_ORPHANS && !shadow.x.orphans.contains_key(&h) {
                let oldest = shadow.x.orphans.keys().next().copied();
                if let Some(k) = oldest {
                    shadow.x.orphans.remove(&k);
                }
            }
            shadow.x.orphans.insert(h, body.to_vec());
            return refuse(Refuse::Later);
        };
        if let Err(r) = check_commit(st, idx, &commit, Some(&prev)) {
            return refuse(r);
        }
        if step_public(&gid, &prev, &h, &commit).is_none() {
            return false; // does not apply to the tree it claims to extend
        }
    }
    let shadow = tree_mut(st, &circle_id);
    shadow.x.orphans.remove(&h);
    shadow.commits.insert(h, body.to_vec());
    true
}

/// A v2 Welcome. It opens only with the one-time key of one of MY key packages; it is accepted
/// only against the PUBLIC commit it names — held, checked like any other commit, signed by the
/// device that sealed this Welcome, producing exactly the delivered tree with my own leaf key at
/// my leaf, and confirmed under the delivered secrets (`keypackage::enter_via_welcome_v2`).
fn receive_welcome(st: &mut NetState, idx: usize, body: &[u8]) -> bool {
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let Ok(env) = SealedEnvelope::from_bytes(body) else { return false };
    let sender_hex = env.sender_hex();
    let Some(sender) = resolve_shadow_sender_ref(st, idx, &sender_hex).cloned() else {
        return refuse(Refuse::Later); // roster lag: the sender cannot be verified yet
    };
    let Some(me) = my_device_id(st) else { return false };
    // Fail closed if my own roster no longer authorizes this device (revoked in the meantime).
    if !st.device_lists.get(&st.me().node_id_bytes()).is_some_and(|cd| cd.list.is_authorized(&me)) {
        return false;
    }
    let Some(shadow) = st.v2_trees.get(&circle_id) else { return false };
    // Not for one of my packages (someone else's Welcome sharing the mailbox): terminal.
    let Some((kp_index, plaintext)) = shadow
        .x
        .kp_secrets
        .iter()
        .enumerate()
        .rev()
        .find_map(|(i, e)| keypackage::open_welcome(&e.secret, &sender, &env).ok().map(|pt| (i, pt)))
    else {
        return false;
    };
    let Ok(welcome) = WelcomeV2::from_bytes(&plaintext) else { return false };
    if shadow.my_welcomes.contains_key(&welcome.commit_hash) {
        return false; // already entered here
    }
    // The public commit it names: stored (so already checked against its parent), or held aside
    // as an orphan — then it is checked standalone, against the tree this Welcome delivers.
    let (commit_bytes, orphan) = match shadow.commits.get(&welcome.commit_hash) {
        Some(b) => (b.clone(), false),
        None => match shadow.x.orphans.get(&welcome.commit_hash) {
            Some(b) => (b.clone(), true),
            None => return refuse(Refuse::Later), // the commit has not arrived
        },
    };
    let Ok(commit) = treekem::Commit::from_bytes(&commit_bytes) else { return false };
    // Sealed by the device that authored the commit — nobody else's word for an entry point.
    if committer_device(&commit).map(|d| hex(&d)) != Some(sender_hex) {
        return false;
    }
    if orphan {
        if let Err(r) = check_commit(st, idx, &commit, None) {
            return refuse(r);
        }
    }
    let shadow = st.v2_trees.get(&circle_id).expect("checked above");
    let entry = &shadow.x.kp_secrets[kp_index];
    let Ok((_tree, _schedule, private)) = keypackage::enter_via_welcome_v2(&entry.secret, &gid, &welcome, &commit_bytes)
    else {
        return false;
    };
    let kp_id = entry.secret.kp_id;
    // The entry point, in the form the shared replay walks from. The leaf secret in it is MY OWN
    // (it never travelled); the whole record is wiped when the checkpoint passes it.
    let entry_welcome = ShadowWelcome {
        epoch: welcome.epoch,
        leaf_index: welcome.leaf_index,
        joiner_secret: welcome.joiner_secret,
        leaf_secret: private.leaf_secret,
        cth: welcome.cth,
        tree_bytes: welcome.tree_bytes.clone(),
    };
    let shadow = st.v2_trees.get_mut(&circle_id).expect("checked above");
    // A Welcome for a NEWER package than the one my current place came from is my re-entry: what
    // I held before is the place I could not follow the chain from. Drop it (wiped on drop).
    let reentry = shadow.x.entered_kp.is_some_and(|k| k != kp_id);
    if reentry {
        shadow.checkpoint = None;
        shadow.my_welcomes.clear();
        shadow.own_builds.clear();
        shadow.x.kp_secrets.drain(..kp_index);
        // My seat's leaf key is the new package's: the Update I authored from the old seat is moot.
        shadow.x.own_keys.clear();
        shadow.x.leaf_at = now_secs();
        shadow.replay_memo.lock().unwrap_or_else(|e| e.into_inner()).clear();
    } else if keying_welcome_superseded(shadow, &mut None, &welcome.commit_hash, &entry_welcome) {
        return false; // an old epoch's secrets coming back: refused (stage 1)
    }
    if orphan {
        shadow.x.orphans.remove(&welcome.commit_hash);
        shadow.commits.insert(welcome.commit_hash, commit_bytes);
    }
    shadow.my_welcomes.insert(welcome.commit_hash, entry_welcome);
    if shadow.x.entered_kp != Some(kp_id) {
        shadow.x.leaf_at = now_secs(); // a new seat: my Update window starts here
    }
    shadow.x.entered_kp = Some(kp_id);
    shadow.x.entered_commit = Some(welcome.commit_hash);
    true
}

fn join_payload(entry_commit: &[u8; 32], device: &[u8; 32]) -> Vec<u8> {
    let mut v = Vec::with_capacity(JOIN_DOMAIN.len() + 64);
    v.extend_from_slice(JOIN_DOMAIN);
    v.extend_from_slice(entry_commit);
    v.extend_from_slice(device);
    v
}

fn note_ack(shadow: &mut ShadowTree, device: [u8; 32], entry_commit: [u8; 32]) -> bool {
    let acks = shadow.x.joined_at.entry(device).or_default();
    if acks.contains(&entry_commit) {
        return false;
    }
    if acks.len() >= KEEP_ACKS_PER_DEVICE {
        acks.remove(0);
    }
    acks.push(entry_commit);
    true
}

/// A v2 join ack: `entry commit(32) ‖ device(32) ‖ sig` — "this device holds the secrets of the
/// leaf that commit gave it". Verified under the device's authorized bundle.
fn receive_join(st: &mut NetState, idx: usize, body: &[u8]) -> bool {
    if body.len() < 64 {
        return false;
    }
    let entry_commit: [u8; 32] = body[0..32].try_into().expect("32 bytes");
    let device: [u8; 32] = body[32..64].try_into().expect("32 bytes");
    let circle_id = st.circles[idx].id.clone();
    if st.v2_trees.get(&circle_id).is_some_and(|t| t.x.joined_at.get(&device).is_some_and(|a| a.contains(&entry_commit))) {
        return false; // recorded already: peers re-send their ack in every bundle
    }
    let Some(bundle) = resolve_shadow_sender_ref(st, idx, &hex(&device)) else {
        return refuse(Refuse::Later);
    };
    if bundle.verify(&join_payload(&entry_commit, &device), &body[64..]).is_err() {
        return false;
    }
    note_ack(tree_mut(st, &circle_id), device, entry_commit)
}

// ── My own key package ─────────────────────────────────────────────────────────────────────────

/// Can `cur` key content at `tip`?
fn derives(cur: &Option<KeyingState>, tip: &[u8; 32]) -> bool {
    cur.as_ref().is_some_and(|c| c.tip_hash == *tip && c.my_private.is_some() && c.sender_root.is_some())
}

/// Does this device need a commit to seat it — and so should offer a key package?
///
///   * no genesis yet: yes (the genesis needs a package from every device);
///   * the agreed chain has no leaf for me, and did not Remove me: yes (an Add);
///   * it has a leaf for me whose key is one of my packages I can still open a Welcome for: no —
///     that Welcome is on its way — until I have waited [`WELCOME_WAIT_SECS`] for it (`waited`),
///     then yes: it is lost, and I ask again with a package the chain has not used;
///   * it has a leaf for me and I cannot derive the agreed tip: yes — I am on a branch that lost
///     (on weight, or on the hash at equal weight) below my checkpoint, or lost my state, and
///     re-enter with a fresh package (`Remove(old leaf) + Add`).
fn wants_entry(shadow: &ShadowTree, me: &[u8; 32], cur: &Option<KeyingState>, waited: bool) -> bool {
    let Some((tip, state)) = canonical(shadow) else { return true };
    match leaf_of_device(&state.tree, me) {
        None => !state.removed.contains(me),
        Some((_, leaf)) => {
            if derives(cur, &tip) {
                return false;
            }
            let key = leaf_key(leaf);
            if shadow.x.kp_secrets.iter().any(|e| e.leaf_key() == key) {
                return waited;
            }
            match cur {
                None => true,
                Some(c) => {
                    c.my_private.is_none()
                        || c.sender_root.is_none()
                        || c.epoch < state.epoch
                        // My own chain hangs off the same genesis the agreed one does, so the fork
                        // rule had both to choose from and chose the other — on weight, or on the
                        // hash at equal weight. My walk follows the same rule wherever it still
                        // can, so I cannot switch; I re-enter. (A chain that does NOT connect — I
                        // entered above a gap in what I hold — is not compared: the public view is
                        // then only what lies below the gap.)
                        || keying_genesis_of(shadow, c.tip_hash).is_some_and(|g| keying_genesis_of(shadow, tip) == Some(g))
                }
            }
        }
    }
}

/// Keep [`V2State::seat_wait`] current and say whether the Welcome for my seat is overdue: the
/// agreed chain seats me under one of my own packages' keys, I cannot derive it, and that has
/// been so for [`WELCOME_WAIT_SECS`].
fn welcome_overdue(shadow: &mut ShadowTree, me: &[u8; 32], cur: &Option<KeyingState>) -> bool {
    let waiting_on = canonical(shadow).and_then(|(tip, state)| {
        let key = leaf_key(leaf_of_device(&state.tree, me)?.1);
        (!derives(cur, &tip) && shadow.x.kp_secrets.iter().any(|e| e.leaf_key() == key)).then_some(key)
    });
    let Some(key) = waiting_on else {
        shadow.x.seat_wait = None;
        return false;
    };
    let now = now_secs();
    match shadow.x.seat_wait {
        // (A clock that went back restarts the wait rather than stretch it.)
        Some((k, since)) if k == key && since <= now => now - since >= WELCOME_WAIT_SECS,
        _ => {
            shadow.x.seat_wait = Some((key, now));
            false
        }
    }
}

/// The key package this device offers right now, if it wants a seat: its newest one the agreed
/// chain has not used, else a freshly generated one. `None` when it has its seat.
fn offer_key_package(st: &mut NetState, idx: usize) -> Option<Vec<u8>> {
    let circle_id = st.circles[idx].id.clone();
    let me = my_device_id(st)?;
    let cred = my_credential(st)?;
    let seed = st.device.as_ref()?.secret_seed();
    let shadow = tree_mut(st, &circle_id);
    let cur = mls_replay(shadow, None);
    let waited = welcome_overdue(shadow, &me, &cur);
    if !wants_entry(shadow, &me, &cur, waited) {
        return None;
    }
    let used: HashSet<[u8; 32]> = canonical(shadow).map(|(_, s)| s.added).unwrap_or_default();
    if let Some(e) = shadow.x.kp_secrets.iter().rev().find(|e| !used.contains(&e.leaf_key())) {
        return Some(tagged(TAG_MLS2_KEYPACKAGE, &e.wire));
    }
    // The leaf secret and the one-time seed come from the OS RNG; the long-term key only signs.
    let (kp, secret) = KeyPackage::generate(&Identity::from_seed(&seed), &cred, circle_id.as_bytes()).ok()?;
    let wire = kp.to_bytes();
    if shadow.x.kp_secrets.len() >= KEEP_OWN_PACKAGES {
        shadow.x.kp_secrets.remove(0);
    }
    shadow.x.kp_secrets.push(KpEntry { secret, wire: wire.clone() });
    Some(tagged(TAG_MLS2_KEYPACKAGE, &wire))
}

/// Delete the one-time seed (and the spare copy of the leaf secret) of the package my place came
/// from, once the checkpoint has passed that entry point: every Welcome through it is wiped, and
/// no Welcome sealed to it can be opened again — by this state, or by the long-term key.
fn prune_key_packages(shadow: &mut ShadowTree) {
    if shadow.checkpoint.is_none() {
        return; // the fork window on the entry point is still open
    }
    let Some(entered) = shadow.x.entered_kp else { return };
    let held: Vec<[u8; 32]> = shadow.my_welcomes.values().map(|w| w.leaf_secret).collect();
    shadow.x.kp_secrets.retain(|e| e.secret.kp_id != entered || held.contains(&e.secret.leaf_secret));
}

// ── Committing ─────────────────────────────────────────────────────────────────────────────────

/// The newest key package I hold for `device` that `used` does not contain and that still
/// verifies as a leaf of an authorized device.
fn usable_package(st: &NetState, idx: usize, device: &[u8; 32], used: &HashSet<[u8; 32]>) -> Option<KeyPackage> {
    let shadow = st.v2_trees.get(&st.circles[idx].id)?;
    let gid = st.circles[idx].id.as_bytes();
    if Some(*device) == my_device_id(st) {
        return shadow
            .x
            .kp_secrets
            .iter()
            .rev()
            .filter(|e| !used.contains(&e.leaf_key()))
            .find_map(|e| KeyPackage::from_bytes(&e.wire).ok());
    }
    shadow.x.key_packages.get(device)?.iter().rev().find_map(|w| {
        let kp = KeyPackage::from_bytes(w).ok()?;
        if kp.group_id != gid || used.contains(&leaf_key(&kp.leaf)) {
            return None;
        }
        // Verified when it arrived; the roster may have moved since.
        let cred = check_leaf(st, idx, &kp.leaf).ok()?;
        (cred.device_id() == *device).then_some(kp)
    })
}

/// Seal the Welcome for `kp`, seated at `leaf_index` of the tree commit `commit_hash` produced.
fn seal_welcome_wire(
    signer: &Identity,
    kp: &KeyPackage,
    commit_hash: [u8; 32],
    leaf_index: u32,
    build: &treekem::CommitBuild,
    tree_bytes: &[u8],
) -> Option<Vec<u8>> {
    // `WelcomeV2` wipes its joiner secret on drop; the sealed envelope is all that is kept.
    let w = WelcomeV2 {
        commit_hash,
        epoch: build.commit.epoch,
        leaf_index,
        joiner_secret: build.schedule.joiner_secret,
        cth: build.confirmed_transcript_hash,
        kp_id: kp.kp_id,
        tree_bytes: tree_bytes.to_vec(),
    };
    let mut plaintext = w.to_bytes();
    let env = keypackage::seal_welcome(signer, kp, &plaintext);
    plaintext.iter_mut().for_each(|b| *b = 0);
    env.ok().map(|e| tagged(TAG_MLS2_WELCOME, &e.to_bytes()))
}

/// Build (once) the v2 genesis: one Add per authorized device, each leaf taken VERBATIM from that
/// device's key package, and a Welcome sealed to each package's one-time key. Waits until a valid
/// package is held for EVERY authorized device of every member — the device-granular evidence that
/// the whole circle runs the v2 tree. The init secret is random and used once.
fn build_genesis(st: &mut NetState, idx: usize) {
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let devices = shadow_device_leaves(st, idx);
    if devices.len() < 2 {
        return;
    }
    let Some(me) = my_device_id(st) else { return };
    let Some(seed) = st.device.as_ref().map(|d| d.secret_seed()) else { return };
    {
        let Some(shadow) = st.v2_trees.get(&circle_id) else { return };
        if keying_winning_genesis(shadow).is_some() {
            return; // one exists — mine, or a sibling device's
        }
    }
    let none_used = HashSet::new();
    let mut packages: Vec<KeyPackage> = Vec::with_capacity(devices.len());
    for (bundle, _) in &devices {
        match usable_package(st, idx, &bundle.node_id_bytes(), &none_used) {
            Some(kp) => packages.push(kp),
            None => return, // a device has not offered one (yet, or ever: an older build)
        }
    }
    let Some(my_leaf) = devices.iter().position(|(b, _)| b.node_id_bytes() == me) else { return };
    let signer = Identity::from_seed(&seed);
    let adds: Vec<treekem::Proposal> = packages
        .iter()
        .enumerate()
        .map(|(li, kp)| treekem::build_add_proposal(&gid, 0, li as u32, kp.leaf.clone(), |m| signer.sign(m)))
        .collect();
    let mut base_init = keying_random_secret();
    let built = treekem::build_commit(
        &treekem::RatchetTree { slots: vec![] },
        &gid,
        1,
        shadow_domain_hash(GENESIS_PARENT_DOMAIN, &gid),
        &genesis_cth(&gid),
        &base_init,
        my_leaf as u32,
        adds,
        None, // add-only: every leaf key is its own device's
        |m| signer.sign(m),
        |m| signer.sign(m),
    );
    treekem::wipe_secret(&mut base_init);
    let Ok(build) = built else { return };
    let commit_bytes = build.commit.to_bytes();
    let commit_hash = treekem::commit_hash(&commit_bytes);
    let tree_bytes = build.tree.to_bytes();
    let mut emit: Vec<Vec<u8>> = vec![tagged(TAG_MLS2_COMMIT, &commit_bytes)];
    for (li, kp) in packages.iter().enumerate() {
        if li != my_leaf {
            emit.extend(seal_welcome_wire(&signer, kp, commit_hash, li as u32, &build, &tree_bytes));
        }
    }
    let my_kp_id = packages[my_leaf].kp_id;
    let shadow = st.v2_trees.get_mut(&circle_id).expect("checked above");
    let Some(my_leaf_secret) =
        shadow.x.kp_secrets.iter().find(|e| e.secret.kp_id == my_kp_id).map(|e| e.secret.leaf_secret)
    else {
        return;
    };
    shadow.commits.insert(commit_hash, commit_bytes);
    shadow.my_genesis = Some(commit_hash);
    shadow.genesis_devices = devices.iter().map(|(b, _)| b.node_id_bytes()).collect();
    // My own entry point, stored directly (I hold the secrets by construction).
    shadow.my_welcomes.insert(
        commit_hash,
        ShadowWelcome {
            epoch: 1,
            leaf_index: my_leaf as u32,
            joiner_secret: build.schedule.joiner_secret,
            leaf_secret: my_leaf_secret,
            cth: build.confirmed_transcript_hash,
            tree_bytes,
        },
    );
    shadow.x.entered_kp = Some(my_kp_id);
    shadow.x.entered_commit = Some(commit_hash);
    shadow.x.leaf_at = now_secs();
    note_ack(shadow, me, commit_hash);
    shadow.emit_cache.extend(emit);
    for (bundle, _) in &devices {
        shadow.x.key_packages.remove(&bundle.node_id_bytes());
    }
}

/// Author one chained commit on my tip: `removes` (leaf indices), then one Add per package in
/// `adds`, re-keying my own leaf with a RANDOM secret. A Welcome goes to each added package's
/// one-time key. With no removes and no adds it is a member update (§16.4), which any device may
/// author. `false` if I cannot commit here (not a deriving member, no authority, already authored
/// on this tip).
fn author_commit(st: &mut NetState, idx: usize, removes: &[u32], adds: &[KeyPackage]) -> bool {
    let circle_id = st.circles[idx].id.clone();
    let gid = circle_id.as_bytes().to_vec();
    let Some(seed) = st.device.as_ref().map(|d| d.secret_seed()) else { return false };
    let signer = Identity::from_seed(&seed);
    let Some(shadow) = st.v2_trees.get(&circle_id) else { return false };
    let Some(cur) = mls_replay(shadow, None) else { return false };
    let Some(mp) = &cur.my_private else { return false };
    let Some(init) = cur.init_secret else { return false };
    if keying_already_authored_on(shadow, &cur) {
        return false; // one own commit per tip
    }
    let my_leaf = mp.leaf_index;
    if removes.contains(&my_leaf) {
        return false;
    }
    // Authority, as receivers will check it: an admin, or a leave (only my own account's leaves).
    let my_account = st.me().node_id_bytes();
    let admin = circle_admin_set(st, idx).is_some_and(|a| a.contains(&my_account));
    let own = |li: &u32| {
        cur.tree.leaf(*li).and_then(|l| leaf_credential_ids(&l.device_credential)).map(|(_, a)| a) == Some(my_account)
    };
    let update_only = removes.is_empty() && adds.is_empty();
    let device_at = |li: &u32| cur.tree.leaf(*li).and_then(|l| leaf_credential_ids(&l.device_credential)).map(|(d, _)| d);
    let leave = !removes.is_empty() && adds.is_empty() && removes.iter().all(own);
    // A re-entry of other devices: each package replaces the leaf of the device that signed it.
    let reentry = !removes.is_empty()
        && removes.len() == adds.len()
        && adds.iter().all(|kp| {
            let d = leaf_credential_ids(&kp.leaf.device_credential).map(|(d, _)| d);
            d.is_some() && removes.iter().filter(|li| device_at(li) == d).count() == 1
        });
    if !admin && !update_only && !leave && !reentry {
        return false;
    }
    // AUTHORING DISCIPLINE: nothing is authored on a tip that is not the agreed one — a device
    // that can see the agreed chain is elsewhere must not lengthen its own branch. The one
    // exception is an admin's plain Remove: it is what restores the agreed chain to the branch
    // that excludes a removed member, so it may be authored from wherever the admin stands.
    let on_agreed = agreed_tip(shadow).is_none_or(|tip| tip == cur.tip_hash);
    if !on_agreed && !(admin && adds.is_empty() && !removes.is_empty()) {
        return false;
    }
    let next = cur.epoch + 1;
    let mut props: Vec<treekem::Proposal> = removes
        .iter()
        .map(|li| treekem::build_remove_proposal(&gid, next, my_leaf, *li, |m| signer.sign(m)))
        .collect();
    for kp in adds {
        props.push(treekem::build_add_proposal(&gid, next, my_leaf, kp.leaf.clone(), |m| signer.sign(m)));
    }
    let Some(cred) = cur.tree.leaf(my_leaf).map(|l| l.device_credential.clone()) else { return false };
    let (new_leaf, entropy) = (keying_random_secret(), keying_random_secret());
    let Ok(build) = treekem::build_commit(
        &cur.tree,
        &gid,
        next,
        cur.tip_hash,
        &cur.cth,
        &init,
        my_leaf,
        props,
        Some((&new_leaf, &cred, &entropy)),
        |m| signer.sign(m),
        |m| signer.sign(m),
    ) else {
        return false;
    };
    let cbytes = build.commit.to_bytes();
    let ch = treekem::commit_hash(&cbytes);
    let tree_bytes = build.tree.to_bytes();
    let mut welcomes: Vec<Vec<u8>> = Vec::new();
    for kp in adds {
        let key = leaf_key(&kp.leaf);
        let Some((li, _)) = leaves_of(&build.tree).into_iter().find(|(_, l)| leaf_key(l) == key) else { continue };
        welcomes.extend(seal_welcome_wire(&signer, kp, ch, li, &build, &tree_bytes));
    }
    let shadow = st.v2_trees.get_mut(&circle_id).expect("checked above");
    if shadow.commits.contains_key(&ch) {
        return false;
    }
    shadow.commits.insert(ch, cbytes.clone());
    shadow.emit_cache.push(tagged(TAG_MLS2_COMMIT, &cbytes));
    shadow.emit_cache.extend(welcomes);
    keying_record_own_build(shadow, ch, cur.tip_hash, next, new_leaf, entropy);
    // Every commit re-keys my own leaf: this one is now "my last Update", and my Update window
    // restarts from it once the chain I adopt carries its leaf key ([`member_update`]).
    let new_kp = treekem::node_keypair_from_path_secret(&new_leaf);
    if shadow.x.own_keys.len() >= KEEP_OWN_KEYS {
        shadow.x.own_keys.remove(0);
    }
    shadow.x.own_keys.push(OwnUpdate {
        leaf_key: leaf_key_of(&new_kp.kem_x, &new_kp.kem_pq[..]),
        commit: ch,
        epoch: next,
        at: now_secs(),
    });
    keying_wipe_material(new_leaf, entropy);
    // The packages just used are NOT forgotten: this commit may lose its fork, and the device
    // goes on offering the same bytes, which a mailbox serves only once. A package is spent when
    // the chain I stand on has used it (`usable_package` checks that), not when I tried to.
    // The circle-wide stamp the sender-keys lane's weekly rotation reads, as before for the
    // commits that existed before member updates (an admin's, a leave). A plain member's Update
    // leaves it alone: its window is per device (`own_keys`), not this stamp.
    if admin || !update_only {
        st.circles[idx].rotated_at = now_secs();
    }
    true
}

/// Reconcile the v2 tree with the verified roster, in ONE commit: Remove every leaf whose device is
/// no longer authorized; Add every authorized device that is not in the tree, was not deliberately
/// removed, and has offered a key package; and RE-ENTER every device that is in the tree but has
/// offered a fresh package — `Remove(old leaf) + Add(package)`. A device re-enters only by its own
/// signed request (the package), and gets nothing of its old leaf back: nobody else ever had it.
fn sync_roster(st: &mut NetState, idx: usize) {
    let circle_id = st.circles[idx].id.clone();
    let Some(shadow) = st.v2_trees.get(&circle_id) else { return };
    let Some(cur) = mls_replay(shadow, None) else { return };
    if cur.my_private.is_none() || cur.init_secret.is_none() {
        return;
    }
    let Some(public) = public_state(shadow, &cur.tip_hash) else { return };
    let me = my_device_id(st);
    let authorized: Vec<[u8; 32]> = shadow_device_leaves(st, idx).iter().map(|(b, _)| b.node_id_bytes()).collect();
    // Off the agreed tip only the revocation Removes are authored (see `author_commit`).
    let on_agreed = agreed_tip(shadow).is_none_or(|tip| tip == cur.tip_hash);
    let mut removes: Vec<u32> = Vec::new();
    let mut revoked_accounts: HashSet<[u8; 32]> = HashSet::new();
    let mut in_tree: HashMap<[u8; 32], (u32, [u8; 32])> = HashMap::new();
    for (li, leaf) in leaves_of(&cur.tree) {
        let Some((device, account)) = leaf_credential_ids(&leaf.device_credential) else { continue };
        if authorized.contains(&device) {
            in_tree.insert(device, (li, leaf_key(leaf)));
        } else {
            removes.push(li);
            revoked_accounts.insert(account);
        }
    }
    let mut adds: Vec<KeyPackage> = Vec::new();
    for device in authorized.iter().filter(|_| on_agreed) {
        if Some(*device) == me {
            continue; // I commit from my own leaf; my own re-entry is another device's to do
        }
        let Some(kp) = usable_package(st, idx, device, &public.added) else { continue };
        match in_tree.get(device) {
            // In the tree under a different key, offering a fresh package: re-entry. Only when I
            // know the chain's whole history: otherwise a package spent before my entry point
            // looks fresh, and the device it belongs to (which has re-keyed since) looks like one
            // that is asking.
            Some((li, key)) if *key != leaf_key(&kp.leaf) && public.complete => {
                removes.push(*li);
                adds.push(kp);
            }
            Some(_) => {}
            None if public.removed.contains(device) => {} // removal is sticky
            None => adds.push(kp),
        }
    }
    if removes.is_empty() && adds.is_empty() {
        return;
    }
    if author_commit(st, idx, &removes, &adds) {
        // A member with no authorized device left is out of the circle (as on the v1 tree).
        let still: HashSet<[u8; 32]> = shadow_device_leaves(st, idx).iter().map(|(_, c)| c.account_id).collect();
        for account in revoked_accounts.iter().filter(|a| !still.contains(*a)) {
            purge_member_from_circle(&mut st.circles[idx], &hex(account));
        }
    }
}

/// A per-(device, package) number for ordering and spreading re-entries.
fn reentry_rank(device: &[u8; 32], kp_id: &[u8; KP_ID_LEN]) -> u64 {
    let mut h = blake3::Hasher::new();
    h.update(REENTRY_DOMAIN);
    h.update(device);
    h.update(kp_id);
    let mut first = [0u8; 8];
    first.copy_from_slice(&h.finalize().as_bytes()[..8]);
    u64::from_le_bytes(first)
}

/// RE-ENTRY BY A DEVICE THAT IS NOT A COMMITTER. A device that derives the agreed tip and holds a
/// fresh, valid package from a device the agreed tree seats under another key may re-enter it:
/// `Remove(old leaf) + Add(package)`, every eligible device in one commit. The committer does
/// this at once (`sync_roster`); the others step in when the committer cannot:
///
///   * the device asking is itself a committer device (the creator account's) — then the healthy
///     device with the smallest [`reentry_rank`] acts at once;
///   * otherwise, and for every other healthy device, once the package has been waiting an hour
///     plus a per-(device, package) offset below six hours — time for a committer to do it.
///
/// "Healthy" is every seated device I hold no such package from, myself included. The waiting
/// time is counted from when I first saw the package this session.
fn member_reentry(st: &mut NetState, idx: usize) -> bool {
    let circle_id = st.circles[idx].id.clone();
    let Some(me) = my_device_id(st) else { return false };
    if my_credential(st).is_none() {
        return false;
    }
    let Some(creator) = circle_mls_accounts(st, idx).iter().map(|a| a.node_id_bytes()).min() else { return false };
    let Some(shadow) = st.v2_trees.get(&circle_id) else { return false };
    let Some(cur) = mls_replay(shadow, None) else { return false };
    if agreed_tip(shadow) != Some(cur.tip_hash) || cur.my_private.is_none() || cur.init_secret.is_none() {
        return false;
    }
    let Some(public) = public_state(shadow, &cur.tip_hash).filter(|p| p.complete) else { return false };
    // (device, leaf, account) of every seat; then who is asking, with which package.
    let seats: Vec<Seat> = leaves_of(&cur.tree)
        .into_iter()
        .filter_map(|(li, l)| leaf_credential_ids(&l.device_credential).map(|(d, a)| (d, li, a, leaf_key(l))))
        .collect();
    let mut asking: Vec<(u32, bool, KeyPackage)> = Vec::new();
    let mut healthy: Vec<[u8; 32]> = Vec::new();
    for (device, li, account, key) in &seats {
        let offered = if *device == me { None } else { usable_package(st, idx, device, &public.added) };
        match offered {
            Some(kp) if leaf_key(&kp.leaf) != *key => asking.push((*li, *account == creator, kp)),
            _ => healthy.push(*device),
        }
    }
    if asking.is_empty() {
        return false;
    }
    let now = now_secs();
    let Some(shadow) = st.v2_trees.get_mut(&circle_id) else { return false };
    let mut removes: Vec<u32> = Vec::new();
    let mut adds: Vec<KeyPackage> = Vec::new();
    for (li, committer, kp) in asking {
        let seen = *shadow.x.kp_seen.entry(*blake3::hash(&kp.to_bytes()).as_bytes()).or_insert(now);
        let waited = now.saturating_sub(seen) >= REENTRY_WAIT_SECS + reentry_rank(&me, &kp.kp_id) % REENTRY_SPREAD_SECS;
        let first = committer && healthy.iter().min_by_key(|d| reentry_rank(d, &kp.kp_id)) == Some(&me);
        if waited || first {
            removes.push(li);
            adds.push(kp);
        }
    }
    !adds.is_empty() && author_commit(st, idx, &removes, &adds)
}

/// Remove every leaf of `account` from the v2 tree (the v2 half of `mls_remove_member`).
pub(crate) fn remove_account(st: &mut NetState, idx: usize, account: &[u8; 32]) -> bool {
    if !gate(st, idx) {
        return false;
    }
    let Some(shadow) = st.v2_trees.get(&st.circles[idx].id) else { return false };
    let Some(cur) = mls_replay(shadow, None) else { return false };
    let leaves: Vec<u32> = leaves_of(&cur.tree)
        .into_iter()
        .filter(|(_, l)| leaf_credential_ids(&l.device_credential).map(|(_, a)| a) == Some(*account))
        .map(|(li, _)| li)
        .collect();
    !leaves.is_empty() && author_commit(st, idx, &leaves, &[])
}

// ── Keying ─────────────────────────────────────────────────────────────────────────────────────

/// Has every leaf's device acked the entry that seated it? (The second gate, per leaf: a device
/// that re-entered must ack its new seat.) Where the chain below my entry point is not held, any
/// ack from the device counts, as on the v1 tree.
fn all_joined(shadow: &ShadowTree, cur: &KeyingState) -> bool {
    let public = public_state(shadow, &cur.tip_hash);
    let devices = tree_leaf_device_ids(&cur.tree);
    !devices.is_empty()
        && devices.iter().all(|d| {
            let Some(acks) = shadow.x.joined_at.get(d) else { return false };
            match public.as_ref().and_then(|p| p.added_at.get(d)) {
                Some(entry) => acks.contains(entry),
                None => !acks.is_empty(),
            }
        })
}

/// Is every authorized device of every member a leaf of my tree — or a device this chain
/// deliberately Removed? Without this a device that has no key package (an older build) would be
/// silently left out of a circle that keeps keying from the tree; with it the circle parks on the
/// sender-keys lane, which seals to every device. (A Removed device is not waited for: a member
/// cut by an admin's commit stays in the other members' circle lists, as on the v1 tree.)
fn all_present(st: &NetState, idx: usize, shadow: &ShadowTree, cur: &KeyingState) -> bool {
    let leaves: HashSet<[u8; 32]> = tree_leaf_device_ids(&cur.tree).into_iter().collect();
    let removed = public_state(shadow, &cur.tip_hash).map(|p| p.removed).unwrap_or_default();
    shadow_device_leaves(st, idx).iter().all(|(b, _)| {
        let d = b.node_id_bytes();
        leaves.contains(&d) || removed.contains(&d) || cur.removed_devices.contains(&d)
    })
}

/// The v2 half of the keying decision, run before the v1 half on every bundle and tree envelope.
///
/// Whenever this device can derive the v2 tree's current epoch it files that epoch's content keys
/// (so a post from a device that flipped first opens at once). It returns `Some(content epoch)` —
/// the v2 tree KEYS the circle — only when every authorized device is a leaf and every leaf has
/// acked. The first time that happens the v1 tree is wiped: from then on this circle emits and
/// accepts no v1 tree wire.
pub(crate) fn refresh(st: &mut NetState, idx: usize) -> Option<u64> {
    let circle_id = st.circles[idx].id.clone();
    if st.v2_trees.get(&circle_id).is_some_and(|t| t.x.retired_v1) && v1_only_evidence(st, idx) {
        // A v1-only account joined: the v1 tree may run again (it starts over from a new genesis).
        if let Some(t) = st.v2_trees.get_mut(&circle_id) {
            t.x.retired_v1 = false;
        }
    }
    if !gate(st, idx) {
        return None;
    }
    let gid = circle_id.as_bytes().to_vec();
    {
        let shadow = st.v2_trees.get_mut(&circle_id)?;
        // Stage 1's chokepoint: the checkpoint advances, superseded secrets are wiped — and with
        // them the one-time seed of the key package this device entered through.
        keying_checkpoint_pass(shadow, None);
        prune_key_packages(shadow);
    }
    let shadow = st.v2_trees.get(&circle_id)?;
    let cur = mls_replay(shadow, None)?;
    let sender_root = cur.sender_root?;
    cur.my_private.as_ref()?;
    let content_epoch = MLS2_EPOCH_BASE + cur.epoch;
    let live = all_joined(shadow, &cur) && all_present(st, idx, shadow, &cur);
    let me_acct = st.me().node_id_bytes();
    for acct in tree_leaf_accounts(&cur.tree) {
        let key = treekem::sender_key(&sender_root, &acct, &gid, cur.epoch);
        st.circles[idx].set_tree_key(&acct, acct == me_acct, content_epoch, key);
    }
    if !live {
        st.circles[idx].prune_epoch_keys();
        return None;
    }
    if st.circles[idx].mls_live_epoch != Some(content_epoch) {
        // The content epoch moved (the flip itself, or a commit): the client re-seals its history.
        st.circles[idx].epoch_moved = true;
    }
    st.circles[idx].mls_live_epoch = Some(content_epoch);
    st.circles[idx].prune_epoch_keys();
    retire_v1(st, idx);
    Some(content_epoch)
}

/// The flip: wipe the v1 tree and everything parked for it. Idempotent.
fn retire_v1(st: &mut NetState, idx: usize) {
    let circle_id = st.circles[idx].id.clone();
    if let Some(t) = st.v2_trees.get_mut(&circle_id) {
        t.x.retired_v1 = true;
    }
    if let Some(mut v1) = st.shadow_trees.remove(&circle_id) {
        // Welcomes, the checkpoint and own build records wipe themselves on drop; the assigned
        // leaves are plain arrays.
        for s in v1.assigned_leaves.values_mut() {
            treekem::wipe_secret(s);
        }
        if let Some(r) = v1.my_secret_root.as_mut() {
            treekem::wipe_secret(r);
        }
    }
    st.circles[idx]
        .pending_tree
        .retain(|raw| !matches!(raw.first(), Some(&TAG_MLS_COMMIT) | Some(&TAG_MLS_WELCOME) | Some(&TAG_MLS_JOIN)));
}

/// `mls_shadow_status` for a circle whose v2 tree took over (its v1 tree is gone): the same four
/// facts, about the v2 tree. `converged` = this device derives the tip every device agrees on.
pub(crate) fn shadow_status(st: &NetState, circle_id: &str) -> Option<MlsShadowStatusFfi> {
    let shadow = st.v2_trees.get(circle_id).filter(|t| t.x.retired_v1)?;
    let cur = mls_replay(shadow, None)?;
    let parent0 = keying_genesis_parent(shadow);
    let geneses = shadow
        .commits
        .values()
        .filter(|b| treekem::Commit::from_bytes(b).is_ok_and(|c| c.epoch == 1 && c.parent_commit_hash == parent0))
        .count();
    let converged = cur.sender_root.is_some() && canonical(shadow).is_none_or(|(tip, _)| tip == cur.tip_hash);
    Some(MlsShadowStatusFfi {
        epoch: cur.epoch,
        tree_hash_hex: hex(&treekem::tree_hash(&cur.tree)),
        converged,
        fork_count: geneses.saturating_sub(1) as u32,
    })
}

// ── Emitting ───────────────────────────────────────────────────────────────────────────────────

/// The v2 wires of a bundle: my key package while I want a seat, the tree wires I authored
/// (commits, Welcomes — byte-stable), my join ack. Empty unless the circle passes [`gate`].
pub(crate) fn emit_bundle(st: &mut NetState, idx: usize, full_bundle: bool) -> Vec<Vec<u8>> {
    if !gate(st, idx) {
        return vec![];
    }
    let circle_id = st.circles[idx].id.clone();
    let mut out: Vec<Vec<u8>> = Vec::new();
    if let Some(shadow) = st.v2_trees.get_mut(&circle_id) {
        settle_void(shadow);
    }
    out.extend(offer_key_package(st, idx));
    if am_committer(st, idx) {
        build_genesis(st, idx);
        sync_roster(st, idx);
    } else {
        member_reentry(st, idx);
    }
    if full_bundle {
        // EVERY device, committer or not (§16.4). After the roster reconciliation, so a commit
        // that already re-keyed my leaf this bundle is seen.
        member_update(st, idx);
    }
    if let Some(t) = st.v2_trees.get(&circle_id) {
        out.extend(t.emit_cache.iter().cloned());
    }
    out.extend(join_wire(st, idx));
    out
}

/// This device's offset into the weekly Update window: below [`UPDATE_JITTER_SECS`], a fixed
/// function of (device id, circle id). Devices that entered a circle together (a genesis, the
/// migration) would otherwise all come due on the same bundle and fork on every Update.
pub(crate) fn update_jitter(device: &[u8; 32], gid: &[u8]) -> u64 {
    let mut h = blake3::Hasher::new();
    h.update(UPDATE_JITTER_DOMAIN);
    h.update(device);
    h.update(gid);
    let mut first = [0u8; 8];
    first.copy_from_slice(&h.finalize().as_bytes()[..8]);
    u64::from_le_bytes(first) % UPDATE_JITTER_SECS
}

#[cfg(test)]
thread_local! {
    /// Test hook: this thread's engines ignore the own-run limit, as a modified client would.
    static MODIFIED_CLIENT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
/// Test hook: see [`MODIFIED_CLIENT`].
#[cfg(test)]
pub(crate) fn x_modified_client(on: bool) {
    MODIFIED_CLIENT.set(on);
}

/// How many chained commits ending at `tip` did I author in a row? (A genesis is not counted: the
/// branches the fork rule compares start at a genesis' children.)
///
/// "I" is my ACCOUNT, any of its devices — as the fork rule's length cap is ([`chain_index`]): past
/// [`MAX_OWN_RUN`] a further commit of the same account adds no weight to its branch. For the
/// account that built the genesis, which the cap exempts, it is this DEVICE, as it was before the
/// cap: a device cut off from the circle must still not grow a branch by itself.
fn own_run(shadow: &ShadowTree, tip: &[u8; 32], me: &[u8; 32], my_account: &[u8; 32]) -> usize {
    let creator = keying_genesis_of(shadow, *tip)
        .and_then(|g| treekem::Commit::from_bytes(shadow.commits.get(&g)?).ok())
        .and_then(|g| genesis_author_account(&g));
    let per_device = creator == Some(*my_account);
    let mut n = 0;
    let mut at = *tip;
    while n <= MAX_OWN_RUN {
        let Some(c) = shadow.commits.get(&at).and_then(|b| treekem::Commit::from_bytes(b).ok()) else { break };
        let mine = if per_device { committer_device(&c) == Some(*me) } else { committer_account(&c) == Some(*my_account) };
        if c.update_path.is_none() || !mine {
            break;
        }
        n += 1;
        at = c.parent_commit_hash;
    }
    n
}

/// Is my own leaf due a re-key? PROTOCOL-SPEC §15/§16.4: the window is per DEVICE and counts from
/// when the key THAT IS AT MY LEAF ON MY TIP was installed:
///
///   * it is a key one of my own commits installed (`own_keys`): a week plus my offset after I
///     authored that commit;
///   * it is not (the key I entered with): a week plus my offset after I entered.
///
/// So an Update that lost a fork (FK4) is re-issued without waiting: the chain I adopted still
/// carries the key the Update was meant to replace, which is over age by then (FK5). And a commit
/// of mine that lost for another reason — a membership race — does not make me due: the key on my
/// tip is as old as it is, whatever I authored since.
fn update_due(shadow: &mut ShadowTree, my_leaf_key: &[u8; 32], me: &[u8; 32], now: u64) -> bool {
    let window = ROTATE_INTERVAL_SECS + update_jitter(me, &shadow.group_id);
    match shadow.x.own_keys.iter_mut().rev().find(|u| u.leaf_key == *my_leaf_key) {
        Some(u) => {
            if u.at > now {
                u.at = now; // the clock went back: restart the window rather than wait it out
            }
            now - u.at >= window
        }
        None => {
            if shadow.x.leaf_at == 0 || shadow.x.leaf_at > now {
                shadow.x.leaf_at = now;
            }
            now - shadow.x.leaf_at >= window
        }
    }
}

/// THE MEMBER UPDATE (PROTOCOL-SPEC §16.4): this device re-keys its OWN leaf with a random secret
/// — whoever it is, committer or not. Runs on the full bundle only (the bundle that re-seals my
/// history under the new epoch — the one place an epoch may move), and only on a tree that keys
/// content. See [`update_due`] for when; the leaf secret and entropy are stored as a stage-1 build
/// record and die with the checkpoint.
///
/// Not authored: on a tip I already authored a child of (`keying_already_authored_on`, inside
/// `author_commit`); on a tip that ends [`MAX_OWN_RUN`] commits of my own account; when my own roster no
/// longer authorizes this device (every receiver would refuse the commit).
fn member_update(st: &mut NetState, idx: usize) -> bool {
    let circle_id = st.circles[idx].id.clone();
    let Some(me) = my_device_id(st) else { return false };
    if my_credential(st).is_none() {
        return false;
    }
    let live = st.v2_trees.get(&circle_id).is_some_and(|shadow| {
        mls_replay(shadow, None).is_some_and(|cur| all_joined(shadow, &cur) && all_present(st, idx, shadow, &cur))
    });
    if !live {
        return false;
    }
    let now = now_secs();
    let Some(shadow) = st.v2_trees.get_mut(&circle_id) else { return false };
    let Some(cur) = mls_replay(shadow, None) else { return false };
    let Some(my_leaf_key) = cur.my_private.as_ref().and_then(|mp| cur.tree.leaf(mp.leaf_index)).map(leaf_key) else {
        return false;
    };
    let Some(my_account) = cur
        .my_private
        .as_ref()
        .and_then(|mp| cur.tree.leaf(mp.leaf_index))
        .and_then(|l| leaf_credential_ids(&l.device_credential))
        .map(|(_, a)| a)
    else {
        return false;
    };
    let run_spent = own_run(shadow, &cur.tip_hash, &me, &my_account) >= MAX_OWN_RUN;
    #[cfg(test)]
    let run_spent = run_spent && !MODIFIED_CLIENT.get();
    if !update_due(shadow, &my_leaf_key, &me, now) || run_spent {
        return false;
    }
    author_commit(st, idx, &[], &[])
}

/// My join ack, once I can derive my tip: it names the commit that seated me.
fn join_wire(st: &mut NetState, idx: usize) -> Option<Vec<u8>> {
    let circle_id = st.circles[idx].id.clone();
    let me = my_device_id(st)?;
    let seed = st.device.as_ref()?.secret_seed();
    let shadow = st.v2_trees.get_mut(&circle_id)?;
    let cur = mls_replay(shadow, None)?;
    if cur.my_private.is_none() || cur.sender_root.is_none() {
        return None;
    }
    let entry =
        public_state(shadow, &cur.tip_hash).and_then(|p| p.added_at.get(&me).copied()).or(shadow.x.entered_commit)?;
    note_ack(shadow, me, entry);
    if let Some((at, wire)) = &shadow.x.join_wire {
        if *at == entry {
            return Some(wire.clone());
        }
    }
    let sig = Identity::from_seed(&seed).sign(&join_payload(&entry, &me));
    let mut body = Vec::with_capacity(64 + sig.len());
    body.extend_from_slice(&entry);
    body.extend_from_slice(&me);
    body.extend_from_slice(&sig);
    let wire = tagged(TAG_MLS2_JOIN, &body);
    shadow.x.join_wire = Some((entry, wire.clone()));
    Some(wire)
}

// ── Persistence ────────────────────────────────────────────────────────────────────────────────

const STATE_V1: u8 = 1;
/// [`STATE_V1`] plus the member-update tail (`leaf_at`, my last Update, the void commits).
const STATE_V2: u8 = 2;
/// The member-update tail with a LIST of my own recent commits in place of the last one.
const STATE_V3: u8 = 3;

fn put_lp(v: &mut Vec<u8>, b: &[u8]) {
    v.extend_from_slice(&(b.len() as u32).to_le_bytes());
    v.extend_from_slice(b);
}

/// `ver(1) ‖ retired(1) ‖ opt(entered_kp 16) ‖ opt(entered_commit 32)
///  ‖ u32 n ‖ lp(package)×n                               — other devices' key packages
///  ‖ u32 n ‖ (kp_id 16 ‖ leaf 32 ‖ init_seed 32 ‖ lp(package))×n — my own, with their secrets
///  ‖ u32 n ‖ (device 32 ‖ u32 m ‖ commit 32 × m)×n        — join acks
///  ‖ leaf_at(8) ‖ u32 n ‖ (leaf_key 32 ‖ commit 32 ‖ epoch 8 ‖ at 8)×n — my seat's age, my commits
///  ‖ u32 n ‖ commit 32 × n                                 — void commits
///  ‖ opt(leaf_key 32 ‖ since 8)                            — the Welcome I am waiting for`
///
/// The last two lines are the member-update tail. Version 1 has none; version 2 has
/// `opt(one commit)` where version 3 has the list. Both still decode.
pub(crate) fn encode_state(t: &ShadowTree) -> Vec<u8> {
    let x = &t.x;
    let mut v = vec![STATE_V3, x.retired_v1 as u8];
    match &x.entered_kp {
        Some(k) => {
            v.push(1);
            v.extend_from_slice(k);
        }
        None => v.push(0),
    }
    match &x.entered_commit {
        Some(c) => {
            v.push(1);
            v.extend_from_slice(c);
        }
        None => v.push(0),
    }
    let packages: Vec<&Vec<u8>> = x.key_packages.values().flatten().collect();
    v.extend_from_slice(&(packages.len() as u32).to_le_bytes());
    for p in packages {
        put_lp(&mut v, p);
    }
    v.extend_from_slice(&(x.kp_secrets.len() as u32).to_le_bytes());
    for e in &x.kp_secrets {
        v.extend_from_slice(&e.secret.kp_id);
        v.extend_from_slice(&e.secret.leaf_secret);
        v.extend_from_slice(&e.secret.init_seed);
        put_lp(&mut v, &e.wire);
    }
    v.extend_from_slice(&(x.joined_at.len() as u32).to_le_bytes());
    for (device, acks) in &x.joined_at {
        v.extend_from_slice(device);
        v.extend_from_slice(&(acks.len() as u32).to_le_bytes());
        for a in acks {
            v.extend_from_slice(a);
        }
    }
    v.extend_from_slice(&x.leaf_at.to_le_bytes());
    v.extend_from_slice(&(x.own_keys.len() as u32).to_le_bytes());
    for u in &x.own_keys {
        v.extend_from_slice(&u.leaf_key);
        v.extend_from_slice(&u.commit);
        v.extend_from_slice(&u.epoch.to_le_bytes());
        v.extend_from_slice(&u.at.to_le_bytes());
    }
    v.extend_from_slice(&(x.void.len() as u32).to_le_bytes());
    for h in &x.void {
        v.extend_from_slice(h);
    }
    match &x.seat_wait {
        Some((key, since)) => {
            v.push(1);
            v.extend_from_slice(key);
            v.extend_from_slice(&since.to_le_bytes());
        }
        None => v.push(0),
    }
    v
}

/// What [`encode_state`] wrote, decoded. Exact consumption; anything else is `None`.
struct DecodedState {
    retired_v1: bool,
    entered_kp: Option<[u8; KP_ID_LEN]>,
    entered_commit: Option<[u8; 32]>,
    packages: Vec<Vec<u8>>,
    own: Vec<KpEntry>,
    acks: Vec<([u8; 32], Vec<[u8; 32]>)>,
    leaf_at: u64,
    own_keys: Vec<OwnUpdate>,
    void: Vec<[u8; 32]>,
    seat_wait: Option<([u8; 32], u64)>,
}

fn decode_state(b: &[u8]) -> Option<DecodedState> {
    struct R<'a>(&'a [u8]);
    impl<'a> R<'a> {
        fn take(&mut self, n: usize) -> Option<&'a [u8]> {
            if self.0.len() < n {
                return None;
            }
            let (a, rest) = self.0.split_at(n);
            self.0 = rest;
            Some(a)
        }
        fn u8(&mut self) -> Option<u8> {
            self.take(1).map(|b| b[0])
        }
        fn u32(&mut self) -> Option<usize> {
            Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?) as usize)
        }
        fn u64(&mut self) -> Option<u64> {
            Some(u64::from_le_bytes(self.take(8)?.try_into().ok()?))
        }
        fn arr<const N: usize>(&mut self) -> Option<[u8; N]> {
            self.take(N)?.try_into().ok()
        }
        fn lp(&mut self) -> Option<Vec<u8>> {
            let n = self.u32()?;
            self.take(n).map(|b| b.to_vec())
        }
        fn flag(&mut self) -> Option<bool> {
            match self.u8()? {
                0 => Some(false),
                1 => Some(true),
                _ => None,
            }
        }
    }
    let mut r = R(b);
    let version = r.u8()?;
    if !(STATE_V1..=STATE_V3).contains(&version) {
        return None;
    }
    let retired_v1 = r.flag()?;
    let entered_kp = if r.flag()? { Some(r.arr::<KP_ID_LEN>()?) } else { None };
    let entered_commit = if r.flag()? { Some(r.arr::<32>()?) } else { None };
    // Counts are never trusted for allocation: each element is read (and bounds-checked) in turn.
    let mut packages = Vec::new();
    for _ in 0..r.u32()? {
        packages.push(r.lp()?);
    }
    let mut own = Vec::new();
    for _ in 0..r.u32()? {
        let secret = KeyPackageSecret { kp_id: r.arr()?, leaf_secret: r.arr()?, init_seed: r.arr()? };
        own.push(KpEntry { secret, wire: r.lp()? });
    }
    let mut acks = Vec::new();
    for _ in 0..r.u32()? {
        let device = r.arr::<32>()?;
        let mut list = Vec::new();
        for _ in 0..r.u32()? {
            list.push(r.arr::<32>()?);
        }
        acks.push((device, list));
    }
    let (mut leaf_at, mut own_keys, mut void) = (0, Vec::new(), Vec::new());
    if version >= STATE_V2 {
        leaf_at = r.u64()?;
        // Version 2 wrote at most one commit, behind a flag; version 3 writes a counted list.
        let n = if version == STATE_V2 { r.flag()? as usize } else { r.u32()? };
        for _ in 0..n {
            own_keys.push(OwnUpdate { leaf_key: r.arr()?, commit: r.arr()?, epoch: r.u64()?, at: r.u64()? });
        }
        for _ in 0..r.u32()? {
            void.push(r.arr::<32>()?);
        }
    }
    // (Absent in a version-3 state written before the wait was recorded: nothing follows.)
    let seat_wait = if version >= STATE_V3 && !r.0.is_empty() && r.flag()? { Some((r.arr()?, r.u64()?)) } else { None };
    r.0.is_empty().then_some(DecodedState {
        retired_v1,
        entered_kp,
        entered_commit,
        packages,
        own,
        acks,
        leaf_at,
        own_keys,
        void,
        seat_wait,
    })
}

/// Merge a persisted v2 state into `t`: what this session already holds wins; the rest fills in.
pub(crate) fn restore_state(t: &mut ShadowTree, bytes: &[u8]) {
    let Some(d) = decode_state(bytes) else { return };
    t.x.retired_v1 |= d.retired_v1;
    if t.x.entered_kp.is_none() {
        t.x.entered_kp = d.entered_kp;
        t.x.entered_commit = d.entered_commit;
    }
    if t.x.leaf_at == 0 {
        t.x.leaf_at = d.leaf_at;
    }
    if t.x.own_keys.is_empty() {
        t.x.own_keys = d.own_keys;
        let extra = t.x.own_keys.len().saturating_sub(KEEP_OWN_KEYS);
        t.x.own_keys.drain(..extra);
    }
    if t.x.seat_wait.is_none() {
        t.x.seat_wait = d.seat_wait;
    }
    // Packages restored from disk start waiting now.
    let now = now_secs();
    let hashes: Vec<[u8; 32]> = t.x.key_packages.values().flatten().map(|w| *blake3::hash(w).as_bytes()).collect();
    for h in hashes {
        t.x.kp_seen.entry(h).or_insert(now);
    }
    // Void commits are verdicts about public commits: they union.
    t.x.void.extend(d.void);
    for wire in d.packages {
        let Some(device) = KeyPackage::from_bytes(&wire)
            .ok()
            .and_then(|kp| leaf_credential_ids(&kp.leaf.device_credential))
            .map(|(device, _)| device)
        else {
            continue;
        };
        let list = t.x.key_packages.entry(device).or_default();
        if !list.contains(&wire) && list.len() < KEEP_PACKAGES_PER_DEVICE {
            list.push(wire);
        }
    }
    // Restored packages are OLDER than any minted this session: they go first.
    let have: BTreeSet<[u8; KP_ID_LEN]> = t.x.kp_secrets.iter().map(|e| e.secret.kp_id).collect();
    let mut restored: Vec<KpEntry> = d.own.into_iter().filter(|e| !have.contains(&e.secret.kp_id)).collect();
    restored.append(&mut t.x.kp_secrets);
    t.x.kp_secrets = restored;
    for (device, acks) in d.acks {
        for a in acks {
            note_ack(t, device, a);
        }
    }
}

/// The v2 state's share of `key_state_digest`: a key package minted (or its secrets wiped), the
/// flip — each must reach disk before the envelopes built on it leave.
pub(crate) fn digest_state(t: &ShadowTree, h: &mut blake3::Hasher) {
    h.update(&[t.x.retired_v1 as u8]);
    h.update(&(t.x.kp_secrets.len() as u64).to_le_bytes());
    for e in &t.x.kp_secrets {
        h.update(&e.secret.kp_id);
    }
    h.update(&t.x.entered_kp.unwrap_or([0u8; KP_ID_LEN]));
    // My Update bookkeeping and the void set must reach disk too: an Update authored and sent but
    // not recorded would be re-issued after a restart; a void verdict lost could not be re-derived
    // once the checkpoint has passed its parent.
    h.update(&t.x.leaf_at.to_le_bytes());
    h.update(&t.x.own_keys.last().map(|u| u.commit).unwrap_or([0u8; 32]));
    h.update(&(t.x.void.len() as u64).to_le_bytes());
    h.update(&t.x.seat_wait.map(|(_, since)| since).unwrap_or(0).to_le_bytes());
}

/// Test access to a v2 tree's private state (`net_tests/keying_v2_tests.rs`).
#[cfg(test)]
impl ShadowTree {
    pub(crate) fn x_retired(&self) -> bool {
        self.x.retired_v1
    }
    /// (kp id, one-time seed, leaf secret) of every key package of mine still held.
    pub(crate) fn x_entries(&self) -> Vec<([u8; KP_ID_LEN], [u8; 32], [u8; 32])> {
        self.x.kp_secrets.iter().map(|e| (e.secret.kp_id, e.secret.init_seed, e.secret.leaf_secret)).collect()
    }
    /// Every secret of my own key packages.
    pub(crate) fn x_own_secrets(&self) -> Vec<[u8; 32]> {
        self.x.kp_secrets.iter().flat_map(|e| [e.secret.leaf_secret, e.secret.init_seed]).collect()
    }
    pub(crate) fn x_packages_of(&self, device: &[u8; 32]) -> usize {
        self.x.key_packages.get(device).map_or(0, |l| l.len())
    }
    /// Make my own leaf Update due at the next full bundle (the window stamps go back; the clock
    /// does not move, so no other device comes due).
    pub(crate) fn x_make_update_due(&mut self) {
        self.x.leaf_at = 1;
        for u in self.x.own_keys.iter_mut() {
            u.at = 1;
        }
    }
    /// (commit, epoch) of the last commit I authored.
    pub(crate) fn x_last_update(&self) -> Option<([u8; 32], u64)> {
        self.x.own_keys.last().map(|u| (u.commit, u.epoch))
    }
    /// When my current seat's leaf key entered the tree.
    pub(crate) fn x_leaf_at(&self) -> u64 {
        self.x.leaf_at
    }
    /// Forget when my seat was made and what I last authored — as a state saved before member
    /// updates loads.
    pub(crate) fn x_forget_update_window(&mut self) {
        self.x.leaf_at = 0;
        self.x.own_keys.clear();
    }
    /// (tip, epoch) of the chain every device holding my commit set agrees on.
    pub(crate) fn x_canonical(&self) -> Option<([u8; 32], u64)> {
        canonical(self).map(|(tip, s)| (tip, s.epoch))
    }
    /// The commits I found void.
    pub(crate) fn x_void(&self) -> Vec<[u8; 32]> {
        self.x.void.iter().copied().collect()
    }
    /// The v2 state as a build before member updates wrote it (version 1: no tail).
    pub(crate) fn x_state_v1_bytes(&self) -> Vec<u8> {
        let mut v = encode_state(self);
        let tail = 8 + 4 + 80 * self.x.own_keys.len() + 4 + 32 * self.x.void.len() + 1 + self.x.seat_wait.map_or(0, |_| 40);
        v.truncate(v.len() - tail);
        v[0] = STATE_V1;
        v
    }
    /// The v2 state as the first member-update build wrote it (version 2: one own commit at most).
    pub(crate) fn x_state_v2_bytes(&self) -> Vec<u8> {
        let mut v = self.x_state_v1_bytes();
        v[0] = STATE_V2;
        v.extend_from_slice(&self.x.leaf_at.to_le_bytes());
        match self.x.own_keys.last() {
            Some(u) => {
                v.push(1);
                v.extend_from_slice(&u.leaf_key);
                v.extend_from_slice(&u.commit);
                v.extend_from_slice(&u.epoch.to_le_bytes());
                v.extend_from_slice(&u.at.to_le_bytes());
            }
            None => v.push(0),
        }
        v.extend_from_slice(&(self.x.void.len() as u32).to_le_bytes());
        for h in &self.x.void {
            v.extend_from_slice(h);
        }
        v
    }
    /// Make the wait for my Welcome `secs` older (the clock does not move).
    pub(crate) fn x_age_seat_wait(&mut self, secs: u64) {
        if let Some((_, since)) = self.x.seat_wait.as_mut() {
            *since = since.saturating_sub(secs);
        }
    }
    /// Move every "first seen" stamp of other devices' key packages back by `secs`.
    pub(crate) fn x_age_packages(&mut self, secs: u64) {
        for at in self.x.kp_seen.values_mut() {
            *at = at.saturating_sub(secs);
        }
    }
    /// The weight `(authority, length)` of the heaviest chain starting at a commit.
    pub(crate) fn x_weight(&self, h: &[u8; 32]) -> Option<(u32, u32)> {
        chain_index(self).weight.get(h).copied()
    }
    /// Lose every key package secret and the record of which one I entered through.
    pub(crate) fn x_forget_packages(&mut self) {
        self.x.kp_secrets.clear();
        self.x.entered_kp = None;
        self.x.entered_commit = None;
    }
}

/// Test diagnostics: why this device would not store a chained commit, check by check.
#[cfg(test)]
pub(crate) fn x_refusal(st: &NetState, idx: usize, body: &[u8]) -> String {
    let Ok(c) = treekem::Commit::from_bytes(body) else { return "unparseable".into() };
    let Some(shadow) = st.v2_trees.get(&st.circles[idx].id) else { return "no tree".into() };
    let Some(prev) = public_state(shadow, &c.parent_commit_hash) else { return "no public state for the parent".into() };
    let mut out = Vec::new();
    match check_commit(st, idx, &c, Some(&prev)) {
        Ok(()) => out.push("check_commit ok".to_string()),
        Err(Refuse::Never) => out.push("check_commit NEVER".to_string()),
        Err(Refuse::Later) => out.push("check_commit LATER".to_string()),
    }
    if let Some(up) = &c.update_path {
        out.push(format!("author leaf ok: {}", check_leaf(st, idx, &up.leaf_node).is_ok()));
    }
    for p in &c.proposals {
        if let treekem::ProposalBody::Add { leaf_node } = &p.body {
            out.push(format!(
                "add: leaf ok {}, key used before {}, seated at {:?}",
                check_leaf(st, idx, leaf_node).is_ok(),
                prev.added.contains(&leaf_key(leaf_node)),
                leaf_credential_ids(&leaf_node.device_credential).and_then(|(d, _)| leaf_of_device(&prev.tree, &d)).map(|(li, _)| li)
            ));
        }
    }
    out.push(format!("applies: {}", step_public(&shadow.group_id, &prev, &treekem::commit_hash(body), &c).is_some()));
    out.join(", ")
}
