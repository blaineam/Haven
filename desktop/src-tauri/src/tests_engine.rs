//! Engine behaviour tests, run in-process on throwaway data dirs. A child module of `engine` so
//! it can reach private fields and the inbound handlers (`handle_hello`, `handle_event`) and wire
//! two engines together without any network. Nothing here starts the node, opens the keyring, or
//! touches the owner's data.

use super::*;
use crate::covtest_util::{engine, tmp_paths};
use std::sync::Arc;

fn items(e: &Arc<Engine>, cid: &str) -> Vec<FeedItemFfi> {
    e.feed(cid)
}

/// Deliver everything `from` holds for `cid` to `to` the way the live sync path does.
pub(crate) fn deliver(from: &Arc<Engine>, to: &Arc<Engine>, cid: &str) {
    for env in from.social.sync_envelopes(cid.to_string()) {
        to.handle_event(&wire::event_payload(cid, &env), None);
    }
}

/// Feed `from`'s signed hello into `to`, the way the transport would deliver it.
pub(crate) fn hello_into(to: &Arc<Engine>, from: &Arc<Engine>) {
    to.handle_hello(&from.hello_payload(DEFAULT_CIRCLE).expect("hello builds"));
}

/// Test-only view of private engine state for sibling test modules.
pub(crate) fn prefs_of(e: &Engine) -> parking_lot::MutexGuard<'_, Prefs> {
    e.prefs.lock()
}

pub(crate) fn is_foreground(e: &Engine) -> bool {
    e.dyn_state.lock().foreground
}

/// Make `a` and `b` contacts of each other on the default circle via the real hello handlers.
pub(crate) fn befriend(a: &Arc<Engine>, b: &Arc<Engine>) {
    // a scans b's invite, b's hello answers it (the initiator path), then b approves a's hello.
    assert!(a.connect_by_link(b.invite_uri()));
    let hb = b.hello_payload(DEFAULT_CIRCLE).unwrap();
    a.handle_hello(&hb);
    let ha = a.hello_payload(DEFAULT_CIRCLE).unwrap();
    b.handle_hello(&ha);
    assert_eq!(b.pending().len(), 1, "a stranger's hello waits for approval");
    b.approve(a.node_id_hex());
}

#[test]
fn engine_writes_its_qa_identity_files_and_derives_stable_ids() {
    let (e, paths) = engine(1);
    let hex = e.node_id_hex();
    assert_eq!(hex.len(), 64);
    assert_eq!(std::fs::read_to_string(paths.root.join("qa-account-hex.txt")).unwrap(), hex);
    assert_eq!(std::fs::read_to_string(paths.root.join("qa-device-hex.txt")).unwrap().len(), 64);
    // Same seed, same account; different seed, different account.
    let again = Engine::new(tmp_paths(), [1u8; 32]).unwrap();
    assert_eq!(again.node_id_hex(), hex);
    assert_ne!(engine(2).0.node_id_hex(), hex);
    assert!(!e.is_seedless());
    assert_eq!(e.seedless_status(), (false, false, false));
    assert!(!e.started());
}

#[test]
fn invite_links_carry_the_account_and_use_the_given_domain() {
    let (e, _) = engine(3);
    let uri = e.invite_uri();
    assert!(uri.starts_with("haven:"), "{uri}");
    let web = e.invite_link("haven.example");
    assert!(web.contains("haven.example"), "{web}");
    // Each link round-trips through the core parser to this account id.
    let info = parse_link(uri).expect("own invite parses");
    assert_eq!(info.id_hex, e.node_id_hex());
}

