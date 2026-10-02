import Foundation
import os

/// How soon a NETWORK-DRIVEN engine export may run, given what the last one cost.
///
/// Field report, 2026-10-02 (owner's iPhone 17 Pro Max, "gets really hot"): the engine state file
/// (`haven-feed.json`) had reached 55 MB, and every ingest burst ended in a whole-state export —
/// a serde encode of 55 MB plus a 55 MB atomic write — 2.5 s after the burst. A mailbox drain is
/// a stream of bursts, so the phone spent the whole sync re-encoding and re-writing the same
/// history. The 2.5 s debounce was sized for a small state; for a large one the gap now scales
/// with what an export actually costs (its size and how long it took), so a drain writes the
/// state a couple of times a minute instead of every few seconds. Nothing is lost by waiting:
/// the seen-marks that depend on the export still wait for it (`persist(then:)`), the keys stay
/// held in memory meanwhile (`awaitingPersist`), backgrounding flushes immediately, and user
/// actions (`persistUserAction`) and authored posts still export at once.
///
/// Small accounts (and the e2e fleet) keep the 2.5 s cadence exactly.
enum PersistCadence {
    /// The classic trailing debounce.
    static let baseDelay: TimeInterval = 2.5
    /// Never hold a network-driven export longer than this.
    static let maxGap: TimeInterval = 45
    /// Below this size the base cadence applies regardless of timing noise.
    static let smallStateBytes = 4 * 1_048_576

    /// Minimum spacing between the END of one export and the START of the next.
    static func minGap(lastBytes: Int, lastDuration: TimeInterval) -> TimeInterval {
        guard lastBytes > smallStateBytes else { return baseDelay }
        let bySize = Double(lastBytes) / 1_048_576 * 0.5          // 0.5 s per MB (55 MB → 27.5 s)
        let byCost = lastDuration * 20                           // keep exports ≤ ~5% duty cycle
        return min(maxGap, max(baseDelay, bySize, byCost))
    }

    /// The debounce to arm now.
    static func delay(lastBytes: Int, lastDuration: TimeInterval, sinceLastEnd: TimeInterval) -> TimeInterval {
        let gap = minGap(lastBytes: lastBytes, lastDuration: lastDuration)
        return max(baseDelay, gap - max(0, sinceLastEnd))
    }

    /// What the last export cost (written by `StatePersister`, read when a debounce is armed).
    struct Stats: Sendable { var bytes = 0; var duration: TimeInterval = 0; var endedAt: TimeInterval = 0 }
    private static let stats = OSAllocatedUnfairLock(initialState: Stats())

    static func record(bytes: Int, duration: TimeInterval, endedAt: TimeInterval = Date().timeIntervalSince1970) {
        stats.withLock { $0 = Stats(bytes: bytes, duration: duration, endedAt: endedAt) }
    }

    /// The debounce for a persist requested now.
    static func currentDelay(now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        let s = stats.withLock { $0 }
        guard s.endedAt > 0 else { return baseDelay }
        return delay(lastBytes: s.bytes, lastDuration: s.duration, sinceLastEnd: now - s.endedAt)
    }
}
