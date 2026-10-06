import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// Deterministic UI-test mode (XCUITest), DEBUG builds only.
///
/// Launch with `-UITestMode` (or `HAVEN_UI_TEST=1`) and the app behaves exactly as the screenshot
/// harness flags would make it — `HAVEN_DEMO` + `HAVEN_NO_NET` + `HAVEN_SKIP_ONBOARDING` — without a
/// test having to spell all three, and with animations off so assertions don't race transitions.
/// Add `-UITestReset` (or `HAVEN_UI_TEST_RESET=1`) to start from a wiped container first, so every
/// launch sees the same seeded state instead of whatever the previous run left on the simulator.
/// `-UITestOnboarding` keeps the mode but leaves the demo cast out and onboarding in, for the
/// first-run test.
///
/// Every switch here is compiled out of Release: `isOn` and `wantsReset` are constant `false`, so a
/// shipped build behaves byte-for-byte as before no matter what it is launched with.
enum UITestMode {
    private static var args: [String] { ProcessInfo.processInfo.arguments }
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// True for a UI-test launch of a DEBUG build.
    static let isOn: Bool = {
        #if DEBUG
        return args.contains("-UITestMode") || env["HAVEN_UI_TEST"] == "1"
        #else
        return false
        #endif
    }()

    /// The first-run test: UI-test mode, but with onboarding (and no demo cast) left in.
    static let onboardingFlow: Bool = {
        #if DEBUG
        return isOn && args.contains("-UITestOnboarding")
        #else
        return false
        #endif
    }()

    /// Seed the demo cast (`HAVEN_DEMO` implied).
    static var impliesDemo: Bool { isOn && !onboardingFlow }
    /// Skip onboarding and the terms gate (`HAVEN_SKIP_ONBOARDING` implied).
    static var skipsOnboarding: Bool { isOn && !onboardingFlow }

    /// Wipe this app's own state before anything reads it.
    static let wantsReset: Bool = {
        #if DEBUG
        return args.contains("-UITestReset") || env["HAVEN_UI_TEST_RESET"] == "1"
        #else
        return false
        #endif
    }()

    private static var didApply = false

    /// Call first thing in `App.init`, before any store singleton touches disk or the keychain.
    static func applyAtLaunch() {
        #if DEBUG
        guard isOn || wantsReset, !didApply else { return }
        didApply = true
        if wantsReset { resetOwnState() }
        if isOn {
            #if canImport(UIKit) && !os(watchOS)
            UIView.setAnimationsEnabled(false)
            #endif
        }
        #endif
    }

    #if DEBUG
    /// Only ever on a simulator, or in the macOS UI-test host (its own bundle id and container).
    /// Never in the personal `com.blaineam.kith` Mac app or the e2e fleet's `qa.stub`.
    private static var resetAllowed: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return Bundle.main.bundleIdentifier?.hasSuffix(".uitesthost") == true
        #endif
    }

    private static func resetOwnState() {
        guard resetAllowed else {
            NSLog("[UITestMode] reset refused: not a simulator or the UI-test host")
            return
        }
        let fm = FileManager.default
        // The app's own container: Application Support, Documents, Caches, tmp, Preferences stay
        // — Preferences go through UserDefaults below so cfprefsd doesn't hand the old values back.
        var dirs: [URL] = []
        for d in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory, .cachesDirectory] {
            if let u = fm.urls(for: d, in: .userDomainMask).first { dirs.append(u) }
        }
        dirs.append(fm.temporaryDirectory)
        #if os(iOS) && targetEnvironment(simulator)
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.blaineam.kith") {
            dirs.append(group)
        }
        #endif
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent != "Preferences" {
                try? fm.removeItem(at: item)
            }
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        #if os(iOS) && targetEnvironment(simulator)
        UserDefaults(suiteName: "group.com.blaineam.kith")?.removePersistentDomain(forName: "group.com.blaineam.kith")
        #endif
        // Keychain: only the data-protection keychain, which is scoped to this app's own access
        // groups. (On macOS the legacy file keychain is the user's login keychain — never touched.)
        for cls in [kSecClassGenericPassword, kSecClassKey, kSecClassInternetPassword] {
            var q: [String: Any] = [kSecClass as String: cls,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
            #if os(macOS)
            q[kSecUseDataProtectionKeychain as String] = true
            #endif
            SecItemDelete(q as CFDictionary)
        }
    }
    #endif
}
