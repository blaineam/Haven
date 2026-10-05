import XCTest

/// Device-id dial hints on invite links (Apple side). The golden vector is the same one Android's
/// `InviteHintsTest` pins, so a link minted on either platform reads identically on the other, and
/// old parsers that only read the `#` fragment never see the hint.
final class InviteHintsTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "0123456789abcdef", count: 4)
    private let link = "haven://u/abcd#VERIFY"

    func testGoldenVectorSharedWithAndroid() {
        XCTAssertEqual(InviteHints.embed(in: link, deviceIds: [a, b]), "haven://u/abcd?d=\(a),\(b)#VERIFY")
    }

    func testEmbedThenExtractRoundTripsAndKeepsTheFragment() {
        let out = InviteHints.embed(in: link, deviceIds: [a, b])
        XCTAssertEqual(InviteHints.extract(from: out), [a, b])
        XCTAssertTrue(out.hasSuffix("#VERIFY"))
    }

    func testEmbedCapsAtFourAndDropsMalformedIds() {
        let ids = (0..<6).map { String(repeating: String($0), count: 64) } + ["short"]
        let out = InviteHints.embed(in: link, deviceIds: ids)
        XCTAssertEqual(InviteHints.extract(from: out).count, InviteHints.maxHints)
        XCTAssertFalse(out.contains("short"))
    }

    func testEmbedLeavesLinksItCannotSafelyExtendUnchanged() {
        XCTAssertEqual(InviteHints.embed(in: link, deviceIds: []), link)
        XCTAssertEqual(InviteHints.embed(in: "haven://u/abcd", deviceIds: [a]), "haven://u/abcd")
        XCTAssertEqual(InviteHints.embed(in: "haven://u/x?t=1#V", deviceIds: [a]), "haven://u/x?t=1#V")
    }

    func testExtractLowercasesFiltersAndIgnoresAQueryInsideTheFragment() {
        XCTAssertEqual(InviteHints.extract(from: "haven://u/x?d=\(a.uppercased()),zz,\(String(repeating: "g", count: 64))#V"), [a])
        XCTAssertEqual(InviteHints.extract(from: "haven://u/x#V?d=\(a)"), [])
        XCTAssertEqual(InviteHints.extract(from: "https://example.com/u/x?t=abc&d=\(b)#V"), [b])
    }

    /// The offline-invite ticket rides as a second query pair AFTER `d=`, so old parsers still see
    /// `d=` first and the fragment is untouched.
    func testAppendQueryAndQueryValue() {
        let withHints = InviteHints.embed(in: link, deviceIds: [a])
        let withTicket = InviteHints.appendQuery(in: withHints, name: "t", value: "dGlja2V0")
        XCTAssertEqual(withTicket, "haven://u/abcd?d=\(a)&t=dGlja2V0#VERIFY")
        XCTAssertEqual(InviteHints.queryValue(from: withTicket, name: "t"), "dGlja2V0")
        XCTAssertEqual(InviteHints.extract(from: withTicket), [a])
        XCTAssertEqual(InviteHints.appendQuery(in: link, name: "t", value: "x"), "haven://u/abcd?t=x#VERIFY")
        XCTAssertEqual(InviteHints.appendQuery(in: link, name: "t", value: ""), link)
        XCTAssertNil(InviteHints.queryValue(from: link, name: "t"))
        XCTAssertNil(InviteHints.queryValue(from: "haven://u/x#V?t=1", name: "t"))
    }
}
