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
