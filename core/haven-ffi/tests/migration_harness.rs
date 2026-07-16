//! Tier-1 core migration + regression harness for Haven.
//!
//! The automated gate that proves the low-level seed-drop / MLS-shadow architecture changes do NOT lose or
//! corrupt an existing user's data on upgrade. Everything runs through the crate's PUBLIC API only (the same
//! entry points the apps call), and every assertion is deterministic — fixed 32-byte seeds, fixed
//! timestamps, no wall-clock or RNG.
//!
//! Run it (the command a human runs, no AI involved):
//!
//!     export PATH="$HOME/.cargo/bin:$PATH"
//!     cargo test -p haven_ffi --test migration_harness
//!
//! (Regenerate the golden fixtures deliberately — only when the on-disk format is intended to change — with
//!  `cargo test -p haven_ffi --test gen_fixtures -- --ignored`.)
//!
//! Two failure classes it catches:
//!   (a) persisted-state serialization breakage across versions — the golden fixtures + round-trip tests;
//!   (b) seed-drop/MLS migration regressions where existing content/rosters/circles/contacts would be
//!       dropped or become unreadable on upgrade — the end-to-end scenarios.

mod common;
use common::*;

use std::collections::BTreeSet;

use haven_ffi::HavenSocial;

/// Deliver everything `from` authored in `cid` to `to`, exactly as the platform's sync/hello does (the key
/// commit teaches `to` the sender's epoch key, then the epoch events open). Public-API twin of the in-crate
/// `sync` helper.
fn sync(from: &HavenSocial, to: &HavenSocial, cid: &str) {
    for env in from.sync_envelopes(cid.to_string()) {
        let _ = to.receive(cid.to_string(), env);
    }
}

