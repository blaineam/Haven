import Foundation
import Security

/// Owns the user's Haven account. Persists only the 32-byte master seed in the
/// Keychain; the full identity (all hybrid-PQ keys) is derived from it on launch.
///
/// Multi-device: the seed can optionally sync across *your* Apple devices via iCloud
/// Keychain (Apple's E2E sync), and can be moved to any client (web/Android/another
/// phone) with a one-time transfer code / QR. The seed never touches a Haven server.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var account: Account
    /// True when the keychain was unreadable at init (e.g., launched before first unlock):
    /// we use a throwaway identity and DID NOT touch the real seed. `reloadIfTemporary()`
    /// swaps in the real one once the keychain is accessible.
    private(set) var usingTemporaryIdentity = false

    private static let service = "com.blaineam.kith"
    private static let seedKey = "account-master-seed"
    private static let syncDefaultsKey = "haven.icloud.identitySync"

    init() {
        switch Self.loadSeedStatus() {
        case .found(let seed):
            if let restored = try? Account.fromSeed(seed: seed) {
                account = restored
                // Re-store device-local. This also performs the Secure-Enclave migration: if the
                // seed came back from a legacy *plaintext* keychain item (or a synchronizable one),
                // `saveSeed` re-wraps it under the SE key and deletes the plaintext copy — so a
                // Keychain dump alone is useless after the first launch on this change. Also record
                // it in the recoverable identity history.
                Self.saveSeed(seed)
                Self.archive(seed)
                SharedSeed.write(seed)   // mirror into the shared group for the NSE
            } else {
                // Seed present but un-deriveable — NEVER overwrite it; use a temp identity.
                account = Account.generate(); usingTemporaryIdentity = true
            }
        case .notFound:
            // Genuinely a new install → make + save the first identity. (Only here do we write.)
            let fresh = Account.generate()
            Self.saveSeed(fresh.secretSeed())
            Self.archive(fresh.secretSeed())
            SharedSeed.write(fresh.secretSeed())
            account = fresh
        case .lockedOrError, .seError:
            // Keychain not accessible yet (locked / errSecInteractionNotAllowed), OR the seed is
            // SE-wrapped but the Enclave couldn't unwrap it right now (.seError — SE key locked,
            // ciphertext present but key unreadable, decrypt transiently failed). In EITHER case a
            // real seed almost certainly exists. Generating + saving here would DESTROY the real
            // identity — the bug that flipped your old content to "not me". Use a throwaway and
            // reload the real seed once unlocked. Do NOT save.
            account = Account.generate(); usingTemporaryIdentity = true
        }
    }

    /// Re-attempt loading the real seed (call when the app becomes active / keychain unlocks).
    func reloadIfTemporary() {
        guard usingTemporaryIdentity, case .found(let seed) = Self.loadSeedStatus(),
              let restored = try? Account.fromSeed(seed: seed) else { return }
        account = restored
        usingTemporaryIdentity = false
        SharedSeed.write(seed)
        FeedStore.shared.reconfigure(seed: account.secretSeed())
    }

    /// Wipe the identity and create a new one ("start over"). The old identity is archived to
    /// the history first, so it can still be rolled back to.
    func reset() {
        Self.archive(account.secretSeed())
        Self.deleteSeed()
        let fresh = Account.generate()
        Self.saveSeed(fresh.secretSeed())
        SharedSeed.write(fresh.secretSeed())
        account = fresh
        ProfileStore.shared.reloadForCurrentIdentity()   // a fresh identity starts with its own blank profile
        // Tear down the old engine + its on-disk social state so the new identity starts genuinely
        // clean — otherwise it inherits the previous identity's contacts, circles, DMs and posts.
        // (A user "starting over" to escape a compromise must not stay wired to the old social graph.)
        FeedStore.shared.reconfigure(seed: fresh.secretSeed())
        _ = SharedInbox.drain()          // discard the old identity's queued sealed push envelopes
        SharedLockedCircles.write([])     // old circle ids are meaningless (and leaky) to the new identity
    }

    // MARK: - Multi-device: iCloud Keychain sync

    static var iCloudSyncEnabled: Bool { UserDefaults.standard.bool(forKey: syncDefaultsKey) }

    /// The existing master seed if the user already has an identity — never creates one.
    /// Used by App Intents so they act as *this* account without spinning up a new one.
    static func storedSeed() -> Data? { loadSeed() }

    /// The node-id hex of the currently stored identity (empty if none/locked). Used to namespace
    /// per-identity data (the profile) so each identity keeps its own name/photo.
    static func currentNodeHex() -> String {
        guard let seed = loadSeed(), let acct = try? Account.fromSeed(seed: seed) else { return "" }
        return acct.nodeIdHex()
    }

    /// Turn iCloud Keychain identity sync on/off and re-store the seed accordingly.
    func setICloudSync(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.syncDefaultsKey)
        let seed = account.secretSeed()
        Self.deleteSeed()
        Self.saveSeed(seed, synced: on)
        SharedSeed.write(seed)
        // Migrate the recovery archive to match the new mode right away (SE-wrapped device-local
        // ⇄ plaintext synchronizable) so the toggle takes effect now, not on the next identity
        // change. `previousIdentities()` reads either form, so re-storing the current list is safe.
        Self.storeHistory(Self.previousIdentities())
    }

    // MARK: - Multi-device: transfer code / QR

    /// A one-time transfer code that encodes the master seed. Anyone holding it can
    /// become this identity — show it only to your own other device.
    /// A transfer/link code. Carries the seed AND the device's relay list so a freshly-linked device
    /// has a transport to bootstrap SelfSync from — without it the new device has the identity but no
    /// way to reach the shared mailbox/slots, so content never syncs (the "macOS detached from iPhone"
    /// bug). Falls back to the legacy seed-only form when there are no relays to share.
    private struct TransferPayload: Codable { let s: String; let r: [String] }

    func transferCode() -> String {
        let seedB64 = Self.base64url(account.secretSeed())
        let relays = RelayMailboxStore.shared.allRelays()
        guard !relays.isEmpty,
              let json = try? JSONEncoder().encode(TransferPayload(s: seedB64, r: relays)) else {
            return "haven-seed:" + seedB64
        }
        return "haven-link:" + Self.base64url(json)
    }

    /// Adopt an identity from a scanned/pasted transfer code. Returns false if invalid. Understands
    /// both the rich `haven-link:` form (seed + relays) and the legacy `haven-seed:` (seed only).
    @discardableResult
    func restore(fromTransferCode code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed: Data
        var bootstrapRelays: [String] = []
        if trimmed.hasPrefix("haven-link:") {
            let body = String(trimmed.dropFirst("haven-link:".count))
            guard let json = Self.base64urlDecode(body),
                  let payload = try? JSONDecoder().decode(TransferPayload.self, from: json),
                  let s = Self.base64urlDecode(payload.s), s.count == 32 else { return false }
            seed = s
            bootstrapRelays = payload.r
        } else if trimmed.hasPrefix("haven-seed:") {
            let body = String(trimmed.dropFirst("haven-seed:".count))
            guard let s = Self.base64urlDecode(body), s.count == 32 else { return false }
            seed = s
        } else {
            return false
        }
        guard let restored = try? Account.fromSeed(seed: seed) else { return false }
        Self.archive(account.secretSeed())   // keep the currently-active identity rollback-able first
        Self.deleteSeed()
        Self.saveSeed(seed, synced: Self.iCloudSyncEnabled)
        SharedSeed.write(seed)
        account = restored
        // Load THIS identity's world, not whatever the previous identity left in the engine/state file.
        FeedStore.shared.reconfigure(seed: seed)
        _ = SharedInbox.drain()
        SharedLockedCircles.write([])
        // Seed a transport so SelfSync can immediately bootstrap (pull slots + mailbox).
        if !bootstrapRelays.isEmpty { RelayMailboxStore.shared.adoptBootstrapRelays(bootstrapRelays) }
        return true
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    // MARK: - Keychain (Secure-Enclave-wrapped seed)
    //
    // The 32-byte master seed is never stored as readable bytes on a device that has a Secure
    // Enclave. Instead:
    //   • A P-256 key is generated *inside* the Secure Enclave (the private key never leaves it).
    //   • The seed is encrypted to that key's public half (ECIES X9.63 SHA-256 AES-GCM) and only
    //     the ciphertext blob lives in the Keychain.
    //   • On load the ciphertext is handed to the Enclave to decrypt; an attacker with a raw
    //     Keychain dump but no Enclave gets nothing.
    // Devices without an Enclave (the Simulator, very old hardware) fall back to the previous
    // plaintext-keychain item, kept byte-for-byte compatible so existing users aren't disturbed.
    //
    // The seed is ALWAYS device-local and NON-synchronizable in either representation. iCloud
    // Keychain must never carry the identity — a syncable seed let a fresh install on one device
    // roll another device's identity. Cross-device is only ever via an explicit, user-confirmed
    // transfer code. (SE-wrapped blobs are inherently device-bound: the Enclave key can't sync.)

    private static let wrappedSeedKey = "account-master-seed-se"            // ciphertext blob
    /// App-only Secure-Enclave key (default access group → unreachable by the NSE) that wraps the
    /// authoritative seed and the device-local recovery archive.
    private static let seedBox = SecureEnclaveBox(tag: "com.blaineam.kith.seed-se-key")

    /// Generic-password blobs live in the **data-protection keychain** (entitlement-governed → a single
    /// implicit grant for the app, no repeated "X wants to use your keychain" prompts on macOS) rather
    /// than the legacy file keychain. Reads fall back to the legacy keychain and migrate forward, so a
    /// pre-migration seed is never mistaken for "no identity". (SE keys are token-backed and unaffected.)
    private static func baseQuery(dataProtection: Bool = true) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: seedKey,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Keychain query for the SE-wrapped ciphertext blob (a generic-password item, distinct
    /// account from the legacy plaintext seed so the two can coexist during migration).
    private static func wrappedQuery(dataProtection: Bool = true) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: wrappedSeedKey,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Persist the seed. Prefers Secure-Enclave wrapping; falls back to a device-local plaintext
    /// item only when no Enclave is available. Always clears the *other* representation first so a
    /// migrated user never leaves a stale plaintext copy behind.
    private static func saveSeed(_ data: Data, synced: Bool = false) {
        deleteSeed()
        if wrapAndStore(data) { return }   // Secure-Enclave path (device hardware).
        // Fallback: no Secure Enclave (Simulator / unsupported) → plaintext, device-local only.
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadSeed() -> Data? {
        if case .found(let d) = loadSeedStatus() { return d }
        return nil
    }

    /// The load result must distinguish four cases so the init never wipes a real identity:
    ///   • `.found`        — seed is present and readable now.
    ///   • `.notFound`     — genuinely no seed (new install) → the only case allowed to generate.
    ///   • `.lockedOrError`— Keychain unreadable right now (locked / errSecInteractionNotAllowed).
    ///   • `.seError`      — an SE-wrapped seed exists but the Enclave couldn't unwrap it this
    ///                       launch (key locked, key missing, or decrypt failed). A real seed
    ///                       exists; treat exactly like `.lockedOrError` — temp identity, retry.
    private enum SeedStatus { case found(Data), notFound, lockedOrError, seError }

    private static func loadSeedStatus() -> SeedStatus {
        // 1. Secure-Enclave-wrapped seed takes precedence over any legacy plaintext copy.
        switch loadWrappedBlob() {
        case .found(let cipher):
            switch seedBox.open(cipher) {
            case .ok(let seed) where seed.count == 32:
                return .found(seed)
            case .ok:
                return .seError       // decrypted but wrong size — corrupt; never "new user".
            case .locked:
                return .lockedOrError // SE key present but locked — transient, retry on unlock.
            case .missingKey, .failed:
                // Ciphertext present but the Enclave key is gone or the decrypt failed. A real
                // identity exists; regenerating here would destroy it. Treat as transient.
                return .seError
            }
        case .locked:
            return .lockedOrError
        case .notFound:
            break   // no wrapped seed → fall through to the legacy plaintext item.
        }

        // 2. Legacy / fallback plaintext seed (pre-migration users, or Simulator/no-SE devices).
        func readPlain(dataProtection: Bool) -> (OSStatus, Data?) {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            return (SecItemCopyMatching(query as CFDictionary, &item), item as? Data)
        }
        let (dpStatus, dpData) = readPlain(dataProtection: true)
        if dpStatus == errSecSuccess { return dpData.map { .found($0) } ?? .lockedOrError }
        if dpStatus != errSecItemNotFound { return .lockedOrError }
        let (legStatus, legData) = readPlain(dataProtection: false)
        switch legStatus {
        case errSecSuccess:
            guard let d = legData else { return .lockedOrError }
            var add = baseQuery(dataProtection: true)
            add[kSecValueData as String] = d
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            let s = SecItemAdd(add as CFDictionary, nil)
            if s == errSecSuccess || s == errSecDuplicateItem {
                var del = baseQuery(dataProtection: false)
                del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
                SecItemDelete(del as CFDictionary)
            }
            return .found(d)
        case errSecItemNotFound: return .notFound
        default: return .lockedOrError   // errSecInteractionNotAllowed, etc. — don't clobber
        }
    }

    /// Deletes both seed representations (the SE-wrapped ciphertext and any plaintext copy). The
    /// Secure-Enclave private key itself is intentionally LEFT in place: it holds no identity (it
    /// only wraps the seed) and is reused for the next `saveSeed`, avoiding needless key churn.
    private static func deleteSeed() {
        // Clear both the data-protection AND legacy keychains so neither representation lingers.
        for dp in [true, false] {
            var query = baseQuery(dataProtection: dp)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny   // delete either variant
            SecItemDelete(query as CFDictionary)
            var wrapped = wrappedQuery(dataProtection: dp)
            wrapped[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            SecItemDelete(wrapped as CFDictionary)
        }
    }

    // MARK: - Secure Enclave wrapping

    private enum BlobStatus { case found(Data), notFound, locked }

    /// Read the SE-wrapped ciphertext blob, distinguishing absent from locked (same discipline as
    /// the seed itself — a locked read must never look like "no blob").
    private static func loadWrappedBlob() -> BlobStatus {
        func read(dataProtection: Bool) -> (OSStatus, Data?) {
            var q = wrappedQuery(dataProtection: dataProtection)
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            return (SecItemCopyMatching(q as CFDictionary, &item), item as? Data)
        }
        // Prefer the data-protection keychain.
        let (dpStatus, dpData) = read(dataProtection: true)
        if dpStatus == errSecSuccess { return dpData.map { .found($0) } ?? .locked }
        if dpStatus != errSecItemNotFound { return .locked }   // locked/error → never "absent"
        // Absent in the DP keychain → check the legacy keychain and migrate it forward if present.
        let (legStatus, legData) = read(dataProtection: false)
        switch legStatus {
        case errSecSuccess:
            guard let d = legData else { return .locked }
            var add = wrappedQuery(dataProtection: true)
            add[kSecValueData as String] = d
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            let s = SecItemAdd(add as CFDictionary, nil)
            if s == errSecSuccess || s == errSecDuplicateItem {
                var del = wrappedQuery(dataProtection: false)   // only drop legacy AFTER the DP copy lands
                del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
                SecItemDelete(del as CFDictionary)
            }
            return .found(d)
        case errSecItemNotFound: return .notFound
        default: return .locked
        }
    }

    /// Encrypt the seed to the Secure-Enclave key and persist the ciphertext blob (device-local,
    /// non-synchronizable). Returns false on any SE unavailability so `saveSeed` falls back to a
    /// plaintext item (Simulator / no-Enclave hardware only).
    private static func wrapAndStore(_ seed: Data) -> Bool {
        guard let cipher = seedBox.seal(seed) else { return false }
        var add = wrappedQuery()
        add[kSecValueData as String] = cipher
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    // MARK: - Recoverable identity history (for rolling back a changed identity)

    private static let historyKey = "account-identity-history"
    private static func historyQuery(dataProtection: Bool = true) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: historyKey]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Append a seed to the identity history (newest first, deduped, capped at 12). The history is
    /// a *recovery archive* of past identities, never the active one.
    ///
    /// At-rest protection mirrors the active seed: when the archive is device-local (the default)
    /// it is **Secure-Enclave-wrapped** so a Keychain dump reveals no past seeds either. The one
    /// case it can't be SE-wrapped is the opt-in iCloud-synced archive — an Enclave key is
    /// physically device-bound, so cross-device recovery requires the bytes to travel; there it
    /// stays synchronizable plaintext, protected by Apple's end-to-end iCloud Keychain. (The
    /// Simulator / no-Enclave hardware also takes the plaintext path.)
    static func archive(_ seed: Data) {
        let b64 = seed.base64EncodedString()
        var hist = previousIdentities()
        hist.removeAll { $0 == b64 }
        hist.insert(b64, at: 0)
        if hist.count > 12 { hist = Array(hist.prefix(12)) }
        storeHistory(hist)
    }

    /// Re-write the history list in whichever at-rest representation matches the *current*
    /// `iCloudSyncEnabled` setting: SE-wrapped device-local, or plaintext synchronizable. Used by
    /// `archive()` and by `setICloudSync` so a sync-toggle migrates the archive immediately rather
    /// than waiting for the next identity change.
    private static func storeHistory(_ hist: [String]) {
        guard let json = try? JSONEncoder().encode(hist) else { return }
        for dp in [true, false] {   // clear both keychains so no stale legacy archive lingers
            var del = historyQuery(dataProtection: dp); del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            SecItemDelete(del as CFDictionary)
        }

        let synced = iCloudSyncEnabled
        var add = historyQuery()
        if !synced, let sealed = seedBox.seal(json) {
            // Device-local → Secure-Enclave-wrapped, same as the live seed.
            add[kSecValueData as String] = sealed
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        } else {
            // iCloud-synced recovery archive (opt-in), or no Enclave → plaintext is unavoidable.
            add[kSecValueData as String] = json
            add[kSecAttrAccessible as String] = synced ? kSecAttrAccessibleAfterFirstUnlock
                                                       : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = synced ? kCFBooleanTrue! : kCFBooleanFalse!
        }
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Past identities (base64 seeds), newest first. Transparently reads both representations: a
    /// SE-wrapped device-local archive (unwrapped via `seedBox`) and a plaintext/synced JSON
    /// archive. Legacy plaintext archives are upgraded to SE-wrapped by the next `archive()` call.
    static func previousIdentities() -> [String] {
        func read(dataProtection: Bool) -> Data? {
            var q = historyQuery(dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            var item: CFTypeRef?
            return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
        }
        // DP keychain (covers synced + migrated archives) first, then the legacy keychain — the next
        // archive()/storeHistory writes it back to DP, so this only needs to keep recovery working.
        guard let d = read(dataProtection: true) ?? read(dataProtection: false) else { return [] }
        // Plaintext/synced JSON decodes directly; otherwise it's an SE-wrapped blob to open first.
        if let arr = try? JSONDecoder().decode([String].self, from: d) { return arr }
        if case .ok(let json) = seedBox.open(d),
           let arr = try? JSONDecoder().decode([String].self, from: json) { return arr }
        return []
    }

    // MARK: - Identity roster (switch between identities you've used)

    /// One entry in the identity switcher: the seed (base64), its node id, a friendly label, and
    /// whether it's the one currently in use.
    struct IdentitySummary: Identifiable {
        let seedB64: String
        let nodeHex: String
        let name: String
        let isCurrent: Bool
        var id: String { seedB64 }
    }

    /// Friendly labels for identities, keyed by node-id hex (the seed history only stores raw
    /// seeds). The current identity's label tracks the profile name; past ones keep what they were
    /// last called. Stored locally — the seeds themselves sync via iCloud Keychain when enabled.
    private static let labelsKey = "haven.identity.labels"
    static func identityLabels() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: labelsKey) as? [String: String]) ?? [:]
    }
    static func setIdentityLabel(_ name: String, forNodeHex hex: String) {
        guard !hex.isEmpty, !name.isEmpty else { return }
        var m = identityLabels(); m[hex] = name
        UserDefaults.standard.set(m, forKey: labelsKey)
    }

    /// The full roster: the active identity first, then every past identity (deduped), each labeled.
    func roster() -> [IdentitySummary] {
        let labels = Self.identityLabels()
        func label(_ hex: String) -> String {
            if let n = labels[hex], !n.isEmpty { return n }
            return "Identity " + String(hex.prefix(6))
        }
        let currentB64 = account.secretSeed().base64EncodedString()
        let currentHex = account.nodeIdHex()
        let profileName = ProfileStore.shared.displayName
        let currentName = profileName.isEmpty ? label(currentHex) : profileName
        var out = [IdentitySummary(seedB64: currentB64, nodeHex: currentHex, name: currentName, isCurrent: true)]
        var seen: Set<String> = [currentB64]
        for b64 in Self.previousIdentities() where !seen.contains(b64) {
            seen.insert(b64)
            guard let seed = Data(base64Encoded: b64), seed.count == 32,
                  let acct = try? Account.fromSeed(seed: seed) else { continue }
            out.append(IdentitySummary(seedB64: b64, nodeHex: acct.nodeIdHex(),
                                       name: label(acct.nodeIdHex()), isCurrent: false))
        }
        return out
    }

    /// Remember the active identity's current display name so it stays labeled after switching away.
    func rememberCurrentLabel() {
        Self.setIdentityLabel(ProfileStore.shared.displayName, forNodeHex: account.nodeIdHex())
    }

    /// Switch to a roster identity by its seed. Archives the current one first so it stays in the
    /// roster to switch back to. Returns false on a bad seed.
    @discardableResult
    func switchToIdentity(seedB64: String) -> Bool {
        rememberCurrentLabel()
        return restoreIdentity(seedB64)
    }

    /// Roll back to a previous identity from the history (current one is archived first).
    @discardableResult
    func restoreIdentity(_ b64: String) -> Bool {
        guard let seed = Data(base64Encoded: b64), seed.count == 32,
              let restored = try? Account.fromSeed(seed: seed) else { return false }
        Self.archive(account.secretSeed())
        Self.saveSeed(seed)
        SharedSeed.write(seed)
        account = restored
        FeedStore.shared.reconfigure(seed: account.secretSeed())
        ProfileStore.shared.reloadForCurrentIdentity()   // load this identity's own name/photo/bio
        return true
    }

    /// Forget a stored (non-active) identity: drop its seed from the recovery archive and its label.
    /// The active identity can't be deleted here — switch away first, or use `factoryReset()`.
    @discardableResult
    func deleteIdentity(seedB64: String) -> Bool {
        guard seedB64 != account.secretSeed().base64EncodedString() else { return false }
        var hist = Self.previousIdentities()
        let before = hist.count
        hist.removeAll { $0 == seedB64 }
        guard hist.count != before else { return false }
        Self.storeHistory(hist)
        if let seed = Data(base64Encoded: seedB64), let acct = try? Account.fromSeed(seed: seed) {
            var m = Self.identityLabels(); m[acct.nodeIdHex()] = nil
            UserDefaults.standard.set(m, forKey: Self.labelsKey)
        }
        return true
    }

    /// Factory reset: erase EVERYTHING — the active identity, every archived/recoverable identity
    /// (local + iCloud-synced), all labels, locked circles, queued push, and all social state — then
    /// start fresh with a single blank identity. Unlike `reset()`, nothing here is recoverable.
    func factoryReset() {
        Self.deleteSeed()
        var delHist = Self.historyQuery()
        delHist[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(delHist as CFDictionary)

        // Sweep EVERY persisted Haven preference so no screen keeps stale state (blocked list, circle
        // settings, hidden posts, contacts, relay/S3 config, photo-album links, last-heard, scheduled
        // posts, camera prefs, onboarding flags — all of it). A previous reset only cleared the seed +
        // a couple of keys, so half the app stayed populated.
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("haven.") { d.removeObject(forKey: key) }
        SharedLockedCircles.write([])
        _ = SharedInbox.drain()

        // Reset the in-memory singletons too, so the LIVE UI reverts now (not just after a relaunch).
        ConnectionsStore.shared.wipe()
        ContactsStore.shared.wipe()
        CircleSettingsStore.shared.wipe()
        RelayNudgeStore.shared.wipe()
        HiddenStore.shared.wipe()
        DMReadStore.shared.wipe()
        EmojiStore.shared.wipe()
        MediaStore.shared.clearMemoryCache()
        DeviceRosterManager.shared.stepDown()
        DeviceCredentialStore.clear()
        Self.deleteAllOnDiskMedia()

        // Back to a single blank identity AND the welcome/setup flow.
        let fresh = Account.generate()
        Self.saveSeed(fresh.secretSeed())
        SharedSeed.write(fresh.secretSeed())
        account = fresh
        ProfileStore.shared.reloadForCurrentIdentity()
        FeedStore.shared.reconfigure(seed: fresh.secretSeed())
        ProfileStore.shared.onboarded = false   // ← drops the user back on the welcome screen, fresh-install style
    }

    /// Delete every on-disk media file + cached avatar so a factory reset leaves nothing behind.
    private static func deleteAllOnDiskMedia() {
        let fm = FileManager.default
        guard let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? fm.removeItem(at: appSup.appendingPathComponent("haven-media", isDirectory: true))
        if let items = try? fm.contentsOfDirectory(at: appSup, includingPropertiesForKeys: nil) {
            for u in items where u.lastPathComponent.hasPrefix("haven-avatar") { try? fm.removeItem(at: u) }
        }
    }
}
