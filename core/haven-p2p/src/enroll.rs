//! Seedless enrollment handshake (seed-drop S4.1, `docs/SEEDLESS-ENROLLMENT-PLAN.md` §3).
//!
//! Today "link a device" copies the master seed (`haven-seed:` / `haven-link:`), so a linked
//! device *is* the account and revocation is advisory. S4 replaces that with a three-part
//! handshake in which the new device NEVER receives the seed:
//!
//!   1. [`EnrollTicket`] — a QR-sized `haven-enroll:` link minted by the primary. It carries the
//!      account's routable id + 16-byte bundle verification (the [`crate::link::HavenLink`]
//!      pattern: the ~3.2 KB hybrid bundle does not fit a QR, so it rides the grant and is
//!      tamper-checked here), a one-time 32-byte secret, the primary's device transport id
//!      (directed dial target), `issued_at`, and bootstrap relays. **No seed, no bundle.**
//!   2. Request ([`enroll_request_wire`] / [`verify_enroll_request`], frame 28) — the new device
//!      proves ticket possession by MACing its device bundle + name + timestamp with the ticket
//!      secret. This is what today's type-24 path lacks entirely (it accepts any mesh peer).
//!   3. Grant ([`enroll_grant_wire`] / [`open_enroll_grant`], frame 29) — the primary answers
//!      with the full account bundle, an account-signed [`DeviceCredential`], the verbatim
//!      roster wire, a sealed self-sync-key grant ([`crate::device::seal_self_sync_key`]), and
//!      relays; all MAC'd under the same secret. The device accepts only if ALL FOUR checks
//!      pass (§3.3) — a failed/partial grant leaves it in linking mode, never a half-identity.
//!
//! Single-use and expiry enforcement are CALLER policy (the primary tracks pending/consumed
//! tickets); the ticket bakes in `issued_at` + [`EnrollTicket::is_expired`] so every platform
//! computes the window identically. Like `device.rs`, everything below is pure (no clock;
//! the only RNG is the explicit CSPRNG in [`EnrollTicket::issue`]) so it is deterministic and
//! testable on every platform, including WASM.

use rand::rngs::OsRng;
use rand::RngCore;

use crate::device::{open_self_sync_key, ContactDevices, DeviceCredential, DeviceList};
use crate::identity::{HavenId, Identity};
use crate::social::SealedEnvelope;
use crate::{CoreError, Result};

/// Text-form scheme. base64url (NOT the base32 of `haven://invite`) because the payload is
/// binary-with-strings and the plan (§3.1) pins this exact form for cross-platform convergence.
const SCHEME: &str = "haven-enroll:";

/// Wire versions — first byte of each encoding, so a future format bump is detectable
/// (an old client rejects rather than misparses).
const TICKET_VERSION: u8 = 1;
const REQUEST_VERSION: u8 = 1;
const GRANT_VERSION: u8 = 1;

/// Domain-separation prefixes inside the keyed MACs, so a request MAC can never be replayed
/// as a grant MAC (both are keyed by the same ticket secret).
const REQ_MAC_DOMAIN: &[u8] = b"haven-enroll-req-v1";
const GRANT_MAC_DOMAIN: &[u8] = b"haven-enroll-grant-v1";

const MAC_LEN: usize = 32;

/// Roster-wire tag byte. Mirrors `TAG_DEVICE_ROSTER` in `haven-ffi` (`encode_roster` /
/// `my_roster_wire`): the grant carries the primary's roster **wire bytes verbatim** so the
/// seedless device can persist + rebroadcast them without re-encoding (re-encoding would strip
/// the primary-signed `SeedDropCapability` trailer — the §7 capability-fidelity risk). Core
/// therefore parses that exact layout here; S4.2 should converge the FFI onto this parser.
const TAG_DEVICE_ROSTER: u8 = 0x04;

// ── Ticket ───────────────────────────────────────────────────────────────────────────────────

/// The decoded contents of a `haven-enroll:` link (plan §3.1). Holds the one-time enrollment
/// `secret` — treat a ticket like an authorization credential (screenshot-protected QR,
/// single-use, short expiry), not like a public reach-me link.
#[derive(Clone)]
pub struct EnrollTicket {
    /// The account's 32-byte routable node id (like `HavenLink.id`).
    pub account_id: [u8; 32],
    /// 16-byte tamper hash of the FULL account bundle ([`HavenId::verification`]). The bundle
    /// itself rides the grant and is checked against this — the `HavenLink::matches` pattern.
    pub verification: [u8; 16],
    /// One-time enrollment secret (CSPRNG). Keys both handshake MACs.
    pub secret: [u8; 32],
    /// The primary's device transport id — the directed iroh dial target for the request.
    pub primary_device: [u8; 32],
    /// Unix seconds the ticket was minted (caller-supplied clock; see [`Self::is_expired`]).
    pub issued_at: u64,
    /// Bootstrap relays (what `haven-link:` added for the same reason).
    pub relays: Vec<String>,
}

