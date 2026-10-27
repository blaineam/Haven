import Foundation

/// The privacy-filtered, Foundation-only view of Haven's direct-message threads that the car (CarPlay
/// list) and Siri (the Intents extension) are allowed to see.
///
/// Two consumers, one rule set:
///   * the CarPlay scene runs inside the app and builds rows from live `FeedStore` data;
///   * the **Intents extension** is a separate process with no engine and no identity, so the app
///     mirrors a small, already-filtered snapshot into the App Group (`MessagingSnapshotStore`) for it.
///
/// Both go through `MessagingThread` -> `MessagingPrivacy.preview`, so a locked or privacy-restricted
/// conversation can never leak text on one surface that the other hides.
///
/// Privacy rules (docs/CARPLAY.md):
///   * a biometric-locked conversation NEVER carries message text - only the word "Locked";
///   * the user's notification-privacy setting (`SharedNotificationPrivacy.Detail`) caps the text:
///     `.full` shows the message, `.privateDetail` shows only "Sent you a message", `.minimal` shows
///     "New activity" and nothing about who or what.
struct MessagingMessage: Equatable {
    var id: String
    var isMe: Bool
    var unsent: Bool
    /// Unix milliseconds.
    var createdAt: UInt64
    var body: String
    var hasAttachment: Bool
    /// Display name of the author ("" for my own messages).
    var author: String = ""
}

struct MessagingThread: Equatable {
    var id: String
    var title: String
    /// Node ids of everyone but me. Siri resolves recipients against these.
    var memberHandles: [String]
    /// Other names this person is known by (their signed name vs your nickname for them), so a spoken
    /// "Tracy Miller" finds the thread you titled "Tracy M". Empty for groups.
    var aliases: [String] = []
    /// Any order; the builders sort.
    var messages: [MessagingMessage]
    /// Read watermark, unix ms. Inbound messages newer than this are unread.
    var watermark: UInt64
    var locked: Bool
}

enum MessagingPrivacy {
    static let lockedText = "Locked"
    static let previewLimit = 80

    /// Newest message (by `createdAt`, ties keep the later element).
    static func latest(_ messages: [MessagingMessage]) -> MessagingMessage? {
        var best: MessagingMessage?
        for m in messages where best == nil || m.createdAt >= best!.createdAt { best = m }
        return best
    }

    /// Inbound, not unsent, newer than the watermark.
    static func unreadCount(_ messages: [MessagingMessage], watermark: UInt64) -> Int {
        messages.filter { !$0.isMe && !$0.unsent && $0.createdAt > watermark }.count
    }

    /// Collapse whitespace/newlines and cut to `limit` characters (grapheme clusters, so emoji and
    /// combined characters are never split) with a trailing ellipsis.
    static func truncate(_ text: String, limit: Int = previewLimit) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > limit, limit > 1 else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "\u{2026}"
    }

    /// The line a surface may show for a thread whose newest message is `message`.
    /// Empty string = nothing to show (an empty thread).
    static func preview(of message: MessagingMessage?, locked: Bool, unread: Bool,
                        detail: SharedNotificationPrivacy.Detail) -> String {
        if locked { return lockedText }
        guard let message else { return "" }
        switch detail {
        case .minimal:
            return unread ? "New activity" : ""
        case .privateDetail:
            if message.unsent { return "Message unsent" }
            return message.isMe ? "You sent a message"
                                : SharedNotificationPrivacy.fallbackPrivateBody(kind: "dm")
        case .full:
            if message.unsent { return "Message unsent" }
            let text = truncate(message.body)
            if !text.isEmpty { return text }
            return message.hasAttachment ? "Attachment" : ""
        }
    }

    /// The text Siri may READ ALOUD for one message; "" means "say nothing about the content".
    static func spokenText(_ message: MessagingMessage, locked: Bool,
                           detail: SharedNotificationPrivacy.Detail) -> String {
        guard !locked, detail == .full, !message.unsent else { return "" }
        let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return message.hasAttachment ? "Attachment" : ""
    }
}

/// What the Intents extension reads. Already filtered at write time: `text` is empty whenever the
/// conversation is locked or the privacy setting forbids content.
struct MessagingSnapshot: Codable, Equatable {
    struct Message: Codable, Equatable {
        var id: String
        var author: String
        var isMe: Bool
        var at: UInt64
        var text: String
        var unread: Bool
    }
    struct Conversation: Codable, Equatable {
        var id: String
        var title: String
        var memberHandles: [String]
        /// Other names for matching (optional so snapshots written before this field still decode).
        var aliases: [String]? = nil
        var locked: Bool
        var lastActivity: UInt64
        var unreadCount: Int
        var messages: [Message]   // oldest -> newest
    }
    var version = 1
    var generatedAt: UInt64
    /// The privacy level the snapshot was built under (the extension echoes it in Siri's wording).
    var detail: String
    var conversations: [Conversation]

    static let maxConversations = 12
    static let maxMessages = 6

