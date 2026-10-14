//! The command layer, exercised with a real `State<Arc<Engine>>` from tauri's mock runtime: DTO
//! mapping, empty-circle normalisation, input validation and error strings. Same throwaway data
//! dirs as the engine tests; commands that restart the app or touch the OS keyring are skipped.

use super::*;
use crate::covtest_util::engine as new_engine;
use crate::engine::cov_engine_tests::{hello_into, is_foreground, prefs_of};
use tauri::{Manager, State};

type St<'a> = State<'a, Arc<Engine>>;

fn with_engine<T>(seed: u8, f: impl FnOnce(St, &Arc<Engine>) -> T) -> T {
    let (e, _paths) = new_engine(seed);
    let app = tauri::test::mock_app();
    app.manage(e.clone());
    let st: St = app.state::<Arc<Engine>>();
    f(st, &e)
}

#[test]
fn bootstrap_reports_identity_invites_and_profile() {
    with_engine(40, |st, e| {
        set_profile(st.clone(), "Ada".into(), "bio".into(), "https://x.example".into(), "🦊".into(), String::new());
        let b = bootstrap(st.clone());
        assert_eq!(b.node_id_hex, e.node_id_hex());
        assert!(b.invite_uri.starts_with("haven:"));
        assert!(b.invite_link.contains("haven.is"));
        assert_eq!(b.profile.name, "Ada");
        assert_eq!(b.profile.emoji, "🦊");
        assert!(!b.started);
        assert_eq!(get_profile(st.clone()).bio, "bio");
        assert_eq!(my_node_hex(st), e.node_id_hex());
    });
}

#[test]
fn self_test_passes_every_primitive() {
    let r = self_test();
    assert_eq!(r["all_ok"], true, "{r}");
    for k in ["identity_ok", "hybrid_kem_ok", "signature_ok", "link_ok"] {
        assert_eq!(r[k], true, "{k}");
    }
    assert_eq!(r["node_id_hex"].as_str().unwrap().len(), 64);
}

#[tokio::test]
async fn empty_circle_id_means_the_personal_circle_for_every_authoring_command() {
    with_engine(41, |st, _| {
        post(st.clone(), String::new(), "hello".into(), vec![], None, None, None);
        let f = feed(st.clone(), String::new());
        assert_eq!(f.len(), 1, "an empty circleId must not silently drop the post");
        assert_eq!(f[0].author_name, "You");
        assert!(f[0].is_me);
        let id = f[0].id.clone();

        comment(st.clone(), String::new(), id.clone(), "c1".into());
        react(st.clone(), String::new(), id.clone(), "🔥".into());
        let f = feed(st.clone(), String::new());
        assert_eq!(f[0].comments.len(), 1);
        assert_eq!(f[0].comments[0].author_name, "You");
        assert_eq!(f[0].reactions.len(), 1);
        assert!(f[0].reactions[0].mine);
        unreact(st.clone(), String::new(), id.clone(), "🔥".into());

        edit_post(st.clone(), DEFAULT_CIRCLE.into(), id.clone(), "edited".into(), None, None, None).unwrap();
        // An edit of an id that does not exist is accepted but changes nothing in the feed.
        let before = feed(st.clone(), DEFAULT_CIRCLE.into()).len();
        let _ = edit_post(st.clone(), DEFAULT_CIRCLE.into(), "zzz".into(), "x".into(), Some(vec![]), None, None);
        assert_eq!(feed(st.clone(), DEFAULT_CIRCLE.into()).len(), before);
        assert_eq!(feed(st.clone(), DEFAULT_CIRCLE.into())[0].body, "edited");

        post_story(st.clone(), "story".into(), None, None);
        assert!(feed(st.clone(), String::new()).iter().any(|i| i.story));
        assert!(sensitive_refs(st.clone(), String::new()).is_empty());
        assert_eq!(sync_status(st.clone(), String::new()), "local");

        let rows = media_backup_rows(st.clone(), String::new(), vec![]);
        assert!(rows["rows"].as_array().unwrap().is_empty());
        assert_eq!(rows["ownRelay"], "");

        unsend_post(st.clone(), DEFAULT_CIRCLE.into(), id);
    });
}