impl EnrollTicket {
    /// Mint a ticket for `account` with a fresh CSPRNG secret. Provided so callers can't reach
    /// for a weak secret; tests construct the struct directly for determinism.
    pub fn issue(
        account: &HavenId,
        primary_device: [u8; 32],
        issued_at: u64,
        relays: Vec<String>,
    ) -> Self {
        let mut secret = [0u8; 32];
        OsRng.fill_bytes(&mut secret);
        Self {
            account_id: account.node_id_bytes(),
            verification: account.verification(),
            secret,
            primary_device,
            issued_at,
            relays,
        }
    }

    /// Expiry helper: has more than `ttl_secs` elapsed since `issued_at`? Single-use tracking
    /// and the actual TTL choice (~10 min per the plan) are caller policy; this only makes the
    /// arithmetic identical on every platform. A `now` earlier than `issued_at` (clock skew)
    /// is NOT expired — the request-side freshness window handles skew separately.
    pub fn is_expired(&self, now: u64, ttl_secs: u64) -> bool {
        now.saturating_sub(self.issued_at) > ttl_secs
    }

    /// Binary form: `ver(1)=1 ‖ account_id(32) ‖ verification(16) ‖ secret(32) ‖
    /// primary_device(32) ‖ issued_at(8 LE) ‖ n_relays(4 LE) ‖ lp(relay)*n`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(1 + 32 + 16 + 32 + 32 + 8 + 4);
        v.push(TICKET_VERSION);
        v.extend_from_slice(&self.account_id);
        v.extend_from_slice(&self.verification);
        v.extend_from_slice(&self.secret);
        v.extend_from_slice(&self.primary_device);
        v.extend_from_slice(&self.issued_at.to_le_bytes());
        v.extend_from_slice(&(self.relays.len() as u32).to_le_bytes());
        for r in &self.relays {
            lp(&mut v, r.as_bytes());
        }
        v
    }

    /// Inverse of [`Self::to_bytes`]. Strict: trailing bytes are a parse error, so a truncated
    /// or padded ticket never half-parses into something usable.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b, WIRE);
        if r.u8()? != TICKET_VERSION {
            return Err(CoreError::Encoding("enroll ticket: unsupported version"));
        }
        let account_id = r.array32()?;
        let verification: [u8; 16] = r.take(16)?.try_into().unwrap();
        let secret = r.array32()?;
        let primary_device = r.array32()?;
        let issued_at = r.u64()?;
        let n = r.u32()? as usize;
        let mut relays = Vec::with_capacity(n.min(64));
        for _ in 0..n {
            relays.push(r.str_lp()?);
        }
        if !r.rest().is_empty() {
            return Err(CoreError::Encoding("enroll ticket: trailing bytes"));
        }
        Ok(Self { account_id, verification, secret, primary_device, issued_at, relays })
    }

    /// `haven-enroll:<base64url-nopad(binary)>` — the QR / copyable text form (~150 bytes +
    /// relays, comfortably QR-able precisely because the bundle stays out).
    pub fn encode_text(&self) -> String {
        format!("{}{}", SCHEME, data_encoding::BASE64URL_NOPAD.encode(&self.to_bytes()))
    }

    /// Inverse of [`Self::encode_text`].
    pub fn parse_text(s: &str) -> Result<Self> {
        let s = s.trim();
        let payload = s
            .strip_prefix(SCHEME)
            .ok_or(CoreError::BadLink("not a haven-enroll: link"))?;
        let bytes = data_encoding::BASE64URL_NOPAD
            .decode(payload.as_bytes())
            .map_err(|_| CoreError::BadLink("enroll ticket is not valid base64url"))?;
        Self::from_bytes(&bytes)
    }

    /// Does the full bundle fetched via the grant match what this ticket promised? The MITM /
    /// tamper check — same shape as `HavenLink::matches`.
    pub fn matches(&self, fetched: &HavenId) -> bool {
        fetched.node_id_bytes() == self.account_id && fetched.verification() == self.verification
    }
}

// ── Request (frame 28) ───────────────────────────────────────────────────────────────────────

/// MAC over the request FIELDS (not the framed wire), per the plan's exact formula:
/// `blake3::keyed_hash(secret, "haven-enroll-req-v1" ‖ device_bundle ‖ name ‖ ts)`.
fn request_mac(secret: &[u8; 32], device_bundle: &[u8], name: &[u8], ts: u64) -> blake3::Hash {
    let mut h = blake3::Hasher::new_keyed(secret);
    h.update(REQ_MAC_DOMAIN);
    h.update(device_bundle);
    h.update(name);
    h.update(&ts.to_le_bytes());
    h.finalize()
}

