//! The screenshot/demo seeder: it builds a whole synthetic social graph inside a real engine, and
//! its own tail verifies that every persona's post landed. Run here under `HAVEN_DEMO=1` against a
//! throwaway data dir, so the seeder can never touch a real install.

use super::*;
use crate::covtest_util::{engine as new_engine, tmp_paths, with_env};

#[test]
fn demo_mode_is_only_the_literal_one() {
    with_env(&[("HAVEN_DEMO", "1")], || assert!(is_demo()));
    with_env(&[("HAVEN_DEMO", "true")], || assert!(!is_demo()), );
    with_env(&[("HAVEN_DEMO", "0")], || assert!(!is_demo()));
}

#[test]
fn the_demo_identity_lives_in_its_own_wiped_directory() {
    let dir = tmp_paths().root;
    with_env(&[("HAVEN_DESKTOP_DATA", dir.to_str().unwrap())], || {
        // Whatever an earlier capture left behind is wiped; the real data root is untouched.
        let old = dir.join(DEMO_DIR);
        std::fs::create_dir_all(&old).unwrap();
        std::fs::write(old.join("stale"), b"x").unwrap();
        std::fs::write(dir.join("keep.txt"), b"real").unwrap();
        let (seed, paths) = identity().expect("demo identity");
        assert_eq!(seed, seed_bytes(ME_SEED_BYTE), "the demo account is reproducible");
        assert_eq!(paths.root, dir, "HAVEN_DESKTOP_DATA names the exact directory");
        assert!(!old.join("stale").exists(), "stale demo state is removed");
        assert!(dir.join("keep.txt").exists(), "nothing outside the demo subdirectory is deleted");
    });
}

#[test]
fn seeds_are_deterministic_per_byte() {
    assert_eq!(seed_bytes(7), seed_bytes(7));
    assert_ne!(seed_bytes(7), seed_bytes(8));
}

#[tokio::test]
async fn the_seeder_is_a_no_op_outside_demo_mode() {
    let (e, _) = new_engine(0x21);
    let _g = crate::covtest_util::ENV_LOCK.lock();
    std::env::remove_var("HAVEN_DEMO");
    assert_eq!(seed(&e), None);
    assert!(e.feed(DEFAULT_CIRCLE).is_empty());
}

#[tokio::test]
async fn seeding_builds_the_full_cast_feed_dms_and_circles() {
    let paths = tmp_paths();
    let e = Engine::new(paths, seed_bytes(ME_SEED_BYTE)).unwrap();
    let posts = with_env(&[("HAVEN_DEMO", "1")], || seed(&e)).expect("demo seeds");
    assert!(posts >= 8, "own and friends' posts landed: {posts}");

    let contacts = e.contacts();
    assert_eq!(contacts.len(), 4, "the cast of four");
    for name in ["Maya Quinn", "Theo Park", "Nina Brooks", "Sam Rivera"] {
        assert!(contacts.iter().any(|c| c.name == name), "{name}");
    }
    let me = e.get_profile();
    assert_eq!(me.name, "Riley Avery");
    assert!(me.avatar.starts_with("data:image/jpeg;base64,"), "own avatar is a loadable data URL");

    let feed = e.feed(DEFAULT_CIRCLE);
    let authors: std::collections::HashSet<_> =
        feed.iter().filter(|i| !i.story).map(|i| i.author_short.clone()).collect();
    assert!(authors.len() >= 5, "every friend plus me has a post: {authors:?}");
    assert!(feed.iter().any(|i| i.story), "a stories tray");
    assert!(feed.iter().any(|i| !i.reactions.is_empty()) && feed.iter().any(|i| !i.comments.is_empty()));
    assert!(feed.iter().any(|i| i.music.is_some()), "a post with a song");
    assert!(feed.iter().any(|i| i.media.len() >= 2), "the mixed carousel");
    assert!(feed.iter().all(|i| i.media.iter().all(|m| e.media_present(m))), "every referenced demo photo is on disk");

    let circles = e.feed_circles();
    assert!(circles.iter().any(|c| c.name == "Weekend Crew"), "a second circle for the switcher");
    let threads = e.dm_threads();
    assert_eq!(threads.len(), 2, "two DM conversations");
    assert!(threads.iter().all(|t| !t.2.is_empty()), "each has a last message");
    assert!(e.started(), "the status dot does not sit on 'starting…'");
}

#[test]
fn bundled_assets_encode_as_data_urls() {
    let url = assets::data_url(b"abc", "image/png");
    assert_eq!(url, "data:image/png;base64,YWJj");
}
