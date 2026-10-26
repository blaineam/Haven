import XCTest

/// What the Notification Service Extension turns a sealed push payload into. The failure modes are
/// the privacy ones: a banner quoting a biometric-locked circle, or "private" detail leaking content.
final class NotificationPayloadTests: XCTestCase {
    private typealias C = NotificationPayloadCodec

    private func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    private func decode(_ o: [String: Any], locked: Set<String> = []) -> NotificationPayload? {
        C.decode(json(o), lockedCircles: locked)
    }

    // MARK: decode

    func testDecodeMessagePayload() throws {
        let p = try XCTUnwrap(decode(["t": "Mom", "b": "dinner at 6?", "bp": "Sent you a message", "c": "dm:aa-bb",
                                      "k": "dm", "p": "m42", "mk": "haven/mailbox/x", "mr": ["img_1", "img_2"]]))
        XCTAssertEqual(p.title, "Mom")
        XCTAssertEqual(p.fullBody, "dinner at 6?")
        XCTAssertEqual(p.body, "dinner at 6?")
        XCTAssertEqual(p.privateBody, "Sent you a message")
        XCTAssertEqual(p.kind, "dm")
        XCTAssertEqual(p.threadId, "dm:aa-bb", "notifications group by circle")
        XCTAssertEqual(p.circleId, "dm:aa-bb")
        XCTAssertEqual(p.postId, "m42")
        XCTAssertEqual(p.mailboxKey, "haven/mailbox/x")
        XCTAssertEqual(p.mediaRefs, ["img_1", "img_2"])
        XCTAssertEqual(p.deepLink, "haven://m/dm%3Aaa-bb/m42")
        XCTAssertFalse(p.redactedForLock)
    }

    func testDecodeDefaultsWhenFieldsMissing() throws {
        let p = try XCTUnwrap(decode(["c": "default"]))
        XCTAssertEqual(p.title, "Haven")
        XCTAssertEqual(p.fullBody, "New message")
        XCTAssertNil(p.privateBody)
        XCTAssertEqual(p.deepLink, "haven://c/default")
    }

    func testDecodeThreadFallsBackToKindWithoutACircle() throws {
        let p = try XCTUnwrap(decode(["t": "Ana", "b": "hi", "k": "react"]))
        XCTAssertEqual(p.threadId, "react")
        XCTAssertNil(p.deepLink, "no circle -> no tap route")
    }

    func testEmptyBodyFallsBackToTheKind() throws {
        XCTAssertEqual(try XCTUnwrap(decode(["b": "", "k": "story"])).fullBody, "Shared a story")
        XCTAssertEqual(try XCTUnwrap(decode(["b": "", "k": "react", "e": "🔥"])).fullBody, "Reacted 🔥")
        XCTAssertEqual(try XCTUnwrap(decode(["b": "", "k": "react"])).fullBody, "Reacted 👍")
        XCTAssertEqual(try XCTUnwrap(decode(["b": ""])).fullBody, "", "no kind -> nothing to fall back to")
    }

    func testCallPayloadIsRecognisedByHexWithoutBody() throws {
        let p = try XCTUnwrap(decode(["t": "Dad", "h": "abcdef"]))
        XCTAssertEqual(p.kind, "call")
        XCTAssertEqual(p.threadId, "abcdef")
        XCTAssertEqual(p.privateBody, "Incoming call")
        XCTAssertTrue(p.fullBody.contains("Incoming call"))
        XCTAssertNil(p.deepLink)
        XCTAssertNil(p.emoji)
    }

    func testBodyPresentWinsOverCallShape() throws {
        XCTAssertEqual(try XCTUnwrap(decode(["t": "x", "b": "text", "h": "abc"])).kind, nil)
    }

    func testDecodeRejectsNonObjectJSON() {
        XCTAssertNil(C.decode(Data("not json".utf8), lockedCircles: []))
        XCTAssertNil(C.decode(Data("[1,2]".utf8), lockedCircles: []))
        XCTAssertNil(C.decode(Data(), lockedCircles: []))
    }

    // MARK: Locked circles

