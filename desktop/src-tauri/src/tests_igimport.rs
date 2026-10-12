//! Instagram archive reading and the import runner, driven by a synthetic export built in a temp
//! dir (a handful of stored zip entries) instead of the owner's real download.
//!
//! The runner keeps process-global state, so everything that drives it lives in ONE test, run
//! top to bottom.

use super::*;
use crate::covtest_util::{engine as new_engine, tmp_paths};
use crate::engine::DEFAULT_CIRCLE;
use crate::instagram::{Failure, Kind};
use std::io::Write;
use std::path::Path;

fn build_zip(name: &str, entries: &[(&str, Vec<u8>)]) -> PathBuf {
    let path = tmp_paths().root.join(name);
    let file = std::fs::File::create(&path).unwrap();
    let mut z = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    for (n, data) in entries {
        z.start_file(*n, opts).unwrap();
        z.write_all(data).unwrap();
    }
    z.finish().unwrap();
    path
}

fn json(v: serde_json::Value) -> Vec<u8> {
    serde_json::to_vec(&v).unwrap()
}

fn export() -> Vec<(&'static str, Vec<u8>)> {
    vec![
        (
            "your_instagram_activity/media/posts.json",
            json(serde_json::json!([
                { // a carousel: the cover is the media object, the second photo hangs off its metadata
                    "timestamp": 1_700_000_100,
                    "title": "Pe\u{c3}\u{b1}a day",
                    "media": [{"uri": "media/posts/a.jpg", "creation_timestamp": 1_700_000_100,
                               "media_metadata": {"video_metadata": {"music_genre": "Pop"},
                                                  "nested": {"more": [{"uri": "media/posts/b.jpg"}]}}}],
                    "label_values": [{"label": "Media", "value": ""}]
                },
                { // a draft is never imported
                    "timestamp": 1_700_000_200, "title": "draft",
                    "media": [{"uri": "media/posts/draft.jpg"}],
                    "label_values": [{"label": "Draft", "value": "True"}]
                },
                { // the post's own timestamp is missing: the media's wins
                    "title": "", "media": [{"uri": "media/posts/c.jpg", "creation_timestamp": 1_700_000_050}]
                },
                {"timestamp": 1_700_000_300, "title": "no media", "media": []}
            ])),
        ),
        (
            "your_instagram_activity/media/stories.json",
            json(serde_json::json!({"ig_stories": [
                {"uri": "media/stories/s.jpg", "creation_timestamp": 1_700_000_400, "title": "story"},
                {"uri": "", "creation_timestamp": 1_700_000_410}
            ]})),
        ),
        (
            "your_instagram_activity/media/reels.json",
            json(serde_json::json!({"ig_reels_media": [
                {"media": [{"uri": "media/reels/r.mp4", "creation_timestamp": 1_700_000_500, "title": "reel"}]},
                {"media": [{"uri": "media/reels/gone.mp4", "creation_timestamp": 1_700_000_510}]}
            ]})),
        ),
        ("media/posts/a.jpg", vec![1u8; 10]),
        ("media/posts/b.jpg", vec![2u8; 20]),
        ("media/posts/c.jpg", vec![3u8; 30]),
        ("media/stories/s.jpg", vec![4u8; 40]),
        ("media/reels/r.mp4", vec![5u8; 50]),
    ]
}

#[test]
fn a_synthetic_export_parses_into_a_deterministic_summary() {
    let path = build_zip("ok.zip", &export());
    let s = crate::instagram::read(&path).expect("parses");
    assert_eq!((s.count(Kind::Post), s.count(Kind::Story), s.count(Kind::Reel)), (2, 1, 2));
    assert_eq!(s.items.len(), 5, "drafts and media-less posts are dropped");
    assert!(s.items.windows(2).all(|w| w[0].created_at <= w[1].created_at), "oldest first");
    assert_eq!(s.earliest(), Some(1_700_000_050_000));
    assert_eq!(s.latest(), Some(1_700_000_510_000));
    let carousel = s.items.iter().find(|i| i.body == "Peña day").expect("mojibake repaired");
    assert_eq!(carousel.media_names, vec!["media/posts/a.jpg", "media/posts/b.jpg"], "nested album members are kept");
    assert_eq!(carousel.music_genre.as_deref(), Some("Pop"));
    assert_eq!(s.media_count, 6);
    assert_eq!(s.total_bytes, 10 + 20 + 30 + 40 + 50, "bytes of the resolvable files");
    assert_eq!(s.missing, vec!["media/reels/gone.mp4".to_string()], "references the archive lacks are reported");
    // Same archive, same order every time (a resumed import skips by index).
    let again = crate::instagram::read(&path).unwrap();
    let a: Vec<_> = s.items.iter().map(|i| i.media_names.clone()).collect();
    let b: Vec<_> = again.items.iter().map(|i| i.media_names.clone()).collect();
    assert_eq!(a, b);
}

