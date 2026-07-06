//! Hybrid post-quantum key establishment + authenticated encryption.
//!
//! ## Why hybrid
//! A relay (or any network observer) can store ciphertext today and try to decrypt
//! it years from now once quantum computers exist — "harvest now, decrypt later".
//! We defeat that by deriving every content key from **two** independent shared
//! secrets and mixing them with HKDF:
//!   * `X25519`  — classical ECDH (fast, battle-tested)
//!   * `ML-KEM-768` — post-quantum KEM (FIPS 203)
//!
//! Mixing means an attacker must break **both** to learn the key, so we are never
//! weaker than classical even if one primitive is later found flawed. This mirrors
//! Signal's PQXDH and Apple's iMessage PQ3.
//!
//! Symmetric encryption is `AES-256-GCM`, which is already quantum-resistant
//! (Grover only halves the effective key length: 256 → 128 bits).
//!
//! NOTE: in this first increment the post-quantum ciphertext is carried as raw
//! bytes inside [`Encapsulation`]; the classical ephemeral key as 32 bytes. Wiring
//! these into the on-wire framing happens with the transport layer.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use hkdf::Hkdf;
use ml_kem::kem::{Decapsulate, Encapsulate};
use ml_kem::EncodedSizeUser;
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey as XPublicKey};

use crate::identity::{Identity, HavenId};
use crate::{CoreError, Result};

/// ML-KEM-768 ciphertext as a fixed-size byte array type.
type PqCiphertext = ml_kem::Ciphertext<ml_kem::MlKem768>;

/// The material the sender transmits so the recipient can derive the same key.
/// Opaque to any relay; reveals nothing without the recipient's private keys.
pub struct Encapsulation {
    /// Sender's ephemeral X25519 public key (classical half).
    pub eph_x_pub: [u8; 32],
    /// ML-KEM-768 ciphertext (post-quantum half), 1088 bytes.
    pub pq_ct: Vec<u8>,
}

/// Derive a fresh 32-byte content key *to* a recipient, returning the key plus the
/// [`Encapsulation`] the recipient needs to derive the same key. Sender side.
pub fn encapsulate_to(recipient: &HavenId) -> Result<(Encapsulation, [u8; 32])> {
    let mut rng = OsRng;

    // Classical: ephemeral ECDH against the recipient's static X25519 key.
    let eph = EphemeralSecret::random_from_rng(&mut rng);
    let eph_pub = XPublicKey::from(&eph);
    let dh = eph.diffie_hellman(&recipient.kem_x);

    // Post-quantum: encapsulate against the recipient's ML-KEM key.
    let (ct, ss_pq) = recipient
        .kem_pq
        .encapsulate(&mut rng)
        .map_err(|_| CoreError::Crypto("ml-kem encapsulate failed"))?;

    let recip_pq = recipient.kem_pq.as_bytes();
    let transcript = kem_transcript(
        &eph_pub.to_bytes(),
        &ct[..],
        recipient.kem_x.as_bytes(),
        &recip_pq[..],
    );
    let key = combine(dh.as_bytes(), &ss_pq, &transcript);
    let enc = Encapsulation {
        eph_x_pub: eph_pub.to_bytes(),
        pq_ct: ct[..].to_vec(),
    };
    Ok((enc, key))
}

/// Recover the same 32-byte content key from an [`Encapsulation`]. Recipient side.
pub fn decapsulate(identity: &Identity, enc: &Encapsulation) -> Result<[u8; 32]> {
    let eph_pub = XPublicKey::from(enc.eph_x_pub);
    let dh = identity.kem_x_secret().diffie_hellman(&eph_pub);

    let ct = PqCiphertext::try_from(&enc.pq_ct[..])
        .map_err(|_| CoreError::Crypto("malformed ml-kem ciphertext"))?;
    let ss_pq = identity
        .kem_pq_decap()
        .decapsulate(&ct)
        .map_err(|_| CoreError::Crypto("ml-kem decapsulate failed"))?;

    // I am the recipient — rebuild the same transcript from my public keys + the carried encapsulation.
    let me = identity.public();
    let my_pq = me.kem_pq.as_bytes();
    let transcript = kem_transcript(
        &enc.eph_x_pub,
        &enc.pq_ct,
        me.kem_x.as_bytes(),
        &my_pq[..],
    );
    Ok(combine(dh.as_bytes(), &ss_pq, &transcript))
}

