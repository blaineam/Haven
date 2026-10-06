import XCTest

/// The native macOS app, driven through the isolated UI-test host.
///
/// SAFETY: these tests launch `com.blaineam.kith.uitesthost` BY BUNDLE ID — never the default target
/// lookup, and never `com.blaineam.kith`, which is the owner's real account on this Mac (a demo
/// capture under that id overwrote real data once). `-UITestReset` wipes the container of whatever
/// it runs in, and the app refuses to reset anything but a simulator or a `.uitesthost` bundle.
final class HavenMacUITests: XCTestCase {
    static let hostBundleID = "com.blaineam.kith.uitesthost"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIApplication(bundleIdentifier: Self.hostBundleID).terminate()
        super.tearDown()
    }

    private func launch(tab: String = "circle") -> XCUIApplication {
        XCTAssertNotEqual(Self.hostBundleID, "com.blaineam.kith", "never drive the personal app")
        let app = XCUIApplication(bundleIdentifier: Self.hostBundleID)
        app.launchArguments = ["-UITestMode", "-UITestReset"]
        app.launchEnvironment["HAVEN_TAB"] = tab
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "the host should open its window")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func text(_ app: XCUIApplication, containing s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", s, s)).firstMatch
    }

    @discardableResult
    private func wait(_ element: XCUIElement, until format: String, _ args: CVarArg..., timeout: TimeInterval = 20) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    private func scroll(_ app: XCUIApplication, to element: XCUIElement, max: Int = 12) -> Bool {
        var n = 0
        while !(element.exists && element.isHittable) && n < max {
            app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
            n += 1
        }
        return element.waitForExistence(timeout: 5)
    }

    private func type(_ text: String, into field: XCUIElement, replacing: Bool = false) {
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.click()
        if replacing { field.typeKey("a", modifierFlags: .command); field.typeKey(.delete, modifierFlags: []) }
        field.typeText(text)
        XCTAssertTrue(wait(field, until: "value == %@", text, timeout: 5), "the field should hold what was typed, got \(String(describing: field.value))")
    }

    private func back(_ app: XCUIApplication) {
        let back = app.toolbars.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "a pushed screen offers Back")
        back.click()
    }

    private func waitForFeed(_ app: XCUIApplication) {
        let send = element(app, "composeSend")
        XCTAssertTrue(send.waitForExistence(timeout: 60), "the circle feed should show its composer")
        XCTAssertTrue(wait(send, until: "label BEGINSWITH %@", "Post to everyone in "), "got \(send.label)")
    }

    /// The window opens on the seeded circle: the tabs, the composer naming the circle, and the
    /// cast's posts.
    func testMainWindowShowsTabsAndSeededFeed() {
        let app = launch()
        waitForFeed(app)
        for tab in ["Circle", "Messages", "You"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", tab)).firstMatch.exists,
                          "the window should offer the \(tab) tab")
        }
        XCTAssertEqual(element(app, "composeSend").label, "Post to everyone in My Circle")
        // The newest seeded posts lead the feed (the list is lazy, so older ones are not built yet).
        XCTAssertTrue(text(app, containing: "a few from the weekend").waitForExistence(timeout: 20),
                      "Theo's seeded post should lead the feed")
        let theo = app.buttons.matching(identifier: "postAuthor").matching(NSPredicate(format: "label == %@", "Theo Park")).firstMatch
        XCTAssertTrue(theo.exists, "posts name their author")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "storyRing").count, 2, "the story tray shows the cast's stories")
    }

    /// Posting from the composer puts the post in the feed.
    func testPostFromComposer() {
        let app = launch()
        waitForFeed(app)
        type("hello from the mac test", into: element(app, "composeField"))
        element(app, "composeSend").click()
        XCTAssertTrue(text(app, containing: "hello from the mac test").waitForExistence(timeout: 20), "the post should appear")
    }

    /// Messages: the seeded conversation opens and a sent message lands in it.
    func testMessagesThreadAndSend() {
        let app = launch(tab: "messages")
        let theo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Theo Park")).firstMatch
        XCTAssertTrue(theo.waitForExistence(timeout: 60), "the list should show the thread with Theo")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Maya Quinn")).firstMatch.exists,
                      "and the thread with Maya")
        XCTAssertTrue(theo.label.contains("🙌"), "a row previews the latest message, got \(theo.label)")
        theo.click()
        XCTAssertTrue(text(app, containing: "trail conditions look perfect").waitForExistence(timeout: 20))
        type("see you at the trailhead", into: element(app, "dmComposeField"))
        element(app, "dmSend").click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@",
                                                           "see you at the trailhead", "see you at the trailhead"))
                        .firstMatch.waitForExistence(timeout: 20), "the sent message should appear")
    }

    /// You: the seeded profile, and Edit profile changes the bio.
    func testYouProfileAndEditProfileSheet() {
        let app = launch(tab: "you")
        let name = element(app, "youDisplayName")
        XCTAssertTrue(name.waitForExistence(timeout: 60))
        XCTAssertTrue(wait(name, until: "label == %@ OR value == %@", "Riley Avery", "Riley Avery"))

        // The avatar button's hit test misreports on macOS (a .plain button around an overlaid
        // image); click its centre directly.
        element(app, "editProfileButton").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let bio = element(app, "editBio")
        type("potter and plant person", into: bio, replacing: true)
        element(app, "editProfileDone").click()
        XCTAssertTrue(bio.waitForNonExistence(timeout: 10), "Done closes the sheet")
        let shown = element(app, "youBio")
        XCTAssertTrue(wait(shown, until: "label == %@ OR value == %@", "potter and plant person", "potter and plant person"),
                      "the header shows the new bio")
    }

    /// You ▸ Settings: blocked people, relays (with the Add relay sheet), and Advanced's privacy check.
    func testSettingsScreens() {
        let app = launch(tab: "you")
        let gear = element(app, "settingsButton")
        XCTAssertTrue(gear.waitForExistence(timeout: 60))
        gear.click()

        let blocked = app.buttons["Blocked people"].firstMatch
        XCTAssertTrue(scroll(app, to: blocked))
        blocked.click()
        XCTAssertTrue(text(app, containing: "No one's blocked").waitForExistence(timeout: 10))
        back(app)

        let relays = app.buttons["Relays"].firstMatch
        XCTAssertTrue(scroll(app, to: relays))
        relays.click()
        let add = app.buttons["Add relay"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10) || scroll(app, to: add), "Relays should offer Add relay")
        back(app)

        let advanced = app.buttons["Advanced"].firstMatch
        XCTAssertTrue(scroll(app, to: advanced))
        advanced.click()
        let check = element(app, "privacyCheck")
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        check.click()
        XCTAssertTrue(text(app, containing: "checks passed").waitForExistence(timeout: 15), "all on-device checks should pass")
    }

    /// Manage circle lists the demo cast.
    func testCircleSheetListsMembers() {
        let app = launch()
        waitForFeed(app)
        element(app, "circleMembers").click()
        for name in ["Maya", "Theo", "Nina", "Sam"] {
            let row = app.descendants(matching: .any).matching(identifier: "circleMemberName")
                .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", name, name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "the circle sheet should list \(name)")
        }
    }
}
