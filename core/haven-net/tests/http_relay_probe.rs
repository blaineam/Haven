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

// ---- Round 2: devroster WRITE probe (audit R6) --------------------------------------------------
//
// Round 1 closed devroster READS but left the PUT ungated ("the account signature is the trust"),
// and the HTTP path never verified that signature. So a self-minted key could rename garbage over
// any account's roster over plain HTTP: `PUT /k/haven/devroster/deadbeef -> 200`. This probe drives
// that exact attack and proves it is now REFUSED, that a genuinely account-signed roster still lands
// (enrollment must keep working), and that a replayed OLDER version can't clobber a newer one.

/// The self-sync roster wire byte-for-byte as `haven-ffi::encode_roster` builds it: a
/// `TAG_DEVICE_ROSTER` byte, then `lp(account_bundle) ‖ lp(device_list) ‖ u32(n_creds)`. The relay's
/// `verify_devroster` reads the bundle + list and ignores the credential tail.
fn signed_roster(account: &SigningKeyAccount, version: u64, devices: Vec<[u8; 32]>) -> Vec<u8> {
    let dl = haven_p2p::device::DeviceList::signed(&account.0, version, 1000, devices, vec![]);
    let lp = |out: &mut Vec<u8>, b: &[u8]| {
        out.extend_from_slice(&(b.len() as u32).to_le_bytes());
        out.extend_from_slice(b);
    };
    let mut body = vec![0x04u8]; // TAG_DEVICE_ROSTER
    lp(&mut body, &account.0.public().to_bytes());
    lp(&mut body, &dl.to_bytes());
    body.extend_from_slice(&0u32.to_le_bytes()); // credentials: none
    body
}

/// Thin newtype so the helper reads cleanly.
struct SigningKeyAccount(haven_p2p::identity::Identity);

#[tokio::test]
async fn devroster_write_requires_a_valid_account_signature() {
    let dir = std::env::temp_dir().join(format!("haven-r6-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    // A victim already has a real roster on this relay. The attacker will try to destroy it.
    let victim_roster_key = "haven/devroster/deadbeef";
    let victim_path = dir.join(victim_roster_key);
    std::fs::create_dir_all(victim_path.parent().unwrap()).unwrap();
    std::fs::write(&victim_path, b"REAL-SIGNED-ROSTER").unwrap();

    let auth = Arc::new(Mutex::new(RelayAuth::default()));
    auth.lock().unwrap().authorize("fam", vec!["22".repeat(32)], vec![]);

    let srv = httprelay::serve(dir.clone(), "127.0.0.1:0", "tok".into(), auth).await.unwrap();
    let base = format!("127.0.0.1:{}", srv.port());

    // The enrolling account: signs its own account-signed roster AND signs the HTTP request with its
    // node key. It is a member of NOTHING — enrollment is exactly the case of a device the relay has
    // never heard of, so this must succeed on the signature alone.
    let account = SigningKeyAccount(haven_p2p::identity::Identity::generate());
    let account_hex: String =
        account.0.public().node_id_bytes().iter().map(|b| format!("{b:02x}")).collect();
    let account_node = account.0.node_secret_bytes();
    let dev = [5u8; 32];

    let cleanup = dir.clone();
    let out = tokio::task::spawn_blocking(move || {
        let mut log = String::new();

        // Sign an HTTP request as `node_sk`.
        let put = |node_sk: &[u8; 32], key: &str, body: &[u8]| {
            let path = format!("/k/{key}");
            let hdr = format!("Authorization: {}\r\n", auth_header(node_sk, "tok", "PUT", key, body));
            req(&base, "PUT", &path, &hdr, body)
        };

        // [ATTACK] a self-minted key, member of nothing, overwrites a stranger's roster with garbage.
        let attacker_sk = [2u8; 32];
        let poison = b"POISONED-NOT-A-SIGNED-ROSTER";
        let r = put(&attacker_sk, victim_roster_key, poison);
        log.push_str(&format!("[ATTACK ] PUT /k/{victim_roster_key} -> {}\n", status(&r)));
        assert_ne!(status(&r), 200, "R6 — a non-member destroyed a stranger's roster over HTTP");
        assert_eq!(
            std::fs::read(&victim_path).unwrap(),
            b"REAL-SIGNED-ROSTER",
            "the victim's real roster must survive the attack"
        );
        log.push_str("           victim roster on disk after: UNCHANGED (real roster intact)\n");

        // [ATTACK] fabricate a roster for an account nobody has ever published — unsigned garbage.
        let fab_key = format!("haven/devroster/{}", "00".repeat(32));
        let r = put(&attacker_sk, &fab_key, b"FABRICATED");
        log.push_str(&format!("[ATTACK ] PUT /k/{fab_key} -> {}\n", status(&r)));
        assert_ne!(status(&r), 200, "R6 — a non-member fabricated a roster over HTTP");
        assert!(!dir.join(&fab_key).exists(), "a fabricated roster must not be stored");

        // [LEGIT] the account publishes its own account-signed roster v2 → must land (enrollment).
        let key = format!("haven/devroster/{account_hex}");
        let roster_v2 = signed_roster(&account, 2, vec![dev]);
        let r = put(&account_node, &key, &roster_v2);
        log.push_str(&format!("[LEGIT  ] PUT /k/{key} (v2, account-signed) -> {}\n", status(&r)));
        assert_eq!(status(&r), 200, "a genuine account-signed enrollment roster must be accepted");
        assert_eq!(std::fs::read(dir.join(&key)).unwrap(), roster_v2, "the signed roster is stored");

        // [ROLLBACK] a validly-signed OLDER version (v1) must NOT clobber the stored v2 on disk.
        // Its listed device ids still join the auth union — the account signature vouches for them,
        // which is exactly how a late-joining linked device escapes the chicken-and-egg lockout — so
        // the PUT reports 200, but the newer blob is never downgraded. The rollback defense now
        // protects the stored BLOB, not the return code.
        let roster_v1 = signed_roster(&account, 1, vec![dev]);
        let r = put(&account_node, &key, &roster_v1);
        log.push_str(&format!("[ROLLBACK] PUT /k/{key} (v1, signed but STALE) -> {}\n", status(&r)));
        assert_eq!(status(&r), 200, "a version-losing but signed roster is accepted for the auth union");
        assert_eq!(
            std::fs::read(dir.join(&key)).unwrap(),
            roster_v2,
            "v2 must survive the rollback — the stored blob is never downgraded"
        );

        // [LEGIT] a newer version (v3) is adopted — the roster genuinely advances.
        let roster_v3 = signed_roster(&account, 3, vec![dev, [6u8; 32]]);
        let r = put(&account_node, &key, &roster_v3);
        log.push_str(&format!("[LEGIT  ] PUT /k/{key} (v3, account-signed) -> {}\n", status(&r)));
        assert_eq!(status(&r), 200, "a newer account-signed roster must be accepted");
        assert_eq!(std::fs::read(dir.join(&key)).unwrap(), roster_v3, "v3 replaces v2");

        log
    })
    .await
    .unwrap();

    println!("\n=== R6 probe: devroster writes over plain HTTP :8674 ===\n{out}");
    srv.stop();
    let _ = std::fs::remove_dir_all(&cleanup);
}
