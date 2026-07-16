//! TreeKEM wire formats — MLS stage **M0** (see `docs/TREEKEM-DESIGN.md` §3.4, §5.4, §9).
//!
//! **Types + serialization ONLY.** No tree math, no key schedule, no signing, no engine
//! wiring lives here yet — that is stage M1+. Shipping the byte layouts first (the
//! `groupkey.rs` increment-1 pattern) pins the wire contract while nothing depends on it,
//! so later stages can interoperate with blobs an M0 build may already have persisted.
//!
//! Layout conventions match `device.rs`: all integers little-endian, `lp(x)` = u32 length
//! ‖ bytes, parsed by a minimal cursor `Reader`. Every top-level `from_bytes` demands the
//! buffer be consumed **exactly** — trailing bytes are rejected, because these formats are
//! terminal (unlike the roster wire, nothing is ever appended after them; an "appendable
//! trailer" here would repeat the seed-drop-trailer trap §7.1 warns about). Untrusted
//! element counts are never pre-allocated: a hostile count fails on the first short read
//! instead of reserving memory.

use crate::{CoreError, Result};

// ── Domain-separation tags (§3.4) ────────────────────────────────────────────────────────
//
// Defined with the wire formats because they are part of the byte contract: stage M1+'s
// sign/verify uses them, and pinning them now means an M0 build and an M1 build agree on
// what any given signature covers. Follows the `CRED_DOMAIN`/`LIST_DOMAIN` discipline.

/// Signed by the DEVICE over `LEAF_DOMAIN ‖ group_id ‖ leaf keys` — binds a leaf public key
/// to the device so a stolen credential can't be replayed onto an attacker-chosen leaf key.
pub const LEAF_DOMAIN: &[u8] = b"haven-mls-leaf-v1";
/// Signed over a [`Proposal`]'s body bytes.
pub const PROPOSAL_DOMAIN: &[u8] = b"haven-mls-prop-v1";
/// Signed over all bytes of a [`Commit`] preceding its signature.
pub const COMMIT_DOMAIN: &[u8] = b"haven-mls-commit-v1";
/// Signed over a [`GroupInfo`]'s body bytes.
pub const GROUPINFO_DOMAIN: &[u8] = b"haven-mls-ginfo-v1";

// ── Fixed sizes (mirror `identity.rs`; a node's public state is a strict subset of HavenId) ──

/// X25519 public key length — the classical half of every node key.
pub const KEM_X_LEN: usize = 32;
/// ML-KEM-768 encapsulation-key length — the post-quantum half of every node key.
pub const MLKEM_EK_LEN: usize = 1184;

// RatchetTree slot tags (§3.4). Any other tag byte is a parse error — strictness here is
// what makes tampered blobs fail closed instead of decoding into a plausible tree.
const SLOT_BLANK: u8 = 0x00;
const SLOT_LEAF: u8 = 0x01;
const SLOT_PARENT: u8 = 0x02;

// Proposal type tags (§3.4).
const PTYPE_ADD: u8 = 1;
const PTYPE_REMOVE: u8 = 2;
const PTYPE_UPDATE: u8 = 3;

/// ParentNode `flags` bit 0: the node is blank (post-Remove, awaiting a repopulating path).
/// All other bits are reserved and MUST be zero — rejected on parse so a future flag can be
/// introduced only behind an explicit version break, never silently misread by old code.
const PARENT_FLAG_BLANK: u8 = 0x01;

/// `PersistTree` blob format version. Bumped only on an incompatible layout change; an
/// unknown version is a parse error (fail closed, never guess at secret material).
const PERSIST_TREE_V1: u8 = 1;

// ── Encoding helpers (device.rs house style) ─────────────────────────────────────────────

/// Append `b` length-prefixed (u32 LE).
fn lp(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u32).to_le_bytes());
    out.extend_from_slice(b);
}

/// Minimal length-prefixed byte reader (the `device.rs:580` shape).
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
            return Err(CoreError::Encoding("treekem wire: unexpected end of input"));
        }
        let s = &self.b[self.i..self.i + n];
        self.i += n;
        Ok(s)
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N]> {
        Ok(self.take(N)?.try_into().unwrap())
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
    fn bytes_lp(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn done(&self) -> bool {
        self.i == self.b.len()
    }
}

/// Enforce exact consumption for a top-level parse: trailing bytes are a hard error, so a
/// blob can't smuggle data past the parser (and round-trips stay byte-stable by construction).
fn expect_consumed<T>(r: &Reader, v: T) -> Result<T> {
    if r.done() {
        Ok(v)
    } else {
        Err(CoreError::Encoding("treekem wire: trailing bytes"))
    }
}

// ── LeafNode (§3.1, §3.4) ────────────────────────────────────────────────────────────────

/// A leaf slot: the device's tree-only hybrid KEM public key plus its credential chain.
///
/// The leaf keypair is fresh for the tree — **not** the device's long-term `HavenId` KEM
/// keys — so leaf updates never rotate the device identity and a leaf-secret compromise
/// never exposes the device's DM/self-sync decapsulation key. The credential bytes are the
/// existing account-signed [`crate::device::DeviceCredential`], carried opaquely here (the
/// verifier parses them with that type); `leaf_binding_sig` is DEVICE-signed over
/// [`LEAF_DOMAIN`]-tagged bytes so a stolen credential can't be replayed onto an
/// attacker-chosen leaf key. M0 carries both; verification is M1+.
///
/// Wire: `leaf_kem_x(32) ‖ leaf_kem_pq(1184) ‖ lp(device_credential) ‖ lp(leaf_binding_sig)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LeafNode {
    pub leaf_kem_x: [u8; KEM_X_LEN],
    pub leaf_kem_pq: [u8; MLKEM_EK_LEN],
    pub device_credential: Vec<u8>,
    pub leaf_binding_sig: Vec<u8>,
}

