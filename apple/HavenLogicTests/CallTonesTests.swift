import XCTest

/// `CallTones`: a ringback/ringtone whose output device won't start (AVAudioPlayer's prepare/play
/// block ~15 s each) must not block the main actor — the caller sends its invites and the callee
/// its answer right after starting a tone, and a 30 s main-thread stall there dropped calls.
final class CallTonesTests: XCTestCase {
    /// A player whose `play()` blocks until released, like AVAudioPlayer on a wedged device.
    private final class StuckPlayer: CallTonePlayer, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        let playing = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _stopped = 0
        var stopped: Int { lock.lock(); defer { lock.unlock() }; return _stopped }
        func play() { playing.signal(); release.wait() }
        func stop() { lock.lock(); _stopped += 1; lock.unlock() }
    }

    private final class Factory: @unchecked Sendable {
        private let lock = NSLock()
        private var _made: [(StuckPlayer, Float)] = []
        var made: [(StuckPlayer, Float)] { lock.lock(); defer { lock.unlock() }; return _made }
        func make(_ wav: Data, _ volume: Float) -> CallTonePlayer? {
            XCTAssertFalse(wav.isEmpty)
            let p = StuckPlayer()
            lock.lock(); _made.append((p, volume)); lock.unlock()
            return p
        }
    }

    @MainActor
    func testStartReturnsWhileTheDeviceIsStuck() {
        let factory = Factory()
        let tones = CallTones(makePlayer: { factory.make($0, $1) })
        let t0 = Date()
        tones.startRingback()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5, "the main actor must not wait on the audio device")
        let deadline = Date().addingTimeInterval(5)
        while factory.made.isEmpty && Date() < deadline { usleep(10_000) }
        guard let (player, volume) = factory.made.first else { return XCTFail("tone never started") }
        XCTAssertEqual(volume, 0.45)
        XCTAssertEqual(player.playing.wait(timeout: .now() + 5), .success)
        tones.stop()   // also returns at once, while play() is still stuck
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        player.release.signal()
    }

    func testStopDuringAStuckStartSilencesItOnReturn() {
        let factory = Factory()
        let driver = CallToneDriver(makePlayer: { factory.make($0, $1) })
        driver.start(.ringtone)
        let deadline = Date().addingTimeInterval(5)
        while factory.made.isEmpty && Date() < deadline { usleep(10_000) }
        guard let (player, volume) = factory.made.first else { return XCTFail("tone never started") }
        XCTAssertEqual(volume, 0.7)
        XCTAssertEqual(player.playing.wait(timeout: .now() + 5), .success)
        driver.stop()
        player.release.signal()
        driver.drain()
        XCTAssertGreaterThanOrEqual(player.stopped, 1, "a tone stopped mid-start must not keep ringing")
    }

    func testStartThenStopBeforeTheQueueRunsNeverPlays() {
        let factory = Factory()
        let driver = CallToneDriver(makePlayer: { factory.make($0, $1) })
        // Park the queue behind a stuck tone, then queue start+stop for a second one.
        driver.start(.ringback)
        let deadline = Date().addingTimeInterval(5)
        while factory.made.isEmpty && Date() < deadline { usleep(10_000) }
        guard let (first, _) = factory.made.first else { return XCTFail("tone never started") }
        XCTAssertEqual(first.playing.wait(timeout: .now() + 5), .success)
        driver.start(.ringtone)
        driver.stop()
        first.release.signal()
        driver.drain()
        XCTAssertEqual(factory.made.count, 1, "a superseded start must not create a player")
        XCTAssertGreaterThanOrEqual(first.stopped, 1)
    }
}
