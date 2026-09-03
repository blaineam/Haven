//! TreeKEM — MLS-style group ratcheting on Haven's own PQ primitives, shipped in 1.0.7
//! (see `docs/TREEKEM-DESIGN.md` §3-§6).
//!
//! **This is the whole pure tree, not a type skeleton.** It carries the wire formats
//! (§3.4) and their serialization, array-tree math (§3.1), node key material and
//! path-secret hybrid encryption (§3.2), UpdatePath build/apply (§4.4), the epoch key
//! schedule (§3.3) with the §6.2 deletion discipline, the proposal/commit builders and
//! their receiver-side appliers (§4), the Welcome joiner rail (§4.2), the fork tie-break
//! and chain rule (§5.1), the per-message sender ratchet for the DM/live lane (§6.5),
//! and `PersistTree` with the bounded KEEP_EPOCHS/KEEP_FORKS pruner that WIPES what ages
//! out rather than merely dropping it.
//!
//! **What is deliberately NOT here: engine wiring.** No `NetState`, no receive router, no
//! shadow trees, no keying flip, no creator/admin authority — those live in
//! `core/haven-ffi/src/lib.rs` (the `mls_*` functions) and `device.rs`. Everything here is
//! PURE: signatures arrive as caller-supplied closures and all randomness expands from a
//! caller-supplied `entropy` seed, so identical inputs yield identical bytes on every
//! replica. That is what makes the tree testable against fixed vectors and WASM-clean, and
//! it is load-bearing — do not reach for the clock, the OS RNG, or engine state in here.
//!
//! Whether a circle actually keys under the tree is the ENGINE's decision, gated per circle:
//! it needs a verified owner and every member affirmatively MLS-capable, else the circle
//! stays on the legacy sender-key epochs (`device::circle_fully_mls_capable`,
//! `docs/SWITCH-FLIP-1.0.7.md`).
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
// Defined with the wire formats because they are part of the byte contract: the sign/verify
// paths below consume them, and pinning them with the layouts is what lets builds from
// different stages agree on what any given signature covers. Follows the
// `CRED_DOMAIN`/`LIST_DOMAIN` discipline.

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
        // `checked_add`, NOT `self.i + n`. DEFENSIVE, not a live bug: `n` comes from an untrusted
        // u32 length prefix, so on a 32-bit `usize` the sum would WRAP, this bounds check would
        // pass, and the slice below would panic with start > end. Every target Haven ships today
        // is 64-bit (iOS/macOS/Android/Windows/Linux native), where `i + n` cannot overflow — so
        // this is unreachable, and is kept because the cost is one `checked_add` and the failure
        // mode would be a silent wrap in release. Do NOT read the wasm32 block in Cargo.toml as a
        // live target: the web client was abandoned 2026-06-22 and `core/haven-wasm` deleted
        // (docs/WEB-PARITY.md); that block is leftover scaffolding.
        let end = self
            .i
            .checked_add(n)
            .ok_or(CoreError::Encoding("treekem wire: length overflow"))?;
        if end > self.b.len() {
            return Err(CoreError::Encoding("treekem wire: unexpected end of input"));
        }
        let s = &self.b[self.i..end];
        self.i = end;
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

// ── PersistTree (§5.4) — persisted tree state + its pruner ───────────────────────────────

/// One losing-fork sender-key cache entry (§5.2 step 2): keys derived from a commit that
/// lost the hash tie-break, kept so events sealed under it before its author learned it
/// lost still open. Bounded by KEEP_FORKS within the KEEP_EPOCHS window, enforced by
/// [`PersistTree::prune`] (which wipes the sender keys it ages out, §6.3-2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ForkCacheEntry {
    pub epoch: u64,
    /// blake3 of the losing commit's full signed bytes (the fork-cache lookup key).
    pub commit_hash: [u8; 32],
    /// `(sender id, 32-byte sender key)` pairs derived under the losing epoch secret.
    pub sender_keys: Vec<([u8; 32], [u8; 32])>,
}

/// Per-circle tree state, shaped to ride the platform-encrypted state blob alongside
/// `PersistCircle`. The codec and the §6.2 pruner below are complete, but **nothing in
/// production writes or reads one yet** — `PersistTree` appears nowhere in `haven-ffi`, so
/// the engine's live tree state is not persisted through this type.
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
    /// Derived-epoch cache: `(epoch, epoch_secret)` for the retained window. Held to the same
    /// KEEP_EPOCHS depth as lib.rs's `my_epoch_keys`, enforced by [`PersistTree::prune`].
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

impl ForkCacheEntry {
    /// Zero every losing-fork sender key this entry holds, in place (§6.2 / §6.3-2). Called by the
    /// pruner the instant an entry ages out of the retained window — wiping, not merely dropping, is
    /// the forward-secrecy property: a captured state blob must not carry a superseded fork's keys
    /// past the window, and a `retain` that only drops would leave them in freed memory.
    pub fn wipe(&mut self) {
        for (_, key) in self.sender_keys.iter_mut() {
            wipe_secret(key);
        }
    }
}

impl PersistTree {
    /// KEEP_EPOCHS (§6.2): retained epoch depth — identical to lib.rs `prune_epoch_keys` so the tree
    /// state and the sender-key store age out on the SAME 4-epoch window (`init_secret`'s one-way link
    /// means nothing older is re-derivable anyway; the pruner makes the *stored* material match).
    pub const KEEP_EPOCHS: usize = 4;
    /// KEEP_FORKS (§6.2 fork-cache row): losing-fork caches retained PER epoch inside the window.
    pub const KEEP_FORKS: usize = 2;

    /// Enforce the §6.2 bounded-window deletion on the PERSISTED tree state — the §6.3-2 proof
    /// obligation ("the fork cache as an FS leak … must age out on the same pruner") plus the
    /// `epoch_secret_n` window row. WIPES (not merely drops) every secret that ages out: the
    /// one-way-schedule FS claim is that a captured state blob opens nothing older than the retained
    /// window, which only holds if aged-out `epoch_secret`s and fork sender keys are zeroed rather
    /// than left in the serialized bytes. The commit CHAIN is public bytes (no secret) so it is only
    /// BOUNDED — the §10 "every cache has a named cap and a pruner" discipline — never wiped.
    pub fn prune(&mut self) {
        // (a) epoch_secrets: keep the newest KEEP_EPOCHS; WIPE each older one in place, then drop it.
        // Sort ascending so the oldest sit at the front; wipe+remove from the front until in-window.
        self.epoch_secrets.sort_by_key(|(e, _)| *e);
        while self.epoch_secrets.len() > Self::KEEP_EPOCHS {
            wipe_secret(&mut self.epoch_secrets[0].1);
            self.epoch_secrets.remove(0);
        }
        // The retained window floor — a fork cache older than this is outside the window entirely.
        let floor = self.epoch_secrets.first().map(|(e, _)| *e).unwrap_or(0);

        // (b) fork_cache: WIPE+drop any entry below the floor, then cap KEEP_FORKS per retained epoch
        // (keeping the largest commit_hash — deterministic, matching the §5.1 tie-break order).
        for f in self.fork_cache.iter_mut() {
            if f.epoch < floor {
                f.wipe();
            }
        }
        self.fork_cache.retain(|f| f.epoch >= floor);
        let mut by_epoch: BTreeMap<u64, Vec<usize>> = BTreeMap::new();
        for (i, f) in self.fork_cache.iter().enumerate() {
            by_epoch.entry(f.epoch).or_default().push(i);
        }
        let mut drop_idx: std::collections::HashSet<usize> = std::collections::HashSet::new();
        for (_, mut idxs) in by_epoch {
            if idxs.len() > Self::KEEP_FORKS {
                idxs.sort_by(|&a, &b| self.fork_cache[a].commit_hash.cmp(&self.fork_cache[b].commit_hash));
                for &i in &idxs[..idxs.len() - Self::KEEP_FORKS] {
                    drop_idx.insert(i);
                }
            }
        }
        for &i in &drop_idx {
            self.fork_cache[i].wipe();
        }
        let mut i = 0usize;
        self.fork_cache.retain(|_| {
            let keep = !drop_idx.contains(&i);
            i += 1;
            keep
        });

        // (c) commit_chain: bound to the newest KEEP_EPOCHS commits (stored oldest→newest). Public
        // bytes only — no wipe, just cap the growth §10 warns becomes a leak when a bound is missing.
        if self.commit_chain.len() > Self::KEEP_EPOCHS {
            let cut = self.commit_chain.len() - Self::KEEP_EPOCHS;
            self.commit_chain.drain(..cut);
        }
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

// ═════════════════════════════════════════════════════════════════════════════════════════
// Stage M1 — the pure tree module (§3.2 node key material, §3.3 epoch key schedule,
// §5.1 fork tie-break + chain rule; design §9 row M1).
//
// Everything below is a PURE function of its inputs: entropy and time are caller-supplied,
// there is no I/O, no engine state, no OsRng. Same inputs → same bytes, always — the M2
// shadow-mode comparison and cross-device convergence depend on that, so any source of
// nondeterminism here (an unseeded RNG, a HashMap iteration order, a platform-dependent
// serialization) is a correctness bug, not a style issue.
// ═════════════════════════════════════════════════════════════════════════════════════════

use std::cmp::Ordering;
use std::collections::BTreeMap;

use hkdf::Hkdf;
use ml_kem::kem::{Decapsulate, Encapsulate};
use ml_kem::{Encoded, EncodedSizeUser, KemCore, MlKem768};
use rand::SeedableRng;
use rand_chacha::ChaCha20Rng;
use sha2::Sha256;
use x25519_dalek::{PublicKey as XPublicKey, StaticSecret as XStaticSecret};

use crate::identity::{DecapKey, EncapKey};

// ── Derivation labels (§3.2, §3.3) ───────────────────────────────────────────────────────
//
// These are part of the cryptographic contract exactly like the signature domains above:
// change one byte and every device derives different keys. The committed test vectors
// below assert exact output bytes so an accidental label change fails loudly.

/// HKDF salt for every path/node/commit derivation in the tree (§3.2).
pub const TREEKEM_SALT: &[u8] = b"haven-treekem-v1";
/// Info label binding a path-secret ciphertext to `(group_id, epoch, node_index)` (§3.2),
/// so a tree ciphertext can never be confused with a content wrap.
pub const TREE_CT_DOMAIN: &[u8] = b"haven-treekem-ct-v1";
/// blake3 domain for the epoch context (§3.3).
pub const EPOCH_CTX_DOMAIN: &[u8] = b"haven-mls-ctx-v1";
/// HKDF salt for the epoch secret (§3.3).
pub const EPOCH_SALT: &[u8] = b"haven-mls-epoch-v1";
/// Info label for per-leaf sender keys (§3.3) — the 32-byte "epoch keys" the content
/// layer consumes unchanged.
pub const SENDER_KEY_DOMAIN: &[u8] = b"haven-mls-sender-v1";

// blake3 domains M1 pins (companions to §3.2/§3.3's table; frozen by the committed vectors).
const TREE_HASH_DOMAIN: &[u8] = b"haven-mls-treehash-v1";
const TRANSCRIPT_DOMAIN: &[u8] = b"haven-mls-transcript-v1";
const COMMIT_CONTENT_DOMAIN: &[u8] = b"haven-mls-commit-content-v1";
const ENTROPY_DOMAIN: &[u8] = b"haven-treekem-entropy-v1";
// The SAME salt as `crypto.rs` `combine()` — §3.2 mandates the identical transcript-bound
// hybrid combine, distinguished only by the info label above.
const HYBRID_KEM_SALT: &[u8] = b"haven-hybrid-kem-v2";

// ── Secret hygiene ───────────────────────────────────────────────────────────────────────

/// Volatile-zero a 32-byte secret in place. Deletion is a *security property* of the epoch
/// schedule (§6.2's table): the one-way claim only holds if consumed secrets are actually
/// destroyed, so the schedule wipes its inputs itself rather than trusting every caller to
/// remember. `write_volatile` keeps the wipe of a dead buffer from being optimized away.
pub fn wipe_secret(b: &mut [u8; 32]) {
    for i in 0..b.len() {
        unsafe { core::ptr::write_volatile(&mut b[i], 0) };
    }
    core::sync::atomic::compiler_fence(core::sync::atomic::Ordering::SeqCst);
}

/// HKDF-SHA256 → 32 bytes (the house pattern of `identity.rs:162` / `groupkey.rs:121`).
fn hkdf32(salt: &[u8], ikm: &[u8], info: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = [0u8; 32];
    hk.expand(info, &mut out).expect("32 is a valid HKDF length");
    out
}

/// HKDF-*expand* from a 32-byte PRK (§3.3's `HKDF-expand(epoch_secret, label)` lines).
fn hkdf_expand32(prk: &[u8; 32], info: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::from_prk(prk).expect("32-byte PRK is valid for SHA-256");
    let mut out = [0u8; 32];
    hk.expand(info, &mut out).expect("32 is a valid HKDF length");
    out
}

// ── Array-tree math (§3.1) ───────────────────────────────────────────────────────────────
//
// Left-balanced binary tree over an array of node slots: leaf i at index 2i, parents at
// odd indices, in-order layout. All pure index arithmetic; the recursive-reference test
// below cross-checks every function for all tree sizes up to 40 leaves.

/// Number of trailing one bits — the height of the complete subtree rooted at `x`.
fn level(x: usize) -> u32 {
    x.trailing_ones()
}

/// Array width for a tree of `n_leaves` leaves.
pub fn node_width(n_leaves: usize) -> usize {
    if n_leaves == 0 {
        0
    } else {
        2 * n_leaves - 1
    }
}

/// Array index of the tree root.
pub fn root_index(n_leaves: usize) -> Result<usize> {
    if n_leaves == 0 {
        return Err(CoreError::Encoding("treekem: empty tree has no root"));
    }
    let w = node_width(n_leaves);
    Ok((1usize << (usize::BITS - 1 - w.leading_zeros())) - 1)
}

/// Left child of an interior node. The left subtree is always complete, so this is pure
/// bit arithmetic with no width dependence.
pub fn left_child(x: usize) -> Result<usize> {
    let k = level(x);
    if k == 0 {
        return Err(CoreError::Encoding("treekem: leaf has no children"));
    }
    Ok(x ^ (0x01 << (k - 1)))
}

/// Right child of an interior node. In a left-balanced tree the right subtree may be
/// truncated, so the complete-tree candidate descends left until it lands in range.
pub fn right_child(x: usize, n_leaves: usize) -> Result<usize> {
    let k = level(x);
    if k == 0 {
        return Err(CoreError::Encoding("treekem: leaf has no children"));
    }
    let w = node_width(n_leaves);
    if x >= w {
        return Err(CoreError::Encoding("treekem: node index out of range"));
    }
    let mut r = x ^ (0x03 << (k - 1));
    while r >= w {
        r = left_child(r)?;
    }
    Ok(r)
}

/// The parent candidate ignoring width (complete-tree step).
fn parent_step(x: usize) -> usize {
    let k = level(x);
    let b = (x >> (k + 1)) & 0x01;
    (x | (1 << k)) ^ (b << (k + 1))
}

/// Parent of a node; `None` at the root.
pub fn parent_index(x: usize, n_leaves: usize) -> Result<Option<usize>> {
    let w = node_width(n_leaves);
    if x >= w {
        return Err(CoreError::Encoding("treekem: node index out of range"));
    }
    if x == root_index(n_leaves)? {
        return Ok(None);
    }
    let mut p = parent_step(x);
    while p >= w {
        p = parent_step(p);
    }
    Ok(Some(p))
}

/// The other child of `x`'s parent; `None` at the root.
pub fn sibling_index(x: usize, n_leaves: usize) -> Result<Option<usize>> {
    match parent_index(x, n_leaves)? {
        None => Ok(None),
        Some(p) => {
            let l = left_child(p)?;
            Ok(Some(if l == x { right_child(p, n_leaves)? } else { l }))
        }
    }
}

/// The nodes from `x`'s parent up to and including the root (empty for a 1-node tree).
pub fn direct_path(x: usize, n_leaves: usize) -> Result<Vec<usize>> {
    let mut out = Vec::new();
    let mut cur = x;
    while let Some(p) = parent_index(cur, n_leaves)? {
        out.push(p);
        cur = p;
    }
    Ok(out)
}

/// The sibling of `x`, then the sibling of each direct-path node below the root — one
/// copath node per direct-path node.
pub fn copath(x: usize, n_leaves: usize) -> Result<Vec<usize>> {
    let mut out = Vec::new();
    let mut cur = x;
    while let Some(s) = sibling_index(cur, n_leaves)? {
        out.push(s);
        cur = parent_index(cur, n_leaves)?.expect("sibling exists implies parent exists");
    }
    Ok(out)
}

/// Array slot of leaf `i` (leaf i lives at index 2i).
pub const fn leaf_slot(leaf_index: u32) -> usize {
    2 * leaf_index as usize
}

/// Whether the subtree rooted at `x` contains the given leaf slot. In-order layout makes
/// every subtree a contiguous index range: `[x - (2^k - 1), min(x + (2^k - 1), width-1)]`.
pub fn subtree_contains(x: usize, leaf_slot: usize, n_leaves: usize) -> bool {
    let mask = (1usize << level(x)) - 1;
    let lo = x - mask;
    let hi = (x + mask).min(node_width(n_leaves).saturating_sub(1));
    leaf_slot >= lo && leaf_slot <= hi
}

// ── Node key material (§3.2) ─────────────────────────────────────────────────────────────

/// A node's hybrid KEM keypair, derived deterministically from its 32-byte node secret via
/// the exact `Identity::from_seed` pattern (`identity.rs:161-178`) under the tree's own
/// salt — node keys can never collide with identity keys derived from the same bytes.
/// Secrets stay private to the module; only the public halves are exposed.
pub struct NodeKeypair {
    x_secret: XStaticSecret,
    pq_dk: DecapKey,
    /// X25519 public key (classical half).
    pub kem_x: [u8; KEM_X_LEN],
    /// ML-KEM-768 encapsulation key (post-quantum half).
    pub kem_pq: [u8; MLKEM_EK_LEN],
}

/// `path_secret[i+1] = HKDF(salt="haven-treekem-v1", ikm=path_secret[i], info="path")`.
pub fn derive_path_secret(prev: &[u8; 32]) -> [u8; 32] {
    hkdf32(TREEKEM_SALT, prev, b"path")
}

/// `node_secret[i] = HKDF(salt="haven-treekem-v1", ikm=path_secret[i], info="node")`.
pub fn derive_node_secret(path_secret: &[u8; 32]) -> [u8; 32] {
    hkdf32(TREEKEM_SALT, path_secret, b"node")
}

/// `commit_secret = HKDF(salt="haven-treekem-v1", ikm=path_secret[root], info="commit")`.
/// For a 1-leaf tree (no parents) the chain is just the leaf secret, which is the root.
pub fn derive_commit_secret(root_path_secret: &[u8; 32]) -> [u8; 32] {
    hkdf32(TREEKEM_SALT, root_path_secret, b"commit")
}

/// Node keypair from a node secret: x25519 sk = HKDF(info="x25519"); ml-kem =
/// `MlKem768::generate(ChaCha20Rng(HKDF(info="ml-kem-768")))` (§3.2).
pub fn node_keypair(node_secret: &[u8; 32]) -> NodeKeypair {
    let x_secret = XStaticSecret::from(hkdf32(TREEKEM_SALT, node_secret, b"x25519"));
    let mut rng = ChaCha20Rng::from_seed(hkdf32(TREEKEM_SALT, node_secret, b"ml-kem-768"));
    let (pq_dk, pq_ek) = MlKem768::generate(&mut rng);
    let kem_x = XPublicKey::from(&x_secret).to_bytes();
    let ek = pq_ek.as_bytes();
    let mut kem_pq = [0u8; MLKEM_EK_LEN];
    kem_pq.copy_from_slice(&ek[..]);
    NodeKeypair { x_secret, pq_dk, kem_x, kem_pq }
}

/// Keypair for the node whose secret derives from this path secret (leaf keypairs use the
/// leaf secret, which is `path_secret[0]`).
pub fn node_keypair_from_path_secret(path_secret: &[u8; 32]) -> NodeKeypair {
    node_keypair(&derive_node_secret(path_secret))
}

/// The DEVICE-signed payload binding a leaf public key to a group (§3.4 `leaf_binding_sig`).
pub fn leaf_binding_payload(
    group_id: &[u8],
    leaf_kem_x: &[u8; KEM_X_LEN],
    leaf_kem_pq: &[u8; MLKEM_EK_LEN],
) -> Vec<u8> {
    let mut v = Vec::with_capacity(LEAF_DOMAIN.len() + group_id.len() + KEM_X_LEN + MLKEM_EK_LEN);
    v.extend_from_slice(LEAF_DOMAIN);
    v.extend_from_slice(group_id);
    v.extend_from_slice(leaf_kem_x);
    v.extend_from_slice(leaf_kem_pq);
    v
}

// ── Path-secret hybrid encryption (§3.2) ─────────────────────────────────────────────────

/// The tree's hybrid KEM key derivation: identical shape to `crypto.rs` `combine()` —
/// HKDF(salt="haven-hybrid-kem-v2", ikm = dh ‖ pq) with the full KEM transcript in the
/// info — except the info leads with `TREE_CT_DOMAIN ‖ group_id ‖ epoch ‖ node_index`
/// instead of `"content-aead-key"`, so no tree wrap can be replayed as a content wrap
/// (or into another group/epoch/node slot).
#[allow(clippy::too_many_arguments)]
fn tree_ct_key(
    dh: &[u8],
    pq_ss: &[u8],
    eph_x: &[u8; KEM_X_LEN],
    pq_ct: &[u8],
    recip_x: &[u8; KEM_X_LEN],
    recip_pq: &[u8; MLKEM_EK_LEN],
    group_id: &[u8],
    epoch: u64,
    resolution_index: u32,
) -> [u8; 32] {
    let mut ikm = Vec::with_capacity(dh.len() + pq_ss.len());
    ikm.extend_from_slice(dh);
    ikm.extend_from_slice(pq_ss);
    // group_id is length-prefixed inside the info so a crafted group id can't shift the
    // fixed fields behind it (unambiguous encoding = unambiguous domain separation).
    let mut info = Vec::new();
    info.extend_from_slice(TREE_CT_DOMAIN);
    info.extend_from_slice(&(group_id.len() as u32).to_le_bytes());
    info.extend_from_slice(group_id);
    info.extend_from_slice(&epoch.to_le_bytes());
    info.extend_from_slice(&resolution_index.to_le_bytes());
    info.extend_from_slice(eph_x);
    info.extend_from_slice(pq_ct);
    info.extend_from_slice(recip_x);
    info.extend_from_slice(recip_pq);
    hkdf32(HYBRID_KEM_SALT, &ikm, &info)
}

/// Per-ciphertext RNG sub-seed: the caller supplies ONE 32-byte entropy input per build
/// and every encapsulation draws from a distinct deterministic expansion of it, keyed by
/// which (direct-path node, resolution node) pair it serves. Determinism is the point —
/// rebuilding the same UpdatePath from the same inputs must reproduce identical bytes.
fn ct_seed(entropy: &[u8; 32], path_node: u32, resolution_index: u32) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(ENTROPY_DOMAIN);
    h.update(entropy);
    h.update(&path_node.to_le_bytes());
    h.update(&resolution_index.to_le_bytes());
    *h.finalize().as_bytes()
}

/// Hybrid-KEM-encrypt a 32-byte path secret to a bare node key pair. Deterministic: all
/// randomness (ephemeral X25519, ML-KEM encapsulation) comes from the caller's seed.
pub fn seal_path_secret(
    recipient_x: &[u8; KEM_X_LEN],
    recipient_pq: &[u8; MLKEM_EK_LEN],
    group_id: &[u8],
    epoch: u64,
    resolution_index: u32,
    path_secret: &[u8; 32],
    seed: &[u8; 32],
) -> Result<PathSecretCiphertext> {
    let mut rng = ChaCha20Rng::from_seed(*seed);
    let eph = XStaticSecret::random_from_rng(&mut rng);
    let eph_x = XPublicKey::from(&eph).to_bytes();
    let dh = eph.diffie_hellman(&XPublicKey::from(*recipient_x));
    let ek_enc = Encoded::<EncapKey>::try_from(&recipient_pq[..])
        .map_err(|_| CoreError::Crypto("treekem: bad ml-kem encapsulation key"))?;
    let ek = EncapKey::from_bytes(&ek_enc);
    let (pq_ct, pq_ss) = ek
        .encapsulate(&mut rng)
        .map_err(|_| CoreError::Crypto("treekem: ml-kem encapsulate failed"))?;
    let key = tree_ct_key(
        dh.as_bytes(),
        &pq_ss[..],
        &eph_x,
        &pq_ct[..],
        recipient_x,
        recipient_pq,
        group_id,
        epoch,
        resolution_index,
    );
    // seal_reproducible is sound here because the key is unique per ciphertext (fresh
    // ephemeral + transcript-bound derivation), and it keeps the whole build deterministic.
    Ok(PathSecretCiphertext {
        resolution_index,
        eph_x,
        pq_ct: pq_ct[..].to_vec(),
        wrapped_path_secret: crate::crypto::seal_reproducible(&key, path_secret),
    })
}

/// Decrypt a path secret addressed to `kp`'s node. Fails closed on any mismatch — wrong
/// node, wrong group, wrong epoch, tampered bytes all land in the same AEAD failure.
pub fn open_path_secret(
    kp: &NodeKeypair,
    group_id: &[u8],
    epoch: u64,
    ct: &PathSecretCiphertext,
) -> Result<[u8; 32]> {
    let dh = kp.x_secret.diffie_hellman(&XPublicKey::from(ct.eph_x));
    let pq_ct = ml_kem::Ciphertext::<MlKem768>::try_from(&ct.pq_ct[..])
        .map_err(|_| CoreError::Crypto("treekem: malformed ml-kem ciphertext"))?;
    let pq_ss = kp
        .pq_dk
        .decapsulate(&pq_ct)
        .map_err(|_| CoreError::Crypto("treekem: ml-kem decapsulate failed"))?;
    let key = tree_ct_key(
        dh.as_bytes(),
        &pq_ss[..],
        &ct.eph_x,
        &ct.pq_ct,
        &kp.kem_x,
        &kp.kem_pq,
        group_id,
        epoch,
        ct.resolution_index,
    );
    let pt = crate::crypto::open(&key, &ct.wrapped_path_secret)?;
    pt.try_into()
        .map_err(|_| CoreError::Crypto("treekem: path secret has wrong length"))
}

// ── Public-tree operations (§3.1, §4.2, §4.3) ────────────────────────────────────────────

impl RatchetTree {
    /// Build a tree from an ordered list of leaves, all parents blank (a fresh group before
    /// any UpdatePath, or a §4.1 creator bootstrapping from device lists).
    pub fn from_leaves(leaves: Vec<LeafNode>) -> Self {
        let mut slots = Vec::with_capacity(node_width(leaves.len()));
        for (i, l) in leaves.into_iter().enumerate() {
            if i > 0 {
                slots.push(TreeSlot::Blank);
            }
            slots.push(TreeSlot::Leaf(l));
        }
        Self { slots }
    }

