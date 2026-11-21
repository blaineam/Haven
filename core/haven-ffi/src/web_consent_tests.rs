//! Per-circle consent to web devices, end to end through the engine (docs/WEB-PARITY.md;
//! `haven_p2p::webpolicy`). The property under test is always the same one, from different
//! angles: a browser linked to an account reads a circle only while that circle allows web
//! devices — and nobody who is not entitled to say so can make it.

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
/// shared circle, which nobody provably owns.
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

#[test]
fn a_circle_nobody_owns_opens_to_a_browser_only_when_every_member_agrees_and_closes_when_one_withdraws() {
    let f = fleet(false);
    let Fleet { alice, bob, web, cid } = &f;

    // Nobody has said anything: the browser is linked, in the roster — and reads nothing.
    post(alice, cid, "before anyone agreed", 2_000);
    post(bob, cid, "bob, before anyone agreed", 2_100);
    settle(&f);
    assert!(reads(bob, cid, "before anyone agreed") && reads(alice, cid, "bob, before anyone agreed"));
    assert!(!reads(web, cid, "before anyone agreed"));
    assert!(!reads(web, cid, "bob, before anyone agreed"));
    let s = alice.circle_web_access(cid.clone());
    assert!(!s.allowed && !s.mine && s.can_sign && !s.decided_by_admins && s.i_decide);
    assert_eq!(s.waiting_on.len(), 2, "both members still have to agree");

    // Alice alone is not enough.
    assert!(alice.set_circle_web_access(cid.clone(), true));
    post(alice, cid, "alice agreed, bob has not", 3_000);
    settle(&f);
    let s = bob.circle_web_access(cid.clone());
    assert!(!s.allowed && !s.mine, "Bob has heard Alice's yes and it is not his");
    assert_eq!(s.waiting_on, vec![acct_hex(&BOB)]);
    assert!(!reads(web, cid, "alice agreed, bob has not"));

    // Bob agrees too: the circle re-keys to include the browser, and it reads the history as well.
    assert!(bob.set_circle_web_access(cid.clone(), true));
    settle(&f);
    assert!(alice.circle_web_access(cid.clone()).allowed && bob.circle_web_access(cid.clone()).allowed);
    assert!(web.circle_web_access(cid.clone()).allowed, "the browser learns the answer from the lane");
    post(alice, cid, "everyone agreed", 4_000);
    post(bob, cid, "bob, after agreeing", 4_100);
    settle(&f);
    for body in ["everyone agreed", "bob, after agreeing", "before anyone agreed"] {
        assert!(reads(web, cid, body), "the browser reads {body:?}");
    }

    // Bob changes his mind. From the next key on, the browser is out again.
    assert!(bob.set_circle_web_access(cid.clone(), false));
    settle(&f);
    assert!(!alice.circle_web_access(cid.clone()).allowed);
    post(alice, cid, "after bob withdrew", 5_000);
    post(bob, cid, "bob, after withdrawing", 5_100);
    settle(&f);
    assert!(reads(bob, cid, "after bob withdrew") && reads(alice, cid, "bob, after withdrawing"));
    assert!(!reads(web, cid, "after bob withdrew"));
    assert!(!reads(web, cid, "bob, after withdrawing"));
    // What it was shown while allowed is not un-shown — said plainly, not hidden.
    assert!(reads(web, cid, "everyone agreed"));
}