    func testLockedCircleIsRedacted() throws {
        let p = try XCTUnwrap(decode(["t": "Secret Sender", "b": "the actual secret", "c": "vault", "k": "dm", "p": "p1",
                                      "mk": "k", "mr": ["img"]], locked: ["vault"]))
        XCTAssertTrue(p.redactedForLock)
        XCTAssertEqual(p.title, "Haven")
        XCTAssertEqual(p.fullBody, "New activity in a locked circle")
        XCTAssertEqual(p.privateBody, "New activity in a locked circle")
        XCTAssertEqual(p.kind, "locked")
        XCTAssertEqual(p.deepLink, "haven://c/vault", "the tap opens the circle, whose lock screen takes over")
        XCTAssertNil(p.postId, "a locked circle's post id is not carried")
        XCTAssertNil(p.mailboxKey)
        XCTAssertNil(p.mediaRefs, "no prefetch of media for a locked circle")
        XCTAssertFalse(p.fullBody.contains("secret"))
    }

    func testUnlockedCircleIsNotRedactedWhenOthersAreLocked() throws {
        let p = try XCTUnwrap(decode(["b": "hello", "c": "open"], locked: ["vault"]))
        XCTAssertFalse(p.redactedForLock)
        XCTAssertEqual(p.fullBody, "hello")
    }

    func testRedactIfLockedNeedsACircleId() {
        XCTAssertNil(C.redactIfLocked(["b": "x"], lockedCircles: ["vault"]))
        XCTAssertNil(C.redactIfLocked(["c": "other"], lockedCircles: ["vault"]))
        XCTAssertNotNil(C.redactIfLocked(["c": "vault"], lockedCircles: ["vault"]))
    }

    // MARK: applyPrivacy

    func testApplyPrivacyByDetailLevel() throws {
        let p = try XCTUnwrap(decode(["t": "Mom", "b": "dinner?", "bp": "Sent you a message", "k": "dm", "c": "dm:a-b"]))
        XCTAssertEqual(C.applyPrivacy(p, detail: .full).title, "Mom")
        XCTAssertEqual(C.applyPrivacy(p, detail: .full).body, "dinner?")
        XCTAssertEqual(C.applyPrivacy(p, detail: .privateDetail).title, "Mom")
        XCTAssertEqual(C.applyPrivacy(p, detail: .privateDetail).body, "Sent you a message")
        let min = C.applyPrivacy(p, detail: .minimal)
        XCTAssertEqual(min.title, "Haven", "minimal hides the sender too")
        XCTAssertEqual(min.body, "New activity")
    }

    func testApplyPrivacyPrivateFallsBackToKindWhenNoPrivateBody() throws {
        let p = try XCTUnwrap(decode(["t": "Ana", "b": "secret text", "k": "comment"]))
        XCTAssertEqual(C.applyPrivacy(p, detail: .privateDetail).body, "Left a comment")
    }

    func testApplyPrivacyNeverQuotesALockedCircleAtAnyLevel() throws {
        let p = try XCTUnwrap(decode(["t": "Mom", "b": "secret", "c": "vault"], locked: ["vault"]))
        for d in SharedNotificationPrivacy.Detail.allCases {
            let shown = C.applyPrivacy(p, detail: d)
            XCTAssertEqual(shown.title, "Haven")
            XCTAssertEqual(shown.body, "New activity in a locked circle", "detail \(d)")
        }
    }

    // MARK: Deep links

    func testDeepLinkShapes() {
        XCTAssertNil(C.deepLink(circleId: nil, postId: "p"))
        XCTAssertNil(C.deepLink(circleId: "", postId: "p"))
        XCTAssertEqual(C.deepLink(circleId: "c", postId: nil), "haven://c/c")
        XCTAssertEqual(C.deepLink(circleId: "c", postId: "p"), "haven://p/c/p")
        XCTAssertEqual(C.deepLink(circleId: "c", postId: "p", kind: "story"), "haven://s/c/p")
        XCTAssertEqual(C.deepLink(circleId: "c", postId: "", kind: "story"), "haven://c/c", "no id, no story")
        XCTAssertEqual(C.deepLink(circleId: "dm:a-b", postId: nil), "haven://m/dm%3Aa-b")
        XCTAssertEqual(C.deepLink(circleId: "dm:a-b", postId: "m1", kind: "story"), "haven://m/dm%3Aa-b/m1",
                       "a DM is always the Messages thread")
    }

