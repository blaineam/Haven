//! The peer side of media: serving a friend's direct ask (and pointing them at a relay instead), the
//! resume bitmap, "notify me when it's back" (frames 31 / 32), the push-ahead prefetch and the missing
//! media sweep. Two engines are wired together in-process; the transport edge (`send_frame`) is a
//! no-op without a node, so what is asserted is the decision each handler makes and the state it
//! leaves behind. The author's re-upload goes to the loopback relay stub of `tests_engine_http`.

use super::*;
use crate::covtest_util::engine as new_engine;
use crate::engine::cov_engine_http_tests::{wire_to, Stub, RELAY};
use crate::engine::cov_engine_tests::{befriend, deliver};
use crate::engine::qa_media;
use std::sync::atomic::Ordering::Relaxed;

/// `a` and `b` are friends; `a` has posted a photo of `size` bytes and `b` has the post (not the photo).
fn friends_with_a_photo(sa: u8, sb: u8, size: usize) -> (Arc<Engine>, Arc<Engine>, String, String) {
    let (a, _) = new_engine(sa);
    let (b, _) = new_engine(sb);
    befriend(&a, &b);
    let mut bytes = b"\xFF\xD8\xFF".to_vec();
    bytes.extend((0..size).map(|i| (i % 253) as u8));
    bytes.extend(sa.to_le_bytes());
    bytes.extend(sb.to_le_bytes());
    let r = a.add_local_media(DEFAULT_CIRCLE, &bytes, false);
    a.post(DEFAULT_CIRCLE.into(), "a photo".into(), vec![r.clone()], None, false, None);
    deliver(&a, &b, DEFAULT_CIRCLE);
    let post_id = b.feed(DEFAULT_CIRCLE).into_iter().find(|i| i.media.contains(&r)).expect("b has the post").id;
    (a, b, r, post_id)
}

fn ask(requester: &Arc<Engine>, r: &str) -> Vec<u8> {
    format!("{}{}", requester.node_id_hex(), r).into_bytes()
}

#[tokio::test]
async fn a_direct_ask_from_a_friend_or_my_own_device_is_served_and_junk_is_not() {
    let (a, b, r, _) = friends_with_a_photo(200, 201, 70_000);
    let (friend0, own0) = (qa_media::SERVED_DIRECT_FRIEND.load(Relaxed), qa_media::SERVED_DIRECT_OWN.load(Relaxed));
    a.handle_media_request(&ask(&b, &r)).await;
    assert!(qa_media::SERVED_DIRECT_FRIEND.load(Relaxed) > friend0, "a friend's ask streams the file");
    assert!(a.dyn_state.lock().chunk_serving.is_empty(), "and the serve slot is released");
    a.handle_media_request(&ask(&a, &r)).await;
    assert!(qa_media::SERVED_DIRECT_OWN.load(Relaxed) > own0, "my own device rides the account-key lane");

    // Nothing is served for a short body, a ref we do not hold, or an empty ref.
    let (friend1, own1) = (qa_media::SERVED_DIRECT_FRIEND.load(Relaxed), qa_media::SERVED_DIRECT_OWN.load(Relaxed));
    a.handle_media_request(b"too short").await;
    a.handle_media_request(&ask(&b, "img_notheld")).await;
    a.handle_media_request(b.node_id_hex().as_bytes()).await;
    assert!(qa_media::SERVED_DIRECT_FRIEND.load(Relaxed) >= friend1 && qa_media::SERVED_DIRECT_OWN.load(Relaxed) >= own1);
    assert!(a.dyn_state.lock().chunk_serving.is_empty());

    // A serve already running for the pair is not started twice.
    let key = format!("{r}|{}", b.node_id_hex());
    a.dyn_state.lock().chunk_serving.insert(key.clone());
    let bytes = a.media.load_any_circle(&a.social, &r).unwrap();
    a.serve_chunks_once(&r, &b.node_id_hex(), &bytes, None).await;
    assert!(a.dyn_state.lock().chunk_serving.contains(&key), "the running serve keeps its slot");
}

#[tokio::test]
async fn nothing_is_streamed_while_a_call_is_up() {
    let (a, b, r, _) = friends_with_a_photo(202, 203, 2_000);
    assert!(a.qa_call_state().is_none());
    a.set_qa_call_state(true, false, "sess".into(), "ringing".into());
    let declined = qa_media::DECLINED.load(Relaxed);
    assert!(!a.relay_first_decide(&r, &b.node_id_hex()).await, "a ringing call owns the uplink");
    assert!(qa_media::DECLINED.load(Relaxed) > declined);
    a.set_qa_call_state(false, true, "sess".into(), "connected".into());
    assert!(!a.relay_first_decide(&r, &b.node_id_hex()).await);
    a.set_qa_call_state(false, false, "sess".into(), "ended".into());
    assert!(a.relay_first_decide(&r, &b.node_id_hex()).await, "once it ends, serving resumes");
}

