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
/// A peer's camera turned on/off mid-call. Without it a peer who stops their video leaves everyone
/// staring at a frozen last frame instead of their avatar. iOS/Android both send and handle it.
pub const CALL_CAMERA: u8 = 22;
pub const DEVICE_ENROLL: u8 = 24; // a device asks its primary to authorize it (multi-device, iOS-compat)
pub const DEVICE_GRANT: u8 = 25; // the primary returns a signed credential to the requesting device
pub const DEVICE_ROSTER: u8 = 27; // a contact's signed device roster announce (iOS/Android-compat)
pub const SEEDLESS_ENROLL_REQ: u8 = 28; // a SEEDLESS new device proves ticket possession (seed-drop S4)
pub const SEEDLESS_ENROLL_GRANT: u8 = 29; // the primary grants credential + roster + self-sync key back
/// "I answered/declined this ringing call on another of MY devices — stand down." Sent only to one's
/// OWN devices, and it only ever silences a device still RINGING (see `handle_call`). Rides the
/// sealed+signed call path: it can silence a ringing machine, so it must be no more forgeable than an
/// invite. iOS/Android-compat.
pub const CALL_HANDLED: u8 = 30;

/// "Put this media back" — a reader asks a post's AUTHOR to re-upload a blob a relay has swept.
/// `[hex64 sender][LP ref][LP circleId][LP postId]`. iOS/Android-compat.
///
/// Rides the sealed+signed call path rather than the plain one: it asks someone to spend their
/// upload bandwidth, so it must be no more forgeable than an invite.
pub const MEDIA_WANTED: u8 = 31;

/// "It's back" — the author's reply once the re-upload has landed on a relay. Same body shape as
/// [`MEDIA_WANTED`]. Also sealed+signed: it raises a notification and triggers a fetch.
pub const MEDIA_AVAILABLE: u8 = 32;

/// Build a media frame's body: `[hex64 sender][LP ref][LP circleId][LP postId]`. Shared by 31 and 32
/// — the reply names the same blob the request did.
pub fn media_frame(my_hex: &str, reference: &str, circle_id: &str, post_id: &str) -> Vec<u8> {
    let mut out = my_hex.as_bytes().to_vec();
    lp_append(&mut out, reference.as_bytes());
    lp_append(&mut out, circle_id.as_bytes());
    lp_append(&mut out, post_id.as_bytes());
    out
}

/// Parse a media frame body into `(ref, circleId, postId)`; `None` if malformed. The 64-char sender
/// head is SKIPPED rather than returned — the caller already holds the cryptographically VERIFIED
/// sender, and the self-declared head must never be what anything keys on.
pub fn parse_media_frame(body: &[u8]) -> Option<(String, String, String)> {
    if body.len() <= 64 {
        return None;
    }
    let mut r = Reader::new(body);
    r.off = 64;
    let reference = String::from_utf8(r.lp()?).ok()?;
    let circle_id = String::from_utf8(r.lp()?).ok()?;
    let post_id = String::from_utf8(r.lp()?).ok()?;
    if reference.is_empty() || circle_id.is_empty() {
        return None;
    }
    Some((reference, circle_id, post_id))
}

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
    fn media_frame_roundtrip() {
        let me = "a".repeat(64);
        let p = media_frame(&me, "img_abc123", "default", "post-7");
        let (r, c, post) = parse_media_frame(&p).unwrap();
        assert_eq!(r, "img_abc123");
        assert_eq!(c, "default");
        assert_eq!(post, "post-7");
    }

    #[test]
    fn media_frame_accepts_an_empty_post_id() {
        // A ref can be asked about without naming a post (nothing to deep-link to); only the ref and
        // the circle are load-bearing, since the circle is what membership is checked against.
        let p = media_frame(&"b".repeat(64), "v:deadbeef", "dm:x-y", "");
        let (r, c, post) = parse_media_frame(&p).unwrap();
        assert_eq!((r.as_str(), c.as_str(), post.as_str()), ("v:deadbeef", "dm:x-y", ""));
    }

    #[test]
    fn media_frame_rejects_malformed_and_unnamed_circles() {
        assert!(parse_media_frame(&[0u8; 64]).is_none()); // head only, no fields
        assert!(parse_media_frame(b"short").is_none());
        // A frame naming no circle can't be membership-checked, so it must not parse into one that
        // looks servable — the member check is the whole guard on the author side.
        assert!(parse_media_frame(&media_frame(&"c".repeat(64), "img_x", "", "p1")).is_none());
        assert!(parse_media_frame(&media_frame(&"c".repeat(64), "", "default", "p1")).is_none());
    }

    #[test]
    fn media_frame_tolerates_a_future_trailing_field() {
        // Every platform's parser must ignore fields it doesn't know, so a later version can append
        // one without breaking this one — the same rule the call invite's timestamp relies on.
        let mut p = media_frame(&"d".repeat(64), "img_x", "default", "p1");
        let extra = b"future-field";
        p.extend_from_slice(&(extra.len() as u16).to_le_bytes());
        p.extend_from_slice(extra);
        let (r, c, post) = parse_media_frame(&p).unwrap();
        assert_eq!((r.as_str(), c.as_str(), post.as_str()), ("img_x", "default", "p1"));
    }

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