impl LeafNode {
    fn encode_into(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.leaf_kem_x);
        out.extend_from_slice(&self.leaf_kem_pq);
        lp(out, &self.device_credential);
        lp(out, &self.leaf_binding_sig);
    }

    fn read(r: &mut Reader) -> Result<Self> {
        Ok(Self {
            leaf_kem_x: r.array()?,
            leaf_kem_pq: r.array()?,
            device_credential: r.bytes_lp()?.to_vec(),
            leaf_binding_sig: r.bytes_lp()?.to_vec(),
        })
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::new();
        self.encode_into(&mut v);
        v
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let v = Self::read(&mut r)?;
        expect_consumed(&r, v)
    }
}

// ── ParentNode (§3.1, §3.4) ──────────────────────────────────────────────────────────────

/// An interior node: a hybrid KEM public key pair plus the standard unmerged-leaves list.
///
/// The layout is fixed regardless of the blank flag (the key fields still travel) so the
/// encoding is positionally stable — a parser never has to branch on the flag to find the
/// next field, and a flipped flag bit can't shift the rest of the tree.
///
/// Wire: `flags(1) ‖ node_kem_x(32) ‖ node_kem_pq(1184) ‖ u32 n_unmerged ‖ leaf_index(4)×n`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParentNode {
    /// Blank after a Remove, until an UpdatePath repopulates it (§4.3).
    pub blank: bool,
    pub node_kem_x: [u8; KEM_X_LEN],
    pub node_kem_pq: [u8; MLKEM_EK_LEN],
    pub unmerged_leaves: Vec<u32>,
}

impl ParentNode {
    fn encode_into(&self, out: &mut Vec<u8>) {
        out.push(if self.blank { PARENT_FLAG_BLANK } else { 0 });
        out.extend_from_slice(&self.node_kem_x);
        out.extend_from_slice(&self.node_kem_pq);
        out.extend_from_slice(&(self.unmerged_leaves.len() as u32).to_le_bytes());
        for l in &self.unmerged_leaves {
            out.extend_from_slice(&l.to_le_bytes());
        }
    }

    fn read(r: &mut Reader) -> Result<Self> {
        let flags = r.u8()?;
        if flags & !PARENT_FLAG_BLANK != 0 {
            return Err(CoreError::Encoding("treekem wire: unknown parent-node flags"));
        }
        let node_kem_x = r.array()?;
        let node_kem_pq = r.array()?;
        let n = r.u32()?;
        let mut unmerged_leaves = Vec::new(); // never pre-allocated from an untrusted count
        for _ in 0..n {
            unmerged_leaves.push(r.u32()?);
        }
        Ok(Self { blank: flags & PARENT_FLAG_BLANK != 0, node_kem_x, node_kem_pq, unmerged_leaves })
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::new();
        self.encode_into(&mut v);
        v
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let v = Self::read(&mut r)?;
        expect_consumed(&r, v)
    }
}

// ── RatchetTree (§3.4) ───────────────────────────────────────────────────────────────────

/// One array slot of the left-balanced binary tree (leaf i at index 2i; parents between).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TreeSlot {
    /// An empty slot (never-populated, or fully blanked).
    Blank,
    Leaf(LeafNode),
    Parent(ParentNode),
}

/// The public tree as an array of slots. Travels as a content-addressed blob (like media
/// refs), NOT inline in every commit — a 32-leaf tree is ~40–75 KB.
///
/// Wire: `u32 n_slots ‖ (0x00 | 0x01 ‖ LeafNode | 0x02 ‖ ParentNode)×n`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RatchetTree {
    pub slots: Vec<TreeSlot>,
}

impl RatchetTree {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&(self.slots.len() as u32).to_le_bytes());
        for s in &self.slots {
            match s {
                TreeSlot::Blank => out.push(SLOT_BLANK),
                TreeSlot::Leaf(l) => {
                    out.push(SLOT_LEAF);
                    l.encode_into(&mut out);
                }
                TreeSlot::Parent(p) => {
                    out.push(SLOT_PARENT);
                    p.encode_into(&mut out);
                }
            }
        }
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let n = r.u32()?;
        let mut slots = Vec::new();
        for _ in 0..n {
            slots.push(match r.u8()? {
                SLOT_BLANK => TreeSlot::Blank,
                SLOT_LEAF => TreeSlot::Leaf(LeafNode::read(&mut r)?),
                SLOT_PARENT => TreeSlot::Parent(ParentNode::read(&mut r)?),
                _ => return Err(CoreError::Encoding("treekem wire: unknown tree slot tag")),
            });
        }
        expect_consumed(&r, Self { slots })
    }
}

// ── Proposal (§3.4) ──────────────────────────────────────────────────────────────────────

/// The membership operation a [`Proposal`] carries. Add/Update carry the (length-prefixed)
/// new leaf; Remove names a leaf index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProposalBody {
    Add { leaf_node: LeafNode },
    Remove { leaf_index: u32 },
    Update { leaf_node: LeafNode },
}

