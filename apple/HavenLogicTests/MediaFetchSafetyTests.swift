import XCTest

/// The guards that keep one fetch of a ref from getting it judged corrupt and blacklisted for the
/// session: single-flight per ref, an empty body as a miss, and atomic replacement on disk.
@MainActor
final class MediaFetchSafetyTests: XCTestCase {
    /// Four lanes asking for the same companion at once must cost ONE fetch, and every caller gets
    /// its result — the second fetch is what raced the first on the same files.
    func testConcurrentCallersForOneRefShareASingleRun() async {
        let flights = SingleFlight<Data?>()
        var runs = 0
        let gate = AsyncGate()
        let body: @Sendable @MainActor () async -> Data? = {
            runs += 1
            await gate.wait()
            return Data("sealed".utf8)
        }
        async let a = flights.run("img_abc", body)
        async let b = flights.run("img_abc", body)
        async let c = flights.run("img_abc", body)
        await Task.yield(); await Task.yield()
        XCTAssertTrue(flights.inFlight("img_abc"))
        gate.open()
        let results = await [a, b, c]
        XCTAssertEqual(runs, 1, "joiners must await the leader, not start their own fetch")
        XCTAssertEqual(results, Array(repeating: Data("sealed".utf8), count: 3))
        XCTAssertFalse(flights.inFlight("img_abc"), "a finished run must not be joined later")
    }

    /// A finished run is never handed to a later caller: a miss a moment ago is no answer now.
    func testALaterCallerRunsAgainAfterTheLeaderFinished() async {
        let flights = SingleFlight<Data?>()
        var runs = 0
        let first = await flights.run("img_abc") { runs += 1; return nil }
        XCTAssertNil(first)
        let second = await flights.run("img_abc") { runs += 1; return Data([1]) }
        XCTAssertEqual(second, Data([1]))
        XCTAssertEqual(runs, 2)
    }

    func testDifferentRefsDoNotWaitOnEachOther() async {
        let flights = SingleFlight<Int>()
        let gate = AsyncGate()
        async let slow = flights.run("img_slow") { await gate.wait(); return 1 }
        await Task.yield()
        let fast = await flights.run("img_fast") { 2 }
        XCTAssertEqual(fast, 2)
        gate.open()
        let slowValue = await slow
        XCTAssertEqual(slowValue, 1)
    }

    /// "found (0B) but OPEN FAILED" — an empty 200 is a miss, and an empty blob is never condemned.
    func testEmptyBodyIsAMissNotAStoredCopy() {
        XCTAssertNil(RelayMediaBody.usable(nil))
        XCTAssertNil(RelayMediaBody.usable(Data()))
        XCTAssertEqual(RelayMediaBody.usable(Data([0x5a])), Data([0x5a]))
        XCTAssertFalse(RelayMediaBody.mayCondemn(Data()))
        XCTAssertTrue(RelayMediaBody.mayCondemn(Data(repeating: 1, count: 13_039)))
    }

    /// A reader polling the target while it is replaced over and over must only ever see a whole
    /// blob — never a missing file (the remove-then-move gap) or a truncated one.
    func testReplaceIsAtomicUnderARacingReader() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("img_cafef00d.jpg")
        let blob = Data(repeating: 0x5a, count: 64 * 1024)
        try blob.write(to: dst)

        let stop = OSAllocatedFlag()
        let writer = Thread {
            while !stop.isSet {
                let tmp = dir.appendingPathComponent("incoming_\(UUID().uuidString).part")
                try? blob.write(to: tmp)
                XCTAssertTrue(AtomicFile.replace(dst, with: tmp))
            }
        }
        writer.start()
        for _ in 0..<2000 {
            let got = try Data(contentsOf: dst)
            XCTAssertEqual(got.count, blob.count, "a reader saw a truncated or missing blob")
        }
        stop.set()
        while !writer.isFinished { usleep(1000) }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, ["img_cafef00d.jpg"], "no temp files may be left behind")
    }

    /// The atomic `Data.write` MediaStore now uses: a racing reader never sees a short file.
    func testAtomicDataWriteNeverExposesATruncatedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mfs-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let blob = Data(repeating: 0xa5, count: 64 * 1024)
        try blob.write(to: url, options: .atomic)
        let stop = OSAllocatedFlag()
        let writer = Thread { while !stop.isSet { try? blob.write(to: url, options: .atomic) } }
        writer.start()
        for _ in 0..<2000 {
            XCTAssertEqual(try Data(contentsOf: url).count, blob.count)
        }
        stop.set()
        while !writer.isFinished { usleep(1000) }
    }
}

/// A one-shot latch the tests open by hand, so a "slow fetch" is held in flight deterministically.
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class OSAllocatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
