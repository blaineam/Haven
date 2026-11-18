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

/// Make one device's own leaf Update due (its window stamps go back; the clock does not move).
fn make_due(f: &Fleet, i: usize) {
    f.devs[i].s.state.lock().unwrap().v2_trees.get_mut(&f.cid).unwrap().x_make_update_due();
}

/// Make a device's weekly leaf Update due and run it: one new tree epoch everywhere. (The window
/// is per device since member updates; it used to be the circle's `rotated_at` stamp.)
fn update(f: &Fleet, committer: usize) {
    let before = f.devs[committer].s.mls_keying_status(f.cid.clone()).epoch;
    make_due(f, committer);
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
    for k in 0..5 {
        // Deep enough that every sender key from before the tree is long pruned. (Each device in
        // turn: one device no longer authors more than three Updates in a row — MAX_OWN_RUN.)
        update(&f, (ci + k) % 3);
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

// ══ Stage 4: member updates (docs/formal/STAGE4-MEMBER-UPDATES.md, PROTOCOL-SPEC §15, §16.4) ══

/// A small deterministic generator (xorshift64*), so a failing schedule can be replayed by seed.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// A network that delays, reorders and duplicates. An envelope a device sends is queued for each
/// other device with its own random delay (in steps); what falls due in a step is delivered in a
/// random order; one in five is delivered a second time, later. Like a content-addressed mailbox,
/// the same bytes are not queued for the same device twice (apart from those duplicates).
struct Net {
    rng: Rng,
    step: u64,
    max_delay: u64,
    queue: Vec<(u64, usize, Vec<u8>)>,
    sent: HashSet<(usize, [u8; 32])>,
    /// Distinct key packages offered after the fleet was live: each is one request to re-enter.
    key_packages: HashSet<[u8; 32]>,
    log: Vec<String>,
}

impl Net {
    fn new(seed: u64, max_delay: u64) -> Self {
        Net { rng: Rng(seed | 1), step: 0, max_delay, queue: Vec::new(), sent: HashSet::new(), key_packages: HashSet::new(), log: Vec::new() }
    }

    /// One step: every device in `senders` builds a full bundle from what it holds NOW (none sees
    /// another's bundle of this step first), then whatever is due is delivered, shuffled.
    fn run(&mut self, f: &Fleet, senders: &[usize]) {
        self.step += 1;
        for &i in senders {
            for e in f.devs[i].s.sync_envelopes(f.cid.clone()) {
                if e.first() == Some(&TAG_MLS2_KEYPACKAGE) && self.key_packages.insert(*blake3::hash(&e).as_bytes()) {
                    self.log.push(format!("step {}: device {i} asked to re-enter: {}", self.step, why_stranded(f, i)));
                }
                let id = *blake3::hash(&e).as_bytes();
                for j in (0..f.devs.len()).filter(|j| *j != i) {
                    if !self.sent.insert((j, id)) {
                        continue;
                    }
                    let at = self.step + self.rng.below(self.max_delay + 1);
                    self.queue.push((at, j, e.clone()));
                    if self.rng.below(5) == 0 {
                        self.queue.push((at + 1 + self.rng.below(3), j, e.clone()));
                    }
                }
            }
        }
        let (mut due, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut self.queue).into_iter().partition(|(at, _, _)| *at <= self.step);
        self.queue = rest;
        for k in (1..due.len()).rev() {
            due.swap(k, self.rng.below(k as u64 + 1) as usize);
        }
        for (_, to, e) in due {
            let _ = f.devs[to].s.receive(f.cid.clone(), e);
        }
    }

    /// Deliver everything still queued, then let every device talk — with no more delay — until
    /// the fleet has settled: every device on the same tip, keyed by the v2 tree, nobody asking
    /// to re-enter, for three rounds running. Key packages are aged between rounds, so a device
    /// that is not a committer does not sit out its hours-long wait before re-entering another.
    /// Returns whether it settled (within 40 rounds).
    fn quiesce(&mut self, f: &Fleet) -> bool {
        self.max_delay = 0;
        let all: Vec<usize> = (0..f.devs.len()).collect();
        let mut calm = 0;
        for _ in 0..40 {
            for d in &f.devs {
                if let Some(t) = d.s.state.lock().unwrap().v2_trees.get_mut(&f.cid) {
                    t.x_age_packages(8 * 60 * 60);
                }
            }
            let asked = self.key_packages.len();
            self.run(f, &all);
            let tips: Vec<Option<[u8; 32]>> = f.devs.iter().map(|d| v2_state(&d.s, &f.cid).map(|k| k.tip_hash)).collect();
            let settled = self.queue.is_empty()
                && asked == self.key_packages.len()
                && tips[0].is_some()
                && tips.iter().all(|t| *t == tips[0])
                && f.devs.iter().all(|d| lane(&d.s, &f.cid) == 2 && !offers_key_package(&d.s, &f.cid));
            calm = if settled { calm + 1 } else { 0 };
            if calm >= 3 {
                return true;
            }
        }
        false
    }
}

/// Why a device's own chain and the chain its commit set agrees on differ: where they fork, how
/// deep each side is, and where the device's checkpoint sits.
fn why_stranded(f: &Fleet, i: usize) -> String {
    let st = f.devs[i].s.state.lock().unwrap();
    let t = st.v2_trees.get(&f.cid).unwrap();
    let parsed: HashMap<[u8; 32], treekem::Commit> =
        t.commits.iter().map(|(h, b)| (*h, treekem::Commit::from_bytes(b).unwrap())).collect();
    let chain = |mut at: [u8; 32]| {
        let mut v = Vec::new();
        while let Some(c) = parsed.get(&at) {
            v.push((at, c.epoch));
            at = c.parent_commit_hash;
        }
        v
    };
    let own = mls_replay(t, None).map(|k| (k.tip_hash, k.epoch));
    let agreed = t.x_canonical();
    let checkpoint = t.checkpoint.as_ref().map(|ck| ck.state.epoch);
    let (Some(own), Some(agreed)) = (own, agreed) else { return format!("own {own:?}, agreed {agreed:?}") };
    let (mine, theirs) = (chain(own.0), chain(agreed.0));
    let fork = mine.iter().find(|(h, _)| theirs.iter().any(|(g, _)| g == h)).map(|(_, e)| *e);
    let authors = |v: &[([u8; 32], u64)]| -> Vec<usize> {
        v.iter()
            .filter(|(_, e)| fork.is_some_and(|fe| *e > fe))
            .filter_map(|(h, _)| {
                let d = leaf_credential_ids(&parsed[h].update_path.as_ref()?.leaf_node.device_credential)?.0;
                f.devs.iter().position(|x| x.device_id() == d)
            })
            .collect()
    };
    format!(
        "own tip at epoch {}, agreed tip at epoch {}, they fork at epoch {fork:?}, checkpoint at {checkpoint:?}; own side authors (newest first) {:?}, agreed side authors {:?}, void {}",
        own.1,
        agreed.1,
        authors(&mine),
        authors(&theirs),
        t.x_void().len()
    )
}

/// What one fork-load run saw (printed).
#[derive(Debug)]
#[allow(dead_code)]
struct ForkLoad {
    seed: u64,
    max_delay: u64,
    rounds: u64,
    epochs: u64,
    commits: usize,
    /// Tips that got more than one child.
    fork_points: usize,
    /// The deepest branch that lost (commits on it).
    deepest_loser: usize,
    /// Requests to re-enter (distinct key packages offered after the fleet was live).
    reentries: usize,
    /// (device, post) pairs where a post made ON THE WAY does not open at the end.
    unreadable: usize,
}

/// One fork-load run: four devices of three accounts. In every round two or three of them come
/// due at once and re-key on whatever tip each holds, while one device posts; envelopes are
/// delayed up to `max_delay` steps (a round is three steps and stands for one update period),
/// reordered and duplicated. `Err` carries what went wrong and the schedule.
///
/// At quiescence: every device derives the same tip, with the same epoch secret; the circle is
/// keyed by the v2 tree on every device; a post made at the end opens on every device; nothing
/// more is authored. Devices MAY have re-entered on the way (a device whose branch lost below its
/// checkpoint has to): how many is reported. Posts made ON THE WAY that do not open at the end
/// are counted; with `strict` any such post fails the run. (One was seen in 56 schedules at a lag
/// of one period — STAGE4-MEMBER-UPDATES.md §12 — so the default tests count and the soak is
/// strict.)
fn fork_load(seed: u64, max_delay: u64, min_epochs: u64, strict: bool) -> Result<ForkLoad, String> {
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let n = f.devs.len();
    let all: Vec<usize> = (0..n).collect();
    let epoch0 = v2_tip(&f.devs[0].s, &f.cid).1;
    let mut net = Net::new(seed, max_delay);
    let mut posted: Vec<String> = Vec::new();
    let mut round = 0u64;
    // Rounds until every device is at least `min_epochs` past the start (bounded).
    loop {
        round += 1;
        let k = 2 + net.rng.below(2) as usize;
        let mut due: Vec<usize> = Vec::new();
        while due.len() < k {
            let d = net.rng.below(n as u64) as usize;
            if !due.contains(&d) {
                due.push(d);
            }
        }
        for d in &due {
            make_due(&f, *d);
        }
        let poster = net.rng.below(n as u64) as usize;
        let body = format!("s{seed:x}-r{round}-from-{poster}");
        post(&f.devs[poster].s, &f.cid, &body, 10_000 + round * 10);
        posted.push(body);
        net.log.push(format!("round {round}: due {due:?}"));
        // The due devices author concurrently; then a few steps of ordinary traffic from a random
        // half of the fleet, so deliveries interleave with later bundles.
        net.run(&f, &due);
        for _ in 0..2 {
            let talkers: Vec<usize> = all.iter().copied().filter(|_| net.rng.below(2) == 0).collect();
            net.run(&f, &talkers);
        }
        let min_epoch = f.devs.iter().filter_map(|d| v2_state(&d.s, &f.cid)).map(|k| k.epoch).min().unwrap_or(0);
        if min_epoch >= epoch0 + min_epochs || round >= 4 * min_epochs {
            break;
        }
    }
    let settled = net.quiesce(&f);
    let last = format!("s{seed:x}-at-the-end");
    post(&f.devs[(seed % n as u64) as usize].s, &f.cid, &last, 90_000);
    posted.push(last);
    sync_fleet(&f, 2);

    let schedule = format!("seed {seed:#x}, max delay {max_delay}, {round} rounds; {}", net.log.join("; "));
    let fail = |what: String| Err(format!("{what} — {schedule}"));
    if !settled {
        let state: Vec<String> = (0..n)
            .map(|i| {
                let (held, parked) = {
                    let st = f.devs[i].s.state.lock().unwrap();
                    let c = st.circles.iter().find(|c| c.id == f.cid).unwrap();
                    (st.v2_trees.get(&f.cid).map_or(0, |t| t.commits.len()), c.pending_tree.len())
                };
                format!(
                    "device {i}: lane {}, asking {}, {held} commits, {parked} parked wires, {}",
                    lane(&f.devs[i].s, &f.cid),
                    offers_key_package(&f.devs[i].s, &f.cid),
                    why_stranded(&f, i)
                )
            })
            .collect();
        // What some device holds and another does not, and what each has parked.
        let mut union: std::collections::BTreeMap<[u8; 32], Vec<u8>> = Default::default();
        for d in &f.devs {
            union.extend(v2_commits(&d.s, &f.cid));
        }
        let mut missing = Vec::new();
        for (i, d) in f.devs.iter().enumerate() {
            let have = v2_commits(&d.s, &f.cid);
            for (h, b) in union.iter().filter(|(h, _)| !have.contains_key(*h)) {
                let c = treekem::Commit::from_bytes(b).unwrap();
                let author = committer_of(&c).and_then(|a| f.devs.iter().position(|x| x.device_id() == a));
                let kinds: String = c
                    .proposals
                    .iter()
                    .map(|p| match &p.body {
                        treekem::ProposalBody::Remove { leaf_index } => format!("R{leaf_index} "),
                        treekem::ProposalBody::Add { leaf_node } => format!(
                            "A{:?} ",
                            leaf_credential_ids(&leaf_node.device_credential).and_then(|(a, _)| f.devs.iter().position(|x| x.device_id() == a))
                        ),
                        _ => "U ".into(),
                    })
                    .collect();
                let why = {
                    let st = d.s.state.lock().unwrap();
                    let idx = st.circles.iter().position(|c| c.id == f.cid).unwrap();
                    keying_v2::x_refusal(&st, idx, b)
                };
                missing.push(format!(
                    "device {i} lacks {:02x}{:02x} (epoch {}, by {author:?}, from leaf {}, [{kinds}], parent held: {}; {why})",
                    h[0],
                    h[1],
                    c.epoch,
                    c.sender_leaf,
                    have.contains_key(&c.parent_commit_hash)
                ));
            }
            let st = d.s.state.lock().unwrap();
            let c = st.circles.iter().find(|c| c.id == f.cid).unwrap();
            let tags: Vec<u8> = c.pending_tree.iter().filter_map(|w| w.first().copied()).collect();
            let seats: Vec<(Option<usize>, u32)> = mls_replay(st.v2_trees.get(&f.cid).unwrap(), None)
                .map(|k| leaves_by_device(&k.tree).into_iter().map(|(dv, li)| (f.devs.iter().position(|x| x.device_id() == dv), li)).collect())
                .unwrap_or_default();
            missing.push(format!("device {i} parked tags {tags:?}, seats {seats:?}, committer {}", i == committer_index(&f)));
        }
        return fail(format!("the fleet did not settle [{}] [{}]", state.join(" | "), missing.join(" | ")));
    }
    let Some(reference) = v2_state(&f.devs[0].s, &f.cid) else { return fail("device 0 derives nothing".into()) };
    let mut unreadable: Vec<String> = Vec::new();
    for (i, d) in f.devs.iter().enumerate() {
        let Some(k) = v2_state(&d.s, &f.cid) else { return fail(format!("device {i} derives nothing")) };
        if (k.tip_hash, k.epoch) != (reference.tip_hash, reference.epoch) {
            return fail(format!("device {i} is at epoch {} on another tip (device 0 at {})", k.epoch, reference.epoch));
        }
        if k.sender_root.is_none() || k.sender_root != reference.sender_root {
            return fail(format!("device {i} derives another epoch secret"));
        }
        if lane(&d.s, &f.cid) != 2 {
            return fail(format!("device {i} is not keyed by the v2 tree"));
        }
        if !d.s.mls_shadow_status(f.cid.clone()).converged {
            return fail(format!("device {i}: the public view disagrees with its tip"));
        }
        if !reads(&d.s, &f.cid, posted.last().unwrap()) {
            return fail(format!("device {i} cannot read the post made at the end"));
        }
        unreadable.extend(posted.iter().filter(|body| !reads(&d.s, &f.cid, body)).map(|body| format!("device {i}: `{body}`")));
        let st = d.s.state.lock().unwrap();
        let c = st.circles.iter().find(|c| c.id == f.cid).unwrap();
        if !c.my_epoch_keys.contains_key(&(MLS2_EPOCH_BASE + reference.epoch)) {
            return fail(format!("device {i} holds no content key for the current epoch"));
        }
    }
    let commits = v2_commits(&f.devs[0].s, &f.cid);
    let parsed: HashMap<[u8; 32], treekem::Commit> =
        commits.iter().map(|(h, b)| (*h, treekem::Commit::from_bytes(b).unwrap())).collect();
    let mut children: HashMap<[u8; 32], Vec<[u8; 32]>> = HashMap::new();
    for (h, c) in &parsed {
        children.entry(c.parent_commit_hash).or_default().push(*h);
    }
    fn depth(children: &HashMap<[u8; 32], Vec<[u8; 32]>>, h: &[u8; 32]) -> usize {
        1 + children.get(h).map_or(0, |cs| cs.iter().map(|c| depth(children, c)).max().unwrap_or(0))
    }
    let mut on_chain: HashSet<[u8; 32]> = HashSet::new();
    let mut at = reference.tip_hash;
    while let Some(c) = parsed.get(&at) {
        on_chain.insert(at);
        at = c.parent_commit_hash;
    }
    let deepest_loser = parsed.keys().filter(|h| !on_chain.contains(*h)).map(|h| depth(&children, h)).max().unwrap_or(0);
    // Quiet: with everything delivered, nobody authors anything more.
    let total: usize = f.devs.iter().map(|d| v2_commits(&d.s, &f.cid).len()).sum();
    sync_fleet(&f, 2);
    if f.devs.iter().map(|d| v2_commits(&d.s, &f.cid).len()).sum::<usize>() != total {
        return fail("commits kept coming after quiescence".into());
    }
    if strict && !unreadable.is_empty() {
        return fail(format!("posts made on the way do not open at the end: {}", unreadable.join(", ")));
    }
    Ok(ForkLoad {
        seed,
        max_delay,
        rounds: round,
        epochs: reference.epoch - epoch0,
        commits: commits.len(),
        fork_points: children.values().filter(|c| c.len() > 1).count(),
        deepest_loser,
        reentries: net.key_packages.len(),
        unreadable: unreadable.len(),
    })
}

/// `schedules` fork-load runs at one delay, side by side. Panics with every failing schedule.
fn fork_load_runs(max_delay: u64, schedules: u64, min_epochs: u64, strict: bool) {
    let _clk = clock_guard();
    let results: Vec<Result<ForkLoad, String>> = std::thread::scope(|scope| {
        let handles: Vec<_> = (1..=schedules)
            .map(|k| scope.spawn(move || fork_load(k * 0x9e37_79b9 + max_delay, max_delay, min_epochs, strict)))
            .collect();
        handles.into_iter().map(|h| h.join().unwrap_or_else(|_| Err("the run panicked".into()))).collect()
    });
    let mut failures = Vec::new();
    for r in &results {
        match r {
            Ok(run) => eprintln!("fork load: {run:?}"),
            Err(e) => failures.push(e.clone()),
        }
    }
    let reentries: Vec<usize> = results.iter().flatten().map(|r| r.reentries).collect();
    let unreadable: usize = results.iter().flatten().map(|r| r.unreadable).sum();
    eprintln!(
        "fork load, max delay {max_delay}: {} of {schedules} schedules converged; re-entries per schedule {reentries:?}; earlier posts that do not open at the end: {unreadable}",
        reentries.len()
    );
    assert!(failures.is_empty(), "{} of {schedules} schedules failed at max delay {max_delay}:\n{}", failures.len(), failures.join("\n"));
    assert!(results.iter().flatten().all(|r| r.epochs >= min_epochs && r.fork_points >= 3), "every schedule really forked");
}

/// FORK LOAD, delivery lagging by less than one update period (two steps of a three-step round).
#[test]
fn fork_load_converges_at_a_lag_under_one_period() {
    fork_load_runs(2, 10, 10, false);
}

/// FORK LOAD, delivery lagging by up to one update period.
#[test]
fn fork_load_converges_at_a_lag_of_one_period() {
    fork_load_runs(3, 10, 10, false);
}

/// FORK LOAD, delivery lagging by up to two update periods — where the depth-capped finality
/// rule left devices stranded on a branch that had lost (STAGE4-MEMBER-UPDATES.md §5).
#[test]
fn fork_load_converges_at_a_lag_of_two_periods() {
    fork_load_runs(6, 10, 10, false);
}

/// The same, longer and wider: `HAVEN_FORK_SEEDS` schedules (default 16) at
/// `HAVEN_FORK_DELAY` steps (default 9) over `HAVEN_FORK_EPOCHS` epochs (default 20).
/// `cargo test -p haven_ffi --lib fork_load_soak -- --ignored --nocapture`
#[test]
#[ignore]
fn fork_load_soak() {
    let get = |k: &str, d: u64| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
    fork_load_runs(get("HAVEN_FORK_DELAY", 9), get("HAVEN_FORK_SEEDS", 16), get("HAVEN_FORK_EPOCHS", 20), true);
}

fn v2_commits(s: &HavenSocial, cid: &str) -> std::collections::BTreeMap<[u8; 32], Vec<u8>> {
    s.state.lock().unwrap().v2_trees.get(cid).map(|t| t.commits.clone()).unwrap_or_default()
}

/// (tip hash, tree epoch) of the chain a device has adopted.
fn v2_tip(s: &HavenSocial, cid: &str) -> ([u8; 32], u64) {
    let k = v2_state(s, cid).expect("the device derives its chain");
    (k.tip_hash, k.epoch)
}

/// The id of the leaf key at this device's own leaf on its adopted tip.
fn my_leaf_x(s: &HavenSocial, cid: &str) -> Vec<u8> {
    let k = v2_state(s, cid).unwrap();
    k.tree.leaf(k.my_private.as_ref().unwrap().leaf_index).unwrap().leaf_kem_x.to_vec()
}

fn x_last_update(s: &HavenSocial, cid: &str) -> Option<([u8; 32], u64)> {
    s.state.lock().unwrap().v2_trees.get(cid).unwrap().x_last_update()
}

/// The v2 commit wires in `bundle` whose commit `before` does not hold.
fn new_commit_wires(before: &std::collections::BTreeMap<[u8; 32], Vec<u8>>, bundle: &[Vec<u8>]) -> Vec<Vec<u8>> {
    bundle
        .iter()
        .filter(|e| e.first() == Some(&TAG_MLS2_COMMIT) && !before.contains_key(&treekem::commit_hash(&e[1..])))
        .cloned()
        .collect()
}

/// Is `ancestor` the tip of this device's adopted chain, or a commit below it?
fn on_adopted_chain(s: &HavenSocial, cid: &str, ancestor: &[u8; 32]) -> bool {
    let commits = v2_commits(s, cid);
    let (mut at, _) = v2_tip(s, cid);
    for _ in 0..4096 {
        if at == *ancestor {
            return true;
        }
        let Some(c) = commits.get(&at).and_then(|b| treekem::Commit::from_bytes(b).ok()) else { return false };
        at = c.parent_commit_hash;
    }
    false
}

fn offers_key_package(s: &HavenSocial, cid: &str) -> bool {
    s.sync_envelopes(cid.to_string()).iter().any(|e| e.first() == Some(&TAG_MLS2_KEYPACKAGE))
}

/// What a crafted commit does differently from an honest member update.
#[derive(Default)]
struct Craft<'a> {
    /// The new leaf secret (default: random — an honest re-key).
    leaf_secret: Option<[u8; 32]>,
    /// Whose leaf the commit claims to be sent from and whose credential the new leaf carries
    /// (default: the author's own).
    as_device: Option<&'a Dev>,
    /// Leaf indices to Remove.
    removes: Vec<u32>,
    /// Key packages to Add (after the Removes).
    adds: Vec<KeyPackage>,
    /// Flip a bit of the confirmation MAC, then sign the commit properly.
    bad_mac: bool,
}

/// A commit on `author`'s current tip, built from its real keying state and signed with its real
/// device key — as a modified client would.
fn craft_commit(f: &Fleet, author: &Dev, how: Craft) -> Vec<u8> {
    let cur = v2_state(&author.s, &f.cid).unwrap();
    let gid = f.cid.as_bytes();
    let signer = Identity::from_seed(&author.device_seed);
    let claimed = how.as_device.unwrap_or(author).device_id();
    let leaf_index = leaves_by_device(&cur.tree).into_iter().find(|(d, _)| *d == claimed).map(|(_, li)| li).unwrap();
    let cred = cur.tree.leaf(leaf_index).unwrap().device_credential.clone();
    let next = cur.epoch + 1;
    let mut props: Vec<treekem::Proposal> = how
        .removes
        .iter()
        .map(|li| treekem::build_remove_proposal(gid, next, leaf_index, *li, |m| signer.sign(m)))
        .collect();
    for kp in &how.adds {
        props.push(treekem::build_add_proposal(gid, next, leaf_index, kp.leaf.clone(), |m| signer.sign(m)));
    }
    let new_leaf = how.leaf_secret.unwrap_or_else(keying_random_secret);
    let entropy = keying_random_secret();
    let mut build = treekem::build_commit(
        &cur.tree,
        gid,
        next,
        cur.tip_hash,
        &cur.cth,
        &cur.init_secret.unwrap(),
        leaf_index,
        props,
        Some((&new_leaf, &cred, &entropy)),
        |m| signer.sign(m),
        |m| signer.sign(m),
    )
    .expect("the crafted commit builds");
    if how.bad_mac {
        build.commit.confirmation_mac[0] ^= 1;
        build.commit.sig = signer.sign(&treekem::commit_signing_bytes(&build.commit));
    }
    build.commit.to_bytes()
}

/// The device whose leaf a chained commit's UpdatePath re-keys.
fn committer_of(c: &treekem::Commit) -> Option<[u8; 32]> {
    leaf_credential_ids(&c.update_path.as_ref()?.leaf_node.device_credential).map(|(d, _)| d)
}

/// (device id, leaf index) of every leaf.
fn leaves_by_device(tree: &treekem::RatchetTree) -> Vec<([u8; 32], u32)> {
    tree.slots
        .iter()
        .enumerate()
        .filter_map(|(i, s)| match s {
            treekem::TreeSlot::Leaf(l) if i % 2 == 0 => {
                leaf_credential_ids(&l.device_credential).map(|(d, _)| (d, (i / 2) as u32))
            }
            _ => None,
        })
        .collect()
}

/// Feed one crafted commit to a device; did it store it?
fn feed_commit(f: &Fleet, to: &Dev, commit: &[u8]) -> bool {
    let _ = to.s.receive(f.cid.clone(), tagged(TAG_MLS2_COMMIT, commit));
    v2_commits(&to.s, &f.cid).contains_key(&treekem::commit_hash(commit))
}

/// A device that is neither the committer nor of the committer's (admin) account.
fn plain_member(f: &Fleet) -> usize {
    let admin = f.devs[committer_index(f)].account_hex();
    f.devs.iter().position(|d| d.account_hex() != admin).unwrap()
}

/// T4, THE MEMBER UPDATE. A device that is not the committer and whose account is not an admin
/// re-keys its own leaf: the commit carries no proposals, every device follows it, content flows
/// both ways — and a copy of that device's ENTIRE stored state taken before the Update, fed every
/// public wire since, derives nothing of the new epoch. (On the tree before this stage the member
/// never authored anything: its stolen state kept opening every later commit.)
#[test]
fn a_plain_member_rekeys_its_own_leaf_and_its_stolen_state_stops_working() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let m = plain_member(&f);
    let member = &f.devs[m];
    post(&member.s, &f.cid, "before-update", 1_000);
    sync_fleet(&f, 2);
    let (tip0, epoch0) = v2_tip(&member.s, &f.cid);
    let stolen = member.s.export_state();
    let old_key = my_leaf_x(&member.s, &f.cid);

    // Not due: a full bundle authors nothing.
    let before = v2_commits(&member.s, &f.cid);
    sync_fleet(&f, 2);
    assert_eq!(v2_commits(&member.s, &f.cid).len(), before.len(), "no Update before the member's window has elapsed");

    update(&f, m);
    let (tip1, epoch1) = v2_tip(&member.s, &f.cid);
    assert_eq!(epoch1, epoch0 + 1);
    let c = treekem::Commit::from_bytes(&v2_commits(&f.devs[0].s, &f.cid)[&tip1]).unwrap();
    assert!(c.proposals.is_empty() && c.update_path.is_some() && c.parent_commit_hash == tip0, "a path-only commit on the old tip");
    assert_eq!(
        leaf_credential_ids(&c.update_path.as_ref().unwrap().leaf_node.device_credential).map(|(d, _)| d),
        Some(member.device_id()),
        "authored from the member's own leaf"
    );
    assert_ne!(my_leaf_x(&member.s, &f.cid), old_key, "the member's leaf key changed");
    assert_eq!(x_last_update(&member.s, &f.cid), Some((tip1, epoch1)), "and the member knows which commit re-keyed it");
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid), (tip1, epoch1), "device {i} adopted the member's Update");
        assert_eq!(lane(&d.s, &f.cid), 2);
    }
    post(&member.s, &f.cid, "after-update", 2_000);
    post(&f.devs[committer_index(&f)].s, &f.cid, "committer-after-update", 2_100);
    sync_fleet(&f, 2);
    for (i, d) in f.devs.iter().enumerate() {
        for body in ["before-update", "after-update", "committer-after-update"] {
            assert!(reads(&d.s, &f.cid, body), "device {i} cannot read `{body}`");
        }
    }

    // The thief: the member's stored state from before the Update, plus every public wire.
    let ghost = s1_relaunch(member.account_seed, member.device_seed, stolen);
    introduce_one(&f, &ghost, member.account_seed);
    assert_eq!(v2_state(&ghost, &f.cid).map(|k| k.epoch), Some(epoch0), "the stolen state derives the epoch it was taken at (the control)");
    for _ in 0..3 {
        for d in &f.devs {
            for e in d.s.sync_envelopes(f.cid.clone()) {
                let _ = ghost.receive(f.cid.clone(), e);
            }
        }
    }
    assert!(v2_commits(&ghost, &f.cid).contains_key(&tip1), "the thief holds the Update commit");
    assert_eq!(v2_state(&ghost, &f.cid).map(|k| k.epoch), Some(epoch0), "and cannot get past it");
    assert!(!reads(&ghost, &f.cid, "after-update") && !reads(&ghost, &f.cid, "committer-after-update"), "nothing posted after the Update opens");
}

