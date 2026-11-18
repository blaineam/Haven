//! Tests of version 2 of the circle tree (`keying_v2.rs`, docs/formal/STAGE3-V2-TREE.md), and of
//! the key-lane fixes its migration leans on (per-lane key retention, the park path).
use super::*;
use haven_p2p::keypackage::{self, KeyPackage};

/// One device of a v2 fleet.
struct Dev {
    s: Arc<HavenSocial>,
    account_seed: [u8; 32],
    device_seed: [u8; 32],
}

impl Dev {
    fn device_id(&self) -> [u8; 32] {
        Identity::from_seed(&self.device_seed).public().node_id_bytes()
    }
    fn account_hex(&self) -> String {
        hex(&Identity::from_seed(&self.account_seed).public().node_id_bytes())
    }
}

/// (account seed, signed device list, credentials) of one account.
type Roster = ([u8; 32], Vec<u8>, Vec<Vec<u8>>);

struct Fleet {
    cid: String,
    devs: Vec<Dev>,
    rosters: Vec<Roster>,
}

/// A fleet of accounts, each with one or more REAL devices (device-only rosters), every engine
/// advertising `ml: versions[i]` (per device, in order). The circle is owned by the account with
/// the lowest id — the one the tree elects as committer. The keying switch is ON everywhere.
fn fleet_with(accounts: &[([u8; 32], &[[u8; 32]])], versions: &[u32]) -> Fleet {
    let ids: Vec<[u8; 32]> = accounts.iter().map(|(a, _)| Identity::from_seed(a).public().node_id_bytes()).collect();
    let creator = *ids.iter().min().unwrap();
    let cid = mint_owned_circle_id(&creator);
    let mut devs: Vec<Dev> = Vec::new();
    let mut rosters = Vec::new();
    let mut n = 0;
    for (account_seed, device_seeds) in accounts {
        let mut creds = Vec::new();
        let mut dev_ids = Vec::new();
        for device_seed in device_seeds.iter() {
            TEST_MLS_VERSION.with(|v| v.set(versions[n]));
            n += 1;
            let s = HavenSocial::new(account_seed.to_vec()).unwrap();
            assert!(s.use_device_identity(device_seed.to_vec()));
            s.create_circle(cid.clone(), "fleet".into());
            creds.push(
                crate::multidevice::issue_device_credential(account_seed.to_vec(), s.my_device_bundle(), "d".into(), 1)
                    .unwrap(),
            );
            dev_ids.push(Identity::from_seed(device_seed).public().node_id_bytes().to_vec());
            devs.push(Dev { s, account_seed: *account_seed, device_seed: *device_seed });
        }
        let list = crate::multidevice::sign_device_list(account_seed.to_vec(), 1, 0, dev_ids, vec![]).unwrap();
        rosters.push((*account_seed, list, creds));
    }
    TEST_MLS_VERSION.with(|v| v.set(MLS_VERSION));
    let f = Fleet { cid, devs, rosters };
    introduce(&f);
    for d in &f.devs {
        assert!(d.s.set_circle_creator(f.cid.clone(), hex(&creator)));
        d.s.set_mls_keying(true);
    }
    f
}

/// Rosters, contact bundles and capability cards, everyone to everyone. The account's card is the
/// one its FIRST device mints (so an account whose first device is upgraded advertises `ml: 2`
/// even if another of its devices runs an older build — the marker is account-level).
fn introduce(f: &Fleet) {
    let card_of = |seed: &[u8; 32]| {
        let d = f.devs.iter().find(|d| d.account_seed == *seed).unwrap();
        (d.s.my_bundle(), card(&d.s, "m"))
    };
    for d in &f.devs {
        for (seed, list, creds) in &f.rosters {
            let (bundle, card) = card_of(seed);
            if *seed == d.account_seed {
                assert!(d.s.set_my_device_roster(list.clone(), creds.clone()));
            } else {
                let _ = d.s.add_contact_bundle(f.cid.clone(), bundle.clone());
                assert!(d.s.ingest_device_roster(bundle.clone(), list.clone(), creds.clone()));
                d.s.profile_seed_drop_version(bundle, card);
            }
        }
    }
}

fn v2_fleet(accounts: &[([u8; 32], &[[u8; 32]])]) -> Fleet {
    let n: usize = accounts.iter().map(|(_, d)| d.len()).sum();
    fleet_with(accounts, &vec![2; n])
}

fn is_v2_wire(e: &[u8]) -> bool {
    matches!(e.first(), Some(&(TAG_MLS2_KEYPACKAGE | TAG_MLS2_COMMIT | TAG_MLS2_WELCOME | TAG_MLS2_JOIN)))
}
fn is_v1_tree_wire(e: &[u8]) -> bool {
    matches!(e.first(), Some(&(TAG_MLS_COMMIT | TAG_MLS_WELCOME | TAG_MLS_JOIN)))
}

/// All-to-all delivery, `rounds` times, dropping every envelope `drop(from, to, envelope)` says to.
fn deliver(f: &Fleet, rounds: usize, drop: &dyn Fn(usize, usize, &[u8]) -> bool) {
    for _ in 0..rounds {
        for i in 0..f.devs.len() {
            let out = f.devs[i].s.sync_envelopes(f.cid.clone());
            for j in 0..f.devs.len() {
                if i != j {
                    for e in &out {
                        if !drop(i, j, e) {
                            let _ = f.devs[j].s.receive(f.cid.clone(), e.clone());
                        }
                    }
                }
            }
        }
    }
}

fn sync_fleet(f: &Fleet, rounds: usize) {
    deliver(f, rounds, &|_, _, _| false);
}

/// The key lane a device's content is sealed under right now: 0 sender keys, 1 v1 tree, 2 v2 tree.
fn lane(s: &HavenSocial, cid: &str) -> u8 {
    let mut st = s.state.lock().unwrap();
    let idx = st.circles.iter().position(|c| c.id == cid).unwrap();
    mls_refresh_keying(&mut st, idx).map(epoch_lane).unwrap_or(0)
}

fn reads(s: &HavenSocial, cid: &str, body: &str) -> bool {
    s.feed(cid.to_string(), u64::MAX / 2, None).iter().any(|m| m.body == body)
}

fn post(s: &HavenSocial, cid: &str, body: &str, at: u64) {
    s.post(cid.to_string(), body.into(), vec![], None, None, false, false, at).unwrap();
}

/// The v2 tree's live state on a device.
fn v2_state(s: &HavenSocial, cid: &str) -> Option<KeyingState> {
    let st = s.state.lock().unwrap();
    mls_replay(st.v2_trees.get(cid)?, None)
}