    /// Leaf capacity of the array (blank leaf slots included — blanks are still slots).
    pub fn n_leaves(&self) -> usize {
        (self.slots.len() + 1) / 2
    }

    /// The leaf at `leaf_index`, if populated.
    pub fn leaf(&self, leaf_index: u32) -> Option<&LeafNode> {
        match self.slots.get(leaf_slot(leaf_index)) {
            Some(TreeSlot::Leaf(l)) => Some(l),
            _ => None,
        }
    }
}

/// Hash of the public tree: blake3 over the domain tag and the canonical serialization.
/// Sound as a whole-tree hash because the M0 codec is a byte-stable bijection (tested
/// there), and the tree travels as one blob anyway — no per-node Merkle structure needed.
pub fn tree_hash(tree: &RatchetTree) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(TREE_HASH_DOMAIN);
    h.update(&tree.to_bytes());
    *h.finalize().as_bytes()
}

/// MLS resolution of a node: the minimal set of non-blank nodes covering its subtree.
/// Non-blank leaf → itself. Non-blank parent → itself plus its unmerged leaves (an
/// unmerged leaf does NOT know the parent's secret, so it must be addressed directly).
/// Blank parent → resolutions of both children, left to right (order is part of the wire
/// contract: builders and receivers must enumerate identically).
pub fn resolution(tree: &RatchetTree, node: usize) -> Result<Vec<usize>> {
    let slot = tree
        .slots
        .get(node)
        .ok_or(CoreError::Encoding("treekem: node index out of range"))?;
    if node % 2 == 0 {
        // Leaf position.
        match slot {
            TreeSlot::Blank => Ok(Vec::new()),
            TreeSlot::Leaf(_) => Ok(vec![node]),
            TreeSlot::Parent(_) => Err(CoreError::Encoding("treekem: parent node in leaf slot")),
        }
    } else {
        match slot {
            TreeSlot::Leaf(_) => Err(CoreError::Encoding("treekem: leaf node in parent slot")),
            TreeSlot::Parent(p) if !p.blank => {
                let mut v = vec![node];
                for &l in &p.unmerged_leaves {
                    v.push(leaf_slot(l));
                }
                Ok(v)
            }
            // TreeSlot::Blank at a parent position and ParentNode{blank:true} are the same
            // logical state (M0 carries both encodings); resolve through the children.
            _ => {
                let n = tree.n_leaves();
                let mut v = resolution(tree, left_child(node)?)?;
                v.extend(resolution(tree, right_child(node, n)?)?);
                Ok(v)
            }
        }
    }
}

/// Add a leaf: first blank leaf slot wins (deterministic — every replica must assign the
/// same index), else the array grows by one leaf. The new leaf is recorded as *unmerged*
/// at every non-blank ancestor: those nodes' secrets predate the newcomer, so it cannot
/// know them, and path encryption must address it directly until an UpdatePath re-keys.
pub fn add_leaf(tree: &mut RatchetTree, leaf: LeafNode) -> Result<u32> {
    let mut target: Option<usize> = None;
    let mut i = 0;
    while i < tree.slots.len() {
        if matches!(tree.slots[i], TreeSlot::Blank) {
            target = Some(i);
            break;
        }
        i += 2;
    }
    let slot = match target {
        Some(s) => {
            tree.slots[s] = TreeSlot::Leaf(leaf);
            s
        }
        None => {
            if !tree.slots.is_empty() {
                tree.slots.push(TreeSlot::Blank);
            }
            tree.slots.push(TreeSlot::Leaf(leaf));
            tree.slots.len() - 1
        }
    };
    let leaf_index = (slot / 2) as u32;
    let n = tree.n_leaves();
    for p in direct_path(slot, n)? {
        if let TreeSlot::Parent(pn) = &mut tree.slots[p] {
            if !pn.blank {
                if let Err(pos) = pn.unmerged_leaves.binary_search(&leaf_index) {
                    pn.unmerged_leaves.insert(pos, leaf_index);
                }
            }
        }
    }
    Ok(leaf_index)
}

/// Remove a leaf (§4.3): blank the leaf and every node on its direct path — those nodes'
/// secrets were known to the removed device, so they are dead the moment it leaves; only
/// a fresh UpdatePath may repopulate them. Also purge the leaf from every unmerged list.
/// The array is NOT truncated: index stability keeps replicas trivially convergent, and
/// blank slots are reused by the next add.
pub fn remove_leaf(tree: &mut RatchetTree, leaf_index: u32) -> Result<()> {
    let slot = leaf_slot(leaf_index);
    match tree.slots.get(slot) {
        Some(TreeSlot::Leaf(_)) => {}
        _ => return Err(CoreError::Encoding("treekem: remove of unpopulated leaf")),
    }
    tree.slots[slot] = TreeSlot::Blank;
    let n = tree.n_leaves();
    for p in direct_path(slot, n)? {
        tree.slots[p] = TreeSlot::Blank;
    }
    for s in &mut tree.slots {
        if let TreeSlot::Parent(pn) = s {
            pn.unmerged_leaves.retain(|&l| l != leaf_index);
        }
    }
    Ok(())
}

/// The leaf's direct path paired with each node's copath child, keeping only nodes whose
/// copath child has a non-empty resolution (there is someone to encrypt to). Nodes
/// filtered out stay blank — nothing lives under their other side.
fn filtered_path_with_copath(tree: &RatchetTree, leaf_index: u32) -> Result<Vec<(usize, usize)>> {
    let n = tree.n_leaves();
    let slot = leaf_slot(leaf_index);
    let mut out = Vec::new();
    let mut prev = slot;
    for d in direct_path(slot, n)? {
        let l = left_child(d)?;
        let cop = if l == prev { right_child(d, n)? } else { l };
        if !resolution(tree, cop)?.is_empty() {
            out.push((d, cop));
        }
        prev = d;
    }
    Ok(out)
}

/// The filtered direct path of a leaf (see [`filtered_path_with_copath`]).
pub fn filtered_direct_path(tree: &RatchetTree, leaf_index: u32) -> Result<Vec<usize>> {
    Ok(filtered_path_with_copath(tree, leaf_index)?.into_iter().map(|(d, _)| d).collect())
}

/// Apply an UpdatePath to the public tree: replace the sender's leaf, blank its direct
/// path, then install the new node keys along the filtered path with EMPTY unmerged lists
/// (a re-keyed node's secret was just delivered to everyone under it — nobody is unmerged
/// anymore). One shared code path for committer and receivers, so their trees are
/// byte-identical by construction.
pub fn merge_update_path(tree: &mut RatchetTree, sender_leaf: u32, path: &UpdatePath) -> Result<()> {
    let slot = leaf_slot(sender_leaf);
    match tree.slots.get(slot) {
        Some(TreeSlot::Leaf(_)) => {}
        _ => return Err(CoreError::Encoding("treekem: update path sender leaf not in tree")),
    }
    let filtered = filtered_direct_path(tree, sender_leaf)?;
    if filtered.len() != path.nodes.len() {
        return Err(CoreError::Encoding("treekem: update path length mismatch"));
    }
    let n = tree.n_leaves();
    tree.slots[slot] = TreeSlot::Leaf(path.leaf_node.clone());
    for d in direct_path(slot, n)? {
        tree.slots[d] = TreeSlot::Blank;
    }
    for (d, pn) in filtered.iter().zip(&path.nodes) {
        tree.slots[*d] = TreeSlot::Parent(ParentNode {
            blank: false,
            node_kem_x: pn.node_kem_x,
            node_kem_pq: pn.node_kem_pq,
            unmerged_leaves: Vec::new(),
        });
    }
    Ok(())
}

/// Public keys of a resolution node (leaf or non-blank parent).
fn node_public_keys(tree: &RatchetTree, idx: usize) -> Result<([u8; KEM_X_LEN], [u8; MLKEM_EK_LEN])> {
    match tree.slots.get(idx) {
        Some(TreeSlot::Leaf(l)) => Ok((l.leaf_kem_x, l.leaf_kem_pq)),
        Some(TreeSlot::Parent(p)) if !p.blank => Ok((p.node_kem_x, p.node_kem_pq)),
        _ => Err(CoreError::Crypto("treekem: resolution node has no public key")),
    }
}

// ── UpdatePath build/apply (§4.4) ────────────────────────────────────────────────────────

/// A member's private tree state: its leaf secret plus the path secrets it knows for nodes
/// on its own direct path. This is the in-memory working set; persistence rides
/// [`PersistTree`], and the §6.2 deletion table governs lifetimes.
#[derive(Clone)]
pub struct TreePrivate {
    pub leaf_index: u32,
    /// `path_secret[0]` — replaced wholesale on every own path update.
    pub leaf_secret: [u8; 32],
    /// Node array index → path secret, for direct-path nodes this member knows.
    pub path_secrets: BTreeMap<u32, [u8; 32]>,
}

impl TreePrivate {
    pub fn new(leaf_index: u32, leaf_secret: [u8; 32]) -> Self {
        Self { leaf_index, leaf_secret, path_secrets: BTreeMap::new() }
    }

    /// This member's leaf keypair (derived from the leaf secret, §3.2).
    pub fn leaf_keypair(&self) -> NodeKeypair {
        node_keypair_from_path_secret(&self.leaf_secret)
    }
}

/// Deletion discipline (§6.2 "leaf_secret / path secrets … deleted on next own path update
/// (replaced), and always on Remove of self"). A leaf/path secret dies when the `TreePrivate`
/// holding it is REPLACED: a fresh own path update installs a new `TreePrivate` and the old one
/// drops here, zeroing the superseded leaf secret and every path secret; a removed-self device
/// sets its `TreePrivate` to `None`, which drops+wipes here. `wipe_secret` (volatile + fence)
/// makes the erase of the dead buffer real, not optimized away. Nothing downstream needs these:
/// the node keys they derived are replaced by the very update that supersedes them.
impl Drop for TreePrivate {
    fn drop(&mut self) {
        wipe_secret(&mut self.leaf_secret);
        for s in self.path_secrets.values_mut() {
            wipe_secret(s);
        }
    }
}

/// Everything a committer gets from building an UpdatePath.
pub struct UpdatePathBuild {
    pub update_path: UpdatePath,
    /// The committer's fresh path secrets (node array index → secret) — its next
    /// [`TreePrivate::path_secrets`] contents.
    pub path_secrets: BTreeMap<u32, [u8; 32]>,
    pub commit_secret: [u8; 32],
}

/// What a receiver learns from decrypting an UpdatePath.
pub struct PathDecryption {
    /// Fresh path secrets for the nodes shared with the committer (common ancestor up to
    /// the root) — merged into the receiver's [`TreePrivate::path_secrets`].
    pub path_secrets: BTreeMap<u32, [u8; 32]>,
    pub commit_secret: [u8; 32],
}

/// Build an UpdatePath (§3.2, §4.4): chain path secrets up from the fresh leaf secret,
/// derive each filtered-path node's keypair, and hybrid-KEM-wrap each node's path secret
/// to every node in the resolution of its copath child — the O(log n) rekey.
///
/// `tree` is the POST-proposal tree (adds/removes already applied): a removed leaf is
/// excluded from every resolution by construction, which is the §4.3 revocation guarantee.
/// Pure and deterministic: the leaf binding signature is produced by the caller-supplied
/// signer (the device identity lives with the caller), and all encapsulation randomness
/// expands from `entropy`.
#[allow(clippy::too_many_arguments)]
pub fn build_update_path(
    tree: &RatchetTree,
    group_id: &[u8],
    epoch: u64,
    sender_leaf: u32,
    leaf_secret: &[u8; 32],
    device_credential: &[u8],
    sign_leaf_binding: impl FnOnce(&[u8]) -> Vec<u8>,
    entropy: &[u8; 32],
) -> Result<UpdatePathBuild> {
    match tree.slots.get(leaf_slot(sender_leaf)) {
        Some(TreeSlot::Leaf(_)) => {}
        _ => return Err(CoreError::Encoding("treekem: committer leaf not in tree")),
    }
    let leaf_kp = node_keypair_from_path_secret(leaf_secret);
    let payload = leaf_binding_payload(group_id, &leaf_kp.kem_x, &leaf_kp.kem_pq);
    let leaf_node = LeafNode {
        leaf_kem_x: leaf_kp.kem_x,
        leaf_kem_pq: leaf_kp.kem_pq,
        device_credential: device_credential.to_vec(),
        leaf_binding_sig: sign_leaf_binding(&payload),
    };
    let mut ps = *leaf_secret;
    let mut nodes = Vec::new();
    let mut path_secrets = BTreeMap::new();
    for (d, cop) in filtered_path_with_copath(tree, sender_leaf)? {
        ps = derive_path_secret(&ps);
        path_secrets.insert(d as u32, ps);
        let kp = node_keypair_from_path_secret(&ps);
        let mut ciphertexts = Vec::new();
        for r in resolution(tree, cop)? {
            let (rx, rpq) = node_public_keys(tree, r)?;
            let seed = ct_seed(entropy, d as u32, r as u32);
            ciphertexts.push(seal_path_secret(&rx, &rpq, group_id, epoch, r as u32, &ps, &seed)?);
        }
        nodes.push(UpdatePathNode { node_kem_x: kp.kem_x, node_kem_pq: kp.kem_pq, ciphertexts });
    }
    let commit_secret = derive_commit_secret(&ps);
    Ok(UpdatePathBuild { update_path: UpdatePath { leaf_node, nodes }, path_secrets, commit_secret })
}

/// Decrypt an UpdatePath at this member's vantage (§4.4): find the lowest filtered-path
/// node covering our leaf (the common ancestor with the committer), decrypt its path
/// secret with whichever key we hold in that copath resolution (our leaf, or an interior
/// node we know), then derive upward — VERIFYING at every level that the derived public
/// keys match the UpdatePath's, so a malformed or malicious path cannot silently desync
/// the tree from the secrets.
///
/// `tree` is the POST-proposal, PRE-merge tree (same view the builder used). A removed
/// member fails here with no decryptable ciphertext — asserted by the §9 M1 proof test.
pub fn decrypt_update_path(
    tree: &RatchetTree,
    group_id: &[u8],
    epoch: u64,
    sender_leaf: u32,
    path: &UpdatePath,
    my: &TreePrivate,
) -> Result<PathDecryption> {
    if sender_leaf == my.leaf_index {
        return Err(CoreError::Crypto("treekem: committer must use its own build, not decrypt"));
    }
    let filtered = filtered_path_with_copath(tree, sender_leaf)?;
    if filtered.len() != path.nodes.len() {
        return Err(CoreError::Encoding("treekem: update path length mismatch"));
    }
    let n = tree.n_leaves();
    let my_slot = leaf_slot(my.leaf_index);
    let anchor = filtered
        .iter()
        .position(|(d, _)| subtree_contains(*d, my_slot, n))
        .ok_or(CoreError::Crypto("treekem: leaf not covered by this update path"))?;
    let mut got: Option<[u8; 32]> = None;
    for ct in &path.nodes[anchor].ciphertexts {
        let kp = if ct.resolution_index as usize == my_slot {
            Some(my.leaf_keypair())
        } else {
            my.path_secrets.get(&ct.resolution_index).map(node_keypair_from_path_secret)
        };
        if let Some(kp) = kp {
            // Addressed to a key we hold: failure here is corruption, not "try the next
            // one" — fail closed rather than mask a bad ciphertext.
            got = Some(open_path_secret(&kp, group_id, epoch, ct)?);
            break;
        }
    }
    let mut ps = got.ok_or(CoreError::Crypto("treekem: no decryptable path secret (removed?)"))?;
    let mut out = BTreeMap::new();
    for (i, (d, _)) in filtered.iter().enumerate().skip(anchor) {
        if i > anchor {
            ps = derive_path_secret(&ps);
        }
        let kp = node_keypair_from_path_secret(&ps);
        let pn = &path.nodes[i];
        if kp.kem_x != pn.node_kem_x || kp.kem_pq[..] != pn.node_kem_pq[..] {
            return Err(CoreError::Crypto("treekem: update path node key inconsistent with derived secret"));
        }
        out.insert(*d as u32, ps);
    }
    let commit_secret = derive_commit_secret(&ps);
    Ok(PathDecryption { path_secrets: out, commit_secret })
}

