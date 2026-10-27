#if os(iOS)
import CarPlay
import Combine
import UIKit

/// The car's display (CarPlay, Communication category).
///
/// CarPlay connects this scene to the SAME process as the phone UI, so it reads the same `FeedStore`.
/// Root: a tab bar (when the entitlement allows 2+ tabs) with
///   * **Messages** - a `CPListTemplate` of direct-message conversations. A tap opens the conversation
///     screen: "Read new messages" (Haven reads them aloud), a "Reply" row (the one Siri-managed
///     `CPMessageListItem`, keyed by the DM circle id, which takes a spoken reply through `HavenIntents`),
///     "Call on Haven", and the recent messages (newest first; a tap reads one aloud).
///   * **Calls** - callable conversations; a row opens a `CPContactTemplate` whose "Call on Haven" button
///     starts an audio call through `CallManager` (CallKit then shows it natively on the car).
///
/// Rules this file keeps:
///   * never block the main thread - rows come from `FeedStore`'s cached read model and refresh on a
///     debounce; avatars are drawn off the main thread and applied if nothing newer superseded them;
///   * a conversation behind Face ID shows "Locked" with a generic avatar and no text (and is absent from
///     Calls), and the notification-privacy setting caps the preview (`CarPlayConversations` /
///     `MessagingPrivacy`);
///   * no identity yet (fresh install) -> a single "Open Haven on your iPhone" row.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var messagesTemplate: CPListTemplate?
    private var callsTemplate: CPListTemplate?
    private var cancellables = Set<AnyCancellable>()
    /// Bumps on every refresh request so a stale async build never overwrites a newer one.
    private var generation = 0
    private var callRows: [CarPlayConversations.CallRow] = []
    private var threadsByID: [String: MessagingThread] = [:]
    private var detailLevel: SharedNotificationPrivacy.Detail = .minimal
    /// The conversation screen currently on top, refreshed in place when new messages arrive.
    private var openConversation: (id: String, template: CPListTemplate)?
    private var avatarsByID: [String: UIImage] = [:]

    // MARK: - Scene lifecycle

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        HavenLog.sync("carplay: connected")
        self.interfaceController = interfaceController
        let messages = CPListTemplate(title: "Haven", sections: [CarPlayTemplates.section(for: [], configured: false, enabled: true)])
        messages.emptyViewSubtitleVariants = [MessagingText.noConversations]
        messagesTemplate = messages
        var root: CPTemplate = messages
        if CPTabBarTemplate.maximumTabCount >= 2 {
            messages.tabTitle = MessagingText.tabMessages
            messages.tabImage = UIImage(systemName: "message.fill")
            let calls = CPListTemplate(title: MessagingText.tabCalls, sections: [CarPlayTemplates.callsSection(for: []) { _ in }])
            calls.tabTitle = MessagingText.tabCalls
            calls.tabImage = UIImage(systemName: "phone.fill")
            callsTemplate = calls
            root = CPTabBarTemplate(templates: [messages, calls])
        }
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        refresh()
        observe()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        HavenLog.sync("carplay: disconnected")
        cancellables.removeAll()
        messagesTemplate = nil
        callsTemplate = nil
        openConversation = nil
        CarPlaySpeaker.shared.stop()
        self.interfaceController = nil
    }

    // MARK: - Refresh

    private func observe() {
        cancellables.removeAll()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Feed changes (new message), read watermarks (cleared a badge), per-circle lock toggles.
            Publishers.Merge3(FeedStore.shared.objectWillChange.map { _ in () },
                              DMReadStore.shared.objectWillChange.map { _ in () },
                              CircleSettingsStore.shared.objectWillChange.map { _ in () })
                .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
                .sink { [weak self] in self?.refresh() }
                .store(in: &self.cancellables)
        }
    }

    @MainActor private func refresh() {
        guard let template = messagesTemplate else { return }
        generation += 1
        let mine = generation
        let limit = min(CarPlayConversations.defaultLimit, CPListTemplate.maximumItemCount)
        let configured = FeedStore.shared.isConfigured
        let enabled = SettingsStore.shared.carPlayAndSiri
        let threads = enabled && configured ? MessagingThreads.current() : []
        let detail = MessagingThreads.privacyDetail
        let rows = CarPlayConversations.rows(threads: threads, detail: detail, now: Date(), limit: limit)
        callRows = enabled && configured ? CarPlayConversations.callRows(threads: threads, limit: limit) : []
        threadsByID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        detailLevel = detail
        // Rows first, from text alone, so the list is never held up by image work...
        template.updateSections([messagesSection(rows: rows, configured: configured, enabled: enabled, avatars: avatarsByID)])
        refreshOpenConversation()
        callsTemplate?.updateSections([callsSection(avatars: avatarsByID)])
        guard enabled, configured, !rows.isEmpty || !callRows.isEmpty else { return }
        // ...then avatars: inputs are read here (stores are main-actor), drawn off the main thread
        // (CarPlayAvatarRenderer is cached and thread-safe), and applied if nothing newer superseded us.
        let store = FeedStore.shared, contacts = ContactsStore.shared
        struct Input: @unchecked Sendable { let id: String; let spec: CarPlayAvatar.Spec; let photo: UIImage?; let stamp: Int }
        var seen = Set<String>()
        let named: [(id: String, title: String, locked: Bool)] =
            rows.map { ($0.conversationId, $0.title, $0.locked) } + callRows.map { ($0.conversationId, $0.title, false) }
        let inputs: [Input] = named.compactMap { n in
            guard seen.insert(n.id).inserted else { return nil }
            let hexes = store.dmMemberHexes(n.id)
            let photoHex = hexes.first { contacts.avatarImage(forNodePrefix: $0) != nil }
            let photo = photoHex.flatMap { contacts.avatarImage(forNodePrefix: $0) }
            let emoji = hexes.count == 1 ? contacts.emoji(forNodePrefix: hexes[0]) : nil
            let spec = CarPlayAvatar.choose(locked: n.locked, detail: detail, hasPhoto: photo != nil,
                                            emoji: emoji, name: n.title)
            return Input(id: n.id, spec: spec, photo: photo, stamp: photo.map { ObjectIdentifier($0).hashValue } ?? 0)
        }
        let side = CarPlayAvatar.side(max: CPMaximumMessageItemImageSize)
        let scale = interfaceController?.carTraitCollection.displayScale ?? 2
        let palette = PaletteStore.current
        Task.detached(priority: .userInitiated) { [weak self] in
            let images: [String: UIImage] = Dictionary(uniqueKeysWithValues: inputs.map { i in
                (i.id, CarPlayAvatarRenderer.shared.image(
                    for: i.spec, photo: i.photo, photoStamp: i.stamp, id: i.id, side: side, scale: scale,
                    paletteId: palette.id, stops: palette.stops))
            })
            await self?.applyAvatars(images, generation: mine, rows: rows, configured: configured, enabled: enabled)
        }
    }

    @MainActor private func applyAvatars(_ images: [String: UIImage], generation mine: Int,
                                         rows: [CarPlayConversations.Row], configured: Bool, enabled: Bool) {
        guard mine == generation else { return }
        avatarsByID = images
        messagesTemplate?.updateSections([messagesSection(rows: rows, configured: configured, enabled: enabled, avatars: images)])
        callsTemplate?.updateSections([callsSection(avatars: images)])
    }

    // MARK: - Messages

    @MainActor private func messagesSection(rows: [CarPlayConversations.Row], configured: Bool, enabled: Bool,
                                            avatars: [String: UIImage]) -> CPListSection {
        CarPlayTemplates.section(for: rows, configured: configured, enabled: enabled, avatars: avatars,
                                 unreadMark: CarPlayTemplates.unreadDot(color: UIColor(PaletteStore.current.tint))) { [weak self] row in
            self?.showConversation(row.conversationId)
        }
    }

    @MainActor private func conversationTemplate(_ id: String) -> CPListTemplate? {
        guard let thread = threadsByID[id] else { return nil }
        let detail = CarPlayConversations.detail(thread: thread, detail: detailLevel, now: Date())
        return CarPlayTemplates.conversationTemplate(
            for: detail,
            onRead: { [weak self] in self?.read(id, unreadOnly: true) },
            onCall: { [weak self] in
                if let row = self?.callRows.first(where: { $0.conversationId == id }) { self?.showContact(row) }
            },
            onSpeak: { [weak self] line in self?.speakLine(id, line) })
    }

    @MainActor private func showConversation(_ id: String) {
        guard let controller = interfaceController, let template = conversationTemplate(id) else { return }
        openConversation = (id, template)
        controller.pushTemplate(template, animated: true, completion: nil)
    }

    /// New messages arriving while a conversation is open update it in place.
    @MainActor private func refreshOpenConversation() {
        guard let open = openConversation else { return }
        guard interfaceController?.templates.contains(where: { $0 === open.template }) == true,
              let fresh = conversationTemplate(open.id) else { openConversation = nil; return }
        open.template.updateSections(fresh.sections)
    }

    /// "Read new messages": the unread ones (or the latest few), then mark the thread read - it has
    /// been heard, so the unread dot goes away like it would after opening it on the phone.
    @MainActor private func read(_ id: String, unreadOnly: Bool) {
        guard let thread = threadsByID[id] else { return }
        let script = CarPlayConversations.spokenScript(thread: thread, detail: detailLevel)
        guard !script.isEmpty else { return }
        let newest = thread.messages.map(\.createdAt).max() ?? 0
        CarPlaySpeaker.shared.speak(script) {
            DMReadStore.shared.markRead(id, newestMessageAt: newest)
        }
    }

    @MainActor private func speakLine(_ id: String, _ line: CarPlayConversations.Line) {
        guard let thread = threadsByID[id], !thread.locked, detailLevel == .full else { return }
        let author = thread.memberHandles.count > 1 ? thread.messages.first { $0.id == line.id }?.author : nil
        CarPlaySpeaker.shared.speak([author.flatMap { $0.isEmpty ? nil : MessagingText.says($0, line.text) } ?? line.text])
    }

    // MARK: - Calls

    @MainActor private func callsSection(avatars: [String: UIImage]) -> CPListSection {
        CarPlayTemplates.callsSection(for: callRows, avatars: avatars) { [weak self] row in
            self?.showContact(row)
        }
    }

    @MainActor private func showContact(_ row: CarPlayConversations.CallRow) {
        guard let controller = interfaceController else { return }
        let side = CarPlayAvatar.side(max: CPButtonMaximumImageSize)
        let image = avatarsByID[row.conversationId]
            ?? CarPlayAvatarRenderer.shared.image(for: .initials(CarPlayAvatar.initials(row.title)), photo: nil, photoStamp: 0,
                                                  id: row.conversationId, side: side, scale: controller.carTraitCollection.displayScale,
                                                  paletteId: PaletteStore.current.id, stops: PaletteStore.current.stops)
        let template = CarPlayTemplates.contactTemplate(for: row, avatar: image) { [weak self] in
            // Back to the list first so the call UI CallKit raises isn't under a pushed template.
            self?.interfaceController?.popToRootTemplate(animated: false, completion: nil)
            SiriCallRouter.place(conversationId: row.conversationId)
        }
        controller.pushTemplate(template, animated: true, completion: nil)
    }
}
#endif
