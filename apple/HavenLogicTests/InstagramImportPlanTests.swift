import XCTest

/// Instagram import plumbing: item selection + order, the resume checkpoint, the "already published"
/// ledger, identities, the song policy and the per-item timeout. The ledger and checkpoint are what
/// keep a re-run from duplicating a feed and an interrupted run from starting over.
final class InstagramImportPlanTests: XCTestCase {
    private typealias P = InstagramImportPlan
    private typealias Item = InstagramArchive.Item

    private func item(_ kind: Item.Kind, at: UInt64, media: [String] = ["m.jpg"], body: String = "") -> Item {
        Item(kind: kind, createdAt: at, body: body, mediaNames: media, musicGenre: nil)
    }

    // MARK: Selection + order

    func testStoriesAreExcludedUnlessAsked() {
        let items = [item(.post, at: 1), item(.story, at: 2), item(.reel, at: 3)]
        XCTAssertEqual(P.selectable(items, includeStories: false).map(\.createdAt), [1, 3])
        XCTAssertEqual(P.selectable(items, includeStories: true).map(\.createdAt), [1, 2, 3])
    }

    func testImportOrderIsNewestFirstSoTheFeedGrowsDownward() {
        let items = [item(.post, at: 10), item(.reel, at: 20), item(.story, at: 30), item(.post, at: 40)]
        XCTAssertEqual(P.importOrder(items, includeStories: false).map(\.createdAt), [40, 20, 10])
        XCTAssertEqual(P.importOrder(items, includeStories: true).map(\.createdAt), [40, 30, 20, 10])
        XCTAssertTrue(P.importOrder([], includeStories: true).isEmpty)
    }

    // MARK: Song policy

    func testSongPlanTable() {
        // Audible posts: a credit (or nothing) — a guess is NEVER layered over a baked-in soundtrack.
        XCTAssertEqual(P.songPlan(hasAudio: true, identifySongs: true, matchSongs: true), .credit)
        XCTAssertEqual(P.songPlan(hasAudio: true, identifySongs: true, matchSongs: false), .credit)
        XCTAssertEqual(P.songPlan(hasAudio: true, identifySongs: false, matchSongs: true), .none)
        XCTAssertEqual(P.songPlan(hasAudio: true, identifySongs: false, matchSongs: false), .none)
        // Silent posts: a suggestion only when the user opted in.
        XCTAssertEqual(P.songPlan(hasAudio: false, identifySongs: true, matchSongs: true), .suggest)
        XCTAssertEqual(P.songPlan(hasAudio: false, identifySongs: false, matchSongs: true), .suggest)
        XCTAssertEqual(P.songPlan(hasAudio: false, identifySongs: true, matchSongs: false), .none)
        XCTAssertEqual(P.songPlan(hasAudio: false, identifySongs: false, matchSongs: false), .none)
    }

    // MARK: Identities

    func testImportIdentityIsFirstMediaPlusTime() {
        XCTAssertEqual(P.importIdentity(item(.post, at: 1_700_000_000_000, media: ["media/posts/a.jpg", "media/posts/b.jpg"])),
                       "ig:media/posts/a.jpg:1700000000000")
        XCTAssertEqual(P.importIdentity(item(.post, at: 5, media: [])), "ig:-:5", "a text-only post is disambiguated by time")
    }

    func testKeptIdentityKeepsItsExistingShape() {
        XCTAssertEqual(P.keptIdentity(item(.story, at: 9, media: ["s/1.mp4"])), "ig:s/1.mp4",
                       "changing this would keep every already-kept story a second time")
        XCTAssertEqual(P.keptIdentity(item(.story, at: 9, media: [])), "ig:9")
    }

    func testTwoDifferentPostsDoNotCollide() {
        XCTAssertNotEqual(P.importIdentity(item(.post, at: 1, media: ["a.jpg"])), P.importIdentity(item(.post, at: 1, media: ["b.jpg"])))
        XCTAssertNotEqual(P.importIdentity(item(.post, at: 1, media: ["a.jpg"])), P.importIdentity(item(.post, at: 2, media: ["a.jpg"])))
    }

    // MARK: Files

