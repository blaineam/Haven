import XCTest
@testable import HavenUITestHost

/// Scheduled posts and DMs: queueing order, per-circle lists, cancellation, persistence, and
/// firing what has come due through the normal authoring path.
@MainActor
final class ScheduledStoreTests: XCTestCase {
    private let store = ScheduledStore.shared
    private func uniq(_ p: String) -> String { "\(p)-\(UUID().uuidString.prefix(8))" }

    override func setUp() async throws {
        _ = await Harness.feed()
        for i in store.items { store.cancel(i.id) }
    }
    override func tearDown() async throws {
        for i in store.items { store.cancel(i.id) }
    }

    func testItemsQueueInTimeOrderPerCircleAndCancelIndividually() {
        let later = Date().addingTimeInterval(7200), sooner = Date().addingTimeInterval(3600)
        store.schedule(circleId: "default", isDM: false, body: "later", media: [], at: later)
        store.schedule(circleId: "default", isDM: false, body: "sooner", media: ["img_x"], at: sooner)
        store.schedule(circleId: "elsewhere", isDM: true, body: "dm", media: [], at: sooner)
        XCTAssertEqual(store.items.map(\.fireAt), store.items.map(\.fireAt).sorted(), "the queue is kept in time order")
        XCTAssertEqual(store.items.last?.body, "later")
        XCTAssertEqual(store.upcoming(forCircle: "default").map(\.body), ["sooner", "later"])
        XCTAssertEqual(store.upcoming(forCircle: "elsewhere").count, 1)
        XCTAssertTrue(store.upcoming(forCircle: "nowhere").isEmpty)
        XCTAssertEqual(store.upcoming(forCircle: "default").first?.fireDate.timeIntervalSince1970 ?? 0, sooner.timeIntervalSince1970, accuracy: 0.001)

        store.cancel(store.upcoming(forCircle: "default")[0].id)
        XCTAssertEqual(store.upcoming(forCircle: "default").map(\.body), ["later"])
        store.fireDue()   // nothing is due: the queue is untouched
        XCTAssertEqual(store.items.count, 2)
    }

    func testTheQueuePersistsToDisk() throws {
        store.schedule(circleId: "default", isDM: false, body: "survives a relaunch", media: [], at: Date().addingTimeInterval(5400))
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let data = try Data(contentsOf: dir.appendingPathComponent("haven-scheduled.json"))
        let onDisk = try JSONDecoder().decode([ScheduledItem].self, from: data)
        XCTAssertTrue(onDisk.contains { $0.body == "survives a relaunch" })
        store.cancel(store.items.first { $0.body == "survives a relaunch" }!.id)
        let after = try JSONDecoder().decode([ScheduledItem].self, from: Data(contentsOf: dir.appendingPathComponent("haven-scheduled.json")))
        XCTAssertFalse(after.contains { $0.body == "survives a relaunch" }, "cancelling rewrites the file")
    }

    func testADuePostIsPublishedAndLeavesTheQueue() async {
        let feed = await Harness.feed()
        let body = uniq("scheduled post")
        store.schedule(circleId: "default", isDM: false, body: body, media: [], at: Date().addingTimeInterval(-5))
        store.start()   // fires whatever is already due, and arms for the rest
        XCTAssertTrue(store.items.isEmpty, "a due item leaves the queue the moment it fires")
        feed.setActiveCircle("default")
        await Harness.until(feed, "the scheduled post reaches the feed") { feed.items.contains { $0.isMe && $0.body == body } }
        store.start()   // idempotent: the foreground observer is installed once
    }

    func testADueMessageIsSentIntoItsDirectThread() async {
        let feed = await Harness.feed()
        let pal = Peer(byte: 0x32, name: "Pal")
        await pal.befriend(feed)
        let dm = feed.startDM(with: pal.hex, name: "Pal")
        let body = uniq("scheduled dm")
        store.schedule(circleId: dm, isDM: true, body: body, media: [], at: Date().addingTimeInterval(-1))
        store.fireDue()
        XCTAssertTrue(store.items.isEmpty)
        await Harness.until(feed, "the scheduled message is in the thread") { feed.messages(in: dm).contains { $0.isMe && $0.body == body } }
    }
}
