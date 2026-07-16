//! Epoch group keys: access revocation + bounded forward secrecy, post-quantum-preserving.
//!
//! See `docs/GROUP-KEYING.md` for the design and why this is used instead of classical MLS
//! (which would drop Haven's hybrid PQ property and assumes ordered handshake delivery that the
//! offline-first gossip model can't guarantee).
//!
//! ## Model
//! A circle has a sequence of **epochs**, each with a random 32-byte `epoch_key`. The epoch key is
//! distributed to the member set via a signed [`KeyCommit`] — the *only* remaining per-recipient
//! hybrid-KEM wrap (once per epoch, not per event). Events are then sealed with a per-event key
//! **derived** from the current epoch key (HKDF), so they are true group encryption (O(1) size) and
//! a member removed in a later epoch — who never receives that epoch's key — cannot decrypt them.
//!
//! This increment is **additive and unwired**: it adds the primitives + tests; the engine still uses
//! the legacy per-recipient path until the integration increment (see the rollout in the design doc).

use hkdf::Hkdf;
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::crypto::{open, seal_reproducible};
use crate::identity::{HavenId, Identity};
use crate::social::{self, Event, Group, SealedEnvelope};
use crate::{CoreError, Result};

/// A fresh random 32-byte epoch key. Held only in memory / the encrypted state blob; deleted once
/// older than the circle's retention window (bounded forward secrecy).
pub fn new_epoch_key() -> [u8; 32] {
    let mut k = [0u8; 32];
    OsRng.fill_bytes(&mut k);
    k
}

/// The payload a KeyCommit carries (sealed to the member set via the hybrid KEM).
#[derive(Clone, Debug, Serialize, Deserialize)]
struct KeyCommitPayload {
    circle_id: String,
    epoch: u64,
    epoch_key: [u8; 32],
    /// The committer's STABLE circle secret (doesn't rotate) — used to derive opaque storage-key
    /// prefixes so a blind relay can't tell circles apart (audit transport-F4). Defaulted for
    /// back-compat with pre-secret commits.
    #[serde(default)]
    circle_secret: [u8; 32],
}

/// A KeyCommit opened by a recipient: the circle's epoch key + the committer's stable circle secret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpenedKeyCommit {
    pub circle_id: String,
    pub epoch: u64,
    pub epoch_key: [u8; 32],
    pub circle_secret: [u8; 32],
}

/// A fresh stable per-member circle secret (used only to derive opaque storage-key prefixes, never
/// for content). Generated once per circle and distributed in the member's key commits.
pub fn new_circle_secret() -> [u8; 32] {
    new_epoch_key()
}

/// Seal a circle's `epoch_key` (+ the committer's stable `circle_secret`) to exactly `members` (the
/// *new* member set after an add/remove). A removed node is simply absent from `members`, so it never
/// receives this — cryptographic revocation, and it never learns the secret to find the circle's
/// blobs. Reuses the hybrid-KEM `seal_bytes` (PQ-preserving), signed by the committer.
pub fn seal_key_commit(
    committer: &Identity,
    members: &[HavenId],
    circle_id: &str,
    epoch: u64,
    epoch_key: &[u8; 32],
    circle_secret: &[u8; 32],
) -> Result<SealedEnvelope> {
    let payload = KeyCommitPayload {
        circle_id: circle_id.to_string(),
        epoch,
        epoch_key: *epoch_key,
        circle_secret: *circle_secret,
    };
    let bytes = serde_json::to_vec(&payload).map_err(|_| CoreError::Encoding("keycommit encode"))?;
    let group = Group::new(circle_id, members.to_vec());
    social::seal_bytes(committer, &group, &bytes)
}

/// Open a KeyCommit addressed to me, verifying the committer's hybrid signature.
pub fn open_key_commit(
    me: &Identity,
    committer_pub: &HavenId,
    env: &SealedEnvelope,
) -> Result<OpenedKeyCommit> {
    let bytes = social::open_bytes(me, committer_pub, env)?;
    let payload: KeyCommitPayload =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::Encoding("keycommit decode"))?;
    Ok(OpenedKeyCommit {
        circle_id: payload.circle_id,
        epoch: payload.epoch,
        epoch_key: payload.epoch_key,
        circle_secret: payload.circle_secret,
    })
}

