import XCTest

/// The circle-audience cues: a feed post goes to EVERYONE in the circle, and the composer's own form
/// says so — the placeholder names the circle ("Post to everyone in <Circle>"), the send control is a
/// labeled Post pill, and a reply reads "Reply to everyone in <Circle>…". Those passive cues are the
/// whole design: there is no audience menu and no "post to everyone?" confirmation, so a circle post
/// goes straight out. The ways to write to one person instead are the people themselves (a profile's
/// Message button, a circle member's "Message <name>", Message on a profile peeked from the story
/// viewer).
///
/// Runs on the PII-free demo cast (`HAVEN_DEMO`: Maya/Theo/Nina/Sam in "Your circle", with seeded
/// DM threads with Maya — "kiln" — and Theo — "gpx"), fully offline (`HAVEN_NO_NET`). Like the rest
/// of HavenUITests it needs a SIGNED simulator build (see HavenUITests for why).
final class AudienceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        SpringboardHygiene.dismissQueuedOpenPrompts()
    }

    private func launch(tab: String = "circle") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAVEN_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["HAVEN_TAB"] = tab
        app.launchEnvironment["HAVEN_NO_NET"] = "1"
        app.launchEnvironment["HAVEN_DEMO"] = "1"
        app.launch()
        return app
    }

    /// Unique per run: posts persist on the simulator between runs, so a fixed string could match
    /// an earlier run's post.
    private func uniqueText(_ prefix: String) -> String {
        "\(prefix) \(UUID().uuidString.prefix(8).lowercased())"
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func wait(_ element: XCUIElement, until format: String, _ args: CVarArg...,
                      timeout: TimeInterval = 30) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait for the composer's labeled Post pill and return the circle's display name, parsed out of
    /// its accessibility label ("Post to everyone in <Circle>").
    @discardableResult
    private func waitForAudience(_ app: XCUIApplication) -> String {
        let send = app.buttons["composeSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 40), "the composer should show the Post button")
        let prefix = "Post to everyone in "
        XCTAssertTrue(wait(send, until: "label BEGINSWITH %@", prefix),
                      "the Post button should name the circle, got \(send.label)")
        return String(send.label.dropFirst(prefix.count))
    }

    private func type(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let field = app.textFields["composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(text)
        // Under heavy host load the simulator drops synthesized keystrokes: gate-4 sent "aud" for
        // "audience first …" (3/3 green on a quiet host), and the Cancel-keeps-draft assertion then
        // compared the dropped draft. Finish what was lost so each test checks the app, not the
        // keyboard. Only ever APPENDS the missing tail — a field holding anything else still fails.
        for _ in 0..<2 {
            let now = field.value as? String ?? ""
            guard now != text, text.hasPrefix(now) else { break }
            field.tap()
            field.typeText(String(text.dropFirst(now.count)))
        }
        XCTAssertEqual(field.value as? String, text, "the composer should hold exactly what was typed")
        return field
    }

    // MARK: - Composer chrome

    /// The placeholder, Post button label and reply placeholder all say who a post reaches — and
    /// there is no audience menu stacked on top of them.
    func testComposerNamesTheAudience() {
        let app = launch()
        let circle = waitForAudience(app)
        XCTAssertFalse(circle.isEmpty)

        let field = app.textFields["composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let expectedPost = circle.count <= 14 ? "Post to everyone in \(circle)" : "Post to everyone…"
        XCTAssertEqual(field.placeholderValue, expectedPost, "the composer's placeholder names the circle")
        XCTAssertFalse(element(app, "composeAudience").exists, "no audience dropdown above the composer")

        // Replies are read by the whole circle too. Short names are spelled out; long ones fall back.
        let reply = element(app, "replyField")
        var scrolls = 0
        while !reply.exists && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "a post should offer a reply field")
        let expected = circle.count <= 14 ? "Reply to everyone in \(circle)…" : "Reply to everyone…"
        XCTAssertEqual(reply.placeholderValue, expected)
    }

    // MARK: - No confirmation

    /// A post in a busy circle (more than one other person) goes straight out on Post — no
    /// "Post to everyone in <Circle>?" step, no "Send privately instead…" — and so does the next.
    func testCirclePostGoesStraightThroughWithoutConfirmation() {
        let app = launch()
        let circle = waitForAudience(app)
        let confirmTitle = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Post to everyone in ")).firstMatch

        for prefix in ["audience first", "audience second"] {
            let text = uniqueText(prefix)
            let field = type(app, text)
            XCTAssertEqual(app.buttons["composeSend"].label, "Post to everyone in \(circle)",
                           "the send control is a labeled Post, not a bare paper plane")
            app.buttons["composeSend"].tap()
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15), "the post should appear straight away")
            XCTAssertFalse(confirmTitle.exists, "posting must not ask for confirmation")
            XCTAssertFalse(app.buttons["Post to everyone"].exists, "no confirmation button")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send privately")).firstMatch.exists,
                           "no send-privately detour")
            XCTAssertNotEqual(field.value as? String, text, "the composer clears after posting")
        }
    }

    // MARK: - Message from a person

    /// A post author's profile ▸ Message → their thread in Messages.
    func testProfileMessageOpensDM() {
        let app = launch()
        waitForAudience(app)

        let author = app.buttons.matching(identifier: "postAuthor")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Theo")).firstMatch
        var scrolls = 0
        while !author.exists && scrolls < 12 { app.swipeUp(); scrolls += 1 }
        XCTAssertTrue(author.waitForExistence(timeout: 10), "a post by Theo should link to his profile")
        author.tap()

        let message = element(app, "profileMessage")
        XCTAssertTrue(message.waitForExistence(timeout: 15), "another person's profile should offer Message")
        XCTAssertEqual(message.label, "Message Theo Park privately")
        message.tap()

        let marker = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "gpx")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "Message should open Theo's thread")
        XCTAssertTrue(app.textFields["dmComposeField"].waitForExistence(timeout: 10))
        XCTAssertFalse(message.exists, "the profile should be closed, not left over the thread")
    }

    /// Manage circle ▸ long-press a member ▸ "Message <name>" → their thread in Messages.
    func testCircleMemberMenuMessage() {
        let app = launch()
        waitForAudience(app)

        let members = element(app, "circleMembers")
        XCTAssertTrue(members.waitForExistence(timeout: 20))
        members.tap()

        let maya = app.staticTexts.matching(identifier: "circleMemberName")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Maya")).firstMatch
        XCTAssertTrue(maya.waitForExistence(timeout: 15), "the circle sheet should list Maya")
        maya.press(forDuration: 1.2)

        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Message Maya")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), "the member menu should offer Message <name>")
        action.tap()

        let marker = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "kiln")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "Message should open Maya's thread")
        XCTAssertTrue(maya.waitForNonExistence(timeout: 10), "the circle sheet should close")
    }

    /// Story viewer ▸ tap the sharer ▸ Message → the full-screen viewer closes and Messages shows
    /// the thread (it used to open hidden underneath the cover).
    func testStoryProfileMessageDismissesViewer() {
        let app = launch()
        waitForAudience(app)

        let ring = app.buttons.matching(identifier: "storyRing")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Maya")).firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 20), "the stories tray should show Maya's story")
        ring.tap()

        let sharer = app.buttons.matching(identifier: "storySharer")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Maya")).firstMatch
        XCTAssertTrue(sharer.waitForExistence(timeout: 10), "the story viewer should name its sharer")
        sharer.tap()   // pauses the viewer and peeks the profile

        let message = element(app, "profileMessage")
        XCTAssertTrue(message.waitForExistence(timeout: 15), "the peeked profile should offer Message")
        message.tap()

        XCTAssertTrue(sharer.waitForNonExistence(timeout: 10), "the story viewer must close")
        let marker = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "kiln")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "Maya's thread should be showing in Messages")
        let dmField = app.textFields["dmComposeField"]
        XCTAssertTrue(dmField.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(dmField, until: "hittable == true", timeout: 10),
                      "the thread must be on top, not under the story cover")
    }
}
