import Foundation
import Combine

/// Manual "Rescan imported videos": walks this account's video posts that still have no song chip
/// — every imported reel is one (the 12 s signature bug ate the import run: 4 of 81 named), plus
/// anything filmed before the chip existed — and feeds them through the same throttled queue, one
/// at a time, honouring the scan ledger. Manual on purpose (owner's request, 2026-09-01): a bulk
/// pass over dozens of reels is Shazam rate-limit and phone-heat territory, so it never runs unasked.
/// Resumable: the queue itself is persisted, and a second press skips everything the ledger already
/// answered.
@MainActor
final class ShazamRescan: ObservableObject {
    static let shared = ShazamRescan()

    @Published private(set) var running = false
    @Published private(set) var progress: String?

    private var total = 0
    private var checked = 0
    private var named = 0
    private var pending = Set<String>()
    private var observer: NSObjectProtocol?

    func start() {
        guard !running else { return }
        running = true
        progress = "Looking for videos without a song…"
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: ShazamRetryQueue.itemFinished, object: nil, queue: .main
            ) { [weak self] n in
                guard let id = n.userInfo?["postId"] as? String,
                      let matched = n.userInfo?["matched"] as? Bool else { return }
                Task { @MainActor in self?.finished(id, matched: matched) }
            }
        }
        Task { @MainActor in
            let candidates = await FeedStore.shared.ownUntaggedVideoPosts()
            total = candidates.count; checked = 0; named = 0; pending.removeAll()
            let ledger = ShazamScanLedger.shared
            for c in candidates {
                await ledger.forgetTransient(c.postId)   // a manual pass may ask again about refusals
                if let e = await ledger.entry(for: c.postId) {   // a deterministic answer is already on file
                    checked += 1
                    if e.outcome == .matched { named += 1 }
                    continue
                }
                pending.insert(c.postId)
                ShazamRetryQueue.shared.enqueue(postId: c.postId, circleId: c.circleId, videoRef: c.ref, firstDelay: 0)
            }
            updateLine()
            if pending.isEmpty { running = false; return }
            ShazamRetryQueue.shared.start()
        }
    }

    private func finished(_ postId: String, matched: Bool) {
        guard pending.remove(postId) != nil else { return }
        checked += 1
        if matched { named += 1 }
        updateLine()
        if pending.isEmpty { running = false }
    }

    private func updateLine() {
        progress = total == 0 ? "No videos without a song." : "\(checked) of \(total) checked · \(named) named"
    }
}
