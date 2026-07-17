//! REAL cross-version upgrade test (Part B): genuine on-disk state produced by the SHIPPED 1.0.6 code
//! (`core/p2pcore-ffi`, v1.0.6 tag) is loaded and verified by 1.0.7 (`haven-ffi`).
//!
//! This is NOT a synthetic in-test fixture: the bytes in `tests/fixtures/real_106_state.bin` were
//! written by `1.0.6`'s `HavenSocial::export_state()` over its OWN public FFI (see the generator at
//! `/private/tmp/claude-501/haven-106/core/p2pcore-ffi/tests/gen_real_106_state.rs`). The sibling
//! `tests/fixtures/real_106_manifest.json` records EXACTLY what 1.0.6 created, so this test asserts
//! exact survival — the absence-as-deletion guard against REAL upgrader data.
//!
//! It then drives the ENABLED 1.0.7 upgrade on those real bytes: flip the dark switches
//! (seed-drop retirement + MLS keying), `retire_account_leaf`, and prove the migrated real account
//! reaches LIVE MLS keying and that retirement cuts a device — WITHOUT losing any 1.0.6 content.
//!
//! Run:
//!     export PATH="$HOME/.cargo/bin:$PATH"
//!     cd core && cargo test -p haven_ffi --test real_upgrade -- --nocapture --test-threads=1

mod common;
use common::*;

use std::collections::BTreeSet;
use std::sync::Arc;

use haven_ffi::HavenSocial;
use serde_json::Value;

const NOW: u64 = 10_000_000;

// ── Public-API sync drivers (twins of the migration_harness helpers). ────────────────────────────

fn sync(from: &HavenSocial, to: &HavenSocial, cid: &str) {
    for env in from.sync_envelopes(cid.to_string()) {
        let _ = to.receive(cid.to_string(), env);
    }
}
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
fn flip_and_join(insts: &[&Arc<HavenSocial>], cid: &str) {
    for s in insts {
        s.set_mls_keying(true);
    }
    sync_all(insts, cid, 6);
}
fn bodies(s: &HavenSocial, cid: &str) -> BTreeSet<String> {
    s.feed(cid.to_string(), NOW, None).into_iter().map(|f| f.body).collect()
}

// ── Fixture loaders (the REAL 1.0.6 bytes + manifest). ───────────────────────────────────────────