/// WHAT IS ACCEPTED AS A MEMBER UPDATE — and what is not. Every refused commit is built from the
/// author's real keying state and signed with its real device key; the only thing wrong with each
/// is the one thing named. The membership rules are where they were: a plain member still cannot
/// Remove another account's leaf.
#[test]
fn a_member_update_is_accepted_only_for_the_authors_own_fresh_leaf() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1, B2]), (C, &[C1])]);
    let ci = committer_index(&f);
    let admin = f.devs[ci].account_hex();
    let members: Vec<usize> = (0..f.devs.len()).filter(|i| f.devs[*i].account_hex() != admin).collect();
    let (m, other) = (members[0], *members.iter().find(|i| f.devs[**i].account_hex() != f.devs[members[0]].account_hex()).unwrap());
    let (member, receiver) = (&f.devs[m], &f.devs[ci]);
    let cur = v2_state(&member.s, &f.cid).unwrap();
    let my_secret = cur.my_private.as_ref().unwrap().leaf_secret;
    let other_leaf = leaves_by_device(&cur.tree).into_iter().find(|(d, _)| *d == f.devs[other].device_id()).unwrap().1;

    // The leaf key does not change: it heals nothing.
    let same_key = craft_commit(&f, member, Craft { leaf_secret: Some(my_secret), ..Default::default() });
    assert!(!feed_commit(&f, receiver, &same_key), "an Update that keeps the leaf key is refused");
    // It claims another device's leaf (signed by the author, carrying the other's credential).
    let not_mine = craft_commit(&f, member, Craft { as_device: Some(&f.devs[other]), ..Default::default() });
    assert!(!feed_commit(&f, receiver, &not_mine), "an Update of another device's leaf is refused");
    // A plain member changing membership: Remove of another account's leaf.
    let remove = craft_commit(&f, member, Craft { removes: vec![other_leaf], ..Default::default() });
    assert!(!feed_commit(&f, receiver, &remove), "a plain member's Remove of another account's leaf is still refused");
    // The control: the same builder, nothing wrong — accepted, by every other device.
    let honest = craft_commit(&f, member, Craft::default());
    for (i, d) in f.devs.iter().enumerate().filter(|(i, _)| *i != m) {
        assert!(feed_commit(&f, d, &honest), "device {i} stores an honest member Update (the builder has teeth)");
    }

    // The roster rule is LISTED, not "authorized right now": an Update from a seated device its
    // account has since revoked is taken by a device that knows of the revocation exactly as by
    // one that does not — whether a commit is valid does not depend on when a roster arrived.
    // The revoked device is cut out by the Remove that follows, which every device adopts over
    // the Update's branch if the two compete. A device the roster does not list at all is not
    // taken.
    let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1, B2]), (C, &[C1])]);
    let ci = committer_index(&f);
    let admin = f.devs[ci].account_hex();
    // An account with two devices that is not the admin: revoke its second device.
    let (seed, _, creds) = f
        .rosters
        .iter()
        .find(|(seed, _, creds)| creds.len() == 2 && hex(&Identity::from_seed(seed).public().node_id_bytes()) != admin)
        .expect("a two-device member account")
        .clone();
    let of_account: Vec<usize> = (0..f.devs.len()).filter(|i| f.devs[*i].account_seed == seed).collect();
    let (keep, revoked) = (of_account[0], of_account[1]);
    let third = (0..f.devs.len()).find(|i| *i != ci && !of_account.contains(i)).unwrap();
    let before = v2_commits(&f.devs[revoked].s, &f.cid);
    make_due(&f, revoked);
    let wires = new_commit_wires(&before, &f.devs[revoked].s.sync_envelopes(f.cid.clone()));
    assert_eq!(wires.len(), 1, "the device authored its Update");
    let ids: Vec<Vec<u8>> = [keep, revoked].iter().map(|i| f.devs[*i].device_id().to_vec()).collect();
    let v2 = crate::multidevice::sign_device_list(seed.to_vec(), 2, 0, ids.clone(), vec![ids[1].clone()]).unwrap();
    assert!(f.devs[ci].s.ingest_device_roster(f.devs[keep].s.my_bundle(), v2, creds.clone()));
    assert!(feed_commit(&f, &f.devs[ci], &wires[0][1..]), "the device that knows of the revocation stores the revoked device's Update");
    assert!(feed_commit(&f, &f.devs[third], &wires[0][1..]), "and so does a device that does not know of it");
    sync_fleet(&f, 4);
    let gone = f.devs[revoked].device_id();
    let tip = v2_tip(&f.devs[ci].s, &f.cid);
    for i in [ci, keep, third] {
        let k = v2_state(&f.devs[i].s, &f.cid).unwrap();
        assert_eq!((k.tip_hash, k.epoch), tip, "device {i} is on the committer's tip");
        assert!(!tree_leaf_device_ids(&k.tree).contains(&gone), "device {i}: the revoked device was Removed");
    }
    post(&f.devs[ci].s, &f.cid, "after-revocation", 5_000);
    sync_fleet(&f, 2);
    assert!(reads(&f.devs[keep].s, &f.cid, "after-revocation") && !reads(&f.devs[revoked].s, &f.cid, "after-revocation"));
    // Not listed at all: the same kind of commit from a device whose account's roster the
    // receiver has never seen name it. (The receiver forgets the device, as if it never knew.)
    let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1, B2]), (C, &[C1])]);
    let ci = committer_index(&f);
    let m = plain_member(&f);
    let honest = craft_commit(&f, &f.devs[m], Craft::default());
    {
        let mut st = f.devs[ci].s.state.lock().unwrap();
        let account = Identity::from_seed(&f.devs[m].account_seed).public().node_id_bytes();
        let cd = st.device_lists.get_mut(&account).unwrap();
        let d = f.devs[m].device_id();
        cd.list.devices.retain(|x| *x != d);
    }
    assert!(!feed_commit(&f, &f.devs[ci], &honest), "an Update from a device the roster does not list is not stored");
}

