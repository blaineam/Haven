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

    /// The one `INPerson` that stands for a conversation in resolution results: a 1:1 carries its
    /// partner's node id, a group carries the conversation id (there is no single handle).
    static func people(_ c: MessagingSnapshot.Conversation) -> [INPerson] {
        [person(handle: c.memberHandles.count == 1 ? c.memberHandles[0] : c.id, name: c.title)]
    }

    /// What Siri heard for one person: the display name, the structured name, and a readable handle.
    static func queries(for p: INPerson) -> [String] {
        var q = [p.displayName]
        if let nc = p.nameComponents { q.append(PersonNameComponentsFormatter().string(from: nc)) }
        if let h = p.personHandle?.value, h.contains(where: \.isLetter), !h.contains("@"), h.count < 64 { q.append(h) }
        var seen = Set<String>()
        return q.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    enum Resolved {
        /// The one conversation this resolves to (a tentative match counts: Siri reaches `handle` only
        /// after the user confirmed it); nil when none or still ambiguous.
        var single: MessagingSnapshot.Conversation? {
            switch self {
            case .one(let c), .tentative(let c): return c
            default: return nil
            }
        }
        case none
        case one(MessagingSnapshot.Conversation)
        /// Several equally plausible; never pick silently.
        case many([MessagingSnapshot.Conversation])
        /// One weak candidate: ask the user to confirm.
        case tentative(MessagingSnapshot.Conversation)
    }

    /// Resolve an intent's target: the CarPlay/Siri conversation identifier wins, then a handle or
    /// conversation id we handed out earlier (`people`), then the fuzzy spoken name.
    static func resolve(id: String?, people: [INPerson]?, in s: MessagingSnapshot) -> Resolved {
        if let id, let c = s.conversation(id: id) { return .one(c) }
        guard let person = people?.first else { return .none }
        for key in [person.customIdentifier, person.personHandle?.value].compactMap({ $0 }) {
            if let c = s.conversation(handle: key) ?? s.conversation(id: key) { return .one(c) }
        }
        switch s.resolution(queries: queries(for: person)) {
        case .none: return .none
        case .confident(let m): return s.conversation(id: m.id).map(Resolved.one) ?? .none
        case .tentative(let m): return s.conversation(id: m.id).map(Resolved.tentative) ?? .none
        case .ambiguous(let ms):
            let cs = ms.compactMap { s.conversation(id: $0.id) }
            return cs.isEmpty ? .none : .many(cs)
        }
    }

    /// `resolve` for requests that must never touch a locked conversation (calls). The winner is judged
    /// against EVERYTHING first: if the person the user meant is locked, the answer is "none" - never a
    /// look-alike substitute ("Maya" locked must not quietly become "Maya Chen"). Locked entries are only
    /// dropped from a genuinely ambiguous list.
    static func resolveUnlocked(id: String?, people: [INPerson]?, in s: MessagingSnapshot) -> Resolved {
        switch resolve(id: id, people: people, in: s) {
        case .none: return .none
        case .one(let c): return isLocked(c) ? .none : .one(c)
        case .tentative(let c): return isLocked(c) ? .none : .tentative(c)
        case .many(let cs):
            let open = cs.filter { !isLocked($0) }
            return open.count >= 2 ? .many(open) : (open.first.map(Resolved.tentative) ?? .none)
        }
    }

    /// For `handle`/`confirm`: the single conversation the request is about (a tentative match counts -
    /// Siri only reaches `handle` after the user confirmed it), nil when still ambiguous or unknown.
    static func conversation(id: String?, recipients: [INPerson]?, in s: MessagingSnapshot) -> [MessagingSnapshot.Conversation] {
        switch resolve(id: id, people: recipients, in: s) {
        case .none: return []
        case .one(let c), .tentative(let c): return [c]
        case .many(let cs): return cs
        }
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
        switch IntentMessaging.resolve(id: intent.conversationIdentifier, people: intent.recipients, in: s) {
        case .none:
            if intent.recipients?.isEmpty ?? true, intent.conversationIdentifier == nil {
                completion([.needsValue()])
            } else {
                completion([.unsupported(forReason: .noValidHandle)])
            }
        case .one(let c):
            completion(IntentMessaging.people(c).map { .success(with: $0) })
        case .tentative(let c):
            completion(IntentMessaging.people(c).map { .confirmationRequired(with: $0) })
        case .many(let cs):
            completion([.disambiguation(with: cs.flatMap { IntentMessaging.people($0) })])
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
              case let found = IntentMessaging.conversation(id: intent.conversationIdentifier, recipients: intent.recipients, in: s),
              found.count == 1, let c = found.first,
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
    /// "Read my messages from Tracy": same fuzzy rules as sending - confident, disambiguate, or confirm.
    func resolveSenders(for intent: INSearchForMessagesIntent,
                        with completion: @escaping ([INPersonResolutionResult]) -> Void) {
        guard let people = intent.senders, !people.isEmpty else { completion([.notRequired()]); return }
        guard let s = IntentMessaging.snapshot else { completion([.unsupported()]); return }
        completion(people.prefix(1).map { p in
            switch IntentMessaging.resolve(id: nil, people: [p], in: s) {
            case .none: return .unsupported()
            case .one(let c): return .success(with: IntentMessaging.people(c)[0])
            case .tentative(let c): return .confirmationRequired(with: IntentMessaging.people(c)[0])
            case .many(let cs): return .disambiguation(with: cs.flatMap { IntentMessaging.people($0) })
            }
        })
    }

    func handle(intent: INSearchForMessagesIntent, completion: @escaping (INSearchForMessagesIntentResponse) -> Void) {
        guard let s = IntentMessaging.snapshot else {
            completion(INSearchForMessagesIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)); return
        }
        let detail = IntentMessaging.detail(s)
        var pool: [MessagingSnapshot.Conversation]
        if let ids = intent.conversationIdentifiers, !ids.isEmpty {
            pool = ids.compactMap { s.conversation(id: $0) }
        } else if let sender = intent.senders?.first {
            // Ambiguous sender names read every plausible thread rather than guessing one.
            pool = IntentMessaging.conversation(id: nil, recipients: [sender], in: s)
        } else {
            pool = s.conversations
        }
        // Attributes: none = everything; .unread / .read narrow it. Haven has no flagged/played state.
        let attrs = intent.attributes
        let unsupportedOnly = !attrs.isEmpty && !attrs.contains(.unread) && !attrs.contains(.read)
        var query = MessagingSearch.Query()
        query.onlyUnread = attrs.contains(.unread) && !attrs.contains(.read)
        query.onlyRead = attrs.contains(.read) && !attrs.contains(.unread)
        query.terms = intent.searchTerms ?? []
        // "Earlier messages": Siri bounds the request with a date range; the page just before `to`.
        let cal = Calendar.current
        query.from = intent.dateTimeRange?.startDateComponents.flatMap { cal.date(from: $0) }
        query.to = intent.dateTimeRange?.endDateComponents.flatMap { cal.date(from: $0) }
        var out: [INMessage] = []
        for c in pool where !IntentMessaging.isLocked(c) && detail == .full && !unsupportedOnly {
            for m in MessagingSearch.select(c.messages, query) {
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
    static let callAudioOnlyKey = "havenAudioOnly"

    func resolveContacts(for intent: INStartCallIntent,
                         with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let s = IntentMessaging.snapshot else { completion([.unsupported(forReason: .noContactFound)]); return }
        guard let person = intent.contacts?.first else { completion([.needsValue()]); return }
        // A locked conversation cannot be called from a car (no Face ID): leave it out of the candidates
        // so it is never offered, and "no contact" is the honest answer if it was the only match.
        switch IntentMessaging.resolveUnlocked(id: nil, people: [person], in: s) {
        case .none: completion([.unsupported(forReason: .noContactFound)])
        case .one(let c): completion([.success(with: IntentMessaging.people(c)[0])])
        case .tentative(let c): completion([.confirmationRequired(with: IntentMessaging.people(c)[0])])
        case .many(let cs): completion([.disambiguation(with: cs.flatMap { IntentMessaging.people($0) })])
        }
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard let s = IntentMessaging.snapshot, let person = intent.contacts?.first,
              case let found = IntentMessaging.resolveUnlocked(id: nil, people: [person], in: s),
              let c = found.single else {
            completion(INStartCallIntentResponse(code: .failure, userActivity: nil)); return
        }
        let activity = NSUserActivity(activityType: Self.callActivityType)
        // Haven calls always START audio-only (also when Siri asked for video: a head unit cannot show
        // it); video can be switched on from the phone once the call is up.
        activity.userInfo = [Self.callActivityKey: c.id, Self.callAudioOnlyKey: true]
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }
}