fn v2_genesis_count(s: &HavenSocial, cid: &str) -> usize {
    let st = s.state.lock().unwrap();
    st.v2_trees.get(cid).map_or(0, |t| {
        t.commits.values().filter(|b| treekem::Commit::from_bytes(b).is_ok_and(|c| c.epoch == 1)).count()
    })
}

/// Make the committer's weekly leaf Update due and run it: one new tree epoch everywhere.
fn update(f: &Fleet, committer: usize) {
    let before = f.devs[committer].s.mls_keying_status(f.cid.clone()).epoch;
    f.devs[committer].s.state.lock().unwrap().circles.iter_mut().find(|c| c.id == f.cid).unwrap().rotated_at = 1;
    sync_fleet(f, 3);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(d.s.mls_keying_status(f.cid.clone()).epoch, before + 1, "device {i} followed the leaf Update");
    }
}

/// The committer: a device of the account with the lowest id.
fn committer_index(f: &Fleet) -> usize {
    let low = f.devs.iter().map(|d| d.account_hex()).min().unwrap();
    f.devs.iter().position(|d| d.account_hex() == low).unwrap()
}

/// Run a fresh v2 fleet to v2-live.
fn live_v2_fleet(accounts: &[([u8; 32], &[[u8; 32]])]) -> Fleet {
    let f = v2_fleet(accounts);
    sync_fleet(&f, 6);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(lane(&d.s, &f.cid), 2, "device {i} is keyed by the v2 tree");
    }
    f
}

const A: [u8; 32] = [41u8; 32];
const B: [u8; 32] = [42u8; 32];
const C: [u8; 32] = [43u8; 32];
const A1: [u8; 32] = [51u8; 32];
const A2: [u8; 32] = [52u8; 32];
const B1: [u8; 32] = [53u8; 32];
const B2: [u8; 32] = [55u8; 32];
const C1: [u8; 32] = [54u8; 32];

/// THE MIGRATION. A fully upgraded fleet (3 accounts, one with two devices) whose circle is already
/// keyed by the v1 tree goes v1-live → v2-live. At every step every device posts, and every post
/// authored so far opens on every other device. Posts from before the flip are still there after
/// it — including on a device that received no content at all until the flip was over. After the
/// flip: no v1 tree in any device's state, no v1 tree wire and no KeyCommit in any bundle.
#[test]
fn v2_migration_keeps_every_post_readable_and_wipes_the_v1_tree() {
    let _clk = clock_guard();
    let f = v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let late = 3; // C's device: syncs keys and tree wires, but no posts, until the very end
    let hold_content = |_: usize, to: usize, e: &[u8]| to == late && e.first() == Some(&TAG_EPOCH_EVENT);

    // Phase 1 — the circle as it is today: keyed by the v1 tree (the v2 wires are held back, as if
    // the fleet had not upgraded yet).
    deliver(&f, 6, &|i, j, e| is_v2_wire(e) || hold_content(i, j, e));
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(lane(&d.s, &f.cid), 1, "device {i} starts keyed by the v1 tree");
        assert_eq!(v2_genesis_count(&d.s, &f.cid), 0, "no v2 genesis without every device's key package");
    }
    let mut posted: Vec<String> = Vec::new();
    let mut clock = 1_000u64;
    let mut everyone_posts = |f: &Fleet, posted: &mut Vec<String>, tag: &str| {
        for (i, d) in f.devs.iter().enumerate() {
            let body = format!("{tag}-from-{i}");
            clock += 10;
            post(&d.s, &f.cid, &body, clock);
            posted.push(body);
        }
    };
    let check = |f: &Fleet, posted: &[String], step: &str| {
        for (i, d) in f.devs.iter().enumerate().filter(|(i, _)| *i != late) {
            for body in posted {
                assert!(reads(&d.s, &f.cid, body), "{step}: device {i} cannot read `{body}`");
            }
        }
    };
    everyone_posts(&f, &mut posted, "before");
    deliver(&f, 2, &|i, j, e| is_v2_wire(e) || hold_content(i, j, e));
    check(&f, &posted, "v1-live");

    // Phase 2 — the v2 wires flow. One delivery round at a time, everyone posting in between.
    let mut lanes_seen: Vec<Vec<u8>> = Vec::new();
    for step in 0..8 {
        deliver(&f, 1, &hold_content);
        everyone_posts(&f, &mut posted, &format!("step{step}"));
        deliver(&f, 1, &hold_content);
        check(&f, &posted, &format!("migration step {step}"));
        lanes_seen.push(f.devs.iter().map(|d| lane(&d.s, &f.cid)).collect());
    }
    assert!(lanes_seen.iter().all(|l| l.iter().all(|x| *x >= 1)), "a tree keyed every device at every step: {lanes_seen:?}");
    assert!(lanes_seen.last().unwrap().iter().all(|x| *x == 2), "every device ends keyed by the v2 tree: {lanes_seen:?}");

    // After the flip.
    for (i, d) in f.devs.iter().enumerate() {
        let st = d.s.state.lock().unwrap();
        assert!(!st.shadow_trees.contains_key(&f.cid), "device {i}: the v1 tree state is gone");
        assert_eq!(st.v2_trees.get(&f.cid).map(|t| t.x_retired()), Some(true));
        drop(st);
        let out = d.s.sync_envelopes(f.cid.clone());
        assert!(!out.iter().any(|e| is_v1_tree_wire(e)), "device {i} emits no v1 tree wire");
        assert!(!out.iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)), "device {i} emits no KeyCommit: the tree keys the circle");
        assert_eq!(v2_genesis_count(&d.s, &f.cid), 1, "one v2 genesis");
    }
    // A v1 tree wire that still arrives (a sibling that had not flipped yet) is dropped, not stored.
    let stale_v1 = tagged(TAG_MLS_JOIN, &[7u8; 96]);
    let _ = f.devs[1].s.receive(f.cid.clone(), stale_v1);
    assert!(!f.devs[1].s.state.lock().unwrap().shadow_trees.contains_key(&f.cid));

    // The late device now gets content for the first time: everything, old and new.
    sync_fleet(&f, 2);
    for body in &posted {
        assert!(reads(&f.devs[late].s, &f.cid, body), "the late device reads `{body}`");
    }
    assert!(posted.iter().any(|b| b.starts_with("before")));
}

