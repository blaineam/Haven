import XCTest

/// `CallAudioGate`: call audio (WebRTC's RemoteIO, the hairpin AVAudioEngine) may only start once a
/// probe has seen the output device answer — on a hung audio server RemoteIO ABORTS the process.
/// A failed/timed-out probe must degrade the call (no audio, banner, backoff retry), never enable.
@MainActor
final class CallAudioGateTests: XCTestCase {
    /// A probe the test answers by hand. `isRunning` stays true until answered, like a real probe
    /// blocked inside AudioToolbox.
    private final class FakeProbe: CallAudioProbing, @unchecked Sendable {
        var runs = 0
        var running = false
        var pending: (@MainActor @Sendable (CallAudioProbeOutcome) -> Void)?
        var isRunning: Bool { running }
        func run(_ done: @escaping @MainActor @Sendable (CallAudioProbeOutcome) -> Void) {
            runs += 1; running = true; pending = done
        }
        @MainActor func answer(_ o: CallAudioProbeOutcome) {
            running = false
            let d = pending; pending = nil
            d?(o)
        }
    }

    /// Manual clock + timer queue.
    private final class Clock {
        var t = Date(timeIntervalSince1970: 1_000)
        var timers: [(at: Date, block: @MainActor () -> Void)] = []
        func schedule(_ d: TimeInterval, _ b: @escaping @MainActor () -> Void) {
            timers.append((t.addingTimeInterval(d), b))
        }
        /// Advance time, firing due timers in order (including ones they schedule).
        @MainActor func advance(_ d: TimeInterval) {
            let end = t.addingTimeInterval(d)
            while let i = timers.indices.filter({ timers[$0].at <= end }).min(by: { timers[$0].at < timers[$1].at }) {
                let timer = timers.remove(at: i)
                t = max(t, timer.at)
                timer.block()
            }
            t = end
        }
    }

    private var probe: FakeProbe!
    private var clock: Clock!
    private var toneBusy = false
    private var enabled = 0
    private var gate: CallAudioGate!

    override func setUp() async throws {
        probe = FakeProbe(); clock = Clock(); toneBusy = false; enabled = 0
        let c = clock!
        gate = CallAudioGate(probe: probe,
                             otherStartInFlight: { [unowned self] in self.toneBusy },
                             now: { c.t },
                             schedule: { d, b in c.schedule(d, b) })
        gate.onAvailable = { [unowned self] in self.enabled += 1 }
    }

    // MARK: Policy

    func testPolicyEnablesOnlyOnHealthy() {
        XCTAssertEqual(CallAudioPolicy.decide(.healthy, priorFailures: 3), .enable)
        XCTAssertEqual(CallAudioPolicy.decide(.failed, priorFailures: 0), .degrade(retryIn: 2))
        XCTAssertEqual(CallAudioPolicy.decide(.timedOut, priorFailures: 0), .degrade(retryIn: 2))
    }

    func testPolicyBackoffGrowsThenCaps() {
        let delays = (1...8).map { CallAudioPolicy.retryDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [2, 4, 8, 15, 30, 30, 30, 30])
        XCTAssertEqual(CallAudioPolicy.decide(.failed, priorFailures: 2), .degrade(retryIn: 8))
    }

    func testPolicyNeverProceedsWhileAnotherStartIsBlocked() {
        XCTAssertEqual(CallAudioPolicy.busyDecision(otherStartInFlight: false, busyFor: 99), .proceed)
        XCTAssertEqual(CallAudioPolicy.busyDecision(otherStartInFlight: true, busyFor: 0),
                       .wait(retryIn: CallAudioPolicy.busyPollInterval))
        XCTAssertEqual(CallAudioPolicy.busyDecision(otherStartInFlight: true, busyFor: CallAudioPolicy.probeTimeout),
                       .giveUp)
    }

    // MARK: Gate

    func testHealthyProbeEnables() {
        gate.request(reason: "t")
        XCTAssertEqual(gate.state, .probing)
        XCTAssertEqual(enabled, 0, "nothing may enable before the probe answers")
        probe.answer(.healthy)
        XCTAssertEqual(gate.state, .available)
        XCTAssertEqual(enabled, 1)
        XCTAssertFalse(gate.showsUnavailableBanner)
        gate.request(reason: "again")
        XCTAssertEqual(probe.runs, 1, "an available gate does not re-probe")
    }

