import Foundation

/// "Load history from your relays" — a user-triggered deep pass over every circle's relay mailbox.
///
/// The ordinary mailbox poll only fetches keys its persisted seen-set has never recorded. "Seen"
/// means "processed once", which includes envelopes that only PARKED waiting for a key (and were
/// later evicted from the 512-slot pending buffer or GC'd as fossils), envelopes from before this
/// device could open them, and — on older builds — envelopes marked seen before the engine state
/// that held them was saved. Posts in any of those states are still sitting on the relay, but no
/// normal poll ever looks at them again. This pass looks at all of them.
///
/// Shape (the planner itself is core — `RelayHistoryPlanner`, shared with Android and desktop):
///   1. per circle, per relay: the FULL listing (no delta digest, no seen-set), minus what the
///      planner's own ingested journal says this device already has;
///   2. fetch in small batches (bounded concurrency), ingest each batch control-plane first, save
///      the engine, THEN commit the batch to the journal and the seen-set (mark-after-persist);
///   3. once every circle's keys and rosters are in, one retry pass over whatever only parked;
///   4. download the photos and videos the feed now names, relay-first.
///
/// It never seals, uploads, fans out, or pushes: history that arrives this way is old news, and the
/// mailbox must not grow because someone pressed this button. Cancel stops between batches; running
/// it again resumes, because committed keys are skipped.
@MainActor
final class RelayHistoryResync: ObservableObject {
    static let shared = RelayHistoryResync()

    @Published private(set) var progress = RelayHistoryProgress()

    /// Envelopes fetched and ingested per engine save. Small enough that a cancel or a kill loses
    /// little, big enough that the save is not per-envelope.
    static let batchSize = 24
    /// Concurrent GETs within a batch.
    static let fetchConcurrency = 4
    /// Concurrent media downloads.
    static let mediaConcurrency = 3

    private var task: Task<Void, Never>?

