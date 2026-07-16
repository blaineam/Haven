//! FFI surface for **seedless enrollment** (seed-drop S4, `docs/SEEDLESS-ENROLLMENT-PLAN.md` §3).
//!
//! Thin wrappers over [`haven_p2p::enroll`] so every platform builds and parses the exact same
//! `haven-enroll:` ticket + frame-28 request + frame-29 grant bytes (the `encode_circle_sync`
//! convergence discipline — one canonical codec in core, no per-platform drift). All security-critical
//! checks (MAC, freshness, tamper, wrong-device grant) live in core; this boundary only marshals
//! `HavenId`/`Identity` and the fixed-size fields across UniFFI. Nothing here ever sees the account seed
//! except [`enroll_assemble_grant`] / [`seal_self_sync_key_grant`], which take it like
//! `issue_device_credential` and never let it cross back out.

use haven_p2p::device::DeviceCredential;
use haven_p2p::enroll::{
    enroll_grant_wire, enroll_request_wire, open_enroll_grant, verify_enroll_request, EnrollTicket,
};
use haven_p2p::identity::{HavenId, Identity};

use crate::HavenError;

fn seed32(v: Vec<u8>) -> Result<[u8; 32], HavenError> {
    v.try_into().map_err(|_| HavenError::Invalid { msg: "seed must be 32 bytes".into() })
}
fn arr32(v: &[u8], what: &str) -> Result<[u8; 32], HavenError> {
    v.try_into().map_err(|_| HavenError::Invalid { msg: format!("{what} must be 32 bytes") })
}
fn arr16(v: &[u8], what: &str) -> Result<[u8; 16], HavenError> {
    v.try_into().map_err(|_| HavenError::Invalid { msg: format!("{what} must be 16 bytes") })
}
fn bundle(b: &[u8]) -> Result<HavenId, HavenError> {
    HavenId::from_bytes(b).map_err(|e| HavenError::Invalid { msg: format!("bad bundle: {e}") })
}

/// The decoded contents of a `haven-enroll:` link (plan §3.1). Carries the one-time enrollment
/// `secret` — treat it as an authorization credential (single-use, short expiry, screenshot-protected).
#[derive(uniffi::Record)]
pub struct EnrollTicketFfi {
    /// The account's 32-byte routable node id.
    pub account_id: Vec<u8>,
    /// 16-byte tamper hash of the FULL account bundle (`HavenId::verification`).
    pub verification: Vec<u8>,
    /// One-time enrollment secret (32 bytes, CSPRNG). Keys both handshake MACs.
    pub secret: Vec<u8>,
    /// The primary's 32-byte device transport id — the directed dial target for the request.
    pub primary_device: Vec<u8>,
    /// Unix seconds the ticket was minted.
    pub issued_at: u64,
    /// Bootstrap relays.
    pub relays: Vec<String>,
}

impl EnrollTicketFfi {
    fn to_core(&self) -> Result<EnrollTicket, HavenError> {
        Ok(EnrollTicket {
            account_id: arr32(&self.account_id, "account id")?,
            verification: arr16(&self.verification, "verification")?,
            secret: arr32(&self.secret, "secret")?,
            primary_device: arr32(&self.primary_device, "primary device id")?,
            issued_at: self.issued_at,
            relays: self.relays.clone(),
        })
    }
    fn from_core(t: &EnrollTicket) -> Self {
        Self {
            account_id: t.account_id.to_vec(),
            verification: t.verification.to_vec(),
            secret: t.secret.to_vec(),
            primary_device: t.primary_device.to_vec(),
            issued_at: t.issued_at,
            relays: t.relays.clone(),
        }
    }
}

/// The verified contents of a frame-28 enrollment request (what a primary shows in its confirm sheet).
#[derive(uniffi::Record)]
pub struct EnrollRequestFfi {
    /// The requesting device's full public bundle bytes.
    pub device_bundle: Vec<u8>,
    /// The name the device advertised (e.g. "Blaine's iPad").
    pub name: String,
    /// The request timestamp (Unix seconds).
    pub ts: u64,
}

/// Everything a seedless device needs to operate, returned by [`enroll_open_grant`] ONLY after all four
/// acceptance checks pass (plan §3.3) — never partially.
#[derive(uniffi::Record)]
pub struct EnrollGrantFfi {
    /// The full account public bundle, verified against the ticket's id + verification.
    pub account_bundle: Vec<u8>,
    /// This device's account-signed credential bytes.
    pub credential: Vec<u8>,
    /// The primary-signed roster WIRE bytes VERBATIM (incl. capability trailer) — install with
    /// `ingest_roster_wire` so a seedless device persists + rebroadcasts them without re-encoding (A3).
    pub roster_wire: Vec<u8>,
    /// The granted 32-byte self-sync key — seed-grade secret; store like a seed and use with
    /// `seal_account_state_with_key` / `open_account_state_with_key`.
    pub self_sync_key: Vec<u8>,
    /// Bootstrap relays from the primary.
    pub relays: Vec<String>,
}

/// PRIMARY: mint a fresh ticket for `account_bundle` with a CSPRNG secret (via [`EnrollTicket::issue`]).
/// `primary_device` is this primary's 32-byte device transport id (the request's directed dial target).
#[uniffi::export]
pub fn enroll_issue_ticket(
    account_bundle: Vec<u8>,
    primary_device: Vec<u8>,
    issued_at: u64,
    relays: Vec<String>,
) -> Result<EnrollTicketFfi, HavenError> {
    let account = bundle(&account_bundle)?;
    let primary = arr32(&primary_device, "primary device id")?;
    Ok(EnrollTicketFfi::from_core(&EnrollTicket::issue(&account, primary, issued_at, relays)))
}

