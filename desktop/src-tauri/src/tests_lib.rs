//! Startup identity resolution: the QA seed override that must beat any real roster, the demo
//! identity, and the deep-link queue. Everything runs against a throwaway `HAVEN_DESKTOP_DATA`, and
//! only the code paths that never touch the OS keyring.

use crate::covtest_util::{tmp_paths, with_env};
use crate::store::Identities;
use base64::Engine as _;

fn seed_file(dir: &std::path::Path, seed: [u8; 32]) -> std::path::PathBuf {
    let f = dir.join("qa-seed.txt");
    std::fs::write(&f, format!("haven-seed:{}\n", base64::engine::general_purpose::STANDARD.encode(seed))).unwrap();
    f
}

#[test]
fn a_qa_seed_wins_over_the_roster_and_is_pinned_to_its_own_directory() {
    let dir = tmp_paths().root;
    let f = seed_file(&dir, [3u8; 32]);
    let vars = [("HAVEN_DESKTOP_DATA", dir.to_str().unwrap()), ("HAVEN_QA_SEED_FILE", f.to_str().unwrap())];
    with_env(&vars, || {
        // An existing personal roster must not be what boots.
        let paths0 = crate::store::Paths { base: dir.clone(), root: dir.clone() };
        let mut ids = Identities::default();
        ids.add(&"ee".repeat(32), "Personal");
        ids.save(&paths0).unwrap();

        let (seed, paths) = super::force_qa_seed_identity().unwrap().expect("override active");
        assert_eq!(seed, [3u8; 32]);
        assert_eq!(paths.root, dir);

        let hex = haven_ffi::Account::from_seed(seed.to_vec()).unwrap().node_id_hex();
        let ids = Identities::load(&paths0);
        let entry = ids.find(&hex).expect("QA identity joins the roster");
        assert_eq!((entry.dir.as_str(), entry.label.as_str()), ("qa-matrix", "QA linked"));
        assert_eq!(ids.active, hex, "and becomes the active one");
        assert!(ids.find(&"ee".repeat(32)).is_some(), "the personal identity is left in place");

        // Re-running is idempotent and still pins the directory.
        let again = super::force_qa_seed_identity().unwrap().unwrap();
        assert_eq!(again.0, seed);
        assert_eq!(Identities::load(&paths0).items.iter().filter(|i| i.node_hex == hex).count(), 1);

        // Every entry point honours it, without a keyring read.
        let (s2, _) = super::ensure_active_identity().unwrap();
        assert_eq!(s2, seed);
        match super::active_identity_if_exists().unwrap() {
            Some(super::Startup::Seeded { seed: s3, .. }) => assert_eq!(s3, seed),
            _ => panic!("the QA seed must boot as a seeded identity"),
        }
        match super::startup_identity().unwrap() {
            Some(super::Startup::Seeded { seed: s4, .. }) => assert_eq!(s4, seed),
            _ => panic!("startup follows the same rule"),
        }
    });
}

#[test]
fn without_a_qa_seed_the_override_is_inert() {
    let dir = tmp_paths().root;
    with_env(&[("HAVEN_DESKTOP_DATA", dir.to_str().unwrap()), ("HAVEN_QA_SEED_FILE", ""), ("HAVEN_QA_SEED_B64", "")], || {
        assert!(super::force_qa_seed_identity().unwrap().is_none());
    });
}

#[test]
fn a_malformed_qa_seed_is_an_error_not_a_silent_new_identity() {
    let dir = tmp_paths().root;
    let f = dir.join("bad-seed.txt");
    std::fs::write(&f, "haven-seed:AAAA").unwrap();
    with_env(&[("HAVEN_DESKTOP_DATA", dir.to_str().unwrap()), ("HAVEN_QA_SEED_FILE", f.to_str().unwrap())], || {
        assert!(super::force_qa_seed_identity().is_err());
    });
}

#[test]
fn the_demo_identity_boots_through_startup_without_the_roster() {
    let dir = tmp_paths().root;
    with_env(&[("HAVEN_DESKTOP_DATA", dir.to_str().unwrap()), ("HAVEN_DEMO", "1")], || {
        match super::startup_identity().unwrap() {
            Some(super::Startup::Seeded { seed, paths }) => {
                assert_eq!(seed, crate::demo::identity().unwrap().0);
                assert_eq!(paths.root, dir);
            }
            _ => panic!("demo mode boots seeded"),
        }
    });
}

#[test]
fn deep_links_queue_in_order_and_survive_a_panicking_holder() {
    let q = super::DeepLinks::default();
    q.0.lock().push("haven://p/c/1".into());
    q.0.lock().push("haven://invite#a.b".into());
    let drained = std::mem::take(&mut *q.0.lock());
    assert_eq!(drained, vec!["haven://p/c/1".to_string(), "haven://invite#a.b".to_string()]);
    assert!(q.0.lock().is_empty());
    // A panic while the lock is held must not poison it (parking_lot): later opens still work.
    let q = std::sync::Arc::new(q);
    let q2 = q.clone();
    let _ = std::thread::spawn(move || {
        let _g = q2.0.lock();
        panic!("boom");
    })
    .join();
    q.0.lock().push("after".into());
    assert_eq!(q.0.lock().len(), 1);
}

#[test]
fn percent_decoding_handles_utf8_literals_and_truncated_escapes() {
    assert_eq!(super::percent_decode("plain"), "plain");
    assert_eq!(super::percent_decode("v%3Aabc"), "v:abc");
    assert_eq!(super::percent_decode("caf%C3%A9"), "café");
    assert_eq!(super::percent_decode("100%zz"), "100%zz", "a bad escape stays as written");
    assert_eq!(super::percent_decode("tail%4"), "tail%4", "a truncated escape stays as written");
    assert_eq!(super::percent_decode(""), "");
}

#[test]
fn the_stderr_logger_honours_its_level_and_keeps_dependency_chatter_out() {
    use log::Log;
    let logger = super::StderrLogger(log::LevelFilter::Info);
    let meta = |level, target: &'static str| log::Metadata::builder().level(level).target(target).build();
    assert!(logger.enabled(&meta(log::Level::Info, "haven_desktop_lib::engine")));
    assert!(logger.enabled(&meta(log::Level::Warn, "hyper")));
    assert!(!logger.enabled(&meta(log::Level::Debug, "haven_desktop_lib")));
    for (level, target) in [
        (log::Level::Info, "haven_desktop_lib::engine"), // ours: printed
        (log::Level::Info, "hyper::client"),             // a dependency below Warn: dropped
        (log::Level::Warn, "hyper::client"),             // a dependency at Warn: printed
        (log::Level::Debug, "haven_desktop_lib"),        // below the filter: dropped
    ] {
        logger.log(&log::Record::builder().args(format_args!("line")).level(level).target(target).build());
    }
    logger.flush();
    // Installing twice is harmless: the second set_boxed_logger just errs.
    with_env(&[("RUST_LOG", "trace")], || super::init_logging());
    super::init_logging();
}

#[test]
fn the_window_helpers_are_inert_without_a_main_window_and_drive_one_when_present() {
    let app = tauri::test::mock_app();
    super::apply_window_chrome(app.handle());
    super::restore_window(app.handle()); // no "main" window: returns quietly
    let _w = tauri::WebviewWindowBuilder::new(&app, "main", tauri::WebviewUrl::App("index.html".into()))
        .build()
        .expect("a mock window builds");
    super::apply_window_chrome(app.handle());
    super::restore_window(app.handle());
    assert!(super::no_net(), "the test process runs under HAVEN_NO_NET");
}
