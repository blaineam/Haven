import Foundation

// Durable client bookkeeping for the crypto enable-sequence (docs/SWITCH-FLIP-1.0.7.md), split from
// CryptoSwitches.swift (Keychain / Secure Enclave) so it runs in the host-less logic tests.

/// Circle IDs THIS account created. `set_circle_creator` (§2) is session state, not a persisted keying
/// decision, so it must be re-pinned on every launch — but only I can pin MY circles' creator (the pin
/// rides a self-grant signed by my account key). A linked device learns OTHER people's circle creators
/// from the propagated admin grant, so this only records circles I authored. Device-local; the default
/// "My Circle" is implicitly mine and handled by the caller.
enum CircleCreatorStore {
    private static let key = "haven.switchflip.myCircles.v1"

    static func markCreated(_ id: String) {
        guard !id.isEmpty else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard ids.insert(id).inserted else { return }
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    static func iCreated(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }
    /// Every circle I created — a value snapshot for the boot pass, which re-pins their creator off-main.
    static func createdIds() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// One-time migration bookkeeping for the §1 account-leaf retirement. `retire_account_leaf()` is
/// idempotent + gated in core (a no-op until the fleet is fully device-capable), so calling it every
/// launch is safe — this flag just avoids a needless roster rebroadcast once it has landed. The retire
/// switch itself is always ON in 1.0.7 on the primary (`set_seed_drop_retire(true)`); kept as a named
/// constant so the self-sync rotation gate reads clearly.
enum SwitchFlipMigration {
    private static let leafKey = "haven.switchflip.accountLeafRetired.v1"

    /// The seed-drop retirement master switch — ON in 1.0.7 on a seed-holding (primary) device.
    static let retireSwitchOn = true

    static var accountLeafRetired: Bool {
        get { UserDefaults.standard.bool(forKey: leafKey) }
        set { UserDefaults.standard.set(newValue, forKey: leafKey) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: leafKey) }
}
