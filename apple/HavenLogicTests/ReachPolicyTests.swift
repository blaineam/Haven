import XCTest

final class DialOrderTests: XCTestCase {
    let acct = String(repeating: "a", count: 64)
    let dev1 = String(repeating: "1", count: 64)
    let dev2 = String(repeating: "2", count: 64)
    let hint = String(repeating: "b", count: 64)

    /// A brand-new friend: no roster (the engine answers [account]) but an invite hint — the hint is
    /// the only id that answers, and the dead account id must not be dialed at all.
    func testNewFriendDialsHintOnly() {
        XCTAssertEqual(DialOrder.targets(account: acct, resolved: [acct], hints: [hint]), [hint])
    }

    /// Roster known, no hint: devices first, account id kept LAST (pre-multidevice safety net).
    func testRosterKeepsAccountLast() {
        XCTAssertEqual(DialOrder.targets(account: acct, resolved: [dev1, dev2, acct], hints: []), [dev1, dev2, acct])
    }

    /// Hints first, then roster devices; account dropped; duplicates and case folded.
    func testHintsFirstThenDevicesDeduped() {
        let got = DialOrder.targets(account: acct.uppercased(), resolved: [dev1, acct, hint.uppercased()], hints: [hint])
        XCTAssertEqual(got, [hint, dev1])
    }

    /// Nothing known but the account: it is the only handle there is.
    func testAccountOnlyFallback() {
        XCTAssertEqual(DialOrder.targets(account: acct, resolved: [], hints: []), [acct])
    }
}

@MainActor
final class BoundedFanOutTests: XCTestCase {
    /// Results come back in INPUT order even when later items finish first.
    func testResultsInInputOrder() async {
        let got = await BoundedFanOut.run([3, 1, 2], limit: 3) { n -> Int in
            try? await Task.sleep(nanoseconds: UInt64(n) * 20_000_000)
            return n * 10
        }
        XCTAssertEqual(got, [30, 10, 20])
    }

    /// Never more than `limit` in flight, and every item runs exactly once.
    func testRespectsLimit() async {
        let probe = InFlightProbe()
        let items = Array(0..<12)
        let got = await BoundedFanOut.run(items, limit: 4) { i -> Int in
            probe.enter()
            try? await Task.sleep(nanoseconds: 10_000_000)
            probe.leave()
            return i
        }
        XCTAssertEqual(got, items)
        XCTAssertLessThanOrEqual(probe.peak, 4)
        XCTAssertGreaterThan(probe.peak, 1, "ran concurrently, not serially")
    }

    /// The point of the change: total time is ~max, not ~sum, of the per-item waits.
    func testSlowItemDoesNotSerializeTheRest() async {
        let start = Date()
        _ = await BoundedFanOut.run(Array(0..<6), limit: 6) { _ -> Bool in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return true
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9, "6 × 200ms ran concurrently")
    }

    func testEmpty() async {
        let got = await BoundedFanOut.run([Int](), limit: 4) { $0 }
        XCTAssertTrue(got.isEmpty)
    }
}

@MainActor
private final class InFlightProbe {
    private(set) var peak = 0
    private var now = 0
    func enter() { now += 1; peak = max(peak, now) }
    func leave() { now -= 1 }
}

final class PendingEnrollmentTests: XCTestCase {
    let relay = String(repeating: "c", count: 64)
    let t0: UInt64 = 1_000_000

    func testRefusalFromFreshTicketRelayRetriesSoon() {
        var p = PendingEnrollment()
        p.noteAdopted(relay, nowMs: t0)
        XCTAssertEqual(p.onFailure(relay: relay.uppercased(), forbidden: true, nowMs: t0 + 30_000),
                       .retrySoon(afterMs: PendingEnrollment.retryGapMs))
        XCTAssertLessThanOrEqual(PendingEnrollment.retryGapMs, 15_000)
    }

    func testOutageStillBacksOff() {
        var p = PendingEnrollment()
        p.noteAdopted(relay, nowMs: t0)
        XCTAssertEqual(p.onFailure(relay: relay, forbidden: false, nowMs: t0 + 1_000), .backOff)
    }

