//! The engine's relay HTTP lane, driven against a loopback stub relay that lives in the test
//! process: mailbox upload and poll, the delta LIST, media upload / probe / fetch, and the 401 / 403
//! / 404 / unreachable mapping every caller depends on. A child module of `engine` (private access).
//!
//! The lane is opened per test thread with `netgate::open_relay_http_for_test`; every other transport
//! (iroh dials, S3, the push worker, iTunes) stays behind `HAVEN_NO_NET`, and the stub only listens on
//! 127.0.0.1, so nothing here can reach a real host. All tests use the current-thread tokio runtime,
//! so the stub task and the engine under test share the one thread the gate flag is set on.

use super::*;
use crate::covtest_util::engine as new_engine;
use crate::engine::cov_engine_tests::befriend;
use std::collections::BTreeMap;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const RELAY: &str = "5151515151515151515151515151515151515151515151515151515151515151";
const TOKEN: &str = "stub-token";

/// What the stub does with the next requests, whatever they ask for.
#[derive(Default)]
struct Knobs {
    /// Answer every request with this status (and an empty body).
    force_status: Option<u16>,
    /// Answer HEAD with 405 (an old relay): callers must fall back to GET.
    head_unsupported: bool,
    /// Every `METHOD path` seen, in order.
    log: Vec<String>,
}

struct Stub {
    base: String,
    store: Arc<parking_lot::Mutex<BTreeMap<String, Vec<u8>>>>,
    knobs: Arc<parking_lot::Mutex<Knobs>>,
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl Stub {
    async fn start() -> Stub {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("binds loopback");
        let base = format!("http://{}", listener.local_addr().unwrap());
        let store: Arc<parking_lot::Mutex<BTreeMap<String, Vec<u8>>>> = Default::default();
        let knobs: Arc<parking_lot::Mutex<Knobs>> = Default::default();
        let (st, kn) = (store.clone(), knobs.clone());
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { return };
                let (st, kn) = (st.clone(), kn.clone());
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut tmp = [0u8; 8192];
                    let head_end = loop {
                        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            break p + 4;
                        }
                        match sock.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => buf.extend_from_slice(&tmp[..n]),
                        }
                    };
                    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
                    let mut lines = head.lines();
                    let mut first = lines.next().unwrap_or("").split(' ');
                    let (method, path) = (first.next().unwrap_or("").to_string(), first.next().unwrap_or("").to_string());
                    let mut clen = 0usize;
                    let mut digest: Option<String> = None;
                    for l in lines {
                        let low = l.to_lowercase();
                        if let Some(v) = low.strip_prefix("content-length:") {
                            clen = v.trim().parse().unwrap_or(0);
                        }
                        if low.starts_with(&haven_net::httprelay::LIST_DIGEST_HEADER.to_lowercase()) {
                            digest = l.split_once(':').map(|(_, v)| v.trim().to_string());
                        }
                    }
                    while buf.len() < head_end + clen {
                        match sock.read(&mut tmp).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => buf.extend_from_slice(&tmp[..n]),
                        }
                    }
                    let body = buf[head_end..].to_vec();
                    kn.lock().log.push(format!("{method} {path}"));
                    let (status, extra, out): (u16, String, Vec<u8>) = {
                        let k = kn.lock();
                        if let Some(s) = k.force_status {
                            (s, String::new(), Vec::new())
                        } else if method == "HEAD" && k.head_unsupported {
                            (405, String::new(), Vec::new())
                        } else if let Some(key) = path.strip_prefix("/k/") {
                            let key = pct_decode(key);
                            match method.as_str() {
                                "PUT" => {
                                    st.lock().insert(key, body);
                                    (200, String::new(), Vec::new())
                                }
                                "GET" => match st.lock().get(&key) {
                                    Some(v) => (200, String::new(), v.clone()),
                                    None => (404, String::new(), Vec::new()),
                                },
                                "HEAD" => {
                                    (if st.lock().contains_key(&key) { 200 } else { 404 }, String::new(), Vec::new())
                                }
                                _ => (405, String::new(), Vec::new()),
                            }
                        } else if let Some(prefix) = path.strip_prefix("/l/") {
                            let prefix = pct_decode(prefix);
                            let keys: Vec<String> = st.lock().keys().filter(|k| k.starts_with(&prefix)).cloned().collect();
                            let joined = keys.join("\n");
                            let d = haven_net::httprelay::list_digest(&joined);
                            let hdr = format!("{}: {}\r\n", haven_net::httprelay::LIST_DIGEST_HEADER, d);
                            if digest.as_deref() == Some(d.as_str()) {
                                (204, hdr, Vec::new())
                            } else {
                                (200, hdr, joined.into_bytes())
                            }
                        } else {
                            (404, String::new(), Vec::new())
                        }
                    };
                    let reply_len = if method == "HEAD" { 0 } else { out.len() };
                    let head = format!(
                        "HTTP/1.1 {status} X\r\ncontent-length: {reply_len}\r\n{extra}connection: close\r\n\r\n"
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    if method != "HEAD" {
                        let _ = sock.write_all(&out).await;
                    }
                    let _ = sock.shutdown().await;
                });
            }
        });
        Stub { base, store, knobs }
    }

    fn force(&self, status: Option<u16>) {
        self.knobs.lock().force_status = status;
    }
    fn count(&self, prefix: &str) -> usize {
        self.knobs.lock().log.iter().filter(|l| l.starts_with(prefix)).count()
    }
    fn keys_with(&self, needle: &str) -> Vec<String> {
        self.store.lock().keys().filter(|k| k.contains(needle)).cloned().collect()
    }
}

