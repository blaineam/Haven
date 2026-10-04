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

/// One step of the per-relay exponential backoff (`RelayHealth`): 5s, 10s, 20s … capped at 5m.
///
/// ONE OUTAGE, ONE STRIKE. A failure that lands while the relay is already parked in a window does
/// not escalate it: every op that was in flight when the relay went quiet (a fan-out of mailbox
/// lists, a media probe, a self-sync slot, a hello) fails a moment later, and each used to count as
/// its own consecutive failure. Seven of them in one burst jumped a relay straight from 5 s to the
/// 5-minute cap — the e2e `newfriend` step watched the inviter's relay parked for 300 s within 80 s
/// of approval (gate-4), though sequential strikes cannot reach that cap in under ~5 minutes. Only
/// a failure AFTER the window has expired (a real retry that failed again) escalates.
enum RelayBackoffStep {
    static let baseMs: UInt64 = 5_000
    static let maxMs: UInt64 = 300_000

    /// The next state after a failure at `now`, or nil when it falls inside the armed window and so
    /// changes nothing.
    static func next(fails: UInt32, nextRetryMs: UInt64, now: UInt64)
        -> (fails: UInt32, nextRetryMs: UInt64, backoffMs: UInt64)? {
        if fails > 0, now < nextRetryMs { return nil }
        let f = fails == UInt32.max ? fails : fails + 1
        let shift = UInt64(min(f - 1, 6))   // cap the exponent so the shift never overflows
        let backoff = min(baseMs * (1 << shift), maxMs)
        return (f, now + backoff, backoff)
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

/// A relay that just JOINED one of our circles (adopted, announced by a member, synced from a sibling
/// device, or made the all-circles default) serves nobody until it has been introduced: it needs our
/// account-signed device roster (so it authorizes THIS device's id, not only the account id its link
/// named) and, from a member it already serves, the circle's member list (`enrollMembers`). Both ran
/// only on timers — the roster on the media-backfill tick (2–3 min), the enroll behind a 10-minute
/// per-CIRCLE gate that a brand-new relay for an already-enrolled circle could not open. So a friend
/// waited out whatever was left of the roster tick before the new relay answered them (e2e
/// `multirelay`: B enrolled on R_A 105 s / 168 s / 177 s after adoption — purely the tick's phase).
/// Now the join itself schedules the introduction a beat later (coalescing a burst of announces).
struct RelayIntroduction {
    /// Coalesce a burst (one announce adds the relay to several circles; adoption also sets the default).
    static let debounceMs: UInt64 = 1_500
    /// A relay that keeps re-joining (announce echoes after a forget/re-add) is introduced at most this often.
    static let reintroduceGapMs: UInt64 = 30_000
    /// The member enroll's steady-state gate: the set changes rarely, so once per 10 min is plenty.
    static let enrollGapMs: UInt64 = 600_000

    /// Circle id meaning "every circle" — a relay made the all-circles default joined all of them.
    static let allCircles = "*"

    private(set) var introducedAtMs: [String: UInt64] = [:]   // "circle|relay" → last introduction
    private(set) var pendingCircles: Set<String> = []

    /// `relay` joined `circleId`. Returns true when an introduction must be scheduled (the caller
    /// debounces by `debounceMs`, then calls `drain`). A join of the same pair inside
    /// `reintroduceGapMs` is ignored; an s3 pseudo-relay is never introduced (it has no auth map).
    mutating func noteJoined(circleId: String, relay: String, nowMs: UInt64) -> Bool {
        let r = relay.lowercased()
        guard r.count == 64, !r.hasPrefix("s3:"), !circleId.isEmpty else { return false }
        let key = circleId + "|" + r
        if let at = introducedAtMs[key], nowMs &- at < Self.reintroduceGapMs { return false }
        introducedAtMs[key] = nowMs
        let wasIdle = pendingCircles.isEmpty
        pendingCircles.insert(circleId)
        return wasIdle
    }

    /// The circles to introduce now (`allCircles` expanded against `circleIds`), clearing the queue.
    mutating func drain(circleIds: [String]) -> [String] {
        defer { pendingCircles.removeAll() }
        if pendingCircles.contains(Self.allCircles) { return circleIds }
        return circleIds.filter { pendingCircles.contains($0) }
    }

    /// The member-enroll gate. Due when forced, never enrolled, the circle's relay set gained a relay
    /// since the last enroll (that relay has never heard the list), or `enrollGapMs` has passed.
    static func enrollDue(nowMs: UInt64, lastMs: UInt64?, lastRelays: Set<String>, relays: [String],
                          force: Bool) -> Bool {
        if force { return true }
        guard let lastMs else { return true }
        if relays.contains(where: { !lastRelays.contains($0.lowercased()) }) { return true }
        return nowMs &- lastMs >= enrollGapMs
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

/// When the in-app host pulls from its sibling relays (`RelayHost.meshSyncTick`). The pull is
/// expensive (a sibling's whole inventory), so it is throttled to once per `intervalMs` — but a host
/// that was OFF missed everything posted meanwhile, and waiting out whatever was left of that window
/// made its catch-up land anywhere from 0 s to 5 min after it came back (e2e `multirelay`, "R_B
/// backfilled what it missed while down": 0.0 s one run, 150 s the next). `restarted` makes the next
/// tick due at once.
struct MeshPullGate {
    let intervalMs: UInt64
    private(set) var lastMs: UInt64 = 0
    private var dueNow = true

    init(intervalMs: UInt64) { self.intervalMs = intervalMs }

    /// Hosting (re)started: the next tick pulls immediately.
    mutating func restarted() { dueNow = true }

    /// Whether this tick should pull; stamps the pull when it does.
    mutating func take(nowMs: UInt64) -> Bool {
        guard dueNow || nowMs &- lastMs >= intervalMs else { return false }
        dueNow = false
        lastMs = nowMs
        return true
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

/// When the in-app host teaches its relays their siblings again (`RelayHost.meshSyncTick`).
///
/// Teaching used to be fire-and-forget: a topology change was marked taught the moment the
/// lessons were SENT. A relay refuses a lesson from someone it does not yet count as a member of
/// that circle, and membership on a freshly adopted relay lands a little after the relay itself
/// (the member's device roster / enrollment arrives on its own schedule). So the one lesson sent
/// on the topology change was refused, the topology was already marked taught, and nothing
/// re-taught until the 5-minute mesh pull — the relay meshed with nobody until then. e2e
/// `multirelay` ("R_A pulls a fresh key from its sibling R_C"): 4–12 s through rc.3, 94–135 s
/// from rc.4, where the lesson was refused 12 s before B's enrollment on R_A completed.
///
/// A topology is now taught until every lesson is ACCEPTED: a refused lesson is retried every
/// `retryBaseMs` for `fastWindowMs` after the topology changed — the window in which the missing
/// membership normally lands; a doubling backoff there let the retry drift 1–2 minutes past it —
/// then doubling to `retryCapMs` (a relay that keeps refusing — an older one with no teaching
/// verb, or a circle we are not a member of there — costs one round trip per cap window, like the
/// gated pull already spends). A new topology starts over at once. (Android and desktop re-teach
/// on every mesh pass, so they never lost a refused lesson; only this topology gate could.)
struct SiblingTeachSchedule {
    static let retryBaseMs: UInt64 = 15_000
    static let retryCapMs: UInt64 = 300_000
    static let fastWindowMs: UInt64 = 600_000

    private(set) var topology = ""
    private var changedAtMs: UInt64 = 0
    private var generation = 0
    private var confirmed = false
    private var inFlight = false
    private var inFlightSinceMs: UInt64 = 0
    private var failStreak: UInt32 = 0
    private var retryAtMs: UInt64 = 0

    /// Should this tick teach `topology`? Returns the attempt's generation (hand it back to
    /// `finish`), or nil when the topology is already taught, an attempt is in flight, or the
    /// retry after a refusal is not due yet.
    mutating func begin(topology t: String, nowMs: UInt64) -> Int? {
        if t != topology || changedAtMs == 0 {
            topology = t
            changedAtMs = nowMs
            confirmed = false
            inFlight = false   // a still-running attempt taught the OLD topology; its result is stale
            failStreak = 0
            retryAtMs = 0
        }
        // An attempt that never reported back (a dial wedged past every timeout) stops blocking
        // the retry after one cap window.
        let stuck = inFlight && nowMs &- inFlightSinceMs >= Self.retryCapMs
        guard !confirmed, !inFlight || stuck, nowMs >= retryAtMs else { return nil }
        inFlight = true
        inFlightSinceMs = nowMs
        generation += 1
        return generation
    }

    /// The attempt `generation` finished: every lesson accepted (`allTaught`), or not.
    mutating func finish(generation g: Int, allTaught: Bool, nowMs: UInt64) {
        guard g == generation, inFlight else { return }   // superseded by a newer topology
        inFlight = false
        if allTaught {
            confirmed = true
            failStreak = 0
        } else {
            failStreak += 1
            let backoff = nowMs &- changedAtMs < Self.fastWindowMs
                ? Self.retryBaseMs
                : min(Self.retryBaseMs << UInt64(min(failStreak - 1, 5)), Self.retryCapMs)
            retryAtMs = nowMs &+ backoff
        }
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
