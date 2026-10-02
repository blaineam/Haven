import XCTest

/// Pre-rename media: migrate into the current store, delete the legacy folder only when every file
/// was accounted for, and run once.
final class LegacyKithMigrationTests: XCTestCase {
    private var root: URL!
    private var legacy: URL { root.appendingPathComponent("kith-media", isDirectory: true) }
    private var store: URL { root.appendingPathComponent("haven-media", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("kith-mig-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func write(_ dir: URL, _ name: String, _ bytes: Int) {
        fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(repeating: 7, count: bytes))
    }
    private func size(_ url: URL) -> Int { (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 }

    func testStoreFileNamesMatchTheCurrentLookup() {
        XCTAssertTrue(LegacyKithMigration.isStoreFileName("img_1346DCE4-E7E8-41D2-8CC2-F790AE5F98F5.jpg"))
        XCTAssertTrue(LegacyKithMigration.isStoreFileName("vid_04E18997-9630-40DF-BE4F-2BA096F6D7D2.mp4"))
        XCTAssertTrue(LegacyKithMigration.isStoreFileName("aud_x.m4a"))
        XCTAssertFalse(LegacyKithMigration.isStoreFileName("vid_x.jpg"), "kind and extension must agree")
        XCTAssertFalse(LegacyKithMigration.isStoreFileName("img_.jpg"))
        XCTAssertFalse(LegacyKithMigration.isStoreFileName("notes.txt"))
    }

    func testMigratesMissingFilesByMoveThenRemovesFolder() {
        write(legacy, "img_A.jpg", 100)
        write(legacy, "vid_B.mp4", 300)
        let out = LegacyKithMigration.migrateMedia(legacyDir: legacy, storeDir: store)
        XCTAssertEqual(out.moved, 2)
        XCTAssertEqual(out.failed, 0)
        XCTAssertTrue(out.legacyRemoved)
        XCTAssertEqual(Set(out.movedNames), ["img_A.jpg", "vid_B.mp4"])
        // Exactly where MediaStore.fileURL(ref) looks: <store>/<ref>.<ext>, same bytes.
        XCTAssertEqual(size(store.appendingPathComponent("img_A.jpg")), 100)
        XCTAssertEqual(size(store.appendingPathComponent("vid_B.mp4")), 300)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
    }

    func testAlreadyHeldFilesAreSkippedAndLegacyDeleted() {
        write(store, "img_A.jpg", 50)      // the current store's copy wins
        write(legacy, "img_A.jpg", 999)
        let out = LegacyKithMigration.migrateMedia(legacyDir: legacy, storeDir: store)
        XCTAssertEqual(out.alreadyPresent, 1)
        XCTAssertEqual(out.moved, 0)
        XCTAssertTrue(out.legacyRemoved)
        XCTAssertEqual(size(store.appendingPathComponent("img_A.jpg")), 50, "never overwrite what the store holds")
    }

    func testFolderKeptWhenAnyFileFailsToMigrate() {
        write(legacy, "img_A.jpg", 10)
        write(legacy, "mystery.bin", 10)   // not a name the store could ever look up
        let out = LegacyKithMigration.migrateMedia(legacyDir: legacy, storeDir: store)
        XCTAssertEqual(out.moved, 1)
        XCTAssertEqual(out.failed, 1)
        XCTAssertFalse(out.legacyRemoved)
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("mystery.bin").path), "left for a later run")
    }

    func testRunsOnceAndOnlyRecordsCompletionOnSuccess() throws {
        let suite = "kith-mig-\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { ud.removePersistentDomain(forName: suite) }

        write(legacy, "img_A.jpg", 10)
        write(legacy, "bad.bin", 10)
        let first = try XCTUnwrap(LegacyKithMigration.runOnce(appSupport: root, storeDir: store, defaults: ud))
        XCTAssertEqual(first.failed, 1)
        XCTAssertFalse(ud.bool(forKey: LegacyKithMigration.doneKey), "a failure retries next launch")

        try fm.removeItem(at: legacy.appendingPathComponent("bad.bin"))
        let second = try XCTUnwrap(LegacyKithMigration.runOnce(appSupport: root, storeDir: store, defaults: ud))
        XCTAssertTrue(second.legacyRemoved)
        XCTAssertTrue(ud.bool(forKey: LegacyKithMigration.doneKey))
        XCTAssertNil(LegacyKithMigration.runOnce(appSupport: root, storeDir: store, defaults: ud), "idempotent: once")
    }

    func testAvatarMovesOnlyWhenNoAvatarExists() {
        let kith = root.appendingPathComponent("kith-avatar.jpg")
        write(root, "kith-avatar.jpg", 20)
        XCTAssertTrue(LegacyKithMigration.migrateAvatar(legacy: kith, appSupport: root))
        XCTAssertEqual(size(root.appendingPathComponent("haven-avatar.jpg")), 20)

        write(root, "kith-avatar.jpg", 30)   // a current avatar now exists → legacy is redundant
        XCTAssertTrue(LegacyKithMigration.migrateAvatar(legacy: kith, appSupport: root))
        XCTAssertFalse(fm.fileExists(atPath: kith.path))
        XCTAssertEqual(size(root.appendingPathComponent("haven-avatar.jpg")), 20)
    }
}
