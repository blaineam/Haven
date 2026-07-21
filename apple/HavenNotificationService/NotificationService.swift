import UserNotifications

/// The Notification Service Extension. When the blind push relay wakes this device, the
/// real content is NOT in the visible payload — the relay only ever forwards the field `e`,
/// a base64 blob that was sealed (hybrid post-quantum) to *us* by the sender. iOS hands the
/// push to this extension first; we read our master seed from the shared Keychain, decrypt
/// `e` with `openSealedWithSeed`, and rewrite the alert so the banner shows the real sender
/// and message. The relay never sees plaintext, and decryption happens on-device even on the
/// lock screen.
///
/// The sealed plaintext is a small JSON object the SENDER built (see `PushBanner`):
/// `{ "t": title, "b": body, "c": circleId, "k": kind, "e": emoji? }`. The NSE cannot open
/// circle events (no social engine here), so richness must ride in that blob — we only format
/// and present what the sender already put there.
///
/// Everything is best-effort: if the seed is unavailable, the blob is missing/malformed, or
/// it wasn't sealed to us, we fall back to the generic banner the relay supplied. We never
/// fail the push.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let best = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        self.bestAttempt = best

        // Push-inline sync: if the push carried the sealed event itself (`ev`), stash it for the
        // app to ingest on next launch — no mailbox round-trip. We can't open a circle event
        // here (needs the engine), so we just queue the raw envelope.
        if let ev = request.content.userInfo["ev"] as? String, let env = Data(base64Encoded: ev) {
            SharedInbox.append(env: env)
        }

        guard let e = request.content.userInfo["e"] as? String,
              let sealed = Data(base64Encoded: e),
              let seed = SharedSeed.read(),
              // Authenticated open: rejects an alert that isn't validly SIGNED by its sender (audit
              // H2) — a forger who only knows our public key can no longer spoof a banner.
              let opened = openSignedNotificationWithSeed(seed: seed, blob: sealed),
              let decoded = Self.decode(opened.data) else {
            // Couldn't decrypt — keep the relay's generic banner (don't leak/guess content).
            if best.body.isEmpty { best.body = "New activity" }
            contentHandler(best)
            return
        }

        best.title = decoded.title
        best.body = decoded.body
        // Group notifications by conversation so a burst of DMs or reactions stacks sensibly
        // instead of flooding the lock screen as unrelated cards.
        if let thread = decoded.threadId, !thread.isEmpty {
            best.threadIdentifier = thread
        }
        // Surface the kind as a summary argument so iOS 15+ notification summaries can say
        // "3 reactions" rather than "3 notifications" when the system collapses a thread.
        if let kind = decoded.kind, !kind.isEmpty {
            best.summaryArgument = Self.summaryLabel(kind: kind, emoji: decoded.emoji)
            best.summaryArgumentCount = 1
        }
        contentHandler(best)
    }

    /// If the sealed payload names a circle the user has biometric-locked, hide its content —
    /// a lock-screen banner spelling out the message would defeat the lock.
    private static func redactIfLocked(_ obj: [String: Any]) -> Decoded? {
        guard let circleId = obj["c"] as? String, SharedLockedCircles.read().contains(circleId) else {
            return nil
        }
        return Decoded(title: "Haven", body: "New activity in a locked circle",
                       kind: "locked", emoji: nil, threadId: circleId)
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the OS kills the extension — deliver our best effort.
        if let handler = contentHandler, let best = bestAttempt {
            handler(best)
        }
    }

    struct Decoded {
        let title: String
        let body: String
        let kind: String?
        let emoji: String?
        let threadId: String?
    }

    /// The sealed payload is a tiny JSON object:
    /// - Message/post: `{ "t", "b", "c", "k"?, "e"? }` — built by `PushBanner` on the sender.
    /// - Call fallback: `{ "t": <caller name>, "h": <caller hex> }` — no `b`.
    private static func decode(_ data: Data) -> Decoded? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let redacted = redactIfLocked(obj) { return redacted }
        let title = (obj["t"] as? String) ?? "Haven"
        let kind = obj["k"] as? String
        let emoji = obj["e"] as? String
        let circleId = obj["c"] as? String
        // Call payload: no body, has peer hex.
        if obj["b"] == nil, obj["h"] is String {
            return Decoded(title: title, body: "📞 Incoming call — open Haven to answer",
                           kind: "call", emoji: nil, threadId: obj["h"] as? String)
        }
        var body = (obj["b"] as? String) ?? "New message"
        // Older senders still ship the generic "Posted in …" for reactions/stories. If a modern
        // kind tag is present but the body is empty somehow, synthesize from kind.
        if body.isEmpty, let kind {
            body = fallbackBody(kind: kind, emoji: emoji)
        }
        // Thread: DMs and circle activity each get their own stack. Prefer the circle id.
        let thread = circleId ?? kind
        return Decoded(title: title, body: body, kind: kind, emoji: emoji, threadId: thread)
    }

    private static func fallbackBody(kind: String, emoji: String?) -> String {
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

    private static func summaryLabel(kind: String, emoji: String?) -> String {
        switch kind {
        case "react":   return emoji.map { "\($0) reactions" } ?? "reactions"
        case "comment": return "comments"
        case "story":   return "stories"
        case "dm":      return "messages"
        case "post":    return "posts"
        case "call":    return "calls"
        default:        return "updates"
        }
    }
}