/// Derive the OPAQUE storage-key prefix for a member's blobs of a given `kind` ("mailbox" / "media" /
/// "presign") in a circle (audit transport-F4). A blind relay sees only this keyed-MAC output, never
/// the circle id; a non-member — lacking the member's circle secret — can't derive it, so they can
/// neither name, list, nor fetch the circle's blobs. 128-bit prefix (collision-safe, compact).
pub fn mailbox_prefix(circle_secret: &[u8; 32], circle_id: &str, kind: &str) -> String {
    let mut msg = Vec::with_capacity(kind.len() + 1 + circle_id.len());
    msg.extend_from_slice(kind.as_bytes());
    msg.push(b':');
    msg.extend_from_slice(circle_id.as_bytes());
    let mac = blake3::keyed_hash(circle_secret, &msg);
    hex(&mac.as_bytes()[..16])
}

/// Derive a per-event AEAD key from the epoch key + a per-event random salt, bound to the circle and
/// epoch. The epoch key is never used directly as an AES key — only as HKDF keying material — so a
/// single epoch key safely seals an unbounded number of events.
fn derive_event_key(epoch_key: &[u8; 32], salt: &[u8], circle_id: &str, epoch: u64) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(salt), epoch_key);
    let mut info = Vec::with_capacity(18 + circle_id.len() + 8);
    info.extend_from_slice(b"haven-event-key-v1");
    info.extend_from_slice(circle_id.as_bytes());
    info.extend_from_slice(&epoch.to_le_bytes());
    let mut okm = [0u8; 32];
    hk.expand(&info, &mut okm).expect("32 is a valid HKDF length");
    okm
}

/// An event sealed under a circle epoch key. No per-recipient wrapping — any holder of the epoch key
/// opens it; a member excluded from that epoch cannot. Opaque to relays.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EpochEnvelope {
    pub circle_id: String,
    pub epoch: u64,
    salt: Vec<u8>, // 16 random bytes; diversifies the per-event key (carried in the clear, not secret)
    sender: Vec<u8>,
    ciphertext: Vec<u8>,
    signature: Vec<u8>, // hybrid signature over the transcript
}

impl EpochEnvelope {
    pub fn sender_hex(&self) -> String {
        hex(&self.sender)
    }
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("epoch envelope serializes")
    }
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        serde_json::from_slice(b).map_err(|_| CoreError::Encoding("malformed epoch envelope"))
    }
    /// Transcript the signature covers: binds circle + epoch + salt + sender + ciphertext.
    fn transcript(&self) -> [u8; 32] {
        let mut h = blake3::Hasher::new();
        h.update(b"haven-epoch-envelope-v1");
        h.update(self.circle_id.as_bytes());
        h.update(&self.epoch.to_le_bytes());
        h.update(&self.salt);
        h.update(&self.sender);
        h.update(&self.ciphertext);
        *h.finalize().as_bytes()
    }
}

/// Seal an event under the current circle epoch key. Sender side.
pub fn seal_event_in_epoch(
    sender: &Identity,
    circle_id: &str,
    epoch: u64,
    epoch_key: &[u8; 32],
    event: &Event,
) -> Result<EpochEnvelope> {
    let plaintext = serde_json::to_vec(event).map_err(|_| CoreError::Encoding("event encode"))?;
    // DETERMINISTIC salt: a PRF over the plaintext keyed by the (secret) epoch key, instead of
    // random bytes. Re-sealing the same event in the same epoch then reproduces the envelope
    // byte-for-byte (the hybrid signature is deterministic too: Ed25519 + ML-DSA's deterministic
    // variant), so the content-addressed mailbox key is STABLE — the relay `has()` check dedupes
    // a backfill instead of accumulating a fresh copy of the whole history per app launch (a
    // mailbox had grown to ~6700 entries for 88 events, and every cold start re-pulled all of
    // them). Binding the plaintext hash means an EDITED event derives a different salt → a
    // different key + nonce, so the derived-nonce seal can never reuse a (key, nonce) pair
    // across distinct plaintexts. Without the epoch key the salt is indistinguishable from
    // random, so it reveals nothing beyond the equality of identical re-seals — exactly the
    // property the dedup needs.
    let salt: [u8; 16] = {
        let mut h = blake3::Hasher::new_keyed(epoch_key);
        h.update(b"haven-event-salt-v1");
        h.update(circle_id.as_bytes());
        h.update(&epoch.to_le_bytes());
        h.update(&plaintext);
        h.finalize().as_bytes()[..16].try_into().expect("16 bytes")
    };
    let event_key = derive_event_key(epoch_key, &salt, circle_id, epoch);
    let ciphertext = seal_reproducible(&event_key, &plaintext);

    let mut env = EpochEnvelope {
        circle_id: circle_id.to_string(),
        epoch,
        salt: salt.to_vec(),
        sender: sender.public().node_id_bytes().to_vec(),
        ciphertext,
        signature: Vec::new(),
    };
    env.signature = sender.sign(&env.transcript());
    Ok(env)
}

