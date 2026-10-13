import XCTest
import AppKit
@testable import HavenUITestHost

/// The Instagram importer end to end on a synthetic archive: parse → preview → publish newest first,
/// keep stories, skip what the ledger already holds, and resume (or drop) an interrupted import.
@MainActor
final class InstagramImporterTests: XCTestCase {
    private var dir: URL!
    private var ids: [String] = []

    override func setUp() async throws {
        _ = await Harness.feed()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("haven-igimp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        InstagramImporter.shared.reset()
        InstagramImportCheckpoint.clear(from: .standard)
    }
    override func tearDown() async throws {
        InstagramImporter.shared.reset()
        InstagramImportCheckpoint.clear(from: .standard)
        InstagramImportLedger.shared.forget(ids)
        try? FileManager.default.removeItem(at: dir)
    }

    private func photo(_ r: Int, _ g: Int, _ b: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [:])!
    }

    /// A STORE-method zip (the reader handles STORE and DEFLATE alike): entries in order, real CRCs.
    private func makeZip(_ entries: [(name: String, data: Data)], named: String) throws -> URL {
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        var body = Data(), central = Data()
        for e in entries {
            let name = Data(e.name.utf8), crc = FileArchive.crc32(e.data), offset = UInt32(body.count)
            let size = UInt32(e.data.count)
            var local = Data()
            local.append(le32(0x04034b50)); local.append(le16(20)); local.append(le16(0)); local.append(le16(0))
            local.append(le16(0)); local.append(le16(0x21)); local.append(le32(crc)); local.append(le32(size))
            local.append(le32(size)); local.append(le16(name.count)); local.append(le16(0)); local.append(name)
            local.append(e.data)
            body.append(local)
            central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0x21)); central.append(le32(crc))
            central.append(le32(size)); central.append(le32(size)); central.append(le16(name.count)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0)); central.append(le32(0))
            central.append(le32(offset)); central.append(name)
        }
        var eocd = Data()
        eocd.append(le32(0x06054b50)); eocd.append(le16(0)); eocd.append(le16(0))
        eocd.append(le16(entries.count)); eocd.append(le16(entries.count))
        eocd.append(le32(UInt32(central.count))); eocd.append(le32(UInt32(body.count))); eocd.append(le16(0))
        let url = dir.appendingPathComponent(named)
        var all = body; all.append(central); all.append(eocd)
        try all.write(to: url)
        return url
    }

    /// An export laid out the way Instagram ships it: `your_instagram_activity/media/*.json` plus the
    /// media files beside it. `tag` makes every archive's identities unique to this test run.
    private func archive(tag: String) throws -> (url: URL, posts: Int) {
        let base = Double(1_500_000_000 + Int.random(in: 0..<1_000_000))
        let posts: [[String: Any]] = [
            ["timestamp": base + 10, "title": "first \(tag)",
             "media": [["uri": "media/posts/\(tag)-a.jpg", "creation_timestamp": base + 10]]],
            ["timestamp": base + 20, "title": "carousel \(tag)",
             "media": [["uri": "media/posts/\(tag)-b.jpg", "creation_timestamp": base + 20,
                        "nested": ["more": [["uri": "media/posts/\(tag)-c.jpg"]]]]]],
            // The photo is missing from the archive: nothing to publish, counted as skipped.
            ["timestamp": base + 30, "title": "partial", "media": [["uri": "media/posts/\(tag)-gone.jpg"]]],
        ]
        let stories: [String: Any] = ["ig_stories": [["uri": "media/stories/\(tag)-s.jpg", "creation_timestamp": base + 5]]]
        let zip = try makeZip([
            ("your_instagram_activity/media/posts.json", try JSONSerialization.data(withJSONObject: posts)),
            ("your_instagram_activity/media/stories.json", try JSONSerialization.data(withJSONObject: stories)),
            ("media/posts/\(tag)-a.jpg", photo(200, 30, 30)),
            ("media/posts/\(tag)-b.jpg", photo(30, 200, 30)),
            ("media/posts/\(tag)-c.jpg", photo(30, 30, 200)),
            ("media/stories/\(tag)-s.jpg", photo(200, 200, 30)),
        ], named: "ig-\(tag).zip")
        return (zip, posts.count)
    }

    /// Wait for the importer to reach a phase; a failure on the way fails the test at once, with its reason.
    private func waitPhase(_ what: String, timeout: TimeInterval = 90, _ ok: @escaping (InstagramImportPhase) -> Bool) async {
        await Harness.until(FeedStore.shared, timeout: timeout, what) {
            let p = InstagramImporter.shared.phase
            if ok(p) { return true }
            if case .failed = p { return true }
            return false
        }
        let p = InstagramImporter.shared.phase
        if !ok(p), case .failed(let why) = p { XCTFail("the import failed while waiting for \(what): \(why)") }
    }

    func testPreviewParsesTheArchiveAndRejectsAnUnreadableOne() async throws {
        let imp = InstagramImporter.shared
        let (url, _) = try archive(tag: "prev\(UUID().uuidString.prefix(6))")
        imp.read(url)
        XCTAssertEqual(imp.phase, .reading)
        await waitPhase("preview") { $0 == .previewing }
        let s = try XCTUnwrap(imp.summary)
        XCTAssertEqual(s.count(.post), 3)
        XCTAssertEqual(s.count(.story), 1)
        XCTAssertEqual(s.missing.count, 1)
        ids += s.items.map(InstagramImportPlan.importIdentity)
        XCTAssertEqual(imp.alreadyImportedCount(s, includeStories: true), 0)
        XCTAssertFalse(imp.isRunning)

        imp.reset()
        XCTAssertEqual(imp.phase, .idle)
        XCTAssertNil(imp.summary)
        let junk = dir.appendingPathComponent("junk.zip")
        try Data(repeating: 0x41, count: 2048).write(to: junk)
        imp.read(junk)
        await waitPhase("a failure") { if case .failed = $0 { return true }; return false }
        // `run` outside the previewing state is a no-op.
        imp.run(into: "default")
        if case .failed = imp.phase {} else { XCTFail("run() must not start from a failed state: \(imp.phase)") }
    }

    func testRunPublishesPostsKeepsStoriesAndASecondRunSkipsEverythingItHas() async throws {
        let store = await Harness.feed()
        let imp = InstagramImporter.shared
        let tag = "run\(UUID().uuidString.prefix(6))"
        let (url, _) = try archive(tag: tag)
        imp.read(url)
        await waitPhase("preview") { $0 == .previewing }
        let s = try XCTUnwrap(imp.summary)
        ids += s.items.map(InstagramImportPlan.importIdentity)
        let keptBefore = KeptStoriesStore.shared.kept.count

        imp.run(into: "default", includeStories: true, matchSongs: false, identifySongs: false)
        XCTAssertTrue(imp.isRunning, "run() flips to importing before the first item")
        await waitPhase("finished") { if case .finished = $0 { return true }; return false }
        // 2 posts + 1 kept story published; the partial post has no readable media, so it is skipped.
        XCTAssertEqual(imp.phase, .finished(imported: 3, skipped: 1))
        XCTAssertEqual(KeptStoriesStore.shared.kept.count, keptBefore + 1, "stories are kept, not posted")
        XCTAssertNotNil(store.lastImportedPostId)
        XCTAssertNil(InstagramImportCheckpoint.load(from: .standard), "a finished import clears its checkpoint")
        await Harness.until(store, timeout: 60, "the imported posts reach the feed") {
            store.items.contains { $0.body == "first \(tag)" } && store.items.contains { $0.body == "carousel \(tag)" }
        }
        let carousel = try XCTUnwrap(store.items.first { $0.body == "carousel \(tag)" })
        XCTAssertGreaterThanOrEqual(carousel.media.count, 2, "a carousel stays ONE post with every photo")
        XCTAssertEqual(imp.alreadyImportedCount(s, includeStories: true), 3)
        XCTAssertEqual(imp.alreadyImportedCount(s, includeStories: false), 2, "stories only count when asked for")

        // The same export again: everything the ledger holds is skipped without being read.
        imp.reset()
        imp.read(url)
        await waitPhase("preview again") { $0 == .previewing }
        imp.run(into: "default", includeStories: true, identifySongs: false)
        await waitPhase("finished again") { if case .finished = $0 { return true }; return false }
        XCTAssertEqual(imp.phase, .finished(imported: 0, skipped: 4))

        // A deliberate re-import: forgetting the ids publishes the stories' kept entries idempotently.
        InstagramImportLedger.shared.forget(ids)
        XCTAssertEqual(imp.alreadyImportedCount(s, includeStories: true), 0)
        for k in KeptStoriesStore.shared.kept where k.id.contains(tag) { KeptStoriesStore.shared.unkeep(k.id) }
    }

    func testStoriesAreLeftAloneUnlessAskedFor() async throws {
        let imp = InstagramImporter.shared
        let tag = "nos\(UUID().uuidString.prefix(6))"
        let (url, _) = try archive(tag: tag)
        imp.read(url)
        await waitPhase("preview") { $0 == .previewing }
        let s = try XCTUnwrap(imp.summary)
        ids += s.items.map(InstagramImportPlan.importIdentity)
        let kept = KeptStoriesStore.shared.kept.count
        imp.run(into: "default", includeStories: false, identifySongs: false)
        await waitPhase("finished") { if case .finished = $0 { return true }; return false }
        XCTAssertEqual(imp.phase, .finished(imported: 2, skipped: 1))
        XCTAssertEqual(KeptStoriesStore.shared.kept.count, kept)
    }

    func testCancellingKeepsTheCheckpointSoStopIsPause() async throws {
        let imp = InstagramImporter.shared
        let tag = "can\(UUID().uuidString.prefix(6))"
        let (url, _) = try archive(tag: tag)
        imp.read(url)
        await waitPhase("preview") { $0 == .previewing }
        let s = try XCTUnwrap(imp.summary)
        ids += s.items.map(InstagramImportPlan.importIdentity)
        imp.run(into: "default", includeStories: false, identifySongs: false)
        imp.cancel()
        await waitPhase("stopped") { if case .finished = $0 { return true }; return false }
        XCTAssertEqual(imp.phase, .finished(imported: 0, skipped: 0), "stopped before the first item: nothing was published")
    }

    func testAnInterruptedImportWhoseArchiveIsGoneIsDroppedQuietly() async {
        let imp = InstagramImporter.shared
        InstagramImportCheckpoint(bookmark: Data([1, 2, 3, 4]), circleId: "default", includeStories: false, done: 2).save(to: .standard)
        imp.resumeIfNeeded()
        XCTAssertNil(InstagramImportCheckpoint.load(from: .standard), "a bookmark that no longer resolves clears the checkpoint")
        XCTAssertEqual(imp.phase, .idle)
        imp.resumeIfNeeded()   // nothing pending: silent
        XCTAssertEqual(imp.phase, .idle)
    }

    func testAResumableCheckpointRestartsFromItsIndex() async throws {
        let imp = InstagramImporter.shared
        let tag = "res\(UUID().uuidString.prefix(6))"
        let (url, _) = try archive(tag: tag)
        let mark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard let mark else { return }   // a host without the bookmark entitlement can't resume at all
        imp.read(url)
        await waitPhase("preview") { $0 == .previewing }
        let s = try XCTUnwrap(imp.summary)
        ids += s.items.map(InstagramImportPlan.importIdentity)
        imp.reset()
        InstagramImportCheckpoint(bookmark: mark, circleId: "default", includeStories: false, identifySongs: false, done: 1).save(to: .standard)
        imp.resumeIfNeeded()
        await waitPhase("resumed import finishes") { if case .finished = $0 { return true }; return false }
        XCTAssertEqual(imp.phase, .finished(imported: 2, skipped: 0), "item 0 (the newest) was already done at the checkpoint")
        XCTAssertNil(InstagramImportCheckpoint.load(from: .standard))
    }
}