fn load_real_state() -> Vec<u8> {
    std::fs::read(fixtures_dir().join("real_106_state.bin")).expect("real_106_state.bin present")
}
fn load_manifest() -> Value {
    let raw = std::fs::read(fixtures_dir().join("real_106_manifest.json")).expect("manifest present");
    serde_json::from_slice(&raw).expect("manifest is valid JSON")
}
fn strs(v: &Value) -> Vec<String> {
    v.as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect()
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════
//  (1)+(2)  REAL 1.0.6 STATE LOADS INTO 1.0.7 AND EVERY MANIFEST ITEM SURVIVES EXACTLY
// ═══════════════════════════════════════════════════════════════════════════════════════════════════

/// Load the REAL 1.0.6 `export_state()` bytes into a fresh 1.0.7 engine under the SAME identity 1.0.6
/// authored them with (account seed 1 + device seed 91, per the manifest), and assert that EVERY item
/// the 1.0.6 generator recorded survived exactly: all circles + names, all members, all posts
/// (id + body + media + authorship), the comment, every reaction, the DM thread + its messages, and
/// the legacy {account, device} roster. Nothing dropped, nothing corrupted.
#[test]
fn real_106_state_loads_into_107_with_exact_fidelity() {
    let m = load_manifest();

    // Identity from the manifest's recorded seeds (proves the seeds are what the fixture claims).
    let acct_seed = strs_to_seed(&m["me"]["account_seed"]);
    let dev_seed = strs_to_seed(&m["me"]["device_seed"]);
    assert_eq!(acct_seed, [1u8; 32], "manifest account seed");
    assert_eq!(dev_seed, [91u8; 32], "manifest device seed");

    let me = HavenSocial::new(acct_seed.to_vec()).unwrap();
    assert!(me.use_device_identity(dev_seed.to_vec()));

    // THE REAL LOAD: 1.0.7 `import_state` over bytes 1.0.6 wrote. If the format broke, this loses data.
    me.import_state(load_real_state());

    let me_hex = me.my_node_hex();
    assert_eq!(me_hex, m["me"]["account_hex"].as_str().unwrap(), "account id matches manifest");
    assert_eq!(me.my_device_node_hex(), m["me"]["device_hex"].as_str().unwrap(), "device id matches manifest");

    // ── Circles + names: exactly the manifest set. ──
    let want_circles: BTreeSet<(String, String)> = m["circles"].as_array().unwrap().iter()
        .map(|c| (c["id"].as_str().unwrap().to_string(), c["name"].as_str().unwrap().to_string()))
        .collect();
    let got_circles: BTreeSet<(String, String)> =
        me.circles().iter().map(|c| (c.id.clone(), c.name.clone())).collect();
    assert_eq!(got_circles, want_circles, "the exact 1.0.6 circle set + names survived");

    // ── Membership per circle: exact, order-preserved. ──
    for c in m["circles"].as_array().unwrap() {
        let id = c["id"].as_str().unwrap();
        assert_eq!(me.contact_node_ids(id.into()), strs(&c["members"]), "members of circle {id} survived");
    }

    // ── Posts: id + body + media + authorship, in the right circle. ──
    for p in m["posts"].as_array().unwrap() {
        let (cid, body, id) =
            (p["circle"].as_str().unwrap(), p["body"].as_str().unwrap(), p["id"].as_str().unwrap());
        let feed = me.feed(cid.into(), NOW, None);
        let item = feed.iter().find(|f| f.body == body)
            .unwrap_or_else(|| panic!("post {body:?} missing from {cid}"));
        assert_eq!(item.id, id, "post {body:?} kept its 1.0.6 event id");
        assert_eq!(item.media, strs(&p["media"]), "post {body:?} kept its media ref(s) verbatim");
        assert!(item.is_me, "post {body:?} reads back as mine (authorship preserved)");
    }

    // ── Comment: on its target post, media intact. ──
    for cm in m["comments"].as_array().unwrap() {
        let (cid, pid, body) =
            (cm["circle"].as_str().unwrap(), cm["post_id"].as_str().unwrap(), cm["body"].as_str().unwrap());
        let feed = me.feed(cid.into(), NOW, None);
        let post = feed.iter().find(|f| f.id == pid).unwrap_or_else(|| panic!("comment target {pid} missing"));
        let comment = post.comments.iter().find(|c| c.body == body)
            .unwrap_or_else(|| panic!("comment {body:?} missing"));
        assert_eq!(comment.media, strs(&cm["media"]), "comment {body:?} kept its media");
        assert!(comment.is_me, "comment {body:?} authorship preserved");
    }

    // ── Reactions: each survives on its target, attributed to me. ──
    for r in m["reactions"].as_array().unwrap() {
        let (cid, pid, emoji) =
            (r["circle"].as_str().unwrap(), r["post_id"].as_str().unwrap(), r["emoji"].as_str().unwrap());
        let feed = me.feed(cid.into(), NOW, None);
        let post = feed.iter().find(|f| f.id == pid).unwrap_or_else(|| panic!("reaction target {pid} missing"));
        assert!(post.reactions.iter().any(|x| x.emoji == emoji && x.mine),
                "reaction {emoji:?} on {pid} survived and is attributed to me");
    }

    // ── DM thread: the dm: circle, its member, and every message (id + body). ──
    let dm = &m["dm"];
    let dm_id = dm["circle"].as_str().unwrap();
    assert_eq!(me.contact_node_ids(dm_id.into()), strs(&dm["members"]), "DM peer membership survived");
    let dm_feed = me.feed(dm_id.into(), NOW, None);
    for msg in dm["messages"].as_array().unwrap() {
        let (body, id) = (msg["body"].as_str().unwrap(), msg["id"].as_str().unwrap());
        let item = dm_feed.iter().find(|f| f.body == body)
            .unwrap_or_else(|| panic!("DM message {body:?} missing"));
        assert_eq!(item.id, id, "DM message {body:?} kept its 1.0.6 event id");
        assert!(item.is_me, "DM message {body:?} authorship preserved");
    }

    // ── Device roster: the legacy {account, device} shape restored, re-verified. ──
    assert!(!me.my_device_roster_wire().is_empty(), "the two-device roster wire rebuilt on import");
    let want_devs: BTreeSet<String> = strs(&m["device_roster"]["device_ids"]).into_iter().collect();
    let got_devs: BTreeSet<String> = me.device_node_ids_for(me_hex.clone()).into_iter().collect();
    assert_eq!(got_devs, want_devs,
               "the legacy {{account, device}} roster (the exact upgrader shape) survived import");
}

fn strs_to_seed(v: &Value) -> [u8; 32] {
    let bytes: Vec<u8> = v.as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect();
    bytes.try_into().expect("32-byte seed in manifest")
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════
//  (3)  THE ENABLED UPGRADE ON REAL BYTES: flip switches → retire account leaf → LIVE MLS keying,
//       nothing lost, and retirement cuts a device.
// ═══════════════════════════════════════════════════════════════════════════════════════════════════

/// Drive the full ENABLED 1.0.7 upgrade on the REAL 1.0.6 state: turn on seed-drop retirement + MLS
/// keying (must lose NOTHING), revive the migrated DM peer as a live capable device, `retire_account_leaf`
/// (the existing-upgrader migration the whole release hinges on), and prove the migrated real DM circle
/// reaches LIVE MLS keying — while every 1.0.6 post/comment/reaction/DM message is still present, new
/// content round-trips, and retirement cryptographically cuts a bare-account-seed holder that read fine
/// before it (a real revocation on real bytes).
#[test]
fn real_106_state_reaches_live_mls_keying_and_retirement_cuts_a_device_losslessly() {
    let m = load_manifest();
    let me = account(1);
    assert!(me.use_device_identity(vec![91u8; 32]));
    me.import_state(load_real_state());
    let me_hex = me.my_node_hex();

    let dm_id = m["dm"]["circle"].as_str().unwrap().to_string();
    let bob_hex = m["peers"]["bob"].as_str().unwrap().to_string();

    // ── Baseline projections BEFORE the flip (the migration invariant to preserve across ALL circles). ──
    let all_circle_ids: Vec<String> =
        m["circles"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap().to_string()).collect();
    let circles_before: BTreeSet<(String, String)> =
        me.circles().iter().map(|c| (c.id.clone(), c.name.clone())).collect();
    let feeds_before: Vec<(String, BTreeSet<String>)> =
        all_circle_ids.iter().map(|id| (id.clone(), bodies(&me, id))).collect();
    let members_before: Vec<(String, Vec<String>)> =
        all_circle_ids.iter().map(|id| (id.clone(), me.contact_node_ids(id.clone()))).collect();
    let roster_before = me.my_device_roster_wire();
    let dm_bodies_before = bodies(&me, &dm_id);
    assert!(dm_bodies_before.contains("dm-hello"), "the real DM thread is present pre-flip");

    // ── FLIP EVERYTHING ON (global switches + pin creators on every migrated circle). ──
    me.set_seed_drop_retire(true);
    me.set_mls_keying(true);
    for id in &all_circle_ids {
        assert!(me.set_circle_creator(id.clone(), me_hex.clone()), "pin creator on {id}");
    }

    // ── The flip must WIPE NOTHING — exact equality against the pre-flip baseline. ──
    let circles_after: BTreeSet<(String, String)> =
        me.circles().iter().map(|c| (c.id.clone(), c.name.clone())).collect();
    assert_eq!(circles_after, circles_before, "circle set survives the switch flip");
    for (id, want) in &feeds_before {
        assert_eq!(&bodies(&me, id), want, "circle {id} feed intact after the flip");
    }
    for (id, want) in &members_before {
        assert_eq!(&me.contact_node_ids(id.clone()), want, "circle {id} membership intact after the flip");
    }
    assert_eq!(me.my_device_roster_wire(), roster_before, "roster wire not clobbered by the flip");
    // Media ref + comment on the real p-default-1 post still present after the flip.
    let pd1 = me.feed("default".into(), NOW, None).into_iter().find(|f| f.body == "p-default-1").unwrap();
    assert_eq!(pd1.media, vec!["media/ref-abc".to_string()], "media ref survives the flip verbatim");
    assert!(pd1.comments.iter().any(|c| c.body == "c-default-1"), "comment survives the flip");
    // Still a functioning engine.
    assert!(me.post("fam".into(), "post-flip-authored".into(), vec![], None, None, false, false, 5_000).is_ok());
    assert!(bodies(&me, "fam").contains("post-flip-authored"), "engine authors after the flip");

    // ── Revive the migrated DM peer (bob = account(2)) as a live, capable device. ──
    let bob = account(2);
    assert!(bob.use_device_identity(vec![12u8; 32]));
    assert_eq!(bob.my_node_hex(), bob_hex, "revived peer matches the migrated DM contact");
    // A fresh engine is born with only the default circle; the DM circle is created on both ends
    // (the app does this when a DM is opened), so bob can be a member of it.
    bob.create_circle(dm_id.clone(), "DM with Blaine".into());
    bob.add_contact_bundle(dm_id.clone(), me.my_bundle()).unwrap();

    let bob_wire = bob.register_device(bob.my_device_bundle(), "bob-dev".into(), 0);
    assert!(me.ingest_roster_wire(bob_wire), "me learns bob's device-only roster");
    me.profile_seed_drop_version(bob.my_bundle(), capability_card(&bob, "bob"));
    bob.profile_seed_drop_version(me.my_bundle(), capability_card(&me, "me"));
    assert!(bob.set_circle_creator(dm_id.clone(), me_hex.clone()));
    bob.set_seed_drop_retire(true);
    bob.set_mls_keying(true);

    // ── (A) BEFORE retiring: me still carries the legacy {account, device 91} roster, so a fresh
    //    account-seed-only sibling still opens content (backward compatible — no seed holder stranded). ──
    assert!(bob.ingest_roster_wire(me.my_device_roster_wire()), "bob learns the pre-retirement account+device roster");
    let acct_only_before = account(1); // account(1) SEED only — no device key
    acct_only_before.create_circle(dm_id.clone(), "DM".into());
    acct_only_before.add_contact_bundle(dm_id.clone(), me.my_bundle()).unwrap();
    me.post(dm_id.clone(), "pre-retire-dual-seal".into(), vec![], None, None, false, false, 5_500).unwrap();
    sync(&me, &acct_only_before, &dm_id);
    assert!(bodies(&acct_only_before, &dm_id).contains("pre-retire-dual-seal"),
            "pre-retirement the bare account key still opens content (account leaf still authorized)");

    // ── (B) RETIRE THE ACCOUNT LEAF — the existing-upgrader migration action. ──
    assert!(!me.account_leaf_retired(), "not retired before the call");
    assert!(me.retire_account_leaf(), "a fully-capable migrated primary retires its bare account leaf");
    assert!(me.account_leaf_retired(), "the account-leaf-retired flag is set on my own signed roster");
    assert!(bob.ingest_roster_wire(me.my_device_roster_wire()),
            "bob adopts the higher-version retired roster and drops my account leaf");

    // With the account leaf retired the migrated {account, device} roster reaches the device-only shape,
    // the all-joined gate completes, and the REAL migrated DM circle flips to LIVE MLS keying.
    flip_and_join(&[&me, &bob], &dm_id);
    assert_eq!(me.mls_keying_status(dm_id.clone()).state, "live",
               "after retire_account_leaf the migrated real DM circle reaches LIVE MLS keying");
    assert_eq!(bob.mls_keying_status(dm_id.clone()).state, "live", "the revived peer is live too");

    // ── Content-preserving: the real 1.0.6 DM messages are still readable, and new content round-trips. ──
    sync_all(&[&me, &bob], &dm_id, 4);
    for body in ["dm-hello", "dm-how-are-you", "dm-see-you-soon"] {
        assert!(bodies(&bob, &dm_id).contains(body), "revived peer reads pre-migration DM message {body:?}");
    }
    me.post(dm_id.clone(), "post-migration-dm".into(), vec![], None, None, false, false, 6_000).unwrap();
    sync_all(&[&me, &bob], &dm_id, 3);
    assert!(bodies(&bob, &dm_id).contains("post-migration-dm"), "new content round-trips on the now-live migrated DM");
    assert!(bodies(&me, &dm_id).is_superset(&dm_bodies_before),
            "every pre-migration DM message is still present after the whole transition");

    // Every OTHER migrated circle's 1.0.6 content is still intact after reaching live on the DM.
    for (id, want) in &feeds_before {
        if id != &dm_id {
            assert!(bodies(&me, id).is_superset(want), "circle {id} keeps all its 1.0.6 content post-upgrade");
        }
    }

    // ── (C) REVOCATION CUTS A DEVICE: the bare account-seed sibling that read fine in (A) can no longer
    //    obtain the now device-only-keyed post-retirement content, while bob's authorized device does. ──
    let acct_only_after = account(1); // account(1) SEED only — no device key
    acct_only_after.create_circle(dm_id.clone(), "DM".into());
    acct_only_after.add_contact_bundle(dm_id.clone(), me.my_bundle()).unwrap();
    sync(&me, &acct_only_after, &dm_id);
    assert!(!bodies(&acct_only_after, &dm_id).contains("post-migration-dm"),
            "after retirement the account-seed-only holder is cryptographically cut off (device-only keying)");
    assert!(bodies(&bob, &dm_id).contains("post-migration-dm"),
            "the authorized device still reads post-retirement content");
}