#[test]
fn unusable_archives_say_why() {
    assert_eq!(crate::instagram::read(Path::new("/definitely/not/here.zip")).unwrap_err(), Failure::Unreadable);
    let junk = tmp_paths().root.join("junk.zip");
    std::fs::write(&junk, b"not a zip").unwrap();
    assert_eq!(crate::instagram::read(&junk).unwrap_err(), Failure::Unreadable);

    let html = build_zip("html.zip", &[("your_instagram_activity/media/posts.html", b"<html>".to_vec())]);
    assert_eq!(crate::instagram::read(&html).unwrap_err(), Failure::HtmlExport);
    let other = build_zip("other.zip", &[("readme.txt", b"hi".to_vec())]);
    assert_eq!(crate::instagram::read(&other).unwrap_err(), Failure::Unreadable);
    let empty = build_zip(
        "empty.zip",
        &[("your_instagram_activity/media/posts.json", b"[]".to_vec())],
    );
    assert_eq!(crate::instagram::read(&empty).unwrap_err(), Failure::NoContent);

    for f in [Failure::Unreadable, Failure::HtmlExport, Failure::NoContent] {
        assert!(!f.message().is_empty());
    }
    assert!(Failure::HtmlExport.message().contains("JSON"));
}

#[test]
fn archive_entries_can_be_read_listed_and_extracted() {
    let path = build_zip("a.zip", &export());
    let mut a = crate::instagram::Archive::open(&path).unwrap();
    assert!(a.names().contains(&"media/posts/a.jpg".to_string()));
    assert_eq!(a.sizes()["media/posts/b.jpg"], 20);
    assert_eq!(a.read("media/posts/a.jpg"), Some(vec![1u8; 10]));
    assert_eq!(a.read("nope"), None);
    let dest = tmp_paths().root.join("out.bin");
    assert!(a.extract_to("media/posts/c.jpg", &dest));
    assert_eq!(std::fs::read(&dest).unwrap(), vec![3u8; 30]);
    assert!(!a.extract_to("nope", &dest));
    assert!(!a.extract_to("media/posts/c.jpg", Path::new("/nonexistent-dir/x")));
}

#[test]
fn scratch_paths_are_unique_and_keep_the_extension() {
    let a = scratch_path("mp4");
    let b = scratch_path("mp4");
    assert_ne!(a, b);
    assert!(a.extension().unwrap() == "mp4");
    assert!(a.starts_with(std::env::temp_dir()));
}