    func testWindowExpiresToOrdinaryBackoff() {
        var p = PendingEnrollment()
        p.noteAdopted(relay, nowMs: t0)
        XCTAssertEqual(p.onFailure(relay: relay, forbidden: true, nowMs: t0 + PendingEnrollment.windowMs), .backOff)
        XCTAssertFalse(p.anyPending(nowMs: t0 + PendingEnrollment.windowMs))
    }

    func testConfirmedOrUnknownRelayBacksOff() {
        var p = PendingEnrollment()
        XCTAssertEqual(p.onFailure(relay: relay, forbidden: true, nowMs: t0), .backOff, "never adopted from a ticket")
        p.noteAdopted(relay, nowMs: t0)
        XCTAssertTrue(p.confirm(relay))
        XCTAssertFalse(p.confirm(relay), "already confirmed")
        XCTAssertEqual(p.onFailure(relay: relay, forbidden: true, nowMs: t0 + 1_000), .backOff)
    }

    func testGrantReopensWindowOnlyForTrackedRelay() {
        var p = PendingEnrollment()
        p.noteAdopted(relay, nowMs: t0)
        p.refresh(relay, nowMs: t0 + 280_000)   // grant arrives late — window re-opens
        XCTAssertTrue(p.isPending(relay, nowMs: t0 + 400_000))
        let other = String(repeating: "d", count: 64)
        p.refresh(other, nowMs: t0)             // never tracked → refresh does not start tracking
        XCTAssertFalse(p.isTracked(other))
    }

    /// The flat gap is per RELAY: after one refusal every loop skips it until the gap elapses —
    /// the e2e fleet saw ~9,000 refusals in 9 minutes from loops that each retried on their own.
    func testRefusalHoldsRelayForTheFlatGap() {
        var p = PendingEnrollment()
        p.noteAdopted(relay, nowMs: t0)
        XCTAssertTrue(p.mayAttempt(relay, nowMs: t0 + 1_000))
        XCTAssertEqual(p.noteRefusal(relay, nowMs: t0 + 1_000), .retrySoon(afterMs: PendingEnrollment.retryGapMs))
        XCTAssertFalse(p.mayAttempt(relay.uppercased(), nowMs: t0 + 1_001))
        XCTAssertFalse(p.mayAttempt(relay, nowMs: t0 + 1_000 + PendingEnrollment.retryGapMs - 1))
        // A refusal from a request already in flight must not push the hold out.
        p.noteRefusal(relay, nowMs: t0 + 5_000)
        XCTAssertTrue(p.mayAttempt(relay, nowMs: t0 + 1_000 + PendingEnrollment.retryGapMs))
    }

    func testGrantOrSuccessLiftsTheHold() {
        var p = PendingEnrollment()
        p.noteAdopted(relay, nowMs: t0)
        p.noteRefusal(relay, nowMs: t0)
        p.releaseHold(relay)
        XCTAssertTrue(p.mayAttempt(relay, nowMs: t0 + 1), "grant/announce re-drive must reach the relay")
        p.noteRefusal(relay, nowMs: t0 + 2)
        XCTAssertTrue(p.confirm(relay))
        XCTAssertTrue(p.mayAttempt(relay, nowMs: t0 + 3), "enrolled — ordinary rules again")
    }

    func testOnlyPendingRelaysAreEverHeld() {
        var p = PendingEnrollment()
        XCTAssertEqual(p.noteRefusal(relay, nowMs: t0), .backOff, "never adopted from a ticket")
        XCTAssertTrue(p.mayAttempt(relay, nowMs: t0 + 1))
        p.noteAdopted(relay, nowMs: t0)
        p.noteRefusal(relay, nowMs: t0 + 1)
        // Past the pending window the hold no longer applies (ordinary health rules take over).
        XCTAssertTrue(p.mayAttempt(relay, nowMs: t0 + PendingEnrollment.windowMs))
    }

