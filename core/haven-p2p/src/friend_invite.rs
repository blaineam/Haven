//! Offline friend invites — async first contact over the relay mailbox
//! (`docs/OFFLINE-FRIEND-INVITES.md`).
//!
//! Today the friend handshake needs both parties online at once, twice: the acceptor's hello is
//! a live iroh dial (the mailbox leg writes only to the ACCEPTOR's own relays, which the inviter
//! never polls — and writing to the inviter's relay is refused at `blob_forbidden`'s membership
//! gate), and the approval reply has the same shape in reverse. This module is the core of the
//! fix: the invite becomes a ticket ([`FriendTicket`], the [`crate::enroll::EnrollTicket`]
//! pattern) carrying a one-time secret and the inviter's bootstrap relays, and both handshake
//! halves become sealed blobs parked under an unguessable, token-derived relay key that each
//! side polls at its leisure:
//!
//!   `haven/invite/<inviter-acct-hex>/<token-id-hex>`         ← acceptance drop (B writes)
//!   `haven/invite/<inviter-acct-hex>/<token-id-hex>/grant`   ← approval grant (A writes)
//!
//! Authorization model: the PUT path itself is the capability — `token_id` is a keyed hash of
//! the ticket secret, so only a link holder can name a valid key. The relay verifies only
//! STRUCTURE ([`verify_invite_blob_structure`]: magic, version, path consistency, expiry, size)
//! and stays blind; the MAC and the AES-GCM seal are keyed from the ticket secret and verified
//! by the parties ([`open_invite_blob`]). Domain-separated keys mean a drop can never replay as
//! a grant. Everything here is pure (no clock, no I/O; the only RNG is the explicit CSPRNG in
//! [`FriendTicket::issue`]) so it is deterministic and testable on every platform.

use rand::rngs::OsRng;
use rand::RngCore;

use crate::crypto;
use crate::identity::HavenId;
use crate::{CoreError, Result};

/// Text-form scheme for a standalone ticket (platforms may instead embed the same base64url
/// payload in the share link's `?t=` query, next to the `?d=` device hints — old parsers
/// ignore unknown query params, so legacy links keep working).
const SCHEME: &str = "haven-friend:";

const TICKET_VERSION: u8 = 1;
const BLOB_VERSION: u8 = 1;

/// First bytes of every invite blob, so the relay can cheaply refuse foreign writes to the lane.
pub const BLOB_MAGIC: &[u8; 4] = b"HVI1";

/// Blob kinds. The kind byte is bound into the MAC and selects the sealing key, so the two
/// directions can never be confused for one another.
const KIND_DROP: u8 = 0;
const KIND_GRANT: u8 = 1;

/// Domain-separation strings. `token_id` deliberately uses its own domain: knowing a token id
/// (it is in the relay path) must reveal nothing about the MAC or sealing keys.
const ID_DOMAIN: &[u8] = b"haven-invite-id-v1";
const MAC_DOMAIN: &[u8] = b"haven-invite-mac-v1";
const SEAL_DROP_DOMAIN: &[u8] = b"haven-invite-seal-drop-v1";
const SEAL_GRANT_DOMAIN: &[u8] = b"haven-invite-seal-grant-v1";

const MAC_LEN: usize = 32;

/// Default ticket lifetime: 30 days. Device-linking tickets live 10 minutes because both ends
/// are the same person mid-task; a friend invite waits for someone ELSE to get around to it.
pub const DEFAULT_TTL_SECS: u64 = 30 * 24 * 3600;

/// Relay-side size cap for one invite blob (drop or grant). A contact bundle + roster + relay
/// list is ~4-5 KB sealed; 16 KB leaves headroom without opening a storage funnel.
pub const MAX_INVITE_BLOB: usize = 16 * 1024;

// ── Ticket ───────────────────────────────────────────────────────────────────────────────────

/// The decoded invite ticket. Treat like an authorization credential: whoever holds it can
/// accept the invite AND read both handshake blobs — the link is the capability, exactly the
/// trust the pre-ticket invite link already carried.
#[derive(Clone)]
pub struct FriendTicket {
    /// The inviter's 32-byte routable account id (`HavenLink.id`).
    pub account_id: [u8; 32],
    /// 16-byte tamper hash of the inviter's FULL hybrid bundle ([`HavenId::verification`]).
    /// The bundle rides the grant and is checked against this — the `HavenLink::matches` shape.
    pub verification: [u8; 16],
    /// One-time invite secret (CSPRNG). Everything else — token id, MAC keys, sealing keys —
    /// derives from this.
    pub secret: [u8; 32],
    /// Unix seconds the ticket was minted (caller-supplied clock).
    pub issued_at: u64,
    /// The inviter's bootstrap relays — the field the friend link was missing; without it the
    /// acceptor has nowhere durable to write. Same precedent as `haven-link:` transfer codes
    /// and `EnrollTicket.relays`.
    pub relays: Vec<String>,
    /// The inviter's device transport ids (the `?d=` hints, so a ticket is self-contained for
    /// the live-path fallback too).
    pub device_hints: Vec<[u8; 32]>,
}

