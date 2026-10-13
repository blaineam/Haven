import XCTest
import Combine
@testable import HavenUITestHost

/// The router that turns a tapped link or notification into a route and a tab, and the helpers that
/// work out which story a DM reply is about. (Locked circles hand off to the system's biometric
/// prompt, which a unit run must never raise, so only unlocked circles are exercised here.)
@MainActor
final class DeepLinkRouterTests: XCTestCase {
    private let router = DeepLinkRouter.shared
    private func url(_ s: String) -> URL { URL(string: s)! }

    override func setUp() async throws {
        _ = await Harness.feed()
        router.route = nil
        router.requestedTab = nil
        DMDraftStore.shared.openThread = nil
    }

    private func message(id: String = "m-\(UUID().uuidString.prefix(8))", isMe: Bool, at: UInt64, body: String = "",
                         media: [String] = [], unsent: Bool = false) -> FeedItemFfi {
        FeedItemFfi(id: id, authorShort: "", isMe: isMe, createdAt: at, body: body, media: media, music: nil, edited: false,
                    unsent: unsent, story: false, muteVideo: false, comments: [], reactions: [], poll: nil)
    }
    private func imgRef(_ b: Character) -> String { "img_" + String(repeating: b, count: 64) }

    func testProfilePostAndStoryLinksBecomeRoutes() {
        var tab = "circle"
        let hex = String(repeating: "ab", count: 32)
        XCTAssertTrue(router.handle(url("haven://u/\(hex)"), tab: &tab))
        guard case .profile(let h)? = router.route else { return XCTFail("route \(String(describing: router.route))") }
        XCTAssertEqual(h, hex)

        XCTAssertTrue(router.handle(url("haven://p/default/post-1"), tab: &tab))
        guard case .post(let c, let p)? = router.route else { return XCTFail("route") }
        XCTAssertEqual([c, p], ["default", "post-1"])
        XCTAssertEqual(tab, "circle", "an unlocked circle's post opens in place")

        XCTAssertTrue(router.handle(url("haven://s/default/story-1"), tab: &tab))
        guard case .story(let sc, let sp)? = router.route else { return XCTFail("route") }
        XCTAssertEqual([sc, sp], ["default", "story-1"])
        XCTAssertEqual(router.route?.id, "s:default:story-1")
    }

    func testAMalformedHavenLinkIsSwallowedAndAForeignOneIsLeftAlone() {
        var tab = "you"
        router.route = nil
        XCTAssertTrue(router.handle(url("haven://p/onlyone"), tab: &tab), "ours but incomplete: handled, not passed on")
        XCTAssertNil(router.route)
        XCTAssertTrue(router.handle(url("haven://u/ab"), tab: &tab))
        XCTAssertNil(router.route)
        XCTAssertFalse(router.handle(url("https://example.com/somewhere"), tab: &tab), "not a deep link: the caller's other handlers get it")
        XCTAssertFalse(router.handle(url("haven://nonsense/x"), tab: &tab))
        XCTAssertEqual(tab, "you")
    }

    func testANotificationTapOpensTheThreadOnTheMessagesTab() async {
        let store = await Harness.feed()
        let pal = Peer(byte: 0x3B, name: "Pal")
        await pal.befriend(store)
        let dm = store.startDM(with: pal.hex, name: "Pal")
        var tab = "circle"
        // The live Messages tab consumes `openThread` the moment it is set, so watch it being set.
        var pushed: [String] = []
        let watch = DMDraftStore.shared.$openThread.sink { if let t = $0 { pushed.append(t) } }
        defer { watch.cancel() }
        XCTAssertTrue(router.handle(url(DeepLink.interactionLink(circleId: dm, postId: "msg-9")), tab: &tab))
        XCTAssertEqual(tab, "messages")
        XCTAssertEqual(router.requestedTab, "messages")
        XCTAssertEqual(DMDraftStore.shared.takeScrollTarget(dm), "msg-9", "the thread scrolls to the exact message")
        await Harness.until(store, "the thread is pushed once the tab has switched") { pushed.contains(dm) }
        XCTAssertEqual(DeepLinkRouter.resolveDMCircle(dm), dm)
        XCTAssertEqual(DeepLinkRouter.resolveDMCircle("dm:\(pal.hex.uppercased())-\(store.myNodeHex.uppercased())"), dm,
                       "same participants, spelled differently, is the same thread")
    }

