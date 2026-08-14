import Foundation
import SwiftUI

/// Runs an Instagram archive import: stage each item's media through Haven's normal compose path,
/// then author the post silently and backdated.
///
/// Deliberately reuses `MediaStore.addImage` / `prepareVideo` rather than writing bytes straight
/// into the store. Those are what apply auto-optimize, mint the ≤32 KB thumb companion, and cut a
/// poster still for every video — so imported media behaves like media the user posted by hand
/// instead of becoming a second class of blob nothing else in the app understands.
///
/// Isolation matters more here than anywhere else in the app. `MediaStore` is `@MainActor`, so the
/// staging calls have to run there — but the archive work must NOT: reading an entry is a disk read
/// plus a CRC over the whole entry, and doing that on the main actor for a 1.2 GB export would lock
/// the UI for the length of the import. So the loop lives in a detached task that owns the reader,
/// and hops to the main actor only for the calls that require it.
@MainActor
final class InstagramImporter: ObservableObject {
    static let shared = InstagramImporter()

    enum Phase: Equatable {
        case idle
        case reading
        case previewing
        case importing(done: Int, total: Int)
        case finished(imported: Int, skipped: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var summary: InstagramArchive.Summary?

    private var cancelled = false
    private var archiveURL: URL?

    /// True while an import is running — the app-wide banner watches this, and the sheet uses it to
    /// offer "continue in the background" rather than holding the user on a progress bar.
    var isRunning: Bool { if case .importing = phase { return true }; return false }

    // MARK: - Resume across launches

    /// Everything needed to pick a half-finished import back up after the app is killed.
    ///
    /// The archive is stored as a security-scoped BOOKMARK, not a path: the file lives outside the
    /// sandbox (Files, iCloud Drive, a download) and a bare path would be unreadable on the next
    /// launch. `done` is an index into the deterministic item order — see `InstagramArchive.read`,
    /// which sorts with a tiebreak precisely so this index means the same thing on every run.
    private struct Pending: Codable {
        var bookmark: Data
        var circleId: String
        var includeStories: Bool
        /// Defaulted so a checkpoint written before song matching existed still decodes.
        var matchSongs: Bool = false
        var done: Int
    }

    private static let pendingKey = "haven.instagram.import.pending"

    private func savePending(_ p: Pending) {
        guard let d = try? JSONEncoder().encode(p) else { return }
        UserDefaults.standard.set(d, forKey: Self.pendingKey)
    }
    private func loadPending() -> Pending? {
        guard let d = UserDefaults.standard.data(forKey: Self.pendingKey) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: d)
    }
    private func clearPending() { UserDefaults.standard.removeObject(forKey: Self.pendingKey) }

    /// Restart an import that was interrupted by the app being killed or backgrounded out.
    ///
    /// Called on launch. Silent when there is nothing pending, and silent when the bookmark no
    /// longer resolves — the user may have deleted the archive, and nagging about it on every cold
    /// start would be worse than quietly forgetting an import they can simply run again.
    func resumeIfNeeded() {
        guard !isRunning, let p = loadPending() else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: p.bookmark,
                                 options: bookmarkResolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            clearPending(); return
        }
        Task { [weak self] in
            let parsed = await Task.detached(priority: .utility) { Self.parse(url) }.value
            guard let self, case .success(let s) = parsed else { self?.clearPending(); return }
            guard p.done < s.items.count else { self.clearPending(); return }
            self.archiveURL = url
            self.summary = s
            self.phase = .previewing          // `run` requires this state
            self.run(into: p.circleId, includeStories: p.includeStories,
                     matchSongs: p.matchSongs, startAt: p.done)
        }
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
    private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    // MARK: - Preview

    func read(_ url: URL) {
        phase = .reading
        summary = nil
        cancelled = false
        Task { [weak self] in
            // Parse off the main actor — on a large export this walks a multi-megabyte JSON.
            let parsed = await Task.detached(priority: .userInitiated) { Self.parse(url) }.value
            guard let self else { return }
            switch parsed {
            case .success(let s):
                self.archiveURL = url
                self.summary = s
                self.phase = .previewing
            case .failure(let e):
                self.phase = .failed(e.localizedDescription)
            }
        }
    }

