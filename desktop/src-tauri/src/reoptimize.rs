//! Re-optimize media I ALREADY shared — the desktop half.
//!
//! Read `apple/HavenApp/MediaReoptimize.swift` first; its header is the design spec and this file
//! deliberately does not restate it. The short version of what it establishes:
//!
//!   * A media ref IS the sha-256 of the blob's PLAINTEXT. That is load-bearing security (it stops a
//!     relay operator — always an ordinary circle member — from PUTting their own bytes at someone
//!     else's ref), so re-encoding is not an in-place operation: new bytes are a NEW ADDRESS.
//!   * Therefore the mechanism is an EDIT of the post carrying a full media array with the new ref,
//!     keeping the item's id, author, thread position and original timestamp. No alias table — that
//!     is exactly the indirection content addressing exists to forbid.
//!   * Only MY OWN posts and comments, because an Edit is signed by the author.
//!   * The OLD BLOB IS NOT DELETED here. A member who is offline right now still holds the PRE-edit
//!     post naming the old ref. Retirement happens through the ordinary weekly orphan sweep with its
//!     grace window.
//!
//!
//! WHAT DESKTOP COVERS, AND WHAT IT DOES NOT: **STILLS ONLY.**
//!
//! This is the honest scope, not an unfinished one, and the reasoning is worth keeping next to the
//! code so nobody "completes" it later without re-deriving it.
//!
//! `desktop/src-tauri` carries NO encoder — no ffmpeg, no codec crate — by deliberate design (see
//! the CODEC DIVERGENCE note over `MEDIA_TARGETS` in `desktop/ui/app.js`). All desktop media
//! processing happens in the WebView, and the only encoder a WebView exposes is `MediaRecorder`,
//! which emits **VP8/VP9 video and Opus audio in a WebM container**. Apple's target is H.264 in MP4
//! with AAC.
//!
//! For a NEW post that divergence is a pre-existing, documented trade-off. For re-optimize it would
//! be a REGRESSION, and that is the whole difference:
//!
//!   The eligible set is my own posts — and on this device that includes posts I authored on my
//!   PHONE, which arrived here through own-device sync. Those carry H.264/MP4 video that every
//!   member of the circle can play today. Re-encoding one here would replace working media with
//!   VP8/WebM bytes that Apple's AVPlayer cannot decode at all, and then EDIT the post so that the
//!   broken copy is the only one anybody fetches. `media_data_url` even labels every `v:` ref
//!   `video/mp4` regardless of its real contents, so the failure would be silent.
//!
//!   In other words: video re-optimize on desktop would spend CPU and every member's bandwidth to
//!   turn a playable clip into an unplayable one. A saving measured in megabytes is not worth
//!   breaking someone's post. Audio is refused for the same reason — MediaRecorder gives Opus/WebM
//!   where Apple expects AAC.
//!
//!   Stills have no such problem. The canvas re-encode produces baseline JPEG at exactly Apple's
//!   targets (1600px longest edge, quality 0.62), which every platform decodes. It is the same
//!   `imageToJpegBase64` the posting path has always used, so a re-optimized photo is byte-for-byte
//!   the kind of thing this client already ships.
//!
//! Videos and audio of mine that are above target are still COUNTED by the scan and reported to the
//! user as "can only be re-optimized from the phone app", because silently omitting them would make
//! a 1.2 GB library look like it had nothing to gain.
//!
//! Closing the gap means putting a real encoder in the Rust side and moving transcode out of the
//! WebView — a project, not a patch.
//!
//!
//! The probe below is a pure function over bytes with no engine dependency, for the same reason
//! `MediaOptimizationTarget` is dependency-free on Apple: it decides what gets rewritten, so it must
//! be testable in isolation. See the tests at the bottom.

/// Longest edge the optimized still path emits. Mirrors `MEDIA_TARGETS.STILL_LONG_EDGE` in app.js
/// and `MediaOptimizationTarget.imageMaxDimension` on Apple.
pub const STILL_LONG_EDGE: u32 = 1600;

/// JPEG q0.62 at 1600px measures well under 0.40 bytes per pixel. Above this a file is carrying more
/// data than our own encoder would have produced, whatever its dimensions say.
pub const IMAGE_BYTES_PER_PIXEL_CEILING: f64 = 0.40;

/// 2% slack purely for even-number rounding in the encoder — matches Apple's `dimensionSlack`.
pub const DIMENSION_SLACK: f64 = 1.02;

