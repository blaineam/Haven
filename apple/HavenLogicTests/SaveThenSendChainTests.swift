import XCTest

/// Authored events leave the device only after the state that sealed them is saved, and in order.
@MainActor
final class SaveThenSendChainTests: XCTestCase {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testEachSendWaitsForItsSaveAndSendsKeepAuthoringOrder() async {
        let chain = SaveThenSendChain()
        let log = Log()
        // The first save is SLOW: without the chain, event 2's send would overtake event 1's.
        chain.enqueue(save: { try? await Task.sleep(nanoseconds: 50_000_000); log.add("save1") },
                      send: { log.add("send1") })
        chain.enqueue(save: { log.add("save2") }, send: { log.add("send2") })
        chain.enqueue(save: { log.add("save3") }, send: { log.add("send3") })
        await chain.drained()
        XCTAssertEqual(log.all, ["save1", "send1", "save2", "send2", "save3", "send3"])
    }

    func testNothingIsSentBeforeItsSaveCompletes() async {
        let chain = SaveThenSendChain()
        let log = Log()
        let saved = expectation(description: "save started")
        chain.enqueue(save: {
            saved.fulfill()
            try? await Task.sleep(nanoseconds: 30_000_000)
            log.add("saved")
        }, send: { log.add("sent") })
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertFalse(log.all.contains("sent"), "a send may never run while its save is in flight")
        await chain.drained()
        XCTAssertEqual(log.all, ["saved", "sent"])
    }
}
