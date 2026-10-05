import XCTest

/// Instagram "Download your information" import, Apple side (Android has InstagramArchiveTest).
/// Fixture archives are built per test with /usr/bin/zip, so JSON entries are DEFLATE-compressed
/// exactly like a real export — exercising ZipReader's central-directory parse, local-header
/// offsets, inflate and CRC check, not just the JSON mapping.
final class InstagramArchiveTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("haven-ig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write `files` under a staging dir and zip them (deflate) into `name`.
    private func makeZip(_ files: [String: Data], name: String = "export.zip") throws -> URL {
        let stage = dir.appendingPathComponent("stage-\(UUID().uuidString)")
        for (path, data) in files {
            let u = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        let out = dir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = stage
        p.arguments = ["-q", "-r", "-X", out.path] + files.keys.sorted()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "zip failed")
        return out
    }

    private func json(_ obj: Any) throws -> Data { try JSONSerialization.data(withJSONObject: obj) }

    private let media = "your_instagram_activity/media/"

    private func standardExport() throws -> URL {
        let posts: [[String: Any]] = [
            // A 3-photo carousel: only the cover sits in the top-level media list; 2..N are nested.
            ["timestamp": 1_600_000_100.0,
             "title": "Pe\u{00C3}\u{00B1}a beach",   // "Peña" double-encoded the way Instagram does
             "media": [["uri": "media/posts/a1.jpg", "creation_timestamp": 1_600_000_100.0,
                        "nested": ["more": [["uri": "media/posts/a2.jpg"], ["uri": "media/posts/a3.jpg"],
                                            ["uri": "media/posts/a1.jpg"],          // duplicate → deduped
                                            ["uri": "media/posts/a1.srt"]]]]]],      // sidecar → ignored
            // A draft must never be republished.
            ["timestamp": 1_600_000_200.0, "media": [["uri": "media/posts/draft.jpg"]],
             "label_values": [["label": "Draft", "value": "true"]]],
            // Timestamp only on the media.
            ["media": [["uri": "media/posts/b.jpg", "creation_timestamp": 1_600_000_050.0, "title": "plain"]]],
            // Referenced but missing from the archive (partial download).
            ["timestamp": 1_600_000_300.0, "media": [["uri": "media/posts/gone.jpg"]]],
        ]
        let stories: [String: Any] = ["ig_stories": [
            ["uri": "media/stories/s.mp4", "creation_timestamp": 1_600_000_000.0, "title": "",
             "media_metadata": ["video_metadata": ["music_genre": "Pop"]]],
            ["uri": "media/stories/bad.mp4", "creation_timestamp": 0.0],   // no time → dropped
        ]]
        let reels: [String: Any] = ["ig_reels_media": [
            ["media": [["uri": "media/reels/r.mp4", "creation_timestamp": 1_600_000_400.0, "title": "reel!"]]],
        ]]
        return try makeZip([
            "\(media)posts.json": try json(posts),
            "\(media)stories.json": try json(stories),
            "\(media)reels.json": try json(reels),
            "media/posts/a1.jpg": Data(repeating: 1, count: 1000),
            "media/posts/a2.jpg": Data(repeating: 2, count: 2000),
            "media/posts/a3.jpg": Data(repeating: 3, count: 3000),
            "media/posts/b.jpg": Data(repeating: 4, count: 10),
            "media/stories/s.mp4": Data(repeating: 5, count: 50),
            "media/reels/r.mp4": Data(repeating: 6, count: 60),
        ])
    }

    func testReadsPostsStoriesAndReelsInChronologicalOrder() throws {
        let s = try InstagramArchive.read(try standardExport())
        XCTAssertEqual(s.count(.post), 3, "draft skipped; carousel, media-timestamp post and missing-media post kept")
        XCTAssertEqual(s.count(.story), 1)
        XCTAssertEqual(s.count(.reel), 1)
        XCTAssertEqual(s.items.map(\.createdAt), s.items.map(\.createdAt).sorted())
        XCTAssertEqual(s.earliest, 1_600_000_000_000, "seconds are converted to milliseconds")
        XCTAssertEqual(s.latest, 1_600_000_400_000)
        XCTAssertFalse(s.items.contains { $0.mediaNames.contains("media/posts/draft.jpg") })
    }

    func testCarouselKeepsEveryNestedPhotoInOrderWithoutSidecarsOrDuplicates() throws {
        let s = try InstagramArchive.read(try standardExport())
        let carousel = try XCTUnwrap(s.items.first { $0.mediaNames.first == "media/posts/a1.jpg" })
        XCTAssertEqual(carousel.mediaNames, ["media/posts/a1.jpg", "media/posts/a2.jpg", "media/posts/a3.jpg"])
        XCTAssertEqual(carousel.body, "Peña beach", "double-encoded latin-1 captions are repaired")
    }

    func testMissingMediaAndSizesAreReportedUpFront() throws {
        let s = try InstagramArchive.read(try standardExport())
        XCTAssertEqual(s.missing, ["media/posts/gone.jpg"])
        XCTAssertEqual(s.mediaCount, 7)
        XCTAssertEqual(s.totalBytes, 1000 + 2000 + 3000 + 10 + 50 + 60)
        XCTAssertEqual(s.items.first { $0.kind == .story }?.musicGenre, "Pop")
    }

    func testOrderIsDeterministicAcrossReads() throws {
        let url = try standardExport()
        let a = try InstagramArchive.read(url).items.map { $0.mediaNames.first ?? "" }
        let b = try InstagramArchive.read(url).items.map { $0.mediaNames.first ?? "" }
        XCTAssertEqual(a, b, "a resumed import skips by index, so the order must be stable")
    }

    func testHTMLExportIsRecognisedWithItsOwnError() throws {
        let url = try makeZip(["index.html": Data("<html/>".utf8), "your_instagram_activity/media/posts.html": Data("x".utf8)])
        XCTAssertThrowsError(try InstagramArchive.read(url)) { e in
            guard case InstagramArchive.Failure.htmlExport = e else { return XCTFail("got \(e)") }
        }
    }

    func testNonZipAndEmptyExportsAreRefused() throws {
        let notZip = dir.appendingPathComponent("photo.zip")
        try Data(repeating: 0x41, count: 4096).write(to: notZip)
        XCTAssertThrowsError(try InstagramArchive.read(notZip)) { e in
            guard case InstagramArchive.Failure.unreadable = e else { return XCTFail("got \(e)") }
        }
        let empty = try makeZip(["\(media)posts.json": try json([[String: Any]]())])
        XCTAssertThrowsError(try InstagramArchive.read(empty)) { e in
            guard case InstagramArchive.Failure.noContent = e else { return XCTFail("got \(e)") }
        }
    }

    func testDecodeLeavesCleanStringsAlone() {
        XCTAssertEqual(InstagramArchive.decode("hello"), "hello")
        XCTAssertEqual(InstagramArchive.decode("日本"), "日本")
        XCTAssertNil(InstagramArchive.decode(nil))
    }

    // MARK: ZipReader

    func testZipReaderInflatesAndExtracts() throws {
        let body = Data((0..<20_000).map { UInt8($0 % 7) })   // compressible → DEFLATE'd by zip
        let url = try makeZip(["a/b.bin": body, "c.txt": Data("hi".utf8)])
        let zip = try XCTUnwrap(ZipReader(url: url))
        defer { zip.close() }
        let e = try XCTUnwrap(zip.entry(named: "a/b.bin"))
        XCTAssertEqual(e.method, 8, "fixture must actually exercise DEFLATE")
        XCTAssertEqual(zip.data(for: e), body)
        XCTAssertEqual(zip.data(named: "c.txt"), Data("hi".utf8))
        XCTAssertNil(zip.data(named: "nope"))
        let dst = dir.appendingPathComponent("out.bin")
        XCTAssertTrue(zip.extract(e, to: dst))
        XCTAssertEqual(try Data(contentsOf: dst), body)
    }

    func testZipReaderRefusesACorruptedEntry() throws {
        let body = Data(repeating: 0x5A, count: 5000)
        let url = try makeZip(["x.bin": body])
        // Corrupt payload bytes in the middle of the file (inside the single entry's data).
        var raw = try Data(contentsOf: url)
        let zip0 = try XCTUnwrap(ZipReader(url: url))
        let entry = try XCTUnwrap(zip0.entry(named: "x.bin"))
        zip0.close()
        let payloadStart = Int(entry.localHeaderOffset) + 30 + "x.bin".utf8.count
        let mid = payloadStart + Int(entry.compressedSize) / 2
        raw[mid] ^= 0xFF
        try raw.write(to: url)
        let zip = try XCTUnwrap(ZipReader(url: url))
        defer { zip.close() }
        XCTAssertNil(zip.data(named: "x.bin"), "a corrupted entry must not be imported")
    }
}