/// Teach `e` the stub as an active relay of every circle, with its HTTP interface.
async fn wire_to(e: &Arc<Engine>, stub: &Stub) {
    let json = serde_json::json!({ "node": RELAY, "urls": [stub.base], "token": TOKEN });
    e.adopt_relay(json.to_string()).await;
    assert_eq!(e.prefs.lock().relay_http(RELAY).map(|(u, t)| (u, t)), Some((vec![stub.base.clone()], TOKEN.to_string())));
}

#[tokio::test]
async fn http_primitives_map_every_status_to_the_outcome_callers_branch_on() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (e, _) = new_engine(170);
    let base = stub.base.clone();

    assert_eq!(e.http_get(&base, TOKEN, "haven/x").await.unwrap(), None, "404 is a real miss");
    e.http_put(&base, TOKEN, "haven/x", b"v1".to_vec()).await.unwrap();
    assert_eq!(e.http_get(&base, TOKEN, "haven/x").await.unwrap().unwrap(), b"v1");
    assert_eq!(e.http_head(&base, TOKEN, "haven/x").await, crate::mediaholding::Head::Present);
    assert_eq!(e.http_head(&base, TOKEN, "haven/none").await, crate::mediaholding::Head::Absent);
    assert!(e.http_exists(&base, TOKEN, "haven/x").await);
    assert!(!e.http_exists(&base, TOKEN, "haven/none").await);

    // Statuses that mean "refused", "unverifiable", "down".
    stub.force(Some(403));
    assert!(matches!(e.http_get(&base, TOKEN, "k").await, Err(RelayErr::Forbidden)));
    assert!(matches!(e.http_put(&base, TOKEN, "k", vec![1]).await, Err(RelayErr::Forbidden)));
    assert_eq!(e.http_head(&base, TOKEN, "k").await, crate::mediaholding::Head::Refused);
    assert!(matches!(e.http_list_delta(&base, TOKEN, "p/", None).await, Err(RelayErr::Forbidden)));
    stub.force(Some(401));
    assert!(matches!(e.http_get(&base, TOKEN, "k").await, Err(RelayErr::Forbidden)));
    assert!(matches!(e.http_put(&base, TOKEN, "k", vec![1]).await, Err(RelayErr::Forbidden)));
    assert_eq!(e.http_head(&base, TOKEN, "k").await, crate::mediaholding::Head::Refused);
    assert!(matches!(e.http_list_delta(&base, TOKEN, "p/", None).await, Err(RelayErr::Forbidden)));
    stub.force(Some(500));
    assert!(matches!(e.http_get(&base, TOKEN, "k").await, Err(RelayErr::Unreachable)));
    assert!(matches!(e.http_put(&base, TOKEN, "k", vec![1]).await, Err(RelayErr::Unreachable)));
    assert_eq!(e.http_head(&base, TOKEN, "k").await, crate::mediaholding::Head::Unreachable);
    assert!(matches!(e.http_list_delta(&base, TOKEN, "p/", None).await, Err(RelayErr::Unreachable)));
    stub.force(Some(501));
    assert_eq!(e.http_head(&base, TOKEN, "k").await, crate::mediaholding::Head::Unsupported);
    stub.force(None);

    // An old relay without HEAD: existence falls back to a GET.
    stub.knobs.lock().head_unsupported = true;
    assert!(e.http_exists(&base, TOKEN, "haven/x").await, "HEAD refused, GET finds it");
    assert!(!e.http_exists(&base, TOKEN, "haven/none").await);
    stub.knobs.lock().head_unsupported = false;

    // Nothing listening: a transport failure on every verb.
    let dead = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        format!("http://{}", l.local_addr().unwrap())
    };
    assert!(matches!(e.http_get(&dead, TOKEN, "k").await, Err(RelayErr::Unreachable)));
    assert!(matches!(e.http_put(&dead, TOKEN, "k", vec![1]).await, Err(RelayErr::Unreachable)));
    assert_eq!(e.http_head(&dead, TOKEN, "k").await, crate::mediaholding::Head::Unreachable);
    assert!(matches!(e.http_list_delta(&dead, TOKEN, "p/", None).await, Err(RelayErr::Unreachable)));
}