/// Below this there is nothing worth winning, and a re-share costs every member in the circle an
/// edit event plus a re-download. Apple parity.
pub const MINIMUM_INTERESTING_BYTES: u64 = 200_000;

/// A re-encode that doesn't clearly win is worse than no re-encode: the whole circle re-downloads for
/// nothing. New bytes must be at least this much smaller to be adopted. Apple parity.
pub const REQUIRED_SHRINK_FACTOR: f64 = 0.90;

/// One tap = at most this many items, then it stops and reports. Apple parity (`batchLimit`).
pub const BATCH_LIMIT: usize = 25;

/// Bound on the persisted don't-retry set, so it cannot itself become the leak. Apple parity.
pub const SKIP_SET_LIMIT: usize = 500;

/// Free bytes required over and above the source, before an encode is allowed to start. Apple
/// parity (`hasDiskHeadroom`). Filling the disk in a loop is the other way a job like this ruins
/// someone's day.
pub const DISK_HEADROOM_MARGIN: u64 = 512 * 1024 * 1024;

/// 2026-07-20 08:00 America/Los_Angeles — the moment the bitrate-controlled encoder landed in the
/// posting path. Anything shared before this instant CANNOT have come from it.
///
/// REPORTED, NOT ENFORCED, exactly as on Apple: shape (what the bytes actually are) is dispositive,
/// because age alone would exclude media shared AFTER the cutoff with optimization off — half the
/// population this button exists for. The cutoff survives because it explains a line to the user.
///
/// (This is the value Apple's `legacyCutoff` COMPUTES. Its hard-coded `Date(timeIntervalSince1970:)`
/// fallback literal is two days later, but that branch is unreachable — the DateComponents always
/// resolve — so the two platforms agree in practice.)
pub const LEGACY_CUTOFF_MS: u64 = 1_784_559_600_000;

pub fn is_legacy_by_age(created_at_ms: u64) -> bool {
    created_at_ms < LEGACY_CUTOFF_MS
}

/// What a stored still turned out to be.
#[derive(Debug, Clone, PartialEq)]
pub struct ImageShape {
    pub bytes: u64,
    pub width: u32,
    pub height: u32,
    /// Short format name for the reason strings ("jpeg", "png", "webp"…).
    pub format: &'static str,
    /// `None` when the file reads as already-at-target; otherwise WHY it is being rewritten.
    pub above_target_reason: Option<String>,
}

impl ImageShape {
    pub fn above_target(&self) -> bool {
        self.above_target_reason.is_some()
    }
    pub fn max_dimension(&self) -> u32 {
        self.width.max(self.height)
    }
}

/// Inspect a still's PLAINTEXT bytes and decide whether our encoder would do better.
///
/// Returns `None` when the bytes cannot be judged at all (unknown container, truncated header,
/// zero dimensions). The caller then LEAVES THAT BLOB ALONE — fail closed. An unreadable file is not
/// a re-encode candidate, and guessing at one risks replacing something valid with something worse.
///
/// The three tells, in Apple's order:
///   1. NOT A JPEG. The optimized path always writes JPEG, so a PNG/HEIC/WebP arrived verbatim.
///   2. TOO BIG. A camera original that never went through the downscale.
///   3. TOO DENSE. A file that IS 1600px but was written at q0.95, where only bytes-per-pixel tells.
///
/// Idempotence is the safety property that makes a shape-only gate sound: our own output must
/// re-probe as AT target or the button would offer the same photo forever. JPEG at 1600px/q0.62
/// lands far under the 0.40 bytes-per-pixel ceiling — verified in `reencoded_output_is_at_target`.
pub fn probe_image(bytes: &[u8]) -> Option<ImageShape> {
    let len = bytes.len() as u64;
    if len == 0 {
        return None;
    }
    let (format, width, height) = image_header(bytes)?;
    if width == 0 || height == 0 {
        return None;
    }
    let mut shape = ImageShape { bytes: len, width, height, format, above_target_reason: None };

    // Small files are left exactly as they are: the win doesn't pay for the circle-wide re-download.
    if len < MINIMUM_INTERESTING_BYTES {
        return Some(shape);
    }

    let max_dim = width.max(height);
    let bpp = len as f64 / (width as f64 * height as f64);
    if format != "jpeg" {
        shape.above_target_reason = Some(format!("not a JPEG ({format})"));
    } else if max_dim as f64 > STILL_LONG_EDGE as f64 * DIMENSION_SLACK {
        shape.above_target_reason = Some(format!("{max_dim}px, target {STILL_LONG_EDGE}px"));
    } else if bpp > IMAGE_BYTES_PER_PIXEL_CEILING {
        shape.above_target_reason =
            Some(format!("{bpp:.2} bytes/pixel, target <= {IMAGE_BYTES_PER_PIXEL_CEILING:.2}"));
    }
    Some(shape)
}

