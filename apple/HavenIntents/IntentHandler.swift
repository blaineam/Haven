import Foundation
import Intents

/// Siri's messaging entry point: what "Hey Siri, read my Haven messages" / "tell Maya ... on Haven" /
/// the CarPlay conversation list (CPMessageListItem) resolve to.
///
/// **This process has no engine and no identity** - by design. It can only:
///   * read the privacy-filtered `MessagingSnapshot` the app mirrors into the App Group, and
///   * enqueue a `SiriRequest` (send text / mark read) for the app, then ring the app's doorbell.
/// The app seals and sends the message; Siri only reports "sent" once the app has acknowledged the
/// request (`SiriRequestSignal.ack`), otherwise it asks Siri to open Haven, which drains on launch.
final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        return self
    }
}

// MARK: - Shared helpers

enum IntentMessaging {
    /// How long to wait for the app to acknowledge a queued request before falling back to launching it.
    nonisolated(unsafe) static var ackTimeout: TimeInterval = 4

    static var snapshot: MessagingSnapshot? { MessagingSnapshotStore.read() }

    /// Live checks layered over the (possibly stale) snapshot: the lock set in the shared keychain and
    /// the notification-privacy setting can only make things stricter than what the app wrote.
    static func isLocked(_ c: MessagingSnapshot.Conversation) -> Bool {
        c.locked || SharedLockedCircles.read().contains(c.id)
    }

    static func detail(_ s: MessagingSnapshot) -> SharedNotificationPrivacy.Detail {
        let written = SharedNotificationPrivacy.Detail(rawValue: s.detail) ?? .minimal
        return SharedNotificationPrivacy.stricter(written, SharedNotificationPrivacy.detail)
    }

    static func person(handle: String?, name: String) -> INPerson {
        let h = INPersonHandle(value: handle ?? name, type: .unknown)
        return INPerson(personHandle: h, nameComponents: nil, displayName: name, image: nil,
                        contactIdentifier: nil, customIdentifier: handle ?? name)
    }

