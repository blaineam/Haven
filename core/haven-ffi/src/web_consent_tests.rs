//! A linked browser is a device like any other (docs/DECISIONS.md, D22 withdrawn).
//!
//! These tests used to prove the opposite: a browser read a circle only while that circle had
//! said yes. That rule is gone, so what is proven now is that linking is the only approval: a
//! browser reads every circle its account is in, from every author, with nobody having stated
//! anything, and that the positions still stored and exchanged change nothing in either
//! direction. The web mark on the device is still signed and still cannot be forged or dropped;
//! that is covered where rosters are verified.

use super::*;

const ALICE: [u8; 32] = [71u8; 32];
const BOB: [u8; 32] = [72u8; 32];
const BOB_DEVICE: [u8; 32] = [73u8; 32];
const WEB: [u8; 32] = [74u8; 32];
const TABLET: [u8; 32] = [75u8; 32];

fn acct_hex(seed: &[u8; 32]) -> String {
    hex(&Identity::from_seed(seed).public().node_id_bytes())
}

fn sync(from: &HavenSocial, to: &HavenSocial, cid: &str) {
    for env in from.sync_envelopes(cid.to_string()) {
        let _ = to.receive(cid.to_string(), env);
    }
}

fn reads(e: &HavenSocial, cid: &str, body: &str) -> bool {
    e.feed(cid.to_string(), 9_000_000, None).iter().any(|m| m.body == body)
}

fn post(e: &HavenSocial, cid: &str, body: &str, at: u64) {
    e.post(cid.to_string(), body.into(), vec![], None, None, false, false, at).unwrap();
}

/// Link a seedless device to `primary` under `name` (the name is what the account signs into the
/// device's credential — a web device's carries the web mark). Returns the device and the
/// primary's signed roster wire.
fn link(primary: &Arc<HavenSocial>, primary_seed: [u8; 32], dev_seed: [u8; 32], name: &str) -> (Arc<HavenSocial>, Vec<u8>) {
    let account_bundle = primary.my_bundle();
    let device = HavenSocial::new_seedless(account_bundle.clone(), dev_seed.to_vec()).unwrap();
    let primary_dev = Identity::from_seed(&primary_seed).public().node_id_bytes().to_vec();
    let relays = vec!["https://relay.example".to_string()];
    let ticket = crate::enroll::enroll_issue_ticket(account_bundle, primary_dev, 1_000, relays.clone()).unwrap();
    let req_wire =
        crate::enroll::enroll_build_request(ticket.secret.clone(), device.my_device_bundle(), name.into(), 1_000).unwrap();
    let req = crate::enroll::enroll_verify_request(ticket.secret.clone(), req_wire, 1_000, 600).unwrap();
    let roster_wire = primary.register_device(req.device_bundle.clone(), name.into(), 1);
    assert!(!roster_wire.is_empty());
    let grant_wire = crate::enroll::enroll_assemble_grant(
        primary_seed.to_vec(),
        ticket.secret.clone(),
        req.device_bundle,
        name.into(),
        1,
        roster_wire,
        relays,
    )
    .unwrap();
    let grant = crate::enroll::enroll_open_grant(dev_seed.to_vec(), ticket, grant_wire).unwrap();
    assert!(device.ingest_roster_wire(grant.roster_wire.clone()));
    (device, grant.roster_wire)
}

struct Fleet {
    alice: Arc<HavenSocial>,
    bob: Arc<HavenSocial>,
    /// Alice's browser.
    web: Arc<HavenSocial>,
    cid: String,
}

