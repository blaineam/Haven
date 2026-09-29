import Foundation

/// Pure policy for reaching peers and relays fast — no FeedStore, no FFI, so HavenLogicTests covers
/// it host-less. Two rules live here because both were "serial by accident" slowness:
///
/// * `BoundedFanOut` — run a relay/peer operation over many targets with a bounded number in flight,
///   so one dead relay's 20–60s timeout overlaps the others instead of delaying all of them.
/// * `DialOrder` — which ids to dial for an account, best-first, and when the bare account id is
///   dead weight.
enum BoundedFanOut {
    /// Run `op` over `items` with at most `limit` in flight; results come back in INPUT order.
    /// Children are main-actor isolated (every relay/mailbox helper in the app is), so shared state
    /// stays exactly where it always lived — the concurrency comes from the I/O inside each op
    /// suspending, which lets one slow request overlap the rest instead of serializing them.
    @MainActor
    static func run<I: Sendable, T: Sendable>(_ items: [I], limit: Int,
                                              _ op: @escaping @Sendable @MainActor (I) async -> T) async -> [T] {
        guard !items.isEmpty else { return [] }
        var results = [T?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, T).self) { group in
            var next = 0
            func launch() {
                let i = next
                let item = items[i]
                next += 1
                group.addTask { @MainActor in (i, await op(item)) }
            }
            while next < items.count, next < max(1, limit) { launch() }
            while let (i, r) = await group.next() {
                results[i] = r
                if next < items.count { launch() }
            }
        }
        return results.compactMap { $0 }
    }
}

enum DialOrder {
    /// The dial set for one account, best-first: invite-link hints (the ids a brand-new friend
    /// actually answers on), then roster device ids, then the bare ACCOUNT id.
    ///
    /// The account id is DROPPED when the account came with invite hints: only per-device builds
    /// mint hints, and under per-device transport the account id resolves to no endpoint — dialing
    /// it bought a guaranteed connect timeout plus a dial-gate strike on every send to a new friend.
    /// With a roster but no hints it stays, LAST (the core keeps it in `device_node_ids_for` on
    /// purpose: dropping it once stranded pre-multidevice peers and half-learned rosters); sends are
    /// concurrent, so a dead one no longer delays the live ones. Lowercased and de-duplicated.
    static func targets(account: String, resolved: [String], hints: [String]) -> [String] {
        let acct = account.lowercased()
        var out: [String] = []
        func add(_ h: String) {
            let l = h.lowercased()
            if !l.isEmpty, !out.contains(l) { out.append(l) }
        }
        for h in hints where h.lowercased() != acct { add(h) }
        let hinted = !out.isEmpty
        for d in resolved where d.lowercased() != acct { add(d) }
        if !hinted || out.isEmpty { add(acct) }
        return out
    }
}

/// Relays adopted from a friend-invite ticket answer 403 to our uploads until the inviter approves
/// us and enrolls our ids there. That refusal is EXPECTED and short-lived, so it must not feed the
/// long backoffs built for dead or hostile relays (media 2 min → 1 h, relay stand-down, uploader
/// doubling) — the new friend's first photos would wait out the longest of them. While a relay is
/// "pending enrollment" (adopted from a ticket, not yet confirmed by a successful authorized write,
/// within `windowMs` of adoption) a 403 from it means "retry soon", and nothing else.
struct PendingEnrollment {
    static let windowMs: UInt64 = 300_000     // treat 403 as "not yet" for ~5 min after adoption
    static let retryGapMs: UInt64 = 12_000    // …retrying on this short, FLAT gap (no escalation)

    enum Decision: Equatable {
        case retrySoon(afterMs: UInt64)   // pending enrollment: no strike, no long backoff
        case backOff                      // the ordinary path (outage, or a genuine refusal)
    }

    private(set) var adoptedAtMs: [String: UInt64] = [:]

    /// A ticket relay was newly adopted (or its window re-opened by a grant / announce).
    mutating func noteAdopted(_ relay: String, nowMs: UInt64) {
        adoptedAtMs[relay.lowercased()] = nowMs
        if adoptedAtMs.count > 64 { adoptedAtMs = adoptedAtMs.filter { nowMs &- $0.value < Self.windowMs } }
    }
    /// Re-open the window only for a relay we are still waiting on (not one already confirmed).
    mutating func refresh(_ relay: String, nowMs: UInt64) {
        if adoptedAtMs[relay.lowercased()] != nil { adoptedAtMs[relay.lowercased()] = nowMs }
    }
    /// An authorized write succeeded there — we are enrolled; 403s are ordinary again.
    /// Returns whether the relay WAS being tracked (the caller then re-drives what it deferred).
    @discardableResult
    mutating func confirm(_ relay: String) -> Bool {
        adoptedAtMs.removeValue(forKey: relay.lowercased()) != nil
    }
    func isTracked(_ relay: String) -> Bool { adoptedAtMs[relay.lowercased()] != nil }
    func isPending(_ relay: String, nowMs: UInt64) -> Bool {
        guard let at = adoptedAtMs[relay.lowercased()], nowMs >= at else { return false }
        return nowMs - at < Self.windowMs
    }
    func anyPending(nowMs: UInt64) -> Bool { adoptedAtMs.keys.contains { isPending($0, nowMs: nowMs) } }

    /// How to treat a failed op against `relay`. Only a REFUSAL from a still-pending relay is
    /// special; an outage (no answer) is not evidence of anything enrollment will fix.
    func onFailure(relay: String, forbidden: Bool, nowMs: UInt64) -> Decision {
        forbidden && isPending(relay, nowMs: nowMs) ? .retrySoon(afterMs: Self.retryGapMs) : .backOff
    }
}
