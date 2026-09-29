import Foundation
import CryptoKit
import os

/// Device-roster envelopes (tag 0x04) this process has already fed to the engine, by content.
///
/// The core's `receive` reports a roster as applied whenever it VERIFIES — including one it already
/// holds — and every hello reply carries the sender's roster verbatim. An idle fleet therefore
/// re-delivered the same roster bytes every ~30 s, and each one read as a new event: a whole-state
/// export, a fan-out to every other device of mine (which re-applied and re-fanned it), and a
/// self-sync push. This only RECOGNISES a repeat: the caller still hands it to the engine (every
/// roster receipt replays parked events) and withholds only the engine export when that landed no
/// events — see `FeedStore.receiveOutcome`. Pure and bounded so HavenLogicTests covers it.
struct RosterEcho: Sendable {
    static let cap = 512
    private var order: [String] = []
    private var seen = Set<String>()

    /// True when these exact bytes were noted before; otherwise notes them and returns false.
    mutating func isRepeat(_ envelope: Data) -> Bool {
        let d = Self.digest(envelope)
        if seen.contains(d) { return true }
        seen.insert(d)
        order.append(d)
        if order.count > Self.cap {
            let drop = order.removeFirst()
            seen.remove(drop)
        }
        return false
    }

    /// Forget `envelope` — its receive did not take (refused / threw), so a later copy must be tried.
    mutating func forget(_ envelope: Data) {
        let d = Self.digest(envelope)
        guard seen.remove(d) != nil else { return }
        order.removeAll { $0 == d }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Process-wide instance for the engine's receive paths (called on the engine actor and from
    /// detached ingest tasks — hence the lock).
    static let shared = OSAllocatedUnfairLock(initialState: RosterEcho())
}