/// Is `new_len` a clear enough win over `old_len` to be worth every member re-downloading?
pub fn is_worth_adopting(old_len: u64, new_len: u64) -> bool {
    new_len > 0 && (new_len as f64) < old_len as f64 * REQUIRED_SHRINK_FACTOR
}

/// Add `reference` to the persisted don't-retry list, keeping it bounded. Returns whether the list
/// changed (i.e. whether prefs need saving).
///
/// Oldest entries are dropped first: a ref decided about long ago is the one most likely to be worth
/// re-testing under a newer encoder, and the newest decisions are the ones a repeat tap hits.
pub fn push_skip(list: &mut Vec<String>, reference: String) -> bool {
    if list.iter().any(|r| *r == reference) {
        return false;
    }
    list.push(reference);
    if list.len() > SKIP_SET_LIMIT {
        let excess = list.len() - SKIP_SET_LIMIT;
        list.drain(..excess);
    }
    true
}

// ---- header parsing --------------------------------------------------------------------------
//
// Dimensions only, from the container header — never a decode. `desktop/src-tauri` has no image
// crate and gains none here: a few hundred bytes of well-understood parsing is a smaller and more
// auditable dependency than a decoder, and it cannot be made to allocate on hostile input.
//
// Every read below is bounds-checked through slice `get`, so a truncated or malicious blob yields
// `None` (leave it alone) rather than a panic in a settings screen.

fn image_header(b: &[u8]) -> Option<(&'static str, u32, u32)> {
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return jpeg_size(b).map(|(w, h)| ("jpeg", w, h));
    }
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        // IHDR is always the first chunk: length+type occupy 8..16, then width, height.
        let w = be_u32(b, 16)?;
        let h = be_u32(b, 20)?;
        return Some(("png", w, h));
    }
    if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        return Some(("gif", le_u16(b, 6)? as u32, le_u16(b, 8)? as u32));
    }
    if b.starts_with(b"RIFF") && b.get(8..12) == Some(b"WEBP") {
        return webp_size(b).map(|(w, h)| ("webp", w, h));
    }
    if b.starts_with(b"BM") {
        // BITMAPINFOHEADER: signed 32-bit LE; a negative height means top-down rows.
        let w = le_u32(b, 18)? as i32;
        let h = le_u32(b, 22)? as i32;
        return Some(("bmp", w.unsigned_abs(), h.unsigned_abs()));
    }
    if b.get(4..8) == Some(b"ftyp") {
        // HEIF family (HEIC/AVIF). The pixel dimensions live in an `ispe` box; locating it properly
        // means walking the meta/iprp/ipco box tree, which is a lot of parser for a format we only
        // ever want to say "not a JPEG" about. Scanning for the box header is enough to get the
        // dimensions for the size line, and yields None (leave alone) when it isn't found.
        return heif_ispe(b).map(|(w, h)| ("heif", w, h));
    }
    None
}

/// Walk JPEG marker segments to the first Start-Of-Frame and read its dimensions.
fn jpeg_size(b: &[u8]) -> Option<(u32, u32)> {
    let mut i = 2usize;
    loop {
        // Markers may be preceded by any number of 0xFF fill bytes.
        while b.get(i) == Some(&0xFF) {
            i += 1;
        }
        let marker = *b.get(i)?;
        i += 1;
        match marker {
            // Standalone markers: no length field, no payload.
            0x01 | 0xD0..=0xD7 => continue,
            // SOF0..SOF15, excluding DHT (0xC4), JPG (0xC8) and DAC (0xCC), which are not frames.
            0xC0..=0xCF if marker != 0xC4 && marker != 0xC8 && marker != 0xCC => {
                // segment: length(2) precision(1) height(2) width(2)
                let h = be_u16(b, i + 3)?;
                let w = be_u16(b, i + 5)?;
                return Some((w as u32, h as u32));
            }
            // Start of scan — compressed data follows, so there is no frame header left to find.
            0xDA | 0xD9 => return None,
            _ => {
                let seg = be_u16(b, i)? as usize;
                if seg < 2 {
                    return None;
                }
                i = i.checked_add(seg)?;
            }
        }
        if i >= b.len() {
            return None;
        }
    }
}