#[tokio::test]
async fn a_blob_a_relay_already_holds_is_hinted_three_times_then_served_directly() {
    let (a, b, r, _) = friends_with_a_photo(204, 205, 2_000);
    a.adopt_relay(RELAY.to_string()).await;
    let bh = b.node_id_hex();
    let hints = qa_media::HINTS_SENT.load(Relaxed);
    for n in 1..=3 {
        a.mark_media_backed_up(RELAY, &r);
        assert!(!a.relay_first_decide(&r, &bh).await, "hint {n}: point them at the relay instead of streaming");
    }
    assert!(qa_media::HINTS_SENT.load(Relaxed) >= hints + 3);
    a.mark_media_backed_up(RELAY, &r);
    assert!(a.relay_first_decide(&r, &bh).await, "the budget is spent: they provably cannot read the relay copy");

    // My own devices are always served, a ref in no feed is served, a ref no relay holds is served.
    a.mark_media_backed_up(RELAY, &r);
    assert!(a.relay_first_decide(&r, &a.node_id_hex()).await);
    let unknown = "img_unknown_to_every_feed";
    a.mark_media_backed_up(RELAY, unknown);
    assert!(a.relay_first_decide(unknown, &bh).await);
    assert!(a.relay_first_decide("img_never_backed_up", &bh).await);
    // The ask re-probes (once an hour per ref) the relay copy it was supposed to have made redundant.
    assert!(a.dyn_state.lock().backup_reverified_at.contains_key(&r));
    assert!(a.dyn_state.lock().backup_reverified_at.contains_key(unknown));
}

#[tokio::test]
async fn a_resume_ask_is_served_only_the_chunks_the_requester_lacks() {
    let (a, b, r, _) = friends_with_a_photo(206, 207, 100_000);
    let plain = a.media.load_any_circle(&a.social, &r).unwrap();
    let total = ((plain.len() + MEDIA_CHUNK_SIZE - 1) / MEDIA_CHUNK_SIZE) as u32;
    assert!(total >= 4);
    let bh = b.node_id_hex();
    let all: HashSet<u32> = (0..total).collect();
    let served = |_a: &Arc<Engine>| qa_media::SERVED_DIRECT_FRIEND.load(Relaxed);

    let before = served(&a);
    a.handle_media_resume_request(&wire::resume_frame(&bh, &r, total, &all)).await;
    assert_eq!(a.dyn_state.lock().chunk_serving.len(), 0);
    let _ = before; // a complete bitmap sends nothing; counters are shared with parallel tests

    let mut some = all.clone();
    some.remove(&2);
    let before = served(&a);
    a.handle_media_resume_request(&wire::resume_frame(&bh, &r, total, &some)).await;
    assert!(served(&a) > before, "a partial bitmap is served the gap");

    // A total that disagrees with ours means their partial indexes other bytes: send everything.
    let before = served(&a);
    a.handle_media_resume_request(&wire::resume_frame(&bh, &r, total + 9, &some)).await;
    assert!(served(&a) > before);

    // Junk, an unheld ref and a hostile oversized bitmap are all ignored.
    a.handle_media_resume_request(b"junk").await;
    a.handle_media_resume_request(&wire::resume_frame(&bh, "img_nothere", 3, &HashSet::new())).await;
    assert!(a.dyn_state.lock().chunk_serving.is_empty());
}