    func testFailedProbeDegradesShowsBannerAndRetries() {
        gate.request(reason: "t")
        probe.answer(.failed)
        XCTAssertEqual(gate.state, .unavailable)
        XCTAssertEqual(enabled, 0)
        XCTAssertTrue(gate.showsUnavailableBanner)
        clock.advance(1.9)
        XCTAssertEqual(probe.runs, 1, "retry waits out the backoff")
        clock.advance(0.2)
        XCTAssertEqual(probe.runs, 2)
        XCTAssertTrue(gate.showsUnavailableBanner, "banner holds while the retry runs")
        probe.answer(.healthy)
        XCTAssertEqual(gate.state, .available)
        XCTAssertEqual(enabled, 1)
        XCTAssertFalse(gate.showsUnavailableBanner)
    }

    /// The crash case: the probe hangs inside AudioToolbox. Past the deadline the call degrades —
    /// and NO retry may launch (or enable) while the hung probe is still running, because that
    /// blocked start is exactly what makes the next RemoteIO call abort.
    func testHungProbeTimesOutAndBlocksRetryUntilItReturns() {
        gate.request(reason: "t")
        clock.advance(CallAudioPolicy.probeTimeout)
        XCTAssertEqual(gate.state, .unavailable)
        XCTAssertEqual(gate.failures, 1)
        XCTAssertEqual(enabled, 0)
        // Backoff elapses, probe is STILL stuck: no second probe, and it counts as another failure.
        clock.advance(2 + CallAudioPolicy.probeTimeout)
        XCTAssertEqual(probe.runs, 1)
        XCTAssertEqual(gate.failures, 2)
        XCTAssertEqual(enabled, 0)
        // A late "healthy" from the stuck probe belongs to a dead attempt — ignored.
        probe.answer(.healthy)
        XCTAssertEqual(enabled, 0)
        XCTAssertEqual(gate.state, .unavailable)
        // Next retry runs a fresh probe that answers.
        clock.advance(4)
        XCTAssertEqual(probe.runs, 2)
        probe.answer(.healthy)
        XCTAssertEqual(enabled, 1)
    }

    func testBlockedToneDefersProbeAndEnable() {
        toneBusy = true
        gate.request(reason: "t")
        XCTAssertEqual(probe.runs, 0, "no probe while a ringtone start is blocked")
        clock.advance(1)
        toneBusy = false
        clock.advance(CallAudioPolicy.busyPollInterval)
        XCTAssertEqual(probe.runs, 1)
        // Tone starts again just as the probe succeeds: enable must wait for it.
        toneBusy = true
        probe.answer(.healthy)
        XCTAssertEqual(enabled, 0)
        toneBusy = false
        clock.advance(CallAudioPolicy.busyPollInterval)
        XCTAssertEqual(enabled, 1)
    }

    func testToneStuckPastDeadlineDegrades() {
        toneBusy = true
        gate.request(reason: "t")
        clock.advance(CallAudioPolicy.probeTimeout + 0.5)
        XCTAssertEqual(gate.state, .unavailable)
        XCTAssertEqual(probe.runs, 0)
        XCTAssertEqual(enabled, 0)
    }

    func testManualRetrySkipsBackoff() {
        gate.request(reason: "t")
        probe.answer(.failed)
        gate.retryNow()
        XCTAssertEqual(probe.runs, 2)
        probe.answer(.healthy)
        XCTAssertEqual(enabled, 1)
        // The superseded backoff timer must not start another probe.
        clock.advance(60)
        XCTAssertEqual(probe.runs, 2)
    }

    func testResetDropsLateResultsAndClearsBanner() {
        gate.request(reason: "t")
        probe.answer(.failed)
        gate.request(reason: "retry")  // unavailable → probes again
        gate.reset()
        XCTAssertEqual(gate.state, .unknown)
        XCTAssertFalse(gate.showsUnavailableBanner)
        probe.answer(.healthy)
        XCTAssertEqual(enabled, 0, "a probe from the ended call must not enable audio")
        clock.advance(60)
        XCTAssertEqual(gate.state, .unknown)
    }

    func testInvalidateReprobesBeforeReenabling() {
        gate.request(reason: "t")
        probe.answer(.healthy)
        XCTAssertEqual(enabled, 1)
        gate.invalidate(reason: "media services reset")
        XCTAssertEqual(gate.state, .probing)
        XCTAssertFalse(gate.isAvailable)
        probe.answer(.healthy)
        XCTAssertEqual(enabled, 2)
    }
}
