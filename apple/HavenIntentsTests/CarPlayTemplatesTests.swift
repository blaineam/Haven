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
                                               configured: true, enabled: true, unreadMark: mark, onSelect: { selected.append($0.conversationId) })
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

    func testNavBarIconsAndTintAndOwnAvatar() {
        XCTAssertNotNil(CarPlayTemplates.barIcon("phone.fill"))
        XCTAssertNotNil(CarPlayTemplates.barIcon(CarPlayTemplates.readSymbol))
        XCTAssertNotNil(CarPlayTemplates.barIcon(CarPlayTemplates.readUnreadSymbol), "the badge variant exists on this OS")
        func rgb(_ c: UIColor) -> [Int] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b].map { Int(($0 * 255).rounded()) }
        }
        XCTAssertEqual(rgb(CarPlayTemplates.tintColor(stops: [0x404040, 0x737373, 0xA3A3A3])), [0x73, 0x73, 0x73], "Neutral: grey")
        XCTAssertEqual(rgb(CarPlayTemplates.tintColor(stops: [0x7C3AED, 0xEC4899, 0xF59E0B])), [0xEC, 0x48, 0x99], "Sunset: its pink")
        XCTAssertEqual(rgb(CarPlayTemplates.tintColor(stops: [0x2563EB, 0x06B6D4, 0x14B8A6])), [0x06, 0xB6, 0xD4], "Ocean follows the choice")
        // My rows prefer my own picture; the tinted bubble is only the fallback.
        let me = CarPlayTemplates.bubbleIcon(mine: true, tint: .systemTeal, side: 30)
        let photo = CarPlayTemplates.glyph("person.fill", tint: .systemOrange, side: 30)
        let withPhoto = CarPlayTemplates.conversationScreen(
            for: detail(), art: .init(myBubble: me, myAvatar: photo), onRead: {}, onCall: {}, onSpeak: { _ in })
        let withoutPhoto = CarPlayTemplates.conversationScreen(
            for: detail(), art: .init(myBubble: me), onRead: {}, onCall: {}, onSpeak: { _ in })
        func myRowImage(_ s: CarPlayTemplates.ConversationScreen) -> Data? {
            (s.sections[0].items.compactMap { $0 as? CPListItem }.first)?.image?.pngData()
        }
        XCTAssertEqual(myRowImage(withPhoto), photo.pngData(), "my own picture on my message")
        XCTAssertEqual(myRowImage(withoutPhoto), me.pngData(), "no profile data -> the bubble")
    }

    func testReadAndCallAreNavBarButtons() {
        var read = 0, called = 0
        let screen = CarPlayTemplates.conversationScreen(for: detail(), onRead: { read += 1 }, onCall: { called += 1 }, onSpeak: { _ in })
        XCTAssertEqual(screen.actions.map(\.title), ["Read new", "Call"], "what each button is called")
        XCTAssertEqual(screen.symbols, [CarPlayTemplates.readUnreadSymbol, CarPlayTemplates.callSymbol])
        XCTAssertTrue(screen.buttons.allSatisfy { $0.image != nil }, "icon buttons: a speaker and a handset")
        XCTAssertLessThanOrEqual(screen.buttons.count, 2, "the nav bar shows at most two")
        screen.actions.forEach { $0.run() }
        XCTAssertEqual([read, called], [1, 1])
        let t = CarPlayTemplates.conversationTemplate(for: detail(), onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual(t.trailingNavigationBarButtons.count, 2)
        let none = CarPlayTemplates.conversationScreen(for: detail(unread: 0), onRead: {}, onCall: {}, onSpeak: { _ in })
        XCTAssertEqual(none.actions.first?.title, "Read to me")
        XCTAssertEqual(none.symbols.first, CarPlayTemplates.readSymbol, "no unread -> the plain speaker")
        XCTAssertNotNil(none.buttons.first?.image)
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
        XCTAssertEqual(screen.actions.map(\.title), ["Read new", "Call"])
        XCTAssertEqual(t.trailingNavigationBarButtons.count, 2, "the read and call icon buttons stay while driving")
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
        let texts = section.items.map { ($0 as? CPListItem)?.text ?? ($0 as? CPMessageListItem)?.text }
        XCTAssertEqual(texts, ["Maya", "Sam"], "names stay")
        let details = section.items.map { ($0 as? CPListItem)?.detailText ?? ($0 as? CPMessageListItem)?.detailText }
        XCTAssertEqual(details.first ?? nil, "3 unread")
        XCTAssertFalse(details.contains { ($0 ?? "").contains("On my way") || ($0 ?? "").contains("see you") })
    }

    // MARK: driving-mode tap (no menu)

    private func drivingRow(_ id: String, unreadCount: Int = 0, locked: Bool = false) -> CarPlayConversations.Row {
        .init(conversationId: id, title: "Maya", detail: locked ? "Locked" : "secret text", trailing: "3:41 PM",
              unread: unreadCount > 0, locked: locked, unreadCount: unreadCount)
    }

    func testDrivingTapDecision() {
        typealias T = CarPlayTemplates
        XCTAssertEqual(T.drivingTap(for: drivingRow("a", unreadCount: 2), canSpeak: true), .read, "unread + speakable -> read aloud")
        XCTAssertEqual(T.drivingTap(for: drivingRow("a", unreadCount: 2), canSpeak: false), .compose, "privacy forbids speaking -> Siri compose")
        XCTAssertEqual(T.drivingTap(for: drivingRow("a"), canSpeak: true), .compose, "nothing unread -> Siri compose")
        XCTAssertEqual(T.drivingTap(for: drivingRow("a"), canSpeak: false), .compose)
        XCTAssertEqual(T.drivingTap(for: drivingRow("a", locked: true), canSpeak: true), .none, "locked never reads or opens")
        XCTAssertEqual(T.drivingTap(for: drivingRow("a", unreadCount: 0, locked: true), canSpeak: false), .none)
    }

    func testDrivingRowsReadComposeOrDoNothingAndNeverOpenTheMenu() {
        var opened: [String] = [], read: [String] = []
        let section = CarPlayTemplates.section(
            for: [drivingRow("dm:unread", unreadCount: 2), drivingRow("dm:read"), drivingRow("dm:lock", locked: true)],
            configured: true, enabled: true, mode: .driving, canSpeak: true,
            onSelect: { opened.append($0.conversationId) }, onRead: { read.append($0.conversationId) })
        XCTAssertEqual(section.items.count, 3)
        let unread = section.items[0] as? CPListItem
        XCTAssertEqual(unread?.detailText, "2 unread")
        XCTAssertNil(unread.flatMap { $0.detailText?.range(of: "secret") }, "no message text while driving")
        fire(unread!)
        XCTAssertEqual(read, ["dm:unread"], "an unread row reads aloud")
        let compose = section.items[1] as? CPMessageListItem
        XCTAssertNotNil(compose, "a read conversation is the Siri-managed row: tap = 'what would you like to say?'")
        XCTAssertEqual(compose?.conversationIdentifier, "dm:read")
        XCTAssertNil(compose?.detailText)
        let locked = section.items[2] as? CPListItem
        XCTAssertNil(locked?.accessoryImage)
        XCTAssertEqual(locked?.detailText, "Locked")
        fire(locked!)
        XCTAssertEqual(read, ["dm:unread"], "a locked row never reads")
        XCTAssertTrue(opened.isEmpty, "no row opens the conversation menu while driving")
        _ = CPListTemplate(title: "Haven", sections: [section])
    }

    func testDrivingUnreadRowWithPrivacyHidingTextFallsBackToSiriCompose() {
        let section = CarPlayTemplates.section(for: [drivingRow("dm:aa", unreadCount: 1)], configured: true, enabled: true,
                                               mode: .driving, canSpeak: false)
        XCTAssertTrue(section.items.first is CPMessageListItem)
    }

    func testParkedRowsStillOpenTheConversationScreen() {
        var opened: [String] = [], read: [String] = []
        let section = CarPlayTemplates.section(for: [drivingRow("dm:aa", unreadCount: 2)], configured: true, enabled: true,
                                               mode: .parked, onSelect: { opened.append($0.conversationId) }, onRead: { read.append($0.conversationId) })
        fire(section.items[0] as! CPListItem)
        XCTAssertEqual(opened, ["dm:aa"])
        XCTAssertTrue(read.isEmpty)
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

    func testCallsListRowsDialDirectlyWithNoContactCard() {
        let rows = [CarPlayConversations.CallRow(conversationId: "dm:aa", title: "Tracy M")]
        var selected: [String] = []
        let section = CarPlayTemplates.callsSection(for: rows) { selected.append($0.conversationId) }
        let item = section.items.first as? CPListItem
        XCTAssertEqual(item?.text, "Tracy M")
        let done = expectation(description: "handler")
        item?.handler?(item!, { done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(selected, ["dm:aa"], "selecting is the dial action itself - no template is pushed in between")
        XCTAssertEqual(item?.detailText, MessagingText.audioCall)
    }

    func testEmptyCallsListHasAnExplanation() {
        let section = CarPlayTemplates.callsSection(for: []) { _ in }
        XCTAssertEqual((section.items.first as? CPListItem)?.text, "No one to call yet")
    }
}