/// Build the frame-28 body the new device sends the primary:
/// `ver(1)=1 ‖ lp(device_bundle) ‖ lp(name) ‖ ts(8 LE) ‖ mac(32)`.
///
/// Possession of `secret` (scanned from the ticket) is the ONLY thing that authorizes this —
/// the new device has no seed with which to already "be" the account.
pub fn enroll_request_wire(secret: &[u8; 32], device_bundle: &[u8], name: &str, ts: u64) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + 4 + device_bundle.len() + 4 + name.len() + 8 + MAC_LEN);
    v.push(REQUEST_VERSION);
    lp(&mut v, device_bundle);
    lp(&mut v, name.as_bytes());
    v.extend_from_slice(&ts.to_le_bytes());
    v.extend_from_slice(request_mac(secret, device_bundle, name.as_bytes(), ts).as_bytes());
    v
}

/// Primary-side verification of a frame-28 body. Checks, in order: version, structure, MAC
/// (constant-time via `blake3::Hash` equality), then freshness — `ts` must be within
/// `max_age_secs` of `now` in BOTH directions (stale replay and future-dated requests beyond
/// clock skew are equally rejected). Only then is the bundle parsed. Returns
/// `(device_bundle, name, ts)`. Ticket single-use bookkeeping stays with the caller.
pub fn verify_enroll_request(
    secret: &[u8; 32],
    wire: &[u8],
    now: u64,
    max_age_secs: u64,
) -> Result<(HavenId, String, u64)> {
    let mut r = Reader::new(wire, WIRE);
    if r.u8()? != REQUEST_VERSION {
        return Err(CoreError::Encoding("enroll request: unsupported version"));
    }
    let bundle = r.bytes_lp()?;
    let name_b = r.bytes_lp()?;
    let ts = r.u64()?;
    let mac = r.rest();
    if mac.len() != MAC_LEN {
        return Err(CoreError::Encoding("enroll request: bad mac length"));
    }
    let mac: [u8; 32] = mac.try_into().unwrap();
    // blake3::Hash == [u8;32] is constant-time, so a byte-by-byte oracle can't recover the MAC.
    if request_mac(secret, bundle, name_b, ts) != mac {
        return Err(CoreError::Crypto("enroll request: MAC verification failed"));
    }
    // Freshness AFTER authenticity: a valid-MAC-but-stale request is a replay, not garbage.
    if now.saturating_sub(ts) > max_age_secs || ts.saturating_sub(now) > max_age_secs {
        return Err(CoreError::Crypto("enroll request: timestamp outside freshness window"));
    }
    let device = HavenId::from_bytes(bundle)?;
    let name = String::from_utf8(name_b.to_vec())
        .map_err(|_| CoreError::Encoding("enroll request: invalid utf-8 name"))?;
    Ok((device, name, ts))
}

// ── Grant (frame 29) ─────────────────────────────────────────────────────────────────────────

/// Everything a seedless device needs to operate, returned by [`open_enroll_grant`] only after
/// ALL acceptance checks pass — never partially.
pub struct EnrollGrant {
    /// The full account public bundle, verified against the ticket's id + verification.
    pub account: HavenId,
    /// This device's account-signed credential.
    pub credential: DeviceCredential,
    /// The verified roster (signed list + credentials) that authorizes this device.
    pub roster: ContactDevices,
    /// The roster wire bytes VERBATIM (incl. any capability trailer) — persist and rebroadcast
    /// these exact bytes; re-encoding would strip the primary-signed trailer (§7).
    pub roster_wire: Vec<u8>,
    /// The granted 32-byte self-sync key — seed-grade secret, store accordingly.
    pub self_sync_key: [u8; 32],
    /// Bootstrap relays from the primary (authoritative superset of the ticket's).
    pub relays: Vec<String>,
}