/// Hold the test clock exclusively: no parallel test's skew leaks in, and this test may move it.
fn exclusive_clock() -> std::sync::RwLockWriteGuard<'static, ()> {
    CLOCK_LOCK.write().unwrap_or_else(|e| e.into_inner())
}

/// Run `f` with the clock `secs` ahead. The caller holds [`exclusive_clock`].
fn skewed<T>(secs: u64, f: impl FnOnce() -> T) -> T {
    use std::sync::atomic::Ordering;
    TEST_CLOCK_SKEW.fetch_add(secs, Ordering::Relaxed);
    let out = f();
    TEST_CLOCK_SKEW.fetch_sub(secs, Ordering::Relaxed);
    out
}

/// THE CADENCE. Every device re-keys its own leaf once its OWN window has elapsed — a week plus a
/// fixed per-device offset below 24 h. A fleet that entered together does not come due together:
/// a week and one second later nobody has updated, part-way through the offsets exactly the
/// devices whose offset has passed have, and a week and a day later every device has — each
/// exactly once, each on the chain everyone adopted.
#[test]
fn every_device_updates_on_its_own_window_spread_by_a_per_device_offset() {
    let _clk = exclusive_clock();
    // The circle id is minted at random, so the offsets differ from run to run. The steps below
    // move the clock to points between two offsets while real seconds pass too: take a circle
    // whose offsets are at least 20 minutes apart (and from zero). Most are.
    let (f, jitter, sorted) = (0..12)
        .find_map(|_| {
            let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
            let jitter: Vec<u64> = f.devs.iter().map(|d| keying_v2::update_jitter(&d.device_id(), f.cid.as_bytes())).collect();
            assert!(jitter.iter().all(|j| *j < keying_v2::UPDATE_JITTER_SECS), "every offset is below 24 h: {jitter:?}");
            let mut sorted = jitter.clone();
            sorted.sort_unstable();
            let spread = sorted[0] >= 1200 && sorted.windows(2).all(|w| w[1] - w[0] >= 1200);
            spread.then_some((f, jitter, sorted))
        })
        .expect("a circle whose per-device offsets are spread out");
    assert_ne!(
        keying_v2::update_jitter(&f.devs[0].device_id(), b"another-circle"),
        jitter[0],
        "and per circle"
    );
    assert_eq!(keying_v2::update_jitter(&f.devs[0].device_id(), f.cid.as_bytes()), jitter[0], "deterministic");

    let epoch0 = v2_tip(&f.devs[0].s, &f.cid).1;
    let updated = |f: &Fleet| -> Vec<bool> { f.devs.iter().map(|d| x_last_update(&d.s, &f.cid).is_some_and(|(_, e)| e > epoch0)).collect() };
    let committer_only: Vec<bool> = vec![false; f.devs.len()];

    // A week and a second: nobody (before this stage the committer fired here).
    skewed(ROTATE_INTERVAL_SECS + 1, || sync_fleet(&f, 2));
    assert_eq!(updated(&f), committer_only, "a week alone makes no device due");
    assert_eq!(v2_tip(&f.devs[0].s, &f.cid).1, epoch0);

    // Between the 2nd and the 3rd offset: exactly the two devices with the smallest offsets.
    let mid = ROTATE_INTERVAL_SECS + (sorted[1] + sorted[2]) / 2;
    skewed(mid, || sync_fleet(&f, 3));
    let expect: Vec<bool> = jitter.iter().map(|j| *j <= sorted[1]).collect();
    assert_eq!(updated(&f), expect, "only the devices whose own window has elapsed updated");
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid).1, epoch0 + 2, "device {i}: two Updates, two epochs");
    }

    // A week and a day after entering: the rest. The two that already updated are NOT due again
    // (their window restarted at their own Update).
    skewed(ROTATE_INTERVAL_SECS + keying_v2::UPDATE_JITTER_SECS, || sync_fleet(&f, 3));
    assert_eq!(updated(&f), vec![true; f.devs.len()]);
    let (tip, epoch) = v2_tip(&f.devs[0].s, &f.cid);
    assert_eq!(epoch, epoch0 + f.devs.len() as u64, "one Update per device, no more");
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid), (tip, epoch), "device {i} is on the same tip");
        let (mine, _) = x_last_update(&d.s, &f.cid).unwrap();
        assert!(on_adopted_chain(&d.s, &f.cid, &mine), "device {i}: its Update is on the chain it adopted");
    }
    post(&f.devs[1].s, &f.cid, "after-a-week", 5_000);
    sync_fleet(&f, 2);
    assert!(f.devs.iter().all(|d| reads(&d.s, &f.cid, "after-a-week")));
}

