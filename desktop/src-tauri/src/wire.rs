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
//!   14 BucketConfig · 15 video · 16 SDP offer · 17 SDP answer · 18 ICE · 19 relay node · 20 presign ·
//!   31 MediaWanted · 32 MediaAvailable · 33 MediaResumeReq

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
/// My account ENDED this call session on another device: tear down even if already answered here.
/// CALL_HANDLED (30) deliberately only silences a device still RINGING, so an established call
/// ended elsewhere left this one in a dead call. Apple/Android frame 35 parity.
pub const CALL_ENDED_ELSEWHERE: u8 = 35;

/// "Put this media back" — a reader asks a post's AUTHOR to re-upload a blob a relay has swept.
/// `[hex64 sender][LP ref][LP circleId][LP postId]`. iOS/Android-compat.
///
/// Rides the sealed+signed call path rather than the plain one: it asks someone to spend their
/// upload bandwidth, so it must be no more forgeable than an invite.
pub const MEDIA_WANTED: u8 = 31;

/// "It's back" — the author's reply once the re-upload has landed on a relay. Same body shape as
/// [`MEDIA_WANTED`]. Also sealed+signed: it raises a notification and triggers a fetch.
pub const MEDIA_AVAILABLE: u8 = 32;

/// "Send me only what I'm missing" — the RE-request for a media transfer that was interrupted.
/// `[hex64 requester][LP ref][u32 LE total][bitmap]`, all little-endian. iOS/Android-compat.
///
/// [`MEDIA_REQ`] is deliberately untouched: its ref is the unlengthed REMAINDER of the body, so
/// there is nowhere to put a resume hint without breaking every parser in the field — and a FIRST
/// request has no bitmap to send anyway. So frame 3 keeps meaning "send everything" and 33 carries
/// the bitmap. An un-upgraded peer ignores 33 and says nothing, so the requester falls back to a
/// full frame 3 after ~8s and nothing regresses.
///
/// Rides the PLAINTEXT blocked-sender path with frame 3 rather than the sealed call-frame set: it
/// asks for a strict SUBSET of what frame 3 already asks for in the clear, so sealing it would buy
/// nothing while making it fail in exactly the places its own frame-3 fallback still works.
pub const MEDIA_RESUME_REQ: u8 = 33;

/// The largest chunk count a resume frame may declare — 4M × 32 KB ≈ 128 GB, far past any real
/// media. The bound is the whole point: `total` is peer-controlled and sizes a bitmap allocation, so
/// an unbounded one lets a single 70-byte frame ask us for half a gigabyte of `Vec` (`u32::MAX / 8`).
/// 34 — "send me the page of your history before this timestamp".
/// `[hex64 requester][u64 LE before_ms][circle_id utf8]`, byte-identical to iOS/Android.
///
/// Adding someone used to hand them EVERY event the adder had authored to that circle, re-sealed one
/// by one, with the media backlog following behind. This asks for a page instead, and the reply is
/// ordinary EVENT frames — so only the ask is new and the receiving side is the path that already
/// ingests and deduplicates envelopes.
pub const HISTORY_REQ: u8 = 34;

/// Events a new member is given up front, and the size of each page fetched afterwards.
pub const HISTORY_PAGE: u32 = 60;

/// Build a HISTORY_REQ payload.
pub fn history_req_payload(requester_hex: &str, before_ms: u64, circle_id: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(64 + 8 + circle_id.len());
    out.extend_from_slice(requester_hex.as_bytes());
    out.extend_from_slice(&before_ms.to_le_bytes());
    out.extend_from_slice(circle_id.as_bytes());
    out
}

