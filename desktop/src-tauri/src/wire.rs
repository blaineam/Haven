//! The Haven wire protocol — a byte-exact Rust port of the framing used by the iOS
//! `FeedStore` and Android `Wire.kt`. This MUST stay identical across all three clients
//! or Windows ↔ iPhone ↔ Android interop breaks.
//!
//!   Frame         = [type:u8][payload]
//!   Hello payload = [LP circleId][LP circleName][LP bundle][signed profile]
//!   Event payload = [LP circleId][sealed envelope]
//!   LP field      = [u16 LE len][bytes]
//!
//! Frame types (parity with iOS `handleInbound` / Android `Wire`):
//!   0 Hello · 1 Event · 3 MediaReq · 5 MediaChunk · 9 Relay · 10-13 audio call ·
//!   14 BucketConfig · 15 video · 16 SDP offer · 17 SDP answer · 18 ICE · 19 relay node · 20 presign

pub const HELLO: u8 = 0;
pub const EVENT: u8 = 1;
pub const MEDIA_REQ: u8 = 3;
pub const MEDIA_CHUNK: u8 = 5;
pub const RELAY: u8 = 9;
pub const CALL_INVITE: u8 = 10;
pub const CALL_ACCEPT: u8 = 11;
pub const CALL_HANGUP: u8 = 12;
pub const CALL_AUDIO: u8 = 13;
pub const CALL_VIDEO: u8 = 15;
pub const SDP_OFFER: u8 = 16;
pub const SDP_ANSWER: u8 = 17;
pub const ICE: u8 = 18;
pub const RELAY_NODE: u8 = 19;
pub const PRESIGN: u8 = 20;
pub const GROUP_INVITE: u8 = 21;
pub const DEVICE_ENROLL: u8 = 24; // a device asks its primary to authorize it (multi-device, iOS-compat)
pub const DEVICE_GRANT: u8 = 25; // the primary returns a signed credential to the requesting device
pub const DEVICE_ROSTER: u8 = 27; // a contact's signed device roster announce (iOS/Android-compat)

/// Prepend the one-byte frame type.
pub fn frame(t: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + payload.len());
    out.push(t);
    out.extend_from_slice(payload);
    out
}

/// Append a length-prefixed field `[u16 LE len][bytes]`.
pub fn lp_append(out: &mut Vec<u8>, field: &[u8]) {
    let n = field.len();
    debug_assert!(n <= 0xFFFF, "LP field too large: {n}");
    out.push((n & 0xFF) as u8);
    out.push(((n >> 8) & 0xFF) as u8);
    out.extend_from_slice(field);
}

/// A cursor for reading LP fields out of a payload.
pub struct Reader<'a> {
    data: &'a [u8],
    pub off: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, off: 0 }
    }
    /// Read one LP field, or `None` if the buffer is short (matches iOS `lpRead`).
    pub fn lp(&mut self) -> Option<Vec<u8>> {
        if self.data.len() < self.off + 2 {
            return None;
        }
        let n = (self.data[self.off] as usize) | ((self.data[self.off + 1] as usize) << 8);
        self.off += 2;
        if self.data.len() < self.off + n {
            return None;
        }
        let field = self.data[self.off..self.off + n].to_vec();
        self.off += n;
        Some(field)
    }
    /// The remaining bytes after the cursor (sealed envelope / signed profile).
    pub fn rest(&self) -> Vec<u8> {
        self.data[self.off..].to_vec()
    }
}

/// Hello payload = `[LP circleId][LP circleName][LP bundle][signed profile]`.
pub fn hello_payload(circle_id: &str, circle_name: &str, bundle: &[u8], signed_profile: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    lp_append(&mut out, circle_id.as_bytes());
    lp_append(&mut out, circle_name.as_bytes());
    lp_append(&mut out, bundle);
    out.extend_from_slice(signed_profile);
    out
}

pub struct Hello {
    pub circle_id: String,
    pub circle_name: String,
    pub bundle: Vec<u8>,
    pub signed_profile: Vec<u8>,
}

/// Parse a Hello payload; `None` if malformed (matches the iOS/Android guards).
pub fn parse_hello(payload: &[u8]) -> Option<Hello> {
    let mut r = Reader::new(payload);
    let cid = r.lp()?;
    let cname = r.lp()?;
    let bundle = r.lp()?;
    if bundle.len() < 32 {
        return None;
    }
    Some(Hello {
        circle_id: String::from_utf8_lossy(&cid).into_owned(),
        circle_name: String::from_utf8_lossy(&cname).into_owned(),
        bundle,
        signed_profile: r.rest(),
    })
}

/// Event payload = `[LP circleId][sealed envelope]`.
pub fn event_payload(circle_id: &str, envelope: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    lp_append(&mut out, circle_id.as_bytes());
    out.extend_from_slice(envelope);
    out
}

pub struct EventFrame {
    pub circle_id: String,
    pub envelope: Vec<u8>,
}

pub fn parse_event(payload: &[u8]) -> Option<EventFrame> {
    let mut r = Reader::new(payload);
    let cid = r.lp()?;
    Some(EventFrame {
        circle_id: String::from_utf8_lossy(&cid).into_owned(),
        envelope: r.rest(),
    })
}

/// node-id hex = first 32 bytes of the bundle, lowercase hex (matches iOS/Android `nodeHex`).
pub fn node_hex(bundle: &[u8]) -> String {
    bundle.iter().take(32).map(|b| format!("{b:02x}")).collect()
}

/// `[u16 LE refLen][ref][u32 LE index][u32 LE total][sealed]` — the media-chunk frame body.
pub fn chunk_frame(ref_bytes: &[u8], index: u32, total: u32, sealed: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + ref_bytes.len() + 8 + sealed.len());
    out.push((ref_bytes.len() & 0xFF) as u8);
    out.push(((ref_bytes.len() >> 8) & 0xFF) as u8);
    out.extend_from_slice(ref_bytes);
    out.extend_from_slice(&index.to_le_bytes());
    out.extend_from_slice(&total.to_le_bytes());
    out.extend_from_slice(sealed);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_roundtrip() {
        let bundle = vec![7u8; 64];
        let p = hello_payload("default", "My Circle", &bundle, b"sig");
        let h = parse_hello(&p).unwrap();
        assert_eq!(h.circle_id, "default");
        assert_eq!(h.circle_name, "My Circle");
        assert_eq!(h.bundle, bundle);
        assert_eq!(h.signed_profile, b"sig");
    }

    #[test]
    fn event_roundtrip() {
        let env = vec![1u8, 2, 3, 4];
        let p = event_payload("fam", &env);
        let e = parse_event(&p).unwrap();
        assert_eq!(e.circle_id, "fam");
        assert_eq!(e.envelope, env);
    }
}