/// A signed Add/Remove/Update proposal. The signature (hybrid, over
/// [`PROPOSAL_DOMAIN`]-tagged body bytes) is carried opaquely in M0; authorization against
/// the verified roster is M2+.
///
/// Wire: `ptype(1) ‖ lp(group_id) ‖ epoch(8) ‖ [variant] ‖ sender_leaf(4) ‖ lp(sig)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proposal {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub body: ProposalBody,
    /// The proposing device's leaf index (the signer; resolved leaf → account at verify).
    pub sender_leaf: u32,
    pub sig: Vec<u8>,
}

impl Proposal {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(match self.body {
            ProposalBody::Add { .. } => PTYPE_ADD,
            ProposalBody::Remove { .. } => PTYPE_REMOVE,
            ProposalBody::Update { .. } => PTYPE_UPDATE,
        });
        lp(&mut out, &self.group_id);
        out.extend_from_slice(&self.epoch.to_le_bytes());
        match &self.body {
            ProposalBody::Add { leaf_node } | ProposalBody::Update { leaf_node } => {
                lp(&mut out, &leaf_node.to_bytes());
            }
            ProposalBody::Remove { leaf_index } => out.extend_from_slice(&leaf_index.to_le_bytes()),
        }
        out.extend_from_slice(&self.sender_leaf.to_le_bytes());
        lp(&mut out, &self.sig);
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let ptype = r.u8()?;
        let group_id = r.bytes_lp()?.to_vec();
        let epoch = r.u64()?;
        let body = match ptype {
            PTYPE_ADD => ProposalBody::Add { leaf_node: LeafNode::from_bytes(r.bytes_lp()?)? },
            PTYPE_REMOVE => ProposalBody::Remove { leaf_index: r.u32()? },
            PTYPE_UPDATE => ProposalBody::Update { leaf_node: LeafNode::from_bytes(r.bytes_lp()?)? },
            _ => return Err(CoreError::Encoding("treekem wire: unknown proposal type")),
        };
        let sender_leaf = r.u32()?;
        let sig = r.bytes_lp()?.to_vec();
        expect_consumed(&r, Self { group_id, epoch, body, sender_leaf, sig })
    }
}

// ── UpdatePath (§3.4) ────────────────────────────────────────────────────────────────────

/// One path secret hybrid-KEM-wrapped to a copath resolution node.
///
/// Wire: `resolution_index(4) ‖ eph_x(32) ‖ lp(pq_ct) ‖ lp(wrapped_path_secret)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PathSecretCiphertext {
    /// Tree array index of the resolution node this ciphertext is addressed to.
    pub resolution_index: u32,
    /// Ephemeral X25519 public key of the hybrid encapsulation.
    pub eph_x: [u8; KEM_X_LEN],
    /// ML-KEM-768 ciphertext of the hybrid encapsulation.
    pub pq_ct: Vec<u8>,
    /// AEAD-wrapped 32-byte path secret.
    pub wrapped_path_secret: Vec<u8>,
}

impl PathSecretCiphertext {
    fn encode_into(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.resolution_index.to_le_bytes());
        out.extend_from_slice(&self.eph_x);
        lp(out, &self.pq_ct);
        lp(out, &self.wrapped_path_secret);
    }

    fn read(r: &mut Reader) -> Result<Self> {
        Ok(Self {
            resolution_index: r.u32()?,
            eph_x: r.array()?,
            pq_ct: r.bytes_lp()?.to_vec(),
            wrapped_path_secret: r.bytes_lp()?.to_vec(),
        })
    }
}

/// One re-keyed node on the committer's direct path: its new public key plus the path
/// secret wrapped to each node of the corresponding copath resolution.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpdatePathNode {
    pub node_kem_x: [u8; KEM_X_LEN],
    pub node_kem_pq: [u8; MLKEM_EK_LEN],
    pub ciphertexts: Vec<PathSecretCiphertext>,
}

impl UpdatePathNode {
    fn encode_into(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.node_kem_x);
        out.extend_from_slice(&self.node_kem_pq);
        out.extend_from_slice(&(self.ciphertexts.len() as u32).to_le_bytes());
        for ct in &self.ciphertexts {
            ct.encode_into(out);
        }
    }

    fn read(r: &mut Reader) -> Result<Self> {
        let node_kem_x = r.array()?;
        let node_kem_pq = r.array()?;
        let n = r.u32()?;
        let mut ciphertexts = Vec::new();
        for _ in 0..n {
            ciphertexts.push(PathSecretCiphertext::read(r)?);
        }
        Ok(Self { node_kem_x, node_kem_pq, ciphertexts })
    }
}

/// The committer's fresh leaf plus its re-keyed direct path — the O(log n) rekey (§4.4).
///
/// Wire: `lp(LeafNode) ‖ u32 n_nodes ‖ UpdatePathNode×n` (nodes leaf→root).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpdatePath {
    pub leaf_node: LeafNode,
    pub nodes: Vec<UpdatePathNode>,
}

impl UpdatePath {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        lp(&mut out, &self.leaf_node.to_bytes());
        out.extend_from_slice(&(self.nodes.len() as u32).to_le_bytes());
        for n in &self.nodes {
            n.encode_into(&mut out);
        }
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let leaf_node = LeafNode::from_bytes(r.bytes_lp()?)?;
        let n = r.u32()?;
        let mut nodes = Vec::new();
        for _ in 0..n {
            nodes.push(UpdatePathNode::read(&mut r)?);
        }
        expect_consumed(&r, Self { leaf_node, nodes })
    }
}

