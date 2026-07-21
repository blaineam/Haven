#if canImport(WatchConnectivity)
import Foundation
import Combine
import WatchConnectivity

/// iPhone-side bridge to the HavenWatch companion.
///
/// The phone holds the iroh node + identity; the Watch is a thin client. We vend recent DM
/// threads / circle posts and accept quick replies + reactions, routing them through
/// `FeedStore` on the main actor. Nothing here runs the Rust node — it's purely a read/relay
/// surface over what the phone already has.
///
/// This file only compiles where WatchConnectivity exists (iOS) — on native macOS the whole
/// file is empty, so HavenMac stays untouched.
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()
    private override init() { super.init() }

    private var session: WCSession { WCSession.default }
    private var feedObserver: AnyCancellable?

    func start() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        // Keep the Watch's thread list live: re-push a snapshot whenever the feed changes,
        // debounced so a burst of inbound events coalesces into one transfer.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feedObserver = FeedStore.shared.objectWillChange
                .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
                .sink { [weak self] in self?.pushSnapshot() }
        }
    }

    // MARK: - Outbound

    /// Push the latest thread list to the Watch as the application context (the system keeps
    /// only the most recent, delivered whenever the Watch next becomes reachable). Cheap to
    /// call on every feed change.
    @MainActor func pushSnapshot() {
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired else { return }
        let msg = WatchCodec.encode(.snapshot, Self.buildSnapshot())
        try? session.updateApplicationContext(msg)
    }

    /// Mirror a phone-side local notification to the Watch so it surfaces there too.
    func mirrorNotification(title: String, body: String, dedupeKey: String) {
        guard WCSession.isSupported(), session.activationState == .activated, session.isWatchAppInstalled else { return }
        let notice = WatchNotice(title: title, body: body, dedupeKey: dedupeKey)
        session.transferUserInfo(WatchCodec.encode(.notify, notice))
    }

    // MARK: - Snapshot building (on the main actor — FeedStore is @MainActor)

    @MainActor static func buildSnapshot() -> WatchSnapshot {
        let store = FeedStore.shared
        var threads: [WatchThread] = []
        for c in store.dmCircles {
            // feed() is newest-first, so the latest message is `.first` (was `.last` → showed the oldest).
            let latest = store.messages(in: c.id).first
            threads.append(WatchThread(id: c.id, title: store.dmPartnerName(c.id),
                                       subtitle: preview(latest), timestamp: latest?.createdAt ?? 0,
                                       isDM: true, unread: 0))
        }
        for c in store.feedCircles {
            let latest = store.messages(in: c.id).first
            threads.append(WatchThread(id: c.id, title: c.name,
                                       subtitle: preview(latest), timestamp: latest?.createdAt ?? 0,
                                       isDM: false, unread: 0))
        }
        threads.sort { $0.timestamp > $1.timestamp }
        return WatchSnapshot(threads: threads, generatedAt: nowMs())
    }

    @MainActor static func buildThread(_ threadId: String) -> WatchThreadDetail {
        let store = FeedStore.shared
        let isDM = threadId.hasPrefix("dm:")
        let title = isDM ? store.dmPartnerName(threadId)
                         : (store.circles.first { $0.id == threadId }?.name ?? "Circle")
        // feed() is newest-first. DMs read as a chat (oldest→newest, scrolled to bottom); a circle reads
        // as a feed (newest→oldest). Cap the count either way.
        let feed = store.messages(in: threadId)
        let ordered: [FeedItemFfi] = isDM ? Array(feed.reversed().suffix(60)) : Array(feed.prefix(60))
        // Assign real media thumbnails to the most RECENT items first, within a WCSession byte budget;
        // older media-bearing items still flag hasMedia (the watch shows a light placeholder).
        // CRITICAL: the reply rides sendMessage's replyHandler, whose payload limit is ~65KB — a bigger
        // reply silently never arrives, so a media-heavy thread spun forever. Keep the media well under
        // that, leaving room for the message text + encoding overhead.
        var budget = 45_000
        var mediaById: [String: [WatchMedia]] = [:]
        let recentFirst = isDM ? Array(ordered.reversed()) : ordered   // newest-first for budgeting
        for item in recentFirst where !item.media.isEmpty {
            let m = watchMedia(item.media, budget: &budget)
            if !m.isEmpty { mediaById[item.id] = m }
        }
        let messages = ordered.map { item -> WatchMessage in
            WatchMessage(id: item.id,
                         author: authorName(item),
                         isMe: item.isMe,
                         body: item.unsent ? "Message unsent" : item.body,
                         timestamp: item.createdAt,
                         hasMedia: !item.media.isEmpty,
                         reactions: reactionSummary(item.reactions),
                         media: mediaById[item.id] ?? [],
                         isStory: item.story)
        }
        return WatchThreadDetail(threadId: threadId, title: title, isDM: isDM, messages: messages)
    }

    /// The resolved display name for a post/message author — a contact's name/nickname, never the raw
    /// node-id prefix (the Watch was showing the prefix). "You" for our own items.
    @MainActor private static func authorName(_ item: FeedItemFfi) -> String {
        if item.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? item.authorShort
    }

    /// Build the Watch's media carousel for a post: up to 4 items, each a ~300px JPEG (sharp on the
    /// watch, not the old pixelated 120px) carrying the SOURCE pixel size so the watch renders the true
    /// aspect ratio. Stops once the running `budget` is exhausted so the WCSession payload stays bounded.
    @MainActor private static func watchMedia(_ refs: [String], budget: inout Int) -> [WatchMedia] {
        var out: [WatchMedia] = []
        for ref in refs.prefix(4) {
            guard budget > 0, let item = MediaStore.shared.item(ref), let img = item.image else { continue }
            let small = MediaStore.downscale(img, maxDimension: 300)
            guard let data = small.jpegData(compressionQuality: 0.68), data.count <= budget else { continue }
            budget -= data.count
            out.append(WatchMedia(thumbnail: data, w: Int(img.size.width), h: Int(img.size.height), isVideo: item.kind == .video))
        }
        return out
    }

    private static func preview(_ item: FeedItemFfi?) -> String {
        guard let item else { return "" }
        if item.unsent { return "Message unsent" }
        if !item.body.isEmpty { return item.body }
        if !item.media.isEmpty { return "📎 Attachment" }
        if item.music != nil { return "🎵 Song" }
        return ""
    }

    private static func reactionSummary(_ reactions: [ReactionFfi]) -> String {
        reactions.map { "\($0.emoji)\($0.count)" }.joined(separator: " ")
    }

    private static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Inbound routing

    @MainActor private func apply(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
        // When the watch reached us via a live message, answer through its replyHandler. When the
        // request arrived queued via userInfo (the phone app was asleep/unreachable), there is NO
        // reply handler — push the answer back the same way, or the watch waits forever ("No posts
        // yet"). This is exactly the path that left opened threads empty when the phone wasn't active.
        func respond(_ payload: [String: Any]) {
            if let reply { reply(payload) } else { session.transferUserInfo(payload) }
        }
        switch WatchCodec.kind(of: message) {
        case .requestSnapshot:
            respond(WatchCodec.encode(.snapshot, Self.buildSnapshot()))
        case .requestThread:
            if let req = WatchCodec.decode(WatchThreadRequest.self, from: message) {
                respond(WatchCodec.encode(.thread, Self.buildThread(req.threadId)))
            }
        case .quickReply:
            if let r = WatchCodec.decode(WatchReply.self, from: message) {
                if let postId = r.targetId {
                    FeedStore.shared.commentMessage(in: r.threadId, postId, r.body)   // circle: comment on a post
                } else {
                    FeedStore.shared.sendMessage(to: r.threadId, r.body)              // DM / thread message
                }
                respond(WatchCodec.encode(.thread, Self.buildThread(r.threadId)))
            }
        case .react:
            if let r = WatchCodec.decode(WatchReaction.self, from: message) {
                FeedStore.shared.reactMessage(in: r.threadId, r.messageId, r.emoji)
                respond(WatchCodec.encode(.thread, Self.buildThread(r.threadId)))
            }
        default:
            reply?([:])
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushSnapshot() }
    }
    // iOS requires these two so the session can re-activate after switching watches.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message, reply: nil) }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.apply(message, reply: replyHandler) }
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.apply(userInfo, reply: nil) }
    }
}
#endif
