import XCTest

/// ZipReader on hand-assembled archives: the structural edge cases (ZIP64, trailing comment, bad
/// signatures, lying sizes, unsupported methods) that a real export rarely hits but an untrusted
/// archive can. /usr/bin/zip-built fixtures for the common path live in InstagramArchiveTests.
final class ZipReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ziprd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Minimal ZIP writer (STORE only; every field overridable to build malformed archives)

    struct E {
        var name: String
        var data: Data = Data()
        var method: UInt16 = 0
        var crc: UInt32?               // override the stored CRC
        var uncompressedSize: UInt64?  // override the declared size
        var zip64Extra = false         // saturate the central sizes/offset and carry them in an extra field
        var localSignature: UInt32 = 0x04034b50
        var localExtra = Data()
    }

    private func le<T: FixedWidthInteger>(_ v: T) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private func cat(_ parts: Data...) -> Data { parts.reduce(Data()) { $0 + $1 } }

    private func build(_ entries: [E], comment: Data = Data(), zip64Eocd: Bool = false, dropZip64Locator: Bool = false) -> Data {
        var out = Data()
        var offsets: [UInt64] = []
        for e in entries {
            offsets.append(UInt64(out.count))
            let name = Data(e.name.utf8)
            out += cat(le(e.localSignature), le(UInt16(20)), le(UInt16(0)), le(e.method), le(UInt16(0)), le(UInt16(0)))
            out += cat(le(e.crc ?? FileArchive.crc32(e.data)), le(UInt32(e.data.count)), le(UInt32(e.data.count)))
            out += cat(le(UInt16(name.count)), le(UInt16(e.localExtra.count)), name, e.localExtra, e.data)
        }
        let cdOffset = UInt64(out.count)
        for (i, e) in entries.enumerated() {
            let name = Data(e.name.utf8)
            let declared = e.uncompressedSize ?? UInt64(e.data.count)
            var extra = Data()
            var comp = UInt32(e.data.count)
            var uncomp = UInt32(truncatingIfNeeded: declared)
            var local = UInt32(offsets[i])
            if e.zip64Extra {
                comp = 0xFFFF_FFFF; uncomp = 0xFFFF_FFFF; local = 0xFFFF_FFFF
                extra = cat(le(UInt16(1)), le(UInt16(24)), le(declared), le(UInt64(e.data.count)), le(offsets[i]))
            }
            out += cat(le(UInt32(0x02014b50)), le(UInt16(20)), le(UInt16(20)), le(UInt16(0)), le(e.method))
            out += cat(le(UInt16(0)), le(UInt16(0)), le(e.crc ?? FileArchive.crc32(e.data)), le(comp), le(uncomp))
            out += cat(le(UInt16(name.count)), le(UInt16(extra.count)), le(UInt16(0)), le(UInt16(0)), le(UInt16(0)))
            out += cat(le(UInt32(0)), le(local), name, extra)
        }
        let cdSize = UInt64(out.count) - cdOffset
        if zip64Eocd {
            let z64At = UInt64(out.count)
            out += cat(le(UInt32(0x06064b50)), le(UInt64(44)), le(UInt16(45)), le(UInt16(45)), le(UInt32(0)), le(UInt32(0)))
            out += cat(le(UInt64(entries.count)), le(UInt64(entries.count)), le(cdSize), le(cdOffset))
            if dropZip64Locator {
                out += Data(count: 20)
            } else {
                out += cat(le(UInt32(0x07064b50)), le(UInt32(0)), le(z64At), le(UInt32(1)))
            }
        }
        let count16 = zip64Eocd ? UInt16(0xFFFF) : UInt16(entries.count)
        let offset32 = zip64Eocd ? UInt32(0xFFFF_FFFF) : UInt32(cdOffset)
        out += cat(le(UInt32(0x06054b50)), le(UInt16(0)), le(UInt16(0)), le(count16), le(count16))
        out += cat(le(UInt32(cdSize)), le(offset32), le(UInt16(comment.count)), comment)
        return out
    }

    private func open(_ bytes: Data, name: String = "t.zip") throws -> ZipReader? {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return ZipReader(url: url)
    }

    // MARK: Happy path

    func testStoredEntriesRoundTrip() throws {
        let a = Data("alpha".utf8), b = Data((0..<500).map { UInt8($0 % 251) })
        let zip = try XCTUnwrap(open(build([E(name: "a.txt", data: a), E(name: "dir/b.bin", data: b)])))
        defer { zip.close() }
        XCTAssertEqual(zip.entries.map(\.name), ["a.txt", "dir/b.bin"])
        XCTAssertEqual(zip.data(named: "a.txt"), a)
        XCTAssertEqual(zip.data(named: "dir/b.bin"), b)
        XCTAssertNil(zip.data(named: "missing"))
        XCTAssertEqual(zip.entry(named: "a.txt")?.method, 0)
        XCTAssertEqual(zip.entry(named: "dir/b.bin")?.uncompressedSize, 500)
    }

    func testEmptyArchiveAndEmptyEntry() throws {
        let none = try XCTUnwrap(open(build([])))
        XCTAssertTrue(none.entries.isEmpty)
        none.close()
        let one = try XCTUnwrap(open(build([E(name: "empty.txt", data: Data())]), name: "e.zip"))
        defer { one.close() }
        XCTAssertEqual(one.data(named: "empty.txt"), Data())
    }

    func testDirectoryEntriesAreFlaggedAndHaveNoData() throws {
        let zip = try XCTUnwrap(open(build([E(name: "photos/"), E(name: "photos/a.jpg", data: Data([1, 2, 3]))])))
        defer { zip.close() }
        XCTAssertTrue(try XCTUnwrap(zip.entry(named: "photos/")).isDirectory)
        XCTAssertFalse(try XCTUnwrap(zip.entry(named: "photos/a.jpg")).isDirectory)
        XCTAssertNil(zip.data(named: "photos/"))
    }

    func testFirstEntryWinsOnDuplicateNames() throws {
        let zip = try XCTUnwrap(open(build([E(name: "d", data: Data([1])), E(name: "d", data: Data([2]))])))
        defer { zip.close() }
        XCTAssertEqual(zip.data(named: "d"), Data([1]))
    }

    func testLocalExtraFieldDoesNotShiftThePayload() throws {
        // The payload offset must come from the LOCAL header's own lengths, not the central directory's.
        let zip = try XCTUnwrap(open(build([E(name: "x", data: Data("payload".utf8), localExtra: Data(repeating: 0xEE, count: 24))])))
        defer { zip.close() }
        XCTAssertEqual(zip.data(named: "x"), Data("payload".utf8))
    }

    func testTrailingCommentIsScannedPast() throws {
        let zip = try XCTUnwrap(open(build([E(name: "c.txt", data: Data("hi".utf8))], comment: Data(repeating: 0x41, count: 3000))))
        defer { zip.close() }
        XCTAssertEqual(zip.data(named: "c.txt"), Data("hi".utf8))
    }

    func testExtractWritesTheFileAndCreatesParents() throws {
        let zip = try XCTUnwrap(open(build([E(name: "a.bin", data: Data([9, 9, 9]))])))
        defer { zip.close() }
        let e = try XCTUnwrap(zip.entry(named: "a.bin"))
        let dst = dir.appendingPathComponent("deep/er/out.bin")
        XCTAssertTrue(zip.extract(e, to: dst))
        XCTAssertEqual(try Data(contentsOf: dst), Data([9, 9, 9]))
    }

    func testExtractFailsWhenTheDestinationCannotBeWritten() throws {
        let zip = try XCTUnwrap(open(build([E(name: "a.bin", data: Data([1]))])))
        defer { zip.close() }
        let e = try XCTUnwrap(zip.entry(named: "a.bin"))
        let blocker = dir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        XCTAssertFalse(zip.extract(e, to: blocker.appendingPathComponent("child/out.bin")), "a file where a directory is needed")
        XCTAssertFalse(zip.extract(ZipReader.Entry(name: "ghost", compressedSize: 1, uncompressedSize: 1, method: 0, crc32: 0, localHeaderOffset: 0),
                                   to: dir.appendingPathComponent("ghost.bin")), "an entry that does not read back")
    }

    // MARK: Refusals

    func testNotAZipIsRefused() throws {
        XCTAssertNil(try open(Data("this is plainly not a zip archive at all".utf8)))
        XCTAssertNil(try open(Data(repeating: 0, count: 10)), "shorter than an end-of-central-directory record")
        XCTAssertNil(try open(Data(), name: "empty.zip"))
        XCTAssertNil(ZipReader(url: dir.appendingPathComponent("does-not-exist.zip")))
    }

    func testTruncatedCentralDirectoryIsRefused() throws {
        var bytes = build([E(name: "a.txt", data: Data("hello".utf8))])
        // Point the EOCD's central-directory offset past the end of the file.
        let eocd = bytes.count - 22
        bytes.replaceSubrange((eocd + 16)..<(eocd + 20), with: le(UInt32(bytes.count + 1000)))
        let zip = try open(bytes)
        defer { zip?.close() }
        XCTAssertTrue(zip?.entries.isEmpty ?? true, "a central directory that lies outside the file yields no entries")
    }

    func testCRCMismatchIsRefused() throws {
        let zip = try XCTUnwrap(open(build([E(name: "bad.txt", data: Data("hello".utf8), crc: 0xDEADBEEF)])))
        defer { zip.close() }
        XCTAssertNil(zip.data(named: "bad.txt"), "a truncated download must not be half-imported")
    }

    func testDeclaredSizeMismatchIsRefused() throws {
        let zip = try XCTUnwrap(open(build([E(name: "lie.txt", data: Data("hello".utf8), uncompressedSize: 9)])))
        defer { zip.close() }
        XCTAssertNil(zip.data(named: "lie.txt"))
    }

    func testOversizedEntryIsRefusedBeforeReading() throws {
        let zip = try XCTUnwrap(open(build([E(name: "bomb", data: Data([1]), uncompressedSize: ZipReader.maxEntryBytes + 1)])))
        defer { zip.close() }
        XCTAssertNil(zip.data(named: "bomb"))
    }

    func testUnsupportedMethodIsRefused() throws {
        let zip = try XCTUnwrap(open(build([E(name: "bz.bin", data: Data([1, 2, 3]), method: 12)])))
        defer { zip.close() }
        XCTAssertNil(zip.data(named: "bz.bin"), "we never write anything but STORE/DEFLATE")
    }

    func testBadLocalHeaderSignatureIsRefused() throws {
        let zip = try XCTUnwrap(open(build([E(name: "x", data: Data("hi".utf8), localSignature: 0x12345678)])))
        defer { zip.close() }
        XCTAssertNil(zip.data(named: "x"))
    }

    func testCorruptDeflateStreamIsRefused() throws {
        // Method 8 with bytes that are not a deflate stream.
        let zip = try XCTUnwrap(open(build([E(name: "d", data: Data(repeating: 0xFF, count: 40), method: 8, uncompressedSize: 100)])))
        defer { zip.close() }
        XCTAssertNil(zip.data(named: "d"))
    }

    // MARK: ZIP64

    func testZip64EndOfCentralDirectory() throws {
        let a = Data("zip64-a".utf8)
        let zip = try XCTUnwrap(open(build([E(name: "a", data: a), E(name: "b", data: Data("b".utf8))], zip64Eocd: true)))
        defer { zip.close() }
        XCTAssertEqual(zip.entries.map(\.name), ["a", "b"])
        XCTAssertEqual(zip.data(named: "a"), a)
    }

    func testZip64EntryExtraField() throws {
        let body = Data("sizes live in the extra field".utf8)
        let zip = try XCTUnwrap(open(build([E(name: "pad", data: Data(repeating: 1, count: 70)),
                                            E(name: "big", data: body, zip64Extra: true)])))
        defer { zip.close() }
        let e = try XCTUnwrap(zip.entry(named: "big"))
        XCTAssertEqual(e.uncompressedSize, UInt64(body.count))
        XCTAssertEqual(e.compressedSize, UInt64(body.count))
        XCTAssertGreaterThan(e.localHeaderOffset, 0)
        XCTAssertEqual(zip.data(for: e), body)
    }

    func testZip64WithoutALocatorIsRefused() throws {
        // The 32-bit fields saturate but nothing says where the real values are: refuse, don't guess.
        let zip = try open(build([E(name: "a", data: Data("x".utf8))], zip64Eocd: true, dropZip64Locator: true))
        defer { zip?.close() }
        XCTAssertTrue(zip?.entries.isEmpty ?? true)
    }
}
