import XCTest
@testable import HavenUITestHost

/// The demo dataset's engine pass, run against a throwaway engine (never the host's stores): the
/// screenshots' cast must come out as a genuinely sealed, multi-author, multi-circle account.
final class DemoSeedEngineTests: XCTestCase {
    private func seeded() throws -> (main: HavenSocial, cast: [DemoSeedEngine.Persona]) {
        let main = try HavenSocial(accountSeed: Data((0..<32).map { UInt8(0x5A &+ UInt8($0)) }))
        return (main, DemoSeedEngine.seed(into: main))
    }
    private var now: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    func testTheCastAndTheirCirclesAreReal() throws {
        let (main, cast) = try seeded()
        XCTAssertEqual(cast.map(\.name), ["Maya Quinn", "Theo Park", "Nina Brooks", "Sam Rivera"])
        XCTAssertEqual(Set(cast.map(\.hex)).count, 4, "four distinct identities")
        XCTAssertTrue(cast.allSatisfy { $0.hex.count == 64 && $0.engine != nil })
        let circles = main.circles()
        XCTAssertTrue(circles.contains { $0.id == "default" })
        XCTAssertTrue(circles.contains { $0.id == "demo-weekend-crew" && $0.name == "Weekend Crew" })
        XCTAssertEqual(circles.filter { $0.id.hasPrefix("dm:") }.count, 2, "two DM threads")
        XCTAssertEqual(main.contactNodeIds(circleId: "default").count, 4)
    }

    func testTheFeedIsMultiAuthorWithReactionsCommentsAndStories() throws {
        let (main, _) = try seeded()
        let feed = main.feed(circleId: "default", nowMs: now, viewerRetentionSecs: nil)
        let posts = feed.filter { !$0.story }
        XCTAssertGreaterThanOrEqual(posts.count, 6)
        XCTAssertTrue(posts.contains { $0.isMe && $0.body.contains("studio") })
        XCTAssertTrue(posts.contains { !$0.isMe })
        let wheel = try XCTUnwrap(posts.first { $0.body.contains("new wheel") })
        XCTAssertGreaterThanOrEqual(wheel.reactions.count, 2, "friends reacted with different emoji")
        XCTAssertEqual(wheel.comments.count, 2)
        let carousel = try XCTUnwrap(posts.first { $0.body.contains("a few from the weekend") })
        XCTAssertEqual(carousel.media.count, 4, "the carousel path has a multi-photo post")
        XCTAssertNotNil(posts.first { $0.body.contains("12 miles") }?.music, "a post carries a song credit")
        let stories = feed.filter(\.story)
        XCTAssertGreaterThanOrEqual(stories.count, 3, "two friends' stories and mine")
        XCTAssertTrue(stories.contains { $0.isMe })
    }

    func testTheDirectThreadsAndSecondCircleCarryConversation() throws {
        let (main, cast) = try seeded()
        let dm = "dm:" + [main.myNodeHex(), cast[0].hex].sorted().joined(separator: "-")
        let thread = main.feed(circleId: dm, nowMs: now, viewerRetentionSecs: nil)
        XCTAssertEqual(thread.count, 4)
        XCTAssertEqual(thread.filter(\.isMe).count, 2, "a real back-and-forth")
        XCTAssertNotNil(thread.first { $0.music != nil }?.music, "one line carries a song")
        let crew = main.feed(circleId: "demo-weekend-crew", nowMs: now, viewerRetentionSecs: nil)
        XCTAssertEqual(crew.count, 2)
        // Deterministic: the same account seed yields the same cast every time.
        let again = DemoSeedEngine.seed(into: try HavenSocial(accountSeed: Data((0..<32).map { UInt8(0x5A &+ UInt8($0)) })))
        XCTAssertEqual(again.map(\.hex), cast.map(\.hex))
    }
}
