//! The QA driver (debug builds): the command interpreter the e2e fleet drives and the state dump
//! it reads back. Run in-process on a throwaway engine, never through the poll loop.

use super::*;
use crate::covtest_util::engine as new_engine;
use crate::engine::cov_engine_tests::hello_into;
use serde_json::json;

fn dump_of(e: &Arc<Engine>) -> Value {
    write_dump(e);
    serde_json::from_slice(&std::fs::read(e.data_root().join("qa-dump.json")).unwrap()).unwrap()
}

#[test]
fn field_trims_and_defaults_to_empty() {
    let c = json!({"a": "  x  ", "n": 5});
    assert_eq!(field(&c, "a"), "x");
    assert_eq!(field(&c, "n"), "", "non-strings read as empty");
    assert_eq!(field(&c, "missing"), "");
}

#[test]
fn dm_peers_come_from_the_circle_id() {
    let me = "a".repeat(64);
    let you = "b".repeat(64);
    assert_eq!(dm_peer(&format!("dm:{me}-{you}"), &me), you);
    assert_eq!(dm_peer(&format!("dm:{you}-{me}"), &me.to_uppercase()), you, "case-insensitive on me");
    let group = format!("dm:{me}-{you}-{}", "c".repeat(64));
    assert_eq!(dm_peer(&group, &me), group, "a group thread keys by its own id");
}

#[test]
fn marker_companions_are_the_trailing_ref() {
    assert_eq!(parse_marker_companion("thumb:img_a:img_b"), Some("img_b".into()));
    assert_eq!(parse_marker_companion("preview:img_a:img_p"), Some("img_p".into()));
    assert_eq!(parse_marker_companion("poster:vid_a:img_s"), Some("img_s".into()));
    assert_eq!(parse_marker_companion("orig:img_a:img_o"), Some("img_o".into()));
    assert_eq!(parse_marker_companion("thumb:img_a:"), None, "empty companion");
    assert_eq!(parse_marker_companion("thumbnoco"), None);
    assert_eq!(parse_marker_companion("img_plain"), None);
}

#[test]
fn only_real_refs_are_counted_for_presence() {
    let media = vec!["img_a".to_string(), "thumb:img_a:img_t".to_string(), "geo:1,2".to_string()];
    let real = real_refs(&media);
    assert!(real.contains(&"img_a".to_string()));
    assert!(!real.iter().any(|r| r.starts_with("thumb:") || r.starts_with("geo:")), "{real:?}");
}

#[tokio::test]
async fn post_story_react_comment_and_profile_ops_change_engine_state() {
    let (e, _) = new_engine(70);
    apply(&e, &json!({"op": "post", "body": "from qa", "media": "photo"}));
    let feed = e.feed(DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 1);
    assert_eq!(feed[0].body, "from qa");
    assert!(feed[0].media.iter().any(|m| m.starts_with("img_")), "a synthetic photo was staged: {:?}", feed[0].media);
    let id = feed[0].id.clone();

    apply(&e, &json!({"op": "react", "target_id": id}));
    apply(&e, &json!({"op": "react", "target_id": id, "emoji": "🔥"}));
    apply(&e, &json!({"op": "comment", "target_id": id, "body": "qa comment"}));
    apply(&e, &json!({"op": "react", "target_id": "does-not-exist"}));
    apply(&e, &json!({"op": "comment", "target_id": ""}));
    let it = e.feed(DEFAULT_CIRCLE).into_iter().find(|i| i.id == id).unwrap();
    assert_eq!(it.comments.len(), 1);
    assert!(it.reactions.iter().any(|r| r.emoji == "❤️") && it.reactions.iter().any(|r| r.emoji == "🔥"));

    apply(&e, &json!({"op": "story", "caption": "cap", "media": "photo"}));
    apply(&e, &json!({"op": "story", "body": "via body"}));
    let feed = e.feed(DEFAULT_CIRCLE);
    assert_eq!(feed.iter().filter(|i| i.story).count(), 2);
    assert!(feed.iter().any(|i| i.story && i.body == "cap"));
    assert!(feed.iter().any(|i| i.story && i.body == "via body"));

    apply(&e, &json!({"op": "profile", "name": "QA Bot"}));
    assert_eq!(e.get_profile().name, "QA Bot");
    apply(&e, &json!({"op": "profile", "name": ""}));
    assert_eq!(e.get_profile().name, "QA Bot", "an empty name leaves the profile alone");

    apply(&e, &json!({"op": "music_post", "body": "tune", "music": {"title": "T", "artist": "A", "duration_ms": 9}}));
    let tune = e.feed(DEFAULT_CIRCLE).into_iter().find(|i| i.body == "tune").unwrap();
    assert_eq!(tune.music.as_ref().unwrap().catalog_id, "qa", "blank catalog id defaults");
    assert_eq!(tune.music.unwrap().duration_ms, 9);
}