#[tokio::test]
async fn music_input_maps_through_to_the_post() {
    with_engine(42, |st, _| {
        let track = TrackInput {
            catalog_id: "123".into(),
            title: "Song".into(),
            artist: "Band".into(),
            artwork_url: String::new(),
            duration_ms: 1000,
        };
        post(st.clone(), String::new(), String::new(), vec![], Some(track), Some(true), None);
        let f = feed(st, String::new());
        assert_eq!(f.len(), 1, "a song alone is a valid post");
        let m = f[0].music.as_ref().unwrap();
        assert_eq!((m.title.as_str(), m.artist.as_str(), m.duration_ms), ("Song", "Band", 1000));
        assert!(f[0].mute_video);
    });
}

#[tokio::test]
async fn circles_commands_create_rename_admin_and_leave() {
    with_engine(43, |st, e| {
        let id = create_circle(st.clone(), "Climbers".into());
        assert!(circles(st.clone()).iter().any(|c| c.id == id && c.name == "Climbers"));
        rename_circle(st.clone(), id.clone(), "Boulderers".into());
        assert!(circles(st.clone()).iter().any(|c| c.name == "Boulderers"));
        assert!(circle_admins(st.clone(), id.clone()).contains(&e.node_id_hex()));
        assert!(!can_offer_circle_upgrade(st.clone(), "default".into()));
        assert!(pending_circle_upgrades(st.clone(), id.clone()).is_empty());
        leave_circle(st.clone(), id.clone());
        assert!(circles(st.clone()).iter().all(|c| c.id != id));
        leave_circle(st.clone(), DEFAULT_CIRCLE.into());
        assert!(circles(st).iter().any(|c| c.id == DEFAULT_CIRCLE));
    });
}

#[tokio::test]
async fn dm_commands_thread_pin_and_clear() {
    let (a, _) = new_engine(44);
    let (b, _) = new_engine(45);
    let app = tauri::test::mock_app();
    app.manage(a.clone());
    let st: St = app.state::<Arc<Engine>>();
    // Make b a contact of a through the hello handlers.
    a.connect_by_link(b.invite_uri());
    hello_into(&a, &b);
    assert_eq!(contacts(st.clone()).len(), 1);

    let dm = start_dm(st.clone(), b.node_id_hex(), "Bee".into());
    send_dm(st.clone(), dm.clone(), "hi bee".into(), vec![], None, None);
    let msgs = messages(st.clone(), dm.clone());
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].body, "hi bee");
    let threads = dm_threads(st.clone());
    assert_eq!(threads.len(), 1);
    assert_eq!((threads[0].circle_id.as_str(), threads[0].last_body.as_str(), threads[0].unread), (dm.as_str(), "hi bee", 0));

    set_pinned_dms(st.clone(), vec![dm.clone()]);
    assert_eq!(pinned_dms(st.clone()), vec![dm.clone()]);
    mark_dm_read(st.clone(), dm.clone());
    let act = activity(st.clone());
    assert_eq!(act.seen_at, activity_seen(st.clone()));
    mark_activity_seen(st.clone());
    assert!(activity_seen(st.clone()) >= act.seen_at);

    // Scheduling a DM for the past and firing it delivers into the thread.
    let sid = schedule_message(st.clone(), "dm".into(), dm.clone(), "later".into(), vec![], None, None, 1);
    let queued = scheduled(st.clone());
    assert_eq!(queued.len(), 1);
    assert_eq!((queued[0].kind.as_str(), queued[0].media_count, queued[0].has_music), ("dm", 0, false));
    a.fire_due_scheduled();
    assert_eq!(messages(st.clone(), dm.clone()).len(), 2);
    let sid2 = schedule_message(st.clone(), "post".into(), String::new(), "p".into(), vec!["m".into()], None, Some(true), u64::MAX);
    assert_eq!(scheduled(st.clone())[0].kind, "post");
    assert_eq!(scheduled(st.clone())[0].circle_id, DEFAULT_CIRCLE, "empty circle normalises");
    assert_eq!(scheduled(st.clone())[0].media_count, 1);
    cancel_scheduled(st.clone(), sid2);
    assert!(scheduled(st.clone()).is_empty());
    let _ = sid;

    delete_conversation(st.clone(), dm.clone());
    assert!(messages(st.clone(), dm).is_empty());

    let author = message_author(st.clone(), b.node_id_hex()[..8].to_string(), DEFAULT_CIRCLE.into(), "pid".into());
    assert!(author.is_some());
    let g = start_group_dm(st.clone(), vec![(b.node_id_hex(), "Bee".into())]);
    assert!(g.starts_with("dm:"));
}