// ── Epoch key schedule (§3.3) ────────────────────────────────────────────────────────────

/// The derived secrets of one epoch. Deliberately absent (§6.2's table, §6.3-1): the
/// consumed `commit_secret` and the PREVIOUS epoch's `init_secret` have no field here and
/// are wiped by [`advance_epoch`] itself — from this struct, epoch n−1 is not derivable.
/// `init_secret` feeds epoch n+1 and is consumed (and wiped) by the next advance;
/// `joiner_secret` exists only for Welcome issuance and is retained by the committer only
/// while a Welcome is un-acked (bounded by the mailbox TTL, §6.3-3).
#[derive(Clone)]
pub struct EpochSchedule {
    pub epoch_secret: [u8; 32],
    pub init_secret: [u8; 32],
    pub sender_root: [u8; 32],
    pub confirm_key: [u8; 32],
    pub welcome_key: [u8; 32],
    pub joiner_secret: [u8; 32],
}

/// Deletion discipline (§6.2 / §6.3): every epoch secret this struct carries is zeroed when the
/// struct drops — i.e. when the epoch is SUPERSEDED (a newer schedule replaces it), a LOSING fork's
/// schedule is discarded (§6.3-2), or a transient copy made only to issue a Welcome goes out of
/// scope. Consumers copy the specific 32-byte values they retain (`sender_root`/`init_secret`/
/// `joiner_secret` into a live `KeyingState`, a `sender_key` into the content-key store) BEFORE the
/// schedule drops; those copies live on independently and are governed by their own deletion points.
/// The two consumed INPUTS (`commit_secret`, `init_secret_{n-1}`) were already wiped at the moment of
/// consumption inside [`advance_epoch`]; this Drop closes the schedule's own six fields so a
/// superseded epoch leaves no derivable material behind (the §6.3-1 "no fossilized secret" property
/// for the in-memory copy, complementing the `PersistState`-has-no-field property for the blob).
impl Drop for EpochSchedule {
    fn drop(&mut self) {
        wipe_secret(&mut self.epoch_secret);
        wipe_secret(&mut self.init_secret);
        wipe_secret(&mut self.sender_root);
        wipe_secret(&mut self.confirm_key);
        wipe_secret(&mut self.welcome_key);
        wipe_secret(&mut self.joiner_secret);
    }
}

/// `epoch_context_n = blake3("haven-mls-ctx-v1" ‖ group_id ‖ n ‖ tree_hash_n ‖
/// confirmed_transcript_hash_n)` (§3.3).
pub fn epoch_context(
    group_id: &[u8],
    epoch: u64,
    tree_hash: &[u8; 32],
    confirmed_transcript_hash: &[u8; 32],
) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(EPOCH_CTX_DOMAIN);
    h.update(group_id);
    h.update(&epoch.to_le_bytes());
    h.update(tree_hash);
    h.update(confirmed_transcript_hash);
    *h.finalize().as_bytes()
}

/// Derive every epoch-n secret from a joiner secret + epoch context (§3.3). This is the
/// entry point a Welcome recipient uses (a Welcome delivers `joiner_secret`); members that
/// processed the commit go through [`advance_epoch`], which lands here after the one-way
/// step.
pub fn epoch_from_joiner(joiner_secret: &[u8; 32], epoch_context: &[u8; 32]) -> EpochSchedule {
    let epoch_secret = hkdf32(EPOCH_SALT, joiner_secret, epoch_context);
    EpochSchedule {
        init_secret: hkdf_expand32(&epoch_secret, b"init"),
        sender_root: hkdf_expand32(&epoch_secret, b"senders"),
        confirm_key: hkdf_expand32(&epoch_secret, b"confirm"),
        welcome_key: hkdf_expand32(joiner_secret, b"welcome"),
        joiner_secret: *joiner_secret,
        epoch_secret,
    }
}

/// Advance the schedule one epoch: `joiner_secret_n = HKDF(salt=init_secret_{n-1},
/// ikm=commit_secret_n, info="joiner" ‖ epoch_context_n)` (§3.3), then derive everything
/// from it.
///
/// BOTH inputs are wiped in place before this returns — they are consumed by the one-way
/// link and must not outlive it (§6.2: `commit_secret` dies immediately; `init_secret_{n-1}`
/// dies when epoch n confirms). The wipe living inside the schedule, not in every caller,
/// is what makes the deletion discipline enforceable; the one-way proof test asserts it.
pub fn advance_epoch(
    init_secret_prev: &mut [u8; 32],
    commit_secret: &mut [u8; 32],
    epoch_context: &[u8; 32],
) -> EpochSchedule {
    let mut info = Vec::with_capacity(6 + 32);
    info.extend_from_slice(b"joiner");
    info.extend_from_slice(epoch_context);
    let joiner = hkdf32(init_secret_prev, commit_secret, &info);
    wipe_secret(init_secret_prev);
    wipe_secret(commit_secret);
    epoch_from_joiner(&joiner, epoch_context)
}

/// `sender_key_n[leaf] = HKDF(salt=leaf_id, ikm=sender_root_n, info="haven-mls-sender-v1"
/// ‖ group_id ‖ n)` (§3.3) — a 32-byte epoch key in exactly today's `groupkey.rs` sense.
pub fn sender_key(sender_root: &[u8; 32], leaf_id: &[u8; 32], group_id: &[u8], epoch: u64) -> [u8; 32] {
    let mut info = Vec::with_capacity(SENDER_KEY_DOMAIN.len() + group_id.len() + 8);
    info.extend_from_slice(SENDER_KEY_DOMAIN);
    info.extend_from_slice(group_id);
    info.extend_from_slice(&epoch.to_le_bytes());
    hkdf32(leaf_id, sender_root, &info)
}

// ── M6: per-message sender ratchet for the DM / live lane (§6.5) ──────────────────────────
//
// A classic MLS-style symmetric sender ratchet layered ON TOP of a leaf's per-epoch
// `sender_key_n` (above): each DM gets its own message key, so capturing message i's key
// does NOT open message i-1 (per-message forward secrecy). The construction is deliberately
// the Signal double-ratchet's *symmetric chain* half:
//
//     CK_0     = HKDF(salt=RATCHET_SALT, ikm=sender_key_n[leaf], info="chain-init" ‖ gid ‖ n)
//     MK_i     = HKDF-expand(CK_i, "msg")     # the message key that seals DM i
//     CK_{i+1} = HKDF-expand(CK_i, "chain")   # advance; CK_i is WIPED the instant CK_{i+1} exists
//
// Two one-way HKDF-expands off the same chain key, separated by info label, give the FS
// property for free: `MK_i` reveals nothing about `CK_i` (different label), and `CK_{i+1}`
// cannot be run back to `CK_i` (HKDF is one-way). So a receiver's post-message-i state —
// `CK_{i+1}` plus whatever it still caches — cannot reconstruct `MK_{i-1}` unless that key is
// still sitting in the skipped cache (which is itself FS-managed, below).
//
// DOMAIN SEPARATION: `RATCHET_SALT` is distinct from the epoch schedule's `EPOCH_SALT` /
// `TREEKEM_SALT` and from the content KDF (`groupkey.rs` "haven-event-key-v1"), and the two
// per-chain-key labels are distinct from those and from each other. A ratchet key can never
// collide with an epoch key, a node key, or a content-event key.
//
// The HARD part is Haven's transport (design §6.5 + the task's mailbox contract): DMs arrive
// DAYS LATE and OUT OF ORDER over content-addressed mailboxes. A naive delete-on-use ratchet
// would lose the ability to open a message that jumped the queue. The receiver therefore keeps
// a BOUNDED skipped-key cache ([`RatchetReceiver`]) — the Signal skipped-key mechanism, capped
// so an adversarial index cannot blow memory or CPU.

/// HKDF salt for the M6 per-message ratchet (§6.5). Domain-separated from `EPOCH_SALT` /
/// `TREEKEM_SALT` / the content KDF — see the module note above.
pub const RATCHET_SALT: &[u8] = b"haven-mls-ratchet-v1";

/// The max-JUMP cap: the largest forward gap (`claimed_index - next_expected`) a single received
/// message may advance the chain. THE bound that makes an adversarial index safe: a message
/// claiming index `next + 2^32` is rejected BEFORE a single HKDF runs or a single byte is
/// allocated, so per-message work is capped at `RATCHET_MAX_JUMP` HKDF-expands regardless of what
/// the envelope claims. Chosen well above any plausible in-flight burst on one epoch's DM chain
/// (weekly epoch rotation re-roots the chain, §6.5) yet small enough that the worst case is a few
/// thousand cheap HKDFs.
pub const RATCHET_MAX_JUMP: u32 = 2048;

/// The cache-SIZE cap: the most skipped message keys a receiver retains per chain. THE memory
/// bound (~`RATCHET_MAX_SKIPPED * 36` bytes/chain). When a new skip would exceed it the
/// lowest-index (oldest) key is evicted AND WIPED (FS on eviction). This also fixes the
/// **late-message horizon**: a message with index `i < next` opens only while `MK_i` is still
/// cached; once evicted it fails to open *gracefully* (`message_key` returns `None`, no panic) and
/// the caller falls back to the epoch-keyed re-seal backstop (§6.1). The horizon is therefore "the
/// most recent `RATCHET_MAX_SKIPPED` skipped indices," documented so no one mistakes an
/// out-of-horizon miss for a bug.
pub const RATCHET_MAX_SKIPPED: usize = 2048;

/// `CK_0 = HKDF(salt=RATCHET_SALT, ikm=sender_key, info="chain-init" ‖ group_id ‖ epoch)`.
/// Both sides derive it from the SAME per-leaf epoch `sender_key` (§3.3) + group + epoch, so the
/// sender's chain and every receiver's replica agree; a new epoch's `sender_key` re-roots a fresh
/// chain (the design's "epoch rotation resets the chain").
pub fn ratchet_chain_init(sender_key: &[u8; 32], group_id: &[u8], epoch: u64) -> [u8; 32] {
    let mut info = Vec::with_capacity(11 + group_id.len() + 8);
    info.extend_from_slice(b"chain-init");
    info.extend_from_slice(group_id);
    info.extend_from_slice(&epoch.to_le_bytes());
    hkdf32(RATCHET_SALT, sender_key, &info)
}

/// `MK_i = HKDF-expand(CK_i, "msg")` — the per-message key. One-way off `CK_i`.
fn ratchet_message_key(ck: &[u8; 32]) -> [u8; 32] {
    hkdf_expand32(ck, b"msg")
}

/// `CK_{i+1} = HKDF-expand(CK_i, "chain")` — advance the chain. One-way off `CK_i`.
fn ratchet_next_chain(ck: &[u8; 32]) -> [u8; 32] {
    hkdf_expand32(ck, b"chain")
}

/// The SENDER side of the ratchet: hands out `(index, MK)` in order and advances. The consumed
/// chain key is wiped the instant the next one exists — FS deletion point #1 (nothing on the
/// sender ever holds a key that sealed an already-sent message).
pub struct SenderChain {
    ck: [u8; 32],
    /// Index of the NEXT message key this chain will produce.
    next: u32,
}

impl SenderChain {
    pub fn new(sender_key: &[u8; 32], group_id: &[u8], epoch: u64) -> Self {
        SenderChain { ck: ratchet_chain_init(sender_key, group_id, epoch), next: 0 }
    }

    /// The current in-order index (the index the next [`Self::next_key`] will stamp).
    pub fn index(&self) -> u32 {
        self.next
    }

    /// Produce `(i, MK_i)` and advance to `i+1`, WIPING `CK_i`. The caller seals under `MK_i`,
    /// stamps `i` on the envelope, then wipes its own copy of `MK_i` after sealing.
    pub fn next_key(&mut self) -> (u32, [u8; 32]) {
        let i = self.next;
        let mk = ratchet_message_key(&self.ck);
        let nck = ratchet_next_chain(&self.ck);
        wipe_secret(&mut self.ck);
        self.ck = nck;
        // u32 space is astronomically larger than one epoch's DM count (the epoch re-roots weekly,
        // §6.5); a saturating step avoids any wrap even in a pathological run.
        self.next = i.saturating_add(1);
        (i, mk)
    }
}

impl Drop for SenderChain {
    fn drop(&mut self) {
        wipe_secret(&mut self.ck);
    }
}

/// The RECEIVER side: derives message keys on demand, tolerating OUT-OF-ORDER and DAYS-LATE
/// delivery via a BOUNDED skipped-key cache (§6.5). Its two caps ([`RATCHET_MAX_JUMP`],
/// [`RATCHET_MAX_SKIPPED`]) are what keep an adversarial envelope from turning "open a late DM"
/// into an unbounded-memory / unbounded-CPU DoS.
pub struct RatchetReceiver {
    /// The chain key at position `next` (i.e. `CK_next`).
    ck: [u8; 32],
    /// The next in-order index we would derive.
    next: u32,
    /// Message keys for indices we jumped OVER (received out of order), awaiting their late
    /// message. `BTreeMap` so eviction of the lowest (oldest) index is O(log n) and deterministic.
    /// Every value is a live secret: wiped on eviction, on use (delete-on-use), and on drop.
    skipped: std::collections::BTreeMap<u32, [u8; 32]>,
}

impl RatchetReceiver {
    pub fn new(sender_key: &[u8; 32], group_id: &[u8], epoch: u64) -> Self {
        RatchetReceiver {
            ck: ratchet_chain_init(sender_key, group_id, epoch),
            next: 0,
            skipped: std::collections::BTreeMap::new(),
        }
    }

    /// Number of cached skipped keys (for the bound tests).
    pub fn skipped_len(&self) -> usize {
        self.skipped.len()
    }

    /// Return `MK_i` for message index `i`, or `None` if it cannot be produced within the bounds.
    ///
    /// * `i < next` — a LATE / out-of-order message: served from the skipped cache and removed
    ///   (delete-on-use FS). `None` if it was already consumed in order, or evicted below the
    ///   horizon — the graceful late-message miss (caller falls back to the epoch-keyed backstop).
    /// * `i == next` — the in-order case: derive, advance, WIPE the consumed chain key. Not cached
    ///   (delete-on-use).
    /// * `i > next` — a forward JUMP: **rejected before any work** if `i - next > RATCHET_MAX_JUMP`
    ///   (the CPU/memory bound; an index of `2^32-1` costs one comparison, not billions of HKDFs).
    ///   Otherwise derive+cache `MK_next..MK_{i-1}` (the skipped keys, honoring the size cap by
    ///   evicting+wiping the oldest) and return the consumed `MK_i`.
    pub fn message_key(&mut self, i: u32) -> Option<[u8; 32]> {
        if i < self.next {
            // Late arrival: only openable while still within the cache horizon. `remove` moves the
            // key out of the map (no lingering map copy) — delete-on-use. Caller wipes after use.
            return self.skipped.remove(&i);
        }
        // i >= next. Reject an out-of-bounds jump BEFORE deriving/allocating anything — this single
        // check is why an adversarial `i` cannot force unbounded derivation or memory (§6.5, §10's
        // "every cache has a named cap" discipline). `i - self.next` cannot underflow (i >= next).
        if i - self.next > RATCHET_MAX_JUMP {
            return None;
        }
        // Walk forward to `i`, caching each jumped-over key. The loop runs at most RATCHET_MAX_JUMP
        // times (bounded above), and `insert_skipped` keeps the cache at most RATCHET_MAX_SKIPPED.
        while self.next < i {
            let mk = ratchet_message_key(&self.ck);
            let at = self.next;
            self.advance();
            self.insert_skipped(at, mk);
        }
        // now self.next == i: the in-order, delete-on-use case.
        let mk = ratchet_message_key(&self.ck);
        self.advance();
        Some(mk)
    }

    /// Advance `CK_next → CK_{next+1}`, wiping the consumed chain key (FS deletion point).
    fn advance(&mut self) {
        let nck = ratchet_next_chain(&self.ck);
        wipe_secret(&mut self.ck);
        self.ck = nck;
        self.next = self.next.saturating_add(1);
    }

    /// Cache a skipped key, enforcing [`RATCHET_MAX_SKIPPED`] by evicting AND WIPING the
    /// lowest-index (oldest) entry first. The eviction wipe is the FS deletion point for a key
    /// that aged past the horizon before its message arrived.
    fn insert_skipped(&mut self, idx: u32, mk: [u8; 32]) {
        while self.skipped.len() >= RATCHET_MAX_SKIPPED {
            // BTreeMap keeps keys ordered → the first is the oldest index. `pop_first` moves it out
            // so we can wipe it (dropping a `[u8;32]` does not zero it).
            match self.skipped.pop_first() {
                Some((_, mut old)) => wipe_secret(&mut old),
                None => break,
            }
        }
        self.skipped.insert(idx, mk);
    }
}

impl Drop for RatchetReceiver {
    fn drop(&mut self) {
        wipe_secret(&mut self.ck);
        for (_, v) in self.skipped.iter_mut() {
            wipe_secret(v);
        }
    }
}

/// The commit's confirmation MAC: `blake3-keyed(confirm_key_n, confirmed_transcript_hash_n)`.
/// Agreeing on this value proves agreement on the entire epoch derivation — tree hash,
/// transcript, and schedule — which is exactly the §1.2 "group agreement" property.
pub fn confirmation_mac(confirm_key: &[u8; 32], confirmed_transcript_hash: &[u8; 32]) -> [u8; 32] {
    *blake3::keyed_hash(confirm_key, confirmed_transcript_hash).as_bytes()
}

/// Constant-time equality for MAC/hash comparison: fixed-work, no early exit, so comparison time
/// does not depend on how many bytes match.
#[inline]
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

// ── Fork tie-break + chain rule (§5.1) ───────────────────────────────────────────────────

/// blake3 of a commit's FULL signed bytes — the §5.1 ordering key and the
/// `parent_commit_hash` chain link.
pub fn commit_hash(commit_bytes: &[u8]) -> [u8; 32] {
    *blake3::hash(commit_bytes).as_bytes()
}

/// Hash of a commit's CONTENT — the signed bytes with the confirmation MAC and signature
/// blanked. The transcript hash must cover the commit without covering the MAC (the MAC is
/// keyed over the transcript hash — including it would be circular), and the M0 codec's
/// byte-stability makes the blanked re-serialization canonical.
pub fn commit_content_hash(commit: &Commit) -> [u8; 32] {
    let mut c = commit.clone();
    c.confirmation_mac = Vec::new();
    c.sig = Vec::new();
    let mut h = blake3::Hasher::new();
    h.update(COMMIT_CONTENT_DOMAIN);
    h.update(&c.to_bytes());
    *h.finalize().as_bytes()
}

/// `confirmed_transcript_hash_n = blake3(domain ‖ cth_{n-1} ‖ commit_content_hash_n)` —
/// the running hash all members provably agree on (via the confirmation MAC).
pub fn next_confirmed_transcript_hash(prev: &[u8; 32], commit: &Commit) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(TRANSCRIPT_DOMAIN);
    h.update(prev);
    h.update(&commit_content_hash(commit));
    *h.finalize().as_bytes()
}

/// §5.1 fork tie-break: order two same-parent commits by the blake3 hash of their full
/// signed bytes; `Greater` wins. Total and deterministic — distinct bytes give distinct
/// hashes, and every device holding both commits computes the same winner with no
/// communication (the shipped converge-on-larger-key shape, promoted to transitions).
pub fn compare_commits(a_bytes: &[u8], b_bytes: &[u8]) -> Ordering {
    commit_hash(a_bytes).cmp(&commit_hash(b_bytes))
}

/// Validate a candidate chain: every commit parses, carries the expected group id, epochs
/// increment by exactly one, and each commit's `parent_commit_hash` is the blake3 of its
/// predecessor's full bytes (the first links to `parent_hash`). Signature and proposal
/// authorization are M2's job (they need the roster); this is the pure hash-chain rule.
pub fn validate_chain(
    parent_hash: &[u8; 32],
    first_epoch: u64,
    group_id: &[u8],
    chain: &[Vec<u8>],
) -> Result<()> {
    let mut expect_parent = *parent_hash;
    let mut expect_epoch = first_epoch;
    for bytes in chain {
        let c = Commit::from_bytes(bytes)?;
        if c.group_id != group_id {
            return Err(CoreError::Encoding("treekem: chain commit for wrong group"));
        }
        if c.epoch != expect_epoch {
            return Err(CoreError::Encoding("treekem: chain epoch not contiguous"));
        }
        if c.parent_commit_hash != expect_parent {
            return Err(CoreError::Encoding("treekem: chain parent hash mismatch"));
        }
        expect_parent = commit_hash(bytes);
        expect_epoch += 1;
    }
    Ok(())
}

/// §5.1 chain selection: among candidate chains extending the same parent, the longest
/// VALID chain wins; equal lengths are broken by the larger tip commit hash. Returns the
/// winning candidate's index, or `None` if no candidate is valid and non-empty. Invalid
/// candidates are skipped, never fatal — a hostile chain must not be able to veto
/// selection. Monotone in information: seeing more candidates can only move every replica
/// toward the same winner, which is the §5 convergence argument.
pub fn select_chain(
    parent_hash: &[u8; 32],
    first_epoch: u64,
    group_id: &[u8],
    candidates: &[Vec<Vec<u8>>],
) -> Option<usize> {
    let mut best: Option<(usize, usize, [u8; 32])> = None; // (index, len, tip hash)
    for (i, chain) in candidates.iter().enumerate() {
        if chain.is_empty() || validate_chain(parent_hash, first_epoch, group_id, chain).is_err() {
            continue;
        }
        let tip = commit_hash(chain.last().expect("non-empty"));
        let better = match &best {
            None => true,
            Some((_, blen, btip)) => match chain.len().cmp(blen) {
                Ordering::Greater => true,
                Ordering::Less => false,
                Ordering::Equal => tip > *btip,
            },
        };
        if better {
            best = Some((i, chain.len(), tip));
        }
    }
    best.map(|(i, _, _)| i)
}

