import XCTest

/// The Shazam retry queue's rules. Shazam refuses more often than it fails, and hammering it is what
/// got us refused: backoff must grow, definitive answers must not be retried, and the queue must give up.
final class ShazamRetryPolicyTests: XCTestCase {
    private typealias P = ShazamRetryPolicy
    private func item(_ post: String, due: TimeInterval = 0, attempts: Int = 0) -> P.Item {
        P.Item(postId: post, circleId: "c", videoRef: "vid_\(post)", attempts: attempts, nextAttemptAt: due)
    }

    func testBackoffDoublesFromTwoMinutes() {
        XCTAssertEqual((1...5).map { P.delay(afterAttempt: $0) / 60 }, [4, 8, 16, 32, 64].map(Double.init),
                       "firstDelay * 2^attempts: the first RETRY is already 2x the first delay")
        XCTAssertEqual(P.delay(afterAttempt: 0), P.firstDelay)
        XCTAssertGreaterThan(P.delay(afterAttempt: 5), 3600, "the later attempts outlast a throttling window")
    }

    func testAcceptsOnlyNewPostsWithIds() {
        let existing = [item("p1")]
        XCTAssertTrue(P.accepts(postId: "p2", videoRef: "v", existing: existing))
        XCTAssertFalse(P.accepts(postId: "p1", videoRef: "v", existing: existing), "two entries would attach the same credit twice")
        XCTAssertFalse(P.accepts(postId: "", videoRef: "v", existing: []))
        XCTAssertFalse(P.accepts(postId: "p3", videoRef: "", existing: []))
    }

    func testNextIndexPicksEarliestDue() {
        XCTAssertNil(P.nextIndex([]))
        XCTAssertEqual(P.nextIndex([item("a", due: 500), item("b", due: 100), item("c", due: 300)]), 1)
        XCTAssertEqual(P.nextIndex([item("a", due: 5)]), 0)
    }

    func testWaitIsZeroWhenDueAndCappedWhenFar() {
        XCTAssertEqual(P.wait(until: 100, now: 100), 0)
        XCTAssertEqual(P.wait(until: 50, now: 100), 0)
        XCTAssertEqual(P.wait(until: 130, now: 100), 30)
        XCTAssertEqual(P.wait(until: 100_000, now: 100), P.maxSleep, "never sleep so long a sooner entry goes unnoticed")
    }

    func testRetryOnlyRefusalsAndOnlyBelowTheCap() {
        XCTAssertTrue(P.shouldRetry(refused: true, attemptsSoFar: 0))
        XCTAssertTrue(P.shouldRetry(refused: true, attemptsSoFar: P.maxAttempts - 2))
        XCTAssertFalse(P.shouldRetry(refused: true, attemptsSoFar: P.maxAttempts - 1), "the sixth refusal ends it")
        XCTAssertFalse(P.shouldRetry(refused: true, attemptsSoFar: 50))
        XCTAssertFalse(P.shouldRetry(refused: false, attemptsSoFar: 0), "a definitive answer (not in catalog) never changes")
    }

    func testItemsSurviveAPersistRoundTrip() throws {
        let items = [item("a", due: 12.5, attempts: 2), item("b")]
        let back = try JSONDecoder().decode([P.Item].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(back, items)
    }
}
