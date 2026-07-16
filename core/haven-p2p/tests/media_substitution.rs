//! The media-substitution attack, and the binding that kills it.
//!
//! Setup is the ordinary one: Alice, Bob and Mallory are all members of one circle, and Mallory
//! hosts the circle's relay — on a Pi, at home, exactly as the product tells her she may. Mallory
//! therefore stores every member's sealed media and answers every member's fetch. She is not an
//! outside attacker and she breaks no crypto here.
//!
//! What she does: Alice posts photo A, Bob posts photo B. Mallory takes Bob's sealed blob and PUTs
//! it under Alice's ref. Nothing about that blob is forged — Bob really did seal it, to this circle,
//! and it opens perfectly. Alice's signed post says "here is media <ref A>"; Mallory serves Bob's
//! bytes; and every client renders Bob's photo under Alice's post.
//!
//! `swap_is_accepted_without_the_ref_check` is the attack, run against the check-free open path that
//! shipped: it passes, which is the bug. `swap_is_rejected_by_the_ref_check` runs the same swap
//! through `mediaref::verify` and it is caught. `legacy_uuid_refs_still_resolve` is the migration
//! guarantee: the UUID refs in people's existing posts keep working.

use haven_p2p::identity::Identity;
use haven_p2p::mediaref::{self, MediaKind};
use haven_p2p::social::{open_bytes, seal_bytes, Group, SealedEnvelope};

struct Circle {
    alice: Identity,
    bob: Identity,
    mallory: Identity,
}

impl Circle {
    fn new() -> Self {
        Self {
            alice: Identity::from_seed(&[1u8; 32]),
            bob: Identity::from_seed(&[2u8; 32]),
            mallory: Identity::from_seed(&[3u8; 32]),
        }
    }
    fn group(&self) -> Group {
        Group::new(
            "circle-1".to_string(),
            vec![self.alice.public(), self.bob.public(), self.mallory.public()],
        )
    }
}

/// Mallory's relay: a key→bytes map she fully controls. `put` is what an honest client calls;
/// `swap` is what she does with the same store, which is the whole point — she needs no new power.
#[derive(Default)]
struct MalloryRelay {
    blobs: std::collections::HashMap<String, Vec<u8>>,
}

impl MalloryRelay {
    fn put(&mut self, media_ref: &str, sealed: Vec<u8>) {
        self.blobs.insert(media_ref.to_string(), sealed);
    }
    fn get(&self, media_ref: &str) -> Option<Vec<u8>> {
        self.blobs.get(media_ref).cloned()
    }
    /// Serve `src`'s bytes under `dst`'s ref. One line, no crypto, no forged signature.
    fn swap(&mut self, dst: &str, src: &str) {
        let stolen = self.blobs[src].clone();
        self.blobs.insert(dst.to_string(), stolen);
    }
}

/// What every client did on fetch: open the blob, verify the seal, render whatever came out.
/// Returns the plaintext the client would put on screen under `media_ref`.
fn client_fetch_unchecked(me: &Identity, c: &Circle, relay: &MalloryRelay, media_ref: &str) -> Option<Vec<u8>> {
    let sealed = relay.get(media_ref)?;
    let env = SealedEnvelope::from_bytes(&sealed).ok()?;
    // The sender is looked up in the circle roster — exactly as `open_circle_media` does. Bob IS a
    // member, so this check passes on a swapped blob and provides no protection at all.
    let sender_hex = env.sender_hex();
    let sender = [&c.alice, &c.bob, &c.mallory]
        .into_iter()
        .map(|i| i.public())
        .find(|p| hex(&p.node_id_bytes()) == sender_hex)?;
    open_bytes(me, &sender, &env).ok()
}

