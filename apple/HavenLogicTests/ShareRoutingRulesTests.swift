import XCTest

/// The share-routing table: where each Share Extension decision goes and what is delivered. These are
/// the rules whose failure mode is a shared message that is lost, sent to the wrong thread, or sent
/// into a biometric-locked circle.
final class ShareRoutingRulesTests: XCTestCase {
    private typealias R = ShareRoutingRules

    func testDeliveryTable() {
        XCTAssertEqual(R.delivery(for: .undecided), .askUser)
        XCTAssertEqual(R.delivery(for: .story), .storyEditor)
        XCTAssertEqual(R.delivery(for: .post), .feedComposer)
        XCTAssertEqual(R.delivery(for: .dm), .directMessage)
    }

    func testOnlyDMCanBeFinishedWithoutTheUser() {
        let all: [ShareInbox.Route] = [.undecided, .post, .dm, .story]
        XCTAssertEqual(all.filter { R.delivery(for: $0) == .directMessage }, [.dm])
    }

    func testAppendTextJoinsWithNewline() {
        XCTAssertEqual(R.appendText("", "first"), "first")
        XCTAssertEqual(R.appendText("first", "second"), "first\nsecond")
        XCTAssertEqual(R.appendText(R.appendText("a", "b"), "c"), "a\nb\nc")
        XCTAssertEqual(R.appendText("a", ""), "a\n", "an empty item still separates; the body trim removes it later")
    }

    func testBodyCombinesCaptionThenTextAndDropsBlanks() {
        XCTAssertEqual(R.body(caption: "cap", text: "shared"), "cap\nshared")
        XCTAssertEqual(R.body(caption: "  cap \n", text: "\n shared  "), "cap\nshared")
        XCTAssertEqual(R.body(caption: "", text: "only text"), "only text")
        XCTAssertEqual(R.body(caption: "only caption", text: "   "), "only caption")
        XCTAssertEqual(R.body(caption: " ", text: "\n"), "")
    }

    func testHasContent() {
        XCTAssertFalse(R.hasContent(text: "", importedCount: 0), "nothing usable is dropped, not retried forever")
        XCTAssertTrue(R.hasContent(text: "x", importedCount: 0))
        XCTAssertTrue(R.hasContent(text: "", importedCount: 2))
    }

    func testDeliverableDM() {
        let ids = ["default", "dm:aa-bb"]
        XCTAssertTrue(R.isDeliverableDM("dm:aa-bb", existingCircleIds: ids, locked: false))
        XCTAssertFalse(R.isDeliverableDM("dm:aa-bb", existingCircleIds: ids, locked: true), "never send into a locked thread")
        XCTAssertFalse(R.isDeliverableDM("dm:gone", existingCircleIds: ids, locked: false), "thread deleted since the extension ran")
        XCTAssertFalse(R.isDeliverableDM("dm:aa-bb", existingCircleIds: [], locked: false))
    }

    func testValidThread() {
        let dms = ["dm:aa-bb", "dm:cc-dd"]
        XCTAssertEqual(R.validThread("dm:aa-bb", dmCircleIds: dms, locked: false), "dm:aa-bb")
        XCTAssertNil(R.validThread("dm:aa-bb", dmCircleIds: dms, locked: true))
        XCTAssertNil(R.validThread("dm:zz-yy", dmCircleIds: dms, locked: false))
        XCTAssertNil(R.validThread("default", dmCircleIds: ["default"], locked: false), "a feed circle is not a thread suggestion")
        XCTAssertNil(R.validThread("", dmCircleIds: dms, locked: false))
    }