/// Parse a HISTORY_REQ payload; None if malformed (matches the iOS/Android guards).
pub fn parse_history_req(payload: &[u8]) -> Option<(String, u64, String)> {
    if payload.len() <= 72 {
        return None;
    }
    let requester = std::str::from_utf8(&payload[..64]).ok()?.to_string();
    if requester.len() != 64 {
        return None;
    }
    let before = u64::from_le_bytes(payload[64..72].try_into().ok()?);
    let cid = std::str::from_utf8(&payload[72..]).ok()?.to_string();
    if cid.is_empty() {
        return None;
    }
    Some((requester, before, cid))
}

pub const MAX_RESUME_CHUNKS: u32 = 4_000_000;

/// Pack held chunk indices into a bitmap: bit `i` of byte `i / 8` set means chunk `i` is on disk.
/// 1,600 chunks is 200 bytes — cheap to keep and cheap to send.
pub fn bitmap(got: &std::collections::HashSet<u32>, total: u32) -> Vec<u8> {
    let mut bits = vec![0u8; (total as usize + 7) / 8];
    for &i in got {
        if i < total {
            bits[(i / 8) as usize] |= 1 << (i % 8);
        }
    }
    bits
}

/// Unpack a bitmap into the indices it claims. Bits past `total` are ignored rather than trusted.
pub fn bitmap_indices(bits: &[u8], total: u32) -> std::collections::HashSet<u32> {
    let mut out = std::collections::HashSet::new();
    for i in 0..total {
        let byte = (i / 8) as usize;
        if byte < bits.len() && bits[byte] & (1 << (i % 8)) != 0 {
            out.insert(i);
        }
    }
    out
}

/// A parsed [`MEDIA_RESUME_REQ`] body.
pub struct ResumeReq {
    /// The requester's self-declared node hex — a DIAL TARGET only, never something to key trust on.
    pub requester_hex: String,
    pub reference: String,
    /// The chunk count the requester's partial was built against. If it disagrees with the total we
    /// compute from our own file, their bitmap indexes different bytes and must be ignored whole.
    pub total: u32,
    /// The requester's bitmap, RAW — deliberately not expanded into a set of chunk indices here.
    ///
    /// [`MAX_RESUME_CHUNKS`] is 4 million, so expanding at parse time would let a peer spend a ~500 KB
    /// frame to make us build a 4M-entry `HashSet<u32>` before anything had checked we even hold the
    /// ref. The caller expands only after the declared total matches the one IT computes from its own
    /// file, which bounds the work by a file we actually have rather than by a number the sender chose.
    pub bitmap: Vec<u8>,
}

/// Build a [`MEDIA_RESUME_REQ`] body.
pub fn resume_frame(my_hex: &str, reference: &str, total: u32, got: &std::collections::HashSet<u32>) -> Vec<u8> {
    let mut out = my_hex.as_bytes().to_vec();
    lp_append(&mut out, reference.as_bytes());
    out.extend_from_slice(&total.to_le_bytes());
    out.extend_from_slice(&bitmap(got, total));
    out
}

