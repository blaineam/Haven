import CarPlay
import XCTest

/// CarPlay raises (ObjC exceptions) on malformed templates, and the scene itself can't be created
/// outside a real CarPlay session - so the part we can prove host-less is that every list state we
/// build constructs valid CarPlay objects with the right Siri-managed items.
final class CarPlayTemplatesTests: XCTestCase {
    private func row(_ id: String, unread: Bool = false, locked: Bool = false, detail: String = "hi", trailing: String = "3:41 PM") -> CarPlayConversations.Row {
        .init(conversationId: id, title: "Maya", detail: detail, trailing: trailing, unread: unread, locked: locked)
    }

    func testConversationRowsAreTappableAndOpenTheConversation() {
        var selected: [String] = []
        let mark = CarPlayTemplates.unreadDot(color: .systemPurple)
        let section = CarPlayTemplates.section(for: [row("dm:aa", unread: true), row("dm:bb", detail: "", trailing: "")],
                                               configured: true, enabled: true, unreadMark: mark) { selected.append($0.conversationId) }
        let items = section.items.compactMap { $0 as? CPListItem }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(section.items.allSatisfy { !($0 is CPMessageListItem) }, "no Siri-managed rows: a tap must open the conversation, not jump to 'what would you like to send?'")
        XCTAssertEqual(items[0].detailText, "3:41 PM \u{00B7} hi")
        XCTAssertNotNil(items[0].accessoryImage, "unread dot")
        XCTAssertNil(items[1].accessoryImage)
        XCTAssertNil(items[1].detailText)
        let done = expectation(description: "handler")
        items[1].handler?(items[1], { done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(selected, ["dm:bb"])
        _ = CPListTemplate(title: "Haven", sections: [section])
    }

    func testLockedRowShowsLockedNotText() {
        let section = CarPlayTemplates.section(for: [row("dm:aa", locked: true, detail: "Locked", trailing: "")],
                                               configured: true, enabled: true)
        XCTAssertEqual((section.items.first as? CPListItem)?.detailText, "Locked")
    }

    // MARK: conversation screen

    private func detail(canSpeak: Bool = true, unread: Int = 1, locked: Bool = false, hidden: Bool = false,
                        lines: [CarPlayConversations.Line]? = nil, callable: Bool = true) -> CarPlayConversations.Detail {
        .init(conversationId: "dm:aa", title: "Tracy M", locked: locked,
              lines: lines ?? [.init(id: "m2", text: "On my way", byline: "Tracy \u{00B7} 3:41 PM", unread: true),
                               .init(id: "m1", text: "hey", byline: "You \u{00B7} 3:00 PM", unread: false)],
              unreadCount: unread, canSpeak: canSpeak, textHidden: hidden, callable: callable)
    }

    func testConversationScreenOffersReadReplyCallAndTheMessages() {
        var read = 0, called = 0
        var spoken: [String] = []
        let t = CarPlayTemplates.conversationTemplate(for: detail(), onRead: { read += 1 }, onCall: { called += 1 },
                                                      onSpeak: { spoken.append($0.id) })
        XCTAssertEqual(t.sections.count, 2)
        let actions = t.sections[0].items
        XCTAssertEqual((actions[0] as? CPListItem)?.text, "Read new messages")
        let reply = actions[1] as? CPMessageListItem
        XCTAssertEqual(reply?.conversationIdentifier, "dm:aa", "the reply row is the one Siri-managed item")
        XCTAssertEqual((actions[2] as? CPListItem)?.text, "Call on Haven")
        let messages = t.sections[1].items.compactMap { $0 as? CPListItem }
        XCTAssertEqual(messages.map(\.text), ["On my way", "hey"], "newest first")
        XCTAssertEqual(t.sections[1].header, "Recent messages")
        for item in [actions[0], actions[2], messages[0]].compactMap({ $0 as? CPListItem }) {
            let done = expectation(description: item.text ?? "")
            item.handler?(item, { done.fulfill() })
            wait(for: [done], timeout: 2)
        }
        XCTAssertEqual([read, called, spoken.count], [1, 1, 1])
        XCTAssertEqual(spoken, ["m2"])
    }

    func testConversationScreenReadsToMeWhenNothingIsUnreadAndHidesReadingWhenPrivate() {
        let none = CarPlayTemplates.conversationTemplate(for: detail(unread: 0), onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual((none.sections[0].items[0] as? CPListItem)?.text, "Read to me")
        let hidden = CarPlayTemplates.conversationTemplate(for: detail(canSpeak: false, hidden: true, lines: [], callable: false),
                                                           onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual(hidden.sections[0].items.count, 1, "only the Siri reply row: no read, no call")
        XCTAssertTrue(hidden.sections[0].items[0] is CPMessageListItem)
        XCTAssertEqual((hidden.sections[1].items.first as? CPListItem)?.text, "Message text is hidden by your notification privacy setting.")
    }

    func testLockedConversationScreenShowsOnlyThatItIsLocked() {
        let t = CarPlayTemplates.conversationTemplate(for: detail(locked: true), onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual(t.sections.count, 1)
        XCTAssertEqual(t.sections[0].items.count, 1)
        XCTAssertEqual((t.sections[0].items[0] as? CPListItem)?.text, "Locked")
    }

    func testEmptyUnconfiguredAndDisabledStates() {
        for (rows, configured, enabled, title) in [([], true, true, "No conversations yet"),
                                                   ([], false, true, "Open Haven on your iPhone"),
                                                   ([row("dm:aa")], true, false, "Turned off")] {
            let section = CarPlayTemplates.section(for: rows, configured: configured, enabled: enabled)
            XCTAssertEqual(section.items.count, 1)
            XCTAssertEqual((section.items.first as? CPListItem)?.text, title)
        }
    }

    func testAvatarImageIsPassedThroughUnscaled() {
        let side = CarPlayAvatar.side(max: CPMaximumMessageItemImageSize)
        let img = CarPlayAvatarRenderer.shared.image(for: .initials("TM"), photo: nil, photoStamp: 0, id: "dm:aa",
                                                     side: side, scale: 2, paletteId: "sunset",
                                                     stops: [0x7C3AED, 0xEC4899, 0xF59E0B])
        let section = CarPlayTemplates.section(for: [row("dm:aa")], configured: true, enabled: true, avatars: ["dm:aa": img])
        XCTAssertNotNil((section.items.first as? CPListItem)?.image)
    }

    func testCallsListRowsOpenAContactAndTheContactButtonCalls() {
        let rows = [CarPlayConversations.CallRow(conversationId: "dm:aa", title: "Tracy M")]
        var selected: [String] = []
        let section = CarPlayTemplates.callsSection(for: rows) { selected.append($0.conversationId) }
        let item = section.items.first as? CPListItem
        XCTAssertEqual(item?.text, "Tracy M")
        let done = expectation(description: "handler")
        item?.handler?(item!, { done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(selected, ["dm:aa"], "selecting opens the card; it does not dial")

        var called = 0
        let img = CarPlayAvatarRenderer.shared.image(for: .initials("TM"), photo: nil, photoStamp: 0, id: "dm:aa",
                                                     side: CarPlayAvatar.side(max: CPButtonMaximumImageSize), scale: 2,
                                                     paletteId: "t", stops: [0x7C3AED, 0xEC4899, 0xF59E0B])
        let template = CarPlayTemplates.contactTemplate(for: rows[0], avatar: img) { called += 1 }
        XCTAssertTrue(template.contact.actions?.first is CPContactCallButton, "the system Call button")
        XCTAssertEqual(template.contact.name, "Tracy M")
        XCTAssertEqual(called, 0, "building the card never dials")
    }

    func testEmptyCallsListHasAnExplanation() {
        let section = CarPlayTemplates.callsSection(for: []) { _ in }
        XCTAssertEqual((section.items.first as? CPListItem)?.text, "No one to call yet")
    }
}
