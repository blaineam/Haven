import XCTest
@testable import HavenUITestHost

/// State that survives restarts: the feed file an older build set aside, shelved identities.
@MainActor
final class FeedStoreStateTests: XCTestCase {
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: FeedStore.setAsideStateURL)
    }

    func testARecoveredSetAsideFeedBringsBackFriendsPostsAndIsRenamedNotDeleted() async throws {
        let store = await Harness.feed()
        let fm = FileManager.default
        try? fm.removeItem(at: FeedStore.setAsideStateURL)
        XCTAssertFalse(FeedStore.hasSetAsideState)

        // The identity an older build left behind: it knew a friend and held one of their posts.
        let oldSeed = Data((0..<32).map { UInt8($0) &+ 0xC0 })
        let old = try HavenSocial(accountSeed: oldSeed)
        old.createCircle(id: "default", name: "Your circle")
        let friend = Peer(byte: 0xD1, name: "Old friend")
        friend.engine.createCircle(id: "default", name: "Your circle")
        _ = try old.addContactBundle(circleId: "default", bundle: friend.bundle)
        _ = try friend.engine.addContactBundle(circleId: "default", bundle: old.myBundle())
        let tag = UUID().uuidString.prefix(6)
        _ = try friend.engine.post(circleId: "default", body: "remember me \(tag)", media: [], music: nil, retentionSecs: nil,
                                   story: false, muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
        for env in friend.engine.syncEnvelopes(circleId: "default") { _ = try? old.receive(circleId: "default", envelope: env) }
        try old.exportState().write(to: FeedStore.setAsideStateURL)
        XCTAssertTrue(FeedStore.hasSetAsideState)

        store.setActiveCircle("default")
        let oldHex = old.myNodeHex()
        let count = await store.recoverSetAsideState(ownOtherIdentities: [oldHex])
        XCTAssertNotNil(count, "the file carried events from someone other than the stray identity")
        XCTAssertGreaterThan(count ?? 0, 0)
        XCTAssertFalse(FeedStore.hasSetAsideState, "the file is renamed, so a second attempt stays possible")
        let siblings = try fm.contentsOfDirectory(at: FeedStore.setAsideStateURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.hasPrefix("haven-feed.prev.recovered-") })
        for url in siblings where url.lastPathComponent.hasPrefix("haven-feed.prev.recovered-") { try? fm.removeItem(at: url) }
    }

    func testNothingUsableMeansNothingRecovered() async throws {
        let store = await Harness.feed()
        try? FileManager.default.removeItem(at: FeedStore.setAsideStateURL)
        let none = await store.recoverSetAsideState(ownOtherIdentities: [])
        XCTAssertNil(none, "no set-aside file: nothing to recover")
        try Data("{\"circles\":[]}".utf8).write(to: FeedStore.setAsideStateURL)
        let empty = await store.recoverSetAsideState(ownOtherIdentities: [])
        XCTAssertNil(empty, "a file with no events is not worth merging")
        XCTAssertTrue(FeedStore.hasSetAsideState, "…and is left where it is")
        try Data("not json".utf8).write(to: FeedStore.setAsideStateURL)
        let junk = await store.recoverSetAsideState(ownOtherIdentities: [])
        XCTAssertNil(junk)
    }

    func testDeletingShelvedStateRemovesEveryIdentitysFeedButNotTheLiveOne() throws {
        let dir = FeedStore.setAsideStateURL.deletingLastPathComponent()
        let shelf = dir.appendingPathComponent("haven-feed.id-\(UUID().uuidString.prefix(8)).json")
        let live = dir.appendingPathComponent("haven-feed.json")
        try Data("{}".utf8).write(to: shelf)
        try Data("{}".utf8).write(to: FeedStore.setAsideStateURL)
        let liveBefore = FileManager.default.fileExists(atPath: live.path)
        FeedStore.deleteAllShelvedState()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelf.path))
        XCTAssertFalse(FeedStore.hasSetAsideState)
        XCTAssertEqual(FileManager.default.fileExists(atPath: live.path), liveBefore, "the live feed is not a shelf")
    }
}
