import Foundation

/// Where the bell's list and its engine-pull watermark live for this launch — pure rules, Foundation
/// only, so HavenLogicTests covers them without the FFI (`ActivityStore` needs `Engine`).
///
/// A demo launch (`HAVEN_DEMO`) is EPHEMERAL: it neither restores nor writes the real list or the
/// watermark. The demo seeds a brand-new synthetic engine on every launch, stamped relative to *now*
/// (Maya's "coffee after?" DM is five hours old), while the watermark on disk belongs to whatever
/// ran last — the real account, an e2e run, or the previous demo launch. Restoring it narrowed the
/// demo's first pull to "the last hour before that", so every seeded row older than that was never
/// asked for and Activity showed no DM rows at all. It also leaked demo rows into the real list (and
/// real/e2e rows into the demo) through the shared `haven-activity.json`.
enum ActivityPersistence {
    /// How far a pull overlaps what the engine already handed us, so an event that raced the
    /// previous pull is not skipped (`ingest` dedupes by event id, so overlap costs nothing).
    static let pullOverlapMs: UInt64 = 3_600_000

    /// Whether this launch reads and writes `haven-activity.json` + the pull watermark.
    static func isPersistent(isDemo: Bool) -> Bool { !isDemo }

    /// The watermark this launch starts from. 0 means "ask the engine for everything".
    static func restoredWatermark(stored: Double, persistent: Bool) -> UInt64 {
        guard persistent else { return 0 }
        return UInt64(max(0, stored))
    }

    /// The lower bound of the next `activity(sinceMs:)` pull for a given watermark.
    static func pullSince(watermark: UInt64) -> UInt64 {
        watermark > pullOverlapMs ? watermark - pullOverlapMs : 0
    }
}
