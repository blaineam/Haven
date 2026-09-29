import Foundation
import os

/// Responsiveness counters the e2e suite reads from the QA dump (`perf`, docs/QA.md).
///
/// Cheap enough to keep in every build (a lock and a few integers); only the DEBUG QA driver ever
/// reads them. The key names in `snapshot()` are a CONTRACT with the e2e orchestrator — do not
/// rename them.
final class HavenPerf: @unchecked Sendable {
    static let shared = HavenPerf()

    private struct State {
        var mainStallCount = 0
        var mainStallMaxMs = 0.0
        /// Ring of the most recent user-lane queue waits (ms).
        var userWaits: [Double] = []
        var userWaitNext = 0
        var persistExportCount = 0
        var lastPersistExportAtMs: UInt64 = 0
        var refreshCount = 0
        var mediaStoreOnMainCount = 0
        /// Exports that ran, by what asked for them ("<function>:<line>").
        var persistReasons: [String: Int] = [:]
        /// State-changing engine calls ("<function>:<line>") — what makes the next persist export.
        var dirtiedBy: [String: Int] = [:]
    }
    private static let userWaitWindow = 512
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A main-thread stall of at least 100 ms (MainThreadStallDetector, DEBUG).
    func noteMainStall(ms: Double) {
        guard ms >= 100 else { return }
        state.withLock { s in
            s.mainStallCount += 1
            s.mainStallMaxMs = max(s.mainStallMaxMs, ms)
        }
    }
    /// How long a user-initiated engine call waited for the engine (announce → body start).
    func noteEngineUserWait(ms: Double) {
        state.withLock { s in
            if s.userWaits.count < Self.userWaitWindow {
                s.userWaits.append(ms)
            } else {
                s.userWaits[s.userWaitNext] = ms
            }
            s.userWaitNext = (s.userWaitNext + 1) % Self.userWaitWindow
        }
    }
    /// A whole-state `exportState()` actually ran (a skipped, unchanged persist does not count).
    func notePersistExport(reason: String = "") {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        state.withLock { s in
            s.persistExportCount += 1
            s.lastPersistExportAtMs = nowMs
            if !reason.isEmpty, s.persistReasons.count < 200 || s.persistReasons[reason] != nil {
                s.persistReasons[reason, default: 0] += 1
            }
        }
    }
    /// An engine call not marked `readOnly` ran (DEBUG attribution for idle exports).
    func noteEngineDirty(_ caller: String) {
        state.withLock { s in
            if s.dirtiedBy.count < 400 || s.dirtiedBy[caller] != nil { s.dirtiedBy[caller, default: 0] += 1 }
        }
    }
    /// A feed rebuild (`FeedStore.refresh`) completed.
    func noteRefresh() { state.withLock { $0.refreshCount += 1 } }
    /// Inbound-media hashing / writing / reassembly ran on the MAIN thread. Should stay 0.
    func noteMediaStoreOnMain() { state.withLock { $0.mediaStoreOnMainCount += 1 } }
    /// Count it if we are on main right now.
    func checkMediaStoreOffMain() { if Thread.isMainThread { noteMediaStoreOnMain() } }

    func reset() { state.withLock { $0 = State() } }
    /// Completed feed rebuilds so far (the QA `react` op waits for this to move).
    var refreshCountNow: Int { state.withLock { $0.refreshCount } }

    /// The dump's `perf` object. `heldRefSetSize` is passed in (it lives in `HeldMediaIndex`).
    func snapshot(heldRefSetSize: Int) -> [String: Any] {
        let s = state.withLock { $0 }
        let sorted = s.userWaits.sorted()
        let p95: Double = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return [
            "mainStallCount": s.mainStallCount,
            "mainStallMaxMs": Int(s.mainStallMaxMs.rounded()),
            "engineUserWaitP95Ms": (p95 * 10).rounded() / 10,
            "engineUserWaitMaxMs": ((sorted.last ?? 0) * 10).rounded() / 10,
            "persistExportCount": s.persistExportCount,
            "lastPersistExportAtMs": s.lastPersistExportAtMs,
            "refreshCount": s.refreshCount,
            "mediaStoreOnMainCount": s.mediaStoreOnMainCount,
            "heldRefSetSize": heldRefSetSize,
            "persistReasons": s.persistReasons,
            // The top state-changing engine callers: a persist that exports while nothing the user
            // can see changed traces back to one of these.
            "engineDirtiedBy": Dictionary(uniqueKeysWithValues:
                s.dirtiedBy.sorted { $0.value > $1.value }.prefix(25).map { ($0.key, $0.value) }),
        ]
    }
}