// ── Commit (§3.4) ────────────────────────────────────────────────────────────────────────

/// A commit: proposals applied atomically, the (optional) UpdatePath, and the hash-chain
/// link (`parent_commit_hash`) that §5's fork resolution orders by. The confirmation MAC
/// (keyed by `confirm_key_n`) and the hybrid signature (over [`COMMIT_DOMAIN`] ‖ all
/// preceding bytes) are opaque bytes in M0.
///
/// Wire: `lp(group_id) ‖ epoch(8) ‖ parent_commit_hash(32) ‖ u32 n_props ‖ lp(Proposal)×n
/// ‖ has_path(1) ‖ [lp(UpdatePath)] ‖ tree_hash(32) ‖ lp(confirmation_mac)
/// ‖ sender_leaf(4) ‖ lp(sig)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commit {
    pub group_id: Vec<u8>,
    /// The epoch this commit CREATES (its parent is the epoch-`epoch − 1` confirmed commit).
    pub epoch: u64,
    /// blake3 of the parent commit's full signed bytes — the fork-resolution chain link.
    pub parent_commit_hash: [u8; 32],
    pub proposals: Vec<Proposal>,
    pub update_path: Option<UpdatePath>,
    pub tree_hash: [u8; 32],
    pub confirmation_mac: Vec<u8>,
    pub sender_leaf: u32,
    pub sig: Vec<u8>,
}

impl Commit {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        lp(&mut out, &self.group_id);
        out.extend_from_slice(&self.epoch.to_le_bytes());
        out.extend_from_slice(&self.parent_commit_hash);
        out.extend_from_slice(&(self.proposals.len() as u32).to_le_bytes());
        for p in &self.proposals {
            lp(&mut out, &p.to_bytes());
        }
        match &self.update_path {
            Some(up) => {
                out.push(1);
                lp(&mut out, &up.to_bytes());
            }
            None => out.push(0),
        }
        out.extend_from_slice(&self.tree_hash);
        lp(&mut out, &self.confirmation_mac);
        out.extend_from_slice(&self.sender_leaf.to_le_bytes());
        lp(&mut out, &self.sig);
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let group_id = r.bytes_lp()?.to_vec();
        let epoch = r.u64()?;
        let parent_commit_hash = r.array()?;
        let n = r.u32()?;
        let mut proposals = Vec::new();
        for _ in 0..n {
            proposals.push(Proposal::from_bytes(r.bytes_lp()?)?);
        }
        // has_path must be exactly 0 or 1: any other value would be an ambiguous encoding
        // (two byte strings for one logical commit), which breaks hash-ordered fork
        // resolution — the hash must be a function of the logical content, one-to-one.
        let update_path = match r.u8()? {
            0 => None,
            1 => Some(UpdatePath::from_bytes(r.bytes_lp()?)?),
            _ => return Err(CoreError::Encoding("treekem wire: invalid has_path flag")),
        };
        let tree_hash = r.array()?;
        let confirmation_mac = r.bytes_lp()?.to_vec();
        let sender_leaf = r.u32()?;
        let sig = r.bytes_lp()?.to_vec();
        expect_consumed(
            &r,
            Self {
                group_id,
                epoch,
                parent_commit_hash,
                proposals,
                update_path,
                tree_hash,
                confirmation_mac,
                sender_leaf,
                sig,
            },
        )
    }
}

// ── GroupInfo + Welcome (§3.4) ───────────────────────────────────────────────────────────

/// The joiner's bootstrap view of the group: where the public tree lives (content-addressed
/// blob ref) and the transcript/tree hashes to verify against, signed by an existing member.
///
/// Wire: `lp(group_id) ‖ epoch(8) ‖ lp(tree_blob_ref) ‖ confirmed_transcript_hash(32)
/// ‖ tree_hash(32) ‖ signer_leaf(4) ‖ lp(sig)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GroupInfo {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    /// Content-addressed ref of the serialized [`RatchetTree`] (trees travel as blobs).
    pub tree_blob_ref: Vec<u8>,
    pub confirmed_transcript_hash: [u8; 32],
    pub tree_hash: [u8; 32],
    pub signer_leaf: u32,
    pub sig: Vec<u8>,
}

impl GroupInfo {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        lp(&mut out, &self.group_id);
        out.extend_from_slice(&self.epoch.to_le_bytes());
        lp(&mut out, &self.tree_blob_ref);
        out.extend_from_slice(&self.confirmed_transcript_hash);
        out.extend_from_slice(&self.tree_hash);
        out.extend_from_slice(&self.signer_leaf.to_le_bytes());
        lp(&mut out, &self.sig);
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let group_id = r.bytes_lp()?.to_vec();
        let epoch = r.u64()?;
        let tree_blob_ref = r.bytes_lp()?.to_vec();
        let confirmed_transcript_hash = r.array()?;
        let tree_hash = r.array()?;
        let signer_leaf = r.u32()?;
        let sig = r.bytes_lp()?.to_vec();
        expect_consumed(
            &r,
            Self { group_id, epoch, tree_blob_ref, confirmed_transcript_hash, tree_hash, signer_leaf, sig },
        )
    }
}

