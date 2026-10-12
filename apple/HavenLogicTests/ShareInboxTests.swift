import XCTest

/// The Share Extension -> app hand-off queue and the destination mirror. Both normally live in the
/// App Group container; the tests point them at a temp directory through the `…Override` seams.
/// A mistake in the queue means a shared message that quietly never arrives, or arrives twice.
final class ShareInboxTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shareinbox-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ShareInbox.rootOverride = root
        SharedDestinations.containerOverride = root
    }

    override func tearDown() {
        ShareInbox.rootOverride = nil
        SharedDestinations.containerOverride = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func payload(_ text: String = "hi", route: ShareInbox.Route = .undecided) -> ShareInbox.Payload {
        var p = ShareInbox.Payload()
        p.items = [.init(kind: .text, text: text)]
        p.route = route
        return p
    }

    private func setCreated(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    }

    // MARK: Payload

    func testPayloadDefaultsAndCodableRoundTrip() throws {
        let fresh = ShareInbox.Payload()
        XCTAssertEqual(fresh.route, .undecided)
        XCTAssertTrue(fresh.items.isEmpty)
        var p = payload("link", route: .dm)
        p.targetCircleId = "dm:aa-bb"
        p.caption = "look"
        p.items.append(.init(kind: .file, file: "doc-0.pdf", name: "Report.pdf"))
        let back = try JSONDecoder().decode(ShareInbox.Payload.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.route, .dm)
        XCTAssertEqual(back.targetCircleId, "dm:aa-bb")
        XCTAssertEqual(back.caption, "look")
        XCTAssertEqual(back.items.count, 2)
        XCTAssertEqual(back.items[1].name, "Report.pdf")
        XCTAssertEqual(back.items[1].kind, .file)
    }

    // MARK: Extension side

    func testBeginCreatesDirectoryButShareIsInvisibleUntilCommitted() {
        let id = ShareInbox.begin()
        var isDir: ObjCBool = false
        let dir = root.appendingPathComponent("ShareInbox/\(id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(ShareInbox.drain().isEmpty, "a share still being composed is the extension's, not the app's")
    }

    func testFileURLLivesInsideTheShareDirectory() {
        let id = ShareInbox.begin()
        let u = ShareInbox.fileURL("img-0.dat", in: id)
        XCTAssertEqual(u?.path, root.appendingPathComponent("ShareInbox/\(id)/img-0.dat").path)
    }

    func testCommitMakesShareDrainable() {
        let id = ShareInbox.begin()
        ShareInbox.commit(payload("hello", route: .post), in: id)
        let q = ShareInbox.drain()
        XCTAssertEqual(q.map(\.id), [id])
        XCTAssertEqual(q.first?.payload.items.first?.text, "hello")
        XCTAssertEqual(q.first?.payload.route, .post)
    }

    func testCommitWithEmptyItemsIsNotDrained() {
        let id = ShareInbox.begin()
        ShareInbox.commit(ShareInbox.Payload(), in: id)
        XCTAssertTrue(ShareInbox.drain().isEmpty, "nothing to deliver is not a share")
    }

    func testCorruptManifestIsSkippedNotFatal() throws {
        let id = ShareInbox.begin()
        let manifest = try XCTUnwrap(ShareInbox.fileURL("payload.json", in: id))
        try Data("{broken".utf8).write(to: manifest)
        let good = ShareInbox.begin()
        ShareInbox.commit(payload("ok"), in: good)
        XCTAssertEqual(ShareInbox.drain().map(\.id), [good])
    }

    func testDiscardRemovesMediaAndManifest() throws {
        let id = ShareInbox.begin()
        try Data([1, 2, 3]).write(to: try XCTUnwrap(ShareInbox.fileURL("img-0.dat", in: id)))
        ShareInbox.commit(payload(), in: id)
        ShareInbox.discard(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ShareInbox/\(id)").path))
        XCTAssertTrue(ShareInbox.drain().isEmpty)
    }

    // MARK: App side

    func testDrainReplaysOldestFirst() throws {
        var ids: [String] = []
        for i in 0..<3 {
            let id = ShareInbox.begin()
            ids.append(id)
            ShareInbox.commit(payload("m\(i)"), in: id)
        }
        // Stamp creation dates explicitly: file times in one test run can tie.
        let base = Date(timeIntervalSinceNow: -1000)
        for (i, id) in ids.enumerated().reversed() {
            setCreated(try XCTUnwrap(ShareInbox.fileURL("payload.json", in: id)), base.addingTimeInterval(Double(i) * 10))
        }
        XCTAssertEqual(ShareInbox.drain().map(\.id), ids, "a burst is delivered in the order it was made")
        XCTAssertEqual(ShareInbox.drain().map { $0.payload.items[0].text }, ["m0", "m1", "m2"])
    }

    func testClearRemovesOneShareOnly() {
        let a = ShareInbox.begin(), b = ShareInbox.begin()
        ShareInbox.commit(payload("a"), in: a)
        ShareInbox.commit(payload("b"), in: b)
        ShareInbox.clear(a)
        XCTAssertEqual(ShareInbox.drain().map(\.id), [b])
    }

    func testClearAllWipesTheQueue() {
        ShareInbox.commit(payload(), in: ShareInbox.begin())
        ShareInbox.clearAll()
        XCTAssertTrue(ShareInbox.drain().isEmpty)
        // And the queue is usable again afterwards.
        ShareInbox.commit(payload("again"), in: ShareInbox.begin())
        XCTAssertEqual(ShareInbox.drain().count, 1)
    }

    func testSweepRemovesOnlyOldUncommittedDirectories() throws {
        let oldAbandoned = ShareInbox.begin()
        let youngInFlight = ShareInbox.begin()
        let committed = ShareInbox.begin()
        ShareInbox.commit(payload(), in: committed)
        let dirOf = { (id: String) in self.root.appendingPathComponent("ShareInbox/\(id)") }
        setCreated(dirOf(oldAbandoned), Date(timeIntervalSinceNow: -7200))
        setCreated(dirOf(committed), Date(timeIntervalSinceNow: -7200))
        ShareInbox.sweepAbandoned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirOf(oldAbandoned).path), "abandoned mid-extraction")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirOf(youngInFlight).path), "an extension may still be filling it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirOf(committed).path), "committed shares are never swept")
        ShareInbox.sweepAbandoned(olderThan: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirOf(youngInFlight).path))
        XCTAssertEqual(ShareInbox.drain().map(\.id), [committed])
    }

    // MARK: Destinations mirror

    private func item(_ id: String, _ name: String, at: UInt64, avatar: String = "") -> SharedDestinations.Item {
        .init(id: id, name: name, isDM: id.hasPrefix("dm:"), lastActivity: at, avatarFile: avatar, emoji: "")
    }

    func testDestinationsReadSortsMostRecentFirst() {
        SharedDestinations.write([item("dm:a", "A", at: 5), item("c1", "Circle", at: 50), item("dm:b", "B", at: 20)], avatars: [:])
        XCTAssertEqual(SharedDestinations.read().map(\.id), ["c1", "dm:b", "dm:a"])
        XCTAssertEqual(SharedDestinations.read().first?.isDM, false)
    }

    func testDestinationsEmptyWhenNothingWritten() {
        XCTAssertTrue(SharedDestinations.read().isEmpty)
        XCTAssertNil(SharedDestinations.avatarURL(""))
    }

    func testDestinationsSweepUnreferencedAvatars() throws {
        let keepName = SharedDestinations.avatarFileName(for: "dm:keep")
        let dropName = SharedDestinations.avatarFileName(for: "dm:drop")
        SharedDestinations.write([item("dm:keep", "K", at: 1, avatar: keepName), item("dm:drop", "D", at: 2, avatar: dropName)],
                                 avatars: [keepName: Data([1]), dropName: Data([2])])
        XCTAssertNotNil(SharedDestinations.avatarURL(keepName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(SharedDestinations.avatarURL(dropName)).path))
        // The contact is removed: its face must not linger in a container the extension can read.
        SharedDestinations.write([item("dm:keep", "K", at: 1, avatar: keepName)], avatars: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(SharedDestinations.avatarURL(keepName)).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(SharedDestinations.avatarURL(dropName)).path))
    }

    func testDestinationsClearWipesMirror() {
        SharedDestinations.write([item("c1", "C", at: 1)], avatars: ["av-1.jpg": Data([1])])
        SharedDestinations.clear()
        XCTAssertTrue(SharedDestinations.read().isEmpty)
    }

    func testAvatarFileNameIsStableAndCompact() {
        let long = "dm:" + String(repeating: "ab", count: 32) + "-" + String(repeating: "cd", count: 32)
        let n = SharedDestinations.avatarFileName(for: long)
        XCTAssertEqual(n, SharedDestinations.avatarFileName(for: long))
        XCTAssertTrue(n.hasPrefix("av-") && n.hasSuffix(".jpg"))
        XCTAssertLessThan(n.count, 30, "a 130-character dm id must not become a 130-character file name")
        XCTAssertNotEqual(n, SharedDestinations.avatarFileName(for: long + "x"))
        XCTAssertEqual(SharedDestinations.avatarFileName(for: ""), "av-1505.jpg", "djb2 of the empty string is 5381 = 0x1505")
    }
}
