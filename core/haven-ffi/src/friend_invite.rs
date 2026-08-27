//! FFI surface for offline friend invites (`docs/OFFLINE-FRIEND-INVITES.md`) — the platform-facing
//! half of `haven-p2p/src/friend_invite.rs`. Same shape as `enroll.rs`: thin records + pure
//! functions; single-use tracking, TTL choice, and the relay I/O are caller policy.

use haven_p2p::friend_invite::{
    invite_drop_wire, invite_grant_wire, open_invite_blob, FriendTicket, DEFAULT_TTL_SECS,
};
use haven_p2p::identity::HavenId;

use crate::HavenError;

fn arr32(v: &[u8], what: &str) -> Result<[u8; 32], HavenError> {
    v.try_into().map_err(|_| HavenError::Invalid { msg: format!("{what} must be 32 bytes") })
}
fn arr16(v: &[u8], what: &str) -> Result<[u8; 16], HavenError> {
    v.try_into().map_err(|_| HavenError::Invalid { msg: format!("{what} must be 16 bytes") })
}
fn bundle(b: &[u8]) -> Result<HavenId, HavenError> {
    HavenId::from_bytes(b).map_err(|e| HavenError::Invalid { msg: format!("bad bundle: {e}") })
}

/// The decoded friend-invite ticket. Carries the one-time `secret` — treat like an authorization
/// credential: whoever holds it can accept the invite and read both handshake blobs (the link is
/// the capability, exactly the trust the pre-ticket invite link already carried).
#[derive(uniffi::Record)]
pub struct FriendTicketFfi {
    /// The inviter's 32-byte routable account id.
    pub account_id: Vec<u8>,
    /// 16-byte tamper hash of the inviter's FULL hybrid bundle.
    pub verification: Vec<u8>,
    /// One-time invite secret (32 bytes, CSPRNG). Token id, MAC and sealing keys derive from it.
    pub secret: Vec<u8>,
    /// Unix seconds the ticket was minted.
    pub issued_at: u64,
    /// The inviter's bootstrap relays — where the acceptance drop is written and the grant polled.
    pub relays: Vec<String>,
    /// The inviter's device transport ids (live-path fallback dial targets).
    pub device_hints: Vec<Vec<u8>>,
}

impl FriendTicketFfi {
    fn to_core(&self) -> Result<FriendTicket, HavenError> {
        Ok(FriendTicket {
            account_id: arr32(&self.account_id, "account id")?,
            verification: arr16(&self.verification, "verification")?,
            secret: arr32(&self.secret, "secret")?,
            issued_at: self.issued_at,
            relays: self.relays.clone(),
            device_hints: self
                .device_hints
                .iter()
                .map(|h| arr32(h, "device hint"))
                .collect::<Result<Vec<_>, _>>()?,
        })
    }
    fn from_core(t: &FriendTicket) -> Self {
        Self {
            account_id: t.account_id.to_vec(),
            verification: t.verification.to_vec(),
            secret: t.secret.to_vec(),
            issued_at: t.issued_at,
            relays: t.relays.clone(),
            device_hints: t.device_hints.iter().map(|h| h.to_vec()).collect(),
        }
    }
}

/// The 30-day default ticket lifetime (device-linking uses 10 minutes; a friend invite waits for
/// someone ELSE to get around to it).
#[uniffi::export]
pub fn friend_invite_default_ttl_secs() -> u64 {
    DEFAULT_TTL_SECS
}

/// INVITER: mint a ticket for `account_bundle` with a fresh CSPRNG secret.
#[uniffi::export]
pub fn friend_invite_issue(
    account_bundle: Vec<u8>,
    issued_at: u64,
    relays: Vec<String>,
    device_hints: Vec<Vec<u8>>,
) -> Result<FriendTicketFfi, HavenError> {
    let account = bundle(&account_bundle)?;
    let hints = device_hints
        .iter()
        .map(|h| arr32(h, "device hint"))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(FriendTicketFfi::from_core(&FriendTicket::issue(&account, issued_at, relays, hints)))
}

