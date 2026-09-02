import Foundation
import SwiftUI

/// The in-app activity list (the bell): who reacted / commented / voted / posted / messaged,
/// merged from two sources —
///   • the engine's `activity(sinceMs:nowMs:)` reduction (one pass across every circle, own
///     actions excluded), pulled OFF-MAIN on the engine actor after ingest bursts and on foreground;
///   • app-layer moments that never enter a circle's event log — connection requests,
///     added-to-a-circle, device linking — appended at the same sites that post their banners.
///
/// Rows persist as a small JSON file in Application Support (cap ~500) so the list survives a
/// relaunch. `seenAt` is the read watermark: unread = rows newer than it, and it syncs across
/// the user's own devices via SelfSync (`setting:activitySeenAt`, merged MAX — the exact
/// dmLastRead pattern), so opening the bell on one device clears it everywhere.
@MainActor
final class ActivityStore: ObservableObject {
    static let shared = ActivityStore()

    struct Entry: Codable, Identifiable, Equatable {
        /// Event id (engine rows) or the banner dedupe key (app-layer rows) — the dedupe axis.
        let id: String
        /// `react|comment|vote|post|story|dm` (engine) or `connect|circle|device` (app-layer).
        let kind: String
        let circleId: String
        let actorHex: String
        /// 8-char author prefix for `ContactsStore.name(forNodePrefix:)`.
        let actorShort: String
        /// The parent post/comment/poll id where applicable (reactions, comments, votes).
        let targetId: String?
        let snippet: String
        let emoji: String?
        /// Event time, unix ms.
        let at: UInt64
    }

    @Published private(set) var entries: [Entry] = []
    /// Rows newer than the seen watermark — the bell badge.
    @Published private(set) var unread = 0

    private var ids = Set<String>()
    private var pullInFlight = false
    private var savePending = false
    private static let cap = 500

    private let seenAtKey = "haven.activity.seenAt"
    /// The read watermark (unix ms). Monotonic — see `applySyncedSeenAt`.
    private(set) var seenAtMs: UInt64

