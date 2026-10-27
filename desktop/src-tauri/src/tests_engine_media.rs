//! Engine relay management, pins / kept stories, the evicted set, local media limits and
//! re-optimization: the device-local policy code that decides what is kept, where it syncs and what
//! may be deleted. In-process on throwaway dirs; nothing here reaches a network.

use super::*;
use crate::covtest_util::engine as new_engine;
use crate::engine::cov_engine_tests::{befriend, deliver};
use crate::store::KeptStory;

const R1: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const R2: &str = "2222222222222222222222222222222222222222222222222222222222222222";

fn story(id: &str, media: &[&str]) -> KeptStory {
    KeptStory {
        id: id.into(),
        body: "b".into(),
        media: media.iter().map(|s| s.to_string()).collect(),
        created_at: 100,
        kept_at: None,
        music_catalog_id: None,
        music_title: None,
        music_artist: None,
        music_artwork_url: None,
        music_duration_ms: None,
    }
}

/// A JPEG that is nothing but a valid header (SOF0) padded to `total` bytes — `probe_image` reads
/// dimensions from the header and never decodes.
fn fake_jpeg(w: u16, h: u16, total: usize) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08];
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&[0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
    v.resize(total, 0xAB);
    v
}

// ── relays ──────────────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn adopting_a_relay_by_bare_id_or_by_announcement_json() {
    let (e, _) = new_engine(90);
    e.adopt_relay("not-a-node-id".into()).await;
    e.adopt_relay("{ not json".into()).await;
    e.adopt_relay(format!("{{\"node\":\"{}\"}}", "short")).await;
    assert!(e.relays_detail().is_empty(), "malformed input adopts nothing");

    e.adopt_relay(format!("  {}  ", R1.to_uppercase())).await;
    let d = e.relays_detail();
    assert_eq!(d.len(), 1);
    assert_eq!(d[0].node_hex, R1, "ids are normalised to lowercase");
    assert!(d[0].active && !d[0].is_default && !d[0].is_s3);
    assert!(e.circle_relay_hexes(DEFAULT_CIRCLE).contains(&R1.to_string()), "every circle gets the relay");

    let json = serde_json::json!({
        "node": R2, "urls": ["http://10.0.0.5:8080", "ftp://ignored"], "token": "tok",
        "derp": "https://derp.example/", "turn": ["turn:turn.example:3478"], "turnUser": "", "turnPass": "",
    });
    e.adopt_relay(json.to_string()).await;
    let p = e.prefs.lock();
    let entry = &p.relay_entries[R2];
    assert_eq!(entry.http_urls, vec!["http://10.0.0.5:8080".to_string()], "only http(s) urls are kept");
    assert_eq!(entry.http_token, "tok");
    assert_eq!(entry.derp_url, "https://derp.example", "trailing slash trimmed");
    assert_eq!(entry.turn_urls, vec!["turn:turn.example:3478".to_string()]);
    assert_eq!(entry.turn_user, haven_net::DEFAULT_TURN_USER, "a missing TURN user defaults");
    assert_eq!(entry.turn_pass, "tok", "and the relay token stands in for a missing TURN password");
}

#[tokio::test]
async fn forgetting_reactivating_renaming_and_defaulting_a_relay() {
    let (e, _) = new_engine(91);
    e.adopt_relay(R1.into()).await;
    e.rename_relay(R1.into(), "   ".into());
    assert_ne!(e.relays_detail()[0].name, "", "a blank name is ignored");
    e.rename_relay(R1.to_uppercase(), "  Home  ".into());
    assert_eq!(e.relays_detail()[0].name, "Home");
    e.rename_relay(R2.into(), "ghost".into()); // unknown: no-op

    e.set_default_relay(R1.into());
    assert!(e.relays_detail()[0].is_default);
    e.set_default_relay(String::new());
    assert!(!e.relays_detail()[0].is_default && e.prefs.lock().default_relay.is_empty());

    e.forget_relay(R1.into()).await;
    {
        let p = e.prefs.lock();
        assert!(!p.relay_is_active(R1), "forgetting deactivates and never erases");
        assert!(p.suppressed_relays.contains(&R1.to_string()));
        assert!(p.relay_forgotten_at_ms(R1) > 0);
        assert!(p.relay_entries.contains_key(R1), "the config survives");
    }
    assert!(e.relays_for(DEFAULT_CIRCLE).is_empty(), "an inactive relay is not dialed");
    e.reactivate_relay(R1.into()).await;
    {
        let p = e.prefs.lock();
        assert!(p.relay_is_active(R1));
        assert!(p.suppressed_relays.is_empty(), "reactivating clears the suppression");
    }
    assert_eq!(e.relays_for(DEFAULT_CIRCLE), vec![R1.to_string()]);
}

/// e2e `multirelay: no private circle's media on a friend's relay that doesn't serve it`: the default
/// relay was the FRIEND's, so A's new PRIVATE circle inherited it — mailbox, enrollment and media landed
/// on a relay whose operator is not in that circle, and self-sync exported it as the circle's own relay.
#[tokio::test]
async fn a_friends_default_relay_is_not_inherited_by_a_circle_the_friend_is_not_in() {
    let (a, _) = new_engine(93);
    let (b, _) = new_engine(94);
    befriend(&a, &b);
    let b_relay = b.node_id_hex(); // B's relay, as A learned it
    a.set_default_relay(b_relay.clone());

    let private = a.create_circle("Private".into());
    let shared = a.create_circle("Shared".into());
    a.social.add_existing_to_circle(shared.clone(), b_relay.clone()).unwrap();

    assert!(a.relays_for(&private).is_empty(), "the private circle must not land on B's relay");
    assert_eq!(a.relays_for(&shared), vec![b_relay.clone()], "the shared circle keeps it");
    assert_eq!(a.relays_for(DEFAULT_CIRCLE), vec![b_relay.clone()], "so does the circle the friendship lives in");
    assert!(
        a.prefs.lock().fallback_relays_for(&private).is_empty(),
        "a relay-less circle is not guessed onto the friend's relay either"
    );

    // Ticking it for the private circle is the user's explicit choice and is honoured.
    a.prefs.lock().relays.entry(private.clone()).or_default().push(b_relay.clone());
    assert_eq!(a.relays_for(&private), vec![b_relay.clone()]);

    // A relay nobody here knows as a contact's is inherited by every circle, as before.
    a.prefs.lock().relays.remove(&private);
    a.set_default_relay(R1.into());
    assert_eq!(a.relays_for(&private), vec![R1.to_string()]);
}

#[tokio::test]
async fn erasing_archives_the_relay_so_it_can_be_restored_exactly() {
    let (e, _) = new_engine(92);
    e.adopt_relay(R1.into()).await;
    e.set_default_relay(R1.into());
    e.rename_relay(R1.into(), "Studio".into());
    e.erase_relay(R1.into()).await;
    assert!(e.relays_detail().is_empty());
    assert!(e.circle_relay_hexes(DEFAULT_CIRCLE).is_empty(), "every circle association is dropped");
    assert!(e.prefs.lock().default_relay.is_empty());
    let erased = e.erased_relays();
    assert_eq!(erased.len(), 1);
    assert!(erased[0].was_default);
    assert_eq!(erased[0].circles, vec![DEFAULT_CIRCLE.to_string()]);

    e.restore_erased_relay(R1.into()).await;
    let d = e.relays_detail();
    assert_eq!(d.len(), 1);
    assert_eq!(d[0].name, "Studio");
    assert!(d[0].is_default && d[0].active, "name, default pick and activity come back");
    assert!(e.circle_relay_hexes(DEFAULT_CIRCLE).contains(&R1.to_string()));
    assert!(e.erased_relays().is_empty());
    assert!(e.prefs.lock().relay_forgotten_at_ms(R1) == 0, "the deletion stamp is cleared so sync cannot re-delete it");
    e.restore_erased_relay(R2.into()).await; // nothing archived: no-op

    e.erase_relay(R1.into()).await;
    e.drop_erased_relay(R1.into());
    assert!(e.erased_relays().is_empty(), "dropping forgets the undo for good");
}

#[tokio::test]
async fn the_erased_archive_is_bounded() {
    let (e, _) = new_engine(93);
    for i in 0..15u8 {
        let hex = format!("{:064x}", u128::from(i) + 1);
        e.prefs.lock().ensure_relay_entry(&hex, None, false, true);
        e.erase_relay(hex).await;
    }
    assert_eq!(e.erased_relays().len(), 12, "capped at twelve");
}

#[tokio::test]
async fn only_relays_that_are_inactive_and_long_unseen_are_purged() {
    let (e, _) = new_engine(94);
    e.adopt_relay(R1.into()).await;
    e.adopt_relay(R2.into()).await;
    {
        let mut p = e.prefs.lock();
        for h in [R1, R2] {
            let r = p.relay_entries.get_mut(h).unwrap();
            r.active = false;
            r.last_seen_ms = 1;
        }
        p.relay_entries.get_mut(R2).unwrap().last_seen_ms = now_ms();
    }
    e.purge_stale_relays().await;
    let hexes: Vec<_> = e.relays_detail().into_iter().map(|d| d.node_hex).collect();
    assert_eq!(hexes, vec![R2.to_string()], "recently seen relays survive even when inactive");
}