    func testAttachmentName() {
        XCTAssertEqual(R.attachmentName(original: "Report.pdf", storedName: "doc-0.pdf"), "Report.pdf")
        XCTAssertEqual(R.attachmentName(original: "a/b.pdf", storedName: "doc-0.pdf"), "a-b.pdf", "a slash must not escape the temp dir")
        XCTAssertEqual(R.attachmentName(original: "  spaced.txt \n", storedName: "doc-1.txt"), "spaced.txt")
        XCTAssertNil(R.attachmentName(original: "", storedName: "doc-0.pdf"))
        XCTAssertNil(R.attachmentName(original: "   ", storedName: "doc-0.pdf"))
        XCTAssertNil(R.attachmentName(original: "doc-0.pdf", storedName: "doc-0.pdf"), "already the right name")
    }

    func testStagedAttachmentNameKeepsSameNameSharesApart() {
        let a = R.stagedAttachmentName(original: "report.pdf", uniquifier: "11111111-aaaa")
        let b = R.stagedAttachmentName(original: "report.pdf", uniquifier: "22222222-bbbb")
        XCTAssertEqual(a, "11111111-report.pdf")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix("-report.pdf"))
    }

    // MARK: Readiness

    func testRetryLaterOnlyWhenSomethingIsQueuedAndRetriesRemain() {
        XCTAssertTrue(R.shouldRetryLater(queued: 1, retriesLeft: 10))
        XCTAssertFalse(R.shouldRetryLater(queued: 0, retriesLeft: 10), "nothing waiting: no reason to come back")
        XCTAssertFalse(R.shouldRetryLater(queued: 3, retriesLeft: 0), "a device that never configures must not spin")
        XCTAssertEqual(R.maxReadinessRetries, 10)
        XCTAssertEqual(R.readinessRetryDelayNs, 1_500_000_000)
    }
}

/// The drain loop's contract, driven with plain integers standing in for queued shares.
@MainActor
final class ShareDrainTests: XCTestCase {
    private final class Log { var consumed: [Int] = []; var cleared: [Int] = [] }

    private func run(_ queue: [Int], blocked: @escaping (Log) -> Bool = { _ in false },
                     outcome: @escaping (Int, Log) -> ShareConsumeOutcome) async -> Log {
        let log = Log()
        await ShareDrain.run(queue,
                             isBlocked: { blocked(log) },
                             consume: { n in log.consumed.append(n); return outcome(n, log) },
                             clear: { log.cleared.append($0) })
        return log
    }

    func testEveryDeliverableShareIsProcessedOldestFirst() async {
        let log = await run([1, 2, 3]) { _, _ in .done }
        XCTAssertEqual(log.consumed, [1, 2, 3], "not just the newest")
        XCTAssertEqual(log.cleared, [1, 2, 3])
    }

    func testTheFirstShareThatNeedsTheUserStopsTheDrainButIsCleared() async {
        let log = await run([1, 2, 3]) { n, _ in n == 2 ? .needsUser : .done }
        XCTAssertEqual(log.consumed, [1, 2])
        XCTAssertEqual(log.cleared, [1, 2], "the router holds its content now; the entry has done its job")
    }

    func testARetryKeepsTheShareAndEverythingAfterIt() async {
        let log = await run([1, 2, 3]) { n, _ in n == 2 ? .retry : .done }
        XCTAssertEqual(log.consumed, [1, 2])
        XCTAssertEqual(log.cleared, [1], "a share that was not delivered must stay queued")
    }

    func testABlockedDrainTouchesNothing() async {
        let log = await run([1, 2], blocked: { _ in true }) { _, _ in .done }
        XCTAssertEqual(log.consumed, [])
        XCTAssertEqual(log.cleared, [])
    }

    func testAComposerOpenedMidDrainStopsTheRest() async {
        // After the first share is consumed a composer is on screen: the rest must wait, not clobber it.
        let log = await run([1, 2, 3], blocked: { !$0.consumed.isEmpty }) { _, _ in .done }
        XCTAssertEqual(log.consumed, [1])
        XCTAssertEqual(log.cleared, [1])
    }

    func testEmptyQueueIsANoOp() async {
        let log = await run([]) { _, _ in .done }
        XCTAssertEqual(log.consumed, [])
    }
}
