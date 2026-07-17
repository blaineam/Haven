//! "Everything ON" end-to-end validation for Haven's 1.0.7 crypto — the confidence gate that proves
//! flipping ALL the dark switches (seed-drop retirement, MLS keying, admin authority, per-message DM
//! forward secrecy, self-sync key rotation, seedless enrollment) composes correctly AND migrates
//! existing data cleanly, BEFORE any client is wired to enable them.
//!
//! Every test drives the FFI exactly as a client would — through the crate's PUBLIC API only (no
//! `#[cfg(test)]` internals, no `state.lock()`, no direct `Identity`/`treekem` access). It is the
//! external twin of the in-crate `#[cfg(test)]` switch tests, composed "all on" and checked for
//! migration safety. Determinism: fixed 32-byte seeds, fixed post timestamps, order-independent set
//! equality on feeds.
//!
//! Run it (the command a human runs):
//!
//!     export PATH="$HOME/.cargo/bin:$PATH"
//!     cd core && cargo test -p haven_ffi --test enabled_paths
//!
//! The client enable-sequence this harness pins is written up in `docs/SWITCH-FLIP-1.0.7.md`.
//!
//! ── One capability the public FFI cannot reach, and how it's handled ──────────────────────────────
//! The weekly PCS *cadence timer* (§6.4) fires off the real wall clock, and the crate's clock-skew
//! hook is `#[cfg(test)]` — compiled OUT of the build an external test links against. So this harness
//! cannot fast-forward seven days. Scenario 7 therefore drives the *same committer-UpdatePath heal*
//! the cadence piggybacks, via an explicit epoch-advancing commit, and asserts the forward-secrecy
//! consequence that IS publicly observable (old-epoch material cannot open new-epoch content). The
//! pure clock-triggered cadence + the internal exfiltrate-and-replay proof remain covered by the
//! in-crate `mls_pcs_cadence_heals_committer_leaf_on_the_rotate_chokepoint`.

mod common;
use common::*;

use std::collections::BTreeSet;
use std::sync::Arc;

use haven_ffi::multidevice::{
    issue_device_credential, mint_self_sync_key, open_account_state_dual,
    open_self_sync_key_epoch_grant, seal_account_state, seal_account_state_with_key_epoch,
    seal_self_sync_key_epoch_grant, self_sync_key_epoch_of, self_sync_key_should_rotate,
    sign_device_list, AccountStateHandle,
};
use haven_ffi::HavenSocial;

use haven_p2p::groupkey::EpochEnvelope;

// Wire tags (mirrors the private consts in `src/lib.rs`; stable on-wire routing bytes).
const TAG_EPOCH_EVENT: u8 = 0x02; // an EpochEnvelope (event sealed under a circle epoch key)
const TAG_KEY_COMMIT: u8 = 0x03; // a SealedEnvelope carrying a circle epoch key (KeyCommit)

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  Shared drivers (public-API twins of the in-crate MLS test helpers)
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// Deliver everything `from` has for `cid` to `to`, exactly as the platform sync/backfill does.
fn sync(from: &HavenSocial, to: &HavenSocial, cid: &str) {
    for env in from.sync_envelopes(cid.to_string()) {
        let _ = to.receive(cid.to_string(), env);
    }
}

/// All-to-all sync `rounds` times so genesis/welcomes/re-seals propagate to convergence.
fn sync_all(insts: &[&Arc<HavenSocial>], cid: &str, rounds: usize) {
    for _ in 0..rounds {
        for i in 0..insts.len() {
            for j in 0..insts.len() {
                if i != j {
                    sync(insts[i], insts[j], cid);
                }
            }
        }
    }
}

/// Feed bodies as a set, for order-independent equality.
fn bodies(s: &HavenSocial, cid: &str, now: u64) -> BTreeSet<String> {
    s.feed(cid.to_string(), now, None).into_iter().map(|f| f.body).collect()
}

/// The account node-id hex for a 32-byte seed (a throwaway engine derives it — never a hard-coded id).
fn acct_hex(seed: [u8; 32]) -> String {
    HavenSocial::new(seed.to_vec()).unwrap().my_node_hex()
}

/// Build (but do not install) a DEVICE-ONLY roster wire for `s` (the running device is the only tree
/// leaf — every leaf maps to a live, joining device, the topology the §7.2 all-joined gate needs).
fn device_only_roster_wire(s: &HavenSocial, seed: [u8; 32]) -> (Vec<u8>, Vec<Vec<u8>>) {
    let dev_bundle = s.my_device_bundle();
    let dev_id = hex_to_bytes(&s.my_device_node_hex());
    let dev_cred = issue_device_credential(seed.to_vec(), dev_bundle, "device".into(), 1).unwrap();
    let list = sign_device_list(seed.to_vec(), 1, 0, vec![dev_id], vec![]).unwrap();
    (list, vec![dev_cred])
}

/// [`device_only_roster_wire`] + install it on `s`.
fn install_device_only_roster(s: &HavenSocial, seed: [u8; 32]) -> (Vec<u8>, Vec<Vec<u8>>) {
    let (list, creds) = device_only_roster_wire(s, seed);
    assert!(s.set_my_device_roster(list.clone(), creds.clone()), "own device-only roster installs");
    (list, creds)
}

/// A fully-MLS-capable fleet in the default circle: device identities, device-only rosters,
/// cross-learned rosters + capability cards, and a pinned creator. Does NOT flip the keying switch
/// (the caller decides). Public-API twin of the in-crate `mls_capable_fleet`.
fn mls_capable_fleet(seeds: &[[u8; 32]], devs: &[[u8; 32]], creator_idx: usize) -> Vec<Arc<HavenSocial>> {
    let cid = DEFAULT_CIRCLE;
    let insts: Vec<Arc<HavenSocial>> = seeds.iter().map(|s| HavenSocial::new(s.to_vec()).unwrap()).collect();
    let n = insts.len();
    for (i, d) in devs.iter().enumerate() {
        assert!(insts[i].use_device_identity(d.to_vec()), "device identity adopts");
    }
    let bundles: Vec<Vec<u8>> = insts.iter().map(|s| s.my_bundle()).collect();
    let mut rosters = Vec::new();
    for i in 0..n {
        for j in 0..n {
            if i != j {
                insts[i].add_contact_bundle(cid.into(), bundles[j].clone()).unwrap();
            }
        }
        rosters.push(install_device_only_roster(&insts[i], seeds[i]));
    }
    let cards: Vec<Vec<u8>> = insts.iter().map(|s| capability_card(s, "m")).collect();
    for i in 0..n {
        for j in 0..n {
            if i != j {
                assert!(insts[i].ingest_device_roster(bundles[j].clone(), rosters[j].0.clone(), rosters[j].1.clone()));
                insts[i].profile_seed_drop_version(bundles[j].clone(), cards[j].clone());
            }
        }
    }
    let creator_hex = acct_hex(seeds[creator_idx]);
    for s in &insts {
        assert!(s.set_circle_creator(cid.into(), creator_hex.clone()), "creator pins");
    }
    insts
}

