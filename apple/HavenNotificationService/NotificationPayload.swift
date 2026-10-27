import Foundation
import UserNotifications

/// What the Notification Service Extension makes of a sealed push payload, without UserNotifications,
/// the Keychain or the network: decode the tiny JSON object, redact a biometric-locked circle, build
/// the tap route, and pick which text a banner may show. Lives in its own file so the host-less
/// logic tests can cover it; the extension itself only wires these to the system.

struct NotificationPayload {
    let title: String
    let fullBody: String
    let privateBody: String?
    let kind: String?
    let emoji: String?
    let threadId: String?
    /// `haven://…` route for notification tap (Messages thread / post / story).
    let deepLink: String?
    var redactedForLock: Bool = false
    /// Push-before-content coordinates (all from inside the sealed blob).
    var circleId: String?
    var postId: String?
    var mailboxKey: String?
    var mediaRefs: [String]?
    /// Convenience when already fully redacted (locked circle / call).
    var body: String { fullBody }
}

enum NotificationPayloadCodec {
    /// What the system's own "Show Previews" setting allows, combined with Haven's: the STRICTER wins.
    /// An unknown future setting is treated as the middle level rather than as full previews.
    static func detail(haven: SharedNotificationPrivacy.Detail,
                       systemPreviews: UNShowPreviewsSetting) -> SharedNotificationPrivacy.Detail {
        let system: SharedNotificationPrivacy.Detail
        switch systemPreviews {
        case .never: system = .minimal
        case .whenAuthenticated: system = .privateDetail
        case .always: system = .full
        @unknown default: system = .privateDetail
        }
        return SharedNotificationPrivacy.stricter(haven, system)
    }

    /// What the extension should prefetch before delivering the banner, so the post is already on the
    /// device when the notification is tapped. Nil = deliver immediately.
    struct PrefetchPlan: Equatable {
        let circleId: String
        let mailboxKey: String?
        let mediaRefs: [String]
        /// The envelope rode inline in the push, so only media remains to fetch.
        let skipEnvelope: Bool
    }

    static func prefetchPlan(_ p: NotificationPayload, hasInlineEvent: Bool) -> PrefetchPlan? {
        let wantEnvelope = !hasInlineEvent && p.mailboxKey != nil
        let mediaRefs = p.mediaRefs ?? []
        guard !p.redactedForLock, wantEnvelope || !mediaRefs.isEmpty,
              let cid = p.circleId, !cid.isEmpty else { return nil }
        return PrefetchPlan(circleId: cid, mailboxKey: p.mailboxKey, mediaRefs: mediaRefs, skipEnvelope: hasInlineEvent)
    }

    static func applyPrivacy(_ decoded: NotificationPayload,
                             detail: SharedNotificationPrivacy.Detail) -> (title: String, body: String) {
        // Biometric-locked circles always win — never quote their content.
        if decoded.redactedForLock {
            return (decoded.title, decoded.body)
        }
        let pick = SharedNotificationPrivacy.displayBody(full: decoded.fullBody,
                                                          privateBody: decoded.privateBody,
                                                          kind: decoded.kind,
                                                          detail: detail)
        let title = pick.titleUsesName ? decoded.title : "Haven"
        return (title, pick.body)
    }

    /// If the sealed payload names a circle the user has biometric-locked, hide its content —
    /// a lock-screen banner spelling out the message would defeat the lock.
    static func redactIfLocked(_ obj: [String: Any], lockedCircles: Set<String>) -> NotificationPayload? {
        guard let circleId = obj["c"] as? String, lockedCircles.contains(circleId) else {
            return nil
        }
        return NotificationPayload(title: "Haven", fullBody: "New activity in a locked circle",
                       privateBody: "New activity in a locked circle",
                       kind: "locked", emoji: nil, threadId: circleId,
                       deepLink: deepLink(circleId: circleId, postId: nil),
                       redactedForLock: true)
    }

    /// Build a tap route from banner fields. Mirror of `DeepLink.interactionLink` /
    /// `DeepLink.storyLink` (NSE can't import the app target) — keep encodings in sync.
    static func deepLink(circleId: String?, postId: String?, kind: String? = nil) -> String? {
        guard let circleId, !circleId.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~")
        let encCid = circleId.addingPercentEncoding(withAllowedCharacters: allowed) ?? circleId
        if circleId.hasPrefix("dm:") {
            if let postId, !postId.isEmpty,
               let encPid = postId.addingPercentEncoding(withAllowedCharacters: allowed) {
                return "haven://m/\(encCid)/\(encPid)"
            }
            return "haven://m/\(encCid)"
        }
        if let postId, !postId.isEmpty,
           let encPid = postId.addingPercentEncoding(withAllowedCharacters: allowed) {
            // A story tap lands in the story viewer, not the feed.
            return kind == "story" ? "haven://s/\(encCid)/\(encPid)" : "haven://p/\(encCid)/\(encPid)"
        }
        return "haven://c/\(encCid)"
    }

