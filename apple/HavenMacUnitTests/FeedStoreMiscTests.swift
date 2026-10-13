import XCTest
@testable import HavenUITestHost

/// Small authoring operations the bigger suites don't reach: crediting a song on an existing post
/// and adding a person to the default circle by id.
@MainActor
final class FeedStoreMiscTests: XCTestCase {
    func testASongCreditCanBeAttachedToAPostAfterTheFact() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let posted = await store.postNow("no song yet \(UUID().uuidString.prefix(6))")
        let id = try XCTUnwrap(posted)
        await Harness.until(store, "the post is listed") { store.items.contains { $0.id == id } }
        XCTAssertNil(store.items.first { $0.id == id }?.music)

        let track = TrackRefFfi(catalogId: "cat-\(UUID().uuidString.prefix(6))", title: "Slow Morning", artist: "Wax & Wane",
                                artworkUrl: "", durationMs: 192_000)
        let ok = await store.attachSongCredit(postId: id, circleId: "default", track: track)
        XCTAssertTrue(ok)
        await Harness.until(store, "the credit shows on the post") { store.items.first { $0.id == id }?.music?.title == "Slow Morning" }

        let missing = await store.attachSongCredit(postId: "no-such-post", circleId: "default", track: track)
        XCTAssertFalse(missing, "nothing to credit")
    }

    func testAddingSomeoneByIdMakesThemAContactAndForcesAHello() async {
        let store = await Harness.feed()
        let hex = String(repeating: "7a", count: 32)
        defer { if let c = ContactsStore.shared.contacts.first(where: { $0.idHex == hex }) { ContactsStore.shared.remove(c) } }
        store.addMemberToMyCircle(hex)
        XCTAssertEqual(ContactsStore.shared.contact(forNodePrefix: hex)?.name, String(hex.prefix(6)), "a placeholder name until their profile arrives")
        let again = ContactsStore.shared.contacts.filter { $0.idHex == hex }.count
        store.addMemberToMyCircle(hex)
        XCTAssertEqual(ContactsStore.shared.contacts.filter { $0.idHex == hex }.count, again, "adding twice doesn't duplicate")
    }
}
