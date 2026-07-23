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
/// `{ "t", "b", "bp", "c", "k", "e"? }`. `b` is the full preview; `bp` is a privacy-safe
/// kind-only line. This extension picks which to show from:
///   1. the user's iOS **Show Previews** setting, and
///   2. Haven's own notification-detail preference (App Group).
/// The sender always ships both — privacy is a *recipient* choice.
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

        // Foreground fast-path hand-off: record the push's coordinates in the App Group so the
        // app's next foreground/push drain targets exactly this envelope + media even if our own
        // prefetch below is killed mid-flight. Reader (`SharedPushHints`) clears; we only append.
        if let cid = decoded.circleId, !cid.isEmpty, !decoded.redactedForLock {
            SharedPushHintWriter.append(c: cid, mk: decoded.mailboxKey,
                                        mr: decoded.mediaRefs, p: decoded.postId)
        }

        // Resolve how much detail THIS device is allowed to show. Async because iOS notification
        // settings are. Cap wait so we never miss the NSE deadline if the system stalls.
        Self.resolveDetail { detail in
            let shown = Self.applyPrivacy(decoded, detail: detail)
            best.title = shown.title
            best.body = shown.body
            // Group notifications by conversation so a burst of DMs or reactions stacks sensibly
            // instead of flooding the lock screen as unrelated cards.
            if let thread = decoded.threadId, !thread.isEmpty {
                best.threadIdentifier = thread
            }
            // Tap → open the conversation / post (app routes via NotificationTapRouter).
            if let link = decoded.deepLink, !link.isEmpty {
                var info = best.userInfo
                info["havenDeepLink"] = link
                best.userInfo = info
            }
            // iOS 15+ ignores summaryArgument / summaryArgumentCount — threadIdentifier above
            // is what groups the stack. Kind labels stay available via SharedNotificationPrivacy.
            _ = decoded.kind
            // Push-before-content: the banner already names the sender — now fetch what it
            // announced (the sealed envelope by its exact mailbox key, plus thumb/poster media)
            // while we still hold the NSE's execution window, THEN deliver. The banner text is
            // final either way; `serviceExtensionTimeWillExpire` still delivers it on overrun.
            let hasInlineEvent = request.content.userInfo["ev"] != nil
            Self.prefetchThenDeliver(decoded, hasInlineEvent: hasInlineEvent) {
                contentHandler(best)
            }
        }
    }

    /// Best-effort content prefetch bounded to ~10s of the NSE budget; always calls `deliver`.
    private static func prefetchThenDeliver(_ decoded: Decoded, hasInlineEvent: Bool,
                                            deliver: @escaping () -> Void) {
        let wantEnvelope = !hasInlineEvent && decoded.mailboxKey != nil
        let mediaRefs = decoded.mediaRefs ?? []
        guard !decoded.redactedForLock, wantEnvelope || !mediaRefs.isEmpty,
              let cid = decoded.circleId, !cid.isEmpty else {
            deliver()
            return
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await SharedPushPrefetch.run(circleId: cid, mailboxKey: decoded.mailboxKey,
                                                 mediaRefs: mediaRefs, skipEnvelope: hasInlineEvent)
                }
                group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000) }
                await group.next()      // whichever finishes first — fetch done, or budget spent
                group.cancelAll()
            }
            deliver()
        }
    }

    /// Combine Haven preference with iOS Show Previews. Conservative when uncertain.
    private static func resolveDetail(completion: @escaping (SharedNotificationPrivacy.Detail) -> Void) {
        let haven = SharedNotificationPrivacy.detail
        // Haven already wants minimal/private — no need to ask the system.
        if haven != .full {
            completion(haven)
            return
        }
        let center = UNUserNotificationCenter.current()
        // Semaphore with a short timeout: getNotificationSettings is async and the NSE budget
        // is tight. If the system doesn't answer in time, fall back to Haven's preference.
        let box = DetailBox()
        center.getNotificationSettings { settings in
            let resolved: SharedNotificationPrivacy.Detail
            switch settings.showPreviewsSetting {
            case .never:
                // User asked the OS to never show notification content — honor that fully.
                resolved = .minimal
            case .whenAuthenticated:
                // Previews only when unlocked. An NSE cannot reliably know lock state
                // (UIApplication is unavailable / unprotected-data is still readable after first
                // unlock), so we use the private body: name + kind, no message text. That way a
                // glance at the lock screen never quotes a DM; the user opens Haven for the rest.
                resolved = .privateDetail
            case .always:
                resolved = .full
            @unknown default:
                resolved = .privateDetail
            }
            // Haven preference can only tighten, never loosen, past what the system allows.
            box.set(SharedNotificationPrivacy.stricter(haven, resolved))
        }
        // Wait up to 1.5s for settings; otherwise use Haven preference alone.
        let detail = box.wait(timeout: 1.5) ?? haven
        completion(detail)
    }

    private final class DetailBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SharedNotificationPrivacy.Detail?
        private let sem = DispatchSemaphore(value: 0)
        func set(_ d: SharedNotificationPrivacy.Detail) {
            lock.lock(); value = d; lock.unlock()
            sem.signal()
        }
        func wait(timeout: TimeInterval) -> SharedNotificationPrivacy.Detail? {
            _ = sem.wait(timeout: .now() + timeout)
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private static func applyPrivacy(_ decoded: Decoded,
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
    private static func redactIfLocked(_ obj: [String: Any]) -> Decoded? {
        guard let circleId = obj["c"] as? String, SharedLockedCircles.read().contains(circleId) else {
            return nil
        }
        return Decoded(title: "Haven", fullBody: "New activity in a locked circle",
                       privateBody: "New activity in a locked circle",
                       kind: "locked", emoji: nil, threadId: circleId,
                       deepLink: deepLink(circleId: circleId, postId: nil),
                       redactedForLock: true)
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the OS kills the extension — deliver our best effort.
        if let handler = contentHandler, let best = bestAttempt {
            handler(best)
        }
    }

    struct Decoded {
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

    /// Build a tap route from banner fields. Mirror of `DeepLink.interactionLink` /
    /// `DeepLink.storyLink` (NSE can't import the app target) — keep encodings in sync.
    private static func deepLink(circleId: String?, postId: String?, kind: String? = nil) -> String? {
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
    private static func decode(_ data: Data) -> Decoded? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let redacted = redactIfLocked(obj) { return redacted }
        let title = (obj["t"] as? String) ?? "Haven"
        let kind = obj["k"] as? String
        let emoji = obj["e"] as? String
        let circleId = obj["c"] as? String
        let postId = obj["p"] as? String
        let privateBody = obj["bp"] as? String
        // Call payload: no body, has peer hex.
        if obj["b"] == nil, obj["h"] is String {
            return Decoded(title: title, fullBody: "📞 Incoming call — open Haven to answer",
                           privateBody: "Incoming call",
                           kind: "call", emoji: nil, threadId: obj["h"] as? String, deepLink: nil)
        }
        var full = (obj["b"] as? String) ?? "New message"
        if full.isEmpty, let kind {
            full = fallbackBody(kind: kind, emoji: emoji)
        }
        let thread = circleId ?? kind
        return Decoded(title: title, fullBody: full, privateBody: privateBody,
                       kind: kind, emoji: emoji, threadId: thread,
                       deepLink: deepLink(circleId: circleId, postId: postId, kind: kind),
                       circleId: circleId, postId: postId,
                       mailboxKey: obj["mk"] as? String,
                       mediaRefs: obj["mr"] as? [String])
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

    /// Summary labels stay kind-only (no emoji) so a collapsed stack doesn't re-leak detail.
    private static func summaryLabel(kind: String) -> String {
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
}
