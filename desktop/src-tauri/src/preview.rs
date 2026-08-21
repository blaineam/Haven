//! The 512px AVIF preview tier (`docs/PREVIEW-TIER-DESIGN.md`). Mirrors iOS `PreviewCodec.swift`
//! and Android `PreviewCodec.kt`.
//!
//! This is the only media small enough to cross a satellite link: about 6 KB, under two Haven text
//! messages, where the existing `thumb:` companion is ≤32 KB and a full photo is megabytes.
//!
//! **Why this is in Rust and not the webview.** Desktop encodes images with
//! `canvas.toDataURL("image/jpeg")` today (`ui/app.js`), and Chromium's canvas cannot write AVIF —
//! only PNG, JPEG and WebP. So the preview encode moves here, which is a better home anyway: it
//! makes desktop behave like the mobile clients instead of depending on what a webview happens to
//! support, and it works identically on Windows, macOS and Linux.
//!
//! **Why the target is BYTES, not a quality number.** The three platforms' encoders take different
//! quality scales that do not line up — ImageIO 0–1, ravif 0–100, avif-coder 0–100 — and the same
//! nominal value produces materially different sizes. A shared quality constant would silently mean
//! three different things. Every platform is specified the same way instead: 512px longest edge,
//! under [`MAX_BYTES`], quality walked down until it fits.

use ravif::{Encoder, Img, RGB8};

/// Longest edge of a preview, in pixels.
pub const MAX_DIMENSION: u32 = 512;

/// Hard ceiling for a preview. ~2 Haven text messages.
pub const MAX_BYTES: usize = 8 * 1024;

/// Quality ladder, walked highest-first until the result fits [`MAX_BYTES`]. Starting high and
/// stepping down costs a few extra encodes on a complex image and yields the best-looking preview
/// that fits, rather than a uniformly poor one sized for the worst case.
const QUALITY_LADDER: [f32; 8] = [58.0, 50.0, 44.0, 38.0, 32.0, 26.0, 20.0, 12.0];

/// Encode a preview from already-decoded RGB8 pixels.
///
/// `None` means "no preview for this item" — a pathological image, or an encoder failure. A caller
/// must never read that as permission to send the full media over a constrained link.
pub fn encode_rgb8(pixels: &[RGB8], width: u32, height: u32) -> Option<Vec<u8>> {
    if width == 0 || height == 0 || pixels.len() < (width as usize * height as usize) {
        return None;
    }
    for quality in QUALITY_LADDER {
        // speed 8 keeps a 512px encode in the tens of milliseconds; the preview is small enough
        // that squeezing the last few percent is not worth seconds of CPU on a laptop.
        let encoded = Encoder::new()
            .with_quality(quality)
            .with_speed(8)
            .encode_rgb(Img::new(pixels, width as usize, height as usize));
        if let Ok(res) = encoded {
            if res.avif_file.len() <= MAX_BYTES {
                return Some(res.avif_file);
            }
        }
    }
    None
}

/// Fit `(w, h)` inside [`MAX_DIMENSION`] on the longest edge, preserving aspect. Never upscales — a
/// picture already smaller than the cap is already its own preview.
pub fn fit(w: u32, h: u32) -> (u32, u32) {
    let longest = w.max(h);
    if longest == 0 || longest <= MAX_DIMENSION {
        return (w, h);
    }
    let scale = MAX_DIMENSION as f64 / longest as f64;
    (
        ((w as f64 * scale) as u32).max(1),
        ((h as f64 * scale) as u32).max(1),
    )
}