#[tokio::test]
async fn contact_request_commands_approve_dismiss_block() {
    let (a, _) = new_engine(46);
    let (b, _) = new_engine(47);
    let app = tauri::test::mock_app();
    app.manage(b.clone());
    let st: St = app.state::<Arc<Engine>>();
    assert!(!connect_by_link(st.clone(), "garbage".into()));
    hello_into(&b, &a);
    let p = pending(st.clone());
    assert_eq!(p.len(), 1);
    assert_eq!(p[0].id_hex, a.node_id_hex());
    dismiss(st.clone(), p[0].id_hex.clone());
    assert!(pending(st.clone()).is_empty());
    hello_into(&b, &a);
    approve(st.clone(), a.node_id_hex());
    let c = contacts(st.clone());
    assert_eq!(c.len(), 1);
    assert_eq!(c[0].id_hex, a.node_id_hex());
    block(st.clone(), a.node_id_hex());
    assert_eq!(blocked(st.clone()), vec![a.node_id_hex()]);
    assert!(contacts(st.clone()).is_empty());
    unblock(st.clone(), a.node_id_hex());
    assert!(blocked(st).is_empty());
}

#[tokio::test]
async fn privacy_and_low_data_commands_agree_with_the_policy_table() {
    with_engine(48, |st, _| {
        let p = privacy_prefs(st.clone());
        assert_eq!((p.notification_detail.as_str(), p.super_data_saver, p.send_original), ("full", false, false));
        set_privacy_prefs(st.clone(), Some("minimal".into()), Some(false), Some(true));
        let p = privacy_prefs(st.clone());
        assert_eq!((p.notification_detail.as_str(), p.send_original), ("minimal", true));

        let l = low_data_state(st.clone());
        assert_eq!((l.level.as_str(), l.active), ("normal", false));
        assert!(l.description.contains("Full speed"));
        assert_eq!(low_data_allowance(st.clone(), "media".into()), "allow");
        set_low_data_level(st.clone(), "ultra".into());
        let l = low_data_state(st.clone());
        assert!(l.active && l.description.contains("Satellite"));
        assert_ne!(low_data_allowance(st.clone(), "media".into()), "allow", "ultra holds media back");
        assert_eq!(low_data_allowance(st.clone(), "text".into()), "allow", "text always flows");
        assert_eq!(
            low_data_allowance(st.clone(), "bogus".into()),
            low_data_allowance(st.clone(), "media".into()),
            "an unknown traffic kind is treated as the strictest (media), never silently allowed"
        );
        for t in [
            "key_convergence", "presence", "thumbnail", "link_preview", "story", "call",
            "history_backfill", "self_sync", "enrollment",
        ] {
            let a = low_data_allowance(st.clone(), t.into());
            assert!(["allow", "ask_first", "deny"].contains(&a.as_str()), "{t} -> {a}");
        }
        set_low_data_level(st.clone(), "low".into());
        assert!(low_data_state(st.clone()).description.contains("Low data"));

        assert!(!video_sound_on(st.clone()));
        set_video_sound(st.clone(), true);
        assert!(video_sound_on(st));
    });
}

#[test]
fn level_of_maps_names_and_defaults_to_normal() {
    use haven_p2p::transport::LinkConstraint::*;
    assert_eq!(level_of("ultra"), Ultra);
    assert_eq!(level_of("low"), Low);
    assert_eq!(level_of("anything"), Normal);
}