/// One joiner's secret delivery inside a [`Welcome`]: the joiner secret (and optionally a
/// path secret) hybrid-KEM-wrapped to the joiner's DEVICE BUNDLE — the `seal_self_sync_key`
/// rail (`device.rs:505`), verbatim.
///
/// Wire: `joiner_device_id(32) ‖ eph_x(32) ‖ lp(pq_ct) ‖ lp(wrapped)`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WelcomeJoiner {
    pub joiner_device_id: [u8; 32],
    pub eph_x: [u8; KEM_X_LEN],
    pub pq_ct: Vec<u8>,
    /// AEAD-wrapped `joiner_secret(32) ‖ path_secret_opt` — opaque until decrypted.
    pub wrapped: Vec<u8>,
}

impl WelcomeJoiner {
    fn encode_into(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.joiner_device_id);
        out.extend_from_slice(&self.eph_x);
        lp(out, &self.pq_ct);
        lp(out, &self.wrapped);
    }

    fn read(r: &mut Reader) -> Result<Self> {
        Ok(Self {
            joiner_device_id: r.array()?,
            eph_x: r.array()?,
            pq_ct: r.bytes_lp()?.to_vec(),
            wrapped: r.bytes_lp()?.to_vec(),
        })
    }
}

/// The Welcome a committer emits for newly-added devices (§4.2): a signed [`GroupInfo`]
/// plus one wrapped secret bundle per joiner.
///
/// Wire: `lp(GroupInfo) ‖ u32 n_joiners ‖ WelcomeJoiner×n`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Welcome {
    pub group_info: GroupInfo,
    pub joiners: Vec<WelcomeJoiner>,
}

impl Welcome {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        lp(&mut out, &self.group_info.to_bytes());
        out.extend_from_slice(&(self.joiners.len() as u32).to_le_bytes());
        for j in &self.joiners {
            j.encode_into(&mut out);
        }
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        let group_info = GroupInfo::from_bytes(r.bytes_lp()?)?;
        let n = r.u32()?;
        let mut joiners = Vec::new();
        for _ in 0..n {
            joiners.push(WelcomeJoiner::read(&mut r)?);
        }
        expect_consumed(&r, Self { group_info, joiners })
    }
}

// ── PersistTree (§5.4) — serialization skeleton only ─────────────────────────────────────

/// One losing-fork sender-key cache entry (§5.2 step 2): keys derived from a commit that
/// lost the hash tie-break, kept so events sealed under it before its author learned it
/// lost still open. Bounded by KEEP_FORKS within the KEEP_EPOCHS window (pruning is M5;
/// this stage only pins the byte layout).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ForkCacheEntry {
    pub epoch: u64,
    /// blake3 of the losing commit's full signed bytes (the fork-cache lookup key).
    pub commit_hash: [u8; 32],
    /// `(sender id, 32-byte sender key)` pairs derived under the losing epoch secret.
    pub sender_keys: Vec<([u8; 32], [u8; 32])>,
}

/// Per-circle tree state as it will ride the platform-encrypted state blob alongside
/// `PersistCircle` — **serialization skeleton only** in M0; nothing writes or reads one in
/// production yet.
///
/// Deliberately absent, and this is a constraint not an omission (§6.3-1): `commit_secret`
/// and `init_secret` have **no field here** — they are consumed at commit application and
/// must never be persisted, or a state-blob backup would fossilize the backward link the
/// one-way epoch schedule exists to sever. A future field for either is a security
/// regression, not a feature.
///
/// Wire (versioned; unknown versions fail closed):
/// `ver(1) ‖ lp(group_id) ‖ u32 n_commits ‖ (hash(32) ‖ lp(commit_bytes))×n
/// ‖ lp(tree_blob_ref) ‖ lp(tree_bytes) ‖ my_leaf_index(4) ‖ my_leaf_secret(32)
/// ‖ u32 n_path ‖ path_secret(32)×n
/// ‖ u32 n_forks ‖ (epoch(8) ‖ commit_hash(32) ‖ u32 n_keys ‖ (id(32) ‖ key(32))×n)×n_forks
/// ‖ u32 n_epochs ‖ (epoch(8) ‖ epoch_secret(32))×n`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PersistTree {
    pub group_id: Vec<u8>,
    /// The last KEEP_EPOCHS confirmed commits, oldest→newest, as `(blake3 hash, full signed
    /// bytes)` — the chain §5.1's longest-valid-chain rule re-evaluates. The caller caps the
    /// depth (same bound as today's key retention); the codec carries what it is given.
    pub commit_chain: Vec<([u8; 32], Vec<u8>)>,
    /// Content-addressed ref of the current public tree blob (may be empty pre-M2).
    pub tree_blob_ref: Vec<u8>,
    /// The serialized [`RatchetTree`] bytes themselves (may be empty when only the ref is
    /// held; kept alongside the ref so a device can re-publish the blob after mailbox GC).
    pub tree_bytes: Vec<u8>,
    pub my_leaf_index: u32,
    /// This device's current leaf secret (replaced wholesale on every own path update).
    pub my_leaf_secret: [u8; 32],
    /// Path secrets from my leaf toward the root, leaf→root order.
    pub my_path_secrets: Vec<[u8; 32]>,
    pub fork_cache: Vec<ForkCacheEntry>,
    /// Derived-epoch cache: `(epoch, epoch_secret)` for the retained window. Subject to the
    /// same KEEP_EPOCHS pruning as today's `my_epoch_keys` (enforced in M5).
    pub epoch_secrets: Vec<(u64, [u8; 32])>,
}

