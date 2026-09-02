//! Fuzz harness for every wire parser in the crate.
//!
//! `docs/TREEKEM-DESIGN.md` §9 M7 names "fuzz wire parsers" as work and "fuzz corpus green in
//! CI" as its proof obligation. This is that harness.
//!
//! **Why it lives in `tests/` rather than a `cargo-fuzz` crate.** `cargo-fuzz` needs nightly and a
//! separate target, so it runs only when someone remembers to run it — which for this project means
//! never. This runs under plain `cargo test` on stable so CI can execute it every push.
//!
//! That last part was NOT free, and the assumption is worth recording: `desktop.yml` ran only
//! `cargo test -p haven-s3` and the desktop lib, so haven-p2p — this crate, the crypto core — had
//! **no CI coverage at all**, and adding a test file here would have run nowhere. The workflow now
//! runs `cargo test -p haven-p2p` too. If that line ever goes away, this harness goes quiet without
//! failing anything, which is the worst way for a security test to die. It is not coverage-guided,
//! so it trades
//! ultimate depth for actually running; the mutators below are structure-aware to buy most of that
//! depth back (purely random bytes bounce off the first length check and never reach the
//! interesting code).
//!
//! **Determinism is the point.** All entropy comes from a fixed-seed xorshift PRNG, so a failure
//! reproduces exactly and the report prints the input hex. Nothing here touches the clock or the OS
//! RNG. Crank the iteration counts for a deep run with `HAVEN_FUZZ_ITERS=200000 cargo test -p
//! haven-p2p --test fuzz_wire_parsers -- --nocapture`.
//!
//! **What it asserts.**
//!   1. No parser PANICS on any input. A panic on attacker-supplied bytes is a remote DoS — every
//!      one of these types arrives from the network or a relay mailbox.
//!   2. `from_bytes(to_bytes(x))` round-trips byte-stably for valid values.
//!   3. Exact consumption: a valid encoding plus ONE trailing byte is REJECTED. These formats are
//!      terminal, and an accepted trailer is the seed-drop-trailer trap `TREEKEM-DESIGN.md` §7.1
//!      warns about.
//!   4. A hostile element count fails closed instead of pre-allocating from an untrusted number.

use std::panic::{catch_unwind, AssertUnwindSafe};

use haven_p2p::device::{AdminGrant, CircleUpgrade, DeviceCredential, DeviceList, SeedDropCapability};
use haven_p2p::groupkey::{seal_event_in_epoch, EpochEnvelope};
use haven_p2p::identity::Identity;
use haven_p2p::social::{Event, EventKind};
use haven_p2p::treekem::{
    Commit, GroupInfo, LeafNode, ParentNode, PathSecretCiphertext, PersistTree, Proposal,
    ProposalBody, RatchetTree, TreeSlot, UpdatePath, UpdatePathNode, Welcome, WelcomeJoiner,
    ForkCacheEntry, KEM_X_LEN, MLKEM_EK_LEN,
};