    static func people(_ c: MessagingSnapshot.Conversation) -> [INPerson] {
        if c.memberHandles.count == 1 { return [person(handle: c.memberHandles[0], name: c.title)] }
        return c.title.components(separatedBy: CharacterSet(charactersIn: ",&")).enumerated().map { i, n in
            person(handle: i < c.memberHandles.count ? c.memberHandles[i] : nil,
                   name: n.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Resolve an intent's target conversation: the CarPlay/Siri conversation identifier wins, then
    /// the recipient's node id, then the spoken name.
    static func conversation(id: String?, recipients: [INPerson]?, in s: MessagingSnapshot) -> [MessagingSnapshot.Conversation] {
        if let id, let c = s.conversation(id: id) { return [c] }
        guard let person = recipients?.first else { return [] }
        if let custom = person.customIdentifier, let c = s.conversation(handle: custom) { return [c] }
        if let handle = person.personHandle?.value, let c = s.conversation(handle: handle) { return [c] }
        return s.resolve(name: person.displayName)
    }

    /// Ring the app and wait (bounded, no polling) for its ack. Calls back exactly once.
    static func deliver(_ done: @escaping (Bool) -> Void) {
        let lock = NSLock()
        var finished = false
        var token: SiriRequestSignal.Token?
        func finish(_ ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            token?.cancel()
            done(ok)
        }
        token = SiriRequestSignal.observe(SiriRequestSignal.ack) { finish(true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + ackTimeout) { finish(false) }
        SiriRequestSignal.post(SiriRequestSignal.request)
    }
}

// MARK: - Send

extension IntentHandler: INSendMessageIntentHandling {
    func resolveRecipients(for intent: INSendMessageIntent,
                           with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void) {
        guard let s = IntentMessaging.snapshot else { completion([.unsupported(forReason: .noAccount)]); return }
        let matches = IntentMessaging.conversation(id: intent.conversationIdentifier, recipients: intent.recipients, in: s)
        switch matches.count {
        case 0:
            if intent.recipients?.isEmpty ?? true, intent.conversationIdentifier == nil {
                completion([.needsValue()])
            } else {
                completion([.unsupported(forReason: .noValidHandle)])
            }
        case 1:
            let people = IntentMessaging.people(matches[0])
            completion(people.map { .success(with: $0) })
        default:
            completion([.disambiguation(with: matches.compactMap { IntentMessaging.people($0).first })])
        }
    }

    func resolveContent(for intent: INSendMessageIntent, with completion: @escaping (INStringResolutionResult) -> Void) {
        let text = intent.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        completion(text.isEmpty ? .needsValue() : .success(with: text))
    }

    func confirm(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        guard let s = IntentMessaging.snapshot else {
            completion(INSendMessageIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)); return
        }
        let matches = IntentMessaging.conversation(id: intent.conversationIdentifier, recipients: intent.recipients, in: s)
        if matches.count == 1, IntentMessaging.isLocked(matches[0]) {
            // Face ID can't happen in a car. Refuse rather than send into a conversation the user locked.
            completion(INSendMessageIntentResponse(code: .failure, userActivity: nil)); return
        }
        completion(INSendMessageIntentResponse(code: matches.count == 1 ? .ready : .failure, userActivity: nil))
    }

    func handle(intent: INSendMessageIntent, completion: @escaping (INSendMessageIntentResponse) -> Void) {
        guard let s = IntentMessaging.snapshot,
              let c = IntentMessaging.conversation(id: intent.conversationIdentifier, recipients: intent.recipients, in: s).first,
              !IntentMessaging.isLocked(c),
              let text = intent.content,
              SiriRequestQueue.enqueue(kind: .send, conversationId: c.id, text: text) else {
            completion(INSendMessageIntentResponse(code: .failure, userActivity: nil)); return
        }
        IntentMessaging.deliver { acknowledged in
            // Not acknowledged: the app isn't running. The request stays queued and the app drains it on
            // launch, so ask Siri to open Haven rather than claim a send that hasn't happened.
            completion(INSendMessageIntentResponse(code: acknowledged ? .success : .failureRequiringAppLaunch,
                                                   userActivity: nil))
        }
    }
}

// MARK: - Read

extension IntentHandler: INSearchForMessagesIntentHandling {
    func handle(intent: INSearchForMessagesIntent, completion: @escaping (INSearchForMessagesIntentResponse) -> Void) {
        guard let s = IntentMessaging.snapshot else {
            completion(INSearchForMessagesIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)); return
        }
        let detail = IntentMessaging.detail(s)
        var pool: [MessagingSnapshot.Conversation]
        if let ids = intent.conversationIdentifiers, !ids.isEmpty {
            pool = ids.compactMap { s.conversation(id: $0) }
        } else if let sender = intent.senders?.first {
            pool = IntentMessaging.conversation(id: nil, recipients: [sender], in: s)
        } else {
            pool = s.conversations
        }
        // Attributes: none = everything; .unread / .read narrow it. Haven has no flagged/played state.
        let attrs = intent.attributes
        let onlyUnread = attrs.contains(.unread) && !attrs.contains(.read)
        let onlyRead = attrs.contains(.read) && !attrs.contains(.unread)
        let unsupportedOnly = !attrs.isEmpty && !attrs.contains(.unread) && !attrs.contains(.read)
        var out: [INMessage] = []
        for c in pool where !IntentMessaging.isLocked(c) {
            for m in c.messages where !m.text.isEmpty && detail == .full && !m.isMe && !unsupportedOnly {
                if onlyUnread && !m.unread { continue }
                if onlyRead && m.unread { continue }
                let sender = IntentMessaging.person(handle: c.memberHandles.count == 1 ? c.memberHandles[0] : nil,
                                              name: m.author.isEmpty ? c.title : m.author)
                out.append(INMessage(identifier: m.id, conversationIdentifier: c.id, content: m.text,
                                     dateSent: Date(timeIntervalSince1970: Double(m.at) / 1000),
                                     sender: sender, recipients: [], groupName: c.memberHandles.count > 1 ? INSpeakableString(spokenPhrase: c.title) : nil,
                                     messageType: .text))
            }
        }
        out.sort { ($0.dateSent ?? .distantPast) < ($1.dateSent ?? .distantPast) }
        if out.isEmpty {
            // Nothing readable: no messages, all locked, or the privacy setting hides content. One
            // generic failure covers all of them so Siri doesn't reveal which.
            completion(INSearchForMessagesIntentResponse(code: .failure, userActivity: nil)); return
        }
        let response = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
        response.messages = Array(out.suffix(10))
        completion(response)
    }
}

// MARK: - Mark read

extension IntentHandler: INSetMessageAttributeIntentHandling {
    func handle(intent: INSetMessageAttributeIntent, completion: @escaping (INSetMessageAttributeIntentResponse) -> Void) {
        guard intent.attribute == .read, let s = IntentMessaging.snapshot, let ids = intent.identifiers, !ids.isEmpty else {
            completion(INSetMessageAttributeIntentResponse(code: .failure, userActivity: nil)); return
        }
        var conversations = Set<String>()
        for c in s.conversations where !IntentMessaging.isLocked(c) && c.messages.contains(where: { ids.contains($0.id) }) {
            conversations.insert(c.id)
        }
        guard !conversations.isEmpty else {
            completion(INSetMessageAttributeIntentResponse(code: .failure, userActivity: nil)); return
        }
        for id in conversations { _ = SiriRequestQueue.enqueue(kind: .markRead, conversationId: id) }
        // Marking read is idempotent bookkeeping: report success whether or not the app is awake - the
        // queue is drained on its next run.
        SiriRequestSignal.post(SiriRequestSignal.request)
        completion(INSetMessageAttributeIntentResponse(code: .success, userActivity: nil))
    }
}

// MARK: - Calls

/// "Hey Siri, call Maya on Haven" (and the CarPlay call affordances). The extension only RESOLVES who
/// is meant; the call itself is placed by the app - it owns the engine, WebRTC and CallKit - so the
/// response is `.continueInApp` with the conversation id in the user activity.
extension IntentHandler: INStartCallIntentHandling {
    static let callActivityType = "INStartCallIntent"
    static let callActivityKey = "havenConversationId"

    func resolveContacts(for intent: INStartCallIntent,
                         with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let s = IntentMessaging.snapshot else { completion([.unsupported(forReason: .noContactFound)]); return }
        guard let person = intent.contacts?.first else { completion([.needsValue()]); return }
        let matches = IntentMessaging.conversation(id: nil, recipients: [person], in: s).filter { !IntentMessaging.isLocked($0) }
        switch matches.count {
        case 0: completion([.unsupported(forReason: .noContactFound)])
        case 1: completion([.success(with: IntentMessaging.people(matches[0]).first ?? person)])
        default: completion([.disambiguation(with: matches.compactMap { IntentMessaging.people($0).first })])
        }
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard let s = IntentMessaging.snapshot, let person = intent.contacts?.first,
              let c = IntentMessaging.conversation(id: nil, recipients: [person], in: s).first(where: { !IntentMessaging.isLocked($0) }) else {
            completion(INStartCallIntentResponse(code: .failure, userActivity: nil)); return
        }
        let activity = NSUserActivity(activityType: Self.callActivityType)
        activity.userInfo = [Self.callActivityKey: c.id]
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }
}