impl FriendTicket {
    /// Mint a ticket with a fresh CSPRNG secret. Tests construct the struct directly.
    pub fn issue(
        account: &HavenId,
        issued_at: u64,
        relays: Vec<String>,
        device_hints: Vec<[u8; 32]>,
    ) -> Self {
        let mut secret = [0u8; 32];
        OsRng.fill_bytes(&mut secret);
        Self {
            account_id: account.node_id_bytes(),
            verification: account.verification(),
            secret,
            issued_at,
            relays,
            device_hints,
        }
    }

    /// Has more than `ttl_secs` elapsed since `issued_at`? Single-use tracking is caller
    /// policy; this only makes the arithmetic identical everywhere. Earlier-than-issued `now`
    /// (clock skew) is NOT expired.
    pub fn is_expired(&self, now: u64, ttl_secs: u64) -> bool {
        now.saturating_sub(self.issued_at) > ttl_secs
    }

    /// The token id naming this invite's relay keys. Keyed hash so the PATH reveals nothing
    /// about the secret, and unguessable so the path itself is the write capability.
    pub fn token_id(&self) -> [u8; 32] {
        derive32(&self.secret, ID_DOMAIN)
    }

    /// Relay key for the acceptance drop.
    pub fn drop_key(&self) -> String {
        format!("haven/invite/{}/{}", hex32(&self.account_id), hex32(&self.token_id()))
    }

    /// Relay key for the approval grant.
    pub fn grant_key(&self) -> String {
        format!("{}/grant", self.drop_key())
    }

    /// Does the full bundle (fetched via the grant) match what this ticket promised?
    pub fn matches(&self, fetched: &HavenId) -> bool {
        fetched.node_id_bytes() == self.account_id && fetched.verification() == self.verification
    }

    /// Binary form: `ver(1)=1 ‖ account_id(32) ‖ verification(16) ‖ secret(32) ‖
    /// issued_at(8 LE) ‖ n_relays(4 LE) ‖ lp(relay)*n ‖ n_hints(4 LE) ‖ hint(32)*n`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(1 + 32 + 16 + 32 + 8 + 8);
        v.push(TICKET_VERSION);
        v.extend_from_slice(&self.account_id);
        v.extend_from_slice(&self.verification);
        v.extend_from_slice(&self.secret);
        v.extend_from_slice(&self.issued_at.to_le_bytes());
        v.extend_from_slice(&(self.relays.len() as u32).to_le_bytes());
        for r in &self.relays {
            lp(&mut v, r.as_bytes());
        }
        v.extend_from_slice(&(self.device_hints.len() as u32).to_le_bytes());
        for h in &self.device_hints {
            v.extend_from_slice(h);
        }
        v
    }

    /// Inverse of [`Self::to_bytes`]. Strict: trailing bytes are a parse error.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b);
        if r.u8()? != TICKET_VERSION {
            return Err(CoreError::Encoding("friend ticket: unsupported version"));
        }
        let account_id = r.array32()?;
        let verification: [u8; 16] = r.take(16)?.try_into().unwrap();
        let secret = r.array32()?;
        let issued_at = r.u64()?;
        let n = r.u32()? as usize;
        let mut relays = Vec::with_capacity(n.min(64));
        for _ in 0..n {
            relays.push(r.str_lp()?);
        }
        let nh = r.u32()? as usize;
        let mut device_hints = Vec::with_capacity(nh.min(16));
        for _ in 0..nh {
            device_hints.push(r.array32()?);
        }
        if !r.rest().is_empty() {
            return Err(CoreError::Encoding("friend ticket: trailing bytes"));
        }
        Ok(Self { account_id, verification, secret, issued_at, relays, device_hints })
    }

    /// `haven-friend:<base64url-nopad(binary)>` — standalone text form.
    pub fn encode_text(&self) -> String {
        format!("{}{}", SCHEME, data_encoding::BASE64URL_NOPAD.encode(&self.to_bytes()))
    }

    /// Inverse of [`Self::encode_text`].
    pub fn parse_text(s: &str) -> Result<Self> {
        let payload = s
            .trim()
            .strip_prefix(SCHEME)
            .ok_or(CoreError::BadLink("not a haven-friend: ticket"))?;
        let bytes = data_encoding::BASE64URL_NOPAD
            .decode(payload.as_bytes())
            .map_err(|_| CoreError::BadLink("friend ticket is not valid base64url"))?;
        Self::from_bytes(&bytes)
    }
}

