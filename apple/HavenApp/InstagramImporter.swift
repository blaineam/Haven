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
    func run(into circleId: String) {
        guard let summary, let url = archiveURL, case .previewing = phase else { return }
        let items = summary.items
        phase = .importing(done: 0, total: items.count)
        cancelled = false

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
            for (idx, item) in items.enumerated() {
                if await MainActor.run(body: { [weak self] in self?.cancelled ?? true }) { break }
                let refs = await Self.stage(item, zip: zip, byName: byName)
                if refs.isEmpty {
                    skipped += 1
                } else {
                    // Everything imports as a POST, including stories and reels. A Haven story is
                    // ephemeral by design (24 h retention); an archived story that never expires is
                    // not a story, it is history — and history belongs in the feed where it can
                    // still be scrolled to a year from now.
                    let body = item.body, at = item.createdAt
                    await MainActor.run {
                        FeedStore.shared.postImported(circleId: circleId, body: body, media: refs,
                                                      music: nil, story: false, createdAt: at)
                    }
                    imported += 1
                }
                let done = idx + 1, total = items.count
                await MainActor.run { [weak self] in self?.phase = .importing(done: done, total: total) }
            }
            let finalImported = imported, finalSkipped = skipped
            await MainActor.run { [weak self] in
                self?.phase = .finished(imported: finalImported, skipped: finalSkipped)
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
                                          byName: [String: ZipReader.Entry]) async -> [String] {
        var refs: [String] = []
        for name in item.mediaNames {
            guard let entry = byName[name] else { continue }
            // Disk read + CRC over the entry — the expensive part, and the reason this is detached.
            guard let bytes = zip.data(for: entry) else { continue }

            if isVideo(name) {
                // prepareVideo transcodes with AVFoundation and needs a file URL, so the clip is
                // spilled to scratch and removed as soon as it is staged.
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("igimport_\(UUID().uuidString).\(ext(name))")
                guard (try? bytes.write(to: scratch)) != nil else { continue }
                defer { try? FileManager.default.removeItem(at: scratch) }
                // forceOptimize: an import is bulk media at someone else's encoder settings —
                // running it through Haven's ladder is what stops a 1.2 GB archive from landing on
                // the relay as-is. alsoOriginal: false — shipping the originals too would double an
                // already large import, for bytes that are themselves a compressed re-encode.
                let prepared = await MediaStore.shared.prepareVideo(url: scratch, forceOptimize: true,
                                                                    alsoOriginal: false)
                // mediaRefs already carries poster + poster marker + clip in the order the feed
                // expects (poster first — MediaVariants.composeVideoMedia), so a video tile has its
                // still from the moment it arrives.
                if !prepared.isEmpty { refs.append(contentsOf: prepared.mediaRefs) }
            } else {
                // Decode + re-encode are MainActor work (MediaStore is main-isolated), and the
                // encoded bytes are what the content ref is minted from.
                let ref = await MainActor.run { () -> String? in
                    guard let image = PlatformImage(data: bytes) else { return nil }
                    return MediaStore.shared.addImage(image, forceOptimize: true)
                }
                if let ref { refs.append(ref) }
            }
        }
        return refs
    }

    private nonisolated static func ext(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.isEmpty ? "mp4" : e
    }
    private nonisolated static func isVideo(_ name: String) -> Bool {
        ["mp4", "mov", "m4v"].contains(ext(name))
    }
}