    static func build(threads: [MessagingThread], detail: SharedNotificationPrivacy.Detail,
                      now: UInt64) -> MessagingSnapshot {
        let convs = threads.map { t -> Conversation in
            let newest = latest(t.messages)
            let unreadN = t.locked ? 0 : MessagingPrivacy.unreadCount(t.messages, watermark: t.watermark)
            var msgs: [Message] = []
            if !t.locked {
                let recent = t.messages.sorted { $0.createdAt < $1.createdAt }.suffix(maxMessages)
                msgs = recent.map { m in
                    Message(id: m.id, author: m.isMe ? "" : m.author, isMe: m.isMe, at: m.createdAt,
                            text: MessagingPrivacy.spokenText(m, locked: false, detail: detail),
                            unread: !m.isMe && !m.unsent && m.createdAt > t.watermark)
                }
            }
            return Conversation(id: t.id, title: t.title, memberHandles: t.memberHandles,
                                aliases: t.aliases.isEmpty ? nil : t.aliases, locked: t.locked,
                                lastActivity: newest?.createdAt ?? 0, unreadCount: unreadN, messages: msgs)
        }
        let top = convs.sorted { ($0.lastActivity, $1.title) > ($1.lastActivity, $0.title) }.prefix(maxConversations)
        return MessagingSnapshot(generatedAt: now, detail: detail.rawValue, conversations: Array(top))
    }

    private static func latest(_ m: [MessagingMessage]) -> MessagingMessage? { MessagingPrivacy.latest(m) }

    /// Candidates for `ContactMatching`: the title first, then the aliases.
    var matchCandidates: [ContactMatching.Candidate] {
        conversations.map { .init(id: $0.id, names: [$0.title] + ($0.aliases ?? [])) }
    }

    /// Fuzzy resolution of what Siri heard (several spellings of one person are fine) to conversations.
    func resolution(queries: [String]) -> ContactMatching.Resolution {
        ContactMatching.resolve(queries: queries, candidates: matchCandidates)
    }

    /// Every plausible conversation for a spoken name, best first (see `resolution` for the verdict).
    /// A locked conversation can still be resolved for SENDING; callers refuse to read it.
    func resolve(name: String) -> [Conversation] {
        let ids: [String]
        switch resolution(queries: [name]) {
        case .none: ids = []
        case .confident(let m), .tentative(let m): ids = [m.id]
        case .ambiguous(let ms): ids = ms.map(\.id)
        }
        return ids.compactMap { conversation(id: $0) }
    }

    func conversation(id: String) -> Conversation? { conversations.first { $0.id == id } }

    /// A conversation whose members include this handle (node id) - 1:1 threads only.
    func conversation(handle: String) -> Conversation? {
        conversations.first { $0.memberHandles == [handle] }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// App Group storage for the snapshot, and the request queue the extension fills for the app.
enum MessagingSnapshotStore {
    static let appGroup = "group.com.blaineam.kith"
    nonisolated(unsafe) static var containerOverride: URL?

    private static var dir: URL? {
        let base = containerOverride ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return base?.appendingPathComponent("Messaging", isDirectory: true)
    }
    private static var fileURL: URL? { dir?.appendingPathComponent("snapshot.json") }

    /// App side. Protected until first unlock so Siri can read it with the phone locked in a pocket
    /// (the car case) but not before the first unlock after boot.
    static func write(_ snapshot: MessagingSnapshot) {
        guard let dir, let fileURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read() -> MessagingSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MessagingSnapshot.self, from: data)
    }

    /// Factory reset / feature switched off: the text must not outlive the account.
    static func clear() {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Requests Siri (the Intents extension) leaves for the app: send this text, mark this thread read.
/// One file per request, so two requests can never overwrite each other; the app drains in order.
/// The extension has no engine - it only enqueues; the app does the sealing and sending.
struct SiriRequest: Codable, Equatable {
    enum Kind: String, Codable { case send, markRead }
    var id: String
    var kind: Kind
    var conversationId: String
    var text: String
    /// Unix milliseconds the request was made.
    var createdAt: UInt64
}

enum SiriRequestQueue {
    nonisolated(unsafe) static var containerOverride: URL?
    static let maxTextLength = 4000

    private static var dir: URL? {
        let base = containerOverride ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MessagingSnapshotStore.appGroup)
        return base?.appendingPathComponent("SiriRequests", isDirectory: true)
    }

    /// Extension side. Returns false when the request is unusable (no container, empty/oversized text).
    @discardableResult
    static func enqueue(kind: SiriRequest.Kind, conversationId: String, text: String = "",
                        now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let dir, conversationId.hasPrefix("dm:") else { return false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .send, body.isEmpty || body.count > maxTextLength { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let req = SiriRequest(id: UUID().uuidString, kind: kind, conversationId: conversationId,
                              text: kind == .send ? body : "", createdAt: now)
        guard let data = try? JSONEncoder().encode(req) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent("\(String(format: "%020llu", now))-\(req.id).json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    /// App side: every pending request, oldest first. Undecodable files are removed.
    static func pending() -> [(file: URL, request: SiriRequest)] {
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(URL, SiriRequest)] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(SiriRequest.self, from: data) {
                out.append((url, r))
            } else { try? FileManager.default.removeItem(at: url) }
        }
        return out
    }

    static func complete(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    static func clear() { if let dir { try? FileManager.default.removeItem(at: dir) } }
}
