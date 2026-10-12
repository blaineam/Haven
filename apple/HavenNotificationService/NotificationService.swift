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
    typealias Decoded = NotificationPayload

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    /// SIGPIPE ignored like the app (see HavenApp.init): the extension fetches over the same
    /// sockets, and an extension killed by SIGPIPE just shows nothing.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        _ = Self.ignoreSIGPIPE
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
              let decoded = NotificationPayloadCodec.decode(opened.data, lockedCircles: SharedLockedCircles.read()) else {
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
            let shown = NotificationPayloadCodec.applyPrivacy(decoded, detail: detail)
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
        guard let plan = NotificationPayloadCodec.prefetchPlan(decoded, hasInlineEvent: hasInlineEvent) else {
            deliver()
            return
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await SharedPushPrefetch.run(circleId: plan.circleId, mailboxKey: plan.mailboxKey,
                                                 mediaRefs: plan.mediaRefs, skipEnvelope: plan.skipEnvelope)
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
            // Haven preference can only tighten, never loosen, past what the system allows (see
            // `NotificationPayloadCodec.detail` for the mapping). An NSE cannot reliably know lock
            // state, so "when unlocked" maps to the private body: name + kind, no message text.
            box.set(NotificationPayloadCodec.detail(haven: haven, systemPreviews: settings.showPreviewsSetting))
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



    override func serviceExtensionTimeWillExpire() {
        // Called just before the OS kills the extension — deliver our best effort.
        if let handler = contentHandler, let best = bestAttempt {
            handler(best)
        }
    }





}