    func testTicketTracksEveryTicketRelayAndTheInvitersOwnRelay() {
        let inviter = String(repeating: "e", count: 64)
        let known = [relay, inviter.uppercased(), String(repeating: "f", count: 64)]
        XCTAssertEqual(PendingEnrollment.relaysToTrack(ticketRelays: [relay.uppercased(), relay, "short"],
                                                       inviterHex: inviter, knownRelays: known),
                       [relay, inviter], "already-known ticket relay still tracked; inviter's node is one of our relays")
        XCTAssertEqual(PendingEnrollment.relaysToTrack(ticketRelays: [relay], inviterHex: inviter, knownRelays: [relay]),
                       [relay], "the inviter's id is tracked only when we actually use it as a relay")
    }
}

final class RelayAuthPlanTests: XCTestCase {
    let me = String(repeating: "b", count: 64)
    let own = String(repeating: "0", count: 64)
    let friend = String(repeating: "a", count: 64)
    let friendDevice = String(repeating: "d", count: 64)
    let qa = String(repeating: "9", count: 64)

    /// The stub's approval regression: "default" is authorized ONCE, carrying the friend it just
    /// approved AND the QA allow-list — never re-authorized with the allow-list alone.
    func testStubDefaultKeepsApprovedFriend() {
        let g = RelayAuthPlan.grants(memberships: [("default", [me, friend, friendDevice])],
                                     relaysFor: { _ in [own] }, qaExtra: [qa], isQaStub: true, me: me, ownRelay: own)
        XCTAssertEqual(g.filter { $0.circleId == "default" }.count, 1)
        XCTAssertEqual(Set(g[0].members), Set([me, friend, friendDevice, qa]))
        XCTAssertEqual(g[0].relays, [own])
    }

    func testStubWithNoCirclesStillServesDefault() {
        let g = RelayAuthPlan.grants(memberships: [], relaysFor: { _ in [] }, qaExtra: [qa],
                                     isQaStub: true, me: me, ownRelay: own)
        XCTAssertEqual(g, [.init(circleId: "default", members: [qa, me], relays: [own])])
    }

    func testRegularHostAuthorizesTheGraphOnly() {
        let g = RelayAuthPlan.grants(memberships: [("default", [me, friend]), ("c1", [me])],
                                     relaysFor: { $0 == "default" ? [own] : [] }, qaExtra: [],
                                     isQaStub: false, me: me, ownRelay: own)
        XCTAssertEqual(g, [.init(circleId: "default", members: [me, friend], relays: [own]),
                           .init(circleId: "c1", members: [me], relays: [])])
    }
}

/// The in-app host's mesh pull throttle (ReachPolicy.swift `MeshPullGate`).
final class MeshPullGateTests: XCTestCase {
    /// multirelay "R_B backfilled what it missed while down": 0 s one run, 150 s the next — the
    /// restarted host waited out what was left of the 5-minute window. A restart pulls at once.
    func testARestartedHostPullsOnItsNextTick() {
        var g = MeshPullGate(intervalMs: 300_000)
        XCTAssertTrue(g.take(nowMs: 1_000), "first tick pulls")
        XCTAssertFalse(g.take(nowMs: 60_000), "then throttled")
        g.restarted()
        XCTAssertTrue(g.take(nowMs: 61_000), "hosting came back: pull now")
        XCTAssertFalse(g.take(nowMs: 62_000), "…once; the throttle resumes")
        XCTAssertTrue(g.take(nowMs: 61_000 + 300_000))
    }
}

