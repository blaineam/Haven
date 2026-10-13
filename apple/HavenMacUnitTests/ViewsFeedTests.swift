import XCTest
import SwiftUI
import AppKit
@testable import HavenUITestHost

/// The feed screens: the post card in every shape a post can take, its header, reactions and
/// comments, the sync pill, the story tray and the full feed over a store holding real posts from
/// real friends. State changes go through the store entry points the buttons call.
@MainActor
final class ViewsFeedTests: XCTestCase {
    override func tearDown() async throws { ViewBench.reset() }

    private func card(_ item: FeedItemFfi, expandAll: Bool = false, highlight: String? = nil) -> some View {
        PostCard(item: item, friendName: "Ada", onReact: { _ in }, onUnreact: { _ in }, onComment: { _, _ in },
                 onEdit: { _ in }, onUnsend: {}, expandAllComments: expandAll, highlightCommentId: highlight)
            .padding(8)
    }

    // MARK: post cards

    func testACardGrowsWithItsCommentsAndShowsEveryPostShape() async {
        _ = await Harness.feed()
        let plain = ViewFixtures.item("p-plain", body: "Just words")
        let withComments = ViewFixtures.item("p-comments", body: "Just words", comments: (1...4).map { ViewFixtures.comment("c\($0)", body: "comment number \($0)") })
        let a = await ViewBench.renderDrawn(card(plain), height: 1400)
        let b = await ViewBench.renderDrawn(card(withComments, expandAll: true), height: 1400)
        XCTAssertGreaterThan(b.fittingSize.height, a.fittingSize.height, "comments add height to the card")

        let react = [ViewFixtures.reaction("👍", count: 3, mine: true, authors: ["abcd", "ef01"]), ViewFixtures.reaction("❤️", count: 1)]
        let mixed: [FeedItemFfi] = [
            ViewFixtures.item("p-mine", mine: true, body: "My own post", edited: true),
            ViewFixtures.item("p-reactions", body: "Liked a lot", reactions: react),
            ViewFixtures.item("p-link", body: "Read https://example.org/article and tell me what you think"),
            ViewFixtures.item("p-music", body: "Song of the day", music: ViewFixtures.track),
            ViewFixtures.item("p-geo", body: "Here", media: [SharedLocation.ref(lat: 48.8584, lon: 2.2945, label: "Eiffel Tower")]),
            ViewFixtures.item("p-missing", body: "Photos that have not arrived", media: ["img_" + String(repeating: "e", count: 64)]),
            ViewFixtures.item("p-poll", body: "Vote", poll: PollFfi(question: "Pizza or tacos?", options: [PollOptionFfi(text: "Pizza", votes: 3), PollOptionFfi(text: "Tacos", votes: 1)],
                                                                totalVotes: 4, closeAtMs: 0, closed: false, myVote: 1)),
            ViewFixtures.item("p-closed-poll", body: "Done", poll: PollFfi(question: "Done?", options: [PollOptionFfi(text: "Yes", votes: 2)],
                                                                      totalVotes: 2, closeAtMs: ViewFixtures.nowMs(minus: 60), closed: true, myVote: nil)),
            ViewFixtures.item("p-unsent", body: "", unsent: true),
            ViewFixtures.item("p-empty", body: ""),
            ViewFixtures.item("p-old", body: "From a while back", ago: 3 * 365 * 86_400),
        ]
        for item in mixed { await ViewBench.renderDrawn(card(item), height: 1000) }

        // Real photos that ARE stored render as images, in a carousel and in a masonry tile.
        let photos = (0..<3).map { ViewFixtures.jpeg("feed-\($0)") }
        for p in photos { XCTAssertTrue(MediaStore.shared.store(p.ref, p.data)) }
        defer { for p in photos { MediaStore.shared.delete(p.ref) } }
        await ViewBench.renderDrawn(card(ViewFixtures.item("p-one", media: [photos[0].ref])), height: 1000)
        await ViewBench.renderDrawn(card(ViewFixtures.item("p-three", body: "Three photos", media: photos.map(\.ref))), height: 1400)
        await ViewBench.renderDrawn(card(ViewFixtures.item("p-mixed", body: "Photos and a pin",
                                                       media: [photos[0].ref, SharedLocation.ref(lat: 1, lon: 2, label: "x")])), height: 1400)
    }

