//! Scan-to-link: the NEW device shows a code and a device the person already uses scans it.
//!
//! Seedless enrollment ([`crate::enroll`]) runs primary → new device: the primary shows a
//! `haven-enroll:` ticket and the new device scans or pastes it. That is the wrong way round for a
//! browser on a borrowed or locked-down computer — it often has no camera, and typing a ticket into
//! it from a phone is not something a person can do. Here the direction of the FIRST hop is
//! reversed and nothing else changes:
//!
//!   1. [`PairCode`] — a `haven-pair:` code the new device shows (QR + text). It carries the new
//!      device's transport id, the 16-byte verification of its full bundle (the bundle itself is
//!      ~3 KB and does not fit a QR), a one-time 32-byte secret, when it was made, and the relay
//!      the device can be reached through. **Nothing about any account** — the device has none.
//!   2. Offer ([`pair_offer_wire`] / [`open_pair_offer`]) — the scanning device, which holds the
//!      account seed, mints an ordinary enrollment ticket and sends it to the new device sealed
//!      under the code's secret.
//!   3. From there it is exactly [`crate::enroll`]: the new device sends the frame-28 request, the
//!      primary's owner confirms, the grant comes back.
//!
//! What the code's secret does and does not buy:
//!   * Whoever can read the code can hand the new device a ticket. So someone who photographs the
//!     screen could make that browser join THEIR account instead — the same thing as tricking a
//!     person into pasting the wrong ticket, and visible to them (wrong name, empty feed). They
//!     gain nothing of the victim's.
//!   * It does NOT let anyone else be enrolled. The scanning device binds the ticket it mints to
//!     the scanned device id + bundle verification ([`PairCode::matches`]) and refuses a request
//!     from any other device, so reading the code is not enough to get a device of one's own onto
//!     the account. That is stricter than a pasted ticket, which enrolls whoever holds it.
//!
//! Pure like `enroll.rs`: no clock, and the only randomness is the explicit CSPRNG in
//! [`PairCode::issue`] and the nonce in [`pair_offer_wire`].

use rand::rngs::OsRng;
use rand::RngCore;

use crate::identity::HavenId;
use crate::wire::{lp, Reader, WireTag};
use crate::{crypto, CoreError, Result};

/// Text-form scheme. base64url, like `haven-enroll:`.
const SCHEME: &str = "haven-pair:";

const CODE_VERSION: u8 = 1;
const OFFER_VERSION: u8 = 1;

/// Key-derivation context for the offer seal. The key also binds the device id, so an offer sealed
/// for one code can never open under another code that happened to reuse a secret.
const OFFER_KEY_CONTEXT: &str = "haven-pair-offer-v1 key";

/// The longest ticket text an offer may carry. A real `haven-enroll:` ticket is a few hundred
/// bytes; this only stops a hostile sender making the receiver allocate without bound.
const MAX_TICKET_LEN: usize = 8 * 1024;

const WIRE: WireTag = WireTag::new(
    "pair: unexpected end of input",
    "pair: length overflow",
    "pair: invalid utf-8",
);

/// The decoded contents of a `haven-pair:` code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairCode {
    /// The new device's 32-byte transport id (the dial target for the offer).
    pub device_id: [u8; 32],
    /// 16-byte tamper hash of the device's FULL bundle (`HavenId::verification`).
    pub verification: [u8; 16],
    /// One-time secret (32 bytes, CSPRNG). Seals the offer.
    pub secret: [u8; 32],
    /// Unix seconds the code was made.
    pub issued_at: u64,
    /// The relay (an `https://…` front door) the device is listening on. One, not a list: a
    /// browser is reachable only through the relay that served it.
    pub relay: String,
}

impl PairCode {
    /// Make a code for `device` (the new device's own public bundle), reachable through `relay`.
    pub fn issue(device: &HavenId, now: u64, relay: &str) -> Self {
        let mut secret = [0u8; 32];
        OsRng.fill_bytes(&mut secret);
        Self {
            device_id: device.node_id_bytes(),
            verification: device.verification(),
            secret,
            issued_at: now,
            relay: relay.to_string(),
        }
    }

