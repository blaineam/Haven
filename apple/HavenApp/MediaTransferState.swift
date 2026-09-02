import Foundation
import Combine

/// Chunk progress of a relay restore, for the placeholder's "Downloading… i/n".
struct MediaRestoreProgress: Equatable {
    let done: Int
    let total: Int
}

/// Per-blob transfer state behind the media placeholders — spinner, i/n chunk progress, "waiting
/// for sender…", "no longer available".
///
/// Split OFF `FeedStore` (owner's thermal report, 2026-09-01). The DEBUG publish census logged
/// `FeedStore published 1101x in 5s` with only three of those attributed to the watched properties;
/// the rest came from these four, which were `@Published` on the store but never in the census —
/// `mediaRestoreProgress` most of all, written PER CHUNK of a relay restore. Every one of those
/// publishes invalidated every PostCard body on screen (the profile's "84% AttributeGraph" main
/// thread) for a number only one small placeholder draws. Now only the placeholders observe this
/// object; the sets publish only when their value actually changes, and chunk progress is coalesced
/// to one publish per ~100 ms.
@MainActor
final class MediaTransferState: ObservableObject {
    static let shared = MediaTransferState()

    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var waitingForSender: Set<String> = []
    @Published private(set) var restoreProgress: [String: MediaRestoreProgress] = [:]

    // Change-guarded setters: a `Set.insert` of a member already present, or a `remove` of one that
    // is absent, must not publish — `@Published` fires on every assignment, not on every change.
    func setDownloading(_ v: Set<String>) { if v != downloading { downloading = v } }
    func setUnavailable(_ v: Set<String>) { if v != unavailable { unavailable = v } }
    func setWaitingForSender(_ v: Set<String>) { if v != waitingForSender { waitingForSender = v } }
    func setRestoreProgress(_ v: [String: MediaRestoreProgress]) { if v != restoreProgress { restoreProgress = v } }

    /// Per-chunk progress lands here and is published at most every ~100 ms — a 32 KB-chunk restore
    /// reports hundreds of times a second and the placeholder cannot show more than a few of them.
    private var pendingProgress: [String: MediaRestoreProgress] = [:]
    private var flushScheduled = false
    func noteRestoreProgress(_ ref: String, done: Int, total: Int) {
        pendingProgress[ref] = MediaRestoreProgress(done: done, total: total)
        if !downloading.contains(ref) { downloading.insert(ref) }   // a chunked pull IS a download — say so
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.flushScheduled = false
            var next = self.restoreProgress
            for (ref, p) in self.pendingProgress { next[ref] = p }
            self.pendingProgress.removeAll()
            self.setRestoreProgress(next)
        }
    }
    /// Drop a ref's progress now (the blob landed or the restore was cleared) — including anything
    /// still pending, so a late flush cannot resurrect it.
    func clearRestoreProgress(_ ref: String) {
        pendingProgress.removeValue(forKey: ref)
        if restoreProgress[ref] != nil { restoreProgress.removeValue(forKey: ref) }
    }
}