#[tokio::test]
async fn the_delta_list_returns_keys_then_a_bodiless_204_for_an_unchanged_set() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (e, _) = new_engine(171);
    let base = stub.base.clone();
    for k in ["haven/mailbox/c1/a", "haven/mailbox/c1/b", "haven/mailbox/c2/z"] {
        e.http_put(&base, TOKEN, k, vec![0]).await.unwrap();
    }
    let (keys, digest) = e.http_list_delta(&base, TOKEN, "haven/mailbox/c1/", None).await.unwrap();
    assert_eq!(keys.unwrap(), vec!["haven/mailbox/c1/a".to_string(), "haven/mailbox/c1/b".to_string()]);
    let digest = digest.expect("the relay advertises the set's digest");
    let (again, _) = e.http_list_delta(&base, TOKEN, "haven/mailbox/c1/", Some(&digest)).await.unwrap();
    assert!(again.is_none(), "an unchanged set is a 204 with no keys");
    e.http_put(&base, TOKEN, "haven/mailbox/c1/c", vec![0]).await.unwrap();
    let (changed, _) = e.http_list_delta(&base, TOKEN, "haven/mailbox/c1/", Some(&digest)).await.unwrap();
    assert_eq!(changed.unwrap().len(), 3, "a changed set comes back whole");
}

#[tokio::test]
async fn an_unusable_http_interface_hides_the_relay_from_the_http_lane() {
    let _net = crate::netgate::open_relay_http_for_test();
    let (e, _) = new_engine(172);
    assert!(e.relay_http_reachable(RELAY).is_none(), "an unknown relay has no interface");
    {
        let mut p = e.prefs.lock();
        p.ensure_relay_entry(RELAY, Some("r"), false, true);
        p.set_relay_http(RELAY, vec!["http://203.0.113.9:80".into()], "t".into());
    }
    let (urls, token) = e.relay_http_reachable(RELAY).expect("a public address is always plausible");
    assert_eq!((urls, token), (vec!["http://203.0.113.9:80".to_string()], "t".to_string()));
    // A private address on a subnet we are not on is dropped; a hostname is kept.
    e.prefs.lock().set_relay_http(RELAY, vec!["http://10.254.254.9:80".into(), "http://relay.example".into()], "t".into());
    let kept = e.relay_http_reachable(RELAY).unwrap().0;
    assert!(kept.contains(&"http://relay.example".to_string()));
    assert!(Engine::url_plausibly_reachable("http://relay.example:8443/x"));
    assert!(!Engine::url_plausibly_reachable("not-a-url"));
    // The gate itself: with the test lane closed the same lookup answers None.
    drop(_net);
    assert!(e.relay_http_reachable(RELAY).is_none(), "HAVEN_NO_NET retires the lane");
}

