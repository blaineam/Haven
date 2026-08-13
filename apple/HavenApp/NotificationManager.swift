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
            // Always complete exactly once — even when the expiration handler cancels us.
            defer {
                // Re-park after work so any ingest side-effect cannot leave Multipeer / media
                // timers warm under the residual assertion window.
                FeedStore.shared.syncForegroundFromSystem()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            // Cold BGAppRefresh never gets scenePhase — park before any work so timers/Multipeer
            // don't run the foreground cadence under the refresh assertion.
            FeedStore.shared.syncForegroundFromSystem()
            await BackgroundUploader.shared.flush()   // finish any posts that didn't reach the mailbox
            // SLIM background sync — NOT forceSync. A BG-refresh window is ~30s of battery the
            // system lends us while the phone is pocketed: bringing up Multipeer discovery and
            // fanning hello+roster to every contact there was pure heat with nobody to answer.
            // Push-inbox drain + a mailbox-only pull + the upload-queue flush is the whole point
            // of the wake; when the poll comes back empty we end the window EARLY (quick no-op)
            // instead of idling out the full grant — that was part of "Haven ran 2h in Background".
            let gotSomething = await FeedStore.shared.slimBackgroundSync()
            if gotSomething && !Task.isCancelled {
                // Give ingest side effects (banner posting, sibling fan-out) a short window —
                // still far shorter than sitting on the full BG grant.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
    #endif

    /// Post a local notification (only when the app isn't in the foreground). Deduped by
    /// `dedupeKey` across relaunches (persisted), so re-ingested history can't re-notify.
    /// `persist: false` keeps the old session-only dedupe — for deliberate, repeatable flows
    /// (e.g. device enrollment) where the SAME key should notify again on a later occasion.
    /// `deepLink` (a `haven://…` URL) makes the notification OPEN something when tapped instead of
    /// just raising the app — carried in userInfo and routed through the same DeepLink parser as a
    /// pasted or shared link, so there is one route table rather than a parallel one.
    func notify(title: String, body: String, dedupeKey: String, persist: Bool = true, deepLink: String? = nil) {
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
        if let deepLink { content.userInfo["havenDeepLink"] = deepLink }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        #if os(iOS)
        // Mirror to the Apple Watch so the same alert surfaces there (and refresh its threads).
        WatchSessionManager.shared.mirrorNotification(title: title, body: body, dedupeKey: dedupeKey)
        WatchSessionManager.shared.pushSnapshot()
        #endif
    }

    /// Route a tapped notification that carries a `havenDeepLink`. Until now nothing handled taps at
    /// all — a notification could only raise the app, so "your media is back" had no way to take you
    /// to the post it was about. Registered from the app's startup.
    func registerTapRouting() {
        UNUserNotificationCenter.current().delegate = Self.tapRouter
    }
    private static let tapRouter = NotificationTapRouter()
}

/// Turns a tapped notification's `havenDeepLink` into an in-app route. Deliberately reuses
/// `DeepLinkRouter` rather than parsing URLs a second way — one route table, one set of rules about
/// what a link may open (a locked circle still lands on its lock screen, not the post).
private final class NotificationTapRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let link = info["havenDeepLink"] as? String, let url = URL(string: link) {
            Task { @MainActor in
                // `handle` also wants to switch tabs, which a delegate has no binding for; the
                // published `route` is what actually presents, so a scratch tab is enough here.
                var scratchTab = ""
                _ = DeepLinkRouter.shared.handle(url, tab: &scratchTab)
            }
        }
        completionHandler()
    }

    /// Show Haven's own notifications while the app is frontmost too — otherwise "media is back"
    /// silently does nothing for someone who is already looking at the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A push that arrives while we're FRONTMOST comes here instead of to the NSE — so this was the
        // one path that saw the sealed event inline (`ev`) and threw it away. The banner appeared and
        // the message did not, for as long as the app stayed open: nothing ingested the envelope, and
        // nothing drained the queue until the next cold launch. Exactly the "I get a notification for
        // the thread I'm looking at and no message ever shows up" report.
        //
        // Ingest it here, same as the NSE and silent-push paths do. Bounded: the queue is capped at 64
        // and ingestPushInbox does the receive() crypto off-main in one batch.
        if let ev = notification.request.content.userInfo["ev"] as? String,
           let env = Data(base64Encoded: ev) {
            SharedInbox.append(env: env)
            Task { @MainActor in FeedStore.shared.ingestPushInbox() }
        }
        // And sync REGARDLESS of whether the event rode along: the worker drops `ev` whenever the
        // payload would exceed APNs' 4KB, so "no inline event" is the normal case for anything large,
        // not an anomaly. Without this the banner was the only trace such a message ever left.
        Task { @MainActor in FeedStore.shared.syncBecauseOfPush() }
        completionHandler([.banner, .sound])
    }
}
