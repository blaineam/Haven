import Foundation
import CryptoKit

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

    /// Which relays to treat as PENDING ENROLLMENT when a friend-invite ticket is accepted: every
    /// ticket relay — not only the ones this call newly added (one already known, e.g. from an
    /// earlier scan or a sibling device's sync, refuses us just the same until the inviter enrolls
    /// us) — plus the inviter's own node id when it is one of our relays (a host's relay id is its
    /// node id, and it answers with the same membership gate).
    static func relaysToTrack(ticketRelays: [String], inviterHex: String, knownRelays: [String]) -> [String] {
        let known = Set(knownRelays.map { $0.lowercased() })
        var out: [String] = []
        for h in ticketRelays.map({ $0.lowercased() }) where h.count == 64 && !out.contains(h) { out.append(h) }
        let inviter = inviterHex.lowercased()
        if inviter.count == 64, known.contains(inviter), !out.contains(inviter) { out.append(inviter) }
        return out
    }

    private(set) var adoptedAtMs: [String: UInt64] = [:]
    /// Per-relay "don't touch it again before" after a pending-enrollment refusal. The flat gap has
    /// to be a property of the RELAY, not of one retry loop: the uploader, the media queue, the
    /// hello fan-out, the mailbox poll and every grant/announce re-drive each re-hit the same
    /// refusing relay on their own clocks (×every HTTP URL, ×the iroh fallback) — ~9,000 refusals
    /// in 9 minutes on the e2e fleet with "a flat 12s retry" nominally in force.
    private(set) var holdUntilMs: [String: UInt64] = [:]

    /// A ticket relay was newly adopted (or its window re-opened by a grant / announce).
    mutating func noteAdopted(_ relay: String, nowMs: UInt64) {
        adoptedAtMs[relay.lowercased()] = nowMs
        if adoptedAtMs.count > 64 { adoptedAtMs = adoptedAtMs.filter { nowMs &- $0.value < Self.windowMs } }
    }
    /// Re-open the window only for a relay we are still waiting on (not one already confirmed).
    mutating func refresh(_ relay: String, nowMs: UInt64) {
        if adoptedAtMs[relay.lowercased()] != nil { adoptedAtMs[relay.lowercased()] = nowMs }
    }
    /// Enrollment is (about to be) in place — the grant / an announce: lift the hold so the
    /// re-drive that follows actually reaches the relay instead of skipping it.
    mutating func releaseHold(_ relay: String) {
        holdUntilMs.removeValue(forKey: relay.lowercased())
    }
    /// An authorized write succeeded there — we are enrolled; 403s are ordinary again.
    /// Returns whether the relay WAS being tracked (the caller then re-drives what it deferred).
    @discardableResult
    mutating func confirm(_ relay: String) -> Bool {
        holdUntilMs.removeValue(forKey: relay.lowercased())
        return adoptedAtMs.removeValue(forKey: relay.lowercased()) != nil
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

    /// A refusal from `relay` was observed: same decision as `onFailure(forbidden: true)`, and a
    /// pending relay is then HELD for `retryGapMs` — every loop skips it until the gap elapses (or
    /// the grant / an announce / a successful write lifts it). A refusal inside an existing hold
    /// (a request already in flight) does not push the hold out.
    @discardableResult
    mutating func noteRefusal(_ relay: String, nowMs: UInt64) -> Decision {
        let d = onFailure(relay: relay, forbidden: true, nowMs: nowMs)
        if case .retrySoon(let gap) = d, mayAttempt(relay, nowMs: nowMs) {
            holdUntilMs[relay.lowercased()] = nowMs + gap
        }
        return d
    }

    /// May a loop touch `relay` now? False only while a pending-enrollment hold is running; any
    /// relay that is not pending enrollment is always allowed (ordinary health rules apply).
    func mayAttempt(_ relay: String, nowMs: UInt64) -> Bool {
        guard let until = holdUntilMs[relay.lowercased()] else { return true }
        return nowMs >= until || !isPending(relay, nowMs: nowMs)
    }
}

/// The mailbox key of a durable frame-19 relay announce (`…/__relay__/<relay>/<id>`).
///
/// It used to be the hash of the SEALED payload — and sealing wraps under a fresh random key every
/// time, so every re-announce (each sync cycle, each nearby connect, each relay change) minted a NEW
/// mailbox entry for the same announcement: one e2e run left 194 copies of one relay's announce in
/// one circle, on every relay of that circle, each re-listed by every member poll and re-replicated
/// by every sibling (the backlog that starved the relay mesh). The id is now a hash of the circle,
/// the relay and the announce's PLAINTEXT, so repeats of the same announcement land on one entry
/// (re-PUT = overwrite) while a real change — a rotated URL, a new token — is still a new key that
/// no reader's seen-cursor hides. The plaintext carries the relay's random token, so the id reveals
/// nothing a relay could enumerate.
enum RelayAnnounceKey {
    static func key(circleId: String, nodeHex: String, plain: Data) -> String {
        var h = SHA256()
        h.update(data: Data("haven-relay-announce-v1".utf8))
        for part in [Data(circleId.utf8), Data(nodeHex.lowercased().utf8), plain] {
            var n = UInt32(part.count).littleEndian
            h.update(data: Data(bytes: &n, count: 4))
            h.update(data: part)
        }
        let id = h.finalize().map { String(format: "%02x", $0) }.joined()
        return "haven/mailbox/\(circleId)/__relay__/\(nodeHex.lowercased())/\(id)"
    }
}

