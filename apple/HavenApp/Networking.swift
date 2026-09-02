import Foundation

/// Adapts the Rust `InboundListener` callback to a Swift closure. The Rust node calls
/// `onInbound` (off the main thread) for each inbound frame; FeedStore handles it.
/// `fromHex` is the sender's AUTHENTICATED transport node id (the iroh connection's remote
/// endpoint id), or "" when the frame wasn't received over a direct peer connection —
/// FeedStore uses it to learn a dialable device id for a contact from any direct hello.
final class InboundBridge: InboundListener {
    private let onData: @Sendable (String, Data) -> Void
    init(onData: @escaping @Sendable (String, Data) -> Void) { self.onData = onData }
    func onInbound(fromHex: String, payload: Data) { onData(fromHex, payload) }
}

/// Serializes heavy `HavenSocial` FFI so concurrent utility Tasks don't pile onto the engine's
/// single pthread mutex. Field sample of a beachballing Mac host (build 343): main + ~14 cooperative
/// threads all stuck in `__psynch_mutexwait` while one holder ran crypto/`feed`/`exportState`.
/// One-at-a-time cuts the thundering herd; callers still must avoid taking the lock on the main actor
/// for multi-envelope work (see FeedStore messages cache / off-main receive).
actor EngineGate {
    static let shared = EngineGate()
    /// `caller` / `line` default to the CALL SITE, so the DEBUG hold log names the operation that
    /// held the engine — the lock HOLDER behind a main-thread park, not just the waiter. Anything
    /// over 300 ms lands in Caches/HavenStalls.log as `[EngineHold] …` next to the stall it caused.
    func run<T>(caller: String = #function, line: Int = #line, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let held = CFAbsoluteTimeGetCurrent() - t0
            if held > 0.3 { EngineHoldLog.note("[EngineHold] \(caller) (line \(line)) held \(Int(held * 1000))ms") }
        }
        #endif
        return try body()
    }
}

/// Serializes engine-state exports + writes OFF the main actor. The exported state holds DECRYPTED
/// content + contacts + derived key material, so it stays protected at rest (readable only after
/// first unlock — the NSE/background can still reach it), never in a locked-device forensic image
/// or unencrypted backup. Being an actor, a burst of persist() calls runs one export at a time and
/// in order — an older export can never land after (and clobber) a newer one.
actor StatePersister {
    static let shared = StatePersister()
    func persist(social: HavenSocial, to url: URL) async {
        // exportState() holds the engine mutex for 100s of ms on a large account — go through
        // EngineGate so it doesn't race a mailbox receive / feed rebuild storm.
        let data = await EngineGate.shared.run { social.exportState() }
        try? data.write(to: url,
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
