import XCTest
import os

/// The engine's lanes: a user-initiated call must not wait behind QUEUED background work, and
/// neither lane may ever reorder its own calls (mailbox ingest slices depend on that).
final class EngineLanesTests: XCTestCase {
    /// Records the order bodies ran in. Only ever touched inside `LanedExecutor` bodies, which run
    /// one at a time on the executor's actor.
    final class Log: @unchecked Sendable { var order: [String] = [] }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testUserCallJumpsQueuedBackgroundWorkAndBackgroundStaysFIFO() async {
        let log = Log()
        let exec = LanedExecutor(log)
        let gate = DispatchSemaphore(value: 0)
        let started = OSAllocatedUnfairLock(initialState: false)

        // A user call occupies the executor (its body blocks until released).
        let first = Task.detached {
            await exec.run(lane: .userInitiated) { l in started.withLock { $0 = true }; gate.wait(); l.order.append("user1") }
        }
        await waitUntil("user1 running") { started.withLock { $0 } }

        // Background calls queue up behind it, strictly one after another.
        var bg: [Task<Void, Never>] = []
        for i in 1...3 {
            bg.append(Task.detached { await exec.run(lane: .background) { l in l.order.append("bg\(i)") } })
            await waitUntil("bg\(i) submitted") { exec.backgroundSubmitted.withLock { $0 } == i }
            try? await Task.sleep(nanoseconds: 30_000_000)   // let its actor hop enqueue
        }
        // …then a second user call arrives, LAST.
        let second = Task.detached { await exec.run(lane: .userInitiated) { l in l.order.append("user2") } }
        await waitUntil("user2 announced") { exec.userDemand.withLock { $0 } == 2 }

        gate.signal()
        await first.value
        await second.value
        for t in bg { await t.value }

        XCTAssertEqual(log.order, ["user1", "user2", "bg1", "bg2", "bg3"])
        XCTAssertEqual(exec.userDemand.withLock { $0 }, 0)
    }

    func testBackgroundRunsImmediatelyWhenNoUserWorkIsPending() async {
        let log = Log()
        let exec = LanedExecutor(log)
        for i in 1...5 { await exec.run { l in l.order.append("bg\(i)") } }
        XCTAssertEqual(log.order, ["bg1", "bg2", "bg3", "bg4", "bg5"])
    }

    func testRethrowsAndStillReleasesTheLane() async {
        struct Boom: Error {}
        let exec = LanedExecutor(Log())
        do {
            try await exec.run(lane: .userInitiated) { _ in throw Boom() }
            XCTFail("expected a throw")
        } catch {}
        XCTAssertEqual(exec.userDemand.withLock { $0 }, 0, "a throwing user call must still release its demand")
        // Background work is not left parked behind it.
        let ran = await exec.run { _ in true }
        XCTAssertTrue(ran)
    }

    func testPersistSkipsWhenNothingChanged() async {
        let exec = LanedExecutor(Log())
        // Starts dirty: the first persist always exports.
        guard let first = await exec.runIfDirty({ _ in "export" }) else { return XCTFail("first persist must export") }
        await exec.markPersisted(first.generation)
        // Reads do not dirty it.
        await exec.run(readOnly: true) { _ in }
        let skipped = await exec.runIfDirty { _ in "export" }
        XCTAssertNil(skipped, "no mutation since the last persist — nothing to export")
        // A mutation does.
        await exec.run { _ in }
        let again = await exec.runIfDirty { _ in "export" }
        XCTAssertNotNil(again)
        // An older export finishing late never marks newer changes as saved.
        await exec.run { _ in }
        await exec.markPersisted(first.generation)
        let stillDirty = await exec.runIfDirty { _ in "export" }
        XCTAssertNotNil(stillDirty)
    }
}
