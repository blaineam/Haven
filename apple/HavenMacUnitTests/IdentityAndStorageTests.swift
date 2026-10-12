import XCTest
import CryptoKit
@testable import HavenUITestHost

@MainActor
final class IdentityAndStorageTests: XCTestCase {
    // MARK: Keychain / PKCE / StorageStore

    func testKeychainRoundTripReplaceAndDelete() {
        let key = "ut-\(UUID().uuidString.prefix(8))"
        XCTAssertNil(Keychain.get(key))
        Keychain.set("first", for: key)
        XCTAssertEqual(Keychain.get(key), "first")
        Keychain.set("second", for: key)
        XCTAssertEqual(Keychain.get(key), "second", "set replaces rather than duplicating")
        Keychain.set("", for: key)
        XCTAssertNil(Keychain.get(key), "an empty value deletes the item")
    }

    func testPkceChallengeIsTheUrlSafeSha256OfTheVerifier() {
        let v = PKCE.verifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertFalse(v.contains("+") || v.contains("/") || v.contains("="))
        XCTAssertNotEqual(v, PKCE.verifier())
        let expected = Data(SHA256.hash(data: Data(v.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(PKCE.challenge(v), expected)
        // RFC 7636 appendix B vector.
        XCTAssertEqual(PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testStorageStoreConfiguredOnlyWithEveryField() {
        let s = StorageStore.shared
        let saved = (s.s3Endpoint, s.s3Region, s.s3Bucket, s.s3AccessKey, s.s3Secret, s.shareCircleMedia)
        defer { (s.s3Endpoint, s.s3Region, s.s3Bucket, s.s3AccessKey, s.s3Secret, s.shareCircleMedia) = saved }
        s.s3Endpoint = ""; s.s3Bucket = ""; s.s3AccessKey = ""; s.s3Secret = ""
        XCTAssertFalse(s.s3Configured)
        s.s3Endpoint = "https://s3.example"; s.s3Bucket = "b"; s.s3AccessKey = "AK"
        XCTAssertFalse(s.s3Configured, "a secret is required")
        s.s3Secret = "SK"
        XCTAssertTrue(s.s3Configured)
        XCTAssertEqual(Keychain.get("s3Secret"), "SK", "credentials live in the keychain")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "haven.s3.bucket"), "b")
        s.shareCircleMedia = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "haven.s3.share"))
        XCTAssertEqual(StorageProvider.s3.id, "s3")
        XCTAssertFalse(StorageProvider.s3.title.isEmpty)
        XCTAssertFalse(StorageProvider.s3.icon.isEmpty)
        XCTAssertNotNil(SharedStore.ownerS3())
        XCTAssertTrue(SharedStore.isVolunteering, "sharing media through my own bucket makes me a volunteer")
    }

    // MARK: Device key + credential + roster

    func testDeviceKeyIsStableAndDistinctFromTheAccount() {
        let a = DeviceKeyStore.deviceNodeHex()
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(DeviceKeyStore.deviceNodeHex(), a, "the device key does not change between calls")
        XCTAssertFalse(DeviceKeyStore.deviceBundle().isEmpty)
        XCTAssertFalse(DeviceKeyStore.deviceName.isEmpty)
        XCTAssertEqual(DeviceKeyStore.deviceAccount().secretSeed().count, 32)
    }

    func testDeviceCredentialStore() {
        let had = DeviceCredentialStore.load()
        defer { if let had { DeviceCredentialStore.save(had) } else { DeviceCredentialStore.clear() } }
        DeviceCredentialStore.clear()
        XCTAssertFalse(DeviceCredentialStore.isAuthorized)
        DeviceCredentialStore.save(Data([1, 2, 3]))
        XCTAssertTrue(DeviceCredentialStore.isAuthorized)
        XCTAssertEqual(DeviceCredentialStore.load(), Data([1, 2, 3]))
        DeviceCredentialStore.clear()
        XCTAssertNil(DeviceCredentialStore.load())
    }

    func testHexToDataOnlyAcceptsA32ByteKey() {
        XCTAssertEqual(DeviceRosterManager.hexToData(String(repeating: "ab", count: 32))?.count, 32)
        XCTAssertNil(DeviceRosterManager.hexToData(String(repeating: "ab", count: 31)))
        XCTAssertNil(DeviceRosterManager.hexToData(String(repeating: "zz", count: 32)))
        XCTAssertNil(DeviceRosterManager.hexToData(""))
    }

    func testRosterEnableLinkRevokeAndStepDown() async throws {
        let mgr = DeviceRosterManager.shared
        mgr.stepDown()
        defer { mgr.stepDown() }
        let seed = Data((0..<32).map { UInt8($0 &+ 90) })
        let primary = try Account.fromSeed(seed: seed)
        let engine = Engine(try HavenSocial(accountSeed: seed))
        XCTAssertFalse(mgr.isEnabled)

        let enabled = await mgr.enable(engine: engine, accountSeed: seed, accountBundle: primary.publicBundle(),
                                       accountHex: primary.nodeIdHex())
        XCTAssertTrue(enabled)
        XCTAssertTrue(mgr.isEnabled)
        XCTAssertEqual(mgr.devices.map(\.isPrimary), [true])

        let phone = Account.generate()
        let cred = await mgr.addLinkedDevice(bundle: phone.publicBundle(), nodeHex: phone.nodeIdHex(), name: "Phone",
                                             engine: engine, accountSeed: seed)
        XCTAssertNotNil(cred, "linking hands back the device's credential")
        XCTAssertEqual(mgr.devices.count, 2)
        XCTAssertEqual(mgr.devices.first?.isPrimary, true, "the master key sorts first")
        XCTAssertEqual(mgr.authorizedDeviceBundles().count, 1, "grants target device keys, never the account leaf")
        XCTAssertTrue(mgr.authorizedDeviceBundles(excluding: phone.nodeIdHex()).isEmpty)

        let revokedMaster = await mgr.revoke(primary.nodeIdHex(), engine: engine, accountSeed: seed)
        XCTAssertFalse(revokedMaster, "the master key is never revocable")
        let revoked = await mgr.revoke(phone.nodeIdHex(), engine: engine, accountSeed: seed)
        XCTAssertTrue(revoked)
        XCTAssertEqual(mgr.devices.count, 1)
        XCTAssertTrue(mgr.authorizedDeviceBundles().isEmpty)

        // The same device can come back: linking again clears its revocation.
        let again = await mgr.addLinkedDevice(bundle: phone.publicBundle(), nodeHex: phone.nodeIdHex(), name: "Phone",
                                              engine: engine, accountSeed: seed)
        XCTAssertNotNil(again)
        XCTAssertEqual(mgr.devices.count, 2)
        mgr.stepDown()
        XCTAssertFalse(mgr.isEnabled)
        XCTAssertTrue(mgr.devices.isEmpty)
    }

    // MARK: AccountStore

    func testTransferCodeCarriesTheSeedAndRejectsGarbage() {
        let a = AccountStore()
        let code = a.transferCode()
        XCTAssertTrue(code.hasPrefix("haven-seed:") || code.hasPrefix("haven-link:"))
        XCTAssertFalse(a.restore(fromTransferCode: "nonsense"))
        XCTAssertFalse(a.restore(fromTransferCode: "haven-seed:@@@"))
        XCTAssertFalse(a.restore(fromTransferCode: "haven-link:@@@"))
        XCTAssertFalse(a.restore(fromTransferCode: "haven-seed:" + Data(repeating: 1, count: 8).base64EncodedString()))
        XCTAssertFalse(a.restoreIdentity("not base64"))
        XCTAssertFalse(a.restoreIdentity(Data(repeating: 1, count: 5).base64EncodedString()))
        XCTAssertFalse(a.deleteIdentity(seedB64: a.account.secretSeed().base64EncodedString()), "the active identity can't be deleted")
        XCTAssertEqual(AccountStore.currentNodeHex(), a.account.nodeIdHex())
        XCTAssertEqual(AccountStore.storedSeed(), a.account.secretSeed())
    }

    func testIdentityLabelsAndRoster() {
        let a = AccountStore()
        let hex = a.account.nodeIdHex()
        AccountStore.setIdentityLabel("", forNodeHex: hex)       // blank labels are ignored
        AccountStore.setIdentityLabel("Primary me", forNodeHex: "")
        AccountStore.setIdentityLabel("Work", forNodeHex: "ff" + hex.dropFirst(2))
        XCTAssertEqual(AccountStore.identityLabels()["ff" + hex.dropFirst(2)], "Work")
        let roster = a.roster()
        XCTAssertEqual(roster.first?.isCurrent, true)
        XCTAssertEqual(roster.first?.nodeHex, hex)
        XCTAssertEqual(roster.filter(\.isCurrent).count, 1)
        a.rememberCurrentLabel()
    }

    func testSwitchingIdentitiesReconfiguresTheFeedAndComesBack() async throws {
        let store = await Harness.feed()
        let a = AccountStore()
        let original = a.account.secretSeed()
        let originalHex = a.account.nodeIdHex()
        let other = Account.generate()
        let otherB64 = other.secretSeed().base64EncodedString()

        XCTAssertTrue(a.restoreIdentity(otherB64))
        XCTAssertEqual(a.account.nodeIdHex(), other.nodeIdHex())
        XCTAssertEqual(AccountStore.currentNodeHex(), other.nodeIdHex())
        _ = await Harness.feed()
        XCTAssertEqual(store.myNodeHex, other.nodeIdHex(), "the engine now runs under the other identity")
        XCTAssertTrue(a.roster().contains { $0.seedB64 == original.base64EncodedString() && !$0.isCurrent },
                      "the identity we left stays in the roster to switch back to")

        XCTAssertTrue(a.switchToIdentity(seedB64: original.base64EncodedString()))
        _ = await Harness.feed()
        XCTAssertEqual(AccountStore.currentNodeHex(), originalHex)
        XCTAssertEqual(store.myNodeHex, originalHex, "switching back brings the first identity's engine back")
        XCTAssertTrue(a.deleteIdentity(seedB64: otherB64))
        XCTAssertFalse(a.deleteIdentity(seedB64: otherB64), "already forgotten")
    }

    func testTransferCodeRoundTripAdoptsTheIdentity() async {
        _ = await Harness.feed()
        let a = AccountStore()
        let original = a.account.secretSeed()
        let incoming = Account.generate()
        let code = "haven-seed:" + incoming.secretSeed().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertTrue(a.restore(fromTransferCode: "  " + code + "\n"))
        XCTAssertEqual(a.account.nodeIdHex(), incoming.nodeIdHex())
        XCTAssertTrue(HistoryHandoff.shared.isWaiting, "joining an account asks its other devices for the history")
        _ = await Harness.feed()
        // put the host back on its own identity
        XCTAssertTrue(a.restoreIdentity(original.base64EncodedString()))
        HistoryHandoff.shared.reset()
        _ = await Harness.feed()
        XCTAssertFalse(HistoryHandoff.shared.isWaiting)
    }
}
