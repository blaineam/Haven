import XCTest

/// The persistence behind the 2026-10-02 heat report: a 21.6 MB seen-set rewritten whole on every
/// mailbox burst, a 55 MB engine state re-exported every few seconds during a drain, a 1.1 MB
/// preferences plist rewritten on every relay op, and 49.5 GB of never-deleted tmp files.
final class HeatPersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("heat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    // MARK: - SeenJournal (append-only seen-set)

    func testNewMarksAreAppendedNotRewritten() throws {
        let url = dir.appendingPathComponent("seen.txt")
        let big = (0..<5000).map { "haven/mailbox/c/\(String(repeating: "a", count: 40))\($0)" }
        try big.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)   // old format: no trailing \n
        let j = SeenJournal(url: url)
        var set = j.load()
        XCTAssertEqual(set.count, 5000)
        let before = size(url)

        set.insert("new-1"); j.noteInserted("new-1")
        set.insert("new-2"); j.noteInserted("new-2")
        let w = j.takeWrite(current: set)
        XCTAssertEqual(w, .append(["new-1", "new-2"]), "a mark is an append, never the whole set")
        XCTAssertTrue(SeenJournal.perform(w!, at: url))
        XCTAssertEqual(size(url), before + "\nnew-1\nnew-2".utf8.count, "only the new lines hit the disk")

        // The first appended key must not fuse with the old file's unterminated last line.
        let reloaded = SeenJournal(url: url).load()
        XCTAssertEqual(reloaded, set)
        XCTAssertNil(j.takeWrite(current: set), "nothing pending after a save")
    }

    func testRemovalRewritesExactlyTheSet() throws {
        let url = dir.appendingPathComponent("seen.txt")
        let j = SeenJournal(url: url)
        var set = j.load()
        for k in ["a/1", "a/2", "b/1"] { set.insert(k); j.noteInserted(k) }
        SeenJournal.perform(j.takeWrite(current: set)!, at: url)

        set = set.filter { !$0.hasPrefix("a/") }
        j.noteRemoved()
        set.insert("c/1"); j.noteInserted("c/1")   // folded into the rewrite
        guard case .rewrite(let keys)? = j.takeWrite(current: set) else { return XCTFail("removal needs a rewrite") }
        XCTAssertEqual(Set(keys), ["b/1", "c/1"])
        SeenJournal.perform(.rewrite(keys), at: url)
        XCTAssertEqual(SeenJournal(url: url).load(), ["b/1", "c/1"])
    }

    func testDuplicateHeavyJournalIsCompactedOnce() throws {
        let url = dir.appendingPathComponent("seen.txt")
        let lines = Array(repeating: ["k1", "k2", "k3"], count: 1000).flatMap { $0 }   // 3000 lines, 3 keys
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let j = SeenJournal(url: url)
        let set = j.load()
        XCTAssertEqual(set, ["k1", "k2", "k3"])
        guard case .rewrite? = j.takeWrite(current: set) else { return XCTFail("expected a compaction") }
        XCTAssertFalse(SeenJournal.wantsCompaction(lines: 1000, distinct: 1000))
        XCTAssertFalse(SeenJournal.wantsCompaction(lines: 1500, distinct: 1000), "small slack is not worth a rewrite")
        XCTAssertTrue(SeenJournal.wantsCompaction(lines: 200_000, distinct: 140_000))
    }

    func testFailedAppendFallsBackToRewrite() {
        let missingDir = dir.appendingPathComponent("nope/seen.txt")
        let j = SeenJournal(url: missingDir)
        var set = Set<String>()
        set.insert("x"); j.noteInserted("x")
        let w = j.takeWrite(current: set)!
        XCTAssertFalse(SeenJournal.perform(w, at: missingDir))
        j.requeue(w)
        guard case .rewrite(let keys)? = j.takeWrite(current: set) else { return XCTFail("expected rewrite") }
        XCTAssertEqual(keys, ["x"])
    }

    func testAppendCreatesMissingFile() {
        let url = dir.appendingPathComponent("fresh.txt")
        XCTAssertTrue(SeenJournal.perform(.append(["one", "two"]), at: url))
        XCTAssertEqual(SeenJournal(url: url).load(), ["one", "two"])
    }

    // MARK: - PersistCadence (engine export spacing)

    func testSmallStateKeepsTheClassicDebounce() {
        XCTAssertEqual(PersistCadence.delay(lastBytes: 200_000, lastDuration: 0.05, sinceLastEnd: 0),
                       PersistCadence.baseDelay)
        XCTAssertEqual(PersistCadence.delay(lastBytes: 3_000_000, lastDuration: 1.5, sinceLastEnd: 0),
                       PersistCadence.baseDelay, "below the size floor timing noise never stretches it")
    }

    func testLargeStateIsSpacedByItsCost() {
        let mb55 = 55 * 1_048_576
        XCTAssertEqual(PersistCadence.minGap(lastBytes: mb55, lastDuration: 0.4), 27.5, accuracy: 0.01)
        XCTAssertEqual(PersistCadence.minGap(lastBytes: mb55, lastDuration: 1.8), 36, accuracy: 0.01,
                       "a slow export spaces the next by 20x its cost")
        XCTAssertEqual(PersistCadence.minGap(lastBytes: 500 * 1_048_576, lastDuration: 9), PersistCadence.maxGap)
        // Time already elapsed since the last export counts toward the gap…
        XCTAssertEqual(PersistCadence.delay(lastBytes: mb55, lastDuration: 0.4, sinceLastEnd: 20), 7.5, accuracy: 0.01)
        // …but never below the classic debounce.
        XCTAssertEqual(PersistCadence.delay(lastBytes: mb55, lastDuration: 0.4, sinceLastEnd: 600), PersistCadence.baseDelay)
    }

    // MARK: - TempSweep

    private func touch(_ name: String, bytes: Int = 16, in d: URL? = nil) -> URL {
        let u = (d ?? dir).appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: Data(count: bytes))
        return u
    }

    func testSweepReclaimsOnlyWhatIsOlderThanMaxAge() throws {
        let old1 = touch("4BCC7C19.mov", bytes: 1000)
        let sub = dir.appendingPathComponent("NSIRD_Haven_x", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = touch("haven-feed.json", bytes: 500, in: sub)
        let fresh = touch("story_live.mov")

        // "Now" a day and a bit after everything was written: all of it is stale…
        let later = Date().addingTimeInterval(TempSweep.maxAge + 120)
        let r = TempSweep.sweep(tempDir: dir, now: later, keep: [fresh.lastPathComponent])
        XCTAssertEqual(r.removed, 2)
        XCTAssertEqual(r.bytes, 1500, "directories count their contents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "kept names are spared")

        // …while at the real "now" nothing just written is touched.
        _ = touch("brand-new.mov")
        XCTAssertEqual(TempSweep.sweep(tempDir: dir).removed, 0)
    }

    func testPickerCopyWithAncientDatesIsNotSweptWhileFresh() throws {
        // A Photos copy keeps the ORIGINAL clip's dates; only "added to the directory" is new.
        let copy = touch("0126C20C.mov")
        let april = Date(timeIntervalSinceNow: -160 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: april, .creationDate: april], ofItemAtPath: copy.path)
        XCTAssertEqual(TempSweep.sweep(tempDir: dir).removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testDiscardOnlyTouchesTempFiles() {
        let inside = touch("picked.mov")
        TempSweep.discardIfTemp(inside, tempDir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))

        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("heat-tests-outside-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: elsewhere.path, contents: Data(count: 4))
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        TempSweep.discardIfTemp(elsewhere, tempDir: dir)   // not inside `dir`
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
        XCTAssertFalse(TempSweep.isInside(dir.appendingPathComponent("../x"), dir))
        XCTAssertFalse(TempSweep.isInside(URL(fileURLWithPath: dir.path + "-sibling/x"), dir))
    }

    // MARK: - SpilledDefaults (big maps out of the preferences plist)

    func testLegacyDefaultsValueMigratesToFileAndLeavesThePlist() throws {
        let suite = "heat-tests-\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { ud.removePersistentDomain(forName: suite) }
        ud.set(["img_a": 1.5, "img_b": 0.75], forKey: "haven.media.aspects.v2")

        let s = SpilledDefaults(directory: dir, legacy: ud, writeDelay: 0.01)
        let m = s.dictionary(forKey: "haven.media.aspects.v2") as? [String: Double]
        XCTAssertEqual(m, ["img_a": 1.5, "img_b": 0.75])
        XCTAssertNil(ud.object(forKey: "haven.media.aspects.v2"), "migrated out of UserDefaults")

        // A fresh instance (next launch) reads the file, not the defaults.
        let s2 = SpilledDefaults(directory: dir, legacy: ud)
        XCTAssertEqual(s2.dictionary(forKey: "haven.media.aspects.v2") as? [String: Double], m)
    }

    func testWritesAreCoalescedAndFlushable() throws {
        let s = SpilledDefaults(directory: dir, legacy: nil, writeDelay: 60)
        for i in 0..<100 { s.set(Array(0...i).map(String.init), forKey: "haven.media.pinned") }
        let file = dir.appendingPathComponent("haven.media.pinned.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing written mid-burst")
        XCTAssertEqual(s.stringArray(forKey: "haven.media.pinned")?.count, 100, "reads see the latest value")
        s.flush()
        XCTAssertEqual(SpilledDefaults(directory: dir, legacy: nil).stringArray(forKey: "haven.media.pinned")?.count, 100)

        let d = Data([1, 2, 3])
        s.set(d, forKey: "haven.media.reqBackoff.v1"); s.flush()
        XCTAssertEqual(SpilledDefaults(directory: dir, legacy: nil).data(forKey: "haven.media.reqBackoff.v1"), d)

        s.removeObject(forKey: "haven.media.reqBackoff.v1"); s.flush()
        XCTAssertNil(SpilledDefaults(directory: dir, legacy: nil).data(forKey: "haven.media.reqBackoff.v1"))
    }

    func testOverwriteBeforeReadDropsTheStaleDefaultsCopy() throws {
        let suite = "heat-tests-\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { ud.removePersistentDomain(forName: suite) }
        ud.set(["old"], forKey: "haven.media.wanted")
        let s = SpilledDefaults(directory: dir, legacy: ud, writeDelay: 60)
        s.set(["new"], forKey: "haven.media.wanted")
        XCTAssertNil(ud.object(forKey: "haven.media.wanted"))
        XCTAssertEqual(s.stringArray(forKey: "haven.media.wanted"), ["new"])
    }

    func testRemoveAllWipesMemoryAndDisk() {
        let s = SpilledDefaults(directory: dir.appendingPathComponent("prefs"), legacy: nil, writeDelay: 60)
        s.set(["x"], forKey: "haven.media.pinned"); s.flush()
        s.removeAll()
        XCTAssertNil(s.stringArray(forKey: "haven.media.pinned"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("prefs").path))
    }
}
