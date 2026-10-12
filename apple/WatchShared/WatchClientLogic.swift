import Foundation

// Pure decision/state logic of the Watch's WCSession client, kept FFI-free and WatchConnectivity-free so
// the host-less logic tests can cover it. `WatchConnectivityClient` owns the session and the @Published
// state; this file owns what an inbound message MEANS and what the offline demo scene contains.

/// What an inbound WatchConnectivity message (reply, application context or queued user info) is.
public enum WatchInbound: Equatable {
    case snapshot(WatchSnapshot)
    case thread(WatchThreadDetail)
    case notice(WatchNotice)
    /// Unknown kind, a request meant for the phone, or a payload that does not decode.
    case ignored

    public static func parse(_ message: [String: Any]) -> WatchInbound {
        switch WatchCodec.kind(of: message) {
        case .snapshot:
            return WatchCodec.decode(WatchSnapshot.self, from: message).map(WatchInbound.snapshot) ?? .ignored
        case .thread:
            return WatchCodec.decode(WatchThreadDetail.self, from: message).map(WatchInbound.thread) ?? .ignored
        case .notify:
            return WatchCodec.decode(WatchNotice.self, from: message).map(WatchInbound.notice) ?? .ignored
        default:
            return .ignored
        }
    }
}

public enum WatchReplyRules {
    /// A reply is sent trimmed; whitespace-only is not a reply.
    public static func cleaned(_ body: String) -> String? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The local-notification identifier for a mirrored notice. One id per `dedupeKey`, so a repeated
    /// mirror REPLACES the banner instead of stacking a second one.
    public static func notificationId(for notice: WatchNotice) -> String { "wmirror-\(notice.dedupeKey)" }
}

/// The synthetic conversations the DEBUG demo / screenshot harness shows (no paired iPhone). Plain
/// value type so "reply echoes locally" and "react adds a count" are testable.
public struct WatchDemoStore: Equatable {
    public var threads: [WatchThread] = []
    public var details: [String: WatchThreadDetail] = [:]

    public init() {}

    public static let defaultOpenThreadId = "dm:ari"

    /// `media` = rendered gradient thumbnails (only the watch app can render them; tests pass stubs).
    public static func seed(now: UInt64, media: [WatchMedia]) -> WatchDemoStore {
        var s = WatchDemoStore()
        s.threads = [
            WatchThread(id: "dm:ari", title: "Ari", subtitle: "On my way 🚲", timestamp: now - 90_000, isDM: true, unread: 1),
            WatchThread(id: "dm:noa", title: "Noa", subtitle: "❤️ that photo", timestamp: now - 1_800_000, isDM: true, unread: 0),
            WatchThread(id: "circle:trail", title: "Trail Crew", subtitle: "Sunset hike Saturday?", timestamp: now - 5_400_000, isDM: false, unread: 0),
        ]
        let dm = WatchThreadDetail(threadId: "dm:ari", title: "Ari", isDM: true, messages: [
            WatchMessage(id: "m1", author: "Ari", isMe: false, body: "Heading over now", timestamp: now - 240_000, hasMedia: false, reactions: "👍1"),
            WatchMessage(id: "m2", author: "You", isMe: true, body: "Cool, door's open", timestamp: now - 180_000, hasMedia: false, reactions: ""),
            WatchMessage(id: "m3", author: "Ari", isMe: false, body: "On my way 🚲", timestamp: now - 90_000, hasMedia: false, reactions: "❤️2"),
            WatchMessage(id: "m4", author: "Ari", isMe: false, body: "Made it to the top!", timestamp: now - 60_000, hasMedia: true,
                         reactions: "🔥3", media: media),
        ])
        let circle = WatchThreadDetail(threadId: "circle:trail", title: "Trail Crew", isDM: false, messages: [
            WatchMessage(id: "s1", author: "Noa", isMe: false, body: "golden hour up here", timestamp: now - 3_600_000,
                         hasMedia: true, reactions: "", media: Array(media.prefix(1)), isStory: true),
            WatchMessage(id: "p1", author: "Noa", isMe: false, body: "Sunset hike Saturday?", timestamp: now - 5_400_000,
                         hasMedia: false, reactions: "👍2"),
        ])
        s.details = [dm.threadId: dm, circle.threadId: circle,
                     "dm:noa": WatchThreadDetail(threadId: "dm:noa", title: "Noa", isDM: true, messages: [
                         WatchMessage(id: "n1", author: "Noa", isMe: false, body: "❤️ that photo",
                                      timestamp: now - 1_800_000, hasMedia: false, reactions: ""),
                     ])]
        return s
    }

    /// Echo a message locally, as the phone's answer would. Returns the updated thread, or nil when
    /// the thread is unknown.
    @discardableResult
    public mutating func append(_ message: WatchMessage, to threadId: String) -> WatchThreadDetail? {
        guard var detail = details[threadId] else { return nil }
        detail.messages.append(message)
        details[threadId] = detail
        return detail
    }

    /// Add one `emoji` to a message's reaction summary ("❤️2" -> "❤️2 👍1"). Nil when the thread or
    /// message is unknown.
    @discardableResult
    public mutating func react(threadId: String, messageId: String, emoji: String) -> WatchThreadDetail? {
        guard var detail = details[threadId],
              let i = detail.messages.firstIndex(where: { $0.id == messageId }) else { return nil }
        let r = detail.messages[i].reactions
        detail.messages[i].reactions = r.isEmpty ? "\(emoji)1" : "\(r) \(emoji)1"
        details[threadId] = detail
        return detail
    }
}
