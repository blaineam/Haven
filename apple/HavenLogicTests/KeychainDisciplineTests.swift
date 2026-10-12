import XCTest
import Security

/// The load discipline behind the seedless / self-sync key stores. The one rule: a locked or erroring
/// read is NEVER "absent". Treating it as absent makes the app regenerate (or delete) a seed-grade
/// secret that was merely unreadable for a moment, which is the "content vanished" class of bug.
final class KeychainDisciplineTests: XCTestCase {
    private let key32 = Data(repeating: 7, count: 32)

    // MARK: KeychainRead mapping

    func testStatusMapping() {
        XCTAssertEqual(KeychainRead(status: errSecSuccess, item: key32 as CFData), .success(key32))
        XCTAssertEqual(KeychainRead(status: errSecSuccess, item: "not data" as CFString), .success(nil),
                       "an item that is not Data is surfaced as success(nil), which the resolvers treat as an error")
        XCTAssertEqual(KeychainRead(status: errSecSuccess, item: nil), .success(nil))
        XCTAssertEqual(KeychainRead(status: errSecItemNotFound, item: nil), .notFound)
        XCTAssertEqual(KeychainRead(status: errSecInteractionNotAllowed, item: nil), .error, "locked device")
        XCTAssertEqual(KeychainRead(status: errSecAuthFailed, item: nil), .error)
        XCTAssertEqual(KeychainRead(status: errSecMissingEntitlement, item: nil), .error)
    }

    // MARK: Account public bundle

    func testAccountBundleStates() {
        let bundle = Data(repeating: 1, count: 40)
        XCTAssertEqual(AccountBundleLoad.resolve(.success(bundle)), .found(bundle))
        XCTAssertEqual(AccountBundleLoad.resolve(.success(Data(repeating: 1, count: 32))), .found(Data(repeating: 1, count: 32)))
        XCTAssertEqual(AccountBundleLoad.resolve(.success(Data(repeating: 1, count: 31))), .lockedOrError, "too short is corrupt, not absent")
        XCTAssertEqual(AccountBundleLoad.resolve(.success(nil)), .lockedOrError)
        XCTAssertEqual(AccountBundleLoad.resolve(.notFound), .notFound)
        XCTAssertEqual(AccountBundleLoad.resolve(.error), .lockedOrError)
    }

    // MARK: Self-sync key

    private func resolve(wrapped: KeychainRead, open: SealedKeyOpen = .failed, plain: KeychainRead = .notFound) -> SelfSyncKeyLoad {
        SelfSyncKeyLoad.resolve(wrapped: wrapped, open: { _ in open }, plain: { plain })
    }

    func testWrappedKeyOpensToFound() {
        XCTAssertEqual(resolve(wrapped: .success(Data([9])), open: .ok(key32)), .found(key32))
    }

    func testWrappedKeyOfWrongSizeIsCorruptNotNew() {
        XCTAssertEqual(resolve(wrapped: .success(Data([9])), open: .ok(Data(repeating: 1, count: 16))), .seError)
    }

    func testLockedEnclaveIsNeverAbsent() {
        XCTAssertEqual(resolve(wrapped: .success(Data([9])), open: .locked), .lockedOrError)
    }

    func testUnreadableEnclaveKeyMeansARealSecretExists() {
        XCTAssertEqual(resolve(wrapped: .success(Data([9])), open: .missingKey), .seError)
        XCTAssertEqual(resolve(wrapped: .success(Data([9])), open: .failed), .seError)
    }

    func testWrappedItemWithNonDataPayloadIsAnError() {
        XCTAssertEqual(resolve(wrapped: .success(nil)), .lockedOrError)
    }

    func testWrappedReadErrorNeverFallsThroughToPlaintext() {
        // A locked keychain must not be read as "no wrapped key, so use the plaintext one / treat as new".
        var consulted = false
        let r = SelfSyncKeyLoad.resolve(wrapped: .error, open: { _ in .ok(self.key32) },
                                        plain: { consulted = true; return .notFound })
        XCTAssertEqual(r, .lockedOrError)
        XCTAssertFalse(consulted)
    }

    func testNoWrappedKeyFallsThroughToPlaintext() {
        XCTAssertEqual(resolve(wrapped: .notFound, plain: .success(key32)), .found(key32), "Simulator / no-Enclave hardware")
        XCTAssertEqual(resolve(wrapped: .notFound, plain: .notFound), .notFound, "only here is the key genuinely absent")
        XCTAssertEqual(resolve(wrapped: .notFound, plain: .error), .lockedOrError)
        XCTAssertEqual(resolve(wrapped: .notFound, plain: .success(Data(repeating: 1, count: 31))), .lockedOrError)
        XCTAssertEqual(resolve(wrapped: .notFound, plain: .success(nil)), .lockedOrError)
    }