/// Durable relay announces are keyed by their plaintext (ReachPolicy.swift `RelayAnnounceKey`).
final class RelayAnnounceKeyTests: XCTestCase {
    let relay = String(repeating: "a", count: 64)
    func announce(_ urls: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["node": relay, "addedAt": 5, "urls": urls, "token": "t0k"],
                                    options: [.sortedKeys])
    }

    /// One e2e run left 194 copies of one relay's announce in one circle: every re-announce was a
    /// new mailbox entry. N announces of the same relay must leave ONE entry.
    func testRepeatsOfTheSameAnnounceAreOneEntry() {
        let keys = Set((0..<50).map { _ in RelayAnnounceKey.key(circleId: "cS", nodeHex: relay, plain: announce(["http://a"])) })
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(RelayAnnounceKey.key(circleId: "cS", nodeHex: relay.uppercased(), plain: announce(["http://a"])), keys.first)
        XCTAssertTrue(keys.first!.hasPrefix("haven/mailbox/cS/__relay__/\(relay)/"))
    }

    /// A real change (a rotated URL) is a NEW key, so no reader's seen-cursor hides it; another
    /// circle's copy is its own entry.
    func testAChangedAnnounceOrAnotherCircleIsANewEntry() {
        let a = RelayAnnounceKey.key(circleId: "cS", nodeHex: relay, plain: announce(["http://a"]))
        XCTAssertNotEqual(a, RelayAnnounceKey.key(circleId: "cS", nodeHex: relay, plain: announce(["http://b"])))
        XCTAssertNotEqual(a, RelayAnnounceKey.key(circleId: "cR", nodeHex: relay, plain: announce(["http://a"])))
    }
}

/// `touchHeldKeys` keeps POSTS alive, never control-plane entries (ReachPolicy.swift `MailboxKeepAlive`).
final class MailboxKeepAliveTests: XCTestCase {
    func testOnlyPostsAreKeptAlive() {
        let relay = String(repeating: "a", count: 64)
        XCTAssertTrue(MailboxKeepAlive.isKeepAliveKey("haven/mailbox/cS/\(String(repeating: "b", count: 64))"))
        XCTAssertTrue(MailboxKeepAlive.isKeepAliveKey("haven/mailbox/dm:x-y/\(String(repeating: "c", count: 64))"))
        XCTAssertFalse(MailboxKeepAlive.isKeepAliveKey(RelayAnnounceKey.key(circleId: "cS", nodeHex: relay, plain: Data("x".utf8))))
        XCTAssertFalse(MailboxKeepAlive.isKeepAliveKey("haven/mailbox/cS/__live__/\(relay)/f00d"))
        XCTAssertFalse(MailboxKeepAlive.isKeepAliveKey("haven/mailbox/default/__hello__/\(relay)/\(relay)/beef"))
    }
}

/// Sibling teaching is per circle (ReachPolicy.swift `SiblingTeachPlan`).
final class SiblingTeachPlanTests: XCTestCase {
    let own = String(repeating: "b", count: 64)      // B's in-app relay
    let ra = String(repeating: "a", count: 64)       // A's relay: C_S, C_R
    let rc = String(repeating: "c", count: 64)       // B's second relay: C_S only
    let dead = String(repeating: "d", count: 64)

    /// multirelay: B's second relay is adopted for the shared circle only, so it is taught to A's
    /// relay for C_S — never for C_R (which B was later removed from) or B's private circle.
    func testEachCircleTeachesOnlyItsOwnRelays() {
        let relays: [String: [String]] = ["cS": [ra, rc], "cR": [ra], "cB": []]
        let plan = SiblingTeachPlan.plan(circleIds: ["cS", "cR", "cB"], relaysFor: { relays[$0] ?? [] },
                                         live: [ra, rc, own], myHex: own)
        let byTarget = Dictionary(uniqueKeysWithValues: plan.map { ($0.0, Dictionary(uniqueKeysWithValues: $0.1.map { ($0.0, $0.1) })) })
        XCTAssertEqual(byTarget[ra]?["cS"], [own, rc].sorted())
        XCTAssertEqual(byTarget[ra]?["cR"], [own])
        XCTAssertNil(byTarget[rc]?["cR"], "B's second relay serves no C_R — it is never a C_R sibling")
        XCTAssertEqual(byTarget[rc]?["cS"], [ra, own].sorted())
        XCTAssertEqual(byTarget[own]?["cS"], [ra, rc].sorted())
        XCTAssertNil(byTarget[own]?["cB"], "a circle with only our relay teaches nothing")
    }