#[tokio::test]
async fn circle_ops_and_unknown_circle_fallback() {
    let (e, _) = new_engine(71);
    apply(&e, &json!({"op": "circle_create", "name": "QA Circle"}));
    let cid = e.feed_circles().into_iter().find(|c| c.name == "QA Circle").expect("created").id;
    assert_eq!(content_circle(&e, &json!({"circle_id": cid})), cid);
    assert_eq!(content_circle(&e, &json!({"circle_id": "nope"})), DEFAULT_CIRCLE, "unknown circle falls back");
    assert_eq!(content_circle(&e, &json!({})), DEFAULT_CIRCLE);
    assert_eq!(content_circle(&e, &json!({"circle_id": "default"})), DEFAULT_CIRCLE);

    apply(&e, &json!({"op": "post", "circle_id": cid, "body": "in circle"}));
    assert_eq!(e.feed(&cid).len(), 1);
    assert_eq!(find_circle_of(&e, &e.feed(&cid)[0].id), Some(cid.clone()));
    assert_eq!(find_circle_of(&e, "zzz"), None);
    assert_eq!(find_circle_of(&e, ""), None);

    // Malformed invites are refused without touching anything.
    apply(&e, &json!({"op": "circle_invite", "circle_id": cid, "dm_to": "short"}));
    apply(&e, &json!({"op": "dm", "dm_to": "short", "body": "x"}));
    assert!(e.dm_threads().is_empty());
}

#[tokio::test]
async fn dm_mark_read_ui_and_unknown_ops() {
    let (a, _) = new_engine(72);
    let (b, _) = new_engine(73);
    a.connect_by_link(b.invite_uri());
    hello_into(&a, &b);
    apply(&a, &json!({"op": "dm", "dm_to": b.node_id_hex().to_uppercase(), "body": "hey", "media": "photo"}));
    let threads = a.dm_threads();
    assert_eq!(threads.len(), 1);
    let msgs = a.messages(&threads[0].0);
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].body, "hey");
    assert_eq!(find_circle_of(&a, &msgs[0].id), Some(threads[0].0.clone()), "DM ids are found through the thread list");

    apply(&a, &json!({"op": "mark_read"}));
    apply(&a, &json!({"op": "mark_read", "circle_id": threads[0].0}));
    apply(&a, &json!({"op": "ui", "action": "open_dm", "dm_to": "x"}));
    apply(&a, &json!({"op": "approve_connections"}));
    apply(&a, &json!({"op": "link_constraint", "level": "ultra"}));
    assert_eq!(a.low_data_level(), "ultra");
    apply(&a, &json!({"op": "link_constraint", "level": "weird"}));
    assert_eq!(a.low_data_level(), "normal");
    apply(&a, &json!({"op": "dump"}));
    apply(&a, &json!({"op": "totally_unknown"}));
    apply(&a, &json!({"op": "relay_history_cancel"}));
}