/// DEVICES FLIP AT DIFFERENT MOMENTS. One device has not seen the last join ack and is still keyed
/// by the v1 tree while the others already key from the v2 tree. Posts cross that boundary in
/// both directions at once: the laggard reads v2-keyed posts (it files the v2 tree's keys as soon
/// as it can derive them), and the flipped devices read its v1-keyed posts (the v1 content keys
/// outlive the v1 tree state by the usual window).
#[test]
fn a_device_that_has_not_flipped_yet_reads_and_is_read() {
    let _clk = clock_guard();
    let f = v2_fleet(&[(A, &[A1]), (B, &[B1]), (C, &[C1])]);
    // Device 1 never receives device 2's v2 join ack.
    let hold_ack = |from: usize, to: usize, e: &[u8]| from == 2 && to == 1 && e.first() == Some(&TAG_MLS2_JOIN);
    deliver(&f, 6, &hold_ack);
    assert_eq!([lane(&f.devs[0].s, &f.cid), lane(&f.devs[1].s, &f.cid), lane(&f.devs[2].s, &f.cid)], [2, 1, 2]);
    for (i, d) in f.devs.iter().enumerate() {
        post(&d.s, &f.cid, &format!("across-{i}"), 1_000 + i as u64);
    }
    deliver(&f, 1, &hold_ack);
    for (i, d) in f.devs.iter().enumerate() {
        for j in 0..3 {
            assert!(reads(&d.s, &f.cid, &format!("across-{j}")), "device {i} (lane {}) cannot read device {j}'s post", lane(&d.s, &f.cid));
        }
    }
    assert_eq!(lane(&f.devs[1].s, &f.cid), 1, "the laggard read them while still keyed by the v1 tree");
    sync_fleet(&f, 2);
    assert!(f.devs.iter().all(|d| lane(&d.s, &f.cid) == 2));
}

/// A MIXED fleet: account B's second device runs a build that never publishes a key package
/// (though B's ACCOUNT advertises `ml: 2`). The circle stays on the v1 tree, content keeps
/// flowing in every direction, and no v2 genesis is ever built.
#[test]
fn a_device_without_a_key_package_keeps_the_circle_on_the_v1_tree() {
    let _clk = clock_guard();
    let f = fleet_with(&[(A, &[A1]), (B, &[B1, B2]), (C, &[C1])], &[2, 2, 1, 2]);
    let old = 2;
    assert!(!f.devs[old].s.sync_envelopes(f.cid.clone()).iter().any(|e| is_v2_wire(e)), "the old build emits no v2 wire");
    assert!(f.devs[0].s.sync_envelopes(f.cid.clone()).iter().any(|e| e.first() == Some(&TAG_MLS2_KEYPACKAGE)), "an upgraded device offers its key package");
    let mut posted = Vec::new();
    for round in 0..10u64 {
        sync_fleet(&f, 1);
        for (i, d) in f.devs.iter().enumerate() {
            let body = format!("r{round}-from-{i}");
            post(&d.s, &f.cid, &body, 1_000 + round * 100 + i as u64);
            posted.push(body);
        }
        sync_fleet(&f, 1);
        for (i, d) in f.devs.iter().enumerate() {
            for body in &posted {
                assert!(reads(&d.s, &f.cid, body), "round {round}: device {i} cannot read `{body}`");
            }
        }
    }
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(lane(&d.s, &f.cid), 1, "device {i} is still keyed by the v1 tree");
        assert_eq!(v2_genesis_count(&d.s, &f.cid), 0, "device {i} holds no v2 genesis");
        assert!(d.s.state.lock().unwrap().shadow_trees.contains_key(&f.cid), "device {i} kept its v1 tree");
    }
}

/// Every 32-byte secret of a device's v2 keying state that no other device may ever hold: its
/// current leaf secret, and the leaf secret + one-time seed of each key package it still holds.
fn own_tree_secrets(s: &HavenSocial, cid: &str) -> Vec<[u8; 32]> {
    let st = s.state.lock().unwrap();
    let t = st.v2_trees.get(cid).unwrap();
    let mut out: Vec<[u8; 32]> = t.x_own_secrets();
    if let Some(p) = mls_replay(t, None).and_then(|k| k.my_private.clone()) {
        out.push(p.leaf_secret);
    }
    out
}

/// SECRET HYGIENE (a): the committer never holds another device's leaf secret (or one-time seed) —
/// not at the genesis, not after its own leaf Updates.
#[test]
fn a_committer_never_holds_another_devices_leaf_secret() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    let scan = |f: &Fleet, when: &str| {
        let leaves = s1_blob_bytes(&f.devs[ci].s.export_state());
        let mine = own_tree_secrets(&f.devs[ci].s, &f.cid);
        assert!(!mine.is_empty() && mine.iter().any(|s| s1_blob_has(&leaves, s)), "{when}: the scan finds the committer's OWN leaf secret (it has teeth)");
        for (i, d) in f.devs.iter().enumerate().filter(|(i, _)| *i != ci) {
            let theirs = own_tree_secrets(&d.s, &f.cid);
            assert!(!theirs.is_empty(), "device {i} has tree secrets to look for");
            for s in &theirs {
                assert!(!s1_blob_has(&leaves, s), "{when}: the committer's state holds a secret of device {i}");
            }
            // And in memory: no key package secret, no assigned leaf, for anyone else.
            let st = f.devs[ci].s.state.lock().unwrap();
            let t = st.v2_trees.get(&f.cid).unwrap();
            assert!(t.assigned_leaves.is_empty(), "a v2 committer assigns no leaf");
            assert!(t.x_own_secrets().iter().all(|k| !theirs.contains(k)));
        }
    };
    scan(&f, "after the genesis");
    update(&f, ci);
    update(&f, ci);
    scan(&f, "after two leaf Updates");
}

