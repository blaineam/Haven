import Foundation
import Darwin

// DEBUG-only QA instrumentation exported through qa-dump.json (docs/QA.md "qa-cmd v2"). Every
// recording entry point compiles to a no-op outside DEBUG, like the dump itself.
/// QA counters for the relay-first media path (docs/QA.md, e2e step `relayfirst`), exported under
/// `relay_first` in qa-dump.json. Recorded from the serve, receive and author paths — some of them
/// background queues, hence the lock. Every entry point is a no-op outside DEBUG, like the dump.
enum QaMediaStats {
    #if DEBUG
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var lastDecline = ""
    nonisolated(unsafe) private static var seq: UInt64 = 0
    /// ref → sequence number of its FIRST authored enqueue; event id → sequence of its broadcast.
    nonisolated(unsafe) private static var enqueuedAt: [String: UInt64] = [:]
    nonisolated(unsafe) private static var broadcastAt: [String: UInt64] = [:]
    #endif

    /// Add `n` to counter `key` (served_direct_friend, relay_hints_sent, received_via_relay, …).
    static func bump(_ key: String, _ n: Int = 1) {
        #if DEBUG
        lock.lock(); counts[key, default: 0] += n; lock.unlock()
        #endif
    }

    static func declined(_ why: String) {
        #if DEBUG
        lock.lock(); counts["serve_declined", default: 0] += 1; lastDecline = why; lock.unlock()
        #endif
    }

    /// Authored media was queued for the relay (`enqueueAuthoredMedia`).
    static func authoredEnqueued(_ refs: [String]) {
        #if DEBUG
        lock.lock(); seq += 1
        for r in refs where enqueuedAt[r] == nil { enqueuedAt[r] = seq }
        if enqueuedAt.count > 5000 { enqueuedAt.removeAll() }
        lock.unlock()
        #endif
    }

    /// An authored event went out (`broadcastEvent`).
    static func broadcast(eventId: String?) {
        #if DEBUG
        guard let eventId, !eventId.isEmpty else { return }
        lock.lock(); seq += 1
        if broadcastAt[eventId] == nil { broadcastAt[eventId] = seq }
        if broadcastAt.count > 5000 { broadcastAt.removeAll() }
        lock.unlock()
        #endif
    }

    #if DEBUG
    /// The dump's `relay_first` object. `ownPosts` = (event id, real media refs) of MY posts in the
    /// feed: each one broadcast this launch is checked — every ref must have been enqueued for the
    /// relay BEFORE the broadcast, or it counts toward `broadcast_before_enqueue` (must stay 0).
    static func snapshot(ownPosts: [(id: String, refs: [String])]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var checked = 0, early = 0
        for p in ownPosts where !p.refs.isEmpty {
            guard let b = broadcastAt[p.id] else { continue }
            checked += 1
            if p.refs.contains(where: { (enqueuedAt[$0] ?? .max) > b }) { early += 1 }
        }
        var out: [String: Any] = counts
        out["served_direct_friend"] = counts["served_direct_friend"] ?? 0
        out["served_direct_friend_bytes"] = counts["served_direct_friend_bytes"] ?? 0
        out["relay_hints_sent"] = counts["relay_hints_sent"] ?? 0
        out["received_via_relay"] = counts["received_via_relay"] ?? 0
        out["received_via_direct"] = counts["received_via_direct"] ?? 0
        out["media_requests_from_friends"] = counts["media_requests_from_friends"] ?? 0
        out["serve_declined"] = counts["serve_declined"] ?? 0
        out["last_decline"] = lastDecline
        out["authored_media_posts_checked"] = checked
        out["broadcast_before_enqueue"] = early
        out["heavy_work"] = heavyWork()
        return out
    }

    /// The live heavy-work gate (HeavyWorkPolicy.Conditions) as the dump reports it.
    static func heavyWork() -> [String: Any] {
        let c = HeavyWorkMonitor.current
        return ["suspended": c.suspendHeavyIO, "friend_serving": c.peerServingAllowedForFriends,
                "reason": c.reason, "forced": c.forced]
    }
    #endif
}

/// Launch timing for the e2e `launch` step: milliseconds since PROCESS START (not since the
/// FeedStore came up) for the first feed paint, the end of the DM warm, the first mailbox pass,
/// and the first content ingest per circle. Each is written once per launch.
enum QaLaunch {
    #if DEBUG
    private static let lock = NSLock()
    nonisolated(unsafe) private static var marks: [String: Int] = [:]
    nonisolated(unsafe) private static var circleIngest: [String: Int] = [:]

    /// Wall-clock ms at which this process started (kinfo_proc), falling back to first use.
    static let processStartMs: Int = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
            let t = info.kp_proc.p_starttime
            return Int(t.tv_sec) * 1000 + Int(t.tv_usec) / 1000
        }
        return Int(Date().timeIntervalSince1970 * 1000)
    }()
    private static func sinceStart() -> Int { Int(Date().timeIntervalSince1970 * 1000) - processStartMs }
    #endif

    /// Record `name` (first occurrence only) as ms since process start.
    static func mark(_ name: String) {
        #if DEBUG
        let t = sinceStart()
        lock.lock(); if marks[name] == nil { marks[name] = t }; lock.unlock()
        #endif
    }

    /// Record a value for `name` once (e.g. the first mailbox pass's duration).
    static func once(_ name: String, _ value: Int) {
        #if DEBUG
        lock.lock(); if marks[name] == nil { marks[name] = value }; lock.unlock()
        #endif
    }

    /// Content from these circles was just ingested from the mailbox.
    static func ingested(circles: Set<String>) {
        #if DEBUG
        let t = sinceStart()
        lock.lock(); for c in circles where circleIngest[c] == nil { circleIngest[c] = t }; lock.unlock()
        #endif
    }

    #if DEBUG
    static func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Any] = [:]
        out["process_start_ms"] = processStartMs
        out["first_feed_rendered_ms"] = marks["first_feed_rendered"] ?? NSNull()
        out["dm_warmup_done_ms"] = marks["dm_warmup_done"] ?? NSNull()
        out["first_mailbox_pass_ms"] = marks["first_mailbox_pass"] ?? NSNull()
        out["first_mailbox_pass_done_ms"] = marks["first_mailbox_pass_done"] ?? NSNull()
        out["circle_first_ingest_ms"] = circleIngest
        return out
    }
    #endif
}