    func testDeadRelaysAndSingleRelayCirclesTeachNothing() {
        let plan = SiblingTeachPlan.plan(circleIds: ["solo", "x"], relaysFor: { $0 == "x" ? [dead] : [] },
                                         live: [own], myHex: own)
        XCTAssertTrue(plan.isEmpty)
    }
}

/// Re-teaching until every relay accepts (ReachPolicy.swift `SiblingTeachSchedule`).
final class SiblingTeachScheduleTests: XCTestCase {
    let t0: UInt64 = 1_000_000

    /// e2e `multirelay` rc.4/rc.5: the topology's one lesson was refused (B not yet a member on R_A)
    /// and nothing re-taught for ~5 minutes. A refused lesson must come back on the next tick
    /// after the short retry, not at the next 5-minute mesh pull.
    func testARefusedTopologyIsRetaughtWithinSeconds() {
        var s = SiblingTeachSchedule()
        let g1 = s.begin(topology: "cS=a,c", nowMs: t0)
        XCTAssertNotNil(g1, "a new topology is taught at once")
        s.finish(generation: g1!, allTaught: false, nowMs: t0 + 100)
        XCTAssertNil(s.begin(topology: "cS=a,c", nowMs: t0 + 5_000), "not before the retry is due")
        let g2 = s.begin(topology: "cS=a,c", nowMs: t0 + 100 + SiblingTeachSchedule.retryBaseMs)
        XCTAssertNotNil(g2, "re-taught one retry window later (was: never, until the 5-min pull)")
        s.finish(generation: g2!, allTaught: true, nowMs: t0 + 20_000)
        XCTAssertNil(s.begin(topology: "cS=a,c", nowMs: t0 + 600_000), "an accepted topology is not re-sent")
    }

    func testATopologyChangeTeachesAtOnceAndIgnoresTheStaleResult() {
        var s = SiblingTeachSchedule()
        let old = s.begin(topology: "cS=a", nowMs: t0)!
        XCTAssertNil(s.begin(topology: "cS=a", nowMs: t0 + 1), "one attempt in flight at a time")
        let new = s.begin(topology: "cS=a,c", nowMs: t0 + 2)
        XCTAssertNotNil(new, "a changed topology does not wait for the old attempt")
        s.finish(generation: old, allTaught: true, nowMs: t0 + 3)   // stale: taught the OLD set
        s.finish(generation: new!, allTaught: false, nowMs: t0 + 4)
        XCTAssertNotNil(s.begin(topology: "cS=a,c", nowMs: t0 + 4 + SiblingTeachSchedule.retryBaseMs),
                        "the stale success did not mark the new topology taught")
    }

    /// While membership is expected to land (the first `fastWindowMs` after a change) a refusal is
    /// retried every `retryBaseMs`, so the lesson lands within one retry of the membership — a
    /// doubling backoff there drifted the retry 1–2 minutes past it (14 s instead of 4 s in e2e).
    /// After the window, a relay that never accepts backs off to one try per cap.
    func testAPersistentRefusalRetriesBrisklyThenBacksOffToTheCap() {
        var s = SiblingTeachSchedule()
        var now = t0
        var gaps: [UInt64] = []
        var last = now
        while now - t0 < SiblingTeachSchedule.fastWindowMs + 30 * 60_000 {
            var g = s.begin(topology: "cS=a,old", nowMs: now)
            while g == nil { now += 1_000; g = s.begin(topology: "cS=a,old", nowMs: now) }
            gaps.append(now - last)
            last = now
            s.finish(generation: g!, allTaught: false, nowMs: now)
        }
        let fast = gaps.dropFirst().prefix(Int(SiblingTeachSchedule.fastWindowMs / SiblingTeachSchedule.retryBaseMs) - 1)
        XCTAssertTrue(fast.allSatisfy { $0 == SiblingTeachSchedule.retryBaseMs }, "brisk inside the window: \(Array(fast))")
        XCTAssertEqual(gaps.last, SiblingTeachSchedule.retryCapMs, "an old relay that never accepts costs one try per cap")
        XCTAssertTrue(gaps.dropFirst().allSatisfy { $0 <= SiblingTeachSchedule.retryCapMs })
    }

