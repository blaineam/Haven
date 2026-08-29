import SwiftUI
import AVKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PostMediaView
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

struct PostMediaView: View {
    let item: FeedItemFfi
    let onHeart: () -> Void
    let onToggleMute: () -> Void
    @Binding var zoomTarget: ZoomTarget?

    @ObservedObject var audio = AudioCoordinator.shared
    @Environment(\.havenFeedContainer) var feedContainer
    var feed: FeedStore { FeedStore.shared }

    /// Am I the post the feed reported as centred? Computed HERE, from the coordinator this media
    /// leaf ALREADY observes to start/stop its player. PostCard used to observe the coordinator
    /// solely to compute this and hand it down — which turned every scroll (a new post crossing
    /// centre, ~once every couple of seconds) into a re-evaluation of its entire ~1,500-line body,
    /// dropping the frame and making the swipe feel like it stuck. Owning the check here costs
    /// nothing extra (this view re-renders on the same signal anyway) and takes the card out of the
    /// scroll-invalidation path entirely.
    ///
    /// The centre must have been reported BY THIS CARD'S OWN FEED. Without the container guard a
    /// post living in two live containers (your own video is in both the circle feed and your
    /// profile) had both copies claim to be active, and both built an AVPlayer for the same clip —
    /// two decode sessions playing over each other, only one of them known to the coordinator.
    var isActive: Bool { audio.centeredPostId == item.id && audio.centeredContainer == feedContainer }

    // The media's own state, finally living with the media. On PostCard these forced the WHOLE card
    // to re-evaluate: paging a carousel, a width measurement landing, a data-saver tap.
    @State var bag = PlayerBag()
    @State var currentPage = 0
    @State var carouselScrubbing = false
    @State var mediaWidth: CGFloat = lastKnownMediaWidth
    @State var dataSaverPendingPlay: Set<String> = []

    var body: some View {
        mediaView
            .onAppear { syncPlayback() }
            .onDisappear { teardownPlayers() }
            .onChange(of: audio.centeredPostId) { syncPlayback() }
            .onChange(of: currentPage) { if isActive { playVisibleVideo() } }
    }

    // Small pieces that are already their own types — forwarded so the moved code reads unchanged.
    func keepOnDeviceButton(_ ref: String) -> some View { KeepOnDeviceButton(ref: ref) }
    func mediaLoadingPlaceholder(_ ref: String) -> some View { PostMediaPlaceholder(item: item, ref: ref) }
    func carouselDots(_ count: Int) -> some View { PostCarouselDots(count: count, currentPage: currentPage) }
    func fileAttachmentPage(_ ref: String) -> some View { PostFileAttachmentPage(ref: ref) }
    func muteButton(_ ref: String) -> some View { PostMuteButton(item: item, ref: ref) }
    func masonryTile(_ ref: String, height: CGFloat) -> some View {
        PostMasonryTile(item: item, media: realMedia, ref: ref, height: height, zoomTarget: $zoomTarget)
    }
    func singleAspect(_ ref: String) -> CGFloat { postSingleAspect(ref, in: item.media) }
    func letterboxes(_ r: String, in a: CGFloat) -> Bool { postLetterboxes(r, in: a) }
    func shareURL(_ ref: String) -> URL? { postShareURL(ref) }
    func heartIt() { onHeart() }
    func togglePostMute() { onToggleMute() }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var isPortraitPhone: Bool { hSizeClass == .compact }
    #else
    var isPortraitPhone: Bool { false }
    #endif


    /// How tall a full-width media page may get, expressed as the page's MINIMUM ASPECT rather than
    /// a point height — which is the whole point of it.
    ///
    /// The cap used to be a flat 460pt on anything that wasn't a portrait phone, and an absolute
    /// height does not survive a wide window. At the ~820pt of card width a normal Mac window gives,
    /// a 460pt page is 1.78:1 — so EVERY clip narrower than that (3:2, 4:3, 1:1) was fitted by its
    /// HEIGHT and drew blurred pillars either side while there was width going spare. A 4:3 video
    /// rendered 613pt wide inside an 820pt page: 103pt of blur down each edge, for nothing. The
    /// phone never showed it because 360/1.33 = 270pt never reaches ITS 680 cap, so the defect
    /// scaled in with the window and read as "sometimes".
    ///
    /// As an aspect the rule is width-independent: the page is as tall as the media needs until it
    /// would be taller than this, so only genuinely tall media letterboxes. 4:3 → fills the width.
    var minPageAspect: CGFloat { isPortraitPhone ? 0.8 : 1.1 }