    func testCommentsListShowsRepliesReactionsAndHighlights() async {
        _ = await Harness.feed()
        let photo = ViewFixtures.jpeg("comment-photo")
        XCTAssertTrue(MediaStore.shared.store(photo.ref, photo.data))
        defer { MediaStore.shared.delete(photo.ref) }
        let comments: [FeedCommentFfi] = [
            ViewFixtures.comment("c1", body: "first"),
            ViewFixtures.comment("c2", mine: true, body: "mine, edited", edited: true, reactions: [ViewFixtures.reaction("😂", count: 2, mine: true)]),
            ViewFixtures.comment("c3", body: "", media: [photo.ref]),
            ViewFixtures.comment("c4", body: "gone", unsent: true),
            ViewFixtures.comment("c5", body: "see https://example.org/x"),
        ]
        let item = ViewFixtures.item("p-list", mine: true, body: "Thread", comments: comments)
        var edited: FeedCommentFfi?
        let list = PostCommentsList(item: item, friendName: "Ada", expandAllComments: true, highlightCommentId: "c3",
                                    onReact: { _ in }, onUnreact: { _ in }, onComment: { _, _ in }, onEdit: { _ in },
                                    onUnsend: {}, onEditComment: { edited = $0 })
        await ViewBench.renderDrawn(list.padding(8), height: 1200)
        XCTAssertNil(edited, "rendering alone edits nothing")
        // Collapsed (the feed default) and with no comments at all.
        await ViewBench.renderDrawn(PostCommentsList(item: item, friendName: "Ada", expandAllComments: false, onReact: { _ in }, onUnreact: { _ in },
                                                     onComment: { _, _ in }, onEdit: { _ in }, onUnsend: {}, onEditComment: { _ in }).padding(8))
        await ViewBench.render(PostCommentsList(item: ViewFixtures.item("p-none"), friendName: "Ada", expandAllComments: true, onReact: { _ in }, onUnreact: { _ in },
                                                onComment: { _, _ in }, onEdit: { _ in }, onUnsend: {}, onEditComment: { _ in }).padding(8))
        await ViewBench.renderDrawn(PostCommentsSheet(item: item, friendName: "Ada", onReact: { _ in }, onComment: { _, _ in },
                                                      onEdit: { _ in }, onUnsend: {}), height: 900)
    }

    func testReactionRowAndCommentFieldPieces() async {
        _ = await Harness.feed()
        await ViewBench.renderDrawn(PostReactionsRow(reactions: [ViewFixtures.reaction("👍", count: 2, mine: true), ViewFixtures.reaction("🎉")],
                                                     onReact: { _ in }, onUnreact: { _ in }).padding(8), height: 200)
        await ViewBench.render(PostReactionsRow(reactions: [], onReact: { _ in }, onUnreact: { _ in }).padding(8), height: 200)
        await ViewBench.renderDrawn(PostCommentField(onSubmit: { _, _ in }, onFocus: { _ in }).padding(8), height: 200)
        await ViewBench.renderDrawn(PostCarouselDots(count: 5, currentPage: 2).padding(8), height: 100)
        await ViewBench.render(PostCarouselDots(count: 1, currentPage: 0).padding(8), height: 100)
        await ViewBench.renderDrawn(PostMediaPlaceholder(item: ViewFixtures.item("p-ph", media: ["img_" + String(repeating: "f", count: 64)]),
                                                         ref: "img_" + String(repeating: "f", count: 64)).frame(width: 300, height: 200), width: 320, height: 220)
        await ViewBench.render(KeepOnDeviceButton(ref: "img_" + String(repeating: "f", count: 64)).padding(8), height: 100)
        await ViewBench.render(PostMuteButton(item: ViewFixtures.item("p-mute", media: ["vid_" + String(repeating: "a", count: 64)]),
                                              ref: "vid_" + String(repeating: "a", count: 64)).padding(8), height: 100)
        await ViewBench.render(PostFileAttachmentPage(ref: "file_" + String(repeating: "b", count: 64)).frame(width: 300, height: 200), width: 320, height: 220)
        await ViewBench.render(OwnPostBackupBadge(blobs: ["img_" + String(repeating: "c", count: 64)], circleId: "default").padding(8), height: 100)
        await ViewBench.render(MyAvatar(size: 40), width: 60, height: 60)
    }

