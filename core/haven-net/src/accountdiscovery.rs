//! **Account → device discovery**, so two peers who are both online can always reach each other
//! without a relay.
//!
//! ## The gap this closes
//!
//! iroh already solves *node id → address*: n0's pkarr/DNS lookup plus hole punching will connect
//! two endpoints anywhere, with no Haven infrastructure involved. What it does NOT answer is
//! **which device node ids belong to an account**. Under device-seed keying a Haven account id is a
//! contact *handle*, not a dialable endpoint — only a device id can be dialled. Today a peer learns
//! device ids from an invite link's `?d=` hints, a signed roster frame, or a relay's devroster key.
//! A contact added without hints, whose roster never arrived, and with whom you share no relay, has
//! **no dialable id at all** — so "no common relay" degrades to "no communication", even though
//! both devices are online and hole punching would work fine.
//!
//! This module publishes the account's device list under the **account key** as a pkarr record.
//! Anyone who knows the account handle — which is exactly what a contact has — resolves it through
//! the same DNS plane iroh already uses, learns the device ids, and dials them directly.
//!
//! ## Why this is safe
//!
//! The record is signed by the account key itself (pkarr signs the packet), so neither a relay nor
//! a resolver nor n0 can forge one: they can only withhold it, which is the same denial-of-service
//! floor `discovery.rs` already documents. And the answer is a **hint, never authority** — dialling
//! a device id still completes a QUIC/TLS handshake that authenticates that exact key, so a wrong
//! or malicious address simply fails to connect. Publishing is opt-in per account and contains only
//! device ids the account already advertises in its signed roster.
//!
//! Privacy note: a pkarr record is public, so this makes "account X has N devices with these ids"
//! resolvable by anyone who already knows X's account id. That is the same exposure n0's DNS
//! already gives for any node id, and strictly less than the account handle itself reveals — but it
//! is a deliberate trade, which is why the caller decides when to publish.

use anyhow::{anyhow, Result};

/// Marks a Haven account record and versions the payload, so a future format can change shape
/// without a resolver mistaking it for this one.
const PREFIX: &str = "hvd1:";

/// A pkarr TXT user-data string is capped at 245 bytes (iroh `UserData::MAX_LENGTH`). Each device
/// is 43 base64url chars plus a separator, so five is what fits with the prefix. Five dialable
/// devices is far past what a real account has; the roster is the authority either way, and this is
/// only the bootstrap hint that lets the first packet flow.
pub const MAX_DEVICES: usize = 5;

/// URL-safe base64 without padding — 43 chars for 32 bytes, against 64 for hex. That difference is
/// what makes five devices fit in the record instead of three.
fn b64url_encode(bytes: &[u8; 32]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(43);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(A[(n >> 18) as usize & 63] as char);
        out.push(A[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 { out.push(A[(n >> 6) as usize & 63] as char); }
        if chunk.len() > 2 { out.push(A[n as usize & 63] as char); }
    }
    out
}

fn b64url_decode(s: &str) -> Option<[u8; 32]> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'-' => Some(62),
            b'_' => Some(63),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    if bytes.len() != 43 { return None; }
    let mut out = [0u8; 32];
    let mut oi = 0usize;
    for chunk in bytes.chunks(4) {
        let mut n = 0u32;
        for (i, c) in chunk.iter().enumerate() {
            n |= val(*c)? << (18 - 6 * i);
        }
        // 4 chars -> 3 bytes, 3 chars -> 2 bytes, 2 chars -> 1 byte.
        let produced = chunk.len() - 1;
        for i in 0..produced {
            if oi >= 32 { break; }
            out[oi] = ((n >> (16 - 8 * i)) & 0xff) as u8;
            oi += 1;
        }
    }
    if oi == 32 { Some(out) } else { None }
}

/// Build the record payload for `devices`. Capped at [`MAX_DEVICES`]; order is preserved so the
/// caller can put the most-likely-reachable device first.
pub fn encode_devices(devices: &[[u8; 32]]) -> String {
    let mut s = String::from(PREFIX);
    for (i, d) in devices.iter().take(MAX_DEVICES).enumerate() {
        if i > 0 { s.push('.'); }
        s.push_str(&b64url_encode(d));
    }
    s
}

