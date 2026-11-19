//! The slice of the Haven app wire protocol the browser session speaks so far.
//!
//! ```text
//!   Frame         = [type:u8][payload]
//!   Event payload = [LP circleId][sealed envelope]
//!   LP field      = [u16 LE len][bytes]
//! ```
//!
//! The canonical Rust port is `desktop/src-tauri/src/wire.rs` (byte-exact with iOS `FeedStore` and
//! Android `Wire.kt`). These few items are duplicated here only until that client layer is lifted
//! into a crate both the desktop app and the browser build link; they must stay identical to it.

/// `[LP circleId][sealed envelope]` — a circle event (post, reaction, key commit, roster, …).
pub const EVENT: u8 = 1;
/// A SEEDLESS new device proves possession of the one-time enroll ticket (body: core request wire).
pub const SEEDLESS_ENROLL_REQ: u8 = 28;
/// The primary's answer: credential + verbatim roster + sealed self-sync key (body: core grant wire).
pub const SEEDLESS_ENROLL_GRANT: u8 = 29;

pub fn frame(t: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + payload.len());
    out.push(t);
    out.extend_from_slice(payload);
    out
}

pub fn event_payload(circle_id: &str, envelope: &[u8]) -> Vec<u8> {
    let id = circle_id.as_bytes();
    let mut out = Vec::with_capacity(2 + id.len() + envelope.len());
    out.extend_from_slice(&(id.len() as u16).to_le_bytes());
    out.extend_from_slice(id);
    out.extend_from_slice(envelope);
    out
}

/// Inverse of [`event_payload`]: `(circle id, sealed envelope)`.
pub fn parse_event(payload: &[u8]) -> Option<(String, &[u8])> {
    let len = u16::from_le_bytes([*payload.first()?, *payload.get(1)?]) as usize;
    let id = payload.get(2..2 + len)?;
    Some((String::from_utf8(id.to_vec()).ok()?, &payload[2 + len..]))
}
