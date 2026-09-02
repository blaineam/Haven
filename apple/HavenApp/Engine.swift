import Foundation

/// The app's ONE door into the social engine.
///
/// `Engine` owns the `HavenSocial` handle; nothing else in the app holds one. Every engine call is
/// made inside `run`, and `run` is an actor method — so every call executes on this actor's
/// executor, one at a time, and never on the main thread. Two properties fall out of that, and
/// both matter:
///
///   * **The UI never waits on the engine's lock.** Every `HavenSocial` method takes the Rust
///     `Mutex<NetState>` — an unfair std mutex. Background work (the mailbox drain, roster ingest,
///     the media backfill's feed walks, `exportState`) holds it for hundreds of milliseconds to
///     seconds, and 1.8.3 caught the main thread parked behind it one stack at a time: 2.05 s in
///     `dialTargets → myNodeHex`, 4.09 s in `handleRelayNode → contactNodeIds`, 9.5 s of held lock
///     under a roster ingest. Those fixes moved the callers it found; this moves the *door*. A
///     main-actor context cannot call the engine synchronously any more — the compiler refuses —
///     and the SwiftUI layer reads value snapshots that `FeedStore` publishes after each pass.
///   * **One call at a time.** The actor serializes engine work the way `EngineGate` did (field
///     sample of a beachballing Mac host: main + ~14 cooperative threads all in
///     `__psynch_mutexwait` while one holder ran crypto), so concurrent utility Tasks queue here
///     instead of piling onto the mutex.
///
/// The DEBUG tripwire in `run` is the runtime proof of the first property: a QA or development
/// build CRASHES the moment an engine call runs on the main thread, so the e2e fleet (four DEBUG
/// clients, ~190 assertions) doubles as the regression test that no call slipped back onto main.
///
/// Anything the engine hands back is a VALUE (UniFFI structs, `Data`, `String`) — callers copy it
/// out and assign it on the main actor; the `HavenSocial` reference itself must never leave the
/// closure. Two engine instances only ever exist during `reconfigure` / seedless adoption, when a
/// dying engine's in-flight passes are dropped by the `self.engine === engine` guards.
actor Engine {
    private let core: HavenSocial

    init(_ core: HavenSocial) { self.core = core }

    /// Run `body` against the engine, on this actor (never the main thread). `caller` / `line`
    /// default to the CALL SITE, so the DEBUG hold log names the operation that held the engine —
    /// the lock HOLDER behind a stall, not just the waiter. Anything over 300 ms lands in
    /// Caches/HavenStalls.log as `[EngineHold] …` next to the stall it caused.
    func run<T>(caller: String = #function, line: Int = #line, _ body: (HavenSocial) throws -> T) rethrows -> T {
        EngineTripwire.check(caller: caller, line: line)
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let held = CFAbsoluteTimeGetCurrent() - t0
            if held > 0.3 { EngineHoldLog.note("[EngineHold] \(caller) (line \(line)) held \(Int(held * 1000))ms") }
        }
        #endif
        return try body(core)
    }

    /// The one engine-adjacent call that is not a `HavenSocial` method: the transport node's
    /// account→device directory publish takes the engine handle as an argument (it reads our roster
    /// under the engine lock on the Rust side). It runs here so the handle never leaves the actor.
    func publishAccountDevices(via node: HavenNode) async throws -> [String] {
        EngineTripwire.check(caller: #function, line: #line)
        return try await node.publishAccountDevices(social: core)
    }
}

/// DEBUG-only: the assertion that no engine call ever runs on the main thread.
///
/// `Engine.run` is an actor method, so a main-actor caller can only reach it through `await`,
/// and the Swift runtime never runs a default actor's job on the main thread (the main executor
/// cannot give up its thread to another actor). This check turns that runtime contract into a
/// crash with a name on it, so a regression shows up in the first QA launch rather than as a
/// freeze report weeks later. Compiled out of Release entirely.
enum EngineTripwire {
    @inline(__always)
    static func check(caller: String, line: Int) {
        #if DEBUG
        if Thread.isMainThread {
            let msg = "engine call on main: \(caller) (line \(line))"
            HavenLog.sync("[EngineTripwire] " + msg)
            preconditionFailure(msg)
        }
        #endif
    }
}