// ═════════════════════════════════════════════════════════════════════════════════════════
// Stage M2 — propose / commit / welcome / apply-commit BUILDERS (design §4, §9 row M2).
//
// These bundle the M1 primitives (tree ops + `build_update_path`/`decrypt_update_path` +
// the epoch schedule + the fork rules) into the four operations the engine drives. They stay
// PURE exactly like M1: entropy and time are caller-supplied, signing is a caller closure
// (the device/account keys live with the caller), no I/O, no engine state. Same inputs →
// same bytes, so two devices that apply the same commit chain land on bit-identical trees and
// epoch secrets — the property the M2 SHADOW mode compares, and the only thing that makes
// convergence without a delivery service (§5) possible.
//
// SHADOW invariant (M2): the epoch secrets these produce are COMPARED via telemetry, never
// consumed for content keys (that flip is M3). Nothing here decides that — a builder is a
// builder — but the engine wiring that calls them is gated and its outputs are inert.
// ═════════════════════════════════════════════════════════════════════════════════════════

// ── Proposal builders (§4.2 Add, §4.3 Remove, §4.4 Update) ───────────────────────────────

/// The exact bytes a [`Proposal`] signature covers: `PROPOSAL_DOMAIN ‖ proposal-with-blank-sig`.
/// Exposed so the verifier (lib.rs, which holds the roster to resolve the signer) checks the
/// identical preimage the builder signed. Blanking the sig field before serializing keeps the
/// preimage a pure function of the proposal's content (the M0 codec's byte-stability makes the
/// blanked re-serialization canonical).
pub fn proposal_signing_bytes(p: &Proposal) -> Vec<u8> {
    let mut c = p.clone();
    c.sig = Vec::new();
    let mut v = Vec::with_capacity(PROPOSAL_DOMAIN.len());
    v.extend_from_slice(PROPOSAL_DOMAIN);
    v.extend_from_slice(&c.to_bytes());
    v
}

/// Build a signed proposal for one membership op. The signer closure is the proposing device's
/// hybrid signature (roster authorization of the signer is the caller's job, §4.2). Deterministic.
pub fn build_proposal(
    group_id: &[u8],
    epoch: u64,
    sender_leaf: u32,
    body: ProposalBody,
    sign: impl FnOnce(&[u8]) -> Vec<u8>,
) -> Proposal {
    let mut p = Proposal { group_id: group_id.to_vec(), epoch, body, sender_leaf, sig: Vec::new() };
    p.sig = sign(&proposal_signing_bytes(&p));
    p
}

/// Convenience: an Add proposal carrying the joiner's [`LeafNode`] (§4.2).
pub fn build_add_proposal(
    group_id: &[u8],
    epoch: u64,
    sender_leaf: u32,
    leaf_node: LeafNode,
    sign: impl FnOnce(&[u8]) -> Vec<u8>,
) -> Proposal {
    build_proposal(group_id, epoch, sender_leaf, ProposalBody::Add { leaf_node }, sign)
}

/// Convenience: a Remove proposal naming the leaf to cut off (§4.3).
pub fn build_remove_proposal(
    group_id: &[u8],
    epoch: u64,
    sender_leaf: u32,
    leaf_index: u32,
    sign: impl FnOnce(&[u8]) -> Vec<u8>,
) -> Proposal {
    build_proposal(group_id, epoch, sender_leaf, ProposalBody::Remove { leaf_index }, sign)
}

// ── Applying proposals to the public tree (shared by builder + receiver) ──────────────────

/// Apply a commit's proposals to the public tree in listed order — the ONE code path both the
/// committer (before building its path) and every receiver run, so their trees are identical by
/// construction. `Update` replaces the named leaf's node in place (a member refreshing its own
/// leaf key without a full path is the degenerate case); `Add`/`Remove` are the M1 tree ops.
/// Returns whether `my_leaf` (if given) was removed by one of the proposals.
fn apply_proposals(tree: &mut RatchetTree, proposals: &[Proposal], my_leaf: Option<u32>) -> Result<bool> {
    let mut removed_me = false;
    for p in proposals {
        match &p.body {
            ProposalBody::Add { leaf_node } => {
                add_leaf(tree, leaf_node.clone())?;
            }
            ProposalBody::Remove { leaf_index } => {
                remove_leaf(tree, *leaf_index)?;
                if my_leaf == Some(*leaf_index) {
                    removed_me = true;
                }
            }
            ProposalBody::Update { leaf_node } => {
                // A bare Update proposal (no path) refreshes the proposer's leaf public key only;
                // its path nodes are blanked so a later commit re-keys them. In M2 the committer's
                // own refresh rides its UpdatePath instead; foreign Update proposals are the rare
                // case and handled here for completeness.
                let slot = leaf_slot(p.sender_leaf);
                match tree.slots.get(slot) {
                    Some(TreeSlot::Leaf(_)) => {}
                    _ => return Err(CoreError::Encoding("treekem: update proposal for unpopulated leaf")),
                }
                tree.slots[slot] = TreeSlot::Leaf(leaf_node.clone());
                let n = tree.n_leaves();
                for d in direct_path(slot, n)? {
                    tree.slots[d] = TreeSlot::Blank;
                }
            }
        }
    }
    Ok(removed_me)
}

// ── Commit builder (§4.1/§4.2/§4.3 + the epoch advance) ───────────────────────────────────

/// The exact bytes a [`Commit`] signature covers: `COMMIT_DOMAIN ‖ commit-with-blank-sig` (the
/// confirmation MAC is already set and IS covered — it binds the epoch derivation into the
/// signature; only the signature field itself is blanked). Exposed for the lib.rs verifier.
pub fn commit_signing_bytes(commit: &Commit) -> Vec<u8> {
    let mut c = commit.clone();
    c.sig = Vec::new();
    let mut v = Vec::with_capacity(COMMIT_DOMAIN.len());
    v.extend_from_slice(COMMIT_DOMAIN);
    v.extend_from_slice(&c.to_bytes());
    v
}

/// Everything a committer gets from [`build_commit`]: the signed commit to publish, the
/// post-commit public tree, the running transcript hash, the new epoch schedule (whose
/// `joiner_secret` seeds every Welcome), and the committer's updated private state.
pub struct CommitBuild {
    pub commit: Commit,
    /// The public tree AFTER proposals + (optional) path merge — its hash is `commit.tree_hash`.
    pub tree: RatchetTree,
    /// `confirmed_transcript_hash_n` — the value receivers must reproduce and the MAC is keyed over.
    pub confirmed_transcript_hash: [u8; 32],
    pub schedule: EpochSchedule,
    /// The committer's private state at epoch n (leaf secret + path secrets).
    pub my_private: TreePrivate,
}

/// Build a commit (§4): apply `proposals` to the tree, optionally re-key the committer's direct
/// path (`new_leaf_secret`/`entropy` given → an UpdatePath; `None` → an add-only commit whose
/// `commit_secret` is the all-zero vector, RFC 9420 §12.4), advance the epoch schedule, key the
/// confirmation MAC, and sign. Pure: `sign_leaf_binding`/`sign_commit` are the committer's
/// device signature, all randomness expands from `entropy`.
///
/// `prev_init_secret` is COPIED and consumed by the advance (the original stays with the caller
/// until epoch n confirms; §6.2). For a genesis (§4.1) pass an empty `prev_tree`, all Adds, and
/// `path = None`: the tree is built up from the proposals and `prev_init_secret` is the group's
/// deterministic genesis init.
#[allow(clippy::too_many_arguments)]
pub fn build_commit(
    prev_tree: &RatchetTree,
    group_id: &[u8],
    epoch: u64,
    parent_commit_hash: [u8; 32],
    prev_cth: &[u8; 32],
    prev_init_secret: &[u8; 32],
    committer_leaf: u32,
    proposals: Vec<Proposal>,
    path: Option<(&[u8; 32], &[u8], &[u8; 32])>, // (new_leaf_secret, device_credential, entropy)
    sign_leaf_binding: impl FnOnce(&[u8]) -> Vec<u8>,
    sign_commit: impl FnOnce(&[u8]) -> Vec<u8>,
) -> Result<CommitBuild> {
    let mut tree = prev_tree.clone();
    apply_proposals(&mut tree, &proposals, Some(committer_leaf))?;
    let (update_path, path_secrets, mut commit_secret, new_leaf_secret) = match path {
        Some((leaf_secret, cred, entropy)) => {
            let b = build_update_path(
                &tree, group_id, epoch, committer_leaf, leaf_secret, cred, sign_leaf_binding, entropy,
            )?;
            merge_update_path(&mut tree, committer_leaf, &b.update_path)?;
            (Some(b.update_path), b.path_secrets, b.commit_secret, Some(*leaf_secret))
        }
        // Add-only / no-path commit: commit_secret is the all-zero vector.
        None => (None, BTreeMap::new(), [0u8; 32], None),
    };
    let th = tree_hash(&tree);
    // Assemble with blank MAC + sig so the transcript covers commit CONTENT (mac/sig blanked),
    // which is exactly what receivers reproduce — computing the MAC before it is set is not
    // circular (the transcript hash never covers the MAC keyed over it).
    let mut commit = Commit {
        group_id: group_id.to_vec(),
        epoch,
        parent_commit_hash,
        proposals,
        update_path,
        tree_hash: th,
        confirmation_mac: Vec::new(),
        sender_leaf: committer_leaf,
        sig: Vec::new(),
    };
    let cth = next_confirmed_transcript_hash(prev_cth, &commit);
    let ctx = epoch_context(group_id, epoch, &th, &cth);
    let mut init = *prev_init_secret;
    let schedule = advance_epoch(&mut init, &mut commit_secret, &ctx);
    commit.confirmation_mac = confirmation_mac(&schedule.confirm_key, &cth).to_vec();
    commit.sig = sign_commit(&commit_signing_bytes(&commit));
    let mut my_private = TreePrivate::new(committer_leaf, new_leaf_secret.unwrap_or([0u8; 32]));
    my_private.path_secrets = path_secrets;
    Ok(CommitBuild { commit, tree, confirmed_transcript_hash: cth, schedule, my_private })
}

// ── Commit application (§4, the receiver side) ────────────────────────────────────────────

/// What a receiver learns from [`apply_commit`]: the new public tree + transcript, and — if the
/// receiver is an active member that could derive the epoch — the schedule and its updated
/// private state. `schedule`/`my_private` are `None` for a non-member (or a receiver removed by
/// this very commit), which still tracks the public facts (tree, transcript) for later.
pub struct AppliedCommit {
    pub tree: RatchetTree,
    pub confirmed_transcript_hash: [u8; 32],
    pub schedule: Option<EpochSchedule>,
    pub my_private: Option<TreePrivate>,
    pub removed_me: bool,
}

/// Apply a received commit (§4/§5.2 step 1): apply its proposals, decrypt+merge its UpdatePath
/// (if any and I am a member), verify the tree hash it claims, advance the schedule, and VERIFY
/// the confirmation MAC — a mismatch anywhere fails closed rather than desyncing the shadow tree
/// from its secrets. `prev_init_secret` is copied and consumed by the advance.
///
/// The committer must not apply its own commit here (it holds the [`CommitBuild`] result); this
/// errors if `commit.sender_leaf == my_private.leaf_index`. Signature + proposal authorization
/// are the caller's (they need the roster); this is the pure tree/schedule application.
pub fn apply_commit(
    prev_tree: &RatchetTree,
    group_id: &[u8],
    prev_cth: &[u8; 32],
    prev_init_secret: &[u8; 32],
    commit: &Commit,
    my_private: Option<&TreePrivate>,
) -> Result<AppliedCommit> {
    if commit.group_id != group_id {
        return Err(CoreError::Encoding("treekem: commit for wrong group"));
    }
    let my_leaf = my_private.map(|m| m.leaf_index);
    if let (Some(mi), true) = (my_leaf, my_private.is_some()) {
        if commit.sender_leaf == mi {
            return Err(CoreError::Crypto("treekem: committer must use its own build, not apply_commit"));
        }
    }
    // Decrypt the path BEFORE the proposals mutate the tree only when needed; but the path was
    // built over the POST-proposal tree (§4.4), so proposals apply first, then decrypt/merge.
    let mut tree = prev_tree.clone();
    let removed_me = apply_proposals(&mut tree, &commit.proposals, my_leaf)?;
    let mut my_out = my_private.cloned();
    let mut commit_secret = [0u8; 32];
    if let Some(path) = &commit.update_path {
        // A member still present decrypts to learn the fresh path secrets + commit secret.
        if let (Some(mp), false) = (&my_out, removed_me) {
            let d = decrypt_update_path(&tree, group_id, commit.epoch, commit.sender_leaf, path, mp)?;
            commit_secret = d.commit_secret;
            // Deletion discipline (§6.2 "path secrets … replaced"): a proposal that blanks a node
            // retires this member's path secret for it. WIPE each retired secret IN PLACE before
            // dropping the map entry — a `retain` that merely drops would leave the secret in the
            // freed BTreeMap node; wiping first zeroes the buffer while we still hold it. Nothing
            // downstream needs these: the node is blank, and the fresh UpdatePath supplies the
            // replacement secrets we `extend` in immediately after.
            let t = &tree;
            if let Some(mp) = &mut my_out {
                let stale: Vec<u32> = mp
                    .path_secrets
                    .keys()
                    .copied()
                    .filter(|ix| !matches!(t.slots.get(*ix as usize), Some(TreeSlot::Parent(pn)) if !pn.blank))
                    .collect();
                for ix in stale {
                    if let Some(s) = mp.path_secrets.get_mut(&ix) {
                        wipe_secret(s);
                    }
                    mp.path_secrets.remove(&ix);
                }
                mp.path_secrets.extend(d.path_secrets);
            }
        }
        merge_update_path(&mut tree, commit.sender_leaf, path)?;
    }
    let th = tree_hash(&tree);
    if th != commit.tree_hash {
        return Err(CoreError::Crypto("treekem: applied tree hash disagrees with the commit"));
    }
    let cth = next_confirmed_transcript_hash(prev_cth, commit);
    let mut schedule = None;
    if my_out.is_some() && !removed_me {
        let ctx = epoch_context(group_id, commit.epoch, &th, &cth);
        let mut init = *prev_init_secret;
        let s = advance_epoch(&mut init, &mut commit_secret, &ctx);
        if !ct_eq(&confirmation_mac(&s.confirm_key, &cth), &commit.confirmation_mac) {
            return Err(CoreError::Crypto("treekem: confirmation MAC did not verify"));
        }
        schedule = Some(s);
    }
    if removed_me {
        my_out = None;
    }
    Ok(AppliedCommit { tree, confirmed_transcript_hash: cth, schedule, my_private: my_out, removed_me })
}

// ── Welcome (§4.2, the joiner rail) ───────────────────────────────────────────────────────

/// The epoch schedule a Welcome recipient derives (§4.2/§3.3): a joiner holds no `init_{n-1}`,
/// so it bootstraps the schedule straight from the `joiner_secret` the Welcome delivered plus
/// the public epoch context (group id, epoch, tree hash, confirmed transcript hash — all
/// verifiable against the commit + `GroupInfo`). This is [`epoch_from_joiner`] with the context
/// assembled; a member and a joiner that reach the same epoch derive the identical `epoch_secret`.
pub fn welcome_epoch_schedule(
    joiner_secret: &[u8; 32],
    group_id: &[u8],
    epoch: u64,
    tree_hash: &[u8; 32],
    confirmed_transcript_hash: &[u8; 32],
) -> EpochSchedule {
    let ctx = epoch_context(group_id, epoch, tree_hash, confirmed_transcript_hash);
    epoch_from_joiner(joiner_secret, &ctx)
}

/// Build a signed [`GroupInfo`] — the joiner's bootstrap view (§3.4). The secret-delivery wrap
/// to each joiner's device bundle is the caller's (`seal_self_sync_key` rail, `device.rs:505`),
/// which lives with the identity keys; this pins the public, signed half.
pub fn build_group_info(
    group_id: &[u8],
    epoch: u64,
    tree_blob_ref: &[u8],
    confirmed_transcript_hash: [u8; 32],
    tree_hash: [u8; 32],
    signer_leaf: u32,
    sign: impl FnOnce(&[u8]) -> Vec<u8>,
) -> GroupInfo {
    let mut gi = GroupInfo {
        group_id: group_id.to_vec(),
        epoch,
        tree_blob_ref: tree_blob_ref.to_vec(),
        confirmed_transcript_hash,
        tree_hash,
        signer_leaf,
        sig: Vec::new(),
    };
    let mut payload = Vec::with_capacity(GROUPINFO_DOMAIN.len());
    payload.extend_from_slice(GROUPINFO_DOMAIN);
    payload.extend_from_slice(&gi.to_bytes());
    gi.sig = sign(&payload);
    gi
}

// ═════════════════════════════════════════════════════════════════════════════════════════
// Stage M4 — offline / mid-chain Welcome ENTRY (design §4.2 Add, §4.4/§5.5 Welcome + sleeper
// re-entry, §9 row M4).
//
// M2's `welcome_epoch_schedule` bootstraps a joiner from a genesis Welcome ONLY: the tree is
// reconstructed by the caller from the genesis Adds. M4 adds the SELF-CONTAINED entry a joiner
// added mid-life (or a sleeper past the mailbox TTL, §5.5) needs — one that does NOT replay the
// commit chain: the Welcome carries a `GroupInfo` (epoch n, tree_blob_ref, tree_hash,
// confirmed_transcript_hash) plus the serialized public tree as a content-addressed blob, so the
// joiner reconstructs epoch n directly and derives the SAME epoch secret every member at n holds.
//
// TWO invariants this file is the home of, both asserted by the M4 tests:
//   * "Enter at epoch n, never rebuild genesis." `enter_via_welcome` lands the joiner at the
//     GroupInfo's epoch — the live epoch — with epoch CONTINUITY preserved; it never resets to a
//     fresh epoch-1 tree. A mid-life Add is a chained commit, not a superseding genesis.
//   * "Revoked-in-the-meantime fails closed." The entry VERIFIES the joiner's own leaf is present
//     in the delivered tree AND that its public key matches the delivered leaf secret. A device
//     removed (leaf blanked) or handed a leaf secret that doesn't match the tree cannot enter —
//     the tree does not admit it, by construction, with no separate policy check to forget.
// Everything here is PURE (caller-supplied secrets, no I/O, no RNG) exactly like M1/M2.
// ═════════════════════════════════════════════════════════════════════════════════════════

/// The content-addressed ref of a serialized [`RatchetTree`] blob (§3.4/§4.6, design point 4):
/// a domain-separated blake3 over the tree bytes. A [`GroupInfo`] names the tree by this ref so
/// the tree can travel as a mailbox blob (like media/commit refs) instead of inline in every
/// Welcome, and a receiver can VERIFY the blob it fetched is the one the signed GroupInfo meant.
pub fn tree_blob_ref(tree_bytes: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new();
    h.update(b"haven-mls-treeblob-v1");
    h.update(tree_bytes);
    *h.finalize().as_bytes()
}

/// The secrets a Welcome delivers to ONE joiner (sealed to its device bundle by the caller via
/// the `seal_self_sync_key` rail, `device.rs:505`): the epoch's `joiner_secret` (§3.3 — with the
/// public context this yields the shared `epoch_secret`), the joiner's own tree leaf secret (for
/// participating in future path updates/removes), and its leaf index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WelcomeSecrets {
    pub joiner_secret: [u8; 32],
    pub leaf_secret: [u8; 32],
    pub leaf_index: u32,
}

/// What a joiner gets from [`enter_via_welcome`]: the reconstructed public tree at the Welcome's
/// epoch, the derived epoch schedule (the same one members at that epoch hold), and the joiner's
/// private tree state — everything a keying replay needs to CONTINUE forward from epoch n.
pub struct WelcomeEntry {
    pub tree: RatchetTree,
    pub schedule: EpochSchedule,
    pub my_private: TreePrivate,
}