#[tokio::test]
async fn profile_edits_stamp_changed_fields_and_survive_a_relaunch() {
    let (e, paths) = engine(4);
    let mut p = e.get_profile();
    assert!(p.name.is_empty());
    p.name = "Ada".into();
    p.bio = "hi".into();
    e.set_profile(p.clone());
    assert_eq!(e.get_profile().name, "Ada");
    {
        let prefs = e.prefs.lock();
        assert!(prefs.profile_field_stamp("name") > 0 && prefs.profile_field_stamp("bio") > 0);
        assert_eq!(prefs.profile_field_stamp("emoji"), 0, "untouched fields are not stamped");
    }
    let relaunched = Engine::new(paths, [4u8; 32]).unwrap();
    assert_eq!(relaunched.get_profile().name, "Ada", "profile persisted to prefs.json");
}

#[tokio::test]
async fn posting_commenting_reacting_editing_and_unsending_shape_the_feed() {
    let (e, _) = engine(5);
    e.post(DEFAULT_CIRCLE.into(), "   ".into(), vec![], None, false, None);
    assert!(items(&e, DEFAULT_CIRCLE).is_empty(), "a blank post is refused");

    e.post(DEFAULT_CIRCLE.into(), "first".into(), vec![], None, false, None);
    let feed = items(&e, DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 1);
    assert!(feed[0].is_me);
    let id = feed[0].id.clone();

    e.comment(DEFAULT_CIRCLE.into(), id.clone(), " ".into());
    e.comment(DEFAULT_CIRCLE.into(), id.clone(), "nice".into());
    e.react(DEFAULT_CIRCLE.into(), id.clone(), "🎉".into());
    let it = items(&e, DEFAULT_CIRCLE).into_iter().find(|i| i.id == id).unwrap();
    assert_eq!(it.comments.len(), 1, "blank comment refused, real one kept");
    assert_eq!(it.comments[0].body, "nice");
    assert_eq!(it.reactions.len(), 1);

    e.unreact(DEFAULT_CIRCLE.into(), id.clone(), "🎉".into());
    let it = items(&e, DEFAULT_CIRCLE).into_iter().find(|i| i.id == id).unwrap();
    assert!(it.reactions.iter().all(|r| r.count == 0) || it.reactions.is_empty());

    e.edit_post(DEFAULT_CIRCLE.into(), id.clone(), "first (edited)".into(), None, None, None).unwrap();
    let it = items(&e, DEFAULT_CIRCLE).into_iter().find(|i| i.id == id).unwrap();
    assert_eq!(it.body, "first (edited)");
    assert!(it.edited);
    // An edit aimed at an id that does not exist is accepted but changes nothing.
    let _ = e.edit_post(DEFAULT_CIRCLE.into(), "no-such-id".into(), "x".into(), Some(vec![]), None, None);
    assert_eq!(items(&e, DEFAULT_CIRCLE).len(), 1);
    assert_eq!(items(&e, DEFAULT_CIRCLE)[0].body, "first (edited)");

    e.unsend_post(DEFAULT_CIRCLE.into(), id.clone());
    let gone = items(&e, DEFAULT_CIRCLE);
    assert!(gone.iter().all(|i| i.id != id || i.unsent), "unsent post is gone or marked unsent");
}

#[tokio::test]
async fn stories_are_flagged_and_expire_after_a_day() {
    let (e, _) = engine(6);
    e.post_story(DEFAULT_CIRCLE.into(), "".into(), None, None);
    assert!(items(&e, DEFAULT_CIRCLE).is_empty());
    e.post_story(DEFAULT_CIRCLE.into(), "story time".into(), None, None);
    let feed = items(&e, DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 1);
    assert!(feed[0].story);
}

#[tokio::test]
async fn imported_posts_are_backdated_and_deduped_by_the_sweeper() {
    let (e, _) = engine(7);
    e.post_imported(DEFAULT_CIRCLE.into(), "".into(), vec![], None, false, 5);
    e.post_imported(DEFAULT_CIRCLE.into(), "old photo".into(), vec![], None, false, 1_500_000_000_000);
    let feed = items(&e, DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 1);
    assert_eq!(feed[0].created_at, 1_500_000_000_000, "imports keep their original capture time");
    assert_eq!(e.sweep_duplicate_imports(DEFAULT_CIRCLE), 0, "nothing to sweep when there are no duplicates");
}

