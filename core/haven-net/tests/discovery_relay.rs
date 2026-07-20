//! **End-to-end: relay-served discovery against a real relay.**
//!
//! Everything here runs the actual HTTP relay (`httprelay::serve`) and the actual client
//! (`discovery::publish` / `discovery::resolve`) — no mocks, no hand-rolled requests. What it
//! proves is the security claim the design rests on: *a relay is a shelf, not an authority.*
//!
//!   1. A node in **no circle this relay serves** can publish and be resolved — bootstrap works,
//!      which is the whole point (a device nobody has heard of must be findable).
//!   2. A record cannot be shelved under **another node's** key. This is the impersonation
//!      defense; without it a relay could misdirect every lookup for a victim.
//!   3. A **rollback** (re-publishing an older `seq`) is refused, so a seized relay cannot pin a
//!      peer to a stale address by replaying yesterday's record.
//!   4. If the relay's stored bytes are **corrupted or swapped**, the client returns *no answer*
//!      rather than a wrong one — the relay cannot make a resolver believe anything.
//!   5. The prefix **cannot be enumerated**, so discovery does not hand the relay operator a
//!      list of every node it has ever seen on a plate.

use std::sync::{Arc, Mutex};

use haven_net::blobstore::RelayAuth;
use haven_net::discovery::{self, AddrRecord, DiscoveryConfig, DISCOVERY_PREFIX};

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn keypair(seed: u8) -> ([u8; 32], [u8; 32]) {
    let sk = ed25519_dalek::SigningKey::from_bytes(&[seed; 32]);
    (sk.to_bytes(), *sk.verifying_key().as_bytes())
}

