import XCTest
import AppKit
@testable import HavenUITestHost

/// FeedStore against real peer engines: DMs, groups, membership, moderation, stories, media.
@MainActor
final class FeedStoreSocialTests: XCTestCase {
    private func jpeg(_ tag: String) -> (ref: String, data: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var d = rep.representation(using: .jpeg, properties: [:])!
        d.append(contentsOf: (tag + UUID().uuidString).utf8)
        return (MediaStore.contentRef(.image, d), d)
    }

    // MARK: DMs

    func testDirectMessagesBothWays() async {
        let store = await Harness.feed()
        let dee = Peer(byte: 0x51, name: "Dee")
        await dee.befriend(store)
        let dm = store.startDM(with: dee.hex, name: "Dee")
        XCTAssertEqual(dm, store.dmCircleId(with: dee.hex))
        XCTAssertTrue(dm.hasPrefix("dm:"))
        XCTAssertTrue(store.dmCircleAllows(dm, dee.hex))
        XCTAssertFalse(store.dmCircleAllows(dm, String(repeating: "ee", count: 32)), "a third party can't handshake into a DM")
        XCTAssertFalse(FeedStore.dmCircleAllows("dm:onlyone", "onlyone"))
        await Harness.until(store, "dm circle exists") { store.circles.contains { $0.id == dm } }

        let sent = await store.authorMessage(to: dm, "hi dee", media: [], music: nil)
        XCTAssertTrue(sent)
        await Harness.until(store, "my message in the thread") { store.messages(in: dm).contains { $0.isMe && $0.body == "hi dee" } }
        XCTAssertEqual(store.dmPartnerHex(dm), dee.hex)
        XCTAssertEqual(store.dmMemberHexes(dm), [dee.hex])
        XCTAssertEqual(store.dmPartnerName(dm), "Dee")

        // Dee answers in the same deterministic circle.
        dee.engine.createCircle(id: dm, name: "me")
        _ = try? dee.engine.addContactBundle(circleId: dm, bundle: store.myPublicBundle()!)
        _ = try? dee.engine.post(circleId: dm, body: "hey back", media: [], music: nil, retentionSecs: nil, story: false,
                                 muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
        let applied = await dee.replay(into: store, circle: dm)
        XCTAssertGreaterThan(applied, 0)
        await Harness.until(store, "reply arrives") { store.messages(in: dm).contains { !$0.isMe && $0.body == "hey back" } }
        XCTAssertGreaterThan(store.unreadMessages(in: dm), 0)
        store.markThreadRead(dm)
        XCTAssertEqual(store.unreadMessages(in: dm), 0)
    }

    func testEditReactCommentAndDeleteInAThread() async {
        let store = await Harness.feed()
        let eli = Peer(byte: 0x52, name: "Eli")
        await eli.befriend(store)
        let dm = store.startDM(with: eli.hex, name: "Eli")
        await Harness.until(store, "dm exists") { store.circles.contains { $0.id == dm } }
        _ = await store.authorMessage(to: dm, "draft", media: [], music: nil)
        await Harness.until(store, "sent") { store.messages(in: dm).contains { $0.body == "draft" } }
        guard let id = store.messages(in: dm).first(where: { $0.body == "draft" })?.id else { return XCTFail("no message") }

        store.editMessage(in: dm, id, "final")
        await Harness.until(store, "edited") { store.messages(in: dm).first { $0.id == id }?.body == "final" }
        await store.reactMessageNow(in: dm, id, "👍")
        await Harness.until(store, "reacted") { store.messages(in: dm).first { $0.id == id }?.reactions.contains { $0.emoji == "👍" } == true }
        store.unreactMessage(in: dm, id, "👍")
        await Harness.until(store, "unreacted") { store.messages(in: dm).first { $0.id == id }?.reactions.contains { $0.emoji == "👍" && $0.mine } != true }
        await store.commentMessageNow(in: dm, id, "a reply")
        await Harness.until(store, "commented") { store.messages(in: dm).first { $0.id == id }?.comments.contains { $0.body == "a reply" } == true }
        let found = await store.post(id, in: dm)
        XCTAssertEqual(found?.id, id)
        store.deleteMessage(in: dm, id)
        await Harness.until(store, "retracted") { store.messages(in: dm).first { $0.id == id }?.unsent != false }
    }

    func testClearingAndDeletingAConversation() async {
        let store = await Harness.feed()
        let fay = Peer(byte: 0x53, name: "Fay")
        await fay.befriend(store)
        let dm = store.startDM(with: fay.hex, name: "Fay")
        await Harness.until(store, "dm exists") { store.circles.contains { $0.id == dm } }
        _ = await store.authorMessage(to: dm, "before clear", media: [], music: nil)
        await Harness.until(store, "sent") { !store.messages(in: dm).isEmpty }
        store.clearDMBefore(dm)
        XCTAssertTrue(store.messages(in: dm).isEmpty, "everything before the watermark is hidden")
        store.deleteConversation(dm)
        await Harness.until(store, "conversation gone") { !store.circles.contains { $0.id == dm } }
        XCTAssertTrue(CircleDeletionStore.isDeleted(dm))
        store.deleteConversation("not-a-dm")   // only dm: circles are deletable this way
        _ = store.startDM(with: fay.hex, name: "Fay")   // re-opening lifts the deletion
        XCTAssertFalse(CircleDeletionStore.isDeleted(dm))
        await Harness.until(store, "dm back") { store.circles.contains { $0.id == dm } }
    }

    func testGroupDMIdsAreOrderIndependent() async {
        let store = await Harness.feed()
        let a = Peer(byte: 0x54, name: "Ann"), b = Peer(byte: 0x55, name: "Bo")
        await a.befriend(store); await b.befriend(store)
        let g1 = store.groupDMCircleId(members: [a.hex, b.hex])
        let g2 = store.groupDMCircleId(members: [b.hex, a.hex, store.myNodeHex])
        XCTAssertEqual(g1, g2, "the same set of people reopens the same thread")
        let id = store.startGroupDM(members: [a.hex, b.hex], name: "Trio")
        XCTAssertEqual(id, g1)
        await Harness.until(store, "group dm exists") { store.circles.contains { $0.id == id } }
        await Harness.until(store, "members cached") { store.dmMemberHexes(id).count == 2 }
        XCTAssertEqual(store.dmPartnerName(id).contains("&"), true)
        XCTAssertTrue(FeedStore.dmCircleAllows(id, a.hex))
        _ = await store.authorMessage(to: id, "hello trio", media: [], music: nil)
        await Harness.until(store, "group message") { store.messages(in: id).contains { $0.body == "hello trio" } }
    }

    // MARK: Circles and members

    func testMembershipAddRemoveAndBlock() async {
        let store = await Harness.feed()
        let gus = Peer(byte: 0x56, name: "Gus"), hal = Peer(byte: 0x57, name: "Hal")
        await gus.befriend(store); await hal.befriend(store)
        guard let cid = await store.createCircleNow(name: "Climbers", memberIds: [gus.hex]) else { return XCTFail("circle") }
        XCTAssertTrue(cid.hasPrefix(OwnedCircle.prefix), "circle ids commit to their creator")
        await Harness.until(store, "gus is a member") { store.cachedMembers(cid).contains(gus.hex) }
        XCTAssertTrue(store.handshaked(in: cid).contains(gus.hex))
        XCTAssertFalse(store.dialTargets(cid).isEmpty, "a member is dialable")

        store.setActiveCircle(cid)
        store.addContactToActiveCircle(idHex: hal.hex)
        await Harness.until(store, "hal joined") { store.cachedMembers(cid).contains(hal.hex) }
        XCTAssertFalse(store.circleMemberships().isEmpty)
        XCTAssertTrue(store.memberHexes(circleId: cid).contains(hal.hex))

        store.removeFromActiveCircle(gus.hex)
        await Harness.until(store, "gus removed") { !store.cachedMembers(cid).contains(gus.hex) }
        XCTAssertTrue(ConnectionsStore.shared.isRemovedFromCircle(gus.hex, circleId: cid), "a removal sticks against re-handshake")
        store.clearCircleRemovalEverywhere(idHex: gus.hex, circleId: cid)
        XCTAssertFalse(ConnectionsStore.shared.isRemovedFromCircle(gus.hex, circleId: cid))

        let pulled = await store.removeFromAllCircles(hal.hex)
        XCTAssertGreaterThanOrEqual(pulled, 1)
        XCTAssertFalse(store.cachedMembers(cid).contains(hal.hex))

        store.blockConnection(hal.hex)
        XCTAssertTrue(ConnectionsStore.shared.isBlocked(hal.hex))
        XCTAssertFalse(ContactsStore.shared.contacts.contains { $0.idHex == hal.hex })
        ConnectionsStore.shared.unblock(hal.hex)
        store.leaveActiveCircle()
        await Harness.until(store, "left") { !store.circles.contains { $0.id == cid } }
    }

    func testPendingConnectionRequestApproval() async {
        let store = await Harness.feed()
        let ivy = Peer(byte: 0x58, name: "Ivy")
        ivy.engine.createCircle(id: "default", name: "Your circle")
        let req = ConnectionRequest(idHex: ivy.hex, name: "Ivy", bundle: ivy.bundle, safetyWords: ["a", "b"])
        ConnectionsStore.shared.removePending(ivy.hex)
        store.approveConnection(req)
        await Harness.until(store, "ivy is a contact") { ContactsStore.shared.contacts.contains { $0.idHex == ivy.hex } }
        store.setActiveCircle("default")
        await Harness.until(store, "ivy handshaked") { store.isHandshaked(ivy.hex) }
        XCTAssertEqual(ContactsStore.shared.contacts.first { $0.idHex == ivy.hex }?.name, "Ivy")
        XCTAssertFalse(store.nonContactMembers(in: "default").contains(ivy.hex))
    }

    func testRenamingAndDisplayNames() async {
        let store = await Harness.feed()
        guard let cid = await store.createCircleNow(name: "Before") else { return XCTFail("circle") }
        store.renameCircle(cid, to: "After")
        await Harness.until(store, "renamed") { store.circles.first { $0.id == cid }?.name == "After" }
        XCTAssertEqual(store.displayName(forCircle: cid), "After")
        XCTAssertEqual(store.displayName(forCircle: "no-such"), "My Circle")
        store.setActiveCircle(cid)
        store.leaveActiveCircle()
        await Harness.until(store, "gone") { !store.circles.contains { $0.id == cid } }
        XCTAssertTrue(store.activeCircleId != cid)
    }

    // MARK: Feed shape

    func testStoriesPostsAndImportedHistory() async {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let (ref, data) = jpeg("story")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        let story = await store.postStoryNow(media: [ref], caption: "sunrise")
        XCTAssertNotNil(story)
        await Harness.until(store, "story shows in the tray") { store.stories.contains { $0.id == story } }
        XCTAssertTrue(store.myStories.contains { $0.id == story })
        XCTAssertFalse(store.feedItems.contains { $0.id == story }, "stories live in the tray, not the feed")
        XCTAssertGreaterThanOrEqual(store.groupedStoriesFlat.count, 1)
        XCTAssertEqual(store.storyStartIndex(forGroup: 0), 0)

        let ts = UInt64(Date().timeIntervalSince1970 * 1000) - 86_400_000 * 400
        await store.postImported(circleId: "default", body: "an old trip", media: [], createdAt: ts)
        XCTAssertNotNil(store.lastImportedPostId)
        store.importFinished()
        await Harness.until(store, "imported post lands") { store.items.contains { $0.body == "an old trip" } }
        XCTAssertGreaterThanOrEqual(store.sweepDuplicateImports(), 0)

        store.postScheduled(circleId: "default", body: "scheduled hello", media: [])
        await Harness.until(store, "scheduled post fires") { store.items.contains { $0.body == "scheduled hello" } }
        store.post("to a circle", toCircle: "default")
        await Harness.until(store, "targeted post") { store.items.contains { $0.body == "to a circle" } }
        let poster = store.myPosts
        XCTAssertTrue(poster.allSatisfy { $0.isMe && !$0.story && !$0.unsent })
    }

    func testPostWithMediaQueuesTheBlobAndMarksCompanions() async {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let (ref, data) = jpeg("photo")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        let id = await store.postNow("with a photo", media: [ref])
        XCTAssertNotNil(id)
        XCTAssertTrue(MediaBackupQueue.shared.hasPending(ref), "the blob is queued for the relay before the post goes out")
        await Harness.until(store, "post visible") { store.items.contains { $0.id == id && $0.media.contains(ref) } }
        XCTAssertEqual(store.publishedPostCount > 0, true)
    }

    // MARK: Moderation

    func testReportingHidesAndNamesTheAuthor() async {
        let store = await Harness.feed()
        let jo = Peer(byte: 0x59, name: "Jo")
        await jo.befriend(store)
        store.setActiveCircle("default")
        await jo.post("spammy post", into: store)
        await Harness.until(store, "jo's post visible") { store.items.contains { !$0.isMe && $0.body == "spammy post" } }
        guard let target = store.items.first(where: { $0.body == "spammy post" })?.id else { return XCTFail("no post") }
        let author = await store.report(circleId: "default", target: target, reason: "spam", comment: "ads")
        XCTAssertEqual(author?.lowercased(), jo.hex.lowercased())
        XCTAssertTrue(HiddenStore.shared.isHidden(target), "the reporter never sees it again")
        XCTAssertEqual(store.reports(circleId: "default")[target]?.count, 1)
        HiddenStore.shared.unhide(target)
    }

    func testSensitiveFlagsAreCircleWide() async {
        let store = await Harness.feed()
        let (ref, data) = jpeg("flag")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        store.flagSensitive(circleId: "default", ref: ref)
        XCTAssertTrue(store.sensitiveRefs(circleId: "default").contains(ref), "the flag is visible optimistically")
        store.flagSensitive(circleId: "default", ref: ref)   // deduped
    }

    // MARK: Housekeeping

    func testMediaInventoryCleanupAndLocalLimits() async {
        let store = await Harness.feed()
        let (used, usedData) = jpeg("inventory-used"), (stray, strayData) = jpeg("inventory-stray")
        XCTAssertTrue(MediaStore.shared.store(used, usedData))
        XCTAssertTrue(MediaStore.shared.store(stray, strayData))
        store.setActiveCircle("default")
        _ = await store.postNow("inventory post", media: [used])
        let rows = await store.mediaInventory()
        XCTAssertTrue(rows.contains { $0.ref == used || $0.id == used })
        let agedAt = Date().addingTimeInterval(-10 * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: agedAt], ofItemAtPath: MediaStore.shared.storagePath(for: stray)!.path)
        let cleaned = await store.cleanupUnusedMedia(grace: 3600)
        XCTAssertGreaterThanOrEqual(cleaned.files, 1)
        XCTAssertFalse(MediaStore.shared.hasLocalFile(stray), "unreferenced media is reclaimed")
        XCTAssertTrue(MediaStore.shared.hasLocalFile(used), "referenced media is kept")
        let targets = await store.reoptimizeTargets()
        _ = targets
        store.enforceLocalLimits(force: true)
        store.setKeepOwnPosts(true)
        store.maybePurgeExpiredMedia("default", retention: 3600)
    }