#[tokio::test]
async fn per_circle_relay_overrides_can_be_toggled() {
    let (e, _) = new_engine(95);
    let cid = e.create_circle("Work".into());
    e.set_circle_relay(R1.into(), cid.clone(), true).await;
    assert_eq!(e.circle_relay_hexes(&cid), vec![R1.to_string()]);
    assert!(e.circle_relay_hexes(DEFAULT_CIRCLE).is_empty(), "scoped to that one circle");
    e.set_circle_relay(R1.into(), cid.clone(), false).await;
    assert!(e.circle_relay_hexes(&cid).is_empty());
    assert!(!e.prefs.lock().relays.contains_key(&cid), "an emptied list is removed");
}

#[tokio::test]
async fn relay_rows_sort_active_first_then_by_name_and_media_goes_to_every_known_relay() {
    let (e, _) = new_engine(96);
    {
        let mut p = e.prefs.lock();
        p.ensure_relay_entry(R2, Some("beta"), false, true);
        p.ensure_relay_entry(R1, Some("Alpha"), false, true);
        p.ensure_relay_entry("s3:bkt", Some("Zed"), true, true);
        p.ensure_relay_entry(&"3".repeat(64), Some("Gone"), false, true);
        p.relay_entries.get_mut(&"3".repeat(64)).unwrap().active = false;
        p.relays.insert(DEFAULT_CIRCLE.into(), vec![R1.into(), "s3:bkt".into()]);
    }
    let names: Vec<_> = e.relays_detail().into_iter().map(|d| d.name).collect();
    assert_eq!(names, vec!["Alpha", "beta", "Zed", "Gone"], "active first, case-insensitive by name");
    let dests = e.media_dests(DEFAULT_CIRCLE);
    assert!(dests.contains(&R1.to_string()) && dests.contains(&R2.to_string()), "media is mirrored to relays beyond the circle's own");
    assert!(!dests.iter().any(|h| h.starts_with("s3:")), "S3 pseudo-relays are not iroh media destinations");
    assert!(!dests.contains(&"3".repeat(64)), "and inactive ones are skipped");
    assert!(e.relay_available(R1));
    e.mark_relay_ok(R1);
    e.mark_relay_fail(R1);
    assert!(e.relay_available(R1) || !e.relay_available(R1), "health bookkeeping does not panic");
}

// ── relay announcements between two members ─────────────────────────────────────────────────────

/// Two befriended engines that can open each other's circle media (keys exchanged both ways).
fn pair(a_seed: u8, b_seed: u8) -> (Arc<Engine>, Arc<Engine>) {
    let (a, _) = new_engine(a_seed);
    let (b, _) = new_engine(b_seed);
    befriend(&a, &b);
    a.post(DEFAULT_CIRCLE.into(), "from a".into(), vec![], None, false, None);
    b.post(DEFAULT_CIRCLE.into(), "from b".into(), vec![], None, false, None);
    deliver(&a, &b, DEFAULT_CIRCLE);
    deliver(&b, &a, DEFAULT_CIRCLE);
    (a, b)
}

/// The frame-19 payload `from` would send for relay `hex` on the default circle.
fn announce_frame(from: &Arc<Engine>, hex: &str) -> Vec<u8> {
    let sealed = from.social.seal_circle_media(DEFAULT_CIRCLE.into(), from.relay_announce_body(hex)).expect("seals");
    wire::event_payload(DEFAULT_CIRCLE, &sealed)
}

#[tokio::test]
async fn a_relay_announce_teaches_a_member_the_relay_and_its_interface() {
    let (a, b) = pair(110, 111);
    // A knows R1 with a full interface and announces it.
    {
        let mut p = a.prefs.lock();
        p.ensure_relay_entry(R1, Some("Home"), false, true);
        p.set_relay_added_at(R1, 0);
        p.set_relay_http(R1, vec!["http://10.0.0.5:8080".into(), "ftp://skip".into()], "tok".into());
        p.set_relay_derp(R1, "https://derp.example/");
        p.set_relay_turn(R1, vec!["turn:t.example:3478".into()], "u", "pw");
    }
    let body = a.relay_announce_body(R1);
    let v: serde_json::Value = serde_json::from_slice(&body).expect("an interface rides as JSON");
    assert_eq!(v["node"], R1);
    assert_eq!(v["token"], "tok");
    assert_eq!(v["turnUser"], "u");
    assert!(v["addedAt"].as_u64().unwrap() > 0, "the adoption stamp always travels");

    let (cid, news) = b.ingest_relay_announce(&announce_frame(&a, R1)).expect("b opens and applies it");
    assert_eq!(cid, DEFAULT_CIRCLE);
    assert!(news, "a relay new to the circle is news");
    {
        let p = b.prefs.lock();
        assert!(p.relays[DEFAULT_CIRCLE].contains(&R1.to_string()));
        let e = &p.relay_entries[R1];
        assert_eq!(e.http_urls, vec!["http://10.0.0.5:8080".to_string()], "only http(s) urls");
        assert_eq!(e.http_token, "tok");
        assert_eq!(e.derp_url, "https://derp.example");
        assert_eq!((e.turn_urls.clone(), e.turn_user.as_str(), e.turn_pass.as_str()), (vec!["turn:t.example:3478".to_string()], "u", "pw"));
    }
    // The same announce again changes nothing, so it must not trigger another backfill.
    let (_, again) = b.ingest_relay_announce(&announce_frame(&a, R1)).unwrap();
    assert!(!again, "a re-announce of an unchanged relay is not news");
    // A changed interface is news again.
    a.prefs.lock().set_relay_http(R1, vec!["http://10.0.0.6:8080".into()], "tok2".into());
    assert!(b.ingest_relay_announce(&announce_frame(&a, R1)).unwrap().1);
    // A bare-hex (legacy) announce is understood.
    a.prefs.lock().ensure_relay_entry(R2, None, false, true);
    let legacy = {
        let sealed = a.social.seal_circle_media(DEFAULT_CIRCLE.into(), R2.as_bytes().to_vec()).unwrap();
        wire::event_payload(DEFAULT_CIRCLE, &sealed)
    };
    assert!(b.ingest_relay_announce(&legacy).unwrap().1);
    assert!(b.prefs.lock().relays[DEFAULT_CIRCLE].contains(&R2.to_string()));
    haven_net::apply_derp_urls(vec![]);
}

#[tokio::test]
async fn malformed_or_foreign_relay_announces_are_dropped() {
    let (a, b) = pair(112, 113);
    let (stranger, _) = new_engine(114);
    assert!(b.ingest_relay_announce(&[]).is_none());
    assert!(b.ingest_relay_announce(&wire::event_payload(DEFAULT_CIRCLE, &[])).is_none(), "empty sealed body");
    assert!(b.ingest_relay_announce(&wire::event_payload("", b"x")).is_none(), "no circle id");
    // Sealed by someone who is not in the circle: cannot be opened.
    let foreign = {
        stranger.social.create_circle(DEFAULT_CIRCLE.into(), "x".into());
        let sealed = stranger.social.seal_circle_media(DEFAULT_CIRCLE.into(), R1.as_bytes().to_vec()).unwrap();
        wire::event_payload(DEFAULT_CIRCLE, &sealed)
    };
    assert!(b.ingest_relay_announce(&foreign).is_none());
    // Valid envelope, but the node id is the wrong length / the JSON is broken.
    for payload in [b"short".to_vec(), b"{ broken".to_vec(), br#"{"node":"abc"}"#.to_vec()] {
        let sealed = a.social.seal_circle_media(DEFAULT_CIRCLE.into(), payload).unwrap();
        assert!(b.ingest_relay_announce(&wire::event_payload(DEFAULT_CIRCLE, &sealed)).is_none());
    }
    assert!(b.relays_detail().is_empty(), "nothing was adopted from any of them");
}

#[tokio::test]
async fn a_deleted_relay_comes_back_only_for_a_newer_re_add_or_its_owner() {
    let (a, b) = pair(115, 116);
    a.prefs.lock().ensure_relay_entry(R1, None, false, true);
    a.prefs.lock().set_relay_added_at(R1, 0);
    // B adopted R1, then deliberately deleted it.
    b.ingest_relay_announce(&announce_frame(&a, R1)).unwrap();
    b.forget_relay(R1.into()).await;
    let forgotten_at = b.prefs.lock().relay_forgotten_at_ms(R1);
    assert!(forgotten_at > 0);

    // A's announce carries its ORIGINAL (older) adoption time: a stale echo loses.
    a.prefs.lock().relay_entries.get_mut(R1).unwrap().added_at_ms = forgotten_at - 1;
    assert!(b.ingest_relay_announce(&announce_frame(&a, R1)).is_none(), "an older announce cannot resurrect a deleted relay");
    assert!(!b.prefs.lock().relay_is_active(R1));

    // A genuine re-add stamped AFTER the deletion wins and syncs as a re-add.
    a.prefs.lock().relay_entries.get_mut(R1).unwrap().added_at_ms = forgotten_at + 5_000;
    let (_, news) = b.ingest_relay_announce(&announce_frame(&a, R1)).expect("newer re-add applies");
    assert!(news);
    assert!(b.prefs.lock().relay_is_active(R1));
    assert!(b.prefs.lock().relay_cleared_forget_ms(R1) > 0);
}