    func testAnAttemptThatNeverReportsBackDoesNotWedgeTheSchedule() {
        var s = SiblingTeachSchedule()
        XCTAssertNotNil(s.begin(topology: "cS=a,c", nowMs: t0))
        XCTAssertNil(s.begin(topology: "cS=a,c", nowMs: t0 + 60_000))
        XCTAssertNotNil(s.begin(topology: "cS=a,c", nowMs: t0 + SiblingTeachSchedule.retryCapMs))
    }
}

/// Which circle a launch reopens and pulls first (ReachPolicy.swift `LaunchOrder`).
final class LaunchOrderTests: XCTestCase {
    func testRelaunchReopensTheRememberedCircle() {
        let ids = ["default", "c1", "dm:a-b"]
        XCTAssertEqual(LaunchOrder.restoredActiveCircle(saved: "c1", current: "default", circleIds: ids, isDeleted: { _ in false }), "c1")
        XCTAssertEqual(LaunchOrder.restoredActiveCircle(saved: nil, current: "default", circleIds: ids, isDeleted: { _ in false }), "default")
        XCTAssertEqual(LaunchOrder.restoredActiveCircle(saved: "gone", current: "default", circleIds: ids, isDeleted: { _ in false }), "default",
                       "a circle we left is not reopened")
        XCTAssertEqual(LaunchOrder.restoredActiveCircle(saved: "c1", current: "default", circleIds: ids, isDeleted: { $0 == "c1" }), "default",
                       "a deleted circle is not reopened")
        XCTAssertEqual(LaunchOrder.restoredActiveCircle(saved: "dm:a-b", current: "default", circleIds: ids, isDeleted: { _ in false }), "default",
                       "a DM thread is not the feed")
    }

    func testTheActiveCircleIsItsOwnFirstMailboxPhase() {
        XCTAssertEqual(LaunchOrder.mailboxPhases(["default", "c1", "c2"], active: "c1"), [["c1"], ["default", "c2"]])
        XCTAssertEqual(LaunchOrder.mailboxPhases(["c1"], active: "c1"), [["c1"]])
        XCTAssertEqual(LaunchOrder.mailboxPhases(["default", "c2"], active: "c1"), [["default", "c2"]])
    }
}

final class RelayBackoffStepTests: XCTestCase {
    /// Sequential failures, each AFTER the previous window expired, escalate 5s → 10s → … → 5m.
    func testSequentialRetriesEscalateToTheCap() {
        var fails: UInt32 = 0, next: UInt64 = 0, now: UInt64 = 1_000
        var windows: [UInt64] = []
        for _ in 0..<8 {
            guard let s = RelayBackoffStep.next(fails: fails, nextRetryMs: next, now: now) else {
                return XCTFail("a failure after the window expired must escalate")
            }
            (fails, next) = (s.fails, s.nextRetryMs)
            windows.append(s.backoffMs)
            now = next   // the retry happens when the window opens
        }
        XCTAssertEqual(windows, [5_000, 10_000, 20_000, 40_000, 80_000, 160_000, 300_000, 300_000])
    }

    /// gate-4 `newfriend`: seven ops in flight against the inviter's relay all failed together and
    /// parked it for 300 s. A burst inside one window is ONE strike.
    func testBurstInsideOneWindowIsOneStrike() {
        guard let first = RelayBackoffStep.next(fails: 0, nextRetryMs: 0, now: 10_000) else { return XCTFail() }
        XCTAssertEqual(first.backoffMs, 5_000)
        for dt in [1, 50, 900, 4_999] as [UInt64] {
            XCTAssertNil(RelayBackoffStep.next(fails: first.fails, nextRetryMs: first.nextRetryMs, now: 10_000 + dt))
        }
        // The window expired, the retry failed: now (and only now) it escalates.
        let second = RelayBackoffStep.next(fails: first.fails, nextRetryMs: first.nextRetryMs, now: 15_000)
        XCTAssertEqual(second?.fails, 2)
        XCTAssertEqual(second?.backoffMs, 10_000)
    }