#[test]
fn a_browser_cannot_vote_itself_in_and_a_strangers_or_stale_word_counts_for_nothing() {
    let f = fleet(false);
    let Fleet { alice, bob, web, cid } = &f;

    // A linked device holds no account key: it cannot sign a position at all.
    assert!(!web.set_circle_web_access(cid.clone(), true));
    let s = web.circle_web_access(cid.clone());
    assert!(!s.can_sign && !s.allowed);

    // A well-formed "yes" from an account that is not in the circle, and one for another circle,
    // are dropped on arrival.
    let mallory = Identity::from_seed(&[80u8; 32]);
    for wire in [
        CircleWebPolicy::issue(&mallory, cid.as_bytes(), true, 9).to_bytes(),
        CircleWebPolicy::issue(&Identity::from_seed(&BOB), b"some-other-circle", true, 9).to_bytes(),
    ] {
        assert!(matches!(alice.receive(cid.clone(), tagged(TAG_WEB_POLICY, &wire)), Ok(false)));
    }
    // …and so is a "yes" that claims to be Bob's but is not signed by Bob.
    let mut forged = CircleWebPolicy::issue(&mallory, cid.as_bytes(), true, 9);
    forged.signer = Identity::from_seed(&BOB).public().node_id_bytes();
    assert!(matches!(alice.receive(cid.clone(), tagged(TAG_WEB_POLICY, &forged.to_bytes())), Ok(false)));
    assert!(alice.set_circle_web_access(cid.clone(), true));
    assert!(!alice.circle_web_access(cid.clone()).allowed, "Bob has not agreed, whatever arrived");

    // Bob says yes (v1), then no (v2). His old yes, replayed, does not come back.
    assert!(bob.set_circle_web_access(cid.clone(), true));
    let bobs_yes: Vec<Vec<u8>> =
        bob.sync_envelopes(cid.clone()).into_iter().filter(|e| e.first() == Some(&TAG_WEB_POLICY)).collect();
    assert!(!bobs_yes.is_empty(), "the position rides the circle's lane");
    settle(&f);
    assert!(alice.circle_web_access(cid.clone()).allowed);
    assert!(bob.set_circle_web_access(cid.clone(), false));
    settle(&f);
    assert!(!alice.circle_web_access(cid.clone()).allowed);
    for e in &bobs_yes {
        let _ = alice.receive(cid.clone(), e.clone());
        let _ = web.receive(cid.clone(), e.clone());
    }
    assert!(!alice.circle_web_access(cid.clone()).allowed, "a replayed older yes loses to the newer no");
    assert!(!web.circle_web_access(cid.clone()).allowed);
}

#[test]
fn a_creator_bound_circle_follows_its_admins_not_its_members() {
    let f = fleet(true);
    let Fleet { alice, bob, web, cid } = &f;
    settle(&f);

    // Bob is a member, not an admin: his yes decides nothing.
    assert!(bob.set_circle_web_access(cid.clone(), true));
    settle(&f);
    let s = bob.circle_web_access(cid.clone());
    assert!(s.decided_by_admins && !s.i_decide && s.mine && !s.allowed);
    post(bob, cid, "bob said yes, alice has not", 2_000);
    settle(&f);
    assert!(reads(alice, cid, "bob said yes, alice has not"));
    assert!(!reads(web, cid, "bob said yes, alice has not"));

    // The creator's word is enough, on every device that hears it.
    assert!(alice.set_circle_web_access(cid.clone(), true));
    settle(&f);
    for e in [alice, bob, web] {
        assert!(e.circle_web_access(cid.clone()).allowed);
    }
    post(bob, cid, "after the creator allowed it", 3_000);
    settle(&f);
    assert!(reads(web, cid, "after the creator allowed it"));
    assert!(reads(web, cid, "bob said yes, alice has not"), "and the history arrives with the new key");

    // And the creator can take it back; Bob's standing yes does not keep it open.
    assert!(alice.set_circle_web_access(cid.clone(), false));
    settle(&f);
    assert!(!bob.circle_web_access(cid.clone()).allowed);
    post(bob, cid, "after the creator closed it", 4_000);
    settle(&f);
    assert!(reads(alice, cid, "after the creator closed it"));
    assert!(!reads(web, cid, "after the creator closed it"));
}