    func testDeepLinkMatchesTheAppsInteractionLinkBuilder() {
        // The NSE cannot import the app target, so it carries a copy of the encoder. They must agree.
        let cases: [(String, String?)] = [("default", nil), ("default", "p1"), ("dm:aa-bb", nil), ("dm:aa-bb", "m1"),
                                          ("a.b/c", "x y"), ("circle~1", "post_2")]
        for (cid, pid) in cases {
            XCTAssertEqual(C.deepLink(circleId: cid, postId: pid), DeepLink.interactionLink(circleId: cid, postId: pid),
                           "\(cid) \(pid ?? "nil")")
        }
        XCTAssertEqual(C.deepLink(circleId: "c.1", postId: "p.2", kind: "story"), DeepLink.storyLink(circleId: "c.1", postId: "p.2"))
    }

    func testEveryEmittedLinkRoutesToTheMatchingTarget() {
        XCTAssertEqual(DeepLinkTarget.classify(URL(string: C.deepLink(circleId: "c", postId: "p")!)!), .post(circleId: "c", postId: "p"))
        XCTAssertEqual(DeepLinkTarget.classify(URL(string: C.deepLink(circleId: "c", postId: "p", kind: "story")!)!), .story(circleId: "c", postId: "p"))
        XCTAssertEqual(DeepLinkTarget.classify(URL(string: C.deepLink(circleId: "dm:a-b", postId: "m1")!)!), .dm(circleId: "dm:a-b", messageId: "m1"))
        XCTAssertEqual(DeepLinkTarget.classify(URL(string: C.deepLink(circleId: "c", postId: nil)!)!), .circle(circleId: "c"))
    }

    // MARK: Labels

    func testFallbackBodyTable() {
        XCTAssertEqual(C.fallbackBody(kind: "story", emoji: nil), "Shared a story")
        XCTAssertEqual(C.fallbackBody(kind: "comment", emoji: nil), "Left a comment")
        XCTAssertEqual(C.fallbackBody(kind: "dm", emoji: nil), "Sent you a message")
        XCTAssertEqual(C.fallbackBody(kind: "edit", emoji: nil), "Edited a message")
        XCTAssertEqual(C.fallbackBody(kind: "unsend", emoji: nil), "Unsent a message")
        XCTAssertEqual(C.fallbackBody(kind: "post", emoji: nil), "Shared something")
        XCTAssertEqual(C.fallbackBody(kind: "mystery", emoji: nil), "New activity")
    }

    func testSummaryLabelTable() {
        XCTAssertEqual(["react", "comment", "story", "dm", "post", "call", "other"].map(C.summaryLabel),
                       ["reactions", "comments", "stories", "messages", "posts", "calls", "updates"])
    }

    // MARK: System preview setting

    func testDetailTakesTheStricterOfHavenAndTheSystem() {
        typealias D = SharedNotificationPrivacy.Detail
        XCTAssertEqual(C.detail(haven: .full, systemPreviews: .always), .full)
        XCTAssertEqual(C.detail(haven: .full, systemPreviews: .whenAuthenticated), .privateDetail)
        XCTAssertEqual(C.detail(haven: .full, systemPreviews: .never), .minimal)
        // Haven can only tighten, never loosen.
        XCTAssertEqual(C.detail(haven: .minimal, systemPreviews: .always), .minimal)
        XCTAssertEqual(C.detail(haven: .privateDetail, systemPreviews: .always), .privateDetail)
        XCTAssertEqual(C.detail(haven: .privateDetail, systemPreviews: .never), .minimal)
        XCTAssertEqual(C.detail(haven: .minimal, systemPreviews: .never), .minimal)
    }

    // MARK: Prefetch plan

