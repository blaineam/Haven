import XCTest

/// `CPInterfaceController` raises an uncaught NSException when an operation fails with no completion
/// handler (the limited-UI crash). These pin the rules that prevent it, against a fake controller.
@MainActor
final class CarPlayNavigatorTests: XCTestCase {
    private final class Tpl {}

    private final class FakeController: CarPlayNavigating {
        var stack: [AnyObject] = []
        var ops: [String] = []
        /// When set, completions are held until `release()` - a transition "in flight".
        var hold = false
        private var pending: [() -> Void] = []
        var failNext = false

        func setRoot(_ template: AnyObject, animated: Bool, completion: @escaping (Bool, Error?) -> Void) {
            ops.append("root"); stack = [template]; finish(completion)
        }
        func push(_ template: AnyObject, animated: Bool, completion: @escaping (Bool, Error?) -> Void) {
            ops.append("push"); stack.append(template); finish(completion)
        }
        func popToRoot(animated: Bool, completion: @escaping (Bool, Error?) -> Void) {
            ops.append("pop"); stack = Array(stack.prefix(1)); finish(completion)
        }
        private func finish(_ completion: @escaping (Bool, Error?) -> Void) {
            let fail = failNext; failNext = false
            let run = { completion(!fail, fail ? NSError(domain: "t", code: 1) : nil) }
            if hold { pending.append(run) } else { run() }
        }
        func release() { let p = pending; pending = []; hold = false; p.forEach { $0() } }
    }

    func testPopToRootAtTheRootIsSkippedNotAttempted() {
        let c = FakeController(); let nav = CarPlayNavigator(controller: c)
        nav.setRoot(Tpl())
        nav.popToRoot()
        XCTAssertEqual(c.ops, ["root"], "nothing to pop - the failing call is never made")
    }

    func testPopToRootWithAScreenOpenPops() {
        let c = FakeController(); let nav = CarPlayNavigator(controller: c)
        nav.setRoot(Tpl()); nav.push(Tpl()); nav.popToRoot()
        XCTAssertEqual(c.ops, ["root", "push", "pop"])
        XCTAssertEqual(c.stack.count, 1)
    }

    func testPushOfATemplateAlreadyOnTheStackIsSkipped() {
        let c = FakeController(); let nav = CarPlayNavigator(controller: c)
        let screen = Tpl()
        nav.setRoot(Tpl()); nav.push(screen); nav.push(screen)
        XCTAssertEqual(c.ops, ["root", "push"])
    }

    func testOperationsRunOneAtATimeAndInOrder() {
        let c = FakeController(); c.hold = true
        let nav = CarPlayNavigator(controller: c)
        nav.setRoot(Tpl())
        nav.push(Tpl())          // queued behind the root transition
        nav.popToRoot()          // queued behind the push
        XCTAssertEqual(c.ops, ["root"], "a transition is in flight - nothing else starts")
        c.release()              // root done -> push starts (held again? release cleared hold)
        XCTAssertEqual(c.ops, ["root", "push", "pop"])
        XCTAssertEqual(c.stack.count, 1)
    }

    func testAFailedOperationIsSwallowedAndTheQueueKeepsGoing() {
        let c = FakeController(); var logs: [String] = []
        let nav = CarPlayNavigator(controller: c, log: { logs.append($0) })
        nav.setRoot(Tpl())
        c.failNext = true
        nav.push(Tpl())
        nav.push(Tpl())
        XCTAssertEqual(c.ops, ["root", "push", "push"], "the op after a failure still runs")
        XCTAssertTrue(logs.contains { $0.contains("push failed") })
    }

    func testEveryCallCarriesACompletion() {
        // The protocol takes a non-optional completion, so a call without one cannot be written; assert the
        // navigator fires them all by observing the queue drain to idle.
        let c = FakeController(); let nav = CarPlayNavigator(controller: c)
        for _ in 0..<5 { nav.push(Tpl()); nav.popToRoot() }
        XCTAssertEqual(c.stack.count, 1)
        nav.push(Tpl())
        XCTAssertEqual(c.stack.count, 2, "the queue is idle and accepts new work")
    }
}