// ── Blobs (drop + grant) ─────────────────────────────────────────────────────────────────────

fn derive32(secret: &[u8; 32], domain: &[u8]) -> [u8; 32] {
    let mut h = blake3::Hasher::new_keyed(secret);
    h.update(domain);
    *h.finalize().as_bytes()
}

fn seal_domain(kind: u8) -> &'static [u8] {
    if kind == KIND_DROP {
        SEAL_DROP_DOMAIN
    } else {
        SEAL_GRANT_DOMAIN
    }
}

fn blob_mac(secret: &[u8; 32], kind: u8, account: &[u8; 32], token: &[u8; 32], expires: u64, sealed: &[u8]) -> blake3::Hash {
    let mac_key = derive32(secret, MAC_DOMAIN);
    let mut h = blake3::Hasher::new_keyed(&mac_key);
    h.update(&[kind]);
    h.update(account);
    h.update(token);
    h.update(&expires.to_le_bytes());
    h.update(sealed);
    h.finalize()
}

/// Build one invite blob:
/// `magic(4)="HVI1" ‖ ver(1)=1 ‖ kind(1) ‖ account_id(32) ‖ token_id(32) ‖ expires(8 LE) ‖
/// lp(sealed) ‖ mac(32)` where `sealed = AES-256-GCM(derive(secret, kind-domain), payload)`
/// and the MAC is keyed by `derive(secret, mac-domain)` over everything between them.
fn blob_wire(ticket_secret: &[u8; 32], kind: u8, account: &[u8; 32], expires: u64, payload: &[u8]) -> Vec<u8> {
    let token = derive32(ticket_secret, ID_DOMAIN);
    let seal_key = derive32(ticket_secret, seal_domain(kind));
    let sealed = crypto::seal(&seal_key, payload);
    let mut v = Vec::with_capacity(4 + 1 + 1 + 32 + 32 + 8 + 4 + sealed.len() + MAC_LEN);
    v.extend_from_slice(BLOB_MAGIC);
    v.push(BLOB_VERSION);
    v.push(kind);
    v.extend_from_slice(account);
    v.extend_from_slice(&token);
    v.extend_from_slice(&expires.to_le_bytes());
    lp(&mut v, &sealed);
    v.extend_from_slice(blob_mac(ticket_secret, kind, account, &token, expires, &sealed).as_bytes());
    v
}

/// The acceptor's sealed acceptance (their contact bundle + relays + roster wire, as the
/// platform assembles it) for the ticket's drop key.
pub fn invite_drop_wire(ticket: &FriendTicket, expires: u64, payload: &[u8]) -> Vec<u8> {
    blob_wire(&ticket.secret, KIND_DROP, &ticket.account_id, expires, payload)
}

/// The inviter's sealed approval grant (their full bundle + relay announces + circle grant)
/// for the ticket's grant key.
pub fn invite_grant_wire(ticket: &FriendTicket, expires: u64, payload: &[u8]) -> Vec<u8> {
    blob_wire(&ticket.secret, KIND_GRANT, &ticket.account_id, expires, payload)
}

/// Parsed-but-unopened header fields (no secret required).
struct BlobHeader<'a> {
    kind: u8,
    account: [u8; 32],
    token: [u8; 32],
    expires: u64,
    sealed: &'a [u8],
    mac: &'a [u8],
}

fn parse_header(b: &[u8]) -> Result<BlobHeader<'_>> {
    let mut r = Reader::new(b);
    if r.take(4)? != BLOB_MAGIC {
        return Err(CoreError::Encoding("invite blob: bad magic"));
    }
    if r.u8()? != BLOB_VERSION {
        return Err(CoreError::Encoding("invite blob: unsupported version"));
    }
    let kind = r.u8()?;
    if kind != KIND_DROP && kind != KIND_GRANT {
        return Err(CoreError::Encoding("invite blob: unknown kind"));
    }
    let account = r.array32()?;
    let token = r.array32()?;
    let expires = r.u64()?;
    let sealed = r.bytes_lp()?;
    let mac = r.take(MAC_LEN)?;
    if !r.rest().is_empty() {
        return Err(CoreError::Encoding("invite blob: trailing bytes"));
    }
    Ok(BlobHeader { kind, account, token, expires, sealed, mac })
}

