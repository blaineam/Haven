import Foundation
import AVFoundation

/// A gentle, synthesized "dialing" loop played while a call is ringing the other side — no audio
/// asset needed. Stops the moment the call connects (or ends). Works for 1:1 and group dialing.
///
/// Every AVAudioPlayer call runs on `CallToneDriver`'s serial queue, never on the main actor:
/// `prepareToPlay()`/`play()` block until the output device starts, and a device that won't start
/// (a disconnected virtual/remote-desktop output, a Bluetooth route mid-handoff, a wedged
/// coreaudiod) holds them ~15 s EACH. On main that froze the caller for 30 s inside
/// `beginOutgoing` — the invites went out 30 s late, the ~30 s invite give-up then hung up before
/// the answer landed — and froze the callee 15 s inside `accept` before its answer was sent.
@MainActor
final class CallTones {
    static let shared = CallTones()
    private let driver: CallToneDriver
    /// Main-side mirror of "a tone is playing or starting", so a second start is a no-op (as before).
    private var sounding = false

    init(makePlayer: @escaping @Sendable (Data, Float) -> CallTonePlayer? = AVCallTonePlayer.make) {
        driver = CallToneDriver(makePlayer: makePlayer)
    }

    func startRingback() { start(.ringback) }

    /// A more insistent looping "incoming call" ringtone, used on Mac (no CallKit system ring).
    /// Distinct cadence from the dialing ringback so the two are never confused.
    func startRingtone() { start(.ringtone) }

    func stop() {
        sounding = false
        driver.stop()
    }

    /// True while a tone's `play()` is still inside AudioToolbox — possibly stuck on a wedged
    /// device. `CallAudioGate` must not let RemoteIO start while it is (see CallAudioGate.swift).
    var startInFlight: Bool { driver.startInFlight }

    private func start(_ tone: CallTone) {
        guard !sounding else { return }
        sounding = true
        driver.start(tone)
    }
}

/// A looping tone player. `play()` may block for seconds on a device that won't start — it is only
/// ever called on `CallToneDriver`'s queue.
protocol CallTonePlayer: AnyObject {
    func play()
    func stop()
}

final class AVCallTonePlayer: CallTonePlayer {
    private let player: AVAudioPlayer

    private init(player: AVAudioPlayer) { self.player = player }

    @Sendable static func make(wav: Data, volume: Float) -> CallTonePlayer? {
        guard let p = try? AVAudioPlayer(data: wav) else { return nil }
        p.numberOfLoops = -1
        p.volume = volume
        return AVCallTonePlayer(player: p)
    }

    func play() {
        player.prepareToPlay()
        player.play()
    }

    func stop() { player.stop() }
}

/// Serializes tone starts/stops off the main thread. A stop issued while a start is still blocked
/// in `play()` wins: the start sees its generation superseded and silences the player on return.
final class CallToneDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.blaineam.haven.calltones", qos: .userInitiated)
    private let makePlayer: @Sendable (Data, Float) -> CallTonePlayer?
    private let lock = NSLock()
    private var generation: UInt64 = 0     // guarded by `lock`; bumped by every start and stop
    private var player: CallTonePlayer?    // confined to `queue`
    private var starting = false           // guarded by `lock`; true while `play()` runs

    /// Whether a `play()` is executing right now (thread-safe).
    var startInFlight: Bool {
        lock.lock(); defer { lock.unlock() }
        return starting
    }

    init(makePlayer: @escaping @Sendable (Data, Float) -> CallTonePlayer?) {
        self.makePlayer = makePlayer
    }

    func start(_ tone: CallTone) {
        let gen = bump()
        queue.async { [self] in
            guard isCurrent(gen) else { return }
            player?.stop()
            player = nil
            guard let wav = tone.wav, let p = makePlayer(wav, tone.volume) else { return }
            player = p
            setStarting(true)
            p.play()
            setStarting(false)
            if !isCurrent(gen) {
                p.stop()
                if player === p { player = nil }
            }
        }
    }

    func stop() {
        _ = bump()
        queue.async { [self] in
            player?.stop()
            player = nil
        }
    }

    /// Blocks until every start/stop queued so far has run. Tests only.
    func drain() { queue.sync {} }

    private func setStarting(_ on: Bool) {
        lock.lock(); starting = on; lock.unlock()
    }

    private func bump() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }
}

enum CallTone: Sendable {
    case ringback, ringtone

    var volume: Float { self == .ringback ? 0.45 : 0.7 }

    /// Rendered once, lazily, on the driver's queue (static lets are thread-safe).
    var wav: Data? { self == .ringback ? Self.ringbackData : Self.ringtoneData }
    private static let ringbackData: Data? = ringbackWAV()
    private static let ringtoneData: Data? = ringtoneWAV()

    /// Synthesize a warm, looping two-note arpeggio (a friendlier take on a ringback cadence),
    /// rendered to an in-memory 16-bit PCM WAV so AVAudioPlayer can loop it seamlessly.
    private static func ringbackWAV() -> Data? {
        let sampleRate = 44_100.0
        let beat = 0.5                  // seconds per note
        let notes: [Double] = [523.25, 659.25, 783.99, 659.25]   // C5 E5 G5 E5 — a gentle major arp
        let gap = 1.0                   // silence after the phrase, so it feels like "ringing"
        let phrase = Double(notes.count) * beat
        let total = phrase + gap
        let frameCount = Int(total * sampleRate)
        var samples = [Int16](repeating: 0, count: frameCount)

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            guard t < phrase else { continue }   // gap = silence
            let noteIdx = min(notes.count - 1, Int(t / beat))
            let local = t - Double(noteIdx) * beat
            let freq = notes[noteIdx]
            // Soft attack/decay envelope per note so it's pleasant, not harsh.
            let env = sin(Double.pi * (local / beat))
            let value = sin(2 * Double.pi * freq * t) * env * 0.35
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }

        return wav(samples, sampleRate: Int(sampleRate))
    }

    /// Synthesize a brighter, more urgent two-tone "ring-ring" burst followed by a pause, looped —
    /// reads as an incoming call rather than a gentle dialing tone.
    private static func ringtoneWAV() -> Data? {
        let sampleRate = 44_100.0
        let ring = 0.4                  // seconds per ring burst
        let innerGap = 0.2              // short gap between the two bursts of a "ring-ring"
        let trailGap = 1.8              // long silence after the pair, the classic ring cadence
        let freqs: [Double] = [880.0, 660.0]   // alternating two-tone within each burst
        let total = ring + innerGap + ring + trailGap
        let frameCount = Int(total * sampleRate)
        var samples = [Int16](repeating: 0, count: frameCount)

        func renderBurst(start: Double) {
            let s = Int(start * sampleRate)
            let e = Int((start + ring) * sampleRate)
            for i in s..<min(e, frameCount) {
                let t = Double(i) / sampleRate
                let local = t - start
                // Alternate the two tones a few times per burst for the warble.
                let freq = freqs[Int(local * 12) % freqs.count]
                let env = sin(Double.pi * (local / ring))
                let value = sin(2 * Double.pi * freq * t) * env * 0.5
                samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
            }
        }
        renderBurst(start: 0)
        renderBurst(start: ring + innerGap)

        return wav(samples, sampleRate: Int(sampleRate))
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        d.append("RIFF".data(using: .ascii)!); d.append(u32(36 + dataSize)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); d.append(u32(16)); d.append(u16(1)); d.append(u16(1))
        d.append(u32(sampleRate)); d.append(u32(byteRate)); d.append(u16(2)); d.append(u16(16))
        d.append("data".data(using: .ascii)!); d.append(u32(dataSize))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