    func testHeaderMenusForMineAndTheirs() async {
        _ = await Harness.feed()
        struct Holder: View {
            let item: FeedItemFfi
            @State var edit = false
            @State var report = false
            @State var story: StoryShareTarget?
            var body: some View {
                PostHeader(item: item, friendName: "Ada", authorName: "Bea", storyableMedia: [], onUnsend: {},
                           showEdit: $edit, showReport: $report, storyShare: $story).padding(8)
            }
        }
        await ViewBench.renderDrawn(Holder(item: ViewFixtures.item("h-theirs", by: "ab12cd34", body: "hi")), height: 200)
        await ViewBench.renderDrawn(Holder(item: ViewFixtures.item("h-mine", mine: true, body: "hi", edited: true)), height: 200)
        await ViewBench.renderDrawn(Holder(item: ViewFixtures.item("h-story", body: "", story: true)), height: 200)
    }

    func testMasonryTilesForPresentAndMissingMedia() async {
        _ = await Harness.feed()
        let photo = ViewFixtures.jpeg("masonry")
        XCTAssertTrue(MediaStore.shared.store(photo.ref, photo.data))
        defer { MediaStore.shared.delete(photo.ref) }
        struct Holder: View {
            let item: FeedItemFfi; let ref: String
            @State var zoom: ZoomTarget?
            var body: some View { PostMasonryTile(item: item, media: [ref], ref: ref, height: 160, zoomTarget: $zoom).frame(width: 200, height: 160) }
        }
        await ViewBench.renderDrawn(Holder(item: ViewFixtures.item("m1", media: [photo.ref]), ref: photo.ref), width: 220, height: 180)
        let gone = "img_" + String(repeating: "9", count: 64)
        await ViewBench.render(Holder(item: ViewFixtures.item("m2", media: [gone]), ref: gone), width: 220, height: 180)
    }

    // MARK: sync pill

    func testSyncPillAndDetailReflectTheStore() async {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        SyncMetrics.shared.nbMediaOut = 3; SyncMetrics.shared.nbMediaIn = 5; SyncMetrics.shared.nbMediaPending = 2
        defer { SyncMetrics.shared.nbMediaOut = 0; SyncMetrics.shared.nbMediaIn = 0; SyncMetrics.shared.nbMediaPending = 0 }
        await ViewBench.renderDrawn(SyncDetailView(), width: 320, height: 300)
        await ViewBench.render(SyncStatusBadge(circleId: "default").padding(8), height: 100)
        await ViewBench.render(SyncStatusBadge(circleId: "dm:nobody").padding(8), height: 100)
    }

    // MARK: the whole feed over real posts

    func testTheFeedShowsPostsFromFriendsAndOwnPostsThroughTheComposerPath() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let friend = Peer(byte: 0x71, name: "Cleo")
        await friend.befriend(store)
        await friend.post("hello from Cleo", into: store)
        await Harness.until(store, "friend post in the feed") { store.feedItems.contains { $0.body == "hello from Cleo" } }

        // What the composer's Send button calls.
        let sent = await store.postNow("my first post")
        XCTAssertNotNil(sent)
        await Harness.until(store, "own post in the feed") { store.feedItems.contains { $0.isMe && $0.body == "my first post" } }
        let mine = try XCTUnwrap(store.feedItems.first { $0.id == sent })
        XCTAssertEqual(mine.body, "my first post")

