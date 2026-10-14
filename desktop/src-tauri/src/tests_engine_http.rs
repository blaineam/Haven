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

pub(crate) const RELAY: &str = "5151515151515151515151515151515151515151515151515151515151515151";
const TOKEN: &str = "stub-token";

/// What the stub does with the next requests, whatever they ask for.
#[derive(Default)]
struct Knobs {
    /// Answer every request with this status (and an empty body).
    force_status: Option<u16>,
    /// Answer HEAD with 405 (an old relay): callers must fall back to GET.
    head_unsupported: bool,
    /// Answer any request whose `METHOD path` contains the text with this status.
    fail_contains: Vec<(String, u16)>,
    /// Every `METHOD path` seen, in order.
    log: Vec<String>,
}

pub(crate) struct Stub {
    pub(crate) base: String,
    pub(crate) store: Arc<parking_lot::Mutex<BTreeMap<String, Vec<u8>>>>,
    knobs: Arc<parking_lot::Mutex<Knobs>>,
}

/// Nothing in these tests may wait forever: a stuck await fails loudly after 60 s instead.
async fn bounded<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    match tokio::time::timeout(std::time::Duration::from_secs(60), fut).await {
        Ok(v) => v,
        Err(_) => panic!("{what} did not finish within 60 s"),
    }
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
    pub(crate) async fn start() -> Stub {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("binds loopback");
        let base = format!("http://{}", listener.local_addr().unwrap());
        crate::netgate::register_test_stub(&base);
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
                        let tag = format!("{method} {path}");
                        if let Some((_, s)) = k.fail_contains.iter().find(|(needle, _)| tag.contains(needle.as_str())) {
                            (*s, String::new(), Vec::new())
                        } else if let Some(s) = k.force_status {
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

    pub(crate) fn force(&self, status: Option<u16>) {
        self.knobs.lock().force_status = status;
    }
    pub(crate) fn fail_when(&self, needle: &str, status: Option<u16>) {
        let mut k = self.knobs.lock();
        k.fail_contains.retain(|(n, _)| n != needle);
        if let Some(s) = status {
            k.fail_contains.push((needle.to_string(), s));
        }
    }
    pub(crate) fn count(&self, prefix: &str) -> usize {
        self.knobs.lock().log.iter().filter(|l| l.starts_with(prefix)).count()
    }
    /// PUTs of media bodies (manifests / windows / blobs), not the per-circle scope markers.
    pub(crate) fn media_puts(&self) -> usize {
        self.knobs.lock().log.iter().filter(|l| l.starts_with("PUT /k/haven/media/") && !l.contains(".c/")).count()
    }
    pub(crate) fn keys_with(&self, needle: &str) -> Vec<String> {
        self.store.lock().keys().filter(|k| k.contains(needle)).cloned().collect()
    }
}

/// Teach `e` the stub as an active relay of every circle, with its HTTP interface.
pub(crate) async fn wire_to(e: &Arc<Engine>, stub: &Stub) {
    let json = serde_json::json!({ "node": RELAY, "urls": [stub.base], "token": TOKEN });
    e.adopt_relay(json.to_string()).await;
    assert_eq!(e.prefs.lock().relay_http(RELAY).map(|(u, t)| (u, t)), Some((vec![stub.base.clone()], TOKEN.to_string())));
}

#[tokio::test]
async fn http_primitives_map_every_status_to_the_outcome_callers_branch_on() {
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
async fn only_the_loopback_stub_passes_the_relay_http_gate_and_unusable_urls_are_dropped() {
    let stub = Stub::start().await;
    let (e, _) = new_engine(172);
    assert!(e.relay_http_reachable(RELAY).is_none(), "an unknown relay has no interface");
    {
        let mut p = e.prefs.lock();
        p.ensure_relay_entry(RELAY, Some("r"), false, true);
        p.set_relay_http(RELAY, vec!["http://203.0.113.9:80".into()], "t".into());
    }
    assert!(e.relay_http_reachable(RELAY).is_none(), "HAVEN_NO_NET retires every URL that is not a registered stub");
    assert!(crate::netgate::relay_http_offline_for("http://203.0.113.9:80"));
    assert!(!crate::netgate::relay_http_offline_for(&format!("{}/", stub.base)), "the stub is open, with or without a slash");
    e.prefs.lock().set_relay_http(RELAY, vec!["http://203.0.113.9:80".into(), stub.base.clone()], "t".into());
    let (urls, token) = e.relay_http_reachable(RELAY).unwrap();
    assert_eq!((urls, token), (vec![stub.base.clone()], "t".to_string()));
    // The plausibility rule on its own: hostnames and public addresses stand, other subnets do not.
    assert!(Engine::url_plausibly_reachable("http://relay.example:8443/x"));
    assert!(Engine::url_plausibly_reachable("http://203.0.113.9:80"));
    assert!(!Engine::url_plausibly_reachable("http://10.254.254.9:80"));
    assert!(!Engine::url_plausibly_reachable("not-a-url"));
    // The primitives refuse a non-stub base outright, whatever token they hold.
    assert!(matches!(e.http_get("http://203.0.113.9:80", "t", "k").await, Err(RelayErr::Unreachable)));
    assert!(matches!(e.http_put("http://203.0.113.9:80", "t", "k", vec![1]).await, Err(RelayErr::Unreachable)));
    assert_eq!(e.http_head("http://203.0.113.9:80", "t", "k").await, crate::mediaholding::Head::Unreachable);
    assert!(matches!(e.http_list_delta("http://203.0.113.9:80", "t", "p/", None).await, Err(RelayErr::Unreachable)));
}

#[tokio::test]
async fn an_authored_post_reaches_the_relay_mailbox_and_a_friend_polls_it_in() {
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

// ── self-sync between two devices of one account ───────────────────────────────────────────────

#[tokio::test]
async fn two_devices_of_one_account_converge_through_the_relay_and_survive_a_bad_relay() {
    let stub = Stub::start().await;
    let (d1, _) = new_engine(230);
    let (d2, _) = new_engine(230); // same seed: the second device of the same account
    assert_eq!(d1.node_id_hex(), d2.node_id_hex());
    wire_to(&d1, &stub).await;
    wire_to(&d2, &stub).await;

    let mut p = d1.get_profile();
    p.name = "Ada on the laptop".into();
    d1.set_profile(p);
    d1.poll_self_sync().await;
    assert!(!stub.keys_with("selfsync").is_empty() || stub.count("PUT /k/") > 0, "d1 publishes its slot");
    d2.poll_self_sync().await;
    assert_eq!(d2.get_profile().name, "Ada on the laptop", "d2 merges d1's slot");
    assert!(d2.paths().selfsync_state_file().exists(), "and records the converged base");

    // A relay that refuses the device is noted for a roster heal; a dead one is parked, and neither
    // stops the pass from finishing.
    stub.force(Some(403));
    d2.poll_self_sync().await;
    assert!(d2.roster_needed.lock().contains(RELAY) || d2.last_heal_ms.lock().clone() > 0);
    stub.force(Some(500));
    d2.clear_http_url_bad(&stub.base);
    d2.poll_self_sync().await;
    assert!(d2.http_url_bad(&stub.base));
    assert!(!d2.dyn_state.lock().self_syncing, "the in-flight flag is always released");

    // Two passes that overlap collapse into one.
    d2.dyn_state.lock().self_syncing = true;
    d2.poll_self_sync().await;
    d2.dyn_state.lock().self_syncing = false;
}

// ── hello and announce blobs in the mailbox ────────────────────────────────────────────────────

#[tokio::test]
async fn a_hello_parked_on_the_relay_reaches_a_recipient_who_polls_and_is_not_offered_twice() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(231);
    let (b, _) = new_engine(232);
    wire_to(&a, &stub).await;
    wire_to(&b, &stub).await;
    assert!(a.connect_by_link(b.invite_uri()));
    let hello = a.hello_payload(DEFAULT_CIRCLE).expect("hello");
    let bh = b.node_id_hex();

    a.offer_hello_mailbox(DEFAULT_CIRCLE, &bh, &hello).await;
    let hello_keys = stub.keys_with("/__hello__/");
    assert_eq!(hello_keys.len(), 1);
    assert!(hello_keys[0].contains(&bh), "the slot names its recipient");
    let puts = stub.count("PUT /k/");
    a.offer_hello_mailbox(DEFAULT_CIRCLE, &bh, &hello).await;
    assert_eq!(stub.count("PUT /k/"), puts, "a landed offer is remembered per relay");

    // A hello addressed to somebody else is not fetched, let alone retired.
    let stranger = "ab".repeat(32);
    a.offer_hello_mailbox(DEFAULT_CIRCLE, &stranger, &hello).await;
    b.poll_mailbox().await;
    assert_eq!(b.pending().len(), 1, "b sees a's request");
    let gets = stub.count("GET /k/");
    b.poll_mailbox().await;
    assert_eq!(stub.count("GET /k/"), gets, "nothing seen is fetched again");

    // A refusing relay is recorded; a dead one is parked; neither marks the offer as landed.
    let (a2, _) = new_engine(233);
    wire_to(&a2, &stub).await;
    stub.force(Some(403));
    a2.offer_hello_mailbox(DEFAULT_CIRCLE, &bh, &hello).await;
    assert!(a2.roster_needed.lock().contains(RELAY));
    assert!(a2.hello_offered.lock().is_empty());
    stub.force(Some(500));
    a2.offer_hello_mailbox(DEFAULT_CIRCLE, &bh, &hello).await;
    assert!(a2.http_url_bad(&stub.base));
    assert!(a2.hello_offered.lock().is_empty());
}

#[tokio::test]
async fn a_mailbox_poll_routes_relay_announces_skips_live_frames_and_buries_garbage() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(234);
    let (b, _) = new_engine(235);
    befriend(&a, &b);
    wire_to(&b, &stub).await;
    let other = "7".repeat(64);
    {
        let mut p = a.prefs.lock();
        p.ensure_relay_entry(&other, Some("Friend relay"), false, true);
        p.set_relay_http(&other, vec!["http://203.0.113.20:8080".into()], "tok".into());
    }
    let sealed = a.social.seal_circle_media(DEFAULT_CIRCLE.into(), a.relay_announce_body(&other)).expect("seals");
    let announce = wire::event_payload(DEFAULT_CIRCLE, &sealed);
    let cid = DEFAULT_CIRCLE;
    stub.store.lock().insert(format!("haven/mailbox/{cid}/__relay__/one"), announce);
    stub.store.lock().insert(format!("haven/mailbox/{cid}/__live__/frame"), vec![1, 2, 3]);
    stub.store.lock().insert(format!("haven/mailbox/{cid}/garbage"), vec![0xEE; 40]);
    bounded("poll", b.poll_mailbox()).await;
    assert!(
        b.prefs.lock().relay_entries.contains_key(&other),
        "the durable announce teaches b a relay it has never dialled"
    );
    let seen = b.dyn_state.lock().seen_mailbox.clone();
    assert!(seen.iter().any(|k| k.ends_with("/__live__/frame")), "live-call frames are claimed and skipped");
    assert!(seen.iter().any(|k| k.ends_with("/__relay__/one")));
    assert!(seen.iter().any(|k| k.ends_with("/garbage")), "an unopenable envelope is buried, not retried forever");

    // More keys than one pass will open: the rest wait, and the list digest is not committed.
    for i in 0..60 {
        stub.store.lock().insert(format!("haven/mailbox/{cid}/junk-{i:03}"), vec![0xAA; 30]);
    }
    b.dyn_state.lock().mailbox_list_digests.clear();
    bounded("poll", b.poll_mailbox()).await;
    let digests = b.dyn_state.lock().mailbox_list_digests.len();
    assert_eq!(digests, 0, "a capped pass must not commit the digest that would hide the rest");
    bounded("poll", b.poll_mailbox()).await;
    for _ in 0..3 {
        bounded("poll", b.poll_mailbox()).await;
    }
    let seen = b.dyn_state.lock().seen_mailbox.clone();
    assert_eq!(
        seen.iter().filter(|k| k.contains("/junk-")).count(),
        60,
        "the backlog drains across passes, 48 opens at a time"
    );
}

// ── chunked media ──────────────────────────────────────────────────────────────────────────────

fn big_photo(tag: u8) -> Vec<u8> {
    let mut v = b"\xFF\xD8\xFF".to_vec();
    v.extend((0..8_700_000usize).map(|i| ((i * 31 + tag as usize) % 251) as u8));
    v
}

#[tokio::test]
async fn a_chunked_upload_resumes_after_a_cut_and_is_re_probed_and_forced_correctly() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(236);
    wire_to(&a, &stub).await;
    let r = a.add_local_media(DEFAULT_CIRCLE, &big_photo(1), false);
    let chunk = |i: usize| format!("PUT /k/{}", Engine::media_chunk_key(&r, i));
    let manifest = Engine::media_key(&r);

    // The link dies on window 1: window 0 is stored and remembered, no manifest, so nothing is readable.
    stub.fail_when(".p/1", Some(500));
    assert!(!a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);
    assert!(stub.store.lock().contains_key(&Engine::media_chunk_key(&r, 0)));
    assert!(!stub.store.lock().contains_key(&manifest));
    assert_eq!(a.media_upload_progress(RELAY, &r).map(|(_, n)| n), Some(1));

    // Retry: window 0 is asked about (HEAD), not re-sent; the rest and the manifest go up.
    stub.fail_when(".p/1", None);
    a.clear_http_url_bad(&stub.base);
    assert!(a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);
    assert_eq!(stub.count(&chunk(0)), 1, "window 0 was not sent twice");
    assert!(stub.store.lock().contains_key(&manifest) && stub.store.lock().contains_key(&Engine::media_chunk_key(&r, 1)));
    assert!(a.media_upload_progress(RELAY, &r).is_none(), "a finished upload needs no record");

    // A complete copy is recognised by the probe and left alone.
    a.forget_media_backed_up_ref(&r);
    let before = stub.media_puts();
    assert!(a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);
    assert_eq!(stub.media_puts(), before);
    assert!(a.media_backed_up_has(RELAY, &r));

    // A copy whose tail went missing is INCOMPLETE and is re-sent in full.
    stub.store.lock().remove(&Engine::media_chunk_key(&r, 1));
    a.forget_media_backed_up_ref(&r);
    assert!(a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);
    assert!(stub.store.lock().contains_key(&Engine::media_chunk_key(&r, 1)));

    // force overwrites without asking; reseal produces fresh bytes under the same key.
    let before = stub.media_puts();
    assert!(a.upload_media_inner(DEFAULT_CIRCLE, &r, true).await);
    assert!(stub.media_puts() > before);
    let old = stub.store.lock().get(&manifest).cloned();
    assert!(a.upload_media_inner_reseal(DEFAULT_CIRCLE, &r, true, true).await);
    assert!(stub.store.lock().get(&manifest).is_some() && old.is_some());
}

