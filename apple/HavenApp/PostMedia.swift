import SwiftUI
import AVKit

struct ZoomTarget: Identifiable {
    let id = UUID()
    let refs: [String]
    let index: Int
}

/// Full-screen media viewer: swipe between a post's photos/videos, pinch + double-tap to
/// zoom, pan a zoomed photo, swipe down to dismiss.
///
/// Gesture model: at scale 1 the per-page pan gesture is masked off (`.subviews`), so the
/// TabView pages horizontally and the dismiss drag handles vertical swipes. When a page is
/// zoomed it reports `zoomed = true`, which (a) activates that page's pan and (b) disables
/// the dismiss drag, so panning a zoomed image never paginates or dismisses.
struct MediaZoomViewer: View {
    let refs: [String]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var dismissOffset: CGFloat = 0
    @State private var zoomed = false
    /// Drives the speaker chip below: this viewer is where a DM's video plays, and it had no sound
    /// control at all — the video opened at whatever the global choice was and there was no way to
    /// change your mind without leaving. The feed's video tiles have carried this chip all along.
    @ObservedObject private var settings = SettingsStore.shared

    /// Is the page currently on screen a video? The chip is meaningless over a photo.
    private var currentIsVideo: Bool {
        guard refs.indices.contains(index) else { return false }
        return MediaStore.shared.item(refs[index])?.kind == .video
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, Double(abs(dismissOffset)) / 600)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                    // paged: with several items a video keeps its scrub to the compact bottom
                    // strip so a horizontal swipe elsewhere PAGES the viewer (a full-area scrub
                    // used to eat every horizontal drag — you couldn't swipe off a video page).
                    ZoomablePage(ref: ref, zoomed: $zoomed, paged: refs.count > 1).tag(i)
                }
            }
            .havenPagedTabViewStyle(showsIndex: refs.count > 1)
            .offset(y: dismissOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { v in
                        guard !zoomed, abs(v.translation.height) > abs(v.translation.width) else { return }
                        dismissOffset = v.translation.height
                    }
                    .onEnded { v in
                        guard !zoomed else { return }
                        if abs(v.translation.height) > 140 && abs(v.translation.height) > abs(v.translation.width) { dismiss() }
                        else { withAnimation(.spring()) { dismissOffset = 0 } }
                    }
            )
            .onChange(of: index) { _, _ in zoomed = false }   // each page starts un-zoomed

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        // ONE clean circular patch: a SQUARE frame clipped to a circle. A padded
                        // (non-square) frame made the Circle read as an oval/rounded-rect slab.
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.4), in: Circle())
                            .contentShape(Circle())
                    }
                    .padding()
                }
                Spacer()
                // Bottom-right speaker, same chip and same placement as a video in the feed, so the
                // control is where muscle memory already looks for it.
                if currentIsVideo {
                    HStack {
                        Spacer()
                        Button { HavenVideoSound.toggle() } label: {
                            Image(systemName: HavenVideoSound.on ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(GlassIconButtonStyle(tint: .white))
                        .padding()
                    }
                }
            }
        }
        .havenStatusBarHidden()
    }
}

/// The viewer's video-sound switch, in one place so the chip and the player can never disagree.
///
/// Deliberately the SAME persisted choice the feed's speaker writes (`videoSoundOn`) rather than a
/// viewer-local flag: "video sound is on" is one preference about this app, and having a DM's viewer
/// keep a second opinion is how you end up unmuting the same video twice.
enum HavenVideoSound {
    /// Sound is actually audible only if the app isn't silenced and no call owns the stage — the
    /// same conditions `AudioCoordinator.start` applies inline.
    @MainActor static var on: Bool {
        !SettingsStore.shared.silent && SettingsStore.shared.videoSoundOn && !CallManager.shared.callInProgress
    }

