import Foundation
import Security

/// Wraps arbitrary small secrets (here: 32-byte master seeds) with a **non-extractable P-256 key
/// held in the Secure Enclave**. The private key never leaves the Enclave; only ECIES ciphertext
/// is ever written to the Keychain, so a raw Keychain dump is useless without *this device's*
/// Enclave.
///
/// One box == one Enclave key, identified by an application `tag` and optionally pinned to a
/// Keychain `accessGroup` so a sibling process — e.g. the Notification Service Extension — can
/// share it (the app creates + seals; the extension only opens). Devices with no Secure Enclave
/// (the Simulator, very old hardware) report `isAvailable == false`; every caller keeps a
/// plaintext fallback for those.
///
/// Compiled into the main app AND the NSE (both include `Shared/`), so the same wrap/unwrap logic
/// backs the authoritative seed, the recovery archive, and the NSE's shared mirror.
struct SecureEnclaveBox {
    let tag: Data
    /// Full keychain access group (team-prefixed), or nil for the target's default group.
    let accessGroup: String?

    init(tag: String, accessGroup: String? = nil) {
        self.tag = Data(tag.utf8)
        self.accessGroup = accessGroup
    }

    /// True in the QA stub (`com.blaineam.kith.qa.stub`): every keychain touch must stay in the
    /// DATA-PROTECTION keychain. The stub binary is re-signed on every QA build, and any legacy
    /// (login-file) keychain access — including the persistent item macOS creates for a
    /// permanent SE key when no DP flag is given, and every legacy-fallback read probe — hits
    /// items whose per-binary ACL no longer matches, so macOS throws the "HavenStub wants to use
    /// your keychain" approval dialog on every rebuilt stub. DP-keychain items are governed by
    /// the `keychain-access-groups` entitlement (`…qa.stub` in Haven.macOS.stub.entitlements),
    /// so a team-signed rebuild never re-prompts — same storage strength, zero dialogs.
    /// Production deliberately keeps its legacy fallbacks (migration of pre-DP items); the flag
    /// only ever ADDS the DP constraint for the stub.
    static let dataProtectionKeychainOnly = Bundle.main.bundleIdentifier?.contains("qa.stub") == true

    private static let algorithm: SecKeyAlgorithm = .eciesEncryptionStandardX963SHA256AESGCM

    /// False where no Secure Enclave exists (Simulator). Callers fall back to plaintext storage.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    // MARK: - Key access

    /// Load the persistent Enclave private key, returning the raw OSStatus so callers can tell
    /// "missing" (`errSecItemNotFound`) from "locked" (`errSecInteractionNotAllowed`) — the same
    /// distinction the seed-load path relies on to never overwrite a real identity.
    func privateKey() -> (SecKey?, OSStatus) {
        var q: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecReturnRef as String: true,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        // QA stub: search the DP keychain only — a legacy-keychain probe is a prompt (see above).
        if Self.dataProtectionKeychainOnly { q[kSecUseDataProtectionKeychain as String] = true }
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &ref)
        guard status == errSecSuccess, let r = ref else { return (nil, status) }
        return ((r as! SecKey), status)
    }

    /// The public key to encrypt against — loading the existing Enclave key, or (only when
    /// `creatingIfNeeded` AND the key is genuinely absent) creating it. Returns nil when there's
    /// no Enclave, on a locked read, or on creation failure. A locked read never spawns a second
    /// key (that would be unable to open the existing ciphertext).
    func publicKey(creatingIfNeeded: Bool) -> SecKey? {
        guard Self.isAvailable else { return nil }
        let (existing, status) = privateKey()
        if let existing { return SecKeyCopyPublicKey(existing) }
        guard creatingIfNeeded, status == errSecItemNotFound else { return nil }

        var acError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,                     // usable after first unlock; no biometric prompt.
            &acError
        ) else { return nil }

        var keyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,           // persist in the Keychain.
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessControl as String: access,
        ]
        // Pin the key to the shared group when requested so a sibling process can open with it.
        if let accessGroup { keyAttrs[kSecAttrAccessGroup as String] = accessGroup }
        // QA stub: persist the key's item in the DP keychain, never the login file keychain —
        // a login-keychain key item is exactly the per-binary-ACL item that prompts on rebuild.
        if Self.dataProtectionKeychainOnly { keyAttrs[kSecUseDataProtectionKeychain as String] = true }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: keyAttrs,
        ]
        if Self.dataProtectionKeychainOnly { attributes[kSecUseDataProtectionKeychain as String] = true }
        var keyError: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
            return nil   // Hardware without a usable Enclave → caller falls back to plaintext.
        }
        return SecKeyCopyPublicKey(priv)
    }

    // MARK: - Seal / open

    /// Encrypt `plaintext` to the Enclave key, creating the key on first use. nil → no Enclave or
    /// any failure, signalling the caller to use its plaintext fallback.
    func seal(_ plaintext: Data) -> Data? {
        guard let pub = publicKey(creatingIfNeeded: true),
              SecKeyIsAlgorithmSupported(pub, .encrypt, Self.algorithm) else { return nil }
        var err: Unmanaged<CFError>?
        return SecKeyCreateEncryptedData(pub, Self.algorithm, plaintext as CFData, &err) as Data?
    }

    /// The outcome of opening a sealed blob. Every non-`.ok` case means "an identity exists but we
    /// couldn't read it right now" — callers must treat them as transient, never as "new user".
    enum OpenResult { case ok(Data), missingKey, locked, failed }

    /// Decrypt a sealed blob with the Enclave private key.
    func open(_ ciphertext: Data) -> OpenResult {
        let (priv, status) = privateKey()
        guard let priv else {
            return status == errSecItemNotFound ? .missingKey : .locked
        }
        guard SecKeyIsAlgorithmSupported(priv, .decrypt, Self.algorithm) else { return .failed }
        var err: Unmanaged<CFError>?
        guard let data = SecKeyCreateDecryptedData(priv, Self.algorithm, ciphertext as CFData, &err) as Data? else {
            return .failed
        }
        return .ok(data)
    }
}