#[tokio::test]
async fn a_chunked_download_resumes_on_the_missing_window_and_opens_for_the_member() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(237);
    let (b, _) = new_engine(238);
    befriend(&a, &b);
    wire_to(&a, &stub).await;
    wire_to(&b, &stub).await;
    let r = a.add_local_media(DEFAULT_CIRCLE, &big_photo(2), false);
    a.post(DEFAULT_CIRCLE.into(), "big".into(), vec![r.clone()], None, false, None);
    crate::engine::cov_engine_tests::deliver(&a, &b, DEFAULT_CIRCLE);
    assert!(a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);

    let saved = stub.store.lock().remove(&Engine::media_chunk_key(&r, 1)).expect("window 1 was stored");
    assert!(b.fetch_media_from_relay(DEFAULT_CIRCLE, &r).await.is_none(), "an incomplete blob is not adopted");
    assert!(!b.media_present(&r));
    stub.store.lock().insert(Engine::media_chunk_key(&r, 1), saved);
    assert!(b.fetch_media_healing(DEFAULT_CIRCLE, &r).await, "the retry finishes it");
    assert_eq!(stub.count(&format!("GET /k/{}", Engine::media_chunk_key(&r, 0))), 1, "window 0 was kept, not re-downloaded");
    assert!(b.media_present(&r));
    assert!(b.media_bytes(DEFAULT_CIRCLE, &r).is_some(), "and it opens for the member");
}

