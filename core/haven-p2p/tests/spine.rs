//! Milestone 1a proof: real hybrid-PQ identity, key establishment, and the
//! link/ticket system — all verifiable on the host with no devices or network.

use haven_p2p::crypto::{decapsulate, encapsulate_to, open, seal};
use haven_p2p::identity::{Identity, HavenId};
use haven_p2p::link::HavenLink;
use haven_p2p::transport::{select, Path};

#[test]
fn identity_sign_verify_roundtrip() {
    let id = Identity::generate();
    let pubid = id.public();
    let msg = b"post: family beach day";
    let sig = id.sign(msg);
    assert!(pubid.verify(msg, &sig).is_ok());
    assert!(pubid.verify(b"tampered", &sig).is_err());

    // A signature from a different identity must not verify.
    let other = Identity::generate();
    assert!(pubid.verify(msg, &other.sign(msg)).is_err());
}

#[test]
fn hybrid_signature_enforces_both_halves() {
    let id = Identity::generate();
    let pubid = id.public();
    let msg = b"only valid if BOTH ed25519 and ml-dsa check out";
    let good = id.sign(msg);
    assert!(pubid.verify(msg, &good).is_ok());

    // Corrupt a byte in the Ed25519 half (first 64 bytes) → must fail.
    let mut bad_ed = good.clone();
    bad_ed[10] ^= 0x01;
    assert!(pubid.verify(msg, &bad_ed).is_err(), "ed25519 half must be checked");

    // Corrupt a byte in the ML-DSA half (after byte 64) → must fail.
    let mut bad_pq = good.clone();
    let i = good.len() - 1;
    bad_pq[i] ^= 0x01;
    assert!(pubid.verify(msg, &bad_pq).is_err(), "ml-dsa half must be checked");
}

#[test]
fn identity_is_deterministic_from_seed() {
    let seed = [7u8; 32];
    let a = Identity::from_seed(&seed);
    let b = Identity::from_seed(&seed);
    assert_eq!(a.public().to_bytes(), b.public().to_bytes(), "same seed → same identity");
    assert_eq!(a.secret_seed(), seed);

    // Restoring from a generated identity's seed reproduces it exactly, and the
    // restored identity can sign in a way the original's public key verifies.
    let original = Identity::generate();
    let restored = Identity::from_seed(&original.secret_seed());
    assert_eq!(original.public().to_bytes(), restored.public().to_bytes());
    let sig = restored.sign(b"recovered device");
    assert!(original.public().verify(b"recovered device", &sig).is_ok());
}

#[test]
fn public_identity_bundle_roundtrips() {
    let id = Identity::generate();
    let pubid = id.public();
    let bytes = pubid.to_bytes();
    // ed25519(32) + x25519(32) + ml-kem-ek(1184) + ml-dsa-65-vk(1952)
    assert_eq!(bytes.len(), 32 + 32 + 1184 + 1952);
    let restored = HavenId::from_bytes(&bytes).expect("decode bundle");
    assert_eq!(restored.node_id_bytes(), pubid.node_id_bytes());
    assert_eq!(restored.verification(), pubid.verification());
}

#[test]
fn hybrid_pq_kem_agrees_then_aead_roundtrips() {
    let bob = Identity::generate();

    // A sender derives a content key *to* Bob using only Bob's public identity and a
    // fresh ephemeral key — the sender's own identity isn't needed for KEM.
    let (enc, key_a) = encapsulate_to(&bob.public()).expect("encapsulate");
    // Bob recovers the identical key from the encapsulation.
    let key_b = decapsulate(&bob, &enc).expect("decapsulate");
    assert_eq!(key_a, key_b, "both halves of the hybrid KEM must agree");

    // The key actually protects content (AES-256-GCM).
    let plaintext = b"a lossless 100GB video, conceptually";
    let sealed = seal(&key_a, plaintext);
    let opened = open(&key_b, &sealed).expect("open");
    assert_eq!(opened, plaintext);

    // A different identity cannot recover the key (so cannot open the content).
    let mallory = Identity::generate();
    let key_m = decapsulate(&mallory, &enc).expect("decapsulate runs");
    assert_ne!(key_a, key_m);
    assert!(open(&key_m, &sealed).is_err(), "wrong key must fail AEAD");

    // Tampered ciphertext must fail the GCM tag check.
    let mut bad = sealed.clone();
    *bad.last_mut().unwrap() ^= 0x01;
    assert!(open(&key_b, &bad).is_err(), "tamper must be detected");
}

#[test]
fn link_roundtrips_and_detects_tampering() {
    let id = Identity::generate();
    let pubid = id.public();
    let link = HavenLink::from_identity(&pubid);

    // Deep-link form.
    let uri = link.to_uri();
    assert!(uri.starts_with("haven://invite#"));
    assert!(uri.contains('#'));
    assert_eq!(HavenLink::parse(&uri).unwrap(), link);

    // Website form (with a subpath, as the app uses) parses to the same payload.
    let web = link.to_web("wemiller.com/apps/haven");
    assert!(web.starts_with("https://wemiller.com/apps/haven/#"));
    assert_eq!(HavenLink::parse(&web).unwrap(), link);

    // A link matches the genuine identity fetched from discovery...
    assert!(link.matches(&pubid));
    // ...but not a different identity (substituted keys = MITM).
    let other = Identity::generate().public();
    assert!(!link.matches(&other));

    // A link with no verification fragment is rejected, not trusted blindly.
    assert!(HavenLink::parse("haven://invite#AAAA").is_err());
}

#[test]
fn path_selector_prefers_local_and_protects_bulk() {
    let all = [Path::Relay, Path::Bluetooth, Path::LocalWifi];

    // Small payload: Bluetooth wins (cheapest, most private, always-on).
    assert_eq!(select(&all, false), Some(Path::Bluetooth));

    // Bulk payload: skip Bluetooth's tiny pipe, take local WiFi over relay.
    assert_eq!(select(&all, true), Some(Path::LocalWifi));

    // Only the relay is reachable: use it (last resort) — even for bulk.
    assert_eq!(select(&[Path::Relay], true), Some(Path::Relay));

    // Nothing reachable.
    assert_eq!(select(&[], false), None);
}