/// Enter a live group at a mid-chain (or re-entry) Welcome WITHOUT replaying the commit chain
/// (§4.2 mid-life Add, §5.5 sleeper re-entry). The joiner:
///   1. verifies the delivered tree blob hashes to the signed GroupInfo's `tree_blob_ref` AND
///      that its `tree_hash` matches — so a tampered/substituted tree is rejected;
///   2. FAILS CLOSED unless its own leaf is present in that tree with a public key matching the
///      delivered `leaf_secret` — a device revoked (leaf blanked/absent) or fed a mismatched leaf
///      secret cannot enter; the tree does not admit it (the "revoked-in-the-meantime" invariant);
///   3. derives epoch n's schedule from the delivered `joiner_secret` + the PUBLIC epoch context
///      (group id, epoch, tree hash, confirmed transcript hash) — the identical `epoch_secret`
///      every member at epoch n derives (epoch CONTINUITY; it never rebuilds a genesis).
///
/// Pure: no chain, no RNG, no I/O. The GroupInfo signature is verified by the CALLER (it holds the
/// roster to resolve the signer); this is the cryptographic tree/schedule bootstrap.
pub fn enter_via_welcome(
    group_info: &GroupInfo,
    tree_bytes: &[u8],
    secrets: &WelcomeSecrets,
) -> Result<WelcomeEntry> {
    // (1) The blob the joiner fetched must be the one the signed GroupInfo named — bind ref+hash.
    if tree_blob_ref(tree_bytes) != group_info.tree_blob_ref[..] {
        return Err(CoreError::Crypto("treekem: welcome tree blob ref mismatch"));
    }
    let tree = RatchetTree::from_bytes(tree_bytes)?;
    if tree_hash(&tree) != group_info.tree_hash {
        return Err(CoreError::Crypto("treekem: welcome tree hash mismatch"));
    }
    // (2) FAIL CLOSED: my leaf must be present AND its key must match the leaf secret I was handed.
    // A removed device's leaf is blanked (absent) ⇒ rejected here; a leaf secret that doesn't match
    // the tree ⇒ rejected here. Either way the tree refuses to admit a device it doesn't carry.
    let leaf = tree
        .leaf(secrets.leaf_index)
        .ok_or(CoreError::Crypto("treekem: welcome leaf absent from tree (revoked?)"))?;
    let kp = node_keypair_from_path_secret(&secrets.leaf_secret);
    if kp.kem_x != leaf.leaf_kem_x || kp.kem_pq[..] != leaf.leaf_kem_pq[..] {
        return Err(CoreError::Crypto("treekem: welcome leaf key inconsistent with delivered secret"));
    }
    // (3) Derive epoch n straight from the joiner secret + PUBLIC context — the shared epoch_secret,
    // at the LIVE epoch (never a rebuilt genesis).
    let schedule = welcome_epoch_schedule(
        &secrets.joiner_secret,
        &group_info.group_id,
        group_info.epoch,
        &group_info.tree_hash,
        &group_info.confirmed_transcript_hash,
    );
    Ok(WelcomeEntry { tree, schedule, my_private: TreePrivate::new(secrets.leaf_index, secrets.leaf_secret) })
}

#[cfg(test)]
mod m4_tests {
    use super::*;

    const GID: &[u8] = b"m4-test-circle";

    fn fake_sig(payload: &[u8]) -> Vec<u8> {
        blake3::hash(payload).as_bytes().to_vec()
    }
    fn secret(tag: &str, i: usize) -> [u8; 32] {
        *blake3::hash(format!("{tag}-{i}").as_bytes()).as_bytes()
    }
    fn leaf_for(secret: &[u8; 32], cred: &[u8]) -> LeafNode {
        let kp = node_keypair_from_path_secret(secret);
        let payload = leaf_binding_payload(GID, &kp.kem_x, &kp.kem_pq);
        LeafNode {
            leaf_kem_x: kp.kem_x,
            leaf_kem_pq: kp.kem_pq,
            device_credential: cred.to_vec(),
            leaf_binding_sig: fake_sig(&payload),
        }
    }

    /// A genesis of `n` leaves, keyed off a fixed `base_init`, built by leaf 0 (add-only, no path).
    /// Returns (commit, post-genesis tree, cth_1, epoch-1 schedule, per-leaf secrets).
    #[allow(clippy::type_complexity)]
    fn genesis(n: usize) -> (Commit, RatchetTree, [u8; 32], EpochSchedule, Vec<[u8; 32]>) {
        let base_init = secret("base-init", 0);
        let base_cth = secret("base-cth", 0);
        let parent = secret("genesis-parent", 0);
        let leaf_secrets: Vec<[u8; 32]> = (0..n).map(|i| secret("leaf", i)).collect();
        let adds: Vec<Proposal> = (0..n)
            .map(|i| {
                let ln = leaf_for(&leaf_secrets[i], &[0xC0, i as u8]);
                build_add_proposal(GID, 0, i as u32, ln, fake_sig)
            })
            .collect();
        let build = build_commit(
            &RatchetTree { slots: vec![] }, GID, 1, parent, &base_cth, &base_init, 0, adds, None,
            fake_sig, fake_sig,
        )
        .unwrap();
        (build.commit, build.tree, build.confirmed_transcript_hash, build.schedule, leaf_secrets)
    }

    /// §9 M4 proof — MID-LIFE ADD + WELCOME with epoch CONTINUITY: a live 3-leaf group; the
    /// committer chains an Add+UpdatePath at epoch 2 (NOT a fresh genesis); an existing member
    /// applies it and lands at epoch 2; the NEW joiner enters via a self-contained Welcome and
    /// derives the IDENTICAL epoch-2 secret — proving it entered at the live epoch, not a rebuild.
    #[test]
    fn mid_chain_add_welcome_enters_at_live_epoch_not_genesis() {
        let (gcommit, gtree, gcth, gsched, lsecs) = genesis(3);
        let gparent_hash = commit_hash(&gcommit.to_bytes());

        // The committer (leaf 0) chains an Add for a brand-new leaf 3 + its own path re-key at epoch 2.
        let joiner_secret_val = secret("joiner-leaf", 3);
        let joiner_ln = leaf_for(&joiner_secret_val, &[0xC0, 3]);
        let add = build_add_proposal(GID, 2, 0, joiner_ln, fake_sig);
        let new_leaf = secret("upd-leaf", 2);
        let entropy = secret("upd-ent", 2);
        let cred0 = gtree.leaf(0).unwrap().device_credential.clone();
        let build = build_commit(
            &gtree, GID, 2, gparent_hash, &gcth, &gsched.init_secret, 0, vec![add],
            Some((&new_leaf, &cred0, &entropy)), fake_sig, fake_sig,
        )
        .unwrap();
        assert_eq!(build.commit.epoch, 2, "the Add is a CHAINED commit at epoch 2, not a genesis");

        // An EXISTING member (leaf 1) applies the chained commit → lands at epoch 2 with the same secret.
        let mp1 = TreePrivate::new(1, lsecs[1]);
        let applied = apply_commit(&gtree, GID, &gcth, &gsched.init_secret, &build.commit, Some(&mp1)).unwrap();
        let member_sched = applied.schedule.expect("existing member derives epoch 2");
        assert_eq!(member_sched.epoch_secret, build.schedule.epoch_secret, "member converges on committer's epoch 2");

        // The NEW joiner enters via a self-contained Welcome — tree blob + GroupInfo at epoch 2.
        let tree_bytes = build.tree.to_bytes();
        let gi = build_group_info(
            GID, 2, &tree_blob_ref(&tree_bytes), build.confirmed_transcript_hash, build.commit.tree_hash, 0, fake_sig,
        );
        // The joiner's leaf index is the one the Add placed it at (leaf 3 in a 4-leaf tree).
        let joiner_leaf = build.tree.slots.iter().enumerate().find_map(|(i, s)| match s {
            TreeSlot::Leaf(l) if l.leaf_kem_x == node_keypair_from_path_secret(&joiner_secret_val).kem_x => Some((i / 2) as u32),
            _ => None,
        }).unwrap();
        let entry = enter_via_welcome(
            &gi, &tree_bytes,
            &WelcomeSecrets { joiner_secret: build.schedule.joiner_secret, leaf_secret: joiner_secret_val, leaf_index: joiner_leaf },
        )
        .unwrap();
        assert_eq!(entry.schedule.epoch_secret, build.schedule.epoch_secret, "the joiner derives the LIVE epoch-2 secret");
        assert_eq!(entry.schedule.sender_root, member_sched.sender_root, "joiner + member share sender_root at the live epoch");

        // Continuity: the joiner did NOT land at a genesis. sender_key at epoch 2 for account bytes agrees.
        let acct = [0x42u8; 32];
        assert_eq!(
            sender_key(&entry.schedule.sender_root, &acct, GID, 2),
            sender_key(&member_sched.sender_root, &acct, GID, 2),
            "joiner and member compute the identical epoch-2 content key",
        );
    }

    /// §9 M4 proof — SLEEPER RE-ENTRY (§5.5): a device that cannot replay the chain (its intermediate
    /// commits are gone past the mailbox TTL) re-enters via a FRESH self-contained Welcome at the
    /// current epoch and converges to the live epoch secret — no chain replay required.
    #[test]
    fn sleeper_reenters_via_selfcontained_welcome_and_converges() {
        // A 4-leaf group has advanced to some epoch; the sleeper is leaf 2. The current committer
        // holds the live schedule and re-Welcomes the sleeper's EXISTING leaf.
        let (_gc, gtree, gcth, gsched, lsecs) = genesis(4);
        // Advance one epoch via a committer (leaf 0) path re-key so "current" != genesis.
        let new_leaf = secret("upd-leaf", 9);
        let entropy = secret("upd-ent", 9);
        let cred0 = gtree.leaf(0).unwrap().device_credential.clone();
        let gparent = commit_hash(&_gc.to_bytes());
        let build = build_commit(
            &gtree, GID, 2, gparent, &gcth, &gsched.init_secret, 0, vec![],
            Some((&new_leaf, &cred0, &entropy)), fake_sig, fake_sig,
        )
        .unwrap();
        let cur_tree = build.tree.clone();
        let cur_cth = build.confirmed_transcript_hash;
        let cur_epoch = 2u64;
        let cur_joiner = build.schedule.joiner_secret;

        // The sleeper (leaf 2) lost ALL state; a fresh Welcome carries the CURRENT tree + context.
        let tree_bytes = cur_tree.to_bytes();
        let gi = build_group_info(
            GID, cur_epoch, &tree_blob_ref(&tree_bytes), cur_cth, build.commit.tree_hash, 0, fake_sig,
        );
        let entry = enter_via_welcome(
            &gi, &tree_bytes,
            &WelcomeSecrets { joiner_secret: cur_joiner, leaf_secret: lsecs[2], leaf_index: 2 },
        )
        .unwrap();
        assert_eq!(entry.schedule.epoch_secret, build.schedule.epoch_secret, "the sleeper converges to the live epoch secret");
        // It is at the CURRENT epoch, not epoch 1.
        assert_eq!(gi.epoch, 2);
    }

    /// §9 M4 proof — REVOKED FAILS CLOSED: a Welcome addressed to a device whose leaf is not in the
    /// (post-revocation) tree, or whose delivered leaf secret does not match the tree, is REJECTED —
    /// the joiner cannot enter; the tree does not admit it.
    #[test]
    fn revoked_welcome_fails_closed() {
        let (_gc, mut tree, gcth, gsched, lsecs) = genesis(3);
        // The device at leaf 1 is REVOKED: its leaf is blanked (a Remove would have done this).
        remove_leaf(&mut tree, 1).unwrap();
        let tree_bytes = tree.to_bytes();
        let gi = build_group_info(
            GID, 2, &tree_blob_ref(&tree_bytes), gcth, tree_hash(&tree), 0, fake_sig,
        );
        // A stale Welcome still names leaf 1 with its old secret — entry must FAIL CLOSED (leaf absent).
        let err = enter_via_welcome(
            &gi, &tree_bytes,
            &WelcomeSecrets { joiner_secret: gsched.joiner_secret, leaf_secret: lsecs[1], leaf_index: 1 },
        );
        assert!(err.is_err(), "a revoked (blanked-leaf) device cannot enter via a stale Welcome");

        // A mismatched leaf secret for a STILL-present leaf also fails closed (no leaf-secret grinding).
        let bad = enter_via_welcome(
            &gi, &tree_bytes,
            &WelcomeSecrets { joiner_secret: gsched.joiner_secret, leaf_secret: secret("wrong", 0), leaf_index: 0 },
        );
        assert!(bad.is_err(), "a leaf secret that doesn't match the tree leaf is rejected");

        // A substituted tree blob (ref/hash mismatch) is rejected before any secret is used.
        let mut tampered = tree_bytes.clone();
        *tampered.last_mut().unwrap() ^= 0xFF;
        let sub = enter_via_welcome(
            &gi, &tampered,
            &WelcomeSecrets { joiner_secret: gsched.joiner_secret, leaf_secret: lsecs[0], leaf_index: 0 },
        );
        assert!(sub.is_err(), "a tree blob that doesn't match the signed GroupInfo ref is rejected");
    }
}

#[cfg(test)]
mod m2_tests {
    use super::*;

    const GID: &[u8] = b"m2-test-circle";

    fn fake_sig(payload: &[u8]) -> Vec<u8> {
        blake3::hash(payload).as_bytes().to_vec()
    }
    fn secret(tag: &str, i: usize) -> [u8; 32] {
        *blake3::hash(format!("{tag}-{i}").as_bytes()).as_bytes()
    }
    fn cred(member: usize) -> Vec<u8> {
        (member as u32).to_le_bytes().to_vec()
    }
    fn leaf_for(secret: &[u8; 32], credential: &[u8]) -> LeafNode {
        let kp = node_keypair_from_path_secret(secret);
        let payload = leaf_binding_payload(GID, &kp.kem_x, &kp.kem_pq);
        LeafNode {
            leaf_kem_x: kp.kem_x,
            leaf_kem_pq: kp.kem_pq,
            device_credential: credential.to_vec(),
            leaf_binding_sig: fake_sig(&payload),
        }
    }

    /// §9 M2 pure-builder proof: a committer builds a commit (with a path), and every OTHER
    /// member applies it and lands on the identical tree hash + epoch secret; the confirmation
    /// MAC verifies for all. Uses the NEW `build_commit`/`apply_commit` (not the M1 harness's
    /// inline logic) so the builders themselves are the thing under test.
    #[test]
    fn commit_builder_and_apply_commit_converge_on_tree_and_epoch_secret() {
        let secrets: Vec<[u8; 32]> = (0..4).map(|i| secret("leaf", i)).collect();
        let tree0 =
            RatchetTree::from_leaves((0..4).map(|i| leaf_for(&secrets[i], &cred(i))).collect());
        let privs: Vec<TreePrivate> =
            (0..4).map(|i| TreePrivate::new(i as u32, secrets[i])).collect();
        let genesis_init = secret("init", 0);
        let genesis_cth = secret("cth", 0);
        let parent = secret("parent", 0);

        // Member 0 commits a Remove(3) + a path refresh of its own leaf.
        let rp = build_remove_proposal(GID, 0, 0, 3, fake_sig);
        let new0 = secret("new", 0);
        let ent = secret("ent", 0);
        let build = build_commit(
            &tree0, GID, 1, parent, &genesis_cth, &genesis_init, 0, vec![rp],
            Some((&new0, &cred(0), &ent)), fake_sig, fake_sig,
        )
        .unwrap();

        // Members 1 and 2 apply and must converge; member 3 was removed → no schedule.
        for m in [1usize, 2] {
            let a = apply_commit(&tree0, GID, &genesis_cth, &genesis_init, &build.commit, Some(&privs[m]))
                .unwrap();
            assert_eq!(tree_hash(&a.tree), tree_hash(&build.tree), "member {m} tree diverged");
            assert_eq!(a.confirmed_transcript_hash, build.confirmed_transcript_hash);
            let s = a.schedule.expect("present member derives the epoch");
            assert_eq!(s.epoch_secret, build.schedule.epoch_secret, "member {m} epoch secret diverged");
        }
        let removed =
            apply_commit(&tree0, GID, &genesis_cth, &genesis_init, &build.commit, Some(&privs[3])).unwrap();
        assert!(removed.removed_me, "leaf 3 must observe its own removal");
        assert!(removed.schedule.is_none(), "a removed member derives no epoch secret");

        // The committer must not re-apply its own commit.
        assert!(apply_commit(&tree0, GID, &genesis_cth, &genesis_init, &build.commit, Some(&privs[0])).is_err());
    }

    /// §9 M2 pure-builder proof: an add-only (no-path) commit lets a Welcomed joiner reach the
    /// SAME epoch secret via `welcome_epoch_schedule` — the genesis shape the shadow wiring uses.
    #[test]
    fn add_only_commit_welcomes_joiners_to_the_same_epoch() {
        // Genesis: empty tree, Add every device, no path (commit_secret = 0). One creator.
        let devs = 4usize;
        let leaf_secrets: Vec<[u8; 32]> = (0..devs).map(|i| secret("g-leaf", i)).collect();
        let adds: Vec<Proposal> = (0..devs)
            .map(|i| build_add_proposal(GID, 0, 0, leaf_for(&leaf_secrets[i], &cred(i)), fake_sig))
            .collect();
        let genesis_init = secret("g-init", 0);
        let genesis_cth = secret("g-cth", 0);
        let parent = secret("g-parent", 0);
        let build = build_commit(
            &RatchetTree { slots: vec![] }, GID, 1, parent, &genesis_cth, &genesis_init, 0, adds,
            None, fake_sig, fake_sig,
        )
        .unwrap();
        assert_eq!(build.tree.n_leaves(), devs, "genesis tree holds every device");

        // Every joiner reconstructs the tree from the commit's Adds and, with the delivered
        // joiner_secret + the public context, reaches the identical epoch secret.
        let mut recon = RatchetTree { slots: vec![] };
        apply_proposals(&mut recon, &build.commit.proposals, None).unwrap();
        assert_eq!(tree_hash(&recon), build.commit.tree_hash, "joiner reconstructs the tree");
        let joiner = welcome_epoch_schedule(
            &build.schedule.joiner_secret, GID, build.commit.epoch, &build.commit.tree_hash,
            &build.confirmed_transcript_hash,
        );
        assert_eq!(joiner.epoch_secret, build.schedule.epoch_secret, "joiner reaches the epoch secret");
        // Sender keys derived from it match too (the 32-byte content-layer keys).
        let probe = *blake3::hash(b"probe").as_bytes();
        assert_eq!(
            sender_key(&joiner.sender_root, &probe, GID, 1),
            sender_key(&build.schedule.sender_root, &probe, GID, 1),
        );
    }

    /// §9 M2 pure-builder proof: two committers building on the SAME parent fork, and every
    /// replica resolves the fork to the identical winner via `select_chain` — the wiring's
    /// convergence backstop, exercised through the real `build_commit`.
    #[test]
    fn concurrent_commits_via_builder_fork_and_resolve_identically() {
        let secrets: Vec<[u8; 32]> = (0..4).map(|i| secret("leaf", i)).collect();
        let tree0 =
            RatchetTree::from_leaves((0..4).map(|i| leaf_for(&secrets[i], &cred(i))).collect());
        let genesis_init = secret("init", 1);
        let genesis_cth = secret("cth", 1);
        let parent = secret("parent", 1);

        // Members 0 and 1 both commit an Update of their own leaf at epoch 1 with parent = genesis.
        let mut forks = Vec::new();
        for m in [0u32, 1] {
            let b = build_commit(
                &tree0, GID, 1, parent, &genesis_cth, &genesis_init, m, vec![],
                Some((&secret("new", m as usize), &cred(m as usize), &secret("ent", m as usize))),
                fake_sig, fake_sig,
            )
            .unwrap();
            forks.push(b.commit.to_bytes());
        }
        // Both branches are valid, same parent → a fork. Every replica sees the same candidate
        // set and picks the same winner (largest tip hash).
        let cands: Vec<Vec<Vec<u8>>> = forks.iter().map(|b| vec![b.clone()]).collect();
        let winner = select_chain(&parent, 1, GID, &cands).expect("a valid winner");
        // Determinism: recomputing from a shuffled candidate order still names the same commit.
        let rev: Vec<Vec<Vec<u8>>> = cands.iter().rev().cloned().collect();
        let winner_rev = select_chain(&parent, 1, GID, &rev).unwrap();
        assert_eq!(commit_hash(&cands[winner][0]), commit_hash(&rev[winner_rev][0]));
        assert_eq!(cands[winner][0], if commit_hash(&forks[0]) > commit_hash(&forks[1]) { forks[0].clone() } else { forks[1].clone() });
    }
}

#[cfg(test)]
mod m1_tests {
    use super::*;
    use rand::{Rng, RngCore};

    const GID: &[u8] = b"m1-test-circle";

    /// Deterministic stand-in signature. M1 never verifies signatures (that is M2's
    /// roster-authorization work), so tests use cheap deterministic bytes instead of
    /// paying ML-DSA per leaf — what matters here is byte-stability, not validity.
    fn fake_sig(payload: &[u8]) -> Vec<u8> {
        blake3::hash(payload).as_bytes().to_vec()
    }

    fn secret(tag: &str, i: usize) -> [u8; 32] {
        *blake3::hash(format!("{tag}-{i}").as_bytes()).as_bytes()
    }

    fn cred(member: usize) -> Vec<u8> {
        (member as u32).to_le_bytes().to_vec()
    }

    fn member_from_cred(c: &[u8]) -> usize {
        u32::from_le_bytes(c.try_into().expect("4-byte sim credential")) as usize
    }

    fn leaf_node_for(gid: &[u8], leaf_secret: &[u8; 32], credential: &[u8]) -> LeafNode {
        let kp = node_keypair_from_path_secret(leaf_secret);
        let payload = leaf_binding_payload(gid, &kp.kem_x, &kp.kem_pq);
        LeafNode {
            leaf_kem_x: kp.kem_x,
            leaf_kem_pq: kp.kem_pq,
            device_credential: credential.to_vec(),
            leaf_binding_sig: fake_sig(&payload),
        }
    }

    // ── Tree math ────────────────────────────────────────────────────────────────────────

    /// Recursive reference construction of a left-balanced tree: left subtree is the
    /// largest complete tree, in-order array layout. Everything the arithmetic functions
    /// claim is cross-checked against this ground truth for every size up to 40 leaves.
    fn build_ref(
        a: usize,
        l: usize,
        ch: &mut BTreeMap<usize, (usize, usize)>,
        ls: &mut BTreeMap<usize, Vec<usize>>,
    ) -> usize {
        if l == 1 {
            ls.insert(2 * a, vec![2 * a]);
            return 2 * a;
        }
        let mut k = 1;
        while k * 2 < l {
            k *= 2;
        }
        let lt = build_ref(a, k, ch, ls);
        let rt = build_ref(a + k, l - k, ch, ls);
        let root = 2 * a + 2 * k - 1;
        ch.insert(root, (lt, rt));
        let mut v = ls[&lt].clone();
        v.extend(ls[&rt].iter().copied());
        ls.insert(root, v);
        root
    }

