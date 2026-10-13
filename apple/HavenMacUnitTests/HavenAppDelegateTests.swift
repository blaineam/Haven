import XCTest
import AppKit
@testable import HavenUITestHost

/// The native Mac app delegate's entry points (a separate instance, so the host's own delegate is
/// untouched): when closing the last window quits, what a dock click does, and that push registration
/// and remote notifications are accepted with no network behind them.
@MainActor
final class HavenAppDelegateTests: XCTestCase {
    override func setUp() async throws { _ = await Harness.feed() }

    func testClosingTheLastWindowQuitsUnlessARelayOrACallNeedsTheApp() {
        let delegate = HavenAppDelegate()
        XCTAssertFalse(RelayHost.shared.enabled, "the isolated host never runs a relay")
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
                      "a plain Mac app quits when its last window closes")
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false),
                      "a dock click re-creates the window")
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .regular, "…and the app is a normal, visible app again")
    }

    func testPushRegistrationAndRemoteNotificationsNeedNoNetworkToBeAccepted() async {
        let delegate = HavenAppDelegate()
        delegate.application(NSApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: Data([0x01, 0x02, 0xab]))
        delegate.application(NSApplication.shared, didFailToRegisterForRemoteNotificationsWithError: URLError(.notConnectedToInternet))
        // A call doorbell it can't decrypt still surfaces something; a worker-dropped body triggers a sync;
        // a re-mint ask is forwarded; an undecodable inline event is ignored.
        delegate.application(NSApplication.shared, didReceiveRemoteNotification: ["call": 1])
        delegate.application(NSApplication.shared, didReceiveRemoteNotification: ["remint": true, "ev": "%%% not base64 %%%"])
        delegate.application(NSApplication.shared, didReceiveRemoteNotification: [:])
        // The handlers hop to the main actor; once the store has settled the host is still healthy.
        let store = await Harness.feed()
        await Harness.until(store, "the host is still configured after the pushes") { store.isConfigured }
    }
}
