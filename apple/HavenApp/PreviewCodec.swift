import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The 512px AVIF preview tier (`docs/PREVIEW-TIER-DESIGN.md`). Mirrors Android `PreviewCodec.kt`.
///
/// This is the only media small enough to cross a satellite link: about 6 KB, under two Haven text
/// messages, where the existing `thumb:` companion is ≤32 KB and a full photo is megabytes. It is
/// what makes sending a picture from a place with no signal possible at all; the full copy follows
/// when service returns.
///
/// **Why AVIF and not JPEG.** Measured on real device photographs at 512px, scored with PSNR against
/// the uncompressed downscale: JPEG cannot reach the budget — its floor is ~12 KB even at quality
/// 0.1, and it is *worse* there (29.7 dB) than AVIF is at 6.2 KB (30.3 dB). AVIF is roughly half the
/// bytes at matched quality, and a 5x reduction against today's `thumb:` contract at a larger size.
///
/// **Why the target is BYTES, not a quality number.** The platforms' encoders take different scales
/// that do not line up — ImageIO 0–1, `ravif` 0–100, avif-coder 0–100 — and the same nominal value
/// produces materially different sizes. A shared quality constant would silently mean three
/// different things, so the shared spec is: 512px longest edge, under `maxBytes`, quality walked
/// down until it fits.
///
/// Apple encodes AVIF natively — verified rather than assumed, since Apple's documentation discusses
/// only decoding: `CGImageDestinationCopyTypeIdentifiers()` lists `public.avif` on iOS, and a real
/// encode returns bytes.
enum PreviewCodec {
    /// Longest edge of a preview, in pixels.
    static let maxDimension = 512

    /// Hard ceiling for a preview. ~2 Haven text messages.
    static let maxBytes = 8 * 1024

    /// The AVIF type identifier. Spelled out rather than `UTType.avif`, which does not exist as a
    /// static member — the type is known to the system by identifier.
    static let avifIdentifier = "public.avif"

    /// Quality ladder, walked highest-first until the result fits `maxBytes`. Starting high and
    /// stepping down costs a few extra encodes on a complex image and yields the best-looking
    /// preview that fits, rather than a uniformly poor one sized for the worst case.
    private static let qualityLadder: [Double] = [0.45, 0.38, 0.32, 0.26, 0.20, 0.15, 0.10, 0.05]

    /// True when this build can write previews at all. False would mean falling back to no preview —
    /// never to sending full media over a constrained link.
    static var canEncode: Bool {
        guard let types = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return false }
        return types.contains(avifIdentifier)
    }

    /// Encode a preview, or nil if even the lowest quality will not fit.
    static func encode(_ image: CGImage) -> Data? {
        guard let scaled = downscale(image) else { return nil }
        for q in qualityLadder {
            guard let data = encodeAVIF(scaled, quality: q) else { continue }
            if data.count <= maxBytes { return data }
        }
        return nil
    }

    #if canImport(UIKit)
    static func encode(_ image: UIImage) -> Data? { upright(image).flatMap(encode) }

    /// The image's pixels ROTATED UPRIGHT.
    ///
    /// `UIImage.cgImage` hands back the pixels exactly as stored and leaves the rotation behind in
    /// `imageOrientation` — cameras record orientation as metadata rather than rotating the sensor
    /// data. Encoding that CGImage directly bakes the wrong rotation into the companion permanently,
    /// because the re-encoded AVIF carries no orientation of its own to correct it.
    ///
    /// The visible symptom: a photo's preview renders sideways on every platform, then appears to
    /// "flip" upright the instant the full-resolution original arrives — the original still has its
    /// EXIF tag and is drawn correctly, so the two representations of one photo disagree.
    private static func upright(_ image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        guard image.imageOrientation != .up else { return cg }
        // Redrawing applies `imageOrientation` (including the mirrored cases, which a bare rotation
        // would get backwards). Point size, so the renderer's own scale is not applied twice.
        let size = CGSize(width: cg.width, height: cg.height)
        let bounds = image.imageOrientation.isSideways
            ? CGSize(width: size.height, height: size.width) : size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: bounds, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: bounds)) }
            .cgImage
    }
    #else
    static func encode(_ image: NSImage) -> Data? {
        var rect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap(encode)
    }
    #endif

    /// Decode a preview back to an image.
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func encodeAVIF(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, avifIdentifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Fit to `maxDimension` on the longest edge, preserving aspect. Never upscales — a picture that
    /// is already small is already its own preview.
    private static func downscale(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        if longest <= maxDimension { return image }
        let scale = Double(maxDimension) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}


#if canImport(UIKit)
extension UIImage.Orientation {
    /// Orientations that exchange width and height. Getting this wrong crops the redraw to the
    /// wrong box rather than merely rotating it.
    var isSideways: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }
}
#endif