    /// A hard ceiling on top of `minPageAspect`, because the aspect rule alone scales without bound:
    /// on a maximised 1600pt window a 4:3 clip would ask for a 1200pt page and one post would fill
    /// more than a screen. Generous enough that a normal window never reaches it.
    var singleMediaMaxHeight: CGFloat { isPortraitPhone ? 680 : 820 }

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

    /// THE PAGE TAKES THE MEDIA'S OWN SHAPE, capped in height. Nothing else.
    ///
    /// This used to clamp with `max(aspect, minPageAspect)`: any page that wanted to be taller than
    /// 0.8 was shortened to 0.8 — and media cannot fill a page shaped differently from itself, so it
    /// pillarboxed instead. Measured on a real 5-photo carousel of 9:16 shots:
    ///
    ///     carousel: 5 items aspects=[0.56 …] chosen=0.56 uniform=yes width=372 pageH=465
    ///
    /// 372/0.56 is 664, but the clamp forced 465, so each photo drew 260pt wide inside a 372pt card
    /// with 56pt of blur down each side — a third of the card's width spent blurring a photo it could
    /// have been showing. Portrait is the common shape for phone photos and for everything an
    /// Instagram archive brings over, so this was most of a feed.
    ///
    /// `singleMediaMaxHeight` is the real bound and always was: at 372pt wide a 9:16 page is 664pt,
    /// inside the 680 cap, so the clamp was not protecting against a post that fills the screen.
    /// Only genuinely extreme media letterboxes now, which is the case the cap exists for.
    func pageHeight(_ aspect: CGFloat) -> CGFloat {
        guard mediaWidth > 0, aspect > 0 else { return singleMediaMaxHeight }
        return min(singleMediaMaxHeight, mediaWidth / aspect)
    }

    func pageAspect(_ aspect: CGFloat) -> CGFloat {
        guard mediaWidth > 0 else { return aspect }
        return mediaWidth / pageHeight(aspect)
    }

    /// DEBUG: why a post is silent. There are four different reasons a video plays without sound and
    /// they are indistinguishable from the outside — the author muted it, a song owns the post's
    /// audio, the app is globally silenced, or the file genuinely has no audio track. Guessing which
    /// costs a build; asking costs a line.
    @ViewBuilder func audioProbe(_ refs: [String]) -> some View {
        #if DEBUG
        Color.clear.onAppear {
            let vids = refs.filter { isVideo($0) }
            guard !vids.isEmpty else { return }
            let tracks = vids.map { ref -> String in
                guard let url = MediaStore.shared.storagePath(for: ref) else { return "no-file" }
                let n = AVURLAsset(url: url).tracks(withMediaType: .audio).count
                return "\(ref.prefix(10))=\(n)track"
            }.joined(separator: " ")
            HavenLog.sync("post-audio: muteVideo=\(item.muteVideo) song=\(item.music != nil) "
                + "silent=\(SettingsStore.shared.silent) [\(tracks)]")
        }
        #else
        EmptyView()
        #endif
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
        .background(audioProbe(realMedia))
        .onPreferenceChange(MediaWidthKey.self) { w in
            // Remember it for the NEXT card to be created, so it never has to lay out at zero width first.
            if w > 0 { mediaWidth = w; lastKnownMediaWidth = w }
        }
    }

    func allSameAspect(_ media: [String]) -> Bool {
        guard let a0 = media.first.map(singleAspect) else { return false }
        return media.allSatisfy { abs(singleAspect($0) - a0) < 0.06 }
    }

