import XCTest

/// Which avatar a CarPlay row gets, and the geometry that makes it a square, circle-masked, aspect-fill
/// bitmap (CarPlay draws leading images verbatim: a raw photo showed as an uncropped rectangle).
final class CarPlayAvatarTests: XCTestCase {
    private typealias A = CarPlayAvatar

    // MARK: choice + privacy

    func testPhotoThenEmojiThenInitialsThenGeneric() {
        XCTAssertEqual(A.choose(locked: false, detail: .full, hasPhoto: true, emoji: "🌿", name: "Tracy M"), .photo)
        XCTAssertEqual(A.choose(locked: false, detail: .full, hasPhoto: false, emoji: "🌿", name: "Tracy M"), .emoji("🌿"))
        XCTAssertEqual(A.choose(locked: false, detail: .full, hasPhoto: false, emoji: nil, name: "Tracy M"), .initials("TM"))
        XCTAssertEqual(A.choose(locked: false, detail: .full, hasPhoto: false, emoji: "", name: "Tracy"), .initials("T"))
        XCTAssertEqual(A.choose(locked: false, detail: .full, hasPhoto: false, emoji: nil, name: "🌿"), .generic)
        XCTAssertEqual(A.choose(locked: false, detail: .full, hasPhoto: false, emoji: nil, name: ""), .generic)
    }

    func testLockedAndMinimalRevealNothing() {
        for detail in [SharedNotificationPrivacy.Detail.full, .privateDetail, .minimal] {
            XCTAssertEqual(A.choose(locked: true, detail: detail, hasPhoto: true, emoji: "🌿", name: "Tracy M"), .generic)
        }
        XCTAssertEqual(A.choose(locked: false, detail: .minimal, hasPhoto: true, emoji: "🌿", name: "Tracy M"), .generic)
        XCTAssertEqual(A.choose(locked: false, detail: .privateDetail, hasPhoto: true, emoji: nil, name: "Tracy M"), .photo)
    }

    func testEmojiIsTheFirstRealEmojiNotADigit() {
        XCTAssertEqual(A.firstEmoji("Mom ❤️"), "❤️")
        XCTAssertNil(A.firstEmoji("Room 101 #1"))
        XCTAssertEqual(A.firstEmoji("🇯🇵 Tokyo"), "🇯🇵")
        XCTAssertEqual(A.choose(locked: false, detail: .full, hasPhoto: false, emoji: "7", name: "Sam"), .initials("S"), "a digit is not an avatar emoji")
    }

    // MARK: initials

    func testInitials() {
        XCTAssertEqual(A.initials("Tracy Miller"), "TM")
        XCTAssertEqual(A.initials("tracy"), "T")
        XCTAssertEqual(A.initials("Alice, Bob & Carol"), "AC")
        XCTAssertEqual(A.initials("Maya 🌿"), "M")
        XCTAssertEqual(A.initials("🌿"), "")
        XCTAssertEqual(A.initials("田中太郎"), "田")
        XCTAssertEqual(A.initials("  José  Luís "), "JL")
        XCTAssertEqual(A.initials("Mary Jo van der Berg"), "MB")
        XCTAssertEqual(A.initials("---"), "")
    }

    // MARK: geometry

    func testCanvasIsTheLargestSquareThatFits() {
        XCTAssertEqual(A.side(max: CGSize(width: 60, height: 40)), 40)
        XCTAssertEqual(A.side(max: CGSize(width: 40, height: 60)), 40)
        XCTAssertEqual(A.side(max: .zero), 1)
    }

    func testFillRectCoversTheSquareAndCentres() {
        // Landscape photo 400x200 on a 100 canvas: scaled to height 100 -> 200 wide, cropped 50 each side.
        let wide = A.fillRect(source: CGSize(width: 400, height: 200), side: 100)
        XCTAssertEqual(wide, CGRect(x: -50, y: 0, width: 200, height: 100))
        // Portrait 200x400: scaled to width 100 -> 200 tall.
        let tall = A.fillRect(source: CGSize(width: 200, height: 400), side: 100)
        XCTAssertEqual(tall, CGRect(x: 0, y: -50, width: 100, height: 200))
        // Already square: exactly the canvas.
        XCTAssertEqual(A.fillRect(source: CGSize(width: 90, height: 90), side: 100), CGRect(x: 0, y: 0, width: 100, height: 100))
        // Upscales small sources (fill, never letterbox).
        let tiny = A.fillRect(source: CGSize(width: 10, height: 20), side: 100)
        XCTAssertEqual(tiny.width, 100); XCTAssertGreaterThanOrEqual(tiny.height, 100)
        // Degenerate source never divides by zero.
        XCTAssertEqual(A.fillRect(source: .zero, side: 50), CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    func testFillAlwaysCoversTheWholeCanvas() {
        for (w, h) in [(1.0, 1.0), (1000, 10), (10, 1000), (333, 222), (222, 333)] {
            let r = A.fillRect(source: CGSize(width: w, height: h), side: 64)
            XCTAssertLessThanOrEqual(r.minX, 0.0001); XCTAssertLessThanOrEqual(r.minY, 0.0001)
            XCTAssertGreaterThanOrEqual(r.maxX, 63.9999); XCTAssertGreaterThanOrEqual(r.maxY, 63.9999)
            XCTAssertEqual(r.width / r.height, w / h, accuracy: 0.0001, "aspect preserved")
        }
    }

    // MARK: tint + cache key

    func testTintIsStableAcrossCallsAndInRange() {
        XCTAssertEqual(A.tintIndex("dm:aa"), A.tintIndex("dm:aa"))
        let seen = Set((0..<60).map { A.tintIndex("dm:\($0)") })
        XCTAssertEqual(seen, [0, 1, 2], "ids spread across the three stops")
        XCTAssertTrue((0...2).contains(A.tintIndex("")))
    }

    func testCacheKeyChangesWithEverythingThatChangesPixels() {
        let base = A.cacheKey(id: "dm:a", spec: .photo, side: 60, scale: 2, paletteId: "sunset", photoStamp: 1)
        XCTAssertNotEqual(base, A.cacheKey(id: "dm:a", spec: .photo, side: 60, scale: 2, paletteId: "sunset", photoStamp: 2))
        XCTAssertNotEqual(base, A.cacheKey(id: "dm:a", spec: .photo, side: 60, scale: 3, paletteId: "sunset", photoStamp: 1))
        XCTAssertNotEqual(base, A.cacheKey(id: "dm:a", spec: .photo, side: 60, scale: 2, paletteId: "ocean", photoStamp: 1))
        XCTAssertNotEqual(base, A.cacheKey(id: "dm:a", spec: .initials("A"), side: 60, scale: 2, paletteId: "sunset", photoStamp: 1))
        XCTAssertEqual(base, A.cacheKey(id: "dm:a", spec: .photo, side: 60, scale: 2, paletteId: "sunset", photoStamp: 1))
    }
}
