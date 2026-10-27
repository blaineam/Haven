import XCTest

/// Mirrors Android's `RelayAnnounceParkingTest` / `NoRelayMediaPolicyTest` and desktop's
/// `relayparking.rs` tests — the same cases and constants on all three platforms.
final class RelayAnnounceParkingTests: XCTestCase {
    private func b(_ s: String) -> Data { Data(s.utf8) }

    func testAnAnnounceParkedBeforeItsKeyIsReturnedOnTheNextDrain() {
        let p = RelayAnnounceParking(minRetryGapMs: 0)
        p.park(circleId: "default", sealed: b("sealed-1"), nowMs: 1_000)
        let got = p.drain(nowMs: 2_000)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].circleId, "default")
        XCTAssertEqual(got[0].sealed, b("sealed-1"))
        XCTAssertEqual(p.count, 0, "handed over; the caller re-parks it if it is STILL unopenable")
    }

    func testTheSameAnnounceIsKeptOnce() {
        let p = RelayAnnounceParking(minRetryGapMs: 0)
        for i in 0..<5 { p.park(circleId: "default", sealed: b("same"), nowMs: UInt64(i)) }
        XCTAssertEqual(p.count, 1)
    }

    func testDifferentCirclesAreDistinct() {
        let p = RelayAnnounceParking(minRetryGapMs: 0)
        p.park(circleId: "a", sealed: b("x"), nowMs: 1)
        p.park(circleId: "b", sealed: b("x"), nowMs: 1)
        XCTAssertEqual(p.count, 2)
    }

    func testTheQueueIsBoundedAndKeepsTheNewest() {
        let p = RelayAnnounceParking(capacity: 3, minRetryGapMs: 0)
        for i in 1...6 { p.park(circleId: "c", sealed: b("s\(i)"), nowMs: UInt64(i)) }
        XCTAssertEqual(p.count, 3)
        let kept = Set(p.drain(nowMs: 10).map { String(decoding: $0.sealed, as: UTF8.self) })
        XCTAssertEqual(kept, ["s4", "s5", "s6"])
    }

    func testExpiredAnnouncesAreDropped() {
        let p = RelayAnnounceParking(ttlMs: 1_000, minRetryGapMs: 0)
        p.park(circleId: "c", sealed: b("old"), nowMs: 0)
        p.park(circleId: "c", sealed: b("new"), nowMs: 5_000)
        let got = p.drain(nowMs: 5_500)
        XCTAssertEqual(got.map { String(decoding: $0.sealed, as: UTF8.self) }, ["new"])
    }

    func testDrainsAreRateLimitedSoABurstOfFramesDoesNotSpin() {
        let p = RelayAnnounceParking(minRetryGapMs: 5_000)
        p.park(circleId: "c", sealed: b("one"), nowMs: 0)
        XCTAssertEqual(p.drain(nowMs: 10_000).count, 1)
        p.park(circleId: "c", sealed: b("two"), nowMs: 10_001)
        XCTAssertTrue(p.drain(nowMs: 12_000).isEmpty, "too soon after the last drain")
        XCTAssertEqual(p.drain(nowMs: 15_000).count, 1, "gap elapsed")
    }

    func testTheFirstDrainIsNeverRateLimited() {
        // The Android sentinel bug (f6e0bf02): a first drain at a small clock value must still return.
        let p = RelayAnnounceParking()
        p.park(circleId: "c", sealed: b("x"), nowMs: 0)
        XCTAssertEqual(p.drain(nowMs: 1).count, 1)
    }

    func testAnUnopenableOneParkedAgainKeepsGettingRetried() {
        let p = RelayAnnounceParking(minRetryGapMs: 0)
        p.park(circleId: "c", sealed: b("later"), nowMs: 0)
        let first = p.drain(nowMs: 1)[0]
        p.park(circleId: first.circleId, sealed: first.sealed, nowMs: 1)   // the key has not landed yet
        XCTAssertEqual(p.drain(nowMs: 2).count, 1, "still there for the next attempt")
    }

    // MARK: NoRelayMediaPolicy

    func testAFetchThatAskedNoRelayDoesNotClaimTheRelaysAnsweredEmpty() {
        XCTAssertFalse(NoRelayMediaPolicy.relaysAnsweredEmpty(relaysAsked: 0))
        XCTAssertTrue(NoRelayMediaPolicy.relaysAnsweredEmpty(relaysAsked: 1))
        XCTAssertTrue(NoRelayMediaPolicy.relaysAnsweredEmpty(relaysAsked: 3))
    }

    func testTheReAskBudgetMatchesTheAuthorsHintBudget() {
        XCTAssertEqual(NoRelayMediaPolicy.maxReasksPerRef, HeavyWorkPolicy.maxRelayHints)
        XCTAssertEqual(NoRelayMediaPolicy.maxReasksPerRef, 3)
        XCTAssertEqual(NoRelayMediaPolicy.reaskSpacingMs, 4_000)
        XCTAssertEqual(NoRelayMediaPolicy.introNudgeEveryMs, 600_000)
    }

    func testAHintWeCanActOnIsNeverReAsked() {
        XCTAssertFalse(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay: true, priorReasks: 0, lastReaskMs: nil, nowMs: 10_000))
    }

    func testReAsksAreSpacedAndCappedAtTheAuthorsHintBudget() {
        let t0: UInt64 = 100_000
        XCTAssertTrue(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay: false, priorReasks: 0, lastReaskMs: nil, nowMs: t0))
        XCTAssertFalse(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay: false, priorReasks: 1, lastReaskMs: t0, nowMs: t0 + NoRelayMediaPolicy.reaskSpacingMs - 1))
        XCTAssertTrue(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay: false, priorReasks: 1, lastReaskMs: t0, nowMs: t0 + NoRelayMediaPolicy.reaskSpacingMs))
        XCTAssertTrue(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay: false, priorReasks: NoRelayMediaPolicy.maxReasksPerRef - 1, lastReaskMs: t0, nowMs: t0 + 60_000))
        XCTAssertFalse(NoRelayMediaPolicy.reAskAfterUnusableHint(hasRelay: false, priorReasks: NoRelayMediaPolicy.maxReasksPerRef, lastReaskMs: t0, nowMs: t0 + 60_000))
    }

    func testTheIntroNudgeIsRateLimitedAndOnlyForRelaylessCircles() {
        let now: UInt64 = 1_000_000
        XCTAssertFalse(NoRelayMediaPolicy.introNudgeDue(hasRelay: true, lastNudgeMs: nil, nowMs: now))
        XCTAssertTrue(NoRelayMediaPolicy.introNudgeDue(hasRelay: false, lastNudgeMs: nil, nowMs: now))
        XCTAssertFalse(NoRelayMediaPolicy.introNudgeDue(hasRelay: false, lastNudgeMs: now - 1_000, nowMs: now))
        XCTAssertTrue(NoRelayMediaPolicy.introNudgeDue(hasRelay: false, lastNudgeMs: now - NoRelayMediaPolicy.introNudgeEveryMs, nowMs: now))
    }
}