    #[test]
    fn tree_math_matches_recursive_reference_for_all_sizes() {
        for n in 1usize..=40 {
            let mut ch = BTreeMap::new();
            let mut ls = BTreeMap::new();
            let root = build_ref(0, n, &mut ch, &mut ls);
            assert_eq!(root_index(n).unwrap(), root, "root, n={n}");
            assert_eq!(parent_index(root, n).unwrap(), None);
            let mut parent_of = BTreeMap::new();
            for (&p, &(l, r)) in &ch {
                assert_eq!(left_child(p).unwrap(), l, "left({p}), n={n}");
                assert_eq!(right_child(p, n).unwrap(), r, "right({p}), n={n}");
                assert_eq!(parent_index(l, n).unwrap(), Some(p), "parent({l}), n={n}");
                assert_eq!(parent_index(r, n).unwrap(), Some(p), "parent({r}), n={n}");
                assert_eq!(sibling_index(l, n).unwrap(), Some(r));
                assert_eq!(sibling_index(r, n).unwrap(), Some(l));
                parent_of.insert(l, p);
                parent_of.insert(r, p);
            }
            for leaf in 0..n {
                let slot = leaf_slot(leaf as u32);
                // direct path == climbing the reference parents
                let mut want = Vec::new();
                let mut cur = slot;
                while let Some(&p) = parent_of.get(&cur) {
                    want.push(p);
                    cur = p;
                }
                assert_eq!(direct_path(slot, n).unwrap(), want, "direct_path({slot}), n={n}");
                // copath[i] is the sibling of the previous path step
                let cp = copath(slot, n).unwrap();
                assert_eq!(cp.len(), want.len());
                let mut prev = slot;
                for (i, &c) in cp.iter().enumerate() {
                    assert_eq!(sibling_index(prev, n).unwrap(), Some(c), "copath[{i}]");
                    prev = want[i];
                }
            }
            // subtree containment matches the reference leaf sets exactly
            for (&node, leaves) in &ls {
                for leaf in 0..n {
                    let slot = leaf_slot(leaf as u32);
                    assert_eq!(
                        subtree_contains(node, slot, n),
                        leaves.contains(&slot),
                        "subtree_contains({node}, {slot}), n={n}"
                    );
                }
            }
        }
    }

    #[test]
    fn resolution_handles_blanks_and_unmerged_leaves() {
        // 4 leaves, all parents blank: resolution of the root is every populated leaf.
        let mut tree = RatchetTree::from_leaves(
            (0..4).map(|i| leaf_node_for(GID, &secret("leaf", i), &cred(i))).collect(),
        );
        assert_eq!(tree.n_leaves(), 4);
        assert_eq!(resolution(&tree, 3).unwrap(), vec![0, 2, 4, 6]);
        // Blank a leaf: it drops out of every resolution.
        remove_leaf(&mut tree, 1).unwrap();
        assert_eq!(resolution(&tree, 3).unwrap(), vec![0, 4, 6]);
        assert_eq!(resolution(&tree, 2).unwrap(), Vec::<usize>::new());
        // A populated parent resolves to itself plus its unmerged leaves.
        tree.slots[5] = TreeSlot::Parent(ParentNode {
            blank: false,
            node_kem_x: [1; KEM_X_LEN],
            node_kem_pq: [2; MLKEM_EK_LEN],
            unmerged_leaves: vec![3],
        });
        assert_eq!(resolution(&tree, 5).unwrap(), vec![5, 6]);
        // ParentNode{blank:true} behaves exactly like TreeSlot::Blank.
        tree.slots[5] = TreeSlot::Parent(ParentNode {
            blank: true,
            node_kem_x: [0; KEM_X_LEN],
            node_kem_pq: [0; MLKEM_EK_LEN],
            unmerged_leaves: vec![],
        });
        assert_eq!(resolution(&tree, 5).unwrap(), vec![4, 6]);
    }

    // ── Node keygen + path-secret encryption ─────────────────────────────────────────────

    #[test]
    fn node_keygen_is_deterministic_and_derivations_are_domain_separated() {
        let s = [7u8; 32];
        let a = node_keypair(&s);
        let b = node_keypair(&s);
        assert_eq!(a.kem_x, b.kem_x);
        assert_eq!(a.kem_pq[..], b.kem_pq[..]);
        // The §3.2 chain: path/node/commit derivations from the same input all differ.
        let ps = derive_path_secret(&s);
        let ns = derive_node_secret(&s);
        let cs = derive_commit_secret(&s);
        assert_ne!(ps, ns);
        assert_ne!(ps, cs);
        assert_ne!(ns, cs);
        assert_ne!(ps, s);
        // Node keys are domain-separated from identity keys derived from the same seed
        // (different HKDF salt): the x25519 public halves must differ.
        let id = crate::identity::Identity::from_seed(&ns);
        assert_ne!(node_keypair(&ns).kem_x, id.public().kem_x.to_bytes());
    }

    #[test]
    fn path_secret_seal_open_roundtrip_and_wrong_context_fails() {
        let kp = node_keypair(&[1; 32]);
        let ps = [9u8; 32];
        let ct = seal_path_secret(&kp.kem_x, &kp.kem_pq, GID, 5, 4, &ps, &[3; 32]).unwrap();
        assert_eq!(open_path_secret(&kp, GID, 5, &ct).unwrap(), ps);
        // Determinism: same seed → identical bytes; different seed → different bytes.
        let ct2 = seal_path_secret(&kp.kem_x, &kp.kem_pq, GID, 5, 4, &ps, &[3; 32]).unwrap();
        assert_eq!(ct, ct2);
        let ct3 = seal_path_secret(&kp.kem_x, &kp.kem_pq, GID, 5, 4, &ps, &[4; 32]).unwrap();
        assert_ne!(ct, ct3);
        // Every context field is bound into the key: group, epoch, node index, recipient.
        assert!(open_path_secret(&kp, b"other-group", 5, &ct).is_err());
        assert!(open_path_secret(&kp, GID, 6, &ct).is_err());
        let mut wrong_slot = ct.clone();
        wrong_slot.resolution_index = 5;
        assert!(open_path_secret(&kp, GID, 5, &wrong_slot).is_err());
        let other = node_keypair(&[2; 32]);
        assert!(open_path_secret(&other, GID, 5, &ct).is_err());
    }

    // ── UpdatePath build/apply ───────────────────────────────────────────────────────────

    #[test]
    fn update_path_converges_for_every_member_and_via_interior_nodes() {
        let secrets: Vec<[u8; 32]> = (0..4).map(|i| secret("leaf", i)).collect();
        let tree0 = RatchetTree::from_leaves(
            (0..4).map(|i| leaf_node_for(GID, &secrets[i], &cred(i))).collect(),
        );
        let mut privs: Vec<TreePrivate> =
            (0..4).map(|i| TreePrivate::new(i as u32, secrets[i])).collect();

        // Leaf 0 commits a path over the fresh (all-blank-parents) tree.
        let new0 = secret("new", 0);
        let b = build_update_path(&tree0, GID, 1, 0, &new0, &cred(0), fake_sig, &secret("ent", 0))
            .unwrap();
        let mut tree1 = tree0.clone();
        merge_update_path(&mut tree1, 0, &b.update_path).unwrap();
        privs[0] = TreePrivate::new(0, new0);
        privs[0].path_secrets = b.path_secrets.clone();
        for i in 1..4 {
            let d = decrypt_update_path(&tree0, GID, 1, 0, &b.update_path, &privs[i]).unwrap();
            assert_eq!(d.commit_secret, b.commit_secret, "member {i} must agree on commit secret");
            let mut t = tree0.clone();
            merge_update_path(&mut t, 0, &b.update_path).unwrap();
            assert_eq!(tree_hash(&t), tree_hash(&tree1), "member {i} must agree on the tree");
            privs[i].path_secrets.extend(d.path_secrets);
        }

        // Leaf 3 commits next: leaf 1 sits under the far side, so its only decryption key
        // for the new root secret is the INTERIOR node it learned above — exercising the
        // non-leaf decryption branch.
        let new3 = secret("new", 3);
        let b2 = build_update_path(&tree1, GID, 2, 3, &new3, &cred(3), fake_sig, &secret("ent", 3))
            .unwrap();
        let root_node = b2.update_path.nodes.last().unwrap();
        assert!(
            root_node.ciphertexts.iter().any(|ct| ct.resolution_index == 1),
            "root path secret must be wrapped to interior node 1, not the individual leaves"
        );
        for i in [0usize, 1, 2] {
            let d = decrypt_update_path(&tree1, GID, 2, 3, &b2.update_path, &privs[i]).unwrap();
            assert_eq!(d.commit_secret, b2.commit_secret);
        }
    }

    #[test]
    fn update_path_consistency_check_rejects_tampered_node_key() {
        let secrets: Vec<[u8; 32]> = (0..4).map(|i| secret("leaf", i)).collect();
        let tree0 = RatchetTree::from_leaves(
            (0..4).map(|i| leaf_node_for(GID, &secrets[i], &cred(i))).collect(),
        );
        let b = build_update_path(&tree0, GID, 1, 0, &secret("new", 0), &cred(0), fake_sig, &secret("ent", 0))
            .unwrap();
        // Tamper with the ROOT node's public key: leaf 1 decrypts at node 1 (below the
        // tampered node), derives upward, and must catch the mismatch instead of merging
        // a tree whose keys disagree with its secrets.
        let mut evil = b.update_path.clone();
        evil.nodes.last_mut().unwrap().node_kem_x = [0xEE; KEM_X_LEN];
        let p1 = TreePrivate::new(1, secrets[1]);
        let err = decrypt_update_path(&tree0, GID, 1, 0, &evil, &p1);
        assert!(err.is_err(), "derived node key mismatch must be rejected");
    }

    #[test]
    fn added_leaf_is_unmerged_until_a_path_rekeys_and_gets_addressed_directly() {
        // 8 leaves so a non-root interior node can hold an unmerged entry that a far-side
        // committer's path must honor.
        let secrets: Vec<[u8; 32]> = (0..8).map(|i| secret("leaf", i)).collect();
        let mut tree = RatchetTree::from_leaves(
            (0..8).map(|i| leaf_node_for(GID, &secrets[i], &cred(i))).collect(),
        );
        let mut privs: BTreeMap<u32, TreePrivate> =
            (0..8).map(|i| (i as u32, TreePrivate::new(i as u32, secrets[i as usize]))).collect();

        // Helper: member `sender` commits a path at `epoch`; every other tracked private
        // decrypts, agrees on the commit secret, and merges.
        let commit_path = |tree: &mut RatchetTree,
                               privs: &mut BTreeMap<u32, TreePrivate>,
                               sender: u32,
                               epoch: u64| {
            let new = secret("upd", (sender as usize) * 100 + epoch as usize);
            let b = build_update_path(tree, GID, epoch, sender, &new, &cred(sender as usize), fake_sig, &secret("ent", epoch as usize))
                .unwrap();
            for (&li, p) in privs.iter_mut() {
                if li == sender {
                    continue;
                }
                let d = decrypt_update_path(tree, GID, epoch, sender, &b.update_path, p).unwrap();
                assert_eq!(d.commit_secret, b.commit_secret, "leaf {li} commit secret");
                p.path_secrets.extend(d.path_secrets);
            }
            let me = privs.get_mut(&sender).unwrap();
            me.leaf_secret = new;
            me.path_secrets = b.path_secrets.clone();
            merge_update_path(tree, sender, &b.update_path).unwrap();
            b
        };

        // Epoch 1: leaf 0 populates its path (1, 3, 7). Epoch 2: leaf 4 populates the
        // right half (9, 11, 7).
        commit_path(&mut tree, &mut privs, 0, 1);
        commit_path(&mut tree, &mut privs, 4, 2);

        // Remove leaf 1: blanks slots 2, 1, 3, 7 and drops its private state.
        remove_leaf(&mut tree, 1).unwrap();
        privs.remove(&1);
        for p in privs.values_mut() {
            let t = &tree;
            p.path_secrets.retain(|&ix, _| matches!(t.slots.get(ix as usize), Some(TreeSlot::Parent(pn)) if !pn.blank));
        }

        // Epoch 3: leaf 0 re-keys — node 1 is filtered out (nothing lives under slot 2),
        // nodes 3 and 7 come back non-blank.
        let b3 = commit_path(&mut tree, &mut privs, 0, 3);
        assert_eq!(b3.update_path.nodes.len(), 2, "node 1 must be filtered out");
        assert!(matches!(&tree.slots[1], TreeSlot::Blank));

        // Add a newcomer: it reuses blank slot 2 (leaf index 1) and must be listed
        // unmerged at every non-blank ancestor — those secrets predate it.
        let new_secret = secret("newcomer", 9);
        let ln = leaf_node_for(GID, &new_secret, &cred(9));
        let idx = add_leaf(&mut tree, ln).unwrap();
        assert_eq!(idx, 1, "first blank leaf slot must be reused deterministically");
        match &tree.slots[3] {
            TreeSlot::Parent(p) => assert_eq!(p.unmerged_leaves, vec![1], "unmerged at node 3"),
            _ => panic!("node 3 must be populated"),
        }
        match &tree.slots[7] {
            TreeSlot::Parent(p) => assert_eq!(p.unmerged_leaves, vec![1], "unmerged at node 7"),
            _ => panic!("node 7 must be populated"),
        }
        privs.insert(1, TreePrivate::new(1, new_secret));

        // Epoch 4: leaf 4 (far side) commits. At the root, the copath child is node 3,
        // whose resolution is [node 3, unmerged leaf slot 2] — the newcomer must be
        // addressed DIRECTLY while old members decrypt via node 3.
        let b4 = commit_path(&mut tree, &mut privs, 4, 4);
        let root_cts: Vec<u32> = b4
            .update_path
            .nodes
            .last()
            .unwrap()
            .ciphertexts
            .iter()
            .map(|c| c.resolution_index)
            .collect();
        assert!(root_cts.contains(&3), "old members are reached via interior node 3");
        assert!(root_cts.contains(&2), "the unmerged newcomer is addressed at its leaf");
        // A fresh path through the newcomer's side clears the unmerged lists it re-keys.
        commit_path(&mut tree, &mut privs, 1, 5);
        if let TreeSlot::Parent(p) = &tree.slots[3] {
            assert!(p.unmerged_leaves.is_empty(), "re-keyed node must clear unmerged");
        } else {
            panic!("node 3 must be populated");
        }
    }

    /// §9 M1 proof obligation: after Remove+Commit, the removed leaf's key material opens
    /// NOTHING in the new UpdatePath — asserted at every ciphertext with every key the
    /// removed device ever held (leaf key and all interior-node secrets, current or stale).
    #[test]
    fn removed_leaf_cannot_decrypt_any_path_secret() {
        let secrets: Vec<[u8; 32]> = (0..4).map(|i| secret("leaf", i)).collect();
        let mut tree = RatchetTree::from_leaves(
            (0..4).map(|i| leaf_node_for(GID, &secrets[i], &cred(i))).collect(),
        );
        let mut privs: Vec<TreePrivate> =
            (0..4).map(|i| TreePrivate::new(i as u32, secrets[i])).collect();

        // Epoch 1 (leaf 0) and epoch 2 (leaf 2) populate the tree so leaf 3 holds real
        // interior secrets — the strongest state a removed member could hoard.
        for (sender, epoch) in [(0u32, 1u64), (2, 2)] {
            let new = secret("upd", epoch as usize);
            let b = build_update_path(&tree, GID, epoch, sender, &new, &cred(sender as usize), fake_sig, &secret("ent", epoch as usize))
                .unwrap();
            for (i, p) in privs.iter_mut().enumerate() {
                if i as u32 == sender {
                    p.leaf_secret = new;
                    p.path_secrets = b.path_secrets.clone();
                } else {
                    let d = decrypt_update_path(&tree, GID, epoch, sender, &b.update_path, p).unwrap();
                    p.path_secrets.extend(d.path_secrets);
                }
            }
            merge_update_path(&mut tree, sender, &b.update_path).unwrap();
        }
        assert!(!privs[3].path_secrets.is_empty(), "leaf 3 must hold interior secrets");

        // Leaf 1 removes leaf 3 and commits epoch 3 on the post-removal tree.
        remove_leaf(&mut tree, 3).unwrap();
        let b = build_update_path(&tree, GID, 3, 1, &secret("upd", 3), &cred(1), fake_sig, &secret("ent", 3))
            .unwrap();

        // The removed member's structured decryption fails…
        assert!(
            decrypt_update_path(&tree, GID, 3, 1, &b.update_path, &privs[3]).is_err(),
            "removed leaf must not decrypt the update path"
        );
        // …and so does brute force: every ciphertext, tried with its leaf key and with a
        // node key derived from EVERY path secret it ever learned (including stale ones
        // for since-blanked nodes) — decryption must fail at every node it could try.
        let mut keys: Vec<NodeKeypair> = vec![privs[3].leaf_keypair()];
        for s in privs[3].path_secrets.values() {
            keys.push(node_keypair_from_path_secret(s));
        }
        let mut attempts = 0;
        for node in &b.update_path.nodes {
            for ct in &node.ciphertexts {
                for kp in &keys {
                    assert!(
                        open_path_secret(kp, GID, 3, ct).is_err(),
                        "removed leaf key material opened a path secret"
                    );
                    attempts += 1;
                }
            }
        }
        assert!(attempts > 0, "the brute-force sweep must actually try something");
        // Control: a surviving member still decrypts (the failure above is exclusion,
        // not a broken path).
        assert!(decrypt_update_path(&tree, GID, 3, 1, &b.update_path, &privs[0]).is_ok());
    }

    // ── Epoch schedule ───────────────────────────────────────────────────────────────────

    /// §9 M1 proof obligation: the schedule is one-way. The consumed inputs are wiped in
    /// place by `advance_epoch` itself (deleted fields actually gone), the returned struct
    /// carries no field for them, and re-deriving with fresh copies is deterministic.
    #[test]
    fn epoch_schedule_is_one_way_and_wipes_consumed_inputs() {
        let ctx = epoch_context(GID, 1, &[1; 32], &[2; 32]);
        let mut init = [7u8; 32];
        let mut cs = [9u8; 32];
        let s1 = advance_epoch(&mut init, &mut cs, &ctx);
        // §6.2: init_secret_{n-1} and commit_secret are consumed — and provably zeroed.
        assert_eq!(init, [0u8; 32], "previous init secret must be wiped");
        assert_eq!(cs, [0u8; 32], "commit secret must be wiped");
        for f in [s1.epoch_secret, s1.init_secret, s1.sender_root, s1.confirm_key, s1.welcome_key, s1.joiner_secret] {
            assert_ne!(f, [0u8; 32], "derived secrets must be populated");
        }
        // Deterministic: fresh copies of the same inputs give the identical schedule.
        let (mut i2, mut c2) = ([7u8; 32], [9u8; 32]);
        let s2 = advance_epoch(&mut i2, &mut c2, &ctx);
        assert_eq!(s1.epoch_secret, s2.epoch_secret);
        assert_eq!(s1.init_secret, s2.init_secret);
        assert_eq!(s1.sender_root, s2.sender_root);
        assert_eq!(s1.confirm_key, s2.confirm_key);
        assert_eq!(s1.welcome_key, s2.welcome_key);
        assert_eq!(s1.joiner_secret, s2.joiner_secret);
        // Advance to epoch 2: nothing in the new state reproduces epoch 1's secrets, and
        // the only backward-pointing value (the consumed init) is gone.
        let ctx2 = epoch_context(GID, 2, &[1; 32], &[2; 32]);
        let mut i3 = s1.init_secret;
        let mut c3 = [5u8; 32];
        let s3 = advance_epoch(&mut i3, &mut c3, &ctx2);
        assert_eq!(i3, [0u8; 32], "epoch 1's init secret is consumed by epoch 2");
        for f in [s3.epoch_secret, s3.init_secret, s3.sender_root, s3.confirm_key, s3.welcome_key, s3.joiner_secret] {
            assert_ne!(f, s1.epoch_secret, "epoch 1 secrets must not appear in epoch 2 state");
            assert_ne!(f, s1.sender_root);
            assert_ne!(f, s1.joiner_secret);
        }
        // A Welcome recipient lands on the identical schedule from just the joiner secret.
        let sj = epoch_from_joiner(&s1.joiner_secret, &ctx);
        assert_eq!(sj.epoch_secret, s1.epoch_secret);
        assert_eq!(sj.init_secret, s1.init_secret);
    }

    #[test]
    fn sender_keys_are_leaf_and_epoch_scoped() {
        let root = [3u8; 32];
        let a = sender_key(&root, &[1; 32], GID, 4);
        assert_eq!(a, sender_key(&root, &[1; 32], GID, 4), "deterministic");
        assert_ne!(a, sender_key(&root, &[2; 32], GID, 4), "sibling devices get distinct keys");
        assert_ne!(a, sender_key(&root, &[1; 32], GID, 5), "epoch-scoped");
        assert_ne!(a, sender_key(&root, &[1; 32], b"other", 4), "group-scoped");
    }

    // ── M5: PCS + the §6.3 forward-secrecy proof obligations ─────────────────────────────