/// SECRET HYGIENE (b), (c): once a joiner has joined and checkpointed, its state holds neither the
/// one-time seed of the key package it entered through nor the Welcome's joiner secret; the
/// recorded Welcome never opened with a long-term key, and no longer opens with anything the
/// joiner still holds.
#[test]
fn a_joiners_welcome_cannot_be_reopened_after_its_checkpoint() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    let ji = (ci + 1) % 3;
    let (committer, joiner) = (&f.devs[ci], &f.devs[ji]);
    let committer_device = Identity::from_seed(&committer.device_seed).public();
    // What a recording adversary has: the joiner's Welcome, off the wire.
    let welcomes: Vec<SealedEnvelope> = committer
        .s
        .sync_envelopes(f.cid.clone())
        .iter()
        .filter(|e| e.first() == Some(&TAG_MLS2_WELCOME))
        .map(|e| SealedEnvelope::from_bytes(&e[1..]).unwrap())
        .collect();
    assert_eq!(welcomes.len(), 2, "one Welcome per other device");
    // The joiner's secrets while the window on its entry point is open.
    let (init_seed, joiner_secret, kp_secret) = {
        let st = joiner.s.state.lock().unwrap();
        let t = st.v2_trees.get(&f.cid).unwrap();
        let e = t.x_entries();
        assert_eq!(e.len(), 1, "the joiner still holds the package it entered through");
        let w = t.my_welcomes.values().next().expect("the entry point is still held");
        (e[0].1, w.joiner_secret, keypackage::KeyPackageSecret { kp_id: e[0].0, leaf_secret: e[0].2, init_seed: e[0].1 })
    };
    let mine: Vec<&SealedEnvelope> =
        welcomes.iter().filter(|w| keypackage::open_welcome(&kp_secret, &committer_device, w).is_ok()).collect();
    assert_eq!(mine.len(), 1, "before the checkpoint the joiner's one-time key opens its Welcome (the test has teeth)");
    let recorded = mine[0];
    let before = s1_blob_bytes(&joiner.s.export_state());
    assert!(s1_blob_has(&before, &init_seed) && s1_blob_has(&before, &joiner_secret), "and both secrets are in its state");
    // Never with a long-term key — the device's, or the account's.
    for long_term in [Identity::from_seed(&joiner.device_seed), Identity::from_seed(&joiner.account_seed)] {
        assert!(open_bytes(&long_term, &committer_device, recorded).is_err(), "a long-term key opens a v2 Welcome");
    }

    // Three leaf Updates: the entry epoch falls behind the checkpoint.
    for _ in 0..3 {
        update(&f, ci);
    }
    let st = joiner.s.state.lock().unwrap();
    let t = st.v2_trees.get(&f.cid).unwrap();
    assert!(t.checkpoint.is_some(), "the joiner checkpointed");
    assert!(t.my_welcomes.is_empty(), "the entry point was wiped");
    assert!(t.x_entries().is_empty(), "the key package's secrets were deleted");
    drop(st);
    let after = s1_blob_bytes(&joiner.s.export_state());
    assert!(!s1_blob_has(&after, &init_seed), "the one-time seed is gone from the joiner's state");
    assert!(!s1_blob_has(&after, &joiner_secret), "the entry epoch's joiner secret is gone from the joiner's state");
    // Nothing the joiner still holds opens the recorded Welcome: not a key package secret (none
    // left), not its long-term keys.
    for long_term in [Identity::from_seed(&joiner.device_seed), Identity::from_seed(&joiner.account_seed)] {
        assert!(open_bytes(&long_term, &committer_device, recorded).is_err());
    }
    // The committer keeps no joiner secret either — not in its live state, not in its checkpoint.
    let st = committer.s.state.lock().unwrap();
    let t = st.v2_trees.get(&f.cid).unwrap();
    assert!(mls_replay(t, None).unwrap().joiner_secret.is_none());
    assert!(t.checkpoint.as_ref().unwrap().state.joiner_secret.is_none());
    drop(st);
    assert!(!s1_blob_has(&s1_blob_bytes(&committer.s.export_state()), &joiner_secret));
    // And the fleet still talks.
    post(&joiner.s, &f.cid, "after-checkpoint", 9_000);
    sync_fleet(&f, 2);
    assert!(reads(&committer.s, &f.cid, "after-checkpoint"));
}

fn held_packages(s: &HavenSocial, cid: &str, device: &[u8; 32]) -> usize {
    s.state.lock().unwrap().v2_trees.get(cid).map_or(0, |t| t.x_packages_of(device))
}

