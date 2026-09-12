import SwiftUI
import AVKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct ZoomTarget: Identifiable {
    let id = UUID()
    let refs: [String]
    let index: Int
    /// The post this media belongs to, and the song paired with it — so the viewer can KEEP that
    /// song playing instead of the feed going quiet the moment a photo opens full screen. Nil for
    /// media that has no post behind it (a DM attachment, a comment's photo).
    var postId: String? = nil
    var music: TrackRefFfi? = nil
    /// The author chose to mute this post's video. A muted clip never takes the stage from the song.
    var authorMutedVideo: Bool = false
}

/// Full-screen media viewer: swipe between a post's photos/videos, pinch + double-tap to
/// zoom, pan a zoomed photo, swipe down to dismiss.
///
/// Gesture model: at scale 1 a page takes no drag of its own, so the TabView pages horizontally
/// and the dismiss drag handles vertical swipes. When a page is zoomed it reports `zoomed = true`,
/// which (a) hands that page the drag, for panning, and (b) disables the dismiss drag, so panning
/// a zoomed image never paginates or dismisses. On iOS the zoom and the pan are a real
/// `UIScrollView` (see `ZoomableImage`) rather than SwiftUI gestures, because a SwiftUI drag
/// cannot win a touch from the paging scroll view it is sitting inside.
///
/// AUDIO. The viewer OWNS the post's audio while it is up, rather than silencing the feed behind it
/// (which is what every other cover does, and what this one used to do — opening a photo full screen
/// killed the song paired with it). The rules, in order:
///
///   * the post's song plays, and keeps playing as you page through photos;
///   * a video page whose clip carries its own audible track takes the stage — the song ducks and
///     comes back the moment you page off it, which is what "watch this bit, then keep listening"
///     needs to feel like;
///   * the music chip (bottom leading) is the song's own mute, and the speaker chip (bottom
///     trailing, where the feed's has always been) is the video's.
struct MediaZoomViewer: View {
    let target: ZoomTarget
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var dismissOffset: CGFloat = 0
    @State private var zoomed = false
    /// Drives the speaker chip below: this viewer is where a DM's video plays, and it had no sound
    /// control at all — the video opened at whatever the global choice was and there was no way to
    /// change your mind without leaving. The feed's video tiles have carried this chip all along.
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var audio = AudioCoordinator.shared

    /// The song's mute, and ONLY the song's — deliberately not the app-wide `silent`, which would
    /// also kill video audio and persist long after this viewer closed.
    @State private var musicMuted = false
    /// An explicit tap on the speaker chip, which overrides the automatic choice below. Nil until
    /// the viewer is tapped, so paging decides on its own until the user says otherwise.
    @State private var videoSoundChoice: Bool?
    /// Does this clip actually carry an audible track? Probed off-main per ref and cached: "is a
    /// video" and "makes sound" are different questions (a screen recording, a time-lapse, a clip
    /// muted before posting), and only a clip that CAN be heard should take the stage from a song.
    @State private var clipHasAudio: [String: Bool] = [:]

    init(target: ZoomTarget) {
        self.target = target
        _index = State(initialValue: target.index)
    }

    /// The post's song, if there is one to play. A CREDIT-ONLY track names the music already inside
    /// the video (see ShazamDetector) — attribution, not a second audio source. Super data saver
    /// never streams a song, here or in the feed.
    private var song: TrackRefFfi? {
        guard let m = target.music, !m.isCreditOnly, !settings.dataSaverActive else { return nil }
        return m
    }

    private var currentRef: String? { target.refs.indices.contains(index) ? target.refs[index] : nil }

    /// Is the page currently on screen a video? The speaker chip is meaningless over a photo.
    /// From the REF's prefix — a cheap string parse, not `item(_:)`, which decodes the poster frame.
    private var currentIsVideo: Bool {
        currentRef.flatMap { MediaKind(ref: $0) } == .video
    }

