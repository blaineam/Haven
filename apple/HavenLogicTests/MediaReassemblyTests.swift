import XCTest

/// The durable record of a half-finished chunked media transfer plus the frame-33 resume codec. A bad
/// bitmap here means a permanent hole in a content-addressed blob, so both directions are covered,
/// and every bound the decoder enforces is a bound on what a PEER can make us allocate.
@MainActor
final class MediaReassemblyTests: XCTestCase {
    private var dir: URL!
    private var parts: URL!
    private var defaults: SpilledDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("reasm-\(UUID().uuidString)")
        parts = dir.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        defaults = SpilledDefaults(directory: dir.appendingPathComponent("prefs"), legacy: nil, writeDelay: 3600)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> ReassemblyStore {
        ReassemblyStore(defaults: defaults, storageDir: { [parts] in parts! }, now: { [unowned self] in self.clock })
    }

    /// A manual clock so "oldest progress" is exact rather than a race between two `Date()` calls.
    private var clock = Date()

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: parts.appendingPathComponent(name).path, contents: Data([1]))
    }

    // MARK: Bitmap

    func testBitmapRoundTrip() {
        let got: Set<Int> = [0, 1, 7, 8, 15, 16, 99]
        let bm = ReassemblyStore.bitmap(got, total: 100)
        XCTAssertEqual(bm.count, 13, "100 chunks pack into ceil(100/8) bytes")
        XCTAssertEqual(ReassemblyStore.indices(bm, total: 100), got)
    }

    func testBitmapBitOrderIsLSBFirst() {
        XCTAssertEqual([UInt8](ReassemblyStore.bitmap([0], total: 8)), [0b0000_0001])
        XCTAssertEqual([UInt8](ReassemblyStore.bitmap([7], total: 8)), [0b1000_0000])
        XCTAssertEqual([UInt8](ReassemblyStore.bitmap([1, 9], total: 16)), [0b10, 0b10])
    }

    func testBitmapIgnoresOutOfRangeAndNegative() {
        let bm = ReassemblyStore.bitmap([-1, 0, 5, 6, 1000], total: 6)
        XCTAssertEqual(ReassemblyStore.indices(bm, total: 6), [0, 5])
        XCTAssertEqual(ReassemblyStore.bitmap([1], total: 0), Data())
        XCTAssertEqual(ReassemblyStore.bitmap([1], total: -3), Data())
    }

    func testIndicesToleratesShortBitmap() {
        XCTAssertEqual(ReassemblyStore.indices(Data([0xFF]), total: 20), Set(0..<8),
                       "a bitmap shorter than the total only claims what it holds")
        XCTAssertEqual(ReassemblyStore.indices(Data(), total: 10), [])
        XCTAssertEqual(ReassemblyStore.indices(Data([0xFF]), total: 0), [])
    }

    // MARK: Frame 33

    private let hex = String(repeating: "ab", count: 32)

    func testResumeRoundTrip() throws {
        let got: Set<Int> = [0, 3, 4, 31]
        let frame = ReassemblyStore.encodeResume(myHex: hex, ref: "img_deadbeef", total: 32, got: got)
        let d = try XCTUnwrap(ReassemblyStore.decodeResume(frame))
        XCTAssertEqual(d.requesterHex, hex)
        XCTAssertEqual(d.ref, "img_deadbeef")
        XCTAssertEqual(d.total, 32)
        XCTAssertEqual(ReassemblyStore.indices(d.bitmap, total: d.total), got)
    }

    func testResumeFrameLayoutIsLittleEndian() {
        let frame = ReassemblyStore.encodeResume(myHex: hex, ref: "r", total: 0x0102, got: [])
        XCTAssertEqual([UInt8](frame[64..<66]), [1, 0], "u16 ref length, LE")
        XCTAssertEqual(frame[66], UInt8(ascii: "r"))
        XCTAssertEqual([UInt8](frame[67..<71]), [2, 1, 0, 0], "u32 total, LE")
    }

    func testDecodeRejectsMalformed() {
        let good = ReassemblyStore.encodeResume(myHex: hex, ref: "ref", total: 16, got: [1])
        XCTAssertNotNil(ReassemblyStore.decodeResume(good))
        XCTAssertNil(ReassemblyStore.decodeResume(Data()))
        XCTAssertNil(ReassemblyStore.decodeResume(good.prefix(65)), "shorter than hex + ref length")
        XCTAssertNil(ReassemblyStore.decodeResume(good.prefix(66 + 3 + 3)), "truncated before the total")
        XCTAssertNil(ReassemblyStore.decodeResume(good.dropLast()), "bitmap one byte short of what total implies")
        XCTAssertNil(ReassemblyStore.decodeResume(good + Data([0])), "bitmap one byte long")
    }

    func testDecodeRejectsBadFields() {
        // Requester hex not 64 chars (here: 62).
        let shortHex = ReassemblyStore.encodeResume(myHex: String(hex.dropLast(2)), ref: "r", total: 8, got: [])
        XCTAssertNil(ReassemblyStore.decodeResume(shortHex))
        // Empty ref.
        XCTAssertNil(ReassemblyStore.decodeResume(ReassemblyStore.encodeResume(myHex: hex, ref: "", total: 8, got: [])))
        // Zero total.
        XCTAssertNil(ReassemblyStore.decodeResume(ReassemblyStore.encodeResume(myHex: hex, ref: "r", total: 0, got: [])))
    }

    func testDecodeBoundsPeerChosenTotal() {
        // 4M chunks (~128 GB) is the ceiling; one over is refused before any allocation.
        let atLimit = ReassemblyStore.encodeResume(myHex: hex, ref: "r", total: 4_000_000, got: [])
        XCTAssertNotNil(ReassemblyStore.decodeResume(atLimit))
        let over = ReassemblyStore.encodeResume(myHex: hex, ref: "r", total: 4_000_001, got: [])
        XCTAssertNil(ReassemblyStore.decodeResume(over))
    }

    func testDecodeReturnsRawBitmapNotExpanded() throws {
        let frame = ReassemblyStore.encodeResume(myHex: hex, ref: "r", total: 800, got: Set(0..<800))
        let d = try XCTUnwrap(ReassemblyStore.decodeResume(frame))
        XCTAssertEqual(d.bitmap.count, 100)
    }

    // MARK: Records

    func testNoteRecordsProgressAndClearForgets() throws {
        let store = makeStore()
        store.note(ref: "r1", part: "r1.part", total: 10, got: [0, 1, 2])
        let rec = try XCTUnwrap(store.record("r1"))
        XCTAssertEqual(rec.part, "r1.part")
        XCTAssertEqual(rec.total, 10)
        XCTAssertEqual(ReassemblyStore.indices(rec.got, total: 10), [0, 1, 2])
        store.clear("r1")
        XCTAssertNil(store.record("r1"))
        store.clear("never-existed")   // a no-op, must not crash or write
    }

    func testStateSurvivesReinit() {
        let a = makeStore()
        a.note(ref: "r1", part: "p1", total: 4, got: [1], force: true)
        let b = makeStore()
        XCTAssertEqual(b.record("r1")?.part, "p1", "a relaunch resumes from the persisted bitmap")
    }

    func testLiveHoldersReadPersistedPartsForTheSweep() {
        let a = makeStore()
        a.note(ref: "r1", part: "p1", total: 4, got: [1], force: true)
        a.note(ref: "r2", part: "p2", total: 4, got: [], force: true)
        let live = ReassemblyStore.liveParts(defaults: defaults)
        XCTAssertEqual(Set(live.keys), ["p1", "p2"])
        XCTAssertEqual(live["p1"], clock.timeIntervalSince1970)
        let empty = SpilledDefaults(directory: dir.appendingPathComponent("other"), legacy: nil, writeDelay: 3600)
        XCTAssertEqual(ReassemblyStore.liveParts(defaults: empty), [:])
    }

    func testRestoreKeepsOnlyRecordsWithBytesOnDisk() {
        let store = makeStore()
        store.note(ref: "kept", part: "kept.part", total: 4, got: [0], force: true)
        store.note(ref: "gone", part: "gone.part", total: 4, got: [0], force: true)
        touch("kept.part")
        let alive = store.restore()
        XCTAssertEqual(alive.map(\.ref), ["kept"])
        XCTAssertNil(store.record("gone"), "a bitmap without its bytes is a lie")
        XCTAssertNotNil(store.record("kept"))
    }

    func testRestoreExpiresAbandonedTransfersAndDeletesTheirPartFile() throws {
        let store = makeStore()
        store.note(ref: "stale", part: "stale.part", total: 4, got: [0], force: true)
        touch("stale.part")
        // Age the record past the 24h abandonment cutoff by rewriting the persisted copy.
        var rec = try XCTUnwrap(store.record("stale"))
        rec.updated = clock.timeIntervalSince1970 - ReassemblyStore.expiry - 10
        defaults.set(try JSONEncoder().encode(["stale": rec]), forKey: ReassemblyStore.key)
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.restore().isEmpty)
        XCTAssertNil(reloaded.record("stale"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parts.appendingPathComponent("stale.part").path),
                       "an abandoned partial is unaccountable disk and is reclaimed")
    }

    func testIndexIsBounded() {
        let store = makeStore()
        for i in 0..<520 {
            clock = clock.addingTimeInterval(1)
            store.note(ref: "r\(i)", part: "p\(i)", total: 8, got: [], force: false)
        }
        let present = (0..<520).filter { store.record("r\($0)") != nil }.count
        XCTAssertEqual(present, 512, "a peer starting thousands of transfers cannot grow the index without limit")
        XCTAssertNotNil(store.record("r519"), "the newest progress is what survives")
        XCTAssertNil(store.record("r0"), "the oldest progress goes first")
        XCTAssertNil(store.record("r7"))
        XCTAssertNotNil(store.record("r8"))
    }
}
