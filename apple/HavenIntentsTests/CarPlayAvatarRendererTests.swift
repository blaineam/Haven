import CarPlay
import XCTest

/// Pixel checks on the real renderer: circle mask (corners transparent), centre opaque, photo FILLS the
/// circle, and the bitmap is square at the size CarPlay wants.
final class CarPlayAvatarRendererTests: XCTestCase {
    private let stops: [UInt32] = [0x7C3AED, 0xEC4899, 0xF59E0B]
    private var side: CGFloat { CarPlayAvatar.side(max: CPMaximumMessageItemImageSize) }

    private func render(_ spec: CarPlayAvatar.Spec, photo: UIImage? = nil, id: String = "dm:a") -> UIImage {
        CarPlayAvatarRenderer.shared.image(for: spec, photo: photo, photoStamp: 1, id: id, side: side, scale: 2,
                                           paletteId: "test-\(UUID().uuidString)", stops: stops)
    }

    /// RGBA of the pixel at (x, y) in points.
    private func pixel(_ img: UIImage, _ x: CGFloat, _ y: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cg = img.cgImage!
        let sx = Int(x * img.scale), sy = Int(y * img.scale)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -sx, y: -(cg.height - 1 - sy), width: cg.width, height: cg.height))
        return (px[0], px[1], px[2], px[3])
    }

    private func photo(_ w: CGFloat, _ h: CGFloat, left: UIColor, right: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { c in
            left.setFill(); c.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            right.setFill(); c.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        }
    }

    func testBitmapIsSquareAtTheCarSizeAndScale() {
        let img = render(.initials("TM"))
        XCTAssertEqual(img.size.width, img.size.height)
        XCTAssertEqual(img.size.width, side)
        XCTAssertEqual(img.scale, 2)
        XCTAssertLessThanOrEqual(img.size.width, CPMaximumMessageItemImageSize.width)
        XCTAssertLessThanOrEqual(img.size.height, CPMaximumMessageItemImageSize.height)
    }

    func testEveryKindIsCircleMasked() {
        let wide = photo(400, 200, left: .red, right: .blue)
        for spec in [CarPlayAvatar.Spec.photo, .emoji("🌿"), .initials("TM"), .generic] {
            let img = render(spec, photo: wide)
            XCTAssertEqual(pixel(img, 0.5, 0.5).a, 0, "\(spec) top-left corner is outside the circle")
            XCTAssertEqual(pixel(img, side - 0.5, side - 0.5).a, 0, "\(spec) bottom-right corner")
            XCTAssertEqual(pixel(img, side / 2, side / 2).a, 255, "\(spec) centre is opaque")
        }
    }

    func testWidePhotoFillsTheCircleInsteadOfLetterboxing() {
        // 400x200 red|blue photo: fill crops the sides, so the circle's left/right edges are still the
        // photo's colours and its top/bottom are NOT transparent bands (as a letterboxed fit would be).
        let img = render(.photo, photo: photo(400, 200, left: .red, right: .blue))
        let mid = side / 2
        let left = pixel(img, side * 0.2, mid), right = pixel(img, side * 0.8, mid)
        XCTAssertGreaterThan(left.r, 200); XCTAssertLessThan(left.b, 60)
        XCTAssertGreaterThan(right.b, 200); XCTAssertLessThan(right.r, 60)
        XCTAssertEqual(pixel(img, mid, side * 0.12).a, 255, "top of the circle is photo, not an empty band")
        XCTAssertEqual(pixel(img, mid, side * 0.88).a, 255, "bottom of the circle is photo, not an empty band")
    }

    func testPhotoSpecWithoutAPhotoStillDrawsSomething() {
        XCTAssertEqual(pixel(render(.photo, photo: nil), side / 2, side / 2).a, 255)
    }

    func testRepeatCallsHitTheCache() {
        let a = CarPlayAvatarRenderer.shared.image(for: .initials("ZZ"), photo: nil, photoStamp: 0, id: "dm:cache", side: side,
                                                   scale: 2, paletteId: "cache-test", stops: stops)
        let b = CarPlayAvatarRenderer.shared.image(for: .initials("ZZ"), photo: nil, photoStamp: 0, id: "dm:cache", side: side,
                                                   scale: 2, paletteId: "cache-test", stops: stops)
        XCTAssertTrue(a === b)
    }
}
