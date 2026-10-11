import XCTest

/// 2.0.1 moved the persisted state's byte fields from decimal arrays to base64. A state file
/// written by 2.0.0 must still parse in Swift (FeedStore's set-aside recovery reads it directly).
final class PersistedStateBytesTests: XCTestCase {
    private let key: [UInt8] = (0..<40).map { UInt8(($0 * 37 + 5) & 0xff) }
    private var hex: String { key.prefix(32).map { String(format: "%02x", $0) }.joined() }

    /// The same member bundle in both on-disk forms, parsed the way FeedStore parses them.
    private func member(fromJSON json: String) throws -> Any {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let circles = try XCTUnwrap(root["circles"] as? [[String: Any]])
        return try XCTUnwrap((circles.first?["members"] as? [Any])?.first)
    }

    func testDecimalArrayFormFrom200Parses() throws {
        let decimal = "[" + key.map(String.init).joined(separator: ",") + "]"
        let m = try member(fromJSON: #"{"circles":[{"id":"default","members":[\#(decimal)]}]}"#)
        XCTAssertEqual(PersistedStateBytes.bytes(m), key)
        XCTAssertEqual(PersistedStateBytes.keyHex(m), hex)
    }

    func testBase64FormFrom201Parses() throws {
        let b64 = Data(key).base64EncodedString()
        let m = try member(fromJSON: #"{"circles":[{"id":"default","members":["\#(b64)"]}]}"#)
        XCTAssertEqual(PersistedStateBytes.bytes(m), key)
        XCTAssertEqual(PersistedStateBytes.keyHex(m), hex)
    }

    func testShortOrForeignValuesYieldNoKey() {
        XCTAssertEqual(PersistedStateBytes.keyHex(Data([1, 2, 3]).base64EncodedString()), "")
        XCTAssertEqual(PersistedStateBytes.keyHex("not base64!"), "")
        XCTAssertEqual(PersistedStateBytes.keyHex(42), "")
    }
}