/// RELAY-side structural check — everything a blind store can verify without the secret:
/// magic + version + known kind, the embedded account/token match the key path, not expired,
/// and within the size cap. The path being unguessable is the write authorization; this check
/// only keeps the lane from becoming generic storage.
pub fn verify_invite_blob_structure(
    b: &[u8],
    path_account: &[u8; 32],
    path_token: &[u8; 32],
    expect_grant: bool,
    now: u64,
) -> bool {
    if b.len() > MAX_INVITE_BLOB {
        return false;
    }
    match parse_header(b) {
        Ok(h) => {
            h.account == *path_account
                && h.token == *path_token
                && (h.kind == KIND_GRANT) == expect_grant
                && h.expires > now
        }
        Err(_) => false,
    }
}

/// Party-side open: full structural parse, token check against the ticket, constant-time MAC
/// verify, expiry, then AEAD open. `expect_grant` pins the direction — an acceptor polling for
/// the grant can never be fed its own drop back.
pub fn open_invite_blob(ticket: &FriendTicket, expect_grant: bool, b: &[u8], now: u64) -> Result<Vec<u8>> {
    let h = parse_header(b)?;
    if (h.kind == KIND_GRANT) != expect_grant {
        return Err(CoreError::Crypto("invite blob: wrong direction"));
    }
    if h.account != ticket.account_id {
        return Err(CoreError::Crypto("invite blob: wrong account"));
    }
    if h.token != ticket.token_id() {
        return Err(CoreError::Crypto("invite blob: wrong token"));
    }
    if h.expires <= now {
        return Err(CoreError::Crypto("invite blob: expired"));
    }
    let expect = blob_mac(&ticket.secret, h.kind, &h.account, &h.token, h.expires, h.sealed);
    // blake3::Hash == [u8; 32] is constant-time — no byte-by-byte oracle.
    let mac: [u8; 32] = h.mac.try_into().unwrap();
    if expect != blake3::Hash::from(mac) {
        return Err(CoreError::Crypto("invite blob: MAC mismatch"));
    }
    let seal_key = derive32(&ticket.secret, seal_domain(h.kind));
    crypto::open(&seal_key, h.sealed)
}

/// Lowercase hex for 32-byte ids — the relay key form used across the mailbox.
fn hex32(b: &[u8; 32]) -> String {
    let mut s = String::with_capacity(64);
    for x in b {
        use std::fmt::Write;
        let _ = write!(s, "{x:02x}");
    }
    s
}

// ── Wire helpers (mirrored from enroll.rs, whose Reader is private) ─────────────────────────

fn lp(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u32).to_le_bytes());
    out.extend_from_slice(b);
}

