import XCTest
import CoreGraphics
@testable import HavenLogicTests

/// The visual fingerprint that makes duplicate detection safe.
///
/// The point of it is a property no content hash has: it survives a re-encode. Haven's media refs
/// are sha-256 of the plaintext, so importing the same archive twice produces different refs for the
/// same picture — which is exactly why the first duplicate sweep found nothing. These tests assert
/// the two halves that matter: the same picture through a lossy round trip still matches, and two
/// different pictures still don't.
final class PerceptualHashTests: XCTestCase {

    /// A greyscale test image from a pixel generator, so cases are exactly reproducible.
    private func image(_ w: Int, _ h: Int, _ value: (Int, Int) -> UInt8) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = value(x, y) } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    /// A gradient with structure — the sort of thing a photo is, as far as a 9x8 downsample cares.
    private func photo(seed: Int) -> CGImage {
        image(64, 64) { x, y in
            let v: Int = x &* 3 &+ y &* 5 &+ seed &* 37
            return UInt8(v % 256)
        }
    }

    func testTheSamePictureHashesTheSame() {
        let a = PerceptualHash.dHash(photo(seed: 1))
        let b = PerceptualHash.dHash(photo(seed: 1))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    /// THE CASE THE WHOLE THING EXISTS FOR: the same picture at a different SIZE — which is what a
    /// re-encode through the importer's optimizer produces, and where a byte hash gives up.
    func testTheSamePictureAtADifferentScaleStillMatches() {
        // Written as typed statements rather than one expression on purpose: the single-expression
        // form mixed `/`, `&*`, `&+` and `%` inside a `UInt8` init, and the compiler gave up
        // type-checking it in reasonable time — which failed the whole test target in CI.
        let big = image(128, 128) { x, y in
            let v: Int = (x / 2) &* 3 &+ (y / 2) &* 5
            return UInt8(v % 256)
        }
        let small = image(64, 64) { x, y in
            let v: Int = x &* 3 &+ y &* 5
            return UInt8(v % 256)
        }
        guard let a = PerceptualHash.dHash(big), let b = PerceptualHash.dHash(small) else {
            return XCTFail("hashing failed")
        }
        XCTAssertTrue(PerceptualHash.looksLikeTheSamePicture(a, b),
                      "same image rescaled differs by \(PerceptualHash.distance(a, b)) bits — "
                      + "a re-encoded import copy must still be recognised")
    }

    func testDifferentPicturesDoNotMatch() {
        guard let a = PerceptualHash.dHash(photo(seed: 1)),
              let b = PerceptualHash.dHash(image(64, 64) { x, y in
                  let v: Int = x &* 11 &+ y &* 2
                  return UInt8(v % 256)
              })
        else { return XCTFail("hashing failed") }
        XCTAssertFalse(PerceptualHash.looksLikeTheSamePicture(a, b),
                       "two different images matched at \(PerceptualHash.distance(a, b)) bits")
    }

    func testDistanceIsSymmetricAndZeroForIdentical() {
        guard let a = PerceptualHash.dHash(photo(seed: 3)) else { return XCTFail("hashing failed") }
        XCTAssertEqual(PerceptualHash.distance(a, a), 0)
        guard let b = PerceptualHash.dHash(photo(seed: 4)) else { return XCTFail("hashing failed") }
        XCTAssertEqual(PerceptualHash.distance(a, b), PerceptualHash.distance(b, a))
    }
}