fn webp_size(b: &[u8]) -> Option<(u32, u32)> {
    match b.get(12..16)? {
        // Lossy: 3-byte start code, then 14-bit width/height (top 2 bits are scaling hints).
        b"VP8 " => {
            let w = le_u16(b, 26)? & 0x3FFF;
            let h = le_u16(b, 28)? & 0x3FFF;
            Some((w as u32, h as u32))
        }
        // Lossless: 14-bit width-1 and height-1, packed across 4 bytes after the signature byte.
        b"VP8L" => {
            let bits = le_u32(b, 21)?;
            Some(((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1))
        }
        // Extended: 24-bit canvas width-1 / height-1.
        b"VP8X" => {
            let w = le_u24(b, 24)? + 1;
            let h = le_u24(b, 27)? + 1;
            Some((w, h))
        }
        _ => None,
    }
}

/// Find the first `ispe` box and read the image's pixel dimensions from it.
fn heif_ispe(b: &[u8]) -> Option<(u32, u32)> {
    // Bounded scan: HEIF metadata sits at the front of the file, and reading megabytes of pixel data
    // looking for a four-byte tag would be both pointless and a DoS shape.
    let limit = b.len().min(64 * 1024);
    let hay = b.get(..limit)?;
    let pos = hay.windows(4).position(|w| w == b"ispe")?;
    // ispe payload: version+flags(4), width(4), height(4).
    Some((be_u32(b, pos + 8)?, be_u32(b, pos + 12)?))
}

fn be_u16(b: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_be_bytes(b.get(i..i + 2)?.try_into().ok()?))
}
fn be_u32(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(i..i + 4)?.try_into().ok()?))
}
fn le_u16(b: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?))
}
fn le_u32(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?))
}
fn le_u24(b: &[u8], i: usize) -> Option<u32> {
    let s = b.get(i..i + 3)?;
    Some(u32::from(s[0]) | u32::from(s[1]) << 8 | u32::from(s[2]) << 16)
}

// ---- disk headroom ---------------------------------------------------------------------------