/// Decode encoded image bytes (what the composer hands over — sanitized JPEG or PNG from the
/// webview), fit to [`MAX_DIMENSION`], and encode the preview.
///
/// `None` for anything we cannot decode, or that the encoder could not fit. Never a reason to send
/// the full media on a constrained link.
pub fn encode_image_bytes(bytes: &[u8]) -> Option<Vec<u8>> {
    let decoded = image::load_from_memory(bytes).ok()?.to_rgb8();
    let (w, h) = decoded.dimensions();
    let (fw, fh) = fit(w, h);
    let scaled = if (fw, fh) == (w, h) {
        decoded
    } else {
        image::imageops::resize(&decoded, fw, fh, image::imageops::FilterType::Lanczos3)
    };
    let pixels: Vec<RGB8> = scaled.pixels().map(|p| RGB8::new(p[0], p[1], p[2])).collect();
    encode_rgb8(&pixels, fw, fh)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn photo(w: u32, h: u32) -> Vec<RGB8> {
        // Gradient plus fine detail, so the encoder is not handed something trivially compressible
        // and the budget is tested honestly.
        (0..h)
            .flat_map(|y| {
                (0..w).map(move |x| {
                    let fx = x as f32 / w as f32;
                    let fy = y as f32 / h as f32;
                    let d = if (x / 3 + y / 3) % 2 == 0 { 30 } else { 0 };
                    RGB8::new(
                        ((0.5 + 0.5 * (fx * 9.0).sin()) * 200.0) as u8 + d,
                        ((0.4 + 0.4 * (fy * 7.0).cos()) * 200.0) as u8 + d,
                        ((0.6 + 0.3 * ((fx + fy) * 11.0).sin()) * 200.0) as u8,
                    )
                })
            })
            .collect()
    }

    /// The budget IS the feature: a preview that does not fit cannot cross a satellite link.
    #[test]
    fn a_preview_fits_the_budget() {
        let (w, h) = fit(1600, 1200);
        assert_eq!((w, h), (512, 384));
        let px = photo(w, h);
        let out = encode_rgb8(&px, w, h).expect("a normal photo must produce a preview");
        assert!(out.len() <= MAX_BYTES, "preview is {} B, budget {}", out.len(), MAX_BYTES);
        // AVIF files carry an `ftyp` box with an avif brand.
        assert!(out.len() > 12 && &out[4..8] == b"ftyp", "output must be a real AVIF container");
    }

    #[test]
    fn fit_preserves_aspect_and_never_upscales() {
        assert_eq!(fit(1024, 768), (512, 384));
        assert_eq!(fit(768, 1024), (384, 512));
        assert_eq!(fit(200, 150), (200, 150), "already small: not upscaled");
        assert_eq!(fit(512, 512), (512, 512));
    }

    /// The path the composer actually takes: encoded bytes in, preview out. Desktop cannot do this
    /// in the webview (Chromium's canvas has no AVIF writer), so this function is the whole reason
    /// the encode lives in Rust.
    #[test]
    fn encodes_a_preview_from_encoded_image_bytes() {
        let (w, h) = (1600u32, 1200u32);
        let px = photo(w, h);
        // Round-trip through PNG so the input is what a caller really hands us: encoded bytes.
        let mut raw = Vec::with_capacity((w * h * 3) as usize);
        for p in &px {
            raw.push(p.r);
            raw.push(p.g);
            raw.push(p.b);
        }
        let img: image::RgbImage = image::ImageBuffer::from_raw(w, h, raw).expect("buffer");
        let mut encoded = std::io::Cursor::new(Vec::new());
        img.write_to(&mut encoded, image::ImageFormat::Png).expect("png");

        let out = encode_image_bytes(encoded.get_ref()).expect("a real photo must produce a preview");
        assert!(out.len() <= MAX_BYTES, "preview is {} B, budget {}", out.len(), MAX_BYTES);
        assert!(out.len() > 12 && &out[4..8] == b"ftyp", "must be a real AVIF container");
    }

    #[test]
    fn undecodable_bytes_yield_no_preview() {
        assert!(encode_image_bytes(b"not an image at all").is_none());
        assert!(encode_image_bytes(&[]).is_none());
    }

    #[test]
    fn degenerate_input_is_refused_not_panicked() {
        assert!(encode_rgb8(&[], 0, 0).is_none());
        assert!(encode_rgb8(&photo(4, 4), 100, 100).is_none(), "short buffer must be refused");
    }
}