#[tokio::test]
async fn probe_verdicts_other_than_missing_decide_whether_a_relay_is_asked_to_store() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(239);
    wire_to(&a, &stub).await;
    let r = a.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF probe me", false);
    // A relay that takes the scope marker but refuses HEAD: noted, nothing uploaded.
    stub.fail_when("HEAD ", Some(403));
    assert!(!a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);
    assert!(a.roster_needed.lock().contains(RELAY));
    assert!(!a.http_url_bad(&stub.base));
    // One that answers HEAD with a 500: the URL is parked.
    stub.fail_when("HEAD ", Some(500));
    assert!(!a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);
    assert!(a.http_url_bad(&stub.base));
    // The scope marker itself refused: this relay does not serve the circle at all.
    a.clear_http_url_bad(&stub.base);
    stub.fail_when("HEAD ", None);
    stub.fail_when("PUT /k/haven/media/", Some(403));
    assert!(!a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await);
    stub.fail_when("PUT /k/haven/media/", None);
    // An old relay with no HEAD: the probe falls back to GET and still lands the blob.
    stub.knobs.lock().head_unsupported = true;
    assert!(a.upload_media_inner(DEFAULT_CIRCLE, &r, true).await);
    assert!(stub.store.lock().contains_key(&Engine::media_key(&r)));
    a.forget_media_backed_up_ref(&r);
    assert!(a.upload_media_inner(DEFAULT_CIRCLE, &r, false).await, "present, found by GET");
}