/// Open an epoch-sealed event, verifying the sender's hybrid signature and the author/sender bind.
/// Recipient side. Fails if `epoch_key` is the wrong epoch (e.g. you were removed before it).
pub fn open_event_in_epoch(
    sender_pub: &HavenId,
    epoch_key: &[u8; 32],
    env: &EpochEnvelope,
    allow_forwarded: bool,
) -> Result<Event> {
    sender_pub.verify(&env.transcript(), &env.signature)?;
    let event_key = derive_event_key(epoch_key, &env.salt, &env.circle_id, env.epoch);
    let plaintext = open(&event_key, &env.ciphertext)?;
    let event: Event =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::Encoding("event decode"))?;
    // The author/sender bind stops a member re-attributing someone else's event. But OWN-DEVICE sync
    // legitimately FORWARDS events (mine + ones I received) re-sealed by MY OWN account, so author (the
    // original) differs from sender (me). The envelope signature is still verified, and only my own account
    // can produce a `sender=me` envelope, so allowing the mismatch for self-forwards is safe.
    if !allow_forwarded && event.author != hex(&env.sender) {
        return Err(CoreError::Crypto("author/sender mismatch"));
    }
    Ok(event)
}

/// Open an epoch event whose SENDER may be a **device acting on behalf of an account** (seed-drop S1,
/// D16 Phase 2). The sender's hybrid signature over the envelope is verified exactly as in
/// [`open_event_in_epoch`]; then the event's internal `author` is bound to `expected_author` — an
/// account id hex the caller resolved from the VERIFIED device roster (the credential chain proving
/// `sender` is that account's device was checked at roster ingest).
///
/// This GENERALIZES the strict `author == sender` bind to `author == account-of-sender-device`, so a peer
/// can accept content a contact's device signed for the account — the **receive-side verifier that ships
/// to everyone** ahead of any device switching to sign under its device key. It is a generalization, not a
/// bypass: a device of account A can still only produce `author == A` (pass a different `expected_author`
/// and it is rejected), so no re-attribution is possible.
///
/// `expected_author == None` skips the bind (own-device self-forward), identical to `allow_forwarded =
/// true`. Passing the sender's own id reduces exactly to the strict `author == sender` case.
pub fn open_event_in_epoch_authored(
    sender_pub: &HavenId,
    epoch_key: &[u8; 32],
    env: &EpochEnvelope,
    expected_author: Option<&str>,
) -> Result<Event> {
    // Signature over the transcript is still verified inside (the `true` only relaxes the author/sender
    // bind, which we re-impose against the account below).
    let event = open_event_in_epoch(sender_pub, epoch_key, env, true)?;
    if let Some(author) = expected_author {
        if event.author != author {
            return Err(CoreError::Crypto("author not authorized for sender device"));
        }
    }
    Ok(event)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::social::EventKind;

    fn member(n: u8) -> Identity {
        Identity::from_seed(&[n; 32])
    }
    fn post(author: &Identity, t: u64, body: &str) -> Event {
        Event::new(
            &author.public().node_id_bytes(),
            t,
            EventKind::Message { body: body.into() },
        )
    }

    #[test]
    fn members_open_epoch_events_nonmembers_cannot() {
        let alice = member(1);
        let bob = member(2);
        let key = new_epoch_key();
        let ev = post(&alice, 100, "hello circle");
        let env = seal_event_in_epoch(&alice, "c1", 0, &key, &ev).unwrap();

        // Bob holds the epoch key → opens it and authenticates Alice.
        assert_eq!(open_event_in_epoch(&alice.public(), &key, &env, false).unwrap(), ev);

        // A different epoch key (what a removed member would be stuck on) cannot open it.
        let wrong = new_epoch_key();
        assert!(open_event_in_epoch(&alice.public(), &wrong, &env, false).is_err());
        let _ = bob;
    }

    #[test]
    fn resealing_same_event_is_byte_identical() {
        // The mailbox stores envelopes under SHA256(bytes); backfill re-seals history on every
        // run, so identical re-seals MUST reproduce identical bytes or the mailbox grows without
        // bound (and every cold start re-pulls the duplicates — the 30s cold-start bug).
        let alice = member(1);
        let key = new_epoch_key();
        let ev = post(&alice, 100, "same event, sealed twice");
        let a = seal_event_in_epoch(&alice, "c1", 0, &key, &ev).unwrap();
        let b = seal_event_in_epoch(&alice, "c1", 0, &key, &ev).unwrap();
        assert_eq!(a.to_bytes(), b.to_bytes());
        // Still opens + authenticates normally.
        assert_eq!(open_event_in_epoch(&alice.public(), &key, &a, false).unwrap(), ev);
    }

    #[test]
    fn distinct_plaintexts_never_share_key_or_nonce() {
        // The derived-nonce seal is only sound if a (key, nonce) pair never covers two different
        // plaintexts. The salt binds the plaintext hash, so ANY change (an edit, a different
        // event, another epoch/circle) must produce a different salt — and therefore a different
        // derived key + nonce (the nonce is a PRF of the key).
        let alice = member(1);
        let key = new_epoch_key();
        let ev1 = post(&alice, 100, "original");
        let ev2 = post(&alice, 100, "edited body");
        let env1 = seal_event_in_epoch(&alice, "c1", 0, &key, &ev1).unwrap();
        let env2 = seal_event_in_epoch(&alice, "c1", 0, &key, &ev2).unwrap();
        assert_ne!(env1.salt, env2.salt);
        // Same event in a different epoch or circle also re-salts (no cross-context reuse).
        let env3 = seal_event_in_epoch(&alice, "c1", 1, &key, &ev1).unwrap();
        let env4 = seal_event_in_epoch(&alice, "c2", 0, &key, &ev1).unwrap();
        assert_ne!(env1.salt, env3.salt);
        assert_ne!(env1.salt, env4.salt);
        // Everything still round-trips.
        assert_eq!(open_event_in_epoch(&alice.public(), &key, &env2, false).unwrap(), ev2);
    }

    #[test]
    fn key_commit_revokes_removed_member() {
        let alice = member(1); // committer
        let bob = member(2);
        let carol = member(3); // will be removed

        // Epoch 0: everyone (Alice, Bob, Carol).
        let e0 = new_epoch_key();
        let secret = new_circle_secret();
        let commit0 = seal_key_commit(
            &alice,
            &[alice.public(), bob.public(), carol.public()],
            "c1",
            0,
            &e0,
            &secret,
        )
        .unwrap();
        // Carol can open epoch 0.
        assert_eq!(open_key_commit(&carol, &alice.public(), &commit0).unwrap().epoch_key, e0);

        // Membership change → epoch 1 sealed to ONLY Alice + Bob (Carol removed).
        let e1 = new_epoch_key();
        let commit1 =
            seal_key_commit(&alice, &[alice.public(), bob.public()], "c1", 1, &e1, &secret).unwrap();

        // Bob (still a member) gets epoch 1.
        assert_eq!(open_key_commit(&bob, &alice.public(), &commit1).unwrap().epoch_key, e1);
        // Carol is NOT a recipient → cannot open the epoch-1 commit at all.
        assert!(open_key_commit(&carol, &alice.public(), &commit1).is_err());

        // A post in epoch 1 is therefore unreadable by Carol (she never learns e1), but readable by Bob.
        let ev = post(&alice, 200, "after carol left");
        let env = seal_event_in_epoch(&alice, "c1", 1, &e1, &ev).unwrap();
        assert_eq!(open_event_in_epoch(&alice.public(), &e1, &env, false).unwrap(), ev);
        // Carol only has e0 → derives the wrong key → open fails. Revocation is cryptographic.
        assert!(open_event_in_epoch(&alice.public(), &e0, &env, false).is_err());
    }

    #[test]
    fn tamper_and_forgery_are_rejected() {
        let alice = member(1);
        let mallory = member(9);
        let key = new_epoch_key();
        let ev = post(&alice, 100, "authentic");
        let mut env = seal_event_in_epoch(&alice, "c1", 0, &key, &ev).unwrap();

        // Flip a ciphertext byte → AEAD/signature rejects.
        env.ciphertext[0] ^= 0xff;
        assert!(open_event_in_epoch(&alice.public(), &key, &env, false).is_err());

        // Verifying with the wrong sender key fails (Mallory didn't sign it).
        let ev2 = post(&alice, 101, "again");
        let env2 = seal_event_in_epoch(&alice, "c1", 0, &key, &ev2).unwrap();
        assert!(open_event_in_epoch(&mallory.public(), &key, &env2, false).is_err());
    }

    #[test]
    fn storage_prefix_is_opaque_and_member_derivable() {
        let secret = new_circle_secret();
        let p1 = mailbox_prefix(&secret, "default", "mailbox");
        assert_eq!(p1, mailbox_prefix(&secret, "default", "mailbox"), "deterministic");
        assert!(!p1.contains("default"), "opaque: the circle id is not in the prefix");
        // A different member's secret → a different prefix (sender-keys storage).
        assert_ne!(p1, mailbox_prefix(&new_circle_secret(), "default", "mailbox"));
        // A different kind → a different prefix (mailbox vs media vs presign don't collide).
        assert_ne!(p1, mailbox_prefix(&secret, "default", "media"));
    }

    #[test]
    fn device_signed_event_verifies_for_its_account_only() {
        // Seed-drop S1: a DEVICE signs an event on its ACCOUNT's behalf — sender = device, author =
        // account. The receive-side verifier accepts it when bound to the correct account, and rejects it
        // for any other account (no re-attribution).
        let account = member(1);
        let device = member(2); // an authorized device of `account` (credential verified elsewhere)
        let key = new_epoch_key();
        // The event's author is the ACCOUNT; the envelope is SIGNED by the device.
        let ev = Event::new(&account.public().node_id_bytes(), 100, EventKind::Message { body: "hi".into() });
        let env = seal_event_in_epoch(&device, "c1", 0, &key, &ev).unwrap();
        let account_hex = hex(&account.public().node_id_bytes());

        // Accept: signature checks against the device, author bound to the device's account.
        assert_eq!(
            open_event_in_epoch_authored(&device.public(), &key, &env, Some(&account_hex)).unwrap(),
            ev,
            "a device-signed event opens when bound to its own account"
        );

        // Reject: binding to a DIFFERENT account (a device may not author for someone else).
        let stranger_hex = hex(&member(3).public().node_id_bytes());
        assert!(
            open_event_in_epoch_authored(&device.public(), &key, &env, Some(&stranger_hex)).is_err(),
            "a device cannot author for an account it isn't credentialed to"
        );

        // The OLD strict bind (author == sender) would have rejected this device-signed event — which is
        // exactly why the generalized verifier must ship before any device switches signers.
        assert!(
            open_event_in_epoch(&device.public(), &key, &env, false).is_err(),
            "strict author==sender rejects a device-signed, account-authored event"
        );
    }

    #[test]
    fn epoch_envelope_round_trips_through_bytes() {
        let alice = member(1);
        let key = new_epoch_key();
        let ev = post(&alice, 100, "serialize me");
        let env = seal_event_in_epoch(&alice, "circle-xyz", 7, &key, &ev).unwrap();
        let bytes = env.to_bytes();
        let back = EpochEnvelope::from_bytes(&bytes).unwrap();
        assert_eq!(back.epoch, 7);
        assert_eq!(back.circle_id, "circle-xyz");
        assert_eq!(open_event_in_epoch(&alice.public(), &key, &back, false).unwrap(), ev);
    }
}
