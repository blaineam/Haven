import XCTest

/// The Circle tab: the seeded feed, reacting, commenting, your own post's edit/unsend, reporting
/// someone else's post, the composer's attach menu and schedule sheet, and the circle switcher.
final class FeedUITests: HavenUITestCase {

    /// The post menu (`…`) that belongs to the card showing `text`: the nearest menu above the text.
    private func postMenu(_ app: XCUIApplication, forPostWith text: XCUIElement) -> XCUIElement {
        let menus = app.descendants(matching: .any).matching(identifier: "postMenu").allElementsBoundByIndex
        let y = text.frame.minY
        let above = menus.filter { $0.frame.minY <= y }.max { $0.frame.minY < $1.frame.minY }
        return above ?? menus.first ?? element(app, "postMenu")
    }

    /// The seeded circle: Maya's and Theo's posts with their authors, a seeded comment, and the
    /// story tray.
    func testSeededFeedShowsPostsCommentsAndStories() {
        let app = launch()
        let circle = waitForFeed(app)
        XCTAssertEqual(circle, "My Circle", "the demo opens on the default circle")

        let mayaPost = text(app, containing: "first throw off the new wheel")
        XCTAssertTrue(scroll(app, to: mayaPost), "Maya's seeded post should be in the feed")
        let theoAuthor = app.buttons.matching(identifier: "postAuthor")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Theo")).firstMatch
        XCTAssertTrue(scroll(app, to: theoAuthor), "Theo's post should name him as its author")
        XCTAssertTrue(scroll(app, to: text(app, containing: "12 miles before breakfast")))

        // Back to the top: the story tray lists people with a live story.
        let ring = app.buttons.matching(identifier: "storyRing").firstMatch
        XCTAssertTrue(scroll(app, to: ring, up: false), "the stories tray should show at least one ring")
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "storyRing").count, 2,
                                    "several of the cast have stories")
    }

    /// React to a post from the picker, see your chip, then see yourself in "Who reacted".
    func testReactFromPickerAndSeeWhoReacted() {
        let app = launch()
        waitForFeed(app)

        let add = element(app, "reactionAdd")
        XCTAssertTrue(scroll(app, to: add), "a post should offer Add reaction")
        add.tap()

        XCTAssertTrue(app.navigationBars["React"].waitForExistence(timeout: 10), "the reaction picker should open")
        let pick = element(app, "reaction.😀")
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "the picker should list the full emoji set")
        pick.tap()
        XCTAssertTrue(app.navigationBars["React"].waitForNonExistence(timeout: 10), "picking closes the picker")

        let chip = element(app, "reactionChip.😀")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "the post should now carry a 😀 chip")
        XCTAssertTrue(wait(chip, until: "label CONTAINS %@", "1"), "with a count of one, got \(chip.label)")

        chip.press(forDuration: 1.0)
        XCTAssertTrue(app.navigationBars["Who reacted"].waitForExistence(timeout: 10), "long-press shows who reacted")
        XCTAssertTrue(text(app, containing: "😀").waitForExistence(timeout: 5), "the roster lists the 😀 reaction")
        button(app, labeled: "Done").tap()
        XCTAssertTrue(app.navigationBars["Who reacted"].waitForNonExistence(timeout: 10))
    }

    /// A reply typed under a post shows up under that post.
    func testCommentOnAPost() {
        let app = launch()
        waitForFeed(app)

        guard let reply = firstOnScreen(app, app.textFields.matching(identifier: "replyField")) else {
            return XCTFail("a post should offer a reply field")
        }
        type("lovely glaze", into: reply)
        // The send button on the same row as that field.
        let send = app.buttons.matching(identifier: "replySend").allElementsBoundByIndex
            .filter { $0.frame.minY.isFinite && $0.frame.height > 0 }
            .min { abs($0.frame.midY - reply.frame.midY) < abs($1.frame.midY - reply.frame.midY) }
        guard let send else { return XCTFail("the reply field should have a send button") }
        send.tap()

        XCTAssertTrue(text(app, containing: "lovely glaze").waitForExistence(timeout: 15),
                      "the comment should appear under the post")
    }

    /// Your own post: post it, edit it (the card shows the new text and "edited"), then unsend it.
    func testOwnPostCanBeEditedThenUnsent() {
        let app = launch()
        waitForFeed(app)

        type("draft from the edit test", into: app.textFields["composeField"])
        app.buttons["composeSend"].tap()
        let original = app.staticTexts["draft from the edit test"]
        XCTAssertTrue(original.waitForExistence(timeout: 15), "the new post should appear")

        postMenu(app, forPostWith: original).tap()
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "your own post's menu offers Edit")
        XCTAssertFalse(app.buttons["Report"].exists, "and never Report")
        edit.tap()

        XCTAssertTrue(app.navigationBars["Edit post"].waitForExistence(timeout: 10))
        let field = element(app, "editPostField")
        XCTAssertEqual(field.value as? String, "draft from the edit test", "the editor starts from the post")
        type("final words from the edit test", into: field, replacing: true)
        element(app, "editPostSave").tap()

        let edited = app.staticTexts["final words from the edit test"]
        XCTAssertTrue(edited.waitForExistence(timeout: 15), "the card should show the edited text")
        XCTAssertTrue(original.waitForNonExistence(timeout: 5), "and not the old text")
        XCTAssertTrue(app.staticTexts["edited"].firstMatch.waitForExistence(timeout: 5), "edited posts say so")

        postMenu(app, forPostWith: edited).tap()
        let unsend = app.buttons["Unsend"].firstMatch
        XCTAssertTrue(unsend.waitForExistence(timeout: 10))
        unsend.tap()
        XCTAssertTrue(edited.waitForNonExistence(timeout: 15), "an unsent post leaves the feed")
    }

    /// Someone else's post ▸ Report opens the report sheet; Report stays disabled until a reason is
    /// picked, and Cancel closes it without reporting.
    func testReportSheetOpensAndCancels() {
        let app = launch()
        waitForFeed(app)

        let post = text(app, containing: "first throw off the new wheel")
        XCTAssertTrue(scroll(app, to: post))
        postMenu(app, forPostWith: post).tap()
        let report = app.buttons["Report"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10), "another person's post offers Report")
        XCTAssertFalse(app.buttons["Edit"].exists, "but not Edit")
        report.tap()

        XCTAssertTrue(app.navigationBars["Report post"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "What's wrong with it?").exists)
        let submit = app.navigationBars["Report post"].buttons["Report"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "nothing to report until a reason is chosen")
        app.navigationBars["Report post"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Report post"].waitForNonExistence(timeout: 10))
    }

    /// The composer's + menu lists every way to attach something, and "Send later…" (offered once
    /// there is text) opens the schedule sheet.
    func testAttachMenuAndSchedulePicker() {
        let app = launch()
        waitForFeed(app)

        type("for later", into: app.textFields["composeField"])
        element(app, "attachMenu").tap()
        for label in ["Photo or Video", "Files…", "Camera", "Add a song", "Pin a location", "Disappears after…", "Send later…"] {
            XCTAssertTrue(app.buttons[label].firstMatch.waitForExistence(timeout: 5), "the attach menu should offer \(label)")
        }
        app.buttons["Send later…"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Schedule"].waitForExistence(timeout: 10), "Send later opens the schedule sheet")
        XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 5), "with a date to pick")
        app.navigationBars["Schedule"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Schedule"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.textFields["composeField"].value as? String, "for later", "cancelling keeps the draft")
    }

    /// The circle switcher lists both demo circles; a new circle becomes the active audience, and
    /// switching to Weekend Crew shows that circle's own posts.
    func testCircleSwitcherCreatesAndSwitchesCircles() {
        let app = launch()
        waitForFeed(app)

        let switcher = element(app, "circleSwitcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.tap()
        XCTAssertTrue(app.buttons["Weekend Crew"].firstMatch.waitForExistence(timeout: 5), "the switcher lists the second circle")
        app.buttons["New circle…"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["New circle"].waitForExistence(timeout: 10))
        let create = element(app, "newCircleCreate")
        create.tap()   // no name yet: Create must do nothing
        XCTAssertTrue(app.navigationBars["New circle"].exists, "a circle needs a name before it can be created")
        type("Book club", into: element(app, "newCircleName"))
        create.tap()

        let send = app.buttons["composeSend"]
        XCTAssertTrue(wait(send, until: "label == %@", "Post to everyone in Book club", timeout: 20),
                      "the new circle becomes the audience, got \(send.label)")

        switcher.tap()
        app.buttons["Weekend Crew"].firstMatch.tap()
        XCTAssertTrue(wait(send, until: "label == %@", "Post to everyone in Weekend Crew", timeout: 20))
        XCTAssertTrue(text(app, containing: "bringing the sourdough").waitForExistence(timeout: 15),
                      "Weekend Crew shows its own posts")
        XCTAssertFalse(text(app, containing: "first throw off the new wheel").exists,
                       "and not My Circle's")
    }
}
