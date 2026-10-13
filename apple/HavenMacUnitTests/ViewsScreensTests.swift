import XCTest
import SwiftUI
import AppKit
@testable import HavenUITestHost

/// The tab screens and sheets rendered over a real store: messages, the You tab and its settings,
/// circle management, connect, onboarding, import, editing, reporting, activity and the media
/// viewer. Each is mounted in an off-screen `NSHostingView` so its body, subviews and
/// `onAppear` work run for real; where a screen reads a store, the store is seeded first.
@MainActor
final class ViewsScreensTests: XCTestCase {
    override func tearDown() async throws { ViewBench.reset() }

    private func identity() throws -> (seed: Data, account: Account, store: AccountStore) {
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        return (seed, try Account.fromSeed(seed: seed), AccountStore())
    }

    // MARK: messages

    func testMessagesListThreadAndPickerOverRealConversations() async throws {
        let store = await Harness.feed()
        let (_, account, _) = try identity()
        let friend = Peer(byte: 0x81, name: "Eve")
        await friend.befriend(store)
        let photo = ViewFixtures.jpeg("dm")
        XCTAssertTrue(MediaStore.shared.store(photo.ref, photo.data))
        defer { MediaStore.shared.delete(photo.ref) }

        await ViewBench.render(MessagesView(account: account), height: 800)   // no conversations yet: the empty state
        let dm = store.startDM(with: friend.hex, name: "Eve")
        await Harness.until(store, "dm circle exists") { store.circles.contains { $0.id == dm } }
        let sent = await store.authorMessage(to: dm, "hi Eve, see https://example.org/x", media: [photo.ref], music: ViewFixtures.track)
        XCTAssertTrue(sent)
        _ = await store.authorMessage(to: dm, "second", media: [], music: nil)
        await Harness.until(store, "messages stored") { store.messages(in: dm).count >= 2 }
        let first = try XCTUnwrap(store.messages(in: dm).first { $0.body.hasPrefix("hi Eve") })
        await store.reactMessageNow(in: dm, first.id, "❤️")
        await store.commentMessageNow(in: dm, first.id, "a reply to myself")
        await Harness.until(store, "reaction and reply landed") {
            store.messages(in: dm).first { $0.id == first.id }.map { !$0.reactions.isEmpty && !$0.comments.isEmpty } == true
        }

        // An incoming message makes the row unread.
        friend.engine.createCircle(id: dm, name: "me")
        _ = try? friend.engine.addContactBundle(circleId: dm, bundle: try XCTUnwrap(store.myPublicBundle()))
        _ = try? friend.engine.post(circleId: dm, body: "hey back", media: [], music: nil, retentionSecs: nil, story: false, muteVideo: false, createdAt: ViewFixtures.nowMs())
        await friend.replay(into: store, circle: dm)
        await Harness.until(store, "reply arrived") { store.unreadMessages(in: dm) > 0 }

        await ViewBench.renderDrawn(MessagesView(account: account), height: 800)
        DMPinStore.shared.toggle(dm)
        defer { DMPinStore.shared.remove(dm) }
        await ViewBench.renderDrawn(MessagesView(account: account), height: 800)   // pinned tile + unread badge

        let thread = await ViewBench.renderDrawn(DMThreadView(circleId: dm), height: 900)
        XCTAssertGreaterThan(thread.fittingSize.width, 0)
        // Opening a thread names a staged draft and a scroll target; both are consumed by the thread.
        DMDraftStore.shared.stage(circleId: dm, text: "draft staged from a post")
        DMDraftStore.shared.stageScroll(circleId: dm, messageId: first.id)
        await ViewBench.renderDrawn(DMThreadView(circleId: dm), height: 900)
        XCTAssertNil(DMDraftStore.shared.takeDraft(dm), "the thread took the staged draft")
        XCTAssertNil(DMDraftStore.shared.takeScrollTarget(dm), "the thread took the scroll target")
        DMDraftStore.shared.openThread = nil
        await ViewBench.render(DMThreadView(circleId: "dm:" + String(repeating: "0", count: 64)), height: 600)   // a thread we never synced

        var picked: String?
        await ViewBench.renderDrawn(DMContactPicker(onPick: { picked = $0 }), height: 700)
        XCTAssertNil(picked)
        await ViewBench.renderDrawn(DMSongChip(track: ViewFixtures.track, isMe: true).padding(8), height: 100)
        await ViewBench.render(DMSongChip(track: ViewFixtures.track, isMe: false).padding(8), height: 100)
        for n in [0, 3, 42, 150] { await ViewBench.render(UnreadBadge(count: n).padding(8), width: 80, height: 60) }
    }