#[tokio::test]
async fn state_survives_a_relaunch_on_the_same_data_dir() {
    let (e, paths) = engine(8);
    e.post(DEFAULT_CIRCLE.into(), "persisted".into(), vec![], None, false, None);
    e.flush_pending_persist();
    let again = Engine::new(paths, [8u8; 32]).unwrap();
    let feed = again.feed(DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 1);
    assert_eq!(feed[0].body, "persisted");
}

#[tokio::test]
async fn circles_create_rename_and_leave_with_a_synced_tombstone() {
    let (e, _) = engine(9);
    let id = e.create_circle("Book Club".into());
    assert!(e.prefs.lock().created_circles.contains(&id));
    let circles = e.feed_circles();
    assert!(circles.iter().any(|c| c.id == id && c.name == "Book Club"));
    assert!(!e.circle_admins(&id).is_empty(), "the creator is an admin of an owned circle");
    assert!(e.circle_admins(&id).iter().any(|a| *a == e.node_id_hex()));

    e.rename_circle(id.clone(), "Readers".into());
    assert!(e.feed_circles().iter().any(|c| c.id == id && c.name == "Readers"));

    e.leave_circle(DEFAULT_CIRCLE.into());
    assert!(e.feed_circles().iter().any(|c| c.id == DEFAULT_CIRCLE), "the personal circle can't be left");

    e.leave_circle(id.clone());
    assert!(e.prefs.lock().is_circle_deleted(&id), "leaving stamps an LWW deletion");
    assert!(e.feed_circles().iter().all(|c| c.id != id));
    assert!(!e.can_offer_circle_upgrade("default".into()));
    assert!(!e.can_offer_circle_upgrade("dm:x-y".into()));
    assert!(e.pending_circle_upgrades(id).is_empty());
}

#[tokio::test]
async fn two_engines_befriend_and_see_each_others_posts() {
    let (a, _) = engine(10);
    let (b, _) = engine(11);
    let mut pa = a.get_profile();
    pa.name = "Alice".into();
    a.set_profile(pa);
    befriend(&a, &b);

    assert_eq!(b.contacts().len(), 1);
    assert_eq!(b.contacts()[0].name, "Alice", "name comes from the signed card");
    assert_eq!(a.contacts().len(), 1, "the initiator learns the contact from the answering hello");
    assert!(b.pending().is_empty());

    a.post(DEFAULT_CIRCLE.into(), "hello bob".into(), vec![], None, false, None);
    deliver(&a, &b, DEFAULT_CIRCLE);
    let seen = b.feed(DEFAULT_CIRCLE);
    assert!(seen.iter().any(|i| i.body == "hello bob" && !i.is_me));
    assert_eq!(b.display_name(&a.node_id_hex()[..8]), "Alice");
    assert_eq!(b.display_name("zzzzzzzzzzzz"), "Someone (zzzzzz)");
    assert_eq!(b.display_name("abc"), "abc");

    // The activity bell lists Alice's post for Bob.
    let acts = b.activity();
    assert!(acts.iter().any(|r| r.snippet.contains("hello bob")), "no activity row mentions the post ({} rows)", acts.len());
    assert!(acts.windows(2).all(|w| w[0].created_at >= w[1].created_at), "newest first");
    let seen_before = b.activity_seen_at();
    b.mark_activity_seen();
    assert!(b.activity_seen_at() >= seen_before);
}