/// FK4 / FK5. Two devices re-key on the same tip at the same time. One Update wins the fork; the
/// other device's leaf is NOT re-keyed on the chain everyone adopts (a copy of its old state
/// derives the winning epoch — the model's FK4). That device notices its Update is not on its
/// adopted chain and authors a new one at its very next bundle, with no window to wait out — and
/// only then is it healed (the old copy cannot get past the re-issue: FK5). The winner authors
/// nothing more, and no further commit follows.
#[test]
fn an_update_that_lost_a_fork_is_reissued_at_the_next_bundle() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let (x, y) = (plain_member(&f), committer_index(&f));
    let (tip0, epoch0) = v2_tip(&f.devs[x].s, &f.cid);
    let stolen: Vec<Vec<u8>> = [x, y].iter().map(|i| f.devs[*i].s.export_state()).collect();
    let before = v2_commits(&f.devs[x].s, &f.cid);

    // Both come due and author on the same tip, neither having seen the other's commit.
    make_due(&f, x);
    make_due(&f, y);
    let bx = f.devs[x].s.sync_envelopes(f.cid.clone());
    let by = f.devs[y].s.sync_envelopes(f.cid.clone());
    let (ux, uy) = (new_commit_wires(&before, &bx), new_commit_wires(&before, &by));
    assert!(ux.len() == 1 && uy.len() == 1, "each authored one Update");
    let (hx, hy) = (treekem::commit_hash(&ux[0][1..]), treekem::commit_hash(&uy[0][1..]));
    for (from, bundle) in [(x, &bx), (y, &by)] {
        for (_, d) in f.devs.iter().enumerate().filter(|(j, _)| *j != from) {
            for e in bundle {
                let _ = d.s.receive(f.cid.clone(), e.clone());
            }
        }
    }
    // The fork rule (larger hash) picks one, the same one on every device.
    let winner_hash = hx.max(hy);
    let (loser, loser_hash, loser_blob) = if winner_hash == hx { (y, hy, &stolen[1]) } else { (x, hx, &stolen[0]) };
    let winner = if loser == x { y } else { x };
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid), (winner_hash, epoch0 + 1), "device {i} adopted the winning Update");
    }
    assert_eq!(x_last_update(&f.devs[loser].s, &f.cid), Some((loser_hash, epoch0 + 1)));
    assert!(!on_adopted_chain(&f.devs[loser].s, &f.cid, &loser_hash), "the loser's Update is not on its adopted chain");

    // FK4: the loser's OLD state derives the winning epoch — that branch did not heal it.
    let ghost = s1_relaunch(f.devs[loser].account_seed, f.devs[loser].device_seed, loser_blob.clone());
    introduce_one(&f, &ghost, f.devs[loser].account_seed);
    let feed_ghost = |ghost: &HavenSocial| {
        for _ in 0..2 {
            for d in &f.devs {
                for e in d.s.sync_envelopes(f.cid.clone()) {
                    let _ = ghost.receive(f.cid.clone(), e);
                }
            }
        }
    };

    // The loser's NEXT bundle re-issues — nothing was made due, no time passed.
    let n_before = v2_commits(&f.devs[loser].s, &f.cid).len();
    let _ = f.devs[loser].s.sync_envelopes(f.cid.clone());
    assert_eq!(v2_commits(&f.devs[loser].s, &f.cid).len(), n_before + 1, "the loser authored a new Update at its next bundle");
    let (reissue, at) = x_last_update(&f.devs[loser].s, &f.cid).unwrap();
    assert_eq!(at, epoch0 + 2);
    let c = treekem::Commit::from_bytes(&v2_commits(&f.devs[loser].s, &f.cid)[&reissue]).unwrap();
    assert_eq!(c.parent_commit_hash, winner_hash, "on the tip everyone adopted — not on its own losing commit, not on the old tip");
    assert_ne!(c.parent_commit_hash, tip0);
    sync_fleet(&f, 3);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid), (reissue, epoch0 + 2), "device {i} adopted the re-issued Update");
    }
    assert!(on_adopted_chain(&f.devs[loser].s, &f.cid, &reissue));
    // Quiet again: the winner's Update stands, nobody authors another commit.
    let total = v2_commits(&f.devs[0].s, &f.cid).len();
    sync_fleet(&f, 3);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_commits(&d.s, &f.cid).len(), total, "device {i}: no further commit (no update storm)");
        assert!(!offers_key_package(&d.s, &f.cid), "device {i} did not ask to re-enter");
    }
    assert_eq!(total, before.len() + 3, "two competing Updates and one re-issue");
    assert_eq!(x_last_update(&f.devs[winner].s, &f.cid).map(|(h, _)| h), Some(winner_hash));

    post(&f.devs[winner].s, &f.cid, "after-reissue", 3_000);
    sync_fleet(&f, 2);
    feed_ghost(&ghost);
    assert_eq!(v2_state(&ghost, &f.cid).map(|k| k.epoch), Some(epoch0 + 1), "FK4: the old state follows the winning branch; FK5: it stops at the re-issue");
    assert!(!reads(&ghost, &f.cid, "after-reissue"), "FK5: nothing after the re-issued Update opens for the old state");
    assert!(f.devs.iter().all(|d| reads(&d.s, &f.cid, "after-reissue")));
}

