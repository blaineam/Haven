import SwiftUI
import AVKit

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
/// Gesture model: at scale 1 the per-page pan gesture is masked off (`.subviews`), so the
/// TabView pages horizontally and the dismiss drag handles vertical swipes. When a page is
/// zoomed it reports `zoomed = true`, which (a) activates that page's pan and (b) disables
/// the dismiss drag, so panning a zoomed image never paginates or dismisses.
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
            .havenPagedTabViewStyle(showsIndex: target.refs.count > 1)
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
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Group {
            if let m = MediaStore.shared.item(ref) {
                if m.kind == .video, let url = m.videoURL {
                    // autoplays + loops, full system controls
                    CarouselVideo(url: url, inCarousel: paged, soundAllowed: soundAllowed)
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