/// Free bytes on the volume holding `path`, or `None` when the platform can't say.
///
/// `None` means DON'T BLOCK, matching Apple's `hasDiskHeadroom` ("unknown -> don't block"): a
/// storage-space query that fails must not become a feature that can never be run.
pub fn free_space_bytes(path: &std::path::Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
        // SAFETY: `c` is a valid NUL-terminated path and `st` is fully written by a successful
        // statvfs; we read it only on a 0 return.
        unsafe {
            let mut st: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c.as_ptr(), &mut st) != 0 {
                return None;
            }
            // f_frsize is the fragment size the block counts are expressed in; f_bavail is what is
            // available to an UNPRIVILEGED process, which is what we actually get to use.
            Some((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
        let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
        wide.push(0);
        let mut free_to_caller: u64 = 0;
        // SAFETY: `wide` is NUL-terminated for the lifetime of the call; the two null out-params are
        // documented as optional, and `free_to_caller` is only read on a non-zero (success) return.
        let ok = unsafe {
            GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut free_to_caller,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return None;
        }
        Some(free_to_caller)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        None
    }
}

/// Refuse to start an encode without room for the source AND its output plus a margin.
pub fn has_disk_headroom(dir: &std::path::Path, source_bytes: u64) -> bool {
    match free_space_bytes(dir) {
        None => true, // unknown -> don't block (Apple parity)
        Some(free) => free > source_bytes.saturating_add(DISK_HEADROOM_MARGIN),
    }
}

// ---- tests -----------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal but REAL JPEG header: SOI, an APP0 segment to prove segment-skipping works, then a
    /// baseline SOF0 carrying the dimensions. `pad` inflates the file to a chosen byte length so the
    /// bytes-per-pixel arithmetic can be exercised without shipping fixture images.
    fn jpeg(w: u16, h: u16, total: usize) -> Vec<u8> {
        let mut v = vec![0xFF, 0xD8]; // SOI
        // APP0. The declared length COUNTS ITS OWN two bytes, so 2 + 12 payload = 14 (0x000E).
        v.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x0E]);
        v.extend_from_slice(b"JFIF\0\x01\x01\0\0\x01\0\x01"); // exactly 12 bytes
        v.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]); // SOF0, length 17, precision 8
        v.extend_from_slice(&h.to_be_bytes());
        v.extend_from_slice(&w.to_be_bytes());
        v.extend_from_slice(&[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
        v.resize(total.max(v.len()), 0x5A);
        v
    }

    fn png(w: u32, h: u32, total: usize) -> Vec<u8> {
        let mut v = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        v.extend_from_slice(&13u32.to_be_bytes());
        v.extend_from_slice(b"IHDR");
        v.extend_from_slice(&w.to_be_bytes());
        v.extend_from_slice(&h.to_be_bytes());
        v.resize(total.max(v.len()), 0x5A);
        v
    }

    #[test]
    fn parses_jpeg_dimensions_past_a_leading_segment() {
        let s = probe_image(&jpeg(4032, 3024, 3_000_000)).expect("jpeg parses");
        assert_eq!(s.format, "jpeg");
        assert_eq!((s.width, s.height), (4032, 3024));
    }

    #[test]
    fn parses_png_gif_bmp_and_webp() {
        let p = probe_image(&png(2000, 1000, 900_000)).unwrap();
        assert_eq!((p.format, p.width, p.height), ("png", 2000, 1000));

        let mut g = b"GIF89a".to_vec();
        g.extend_from_slice(&640u16.to_le_bytes());
        g.extend_from_slice(&480u16.to_le_bytes());
        g.resize(300_000, 0);
        let g = probe_image(&g).unwrap();
        assert_eq!((g.format, g.width, g.height), ("gif", 640, 480));

        let mut bmp = b"BM".to_vec();
        bmp.resize(18, 0);
        bmp.extend_from_slice(&800i32.to_le_bytes());
        bmp.extend_from_slice(&(-600i32).to_le_bytes()); // top-down: negative height
        bmp.resize(400_000, 0);
        let bmp = probe_image(&bmp).unwrap();
        assert_eq!((bmp.format, bmp.width, bmp.height), ("bmp", 800, 600));

        let mut wp = b"RIFF\0\0\0\0WEBPVP8 ".to_vec();
        wp.resize(26, 0);
        wp.extend_from_slice(&1234u16.to_le_bytes());
        wp.extend_from_slice(&567u16.to_le_bytes());
        wp.resize(500_000, 0);
        let wp = probe_image(&wp).unwrap();
        assert_eq!((wp.format, wp.width, wp.height), ("webp", 1234, 567));
    }

    /// Fail closed. Anything we cannot positively identify and measure must be LEFT ALONE, because
    /// the alternative is replacing a file we did not understand.
    #[test]
    fn unjudgeable_bytes_are_left_alone() {
        assert!(probe_image(&[]).is_none());
        assert!(probe_image(b"not an image at all, just prose").is_none());
        // Truncated JPEG: SOI and a marker, but the SOF never arrives.
        assert!(probe_image(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).is_none());
        // A JPEG whose frame reports zero height is not a thing we can reason about.
        assert!(probe_image(&jpeg(0, 0, 3_000_000)).is_none());
        // Header claims PNG, then stops before IHDR's dimensions.
        assert!(probe_image(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]).is_none());
    }

    /// A hostile blob must not panic a settings screen. Every truncation of a valid header, and a
    /// pile of junk, must come back as Some/None without unwinding.
    #[test]
    fn malformed_input_never_panics() {
        let full = jpeg(1600, 1200, 900_000);
        for n in 0..full.len().min(600) {
            let _ = probe_image(&full[..n]);
        }
        for seed in 0u8..=255 {
            let junk: Vec<u8> = (0..512u16).map(|i| (i as u8) ^ seed).collect();
            let _ = probe_image(&junk);
        }
        // A JPEG segment claiming a zero length would loop forever if the guard were missing.
        let mut looping = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00];
        looping.resize(300_000, 0);
        let _ = probe_image(&looping);
    }

    // ---- the gate itself -------------------------------------------------------------------

    #[test]
    fn oversized_camera_original_is_a_candidate() {
        let s = probe_image(&jpeg(4032, 3024, 3_000_000)).unwrap();
        assert!(s.above_target(), "a 4032px 3 MB JPEG must be offered");
        assert!(s.above_target_reason.unwrap().contains("4032px"));
    }

    #[test]
    fn at_size_but_too_dense_is_a_candidate() {
        // 1600x1200 = 1.92 Mpx. 1.5 MB is ~0.78 bytes/pixel — a q0.95 write, well over the ceiling.
        let s = probe_image(&jpeg(1600, 1200, 1_500_000)).unwrap();
        assert!(s.above_target(), "density alone must be enough");
        assert!(s.above_target_reason.unwrap().contains("bytes/pixel"));
    }

    #[test]
    fn a_non_jpeg_is_a_candidate_whatever_its_size() {
        // 1200x900 PNG: inside the dimension target, so ONLY the format tell can catch it.
        let s = probe_image(&png(1200, 900, 900_000)).unwrap();
        assert!(s.above_target());
        assert!(s.above_target_reason.unwrap().contains("not a JPEG"));
    }

    /// THE IDEMPOTENCE PROPERTY. Our own output must re-probe as AT target, or a scan would offer
    /// the same photo on every run forever and each tap would re-encode work already done.
    #[test]
    fn reencoded_output_is_at_target() {
        // What the canvas emits: JPEG, longest edge 1600, q0.62. A 1600x1200 q0.62 photo measures
        // around 0.15-0.25 bytes/pixel; 500 KB (0.26 bpp) is a generous stand-in for a busy one.
        let s = probe_image(&jpeg(1600, 1200, 500_000)).unwrap();
        assert!(!s.above_target(), "second pass must be a no-op, got {:?}", s.above_target_reason);
        // And at exactly the slack boundary (1600 * 1.02 = 1632) we still do not re-offer.
        let s = probe_image(&jpeg(1632, 1000, 400_000)).unwrap();
        assert!(!s.above_target(), "the 2% rounding slack must not trigger a rewrite");
    }

    #[test]
    fn small_files_are_never_offered() {
        // A tiny PNG is "not a JPEG" and 3000px, and STILL must not be offered: under the minimum,
        // the circle-wide re-download costs more than the bytes saved.
        let s = probe_image(&png(3000, 3000, 199_999)).unwrap();
        assert!(!s.above_target());
        // One byte over, and the same file IS offered — proving the boundary is where it claims.
        let s = probe_image(&png(3000, 3000, MINIMUM_INTERESTING_BYTES as usize)).unwrap();
        assert!(s.above_target());
    }

    #[test]
    fn only_a_clear_win_is_adopted() {
        assert!(is_worth_adopting(1_000_000, 500_000));
        assert!(!is_worth_adopting(1_000_000, 900_000), "exactly 10% smaller is not clear enough");
        assert!(!is_worth_adopting(1_000_000, 899_999 + 1));
        assert!(is_worth_adopting(1_000_000, 899_999));
        assert!(!is_worth_adopting(1_000_000, 1_200_000), "bigger must never be kept");
        assert!(!is_worth_adopting(1_000_000, 0), "an empty encode is a failure, not a win");
    }

    #[test]
    fn legacy_cutoff_is_the_encoder_landing() {
        assert!(is_legacy_by_age(LEGACY_CUTOFF_MS - 1));
        assert!(!is_legacy_by_age(LEGACY_CUTOFF_MS));
        // Sanity: mid-2026, not some epoch-arithmetic slip.
        assert!(LEGACY_CUTOFF_MS > 1_767_225_600_000 && LEGACY_CUTOFF_MS < 1_798_761_600_000);
    }

    #[test]
    fn skip_set_dedupes_and_stays_bounded() {
        let mut list = Vec::new();
        assert!(push_skip(&mut list, "img_a".into()));
        assert!(!push_skip(&mut list, "img_a".into()), "a repeat must not grow the list");
        assert_eq!(list.len(), 1);

        // Overfill it, then check it is capped and that it kept the NEWEST decisions.
        for i in 0..SKIP_SET_LIMIT + 50 {
            push_skip(&mut list, format!("img_{i}"));
        }
        assert_eq!(list.len(), SKIP_SET_LIMIT, "an unbounded don't-retry set is just a slower leak");
        let last = format!("img_{}", SKIP_SET_LIMIT + 49);
        assert!(list.contains(&last), "the most recent decision must survive");
        assert!(!list.contains(&"img_a".to_string()), "the oldest must be the one dropped");
    }

    #[test]
    fn headroom_refuses_a_full_disk_and_allows_an_unknown_one() {
        // The real volume under the test runner has room for a small file.
        let tmp = std::env::temp_dir();
        assert!(has_disk_headroom(&tmp, 1024));
        // Nothing has room for this, so the guard must bite.
        assert!(!has_disk_headroom(&tmp, u64::MAX / 2));
        // A path that cannot be queried must not become a permanently unusable feature.
        let nope = std::path::Path::new("/definitely/not/a/real/volume/haven-test");
        assert!(free_space_bytes(nope).is_none());
        assert!(has_disk_headroom(nope, 10_000_000));
    }
}