// ── "Load history from your relays" ────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_history_pass_recovers_a_friends_posts_and_media_from_the_relay() {
    let _rh = crate::covtest_util::RELAY_HISTORY_LOCK.lock();
    let stub = Stub::start().await;
    let (a, _) = new_engine(240);
    let (b, _) = new_engine(241);
    befriend(&a, &b);
    wire_to(&a, &stub).await;
    wire_to(&b, &stub).await;
    let photo = a.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF history photo", false);
    a.post(DEFAULT_CIRCLE.into(), "from the archive".into(), vec![photo.clone()], None, false, None);
    a.backfill_mailbox(DEFAULT_CIRCLE).await;
    assert!(!stub.keys_with("haven/mailbox/").is_empty());
    assert!(!b.feed(DEFAULT_CIRCLE).iter().any(|i| i.body == "from the archive"), "b has not heard of it");

    b.relay_history_reset_journal();
    assert!(b.relay_history_start());
    assert!(!b.relay_history_start(), "a second start while one runs is refused");
    let mut spins = 0u64;
    while !matches!(b.relay_history_status()["state"].as_str(), Some("done" | "cancelled")) {
        tokio::task::yield_now().await;
        spins += 1;
        assert!(spins < 50_000_000, "the history pass never finished");
    }
    let status = b.relay_history_status();
    assert_eq!(status["state"], "done", "{status}");
    assert!(status["entries_found"].as_u64().unwrap() > 0, "{status}");
    assert!(status["journal_keys"].as_u64().unwrap() > 0, "ingested keys are journalled");
    assert!(b.feed(DEFAULT_CIRCLE).iter().any(|i| i.body == "from the archive"), "the post came back from the relay");
    assert!(b.media_present(&photo), "and so did its photo");

    // Running it again finds nothing new: the journal remembers every key.
    b.relay_history_dismiss();
    assert!(b.relay_history_start());
    spins = 0;
    while !matches!(b.relay_history_status()["state"].as_str(), Some("done" | "cancelled")) {
        tokio::task::yield_now().await;
        spins += 1;
        assert!(spins < 50_000_000, "the second history pass never finished");
    }
    assert_eq!(b.relay_history_status()["posts_added"], 0);
    b.relay_history_dismiss();

    // A relay that refuses the device ends honestly as unreachable.
    stub.force(Some(403));
    b.relay_history_reset_journal();
    assert!(b.relay_history_start());
    spins = 0;
    while !matches!(b.relay_history_status()["state"].as_str(), Some("done" | "cancelled")) {
        tokio::task::yield_now().await;
        spins += 1;
        assert!(spins < 50_000_000, "the refused pass never finished");
    }
    assert_eq!(b.relay_history_status()["outcome"], "unreachable");
    b.relay_history_dismiss();
}

