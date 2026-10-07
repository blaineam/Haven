import XCTest

/// The Apple Watch companion, driven offline: `-UITestMode` turns on the DEBUG-only watch demo
/// (synthetic threads, no paired iPhone, no notification prompt) and makes reply/react echo
/// locally instead of going to WCSession.
final class HavenWatchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        // On a loaded host the watch simulator can drop the app right after launch — the next query
        // then fails "application com.blaineam.kith.watchkitapp is not running" (2026-10-07 gate,
        // load ~32, no crash report). Wait for the demo's first screen and relaunch once if the app
        // never got there; a real launch failure still fails, on the second attempt.
        for attempt in 1...2 {
            app.launch()
            if app.wait(for: .runningForeground, timeout: 30),
               app.staticTexts["Circles"].waitForExistence(timeout: 30) {
                return app
            }
            if attempt == 1 { app.terminate() }
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "watch.threadRow")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
    }

    private func message(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "watch.messageRow")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @discardableResult
    private func wait(_ element: XCUIElement, until format: String, _ args: CVarArg..., timeout: TimeInterval = 10) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, up: Bool = true) -> Bool {
        var n = 0
        while !(element.exists && element.isHittable) && n < 8 {
            if up { app.swipeUp() } else { app.swipeDown() }
            n += 1
        }
        return element.waitForExistence(timeout: 3)
    }

    /// The conversations list separates circles from messages and shows each thread's latest line.
    func testConversationsListShowsCirclesAndMessages() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Circles"].waitForExistence(timeout: 30), "circles get their own section")
        XCTAssertTrue(row(app, "Trail Crew").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sunset hike Saturday?"].exists, "a row shows the thread's latest line")
        XCTAssertTrue(scrollTo(app, row(app, "Ari")), "the DM with Ari is listed")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Messages")).firstMatch.exists,
                      "messages get their own section")
        XCTAssertTrue(scrollTo(app, row(app, "Noa")), "and the DM with Noa")
    }

    /// A DM thread shows its history (with the photo carousel); a quick reply lands at the bottom.
    func testThreadShowsMessagesAndQuickReplyEchoes() {
        let app = launch()
        let ari = row(app, "Ari")
        XCTAssertTrue(scrollTo(app, ari))
        ari.tap()

        // A DM opens scrolled to the newest message at the bottom.
        let media = message(app, containing: "Made it to the top")
        XCTAssertTrue(media.waitForExistence(timeout: 10), "the thread opens on its newest message")
        XCTAssertTrue(media.label.hasPrefix("Ari"), "a message from someone else names them, got \(media.label)")
        XCTAssertTrue(media.images.count > 0 || app.images.count > 0, "a photo post shows its thumbnails")

        media.press(forDuration: 1.0)
        let reply = app.buttons["Reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "long-press offers Reply")
        XCTAssertTrue(app.buttons["React"].firstMatch.exists, "and React")
        reply.tap()

        XCTAssertTrue(app.staticTexts["Replying to Ari"].waitForExistence(timeout: 10), "the reply sheet names who it goes to")
        let canned = app.buttons.matching(identifier: "watch.quickReply")
            .matching(NSPredicate(format: "label == %@", "On my way")).firstMatch
        XCTAssertTrue(scrollTo(app, canned), "quick replies are offered")
        canned.tap()

        XCTAssertTrue(app.staticTexts["Replying to Ari"].waitForNonExistence(timeout: 10), "sending closes the sheet")
        // Your own messages carry no author name, so the row STARTS with the text (Ari's earlier
        // "On my way 🚲" reads "Ari, On my way 🚲, …").
        let sent = app.descendants(matching: .any).matching(identifier: "watch.messageRow")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "On my way")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the reply should land in the thread as yours")
        XCTAssertTrue(sent.frame.minY > media.frame.minY, "below the message it answered")

        // And the history above is still there.
        let first = message(app, containing: "Heading over now")
        XCTAssertTrue(scrollTo(app, first, up: false), "the thread keeps its earlier messages")
    }

    /// React from the picker: the reaction shows on the message row.
    func testReactionPickerAddsAReaction() {
        let app = launch()
        let ari = row(app, "Ari")
        XCTAssertTrue(scrollTo(app, ari))
        ari.tap()

        let target = message(app, containing: "Made it to the top")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertFalse(target.label.contains("😮"))
        target.press(forDuration: 1.0)
        let react = app.buttons["React"].firstMatch
        XCTAssertTrue(react.waitForExistence(timeout: 10))
        react.tap()

        let wow = element(app, "watch.reaction.😮")
        XCTAssertTrue(wow.waitForExistence(timeout: 10), "the picker lists the reactions")
        wow.tap()
        XCTAssertTrue(wait(message(app, containing: "Made it to the top"), until: "label CONTAINS %@", "😮"),
                      "the reaction should show on the message")
    }

    /// A circle shows its story tray; a story opens full-screen with its author and caption.
    func testCircleStoryTrayAndViewer() {
        let app = launch()
        let crew = row(app, "Trail Crew")
        XCTAssertTrue(crew.waitForExistence(timeout: 30))
        crew.tap()

        XCTAssertTrue(message(app, containing: "Sunset hike Saturday").waitForExistence(timeout: 10), "the circle shows its posts")
        let ring = element(app, "watch.storyRing")
        XCTAssertTrue(ring.waitForExistence(timeout: 10), "stories ride in a tray at the top")
        XCTAssertTrue(ring.label.contains("Noa"), "the ring names its author, got \(ring.label)")
        ring.tap()

        let viewer = element(app, "watch.storyViewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        XCTAssertTrue(viewer.label.contains("golden hour"), "the story shows its caption, got \(viewer.label)")
        XCTAssertTrue(viewer.label.contains("Noa"), "and its author")
        viewer.tap()   // the last story: tapping past it closes the viewer
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 10))
    }
}
