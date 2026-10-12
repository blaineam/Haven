import XCTest
import AppKit
@testable import HavenUITestHost

/// The qa-cmd v2 driver the e2e fleet drives the macOS client with (docs/QA.md): a JSON `{"op": …}`
/// drop file plus a `haven://qa` poke in, `qa-dump.json` out. These pin the contract the
/// orchestrator depends on — every op rides the same store call the UI uses, then refreshes the dump.
@MainActor
final class FeedStoreQaDriverTests: XCTestCase {
    private var dir: URL { QaFiles.dir! }
    private var dumpURL: URL { dir.appendingPathComponent("qa-dump.json") }

    private func readDump() -> [String: Any] {
        guard let d = try? Data(contentsOf: dumpURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    private func seq(_ d: [String: Any]) -> Int { (d["dump_seq"] as? Int) ?? -1 }

    /// Drop a command, poke the app, and wait (event-driven, no sleeps) for a dump that is newer than
    /// the one before it AND satisfies `expect`. A dump from an EARLIER op can land after this one
    /// started, so a newer sequence number alone does not prove the op ran.
    @discardableResult
    private func run(_ cmd: [String: Any], file: StaticString = #filePath, line: UInt = #line,
                     until expect: (([String: Any]) -> Bool)? = nil) async -> [String: Any] {
        let store = await Harness.feed()
        let before = seq(readDump())
        let data = try! JSONSerialization.data(withJSONObject: cmd)
        try! data.write(to: dir.appendingPathComponent("qa-cmd.json"), options: .atomic)
        XCTAssertTrue(store.handleMatrixQaURL(URL(string: "haven://qa?poke=1")!))
        await waitFor("dump after \(cmd["op"] ?? "?")", file: file, line: line) {
            let d = self.readDump()
            return self.seq(d) > before && (expect?(d) ?? true)
        }
        return readDump()
    }
    private func has(body: String) -> ([String: Any]) -> Bool {
        { d in ((d["posts"] as? [[String: Any]]) ?? []).contains { $0["body"] as? String == body } }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line,
                         _ cond: @escaping @MainActor () -> Bool) async {
        let store = await Harness.feed()
        await Harness.until(store, timeout: timeout, what, file: file, line: line, cond)
    }

    private func posts(_ d: [String: Any]) -> [[String: Any]] { (d["posts"] as? [[String: Any]]) ?? [] }

    func testRejectsForeignURLsAndPokesAnEmptyDrop() async {
        let store = await Harness.feed()
        XCTAssertFalse(store.handleMatrixQaURL(URL(string: "https://qa?x=1")!))
        XCTAssertFalse(store.handleMatrixQaURL(URL(string: "haven://other?x=1")!))
        XCTAssertTrue(store.handleMatrixQaURL(URL(string: "haven://qa?x=1")!), "a bare poke is accepted")
    }

    func testPostReactCommentAndTheDumpContract() async {
        let body = "qa post \(UUID().uuidString.prefix(6))"
        await Harness.feed().setActiveCircle("default")
        let d1 = await run(["op": "post", "body": body], until: has(body: body))
        XCTAssertEqual(d1["device"] as? String, "mac")
        XCTAssertFalse((d1["account_hex"] as? String ?? "").isEmpty)
        guard let row = posts(d1).first(where: { $0["body"] as? String == body }),
              let id = row["id"] as? String else { return XCTFail("the post is in the dump") }
        XCTAssertEqual(row["circle"] as? String, "default")
        XCTAssertEqual(row["story"] as? Bool, false)

        let d2 = await run(["op": "react", "target_id": id, "emoji": "🎉"]) { d in
            ((d["posts"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == id }
                .flatMap { $0["reactions"] as? [String: Int] }?["🎉"] == 1
        }
        XCTAssertEqual((posts(d2).first { $0["id"] as? String == id }?["reactions"] as? [String: Int])?["🎉"], 1)
        XCTAssertNotNil(d2["react_latency"], "the tap-to-publish latency is reported")

        let d3 = await run(["op": "comment", "target_id": id, "body": "nice"]) { d in
            let row = ((d["posts"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == id }
            return ((row?["comments"] as? [[String: Any]]) ?? []).contains { $0["body"] as? String == "nice" }
        }
        let comments = posts(d3).first { $0["id"] as? String == id }?["comments"] as? [[String: Any]]
        XCTAssertEqual(comments?.first?["body"] as? String, "nice")

        let d4 = await run(["op": "dump"])
        XCTAssertGreaterThan(seq(d4), seq(d3), "dump_seq is strictly increasing while the driver is healthy")
        for key in ["contacts", "circles", "dms", "pending_connections", "relay_stats", "relay_first", "perf", "call",
                    "hosted_relay", "friend_invites", "delivery", "heavy_work", "launch", "relay_backoff"] {
            XCTAssertNotNil(d4[key], "the dump keeps the \(key) block the orchestrator reads")
        }
        let unknown = await run(["op": "no_such_op"])
        XCTAssertGreaterThan(seq(unknown), seq(d4), "an unknown op still refreshes the dump")
    }

    func testStoryProfileAndMusicOps() async {
        let tag = UUID().uuidString.prefix(6)
        let d = await run(["op": "story", "body": "story \(tag)", "caption": "cap \(tag)"], until: has(body: "cap \(tag)"))
        let story = posts(d).first { $0["body"] as? String == "cap \(tag)" }
        XCTAssertEqual(story?["story"] as? Bool, true, "a story is a post with a 24 h life")
        XCTAssertEqual(story?["caption"] as? String, "cap \(tag)", "the caption wins over the body")

        let p = await run(["op": "profile", "name": "QA Mac \(tag)"]) { ($0["profile"] as? [String: Any])?["name"] as? String == "QA Mac \(tag)" }
        XCTAssertEqual((p["profile"] as? [String: Any])?["name"] as? String, "QA Mac \(tag)")

        let m = await run(["op": "music_post", "body": "tune \(tag)", "music": ["title": "Song", "artist": "Band"]], until: has(body: "tune \(tag)"))
        XCTAssertTrue(posts(m).contains { $0["body"] as? String == "tune \(tag)" })
    }

    func testPhotoVideoAndFilePosts() async throws {
        let tag = UUID().uuidString.prefix(6)
        let photo = await run(["op": "post", "body": "photo \(tag)", "media": "photo"], until: has(body: "photo \(tag)"))
        let prow = posts(photo).first { $0["body"] as? String == "photo \(tag)" }
        XCTAssertEqual((prow?["media_refs"] as? [String])?.count, 1, "a synthetic photo is attached")
        XCTAssertEqual((prow?["media_present"] as? [Bool]), [true])

        let video = await run(["op": "post", "body": "video \(tag)", "media": "video"], until: has(body: "video \(tag)"))
        let vrow = posts(video).first { $0["body"] as? String == "video \(tag)" }
        XCTAssertGreaterThanOrEqual((vrow?["media_refs"] as? [String])?.count ?? 0, 1, "the synthetic clip is encoded and attached")

        let f = FileManager.default.temporaryDirectory.appendingPathComponent("qa-\(tag).txt")
        try Data("hello file".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        let file = await run(["op": "file", "body": "file \(tag)", "file_path": f.path], until: has(body: "file \(tag)"))
        let frow = posts(file).first { $0["body"] as? String == "file \(tag)" }
        XCTAssertEqual((frow?["media_refs"] as? [String])?.first?.hasPrefix("file_"), true)
        let missing = await run(["op": "file", "body": "x", "file_path": "/nonexistent/qa.bin"])
        XCTAssertNil(posts(missing).first { $0["body"] as? String == "x" })
    }

    func testFriendOpsDMsConnectLinksAndApprovals() async {
        let store = await Harness.feed()
        let friend = Peer(byte: 0x91, name: "QA friend")
        await friend.befriend(store)
        let tag = UUID().uuidString.prefix(6)
        let dm = await run(["op": "dm", "dm_to": friend.hex, "body": "dm \(tag)"]) { d in
            ((d["dms"] as? [String: [[String: Any]]])?[friend.hex] ?? []).contains { $0["body"] as? String == "dm \(tag)" }
        }
        let thread = (dm["dms"] as? [String: [[String: Any]]])?[friend.hex]
        XCTAssertTrue(thread?.contains { $0["body"] as? String == "dm \(tag)" } ?? false, "the DM shows under the peer's hex")
        XCTAssertTrue((dm["contacts"] as? [[String: Any]])?.contains { $0["hex"] as? String == friend.hex } ?? false)
        _ = await run(["op": "mark_read"])
        _ = await run(["op": "mark_read", "circle_id": store.dmCircleId(with: friend.hex)])

        let created = await run(["op": "circle_create", "name": "QA circle \(tag)"]) { d in
            ((d["circles"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "QA circle \(tag)" }
        }
        let cid = (created["circles"] as? [[String: Any]])?.first { $0["name"] as? String == "QA circle \(tag)" }?["id"] as? String
        XCTAssertNotNil(cid)
        if let cid {
            let invited = await run(["op": "circle_invite", "circle_id": cid, "dm_to": friend.hex])
            _ = invited
            await waitFor("friend joined") { store.cachedMembers(cid).contains(friend.hex) }
            _ = await run(["op": "post", "body": "targeted \(tag)", "circle_id": cid], until: has(body: "targeted \(tag)"))
            XCTAssertEqual(store.activeCircleId, cid)
            _ = await run(["op": "remove_member", "circle_id": cid, "dm_to": friend.hex])
            await waitFor("friend removed") { !store.cachedMembers(cid).contains(friend.hex) }
            store.leaveActiveCircle()
        }
        _ = await run(["op": "circle_invite", "circle_id": "", "dm_to": "bad"])   // bad args are logged, not fatal

        // A link from a new person becomes a contact (the offline-invite entry point).
        let newcomer = Account.generate()
        let linked = await run(["op": "connect_link", "uri": newcomer.havenLink(domain: HavenSite.inviteDomain)]) { d in
            ((d["contacts"] as? [[String: Any]]) ?? []).contains { $0["hex"] as? String == newcomer.nodeIdHex() }
        }
        XCTAssertTrue((linked["contacts"] as? [[String: Any]])?.contains { $0["hex"] as? String == newcomer.nodeIdHex() } ?? false)

        // A stranger's hello waits for approval; the driver approves it (nobody taps Approve in an e2e).
        let stranger = Peer(byte: 0x92, name: "Wants in")
        func lp(_ d: Data) -> Data { Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)]) + d }
        var hello = Data([0])
        hello.append(lp(Data("default".utf8)))
        hello.append(lp(Data("Their circle".utf8)))
        hello.append(lp(stranger.bundle))
        store.deliverFrameForTesting(hello)
        await waitFor("request pending") { ConnectionsStore.shared.pending.contains { $0.idHex == stranger.hex } }
        let pending = await run(["op": "dump"])
        XCTAssertTrue((pending["pending_connections"] as? [String])?.contains(stranger.hex) ?? false)
        let approved = await run(["op": "approve_connections"]) { d in
            !((d["pending_connections"] as? [String]) ?? []).contains(stranger.hex)
        }
        XCTAssertFalse((approved["pending_connections"] as? [String])?.contains(stranger.hex) ?? true)
        XCTAssertTrue(ContactsStore.shared.contacts.contains { $0.idHex == stranger.hex })
    }

    func testInviteLinkRelayAndInfrastructureOps() async {
        let store = await Harness.feed()
        let invite = await run(["op": "invite_link"]) { !(($0["invite_link"] as? String) ?? "").isEmpty }
        XCTAssertFalse((invite["invite_link"] as? String ?? "").isEmpty, "the minted link is exposed through the dump")

        let relay = String(repeating: "b7", count: 32)
        let added = await run(["op": "add_relay", "relay": ["node": relay, "urls": ["https://qa-relay.example"], "token": "t"],
                               "default": false]) { _ in
            RelayMailboxStore.shared.relays(forCircle: "default").contains(relay)
        }
        XCTAssertTrue(RelayMailboxStore.shared.relays(forCircle: "default").contains(relay))
        XCTAssertNotNil(added["relay_stats"])
        let link = await run(["op": "relay_link"]) { !(($0["relay_link"] as? String) ?? "").isEmpty }
        XCTAssertFalse((link["relay_link"] as? String ?? "").isEmpty)
        let probe = await run(["op": "relay_probe", "relay": relay, "method": "GET", "key": "haven/x"]) { ($0["relay_probe"] as? [String: Any])?["relay"] as? String == relay }
        XCTAssertNotNil(probe["relay_probe"])
        _ = await run(["op": "relay_backoff_reset"])
        _ = await run(["op": "forget_relay", "hex": relay]) { _ in !RelayMailboxStore.shared.isActive(relay) }
        XCTAssertFalse(RelayMailboxStore.shared.isActive(relay))
        RelayMailboxStore.shared.eraseNow(relay); RelayMailboxStore.shared.dropErased(relay)

        _ = await run(["op": "heavy_work_override", "suspend": true, "reason": "unit test"]) { _ in HeavyWorkMonitor.current.suspendHeavyIO }
        XCTAssertTrue(HeavyWorkMonitor.current.suspendHeavyIO)
        XCTAssertEqual(HeavyWorkMonitor.current.forced, "unit test")
        _ = await run(["op": "heavy_work_override", "suspend": false]) { _ in !HeavyWorkMonitor.current.suspendHeavyIO }
        XCTAssertFalse(HeavyWorkMonitor.current.suspendHeavyIO)
        XCTAssertEqual(HeavyWorkMonitor.current.forced, "")
        for level in ["ultra", "low", "normal", "auto"] { _ = await run(["op": "link_constraint", "level": level]) }
        _ = await run(["op": "perf_reset"])
        _ = await run(["op": "media_ask", "ref": "img_" + String(repeating: "0", count: 64)])
        _ = await run(["op": "host_relay", "on": false])
        _ = await run(["op": "relay_history_cancel"])
        _ = await run(["op": "call_video", "on": false])
        _ = await run(["op": "call_end"])
        _ = await run(["op": "history_status"])
        _ = store
    }

    func testBulkPostsAndHistoryAndRecoveryOps() async {
        let tag = UUID().uuidString.prefix(6)
        let bulk = await run(["op": "posts_bulk", "count": "4", "body": "bulk \(tag)"]) { d in
            ((d["posts"] as? [[String: Any]]) ?? []).filter { ($0["body"] as? String)?.hasPrefix("bulk \(tag)") == true }.count == 4
        }
        XCTAssertEqual(posts(bulk).filter { ($0["body"] as? String)?.hasPrefix("bulk \(tag)") == true }.count, 4)
        _ = await run(["op": "history_request"]) { _ in HistoryHandoff.shared.isWaiting }
        XCTAssertTrue(HistoryHandoff.shared.isWaiting)
        _ = await run(["op": "history_cancel"]) { _ in !HistoryHandoff.shared.isWaiting }
        XCTAssertFalse(HistoryHandoff.shared.isWaiting)
        HistoryHandoff.shared.reset()
        _ = await run(["op": "recover_set_aside"])
        _ = await run(["op": "relay_history_resync", "reset_journal": true])
    }

    func testMatrixQaQueryItemsPostAndStory() async {
        let store = await Harness.feed()
        let tag = UUID().uuidString.prefix(6)
        XCTAssertTrue(store.handleMatrixQaURL(URL(string: "haven://qa?post=url%20post%20\(tag)&story=url%20story%20\(tag)")!))
        await waitFor("both land") {
            store.items.contains { $0.body == "url post \(tag)" } && store.items.contains { $0.body == "url story \(tag)" && $0.story }
        }
    }
}
