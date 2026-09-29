import Foundation

// Pure decisions behind the sync / transfer progress UI — Foundation only, so HavenLogicTests covers
// them on the host Mac with no simulator, FeedStore or FFI.
//
// Field report: "The app has UX for showing sync statuses and progress but it doesn't appear to
// actually ever progress at all and just disappears after a bit." Each type here replaces a piece of
// that UI's old source of truth with one that tracks real work:
//
//   • SyncBadgeState — the composer pill. It used to be "yellow while ANY upload pass runs", and every
//     foreground launch runs one (epoch heads for every circle), so it flashed "Syncing…" with no count
//     and then vanished even when the user's own post had failed and was waiting in backoff.
//   • TransferStallWatch — media spinners. They were cleared on a fixed 45s timer, or the moment the
//     relay missed, while a direct peer transfer was still delivering chunks.
//   • MediaWantedSet — "media waiting". It was the size of one scan's `missing` map, which covers the
//     active circle plus ONE rotating other circle, so the number jumped around every 2s.

/// Snapshot of the authored-event upload queue (published by `BackgroundUploader`).
///
/// Counts only USER content — posts, comments, reactions, messages. Maintenance items (the epoch heads
/// every launch re-publishes for every circle) still upload, but they are nothing the user did and
/// nothing they are waiting for, so they never move the badge.
struct UploadProgress: Equatable, Sendable {
    /// User items still waiting for a mailbox, per circle.
    var pendingByCircle: [String: Int] = [:]
    /// A flush pass is running right now.
    var flushing = false
    /// This pass: user items it set out to send, and how many have landed, per circle.
    var flushTotalByCircle: [String: Int] = [:]
    var flushDoneByCircle: [String: Int] = [:]
    /// The last pass ended with user items still pending: they wait on a backoff timer (or are in the
    /// retry pass that timer started). Cleared by a pass that lands everything.
    var backingOff = false
    /// Media blobs of posts you just authored still on their way to a relay, per circle
    /// (`MediaBackupQueue`'s fresh-post lane). The event envelope is a few KB and lands in well under
    /// a second; the photo or video it names is what actually takes time — a pill that ignored it
    /// said "Synced" while your video was still uploading.
    var mediaPendingByCircle: [String: Int] = [:]

    /// Authored EVENTS still waiting for a mailbox.
    func pending(_ circleId: String) -> Int { pendingByCircle[circleId] ?? 0 }
    /// Authored media blobs still waiting for a relay.
    func mediaPending(_ circleId: String) -> Int { mediaPendingByCircle[circleId] ?? 0 }
    /// Everything of yours the pill is waiting on.
    func totalPending(_ circleId: String) -> Int { pending(circleId) + mediaPending(circleId) }
}

/// What the composer's sync pill says for one circle.
enum SyncBadgeState: Equatable, Sendable {
    /// Nothing of yours is waiting (or there is no relay to wait for and you're reachable).
    case synced
    /// An upload pass is sending this circle's items right now: `done` of `total` landed.
    case sending(done: Int, total: Int)
    /// Items are queued and a pass is about to take them.
    case queued(pending: Int)
    /// The last attempt failed; items wait on the retry timer.
    case retrying(pending: Int)
    /// Offline with nowhere to deliver: your content is on this device only.
    case deviceOnly

    static func derive(progress p: UploadProgress, circleId: String, hostsRelay: Bool, hasRelay: Bool,
                       nearbyConnected: Bool, online: Bool) -> SyncBadgeState {
        // This device IS the circle's relay: the mailbox is on this machine.
        if hostsRelay { return .synced }
        if hasRelay {
            let pending = p.totalPending(circleId)
            guard pending > 0 else { return .synced }
            // Can't reach any relay at all: the queue is real, but it is going nowhere until we're back.
            if !online && !nearbyConnected { return .deviceOnly }
            if p.backingOff { return .retrying(pending: pending) }
            if p.flushing, let total = p.flushTotalByCircle[circleId], total > 0 {
                return .sending(done: min(p.flushDoneByCircle[circleId] ?? 0, total), total: total)
            }
            return .queued(pending: pending)
        }
        // No relay: posts go best-effort straight to whoever's reachable — there is no upload to track.
        if nearbyConnected || online { return .synced }
        return .deviceOnly
    }