    func testGroupThreadLabelsEachSenderAndStoryRepliesRender() async throws {
        let store = await Harness.feed()
        let a = Peer(byte: 0x84, name: "Hana"), b = Peer(byte: 0x85, name: "Ivo")
        await a.befriend(store); await b.befriend(store)
        let group = store.startGroupDM(members: [a.hex, b.hex], name: "Hana, Ivo")
        XCTAssertTrue(group.hasPrefix("dm:"))
        await Harness.until(store, "group exists with both members") {
            store.circles.contains { $0.id == group } && Set(store.dmMemberHexes(group)) == [a.hex, b.hex]
        }
        _ = await store.authorMessage(to: group, "hello both", media: [], music: nil)
        await Harness.until(store, "message in group") { store.messages(in: group).contains { $0.body == "hello both" } }
        for peer in [a, b] {
            peer.engine.createCircle(id: group, name: "g")
            _ = try? peer.engine.addContactBundle(circleId: group, bundle: try XCTUnwrap(store.myPublicBundle()))
            _ = try? peer.engine.post(circleId: group, body: "hi from \(peer.name)", media: [], music: nil, retentionSecs: nil, story: false,
                                      muteVideo: false, createdAt: ViewFixtures.nowMs())
            await peer.replay(into: store, circle: group)
        }
        await Harness.until(store, "both friends' messages arrive") {
            let bodies = Set(store.messages(in: group).map(\.body))
            return bodies.contains("hi from Hana") && bodies.contains("hi from Ivo")
        }
        await ViewBench.renderDrawn(DMThreadView(circleId: group), height: 900)
        let (_, account, _) = try identity()
        await ViewBench.renderDrawn(MessagesView(account: account), height: 800)
    }

    // MARK: the You tab and settings

    func testYouTabAndSettingsScreens() async throws {
        let store = await Harness.feed()
        _ = store
        let (_, account, accountStore) = try identity()
        let profile = ProfileStore.shared
        var resets = 0
        await ViewBench.renderDrawn(YouView(account: account, accountStore: accountStore, profile: profile, contacts: ContactsStore.shared,
                                            onReset: { resets += 1 }), width: 520, height: 1000)
        await ViewBench.renderDrawn(SettingsView(account: account, accountStore: accountStore, onReset: { resets += 1 }), width: 520, height: 1200)
        await ViewBench.renderDrawn(AdvancedView(account: account, accountStore: accountStore, onReset: { resets += 1 }), width: 520, height: 1000)
        await ViewBench.renderDrawn(IdentityBackupView(account: account, accountStore: accountStore), width: 520, height: 900)
        await ViewBench.renderDrawn(EditProfileSheet(), width: 520, height: 700)
        XCTAssertEqual(resets, 0, "mounting a screen never resets the identity")

        // Settings render in each combination of the switches that change what they show.
        let s = SettingsStore.shared
        let was = (s.superDataSaver, s.sendOriginal, s.keepMyPosts, s.retentionDays, s.localMediaMaxDays, s.localMediaMaxGB)
        defer { s.superDataSaver = was.0; s.sendOriginal = was.1; s.keepMyPosts = was.2; s.retentionDays = was.3; s.localMediaMaxDays = was.4; s.localMediaMaxGB = was.5 }
        s.superDataSaver = true; s.sendOriginal = true; s.keepMyPosts = false; s.retentionDays = 30; s.localMediaMaxDays = 60; s.localMediaMaxGB = 5
        await ViewBench.renderDrawn(SettingsView(account: account, accountStore: accountStore, onReset: {}), width: 520, height: 1200)
    }

    func testOnboardingRendersEveryStepsContent() async throws {
        _ = await Harness.feed()
        let (_, _, accountStore) = try identity()
        await ViewBench.renderDrawn(OnboardingView(profile: ProfileStore.shared, accountStore: accountStore), width: 520, height: 800)
    }

    // MARK: circles and connections

    func testCircleManagementScreens() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let (_, account, _) = try identity()
        let friend = Peer(byte: 0x82, name: "Fox")
        await friend.befriend(store)
        await ViewBench.renderDrawn(CircleView(account: account), width: 520, height: 900)
        await ViewBench.renderDrawn(CircleSettingsView(circleId: "default"), width: 520, height: 900)
        await ViewBench.render(CircleRelayOverrideSection(circleId: "default"), width: 520, height: 400)
        await ViewBench.renderDrawn(CircleLockView(circleName: "Family", circleId: "default"), width: 420, height: 700)
        await ViewBench.render(PrivacyBlurView(), width: 420, height: 700)