/// Build the frame-29 body on the primary, AFTER it has issued the credential, unioned the
/// device into its roster, and sealed the self-sync grant:
/// `ver(1)=1 ‖ lp(account_bundle) ‖ lp(credential) ‖ lp(roster_wire) ‖ lp(self_sync_grant) ‖
/// lp(relays_json) ‖ mac(32)`, where `mac = blake3::keyed_hash(secret,
/// "haven-enroll-grant-v1" ‖ all previous bytes)` — the MAC covers the entire preceding wire
/// (version byte and length prefixes included), so no field can be resized or reordered.
///
/// `roster_wire` must be the tagged `TAG_DEVICE_ROSTER` bytes exactly as the primary emits
/// them (`my_roster_wire`), so the device can persist/rebroadcast them verbatim. `relays` are
/// JSON-encoded here in core (single canonical encoder — the `encode_circle_sync` convergence
/// discipline) rather than taking pre-encoded platform JSON.
pub fn enroll_grant_wire(
    secret: &[u8; 32],
    account_bundle: &[u8],
    credential: &[u8],
    roster_wire: &[u8],
    self_sync_grant: &[u8],
    relays: &[String],
) -> Vec<u8> {
    let relays_json = serde_json::to_vec(relays).expect("string list serializes");
    let mut v = Vec::with_capacity(
        1 + 5 * 4
            + account_bundle.len()
            + credential.len()
            + roster_wire.len()
            + self_sync_grant.len()
            + relays_json.len()
            + MAC_LEN,
    );
    v.push(GRANT_VERSION);
    lp(&mut v, account_bundle);
    lp(&mut v, credential);
    lp(&mut v, roster_wire);
    lp(&mut v, self_sync_grant);
    lp(&mut v, &relays_json);
    let mut h = blake3::Hasher::new_keyed(secret);
    h.update(GRANT_MAC_DOMAIN);
    h.update(&v);
    let mac = h.finalize();
    v.extend_from_slice(mac.as_bytes());
    v
}

/// New-device acceptance of a frame-29 body (plan §3.3) — ALL-POSITIVE, in order:
///
///   1. MAC verifies under the ticket secret, and the carried account bundle matches the
///      ticket's `{account_id, verification}` (the MITM/tamper check the QR promised).
///   2. The credential verifies against that account AND names THIS device — a credential for
///      any other device, however validly signed, is not ours to accept.
///   3. The roster wire parses, its signed list + every credential verify against the account,
///      and the list currently authorizes this device (present, not revoked).
///   4. The self-sync grant opens with OUR device key ([`open_self_sync_key`] verifies the
///      account's signature and yields exactly 32 bytes).
///
/// Any failure returns an error and NOTHING is handed to the caller — a failed/partial grant
/// leaves the device in linking mode (idempotent, re-scannable), never a half-identity.
pub fn open_enroll_grant(
    ticket: &EnrollTicket,
    device: &Identity,
    wire: &[u8],
) -> Result<EnrollGrant> {
    // Structure + MAC first: the MAC covers every preceding byte, so nothing downstream is
    // parsed until the whole grant is known to come from the secret holder, untampered.
    if wire.len() < 1 + MAC_LEN {
        return Err(CoreError::Encoding("enroll grant: too short"));
    }
    let (body, mac) = wire.split_at(wire.len() - MAC_LEN);
    let mac: [u8; 32] = mac.try_into().unwrap();
    let mut h = blake3::Hasher::new_keyed(&ticket.secret);
    h.update(GRANT_MAC_DOMAIN);
    h.update(body);
    if h.finalize() != mac {
        return Err(CoreError::Crypto("enroll grant: MAC verification failed"));
    }
    let mut r = Reader::new(body, WIRE);
    if r.u8()? != GRANT_VERSION {
        return Err(CoreError::Encoding("enroll grant: unsupported version"));
    }
    let account_bundle = r.bytes_lp()?;
    let cred_bytes = r.bytes_lp()?;
    let roster_wire = r.bytes_lp()?;
    let grant_bytes = r.bytes_lp()?;
    let relays_json = r.bytes_lp()?;
    if !r.rest().is_empty() {
        return Err(CoreError::Encoding("enroll grant: trailing bytes"));
    }

    // Check 1 (continued): the bundle is what the ticket promised — full-bundle verification
    // hash, not just the 32-byte id, so swapped KEM/DSA keys are caught.
    let account = HavenId::from_bytes(account_bundle)?;
    if !ticket.matches(&account) {
        return Err(CoreError::Crypto("enroll grant: account bundle does not match ticket"));
    }

    // Check 2: account-signed credential, for THIS device.
    let credential = DeviceCredential::from_bytes(cred_bytes)?;
    credential.verify(&account)?;
    let my_id = device.public().node_id_bytes();
    if credential.device_id() != my_id {
        return Err(CoreError::Crypto("enroll grant: credential names a different device"));
    }

    // Check 3: verified roster that authorizes us. Verification is anchored to the
    // TICKET-checked account bundle, never the roster's embedded copy (substitution defense);
    // the embedded copy must still name the same account.
    let roster = parse_and_verify_roster(roster_wire, &account)?;
    if !roster.list.is_authorized(&my_id) {
        return Err(CoreError::Crypto("enroll grant: roster does not authorize this device"));
    }

    // Check 4: the self-sync grant is sealed to OUR bundle and signed by the account.
    let env = SealedEnvelope::from_bytes(grant_bytes)?;
    let self_sync_key = open_self_sync_key(device, &account, &env)?;

    let relays: Vec<String> = serde_json::from_slice(relays_json)
        .map_err(|_| CoreError::Encoding("enroll grant: malformed relays"))?;

    Ok(EnrollGrant {
        account,
        credential,
        roster,
        roster_wire: roster_wire.to_vec(),
        self_sync_key,
        relays,
    })
}

