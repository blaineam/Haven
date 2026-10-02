import Foundation
import AVFoundation

// MARK: - Why this exists
//
// A call must never be able to take the app down because the AUDIO SYSTEM is sick.
//
// When the audio server is wedged — coreaudiod/mediaserverd stuck, a Bluetooth route mid-handoff,
// or (how it was found) a Mac whose default output is a hung virtual device under the iOS
// simulator — the first `AudioUnitInitialize`/`AudioOutputUnitStart` on Apple's RemoteIO unit
// sends an RPC to the audio server that never answers, and AudioToolbox handles that with
// `_ReportRPCTimeout` → `abort()`. Not an error, not an exception: the process dies, and nothing
// in Swift can catch it. The crash reports show three ways in, all the same shape:
//
//   • WebRTC's audio device module: `AURemoteIO::Initialize` on a WebRTC worker thread, the moment
//     `RTCAudioSession.isAudioEnabled` flips on.
//   • The hairpin bridge: `AVAudioEngine.start()` → `AURemoteIO::Start`.
//   • Both of the above while a ringback `AVAudioPlayer.play()` sat inside `AudioQueueStart`
//     waiting for an IO cycle that never came — holding the lock RemoteIO's server needs, so the
//     NEXT RemoteIO call times out and aborts even if it would otherwise have been fine.
//
// The AudioQueue path (AVAudioPlayer) is different: on a stuck device it BLOCKS — ~15 s, then
// returns — it does not abort. So it is a safe thing to probe with, provided the probe runs off the
// main thread, is bounded by a deadline, and — the subtle part — nothing touches RemoteIO while any
// such start is still blocked, because that blocked start is exactly what makes RemoteIO abort.
//
// So: Haven runs WebRTC with `useManualAudio` (its audio unit stays uninitialized until we say so),
// and only says so after this gate has seen the output device start and stop promptly. If it
// doesn't, the call carries on without audio — video and screen share are untouched — the call
// screen says so, and the gate keeps re-probing with backoff until audio comes back.

/// What one health probe saw.
enum CallAudioProbeOutcome: Equatable, Sendable {
    /// The output device started (and stopped) within the deadline.
    case healthy
    /// The probe came back, but the device refused (player could not be built / `play()` failed).
    case failed
    /// No answer within the deadline. The probe may still be blocked inside AudioToolbox — and while
    /// it is, RemoteIO must not be touched (see the file header).
    case timedOut
}

/// The pure decisions behind `CallAudioGate`, split out so they are unit-tested without audio.
enum CallAudioPolicy {
    /// How long the output device gets to start before audio is declared unavailable. A healthy
    /// start is tens of milliseconds; a wedged one is ~15 s. Three seconds separates them with room
    /// for a slow Bluetooth route.
    static let probeTimeout: TimeInterval = 3

    /// Backoff between re-probes after a failure: quick at first (a route settling), then patient
    /// (a wedged audio server can take a while to be restarted by the system). Last value repeats.
    static let retryDelays: [TimeInterval] = [2, 4, 8, 15, 30]

    /// How often to look again while some OTHER audio start (a ringtone, a previous probe that
    /// timed out) is still blocked inside AudioToolbox.
    static let busyPollInterval: TimeInterval = 0.25

    enum Decision: Equatable {
        /// Audio is usable: switch call audio on.
        case enable
        /// Audio is not usable: run the call without it and probe again after `retryIn` seconds.
        case degrade(retryIn: TimeInterval)
    }

    /// Delay before the next probe after `failures` consecutive failures (1-based).
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let i = max(0, min(failures - 1, retryDelays.count - 1))
        return retryDelays[i]
    }

    /// Turn a probe outcome into what the call should do. `failures` is the count BEFORE this one.
    static func decide(_ outcome: CallAudioProbeOutcome, priorFailures failures: Int) -> Decision {
        switch outcome {
        case .healthy: return .enable
        case .failed, .timedOut: return .degrade(retryIn: retryDelay(afterFailures: failures + 1))
        }
    }

    enum BusyDecision: Equatable {
        /// Nothing else is starting audio — the probe may run now.
        case proceed
        /// Another start is still blocked; look again after `retryIn` seconds.
        case wait(retryIn: TimeInterval)
        /// It has been blocked longer than a healthy device ever takes: count it as a timeout.
        case giveUp
    }

    /// Whether a probe (or the enable that follows a good one) may proceed while another audio
    /// start may be blocked. Never proceed while one is: that blocked start is what makes RemoteIO
    /// time out and abort.
    static func busyDecision(otherStartInFlight: Bool, busyFor: TimeInterval) -> BusyDecision {
        guard otherStartInFlight else { return .proceed }
        return busyFor >= probeTimeout ? .giveUp : .wait(retryIn: busyPollInterval)
    }
}