/// Parse a record payload. Unknown prefixes and malformed entries yield nothing rather than an
/// error — this is a hint source, and a resolver must never hard-fail on a stranger's record.
pub fn decode_devices(payload: &str) -> Vec<[u8; 32]> {
    let Some(rest) = payload.strip_prefix(PREFIX) else { return Vec::new() };
    rest.split('.')
        .filter(|s| !s.is_empty())
        .filter_map(b64url_decode)
        .take(MAX_DEVICES)
        .collect()
}

fn to_hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn from_hex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 { return None; }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

/// Hex helper for the FFI boundary, which speaks hex everywhere else.
pub fn decode_devices_hex(payload: &str) -> Vec<String> {
    decode_devices(payload).iter().map(|d| to_hex(d)).collect()
}

/// Encode from hex device ids (FFI side). Malformed entries are skipped rather than failing the
/// whole publish — one bad id must not cost the account its discovery record.
pub fn encode_devices_hex(hexes: &[String]) -> Result<String> {
    let out: Vec<[u8; 32]> = hexes.iter().filter_map(|h| from_hex32(h.trim())).collect();
    if out.is_empty() && !hexes.is_empty() {
        return Err(anyhow!("no valid 32-byte device ids among {} entries", hexes.len()));
    }
    Ok(encode_devices(&out))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev(seed: u8) -> [u8; 32] { [seed; 32] }

    #[test]
    fn round_trips_a_single_device() {
        let d = dev(7);
        let s = encode_devices(&[d]);
        assert!(s.starts_with(PREFIX));
        assert_eq!(decode_devices(&s), vec![d]);
    }

    #[test]
    fn round_trips_many_and_preserves_order() {
        let ds = vec![dev(1), dev(2), dev(3)];
        assert_eq!(decode_devices(&encode_devices(&ds)), ds);
    }

    #[test]
    fn every_byte_value_survives() {
        // Guards the hand-rolled base64url against sign/shift mistakes that only show on high bytes.
        let mut d = [0u8; 32];
        for (i, b) in d.iter_mut().enumerate() { *b = (i as u8).wrapping_mul(37).wrapping_add(200); }
        assert_eq!(decode_devices(&encode_devices(&[d])), vec![d]);
    }

    #[test]
    fn caps_at_max_devices_and_fits_the_pkarr_limit() {
        let ds: Vec<[u8; 32]> = (0..10).map(|i| dev(i as u8)).collect();
        let s = encode_devices(&ds);
        // iroh UserData::MAX_LENGTH is 245; blowing it makes publishing fail at runtime.
        assert!(s.len() <= 245, "payload {} bytes exceeds pkarr user-data limit", s.len());
        assert_eq!(decode_devices(&s).len(), MAX_DEVICES);
    }

    #[test]
    fn foreign_and_malformed_payloads_yield_nothing() {
        assert!(decode_devices("").is_empty());
        assert!(decode_devices("something-else").is_empty());
        assert!(decode_devices("hvd2:AAAA").is_empty());          // future version
        assert!(decode_devices(&format!("{PREFIX}short")).is_empty());
        assert!(decode_devices(&format!("{PREFIX}!!!")).is_empty());
    }

    #[test]
    fn hex_helpers_match_the_binary_form() {
        let d = dev(9);
        let s = encode_devices_hex(&[to_hex(&d)]).unwrap();
        assert_eq!(s, encode_devices(&[d]));
        assert_eq!(decode_devices_hex(&s), vec![to_hex(&d)]);
    }

    #[test]
    fn hex_encode_rejects_an_all_bad_list_but_tolerates_a_stray() {
        assert!(encode_devices_hex(&["nonsense".to_string()]).is_err());
        let good = to_hex(&dev(3));
        let s = encode_devices_hex(&[good.clone(), "short".to_string()]).unwrap();
        assert_eq!(decode_devices_hex(&s), vec![good]);
    }
}
