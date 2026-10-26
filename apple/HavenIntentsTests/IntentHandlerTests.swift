import Intents
import XCTest

/// The Siri side of CarPlay messaging: the real `IntentHandler` driven through its SiriKit entry points
/// against a temp-directory App Group, with this test standing in for the app (it rings the ack
/// doorbell exactly as `CarPlayBridge.drain` does). Event-driven - no sleeps.
final class IntentHandlerTests: XCTestCase {
    private var root: URL!
    private let handler = IntentHandler()

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("intents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MessagingSnapshotStore.containerOverride = root
        SiriRequestQueue.containerOverride = root
        IntentMessaging.ackTimeout = 0.3
    }

    override func tearDown() {
        MessagingSnapshotStore.containerOverride = nil
        SiriRequestQueue.containerOverride = nil
        IntentMessaging.ackTimeout = 4
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: fixtures

    private func msg(_ id: String, _ mins: Double, mine: Bool = false, body: String, unsent: Bool = false) -> MessagingMessage {
        MessagingMessage(id: id, isMe: mine, unsent: unsent, createdAt: UInt64(1_800_000_000_000 - mins * 60_000),
                         body: body, hasAttachment: false, author: "Maya")
    }

    private func install(detail: SharedNotificationPrivacy.Detail = .full, lockMaya: Bool = false) {
        let maya = MessagingThread(id: "dm:maya", title: "Maya", memberHandles: ["aa11"],
                                   messages: [msg("m1", 10, body: "dinner at 7?"), msg("m2", 5, body: "bring wine")],
                                   watermark: 1_800_000_000_000 - 8 * 60_000, locked: lockMaya)
        let theo = MessagingThread(id: "dm:theo", title: "Theo Park", memberHandles: ["bb22"],
                                   messages: [msg("t1", 3, body: "gpx file?")], watermark: 0, locked: false)
        let mayaB = MessagingThread(id: "dm:maya2", title: "Maya Chen", memberHandles: ["cc33"], messages: [], watermark: 0, locked: false)
        MessagingSnapshotStore.write(MessagingSnapshot.build(threads: [maya, theo, mayaB], detail: detail, now: 1))
    }

    private func person(_ name: String) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: name, type: .unknown), nameComponents: nil,
                 displayName: name, image: nil, contactIdentifier: nil, customIdentifier: nil)
    }

    /// Stand-in for the running app: when the doorbell rings, drain and ack.
    private func actAsApp(drainTo drained: XCTestExpectation? = nil,
                          seen: @escaping ([SiriRequest]) -> Void = { _ in }) -> SiriRequestSignal.Token {
        SiriRequestSignal.observe(SiriRequestSignal.request) {
            let pending = SiriRequestQueue.pending()
            seen(pending.map(\.request))
            for (file, _) in pending { SiriRequestQueue.complete(file) }
            drained?.fulfill()
            SiriRequestSignal.post(SiriRequestSignal.ack)
        }
    }

    /// `INIntentResolutionResult` has no public code accessor; its (stable, KVC-visible) result code is
    /// compared against reference results built with the public factories.
    private func code(_ r: INIntentResolutionResult) -> Int {
        (r.value(forKey: "resolutionResultCode") as? Int) ?? -1
    }
    private func kind(_ r: INIntentResolutionResult) -> String {
        let p = person("x")
        let refs: [(String, INIntentResolutionResult)] = [
            ("success", INPersonResolutionResult.success(with: p)),
            ("needsValue", INPersonResolutionResult.needsValue()),
            ("unsupported", INPersonResolutionResult.unsupported()),
            ("disambiguation", INPersonResolutionResult.disambiguation(with: [p, p])),
        ]
        return refs.first { code($0.1) == code(r) }?.0 ?? "unknown(\(code(r)))"
    }

    // MARK: send

    func testSendIsAcknowledgedByTheApp() {
        install()
        let done = expectation(description: "handled")
        let drained = expectation(description: "app drained")
        var seenRequests: [SiriRequest] = []
        let app = actAsApp(drainTo: drained) { seenRequests = $0 }
        let intent = INSendMessageIntent(recipients: [person("theo park")], outgoingMessageType: .outgoingMessageText,
                                         content: "  on my way ", speakableGroupName: nil,
                                         conversationIdentifier: nil, serviceName: "Haven", sender: nil, attachments: nil)
        var code: INSendMessageIntentResponseCode?
        handler.handle(intent: intent) { code = $0.code; done.fulfill() }
        wait(for: [drained, done], timeout: 5)
        app.cancel()
        XCTAssertEqual(seenRequests.map(\.text), ["on my way"])
        XCTAssertEqual(seenRequests.map(\.conversationId), ["dm:theo"])
        XCTAssertEqual(code, .success)
    }

    func testSendWithoutAnAppAckAsksToLaunchAndKeepsTheRequestQueued() {
        install()
        let done = expectation(description: "handled")
        var code: INSendMessageIntentResponseCode?
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "hi",
                                         speakableGroupName: nil, conversationIdentifier: "dm:maya", serviceName: "Haven",
                                         sender: nil, attachments: nil)
        handler.handle(intent: intent) { code = $0.code; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(code, .failureRequiringAppLaunch, "never claim a send the app hasn't taken")
        XCTAssertEqual(SiriRequestQueue.pending().map(\.request.conversationId), ["dm:maya"], "stays queued for launch")
    }

    func testSendToALockedConversationIsRefused() {
        install(lockMaya: true)
        let done = expectation(description: "handled")
        var code: INSendMessageIntentResponseCode?
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "hi",
                                         speakableGroupName: nil, conversationIdentifier: "dm:maya", serviceName: "Haven",
                                         sender: nil, attachments: nil)
        handler.handle(intent: intent) { code = $0.code; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(code, .failure)
        XCTAssertTrue(SiriRequestQueue.pending().isEmpty)
    }

    func testResolveRecipients() {
        install()
        func resolve(_ intent: INSendMessageIntent) -> [INSendMessageRecipientResolutionResult] {
            var out: [INSendMessageRecipientResolutionResult] = []
            let e = expectation(description: "resolve"); handler.resolveRecipients(for: intent) { out = $0; e.fulfill() }
            wait(for: [e], timeout: 5); return out
        }
        func send(_ people: [INPerson]?, conv: String? = nil) -> INSendMessageIntent {
            INSendMessageIntent(recipients: people, outgoingMessageType: .outgoingMessageText, content: "x", speakableGroupName: nil,
                                conversationIdentifier: conv, serviceName: nil, sender: nil, attachments: nil)
        }
        XCTAssertEqual(resolve(send([person("Theo")])).first.map(kind), "success")
        XCTAssertEqual(resolve(send([person("Maya Chen")])).first.map(kind), "success", "exact title beats partial")
        XCTAssertEqual(resolve(send([person("Maya")])).first.map(kind), "success", "exact 'Maya' beats 'Maya Chen'")
        XCTAssertEqual(resolve(send([person("Nobody")])).first.map(kind), "unsupported")
        XCTAssertEqual(resolve(send(nil)).first.map(kind), "needsValue")
        XCTAssertEqual(resolve(send(nil, conv: "dm:theo")).first.map(kind), "success", "CarPlay conversation identifier")
    }

    func testEmptyContentNeedsAValue() {
        var r: INStringResolutionResult?
        let e = expectation(description: "content")
        handler.resolveContent(for: INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "  ",
                                                         speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil,
                                                         sender: nil, attachments: nil)) { r = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(r.map(kind), "needsValue")
    }

    // MARK: read

    private func search(conversation: String? = nil, attributes: INMessageAttributeOptions = []) -> INSearchForMessagesIntentResponse {
        let intent = INSearchForMessagesIntent(recipients: nil, senders: nil, searchTerms: nil, attributes: attributes,
                                               dateTime: nil, identifiers: nil, notificationIdentifiers: nil,
                                               speakableGroupNames: nil, conversationIdentifiers: conversation.map { [$0] })
        var out: INSearchForMessagesIntentResponse!
        let e = expectation(description: "search")
        handler.handle(intent: intent) { out = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        return out
    }

    func testReadReturnsUnreadInboundTextForAConversation() {
        install()
        let r = search(conversation: "dm:maya", attributes: .unread)
        XCTAssertEqual(r.code, .success)
        XCTAssertEqual(r.messages?.map(\.content), ["bring wine"], "only the message newer than the watermark")
        XCTAssertEqual(r.messages?.first?.conversationIdentifier, "dm:maya")
        XCTAssertEqual(search(conversation: "dm:maya").messages?.map(\.content), ["dinner at 7?", "bring wine"])
    }

    func testReadNeverRevealsLockedOrPrivacyHiddenContent() {
        install(lockMaya: true)
        XCTAssertEqual(search(conversation: "dm:maya").code, .failure, "locked")
        install(detail: .privateDetail)
        XCTAssertEqual(search(conversation: "dm:maya").code, .failure, "text hidden by notification privacy")
    }

    // MARK: mark read

    func testMarkReadQueuesPerConversationAndIgnoresLockedOrUnknown() {
        install()
        func mark(_ ids: [String]) -> INSetMessageAttributeIntentResponseCode {
            var c: INSetMessageAttributeIntentResponseCode!
            let e = expectation(description: "mark")
            handler.handle(intent: INSetMessageAttributeIntent(identifiers: ids, attribute: .read)) { c = $0.code; e.fulfill() }
            wait(for: [e], timeout: 5); return c
        }
        XCTAssertEqual(mark(["m1", "m2", "t1"]), .success)
        XCTAssertEqual(Set(SiriRequestQueue.pending().map(\.request.conversationId)), ["dm:maya", "dm:theo"])
        XCTAssertTrue(SiriRequestQueue.pending().allSatisfy { $0.request.kind == .markRead })
        SiriRequestQueue.clear()
        XCTAssertEqual(mark(["nope"]), .failure)
        install(lockMaya: true)
        XCTAssertEqual(mark(["m1"]), .failure, "locked conversation")
        var c: INSetMessageAttributeIntentResponseCode!
        let e = expectation(description: "unread"); handler.handle(intent: INSetMessageAttributeIntent(identifiers: ["t1"], attribute: .unread)) { c = $0.code; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(c, .failure, "only 'read' is supported")
    }

    // MARK: calls

    func testStartCallContinuesInAppWithTheConversation() {
        install()
        var response: INStartCallIntentResponse!
        let e = expectation(description: "call")
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                       destinationType: .normal, contacts: [person("Theo")], callCapability: .audioCall)
        handler.handle(intent: intent) { response = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(response.code, .continueInApp)
        XCTAssertEqual(response.userActivity?.userInfo?[SiriCallTarget.conversationKey] as? String, "dm:theo")
    }

    func testStartCallRefusesLockedAndUnknown() {
        install(lockMaya: true)
        for name in ["Maya", "Nobody"] {
            var response: INStartCallIntentResponse!
            let e = expectation(description: name)
            let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                           destinationType: .normal, contacts: [person(name)], callCapability: .audioCall)
            handler.handle(intent: intent) { response = $0; e.fulfill() }
            wait(for: [e], timeout: 5)
            XCTAssertEqual(response.code, .failure, name)
        }
    }
}