/// What an in-app host teaches each relay about its siblings (`RelayHost.teachSiblingRelays`).
/// PER CIRCLE: a relay taught a sibling for a circle lets that sibling replicate the circle's
/// mailbox, so each circle's relays learn only each other. The flat pool (every relay we know, for
/// every circle we are in) made a friend's relay adopted for ONE shared circle a mirror of the rest,
/// and kept it mirroring a circle after the circle's creator removed us from it.
enum SiblingTeachPlan {
    /// target relay → [(circle, that circle's OTHER relays)]. A circle's relays are those it is
    /// configured with that are live now, plus our own hosted relay (`myHex`, which serves every
    /// circle we are in). A circle with a single relay teaches nothing. Deterministic order.
    static func plan(circleIds: [String], relaysFor: (String) -> [String],
                     live: Set<String>, myHex: String) -> [(String, [(String, [String])])] {
        let live = Set(live.map { $0.lowercased() })
        var byTarget: [String: [(String, [String])]] = [:]
        for cid in Set(circleIds).sorted() {
            var set = Set(relaysFor(cid).map { $0.lowercased() }).intersection(live)
            if myHex.count == 64 { set.insert(myHex.lowercased()) }
            guard set.count > 1 else { continue }
            for target in set.sorted() {
                byTarget[target, default: []].append((cid, set.subtracting([target]).sorted()))
            }
        }
        return byTarget.keys.sorted().map { ($0, byTarget[$0] ?? []) }
    }
}

/// What the in-process relay is told to serve, per circle (`RelayHost.authorizeMembership`).
/// `authorize` REPLACES a circle's member set, so every circle must be authorized exactly once,
/// with everything that belongs in it. The matrix QA stub used to authorize "default" a SECOND
/// time with only the driver's allow-list — wiping the friend it had just approved from its own
/// relay, so the new friend's writes stayed 403 until the harness patched the list by hand.
enum RelayAuthPlan {
    struct Grant: Equatable {
        let circleId: String
        let members: [String]
        let relays: [String]
    }

    /// - memberships: (circleId, member + device hexes) from the social graph.
    /// - qaExtra: DEBUG matrix allow-list hexes (empty in release), unioned into every circle.
    /// - isQaStub: the relay-only QA stub, which also serves "default" when its graph has none.
    static func grants(memberships: [(String, [String])], relaysFor: (String) -> [String],
                       qaExtra: [String], isQaStub: Bool, me: String, ownRelay: String) -> [Grant] {
        func union(_ a: [String], _ b: [String]) -> [String] {
            var out = a
            for h in b where !h.isEmpty && !out.contains(h) { out.append(h) }
            return out
        }
        var out: [Grant] = []
        for (cid, members) in memberships where !out.contains(where: { $0.circleId == cid }) {
            var m = union(members, qaExtra)
            var relays = relaysFor(cid)
            if isQaStub, cid == "default" {
                m = union(m, [me])
                relays = union(relays, [ownRelay])
            }
            out.append(Grant(circleId: cid, members: m, relays: relays))
        }
        if isQaStub, !out.contains(where: { $0.circleId == "default" }) {
            let m = union(qaExtra, [me])
            if !m.isEmpty { out.append(Grant(circleId: "default", members: m, relays: union([], [ownRelay]))) }
        }
        return out
    }
}

/// Which circle a launch opens and pulls first. The mailbox pass takes the ACTIVE circle as a phase
/// of its own, ingested and painted before any other — which only helps if "active" is the circle
/// the user was in. It was not remembered across launches, so every relaunch came back on
/// "default" and pulled that first (e2e `launch`: default 2353 ms, the circle on screen 2699 ms).
enum LaunchOrder {
    /// The circle to reopen: the one remembered for this account, when it still exists. DM threads
    /// and deleted circles keep whatever is active already.
    static func restoredActiveCircle(saved: String?, current: String, circleIds: [String],
                                     isDeleted: (String) -> Bool) -> String {
        guard let saved, !saved.isEmpty, saved != current, !saved.hasPrefix("dm:"),
              circleIds.contains(saved), !isDeleted(saved) else { return current }
        return saved
    }

    /// The mailbox pass's phases: the active circle alone first, then everything else.
    static func mailboxPhases(_ ids: [String], active: String) -> [[String]] {
        guard ids.contains(active) else { return [ids] }
        return [[active], ids.filter { $0 != active }].filter { !$0.isEmpty }
    }
}
