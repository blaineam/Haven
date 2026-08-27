import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Makes sure a post/message you authored reaches the shared mailbox even if you background
/// the app mid-upload. Authored events are enqueued to a persisted queue and flushed under a
/// UIKit background-task assertion (so iOS grants extra time to finish on the way out); anything
/// that still doesn't make it is retried on the next launch / background refresh. Uploads are
/// idempotent (content-addressed mailbox keys), so retries are always safe.
@MainActor
final class BackgroundUploader {
    static let shared = BackgroundUploader()

    private struct Pending: Codable { let circleId: String; let env: Data }
    private let key = "haven.pendingUploads"
    private let maxQueued = 200
    private var queue: [Pending]
    private var flushing = false
    /// Re-arm state. Two bugs lived here (field-reported as "my posts/reactions don't reach
    /// anyone until I relaunch the app"): (1) `enqueue` during an in-flight flush bounced off the
    /// `flushing` guard, so anything authored inside another upload's network round-trip — every
    /// reaction burst — sat queued with NOTHING scheduled to send it; (2) a failed upload had no
    /// retry timer at all, so one relay hiccup stranded the event until the next launch /
    /// scene-phase / BGRefresh trigger. Now every pass that ends with work left (or work that
    /// arrived mid-pass) schedules the next pass itself, with capped backoff. Uploads are
    /// idempotent (content-addressed keys), so the worst a retry can do is a no-op.
    private var enqueuedWhileFlushing = false
    private var retryTask: Task<Void, Never>?
    private var backoffSecs: UInt64 = 3
    private let backoffCapSecs: UInt64 = 120

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Pending].self, from: data) {
            queue = list
        } else {
            queue = []
        }
    }

    /// Whether any authored event for this circle is still waiting to reach the relay mailbox (drives
    /// the post sync-status light: pending = "syncing", empty = "in the relay").
    func hasPending(circleId: String) -> Bool { queue.contains { $0.circleId == circleId } }

    /// Is ANY authored event still waiting for a mailbox, in any circle? This is one of the few
    /// honest reasons to ask iOS for another background wake — see
    /// `NotificationManager.scheduleRefresh`.
    var hasAnyPending: Bool { !queue.isEmpty }

    /// Is an upload flush ACTIVELY running right now? The sync-status light shows "Syncing…" off this
    /// (a transient, real upload) rather than off `hasPending` (a queue that may be stuck/unreachable and
    /// would otherwise pin the badge to yellow forever — the post already went directly to online members,
    /// and the relay copy is best-effort + retried silently).
    var isFlushing: Bool { flushing }

    /// Queue an authored event for mailbox upload and kick off a flush.
    func enqueue(circleId: String, env: Data) {
        queue.append(Pending(circleId: circleId, env: env))
        if queue.count > maxQueued { queue.removeFirst(queue.count - maxQueued) }
        save()
        backoffSecs = 3   // fresh user action: retry eagerly again even if we'd backed off
        if flushing {
            enqueuedWhileFlushing = true   // the running pass re-arms on exit; the guard would eat this Task
        } else {
            Task { await flush() }
        }
    }

    /// Schedule the next flush attempt. One timer at a time — a newer schedule replaces the old.
    private func scheduleRetry(after secs: UInt64) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Upload everything still pending, holding a background-task assertion so it can finish
    /// after the app leaves the foreground. Items that fail stay queued for the next attempt.
    func flush() async {
        guard !flushing, !queue.isEmpty else { return }
        flushing = true
        defer { flushing = false }

        // iOS suspends the app shortly after backgrounding; a background-task assertion keeps the
        // upload alive long enough to finish. macOS apps aren't suspended this way — no-op there.
        // Expiration handler is mandatory: a hung relay PUT must not pin the process (and the
        // battery meter) until the system force-kills us.
        #if canImport(UIKit)
        var bgId: UIBackgroundTaskIdentifier = .invalid
        bgId = UIApplication.shared.beginBackgroundTask(withName: "haven.upload") {
            let id = bgId
            bgId = .invalid
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
        defer {
            let id = bgId
            bgId = .invalid
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
        #endif

        let work = queue
        var stillPending: [Pending] = []
        for (i, item) in work.enumerated() {
            #if canImport(UIKit)
            // System revoked our time — leave this item and the rest queued for the next wake.
            if bgId == .invalid {
                stillPending.append(contentsOf: work[i...])
                break
            }
            #endif
            let ok = await SharedStore.uploadEvent(circleId: item.circleId, env: item.env)
            if !ok { stillPending.append(item) }
        }
        // Keep anything that failed, plus anything newly enqueued while we were uploading.
        let newlyAdded = queue.count > work.count ? Array(queue.suffix(queue.count - work.count)) : []
        queue = stillPending + newlyAdded
        save()

        // Re-arm. This is what turns one-shot best-effort into "keeps trying until it's in the
        // relay": mid-pass arrivals go again immediately; failures go again on capped backoff.
        let hadMidPassArrivals = enqueuedWhileFlushing || !newlyAdded.isEmpty
        enqueuedWhileFlushing = false
        if hadMidPassArrivals && !queue.isEmpty {
            backoffSecs = 3
            scheduleRetry(after: 0)
        } else if !stillPending.isEmpty {
            HavenLog.sync("uploader: \(stillPending.count) event(s) still pending — retrying in \(backoffSecs)s")
            scheduleRetry(after: backoffSecs)
            backoffSecs = min(backoffSecs * 2, backoffCapSecs)
        } else {
            backoffSecs = 3
            retryTask?.cancel(); retryTask = nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
