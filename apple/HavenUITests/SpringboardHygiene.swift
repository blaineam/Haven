import XCTest

/// Clear SpringBoard's queued "Open in “Haven”?" prompts before a test launches the app.
///
/// The cross-device e2e harness wakes the app with `xcrun simctl openurl … haven://qa` every few
/// seconds, and on the iOS 27 simulator each of those asks SpringBoard to confirm. Nobody answers
/// them during an e2e run, so they QUEUE — a gate's release run on the same simulator found ~70 of
/// them waiting. XCUITest's default interruption handler cancels ~10 per interaction and then gives
/// up ("Did not handle the interruption, but will attempt to continue…"), so the next `typeText`
/// found no keyboard focus behind the prompt and `testChipMenuSendPrivately` failed on a
/// simulator whose only fault was its history. Draining them up front makes every test start from
/// a quiet SpringBoard; it asserts nothing about the app and waits only while prompts keep coming.
enum SpringboardHygiene {
    static func dismissQueuedOpenPrompts(timeout: TimeInterval = 120) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = springboard.alerts.matching(NSPredicate(format: "label BEGINSWITH %@", "Open in")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, prompt.waitForExistence(timeout: 1) {
            let cancel = prompt.buttons["Cancel"]
            if cancel.exists { cancel.tap() } else { prompt.buttons.firstMatch.tap() }
        }
    }
}