/// Feed bodies as a set, for order-independent equality.
fn bodies(s: &HavenSocial, cid: &str, now: u64) -> BTreeSet<String> {
    s.feed(cid.to_string(), now, None).into_iter().map(|f| f.body).collect()
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════
//  (a) GOLDEN SERIALIZED-STATE FIXTURES  — forward-compat tripwires
// ═══════════════════════════════════════════════════════════════════════════════════════════════════════

/// TRIPWIRE — load the frozen current-format state of a multi-circle account (contacts, a device roster, a
/// post carrying a media ref, an ingested peer post, a comment, a second circle) into today's engine and
/// assert FULL FIDELITY: every circle, member, event, and the device roster is restored intact.
///
/// Invariant asserted: `import_state(golden_bytes)` reconstructs the exact circle set, per-circle
/// membership, feed content (bodies + authorship + media ref + comment), and device roster. If a future
/// serialization change drops or reshapes any persisted field, loading this OLD fixture loses data and this
/// test fails loudly with what went missing.
#[test]
fn golden_multicircle_restores_with_full_fidelity() {
    // A fresh primary with the SAME identity the fixture was authored under (seed 1 + device 91), so its own
    // posts read back as `is_me` and its roster rebuilds.
    let me = account(1);
    assert!(me.use_device_identity(vec![91u8; 32]));
    me.import_state(load_fixture("account_multicircle.b64"));

    // Expected peer ids, recomputed from seeds (never hard-coded hex).
    let bob_hex = account(2).my_node_hex();
    let carol_hex = account(3).my_node_hex();

    // Circles: exactly {default, fam} with their names restored.
    let circles = me.circles();
    let ids: BTreeSet<String> = circles.iter().map(|c| c.id.clone()).collect();
    assert_eq!(ids, BTreeSet::from(["default".to_string(), "fam".to_string()]), "both circles restored");
    let name_of = |id: &str| circles.iter().find(|c| c.id == id).unwrap().name.clone();
    assert_eq!(name_of("default"), "My Circle");
    assert_eq!(name_of("fam"), "Family");

    // Membership restored per circle (members hold contacts, not self).
    assert_eq!(me.contact_node_ids("default".into()), vec![bob_hex.clone()], "default membership restored");
    assert_eq!(me.contact_node_ids("fam".into()), vec![carol_hex], "fam membership restored");

    // Feed content restored with fidelity: my post (is_me, media ref intact, one comment) + the ingested
    // peer post (not me), and the fam post in its own circle.
    let default_feed = me.feed("default".into(), 10_000, None);
    let mine = default_feed.iter().find(|f| f.body == "p-default-1").expect("my post survives");
    assert!(mine.is_me, "authorship restored — my post reads as mine");
    assert_eq!(mine.media, vec!["media/ref-abc".to_string()], "the post's media ref survives verbatim");
    assert!(mine.comments.iter().any(|c| c.body == "c-default-1"), "the comment on my post survives");
    let peer = default_feed.iter().find(|f| f.body == "b-default-1").expect("ingested peer post survives");
    assert!(!peer.is_me, "the peer post is attributed to the peer, not me");

    let fam_feed = me.feed("fam".into(), 10_000, None);
    assert!(fam_feed.iter().any(|f| f.body == "p-fam-1" && f.is_me), "fam post restored in its own circle");
    assert!(!fam_feed.iter().any(|f| f.body == "p-default-1"), "circle isolation preserved across restore");

    // Device roster restored: my own roster wire rebuilds from the persisted `device_rosters`.
    assert!(!me.my_device_roster_wire().is_empty(), "my two-device roster survives the restore");
}

/// TRIPWIRE (oldest schema) — load a `LegacyPersistState` `{events, contacts}` fixture (predates
/// multi-circle support) and prove FORWARD-MIGRATION into the default circle: the legacy events + contacts
/// land intact, nothing is wiped, and the account is otherwise a normal engine afterward.
///
/// Invariant asserted: the legacy fallback path in `import_state` migrates every legacy event/contact into
/// the default circle with no loss (the absence-as-deletion guard — an older, smaller schema never erases
/// data).
#[test]
fn golden_legacy_v0_migrates_into_default_circle() {
    let me = account(1);
    me.import_state(load_fixture("legacy_v0.b64"));

    let bob_hex = account(2).my_node_hex();
    // Legacy contacts migrate into the default circle.
    assert!(me.contact_node_ids("default".into()).contains(&bob_hex), "legacy contact migrated");
    // Legacy events migrate into the default circle's feed.
    let feed = bodies(&me, "default", 10_000);
    assert!(feed.contains("p-default-1"), "legacy event migrated (my post)");
    assert!(feed.contains("b-default-1"), "legacy event migrated (peer post)");
    // The migrated account is still a functioning engine — it can author into the migrated circle.
    assert!(me.post("default".into(), "post-migration".into(), vec![], None, None, false, false, 5_000).is_ok());
    assert!(bodies(&me, "default", 10_000).contains("post-migration"), "engine works after legacy migration");
}

/// TRIPWIRE (older PersistState schema) — load a multi-circle fixture from BEFORE epoch keys / device
/// rosters / seedless wire existed (every `#[serde(default)]` field simply absent) and prove the missing
/// fields default safely: circles, members, and events all restore; nothing is wiped.
///
/// Invariant asserted: a state file missing the newer fields loads without error and without data loss —
/// the `#[serde(default)]` forward-migration is intact. This is the direct guard against a future field
/// being added in a way that makes older state files fail to parse (which would silently wipe a user on
/// upgrade).
#[test]
fn golden_pre_epoch_schema_defaults_missing_fields_safely() {
    let me = account(1);
    me.import_state(load_fixture("pre_epoch.b64"));

    let bob_hex = account(2).my_node_hex();
    let carol_hex = account(3).my_node_hex();

    // Circles + membership + events all survive despite the absent epoch/roster fields.
    let ids: BTreeSet<String> = me.circles().iter().map(|c| c.id.clone()).collect();
    assert_eq!(ids, BTreeSet::from(["default".to_string(), "fam".to_string()]), "circles restored from old schema");
    assert_eq!(me.contact_node_ids("default".into()), vec![bob_hex]);
    assert_eq!(me.contact_node_ids("fam".into()), vec![carol_hex]);
    assert!(bodies(&me, "default", 10_000).contains("p-default-1"), "events survive the field-absent load");
    assert!(bodies(&me, "fam", 10_000).contains("p-fam-1"), "second circle's events survive too");

    // The account can still author after loading old-schema state (defaulted epoch bootstraps on next post).
    assert!(me.post("default".into(), "after-old-load".into(), vec![], None, None, false, false, 5_000).is_ok());
    assert!(bodies(&me, "default", 10_000).contains("after-old-load"));
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════
//  (a) ROUND-TRIP INVARIANTS  — non-deterministic-persistence tripwire
// ═══════════════════════════════════════════════════════════════════════════════════════════════════════

/// INVARIANT — for a minimal account (one circle, one contact, one authored post; every persisted HashMap
/// holds at most one entry), `export → import → export` is BYTE-IDENTICAL. This is the tripwire for
/// non-deterministic persistence creeping into the simple case: if a future change serialized an unordered
/// collection into even a one-entry state, this catches it.
#[test]
fn roundtrip_minimal_is_byte_identical() {
    let alice = account(1);
    let bob = account(2);
    alice.add_contact_bundle(DEFAULT_CIRCLE.into(), bob.my_bundle()).unwrap();
    alice.post(DEFAULT_CIRCLE.into(), "only-post".into(), vec![], None, None, false, false, 1_000).unwrap();

    let first = alice.export_state();
    let reloaded = account(1);
    reloaded.import_state(first.clone());
    let second = reloaded.export_state();

    assert_eq!(first, second, "minimal state round-trips byte-for-byte (deterministic persistence)");
}

/// INVARIANT — a RICH account (device roster + multiple circles + peer content, i.e. several HashMap-backed
/// collections) is SEMANTICALLY STABLE across a full `export → import → export → import`: the two reloaded
/// engines project identical circles, membership, and feeds. (Raw bytes may reorder — the engine persists
/// HashMap-backed arrays, whose iteration order is per-instance; see the migration-risk note in the harness
/// summary. This test asserts the property that actually matters for migration: no data changes across the
/// round trip.)
#[test]
fn roundtrip_rich_is_semantically_stable() {
    // Build a rich state.
    let me = account(1);
    let bob = account(2);
    assert!(me.use_device_identity(vec![91u8; 32]));
    me.add_contact_bundle(DEFAULT_CIRCLE.into(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(DEFAULT_CIRCLE.into(), me.my_bundle()).unwrap();
    me.post(DEFAULT_CIRCLE.into(), "mine-1".into(), vec!["media/x".into()], None, None, false, false, 1_000).unwrap();
    bob.post(DEFAULT_CIRCLE.into(), "bobs-1".into(), vec![], None, None, false, false, 1_100).unwrap();
    sync(&bob, &me, DEFAULT_CIRCLE);
    install_two_device_roster(&me, [1u8; 32]);
    me.create_circle("fam".into(), "Family".into());
    me.add_contact_bundle("fam".into(), account(3).my_bundle()).unwrap();
    me.post("fam".into(), "fam-1".into(), vec![], None, None, false, false, 2_000).unwrap();

    // Two independent reloads from the same export.
    let exported = me.export_state();
    let r1 = account(1);
    r1.use_device_identity(vec![91u8; 32]);
    r1.import_state(exported.clone());
    let r2 = account(1);
    r2.use_device_identity(vec![91u8; 32]);
    r2.import_state(r1.export_state()); // a SECOND generation of export→import

    // Same projection out of both generations.
    let proj = |s: &HavenSocial| {
        let circles: BTreeSet<(String, String)> =
            s.circles().iter().map(|c| (c.id.clone(), c.name.clone())).collect();
        let default_members: BTreeSet<String> = s.contact_node_ids("default".into()).into_iter().collect();
        let fam_members: BTreeSet<String> = s.contact_node_ids("fam".into()).into_iter().collect();
        (circles, default_members, fam_members, bodies(s, "default", 10_000), bodies(s, "fam", 10_000))
    };
    assert_eq!(proj(&r1), proj(&r2), "state is semantically identical across two export/import generations");
    // And it matches the original, live engine's projection — no drift on the very first restore.
    assert_eq!(proj(&r1), proj(&me), "first restore matches the live source engine exactly");
    // Device roster survived both generations.
    assert!(!r2.my_device_roster_wire().is_empty(), "device roster survives repeated round-trips");
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════
//  (b) END-TO-END MIGRATION / REGRESSION SCENARIOS
// ═══════════════════════════════════════════════════════════════════════════════════════════════════════

/// SCENARIO — a LEGACY peer (no device identity, no capability) and an UPGRADED peer (device identity +
/// seed-drop/MLS-capable) share a circle. Content flows BOTH directions across sync/backfill; the legacy
/// peer then upgrades MID-STREAM and every already-delivered post remains readable, plus new content flows.
///
/// Invariant asserted: mixed-version interop is total. The upgraded peer's dual-seal keeps the legacy peer
/// reading; the legacy peer's account-signed content stays readable to the upgraded peer; and upgrading a
/// peer never drops history — the exact feed sets on both sides are asserted before and after the flip.
#[test]
fn legacy_and_upgraded_peer_interop_both_directions_and_upgrade_keeps_history() {
    let cid = DEFAULT_CIRCLE;
    let up = account(1); // upgraded from the start
    let legacy = account(2); // legacy: never adopts a device or advertises capability… until mid-stream
    assert!(up.use_device_identity(vec![91u8; 32]));
    up.add_contact_bundle(cid.into(), legacy.my_bundle()).unwrap();
    legacy.add_contact_bundle(cid.into(), up.my_bundle()).unwrap();
    let (up_list, up_creds) = install_two_device_roster(&up, [1u8; 32]);

    // Both directions before any upgrade of the legacy peer.
    up.post(cid.into(), "up-1".into(), vec![], None, None, false, false, 1_000).unwrap();
    sync(&up, &legacy, cid);
    assert!(bodies(&legacy, cid, 2_000).contains("up-1"), "legacy peer reads the upgraded peer's post");
    legacy.post(cid.into(), "legacy-1".into(), vec![], None, None, false, false, 1_100).unwrap();
    sync(&legacy, &up, cid);
    assert!(bodies(&up, cid, 2_000).contains("legacy-1"), "upgraded peer reads the legacy peer's post");

    // ── The legacy peer UPGRADES mid-stream: adopts a device key, installs + exchanges rosters/capability.
    assert!(legacy.use_device_identity(vec![92u8; 32]));
    let (leg_list, leg_creds) = install_two_device_roster(&legacy, [2u8; 32]);
    assert!(up.ingest_device_roster(legacy.my_bundle(), leg_list, leg_creds), "upgraded peer learns the newly-upgraded peer's roster");
    // `legacy` already learned `up`'s roster when it rode the earlier "up-1" sync bundle, so this direct
    // ingest is an idempotent no-op (same version ⇒ false). We call it for completeness, not correctness.
    legacy.ingest_device_roster(up.my_bundle(), up_list, up_creds);
    // Capability markers ride each side's signed profile.
    up.profile_seed_drop_version(legacy.my_bundle(), capability_card(&legacy, "legacy"));
    legacy.profile_seed_drop_version(up.my_bundle(), capability_card(&up, "up"));
    sync(&up, &legacy, cid);
    sync(&legacy, &up, cid);

    // Already-delivered history is intact on BOTH sides after the upgrade (nothing dropped by the roster
    // rotation the upgrade triggers).
    assert!(bodies(&legacy, cid, 3_000).is_superset(&BTreeSet::from(["up-1".into(), "legacy-1".into()])),
            "the newly-upgraded peer keeps everything delivered while it was legacy");
    assert!(bodies(&up, cid, 3_000).is_superset(&BTreeSet::from(["up-1".into(), "legacy-1".into()])),
            "the always-upgraded peer keeps the full history too");

    // New content posted AFTER the flip flows both ways.
    up.post(cid.into(), "up-2".into(), vec![], None, None, false, false, 2_000).unwrap();
    legacy.post(cid.into(), "legacy-2".into(), vec![], None, None, false, false, 2_100).unwrap();
    sync(&up, &legacy, cid);
    sync(&legacy, &up, cid);
    assert_eq!(bodies(&legacy, cid, 4_000),
               BTreeSet::from(["up-1".into(), "legacy-1".into(), "up-2".into(), "legacy-2".into()]),
               "post-upgrade feed on the upgraded-late peer is the FULL history, exactly");
    assert_eq!(bodies(&up, cid, 4_000),
               BTreeSet::from(["up-1".into(), "legacy-1".into(), "up-2".into(), "legacy-2".into()]),
               "post-upgrade feed on the early-upgraded peer is the FULL history, exactly");
}

/// SCENARIO — a full circle CONVERGES to fully-capable. Content is posted BEFORE any capability wiring,
/// DURING partial convergence, and AFTER the circle is fully seed-drop/MLS-capable; every message remains
/// readable by everyone, and the shadow MLS tree converges (equal tree hash, no fork) WITHOUT touching
/// content.
///
/// Invariant asserted: the capability flip (the migration trigger) is content-preserving. Each of the three
/// members ends with the exact same full feed regardless of when each post was authored, and
/// `mls_shadow_status` reports converged=true with an identical tree hash across the fleet — the shadow tree
/// is never consumed for content keys.
#[test]
fn circle_converges_to_fully_capable_content_readable_at_every_stage_shadow_converges() {
    let cid = DEFAULT_CIRCLE;
    let a = account(1);
    let b = account(2);
    let c = account(3);
    let insts = [&a, &b, &c];
    let seeds = [[1u8; 32], [2u8; 32], [3u8; 32]];
    let devs = [[11u8; 32], [12u8; 32], [13u8; 32]];
    for (s, d) in insts.iter().zip(devs.iter()) {
        assert!(s.use_device_identity(d.to_vec()));
    }
    let bundles: Vec<Vec<u8>> = insts.iter().map(|s| s.my_bundle()).collect();
    for i in 0..3 {
        for j in 0..3 {
            if i != j {
                insts[i].add_contact_bundle(cid.into(), bundles[j].clone()).unwrap();
            }
        }
    }

    // STAGE 1 — BEFORE any capability wiring: legacy-style dual-seal. Content still flows.
    a.post(cid.into(), "before-flip".into(), vec![], None, None, false, false, 1_000).unwrap();
    for _ in 0..2 {
        sync(&a, &b, cid);
        sync(&a, &c, cid);
    }
    assert!(bodies(&b, cid, 2_000).contains("before-flip"));
    assert!(bodies(&c, cid, 2_000).contains("before-flip"));

    // STAGE 2 — DURING: install own rosters, then cross-ingest ONE pair's roster/capability (partial).
    let mut rosters = Vec::new();
    for i in 0..3 {
        rosters.push(install_two_device_roster(insts[i], seeds[i]));
    }
    let cards: Vec<Vec<u8>> = insts.iter().enumerate().map(|(i, s)| capability_card(s, &format!("m{i}"))).collect();
    assert!(a.ingest_device_roster(bundles[1].clone(), rosters[1].0.clone(), rosters[1].1.clone()));
    a.profile_seed_drop_version(bundles[1].clone(), cards[1].clone());
    b.post(cid.into(), "during-flip".into(), vec![], None, None, false, false, 1_500).unwrap();
    for _ in 0..2 {
        sync(&b, &a, cid);
        sync(&b, &c, cid);
    }
    assert!(bodies(&a, cid, 2_500).contains("during-flip"), "content readable mid-convergence");
    assert!(bodies(&c, cid, 2_500).contains("during-flip"));

    // STAGE 3 — AFTER: complete the mesh so the circle is FULLY capable everywhere.
    for i in 0..3 {
        for j in 0..3 {
            if i != j {
                // Idempotent: re-ingesting the roster `a` already learned in stage 2 is a legitimate no-op
                // (returns false); every other pair ingests for the first time. Convergence only needs each
                // roster learned once, so we don't assert the return here.
                insts[i].ingest_device_roster(bundles[j].clone(), rosters[j].0.clone(), rosters[j].1.clone());
                insts[i].profile_seed_drop_version(bundles[j].clone(), cards[j].clone());
            }
        }
    }
    c.post(cid.into(), "after-flip".into(), vec![], None, None, false, false, 2_000).unwrap();
    // Several all-to-all rounds so the shadow genesis + welcomes (and any re-seals) propagate.
    for _ in 0..4 {
        for i in 0..3 {
            for j in 0..3 {
                if i != j {
                    sync(insts[i], insts[j], cid);
                }
            }
        }
    }

    // Every member ends with the EXACT same full feed — content from all three stages, readable by all.
    let expected = BTreeSet::from(["before-flip".into(), "during-flip".into(), "after-flip".into()]);
    for (i, s) in insts.iter().enumerate() {
        assert_eq!(bodies(s, cid, 5_000), expected, "instance {i} holds all content across the capability flip");
    }

    // Shadow MLS tree converged across the fleet — and never touched content.
    let reference = a.mls_shadow_status(cid.into());
    assert!(reference.converged, "the shadow tree converged");
    assert_eq!(reference.fork_count, 0, "single elected creator ⇒ no fork");
    assert!(!reference.tree_hash_hex.is_empty());
    for (i, s) in insts.iter().enumerate() {
        let st = s.mls_shadow_status(cid.into());
        assert!(st.converged, "instance {i} shadow converged");
        assert_eq!(st.tree_hash_hex, reference.tree_hash_hex, "instance {i} agrees on the shadow tree hash");
        assert_eq!(st.epoch, reference.epoch);
    }
}

/// SCENARIO — SEEDLESS enrollment migration (plan §7 absence-as-deletion hazard). A freshly-enrolled
/// seedless device (holds a device key + account-signed credential + granted self-sync key, NEVER the
/// account seed) receives the primary's FULL history via self-sync, authors in the fully-capable circle, and
/// nothing it holds is tombstoned by a subsequent self-sync that omits fields.
///
/// Invariant asserted: importing the primary's exported state onto the seedless device (self-sync) is purely
/// ADDITIVE — the primary's history lands, the seedless device's OWN verbatim roster wire is NOT clobbered
/// by the primary's `None`, and a second self-sync does not erase anything. Then the seedless device authors
/// readable, ACCOUNT-attributed content.
#[test]
fn seedless_enrollment_receives_history_and_nothing_is_tombstoned() {
    let cid = DEFAULT_CIRCLE;
    let dev_seed = [98u8; 32];

    // ── Enroll a seedless device against primary Alice, entirely over the enroll FFI. ──
    let primary = account(1);
    let account_bundle = primary.my_bundle();
    let seedless = HavenSocial::new_seedless(account_bundle.clone(), dev_seed.to_vec()).unwrap();
    assert!(seedless.is_seedless() && !primary.is_seedless());

    let primary_dev = hex_to_bytes(&primary.my_node_hex());
    let ticket = haven_ffi::enroll::enroll_issue_ticket(
        account_bundle, primary_dev, 1_000, vec!["https://relay.example".into()],
    ).unwrap();
    let req_wire = haven_ffi::enroll::enroll_build_request(
        ticket.secret.clone(), seedless.my_device_bundle(), "Blaine's iPad".into(), 1_000,
    ).unwrap();
    let req = haven_ffi::enroll::enroll_verify_request(ticket.secret.clone(), req_wire, 1_000, 600).unwrap();
    let alice_roster_wire = primary.register_device(req.device_bundle.clone(), req.name.clone(), 1);
    let grant_wire = haven_ffi::enroll::enroll_assemble_grant(
        vec![1u8; 32], ticket.secret.clone(), req.device_bundle, "Blaine's iPad".into(), 1,
        alice_roster_wire, vec!["https://relay.example".into()],
    ).unwrap();
    let grant = haven_ffi::enroll::enroll_open_grant(dev_seed.to_vec(), ticket, grant_wire).unwrap();
    assert!(seedless.ingest_roster_wire(grant.roster_wire.clone()), "seedless installs its granted roster");
    let granted_roster_wire = grant.roster_wire.clone();

    // ── Make the seedless device's circle FULLY capable via a capable contact Bob. ──
    let bob = account(2);
    seedless.add_contact_bundle(cid.into(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(cid.into(), primary.my_bundle()).unwrap();
    assert!(bob.use_device_identity(vec![99u8; 32]));
    let bob_roster_wire = bob.register_device(bob.my_device_bundle(), "Bob's phone".into(), 0);
    assert!(seedless.ingest_roster_wire(bob_roster_wire), "seedless learns Bob's roster + capability");
    assert!(bob.ingest_roster_wire(granted_roster_wire.clone()), "Bob learns Alice's roster");

    // ── The primary accrues history BEFORE the seedless device ever syncs. ──
    primary.add_contact_bundle(cid.into(), bob.my_bundle()).unwrap();
    primary.post(cid.into(), "history-1".into(), vec!["media/hist".into()], None, None, false, false, 1_500).unwrap();
    primary.post(cid.into(), "history-2".into(), vec![], None, None, false, false, 1_600).unwrap();

    // ── Self-sync: the seedless device imports the primary's exported account state. ──
    let primary_state = primary.export_state();
    seedless.import_state(primary_state.clone());

    // History landed…
    let feed_after_sync = bodies(&seedless, cid, 3_000);
    assert!(feed_after_sync.is_superset(&BTreeSet::from(["history-1".into(), "history-2".into()])),
            "the seedless device received the primary's full history via self-sync");
    assert!(seedless.feed(cid.into(), 3_000, None).iter().any(|f| f.body == "history-1" && f.media == vec!["media/hist".to_string()]),
            "media refs on synced history survive");
    // …and the seedless device's OWN verbatim roster wire was NOT clobbered by the primary's `None`
    // (the absence-as-deletion guard, plan §7).
    assert_eq!(seedless.my_device_roster_wire(), granted_roster_wire,
               "self-sync must not wipe the seedless device's granted roster wire");

    // ── A SECOND self-sync (idempotent) tombstones nothing. ──
    seedless.import_state(primary_state);
    assert!(bodies(&seedless, cid, 3_000).is_superset(&BTreeSet::from(["history-1".into(), "history-2".into()])),
            "a repeated self-sync does not drop synced history");
    assert_eq!(seedless.my_device_roster_wire(), granted_roster_wire, "roster wire still intact after re-sync");

    // ── The seedless device AUTHORS in the fully-capable circle; Bob reads it, attributed to the ACCOUNT. ──
    seedless.post(cid.into(), "from-seedless".into(), vec![], None, None, false, false, 2_500)
        .expect("seedless authors in a fully-capable circle");
    sync(&seedless, &bob, cid);
    let item = bob.feed(cid.into(), 3_000, None).into_iter().find(|f| f.body == "from-seedless")
        .expect("contact reads the seedless device's post");
    assert!(!item.is_me, "the post is the account's, read by Bob");
    assert_eq!(item.author_short, &primary.my_node_hex()[..item.author_short.len()],
               "attributed to the ACCOUNT, not the seedless device's transport id");
}

/// SCENARIO — REVOCATION at the migration layer: a device authorized in a roster receives content, then is
/// revoked via a roster version bump, and can no longer open content posted AFTER the revocation (the
/// seed-drop headline). Re-proven end-to-end through the persist/roster API the upgrade path uses.
///
/// Invariant asserted: after a roster bump moves a device to the revoked set, the sealer stops sealing new
/// epoch keys to it — so the revoked device reads everything up to the bump and NOTHING after it, while a
/// still-authorized device keeps reading.
#[test]
fn revoked_device_cannot_open_post_revocation_content() {
    let cid = DEFAULT_CIRCLE;
    let alice = account(1);
    let bob = account(2);
    let bob_phone = account(22); // modeled as a separate opener authorized in Bob's roster

    alice.add_contact_bundle(cid.into(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();
    bob_phone.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();

    let bob_acct_id = hex_to_bytes(&bob.my_node_hex());
    let phone_id = hex_to_bytes(&bob_phone.my_node_hex());
    let acct_cred =
        haven_ffi::multidevice::issue_device_credential(vec![2u8; 32], bob.my_bundle(), "bob-primary".into(), 0).unwrap();
    let phone_cred =
        haven_ffi::multidevice::issue_device_credential(vec![2u8; 32], bob_phone.my_bundle(), "bob-phone".into(), 1).unwrap();

    // Roster v1 authorizes Bob's account + his phone. Alice learns it.
    let v1 = haven_ffi::multidevice::sign_device_list(vec![2u8; 32], 1, 0, vec![bob_acct_id.clone(), phone_id.clone()], vec![]).unwrap();
    assert!(bob.set_my_device_roster(v1.clone(), vec![acct_cred.clone(), phone_cred.clone()]));
    assert!(alice.ingest_device_roster(bob.my_bundle(), v1, vec![acct_cred.clone(), phone_cred.clone()]));

    // Alice posts → her key commit seals to Bob's phone too → the phone receives it.
    alice.post(cid.into(), "before-revoke".into(), vec![], None, None, false, false, 1_000).unwrap();
    sync(&alice, &bob_phone, cid);
    assert!(bodies(&bob_phone, cid, 2_000).contains("before-revoke"), "authorized device receives pre-revocation content");

    // Bob REVOKES the phone (roster v2 moves it to the revoked set). Alice learns it (rotating her epoch).
    let v2 = haven_ffi::multidevice::sign_device_list(vec![2u8; 32], 2, 1, vec![bob_acct_id], vec![phone_id]).unwrap();
    assert!(alice.ingest_device_roster(bob.my_bundle(), v2, vec![acct_cred]));

    // Alice posts again → sealed only to the remaining authorized devices; the revoked phone can't learn the
    // new epoch key, so it never opens this post — while Bob's still-authorized primary does.
    alice.post(cid.into(), "after-revoke".into(), vec![], None, None, false, false, 3_000).unwrap();
    sync(&alice, &bob_phone, cid);
    sync(&alice, &bob, cid);
    assert!(!bodies(&bob_phone, cid, 4_000).contains("after-revoke"),
            "REVOKED device cannot open content posted after revocation");
    assert!(bodies(&bob_phone, cid, 4_000).contains("before-revoke"),
            "…but everything delivered before revocation stays readable (no retroactive loss)");
    assert!(bodies(&bob, cid, 4_000).contains("after-revoke"),
            "a still-authorized device keeps reading");
}

/// SCENARIO — S5 RETIREMENT gate at the migration layer: with retirement OFF (the shipping default) a circle
/// keeps today's dual-seal so an account-only holder still reads (backwards compatible); flip retirement ON
/// in a fully-capable circle and a FRESH account-only holder is cut off — the cryptographic retirement of
/// the account seal that makes a revoked device's leaked seed useless.
///
/// Invariant asserted: the retirement switch is inert until a circle is fully capable AND the flag is on;
/// then, and only then, the bare account key is dropped from the sealing set. This guards that the migration
/// doesn't accidentally strand account-only (legacy) holders while the fleet is still converging.
#[test]
fn retirement_gate_is_backward_compatible_off_and_cuts_account_key_on() {
    let cid = DEFAULT_CIRCLE;
    let alice = account(1);
    let bob = account(2); // Bob's device (adopts a device key)
    let acct_off = account(2); // fresh account-only witness for the OFF era
    let acct_on = account(2); // fresh account-only witness for the ON era
    alice.add_contact_bundle(cid.into(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();
    acct_off.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();
    acct_on.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();

    assert!(alice.use_device_identity(vec![98u8; 32]));
    assert!(bob.use_device_identity(vec![99u8; 32]));
    let (al_list, al_creds) = install_two_device_roster(&alice, [1u8; 32]);
    // Bob's fully-upgraded roster authorizes ONLY his device bundle (not the bare account) so the drop path
    // can exclude a seed-only holder.
    let bob_dev_id = hex_to_bytes(&bob.my_device_node_hex());
    let bob_dev_cred =
        haven_ffi::multidevice::issue_device_credential(vec![2u8; 32], bob.my_device_bundle(), "device".into(), 1).unwrap();
    let bo_list = haven_ffi::multidevice::sign_device_list(vec![2u8; 32], 1, 0, vec![bob_dev_id], vec![]).unwrap();
    let bo_creds = vec![bob_dev_cred];
    assert!(bob.set_my_device_roster(bo_list.clone(), bo_creds.clone()));
    assert!(bob.ingest_device_roster(alice.my_bundle(), al_list, al_creds));
    assert!(alice.ingest_device_roster(bob.my_bundle(), bo_list, bo_creds));
    sync(&bob, &alice, cid); // Bob's roster-wire capability trailer → Alice marks Bob capable

    // (1) Retirement OFF: dual-seal. A fresh account-only witness obtains the key and reads.
    alice.set_seed_drop_retire(false);
    alice.post(cid.into(), "dual-seal-era".into(), vec![], None, None, false, false, 1_000).unwrap();
    sync(&alice, &acct_off, cid);
    assert!(bodies(&acct_off, cid, 2_000).contains("dual-seal-era"),
            "gate OFF: the account key still opens content (backwards compatible)");

    // (2) Retirement ON + fully capable: the bare account key is dropped. The fresh account-only witness is
    //     cut off; the authorized device still reads.
    alice.set_seed_drop_retire(true);
    alice.post(cid.into(), "device-only-era".into(), vec![], None, None, false, false, 3_000).unwrap();
    sync(&alice, &acct_on, cid);
    sync(&alice, &bob, cid);
    assert!(!bodies(&acct_on, cid, 4_000).contains("device-only-era"),
            "gate ON in a fully-capable circle: an account-only key can no longer obtain the epoch key");
    assert!(bodies(&bob, cid, 4_000).contains("device-only-era"), "the authorized device still opens it");
}
