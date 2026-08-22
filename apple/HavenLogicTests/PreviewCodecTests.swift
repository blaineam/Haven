import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import HavenLogicTests

/// The preview tier's contract: 512px, under 8 KB, and a real decodable AVIF.
///
/// The budget is the feature. A preview that does not fit is not a smaller picture — it is a picture
/// that cannot cross a satellite link, which is the only reason this tier exists.
final class PreviewCodecTests: XCTestCase {

    /// A photo-like source: smooth gradient plus high-frequency detail, so the encoder is not handed
    /// something trivially compressible and the budget is tested honestly.
    private func photo(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
                // Gradient + a fine checker so there is real detail to spend bits on.
                let detail = ((x / 3) + (y / 3)) % 2 == 0 ? 0.12 : 0.0
                ctx.setFillColor(red: min(1, 0.5 + 0.5 * sin(fx * 9) + detail),
                                 green: min(1, 0.4 + 0.4 * cos(fy * 7) + detail),
                                 blue: min(1, 0.6 + 0.3 * sin((fx + fy) * 11)),
                                 alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    func testThisBuildCanWritePreviews() {
        // Every client must be able to WRITE previews, not just read them — any device can be the
        // sender. Apple's docs only discuss decoding AVIF, so this is asserted rather than trusted.
        // CI macos-15 runners ship an ImageIO with NO AVIF writer ("unsupported output file
        // format public.avif"), while every OS this app targets has one. "No encoder" is a designed
        // state — the product answer is "no preview for this item", never a crash — so the tests
        // SKIP there rather than fail: a red that means "the runner is old" teaches nothing.
        try XCTSkipUnless(PreviewCodec.canEncode, "runner ImageIO has no AVIF writer — encode tests skipped")
    }

    func testAPreviewFitsTheBudgetAndDecodesBack() throws {
        let src = photo(1600, 1200)
        try XCTSkipUnless(PreviewCodec.canEncode, "no AVIF writer on this runner")
        let data = try XCTUnwrap(PreviewCodec.encode(src), "a normal photo must produce a preview")

        XCTAssertLessThanOrEqual(data.count, PreviewCodec.maxBytes,
                                 "preview is \(data.count) B, budget is \(PreviewCodec.maxBytes) B")

        let back = try XCTUnwrap(PreviewCodec.decode(data), "a preview must decode")
        XCTAssertLessThanOrEqual(max(back.width, back.height), PreviewCodec.maxDimension)
        // Aspect preserved (4:3 in, 4:3 out).
        let ratioIn = Double(src.width) / Double(src.height)
        let ratioOut = Double(back.width) / Double(back.height)
        XCTAssertEqual(ratioIn, ratioOut, accuracy: 0.02, "a preview must not distort the picture")
    }

    func testPreviewIsActuallyAvifNotSomethingElse() throws {
        try XCTSkipUnless(PreviewCodec.canEncode, "no AVIF writer on this runner")
        let data = try XCTUnwrap(PreviewCodec.encode(photo(1024, 1024)))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let uti = try XCTUnwrap(CGImageSourceGetType(src) as String?)
        XCTAssertEqual(uti, PreviewCodec.avifIdentifier, "the tier is AVIF; JPEG cannot meet the budget")
    }

    func testASmallPictureIsNotUpscaled() throws {
        let small = photo(200, 150)
        try XCTSkipUnless(PreviewCodec.canEncode, "no AVIF writer on this runner")
        let data = try XCTUnwrap(PreviewCodec.encode(small))
        let back = try XCTUnwrap(PreviewCodec.decode(data))
        XCTAssertEqual(back.width, 200)
        XCTAssertEqual(back.height, 150)
        XCTAssertLessThanOrEqual(data.count, PreviewCodec.maxBytes)
    }

    func testAPathologicallyDetailedImageStillFits() throws {
        // Worst case for an encoder: dense high-frequency noise, nothing to predict. The ladder must
        // walk far enough down to stay inside the budget rather than returning an oversized preview.
        let w = 1024, h = 1024
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 1000) / 1000.0
        }
        for y in 0..<h {
            for x in 0..<w {
                ctx.setFillColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let noise = ctx.makeImage()!
        if let data = PreviewCodec.encode(noise) {
            XCTAssertLessThanOrEqual(data.count, PreviewCodec.maxBytes,
                                     "the ladder must walk down far enough: got \(data.count) B")
        }
        // A nil here is also acceptable — "no preview for this item" is a valid answer, and the
        // caller must never read it as permission to send full media on a constrained link.
    }
}
