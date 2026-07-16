import Foundation
import Security

// Seed-drop S4 (seedless enrollment) — Apple persistence (plan §5, Apple column).
//
// A seedless device holds NO account master seed. Its authoritative identity is the DEVICE key
// (DeviceKeyStore) plus:
//   • the account PUBLIC bundle           — AccountPublicStore (the trust anchor it verifies against)
//   • a granted 32-byte self-sync key      — SelfSyncKeyStore (seed-grade; decrypts all account state)
//   • its account-signed credential        — DeviceCredentialStore (existing, DeviceRoster.swift)
//   • the primary-signed roster wire        — persisted verbatim in the engine (ingestRosterWire)
//
// The two new secrets copy the exact four-state load discipline of `AccountStore.loadSeedStatus`
// (locked/`.seError` ≠ absent, never regenerate, never delete on a failed read) — the only writer
// is enrollment-grant acceptance. Getting this wrong resurrects the "content vanished" class of bug.

/// Persisted "this device runs seedless" flag. Set only by a completed enrollment grant; cleared
/// only by a factory reset / adopting a seeded identity. When true, `AccountStore.storedSeed()`
/// returns nil (so every seed-holder-only path — authoring a roster, authorizing a device, sealing
/// self-sync from the seed — correctly no-ops) and identity reads come from the account PUBLIC bundle.
enum SeedlessState {
    private static let key = "haven.account.seedless.v1"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
    static func enable() { UserDefaults.standard.set(true, forKey: key) }
    static func disable() { UserDefaults.standard.removeObject(forKey: key) }
}

/// A seedless device's copy of the account PUBLIC bundle (the primary's `HavenId` public half —
/// authorship anchor, contact id, roster/credential verification key). Tamper-integrity matters
/// more than secrecy, so it lives in the device-local data-protection keychain with the SAME
/// four-state discipline as the account seed: a locked/error read is NEVER mistaken for "absent",
/// and nothing here regenerates or deletes on a failed read — only the enrollment grant writes it.
enum AccountPublicStore {
    private static let service = "com.blaineam.kith"
    private static let bundleKey = "haven.account-public-bundle.v1"

    /// Distinguish present-and-readable from absent from unreadable-right-now, so a locked read can
    /// never look like "no account" and drop a seedless device back into linking mode.
    enum LoadStatus { case found(Data), notFound, lockedOrError }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: bundleKey, kSecUseDataProtectionKeychain as String: true]
    }

    static func loadStatus() -> LoadStatus {
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &item) {
        case errSecSuccess:
            guard let d = item as? Data, d.count >= 32 else { return .lockedOrError }
            return .found(d)
        case errSecItemNotFound:
            return .notFound
        default:
            return .lockedOrError   // errSecInteractionNotAllowed etc. — never "absent"
        }
    }

    static func load() -> Data? { if case .found(let d) = loadStatus() { return d }; return nil }

    /// The account node hex = hex(bundle[0..<32]) — the same derivation the hello path uses.
    static func hex() -> String {
        guard let b = load() else { return "" }
        return b.prefix(32).map { String(format: "%02x", $0) }.joined()
    }

    /// Only enrollment-grant acceptance writes this. Device-local, non-synchronizable.
    static func save(_ bundle: Data) {
        SecItemDelete(query() as CFDictionary)
        var add = query()
        add[kSecValueData as String] = bundle
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(query() as CFDictionary) }
}

