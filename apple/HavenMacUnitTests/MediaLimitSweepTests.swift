import XCTest
@testable import HavenUITestHost

/// "Delete local media older than N days" / "keep local media under N GB": which files the sweep
/// removes, what it never touches, and which of the removed ones a post still references (those
/// are remembered as evicted so they can be downloaded again on demand, not silently re-fetched).
@MainActor
final class MediaLimitSweepTests: XCTestCase {
    private var planted: [URL] = []
    private let dir = MediaStore.storageDir

    override func setUp() async throws { _ = await Harness.feed() }
    override func tearDown() async throws {
        for u in planted { HeldMediaIndex.shared.remove(u.lastPathComponent); try? FileManager.default.removeItem(at: u) }
        planted = []
        SettingsStore.shared.localMediaMaxDays = 0
        SettingsStore.shared.localMediaMaxGB = 0
    }

    private func stem() -> String { "img_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "0", count: 32) }
    @discardableResult
    private func plant(_ stem: String, bytes: Int = 64, daysOld: Double, sparseBytes: UInt64? = nil, ext: String = "jpg") throws -> URL {
        let url = dir.appendingPathComponent("\(stem).\(ext)")
        if let sparseBytes {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: sparseBytes)   // apparent size only: no disk is used
            try h.close()
        } else {
            try Data(repeating: 7, count: bytes).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        planted.append(url)
        return url
    }
    private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    func testTheAgeLimitRemovesOldFilesButNeverPinnedFreshOrInFlightOnes() throws {
        let old = stem(), pinned = stem(), fresh = stem(), referenced = stem()
        let oldURL = try plant(old, daysOld: 30)
        let pinnedURL = try plant(pinned, daysOld: 30)
        let freshURL = try plant(fresh, daysOld: 0.1)
        let refURL = try plant(referenced, bytes: 100, daysOld: 20)
        let minting = try plant("mint_" + stem(), daysOld: 30)
        let incoming = try plant("incoming_" + stem(), daysOld: 30)

        let r = MediaStore.performLimitSweep(maxDays: 7, maxGB: 0, pinnedStems: [pinned], inUse: [referenced])
        XCTAssertFalse(exists(oldURL), "older than the limit")
        XCTAssertFalse(exists(refURL))
        XCTAssertTrue(exists(pinnedURL), "device-pinned media is never evicted")
        XCTAssertTrue(exists(freshURL), "inside the 48 h grace window: too fresh to judge")
        XCTAssertTrue(exists(minting) && exists(incoming), "composer-staged and in-flight files are never touched")
        XCTAssertGreaterThanOrEqual(r.files, 2)
        XCTAssertEqual(r.evict[referenced], 100, "a file a post still references is remembered as evicted, with its size")
        XCTAssertNil(r.evict[old], "an unreferenced file is simply gone")
        let off = MediaStore.performLimitSweep(maxDays: 0, maxGB: 0, pinnedStems: [], inUse: [])
        XCTAssertEqual(off.files, 0, "no limits set: nothing happens")
    }

    func testTheSizeLimitEvictsOldestFirstUntilItFits() throws {
        // Two sparse files with a 0.6 GB apparent size each: over the 1 GB cap together, under it alone.
        let older = stem(), newer = stem()
        let olderURL = try plant(older, daysOld: 4, sparseBytes: 600_000_000)
        let newerURL = try plant(newer, daysOld: 3, sparseBytes: 600_000_000)
        let r = MediaStore.performLimitSweep(maxDays: 0, maxGB: 1, pinnedStems: [], inUse: [])
        XCTAssertFalse(exists(olderURL), "the oldest goes first")
        XCTAssertTrue(exists(newerURL), "…and eviction stops as soon as the library fits")
        XCTAssertGreaterThanOrEqual(r.files, 1)
    }

    func testChangingTheLimitSweepsAndRemembersWhatAPostStillShows() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let ann = Peer(byte: 0x3F, name: "Ann")
        await ann.befriend(store)
        let ref = stem()
        let url = try plant(ref, bytes: 90, daysOld: 40)
        let body = "old photo \(UUID().uuidString.prefix(6))"
        await ann.post(body, into: store, media: [ref])
        await Harness.until(store, "the post that references it is in the feed") { store.items.contains { $0.body == body } }
        XCTAssertFalse(EvictedMediaStore.shared.contains(ref))

        SettingsStore.shared.localMediaMaxDays = 7   // changing the limit sweeps at once
        await Harness.until(store, timeout: 60, "the old file is swept") { !self.exists(url) }
        await Harness.until(store, timeout: 30, "…and remembered as evicted, not as lost") { EvictedMediaStore.shared.contains(ref) }
        XCTAssertEqual(EvictedMediaStore.shared.size(ref), 90)
        EvictedMediaStore.shared.clear(ref)
    }
}
