import XCTest

/// The honest-progress decisions (SyncProgress.swift). Field report: the sync pill and media spinners
/// "never progress at all and just disappear after a bit" — these pin the rules that replaced them.
final class SyncProgressTests: XCTestCase {
    private let c = "circle-a"

    private func derive(_ p: UploadProgress, relay: Bool = true, hosts: Bool = false,
                        nearby: Bool = false, online: Bool = true) -> SyncBadgeState {
        SyncBadgeState.derive(progress: p, circleId: c, hostsRelay: hosts, hasRelay: relay,
                              nearbyConnected: nearby, online: online)
    }

    // MARK: sync pill

    func testNothingPendingIsSyncedEvenWhileAPassRuns() {
        // Launch re-publishes epoch heads for every circle: a pass runs, but none of it is the
        // user's. The pill must not appear for that.
        var p = UploadProgress()
        p.flushing = true
        XCTAssertEqual(derive(p), .synced)
    }

    func testQueuedUserItemsShowTheirCount() {
        var p = UploadProgress()
        p.pendingByCircle[c] = 3
        XCTAssertEqual(derive(p), .queued(pending: 3))
    }

    func testActivePassShowsSentOfTotalForThisCircle() {
        var p = UploadProgress()
        p.pendingByCircle[c] = 5
        p.flushing = true
        p.flushTotalByCircle[c] = 5
        p.flushDoneByCircle[c] = 2
        XCTAssertEqual(derive(p), .sending(done: 2, total: 5))
        // done can never read past total
        p.flushDoneByCircle[c] = 9
        XCTAssertEqual(derive(p), .sending(done: 5, total: 5))
    }

    func testAPassForAnotherCircleIsNotThisCirclesSend() {
        var p = UploadProgress()
        p.pendingByCircle[c] = 1
        p.flushing = true
        p.flushTotalByCircle["other"] = 4
        XCTAssertEqual(derive(p), .queued(pending: 1))
    }

    func testBackoffShowsRetryingWithTheCount() {
        var p = UploadProgress()
        p.pendingByCircle[c] = 2
        p.backingOff = true
        XCTAssertEqual(derive(p), .retrying(pending: 2))
        // …including during the retry pass itself (no flicker to "Sending 0 of 2" per attempt)
        p.flushing = true
        p.flushTotalByCircle[c] = 2
        XCTAssertEqual(derive(p), .retrying(pending: 2))
    }

    func testOfflineWithPendingIsDeviceOnly() {
        var p = UploadProgress()
        p.pendingByCircle[c] = 1
        p.backingOff = true
        XCTAssertEqual(derive(p, online: false), .deviceOnly)
        p.backingOff = false
        XCTAssertEqual(derive(p, nearby: true, online: false), .queued(pending: 1))
    }

    func testHostingTheRelayIsAlwaysSynced() {
        var p = UploadProgress()
        p.pendingByCircle[c] = 4
        p.backingOff = true
        XCTAssertEqual(derive(p, hosts: true), .synced)
    }

    func testNoRelayIgnoresTheQueue() {
        var p = UploadProgress()
        p.pendingByCircle[c] = 4
        XCTAssertEqual(derive(p, relay: false), .synced)
        XCTAssertEqual(derive(p, relay: false, nearby: true, online: false), .synced)
        XCTAssertEqual(derive(p, relay: false, online: false), .deviceOnly)
    }

    // MARK: no-progress watchdog

    func testSteadyProgressNeverStalls() {
        var w = TransferStallWatch(progress: 0, nowMs: 0)
        for i in 1...20 {
            XCTAssertFalse(w.observe(progress: i, nowMs: UInt64(i) * 30_000))
        }
    }

    func testStallsOnlyAfterTheNoProgressWindow() {
        var w = TransferStallWatch(progress: 3, nowMs: 1_000)
        XCTAssertFalse(w.observe(progress: 3, nowMs: 1_000 + 44_999))
        XCTAssertTrue(w.observe(progress: 3, nowMs: 1_000 + 45_000))
    }

    func testNewBytesResetTheClock() {
        var w = TransferStallWatch(progress: 0, nowMs: 0)
        XCTAssertFalse(w.observe(progress: 1, nowMs: 40_000))
        XCTAssertFalse(w.observe(progress: 1, nowMs: 80_000))
        XCTAssertTrue(w.observe(progress: 1, nowMs: 85_000))
    }

    func testABusyRelayRestoreHoldsTheClock() {
        var w = TransferStallWatch(progress: 0, nowMs: 0)
        XCTAssertFalse(w.observe(progress: 0, nowMs: 120_000, busy: true))
        XCTAssertFalse(w.observe(progress: 0, nowMs: 160_000))
        XCTAssertTrue(w.observe(progress: 0, nowMs: 165_000))
    }

    func testAShrinkingMarkIsNotProgress() {
        // A restarted partial reports fewer chunks; that must not count as bytes arriving.
        var w = TransferStallWatch(progress: 10, nowMs: 0)
        XCTAssertFalse(w.observe(progress: 2, nowMs: 10_000))
        XCTAssertTrue(w.observe(progress: 2, nowMs: 45_000))
        XCTAssertFalse(w.observe(progress: 3, nowMs: 46_000))
    }

    // MARK: wanted set

    func testWantedSetIsStableAcrossPartialScans() {
        var s = MediaWantedSet()
        s.discover(["a", "b"])          // pass 1: active circle + circle X
        s.discover(["a", "c"])          // pass 2: active circle + circle Y
        XCTAssertEqual(s.count, 3)      // not 2 then 2 — every missing ref still counts
        XCTAssertTrue(s.arrived("b"))
        XCTAssertFalse(s.arrived("b"))  // arriving twice never double-counts
        XCTAssertEqual(s.count, 2)
        s.gaveUp("c")
        XCTAssertEqual(s.refs, ["a"])
    }

    func testPruneDropsRefsThatArrivedElsewhere() {
        var s = MediaWantedSet()
        s.discover(["a", "b", "c"])
        s.prune { $0 == "b" }
        XCTAssertEqual(s.refs, ["a", "c"])
    }

    func testWantedSetIsBounded() {
        var s = MediaWantedSet()
        s.discover((0..<(MediaWantedSet.cap + 50)).map { "r\($0)" })
        XCTAssertEqual(s.count, MediaWantedSet.cap)
    }
}
