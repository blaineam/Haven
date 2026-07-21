#if os(iOS)
import AudioToolbox
import QuartzCore
import Foundation

/// Best-effort detection of the hardware ring/silent switch. iOS exposes **no** API for it, so we
/// use the well-known trick: play a short, genuinely silent system sound and time it. When the
/// switch is set to silent the system suppresses the sound and the completion fires almost
/// instantly; when the ringer is on it "plays" for the sound's full duration. We use this once at
/// launch to seed the post-audio autoplay default (silenced → start muted; ringer on → autoplay).
///
/// Limitations (honest): it's a heuristic, it can't be exercised in the Simulator (no switch), and
/// MusicKit/Apple-Music playback itself ignores the switch by design — this only gates whether we
/// *auto-start* the music, which is the behavior the product wants.
enum SilentSwitch {
    /// Length of the silent probe sound. Suppressed playback returns in well under half of this.
    private static let probeSeconds = 0.45

    /// A genuinely-silent PCM WAV written to temp once, reused thereafter. No bundled asset needed.
    private static func probeURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haven-silent-probe.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 8000
        let frames = Int(Double(sampleRate) * probeSeconds)
        let dataBytes = frames * 2   // 16-bit mono
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)   // PCM, mono
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))   // pure silence
        return (try? d.write(to: url)) == nil ? nil : url
    }

    // MARK: - Continuous monitoring

    /// How often the switch is re-probed while the app is in the foreground. Flipping the physical switch
    /// takes effect within this window rather than requiring the app to be force-quit and relaunched.
    /// 15s (was 2s): each probe plays a silent system sound and wakes AudioSession — at 2s that was
    /// ~30 audio wakeups/min for the whole foreground session (battery + heat for no UX win).
    private static let pollSeconds = 15.0

    @MainActor private static var timer: Timer?
    @MainActor private static var probing = false
    /// The last switch position we observed. Changes are applied EDGE-triggered: flipping the physical
    /// switch takes effect immediately, but a poll that merely re-reads an UNCHANGED position must never
    /// stomp an explicit in-app mute/unmute tap (tapping unmute while the phone is on silent has to stick).
    @MainActor private static var lastSilenced: Bool?

    /// Begin (or restart) foreground monitoring. Safe to call repeatedly — it replaces any existing timer.
    @MainActor static func startMonitoring() {
        stopMonitoring()
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }   // scheduled on the main run loop, so this is genuine
        }
        RunLoop.main.add(t, forMode: .common)   // keep probing while a scroll is tracking
        timer = t
    }

    /// Stop monitoring (backgrounded) — no reason to keep playing probe sounds off-screen.
    @MainActor static func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor private static func poll() {
        // Never probe over a call: call audio owns the session and a system sound has no business there.
        guard !probing, !CallManager.shared.callInProgress else { return }
        probing = true
        detectSilenced { silenced in
            // detectSilenced always completes on the main queue, so this is genuinely isolated.
            MainActor.assumeIsolated {
                probing = false
                defer { lastSilenced = silenced }
                guard lastSilenced != silenced else { return }   // unchanged → leave the user's own tap alone
                if SettingsStore.shared.silent != silenced { SettingsStore.shared.silent = silenced }
            }
        }
    }

    /// Calls back (on the main queue) with `true` if the device appears to be silenced. Always
    /// calls back — `false` if the probe can't run (so the default is "audible / autoplay").
    static func detectSilenced(_ completion: @escaping (Bool) -> Void) {
        guard let url = probeURL() else { completion(false); return }
        var sid: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sid) == noErr else { completion(false); return }
        let start = CACurrentMediaTime()
        AudioServicesPlaySystemSoundWithCompletion(sid) {
            let elapsed = CACurrentMediaTime() - start
            AudioServicesDisposeSystemSoundID(sid)
            DispatchQueue.main.async { completion(elapsed < probeSeconds * 0.5) }
        }
    }
}
#endif
