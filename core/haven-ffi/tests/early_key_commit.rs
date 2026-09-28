//! A new friend's key commit routinely reaches my mailbox BEFORE their bundle is added to my circle
//! (the grant/hello and their first commit race). The engine used to DROP a commit from a committer
//! it couldn't resolve — while the mailbox had already marked its key seen — so every post they
//! sealed under that epoch sat in `pending_epoch` until the next periodic history resend (minutes to
//! an hour: "new friends take a while"). The commit is now parked (durably) and replayed the moment
//! the member lands.
//!
//!     cd core && cargo test -p haven_ffi --test early_key_commit

mod common;
use common::*;

use haven_ffi::HavenSocial;

fn bodies(s: &HavenSocial) -> Vec<String> {
    s.feed(DEFAULT_CIRCLE.into(), 10_000, None).into_iter().map(|f| f.body).collect()
}

/// Deliver everything the author holds for the default circle to `to` (commit + posts + roster).
fn deliver_all(from: &HavenSocial, to: &HavenSocial) {
    for env in from.sync_envelopes(DEFAULT_CIRCLE.to_string()) {
        let _ = to.receive(DEFAULT_CIRCLE.to_string(), env);
    }
}

#[test]
fn key_commit_before_membership_is_recovered_when_the_member_is_added() {
    let reader = account(31);
    let author = account(32);
    author.add_contact_bundle(DEFAULT_CIRCLE.into(), reader.my_bundle()).unwrap();
    author
        .post(DEFAULT_CIRCLE.into(), "hello-new-friend".into(), vec![], None, None, false, false, 1_000)
        .unwrap();

    // The author's commit + post arrive BEFORE the reader has added them (grant still in flight).
    deliver_all(&author, &reader);
    assert!(!bodies(&reader).iter().any(|b| b == "hello-new-friend"), "not yet a member — can't open");

    // The friendship lands: adding the member must replay the parked commit and unlock the post
    // WITHOUT any re-delivery (the mailbox already marked those keys seen).
    reader.add_contact_bundle(DEFAULT_CIRCLE.into(), author.my_bundle()).unwrap();
    assert!(
        bodies(&reader).iter().any(|b| b == "hello-new-friend"),
        "parked key commit replayed on member add → post opens: {:?}",
        bodies(&reader)
    );
}

#[test]
fn a_parked_key_commit_survives_export_import() {
    let reader = account(33);
    let author = account(34);
    author.add_contact_bundle(DEFAULT_CIRCLE.into(), reader.my_bundle()).unwrap();
    author
        .post(DEFAULT_CIRCLE.into(), "survives-restart".into(), vec![], None, None, false, false, 1_000)
        .unwrap();
    deliver_all(&author, &reader);

    // App killed before the friendship landed: the parked commit + event must be in the state blob.
    let blob = reader.export_state();
    let restarted = account(33);
    restarted.import_state(blob);
    assert!(!bodies(&restarted).iter().any(|b| b == "survives-restart"));

    restarted.add_contact_bundle(DEFAULT_CIRCLE.into(), author.my_bundle()).unwrap();
    assert!(
        bodies(&restarted).iter().any(|b| b == "survives-restart"),
        "commit parked before the restart still unlocks the post after it: {:?}",
        bodies(&restarted)
    );

    // And the other recovery trigger: membership arriving via an imported state blob (another of my
    // devices synced the new member) must drain too.
    let reader2 = account(33);
    let author2 = account(35);
    author2.add_contact_bundle(DEFAULT_CIRCLE.into(), reader2.my_bundle()).unwrap();
    author2
        .post(DEFAULT_CIRCLE.into(), "via-sibling-sync".into(), vec![], None, None, false, false, 1_000)
        .unwrap();
    deliver_all(&author2, &reader2);
    let sibling = account(33);
    sibling.add_contact_bundle(DEFAULT_CIRCLE.into(), author2.my_bundle()).unwrap();
    reader2.import_state(sibling.export_state());
    assert!(
        bodies(&reader2).iter().any(|b| b == "via-sibling-sync"),
        "member learned through a state merge replays the parked commit: {:?}",
        bodies(&reader2)
    );
}
