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
                               .init(id: "m1", text: "hey", byline: "You \u{00B7} 3:00 PM", unread: false, mine: true)],
              unreadCount: unread, canSpeak: canSpeak, textHidden: hidden, callable: callable)
    }

    private func fire(_ item: CPListItem) {
        let done = expectation(description: item.text ?? "")
        item.handler?(item, { done.fulfill() })
        wait(for: [done], timeout: 2)
    }

    func testParkedConversationShowsChatOrderMessagesThenTheSiriReplyRow() {
        var spoken: [String] = []
        let t = CarPlayTemplates.conversationTemplate(for: detail(), mode: .parked, onRead: {}, onCall: {},
                                                      onSpeak: { spoken.append($0.id) })
        XCTAssertEqual(t.sections.count, 2, "messages, then the composer row")
        let messages = t.sections[0].items.compactMap { $0 as? CPListItem }
        XCTAssertEqual(messages.map(\.text), ["hey", "On my way"], "oldest first: the newest sits right above Reply")
        XCTAssertEqual(messages.map(\.detailText), ["You \u{00B7} 3:00 PM", "Tracy \u{00B7} 3:41 PM"])
        let reply = t.sections[1].items.first as? CPMessageListItem
        XCTAssertEqual(t.sections[1].items.count, 1)
        XCTAssertEqual(reply?.conversationIdentifier, "dm:aa", "the reply row is the one Siri-managed item")
        XCTAssertEqual(reply?.text, "Reply")
        fire(messages[1])
        XCTAssertEqual(spoken, ["m2"], "a message row reads that message")
    }

    func testBubbleArtDistinguishesMineFromTheirs() {
        let tint = UIColor.systemPurple
        let mine = CarPlayTemplates.bubbleIcon(mine: true, tint: tint)
        let theirs = CarPlayTemplates.bubbleIcon(mine: false, tint: tint)
        XCTAssertGreaterThan(mine.size.width, 0)
        XCTAssertNotEqual(mine.pngData(), theirs.pngData(), "right/tinted vs left/grey bubble")
        let avatar = CarPlayTemplates.bubbleIcon(mine: false, tint: tint, side: 30)
        let art = CarPlayTemplates.ConversationArt(theirAvatar: avatar, theirBubble: theirs, myBubble: mine)
        let t = CarPlayTemplates.conversationTemplate(for: detail(), art: art, onRead: {}, onCall: {}, onSpeak: { _ in })
        let items = t.sections[0].items.compactMap { $0 as? CPListItem }
        XCTAssertNotNil(items[0].image, "my message carries the right bubble")
        XCTAssertNotNil(items[1].image, "their message carries their avatar")
    }

    func testReadAndCallAreNavBarButtons() {
        var read = 0, called = 0
        let screen = CarPlayTemplates.conversationScreen(for: detail(), onRead: { read += 1 }, onCall: { called += 1 }, onSpeak: { _ in })
        XCTAssertEqual(screen.buttons.map(\.title), ["Read new", "Call"])
        XCTAssertEqual(screen.actions.map(\.title), ["Read new", "Call"])
        XCTAssertLessThanOrEqual(screen.buttons.count, 2, "the nav bar shows at most two")
        screen.actions.forEach { $0.run() }
        XCTAssertEqual([read, called], [1, 1])
        let t = CarPlayTemplates.conversationTemplate(for: detail(), onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual(t.trailingNavigationBarButtons.map(\.title), ["Read new", "Call"])
        let none = CarPlayTemplates.conversationTemplate(for: detail(unread: 0), onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual(none.trailingNavigationBarButtons.first?.title, "Read to me")
    }

    func testDrivingConversationShowsNoMessageTextOnlyTheActions() {
        var read = 0
        let screen = CarPlayTemplates.conversationScreen(for: detail(), mode: .driving, onRead: { read += 1 }, onCall: {}, onSpeak: { _ in })
        let t = CarPlayTemplates.conversationTemplate(for: detail(), mode: .driving, onRead: {}, onCall: {}, onSpeak: { _ in })
        let texts = t.sections.flatMap(\.items).compactMap { ($0 as? CPListItem).map { [$0.text, $0.detailText].compactMap { $0 } } }.flatMap { $0 }
        XCTAssertFalse(texts.contains { $0.contains("On my way") || $0.contains("hey") }, "no message text while driving")
        XCTAssertEqual(t.sections[0].items.count, 1)
        XCTAssertEqual((t.sections[0].items[0] as? CPListItem)?.text, "Messages are hidden while driving")
        XCTAssertEqual((t.sections[0].items[0] as? CPListItem)?.detailText, "Park to read them, or tap Read to me.")
        XCTAssertTrue(t.sections.last?.items.first is CPMessageListItem, "Reply stays available")
        XCTAssertEqual(t.trailingNavigationBarButtons.map(\.title), ["Read new", "Call"])
        screen.actions.first?.run()
        XCTAssertEqual(read, 1, "Read to me still works while driving")
        let hiddenText = CarPlayTemplates.conversationTemplate(for: detail(canSpeak: false, hidden: true, lines: [], callable: false), mode: .driving,
                                                               onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual((hiddenText.sections[0].items[0] as? CPListItem)?.detailText, "Park to see them.")
        XCTAssertTrue(hiddenText.trailingNavigationBarButtons.isEmpty)
    }

    func testDriveModeFromLimits() {
        XCTAssertEqual(CarPlayDriveMode.mode(limitsActive: false), .parked)
        XCTAssertEqual(CarPlayDriveMode.mode(limitsActive: true), .driving)
        XCTAssertEqual(CarPlayDriveMode.mode(for: []), .parked, "a car that never reports a limit looks parked")
        XCTAssertEqual(CarPlayDriveMode.mode(for: .lists), .driving)
        XCTAssertEqual(CarPlayDriveMode.mode(for: .keyboard), .driving)
        XCTAssertEqual(CarPlayDriveMode.mode(for: [.lists, .keyboard]), .driving)
        XCTAssertTrue(CarPlayDriveMode.parked.showsMessageText)
        XCTAssertFalse(CarPlayDriveMode.driving.showsMessageText)
    }

    func testMessagesTabRowsShowNamesAndUnreadCountsOnlyWhileDriving() {
        let unreadRow = CarPlayConversations.Row(conversationId: "dm:aa", title: "Maya", detail: "On my way", trailing: "3:41 PM",
                                                 unread: true, locked: false, unreadCount: 3)
        let readRow = CarPlayConversations.Row(conversationId: "dm:bb", title: "Sam", detail: "see you", trailing: "2:00 PM",
                                               unread: false, locked: false, unreadCount: 0)
        let locked = CarPlayConversations.Row(conversationId: "dm:cc", title: "Locked chat", detail: "Locked", trailing: "",
                                              unread: false, locked: true)
        XCTAssertEqual(CarPlayTemplates.rowDetail(unreadRow, mode: .parked), "3:41 PM \u{00B7} On my way")
        XCTAssertEqual(CarPlayTemplates.rowDetail(unreadRow, mode: .driving), "3 unread")
        XCTAssertEqual(CarPlayTemplates.rowDetail(readRow, mode: .driving), "")
        XCTAssertEqual(CarPlayTemplates.rowDetail(locked, mode: .driving), "Locked")
        let section = CarPlayTemplates.section(for: [unreadRow, readRow], configured: true, enabled: true, mode: .driving)
        let items = section.items.compactMap { $0 as? CPListItem }
        XCTAssertEqual(items.map(\.text), ["Maya", "Sam"], "names stay")
        XCTAssertEqual(items.map(\.detailText), ["3 unread", nil])
        XCTAssertFalse(items.contains { ($0.detailText ?? "").contains("On my way") })
    }

    func testConversationScreenReadsToMeWhenNothingIsUnreadAndHidesReadingWhenPrivate() {
        let hidden = CarPlayTemplates.conversationTemplate(for: detail(canSpeak: false, hidden: true, lines: [], callable: false),
                                                           onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertTrue(hidden.trailingNavigationBarButtons.isEmpty, "no read, no call")
        XCTAssertEqual((hidden.sections[0].items.first as? CPListItem)?.text, "Message text is hidden by your notification privacy setting.")
        XCTAssertTrue(hidden.sections[1].items[0] is CPMessageListItem, "only the Siri reply row remains")
    }

    func testLockedConversationScreenShowsOnlyThatItIsLocked() {
        let t = CarPlayTemplates.conversationTemplate(for: detail(locked: true), onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual(t.sections.count, 1)
        XCTAssertEqual(t.sections[0].items.count, 1)
        XCTAssertEqual((t.sections[0].items[0] as? CPListItem)?.text, "Locked")
        XCTAssertTrue(t.trailingNavigationBarButtons.isEmpty)
        let driving = CarPlayTemplates.conversationTemplate(for: detail(locked: true), mode: .driving, onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual((driving.sections[0].items[0] as? CPListItem)?.text, "Locked")
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
