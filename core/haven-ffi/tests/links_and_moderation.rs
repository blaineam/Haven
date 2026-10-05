//! Public-API coverage for the FFI surfaces the apps call directly but no other test reached:
//!
//! * reach-me links (`Account::haven_uri` / `haven_link` → `parse_link`) incl. tamper detection,
//! * relay links (`make_relay_link` / `make_relay_link_multi` → `parse_relay_link` / the JSON the
//!   relay daemon reads),
//! * the push-registration signature (the exact message the blind push worker verifies — pinned by
//!   a shared vector that `push/worker.test.mjs` verifies with WebCrypto),
//! * moderation: `block_member`, `flag_sensitive` / `sensitive_refs`, `leave_circle`,
//!   `rename_circle`.
//!
//! Everything goes through the crate's public API only, with fixed seeds and timestamps.

mod common;

use common::{account, DEFAULT_CIRCLE};
use haven_ffi::{make_relay_link, make_relay_link_multi, parse_link, parse_relay_link, Account, HavenSocial};

fn sync(from: &HavenSocial, to: &HavenSocial, cid: &str) {
    for env in from.sync_envelopes(cid.to_string()) {
        let _ = to.receive(cid.to_string(), env);
    }
}

/// Two accounts that have exchanged verified bundles in `cid` (created on both if not default).
fn pair(a: u8, b: u8, cid: &str) -> (std::sync::Arc<HavenSocial>, std::sync::Arc<HavenSocial>) {
    let x = account(a);
    let y = account(b);
    for s in [&x, &y] {
        if cid != DEFAULT_CIRCLE {
            s.create_circle(cid.into(), "Fam".into());
        }
    }
    x.add_contact_bundle(cid.into(), y.my_bundle()).unwrap();
    y.add_contact_bundle(cid.into(), x.my_bundle()).unwrap();
    (x, y)
}

// ── reach-me links ─────────────────────────────────────────────────────────────────────────────

#[test]
fn haven_uri_and_web_link_parse_back_to_the_same_identity() {
    let acct = Account::from_seed(vec![3u8; 32]).unwrap();
    let uri = acct.haven_uri();
    assert!(uri.starts_with("haven://"), "{uri}");
    let info = parse_link(uri.clone()).unwrap();
    assert_eq!(info.id_hex, acct.node_id_hex());
    assert_eq!(info.verification_hex, acct.verification_hex());
    assert_eq!(info.uri, uri, "parse→to_uri is the identity on the canonical form");

    let web = acct.haven_link("haven.example".into());
    assert!(web.starts_with("https://haven.example/"), "{web}");
    let from_web = parse_link(web).unwrap();
    assert_eq!(from_web.id_hex, acct.node_id_hex());
    assert_eq!(from_web.verification_hex, acct.verification_hex());
    assert_eq!(from_web.uri, uri, "the web form normalizes to the same haven:// link");
}

#[test]
fn a_link_with_a_tampered_fingerprint_or_garbage_is_rejected_not_panicking() {
    let acct = Account::from_seed(vec![4u8; 32]).unwrap();
    let uri = acct.haven_uri();
    let (head, frag) = uri.rsplit_once('#').expect("haven:// link carries a #fingerprint");
    // Flip one fingerprint character: still well-formed, but no longer this identity's fingerprint.
    let mut chars: Vec<char> = frag.chars().collect();
    let i = chars.len() / 2;
    chars[i] = if chars[i] == 'a' { 'b' } else { 'a' };
    let tampered = format!("{head}#{}", chars.into_iter().collect::<String>());
    assert_ne!(tampered, uri);
    match parse_link(tampered) {
        Err(_) => {}
        Ok(info) => assert_ne!(
            info.verification_hex,
            acct.verification_hex(),
            "a tampered link must never present the real identity's fingerprint"
        ),
    }
    for junk in ["", "haven://", "haven://u/", "https://example.com/", "not a link", "haven://u/zz#zz",
                 &"x".repeat(10_000), "javascript:alert(1)"] {
        assert!(parse_link(junk.to_string()).is_err(), "garbage must be an Err: {junk:.40}");
    }
}

#[test]
fn different_seeds_give_different_links_and_same_seed_is_stable() {
    let a = Account::from_seed(vec![5u8; 32]).unwrap();
    let a2 = Account::from_seed(a.secret_seed()).unwrap();
    let b = Account::from_seed(vec![6u8; 32]).unwrap();
    assert_eq!(a.haven_uri(), a2.haven_uri(), "restoring from the seed reproduces the identity");
    assert_ne!(a.haven_uri(), b.haven_uri());
    assert!(Account::from_seed(vec![1u8; 31]).is_err(), "seed must be exactly 32 bytes");
}

// ── relay links ────────────────────────────────────────────────────────────────────────────────

