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

    func testLargeAvatarIsScaledToCarLimit() {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        }
        let scaled = CarPlayTemplates.scaledForCar(big)
        XCTAssertLessThanOrEqual(scaled.size.width, CPMaximumMessageItemImageSize.width)
        XCTAssertLessThanOrEqual(scaled.size.height, CPMaximumMessageItemImageSize.height)
        let section = CarPlayTemplates.section(for: [row("dm:aa")], configured: true, enabled: true, avatars: ["dm:aa": big])
        XCTAssertNotNil((section.items.first as? CPMessageListItem)?.leadingConfiguration.leadingImage)
    }
}
