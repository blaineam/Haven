#if os(iOS)
import CarPlay
import Combine
import UIKit

/// The car's display (CarPlay, Communication category).
///
/// CarPlay connects this scene to the SAME process as the phone UI, so it reads the same `FeedStore`.
/// The root is a `CPListTemplate` of direct-message conversations rendered as `CPMessageListItem`s:
/// those are Siri-managed - selecting one does not call back into us. Siri reads the conversation
/// (unread) or starts a reply (read) through `HavenIntents`, keyed by the `conversationIdentifier`
/// (the DM circle id). That is Apple's model for messaging in the car: nothing is typed or scrolled.
///
/// Rules this file keeps:
///   * never block the main thread - rows come from `FeedStore`'s cached read model and refresh on a
///     debounce, so a burst of inbound events is one template update;
///   * a conversation behind Face ID shows "Locked" and no text, and the notification-privacy
///     setting caps the preview (`CarPlayConversations` / `MessagingPrivacy`);
///   * no identity yet (fresh install) -> a single "Open Haven on your iPhone" row.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var cancellables = Set<AnyCancellable>()
    /// Bumps on every refresh request so a stale async build never overwrites a newer one.
    private var generation = 0

    // MARK: - Scene lifecycle

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        HavenLog.sync("carplay: connected")
        self.interfaceController = interfaceController
        let template = CPListTemplate(title: "Haven", sections: [Self.section(for: [], configured: false, enabled: true)])
        template.emptyViewSubtitleVariants = ["No conversations yet"]
        listTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        refresh()
        observe()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        HavenLog.sync("carplay: disconnected")
        cancellables.removeAll()
        listTemplate = nil
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
        guard let template = listTemplate else { return }
        generation += 1
        let mine = generation
        let limit = min(CarPlayConversations.defaultLimit, CPListTemplate.maximumItemCount)
        let configured = FeedStore.shared.isConfigured
        let enabled = SettingsStore.shared.carPlayAndSiri
        let rows = !enabled ? [] : CarPlayConversations.rows(threads: MessagingThreads.current(),
                                             detail: MessagingThreads.privacyDetail,
                                             now: Date(), limit: limit)
        guard mine == generation else { return }
        let avatars = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, UIImage)? in
            guard !row.locked, let hex = FeedStore.shared.dmPartnerHex(row.conversationId),
                  let img = ContactsStore.shared.avatarImage(forNodePrefix: hex) else { return nil }
            return (row.conversationId, img)
        })
        template.updateSections([Self.section(for: rows, configured: configured, enabled: enabled, avatars: avatars)])
    }

    // MARK: - Template building

    private static func section(for rows: [CarPlayConversations.Row], configured: Bool, enabled: Bool,
                                avatars: [String: UIImage] = [:]) -> CPListSection {
        if !enabled {
            return CPListSection(items: [CPListItem(text: "Turned off", detailText: "Turn on CarPlay and Siri messages in Haven Settings on your iPhone.")])
        }
        if !configured {
            return CPListSection(items: [CPListItem(text: "Open Haven on your iPhone", detailText: "Finish setting up to see your conversations.")])
        }
        if rows.isEmpty {
            return CPListSection(items: [CPListItem(text: "No conversations yet", detailText: "Say \u{201C}Hey Siri, send a message with Haven\u{201D} once you have someone to talk to.")])
        }
        let items: [CPListTemplateItem] = rows.map { row in
            let leading = CPMessageListItemLeadingConfiguration(
                leadingItem: .none,
                leadingImage: avatars[row.conversationId].map(scaledForCar),
                unread: row.unread)
            return CPMessageListItem(conversationIdentifier: row.conversationId,
                                     text: row.title,
                                     leadingConfiguration: leading,
                                     trailingConfiguration: nil,
                                     detailText: row.detail.isEmpty ? nil : row.detail,
                                     trailingText: row.trailing.isEmpty ? nil : row.trailing)
        }
        return CPListSection(items: items)
    }

    private static func scaledForCar(_ image: UIImage) -> UIImage {
        let max = CPMaximumMessageItemImageSize
        let scale = min(max.width / image.size.width, max.height / image.size.height, 1)
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
