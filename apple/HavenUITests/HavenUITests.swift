import XCTest

/// On-device proof that the hybrid-PQ engine and social feed work, driven through
/// the real (human-friendly) UI. Onboarding is bypassed via an env flag.
///
/// These tests exercise the REAL keychain-backed identity, so they must run against a **signed**
/// simulator build. An unsigned build (`CODE_SIGNING_ALLOWED=NO`) has no keychain entitlement, so
/// the data-protection keychain read fails with `errSecMissingEntitlement`, `AccountStore` treats it
/// as "locked" and never persists a master seed, and `FeedStore.configureForCurrentIdentity()` then
/// creates no social engine at all — leaving an empty, offline feed with nothing to drive. Run with
/// a development team (e.g. `-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic
/// DEVELOPMENT_TEAM=<team>`), not `CODE_SIGNING_ALLOWED=NO`.
final class HavenUITests: XCTestCase {
    private func app(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAVEN_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["HAVEN_TAB"] = tab
        // Hermetic: no iroh node, no relay HTTP, no Multipeer, no push, no S3 (see `HavenNet`).
        // This used to gate only the node, so a simulator holding relay records from a real run
        // still greeted the world over HTTP — and a stranger's inbound hello could raise a live
        // connection request in the middle of a test. These tests drive local state only.
        app.launchEnvironment["HAVEN_NO_NET"] = "1"
        return app
    }