    private let pulledThroughKey = "haven.activity.pulledThroughMs"
    /// The newest EVENT TIME the engine's `activity()` has actually handed us — the ONLY thing
    /// allowed to narrow the next pull's window.
    ///
    /// This used to be `entries.first?.at`: the newest row in the list, whatever its source. But
    /// the list is a MERGE, and its other source stamps `Date()`. One `note(…)` row — "someone
    /// wants to connect", "you were added to a circle", "a device was linked" — therefore set the
    /// engine's watermark to *now*, and every pull after it asked the engine for the last hour
    /// only. Anything older that the list had not already ingested was skipped, and skipped again
    /// on the next pull, because that app-layer row stayed the newest one: a permanent hole, not a
    /// slow refresh. `noteFeedItem` did the same with a real event time — `runCircleSideEffects`
    /// mirrors the newest inbound item and *then* pulls, so a phone catching up after a day
    /// offline noted one fresh message and clamped the pull that was supposed to fetch the
    /// backlog behind it.
    ///
    /// Persisted, so a relaunch keeps the incremental window. Absent (or 0) means "ask for
    /// everything" — which is what a fresh install does anyway, and what repairs a list this bug
    /// already punched a hole in.
    private var pulledThroughMs: UInt64

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-activity.json")
    }

    private init() {
        seenAtMs = UInt64(max(0, UserDefaults.standard.double(forKey: seenAtKey)))
        pulledThroughMs = UInt64(max(0, UserDefaults.standard.double(forKey: pulledThroughKey)))
        if let data = try? Data(contentsOf: fileURL),
           let rows = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = rows
            ids = Set(rows.map(\.id))
        }
        recomputeUnread()
    }

    // MARK: - Intake

    /// Engine rows. The FFI runs on the engine actor (it takes the engine lock); the merge
    /// publishes back on the main actor. Coalesced — an ingest burst pulls once.
    func pull(engine: Engine) {
        guard !pullInFlight else { return }
        pullInFlight = true
        // Overlap what the engine has already given us by an hour so an event that raced the
        // previous pull isn't skipped; `ingest` dedupes by event id, so overlap costs nothing.
        // The watermark is `pulledThroughMs` and NOT the newest row in the list — see its comment.
        let since = pulledThroughMs > 3_600_000 ? pulledThroughMs - 3_600_000 : 0
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        Task { @MainActor [weak self] in
            let rows = await engine.run { $0.activity(sinceMs: since, nowMs: nowMs) }
            guard let self else { return }
            self.pullInFlight = false
            self.ingest(rows)
        }
    }

    /// Merge one completed engine pull. This is the only place the pull watermark moves, and it
    /// moves to an EVENT time the engine reported — never to the wall clock, so a backfill that
    /// delivers older events later still lands.
    private func ingest(_ rows: [ActivityItemFfi]) {
        if let newest = rows.map(\.createdAt).max(), newest > pulledThroughMs {
            pulledThroughMs = newest
            scheduleSave()   // the watermark rides the SAME write as the rows it accounts for
        }
        var added = false
        for r in rows where !ids.contains(r.id) {
            ids.insert(r.id)
            entries.append(Entry(id: r.id, kind: r.kind, circleId: r.circleId,
                                 actorHex: r.actorHex, actorShort: r.actorShort,
                                 targetId: r.targetId, snippet: r.snippet, emoji: r.emoji,
                                 at: r.createdAt))
            added = true
        }
        if added { finalizeMutation() }
    }

    /// App-layer rows (connection request, added-to-circle, device linked) — appended at the same
    /// sites that post their banners, so the list is complete even when banners are suppressed.
    func note(id: String, kind: String, circleId: String = "", actorHex: String = "",
              actorShort: String = "", snippet: String) {
        guard !ids.contains(id) else { return }
        ids.insert(id)
        entries.append(Entry(id: id, kind: kind, circleId: circleId, actorHex: actorHex,
                             actorShort: actorShort, targetId: nil, snippet: snippet,
                             emoji: nil, at: UInt64(Date().timeIntervalSince1970 * 1000)))
        finalizeMutation()
    }

    /// A feed item the banner path just surfaced (`applyNotifyFromItems`) — mirror it into the
    /// list ahead of the next engine pull. Same id as the engine's row, so the pull dedupes.
    func noteFeedItem(_ item: FeedItemFfi, circleId: String) {
        guard !ids.contains(item.id) else { return }
        ids.insert(item.id)
        let kind = item.story ? "story" : (circleId.hasPrefix("dm:") ? "dm" : "post")
        entries.append(Entry(id: item.id, kind: kind, circleId: circleId, actorHex: "",
                             actorShort: item.authorShort, targetId: nil,
                             snippet: String(item.body.prefix(120)), emoji: nil,
                             at: item.createdAt))
        finalizeMutation()
    }

    private func finalizeMutation() {
        entries.sort { $0.at > $1.at }
        if entries.count > Self.cap {
            for e in entries.suffix(entries.count - Self.cap) { ids.remove(e.id) }
            entries.removeLast(entries.count - Self.cap)
        }
        recomputeUnread()
        scheduleSave()
    }

    // MARK: - Seen watermark

    /// Opening the activity list clears the bell — here, and (via SelfSync) on every device.
    func markAllSeen() {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        guard now > seenAtMs else { return }
        seenAtMs = now
        UserDefaults.standard.set(Double(seenAtMs), forKey: seenAtKey)
        recomputeUnread()
        // A LOCAL clear (never `applySyncedSeenAt`) drops the bell badge on my other devices in
        // seconds via a debounced forced self-sync pass.
        FeedStore.shared.nudgeSelfSyncSoon()
    }

    /// SelfSync apply (`setting:activitySeenAt`): merged MAX — reading on one device clears the
    /// bell everywhere, and no device can un-read another (a fresh device's 0 changes nothing).
    func applySyncedSeenAt(_ ms: UInt64) {
        guard ms > seenAtMs else { return }
        seenAtMs = ms
        UserDefaults.standard.set(Double(seenAtMs), forKey: seenAtKey)
        recomputeUnread()
    }

    private func recomputeUnread() {
        let n = entries.reduce(0) { $0 + ($1.at > seenAtMs ? 1 : 0) }
        if n != unread { unread = n }
    }

    // MARK: - Persistence (debounced, off-main write)

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.savePending = false
            // Watermark and rows are written together on purpose. Persisting `pulledThroughMs` the
            // moment a pull returned would narrow the next launch's window on the strength of rows
            // that a kill in the next two seconds never wrote — a hole that no later pull would
            // ever ask for again. Written here they advance together, and a kill in between simply
            // re-pulls the same window.
            UserDefaults.standard.set(Double(self.pulledThroughMs), forKey: self.pulledThroughKey)
            guard let data = try? JSONEncoder().encode(self.entries) else { return }
            let url = self.fileURL
            DispatchQueue.global(qos: .utility).async {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
}
