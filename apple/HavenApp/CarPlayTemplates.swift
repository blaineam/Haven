#if os(iOS)
import CarPlay
import UIKit

/// Builds the CarPlay list sections from `CarPlayConversations.Row`s. Separate from the scene delegate
/// (which needs the live app stores) so the template construction - where CarPlay raises on a bad
/// argument - is exercised by a host-less test (`CarPlayTemplatesTests`).
enum CarPlayTemplates {
    static func section(for rows: [CarPlayConversations.Row], configured: Bool, enabled: Bool,
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
                leadingImage: avatars[row.conversationId],
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

    // MARK: Calls

    /// The Calls tab list. A row opens a contact card (never dials on the first tap - an accidental
    /// touch on a dashboard must not ring someone).
    static func callsSection(for rows: [CarPlayConversations.CallRow], avatars: [String: UIImage] = [:],
                             onSelect: @escaping (CarPlayConversations.CallRow) -> Void) -> CPListSection {
        guard !rows.isEmpty else {
            return CPListSection(items: [CPListItem(text: "No one to call yet", detailText: "Conversations you can call appear here.")])
        }
        let items: [CPListItem] = rows.map { row in
            let item = CPListItem(text: row.title, detailText: nil, image: avatars[row.conversationId])
            item.handler = { _, completion in onSelect(row); completion() }
            return item
        }
        return CPListSection(items: items)
    }

    /// Contact card with the system Call button (CPContactCallButton). `onCall` starts an AUDIO call (`CallManager.startCall`).
    static func contactTemplate(for row: CarPlayConversations.CallRow, avatar: UIImage,
                                onCall: @escaping () -> Void) -> CPContactTemplate {
        let call = CPContactCallButton(handler: { _ in onCall() })
        let contact = CPContact(name: row.title, image: avatar)
        contact.subtitle = "Haven audio call"
        contact.actions = [call]
        return CPContactTemplate(contact: contact)
    }
}
#endif