/// Raw HTTP, for the cases where we deliberately send something the client would never send.
fn raw(base: &str, verb: &str, path: &str, auth: &str, body: &[u8]) -> String {
    use std::io::{Read, Write};
    let mut s = std::net::TcpStream::connect(base).unwrap();
    let head = format!(
        "{verb} {path} HTTP/1.1\r\nHost: x\r\nAuthorization: {auth}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    s.write_all(head.as_bytes()).unwrap();
    s.write_all(body).unwrap();
    let mut resp = Vec::new();
    s.read_to_end(&mut resp).unwrap();
    String::from_utf8_lossy(&resp).into_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn relay_is_a_shelf_not_an_authority() {
    let dir = std::env::temp_dir().join(format!("haven-disc-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    // A relay that serves ONE circle, and neither of our test nodes is in it. Discovery must still
    // work for them — that is the bootstrap requirement.
    let auth = Arc::new(Mutex::new(RelayAuth::default()));
    auth.lock().unwrap().authorize("somebody-elses-circle", vec![hex(&[1u8; 32])], vec![]);

    let srv = haven_net::httprelay::serve(dir.clone(), "127.0.0.1:0", "tok".into(), auth)
        .await
        .unwrap();
    let base = format!("127.0.0.1:{}", srv.port());

    let (alice_sk, alice_pk) = keypair(11);
    let (mallory_sk, mallory_pk) = keypair(22);
    let alice_hex = hex(&alice_pk);
    let mallory_hex = hex(&mallory_pk);

    let cfg = DiscoveryConfig {
        enabled: true,
        relays: vec![base.clone()],
        token: "tok".into(),
        read_key: Some(alice_sk),
    };

    // ── 1. bootstrap: a stranger publishes and is resolved ───────────────────────────────────
    let rec = AddrRecord::new(alice_pk, 5, vec!["relay:https://home.example".into()]);
    assert_eq!(
        discovery::publish(&cfg, &alice_sk, &rec).await,
        1,
        "a node in no circle this relay serves must still be able to publish"
    );
    let got = discovery::resolve(&cfg, &alice_hex).await.expect("resolves");
    assert_eq!(got.addrs, rec.addrs);
    assert_eq!(got.seq, 5);

    // ── 2. impersonation: Mallory cannot shelve a record under Alice's key ───────────────────
    // Mallory signs a perfectly valid record for HERSELF, then tries to store it at Alice's key.
    let forged = AddrRecord::new(mallory_pk, 999, vec!["ip:6.6.6.6:6666".into()])
        .sign(&mallory_sk)
        .unwrap();
    let key = format!("{DISCOVERY_PREFIX}{alice_hex}");
    let hdr = haven_net::httprelay::auth_header(&mallory_sk, "tok", "PUT", &key, &forged);
    let resp = raw(&base, "PUT", &format!("/k/{key}"), &hdr, &forged);
    assert!(
        resp.starts_with("HTTP/1.1 403"),
        "a record must not be storable under another node's key: {resp}"
    );
    // …and Alice's real record is untouched.
    let still = discovery::resolve(&cfg, &alice_hex).await.expect("still there");
    assert_eq!(still.addrs, rec.addrs, "the forgery must not have displaced the real record");

    // Mallory publishing under her OWN key is fine — that is not an attack, it is the protocol.
    let mine = AddrRecord::new(mallory_pk, 1, vec!["ip:5.5.5.5:5".into()]);
    assert_eq!(discovery::publish(&cfg, &mallory_sk, &mine).await, 1);
    assert_eq!(
        discovery::resolve(&cfg, &mallory_hex).await.unwrap().addrs,
        mine.addrs
    );

    // ── 3. rollback defense ──────────────────────────────────────────────────────────────────
    let older = AddrRecord::new(alice_pk, 4, vec!["ip:1.1.1.1:1".into()]);
    let body = older.sign(&alice_sk).unwrap();
    let hdr = haven_net::httprelay::auth_header(&alice_sk, "tok", "PUT", &key, &body);
    let resp = raw(&base, "PUT", &format!("/k/{key}"), &hdr, &body);
    assert!(resp.starts_with("HTTP/1.1 403"), "seq 4 must not overwrite seq 5: {resp}");
    assert_eq!(discovery::resolve(&cfg, &alice_hex).await.unwrap().seq, 5);

    // A genuinely newer publish still wins.
    let newer = AddrRecord::new(alice_pk, 6, vec!["ip:2.2.2.2:2".into()]);
    assert_eq!(discovery::publish(&cfg, &alice_sk, &newer).await, 1);
    assert_eq!(discovery::resolve(&cfg, &alice_hex).await.unwrap().seq, 6);

    // ── 4. a lying relay produces NO answer, never a wrong one ───────────────────────────────
    // Simulate a compromised operator editing the shelf directly, below the write gate.
    let path = dir.join(DISCOVERY_PREFIX).join(&alice_hex);
    // (a) Swap in Mallory's validly-signed record.
    std::fs::write(&path, &forged).unwrap();
    assert!(
        discovery::resolve(&cfg, &alice_hex).await.is_none(),
        "a valid record for the WRONG node must not resolve as Alice"
    );
    // (b) Corrupt Alice's own record.
    let mut tampered = newer.sign(&alice_sk).unwrap();
    let n = tampered.len();
    tampered[n - 70] ^= 0x01;
    std::fs::write(&path, &tampered).unwrap();
    assert!(
        discovery::resolve(&cfg, &alice_hex).await.is_none(),
        "a tampered record must not resolve"
    );

    // ── 5. the prefix is not enumerable ──────────────────────────────────────────────────────
    // LIST names a prefix, not one node key, so the discovery carve-out does not apply and the
    // ordinary membership gate refuses it. Otherwise any signed peer could dump every node the
    // relay has ever seen.
    let hdr = haven_net::httprelay::auth_header(&alice_sk, "tok", "GET", DISCOVERY_PREFIX, b"");
    let resp = raw(&base, "GET", &format!("/l/{DISCOVERY_PREFIX}"), &hdr, b"");
    assert!(
        resp.starts_with("HTTP/1.1 403"),
        "the discovery namespace must not be enumerable: {resp}"
    );

    srv.stop();
    let _ = std::fs::remove_dir_all(&dir);
}

/// The flag is the merge safety net: with `enabled: false` (the default) nothing reaches the wire.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disabled_is_completely_inert() {
    let cfg = DiscoveryConfig::default();
    let (sk, pk) = keypair(33);
    // Address is deliberately unroutable — if the flag leaked, this would hang or error, not
    // return instantly.
    let rec = AddrRecord::new(pk, 1, vec!["ip:0.0.0.0:1".into()]);
    assert_eq!(discovery::publish(&cfg, &sk, &rec).await, 0);
    assert!(discovery::resolve(&cfg, &hex(&pk)).await.is_none());
}