#[tokio::test]
async fn a_merely_deactivated_relay_is_reactivated_by_its_owner_but_not_by_a_third_party() {
    let (a, b) = pair(117, 118);
    let owner_node = a.node_id_hex();                                  // A announces its OWN node as the relay
    a.prefs.lock().ensure_relay_entry(&owner_node, None, false, true);
    a.prefs.lock().relay_entries.get_mut(&owner_node).unwrap().added_at_ms = 0;
    b.prefs.lock().ensure_relay_entry(&owner_node, None, false, true);
    b.prefs.lock().relay_entries.get_mut(&owner_node).unwrap().active = false;
    let (_, news) = b.ingest_relay_announce(&announce_frame(&a, &owner_node)).expect("the relay's owner may bring it back");
    assert!(news && b.prefs.lock().relay_is_active(&owner_node));

    // A third party announcing someone else's relay does not revive it.
    b.prefs.lock().ensure_relay_entry(R1, None, false, true);
    b.prefs.lock().relay_entries.get_mut(R1).unwrap().active = false;
    a.prefs.lock().ensure_relay_entry(R1, None, false, true);
    a.prefs.lock().relay_entries.get_mut(R1).unwrap().added_at_ms = 0;
    assert!(b.ingest_relay_announce(&announce_frame(&a, R1)).is_none(), "a legacy third-party echo of an inactive relay is ignored");
    assert!(!b.prefs.lock().relay_is_active(R1));
}

#[tokio::test]
async fn handle_relay_node_applies_a_live_announce_and_ignores_junk() {
    let (a, b) = pair(119, 120);
    a.prefs.lock().ensure_relay_entry(R1, None, false, true);
    b.handle_relay_node(b"junk").await;
    assert!(b.relays_detail().is_empty());
    let frame = announce_frame(&a, R1);
    b.handle_relay_node(&frame).await;
    assert_eq!(b.relays_detail().len(), 1, "the live frame adopts the relay");
    b.handle_relay_node(&frame).await;                                  // an unchanged re-announce is a no-op
    assert_eq!(b.relays_detail().len(), 1);
}

// ── pins, kept stories, evicted set ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn pinning_dedupes_skips_synthetic_refs_and_unpins_exactly() {
    let (e, _) = new_engine(97);
    e.pin_media(vec!["img_a".into(), "img_a".into(), "geo:1,2,x".into(), "img_b".into()]);
    assert_eq!(e.pinned_count(), 2);
    assert!(e.is_pinned("img_a") && !e.is_pinned("img_zzz"));
    e.unpin_media(vec!["img_a".into()]);
    assert_eq!(e.pinned_count(), 1);
    assert!(!e.is_pinned("img_a"));
}

#[tokio::test]
async fn keeping_a_story_pins_its_media_until_the_last_holder_is_released() {
    let (e, _) = new_engine(98);
    assert!(e.kept_stories_payload().is_none(), "nothing to say, nothing published");
    e.keep_story(story("s1", &["img_x", "img_shared"]));
    e.keep_story(story("s1", &["img_ignored"]));      // keeping twice is a no-op
    e.keep_story(story("s2", &["img_shared"]));
    assert_eq!(e.kept_stories().len(), 2);
    assert!(e.is_story_kept("s1") && e.is_story_kept("s2"));
    assert!(e.kept_stories().iter().all(|k| k.kept_at.is_some()), "kept_at is stamped for the LWW merge");
    assert!(e.is_pinned("img_x") && e.is_pinned("img_shared") && !e.is_pinned("img_ignored"));
    let wire: crate::store::KeptStoriesWire = serde_json::from_slice(&e.kept_stories_payload().unwrap()).unwrap();
    assert_eq!(wire.kept.len(), 2);

    e.unkeep_story("s1");
    assert!(!e.is_story_kept("s1"));
    assert!(!e.is_pinned("img_x"), "released");
    assert!(e.is_pinned("img_shared"), "still needed by s2");
    assert!(e.prefs.lock().kept_stories_removed.contains_key("s1"), "a tombstone for the sync");
    e.unkeep_story("nope");
    e.unkeep_story("s2");
    assert!(!e.is_pinned("img_shared"));
    assert!(e.kept_stories_payload().is_some(), "tombstones alone are still worth publishing");
    e.keep_story(story("s1", &["img_x"]));
    assert!(!e.prefs.lock().kept_stories_removed.contains_key("s1"), "re-keeping clears the tombstone");
}

#[tokio::test]
async fn evicted_refs_resolve_by_ref_or_storage_name() {
    let (e, _) = new_engine(99);
    assert!(!e.evicted_contains("img_abc") && e.evicted_size("img_abc").is_none());
    e.mark_evicted("abc", 1234);
    assert!(e.evicted_contains("img_abc"), "an event ref finds an eviction recorded under the bare name");
    assert_eq!(e.evicted_size("img_abc"), Some(1234));
    e.clear_evicted("img_abc");
    assert!(!e.evicted_contains("abc"));
    for i in 0..8_001 {
        e.mark_evicted(&format!("r{i}"), 1);
    }
    assert!(e.prefs.lock().evicted_media.len() <= 4_001, "the set is bounded");
}

// ── local media, limits and cleanup ─────────────────────────────────────────────────────────────

fn age_all(e: &Arc<Engine>, secs: u64) {
    for entry in std::fs::read_dir(e.paths().media_dir()).unwrap().flatten() {
        let f = std::fs::OpenOptions::new().write(true).open(entry.path()).unwrap();
        f.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(secs)).unwrap();
    }
}

#[tokio::test]
async fn local_media_round_trips_and_is_typed_by_kind() {
    let (e, paths) = new_engine(100);
    let img = e.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF image bytes", false);
    let vid = e.add_local_media(DEFAULT_CIRCLE, b"video bytes", true);
    let aud = e.add_local_audio(DEFAULT_CIRCLE, b"OggS audio");
    let file = e.add_local_file(DEFAULT_CIRCLE, b"PK file");
    assert!(img.starts_with("img_") && vid.starts_with("vid_") && aud.starts_with("aud_") && file.starts_with("file_"));
    assert_eq!(e.media_bytes(DEFAULT_CIRCLE, &img).unwrap(), b"\xFF\xD8\xFF image bytes");
    assert!(e.media_bytes(DEFAULT_CIRCLE, "img_missing").is_none());
    assert!(e.media_present(&img) && !e.media_present("img_missing"));
    assert!(e.media_present("geo:1,2,x"), "synthetic refs are vacuously present");

    // From a file on disk (the off-heap path).
    let src = paths.root.join("clip.mp4");
    std::fs::write(&src, b"a big clip").unwrap();
    let from_file = e.add_local_media_file(DEFAULT_CIRCLE, src.to_str().unwrap(), true).expect("stored");
    assert!(from_file.starts_with("vid_"));
    assert_eq!(e.media_bytes(DEFAULT_CIRCLE, &from_file).unwrap(), b"a big clip");
    assert!(e.add_local_media_file(DEFAULT_CIRCLE, "/no/such/file.mp4", true).is_none());
}

#[tokio::test]
async fn unreferenced_media_is_swept_only_after_its_grace_window_and_pins_are_exempt() {
    let (e, _) = new_engine(101);
    let keep = e.add_local_media(DEFAULT_CIRCLE, b"pinned bytes", false);
    let drop = e.add_local_media(DEFAULT_CIRCLE, b"orphan bytes!", false);
    let used = e.add_local_media(DEFAULT_CIRCLE, b"used by a post", false);
    e.post(DEFAULT_CIRCLE.into(), "has media".into(), vec![used.clone()], None, false, None);
    e.pin_media(vec![keep.clone()]);
    assert_eq!(e.cleanup_unused_media().1, 0, "everything is inside the 48 h grace window");
    age_all(&e, 72 * 3600);
    let (bytes, files) = e.cleanup_unused_media();
    assert_eq!(files, 1, "only the orphan goes");
    assert!(bytes > 0);
    assert!(e.media_present(&keep) && e.media_present(&used) && !e.media_present(&drop));
}

#[tokio::test]
async fn deleting_selected_media_marks_referenced_blobs_as_evicted_placeholders() {
    let (e, _) = new_engine(102);
    let used = e.add_local_media(DEFAULT_CIRCLE, b"referenced bytes", false);
    let orphan = e.add_local_media(DEFAULT_CIRCLE, b"orphan", false);
    let pinned = e.add_local_media(DEFAULT_CIRCLE, b"pinned one", false);
    e.post(DEFAULT_CIRCLE.into(), "p".into(), vec![used.clone()], None, false, None);
    e.pin_media(vec![pinned.clone()]);
    let freed = e.media_delete_selected(vec![used.clone(), orphan.clone(), pinned.clone()]);
    assert!(freed > 0);
    assert!(!e.media_present(&used) && !e.media_present(&orphan));
    assert!(e.media_present(&pinned), "Keep on this device is honoured");
    assert!(e.evicted_contains(&used), "a still-referenced blob becomes a re-downloadable placeholder");
    assert!(!e.evicted_contains(&orphan), "a pure orphan just goes");
}

#[tokio::test]
async fn the_media_inventory_joins_blobs_to_their_posts_and_labels_the_rest() {
    let (e, _) = new_engine(103);
    let in_post = e.add_local_media(DEFAULT_CIRCLE, b"in a post, long enough to sort first", false);
    let orphan = e.add_local_media(DEFAULT_CIRCLE, b"x", false);
    let scheduled = e.add_local_media(DEFAULT_CIRCLE, b"waiting to send", false);
    e.post(DEFAULT_CIRCLE.into(), "beach day".into(), vec![in_post.clone()], None, false, None);
    e.schedule(crate::scheduled::SchedKind::Post, DEFAULT_CIRCLE.into(), "later".into(), vec![scheduled.clone()], None, false, now_ms() + 1_000_000);
    let rows = e.media_inventory();
    assert_eq!(rows.len(), 3);
    assert!(rows.windows(2).all(|w| w[0].bytes >= w[1].bytes), "largest first");
    let row = |r: &str| rows.iter().find(|x| x.reference == crate::localmedia::LocalMedia::storage_name(r)).unwrap();
    assert_eq!(row(&in_post).snippet.as_deref(), Some("beach day"));
    assert!(!row(&in_post).is_orphan);
    assert!(row(&orphan).is_orphan && row(&orphan).circle_name == "Unused");
    assert_eq!(row(&scheduled).circle_name, "Scheduled to send");
    assert!(!row(&scheduled).is_orphan, "a queued send still needs it");
}