/// Every leaf and path secret a device's v2 tree state holds IN MEMORY, wherever it sits: the
/// checkpoint, the entry points, the own-build records, the key packages — and the replay memo.
fn held_tree_secrets(s: &HavenSocial, cid: &str) -> Vec<[u8; 32]> {
    let st = s.state.lock().unwrap();
    let t = st.v2_trees.get(cid).unwrap();
    let mut out: Vec<[u8; 32]> = t.x_own_secrets();
    let mut private = |p: &Option<treekem::TreePrivate>| {
        if let Some(p) = p {
            out.push(p.leaf_secret);
            out.extend(p.path_secrets.values().copied());
        }
    };
    if let Some(ck) = &t.checkpoint {
        private(&ck.state.my_private);
    }
    for (_, (end, candidate, _)) in t.replay_memo.lock().unwrap().iter() {
        if let Some(k) = end {
            private(&k.my_private);
        }
        if let Some(ck) = candidate {
            private(&ck.state.my_private);
        }
    }
    out.extend(t.my_welcomes.values().map(|w| w.leaf_secret));
    out.extend(t.own_builds.values().map(|b| b.new_leaf));
    out
}

/// THE OLD LEAF SECRET'S LIFETIME (PROTOCOL-SPEC §15). A member re-keys its leaf. The leaf secret
/// and the path secrets it held before are still in its state right after the Update and two
/// epochs later (a competing branch could still need them) — and are gone, from the exported
/// state AND from memory, the moment the checkpoint reaches the Update's epoch: not before, not
/// after.
#[test]
fn the_superseded_leaf_secret_dies_when_the_checkpoint_passes_the_update() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    let m = plain_member(&f);
    let others: Vec<usize> = (0..f.devs.len()).filter(|i| *i != ci && *i != m).collect();
    let member = &f.devs[m];
    update(&f, ci); // epoch 2: the member now holds path secrets too
    let old: Vec<[u8; 32]> = {
        let k = v2_state(&member.s, &f.cid).unwrap();
        let p = k.my_private.as_ref().unwrap();
        std::iter::once(p.leaf_secret).chain(p.path_secrets.values().copied()).collect()
    };
    assert!(old.len() >= 2, "a leaf secret and at least one path secret to follow");
    update(&f, m); // epoch 3: the member's Update
    let update_epoch = v2_tip(&member.s, &f.cid).1;
    let new_leaf = v2_state(&member.s, &f.cid).unwrap().my_private.as_ref().unwrap().leaf_secret;
    assert_ne!(new_leaf, old[0]);
    let scan = |when: &str, expect_old: bool| {
        let blob = s1_blob_bytes(&member.s.export_state());
        let memory = held_tree_secrets(&member.s, &f.cid);
        let checkpoint = member.s.state.lock().unwrap().v2_trees.get(&f.cid).unwrap().checkpoint.as_ref().map(|ck| ck.state.epoch);
        assert_eq!(s1_blob_has(&blob, &old[0]), expect_old, "{when} (checkpoint at {checkpoint:?}): old leaf secret in the exported state");
        assert_eq!(memory.contains(&old[0]), expect_old, "{when} (checkpoint at {checkpoint:?}): old leaf secret in memory");
        if !expect_old {
            for (i, s) in old.iter().enumerate() {
                assert!(!s1_blob_has(&blob, s), "{when}: superseded secret {i} is still in the exported state");
                assert!(!memory.contains(s), "{when}: superseded secret {i} is still in memory");
            }
            assert!(s1_blob_has(&blob, &new_leaf) && memory.contains(&new_leaf), "{when}: the scan finds the CURRENT leaf secret (it has teeth)");
        }
        checkpoint
    };
    scan("right after the Update", true);
    update(&f, others[0]);
    update(&f, others[1]);
    let ck = scan("two epochs after the Update", true);
    assert!(ck.is_some_and(|e| e < update_epoch), "the checkpoint has not reached the Update yet");
    update(&f, ci);
    let ck = scan("three epochs after the Update", false);
    assert_eq!(ck, Some(update_epoch), "the checkpoint is exactly at the Update's epoch");
    post(&member.s, &f.cid, "after-wipe", 4_000);
    sync_fleet(&f, 2);
    assert!(f.devs.iter().all(|d| reads(&d.s, &f.cid, "after-wipe")));
}

/// A DEVICE CUT OFF FROM THE CIRCLE. It keeps running full bundles and comes due week after week,
/// while the rest of the fleet moves on by more than the finality depth. It authors at most
/// `MAX_OWN_RUN` Updates on its own, so its branch never becomes final and its checkpoint never
/// passes the fork point — and when it reconnects it adopts the fleet's branch from the state it
/// still holds, re-issues its Update there, and never has to re-enter.
#[test]
fn a_device_cut_off_from_the_circle_cannot_make_its_own_branch_final() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let z = plain_member(&f);
    let rest: Vec<usize> = (0..f.devs.len()).filter(|i| *i != z).collect();
    let cut = |from: usize, to: usize, _: &[u8]| from == z || to == z;
    let (fork, epoch0) = v2_tip(&f.devs[z].s, &f.cid);
    post(&f.devs[z].s, &f.cid, "before-the-cut", 1_000);
    sync_fleet(&f, 2);

    for k in 0..5 {
        make_due(&f, rest[k % rest.len()]);
        deliver(&f, 2, &cut);
        make_due(&f, z);
        let _ = f.devs[z].s.sync_envelopes(f.cid.clone());
    }
    let fleet_tip = v2_tip(&f.devs[rest[0]].s, &f.cid);
    assert_eq!(fleet_tip.1, epoch0 + 5, "the fleet moved on five epochs");
    let own: usize = v2_commits(&f.devs[z].s, &f.cid)
        .values()
        .filter_map(|b| treekem::Commit::from_bytes(b).ok())
        .filter(|c| c.epoch > epoch0)
        .count();
    assert_eq!(own, keying_v2::MAX_OWN_RUN, "the cut-off device authored {own} Updates in a row");
    assert_eq!(v2_tip(&f.devs[z].s, &f.cid).1, epoch0 + keying_v2::MAX_OWN_RUN as u64);
    {
        let st = f.devs[z].s.state.lock().unwrap();
        let ck = st.v2_trees.get(&f.cid).unwrap().checkpoint.as_ref().map(|ck| ck.state.epoch);
        assert!(ck.is_none_or(|e| e <= epoch0), "its checkpoint has not passed the fork point (at {ck:?}, fork at {epoch0})");
    }
    post(&f.devs[z].s, &f.cid, "from-the-island", 2_000);
    post(&f.devs[rest[0]].s, &f.cid, "from-the-fleet", 2_100);

    // Reconnected.
    let mut reentry = false;
    for _ in 0..5 {
        for i in 0..f.devs.len() {
            let out = f.devs[i].s.sync_envelopes(f.cid.clone());
            reentry |= out.iter().any(|e| e.first() == Some(&TAG_MLS2_KEYPACKAGE));
            for (j, d) in f.devs.iter().enumerate() {
                if i != j {
                    for e in &out {
                        let _ = d.s.receive(f.cid.clone(), e.clone());
                    }
                }
            }
        }
    }
    assert!(!reentry, "no device offered a key package: nobody had to re-enter");
    // (The returned device may re-issue before the last fleet commits reach it, and that commit
    // may win a fork near the tip — so the exact tip is not fixed, only where it descends from.)
    let (tip, epoch) = v2_tip(&f.devs[z].s, &f.cid);
    assert!(epoch > fleet_tip.1, "the fleet's five epochs, plus the returned device's re-issued Update");
    let island: Vec<[u8; 32]> = v2_commits(&f.devs[z].s, &f.cid)
        .iter()
        .filter(|(_, b)| treekem::Commit::from_bytes(b).is_ok_and(|c| c.epoch == epoch0 + 1 && committer_of(&c) == Some(f.devs[z].device_id())))
        .map(|(h, _)| *h)
        .collect();
    assert_eq!(island.len(), 1, "the first commit of the cut-off device's own branch");
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid), (tip, epoch), "device {i} is on the same tip");
        assert_eq!(lane(&d.s, &f.cid), 2);
        assert!(on_adopted_chain(&d.s, &f.cid, &fork), "device {i} left the chain below the fork point");
        assert!(!on_adopted_chain(&d.s, &f.cid, &island[0]), "device {i} adopted the cut-off device's branch over the fleet's final one");
        for body in ["before-the-cut", "from-the-island", "from-the-fleet"] {
            assert!(reads(&d.s, &f.cid, body), "device {i} cannot read `{body}`");
        }
    }
    assert!(on_adopted_chain(&f.devs[z].s, &f.cid, &x_last_update(&f.devs[z].s, &f.cid).unwrap().0));
}

/// A VOID COMMIT. A member publishes an Update that is right in every public respect — its own
/// leaf, a fresh key, properly signed, the tree hash it claims — but whose confirmation MAC is
/// wrong, and which out-hashes the honest Update authored on the same tip. Every device that can
/// derive the epoch finds it void and takes the honest commit; none stops behind it, none asks to
/// re-enter; the verdict survives a restart.
#[test]
fn a_commit_with_a_bad_confirmation_mac_is_void_and_strands_nobody() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    let m = plain_member(&f);
    let honest = (0..f.devs.len()).find(|i| *i != ci && *i != m).unwrap();
    let epoch0 = v2_tip(&f.devs[m].s, &f.cid).1;
    let before = v2_commits(&f.devs[honest].s, &f.cid);
    make_due(&f, honest);
    let honest_bundle = f.devs[honest].s.sync_envelopes(f.cid.clone());
    let honest_hash = treekem::commit_hash(&new_commit_wires(&before, &honest_bundle)[0][1..]);
    // The bad commit, re-drawn until the fork rule prefers it to the honest one.
    let bad = (0..200)
        .map(|_| craft_commit(&f, &f.devs[m], Craft { bad_mac: true, ..Default::default() }))
        .find(|c| treekem::commit_hash(c) > honest_hash)
        .expect("a bad commit that out-hashes the honest one");
    let bad_hash = treekem::commit_hash(&bad);
    let victims: Vec<usize> = (0..f.devs.len()).filter(|i| *i != m).collect();
    for i in &victims {
        assert!(feed_commit(&f, &f.devs[*i], &bad), "device {i} stores it: every public check passes");
    }
    for (_, d) in f.devs.iter().enumerate().filter(|(j, _)| *j != honest) {
        for e in &honest_bundle {
            let _ = d.s.receive(f.cid.clone(), e.clone());
        }
    }
    sync_fleet(&f, 3);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid), (honest_hash, epoch0 + 1), "device {i} took the honest Update");
        assert_eq!(lane(&d.s, &f.cid), 2);
        assert!(!offers_key_package(&d.s, &f.cid), "device {i} does not ask to re-enter");
    }
    for i in &victims {
        let d = &f.devs[*i];
        assert_eq!(d.s.state.lock().unwrap().v2_trees.get(&f.cid).unwrap().x_void(), vec![bad_hash], "device {i} recorded the commit as void");
        assert!(d.s.mls_shadow_status(f.cid.clone()).converged, "device {i}: its tip is the one the public view agrees on");
    }
    // The fleet carries on over it, and a restart keeps the verdict.
    update(&f, ci);
    post(&f.devs[honest].s, &f.cid, "past-the-void", 3_000);
    sync_fleet(&f, 2);
    assert!(f.devs.iter().all(|d| reads(&d.s, &f.cid, "past-the-void")));
    let g = relaunch_all(&f);
    sync_fleet(&g, 2);
    for i in &victims {
        let d = &g.devs[*i];
        assert_eq!(d.s.state.lock().unwrap().v2_trees.get(&g.cid).unwrap().x_void(), vec![bad_hash], "device {i} still holds the verdict after a restart");
        assert_eq!(v2_tip(&d.s, &g.cid).1, epoch0 + 2);
        assert!(!offers_key_package(&d.s, &g.cid));
    }
}

