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
