import SwiftUI
import AVKit

#if !os(macOS)
/// AVPlayerLayer-backed surface with no system chrome. `.resizeAspect` letterboxes — the whole
/// frame is always visible, never cropped.
///
/// Also hosts the scrub pan as a UIKIT recognizer. A SwiftUI `DragGesture` on this surface —
/// even attached with `.simultaneousGesture` — blocks the feed ScrollView's pan on iOS 26,
/// which is why a tall video was a wall the feed couldn't scroll past (proven by bisection in
/// the simulator: with the SwiftUI drag removed, the same swipe scrolls). A
/// `UIPanGestureRecognizer` whose `gestureRecognizerShouldBegin` REFUSES vertical-dominant
/// movement never claims those touches at all, so the feed scrolls natively; horizontal
/// movement begins the pan and drives the scrub.
final class PlayerLayerView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// Carousel mode: only a drag starting in the bottom strip of this height scrubs (a drag
    /// above it pages the carousel). 0 = the whole surface scrubs (single-video post).
    var scrubStripHeight: CGFloat = 0
    var onScrubBegan: (() -> Void)?
    var onScrubChangedX: ((CGFloat) -> Void)?   // cumulative horizontal translation
    var onScrubEnded: (() -> Void)?
    private var pan: UIPanGestureRecognizer?

    func installScrubPan() {
        guard pan == nil else { return }
        let p = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        p.delegate = self
        p.maximumNumberOfTouches = 1
        addGestureRecognizer(p)
        pan = p
    }

    @objc private func handlePan(_ p: UIPanGestureRecognizer) {
        switch p.state {
        case .began: onScrubBegan?()
        case .changed: onScrubChangedX?(p.translation(in: self).x)
        case .ended, .cancelled, .failed: onScrubEnded?()
        default: break
        }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan, let p = pan else { return super.gestureRecognizerShouldBegin(g) }
        // Vertical-dominant start → this recognizer never begins, so the touch belongs to the
        // feed's UIScrollView (the whole point). Horizontal-dominant → scrub.
        let v = p.velocity(in: self)
        guard abs(v.x) > abs(v.y) else { return false }
        if scrubStripHeight > 0, p.location(in: self).y < bounds.height - scrubStripHeight {
            return false   // above the carousel's scrub strip → let the pager handle it
        }
        return true
    }
}
#else
/// AVPlayerLayer-backed surface with no system chrome (native macOS / AppKit). Layer-backed
/// `NSView` hosting an `AVPlayerLayer`. Mirrors the iOS class's public API (`playerLayer`).
/// `.resizeAspect` letterboxes — the whole frame is always visible, never cropped.
final class PlayerLayerView: NSView {
    private let _playerLayer = AVPlayerLayer()
    var playerLayer: AVPlayerLayer { _playerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = _playerLayer
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = _playerLayer
    }
}
#endif

#if !os(macOS)
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    /// Fill the surface (crop overflow) instead of letterboxing. Default fit for back-compat.
    var fill: Bool = false
    /// nil = no scrub pan. 0 = whole-surface horizontal scrub. >0 = bottom-strip-only (carousel).
    var scrubStripHeight: CGFloat? = nil
    var onScrubBegan: (() -> Void)? = nil
    var onScrubChangedX: ((CGFloat) -> Void)? = nil
    var onScrubEnded: (() -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        if scrubStripHeight != nil { v.installScrubPan() }
        return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        v.scrubStripHeight = scrubStripHeight ?? 0
        v.onScrubBegan = onScrubBegan
        v.onScrubChangedX = onScrubChangedX
        v.onScrubEnded = onScrubEnded
        if scrubStripHeight != nil { v.installScrubPan() }
    }
}
#else
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var fill: Bool = false
    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }
    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
#endif