// ── Deterministic PRNG (xorshift64*) ──────────────────────────────────────────────────────
//
// Hand-rolled rather than pulled from `rand`: this file must add no dependency, and a fixed
// algorithm means a seed reproduces the same corpus across toolchains and rand versions forever.

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Rng(seed | 1) // never zero — xorshift's fixed point
    }
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn next_u32(&mut self) -> u32 {
        (self.next_u64() >> 32) as u32
    }
    /// Uniform-ish in `[0, n)`. Modulo bias is irrelevant for corpus generation.
    fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next_u64() % n as u64) as usize
        }
    }
    fn byte(&mut self) -> u8 {
        (self.next_u64() >> 56) as u8
    }
    fn bytes(&mut self, n: usize) -> Vec<u8> {
        (0..n).map(|_| self.byte()).collect()
    }
    fn arr32(&mut self) -> [u8; 32] {
        let mut a = [0u8; 32];
        for b in a.iter_mut() {
            *b = self.byte();
        }
        a
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Trim a hex dump so a failure report stays readable — the seed reproduces the full input.
fn hex_head(b: &[u8]) -> String {
    if b.len() <= 96 {
        hex(b)
    } else {
        format!("{}… ({} bytes)", hex(&b[..96]), b.len())
    }
}

fn iters(default: usize) -> usize {
    std::env::var("HAVEN_FUZZ_ITERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

// ── The parser table ──────────────────────────────────────────────────────────────────────

/// One fuzz target: a named parser plus valid encodings to mutate. `parse` normalizes every
/// parser's return shape (`Result` here, `Option` for `SeedDropCapability`) to "did it accept".
struct Target {
    name: &'static str,
    parse: Box<dyn Fn(&[u8]) -> bool>,
    /// Valid encodings — the mutation corpus. May include several encodings of one value.
    seeds: Vec<Vec<u8>>,
    /// The subset whose re-encode through `reencode` is byte-stable. `EpochEnvelope` has three
    /// encoders (`to_bytes` JSON, `to_bytes_compact` postcard, `to_bytes_gated`), so only the one
    /// matching `reencode` round-trips byte-for-byte; the others are still valid mutation seeds.
    canonical: Vec<Vec<u8>>,
    /// Does this parser promise EXACT consumption? True only for `treekem`, whose header states the
    /// property and scopes it: these formats are terminal "unlike the roster wire". `device.rs`
    /// deliberately allows an appended trailer (`SeedDropCapability` is designed as one,
    /// device.rs:585) and takes the variable-length hybrid signature via `r.rest()`, so a trailer
    /// there lands inside `sig` and fails at VERIFY rather than at parse. Asserting exact
    /// consumption on those would test a property the design deliberately does not have.
    exact_consumption: bool,
    reencode: Box<dyn Fn(&[u8]) -> Option<Vec<u8>>>,
}

/// Build a target from a type's `from_bytes`/`to_bytes` pair.
macro_rules! target {
    ($name:literal, $ty:ty, $seeds:expr, $exact:expr) => {{
        let s: Vec<Vec<u8>> = $seeds;
        Target {
            name: $name,
            parse: Box::new(|b: &[u8]| <$ty>::from_bytes(b).is_ok()),
            canonical: s.clone(),
            seeds: s,
            exact_consumption: $exact,
            reencode: Box::new(|b: &[u8]| <$ty>::from_bytes(b).ok().map(|v| v.to_bytes())),
        }
    }};
}

fn leaf_node(r: &mut Rng) -> LeafNode {
    let mut pq = [0u8; MLKEM_EK_LEN];
    for b in pq.iter_mut() {
        *b = r.byte();
    }
    let mut x = [0u8; KEM_X_LEN];
    for b in x.iter_mut() {
        *b = r.byte();
    }
    LeafNode {
        leaf_kem_x: x,
        leaf_kem_pq: pq,
        device_credential: r.bytes(64),
        leaf_binding_sig: r.bytes(80),
    }
}

fn parent_node(r: &mut Rng, blank: bool) -> ParentNode {
    let mut pq = [0u8; MLKEM_EK_LEN];
    for b in pq.iter_mut() {
        *b = r.byte();
    }
    let mut x = [0u8; KEM_X_LEN];
    for b in x.iter_mut() {
        *b = r.byte();
    }
    ParentNode {
        blank,
        node_kem_x: x,
        node_kem_pq: pq,
        unmerged_leaves: vec![r.next_u32() % 8, r.next_u32() % 8],
    }
}

fn path_ct(r: &mut Rng) -> PathSecretCiphertext {
    let mut x = [0u8; KEM_X_LEN];
    for b in x.iter_mut() {
        *b = r.byte();
    }
    PathSecretCiphertext {
        resolution_index: r.next_u32() % 16,
        eph_x: x,
        pq_ct: r.bytes(1088),
        wrapped_path_secret: r.bytes(48),
    }
}

fn update_path(r: &mut Rng) -> UpdatePath {
    let mut x = [0u8; KEM_X_LEN];
    for b in x.iter_mut() {
        *b = r.byte();
    }
    let mut pq = [0u8; MLKEM_EK_LEN];
    for b in pq.iter_mut() {
        *b = r.byte();
    }
    UpdatePath {
        leaf_node: leaf_node(r),
        nodes: vec![UpdatePathNode {
            node_kem_x: x,
            node_kem_pq: pq,
            ciphertexts: vec![path_ct(r), path_ct(r)],
        }],
    }
}

fn proposal(r: &mut Rng, which: u8) -> Proposal {
    let body = match which % 3 {
        0 => ProposalBody::Add { leaf_node: leaf_node(r) },
        1 => ProposalBody::Remove { leaf_index: r.next_u32() % 32 },
        _ => ProposalBody::Update { leaf_node: leaf_node(r) },
    };
    Proposal {
        group_id: r.bytes(16),
        epoch: r.next_u64(),
        body,
        sender_leaf: r.next_u32() % 32,
        sig: r.bytes(96),
    }
}

fn group_info(r: &mut Rng) -> GroupInfo {
    GroupInfo {
        group_id: r.bytes(16),
        epoch: r.next_u64(),
        tree_blob_ref: r.bytes(32),
        confirmed_transcript_hash: r.arr32(),
        tree_hash: r.arr32(),
        signer_leaf: r.next_u32() % 32,
        sig: r.bytes(96),
    }
}

fn commit(r: &mut Rng, with_path: bool) -> Commit {
    Commit {
        group_id: r.bytes(16),
        epoch: r.next_u64(),
        parent_commit_hash: r.arr32(),
        proposals: vec![proposal(r, 0), proposal(r, 1)],
        update_path: if with_path { Some(update_path(r)) } else { None },
        tree_hash: r.arr32(),
        confirmation_mac: r.bytes(32),
        sender_leaf: r.next_u32() % 32,
        sig: r.bytes(96),
    }
}

fn persist_tree(r: &mut Rng) -> PersistTree {
    PersistTree {
        group_id: r.bytes(16),
        commit_chain: vec![(r.arr32(), r.bytes(128))],
        tree_blob_ref: r.bytes(32),
        tree_bytes: r.bytes(64),
        my_leaf_index: r.next_u32() % 32,
        my_leaf_secret: r.arr32(),
        my_path_secrets: vec![r.arr32(), r.arr32()],
        fork_cache: vec![ForkCacheEntry {
            epoch: r.next_u64(),
            commit_hash: r.arr32(),
            sender_keys: vec![(r.arr32(), r.arr32())],
        }],
        epoch_secrets: vec![(r.next_u64(), r.arr32()), (r.next_u64(), r.arr32())],
    }
}

/// A valid `EpochEnvelope`, produced by the real seal path (its fields are private, so it cannot
/// be constructed field-wise the way the wire types above can).
fn envelope_seeds(r: &mut Rng) -> Vec<Vec<u8>> {
    let id = Identity::from_seed(&r.arr32());
    let key = r.arr32();
    let ev = Event {
        id: "e1".into(),
        author: "a1".into(),
        created_at: 1_700_000_000_000,
        kind: EventKind::Message { body: "fuzz seed".into() },
    };
    match seal_event_in_epoch(&id, "c1", 7, &key, &ev) {
        Ok(env) => vec![env.to_bytes(), env.to_bytes_compact()],
        Err(_) => Vec::new(),
    }
}

fn targets() -> Vec<Target> {
    let r = &mut Rng::new(0xC0FFEE_1234_5678);

    let device = Identity::from_seed(&r.arr32()).public();
    let sdc: Vec<Vec<u8>> = vec![SeedDropCapability {
        account_id: r.arr32(),
        version: 1,
        sig: r.bytes(96),
    }
    .to_bytes()];
    // `to_bytes` (JSON) is the encoder `reencode` uses, so only it is byte-stable; the compact
    // postcard form is still a valid parse target and stays in the mutation corpus.
    let env_all = envelope_seeds(r);
    let env_canonical: Vec<Vec<u8>> = env_all.iter().take(1).cloned().collect();

    // The trailing `true`/`false` is the EXACT-CONSUMPTION contract (see `Target`): treekem's
    // formats are terminal; the roster wire deliberately carries appended trailers.
    vec![
        target!("treekem::LeafNode", LeafNode, vec![leaf_node(r).to_bytes()], true),
        target!(
            "treekem::ParentNode",
            ParentNode,
            vec![parent_node(r, false).to_bytes(), parent_node(r, true).to_bytes()],
            true
        ),
        target!(
            "treekem::RatchetTree",
            RatchetTree,
            vec![RatchetTree {
                slots: vec![
                    TreeSlot::Blank,
                    TreeSlot::Leaf(leaf_node(r)),
                    TreeSlot::Parent(parent_node(r, false)),
                    TreeSlot::Leaf(leaf_node(r)),
                ],
            }
            .to_bytes()],
            true
        ),
        target!(
            "treekem::Proposal",
            Proposal,
            vec![proposal(r, 0).to_bytes(), proposal(r, 1).to_bytes(), proposal(r, 2).to_bytes()],
            true
        ),
        target!("treekem::UpdatePath", UpdatePath, vec![update_path(r).to_bytes()], true),
        target!(
            "treekem::Commit",
            Commit,
            vec![commit(r, false).to_bytes(), commit(r, true).to_bytes()],
            true
        ),
        target!("treekem::GroupInfo", GroupInfo, vec![group_info(r).to_bytes()], true),
        target!(
            "treekem::Welcome",
            Welcome,
            vec![Welcome {
                group_info: group_info(r),
                joiners: vec![WelcomeJoiner {
                    joiner_device_id: r.arr32(),
                    eph_x: {
                        let mut x = [0u8; KEM_X_LEN];
                        for b in x.iter_mut() {
                            *b = r.byte();
                        }
                        x
                    },
                    pq_ct: r.bytes(1088),
                    wrapped: r.bytes(80),
                }],
            }
            .to_bytes()],
            true
        ),
        target!("treekem::PersistTree", PersistTree, vec![persist_tree(r).to_bytes()], true),
        target!(
            "device::DeviceCredential",
            DeviceCredential,
            vec![DeviceCredential {
                account_id: r.arr32(),
                device: device.clone(),
                device_name: "Fuzz iPhone".into(),
                created_at: 1_700_000_000,
                sig: r.bytes(96),
            }
            .to_bytes()],
            false
        ),
        target!(
            "device::DeviceList",
            DeviceList,
            vec![DeviceList {
                account_id: r.arr32(),
                version: 9,
                updated_at: 1_700_000_000,
                devices: vec![r.arr32(), r.arr32()],
                revoked: vec![r.arr32()],
                account_leaf_retired: true,
                sig: r.bytes(96),
            }
            .to_bytes()],
            false
        ),
        Target {
            name: "device::SeedDropCapability",
            // The one parser returning Option rather than Result.
            parse: Box::new(|b: &[u8]| SeedDropCapability::from_bytes(b).is_some()),
            canonical: sdc.clone(),
            seeds: sdc,
            // Designed to be APPENDED as a trailer (device.rs:585) — demanding exact consumption
            // here would test the opposite of its contract.
            exact_consumption: false,
            reencode: Box::new(|b: &[u8]| SeedDropCapability::from_bytes(b).map(|v| v.to_bytes())),
        },
        target!(
            "device::AdminGrant",
            AdminGrant,
            vec![AdminGrant {
                circle_id: r.bytes(18),
                creator: r.arr32(),
                admin_account: r.arr32(),
                version: 3,
                grantor_account: r.arr32(),
                sig: r.bytes(96),
            }
            .to_bytes()],
            false
        ),
        target!(
            "device::CircleUpgrade",
            CircleUpgrade,
            vec![CircleUpgrade {
                legacy_circle_id: b"default".to_vec(),
                new_circle_id: b"c1abcdefghijklmnop".to_vec(),
                creator: r.arr32(),
                name: "Family".into(),
                version: 2,
                sig: r.bytes(96),
            }
            .to_bytes()],
            false
        ),
        Target {
            name: "groupkey::EpochEnvelope",
            parse: Box::new(|b: &[u8]| EpochEnvelope::from_bytes(b).is_ok()),
            canonical: env_canonical,
            seeds: env_all,
            // A serde/postcard container, not a `Reader`-cursor format — the treekem tail rule
            // does not apply to it and is not claimed for it.
            exact_consumption: false,
            reencode: Box::new(|b: &[u8]| EpochEnvelope::from_bytes(b).ok().map(|v| v.to_bytes())),
        },
    ]
}

// ── Mutators ──────────────────────────────────────────────────────────────────────────────

/// Mutate a valid encoding. These are chosen against what the parsers actually do: `lp()` length
/// prefixes and `u32` element counts, fixed-size arrays, and an exact-consumption tail check.
fn mutate(r: &mut Rng, seed: &[u8]) -> Vec<u8> {
    let mut b = seed.to_vec();
    if b.is_empty() {
        return b;
    }
    match r.below(8) {
        // Flip one bit — the cheapest way to hit a tag byte or a length's high bits.
        0 => {
            let i = r.below(b.len());
            b[i] ^= 1u8 << r.below(8);
        }
        // Replace one byte outright.
        1 => {
            let i = r.below(b.len());
            b[i] = r.byte();
        }
        // Truncate — every parser must fail closed on a short read, never index past the end.
        2 => {
            let n = r.below(b.len());
            b.truncate(n);
        }
        // Append trailing bytes — must be REJECTED (property 3), never silently ignored.
        3 => {
            let extra = r.below(8) + 1;
            for _ in 0..extra {
                b.push(r.byte());
            }
        }
        // Corrupt a 4-byte little-endian field to a hostile count. This is the no-preallocation
        // claim under direct attack: a count of ~4 billion with no data behind it.
        4 => {
            if b.len() >= 4 {
                let i = r.below(b.len() - 3);
                let v: u32 = match r.below(4) {
                    0 => u32::MAX,
                    1 => 0x7FFF_FFFF,
                    2 => 0x0100_0000,
                    _ => r.next_u32(),
                };
                b[i..i + 4].copy_from_slice(&v.to_le_bytes());
            }
        }
        // Zero a run — drives lengths and tags to 0.
        5 => {
            let i = r.below(b.len());
            let n = r.below(16).min(b.len() - i);
            for x in b[i..i + n].iter_mut() {
                *x = 0;
            }
        }
        // Splice: duplicate a chunk, so counts and payloads disagree.
        6 => {
            let i = r.below(b.len());
            let n = r.below(32).min(b.len() - i);
            let chunk: Vec<u8> = b[i..i + n].to_vec();
            let at = r.below(b.len());
            for (k, c) in chunk.into_iter().enumerate() {
                b.insert(at + k, c);
            }
        }
        // Remove a chunk from the middle.
        _ => {
            let i = r.below(b.len());
            let n = r.below(16).min(b.len() - i);
            b.drain(i..i + n);
        }
    }
    b
}

// ── Panic capture ─────────────────────────────────────────────────────────────────────────

/// Run `parse` with panics captured. A panic here is the finding — every one of these inputs
/// models bytes an attacker can put in a mailbox.
fn parse_caught(t: &Target, bytes: &[u8]) -> std::result::Result<bool, ()> {
    catch_unwind(AssertUnwindSafe(|| (t.parse)(bytes))).map_err(|_| ())
}

/// Silence the default panic printer for the duration of a fuzz loop, so a caught panic does not
/// dump a backtrace per iteration. Restored on drop, including on unwind.
struct QuietPanics(Option<Box<dyn Fn(&std::panic::PanicHookInfo<'_>) + Sync + Send + 'static>>);

impl QuietPanics {
    fn install() -> Self {
        let prev = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        QuietPanics(Some(prev))
    }
}

impl Drop for QuietPanics {
    fn drop(&mut self) {
        // `set_hook` PANICS if called from a panicking thread, and a panic inside a Drop that is
        // running during unwind is a double panic — which aborts the process (SIGABRT) instead of
        // reporting the original assertion. Restoring the hook is only a courtesy to later tests,
        // so skip it on the unwind path and let the real failure surface.
        if std::thread::panicking() {
            return;
        }
        if let Some(h) = self.0.take() {
            std::panic::set_hook(h);
        }
    }
}

// ── Properties ────────────────────────────────────────────────────────────────────────────

#[test]
fn every_seed_round_trips_byte_stably() {
    // Guards the harness as much as the parsers: if a seed below is malformed, this fails here
    // with a clear message rather than silently degrading every mutation run into noise.
    for t in targets() {
        assert!(!t.seeds.is_empty(), "{}: no seeds — mutation coverage would be vacuous", t.name);
        for (i, s) in t.canonical.iter().enumerate() {
            assert!((t.parse)(s), "{} seed #{i}: valid encoding rejected — harness bug", t.name);
            let again = (t.reencode)(s)
                .unwrap_or_else(|| panic!("{} seed #{i}: re-encode failed", t.name));
            assert_eq!(&again, s, "{} seed #{i}: round-trip is not byte-stable", t.name);
        }
    }
}

#[test]
fn no_parser_panics_on_arbitrary_bytes() {
    let n = iters(3_000);
    let ts = targets();
    let _quiet = QuietPanics::install();
    for t in &ts {
        for seed in 0..4u64 {
            let r = &mut Rng::new(0xA11CE ^ (seed << 32));
            for i in 0..n {
                let len = r.below(2_048);
                let bytes = r.bytes(len);
                if parse_caught(t, &bytes).is_err() {
                    drop(_quiet);
                    panic!(
                        "PANIC in {} on random input\n  seed={seed} iter={i}\n  input={}",
                        t.name,
                        hex_head(&bytes)
                    );
                }
            }
        }
    }
}

#[test]
fn no_parser_panics_on_mutated_valid_encodings() {
    // The one that actually finds things: mutations start from structurally valid bytes, so they
    // reach past the first length check into the tree/count-walking code.
    let n = iters(6_000);
    let ts = targets();
    let _quiet = QuietPanics::install();
    for t in &ts {
        for seed in 0..4u64 {
            let r = &mut Rng::new(0xBEEF ^ (seed << 32) ^ t.name.len() as u64);
            for i in 0..n {
                let base = &t.seeds[r.below(t.seeds.len())];
                let bytes = mutate(r, base);
                if parse_caught(t, &bytes).is_err() {
                    drop(_quiet);
                    panic!(
                        "PANIC in {} on mutated input\n  seed={seed} iter={i}\n  input={}",
                        t.name,
                        hex_head(&bytes)
                    );
                }
            }
        }
    }
}

#[test]
fn trailing_bytes_are_rejected() {
    // Property 3 — these formats are terminal. An accepted trailer is the trap §7.1 names.
    for t in targets().into_iter().filter(|t| t.exact_consumption) {
        for (i, s) in t.canonical.iter().enumerate() {
            for extra in [0x00u8, 0xFF, 0x41] {
                let mut b = s.clone();
                b.push(extra);
                match parse_caught(&t, &b) {
                    Err(()) => panic!("PANIC in {} on seed #{i} + trailing {extra:#04x}", t.name),
                    Ok(accepted) => assert!(
                        !accepted,
                        "{} seed #{i}: accepted a trailing {extra:#04x} byte — exact consumption \
                         is not enforced, so a trailer can smuggle data past this parser",
                        t.name
                    ),
                }
            }
        }
    }
}

#[test]
fn hostile_element_counts_do_not_preallocate() {
    // The "untrusted element counts are never pre-allocated" claim, attacked directly: plant a
    // ~4-billion count at each plausible offset with nothing behind it.
    //
    // The property is that the parser RETURNS — promptly, without reserving gigabytes. It is NOT
    // that it must reject: several of these u32 slots are legitimately free-form (a `version`, an
    // `epoch`, a `leaf_index`), so a parser accepting 0xFFFFFFFF there is correct behaviour, and
    // asserting rejection would be testing the harness's guess about the layout rather than the
    // code. A parser that reserves from the count first never reaches the assertion at all — it
    // aborts on allocation failure, which is exactly the failure this is here to catch.
    let ts = targets();
    let _quiet = QuietPanics::install();
    for t in &ts {
        for count in [u32::MAX, 0x7FFF_FFFF, 0x00FF_FFFF] {
            // Sweep every offset a count could sit at, not a hand-picked few. The
            // DeviceList pre-allocation DoS lived at offset 48 (32 id + 8 version + 8
            // updated_at) and this test walked straight past it — the mutation fuzzer
            // caught it instead. A dense sweep makes this the direct regression guard.
            for prefix_len in 0usize..=64 {
                let mut b = vec![0u8; prefix_len];
                b.extend_from_slice(&count.to_le_bytes());
                b.extend_from_slice(&[0u8; 8]);
                // An allocation failure ABORTS rather than unwinding, so `catch_unwind` never
                // returns and the process dies with no indication of which target was in flight.
                // Set HAVEN_FUZZ_TRACE=1 to print each probe before it runs and identify it.
                if std::env::var_os("HAVEN_FUZZ_TRACE").is_some() {
                    use std::io::Write as _;
                    eprintln!("  probing {} count={count:#x} offset={prefix_len}", t.name);
                    let _ = std::io::stderr().flush();
                }
                if parse_caught(t, &b).is_err() {
                    panic!(
                        "PANIC in {} on hostile count {count:#x} at offset {prefix_len}",
                        t.name
                    );
                }
            }
        }
    }
}
