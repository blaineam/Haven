//! On-device identity. No phone number, no email, no PII — an account is a keypair.
//!
//! An identity bundles, with **hybrid post-quantum** signing and key exchange:
//!   * **Ed25519 + ML-DSA-65** signing keys — long-term identity & message
//!     authentication. Both must verify, so a forger must break classical *and*
//!     post-quantum signatures. The Ed25519 public half doubles as the compact
//!     routable node id ([`HavenId::node_id_bytes`]).
//!   * an **X25519** static secret — the classical half of the hybrid KEM.
//!   * an **ML-KEM-768** decapsulation key — the post-quantum half of the KEM.
//!
//! The Ed25519 key is the stable, compact public address that goes in links/QRs.
//! The bulky post-quantum public keys travel via discovery (a signed DHT record
//! keyed by the Ed25519 id), and a short hash of the full bundle
//! ([`HavenId::verification`]) lets a dialer detect tampering once fetched.

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use hkdf::Hkdf;
use ml_dsa::{
    EncodedSignature, EncodedVerifyingKey, Keypair as _, MlDsa65, Signature as DsaSignature,
    Signer as _, SigningKey as DsaSigningKey, Verifier as _, VerifyingKey as DsaVerifyingKey, B32,
};
use ml_kem::{Encoded, EncodedSizeUser, KemCore, MlKem768};
use rand::rngs::OsRng;
use rand::{RngCore, SeedableRng};
use rand_chacha::ChaCha20Rng;
use sha2::Sha256;
use x25519_dalek::{PublicKey as XPublicKey, StaticSecret as XStaticSecret};

use crate::{CoreError, Result};

/// Concrete ML-KEM-768 key types (the trait exposes them as associated types).
pub(crate) type EncapKey = <MlKem768 as KemCore>::EncapsulationKey;
pub(crate) type DecapKey = <MlKem768 as KemCore>::DecapsulationKey;

const ED_VK_LEN: usize = 32;
const X_LEN: usize = 32;
const MLKEM_EK_LEN: usize = 1184;
/// Fixed-size prefix before the (large) ML-DSA verifying key in the serialized bundle.
const PREFIX_LEN: usize = ED_VK_LEN + X_LEN + MLKEM_EK_LEN;
/// Ed25519 signature length; the hybrid signature is this followed by the ML-DSA sig.
const ED_SIG_LEN: usize = 64;

/// The public, shareable identity of a peer.
#[derive(Clone)]
pub struct HavenId {
    /// Ed25519 verifying key — also the 32-byte routable node id.
    pub signing: VerifyingKey,
    /// ML-DSA-65 verifying key — the post-quantum half of the hybrid signature.
    pub sig_pq: DsaVerifyingKey<MlDsa65>,
    /// X25519 public — classical half of the hybrid KEM.
    pub kem_x: XPublicKey,
    /// ML-KEM-768 encapsulation key — post-quantum half of the hybrid KEM.
    pub kem_pq: EncapKey,
}

impl HavenId {
    /// The 32-byte routable id (Ed25519 public key). Stable for the life of the
    /// identity; this is what a `haven://u/<id>` link encodes.
    pub fn node_id_bytes(&self) -> [u8; 32] {
        self.signing.to_bytes()
    }

    /// A short, order-independent fingerprint of the *entire* hybrid public bundle.
    /// Carried in a link's `#fragment` so a dialer can confirm the keys fetched from
    /// discovery match the keys the link's author intended (tamper / MITM check).
    pub fn verification(&self) -> [u8; 16] {
        let ek = self.kem_pq.as_bytes();
        let sig_vk = self.sig_pq.encode();
        let mut h = blake3::Hasher::new();
        h.update(b"haven-id-v1");
        h.update(&self.signing.to_bytes());
        h.update(&sig_vk[..]);
        h.update(self.kem_x.as_bytes());
        h.update(&ek[..]);
        let full = h.finalize();
        let mut out = [0u8; 16];
        out.copy_from_slice(&full.as_bytes()[..16]);
        out
    }

