//! Enabling the in-process relay must not run the store sweep inline.
//!
//! `RelayServerHandle.attach*` reaches `enable_relay_with_retention` synchronously from the app's
//! MAIN thread (RelayHost start, and the reattach after every fabric rebind). The first-enable GC
//! sweep used to run right there, stat()ing every file of the store — on a Mac hosting a 13 GB
//! library that pinned the main thread (Haven 2.0.0 (629), 150% CPU, `stat` under
//! `sweep_dir` ← `gc_sweep_with` ← `enable_relay_with_retention` ← `attach_with_limits`).
//!
//! The sweep now runs on the GC thread. What must NOT change: the grace markers are planted at
//! enable time (the 48h clock starts then), and the deferred sweep still happens promptly.

use std::time::{Duration, SystemTime};

use haven_net::blobstore::{Retention, GC_GRACE};
use haven_net::RelayNode;

fn age(path: &std::path::Path, by: Duration) {
    std::fs::File::options()
        .write(true)
        .open(path)
        .and_then(|f| f.set_modified(SystemTime::now() - by))
        .unwrap();
}

fn fresh_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("haven-enable-gc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn enable_plants_grace_markers_synchronously() {
    let dir = fresh_dir("markers");
    let relay = RelayNode::spawn([51u8; 32], None).await.unwrap();
    let node = relay.node();
    let retention = Retention { media_max_age: Some(Duration::from_secs(30 * 86_400)), ..Retention::default() };
    node.enable_relay_with_retention(dir.clone(), retention);

    // Both markers exist the moment enable returns — no waiting on the GC thread.
    let mailbox = dir.join(".haven-gc-enabled");
    let media = dir.join(".haven-media-gc-enabled");
    assert!(mailbox.is_file(), "mailbox grace marker planted at enable time");
    assert!(media.is_file(), "media grace marker planted at enable time (a media limit is set)");
    // An empty store has nothing to protect: its mailbox marker starts already past the grace.
    let mailbox_age = SystemTime::now().duration_since(std::fs::metadata(&mailbox).unwrap().modified().unwrap()).unwrap();
    assert!(mailbox_age >= GC_GRACE, "empty-store mailbox marker is backdated past the grace");
    // The media marker is fresh — the full grace before any media may be deleted.
    let media_age = SystemTime::now().duration_since(std::fs::metadata(&media).unwrap().modified().unwrap()).unwrap();
    assert!(media_age < Duration::from_secs(3600), "media marker starts the full grace clock");

    node.disable_relay();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn first_sweep_still_runs_after_enable_off_the_calling_thread() {
    let dir = fresh_dir("deferred");
    let dead = dir.join("haven/mailbox/fam/dead");
    let live = dir.join("haven/mailbox/fam/live");
    std::fs::create_dir_all(dead.parent().unwrap()).unwrap();
    std::fs::write(&dead, b"x").unwrap();
    std::fs::write(&live, b"y").unwrap();
    age(&dead, Duration::from_secs(400 * 86_400));
    // A long-running relay: its marker is ancient, so the sweep may delete.
    let marker = dir.join(".haven-gc-enabled");
    std::fs::write(&marker, b"").unwrap();
    age(&marker, Duration::from_secs(400 * 86_400));

    let relay = RelayNode::spawn([52u8; 32], None).await.unwrap();
    let node = relay.node();
    node.enable_relay(dir.clone());

    // The deferred first sweep reaps the expired entry promptly (not an hour later).
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while dead.exists() && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!dead.exists(), "the first-enable sweep ran on the GC thread");
    assert!(live.exists(), "a live entry survives the sweep");

    node.disable_relay();
    let _ = std::fs::remove_dir_all(&dir);
}