    private func payload(_ o: [String: Any], locked: Set<String> = []) -> NotificationPayload {
        try! XCTUnwrap(decode(o, locked: locked))
    }

    func testPrefetchEnvelopeAndMedia() {
        let p = payload(["b": "x", "c": "circ", "mk": "haven/mailbox/k", "mr": ["img_1"]])
        XCTAssertEqual(C.prefetchPlan(p, hasInlineEvent: false),
                       .init(circleId: "circ", mailboxKey: "haven/mailbox/k", mediaRefs: ["img_1"], skipEnvelope: false))
    }

    func testPrefetchSkipsTheEnvelopeWhenItRodeInline() {
        let p = payload(["b": "x", "c": "circ", "mk": "k", "mr": ["img_1"]])
        let plan = C.prefetchPlan(p, hasInlineEvent: true)
        XCTAssertEqual(plan?.skipEnvelope, true)
        XCTAssertEqual(plan?.mediaRefs, ["img_1"])
        XCTAssertNil(C.prefetchPlan(payload(["b": "x", "c": "circ", "mk": "k"]), hasInlineEvent: true),
                     "inline envelope and no media: nothing left to fetch")
    }

    func testPrefetchNeedsSomethingToFetchAndACircle() {
        XCTAssertNil(C.prefetchPlan(payload(["b": "x", "c": "circ"]), hasInlineEvent: false), "no mailbox key, no media")
        XCTAssertNil(C.prefetchPlan(payload(["b": "x", "mk": "k"]), hasInlineEvent: false), "no circle id")
        XCTAssertNil(C.prefetchPlan(payload(["b": "x", "c": "", "mk": "k"]), hasInlineEvent: false), "empty circle id")
        XCTAssertNotNil(C.prefetchPlan(payload(["b": "x", "c": "circ", "mr": ["a"]]), hasInlineEvent: false), "media alone is enough")
    }

    func testPrefetchNeverRunsForALockedCircle() {
        let p = payload(["b": "secret", "c": "vault", "mk": "k", "mr": ["img"]], locked: ["vault"])
        XCTAssertNil(C.prefetchPlan(p, hasInlineEvent: false), "a locked circle's content must not be pulled onto the device by a push")
    }

    // MARK: communication notifications (Siri announce / CarPlay reply)

    func testCommunicationPlanOnlyForPlainDMAtFullDetail() throws {
        let dm = try XCTUnwrap(decode(["t": "Maya", "b": "dinner at 6?", "c": "dm:aa-bb", "k": "dm"]))
        XCTAssertEqual(C.communicationPlan(dm, detail: .full),
                       .init(conversationId: "dm:aa-bb", senderName: "Maya", text: "dinner at 6?"))
        XCTAssertNil(C.communicationPlan(dm, detail: .privateDetail), "private detail must not put text in the intent")
        XCTAssertNil(C.communicationPlan(dm, detail: .minimal))
    }

    func testCommunicationPlanNeverForLockedCircleOrNonDM() throws {
        let locked = try XCTUnwrap(decode(["t": "Maya", "b": "secret", "c": "dm:aa-bb", "k": "dm"], locked: ["dm:aa-bb"]))
        XCTAssertNil(C.communicationPlan(locked, detail: .full))
        let react = try XCTUnwrap(decode(["t": "Maya", "b": "Reacted", "c": "dm:aa-bb", "k": "react"]))
        XCTAssertNil(C.communicationPlan(react, detail: .full))
        let circle = try XCTUnwrap(decode(["t": "Maya", "b": "hi", "c": "circle-1", "k": "dm"]))
        XCTAssertNil(C.communicationPlan(circle, detail: .full), "only dm: conversations")
        let anon = try XCTUnwrap(decode(["b": "hi", "c": "dm:aa-bb", "k": "dm"]))
        XCTAssertNil(C.communicationPlan(anon, detail: .full), "no sender name -> nothing to announce")
        let call = try XCTUnwrap(decode(["t": "Maya", "h": "abc"]))
        XCTAssertNil(C.communicationPlan(call, detail: .full))
    }
}