    /// The shape a carousel's pages take: the MEDIAN of what it holds, not a clamp around the
    /// tallest.
    ///
    /// Taking the tallest and clamping to 0.8 gave a page that fitted NOTHING. Measured on a real
    /// post — four 9:16 clips and one genuinely landscape one:
    ///
    ///     carousel: 5 items aspects=[0.56 0.56 0.56 0.56 1.78] chosen=0.80 pageH=465
    ///
    /// 0.80 is not 0.56 and it is not 1.78, so all five letterboxed: the four portrait clips drew as
    /// slivers and the landscape one sat in a band, with blur everywhere. One odd item out of five
    /// was dictating the shape of the other four.
    ///
    /// The median is the shape most pages actually want. Four of five fill the page edge to edge and
    /// the outlier letterboxes over its own blurred copy — which is exactly what that backdrop is
    /// for, and what a single-media post already does. A uniform set still keeps its exact aspect.
    func carouselAspect(_ media: [String]) -> CGFloat {
        let aspects = media.map(singleAspect).filter { $0 > 0 }.sorted()
        guard !aspects.isEmpty else { return 4.0 / 3.0 }
        if allSameAspect(media) { return aspects[0] }
        return aspects[aspects.count / 2]
    }

    /// DEBUG: what shape the carousel chose and why. Every "sizing is wrong" report on this view has
    /// been a disagreement between the PAGE's shape and the MEDIA's, and guessing which of the two is
    /// wrong has cost more round trips than measuring it.
    @ViewBuilder func carouselProbe(_ media: [String], aspect: CGFloat) -> some View {
        #if DEBUG
        Color.clear.onAppear {
            let each = media.map { String(format: "%.2f", singleAspect($0)) }.joined(separator: " ")
            HavenLog.sync(String(format: "carousel: %d items aspects=[%@] chosen=%.2f uniform=%@ "
                                 + "width=%.0f pageH=%.0f",
                                 media.count, each, aspect,
                                 allSameAspect(media) ? "yes" : "no",
                                 mediaWidth, pageHeight(aspect)))
        }
        #else
        EmptyView()
        #endif
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
        .background(carouselProbe(media, aspect: aspect))
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
        let dataSaver = SettingsStore.shared.dataSaverActive
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
                // Match the photo path: fit the media into the page, blur fills the rest.
                //
                // Photos use Image `.fit` so letterbox strips stay transparent and the blurred
                // poster wash shows through. A full-bleed AVPlayerLayer does NOT — even with a
                // clear layer background, CoreAnimation still paints opaque black into the
                // pillar/letterbox regions for the whole loop (1.4.3 tried clear + ZStack and
                // failed on device). So size the player to the video's own aspect; the layer
                // never letterboxes, and the wash lives in the strips the same way photos do.
                let poster = MediaVariants.poster(for: ref, in: item.media)
                let videoAspect = singleAspect(ref)
                GestureVideoPlayer(player: player,
                                   onTap: { dataSaverVideoTap(ref, player) },
                                   onDoubleTap: { heartIt() },
                                   inCarousel: inCarousel,
                                   onScrubbing: onScrubbing)
                    .aspectRatio(videoAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { pageBackdrop(poster ?? ref, containerAspect: containerAspect) }
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
            //
            // The same page contract every branch above keeps, and the one this branch was missing:
            // the PAGE proposes the size and the content never dictates it. Without the frame, an
            // oversized placeholder sized the page instead of the other way round — see the fill/fit
            // note in `MissingMediaPlaceholder`, which is the defect this pairs with. Belt and
            // braces: either half alone contains it, and a page that can be resized by its contents
            // is a card that can break the feed's width.
            //
            // The backdrop comes from the THUMB companion, not the parent ref: the parent's bytes
            // are by definition not on disk here, so blurring it would find nothing and the strip
            // either side of a fitted thumb would be the card's flat surface. The thumb is what the
            // placeholder is already drawing.
            // Preview first, then thumb — the same order the placeholder itself uses, so the
            // blurred backdrop and the fitted image on top are always the same picture.
            let waitingThumb = MediaVariants.preview(for: ref, in: item.media)
                ?? MediaVariants.thumb(for: ref, in: item.media)
            mediaLoadingPlaceholder(ref)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { pageBackdrop(waitingThumb ?? ref, containerAspect: containerAspect) }
        }
    }

