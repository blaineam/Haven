//! The relay-PULL roster arm must behave like the mailbox roster arm.
//!
//! Haven learns a contact's device roster two ways:
//!
//!   * it arrives as a mailbox envelope  → `receive()` → `TAG_DEVICE_ROSTER`
//!   * we fetch it from a relay directly → `ingest_roster_wire()`
//!
//! Same bytes, same verification — so the same consequences. They diverged in two ways, and the two
//! compose into silent, permanent content loss.
//!
//!   1. Only the mailbox arm drained `pending_epoch`. That buffer is where an envelope waits when it
//!      arrives before the key that opens it or the roster that resolves its sender.
//!   2. Re-ingesting a roster we ALREADY HOLD reported `false` — indistinguishable from a forged or
//!      rolled-back roster. Callers read that bool as "is this roster known?" and skip their
//!      post-roster recovery on `false`.
//!
//! In steady state a device re-pulls the same roster on every poll, so #2 fires constantly, and #1
//! means the one arm that could replay the buffer never did. The Android QA leg showed exactly this:
//! 188 mailbox keys marked seen, `parked: 8` in the durable buffer, a feed holding one post (its
//! own), and a log line insisting the engine "refused" a roster it had simply already learned.
//!
//!     export PATH="$HOME/.cargo/bin:$PATH"
//!     cd core && cargo test -p haven_ffi --test roster_pull_drain

mod common;
use common::*;

use haven_ffi::HavenSocial;

/// Everything `from` holds for `cid` EXCEPT its roster — the shape a contact's traffic has on a
/// device that only ever learns rosters by relay pull.
fn sync_without_roster(from: &HavenSocial, to: &HavenSocial, cid: &str) {
    const TAG_DEVICE_ROSTER: u8 = 0x04;
    for env in from.sync_envelopes(cid.to_string()) {
        if env.first() == Some(&TAG_DEVICE_ROSTER) {
            continue;
        }
        let _ = to.receive(cid.to_string(), env);
    }
}

fn parked(s: &HavenSocial, cid: &str) -> u64 {
    let json = s.diag_delivery_json();
    // Deliberately dependency-free: find this circle's object and read its `parked` counter.
    let needle = format!("\"id\":\"{cid}\"");
    let at = json.find(&needle).unwrap_or_else(|| panic!("no circle {cid} in {json}"));
    let tail = &json[at..];
    let p = tail.find("\"parked\":").expect("parked field") + "\"parked\":".len();
    let rest = &tail[p..];
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse().unwrap()
}

#[test]
fn re_ingesting_a_roster_we_already_hold_is_a_no_op_not_a_refusal() {
    let reader = account(7);
    let author = account(8);
    assert!(author.use_device_identity(vec![21u8; 32]));
    reader.add_contact_bundle(DEFAULT_CIRCLE.into(), author.my_bundle()).unwrap();
    author.add_contact_bundle(DEFAULT_CIRCLE.into(), reader.my_bundle()).unwrap();

    let wire = author.register_device(author.my_device_bundle(), "author-dev".into(), 0);
    assert!(reader.ingest_roster_wire(wire.clone()), "first ingest stores the roster");

    // Steady state: every later poll re-fetches identical bytes at the same version. That is the
    // normal case, not an error, and it must not read as a rejection.
    assert!(reader.ingest_roster_wire(wire.clone()),
            "re-ingesting the identical, already-held roster reports success (already current)");
    assert!(reader.ingest_roster_wire(wire),
            "and stays successful — the answer is stable, not alternating");
}

#[test]
fn an_older_roster_is_still_refused() {
    // The rollback defense must survive the fix above: ONLY the equal-version case is a benign
    // no-op. A genuinely older roster is an attempted replay and still has to lose.
    let author = account(9);
    assert!(author.use_device_identity(vec![22u8; 32]));
    let reader = account(10);
    reader.add_contact_bundle(DEFAULT_CIRCLE.into(), author.my_bundle()).unwrap();

    let v1 = author.register_device(author.my_device_bundle(), "dev-a".into(), 0);
    assert!(reader.ingest_roster_wire(v1.clone()), "v1 stores");

    // A SECOND, distinct device bumps the roster version.
    let second = account(9);
    assert!(second.use_device_identity(vec![23u8; 32]));
    let v2 = author.register_device(second.my_device_bundle(), "dev-b".into(), 1);
    assert!(reader.ingest_roster_wire(v2), "a NEWER roster is adopted");

    assert!(!reader.ingest_roster_wire(v1),
            "replaying the OLDER roster is refused — the rollback defense is intact");
}

#[test]
fn the_pull_arm_replays_the_parked_buffer() {
    // A reader that has NOT yet learned the author's epoch key parks the author's content. The
    // mailbox arm has always replayed that buffer on a roster; the pull arm must too, so a device
    // whose rosters only ever arrive by pull still recovers.
    let reader = account(11);
    let author = account(12);
    assert!(author.use_device_identity(vec![24u8; 32]));
    reader.add_contact_bundle(DEFAULT_CIRCLE.into(), author.my_bundle()).unwrap();
    author.add_contact_bundle(DEFAULT_CIRCLE.into(), reader.my_bundle()).unwrap();
    let wire = author.register_device(author.my_device_bundle(), "author-dev".into(), 0);

    author.post(DEFAULT_CIRCLE.into(), "pulled-back".into(), vec![], None, None, false, false, 5_000).unwrap();
    sync_without_roster(&author, &reader, DEFAULT_CIRCLE);

    // Whatever the reader could not open sits in the durable buffer. Learning the roster BY PULL
    // must trigger the replay — and must keep doing so on the already-current re-pulls that follow,
    // because that is the only trigger this arm ever gets.
    let before = parked(&reader, DEFAULT_CIRCLE);
    assert!(reader.ingest_roster_wire(wire.clone()), "the pull arm reports the roster as known");
    assert!(reader.ingest_roster_wire(wire), "and again on the steady-state re-pull");
    assert!(parked(&reader, DEFAULT_CIRCLE) <= before,
            "the pull arm never GROWS the parked buffer — it replays it");
}

#[test]
fn the_delivery_diagnostic_separates_parked_from_absent() {
    // The whole point of the diagnostic: a short feed alone cannot tell "never arrived" from
    // "arrived and could not be opened". These two states must read differently.
    let quiet = account(13);
    assert_eq!(parked(&quiet, DEFAULT_CIRCLE), 0, "a device nobody has written to holds nothing back");

    let json = quiet.diag_delivery_json();
    assert!(json.contains("\"circles\":["), "reports circles");
    assert!(json.contains("\"rosters\":["), "reports known rosters");
    assert!(json.contains("\"events\":"), "reports what IS readable alongside what is parked");
}