/// `haven-friend:<base64url>` — the standalone text form. Platforms may instead embed the same
/// payload in the share link's `?t=` query (next to the `?d=` hints), which legacy parsers ignore.
#[uniffi::export]
pub fn friend_ticket_encode(ticket: FriendTicketFfi) -> Result<String, HavenError> {
    Ok(ticket.to_core()?.encode_text())
}

/// Inverse of [`friend_ticket_encode`].
#[uniffi::export]
pub fn friend_ticket_parse(text: String) -> Result<FriendTicketFfi, HavenError> {
    let t = FriendTicket::parse_text(&text)
        .map_err(|e| HavenError::Invalid { msg: format!("bad friend ticket: {e}") })?;
    Ok(FriendTicketFfi::from_core(&t))
}

/// Expiry arithmetic, identical on every platform. Earlier-than-issued `now` is NOT expired.
#[uniffi::export]
pub fn friend_ticket_is_expired(
    ticket: FriendTicketFfi,
    now: u64,
    ttl_secs: u64,
) -> Result<bool, HavenError> {
    Ok(ticket.to_core()?.is_expired(now, ttl_secs))
}

/// Does a fetched full bundle match what the ticket promised (id + 16-byte verification)?
/// The MITM/tamper check to run on the grant's bundle before trusting it.
#[uniffi::export]
pub fn friend_ticket_matches(ticket: FriendTicketFfi, account_bundle: Vec<u8>) -> Result<bool, HavenError> {
    Ok(ticket.to_core()?.matches(&bundle(&account_bundle)?))
}

/// The relay key the ACCEPTOR writes (and the inviter polls): `haven/invite/<acct>/<token>`.
#[uniffi::export]
pub fn friend_invite_drop_key(ticket: FriendTicketFfi) -> Result<String, HavenError> {
    Ok(ticket.to_core()?.drop_key())
}

/// The relay key the INVITER writes on approval (and the acceptor polls): `…/grant`.
#[uniffi::export]
pub fn friend_invite_grant_key(ticket: FriendTicketFfi) -> Result<String, HavenError> {
    Ok(ticket.to_core()?.grant_key())
}

/// ACCEPTOR: seal the acceptance payload (contact bundle + relays + roster wire, as the platform
/// assembles it) into the drop blob for [`friend_invite_drop_key`].
#[uniffi::export]
pub fn friend_invite_build_drop(
    ticket: FriendTicketFfi,
    expires: u64,
    payload: Vec<u8>,
) -> Result<Vec<u8>, HavenError> {
    Ok(invite_drop_wire(&ticket.to_core()?, expires, &payload))
}

/// INVITER: open + verify an acceptance drop fetched from [`friend_invite_drop_key`].
#[uniffi::export]
pub fn friend_invite_open_drop(
    ticket: FriendTicketFfi,
    blob: Vec<u8>,
    now: u64,
) -> Result<Vec<u8>, HavenError> {
    open_invite_blob(&ticket.to_core()?, false, &blob, now)
        .map_err(|e| HavenError::Invalid { msg: format!("invite drop refused: {e}") })
}

/// INVITER: seal the approval grant (full bundle + relay announces + circle grant) into the blob
/// for [`friend_invite_grant_key`].
#[uniffi::export]
pub fn friend_invite_build_grant(
    ticket: FriendTicketFfi,
    expires: u64,
    payload: Vec<u8>,
) -> Result<Vec<u8>, HavenError> {
    Ok(invite_grant_wire(&ticket.to_core()?, expires, &payload))
}

/// ACCEPTOR: open + verify a grant fetched from [`friend_invite_grant_key`].
#[uniffi::export]
pub fn friend_invite_open_grant(
    ticket: FriendTicketFfi,
    blob: Vec<u8>,
    now: u64,
) -> Result<Vec<u8>, HavenError> {
    open_invite_blob(&ticket.to_core()?, true, &blob, now)
        .map_err(|e| HavenError::Invalid { msg: format!("invite grant refused: {e}") })
}