        // Reactions, comments, edits and unsend: the closures the card hands the feed.
        store.react(mine.id, "👍")
        await Harness.until(store, "reaction") { store.feedItems.first { $0.id == mine.id }?.reactions.contains { $0.emoji == "👍" && $0.mine } == true }
        store.unreact(mine.id, "👍")
        await Harness.until(store, "unreaction") { store.feedItems.first { $0.id == mine.id }?.reactions.contains { $0.mine } != true }
        store.comment(mine.id, "a note to self")
        await Harness.until(store, "comment") { store.feedItems.first { $0.id == mine.id }?.comments.contains { $0.body == "a note to self" } == true }
        store.edit(mine.id, "my first post (edited)")
        await Harness.until(store, "edit") { store.feedItems.first { $0.id == mine.id }?.body == "my first post (edited)" }
        XCTAssertEqual(store.feedItems.first { $0.id == mine.id }?.edited, true)

        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let account = try Account.fromSeed(seed: seed)
        let feed = await ViewBench.renderDrawn(FeedView(account: account, seed: seed, friendName: "Ada"), width: 520, height: 1000)
        XCTAssertGreaterThan(feed.fittingSize.height, 0)
        _ = await ViewBench.renderDrawn(UserProfileView(authorHex: friend.hex, name: "Cleo"), width: 520, height: 900)
        _ = await ViewBench.renderDrawn(ProfileView(friendName: "Ada"), width: 520, height: 900)
        _ = await ViewBench.renderDrawn(NewCircleView(onCreate: { _, _ in }), width: 480, height: 600)

        store.unsend(mine.id)
        await Harness.until(store, "unsent post leaves the feed") { !store.feedItems.contains { $0.id == mine.id } }
        XCTAssertTrue(store.feedItems.contains { $0.body == "hello from Cleo" }, "only the unsent post left")
        _ = await ViewBench.renderDrawn(FeedView(account: account, seed: seed, friendName: "Ada"), width: 520, height: 1000)
    }

    func testTheStoryTrayAndViewer() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let friend = Peer(byte: 0x72, name: "Dov")
        await friend.befriend(store)
        let photo = ViewFixtures.jpeg("story")
        XCTAssertTrue(MediaStore.shared.store(photo.ref, photo.data))
        defer { MediaStore.shared.delete(photo.ref) }
        _ = try? friend.engine.post(circleId: "default", body: "story caption", media: [photo.ref], music: nil, retentionSecs: 86_400, story: true,
                                    muteVideo: false, createdAt: ViewFixtures.nowMs())
        await friend.replay(into: store)
        await Harness.until(store, "story arrives") { !store.groupedStoriesFlat.isEmpty }
        XCTAssertEqual(store.storyStartIndex(forGroup: 0), 0)
        XCTAssertFalse(store.feedItems.contains { $0.story }, "stories live in the tray, not the main list")

        let stories = store.groupedStoriesFlat
        let viewer = await ViewBench.renderDrawn(StoryViewer(stories: stories, index: 0, friendName: "Ada"), width: 420, height: 800)
        XCTAssertGreaterThan(viewer.fittingSize.width, 0)
        // An out-of-range story list renders nothing but must not crash.
        _ = await ViewBench.render(StoryViewer(stories: [], index: 0, friendName: "Ada"), width: 420, height: 800)
        // Variants the viewer branches on: an imported story, one with a song, one embedding a post, a long caption.
        let embed = StoryEmbed.encode(StoryEmbed.Ref(circleId: "default", postId: "some-post", musicStartMs: 1500), caption: "look at this")
        for variant in [ViewFixtures.item("ig:imported-1", by: stories[0].authorShort, body: "imported", media: [photo.ref], story: true),
                        ViewFixtures.item("s-song", by: stories[0].authorShort, body: "with a song", media: [photo.ref], music: ViewFixtures.track, story: true),
                        ViewFixtures.item("s-embed", by: stories[0].authorShort, body: embed, media: [photo.ref], story: true),
                        ViewFixtures.item("s-long", by: stories[0].authorShort, body: String(repeating: "a long caption ", count: 40), media: [photo.ref], story: true),
                        ViewFixtures.item("s-nomedia", by: stories[0].authorShort, body: "words only", story: true)] {
            _ = await ViewBench.renderDrawn(StoryViewer(stories: [variant], index: 0, friendName: "Ada"), width: 420, height: 800)
        }
        let mineStory = ViewFixtures.item("s-mine", mine: true, body: "mine", media: [photo.ref], story: true)
        _ = await ViewBench.renderDrawn(StoryViewer(stories: [mineStory, stories[0]], index: 0, friendName: "Ada"), width: 420, height: 800)
    }
}