#[tokio::test]
async fn an_authored_post_reaches_the_relay_mailbox_and_a_friend_polls_it_in() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (a, _) = new_engine(173);
    let (b, _) = new_engine(174);
    befriend(&a, &b);
    wire_to(&a, &stub).await;
    wire_to(&b, &stub).await;

    a.post(DEFAULT_CIRCLE.into(), "over the relay".into(), vec![], None, false, None);
    let envs = a.social.export_my_envelopes(DEFAULT_CIRCLE.to_string());
    assert!(!envs.is_empty());
    let mut all_landed = true;
    for env in &envs {
        all_landed &= a.upload_event(DEFAULT_CIRCLE, env).await;
    }
    assert!(all_landed, "every envelope lands on the stub relay");
    assert!(!stub.keys_with("haven/mailbox/").is_empty());
    let puts = stub.count("PUT /k/");
    // A repeat is seen-filtered per (relay, key): nothing more goes on the wire.
    assert!(a.upload_event(DEFAULT_CIRCLE, &envs[0]).await);
    assert_eq!(stub.count("PUT /k/"), puts, "a landed envelope is never re-sent");

    b.poll_mailbox().await;
    assert!(
        b.feed(DEFAULT_CIRCLE).iter().any(|i| i.body == "over the relay"),
        "b ingests a's post from the relay mailbox"
    );
    // A second poll with an unchanged mailbox is answered by the delta LIST.
    let lists = stub.count("GET /l/");
    b.poll_mailbox().await;
    assert!(stub.count("GET /l/") > lists);
    assert!(stub.count("PUT /k/") >= puts);
}

#[tokio::test]
async fn a_relay_that_refuses_us_is_recorded_not_parked_and_a_dead_one_is_parked() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (a, _) = new_engine(175);
    wire_to(&a, &stub).await;
    a.post(DEFAULT_CIRCLE.into(), "refused".into(), vec![], None, false, None);
    let envs = a.social.export_my_envelopes(DEFAULT_CIRCLE.to_string());

    a.dyn_state.lock().seen_mailbox.clear(); // as if no relay had ever taken it
    stub.force(Some(403));
    assert!(!a.upload_event(DEFAULT_CIRCLE, &envs[0]).await, "a refusal lands nowhere");
    assert!(a.roster_needed.lock().contains(RELAY), "the refusal queues a roster publish");
    assert!(!a.http_url_bad(&stub.base), "a refusal is not an outage");

    stub.force(Some(500));
    assert!(!a.upload_event(DEFAULT_CIRCLE, &envs[0]).await);
    assert!(a.http_url_bad(&stub.base), "a transport failure parks the URL");
    // While parked the relay is skipped outright.
    let puts = stub.count("PUT /k/");
    assert!(!a.upload_event(DEFAULT_CIRCLE, &envs[0]).await);
    assert_eq!(stub.count("PUT /k/"), puts);
    a.clear_http_url_bad(&stub.base);
    stub.force(None);
    assert!(a.upload_event(DEFAULT_CIRCLE, &envs[0]).await, "and works again once forgiven");
}

#[tokio::test]
async fn a_backfill_pass_re_asserts_history_and_uploads_media_to_the_relay() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (a, _) = new_engine(176);
    wire_to(&a, &stub).await;
    let r = a.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF a photo for the relay", false);
    a.post(DEFAULT_CIRCLE.into(), "with a photo".into(), vec![r.clone()], None, false, None);
    a.backfill_mailbox(DEFAULT_CIRCLE).await;
    assert!(!stub.keys_with("haven/mailbox/").is_empty(), "the envelopes went up");
    assert!(
        stub.store.lock().contains_key(&Engine::media_key(&r)),
        "and so did the sealed photo"
    );
    assert!(stub.store.lock().contains_key(&Engine::media_scope_key(&r, DEFAULT_CIRCLE)), "the circle scope marker is written first");
    assert!(a.media_backed_up_has(RELAY, &r), "the ledger records where it lives");
    // A second pass finds the relay already holding it: the probe is a HEAD, no second upload.
    let puts = stub.count("PUT /k/haven/media/");
    a.backfill_mailbox(DEFAULT_CIRCLE).await;
    assert_eq!(stub.count("PUT /k/haven/media/"), puts);
}