    /// The QA dump's word for the state (docs/QA.md "Progress fields").
    var dumpState: String {
        switch self {
        case .synced: return "synced"
        case .sending, .queued: return "syncing"
        case .retrying: return "retrying"
        case .deviceOnly: return "local"
        }
    }
    /// Finer than `dumpState`: which syncing it is.
    var detail: String {
        switch self {
        case .synced: return "synced"
        case .sending(let d, let t): return "sending \(d)/\(t)"
        case .queued(let n): return "queued \(n)"
        case .retrying(let n): return "retrying \(n)"
        case .deviceOnly: return "local"
        }
    }
}

/// Bounded log of the pill's transitions (QA dump `sync_badge_history`).
///
/// The e2e `progress` step sampled the pill every few hundred ms and never once saw it leave
/// "synced": a small post's upload starts and finishes between two samples. Recording every
/// change where it happens makes "it went synced → syncing → synced" provable instead of a race.
struct SyncBadgeHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var circle: String
        var state: String
        var detail: String
        var pending: Int
        var atMs: UInt64
    }
    static let cap = 20
    private(set) var entries: [Entry] = []

    /// Append when what the pill shows changed (same circle, state, detail and count = no entry).
    mutating func record(circle: String, _ badge: SyncBadgeState, pending: Int, atMs: UInt64) {
        let e = Entry(circle: circle, state: badge.dumpState, detail: badge.detail, pending: pending, atMs: atMs)
        if let last = entries.last, last.circle == e.circle, last.state == e.state,
           last.detail == e.detail, last.pending == e.pending { return }
        entries.append(e)
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
    }
}

/// No-progress watchdog for one media transfer.
///
/// A spinner comes down when bytes arrive or when the transfer has genuinely stopped — never on a
/// fixed timer. `progress` is any number that grows as bytes land (chunks held by a direct transfer
/// plus chunks of a relay reassembly); the transfer counts as stalled only after `noProgressMs` with
/// no growth. `busy` (a relay restore still in flight, which reports nothing until it finishes a
/// chunk) keeps the clock from running out underneath it.
struct TransferStallWatch: Equatable, Sendable {
    static let noProgressMs: UInt64 = 45_000

    private(set) var lastProgress: Int
    private(set) var lastProgressAt: UInt64

    init(progress: Int, nowMs: UInt64) {
        lastProgress = progress
        lastProgressAt = nowMs
    }

    /// Record the current progress. True once the transfer has made no progress for `noProgressMs`.
    mutating func observe(progress: Int, nowMs: UInt64, busy: Bool = false) -> Bool {
        if progress > lastProgress || busy {
            lastProgress = max(lastProgress, progress)
            lastProgressAt = nowMs
            return false
        }
        // A reset (a restarted partial) is not progress, but it isn't a stall on its own either.
        if progress < lastProgress { lastProgress = progress }
        return nowMs >= lastProgressAt && nowMs &- lastProgressAt >= Self.noProgressMs
    }
}

/// Media refs this device wants and doesn't have yet — "media waiting" in the sync detail.
///
/// Persistent across scans: a ref joins when a scan discovers it missing and leaves when its bytes
/// arrive, when the fetch gives up for good, or when a later check finds it held. The scans cover a
/// rotating subset of circles, so their per-pass `missing` count was never a stable number to show.
struct MediaWantedSet: Equatable, Sendable {
    static let cap = 5_000
    private(set) var refs = Set<String>()
    var count: Int { refs.count }

    mutating func discover<S: Sequence>(_ found: S) where S.Element == String {
        for r in found where refs.count < Self.cap { refs.insert(r) }
    }
    /// The bytes landed. True if the ref was wanted.
    @discardableResult
    mutating func arrived(_ ref: String) -> Bool { refs.remove(ref) != nil }
    /// Every lane gave up on it (it shows "No longer available"); a retry rediscovers it.
    mutating func gaveUp(_ ref: String) { refs.remove(ref) }
    /// Drop refs that turned up by a path that never reported them (NSE prefetch, another store).
    mutating func prune(held: (String) -> Bool) { refs = refs.filter { !held($0) } }
}