/// The primary-signed device-roster WIRE bytes, persisted VERBATIM (incl. the `SeedDropCapability`
/// trailer). A seedless device rebroadcasts these EXACT bytes — re-encoding would strip the trailer
/// and stall the circle's capability convergence (plan §7, capability-trailer fidelity). Not secret
/// (it's account-signed public data), so plain UserDefaults; the engine also persists it in its
/// exported state, this is the belt-and-suspenders copy that survives an engine-state wipe.
enum SeedlessRosterStore {
    private static let key = "haven.seedless.rosterWire.v1"
    static func save(_ wire: Data) { UserDefaults.standard.set(wire, forKey: key) }
    static func load() -> Data? { UserDefaults.standard.data(forKey: key) }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// The granted 32-byte self-sync key — the secret that decrypts ALL of this account's self-synced
/// state (profile, contacts, circles, settings). It is seed-grade: Secure-Enclave-wrapped exactly
/// like the account master seed, with the four-state load discipline so a locked Enclave / transient
/// decrypt failure is never mistaken for "no key" (which would strand the device's state and, worse,
/// tempt a regenerate that can never reproduce the primary's key). The ONLY writer is the enrollment
/// grant. Devices without a Secure Enclave (Simulator) fall back to a device-local plaintext item.
enum SelfSyncKeyStore {
    private static let service = "com.blaineam.kith"
    private static let wrappedKey = "haven.selfsync-key-se.v1"   // SE ciphertext blob
    private static let plainKey = "haven.selfsync-key.v1"        // plaintext fallback (no Enclave)
    private static let box = SecureEnclaveBox(tag: "com.blaineam.kith.selfsync-key-se")

    /// Four states, mirroring `AccountStore.loadSeedStatus`:
    ///   • `.found`        — key present + readable now.
    ///   • `.notFound`     — genuinely no key (never enrolled seedless).
    ///   • `.lockedOrError`— keychain unreadable right now (locked / errSecInteractionNotAllowed).
    ///   • `.seError`      — an SE-wrapped key exists but the Enclave couldn't unwrap it this launch.
    /// A real key exists in the last two; a caller must NEVER regenerate or delete on them.
    enum LoadStatus { case found(Data), notFound, lockedOrError, seError }

    private static func plainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: plainKey, kSecUseDataProtectionKeychain as String: true]
    }
    private static func wrappedQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: wrappedKey, kSecUseDataProtectionKeychain as String: true]
    }

    static func loadStatus() -> LoadStatus {
        // 1. SE-wrapped ciphertext takes precedence over any plaintext fallback.
        var wq = wrappedQuery(); wq[kSecReturnData as String] = true; wq[kSecMatchLimit as String] = kSecMatchLimitOne
        var wItem: CFTypeRef?
        switch SecItemCopyMatching(wq as CFDictionary, &wItem) {
        case errSecSuccess:
            guard let cipher = wItem as? Data else { return .lockedOrError }
            switch box.open(cipher) {
            case .ok(let key) where key.count == 32: return .found(key)
            case .ok: return .seError                  // decrypted, wrong size — corrupt, not "new".
            case .locked: return .lockedOrError
            case .missingKey, .failed: return .seError // key present but unreadable — real secret exists.
            }
        case errSecItemNotFound:
            break   // no wrapped key → fall through to the plaintext item.
        default:
            return .lockedOrError
        }
        // 2. Plaintext fallback (Simulator / no-Enclave hardware).
        var pq = plainQuery(); pq[kSecReturnData as String] = true; pq[kSecMatchLimit as String] = kSecMatchLimitOne
        var pItem: CFTypeRef?
        switch SecItemCopyMatching(pq as CFDictionary, &pItem) {
        case errSecSuccess:
            guard let d = pItem as? Data, d.count == 32 else { return .lockedOrError }
            return .found(d)
        case errSecItemNotFound:
            return .notFound
        default:
            return .lockedOrError
        }
    }

    static func load() -> Data? { if case .found(let k) = loadStatus() { return k }; return nil }

    /// Persist the granted key. Prefers Secure-Enclave wrapping; falls back to a device-local
    /// plaintext item only where no Enclave exists. Clears the other representation first. Only
    /// enrollment-grant acceptance calls this.
    static func save(_ key: Data) {
        guard key.count == 32 else { return }
        SecItemDelete(wrappedQuery() as CFDictionary)
        SecItemDelete(plainQuery() as CFDictionary)
        if let cipher = box.seal(key) {
            var add = wrappedQuery()
            add[kSecValueData as String] = cipher
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            SecItemAdd(add as CFDictionary, nil)
            return
        }
        var add = plainQuery()
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(wrappedQuery() as CFDictionary)
        SecItemDelete(plainQuery() as CFDictionary)
    }
}
