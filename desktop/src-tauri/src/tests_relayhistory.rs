//! The relay-history pass as the user drives it: availability, status, start / cancel / dismiss and a
//! whole offline run. Its progress is process-global, so the stateful checks live in ONE test.

use super::*;
use crate::covtest_util::engine as new_engine;

const R1: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn phase() -> &'static str {
    state().lock().progress.phase
}

fn wait_for(done: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while !done() {
        assert!(std::time::Instant::now() < deadline, "timed out waiting for the relay-history pass");
        std::thread::yield_now();
    }
}

#[tokio::test]
async fn availability_status_and_a_full_offline_run() {
    let (e, _paths) = new_engine(80);
    relay_history_dismiss_all(&e);

    // No relay anywhere: nothing to load history from.
    assert_eq!(e.relay_history_unavailable(), Some("norelay"));
    assert!(!e.relay_history_start(), "start refuses when it cannot run");
    let status = e.relay_history_status();
    assert_eq!(status["state"], "idle");
    assert_eq!(status["unavailable"], "norelay");
    assert_eq!(status["journal_keys"], 0);
    assert_eq!(status["outcome"], "uptodate");

    // The satellite profile pauses it even with a relay configured.
    e.prefs.lock().relays.insert(DEFAULT_CIRCLE.into(), vec![R1.into()]);
    e.set_low_data_level("ultra");
    assert_eq!(e.relay_history_unavailable(), Some("satellite"));
    e.set_low_data_level("normal");
    assert_eq!(e.relay_history_unavailable(), None);

    // An S3 pseudo-relay is not an iroh node and does not count.
    e.prefs.lock().relays.insert(DEFAULT_CIRCLE.into(), vec!["s3:bucket".into()]);
    assert_eq!(e.relay_history_unavailable(), Some("norelay"));
    e.prefs.lock().relays.insert(DEFAULT_CIRCLE.into(), vec![R1.into()]);

    // A run against a relay that cannot be reached finishes honestly: nothing found, relay error noted.
    e.post(DEFAULT_CIRCLE.into(), "local".into(), vec![], None, false, None);
    assert!(e.relay_history_start());
    wait_for(|| phase() == "done" || phase() == "cancelled");
    let done = state().lock().progress.clone();
    assert_eq!(done.phase, "done");
    assert_eq!(done.circles_total, 1);
    assert_eq!(done.circles_done, 1);
    assert_eq!(done.entries_found, 0);
    assert_eq!(done.posts_added, 0);
    assert!(done.finished_ms >= done.started_ms && done.started_ms > 0);
    let j = e.relay_history_status();
    assert_eq!(j["state"], "done");
    assert_eq!(j["retention_caveat"], true, "a finished run always says relays are a mailbox, not an archive");
    assert_eq!(j["fraction"], 1.0);

    // A pass already in flight refuses a second start.
    state().lock().progress.phase = "scanning";
    assert!(!e.relay_history_start());
    state().lock().progress.phase = "done";

    // Dismiss clears a finished run, but never one in flight.
    e.relay_history_dismiss();
    assert_eq!(phase(), "");
    state().lock().progress.phase = "media";
    e.relay_history_dismiss();
    assert_eq!(phase(), "media", "dismissing a running pass does nothing");
    state().lock().progress.phase = "";

    // Cancel is a flag the next run replaces; the QA reset also forgets the journal.
    e.relay_history_cancel();
    assert!(state().lock().cancel.load(Ordering::SeqCst));
    e.relay_history_reset_journal();
    assert_eq!(phase(), "");
    assert_eq!(e.relay_history_status()["journal_keys"], 0);
    assert!(e.relay_history_start(), "a new start installs a fresh cancel flag");
    assert!(!state().lock().cancel.load(Ordering::SeqCst));
    wait_for(|| phase() == "done" || phase() == "cancelled");
    e.relay_history_dismiss();
}

fn relay_history_dismiss_all(e: &Arc<Engine>) {
    state().lock().progress = RelayHistoryProgress::default();
    e.relay_history_cancel();
}

#[tokio::test]
async fn media_candidates_name_posts_comments_and_their_companions_once() {
    let (e, _) = new_engine(81);
    e.post(
        DEFAULT_CIRCLE.into(),
        "pics".into(),
        vec!["img_a".into(), "thumb:img_a:img_t".into(), "geo:1,2,x".into(), "img_a".into()],
        None,
        false,
        None,
    );
    let post_id = e.feed(DEFAULT_CIRCLE)[0].id.clone();
    e.comment(DEFAULT_CIRCLE.into(), post_id, "nice".into());
    let c = e.rh_media_candidates(DEFAULT_CIRCLE);
    let refs: Vec<&str> = c.iter().map(|(r, _, _, _)| r.as_str()).collect();
    assert!(refs.contains(&"img_a") && refs.contains(&"img_t"), "{refs:?}");
    assert!(!refs.iter().any(|r| r.starts_with("geo:") || r.starts_with("thumb:")), "synthetic refs are dropped: {refs:?}");
    assert_eq!(refs.iter().filter(|r| **r == "img_a").count(), 1, "deduped");
    let t = c.iter().find(|(r, ..)| r == "img_t").unwrap();
    assert!(t.2, "a thumb is a small companion");
    assert_eq!(t.3, "img_a", "and it is tagged with the primary it belongs to");
    let a = c.iter().find(|(r, ..)| r == "img_a").unwrap();
    assert!(!a.2);
    assert_eq!(a.3, "img_a");
}

#[tokio::test]
async fn event_counts_sum_across_circles() {
    let (e, _) = new_engine(82);
    let c2 = e.create_circle("Two".into());
    e.post(DEFAULT_CIRCLE.into(), "one".into(), vec![], None, false, None);
    e.post(c2.clone(), "two".into(), vec![], None, false, None);
    let both = e.rh_event_count(&[DEFAULT_CIRCLE.to_string(), c2.clone()]);
    let first = e.rh_event_count(&[DEFAULT_CIRCLE.to_string()]);
    assert!(both > first && first > 0, "{both} vs {first}");
    assert_eq!(e.rh_event_count(&[]), 0);
}
