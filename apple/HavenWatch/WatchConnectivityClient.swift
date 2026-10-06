import Foundation
import WatchConnectivity
import UserNotifications
import SwiftUI   // ImageRenderer for synthetic demo thumbnails

/// Watch-side WCSession client. The phone holds the iroh node + identity; this just asks the
/// phone for recent threads, displays them, and sends quick replies / reactions back. All
/// published state is mutated on the main actor so SwiftUI stays happy.
@MainActor
final class WatchConnectivityClient: NSObject, ObservableObject {
    static let shared = WatchConnectivityClient()

    @Published private(set) var threads: [WatchThread] = []
    @Published private(set) var openThread: WatchThreadDetail?
    @Published private(set) var reachable = false
    @Published private(set) var lastSyncedAt: UInt64 = 0
    /// True while we're waiting on a reply for the currently-open thread.
    @Published private(set) var loadingThread = false
    /// Watchdog so a thread NEVER spins forever — e.g. when a media-heavy reply exceeds
    /// WatchConnectivity's message-size limit and the reply/error handler never fires.
    private var loadTimeout: Task<Void, Never>?

    private func beginLoadTimeout() {
        loadTimeout?.cancel()
        loadTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            self.loadingThread = false   // stop the spinner; show whatever's cached/empty
        }
    }
    private func finishLoading() {
        loadTimeout?.cancel(); loadTimeout = nil
        loadingThread = false
    }

    private var session: WCSession { WCSession.default }

    func start() {
        if seedDemoIfNeeded() { return }   // offline screenshot harness — no live session
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    /// Every demo thread's contents, keyed by thread id, so opening any of them works offline.
    private var demoThreads: [String: WatchThreadDetail] = [:]

    /// HAVENWATCH_DEMO=1 (or a `-UITestMode` UI-test launch) — PII-free synthetic threads/messages
    /// so the UI is screenshottable and testable without a paired iPhone (mirrors the phone app's
    /// DemoEnv harness). DEBUG-only: a release build always talks to the real phone. Returns true
    /// when seeded, so `start()` skips activating a real (empty) session.
    @discardableResult
    private func seedDemoIfNeeded() -> Bool {
        guard WatchDemo.isOn else { return false }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        threads = [
            WatchThread(id: "dm:ari", title: "Ari", subtitle: "On my way 🚲", timestamp: now - 90_000, isDM: true, unread: 1),
            WatchThread(id: "dm:noa", title: "Noa", subtitle: "❤️ that photo", timestamp: now - 1_800_000, isDM: true, unread: 0),
            WatchThread(id: "circle:trail", title: "Trail Crew", subtitle: "Sunset hike Saturday?", timestamp: now - 5_400_000, isDM: false, unread: 0),
        ]
        let dm = WatchThreadDetail(threadId: "dm:ari", title: "Ari", isDM: true, messages: [
            WatchMessage(id: "m1", author: "Ari", isMe: false, body: "Heading over now", timestamp: now - 240_000, hasMedia: false, reactions: "👍1"),
            WatchMessage(id: "m2", author: "You", isMe: true, body: "Cool, door's open", timestamp: now - 180_000, hasMedia: false, reactions: ""),
            WatchMessage(id: "m3", author: "Ari", isMe: false, body: "On my way 🚲", timestamp: now - 90_000, hasMedia: false, reactions: "❤️2"),
            WatchMessage(id: "m4", author: "Ari", isMe: false, body: "Made it to the top!", timestamp: now - 60_000, hasMedia: true,
                         reactions: "🔥3", media: Self.demoMedia()),
        ])
        let media = Self.demoMedia()
        let circle = WatchThreadDetail(threadId: "circle:trail", title: "Trail Crew", isDM: false, messages: [
            WatchMessage(id: "s1", author: "Noa", isMe: false, body: "golden hour up here", timestamp: now - 3_600_000,
                         hasMedia: true, reactions: "", media: Array(media.prefix(1)), isStory: true),
            WatchMessage(id: "p1", author: "Noa", isMe: false, body: "Sunset hike Saturday?", timestamp: now - 5_400_000,
                         hasMedia: false, reactions: "👍2"),
        ])
        demoThreads = [dm.threadId: dm, circle.threadId: circle,
                       "dm:noa": WatchThreadDetail(threadId: "dm:noa", title: "Noa", isDM: true, messages: [
                           WatchMessage(id: "n1", author: "Noa", isMe: false, body: "❤️ that photo",
                                        timestamp: now - 1_800_000, hasMedia: false, reactions: ""),
                       ])]
        openThread = dm
        reachable = true
        lastSyncedAt = now
        return true
    }

    /// Synthetic gradient "photos" standing in for real post media in the demo harness — two with
    /// different aspect ratios so the carousel + true-aspect rendering are exercised. (ImageRenderer is
    /// the watchOS-available rasterizer; UIGraphicsImageRenderer isn't.)
    @MainActor private static func demoMedia() -> [WatchMedia] {
        func gradient(_ a: Color, _ b: Color, _ w: Int, _ h: Int) -> WatchMedia? {
            let view = LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: CGFloat(w), height: CGFloat(h))
            let r = ImageRenderer(content: view); r.scale = 2
            return r.uiImage?.jpegData(compressionQuality: 0.6).map { WatchMedia(thumbnail: $0, w: w, h: h, isVideo: false) }
        }
        return [gradient(WTheme.pink, WTheme.violet, 160, 120),
                gradient(WTheme.violet, WTheme.amber, 120, 150)].compactMap { $0 }
    }

    // MARK: - Requests to the phone

    func refresh() {
        guard activated else { return }
        if session.isReachable {
            session.sendMessage(WatchCodec.encode(.requestSnapshot), replyHandler: { [weak self] reply in
                Task { @MainActor in self?.ingest(reply) }
            }, errorHandler: nil)
        }
        // Always fall back to whatever the phone last pushed as application context.
        ingest(session.receivedApplicationContext)
    }

    func openThread(_ threadId: String) {
        if WatchDemo.isOn {
            openThread = demoThreads[threadId]
            finishLoading()
            return
        }
        loadingThread = true
        beginLoadTimeout()
        // Show what we already have immediately if the same thread is cached.
        if openThread?.threadId != threadId { openThread = nil }
        guard activated else { finishLoading(); return }
        let payload = WatchCodec.encode(.requestThread, WatchThreadRequest(threadId: threadId))
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.ingest(reply) }
            }, errorHandler: { [weak self] _ in
                // Live send failed mid-flight — queue it so the phone wakes to answer via userInfo
                // (the response comes back through didReceiveUserInfo → ingest).
                self?.session.transferUserInfo(payload)
            })
        } else {
            // Phone app isn't active/reachable — DON'T give up (that left threads stuck on "No posts
            // yet"). Queue the request; it can wake the phone in the background to respond via userInfo.
            session.transferUserInfo(payload)
        }
    }

    func sendReply(threadId: String, body: String, targetId: String? = nil) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if WatchDemo.isOn, !trimmed.isEmpty {
            // Demo: no phone to send to — echo the reply locally, as the phone's answer would.
            demoAppend(threadId, WatchMessage(id: "demo-\(UUID().uuidString)", author: "You", isMe: true, body: trimmed,
                                              timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                              hasMedia: false, reactions: ""))
            return
        }
        guard !trimmed.isEmpty, activated else { return }
        loadingThread = true
        beginLoadTimeout()
        let payload = WatchCodec.encode(.quickReply, WatchReply(threadId: threadId, body: trimmed, targetId: targetId))
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.ingest(reply) }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in self?.finishLoading() }
            })
        } else {
            // Queued delivery when the phone is briefly unreachable.
            session.transferUserInfo(payload)
            finishLoading()
        }
    }

    func react(threadId: String, messageId: String, emoji: String) {
        if WatchDemo.isOn {
            guard var detail = demoThreads[threadId],
                  let i = detail.messages.firstIndex(where: { $0.id == messageId }) else { return }
            let r = detail.messages[i].reactions
            detail.messages[i].reactions = r.isEmpty ? "\(emoji)1" : "\(r) \(emoji)1"
            demoThreads[threadId] = detail
            if openThread?.threadId == threadId { openThread = detail }
            return
        }
        guard activated else { return }
        let payload = WatchCodec.encode(.react, WatchReaction(threadId: threadId, messageId: messageId, emoji: emoji))
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.ingest(reply) }
            }, errorHandler: nil)
        } else {
            session.transferUserInfo(payload)
        }
    }

    private func demoAppend(_ threadId: String, _ message: WatchMessage) {
        guard var detail = demoThreads[threadId] else { return }
        detail.messages.append(message)
        demoThreads[threadId] = detail
        if openThread?.threadId == threadId { openThread = detail }
    }

    // MARK: - Inbound

    private var activated: Bool { session.activationState == .activated }

    private func ingest(_ message: [String: Any]) {
        switch WatchCodec.kind(of: message) {
        case .snapshot:
            if let snap = WatchCodec.decode(WatchSnapshot.self, from: message) {
                threads = snap.threads
                lastSyncedAt = snap.generatedAt
            }
        case .thread:
            if let detail = WatchCodec.decode(WatchThreadDetail.self, from: message) {
                openThread = detail
                finishLoading()
            }
        case .notify:
            if let notice = WatchCodec.decode(WatchNotice.self, from: message) {
                postLocalNotification(notice)
            }
        default:
            break
        }
    }

    private func postLocalNotification(_ notice: WatchNotice) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "wmirror-\(notice.dedupeKey)", content: content, trigger: nil))
        refresh()   // freshen the thread list alongside the alert
    }
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.reachable = session.isReachable
            self.refresh()
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if session.isReachable { self.refresh() }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.ingest(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.ingest(userInfo) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.ingest(message) }
    }
    #if os(iOS)
    // WCSessionDelegate requires these only on iOS — the watch app never compiles them on
    // watchOS, but the iOS SDK (used when this target is built alongside the phone) needs them
    // for protocol conformance.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}

/// The watch's demo / UI-test switch. DEBUG-only: `isOn` is constant `false` in a release build.
enum WatchDemo {
    static let isOn: Bool = {
        #if DEBUG
        let p = ProcessInfo.processInfo
        return p.environment["HAVENWATCH_DEMO"] == "1" || p.arguments.contains("-UITestMode")
        #else
        return false
        #endif
    }()

    /// The thread to auto-open for its screenshot (`HAVENWATCH_DEMO_SCENE=thread`), DEBUG-only.
    static var opensThread: Bool {
        #if DEBUG
        return isOn && ProcessInfo.processInfo.environment["HAVENWATCH_DEMO_SCENE"] == "thread"
        #else
        return false
        #endif
    }
}