    /// The sealed payload is a tiny JSON object:
    /// - Message/post: `{ "t", "b", "bp"?, "c", "k"?, "e"?, "p"?, "mk"?, "mr"? }` — built by
    ///   `PushBanner`. `p`/`mk`/`mr` are the deep-link + prefetch coordinates.
    /// - Call fallback: `{ "t": <caller name>, "h": <caller hex> }` — no `b`.
    static func decode(_ data: Data, lockedCircles: Set<String>) -> NotificationPayload? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let redacted = redactIfLocked(obj, lockedCircles: lockedCircles) { return redacted }
        let title = (obj["t"] as? String) ?? "Haven"
        let kind = obj["k"] as? String
        let emoji = obj["e"] as? String
        let circleId = obj["c"] as? String
        let postId = obj["p"] as? String
        let privateBody = obj["bp"] as? String
        // Call payload: no body, has peer hex.
        if obj["b"] == nil, obj["h"] is String {
            return NotificationPayload(title: title, fullBody: "📞 Incoming call — open Haven to answer",
                           privateBody: "Incoming call",
                           kind: "call", emoji: nil, threadId: obj["h"] as? String, deepLink: nil)
        }
        var full = (obj["b"] as? String) ?? "New message"
        if full.isEmpty, let kind {
            full = fallbackBody(kind: kind, emoji: emoji)
        }
        let thread = circleId ?? kind
        return NotificationPayload(title: title, fullBody: full, privateBody: privateBody,
                       kind: kind, emoji: emoji, threadId: thread,
                       deepLink: deepLink(circleId: circleId, postId: postId, kind: kind),
                       circleId: circleId, postId: postId,
                       mailboxKey: obj["mk"] as? String,
                       mediaRefs: obj["mr"] as? [String])
    }

    static func fallbackBody(kind: String, emoji: String?) -> String {
        switch kind {
        case "story":   return "Shared a story"
        case "react":   return "Reacted \(emoji ?? "👍")"
        case "comment": return "Left a comment"
        case "dm":      return "Sent you a message"
        case "edit":    return "Edited a message"
        case "unsend":  return "Unsent a message"
        case "post":    return "Shared something"
        default:        return "New activity"
        }
    }

    /// Summary labels stay kind-only (no emoji) so a collapsed stack doesn't re-leak detail.
    static func summaryLabel(kind: String) -> String {
        switch kind {
        case "react":   return "reactions"
        case "comment": return "comments"
        case "story":   return "stories"
        case "dm":      return "messages"
        case "post":    return "posts"
        case "call":    return "calls"
        default:        return "updates"
        }
    }

    // MARK: - Communication notifications (Siri announce / reply, CarPlay)

    /// What a communication notification may carry. Nil = post the ordinary banner.
    struct CommunicationPlan: Equatable {
        let conversationId: String
        let senderName: String
        let text: String
        /// Set for a group DM: Siri announces "<sender> in <group> says ...".
        let groupName: String?
    }

    /// Only a plain inbound DM, on a device whose effective privacy level is `.full`, becomes a
    /// communication notification. The donated `INSendMessageIntent` carries the message text, and
    /// that is exactly what Siri may read aloud - so anything that hides content from the banner
    /// (Private/Minimal, iOS Show Previews, a biometric-locked circle, a sealed call/story/reaction)
    /// must also keep it out of the intent. The decision therefore takes the already-resolved
    /// `detail` (Haven's preference tightened by the system's), never the raw preference.
    ///
    /// `groupName` is the thread title when the thread has several other members (from the App Group
    /// destination mirror); circle POSTS and comments are not messages and never get a plan.
    static func communicationPlan(_ p: NotificationPayload,
                                  detail: SharedNotificationPrivacy.Detail,
                                  groupName: String? = nil) -> CommunicationPlan? {
        guard detail == .full, !p.redactedForLock, p.kind == "dm",
              let cid = p.circleId, cid.hasPrefix("dm:") else { return nil }
        let name = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = p.fullBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "Haven", !text.isEmpty else { return nil }
        let group = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommunicationPlan(conversationId: cid, senderName: name, text: localizedPlaceholder(text),
                                 groupName: (group?.isEmpty ?? true) ? nil : group)
    }

    /// The sender builds the banner in ITS language ("Sent a photo"); when the whole body is one of those
    /// stock lines, say it in THIS device's language instead. Real message text is never touched.
    static func localizedPlaceholder(_ body: String) -> String {
        switch body {
        case "Sent a photo": return MessagingText.photo
        case "Sent the group a photo": return MessagingText.groupPhoto
        case "Sent a voice note": return MessagingText.voice
        case "Sent the group a voice note": return MessagingText.groupVoice
        case "Sent you a message": return MessagingText.sentAMessage
        case "Messaged the group": return MessagingText.groupMessage
        default: return body
        }
    }
}
