import XCTest

/// First run (onboarding + the terms door) and the in-call overlay.
final class OnboardingAndCallUITests: HavenUITestCase {

    /// A brand-new install: welcome ▸ "I'm new" ▸ name ▸ how it works ▸ the terms ("I agree" is the
    /// only way in) ▸ the app, under the name you picked.
    func testFirstRunOnboardingThroughTerms() {
        let app = launch(tab: "you", extraArgs: ["-UITestOnboarding"])

        let new = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "I'm new to Haven")).firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 30), "a fresh install starts on the welcome screen")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add this as another of my devices")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Move my account to this device")).firstMatch.exists)
        new.tap()

        let next = element(app, "onboardingNext")
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertFalse(next.isEnabled, "a name is required before continuing")
        type("Avery", into: element(app, "onboardingName"))
        XCTAssertTrue(wait(next, until: "enabled == true"))
        next.tap()

        XCTAssertTrue(text(app, containing: "How Haven works").waitForExistence(timeout: 10))
        next.tap()

        let agree = element(app, "onboardingFinish")
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "the last step is the terms")
        XCTAssertEqual(agree.label, "I agree — enter Haven")
        agree.tap()

        // First run walks you to adding your first person; close that to see the app itself.
        let connect = app.navigationBars["Connect"]
        if connect.waitForExistence(timeout: 10) {
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(connect.waitForNonExistence(timeout: 10))
        }
        let name = element(app, "youDisplayName")
        XCTAssertTrue(name.waitForExistence(timeout: 20), "onboarding should land in the app")
        XCTAssertEqual(name.label, "Avery", "the You tab shows the name picked in onboarding")
    }

    /// The demo group call: mute toggles, Add someone lists who isn't on the call yet, minimize
    /// parks it in a Call tab that brings it back, and End call ends it.
    func testCallOverlayControls() {
        let app = launch(scene: "call")

        let mute = element(app, "callMute")
        XCTAssertTrue(mute.waitForExistence(timeout: 40), "the call scene should show its controls")
        XCTAssertEqual(mute.label, "Mute")
        mute.tap()
        XCTAssertTrue(wait(mute, until: "label == %@", "Unmute"), "muting flips the control, got \(mute.label)")
        mute.tap()
        XCTAssertTrue(wait(mute, until: "label == %@", "Mute"))

        element(app, "callAddPerson").tap()
        XCTAssertTrue(app.navigationBars["Add to call"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "Sam").waitForExistence(timeout: 5),
                      "Sam is in the circle but not on the call yet")
        app.navigationBars["Add to call"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add to call"].waitForNonExistence(timeout: 10))

        element(app, "callMinimize").tap()
        XCTAssertTrue(mute.waitForNonExistence(timeout: 10), "minimize hides the overlay")
        let callTab = app.buttons["Call"].firstMatch
        XCTAssertTrue(callTab.waitForExistence(timeout: 10), "a minimized call keeps a Call tab")
        callTab.tap()
        XCTAssertTrue(mute.waitForExistence(timeout: 10), "the Call tab brings the call back")

        element(app, "callEnd").tap()
        XCTAssertTrue(mute.waitForNonExistence(timeout: 10), "End call closes the overlay")
        XCTAssertTrue(app.buttons["Call"].firstMatch.waitForNonExistence(timeout: 10), "and the Call tab goes away")
    }
}
