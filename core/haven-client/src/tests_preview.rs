//! The import fallback's still / thumb re-encode and the AVIF preview from real encoded bytes:
//! what the Instagram importer ships when the webview cannot do it.

use super::*;

fn detailed(w: u32, h: u32) -> image::RgbImage {
    image::RgbImage::from_fn(w, h, |x, y| {
        let d = if (x / 3 + y / 3) % 2 == 0 { 40 } else { 0 };
        image::Rgb([((x * 255 / w) as u8).wrapping_add(d), ((y * 255 / h) as u8).wrapping_add(d), (((x + y) * 3) % 251) as u8])
    })
}

/// A smooth photo-like gradient, which a 8 KB AVIF budget can hold (the detailed one cannot, by design).
fn smooth(w: u32, h: u32) -> image::RgbImage {
    image::RgbImage::from_fn(w, h, |x, y| {
        let (fx, fy) = (x as f32 / w as f32, y as f32 / h as f32);
        image::Rgb([(120.0 + 100.0 * (fx * 3.0).sin()) as u8, (110.0 + 90.0 * (fy * 2.0).cos()) as u8, (100.0 + 80.0 * ((fx + fy) * 2.0).sin()) as u8])
    })
}

fn encode(img: &image::RgbImage, fmt: image::ImageFormat) -> Vec<u8> {
    let mut out = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(img.clone()).write_to(&mut out, fmt).expect("encodes");
    out.into_inner()
}

fn dims(jpeg: &[u8]) -> (u32, u32) {
    let d = image::load_from_memory(jpeg).expect("decodes");
    (d.width(), d.height())
}

#[test]
fn a_big_still_is_resized_to_the_feed_target_and_a_small_one_is_left_alone() {
    let big = encode(&detailed(2400, 1800), image::ImageFormat::Jpeg);
    let still = encode_still_jpeg(&big).expect("a real JPEG re-encodes");
    assert_eq!(dims(&still), (1600, 1200), "longest edge 1600, aspect kept");
    assert!(still.len() < big.len());

    let small = encode(&detailed(800, 600), image::ImageFormat::Png);
    let kept = encode_still_jpeg(&small).expect("a PNG becomes a JPEG");
    assert_eq!(dims(&kept), (800, 600), "never upscaled, never shrunk below the target");
    assert_eq!(&kept[..2], &[0xFF, 0xD8], "and it is a JPEG");

    assert!(encode_still_jpeg(b"definitely not an image").is_none(), "undecodable bytes fall back to the original");
}

#[test]
fn the_thumb_companion_is_256px_under_32_kb_and_absent_for_an_already_small_source() {
    let big = encode(&detailed(2000, 1500), image::ImageFormat::Jpeg);
    let thumb = encode_thumb_jpeg(&big).expect("a large still gets a thumb");
    assert_eq!(dims(&thumb), (256, 192));
    assert!(thumb.len() <= 32 * 1024);

    let tiny = encode(&detailed(200, 120), image::ImageFormat::Jpeg);
    assert!(encode_thumb_jpeg(&tiny).is_none(), "the content ref is its own thumb");
    assert!(encode_thumb_jpeg(&[0u8; 16]).is_none());
}

#[test]
fn a_decoded_photo_becomes_a_budgeted_avif_preview_and_bad_input_makes_none() {
    let png = encode(&smooth(1200, 900), image::ImageFormat::Png);
    let avif = encode_image_bytes(&png).expect("a normal photo makes a preview");
    assert!(avif.len() <= MAX_BYTES);
    assert_eq!(&avif[4..8], b"ftyp");
    let small = encode(&smooth(300, 200), image::ImageFormat::Png);
    assert!(encode_image_bytes(&small).is_some(), "an image already under the cap is its own preview size");
    assert!(encode_image_bytes(b"nope").is_none());
    assert!(encode_rgb8(&[], 0, 0).is_none());
    assert!(encode_rgb8(&[RGB8::new(1, 2, 3)], 4, 4).is_none(), "fewer pixels than the dimensions claim");
}