/// HKDF-SHA256 over (classical-dh ‖ pq-shared), domain-separated, with the full KEM **transcript**
/// folded into the `info` (audit H1): the ephemeral key, the PQ ciphertext, and the recipient's two
/// public keys. Binding the transcript gives implicit key confirmation and blocks unknown-key-share /
/// ciphertext-substitution attacks (PQXDH/PQ3-style). Knowing the key requires breaking *both* halves.
fn combine(dh: &[u8], pq: &[u8], transcript: &[u8]) -> [u8; 32] {
    let mut ikm = Vec::with_capacity(dh.len() + pq.len());
    ikm.extend_from_slice(dh);
    ikm.extend_from_slice(pq);
    // v2 salt marks the transcript-bound derivation (a clean break from the unbound v1).
    let hk = Hkdf::<Sha256>::new(Some(b"haven-hybrid-kem-v2"), &ikm);
    let mut info = Vec::with_capacity(16 + transcript.len());
    info.extend_from_slice(b"content-aead-key");
    info.extend_from_slice(transcript);
    let mut okm = [0u8; 32];
    hk.expand(&info, &mut okm)
        .expect("32 is a valid HKDF length");
    okm
}

/// The KEM transcript both sides bind into the derived key: ephemeral X25519 pub ‖ ML-KEM ciphertext
/// ‖ recipient X25519 pub ‖ recipient ML-KEM pub.
fn kem_transcript(eph_x_pub: &[u8], pq_ct: &[u8], recip_kem_x: &[u8], recip_kem_pq: &[u8]) -> Vec<u8> {
    let mut t = Vec::with_capacity(eph_x_pub.len() + pq_ct.len() + recip_kem_x.len() + recip_kem_pq.len());
    t.extend_from_slice(eph_x_pub);
    t.extend_from_slice(pq_ct);
    t.extend_from_slice(recip_kem_x);
    t.extend_from_slice(recip_kem_pq);
    t
}

/// AES-256-GCM seal. A random 12-byte nonce is generated and prepended to the
/// ciphertext: output = nonce(12) ‖ ciphertext ‖ tag(16).
pub fn seal(key: &[u8; 32], plaintext: &[u8]) -> Vec<u8> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .expect("AES-GCM encryption is infallible for valid keys");
    let mut out = Vec::with_capacity(12 + ct.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    out
}

/// AES-256-GCM seal with the nonce DERIVED from the key instead of random, so sealing the same
/// plaintext under the same key is byte-for-byte reproducible. Output layout is identical to
/// [`seal`] (nonce(12) ‖ ciphertext ‖ tag(16)), so [`open`] reads both interchangeably.
///
/// SAFETY: only sound when the key is unique per distinct plaintext — a (key, nonce) pair must
/// never encrypt two different messages. The epoch event path guarantees this by deriving the
/// event key from a salt that itself binds the plaintext hash (see `seal_event_in_epoch`), so an
/// edited event gets a fresh key + nonce while an identical re-seal reproduces the same bytes.
/// The reproducibility is what makes content-addressed mailbox keys stable: a re-sealed event
/// dedupes on the relay instead of accumulating a new copy per backfill.
pub fn seal_reproducible(key: &[u8; 32], plaintext: &[u8]) -> Vec<u8> {
    let mut h = blake3::Hasher::new();
    h.update(b"haven-derived-nonce-v1");
    h.update(key);
    let nonce: [u8; 12] = h.finalize().as_bytes()[..12].try_into().expect("12 bytes");
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .expect("AES-GCM encryption is infallible for valid keys");
    let mut out = Vec::with_capacity(12 + ct.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    out
}

/// Inverse of [`seal`]. Fails if the data was tampered with (GCM tag mismatch).
pub fn open(key: &[u8; 32], sealed: &[u8]) -> Result<Vec<u8>> {
    if sealed.len() < 12 + 16 {
        return Err(CoreError::Crypto("sealed payload too short"));
    }
    let (nonce, ct) = sealed.split_at(12);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher
        .decrypt(Nonce::from_slice(nonce), ct)
        .map_err(|_| CoreError::Crypto("AEAD open failed (tampered or wrong key)"))
}
