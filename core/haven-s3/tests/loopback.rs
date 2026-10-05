//! `S3Mailbox` against a loopback fake S3 (no network, no real account).
//!
//! The fake speaks just enough HTTP/1.1 for PUT / GET / ListObjectsV2, keeps objects in memory and
//! — crucially — RE-VERIFIES every request's SigV4 signature from the bytes that actually arrived on
//! the socket (method, raw path, raw query, host header, body). A real S3 does the same, so this
//! catches the class of bug a unit vector cannot: the client signing one canonical URI/query while
//! sending a different one (encoding drift), or signing a payload hash that is not the body's.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use haven_s3::{S3Config, S3Mailbox};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

const ACCESS: &str = "AKIDEXAMPLE";
const SECRET: &str = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
const REGION: &str = "auto";
const BUCKET: &str = "haven-test";

#[derive(Default)]
struct Fake {
    objects: BTreeMap<String, Vec<u8>>, // full object key (prefix included, decoded)
    log: Vec<String>,                   // "METHOD path?query -> status"
    fail_next: Option<u16>,
}

fn sha256_hex(b: &[u8]) -> String {
    hex::encode(Sha256::digest(b))
}

fn hmac(key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut m = Hmac::<Sha256>::new_from_slice(key).unwrap();
    m.update(msg);
    m.finalize().into_bytes().to_vec()
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).unwrap()
}

/// Independent SigV4 check of what arrived. Returns Err(reason) on mismatch.
fn verify_sigv4(method: &str, path: &str, query: &str, headers: &HashMap<String, String>, body: &[u8]) -> Result<(), String> {
    let auth = headers.get("authorization").ok_or("no authorization")?;
    let amz_date = headers.get("x-amz-date").ok_or("no x-amz-date")?;
    let content = headers.get("x-amz-content-sha256").ok_or("no x-amz-content-sha256")?;
    if *content != sha256_hex(body) {
        return Err("x-amz-content-sha256 is not the body's hash".into());
    }
    let rest = auth.strip_prefix("AWS4-HMAC-SHA256 ").ok_or("bad scheme")?;
    let mut parts = HashMap::new();
    for p in rest.split(", ") {
        let (k, v) = p.split_once('=').ok_or("bad auth part")?;
        parts.insert(k, v);
    }
    let cred = parts["Credential"];
    let (access, scope) = cred.split_once('/').ok_or("bad credential")?;
    if access != ACCESS {
        return Err("wrong access key".into());
    }
    let datestamp = &amz_date[..8];
    if scope != format!("{datestamp}/{REGION}/s3/aws4_request") {
        return Err(format!("bad scope {scope}"));
    }
    let signed: Vec<&str> = parts["SignedHeaders"].split(';').collect();
    for must in ["host", "x-amz-content-sha256", "x-amz-date"] {
        if !signed.contains(&must) {
            return Err(format!("{must} not signed"));
        }
    }
    // Canonical query: the client must send it already sorted + encoded.
    let mut q: Vec<&str> = if query.is_empty() { vec![] } else { query.split('&').collect() };
    q.sort();
    let canonical_query = q.join("&");
    let canonical_headers: String = signed.iter().map(|h| format!("{h}:{}\n", headers[*h].trim())).collect();
    let creq = format!("{method}\n{path}\n{canonical_query}\n{canonical_headers}\n{}\n{content}", signed.join(";"));
    let sts = format!("AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}", sha256_hex(creq.as_bytes()));
    let k = hmac(&hmac(&hmac(&hmac(format!("AWS4{SECRET}").as_bytes(), datestamp.as_bytes()), REGION.as_bytes()), b"s3"), b"aws4_request");
    let expect = hex::encode(hmac(&k, sts.as_bytes()));
    if parts["Signature"] != expect {
        return Err("signature mismatch".into());
    }
    Ok(())
}