    /// You → Settings → Advanced → Run privacy check → all checks pass.
    func testPrivacyCheckPasses() {
        let app = app(tab: "you")
        app.launch()

        // The technical surface (identity, privacy check, "start over") moved off the You tab into
        // You ▸ Settings (the gear) ▸ Advanced. Walk that path. The gear's accessibility label is
        // "Settings" (it overrides the SF Symbol name).
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings should be reachable from You")
        settings.tap()

        // "Advanced" is the last section of a long grouped Form, so it starts below the fold — a
        // lazy List/Form doesn't put off-screen rows in the accessibility tree until they scroll in.
        // Scroll until it materializes rather than assuming it's already realized.
        let advanced = app.buttons["Advanced"].firstMatch
        var scrolls = 0
        while !advanced.exists && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), "Advanced should be reachable in Settings")
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
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("a sealed post from the UI test")
        app.buttons["composeSend"].tap()

        let posted = app.staticTexts["a sealed post from the UI test"]
        XCTAssertTrue(posted.waitForExistence(timeout: 10), "new post should appear in the feed")
    }

    /// Tapping "add friend" in the Circle header must open the invite sheet — promptly, and
    /// without taking the app down with it.
    ///
    /// This is the test that was missing when 1.8.4 shipped: the sheet's body computed the invite
    /// link inline, which minted a post-quantum invite ticket and rendered a QR image on the MAIN
    /// thread, on every body evaluation. On a device with relays that is seconds of freeze and then
    /// the watchdog, which reads to a person as "the add friend button crashes the app".
    ///
    /// The assertions are deliberately about time as well as existence: a sheet that eventually
    /// appears after ten seconds is the bug, not a pass. `HAVEN_DEMO` seeds relays, so the ticket
    /// path this exercises is the one a real account takes.
    func testAddFriendOpensTheInviteSheetWithoutFreezing() {
        let app = app(tab: "circle")
        app.launchEnvironment["HAVEN_DEMO"] = "1"
        app.launch()

        // Circle ▸ manage circle ▸ add friend — the path a person actually takes.
        let members = app.descendants(matching: .any).matching(identifier: "circleMembers").firstMatch
        XCTAssertTrue(members.waitForExistence(timeout: 30), "the Circle header should offer manage circle")
        members.tap()

        let addFriend = app.descendants(matching: .any).matching(identifier: "circleAddFriend").firstMatch
        XCTAssertTrue(addFriend.waitForExistence(timeout: 15), "the circle sheet should offer add friend")

        let started = Date()
        addFriend.tap()

        // The sheet's own heading, not a spinner: "invite" must actually be on screen.
        let heading = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Invite someone you trust")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 8),
                      "the invite sheet must open — it froze or the app went down")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8,
                          "the invite sheet took too long to appear; the link work is back on the main thread")

        // Still alive and still interactive: a watchdog kill shows up here as a dead app.
        XCTAssertEqual(app.state, .runningForeground, "the app must survive opening the sheet")
        // The link resolves asynchronously now, so wait for the resolved artefacts by identifier
        // rather than for a substring of a label — and prove the placeholder gave way to a real QR,
        // which is what tells us the off-main work finished instead of hanging.
        let linkText = app.descendants(matching: .any).matching(identifier: "inviteLinkText").firstMatch
        let shareButton = app.descendants(matching: .any).matching(identifier: "shareInviteLink").firstMatch
        XCTAssertTrue(linkText.waitForExistence(timeout: 20) || shareButton.waitForExistence(timeout: 5),
                      "the sheet should show the invite link once it has resolved")
        let placeholder = app.descendants(matching: .any).matching(identifier: "inviteQRPlaceholder").firstMatch
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: 20),
                      "the QR placeholder should give way to the rendered code")

        // And it closes again — proving the whole sheet lifecycle, not just its first frame.
        let close = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Done", "Close")).firstMatch
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(heading.waitForNonExistence(timeout: 10), "the invite sheet should close")
        XCTAssertEqual(app.state, .runningForeground, "the app must still be alive after closing the sheet")
    }

    /// The in-call scene's minimize ("back") control must sit INSIDE the safe area, clear of the
    /// status bar and the display's rounded corner. It regressed to x=0/y=54 when the scene's
    /// ZStack ignored the safe area, which zeroed it for every descendant.
    func testCallMinimizeIsInsideSafeArea() {
        let app = app(tab: "circle")
        app.launchEnvironment["HAVEN_DEMO"] = "1"
        app.launchEnvironment["HAVEN_SCENE"] = "call"
        app.launch()

        // Query by IDENTIFIER, not by element type: on the iOS 27 simulator XCUITest classifies this
        // glass-styled Button as a PopUpButton under its "modern" automation attributes
        // ("Automation type mismatch: computed Button … vs PopUpButton"), so `app.buttons[…]`
        // found nothing while the control was on screen. The contract under test is the frame,
        // not the accessibility role.
        let minimize = app.descendants(matching: .any).matching(identifier: "callMinimize").firstMatch
        XCTAssertTrue(minimize.waitForExistence(timeout: 25), "the call scene should offer a way back")

        let frame = minimize.frame
        XCTAssertGreaterThanOrEqual(frame.minX, 16, "minimize must clear the display's rounded corner")
        XCTAssertGreaterThanOrEqual(frame.minY, 62, "minimize must sit below the status bar / Dynamic Island")

        minimize.tap()
        XCTAssertTrue(minimize.waitForNonExistence(timeout: 5), "minimize should take you back to the app")
    }

    /// An Activity row must open its DM — including a conversation you have ALREADY opened and
    /// backed out of once in this session.
    ///
    /// That last clause is the whole test. Opening the thread, popping it, and then routing to it
    /// again from Activity pushed a blank page: back chevron, empty title, no composer, no
    /// messages. Tapping the row without the earlier open/pop worked, which is exactly why a first
    /// attempt at this shipped "fixed" in 1.2.1 build 404 and was still broken on a real phone —
    /// the verification skipped the pop.
    func testActivityRowOpensDMAfterItWasOpenedAndPopped() {
        let app = app(tab: "messages")
        app.launchEnvironment["HAVEN_DEMO"] = "1"
        app.launch()

        // 1. open a conversation from the list, and 2. back out of it.
        let maya = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Maya")).firstMatch
        XCTAssertTrue(maya.waitForExistence(timeout: 40), "the demo DM list should have a conversation")
        maya.tap()
        let kiln = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "kiln")).firstMatch
        XCTAssertTrue(kiln.waitForExistence(timeout: 20), "the thread should open the first time")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(kiln.waitForNonExistence(timeout: 10), "back should pop the thread")

        // 3. Circle ▸ Activity ▸ the DM row for that same conversation.
        app.buttons["Circle"].firstMatch.tap()
        let bell = app.buttons["Activity"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 20), "the Circle tab should offer Activity")
        bell.tap()

        // DM rows sit below the circle activity, so scroll until one is on screen.
        let dmRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "coffee after")).firstMatch
        var scrolls = 0
        while !dmRow.exists && scrolls < 10 { app.swipeUp(); scrolls += 1 }
        XCTAssertTrue(dmRow.waitForExistence(timeout: 10), "Activity should list the DM")
        dmRow.tap()

        // The conversation itself — not an empty page wearing its navigation bar.
        XCTAssertTrue(kiln.waitForExistence(timeout: 20),
                      "the Activity row must open the conversation, not a blank page")
    }
}
