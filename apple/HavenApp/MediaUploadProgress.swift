import Foundation

/// How far along each in-flight media upload is, and how many times it has failed.
///
/// Before this, the only thing the UI knew about an upload was `MediaBackupLedger.hasAny(ref)` — a
/// Bool. So a post showed ↑ until it showed ✓, and NOTHING distinguished:
///
///   • a 600 MB video legitimately taking minutes,
///   • an upload creeping along on a bad connection,
///   • an upload retrying the same failure forever (a failed job goes straight back on the queue with
///     no attempt counter and no give-up, so it spins silently until the app is killed),
///   • a post whose media has no bytes at all and can never upload.
///
/// All four rendered as the same motionless arrow, which is exactly why "is it uploading or is it
/// broken?" was unanswerable. The upload already streams in 8 MB windows, so real progress was
/// available the whole time and simply never surfaced.
///
/// Live state only — deliberately not persisted. A relaunch re-derives it from the queue, and a
/// half-finished byte count from a previous run would be a lie about what the relay actually holds
/// (the ledger, which IS persisted, remains the source of truth for "durably stored").
@MainActor
final class MediaUploadProgress: ObservableObject {
    static let shared = MediaUploadProgress()

    struct State {
        var windows: Int      // total 8 MB windows this blob will take
        var done: Int         // windows confirmed written
        var attempts: Int     // how many times we've started this blob
        var fraction: Double { windows > 0 ? min(1, Double(done) / Double(windows)) : 0 }
    }

    /// Attempts past which an upload has stopped looking slow and started looking broken. The queue
    /// itself never gives up (by design — a relay that was unreachable at lunch may be fine by dinner),
    /// so this changes only what the UI SAYS, never whether we keep trying.
    static let stuckAfterAttempts = 3

    @Published private(set) var live: [String: State] = [:]

    func begin(_ ref: String, windows: Int) {
        var s = live[ref] ?? State(windows: windows, done: 0, attempts: 0)
        s.windows = windows
        s.done = 0                     // a retry restarts the blob; don't imply progress we no longer have
        s.attempts += 1
        live[ref] = s
    }

    func advance(_ ref: String, done: Int) {
        guard var s = live[ref] else { return }
        s.done = done
        live[ref] = s
    }

    /// Landed — the ledger takes over from here.
    func finish(_ ref: String) { live[ref] = nil }

    func state(_ ref: String) -> State? { live[ref] }

    /// Progress across a post's blobs: nil when none of them is actively uploading.
    func fraction(for refs: [String]) -> Double? {
        let states = refs.compactMap { live[$0] }
        guard !states.isEmpty else { return nil }
        return states.reduce(0.0) { $0 + $1.fraction } / Double(states.count)
    }

    /// True once any of a post's blobs has restarted enough times to call it stuck rather than slow.
    func looksStuck(_ refs: [String]) -> Bool {
        refs.contains { (live[$0]?.attempts ?? 0) > Self.stuckAfterAttempts }
    }
}
