import Foundation

// MARK: - Watch <-> iPhone wire models
//
// Lightweight, FFI-free models shared between the iPhone Haven app and the HavenWatch
// companion. They cross the WatchConnectivity link as JSON, so they MUST stay Codable and
// free of any HavenFFI / WebRTC dependency — the Watch is a thin client (the phone holds the
// iroh node + identity). This file is compiled into BOTH the iOS `Haven` target and the
// `HavenWatch` target; nothing else should be assumed available on watchOS.

/// Keys + message kinds used on the WCSession link.
public enum WatchWire {
    public static let kind = "kind"        // WatchWire.Kind.rawValue
    public static let payload = "payload"  // JSON-encoded Data of the associated model (optional)

    public enum Kind: String, Codable {
        case requestSnapshot   // Watch → phone: "send me the current thread list"
        case snapshot          // phone → Watch: WatchSnapshot
        case requestThread     // Watch → phone: WatchThreadRequest
        case thread            // phone → Watch: WatchThreadDetail
        case quickReply        // Watch → phone: WatchReply
        case react             // Watch → phone: WatchReaction
        case notify            // phone → Watch: WatchNotice (mirror a local notification)
    }
}

/// One row in the Watch's conversation list — a DM or a circle feed.
public struct WatchThread: Codable, Identifiable, Hashable {
    public var id: String        // circle id ("dm:…" for a DM, otherwise a feed circle id)
    public var title: String     // partner name (DM) or circle name
    public var subtitle: String  // last message / post preview
    public var timestamp: UInt64 // last activity, unix millis
    public var isDM: Bool
    public var unread: Int

    public init(id: String, title: String, subtitle: String, timestamp: UInt64, isDM: Bool, unread: Int) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.timestamp = timestamp; self.isDM = isDM; self.unread = unread
    }
}

/// The full thread list pushed to the Watch.
public struct WatchSnapshot: Codable, Hashable {
    public var threads: [WatchThread]
    public var generatedAt: UInt64
    /// The phone's `appearance.palette` id so the wrist matches (nil from an older phone → Sunset).
    public var palette: String?

    public init(threads: [WatchThread], generatedAt: UInt64, palette: String? = nil) {
        self.threads = threads; self.generatedAt = generatedAt; self.palette = palette
    }
}

/// One piece of post media, framed for the Watch: a JPEG thumbnail plus the ORIGINAL pixel
/// dimensions so the watch renders it at the real aspect ratio (not a forced square), and an
/// is-video flag for the play badge. `w`/`h` are the source size in pixels (0 if unknown → square).
public struct WatchMedia: Codable, Hashable {
    public var thumbnail: Data
    public var w: Int
    public var h: Int
    public var isVideo: Bool
    public init(thumbnail: Data, w: Int, h: Int, isVideo: Bool) {
        self.thumbnail = thumbnail; self.w = w; self.h = h; self.isVideo = isVideo
    }
    /// Source aspect ratio (width / height), clamped to a sane range; 1 when unknown.
    public var aspect: Double { (w > 0 && h > 0) ? max(0.5, min(2.0, Double(w) / Double(h))) : 1 }
}

/// One message/post inside a thread, flattened for the Watch.
public struct WatchMessage: Codable, Identifiable, Hashable {
    public var id: String
    public var author: String           // the resolved DISPLAY NAME (or "You"), never a node-id prefix
    public var isMe: Bool
    public var body: String
    public var timestamp: UInt64
    public var hasMedia: Bool
    public var reactions: String        // compact summary, e.g. "❤️2 👍1"
    /// All of the post's media (a swipeable carousel on the watch), each at its true aspect ratio.
    /// May be empty even when `hasMedia` is true (the thumbnails were over the WCSession byte budget).
    public var media: [WatchMedia]
    /// This item is a 24-hour STORY (rendered as a ring in the circle's story tray, not a feed post).
    public var isStory: Bool

    public init(id: String, author: String, isMe: Bool, body: String, timestamp: UInt64,
                hasMedia: Bool, reactions: String, media: [WatchMedia] = [], isStory: Bool = false) {
        self.id = id; self.author = author; self.isMe = isMe; self.body = body
        self.timestamp = timestamp; self.hasMedia = hasMedia; self.reactions = reactions
        self.media = media; self.isStory = isStory
    }
}

public struct WatchThreadRequest: Codable, Hashable {
    public var threadId: String
    public init(threadId: String) { self.threadId = threadId }
}

public struct WatchThreadDetail: Codable, Hashable {
    public var threadId: String
    public var title: String
    public var isDM: Bool
    public var messages: [WatchMessage]
    public init(threadId: String, title: String, isDM: Bool, messages: [WatchMessage]) {
        self.threadId = threadId; self.title = title; self.isDM = isDM; self.messages = messages
    }
}

public struct WatchReply: Codable, Hashable {
    public var threadId: String
    public var body: String
    /// When set, this is a COMMENT on that post id (circle long-press → Comment); nil = a thread-level
    /// message (a DM reply, or a new circle post).
    public var targetId: String?
    public init(threadId: String, body: String, targetId: String? = nil) {
        self.threadId = threadId; self.body = body; self.targetId = targetId
    }
}

public struct WatchReaction: Codable, Hashable {
    public var threadId: String
    public var messageId: String
    public var emoji: String
    public init(threadId: String, messageId: String, emoji: String) {
        self.threadId = threadId; self.messageId = messageId; self.emoji = emoji
    }
}

public struct WatchNotice: Codable, Hashable {
    public var title: String
    public var body: String
    public var dedupeKey: String
    public init(title: String, body: String, dedupeKey: String) {
        self.title = title; self.body = body; self.dedupeKey = dedupeKey
    }
}

/// Encode/decode our typed models into the `[String: Any]` plist dictionaries that
/// WCSession messages / application-context / userInfo transfers require. We carry the
/// model as a JSON `Data` value (a valid plist type) keyed by `WatchWire.payload`.
public enum WatchCodec {
    public static func encode<T: Encodable>(_ kind: WatchWire.Kind, _ value: T?) -> [String: Any] {
        var dict: [String: Any] = [WatchWire.kind: kind.rawValue]
        if let value, let data = try? JSONEncoder().encode(value) {
            dict[WatchWire.payload] = data
        }
        return dict
    }

    public static func encode(_ kind: WatchWire.Kind) -> [String: Any] {
        [WatchWire.kind: kind.rawValue]
    }

    public static func kind(of message: [String: Any]) -> WatchWire.Kind? {
        (message[WatchWire.kind] as? String).flatMap(WatchWire.Kind.init(rawValue:))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[WatchWire.payload] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Canned quick replies offered on the Watch (tap-to-send without dictation).
public enum WatchQuickReplies {
    public static let all = ["👍", "On my way", "Got it", "Thanks!", "Call you later", "❤️", "😂", "Yes", "No"]
    /// Emoji offered for tap-to-react on a message.
    public static let reactions = ["❤️", "👍", "😂", "🔥", "😮", "😢"]
}

/// Shared short relative-time formatter (no HavenFFI dependency) so the Watch and phone
/// render timestamps identically.
public func watchRelativeTime(_ ms: UInt64) -> String {
    guard ms > 0 else { return "" }
    let secs = Date().timeIntervalSince1970 - Double(ms) / 1000
    switch secs {
    case ..<5: return "now"
    case ..<60: return "\(Int(secs))s"
    case ..<3600: return "\(Int(secs / 60))m"
    case ..<86_400: return "\(Int(secs / 3600))h"
    case ..<604_800: return "\(Int(secs / 86_400))d"
    default: return "\(Int(secs / 604_800))w"
    }
}
