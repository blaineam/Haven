import Foundation

/// The queue rules behind `ShazamRetryQueue`, without Shazam, the media store or the feed: which
/// entries are accepted, which is drained next, how long to back off, and when to give up. The worker
/// itself (network + attach) stays in the queue.
enum ShazamRetryPolicy {
    /// The first RETRY waits a while on purpose. Being refused means Shazam wants us to stop asking,
    /// and trying again immediately is what got us refused in the first place.
    static let firstDelay: TimeInterval = 120
    /// Give up after this many refusals. Six attempts spans roughly an hour of backoff, which is
    /// long enough to outlast a throttling window without retrying forever.
    static let maxAttempts = 6
    /// The worker never sleeps longer than this in one go, so a newly queued sooner entry is noticed.
    static let maxSleep: TimeInterval = 300

    /// One parked post.
    struct Item: Codable, Equatable {
        let postId: String
        let circleId: String
        /// The STAGED media ref, not a temp path: temp clips are deleted as soon as a post is staged.
        let videoRef: String
        var attempts: Int
        var nextAttemptAt: TimeInterval
    }

    /// Idempotent per post, and both ids must be present: an import can stage the same post twice
    /// across a resume, and two entries would mean two edits attaching the same credit.
    static func accepts(postId: String, videoRef: String, existing: [Item]) -> Bool {
        guard !postId.isEmpty, !videoRef.isEmpty else { return false }
        return !existing.contains(where: { $0.postId == postId })
    }

    /// Exponential: 2m, 4m, 8m, 16m, 32m for attempts 1…5.
    static func delay(afterAttempt attempts: Int) -> TimeInterval {
        firstDelay * pow(2, Double(attempts))
    }

    /// Earliest-due first, so a long backoff on one post doesn't hold up the others.
    static func nextIndex(_ items: [Item]) -> Int? {
        items.indices.min(by: { items[$0].nextAttemptAt < items[$1].nextAttemptAt })
    }

    /// How long to sleep before the item is due (0 when due now), capped.
    static func wait(until due: TimeInterval, now: TimeInterval) -> TimeInterval {
        let w = due - now
        return w > 0 ? min(w, maxSleep) : 0
    }

    /// A definitive answer is not worth retrying — only a refusal is, and only up to `maxAttempts`.
    static func shouldRetry(refused: Bool, attemptsSoFar: Int) -> Bool {
        refused && attemptsSoFar + 1 < maxAttempts
    }
}
