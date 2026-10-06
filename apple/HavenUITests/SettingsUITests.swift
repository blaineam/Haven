import XCTest

/// You ▸ Settings and every screen it leads to.
final class SettingsUITests: HavenUITestCase {

    private func openSettings(_ app: XCUIApplication) {
        let gear = element(app, "settingsButton")
        XCTAssertTrue(gear.waitForExistence(timeout: 40), "Settings should be reachable from You")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    /// Settings is a long lazy Form: swipe until the row is realized, then tap it.
    private func openRow(_ app: XCUIApplication, _ label: String, title: String) {
        let row = app.buttons[label].firstMatch
        XCTAssertTrue(scroll(app, to: row, max: 12), "Settings should list \(label)")
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "\(label) should open \(title)")
    }

    private func switchValue(_ s: XCUIElement) -> String { (s.value as? String) ?? "" }

    /// A toggle flips, and keeps its new value across a push and pop of another screen.
    func testTogglesFlipAndPersistAcrossNavigation() {
        let app = launch(tab: "you")
        openSettings(app)

        let saver = app.switches["settings.superDataSaver"].firstMatch
        XCTAssertTrue(scroll(app, to: saver), "the media section should offer Super data saver")
        let before = switchValue(saver)
        XCTAssertEqual(before, "0", "Super data saver starts off")
        // iOS 26 exposes the row AND its inner switch; only the inner control flips on tap.
        let knob = saver.switches.firstMatch
        (knob.exists ? knob : saver).tap()
        XCTAssertTrue(wait(saver, until: "value == %@", "1"), "the toggle should flip on")

        openRow(app, "Blocked people", title: "Blocked")
        goBack(app)
        XCTAssertTrue(scroll(app, to: saver, up: false))
        XCTAssertEqual(switchValue(saver), "1", "the setting should persist after navigating away and back")

        // Auto-delete: picking a value reveals "Always keep my own posts".
        let retention = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto-delete old posts")).firstMatch
        XCTAssertTrue(scroll(app, to: retention))
        XCTAssertFalse(app.switches["Always keep my own posts"].exists, "only offered once auto-delete is on")
        retention.tap()
        let month = app.buttons["After 1 month"].firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 5), "the auto-delete picker lists its choices")
        month.tap()
        XCTAssertTrue(app.switches["Always keep my own posts"].waitForExistence(timeout: 10),
                      "turning auto-delete on offers keeping your own posts")
    }

    /// Storage, relays (incl. the Add relay sheet's validation) and blocked people.
    func testStorageRelaysAndBlockedScreens() {
        let app = launch(tab: "you")
        openSettings(app)

        openRow(app, "Manage media", title: "Manage media")
        goBack(app)

        openRow(app, "Relays", title: "Relays")
        let add = app.buttons["Add relay"].firstMatch
        XCTAssertTrue(scroll(app, to: add), "Relays should offer Add relay")
        add.tap()
        XCTAssertTrue(app.navigationBars["Add relay"].waitForExistence(timeout: 10))
        let confirm = app.navigationBars["Add relay"].buttons["Add"]
        XCTAssertFalse(confirm.isEnabled, "an empty relay can't be added")
        let node = app.textFields["Node id (64 hex) or interface JSON"].firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        type("not-a-node-id", into: node)
        XCTAssertFalse(confirm.isEnabled, "a malformed node id can't be added")
        app.navigationBars["Add relay"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add relay"].waitForNonExistence(timeout: 10))
        goBack(app)

        openRow(app, "Blocked people", title: "Blocked")
        XCTAssertTrue(text(app, containing: "No one's blocked").waitForExistence(timeout: 5), "the demo blocks nobody")
        goBack(app)
    }

    /// Identity & backup (current identity, transfer, restore) and Devices.
    func testIdentityAndDevicesScreens() {
        let app = launch(tab: "you")
        openSettings(app)

        openRow(app, "Identity & iCloud backup", title: "Identity & backup")
        XCTAssertTrue(text(app, containing: "Current").waitForExistence(timeout: 10), "the identity in use is marked Current")
        let move = app.buttons["Move to another device"].firstMatch
        XCTAssertTrue(scroll(app, to: move))
        move.tap()
        XCTAssertTrue(app.navigationBars["Transfer"].waitForExistence(timeout: 10))
        goBack(app)
        let restore = app.buttons["Add / restore an identity here"].firstMatch
        XCTAssertTrue(scroll(app, to: restore))
        restore.tap()
        XCTAssertTrue(app.navigationBars["Restore"].waitForExistence(timeout: 10))
        goBack(app)
        goBack(app)

        openRow(app, "Devices", title: "Devices")
        XCTAssertTrue(text(app, containing: "primary").waitForExistence(timeout: 10),
                      "Devices explains the primary device")
        goBack(app)
    }

    /// Advanced: the privacy check passes, Connection pushes diagnostics, and "Start over" asks
    /// before erasing anything (cancelled here).
    func testAdvancedConnectionAndStartOverConfirmation() {
        let app = launch(tab: "you")
        openSettings(app)

        openRow(app, "Advanced", title: "Advanced")
        XCTAssertTrue(element(app, "privacyCheck").waitForExistence(timeout: 10), "Advanced offers the privacy check")
        let connection = element(app, "connectionRow")
        XCTAssertTrue(scroll(app, to: connection), "Advanced links to connection diagnostics")
        connection.tap()   // the middle of the row, not its label: the whole row must take the tap
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 10))
        goBack(app)

        let startOver = app.buttons["Start over (new identity)"].firstMatch
        XCTAssertTrue(scroll(app, to: startOver), "Advanced offers Start over")
        startOver.tap()
        let erase = app.buttons["Erase everything & start over"].firstMatch
        XCTAssertTrue(erase.waitForExistence(timeout: 10), "Start over must confirm first")
        // iOS 26 draws this dialog as a popover under its button, with no Cancel on iPhone: tapping
        // away (below it) is the cancel.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap() }
        XCTAssertTrue(erase.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Advanced"].exists, "cancelling leaves you where you were")
    }

    /// The Instagram import sheet opens for the active circle, and the About section names the app
    /// and its version.
    func testInstagramImportSheetAndAbout() {
        let app = launch(tab: "you")
        openSettings(app)

        let importRow = element(app, "settings.instagramImport")
        XCTAssertTrue(scroll(app, to: importRow))
        importRow.tap()
        XCTAssertTrue(app.navigationBars["Import from Instagram"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "Ask Instagram for your file").waitForExistence(timeout: 5),
                      "the import starts on its first walkthrough step")
        XCTAssertTrue(app.links["Open Instagram"].firstMatch.exists || app.buttons["Open Instagram"].firstMatch.exists,
                      "step one links to Instagram's export page")
        app.navigationBars["Import from Instagram"].buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Import from Instagram"].waitForNonExistence(timeout: 10))

        let version = text(app, containing: "Version")
        XCTAssertTrue(scroll(app, to: version, max: 15), "About should show the version")
        XCTAssertTrue(version.label.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil
                        || text(app, containing: "2.").exists, "with a version number")
    }
}
