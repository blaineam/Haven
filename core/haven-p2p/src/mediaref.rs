//! Media refs: content addresses, and the binding that makes a blob answer for its ref.
//!
//! A post's `media` array is signed, but the *bytes* behind each ref were not bound to the ref in
//! any way: refs were minted as random UUIDs on iOS, and every client opened whatever the relay
//! served under a ref and rendered it. A relay operator — always an ordinary circle member, possibly
//! running the relay on their own Pi — could take member X's sealed blob from ref A and PUT it at
//! ref B: the seal opens (X is a member, the signature verifies, GCM verifies), so X's photo renders
//! under whatever signed post referenced ref B. Silent, cryptographically undetected substitution
//! across posts, authors and circles.
//!
//! The fix is to make the ref an actual content address and to CHECK it on the way in:
//!
//!   ref = "<kind>_" + hex(sha256(PLAINTEXT))
//!
//! **Why the plaintext and not the ciphertext.** Sealing is non-deterministic — [`social::seal_bytes`]
//! draws a fresh content key and a fresh nonce per seal, and the recipient list changes with the
//! roster — so the same photo sealed twice, or sealed on two devices, or re-sealed after a member
//! joins, produces different ciphertext every time. A ciphertext address would therefore change
//! under the post that references it (orphaning media on every re-seal) and would differ per device,
//! breaking the cross-device fetch that assumes "same bytes ⇒ same ref" (this is exactly what the
//! Android/desktop stores already rely on). Hashing the plaintext gives one stable address for one
//! piece of media, forever, on every platform. The cost is that verification requires opening the
//! blob first — a substituted blob is detected after the AEAD, not before — which is fine: the
//! decrypt is work we were doing anyway, and the check is what gates *adoption*.
//!
//! The residual tradeoff, stated plainly: a plaintext hash is a confirmation oracle. A relay holding
//! a candidate photo can hash it and learn whether that exact file is the one behind a ref. It
//! cannot go the other way (no preimage), and it already holds every ref it stores, so this only
//! confirms a guess it could already make by other means (size, timing). Convergent addressing is
//! worth that; a per-circle keyed hash would close it but would break the cross-platform refs that
//! are already minted and shipped.
//!
//! **sha-256, not blake3.** Android (`LocalMedia.kt`) and desktop (`localmedia.rs`) have minted
//! sha-256 content refs since they shipped. Switching the digest would strand every ref they have
//! already published into real posts, for no security gain — sha-256's collision resistance is what
//! this needs and is not in question.
//!
//! **Legacy refs stay readable.** Real posts reference the UUID refs iOS used to mint, and those can
//! never be verified — there is nothing in `img_<uuid>` to check bytes against. So verification is
//! conditional on the ref being *verifiable* ([`is_verifiable`]): a content-addressed ref is checked
//! and a mismatch is rejected; a legacy ref is accepted as-is. Nothing breaks, and because minting
//! now only ever produces content addresses, the unverifiable population is closed and shrinks.
//! An attacker cannot downgrade into that hole: the ref comes from a signed post, so they cannot
//! swap a verifiable ref for a legacy-shaped one without forging the author's signature.

use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::Path;

/// What a ref points at. The kind rides in the ref prefix so a recipient knows how to render the
/// bytes without opening them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaKind {
    Image,
    Video,
    Audio,
    /// Zipped file/folder attachment (posts + DMs). Always a `.zip` on disk; the archive is the
    /// content-addressed unit so a folder ships as one blob.
    File,
}

impl MediaKind {
    /// The modern prefix. Matches iOS `MediaKind` and Android `LocalMedia` byte-for-byte.
    pub fn prefix(self) -> &'static str {
        match self {
            MediaKind::Image => "img_",
            MediaKind::Video => "vid_",
            MediaKind::Audio => "aud_",
            MediaKind::File => "file_",
        }
    }

    /// The kind a ref declares, or `None` for a kindless legacy ref (a bare content hash).
    pub fn of(reference: &str) -> Option<MediaKind> {
        if reference.starts_with("img_") || reference.starts_with("i:") {
            Some(MediaKind::Image)
        } else if reference.starts_with("vid_") || reference.starts_with("v:") {
            Some(MediaKind::Video)
        } else if reference.starts_with("aud_") || reference.starts_with("a:") {
            Some(MediaKind::Audio)
        } else if reference.starts_with("file_") {
            Some(MediaKind::File)
        } else {
            None
        }
    }
}

