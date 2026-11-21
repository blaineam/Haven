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