/// A v2 state saved before member updates (version 1, no tail) loads; one saved now round-trips
/// with the new fields; and a device that loads the old form starts its Update window then — it
/// does not come due at once.
#[test]
fn a_v2_state_from_before_member_updates_loads_and_starts_its_window() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1]), (C, &[C1])]);
    let m = plain_member(&f);
    update(&f, m);
    let (old_form, new_form, last, kps) = {
        let st = f.devs[m].s.state.lock().unwrap();
        let t = st.v2_trees.get(&f.cid).unwrap();
        (t.x_state_v1_bytes(), keying_v2::encode_state(t), t.x_last_update(), t.x_entries())
    };
    assert_eq!(old_form[0], 1);
    assert_eq!(new_form[0], 3);
    // Version 2 (the first member-update build): one own commit, the same window stamps.
    let v2_form = f.devs[m].s.state.lock().unwrap().v2_trees.get(&f.cid).unwrap().x_state_v2_bytes();
    assert_eq!(v2_form[0], 2);
    let mut from_v2 = ShadowTree::new_v2(f.cid.as_bytes().to_vec());
    keying_v2::restore_state(&mut from_v2, &v2_form);
    assert!(from_v2.x_retired() && from_v2.x_leaf_at() > 0, "the version-2 fields load");
    assert_eq!(from_v2.x_last_update(), last, "and its one own commit becomes the list's entry");
    assert_eq!(keying_v2::encode_state(&from_v2), new_form, "which re-saves as version 3");
    assert!(last.is_some());
    let gid = f.cid.as_bytes().to_vec();
    let mut from_old = ShadowTree::new_v2(gid.clone());
    keying_v2::restore_state(&mut from_old, &old_form);
    assert!(from_old.x_retired() && from_old.x_entries() == kps, "the version-1 fields load");
    assert!(from_old.x_last_update().is_none() && from_old.x_leaf_at() == 0 && from_old.x_void().is_empty());
    let mut from_new = ShadowTree::new_v2(gid);
    keying_v2::restore_state(&mut from_new, &new_form);
    assert_eq!(from_new.x_last_update(), last);
    assert!(from_new.x_leaf_at() > 0);
    assert_eq!(keying_v2::encode_state(&from_new), new_form, "a round trip is byte-stable");

    // A relaunched fleet whose window stamps are unknown (as after loading the old form): the
    // first full bundles author nothing.
    let g = relaunch_all(&f);
    for d in &g.devs {
        let mut st = d.s.state.lock().unwrap();
        let t = st.v2_trees.get_mut(&g.cid).unwrap();
        let old = t.x_state_v1_bytes();
        let mut fresh = ShadowTree::new_v2(g.cid.as_bytes().to_vec());
        keying_v2::restore_state(&mut fresh, &old);
        assert_eq!(fresh.x_leaf_at(), 0);
        t.x_forget_update_window();
    }
    let n = v2_commits(&g.devs[0].s, &g.cid).len();
    sync_fleet(&g, 3);
    for (i, d) in g.devs.iter().enumerate() {
        assert_eq!(v2_commits(&d.s, &g.cid).len(), n, "device {i} authored nothing on loading a state without window stamps");
        assert!(d.s.state.lock().unwrap().v2_trees.get(&g.cid).unwrap().x_leaf_at() > 0, "device {i}: the window started");
    }
}

// ══ Roster version tie (PROTOCOL-SPEC §17, finding F5) ═════════════════════════════════════════

/// Two seed holders of one account each sign a roster with the SAME version: one revokes a device,
/// the other does not. A contact that keeps whichever arrives first can miss the revocation. In
/// BOTH delivery orders the verifier now ends with the device unauthorized, the tree Removes its
/// leaf, and it reads nothing posted afterwards; re-delivering either roster changes nothing (no
/// commit, no epoch move); the verdict survives a restart; and a strictly newer roster that
/// authorizes the device again is believed.
#[test]
fn a_roster_version_tie_counts_every_revocation_in_either_delivery_order() {
    let _clk = clock_guard();
    for order in ["the revoking roster arrives second", "the revoking roster arrives first"] {
        let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1, B2]), (C, &[C1])]);
        let ci = committer_index(&f);
        let admin = f.devs[ci].account_hex();
        let (seed, _, creds) = f
            .rosters
            .iter()
            .find(|(seed, _, creds)| creds.len() == 2 && hex(&Identity::from_seed(seed).public().node_id_bytes()) != admin)
            .expect("a two-device member account")
            .clone();
        let account = Identity::from_seed(&seed).public().node_id_bytes();
        let of_account: Vec<usize> = (0..f.devs.len()).filter(|i| f.devs[*i].account_seed == seed).collect();
        let (keep, revoked) = (of_account[0], of_account[1]);
        let verifiers: Vec<usize> = (0..f.devs.len()).filter(|i| !of_account.contains(i)).collect();
        let revoked_id = f.devs[revoked].device_id();
        let ids: Vec<Vec<u8>> = [keep, revoked].iter().map(|i| f.devs[*i].device_id().to_vec()).collect();
        let sign = |version: u64, at: u64, revoke: bool| {
            let r = if revoke { vec![ids[1].clone()] } else { vec![] };
            crate::multidevice::sign_device_list(seed.to_vec(), version, at, ids.clone(), r).unwrap()
        };
        // Same version, both signed by the account, different contents.
        let (plain, revoking) = (sign(2, 10, false), sign(2, 20, true));
        let bundle = f.devs[keep].s.my_bundle();
        let ingest = |s: &HavenSocial, list: &Vec<u8>| s.ingest_device_roster(bundle.clone(), list.clone(), creds.clone());
        let authorized = |s: &HavenSocial| s.state.lock().unwrap().device_lists.get(&account).unwrap().list.is_authorized(&revoked_id);
        let in_tree = |s: &HavenSocial| tree_leaf_device_ids(&v2_state(s, &f.cid).unwrap().tree).contains(&revoked_id);
        post(&f.devs[ci].s, &f.cid, "before-tie", 1_000);
        sync_fleet(&f, 2);
        assert!(reads(&f.devs[revoked].s, &f.cid, "before-tie") && in_tree(&f.devs[ci].s), "{order}: the device starts as a member");

        let sequence = if order.ends_with("second") { [&plain, &revoking] } else { [&revoking, &plain] };
        for v in &verifiers {
            assert!(authorized(&f.devs[*v].s));
            for list in sequence {
                assert!(ingest(&f.devs[*v].s, list), "{order}: device {v} knows the roster");
            }
            assert!(!authorized(&f.devs[*v].s), "{order}: device {v} still treats the revoked device as authorized");
        }
        // Exactly as a newly learned revocation: the committer Removes the leaf.
        sync_fleet(&f, 4);
        for i in verifiers.iter().chain([&keep]) {
            assert!(!in_tree(&f.devs[*i].s), "{order}: device {i}'s tree still seats the revoked device");
            assert_eq!(lane(&f.devs[*i].s, &f.cid), 2, "{order}: device {i} is keyed by the tree");
        }
        post(&f.devs[ci].s, &f.cid, "after-tie", 2_000);
        sync_fleet(&f, 2);
        assert!(reads(&f.devs[keep].s, &f.cid, "after-tie") && reads(&f.devs[verifiers[1]].s, &f.cid, "after-tie"));
        assert!(!reads(&f.devs[revoked].s, &f.cid, "after-tie"), "{order}: the revoked device reads new content");

        // Idempotent: both rosters again, three times over — nothing moves.
        let snapshot = |s: &HavenSocial| {
            let st = s.state.lock().unwrap();
            let c = st.circles.iter().find(|c| c.id == f.cid).unwrap();
            (c.my_epoch, c.mls_live_epoch, st.v2_trees.get(&f.cid).unwrap().commits.len(), st.roster_ties.get(&account).map(|t| t.others.len()))
        };
        let before: Vec<_> = verifiers.iter().map(|v| snapshot(&f.devs[*v].s)).collect();
        assert!(before.iter().all(|b| b.3 == Some(1)), "{order}: one tied roster is remembered");
        for _ in 0..3 {
            for v in &verifiers {
                for list in [&plain, &revoking, &plain] {
                    assert!(ingest(&f.devs[*v].s, list));
                }
            }
            sync_fleet(&f, 1);
        }
        let after: Vec<_> = verifiers.iter().map(|v| snapshot(&f.devs[*v].s)).collect();
        assert_eq!(before, after, "{order}: re-delivery rotated or committed something");

        // Across a restart.
        let v = &f.devs[ci];
        let relaunched = s1_relaunch(v.account_seed, v.device_seed, v.s.export_state());
        introduce_one(&f, &relaunched, v.account_seed);
        {
            let st = relaunched.state.lock().unwrap();
            let cd = st.device_lists.get(&account).expect("the roster was restored (its saved form verifies)");
            assert_eq!(cd.list.version, 2);
            assert!(!cd.list.is_authorized(&revoked_id), "{order}: a restart re-authorized the revoked device");
            assert!(cd.list.is_authorized(&f.devs[keep].device_id()));
            assert_eq!(st.roster_ties.get(&account).map(|t| t.others.len()), Some(1));
        }
        // An older or equal roster does not undo it; a strictly newer one that authorizes the
        // device again does, and settles the tie.
        assert!(!relaunched.ingest_device_roster(bundle.clone(), sign(1, 5, false), creds.clone()), "a rollback is refused");
        assert!(ingest(&relaunched, &plain));
        assert!(!authorized(&relaunched));
        assert!(ingest(&relaunched, &sign(3, 30, false)));
        assert!(authorized(&relaunched), "{order}: a strictly newer roster re-authorizes the device");
        assert!(relaunched.state.lock().unwrap().roster_ties.is_empty());
    }
}

// ══ Stage 4b: the fork rule by weight, re-entry by any member ══════════════════════════════════

const C2: [u8; 32] = [56u8; 32];