/// A key package is accepted only if it is this circle's, intact, from a device the verified
/// roster authorizes — and only once: a package the chain has used is refused when replayed.
#[test]
fn key_packages_are_verified_and_used_once() {
    let _clk = clock_guard();
    let f = v2_fleet(&[(A, &[A1]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    let bi = (ci + 1) % 3;
    let (a, b) = (&f.devs[ci], &f.devs[bi]);
    let b_dev = b.device_id();
    let b_device = Identity::from_seed(&b.device_seed);
    let b_cred = DeviceCredential::from_bytes(&f.rosters.iter().find(|r| r.0 == b.account_seed).unwrap().2[0]).unwrap();
    let feed = |kp: &KeyPackage| a.s.receive(f.cid.clone(), tagged(TAG_MLS2_KEYPACKAGE, &kp.to_bytes()));
    let _ = a.s.sync_envelopes(f.cid.clone()); // A's v2 tree exists (it offered its own package)

    // Tampered: any changed field breaks the device's signature.
    let (good, _) = KeyPackage::generate(&b_device, &b_cred, f.cid.as_bytes()).unwrap();
    let mut tampered = good.clone();
    tampered.init_bundle = Identity::from_seed(&[9u8; 32]).public().to_bytes();
    let _ = feed(&tampered);
    assert_eq!(held_packages(&a.s, &f.cid, &b_dev), 0, "a tampered package is refused");
    // For another circle (validly signed for it).
    let (other, _) = KeyPackage::generate(&b_device, &b_cred, b"some-other-circle").unwrap();
    let _ = feed(&other);
    assert_eq!(held_packages(&a.s, &f.cid, &b_dev), 0, "a package for another circle is refused");
    // From a device B's account signed a credential for but its verified roster does not list.
    let rogue = Identity::from_seed(&[77u8; 32]);
    let rogue_id = rogue.public().node_id_bytes();
    let rogue_cred = DeviceCredential::issue(&Identity::from_seed(&b.account_seed), &rogue.public(), "rogue", 1);
    let (unlisted, _) = KeyPackage::generate(&rogue, &rogue_cred, f.cid.as_bytes()).unwrap();
    let _ = feed(&unlisted);
    assert_eq!(held_packages(&a.s, &f.cid, &rogue_id), 0, "a device outside the verified roster is refused");
    // From a device whose credential some other account signed.
    let forged_cred = DeviceCredential::issue(&Identity::from_seed(&[78u8; 32]), &rogue.public(), "rogue", 1);
    let (forged, _) = KeyPackage::generate(&rogue, &forged_cred, f.cid.as_bytes()).unwrap();
    let _ = feed(&forged);
    assert_eq!(held_packages(&a.s, &f.cid, &rogue_id), 0);

    // B's real package: accepted (the refusals above have teeth), and the genesis uses it.
    let b_first: Vec<u8> =
        b.s.sync_envelopes(f.cid.clone()).into_iter().find(|e| e.first() == Some(&TAG_MLS2_KEYPACKAGE)).unwrap();
    let b_first_kp = KeyPackage::from_bytes(&b_first[1..]).unwrap();
    let _ = feed(&b_first_kp);
    assert_eq!(held_packages(&a.s, &f.cid, &b_dev), 1, "a valid package from an authorized device is accepted");
    sync_fleet(&f, 6);
    assert_eq!(lane(&a.s, &f.cid), 2);
    let in_tree = |s: &HavenSocial, kp: &KeyPackage| {
        v2_state(s, &f.cid).unwrap().tree.slots.iter().any(|x| matches!(x, treekem::TreeSlot::Leaf(l) if l.leaf_kem_x == kp.leaf.leaf_kem_x))
    };
    assert!(in_tree(&a.s, &b_first_kp), "B's leaf is the one from its key package, verbatim");
    assert_eq!(held_packages(&a.s, &f.cid, &b_dev), 0, "a used package is not kept");

    // REPLAY of the used package: refused, and nothing comes of it.
    let epoch = a.s.mls_keying_status(f.cid.clone()).epoch;
    let commits = a.s.state.lock().unwrap().v2_trees.get(&f.cid).unwrap().commits.len();
    let _ = feed(&b_first_kp);
    assert_eq!(held_packages(&a.s, &f.cid, &b_dev), 0, "a package the chain already used is refused on replay");
    sync_fleet(&f, 3);
    assert_eq!(a.s.state.lock().unwrap().v2_trees.get(&f.cid).unwrap().commits.len(), commits, "a replayed package causes no commit");
    assert_eq!(a.s.mls_keying_status(f.cid.clone()).epoch, epoch);
    assert!(in_tree(&a.s, &b_first_kp));
}

/// RE-ENTRY. A device that lost its place in the tree (here: its whole v2 state) gets back in
/// with a FRESH key package — `Remove(old leaf) + Add(new package)` in one commit and a v2
/// Welcome — and what it held before (the old leaf secret, the old epoch's secrets) derives
/// nothing of the new epoch.
#[test]
fn a_stranded_device_reenters_with_a_fresh_key_package() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    let bi = (ci + 1) % 3;
    let (a, b) = (&f.devs[ci], &f.devs[bi]);
    post(&a.s, &f.cid, "before-loss", 1_000);
    sync_fleet(&f, 2);
    let epoch = a.s.mls_keying_status(f.cid.clone()).epoch;
    // The thief's copy: B's whole stored state at this epoch.
    let stolen = b.s.export_state();
    let old_leaf = v2_state(&b.s, &f.cid).unwrap().my_private.as_ref().unwrap().leaf_secret;
    let old_key = treekem::node_keypair_from_path_secret(&old_leaf).kem_x;

    // B loses its place: no entry point, no checkpoint, no key package secrets.
    {
        let mut st = b.s.state.lock().unwrap();
        let t = st.v2_trees.get_mut(&f.cid).unwrap();
        t.my_welcomes.clear();
        t.checkpoint = None;
        t.x_forget_packages();
    }
    assert!(v2_state(&b.s, &f.cid).is_none(), "B cannot derive the tree any more");
    let offer: Vec<Vec<u8>> =
        b.s.sync_envelopes(f.cid.clone()).into_iter().filter(|e| e.first() == Some(&TAG_MLS2_KEYPACKAGE)).collect();
    assert_eq!(offer.len(), 1, "B offers a fresh key package");
    assert_ne!(KeyPackage::from_bytes(&offer[0][1..]).unwrap().leaf.leaf_kem_x, old_key, "with a new leaf key");

    sync_fleet(&f, 5);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(lane(&d.s, &f.cid), 2, "device {i} is keyed by the v2 tree again");
        assert_eq!(d.s.mls_keying_status(f.cid.clone()).epoch, epoch + 1, "device {i}: one commit re-seated B");
    }
    // That commit is Remove + Add, and B's leaf carries the new key.
    {
        let st = a.s.state.lock().unwrap();
        let t = st.v2_trees.get(&f.cid).unwrap();
        let cur = mls_replay(t, None).unwrap();
        let c = treekem::Commit::from_bytes(&t.commits[&cur.tip_hash]).unwrap();
        let kinds: Vec<&str> = c
            .proposals
            .iter()
            .map(|p| match p.body {
                treekem::ProposalBody::Remove { .. } => "remove",
                treekem::ProposalBody::Add { .. } => "add",
                treekem::ProposalBody::Update { .. } => "update",
            })
            .collect();
        assert_eq!(kinds, ["remove", "add"], "re-entry is Remove(old leaf) + Add(fresh package) in one commit");
        assert!(!cur.tree.slots.iter().any(|s| matches!(s, treekem::TreeSlot::Leaf(l) if l.leaf_kem_x == old_key)), "the old leaf is out of the tree");
        assert!(!cur.removed_devices.contains(&b.device_id()), "a re-entry is not a (sticky) removal");
    }
    post(&a.s, &f.cid, "after-reentry", 2_000);
    post(&b.s, &f.cid, "b-is-back", 2_100);
    sync_fleet(&f, 3);
    assert!(reads(&b.s, &f.cid, "after-reentry") && reads(&b.s, &f.cid, "before-loss"), "B reads again, history included");
    assert!(reads(&a.s, &f.cid, "b-is-back") && reads(&f.devs[(ci + 2) % 3].s, &f.cid, "b-is-back"));

    // The thief: B's stolen state, fed every public wire since. Its leaf was removed by the
    // re-entry commit, so it cannot derive the new epoch — and it holds no secret for the fresh
    // package, so the new Welcome does not open for it either.
    let ghost = s1_relaunch(b.account_seed, b.device_seed, stolen);
    introduce_one(&f, &ghost, b.account_seed);
    assert_eq!(v2_state(&ghost, &f.cid).map(|k| k.epoch), Some(epoch), "the stolen state derives the epoch it was taken at (the control)");
    for _ in 0..3 {
        for d in &f.devs {
            for e in d.s.sync_envelopes(f.cid.clone()) {
                let _ = ghost.receive(f.cid.clone(), e);
            }
        }
    }
    let g = v2_state(&ghost, &f.cid);
    assert!(g.as_ref().is_none_or(|k| k.sender_root.is_none()), "the old state does not derive the re-entry epoch");
    assert!(!reads(&ghost, &f.cid, "after-reentry"), "and cannot read what was posted after it");
    assert!(reads(&ghost, &f.cid, "before-loss"), "(it holds what it could read before)");
}

/// Capability + rosters for one relaunched engine of `account_seed`.
fn introduce_one(f: &Fleet, s: &HavenSocial, account_seed: [u8; 32]) {
    for (seed, list, creds) in &f.rosters {
        let d = f.devs.iter().find(|d| d.account_seed == *seed).unwrap();
        if *seed == account_seed {
            let _ = s.set_my_device_roster(list.clone(), creds.clone());
        } else {
            let _ = s.ingest_device_roster(d.s.my_bundle(), list.clone(), creds.clone());
            s.profile_seed_drop_version(d.s.my_bundle(), card(&d.s, "m"));
        }
    }
}

/// Kill + relaunch every device from its saved state.
fn relaunch_all(f: &Fleet) -> Fleet {
    let devs: Vec<Dev> = f
        .devs
        .iter()
        .map(|d| Dev {
            s: s1_relaunch(d.account_seed, d.device_seed, d.s.export_state()),
            account_seed: d.account_seed,
            device_seed: d.device_seed,
        })
        .collect();
    let g = Fleet { cid: f.cid.clone(), devs, rosters: f.rosters.clone() };
    for d in &g.devs {
        introduce_one(&g, &d.s, d.account_seed);
    }
    g
}

fn v2_wires(s: &HavenSocial, cid: &str) -> std::collections::BTreeSet<Vec<u8>> {
    s.sync_envelopes(cid.to_string()).into_iter().filter(|e| is_v2_wire(e)).collect()
}

/// RESTART. Every device is killed and relaunched from its saved state in the middle of the
/// migration (the v2 genesis built but not yet sent) and again after it. Nothing is minted a
/// second time: the same key packages, the same genesis, the same Welcomes — and the fleet ends
/// keyed by the v2 tree with every post readable.
#[test]
fn a_restart_mid_migration_and_after_it_mints_nothing_twice() {
    let _clk = clock_guard();
    let f = v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    post(&f.devs[0].s, &f.cid, "pre", 1_000);
    // Until the creator has BUILT the v2 genesis — and stop right there, before its bundle (the
    // genesis and every Welcome) is delivered: the others hold only their key packages' secrets.
    let mut rounds = 0;
    'built: loop {
        for i in 0..f.devs.len() {
            let out = f.devs[i].s.sync_envelopes(f.cid.clone());
            if v2_genesis_count(&f.devs[i].s, &f.cid) > 0 {
                break 'built;
            }
            for (j, d) in f.devs.iter().enumerate() {
                if i != j {
                    for e in &out {
                        let _ = d.s.receive(f.cid.clone(), e.clone());
                    }
                }
            }
        }
        rounds += 1;
        assert!(rounds < 8, "a v2 genesis is built");
    }
    assert!(f.devs.iter().all(|d| lane(&d.s, &f.cid) != 2), "the migration is still in flight");
    assert_eq!(f.devs.iter().filter(|d| v2_genesis_count(&d.s, &f.cid) > 0).count(), 1, "only its builder holds the genesis");
    let before: Vec<_> = f.devs.iter().map(|d| v2_wires(&d.s, &f.cid)).collect();
    assert!(before.iter().any(|w| w.iter().any(|e| e.first() == Some(&TAG_MLS2_COMMIT))));

    let g = relaunch_all(&f);
    for (i, d) in g.devs.iter().enumerate() {
        assert!(v2_wires(&d.s, &g.cid).is_subset(&before[i]), "device {i} minted no new v2 wire on relaunch (mid-migration)");
    }
    sync_fleet(&g, 6);
    post(&g.devs[2].s, &g.cid, "mid", 2_000);
    sync_fleet(&g, 2);
    for (i, d) in g.devs.iter().enumerate() {
        assert_eq!(lane(&d.s, &g.cid), 2, "device {i} finished the migration after the restart");
        // (The creator account has two devices; the one that had not heard of its sibling's
        // genesis may validly build its own — the election picks one. Never more than that.)
        assert!(v2_genesis_count(&d.s, &g.cid) <= 2, "device {i}: no genesis was minted a second time");
        assert_eq!(v2_state(&d.s, &g.cid).unwrap().tip_hash, v2_state(&g.devs[0].s, &g.cid).unwrap().tip_hash, "device {i} is on the one elected chain");
        assert!(reads(&d.s, &g.cid, "pre") && reads(&d.s, &g.cid, "mid"));
    }
    let geneses = v2_genesis_count(&g.devs[0].s, &g.cid);

    // And once more, after the flip.
    let epoch = g.devs[0].s.mls_keying_status(g.cid.clone()).epoch;
    let before: Vec<_> = g.devs.iter().map(|d| v2_wires(&d.s, &g.cid)).collect();
    let h = relaunch_all(&g);
    for (i, d) in h.devs.iter().enumerate() {
        assert!(v2_wires(&d.s, &h.cid).is_subset(&before[i]), "device {i} minted no new v2 wire on relaunch (after the flip)");
        assert!(!d.s.sync_envelopes(h.cid.clone()).iter().any(|e| is_v1_tree_wire(e)), "device {i}: the v1 tree stays retired across a restart");
        assert!(!d.s.state.lock().unwrap().shadow_trees.contains_key(&h.cid));
    }
    post(&h.devs[1].s, &h.cid, "post", 3_000);
    sync_fleet(&h, 3);
    for (i, d) in h.devs.iter().enumerate() {
        assert_eq!(lane(&d.s, &h.cid), 2);
        assert_eq!(d.s.mls_keying_status(h.cid.clone()).epoch, epoch, "device {i} is on the epoch it was on");
        assert_eq!(v2_genesis_count(&d.s, &h.cid), geneses, "device {i}: no new genesis after the second restart");
        assert!(reads(&d.s, &h.cid, "post") && reads(&d.s, &h.cid, "pre"));
    }
}

