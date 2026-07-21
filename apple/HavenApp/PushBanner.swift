import Foundation

/// What the recipient's Notification Service Extension should show after it decrypts the
/// sealed push blob. Built on the SENDER at author time — the NSE has the seed alone and
/// cannot open circle events, so every bit of richness has to ride in this JSON.
///
/// Wire format (AES-GCM plaintext inside the signed notification envelope):
/// ```
/// { "t": "<sender display name>",
///   "b": "<human body line>",
///   "c": "<circleId>",            // for locked-circle redaction
///   "k": "post|story|dm|react|comment|edit|unsend|…",
///   "e": "<emoji>" }              // optional, reactions
/// ```
/// Older NSEs only read `t`/`b`/`c` and ignore the rest — so adding fields is forward-compatible.
enum PushBanner: Sendable {
    case post(circleName: String, preview: String?, hasMedia: Bool)
    case story(circleName: String, hasCaption: Bool)
    case dm(preview: String?, hasMedia: Bool, hasAudio: Bool)
    case reaction(emoji: String, isDM: Bool)
    case comment(preview: String?, isDM: Bool, circleName: String)
    case edit(isDM: Bool, circleName: String)
    case unsend(isDM: Bool)
    /// Fallback when the caller doesn't know (legacy / rare paths).
    case generic(isDM: Bool, circleName: String)

    /// Kind tag for the NSE / future rich UI. Keep short and stable.
    var kind: String {
        switch self {
        case .post:      return "post"
        case .story:     return "story"
        case .dm:        return "dm"
        case .reaction:  return "react"
        case .comment:   return "comment"
        case .edit:      return "edit"
        case .unsend:    return "unsend"
        case .generic:   return "activity"
        }
    }

    /// Human body line under the sender's name.
    var body: String {
        switch self {
        case .post(let circle, let preview, let hasMedia):
            if let p = Self.clip(preview), !p.isEmpty { return "\(circle): \(p)" }
            if hasMedia { return "Shared a photo in \(circle)" }
            return "Posted in \(circle)"
        case .story(let circle, let hasCaption):
            return hasCaption ? "Shared a story in \(circle)" : "Shared a story in \(circle)"
        case .dm(let preview, let hasMedia, let hasAudio):
            if let p = Self.clip(preview), !p.isEmpty { return p }
            if hasAudio { return "Sent a voice note" }
            if hasMedia { return "Sent a photo" }
            return "Sent you a message"
        case .reaction(let emoji, let isDM):
            let e = emoji.isEmpty ? "👍" : emoji
            return isDM ? "Reacted \(e) to your message" : "Reacted \(e) to your post"
        case .comment(let preview, let isDM, let circle):
            if let p = Self.clip(preview), !p.isEmpty {
                return isDM ? "Replied: \(p)" : "Commented in \(circle): \(p)"
            }
            return isDM ? "Replied to your message" : "Commented in \(circle)"
        case .edit(let isDM, let circle):
            return isDM ? "Edited a message" : "Edited a post in \(circle)"
        case .unsend(let isDM):
            return isDM ? "Unsent a message" : "Unsent a post"
        case .generic(let isDM, let circle):
            return isDM ? "Sent you a message" : "Posted in \(circle)"
        }
    }

    /// Optional reaction emoji for the wire field `e`.
    var emoji: String? {
        if case .reaction(let emoji, _) = self { return emoji.isEmpty ? nil : emoji }
        return nil
    }

    /// JSON object ready to seal. `title` is the sender display name.
    func jsonObject(title: String, circleId: String) -> [String: Any] {
        var o: [String: Any] = [
            "t": title,
            "b": body,
            "c": circleId,
            "k": kind,
        ]
        if let emoji { o["e"] = emoji }
        return o
    }

    /// One-line preview: strip secrets, collapse whitespace, cap length so the sealed blob
    /// stays well under the APNs budget even with the rest of the envelope.
    ///
    /// Deliberately free of `SecretMessages` / `MediaStore` so this file can unit-test in the
    /// host-less HavenLogicTests target. The secret marker is the same STX control char the
    /// app uses (`\u{2}` prefix).
    static func clip(_ text: String?, limit: Int = 80) -> String? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        // Secret messages must never leak their plaintext into a lock-screen banner.
        if s.hasPrefix("\u{2}") { return "🔒 Secret message" }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if s.count > limit {
            let end = s.index(s.startIndex, offsetBy: limit)
            return String(s[..<end]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return s
    }

    /// True when a media ref is a synthetic attachment (geo pin, poster/orig marker, …) —
    /// multi-char URI scheme, same rule as `MediaStore.isSynthetic`.
    static func isSyntheticRef(_ ref: String) -> Bool {
        guard let i = ref.firstIndex(of: ":") else { return false }
        return ref.distance(from: ref.startIndex, to: i) > 1
    }

    static func isAudioRef(_ ref: String) -> Bool {
        ref.hasPrefix("aud_") || ref.hasPrefix("a:")
    }

    // MARK: - Factories used by FeedStore

    static func forPost(circleId: String, circleName: String, body: String,
                        media: [String], story: Bool) -> PushBanner {
        if story {
            return .story(circleName: circleName, hasCaption: !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        let real = media.filter { !isSyntheticRef($0) }
        if circleId.hasPrefix("dm:") {
            let hasAudio = real.contains(where: isAudioRef)
            return .dm(preview: body, hasMedia: !real.isEmpty, hasAudio: hasAudio)
        }
        return .post(circleName: circleName, preview: body, hasMedia: !real.isEmpty)
    }

    static func forReaction(emoji: String, circleId: String) -> PushBanner {
        .reaction(emoji: emoji, isDM: circleId.hasPrefix("dm:"))
    }

    static func forComment(body: String, circleId: String, circleName: String) -> PushBanner {
        .comment(preview: body, isDM: circleId.hasPrefix("dm:"), circleName: circleName)
    }

    static func forEdit(circleId: String, circleName: String) -> PushBanner {
        .edit(isDM: circleId.hasPrefix("dm:"), circleName: circleName)
    }

    static func forUnsend(circleId: String) -> PushBanner {
        .unsend(isDM: circleId.hasPrefix("dm:"))
    }
}