    /// §9 M5 — THE PCS TEST (§6.4). Exfiltrate a device's FULL epoch-1 deriving state, then take two
    /// futures: (A) D issues a LEAF UPDATE, or (B) the epoch advances WITHOUT one (an add-only
    /// commit). The stolen state opens NOTHING at epoch 2 in (A) — the fresh leaf secret it lacks is
    /// what heals — but DOES open epoch 2 in (B). Both futures share the identical stolen `init_1`;
    /// the ONLY difference is whether the advance mixed a fresh, attacker-unknown `commit_secret` —
    /// which is exactly the teeth the obligation demands.
    #[test]
    fn pcs_leaf_update_heals_epoch_n_plus_1_and_the_test_has_teeth() {
        // Genesis at epoch 1: 3 devices, add-only (commit_secret = 0). Member 0 = the victim D.
        let devs = 3usize;
        let lsec: Vec<[u8; 32]> = (0..devs).map(|i| secret("pcs-leaf", i)).collect();
        let adds: Vec<Proposal> = (0..devs)
            .map(|i| build_add_proposal(GID, 1, 0, leaf_node_for(GID, &lsec[i], &cred(i)), fake_sig))
            .collect();
        let g_init = secret("pcs-init", 0);
        let g_cth = secret("pcs-cth", 0);
        let g_parent = secret("pcs-parent", 0);
        let genesis = super::build_commit(
            &RatchetTree { slots: vec![] }, GID, 1, g_parent, &g_cth, &g_init, 0, adds, None, fake_sig, fake_sig,
        )
        .unwrap();
        let tree1 = genesis.tree.clone();
        let cth1 = genesis.confirmed_transcript_hash;
        let tip1 = commit_hash(&genesis.commit.to_bytes());
        // The FULL epoch-1 deriving state the attacker exfiltrates from D: `init_secret_1` (the salt
        // feeding epoch 2) plus D's private tree state and the public epoch-1 facts.
        let stolen_init_1 = genesis.schedule.init_secret;
        let d_leaf_secret_1 = lsec[0];
        let acct = *blake3::hash(b"pcs-acct").as_bytes();

        // ── FUTURE A — D issues a LEAF UPDATE (no proposals, fresh path). The healing move. ──
        let fresh_leaf = secret("pcs-fresh", 0); // entropy NOT in the stolen state (D's device-seed lane)
        let ent_a = secret("pcs-ent-a", 0);
        let build_a = super::build_commit(
            &tree1, GID, 2, tip1, &cth1, &stolen_init_1, 0, vec![],
            Some((&fresh_leaf, &cred(0), &ent_a)), fake_sig, fake_sig,
        )
        .unwrap();
        let real_root_2a = build_a.schedule.sender_root;
        let real_key_2a = sender_key(&real_root_2a, &acct, GID, 2);
        // Honest members 1 & 2 DO converge on the healed epoch (the circle keeps working through it).
        for m in [1usize, 2] {
            let mp = TreePrivate::new(m as u32, lsec[m]);
            let a = apply_commit(&tree1, GID, &cth1, &stolen_init_1, &build_a.commit, Some(&mp)).unwrap();
            assert_eq!(
                a.schedule.expect("member derives the healed epoch").sender_root, real_root_2a,
                "member {m} converges on D's healed epoch",
            );
        }
        // The ATTACKER, holding only the stolen epoch-1 state, cannot reach epoch 2's sender_root:
        // every commit_secret it can form from that state (the public add-only zero; or any 32 bytes
        // it holds — the stolen init, D's OLD leaf secret) advances the SAME public context to a
        // DIFFERENT root, because the real advance consumed the fresh secret only D could make.
        let ctx_2a = epoch_context(GID, 2, &tree_hash(&build_a.tree), &build_a.confirmed_transcript_hash);
        for guess in [[0u8; 32], stolen_init_1, d_leaf_secret_1] {
            let (mut i, mut g) = (stolen_init_1, guess);
            let s = advance_epoch(&mut i, &mut g, &ctx_2a);
            assert_ne!(s.sender_root, real_root_2a, "stolen state must NOT reconstruct the healed sender_root");
            assert_ne!(
                sender_key(&s.sender_root, &acct, GID, 2), real_key_2a,
                "stolen epoch-1 state opens NOTHING at epoch 2 once D updates",
            );
        }

        // ── FUTURE B (the teeth) — the SAME stolen init advances via an ADD-ONLY commit
        // (commit_secret = 0, PUBLIC). Here the stolen state DOES reach epoch 2: `init_secret_1` plus
        // the public zero is all it takes. Absent a fresh leaf Update, the exfiltration still reads
        // n+1 — proving FUTURE A's failure is the Update healing, not a rigged setup. ──
        let newcomer = leaf_node_for(GID, &secret("pcs-add", 0), &cred(9));
        let add = build_add_proposal(GID, 2, 0, newcomer, fake_sig);
        let build_b = super::build_commit(&tree1, GID, 2, tip1, &cth1, &stolen_init_1, 0, vec![add], None, fake_sig, fake_sig)
            .unwrap();
        let real_root_2b = build_b.schedule.sender_root;
        let ctx_2b = epoch_context(GID, 2, &tree_hash(&build_b.tree), &build_b.confirmed_transcript_hash);
        let (mut i, mut z) = (stolen_init_1, [0u8; 32]);
        let s = advance_epoch(&mut i, &mut z, &ctx_2b);
        assert_eq!(s.sender_root, real_root_2b, "WITHOUT a fresh Update the stolen state reproduces epoch 2");
        assert_eq!(
            sender_key(&s.sender_root, &acct, GID, 2), sender_key(&real_root_2b, &acct, GID, 2),
            "and opens epoch 2's content key — the test has teeth",
        );
    }

    /// §9 M5 / §6.3-1 — a serialized `PersistTree` carries NO consumed secret. `commit_secret` and
    /// `init_secret` have no field in the type (a state-blob backup must not fossilize the backward
    /// link); this serializes post-commit state and byte-scans: both consumed secrets ABSENT, while a
    /// legitimately RETAINED secret is present (so the negative asserts are not vacuous).
    #[test]
    fn fs_bug_1_persist_tree_carries_no_consumed_secret() {
        let lsec: Vec<[u8; 32]> = (0..2).map(|i| secret("b1-leaf", i)).collect();
        let tree1 = RatchetTree::from_leaves((0..2).map(|i| leaf_node_for(GID, &lsec[i], &cred(i))).collect());
        let init_1 = secret("b1-init", 0); // consumed as salt by the epoch-2 advance
        let cth1 = secret("b1-cth", 0);
        let fresh = secret("b1-fresh", 0);
        let ent = secret("b1-ent", 0);
        // Learn the EXACT commit_secret the advance consumes by building the same update path.
        let upb = build_update_path(&tree1, GID, 2, 0, &fresh, &cred(0), fake_sig, &ent).unwrap();
        let known_commit_secret = upb.commit_secret;
        let build = super::build_commit(
            &tree1, GID, 2, secret("b1-parent", 0), &cth1, &init_1, 0, vec![],
            Some((&fresh, &cred(0), &ent)), fake_sig, fake_sig,
        )
        .unwrap();
        let epoch_secret_2 = build.schedule.epoch_secret;
        let pt = PersistTree {
            group_id: GID.to_vec(),
            commit_chain: vec![(commit_hash(&build.commit.to_bytes()), build.commit.to_bytes())],
            tree_blob_ref: vec![],
            tree_bytes: build.tree.to_bytes(),
            my_leaf_index: 0,
            my_leaf_secret: fresh,
            my_path_secrets: build.my_private.path_secrets.values().copied().collect(),
            fork_cache: vec![],
            epoch_secrets: vec![(2, epoch_secret_2)],
        };
        let blob = pt.to_bytes();
        let contains = |needle: &[u8; 32]| blob.windows(32).any(|w| w == needle);
        // Sanity — the scan CAN find a retained secret (else the negatives below are vacuous).
        assert!(contains(&fresh), "the current leaf secret is legitimately in the blob");
        assert!(contains(&epoch_secret_2), "the retained epoch secret is in the blob");
        // The proof — consumed secrets are ABSENT from the persisted bytes (§6.3-1).
        assert!(!contains(&init_1), "the consumed init_secret must never fossilize in the blob");
        assert!(!contains(&known_commit_secret), "the consumed commit_secret must never fossilize in the blob");
    }

    /// §9 M5 / §6.3-2 — the fork cache ages out on the pruner, WIPING losing-fork keys. Build a
    /// `PersistTree` spanning 6 epochs with fork caches below and within the KEEP_EPOCHS window;
    /// prune; assert the window is 4, out-of-window forks are gone, in-window forks are capped at
    /// KEEP_FORKS, the chain is bounded, and a re-serialization no longer contains an aged-out fork's
    /// distinctive sender key.
    #[test]
    fn fs_bug_2_fork_cache_ages_out_on_the_pruner() {
        let dead_key = [0xABu8; 32]; // a distinctive aged-out fork key we can byte-scan for
        let mut pt = PersistTree {
            group_id: GID.to_vec(),
            commit_chain: (1..=6u64).map(|e| ([e as u8; 32], vec![e as u8; 8])).collect(),
            tree_blob_ref: vec![],
            tree_bytes: vec![],
            my_leaf_index: 0,
            my_leaf_secret: [1u8; 32],
            my_path_secrets: vec![],
            fork_cache: vec![
                // epochs 1 & 2: OUTSIDE the retained window (keeps 3..=6) ⇒ wiped + dropped.
                ForkCacheEntry { epoch: 1, commit_hash: [1u8; 32], sender_keys: vec![([9u8; 32], dead_key)] },
                ForkCacheEntry { epoch: 2, commit_hash: [2u8; 32], sender_keys: vec![([8u8; 32], [0xCDu8; 32])] },
                // epoch 5: FOUR forks ⇒ capped to KEEP_FORKS = 2 (largest commit_hash kept).
                ForkCacheEntry { epoch: 5, commit_hash: [0x10u8; 32], sender_keys: vec![([1u8; 32], [0x51u8; 32])] },
                ForkCacheEntry { epoch: 5, commit_hash: [0x20u8; 32], sender_keys: vec![([2u8; 32], [0x52u8; 32])] },
                ForkCacheEntry { epoch: 5, commit_hash: [0x30u8; 32], sender_keys: vec![([3u8; 32], [0x53u8; 32])] },
                ForkCacheEntry { epoch: 5, commit_hash: [0x40u8; 32], sender_keys: vec![([4u8; 32], [0x54u8; 32])] },
            ],
            epoch_secrets: (1..=6u64).map(|e| (e, [e as u8; 32])).collect(),
        };
        pt.prune();
        let mut kept: Vec<u64> = pt.epoch_secrets.iter().map(|(e, _)| *e).collect();
        kept.sort_unstable();
        assert_eq!(kept, vec![3, 4, 5, 6], "epoch secrets kept to the 4-epoch window");
        assert!(pt.fork_cache.iter().all(|f| f.epoch >= 3), "out-of-window forks aged out");
        let e5: Vec<[u8; 32]> = pt.fork_cache.iter().filter(|f| f.epoch == 5).map(|f| f.commit_hash).collect();
        assert_eq!(e5.len(), PersistTree::KEEP_FORKS, "epoch-5 forks capped to KEEP_FORKS");
        assert!(e5.contains(&[0x40u8; 32]) && e5.contains(&[0x30u8; 32]), "the two largest-hash forks are kept");
        assert_eq!(pt.commit_chain.len(), PersistTree::KEEP_EPOCHS, "commit chain bounded to the window");
        let blob = pt.to_bytes();
        assert!(
            !blob.windows(32).any(|w| w == dead_key),
            "the aged-out fork's sender key is wiped, not lingering in the re-serialized blob",
        );
    }

    // ── Fork tie-break + chain rule (§5.1) ───────────────────────────────────────────────

    fn bare_commit(parent: [u8; 32], epoch: u64, salt: u8) -> Vec<u8> {
        Commit {
            group_id: GID.to_vec(),
            epoch,
            parent_commit_hash: parent,
            proposals: vec![],
            update_path: None,
            tree_hash: [salt; 32],
            confirmation_mac: vec![salt],
            sender_leaf: 0,
            sig: vec![salt, 1],
        }
        .to_bytes()
    }

    #[test]
    fn fork_tiebreak_is_total_and_larger_hash_wins() {
        let genesis = [0xAA; 32];
        let a = bare_commit(genesis, 1, 1);
        let b = bare_commit(genesis, 1, 2);
        assert_eq!(compare_commits(&a, &a), Ordering::Equal);
        let ab = compare_commits(&a, &b);
        assert_ne!(ab, Ordering::Equal, "distinct bytes give distinct hashes");
        assert_eq!(compare_commits(&b, &a), ab.reverse(), "comparator is antisymmetric");
        // The winner is exactly the lexicographically larger blake3 hash.
        let winner_is_a = commit_hash(&a) > commit_hash(&b);
        assert_eq!(ab == Ordering::Greater, winner_is_a);
        // Equal-length candidate chains: select_chain picks the larger tip hash.
        let cands = vec![vec![a.clone()], vec![b.clone()]];
        let want = if winner_is_a { 0 } else { 1 };
        assert_eq!(select_chain(&genesis, 1, GID, &cands), Some(want));
    }

    #[test]
    fn chain_rule_longest_valid_beats_tip_hash_and_invalid_chains_are_skipped() {
        let genesis = [0xAB; 32];
        let a = bare_commit(genesis, 1, 1);
        let b = bare_commit(genesis, 1, 2);
        // Extend the tie-break LOSER by one commit: length must beat hash order.
        let (loser, winner) = if commit_hash(&a) > commit_hash(&b) { (b.clone(), a.clone()) } else { (a.clone(), b.clone()) };
        let child = bare_commit(commit_hash(&loser), 2, 3);
        let cands = vec![vec![winner.clone()], vec![loser.clone(), child.clone()]];
        assert_eq!(select_chain(&genesis, 1, GID, &cands), Some(1), "longest valid chain wins");
        // Validation: broken parent link, wrong epoch, wrong group are each fatal.
        assert!(validate_chain(&genesis, 1, GID, &[loser.clone(), child.clone()]).is_ok());
        assert!(validate_chain(&genesis, 1, GID, &[winner.clone(), child.clone()]).is_err(), "parent hash mismatch");
        assert!(validate_chain(&genesis, 2, GID, &[loser.clone()]).is_err(), "wrong first epoch");
        assert!(validate_chain(&genesis, 1, b"other", &[loser.clone()]).is_err(), "wrong group");
        // An invalid (unlinked) longer chain cannot veto a valid shorter one.
        let forged = vec![bare_commit([9; 32], 1, 7), bare_commit([8; 32], 2, 8), bare_commit([7; 32], 3, 9)];
        let cands2 = vec![forged, vec![winner]];
        assert_eq!(select_chain(&genesis, 1, GID, &cands2), Some(1));
        // No valid candidate → None (never a guess).
        assert_eq!(select_chain(&genesis, 1, GID, &[vec![bare_commit([1; 32], 1, 1)]]), None);
        assert_eq!(select_chain(&genesis, 1, GID, &[]), None);
    }

    // ── Committed test vectors (§9 M1) ───────────────────────────────────────────────────

    /// Fixed seeds → exact expected bytes, asserted byte-for-byte: any change to a label,
    /// a derivation, the serialization, or a dependency's deterministic keygen SCREAMS
    /// here instead of silently forking the fleet. Values were computed by this code once
    /// and frozen; they are the wire contract now.
    #[test]
    fn committed_test_vectors_pin_tree_hash_epoch_secret_and_sender_key() {
        let gid = b"haven-treekem-vector-v1";
        let leaf_secrets: [[u8; 32]; 4] = [[0x11; 32], [0x22; 32], [0x33; 32], [0x44; 32]];
        let tree0 = RatchetTree::from_leaves(
            (0..4).map(|i| leaf_node_for(gid, &leaf_secrets[i], format!("cred-{i}").as_bytes())).collect(),
        );
        assert_eq!(
            hex::encode(tree_hash(&tree0)),
            "c4d3e9d50a159c4cdd573c5f3c7b76b528296f14347c0747885f2f65faef8d5f",
            "genesis tree hash"
        );
        let b = build_update_path(&tree0, gid, 1, 0, &[0x55; 32], b"cred-0", fake_sig, &[0x66; 32]).unwrap();
        assert_eq!(
            hex::encode(b.commit_secret),
            "fbdd08cf40efa6a6f90798ec71ead8bb3336f4a26969bffd494f22a2e86d29a0",
            "commit secret"
        );
        // A receiver derives the identical commit secret from the wire bytes alone.
        let wire = UpdatePath::from_bytes(&b.update_path.to_bytes()).unwrap();
        let d = decrypt_update_path(&tree0, gid, 1, 0, &wire, &TreePrivate::new(1, leaf_secrets[1])).unwrap();
        assert_eq!(d.commit_secret, b.commit_secret);
        let mut tree1 = tree0.clone();
        merge_update_path(&mut tree1, 0, &b.update_path).unwrap();
        assert_eq!(
            hex::encode(tree_hash(&tree1)),
            "dabde6cc54df493b9ff634ddd4539c94a384879a3101877a8cb42cd816631eed",
            "post-merge tree hash"
        );
        let ctx = epoch_context(gid, 1, &tree_hash(&tree1), &[0xAB; 32]);
        let mut init = [0x01; 32];
        let mut cs = b.commit_secret;
        let s = advance_epoch(&mut init, &mut cs, &ctx);
        assert_eq!(
            hex::encode(s.epoch_secret),
            "42e82ca94225b46b5d9668aef56f90354f96b21591287017e5b090f235d977bd",
            "epoch secret"
        );
        assert_eq!(
            hex::encode(sender_key(&s.sender_root, &[0xCD; 32], gid, 1)),
            "febc663bda295f62c8f6d5fae782b00a89bd106f663f65f3b5d114b4bf422859",
            "sender key"
        );
    }

    // ── Convergence property test (§9 M1) ────────────────────────────────────────────────
    //
    // N replicas, a seeded randomized schedule of add/remove/update commits, random
    // delivery orders with partitions, redelivery, and guaranteed forks. At quiescence
    // every replica that is a member computes the identical winning chain, tree hash, and
    // epoch secret — from PURE replay of the same commit set, which is exactly the
    // determinism M2's shadow mode will lean on. All entropy flows from the fixed seed:
    // failures reproduce byte-for-byte.

    const POOL: usize = 5;
    const GENESIS_MEMBERS: usize = 4;

    struct WelcomeRec {
        member: usize,
        leaf_secret: [u8; 32],
        joiner_secret: [u8; 32],
    }

    struct BuildRec {
        author: usize,
        leaf_secret: [u8; 32],
        entropy: [u8; 32],
    }

    struct World {
        commits: BTreeMap<[u8; 32], Vec<u8>>,
        welcomes: BTreeMap<[u8; 32], WelcomeRec>,
        builds: BTreeMap<[u8; 32], BuildRec>,
        genesis_tree: RatchetTree,
        genesis_hash: [u8; 32],
        genesis_init: [u8; 32],
        genesis_cth: [u8; 32],
    }

    struct View {
        tree: RatchetTree,
        epoch: u64,
        tip: [u8; 32],
        cth: [u8; 32],
        init: [u8; 32],
        me: Option<TreePrivate>,
        sched: Option<EpochSchedule>,
    }

    fn genesis_leaf_secret(member: usize) -> [u8; 32] {
        secret("genesis-leaf", member)
    }

    /// Pure replay of a commit chain from genesis at one member's vantage. Stateless by
    /// design: replicas converge because replay is a pure function of (chain, member),
    /// not because incremental state happened to line up.
    fn replay(world: &World, member: usize, chain: &[Vec<u8>]) -> View {
        let mut tree = world.genesis_tree.clone();
        let mut cth = world.genesis_cth;
        let mut init = world.genesis_init;
        let mut me = if member < GENESIS_MEMBERS {
            Some(TreePrivate::new(member as u32, genesis_leaf_secret(member)))
        } else {
            None
        };
        let mut sched: Option<EpochSchedule> = None;
        let mut epoch = 0u64;
        let mut tip = world.genesis_hash;
        for bytes in chain {
            let commit = Commit::from_bytes(bytes).unwrap();
            let h = commit_hash(bytes);
            let mut joined_now = false;
            for p in &commit.proposals {
                match &p.body {
                    ProposalBody::Add { leaf_node } => {
                        let idx = add_leaf(&mut tree, leaf_node.clone()).unwrap();
                        if let Some(w) = world.welcomes.get(&h) {
                            if w.member == member {
                                me = Some(TreePrivate::new(idx, w.leaf_secret));
                                joined_now = true;
                            }
                        }
                    }
                    ProposalBody::Remove { leaf_index } => {
                        remove_leaf(&mut tree, *leaf_index).unwrap();
                        if me.as_ref().map(|m| m.leaf_index) == Some(*leaf_index) {
                            me = None;
                            sched = None;
                        }
                    }
                    ProposalBody::Update { .. } => unreachable!("sim commits carry paths, not update proposals"),
                }
            }
            // Deletion discipline: secrets for nodes blanked by the proposals are dead.
            if let Some(m) = &mut me {
                let t = &tree;
                m.path_secrets.retain(|&ix, _| {
                    matches!(t.slots.get(ix as usize), Some(TreeSlot::Parent(pn)) if !pn.blank)
                });
            }
            let up = commit.update_path.as_ref().expect("sim commits always carry a path");
            let mut new_secrets = BTreeMap::new();
            let mut commit_secret: Option<[u8; 32]> = None;
            let authored = world.builds.get(&h).map(|b| b.author) == Some(member);
            if authored {
                let b = &world.builds[&h];
                let built = build_update_path(&tree, GID, commit.epoch, commit.sender_leaf, &b.leaf_secret, &cred(member), fake_sig, &b.entropy)
                    .unwrap();
                assert_eq!(built.update_path, *up, "deterministic rebuild must reproduce the committed path");
                let m = me.as_mut().expect("author is a member on its own branch");
                m.leaf_secret = b.leaf_secret;
                m.path_secrets.clear();
                new_secrets = built.path_secrets;
                commit_secret = Some(built.commit_secret);
            } else if let Some(m) = &me {
                let d = decrypt_update_path(&tree, GID, commit.epoch, commit.sender_leaf, up, m).unwrap();
                new_secrets = d.path_secrets;
                commit_secret = Some(d.commit_secret);
            }
            merge_update_path(&mut tree, commit.sender_leaf, up).unwrap();
            let th = tree_hash(&tree);
            assert_eq!(th, commit.tree_hash, "replica tree must match the committed tree hash");
            cth = next_confirmed_transcript_hash(&cth, &commit);
            if let Some(m) = &mut me {
                let ctx = epoch_context(GID, commit.epoch, &th, &cth);
                let s = if joined_now {
                    // The Welcome rail: a joiner has no init_{n-1}; it gets joiner_secret.
                    epoch_from_joiner(&world.welcomes[&h].joiner_secret, &ctx)
                } else {
                    let mut cs = commit_secret.expect("active member derived a commit secret");
                    advance_epoch(&mut init, &mut cs, &ctx)
                };
                // Agreeing on the MAC proves agreement on the entire derivation.
                assert_eq!(
                    &confirmation_mac(&s.confirm_key, &cth)[..],
                    &commit.confirmation_mac[..],
                    "confirmation MAC must verify"
                );
                init = s.init_secret;
                m.path_secrets.extend(new_secrets);
                sched = Some(s);
            }
            epoch = commit.epoch;
            tip = h;
        }
        View { tree, epoch, tip, cth, init, me, sched }
    }