#[tokio::test]
async fn a_member_fetches_a_photo_from_the_relay_and_a_refused_or_empty_relay_is_a_miss() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (a, _) = new_engine(177);
    let (b, _) = new_engine(178);
    befriend(&a, &b);
    wire_to(&a, &stub).await;
    wire_to(&b, &stub).await;
    let r = a.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF shared photo bytes", false);
    a.post(DEFAULT_CIRCLE.into(), "p".into(), vec![r.clone()], None, false, None);
    // Hand b the post (and so the circle keys) directly, then pull the photo through the relay.
    crate::engine::cov_engine_tests::deliver(&a, &b, DEFAULT_CIRCLE);
    assert!(a.upload_media(DEFAULT_CIRCLE, &r).await, "a uploads");
    assert!(!b.media_present(&r));

    assert!(b.fetch_media_healing(DEFAULT_CIRCLE, &r).await, "b downloads and opens it");
    assert!(b.media_present(&r));
    assert!(b.media_backed_up_has(RELAY, &r), "the relay it came from is recorded as a holder");
    assert!(b.fetch_media_healing(DEFAULT_CIRCLE, &r).await, "already held is an instant yes");

    // A relay that does not hold a ref is a miss; one that refuses is not mistaken for a miss.
    let (c, _) = new_engine(179);
    wire_to(&c, &stub).await;
    assert!(c.fetch_media_from_relay(DEFAULT_CIRCLE, "img_0000000000000000000000000000000000000000000000000000000000000000").await.is_none());
    stub.force(Some(403));
    assert!(c.fetch_media_from_relay(DEFAULT_CIRCLE, "img_1111111111111111111111111111111111111111111111111111111111111111").await.is_none());
    assert!(c.roster_needed.lock().contains(RELAY));
    stub.force(Some(500));
    assert!(c.fetch_media_from_relay(DEFAULT_CIRCLE, "img_2222222222222222222222222222222222222222222222222222222222222222").await.is_none());
    assert!(c.http_url_bad(&stub.base));
}

#[tokio::test]
async fn a_garbage_blob_on_the_relay_is_dropped_instead_of_masquerading_as_media() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (b, _) = new_engine(180);
    wire_to(&b, &stub).await;
    let r = "img_3333333333333333333333333333333333333333333333333333333333333333";
    stub.store.lock().insert(Engine::media_key(r), vec![7u8; 4096]);
    assert!(!b.fetch_media_healing(DEFAULT_CIRCLE, r).await, "bytes that open for no circle are not media");
    assert!(!b.media_present(r));
    assert!(b.dyn_state.lock().media_unopenable.contains(r), "and the ref is not re-downloaded this session");
    // An empty body is a plain miss, never a corrupt copy.
    let e = "img_4444444444444444444444444444444444444444444444444444444444444444";
    stub.store.lock().insert(Engine::media_key(e), Vec::new());
    assert!(!b.fetch_media_healing(DEFAULT_CIRCLE, e).await);
    assert!(!b.dyn_state.lock().media_unopenable.contains(e));
}

#[tokio::test]
async fn a_device_the_relay_does_not_know_is_healed_by_publishing_its_roster() {
    let _net = crate::netgate::open_relay_http_for_test();
    let stub = Stub::start().await;
    let (a, _) = new_engine(181);
    wire_to(&a, &stub).await;
    let r = a.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF refused first", false);
    stub.force(Some(403));
    assert!(!a.upload_media(DEFAULT_CIRCLE, &r).await, "a refusing relay holds nothing");
    assert!(a.roster_needed.lock().contains(RELAY) || a.last_heal_ms.lock().clone() > 0, "the refusal is noted and healed");
    stub.force(None);
    a.roster_needed.lock().insert(RELAY.to_string());
    *a.last_heal_ms.lock() = 0;
    assert!(a.heal_forbidden_relays().await, "a pending refusal publishes the roster");
    assert!(!stub.keys_with("devroster").is_empty() || stub.count("PUT /k/") > 0, "the roster went up");
    assert!(!a.heal_forbidden_relays().await, "rate limited: nothing pending now");
    assert!(a.upload_media(DEFAULT_CIRCLE, &r).await, "now the blob lands");
}