/// Something that can test whether the audio output device starts. `run` may block for a long
/// time on its own thread; `done` is delivered on the main actor exactly once.
protocol CallAudioProbing: AnyObject {
    /// True while a probe is still executing (possibly stuck past its deadline). Thread-safe.
    var isRunning: Bool { get }
    func run(_ done: @escaping @MainActor @Sendable (CallAudioProbeOutcome) -> Void)
}

/// Decides whether — and when — a call may switch real audio I/O on. One per process (the audio
/// system is process-wide); `CallManager` resets it per call.
@MainActor
final class CallAudioGate {
    enum State: Equatable {
        case unknown        // nothing asked yet this call
        case probing        // a probe (or a wait for another blocked start) is in progress
        case available      // the device answered promptly: audio may run
        case unavailable    // it did not: the call runs without audio and a retry is scheduled
    }

    private(set) var state: State = .unknown
    /// Consecutive failed probes this call. Drives the backoff and the banner.
    private(set) var failures = 0

    /// Fires on every state change (main actor).
    var onStateChange: ((State) -> Void)?
    /// Fires each time audio becomes available (main actor) — switch call audio on here.
    var onAvailable: (() -> Void)?

    /// Whether the call screen should say audio is unavailable: a probe has failed this call and
    /// audio has not come back yet (including while a retry is in flight — the banner must not
    /// flicker away during every re-probe).
    var showsUnavailableBanner: Bool { failures > 0 && state != .available }

    var isAvailable: Bool { state == .available }

    private let probe: CallAudioProbing
    /// Whether some other audio start (a call tone) may still be blocked in AudioToolbox.
    private let otherStartInFlight: () -> Bool
    /// Run a block on the main actor after a delay. Injected so tests drive time by hand.
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Bumped by `reset()` and by every new attempt: stale timers and late probe results check it
    /// and bail, so a probe that answers after its deadline (or after the call ended) is ignored.
    private var attempt = 0
    private var busySince: Date?
    /// The attempt whose probe already answered (or timed out) — whichever comes second is ignored.
    private var settled = -1
    private let now: () -> Date

    init(probe: CallAudioProbing,
         otherStartInFlight: @escaping () -> Bool = { false },
         now: @escaping () -> Date = Date.init,
         schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil) {
        self.probe = probe
        self.otherStartInFlight = otherStartInFlight
        self.now = now
        self.schedule = schedule ?? { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { block() } }
        }
    }

    /// Ask for audio. No-op if it is already available or a probe is underway; otherwise starts
    /// one. Call audio is switched on from `onAvailable`, never by the caller directly.
    func request(reason: String) {
        switch state {
        case .available, .probing: return
        case .unknown, .unavailable:
            HavenLog.call("audio gate: probing (\(reason))")
            begin()
        }
    }

    /// The user tapped Retry (or something suggests the device is back): probe now instead of
    /// waiting out the backoff. Ignored while a probe is already running or audio is up.
    func retryNow() {
        guard state == .unavailable else { return }
        HavenLog.call("audio gate: manual retry")
        begin()
    }

    /// The audio system was reset under us (media services reset): what we knew is stale.
    /// Re-probe before anything touches RemoteIO again.
    func invalidate(reason: String) {
        guard state == .available else { return }
        HavenLog.call("audio gate: invalidated (\(reason)) — re-probing")
        attempt &+= 1
        set(.unknown)
        begin()
    }

    /// The call ended: forget everything. A probe still blocked keeps `probe.isRunning` true, so
    /// the next call will wait for it instead of piling onto a stuck device.
    func reset() {
        attempt &+= 1
        failures = 0
        busySince = nil
        set(.unknown)
    }

    // MARK: - Internals

    private func begin() {
        attempt &+= 1
        busySince = nil
        set(.probing)
        waitThenProbe(attempt)
    }

    /// Never start a probe — and never enable — while another start is blocked in AudioToolbox.
    private func waitThenProbe(_ token: Int) {
        guard token == attempt else { return }
        switch busy(token) {
        case .wait(let d): schedule(d) { [weak self] in self?.waitThenProbe(token) }
        case .giveUp: finish(.timedOut, token)
        case .proceed:
            probe.run { [weak self] outcome in
                guard let self, token == self.attempt, self.settled != token else { return }
                self.settled = token
                self.probed(outcome, token)
            }
            schedule(CallAudioPolicy.probeTimeout) { [weak self] in
                guard let self, token == self.attempt, self.settled != token else { return }
                self.settled = token
                HavenLog.call("audio gate: probe exceeded \(CallAudioPolicy.probeTimeout)s — audio unavailable")
                self.finish(.timedOut, token)
            }
        }
    }

    private func probed(_ outcome: CallAudioProbeOutcome, _ token: Int) {
        guard outcome == .healthy else { finish(outcome, token); return }
        // A good probe can still race a tone that began starting meanwhile; wait that out too.
        busySince = nil
        confirmIdleThenEnable(token)
    }

    private func confirmIdleThenEnable(_ token: Int) {
        guard token == attempt else { return }
        switch busy(token) {
        case .wait(let d): schedule(d) { [weak self] in self?.confirmIdleThenEnable(token) }
        case .giveUp: finish(.timedOut, token)
        case .proceed: finish(.healthy, token)
        }
    }

    private func busy(_ token: Int) -> CallAudioPolicy.BusyDecision {
        let inFlight = probe.isRunning || otherStartInFlight()
        if !inFlight { busySince = nil; return .proceed }
        let since = busySince ?? now()
        busySince = since
        return CallAudioPolicy.busyDecision(otherStartInFlight: true, busyFor: now().timeIntervalSince(since))
    }

    private func finish(_ outcome: CallAudioProbeOutcome, _ token: Int) {
        guard token == attempt else { return }
        switch CallAudioPolicy.decide(outcome, priorFailures: failures) {
        case .enable:
            if failures > 0 { HavenLog.call("audio gate: audio is back after \(failures) failed probe(s)") }
            failures = 0
            set(.available)
            onAvailable?()
        case .degrade(let retryIn):
            failures += 1
            HavenLog.call("audio gate: audio unavailable (\(outcome), failure \(failures)) — call continues without audio; retry in \(retryIn)s")
            set(.unavailable)
            schedule(retryIn) { [weak self] in
                guard let self, token == self.attempt, self.state == .unavailable else { return }
                self.begin()
            }
        }
    }

    private func set(_ s: State) {
        guard state != s else { return }
        state = s
        onStateChange?(s)
    }
}