#[test]
fn a_single_circle_relay_link_roundtrips() {
    let m1 = "11".repeat(32);
    let m2 = "22".repeat(32);
    let link = make_relay_link("fam".into(), vec![m1.clone(), m2.clone()]);
    assert!(link.starts_with("haven-relay://circle#"));
    let info = parse_relay_link(link.clone()).expect("v1 link parses");
    assert_eq!(info.circle, "fam");
    assert_eq!(info.members, vec![m1.clone(), m2]);
    // The bare base32 payload (what a user pastes from the fragment) parses identically.
    let bare = link.rsplit_once('#').unwrap().1.to_string();
    assert_eq!(parse_relay_link(format!("  {bare}\n")).unwrap().circle, "fam");
}

#[test]
fn a_multi_circle_relay_link_grants_every_circle_and_keeps_the_first_for_old_relays() {
    let a = "aa".repeat(32);
    let b = "bb".repeat(32);
    let link = make_relay_link_multi(
        vec!["default".into(), "c1".into(), "dm:x".into()],
        vec![a.clone(), format!("{a},{b}"), format!("{b},")],
    );
    let payload = link.rsplit_once('#').unwrap().1;
    let json = data_encoding::BASE32_NOPAD.decode(payload.as_bytes()).unwrap();
    let v: serde_json::Value = serde_json::from_slice(&json).unwrap();
    assert_eq!(v["v"], 2);
    // v2 keeps the FIRST grant in c/m so an older relay binary still authorizes that circle.
    assert_eq!(v["c"], "default");
    assert_eq!(v["m"], serde_json::json!([a]));
    let g = v["g"].as_array().unwrap();
    assert_eq!(g.len(), 3, "every circle must be granted");
    assert_eq!(g[1]["c"], "c1");
    assert_eq!(g[1]["m"], serde_json::json!([a, b]));
    assert_eq!(g[2]["m"], serde_json::json!([b]), "empty comma entries are dropped");
}

