import Foundation

/// What Shazam said about a post's video, remembered per post.
enum ShazamScanOutcome: String, Codable {
    case matched          // a credit chip is on the post
    case notInCatalog     // Shazam looked and had no answer — an answer, never re-asked
    case noAudio          // the clip has no audible track
    case tooShort         // under the 3 s the catalog needs
    case badSignature     // 201 — the signature itself was refused (deterministic)
    case transient        // 202 / 500 / no answer — may be asked again after a back-off
    case exhausted        // transient refusals hit the cap; costs nothing until a manual rescan
    case failed           // some other deterministic error; a manual rescan may try again
}

/// Per-post scan ledger for the song-credit feature.
///
/// Owner's request, 2026-09-01: play an older, untagged video and it inherits its chip — so playback
/// triggers a scan, and this is what stops the same clip being fingerprinted on every play. A post is
/// scanned at most once for a deterministic answer and re-asked only for a transient one, after a
/// back-off, a bounded number of times.
///
/// A small JSON file in Application Support, written by this serialized actor and loaded once —
/// NOT a UserDefaults blob written on the main actor (the BackgroundUploader lesson: a fat prefs
/// write is a synchronous cfprefsd XPC round-trip on whatever thread makes it).
actor ShazamScanLedger {
    static let shared = ShazamScanLedger()

    struct Entry: Codable {
        var outcome: ShazamScanOutcome
        var at: TimeInterval
        var attempts: Int
    }

    /// Transient refusals are re-asked at most this many times, 30 min × 2ⁿ apart; then `exhausted`.
    static let maxTransientAttempts = 4
    private static let transientBase: TimeInterval = 30 * 60

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var writeScheduled = false

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-shazam-ledger.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func entry(for postId: String) -> Entry? {
        loadIfNeeded()
        return entries[postId]
    }

    /// May this post be (re)scanned now? Unknown: yes. Deterministic outcomes: never. Transient:
    /// after its back-off, until the attempt cap.
    func shouldScan(_ postId: String, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        loadIfNeeded()
        guard let e = entries[postId] else { return true }
        switch e.outcome {
        case .transient:
            guard e.attempts < Self.maxTransientAttempts else { return false }
            return now >= e.at + Self.transientBase * pow(2, Double(max(0, e.attempts - 1)))
        default:
            return false
        }
    }

    func record(_ postId: String, outcome: ShazamScanOutcome, now: TimeInterval = Date().timeIntervalSince1970) {
        loadIfNeeded()
        var attempts = entries[postId]?.attempts ?? 0
        var final = outcome
        if outcome == .transient {
            attempts += 1
            if attempts >= Self.maxTransientAttempts { final = .exhausted }
        }
        entries[postId] = Entry(outcome: final, at: now, attempts: attempts)
        scheduleWrite()
    }

    /// Manual rescan: a transient / exhausted post may be asked again from a clean slate.
    /// Deterministic answers stay — asking Shazam about a clip it has already said is not in its
    /// catalog is heat for nothing.
    func forgetTransient(_ postId: String) {
        loadIfNeeded()
        guard let e = entries[postId], e.outcome == .transient || e.outcome == .exhausted || e.outcome == .failed else { return }
        entries[postId] = nil
        scheduleWrite()
    }

    func outcomes(for postIds: [String]) -> [String: ShazamScanOutcome] {
        loadIfNeeded()
        var out: [String: ShazamScanOutcome] = [:]
        for id in postIds { if let e = entries[id] { out[id] = e.outcome } }
        return out
    }

    /// Coalesced atomic write, half a second after the last change.
    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.flush()
        }
    }

    private func flush() {
        writeScheduled = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
