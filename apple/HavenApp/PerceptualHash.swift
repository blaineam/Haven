import Foundation
import CoreGraphics

/// A 64-bit fingerprint of what a picture LOOKS like, rather than of its bytes.
///
/// Haven identifies media by sha-256 of the plaintext, which is exactly right for storage and
/// exactly useless for "is this the same photo?": the importer re-encodes everything it stages, and
/// re-encoding is not reproducible — a video is remuxed by AVAssetExportSession with its own
/// timestamps, posters are generated fresh, a JPEG round-trip need not be byte-identical. Import the
/// same archive twice and every content hash differs while every picture is the same. That is what
/// defeated the first duplicate sweep.
///
/// dHash (difference hash): reduce to 9×8 grey, then take one bit per adjacent horizontal pair —
/// "is this pixel brighter than the one to its right". What survives is the coarse structure of the
/// image, which is what re-encoding preserves and what a different photo does not share. It is
/// deliberately not a cryptographic hash and must never be used as one.
enum PerceptualHash {

    /// Bits that may differ before two pictures are considered different.
    ///
    /// 0 would demand bit-identical downsamples, which re-encoding does not guarantee. Anything past
    /// ~10 starts matching photos that merely share a composition — two frames of the same sunset,
    /// which are two posts. 6 of 64 is the usual working range for dHash and leaves a wide margin on
    /// both sides: a re-encode of the same JPEG typically lands at 0–2, and genuinely different
    /// pictures are almost always past 20.
    static let duplicateThreshold = 6

    private static let width = 9
    private static let height = 8

    /// Nil when the image cannot be rendered — callers must treat that as "unknown", never as a match.
    static func dHash(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] { hash |= (1 << UInt64(bit)) }
                bit += 1
            }
        }
        return hash
    }

    /// Hamming distance — how many of the 64 bits differ.
    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    static func looksLikeTheSamePicture(_ a: UInt64, _ b: UInt64) -> Bool {
        distance(a, b) <= duplicateThreshold
    }
}