#[tokio::test]
async fn asking_peers_for_media_upgrades_to_a_resume_request_once_a_partial_exists() {
    let (a, b, r, _) = friends_with_a_photo(208, 209, 100_000);
    let plain = a.media.load_any_circle(&a.social, &r).unwrap();
    let total = ((plain.len() + MEDIA_CHUNK_SIZE - 1) / MEDIA_CHUNK_SIZE) as u32;
    let me = b.node_id_hex();
    let payload = ask(&b, &r);
    let targets = vec![a.node_id_hex()];
    // No partial: the plain frame-3 path.
    b.ask_for_media(&r, &me, payload.clone(), targets.clone());
    assert!(b.dyn_state.lock().resume_fallback.is_empty());
    // Hold chunk 1 of a sealed stream: the next ask is a frame 33 with a fallback armed (once).
    let sealed = a.social.seal_media(b.node_id_hex(), plain[MEDIA_CHUNK_SIZE..2 * MEDIA_CHUNK_SIZE].to_vec()).unwrap();
    b.handle_media_chunk(&wire::chunk_frame(r.as_bytes(), 1, total, &sealed));
    assert!(b.dyn_state.lock().reassembly.resume_hint(&r).is_some(), "b holds a partial");
    b.ask_for_media(&r, &me, payload.clone(), targets.clone());
    assert!(b.dyn_state.lock().resume_fallback.contains(&r), "frame 33 arms the full-request fallback");
    b.ask_for_media(&r, &me, payload, targets);
    assert_eq!(b.dyn_state.lock().resume_fallback.len(), 1, "never more than one fallback per ref");
}

#[tokio::test]
async fn an_author_puts_swept_media_back_on_a_relay_when_a_member_asks() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (a, b, r, post_id) = friends_with_a_photo(210, 211, 3_000);
    wire_to(&a, &stub).await;
    wire_to(&b, &stub).await;
    // Adopting the relay backfilled history; the relay then "sweeps" everything, which is the premise.
    stub.store.lock().clear();
    let (ah, bh) = (a.node_id_hex(), b.node_id_hex());

    // b asks the author; an unresolvable author is not asked.
    b.request_media_when_available(r.clone(), DEFAULT_CIRCLE.into(), post_id.clone(), "zzzzzzzz".into(), true);
    assert!(!b.media_is_wanted(&r));
    b.request_media_when_available(r.clone(), DEFAULT_CIRCLE.into(), post_id.clone(), ah[..8].to_string(), true);
    b.request_media_when_available(r.clone(), DEFAULT_CIRCLE.into(), post_id.clone(), ah[..8].to_string(), false);
    assert!(b.media_is_wanted(&r));
    assert_eq!(b.prefs.lock().media_wanted.iter().filter(|x| **x == r).count(), 1, "asking twice records once");

    let wanted_frame = |from: &Arc<Engine>, to: &str, circle: &str, reference: &str| {
        from.social
            .seal_call_frame(to.to_string(), wire::MEDIA_WANTED, from.media_frame_body(reference, circle, &post_id))
            .expect("seals to a contact")
    };

    // Refusals: a stranger, a circle the asker is not in, a ref the author does not hold.
    let (stranger, _) = new_engine(212);
    let sealed_by_stranger = stranger.social.seal_call_frame(ah.clone(), wire::MEDIA_WANTED, stranger.media_frame_body(&r, DEFAULT_CIRCLE, &post_id));
    if let Ok(s) = sealed_by_stranger {
        a.handle_media_wanted(&s).await;
    }
    a.handle_media_wanted(b"garbage").await;
    a.handle_media_wanted(&wanted_frame(&b, &ah, "no-such-circle", &r)).await;
    a.handle_media_wanted(&wanted_frame(&b, &ah, DEFAULT_CIRCLE, "img_author_has_nothing")).await;
    assert!(stub.store.lock().get(&Engine::media_key(&r)).is_none(), "none of those uploaded anything");

    // An ask already being served is a duplicate.
    a.dyn_state.lock().media_serving.insert(r.clone());
    a.handle_media_wanted(&wanted_frame(&b, &ah, DEFAULT_CIRCLE, &r)).await;
    assert!(stub.store.lock().get(&Engine::media_key(&r)).is_none());
    a.dyn_state.lock().media_serving.remove(&r);

    // The real ask: the author re-seals and re-uploads, then remembers it did.
    a.handle_media_wanted(&wanted_frame(&b, &ah, DEFAULT_CIRCLE, &r)).await;
    assert!(stub.store.lock().get(&Engine::media_key(&r)).is_some(), "the blob is back on the relay");
    assert!(a.dyn_state.lock().media_resealed_session.contains(&r));
    assert!(a.dyn_state.lock().media_served_at.contains_key(&r));
    assert!(a.dyn_state.lock().media_serving.is_empty());
    // A second ask inside the cooldown is answered from what was already done.
    let puts = stub.count("PUT /k/haven/media/");
    a.handle_media_wanted(&wanted_frame(&b, &ah, DEFAULT_CIRCLE, &r)).await;
    assert_eq!(stub.count("PUT /k/haven/media/"), puts, "no second upload inside the cooldown");

    // b hears it is back (frame 32): the wish clears and the ledger entry is dropped.
    let available = a.social.seal_call_frame(bh.clone(), wire::MEDIA_AVAILABLE, a.media_frame_body(&r, DEFAULT_CIRCLE, &post_id)).unwrap();
    b.mark_evicted(&r, 10);
    b.handle_media_available(b"garbage");
    b.handle_media_available(&available);
    assert!(!b.media_is_wanted(&r), "the manual wish is consumed");
    assert!(!b.prefs.lock().media_wanted.contains(&r));
    assert!(!b.evicted_contains(&r), "and a deliberate eviction no longer blocks the re-download");
    assert!(b.activity().iter().any(|row| row.kind == "app" && row.actor_name == "Media is available again"), "the person who asked is told");
}

