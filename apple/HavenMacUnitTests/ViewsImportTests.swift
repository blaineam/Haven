import XCTest
import SwiftUI
import AppKit
import zlib
@testable import HavenUITestHost

/// The Instagram import sheet driven through its real states by a real (tiny) export: the walkthrough,
/// the preview built from the archive, the progress/finished screens after `run`, a damaged archive,
/// and the posts that land in the feed backdated to when they were originally shared.
@MainActor
final class ViewsImportTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("views-ig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        ViewBench.reset()
        InstagramImporter.shared.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    /// A minimal ZIP (STORE method) so the fixture needs no external tool.
    private func makeZip(_ files: [(String, Data)], name: String = "export.zip") throws -> URL {
        var out = Data(), central = Data()
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        for (path, data) in files {
            let nameBytes = Data(path.utf8)
            let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
            let offset = UInt32(out.count)
            out += le(UInt32(0x04034b50)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0x21))
            out += le(crc) + le(UInt32(data.count)) + le(UInt32(data.count)) + le(UInt16(nameBytes.count)) + le(UInt16(0))
            out += nameBytes + data
            central += le(UInt32(0x02014b50)) + le(UInt16(20)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0x21))
            central += le(crc) + le(UInt32(data.count)) + le(UInt32(data.count)) + le(UInt16(nameBytes.count))
            central += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(offset) + nameBytes
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += le(UInt32(0x06054b50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(files.count)) + le(UInt16(files.count))
        out += le(UInt32(central.count)) + le(cdOffset) + le(UInt16(0))
        let url = dir.appendingPathComponent(name)
        try out.write(to: url)
        return url
    }

    private func json(_ obj: Any) throws -> Data { try JSONSerialization.data(withJSONObject: obj) }

    private func archive(titles: [(String, Double)]) throws -> URL {
        var files: [(String, Data)] = []
        var posts: [[String: Any]] = []
        for (i, t) in titles.enumerated() {
            let photo = ViewFixtures.jpeg("ig-\(UUID().uuidString)", side: 40).data
            files.append(("media/posts/p\(i).jpg", photo))
            posts.append(["timestamp": t.1, "title": t.0, "media": [["uri": "media/posts/p\(i).jpg", "creation_timestamp": t.1]]])
        }
        files.append(("your_instagram_activity/media/posts.json", try json(posts)))
        return try makeZip(files)
    }

    func testAnExportIsPreviewedImportedBackdatedAndReportedFinished() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let importer = InstagramImporter.shared
        importer.reset()
        let old = Date().timeIntervalSince1970 - 400 * 86_400
        let url = try archive(titles: [("Beach day \(UUID().uuidString.prefix(6))", old), ("Hike \(UUID().uuidString.prefix(6))", old + 86_400)])

        let sheet = InstagramImportView(circleId: "default", circleName: "Your circle")
        await ViewBench.renderDrawn(sheet, width: 520, height: 800)   // the walkthrough
        importer.read(url)
        XCTAssertEqual(importer.phase.isRunning, false)
        await Harness.until(store, "archive parsed") { if case .previewing = importer.phase { return true }; return false }
        let summary = try XCTUnwrap(importer.summary)
        XCTAssertEqual(summary.count(.post), 2)
        XCTAssertEqual(summary.mediaCount, 2)
        XCTAssertTrue(summary.missing.isEmpty)
        XCTAssertEqual(importer.alreadyImportedCount(summary, includeStories: false), 0)
        await ViewBench.renderDrawn(sheet, width: 520, height: 800)   // the preview

        importer.run(into: "default")
        await Harness.until(store, timeout: 60, "import finished") { if case .finished = importer.phase { return true }; return false }
        guard case .finished(let imported, let skipped) = importer.phase else { return XCTFail("expected finished") }
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(skipped, 0)
        await ViewBench.renderDrawn(sheet, width: 520, height: 800)   // the finished screen

        // Each post lands with its photo and its ORIGINAL date, not today's.
        await Harness.until(store, timeout: 30, "imported posts in the feed") {
            summary.items.allSatisfy { item in store.feedItems.contains { $0.body == item.body } }
        }
        for item in summary.items {
            let post = try XCTUnwrap(store.feedItems.first { $0.body == item.body })
            XCTAssertEqual(post.createdAt, item.createdAt, "backdated to when it was first shared")
            XCTAssertEqual(post.media.filter { $0.hasPrefix("img_") }.count, 1)
            XCTAssertTrue(post.isMe)
        }

        // Importing the SAME archive again is recognised, not duplicated.
        importer.reset()
        importer.read(url)
        await Harness.until(store, "archive parsed again") { if case .previewing = importer.phase { return true }; return false }
        XCTAssertEqual(importer.alreadyImportedCount(try XCTUnwrap(importer.summary), includeStories: false), 2)
        importer.run(into: "default")
        await Harness.until(store, timeout: 60, "second import finished") { if case .finished = importer.phase { return true }; return false }
        guard case .finished(let again, let skippedAgain) = importer.phase else { return XCTFail("expected finished") }
        XCTAssertEqual(again, 0, "nothing new to publish")
        XCTAssertEqual(skippedAgain, 2)
    }

    func testDamagedAndWrongKindsOfArchiveFailWithAnExplanation() async throws {
        let store = await Harness.feed()
        let importer = InstagramImporter.shared
        importer.reset()

        let junk = dir.appendingPathComponent("junk.zip")
        try Data("this is not a zip".utf8).write(to: junk)
        importer.read(junk)
        await Harness.until(store, "unreadable archive fails") { if case .failed = importer.phase { return true }; return false }
        guard case .failed(let why) = importer.phase else { return XCTFail("expected failed") }
        XCTAssertFalse(why.isEmpty)
        await ViewBench.renderDrawn(InstagramImportView(circleId: "default", circleName: "Your circle"), width: 520, height: 800)

        // An HTML export (the wrong format) is told apart from a broken file.
        importer.reset()
        let html = try makeZip([("your_instagram_activity/media/posts.html", Data("<html></html>".utf8))], name: "html.zip")
        importer.read(html)
        await Harness.until(store, "html export fails") { if case .failed = importer.phase { return true }; return false }
        guard case .failed(let htmlWhy) = importer.phase else { return XCTFail("expected failed") }
        XCTAssertNotEqual(htmlWhy, why, "the HTML export gets its own instruction")

        // A JSON export with nothing in it.
        importer.reset()
        let empty = try makeZip([("your_instagram_activity/media/posts.json", try json([[String: Any]]()))], name: "empty.zip")
        importer.read(empty)
        await Harness.until(store, "empty export fails") { if case .failed = importer.phase { return true }; return false }
        guard case .failed(let emptyWhy) = importer.phase else { return XCTFail("expected failed") }
        XCTAssertNotEqual(emptyWhy, why)
        XCTAssertNotEqual(emptyWhy, htmlWhy, "an empty export is explained differently again")

        importer.reset()
        if case .idle = importer.phase {} else { XCTFail("reset returns to the walkthrough") }
    }
}
