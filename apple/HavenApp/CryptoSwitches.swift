import Foundation
import Security

// Switch-Flip 1.0.7 — client-side persistence for the crypto enable-sequence (docs/SWITCH-FLIP-1.0.7.md).
//
// Every crypto switch (`set_mls_keying`, `set_seed_drop_retire`, `set_circle_creator`,
// `set_circle_live_lane`) is NON-PERSISTED session state and GATED in core — flipping one ON changes
// nothing on the wire until a whole circle (or the whole own-device fleet, for self-sync) is capable.
// The app re-applies them on every launch (`FeedStore.applyCryptoSwitches`). These three little stores
// hold the small amount of DURABLE bookkeeping the re-apply needs:
//   • CircleCreatorStore  — which circles I authored, so §2 re-pins my authority root each launch.
//   • SwitchFlipMigration — the one-time §1 account-leaf-retirement flag (don't rebroadcast every launch).
//   • SelfSyncEpochStore  — the §6 rotated self-sync key + epoch after a device revocation.

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

/// The ROTATED self-sync key + its epoch (§6). Absent (epoch 0) ⇒ NO rotation yet ⇒ the v0 path
/// (seed-derived for a primary, granted key for a seedless device) — byte-identical to 1.0.6. Present
/// (epoch ≥ 1) ⇒ seal/open switch to the v1 dual-key path (`seal_account_state_with_key_epoch` /
/// `open_account_state_dual` with an EMPTY seed_key, since rotation only fires once v0 authority is
/// retired). The key is seed-grade — it decrypts ALL account state — so it is Secure-Enclave-wrapped
/// exactly like `SelfSyncKeyStore`, with the same never-regenerate-on-a-failed-read discipline (a
/// locked/SE-error read is never mistaken for "no key"). Writers: the primary's revocation rotation
/// (mint) and a survivor accepting an epoch grant. Cleared on identity change (see SelfSyncCoordinator.reset).
enum SelfSyncEpochStore {
    private static let service = "com.blaineam.kith"
    private static let wrappedKey = "haven.selfsync-epoch-key-se.v1"   // SE ciphertext blob
    private static let plainKey = "haven.selfsync-epoch-key.v1"        // plaintext fallback (no Enclave)
    private static let epochKey = "haven.selfsync.epoch.v1"
    private static let box = SecureEnclaveBox(tag: "com.blaineam.kith.selfsync-epoch-se")

    /// The epoch currently honored (0 ⇒ no rotation ⇒ v0 path).
    static var epoch: UInt64 {
        let n = UserDefaults.standard.object(forKey: epochKey) as? NSNumber
        return n?.uint64Value ?? 0
    }

    private static func plainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: plainKey, kSecUseDataProtectionKeychain as String: true]
    }
    private static func wrappedQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: wrappedKey, kSecUseDataProtectionKeychain as String: true]
    }

    /// The current rotated key, or nil when none is stored (v0 path) or the read is transiently
    /// unavailable (locked / SE error — NEVER treated as "regenerate": there is no regenerating a
    /// primary-minted key). A nil here simply keeps the caller on whatever it can read this launch.
    static func currentKey() -> Data? {
        var wq = wrappedQuery(); wq[kSecReturnData as String] = true; wq[kSecMatchLimit as String] = kSecMatchLimitOne
        var wItem: CFTypeRef?
        switch SecItemCopyMatching(wq as CFDictionary, &wItem) {
        case errSecSuccess:
            guard let cipher = wItem as? Data else { return nil }
            if case .ok(let key) = box.open(cipher), key.count == 32 { return key }
            return nil
        case errSecItemNotFound:
            break   // fall through to plaintext fallback
        default:
            return nil
        }
        var pq = plainQuery(); pq[kSecReturnData as String] = true; pq[kSecMatchLimit as String] = kSecMatchLimitOne
        var pItem: CFTypeRef?
        if SecItemCopyMatching(pq as CFDictionary, &pItem) == errSecSuccess,
           let d = pItem as? Data, d.count == 32 { return d }
        return nil
    }

    /// Persist a rotated `key` at `epoch` (SE-wrapped, plaintext fallback only where no Enclave exists).
    static func save(epoch: UInt64, key: Data) {
        guard key.count == 32 else { return }
        SecItemDelete(wrappedQuery() as CFDictionary)
        SecItemDelete(plainQuery() as CFDictionary)
        if let cipher = box.seal(key) {
            var add = wrappedQuery()
            add[kSecValueData as String] = cipher
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            SecItemAdd(add as CFDictionary, nil)
        } else {
            var add = plainQuery()
            add[kSecValueData as String] = key
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            SecItemAdd(add as CFDictionary, nil)
        }
        UserDefaults.standard.set(NSNumber(value: epoch), forKey: epochKey)
    }

    /// Adopt a received epoch grant only when it is STRICTLY NEWER (idempotent + newer-epoch-wins), so a
    /// replayed or stale grant can never roll the channel back to a key a revoked device still holds.
    @discardableResult
    static func adoptIfNewer(epoch: UInt64, key: Data) -> Bool {
        guard epoch > self.epoch else { return false }
        save(epoch: epoch, key: key)
        return true
    }

    static func clear() {
        SecItemDelete(wrappedQuery() as CFDictionary)
        SecItemDelete(plainQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: epochKey)
    }
}
