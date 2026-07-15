import XCTest

/// On-device proof that the hybrid-PQ engine and social feed work, driven through
/// the real (human-friendly) UI. Onboarding is bypassed via an env flag.
final class HavenUITests: XCTestCase {
    private func app(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAVEN_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["HAVEN_TAB"] = tab
        app.launchEnvironment["HAVEN_NO_NET"] = "1"   // don't start the live P2P node in UI tests
        return app
    }

    /// You → Advanced → Run privacy check → all checks pass.
    func testPrivacyCheckPasses() {
        let app = app(tab: "you")
        app.launch()

        let advanced = app.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 15), "Advanced should be reachable")
        advanced.tap()

        let check = app.buttons["privacyCheck"]
        XCTAssertTrue(check.waitForExistence(timeout: 10), "privacy check button should exist")
        check.tap()

        let passed = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "checks passed")
        ).firstMatch
        XCTAssertTrue(passed.waitForExistence(timeout: 10), "all on-device checks should pass")
    }

    /// Posting to the circle feed round-trips through the social engine into the UI.
    func testSocialFeedPostAppears() {
        let app = app(tab: "circle")
        app.launch()

        // The feed starts empty (no fake/seeded content) — share a real post.
        let field = app.textFields["composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("a sealed post from the UI test")
        app.buttons["composeSend"].tap()

        let posted = app.staticTexts["a sealed post from the UI test"]
        XCTAssertTrue(posted.waitForExistence(timeout: 5), "new post should appear in the feed")
    }

    /// The in-call scene's minimize ("back") control must sit INSIDE the safe area, clear of the
    /// status bar and the display's rounded corner. It regressed to x=0/y=54 when the scene's
    /// ZStack ignored the safe area, which zeroed it for every descendant.
    func testCallMinimizeIsInsideSafeArea() {
        let app = app(tab: "circle")
        app.launchEnvironment["HAVEN_DEMO"] = "1"
        app.launchEnvironment["HAVEN_SCENE"] = "call"
        app.launch()

        let minimize = app.buttons["chevron.down"].firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 20), "the call scene should offer a way back")

        let frame = minimize.frame
        XCTAssertGreaterThanOrEqual(frame.minX, 16, "minimize must clear the display's rounded corner")
        XCTAssertGreaterThanOrEqual(frame.minY, 62, "minimize must sit below the status bar / Dynamic Island")

        minimize.tap()
        XCTAssertTrue(minimize.waitForNonExistence(timeout: 5), "minimize should take you back to the app")
    }
}