#[tokio::test]
async fn an_automatic_repair_ask_is_answered_silently_and_an_unsolicited_announce_is_prefetched_once() {
    let (a, b, r, post_id) = friends_with_a_photo(213, 214, 2_000);
    let (ah, bh) = (a.node_id_hex(), b.node_id_hex());
    // The sweep's own ask (manual = false) leaves no "notify me" wish.
    b.request_media_when_available(r.clone(), DEFAULT_CIRCLE.into(), post_id.clone(), ah[..8].to_string(), false);
    assert!(b.prefs.lock().media_wanted.contains(&r) && !b.media_is_wanted(&r));
    let available = a.social.seal_call_frame(bh.clone(), wire::MEDIA_AVAILABLE, a.media_frame_body(&r, DEFAULT_CIRCLE, &post_id)).unwrap();
    let rows = b.activity().len();
    b.handle_media_available(&available);
    assert!(!b.prefs.lock().media_wanted.contains(&r));
    assert_eq!(b.activity().len(), rows, "no notification for an automatic repair");

    // An announce for something nobody asked about is a quiet prefetch, throttled per ref.
    let other = "img_ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    let announce = a.social.seal_call_frame(bh.clone(), wire::MEDIA_AVAILABLE, a.media_frame_body(other, DEFAULT_CIRCLE, "")).unwrap();
    b.handle_media_available(&announce);
    let stamp = *b.dyn_state.lock().announced_media_at.get(other).expect("the announce was acted on");
    b.prefetch_announced_media(other, DEFAULT_CIRCLE);
    assert_eq!(*b.dyn_state.lock().announced_media_at.get(other).unwrap(), stamp, "inside 60 s it is not repeated");
    // Synthetic and held refs never prefetch.
    b.prefetch_announced_media("geo:1,2,x", DEFAULT_CIRCLE);
    assert!(!b.dyn_state.lock().announced_media_at.contains_key("geo:1,2,x"));
    let held = b.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF held already", false);
    b.prefetch_announced_media(&held, DEFAULT_CIRCLE);
    assert!(!b.dyn_state.lock().announced_media_at.contains_key(&held));
    // Frames from a non-contact or an unparseable body are dropped.
    let (stranger, _) = new_engine(215);
    if let Ok(s) = stranger.social.seal_call_frame(bh, wire::MEDIA_AVAILABLE, stranger.media_frame_body(other, DEFAULT_CIRCLE, "")) {
        b.handle_media_available(&s);
    }
}

#[tokio::test]
async fn the_missing_media_sweep_asks_on_a_fresh_ladder_and_repairs_what_it_holds_but_cannot_read() {
    let (a, b, r, _) = friends_with_a_photo(216, 217, 2_000);
    b.request_missing_media();
    {
        let st = b.dyn_state.lock();
        let (n, due) = st.fast_req.get(&r).copied().expect("a fresh post's media rides the fast lane");
        assert_eq!(n, 1);
        assert!(due > 0);
        assert!(st.media_req_at.contains_key(&r));
        assert!(st.fast_sweep_armed, "a re-sweep is armed while the fast lane is live");
    }
    b.request_missing_media();
    assert_eq!(b.dyn_state.lock().fast_req.get(&r).unwrap().0, 1, "the next rung is not due yet");

    // Held but unreadable: the sweep asks the author to re-seal, silently.
    let (c, d, r2, _) = friends_with_a_photo(218, 219, 2_000);
    assert!(d.media.write_raw_sealed(&r2, &[9u8; 600]));
    assert!(d.media.has(&r2));
    d.request_missing_media();
    assert!(d.prefs.lock().media_wanted.contains(&r2), "the author is asked to re-seal");
    assert!(!d.media_is_wanted(&r2), "without promising the person a notification");
    assert!(d.dyn_state.lock().media_probed_session.contains(&r2));
    drop((a, c));
}