    /// Has more than `ttl_secs` elapsed since the code was made? Same arithmetic as
    /// `EnrollTicket::is_expired` (a `now` before `issued_at` is not expired).
    pub fn is_expired(&self, now: u64, ttl_secs: u64) -> bool {
        now.saturating_sub(self.issued_at) > ttl_secs
    }

    /// Is `bundle` the device this code was made for? The scanning device asks this of the bundle
    /// in the enrollment request, and enrolls nothing else on the strength of this code.
    pub fn matches(&self, bundle: &HavenId) -> bool {
        bundle.node_id_bytes() == self.device_id && bundle.verification() == self.verification
    }

    /// Binary form: `ver(1)=1 ‖ device_id(32) ‖ verification(16) ‖ secret(32) ‖ issued_at(8 LE) ‖
    /// lp(relay)`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(1 + 32 + 16 + 32 + 8 + 4 + self.relay.len());
        v.push(CODE_VERSION);
        v.extend_from_slice(&self.device_id);
        v.extend_from_slice(&self.verification);
        v.extend_from_slice(&self.secret);
        v.extend_from_slice(&self.issued_at.to_le_bytes());
        lp(&mut v, self.relay.as_bytes());
        v
    }

    /// Inverse of [`Self::to_bytes`]. Strict: trailing bytes are an error.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b, WIRE);
        if r.u8()? != CODE_VERSION {
            return Err(CoreError::Encoding("pair code: unsupported version"));
        }
        let device_id = r.array32()?;
        let verification: [u8; 16] = r.take(16)?.try_into().expect("16 bytes");
        let secret = r.array32()?;
        let issued_at = r.u64()?;
        let relay = r.str_lp()?;
        if !r.rest().is_empty() {
            return Err(CoreError::Encoding("pair code: trailing bytes"));
        }
        Ok(Self { device_id, verification, secret, issued_at, relay })
    }

    /// `haven-pair:<base64url-nopad(binary)>` — the QR / copyable form.
    pub fn encode_text(&self) -> String {
        format!("{}{}", SCHEME, data_encoding::BASE64URL_NOPAD.encode(&self.to_bytes()))
    }

    /// Inverse of [`Self::encode_text`].
    pub fn parse_text(s: &str) -> Result<Self> {
        let payload = s.trim().strip_prefix(SCHEME).ok_or(CoreError::BadLink("not a haven-pair: code"))?;
        let bytes = data_encoding::BASE64URL_NOPAD
            .decode(payload.as_bytes())
            .map_err(|_| CoreError::BadLink("pair code is not valid base64url"))?;
        Self::from_bytes(&bytes)
    }
}

fn offer_key(secret: &[u8; 32], device_id: &[u8; 32]) -> [u8; 32] {
    let mut material = [0u8; 64];
    material[..32].copy_from_slice(secret);
    material[32..].copy_from_slice(device_id);
    blake3::derive_key(OFFER_KEY_CONTEXT, &material)
}

/// Build the offer the scanning device sends the new device: `ver(1)=1 ‖ seal(ts(8 LE) ‖
/// lp(ticket_text))`, sealed (AES-256-GCM) under a key derived from the code's secret and the
/// device id. The ticket holds the one-time enrollment secret, so it never travels in the clear,
/// and only a holder of the code can make something the new device will accept.
pub fn pair_offer_wire(code: &PairCode, ticket_text: &str, ts: u64) -> Vec<u8> {
    let mut plain = Vec::with_capacity(8 + 4 + ticket_text.len());
    plain.extend_from_slice(&ts.to_le_bytes());
    lp(&mut plain, ticket_text.as_bytes());
    let mut v = vec![OFFER_VERSION];
    v.extend_from_slice(&crypto::seal(&offer_key(&code.secret, &code.device_id), &plain));
    v
}

