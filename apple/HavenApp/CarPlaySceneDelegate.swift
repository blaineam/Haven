#if os(iOS)
import CarPlay
import Combine
import UIKit

/// The car's display (CarPlay, Communication category).
///
/// CarPlay connects this scene to the SAME process as the phone UI, so it reads the same `FeedStore`.
/// Root: a tab bar (when the entitlement allows 2+ tabs) with
///   * **Messages** - a `CPListTemplate` of direct-message conversations. DRIVING (the car reports a UI
///     limit) a tap opens NO screen: an unread conversation reads its unread messages aloud, any other is
///     the Siri-managed compose row ("what would you like to say?"), a locked one does nothing. PARKED a
///     tap opens the conversation screen: it shows the recent messages in chat order (a tap reads one aloud) above a "Reply"
///     row (the one Siri-managed `CPMessageListItem`, keyed by the DM circle id, which takes a spoken
///     reply through `HavenIntents`), with "Read to me" and "Call" as nav-bar buttons; DRIVING (the car
///     reports a UI limit - `CarPlayDriveMode`) it shows no message text at all, only those actions.
///   * **Calls** - callable conversations; a row dials that person straight away (no intermediate screen)
///     as an audio call through `CallManager` (CallKit then shows it natively on the car).
///
/// Rules this file keeps:
///   * never block the main thread - rows come from `FeedStore`'s cached read model and refresh on a
///     debounce; avatars are drawn off the main thread and applied if nothing newer superseded them;
///   * a conversation behind Face ID shows "Locked" with a generic avatar and no text (and is absent from
///     Calls), and the notification-privacy setting caps the preview (`CarPlayConversations` /
///     `MessagingPrivacy`);
///   * no identity yet (fresh install) -> a single "Open Haven on your iPhone" row.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPSessionConfigurationDelegate {
    private var interfaceController: CPInterfaceController?
    /// All navigation (set root / push / pop) goes through here: one op at a time, always a completion.
    private var navigator: CarPlayNavigator?
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
    /// My own profile picture for my message rows (photo / emoji / initials), nil until drawn or when I have none.
    private var myAvatar: UIImage?
    private static let myAvatarKey = "__me__"
    /// Retained for the session: the car's UI-limit reports (`limitedUserInterfaces`) arrive through it.
    private var carSession: CPSessionConfiguration?
    private var driveMode: CarPlayDriveMode = .parked

    // MARK: - Scene lifecycle

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        HavenLog.sync("carplay: connected")
        self.interfaceController = interfaceController
        navigator = CarPlayNavigator(controller: CarPlayControllerAdapter(interfaceController),
                                     log: { HavenLog.sync($0) })
        let configuration = CPSessionConfiguration(delegate: self)
        carSession = configuration
        driveMode = CarPlayDriveMode.mode(for: configuration.limitedUserInterfaces)
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
        navigator?.setRoot(root, animated: false)
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
        carSession = nil
        CarPlaySpeaker.shared.stop()
        self.interfaceController = nil
        navigator = nil
    }

    // MARK: - Parked / driving

    /// The vehicle started or stopped limiting its UI (it is moving / it is parked). Rebuild the Messages
    /// list and any open conversation right now, so message text never lingers on screen after the car
    /// starts moving.
    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        let mode = CarPlayDriveMode.mode(for: limitedUserInterfaces)
        Task { @MainActor [weak self] in
            guard let self, self.driveMode != mode else { return }
            HavenLog.sync("carplay: \(mode == .driving ? "driving" : "parked")")
            self.driveMode = mode
            // Driving has no conversation menu: a screen left open from when the car was parked closes,
            // back to the list (whose rows now read / compose directly).
            if mode == .driving, self.openConversation != nil {
                self.openConversation = nil
                self.navigator?.popToRoot(animated: false)
            }
            self.refresh()
        }
    }

    // MARK: - Refresh

    private func observe() {
        cancellables.removeAll()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Feed changes (new message), read watermarks (cleared a badge), per-circle lock toggles.
            // Also the palette (Settings > Appearance) and my profile (photo / emoji), so the car follows
            // both without a reconnect. `PaletteStore.shared` is touched here on purpose: it loads the
            // stored choice even when the app was launched by CarPlay with no phone UI.
            Publishers.MergeMany([
                FeedStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                DMReadStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                CircleSettingsStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                PaletteStore.shared.$palette.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                ProfileStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ])
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
        // My own picture for my message rows (nil spec = no profile data = tinted bubble glyph).
        let profile = ProfileStore.shared
        let mySpec = CarPlayAvatar.chooseOwn(hasPhoto: profile.avatar != nil, emoji: profile.emoji, name: profile.displayName)
        let myPhoto = profile.avatar
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
        let mine2 = mySpec.map { Input(id: Self.myAvatarKey, spec: $0, photo: myPhoto, stamp: myPhoto.map { ObjectIdentifier($0).hashValue } ?? 0) }
        Task.detached(priority: .userInitiated) { [weak self] in
            var images: [String: UIImage] = Dictionary(uniqueKeysWithValues: inputs.map { i in
                (i.id, CarPlayAvatarRenderer.shared.image(
                    for: i.spec, photo: i.photo, photoStamp: i.stamp, id: i.id, side: side, scale: scale,
                    paletteId: palette.id, stops: palette.stops))
            })
            if let m = mine2 {
                images[m.id] = CarPlayAvatarRenderer.shared.image(
                    for: m.spec, photo: m.photo, photoStamp: m.stamp, id: m.id, side: side, scale: scale,
                    paletteId: palette.id, stops: palette.stops)
            }
            await self?.applyAvatars(images, generation: mine, rows: rows, configured: configured, enabled: enabled)
        }
    }

    @MainActor private func applyAvatars(_ images: [String: UIImage], generation mine: Int,
                                         rows: [CarPlayConversations.Row], configured: Bool, enabled: Bool) {
        guard mine == generation else { return }
        var images = images
        myAvatar = images.removeValue(forKey: Self.myAvatarKey)
        avatarsByID = images
        refreshOpenConversation()
        messagesTemplate?.updateSections([messagesSection(rows: rows, configured: configured, enabled: enabled, avatars: images)])
        callsTemplate?.updateSections([callsSection(avatars: images)])
    }

    // MARK: - Messages

    @MainActor private func messagesSection(rows: [CarPlayConversations.Row], configured: Bool, enabled: Bool,
                                            avatars: [String: UIImage]) -> CPListSection {
        CarPlayTemplates.section(for: rows, configured: configured, enabled: enabled, mode: driveMode,
                                 canSpeak: detailLevel == .full, avatars: avatars,
                                 unreadMark: CarPlayTemplates.unreadDot(color: CarPlayTemplates.tintColor(stops: PaletteStore.current.stops)),
                                 onSelect: { [weak self] row in self?.showConversation(row.conversationId) },
                                 // Driving: no menu - an unread row just reads aloud.
                                 onRead: { [weak self] row in self?.read(row.conversationId, unreadOnly: true) })
    }

    @MainActor private func conversationScreen(_ id: String) -> CarPlayTemplates.ConversationScreen? {
        guard let thread = threadsByID[id] else { return nil }
        let detail = CarPlayConversations.detail(thread: thread, detail: detailLevel, now: Date())
        let tint = CarPlayTemplates.tintColor(stops: PaletteStore.current.stops)
        let art = CarPlayTemplates.ConversationArt(
            theirAvatar: avatarsByID[id],
            theirBubble: CarPlayTemplates.bubbleIcon(mine: false, tint: tint),
            myBubble: CarPlayTemplates.bubbleIcon(mine: true, tint: tint),
            myAvatar: myAvatar,
            unreadMark: CarPlayTemplates.unreadDot(color: tint),
            replyIcon: CarPlayTemplates.glyph("mic.fill", tint: tint))
        return CarPlayTemplates.conversationScreen(
            for: detail, mode: driveMode, art: art,
            onRead: { [weak self] in self?.read(id, unreadOnly: true) },
            onCall: { [weak self] in
                if let row = self?.callRows.first(where: { $0.conversationId == id }) { self?.dial(row) }
            },
            onSpeak: { [weak self] line in self?.speakLine(id, line) })
    }

    @MainActor private func showConversation(_ id: String) {
        // Never in limited UI (no conversation screen while driving) and never over a screen already open.
        guard let navigator, driveMode == .parked, openConversation == nil, let screen = conversationScreen(id),
              let title = threadsByID[id]?.title else { return }
        let template = CPListTemplate(title: title, sections: screen.sections)
        template.trailingNavigationBarButtons = screen.buttons
        openConversation = (id, template)
        navigator.push(template, animated: true)
    }

    /// New messages arriving while a conversation is open, or the car starting/stopping, update it in place.
    @MainActor private func refreshOpenConversation() {
        guard let open = openConversation else { return }
        guard navigator?.contains(open.template) == true,
              let fresh = conversationScreen(open.id) else { openConversation = nil; return }
        open.template.updateSections(fresh.sections)
        open.template.trailingNavigationBarButtons = fresh.buttons
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
            self?.dial(row)
        }
    }

    /// Tapping a person dials them - no intermediate screen. Back to the root first (a no-op from the
    /// Calls tab) so the call UI CallKit raises isn't under a pushed conversation screen.
    @MainActor private func dial(_ row: CarPlayConversations.CallRow) {
        navigator?.popToRoot(animated: false)
        SiriCallRouter.place(conversationId: row.conversationId)
    }
}

/// `CPInterfaceController` seen through `CarPlayNavigating` (see `CarPlayNavigator` for why every call carries a completion).
private final class CarPlayControllerAdapter: CarPlayNavigating {
    private let controller: CPInterfaceController
    init(_ controller: CPInterfaceController) { self.controller = controller }

    var stack: [AnyObject] { controller.templates }

    func setRoot(_ template: AnyObject, animated: Bool, completion: @escaping (Bool, Error?) -> Void) {
        guard let template = template as? CPTemplate else { return completion(false, nil) }
        controller.setRootTemplate(template, animated: animated, completion: completion)
    }

    func push(_ template: AnyObject, animated: Bool, completion: @escaping (Bool, Error?) -> Void) {
        guard let template = template as? CPTemplate else { return completion(false, nil) }
        controller.pushTemplate(template, animated: animated, completion: completion)
    }

    func popToRoot(animated: Bool, completion: @escaping (Bool, Error?) -> Void) {
        controller.popToRootTemplate(animated: animated, completion: completion)
    }
}
#endif
