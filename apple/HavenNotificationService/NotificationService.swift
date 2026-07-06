import UserNotifications

/// The Notification Service Extension. When the blind push relay wakes this device, the
/// real content is NOT in the visible payload — the relay only ever forwards the field `e`,
/// a base64 blob that was sealed (hybrid post-quantum) to *us* by the sender. iOS hands the
/// push to this extension first; we read our master seed from the shared Keychain, decrypt
/// `e` with `openSealedWithSeed`, and rewrite the alert so the banner shows the real sender
/// and message. The relay never sees plaintext, and decryption happens on-device even on the
/// lock screen.
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
              let (title, body) = Self.decode(opened.data) else {
            // Couldn't decrypt — keep the relay's generic banner (don't leak/guess content).
            if best.body.isEmpty { best.body = "New activity" }
            contentHandler(best)
            return
        }

        best.title = title
        best.body = body
        contentHandler(best)
    }

    /// If the sealed payload names a circle the user has biometric-locked, hide its content —
    /// a lock-screen banner spelling out the message would defeat the lock.
    private static func redactIfLocked(_ obj: [String: Any]) -> (String, String)? {
        guard let circleId = obj["c"] as? String, SharedLockedCircles.read().contains(circleId) else {
            return nil
        }
        return ("Haven", "New activity in a locked circle")
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the OS kills the extension — deliver our best effort.
        if let handler = contentHandler, let best = bestAttempt {
            handler(best)
        }
    }

    /// The sealed payload is a tiny JSON object `{ "t": <title>, "b": <body>, "c": <circleId> }`.
    /// A CALL payload is `{ "t": <caller name>, "h": <caller hex> }` — same blob the PushKit
    /// handler opens; it reaches the NSE only via the worker's `/call` FALLBACK (no live VoIP
    /// token), so label it as an incoming call rather than the generic "New message".
    private static func decode(_ data: Data) -> (String, String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let redacted = redactIfLocked(obj) { return redacted }
        let title = (obj["t"] as? String) ?? "Haven"
        if obj["b"] == nil, obj["h"] is String {
            return (title, "📞 Incoming call — open Haven to answer")
        }
        let body = (obj["b"] as? String) ?? "New message"
        return (title, body)
    }
}