    /// Verify a **hybrid** signature: both Ed25519 and ML-DSA must check out.
    /// Layout: `ed25519(64) ‖ ml-dsa-65(rest)`.
    pub fn verify(&self, msg: &[u8], sig: &[u8]) -> Result<()> {
        if sig.len() <= ED_SIG_LEN {
            return Err(CoreError::Crypto("hybrid signature too short"));
        }
        let (ed_part, dsa_part) = sig.split_at(ED_SIG_LEN);

        let ed_sig = ed25519_dalek::Signature::from_slice(ed_part)
            .map_err(|_| CoreError::Crypto("bad ed25519 signature length"))?;
        self.signing
            .verify(msg, &ed_sig)
            .map_err(|_| CoreError::Crypto("ed25519 verification failed"))?;

        let enc = EncodedSignature::<MlDsa65>::try_from(dsa_part)
            .map_err(|_| CoreError::Crypto("bad ml-dsa signature length"))?;
        let dsa_sig = DsaSignature::<MlDsa65>::decode(&enc)
            .ok_or(CoreError::Crypto("malformed ml-dsa signature"))?;
        self.sig_pq
            .verify(msg, &dsa_sig)
            .map_err(|_| CoreError::Crypto("ml-dsa verification failed"))?;
        Ok(())
    }

    /// Serialize the full public bundle (for publishing to discovery).
    /// Layout: ed25519(32) ‖ x25519(32) ‖ ml-kem-ek(1184) ‖ ml-dsa-vk(rest).
    pub fn to_bytes(&self) -> Vec<u8> {
        let ek = self.kem_pq.as_bytes();
        let sig_vk = self.sig_pq.encode();
        let mut v = Vec::with_capacity(PREFIX_LEN + sig_vk.len());
        v.extend_from_slice(&self.signing.to_bytes());
        v.extend_from_slice(self.kem_x.as_bytes());
        v.extend_from_slice(&ek[..]);
        v.extend_from_slice(&sig_vk[..]);
        v
    }

    /// Inverse of [`HavenId::to_bytes`].
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        if b.len() <= PREFIX_LEN {
            return Err(CoreError::Encoding("identity bundle too short"));
        }
        let signing = VerifyingKey::from_bytes(b[..ED_VK_LEN].try_into().unwrap())
            .map_err(|_| CoreError::Crypto("bad ed25519 key"))?;
        let kem_x = XPublicKey::from(<[u8; 32]>::try_from(&b[ED_VK_LEN..ED_VK_LEN + X_LEN]).unwrap());
        let ek_encoded = Encoded::<EncapKey>::try_from(&b[ED_VK_LEN + X_LEN..PREFIX_LEN])
            .map_err(|_| CoreError::Crypto("bad ml-kem key length"))?;
        let kem_pq = EncapKey::from_bytes(&ek_encoded);
        let sig_encoded = EncodedVerifyingKey::<MlDsa65>::try_from(&b[PREFIX_LEN..])
            .map_err(|_| CoreError::Crypto("bad ml-dsa key length"))?;
        let sig_pq = DsaVerifyingKey::<MlDsa65>::decode(&sig_encoded);
        Ok(Self { signing, sig_pq, kem_x, kem_pq })
    }
}

/// A full identity including the private keys. Lives in the Secure Enclave /
/// Keychain on Apple platforms; never leaves the device.
///
/// All keys are derived deterministically from a single 32-byte **master seed** via
/// HKDF, so persistence and recovery are just that seed (store it in the Keychain).
pub struct Identity {
    seed: [u8; 32],
    signing: SigningKey,
    sig_pq: DsaSigningKey<MlDsa65>,
    kem_x: XStaticSecret,
    kem_pq_dk: DecapKey,
    kem_pq_ek: EncapKey,
}