/// NEVER DARK. A circle keyed by the v2 tree for more than four epochs gets a new device that
/// offers no key package (an older build under an upgraded account). The circle PARKS on the
/// sender-keys lane — posts flow in every direction, to the new device too — and when that
/// device does offer a package it is Added and the tree keys the circle again.
#[test]
fn a_new_device_without_a_key_package_parks_the_circle_and_its_upgrade_resumes_it() {
    let _clk = clock_guard();
    let mut f = live_v2_fleet(&[(A, &[A1]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    for _ in 0..5 {
        update(&f, ci); // deep enough that every sender key from before the tree is long pruned
    }
    post(&f.devs[0].s, &f.cid, "tree-keyed", 1_000);
    sync_fleet(&f, 2);

    // Account B links a second device. It is wired like any device; its v2 wires are held back to
    // model a build that does not have them.
    let b_seed = B;
    let new = HavenSocial::new(b_seed.to_vec()).unwrap();
    assert!(new.use_device_identity(B2.to_vec()));
    new.create_circle(f.cid.clone(), "fleet".into());
    let ri = f.rosters.iter().position(|r| r.0 == b_seed).unwrap();
    let mut creds = f.rosters[ri].2.clone();
    creds.push(crate::multidevice::issue_device_credential(b_seed.to_vec(), new.my_device_bundle(), "d".into(), 2).unwrap());
    let ids: Vec<Vec<u8>> = [B1, B2].iter().map(|d| Identity::from_seed(d).public().node_id_bytes().to_vec()).collect();
    f.rosters[ri] = (b_seed, crate::multidevice::sign_device_list(b_seed.to_vec(), 2, 0, ids, vec![]).unwrap(), creds);
    f.devs.push(Dev { s: new, account_seed: b_seed, device_seed: B2 });
    let ni = f.devs.len() - 1;
    introduce(&f);
    let creator = f.devs[ci].account_hex();
    assert!(f.devs[ni].s.set_circle_creator(f.cid.clone(), creator));
    f.devs[ni].s.set_mls_keying(true);

    let old_build = |from: usize, to: usize, e: &[u8]| (from == ni || to == ni) && is_v2_wire(e);
    deliver(&f, 3, &old_build);
    for (i, d) in f.devs.iter().enumerate().filter(|(i, _)| *i != ni) {
        assert_eq!(lane(&d.s, &f.cid), 0, "device {i} parked on the sender-keys lane");
        assert_eq!(d.s.mls_keying_status(f.cid.clone()).state, "parked");
        assert!(d.s.sync_envelopes(f.cid.clone()).iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)), "device {i} emits a KeyCommit again");
        assert!(!d.s.sync_envelopes(f.cid.clone()).iter().any(|e| is_v1_tree_wire(e)), "device {i} does not fall back to a v1 tree");
    }
    for (i, d) in f.devs.iter().enumerate() {
        post(&d.s, &f.cid, &format!("parked-from-{i}"), 2_000 + i as u64);
    }
    deliver(&f, 3, &old_build);
    for (i, d) in f.devs.iter().enumerate() {
        for j in 0..f.devs.len() {
            assert!(reads(&d.s, &f.cid, &format!("parked-from-{j}")), "parked: device {i} cannot read device {j}'s post");
        }
    }
    assert!(reads(&f.devs[ni].s, &f.cid, "tree-keyed"), "the new device reads history (re-sealed under the sender key)");

    // The device upgrades: its key package gets through, the committer Adds it, the tree keys again.
    sync_fleet(&f, 6);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(lane(&d.s, &f.cid), 2, "device {i} is keyed by the v2 tree again");
    }
    post(&f.devs[ni].s, &f.cid, "resumed", 3_000);
    sync_fleet(&f, 2);
    for (i, d) in f.devs.iter().enumerate() {
        assert!(reads(&d.s, &f.cid, "resumed"), "device {i} reads the resumed circle");
        assert!(reads(&d.s, &f.cid, "parked-from-0"));
    }
}