/// The real probe: start and stop a silent `AVAudioPlayer` on a dedicated thread.
///
/// AVAudioPlayer rides AudioQueue, whose start on a wedged device BLOCKS (and eventually returns)
/// rather than aborting the way RemoteIO does — so it can test the device without being able to
/// kill the process. It deliberately does NOT use AVAudioEngine or any RemoteIO/VoiceProcessingIO
/// unit: those are the calls that abort.
final class AVAudioOutputProbe: CallAudioProbing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.blaineam.haven.audioprobe", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func run(_ done: @escaping @MainActor @Sendable (CallAudioProbeOutcome) -> Void) {
        lock.lock(); running = true; lock.unlock()
        queue.async { [self] in
            let outcome = Self.probeOnce()
            lock.lock(); running = false; lock.unlock()
            Task { @MainActor in done(outcome) }
        }
    }

    private static func probeOnce() -> CallAudioProbeOutcome {
        #if DEBUG
        if let injected = CallAudioProbeFault.next() { return injected }
        #endif
        guard let player = try? AVAudioPlayer(data: silentWAV) else { return .failed }
        player.volume = 0
        // Both block until the output device actually starts — that wait IS the measurement.
        guard player.prepareToPlay(), player.play() else { return .failed }
        player.stop()
        return .healthy
    }

    /// 50 ms of 16-bit mono silence.
    private static let silentWAV: Data = {
        let rate = 16_000, frames = rate / 20, bytes = frames * 2
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.append(Data(count: bytes))
        return d
    }()
}

#if DEBUG
/// DEBUG-only fault injection for the degrade path, so it can be exercised on a machine whose
/// audio is healthy. Launch with `HAVEN_AUDIO_PROBE_FAIL` set to:
///   • `always` — every probe fails (audio never comes up; the banner stays, retries keep going)
///   • `hang`   — the first probe blocks 10 s (past its deadline), later ones run for real
///   • `N`      — the first N probes fail, later ones run for real (exercises recovery)
enum CallAudioProbeFault {
    private static let lock = NSLock()
    private static var used = 0

    /// Called on the probe's own queue. Nil = run the real probe.
    static func next() -> CallAudioProbeOutcome? {
        guard let spec = ProcessInfo.processInfo.environment["HAVEN_AUDIO_PROBE_FAIL"], !spec.isEmpty else { return nil }
        lock.lock(); used += 1; let n = used; lock.unlock()
        HavenLog.call("audio gate: DEBUG probe fault '\(spec)' (probe #\(n))")
        switch spec {
        case "always": return .failed
        case "hang":
            guard n == 1 else { return nil }
            Thread.sleep(forTimeInterval: 10)
            return .failed
        default:
            guard let limit = Int(spec) else { return nil }
            return n <= limit ? .failed : nil
        }
    }
}
#endif
