import SwiftUI
import AVKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PostCard media
//
// The media half of PostCard: the carousel/grid, per-page rendering, and the video player
// lifecycle. Roughly 460 lines, lifted out of a file that had grown past 9,700.
//
// It lives in an EXTENSION IN ITS OWN FILE rather than a separate view. Three attempts to make it a
// standalone `PostMedia` view by script all died the same way — brace accounting inside the huge
// source file — and the members here genuinely share one pile of state (the PlayerBag cache,
// currentPage, mediaWidth, dataSaverPendingPlay). Splitting the FILE gets the maintainability win
// without restructuring view identity or the player lifecycle, which is the code that produced
// tonight's doubled-decode bug and is now behaving.
//
// `private` became internal on the members that moved: private is file-scoped in Swift, so an
// extension in another file cannot see it. Nothing outside this module can reach them.
//
// The remaining step, when someone has a clear run at it, is making this a real child view so a
// media page re-renders without the header, reactions and comments. That needs the shared @State to
// move with it — which is now a contained problem, because it is all in one file.

extension PostCard {

    var singleMediaMaxHeight: CGFloat { isPortraitPhone ? 680 : 460 }

    @MainActor final class PlayerBag {
        /// Identity of this CARD INSTANCE's cache. Two creations for one clip with DIFFERENT bag ids
        /// means two live PostCards; the same id would mean the cache itself is failing.
        let id = UUID().uuidString.prefix(4)
        var players: [String: AVPlayer] = [:]
        var observers: [String: NSObjectProtocol] = [:]   // loop observers, removed on teardown
    }

    var primaryVideoPlayer: AVPlayer? {
        let media = realMedia
        guard media.count == 1, let ref = media.first, isVideo(ref) else { return nil }
        return bag.players[ref]
    }

    var isSingleVideoPost: Bool {
        let media = realMedia
        return media.count == 1 && (media.first.map(isVideo) ?? false)
    }

    func isVideo(_ ref: String) -> Bool { MediaKind(ref: ref) == .video }

    var realMedia: [String] {
        MediaVariants.displayRefs(item.media).filter { SharedLocation.parse($0) == nil }
    }

    func pageHeight(_ aspect: CGFloat) -> CGFloat {
        guard mediaWidth > 0 else { return singleMediaMaxHeight }
        return min(singleMediaMaxHeight, mediaWidth / aspect)
    }

    func pageAspect(_ aspect: CGFloat) -> CGFloat {
        guard mediaWidth > 0 else { return aspect }
        return mediaWidth / pageHeight(aspect)
    }

    @ViewBuilder var mediaView: some View {
        VStack(spacing: 8) {
            if let geo = item.media.first(where: { SharedLocation.parse($0) != nil }),
               let loc = SharedLocation.parse(geo) {
                LocationMapView(lat: loc.lat, lon: loc.lon, label: loc.label)
            }
            let media = realMedia
            if media.count == 1, let ref = media.first {
                let video = isVideo(ref)
                ZStack(alignment: .bottomTrailing) {
                    // containerAspect == the media's own aspect ⇒ the inner per-page gate stays off; the
                    // outer backdrop below covers the whole page, so we don't blur the same thing twice.
                    mediaPage(ref, containerAspect: singleAspect(ref))
                    if video { muteButton(ref) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: pageHeight(singleAspect(ref)))
                .background { blurredBackdrop(ref) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                // Tap-to-zoom only for images. For a video, the player owns the single tap
                // (mute) / hold (pause) / drag (scrub); a zoom tap here would swallow them.
                .modifier(ConditionalTap(enabled: !video) { zoomTarget = ZoomTarget(refs: media, index: 0) })
            } else if (2...10).contains(media.count) {
                // Mixed aspects no longer force the grid — each page fits inside a shared shape and
                // its own blurred backdrop masks the difference, which beats a 2-photo masonry.
                // (A location-only post has NO real media: it must fall through to nothing.)
                mediaCarousel(media)
            } else if !media.isEmpty {
                masonry   // a big set → the staggered grid; tap any to zoom
            }
        }
        // Measure the card's content width — pageHeight/pageAspect need it to span the card. maxWidth
        // resolves from the PARENT's proposal, so reading it back here can't feed itself.
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear.preference(key: MediaWidthKey.self, value: g.size.width)
        })
        .onPreferenceChange(MediaWidthKey.self) { w in
            // Remember it for the NEXT card to be created, so it never has to lay out at zero width first.
            if w > 0 { mediaWidth = w; lastKnownMediaWidth = w }
        }
    }