#[test]
fn a_browser_refuses_keys_a_sender_offers_it_for_a_circle_that_has_not_agreed() {
    // An app that predates the rule seals to every device in the roster. Model exactly that: take
    // a key commit made while the circle allowed the browser, and deliver it AFTER the circle
    // stopped allowing it. The honest browser must not take it.
    let f = fleet(false);
    let Fleet { alice, bob, web, cid } = &f;
    assert!(alice.set_circle_web_access(cid.clone(), true));
    assert!(bob.set_circle_web_access(cid.clone(), true));
    sync(alice, bob, cid);
    sync(bob, alice, cid);
    assert!(alice.circle_web_access(cid.clone()).allowed);
    post(alice, cid, "sealed while allowed, delivered after", 2_000);
    let held_back = alice.sync_envelopes(cid.clone());
    assert!(held_back.iter().any(|e| e.first() == Some(&TAG_KEY_COMMIT)));

    // The browser first hears that Bob withdrew…
    assert!(bob.set_circle_web_access(cid.clone(), false));
    sync(bob, web, cid);
    assert!(!web.circle_web_access(cid.clone()).allowed);
    // …and only then the older bundle whose commit was sealed to it. Positions in that bundle are
    // older than what it holds, so the answer stays no, and the key is refused.
    for e in held_back {
        let _ = web.receive(cid.clone(), e);
    }
    assert!(!web.circle_web_access(cid.clone()).allowed);
    assert!(!reads(web, cid, "sealed while allowed, delivered after"));
}

#[test]
fn a_key_that_reaches_a_browser_before_the_circles_yes_is_held_not_lost() {
    // Found through a real tunnel: the yes and the key it releases travel together, key first,
    // and each envelope is delivered ONCE (a mailbox entry is marked seen). Whatever order they
    // arrive in, the browser must end up reading — and must not read before the yes.
    for order in ["as sent", "reversed", "keys first, then the control lane"] {
        let f = fleet(false);
        let Fleet { alice, bob, web, cid } = &f;
        assert!(alice.set_circle_web_access(cid.clone(), true));
        assert!(bob.set_circle_web_access(cid.clone(), true));
        for _ in 0..2 {
            sync(alice, bob, cid);
            sync(bob, alice, cid);
        }
        assert!(alice.circle_web_access(cid.clone()).allowed);
        post(alice, cid, "sealed after everyone agreed", 2_000);
        let mut bundle = alice.sync_envelopes(cid.clone());
        assert!(bundle.iter().any(|e| e.first() == Some(&TAG_WEB_POLICY)));
        let commit_at = bundle.iter().position(|e| e.first() == Some(&TAG_KEY_COMMIT)).expect("a key commit");
        let policy_at = bundle.iter().position(|e| e.first() == Some(&TAG_WEB_POLICY)).unwrap();
        assert!(commit_at < policy_at, "the bundle really does carry the key before the yes");
        match order {
            "reversed" => bundle.reverse(),
            "keys first, then the control lane" => {
                let is_key = |e: &Vec<u8>| matches!(e.first(), Some(&TAG_KEY_COMMIT) | Some(&TAG_EPOCH_EVENT));
                let (keys, rest): (Vec<_>, Vec<_>) = bundle.into_iter().partition(is_key);
                // The browser has the key and the post in hand and still shows nothing…
                for e in &keys {
                    let _ = web.receive(cid.clone(), e.clone());
                }
                assert!(!reads(web, cid, "sealed after everyone agreed"), "{order}: nothing is opened before the yes");
                bundle = rest;
            }
            _ => {}
        }
        // …each remaining envelope exactly once.
        for e in bundle {
            let _ = web.receive(cid.clone(), e);
        }
        assert!(web.circle_web_access(cid.clone()).allowed, "{order}");
        assert!(reads(web, cid, "sealed after everyone agreed"), "{order}: the held key was opened once the yes arrived");
    }
}

#[test]
fn an_app_on_the_same_account_is_never_affected() {
    // The rule is about web devices only: a linked tablet reads the circle whatever it says.
    let alice = HavenSocial::new(ALICE.to_vec()).unwrap();
    let cid = DEFAULT_CIRCLE.to_string();
    let (tablet, _) = link(&alice, ALICE, TABLET, "Alice's tablet");
    assert!(!tablet.is_web_device());
    post(&alice, &cid, "to all my devices", 2_000);
    sync(&alice, &tablet, &cid);
    assert!(reads(&tablet, &cid, "to all my devices"));
    assert!(!alice.circle_web_access(cid.clone()).allowed);
}