/// Parse + verify a tagged roster wire (`TAG_DEVICE_ROSTER ‖ lp(account_bundle) ‖ lp(list) ‖
/// n(4) ‖ lp(credential)*n ‖ trailer`) against the ticket-verified account.
///
/// This mirrors the FFI's `encode_roster`/`decode_roster` layout on purpose: the grant carries
/// the primary's wire bytes VERBATIM so the trailer survives, which means core must be able to
/// read that exact framing. Only what acceptance needs is mirrored — the capability trailer is
/// carried through untouched (recording capability stays an FFI concern). Every credential must
/// verify (the `verify_and_store_roster` discipline: no smuggling a rogue device's credential
/// alongside a valid list).
fn parse_and_verify_roster(wire: &[u8], account: &HavenId) -> Result<ContactDevices> {
    let mut r = Reader::new(wire, WIRE);
    if r.u8()? != TAG_DEVICE_ROSTER {
        return Err(CoreError::Encoding("enroll grant: roster wire missing tag"));
    }
    let embedded = r.bytes_lp()?;
    let list_bytes = r.bytes_lp()?;
    let n = r.u32()? as usize;
    let mut credentials = Vec::with_capacity(n.min(64));
    for _ in 0..n {
        let cred = DeviceCredential::from_bytes(r.bytes_lp()?)?;
        cred.verify(account)?;
        credentials.push(cred);
    }
    // Anything after the credentials is the (optional) capability trailer — ignored here,
    // preserved by the caller's verbatim `roster_wire` copy.
    let embedded = HavenId::from_bytes(embedded)?;
    if embedded.node_id_bytes() != account.node_id_bytes() {
        return Err(CoreError::Crypto("enroll grant: roster names a different account"));
    }
    let list = DeviceList::from_bytes(list_bytes)?;
    list.verify(account)?;
    Ok(ContactDevices { list, credentials })
}

// ── Wire helpers (the device.rs Reader/lp style; Reader there is private, so mirrored) ──────

// The wire cursor now lives in `crate::wire` — this module carried one of five
// byte-identical private copies, which is why the cursor-overflow guard had to be
// written five times. Only the error strings were ever module-specific, so those stay
// here as a tag and the cursor itself does not.
use crate::wire::{lp, Reader, WireTag};

