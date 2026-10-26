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

    static func scaledForCar(_ image: UIImage) -> UIImage {
        let max = CPMaximumMessageItemImageSize
        let scale = min(max.width / image.size.width, max.height / image.size.height, 1)
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