    private static var journalURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-relay-history.journal")
    }
    private lazy var planner = RelayHistoryPlanner(journalPath: Self.journalURL.path)

    /// The run may start: an engine, at least one relay-backed circle, and not on a satellite link
    /// (the low-data policy denies history backfill there outright).
    var unavailableReason: String? {
        if linkConstraint() == .ultra { return "satellite" }
        if !FeedStore.shared.circles.contains(where: { !SharedStore.historyRelayNodes($0.id).isEmpty }) { return "norelay" }
        return nil
    }

    func start() {
        guard task == nil, unavailableReason == nil else { return }
        progress = RelayHistoryProgress(phase: .scanning, startedAtMs: Self.nowMs())
        HavenLog.relay("relay history: start")
        task = Task { @MainActor [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Hide a finished/cancelled summary.
    func dismiss() {
        guard !progress.running else { return }
        progress = RelayHistoryProgress()
    }

    /// Identity reset: a new account must not inherit the old one's ingested journal.
    func resetJournal() {
        cancel()
        planner.reset()
        progress = RelayHistoryProgress()
    }

    nonisolated static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    private struct Pending { let circle: String; let key: String; let nodes: [String] }

    private func run() async {
        let store = FeedStore.shared
        guard let engine = store.relayHistoryEngine else { progress.phase = .cancelled; return }
        let circleIds = store.circles.map(\.id).filter { !SharedStore.historyRelayNodes($0).isEmpty }
        progress.circlesTotal = circleIds.count
        let before = await store.historyEventCount(circleIds: circleIds)
        // The media the feed already names: anything outside it at the end came from this run.
        let refsBefore = Set(await Self.namedMedia(circleIds: circleIds, engine: engine).flatMap(\.refs))
        var retry: [Pending] = []
        var landed = Set<String>()

        // 1–2. Scan every circle.
        for cid in circleIds {
            if Task.isCancelled { break }
            var perRelay: [(node: String, keys: [String])] = []
            var listedAny = false
            for node in SharedStore.historyRelayNodes(cid) {
                guard let keys = await SharedStore.historyList(circleId: cid, node: node) else { continue }
                listedAny = true
                let plan = await Task.detached(priority: .utility) { [planner] in
                    planner.plan(circleId: cid, listed: keys)
                }.value
                perRelay.append((node, plan))
            }
            if !listedAny { progress.relayErrors += 1 }
            let work = RelayHistoryPlan.merge(perRelay).map { Pending(circle: cid, key: $0.key, nodes: $0.nodes) }
            progress.entriesFound += work.count
            for batch in RelayHistoryPlan.batches(work, size: Self.batchSize) {
                if Task.isCancelled { break }
                let r = await ingest(batch, engine: engine)
                retry += r.retry
                if r.changed { landed.insert(cid) }
            }
            progress.circlesDone += 1
            if landed.contains(cid) { store.relayHistoryLanded(circleIds: [cid]) }   // paint as we go
        }

        // 3. Retry what parked, now that every circle's control plane is in.
        if !Task.isCancelled, !retry.isEmpty {
            progress.phase = .retrying
            var still = 0
            for batch in RelayHistoryPlan.batches(retry, size: Self.batchSize) {
                if Task.isCancelled { break }
                let r = await ingest(batch, engine: engine, counting: false)
                still += r.retry.count
                for p in batch where r.changed { landed.insert(p.circle) }
            }
            progress.waiting = still
        }
        let after = await store.historyEventCount(circleIds: circleIds)
        progress.postsAdded = max(0, after - before)
        if !landed.isEmpty { store.relayHistoryLanded(circleIds: landed) }
        HavenLog.relay("relay history: scan done — \(progress.entriesFound) unseen entries, +\(progress.postsAdded) events, \(progress.unreadable) unreadable, \(progress.waiting) waiting, \(progress.relayErrors) relay errors")

        // 4. Media for everything the feed now names.
        if !Task.isCancelled {
            progress.phase = .media
            await fetchMedia(circleIds: circleIds, before: refsBefore, engine: engine)
        }
        progress.phase = Task.isCancelled ? .cancelled : .done
        progress.finishedAtMs = Self.nowMs()
        HavenLog.relay("relay history: \(progress.phase.rawValue) — +\(progress.postsAdded) events, media \(progress.mediaDone)/\(progress.mediaTotal) (\(progress.mediaMissing) missing)")
    }

    /// Fetch one batch, ingest it, save the engine, then commit. Returns what still needs a retry.
    private func ingest(_ batch: [Pending], engine: Engine, counting: Bool = true) async -> (retry: [Pending], changed: Bool) {
        let got: [Data?] = await SharedStore.fanOut(batch, limit: Self.fetchConcurrency) { p -> Data? in
            for node in p.nodes {
                if let d = await SharedStore.historyGet(node: node, key: p.key) { return d }
            }
            return nil
        }
        var byCircle: [String: [RelayHistoryItem]] = [:]
        var meta: [String: Pending] = [:]
        for (p, d) in zip(batch, got) {
            meta[p.key] = p
            if let d { byCircle[p.circle, default: []].append(RelayHistoryItem(key: p.key, envelope: d)) }
        }
        let planner = self.planner
        var retry: [Pending] = []
        var processed: [String] = []
        var changed = false
        for (cid, items) in byCircle {
            let r = await engine.run { s in planner.ingest(social: s, circleId: cid, items: items) }
            progress.unreadable += Int(r.unreadable)
            if r.applied > 0 { changed = true }
            retry += r.retry.compactMap { meta[$0] }
            processed += r.processed
        }
        if counting { progress.entriesChecked += batch.count }
        guard !processed.isEmpty else { return (retry, changed) }
        // Mark-after-persist: the journal and the seen-set only learn a key once the engine state
        // holding its event is on disk. A failed save drops the staged keys — the next run re-fetches.
        if await FeedStore.shared.relayHistorySave() {
            if !planner.commitStaged() { planner.discardStaged() }
            for k in processed { SharedStore.markSeenPublic(k) }
        } else {
            planner.discardStaged()
        }
        return (retry, changed)
    }

    /// Every ref each circle's feed names (posts and comments), plus which of them are the small
    /// companions (also included in `refs`).
    private static func namedMedia(circleIds: [String], engine: Engine) async -> [(circle: String, refs: [String], small: Set<String>)] {
        let nowMs = Self.nowMs()
        return await engine.run(readOnly: true) { s in
            circleIds.map { cid in
                var refs: [String] = []
                for item in s.feed(circleId: cid, nowMs: nowMs, viewerRetentionSecs: nil) {
                    refs += item.media
                    for c in item.comments { refs += c.media }
                }
                let small = Set(MediaVariants.allThumbs(in: refs) + MediaVariants.allPosters(in: refs)
                                + MediaVariants.allPreviews(in: refs))
                return (cid, refs + Array(small), small)
            }
        }
    }

    /// "Photos and videos" in the summary = media this run brought onto the device: refs new to the
    /// feed that are on disk now (whichever path fetched them) plus what this phase fetches itself.
    private func fetchMedia(circleIds: [String], before: Set<String>, engine: Engine) async {
        let constrained = linkConstraint() != .normal || SettingsStore.shared.dataSaverActive
        let named = await Self.namedMedia(circleIds: circleIds, engine: engine)
        var landed = Set<String>()
        for n in named {
            landed.formUnion(RelayHistoryPlan.landed(
                refs: n.refs, small: n.small, before: before, have: { MediaStore.shared.has($0) },
                synthetic: { MediaStore.isSynthetic($0) }, constrained: constrained))
        }
        var want: [(ref: String, circle: String)] = []
        var taken = Set<String>()
        for n in named {
            let refs = RelayHistoryPlan.wanted(
                refs: n.refs, small: n.small,
                have: { MediaStore.shared.has($0) }, evicted: { EvictedMediaStore.shared.contains($0) },
                synthetic: { MediaStore.isSynthetic($0) }, constrained: constrained)
            for r in refs where !landed.contains(r) && taken.insert(r).inserted { want.append((r, n.circle)) }
        }
        // Small companions first: they make the feed look right long before the full-size files land.
        let small = Set(named.flatMap(\.small))
        want.sort { small.contains($0.ref) && !small.contains($1.ref) }
        progress.mediaTotal = landed.count + want.count
        progress.mediaDone = landed.count
        let allCircles = FeedStore.shared.circles.map(\.id)
        for batch in RelayHistoryPlan.batches(want, size: Self.mediaConcurrency * 4) {
            if Task.isCancelled { return }
            // User-initiated, so a call or Low Power Mode doesn't stop it — real heat does, briefly.
            var waited = 0
            while ThermalPolicy.isSeriousOrWorse, waited < 120, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                waited += 5
            }
            if ThermalPolicy.isSeriousOrWorse { progress.mediaDeferred = true; return }
            let ok: [Bool] = await SharedStore.fanOut(batch, limit: Self.mediaConcurrency) { w -> Bool in
                if MediaStore.shared.has(w.ref) { return true }
                let circles = [w.circle] + allCircles.filter { $0 != w.circle }
                guard let data = await SharedStore.restore(ref: w.ref, circleIds: circles, engine: engine) else { return false }
                let stored = await MediaStore.shared.storeAsync(w.ref, data)
                if stored { FeedStore.shared.relayHistoryMediaLanded(w.ref) }
                return stored
            }
            for r in ok { if r { progress.mediaDone += 1 } else { progress.mediaMissing += 1 } }
        }
    }

    /// QA dump block (`relay_history`).
    var qaSnapshot: [String: Any] {
        let p = progress
        return ["state": p.phase.rawValue, "circles_done": p.circlesDone, "circles_total": p.circlesTotal,
                "entries_found": p.entriesFound, "entries_checked": p.entriesChecked,
                "posts_added": p.postsAdded, "unreadable": p.unreadable, "waiting": p.waiting,
                "media_done": p.mediaDone, "media_total": p.mediaTotal, "media_missing": p.mediaMissing,
                "relay_errors": p.relayErrors, "started_ms": p.startedAtMs, "finished_ms": p.finishedAtMs,
                "journal_keys": planner.ingestedCount()]
    }
}