/// Alice (a primary) with a linked BROWSER, and her contact Bob, sharing circle `cid`.
/// `owned = true` makes it a creator-bound circle Alice created; otherwise it is an older
/// shared circle with a plain id.
fn fleet(owned: bool) -> Fleet {
    let alice = HavenSocial::new(ALICE.to_vec()).unwrap();
    let bob = HavenSocial::new(BOB.to_vec()).unwrap();
    let web_name = haven_p2p::webpolicy::mark_web_device_name("Chrome");
    let (web, alice_roster) = link(&alice, ALICE, WEB, &web_name);
    assert!(web.is_web_device() && !alice.is_web_device() && !bob.is_web_device());

    let cid = if owned {
        let id = alice.create_circle_owned("Family".into());
        for e in [&bob, &web] {
            e.create_circle(id.clone(), "Family".into());
            assert!(e.set_circle_creator(id.clone(), acct_hex(&ALICE)));
        }
        id
    } else {
        // An older shared circle: a plain id that binds to no creator. (Not My Circle, which each
        // account decides for itself: see the tests at the end of this file.)
        let id = "legacy-family".to_string();
        for e in [&alice, &bob, &web] {
            e.create_circle(id.clone(), "Family".into());
        }
        id
    };
    alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
    web.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
    assert!(bob.use_device_identity(BOB_DEVICE.to_vec()));
    let bob_roster = bob.register_device(bob.my_device_bundle(), "Bob's phone".into(), 0);
    assert!(alice.ingest_roster_wire(bob_roster.clone()));
    assert!(web.ingest_roster_wire(bob_roster));
    assert!(bob.ingest_roster_wire(alice_roster));
    Fleet { alice, bob, web, cid }
}

/// Everybody hears from everybody (the browser included), a few times over.
fn settle(f: &Fleet) {
    for _ in 0..3 {
        sync(&f.alice, &f.bob, &f.cid);
        sync(&f.bob, &f.alice, &f.cid);
        sync(&f.alice, &f.web, &f.cid);
        sync(&f.bob, &f.web, &f.cid);
        sync(&f.web, &f.alice, &f.cid);
    }
}

fn reads_both_ways_with_nobody_asked(f: &Fleet) {
    let Fleet { alice, bob, web, cid } = f;
    post(alice, cid, "alice's", 2_000);
    post(bob, cid, "bob's", 2_100);
    settle(f);
    assert!(reads(web, cid, "alice's"), "her own posts reach her browser");
    assert!(reads(web, cid, "bob's"), "and so do a contact's");
    assert!(reads(bob, cid, "alice's") && reads(alice, cid, "bob's"));
    let s = web.circle_web_access(cid.clone());
    assert!(s.allowed && s.waiting_on.is_empty(), "nothing to wait for");
    // What the browser posts is read by everyone, as from any device of Alice's.
    post(web, cid, "from the browser", 2_200);
    settle(f);
    assert!(reads(alice, cid, "from the browser") && reads(bob, cid, "from the browser"));
}

#[test]
fn a_linked_browser_reads_an_older_shared_circle_with_nobody_asked() {
    reads_both_ways_with_nobody_asked(&fleet(false));
}

#[test]
fn a_linked_browser_reads_a_creator_bound_circle_with_nobody_asked() {
    reads_both_ways_with_nobody_asked(&fleet(true));
}

