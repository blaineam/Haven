#if os(iOS)
import AVFoundation
import Foundation

/// Reads a conversation aloud from the CarPlay conversation screen ("Read new messages" / "Read to me",
/// or a tap on one message). The Siri-managed message rows can only read through Siri; this is the
/// app's own, so it works from a tap and never has to guess at a spoken name.
///
/// Audio rules:
///   * spoken-audio session that ducks/interrupts other audio (music, podcasts) and hands the car back
///     afterwards (`notifyOthersOnDeactivation`);
///   * never while a Haven call is up (it would talk over the person on the line);
///   * a new request, or the scene disconnecting, stops what is being read.
/// The script itself (what may be spoken at all) comes from `CarPlayConversations.spokenScript`, so the
/// locked / notification-privacy rules are applied before anything reaches the synthesizer.
@MainActor
final class CarPlaySpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = CarPlaySpeaker()

    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    private var onFinished: (() -> Void)?

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak `script` utterance by utterance. `completion` runs once all of it has been spoken (not when
    /// stopped early).
    func speak(_ script: [String], completion: (() -> Void)? = nil) {
        stop()
        let lines = script.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, !CallManager.shared.callInProgress else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
        try? session.setActive(true)
        onFinished = completion
        pending = lines.count
        for line in lines {
            let u = AVSpeechUtterance(string: line)
            u.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
            u.postUtteranceDelay = 0.35
            synth.speak(u)
        }
    }

    func stop() {
        onFinished = nil
        pending = 0
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        release()
    }

    private func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.pending > 0 else { return }
            self.pending -= 1
            if self.pending == 0 {
                let done = self.onFinished
                self.onFinished = nil
                self.release()
                done?()
            }
        }
    }
}
#endif
