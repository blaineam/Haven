import XCTest

/// The circle-audience flow: a feed post goes to EVERYONE in the circle, and the composer has to say
/// so — the "Everyone in <Circle> · N people" chip, the "Post to everyone…" placeholder, the labeled
/// Post button, the one-time per-circle confirmation, and the ways out to a private message (the
/// confirmation's "Send privately instead…", the chip menu, a profile's Message button, a circle
/// member's "Message <name>", and Message on a profile peeked from the story viewer).
///
/// Runs on the PII-free demo cast (`HAVEN_DEMO`: Maya/Theo/Nina/Sam in "Your circle", with seeded
/// DM threads with Maya — "kiln" — and Theo — "gpx"), fully offline (`HAVEN_NO_NET`). Like the rest
/// of HavenUITests it needs a SIGNED simulator build (see HavenUITests for why).
final class AudienceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// `resetAck` launches with `HAVEN_RESET_AUDIENCE_ACK=1` (DEBUG-only) so the one-time
    /// confirmation is asked again even on a simulator that already acknowledged it.
    private func launch(tab: String = "circle", resetAck: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAVEN_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["HAVEN_TAB"] = tab
        app.launchEnvironment["HAVEN_NO_NET"] = "1"
        app.launchEnvironment["HAVEN_DEMO"] = "1"
        if resetAck { app.launchEnvironment["HAVEN_RESET_AUDIENCE_ACK"] = "1" }
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

    /// Wait until the chip knows the audience (the demo cast is seeded asynchronously, and the
    /// confirmation is only asked when more than one other person would see the post). Returns the
    /// circle's display name, parsed out of the chip's accessibility label.
    @discardableResult
    private func waitForAudience(_ app: XCUIApplication) -> String {
        let chip = element(app, "composeAudience")
        XCTAssertTrue(chip.waitForExistence(timeout: 40), "the composer should show the audience chip")
        XCTAssertTrue(wait(chip, until: "label MATCHES %@", ".*Everyone in .+ · ([2-9]|[1-9][0-9]+) people.*"),
                      "the chip should name the circle and a count of more than one person, got \(chip.label)")
        let label = chip.label
        guard let start = label.range(of: "Everyone in "), let end = label.range(of: " · ", range: start.upperBound..<label.endIndex)
        else { XCTFail("unparseable chip label: \(label)"); return "" }
        return String(label[start.upperBound..<end.lowerBound])
    }

    private func type(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let field = app.textFields["composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(text)
        return field
    }

    /// Cancel the confirmation. iOS 26 presents a confirmation dialog as a popover-style sheet with
    /// no visible Cancel button (the cancel role is "tap outside"), older layouts show one.
    private func cancelDialog(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
        if cancel.exists {
            cancel.tap()
        } else if dismissRegion.exists {
            dismissRegion.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
    }

    private var confirmTitle: NSPredicate { NSPredicate(format: "label BEGINSWITH %@", "Post to everyone in ") }

    // MARK: - Composer chrome

    /// The chip, placeholder, Post button label and reply placeholder all say who a post reaches.
    func testComposerNamesTheAudience() {
        let app = launch()
        let circle = waitForAudience(app)

        let field = app.textFields["composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.placeholderValue, "Post to everyone…")

        let send = app.buttons["composeSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertEqual(send.label, "Post to everyone in \(circle)",
                       "the send control is a labeled Post, not a bare paper plane")

        // Replies are read by the whole circle too. Short names are spelled out; long ones fall back.
        let reply = element(app, "replyField")
        var scrolls = 0
        while !reply.exists && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "a post should offer a reply field")
        let expected = circle.count <= 14 ? "Reply to everyone in \(circle)…" : "Reply to everyone…"
        XCTAssertEqual(reply.placeholderValue, expected)
    }

    // MARK: - One-time confirmation

    /// First post in a busy circle asks "Post to everyone in <Circle>?"; Cancel keeps the draft and
    /// posts nothing; accepting posts; the next post (and the next launch) doesn't ask again.
    func testConfirmationAsksOncePerCircleAndCancelKeepsDraft() {
        var app = launch()
        let circle = waitForAudience(app)

        // 1. Cancel → nothing posted, draft kept.
        let first = uniqueText("audience first")
        let field = type(app, first)
        app.buttons["composeSend"].tap()
        let title = app.staticTexts.matching(confirmTitle).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the first post should ask who it goes to")
        XCTAssertEqual(title.label, "Post to everyone in \(circle)?")
        XCTAssertTrue(app.buttons["Post to everyone"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send privately instead")).firstMatch.exists)
        cancelDialog(app)
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "Cancel should close the confirmation")
        XCTAssertEqual(field.value as? String, first, "Cancel must keep the draft")
        XCTAssertFalse(app.staticTexts[first].waitForExistence(timeout: 3), "Cancel must not post")

        // 2. Send again → asked again (Cancel didn't acknowledge) → Post to everyone → posted.
        app.buttons["composeSend"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Cancel must not count as acknowledging")
        app.buttons["Post to everyone"].tap()
        XCTAssertTrue(app.staticTexts[first].waitForExistence(timeout: 15), "the confirmed post should appear")

        // 3. The second post in the same circle goes straight out.
        let second = uniqueText("audience second")
        _ = type(app, second)
        app.buttons["composeSend"].tap()
        XCTAssertTrue(app.staticTexts[second].waitForExistence(timeout: 15), "the second post should appear")
        XCTAssertFalse(title.exists, "the confirmation is one-time per circle")
        XCTAssertFalse(app.buttons["Post to everyone"].exists)

        // 4. The acknowledgement is persisted: a fresh launch doesn't ask either.
        app.terminate()
        app = launch(resetAck: false)
        waitForAudience(app)
        let third = uniqueText("audience third")
        _ = type(app, third)
        app.buttons["composeSend"].tap()
        XCTAssertTrue(app.staticTexts[third].waitForExistence(timeout: 15), "the post after relaunch should appear")
        XCTAssertFalse(app.staticTexts.matching(confirmTitle).firstMatch.exists,
                       "the acknowledgement must survive a relaunch")
    }

    // MARK: - Send privately

    /// Pick a person in the DM picker and land in their thread with the draft — once.
    private func pickAndAssertDraftCarried(_ app: XCUIApplication, person: String, threadMarker: String,
                                           draft: String) {
        let row = app.buttons.matching(identifier: "dmPickerRow")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", person)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the private-message picker should list \(person)")
        row.tap()
        let start = element(app, "dmPickerStart")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        let marker = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", threadMarker)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "\(person)'s thread should open in Messages")
        let dmField = app.textFields["dmComposeField"]
        XCTAssertTrue(dmField.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(dmField, until: "value == %@", draft, timeout: 10),
                      "the draft should land in the DM composer exactly once, got \(String(describing: dmField.value))")

        // Nothing went to the circle, and the circle composer was cleared.
        app.buttons["Circle"].firstMatch.tap()
        let feedField = app.textFields["composeField"]
        XCTAssertTrue(feedField.waitForExistence(timeout: 15))
        XCTAssertNotEqual(feedField.value as? String, draft, "the draft moved to the DM, not left in the feed")
        XCTAssertFalse(app.staticTexts[draft].waitForExistence(timeout: 3), "nothing may be posted to the circle")

        // Exactly once: re-entering the thread must not re-append the staged draft.
        app.buttons["Messages"].firstMatch.tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(marker.waitForNonExistence(timeout: 10), "back should pop the thread")
        let listRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", person)).firstMatch
        XCTAssertTrue(listRow.waitForExistence(timeout: 10))
        listRow.tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        XCTAssertTrue(dmField.waitForExistence(timeout: 10))
        XCTAssertFalse((dmField.value as? String ?? "").contains(draft),
                       "the staged draft must be consumed once, not re-applied on re-entry")
    }

    /// Confirmation ▸ "Send privately instead…" ▸ pick Maya → her thread, draft carried over.
    func testSendPrivatelyInsteadCarriesDraftToDM() {
        let app = launch()
        waitForAudience(app)
        let draft = uniqueText("just for maya")
        _ = type(app, draft)
        app.buttons["composeSend"].tap()

        let privately = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send privately instead")).firstMatch
        XCTAssertTrue(privately.waitForExistence(timeout: 10), "the confirmation should offer a private message")
        privately.tap()
        pickAndAssertDraftCarried(app, person: "Maya", threadMarker: "kiln", draft: draft)
    }

    /// The chip's menu ▸ "Send privately to someone…" opens the same picker.
    func testChipMenuSendPrivately() {
        let app = launch()
        waitForAudience(app)
        let draft = uniqueText("just for theo")
        _ = type(app, draft)

        element(app, "composeAudience").tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send privately to someone")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the chip menu should offer a private message")
        item.tap()
        pickAndAssertDraftCarried(app, person: "Theo", threadMarker: "gpx", draft: draft)
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