/// Every kind prefix we have ever minted, modern and legacy. The single-letter schemes are what the
/// desktop store still writes (`v:`/`a:`, bare for images) and what early Android/iOS media carries.
const PREFIXES: [&str; 7] = ["img_", "vid_", "aud_", "file_", "v:", "i:", "a:"];

/// The ref with its kind prefix stripped — the content hash, for a content-addressed ref.
///
/// NOT a storage key: this is kind-BLIND, so `img_X` and `vid_X` reduce to the same string. Storage
/// keys must stay kind-qualified (Android learned this the hard way: a kind-stripped filename let a
/// photo and a video share one file and serve each other's bytes).
pub fn bare_id(reference: &str) -> &str {
    for p in PREFIXES {
        if let Some(rest) = reference.strip_prefix(p) {
            return rest;
        }
    }
    reference
}

fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// True if `reference` is a synthetic, non-fetchable attachment (e.g. a `geo:<lat>,<lon>,<label>`
/// location pin) rather than real media bytes — a MULTI-char URI scheme, so the legacy single-letter
/// media schemes (`v:`/`i:`/`a:`) stay fetchable. Mirrors the same predicate in every client store.
pub fn is_synthetic(reference: &str) -> bool {
    reference.find(':').is_some_and(|i| i > 1)
}

/// True if `reference` is a content address we can hold bytes to account for — i.e. its bare id is a
/// sha-256 hex digest. False for the legacy UUID refs iOS minted (nothing to check against) and for
/// synthetic attachments (no bytes at all). This is the migration hinge: verifiable refs are
/// enforced, everything else is grandfathered.
pub fn is_verifiable(reference: &str) -> bool {
    !is_synthetic(reference) && is_sha256_hex(bare_id(reference))
}

/// The content address for `bytes` under `kind` — the ref to publish in a post.
pub fn mint(kind: MediaKind, bytes: &[u8]) -> String {
    format!("{}{}", kind.prefix(), sha256_hex(bytes))
}

/// [`mint`] for media already on disk, hashed in 1 MB windows so a hundreds-of-MB video never lands
/// in a buffer whole (the managed-heap trap the file→file seal path exists to avoid).
pub fn mint_file(kind: MediaKind, path: &Path) -> std::io::Result<String> {
    Ok(format!("{}{}", kind.prefix(), sha256_file_hex(path)?))
}

/// Do these bytes account for this ref?
///
/// `true` when the ref is a content address and the digest matches, and `true` when the ref is a
/// legacy ref there is nothing to check (see the module note on migration). `false` only for a
/// content-addressed ref whose bytes are NOT the bytes it names — i.e. a substitution.
pub fn verify(reference: &str, plaintext: &[u8]) -> bool {
    if !is_verifiable(reference) {
        return true; // legacy ref: unverifiable by construction, accepted read-only
    }
    // Constant-time isn't needed: both sides are public, and an attacker who could grind the
    // comparison would need a preimage anyway.
    sha256_hex(plaintext) == bare_id(reference)
}