        // A circle with its own media overrides and a nickname draws differently from the default one.
        let c = CircleSettingsStore.shared
        defer { c.clearMediaOverrides(for: "default"); c.setNickname("", for: "default") }
        c.setNickname("The Crew", for: "default")
        c.setSaveOwn(false, for: "default"); c.setOptimize(false, for: "default"); c.setRetention(7, for: "default")
        await ViewBench.renderDrawn(CircleSettingsView(circleId: "default"), width: 520, height: 900)
        await ViewBench.renderDrawn(CircleView(account: account), width: 520, height: 900)
    }

    func testConnectScreenWithAndWithoutAnIncomingLink() async throws {
        _ = await Harness.feed()
        let (_, account, _) = try identity()
        await ViewBench.renderDrawn(ConnectView(account: account, contacts: ContactsStore.shared), width: 520, height: 900)
        await ViewBench.render(ConnectView(account: account, contacts: ContactsStore.shared, incomingLink: "not a real invite"), width: 520, height: 900)
        // A real invite link from another identity resolves to a "found" confirmation.
        let friendSeed = Data((0..<32).map { UInt8(truncatingIfNeeded: 0x91 &+ $0) })
        let friend = try Account.fromSeed(seed: friendSeed)
        let link = friend.havenLink(domain: HavenSite.inviteDomain)
        XCTAssertNotNil(try? parseLink(s: link), "the link we built parses back")
        await ViewBench.renderDrawn(ConnectView(account: account, contacts: ContactsStore.shared, incomingLink: link), width: 520, height: 900)
        // …and your own link is recognised too.
        await ViewBench.render(ConnectView(account: account, contacts: ContactsStore.shared, incomingLink: account.havenLink(domain: HavenSite.inviteDomain)),
                               width: 520, height: 900)
    }

    // MARK: import, edit, report, activity

    func testImportEditReportAndActivitySheets() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        await ViewBench.renderDrawn(InstagramImportView(circleId: "default", circleName: "Your circle"), width: 520, height: 800)

        let photo = ViewFixtures.jpeg("edit")
        XCTAssertTrue(MediaStore.shared.store(photo.ref, photo.data))
        defer { MediaStore.shared.delete(photo.ref) }
        let mine = ViewFixtures.item("e-mine", mine: true, body: "to be edited", media: [photo.ref], music: ViewFixtures.track)
        await ViewBench.renderDrawn(EditPostSheet(item: mine), width: 520, height: 800)
        await ViewBench.renderDrawn(EditPostSheet(item: ViewFixtures.item("e-text", mine: true, body: "just text")), width: 520, height: 700)

        let theirs = ViewFixtures.item("r-theirs", by: "ab12cd34", body: "reported content")
        await ViewBench.renderDrawn(ReportSheet(item: theirs, authorName: "Ben"), width: 480, height: 800)
        let reports = [ReportFfi(id: "rp1", reporter: String(repeating: "a", count: 64), reporterShort: "aaaa", target: theirs.id,
                                 author: String(repeating: "b", count: 64), reason: ReportReason.spam.rawValue, comment: "looks like a scam", createdAt: ViewFixtures.nowMs())]
        await ViewBench.renderDrawn(ReportedBanner(item: theirs, authorName: "Ben", reports: reports).padding(8), height: 300)

        let activity = ActivityStore.shared
        await ViewBench.render(ActivityView(), width: 480, height: 700)   // nothing happened yet
        activity.note(id: "views-act-1", kind: "post", circleId: "default", actorShort: "ab12", snippet: "posted a photo")
        activity.note(id: "views-act-2", kind: "comment", circleId: "default", actorShort: "cd34", snippet: "great shot")
        activity.noteFeedItem(ViewFixtures.item("views-act-3", by: "ef56", body: "a story", story: true, ago: 1), circleId: "default")
        activity.noteFeedItem(ViewFixtures.item("views-act-4", by: "0a1b", body: "a message", ago: 1), circleId: "dm:one-two")
        let hasActivity = activity.entries.contains { $0.id == "views-act-1" }
        XCTAssertTrue(hasActivity)
        await ViewBench.renderDrawn(ActivityView(), width: 480, height: 700)
        activity.markAllSeen()
        XCTAssertEqual(activity.unread, 0)
        await ViewBench.renderDrawn(ActivityView(), width: 480, height: 700)
    }

    func testReportingAPostHidesItAndTheBannerShowsTheReport() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let friend = Peer(byte: 0x86, name: "Jun")
        await friend.befriend(store)
        let body = "questionable post \(UUID().uuidString.prefix(6))"
        await friend.post(body, into: store)
        await Harness.until(store, "post arrives") { store.feedItems.contains { $0.body == body } }
        let post = try XCTUnwrap(store.feedItems.first { $0.body == body })
        defer { HiddenStore.shared.unhide(post.id) }

        // What the sheet's Report button does.
        let author = await store.report(circleId: "default", target: post.id, reason: ReportReason.harassment.rawValue, comment: "rude")
        XCTAssertEqual(author, friend.hex, "the core resolves the reported author's full id for the block offer")
        XCTAssertTrue(HiddenStore.shared.isHidden(post.id), "the reporter never sees it again")
        await Harness.until(store, "post hidden from the feed") { !store.feedItems.contains { $0.id == post.id } }
        let reports = store.reports(circleId: "default")[post.id] ?? []
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.reason, ReportReason.harassment.rawValue)
        XCTAssertEqual(reports.first?.comment, "rude")
        await ViewBench.renderDrawn(ReportedBanner(item: post, authorName: "Jun", reports: reports).padding(8), height: 300)

        // Blocking from the same sheet removes the connection.
        store.blockConnection(friend.hex)
        XCTAssertTrue(ConnectionsStore.shared.isBlocked(friend.hex))
        await Harness.until(store, "friend removed from contacts") { !ContactsStore.shared.contacts.contains { $0.idHex == friend.hex } }
        defer { ConnectionsStore.shared.unblock(friend.hex) }
    }

    // MARK: links, locations, avatars, the media viewer

    func testLinkAndLocationAndAvatarViews() async throws {
        let store = await Harness.feed()
        let friend = Peer(byte: 0x83, name: "Gus")
        await friend.befriend(store)
        await ViewBench.renderDrawn(LinkedText(text: "Plain words and https://example.org/page more words").padding(8), height: 200)
        await ViewBench.render(LinkedText(text: "no links at all", showsPreview: false).padding(8), height: 100)
        await ViewBench.render(LinkPreviewCard(url: URL(string: "https://example.org/page")!).padding(8), height: 300)
        await ViewBench.render(InAppBrowserView(url: URL(string: "about:blank")!), width: 600, height: 500)
        await ViewBench.render(LocationMapView(lat: 51.5007, lon: -0.1246, label: "Big Ben").frame(width: 300, height: 200), width: 320, height: 220)
        await ViewBench.render(LocationMapView(lat: 0, lon: 0, label: "").frame(width: 300, height: 200), width: 320, height: 220)
        await ViewBench.renderDrawn(HavenAvatar(image: nil, emoji: "🦊", size: 60), width: 80, height: 80)
        await ViewBench.renderDrawn(PeerAvatar(nodeHex: friend.hex, name: "Gus"), width: 60, height: 60)
        await ViewBench.renderDrawn(PeerAvatar(nodeHex: String(repeating: "7", count: 64), name: "Stranger"), width: 60, height: 60)
    }

    func testTheMediaViewerOpensPhotosAndMissingMedia() async throws {
        _ = await Harness.feed()
        let photos = (0..<2).map { ViewFixtures.jpeg("zoom-\($0)", side: 64) }
        for p in photos { XCTAssertTrue(MediaStore.shared.store(p.ref, p.data)) }
        defer { for p in photos { MediaStore.shared.delete(p.ref) } }
        await ViewBench.render(MediaZoomViewer(target: ZoomTarget(refs: photos.map(\.ref), index: 1)), width: 600, height: 800)
        await ViewBench.render(MediaZoomViewer(target: ZoomTarget(refs: [photos[0].ref], index: 0, postId: "p1", music: ViewFixtures.track, authorMutedVideo: true)),
                               width: 600, height: 800)
        await ViewBench.render(MediaZoomViewer(target: ZoomTarget(refs: ["img_" + String(repeating: "d", count: 64)], index: 0)), width: 600, height: 800)
    }

    // MARK: re-optimising media I already shared

    func testReoptimizeRowStatesAndAnEmptyScan() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let reopt = MediaReoptimizer.shared
        await ViewBench.renderDrawn(ReoptimizeMediaRow().padding(8), height: 300)
        XCTAssertTrue(reopt.candidates.isEmpty)
        await reopt.scan()
        XCTAssertTrue(reopt.hasScanned)
        XCTAssertFalse(reopt.scanning)
        XCTAssertTrue(reopt.candidates.isEmpty, "a fresh library has nothing to improve")
        XCTAssertEqual(reopt.pendingBytes, 0)
        XCTAssertEqual(reopt.posterOnlyCount, 0)
        await reopt.run()   // nothing to do: must be a no-op
        XCTAssertFalse(reopt.running)
        await ViewBench.renderDrawn(ReoptimizeMediaRow().padding(8), height: 300)
    }
}