    func testWrappedTakesPrecedenceOverPlaintext() {
        let other = Data(repeating: 9, count: 32)
        XCTAssertEqual(resolve(wrapped: .success(Data([1])), open: .ok(key32), plain: .success(other)), .found(key32))
    }

    // MARK: Epoch key

    private func epochKey(wrapped: KeychainRead, open: SealedKeyOpen = .failed, plain: KeychainRead = .notFound) -> Data? {
        SelfSyncEpochRules.currentKey(wrapped: wrapped, open: { _ in open }, plain: { plain })
    }

    func testEpochKeyFromWrappedItem() {
        XCTAssertEqual(epochKey(wrapped: .success(Data([1])), open: .ok(key32)), key32)
        XCTAssertNil(epochKey(wrapped: .success(Data([1])), open: .ok(Data(count: 5))))
        XCTAssertNil(epochKey(wrapped: .success(Data([1])), open: .locked))
        XCTAssertNil(epochKey(wrapped: .success(nil)))
    }

    func testEpochKeyFallsBackToPlaintextOnlyWhenWrappedIsAbsent() {
        XCTAssertEqual(epochKey(wrapped: .notFound, plain: .success(key32)), key32)
        XCTAssertNil(epochKey(wrapped: .notFound, plain: .success(Data(count: 5))))
        XCTAssertNil(epochKey(wrapped: .notFound, plain: .notFound), "no rotation yet -> the v0 path")
        XCTAssertNil(epochKey(wrapped: .error, plain: .success(key32)), "a failed wrapped read must not be papered over")
    }

    func testEpochAdoptionIsStrictlyNewerOnly() {
        XCTAssertTrue(SelfSyncEpochRules.shouldAdopt(epoch: 1, current: 0, key: key32))
        XCTAssertTrue(SelfSyncEpochRules.shouldAdopt(epoch: 5, current: 4, key: key32))
        XCTAssertFalse(SelfSyncEpochRules.shouldAdopt(epoch: 4, current: 4, key: key32), "idempotent")
        XCTAssertFalse(SelfSyncEpochRules.shouldAdopt(epoch: 3, current: 4, key: key32), "a replayed grant cannot roll back")
        XCTAssertFalse(SelfSyncEpochRules.shouldAdopt(epoch: 9, current: 4, key: Data(count: 31)), "a malformed key is never adopted")
    }
}

/// Durable bookkeeping for the crypto enable-sequence. UserDefaults-backed; each test uses fresh ids
/// and clears what it set.
final class SwitchFlipStoresTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CircleCreatorStore.clear()
        SwitchFlipMigration.clear()
    }

    override func tearDown() {
        CircleCreatorStore.clear()
        SwitchFlipMigration.clear()
        super.tearDown()
    }

    func testCreatedCirclesAreRememberedAndDeduplicated() {
        XCTAssertFalse(CircleCreatorStore.iCreated("c1"))
        CircleCreatorStore.markCreated("c1")
        CircleCreatorStore.markCreated("c1")
        CircleCreatorStore.markCreated("c2")
        XCTAssertTrue(CircleCreatorStore.iCreated("c1"))
        XCTAssertFalse(CircleCreatorStore.iCreated("c3"))
        XCTAssertEqual(CircleCreatorStore.createdIds(), ["c1", "c2"])
    }

    func testEmptyIdIsIgnored() {
        CircleCreatorStore.markCreated("")
        XCTAssertEqual(CircleCreatorStore.createdIds(), [])
        XCTAssertFalse(CircleCreatorStore.iCreated(""))
    }

    func testClearForgetsEverything() {
        CircleCreatorStore.markCreated("c1")
        CircleCreatorStore.clear()
        XCTAssertEqual(CircleCreatorStore.createdIds(), [])
    }

    func testAccountLeafRetiredFlag() {
        XCTAssertFalse(SwitchFlipMigration.accountLeafRetired)
        SwitchFlipMigration.accountLeafRetired = true
        XCTAssertTrue(SwitchFlipMigration.accountLeafRetired)
        SwitchFlipMigration.clear()
        XCTAssertFalse(SwitchFlipMigration.accountLeafRetired)
        XCTAssertTrue(SwitchFlipMigration.retireSwitchOn, "the seed-drop retirement switch is ON in 1.0.7")
    }
}