    func allSameAspect(_ media: [String]) -> Bool {
        guard let a0 = media.first.map(singleAspect) else { return false }
        return media.allSatisfy { abs(singleAspect($0) - a0) < 0.06 }
    }

    func carouselAspect(_ media: [String]) -> CGFloat {
        guard let tallest = media.map(singleAspect).min() else { return 4.0 / 3.0 }
        if allSameAspect(media) { return tallest }
        return min(1.91, max(0.8, tallest))
    }

    @ViewBuilder func mediaCarousel(_ media: [String]) -> some View {
        let aspect = carouselAspect(media)
        // A ScrollView pager (NOT TabView) so it works on macOS too — a TabView renders its pages as
        // tab-bar items on macOS, dumping the dots into the nav toolbar. Custom dots overlay the carousel.
        // showsIndicators:false in the initializer (not just the .scrollIndicators modifier) — on macOS the
        // modifier alone doesn't suppress AppKit's legacy scroller, which showed an ugly bar under the dots.
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(media.enumerated()), id: \.offset) { i, ref in
                    ZStack(alignment: .bottomTrailing) {
                        // The player scrubs only from the bottom 1/3 (top 2/3 pages the carousel); a photo
                        // page has no scrub strip so the whole page pages.
                        mediaPage(ref, containerAspect: pageAspect(aspect), inCarousel: true,
                                  onScrubbing: { carouselScrubbing = $0 })
                        if isVideo(ref) { muteButton(ref) }
                    }
                    .containerRelativeFrame(.horizontal)   // each page == the carousel's width
                    .modifier(ConditionalTap(enabled: !isVideo(ref)) { zoomTarget = ZoomTarget(refs: media, index: i) })
                    .id(i)
                }
            }
            .scrollTargetLayout()
            #if os(macOS)
            .background(KillHorizontalScroller().frame(width: 0, height: 0))
            #endif
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding<Int?>(get: { currentPage }, set: { currentPage = $0 ?? currentPage }))
        // .never, not .hidden: on macOS .hidden still leaves AppKit's legacy scroller drawing a bar
        // across the bottom of the carousel.
        .scrollIndicators(.never)
        // Pages are containerRelativeFrame'd to this ScrollView — clip to it so a neighbouring page's
        // backdrop can't bleed past the edge mid-swipe.
        .clipped()
        .scrollDisabled(carouselScrubbing)   // while scrubbing a video, don't let a swipe page the carousel
        #if os(macOS)
        // macOS: a horizontal ScrollView only pages on a trackpad two-finger swipe — a plain MOUSE has no
        // horizontal scroll, so a click-drag paging gesture is the mouse equivalent. Simultaneous + onEnded
        // + thresholds so it never steals a tap-to-zoom, a vertical scroll, or a video scrub.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard !carouselScrubbing,
                          abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 40 else { return }
                    if value.translation.width < 0, currentPage < media.count - 1 {
                        withAnimation(.easeOut(duration: 0.22)) { currentPage += 1 }
                    } else if value.translation.width > 0, currentPage > 0 {
                        withAnimation(.easeOut(duration: 0.22)) { currentPage -= 1 }
                    }
                }
        )
        #endif
        // Full-width pages (NOT .aspectRatio(_, .fit), which shrank the whole carousel to a centre column
        // on a wide window) — each page letterboxes inside against its own blurred backdrop.
        .frame(maxWidth: .infinity)
        .frame(height: pageHeight(aspect))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            // Dots hide while scrubbing so the scrub bar doesn't collide with them.
            if media.count > 1 && !carouselScrubbing { carouselDots(media.count) }
        }
    }

    var masonry: some View {
        let rows = 2
        let rowHeight: CGFloat = 150
        let media = realMedia
        let rowItems = (0..<rows).map { ri in
            media.enumerated().filter { $0.offset % rows == ri }.map { $0.element }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<rows, id: \.self) { ri in
                    HStack(spacing: 6) {
                        ForEach(rowItems[ri], id: \.self) { ref in masonryTile(ref, height: rowHeight) }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: rowHeight * CGFloat(rows) + 6)
    }

    @ViewBuilder func mediaPage(_ ref: String, containerAspect: CGFloat,
                                        inCarousel: Bool = false,
                                        onScrubbing: @escaping (Bool) -> Void = { _ in }) -> some View {
        if isVideo(ref) {
            // No contextMenu for videos — the long-press is reserved for the player's
            // hold-to-pause. Save/Share live in the mute control's menu instead.
            mediaPageContent(ref, containerAspect: containerAspect, inCarousel: inCarousel, onScrubbing: onScrubbing)
        } else {
            mediaPageContent(ref, containerAspect: containerAspect)
                .contextMenu {
                    Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    if let url = shareURL(ref) {
                        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                    keepOnDeviceButton(ref)
                }
        }
    }

    @ViewBuilder func mediaPageContent(_ ref: String, containerAspect: CGFloat,
                                               inCarousel: Bool = false,
                                               onScrubbing: @escaping (Bool) -> Void = { _ in }) -> some View {
        // Decide from the REF + a cheap file check, never `item(ref)`: that decodes the bitmap / generates
        // the video poster ON THE MAIN THREAD on a cache miss, and this runs for every page of every media
        // post — a 3-video carousel paid three decodes per layout pass, which is the carousel/grid jitter.
        let dataSaver = SettingsStore.shared.superDataSaver
        let hasVideo = MediaStore.shared.hasLocalFile(ref)
        // Super data saver + video not yet downloaded: show the poster still (if we have one) with a
        // play affordance. Tapping play requests the video bytes and only then builds an AVPlayer.
        if dataSaver, MediaKind(ref: ref) == .video, !hasVideo {
            let poster = MediaVariants.poster(for: ref, in: item.media)
            let waiting = dataSaverPendingPlay.contains(ref)
            ZStack {
                if let poster, MediaStore.shared.hasLocalFile(poster) {
                    FeedImage(ref: poster, maxDimension: 1200, contentMode: .fit) { mediaLoadingPlaceholder(ref) }
                } else {
                    mediaLoadingPlaceholder(ref)
                }
                if waiting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                        .padding(18)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                } else {
                    Image(systemName: "play.circle.fill").font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.92)).shadow(radius: 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                // Explicit play → download the video (and only the video), then start once it lands.
                dataSaverPendingPlay.insert(ref)
                feed.requestMedia(ref, circleId: feed.activeCircleId)
            }
            .background { pageBackdrop(poster ?? ref, containerAspect: containerAspect) }
        } else if hasVideo {
            // NO AVPlayer FOR A CARD THAT IS NOT CENTERED.
            //
            // playVisibleVideo() already restricts PLAYBACK to the centered post, but creation was
            // never gated the same way: this branch built an AVPlayer for every visible video tile,
            // and a player holding an item holds a decode pipeline whether or not it is playing. A
            // scroll through a run of video posts therefore kept several decode sessions alive at
            // once — and teardownPlayers() only runs on .onDisappear, which a LazyVStack defers.
            //
            // Reported directly: "videos get warmer than just photo posts". That is what this
            // predicts, and it is invisible to a Time Profiler because hardware decode is not CPU
            // time — six CPU traces showed no hotspot and a Nominal thermal state throughout.
            //
            // An off-centre card shows its poster still instead, which is the same thing the super
            // data-saver branch above renders. Becoming centered flips isActive, the body
            // re-evaluates, and the player is built then — so playback is unchanged, it just stops
            // paying for clips nobody is watching.
            if MediaKind(ref: ref) == .video, !isActive {
                let poster = MediaVariants.poster(for: ref, in: item.media)
                ZStack {
                    if let poster, MediaStore.shared.hasLocalFile(poster) {
                        FeedImage(ref: poster, maxDimension: 1200, contentMode: .fit) { mediaLoadingPlaceholder(ref) }
                    } else {
                        mediaLoadingPlaceholder(ref)
                    }
                    Image(systemName: "play.circle.fill").font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.85)).shadow(radius: 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { pageBackdrop(poster ?? ref, containerAspect: containerAspect) }
            } else if MediaKind(ref: ref) == .video, let url = MediaStore.shared.storagePath(for: ref) {
                // Data saver with local video: don't autoplay until the user asked (pending play
                // from a poster tap, or a first tap on an already-local clip). Tap then toggles mute.
                let player = playerFor(ref, url)
                GestureVideoPlayer(player: player,
                                   onTap: { dataSaverVideoTap(ref, player) },
                                   onDoubleTap: { heartIt() },
                                   inCarousel: inCarousel,
                                   onScrubbing: onScrubbing)
                    .background { pageBackdrop(ref, containerAspect: containerAspect) }
                    .onAppear {
                        if dataSaver, dataSaverPendingPlay.contains(ref) {
                            startDataSaverPlayback(ref, player)
                        }
                        // HAND THE COORDINATOR THIS PLAYER.
                        //
                        // Players are now built when a card reaches the centre, and centering can run
                        // BEFORE the body builds one — playVisibleVideo passes `primaryVideoPlayer`,
                        // which reads the players dict and is nil at that moment. The coordinator then
                        // holds nil (or a torn-down player) and its fades act on nothing, so the
                        // speaker toggled state while the clip stayed silent. This fires immediately
                        // after creation, which is the first moment the real object exists.
                        if audio.activePostId == item.id {
                            audio.start(postId: item.id, track: item.music, video: player,
                                        muteVideo: item.muteVideo)
                        }
                    }
            } else if MediaKind(ref: ref) == .file {
                fileAttachmentPage(ref)
            } else {
                // Non-video → a ~1200px thumbnail (not the 2560px original) via the self-loading `FeedImage`:
                // it decodes OFF the main thread and swaps into only itself, so a fast flick never hitches on
                // a main-thread decode AND a finished decode never triggers a feed-wide refresh (the flash of
                // already-shown media + re-rasterized blurs). Zoom uses full-res. Shows the whole image (fit).
                FeedImage(ref: ref, maxDimension: 1200, contentMode: .fit) { mediaLoadingPlaceholder(ref) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { pageBackdrop(ref, containerAspect: containerAspect) }
            }
        } else {
            // Referenced but not here yet — it's still coming from the sender / mailbox.
            mediaLoadingPlaceholder(ref)
        }
    }

    func dataSaverVideoTap(_ ref: String, _ player: AVPlayer) {
        if SettingsStore.shared.superDataSaver, player.rate == 0 {
            startDataSaverPlayback(ref, player)
            return
        }
        togglePostMute()
    }

    func startDataSaverPlayback(_ ref: String, _ player: AVPlayer) {
        dataSaverPendingPlay.remove(ref)
        if audio.activePostId != item.id {
            audio.start(postId: item.id, track: nil, video: player, muteVideo: item.muteVideo, immediateMusic: false)
        }
        #if os(iOS)
        ensureHavenPlaybackSession()
        #endif
        player.seek(to: .zero)
        player.play()
    }

    @ViewBuilder func blurredBackdrop(_ ref: String) -> some View {
        BlurredMediaBackdrop(ref: ref)
    }

    @ViewBuilder func pageBackdrop(_ ref: String, containerAspect: CGFloat) -> some View {
        blurredBackdrop(ref)
    }

    func playerFor(_ ref: String, _ url: URL) -> AVPlayer {
        if let p = bag.players[ref] { return p }
        let p = AVPlayer(url: url)
        // VOLUME FROM THE SHARED STATE, not a hardcoded 0.
        //
        // This was `p.volume = 0`, which was survivable only while players were built early and
        // lived: the coordinator's fade would bring the volume up later. Now that a player is built
        // when its card reaches the centre, a hardcoded 0 means the viewer's existing sound choice is
        // applied to a player that no longer exists — the speaker read "unmuted" while the clip
        // played silent, and toggling wrote to state nothing was listening to. Exactly the report:
        // "shows not muted but they are playing muted and unmuting them does nothing".
        //
        // AudioCoordinator.videoUnmuted is the same published value the indicator draws, so the
        // player and the icon now start from one source of truth. The full-screen viewer already
        // did this (`p.volume = soundOn ? 1 : 0`); the feed did not.
        // START SILENT unless THIS post is the active audio source and may be heard right now.
        //
        // I changed this from a hardcoded 0 earlier tonight so a rebuilt player would not lose the
        // viewer's sound choice — but I used the GLOBAL videoUnmuted flag, which belongs to whichever
        // post is currently the audio source. Any other post's player could therefore be built at
        // full volume, including one built while the app was in the BACKGROUND: reported as "the post
        // video audio is playing from the background on its own".
        //
        // The coordinator owns this decision (one audible post at a time, never while backgrounded,
        // silenced, or in a call), so ask it rather than reading one of its flags in isolation.
        p.volume = AudioCoordinator.shared.videoShouldBeAudible(forPost: item.id) ? 1 : 0
        p.actionAtItemEnd = .none
        // DIAGNOSTIC: every player creation, with the post and ref it belongs to. Audio is doubling
        // with only ONE visible video, so something builds a second AVPlayer for the same clip; this
        // says exactly what and how many. Counting creations beats reasoning about the view tree.
        PlayerCensus.note(ref: ref, postId: item.id, container: feedContainer, bag: String(bag.id))
        // When the clip ends, loop it (muted) and — if we're still on this post —
        // bring the song back, so the music never stays paused under an idle video.
        let postId = item.id
        // CRITICAL: capture the player WEAKLY. addObserver(forName:) returns a token whose closure is
        // retained by NotificationCenter until removed — a strong `p` capture meant every AVPlayer (and
        // its video decode buffers) lived forever even after the card scrolled away. That was the runaway
        // leak (memory climbed into the tens of GB). We also store the token and remove it on teardown.
        let token = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: p.currentItem, queue: .main) { [weak p] _ in
            guard let p else { return }
            MainActor.assumeIsolated {   // observer is delivered on .main, so this is genuinely isolated
                p.seek(to: .zero)
                if AudioCoordinator.shared.centeredPostId == postId {
                    p.play()
                    AudioCoordinator.shared.videoFinished()
                }
            }
        }
        // CACHE SYNCHRONOUSLY — this is the doubling bug.
        //
        // These two writes were inside `DispatchQueue.main.async`, so playerFor RETURNED BEFORE the
        // cache was populated. Any further evaluation in the same pass hit `bag.players[ref] == nil`,
        // missed, and built a SECOND AVPlayer for the same clip. Instrumented runs logged `player #1`
        // and `player #2` for every video with an IDENTICAL bag id — one card, one cache, two
        // players — which is the audio playing over itself slightly offset ("static sounding"), the
        // mute toggle reaching only the player the coordinator knew about, and 2x hardware decode on
        // every video in the feed. That last part is heat with no CPU hotspot, and heat that survives
        // airplane mode.
        //
        // The deferral was needed when these were @State dictionaries: writing them mid-body is a
        // "Modifying state during view update" violation. `bag` is a reference type now, so mutating
        // its contents is not a state write and can happen immediately — which is the whole point of
        // having moved it.
        //
        // playVisibleVideo() STAYS deferred: it touches AudioCoordinator and @State, so it must not
        // run inside a view evaluation.
        bag.players[ref] = p
        bag.observers[ref] = token
        // Tell the coordinator which player belongs to this post, so anything that activates the
        // post's audio (tap-to-mute, the speaker chip) no longer has to carry a player reference.
        AudioCoordinator.shared.registerVideo(p, for: item.id)
        DispatchQueue.main.async {
            if isActive { playVisibleVideo() }
        }
        return p
    }

    func syncPlayback() {
        if isActive {
            // Super data saver: no autoplay of attached music either — only the poster still loads.
            let track = SettingsStore.shared.superDataSaver ? nil : item.music
            audio.start(postId: item.id, track: track, video: nil, muteVideo: item.muteVideo)
            if !SettingsStore.shared.superDataSaver {
                audio.ensureMusicPlaying()   // resume the song if a video had paused it
            }
            playVisibleVideo()
        } else {
            pauseVideos()
        }
    }

    func pauseVideos() { bag.players.values.forEach { $0.pause() } }

    func teardownPlayers() {
        for (_, token) in bag.observers { NotificationCenter.default.removeObserver(token) }
        for (_, p) in bag.players { p.pause(); p.replaceCurrentItem(with: nil) }
        bag.observers.removeAll()
        bag.players.removeAll()
        AudioCoordinator.shared.registerVideo(nil, for: item.id)
    }

    func playVisibleVideo() {
        guard isActive else { return }
        // Index against display refs (not raw item.media) so carousel page maps to the video slide.
        let media = realMedia
        let visibleRef: String? = media.isEmpty
            ? nil
            : media[min(max(currentPage, 0), media.count - 1)]
        // Super data saver: never autoplay *unless* the user explicitly tapped play on this ref
        // (poster → download → pending). Keep a clip they already started; pause everything else.
        if SettingsStore.shared.superDataSaver {
            for (ref, player) in bag.players {
                let isVisible = ref == visibleRef
                if isVisible, dataSaverPendingPlay.contains(ref) {
                    startDataSaverPlayback(ref, player)
                } else if isVisible, player.rate > 0 {
                    // User-started — leave playing.
                } else if !isVisible {
                    player.pause()
                }
            }
            return
        }
        #if os(iOS)
        // A post's music plays on the system music player; without mixing, that music takes the audio
        // session and INTERRUPTS the video's AVPlayer, so the (muted) video just froze. Mix so the video
        // plays alongside the music. Safe when the video is unmuted too (it simply mixes its own audio).
        // NB: setCategory/setActive are synchronous and can block the main thread for tens of ms — doing
        // that every time a video scrolled to centre was the scroll "stick then continue". Configure the
        // session once, off the main thread, and skip entirely when it's already set up.
        if let visibleRef, isVideo(visibleRef) { ensureHavenPlaybackSession() }
        #endif
        for (ref, player) in bag.players {
            if ref == visibleRef && isVideo(ref) {
                player.seek(to: .zero)
                player.play()
            } else {
                player.pause()
            }
        }
    }
}
