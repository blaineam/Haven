import Foundation
import CryptoKit

/// Relay announces (frame 19) that arrived BEFORE this device held the circle's key.
///
/// A relay announce is sealed to the circle, so a freshly (re)installed device that has not yet
/// received the circle's key material cannot open it — and `handleRelayNode` used to `return`,
/// dropping it for good. That is the only way a new device ever learns its FIRST relay (an invite
/// carries device ids, not a relay, and self-sync needs a transport), so a device whose first
/// announce raced its key ran relay-less indefinitely. Park them (bounded, expiring, de-duplicated)
/// and re-process when keys may have landed.
///
/// Pure and clock-injected so the rules are unit-testable. Same constants and semantics as Android's
/// `RelayAnnounceParking` and desktop's `relayparking.rs` — keep the three in step.
final class RelayAnnounceParking: @unchecked Sendable {
    struct Parked: Equatable {
        let circleId: String
        let sealed: Data
        let parkedAtMs: UInt64
    }

    private let capacity: Int
    private let ttlMs: UInt64
    private let minRetryGapMs: UInt64
    private let lock = NSLock()
    private var order: [String] = []                 // oldest → newest (insertion / re-park recency)
    private var items: [String: Parked] = [:]
    private var drained = false
    private var lastDrainMs: UInt64 = 0

    init(capacity: Int = 64, ttlMs: UInt64 = 60 * 60_000, minRetryGapMs: UInt64 = 5_000) {
        self.capacity = capacity
        self.ttlMs = ttlMs
        self.minRetryGapMs = minRetryGapMs
    }

    /// Park an announce; the same sealed bytes are kept once. Oldest are evicted past `capacity`.
    func park(circleId: String, sealed: Data, nowMs: UInt64) {
        let digest = SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined().prefix(24)
        let key = circleId + "|" + digest
        lock.lock(); defer { lock.unlock() }
        if items.removeValue(forKey: key) != nil { order.removeAll { $0 == key } }   // re-park refreshes recency
        items[key] = Parked(circleId: circleId, sealed: sealed, parkedAtMs: nowMs)
        order.append(key)
        while items.count > capacity, let oldest = order.first {
            order.removeFirst()
            items.removeValue(forKey: oldest)
        }
    }

    /// The parked announces to re-process now: none until `minRetryGapMs` has passed since the last
    /// drain, expired ones are dropped, and the returned ones are REMOVED (a still-unopenable one is
    /// simply parked again by the caller, keeping its place in the bounded queue).
    func drain(nowMs: UInt64) -> [Parked] {
        lock.lock(); defer { lock.unlock() }
        if items.isEmpty || (drained && nowMs &- lastDrainMs < minRetryGapMs) { return [] }
        drained = true
        lastDrainMs = nowMs
        var out: [Parked] = []
        for key in order {
            if let p = items[key], nowMs &- p.parkedAtMs <= ttlMs { out.append(p) }
        }
        items.removeAll()
        order.removeAll()
        return out
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

/// Media for a circle this device knows NO relay for (a freshly installed device that has not yet
/// learned the circle's relay — frame 19 — or whose announce has not landed). Mirrors Android's
/// `NoRelayMediaPolicy` and desktop's `relayparking.rs`.
///
///  1. A fetch that asked ZERO relays proved nothing: it must not claim "the relays answered and
///     none holds it" (the "Waiting for sender…" lie) — say "Finding a relay…" instead.
///  2. A relay HINT ("it's on a relay, fetch it there") is useless to a device with no relay. Re-ask
///     the author right away (spaced, capped at the author's hint budget) so they reach "hints
///     exhausted" and stream the bytes straight over.
///  3. The hint proves the author has a relay for the circle, so nudge them to re-announce it (a
///     Hello) — rate-limited per (author, circle).
enum NoRelayMediaPolicy {
    /// Re-asks one ref gets after hints while no relay is known (the author's hint budget).
    static let maxReasksPerRef = HeavyWorkPolicy.maxRelayHints
    /// Spacing between re-asks of the same ref.
    static let reaskSpacingMs: UInt64 = 4_000
    /// One relay-introduction nudge per (author, circle) at most this often.
    static let introNudgeEveryMs: UInt64 = 10 * 60_000

    /// Only a fetch that actually asked at least one relay may claim "the relays answered and none holds it".
    static func relaysAnsweredEmpty(relaysAsked: Int) -> Bool { relaysAsked > 0 }

    /// Re-ask the author right away after a hint we cannot act on.
    static func reAskAfterUnusableHint(hasRelay: Bool, priorReasks: Int, lastReaskMs: UInt64?, nowMs: UInt64) -> Bool {
        if hasRelay { return false }
        if priorReasks >= maxReasksPerRef { return false }
        guard let last = lastReaskMs else { return true }
        return nowMs &- last >= reaskSpacingMs
    }

    /// Ask the author to (re)announce their circle relay to us.
    static func introNudgeDue(hasRelay: Bool, lastNudgeMs: UInt64?, nowMs: UInt64) -> Bool {
        if hasRelay { return false }
        guard let last = lastNudgeMs else { return true }
        return nowMs &- last >= introNudgeEveryMs
    }
}
