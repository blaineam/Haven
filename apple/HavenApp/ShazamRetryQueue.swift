import Foundation

/// Posts whose music could not be identified YET, held for another try.
///
/// Shazam refuses far more often than it fails: in a real import run, 50 of 81 attempts came back
/// rate-limited (error 201) in 0.0s — the audio was never even looked at. Dropping those on the
/// floor threw away most of the credits the feature exists to produce, and they are not recoverable
/// afterwards because the post has already published.
///
/// So a refusal parks the post here instead. A single worker drains the queue slowly, backing off
/// hard whenever it is refused again, and attaches the credit by EDITING the published post once an
/// answer arrives. It is persisted, so a queue built during an import survives being killed and
/// carries on later — which matters, because "later" is exactly when Shazam is willing to talk.
///
/// Deliberately separate from the importer: identification is not part of publishing, and anything
/// in the app that has a video can enqueue for this.
@MainActor
final class ShazamRetryQueue: ObservableObject {
    static let shared = ShazamRetryQueue()

    private struct Item: Codable {
        let postId: String
        let circleId: String
        /// The STAGED media ref, not a temp path. Temp clips are deleted as soon as a post is
        /// staged, and the archive may be long gone by the time a retry runs — but the video Haven
        /// stored is still there, and it is the same audio.
        let videoRef: String
        var attempts: Int
        var nextAttemptAt: TimeInterval
    }

    private static let key = "haven.shazam.retryQueue"
    /// Give up after this many refusals. Six attempts spans roughly an hour of backoff, which is
    /// long enough to outlast a throttling window without retrying forever.
    private static let maxAttempts = 6

    private var items: [Item] = []
    private var draining = false

    @Published private(set) var pendingCount = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        pendingCount = items.count
    }

    // MARK: - Enqueue

    /// Park a post for a later identification attempt.
    ///
    /// Idempotent per post: an import can stage the same post twice across a resume, and two
    /// entries would mean two edits attaching the same credit.
    func enqueue(postId: String, circleId: String, videoRef: String) {
        guard !postId.isEmpty, !videoRef.isEmpty else { return }
        guard !items.contains(where: { $0.postId == postId }) else { return }
        items.append(Item(postId: postId, circleId: circleId, videoRef: videoRef,
                          attempts: 0, nextAttemptAt: Date().timeIntervalSince1970 + Self.firstDelay))
        save()
        HavenLog.sync("shazam-retry: queued \(postId.prefix(8)) (\(items.count) waiting)")
    }

    /// The first retry waits a while on purpose. Being refused means Shazam wants us to stop asking,
    /// and trying again immediately is what got us refused in the first place.
    private static let firstDelay: TimeInterval = 120

    // MARK: - Draining

    /// Start the worker if it isn't already running. Safe to call repeatedly (app launch, import
    /// finishing, foreground) — it self-cancels when the queue empties.
    func start() {
        guard !draining, !items.isEmpty else { return }
        draining = true
        Task { [weak self] in
            await self?.drain()
            await MainActor.run { self?.draining = false }
        }
    }

    private func drain() async {
        while !items.isEmpty {
            // Earliest-due first, so a long backoff on one post doesn't hold up the others.
            guard let idx = items.indices.min(by: { items[$0].nextAttemptAt < items[$1].nextAttemptAt })
            else { return }
            let item = items[idx]

            let wait = item.nextAttemptAt - Date().timeIntervalSince1970
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 300) * 1_000_000_000))
                continue                      // re-evaluate: something sooner may have been queued
            }

            guard let clip = await Self.clipURL(for: item.videoRef) else {
                remove(item.postId); continue // the media is gone; nothing to identify
            }
            defer { try? FileManager.default.removeItem(at: clip) }

            let outcome = await ShazamDetector.identifyDetailed(clip)
            if let track = outcome.track {
                HavenLog.sync("shazam-retry: MATCHED \(track.title) for \(item.postId.prefix(8))")
                FeedStore.shared.attachSongCredit(postId: item.postId, circleId: item.circleId, track: track)
                remove(item.postId)
                continue
            }

            // A definitive answer is not worth retrying — only a refusal is.
            let refused = outcome.reason.contains("201") || outcome.reason.contains("no result")
            guard refused, item.attempts + 1 < Self.maxAttempts else {
                HavenLog.sync("shazam-retry: giving up on \(item.postId.prefix(8)) — \(outcome.reason)")
                remove(item.postId); continue
            }

            // Exponential: 2m, 4m, 8m, 16m, 32m.
            let attempts = item.attempts + 1
            let delay = Self.firstDelay * pow(2, Double(attempts))
            if let i = items.firstIndex(where: { $0.postId == item.postId }) {
                items[i].attempts = attempts
                items[i].nextAttemptAt = Date().timeIntervalSince1970 + delay
                save()
            }
            HavenLog.sync("shazam-retry: \(outcome.reason) for \(item.postId.prefix(8)) — "
                + "attempt \(attempts), next in \(Int(delay / 60))m")
        }
    }

    private func remove(_ postId: String) {
        items.removeAll { $0.postId == postId }
        save()
    }

    private func save() {
        pendingCount = items.count
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Spill a stored video back to a temp file so AVFoundation can read its audio.
    private nonisolated static func clipURL(for ref: String) async -> URL? {
        guard let bytes = await MainActor.run(body: { MediaStore.shared.rawBytes(ref) }) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shazamretry_\(UUID().uuidString).mp4")
        guard (try? bytes.write(to: url)) != nil else { return nil }
        return url
    }
}
