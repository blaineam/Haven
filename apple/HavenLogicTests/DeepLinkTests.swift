import XCTest

/// Link building + parsing + the router's classification table. The same shapes are emitted by
/// Android and the desktop app, and notification payloads (NSE) mirror `interactionLink`, so a
/// regression here silently breaks "tap a notification" on every platform.
final class DeepLinkTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Building

    func testProfileURL() {
        XCTAssertEqual(DeepLink.profileURL("abcdef0123")?.absoluteString, "haven://u/abcdef0123")
    }

    func testInteractionLinkShapes() {
        XCTAssertEqual(DeepLink.interactionLink(circleId: "default"), "haven://c/default")
        XCTAssertEqual(DeepLink.interactionLink(circleId: "default", postId: "p1"), "haven://p/default/p1")
        XCTAssertEqual(DeepLink.interactionLink(circleId: "default", postId: ""), "haven://c/default",
                       "an empty post id must fall back to the circle, not emit a dangling slash")
        XCTAssertEqual(DeepLink.interactionLink(circleId: "dm:aa-bb"), "haven://m/dm%3Aaa-bb")
        XCTAssertEqual(DeepLink.interactionLink(circleId: "dm:aa-bb", postId: "m9"), "haven://m/dm%3Aaa-bb/m9")
        XCTAssertEqual(DeepLink.interactionLink(circleId: "dm:aa-bb", postId: ""), "haven://m/dm%3Aaa-bb")
    }

    func testInteractionLinkEncodesDelimiters() {
        // `.` and `/` are the web form's delimiters, so an id containing them must be escaped.
        let link = DeepLink.interactionLink(circleId: "a.b/c", postId: "x y")
        XCTAssertEqual(link, "haven://p/a%2Eb%2Fc/x%20y")
    }

    func testStoryLinkAndRoundTrip() {
        let link = DeepLink.storyLink(circleId: "c.1", postId: "p.2")
        XCTAssertEqual(link, "haven://s/c%2E1/p%2E2")
        let parsed = DeepLink.parseStory(link)
        XCTAssertEqual(parsed?.circleId, "c.1")
        XCTAssertEqual(parsed?.postId, "p.2")
    }

    func testPostURLIsFragmentOnly() {
        let u = DeepLink.postURL(circleId: "circle-1", postId: "post~1")
        XCTAssertEqual(u?.absoluteString, "https://wemiller.com/apps/haven/open/#p/circle-1.post~1")
        // The privacy rule: nothing identifying may appear before the `#`.
        XCTAssertEqual(u?.path, "/apps/haven/open")
        XCTAssertFalse(u?.query?.isEmpty == false)
    }

    func testStoryURLRoundTripsThroughParseStory() {
        let u = DeepLink.storyURL(circleId: "dm:aa-bb", postId: "evt.9")!
        XCTAssertTrue(u.absoluteString.hasPrefix("https://wemiller.com/apps/haven/open/#s/"))
        let parsed = DeepLink.parseStory(u)
        XCTAssertEqual(parsed?.circleId, "dm:aa-bb")
        XCTAssertEqual(parsed?.postId, "evt.9")
    }

    // MARK: Parsing stories

    func testParseStoryTrimsWhitespaceAndRejectsEmpty() {
        XCTAssertNil(DeepLink.parseStory(""))
        XCTAssertNil(DeepLink.parseStory("   \n"))
        let parsed = DeepLink.parseStory("  haven://s/c/p \n")
        XCTAssertEqual(parsed?.circleId, "c")
        XCTAssertEqual(parsed?.postId, "p")
    }

    func testParseStoryRejectsMalformedAndForeign() {
        XCTAssertNil(DeepLink.parseStory("haven://s/onlyone"))
        XCTAssertNil(DeepLink.parseStory("haven://p/c/p"), "a post link is not a story")
        XCTAssertNil(DeepLink.parseStory("http://wemiller.com/apps/haven/open/#s/c.p"), "http is not https")
        XCTAssertNil(DeepLink.parseStory("https://example.com/apps/haven/open/#s/c.p"), "foreign host")
        XCTAssertNil(DeepLink.parseStory("https://wemiller.com/other/#s/c.p"), "path outside the site")
        XCTAssertNil(DeepLink.parseStory("https://wemiller.com/apps/haven/open/#s/nodot"))
        XCTAssertNil(DeepLink.parseStory("https://wemiller.com/apps/haven/open/#s/.p"), "empty circle")
        XCTAssertNil(DeepLink.parseStory("https://wemiller.com/apps/haven/open/#s/c."), "empty post")
    }

    func testParseStoryAcceptsLegacySitePath() {
        let parsed = DeepLink.parseStory("https://WEMILLER.com/apps/haven/#s/c.p")
        XCTAssertEqual(parsed?.circleId, "c")
        XCTAssertEqual(parsed?.postId, "p")
    }

    func testFirstStoryFindsTokenInBody() {
        let body = "so good!!\nhttps://wemiller.com/apps/haven/open/#s/c1.p1"
        let hit = DeepLink.firstStory(in: body)
        XCTAssertEqual(hit?.circleId, "c1")
        XCTAssertEqual(hit?.postId, "p1")
        XCTAssertEqual(hit?.raw, "https://wemiller.com/apps/haven/open/#s/c1.p1")
    }

    func testFirstStoryFindsAppSchemeAndMidString() {
        XCTAssertEqual(DeepLink.firstStory(in: "look haven://s/c/p now")?.postId, "p")
        // Pasted without whitespace in front of it: only the substring fallback can find this.
        let glued = "see:https://wemiller.com/apps/haven/open/#s/c9.p9 ok"
        let hit = DeepLink.firstStory(in: glued)
        XCTAssertEqual(hit?.circleId, "c9")
        XCTAssertEqual(hit?.raw, "https://wemiller.com/apps/haven/open/#s/c9.p9")
    }

    func testFirstStoryNilWhenNoStory() {
        XCTAssertNil(DeepLink.firstStory(in: ""))
        XCTAssertNil(DeepLink.firstStory(in: "just words https://example.com/x"))
        XCTAssertNil(DeepLink.firstStory(in: "a post link https://wemiller.com/apps/haven/open/#p/c.p"))
    }

    // MARK: Story window

    func testStoryWindowBoundary() {
        let created: UInt64 = 1_000_000
        let day = DeepLink.storyLifetimeMs
        XCTAssertEqual(day, 86_400_000)
        XCTAssertFalse(DeepLink.isPastStoryWindow(createdAt: created, now: created + day), "exactly 24h is still live")
        XCTAssertTrue(DeepLink.isPastStoryWindow(createdAt: created, now: created + day + 1))
        XCTAssertFalse(DeepLink.isPastStoryWindow(createdAt: created, now: created - 5), "clock skew: future story is live")
        XCTAssertFalse(DeepLink.isPastStoryWindow(createdAt: created, now: created))
    }

    func testNowMsIsMilliseconds() {
        let n = DeepLink.nowMs()
        XCTAssertGreaterThan(n, 1_700_000_000_000)
        XCTAssertLessThan(n, 4_000_000_000_000)
    }

    // MARK: Web post

    func testWebPostParsesCurrentAndLegacyPaths() {
        let a = DeepLink.webPost(url("https://wemiller.com/apps/haven/open/#p/circle.post"))
        XCTAssertEqual(a?.circleId, "circle")
        XCTAssertEqual(a?.postId, "post")
        let b = DeepLink.webPost(url("https://wemiller.com/apps/haven/#p/circle.post"))
        XCTAssertEqual(b?.postId, "post")
    }

    func testWebPostDecodesExactlyOnce() {
        let w = DeepLink.webPost(url("https://wemiller.com/apps/haven/open/#p/dm%3Aaa-bb.m%2E1"))
        XCTAssertEqual(w?.circleId, "dm:aa-bb")
        XCTAssertEqual(w?.postId, "m.1", "an escaped dot is part of the id, not the delimiter")
    }

    func testWebPostRejects() {
        XCTAssertNil(DeepLink.webPost(url("https://wemiller.com/apps/haven/open/")), "no fragment")
        XCTAssertNil(DeepLink.webPost(url("https://wemiller.com/apps/haven/open/#main")), "site anchor")
        XCTAssertNil(DeepLink.webPost(url("https://wemiller.com/apps/haven/open/#abc.def")), "that is an invite")
        XCTAssertNil(DeepLink.webPost(url("https://wemiller.com/features/#p/c.p")), "outside the claimed path")
        XCTAssertNil(DeepLink.webPost(url("https://evil.example/apps/haven/open/#p/c.p")))
        XCTAssertNil(DeepLink.webPost(url("http://wemiller.com/apps/haven/open/#p/c.p")))
        XCTAssertNil(DeepLink.webPost(url("https://wemiller.com/apps/haven/open/#p/.post")), "leading dot")
        XCTAssertNil(DeepLink.webPost(url("https://wemiller.com/apps/haven/open/#p/c.")), "empty post")
        XCTAssertNil(DeepLink.webPost(url("https://wemiller.com/apps/haven/open/#p/nodot")))
    }

    // MARK: Classification

    func testClassifyProfile() {
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://u/abcdef")), .profile(nodeHex: "abcdef"))
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://u/abc")), .ignored, "too short to be a node id")
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://u")), .ignored)
    }

    func testClassifyPost() {
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://p/c1/p1")), .post(circleId: "c1", postId: "p1"))
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://p/c1")), .ignored)
        XCTAssertEqual(DeepLinkTarget.classify(url("https://wemiller.com/apps/haven/open/#p/c1.p1")),
                       .post(circleId: "c1", postId: "p1"))
    }

    func testClassifyDM() {
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://m/dm%3Aaa-bb")), .dm(circleId: "dm:aa-bb", messageId: nil))
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://m/dm%3Aaa-bb/msg7")),
                       .dm(circleId: "dm:aa-bb", messageId: "msg7"))
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://m/notadm")), .ignored)
    }

    func testClassifyStory() {
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://s/c/p")), .story(circleId: "c", postId: "p"))
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://s/c")), .ignored)
        XCTAssertEqual(DeepLinkTarget.classify(url("https://wemiller.com/apps/haven/open/#s/c.p")),
                       .story(circleId: "c", postId: "p"))
    }

    func testClassifyCircle() {
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://c/default")), .circle(circleId: "default"))
        XCTAssertEqual(DeepLinkTarget.classify(url("haven://c")), .ignored)
    }

    func testClassifyNotOurs() {
        XCTAssertNil(DeepLinkTarget.classify(url("haven://invite#abc.def")), "invites fall through to the invite path")
        XCTAssertNil(DeepLinkTarget.classify(url("haven://share")))
        XCTAssertNil(DeepLinkTarget.classify(url("mailto:a@b.c")))
        XCTAssertNil(DeepLinkTarget.classify(url("https://wemiller.com/apps/haven/open/#abcd.efgh")))
        XCTAssertNil(DeepLinkTarget.classify(url("https://example.com/")))
    }

    // MARK: DM resolution

    func testResolveDMCircleExactAndParticipantMatch() {
        let known = ["default", "dm:aaaa-bbbb", "dm:cccc-dddd"]
        XCTAssertEqual(DeepLinkTarget.resolveDMCircle("dm:aaaa-bbbb", known: known), "dm:aaaa-bbbb")
        // Same participants, different case / order.
        XCTAssertEqual(DeepLinkTarget.resolveDMCircle("dm:BBBB-AAAA", known: known), "dm:aaaa-bbbb")
        // A thread we have not synced falls back to the id as given.
        XCTAssertEqual(DeepLinkTarget.resolveDMCircle("dm:eeee-ffff", known: known), "dm:eeee-ffff")
        // Not a dm id at all.
        XCTAssertEqual(DeepLinkTarget.resolveDMCircle("default", known: known), "default")
        XCTAssertEqual(DeepLinkTarget.resolveDMCircle("dm:", known: known), "dm:")
    }

    func testParticipantSet() {
        XCTAssertEqual(DeepLinkTarget.participantSet("dm:AA-bb"), ["aa", "bb"])
        XCTAssertEqual(DeepLinkTarget.participantSet("circle"), [])
    }

    // MARK: Route ids

    func testRouteIds() {
        XCTAssertEqual(DeepLinkRoute.profile(nodeHex: "ab").id, "u:ab")
        XCTAssertEqual(DeepLinkRoute.post(circleId: "c", postId: "p").id, "p:c:p")
        XCTAssertEqual(DeepLinkRoute.story(circleId: "c", postId: "p").id, "s:c:p")
    }

    // MARK: Legacy story inference

    func testStoryWasLiveWindow() {
        let day = LegacyStoryMatch.dayMs
        XCTAssertTrue(LegacyStoryMatch.storyWasLive(createdAt: 1_000, replyAt: 1_000))
        XCTAssertTrue(LegacyStoryMatch.storyWasLive(createdAt: 1_000, replyAt: 1_000 + day))
        XCTAssertFalse(LegacyStoryMatch.storyWasLive(createdAt: 1_000, replyAt: 1_001 + day))
        XCTAssertFalse(LegacyStoryMatch.storyWasLive(createdAt: 2_000, replyAt: 1_000), "story did not exist yet")
        XCTAssertTrue(LegacyStoryMatch.storyWasLive(createdAt: 1_000, replyAt: 1_000 + 3 * day,
                                                    windowMs: LegacyStoryMatch.keptWindowMs))
    }

    func testAuthorIsPeer() {
        let peer = "ABCDEF0123456789ABCDEF0123456789"
        XCTAssertTrue(LegacyStoryMatch.authorIsPeer("abcdef012345", peerHex: peer), "12-char short form")
        XCTAssertTrue(LegacyStoryMatch.authorIsPeer("ABCDEF", peerHex: peer), "shorter prefix")
        XCTAssertTrue(LegacyStoryMatch.authorIsPeer(peer, peerHex: peer), "full hex")
        XCTAssertFalse(LegacyStoryMatch.authorIsPeer("ffffff012345", peerHex: peer))
        XCTAssertFalse(LegacyStoryMatch.authorIsPeer("abcdef", peerHex: nil), "no known partner -> never match")
    }

    func testBestCandidateIsNewest() {
        typealias C = LegacyStoryMatch.Candidate
        XCTAssertNil(LegacyStoryMatch.best([]))
        let best = LegacyStoryMatch.best([C(circleId: "a", id: "1", createdAt: 10),
                                          C(circleId: "b", id: "2", createdAt: 30),
                                          C(circleId: "c", id: "3", createdAt: 20)])
        XCTAssertEqual(best?.id, "2")
    }

    // MARK: Site constants

    func testHavenSiteConstants() {
        XCTAssertEqual(HavenSite.host, "wemiller.com")
        XCTAssertEqual(HavenSite.path, HavenSite.sitePath)
        XCTAssertEqual(HavenSite.inviteDomain, "wemiller.com/apps/haven/open")
        XCTAssertTrue(HavenSite.inviteDomain.hasPrefix(HavenSite.host + HavenSite.sitePath),
                      "emitted links must sit under the matched prefix")
    }
}