    func dataSaverVideoTap(_ ref: String, _ player: AVPlayer) {
        if SettingsStore.shared.dataSaverActive, player.rate == 0 {
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
                // Ask the coordinator, which folds in whether the app is even in the foreground.
                // `centeredPostId == postId` alone says where the feed is scrolled, not whether
                // anyone can see it — and backgrounding does not move the centred post. A video
                // centred when the user locked their phone therefore looped forever, audibly, with
                // the app fully backgrounded.
                if AudioCoordinator.shared.videoMayLoop(forPost: postId) {
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
            let track = SettingsStore.shared.dataSaverActive ? nil : item.music
            audio.start(postId: item.id, track: track, video: nil, muteVideo: item.muteVideo)
            if !SettingsStore.shared.dataSaverActive {
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
        if SettingsStore.shared.dataSaverActive {
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
        // HAND THE COORDINATOR THE PLAYER YOU ARE ACTUALLY LOOKING AT.
        //
        // `videoByPost` is ONE slot per post, and a carousel builds a player per page — every
        // `playerFor` overwrites the last, so the coordinator ended up holding whichever page was
        // built most recently rather than the visible one. Tapping to unmute then raised the volume
        // of an off-screen, paused player while the clip on screen stayed at zero: a post whose files
        // all carry audio, playing silent, with the speaker reading unmuted.
        //
        //   post-audio: muteVideo=false song=false silent=false
        //               [vid_dfe56e=1track … ×5]   ← nothing muted, five real audio tracks
        //
        // This runs on every page change, so the visible page always gets the last word.
        if let visibleRef, isVideo(visibleRef) {
            AudioCoordinator.shared.registerVideo(bag.players[visibleRef], for: item.id)
        }
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


    /// The measured width of a post's media column, so a page can span the card rather than shrink to the
/// media's own shape. `max` because the reducer sees one value per card.
struct MediaWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The blurred backdrop itself — SELF-LOADING, which is the whole reason it's a view and not a
/// `@ViewBuilder` helper reading the thumbnail cache inline.
///
/// It used to be exactly that: a cache PEEK evaluated in `PostCard.body`. But nothing ever tells a
/// card that its thumbnail has since landed — `FeedImage` decodes off-main and swaps the bitmap into
/// JUST itself, deliberately WITHOUT nudging a feed refresh (that refresh is what used to flash
/// already-shown media and chop the scroll). So a card whose body ran before its thumbnail was
/// resident saw an empty cache, drew no backdrop, and was never re-evaluated to notice otherwise.
/// It stayed flat for the life of the card.
///
/// That is the "top posts have no blur behind them" report. The cards you scroll DOWN to are built
/// after their decode finishes, so they look right; the ones on screen at launch race it and lose.
/// On a tall Mac window those top cards are also never recycled, so they never got a second chance —
/// which is why it read as a macOS bug even though the race is the same everywhere.
///
/// Holding its own `@State` bitmap keeps the property that made the old design worth having: a
/// finished decode re-renders this one backdrop, never the feed. Loading is awaited via
/// `thumbnailAsync`, which decodes off the main thread (and generates a video's poster off-thread),
/// so the backdrop still never decodes on the scroll hot path.
struct BlurredMediaBackdrop: View {
    let ref: String
    @State private var img: PlatformImage?
    /// Which ref `img` belongs to — a lazy cell reused for another post must not show the old blur.
    @State private var loadedRef: String?

    var body: some View {
        Group {
            if let img, loadedRef == ref {
                // GeometryReader (not `Color.clear.overlay { … .scaledToFill() }`) so the fill size is
                // COMPUTED and bounded — see `backdropFill`. `scaledToFill` let the layer size run away on a
                // narrow source, and a runaway layer is exactly what made the backdrop vanish.
                GeometryReader { g in
                    let fill = Self.backdropFill(source: img.size, container: g.size)
                    Image(platformImage: img)
                        .resizable()
                        .frame(width: fill.width, height: fill.height)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                        .blur(radius: 24, opaque: true)
                }
                .clipped()
                // Rasterize the blur ONCE instead of re-running it every scroll frame — a 24pt blur
                // re-composited per frame is what made scrolling past a post chop.
                .drawingGroup()
                .allowsHitTesting(false)
            }
        }
        .task(id: ref) {
            if let cached = Self.cachedSource(ref) { img = cached; loadedRef = ref; return }
            img = nil; loadedRef = nil
            // A 200px bucket, NOT the 1200px one. This is a 24pt-blurred wash stretched to fill —
            // it cannot show detail, so decoding full-size for it buys nothing and costs plenty.
            // The old code took 1200px to share the front tile's decode, but it also RETAINS that
            // bitmap in @State for the life of the card: every visible post held a 1200px image
            // alive purely to be blurred out of recognition. A feed of freshly-synced media is then
            // tens of MB of retained bitmaps, which is memory pressure, which is cache churn and a
            // warm phone — reported as the phone heating while pulling media from a peer's relay.
            // 200px is ~36x fewer pixels and visually identical once blurred.
            //
            // KEEP the returned bitmap. The old code discarded it and re-peeked the NSCache —
            // which iOS purges on every memory warning — so under pressure the peek came back nil,
            // `img` stayed nil forever, and the letterbox rendered the card's pure-black dark-mode
            // surface (the "background blur is just black on my iPhone" report). The front tile
            // never broke because FeedImage keeps its decode's return value; now the backdrop is
            // exactly as pressure-proof.
            //
            // RETRY UNTIL IT LANDS. This used to be a single attempt that, on failure, left
            // `loadedRef` nil "so a later .task re-run retries" — a promise nothing kept. `.task(id:)`
            // fires on appear and when its id changes, `ref` never changes, and this view observes
            // nothing, so there was no later run. Meanwhile the two ordinary ways to fail are both
            // TRANSIENT: `thumbnailAsync` returns nil the moment the bytes aren't on disk yet, and a
            // video's poster generation can fail outright when VideoToolbox is out of decode sessions.
            // So any card built before its media arrived drew a flat letterbox — the card's pure-black
            // dark-mode surface — for the life of that card instance, and scrolling it off-screen and
            // back (which rebuilds it in the LazyVStack, re-running this) was the only repair. That is
            // the "some posts have no background blur" report, and why it looked random: it depended
            // purely on whether the bytes beat the card.
            //
            // A widening delay, bounded. Each round is a cache peek plus one decode attempt, and only
            // for cards that have NO backdrop — a card that already drew one returned above. When the
            // card scrolls away the task is cancelled and the loop ends with it.
            for attempt in 0..<Self.loadRetryDelays.count {
                let decoded = await MediaStore.shared.thumbnailAsync(ref, maxDimension: 200)
                guard !Task.isCancelled else { return }
                if let found = Self.cachedSource(ref) ?? decoded {
                    img = found; loadedRef = ref
                    return
                }
                // Nothing to blur YET. Wait and ask again — the media is very likely still downloading.
                try? await Task.sleep(for: .seconds(Self.loadRetryDelays[attempt]))
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// Backoff between backdrop load attempts, in seconds. Runs ~2 minutes in total and then stops:
    /// past that the media is not "still arriving", and a card the user scrolls back to starts over.
    private static let loadRetryDelays: [Double] = [1, 2, 3, 5, 8, 12, 20, 30, 40]

    /// The bitmap to blur. Falls back through sizes because the 64px thumb ALONE is not dependable: it
    /// lives in an NSCache that evicts under pressure (the backdrop would vanish from a post that had
    /// one a moment ago), and for a video it's nil until the poster finishes generating off-thread.
    /// The 1200px thumb is already resident — it's what the page itself draws — so the fallback is
    /// free in the case that matters. Blurring a bigger bitmap costs nothing extra once rasterized.
    ///
    /// Cache PEEK only — no decode happens here. The decode is awaited in `.task`, off the main thread.
    ///
    /// The 64px thumb is preferred ONLY while it still has pixels to blur. A narrow source collapses its
    /// minor axis at that size (a 40×1600 sliver thumbs to 2×64), and a 2px-wide bitmap carries no color
    /// detail a 24pt blur can show — it bands. The 1200px thumb is the page's own bitmap, already resident,
    /// and holds its shape at any aspect, so it's the better source precisely in the narrow case.
    private static func cachedSource(_ ref: String) -> PlatformImage? {
        if let small = MediaStore.shared.cachedThumbnail(ref, maxDimension: 64),
           min(small.size.width, small.size.height) >= 8 {
            return small
        }
        // 200 is what the decode below now produces; 1200 stays only as an opportunistic hit for
        // cards that already have the front tile's bitmap resident (free — we don't ASK for it).
        return MediaStore.shared.cachedThumbnail(ref, maxDimension: 200)
            ?? MediaStore.shared.cachedThumbnail(ref, maxDimension: 1200)
            ?? MediaStore.shared.cachedThumbnail(ref, maxDimension: 64)
    }

    /// How far past the container a uniform crop-to-fill may spill before we stretch instead.
    private static let maxBackdropOverflow: CGFloat = 4

    /// The size to draw the backdrop bitmap at so it covers `container`.
    ///
    /// Normally that's a uniform crop-to-fill, exactly what `scaledToFill` did. The reason this is
    /// computed by hand is the NARROW case, where `scaledToFill` silently produced no backdrop at all:
    ///
    /// A 64px thumbnail caps the LARGER axis (ImageIO's `kCGImageSourceThumbnailMaxPixelSize`), so a
    /// narrow source comes back with its minor axis rounded down to a few pixels — a 40×1600 sliver
    /// becomes 2×64. Covering a card-sized page from a 2px-wide bitmap means magnifying it ~200×, and
    /// the filtered layer that produces runs to tens of thousands of points. Past the renderer's max
    /// texture size `.drawingGroup()` rasterizes to NOTHING — the post draws with no backdrop, which is
    /// the "too narrow → no blur" report. It's aspect-dependent, so it hit only some posts.
    ///
    /// So past `maxBackdropOverflow` we stretch to the container instead of cropping to it. Behind a
    /// 24pt blur a stretched copy is indistinguishable from a cropped one, and the layer is then exactly
    /// the container's size — it can never explode and never degenerate, for ANY aspect ratio.
    static func backdropFill(source: CGSize, container: CGSize) -> CGSize {
        // `> 0` also rejects NaN, which a zero-byte or malformed decode can hand back.
        guard source.width > 0, source.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = max(container.width / source.width, container.height / source.height)
        let filled = CGSize(width: source.width * scale, height: source.height * scale)
        // `scale` is the max of the two ratios, so one axis lands exactly on the container and the other
        // spills. This is that spill.
        let overflow = max(filled.width / container.width, filled.height / container.height)
        return overflow <= maxBackdropOverflow ? filled : container
    }
}


#if os(macOS)
/// Reaches the enclosing NSScrollView and turns its horizontal scroller off for good.
///
/// SwiftUI can't do this on macOS: with "Show scroll bars: Always" in System Settings, AppKit forces
/// LEGACY (non-overlay) scrollers and neither `showsIndicators: false` nor `.scrollIndicators(.never)`
/// suppresses them — a grey bar draws across the bottom of the carousel. The dots already say which
/// page you're on, so the scroller is pure noise.
struct KillHorizontalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ v: NSView, context: Context) {
        // async: the view isn't in the hierarchy yet at make time, so there's no scroll view to find.
        DispatchQueue.main.async {
            var node: NSView? = v
            while let cur = node {
                if let sv = cur as? NSScrollView {
                    sv.hasHorizontalScroller = false
                    sv.horizontalScroller = nil
                    sv.scrollerStyle = .overlay
                    return
                }
                node = cur.superview
            }
        }
    }
}
#endif