/// A build that does not pass the v2 gate (here: a fleet that advertises `ml: 1`) treats every v2
/// wire as a no-op: nothing stored, nothing parked for retry, and it emits none.
#[test]
fn v2_wires_are_inert_without_the_gate() {
    let _clk = clock_guard();
    let f = v2_fleet(&[(A, &[A1]), (B, &[B1])]);
    sync_fleet(&f, 6);
    let wires: Vec<Vec<u8>> =
        f.devs.iter().flat_map(|d| d.s.sync_envelopes(f.cid.clone())).filter(|e| is_v2_wire(e)).collect();
    assert!([TAG_MLS2_COMMIT, TAG_MLS2_WELCOME, TAG_MLS2_JOIN].iter().all(|t| wires.iter().any(|e| e.first() == Some(t))));
    let (insts, cid) = mls_capable_fleet(&[A, B], &[A1, B1], 0); // a v1-only fleet
    for s in &insts {
        s.set_mls_keying(true);
        for e in &wires {
            assert!(matches!(s.receive(cid.clone(), e.clone()), Ok(false)));
        }
        let st = s.state.lock().unwrap();
        assert!(!st.v2_trees.contains_key(&cid), "nothing of a v2 wire is stored");
        assert!(st.circles.iter().find(|c| c.id == cid).unwrap().pending_tree.is_empty(), "and nothing is parked for retry");
        drop(st);
        assert!(!s.sync_envelopes(cid.clone()).iter().any(|e| is_v2_wire(e)), "an `ml: 1` fleet emits no v2 wire");
    }
}

// ── The key lanes (review of the stage-1 change) ──────────────────────────────────────────────

/// A circle the v1 tree keyed PAST tree epoch 4 parks (the switch goes off) and keeps working:
/// posting does not panic, the bundle is not empty, and every device reads every other's posts
/// on the sender-keys lane. Before the per-lane window the tree keys' epoch numbers evicted every
/// sender key — the current one included.
#[test]
fn a_tree_keyed_circle_past_epoch_four_parks_without_losing_its_sender_keys() {
    let _clk = clock_guard();
    let seeds = [[71u8; 32], [72u8; 32], [73u8; 32]];
    // The committer is the account with the lowest id; the fleet is built with it as the creator.
    let ids: Vec<[u8; 32]> = seeds.iter().map(|s| Identity::from_seed(s).public().node_id_bytes()).collect();
    let ci = (0..3).min_by_key(|i| ids[*i]).unwrap();
    let (insts, cid) = mls_capable_fleet(&seeds, &[[81u8; 32], [82u8; 32], [83u8; 32]], ci);
    let fleet: Vec<&Arc<HavenSocial>> = insts.iter().collect();
    // Sender-keys content first, so every device holds every other's sender key.
    sync_all(&fleet, &cid, 2);
    for (i, s) in insts.iter().enumerate() {
        post(s, &cid, &format!("legacy-{i}"), 100 + i as u64);
    }
    sync_all(&fleet, &cid, 2);
    flip_and_join(&insts, &cid);
    for _ in 0..6 {
        s1_update(&insts[ci], &fleet, &cid);
    }
    assert_eq!(insts[0].mls_keying_status(cid.clone()).epoch, 7);
    for (i, s) in insts.iter().enumerate() {
        post(s, &cid, &format!("tree-{i}"), 1_000 + i as u64);
    }
    sync_all(&fleet, &cid, 2);
    for s in &insts {
        let st = s.state.lock().unwrap();
        let c = st.circles.iter().find(|c| c.id == cid).unwrap();
        assert!(c.my_epoch_keys.contains_key(&c.my_epoch), "the current sender key survives a tree-keyed stretch");
        assert_eq!(c.my_epoch_keys.keys().filter(|e| epoch_lane(**e) == 1).count(), 4, "the tree lane keeps its own four");
        assert!(c.my_epoch_keys.keys().filter(|e| epoch_lane(**e) == 0).count() <= 1, "a lane nothing is added to shrinks to one key");
    }

    // PARK: the switch goes off everywhere.
    for s in &insts {
        s.set_mls_keying(false);
    }
    for (i, s) in insts.iter().enumerate() {
        post(s, &cid, &format!("parked-{i}"), 2_000 + i as u64); // must not panic
        assert!(s.sync_envelopes(cid.clone()).iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)), "device {i}: a parked circle emits its KeyCommit");
    }
    sync_all(&fleet, &cid, 2);
    for (i, s) in insts.iter().enumerate() {
        for j in 0..insts.len() {
            for tag in ["legacy", "tree", "parked"] {
                assert!(reads(s, &cid, &format!("{tag}-{j}")), "device {i} cannot read `{tag}-{j}` after the park");
            }
        }
    }
    // A parked post that arrives BEFORE its KeyCommit waits for it (it is not dropped as a fossil
    // just because tree keys with huge epoch numbers are still held).
    insts[0].state.lock().unwrap().circles.iter_mut().find(|c| c.id == cid).unwrap().rotate_epoch();
    post(&insts[0], &cid, "parked-late-key", 3_000);
    let out = insts[0].sync_envelopes(cid.clone());
    for e in out.iter().filter(|e| e.first() == Some(&TAG_EPOCH_EVENT)) {
        let _ = insts[1].receive(cid.clone(), e.clone());
    }
    assert!(!reads(&insts[1], &cid, "parked-late-key"));
    for e in out.iter().filter(|e| e.first() == Some(&TAG_KEY_COMMIT)) {
        let _ = insts[1].receive(cid.clone(), e.clone());
    }
    assert!(reads(&insts[1], &cid, "parked-late-key"), "the parked post opened once its key arrived");
}

