import XCTest

/// The Messages tab (list, a thread, sending, the new-message picker) and the You tab (profile
/// header, edit profile).
final class MessagesAndYouUITests: HavenUITestCase {

    /// The list shows both seeded conversations; a thread shows its history and a sent message lands
    /// at the bottom of it.
    func testMessagesListThreadAndSend() {
        let app = launch(tab: "messages")

        XCTAssertTrue(app.navigationBars["Messages"].waitForExistence(timeout: 40))
        let maya = text(app, containing: "Maya")
        let theo = text(app, containing: "Theo")
        XCTAssertTrue(maya.waitForExistence(timeout: 40), "the list should show the thread with Maya")
        XCTAssertTrue(theo.waitForExistence(timeout: 10), "and the thread with Theo")

        theo.tap()
        XCTAssertTrue(text(app, containing: "trail conditions look perfect").waitForExistence(timeout: 20),
                      "Theo's thread should show its history")
        XCTAssertTrue(text(app, containing: "sending the gpx now").exists)

        let field = app.textFields["dmComposeField"]
        type("see you at the trailhead", into: field)
        element(app, "dmSend").tap()
        XCTAssertTrue(app.staticTexts["see you at the trailhead"].waitForExistence(timeout: 15),
                      "the sent message should appear in the thread")
        XCTAssertNotEqual(field.value as? String, "see you at the trailhead", "the composer clears after sending")
    }

    /// New message ▸ the picker lists your contacts; Start is disabled until someone is picked, and
    /// picking Maya opens her (existing) conversation.
    func testNewMessagePickerOpensAConversation() {
        let app = launch(tab: "messages")
        XCTAssertTrue(text(app, containing: "Maya").waitForExistence(timeout: 40))

        element(app, "newMessageButton").tap()
        XCTAssertTrue(app.navigationBars["New message"].waitForExistence(timeout: 10))
        let rows = app.buttons.matching(identifier: "dmPickerRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 4, "the picker should list the four people in your circle")
        let start = element(app, "dmPickerStart")
        start.tap()   // nobody picked yet: Start must do nothing
        XCTAssertTrue(app.navigationBars["New message"].exists, "nothing to start until someone is picked")

        rows.matching(NSPredicate(format: "label CONTAINS[c] %@", "Maya")).firstMatch.tap()
        start.tap()

        XCTAssertTrue(text(app, containing: "kiln").waitForExistence(timeout: 20), "Maya's thread should open")
        XCTAssertTrue(app.textFields["dmComposeField"].waitForExistence(timeout: 10))
    }

    /// You shows the seeded profile; Edit profile changes the bio and the header shows it.
    func testYouProfileAndEditProfile() {
        let app = launch(tab: "you")

        let name = element(app, "youDisplayName")
        XCTAssertTrue(name.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(name, until: "label == %@", "Riley Avery", timeout: 30), "got \(name.label)")
        let bio = element(app, "youBio")
        XCTAssertTrue(bio.waitForExistence(timeout: 10))
        XCTAssertTrue(bio.label.contains("plant hoarder"), "the seeded bio shows, got \(bio.label)")

        element(app, "editProfileButton").tap()
        XCTAssertTrue(app.navigationBars["Edit profile"].waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "editName").value as? String, "Riley Avery")
        type("potter and plant person", into: element(app, "editBio"), replacing: true)
        element(app, "editProfileDone").tap()

        XCTAssertTrue(app.navigationBars["Edit profile"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(wait(bio, until: "label == %@", "potter and plant person"), "the header shows the new bio, got \(bio.label)")
    }

    /// Someone's profile (from their post) shows their name and a Message button.
    func testFriendProfileFromAPost() {
        let app = launch()
        waitForFeed(app)

        let author = app.buttons.matching(identifier: "postAuthor")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Nina")).firstMatch
        XCTAssertTrue(scroll(app, to: author), "a post by Nina should link to her profile")
        author.tap()

        XCTAssertTrue(app.navigationBars["Nina Brooks"].waitForExistence(timeout: 15), "her profile opens under her name")
        let message = element(app, "profileMessage")
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Message Nina Brooks privately")
        XCTAssertTrue(text(app, containing: "film photography").exists, "her bio shows on her profile")
    }
}
