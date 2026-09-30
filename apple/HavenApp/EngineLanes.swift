import Foundation
import os

/// Which lane an engine call waits in. See `LanedExecutor`.
enum EngineLane: Sendable {
    /// Something the user just did and is waiting to see: post, react, comment, the visible feed.
    case userInitiated
    /// Everything else — mailbox drain slices, exports, verify walks, backfills. The default, so an
    /// unannotated call keeps the exact FIFO it always had relative to every other background call.
    case background
}

/// A serial executor with two lanes, over one resource that must only ever be touched by one caller
/// at a time (the engine handle — its every method takes one unfair Rust mutex).
///
/// The engine used to be one plain actor lane: a tap on "react" queued behind whatever background
/// work happened to be ahead of it — a mailbox drain slice, an `exportState`, a verify walk — each
/// holding the engine for hundreds of milliseconds. The user waited on work they never asked for.
///
/// Rules, and why they are safe:
///   * **FIFO within a lane.** Background calls never reorder among themselves (mailbox ingest
///     slices depend on that), and user calls never reorder among themselves.
///   * **User calls jump queued background calls.** A user call announces itself (`userDemand`)
///     BEFORE it hops onto the actor, so a background call that reaches the front of the actor
///     while user work is pending parks itself instead of running. Nothing preempts a call that is
///     already running — every body is synchronous, so it runs to completion.
///   * **Background resumes strictly in order**, one at a time, once no user work is pending.
///     A newly arriving background call queues behind parked ones rather than slipping ahead.
///
/// A user call that depends on an EARLIER background write can therefore run before it; callers
/// only mark a call `.userInitiated` when it acts on state the user can already see (a post on
/// screen, a circle they are in), which by construction has already been ingested.
///
/// It also counts mutations: any call not marked `readOnly` bumps `generation`, so a persist that
/// finds nothing changed since the last export can skip the whole-state serialization.
actor LanedExecutor<Core> {
    private let core: Core
    /// Told how long each user-initiated call waited (announce → body start), in ms.
    private let onUserWait: (@Sendable (Double) -> Void)?

    init(_ core: Core, onUserWait: (@Sendable (Double) -> Void)? = nil) {
        self.core = core
        self.onUserWait = onUserWait
    }

    // MARK: Lanes

    /// User-initiated calls announced but not yet finished. Read and written from any thread (the
    /// announce happens before the actor hop), hence the lock rather than actor state.
    nonisolated let userDemand = OSAllocatedUnfairLock(initialState: 0)
    /// Background calls parked while user work runs, in arrival order.
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    /// A parked background call has been woken but has not started yet. Arrivals must queue behind
    /// it, or a newcomer could overtake the one just woken.
    private var backgroundHandoff = false

    /// Test/diagnostic probe: background calls that have entered `run` (announced, not necessarily
    /// admitted).
    nonisolated let backgroundSubmitted = OSAllocatedUnfairLock(initialState: 0)

    nonisolated func run<T>(lane: EngineLane = .background, readOnly: Bool = false,
                            _ body: (Core) throws -> T) async rethrows -> T {
        switch lane {
        case .userInitiated: userDemand.withLock { $0 += 1 }
        case .background: backgroundSubmitted.withLock { $0 += 1 }
        }
        return try await runIsolated(lane, readOnly: readOnly, announcedAt: DispatchTime.now().uptimeNanoseconds, body)
    }

    private func runIsolated<T>(_ lane: EngineLane, readOnly: Bool, announcedAt: UInt64,
                                _ body: (Core) throws -> T) async rethrows -> T {
        if lane == .background { await admitBackground() }
        if lane == .userInitiated, let onUserWait {
            onUserWait(Double(DispatchTime.now().uptimeNanoseconds &- announcedAt) / 1_000_000)
        }
        defer {
            if lane == .userInitiated { userDemand.withLock { $0 -= 1 } }
            wakeNextBackground()
        }
        if !readOnly { generation &+= 1 }
        return try body(core)
    }

    /// An async body on the actor (reentrant across its suspensions, like any actor method). Kept
    /// outside the lanes: it is the transport's own call and awaits the network, not the mutex.
    func withCore<T>(_ body: (Core) async throws -> T) async rethrows -> T {
        try await body(core)
    }

    private func admitBackground() async {
        let demand = userDemand.withLock { $0 }
        guard demand > 0 || !backgroundWaiters.isEmpty || backgroundHandoff else { return }
        await withCheckedContinuation { backgroundWaiters.append($0) }
        backgroundHandoff = false
    }

    private func wakeNextBackground() {
        guard !backgroundHandoff, !backgroundWaiters.isEmpty, userDemand.withLock({ $0 }) == 0 else { return }
        backgroundHandoff = true
        backgroundWaiters.removeFirst().resume()
    }

    // MARK: Mutation generation

    /// Bumped by every call not marked `readOnly`. Starts dirty so the first persist always runs.
    private var generation: UInt64 = 1
    /// The generation the last completed persist captured.
    private var persistedGeneration: UInt64 = 0

    /// Run a read-only background `body` — but only if something changed since the last
    /// `markPersisted` — and return its result with the generation it observed. The check and the
    /// body share one actor turn, so no mutation can land between them.
    nonisolated func runIfDirty<T>(_ body: (Core) throws -> T) async rethrows -> (value: T, generation: UInt64)? {
        backgroundSubmitted.withLock { $0 += 1 }
        return try await runIfDirtyIsolated(body)
    }
    private func runIfDirtyIsolated<T>(_ body: (Core) throws -> T) async rethrows -> (value: T, generation: UInt64)? {
        await admitBackground()
        defer { wakeNextBackground() }
        guard generation != persistedGeneration else { return nil }
        let g = generation
        return (try body(core), g)
    }
    /// The current mutation generation — equal across two reads only if no state-changing call ran
    /// in between. Lets a periodic walk skip recomputing what cannot have changed.
    func currentGeneration() -> UInt64 { generation }
    /// A persist that captured `g` reached disk. Never moves backwards (an older export finishing
    /// late must not mark newer changes as saved).
    func markPersisted(_ g: UInt64) {
        if g > persistedGeneration { persistedGeneration = g }
    }
}

/// "Save, THEN send" for authored events, in authoring order.
///
/// Authoring advances the sender's ratchet / epoch state. If an event leaves the device before that
/// state is on disk, a kill in between relaunches on OLDER state and the next events re-use key
/// material the recipients already consumed — they silently drop them (gate `multirelay: A's shared
/// photo readable by B`, after the `launch` step killed iOS ~3 s into the 2.5 s persist debounce).
/// Each link awaits the previous one, then `save` (an export — a no-op when an earlier link already
/// captured this state), then `send`. So nothing goes out before its state is durable, and events go
/// out in the order they were authored.
@MainActor
final class SaveThenSendChain {
    private var tail: Task<Void, Never>?

    func enqueue(save: @escaping @Sendable () async -> Void, send: @escaping @MainActor () -> Void) {
        let prev = tail
        tail = Task { @MainActor in
            await prev?.value
            await save()
            send()
        }
    }

    /// Resolves once everything enqueued so far has been saved and sent.
    func drained() async { await tail?.value }
}