    func testACircleLinkSwitchesToThatCircle() async {
        let store = await Harness.feed()
        var tab = "you"
        XCTAssertTrue(router.handle(url("haven://c/default"), tab: &tab))
        XCTAssertEqual(tab, "circle")
        XCTAssertEqual(router.requestedTab, "circle")
        XCTAssertEqual(store.activeCircleId, "default")
        XCTAssertNil(router.route, "a circle link shows the circle, never a sheet")
    }

    func testOpeningAPostFromInsideTheAppUsesTheSameRules() {
        router.openPost(circleId: "default", postId: "p-in-app")
        guard case .post(_, let p)? = router.route else { return XCTFail("route") }
        XCTAssertEqual(p, "p-in-app")
        XCTAssertNil(router.requestedTab)
    }

    func testAStoryLinkInAReplyNamesTheStoryAndIsRememberedAfterTheLinkIsGone() {
        let target = DeepLink.storyLink(circleId: "default", postId: "story-7")
        let id = "reply-\(UUID().uuidString.prefix(8))"
        let withLink = message(id: id, isMe: true, at: 1_000, body: "love this \(target)")
        let t = DeepLink.storyReplyTarget(message: withLink, dmCircleId: "dm:aa-bb")
        XCTAssertEqual(t?.circleId, "default"); XCTAssertEqual(t?.postId, "story-7")
        XCTAssertTrue(DeepLink.isStoryReplyMessage(withLink, dmCircleId: "dm:aa-bb"))
        // Edited to remove the link: the remembered association still answers.
        let bare = message(id: id, isMe: true, at: 1_000, body: "love this")
        XCTAssertEqual(DeepLink.storyReplyTarget(message: bare, dmCircleId: "dm:aa-bb")?.postId, "story-7")
        XCTAssertEqual(StoryReplyAssociationStore.shared.lookup(messageId: id)?.circleId, "default")
        StoryReplyAssociationStore.shared.remember(messageId: "", circleId: "c", postId: "p")
        XCTAssertNil(StoryReplyAssociationStore.shared.lookup(messageId: ""))
        XCTAssertFalse(DeepLink.storyReplyAvailable(circleId: "default", postId: "no-such-story"))
    }

    func testALegacyMediaOnlyReplyIsMatchedToTheStoryThatWasLive() async throws {
        let store = await Harness.feed()
        let ann = Peer(byte: 0x3C, name: "Ann")
        await ann.befriend(store)
        let storyMedia = imgRef("c")
        let at = UInt64(Date().timeIntervalSince1970 * 1000) - 120_000
        _ = try ann.engine.post(circleId: "default", body: "my story", media: [storyMedia], music: nil, retentionSecs: 86_400,
                                story: true, muteVideo: false, createdAt: at)
        await ann.replay(into: store)
        await Harness.until(store, "ann's story is known") { store.messages(in: "default").contains { $0.story && !$0.isMe } }
        let story = try XCTUnwrap(store.messages(in: "default").first { $0.story && !$0.isMe })
        let dm = store.startDM(with: ann.hex, name: "Ann")
        await Harness.until(store, "the thread knows its partner") { store.dmPartnerHex(dm) == ann.hex }

        // I replied with just the story's picture, a minute after it went up: it's about that story.
        let reply = message(isMe: true, at: story.createdAt + 60_000, media: [imgRef("d")])
        let found = DeepLink.storyReplyTarget(message: reply, dmCircleId: dm)
        XCTAssertEqual(found?.postId, story.id)
        XCTAssertEqual(found?.circleId, "default")
        XCTAssertTrue(DeepLink.isStoryReplyMessage(reply, dmCircleId: dm))
        XCTAssertEqual(DeepLink.singleStoryLikeVisual(in: reply.media), imgRef("d"))
        XCTAssertNil(DeepLink.singleStoryLikeVisual(in: [imgRef("d"), imgRef("e")]), "two pictures are a share, not a reply")

        // A reply sent before the story existed, or an unsent one, or a multi-file send, is nobody's reply.
        XCTAssertNil(DeepLink.storyReplyTarget(message: message(isMe: true, at: story.createdAt - 5_000, media: [imgRef("f")]), dmCircleId: dm))
        XCTAssertNil(DeepLink.storyReplyTarget(message: message(isMe: true, at: story.createdAt + 60_000, media: [imgRef("f")], unsent: true), dmCircleId: dm))
        XCTAssertNil(DeepLink.storyReplyTarget(message: message(isMe: true, at: story.createdAt + 60_000, media: [imgRef("f"), "file_" + String(repeating: "1", count: 64)]), dmCircleId: dm))

        // A video, or a picture of unknown shape, is read as story-shaped.
        XCTAssertTrue(DeepLink.prefersStoryCrop(ref: "vid_" + String(repeating: "a", count: 64), postMedia: []))
        XCTAssertTrue(DeepLink.prefersStoryCrop(ref: imgRef("9"), postMedia: [imgRef("9")]), "unknown size → story-shaped")
    }