/// Parse a [`MEDIA_RESUME_REQ`] body; `None` for anything malformed.
///
/// Every bound here is a bound on what a PEER can make us do: the declared total must be plausible
/// ([`MAX_RESUME_CHUNKS`]) and the bitmap must be EXACTLY the size that total implies, so a frame
/// claiming 4.2 billion chunks is refused rather than allocated for. The exact-length check (rather
/// than the "ignore trailing fields" tolerance the other media frames grant) is deliberate: the
/// bitmap is the frame's last field, so a trailing extension is indistinguishable from a bitmap that
/// disagrees with its own total, and the wrong guess silently corrupts which chunks get served.
pub fn parse_resume_frame(body: &[u8]) -> Option<ResumeReq> {
    if body.len() < 64 + 2 {
        return None;
    }
    let requester_hex = std::str::from_utf8(&body[..64]).ok()?.to_string();
    if requester_hex.chars().count() != 64 {
        return None;
    }
    let mut r = Reader::new(body);
    r.off = 64;
    let reference = String::from_utf8(r.lp()?).ok()?;
    if body.len() < r.off + 4 {
        return None;
    }
    let total = u32::from_le_bytes([body[r.off], body[r.off + 1], body[r.off + 2], body[r.off + 3]]);
    r.off += 4;
    let bits = &body[r.off..];
    if reference.is_empty() || total == 0 || total > MAX_RESUME_CHUNKS {
        return None;
    }
    if bits.len() != (total as usize + 7) / 8 {
        return None;
    }
    Some(ResumeReq { requester_hex, reference, total, bitmap: bits.to_vec() })
}

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

    // ---- frame 33 (resume request) ---------------------------------------------------------

    use std::collections::HashSet;

    #[test]
    fn bitmap_roundtrips_at_every_byte_boundary() {
        // The off-by-one that would matter is at the byte edges, so walk them explicitly. 1,600 is a
        // 50 MB video at 32 KB a chunk — the transfer this whole feature exists for.
        for total in [1u32, 7, 8, 9, 63, 64, 65, 1600, 1601] {
            let got: HashSet<u32> = (0..total).filter(|i| i % 3 == 0).collect();
            let bits = bitmap(&got, total);
            assert_eq!(bits.len(), (total as usize + 7) / 8, "total={total}");
            assert_eq!(bitmap_indices(&bits, total), got, "total={total}");
        }
    }

    #[test]
    fn bitmap_ignores_indices_outside_the_total() {
        // Neither our own bookkeeping nor a peer's bitmap may set a bit that names a chunk which
        // does not exist — it would count toward completion and finish a transfer with a hole in it.
        let got: HashSet<u32> = [0, 5, 99].into_iter().collect();
        let bits = bitmap(&got, 8);
        assert_eq!(bits.len(), 1);
        assert_eq!(bitmap_indices(&bits, 8), [0u32, 5].into_iter().collect::<HashSet<u32>>());
        // A byte with high bits set, read back under a total that doesn't reach them.
        assert_eq!(bitmap_indices(&[0xFF], 3), [0u32, 1, 2].into_iter().collect::<HashSet<u32>>());
    }

    #[test]
    fn resume_frame_roundtrip() {
        let me = "a".repeat(64);
        let got: HashSet<u32> = (0..1599).collect(); // the 1,599-of-1,600 transfer
        let p = resume_frame(&me, "vid_abc123", 1600, &got);
        let r = parse_resume_frame(&p).unwrap();
        assert_eq!(r.requester_hex, me);
        assert_eq!(r.reference, "vid_abc123");
        assert_eq!(r.total, 1600);
        let theirs = bitmap_indices(&r.bitmap, r.total);
        let missing: Vec<u32> = (0..1600).filter(|i| !theirs.contains(i)).collect();
        assert_eq!(missing, vec![1599], "the server must serve exactly one chunk, not 50 MB");
        // 1,600 chunks of bitmap is 200 bytes on top of the head — the ask stays tiny.
        assert_eq!(p.len(), 64 + 2 + 10 + 4 + 200);
    }

    #[test]
    fn resume_frame_survives_a_ref_with_a_colon() {
        // The legacy desktop/iOS media schemes (`v:`/`a:`/`i:`) are still in real posts.
        let p = resume_frame(&"b".repeat(64), "v:deadbeef", 9, &[0u32, 8].into_iter().collect());
        let r = parse_resume_frame(&p).unwrap();
        assert_eq!(r.reference, "v:deadbeef");
        assert_eq!(bitmap_indices(&r.bitmap, r.total), [0u32, 8].into_iter().collect::<HashSet<u32>>());
        // The parser must hand back the RAW bitmap: expanding 4M indices before we have even checked
        // we hold the ref is a peer-priced allocation, which is the whole reason it is a Vec<u8>.
        assert_eq!(r.bitmap.len(), (r.total as usize + 7) / 8);
    }

    /// Every field in frame 33 is peer-controlled, and `total` sizes an allocation. These are the
    /// shapes a hostile peer sends; none of them may parse into something servable.
    #[test]
    fn resume_frame_refuses_every_hostile_shape() {
        let me = "c".repeat(64);
        let good = resume_frame(&me, "img_x", 16, &[0u32, 3].into_iter().collect());
        assert!(parse_resume_frame(&good).is_some()); // control

        assert!(parse_resume_frame(&[]).is_none());
        assert!(parse_resume_frame(b"short").is_none());
        assert!(parse_resume_frame(&[0u8; 64]).is_none()); // head only, no LP ref
        assert!(parse_resume_frame(&good[..good.len() - 1]).is_none()); // truncated bitmap

        // A bitmap LONGER than the total implies: either a lie or a different chunking. Either way
        // acting on it serves the wrong chunk indices.
        let mut long = good.clone();
        long.push(0);
        assert!(parse_resume_frame(&long).is_none());

        // total = 0: nothing to serve, and `(0 + 7) / 8 == 0` would make an empty bitmap "valid".
        assert!(parse_resume_frame(&resume_frame(&me, "img_x", 0, &HashSet::new())).is_none());

        // A ref length that overruns the buffer — the classic parser walk-off.
        let mut over = me.as_bytes().to_vec();
        over.extend_from_slice(&u16::MAX.to_le_bytes());
        over.extend_from_slice(b"img_x");
        assert!(parse_resume_frame(&over).is_none());

        // An empty ref names nothing servable.
        let mut empty_ref = me.as_bytes().to_vec();
        lp_append(&mut empty_ref, b"");
        empty_ref.extend_from_slice(&1u32.to_le_bytes());
        empty_ref.push(1);
        assert!(parse_resume_frame(&empty_ref).is_none());

        // THE ALLOCATION ATTACK: 4.2 billion chunks in a 71-byte frame. Believed, `(total + 7) / 8`
        // is a 536 MB bitmap — refused at the bound, never allocated for.
        let mut absurd = me.as_bytes().to_vec();
        lp_append(&mut absurd, b"img_x");
        absurd.extend_from_slice(&u32::MAX.to_le_bytes());
        assert!(parse_resume_frame(&absurd).is_none());
        // ...and one chunk past the bound, with a correctly-sized bitmap, is still refused.
        let mut just_over = me.as_bytes().to_vec();
        lp_append(&mut just_over, b"img_x");
        let t = MAX_RESUME_CHUNKS + 1;
        just_over.extend_from_slice(&t.to_le_bytes());
        just_over.extend_from_slice(&vec![0u8; (t as usize + 7) / 8]);
        assert!(parse_resume_frame(&just_over).is_none());
        // The bound itself parses — it is a limit, not an off-by-one.
        let mut at_bound = me.as_bytes().to_vec();
        lp_append(&mut at_bound, b"img_x");
        at_bound.extend_from_slice(&MAX_RESUME_CHUNKS.to_le_bytes());
        at_bound.extend_from_slice(&vec![0u8; (MAX_RESUME_CHUNKS as usize + 7) / 8]);
        assert!(parse_resume_frame(&at_bound).is_some());

        // A non-utf8 head can't be a node hex, so it can't be a dial target either.
        let mut bad_head = vec![0xFFu8; 64];
        lp_append(&mut bad_head, b"img_x");
        bad_head.extend_from_slice(&1u32.to_le_bytes());
        bad_head.push(1);
        assert!(parse_resume_frame(&bad_head).is_none());
    }

    #[test]
    fn resume_frame_head_must_be_a_full_64_char_hex() {
        // Multi-byte utf8 fills 64 BYTES with fewer than 64 chars — the length check is on chars, so
        // it matches the iOS parser byte-for-byte rather than accidentally admitting these.
        let mut short_head = "é".repeat(32).into_bytes(); // 64 bytes, 32 chars
        assert_eq!(short_head.len(), 64);
        lp_append(&mut short_head, b"img_x");
        short_head.extend_from_slice(&1u32.to_le_bytes());
        short_head.push(1);
        assert!(parse_resume_frame(&short_head).is_none());
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

// ---- Deep links -------------------------------------------------------------------------

/// Fragment-safe token charset: unreserved characters *minus* `.` and `/`, so those two stay
/// unambiguous as our delimiters no matter what an id carries. Must stay byte-identical to
/// `fragmentToken` in `apple/HavenApp/DeepLink.swift` and `encodeToken` in Android's `DeepLink.kt` —
/// a link one platform emits has to split the same way on the others.
const TOKEN_SAFE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~";

fn encode_token(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        if *b < 0x80 && TOKEN_SAFE.contains(b) {
            out.push(*b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

/// The link a post's share sheet hands out — web-routed so it crosses to iOS/Android and survives
/// being pasted anywhere.
///
/// ⚠️ THE PAYLOAD GOES AFTER THE `#` ON PURPOSE — DO NOT "TIDY" IT INTO A PATH. ⚠️
/// A browser never sends `#…` to the server, so wemiller.com's logs (and every CDN/proxy between)
/// see only `/apps/haven/open/` — never WHICH post. A path form would hand the host a readership
/// map: reader IP × circle × post. That map is exactly what Haven exists not to create. See
/// `docs/LINK-SYSTEM.md`.
///
/// The link is a POINTER, not a capability — it carries no key. Only a device already in the circle
/// can decrypt the post; everyone else gets "post not found".
/// Tap-target for a notification / activity row: DMs open the Messages thread, circle posts open
/// the post, a bare circle id opens the circle. Percent-encoded with the SAME token charset as the
/// web post link, so a `dm:hex-hex` circle id survives URL parsing. Mirrors Apple
/// `DeepLink.interactionLink` byte-for-byte.
pub fn interaction_link(circle_id: &str, post_id: Option<&str>) -> String {
    let cid = encode_token(circle_id);
    let pid = post_id.filter(|p| !p.is_empty()).map(encode_token);
    if circle_id.starts_with("dm:") {
        match pid {
            Some(p) => format!("haven://m/{cid}/{p}"),
            None => format!("haven://m/{cid}"),
        }
    } else {
        match pid {
            Some(p) => format!("haven://p/{cid}/{p}"),
            None => format!("haven://c/{cid}"),
        }
    }
}

pub fn post_url(circle_id: &str, post_id: &str) -> Option<String> {
    if circle_id.is_empty() || post_id.is_empty() {
        return None;
    }
    Some(format!(
        "https://wemiller.com/apps/haven/open/#p/{}.{}",
        encode_token(circle_id),
        encode_token(post_id)
    ))
}

#[cfg(test)]
mod deeplink_tests {
    use super::*;

    /// The token encoding is a CROSS-PLATFORM contract: a link emitted here must split the same way
    /// on iOS and Android, so `.` and `/` must be escaped even though they are URL-legal.
    #[test]
    fn delimiters_are_escaped_but_unreserved_survive() {
        assert_eq!(encode_token("abc-XYZ_0~9"), "abc-XYZ_0~9");
        assert_eq!(encode_token("a.b"), "a%2Eb");
        assert_eq!(encode_token("a/b"), "a%2Fb");
        // A dm: circle id is the case that forced this: ':' and '-' must not become delimiters.
        assert_eq!(encode_token("dm:aa-bb"), "dm%3Aaa-bb");
    }

    #[test]
    fn the_payload_stays_in_the_fragment() {
        let u = post_url("default", "p1").unwrap();
        assert!(u.starts_with("https://wemiller.com/apps/haven/open/#p/"), "{u}");
        // Nothing identifying may appear before the '#', or the host learns who read what.
        let (before, _) = u.split_once('#').unwrap();
        assert!(!before.contains("default") && !before.contains("p1"), "{u}");
    }

    #[test]
    fn empty_ids_have_no_link() {
        assert!(post_url("", "p1").is_none());
        assert!(post_url("c", "").is_none());
    }
}