/// The accounts of a fleet in which the CREATOR account (the lowest id — the committer, the
/// admin) has two devices and the other two accounts one each. Returns the fleet, the creator's
/// two device indices and the other two.
fn creator_pair_fleet() -> (Fleet, Vec<usize>, Vec<usize>) {
    let id = |seed: &[u8; 32]| Identity::from_seed(seed).public().node_id_bytes();
    let creator = [A, B, C].into_iter().min_by_key(id).unwrap();
    let devices: [(&[u8; 32], [[u8; 32]; 2]); 3] = [(&A, [A1, A2]), (&B, [B1, B2]), (&C, [C1, C2])];
    let accounts: Vec<([u8; 32], &[[u8; 32]])> =
        devices.iter().map(|(seed, d)| (**seed, if **seed == creator { &d[..] } else { &d[..1] })).collect();
    let f = live_v2_fleet(&accounts);
    let (pair, rest): (Vec<usize>, Vec<usize>) = (0..f.devs.len()).partition(|i| f.devs[*i].account_seed == creator);
    assert!(pair.len() == 2 && rest.len() == 2);
    (f, pair, rest)
}

/// Deliver within each group only, `rounds` times.
fn deliver_within(f: &Fleet, groups: [&[usize]; 2], rounds: usize) {
    deliver(f, rounds, &|from, to, _| !groups.iter().any(|g| g.contains(&from) && g.contains(&to)));
}

/// (tip hash, epoch).
type Tip = ([u8; 32], u64);
/// [`partition_then_join`]'s result.
type Joined = (Fleet, [Vec<usize>; 2], Tip, [Tip; 2], bool);

/// Two groups cut off from each other author `depth[0]` and `depth[1]` commits on the same tip,
/// each group's two devices in turn, each side posting; then they are joined. Returns the fleet,
/// the fork point, each side's tip before the join, and whether a key package was offered after it.
fn partition_then_join(depth: [usize; 2]) -> Joined {
    let (f, pair, rest) = creator_pair_fleet();
    let groups = [pair, rest];
    let fork = v2_tip(&f.devs[0].s, &f.cid);
    for (g, group) in groups.iter().enumerate() {
        for k in 0..depth[g] {
            make_due(&f, group[k % 2]);
            deliver_within(&f, [&groups[0], &groups[1]], 2);
        }
        post(&f.devs[group[0]].s, &f.cid, &format!("from-side-{g}"), 1_000 + g as u64);
    }
    deliver_within(&f, [&groups[0], &groups[1]], 2);
    let tips = [v2_tip(&f.devs[groups[0][0]].s, &f.cid), v2_tip(&f.devs[groups[1][0]].s, &f.cid)];
    for g in 0..2 {
        assert_eq!(tips[g].1, fork.1 + depth[g] as u64, "side {g} is {} commits past the fork", depth[g]);
        assert_eq!(v2_tip(&f.devs[groups[g][1]].s, &f.cid), tips[g]);
        let st = f.devs[groups[g][0]].s.state.lock().unwrap();
        let ck = st.v2_trees.get(&f.cid).unwrap().checkpoint.as_ref().map(|ck| ck.state.epoch);
        assert!(ck.is_some_and(|e| e > fork.1), "side {g} has checkpointed past the fork point (at {ck:?})");
    }
    // Joined. A device that is not a committer waits hours before it re-enters another; the
    // packages are aged instead of the clock moved.
    let mut asked = false;
    for _ in 0..10 {
        for d in &f.devs {
            d.s.state.lock().unwrap().v2_trees.get_mut(&f.cid).unwrap().x_age_packages(8 * 60 * 60);
        }
        for i in 0..f.devs.len() {
            let out = f.devs[i].s.sync_envelopes(f.cid.clone());
            asked |= out.iter().any(|e| e.first() == Some(&TAG_MLS2_KEYPACKAGE));
            for (j, d) in f.devs.iter().enumerate() {
                if i != j {
                    for e in &out {
                        let _ = d.s.receive(f.cid.clone(), e.clone());
                    }
                }
            }
        }
    }
    (f, groups, fork, tips, asked)
}

/// Everything a joined fleet must end with: one tip, the v2 tree keying every device, every
/// device still seated, both sides' posts and a new one readable everywhere.
fn assert_rejoined(f: &Fleet) -> ([u8; 32], u64) {
    let tip = v2_tip(&f.devs[0].s, &f.cid);
    post(&f.devs[0].s, &f.cid, "after-the-join", 9_000);
    sync_fleet(f, 2);
    for (i, d) in f.devs.iter().enumerate() {
        let k = v2_state(&d.s, &f.cid).unwrap();
        assert_eq!((k.tip_hash, k.epoch), tip, "device {i} is on the same tip");
        assert_eq!(lane(&d.s, &f.cid), 2, "device {i} is keyed by the v2 tree");
        assert_eq!(tree_leaf_device_ids(&k.tree).len(), f.devs.len(), "device {i}: every device is seated");
        assert!(!offers_key_package(&d.s, &f.cid), "device {i} is not asking to re-enter any more");
        for body in ["from-side-0", "from-side-1", "after-the-join"] {
            assert!(reads(&d.s, &f.cid, body), "device {i} cannot read `{body}`");
        }
    }
    tip
}

/// THE LONGER CHAIN WINS, AND THE OTHER SIDE RE-ENTERS — WITH NO ADMIN ON THE WINNING SIDE. The
/// creator account's two devices (the only committers, the only admins) author five commits cut
/// off from the other two devices, which author six. Both sides have checkpointed past the fork.
/// Joined: the six-commit side is the agreed chain on every device; the creator's devices cannot
/// follow it, ask to re-enter, and are re-entered by a commit a plain member authors (there is no
/// committer on that side to do it). Nothing is lost: both sides' posts open everywhere.
#[test]
fn the_longer_side_wins_and_a_plain_member_reenters_the_committers() {
    let _clk = clock_guard();
    let (f, groups, fork, tips, asked) = partition_then_join([5, 6]);
    assert!(asked, "the shorter side asked to re-enter");
    let tip = assert_rejoined(&f);
    let admin = f.devs[groups[0][0]].account_hex();
    for (i, d) in f.devs.iter().enumerate() {
        assert!(on_adopted_chain(&d.s, &f.cid, &tips[1].0), "device {i} is on the longer side's chain");
        assert!(!on_adopted_chain(&d.s, &f.cid, &tips[0].0), "device {i} is not on the shorter side's");
        assert!(on_adopted_chain(&d.s, &f.cid, &fork.0));
    }
    // The commits above the longer side's old tip. The FIRST re-entry is authored by a device
    // that is not of the admin account (there was no committer on that side); if it seated only
    // one of the creator's devices, that device — a committer again — may seat the other.
    let commits = v2_commits(&f.devs[0].s, &f.cid);
    let mut at = tip.0;
    let mut reentered: Vec<[u8; 32]> = Vec::new();
    let mut first_author = None;
    while at != tips[1].0 {
        let c = treekem::Commit::from_bytes(&commits[&at]).unwrap();
        let author = committer_of(&c).and_then(|d| f.devs.iter().find(|x| x.device_id() == d)).unwrap();
        for p in &c.proposals {
            if let treekem::ProposalBody::Add { leaf_node } = &p.body {
                assert_eq!(c.proposals.len() % 2, 0, "Remove + Add pairs");
                first_author = Some(author.account_hex()); // walking down: the last one seen is the earliest
                reentered.push(leaf_credential_ids(&leaf_node.device_credential).unwrap().0);
            }
        }
        at = c.parent_commit_hash;
    }
    assert!(first_author.is_some_and(|a| a != admin), "the first re-entry on the winning side was authored by a plain member");
    reentered.sort_unstable();
    reentered.dedup();
    let mut expect: Vec<[u8; 32]> = groups[0].iter().map(|i| f.devs[*i].device_id()).collect();
    expect.sort_unstable();
    assert_eq!(reentered, expect, "exactly the two creator devices were re-entered");
}

/// EQUAL WEIGHT: THE HASH DECIDES, AND THE LOSING SIDE RE-ENTERS. Both sides author four commits.
/// Neither chain is heavier; the larger commit hash at the fork point picks one, the same one on
/// every device, and the two devices of the other side — whichever they are — re-enter.
#[test]
fn an_equal_weight_fork_is_decided_by_hash_and_the_losing_side_reenters() {
    let _clk = clock_guard();
    let (f, groups, fork, tips, asked) = partition_then_join([4, 4]);
    assert!(asked, "the losing side asked to re-enter");
    assert_rejoined(&f);
    // The first commit of each side: the larger hash is the side everyone is on.
    let commits = v2_commits(&f.devs[0].s, &f.cid);
    let first = |tip: [u8; 32]| {
        let mut at = tip;
        loop {
            let c = treekem::Commit::from_bytes(&commits[&at]).unwrap();
            if c.parent_commit_hash == fork.0 {
                return at;
            }
            at = c.parent_commit_hash;
        }
    };
    let (a, b) = (first(tips[0].0), first(tips[1].0));
    let (won, lost) = if a > b { (0, 1) } else { (1, 0) };
    for (i, d) in f.devs.iter().enumerate() {
        assert!(on_adopted_chain(&d.s, &f.cid, &tips[won].0), "device {i} is on the side with the larger hash");
        assert!(!on_adopted_chain(&d.s, &f.cid, &tips[lost].0));
    }
    let st = f.devs[groups[won][0]].s.state.lock().unwrap();
    let t = st.v2_trees.get(&f.cid).unwrap();
    assert_eq!(t.x_weight(&a).map(|w| w.0), Some(0), "no authority on either side");
}