/// `haven-enroll:<base64url>` text form for the QR / copy affordance.
#[uniffi::export]
pub fn enroll_ticket_encode(ticket: EnrollTicketFfi) -> Result<String, HavenError> {
    Ok(ticket.to_core()?.encode_text())
}

/// Inverse of [`enroll_ticket_encode`] — parse a scanned/pasted `haven-enroll:` link.
#[uniffi::export]
pub fn enroll_ticket_parse(text: String) -> Result<EnrollTicketFfi, HavenError> {
    let t = EnrollTicket::parse_text(&text)
        .map_err(|e| HavenError::Invalid { msg: format!("bad enroll ticket: {e}") })?;
    Ok(EnrollTicketFfi::from_core(&t))
}

/// Expiry helper (single-use tracking + the TTL choice are caller policy; this only makes the arithmetic
/// identical on every platform). A `now` earlier than `issued_at` (clock skew) is NOT expired.
#[uniffi::export]
pub fn enroll_ticket_is_expired(ticket: EnrollTicketFfi, now: u64, ttl_secs: u64) -> Result<bool, HavenError> {
    Ok(ticket.to_core()?.is_expired(now, ttl_secs))
}

/// NEW DEVICE: build the frame-28 request body proving ticket possession (MAC over the device bundle +
/// name + ts under the ticket secret).
#[uniffi::export]
pub fn enroll_build_request(
    secret: Vec<u8>,
    device_bundle: Vec<u8>,
    name: String,
    ts: u64,
) -> Result<Vec<u8>, HavenError> {
    let secret = arr32(&secret, "secret")?;
    Ok(enroll_request_wire(&secret, &device_bundle, &name, ts))
}

/// PRIMARY: verify a frame-28 request — MAC + freshness (`ts` within `max_age_secs` of `now` in BOTH
/// directions). Ticket single-use bookkeeping stays with the caller.
#[uniffi::export]
pub fn enroll_verify_request(
    secret: Vec<u8>,
    wire: Vec<u8>,
    now: u64,
    max_age_secs: u64,
) -> Result<EnrollRequestFfi, HavenError> {
    let secret = arr32(&secret, "secret")?;
    let (device, name, ts) = verify_enroll_request(&secret, &wire, now, max_age_secs)
        .map_err(|e| HavenError::Invalid { msg: format!("enroll request rejected: {e}") })?;
    Ok(EnrollRequestFfi { device_bundle: device.to_bytes(), name, ts })
}

/// PRIMARY (raw): build the frame-29 grant body from already-assembled parts (see [`enroll_assemble_grant`]
/// for the convenience path that also issues the credential + seals the self-sync grant from the seed).
#[uniffi::export]
pub fn enroll_build_grant(
    secret: Vec<u8>,
    account_bundle: Vec<u8>,
    credential: Vec<u8>,
    roster_wire: Vec<u8>,
    self_sync_grant: Vec<u8>,
    relays: Vec<String>,
) -> Result<Vec<u8>, HavenError> {
    let secret = arr32(&secret, "secret")?;
    Ok(enroll_grant_wire(&secret, &account_bundle, &credential, &roster_wire, &self_sync_grant, &relays))
}

/// PRIMARY (convenience, seed-taking): after verifying the request and unioning the device into its roster
/// (`register_device` / `set_my_device_roster`, whose emitted wire is `roster_wire` here), assemble the
/// whole frame-29 grant: issue the account-signed credential, seal the self-sync-key grant to the device
/// bundle, and MAC everything under the ticket secret. Takes `account_seed` like `issue_device_credential`;
/// the seed never crosses back out.
#[uniffi::export]
pub fn enroll_assemble_grant(
    account_seed: Vec<u8>,
    ticket_secret: Vec<u8>,
    device_bundle: Vec<u8>,
    name: String,
    created_at: u64,
    roster_wire: Vec<u8>,
    relays: Vec<String>,
) -> Result<Vec<u8>, HavenError> {
    let acct = Identity::from_seed(&seed32(account_seed)?);
    let secret = arr32(&ticket_secret, "ticket secret")?;
    let device = bundle(&device_bundle)?;
    let credential = DeviceCredential::issue(&acct, &device, &name, created_at).to_bytes();
    let grant_env = haven_p2p::device::seal_self_sync_key(&acct, &device, &acct.self_sync_key())
        .map_err(|e| HavenError::Invalid { msg: format!("seal self-sync grant failed: {e}") })?;
    Ok(enroll_grant_wire(
        &secret,
        &acct.public().to_bytes(),
        &credential,
        &roster_wire,
        &grant_env.to_bytes(),
        &relays,
    ))
}

/// NEW DEVICE: accept a frame-29 grant (plan §3.3, ALL-POSITIVE). Verifies the MAC + account bundle
/// against the ticket, the credential against the account (and that it names THIS device), the roster,
/// and that the self-sync grant opens with our device key. On any failure the device stays in linking
/// mode (idempotent, re-scannable) — never a half-identity.
#[uniffi::export]
pub fn enroll_open_grant(
    device_seed: Vec<u8>,
    ticket: EnrollTicketFfi,
    wire: Vec<u8>,
) -> Result<EnrollGrantFfi, HavenError> {
    let device = Identity::from_seed(&seed32(device_seed)?);
    let ticket = ticket.to_core()?;
    let grant = open_enroll_grant(&ticket, &device, &wire)
        .map_err(|e| HavenError::Invalid { msg: format!("enroll grant rejected: {e}") })?;
    Ok(EnrollGrantFfi {
        account_bundle: grant.account.to_bytes(),
        credential: grant.credential.to_bytes(),
        roster_wire: grant.roster_wire,
        self_sync_key: grant.self_sync_key.to_vec(),
        relays: grant.relays,
    })
}