const WIRE: WireTag = WireTag::new(
    "enroll wire: unexpected end of input",
    "enroll wire: length overflow",
    "enroll wire: invalid utf-8",
);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::seal_self_sync_key;
    use crate::identity::Identity;

    fn id(seed: u8) -> Identity {
        Identity::from_seed(&[seed; 32])
    }

    /// A deterministic ticket for `account` (tests never want OsRng).
    fn ticket_for(account: &HavenId, primary_device: [u8; 32]) -> EnrollTicket {
        EnrollTicket {
            account_id: account.node_id_bytes(),
            verification: account.verification(),
            secret: [0xA5; 32],
            primary_device,
            issued_at: 1_700_000_000,
            relays: vec!["https://relay.example".into(), "https://backup.example:8674".into()],
        }
    }

    /// Mirror of the FFI `my_roster_wire` framing (tag ‖ lp(bundle) ‖ lp(list) ‖ n ‖ lp(cred)* ‖
    /// trailer) so grant tests exercise the exact bytes a primary emits, trailer included.
    fn roster_wire(
        account: &HavenId,
        list: &DeviceList,
        creds: &[DeviceCredential],
        trailer: &[u8],
    ) -> Vec<u8> {
        let mut v = vec![TAG_DEVICE_ROSTER];
        lp(&mut v, &account.to_bytes());
        lp(&mut v, &list.to_bytes());
        v.extend_from_slice(&(creds.len() as u32).to_le_bytes());
        for c in creds {
            lp(&mut v, &c.to_bytes());
        }
        v.extend_from_slice(trailer);
        v
    }

    /// Full primary-side grant assembly for `device`, returning (ticket, grant wire, expected key).
    fn make_grant(account: &Identity, device: &Identity) -> (EnrollTicket, Vec<u8>, [u8; 32]) {
        let primary_dev = id(50);
        let ticket = ticket_for(&account.public(), primary_dev.public().node_id_bytes());
        let dev_id = device.public().node_id_bytes();
        let cred = DeviceCredential::issue(account, &device.public(), "Blaine's iPad", 100);
        let list = DeviceList::signed(
            account,
            2,
            100,
            vec![primary_dev.public().node_id_bytes(), dev_id],
            vec![],
        );
        // A non-empty trailer stands in for the SeedDropCapability marker: acceptance must
        // tolerate + preserve it, not choke on bytes after the credentials.
        let wire = roster_wire(
            &account.public(),
            &list,
            &[cred.clone()],
            &crate::device::SeedDropCapability::issue(account, 1).to_bytes(),
        );
        let key = account.self_sync_key();
        let grant_env = seal_self_sync_key(account, &device.public(), &key).expect("seal grant");
        let grant = enroll_grant_wire(
            &ticket.secret,
            &account.public().to_bytes(),
            &cred.to_bytes(),
            &wire,
            &grant_env.to_bytes(),
            &["https://relay.example".to_string()],
        );
        (ticket, grant, key)
    }

    // ── Ticket ────────────────────────────────────────────────────────────────────────────

    #[test]
    fn ticket_round_trips_binary_and_text() {
        let account = id(1);
        let t = ticket_for(&account.public(), id(2).public().node_id_bytes());
        let back = EnrollTicket::from_bytes(&t.to_bytes()).expect("binary decode");
        assert_eq!(back.to_bytes(), t.to_bytes(), "binary round-trip must be stable");
        assert_eq!(back.relays, t.relays);
        assert_eq!(back.issued_at, t.issued_at);

        let text = t.encode_text();
        assert!(text.starts_with("haven-enroll:"), "text form carries the scheme");
        let parsed = EnrollTicket::parse_text(&text).expect("text decode");
        assert_eq!(parsed.to_bytes(), t.to_bytes());
        // Whitespace tolerance (QR scanners / copy-paste), same as HavenLink::parse.
        assert!(EnrollTicket::parse_text(&format!("  {}\n", text)).is_ok());
        // matches() accepts the real bundle and rejects an imposter's.
        assert!(parsed.matches(&account.public()));
        assert!(!parsed.matches(&id(9).public()));
        // Empty relay list round-trips too.
        let mut bare = t.clone();
        bare.relays = vec![];
        assert!(EnrollTicket::parse_text(&bare.encode_text()).expect("decode").relays.is_empty());
    }

    #[test]
    fn ticket_malformed_text_is_rejected() {
        let t = ticket_for(&id(1).public(), id(2).public().node_id_bytes());
        let text = t.encode_text();
        // Wrong scheme.
        assert!(EnrollTicket::parse_text(&text.replace("haven-enroll:", "haven-seed:")).is_err());
        // Not base64url.
        assert!(EnrollTicket::parse_text("haven-enroll:!!!not-base64!!!").is_err());
        // Truncated payload (structure check catches it — the fixed fields no longer fit).
        assert!(EnrollTicket::parse_text(&text[..text.len() / 2]).is_err());
        // Trailing garbage after a valid payload must not silently parse.
        let mut padded = t.to_bytes();
        padded.extend_from_slice(b"xx");
        assert!(EnrollTicket::from_bytes(&padded).is_err());
        // Unknown version byte.
        let mut vbad = t.to_bytes();
        vbad[0] = 2;
        assert!(EnrollTicket::from_bytes(&vbad).is_err());
    }

    #[test]
    fn ticket_expiry_helper() {
        let t = ticket_for(&id(1).public(), id(2).public().node_id_bytes());
        let ttl = 600; // the plan's ~10-minute window
        assert!(!t.is_expired(t.issued_at, ttl), "fresh at mint");
        assert!(!t.is_expired(t.issued_at + ttl, ttl), "inclusive at the boundary");
        assert!(t.is_expired(t.issued_at + ttl + 1, ttl), "expired past the window");
        assert!(!t.is_expired(t.issued_at - 30, ttl), "clock skew (now < issued) is not expiry");
    }

    // ── Request ───────────────────────────────────────────────────────────────────────────

    #[test]
    fn request_round_trips_and_verifies() {
        let device = id(3);
        let secret = [0xA5u8; 32];
        let bundle = device.public().to_bytes();
        let wire = enroll_request_wire(&secret, &bundle, "Blaine's iPad", 1_000);
        let (got, name, ts) =
            verify_enroll_request(&secret, &wire, 1_100, 600).expect("valid request verifies");
        assert_eq!(got.node_id_bytes(), device.public().node_id_bytes());
        assert_eq!(name, "Blaine's iPad");
        assert_eq!(ts, 1_000);
    }

    #[test]
    fn request_tamper_of_each_field_is_rejected() {
        let device = id(3);
        let secret = [0xA5u8; 32];
        let bundle = device.public().to_bytes();
        let wire = enroll_request_wire(&secret, &bundle, "iPad", 1_000);
        // Locate each field region in the wire: ver(1) ‖ len(4) ‖ bundle ‖ len(4) ‖ name(4) ‖ ts(8) ‖ mac(32).
        let bundle_at = 1 + 4;
        let name_at = bundle_at + bundle.len() + 4;
        let ts_at = name_at + 4;
        let mac_at = ts_at + 8;
        for (label, idx) in [
            ("device_bundle", bundle_at),
            ("name", name_at),
            ("ts", ts_at),
            ("mac", mac_at),
        ] {
            let mut bad = wire.clone();
            bad[idx] ^= 0x01;
            assert!(
                verify_enroll_request(&secret, &bad, 1_100, 600).is_err(),
                "tampered {label} must be rejected"
            );
        }
        // Untampered control: still verifies.
        assert!(verify_enroll_request(&secret, &wire, 1_100, 600).is_ok());
    }

    #[test]
    fn request_wrong_secret_is_rejected() {
        let bundle = id(3).public().to_bytes();
        let wire = enroll_request_wire(&[0xA5u8; 32], &bundle, "iPad", 1_000);
        assert!(verify_enroll_request(&[0x5Au8; 32], &wire, 1_100, 600).is_err());
    }

    #[test]
    fn request_stale_and_future_timestamps_are_rejected() {
        let secret = [0xA5u8; 32];
        let bundle = id(3).public().to_bytes();
        let wire = enroll_request_wire(&secret, &bundle, "iPad", 10_000);
        // Stale: now is beyond ts + window (a captured request replayed later).
        assert!(verify_enroll_request(&secret, &wire, 10_000 + 601, 600).is_err());
        // Future: ts is beyond now + window (a clock wildly ahead — or a pre-dated replay stash).
        assert!(verify_enroll_request(&secret, &wire, 10_000 - 601, 600).is_err());
        // Both edges of the window are inclusive.
        assert!(verify_enroll_request(&secret, &wire, 10_000 + 600, 600).is_ok());
        assert!(verify_enroll_request(&secret, &wire, 10_000 - 600, 600).is_ok());
    }

    // ── Grant ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn grant_end_to_end_yields_exact_key_and_verified_material() {
        let account = id(1);
        let device = id(4); // brand-new device: no seed, only its own keypair
        let (ticket, grant, key) = make_grant(&account, &device);
        let out = open_enroll_grant(&ticket, &device, &grant).expect("all four checks pass");
        assert_eq!(out.self_sync_key, key, "the exact granted self-sync key comes out");
        assert_eq!(out.account.node_id_bytes(), account.public().node_id_bytes());
        assert_eq!(out.credential.device_id(), device.public().node_id_bytes());
        assert!(out.roster.list.is_authorized(&device.public().node_id_bytes()));
        assert_eq!(out.relays, vec!["https://relay.example".to_string()]);
        // The verbatim roster wire (incl. capability trailer) is preserved for rebroadcast.
        assert_eq!(out.roster_wire.first(), Some(&TAG_DEVICE_ROSTER));
        assert!(out.roster_wire.len() > out.roster.list.to_bytes().len());
    }

    #[test]
    fn grant_mac_tamper_is_rejected() {
        let account = id(1);
        let device = id(4);
        let (ticket, grant, _) = make_grant(&account, &device);
        // Flip one byte anywhere in the body → MAC over "all previous bytes" must catch it.
        let mut bad = grant.clone();
        bad[10] ^= 0x01;
        assert!(open_enroll_grant(&ticket, &device, &bad).is_err());
        // Flip a MAC byte itself.
        let n = grant.len();
        let mut bad_mac = grant.clone();
        bad_mac[n - 1] ^= 0x01;
        assert!(open_enroll_grant(&ticket, &device, &bad_mac).is_err());
        // Wrong secret (ticket mismatch) also fails the MAC.
        let mut wrong_ticket = ticket.clone();
        wrong_ticket.secret = [0x11; 32];
        assert!(open_enroll_grant(&wrong_ticket, &device, &grant).is_err());
    }

    #[test]
    fn grant_account_bundle_must_match_ticket_verification() {
        // A grant whose bundle is NOT the account the ticket promised (a substituted identity
        // from someone who somehow learned the secret) fails check 1 even with a valid MAC.
        let account = id(1);
        let imposter = id(9);
        let device = id(4);
        let (ticket, _, _) = make_grant(&account, &device);
        // Rebuild the grant with the imposter's bundle + imposter-signed material, same secret.
        let cred = DeviceCredential::issue(&imposter, &device.public(), "iPad", 100);
        let list = DeviceList::signed(&imposter, 1, 100, vec![device.public().node_id_bytes()], vec![]);
        let wire = roster_wire(&imposter.public(), &list, &[cred.clone()], &[]);
        let env = seal_self_sync_key(&imposter, &device.public(), &imposter.self_sync_key()).unwrap();
        let grant = enroll_grant_wire(
            &ticket.secret,
            &imposter.public().to_bytes(),
            &cred.to_bytes(),
            &wire,
            &env.to_bytes(),
            &[],
        );
        assert!(open_enroll_grant(&ticket, &device, &grant).is_err());
    }

    #[test]
    fn grant_credential_for_a_different_device_is_rejected() {
        let account = id(1);
        let device = id(4);
        let other = id(5);
        let (ticket, _, _) = make_grant(&account, &device);
        // Validly account-signed — but it names OTHER, not us. Roster + self-sync grant are
        // otherwise perfect for us, so this isolates check 2.
        let wrong_cred = DeviceCredential::issue(&account, &other.public(), "someone else", 100);
        let good_cred = DeviceCredential::issue(&account, &device.public(), "iPad", 100);
        let list = DeviceList::signed(
            &account, 1, 100,
            vec![device.public().node_id_bytes(), other.public().node_id_bytes()],
            vec![],
        );
        let wire = roster_wire(&account.public(), &list, &[good_cred, wrong_cred.clone()], &[]);
        let env = seal_self_sync_key(&account, &device.public(), &account.self_sync_key()).unwrap();
        let grant = enroll_grant_wire(
            &ticket.secret,
            &account.public().to_bytes(),
            &wrong_cred.to_bytes(),
            &wire,
            &env.to_bytes(),
            &[],
        );
        assert!(open_enroll_grant(&ticket, &device, &grant).is_err());
    }

    #[test]
    fn grant_roster_not_authorizing_the_device_is_rejected() {
        let account = id(1);
        let device = id(4);
        let (ticket, _, _) = make_grant(&account, &device);
        let cred = DeviceCredential::issue(&account, &device.public(), "iPad", 100);
        let env = seal_self_sync_key(&account, &device.public(), &account.self_sync_key()).unwrap();
        // (a) Roster that simply doesn't list us.
        let absent = DeviceList::signed(&account, 1, 100, vec![id(5).public().node_id_bytes()], vec![]);
        // (b) Roster that lists us REVOKED — is_authorized must treat that as not authorized.
        let revoked = DeviceList::signed(
            &account, 2, 100,
            vec![id(5).public().node_id_bytes()],
            vec![device.public().node_id_bytes()],
        );
        for list in [absent, revoked] {
            let wire = roster_wire(&account.public(), &list, &[cred.clone()], &[]);
            let grant = enroll_grant_wire(
                &ticket.secret,
                &account.public().to_bytes(),
                &cred.to_bytes(),
                &wire,
                &env.to_bytes(),
                &[],
            );
            assert!(open_enroll_grant(&ticket, &device, &grant).is_err());
        }
    }

    #[test]
    fn grant_sealed_to_a_different_device_is_rejected() {
        let account = id(1);
        let device = id(4);
        let stranger = id(6);
        let (ticket, _, _) = make_grant(&account, &device);
        let cred = DeviceCredential::issue(&account, &device.public(), "iPad", 100);
        let list = DeviceList::signed(&account, 1, 100, vec![device.public().node_id_bytes()], vec![]);
        let wire = roster_wire(&account.public(), &list, &[cred.clone()], &[]);
        // Checks 1-3 pass; the self-sync grant is sealed to the WRONG bundle → check 4 fails.
        let env = seal_self_sync_key(&account, &stranger.public(), &account.self_sync_key()).unwrap();
        let grant = enroll_grant_wire(
            &ticket.secret,
            &account.public().to_bytes(),
            &cred.to_bytes(),
            &wire,
            &env.to_bytes(),
            &[],
        );
        assert!(open_enroll_grant(&ticket, &device, &grant).is_err());
    }

    // ── The headline S4 property ──────────────────────────────────────────────────────────

    #[test]
    fn no_wire_ever_contains_the_account_seed() {
        // The entire point of seedless enrollment: construct the account from a KNOWN seed and
        // prove the seed bytes appear in NO artifact of the handshake — ticket (binary + text),
        // request, and grant.
        fn contains(haystack: &[u8], needle: &[u8; 32]) -> bool {
            haystack.windows(32).any(|w| w == needle)
        }
        let seed = [0x42u8; 32];
        let account = Identity::from_seed(&seed);
        let device = id(4);
        let (ticket, grant, _) = make_grant(&account, &device);
        let request = enroll_request_wire(&ticket.secret, &device.public().to_bytes(), "iPad", 1_000);

        assert!(!contains(&ticket.to_bytes(), &seed), "ticket must not carry the seed");
        assert!(
            !contains(ticket.encode_text().as_bytes(), &seed),
            "ticket text must not carry the seed"
        );
        assert!(!contains(&request, &seed), "request must not carry the seed");
        assert!(!contains(&grant, &seed), "grant must not carry the seed");
        // And the granted self-sync key is NOT the seed either (it is derived, then granted).
        let out = open_enroll_grant(&ticket, &device, &grant).expect("grant opens");
        assert_ne!(out.self_sync_key, seed, "the granted key must never equal the master seed");
    }
}