    /// The live state, handed to the rule table that decides all of this — see ViewerAudioPolicy,
    /// which is where the behaviour is written down and where it is tested.
    private var policy: ViewerAudioPolicy {
        ViewerAudioPolicy(
            hasSong: song != nil,
            musicMuted: musicMuted,
            onVideoPage: currentIsVideo,
            clipCarriesAudio: currentRef.flatMap { clipHasAudio[$0] } == true,
            authorMutedVideo: target.authorMutedVideo,
            explicitVideoChoice: videoSoundChoice,
            globalVideoSoundOn: settings.videoSoundOn,
            appSilent: settings.silent,
            callActive: CallManager.shared.callInProgress)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, Double(abs(dismissOffset)) / 600)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(target.refs.enumerated()), id: \.offset) { i, ref in
                    // paged: with several items a video keeps its scrub to the compact bottom
                    // strip so a horizontal swipe elsewhere PAGES the viewer (a full-area scrub
                    // used to eat every horizontal drag — you couldn't swipe off a video page).
                    ZoomablePage(ref: ref, zoomed: $zoomed, paged: target.refs.count > 1,
                                 soundAllowed: policy.videoAudible && i == index).tag(i)
                }
            }
            // showsIndex: FALSE, deliberately. The system's page dots sit in the bottom CENTRE,
            // underneath whatever chrome the viewer draws there — which is how the song chip ended
            // up printed across them. The viewer draws its own dots below, in the same stack as the
            // chips, where a collision is impossible by construction: one row, then the next.
            .havenPagedTabViewStyle(showsIndex: false)
            .offset(y: dismissOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { v in
                        guard !zoomed, abs(v.translation.height) > abs(v.translation.width) else { return }
                        dismissOffset = v.translation.height
                    }
                    .onEnded { v in
                        // Zoomed → this drag was never a dismiss, but it may have nudged the
                        // viewer before the pinch reported: put it back rather than leaving the
                        // page sitting a few points down the screen.
                        guard !zoomed else { withAnimation(.spring()) { dismissOffset = 0 }; return }
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
                HStack(alignment: .bottom) {
                    // The song paired with this post, named and mutable without leaving the viewer.
                    // Bottom LEADING so it never collides with the speaker chip on a video page —
                    // two separate sources, two separate controls, never the same corner.
                    if let song {
                        ViewerMusicChip(track: song, playing: policy.musicAudible,
                                        ducked: policy.musicDucked) {
                            musicMuted.toggle()
                        }
                        .padding()
                    }
                    Spacer(minLength: 0)
                    // Bottom-right speaker, same chip and same placement as a video in the feed, so the
                    // control is where muscle memory already looks for it.
                    if currentIsVideo {
                        Button {
                            let want = !policy.videoAudible
                            videoSoundChoice = want
                            HavenVideoSound.set(want)
                        } label: {
                            Image(systemName: policy.videoAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(GlassIconButtonStyle(tint: .white))
                        .padding()
                    }
                }
                // The page dots, BELOW the chips rather than behind them — the same dots the feed
                // carousel draws, so the two read as one control at two sizes.
                if target.refs.count > 1 {
                    PostCarouselDots(count: target.refs.count, currentPage: index)
                }
            }
        }
        .havenStatusBarHidden()
        // The viewer takes the post's audio over for as long as it is up — see the type comment. A
        // post with no playable song falls back to the old "quiet the feed behind me" behaviour,
        // which `enterMediaViewer` handles, so DM and comment media are untouched.
        .onAppear {
            audio.enterMediaViewer(postId: target.postId ?? "", track: target.music)
            probeCurrentClip()
            applyMusic()
        }
        .onChange(of: index) { _, _ in probeCurrentClip(); applyMusic() }
        .onChange(of: musicMuted) { _, _ in applyMusic() }
        .onChange(of: videoSoundChoice) { _, _ in applyMusic() }
        .onChange(of: settings.silent) { _, _ in applyMusic() }
        .onChange(of: settings.videoSoundOn) { _, _ in applyMusic() }
        .onChange(of: clipHasAudio) { _, _ in applyMusic() }
        .onDisappear {
            guard song != nil else { return }
            audio.exitMediaViewer(musicStaysMuted: musicMuted)
        }
    }

    /// Push the current decision at the coordinator. Cheap and idempotent — `resume`/`duck` both
    /// no-op when the player is already where we want it — so every signal above can just re-apply.
    private func applyMusic() {
        guard let song else { return }
        audio.setViewerMusicAudible(policy.musicAudible, track: song)
    }

    /// Ask the file whether this clip can be heard, once per ref. Off the main thread: it opens the
    /// asset and loads its track table, which is exactly the kind of work that stutters a page swipe.
    private func probeCurrentClip() {
        guard currentIsVideo, let ref = currentRef, clipHasAudio[ref] == nil,
              let url = MediaStore.shared.storagePath(for: ref) else { return }
        Task { @MainActor in
            let has = await SongSuggester.hasAudio(url)
            clipHasAudio[ref] = has
        }
    }
}