#[tokio::test]
async fn local_limits_evict_old_media_but_never_pinned_and_record_referenced_ones_as_placeholders() {
    let (e, _) = new_engine(104);
    assert_eq!(e.get_media_limits(), (0, 0));
    e.enforce_local_limits(true);                         // both caps off: nothing happens
    let old = e.add_local_media(DEFAULT_CIRCLE, b"old and unused", false);
    let pinned = e.add_local_media(DEFAULT_CIRCLE, b"old but pinned", false);
    let used = e.add_local_media(DEFAULT_CIRCLE, b"old but in a post", false);
    e.post(DEFAULT_CIRCLE.into(), "p".into(), vec![used.clone()], None, false, None);
    e.pin_media(vec![pinned.clone()]);
    age_all(&e, 90 * 24 * 3600);
    e.set_media_limits(30, 0);                            // enforces immediately, off-thread
    assert_eq!(e.get_media_limits(), (30, 0));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while e.media_present(&old) || e.dyn_state.lock().limit_sweep_in_flight {
        assert!(std::time::Instant::now() < deadline, "limit sweep never finished");
        std::thread::yield_now();
    }
    assert!(e.media_present(&pinned), "Keep on this device is exempt from the age cap");
    // Unlike the orphan sweep, a blob a live post references IS eligible: it becomes a re-downloadable
    // placeholder, recorded as evicted so the missing-media sweep does not silently refetch it.
    wait_until("the referenced blob to be recorded as evicted", || e.evicted_contains(&used));
    assert!(!e.media_present(&used));
    assert!(!e.evicted_contains(&old), "a pure orphan just goes");
}

// ── re-optimize ─────────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn reoptimize_finds_only_my_oversized_stills_and_counts_the_videos_it_leaves_alone() {
    let (e, _) = new_engine(105);
    let big = e.add_local_media(DEFAULT_CIRCLE, &fake_jpeg(4000, 3000, 400_000), false);
    let small = e.add_local_media(DEFAULT_CIRCLE, &fake_jpeg(800, 600, 60_000), false);
    let video = e.add_local_media(DEFAULT_CIRCLE, &vec![7u8; 300_000], true);
    e.post(DEFAULT_CIRCLE.into(), "mine".into(), vec![big.clone(), small.clone(), video.clone(), "geo:1,2,x".into()], None, false, None);
    e.post_story(DEFAULT_CIRCLE.into(), "story".into(), Some(e.add_local_media(DEFAULT_CIRCLE, &fake_jpeg(5000, 4000, 500_000), false)), None);

    let targets = e.reoptimize_targets();
    assert_eq!(targets.len(), 1, "stories are never re-optimized");
    assert_eq!(targets[0].media.len(), 4);

    let scan = e.reoptimize_scan();
    assert_eq!(scan.candidates.len(), 1, "only the oversized still");
    assert_eq!(scan.candidates[0].reference, big);
    assert_eq!((scan.candidates[0].width, scan.candidates[0].height), (4000, 3000));
    assert!(!scan.candidates[0].reason.is_empty());
    assert_eq!(scan.videos_above_target, 1, "large video is counted, never offered");
    assert!(scan.video_bytes >= 300_000);
}

#[tokio::test]
async fn a_reencode_is_adopted_only_when_it_is_a_clear_win_and_the_post_is_edited_in_place() {
    let (e, _) = new_engine(106);
    let big = e.add_local_media(DEFAULT_CIRCLE, &fake_jpeg(4000, 3000, 400_000), false);
    e.post(DEFAULT_CIRCLE.into(), "mine".into(), vec![big.clone(), "geo:1,2,x".into()], None, false, None);
    let event = e.reoptimize_targets()[0].event_id.clone();

    // Not smaller: rejected and remembered, so it is never offered again.
    assert!(e.reoptimize_accept(DEFAULT_CIRCLE.into(), big.clone(), fake_jpeg(1600, 1200, 399_000)).is_none());
    assert!(e.prefs.lock().reoptimize_skipped.contains(&big));
    // Unreadable output is rejected too.
    assert!(e.reoptimize_accept(DEFAULT_CIRCLE.into(), big.clone(), b"not an image".to_vec()).is_none());
    // A ref whose bytes are gone cannot be judged.
    assert!(e.reoptimize_accept(DEFAULT_CIRCLE.into(), "img_gone".into(), fake_jpeg(10, 10, 300)).is_none());

    let new_ref = e.reoptimize_accept(DEFAULT_CIRCLE.into(), big.clone(), fake_jpeg(1600, 1200, 150_000)).expect("clear win");
    assert_ne!(new_ref, big);
    assert!(e.media_present(&new_ref));

    // Re-point the post: same length and order, synthetic entries byte-identical.
    assert!(!e.reoptimize_apply(DEFAULT_CIRCLE.into(), event.clone(), vec![new_ref.clone()]), "wrong length is refused");
    assert!(!e.reoptimize_apply(DEFAULT_CIRCLE.into(), event.clone(), vec![new_ref.clone(), "geo:9,9,tampered".into()]), "a geo pin must not change");
    assert!(!e.reoptimize_apply(DEFAULT_CIRCLE.into(), "no-such-event".into(), vec![new_ref.clone(), "geo:1,2,x".into()]));
    assert!(e.reoptimize_apply(DEFAULT_CIRCLE.into(), event, vec![new_ref.clone(), "geo:1,2,x".into()]));
    let post = e.feed(DEFAULT_CIRCLE).into_iter().find(|i| i.body == "mine").unwrap();
    assert_eq!(post.media, vec![new_ref, "geo:1,2,x".to_string()]);
    assert!(post.edited);
    assert!(e.media_present(&big), "the old blob is kept for members who are offline");
    assert!(e.reoptimize_has_headroom(1));
    assert!(!e.reoptimize_has_headroom(u64::MAX / 2), "an impossible request is refused");
}

// ── inbound frames ──────────────────────────────────────────────────────────────────────────────

