import Foundation
import Security

// Switch-Flip 1.0.7 — client-side persistence for the crypto enable-sequence (docs/SWITCH-FLIP-1.0.7.md).
//
// Every crypto switch (`set_mls_keying`, `set_seed_drop_retire`, `set_circle_creator`,
// `set_circle_live_lane`) is NON-PERSISTED session state and GATED in core — flipping one ON changes
// nothing on the wire until a whole circle (or the whole own-device fleet, for self-sync) is capable.
// The app re-applies them on every launch (`FeedStore.postBootPass`). These three little stores
// hold the small amount of DURABLE bookkeeping the re-apply needs:
//   • CircleCreatorStore  — which circles I authored, so §2 re-pins my authority root each launch.
//   • SwitchFlipMigration — the one-time §1 account-leaf-retirement flag (don't rebroadcast every launch).
//   • SelfSyncEpochStore  — the §6 rotated self-sync key + epoch after a device revocation.

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
        func read(_ query: [String: Any]) -> KeychainRead {
            var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            return KeychainRead(status: status, item: item)
        }
        return SelfSyncEpochRules.currentKey(
            wrapped: read(wrappedQuery()),
            open: { cipher in
                switch box.open(cipher) {
                case .ok(let key): return .ok(key)
                case .missingKey: return .missingKey
                case .locked: return .locked
                case .failed: return .failed
                }
            },
            plain: { read(plainQuery()) })
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
        guard SelfSyncEpochRules.shouldAdopt(epoch: epoch, current: self.epoch, key: key) else { return false }
        save(epoch: epoch, key: key)
        return true
    }

    static func clear() {
        SecItemDelete(wrappedQuery() as CFDictionary)
        SecItemDelete(plainQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: epochKey)
    }
}