#[test]
fn a_linked_browser_reads_my_circle_with_nobody_asked() {
    let alice = HavenSocial::new(ALICE.to_vec()).unwrap();
    let bob = HavenSocial::new(BOB.to_vec()).unwrap();
    let web_name = haven_p2p::webpolicy::mark_web_device_name("Chrome");
    let (web, alice_roster) = link(&alice, ALICE, WEB, &web_name);
    let cid = DEFAULT_CIRCLE.to_string();
    alice.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
    web.add_contact_bundle(cid.clone(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(cid.clone(), alice.my_bundle()).unwrap();
    assert!(bob.use_device_identity(BOB_DEVICE.to_vec()));
    let bob_roster = bob.register_device(bob.my_device_bundle(), "Bob's phone".into(), 0);
    assert!(alice.ingest_roster_wire(bob_roster.clone()));
    assert!(web.ingest_roster_wire(bob_roster));
    assert!(bob.ingest_roster_wire(alice_roster));
    reads_both_ways_with_nobody_asked(&Fleet { alice, bob, web, cid });
}

/// The positions people signed under the old rule are still stored and still travel. A "no"
/// among them must not shut a browser out any more, in an owned circle or an unowned one.
#[test]
fn a_stored_no_from_anyone_changes_nothing() {
    for owned in [false, true] {
        let f = fleet(owned);
        let Fleet { alice, bob, web, cid } = &f;
        assert!(alice.set_circle_web_access(cid.clone(), false));
        assert!(bob.set_circle_web_access(cid.clone(), false));
        settle(&f);
        post(alice, cid, "after two noes", 3_000);
        post(bob, cid, "bob after two noes", 3_100);
        settle(&f);
        assert!(reads(web, cid, "after two noes") && reads(web, cid, "bob after two noes"), "owned={owned}");
        assert!(web.circle_web_access(cid.clone()).allowed);
    }
}

/// A browser holds no account key, so it still cannot sign a position (or anything else in the
/// account's name), whatever the positions now mean.
#[test]
fn a_browser_still_cannot_sign_for_the_account() {
    let f = fleet(true);
    assert!(!f.web.set_circle_web_access(f.cid.clone(), true));
    assert!(!f.web.circle_web_access(f.cid.clone()).can_sign);
    assert!(f.alice.circle_web_access(f.cid.clone()).can_sign);
}

// ── Key hand-off between my own devices (`key_handoff`) ─────────────────────────────────────

/// Alice and Bob are contacts and have read each other. Then Alice links a new device that Bob's
/// app never hears about (Bob does not come online again). Returns the new device.
fn linked_while_bob_is_away(f: &Fleet, seed: [u8; 32], name: &str) -> Arc<HavenSocial> {
    let (dev, roster) = link(&f.alice, ALICE, seed, name);
    if f.cid != DEFAULT_CIRCLE {
        dev.create_circle(f.cid.clone(), "Family".into());
        let _ = dev.set_circle_creator(f.cid.clone(), acct_hex(&ALICE));
    }
    dev.add_contact_bundle(f.cid.clone(), f.bob.my_bundle()).unwrap();
    assert!(f.alice.ingest_roster_wire(roster));
    // The new device knows Bob's devices (that is account state, which its own account syncs)…
    let bob_roster = f.bob.my_device_roster_wire();
    assert!(dev.ingest_roster_wire(bob_roster));
    dev
}

#[test]
fn a_new_device_reads_a_friends_posts_once_my_own_device_hands_over_its_keys() {
    // Keys rotate on a schedule: a parallel test that advances the clock must not rotate Bob's
    // between his post and the hand-off.
    let _clk = super::net_tests::clock_guard();
    for owned in [false, true] {
        let f = fleet(owned);
        let Fleet { alice, bob, cid, .. } = &f;
        // Alice's phone is a device in her own roster, as every real primary is.
        assert!(!alice.register_device(alice.my_device_bundle(), "Alice's phone".into(), 0).is_empty());
        post(bob, cid, "bob's, before the new device", 2_000);
        settle(&f);
        assert!(reads(alice, cid, "bob's, before the new device"));

        let tablet = linked_while_bob_is_away(&f, TABLET, "Alice's tablet");
        let tablet_hex = tablet.my_device_node_hex();
        // Bob's envelopes reach the tablet (they are on the relay), but Bob sealed them before the
        // tablet existed: it cannot open them.
        sync(bob, &tablet, cid);
        assert!(!reads(&tablet, cid, "bob's, before the new device"), "owned={owned}: nothing opens without a key");

        // Alice's phone is up to date with Bob (it has been running all along); Bob's app never
        // hears of the tablet. Her phone hands over what it holds.
        sync(bob, alice, cid);
        let blob = alice.export_key_handoff(tablet_hex.clone());
        assert!(!blob.is_empty());
        let gained = tablet.import_key_handoff(blob.clone());
        assert!(gained.contains(cid), "owned={owned}: {gained:?}");
        sync(bob, &tablet, cid);
        assert!(reads(&tablet, cid, "bob's, before the new device"), "owned={owned}: the friend's post opens");
        // Handing the same keys over again changes nothing.
        assert!(tablet.import_key_handoff(blob).is_empty());
    }
}

#[test]
fn a_hand_off_is_only_between_authorized_devices_of_one_account() {
    let f = fleet(false);
    let Fleet { alice, bob, web, cid } = &f;
    post(bob, cid, "bob's", 2_000);
    post(alice, cid, "alice's", 2_100);
    settle(&f);
    let alice_dev = alice.my_device_node_hex();
    let web_dev = web.my_device_node_hex();
    let bob_dev = bob.my_device_node_hex();

    // A device does not export to itself, to a contact's device, or to a made-up id.
    assert!(alice.export_key_handoff(alice_dev.clone()).is_empty());
    assert!(alice.export_key_handoff(bob_dev.clone()).is_empty(), "never to another account's device");
    assert!(alice.export_key_handoff("ab".repeat(32)).is_empty());
    assert!(alice.export_key_handoff("nonsense".into()).is_empty());

    // Bob cannot hand Alice's devices anything: he is not a device of her account.
    assert!(bob.export_key_handoff(web_dev.clone()).is_empty());

    // A blob sealed to one device opens on no other.
    let for_web = alice.export_key_handoff(web_dev.clone());
    assert!(!for_web.is_empty());
    assert!(bob.import_key_handoff(for_web.clone()).is_empty(), "not Bob's to open");
    let mut tampered = for_web.clone();
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    assert!(web.import_key_handoff(tampered).is_empty(), "a changed blob is refused");
    assert!(web.import_key_handoff(vec![1, 2, 3]).is_empty());

    // A device the account has removed is neither a target nor a source.
    let (tablet, roster) = link(alice, ALICE, TABLET, "Alice's tablet");
    assert!(web.ingest_roster_wire(roster));
    let tablet_hex = tablet.my_device_node_hex();
    let from_tablet_before = tablet.export_key_handoff(web_dev.clone());
    // Alice removes the tablet: a newer account-signed roster without it.
    let id = |b: Vec<u8>| HavenId::from_bytes(&b).unwrap().node_id_bytes().to_vec();
    let list = crate::multidevice::sign_device_list(
        ALICE.to_vec(),
        99,
        9,
        vec![id(alice.my_bundle()), id(web.my_device_bundle())],
        vec![id(tablet.my_device_bundle())],
    )
    .unwrap();
    let creds = vec![
        crate::multidevice::issue_device_credential(ALICE.to_vec(), alice.my_bundle(), "phone".into(), 9).unwrap(),
        crate::multidevice::issue_device_credential(
            ALICE.to_vec(),
            web.my_device_bundle(),
            haven_p2p::webpolicy::mark_web_device_name("Chrome"),
            9,
        )
        .unwrap(),
    ];
    assert!(alice.set_my_device_roster(list.clone(), creds.clone()));
    assert!(web.ingest_device_roster(alice.my_bundle(), list, creds));
    assert!(alice.export_key_handoff(tablet_hex).is_empty(), "a removed device gets nothing");
    assert!(web.import_key_handoff(from_tablet_before).is_empty(), "and what it sealed earlier is refused");
}

/// A photo is wrapped under its SEALER's circle key. A browser linked after it was sealed is on no
/// recipient list, so that key (handed over by my own device) is its only way in. Opening used to
/// try only my own keys: the browser could open none of a friend's media straight from the relay.
/// It now opens everything under a key that still exists; older keys are deleted on every device.
#[test]
fn a_newly_linked_browser_opens_a_friends_media_under_every_key_still_held() {
    let _clk = super::net_tests::clock_guard();
    let f = fleet(true);
    let Fleet { alice, bob, cid, .. } = &f;
    assert!(!alice.register_device(alice.my_device_bundle(), "Alice's phone".into(), 0).is_empty());
    post(bob, cid, "hello", 2_000);
    settle(&f);
    let mut sealed = Vec::new();
    for n in 0..8u8 {
        sealed.push(bob.seal_circle_media(cid.clone(), vec![n; 64]).unwrap());
        bob.rotate_circle(cid.clone());
        post(bob, cid, &format!("after rotation {n}"), 3_000 + u64::from(n));
        settle(&f);
    }
    let latest = bob.seal_circle_media(cid.clone(), vec![99; 64]).unwrap();
    settle(&f);
    let browser = linked_while_bob_is_away(&f, TABLET, &haven_p2p::webpolicy::mark_web_device_name("Safari"));
    sync(bob, alice, cid);
    browser.import_key_handoff(alice.export_key_handoff(browser.my_device_node_hex()));
    sync(bob, &browser, cid);
    let opens = |e: &HavenSocial, b: &Vec<u8>| e.open_circle_media(cid.clone(), b.clone()).is_some();
    let phone: Vec<bool> = sealed.iter().map(|b| opens(alice, b)).collect();
    let web: Vec<bool> = sealed.iter().map(|b| opens(&browser, b)).collect();
    assert!(phone.iter().all(|o| *o) && opens(alice, &latest), "the account's phone opens everything: {phone:?}");
    assert!(opens(&browser, &latest), "the newest photo opens");
    // Oldest first, one rotation apart; four epochs are kept (the current one and three before).
    assert_eq!(web, [false, false, false, false, false, true, true, true]);
    // The file path (large videos) takes the same keys.
    let dir = std::env::temp_dir().join(format!("haven-media-keys-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (src, out) = (dir.join("sealed"), dir.join("plain"));
    std::fs::write(&src, &latest).unwrap();
    assert!(browser.open_circle_media_file(cid.clone(), src.display().to_string(), out.display().to_string()));
    assert_eq!(std::fs::read(&out).unwrap(), vec![99; 64]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// DECISIONS D27: media older than every circle key a new browser can be given opens with its own
/// content key, which the account's phone unwraps from the END of each blob and sends sealed to
/// that browser alone.
#[test]
fn a_new_browser_opens_old_media_with_the_item_keys_its_phone_sends() {
    let _clk = super::net_tests::clock_guard();
    let f = fleet(true);
    let Fleet { alice, bob, cid, .. } = &f;
    assert!(!alice.register_device(alice.my_device_bundle(), "Alice's phone".into(), 0).is_empty());
    post(bob, cid, "hello", 2_000);
    settle(&f);
    let mut sealed = Vec::new();
    for n in 0..8u8 {
        // Bigger than the tail the phone reads, so a tail really is only part of the blob.
        sealed.push(bob.seal_circle_media(cid.clone(), vec![n; 200_000]).unwrap());
        bob.rotate_circle(cid.clone());
        post(bob, cid, &format!("after rotation {n}"), 3_000 + u64::from(n));
        settle(&f);
    }
    let browser = linked_while_bob_is_away(&f, TABLET, &haven_p2p::webpolicy::mark_web_device_name("Safari"));
    sync(bob, alice, cid);
    browser.import_key_handoff(alice.export_key_handoff(browser.my_device_node_hex()));
    sync(bob, &browser, cid);
    let opens = |e: &HavenSocial, b: &Vec<u8>| e.open_circle_media(cid.clone(), b.clone());
    assert!(opens(&browser, &sealed[0]).is_none(), "too old for any key the browser was given");

    let tail = |b: &Vec<u8>| b[b.len() - 64 * 1024..].to_vec();
    let entries: Vec<Vec<u8>> =
        sealed.iter().map(|b| alice.item_key_from_tail(tail(b)).expect("the phone's own entry")).collect();
    let target = browser.my_device_node_hex();
    // Only the account's holder can produce keys or a grant, and only for a device its roster lists.
    assert!(browser.item_key_from_tail(tail(&sealed[0])).is_none());
    assert!(browser.seal_item_keys(target.clone(), entries.clone()).is_none());
    assert!(alice.seal_item_keys("ab".repeat(32), entries.clone()).is_none());
    assert!(alice.seal_item_keys(target.clone(), vec![vec![1; 63]]).is_none());
    let grant = alice.seal_item_keys(target, entries).expect("sealed to the browser");
    // Another member of the circle cannot read it, and neither can the phone that sent it.
    assert_eq!(bob.receive_item_keys(grant.clone()), 0);
    assert_eq!(alice.receive_item_keys(grant.clone()), 0);

    assert_eq!(browser.receive_item_keys(grant.clone()), 8);
    assert_eq!(browser.receive_item_keys(grant), 0, "the same grant again adds nothing");
    for (n, b) in sealed.iter().enumerate() {
        assert_eq!(opens(&browser, b), Some(vec![n as u8; 200_000]), "photo {n}");
    }
    // The keys survive a reload of the page, and the file path (large videos) uses them too.
    let again = HavenSocial::new_seedless(alice.my_bundle(), TABLET.to_vec()).unwrap();
    again.import_state(browser.export_state());
    assert_eq!(again.item_key_count(), 8);
    assert_eq!(opens(&again, &sealed[0]), Some(vec![0; 200_000]));
    let dir = std::env::temp_dir().join(format!("haven-item-keys-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (src, out) = (dir.join("sealed"), dir.join("plain"));
    std::fs::write(&src, &sealed[0]).unwrap();
    assert!(again.open_circle_media_file(cid.clone(), src.display().to_string(), out.display().to_string()));
    assert_eq!(std::fs::read(&out).unwrap(), vec![0; 200_000]);
    let _ = std::fs::remove_dir_all(&dir);
    // A state that holds no item keys is written as it always was.
    assert!(!String::from_utf8_lossy(&alice.export_state()).contains("item_keys"));
}
