import Foundation
import Security

// The decision half of the seedless / self-sync key stores, split from the Keychain and Secure Enclave
// calls so the host-less logic tests can drive every state without an entitled Keychain.
//
// THE RULE these encode (see SeedlessStores.swift): a locked or erroring read is NEVER "absent". Only an
// explicit errSecItemNotFound is `notFound`; anything else that could still hold a real secret is
// `lockedOrError` / `seError`, and callers must not regenerate or delete on it. Getting this wrong
// resurrects the "content vanished" class of bug.

/// One `SecItemCopyMatching` outcome, reduced to what the decision needs.
enum KeychainRead: Equatable {
    /// errSecSuccess. `nil` when the item came back but its payload was not `Data`.
    case success(Data?)
    case notFound
    /// Any other status (errSecInteractionNotAllowed while locked, a corrupt store, …).
    case error

    init(status: OSStatus, item: CFTypeRef?) {
        switch status {
        case errSecSuccess: self = .success(item as? Data)
        case errSecItemNotFound: self = .notFound
        default: self = .error
        }
    }
}

/// The outcome of opening a Secure-Enclave-sealed blob (mirrors `SecureEnclaveBox.OpenResult`).
enum SealedKeyOpen: Equatable {
    case ok(Data)
    case missingKey, locked, failed
}

/// The account's public bundle (a trust anchor). A short or non-Data payload is an error, not absent.
enum AccountBundleLoad: Equatable {
    case found(Data), notFound, lockedOrError

    static let minimumBundleBytes = 32

    static func resolve(_ read: KeychainRead) -> AccountBundleLoad {
        switch read {
        case .success(let d):
            guard let d, d.count >= minimumBundleBytes else { return .lockedOrError }
            return .found(d)
        case .notFound: return .notFound
        case .error: return .lockedOrError
        }
    }
}

/// The granted self-sync key (seed-grade: it decrypts ALL account state).
enum SelfSyncKeyLoad: Equatable {
    case found(Data), notFound, lockedOrError, seError

    static let keyBytes = 32

    /// The SE-wrapped item takes precedence over any plaintext fallback (Simulator / no Enclave).
    static func resolve(wrapped: KeychainRead, open: (Data) -> SealedKeyOpen, plain: () -> KeychainRead) -> SelfSyncKeyLoad {
        switch wrapped {
        case .success(let cipher):
            guard let cipher else { return .lockedOrError }
            switch open(cipher) {
            case .ok(let key) where key.count == keyBytes: return .found(key)
            case .ok: return .seError                   // decrypted, wrong size — corrupt, not "new"
            case .locked: return .lockedOrError
            case .missingKey, .failed: return .seError  // key present but unreadable — a real secret exists
            }
        case .notFound:
            break                                       // no wrapped key → fall through to plaintext
        case .error:
            return .lockedOrError
        }
        switch plain() {
        case .success(let d):
            guard let d, d.count == keyBytes else { return .lockedOrError }
            return .found(d)
        case .notFound: return .notFound
        case .error: return .lockedOrError
        }
    }
}

/// The rotated self-sync key + epoch (§6 of the switch-flip plan).
enum SelfSyncEpochRules {
    /// The current rotated key, or nil when none is stored (v0 path) or the read is transiently
    /// unavailable — NEVER treated as "regenerate": there is no regenerating a primary-minted key.
    static func currentKey(wrapped: KeychainRead, open: (Data) -> SealedKeyOpen, plain: () -> KeychainRead) -> Data? {
        switch wrapped {
        case .success(let cipher):
            guard let cipher else { return nil }
            if case .ok(let key) = open(cipher), key.count == SelfSyncKeyLoad.keyBytes { return key }
            return nil
        case .notFound:
            break
        case .error:
            return nil
        }
        if case .success(let d?) = plain(), d.count == SelfSyncKeyLoad.keyBytes { return d }
        return nil
    }

    /// A received epoch grant is adopted only when STRICTLY NEWER (idempotent + newer-epoch-wins), so a
    /// replayed or stale grant can never roll the channel back to a key a revoked device still holds.
    static func shouldAdopt(epoch: UInt64, current: UInt64, key: Data) -> Bool {
        epoch > current && key.count == SelfSyncKeyLoad.keyBytes
    }
}