/// `epochs_to_keep`, case by case.
#[test]
fn the_key_window_is_applied_per_lane() {
    let t = MLS_EPOCH_BASE;
    let u = MLS2_EPOCH_BASE;
    let keep = |e: &[u64], active: u8, protect: Option<u64>| {
        let mut v: Vec<u64> = epochs_to_keep(e, active, 4, protect).into_iter().collect();
        v.sort_unstable();
        v
    };
    // One lane: the four highest, as always.
    assert_eq!(keep(&[1, 2, 3, 4, 5, 6], 0, None), [3, 4, 5, 6]);
    assert_eq!(keep(&[t + 1, t + 2, t + 3, t + 4, t + 5], 1, None), [t + 2, t + 3, t + 4, t + 5]);
    // Tree-keyed with a short tree lane: the sender keys are all still there.
    assert_eq!(keep(&[5, 6, 7, 8, t + 1, t + 2], 1, None), [5, 6, 7, 8, t + 1, t + 2]);
    // Tree-keyed with a full tree lane: the idle sender lane shrinks to its newest key...
    assert_eq!(keep(&[5, 6, 7, 8, t + 1, t + 2, t + 3, t + 4], 1, None), [8, t + 1, t + 2, t + 3, t + 4]);
    // ...and my current sender epoch is never pruned, even when it is not the newest number.
    assert_eq!(keep(&[5, 6, 7, 8, t + 1, t + 2, t + 3, t + 4], 1, Some(6)), [6, 8, t + 1, t + 2, t + 3, t + 4]);
    // Parked: the sender lane is active and keeps four; the tree lanes keep their own.
    assert_eq!(keep(&[5, 6, 7, t + 3, t + 4], 0, None), [5, 6, 7, t + 3, t + 4]);
    // ...until the sender lane has a full window again; then the idle tree lane is down to one.
    assert_eq!(keep(&[5, 6, 7, 8, 9, t + 3, t + 4], 0, None), [6, 7, 8, 9, t + 4]);
    // Keyed by the v1 tree, already holding the v2 tree's current key: both survive.
    assert_eq!(keep(&[t + 1, t + 2, t + 3, t + 4, t + 5, u + 1], 1, None), [t + 2, t + 3, t + 4, t + 5, u + 1]);
    // Keyed by the v2 tree for a full window: one v1 key left, then it is the v2 lane's four.
    assert_eq!(keep(&[t + 4, t + 5, u + 1, u + 2, u + 3, u + 4, u + 5], 2, None), [t + 5, u + 2, u + 3, u + 4, u + 5]);
}

/// THE AUTHORING GUARD. A committer whose replay cannot get past its own commit must not author a
/// second commit on the same tip: (1) the build record is there but does not reproduce the commit;
/// (2) the build record is gone (a restore from an older save), the commit itself is still held.
/// Either way the next due Update is refused — no sibling is minted. The control: with the record
/// intact the same due Update IS authored.
#[test]
fn a_committer_stuck_behind_its_own_commit_authors_no_sibling() {
    let _clk = clock_guard();
    let commits = |s: &Arc<HavenSocial>, cid: &str| s.state.lock().unwrap().shadow_trees.get(cid).unwrap().commits.len();
    let make_due = |s: &Arc<HavenSocial>, cid: &str| {
        s.state.lock().unwrap().circles.iter_mut().find(|c| c.id == cid).unwrap().rotated_at = 1;
    };
    for case in ["broken record", "lost record", "control"] {
        let (insts, cid) = mls_capable_fleet(&[[71u8; 32], [72u8; 32]], &[[81u8; 32], [82u8; 32]], 0);
        let (a, b) = (&insts[0], &insts[1]);
        flip_and_join(&insts, &cid);
        s1_update(a, &[a, b], &cid); // an own commit X on the genesis: epoch 2
        let before = commits(a, &cid);
        if case != "control" {
            let mut st = a.state.lock().unwrap();
            let t = st.shadow_trees.get_mut(&cid).unwrap();
            assert_eq!(t.own_builds.len(), 1);
            if case == "lost record" {
                t.own_builds.clear();
            } else {
                t.own_builds.values_mut().next().unwrap().new_leaf = [9u8; 32];
            }
            let cur = mls_replay(t, Some([81u8; 32])).unwrap();
            assert_eq!(cur.epoch, 1, "{case}: the walk can no longer pass the own commit");
            assert!(keying_already_authored_on(t, &cur), "{case}: the guard sees it");
        }
        make_due(a, &cid);
        let _ = a.sync_envelopes(cid.clone());
        let expect = if case == "control" { before + 1 } else { before };
        assert_eq!(commits(a, &cid), expect, "{case}: commits after a due Update");
    }
}