/// [`verify`] for a plaintext file, streamed. An unreadable file fails closed.
pub fn verify_file(reference: &str, path: &Path) -> bool {
    if !is_verifiable(reference) {
        return true;
    }
    match sha256_file_hex(path) {
        Ok(h) => h == bare_id(reference),
        Err(_) => false,
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex_lower(&h.finalize())
}

fn sha256_file_hex(path: &Path) -> std::io::Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex_lower(&h.finalize()))
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mint_is_stable_and_kind_qualified() {
        let photo = b"jpeg-bytes";
        assert_eq!(mint(MediaKind::Image, photo), mint(MediaKind::Image, photo));
        // Same bytes, different kind → different ref, same hash. The kind must stay in the ref (and
        // in every storage key) or a photo and a video collide on one entry.
        let img = mint(MediaKind::Image, photo);
        let vid = mint(MediaKind::Video, photo);
        assert_ne!(img, vid);
        assert_eq!(bare_id(&img), bare_id(&vid));
    }

    #[test]
    fn mint_matches_the_refs_the_clients_already_publish() {
        // sha-256("hello") — the exact digest Android's LocalMedia.sha256Hex and desktop's
        // localmedia::sha256_hex produce. If this ever changes, every shipped ref is orphaned.
        assert_eq!(
            mint(MediaKind::Image, b"hello"),
            "img_2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn verifiable_only_for_content_addresses() {
        assert!(is_verifiable(&mint(MediaKind::Image, b"x")));
        assert!(is_verifiable(&mint(MediaKind::Video, b"x")));
        assert!(is_verifiable(&mint(MediaKind::File, b"zip-bytes")));
        assert!(mint(MediaKind::File, b"zip-bytes").starts_with("file_"));
        // Desktop's legacy single-letter scheme is a content address too.
        assert!(is_verifiable(&format!("v:{}", sha256_hex(b"x"))));
        // ...and so is a kindless bare hash (the pre-parity Android/desktop scheme).
        assert!(is_verifiable(&sha256_hex(b"x")));
        // The UUID refs iOS minted: nothing to check bytes against.
        assert!(!is_verifiable("img_7E1B4A2C-9F3D-4E5A-8B6C-1D2E3F4A5B6C"));
        // Synthetic attachments carry no bytes at all.
        assert!(!is_verifiable("geo:37.7,-122.4,Ocean Beach"));
        assert!(is_synthetic("geo:37.7,-122.4,Ocean Beach"));
        assert!(!is_synthetic("v:abc"));
        // Poster/original markers are multi-char schemes → synthetic, not fetchable.
        assert!(is_synthetic("poster:vid_abc:img_def"));
        assert!(is_synthetic("orig:vid_opt:vid_orig"));
    }

    #[test]
    fn verify_accepts_the_named_bytes_and_rejects_a_swap() {
        let alice_photo = b"ALICE-PHOTO-BYTES";
        let bob_photo = b"BOB-PHOTO-BYTES";
        let ref_a = mint(MediaKind::Image, alice_photo);
        assert!(verify(&ref_a, alice_photo));
        // The substitution the relay operator wants: different bytes under Alice's ref.
        assert!(!verify(&ref_a, bob_photo));
    }

    #[test]
    fn verify_grandfathers_legacy_uuid_refs() {
        // A real post from before content addressing. There is no digest in the ref, so any bytes
        // the relay serves are the only bytes we will ever have — accept them, or break the feed.
        let legacy = "img_7E1B4A2C-9F3D-4E5A-8B6C-1D2E3F4A5B6C";
        assert!(verify(legacy, b"whatever-bytes"));
    }

    #[test]
    fn verify_file_streams_and_fails_closed() {
        let dir = std::env::temp_dir().join(format!("havenref-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let big = vec![7u8; 3 * 1024 * 1024 + 17]; // spans several 1 MB hash windows
        let p = dir.join("blob.bin");
        std::fs::write(&p, &big).unwrap();

        let r = mint_file(MediaKind::Video, &p).unwrap();
        assert_eq!(r, mint(MediaKind::Video, &big)); // streamed == in-memory
        assert!(verify_file(&r, &p));

        std::fs::write(&p, b"swapped").unwrap();
        assert!(!verify_file(&r, &p));

        // Missing file under a verifiable ref → fail closed, never "nothing to check".
        assert!(!verify_file(&r, &dir.join("gone.bin")));
        // ...but a legacy ref has nothing to check even when the file is missing.
        assert!(verify_file("img_7E1B4A2C-9F3D-4E5A-8B6C-1D2E3F4A5B6C", &dir.join("gone.bin")));

        std::fs::remove_dir_all(&dir).ok();
    }
}