    /// Security-scoped: the picker's URL is only readable while the scope is held.
    private nonisolated static func parse(_ url: URL) -> Result<InstagramArchive.Summary, Error> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { return .success(try InstagramArchive.read(url)) } catch { return .failure(error) }
    }

    func cancel() { cancelled = true }

    func reset() {
        cancelled = false
        summary = nil
        archiveURL = nil
        phase = .idle
    }

    // MARK: - Import

    /// Publish every parsed item into `circleId`, oldest first.
    ///
    /// Oldest-first matters: the feed orders by creation date, so importing chronologically means
    /// anyone watching it happen sees history fill in forwards rather than as a shuffled heap.
    /// `includeStories` is OFF by default, and that default is load-bearing.
    ///
    /// Instagram archives EVERY story you post, automatically — `stories.json` is not "the ones you
    /// chose to keep", it is all of them, and the export carries no signal for which were added to a
    /// Highlight (checked: no highlight field, no separate file, nothing). So importing them by
    /// default would resurrect years of stories the user deliberately let expire. It has to be
    /// something they ask for, having been told what the archive actually contains.
    /// `startAt` resumes a previous run, skipping items already imported. Only `resumeIfNeeded`
    /// passes it; a fresh import starts at 0.
    func run(into circleId: String, includeStories: Bool = false,
             matchSongs: Bool = false, startAt: Int = 0) {
        guard let summary, let url = archiveURL, case .previewing = phase else { return }
        let items = includeStories ? summary.items : summary.items.filter { $0.kind != .story }
        phase = .importing(done: min(startAt, items.count), total: items.count)
        cancelled = false

        // Record the job BEFORE any work, so a crash on the very first item still resumes.
        // Best-effort: without a bookmark the import runs fine, it just won't survive a relaunch.
        if let bookmark = try? url.bookmarkData(options: bookmarkCreationOptions,
                                                includingResourceValuesForKeys: nil, relativeTo: nil) {
            savePending(Pending(bookmark: bookmark, circleId: circleId,
                                includeStories: includeStories, matchSongs: matchSongs, done: startAt))
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let zip = ZipReader(url: url) else {
                await MainActor.run { [weak self] in
                    self?.phase = .failed(InstagramArchive.Failure.unreadable.localizedDescription)
                }
                return
            }
            defer { zip.close() }
            var byName: [String: ZipReader.Entry] = [:]
            for e in zip.entries { byName[e.name] = e }

            // Counters stay in THIS task's scope and are never touched from inside a hop — the
            // main actor only ever receives already-computed values.
            var imported = 0, skipped = 0
            // Every catalog id already attached this run. Passed back into the suggester so each
            // post takes the best song NOT yet spoken for — without this, one search term per year
            // meant one song for every silent post in that year.
            var usedSongs = Set<String>()
            var audible = 0, identified = 0
            HavenLog.sync("ig-import: starting \(items.count) items from \(startAt)")
            for (idx, item) in items.enumerated() {
                if idx < startAt { continue }   // already imported on a previous run
                if await MainActor.run(body: { [weak self] in self?.cancelled ?? true }) { break }
                let began = Date()
                let (refs, hasAudio, detected, themes) = await Self.stage(
                    item, zip: zip, byName: byName, identify: matchSongs,
                    isCancelled: { await MainActor.run { [weak self] in self?.cancelled ?? true } })
                // Stop means STOP. Staging an item can take a minute (a video transcode), and the
                // check above happened before all of it — so hitting Stop used to finish the clip
                // AND publish it, which is not what "stop" looks like from the outside.
                if await MainActor.run(body: { [weak self] in self?.cancelled ?? true }) { break }
                if hasAudio { audible += 1 }
                if detected != nil { identified += 1 }
                if refs.isEmpty {
                    skipped += 1
                } else {
                    let body = item.body, at = item.createdAt, kind = item.kind
                    // Suggest a song ONLY into silence. A reel that shipped with its soundtrack
                    // keeps it — that audio is baked into the video and is what the user actually
                    // chose; layering a guess over it would be worse than adding nothing.
                    // Two different jobs, and which one applies is decided by whether the post
                    // already makes a sound:
                    //
                    //   has audio  → IDENTIFY it (Shazam) and attach the result as a CREDIT, so the
                    //                chip names the real song while the video keeps its own audio.
                    //   silent     → SUGGEST one (Apple Music, by genre + era). A guess, and the
                    //                only case where a guess is harmless, because the alternative
                    //                is silence.
                    var music: TrackRefFfi? = nil
                    if matchSongs {
                        if hasAudio {
                            music = detected
                        } else {
                            let when = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
                            let parts = Calendar.current.dateComponents([.year, .month], from: when)
                            music = await SongSuggester.song(themes: themes, genre: item.musicGenre,
                                                             year: parts.year ?? 2024,
                                                             month: parts.month ?? 0,
                                                             exclude: usedSongs)
                            if let id = music?.catalogId { usedSongs.insert(id) }
                        }
                    }
                    // Stories, when the user opted in, land as KEPT stories rather than feed posts:
                    // a personal snapshot on their profile with its media pinned. Keeping
                    // deliberately does not republish (see KeptStoriesStore), which is what makes
                    // this safe — nobody else's feed fills with someone's old stories, and the
                    // circle is not asked to carry them at all.
                    //
                    // Posts and reels ARE feed content and publish normally (silent + backdated).
                    let identity = Self.keptIdentity(item)
                    await MainActor.run {
                        if kind == .story {
                            KeptStoriesStore.shared.keep(id: identity, body: body, media: refs,
                                                         createdAt: at, music: music)
                        } else {
                            FeedStore.shared.postImported(circleId: circleId, body: body, media: refs,
                                                          music: music, story: false, createdAt: at)
                        }
                    }
                    imported += 1
                }
                // Checkpoint after EVERY item. The unit of work is one post, so the most a kill can
                // cost is the item in flight — and re-importing that one item is the failure mode
                // we accept, rather than re-importing all 300.
                // ASK for a rebuild as we go. The slow floor in FeedStore.refresh caps how often one
                // actually happens, but a cap is not a trigger — with postImported no longer
                // requesting anything, nothing was driving the feed at all and it sat unchanged for
                // the whole import. Requesting per item and letting the floor throttle it gives a
                // feed that fills in visibly without thrashing.
                await MainActor.run { FeedStore.shared.scheduleRefresh(after: 1) }
                let done = idx + 1, total = items.count
                let secs = Date().timeIntervalSince(began)
                if secs > 5 {
                    HavenLog.sync("ig-import: item \(done)/\(total) took \(String(format: "%.1f", secs))s (\(item.mediaNames.count) media)")
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.phase = .importing(done: done, total: total)
                    if var p = self.loadPending() { p.done = done; self.savePending(p) }
                }
            }
            HavenLog.sync("ig-import: done — \(identified)/\(audible) posts with audio were identified by Shazam")
            let finalImported = imported, finalSkipped = skipped
            let stopped = await MainActor.run(body: { [weak self] in self?.cancelled ?? false })
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A cancel keeps the checkpoint, so "Stop" is really "pause" — reopening the
                // importer offers to carry on. Finishing clears it.
                if !stopped { self.clearPending() }
                self.phase = .finished(imported: finalImported, skipped: finalSkipped)
                // The feed was frozen for the whole run (see FeedStore.refresh) — bring it up to
                // date now, in one rebuild, with everything in place.
                FeedStore.shared.importFinished()
            }
        }
    }

    /// Turn one parsed item's archive entries into Haven media refs, in album order.
    ///
    /// A carousel stays ONE post: every photo in the album is staged into the same `media` array,
    /// so a 20-photo Instagram carousel arrives as a 20-photo Haven post rather than 20 posts.
    ///
    /// `nonisolated` on purpose — the zip reads happen here, off the main actor, and only the
    /// `MediaStore` calls hop onto it.
    private nonisolated static func stage(_ item: InstagramArchive.Item,
                                          zip: ZipReader,
                                          byName: [String: ZipReader.Entry],
                                          identify: Bool,
                                          isCancelled: @Sendable () async -> Bool) async -> ([String], Bool, TrackRefFfi?, [String]) {
        var refs: [String] = []
        /// Temp clips, removed once identification has finished with them.
        var scratchFiles: [URL] = []
        /// Does ANY of this post's media make sound? One song plays per post, so a carousel with a
        /// single talking video should not get one layered on top of it.
        var anyAudio = false
        /// Identification running alongside the staging work — see where it is started.
        var shazamTask: Task<Void, Never>?
        /// Where that task deposits its answer, if it finishes in time.
        let shazamResult = ShazamResultBox()
        /// What the post is ABOUT — Vision labels off the first photo, plus caption words. This is
        /// what makes one silent post's suggestion differ from the next one's.
        var themes: [String] = SongSuggester.captionThemes(item.body)
        if themes.isEmpty && !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Every logged suggestion came through with no themes, while the archive shows 20 of 22
            // silent posts DO have captions — so the input is not the problem and extraction is.
            // Log the caption that produced nothing rather than reasoning about it again.
            HavenLog.sync("song-suggest   caption gave NO themes (\(item.body.count) chars): "
                + "\(item.body.prefix(60))")
        }
        for name in item.mediaNames {
            // A 20-photo carousel is 20 encodes; a cancel should not have to wait out the album.
            if await isCancelled() { break }
            guard let entry = byName[name] else { continue }
            // Disk read + CRC over the entry — the expensive part, and the reason this is detached.
            guard let bytes = zip.data(for: entry) else { continue }

            if isVideo(name) {
                // prepareVideo transcodes with AVFoundation and needs a file URL, so the clip is
                // spilled to scratch and removed as soon as it is staged.
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("igimport_\(UUID().uuidString).\(ext(name))")
                guard (try? bytes.write(to: scratch)) != nil else { continue }
                // NOT removed here: the identification task started below reads this file, and it
                // outlives this iteration. Cleaned up at the end of the post instead.
                scratchFiles.append(scratch)
                // Asked of the real file, before transcoding — "is it a video" and "does it make
                // sound" are different questions. A screen recording, a time-lapse or a clip muted
                // before posting is a silent video, and deserves a song as much as a photo does.
                if await SongSuggester.hasAudio(scratch) {
                    anyAudio = true
                    // Identify from the FIRST audible clip only. A carousel shows one chip, and
                    // Shazam-ing every clip in a 20-video album is work with nowhere to go.
                    //
                    // STARTED HERE, COLLECTED LATER. Identification must never gate the import: it
                    // is a network call behind a back-off throttle, so on a bad stretch it can sit
                    // for tens of seconds, and the credit it produces is a nicety while the post
                    // itself is the point. Kicking it off before the transcode means it runs
                    // alongside the expensive work and is usually finished for free by the time the
                    // clip is encoded — and if it isn't, it gets abandoned rather than waited on.
                    if identify, shazamTask == nil {
                        let clip = scratch
                        let label = name
                        let box = shazamResult
                        shazamTask = Task.detached(priority: .utility) {
                            let began = Date()
                            let outcome = await ShazamDetector.identifyDetailed(clip)
                            await box.set(outcome.track)
                            HavenLog.sync("ig-import: shazam \(outcome.reason) in "
                                + "\(String(format: "%.1f", Date().timeIntervalSince(began)))s — \(label)")
                        }
                    }
                }
                // forceOptimize: an import is bulk media at someone else's encoder settings —
                // running it through Haven's ladder is what stops a 1.2 GB archive from landing on
                // the relay as-is. alsoOriginal: false — shipping the originals too would double an
                // already large import, for bytes that are themselves a compressed re-encode.
                let prepared = await withTimeout(videoStageTimeout) {
                    await MediaStore.shared.prepareVideo(url: scratch, forceOptimize: true,
                                                         alsoOriginal: false)
                }
                if prepared == nil {
                    HavenLog.sync("ig-import: video staging TIMED OUT after \(Int(videoStageTimeout))s — skipping \(name)")
                }
                // mediaRefs already carries poster + poster marker + clip in the order the feed
                // expects (poster first — MediaVariants.composeVideoMedia), so a video tile has its
                // still from the moment it arrives.
                if let prepared, !prepared.isEmpty { refs.append(contentsOf: prepared.mediaRefs) }
            } else {
                // Read the subject off the FIRST photo only — one song per post, so one look is
                // enough, and Vision on every frame of a 20-photo carousel is work with nowhere
                // to go.
                if themes.count < 3, refs.isEmpty {
                    let seen = SongSuggester.visualThemes(bytes)
                    // Every logged suggestion carried caption themes only, never a visual one — so
                    // either Vision is contributing nothing or its labels are all being filtered.
                    // Say which, rather than assume the on-device analysis is working.
                    HavenLog.sync("song-suggest   vision -> \(seen.isEmpty ? "[nothing]" : seen.joined(separator: "+"))")
                    themes += seen
                }
                // Decode + re-encode are MainActor work (MediaStore is main-isolated), and the
                // encoded bytes are what the content ref is minted from.
                let ref = await MainActor.run { () -> String? in
                    guard let image = PlatformImage(data: bytes) else { return nil }
                    return MediaStore.shared.addImage(image, forceOptimize: true)
                }
                if let ref { refs.append(ref) }
            }
        }
        // Collect identification only if it is ready or nearly so. The import does not wait on it:
        // a missing credit costs a chip, whereas waiting costs every remaining post.
        // Take the result ONLY if it has already landed. Never await the task: awaiting a detached
        // task inside a timeout does not bound anything (a task group waits for all its children,
        // and cancelling the group cannot cancel a detached task), which is precisely how this
        // deadlocked an entire import. The box holds whatever finished in time; anything slower is
        // abandoned, which is the stated contract — identification must not gate the import.
        let detected = await shazamResult.value()
        shazamTask?.cancel()
        for f in scratchFiles { try? FileManager.default.removeItem(at: f) }
        return (refs, anyAudio, detected, themes)
    }

    /// Stable id for a kept story, derived from the archive entry it came from.
    ///
    /// `KeptStoriesStore.keep` is keyed on the original event id so a story is kept at most once —
    /// an import has no Haven event to point at, so the archive path stands in. It is stable across
    /// runs, which makes re-importing the same export idempotent instead of doubling every story.
    private nonisolated static func keptIdentity(_ item: InstagramArchive.Item) -> String {
        "ig:" + (item.mediaNames.first ?? "\(item.createdAt)")
    }

    /// Holds an identification result for collection without ever blocking on it.
    actor ShazamResultBox {
        private var track: TrackRefFfi?
        func set(_ t: TrackRefFfi?) { track = t }
        func value() -> TrackRefFfi? { track }
    }

    /// Run `work`, giving up after `seconds`.
    ///
    /// One item must never be able to wedge a 372-item import. Video staging is the risk: the
    /// encoder ladder can fall back through several export presets, and poster generation waits on
    /// a semaphore with a 15s timeout PER config — so a clip AVFoundation dislikes can sit there for
    /// a minute or more, and a clip it hangs on sits there forever. The simulator's software
    /// encoder makes both far likelier than on a device.
    ///
    /// Losing the race does not kill the underlying work (an AVAssetExportSession does not
    /// meaningfully honour cancellation) — it just stops the LOOP waiting on it, so the import
    /// continues and the offending post is skipped rather than taking everything else down with it.
    private nonisolated static func withTimeout<T: Sendable>(
        _ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// How long one video may take to stage before the import moves on. Generous — a large clip on a
    /// slow device legitimately takes a while, and skipping a post the user wanted is worse than
    /// waiting — but bounded, which is the part that was missing.
    private static let videoStageTimeout: Double = 180

    private nonisolated static func ext(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.isEmpty ? "mp4" : e
    }
    private nonisolated static func isVideo(_ name: String) -> Bool {
        ["mp4", "mov", "m4v"].contains(ext(name))
    }
}