fn wait_until(what: &str, done: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !done() {
        assert!(std::time::Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::yield_now();
    }
}

/// A frame-relay envelope: 16-byte id, ttl, destinations (32 bytes each), then the inner frame.
fn relay_envelope(id: [u8; 16], ttl: u8, dests: &[String], inner: &[u8]) -> Vec<u8> {
    let mut v = id.to_vec();
    v.push(ttl);
    v.push(dests.len() as u8);
    for d in dests {
        v.extend(hex_to_bytes32(d).expect("32-byte destination"));
    }
    v.extend_from_slice(inner);
    v
}

#[tokio::test]
async fn a_relayed_frame_addressed_to_me_is_delivered_once() {
    let (a, b) = pair(121, 122);
    a.post(DEFAULT_CIRCLE.into(), "relayed hello".into(), vec![], None, false, None);
    // Everything A now holds, each as its own relayed frame; B has the circle's keys from `pair` but not these events.
    let frames: Vec<Vec<u8>> = a
        .social
        .sync_envelopes(DEFAULT_CIRCLE.to_string())
        .iter()
        .map(|env| {
            let mut inner = vec![wire::EVENT];
            inner.extend(wire::event_payload(DEFAULT_CIRCLE, env));
            inner
        })
        .collect();
    assert!(!b.feed(DEFAULT_CIRCLE).iter().any(|i| i.body == "relayed hello"), "not delivered yet");
    let relayed: Vec<Vec<u8>> = frames
        .iter()
        .enumerate()
        .map(|(i, inner)| relay_envelope([i as u8 + 1; 16], 0, &[b.node_id_hex()], inner))
        .collect();
    b.handle_relay(&[1, 2, 3]);                                          // too short: ignored
    for r in &relayed {
        b.handle_relay(r);
    }
    b.handle_relay(&relayed[0]);                                         // same id: de-duplicated
    wait_until("the relayed event", || b.feed(DEFAULT_CIRCLE).iter().any(|i| i.body == "relayed hello"));
    assert_eq!(b.seen_relay.lock().len(), relayed.len(), "each distinct id remembered once");
    let inner = frames[0].clone();

    // Not addressed to me, wrong length, empty inner: all dropped without effect.
    let other = relay_envelope([8u8; 16], 3, &[a.node_id_hex()], &inner);
    b.handle_relay(&other);
    let bad_len = { let mut v = vec![7u8; 16]; v.push(0); v.push(5); v };
    b.handle_relay(&bad_len);
    let empty_inner = relay_envelope([6u8; 16], 0, &[b.node_id_hex()], &[]);
    b.handle_relay(&empty_inner);
}

#[tokio::test]
async fn inbound_dispatch_ignores_empty_blocked_and_unknown_frames() {
    let (a, b) = pair(123, 124);
    b.dispatch(Vec::new());                                              // empty payload
    b.dispatch(vec![250, 1, 2, 3]);                                      // unknown frame type
    // A MEDIA_REQ from a blocked sender is dropped before any task is spawned.
    b.block(a.node_id_hex());
    let mut body = a.node_id_hex().into_bytes();
    body.extend_from_slice(b"rest");
    let mut payload = vec![wire::MEDIA_REQ];
    payload.extend(&body);
    b.dispatch(payload);
    // A garbage EVENT/HELLO is parsed and rejected quietly.
    b.dispatch(vec![wire::EVENT, 0xFF]);
    b.dispatch(vec![wire::HELLO, 0xFF]);
    b.dispatch_from(Some("not-a-device".into()), vec![wire::HELLO]);
    b.handle_event(b"garbage", None);
    b.handle_hello(b"garbage");
    wait_until("the runtime to drain the dispatches", || b.dyn_state.lock().internet_active);
    assert!(b.contacts().is_empty() || b.blocked().contains(&a.node_id_hex()));
}

// ── invite links: device hints and offline friend tickets ───────────────────────────────────────

#[tokio::test]
async fn invite_hints_ride_before_the_fragment_and_only_64_hex_ids_survive() {
    let (e, _) = new_engine(130);
    let link = e.embed_invite_hints("https://haven.is/open/#abc.def".into());
    assert!(link.contains("?d="), "{link}");
    assert!(link.ends_with("#abc.def"), "the fragment stays last so old parsers keep working");
    let hints = Engine::extract_invite_hints(&link);
    assert_eq!(hints, vec![e.social.my_device_node_hex().to_lowercase()]);
    // A link that already carries a query, or has no fragment, is left alone.
    assert_eq!(e.embed_invite_hints("https://x/?a=1#f".into()), "https://x/?a=1#f");
    assert_eq!(e.embed_invite_hints("https://x/nofragment".into()), "https://x/nofragment");

    let good = "ab".repeat(32);
    let messy = format!("https://x/?d={good},nothex,{},{}&t=1#frag", "zz".repeat(32), good.to_uppercase());
    assert_eq!(Engine::extract_invite_hints(&messy), vec![good.clone(), good.clone()], "case-folded, junk dropped");
    assert!(Engine::extract_invite_hints("https://x/#frag?d=ab").is_empty(), "a ? after the # is not a query");
    assert!(Engine::extract_invite_hints("https://x/?q=1#f").is_empty());
    assert!(Engine::extract_invite_hints("no link").is_empty());
}

#[tokio::test]
async fn device_hints_are_remembered_deduped_and_bounded() {
    let (e, _) = new_engine(131);
    let acct = "ab".repeat(32);
    assert!(e.device_hints_for(&acct).is_empty());
    e.record_device_hints(&acct, vec![]);
    assert!(e.device_hints_for(&acct).is_empty());
    let ids: Vec<String> = (0..10u8).map(|i| format!("{i:02x}").repeat(32)).collect();
    e.record_device_hints(&acct.to_uppercase(), ids[..3].to_vec());
    e.record_device_hints(&acct, ids[..3].to_vec());
    assert_eq!(e.device_hints_for(&acct).len(), 3, "keyed case-insensitively, no duplicates");
    e.record_device_hints(&acct, ids.clone());
    let hints = e.device_hints_for(&acct);
    assert_eq!(hints.len(), 8, "only the newest eight are kept");
    assert_eq!(hints.last(), ids.last());
    e.forgive_dials(&acct, Some("cc")); // no node: inert
}

#[tokio::test]
async fn friend_ticket_links_mint_once_embed_and_are_accepted_by_the_other_side() {
    let (a, _) = new_engine(132);
    let (b, _) = new_engine(133);
    // No relay: the link stays live-only, with no ticket.
    assert!(a.friend_invite_link_value().is_none());
    assert!(!a.invite_uri().contains("t="));

    a.prefs.lock().relays.insert(DEFAULT_CIRCLE.into(), vec![R1.into()]);
    a.prefs.lock().ensure_relay_entry(R1, None, false, true);
    let uri = a.invite_uri();
    let t = Engine::friend_invite_extract(&uri).expect("a ticket rides on the link once a relay exists");
    assert_eq!(a.invite_uri().matches("t=").count(), 1);
    assert_eq!(Engine::friend_invite_extract(&a.invite_uri()), Some(t.clone()), "the live ticket is reused");
    assert_eq!(a.prefs.lock().friend_invites_issued.len(), 1);
    assert!(a.invite_link("haven.is").contains(&format!("t={t}")), "and the web form carries it too");

    assert_eq!(Engine::friend_invite_extract("https://x/#f"), None);
    assert_eq!(Engine::friend_invite_extract("https://x/?t=#f"), None, "an empty value is no ticket");
    assert_eq!(Engine::friend_invite_extract("https://x/#f?t=abc"), None);

    // B scans the link: connecting persists the acceptance exactly once.
    assert!(b.connect_by_link(uri.clone()));
    assert!(b.connect_by_link(uri));
    assert_eq!(b.prefs.lock().friend_invites_accepted.len(), 1);
    b.friend_invite_accept("garbage"); // an unparseable ticket is ignored
    assert_eq!(b.prefs.lock().friend_invites_accepted.len(), 1);
}

#[tokio::test]
async fn expired_and_surplus_tickets_are_pruned_but_consumed_ones_are_kept() {
    let (a, _) = new_engine(134);
    {
        let mut p = a.prefs.lock();
        let ttl = haven_p2p::friend_invite::DEFAULT_TTL_SECS;
        let now = friend_invite_now();
        let mk = |issued_at: u64, consumed_at: u64| crate::store::IssuedFriendInvite { ticket: format!("t{issued_at}-{consumed_at}"), issued_at, consumed_at, acceptor_hex: String::new() };
        p.friend_invites_issued.push(mk(now - ttl - 10, 0));       // expired, unconsumed: dropped
        p.friend_invites_issued.push(mk(now - ttl - 10, now - 5)); // expired but consumed: kept (approve→grant join key)
        for i in 0..20 {
            p.friend_invites_issued.push(mk(now - i, 0));
        }
        p.friend_invites_accepted.push(crate::store::AcceptedFriendInvite { ticket: "old".into(), accepted_at: now - ttl - 10, drop_landed: false, granted: false });
        p.friend_invites_accepted.push(crate::store::AcceptedFriendInvite { ticket: "done".into(), accepted_at: now, drop_landed: true, granted: true });
        p.friend_invites_accepted.push(crate::store::AcceptedFriendInvite { ticket: "live".into(), accepted_at: now, drop_landed: false, granted: false });
    }
    a.friend_invite_prune();
    let p = a.prefs.lock();
    assert_eq!(p.friend_invites_issued.iter().filter(|i| i.consumed_at == 0).count(), 16, "at most sixteen live tickets");
    assert_eq!(p.friend_invites_issued.iter().filter(|i| i.consumed_at != 0).count(), 1);
    let kept: Vec<_> = p.friend_invites_accepted.iter().map(|a| a.ticket.as_str()).collect();
    assert_eq!(kept, vec!["live"], "expired and already-granted acceptances go");
}

#[tokio::test]
async fn hello_bodies_name_their_sender_and_hex_ids_validate() {
    let (a, _) = new_engine(135);
    let hello = a.hello_payload(DEFAULT_CIRCLE).unwrap();
    assert_eq!(friend_invite_hello_sender(&hello), Some(a.node_id_hex().to_lowercase()));
    assert_eq!(friend_invite_hello_sender(&[]), None);
    assert_eq!(friend_invite_hello_sender(&[1, 0, b'x']), None, "truncated after the first field");
    assert_eq!(friend_invite_hello_sender(&hello[..20]), None, "cut off before the bundle");
    assert!(friend_invite_hex32(&"ab".repeat(32)).is_some());
    assert_eq!(friend_invite_hex32("ab"), None);
    assert_eq!(friend_invite_hex32(&"zz".repeat(32)), None);
    assert!(friend_invite_live(friend_invite_now()));
    assert!(!friend_invite_live(0));
}

// ── call frames: sealing, parsing and the contact gate ──────────────────────────────────────────

/// What `to` would hand the webview for a call frame `from` sealed to it, plus the raw verdicts.
fn receive_call(from: &Arc<Engine>, to: &Arc<Engine>, t: u8, body: &[u8]) -> Option<serde_json::Value> {
    let sealed = from.social.seal_call_frame(to.node_id_hex(), t, body.to_vec()).expect("seals to a known contact");
    let (_, opened) = to.open_sealed_frame(t, &sealed)?;
    let ev = to.call_event(t, &opened)?;
    to.call_event_allowed(t, &ev).then_some(ev)
}

#[tokio::test]
async fn call_frames_are_sealed_signed_parsed_and_gated_on_the_contact_list() {
    let (a, b) = pair(140, 141);
    let (stranger, _) = new_engine(142);
    let ah = a.node_id_hex();

    let invite = receive_call(&a, &b, wire::GROUP_INVITE, &callwire::group_invite(&ah, "sess", "Crew", &format!("{ah},{}", b.node_id_hex()), now_ms() / 1000)).expect("a contact's invite reaches the UI");
    assert_eq!(invite["kind"], "groupInvite");
    assert_eq!((invite["sessionId"].as_str(), invite["groupName"].as_str(), invite["from"].as_str()), (Some("sess"), Some("Crew"), Some(ah.as_str())));
    assert_eq!(invite["roster"].as_array().unwrap().len(), 2);

    assert!(receive_call(&a, &b, wire::GROUP_INVITE, &callwire::group_invite(&ah, "old", "Crew", &ah, now_ms() / 1000 - 600)).is_none(), "a replayed invite older than the dial window is dropped");

    let accept = receive_call(&a, &b, wire::CALL_ACCEPT, &callwire::accept(&ah, "sess")).unwrap();
    assert_eq!((accept["kind"].as_str(), accept["sessionId"].as_str()), (Some("accept"), Some("sess")));
    let hangup = receive_call(&a, &b, wire::CALL_HANGUP, &callwire::hangup(&ah, "sess")).unwrap();
    assert_eq!(hangup["kind"], "hangup");
    assert_eq!(receive_call(&a, &b, wire::CALL_CAMERA, &callwire::camera_state(&ah, "sess", true)).unwrap()["on"], true);
    assert_eq!(receive_call(&a, &b, wire::CALL_CAMERA, &callwire::camera_state(&ah, "sess", false)).unwrap()["on"], false);
    for (t, kind) in [(wire::SDP_OFFER, "offer"), (wire::SDP_ANSWER, "answer"), (wire::ICE, "ice")] {
        let ev = receive_call(&a, &b, t, &callwire::signal(&ah, "sess", br#"{"sdp":"x"}"#)).unwrap();
        assert_eq!(ev["kind"], kind);
        assert_eq!(ev["json"], r#"{"sdp":"x"}"#);
    }
    // The legacy 1:1 invite names the caller.
    let mut legacy = ah.clone().into_bytes();
    legacy.extend_from_slice(b"Alice");                                  // the legacy name is the raw tail
    let ev = receive_call(&a, &b, wire::CALL_INVITE, &legacy).unwrap();
    assert_eq!((ev["kind"].as_str(), ev["name"].as_str()), (Some("invite"), Some("Alice")));
    assert_eq!(ev["sessionId"], format!("legacy:{ah}"));

    // Unknown types and malformed bodies parse to nothing.
    assert!(b.call_event(wire::MEDIA_REQ, b"x").is_none());
    assert!(b.call_event(wire::CALL_ACCEPT, b"short").is_none());

    // Frames 30/35 speak for MY account only: a contact cannot silence or end my call.
    assert!(receive_call(&a, &b, wire::CALL_HANDLED, &callwire::handled_elsewhere(&ah, "sess")).is_none());
    assert!(receive_call(&a, &b, wire::CALL_ENDED_ELSEWHERE, &callwire::accept(&ah, "sess")).is_none());
    let bh = b.node_id_hex();
    let own = b.call_event(wire::CALL_HANDLED, &callwire::handled_elsewhere(&bh, "sess")).unwrap();
    assert!(b.call_event_allowed(wire::CALL_HANDLED, &own), "my own account may silence my ring");
    let own35 = b.call_event(wire::CALL_ENDED_ELSEWHERE, &callwire::accept(&bh, "sess")).unwrap();
    assert!(b.call_event_allowed(wire::CALL_ENDED_ELSEWHERE, &own35), "and end an answered call");

    // A stranger who is not a contact is refused at the gate even though the frame opens.
    let fake = serde_json::json!({"kind": "invite", "from": stranger.node_id_hex()});
    assert!(!b.call_event_allowed(wire::CALL_INVITE, &fake));
    assert!(!b.call_event_allowed(wire::CALL_INVITE, &serde_json::json!({"kind": "invite"})), "no sender at all");
}

#[tokio::test]
async fn an_accept_or_hangup_settles_the_dialing_retry_loop_for_its_own_session_only() {
    let (a, b) = pair(143, 144);
    let ah = a.node_id_hex();
    b.dialing.lock().begin("s1");
    receive_call(&a, &b, wire::CALL_ACCEPT, &callwire::accept(&ah, "other"));
    assert!(b.dialing.lock().is_dialing("s1"), "a late frame from another call changes nothing");
    receive_call(&a, &b, wire::CALL_ACCEPT, &callwire::accept(&ah, "s1"));
    assert!(!b.dialing.lock().is_dialing("s1"));
    b.dialing.lock().begin("s2");
    receive_call(&a, &b, wire::CALL_HANGUP, &callwire::hangup(&ah, "s2"));
    assert!(!b.dialing.lock().is_dialing("s2"), "a decline stops the invite too");
}

#[tokio::test]
async fn sealed_call_frames_from_blocked_or_forged_senders_do_not_open() {
    let (a, b) = pair(145, 146);
    let ah = a.node_id_hex();
    let body = callwire::accept(&ah, "s");
    let sealed = a.social.seal_call_frame(b.node_id_hex(), wire::CALL_ACCEPT, body.clone()).unwrap();
    assert!(b.open_sealed_frame(wire::CALL_ACCEPT, &sealed).is_some());
    assert!(b.open_sealed_frame(wire::CALL_HANGUP, &sealed).is_none(), "the frame type is bound into the seal");
    assert!(b.open_sealed_frame(wire::CALL_ACCEPT, b"not sealed at all").is_none());
    // A body that claims to be someone else is refused: the proven signer must equal the declared sender.
    let forged = callwire::accept(&b.node_id_hex(), "s");
    let sealed_forged = a.social.seal_call_frame(b.node_id_hex(), wire::CALL_ACCEPT, forged).unwrap();
    assert!(b.open_sealed_frame(wire::CALL_ACCEPT, &sealed_forged).is_none());
    b.block(ah);
    assert!(b.open_sealed_frame(wire::CALL_ACCEPT, &sealed).is_none(), "blocked senders never reach the UI");
}

#[tokio::test]
async fn without_a_window_call_frames_are_noted_for_qa_and_dropped() {
    let (a, b) = pair(147, 148);
    let sealed = a.social.seal_call_frame(b.node_id_hex(), wire::CALL_ACCEPT, callwire::accept(&a.node_id_hex(), "s")).unwrap();
    b.handle_call(wire::CALL_ACCEPT, &sealed);
    assert_eq!(b.qa_last_call_event(), format!("recv-no-app:{}", wire::CALL_ACCEPT));
    // The call engine's QA surface.
    b.set_qa_call_state(true, false, "sess".into(), "trail".into());
    assert_eq!(b.qa_call_state(), Some((true, false)));
    assert_eq!((b.qa_call_session().as_str(), b.qa_call_trail().as_str()), ("sess", "trail"));
    // Outgoing call plumbing is inert without a node but must not panic.
    let ah = a.node_id_hex();
    b.call_group_invite("s".into(), "G".into(), vec![ah.clone()], vec![ah.clone()]);
    b.call_accept("s".into(), vec![ah.clone()]);
    b.call_hangup(vec![ah.clone()], "s".into());
    b.call_handled_elsewhere("s".into());
    b.call_camera_state("s".into(), true, vec![ah.clone()]);
    b.call_signal("offer".into(), "s".into(), "{}".into(), ah);
    assert!(b.diag_delivery_json().starts_with('{') || b.diag_delivery_json().starts_with('['));
    let _ = b.debug_tree_chain_json();
}

// ── durable ledgers: seen mailbox keys, media backup confirmations, upload progress ─────────────

#[tokio::test]
async fn mailbox_keys_are_content_addressed_per_circle() {
    let k1 = Engine::mailbox_key("c1", b"envelope");
    assert_eq!(k1, Engine::mailbox_key("c1", b"envelope"));
    assert_ne!(k1, Engine::mailbox_key("c2", b"envelope"));
    assert_ne!(k1, Engine::mailbox_key("c1", b"other"));
    assert!(k1.starts_with("haven/mailbox/c1/") && k1.len() == "haven/mailbox/c1/".len() + 64);
}

#[tokio::test]
async fn seen_mailbox_keys_survive_a_relaunch_via_the_append_journal() {
    let (e, paths) = new_engine(150);
    for i in 0..5 {
        e.mark_mailbox_seen(format!("haven/mailbox/c/{i}"));
    }
    e.mark_mailbox_seen("haven/mailbox/c/0".into());                       // a repeat is not journaled twice
    e.flush_seen_mailbox();
    e.mark_mailbox_seen("haven/mailbox/c/5".into());
    e.flush_seen_mailbox();
    let text = std::fs::read_to_string(paths.root.join("mailbox-seen.txt")).unwrap();
    let distinct: std::collections::HashSet<_> = text.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(distinct.len(), 6, "every key is on disk: {text:?}");
    let again = Engine::new(paths, [150u8; 32]).unwrap();
    assert_eq!(again.dyn_state.lock().seen_mailbox.len(), 6);
    assert!(again.dyn_state.lock().seen_mailbox.contains("haven/mailbox/c/5"));
    e.flush_seen_mailbox();                                                 // nothing new: no rewrite, no error
}

#[tokio::test]
async fn the_backup_ledger_answers_where_each_attachment_is_stored() {
    let (e, paths) = new_engine(151);
    e.prefs.lock().relays.insert(DEFAULT_CIRCLE.into(), vec![R1.into()]);
    assert!(!e.media_backed_up_has(R1, "img_a"));
    e.mark_media_backed_up(R1, "img_a");
    e.mark_media_backed_up(R1, "img_b");
    e.mark_media_backed_up(R2, "img_a");
    let rows = e.media_backup_rows(DEFAULT_CIRCLE.into(), vec!["img_a".into(), "img_b".into()]);
    let row = |d: &str| rows.iter().find(|r| r.0 == d).map(|r| r.1);
    assert_eq!(row(R1), Some(2));
    assert_eq!(row(R2), Some(1), "a destination that holds only some is listed with its count");
    // A relay the circle publishes to is listed even when it holds nothing (the case you most need to see).
    e.prefs.lock().relays.insert(DEFAULT_CIRCLE.into(), vec![R1.into(), "3".repeat(64)]);
    let rows = e.media_backup_rows(DEFAULT_CIRCLE.into(), vec!["img_a".into()]);
    assert_eq!(rows.iter().find(|r| r.0 == "3".repeat(64)).unwrap().1, 0);
    assert_eq!(e.own_hosted_relay_hex(), "", "this app hosts no relay");

    e.flush_media_backed_up();
    assert_eq!(std::fs::read_to_string(paths.root.join("media-backed-up.txt")).unwrap().lines().count(), 3);
    assert!(!e.dyn_state.lock().media_backed_up_dirty, "flushed");
    e.flush_media_backed_up();                                              // clean: no write
    e.forget_media_backed_up_ref("img_a");
    assert!(!e.media_backed_up_has(R1, "img_a") && !e.media_backed_up_has(R2, "img_a") && e.media_backed_up_has(R1, "img_b"));
    e.forget_media_backed_up(R1);
    assert!(!e.media_backed_up_has(R1, "img_b"));
    e.flush_media_backed_up_throttled();                                   // may be rate-limited by an earlier flush…
    e.flush_media_backed_up();                                              // …this one is not
    let again = Engine::new(paths, [151u8; 32]).unwrap();
    assert!(again.dyn_state.lock().media_backed_up.is_empty(), "the forgotten confirmations are gone after a relaunch");
}

#[tokio::test]
async fn upload_progress_only_ever_understates_and_is_bounded() {
    let (e, paths) = new_engine(152);
    assert!(e.media_upload_progress(R1, "img_a").is_none());
    e.record_media_upload_progress(R1, "img_a", "fp1", 3);
    assert_eq!(e.media_upload_progress(R1, "img_a"), Some(("fp1".to_string(), 3)));
    e.record_media_upload_progress(R1, "img_a", "fp1", 3);                 // unchanged: no rewrite
    e.record_media_upload_progress(R1, "img_a", "fp2", 1);
    assert_eq!(e.media_upload_progress(R1, "img_a"), Some(("fp2".to_string(), 1)));
    assert_eq!(std::fs::read_to_string(paths.root.join("media-upload-progress.txt")).unwrap(), format!("{R1}|img_a\tfp2:1"));
    e.record_media_upload_progress(R1, "img_a", "", 0);                    // finished: the record is cleared
    assert!(e.media_upload_progress(R1, "img_a").is_none());
    e.record_media_upload_progress(R1, "img_never", "", 0);                // clearing nothing is harmless
    for i in 0..2_050 {
        e.record_media_upload_progress(R1, &format!("img_{i}"), "fp", 1);
    }
    assert!(e.dyn_state.lock().media_upload_progress.len() <= 2_000);
    let again = Engine::new(paths, [152u8; 32]).unwrap();
    assert!(!again.dyn_state.lock().media_upload_progress.is_empty(), "progress is picked back up after a relaunch");
}

#[tokio::test]
async fn http_url_health_backs_off_escalates_and_clears() {
    let (e, _) = new_engine(153);
    let url = "http://10.0.0.5:8080";
    assert!(!e.http_url_bad(url));
    e.mark_http_url_bad(url);
    assert!(e.http_url_bad(url), "a URL that failed is skipped for a window");
    e.clear_http_url_bad(url);
    assert!(!e.http_url_bad(url));
    assert_eq!(Engine::http_key_url("http://h:1/", "haven/media/x"), "http://h:1/k/haven/media/x");
    assert_eq!(Engine::http_list_url("http://h:1/", "haven/mailbox/c d/?x#y%"), "http://h:1/l/haven%2Fmailbox%2Fc%20d%2F%3Fx%23y%25");
    assert!(e.http_auth("tok", "GET", "haven/media/x", b"").is_some(), "requests are signed with the device key");
}

#[tokio::test]
async fn the_app_activity_log_is_persisted_bounded_and_reloaded() {
    let (e, paths) = new_engine(154);
    e.append_app_activity("Media is back", "tap to view", Some("haven://p/default/abc"));
    e.append_app_activity("Second", "row", None);
    let rows = e.activity();
    let app_rows: Vec<_> = rows.iter().filter(|r| r.kind == "app").collect();
    assert_eq!(app_rows.len(), 2);
    assert_eq!(app_rows[0].link.as_deref(), None, "newest first: the second row has no link");
    assert!(paths.root.join("activity-app.json").exists());
    let again = Engine::new(paths, [154u8; 32]).unwrap();
    assert_eq!(again.activity().iter().filter(|r| r.kind == "app").count(), 2, "rows survive a relaunch");
    for i in 0..250 {
        again.append_app_activity(&format!("t{i}"), "b", None);
    }
    assert!(again.activity().len() <= 200, "capped");
    // A deep-linked notification is also an activity row; a plain one in the foreground is not.
    again.set_foreground(true);
    again.notify_with_link("Hi", "there", Some("haven://c/default"));
    again.notify_with_link("Plain", "x", None);
    let titles: Vec<_> = again.activity().into_iter().map(|r| r.actor_name).collect();
    assert!(titles.contains(&"Hi".to_string()));
    assert!(!titles.contains(&"Plain".to_string()));
}

// ── history paging and import dedupe ────────────────────────────────────────────────────────────

#[tokio::test]
async fn an_archive_imported_twice_is_repaired_keeping_the_first_copy() {
    let (e, _) = new_engine(155);
    let t = 1_500_000_000_000;
    // The second import re-encoded the photo, so the media hash differs but the capture time,
    // caption and item count are what an import cannot change.
    e.post_imported(DEFAULT_CIRCLE.into(), "Beach  Day".into(), vec!["img_first".into()], None, false, t);
    e.post_imported(DEFAULT_CIRCLE.into(), "beach day".into(), vec!["img_second".into()], None, false, t);
    e.post_imported(DEFAULT_CIRCLE.into(), "different".into(), vec!["img_third".into()], None, false, t);
    // Text-only repeats may be deliberate and are never merged.
    e.post_imported(DEFAULT_CIRCLE.into(), "hello".into(), vec![], None, false, t + 1);
    e.post_imported(DEFAULT_CIRCLE.into(), "hello!".into(), vec![], None, false, t + 1);
    assert_eq!(e.feed(DEFAULT_CIRCLE).len(), 5);
    assert_eq!(e.sweep_duplicate_imports(DEFAULT_CIRCLE), 1, "exactly one duplicate is withdrawn");
    let feed = e.feed(DEFAULT_CIRCLE);
    assert_eq!(feed.iter().filter(|i| !i.unsent).count(), 4);
    assert_eq!(e.sweep_duplicate_imports(DEFAULT_CIRCLE), 0, "idempotent");
}

#[tokio::test]
async fn older_history_is_requested_once_per_cursor_and_served_to_members_only() {
    let (a, b) = pair(156, 157);
    a.request_older_history(DEFAULT_CIRCLE.into(), 0);                       // nothing held yet: nothing to ask
    assert!(a.history_asked_before.lock().is_empty());
    a.request_older_history(DEFAULT_CIRCLE.into(), 5_000);
    a.request_older_history(DEFAULT_CIRCLE.into(), 5_000);                   // same cursor: not asked again
    assert_eq!(a.history_asked_before.lock().get(DEFAULT_CIRCLE), Some(&5_000));
    a.request_older_history(DEFAULT_CIRCLE.into(), 3_000);                   // an older page arrived and moved it
    assert_eq!(a.history_asked_before.lock().get(DEFAULT_CIRCLE), Some(&3_000));

    // Serving: a request from a contact is answered (no node here, so nothing leaves); a stranger's is ignored.
    let req = wire::history_req_payload(&a.node_id_hex(), u64::MAX / 2, DEFAULT_CIRCLE);
    b.handle_history_request(&req);
    b.handle_history_request(&wire::history_req_payload(&"ee".repeat(32), 1, DEFAULT_CIRCLE));
    b.handle_history_request(b"garbage");
}

// ── direct media transfer: chunk reassembly ─────────────────────────────────────────────────────

fn content_ref(prefix: &str, data: &[u8]) -> String {
    let hex: String = Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect();
    format!("{prefix}{hex}")
}

fn seal_chunk(from: &Arc<Engine>, to: &Arc<Engine>, reference: &str, index: u32, total: u32, plain: &[u8]) -> Vec<u8> {
    let sealed = from.social.seal_media(to.node_id_hex(), plain.to_vec()).expect("seals to a contact");
    wire::chunk_frame(reference.as_bytes(), index, total, &sealed)
}

#[tokio::test]
async fn chunks_arriving_out_of_order_reassemble_into_the_verified_blob() {
    let (a, b) = pair(160, 161);
    let data: Vec<u8> = (0..(MEDIA_CHUNK_SIZE + 7_000)).map(|i| (i % 251) as u8).collect();
    let r = content_ref("img_", &data);
    let (c0, c1) = data.split_at(MEDIA_CHUNK_SIZE);

    b.handle_media_chunk(&seal_chunk(&a, &b, &r, 1, 2, c1));              // the tail first
    assert!(!b.media_present(&r), "not complete yet");
    b.handle_media_chunk(&seal_chunk(&a, &b, &r, 1, 2, c1));              // a repeated chunk changes nothing
    assert!(!b.media_present(&r));
    b.handle_media_chunk(&seal_chunk(&a, &b, &r, 0, 2, c0));
    assert!(b.media_present(&r), "the last missing chunk completes it");
    assert_eq!(b.media_bytes(DEFAULT_CIRCLE, &r).unwrap(), data, "and it opens to exactly the original bytes");
    assert!(b.dyn_state.lock().reassembly.get(&r).is_none(), "the reassembly record is cleared");
    b.handle_media_chunk(&seal_chunk(&a, &b, &r, 0, 2, c0));              // already held: ignored
}

#[tokio::test]
async fn a_blob_that_does_not_match_its_content_address_is_rejected() {
    let (a, b) = pair(162, 163);
    let data = vec![5u8; 1_000];
    let wrong_ref = content_ref("img_", b"something else entirely");
    b.handle_media_chunk(&seal_chunk(&a, &b, &wrong_ref, 0, 1, &data));
    assert!(!b.media_present(&wrong_ref), "bytes that do not hash to their ref are never adopted");
    assert!(b.dyn_state.lock().reassembly.get(&wrong_ref).is_none(), "and no stale bitmap is left behind");
}

#[tokio::test]
async fn malformed_chunk_frames_are_ignored() {
    let (a, b) = pair(164, 165);
    let r = content_ref("img_", b"x");
    b.handle_media_chunk(&[]);
    b.handle_media_chunk(&[1]);
    b.handle_media_chunk(&[9, 0, b'a']);                                   // claims a 9-byte ref it does not have
    b.handle_media_chunk(&seal_chunk(&a, &b, &r, 0, 0, b"x"));            // total 0
    b.handle_media_chunk(&seal_chunk(&a, &b, &r, 3, 2, b"x"));            // index past total
    b.handle_media_chunk(&seal_chunk(&a, &b, &r, 0, wire::MAX_RESUME_CHUNKS + 1, b"x"));  // absurd total
    b.handle_media_chunk(&seal_chunk(&a, &b, "", 0, 1, b"x"));             // no ref
    b.handle_media_chunk(&wire::chunk_frame(r.as_bytes(), 0, 1, b"not sealed"));          // cannot be opened
    assert!(!b.media_present(&r));
    assert!(b.dyn_state.lock().reassembly.get(&r).is_none());
}

// ── self-sync key selection and superseded circles ──────────────────────────────────────────────

#[tokio::test]
async fn a_primary_syncs_under_its_seed_key_until_the_channel_is_rotated() {
    let (e, _) = new_engine(180);
    let (accepted, seed_key, seal) = e.self_sync_crypto();
    assert!(accepted.is_empty() && seal.is_none(), "the v0 path: no rotated epochs");
    assert_eq!(seed_key, Some(haven_p2p::identity::Identity::from_seed(&[180u8; 32]).self_sync_key()));
    assert_eq!(e.self_sync_key(), seed_key);
}

#[tokio::test]
async fn a_seedless_device_syncs_under_exactly_the_key_it_was_granted() {
    let paths = crate::covtest_util::tmp_paths();
    let s = Engine::new_seedless(paths.clone()).unwrap();
    assert_eq!(s.self_sync_crypto(), (Default::default(), None, None), "not yet granted: nothing to sync with");
    assert!(s.self_sync_key().is_none());
    {
        let mut sl = s.seedless.lock();
        sl.self_sync_key = vec![9u8; 32];
        sl.self_sync_epoch = 0;
    }
    let (acc, v0, seal) = s.self_sync_crypto();
    assert!(acc.is_empty() && seal.is_none());
    assert_eq!(v0, Some([9u8; 32]), "a v0-equivalent grant opens legacy blobs");
    s.seedless.lock().self_sync_epoch = 3;
    let (acc, v0, seal) = s.self_sync_crypto();
    assert_eq!(acc.get(&3), Some(&[9u8; 32]));
    assert_eq!(v0, None, "a rotated grant no longer honours the legacy key");
    assert_eq!(seal, Some((3, [9u8; 32])));
}

#[tokio::test]
async fn a_circle_carried_onto_an_owned_successor_leaves_one_row_and_a_synced_tombstone() {
    let (e, _) = new_engine(181);
    e.social.create_circle("legacy-circle".into(), "Old".into());
    let successor = e.upgrade_circle("legacy-circle".into());
    if let Some(new_id) = successor {
        assert!(e.prefs.lock().created_circles.contains(&new_id));
        e.reconcile_superseded_circles();
        assert!(e.prefs.lock().is_circle_deleted("legacy-circle"), "the legacy row is tombstoned so sync cannot resurrect it");
        assert!(e.feed_circles().iter().all(|c| c.id != "legacy-circle"));
        e.reconcile_superseded_circles();                                  // idempotent
    }
    e.reconcile_superseded_circles();                                      // nothing superseded: no-op
}

// ── multi-circle posts with attachments: one blob openable by every selected circle ─────────────

/// The stored (at-rest, sealed) bytes behind a ref.
fn stored(e: &Engine, r: &str) -> Vec<u8> {
    e.media.raw_sealed(r).expect("blob is held")
}

#[tokio::test]
async fn resealed_media_opens_under_every_selected_circle_and_the_ref_never_changes() {
    let (e, paths) = new_engine(190);
    let work = e.create_circle("Work".into());
    let bytes = b"\xFF\xD8\xFF one photo for two circles".to_vec();
    let r = e.add_local_media(DEFAULT_CIRCLE, &bytes, false);
    let before = stored(&e, &r);
    // (The author's own account is a recipient of every circle's seal, so a single-engine test
    // cannot show a NON-member circle failing to open it; the per-circle epoch entries are the
    // core's `seal_circle_media_multi` tests. What this pins is the store-level contract below.)
    assert!(e.social.open_circle_media(DEFAULT_CIRCLE.into(), before.clone()).is_some());

    e.reseal_media_for_circles(DEFAULT_CIRCLE, std::slice::from_ref(&r), &[DEFAULT_CIRCLE.to_string(), work.clone()])
        .expect("reseal");
    let after = stored(&e, &r);
    assert_ne!(before, after, "a fresh envelope replaced the stored blob");
    for cid in [DEFAULT_CIRCLE, work.as_str()] {
        assert_eq!(e.social.open_circle_media(cid.into(), after.clone()).as_deref(), Some(&bytes[..]), "opens under {cid}");
        assert_eq!(e.media.load(&e.social, cid, &r).as_deref(), Some(&bytes[..]), "load verifies under {cid}");
    }
    // Same ref, same file name (the plaintext's sha-256), one file, no scratch left behind.
    assert_eq!(r, format!("img_{}", crate::localmedia::bare_id(&r)));
    let names: Vec<String> = std::fs::read_dir(paths.media_dir()).unwrap().flatten()
        .map(|d| d.file_name().to_string_lossy().into_owned()).collect();
    assert_eq!(names, vec![crate::localmedia::bare_id(&r).to_string()]);
}

#[tokio::test]
async fn reseal_with_a_non_origin_primary_and_a_repeat_still_covers_origin() {
    let (e, _) = new_engine(191);
    let work = e.create_circle("Work".into());
    let r = e.add_local_audio(DEFAULT_CIRCLE, b"OggS a voice note");
    // Targets given in picker order (not origin-first), with a duplicate.
    e.reseal_media_for_circles(DEFAULT_CIRCLE, std::slice::from_ref(&r), &[work.clone(), DEFAULT_CIRCLE.to_string(), work.clone()])
        .expect("reseal");
    let blob = stored(&e, &r);
    assert!(e.social.open_circle_media(DEFAULT_CIRCLE.into(), blob.clone()).is_some());
    assert!(e.social.open_circle_media(work, blob).is_some());
}

#[tokio::test]
async fn reseal_works_for_file_attachments_stored_from_disk() {
    let (e, paths) = new_engine(192);
    let work = e.create_circle("Work".into());
    let src = paths.root.join("clip.mp4");
    std::fs::write(&src, b"a clip stored via the file path").unwrap();
    let r = e.add_local_media_file(DEFAULT_CIRCLE, src.to_str().unwrap(), true).expect("stored");
    let f = e.add_local_file(DEFAULT_CIRCLE, b"PK a zip");
    e.reseal_media_for_circles(DEFAULT_CIRCLE, &[r.clone(), f.clone()], &[DEFAULT_CIRCLE.to_string(), work.clone()])
        .expect("reseal");
    assert_eq!(e.media.load(&e.social, &work, &r).unwrap(), b"a clip stored via the file path");
    assert_eq!(e.media.load(&e.social, &work, &f).unwrap(), b"PK a zip");
    assert_eq!(e.media_bytes(DEFAULT_CIRCLE, &r).unwrap(), b"a clip stored via the file path");
}

#[tokio::test]
async fn reseal_refuses_and_leaves_the_stored_blob_untouched_on_bad_input() {
    let (e, _) = new_engine(193);
    let work = e.create_circle("Work".into());
    let r = e.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF keep me", false);
    let before = stored(&e, &r);
    let both = vec![DEFAULT_CIRCLE.to_string(), work.clone()];

    // Unknown target circle: the core refuses, nothing is replaced.
    let unknown = vec![DEFAULT_CIRCLE.to_string(), "no-such-circle".to_string()];
    assert!(e.reseal_media_for_circles(DEFAULT_CIRCLE, std::slice::from_ref(&r), &unknown).is_err());
    assert_eq!(stored(&e, &r), before);
    // No targets / missing blob are errors too; synthetic markers are skipped (nothing to seal).
    assert!(e.reseal_media_for_circles(DEFAULT_CIRCLE, std::slice::from_ref(&r), &[]).is_err());
    assert!(e.reseal_media_for_circles(DEFAULT_CIRCLE, &["img_missing".to_string()], &both).is_err());
    assert!(e.reseal_media_for_circles(DEFAULT_CIRCLE, &["thumb:img_a:img_b".to_string(), "geo:1,2,x".to_string()], &both).is_ok());

    // A blob whose plaintext is not what its ref names (tampered / substituted) is never re-sealed
    // into a fresh, valid-looking envelope.
    let forged = e.social.seal_circle_media(DEFAULT_CIRCLE.into(), b"substituted bytes".to_vec()).unwrap();
    assert!(e.media.write_raw_sealed(&r, &forged));
    assert!(e.reseal_media_for_circles(DEFAULT_CIRCLE, std::slice::from_ref(&r), &both).is_err());
    assert_eq!(stored(&e, &r), forged, "the refused blob is left exactly as it was");
}