/// The same fetch with the binding: bytes must account for the ref the signed post named.
fn client_fetch_verified(me: &Identity, c: &Circle, relay: &MalloryRelay, media_ref: &str) -> Option<Vec<u8>> {
    let data = client_fetch_unchecked(me, c, relay, media_ref)?;
    mediaref::verify(media_ref, &data).then_some(data)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Alice and Bob each post a photo; Mallory's relay ends up holding both, keyed by content address.
fn post_both(c: &Circle, relay: &mut MalloryRelay) -> (String, String, Vec<u8>, Vec<u8>) {
    let alice_photo = b"ALICE: the kids at the beach".to_vec();
    let bob_photo = b"BOB: a photo Alice would never post".to_vec();

    let ref_a = mediaref::mint(MediaKind::Image, &alice_photo);
    let ref_b = mediaref::mint(MediaKind::Image, &bob_photo);

    relay.put(&ref_a, seal_bytes(&c.alice, &c.group(), &alice_photo).unwrap().to_bytes());
    relay.put(&ref_b, seal_bytes(&c.bob, &c.group(), &bob_photo).unwrap().to_bytes());

    (ref_a, ref_b, alice_photo, bob_photo)
}

#[test]
fn swap_is_accepted_without_the_ref_check() {
    let c = Circle::new();
    let mut relay = MalloryRelay::default();
    let (ref_a, ref_b, alice_photo, bob_photo) = post_both(&c, &mut relay);

    // Baseline: honest relay, honest bytes.
    assert_eq!(client_fetch_unchecked(&c.bob, &c, &relay, &ref_a).as_ref(), Some(&alice_photo));

    // The attack.
    relay.swap(&ref_a, &ref_b);

    // Bob asks for the media Alice's signed post names, and is handed Bob's photo. The envelope's
    // signature verifies, the AEAD verifies, the sender is a circle member in good standing. Every
    // check the shipped code performs PASSES, and the client renders the wrong photo under Alice's
    // post. Nothing anywhere detects it. This assertion documents the break.
    let rendered = client_fetch_unchecked(&c.bob, &c, &relay, &ref_a);
    assert_eq!(
        rendered.as_ref(),
        Some(&bob_photo),
        "the substitution is accepted: every seal/roster check passes on a blob moved between refs"
    );
    assert_ne!(rendered.as_ref(), Some(&alice_photo), "and it is NOT what Alice's post pointed at");
}

#[test]
fn swap_is_rejected_by_the_ref_check() {
    let c = Circle::new();
    let mut relay = MalloryRelay::default();
    let (ref_a, ref_b, alice_photo, _bob_photo) = post_both(&c, &mut relay);

    // Honest bytes still resolve — the check must not cost us the working case.
    assert_eq!(client_fetch_verified(&c.bob, &c, &relay, &ref_a).as_ref(), Some(&alice_photo));

    relay.swap(&ref_a, &ref_b);

    // Same blob, same passing signature, same passing AEAD — and now it is refused, because Bob's
    // photo does not hash to the address Alice's post named. Mallory cannot fix this without a
    // sha-256 preimage: to serve bytes under ref A she must possess the bytes ref A names.
    assert_eq!(
        client_fetch_verified(&c.bob, &c, &relay, &ref_a),
        None,
        "substituted media must not render under a ref it does not account for"
    );

    // Bob's own post is untouched — the swap doesn't collaterally break the source ref.
    assert!(client_fetch_verified(&c.bob, &c, &relay, &ref_b).is_some());
}

#[test]
fn garbage_under_a_ref_is_rejected_not_rendered() {
    let c = Circle::new();
    let mut relay = MalloryRelay::default();
    let (ref_a, _ref_b, _a, _b) = post_both(&c, &mut relay);

    // Mallory seals her OWN bytes — she's a member, so she can — and parks them at Alice's ref.
    // This is the same attack with authored rather than stolen content: a caption-swap, a fake.
    let forgery = b"MALLORY: something that looks like Alice took it".to_vec();
    relay.put(&ref_a, seal_bytes(&c.mallory, &c.group(), &forgery).unwrap().to_bytes());

    assert_eq!(client_fetch_unchecked(&c.bob, &c, &relay, &ref_a).as_ref(), Some(&forgery),
        "unchecked: Mallory can author media into Alice's post");
    assert_eq!(client_fetch_verified(&c.bob, &c, &relay, &ref_a), None,
        "checked: she cannot, because she cannot make her bytes hash to Alice's ref");
}

#[test]
fn legacy_uuid_refs_still_resolve() {
    // The migration guarantee. Real posts out there reference refs iOS minted as random UUIDs.
    // There is no digest inside `img_<uuid>` to hold bytes to, so the ONLY options are "accept" or
    // "break every existing post's media". We accept: verification is conditional on the ref being
    // a content address, and this one isn't.
    let c = Circle::new();
    let mut relay = MalloryRelay::default();

    let legacy_ref = "img_7E1B4A2C-9F3D-4E5A-8B6C-1D2E3F4A5B6C";
    let old_photo = b"a photo posted last year, ref minted as a UUID".to_vec();
    relay.put(legacy_ref, seal_bytes(&c.alice, &c.group(), &old_photo).unwrap().to_bytes());

    assert!(!mediaref::is_verifiable(legacy_ref));
    assert_eq!(
        client_fetch_verified(&c.bob, &c, &relay, legacy_ref).as_ref(),
        Some(&old_photo),
        "legacy media must keep working — a flag day here is people's real posts going blank"
    );
}

#[test]
fn legacy_refs_cannot_be_used_to_downgrade() {
    // The obvious worry about grandfathering: can Mallory dodge the check by pointing at a legacy
    // ref? No — the media ref is a field of the AUTHOR-SIGNED post. She can serve any bytes she
    // likes under a legacy ref, but she cannot put a legacy ref into Alice's post without Alice's
    // signing key. The unverifiable population is exactly the set of refs already minted, and it
    // only shrinks: minting is content-addressed now.
    assert!(mediaref::is_verifiable(&mediaref::mint(MediaKind::Image, b"x")));
    assert!(mediaref::is_verifiable(&mediaref::mint(MediaKind::Video, b"x")));
    assert!(mediaref::is_verifiable(&mediaref::mint(MediaKind::Audio, b"x")));
}

#[test]
fn chunked_media_manifest_is_not_a_swap_point() {
    // Large media (>256 MB) rides as 8 MB chunks at `<ref>.p/<i>` under an HVCHUNK1 manifest, so the
    // manifest is the natural next place to attack: rewrite it, or swap one chunk, and reassembly
    // yields different bytes. But chunking only carries the SAME sealed envelope, and the check is
    // on the reassembled PLAINTEXT — so a tamper anywhere in the chunk set either breaks the AEAD
    // or changes the plaintext, and either way the digest doesn't land. No per-chunk hashes needed.
    let c = Circle::new();
    let big: Vec<u8> = (0..300_000u32).flat_map(|i| i.to_le_bytes()).collect();
    let ref_big = mediaref::mint(MediaKind::Video, &big);
    let sealed = seal_bytes(&c.alice, &c.group(), &big).unwrap().to_bytes();

    let chunk = 8 * 1024 * 1024;
    let chunks: Vec<Vec<u8>> = sealed.chunks(chunk).map(|c| c.to_vec()).collect();

    // Honest reassembly → verifies.
    let whole: Vec<u8> = chunks.concat();
    let env = SealedEnvelope::from_bytes(&whole).unwrap();
    let opened = open_bytes(&c.bob, &c.alice.public(), &env).unwrap();
    assert!(mediaref::verify(&ref_big, &opened));

    // Mallory flips one byte deep inside a chunk. The AEAD catches this one...
    let mut tampered = chunks.clone();
    let last = tampered.len() - 1;
    let n = tampered[last].len();
    tampered[last][n / 2] ^= 0xff;
    let whole = tampered.concat();
    let opened = SealedEnvelope::from_bytes(&whole)
        .ok()
        .and_then(|e| open_bytes(&c.bob, &c.alice.public(), &e).ok());
    // ...and if it ever didn't, the ref check is the backstop that has to hold.
    match opened {
        None => {}
        Some(data) => assert!(!mediaref::verify(&ref_big, &data), "tampered chunk must not verify"),
    }
}
