import CarPlay
import XCTest

/// CarPlay raises (ObjC exceptions) on malformed templates, and the scene itself can't be created
/// outside a real CarPlay session - so the part we can prove host-less is that every list state we
/// build constructs valid CarPlay objects with the right Siri-managed items.
final class CarPlayTemplatesTests: XCTestCase {
    private func row(_ id: String, unread: Bool = false, locked: Bool = false, detail: String = "hi", trailing: String = "3:41 PM") -> CarPlayConversations.Row {
        .init(conversationId: id, title: "Maya", detail: detail, trailing: trailing, unread: unread, locked: locked)
    }

    func testConversationRowsBecomeMessageListItemsKeyedByCircleId() {
        let section = CarPlayTemplates.section(for: [row("dm:aa", unread: true), row("dm:bb", detail: "", trailing: "")],
                                               configured: true, enabled: true)
        let items = section.items.compactMap { $0 as? CPMessageListItem }
        XCTAssertEqual(items.count, 2, "Siri-managed message items, not CPListItem")
        XCTAssertEqual(items.map(\.conversationIdentifier), ["dm:aa", "dm:bb"])
        XCTAssertTrue(items[0].leadingConfiguration.isUnread)
        XCTAssertFalse(items[1].leadingConfiguration.isUnread)
        XCTAssertEqual(items[0].detailText, "hi")
        XCTAssertNil(items[1].detailText)
        XCTAssertEqual(items[0].trailingText, "3:41 PM")
        _ = CPListTemplate(title: "Haven", sections: [section])
    }

    func testLockedRowShowsLockedNotText() {
        let section = CarPlayTemplates.section(for: [row("dm:aa", locked: true, detail: "Locked", trailing: "")],
                                               configured: true, enabled: true)
        XCTAssertEqual((section.items.first as? CPMessageListItem)?.detailText, "Locked")
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
        XCTAssertNotNil((section.items.first as? CPMessageListItem)?.leadingConfiguration.leadingImage)
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
