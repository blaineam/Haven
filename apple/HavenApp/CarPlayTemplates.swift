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
                        mode: CarPlayDriveMode = .parked,
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
            let detail = rowDetail(row, mode: mode)
            let item = CPListItem(text: row.title, detailText: detail.isEmpty ? nil : detail,
                                  image: avatars[row.conversationId],
                                  accessoryImage: row.unread ? unreadMark : nil,
                                  accessoryType: row.unread ? .none : .disclosureIndicator)
            item.handler = { _, completion in onSelect(row); completion() }
            return item
        }
        return CPListSection(items: items)
    }

    /// The row's subtitle. Parked: time and the message preview. Driving: never message text - just the
    /// unread count (a locked thread keeps its own "Locked" label).
    static func rowDetail(_ row: CarPlayConversations.Row, mode: CarPlayDriveMode) -> String {
        switch mode {
        case .parked:
            return [row.trailing, row.detail].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        case .driving:
            if row.locked { return row.detail }
            return row.unreadCount > 0 ? MessagingText.unreadCount(row.unreadCount) : ""
        }
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

    /// The pieces of a conversation screen, built apart from the template so a live refresh can swap the
    /// sections AND the nav-bar buttons of the template already on screen.
    struct ConversationScreen {
        var sections: [CPListSection]
        var buttons: [CPBarButton]
        /// What each button does, by title, so the wiring can be exercised without a car (a
        /// `CPBarButton` does not expose its handler).
        var actions: [(title: String, run: () -> Void)] = []
    }

    /// Icons the screen may draw. All optional: a missing one just leaves the row without an image.
    struct ConversationArt {
        var theirAvatar: UIImage? = nil
        var theirBubble: UIImage? = nil
        var myBubble: UIImage? = nil
        var unreadMark: UIImage? = nil
        var replyIcon: UIImage? = nil
    }

    /// A chat-bubble glyph for a message row: a left bubble in a neutral grey for what they said, a right
    /// bubble in the palette tint for what you said. CarPlay draws list rows itself (no custom views, no
    /// free-form bubbles), so this small leading image is as close to a bubble as the platform allows.
    static func bubbleIcon(mine: Bool, tint: UIColor, side: CGFloat? = nil) -> UIImage {
        let edge = side ?? max(24, min(CPListItem.maximumImageSize.width, CPListItem.maximumImageSize.height))
        let size = CGSize(width: edge, height: edge)
        let color = mine ? tint : UIColor(white: 0.58, alpha: 1)
        let config = UIImage.SymbolConfiguration(pointSize: edge * 0.74, weight: .regular)
        let glyph = UIImage(systemName: mine ? "bubble.right.fill" : "bubble.left.fill", withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { _ in
            if let glyph {
                let r = CGRect(x: (edge - glyph.size.width) / 2, y: (edge - glyph.size.height) / 2,
                               width: glyph.size.width, height: glyph.size.height)
                glyph.draw(in: r)
            } else {
                color.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 4), cornerRadius: edge * 0.3).fill()
            }
        }
    }

    /// A tinted SF Symbol, sized to fit CarPlay's message-item image limit.
    static func glyph(_ systemName: String, tint: UIColor, side: CGFloat? = nil) -> UIImage {
        let edge = side ?? max(24, min(CPMaximumMessageItemImageSize.width, CPMaximumMessageItemImageSize.height))
        let config = UIImage.SymbolConfiguration(pointSize: edge * 0.7, weight: .semibold)
        let image = UIImage(systemName: systemName, withConfiguration: config)?.withTintColor(tint, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge)).image { _ in
            guard let image else { return }
            image.draw(in: CGRect(x: (edge - image.size.width) / 2, y: (edge - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    /// What tapping a conversation shows.
    ///   * PARKED: the recent messages in chat order (oldest first, so the newest sits right above the
    ///     composer), each with a bubble glyph (them left/grey, you right/tinted), then the "Reply" row.
    ///     A message row reads THAT message aloud. "Read to me" and "Call" are buttons in the navigation
    ///     bar - CarPlay lists have no footer or in-list buttons, and the nav bar is the only place an app
    ///     gets real buttons on a list.
    ///   * DRIVING (the car reports a UI limit): no message text at all - a short "hidden while driving"
    ///     line and the same Reply row and buttons.
    /// A locked conversation shows only that it is locked; a privacy setting that hides text says why.
    static func conversationScreen(for detail: CarPlayConversations.Detail,
                                   mode: CarPlayDriveMode = .parked,
                                   art: ConversationArt = ConversationArt(),
                                   onRead: @escaping () -> Void,
                                   onCall: @escaping () -> Void,
                                   onSpeak: @escaping (CarPlayConversations.Line) -> Void) -> ConversationScreen {
        if detail.locked {
            let item = CPListItem(text: MessagingText.locked, detailText: MessagingText.lockedHint)
            return ConversationScreen(sections: [CPListSection(items: [item])], buttons: [], actions: [])
        }
        var actions: [(title: String, run: () -> Void)] = []
        if detail.canSpeak { actions.append((detail.unreadCount > 0 ? MessagingText.readNewShort : MessagingText.readToMe, onRead)) }
        if detail.callable { actions.append((MessagingText.callShort, onCall)) }
        let buttons: [CPBarButton] = actions.map { action in
            let button = CPBarButton(title: action.title) { _ in action.run() }
            button.buttonStyle = .rounded
            return button
        }
        // The one Siri-managed item: tapping it hands the conversation to Siri to take a reply (and to
        // read any unread messages first).
        let reply = CPMessageListItem(conversationIdentifier: detail.conversationId,
                                      text: MessagingText.reply,
                                      leadingConfiguration: CPMessageListItemLeadingConfiguration(leadingItem: .none, leadingImage: art.replyIcon, unread: false),
                                      trailingConfiguration: nil,
                                      detailText: MessagingText.replyHint, trailingText: nil)
        var sections: [CPListSection] = []
        switch mode {
        case .driving:
            let hint = detail.canSpeak ? MessagingText.hiddenWhileDrivingHint : MessagingText.hiddenWhileDrivingHintNoRead
            sections.append(CPListSection(items: [CPListItem(text: MessagingText.hiddenWhileDriving, detailText: hint)]))
        case .parked:
            var lines: [CPListItem] = detail.lines.reversed().map { line in
                let image = line.mine ? art.myBubble : (art.theirAvatar ?? art.theirBubble)
                let item = CPListItem(text: line.text, detailText: line.byline, image: image,
                                      accessoryImage: line.unread ? art.unreadMark : nil, accessoryType: .none)
                if detail.canSpeak { item.handler = { _, completion in onSpeak(line); completion() } }
                return item
            }
            if lines.isEmpty {
                lines = [CPListItem(text: detail.textHidden ? MessagingText.hiddenHint : MessagingText.noMessagesYet, detailText: nil)]
            }
            sections.append(CPListSection(items: lines))
        }
        sections.append(CPListSection(items: [reply]))
        return ConversationScreen(sections: sections, buttons: buttons, actions: actions)
    }

    static func conversationTemplate(for detail: CarPlayConversations.Detail,
                                     mode: CarPlayDriveMode = .parked,
                                     art: ConversationArt = ConversationArt(),
                                     onRead: @escaping () -> Void,
                                     onCall: @escaping () -> Void,
                                     onSpeak: @escaping (CarPlayConversations.Line) -> Void) -> CPListTemplate {
        let screen = conversationScreen(for: detail, mode: mode, art: art, onRead: onRead, onCall: onCall, onSpeak: onSpeak)
        let template = CPListTemplate(title: detail.title, sections: screen.sections)
        template.trailingNavigationBarButtons = screen.buttons
        return template
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
