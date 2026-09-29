import Foundation
import os

/// An in-memory record of which media files are on disk, keyed by file name (`<ref>.<ext>`).
///
/// `MediaStore.has` / `hasLocalFile` answered every question with a `stat`, and the missing-media
/// sweep asks it for every variant of every media ref of every post, every few seconds, on the main
/// thread. Almost every answer is "yes, held" — so this remembers the yeses.
///
/// POSITIVE-ONLY by design. A name in the set means "we saw it on disk / wrote it, and nothing we
/// know of removed it"; absence means "unknown — go and look". Callers stat on a miss and `insert`
/// on a hit, so the set warms itself and is never trusted to say a file is ABSENT. The failure mode
/// that remains is a stale yes, which only happens if a file is deleted by a path that does not
/// call `remove`/`removeAll` — every deletion in the media directory goes through one that does.
///
/// Thread-safe (the limit/orphan sweeps delete off the main actor).
final class HeldMediaIndex: @unchecked Sendable {
    static let shared = HeldMediaIndex()

    private let names = OSAllocatedUnfairLock(initialState: Set<String>())

    init() {}

    func contains(_ name: String) -> Bool { names.withLock { $0.contains(name) } }
    func insert(_ name: String) { names.withLock { _ = $0.insert(name) } }
    func remove(_ name: String) { names.withLock { _ = $0.remove(name) } }
    func removeAll() { names.withLock { $0.removeAll() } }
    var count: Int { names.withLock { $0.count } }

    /// `contains`, falling back to `probe` (the real filesystem check) on a miss and remembering a
    /// positive answer. A negative answer is never cached.
    func held(_ name: String, probe: () -> Bool) -> Bool {
        if contains(name) { return true }
        guard probe() else { return false }
        insert(name)
        return true
    }
}
