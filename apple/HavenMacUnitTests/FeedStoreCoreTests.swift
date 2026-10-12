import XCTest
@testable import HavenUITestHost

@MainActor
final class FeedStoreCoreTests: XCTestCase {
    func testBootsConfiguredWithDefaultCircle() async {
        let store = await Harness.feed()
        XCTAssertTrue(store.isConfigured)
        await store.reloadCircles()
        XCTAssertTrue(store.circles.contains { $0.id == "default" })
        XCTAssertFalse(store.myNodeHex.isEmpty)
    }

    func testPostThenEditThenUnsend() async {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let id = await store.postNow("first light")
        XCTAssertNotNil(id)
        guard let id else { return }
        await Harness.until(store, "post visible") { store.items.contains { $0.id == id && $0.isMe && $0.body == "first light" } }

        store.edit(id, "first light, edited")
        await Harness.until(store, "edit applied") { store.items.first { $0.id == id }?.body == "first light, edited" }
        XCTAssertEqual(store.items.first { $0.id == id }?.edited, true)

        store.unsend(id)
        await Harness.until(store, "post retracted") { store.items.first { $0.id == id } == nil || store.items.first { $0.id == id }?.unsent == true }
    }

    func testReactAndUnreactAndComment() async {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        guard let id = await store.postNow("react to me") else { return XCTFail("post failed") }
        await Harness.until(store, "post visible") { store.items.contains { $0.id == id } }

        store.react(id, "🔥")
        await Harness.until(store, "reaction shows") { store.items.first { $0.id == id }?.reactions.contains { $0.emoji == "🔥" && $0.mine } == true }

        store.unreact(id, "🔥")
        await Harness.until(store, "reaction gone") { store.items.first { $0.id == id }?.reactions.contains { $0.emoji == "🔥" && $0.mine } != true }

        store.comment(id, "nice one")
        await Harness.until(store, "comment shows") { store.items.first { $0.id == id }?.comments.contains { $0.body == "nice one" } == true }
    }

    func testCreateRenameAndLeaveCircle() async {
        let store = await Harness.feed()
        guard let cid = await store.createCircleNow(name: "Hikers") else { return XCTFail("circle not created") }
        await store.reloadCircles()
        XCTAssertEqual(store.displayName(forCircle: cid), "Hikers")
        store.renameCircle(cid, to: "Hikers & Co")
        await Harness.until(store, "rename shown") { store.displayName(forCircle: cid) == "Hikers & Co" }
        store.setActiveCircle(cid)
        XCTAssertEqual(store.activeCircleId, cid)
        store.leaveActiveCircle()
        await Harness.until(store, "circle gone") { !store.circles.contains { $0.id == cid } }
    }

    func testFriendPostReactionAndCommentArrive() async {
        let store = await Harness.feed()
        let maya = Peer(byte: 0xA1, name: "Maya")
        await maya.befriend(store)
        store.setActiveCircle("default")
        let applied = await maya.post("hello from maya", into: store)
        XCTAssertGreaterThan(applied, 0)
        await Harness.until(store, "friend post visible") { store.items.contains { !$0.isMe && $0.body == "hello from maya" } }
        XCTAssertTrue(ContactsStore.shared.contacts.contains { $0.idHex == maya.hex })
        await Harness.until(store, "maya handshaked") { store.isHandshaked(maya.hex) }
    }
}