    func testFileExtensionAndVideoDetection() {
        XCTAssertEqual(P.fileExtension("media/reels/clip.MOV"), "mov")
        XCTAssertEqual(P.fileExtension("noext"), "mp4", "unknown containers default to mp4 for the scratch file")
        XCTAssertTrue(P.isVideo("a/b.mp4"))
        XCTAssertTrue(P.isVideo("a/b.MOV"))
        XCTAssertTrue(P.isVideo("a/b.m4v"))
        XCTAssertFalse(P.isVideo("a/b.jpg"))
        XCTAssertFalse(P.isVideo("a/b.heic"))
        XCTAssertFalse(P.isVideo("a/b.webm"))
        XCTAssertTrue(P.isVideo("noext"), "an extensionless entry is staged as mp4, so it is treated as video")
    }

    // MARK: Timeout

    func testWithTimeoutReturnsWorkResultWhenFast() async {
        let r = await P.withTimeout(5) { 42 }
        XCTAssertEqual(r, 42)
    }

    func testWithTimeoutGivesUpOnHungWork() async {
        let began = Date()
        let r: Int? = await P.withTimeout(0.05) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return 1
        }
        XCTAssertNil(r, "a hung video must not wedge the loop")
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testWithTimeoutPropagatesNilFromWork() async {
        let r: Int? = await P.withTimeout(5) { nil }
        XCTAssertNil(r)
    }

    func testVideoStageTimeoutIsGenerousButBounded() {
        XCTAssertGreaterThanOrEqual(P.videoStageTimeout, 60)
        XCTAssertLessThanOrEqual(P.videoStageTimeout, 600)
    }

    // MARK: Checkpoint

    private func freshDefaults() -> UserDefaults {
        let name = "haven.test.igcheckpoint.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testCheckpointRoundTrip() {
        let d = freshDefaults()
        XCTAssertNil(InstagramImportCheckpoint.load(from: d))
        let cp = InstagramImportCheckpoint(bookmark: Data([1, 2, 3]), circleId: "default", includeStories: true,
                                           matchSongs: true, identifySongs: false, done: 17)
        cp.save(to: d)
        XCTAssertEqual(InstagramImportCheckpoint.load(from: d), cp)
        InstagramImportCheckpoint.clear(from: d)
        XCTAssertNil(InstagramImportCheckpoint.load(from: d))
    }

    func testCheckpointDefaults() {
        let cp = InstagramImportCheckpoint(bookmark: Data(), circleId: "c", includeStories: false, done: 0)
        XCTAssertFalse(cp.matchSongs, "suggesting songs is opt-in")
        XCTAssertTrue(cp.identifySongs, "naming a reel's real song is on by default")
    }

    func testCorruptCheckpointLoadsAsNil() {
        let d = freshDefaults()
        d.set(Data("garbage".utf8), forKey: InstagramImportCheckpoint.defaultsKey)
        XCTAssertNil(InstagramImportCheckpoint.load(from: d))
    }

    // MARK: Ledger

    private func ledger() -> (InstagramImportLedger, SpilledDefaults) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("igledger-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sd = SpilledDefaults(directory: dir, legacy: nil, writeDelay: 3600)
        return (InstagramImportLedger(defaults: sd), sd)
    }

    func testLedgerRecordsAndRemembers() {
        let (l, _) = ledger()
        XCTAssertFalse(l.contains("ig:a:1"))
        l.record("ig:a:1")
        XCTAssertTrue(l.contains("ig:a:1"))
        l.record("ig:a:1")   // idempotent
        XCTAssertEqual(l.alreadyImported(["ig:a:1", "ig:b:2", "ig:a:1"]), 2, "counts every id that is present, per occurrence")
    }

    func testLedgerPersistsAcrossInstances() {
        let (l, sd) = ledger()
        l.record("ig:x:9")
        let again = InstagramImportLedger(defaults: sd)
        XCTAssertTrue(again.contains("ig:x:9"), "a re-run on the same device skips what it already published")
    }

    func testLedgerForgetAllowsReimport() {
        let (l, sd) = ledger()
        l.record("ig:a:1"); l.record("ig:b:2")
        l.forget(["ig:a:1", "ig:never-there"])
        XCTAssertFalse(l.contains("ig:a:1"))
        XCTAssertTrue(l.contains("ig:b:2"))
        XCTAssertFalse(InstagramImportLedger(defaults: sd).contains("ig:a:1"), "the forget is persisted")
    }

    func testLedgerIsThreadSafe() {
        let (l, _) = ledger()
        DispatchQueue.concurrentPerform(iterations: 200) { i in l.record("ig:\(i % 50):1") }
        XCTAssertEqual(l.alreadyImported((0..<50).map { "ig:\($0):1" }), 50)
    }
}
