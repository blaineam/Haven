import SwiftUI

/// Media currently being prepared for sending — encoding, filtering, splitting.
///
/// Attaching a video is not instant: a 67-second clip takes ~35 seconds to re-encode, and a Photos
/// pick can be far heavier still. Until now that window was completely silent. You chose a video, the
/// composer showed nothing, and there was no way to tell "working on it" from "it didn't take".
///
/// That gap cost real debugging time: when the encoder deadlocked, the symptom users reported was
/// "attaching a video never attaches anything" — indistinguishable from slow processing, because
/// nothing on screen separated the two. A visible in-progress state is a diagnostic, not just polish.
///
/// Counted rather than boolean so several attachments in flight resolve independently, and so a
/// failure that forgets to balance its `begin` can be seen rather than silently pinning the UI.
@MainActor
final class MediaProcessing: ObservableObject {
    static let shared = MediaProcessing()

    @Published private(set) var inFlight = 0
    /// What to call it on screen. Plural is handled by the view.
    @Published private(set) var label = "video"

    var isBusy: Bool { inFlight > 0 }

    func begin(_ what: String = "video") {
        label = what
        inFlight += 1
    }

    func end() {
        inFlight = max(0, inFlight - 1)
    }

    /// Run `body` with the indicator up, balanced however it exits.
    static func tracking<T>(_ what: String = "video", _ body: () async -> T) async -> T {
        await MainActor.run { MediaProcessing.shared.begin(what) }
        defer { Task { @MainActor in MediaProcessing.shared.end() } }
        return await body()
    }
}

/// The card the composer shows while something is being prepared.
struct MediaProcessingCard: View {
    @ObservedObject private var processing = MediaProcessing.shared

    var body: some View {
        if processing.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(processing.inFlight > 1
                         ? "Preparing \(processing.inFlight) \(processing.label)s…"
                         : "Preparing your \(processing.label)…")
                        .font(.caption.weight(.medium))
                    // Says why it takes a moment, so a slow encode doesn't read as a stuck app.
                    Text("Compressing so it sends quickly")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