impl PersistTree {
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = vec![PERSIST_TREE_V1];
        lp(&mut out, &self.group_id);
        out.extend_from_slice(&(self.commit_chain.len() as u32).to_le_bytes());
        for (h, bytes) in &self.commit_chain {
            out.extend_from_slice(h);
            lp(&mut out, bytes);
        }
        lp(&mut out, &self.tree_blob_ref);
        lp(&mut out, &self.tree_bytes);
        out.extend_from_slice(&self.my_leaf_index.to_le_bytes());
        out.extend_from_slice(&self.my_leaf_secret);
        out.extend_from_slice(&(self.my_path_secrets.len() as u32).to_le_bytes());
        for s in &self.my_path_secrets {
            out.extend_from_slice(s);
        }
        out.extend_from_slice(&(self.fork_cache.len() as u32).to_le_bytes());
        for f in &self.fork_cache {
            out.extend_from_slice(&f.epoch.to_le_bytes());
            out.extend_from_slice(&f.commit_hash);
            out.extend_from_slice(&(f.sender_keys.len() as u32).to_le_bytes());
            for (id, key) in &f.sender_keys {
                out.extend_from_slice(id);
                out.extend_from_slice(key);
            }
        }
        out.extend_from_slice(&(self.epoch_secrets.len() as u32).to_le_bytes());
        for (e, s) in &self.epoch_secrets {
            out.extend_from_slice(&e.to_le_bytes());
            out.extend_from_slice(s);
        }
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        if r.u8()? != PERSIST_TREE_V1 {
            return Err(CoreError::Encoding("treekem wire: unknown PersistTree version"));
        }
        let group_id = r.bytes_lp()?.to_vec();
        let n = r.u32()?;
        let mut commit_chain = Vec::new();
        for _ in 0..n {
            let h = r.array()?;
            let bytes = r.bytes_lp()?.to_vec();
            commit_chain.push((h, bytes));
        }
        let tree_blob_ref = r.bytes_lp()?.to_vec();
        let tree_bytes = r.bytes_lp()?.to_vec();
        let my_leaf_index = r.u32()?;
        let my_leaf_secret = r.array()?;
        let n = r.u32()?;
        let mut my_path_secrets = Vec::new();
        for _ in 0..n {
            my_path_secrets.push(r.array()?);
        }
        let n = r.u32()?;
        let mut fork_cache = Vec::new();
        for _ in 0..n {
            let epoch = r.u64()?;
            let commit_hash = r.array()?;
            let k = r.u32()?;
            let mut sender_keys = Vec::new();
            for _ in 0..k {
                let id = r.array()?;
                let key = r.array()?;
                sender_keys.push((id, key));
            }
            fork_cache.push(ForkCacheEntry { epoch, commit_hash, sender_keys });
        }
        let n = r.u32()?;
        let mut epoch_secrets = Vec::new();
        for _ in 0..n {
            let e = r.u64()?;
            let s = r.array()?;
            epoch_secrets.push((e, s));
        }
        expect_consumed(
            &r,
            Self {
                group_id,
                commit_chain,
                tree_blob_ref,
                tree_bytes,
                my_leaf_index,
                my_leaf_secret,
                my_path_secrets,
                fork_cache,
                epoch_secrets,
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Fixed, deterministic sample values — round-trip tests must be reproducible bytes,
    // not RNG-dependent (test-vector discipline for a wire contract).
    fn leaf(fill: u8) -> LeafNode {
        LeafNode {
            leaf_kem_x: [fill; KEM_X_LEN],
            leaf_kem_pq: [fill.wrapping_add(1); MLKEM_EK_LEN],
            device_credential: vec![0xC0, fill, 0x01],
            leaf_binding_sig: vec![0x51, 0x6E, fill],
        }
    }

    fn parent(fill: u8, blank: bool) -> ParentNode {
        ParentNode {
            blank,
            node_kem_x: [fill; KEM_X_LEN],
            node_kem_pq: [fill.wrapping_add(2); MLKEM_EK_LEN],
            unmerged_leaves: vec![0, 3, 7],
        }
    }

    fn proposal_add() -> Proposal {
        Proposal {
            group_id: b"circle-1".to_vec(),
            epoch: 41,
            body: ProposalBody::Add { leaf_node: leaf(5) },
            sender_leaf: 2,
            sig: vec![0xAB; 7],
        }
    }

    fn update_path() -> UpdatePath {
        UpdatePath {
            leaf_node: leaf(9),
            nodes: vec![
                UpdatePathNode {
                    node_kem_x: [3; KEM_X_LEN],
                    node_kem_pq: [4; MLKEM_EK_LEN],
                    ciphertexts: vec![
                        PathSecretCiphertext {
                            resolution_index: 6,
                            eph_x: [7; KEM_X_LEN],
                            pq_ct: vec![8; 11],
                            wrapped_path_secret: vec![9; 60],
                        },
                        PathSecretCiphertext {
                            resolution_index: 12,
                            eph_x: [13; KEM_X_LEN],
                            pq_ct: vec![14; 5],
                            wrapped_path_secret: vec![15; 3],
                        },
                    ],
                },
                UpdatePathNode {
                    node_kem_x: [16; KEM_X_LEN],
                    node_kem_pq: [17; MLKEM_EK_LEN],
                    ciphertexts: vec![],
                },
            ],
        }
    }

    fn commit(with_path: bool) -> Commit {
        Commit {
            group_id: b"circle-1".to_vec(),
            epoch: 42,
            parent_commit_hash: [0xEE; 32],
            proposals: vec![
                proposal_add(),
                Proposal {
                    group_id: b"circle-1".to_vec(),
                    epoch: 41,
                    body: ProposalBody::Remove { leaf_index: 4 },
                    sender_leaf: 0,
                    sig: vec![0xCD; 4],
                },
                Proposal {
                    group_id: b"circle-1".to_vec(),
                    epoch: 41,
                    body: ProposalBody::Update { leaf_node: leaf(20) },
                    sender_leaf: 1,
                    sig: vec![0xEF; 5],
                },
            ],
            update_path: if with_path { Some(update_path()) } else { None },
            tree_hash: [0x77; 32],
            confirmation_mac: vec![0x33; 32],
            sender_leaf: 2,
            sig: vec![0x44; 9],
        }
    }

    fn group_info() -> GroupInfo {
        GroupInfo {
            group_id: b"circle-1".to_vec(),
            epoch: 42,
            tree_blob_ref: b"blake3:abcdef".to_vec(),
            confirmed_transcript_hash: [0x55; 32],
            tree_hash: [0x66; 32],
            signer_leaf: 3,
            sig: vec![0x99; 6],
        }
    }

    fn welcome() -> Welcome {
        Welcome {
            group_info: group_info(),
            joiners: vec![
                WelcomeJoiner {
                    joiner_device_id: [0xD1; 32],
                    eph_x: [0xD2; KEM_X_LEN],
                    pq_ct: vec![0xD3; 8],
                    wrapped: vec![0xD4; 40],
                },
                WelcomeJoiner {
                    joiner_device_id: [0xD5; 32],
                    eph_x: [0xD6; KEM_X_LEN],
                    pq_ct: vec![],
                    wrapped: vec![0xD7],
                },
            ],
        }
    }

    fn persist_tree() -> PersistTree {
        PersistTree {
            group_id: b"circle-1".to_vec(),
            commit_chain: vec![([0xA1; 32], vec![1, 2, 3]), ([0xA2; 32], vec![4, 5])],
            tree_blob_ref: b"blake3:tree".to_vec(),
            tree_bytes: ratchet_tree().to_bytes(),
            my_leaf_index: 4,
            my_leaf_secret: [0xB1; 32],
            my_path_secrets: vec![[0xB2; 32], [0xB3; 32]],
            fork_cache: vec![ForkCacheEntry {
                epoch: 41,
                commit_hash: [0xC1; 32],
                sender_keys: vec![([0xC2; 32], [0xC3; 32]), ([0xC4; 32], [0xC5; 32])],
            }],
            epoch_secrets: vec![(40, [0xE1; 32]), (41, [0xE2; 32])],
        }
    }

    fn ratchet_tree() -> RatchetTree {
        RatchetTree {
            slots: vec![
                TreeSlot::Leaf(leaf(1)),
                TreeSlot::Parent(parent(2, false)),
                TreeSlot::Leaf(leaf(3)),
                TreeSlot::Parent(parent(4, true)),
                TreeSlot::Blank,
            ],
        }
    }

    /// Every strict prefix of a valid encoding must fail to parse (truncation is detected
    /// wherever it lands — mid-field, at a field boundary, inside a count), and a single
    /// appended byte must fail too (exact-consumption: nothing rides after these formats).
    fn assert_prefixes_and_trailer_rejected<T>(bytes: &[u8], parse: impl Fn(&[u8]) -> Result<T>) {
        for cut in 0..bytes.len() {
            assert!(parse(&bytes[..cut]).is_err(), "prefix of len {cut} must be rejected");
        }
        let mut extended = bytes.to_vec();
        extended.push(0);
        assert!(parse(&extended).is_err(), "trailing byte must be rejected");
    }

    /// Decode(encode(x)) == x AND encode(decode(bytes)) == bytes: the codec is a bijection
    /// on its value set, so blobs persisted by M0 re-encode byte-identically forever
    /// (content-addressed refs and commit hashes depend on this stability).
    fn assert_byte_stable<T: PartialEq + std::fmt::Debug>(
        value: &T,
        to_bytes: impl Fn(&T) -> Vec<u8>,
        parse: impl Fn(&[u8]) -> Result<T>,
    ) {
        let bytes = to_bytes(value);
        let back = parse(&bytes).expect("valid encoding must parse");
        assert_eq!(&back, value, "decoded value differs");
        assert_eq!(to_bytes(&back), bytes, "re-encode must reproduce the exact bytes");
        assert_prefixes_and_trailer_rejected(&bytes, parse);
    }

    #[test]
    fn leaf_and_parent_nodes_round_trip_byte_stably() {
        assert_byte_stable(&leaf(1), LeafNode::to_bytes, LeafNode::from_bytes);
        assert_byte_stable(&parent(2, false), ParentNode::to_bytes, ParentNode::from_bytes);
        assert_byte_stable(&parent(2, true), ParentNode::to_bytes, ParentNode::from_bytes);

        // Reserved parent flag bits are rejected — a future flag needs a version break, and a
        // tampered flags byte must not decode into a plausible node.
        let mut bad = parent(2, false).to_bytes();
        bad[0] = 0x02;
        assert!(ParentNode::from_bytes(&bad).is_err(), "reserved flag bits must reject");
    }

    #[test]
    fn ratchet_tree_round_trips_byte_stably_and_rejects_bad_slot_tags() {
        let tree = ratchet_tree();
        assert_byte_stable(&tree, RatchetTree::to_bytes, RatchetTree::from_bytes);

        // Exact layout spot-check (fixed input → known bytes): 5 slots LE, then the first
        // slot tag is 0x01 (leaf) whose first key byte follows immediately (no inner lp).
        let bytes = tree.to_bytes();
        assert_eq!(&bytes[..4], &5u32.to_le_bytes());
        assert_eq!(bytes[4], 0x01);
        assert_eq!(bytes[5], 1, "leaf_kem_x starts right after the slot tag");
        // The final slot is the blank — encoded as the single tag byte 0x00.
        assert_eq!(*bytes.last().unwrap(), 0x00);

        // An unknown slot tag is a parse error, not a skip.
        let mut bad = bytes.clone();
        bad[4] = 0x03;
        assert!(RatchetTree::from_bytes(&bad).is_err(), "unknown slot tag must reject");
    }

    #[test]
    fn proposal_variants_round_trip_and_remove_matches_the_spec_bytes_exactly() {
        assert_byte_stable(&proposal_add(), Proposal::to_bytes, Proposal::from_bytes);
        let update = Proposal {
            group_id: b"g2".to_vec(),
            epoch: 9,
            body: ProposalBody::Update { leaf_node: leaf(30) },
            sender_leaf: 1,
            sig: vec![1, 2, 3],
        };
        assert_byte_stable(&update, Proposal::to_bytes, Proposal::from_bytes);

        // A Remove is small enough to pin the ENTIRE §3.4 layout by hand:
        // ptype(1)=2 ‖ lp("g") ‖ epoch(8)=7 ‖ leaf_index(4)=3 ‖ sender_leaf(4)=2 ‖ lp(sig).
        let remove = Proposal {
            group_id: b"g".to_vec(),
            epoch: 7,
            body: ProposalBody::Remove { leaf_index: 3 },
            sender_leaf: 2,
            sig: vec![0xAA, 0xAA],
        };
        let mut expected = vec![2u8];
        expected.extend_from_slice(&1u32.to_le_bytes());
        expected.extend_from_slice(b"g");
        expected.extend_from_slice(&7u64.to_le_bytes());
        expected.extend_from_slice(&3u32.to_le_bytes());
        expected.extend_from_slice(&2u32.to_le_bytes());
        expected.extend_from_slice(&2u32.to_le_bytes());
        expected.extend_from_slice(&[0xAA, 0xAA]);
        assert_eq!(remove.to_bytes(), expected, "Remove encoding must match §3.4 byte-for-byte");
        assert_byte_stable(&remove, Proposal::to_bytes, Proposal::from_bytes);

        // An unknown proposal type must reject (fail closed, never a default variant).
        let mut bad = remove.to_bytes();
        bad[0] = 9;
        assert!(Proposal::from_bytes(&bad).is_err(), "unknown ptype must reject");
    }

    #[test]
    fn update_path_round_trips_byte_stably() {
        assert_byte_stable(&update_path(), UpdatePath::to_bytes, UpdatePath::from_bytes);
        // Empty path (leaf only) is a valid encoding too.
        let bare = UpdatePath { leaf_node: leaf(1), nodes: vec![] };
        assert_byte_stable(&bare, UpdatePath::to_bytes, UpdatePath::from_bytes);
    }

    #[test]
    fn commit_round_trips_with_and_without_path_and_rejects_ambiguous_flag() {
        assert_byte_stable(&commit(true), Commit::to_bytes, Commit::from_bytes);
        assert_byte_stable(&commit(false), Commit::to_bytes, Commit::from_bytes);

        // has_path must be exactly 0/1: any other value is an ambiguous encoding, which
        // would let two byte strings carry one logical commit and corrupt hash-ordered
        // fork resolution. Locate the flag byte structurally, not by magic offset.
        let c = commit(false);
        let bytes = c.to_bytes();
        // ...the flag sits right before tree_hash(32) ‖ lp(mac) ‖ sender_leaf(4) ‖ lp(sig).
        let tail = 32 + 4 + c.confirmation_mac.len() + 4 + 4 + c.sig.len();
        let flag_at = bytes.len() - tail - 1;
        assert_eq!(bytes[flag_at], 0);
        let mut bad = bytes.clone();
        bad[flag_at] = 2;
        assert!(Commit::from_bytes(&bad).is_err(), "has_path flag must be exactly 0 or 1");
    }

    #[test]
    fn group_info_and_welcome_round_trip_byte_stably() {
        assert_byte_stable(&group_info(), GroupInfo::to_bytes, GroupInfo::from_bytes);
        assert_byte_stable(&welcome(), Welcome::to_bytes, Welcome::from_bytes);
        // A Welcome with zero joiners still round-trips (a committer may cache one early).
        let empty = Welcome { group_info: group_info(), joiners: vec![] };
        assert_byte_stable(&empty, Welcome::to_bytes, Welcome::from_bytes);
    }

    #[test]
    fn persist_tree_round_trips_byte_stably_and_rejects_unknown_versions() {
        assert_byte_stable(&persist_tree(), PersistTree::to_bytes, PersistTree::from_bytes);

        // Version discipline: an unknown version byte fails closed — secret-bearing state is
        // never decoded on a guess.
        let mut bad = persist_tree().to_bytes();
        bad[0] = 0xFF;
        assert!(PersistTree::from_bytes(&bad).is_err(), "unknown PersistTree version must reject");

        // The embedded tree bytes decode back to the same tree (nesting stays coherent).
        let pt = persist_tree();
        assert_eq!(RatchetTree::from_bytes(&pt.tree_bytes).unwrap(), ratchet_tree());
    }
}
