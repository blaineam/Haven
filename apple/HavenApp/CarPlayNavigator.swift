import Foundation

/// The slice of `CPInterfaceController` the navigator drives, so the rules below are testable without
/// CarPlay. `stack` is the template stack, root first.
protocol CarPlayNavigating: AnyObject {
    var stack: [AnyObject] { get }
    func setRoot(_ template: AnyObject, animated: Bool, completion: @escaping (Bool, Error?) -> Void)
    func push(_ template: AnyObject, animated: Bool, completion: @escaping (Bool, Error?) -> Void)
    func popToRoot(animated: Bool, completion: @escaping (Bool, Error?) -> Void)
}

/// Every CarPlay navigation goes through here. `CPInterfaceController` raises an uncaught NSException from
/// `_handleCompletion:withSuccess:error:` when an operation fails and the caller gave no completion handler
/// (seen when the car flipped to limited UI while a conversation was open: a pop/push raced a transition
/// already in flight). So: one operation at a time (a queue), a completion handler on EVERY call that logs
/// and swallows the error, and each operation re-checks the stack when it actually runs - a pop with
/// nothing to pop and a push of a template that is already on the stack are skipped, never attempted.
@MainActor
final class CarPlayNavigator {
    private let controller: CarPlayNavigating
    private let log: (String) -> Void
    /// Each step runs against the live controller and calls `finish` exactly once.
    private var queue: [(CarPlayNavigating, @escaping (Bool, Error?) -> Void) -> Void] = []
    private var busy = false

    init(controller: CarPlayNavigating, log: @escaping (String) -> Void = { _ in }) {
        self.controller = controller
        self.log = log
    }

    /// The template stack, root first.
    var stack: [AnyObject] { controller.stack }

    func contains(_ template: AnyObject) -> Bool { controller.stack.contains { $0 === template } }

    func setRoot(_ template: AnyObject, animated: Bool = false) {
        enqueue("setRoot") { controller, finish in
            controller.setRoot(template, animated: animated, completion: finish)
        }
    }

    /// Skipped when the template is already on the stack.
    func push(_ template: AnyObject, animated: Bool = true) {
        enqueue("push") { [log] controller, finish in
            guard controller.stack.contains(where: { $0 === template }) == false else {
                log("carplay: push skipped (already on the stack)"); return finish(true, nil)
            }
            controller.push(template, animated: animated, completion: finish)
        }
    }

    /// Skipped when only the root is on the stack.
    func popToRoot(animated: Bool = false) {
        enqueue("popToRoot") { [log] controller, finish in
            guard controller.stack.count > 1 else { log("carplay: popToRoot skipped (at root)"); return finish(true, nil) }
            controller.popToRoot(animated: animated, completion: finish)
        }
    }

    private func enqueue(_ name: String, _ step: @escaping (CarPlayNavigating, @escaping (Bool, Error?) -> Void) -> Void) {
        queue.append { [weak self] controller, finish in
            step(controller) { success, error in
                if !success || error != nil { self?.log("carplay: \(name) failed - \(error.map { "\($0)" } ?? "no error")") }
                finish(success, error)
            }
        }
        drain()
    }

    private func drain() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let next = queue.removeFirst()
        next(controller) { [weak self] _, _ in
            self?.busy = false
            self?.drain()
        }
    }
}