#[test]
fn the_circles_answer_survives_a_restart() {
    let f = fleet(false);
    let Fleet { alice, bob, cid, .. } = &f;
    assert!(alice.set_circle_web_access(cid.clone(), true));
    assert!(bob.set_circle_web_access(cid.clone(), true));
    settle(&f);
    assert!(alice.circle_web_access(cid.clone()).allowed);

    let saved = alice.export_state();
    let again = HavenSocial::new(ALICE.to_vec()).unwrap();
    again.import_state(saved);
    let s = again.circle_web_access(cid.clone());
    assert!(s.allowed && s.mine, "both positions were saved and still verify");

    // Saying the same thing again signs nothing new.
    let before = again.export_state();
    assert!(again.set_circle_web_access(cid.clone(), true));
    assert_eq!(again.export_state(), before);
}

// ── My Circle: each account decides for its own ─────────────────────────────────────────────

/// Alice with a linked browser and her contact Bob, in everyone's own My Circle (`default`).
fn my_circle_fleet() -> Fleet {
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
    Fleet { alice, bob, web, cid }
}

#[test]
fn my_circle_opens_to_my_browser_on_my_word_alone() {
    let f = my_circle_fleet();
    let Fleet { alice, bob, web, cid } = &f;
    post(alice, cid, "mine, before I agreed", 2_000);
    settle(&f);
    assert!(!reads(web, cid, "mine, before I agreed"), "silence is still no");
    let s = alice.circle_web_access(cid.clone());
    assert!(!s.allowed && s.decided_by_admins && s.i_decide && s.waiting_on.is_empty(), "it is hers to decide, and she waits on nobody");

    // Alice says yes. Bob has said nothing and is never asked.
    assert!(alice.set_circle_web_access(cid.clone(), true));
    settle(&f);
    assert!(alice.circle_web_access(cid.clone()).allowed);
    assert!(web.circle_web_access(cid.clone()).allowed, "her browser learns her answer");
    post(alice, cid, "mine, after I agreed", 3_000);
    settle(&f);
    assert!(reads(web, cid, "mine, after I agreed"), "her own posts reach her own browser");
    assert!(reads(bob, cid, "mine, after I agreed"));

    // And she can take it back.
    assert!(alice.set_circle_web_access(cid.clone(), false));
    settle(&f);
    post(alice, cid, "mine, after I withdrew", 4_000);
    settle(&f);
    assert!(!reads(web, cid, "mine, after I withdrew"));
    assert!(reads(bob, cid, "mine, after I withdrew"));
}

#[test]
fn a_contacts_my_circle_posts_reach_my_browser_only_if_they_allowed_browsers() {
    let f = my_circle_fleet();
    let Fleet { alice, bob, web, cid } = &f;
    // Alice allows browsers in HER My Circle. That speaks for her posts, not for Bob's.
    assert!(alice.set_circle_web_access(cid.clone(), true));
    settle(&f);
    assert!(!bob.circle_web_access(cid.clone()).allowed, "Alice's yes is not Bob's");
    post(bob, cid, "bob's, he never agreed", 3_000);
    settle(&f);
    assert!(reads(alice, cid, "bob's, he never agreed"), "her app reads it");
    assert!(!reads(web, cid, "bob's, he never agreed"), "her browser does not: the author decides");

    // Bob allows browsers in his own My Circle: from then on his posts reach it too.
    assert!(bob.set_circle_web_access(cid.clone(), true));
    settle(&f);
    post(bob, cid, "bob's, after he agreed", 4_000);
    settle(&f);
    assert!(reads(web, cid, "bob's, after he agreed"));
}

#[test]
fn nobody_else_can_open_my_circle_for_me() {
    let f = my_circle_fleet();
    let Fleet { alice, bob, web, cid } = &f;
    // Bob says yes; a browser cannot sign a position at all.
    assert!(bob.set_circle_web_access(cid.clone(), true));
    assert!(!web.set_circle_web_access(cid.clone(), true));
    settle(&f);
    assert!(!alice.circle_web_access(cid.clone()).allowed, "Bob's yes does not open Alice's circle");
    post(alice, cid, "mine, I never agreed", 3_000);
    settle(&f);
    assert!(!reads(web, cid, "mine, I never agreed"));
}

