import XCTest

/// Relay-first media serving + the call / thermal / Low Power heavy-I/O gate.
///
/// Field report: a phone got hot during a call because it streamed a video peer-to-peer to a friend
/// while that blob was (or was about to be) on the user's relay. These pin the decisions that stop it.
final class HeavyWorkPolicyTests: XCTestCase {
    typealias C = HeavyWorkPolicy.Conditions
    typealias R = HeavyWorkPolicy.ServeRequest

    private func friend(onRelay: Bool = false, pending: Bool = false, relay: Bool = true, hints: Int = 0) -> R {
        R(isOwnDevice: false, onRelay: onRelay, uploadPending: pending, circleHasRelay: relay, hintsAlreadySent: hints)
    }
    private func own(pending: Bool = false, handoff: Bool = false, hints: Int = 0) -> R {
        R(isOwnDevice: true, isHandoffTarget: handoff, onRelay: false, uploadPending: pending,
          circleHasRelay: true, hintsAlreadySent: hints)
    }

    // MARK: gate

    func testGateSuspendsForAnyCallLowPowerOrSeriousHeat() {
        XCTAssertFalse(C().suspendHeavyIO)
        XCTAssertTrue(C(havenCall: true).suspendHeavyIO)
        XCTAssertTrue(C(systemCall: true).suspendHeavyIO)
        XCTAssertTrue(C(lowPower: true).suspendHeavyIO)
        XCTAssertTrue(C(heat: .serious).suspendHeavyIO)
        XCTAssertTrue(C(heat: .critical).suspendHeavyIO)
        XCTAssertFalse(C(heat: .fair).suspendHeavyIO, ".fair halves budgets but is not a suspend")
    }

    func testFriendServingNeedsAFullyCoolIdleDevice() {
        XCTAssertTrue(C().peerServingAllowedForFriends)
        XCTAssertFalse(C(heat: .fair).peerServingAllowedForFriends, "warm → relay upload gets the budget, not peer serving")
        XCTAssertFalse(C(havenCall: true).peerServingAllowedForFriends)
        XCTAssertFalse(C(systemCall: true).peerServingAllowedForFriends)
        XCTAssertFalse(C(lowPower: true).peerServingAllowedForFriends)
    }

    // MARK: serving

    /// The reported bug: a friend asks during a call for a blob the relay holds.
    func testNeverStreamDuringACall() {
        let c = C(havenCall: true)
        XCTAssertNotEqual(HeavyWorkPolicy.decideServe(friend(onRelay: true), c), .stream)
        XCTAssertNotEqual(HeavyWorkPolicy.decideServe(friend(relay: false), c), .stream)
        XCTAssertNotEqual(HeavyWorkPolicy.decideServe(own(), c), .stream)
        XCTAssertNotEqual(HeavyWorkPolicy.decideServe(friend(relay: false), C(systemCall: true)), .stream)
    }

    func testRelayHeldBlobIsHintedNotStreamed() {
        XCTAssertEqual(HeavyWorkPolicy.decideServe(friend(onRelay: true), C()), .hintRelay)
    }

    func testPendingUploadIsFinishedFirst() {
        XCTAssertEqual(HeavyWorkPolicy.decideServe(friend(pending: true), C()), .hintWhenUploaded)
    }

    func testNoRelayAtAllStreamsOnlyWhenCool() {
        XCTAssertEqual(HeavyWorkPolicy.decideServe(friend(relay: false), C()), .stream)
        if case .decline = HeavyWorkPolicy.decideServe(friend(relay: false), C(heat: .fair)) {} else {
            XCTFail("warm device must not stream to a friend")
        }
    }

    /// A requester that keeps asking after being pointed at the relay cannot read that copy — after
    /// the hint budget it gets the direct path (only if the gate allows).
    func testHintBudgetFallsBackToDirect() {
        let spent = HeavyWorkPolicy.maxRelayHints
        XCTAssertEqual(HeavyWorkPolicy.decideServe(friend(onRelay: true, hints: spent), C()), .stream)
        if case .decline = HeavyWorkPolicy.decideServe(friend(onRelay: true, hints: spent), C(lowPower: true)) {} else {
            XCTFail("Low Power Mode must not stream even after hints")
        }
    }

    /// Relay neither holds nor is receiving it (e.g. a friend's blob we merely hold) → normal serve.
    func testNotOnRelayNotPendingStreamsWhenCool() {
        XCTAssertEqual(HeavyWorkPolicy.decideServe(friend(), C()), .stream)
    }

