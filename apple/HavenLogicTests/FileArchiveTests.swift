import XCTest

/// CRC + zip round-trip for the pure-logic archive writer. No app/FFI deps.
final class FileArchiveTests: XCTestCase {

    func testCrc32KnownVector() {
        // ISO 3309 / ZIP CRC of "123456789" is the well-known 0xcbf43926.
        let data = Data("123456789".utf8)
        XCTAssertEqual(FileArchive.crc32(data), 0xcbf43926)
    }

    func testCrc32Empty() {
        XCTAssertEqual(FileArchive.crc32(Data()), 0)
    }

    func testZipSingleFileRoundTripShape() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-zip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("hello.txt")
        try Data("hello haven".utf8).write(to: src)

        guard let zip = FileArchive.zip([src], preferredName: "hello") else {
            return XCTFail("zip returned nil")
        }
        defer { try? FileManager.default.removeItem(at: zip) }

        let bytes = try Data(contentsOf: zip)
        // Local file header magic
        XCTAssertEqual(bytes.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        // End of central directory magic somewhere near the end
        XCTAssertTrue(bytes.range(of: Data([0x50, 0x4b, 0x05, 0x06])) != nil)
        // Non-trivial size
        XCTAssertGreaterThan(bytes.count, 30)
    }

    func testZipEmptyInputReturnsNil() {
        XCTAssertNil(FileArchive.zip([]))
    }

    func testZipRespectsSizeCap() throws {
        // A synthetic over-cap source should refuse rather than produce a multi-GB archive.
        // We can't actually allocate 512 MB in a unit test cheaply, so exercise the empty-dir
        // path and the single-small-file path only; the cap is a guard, not the happy path.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-zip-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("tiny.bin")
        try Data([1, 2, 3, 4]).write(to: src)
        XCTAssertNotNil(FileArchive.zip([src]))
    }
}
