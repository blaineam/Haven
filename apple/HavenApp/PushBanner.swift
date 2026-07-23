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
///   "e": "<emoji>",               // optional, reactions
///   "p": "<postId>",              // optional — the authored/PARENT post, for an exact tap route
///   "mk": "<mailbox key>",        // optional — where the sealed envelope lives (NSE prefetch)
///   "mr": ["<ref>", …] }          // optional — media to prefetch, thumbs/posters first
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
    /// Wrapper carrying deep-link/prefetch coordinates alongside any banner: the authored or
    /// PARENT post id (`p` — a reaction's tap opens the post it reacted to, not just the circle)
    /// and the post's fetchable media refs (`mr`, thumbs/posters first). Indirect so a banner
    /// stays one value; every presentation property delegates to the wrapped case.
    indirect case tagged(PushBanner, postId: String?, mediaRefs: [String])

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
        case .tagged(let inner, _, _): return inner.kind
        }
    }

    /// Full body line under the sender's name (may quote message text / emoji).
    var body: String {
        switch self {
        case .post(let circle, let preview, let hasMedia):
            if let p = Self.clip(preview), !p.isEmpty { return "\(circle): \(p)" }
            if hasMedia { return "Shared a photo in \(circle)" }
            return "Posted in \(circle)"
        case .story(let circle, _):
            return "Shared a story in \(circle)"
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
        case .tagged(let inner, _, _):
            return inner.body
        }
    }

    /// Privacy-safe body: kind of activity only — no message text, no comment quote, no emoji.
    /// The recipient's NSE uses this when their lock-screen / Haven preview preference says so.
    var privateBody: String {
        switch self {
        case .post(_, _, let hasMedia):
            return hasMedia ? "Shared a photo" : "Posted in your circle"
        case .story:
            return "Shared a story"
        case .dm(_, let hasMedia, let hasAudio):
            if hasAudio { return "Sent a voice note" }
            if hasMedia { return "Sent a photo" }
            return "Sent you a message"
        case .reaction(_, let isDM):
            return isDM ? "Reacted to your message" : "Reacted to your post"
        case .comment(_, let isDM, _):
            return isDM ? "Replied to your message" : "Left a comment"
        case .edit(let isDM, _):
            return isDM ? "Edited a message" : "Edited a post"
        case .unsend(let isDM):
            return isDM ? "Unsent a message" : "Unsent a post"
        case .generic(let isDM, _):
            return isDM ? "Sent you a message" : "New activity in your circle"
        case .tagged(let inner, _, _):
            return inner.privateBody
        }
    }

    /// Optional reaction emoji for the wire field `e`.
    var emoji: String? {
        switch self {
        case .reaction(let emoji, _): return emoji.isEmpty ? nil : emoji
        case .tagged(let inner, _, _): return inner.emoji
        default: return nil
        }
    }

    /// The authored/PARENT post id this banner is about (wire field `p`), if the caller knew it.
    var postId: String? {
        if case .tagged(_, let postId, _) = self { return postId }
        return nil
    }

    /// Fetchable media refs to prefetch (wire field `mr`), thumbs/posters first.
    var mediaRefs: [String] {
        if case .tagged(_, _, let refs) = self { return refs }
        return []
    }

    /// JSON object ready to seal. `title` is the sender display name.
    /// Always includes both `b` (full) and `bp` (private) so the *recipient* chooses detail
    /// level — the sender must not decide how much of someone else's lock screen to expose.
    /// `mailboxKey` is the deterministic store-and-forward key the envelope is uploaded under —
    /// it rides INSIDE the sealed blob so the recipient's NSE can fetch the content the moment
    /// the banner lands (push-before-content), without the relay learning what was announced.
    func jsonObject(title: String, circleId: String, mailboxKey: String? = nil) -> [String: Any] {
        var o: [String: Any] = [
            "t": title,
            "b": body,
            "bp": privateBody,
            "c": circleId,
            "k": kind,
        ]
        if let emoji { o["e"] = emoji }
        if let postId { o["p"] = postId }
        if let mailboxKey { o["mk"] = mailboxKey }
        let refs = mediaRefs
        if !refs.isEmpty { o["mr"] = Array(refs.prefix(4)) }   // bounded — APNs budget
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
    //
    // Each takes the authored/PARENT post id when the caller has it (reactions, comments, edits
    // and unsends always do — it's their target), so the recipient's tap opens the exact post.
    // A nil id keeps the old circle/thread route.

    static func forPost(circleId: String, circleName: String, body: String,
                        media: [String], story: Bool, postId: String? = nil) -> PushBanner {
        let real = media.filter { !isSyntheticRef($0) }
        let inner: PushBanner
        if story {
            inner = .story(circleName: circleName, hasCaption: !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if circleId.hasPrefix("dm:") {
            let hasAudio = real.contains(where: isAudioRef)
            inner = .dm(preview: body, hasMedia: !real.isEmpty, hasAudio: hasAudio)
        } else {
            inner = .post(circleName: circleName, preview: body, hasMedia: !real.isEmpty)
        }
        // Prefetch coordinates for the recipient's NSE: thumbs first (tiny — they unblock the
        // placeholder), then posters, then content — the same priority as the relay upload order.
        let refs = MediaVariants.uploadOrder(media)
        guard postId != nil || !refs.isEmpty else { return inner }
        return .tagged(inner, postId: postId, mediaRefs: refs)
    }

    static func forReaction(emoji: String, circleId: String, postId: String? = nil) -> PushBanner {
        tag(.reaction(emoji: emoji, isDM: circleId.hasPrefix("dm:")), postId)
    }

    static func forComment(body: String, circleId: String, circleName: String, postId: String? = nil) -> PushBanner {
        tag(.comment(preview: body, isDM: circleId.hasPrefix("dm:"), circleName: circleName), postId)
    }

    static func forEdit(circleId: String, circleName: String, postId: String? = nil) -> PushBanner {
        tag(.edit(isDM: circleId.hasPrefix("dm:"), circleName: circleName), postId)
    }

    static func forUnsend(circleId: String, postId: String? = nil) -> PushBanner {
        tag(.unsend(isDM: circleId.hasPrefix("dm:")), postId)
    }

    private static func tag(_ inner: PushBanner, _ postId: String?) -> PushBanner {
        guard let postId, !postId.isEmpty else { return inner }
        return .tagged(inner, postId: postId, mediaRefs: [])
    }
}