#[tokio::test]
async fn enrollment_commands_surface_errors_as_strings() {
    with_engine(49, |st, _| {
        let t = enroll_mint_ticket(st.clone()).unwrap();
        assert!(t.starts_with("haven-enroll:"));
        assert!(enroll_pending(st.clone()).is_empty());
        let err = enroll_approve(st.clone(), "nope".into()).unwrap_err();
        assert!(err.contains("no such pending"), "{err}");
        enroll_reject(st.clone(), "nope".into());
        let s = seedless_status(st.clone());
        assert!(!s.seedless && !s.linked && !s.linking);
        enable_device_roster(st.clone());
        let r = device_roster(st.clone());
        assert!(r.enabled, "the primary has the roster on (it holds no credential of its own)");
        assert_eq!(r.devices.len(), 1);
        revoke_device(st.clone(), "unknown-device".into());
        step_down_as_primary(st);
    });
}

#[tokio::test]
async fn media_commands_store_serve_pin_and_clean_up() {
    use base64::Engine as _;
    let b64 = |bytes: &[u8]| base64::engine::general_purpose::STANDARD.encode(bytes);
    with_engine(50, |st, e| {
        assert!(add_media(st.clone(), String::new(), "!!not base64!!".into(), false).is_err());
        // Distinct payloads: media is content-addressed, so equal bytes would share one blob.
        let jpeg = b64(&[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
        let r = add_media(st.clone(), String::new(), jpeg.clone(), false).unwrap();
        assert!(r.starts_with("img_"), "{r}");
        let url = media_data_url(st.clone(), String::new(), r.clone()).unwrap();
        assert!(url.starts_with("data:image/jpeg;base64,"), "{url}");
        assert!(media_data_url(st.clone(), String::new(), "img_missing".into()).is_none());

        let v = add_media(st.clone(), String::new(), b64(&[0, 0, 0, 0x20, b'f', b't', b'y', b'p', 9, 9, 9, 9]), true).unwrap();
        assert!(v.starts_with("vid_"));
        assert!(media_data_url(st.clone(), String::new(), v).unwrap().starts_with("data:video/mp4;base64,"));
        let a = add_audio(st.clone(), String::new(), b64(b"OggS\x00\x02 padding to twenty")).unwrap();
        assert!(media_data_url(st.clone(), String::new(), a).unwrap().starts_with("data:audio/ogg;base64,"));
        let f = add_file(st.clone(), String::new(), b64(b"PK\x03\x04 sixteen bytes")).unwrap();
        assert!(media_data_url(st.clone(), String::new(), f).unwrap().starts_with("data:application/zip;base64,"));
        assert!(add_audio(st.clone(), String::new(), "%%%".into()).is_err());
        assert!(add_file(st.clone(), String::new(), "%%%".into()).is_err());
        assert!(mint_preview(st.clone(), String::new(), "%%%".into()).is_none());

        // Nothing references these blobs, so they are inventory orphans.
        let inv = media_inventory(st.clone());
        assert_eq!(inv.len(), 4, "{:?}", inv.iter().map(|r| &r.reference).collect::<Vec<_>>());
        assert!(inv.iter().all(|r| r.is_orphan && !r.is_pinned && r.circle_name == "Unused"));
        assert!(inv.windows(2).all(|w| w[0].bytes >= w[1].bytes), "largest first");

        // A fresh blob is inside the 48 h grace window and is never swept, even when unreferenced.
        assert_eq!(media_cleanup(st.clone()).files, 0, "new media is spared");
        // Age everything past the grace window, pin the largest, and sweep.
        for entry in std::fs::read_dir(e.paths().media_dir()).unwrap().flatten() {
            let f = std::fs::OpenOptions::new().write(true).open(entry.path()).unwrap();
            f.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(72 * 3600)).unwrap();
        }
        let keep = inv[0].reference.clone();
        media_pin(st.clone(), vec![keep.clone()]);
        assert_eq!(media_pinned_count(st.clone()), 1);
        assert!(media_inventory(st.clone()).iter().any(|r| r.reference == keep && r.is_pinned));
        let cleaned = media_cleanup(st.clone());
        assert_eq!(cleaned.files, 3, "the pinned blob survives the sweep");
        assert!(cleaned.bytes > 0);
        assert_eq!(media_inventory(st.clone()).len(), 1);
        assert_eq!(media_delete_selected(st.clone(), vec![keep.clone()]), 0, "a pinned blob is never deleted by hand");
        media_unpin(st.clone(), vec![keep.clone()]);
        assert_eq!(media_pinned_count(st.clone()), 0);
        assert!(media_delete_selected(st.clone(), vec![keep]) > 0);
        assert!(media_inventory(st.clone()).is_empty());

        assert!(media_evicted_size(st.clone(), "img_gone".into()).is_none());
        assert!(!media_is_wanted(st.clone(), "img_gone".into()));
        set_media_limits(st.clone(), 14, 3);
        let l2 = get_media_limits(st);
        assert_eq!((l2.days, l2.gb), (14, 3));
    });
}

#[tokio::test]
async fn reoptimize_commands_validate_input_and_report_an_empty_library() {
    with_engine(51, |st, _| {
        let scan = reoptimize_scan(st.clone());
        assert!(scan.candidates.is_empty());
        assert_eq!(scan.batch_limit, crate::reoptimize::BATCH_LIMIT);
        assert!(reoptimize_targets(st.clone()).is_empty());
        assert!(reoptimize_accept(st.clone(), String::new(), "img_x".into(), "@@@".into()).unwrap_err().contains("bad base64"));
        assert_eq!(reoptimize_accept(st.clone(), DEFAULT_CIRCLE.into(), "img_x".into(), "AAAA".into()).unwrap(), None);
        reoptimize_skip(st.clone(), "img_x".into());
        assert!(reoptimize_headroom(st.clone(), 1));
        assert!(!reoptimize_apply(st, DEFAULT_CIRCLE.into(), "evt".into(), vec![]));
    });
}

#[tokio::test]
async fn kept_story_toggle_keeps_then_releases() {
    with_engine(52, |st, _| {
        let entry = || crate::store::KeptStory {
            id: "s1".into(),
            body: "b".into(),
            media: vec!["img_a".into()],
            created_at: 5,
            kept_at: None,
            music_catalog_id: None,
            music_title: None,
            music_artist: None,
            music_artwork_url: None,
            music_duration_ms: None,
        };
        assert!(toggle_kept_story(st.clone(), entry()), "first toggle keeps");
        assert_eq!(kept_stories(st.clone()).len(), 1);
        assert_eq!(media_pinned_count(st.clone()), 1, "a kept story pins its media");
        assert!(!toggle_kept_story(st.clone(), entry()), "second toggle releases");
        assert!(kept_stories(st.clone()).is_empty());
        assert_eq!(media_pinned_count(st), 0);
    });
}

#[tokio::test]
async fn relay_commands_manage_entries_without_a_network() {
    with_engine(53, |st, e| {
        let hex = "ab".repeat(32);
        let rs = relay_status(st.clone());
        assert!(!rs.hosting && !rs.has_relay && !rs.path_routed);
        assert!(relays(st.clone()).is_empty());
        prefs_of(e).ensure_relay_entry(&hex, Some("Home"), false, true);
        rename_relay(st.clone(), hex.clone(), "Studio".into());
        set_default_relay(st.clone(), hex.clone());
        let list = relays(st.clone());
        assert_eq!(list.len(), 1);
        assert_eq!((list[0].name.as_str(), list[0].active, list[0].is_default), ("Studio", true, true));
        assert!(circle_relays(st.clone(), DEFAULT_CIRCLE.into()).is_empty(), "the default relay is inherited, not an explicit per-circle association");

        let d = get_relay_media_limits(st.clone());
        assert_eq!((d.max_age_days, d.max_bytes), (30, 32 * 1024 * 1024 * 1024));
        set_relay_media_limits(st.clone(), 7, 1024);
        let d = get_relay_media_limits(st.clone());
        assert_eq!((d.max_age_days, d.max_bytes), (7, 1024));

        set_relay_public_settings(st.clone(), "https://r.example".into(), String::new(), false, "manual".into(), String::new());
        let ps = relay_public_settings(st.clone());
        assert_eq!(ps.public_url, "https://r.example");
        assert_eq!(ps.front_door, "manual");
        assert!(!ps.auto_tunnel);

        let s3 = s3_status(st.clone());
        assert!(!s3.configured && s3.bucket.is_empty());
        stop_hosting(st);
    });
}

#[tokio::test]
async fn async_relay_commands_forget_erase_and_restore() {
    let (e, _) = new_engine(54);
    let app = tauri::test::mock_app();
    app.manage(e.clone());
    let st: St = app.state::<Arc<Engine>>();
    let hex = "cd".repeat(32);
    prefs_of(&e).ensure_relay_entry(&hex, Some("Far"), false, true);
    prefs_of(&e).relays.insert(DEFAULT_CIRCLE.into(), vec![hex.clone()]);
    forget_relay(st.clone(), hex.clone()).await.unwrap();
    assert!(!relays(st.clone())[0].active, "forget deactivates, never erases");
    reactivate_relay(st.clone(), hex.clone()).await.unwrap();
    assert!(relays(st.clone())[0].active);
    set_circle_relay(st.clone(), hex.clone(), "c1".into(), true).await.unwrap();
    assert!(circle_relays(st.clone(), "c1".into()).contains(&hex));
    set_circle_relay(st.clone(), hex.clone(), "c1".into(), false).await.unwrap();
    assert!(!circle_relays(st.clone(), "c1".into()).contains(&hex));
    erase_relay(st.clone(), hex.clone()).await.unwrap();
    assert!(relays(st.clone()).is_empty());
    assert_eq!(erased_relays(st.clone()).len(), 1, "an erased relay is kept for undo");
    restore_erased_relay(st.clone(), hex.clone()).await.unwrap();
    assert_eq!(relays(st.clone()).len(), 1);
    assert!(erased_relays(st.clone()).is_empty());
    erase_relay(st.clone(), hex.clone()).await.unwrap();
    drop_erased_relay(st.clone(), hex);
    assert!(erased_relays(st).is_empty());
}

#[test]
fn seed_decoding_accepts_every_alphabet_and_rejects_the_rest() {
    use base64::engine::general_purpose as g;
    use base64::Engine as _;
    let seed = [0xFBu8; 32]; // bytes that differ between the standard and url-safe alphabets
    for enc in [
        g::STANDARD.encode(seed),
        g::URL_SAFE.encode(seed),
        g::STANDARD_NO_PAD.encode(seed),
        g::URL_SAFE_NO_PAD.encode(seed),
        format!("haven-seed:{}", g::STANDARD.encode(seed)),
        format!("  haven-seed: {}  ", g::STANDARD.encode(seed)),
    ] {
        assert_eq!(decode_seed(&enc).unwrap(), seed, "{enc}");
    }
    assert!(decode_seed("***").unwrap_err().contains("bad seed base64"));
    assert_eq!(decode_seed(&g::STANDARD.encode([1u8; 16])).unwrap_err(), "seed is not 32 bytes");
}

#[test]
fn itunes_ids_come_from_track_links_only() {
    assert_eq!(itunes_track_id("https://music.apple.com/us/album/x/123456?i=789"), Some("789".into()));
    assert_eq!(itunes_track_id("https://music.apple.com/us/album/x/id123456"), Some("123456".into()));
    assert_eq!(itunes_track_id("https://itunes.apple.com/us/song/id42?foo=1"), Some("42".into()));
    assert_eq!(itunes_track_id("https://music.apple.com/us/artist/band"), None, "no id, no result");
    assert_eq!(itunes_track_id("https://example.com/id123"), None, "other hosts are not music links");
}

#[test]
fn dropped_files_are_type_and_size_checked() {
    let dir = crate::covtest_util::tmp_paths().root;
    let img = dir.join("pic.JPG");
    std::fs::write(&img, b"imgbytes").unwrap();
    let ok = read_media_file_b64(img.to_string_lossy().into(), 100).unwrap();
    assert_eq!(ok["name"], "pic.JPG");
    assert_eq!(ok["is_video"], false);
    assert_eq!(ok["data_base64"], base64::engine::general_purpose::STANDARD.encode(b"imgbytes"));
    let vid = dir.join("clip.mov");
    std::fs::write(&vid, b"v").unwrap();
    assert_eq!(read_media_file_b64(vid.to_string_lossy().into(), 100).unwrap()["is_video"], true);
    assert!(read_media_file_b64(img.to_string_lossy().into(), 3).unwrap_err().contains("too large"));
    let txt = dir.join("notes.txt");
    std::fs::write(&txt, b"x").unwrap();
    assert!(read_media_file_b64(txt.to_string_lossy().into(), 100).unwrap_err().contains("not a media file"));
    assert!(read_media_file_b64(dir.join("missing.png").to_string_lossy().into(), 100).is_err());
}

#[tokio::test]
async fn call_commands_record_qa_state_and_are_inert_without_a_node() {
    with_engine(55, |st, e| {
        qa_set_call_state(st.clone(), true, false, Some("sess".into()), Some("trail".into()));
        assert_eq!(e.qa_call_state(), Some((true, false)));
        assert_eq!(e.qa_call_session(), "sess");
        call_signal(st.clone(), "offer".into(), "sess".into(), "{}".into(), "ab".repeat(32));
        call_hangup(st.clone(), vec![], "sess".into());
        call_camera_state(st.clone(), "sess".into(), true, vec![]);
        call_accept(st.clone(), "sess".into(), vec![]);
        call_handled_elsewhere(st.clone(), "sess".into());
        call_group_invite(st, "sess".into(), "Group".into(), vec![], vec![]);
    });
}

#[tokio::test]
async fn identity_commands_report_errors_without_keyring_access() {
    with_engine(56, |st, _| {
        assert!(identities(st.clone()).is_empty());
        assert!(rename_identity(st.clone(), "nobody".into(), "x".into()).is_err());
        assert!(remove_identity(st.clone(), "nobody".into()).is_err());
        assert!(import_identity(st, "x".into(), "not-a-seed".into()).is_err());
    });
}

#[tokio::test]
async fn foreground_flag_and_instagram_status_are_reachable() {
    with_engine(57, |st, e| {
        set_foreground(st.clone(), true);
        assert!(is_foreground(e));
        set_foreground(st.clone(), false);
        assert!(!is_foreground(e));
        ui_log("hello from the webview".into());
        assert!(sweep_duplicate_imports(st.clone(), DEFAULT_CIRCLE.into()) == 0);
        request_older_history(st.clone(), DEFAULT_CIRCLE.into(), 1);
        let _ = relay_history_status(st.clone());
        relay_history_cancel(st.clone());
        relay_history_dismiss(st);
    });
}

#[test]
fn queued_deep_links_are_drained_in_order_exactly_once() {
    let app = tauri::test::mock_app();
    app.manage(crate::DeepLinks::default());
    let links: State<'_, crate::DeepLinks> = app.state();
    links.0.lock().push("haven://p/c/1".into());
    links.0.lock().push("haven://invite#a.b".into());
    assert_eq!(take_deep_links(links.clone()), vec!["haven://p/c/1".to_string(), "haven://invite#a.b".to_string()]);
    assert!(take_deep_links(links).is_empty(), "a second drain finds nothing");
}

#[tokio::test]
async fn instagram_import_commands_drive_the_runner_state() {
    let _bridge = crate::covtest_util::IGENCODE_LOCK.lock();
    with_engine(58, |st, _| {
        instagram_reset(st.clone());
        assert_eq!(instagram_status()["phase"], "idle");
        instagram_cancel();                                   // no run in flight: harmless
        instagram_encoded(u64::MAX, None);                    // an answer nobody asked for
        instagram_encoded(u64::MAX - 1, Some(vec!["img_x".into()]));
        instagram_resume(st.clone());                         // nothing to resume
        instagram_reset(st);
    });
}

#[test]
fn onboarding_is_never_offered_in_demo_mode_or_with_a_qa_identity() {
    use base64::Engine as _;
    let dir = crate::covtest_util::tmp_paths().root;
    let f = dir.join("seed.txt");
    std::fs::write(&f, base64::engine::general_purpose::STANDARD.encode([4u8; 32])).unwrap();
    // A QA seed means an identity exists, so the welcome flow is skipped; and the keyring is never read.
    crate::covtest_util::with_env(
        &[("HAVEN_DESKTOP_DATA", dir.to_str().unwrap()), ("HAVEN_QA_SEED_FILE", f.to_str().unwrap())],
        || assert_eq!(needs_onboarding(), Ok(false)),
    );
    crate::covtest_util::with_env(&[("HAVEN_DEMO", "1"), ("HAVEN_DESKTOP_DATA", dir.to_str().unwrap())], || {
        assert_eq!(needs_onboarding(), Ok(false), "the demo cast is never 'fresh'");
        assert!(demo_mode());
    });
    crate::covtest_util::with_env(&[("HAVEN_DEMO", "0")], || assert!(!demo_mode()));
}

#[tokio::test]
async fn circle_governance_report_and_housekeeping_commands_map_the_engine() {
    with_engine(62, |st, e| {
        let cid = create_circle(st.clone(), "Club".into());
        // Upgrade offers: nothing pending, a made-up acceptance is refused, and a circle that is not a
        // legacy one has nothing to carry over.
        assert!(pending_circle_upgrades(st.clone(), cid.clone()).is_empty());
        assert!(!accept_circle_upgrade(st.clone(), cid.clone(), "no-such-successor".into()));
        assert_eq!(upgrade_circle(st.clone(), cid.clone()), e.upgrade_circle(cid.clone()));
        // Membership and admin delegation pass straight through (an unknown account is simply not added).
        let stranger = "cd".repeat(32);
        add_to_circle(st.clone(), cid.clone(), stranger.clone());
        remove_from_circle(st.clone(), cid.clone(), stranger.clone());
        assert_eq!(grant_circle_admin(st.clone(), cid.clone(), stranger.clone()), e.circle_admins(&cid).contains(&stranger));

        // A report names its target and shows up in the circle's shared list with a resolved name.
        post(st.clone(), cid.clone(), "rude post".into(), vec![], None, None, None);
        let target = feed(st.clone(), cid.clone())[0].id.clone();
        let author = report(st.clone(), cid.clone(), target.clone(), "spam".into(), "looks like an ad".into());
        assert!(author.is_some(), "a report of an existing post returns its author");
        let rows = reports(st.clone(), cid.clone());
        assert_eq!(rows.len(), 1);
        assert_eq!((rows[0].target.as_str(), rows[0].reason.as_str(), rows[0].comment.as_str()), (target.as_str(), "spam", "looks like an ad"));
        assert!(!rows[0].reporter_name.is_empty());

        // Housekeeping: an unknown ref downloads nothing, the re-encode scan of an empty library is empty,
        // a bad preview payload is refused, and an ask for an unresolvable author is dropped.
        media_download(st.clone(), "img_not_held".into());
        let scan = reoptimize_scan(st.clone());
        assert!(scan.candidates.is_empty());
        assert!(reoptimize_targets(st.clone()).is_empty());
        assert_eq!(mint_preview(st.clone(), String::new(), "!!not base64!!".into()), None);
        media_request_when_available(st.clone(), "img_x".into(), cid.clone(), "p1".into(), "zzzzzzzz".into());
        assert!(!media_is_wanted(st.clone(), "img_x".into()));
        assert!(!relay_history_start(st.clone()), "no relay, so the history pass cannot run");
        relay_history_cancel(st.clone());
        relay_history_dismiss(st.clone());

        // A scheduled post comes back with an id and is listed.
        let sid = schedule_message(st.clone(), "post".into(), cid.clone(), "later".into(), vec![], None, None, now_ms_for_test() + 3_600_000);
        assert!(!sid.is_empty());
        let s3 = s3_status(st.clone());
        assert!(!s3.configured && s3.bucket.is_empty());
        request_device_enrollment(st);
    });
}

fn now_ms_for_test() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}