#[tokio::test]
async fn direct_messages_thread_unread_counts_and_clear_watermarks() {
    let (a, _) = engine(12);
    let (b, _) = engine(13);
    befriend(&a, &b);

    let dm = a.start_dm(b.node_id_hex(), "Bob".into());
    assert_eq!(dm, b.dm_circle_id(&a.node_id_hex()), "both sides derive the same thread id");
    assert!(dm.starts_with("dm:"));
    a.send_dm(dm.clone(), "  ".into(), vec![], None, None);
    assert!(a.messages(&dm).is_empty());
    a.send_dm(dm.clone(), "psst".into(), vec![], None, None);
    assert_eq!(a.messages(&dm).len(), 1);

    // Bob has never opened this thread; the live event creates it because Alice is his contact.
    assert!(b.messages(&dm).is_empty());
    deliver(&a, &b, &dm);
    let msgs = b.messages(&dm);
    assert_eq!(msgs.len(), 1, "{} messages", msgs.len());
    assert_eq!(msgs[0].body, "psst");

    let threads = b.dm_threads();
    assert_eq!(threads.len(), 1);
    assert_eq!(threads[0].0, dm);
    assert_eq!(threads[0].2, "psst");
    assert_eq!(threads[0].5, 1, "one unread inbound message");
    b.mark_dm_read(dm.clone());
    assert_eq!(b.dm_threads()[0].5, 0, "viewing the thread clears the badge");

    // Own thread has no unread (my own messages never badge).
    assert_eq!(a.dm_threads()[0].5, 0);

    b.delete_conversation(dm.clone());
    assert!(b.messages(&dm).is_empty(), "cleared-before watermark hides history");
    assert!(b.dm_threads().is_empty());
    b.delete_conversation("not-a-dm".into()); // ignored
}

#[tokio::test]
async fn group_dm_ids_are_order_independent_and_message_author_stages_a_draft() {
    let (a, _) = engine(14);
    let (b, _) = engine(15);
    let (c, _) = engine(16);
    let x = a.group_dm_circle_id(&[b.node_id_hex(), c.node_id_hex()]);
    let y = a.group_dm_circle_id(&[c.node_id_hex(), b.node_id_hex(), b.node_id_hex().to_uppercase()]);
    assert_eq!(x, y, "sorted, lowercased, deduped");
    assert_eq!(x.matches('-').count(), 2);

    befriend(&a, &b);
    let target = a.message_author(b.node_id_hex()[..8].to_string(), DEFAULT_CIRCLE.into(), "post1".into());
    let t = target.expect("known contact");
    assert_eq!(t.name, "Someone", "b never set a profile name, so its card says Someone");
    assert!(t.dm.starts_with("dm:"));
    assert!(a.message_author("00000000".into(), DEFAULT_CIRCLE.into(), "p".into()).is_none(), "non-contacts can't be DMed");
    let g = a.start_group_dm(vec![(b.node_id_hex(), "Bob".into())]);
    assert_eq!(g, a.dm_circle_id(&b.node_id_hex()), "a one-member group is a plain DM");
}

#[tokio::test]
async fn blocking_removes_the_contact_and_drops_their_future_hellos() {
    let (a, _) = engine(17);
    let (b, _) = engine(18);
    befriend(&a, &b);
    let bhex = b.node_id_hex();
    a.block(bhex.clone());
    assert!(a.contacts().is_empty());
    assert_eq!(a.blocked(), vec![bhex.clone()]);
    assert!(a.prefs.lock().contact_removed_at.contains_key(&bhex), "block leaves an LWW contact tombstone");
    // A hello from the blocked account is ignored outright.
    let hb = b.hello_payload(DEFAULT_CIRCLE).unwrap();
    a.handle_hello(&hb);
    assert!(a.pending().is_empty() && a.contacts().is_empty());
    a.unblock(bhex);
    assert!(a.blocked().is_empty());
    // Now the hello becomes a pending request again, which can be dismissed.
    a.handle_hello(&hb);
    assert_eq!(a.pending().len(), 1);
    a.dismiss(b.node_id_hex());
    assert!(a.pending().is_empty());
}

#[tokio::test]
async fn bad_links_do_not_connect() {
    let (e, _) = engine(19);
    assert!(!e.connect_by_link("not a link".into()));
    assert!(e.dyn_state.lock().initiated.is_empty());
}

