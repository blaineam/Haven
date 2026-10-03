import Foundation

// The three guards behind "one fetch of a ref must never get it judged corrupt and blacklisted"
// (desktop fix 85dd646b, ported). Foundation only, so HavenLogicTests covers them host-less.
//
// The failure they close: two lanes fetch the same small companion at the same moment (the fresh
// lane, the thumb sweep, a tap, the relay-history resync). Each one either races the other on the
// same on-disk file — a non-atomic write truncates before it refills, so a concurrent reader sees
// 0 bytes or half a blob — or is handed an empty relay body and treats it as a stored copy. Either
// way the copy "fails to open", the ref goes into `unopenableMedia`, and the relay half of every
// lane skips it for the rest of the session.

/// One in-flight run per key. A caller that finds a run for the same key already going awaits the
/// LEADER's result instead of starting a second one into the same files.
///
/// The entry is removed inside the leader's own task, on the main actor, in the same step that
/// produces the value — so a caller only ever joins a run that is genuinely still going, never a
/// finished one that happened not to be cleaned up yet.
@MainActor
final class SingleFlight<Value: Sendable> {
    private var flights: [String: (id: UUID, task: Task<Value, Never>)] = [:]

    init() {}

    func run(_ key: String, _ body: @escaping @Sendable @MainActor () async -> Value) async -> Value {
        if let running = flights[key] { return await running.task.value }
        let id = UUID()
        let task = Task { @MainActor [weak self] () -> Value in
            let value = await body()
            if self?.flights[key]?.id == id { self?.flights[key] = nil }
            return value
        }
        flights[key] = (id, task)
        return await task.value
    }

    func inFlight(_ key: String) -> Bool { flights[key] != nil }
}

/// What a relay / S3 / own-store GET handed back, as far as media is concerned.
enum RelayMediaBody {
    /// A 200 with an EMPTY body is a miss, not a stored copy: nothing sealed is zero bytes, and
    /// opening nothing is what produced "found (0B) but OPEN FAILED" and a session-long blacklist.
    static func usable(_ body: Data?) -> Data? {
        guard let body, !body.isEmpty else { return nil }
        return body
    }

    /// Whether a fetched blob that failed to open may be recorded as unopenable. Only bytes that
    /// were actually there can be "bad"; an empty blob is a miss, and condemning it would stop every
    /// retry for a ref that may be perfectly fine on the relay.
    static func mayCondemn(_ blob: Data) -> Bool { !blob.isEmpty }
}

enum AtomicFile {
    /// Move `src` over `dst` in ONE step (rename(2)): a reader sees the old file or the new one,
    /// never a missing or half-written one. `FileManager.moveItem` refuses an existing destination,
    /// so the old idiom was remove-then-move — a window in which the ref looked absent, and in which
    /// a second adopter's move failed outright. Both paths must be on the same volume.
    @discardableResult
    static func replace(_ dst: URL, with src: URL) -> Bool {
        if rename(src.path, dst.path) == 0 { return true }
        // Different volume (EXDEV) or similar: the old non-atomic idiom beats losing the bytes.
        guard errno == EXDEV else { return false }
        try? FileManager.default.removeItem(at: dst)
        return (try? FileManager.default.moveItem(at: src, to: dst)) != nil
    }
}