/// The new device opens an offer with its own code. Returns the ticket text only if the offer was
/// sealed for THIS code and is fresh (`|now − ts| ≤ max_age_secs`); anything else is an error and
/// the device goes on waiting.
pub fn open_pair_offer(code: &PairCode, wire: &[u8], now: u64, max_age_secs: u64) -> Result<String> {
    let (ver, sealed) = wire.split_first().ok_or(CoreError::Encoding("pair offer: empty"))?;
    if *ver != OFFER_VERSION {
        return Err(CoreError::Encoding("pair offer: unsupported version"));
    }
    if sealed.len() > MAX_TICKET_LEN + 64 {
        return Err(CoreError::Encoding("pair offer: too long"));
    }
    let plain = crypto::open(&offer_key(&code.secret, &code.device_id), sealed)?;
    let mut r = Reader::new(&plain, WIRE);
    let ts = r.u64()?;
    let ticket = r.str_lp()?;
    if !r.rest().is_empty() {
        return Err(CoreError::Encoding("pair offer: trailing bytes"));
    }
    if now.abs_diff(ts) > max_age_secs {
        return Err(CoreError::Crypto("pair offer: stale"));
    }
    Ok(ticket)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    fn device(seed: u8) -> HavenId {
        Identity::from_seed(&[seed; 32]).public()
    }

    fn code() -> PairCode {
        PairCode::issue(&device(7), 1_000, "https://relay.example.test")
    }

    #[test]
    fn a_code_round_trips_as_text_and_names_only_the_device() {
        let c = code();
        let text = c.encode_text();
        assert!(text.starts_with("haven-pair:"));
        assert_eq!(PairCode::parse_text(&format!("  {text}\n")).unwrap(), c);
        assert!(c.matches(&device(7)));
        assert!(!c.matches(&device(8)), "another device's bundle does not match");
        // QR-sized: no bundle inside.
        assert!(text.len() < 220, "{}", text.len());
    }

    #[test]
    fn two_codes_for_one_device_have_different_secrets() {
        assert_ne!(code().secret, code().secret);
    }

    #[test]
    fn a_code_expires_and_tolerates_a_clock_that_runs_behind() {
        let c = code();
        assert!(!c.is_expired(1_000 + 600, 600));
        assert!(c.is_expired(1_000 + 601, 600));
        assert!(!c.is_expired(900, 600));
    }

    #[test]
    fn malformed_codes_are_refused() {
        let c = code();
        assert!(PairCode::parse_text("haven-enroll:AAAA").is_err());
        assert!(PairCode::parse_text("haven-pair:!!!").is_err());
        let mut b = c.to_bytes();
        b.push(0);
        assert!(PairCode::from_bytes(&b).is_err(), "trailing bytes");
        let mut b = c.to_bytes();
        b[0] = 2;
        assert!(PairCode::from_bytes(&b).is_err(), "unknown version");
        let b = c.to_bytes();
        for n in 0..b.len() {
            assert!(PairCode::from_bytes(&b[..n]).is_err(), "truncated at {n}");
        }
    }

    #[test]
    fn an_offer_opens_only_under_the_code_it_was_sealed_for() {
        let c = code();
        let wire = pair_offer_wire(&c, "haven-enroll:TICKET", 2_000);
        assert_eq!(open_pair_offer(&c, &wire, 2_010, 600).unwrap(), "haven-enroll:TICKET");
        // The ticket is not readable on the wire.
        assert!(!wire.windows(6).any(|w| w == b"TICKET"));

        // Another code (another secret) cannot open it.
        assert!(open_pair_offer(&code(), &wire, 2_010, 600).is_err());
        // The same secret under another device id cannot either — the key binds the device.
        let mut other = c.clone();
        other.device_id = device(8).node_id_bytes();
        assert!(open_pair_offer(&other, &wire, 2_010, 600).is_err());
    }

    #[test]
    fn a_tampered_stale_or_malformed_offer_is_refused() {
        let c = code();
        let wire = pair_offer_wire(&c, "haven-enroll:TICKET", 2_000);
        for i in 0..wire.len() {
            let mut w = wire.clone();
            w[i] ^= 1;
            assert!(open_pair_offer(&c, &w, 2_000, 600).is_err(), "flipped byte {i}");
        }
        assert!(open_pair_offer(&c, &wire, 2_000 + 601, 600).is_err(), "too old");
        assert!(open_pair_offer(&c, &wire, 2_000 - 601, 600).is_err(), "from the future");
        assert!(open_pair_offer(&c, &[], 2_000, 600).is_err());
        assert!(open_pair_offer(&c, &[OFFER_VERSION], 2_000, 600).is_err());
        let huge = pair_offer_wire(&c, &"x".repeat(MAX_TICKET_LEN + 100), 2_000);
        assert!(open_pair_offer(&c, &huge, 2_000, 600).is_err(), "oversized");
    }
}