    func testOwnDevicesAreServedUnlessSuspended() {
        XCTAssertEqual(HeavyWorkPolicy.decideServe(own(), C()), .stream)
        XCTAssertEqual(HeavyWorkPolicy.decideServe(own(), C(heat: .fair)), .stream, "own-device lane is cheap")
        XCTAssertEqual(HeavyWorkPolicy.decideServe(own(pending: true), C()), .hintWhenUploaded)
        XCTAssertEqual(HeavyWorkPolicy.decideServe(own(pending: true, handoff: true), C()), .stream)
    }

    func testCriticalDeclinesEverything() {
        if case .decline = HeavyWorkPolicy.decideServe(own(), C(heat: .critical)) {} else { XCTFail() }
    }

    // MARK: requester patience

    func testFreshRefWaitsForTheRelay() {
        XCTAssertFalse(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(small: false, circleHasRelay: true, ageMs: 30_000,
                                                                 userInitiated: false, C()))
        XCTAssertTrue(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(small: false, circleHasRelay: true,
                                                                ageMs: HeavyWorkPolicy.freshRelayPatienceMs + 1,
                                                                userInitiated: false, C()))
        XCTAssertTrue(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(small: false, circleHasRelay: false, ageMs: 1_000,
                                                                userInitiated: false, C()),
                      "no relay → peers are the only path")
    }

    func testThumbsAreNeverGated() {
        XCTAssertTrue(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(small: true, circleHasRelay: true, ageMs: 1,
                                                                userInitiated: false, C(havenCall: true)))
        XCTAssertTrue(HeavyWorkPolicy.prefetchAllowed(small: true, C(lowPower: true)))
        XCTAssertFalse(HeavyWorkPolicy.prefetchAllowed(small: false, C(lowPower: true)))
    }

    func testSuspendBlocksDirectAsks() {
        XCTAssertFalse(HeavyWorkPolicy.mayDirectAskAfterRelayMiss(small: false, circleHasRelay: false, ageMs: nil,
                                                                 userInitiated: true, C(systemCall: true)))
    }

    // MARK: upload queue

    func testOwnFreshUploadsContinueThroughACall() {
        XCTAssertEqual(HeavyWorkPolicy.uploadBudget(base: 5, C()), .init(priority: 5, backfill: 5))
        XCTAssertEqual(HeavyWorkPolicy.uploadBudget(base: 5, C(havenCall: true)), .init(priority: 1, backfill: 0))
        XCTAssertEqual(HeavyWorkPolicy.uploadBudget(base: 5, C(heat: .fair)), .init(priority: 5, backfill: 5),
                       "warm → keep uploading to the relay")
        XCTAssertEqual(HeavyWorkPolicy.uploadBudget(base: 5, C(heat: .critical)), .init(priority: 0, backfill: 0))
    }

    /// The QA attribution of a direct friend serve names its cause (e2e `relayfirst`).
    func testStreamReasonNamesWhyNoHintAnsweredIt() {
        XCTAssertEqual(HeavyWorkPolicy.streamReason(friend(onRelay: true, relay: false), circleKnown: false), "circle-unresolved")
        XCTAssertEqual(HeavyWorkPolicy.streamReason(friend(relay: false), circleKnown: true), "circle-has-no-relay")
        XCTAssertEqual(HeavyWorkPolicy.streamReason(friend(onRelay: true, hints: HeavyWorkPolicy.maxRelayHints), circleKnown: true),
                       "hints-exhausted")
        XCTAssertEqual(HeavyWorkPolicy.streamReason(friend(), circleKnown: true), "not-on-relay-nor-queued")
    }

    /// On a satellite link only satellite-safe media may leave — by ANY path (a friend's media-wanted
    /// ask used to force the full original onto the relay mid-pass).
    func testUltraConstrainedLinkMovesOnlySatelliteSafeMedia() {
        XCTAssertTrue(HeavyWorkPolicy.mayMoveOverLink(ultraConstrained: false, satelliteSafe: false))
        XCTAssertTrue(HeavyWorkPolicy.mayMoveOverLink(ultraConstrained: false, satelliteSafe: true))
        XCTAssertTrue(HeavyWorkPolicy.mayMoveOverLink(ultraConstrained: true, satelliteSafe: true))
        XCTAssertFalse(HeavyWorkPolicy.mayMoveOverLink(ultraConstrained: true, satelliteSafe: false))
    }
}