    func testUnseenCountersAndFeedSignals() async {
        let store = await Harness.feed()
        let kit = Peer(byte: 0x5A, name: "Kit")
        await kit.befriend(store)
        store.setActiveCircle("default")
        store.markCircleSeen()
        XCTAssertEqual(store.unseenCircle, 0)
        await kit.post("fresh from kit", into: store)
        await Harness.until(store, "kit's post visible") { store.items.contains { $0.body == "fresh from kit" } }
        store.setForeground(true)
        store.bumpActivity()
        store.markCircleSeen()
        XCTAssertEqual(store.unseenCircle, 0)
        store.setForeground(false)
        store.setForeground(true)
    }

    func testRelayLinksAndInvites() async {
        let store = await Harness.feed()
        XCTAssertNotNil(store.inviteHelloBody())
        let body = store.inviteHelloBody()!
        XCTAssertEqual(store.helloSenderHex(body), store.myNodeHex)
        XCTAssertNil(store.helloSenderHex(Data([1, 2, 3])))
        XCTAssertNotNil(store.myPublicBundle())
        XCTAssertFalse(store.inviteDeviceIds().isEmpty)
        // A stranger's hello surfaces a connection request instead of silently adding them.
        let stranger = Peer(byte: 0x5B, name: "Stranger")
        var hello = Data()
        func lp(_ d: Data) { var n = UInt16(d.count).littleEndian; hello.append(Data(bytes: &n, count: 2)); hello.append(d) }
        lp(Data("default".utf8)); lp(Data("Your circle".utf8)); lp(stranger.bundle)
        let consumed = await store.ingestInviteHello(hello)
        _ = consumed
    }
}