#[tokio::test]
async fn removing_a_member_blocks_their_unsolicited_rejoin_until_re_added() {
    let (a, _) = engine(20);
    let (b, _) = engine(21);
    befriend(&a, &b);
    let cid = a.create_circle("Club".into());
    a.add_to_circle(cid.clone(), b.node_id_hex());
    assert!(a.circle_member_ids(&cid).contains(&b.node_id_hex()));
    a.remove_from_circle(cid.clone(), b.node_id_hex());
    assert!(a.is_removed_from_circle(&cid, &b.node_id_hex()));
    assert!(!a.circle_member_ids(&cid).contains(&b.node_id_hex()));
    a.add_to_circle(cid.clone(), b.node_id_hex());
    assert!(!a.is_removed_from_circle(&cid, &b.node_id_hex()), "a deliberate re-add lifts the severance");
}

#[tokio::test]
async fn scheduled_items_queue_persist_cancel_and_fire_when_due() {
    use crate::scheduled::SchedKind;
    let (e, paths) = engine(22);
    let later = e.schedule(SchedKind::Post, DEFAULT_CIRCLE.into(), "future".into(), vec![], None, false, now_ms() + 3_600_000);
    let due = e.schedule(SchedKind::Post, DEFAULT_CIRCLE.into(), "due now".into(), vec![], None, false, 1);
    let gone = e.schedule(SchedKind::Post, DEFAULT_CIRCLE.into(), "cancelled".into(), vec![], None, false, 2);
    assert_eq!(e.list_scheduled().len(), 3);
    assert_ne!(later, due);
    e.cancel_scheduled(&gone);
    e.cancel_scheduled("nope"); // unknown id is a no-op
    assert_eq!(e.list_scheduled().len(), 2);
    assert!(Engine::new(paths, [22u8; 32]).unwrap().list_scheduled().len() == 2, "queue persists");

    e.fire_due_scheduled();
    let feed = e.feed(DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 1, "only the due item was authored");
    assert_eq!(feed[0].body, "due now");
    assert_eq!(e.list_scheduled().len(), 1);
    assert_eq!(e.list_scheduled()[0].id, later);
}

#[tokio::test]
async fn simple_settings_round_trip_through_prefs() {
    let (e, paths) = engine(23);
    assert_eq!(e.privacy_prefs(), ("full".to_string(), false, false));
    e.set_privacy_prefs(Some("private".into()), Some(true), Some(true));
    assert_eq!(e.privacy_prefs(), ("private".to_string(), true, true));
    e.set_privacy_prefs(Some("garbage".into()), None, None);
    assert_eq!(e.privacy_prefs().0, "full", "unknown detail levels fall back to full");

    assert_eq!(e.low_data_level(), "low", "the manual data saver forces at least the low profile");
    e.set_privacy_prefs(None, Some(false), None);
    assert_eq!(e.low_data_level(), "normal");
    e.set_low_data_level("ultra");
    assert_eq!(e.low_data_level(), "ultra");
    e.set_low_data_level("low"); // improving the link triggers a (no-op offline) media catch-up
    assert_eq!(e.low_data_level(), "low");
    e.set_low_data_level("bogus");
    assert_eq!(e.low_data_level(), "normal");

    assert!(!e.video_sound_on());
    e.set_video_sound(true);
    assert!(e.video_sound_on());
    assert!(!e.host_on_launch());
    e.set_host_on_launch(true);
    e.set_host_on_launch(true);
    assert!(e.host_on_launch());
    assert!(e.prefs.lock().setting_stamp("host_on_launch") > 0);

    e.set_pinned_dms((0..9).map(|i| format!("dm{i}")).collect());
    assert_eq!(e.pinned_dms().len(), 6, "pins are capped at six");

    let re = Engine::new(paths, [23u8; 32]).unwrap();
    assert!(re.video_sound_on() && re.host_on_launch());
    assert_eq!(re.pinned_dms().len(), 6);
}