    @MainActor static func toggle() {
        guard !CallManager.shared.callInProgress else { return }   // a call owns audio
        let want = !on
        // Tapping the speaker IS the intent to hear it, so lift the app-wide mute rather than
        // no-op'ing — macOS launches silent by default, which would otherwise make this a dead
        // button on the platform that just grew the control. (Mirrors AudioCoordinator.toggleVideoAudio.)
        if want, SettingsStore.shared.silent { SettingsStore.shared.silent = false }
        SettingsStore.shared.videoSoundOn = want
    }
}

/// One pinch/drag-zoomable photo or (muted-tap-to-play) video. Reports its zoom state up so
/// the pager can decide whether to page/dismiss or let this page pan.
private struct ZoomablePage: View {
    let ref: String
    @Binding var zoomed: Bool
    var paged: Bool = false   // part of a multi-item viewer → video scrub confined to the bottom strip
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Group {
            if let m = MediaStore.shared.item(ref) {
                if m.kind == .video, let url = m.videoURL {
                    CarouselVideo(url: url, inCarousel: paged)   // autoplays + loops, full system controls
                } else if let img = m.image {
                    // Photo — or a video whose file hasn't downloaded yet: show its still
                    // (with a play badge) instead of a blank page.
                    Image(platformImage: img).resizable().scaledToFit()
                        .scaleEffect(scale).offset(offset)
                        .overlay {
                            if m.kind == .video {
                                Image(systemName: "play.circle.fill").font(.system(size: 56))
                                    .foregroundStyle(.white.opacity(0.9)).shadow(radius: 6)
                            }
                        }
                        .gesture(zoomGesture)
                        // Pan only when zoomed; masked to .subviews otherwise so the TabView
                        // can page and the dismiss drag can fire.
                        .gesture(panGesture, including: scale > 1 ? .all : .subviews)
                        .onTapGesture(count: 2) {
                            withAnimation(.spring()) {
                                if scale > 1 { resetZoom() }
                                else { scale = 2.5; lastScale = 2.5; zoomed = true }
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resetZoom() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero; zoomed = false
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in scale = max(1, min(5, lastScale * v)); zoomed = scale > 1.01 }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { withAnimation { resetZoom() } } else { zoomed = true }
            }
    }
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in if scale > 1 { offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) } }
            .onEnded { _ in lastOffset = offset }
    }
}

/// Full-screen carousel video: native controls (scrub/play), autoplays + loops on appear,
/// pauses + tears down when you swipe to another page.
private struct CarouselVideo: View {
    let url: URL
    var inCarousel: Bool = false   // multi-item viewer: confine scrub to the strip so swipes page
    @State private var player: AVPlayer?
    @State private var looper: Any?
    /// So a flip of the viewer's speaker chip re-renders this view and the `onChange` below is
    /// actually reached. Without it the volume was read once, at `onAppear`, and a toggle mid-video
    /// changed the icon and nothing else.
    @ObservedObject private var settings = SettingsStore.shared

    /// The viewer's global video-sound choice, gated by the app-wide mute and by call audio
    /// (a call owns the stage) — the same conditions AudioCoordinator.start applies inline.
    private var soundOn: Bool { HavenVideoSound.on }

    var body: some View {
        // The SAME custom gesture player as the inline feed (hold-to-pause, drag-to-scrub, clean chrome)
        // rather than AVKit's VideoPlayer with its stock airplay/volume/scrubber bar.
        Group {
            if let player { GestureVideoPlayer(player: player, inCarousel: inCarousel) } else { Color.black }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                let p = AVPlayer(url: url)
                // Start SILENT unless the viewer has actually asked for video sound — opening a video
                // full-screen used to blast it at full volume regardless of the app's mute switch, the
                // global video-sound choice, or a live call. Same rule as the inline feed player.
                p.volume = soundOn ? 1 : 0
                looper = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak p] _ in
                    p?.seek(to: .zero); p?.play()
                }
                player = p
                p.play()
            }
            // Live, not just at open: the speaker chip over this page writes the shared choice and
            // the running player follows it.
            .onChange(of: soundOn) { _, on in player?.volume = on ? 1 : 0 }
            .onDisappear {
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                if let o = looper { NotificationCenter.default.removeObserver(o); looper = nil }
                player = nil
            }
    }
}