/// Flip MLS keying on the whole fleet and sync all-to-all until it goes live everywhere.
fn flip_and_join(insts: &[Arc<HavenSocial>], cid: &str) {
    for s in insts {
        s.set_mls_keying(true);
    }
    let refs: Vec<&Arc<HavenSocial>> = insts.iter().collect();
    sync_all(&refs, cid, 6);
}

/// Ratchet index carried by a `post()` wire (tagged epoch envelope). `None` ⇒ NOT ratcheted.
fn wire_ratchet_index(wire: &[u8]) -> Option<u32> {
    assert_eq!(wire.first(), Some(&TAG_EPOCH_EVENT), "a post is a tagged epoch envelope");
    EpochEnvelope::from_bytes(&wire[1..]).unwrap().ratchet_index()
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 1 — AUTO-MIGRATION: legacy persisted state → all switches ON, nothing lost
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// Load a golden LEGACY persisted state (a real multi-circle account: two circles, contacts, a post
/// with a media ref + a comment, an ingested peer post, a device roster), turn EVERY 1.0.7 switch ON,
/// and prove the enabled path is content-preserving — the absence-as-deletion guard holds under the
/// enabled path. Then RETIRE THE ACCOUNT LEAF, revive the migrated contact as a live capable peer, and
/// prove the migrated circle now reaches LIVE MLS keying and that retirement cuts an account-seed-only
/// holder — the migration that was previously unreachable.
///
/// Invariant asserted: enabling all switches on an existing account wipes NOTHING (exact circle set,
/// per-circle membership, feed bodies + authorship + media ref + comment all identical before/after
/// the flip), the account stays a functioning engine, and — the FIX — once the account calls
/// `retire_account_leaf`, its legacy `{account, device}` roster settles at the device-only shape, the
/// circle reaches `state == "live"`, retirement cuts a bare-account-seed holder (that read fine before
/// retirement), and every pre-migration post plus new content still round-trips to the revived peer.
///
/// THE FIX (was a flagged FINDING before the account-leaf-retirement migration path landed): a migrated
/// multi-device account's own roster is grow-only union-merged, so it could never shed the bare account
/// leaf to reach the device-only shape live MLS keying + account-key retirement require — the circle was
/// stranded at "shadow" (dual-stack, legacy-keyed) forever. `retire_account_leaf` mints an authenticated,
/// versioned, sticky "account-leaf retired" flag on the signed roster (the account id STAYS in `devices`
/// but stops being authorized), so the roster reaches device-only, the all-joined gate completes, and the
/// circle flips to live. New installs that register device-only from day one were always fine; this is the
/// path for EXISTING upgraders — the central 1.0.7 requirement. See docs/SWITCH-FLIP-1.0.7.md §1.
#[test]
fn migration_all_switches_on_loses_nothing_and_retire_account_leaf_reaches_live() {
    // Load the frozen state under the identity it was authored with (seed 1 + device 91).
    let me = account(1);
    assert!(me.use_device_identity(vec![91u8; 32]));
    me.import_state(load_fixture("account_multicircle.b64"));

    let bob_hex = acct_hex([2u8; 32]);
    let carol_hex = acct_hex([3u8; 32]);

    // ── Projection BEFORE the flip (the migration baseline). ──
    let circles_before: BTreeSet<(String, String)> =
        me.circles().iter().map(|c| (c.id.clone(), c.name.clone())).collect();
    let default_before = bodies(&me, "default", 10_000);
    let fam_before = bodies(&me, "fam", 10_000);
    let default_members_before = me.contact_node_ids("default".into());
    let fam_members_before = me.contact_node_ids("fam".into());
    let roster_before = me.my_device_roster_wire();
    let my_post_before = me.feed("default".into(), 10_000, None)
        .into_iter().find(|f| f.body == "p-default-1").expect("my migrated post is present");
    assert_eq!(my_post_before.media, vec!["media/ref-abc".to_string()], "media ref present pre-flip");
    assert!(my_post_before.comments.iter().any(|c| c.body == "c-default-1"), "comment present pre-flip");
    assert!(my_post_before.is_me, "authorship present pre-flip");

    // ── FLIP EVERYTHING ON. ──
    me.set_seed_drop_retire(true);
    me.set_mls_keying(true);
    let me_hex = me.my_node_hex();
    assert!(me.set_circle_creator("default".into(), me_hex.clone()));
    assert!(me.set_circle_creator("fam".into(), me_hex.clone()));
    me.set_circle_live_lane("fam".into(), true); // mark a lane; inert until the circle keys live

    // ── Projection AFTER the flip must EQUAL the baseline — nothing wiped by enabling the switches. ──
    let circles_after: BTreeSet<(String, String)> =
        me.circles().iter().map(|c| (c.id.clone(), c.name.clone())).collect();
    assert_eq!(circles_after, circles_before, "circle set survives the flip");
    assert_eq!(circles_after, BTreeSet::from([
        ("default".to_string(), "My Circle".to_string()),
        ("fam".to_string(), "Family".to_string()),
    ]), "the exact migrated circles are present");
    assert_eq!(me.contact_node_ids("default".into()), default_members_before, "default membership intact");
    assert_eq!(me.contact_node_ids("fam".into()), fam_members_before, "fam membership intact");
    assert_eq!(default_members_before, vec![bob_hex.clone()], "default holds the migrated contact");
    assert_eq!(fam_members_before, vec![carol_hex], "fam holds the migrated contact");
    assert_eq!(bodies(&me, "default", 10_000), default_before, "default feed intact");
    assert_eq!(bodies(&me, "fam", 10_000), fam_before, "fam feed intact (circle isolation preserved)");
    assert_eq!(me.my_device_roster_wire(), roster_before, "device roster wire not clobbered by the flip");
    let my_post_after = me.feed("default".into(), 10_000, None)
        .into_iter().find(|f| f.body == "p-default-1").expect("my migrated post survives the flip");
    assert_eq!(my_post_after.media, my_post_before.media, "media ref survives verbatim");
    assert!(my_post_after.comments.iter().any(|c| c.body == "c-default-1"), "comment survives");
    assert!(my_post_after.is_me, "authorship survives");
    // Still a functioning engine after the flip.
    assert!(me.post("default".into(), "post-flip-authored".into(), vec![], None, None, false, false, 5_000).is_ok());
    assert!(bodies(&me, "default", 10_000).contains("post-flip-authored"), "engine authors after the flip");

    // ── Revive the migrated contact as a live, capable peer. The migrated contact is account(2);
    //    instantiate it live with a device. Cross-learn via the self-describing tagged roster wires
    //    exactly as a client does. `me` STILL carries its fixture {account, device 91} roster at this
    //    point — the account leaf has not been retired yet.
    let bob = account(2);
    assert!(bob.use_device_identity(vec![12u8; 32]));
    bob.add_contact_bundle("default".into(), me.my_bundle()).unwrap();

    let bob_wire = bob.register_device(bob.my_device_bundle(), "bob-dev".into(), 0);
    assert!(me.ingest_roster_wire(bob_wire));
    me.profile_seed_drop_version(bob.my_bundle(), capability_card(&bob, "bob"));
    bob.profile_seed_drop_version(me.my_bundle(), capability_card(&me, "me"));
    assert!(bob.set_circle_creator("default".into(), me_hex.clone()));
    bob.set_seed_drop_retire(true);
    bob.set_mls_keying(true);

    // ── (A) BEFORE retiring: `me` still carries the legacy {account, device 91} roster (account leaf
    //    present + authorized), so a fresh account-seed-only sibling still opens content — the migration
    //    never strands a seed holder while the fleet is converging (backward compatible).
    assert!(bob.ingest_roster_wire(me.my_device_roster_wire()), "bob learns the pre-retirement account-plus-device roster");
    let acct_only_before = account(1); // account(1) SEED only — no device key (a bare-seed sibling)
    acct_only_before.add_contact_bundle("default".into(), me.my_bundle()).unwrap();
    me.post("default".into(), "pre-retire-dual-seal".into(), vec![], None, None, false, false, 5_500).unwrap();
    sync(&me, &acct_only_before, "default");
    assert!(bodies(&acct_only_before, "default", 10_000).contains("pre-retire-dual-seal"),
            "pre-retirement the bare account key still opens content (the account leaf is still authorized)");

    // ── (B) RETIRE THE ACCOUNT LEAF — the migration action. `me`'s roster becomes device-only: the
    //    account id stays in `devices` (grow-only) but is no longer authorized, version-bumped + signed.
    assert!(!me.account_leaf_retired(), "not retired before the call");
    assert!(me.retire_account_leaf(), "a fully-capable primary retires its bare account leaf");
    assert!(me.account_leaf_retired(), "the account-leaf-retired flag is set on my own signed roster");
    assert!(bob.ingest_roster_wire(me.my_device_roster_wire()),
            "bob adopts the retired (higher-version) roster and drops my account leaf");

    let pair = [me.clone(), bob.clone()];
    flip_and_join(&pair, "default");
    // ── THE FIX: with the account leaf retired the migrated {account, device} roster reaches the
    //    device-only shape → the §7.2 all-joined gate completes → the circle flips to LIVE (previously
    //    it was stranded permanently at "shadow"). This is the assertion the FINDING said was unreachable.
    assert_eq!(me.mls_keying_status("default".into()).state, "live",
               "after retire_account_leaf the migrated circle reaches LIVE MLS keying (the fix)");
    assert_eq!(bob.mls_keying_status("default".into()).state, "live", "the revived peer is live too");

    // The migrated history is still readable to the revived peer, and new content round-trips — the
    // whole migration is content-preserving.
    sync_all(&[&me, &bob], "default", 4);
    assert!(bodies(&bob, "default", 10_000).contains("p-default-1"),
            "the revived peer reads pre-migration history");
    me.post("default".into(), "post-migration-content".into(), vec![], None, None, false, false, 6_000).unwrap();
    sync_all(&[&me, &bob], "default", 3);
    assert!(bodies(&bob, "default", 10_000).contains("post-migration-content"),
            "new content round-trips on the migrated, now-live circle");
    assert!(bodies(&me, "default", 10_000).is_superset(&default_before),
            "every pre-migration default post is still present after the whole transition");

    // ── (C) RETIREMENT CUTS THE ACCOUNT-SEED HOLDER: a fresh account-seed-only sibling — which read
    //    fine in (A) — can no longer obtain the (now device-only-keyed) post-retirement content, while
    //    bob's authorized device does. The bare account seed with no authorized device is cut off.
    let acct_only_after = account(1); // account(1) SEED only — no device key
    acct_only_after.add_contact_bundle("default".into(), me.my_bundle()).unwrap();
    sync(&me, &acct_only_after, "default");
    assert!(!bodies(&acct_only_after, "default", 10_000).contains("post-migration-content"),
            "after retirement the account-seed-only holder is cryptographically cut off (device-only keying)");
    assert!(bodies(&bob, "default", 10_000).contains("post-migration-content"),
            "the authorized device still reads post-retirement content");
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 2 — SEED-DROP RETIREMENT ON: content keyed device-only; an account-seed-only holder is cut
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// A fully-capable circle drops the account-key seal once retirement is ON: a fresh account-only
/// holder (seed but no device key) still reads while retirement is OFF (backward compatible), but is
/// cryptographically cut off once retirement flips ON in the fully-capable circle — while the
/// authorized DEVICE keeps reading.
///
/// Invariant asserted: the retirement switch is inert until the circle is fully capable AND the flag
/// is on; then, and only then, the bare account key leaves the sealing set — the migration never
/// strands account-only holders while the fleet is still converging.
#[test]
fn retirement_on_keys_device_only_and_cuts_the_account_seed_holder() {
    let cid = DEFAULT_CIRCLE;
    let alice = account(1);
    let bob = account(2); // Bob's device
    let acct_off = account(2); // fresh account-only witness for the OFF era
    let acct_on = account(2); // fresh account-only witness for the ON era
    alice.add_contact_bundle(cid.into(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();
    acct_off.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();
    acct_on.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();

    assert!(alice.use_device_identity(vec![98u8; 32]));
    assert!(bob.use_device_identity(vec![99u8; 32]));
    let (al_list, al_creds) = install_two_device_roster(&alice, [1u8; 32]);
    // Bob's fully-upgraded roster authorizes ONLY his device bundle (not the bare account) so the drop
    // path can exclude a seed-only holder.
    let bob_dev_id = hex_to_bytes(&bob.my_device_node_hex());
    let bob_dev_cred = issue_device_credential(vec![2u8; 32], bob.my_device_bundle(), "device".into(), 1).unwrap();
    let bo_list = sign_device_list(vec![2u8; 32], 1, 0, vec![bob_dev_id], vec![]).unwrap();
    let bo_creds = vec![bob_dev_cred];
    assert!(bob.set_my_device_roster(bo_list.clone(), bo_creds.clone()));
    assert!(bob.ingest_device_roster(alice.my_bundle(), al_list, al_creds));
    assert!(alice.ingest_device_roster(bob.my_bundle(), bo_list, bo_creds));
    sync(&bob, &alice, cid); // Bob's roster-wire capability trailer → Alice marks Bob capable

    // (1) Retirement OFF: dual-seal — a fresh account-only witness obtains the key and reads.
    alice.set_seed_drop_retire(false);
    alice.post(cid.into(), "dual-seal-era".into(), vec![], None, None, false, false, 1_000).unwrap();
    sync(&alice, &acct_off, cid);
    assert!(bodies(&acct_off, cid, 2_000).contains("dual-seal-era"),
            "gate OFF: the account key still opens content (backward compatible)");

    // (2) Retirement ON + fully capable: the bare account key is dropped. The fresh account-only
    //     witness is cut off; the authorized device still reads.
    alice.set_seed_drop_retire(true);
    alice.post(cid.into(), "device-only-era".into(), vec![], None, None, false, false, 3_000).unwrap();
    sync(&alice, &acct_on, cid);
    sync(&alice, &bob, cid);
    assert!(!bodies(&acct_on, cid, 4_000).contains("device-only-era"),
            "gate ON in a fully-capable circle: an account-only key can no longer obtain the epoch key");
    assert!(bodies(&bob, cid, 4_000).contains("device-only-era"), "the authorized device still opens it");
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 3 — MLS KEYING ON: content keyed by the tree; posts round-trip; KeyCommit stops
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// A fully-joined circle flips to tree-derived content keys once MLS keying is ON: the legacy
/// KeyCommit stops, posts from every member round-trip under the tree, and the shadow tree is
/// converged (equal tree hash, no fork) across the fleet.
///
/// Invariant asserted: OFF ⇒ the KeyCommit still keys content (byte-compatible with today); ON +
/// all-joined ⇒ every member reports `state == "live"` at the genesis epoch, `sync_envelopes` carries
/// NO KeyCommit, and posts round-trip with an identical converged tree hash across all members.
#[test]
fn mls_keying_on_flips_live_stops_keycommit_and_content_round_trips() {
    let cid = DEFAULT_CIRCLE;
    let insts = mls_capable_fleet(&[[1u8; 32], [2u8; 32], [3u8; 32]], &[[11u8; 32], [12u8; 32], [13u8; 32]], 0);
    let (a, b, c) = (insts[0].clone(), insts[1].clone(), insts[2].clone());

    // SWITCH OFF: shadow only — a KeyCommit is emitted and content flows (the legacy path).
    sync_all(&[&a, &b, &c], cid, 4);
    assert_ne!(a.mls_keying_status(cid.into()).state, "live", "off ⇒ not live");
    assert!(a.sync_envelopes(cid.into()).iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)),
            "off ⇒ KeyCommit still keys content");
    a.post(cid.into(), "legacy-keyed".into(), vec![], None, None, false, false, 900).unwrap();
    sync_all(&[&a, &b, &c], cid, 2);
    assert!(bodies(&b, cid, 1_000).contains("legacy-keyed"), "off-era content flows");

    // SWITCH ON + all-joined ⇒ LIVE everywhere, KeyCommit stops, tree keys content.
    flip_and_join(&insts, cid);
    for s in &insts {
        let ks = s.mls_keying_status(cid.into());
        assert_eq!(ks.state, "live", "every all-joined member flips live");
        assert_eq!(ks.epoch, 1, "at the genesis epoch");
    }
    assert!(a.sync_envelopes(cid.into()).iter().all(|e| e.first() != Some(&TAG_KEY_COMMIT)),
            "a live circle STOPS the KeyCommit (§4.5)");

    // Posts from two members round-trip to everyone under the tree.
    a.post(cid.into(), "tree-keyed".into(), vec![], None, None, false, false, 2_000).unwrap();
    b.post(cid.into(), "tree-keyed-from-b".into(), vec![], None, None, false, false, 2_100).unwrap();
    sync_all(&[&a, &b, &c], cid, 3);
    let expect = BTreeSet::from(["tree-keyed".to_string(), "tree-keyed-from-b".to_string()]);
    for s in &insts {
        assert!(bodies(s, cid, 3_000).is_superset(&expect), "every member reads both tree-keyed posts");
    }

    // The shadow tree converged across the fleet with an identical hash (single creator ⇒ no fork).
    let reference = a.mls_shadow_status(cid.into());
    assert!(reference.converged && reference.fork_count == 0 && !reference.tree_hash_hex.is_empty());
    for s in &insts {
        let st = s.mls_shadow_status(cid.into());
        assert!(st.converged, "shadow converged");
        assert_eq!(st.tree_hash_hex, reference.tree_hash_hex, "identical tree hash across the fleet");
    }
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 4 — CIRCLE-WIDE REMOVAL (the headline, enabled)
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// In a fully-joined, keying-LIVE circle a creator removes a device: it cannot derive the next epoch,
/// cannot open content posted after the Remove, and cannot re-enter (it is not an admin). A NON-admin's
/// attempt to author a Remove is rejected at the committer.
///
/// Invariant asserted: the creator's Remove advances the surviving fleet to the next epoch and
/// cryptographically cuts the removed device off all post-Remove content (while a remaining member
/// still reads), the removed non-admin cannot author a Remove to force its way back, AND a plain
/// member cannot author a Remove at all — authority is enforced.
#[test]
fn circle_removal_cuts_off_the_device_and_non_admin_removal_is_rejected() {
    let cid = DEFAULT_CIRCLE;
    // A is the creator; B stays; C is removed.
    let insts = mls_capable_fleet(&[[1u8; 32], [2u8; 32], [3u8; 32]], &[[11u8; 32], [12u8; 32], [13u8; 32]], 0);
    let (a, b, c) = (insts[0].clone(), insts[1].clone(), insts[2].clone());
    flip_and_join(&insts, cid);
    assert_eq!(a.mls_keying_status(cid.into()).state, "live");

    // CONTROL: pre-Remove content is readable by C.
    a.post(cid.into(), "before-removal".into(), vec![], None, None, false, false, 2_000).unwrap();
    sync_all(&[&a, &b, &c], cid, 3);
    assert!(bodies(&c, cid, 3_000).contains("before-removal"), "C reads pre-removal content");

    // A NON-ADMIN removal is rejected at the committer: B (a plain member) cannot author a Remove.
    let c_acct = acct_hex([3u8; 32]);
    assert!(!b.mls_remove_member(cid.into(), c_acct.clone()), "a non-admin cannot author a Remove");
    assert!(!c.circle_admins(cid.into()).contains(&c_acct), "C is not an admin");

    // The CREATOR removes C — a re-key (chained Remove + UpdatePath commit).
    assert!(a.mls_remove_member(cid.into(), c_acct.clone()), "the creator's Remove is authored");
    sync_all(&[&a, &b, &c], cid, 4);

    // A and B advanced to the new epoch; C is cut off (cannot derive it).
    assert_eq!(a.mls_keying_status(cid.into()).epoch, 2, "A re-keyed to epoch 2");
    assert_eq!(b.mls_keying_status(cid.into()).epoch, 2, "B re-keyed to epoch 2");
    assert_ne!(c.mls_keying_status(cid.into()).state, "live", "the removed device cannot derive the new epoch");

    // Post-Remove content: readable by B, NOT by C.
    a.post(cid.into(), "after-removal".into(), vec![], None, None, false, false, 4_000).unwrap();
    sync_all(&[&a, &b, &c], cid, 4);
    assert!(bodies(&b, cid, 5_000).contains("after-removal"), "a remaining member reads post-Remove content");
    assert!(!bodies(&c, cid, 5_000).contains("after-removal"),
            "the removed device CANNOT open content posted after the Remove");

    // C cannot re-enter: it is not an admin, so it cannot author an authorized Remove/Add.
    assert!(!c.mls_remove_member(cid.into(), c_acct.clone()),
            "a removed non-admin cannot author a tree Remove to force its way back");
    assert!(!c.circle_admins(cid.into()).contains(&c_acct), "the removed device is still not an admin");
}

/// Delegated authority (enabled): the creator grants a plain member admin; that member can then author
/// an accepted Remove that cuts the target off — proving `grant_circle_admin` composes with removal.
#[test]
fn creator_delegated_admin_can_remove_after_grant() {
    let cid = DEFAULT_CIRCLE;
    // A creator; B a plain member (to be delegated); C a bystander; D the removal target.
    let insts = mls_capable_fleet(
        &[[1u8; 32], [2u8; 32], [3u8; 32], [4u8; 32]],
        &[[11u8; 32], [12u8; 32], [13u8; 32], [14u8; 32]],
        0,
    );
    let (a, b, d) = (insts[0].clone(), insts[1].clone(), insts[3].clone());
    flip_and_join(&insts, cid);
    let b_acct = acct_hex([2u8; 32]);
    let d_acct = acct_hex([4u8; 32]);

    // Before the grant, B cannot remove D.
    assert!(!b.mls_remove_member(cid.into(), d_acct.clone()), "a non-admin cannot remove");

    // The creator delegates admin to B; the grant propagates.
    assert!(a.grant_circle_admin(cid.into(), b_acct.clone()), "the creator delegates admin to B");
    let refs: Vec<&Arc<HavenSocial>> = insts.iter().collect();
    sync_all(&refs, cid, 4);
    assert!(a.circle_admins(cid.into()).contains(&b_acct), "B is an admin after the grant");
    assert!(b.circle_admins(cid.into()).contains(&b_acct), "B learns it is an admin");

    // The delegated admin removes D — accepted, and D is cut off.
    assert!(b.mls_remove_member(cid.into(), d_acct.clone()), "a delegated admin authors a Remove");
    sync_all(&refs, cid, 5);
    a.post(cid.into(), "post-delegated-remove".into(), vec![], None, None, false, false, 6_000).unwrap();
    sync_all(&refs, cid, 4);
    assert!(bodies(&insts[2], cid, 7_000).contains("post-delegated-remove"), "a remaining member reads on");
    assert!(!bodies(&d, cid, 7_000).contains("post-delegated-remove"), "D is cut off by the delegated-admin Remove");
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 5 — SELF-SYNC REVOCATION (M1, enabled): rotate the self-sync key on revocation
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// After a device revocation the rotated self-sync key excludes the revoked device: it cannot open the
/// new (post-rotation) account state, and its stale-epoch write is rejected by an authorized device,
/// while authorized devices converge. With the switch OFF the path is byte-identical to today (legacy
/// v0, seed-derived, no epoch tag).
///
/// Invariant asserted: the rotation gate mirrors retirement exactly (ON + all-own-devices-capable ⇒
/// rotate); post-rotation, a revoked device holding only the stale key can neither READ the new state
/// nor have its WRITE accepted, and a still-authorized device reads the converged state.
#[test]
fn self_sync_revocation_rotates_key_and_cuts_the_revoked_device() {
    // The gate: rotate only when the switch is ON and every own device is seed-drop-capable.
    assert!(!self_sync_key_should_rotate(false, true), "switch OFF ⇒ no rotation (byte-identical)");
    assert!(!self_sync_key_should_rotate(true, false), "a non-capable own device keeps v0");
    assert!(self_sync_key_should_rotate(true, true), "fully capable + switch ON ⇒ rotate");

    let acct_seed = [1u8; 32];
    let account_bundle = account(1).my_bundle();
    let stays_seed = [98u8; 32]; // a device that stays authorized
    let revoked_seed = [97u8; 32]; // a device that will be revoked
    let stays_bundle = account(98).my_bundle();
    let revoked_bundle = account(97).my_bundle();
    let dev_id = |seed: [u8; 32]| hex_to_bytes(&account(seed[0]).my_node_hex());

    // ── Epoch 1: the primary grants the current self-sync key to BOTH devices. ──
    let k1 = mint_self_sync_key();
    let g1_stays = seal_self_sync_key_epoch_grant(acct_seed.to_vec(), stays_bundle.clone(), 1, k1.clone()).unwrap();
    let g1_revoked = seal_self_sync_key_epoch_grant(acct_seed.to_vec(), revoked_bundle.clone(), 1, k1.clone()).unwrap();
    let held_stays = open_self_sync_key_epoch_grant(stays_seed.to_vec(), account_bundle.clone(), g1_stays).unwrap();
    let held_revoked = open_self_sync_key_epoch_grant(revoked_seed.to_vec(), account_bundle.clone(), g1_revoked).unwrap();
    assert_eq!((held_stays.epoch, &held_stays.key), (1, &k1));
    assert_eq!((held_revoked.epoch, &held_revoked.key), (1, &k1), "both devices hold the epoch-1 key");

    // ── Revocation: mint a fresh key at epoch 2, re-grant it ONLY to the still-authorized device. ──
    let k2 = mint_self_sync_key();
    let g2_stays = seal_self_sync_key_epoch_grant(acct_seed.to_vec(), stays_bundle.clone(), 2, k2.clone()).unwrap();
    let held_stays2 = open_self_sync_key_epoch_grant(stays_seed.to_vec(), account_bundle.clone(), g2_stays).unwrap();
    assert_eq!((held_stays2.epoch, &held_stays2.key), (2, &k2));
    // The revoked device is NOT a grant recipient — it keeps only k1.

    // The primary seals the CURRENT account state under the epoch-2 key (retirement ON ⇒ no v0 seal).
    let st = AccountStateHandle::new();
    st.set("circle:home".into(), b"home".to_vec(), 10, dev_id(stays_seed)).unwrap();
    let post_rotation = seal_account_state_with_key_epoch(k2.clone(), 2, st).unwrap();
    assert_eq!(self_sync_key_epoch_of(post_rotation.clone()), Some(2), "the blob is stamped epoch 2");

    // (a) The revoked device (k1 only, v0 retired ⇒ empty seed_key) CANNOT open the post-rotation state.
    assert!(open_account_state_dual(post_rotation.clone(), 1, k1.clone(), vec![]).is_err(),
            "a revoked device cannot open account state sealed under the post-rotation key");
    // A still-authorized device (k2) opens it and converges.
    let opened = open_account_state_dual(post_rotation, 2, k2.clone(), vec![]).unwrap();
    assert_eq!(opened.get("circle:home".into()), Some(b"home".to_vec()), "an authorized device converges");

    // (b) The revoked device seals a NEWER-stamped write under its STALE key k1…
    let hijack = AccountStateHandle::new();
    hijack.set("circle:home".into(), b"HIJACK".to_vec(), 9_999, dev_id(revoked_seed)).unwrap();
    let revoked_write = seal_account_state_with_key_epoch(k1.clone(), 1, hijack).unwrap();
    // …and an authorized device (accepts only epoch 2, v0 retired) REJECTS it.
    assert!(open_account_state_dual(revoked_write, 2, k2.clone(), vec![]).is_err(),
            "an authorized device rejects the revoked device's stale-epoch write — the channel is cut");

    // ── Switch OFF ⇒ byte-identical to today: legacy v0 seal (no epoch tag), opens with the seed. ──
    let off = AccountStateHandle::new();
    off.set("profile".into(), b"me".to_vec(), 5, dev_id(stays_seed)).unwrap();
    let off_blob = seal_account_state(acct_seed.to_vec(), off).unwrap();
    assert_eq!(self_sync_key_epoch_of(off_blob.clone()), None, "OFF path is the untagged legacy v0 blob");
    let back = haven_ffi::multidevice::open_account_state(acct_seed.to_vec(), off_blob).unwrap();
    assert_eq!(back.get("profile".into()), Some(b"me".to_vec()), "OFF path round-trips unchanged");
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 6 — PER-MESSAGE DM FORWARD SECRECY ON: ratcheted DMs open out of order
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// DMs in a keying-live circle marked a live lane carry a MONOTONIC per-message ratchet index and open
/// even when delivered OUT OF ORDER (the receiver's skipped-key cache), while an UNMARKED circle stays
/// epoch-keyed (no ratchet — byte-identical to feed traffic).
///
/// Invariant asserted: with the lane marked, successive DMs carry ratchet indices 0,1,2…; delivered
/// tip-first with NO epoch-keyed backstop, every one still opens via the skipped-key cache; and a post
/// to the same live circle BEFORE the lane is marked carries NO ratchet index — the ratchet engages
/// only for the live lane. (Index N's key being independent of N-1's is the treekem.rs FS obligation;
/// here we prove the wire indices + the out-of-order open the mailbox contract needs.)
#[test]
fn dm_live_lane_ratchets_and_opens_out_of_order() {
    let cid = DEFAULT_CIRCLE;
    // A 2-party circle = a DM. Flip it live (tree-keyed content).
    let insts = mls_capable_fleet(&[[1u8; 32], [2u8; 32]], &[[11u8; 32], [12u8; 32]], 0);
    let (a, b) = (insts[0].clone(), insts[1].clone());
    flip_and_join(&insts, cid);
    assert_eq!(a.mls_keying_status(cid.into()).state, "live", "the pair is keying-live");

    // Live, but the circle is NOT yet a live lane → a post stays epoch-keyed (feed scope).
    let feedish = a.post(cid.into(), "not-a-dm".into(), vec![], None, None, false, false, 2_000).unwrap();
    assert_eq!(wire_ratchet_index(&feedish), None, "an unmarked circle is NOT ratcheted");

    // Mark the DM lane on both ends.
    a.set_circle_live_lane(cid.into(), true);
    b.set_circle_live_lane(cid.into(), true);

    // Each DM now carries a monotonically increasing ratchet index.
    let w0 = a.post(cid.into(), "dm-0".into(), vec![], None, None, false, false, 3_000).unwrap();
    let w1 = a.post(cid.into(), "dm-1".into(), vec![], None, None, false, false, 3_100).unwrap();
    let w2 = a.post(cid.into(), "dm-2".into(), vec![], None, None, false, false, 3_200).unwrap();
    assert_eq!(wire_ratchet_index(&w0), Some(0), "first DM is ratchet index 0");
    assert_eq!(wire_ratchet_index(&w1), Some(1), "second DM is ratchet index 1");
    assert_eq!(wire_ratchet_index(&w2), Some(2), "third DM is ratchet index 2");

    // OUT OF ORDER: deliver the ratcheted wires directly (NO sync, so no epoch-keyed backstop can mask
    // the ratchet path) in the shuffled order [w2, w0, w1]. The skipped-key cache opens every one.
    assert!(b.receive(cid.into(), w2).unwrap(), "the out-of-order tip (index 2) opens, caching 0..2");
    assert!(b.receive(cid.into(), w0).unwrap(), "the late index 0 opens from the skipped cache");
    assert!(b.receive(cid.into(), w1).unwrap(), "the late index 1 opens from the skipped cache");
    let feed = bodies(&b, cid, 4_000);
    for body in ["dm-0", "dm-1", "dm-2"] {
        assert!(feed.contains(body), "B reads {body} despite out-of-order delivery");
    }
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 7 — PCS: a committer leaf-Update heals an exfiltrated epoch (mechanism reachable publicly)
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// Post-compromise security: a committer's fresh UpdatePath (the same leaf-refresh the weekly cadence
/// piggybacks) advances the tree epoch and heals forward — a party holding only the pre-heal epoch's
/// material cannot open post-heal content, while the committer + remaining members keep reading and the
/// circle stays live.
///
/// Invariant asserted: after the committer's epoch-advancing UpdatePath, the surviving fleet is at
/// epoch n+1 and keeps round-tripping content, while a device frozen at epoch n (the exfiltration
/// stand-in — the removed leaf, whose stolen epoch-n state is all an attacker would hold) is
/// cryptographically unable to derive epoch n+1 and reads NOTHING authored after the heal.
///
/// NOTE: the clock-triggered *cadence* itself (§6.4) needs a 7-day wall-clock advance the crate only
/// permits under `#[cfg(test)]`, which is compiled out of an external test build; the cadence's timer
/// path + the internal exfiltrate/replay proof are covered by the in-crate
/// `mls_pcs_cadence_heals_committer_leaf_on_the_rotate_chokepoint`. Here we drive the identical heal
/// mechanism explicitly and assert its publicly-observable forward-secrecy consequence.
#[test]
fn pcs_committer_update_heals_forward_and_frozen_epoch_is_useless() {
    let cid = DEFAULT_CIRCLE;
    // A is the creator/committer; B stays; X is the "exfiltration stand-in" — a member whose only
    // secrets are the epoch-1 (pre-heal) material.
    let insts = mls_capable_fleet(&[[1u8; 32], [2u8; 32], [3u8; 32]], &[[11u8; 32], [12u8; 32], [13u8; 32]], 0);
    let (a, b, x) = (insts[0].clone(), insts[1].clone(), insts[2].clone());
    flip_and_join(&insts, cid);
    assert_eq!(a.mls_keying_status(cid.into()).epoch, 1, "the fleet is live at the genesis (compromised) epoch");

    // Epoch-1 (pre-heal) content is readable by X — establishing X holds live epoch-1 material.
    a.post(cid.into(), "epoch-1-content".into(), vec![], None, None, false, false, 2_000).unwrap();
    sync_all(&[&a, &b, &x], cid, 3);
    assert!(bodies(&x, cid, 3_000).contains("epoch-1-content"), "X holds working epoch-1 material");

    // HEAL: the committer authors a fresh UpdatePath that advances the epoch and refreshes its leaf —
    // the same commit the weekly PCS cadence emits, here driven by removing the stand-in X. After the
    // heal, X's epoch-1 secrets can derive NOTHING at epoch 2.
    let x_acct = acct_hex([3u8; 32]);
    assert!(a.mls_remove_member(cid.into(), x_acct), "the committer authors the leaf-refreshing UpdatePath");
    sync_all(&[&a, &b, &x], cid, 5);

    // Forward heal: A and B advanced to epoch 2 and stay live; X (frozen at epoch 1) cannot derive it.
    assert_eq!(a.mls_keying_status(cid.into()).epoch, 2, "the committer healed forward to epoch 2");
    assert_eq!(b.mls_keying_status(cid.into()).epoch, 2, "the remaining member converged on the healed epoch");
    assert_ne!(x.mls_keying_status(cid.into()).state, "live", "the frozen epoch-1 view cannot derive the healed epoch");

    // The circle keeps working across the heal; content authored after the heal round-trips for the
    // survivors, and the epoch-1-frozen party opens NONE of it (its stolen state is useless).
    a.post(cid.into(), "post-heal-content".into(), vec![], None, None, false, false, 4_000).unwrap();
    sync_all(&[&a, &b, &x], cid, 5);
    assert!(bodies(&b, cid, 5_000).contains("post-heal-content"), "the circle keeps working post-heal");
    assert!(!bodies(&x, cid, 5_000).contains("post-heal-content"),
            "the exfiltrated epoch-1 material opens NOTHING authored after the heal (PCS holds)");
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════
//  SCENARIO 8 — MIXED-VERSION SAFETY: the all-present-positive gate prevents premature activation
// ══════════════════════════════════════════════════════════════════════════════════════════════════

/// A circle with ONE legacy (non-capable) member stays on the legacy path even with every switch ON —
/// the all-present-positive gate refuses to activate MLS keying or retire the account key until the
/// WHOLE circle is capable, so everyone (including the legacy member) still reads. This is what makes
/// shipping the switches ON in 1.0.7 safe.
///
/// Invariant asserted: with a legacy member present, no member reports `state == "live"`, `sync_envelopes`
/// still carries the KeyCommit (legacy keying), a fresh account-only witness STILL reads even with
/// retirement ON (the account key is NOT dropped), and content round-trips to all — capable and legacy
/// alike. Then, when the straggler upgrades and joins, the same circle re-flips to live keying.
#[test]
fn mixed_version_circle_stays_legacy_until_fully_capable_then_reflips() {
    let cid = DEFAULT_CIRCLE;
    // A + B are fully capable; L is a legacy account (no device key, no capability marker).
    let a = account(1);
    let b = account(2);
    let l = account(9);
    let witness = account(2); // fresh account-only witness of the account key
    assert!(a.use_device_identity(vec![11u8; 32]));
    assert!(b.use_device_identity(vec![12u8; 32]));

    for (i, j) in [(&a, &b), (&a, &l), (&b, &l), (&b, &a), (&l, &a), (&l, &b)] {
        i.add_contact_bundle(cid.into(), j.my_bundle()).unwrap();
    }
    witness.add_contact_bundle(cid.into(), a.my_bundle()).unwrap();

    let (a_list, a_creds) = install_device_only_roster(&a, [1u8; 32]);
    let (b_list, b_creds) = install_device_only_roster(&b, [2u8; 32]);
    assert!(a.ingest_device_roster(b.my_bundle(), b_list.clone(), b_creds.clone()));
    assert!(b.ingest_device_roster(a.my_bundle(), a_list.clone(), a_creds.clone()));
    a.profile_seed_drop_version(b.my_bundle(), capability_card(&b, "b"));
    b.profile_seed_drop_version(a.my_bundle(), capability_card(&a, "a"));
    let creator_hex = a.my_node_hex();
    assert!(a.set_circle_creator(cid.into(), creator_hex.clone()));
    assert!(b.set_circle_creator(cid.into(), creator_hex.clone()));

    // EVERY switch ON — but the circle is NOT fully capable (L is legacy).
    for s in [&a, &b] {
        s.set_seed_drop_retire(true);
        s.set_mls_keying(true);
    }
    sync_all(&[&a, &b, &l], cid, 6);

    // The gate holds the circle on the legacy path: NOT live, KeyCommit still keys content.
    assert_ne!(a.mls_keying_status(cid.into()).state, "live",
               "a legacy member present ⇒ the all-present-positive gate refuses to flip live");
    assert!(a.sync_envelopes(cid.into()).iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)),
            "legacy keying (KeyCommit) is still in force");

    // Retirement is inert too: a fresh account-only witness STILL reads (the account key is not dropped).
    a.post(cid.into(), "mixed-post".into(), vec![], None, None, false, false, 1_000).unwrap();
    sync_all(&[&a, &b, &l], cid, 3);
    sync(&a, &witness, cid);
    assert!(bodies(&witness, cid, 2_000).contains("mixed-post"),
            "retirement is inert while mixed-version: the account key still opens content");
    // Everyone — capable and legacy — reads.
    assert!(bodies(&b, cid, 2_000).contains("mixed-post"), "the capable member reads");
    assert!(bodies(&l, cid, 2_000).contains("mixed-post"), "the LEGACY member still reads (safe migration)");
    l.post(cid.into(), "from-legacy".into(), vec![], None, None, false, false, 1_100).unwrap();
    sync_all(&[&a, &b, &l], cid, 3);
    assert!(bodies(&a, cid, 2_000).contains("from-legacy"), "the legacy member's content flows to a capable one");

    // ── The straggler UPGRADES + joins ⇒ the SAME circle now computes fully capable and re-flips live. ──
    assert!(l.use_device_identity(vec![19u8; 32]));
    let (l_list, l_creds) = install_device_only_roster(&l, [9u8; 32]);
    let up = [a.clone(), b.clone(), l.clone()];
    let wires = [(a_list, a_creds), (b_list, b_creds), (l_list, l_creds)];
    let bundles: Vec<Vec<u8>> = up.iter().map(|s| s.my_bundle()).collect();
    for i in 0..3 {
        for j in 0..3 {
            if i != j {
                let _ = up[i].ingest_device_roster(bundles[j].clone(), wires[j].0.clone(), wires[j].1.clone());
                up[i].profile_seed_drop_version(bundles[j].clone(), capability_card(&up[j], "m"));
            }
        }
    }
    assert!(l.set_circle_creator(cid.into(), creator_hex.clone()));
    l.set_seed_drop_retire(true);
    l.set_mls_keying(true);
    let up_refs: Vec<&Arc<HavenSocial>> = up.iter().collect();
    sync_all(&up_refs, cid, 10);

    assert_eq!(a.mls_keying_status(cid.into()).state, "live",
               "once the straggler is capable + joined, the SAME circle re-flips to live keying");
    a.post(cid.into(), "reflipped-content".into(), vec![], None, None, false, false, 6_000).unwrap();
    sync_all(&up_refs, cid, 4);
    assert!(bodies(&l, cid, 7_000).contains("reflipped-content"),
            "the upgraded straggler reads tree-keyed content after the re-flip");
    // Nothing from the legacy era was lost across the re-flip.
    assert!(bodies(&a, cid, 7_000).is_superset(&BTreeSet::from(["mixed-post".to_string(), "from-legacy".to_string()])),
            "legacy-era history survives the re-flip to live keying");
}