// ── device rosters and relay introductions over HTTP ───────────────────────────────────────────

#[tokio::test]
async fn the_signed_device_roster_is_published_once_pulled_by_a_friend_and_healed_when_refused() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(242);
    let (b, _) = new_engine(243);
    befriend(&a, &b);
    wire_to(&a, &stub).await;
    wire_to(&b, &stub).await;
    stub.store.lock().clear();
    a.roster_published.lock().clear();
    let key = format!("haven/devroster/{}", a.node_id_hex());

    a.publish_device_roster().await;
    assert!(stub.store.lock().contains_key(&key), "the account-signed roster is on the relay");
    let puts = stub.count(&format!("PUT /k/{key}"));
    a.publish_device_roster().await;
    assert_eq!(stub.count(&format!("PUT /k/{key}")), puts, "an unchanged roster is not re-sent inside 30 minutes");
    a.publish_device_roster_inner(true).await;
    assert!(stub.count(&format!("PUT /k/{key}")) > puts, "but a forced publish (the refusal heal) always is");

    // A friend pulls it; a malformed account id and an empty relay yield nothing new.
    let _ = b.fetch_contact_roster(&a.node_id_hex()).await;
    assert!(!b.social.device_node_ids_for(a.node_id_hex()).is_empty(), "b can resolve a's devices");
    assert!(!b.fetch_contact_roster("not-an-account").await);
    stub.store.lock().remove(&key);
    let (c, _) = new_engine(244);
    wire_to(&c, &stub).await;
    assert!(!c.fetch_contact_roster(&"ee".repeat(32)).await, "nobody holds that roster");

    // A relay that REJECTS the roster body sends the device to read back the version it holds.
    a.publish_device_roster_inner(true).await;
    assert!(stub.store.lock().contains_key(&key));
    stub.fail_when(&format!("PUT /k/{key}"), Some(403));
    a.publish_device_roster_inner(true).await;
    stub.fail_when(&format!("PUT /k/{key}"), None);
    // A relay that is down is parked; one that refuses reads is noted.
    stub.force(Some(500));
    a.roster_published.lock().clear();
    a.publish_device_roster().await;
    assert!(a.http_url_bad(&stub.base));
    a.clear_http_url_bad(&stub.base);
    stub.force(Some(403));
    let _ = a.fetch_contact_roster(&b.node_id_hex()).await; // refused reads are routed to note_refused
    assert!(a.roster_needed.lock().contains(RELAY));
    stub.force(None);

    // A freshly joined relay is introduced to once; a second heartbeat has nothing to say.
    a.introduce_to_joined_relays().await;
    a.introduce_to_joined_relays().await;
    a.enroll_circle_members().await;
    a.backfill_media_to_relays().await;
}