    /// Enumerate every maximal chain from genesis among the known commits and pick the
    /// §5.1 winner via `select_chain`.
    fn best_chain(world: &World, known: &BTreeMap<[u8; 32], Vec<u8>>) -> Vec<Vec<u8>> {
        let mut children: BTreeMap<[u8; 32], Vec<[u8; 32]>> = BTreeMap::new();
        for (h, bytes) in known {
            let c = Commit::from_bytes(bytes).unwrap();
            children.entry(c.parent_commit_hash).or_default().push(*h);
        }
        fn dfs(
            cur: [u8; 32],
            path: &mut Vec<[u8; 32]>,
            children: &BTreeMap<[u8; 32], Vec<[u8; 32]>>,
            out: &mut Vec<Vec<[u8; 32]>>,
        ) {
            match children.get(&cur) {
                None => {
                    if !path.is_empty() {
                        out.push(path.clone());
                    }
                }
                Some(kids) => {
                    for k in kids {
                        path.push(*k);
                        dfs(*k, path, children, out);
                        path.pop();
                    }
                }
            }
        }
        let mut chains = Vec::new();
        dfs(world.genesis_hash, &mut Vec::new(), &children, &mut chains);
        let candidates: Vec<Vec<Vec<u8>>> = chains
            .iter()
            .map(|hs| hs.iter().map(|h| known[h].clone()).collect())
            .collect();
        match select_chain(&world.genesis_hash, 1, GID, &candidates) {
            Some(i) => candidates[i].clone(),
            None => Vec::new(),
        }
    }

    fn rand32(rng: &mut ChaCha20Rng) -> [u8; 32] {
        let mut b = [0u8; 32];
        rng.fill_bytes(&mut b);
        b
    }

    /// One member builds a commit on its current best tip: a random valid op (update /
    /// remove / add) plus its UpdatePath, schedule, MAC. Returns the commit hash.
    fn build_commit(
        world: &mut World,
        rng: &mut ChaCha20Rng,
        author: usize,
        known: &BTreeMap<[u8; 32], Vec<u8>>,
    ) -> Option<[u8; 32]> {
        let chain = best_chain(world, known);
        let view = replay(world, author, &chain);
        let me = view.me?;
        let mut present: Vec<(usize, u32)> = Vec::new();
        for li in 0..view.tree.n_leaves() {
            if let Some(l) = view.tree.leaf(li as u32) {
                present.push((member_from_cred(&l.device_credential), li as u32));
            }
        }
        let mut proposals = Vec::new();
        let mut tree2 = view.tree.clone();
        let mut welcome: Option<(usize, [u8; 32])> = None;
        match rng.gen_range(0u8..3) {
            1 if present.len() > 2 => {
                let others: Vec<(usize, u32)> =
                    present.iter().copied().filter(|(m, _)| *m != author).collect();
                let (_, target_leaf) = others[rng.gen_range(0..others.len())];
                proposals.push(Proposal {
                    group_id: GID.to_vec(),
                    epoch: view.epoch,
                    body: ProposalBody::Remove { leaf_index: target_leaf },
                    sender_leaf: me.leaf_index,
                    sig: fake_sig(b"remove"),
                });
                remove_leaf(&mut tree2, target_leaf).unwrap();
            }
            2 => {
                let absent: Vec<usize> =
                    (0..POOL).filter(|m| !present.iter().any(|(pm, _)| pm == m)).collect();
                if !absent.is_empty() {
                    let joiner = absent[rng.gen_range(0..absent.len())];
                    let jls = rand32(rng);
                    let ln = leaf_node_for(GID, &jls, &cred(joiner));
                    proposals.push(Proposal {
                        group_id: GID.to_vec(),
                        epoch: view.epoch,
                        body: ProposalBody::Add { leaf_node: ln.clone() },
                        sender_leaf: me.leaf_index,
                        sig: fake_sig(b"add"),
                    });
                    add_leaf(&mut tree2, ln).unwrap();
                    welcome = Some((joiner, jls));
                }
            }
            _ => {}
        }
        let new_ls = rand32(rng);
        let entropy = rand32(rng);
        let built = build_update_path(&tree2, GID, view.epoch + 1, me.leaf_index, &new_ls, &cred(author), fake_sig, &entropy)
            .unwrap();
        let mut tree3 = tree2.clone();
        merge_update_path(&mut tree3, me.leaf_index, &built.update_path).unwrap();
        let th = tree_hash(&tree3);
        let mut c = Commit {
            group_id: GID.to_vec(),
            epoch: view.epoch + 1,
            parent_commit_hash: view.tip,
            proposals,
            update_path: Some(built.update_path),
            tree_hash: th,
            confirmation_mac: Vec::new(),
            sender_leaf: me.leaf_index,
            sig: Vec::new(),
        };
        // The transcript hash covers commit CONTENT (mac/sig blanked), so computing it
        // before the MAC is set is not circular — same value the receivers compute.
        let cth = next_confirmed_transcript_hash(&view.cth, &c);
        let ctx = epoch_context(GID, c.epoch, &th, &cth);
        let mut init = view.init;
        let mut cs = built.commit_secret;
        let sched = advance_epoch(&mut init, &mut cs, &ctx);
        c.confirmation_mac = confirmation_mac(&sched.confirm_key, &cth).to_vec();
        c.sig = fake_sig(&c.to_bytes());
        let bytes = c.to_bytes();
        let h = commit_hash(&bytes);
        world.commits.insert(h, bytes);
        world.builds.insert(h, BuildRec { author, leaf_secret: new_ls, entropy });
        if let Some((joiner, jls)) = welcome {
            world.welcomes.insert(h, WelcomeRec { member: joiner, leaf_secret: jls, joiner_secret: sched.joiner_secret });
        }
        Some(h)
    }

    fn run_convergence_sim(seed: u64, steps: usize) {
        let mut rng = ChaCha20Rng::seed_from_u64(seed);
        let world_tree = RatchetTree::from_leaves(
            (0..GENESIS_MEMBERS).map(|i| leaf_node_for(GID, &genesis_leaf_secret(i), &cred(i))).collect(),
        );
        let mut world = World {
            commits: BTreeMap::new(),
            welcomes: BTreeMap::new(),
            builds: BTreeMap::new(),
            genesis_tree: world_tree,
            genesis_hash: *blake3::hash(b"m1-sim-genesis").as_bytes(),
            genesis_init: *blake3::hash(b"m1-sim-genesis-init").as_bytes(),
            genesis_cth: *blake3::hash(b"m1-sim-genesis-cth").as_bytes(),
        };
        struct Replica {
            known: BTreeMap<[u8; 32], Vec<u8>>,
            inbox: Vec<[u8; 32]>,
        }
        let mut replicas: Vec<Replica> = (0..POOL).map(|_| Replica { known: BTreeMap::new(), inbox: Vec::new() }).collect();
        let mut partitioned = vec![false; POOL];

        let publish = |world: &World, replicas: &mut Vec<Replica>, author: usize, h: [u8; 32]| {
            replicas[author].known.insert(h, world.commits[&h].clone());
            for (r, rep) in replicas.iter_mut().enumerate() {
                if r != author {
                    rep.inbox.push(h);
                }
            }
        };

        // Force a fork immediately: two genesis members commit with the same parent
        // before any delivery — the §5 weather, guaranteed, every run.
        for a in [0usize, 1] {
            let known = replicas[a].known.clone();
            let h = build_commit(&mut world, &mut rng, a, &known).expect("genesis member can commit");
            publish(&world, &mut replicas, a, h);
        }

        for _ in 0..steps {
            match rng.gen_range(0u8..10) {
                0..=2 => {
                    let a = rng.gen_range(0..POOL);
                    let known = replicas[a].known.clone();
                    if let Some(h) = build_commit(&mut world, &mut rng, a, &known) {
                        publish(&world, &mut replicas, a, h);
                    }
                }
                3..=8 => {
                    let r = rng.gen_range(0..POOL);
                    if !partitioned[r] && !replicas[r].inbox.is_empty() {
                        let i = rng.gen_range(0..replicas[r].inbox.len());
                        // Redelivery: sometimes deliver without dequeuing, so the same
                        // commit arrives again later — ingestion must be idempotent.
                        let h = if rng.gen_bool(0.25) {
                            replicas[r].inbox[i]
                        } else {
                            replicas[r].inbox.remove(i)
                        };
                        let bytes = world.commits[&h].clone();
                        replicas[r].known.insert(h, bytes);
                    }
                }
                _ => {
                    let r = rng.gen_range(0..POOL);
                    partitioned[r] = !partitioned[r];
                }
            }
        }

        // Quiescence: every replica eventually receives every commit (partitions heal,
        // duplicates and all).
        for rep in &mut replicas {
            rep.known = world.commits.clone();
        }
        // The run must actually have forked, or this test proves nothing.
        let mut children: BTreeMap<[u8; 32], usize> = BTreeMap::new();
        for bytes in world.commits.values() {
            *children.entry(Commit::from_bytes(bytes).unwrap().parent_commit_hash).or_default() += 1;
        }
        assert!(children.values().any(|&c| c >= 2), "seed {seed}: no fork occurred");

        let views: Vec<View> = (0..POOL).map(|m| replay(&world, m, &best_chain(&world, &replicas[m].known))).collect();
        let mut present: Vec<usize> = Vec::new();
        for li in 0..views[0].tree.n_leaves() {
            if let Some(l) = views[0].tree.leaf(li as u32) {
                present.push(member_from_cred(&l.device_credential));
            }
        }
        assert!(present.len() >= 2, "seed {seed}: membership collapsed");
        let reference = &views[present[0]];
        let ref_sched = reference.sched.as_ref().expect("member has a schedule");
        let probe_leaf_id = *blake3::hash(b"probe-device").as_bytes();
        for m in 0..POOL {
            let v = &views[m];
            // Everyone — member or not — agrees on the public facts: winning tip, tree.
            assert_eq!(v.tip, reference.tip, "seed {seed}: replica {m} tip diverged");
            assert_eq!(tree_hash(&v.tree), tree_hash(&reference.tree), "seed {seed}: replica {m} tree diverged");
            assert_eq!(v.cth, reference.cth, "seed {seed}: replica {m} transcript diverged");
            assert_eq!(v.epoch, reference.epoch);
            if present.contains(&m) {
                // Members agree on every secret of the epoch.
                let s = v.sched.as_ref().expect("present member must have derived the epoch");
                assert!(v.me.is_some(), "seed {seed}: present member {m} lost its leaf");
                assert_eq!(s.epoch_secret, ref_sched.epoch_secret, "seed {seed}: epoch secret diverged");
                assert_eq!(s.init_secret, ref_sched.init_secret);
                assert_eq!(
                    sender_key(&s.sender_root, &probe_leaf_id, GID, v.epoch),
                    sender_key(&ref_sched.sender_root, &probe_leaf_id, GID, reference.epoch),
                    "seed {seed}: sender key diverged"
                );
            } else {
                assert!(v.me.is_none(), "seed {seed}: non-member {m} thinks it is in the tree");
            }
        }
    }

    /// §9 M1 proof obligation: replicas converge to identical tree hash + epoch secret at
    /// quiescence under randomized ops, delivery orders, partitions, redelivery, and
    /// guaranteed forks. Several fixed seeds; failures reproduce exactly.
    #[test]
    fn replicas_converge_under_random_delivery_partitions_and_forks() {
        for seed in [11u64, 22, 33] {
            run_convergence_sim(seed, 28);
        }
    }
}

// ── M6: per-message sender-ratchet proof obligations (§9 M6, §6.5) ────────────────────────
#[cfg(test)]
mod ratchet_m6_tests {
    use super::*;

    const GID: &[u8] = b"dm-circle";
    const EPOCH: u64 = 7;
    // A stand-in for a leaf's per-epoch `sender_key_n` — the ratchet's one input.
    const SENDER_KEY: [u8; 32] = [0x5A; 32];

    /// What one message key opens: the derived event/AEAD-shaped material. For the FS test we only
    /// need "MK_i is a deterministic function of i and nothing about MK_{i-1} leaks from later
    /// state", so we compare the raw message keys (the content layer keys off these unchanged).
    fn all_keys(n: u32) -> Vec<[u8; 32]> {
        let mut s = SenderChain::new(&SENDER_KEY, GID, EPOCH);
        (0..n).map(|_| s.next_key().1).collect()
    }

    /// Sender and receiver agree on every message key, in order — the baseline the FS/order tests
    /// build on. Distinct keys per index (no accidental reuse).
    #[test]
    fn sender_and_receiver_agree_and_keys_are_distinct() {
        let sent = all_keys(16);
        let mut r = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        for (i, mk) in sent.iter().enumerate() {
            assert_eq!(r.message_key(i as u32).unwrap(), *mk, "receiver derives the same MK_{i}");
        }
        for i in 0..sent.len() {
            for j in (i + 1)..sent.len() {
                assert_ne!(sent[i], sent[j], "MK_{i} and MK_{j} must differ");
            }
        }
        // A different epoch (weekly re-root) yields a wholly different chain — "epoch rotation
        // resets the chain".
        let other = SenderChain::new(&SENDER_KEY, GID, EPOCH + 1).next_key().1;
        assert_ne!(other, sent[0], "a new epoch re-roots CK_0");
    }

    /// **Per-message FS (§9 M6):** capturing MK_i (or the receiver state AFTER processing message
    /// i) does not reveal MK_{i-1}. Proven two ways:
    ///   (a) the chain is one-way — the message key and the next chain key are independent HKDF
    ///       expands, so no function of {MK_i, CK_{i+1}} reconstructs MK_{i-1}; we assert the used
    ///       key is gone from the sender/receiver state and that later state never equals an
    ///       earlier key;
    ///   (b) delete-on-use — after the receiver processes i in order, MK_{i-1} is not held anywhere
    ///       (it was never cached), so a post-i state snapshot cannot yield it.
    #[test]
    fn per_message_forward_secrecy_used_key_is_unrecoverable() {
        let keys = all_keys(8);
        let mut r = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        // Process 0..=4 in order (delete-on-use — nothing cached).
        for i in 0..=4u32 {
            let _ = r.message_key(i).unwrap();
        }
        // Post-message-4 receiver state: the live chain key is CK_5. It must not equal any prior
        // message key, and the cache must be empty (in-order ⇒ no skips retained). So MK_3, MK_2,
        // … are unrecoverable from this snapshot.
        assert_eq!(r.next, 5, "receiver advanced to the next in-order index");
        assert_eq!(r.skipped_len(), 0, "in-order delivery caches nothing — delete-on-use");
        for k in &keys[..5] {
            assert_ne!(&r.ck, k, "the live chain key is not any consumed message key");
        }
        // And a late request for an already-consumed, never-cached index fails gracefully (the key
        // is gone) — you cannot walk the ratchet backwards to recover MK_3.
        assert!(r.message_key(3).is_none(), "a consumed in-order key cannot be re-derived (FS)");

        // Sender side: after producing MK_i the chain key advanced; the old CK_i is wiped, so the
        // sender likewise cannot re-emit MK_{i-1}.
        let mut s = SenderChain::new(&SENDER_KEY, GID, EPOCH);
        let (_, _mk0) = s.next_key();
        let ck_after0 = s.ck;
        let (_, _mk1) = s.next_key();
        assert_ne!(s.ck, ck_after0, "the sender chain key moved forward (old CK wiped, one-way)");
    }

    /// **Out-of-order / days-late (§9 M6):** a shuffled delivery order, plus one message delivered
    /// "days late" (far behind the current chain position), all open via the skipped-key cache —
    /// the mailbox open-a-late-message contract holds.
    #[test]
    fn out_of_order_and_days_late_all_open() {
        let keys = all_keys(64);
        let mut r = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);

        // Shuffled (deterministic) order over 0..12.
        for &i in &[3u32, 0, 7, 1, 2, 11, 4, 9, 5, 6, 8, 10] {
            assert_eq!(r.message_key(i).unwrap(), keys[i as usize], "shuffled MK_{i} opens");
        }
        // Jump far ahead: process index 60 while the tip was ~12. This caches 12..60 as skipped.
        assert_eq!(r.message_key(60).unwrap(), keys[60], "a big in-cap jump opens");
        // Now a DAYS-LATE message: index 20, delivered long after the chain advanced to 61. It is
        // still within the horizon, so the cache opens it.
        assert_eq!(r.message_key(20).unwrap(), keys[20], "a days-late message opens from the cache");
        assert_eq!(r.message_key(45).unwrap(), keys[45], "another late one opens");
        // Delete-on-use: re-requesting an already-served late index now misses (its key was
        // consumed) — but that is the dedup layer's job upstream, and it fails gracefully.
        assert!(r.message_key(20).is_none(), "a served late key is delete-on-use");
    }

    /// **Bounded skipped-key cache under adversarial gaps (§9 M6):**
    ///   1. a message claiming `next + HUGE` is rejected by the max-jump cap with NO derivation;
    ///   2. a normal gap within the cap works;
    ///   3. the cache honors its size cap — oldest evicted (and, implicitly, wiped).
    #[test]
    fn bounded_cache_rejects_adversarial_gap_and_caps_size() {
        // (1) Adversarial index: 2^32-1 while at 0. Rejected instantly, no state change.
        let mut r = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        assert!(r.message_key(u32::MAX).is_none(), "an out-of-cap jump is rejected");
        assert_eq!(r.next, 0, "a rejected jump advances nothing");
        assert_eq!(r.skipped_len(), 0, "a rejected jump derives/caches nothing");
        // Exactly at the cap boundary is allowed; one past is not.
        assert!(r.message_key(RATCHET_MAX_JUMP).is_some(), "a jump of exactly MAX_JUMP is allowed");
        let mut r2 = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        assert!(r2.message_key(RATCHET_MAX_JUMP + 1).is_none(), "one past MAX_JUMP is rejected");

        // (2) A normal in-cap gap opens and caches the skipped keys.
        let keys = all_keys(40);
        let mut r3 = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        assert_eq!(r3.message_key(30).unwrap(), keys[30], "an in-cap gap opens");
        assert_eq!(r3.skipped_len(), 30, "indices 0..30 are cached as skipped");
        assert_eq!(r3.message_key(5).unwrap(), keys[5], "a cached skipped key opens");

        // (3) Size cap: force more than RATCHET_MAX_SKIPPED skips across successive jumps and
        // assert the cache never exceeds the cap and the OLDEST indices are the ones evicted.
        let mut r4 = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        // First fill exactly to the cap (skip 0..cap, consume `cap`).
        let cap = RATCHET_MAX_SKIPPED as u32;
        assert!(r4.message_key(cap).is_some());
        assert_eq!(r4.skipped_len(), RATCHET_MAX_SKIPPED, "cache filled to the cap");
        assert!(r4.skipped.contains_key(&0), "index 0 present before overflow");
        // Now skip forward by RATCHET_MAX_JUMP more, forcing evictions of the oldest.
        assert!(r4.message_key(cap + RATCHET_MAX_JUMP).is_some());
        assert_eq!(r4.skipped_len(), RATCHET_MAX_SKIPPED, "cache stays capped after overflow");
        assert!(!r4.skipped.contains_key(&0), "the oldest index was evicted (and wiped)");
        assert!(
            r4.skipped.keys().min().copied().unwrap() > 0,
            "eviction removed a contiguous run of the oldest indices"
        );
        // The evicted (out-of-horizon) key now fails gracefully — no panic, just None.
        assert!(r4.message_key(0).is_none(), "an out-of-horizon late message fails gracefully");
    }

    /// The chain is a pure function of (sender_key, group, epoch): two independently constructed
    /// receivers agree, and the sender's stream matches a receiver's in-order stream — the
    /// property the FFI relies on to have peers converge without shared state.
    #[test]
    fn ratchet_is_deterministic_across_replicas() {
        let mut r_a = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        let mut r_b = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH);
        for i in 0..20u32 {
            assert_eq!(r_a.message_key(i), r_b.message_key(i), "independent replicas agree at {i}");
        }
        // A different group id gives a different chain (no cross-DM confusion).
        let cross = RatchetReceiver::new(&SENDER_KEY, b"other-dm", EPOCH)
            .message_key(0)
            .unwrap();
        let mine = RatchetReceiver::new(&SENDER_KEY, GID, EPOCH).message_key(0).unwrap();
        assert_ne!(cross, mine, "group id is bound into CK_0");
    }
}