async fn serve(state: Arc<Mutex<Fake>>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((sock, _)) = listener.accept().await else { return };
            let state = state.clone();
            tokio::spawn(async move {
                let (r, mut w) = sock.into_split();
                let mut r = BufReader::new(r);
                loop {
                    let mut line = String::new();
                    if r.read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    let mut it = line.trim_end().splitn(3, ' ');
                    let (method, target) = (it.next().unwrap().to_string(), it.next().unwrap_or("/").to_string());
                    let mut headers = HashMap::new();
                    loop {
                        let mut h = String::new();
                        r.read_line(&mut h).await.unwrap();
                        let h = h.trim_end();
                        if h.is_empty() {
                            break;
                        }
                        if let Some((k, v)) = h.split_once(':') {
                            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                        }
                    }
                    let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
                    let mut body = vec![0u8; len];
                    r.read_exact(&mut body).await.unwrap();
                    let (path, query) = target.split_once('?').map(|(p, q)| (p.to_string(), q.to_string())).unwrap_or((target.clone(), String::new()));

                    let (status, resp): (u16, Vec<u8>) = {
                        let mut st = state.lock().unwrap();
                        if let Some(code) = st.fail_next.take() {
                            (code, b"<Error/>".to_vec())
                        } else if let Err(why) = verify_sigv4(&method, &path, &query, &headers, &body) {
                            (403, format!("<Error><Code>SignatureDoesNotMatch</Code><Message>{why}</Message></Error>").into_bytes())
                        } else {
                            let bucket_root = format!("/{BUCKET}");
                            let key = pct_decode(path.strip_prefix(&format!("{bucket_root}/")).unwrap_or(""));
                            match method.as_str() {
                                "PUT" => {
                                    st.objects.insert(key, body.clone());
                                    (200, vec![])
                                }
                                "GET" if path == bucket_root => {
                                    let prefix = query
                                        .split('&')
                                        .find_map(|kv| kv.strip_prefix("prefix="))
                                        .map(pct_decode)
                                        .unwrap_or_default();
                                    let mut xml = String::from("<ListBucketResult>");
                                    for k in st.objects.keys().filter(|k| k.starts_with(&prefix)) {
                                        xml.push_str(&format!("<Contents><Key>{}</Key></Contents>", k.replace('&', "&amp;")));
                                    }
                                    xml.push_str("</ListBucketResult>");
                                    (200, xml.into_bytes())
                                }
                                "GET" => match st.objects.get(&key) {
                                    Some(v) => (200, v.clone()),
                                    None => (404, b"<Error><Code>NoSuchKey</Code></Error>".to_vec()),
                                },
                                _ => (405, vec![]),
                            }
                        }
                    };
                    state.lock().unwrap().log.push(format!("{method} {target} -> {status}"));
                    let head = format!("HTTP/1.1 {status} X\r\ncontent-length: {}\r\n\r\n", resp.len());
                    if w.write_all(head.as_bytes()).await.is_err() || w.write_all(&resp).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    format!("http://{addr}")
}

fn mailbox(endpoint: &str, secret: &str) -> S3Mailbox {
    S3Mailbox::new(S3Config {
        endpoint: endpoint.to_string(),
        region: REGION.into(),
        bucket: BUCKET.into(),
        access_key: ACCESS.into(),
        secret_key: secret.into(),
        prefix: "/haven/mailbox/".into(),
    })
    .unwrap()
}

#[tokio::test]
async fn put_get_list_round_trip_with_verified_signatures() {
    let state = Arc::new(Mutex::new(Fake::default()));
    let ep = serve(state.clone()).await;
    let mb = mailbox(&ep, SECRET);

    let sealed = (0..=255u8).cycle().take(70_000).collect::<Vec<u8>>();
    mb.put("circle1/alice/1", &sealed).await.unwrap();
    mb.put("circle1/alice/2", b"two").await.unwrap();
    mb.put("circle2/bob/1", b"other circle").await.unwrap();

    assert_eq!(mb.get("circle1/alice/1").await.unwrap().as_deref(), Some(&sealed[..]));
    assert!(state.lock().unwrap().objects.contains_key("haven/mailbox/circle1/alice/1"), "stored under the prefix");

    let mut keys = mb.list("circle1").await.unwrap();
    keys.sort();
    assert_eq!(keys, vec!["circle1/alice/1", "circle1/alice/2"], "keys come back relative to the prefix, other circles excluded");
    for k in &keys {
        assert!(mb.get(k).await.unwrap().is_some(), "listed keys round-trip into get");
    }
    assert!(state.lock().unwrap().log.iter().all(|l| !l.ends_with("403")), "{:?}", state.lock().unwrap().log);
}

#[tokio::test]
async fn keys_needing_percent_encoding_are_signed_as_sent() {
    let state = Arc::new(Mutex::new(Fake::default()));
    let ep = serve(state.clone()).await;
    let mb = mailbox(&ep, SECRET);
    for key in ["dm:a-b/x y/1", "c/ü+é/2", "c/a&b/3"] {
        mb.put(key, key.as_bytes()).await.unwrap_or_else(|e| panic!("put {key}: {e}"));
        assert_eq!(mb.get(key).await.unwrap().as_deref(), Some(key.as_bytes()), "{key}");
    }
    let mut listed = mb.list("c").await.unwrap();
    listed.sort();
    assert_eq!(listed, vec!["c/a&b/3", "c/ü+é/2"], "entity-escaped keys are unescaped");
}

#[tokio::test]
async fn a_missing_object_is_none_not_an_error() {
    let state = Arc::new(Mutex::new(Fake::default()));
    let ep = serve(state.clone()).await;
    assert!(mailbox(&ep, SECRET).get("nope").await.unwrap().is_none());
}

#[tokio::test]
async fn wrong_credentials_and_server_errors_surface_as_errors() {
    let state = Arc::new(Mutex::new(Fake::default()));
    let ep = serve(state.clone()).await;
    let bad = mailbox(&ep, "not-the-secret");
    assert!(bad.put("k", b"v").await.is_err(), "a 403 must not be reported as stored");
    assert!(bad.get("k").await.is_err());
    assert!(bad.list("").await.is_err());
    assert!(state.lock().unwrap().objects.is_empty());

    let good = mailbox(&ep, SECRET);
    state.lock().unwrap().fail_next = Some(500);
    assert!(good.put("k", b"v").await.is_err());
    state.lock().unwrap().fail_next = Some(503);
    assert!(good.get("k").await.is_err(), "a 5xx is not a miss");
}

#[tokio::test]
async fn an_unreachable_endpoint_is_an_error() {
    // Bind then drop: nothing is listening on this port any more.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let mb = mailbox(&format!("http://127.0.0.1:{port}"), SECRET);
    assert!(mb.put("k", b"v").await.is_err());
    assert!(mb.get("k").await.is_err());
}