#[tokio::test]
async fn file_and_media_staging_ops() {
    let (e, paths) = new_engine(74);
    let f = paths.root.join("doc.zip");
    std::fs::write(&f, b"PK-not-really").unwrap();
    apply(&e, &json!({"op": "file", "file_path": f.to_string_lossy(), "body": "attached"}));
    apply(&e, &json!({"op": "file", "file_path": "/nonexistent/file.zip"}));
    let feed = e.feed(DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 1);
    assert!(feed[0].media.iter().any(|m| m.starts_with("file_")), "{:?}", feed[0].media);

    let img = paths.root.join("p.png");
    std::fs::write(&img, QA_PNG).unwrap();
    let refs = stage_media(&e, DEFAULT_CIRCLE, &json!({"photo_path": img.to_string_lossy()}));
    assert_eq!(refs.len(), 1);
    assert!(stage_media(&e, DEFAULT_CIRCLE, &json!({"photo_path": "/nope.png"})).is_empty());
    assert!(stage_media(&e, DEFAULT_CIRCLE, &json!({"video_path": "/nope.mp4"})).is_empty());
    assert!(stage_media(&e, DEFAULT_CIRCLE, &json!({"media": "video"})).is_empty(), "synthetic video is unsupported");
    assert_eq!(stage_media(&e, DEFAULT_CIRCLE, &json!({"media": "PHOTO"})).len(), 1);
    assert!(stage_media(&e, DEFAULT_CIRCLE, &json!({})).is_empty());
}

#[tokio::test]
async fn the_dump_reports_identity_posts_dms_circles_and_media_presence() {
    let (a, _) = new_engine(75);
    let (b, _) = new_engine(76);
    a.connect_by_link(b.invite_uri());
    hello_into(&a, &b);
    apply(&a, &json!({"op": "post", "body": "dumped", "media": "photo"}));
    apply(&a, &json!({"op": "dm", "dm_to": b.node_id_hex(), "body": "dm body"}));
    a.set_qa_call_state(true, false, "sess".into(), "trail".into());

    let d = dump_of(&a);
    assert_eq!(d["device"], "desktop");
    assert_eq!(d["account_hex"], a.node_id_hex().to_lowercase());
    let post = d["posts"].as_array().unwrap().iter().find(|p| p["body"] == "dumped").expect("post in dump");
    assert_eq!(post["circle"], DEFAULT_CIRCLE);
    assert_eq!(post["media_present"], json!([true]), "the staged blob is on disk");
    assert_eq!(post["story"], false);
    let dm = d["dms"][b.node_id_hex().to_lowercase()].as_array().expect("dm keyed by peer account");
    assert_eq!(dm[0]["body"], "dm body");
    assert!(d["circles"].as_array().unwrap().iter().any(|c| c["id"] == DEFAULT_CIRCLE));
    assert_eq!(d["call"]["ringing"], true);
    assert_eq!(d["call"]["session"], "sess");
    assert_eq!(d["call_engine"]["trail"], "trail");
    assert!(d["dump_seq"].as_u64().is_some());
    assert!(d.get("relay_history").is_some() && d.get("delivery").is_some());

    // A story's caption is surfaced separately.
    apply(&a, &json!({"op": "story", "caption": "storycap"}));
    let d = dump_of(&a);
    let story = d["posts"].as_array().unwrap().iter().find(|p| p["story"] == true).unwrap();
    assert_eq!(story["caption"], "storycap");

    // No stale temp file is left behind.
    assert!(!a.data_root().join("qa-dump.json.tmp").exists());
}

#[test]
fn dump_timing_phases_are_readable() {
    let t = DumpTiming { feed_ms: 1, dms_ms: 2, meta_ms: 3, diag_ms: 4, write_ms: 5, total_ms: 15 };
    assert_eq!(t.phases(), "feed=1ms dms=2ms meta=3ms diag=4ms write=5ms");
}

#[tokio::test]
async fn presence_cache_asks_the_engine_once_per_ref() {
    let (e, _) = new_engine(77);
    let r = e.add_local_media(DEFAULT_CIRCLE, b"bytes", false);
    let mut c = PresentCache::new(&e);
    assert!(c.has(&r));
    assert!(!c.has("img_missing"));
    // Removing the file behind the cache's back does not change the cached answer.
    e.media_delete_selected(vec![r.clone()]);
    assert!(c.has(&r), "cached");
    assert!(!PresentCache::new(&e).has(&r), "a fresh cache sees the deletion");
}
