import Foundation
import UserNotifications
import BackgroundTasks
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Local notifications with **no server and no third party**. We can't (and won't)
/// run a push service that would learn who talks to whom. Instead: a periodic
/// background-refresh wake briefly brings up P2P networking, syncs with the circle,
/// and posts LOCAL notifications for anything new that arrived. When the app is alive
/// (foreground or briefly backgrounded), inbound events notify directly.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    static let refreshTaskId = "com.blaineam.kith.refresh"

    private var authorized = false
    // Dedupe keys of everything we've already notified about — PERSISTED. This was in-memory
    // only, so every relaunch forgot it and the next ingest burst (mailbox poll, epoch-churn
    // re-seals, history backfill) re-notified the SAME newest message per circle — "the same
    // notifications again and again". `notifiedOrder` keeps insertion order so the cap trims
    // the OLDEST half; the old `removeAll()` at the cap made every past key eligible again.
    private var notified = Set<String>()
    private var notifiedOrder: [String] = []
    private var notifiedLoaded = false
    private var notifiedSavePending = false
    private var notifiedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-notified.txt")
    }
    private func loadNotifiedIfNeeded() {
        guard !notifiedLoaded else { return }
        notifiedLoaded = true
        guard let text = try? String(contentsOf: notifiedURL, encoding: .utf8) else { return }
        for key in text.split(separator: "\n").map(String.init) where notified.insert(key).inserted {
            notifiedOrder.append(key)
        }
    }
    private func scheduleNotifiedSave() {
        guard !notifiedSavePending else { return }
        notifiedSavePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.notifiedSavePending = false
            let snapshot = self.notifiedOrder.joined(separator: "\n")
            DispatchQueue.global(qos: .utility).async { [url = self.notifiedURL] in
                try? snapshot.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Ask once for permission to show local notifications.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Must run at launch (before the app finishes launching). iOS-only — macOS uses the
    /// always-running app + live inbound notifications (no background-refresh wake).
    func registerBackgroundTask() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            // The launch handler runs on a PRIVATE (non-main) queue, so MainActor.assumeIsolated
            // would trap. Hop onto the main actor properly instead — this was the BG crash.
            Task { @MainActor in self.handleRefresh(refresh) }
        }
        #endif
    }

    /// Ask iOS to wake us again later (it decides the real cadence). No-op on macOS.
    func scheduleRefresh() {
        #if os(iOS)
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
        #endif
    }

    #if os(iOS)
    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()   // chain the next wake
        let work = Task { @MainActor in
            await BackgroundUploader.shared.flush()   // finish any posts that didn't reach the mailbox
            FeedStore.shared.forceSync()
            // Give inbound a window to arrive (handleEvent fires notifications itself).
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
    #endif

    /// Post a local notification (only when the app isn't in the foreground). Deduped by
    /// `dedupeKey` across relaunches (persisted), so re-ingested history can't re-notify.
    /// `persist: false` keeps the old session-only dedupe — for deliberate, repeatable flows
    /// (e.g. device enrollment) where the SAME key should notify again on a later occasion.
    func notify(title: String, body: String, dedupeKey: String, persist: Bool = true) {
        guard authorized else { return }
        guard !PlatformApp.isActive else { return }
        loadNotifiedIfNeeded()
        guard notified.insert(dedupeKey).inserted else { return }
        if persist {
            notifiedOrder.append(dedupeKey)
            if notifiedOrder.count > 3000 {   // trim the OLDEST half; never wipe everything
                for old in notifiedOrder.prefix(1500) { notified.remove(old) }
                notifiedOrder.removeFirst(1500)
            }
            scheduleNotifiedSave()
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        #if os(iOS)
        // Mirror to the Apple Watch so the same alert surfaces there (and refresh its threads).
        WatchSessionManager.shared.mirrorNotification(title: title, body: body, dedupeKey: dedupeKey)
        WatchSessionManager.shared.pushSnapshot()
        #endif
    }
}