/// A REMOVED MEMBER CANNOT OUT-BUILD ITS REMOVE. The admin Removes a two-device member. With a
/// modified client the member's devices author six path-only commits in turn — on the Remove's
/// parent, and six more on the parent's parent (from the state they held then). Every honest
/// device stays on the Remove's branch: a chain is weighed by its authority commits first, and a
/// member can author none. The member reads nothing posted afterwards.
#[test]
fn a_removed_member_cannot_out_build_its_remove() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1, B2]), (C, &[C1])]);
    let ci = committer_index(&f);
    let admin = f.devs[ci].account_hex();
    let member_seed = f.rosters.iter().find(|(seed, _, creds)| creds.len() == 2 && hex(&Identity::from_seed(seed).public().node_id_bytes()) != admin).unwrap().0;
    let member: Vec<usize> = (0..f.devs.len()).filter(|i| f.devs[*i].account_seed == member_seed).collect();
    let honest: Vec<usize> = (0..f.devs.len()).filter(|i| !member.contains(i)).collect();
    // The member's devices as they were one commit earlier (the parent's parent).
    let earlier: Vec<Dev> = member
        .iter()
        .map(|i| {
            let d = &f.devs[*i];
            let s = s1_relaunch(d.account_seed, d.device_seed, d.s.export_state());
            introduce_one(&f, &s, d.account_seed);
            Dev { s, account_seed: d.account_seed, device_seed: d.device_seed }
        })
        .collect();
    let grandparent = v2_tip(&f.devs[ci].s, &f.cid);
    update(&f, honest[1]);
    let parent = v2_tip(&f.devs[ci].s, &f.cid);
    // Six path-only commits by the member's two devices in turn, from `devs`' current tip: each
    // is made due (the hook that stands for a client ignoring the weekly window), authors on the
    // other's commit, and hands it over. Nothing reaches the honest devices yet.
    let out_build = |devs: [&Dev; 2]| -> Vec<Vec<u8>> {
        let mut chain = Vec::new();
        for k in 0..6 {
            let (author, other) = (devs[k % 2], devs[(k + 1) % 2]);
            let before = v2_commits(&author.s, &f.cid);
            author.s.state.lock().unwrap().v2_trees.get_mut(&f.cid).unwrap().x_make_update_due();
            let wires = new_commit_wires(&before, &author.s.sync_envelopes(f.cid.clone()));
            assert_eq!(wires.len(), 1, "the member's device authored commit {k}");
            let c = wires[0][1..].to_vec();
            assert!(treekem::Commit::from_bytes(&c).unwrap().proposals.is_empty());
            assert!(feed_commit(&f, other, &c), "the member's other device follows commit {k}");
            chain.push(c);
        }
        chain
    };
    let on_parent = out_build([&f.devs[member[0]], &f.devs[member[1]]]);
    let on_grandparent = out_build([&earlier[0], &earlier[1]]);
    assert_eq!(treekem::Commit::from_bytes(&on_parent[0]).unwrap().parent_commit_hash, parent.0);
    assert_eq!(treekem::Commit::from_bytes(&on_grandparent[0]).unwrap().parent_commit_hash, grandparent.0);

    // The admin's Remove, on the parent. The honest devices get it, then the member's branches.
    let before = v2_commits(&f.devs[ci].s, &f.cid);
    assert!(f.devs[ci].s.mls_remove_member(f.cid.clone(), hex(&Identity::from_seed(&member_seed).public().node_id_bytes())));
    let remove = v2_commits(&f.devs[ci].s, &f.cid).into_keys().find(|h| !before.contains_key(h)).expect("the Remove commit");
    for e in f.devs[ci].s.sync_envelopes(f.cid.clone()) {
        let _ = f.devs[honest.iter().copied().find(|i| *i != ci).unwrap()].s.receive(f.cid.clone(), e);
    }
    // (The admin's own device has dropped the member's account from the circle and no longer
    // verifies anything it signs; the other honest device stores the commits — they are valid.)
    for i in &honest {
        for c in on_parent.iter().chain(&on_grandparent) {
            let stored = feed_commit(&f, &f.devs[*i], c);
            assert!(stored || *i == ci, "device {i} stores the member's commit: it is valid");
        }
    }
    sync_fleet(&f, 3);
    for i in &honest {
        let d = &f.devs[*i];
        assert!(on_adopted_chain(&d.s, &f.cid, &remove), "device {i} left the Remove's branch for the member's longer one");
        assert!(!offers_key_package(&d.s, &f.cid), "device {i} is not asking to re-enter");
        assert_eq!(lane(&d.s, &f.cid), 2);
    }
    for i in &honest {
        let d = &f.devs[*i];
        let st = d.s.state.lock().unwrap();
        let t = st.v2_trees.get(&f.cid).unwrap();
        assert_eq!(t.x_weight(&remove).map(|w| w.0), Some(1), "the Remove is an authority commit");
        if *i != ci {
            for first in [&on_parent[0], &on_grandparent[0]] {
                assert_eq!(t.x_weight(&treekem::commit_hash(first)), Some((0, 6)), "six commits, no authority");
            }
        }
    }
    post(&f.devs[ci].s, &f.cid, "after-the-remove", 7_000);
    sync_fleet(&f, 2);
    assert!(reads(&f.devs[honest[1]].s, &f.cid, "after-the-remove") && reads(&f.devs[honest[0]].s, &f.cid, "after-the-remove"));
    for d in member.iter().map(|i| &f.devs[*i]).chain(&earlier) {
        for e in f.devs[ci].s.sync_envelopes(f.cid.clone()) {
            let _ = d.s.receive(f.cid.clone(), e);
        }
        assert!(!reads(&d.s, &f.cid, "after-the-remove"), "the removed member reads content sealed after its Remove");
    }
}

/// RE-ENTRY BY A MEMBER: what is accepted. A device that lost its place offers a fresh package. A
/// plain member's `Remove(its old leaf) + Add(that package)` is stored by every device and is not
/// an authority commit. Refused: the package paired with ANOTHER device's leaf; the same package
/// a second time on the same chain; a package of a device the receiver's roster does not
/// authorize.
#[test]
fn a_member_reentry_is_accepted_only_for_the_device_that_asked() {
    let _clk = clock_guard();
    let setup = || {
        let f = live_v2_fleet(&[(A, &[A1]), (B, &[B1, B2]), (C, &[C1])]);
        let ci = committer_index(&f);
        let admin = f.devs[ci].account_hex();
        let plain: Vec<usize> = (0..f.devs.len()).filter(|i| f.devs[*i].account_hex() != admin).collect();
        // The device that asks: the last plain one. It loses its place and offers a package.
        let lost = *plain.last().unwrap();
        {
            let mut st = f.devs[lost].s.state.lock().unwrap();
            let t = st.v2_trees.get_mut(&f.cid).unwrap();
            t.my_welcomes.clear();
            t.checkpoint = None;
            t.x_forget_packages();
        }
        let wire = f.devs[lost].s.sync_envelopes(f.cid.clone()).into_iter().find(|e| e.first() == Some(&TAG_MLS2_KEYPACKAGE)).expect("a fresh package");
        let kp = KeyPackage::from_bytes(&wire[1..]).unwrap();
        (f, ci, plain, lost, kp)
    };
    let leaf_of = |f: &Fleet, of: usize, viewer: usize| {
        let tree = v2_state(&f.devs[viewer].s, &f.cid).unwrap().tree.clone();
        leaves_by_device(&tree).into_iter().find(|(d, _)| *d == f.devs[of].device_id()).unwrap().1
    };

    let (f, ci, plain, lost, kp) = setup();
    let (m1, m2) = (plain[0], plain[1]);
    assert!(m1 != lost && m2 != lost && m1 != m2);
    // Paired with another device's leaf.
    let wrong = craft_commit(&f, &f.devs[m1], Craft { removes: vec![leaf_of(&f, m2, m1)], adds: vec![kp.clone()], ..Default::default() });
    assert!(!feed_commit(&f, &f.devs[ci], &wrong), "a package may only replace its own device's leaf");
    // An Add with no Remove, a Remove with no Add: not a re-entry (and not a leave).
    let add_only = craft_commit(&f, &f.devs[m1], Craft { adds: vec![kp.clone()], ..Default::default() });
    assert!(!feed_commit(&f, &f.devs[ci], &add_only));
    let remove_only = craft_commit(&f, &f.devs[m1], Craft { removes: vec![leaf_of(&f, lost, m1)], ..Default::default() });
    assert!(!feed_commit(&f, &f.devs[ci], &remove_only), "a plain member cannot just Remove another account's device");
    // The real thing.
    let good = craft_commit(&f, &f.devs[m1], Craft { removes: vec![leaf_of(&f, lost, m1)], adds: vec![kp.clone()], ..Default::default() });
    for i in [ci, m2] {
        assert!(feed_commit(&f, &f.devs[i], &good), "device {i} stores a plain member's re-entry of the device that asked");
        let st = f.devs[i].s.state.lock().unwrap();
        assert_eq!(st.v2_trees.get(&f.cid).unwrap().x_weight(&treekem::commit_hash(&good)), Some((0, 1)), "it is not an authority commit");
    }
    // The same package again, further up the same chain.
    let again = craft_commit(&f, &f.devs[m2], Craft { removes: vec![leaf_of(&f, lost, m2)], adds: vec![kp.clone()], ..Default::default() });
    assert_eq!(treekem::Commit::from_bytes(&again).unwrap().parent_commit_hash, treekem::commit_hash(&good));
    assert!(!feed_commit(&f, &f.devs[ci], &again), "a package is used once on a chain");

    // The receiver's roster does not authorize the device that asks.
    let (f, ci, plain, lost, kp) = setup();
    let m1 = plain[0];
    let seed = f.devs[lost].account_seed;
    let (_, _, creds) = f.rosters.iter().find(|(s, _, _)| *s == seed).unwrap().clone();
    let of_account: Vec<Vec<u8>> = f.devs.iter().filter(|d| d.account_seed == seed).map(|d| d.device_id().to_vec()).collect();
    let revoking = crate::multidevice::sign_device_list(seed.to_vec(), 2, 0, of_account, vec![f.devs[lost].device_id().to_vec()]).unwrap();
    let bundle = f.devs.iter().find(|d| d.account_seed == seed).unwrap().s.my_bundle();
    assert!(f.devs[ci].s.ingest_device_roster(bundle, revoking, creds));
    let good = craft_commit(&f, &f.devs[m1], Craft { removes: vec![leaf_of(&f, lost, m1)], adds: vec![kp], ..Default::default() });
    assert!(!feed_commit(&f, &f.devs[ci], &good), "a re-entry of a device the roster does not authorize is not stored");
}

/// A DEVICE THAT ENTERED BY A WELCOME FOLLOWS A THIRD DEVICE'S UPDATE. The commit that seats a
/// device re-keys its author's path, and the secrets of the nodes that path shares with the new
/// leaf's reach the new device only inside that commit. A later Update from a third device is
/// wrapped to one of those nodes. (With committer-only Updates this never arose: every later path
/// came from the same leaf.) The re-entered device here is the committer's sibling leaf — the
/// geometry in which the shared node is the one a device of the other half wraps to.
#[test]
fn a_device_that_entered_by_a_welcome_follows_a_third_devices_update() {
    let _clk = clock_guard();
    let f = live_v2_fleet(&[(A, &[A1, A2]), (B, &[B1]), (C, &[C1])]);
    let ci = committer_index(&f);
    let tree = v2_state(&f.devs[ci].s, &f.cid).unwrap().tree.clone();
    let leaves = leaves_by_device(&tree);
    let leaf = |i: usize| leaves.iter().find(|(d, _)| *d == f.devs[i].device_id()).unwrap().1;
    let joiner = (0..f.devs.len()).find(|i| leaf(*i) == leaf(ci) ^ 1).expect("the committer's sibling leaf");
    let third: Vec<usize> = (0..f.devs.len()).filter(|i| *i != ci && *i != joiner).collect();
    let epoch0 = v2_tip(&f.devs[ci].s, &f.cid).1;
    {
        let mut st = f.devs[joiner].s.state.lock().unwrap();
        let t = st.v2_trees.get_mut(&f.cid).unwrap();
        t.my_welcomes.clear();
        t.checkpoint = None;
        t.x_forget_packages();
    }
    sync_fleet(&f, 5);
    for (i, d) in f.devs.iter().enumerate() {
        assert_eq!(v2_tip(&d.s, &f.cid).1, epoch0 + 1, "device {i}: one commit re-seated the device");
        assert_eq!(lane(&d.s, &f.cid), 2);
    }
    assert_eq!(leaf(joiner), leaves_by_device(&v2_state(&f.devs[ci].s, &f.cid).unwrap().tree).into_iter().find(|(d, _)| *d == f.devs[joiner].device_id()).unwrap().1, "it came back to the same leaf");
    // Each device of the other half re-keys in turn; `update` asserts every device follows.
    for t in &third {
        update(&f, *t);
    }
    update(&f, joiner);
    post(&f.devs[third[0]].s, &f.cid, "after-third-update", 6_000);
    sync_fleet(&f, 2);
    assert!(f.devs.iter().all(|d| reads(&d.s, &f.cid, "after-third-update")));
    assert!(f.devs.iter().all(|d| !offers_key_package(&d.s, &f.cid)), "nobody had to re-enter again");
}