struct Reader<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Reader<'a> {
    fn new(b: &'a [u8]) -> Self {
        Self { b, i: 0 }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.i + n > self.b.len() {
            return Err(CoreError::Encoding("invite wire: unexpected end of input"));
        }
        let s = &self.b[self.i..self.i + n];
        self.i += n;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn array32(&mut self) -> Result<[u8; 32]> {
        Ok(self.take(32)?.try_into().unwrap())
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn bytes_lp(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn str_lp(&mut self) -> Result<String> {
        let b = self.bytes_lp()?;
        String::from_utf8(b.to_vec()).map_err(|_| CoreError::Encoding("invite wire: invalid utf-8"))
    }
    fn rest(&self) -> &'a [u8] {
        &self.b[self.i..]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    fn ticket() -> FriendTicket {
        let id = Identity::from_seed(&[7u8; 32]);
        FriendTicket {
            account_id: id.public().node_id_bytes(),
            verification: id.public().verification(),
            secret: [42u8; 32],
            issued_at: 1_000,
            relays: vec!["a".repeat(64), "b".repeat(64)],
            device_hints: vec![[9u8; 32]],
        }
    }

    #[test]
    fn ticket_roundtrips_binary_and_text() {
        let t = ticket();
        let back = FriendTicket::from_bytes(&t.to_bytes()).unwrap();
        assert_eq!(back.account_id, t.account_id);
        assert_eq!(back.verification, t.verification);
        assert_eq!(back.secret, t.secret);
        assert_eq!(back.issued_at, t.issued_at);
        assert_eq!(back.relays, t.relays);
        assert_eq!(back.device_hints, t.device_hints);
        let back2 = FriendTicket::parse_text(&t.encode_text()).unwrap();
        assert_eq!(back2.secret, t.secret);
    }

    #[test]
    fn ticket_rejects_trailing_bytes_and_wrong_scheme() {
        let t = ticket();
        let mut b = t.to_bytes();
        b.push(0);
        assert!(FriendTicket::from_bytes(&b).is_err());
        assert!(FriendTicket::parse_text("haven-enroll:AAAA").is_err());
    }

    #[test]
    fn expiry_arithmetic() {
        let t = ticket();
        assert!(!t.is_expired(1_000 + DEFAULT_TTL_SECS, DEFAULT_TTL_SECS));
        assert!(t.is_expired(1_001 + DEFAULT_TTL_SECS, DEFAULT_TTL_SECS));
        assert!(!t.is_expired(0, DEFAULT_TTL_SECS)); // skew: earlier than issued ≠ expired
    }

    #[test]
    fn drop_and_grant_roundtrip_and_stay_separate() {
        let t = ticket();
        let drop = invite_drop_wire(&t, 5_000, b"acceptance payload");
        let grant = invite_grant_wire(&t, 5_000, b"grant payload");
        assert_eq!(open_invite_blob(&t, false, &drop, 4_999).unwrap(), b"acceptance payload");
        assert_eq!(open_invite_blob(&t, true, &grant, 4_999).unwrap(), b"grant payload");
        // Direction confusion is rejected both ways.
        assert!(open_invite_blob(&t, true, &drop, 4_999).is_err());
        assert!(open_invite_blob(&t, false, &grant, 4_999).is_err());
    }

    #[test]
    fn tampered_mac_or_body_is_rejected() {
        let t = ticket();
        let mut b = invite_drop_wire(&t, 5_000, b"payload");
        let n = b.len();
        b[n - 1] ^= 1; // MAC tail
        assert!(open_invite_blob(&t, false, &b, 100).is_err());
        let mut b2 = invite_drop_wire(&t, 5_000, b"payload");
        b2[80] ^= 1; // inside the sealed region / header
        assert!(open_invite_blob(&t, false, &b2, 100).is_err());
    }

    #[test]
    fn wrong_secret_cannot_open() {
        let t = ticket();
        let b = invite_drop_wire(&t, 5_000, b"payload");
        let mut other = ticket();
        other.secret = [43u8; 32];
        assert!(open_invite_blob(&other, false, &b, 100).is_err());
    }

    #[test]
    fn expired_blob_is_rejected_by_both_sides() {
        let t = ticket();
        let b = invite_drop_wire(&t, 5_000, b"payload");
        assert!(open_invite_blob(&t, false, &b, 5_000).is_err());
        let tok = t.token_id();
        assert!(!verify_invite_blob_structure(&b, &t.account_id, &tok, false, 5_000));
    }

    #[test]
    fn relay_structural_check_needs_no_secret() {
        let t = ticket();
        let tok = t.token_id();
        let drop = invite_drop_wire(&t, 5_000, b"payload");
        assert!(verify_invite_blob_structure(&drop, &t.account_id, &tok, false, 100));
        // Wrong path token, wrong account, wrong direction, garbage: all refused.
        assert!(!verify_invite_blob_structure(&drop, &t.account_id, &[0u8; 32], false, 100));
        assert!(!verify_invite_blob_structure(&drop, &[0u8; 32], &tok, false, 100));
        assert!(!verify_invite_blob_structure(&drop, &t.account_id, &tok, true, 100));
        assert!(!verify_invite_blob_structure(b"HVI1garbage", &t.account_id, &tok, false, 100));
        let grant = invite_grant_wire(&t, 5_000, b"payload");
        assert!(verify_invite_blob_structure(&grant, &t.account_id, &tok, true, 100));
    }

    #[test]
    fn keys_are_stable_and_path_shaped() {
        let t = ticket();
        let dk = t.drop_key();
        assert!(dk.starts_with("haven/invite/"));
        assert_eq!(dk.split('/').count(), 4);
        assert_eq!(t.grant_key(), format!("{dk}/grant"));
        // Token id reveals nothing secret-shaped and is stable.
        assert_eq!(t.token_id(), ticket().token_id());
        assert_ne!(t.token_id(), t.secret);
    }
}
