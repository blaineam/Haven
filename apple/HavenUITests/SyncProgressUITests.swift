import XCTest

/// The honest-progress UI, end to end in the real app: the composer's sync pill follows the REAL
/// upload queue, and a media placeholder's "Downloading… i/n" advances as peer chunks land.
///
/// Field report: "The app has UX for showing sync statuses and progress but it doesn't appear to
/// actually ever progress at all and just disappears after a bit."
///
/// Hermetic: `HAVEN_NO_NET` + `HAVEN_DEMO` (which seeds relays), with `HAVEN_QA_UPLOADS` scripting the
/// upload outcome so the real BackgroundUploader queue / progress / backoff machine runs without a
/// relay (see `BackgroundUploader.qaSimulated`). Same signing requirements as `HavenUITests`.
final class SyncProgressUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        SpringboardHygiene.dismissQueuedOpenPrompts()
    }

    private func app(uploads: String? = nil, scene: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        // Start from a wiped container (DEBUG-only `UITestMode` reset) so nothing a previous run
        // left on the simulator — posts, relay records, settings — leaks into this one.
        app.launchArguments += ["-UITestReset"]
        app.launchEnvironment["HAVEN_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["HAVEN_TAB"] = "circle"
        app.launchEnvironment["HAVEN_NO_NET"] = "1"
        app.launchEnvironment["HAVEN_DEMO"] = "1"
        if let uploads { app.launchEnvironment["HAVEN_QA_UPLOADS"] = uploads }
        if let scene { app.launchEnvironment["HAVEN_SCENE"] = scene }
        return app
    }

    private func badge(_ app: XCUIApplication, labelContains text: String? = nil) -> XCUIElement {
        let q = app.descendants(matching: .any).matching(identifier: "syncBadge")
        guard let text else { return q.firstMatch }
        return q.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func post(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["composeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 40), "the composer should be on screen")
        field.tap()
        field.typeText(text)
        app.buttons["composeSend"].tap()
    }

    /// Every launch re-publishes an epoch head for every circle. That is upkeep, not something the
    /// user did — it used to flash a count-less "Syncing…" pill on every open.
    func testMaintenanceOnlyUploadsNeverShowThePill() {
        let app = app(uploads: "ok")
        app.launch()
        XCTAssertTrue(app.textFields["composeField"].waitForExistence(timeout: 40))
        XCTAssertFalse(badge(app).waitForExistence(timeout: 10),
                       "the launch's epoch-head uploads must not raise the sync pill")
    }

    /// A post shows real progress, completes visibly ("Synced"), then the pill folds away.
    func testPostShowsSyncingThenSynced() {
        let app = app(uploads: "ok")
        app.launch()
        post(app, "progress pill check")
        let moving = app.descendants(matching: .any).matching(identifier: "syncBadge")
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Syncing", "Sending")).firstMatch
        XCTAssertTrue(moving.waitForExistence(timeout: 15), "a queued post should show the pill with its count")
        XCTAssertTrue(badge(app, labelContains: "Synced").waitForExistence(timeout: 45),
                      "the pill should say Synced once the post lands")
        XCTAssertTrue(badge(app).waitForNonExistence(timeout: 10), "then fold away")
    }

    /// A failed upload waits in backoff — and the pill says so, with the count, instead of vanishing.
    func testFailedUploadShowsRetryingWithCount() {
        let app = app(uploads: "fail")
        app.launch()
        post(app, "this one will not land")
        XCTAssertTrue(badge(app, labelContains: "Retrying (1 waiting)").waitForExistence(timeout: 60),
                      "a post waiting on the retry timer should say Retrying with its count")
        // Still there through the backoff AND the retry attempts it starts — it neither vanishes nor
        // flickers back to "Sending" per attempt.
        for _ in 0..<4 {
            sleep(2)
            XCTAssertTrue(badge(app, labelContains: "Retrying (1 waiting)").exists,
                          "Retrying must persist through the backoff and its retry passes")
        }
    }

    /// Peer-to-peer chunk progress reaches the placeholder (it never did: only relay restores
    /// reported i/n). `HAVEN_SCENE=transfer` feeds chunks through the real `finishChunk` path.
    func testPeerChunkProgressAdvances() {
        let app = app(scene: "transfer")
        app.launch()
        let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Downloading")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 40), "the placeholder should show Downloading… i/n")
        let first = Self.done(in: label.label)
        XCTAssertNotNil(first, "expected Downloading… i/n, got \(label.label)")
        // A chunk lands every 0.4s; give it a few seconds to visibly move.
        let advanced = NSPredicate { _, _ in (Self.done(in: label.label) ?? 0) > (first ?? .max) }
        let moved = expectation(for: advanced, evaluatedWith: nil)
        wait(for: [moved], timeout: 8)
    }

    /// "Downloading… 7/40" → 7
    private static func done(in label: String) -> Int? {
        guard let slash = label.lastIndex(of: "/") else { return nil }
        let head = label[..<slash].reversed().prefix { $0.isNumber }
        return Int(String(head.reversed()))
    }
}
