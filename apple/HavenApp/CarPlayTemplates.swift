#if os(iOS)
import CarPlay
import UIKit

/// Builds the CarPlay list sections from `CarPlayConversations.Row`s. Separate from the scene delegate
/// (which needs the live app stores) so the template construction - where CarPlay raises on a bad
/// argument - is exercised by a host-less test (`CarPlayTemplatesTests`).
enum CarPlayTemplates {
    /// The Messages tab. Rows are plain `CPListItem`s (not Siri-managed `CPMessageListItem`s): a tap opens
    /// the conversation screen (`conversationTemplate`) where the messages can be read aloud or seen, a
    /// reply started and the person called. A Siri-managed row can only ever read-then-reply, which is
    /// what made every tap end at "what would you like to send?".
    static func section(for rows: [CarPlayConversations.Row], configured: Bool, enabled: Bool,
                        avatars: [String: UIImage] = [:], unreadMark: UIImage? = nil,
                        onSelect: @escaping (CarPlayConversations.Row) -> Void = { _ in }) -> CPListSection {
        if !enabled {
            return CPListSection(items: [CPListItem(text: MessagingText.turnedOff, detailText: MessagingText.turnedOffHint)])
        }
        if !configured {
            return CPListSection(items: [CPListItem(text: MessagingText.openOnPhone, detailText: MessagingText.openOnPhoneHint)])
        }
        if rows.isEmpty {
            return CPListSection(items: [CPListItem(text: MessagingText.noConversations, detailText: MessagingText.noConversationsHint)])
        }
        let items: [CPListItem] = rows.map { row in
            let detail = [row.trailing, row.detail].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            let item = CPListItem(text: row.title, detailText: detail.isEmpty ? nil : detail,
                                  image: avatars[row.conversationId],
                                  accessoryImage: row.unread ? unreadMark : nil,
                                  accessoryType: row.unread ? .none : .disclosureIndicator)
            item.handler = { _, completion in onSelect(row); completion() }
            return item
        }
        return CPListSection(items: items)
    }

    /// A filled dot for the unread accessory.
    static func unreadDot(color: UIColor, side: CGFloat = 14) -> UIImage {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
    }

    // MARK: Conversation screen

    /// What tapping a conversation shows. Top section = the actions (hear it, reply, call); below it the
    /// recent messages, newest first. A message row reads THAT message aloud. A locked conversation shows
    /// only that it is locked; a privacy setting that hides text shows the capped preview lines and says why.
    static func conversationTemplate(for detail: CarPlayConversations.Detail,
                                     onRead: @escaping () -> Void,
                                     onCall: @escaping () -> Void,
                                     onSpeak: @escaping (CarPlayConversations.Line) -> Void) -> CPListTemplate {
        if detail.locked {
            let item = CPListItem(text: MessagingText.locked, detailText: MessagingText.lockedHint)
            return CPListTemplate(title: detail.title, sections: [CPListSection(items: [item])])
        }
        var actions: [CPListTemplateItem] = []
        if detail.canSpeak {
            let read = CPListItem(text: detail.unreadCount > 0 ? MessagingText.readNew : MessagingText.readToMe,
                                  detailText: MessagingText.readHint,
                                  image: UIImage(systemName: "speaker.wave.2.fill"))
            read.handler = { _, completion in onRead(); completion() }
            actions.append(read)
        }
        // The one Siri-managed item: tapping it hands the conversation to Siri to take a reply (and to
        // read any unread messages first).
        actions.append(CPMessageListItem(conversationIdentifier: detail.conversationId,
                                         text: MessagingText.reply,
                                         leadingConfiguration: CPMessageListItemLeadingConfiguration(leadingItem: .none, leadingImage: nil, unread: false),
                                         trailingConfiguration: nil,
                                         detailText: MessagingText.replyHint, trailingText: nil))
        if detail.callable {
            let call = CPListItem(text: MessagingText.callOnHaven, detailText: MessagingText.audioCall,
                                  image: UIImage(systemName: "phone.fill"))
            call.handler = { _, completion in onCall(); completion() }
            actions.append(call)
        }
        var sections = [CPListSection(items: actions)]
        var lines: [CPListItem] = detail.lines.map { line in
            let item = CPListItem(text: line.text, detailText: line.byline)
            if detail.canSpeak { item.handler = { _, completion in onSpeak(line); completion() } }
            return item
        }
        if lines.isEmpty {
            lines = [CPListItem(text: detail.textHidden ? MessagingText.hiddenHint : MessagingText.noMessagesYet, detailText: nil)]
        }
        sections.append(CPListSection(items: lines, header: MessagingText.recentMessages, sectionIndexTitle: nil))
        return CPListTemplate(title: detail.title, sections: sections)
    }

    // MARK: Calls

    /// The Calls tab list. A row opens a contact card (never dials on the first tap - an accidental
    /// touch on a dashboard must not ring someone).
    static func callsSection(for rows: [CarPlayConversations.CallRow], avatars: [String: UIImage] = [:],
                             onSelect: @escaping (CarPlayConversations.CallRow) -> Void) -> CPListSection {
        guard !rows.isEmpty else {
            return CPListSection(items: [CPListItem(text: MessagingText.noOneToCall, detailText: MessagingText.noOneToCallHint)])
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
        contact.subtitle = MessagingText.audioCall
        contact.actions = [call]
        return CPContactTemplate(contact: contact)
    }
}
#endif
