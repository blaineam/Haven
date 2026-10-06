import XCTest

/// Manage circle (members, settings, rename) and the full-screen story viewer.
final class CircleAndStoryUITests: HavenUITestCase {

    /// Manage circle lists the whole demo cast; Circle settings renames the circle, and the new
    /// name is what the composer and the circle sheet then show.
    func testCircleSheetListsMembersAndSettingsRenames() {
        let app = launch()
        waitForFeed(app)

        element(app, "circleMembers").tap()
        for name in ["Maya", "Theo", "Nina", "Sam"] {
            let row = app.staticTexts.matching(identifier: "circleMemberName")
                .matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "the circle sheet should list \(name)")
        }
        XCTAssertTrue(app.buttons["Start group call"].firstMatch.isEnabled, "a circle with people can start a call")

        let settings = app.buttons["Circle settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Circle settings"].waitForExistence(timeout: 10))
        let nameField = element(app, "circleNameField")
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertEqual(nameField.value as? String, "My Circle", "the field starts from the circle's name")
        XCTAssertTrue(app.switches.firstMatch.exists, "privacy toggles are offered")
        type("Pottery pals", into: nameField, replacing: true)
        app.keyboards.buttons["Return"].firstMatch.tap()

        goBack(app)   // back to the circle sheet; leaving settings persists the rename
        XCTAssertTrue(app.navigationBars["Pottery pals"].waitForExistence(timeout: 15),
                      "the circle sheet should carry the new name")
        app.swipeDown(velocity: .fast)
        let send = app.buttons["composeSend"]
        XCTAssertTrue(wait(send, until: "label == %@", "Post to everyone in Pottery pals", timeout: 20),
                      "the composer should name the renamed circle, got \(send.label)")
    }

    /// Tapping a story ring opens that person's story full-screen with their name, a reply field
    /// addressed to them, and a close button that returns to the feed.
    func testStoryViewerShowsSharerReplyAndCloses() {
        let app = launch()
        waitForFeed(app)

        let ring = app.buttons.matching(identifier: "storyRing")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Theo")).firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 20), "the stories tray should show Theo's story")
        ring.tap()

        let sharer = element(app, "storySharer")
        XCTAssertTrue(sharer.waitForExistence(timeout: 10))
        XCTAssertTrue(sharer.label.contains("Theo"), "the viewer names the sharer, got \(sharer.label)")
        let reply = element(app, "storyReplyField")
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "someone else's story can be replied to")
        XCTAssertTrue((reply.placeholderValue ?? "").hasPrefix("Reply to Theo"),
                      "the reply field is addressed to the sharer, got \(reply.placeholderValue ?? "nil")")

        element(app, "storyClose").tap()
        XCTAssertTrue(sharer.waitForNonExistence(timeout: 10), "close returns to the feed")
        XCTAssertTrue(app.buttons["composeSend"].waitForExistence(timeout: 10))
    }
}
