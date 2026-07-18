import SwiftUI
import AVFoundation

/// Records a short audio reply to a temp file. Mic permission is the existing
/// NSMicrophoneUsageDescription. The recording is treated like any other media —
/// sealed E2E before it's sent.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var url: URL?

    func start() {
        // AVAudioSession is iOS/Catalyst-only; macOS records without a session.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)
        #endif
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        recorder = try? AVAudioRecorder(url: u, settings: settings)
        recorder?.record()
        url = u
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in self.elapsed += 0.1 }
        }
    }

    @discardableResult
    func stop() -> URL? {
        recorder?.stop(); recorder = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        return url
    }
}

/// A tap-to-record sheet for an audio reply.
struct AudioRecorderView: View {
    var onDone: (String) -> Void
    @StateObject private var rec = AudioRecorder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            HavenBackground()
            VStack(spacing: 24) {
                Text(rec.isRecording ? "Recording…" : "Record an audio reply")
                    .font(.headline)
                Text(String(format: "%0.1fs", rec.elapsed))
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(rec.isRecording ? HavenTheme.pink : .secondary)
                EqualizerBars(animating: rec.isRecording).frame(width: 60, height: 30)

                Button {
                    if rec.isRecording {
                        if let u = rec.stop() { onDone(MediaStore.shared.addAudio(url: u)); dismiss() }
                    } else {
                        AVAudioApplication.requestRecordPermission { _ in }
                        rec.start()
                    }
                } label: {
                    Image(systemName: rec.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(HavenTheme.brand)
                }
                Button("Cancel") { rec.stop(); dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        }
        .presentationDetents([.medium]).havenPausesPostAudio()
    }
}

/// A small play/pause pill for an audio reply.
struct AudioPlayerPill: View {
    let url: URL
    @StateObject private var engine = AudioPillEngine()

    var body: some View {
        Button(action: { engine.toggle(url: url) }) {
            HStack(spacing: 8) {
                Image(systemName: engine.playing ? "pause.fill" : "play.fill")
                EqualizerBars(animating: engine.playing)
                Text("Audio").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(HavenTheme.pink.opacity(0.35)))
        }
        .buttonStyle(PressableStyle())
        .onDisappear { engine.stop() }
    }
}

/// Owns the AVAudioPlayer + its delegate so a voice reply actually makes sound and the pill resets when
/// the clip ends. Two bugs this fixes: (1) the session was only *categorized* `.playback` but never
/// *activated* — without `setActive(true)` the output route never switches, so it played silently;
/// (2) there was no finished-callback, so the pill stayed stuck showing "pause" after the clip ended.
@MainActor final class AudioPillEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    private var player: AVAudioPlayer?

    func toggle(url: URL) {
        if playing { player?.pause(); playing = false; return }
        if player == nil {
            #if os(iOS)
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .spokenAudio)
            try? s.setActive(true)   // REQUIRED — categorizing alone leaves the route unset → silence
            #endif
            let p = try? AVAudioPlayer(contentsOf: url)
            p?.delegate = self
            p?.volume = 1
            p?.prepareToPlay()
            player = p
        }
        player?.play(); playing = true
    }

    func stop() {
        player?.stop(); playing = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }
}