#[tokio::test]
async fn sync_status_reflects_configured_transports() {
    let (e, _) = engine(24);
    assert_eq!(e.sync_status(DEFAULT_CIRCLE), "local", "no relay and not online: device-only");
    e.dyn_state.lock().internet_active = true;
    assert_eq!(e.sync_status(DEFAULT_CIRCLE), "synced");
    e.dyn_state.lock().internet_active = false;
    e.prefs.lock().host_on_launch = true;
    assert_eq!(e.sync_status(DEFAULT_CIRCLE), "synced", "hosting your own relay counts");
}

#[tokio::test]
async fn identity_roster_errors_are_reported_without_touching_the_keyring() {
    let (e, _) = engine(25);
    assert!(e.identities().is_empty());
    assert!(e.rename_identity("nobody", "x").is_err());
    assert!(e.set_active_identity("nobody").is_err());
    assert!(e.remove_identity("nobody").is_err());
}

#[tokio::test]
async fn enroll_ticket_lifecycle_for_a_new_seedless_device() {
    let (primary, _) = engine(26);
    let ticket = primary.mint_enroll_ticket().expect("a seed holder can mint tickets");
    assert!(ticket.starts_with("haven-enroll:"), "{ticket}");
    assert_eq!(primary.enroll_tickets.lock().len(), 1);
    let (enabled, _authorized, devices) = primary.device_roster_dto();
    assert!(enabled, "minting enables the roster on the primary");
    assert_eq!(devices.len(), 1);

    // The new device builds its request from the ticket; the primary verifies it and queues it.
    let parsed = haven_ffi::enroll::enroll_ticket_parse(ticket).unwrap();
    let device = crate::roster::DeviceRoster::load(&tmp_paths());
    let req = haven_ffi::enroll::enroll_build_request(parsed.secret.clone(), device.device_bundle(), "Laptop".into(), now_ms() / 1000)
        .unwrap();
    primary.handle_seedless_enroll_request(None, &req);
    let pending = primary.enroll_pending();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].1, "Laptop");
    primary.handle_seedless_enroll_request(None, &req); // a resend is ignored
    assert_eq!(primary.enroll_pending().len(), 1);
    primary.handle_seedless_enroll_request(None, b"garbage");
    assert_eq!(primary.enroll_pending().len(), 1);

    primary.reject_enroll(pending[0].0.clone());
    assert!(primary.enroll_pending().is_empty());
    assert!(primary.approve_enroll("ffff".into()).is_err(), "approving an unknown request fails");

    primary.handle_seedless_enroll_request(None, &req);
    let dev_hex = primary.enroll_pending()[0].0.clone();
    primary.approve_enroll(dev_hex.clone()).expect("approval succeeds");
    assert!(primary.enroll_pending().is_empty());
    let (_, _, devices) = primary.device_roster_dto();
    assert!(devices.len() >= 2, "the approved device is in the signed roster ({} devices)", devices.len());
    assert!(primary.enroll_tickets.lock()[0].consumed, "tickets are single use");

    // A consumed ticket can't be replayed.
    primary.handle_seedless_enroll_request(None, &req);
    assert!(primary.enroll_pending().is_empty());

    primary.revoke_device(dev_hex.clone());
    let (_, _, after) = primary.device_roster_dto();
    assert!(after.iter().all(|d| d.node_hex != dev_hex), "a revoked device leaves the roster");
}

#[tokio::test]
async fn a_seedless_engine_cannot_author_account_level_things() {
    let (e, _) = engine(27);
    // The primary's own enrolment helpers must keep refusing on seedless engines; we exercise the
    // guard through a freshly built seedless engine on a data dir that has only a device key.
    let paths = tmp_paths();
    let s = Engine::new_seedless(paths).expect("seedless engine builds on a bare data dir");
    assert!(s.is_seedless());
    assert!(s.mint_enroll_ticket().is_err());
    assert!(s.approve_enroll("aa".into()).is_err());
    let (seedless, linked, linking) = s.seedless_status();
    assert!(seedless && !linked && linking);
    drop(e);
}