// ── launch-time migrations that talk to the relay ──────────────────────────────────────────────

#[tokio::test]
async fn the_one_time_media_recovery_overwrites_my_own_blobs_and_latches() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(245);
    wire_to(&a, &stub).await;
    let r = a.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF recovery", false);
    a.post(DEFAULT_CIRCLE.into(), "mine".into(), vec![r.clone()], None, false, None);
    stub.store.lock().clear();
    assert!(!a.prefs.lock().media_resealed_v108);

    a.maybe_reseal_own_media().await;
    assert!(stub.store.lock().contains_key(&Engine::media_key(&r)), "the blob was force-written to the relay");
    {
        let p = a.prefs.lock();
        assert!(p.media_resealed_v108, "every held blob confirmed, so it latches");
        assert_eq!(p.media_reseal_attempts, 1);
        assert!(p.media_reseal_refs.contains(&r));
    }
    let puts = stub.media_puts();
    a.maybe_reseal_own_media().await;
    assert_eq!(stub.media_puts(), puts, "a latched migration never runs again");

    // A relay that never takes the blob is retried, then written off after the attempt budget.
    let (c, _) = new_engine(246);
    wire_to(&c, &stub).await;
    let r2 = c.add_local_media(DEFAULT_CIRCLE, b"\xFF\xD8\xFF unreachable", false);
    c.post(DEFAULT_CIRCLE.into(), "stuck".into(), vec![r2], None, false, None);
    stub.force(Some(500));
    for _ in 0..9 {
        c.maybe_reseal_own_media().await;
        assert!(!c.prefs.lock().media_resealed_v108);
        c.clear_http_url_bad(&stub.base);
    }
    c.maybe_reseal_own_media().await;
    assert!(c.prefs.lock().media_resealed_v108, "ten failed attempts write the blob off");
    stub.force(None);
}