    /// A relay that recorded a success (fails reset to 0) starts again at 5 s even if a stale
    /// window stamp were left behind.
    func testFirstFailureAlwaysArms() {
        let s = RelayBackoffStep.next(fails: 0, nextRetryMs: 999_999, now: 1)
        XCTAssertEqual(s?.fails, 1)
        XCTAssertEqual(s?.backoffMs, 5_000)
    }
}

/// A relay that joins a circle is introduced (devroster + member enroll) seconds later, not on the
/// next roster tick / 10-minute enroll gate — the e2e `multirelay` 105–177 s enrollment.
final class RelayIntroductionTests: XCTestCase {
    let ra = String(repeating: "a", count: 64)
    let rb = String(repeating: "b", count: 64)

    /// The first join schedules; further joins inside the debounce ride the same flush.
    func testJoinSchedulesOnceAndCoalesces() {
        var p = RelayIntroduction()
        XCTAssertTrue(p.noteJoined(circleId: "cS", relay: ra, nowMs: 1_000))
        XCTAssertFalse(p.noteJoined(circleId: "cA", relay: ra, nowMs: 1_100))   // already scheduled
        XCTAssertEqual(p.drain(circleIds: ["default", "cA", "cS"]), ["cA", "cS"])
        XCTAssertTrue(p.pendingCircles.isEmpty)
    }

    /// Announce echoes of the same (circle, relay) don't re-introduce inside the gap; after it they do.
    func testSamePairIsRateLimited() {
        var p = RelayIntroduction()
        XCTAssertTrue(p.noteJoined(circleId: "cS", relay: ra, nowMs: 0))
        _ = p.drain(circleIds: ["cS"])
        XCTAssertFalse(p.noteJoined(circleId: "cS", relay: ra.uppercased(), nowMs: 10_000))
        XCTAssertTrue(p.noteJoined(circleId: "cS", relay: rb, nowMs: 10_000))   // a different relay is news
        _ = p.drain(circleIds: ["cS"])
        XCTAssertTrue(p.noteJoined(circleId: "cS", relay: ra, nowMs: RelayIntroduction.reintroduceGapMs + 1))
    }

    /// The all-circles default joins every circle; s3 pseudo-relays and malformed ids are never introduced.
    func testDefaultExpandsAndS3Ignored() {
        var p = RelayIntroduction()
        XCTAssertFalse(p.noteJoined(circleId: "cS", relay: "s3:bucket", nowMs: 0))
        XCTAssertFalse(p.noteJoined(circleId: "cS", relay: "abc", nowMs: 0))
        XCTAssertTrue(p.noteJoined(circleId: RelayIntroduction.allCircles, relay: ra, nowMs: 0))
        XCTAssertEqual(p.drain(circleIds: ["default", "cS"]), ["default", "cS"])
    }

    /// The enroll gate holds only while the relay set is unchanged: a relay added since the last
    /// enroll opens it at once (the old per-circle 10-min gate kept a new relay waiting).
    func testEnrollGateOpensForANewRelay() {
        let enrolled: Set<String> = [rb]
        XCTAssertFalse(RelayIntroduction.enrollDue(nowMs: 60_000, lastMs: 0, lastRelays: enrolled,
                                                   relays: [rb], force: false))
        XCTAssertTrue(RelayIntroduction.enrollDue(nowMs: 60_000, lastMs: 0, lastRelays: enrolled,
                                                  relays: [rb, ra], force: false))
        XCTAssertTrue(RelayIntroduction.enrollDue(nowMs: RelayIntroduction.enrollGapMs, lastMs: 0,
                                                  lastRelays: enrolled, relays: [rb], force: false))
        XCTAssertTrue(RelayIntroduction.enrollDue(nowMs: 1, lastMs: nil, lastRelays: [], relays: [rb], force: false))
        XCTAssertTrue(RelayIntroduction.enrollDue(nowMs: 1, lastMs: 0, lastRelays: enrolled, relays: [rb], force: true))
    }
}