#[test]
fn the_runner_imports_backdated_posts_keeps_stories_and_checkpoints() {
    let _bridge = crate::covtest_util::IGENCODE_LOCK.lock();
    let archive = build_zip("run.zip", &export());
    let (engine, paths) = new_engine(60);
    // There is no webview here. Every optimize request the importer makes is declined by
    // `wait_until` (below) so it takes its own path, instead of waiting out a 45 s timeout per image.

    // Idle by default.
    reset(&engine);
    let st = status();
    assert_eq!(st["phase"], "idle");
    assert_eq!(st["running"], false);
    assert!(st["summary"].is_null());

    // Preview: read() parses on a thread; wait for it to leave Reading.
    read(engine.clone(), archive.to_string_lossy().into());
    wait_until(|| state().lock().phase() != Phase::Reading);
    let st = status();
    assert_eq!(st["phase"], "previewing", "{st}");
    assert_eq!(st["summary"]["posts"], 2);
    assert_eq!(st["summary"]["stories"], 1);
    assert_eq!(st["summary"]["reels"], 2);
    assert_eq!(st["summary"]["missing"], 1);
    assert_eq!(st["archivePath"], archive.to_string_lossy().to_string());

    // A bad path fails with the human message and no summary.
    let bad = tmp_paths().root.join("bad.zip");
    std::fs::write(&bad, b"nope").unwrap();
    read(engine.clone(), bad.to_string_lossy().into());
    wait_until(|| state().lock().phase() != Phase::Reading);
    let st = status();
    assert_eq!(st["phase"], "failed");
    assert!(st["message"].as_str().unwrap().contains("readable"));
    assert!(st["summary"].is_null());

    // Run needs a previewed archive; from Failed it does nothing.
    run(engine.clone(), "default".into(), true, false, 0);
    assert!(!state().lock().running);

    // Preview again, then import everything including stories.
    read(engine.clone(), archive.to_string_lossy().into());
    wait_until(|| state().lock().phase() == Phase::Previewing);
    run(engine.clone(), DEFAULT_CIRCLE.into(), true, false, 0);
    wait_until(|| !state().lock().running);
    let st = status();
    assert_eq!(st["phase"], "finished", "{st}");
    assert_eq!(st["total"], 5);
    assert_eq!(st["done"], 5);
    // The reel whose file is absent from the archive stages nothing and is skipped.
    assert_eq!(st["imported"], 4, "{st}");
    assert_eq!(st["skipped"], 1);
    assert!(st["resumeFrom"].is_null(), "a finished run has nothing to resume");
    assert!(!paths.instagram_import_file().exists(), "finishing clears the checkpoint");

    // Posts are backdated and newest-first; the story became a kept story, not a feed post.
    let feed = engine.feed(DEFAULT_CIRCLE);
    assert_eq!(feed.len(), 3, "carousel + c.jpg + the reel: {:?}", feed.iter().map(|f| &f.body).collect::<Vec<_>>());
    assert!(feed.iter().all(|f| f.created_at < 1_800_000_000_000 && !f.media.is_empty()));
    let carousel = feed.iter().find(|f| f.body == "Peña day").unwrap();
    assert!(carousel.media.len() >= 2, "both carousel photos staged");
    let kept = engine.kept_stories();
    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].id, "ig:media/stories/s.jpg");
    assert!(engine.pinned_count() >= 1, "kept story media is pinned");

    // A second run skipping the first N items starts from the checkpoint index.
    reset(&engine);
    assert_eq!(status()["phase"], "idle");
    read(engine.clone(), archive.to_string_lossy().into());
    wait_until(|| state().lock().phase() == Phase::Previewing);
    run(engine.clone(), DEFAULT_CIRCLE.into(), false, false, 100);
    wait_until(|| !state().lock().running);
    let st = status();
    assert_eq!(st["total"], 4, "stories excluded");
    assert_eq!(st["imported"], 0, "start_at past the end imports nothing");

    // resume_now with nothing to resume is a no-op; cancel with no run is harmless.
    resume_now(engine.clone());
    cancel();
    reset(&engine);
}

#[test]
fn a_leftover_checkpoint_for_a_missing_archive_is_discarded() {
    let _bridge = crate::covtest_util::IGENCODE_LOCK.lock();
    let (engine, paths) = new_engine(61);
    save_pending(
        &engine,
        &Pending { archive_path: "/no/such/archive.zip".into(), circle_id: "default".into(), include_stories: false, match_songs: false, done: 3 },
    );
    assert_eq!(load_pending(&engine).unwrap().done, 3);
    resume_if_needed(engine.clone());
    assert!(!paths.instagram_import_file().exists(), "an archive that is gone cannot be resumed");
    assert!(load_pending(&engine).is_none());
    resume_if_needed(engine); // nothing pending: no-op
}

fn wait_until(mut cond: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        crate::igencode::decline_all();
        if cond() {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "timed out waiting for the importer");
        std::thread::yield_now();
    }
}