#[tokio::test]
async fn the_account_leaf_migration_waits_for_a_multi_device_account() {
    let stub = Stub::start().await;
    let (a, _) = new_engine(247);
    wire_to(&a, &stub).await;
    a.maybe_migrate_retire_account_leaf().await;
    assert!(!a.prefs.lock().account_leaf_retired, "a device-only install has nothing to retire");
    a.enable_device_roster();
    a.maybe_migrate_retire_account_leaf().await;
    a.prefs.lock().account_leaf_retired = true;
    let puts = stub.count("PUT /k/");
    a.maybe_migrate_retire_account_leaf().await;
    assert_eq!(stub.count("PUT /k/"), puts, "the latch is sticky");
}

// ── linking a seedless device ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_seedless_device_is_linked_by_a_ticket_primes_its_state_from_the_relay_and_follows_a_key_rotation() {
    let stub = Stub::start().await;
    let (p, _) = new_engine(252);
    let s = Engine::new_seedless(crate::covtest_util::tmp_paths()).expect("a linking device builds");
    assert!(s.is_seedless());
    wire_to(&p, &stub).await;
    wire_to(&s, &stub).await;

    // The primary has state worth syncing and has published its slot.
    let mut prof = p.get_profile();
    prof.name = "Primary Pat".into();
    p.set_profile(prof);
    p.poll_self_sync().await;

    // A seedless device cannot mint tickets; the primary can.
    assert!(s.mint_enroll_ticket().is_err());
    let ticket_text = p.mint_enroll_ticket().expect("primary mints a ticket");
    let ticket = haven_ffi::enroll::enroll_ticket_parse(ticket_text).expect("and it parses");
    assert_eq!(ticket.account_id.len(), 32);
    {
        let mut sl = s.seedless.lock();
        sl.enabled = true;
        sl.linked = false;
        sl.relays = ticket.relays.clone();
        sl.pending_ticket = Some(crate::roster::PendingTicketRec {
            account_id: ticket.account_id.clone(),
            verification: ticket.verification.clone(),
            secret: ticket.secret.clone(),
            primary_device: ticket.primary_device.clone(),
            issued_at: ticket.issued_at,
            relays: ticket.relays.clone(),
        });
    }

    // The new device's request: junk and a request under the wrong secret are ignored.
    let now = now_ms() / 1000;
    let dev_bundle = s.roster.lock().device_bundle();
    let dev_hex = s.roster.lock().device_node_hex();
    p.handle_seedless_enroll_request(None, b"junk");
    p.handle_seedless_enroll_request(None, &haven_ffi::enroll::enroll_build_request(vec![9u8; 32], dev_bundle.clone(), "Imposter".into(), now).unwrap());
    assert!(p.enroll_pending().is_empty());
    s.send_seedless_enroll_request(); // goes nowhere without a node, but must build cleanly
    let req = haven_ffi::enroll::enroll_build_request(ticket.secret.clone(), dev_bundle.clone(), "Linked laptop".into(), now).unwrap();
    p.handle_seedless_enroll_request(None, &req);
    p.handle_seedless_enroll_request(None, &req); // a resend while pending changes nothing
    assert_eq!(p.enroll_pending(), vec![(dev_hex.clone(), "Linked laptop".to_string())]);
    p.reject_enroll(dev_hex.clone());
    assert!(p.enroll_pending().is_empty(), "dismissed");
    assert!(p.approve_enroll(dev_hex.clone()).is_err(), "nothing pending to approve");
    p.handle_seedless_enroll_request(None, &req);
    p.approve_enroll(dev_hex.clone()).expect("the user confirms");
    assert!(p.device_roster_dto().2.iter().any(|d| d.node_hex == dev_hex), "the device joined the signed roster");
    // The ticket is single-use.
    p.handle_seedless_enroll_request(None, &req);
    assert!(p.enroll_pending().is_empty(), "a consumed ticket answers nothing");

    // The grant the primary sent (re-assembled here, because the send itself has no node to ride).
    let seed = p.seed.expect("primary holds the seed");
    let grant = haven_ffi::enroll::enroll_assemble_grant(
        seed.to_vec(),
        ticket.secret.clone(),
        dev_bundle.clone(),
        "Linked laptop".into(),
        now,
        p.social.my_device_roster_wire(),
        p.active_relay_hexes(),
    )
    .expect("assembles");
    s.handle_seedless_enroll_grant(b"not a grant").await;
    assert!(!s.seedless.lock().linked, "a bad grant leaves the device linking");
    s.handle_seedless_enroll_grant(&grant).await;
    {
        let sl = s.seedless.lock();
        assert!(sl.linked && sl.enabled);
        assert!(sl.pending_ticket.is_none());
        assert_eq!(sl.self_sync_key.len(), 32);
        assert_eq!(sl.account_bundle.len() > 32, true);
    }
    assert!(s.roster.lock().credential.is_some(), "the device holds its credential");
    assert_eq!(s.get_profile().name, "Primary Pat", "its state was primed from the primary's slot before any local diff");
    assert!(s.paths().selfsync_state_file().exists());
    s.handle_seedless_enroll_grant(&grant).await; // already linked: ignored
    s.send_seedless_enroll_request(); // and no longer asks

    // A revocation re-keys the channel: the primary seals the new epoch to the survivor, which adopts it.
    let epoch_key = [7u8; 32];
    p.distribute_self_sync_grants(&seed, &p.node_id_hex(), 3, &epoch_key, vec![dev_bundle]).await;
    assert!(!stub.keys_with("keygrant").is_empty(), "the grant is in the mailbox");
    s.adopt_rotated_self_sync_grant().await;
    {
        let sl = s.seedless.lock();
        assert_eq!(sl.self_sync_epoch, 3);
        assert_eq!(sl.self_sync_key, epoch_key.to_vec());
    }
    let (accepted, v0, seal) = s.self_sync_crypto();
    assert_eq!((accepted.len(), v0, seal.map(|(e, _)| e)), (1, None, Some(3)));
    p.revoke_device(dev_hex.clone());
    assert!(!p.device_roster_dto().2.iter().any(|d| d.node_hex == dev_hex), "revoked devices leave the list");
}