impl Identity {
    /// Generate a brand-new identity from the OS CSPRNG.
    pub fn generate() -> Self {
        let mut master = [0u8; 32];
        OsRng.fill_bytes(&mut master);
        Self::from_seed(&master)
    }

    /// Deterministically derive a full identity from a 32-byte master seed.
    /// The same seed always yields the same identity — this is the persistence and
    /// recovery primitive (back up the seed, restore the identity).
    pub fn from_seed(master: &[u8; 32]) -> Self {
        let hk = Hkdf::<Sha256>::new(Some(b"haven-identity-v1"), master);
        let sub = |info: &[u8]| -> [u8; 32] {
            let mut out = [0u8; 32];
            hk.expand(info, &mut out).expect("32 is a valid HKDF length");
            out
        };

        let signing = SigningKey::from_bytes(&sub(b"ed25519"));
        let kem_x = XStaticSecret::from(sub(b"x25519"));

        let mut kem_rng = ChaCha20Rng::from_seed(sub(b"ml-kem-768"));
        let (kem_pq_dk, kem_pq_ek) = MlKem768::generate(&mut kem_rng);

        let dsa_seed = B32::try_from(&sub(b"ml-dsa-65")[..]).expect("32 bytes");
        let sig_pq = DsaSigningKey::<MlDsa65>::from_seed(&dsa_seed);

        Self { seed: *master, signing, sig_pq, kem_x, kem_pq_dk, kem_pq_ek }
    }

    /// The 32-byte master seed. This is the **secret** to store in the Keychain /
    /// Secure Enclave and to back up for recovery — it reconstructs the whole identity.
    pub fn secret_seed(&self) -> [u8; 32] {
        self.seed
    }

    /// The 32-byte Ed25519 signing-key seed. This is the key material the transport
    /// (iroh) binds to, so the network node id equals this identity's `node_id_bytes()`
    /// — letting a contact dial you by the id in your reach-me link. Secret; never share.
    pub fn node_secret_bytes(&self) -> [u8; 32] {
        self.signing.to_bytes()
    }

    /// A 32-byte **symmetric** key for self-encrypting the account-state self-sync blob
    /// (multi-device D16, see [`crate::selfsync`]). Derived from the master seed with its
    /// own HKDF context, so it is independent of every other key and identical on *all* of
    /// the user's devices (they share the seed) — and derivable by no one else.
    pub fn self_sync_key(&self) -> [u8; 32] {
        let hk = Hkdf::<Sha256>::new(Some(b"haven-selfsync-v1"), &self.seed);
        let mut out = [0u8; 32];
        hk.expand(b"state-key", &mut out).expect("32 is a valid HKDF length");
        out
    }

    /// The shareable public identity.
    pub fn public(&self) -> HavenId {
        HavenId {
            signing: self.signing.verifying_key(),
            sig_pq: self.sig_pq.verifying_key(),
            kem_x: XPublicKey::from(&self.kem_x),
            kem_pq: self.kem_pq_ek.clone(),
        }
    }

    /// Produce a **hybrid** signature: `ed25519(64) ‖ ml-dsa-65(rest)`.
    pub fn sign(&self, msg: &[u8]) -> Vec<u8> {
        let ed_sig = self.signing.sign(msg).to_bytes();
        let dsa_sig: DsaSignature<MlDsa65> = self.sig_pq.sign(msg);
        let dsa_bytes = dsa_sig.encode();
        let mut v = Vec::with_capacity(ED_SIG_LEN + dsa_bytes.len());
        v.extend_from_slice(&ed_sig);
        v.extend_from_slice(&dsa_bytes[..]);
        v
    }

    // --- accessors used by the KEM in `crypto.rs` ---
    pub(crate) fn kem_x_secret(&self) -> &XStaticSecret {
        &self.kem_x
    }
    pub(crate) fn kem_pq_decap(&self) -> &DecapKey {
        &self.kem_pq_dk
    }
}