#[test]
fn garbage_relay_links_are_none() {
    for junk in ["", "haven-relay://circle#", "haven-relay://circle#!!!!", "not base32 at all", "#"] {
        assert!(parse_relay_link(junk.into()).is_none(), "{junk}");
    }
    // Valid base32 + valid JSON but an unknown version.
    let v9 = data_encoding::BASE32_NOPAD.encode(br#"{"v":9,"c":"x","m":[]}"#);
    assert!(parse_relay_link(format!("haven-relay://circle#{v9}")).is_none());
}

// ── push registration signature (shared vector with push/worker.test.mjs) ───────────────────────

/// The blind push worker accepts a registration only if it carries an Ed25519 signature by the
/// node id over `haven-push-register-v1:<nodeId>:<token>:<ts>`. The worker's own test verifies
/// exactly these constants with WebCrypto, so if either side changes the message format the pair
/// of tests goes red instead of every device silently failing to register for push.
pub const PUSH_VECTOR_SEED: u8 = 0x42;
pub const PUSH_VECTOR_TOKEN: &str = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
pub const PUSH_VECTOR_TS: u64 = 1_800_000_000;
pub const PUSH_VECTOR_NODE: &str = "a2cdb6c5843e48f2b000afce44b4ba4aa83b8d2cd762d12857b1640dd90f5367";
pub const PUSH_VECTOR_SIG_B64: &str = "rnpFvI/SWgHX41JnDTwq2iaKI430QtUkANrLLUhD3j59ygsJKZyLc3ZOpap1Su8uJSKc/DsK//rejAgNn/BJAA==";

#[test]
fn push_registration_signature_matches_the_worker_vector() {
    let acct = Account::from_seed(vec![PUSH_VECTOR_SEED; 32]).unwrap();
    let sig = acct.sign_push_registration(PUSH_VECTOR_TOKEN.into(), PUSH_VECTOR_TS);
    assert_eq!(sig.len(), 64, "the worker verifies a bare 64-byte Ed25519 signature");
    let b64 = data_encoding::BASE64.encode(&sig);

    assert_eq!(acct.node_id_hex(), PUSH_VECTOR_NODE);
    assert_eq!(b64, PUSH_VECTOR_SIG_B64);
    // Bound to the token and the timestamp.
    assert_ne!(acct.sign_push_registration(PUSH_VECTOR_TOKEN.replace('a', "b"), PUSH_VECTOR_TS), sig);
    assert_ne!(acct.sign_push_registration(PUSH_VECTOR_TOKEN.into(), PUSH_VECTOR_TS + 1), sig);
}

// ── moderation ─────────────────────────────────────────────────────────────────────────────────

#[test]
fn blocking_a_member_removes_their_content_everywhere_and_new_posts_never_open() {
    let alice = account(31);
    let bob = account(32);
    let carol = account(33);
    let fam = "fam";
    for s in [&alice, &bob, &carol] {
        s.create_circle(fam.into(), "Fam".into());
    }
    for cid in [DEFAULT_CIRCLE, fam] {
        alice.add_contact_bundle(cid.into(), bob.my_bundle()).unwrap();
        alice.add_contact_bundle(cid.into(), carol.my_bundle()).unwrap();
        bob.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();
        carol.add_contact_bundle(cid.into(), alice.my_bundle()).unwrap();
    }

    bob.post(DEFAULT_CIRCLE.into(), "bob default".into(), vec![], None, None, false, false, 1_000).unwrap();
    bob.post(fam.into(), "bob fam".into(), vec![], None, None, false, false, 1_001).unwrap();
    carol.post(fam.into(), "carol fam".into(), vec![], None, None, false, false, 1_002).unwrap();
    for cid in [DEFAULT_CIRCLE, fam] {
        sync(&bob, &alice, cid);
        sync(&carol, &alice, cid);
    }
    assert_eq!(alice.feed(DEFAULT_CIRCLE.into(), 9_000, None).len(), 1);
    assert_eq!(alice.feed(fam.into(), 9_000, None).len(), 2);

    let bob_hex = bob.my_node_hex();
    alice.block_member(bob_hex.clone());

    for cid in [DEFAULT_CIRCLE, fam] {
        let feed = alice.feed(cid.into(), 9_000, None);
        assert!(feed.iter().all(|p| !p.body.starts_with("bob")), "blocked member's posts must vanish from {cid}");
    }
    assert_eq!(alice.feed(fam.into(), 9_000, None).len(), 1, "other members' posts are untouched");
    assert_eq!(alice.feed(fam.into(), 9_000, None)[0].body, "carol fam");

    // Bob keeps posting. Alice's engine no longer holds him as a member, so nothing new opens.
    bob.post(fam.into(), "after block".into(), vec![], None, None, false, false, 2_000).unwrap();
    sync(&bob, &alice, fam);
    assert!(alice.feed(fam.into(), 9_000, None).iter().all(|p| p.body != "after block"));
    assert!(alice.activity(0, 9_000).iter().all(|a| a.actor_hex != bob_hex), "nothing from Bob in the bell");

    // The block survives a persist/restore (the removal is tombstoned, not just dropped in memory).
    let restored = account(31);
    restored.import_state(alice.export_state());
    sync(&bob, &restored, fam);
    assert!(restored.feed(fam.into(), 9_000, None).iter().all(|p| !p.body.starts_with("bob") && p.body != "after block"));
}

#[test]
fn a_sensitive_flag_reaches_every_member_and_survives_restore() {
    let (alice, bob) = pair(41, 42, DEFAULT_CIRCLE);
    let cid = DEFAULT_CIRCLE.to_string();
    alice.post(cid.clone(), "pic".into(), vec!["media-ref-1".into()], None, None, false, false, 1_000).unwrap();
    sync(&alice, &bob, &cid);
    assert!(bob.sensitive_refs(cid.clone()).is_empty());

    bob.flag_sensitive(cid.clone(), "media-ref-1".into(), 1_100).unwrap();
    bob.flag_sensitive(cid.clone(), "media-ref-1".into(), 1_200).unwrap(); // a second flag dedupes
    assert_eq!(bob.sensitive_refs(cid.clone()), vec!["media-ref-1".to_string()]);

    sync(&bob, &alice, &cid);
    assert_eq!(alice.sensitive_refs(cid.clone()), vec!["media-ref-1".to_string()],
               "the author's own device must blur it too");

    let restored = account(41);
    restored.import_state(alice.export_state());
    assert_eq!(restored.sensitive_refs(cid.clone()), vec!["media-ref-1".to_string()]);

    // Flags are not feed content.
    assert_eq!(alice.feed(cid.clone(), 9_000, None).len(), 1);
    assert!(alice.sensitive_refs("no-such-circle".into()).is_empty());
}

#[test]
fn leaving_a_circle_drops_it_but_the_default_circle_cannot_be_left() {
    let (alice, bob) = pair(51, 52, "fam");
    bob.post("fam".into(), "hello".into(), vec![], None, None, false, false, 1_000).unwrap();
    sync(&bob, &alice, "fam");
    assert_eq!(alice.feed("fam".into(), 9_000, None).len(), 1);

    alice.leave_circle("fam".into());
    assert!(alice.circles().iter().all(|c| c.id != "fam"), "left circle is gone");
    assert!(alice.feed("fam".into(), 9_000, None).is_empty());

    alice.leave_circle(DEFAULT_CIRCLE.into());
    assert!(alice.circles().iter().any(|c| c.id == DEFAULT_CIRCLE), "the default circle is kept");
}

#[test]
fn renaming_a_circle_changes_only_its_name() {
    let alice = account(61);
    alice.create_circle("fam".into(), "Family".into());
    alice.rename_circle("fam".into(), "The Fam".into());
    alice.rename_circle("missing".into(), "Ghost".into()); // unknown id: no-op, no panic
    let circles = alice.circles();
    let fam = circles.iter().find(|c| c.id == "fam").unwrap();
    assert_eq!(fam.name, "The Fam");
    assert!(circles.iter().all(|c| c.id != "missing" && c.name != "Ghost"));
    // Survives persist/restore.
    let restored = account(61);
    restored.import_state(alice.export_state());
    assert_eq!(restored.circles().iter().find(|c| c.id == "fam").unwrap().name, "The Fam");
}