    func testAStoryOpensWhileLiveOrKeptAndNotOnceExpired() async throws {
        let store = await Harness.feed()
        let ann = Peer(byte: 0x3D, name: "Ann")
        await ann.befriend(store)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try ann.engine.post(circleId: "default", body: "live story", media: [imgRef("1")], music: nil, retentionSecs: 86_400,
                                story: true, muteVideo: false, createdAt: nowMs - 60_000)
        await ann.replay(into: store)
        await Harness.until(store, "the live story is known") { store.messages(in: "default").contains { $0.story && $0.body == "live story" } }
        let live = try XCTUnwrap(store.messages(in: "default").first { $0.story && $0.body == "live story" })
        XCTAssertEqual(StoryLinkView.resolve(circleId: "default", postId: live.id)?.id, live.id)
        let viaEngine = await StoryLinkView.resolveNow(circleId: "default", postId: live.id)
        XCTAssertEqual(viaEngine?.id, live.id)
        XCTAssertNil(StoryLinkView.resolve(circleId: "default", postId: "no-such-story"))
        let none = await StoryLinkView.resolveNow(circleId: "default", postId: "no-such-story")
        XCTAssertNil(none)

        // Past the 24 h window an unkept story is gone, even if the event is still in the store…
        let old = nowMs - 30 * 3_600_000
        _ = try ann.engine.post(circleId: "default", body: "old story", media: [imgRef("2")], music: nil, retentionSecs: nil,
                                story: true, muteVideo: false, createdAt: old)
        await ann.replay(into: store)
        if let stale = store.messages(in: "default").first(where: { $0.body == "old story" }) {
            XCTAssertNil(StoryLinkView.resolve(circleId: "default", postId: stale.id))
            let staleNow = await StoryLinkView.resolveNow(circleId: "default", postId: stale.id)
            XCTAssertNil(staleNow)
        }
        // …but one its author kept is revived from the snapshot, music and all.
        let keptId = "kept-\(UUID().uuidString.prefix(8))"
        let track = TrackRefFfi(catalogId: "cat-1", title: "Slow Morning", artist: "Wax & Wane", artworkUrl: "", durationMs: 1000)
        KeptStoriesStore.shared.keep(id: keptId, body: "kept", media: [imgRef("3")], createdAt: old, music: track)
        defer { KeptStoriesStore.shared.unkeep(keptId) }
        let revived = try XCTUnwrap(StoryLinkView.resolve(circleId: "default", postId: keptId))
        XCTAssertTrue(revived.isMe && revived.story)
        XCTAssertEqual(revived.music?.title, "Slow Morning")
        XCTAssertEqual(StoryLinkView.keptItem(keptId)?.body, "kept")
        XCTAssertNil(StoryLinkView.keptItem("not-kept"))
    }
}
