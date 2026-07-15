//! The security audit's F2/F4 probe, as a permanent regression test.
//!
//! Scenario: a caller who is a member of NO circle points the audit's probe at the DEFAULT media
//! transport — plain HTTP on :8674 — and tries to enumerate every circle, read another circle's
//! blob, and write into its mailbox. Every line returned 200 before the fix.
//!
//! The probe runs in three passes, because "the attack fails" and "the product still works" are
//! both claims that need proving:
//!
//!   1. the ORIGINAL attacker — holds the shared relay token, nothing else,
//!   2. the UPGRADED attacker — a real identity, correctly signing, also holding the token, i.e.
//!      the strongest caller who is still not a member (this is the case the fix actually turns on:
//!      pass 1 could be defeated by any authentication, pass 2 only by authorization),
//!   3. a real MEMBER — must be served normally.

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use ed25519_dalek::SigningKey;
use haven_net::blobstore::RelayAuth;
use haven_net::httprelay::{self, auth_header};

/// The audit's four requests, run against the relay as whoever `hdr` makes us.
const PROBE: [(&str, &str, &[u8]); 4] = [
    ("GET", "/l/haven", b""),
    ("GET", "/k/haven/mailbox/secretclub/bbbb", b""),
    ("PUT", "/k/haven/mailbox/secretclub/injected", b"INJECTED"),
    ("GET", "/l/haven/devroster", b""),
];

/// Raw HTTP/1.1 client — keeps the probe dependency-free and byte-exact.
fn req(base: &str, verb: &str, path: &str, auth: &str, body: &[u8]) -> String {
    let mut s = std::net::TcpStream::connect(base).unwrap();
    let head = format!(
        "{verb} {path} HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    s.write_all(head.as_bytes()).unwrap();
    s.write_all(body).unwrap();
    let mut resp = Vec::new();
    s.read_to_end(&mut resp).unwrap();
    String::from_utf8_lossy(&resp).into_owned()
}

fn status(r: &str) -> u16 {
    r.split_whitespace().nth(1).and_then(|c| c.parse().ok()).unwrap_or(0)
}

fn body(r: &str) -> String {
    r.split_once("\r\n\r\n").map(|(_, b)| b.to_string()).unwrap_or_default()
}

#[tokio::test]
async fn audit_probe_is_refused_and_members_still_served() {
    let dir = std::env::temp_dir().join(format!("haven-probe-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    // Populate the store the way a real co-tenant relay looks: two strangers' circles sharing one
    // relay (the whole point of the community-relay model) + a device roster.
    for (k, v) in [
        ("haven/devroster/deadbeef", &b"ROSTER"[..]),
        ("haven/mailbox/fam/aaaa", &b"SEALED-fam-post"[..]),
        ("haven/mailbox/secretclub/bbbb", &b"SEALED-secretclub-post"[..]),
    ] {
        let p = dir.join(k);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, v).unwrap();
    }

    let secretclub_sk = [1u8; 32];
    let attacker_sk = [2u8; 32];
    let vk = |sk: &[u8; 32]| {
        SigningKey::from_bytes(sk).verifying_key().as_bytes().iter().map(|b| format!("{b:02x}")).collect::<String>()
    };

    // The relay serves `secretclub` for a member the probe is not, and `fam` for someone else.
    let auth = Arc::new(Mutex::new(RelayAuth::default()));
    auth.lock().unwrap().authorize("secretclub", vec![vk(&secretclub_sk)], vec![]);
    auth.lock().unwrap().authorize("fam", vec!["22".repeat(32)], vec![]);

    let srv = httprelay::serve(dir.clone(), "127.0.0.1:0", "tok".into(), auth).await.unwrap();
    let base = format!("127.0.0.1:{}", srv.port());

    let out = tokio::task::spawn_blocking(move || {
        let mut log = String::new();
        let mut run = |title: &str, hdr: &dyn Fn(&str, &str, &[u8]) -> String, want_ok: bool| {
            log.push_str(&format!("\n{title}\n"));
            for (verb, path, b) in PROBE {
                let r = req(&base, verb, path, &hdr(verb, path, b), b);
                let got = status(&r);
                log.push_str(&format!("  {verb} {path:<40} → {got}  {}\n", body(&r).replace('\n', " | ")));
                if want_ok {
                    assert_eq!(got, 200, "REGRESSION — a member was refused {verb} {path}");
                } else {
                    assert_ne!(got, 200, "PROBE SUCCEEDED — a non-member reached {verb} {path}");
                }
            }
        };

        // 1. The auditor's original attacker: the shared token and nothing else.
        run("[1] non-member, holding only the relay's shared token:", &|_, _, _| "Authorization: Bearer tok\r\n".into(), false);

        // 2. The same attacker upgraded to the signed protocol: a valid identity, a valid
        //    signature, and the token — everything except membership.
        let signed = |sk: [u8; 32]| {
            move |verb: &str, path: &str, b: &[u8]| {
                let key = path.splitn(3, '/').nth(2).unwrap_or("");
                format!("Authorization: {}\r\n", auth_header(&sk, "tok", verb, key, b))
            }
        };
        run("[2] non-member, correctly signed + holding the token:", &signed(attacker_sk), false);

        assert!(!dir.join("haven/mailbox/secretclub/injected").exists(), "a non-member wrote a blob");

        // 3. The legitimate path: secretclub's own member, doing the same four things to their
        //    own circle. Anything but 200 here means the fix broke media for real users.
        log.push_str("\n[3] secretclub's OWN member, same four requests:\n");
        let member = signed(secretclub_sk);
        for (verb, path, b) in [
            ("GET", "/l/haven/mailbox/secretclub/", &b""[..]),
            ("GET", "/k/haven/mailbox/secretclub/bbbb", &b""[..]),
            ("PUT", "/k/haven/mailbox/secretclub/mine", &b"SEALED-mine"[..]),
            ("GET", "/k/haven/devroster/deadbeef", &b""[..]),
        ] {
            let r = req(&base, verb, path, &member(verb, path, b), b);
            log.push_str(&format!("  {verb} {path:<40} → {}  {}\n", status(&r), body(&r).replace('\n', " | ")));
            assert_eq!(status(&r), 200, "REGRESSION — secretclub's member was refused {verb} {path}");
        }
        log
    })
    .await
    .unwrap();

    println!("\n=== audit probe: the default media transport (plain HTTP :8674) ==={out}");
    srv.stop();
}