/// Inline video with custom, chrome-free controls. This view OWNS every gesture on the
/// video so nothing upstream (the parent post's tap/zoom/contextMenu) can steal them:
///  • **single tap** → `onTap` (the parent uses this to toggle mute)
///  • **double tap** → `onDoubleTap` (the parent uses this to ❤️ the post)
///  • **hold** (long-press) → pause while held, release to resume
///  • **horizontal drag** → scrub (shows a thin progress bar + time)
struct GestureVideoPlayer: View {
    let player: AVPlayer
    var onTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}
    /// In a swipeable carousel, only a drag in the bottom 1/3 should scrub — a drag in the top 2/3 must
    /// swipe between carousel items. Also lifts the scrub bar above the page dots. Off = scrub anywhere.
    var inCarousel: Bool = false
    /// Reports scrub start/stop so the carousel can hide its page dots while the scrub bar is up.
    var onScrubbing: (Bool) -> Void = { _ in }

    @State private var progress: Double = 0      // 0…1
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var interacting = false
    @State private var wasPlaying = false
    @State private var startProgress: Double = 0
    @State private var dragAxisLocked = false   // committed to horizontal-scrub for this drag
    @State private var observed: (AVPlayer, Any)?

    var body: some View {
        GeometryReader { geo in
            content(geo)
        }
        .onAppear(perform: addObserver)
        .onDisappear(perform: removeObserver)
        .onChange(of: scrubbing) { _, s in onScrubbing(s) }   // let the carousel hide its dots while scrubbing
    }

    @ViewBuilder private func content(_ geo: GeometryProxy) -> some View {
        #if !os(macOS)
        // iOS/Catalyst: the scrub lives INSIDE VideoSurface as a UIKit pan that only begins on
        // horizontal movement (see PlayerLayerView). Any SwiftUI DragGesture here — high-priority
        // OR simultaneous — blocks the feed ScrollView's pan on iOS 26, which made a tall video a
        // wall the feed couldn't scroll past (verified by simulator bisection). Vertical swipes
        // never engage the pan, so the feed / dismiss-drag / carousel handle them natively.
        VideoSurface(player: player,
                     scrubStripHeight: inCarousel ? min(96, max(56, geo.size.height / 3)) : 0,
                     onScrubBegan: { beginScrub() },
                     onScrubChangedX: { x in changeScrub(x, width: geo.size.width) },
                     onScrubEnded: { endScrub() })
            .overlay(alignment: .bottom) {
                // Lift the scrub bar above the carousel's page dots so they don't collide.
                if scrubbing { scrubBar.padding(.horizontal, 8).padding(.bottom, inCarousel ? 26 : 8) }
            }
            .contentShape(Rectangle())
            // Tap → mute, double-tap → heart. Double-tap registered first so a genuine
            // double-tap isn't consumed as a single tap.
            .onTapGesture(count: 2) { onDoubleTap() }
            .onTapGesture(count: 1) { onTap() }
            // Hold-to-pause. SIMULTANEOUS, not high-priority — the high-priority long-press's
            // sequenced drag claimed whole swipes whenever the finger rested >0.2s first. Video
            // posts carry no contextMenu (reserved for the player), so nothing needs
            // out-prioritizing; a slow scroll may briefly pause the video, resuming on lift.
            .simultaneousGesture(holdToPause)
        #else
        // Native macOS: feed scrolling is wheel/trackpad-driven, which SwiftUI drags don't block,
        // so the original SwiftUI scrub gesture stays.
        let base = VideoSurface(player: player)
            .overlay(alignment: .bottom) {
                if scrubbing { scrubBar.padding(.horizontal, 8).padding(.bottom, inCarousel ? 26 : 8) }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onDoubleTap() }
            .onTapGesture(count: 1) { onTap() }
            .simultaneousGesture(holdToPause)
        if inCarousel {
            base.overlay(alignment: .bottom) {
                Color.clear
                    .frame(height: min(96, max(56, geo.size.height / 3)))
                    .contentShape(Rectangle())
                    .highPriorityGesture(scrub(width: geo.size.width))
            }
        } else {
            base.simultaneousGesture(scrub(width: geo.size.width))
        }
        #endif
    }

    // MARK: - Scrub state transitions (shared by the UIKit pan on iOS and the macOS drag)

    private func beginScrub() {
        scrubbing = true
        wasPlaying = wasPlaying || player.timeControlStatus == .playing
        startProgress = progress
        player.pause()
    }
    private func changeScrub(_ translationX: CGFloat, width: CGFloat) {
        guard scrubbing, width > 0 else { return }
        let pct = min(1, max(0, startProgress + translationX / width))
        progress = pct
        seek(to: pct)
    }
    private func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        if wasPlaying { player.play() }
        wasPlaying = false
        interacting = false
    }

    private var scrubBar: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: g.size.width * progress)
                }
            }
            .frame(height: 4)
            Text(timeLabel).font(.caption2.monospacedDigit()).foregroundStyle(.white)
        }
        .padding(8)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var timeLabel: String {
        func f(_ s: Double) -> String { let v = max(0, s); return String(format: "%d:%02d", Int(v) / 60, Int(v) % 60) }
        return "\(f(progress * duration)) / \(f(duration))"
    }

    /// Press-and-hold pauses the video while held, resumes on release. A 0.2s minimum keeps
    /// it from firing on a quick tap. Because this is attached as a high-priority gesture it
    /// wins the long-press race against any ancestor `.contextMenu`.
    private var holdToPause: some Gesture {
        LongPressGesture(minimumDuration: 0.2, maximumDistance: 10)
            .onEnded { _ in
                // Long-press recognized — pause and hold. The accompanying drag/lift is tracked
                // by the trailing DragGesture so we know when the finger lifts.
                if !scrubbing {
                    wasPlaying = player.timeControlStatus == .playing
                    player.pause()
                    interacting = true
                }
            }
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { _ in
                // Finger lifted after a hold — resume if it had been playing (and we're not
                // mid-scrub, which manages its own resume).
                if interacting && !scrubbing {
                    if wasPlaying { player.play() }
                    interacting = false
                }
            }
    }

    #if os(macOS)
    /// A horizontal drag scrubs the timeline (macOS only — on iOS the scrub is a UIKit pan in
    /// PlayerLayerView; see content()). Engages once the drag is clearly horizontal; axis-locks
    /// for the rest of the drag so a wiggly cursor doesn't drop the scrub.
    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag in
                if !dragAxisLocked {
                    guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                    dragAxisLocked = true
                    beginScrub()
                }
                guard dragAxisLocked else { return }
                changeScrub(drag.translation.width, width: width)
            }
            .onEnded { _ in
                guard dragAxisLocked else { return }
                dragAxisLocked = false
                endScrub()
            }
    }
    #endif

    private func seek(to pct: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: pct * duration, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func addObserver() {
        removeObserver()   // never stack observers / leave a stale one
        if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            if duration <= 0, let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
            if !scrubbing, duration > 0 { progress = time.seconds / duration }
        }
        observed = (player, token)   // remember the EXACT player this token belongs to
    }
    private func removeObserver() {
        // Remove from the player the observer was actually added to — SwiftUI can recycle this
        // view onto a different `player`, and removing a token from the wrong player throws
        // (the iPad crash on tab-away). Only ever remove once.
        if let (p, token) = observed { p.removeTimeObserver(token); observed = nil }
    }
}

/// Attaches a single-tap gesture only when `enabled`. Lets the single-video tile drop its
/// tap-to-zoom (so the video's own tap/hold/drag gestures aren't intercepted) while images
/// keep tap-to-zoom.
struct ConditionalTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) }
        else { content }
    }
}
