import XCTest

/// Safety words are compared OUT LOUD between two phones, often an iPhone and an Android phone, so
/// the mapping must be identical on both. These are the same golden vectors Android's
/// `SafetyWordsTest.matches_ios_golden_vectors` pins — if either side drifts, both suites say so.
final class SafetyWordsTests: XCTestCase {

    func testGoldenVectorsSharedWithAndroid() {
        let golden: [String: String] = [
            "00": "apple",
            "ff": "fox",
            "0102030405": "amber anchor aspen basil",
            "deadbeef": "topaz deer leaf brook",
            "a1b2c3d4e5f60718": "bloom finch mint sky",
            "000102030405060708090a0b0c0d0e0f": "apple amber anchor aspen",
            "abcdef0123456789": "daisy quail brook amber",
            "4c30224b": "apple panda honey wren",
        ]
        for (hex, expected) in golden {
            XCTAssertEqual(SafetyWords.words(fromHex: hex).joined(separator: " "), expected, "hex=\(hex)")
        }
    }

    func testByteModuloWrapsAt76() {
        XCTAssertEqual(SafetyWords.words(fromHex: "4c").first, "apple")   // 76 % 76 == 0
        XCTAssertEqual(SafetyWords.words(fromHex: "4d").first, "amber")   // 77 % 76 == 1
    }

    func testCountAndShortInput() {
        XCTAssertEqual(SafetyWords.words(fromHex: "aabbccddeeff0011").count, 4)
        XCTAssertEqual(SafetyWords.words(fromHex: "aabbccddeeff0011", count: 6).count, 6)
        XCTAssertEqual(SafetyWords.words(fromHex: "aabbcc").count, 3)
        XCTAssertEqual(SafetyWords.words(fromHex: ""), [])
    }

    func testHexCaseDoesNotChangeTheWords() {
        XCTAssertEqual(SafetyWords.words(fromHex: "ABCDEF0123456789"), SafetyWords.words(fromHex: "abcdef0123456789"))
    }

    func testDifferentFingerprintsUsuallyDiffer() {
        // A one-byte change in the first four bytes must change the phrase (no collisions within 76).
        for b in 0..<76 {
            let a = String(format: "%02x000000", b)
            let c = String(format: "%02x000000", (b + 1) % 76)
            XCTAssertNotEqual(SafetyWords.words(fromHex: a), SafetyWords.words(fromHex: c))
        }
    }
}
