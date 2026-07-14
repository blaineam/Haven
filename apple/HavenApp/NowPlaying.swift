import SwiftUI

/// The little "now playing" pill shown near a post with attached music: artist + song
/// title and a live audio-playing animation. Tapping the chip toggles the app's global mute
/// (post music + video audio); a small "open in Music" button at the trailing edge opens the
/// song in Apple Music (where adding it to your library is one tap).
struct NowPlayingPill: View {
    let track: TrackRefFfi
    var animating: Bool
    @Environment(\.openURL) private var openURL
    @ObservedObject private var settings = SettingsStore.shared

    /// Apple Music deep link for the shared catalog song (nil for library-only items
    /// that have no store id).
    private var appleMusicURL: URL? {
        guard let store = trackIds(track.catalogId).store else { return nil }
        return URL(string: "https://music.apple.com/song/\(store)")
    }

    var body: some View {
        HStack(spacing: 8) {
            EqualizerBars(animating: animating && !settings.silent)
            Text("\(track.title) · \(track.artist)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            // A muted-speaker glyph makes it clear the chip is the mute control.
            Image(systemName: settings.silent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // "Open in Music" is now a SMALL, explicit element within the chip — not the whole
            // chip's tap target — so a stray tap mutes rather than yanking the user into Music.
            if let url = appleMusicURL {
                Button { openURL(url) } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption).foregroundStyle(HavenTheme.pink)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in Music")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // The chip is a control (tap = mute), so it gets ONE glass surface — the pink now rides the
        // glass as a tint rather than a stroke stacked on a material.
        .havenGlass(in: Capsule(), tint: HavenTheme.pink.opacity(0.35))
        .contentShape(Capsule())
        // Tapping the chip toggles the global mute (post music + video audio).
        .onTapGesture { settings.silent.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title) by \(track.artist). \(settings.silent ? "Unmute" : "Mute") sound")
    }
}

/// Four little bars that bob up and down while audio plays.
struct EqualizerBars: View {
    var animating: Bool
    /// Drives the perpetual bob. Toggled whenever `animating` changes — keying the
    /// `repeatForever` animation on this (not a one-shot onAppear flag) is what makes the
    /// bars animate when playback starts *after* the view already exists, e.g. tapping play
    /// on a DM song chip.
    @State private var bouncing = false

    private let durations: [Double] = [0.42, 0.55, 0.36, 0.48]
    private let lows: [CGFloat] = [0.35, 0.5, 0.3, 0.45]
    /// Tallest a bar ever gets — fixed so the bars are anchored to a baseline and animate
    /// their HEIGHT (not a scale transform that could render past the frame). The container
    /// is exactly this tall and bottom-aligned + clipped, so bars can never spill below the chip.
    private let maxBarHeight: CGFloat = 14

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(HavenTheme.brandHorizontal)
                    // Animate the bar's HEIGHT between its low and full height, anchored to the
                    // container's bottom edge — never a transform that escapes the frame.
                    // Clamped to the resting low when not animating — a bar never goes shorter.
                    .frame(width: 3, height: (animating && bouncing) ? maxBarHeight : maxBarHeight * lows[i])
                    // Oscillate (low↔full) while animating; keyed on the perpetual `bouncing` toggle.
                    .animation(
                        animating
                            ? .easeInOut(duration: durations[i]).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: bouncing
                    )
                    // When (un)muting, settle straight to the low with a finite ease — WITHOUT this,
                    // the in-flight repeatForever autoreverse springs the bar BELOW its low while
                    // stopping (the bug: muting drove the bars under the minimum).
                    .animation(.easeOut(duration: 0.2), value: animating)
            }
        }
        .frame(width: 22, height: maxBarHeight, alignment: .bottom)
        .clipped()   // hard-stop any overshoot at the chip's edge
        .onAppear { if animating { bouncing = true } }
        .onChange(of: animating) { _, now in bouncing = now }
    }
}