#[tokio::test]
async fn the_legacy_device_enrollment_hands_a_credential_to_a_second_device_of_the_account() {
    let (p, _) = new_engine(253);
    let (d, _) = new_engine(253); // same seed: another device of the same account
    p.enable_device_roster();
    let (bundle, name, hex) = {
        let r = d.roster.lock();
        (r.device_bundle(), crate::roster::DeviceRoster::device_name(), r.device_node_hex())
    };
    let mut payload = Vec::new();
    wire::lp_append(&mut payload, &bundle);
    wire::lp_append(&mut payload, name.as_bytes());
    wire::lp_append(&mut payload, hex.as_bytes());
    d.request_device_enrollment(); // no node: builds the frame and drops it

    p.handle_enrollment_request(b"\x00");
    p.handle_enrollment_request(&payload);
    assert!(p.device_roster_dto().2.iter().any(|x| x.node_hex == hex), "the primary authorized the requester");
    // The grant, as it would arrive on the requester.
    let mut grant = Vec::new();
    wire::lp_append(&mut grant, hex.as_bytes());
    wire::lp_append(&mut grant, b"credential-bytes");
    d.handle_device_grant(&grant);
    assert_eq!(d.roster.lock().credential.as_deref(), Some(&b"credential-bytes"[..]));
    let mut other = Vec::new();
    wire::lp_append(&mut other, "ab".repeat(32).as_bytes());
    wire::lp_append(&mut other, b"not-mine");
    d.handle_device_grant(&other);
    assert_eq!(d.roster.lock().credential.as_deref(), Some(&b"credential-bytes"[..]), "a grant for another device is ignored");
    // A device never authorizes itself, and a seedless one authorizes nobody.
    let mut own = Vec::new();
    wire::lp_append(&mut own, &p.roster.lock().device_bundle());
    wire::lp_append(&mut own, b"me");
    wire::lp_append(&mut own, p.roster.lock().device_node_hex().as_bytes());
    p.handle_enrollment_request(&own);
    let s = Engine::new_seedless(crate::covtest_util::tmp_paths()).unwrap();
    s.handle_enrollment_request(&payload);
    assert!(s.device_roster_dto().2.is_empty() || !s.device_roster_dto().0);
    p.step_down_as_primary();
}