/// The song chip inside the full-screen viewer: what you're listening to, and the mute for it.
///
/// Not `NowPlayingPill` — that chip's tap is the app-wide mute (every post, every video, and it
/// persists), which is the wrong control to put under a thumb in a viewer. This one mutes THIS
/// song and nothing else.
private struct ViewerMusicChip: View {
    let track: TrackRefFfi
    var playing: Bool
    /// Quiet because a clip on this page is taking the stage, not because the user muted it — worth
    /// distinguishing, or the chip reads as "you muted this" when the video simply started talking.
    var ducked: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                EqualizerBars(animating: playing)
                Text("\(track.title) · \(track.artist)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Image(systemName: playing ? "speaker.wave.2.fill"
                                          : (ducked ? "speaker.wave.1.fill" : "speaker.slash.fill"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 240, alignment: .leading)
        // Deliberately the SAME format string NowPlayingPill uses ("%@ by %@. %@ sound"), so the
        // viewer's chip costs no new catalog entry and cannot drift from the one already translated.
        .accessibilityLabel("\(track.title) by \(track.artist). \(playing ? "Mute" : "Unmute") sound")
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

    @MainActor static func toggle() { set(!on) }

    /// Write the choice explicitly — the viewer decides what "the other state" is for itself, because
    /// its speaker can be showing an automatic duck rather than the global flag (see MediaZoomViewer).
    @MainActor static func set(_ want: Bool) {
        guard !CallManager.shared.callInProgress else { return }   // a call owns audio
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
    /// May THIS page's clip be heard? Decided by the viewer, which weighs the post's song against
    /// the clip's own audio — a page cannot answer that on its own, and reading the global toggle
    /// here (as it used to) is how a music post ended up playing both at once.
    var soundAllowed: Bool = false
    #if !os(iOS)
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    #endif

    var body: some View {
        Group {
            if let m = MediaStore.shared.item(ref) {
                if m.kind == .video, let url = m.videoURL {
                    // autoplays + loops, full system controls
                    CarouselVideo(url: url, inCarousel: paged, soundAllowed: soundAllowed)
                } else if let img = m.image {
                    // Photo — or a video whose file hasn't downloaded yet: show its still
                    // (with a play badge) instead of a blank page.
                    photo(img, stillOfVideo: m.kind == .video)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The badge over a video whose bytes have not landed yet. Deliberately untappable: the page
    /// under it owns every touch, and a badge that eats the double tap is a photo that won't zoom.
    private var playBadge: some View {
        Image(systemName: "play.circle.fill").font(.system(size: 56))
            .foregroundStyle(.white.opacity(0.9)).shadow(radius: 6)
            .allowsHitTesting(false)
    }

    #if os(iOS)
    /// iOS drives zoom and pan from a real `UIScrollView` — see `ZoomableImage` for why.
    private func photo(_ img: PlatformImage, stillOfVideo: Bool) -> some View {
        ZoomableImage(image: img, zoomed: $zoomed)
            .overlay { if stillOfVideo { playBadge } }
    }
    #else
    /// macOS keeps the SwiftUI gestures: there is no paging `TabView` under them to fight with
    /// (`havenPagedTabViewStyle` is a no-op off iOS), and no UIKit to reach for.
    private func photo(_ img: PlatformImage, stillOfVideo: Bool) -> some View {
        Image(platformImage: img).resizable().scaledToFit()
            .scaleEffect(scale).offset(offset)
            .overlay { if stillOfVideo { playBadge } }
            .gesture(zoomGesture)
            // Pan only when zoomed; masked to .subviews otherwise so the pager can page and the
            // dismiss drag can fire.
            .gesture(panGesture, including: scale > 1 ? .all : .subviews)
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
                    if scale > 1 { resetZoom() }
                    else { scale = 2.5; lastScale = 2.5; zoomed = true }
                }
            }
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
    #endif
}

#if os(iOS)
/// A zoomable photo page, backed by a real `UIScrollView`.
///
/// WHY UIKit, when the rest of this viewer is SwiftUI. The page lives inside a paged `TabView`,
/// which is a `UIPageViewController` and therefore a scroll view. A SwiftUI `DragGesture` on a
/// page inside it has to win the touch from that scroll view's own pan recogniser, and it does
/// not: the drag's `onChanged` updates arrive late and coalesced, so a zoomed photo did not
/// follow the finger — it sat still and then JUMPED to wherever the finger had got to by the
/// time you lifted it. No amount of gesture masking fixes that, because the competition is
/// between a SwiftUI gesture and a UIKit recogniser that never fails.
///
/// A nested scroll view is what UIKit already knows how to resolve — it is how every photo
/// browser on the platform is built. The inner view owns the pan the moment there is something
/// to pan, panning is clamped to the picture (the old code let you fling a photo clean off
/// screen), and it comes with momentum, rubber-banding and 120 Hz tracking for free.
///
/// At scale 1 the pan recogniser is DISABLED, so the page behaves exactly as it did before this
/// view existed: the pager gets horizontal swipes, the viewer's dismiss drag gets vertical ones.
/// Pinch and double-tap are separate recognisers and stay live throughout.
private struct ZoomableImage: UIViewRepresentable {
    let image: PlatformImage
    @Binding var zoomed: Bool

    func makeUIView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 5
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never   // the viewer draws edge to edge
        sv.backgroundColor = .clear
        sv.bouncesZoom = true
        sv.decelerationRate = .fast
        sv.panGestureRecognizer.isEnabled = false    // nothing to pan until it is zoomed
        sv.imageView.image = image
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)
        return sv
    }

    func updateUIView(_ sv: ZoomScrollView, context: Context) {
        let binding = $zoomed
        context.coordinator.zoomedChanged = { binding.wrappedValue = $0 }
        // One ref, one picture: the image is set at make time and only ever filled in here if the
        // decode had not landed yet. NEVER re-set on identity alone — `MediaStore.item` hands back
        // a fresh `UIImage` after a cache eviction, and re-fitting mid-pinch would eat the zoom.
        if sv.imageView.image == nil { sv.imageView.image = image; sv.fitImage() }
        // The viewer clears `zoomed` when the page changes; follow it back down so a page you
        // return to is un-zoomed, which is what the pager has always claimed.
        if !zoomed, sv.zoomScale > 1.01 { sv.setZoomScale(1, animated: false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var zoomedChanged: (Bool) -> Void = { _ in }
        private var reportedZoomed = false

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerContent()
            report(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            report(scrollView)
        }

        /// Double tap zooms to the point you tapped, or all the way back out.
        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? ZoomScrollView else { return }
            if sv.zoomScale > sv.minimumZoomScale {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let scale = min(2.5, sv.maximumZoomScale)
                let size = CGSize(width: sv.bounds.width / scale, height: sv.bounds.height / scale)
                let point = g.location(in: sv.imageView)
                sv.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
            }
        }

        /// Hand "this page is zoomed" up to the viewer, which uses it to hold off the dismiss drag,
        /// and switch the pan recogniser with it — at scale 1 the page must not take touches the
        /// pager and the dismiss drag are entitled to.
        private func report(_ sv: UIScrollView) {
            let nowZoomed = sv.zoomScale > 1.01
            guard nowZoomed != reportedZoomed else { return }
            reportedZoomed = nowZoomed
            // Only on the flip: disabling a recogniser CANCELS it, so writing this every zoom
            // notification would cut a pan short the moment the picture bounced back a hair.
            sv.panGestureRecognizer.isEnabled = nowZoomed
            // Off this turn of the run loop: this arrives from a live gesture inside a layout pass,
            // which is exactly what "Modifying state during view update" means.
            let notify = zoomedChanged
            DispatchQueue.main.async { notify(nowZoomed) }
        }
    }
}

/// The scroll view behind a zoomable photo: an image view sized to the picture's aspect-fit rect
/// (so panning is bounded by the PHOTO, not by the letterbox around it), kept centred whenever it
/// is smaller than the page.
private final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var fittedFor: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("ZoomScrollView is code-only") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-fit on a real size change only (rotation, a window resize) — never every scroll, or
        // a pan would be fighting the layout it is panning.
        if bounds.size != fittedFor, zoomScale == minimumZoomScale { fitImage() }
        centerContent()
    }

    /// Size the image view to the picture's aspect-fit rect inside the page.
    func fitImage() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        fittedFor = bounds.size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * fit, height: size.height * fit)
        zoomScale = minimumZoomScale
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerContent()
    }

    /// Centre the picture while it is smaller than the page — a scroll view pins its content to
    /// the top leading corner otherwise, which reads as the photo sliding into a corner as you
    /// zoom out of it.
    func centerContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }
}
#endif

/// Full-screen carousel video: native controls (scrub/play), autoplays + loops on appear,
/// pauses + tears down when you swipe to another page.
private struct CarouselVideo: View {
    let url: URL
    var inCarousel: Bool = false   // multi-item viewer: confine scrub to the strip so swipes page
    /// The viewer's verdict for this page — already gated by the app-wide mute, by call audio, and by
    /// whether a post song is holding the stage. This view does not second-guess it.
    var soundAllowed: Bool = false
    @State private var player: AVPlayer?
    @State private var looper: Any?

    /// The viewer re-renders this page whenever its verdict changes (an observed SettingsStore here
    /// used to be what got the `onChange` below reached — the parameter does that job now), so the
    /// running player follows a mid-video flip rather than reading the volume once at onAppear.
    private var soundOn: Bool { soundAllowed }

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
