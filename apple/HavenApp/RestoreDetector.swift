import Foundation
import Security

/// Detects "this install was restored from a device backup onto a DIFFERENT device" (iCloud restore,
/// Quick Start, an encrypted Finder backup) — the upgrade-to-a-new-iPhone case.
///
/// Why it matters: a restore brings back UserDefaults and Application Support (the onboarded flag,
/// `haven-feed.json`, the device roster, the plaintext device-key mirror) but drops every
/// `…ThisDeviceOnly` keychain item and the Secure-Enclave key. Before this, the app read the missing
/// seed as "genuinely a new install", minted a stranger identity, skipped onboarding (the flag
/// survived), and merged the old account's state file into it — while the old phone's device key
/// came back from UserDefaults, so two phones shared one device id.
///
/// Mechanism: a random install sentinel lives in BOTH a device-local keychain item and UserDefaults.
/// A restore to a new device carries the UserDefaults half but not the keychain half. A delete +
/// reinstall on the same device is the opposite (keychain survives, defaults don't) and is not a
/// restore. Backups taken before the sentinel existed are caught by the same asymmetry on the device
/// key: the app had been onboarded, yet the device-local device-key item is gone.
///
/// Evaluated once per process, before anything mints a device key or an account seed.
enum RestoreDetector {
    /// True when this process is the first launch after a restore onto a new device.
    static let wasRestoredToNewDevice: Bool = evaluate()

    private static let service = "com.blaineam.kith"
    private static let sentinelAccount = "haven.install-sentinel"
    private static let sentinelDefaultsKey = "haven.installSentinel.v1"
    /// Matches `DeviceKeyStore.accountKey` — read-only here, as pre-sentinel restore evidence.
    private static let deviceKeyAccount = "haven.device-key-seed"

    private enum ItemStatus { case found(Data), notFound, lockedOrError }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }

    private static func read(_ account: String) -> ItemStatus {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &item) {
        case errSecSuccess: return (item as? Data).map { .found($0) } ?? .lockedOrError
        case errSecItemNotFound: return .notFound
        default: return .lockedOrError
        }
    }

    private static func evaluate() -> Bool {
        #if DEBUG
        // "1" = a restore that carried the backup escrow; "2" = one that didn't (older backup / opted out).
        switch ProcessInfo.processInfo.environment["HAVEN_SIMULATE_DEVICE_RESTORE"] {
        case "1": simulateRestoreToNewDevice(keepEscrow: true)
        case "2": simulateRestoreToNewDevice(keepEscrow: false)
        default: break
        }
        #endif
        let defaults = UserDefaults.standard
        switch read(sentinelAccount) {
        case .found(let v):
            // Steady state. Heal the defaults half if it went missing (a pre-sentinel install).
            let b64 = v.base64EncodedString()
            if defaults.string(forKey: sentinelDefaultsKey) != b64 { defaults.set(b64, forKey: sentinelDefaultsKey) }
            return false
        case .lockedOrError:
            // Can't tell right now. Deciding "restored" on a locked read would throw away a live
            // device's state, so a locked launch is never a restore; the next unlocked launch decides.
            return false
        case .notFound:
            let defaultsSurvived = defaults.string(forKey: sentinelDefaultsKey) != nil
            // Pre-sentinel backups: the app was set up, but the device-local device key is gone.
            // (An existing install upgrading to this build still has its device key → not a restore.)
            var deviceKeyGone = false
            if case .notFound = read(deviceKeyAccount) { deviceKeyGone = true }
            // The restored feed file is required too: the defaults domain alone can outlive an
            // uninstall (the preferences daemon caches it), a restored Application Support can't.
            let feedRestored = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("haven-feed.json").path) } ?? false
            let pristineOnboarded = defaults.bool(forKey: "haven.onboarded") && deviceKeyGone && feedRestored
            // Plant the sentinel. If the keychain can't persist it (unsigned Simulator QA builds),
            // leave the defaults half unset too — this detector must never fire in that environment.
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, 16, &bytes) == errSecSuccess else { return false }
            var add = query(sentinelAccount)
            add[kSecValueData as String] = Data(bytes)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
            defaults.set(Data(bytes).base64EncodedString(), forKey: sentinelDefaultsKey)
            let restored = defaultsSurvived || pristineOnboarded
            if restored { HavenLog.net("RestoreDetector: restored onto a new device (sentinel=\(defaultsSurvived))") }
            return restored
        }
    }

    /// Drop the restored state that belongs to the OLD device, never to this one: its device key
    /// mirror, its linked-device credential, and its seedless enrollment (whose device-local secrets
    /// did not come across, so the flag would strand this device as a seedless shell).
    static func forgetPreviousDeviceState() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "haven.deviceKeySeed.v1")
        d.removeObject(forKey: "haven.ephemeralSeed.v1")
        DeviceCredentialStore.clear()
        SeedlessState.disable()
        SeedlessRosterStore.clear()
    }

    #if DEBUG
    /// QA: reproduce what a restore onto a NEW device leaves behind — every `ThisDeviceOnly` item
    /// gone, the migratable backup escrow (and UserDefaults / Application Support) intact.
    private static func simulateRestoreToNewDevice(keepEscrow: Bool) {
        let deviceOnly = ["account-master-seed", "account-master-seed-se", "account-identity-history",
                          deviceKeyAccount, sentinelAccount, "haven.account-public-bundle.v1"]
            + (keepEscrow ? [] : ["account-master-seed-backup"])
        for acct in deviceOnly {
            var q = query(acct)
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            SecItemDelete(q as CFDictionary)
        }
        HavenLog.net("RestoreDetector: SIMULATED restore — device-only keychain items wiped")
    }
    #endif
}
