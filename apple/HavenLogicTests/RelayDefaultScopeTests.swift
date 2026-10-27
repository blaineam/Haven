import XCTest

/// Which circles inherit the all-circles default relay: a friend's relay is withheld from a circle the
/// friend is not in (e2e `multirelay: no private circle's media on a friend's relay that doesn't serve it`).
final class RelayDefaultScopeTests: XCTestCase {
    private let friend = String(repeating: "b3", count: 32)
    private let friendAccount = String(repeating: "b2", count: 32)
    private let own = String(repeating: "c4", count: 32)

    func testRule() {
        let friends: Set<String> = [friend, friendAccount]
        XCTAssertFalse(RelayDefaultScope.rule(relay: friend, circleMembers: [], friends: friends))
        XCTAssertFalse(RelayDefaultScope.rule(relay: friend.uppercased(), circleMembers: [], friends: friends))
        XCTAssertTrue(RelayDefaultScope.rule(relay: friend, circleMembers: [friend, friendAccount], friends: friends))
        XCTAssertTrue(RelayDefaultScope.rule(relay: own, circleMembers: [], friends: friends))
        XCTAssertTrue(RelayDefaultScope.rule(relay: "s3:bucket", circleMembers: [], friends: friends))
    }

    func testSnapshotJudgesEachCircleOnItsOwnMembers() {
        let scope = RelayDefaultScope()
        XCTAssertTrue(scope.inherits(circleId: "cA", relay: friend), "nothing learned yet: nothing is filtered")
        scope.update(members: ["cS": [friend, friendAccount], "cA": []])
        XCTAssertFalse(scope.inherits(circleId: "cA", relay: friend))
        XCTAssertTrue(scope.inherits(circleId: "cS", relay: friend))
        XCTAssertTrue(scope.inherits(circleId: "cA", relay: own))
        XCTAssertFalse(scope.inherits(circleId: "cNew", relay: friend), "an unknown circle is not trusted with a friend's relay")
        scope.learn(circleId: "dm:b", members: [friend])
        XCTAssertTrue(scope.inherits(circleId: "dm:b", relay: friend))
        scope.learn(circleId: "dm:b", members: [])
        XCTAssertTrue(scope.inherits(circleId: "dm:b", relay: friend), "learning never forgets known members")
        scope.reset()
        XCTAssertTrue(scope.inherits(circleId: "cA", relay: friend))
    }

    /// iOS never GUESSES a relay for a circle with no list of its own (Android/desktop's `fallback`): such a
    /// circle uses only the default, and that verdict is recomputed on every call — so a relay that becomes
    /// the default, or membership that arrives late, re-scopes the circle with nothing to retry. Events
    /// authored before that are re-sent by `backfillMailbox` when the relay joins. A friend's relay is still
    /// never taken by a circle the friend is not in, however late things arrive.
    func testKeylessCircleIsReJudgedEachCallSoLateArrivalsNeverStrandIt() {
        let scope = RelayDefaultScope()
        scope.update(members: ["cS": [friend, friendAccount], "cA": []])
        XCTAssertFalse(scope.inherits(circleId: "cA", relay: friend), "A's private circle never takes B's relay")
        XCTAssertTrue(scope.inherits(circleId: "cA", relay: own), "my own relay, adopted later, is usable at once")
        scope.learn(circleId: "cA", members: [])
        scope.update(members: ["cS": [friend, friendAccount], "cA": [], "dm:b": [friend]])   // a late roster/record
        XCTAssertFalse(scope.inherits(circleId: "cA", relay: friend), "late data does not widen the private circle")
        XCTAssertTrue(scope.inherits(circleId: "dm:b", relay: friend))
    }
}
