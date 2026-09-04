import SwiftUI
import Combine
import AVKit
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Short relative time ("now", "5m", "3h", "2d", "8mo", "2y") from a unix-millis SENT timestamp —
/// so people see when something was sent, not when it reached them.
///
/// Months stop at a year. Counting them forever produced "32mo" for a post from 2023, which is a
/// number nobody converts on sight — the unit has to keep getting coarser or it stops being a
/// glance. Archive imports made this constant rather than a curiosity, since they backdate posts
/// years into the past.
func relativeTimeShort(_ ms: UInt64) -> String {
    let secs = Date().timeIntervalSince1970 - Double(ms) / 1000
    switch secs {
    case ..<5: return "now"
    case ..<60: return "\(Int(secs))s"
    case ..<3600: return "\(Int(secs / 60))m"
    case ..<86_400: return "\(Int(secs / 3600))h"
    case ..<604_800: return "\(Int(secs / 86_400))d"
    case ..<2_592_000: return "\(Int(secs / 604_800))w"
    case ..<31_536_000: return "\(Int(secs / 2_592_000))mo"
    default: return "\(Int(secs / 31_536_000))y"
    }
}

/// Set while a capture session (story / post camera) owns the audio session. An AVCaptureSession
/// configures the SHARED session for recording; having feed playback asynchronously stomp it back to
/// `.playback` mid-startup makes the two fight and can wedge the camera. While this is true, playback
/// never touches the session — the camera is the only owner.
nonisolated(unsafe) var havenCaptureOwnsAudioSession = false

/// How many camera surfaces are on screen right now (story camera, post camera, any viewfinder).
/// While ANY is open the system music player stays silent: a post's song playing behind a viewfinder is
/// never wanted, and it fights the capture session for the audio route. Counted rather than a Bool so a
/// camera presented over another camera can't clear the flag early.
nonisolated(unsafe) var havenCameraUIOpen = 0
/// True while any camera UI is up — the single gate every playback entry point checks.
var havenCameraIsOpen: Bool { havenCameraUIOpen > 0 || havenCaptureOwnsAudioSession }

/// Set while the story composer is deliberately previewing its attached song. The composer plays through
/// the SAME shared system music player the feed uses, so the "stop the post song behind this overlay"
/// paths must not touch it: a sheet appearing over the composer (or the composer's own onAppear re-firing
/// as the song picker dismissed) was calling stop() on the preview we had just started — which is why the
/// song played through the dismiss animation and then went silent.
nonisolated(unsafe) var havenStoryPreviewActive = false

#if os(iOS)
private let havenAudioSessionQueue = DispatchQueue(label: "haven.audioSession")

/// Configure the shared audio session for muted-video-over-music playback exactly once, OFF the main
/// thread. setCategory/setActive are synchronous and can stall the main thread for tens of ms; calling
/// them from `playVisibleVideo` on every scroll was the video "stick then continue". Idempotent — it
/// no-ops when the session is already playback + mixWithOthers (so a call that changed the category
/// still gets it reconfigured next time a video plays).
/// `force` = the caller definitively owns playback right now (the story editor, where capture is over).
/// Without it the async re-check below could be beaten by the camera view re-claiming the session as the
/// editor came up, and the whole configuration would silently no-op.
/// `then` runs on the main queue once the session is actually configured. Anything that STARTS audio must
/// use it: the configuration happens off-main, so starting a song on the line after the call began playback
/// while the session was still non-mixing — the muted canvas clip then held the route exclusively and
/// suppressed the song. (That's why the preview only worked on a second toggle: by then the first call's
/// configuration had landed.) Always invoked, including on the early-outs, so callers can't stall.
func ensureHavenPlaybackSession(force: Bool = false, then: (() -> Void)? = nil) {
    func finish() { if let then { DispatchQueue.main.async(execute: then) } }
    if !force, havenCaptureOwnsAudioSession { finish(); return }   // the camera owns the session — hands off
    havenAudioSessionQueue.async {
        if !force, havenCaptureOwnsAudioSession { finish(); return }   // the camera may have opened since
        let s = AVAudioSession.sharedInstance()
        if s.category != .playback || !s.categoryOptions.contains(.mixWithOthers) {
            // NB: this THROWS while a capture session is live — the category then silently stays
            // PlayAndRecord (non-mixing) and interrupts anything we start. Capture is stopped before the
            // composer opens precisely so this call can succeed.
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        // ALWAYS activate, even when the category already looked right. A capture session tearing down
        // leaves the session INACTIVE while the category still reads playback+mixWithOthers — skipping
        // activation there meant the next player to start grabbed the session in default (non-mixing)
        // mode and interrupted whatever was already playing.
        try? s.setActive(true)
        finish()
    }
}
#endif

/// Reports each post card's on-screen vertical center so the feed can pick the one
/// nearest the middle of the screen as the "active" (playing) post.
/// Which scroll container a PostCard is rendered inside.
///
/// Three feeds report a centered post into the one AudioCoordinator, and a TabView keeps its tabs
/// alive off screen — so the same post can exist as two live cards that BOTH matched
/// `centeredPostId == item.id`. Both then built a player for the same clip. Pairing the centered id
/// with its container lets a card tell "the centre is mine" from "some other feed reported it".
private struct HavenFeedContainerKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var havenFeedContainer: String {
        get { self[HavenFeedContainerKey.self] }
        set { self[HavenFeedContainerKey.self] = newValue }
    }
}

/// Counts live feed players so a doubled clip is a fact rather than a theory.
@MainActor
enum BodyCensus {
    private static var n = 0
    private static var started = false
    static func tick() {
        // DEBUG-only: this diagnostic timer ran in Release builds too (audit of DEBUG timers,
        // owner's thermal report). The 5s line also lands in HavenThermal.log next to the CPU samples.
        #if DEBUG
        n += 1
        if !started {
            started = true
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if n > 0 {
                        let line = "PostCard.body evaluated \(n)x in 5s (\(n / 5)/s)"
                        HavenLog.sync(line); ThermalSampler.shared.note("[Census] " + line); n = 0
                    }
                }
            }
        }
        #endif
    }
}

enum PlayerCensus {
    private static var made: [String: Int] = [:]
    static func note(ref: String, postId: String, container: String, bag: String) {
        let k = "\(ref)|\(postId)"
        made[k, default: 0] += 1
        let n = made[k]!
        HavenLog.sync("player #\(n) ref=\(ref.prefix(12)) post=\(postId.prefix(8)) container=\(container) bag=\(bag)")
    }
}

struct PostCenterKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { a, _ in a }
    }
}


/// Delivery state of a circle's authored content (the composer status light).
enum PostSyncStatus: Equatable {
    case synced, pending, stuck
    var color: Color { switch self { case .synced: return .green; case .pending: return .yellow; case .stuck: return .red } }
    var label: String {
        switch self {
        case .synced: return "Synced"
        case .pending: return "Syncing…"
        case .stuck: return "On this device only"
        }
    }
}

/// A small green/yellow/red light + label showing whether posts in this circle are getting out. Recomputed
/// on a light timer so it reflects an upload finishing or a peer connecting without needing a manual refresh.
/// Live media-sync counters, kept OUT of FeedStore so incrementing them never re-renders the feed/You
/// tab (that was the sync-time lag). Only the tap-to-open SyncDetailView observes this.
@MainActor final class SyncMetrics: ObservableObject {
    static let shared = SyncMetrics()
    private init() {}
    @Published var nbMediaOut = 0       // media items served/pushed over nearby
    @Published var nbMediaIn = 0        // media items fully received over nearby
    @Published var nbMediaPending = 0   // media refs still missing locally
}

struct SyncStatusBadge: View {
    let circleId: String
    @ObservedObject private var store = FeedStore.shared
    @State private var showDetail = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.5)) { _ in
            let s = store.syncStatus(circleId: circleId)
            // Only surface the pill when there's something to know — "Syncing…" or "device-only". When
            // everything's synced it collapses to nothing so it doesn't pad out the composer.
            if s != .synced {
                Button { showDetail = true } label: {
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                            .shadow(color: s.color.opacity(0.6), radius: 2)
                        Text(s.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .havenGlass(in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Tap for live sync detail. Yellow: still syncing. Red: only on this device.")
                .transition(.opacity)
                .popover(isPresented: $showDetail, arrowEdge: .bottom) { SyncDetailView() }
            }
        }
    }
}

/// The "magical details" behind the sync light — surfaced only when the user taps the yellow/red pill, so
/// it's there when they want to monitor a sync but never clutters (or re-renders) the feed otherwise.
struct SyncDetailView: View {
    @ObservedObject private var m = SyncMetrics.shared
    @ObservedObject private var store = FeedStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync activity").font(.headline)
            Label("\(m.nbMediaOut) media sent", systemImage: "arrow.up.circle")
            Label("\(m.nbMediaIn) media received", systemImage: "arrow.down.circle")
            Label("\(m.nbMediaPending) media waiting", systemImage: "clock")
            Divider()
            Label(store.nearbyActive ? "Nearby devices: connected" : "Nearby devices: not connected",
                  systemImage: store.nearbyActive ? "antenna.radiowaves.left.and.right"
                                                  : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(store.nearbyActive ? HavenTheme.pink : .secondary)
            Text("Updates live while your devices and circles sync.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
        .padding(16)
        .frame(minWidth: 240, alignment: .leading)
        // On iPhone a popover adapts to a sheet — pin it to a small detent so it's a compact card, not full-screen.
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

struct FeedView: View {
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var gate = BiometricGate.shared
    let account: Account
    let friendName: String
    let seed: Data
    @State private var showCircle = false

    @State private var compose = ""
    @State private var attachedMedia: [String] = []
    @State private var attachedTrack: TrackRefFfi?
    @State private var muteVideo = false   // author's audio choice for attached video(s)
    @State private var pendingSensitive: [String]?   // attachments SCA flagged, awaiting send-anyway
    @State private var showLocation = false   // opt-in: tag the post with a photo's reverse-geocoded place
    @State private var showSchedule = false   // "send later" date picker
    @State private var dropActive = false   // drag-and-drop media onto the composer (macOS/iPadOS)
    @State private var showFilesImporter = false   // pick media from the Files app (iOS/iPadOS)
    @State private var showFilePicker = false      // macOS file browser (NSOpenPanel)
    @State private var showMediaPicker = false
    @State private var showAudioRecorder = false
    @State private var showCamera = false
    @State private var showSongPicker = false
    @State private var showLocationPicker = false
    @State private var composeRetention: UInt64?
    @State private var showNewCircle = false
    @State private var newCircleName = ""
    @State private var showStoryCamera = false
    @State private var showStories = false
    @State private var storyIndex = 0
    @State private var trimmingRef: TrimTarget?
    @State private var showRequests = false
    @State private var showActivity = false
    @ObservedObject private var activity = ActivityStore.shared
    @ObservedObject private var connections = ConnectionsStore.shared
    @FocusState private var composeFocused: Bool
    @State private var commentingActive = false   // a post's comment field is focused → hide composer
    /// The post currently at the top edge — see `.scrollPosition` below. Nil while the header is on
    /// screen, which is what lets new posts appear normally when you are already at the top.
    @State private var anchoredPostId: String?
    @ObservedObject private var importer = InstagramImporter.shared
    /// Posts are arriving in bulk (an archive import) rather than one at a time — suppress the
    /// arrival animation so the feed stays still enough to read while it fills in behind you.
    private var bulkArriving: Bool { importer.isRunning }

    struct TrimTarget: Identifiable { let id = UUID(); let ref: String }

    init(account: Account, seed: Data, friendName: String) {
        self.account = account
        self.seed = seed
        self.friendName = friendName
    }

    /// The "My Circles" switcher (also: show/hide hidden posts, new circle). Extracted so it can be
    /// placed centered on iOS but pinned leading on macOS (where it would otherwise shove the top tabs).
    @ViewBuilder private var circlePicker: some View {
        Menu {
            ForEach(store.feedCircles, id: \.id) { c in
                Button { store.setActiveCircle(c.id) } label: {
                    Label(c.name, systemImage: c.id == store.activeCircleId ? "checkmark" : "circle.dashed")
                }
            }
            Divider()
            if store.hiddenInActiveCircle > 0 || HiddenStore.shared.showHidden {
                Button {
                    HiddenStore.shared.toggleShowHidden(); store.refresh()
                } label: {
                    Label(HiddenStore.shared.showHidden ? "Hide hidden posts" : "Show hidden posts (\(store.hiddenInActiveCircle))",
                          systemImage: HiddenStore.shared.showHidden ? "eye.slash" : "eye")
                }
            }
            Button { newCircleName = ""; showNewCircle = true } label: {
                Label("New circle…", systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.activeCircleName).font(.headline)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(.primary)
        }
        .menuIndicator(.hidden)   // macOS adds its own chevron; keep only our styled one
        #if os(macOS)
        .menuStyle(.borderlessButton)   // else macOS wraps the title+chevron in a popup-button bezel
        .fixedSize()
        #endif
    }

    #if os(iOS)
    /// Load a share routed to "Share as Post" into THIS composer — the one that owns the circle
    /// switcher, the song picker, the location toggle and scheduling. Appended, never assigned, so
    /// it can't discard something half-typed.
    ///
    /// Deliberately a PULL (`takePostDraft`), and deliberately never called straight from the
    /// publisher — see that method for why clearing during the publish silently put the draft back.
    /// Refs are de-duplicated because both entry points (the publisher and `onAppear`) can fire for
    /// one share, which is what attached the same photo twice.
    private func applySharedPostDraft() {
        guard let draft = ShareRouter.shared.takePostDraft() else { return }
        if !draft.text.isEmpty {
            compose = compose.isEmpty ? draft.text : compose + "\n" + draft.text
        }
        attachedMedia.append(contentsOf: draft.refs.filter { !attachedMedia.contains($0) })
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                    .contentShape(Rectangle())
                    .onTapGesture { composeFocused = false }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        banner
                        if !connections.pending.isEmpty { pendingBanner }
                        CircleUpgradeBanner(circleId: store.activeCircleId)
                        RelayNudgeBanner(circleId: store.activeCircleId)
                        storiesTray
                        if store.feedItems.isEmpty {
                            emptyState
                        }
                        ForEach(store.feedItems, id: \.id) { item in
                            PostCard(
                                item: item, friendName: friendName,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onUnreact: { e in withAnimation(HavenTheme.bouncy) { store.unreact(item.id, e) } },
                                onComment: { b, m in
                                    withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) }
                                    // Reveal the freshly added reply (it lands at the post's bottom).
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        withAnimation(HavenTheme.smooth) { proxy.scrollTo(item.id, anchor: .bottom) }
                                    }
                                },
                                onEdit: { b in withAnimation(HavenTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(HavenTheme.smooth) { store.unsend(item.id) } },
                                onCommentFocus: { focused in
                                    // Hide the feed composer while commenting (it overlapped the
                                    // comment), and lift the focused post above the keyboard.
                                    commentingActive = focused
                                    if focused {
                                        withAnimation(HavenTheme.smooth) { proxy.scrollTo(item.id, anchor: .bottom) }
                                    }
                                }
                            )
                            // Skip the whole 1,507-line body when this row's item is unchanged.
                            // FeedStore.items republishes on every feed rebuild (a mailbox pull, a
                            // poster landing, a periodic tick) and re-initialises every visible card;
                            // without this each republish re-evaluates all of them.
                            .equatable()
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PostCenterKey.self,
                                                       value: [item.id: geo.frame(in: .global).midY])
                            })
                            // Reaching the oldest post we hold is the cue to ask its author for the
                            // page before it — history arrives as it is looked at, not all at once
                            // when someone is added. No-op once we've asked for this cursor.
                            .onAppear {
                                if item.id == store.feedItems.last?.id { store.requestOlderHistory() }
                            }
                            // A bulk import writes hundreds of posts, and animating each arrival
                            // means the whole stack springs on every one of them — the page visibly
                            // bounces, and because the moving layout changes which post is nearest
                            // the centre, the video you were watching keeps restarting. A single
                            // post arriving is news worth animating; three hundred is not.
                            .transition(bulkArriving ? .identity : .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                removal: .opacity))
                        }
                    }
                    .scrollTargetLayout()
                    .animation(bulkArriving ? nil : HavenTheme.bouncy, value: store.items.count)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 130)
                }
                // KEEP THE READER'S PLACE when posts arrive.
                //
                // The feed is newest-first, so anything new — a peer's post, a mailbox pull landing
                // a batch, an archive import writing 300 of them — is INSERTED ABOVE whatever is
                // being read. A plain ScrollView holds its content offset, not its content, so
                // every insertion shoved the page down and the reader lost their spot. An import
                // made that constant.
                //
                // Binding the scroll position to the post at the top edge pins that post instead of
                // the offset: content grows above it and the reader does not move. The binding is
                // nil while the header/stories tray is on screen, which is exactly right — at the
                // top of the feed new posts SHOULD appear in front of you.
                .scrollPosition(id: $anchoredPostId, anchor: .top)
                .scrollDismissesKeyboard(.immediately)
                .onPreferenceChange(PostCenterKey.self) { centers in
                    // The post nearest the vertical center of the screen becomes active.
                    let target = PlatformScreen.contentCenterY
                    let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                    AudioCoordinator.shared.center(nearest?.key, container: "circle")
                }
                .environment(\.havenFeedContainer, "circle")
                }   // ScrollViewReader
                // Hide the "Share something" composer while a comment field is focused so it
                // doesn't float over the comment you're writing.
                if !commentingActive { composerBar }
            }
            .overlay {
                // Biometric-locked circle: cover its feed until Face ID unlocks it. The toolbar
                // circle-switcher stays usable so you can navigate away without unlocking.
                if gate.isLocked(store.activeCircleId) {
                    CircleLockView(circleName: store.activeCircleName, circleId: store.activeCircleId)
                }
            }
            .navigationTitle(store.activeCircleName)
            .havenInlineNavTitle()
            .toolbar {
                #if os(macOS)
                // On macOS the TabView's tabs (Circle / Messages / You) sit centered at the top; a
                // centered (.principal) circle switcher fought them for space and shoved them around as
                // its label width changed. Pin the switcher to the leading edge so the tabs stay put.
                ToolbarItem(placement: .havenLeading) { circlePicker }
                #else
                ToolbarItem(placement: .principal) { circlePicker }
                #endif
                // Activity bell: everything that happened across your circles, with an unread
                // badge cleared fleet-wide on open (seenAt syncs via SelfSync). Both platforms.
                ToolbarItem(placement: .havenTrailing) {
                    Button { showActivity = true } label: {
                        // The toolbar's glass capsule CLIPS whatever overflows the label's bounds,
                        // so a badge nudged outward with .offset always loses its top-right corner
                        // — every previous attempt here was just tuning how much got cut. Instead
                        // give the label uniform padding: the capsule grows to include it, the
                        // glyph stays centred (asymmetric padding is what shoved it off-centre
                        // before), and the badge lives INSIDE that padded corner where nothing
                        // clips it. No offset at all.
                        Image(systemName: "bell.fill")
                            .padding(5)
                            .overlay(alignment: .topTrailing) {
                                if activity.unread > 0 {
                                    Text(activity.unread > 99 ? "99+" : "\(activity.unread)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.red))
                                        .fixedSize()
                                }
                            }
                    }
                    .buttonStyle(HavenGlassIcon())
                    .accessibilityLabel("Activity")
                }
                // Manage this circle (members, invite, settings) — lives on the circle, not You.
                ToolbarItem(placement: .havenTrailing) {
                    Button { showCircle = true } label: { Image(systemName: "person.2.fill") }
                        .accessibilityIdentifier("circleMembers")
                        .buttonStyle(HavenGlassIcon())
                        .accessibilityLabel("Manage circle")
                }
            }
            .sheet(isPresented: $showActivity) {
                ActivityView().macSheetFrame()
            }
            .sheet(isPresented: $showCircle) {
                #if os(macOS)
                CircleView(account: account)   // HavenMacSheet brings its own frame, gradient, and close
                #else
                NavigationStack { CircleView(account: account) }.macSheetClose()
                #endif
            }
            .sheet(isPresented: $showNewCircle) {
                #if os(macOS)
                NewCircleView { name, members in store.createCircle(name: name, memberIds: members) }
                #else
                NewCircleView { name, members in store.createCircle(name: name, memberIds: members) }.macSheetClose()
                #endif
            }
            // Something shared in from another app, routed to "Share as Post" — load it into THIS
            // composer rather than a lesser copy of it, so the circle switcher, song picker,
            // location toggle and schedule all still apply. Appended, never assigned: re-entering
            // the tab must not discard something half-typed.
            #if os(iOS)
            // Next runloop turn, NOT inline: this fires from `@Published`'s willSet, and taking the
            // draft there writes into the middle of the very assignment that published it.
            .onReceive(ShareRouter.shared.$postDraft) { _ in
                DispatchQueue.main.async { applySharedPostDraft() }
            }
            #endif
            .onAppear {
                #if os(iOS)
                // A draft that arrived BEFORE this view existed.
                //
                // TabView builds a tab's content the first time that tab is shown, so a share
                // routed to "Share as Post" while the Circle tab had never been opened published
                // `postDraft` to nobody — `onReceive` needs a live subscriber. The draft is
                // durable, so also look for one on the way in. Both paths are safe to run: the
                // take is atomic and the refs de-duplicate.
                applySharedPostDraft()
                #endif
                store.configureForCurrentIdentity()   // seeded or seedless (S4) — never boot off a throwaway seed
                // Screenshot harness: open the full-screen story viewer for its hero shot.
                // The feed rebuild is async now, so RETRY until the demo stories are published
                // (a single fixed delay raced the off-main refresh and silently skipped the scene).
                if DemoEnv.scene == .story {
                    func tryPresent(_ attempt: Int = 0) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if !store.groupedStoriesFlat.isEmpty {
                                storyIndex = 0; showStories = true
                            } else if attempt < 10 {
                                tryPresent(attempt + 1)
                            }
                        }
                    }
                    tryPresent()
                }
            }
            .sensoryFeedback(.success, trigger: store.postTick)
            .sensoryFeedback(.impact(weight: .light), trigger: store.reactionTick)
            .sheet(isPresented: $showMediaPicker) {
                MediaPicker { refs in attachedMedia.append(contentsOf: refs) }.macSheetClose()
            }
            #if os(macOS)
            .sheet(isPresented: $showFilePicker) {
                FilePicker { refs in attachedMedia.append(contentsOf: refs) }.macSheetFrame()
            }
            #endif
            .sheet(isPresented: $showLocationPicker) {
                LocationPicker { ref in attachedMedia.append(ref) }.macSheetClose()
            }
            .havenFullScreenCover(isPresented: $showCamera) {
                CameraView { refs in attachedMedia.append(contentsOf: refs) }.ignoresSafeArea()
            }
            .sheet(isPresented: $showSongPicker) {
                SongPicker(onPick: { track in attachedTrack = track },
                           suggestFor: (media: attachedMedia, caption: compose)).macSheetFrame()
            }
            .sheet(isPresented: $showSchedule) {
                SchedulePicker(circleId: store.activeCircleId, isDM: false) { date in scheduleCurrentPost(at: date) }.macSheetFrame()
            }
            .fileImporter(isPresented: $showFilesImporter,
                          allowedContentTypes: [.image, .movie, .item, .data, .archive, .folder],
                          allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                Task { @MainActor in
                    let refs = await MediaImport.importURLs(urls)
                    if !refs.isEmpty { attachedMedia.append(contentsOf: refs) }
                }
            }
            .confirmationDialog("This media may be sensitive",
                                isPresented: Binding(get: { pendingSensitive != nil },
                                                     set: { if !$0 { pendingSensitive = nil } }),
                                titleVisibility: .visible) {
                Button("Send anyway", role: .destructive) {
                    let f = pendingSensitive ?? []; pendingSensitive = nil; doSend(flagged: f)
                }
                Button("Cancel", role: .cancel) { pendingSensitive = nil }
            } message: {
                Text("On-device analysis flagged one or more attachments as sensitive. If you send, they'll be blurred for everyone in the circle until each person taps to reveal.")
            }
            .havenFullScreenCover(isPresented: $showStoryCamera) {
                StoryCameraView { ref, caption, track in
                    Task { @MainActor in
                        // A long video becomes up to 5 consecutive story slides.
                        let refs = await MediaStore.shared.splitStoryVideo(ref)
                        for r in refs { store.postStory(media: [r], caption: caption, music: track) }
                    }
                }
            }
            .sheet(isPresented: $showRequests) { ConnectionRequestsView() }
            .havenFullScreenCover(isPresented: $showStories) {
                // `.id(storyIndex)` forces a fresh StoryViewer per tapped user — otherwise SwiftUI reuses
                // the view identity and its @State `index` sticks at the first value, so every tap opened
                // the lineup from the far-left user instead of the one tapped.
                StoryViewer(stories: store.groupedStoriesFlat, index: storyIndex, friendName: friendName)
                    .id(storyIndex)
            }
            .havenFullScreenCover(item: $trimmingRef) { target in
                if let url = MediaStore.shared.storagePath(for: target.ref) {
                    VideoTrimmer(path: url.path) { trimmed in
                        replaceAttached(target.ref, with: MediaStore.shared.importTrimmed(trimmed))
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40)).foregroundStyle(HavenTheme.pink)
            Text("Nothing here yet")
                .font(.headline)
            Text("Share your first moment below. As your circle connects, their posts show up here too.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60).padding(.horizontal, 24)
    }

    private var pendingBanner: some View {
        Button { showRequests = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark.fill")
                    .font(.title2).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connections.pending.count == 1 ? "1 connection request" : "\(connections.pending.count) connection requests")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("Tap to review who wants to connect").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.85))
            }
            .padding(14)
            .background(HavenTheme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var storiesTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { showStoryCamera = true } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().strokeBorder(HavenTheme.brandHorizontal, lineWidth: 2).frame(width: 62, height: 62)
                            Image(systemName: "camera.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                        }
                        Text("Add").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                ForEach(Array(store.groupedStories.enumerated()), id: \.element.author) { gi, group in
                    Button { storyIndex = store.storyStartIndex(forGroup: gi); showStories = true } label: {
                        VStack(spacing: 6) {
                            storyThumb(group.items.last ?? group.items[0])   // latest as the cover
                            Text((group.items.first?.isMe ?? false) ? "You" : (ContactsStore.shared.name(forNodePrefix: group.author) ?? friendName))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
        }
    }

    private func storyThumb(_ s: FeedItemFfi) -> some View {
        // The ring identifies WHOSE story it is → show the sharer's profile picture (mine, or the
        // friend's synced avatar), not the story media itself. Resolved the same way as avatars
        // everywhere else so it stays in sync.
        ZStack {
            Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
            if s.isMe {
                HavenAvatar(image: ProfileStore.shared.avatar, emoji: ProfileStore.shared.emoji, size: 56)
            } else {
                PeerAvatar(nodeHex: s.authorShort,
                           name: ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName, size: 56)
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Circle().fill(store.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(connectionText)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private var connectionText: String {
        guard store.online else { return "Offline — posts sync when you reconnect" }
        var paths: [String] = []
        if store.internetActive { paths.append("internet") }
        if store.nearbyActive { paths.append("nearby") }
        if paths.isEmpty { return "Online — looking for your circle…" }
        return "Connected · " + paths.joined(separator: " + ")
    }

    private var composerBar: some View {
        VStack { Spacer()
            VStack(spacing: 8) {
                // Delivery status for this circle: green = safely in your relay / reached a member,
                // yellow = still syncing, red = only on this device. So you know if a post got out.
                // Delivery light: tap the yellow/red pill to dive into live sync detail (sent/received/waiting).
                HStack { Spacer(); SyncStatusBadge(circleId: store.activeCircleId) }
                MediaProcessingCard()   // spinner while a video encodes — see MediaProcessing
                if !attachedMedia.isEmpty || attachedTrack != nil || composeRetention != nil { attachmentTray }
                // Opt-in location tag — only when a photo/video with GPS is attached. Default off.
                if MediaStore.shared.anyLocated(attachedMedia) {
                    Toggle(isOn: $showLocation) {
                        Label("Show location", systemImage: "mappin.and.ellipse").font(.caption.weight(.medium))
                    }
                    .tint(HavenTheme.pink)
                    .padding(.horizontal, 4)
                }
                HStack(spacing: 10) {
                    Menu {
                        Button { showMediaPicker = true } label: { Label("Photo or Video", systemImage: "photo.on.rectangle") }
                        Button {
                            #if os(iOS)
                            showFilesImporter = true   // Files app
                            #else
                            showFilePicker = true       // macOS file browser (NSOpenPanel)
                            #endif
                        } label: { Label("Files…", systemImage: "folder") }
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                        Button { showSongPicker = true } label: { Label("Add a song", systemImage: "music.note") }
                        Button { showLocationPicker = true } label: { Label("Pin a location", systemImage: "mappin.and.ellipse") }
                        Divider()
                        Menu {
                            Button("Off") { composeRetention = nil }
                            Button("1 hour") { composeRetention = 3_600 }
                            Button("1 day") { composeRetention = 86_400 }
                            Button("1 week") { composeRetention = 604_800 }
                        } label: { Label("Disappears after…", systemImage: "timer") }
                        if !compose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedMedia.isEmpty {
                            Button { showSchedule = true } label: { Label("Send later…", systemImage: "clock") }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title).foregroundStyle(HavenTheme.pink)
                    }
                    .accessibilityIdentifier("attachMenu")
                    .menuIndicator(.hidden)   // no macOS disclosure chevron next to the + button
                    #if os(macOS)
                    .menuStyle(.borderlessButton)   // drop the rectangular button chrome — just the circle
                    .fixedSize()
                    #endif

                    TextField("Share something…", text: $compose, axis: .vertical)
                        .accessibilityIdentifier("composeField")
                        .focused($composeFocused)
                        .textFieldStyle(.plain)   // drop the macOS system focus ring/border — matches iOS
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        // ONE glass surface. A fixed-radius rounded rect (not havenPillField's Capsule):
                        // a Capsule's radius grows with height and clips into the text once the field
                        // wraps to multiple lines.
                        .havenGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Button { send() } label: {
                        Image(systemName: "paperplane.fill").foregroundStyle(.white)
                            .padding(13).background(HavenTheme.brand, in: Circle())
                            .shadow(color: HavenTheme.pink.opacity(0.4), radius: 8, y: 4)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("composeSend")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            // NO band behind the composer: a material slab here read as a detached grey bar pasted
            // under the gradient. The field / + / send each carry their own surface and float over
            // the backdrop instead. contentShape keeps the whole bar a drop target without one.
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if dropActive {
                    Rectangle().fill(HavenTheme.pink.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(HavenTheme.pink, style: StrokeStyle(lineWidth: 2, dash: [6])))
                        .overlay(Label("Drop to attach", systemImage: "tray.and.arrow.down.fill").font(.subheadline.weight(.semibold)).foregroundStyle(HavenTheme.pink))
                        .allowsHitTesting(false)
                }
            }
            // Drag media in from Finder / Files / Photos and it becomes attachments on the next post.
            .onDrop(of: [.image, .movie, .fileURL], isTargeted: $dropActive) { providers in
                handleComposerDrop(providers)
            }
        }
    }

    /// Load dropped images/videos into MediaStore and attach them to the composer. Returns true if at
    /// least one provider is a media type we can ingest.
    private func handleComposerDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                handled = true
                p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url else { return }
                    // The provided URL is a short-lived temp; copy it before the closure returns.
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drop_\(UUID().uuidString).\(ext)")
                    try? FileManager.default.copyItem(at: url, to: tmp)
                    Task { @MainActor in
                        let bundle = await MediaStore.shared.prepareVideo(url: tmp)
                        // prepareVideo returns empty mediaRefs when it REFUSES the clip (over the
                        // 15-minute limit). Appending nothing is correct — never attach an empty ref.
                        guard !bundle.isEmpty else { return }
                        attachedMedia.append(contentsOf: bundle.mediaRefs)
                    }
                }
            } else if p.canLoadObject(ofClass: PlatformImage.self) {
                handled = true
                _ = p.loadObject(ofClass: PlatformImage.self) { obj, _ in
                    guard let img = obj as? PlatformImage else { return }
                    Task { @MainActor in attachedMedia.append(MediaStore.shared.addImage(img)) }
                }
            }
        }
        return handled
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Hide synthetic markers and original companions from the tray — they ride with
                // the playable ref and would just look like duplicate chips.
                ForEach(MediaVariants.displayRefs(attachedMedia), id: \.self) { ref in
                    attachmentChip(ref)
                }
                if let track = attachedTrack {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                        Text(track.title).font(.caption2).lineLimit(1)
                        Button { attachedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(HavenTheme.brandHorizontal.opacity(0.18), in: Capsule())
                }
                // Per-post video audio: only meaningful with a video and no song (a song
                // always plays over a muted video). Toggles between the video's own sound
                // and a silent share.
                if attachedTrack == nil && attachedMedia.contains(where: { MediaStore.shared.item($0)?.kind == .video }) {
                    Button { muteVideo.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: muteVideo ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            Text(muteVideo ? "Video muted" : "Video sound").font(.caption2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(muteVideo ? AnyShapeStyle(.secondary) : AnyShapeStyle(HavenTheme.pink))
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let secs = composeRetention {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text("Disappears: \(Self.retentionLabel(secs))").font(.caption2).lineLimit(1)
                        Button { composeRetention = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
    }

    /// One tile in the composer's attachment tray. See `ComposerAttachmentTile` for why every
    /// attachment draws one whether or not it has a picture to show.
    @ViewBuilder private func attachmentChip(_ ref: String) -> some View {
        if SharedLocation.parse(ref) != nil {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 2) {
                    Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                    Text("Location").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                removeChip { attachedMedia.removeAll { $0 == ref } }
            }
        } else {
            ZStack(alignment: .topTrailing) {
                ComposerAttachmentTile(ref: ref, media: attachedMedia)
                    .overlay(alignment: .bottomLeading) {
                        // Trim/mute stay reachable from the tile even when the tile is a glyph — the
                        // clip is attached either way, so its controls apply either way.
                        if MediaKind(ref: ref) == .video { videoEditMenu(ref) }
                    }
                removeChip { removeAttachment(ref) }
            }
        }
    }

    /// Drop an attachment AND every companion tied to it — a poster or original left behind would
    /// ride along on the next post with no playable ref to belong to.
    private func removeAttachment(_ ref: String) {
        attachedMedia.removeAll { r in
            if r == ref { return true }
            if let p = MediaVariants.parsePoster(r), p.video == ref || p.poster == ref { return true }
            if let o = MediaVariants.parseOriginal(r), o.optimized == ref || o.original == ref { return true }
            if let t = MediaVariants.parseThumb(r), t.content == ref || t.thumb == ref { return true }
            if MediaVariants.poster(for: ref, in: attachedMedia) == r { return true }
            if MediaVariants.original(for: ref, in: attachedMedia) == r { return true }
            if MediaVariants.thumb(for: ref, in: attachedMedia) == r { return true }
            return false
        }
    }

    private static func retentionLabel(_ secs: UInt64) -> String {
        switch secs {
        case ..<3_600: return "\(secs / 60)m"
        case ..<86_400: return "\(secs / 3_600)h"
        case ..<604_800: return "\(secs / 86_400)d"
        default: return "\(secs / 604_800)w"
        }
    }

    private func removeChip(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.white)
                .background(Circle().fill(.black.opacity(0.5)))
        }
        .buttonStyle(.plain)   // the glyph IS the circle — no macOS bezel behind it
        .padding(3)
    }

    private func videoEditMenu(_ ref: String) -> some View {
        Menu {
            if MediaStore.shared.canTrim(ref) {
                Button { trimmingRef = TrimTarget(ref: ref) } label: { Label("Trim", systemImage: "scissors") }
            }
            Button { muteVideo.toggle() } label: {
                Label(muteVideo ? "Play video sound" : "Mute video sound",
                      systemImage: muteVideo ? "speaker.wave.2" : "speaker.slash")
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.white)
                .padding(4).havenGlass(in: Circle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)   // just the glass circle — no popup-button bezel behind it
        .fixedSize()
        #endif
        .padding(3)
    }

    private func replaceAttached(_ old: String, with new: String) {
        if let i = attachedMedia.firstIndex(of: old) { attachedMedia[i] = new }
    }

    /// Queue the current composer contents to post at a future time, then clear the field.
    private func scheduleCurrentPost(at date: Date) {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedMedia.isEmpty else { return }
        ScheduledStore.shared.schedule(circleId: store.activeCircleId, isDM: false, body: text, media: attachedMedia, at: date)
        compose = ""; attachedMedia = []; attachedTrack = nil; composeRetention = nil; muteVideo = false; showLocation = false
        composeFocused = false
    }

    private func send() {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedMedia.isEmpty || attachedTrack != nil else { return }
        // Sender-side check: if on-device Sensitive Content Analysis flags an attachment, ask before
        // sending. (Only when the user has SCA on; otherwise post straight away.)
        let media = attachedMedia
        guard SensitiveContentScanner.shared.isEnabled, !media.isEmpty else { doSend(flagged: []); return }
        Task { @MainActor in
            var flagged: [String] = []
            for ref in media where await SensitiveContentScanner.shared.isSensitive(ref: ref) { flagged.append(ref) }
            if flagged.isEmpty { doSend(flagged: []) } else { pendingSensitive = flagged }
        }
    }

    /// Actually post, then federate a flag for any attachment confirmed sensitive so recipients
    /// without SCA (Android/desktop) blur it too. If "Show location" is on, a photo's GPS is
    /// reverse-geocoded into a tappable map pin attached to the post.
    private func doSend(flagged: [String]) {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        // Snapshot compose state, then clear the UI immediately (the geocode is async).
        let base = attachedMedia, track = attachedTrack, retention = composeRetention, mute = muteVideo
        let wantLocation = showLocation
        let cid = store.activeCircleId
        compose = ""; attachedMedia = []; attachedTrack = nil; composeRetention = nil; muteVideo = false
        showLocation = false; composeFocused = false
        Task { @MainActor in
            var media = base
            if wantLocation,
               let located = base.first(where: { MediaStore.shared.location(for: $0) != nil }),
               let coord = MediaStore.shared.location(for: located) {
                let name = await SharedLocation.placeName(coord)
                media.insert(SharedLocation.ref(lat: coord.latitude, lon: coord.longitude, label: name), at: 0)
            }
            store.post(text, media: media, music: track, retentionSecs: retention, muteVideo: mute)
            for ref in flagged { store.flagSensitive(circleId: cid, ref: ref) }
        }
    }
}

/// The feed column's content width, remembered across cards. Every PostCard in a feed lays out at the
/// SAME width, but each one is created as it scrolls into view with its own `@State` starting at zero —
/// and a zero width made `pageHeight` fall back to `singleMediaMaxHeight`, so the card first rendered at
/// full height and then snapped to its real aspect the instant the width preference landed. That resize,
/// once per card, is what made the feed jump up and down during a scroll (for photos as much as videos).
/// Seeding a new card from the last measured width lets it compute the correct height on its FIRST pass.
/// Written and read only from SwiftUI layout on the main thread.
nonisolated(unsafe) var lastKnownMediaWidth: CGFloat = 0

/// EQUATABLE so SwiftUI can SKIP a row whose content did not change.
///
/// `FeedStore.items` republishes on every feed rebuild — a mailbox pull, a poster landing, a
/// periodic tick — and each republish re-initialises every PostCard in the list, re-evaluating a
/// 1,507-line body per visible row. A Time Profiler trace of a warm phone is 83% main thread with no
/// single hot leaf: AG::Graph::propagate_dirty marking subtrees, swift_getGenericMetadata and
/// LockingConcurrentMap re-instantiating deeply nested generic view types, ARC churn. That is rows
/// rebuilding wholesale, and it is why deleting expensive calls from inside `body` (storageDir,
/// shareURL) measurably helped and did not fix it.
///
/// With `.equatable()` at the call site, a republish carrying an IDENTICAL item skips the body
/// entirely. The closures are deliberately NOT compared — they are recreated on every parent render
/// and capture only the store plus `item.id`, so two cards with an equal `item` have behaviourally
/// identical callbacks. Comparing them is impossible anyway (functions are not Equatable), and
/// treating them as significant would defeat the whole optimisation.
///
/// This does NOT stop the card's own @ObservedObject stores from invalidating it — that is the next
/// step, pushing `feed`/`audio`/`pinned`/`profile` down into the leaf views that read them.
/// My own avatar, as its OWN view so it — and not its 1,507-line host — is what a ProfileStore
/// publish invalidates.
///
/// PostCard observed ProfileStore for exactly these two call sites. Because @ObservedObject
/// subscribes the WHOLE view, changing an avatar re-evaluated every visible card's entire body. A
/// trace after making rows Equatable showed generic-metadata instantiation down 36% but
/// AG::Graph::UpdateStack::update FLAT — parent-driven rebuilds were being skipped while the card's
/// own store subscriptions kept dirtying it directly. This is the first of those four moved down.
struct MyAvatar: View {
    let size: CGFloat
    @ObservedObject private var profile = ProfileStore.shared
    var body: some View { HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: size) }
}

extension PostCard: Equatable {
    static func == (a: PostCard, b: PostCard) -> Bool {
        a.item == b.item
            && a.friendName == b.friendName
            && a.expandAllComments == b.expandAllComments
    }
}

/// A post's reaction chips + quick-react buttons.
///
/// Extracted from PostCard, which was a single ~1,600-line `body`. SwiftUI instantiates that whole
/// generic tree every time a row appears, which is the cost that remains once invalidation churn is
/// gone: measured at 21-34 body evaluations per second while scrolling. Smaller views are cheaper to
/// build, are re-evaluated only when THEIR inputs change, and are far easier to read than a nested
/// block four levels inside another view.
///
/// It owns its own sheet state — `showPicker`/`showDetail` were @State on PostCard used nowhere but
/// here, so presenting a picker re-evaluated the entire card.
struct PostReactionsRow: View {
    let reactions: [ReactionFfi]
    let onReact: (String) -> Void
    let onUnreact: (String) -> Void
    @State private var showPicker = false
    @State private var showDetail = false

    private var visible: [ReactionFfi] { PostCard.cappedReactions(reactions, cap: 4) }
    private var hiddenCount: Int { max(0, reactions.count - visible.count) }
    private func react(_ e: String) { EmojiStore.shared.record(e); onReact(e) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(visible, id: \.emoji) { r in
                // Tap a chip to toggle your own reaction; press-and-hold to see who reacted.
                HStack(spacing: 3) {
                    Text(r.emoji).font(.caption)
                    Text("\(r.count)").font(.caption2.weight(.semibold).monospacedDigit())
                        // PINK COUNT ON A PINK CAPSULE IS INVISIBLE.
                        //
                        // Both the chip tint and the count read "this one is yours", so the count was
                        // drawn in the same pink as the capsule behind it and the number disappeared
                        // into its own background. The capsule already carries that meaning; the
                        // number's job is to be READ. `.primary` keeps it legible over the tinted
                        // glass in both light and dark, and the chip is still obviously yours.
                        .foregroundStyle(r.mine ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                // One glass capsule, tinted pink when it's YOUR reaction.
                .havenGlass(in: Capsule(), tint: r.mine ? HavenTheme.pink : nil)
                .contentShape(Capsule())
                .onTapGesture { if r.mine { onUnreact(r.emoji) } else { react(r.emoji) } }
                .onLongPressGesture(minimumDuration: 0.3) { showDetail = true }
                .transition(.scale.combined(with: .opacity))
            }
            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .havenGlass(in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { showDetail = true }
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 8)
            ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                Button(e) { react(e) }.font(.body).buttonStyle(PressableStyle())
            }
            Button { showPicker = true } label: {
                Image(systemName: "plus.circle").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .animation(HavenTheme.bouncy, value: reactions.count)
        .sheet(isPresented: $showPicker) { ReactionPicker { e in onReact(e) } }
        .sheet(isPresented: $showDetail) {
            ReactionDetailView(reactions: reactions, onUnreact: { e in onUnreact(e) })
        }
    }
}

/// The "Add a reply…" composer for one post: attachments, text field, send.
///
/// Extracted from PostCard. It owns everything it needs — draft text, staged attachments, the two
/// sheet flags and the focus state — none of which any other part of the card read. As @State on a
/// ~1,600-line view, TYPING A CHARACTER re-evaluated the whole card body; now it re-evaluates a text
/// field. The keyboard-avoidance callback still reports upward, because the feed (not the card) owns
/// the scroll proxy that lifts the post.
struct PostCommentField: View {
    let onSubmit: (String, [String]) -> Void
    var onFocus: ((Bool) -> Void)?

    @State private var text = ""
    @State private var media: [String] = []
    @State private var showMediaPicker = false
    @State private var showAudioRecorder = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(media, id: \.self) { attachChip($0) } }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    Button { showMediaPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                    Button { showAudioRecorder = true } label: { Label("Audio reply", systemImage: "mic") }
                } label: { Image(systemName: "paperclip").foregroundStyle(.secondary) }
                .menuIndicator(.hidden)   // no macOS disclosure chevron next to the paperclip
                #if os(macOS)
                .menuStyle(.borderlessButton).fixedSize()
                #endif
                TextField("Add a reply…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)   // drop the macOS system focus ring — matches iOS
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .focused($focused)
                    // Report focus up so the feed lifts this post above the keyboard AND hides the
                    // "Share something" composer (which otherwise floats over the comment).
                    .onChange(of: focused) { _, f in onFocus?(f) }
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large).foregroundStyle(HavenTheme.pink)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .sheet(isPresented: $showMediaPicker) { MediaPicker { refs in media.append(contentsOf: refs) }.macSheetFrame() }
        .sheet(isPresented: $showAudioRecorder) { AudioRecorderView { ref in media.append(ref) }.macSheetFrame() }
    }

    private func attachChip(_ ref: String) -> some View {
        let m = MediaStore.shared.item(ref)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let img = m?.image { Image(platformImage: img).resizable().scaledToFill() }
                else { Image(systemName: "waveform").frame(maxWidth: .infinity, maxHeight: .infinity).background(HavenTheme.brandHorizontal.opacity(0.25)) }
            }
            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            Button { media.removeAll { $0 == ref } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white).background(Circle().fill(.black.opacity(0.5)))
            }
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !media.isEmpty else { return }
        onSubmit(t, media)
        text = ""; media = []
    }
}

/// A post's header: avatar, author, timestamp, backup state and the overflow menu.
///
/// 265 lines lifted out of PostCard — the single largest block in it. It observes PinnedMediaStore
/// itself, so a pin toggle invalidates a header rather than a whole card, and it owns
/// showBackupDetail (nothing else read it). The sheets it OPENS stay on the card, because the card
/// is what presents them, so those arrive as bindings.
struct PostHeader: View {
    let item: FeedItemFfi
    let friendName: String
    let authorName: String
    let storyableMedia: [String]
    let onUnsend: () -> Void
    @Binding var showEdit: Bool
    @Binding var showReport: Bool
    @Binding var storyShare: StoryShareTarget?
    @ObservedObject private var pinned = PinnedMediaStore.shared
    @State private var showBackupDetail = false
    @State private var linkCopied = false

    @ViewBuilder private var avatar: some View {
        if item.isMe { MyAvatar(size: 34) }
        else { PeerAvatar(nodeHex: item.authorShort, name: authorName, size: 34) }
    }

    var body: some View {
        HStack(spacing: 10) {
            if item.isMe {
                avatar
                Text(authorName).font(.subheadline.weight(.semibold))
            } else {
                NavigationLink {
                    UserProfileView(authorHex: item.authorShort, name: authorName)
                } label: {
                    HStack(spacing: 10) {
                        avatar
                        Text(authorName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
            Text(relativeTimeShort(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
            if item.edited {
                Text("edited").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
            }
            // Kept on THIS device. Without a mark on the card, "Keep on this device" recorded the pin
            // and showed nothing — the menu closed and the post looked identical, so a working toggle
            // read as a dead button. This is the state, visible where the decision applies.
            if item.media.contains(where: { !MediaStore.isSynthetic($0) && pinned.isPinned($0) }) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(HavenTheme.pink)
                    .accessibilityLabel("Kept on this device")
            }
            // Upload state for YOUR OWN media posts — ALWAYS shown when there is media, even if this
            // device knows zero relays. Gating on "has a relay" hid the indicator entirely when a
            // friend never learned frame-19 (or only had LAN media URLs), so "not syncing" looked
            // identical to "nothing to show" and previously shared content appeared fine while no
            // relay ever got a copy. Driven PER-MEDIA off the backup ledger + queue.
            if item.isMe && !item.unsent, !item.media.isEmpty {
                // The whole cluster is one tap target: every state below is a partial answer to
                // "where is this?", and the sheet is the full one — including which relays hold
                // nothing, which no icon can express.
                // TICK ONLY WHILE SOMETHING CAN CHANGE.
                //
                // This cluster re-rendered every second for every one of YOUR OWN media posts on
                // screen — forever, including posts uploaded months ago where the answer is fixed.
                // On the You feed every cell is yours, so the app never stopped recomputing upload
                // state on the main thread: a warm phone sitting idle, and a feed that stutters
                // while scrolling because each frame competes with this work.
                //
                // A post confirmed on a relay someone else can read is DONE — content-addressed
                // blobs never change, so that verdict cannot be revoked. Those fall back to an
                // hourly tick (a timer that effectively never fires) instead of a per-second one.
                // Anything still in flight keeps the 1s cadence, which is the case the ring and the
                // percentage were built for.
                let settledOwnRelay = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
                let settledBlobs = item.media.filter { !MediaStore.isSynthetic($0) }
                let settled = !settledBlobs.isEmpty && settledBlobs.allSatisfy {
                    MediaBackupLedger.hasAnyRemote($0, ownRelayHex: settledOwnRelay)
                }
                // TICK ONLY WHILE AN UPLOAD IS GENUINELY IN FLIGHT.
                //
                // A Time Profiler trace of a warm phone (47s, iPhone 17 Pro Max) is ~half
                // AG::Graph::UpdateStack::update / update_attribute / input_value_ref_slow with
                // CA::Layer::commit_if_needed and LayoutEngineBox.sizeThatFits behind them: SwiftUI's
                // attribute graph being dirtied over and over and re-running layout. Not media
                // decode, not networking — the earlier fixes in this release were all treating
                // network symptoms of a RENDERING problem.
                //
                // Each of these timers dirties its subtree, and a subtree invalidation drags a layout
                // pass across the list. Gating on `settled` alone was not enough: a post that is not
                // backed up AND has nothing queued (no relay known, upload long since abandoned) also
                // ticked every second while its answer was every bit as fixed.
                //
                // So the 1s cadence — which exists for the progress ring and percentage — now applies
                // ONLY when the queue actually holds one of this post's blobs. hasPending is O(1)
                // now, so asking is free. Everything else falls to an hourly tick that effectively
                // never fires, and re-renders when its own state publishes instead.
                let inFlight = !settled && settledBlobs.contains { MediaBackupQueue.shared.hasPending($0) }
                TimelineView(.periodic(from: .now, by: inFlight ? 1.0 : 3600)) { _ in
                    let blobs = item.media.filter { !MediaStore.isSynthetic($0) }
                    let circleId = FeedStore.shared.activeCircleId
                    let hasRelay = !RelayMailboxStore.shared.relays(forCircle: circleId).isEmpty
                        || SharedStore.hasMailbox(circleId)
                    // "Backed up" must mean a relay SOMEONE ELSE can read. Writing to our own
                    // in-process relay is a local file copy that cannot fail, so counting it showed a
                    // confident tick on every post while friends could fetch none of them.
                    let ownRelay = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
                    let backed = !blobs.isEmpty && blobs.allSatisfy {
                        MediaBackupLedger.hasAnyRemote($0, ownRelayHex: ownRelay)
                    }
                    // Reached OUR relay and nowhere else: not an error, not safe either. Says so.
                    let localOnly = !backed && !blobs.isEmpty && blobs.allSatisfy { MediaBackupLedger.hasAny($0) }
                    let pending = blobs.contains { MediaBackupQueue.shared.hasPending($0) }
                    let progress = MediaUploadProgress.shared.fraction(for: blobs)
                    let stuck = MediaUploadProgress.shared.looksStuck(blobs)
                        || (!backed && !hasRelay)
                        || (!backed && !pending && !localOnly && !blobs.isEmpty)
                    if backed {
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.caption2).foregroundStyle(HavenTheme.pink)
                            .help("Backed up to a relay others can read")
                    } else if !hasRelay {
                        // The invisible case: no known mailbox → never showed an icon before.
                        Image(systemName: "exclamationmark.icloud")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("No relay known for this circle — media stays on this device only. Open Relays or wait for a member who hosts one.")
                    } else if localOnly {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("Only on this device's own relay — nobody else can fetch it yet")
                    } else if let progress {
                        // A real fraction, because a big video genuinely takes minutes and a motionless
                        // arrow made "slow" and "broken" look identical. Determinate ring + percentage.
                        ZStack {
                            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                            Circle().trim(from: 0, to: max(0.02, progress))
                                .stroke(stuck ? Color.orange : HavenTheme.pink,
                                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 12, height: 12)
                        .help(stuck
                              ? "Still trying to upload — it has restarted several times"
                              : "Uploading to a relay… \(Int(progress * 100))%")
                    } else {
                        // Queued but no window has been written yet (or the blob is small enough to go
                        // in one shot). Orange once it has restarted repeatedly: the queue never gives
                        // up, so without this an upload that can never succeed looks like one about to.
                        Image(systemName: stuck ? "exclamationmark.icloud" : "arrow.up.circle")
                            .font(.caption2)
                            .foregroundStyle(stuck ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.secondary))
                            .help(stuck
                                  ? (hasRelay
                                     ? "Upload not reaching a relay yet — tap for detail; keep Haven open"
                                     : "No relay available — media only on this device")
                                  : "Waiting to upload to a relay…")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showBackupDetail = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows which relays hold a copy")
                .sheet(isPresented: $showBackupDetail) {
                    BackupDetailView(refs: item.media.filter { !MediaStore.isSynthetic($0) },
                                     circleId: FeedStore.shared.activeCircleId)
                        .macSheetFrame()
                        #if os(iOS)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        #endif
                }
            }
            Spacer()
            if !item.unsent {
                Menu {
                    // No link for a story (gone by the time anyone taps it) or a DM — a dm: circle
                    // id is literally both members' node ids, so the link would leak the pair to
                    // whoever you sent it to, and nobody outside the DM could ever open it anyway.
                    if !item.story, !FeedStore.shared.activeCircleId.hasPrefix("dm:"),
                       let url = DeepLink.postURL(circleId: FeedStore.shared.activeCircleId, postId: item.id) {
                        ShareLink(item: url) { Label("Share post", systemImage: "square.and.arrow.up") }
                        Button {
                            PlatformPasteboard.string = url.absoluteString
                            linkCopied = true
                            // Unlike the app's other copy buttons this one has to un-stick: the menu
                            // closes on tap, so a reopen a minute later must not still read "Copied".
                            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); linkCopied = false }
                        } label: {
                            Label(linkCopied ? "Copied" : "Copy link",
                                  systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                        }
                        // Reshare the post as a 24h story that links back to it. Deliberately inside the
                        // same guard as the link actions: a story goes to the ACTIVE circle (see
                        // FeedStore.post), and this post is IN the active circle, so everyone who can see
                        // the story can already open the post. That is the whole access story — the embed
                        // carries no key, and we never widen the audience beyond the circle.
                        if !storyableMedia.isEmpty {
                            Button {
                                storyShare = StoryShareTarget(
                                    draft: StoryDraft(refs: storyableMedia),
                                    embed: StoryEmbed.Ref(circleId: FeedStore.shared.activeCircleId,
                                                          postId: item.id, musicStartMs: 0))
                            } label: { Label("Share as story", systemImage: "circle.dashed.inset.filled") }
                        }
                    }
                    // Reply to the AUTHOR privately, the same move a story reply makes: open (or
                    // reuse) the DM with them and carry the post's media so they know which post
                    // you mean. Never available on your own post — that would DM yourself.
                    if !item.isMe, let authorHex = ContactsStore.shared.idHex(forNodePrefix: item.authorShort) {
                        Button {
                            // Stage a draft; do NOT send. Referencing a post is the START of a
                            // message, not one — the point is to ask them something about it, so
                            // the link goes in the composer and the words stay yours. Opens the
                            // real DM thread in Messages rather than switching the circle, which
                            // would drop you into the feed layout instead of the conversation.
                            let dm = FeedStore.shared.startDM(with: authorHex, name: authorName)
                            let ref = DeepLink.postURL(circleId: FeedStore.shared.activeCircleId, postId: item.id)?
                                .absoluteString ?? ""
                            DMDraftStore.shared.stage(circleId: dm, text: ref)
                            DeepLinkRouter.shared.requestedTab = "messages"
                        } label: { Label("Message \(authorName)", systemImage: "bubble.left") }
                    }
                    if item.isMe {
                        Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { onUnsend() } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
                    }
                    // "Show original" only when the author actually sent an uncompressed companion.
                    // Hidden otherwise so the menu never offers a dead download.
                    let originalRefs = MediaVariants.allOriginals(in: item.media)
                        .filter { !MediaStore.shared.has($0) }
                    if !originalRefs.isEmpty {
                        Button {
                            for r in originalRefs {
                                FeedStore.shared.requestMedia(r, circleId: FeedStore.shared.activeCircleId)
                            }
                        } label: {
                            Label("Show original", systemImage: "arrow.down.circle")
                        }
                    } else if MediaVariants.allOriginals(in: item.media).contains(where: { MediaStore.shared.has($0) }) {
                        // Original already on disk — nothing to download; still surface so the user
                        // knows it's available (opens the zoom viewer on the original if present).
                        Button {
                            // Prefer opening the first available original in the media zoom path.
                            if let first = MediaVariants.allOriginals(in: item.media).first(where: { MediaStore.shared.has($0) }) {
                                // Nudge a refresh so any view observing the store re-reads the item.
                                FeedStore.shared.scheduleRefresh()
                                _ = first
                            }
                        } label: {
                            Label("Original available", systemImage: "checkmark.circle")
                        }
                    }
                    // Keep the post's photos/videos on THIS device so no cleanup (orphan sweep, age/size
                    // limit, or the Manage-media screen) ever removes their bytes. Pins every real media
                    // ref on the post at once — this is the discoverable home for the per-image long-press
                    // "Keep on this device" the storage screen advertises.
                    let keepRefs = item.media.filter { !MediaStore.isSynthetic($0) }
                    if !keepRefs.isEmpty {
                        // `pinned` (observed) rather than the singleton, so flipping this re-renders
                        // the card and its badge — the toggle has to be visible to be believed.
                        let anyPinned = keepRefs.contains { pinned.isPinned($0) }
                        Button { pinned.togglePin(keepRefs) } label: {
                            Label(anyPinned ? "Stop keeping on this device" : "Keep on this device",
                                  systemImage: anyPinned ? "pin.slash.fill" : "pin")
                        }
                    }
                    // Hide any post from my own feed (reversible). Local + per-device.
                    let isHidden = HiddenStore.shared.isHidden(item.id)
                    Button {
                        if isHidden { HiddenStore.shared.unhide(item.id) } else { HiddenStore.shared.hide(item.id) }
                        FeedStore.shared.refresh()
                    } label: { Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash") }
                    if !item.isMe {
                        Button(role: .destructive) { showReport = true } label: {
                            Label("Report", systemImage: "flag")
                        }
                    }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(6) }
                .menuIndicator(.hidden)
                #if os(macOS)
                .menuStyle(.borderlessButton)   // else macOS paints a rounded-rect bezel behind the glyph
                .fixedSize()
                #endif
            }
        }
    }
}

/// A post's inline comments: rows, per-comment reactions, attachments and the "show all" sheet.
///
/// The last big block out of PostCard. It owns showAllComments and commentReactTarget — @State that
/// nothing outside the comment list read, so opening a reaction picker used to re-evaluate the whole
/// card. Editing still belongs to the card (it presents the alert), so that arrives as a callback
/// rather than three bindings.
struct PostCommentsList: View {
    let item: FeedItemFfi
    let friendName: String
    let expandAllComments: Bool
    /// The comment a deep link named (see `PostCard.highlightCommentId`) — tinted, never hidden
    /// behind "show all".
    var highlightCommentId: String? = nil
    let onReact: (String) -> Void
    let onUnreact: (String) -> Void
    let onComment: (String, [String]) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void
    let onEditComment: (FeedCommentFfi) -> Void

    @State private var showAllComments = false
    @State private var commentReactTarget: PostCard.CommentReactTarget?


    private func commentAuthorName(_ c: FeedCommentFfi) -> String {
        if c.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: c.authorShort) ?? friendName
    }

    var body: some View {
        // Inline we show at most 3; the "show all" sheet shows every comment. A comment the caller
        // opened this post FOR is always among them — landing on the post but not the comment the
        // notification named would be its own small failure.
        var shown = expandAllComments ? item.comments : Array(item.comments.prefix(3))
        if let h = highlightCommentId, !shown.contains(where: { $0.id == h }),
           let linked = item.comments.first(where: { $0.id == h }) {
            shown.append(linked)
        }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(shown, id: \.id) { c in commentRow(c) }
            if !expandAllComments && item.comments.count > 3 {
                Button { showAllComments = true } label: {
                    Text("Show all \(item.comments.count) comments")
                        .font(.caption.weight(.semibold)).foregroundStyle(HavenTheme.pink)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $showAllComments) {
            PostCommentsSheet(item: item, friendName: friendName,
                              onReact: onReact, onUnreact: onUnreact, onComment: onComment, onEdit: onEdit, onUnsend: onUnsend)
                .macSheetFrame()
        }
        .sheet(item: $commentReactTarget) { t in
            ReactionPicker { e in FeedStore.shared.react(t.id, e) }
        }
    }

    @ViewBuilder private func commentRow(_ c: FeedCommentFfi) -> some View {
        HStack(alignment: .top, spacing: 8) {
            commentAuthorLink(c) { commentAvatar(c) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    commentAuthorLink(c) {
                        Text(commentAuthorName(c)).font(.caption.weight(.semibold))
                            .foregroundStyle(c.isMe ? HavenTheme.pink : .primary)
                    }
                    Text(relativeTimeShort(c.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                    if c.edited && !c.unsent { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                }
                if c.unsent {
                    Text("unsent").font(.caption).italic().foregroundStyle(.secondary)
                } else if !c.body.isEmpty {
                    LinkedText(text: c.body, font: .caption)
                    if let url = LinkScanner.urls(in: c.body).first { LinkPreviewCard(url: url).padding(.top, 6) }
                }
                if !c.unsent && !c.media.isEmpty { commentMediaRow(c.media) }
                if !c.unsent { commentReactionsRow(c) }
            }
        }
        .padding(highlightCommentId == c.id ? 6 : 0)
        .background {
            if highlightCommentId == c.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HavenTheme.pink.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(HavenTheme.pink.opacity(0.35)))
            }
        }
        .contextMenu {
            if !c.unsent {
                // Flat rows, each reacting on TAP. A ControlGroup here collapsed into a
                // "❤️ 😎 👍 ›" SUBMENU on macOS: it showed the emoji, then made you open a
                // second menu to actually pick one.
                ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                    Button("React \(e)") { EmojiStore.shared.record(e); FeedStore.shared.react(c.id, e) }
                }
                Button { commentReactTarget = PostCard.CommentReactTarget(id: c.id) } label: { Label("More reactions…", systemImage: "face.smiling") }
                if c.isMe {
                    if !c.body.isEmpty {
                        Button { onEditComment(c) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) { FeedStore.shared.unsend(c.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    @ViewBuilder private func commentReactionsRow(_ c: FeedCommentFfi) -> some View {
        // Cap the chips (most-reacted first, always keep mine) so a comment can't flood its row.
        let visible = PostCard.cappedReactions(c.reactions, cap: 5)
        let hidden = max(0, c.reactions.count - visible.count)
        HStack(spacing: 4) {
            ForEach(visible, id: \.emoji) { r in
                Text("\(r.emoji)\(r.count > 1 ? " \(r.count)" : "")")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(r.mine ? AnyShapeStyle(HavenTheme.brandHorizontal.opacity(0.22)) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                    .overlay(Capsule().strokeBorder(r.mine ? HavenTheme.pink.opacity(0.5) : .clear))
                    .contentShape(Capsule())
                    .onTapGesture {
                        if r.mine { FeedStore.shared.unreact(c.id, r.emoji) }
                        else { EmojiStore.shared.record(r.emoji); FeedStore.shared.react(c.id, r.emoji) }
                    }
            }
            if hidden > 0 {
                Text("+\(hidden)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
            }
            Button { commentReactTarget = PostCard.CommentReactTarget(id: c.id) } label: {
                Image(systemName: "face.smiling").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .animation(HavenTheme.bouncy, value: c.reactions.count)
    }

    @ViewBuilder private func commentAvatar(_ c: FeedCommentFfi) -> some View {
        if c.isMe {
            MyAvatar(size: 24)
        } else {
            PeerAvatar(nodeHex: c.authorShort, name: commentAuthorName(c), size: 24)
        }
    }

    @ViewBuilder private func commentAuthorLink<Content: View>(_ c: FeedCommentFfi, @ViewBuilder _ content: () -> Content) -> some View {
        if c.isMe {
            content()
        } else {
            NavigationLink {
                UserProfileView(authorHex: c.authorShort, name: commentAuthorName(c))
            } label: { content() }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func commentMediaRow(_ refs: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(refs, id: \.self) { ref in
                if let m = MediaStore.shared.item(ref) {
                    switch m.kind {
                    case .audio:
                        if let u = m.videoURL { AudioPlayerPill(url: u) }
                    case .video:
                        if let img = m.image {
                            thumb(img).overlay(Image(systemName: "play.circle.fill").foregroundStyle(.white).font(.title3))
                        }
                    case .image:
                        if let img = m.image { thumb(img) }
                    case .file:
                        Image(systemName: "doc.zipper")
                            .frame(width: 56, height: 56)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func thumb(_ img: PlatformImage) -> some View {
        Image(platformImage: img).resizable().scaledToFill()
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Grid tile for a multi-image post — one slot of the masonry layout.
///
/// A leaf renderer with three inputs, lifted out of PostCard so a tile redraws without the card.
struct PostMasonryTile: View {
    let item: FeedItemFfi
    let media: [String]
    let ref: String
    let height: CGFloat
    @Binding var zoomTarget: ZoomTarget?
    @ObservedObject private var transfer = MediaTransferState.shared   // the download badge's source of truth

    var body: some View { tile(ref, height: height) }

    @ViewBuilder private func tile(_ ref: String, height: CGFloat) -> some View {
        // Use MediaKind(ref:) (a cheap string parse) for the play badge — NOT item(ref), which would
        // generate the video poster on the main thread as each tile scrolls into view (the scroll lag).
        //
        // The tile's WIDTH comes from the persisted pixel size (a dictionary lookup, no decode) and the
        // bitmap decodes off-main via FeedImage. This used to call the synchronous thumbnail(_:), which
        // decoded EVERY tile on the main thread in a single layout pass — on a 10+ photo post that was
        // the scroll jitter. The evicted/not-yet-downloaded cases are checked first so the common path
        // never has to decode anything just to decide what to draw.
        if EvictedMediaStore.shared.contains(ref) {
            // Deliberately evicted — a compact tap-to-download tile (not an endless spinner).
            Button { FeedStore.shared.downloadEvicted(ref) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill))
                    Image(systemName: transfer.downloading.contains(ref) ? "arrow.down.circle" : "arrow.down.circle.fill")
                        .font(.title2).foregroundStyle(HavenTheme.pink)
                }
                .frame(width: height * 1.2, height: height)
            }
            .buttonStyle(.plain)
        } else if MediaStore.shared.hasLocalFile(ref) {
            // Non-blocking aspect: a grid tile's aspect only sets its WIDTH inside a horizontal scroller,
            // so it can safely fill in late rather than stalling layout on a header read per tile.
            let known = MediaStore.shared.pixelSize(ref, allowSyncRead: false)
            let aspect = min(2.4, max(0.6, known.map { $0.width / max($0.height, 1) } ?? 4.0 / 3.0))
            FeedImage(ref: ref, maxDimension: height * 3, contentMode: .fill) {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12))
            }
                .frame(width: height * aspect, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .center) {
                    if MediaKind(ref: ref) == .video {
                        Image(systemName: "play.circle.fill").font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
                    }
                }
                // Blur media flagged sensitive — by this device's SCA or any circle member's
                // federated flag (protects viewers whose platform has no SCA).
                .sensitiveContentGuard(ref: ref, circleId: FeedStore.shared.activeCircleId, scan: !item.isMe)
                .onTapGesture {
                    let media = media
                    if let idx = media.firstIndex(of: ref) { zoomTarget = ZoomTarget(refs: media, index: idx) }
                }
        } else {
            // Not downloaded yet — a compact loading tile keeps the gallery layout intact.
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill))
                ProgressView()
            }
            .frame(width: height * 1.2, height: height)
        }
    }
}

/// Placeholder shown while a media ref has not landed yet (or cannot be fetched).
struct PostMediaPlaceholder: View {
    let item: FeedItemFfi
    let ref: String

    var body: some View { placeholder(ref) }

    @ViewBuilder func placeholder(_ ref: String) -> some View {
        MissingMediaPlaceholder(ref: ref, isVideo: MediaKind(ref: ref) == .video,
                                postContext: (circleId: FeedStore.shared.activeCircleId, postId: item.id,
                                              authorShort: item.authorShort),
                                mediaList: item.media)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// The carousel's page dots.
struct PostCarouselDots: View {
    let count: Int
    let currentPage: Int

    var body: some View { body(count) }

    func body(_ count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(.white.opacity(i == currentPage ? 0.95 : 0.4)).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }
}

// MARK: - Post media geometry helpers
//
// Free functions, not view methods: they read MediaStore and their arguments and nothing else, so
// living on PostCard only made a 1,600-line view longer. Pulling them out also makes it obvious that
// shareURL must never call item(ref) — see its comment; that was a main-thread bitmap decode per ref
// per layout pass, and it cost real scroll performance until this release.

@MainActor func postShareURL(_ ref: String) -> URL? {
    // NEVER `item(ref)` here — the rule mediaPageContent states two functions below, which this
    // was quietly breaking: item() DECODES THE BITMAP / generates the video poster ON THE MAIN
    // THREAD on a cache miss. shareURL is called from `body` for every media ref, so a scroll
    // paid a decode per ref per layout pass. In a Time Profiler trace of a warm phone this shows
    // as PostCard.shareURL at 957 samples with MediaStore.item at 964 and downsampled at 384,
    // all under PostCard.body.getter — the choppy scrolling and the heat.
    //
    // The on-disk path is derivable from the ref alone: storagePath builds <dir>/<ref>.<ext>
    // from MediaKind(ref:), which is pure string work and cannot decode anything. Video and
    // image resolve to the same file either way — `videoURL` was the same path for a video.
    MediaStore.shared.storagePath(for: ref)
    }

@MainActor func postLetterboxes(_ ref: String, in containerAspect: CGFloat) -> Bool {
    guard let sz = MediaStore.shared.pixelSize(ref), sz.height > 0 else { return true }
    return abs(sz.width / sz.height - containerAspect) > 0.02
    }

@MainActor func postSingleAspect(_ ref: String, in media: [String]) -> CGFloat {
    // Read pixel dimensions from the file header (ImageIO) — NOT item()?.image.size, which decoded the
    // whole bitmap on the main thread just to get an aspect ratio (a scroll hitch per single-media post).
    if let sz = MediaStore.shared.pixelSize(ref), sz.width > 0, sz.height > 0 {
        MediaAspectStore.shared.record(ref, aspect: sz.width / sz.height)
        return sz.width / sz.height
    }
    // Full bytes not here yet, but the tiny thumb companion may be — same aspect as the
    // original, so the placeholder reserves the REAL shape and the layout doesn't jump when
    // the full-size media lands.
    if let t = MediaVariants.thumb(for: ref, in: media),
       let sz = MediaStore.shared.pixelSize(t), sz.width > 0, sz.height > 0 {
        MediaAspectStore.shared.record(ref, aspect: sz.width / sz.height)
        return sz.width / sz.height
    }
    // REMEMBERED shape, before the 4:3 guess.
    //
    // This function decides a card's HEIGHT, and it used to answer differently over time for the
    // same post: 4:3 while nothing was on disk, then the true shape once a thumb landed. A card
    // that changes height is a card that shoves everything below it — and while media is arriving
    // (an import, a mailbox pull, a fresh join) that is happening constantly, ABOVE the reader as
    // well as below. That is the feed "jumping around", and no amount of throttling refreshes
    // addresses it, because the rebuild was never the thing moving the content.
    //
    // So once a ref's real shape is known it is remembered, and every later render agrees with the
    // first one — including after the blob is evicted, which used to snap the card back to 4:3.
    if let remembered = MediaAspectStore.shared.aspect(ref) { return remembered }
    return 4.0 / 3.0
    }

/// The "Keep on this device" pin toggle, as its own view.
///
/// It observes PinnedMediaStore ITSELF. PostCard used to, for these two lines alone — so pinning any
/// media anywhere invalidated every visible card, re-evaluating a ~1,600-line body to redraw one
/// menu label. The original comment ("through the OBSERVED store, so toggling re-renders the card")
/// had the right instinct and the wrong scope: what must re-render is the BUTTON.
struct KeepOnDeviceButton: View {
    let ref: String
    @ObservedObject private var pinned = PinnedMediaStore.shared

    var body: some View {
        let isPinned = pinned.isPinned(ref)
        Button { pinned.togglePin([ref]) } label: {
            Label(isPinned ? "Stop keeping on this device" : "Keep on this device",
                  systemImage: isPinned ? "pin.slash.fill" : "pin")
        }
    }
}

/// The speaker chip over a video page, plus that page's Save/Share menu.
///
/// This could not leave PostCard until an hour ago: it activated the post's audio by handing
/// `primaryVideoPlayer` to the coordinator, so it needed the card's player cache. Now that
/// AudioCoordinator resolves a post's player from its own registry, the chip only needs the item and
/// the ref — and it observes the coordinator itself, so toggling sound redraws a chip rather than a
/// whole card.
struct PostMuteButton: View {
    let item: FeedItemFfi
    let ref: String
    @ObservedObject var audio = AudioCoordinator.shared

    var body: some View {
        Button {
            if audio.activePostId != item.id {
                audio.start(postId: item.id, track: item.music, video: nil,
                            muteVideo: item.muteVideo, immediateMusic: true)
            }
            audio.toggleVideoAudio()
        } label: {
            Image(systemName: audio.activePostId == item.id && audio.videoUnmuted
                  ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(.white)
        }
        // A glass circle chip and nothing else — the default button style painted its own
        // rounded-rect bezel BEHIND the circle on macOS (the doubled-background look).
        .buttonStyle(GlassIconButtonStyle(tint: .white))
        .padding(10)
        // Save/Share lives here for videos (the player's long-press is hold-to-pause, so the video
        // itself no longer carries a contextMenu). It acts on THIS page's video — it used to take
        // item.media.first, which is the wrong item on any page but the first (and is the synthetic
        // geo: ref on a post that also pins a location).
        .contextMenu {
            Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
            if let url = postShareURL(ref) {
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
            KeepOnDeviceButton(ref: ref)
        }
    }
}

/// A media page for a `file_` attachment: icon, size, and a share button.
///
/// Self-contained — it reads its ref and MediaStore and nothing else — so it had no reason to be a
/// method on a 1,000-line view. Part of taking the media block out of PostCard one member at a time,
/// after three attempts to move the whole cluster by script left the file's braces unbalanced.
struct PostFileAttachmentPage: View {
    let ref: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.zipper").font(.system(size: 44)).foregroundStyle(HavenTheme.pink)
            Text("File attachment").font(.subheadline.weight(.semibold))
            if let url = MediaStore.shared.storagePath(for: ref) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                ShareLink(item: url) { Label("Share file", systemImage: "square.and.arrow.up") }
                    .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct PostCard: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var isPortraitPhone: Bool { hSizeClass == .compact }
    #else
    var isPortraitPhone: Bool { false }
    #endif
    let item: FeedItemFfi
    let friendName: String
    let onReact: (String) -> Void
    var onUnreact: (String) -> Void = { _ in }
    let onComment: (String, [String]) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void
    /// When true (the "show all comments" sheet) every comment is shown; otherwise the inline
    /// list is capped at 3 with a "show all" control.
    var expandAllComments = false
    /// A comment this card was opened FOR — a notification/activity row about a reaction or reply on
    /// it. Tinted so the thing that was announced is findable in a long thread.
    var highlightCommentId: String? = nil
    /// Called when the "Add a reply…" field gains focus so the enclosing scroll view (which owns
    /// the ScrollViewReader proxy) can lift this post above the keyboard.
    var onCommentFocus: ((Bool) -> Void)? = nil

    @Environment(\.havenFeedContainer) var feedContainer
    /// NOT @ObservedObject — deliberately, for the same reason as `feed` below. The card's ONLY
    /// reactive use of the coordinator was `isActive`, which now lives on `PostMediaView` — the media
    /// leaf that already observes the coordinator to start and stop its player. Observing here made
    /// the centred-post signal (which changes on every scroll, a new post crossing centre roughly
    /// every couple of seconds) re-evaluate this entire ~1,500-line body, dropping the frame and
    /// making the swipe feel like it stuck. The remaining uses below (`start`, `toggleVideoAudio`,
    /// `activePostId`) are ACTIONS that read the current value through this plain reference — no
    /// reactivity needed.
    var audio: AudioCoordinator { AudioCoordinator.shared }
    /// NOT @ObservedObject — deliberately.
    ///
    /// FeedStore publishes up to 40 TIMES PER SECOND on device (measured: "FeedStore published 204x
    /// in 5s"), because ordinary traffic writes its @Published properties — and @Published fires on
    /// every assignment, equal or not. Observing it here turned each of those into an invalidation of
    /// EVERY PostCard on screen, re-evaluating a ~1,500-line body per card: measured at up to 21 body
    /// evaluations per second while the app sat there.
    ///
    /// That is what the Time Profiler kept describing without naming: the main thread 84% framework
    /// (AG::Graph::propagate_dirty, UpdateStack::update, CA commits) with only 16% of samples
    /// containing any Haven frame — a graph being dirtied, not a slow function.
    ///
    /// This view does not NEED the reactivity. Of its 22 uses, all but one are actions (react, edit,
    /// requestMedia, refresh, postStory, unsend) or reads of activeCircleId, which changes rarely.
    /// Post CONTENT arrives through `item`, handed down by the feed — which does observe the store —
    /// so a changed post still re-renders, now via the value rather than a global notification.
    var feed: FeedStore { FeedStore.shared }
    /// Observed so "Keep on this device" visibly changes state. Reading the store WITHOUT observing
    /// it meant the pin was recorded but nothing on screen moved — the menu closed and the post
    /// looked identical, so a working toggle read as a dead button.
    /// A single photo/video sizes to fill the WIDTH on a portrait phone (a tall shot fills the column
    /// instead of shrinking to a narrow sliver), but fits the WHOLE image within a shorter cap on wider
    /// layouts (iPad / landscape / macOS) so you can see all of it at once.
    @State private var showEdit = false
    @State private var showReport = false
    @State private var linkCopied = false
    /// Set when the backup indicator is tapped — "which relays actually hold this?"
    @State private var showBackupDetail = false
    @State var zoomTarget: ZoomTarget?
    /// A REFERENCE-TYPE cache, deliberately — this is the fix for videos playing twice.
    ///
    /// These were `@State` dictionaries, and `playerFor` writes to them. But `playerFor` is called
    /// FROM `body` (the media page needs a player to hand to GestureVideoPlayer), so that write was a
    /// @State mutation DURING view evaluation. SwiftUI does not honour it for the pass in flight, so
    /// the next evaluation still saw an empty dict, missed the cache, and built a SECOND AVPlayer for
    /// the same clip. The first stayed alive — its loop observer retains it — and kept decoding.
    ///
    /// Measured, not deduced: an instrumented run logged `player #1` and `player #2` for EVERY video,
    /// identical ref, identical post, identical container. Two hardware decode sessions per clip,
    /// audio playing over itself slightly offset (the "static sounding" doubling), and a mute toggle
    /// that could only ever reach the one the coordinator knew about. It is also 2x decode on every
    /// video in the feed — heat with no CPU hotspot, and heat that survives AIRPLANE MODE.
    ///
    /// Mutating a class's contents is not a @State write, so the cache now actually caches.
    @State private var editCommentId: String?
    @State private var editCommentText = ""
    @State private var editCommentMedia: [String] = []

    struct CommentReactTarget: Identifiable { let id: String }
    /// The card's content width, measured. The media page spans it EDGE TO EDGE: sizing the page to the
    /// media's own aspect (the old `.aspectRatio(_, .fit)`) parked a tall clip in a narrow centre column
    /// with the card's grey either side on any wide window — the page must own the width, and the media
    /// letterboxes INSIDE it against its own blurred copy.
    @State private var showHeart = false
    /// A "share this post as a story" composer session (nil = not sharing).
    @State private var storyShare: StoryShareTarget?
    /// Super data saver: video refs the user explicitly tapped play for. We pull those bytes and
    /// auto-start once they land (normal data-saver mode never autoplays).


    /// The post's real media, minus synthetic refs (a `geo:` location pin has no bytes). A story needs
    /// something to show, so this is what gates the "Share as story" action.
    var storyableMedia: [String] { realMedia.filter { !MediaStore.isSynthetic($0) } }

    /// Display name for the post's author — resolved from your contacts by node id.
    private var authorName: String {
        if item.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? friendName
    }
    private func commentAuthorName(_ c: FeedCommentFfi) -> String {
        if c.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: c.authorShort) ?? friendName
    }

    /// A post that is exactly one video — the GestureVideoPlayer owns all of its gestures.
    /// Kind from the REF (a cheap string parse — refs encode img_/vid_/aud_), never `item(ref)`. `item(_:)`
    /// decodes the bitmap / generates the video poster on the main thread on a cache miss, and this is
    /// called per media ref all over layout and scrolling (mediaView, isSingleVideoPost, primaryVideoPlayer,
    /// playVisibleVideo). On a carousel or photo-grid post that was several decodes per layout pass — the
    /// same trap the masonry tile already documents.

    private func react(_ e: String) { EmojiStore.shared.record(e); onReact(e) }

    /// Double-tap a post to ❤️ it (with an Instagram-style heart pop).
    func heartIt() {
        react("❤️")
        withAnimation(HavenTheme.bouncy) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(HavenTheme.smooth) { showHeart = false }
        }
    }

    /// Single-tap a post's media to mute/unmute its sound (video audio or its song).
    func togglePostMute() {
        let hasVideo = item.media.contains(where: isVideo)
        // Make sure this post is the active audio source first, so the toggle acts on it.
        if (hasVideo || item.music != nil), audio.activePostId != item.id {
            audio.start(postId: item.id, track: item.music, video: nil, muteVideo: item.muteVideo, immediateMusic: true)
        }
        if hasVideo {
            // Tapping a video toggles *its own* sound (same as the speaker button) — overriding
            // the author's mute and any global silence so a tap always brings the audio up.
            if SettingsStore.shared.silent { SettingsStore.shared.silent = false }
            audio.toggleVideoAudio()
        } else {
            // A photo / song-only post: a tap still toggles the app's global mute.
            SettingsStore.shared.silent.toggle()
        }
    }

    private var heartBurst: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 86)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 10)
            .scaleEffect(showHeart ? 1 : 0.4)
            .opacity(showHeart ? 0.95 : 0)
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCensus.tick()
        #endif

        VStack(alignment: .leading, spacing: 12) {
            header
            // Another member reported this post → surface the circle's shared moderation signal
            // with per-viewer actions (hide / remove from circle / block). The reporter themselves
            // never sees it — reporting hid the post for them.
            if !item.isMe, let reps = feed.reports(circleId: feed.activeCircleId)[item.id], !reps.isEmpty {
                ReportedBanner(item: item, authorName: authorName, reports: reps)
            }
            if item.unsent {
                Label("Message unsent", systemImage: "minus.circle")
                    .font(.subheadline).italic().foregroundStyle(.secondary)
            } else {
                if !item.body.isEmpty { LinkedText(text: item.body) }
                // Rich Open Graph preview for the first link in a text post (no media of its own).
                if item.media.isEmpty, let url = LinkScanner.urls(in: item.body).first {
                    LinkPreviewCard(url: url)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, 8).padding(.horizontal, 2)
                }
                if !item.media.isEmpty {
                    // For a single-video post the GestureVideoPlayer owns tap/double-tap/hold/
                    // scrub itself (so its hold-to-pause and drag-to-scrub aren't stolen). For
                    // everything else the post-level tap gestures drive mute + heart.
                    if isSingleVideoPost {
                        postMedia
                            .overlay { if showHeart { heartBurst } }
                    } else {
                        postMedia
                            .overlay { if showHeart { heartBurst } }
                            .onTapGesture(count: 2) { heartIt() }       // double-tap to heart
                            .onTapGesture(count: 1) { togglePostMute() } // tap to mute/unmute
                    }
                }
                if let track = item.music { NowPlayingPill(track: track, animating: true) }
                reactionsRow
                if !item.comments.isEmpty {
                    PostCommentsList(item: item, friendName: friendName,
                                     expandAllComments: expandAllComments,
                                     highlightCommentId: highlightCommentId,
                                     onReact: onReact, onUnreact: onUnreact, onComment: onComment,
                                     onEdit: onEdit, onUnsend: onUnsend,
                                     onEditComment: { c in
                                         editCommentId = c.id
                                         editCommentText = c.body
                                         editCommentMedia = c.media
                                     })
                }
                commentField
            }
        }
        .havenCard()
        .sheet(isPresented: $showEdit) { EditPostSheet(item: item) }
        .sheet(isPresented: $showReport) { ReportSheet(item: item, authorName: authorName) }
        .havenFullScreenCover(item: $zoomTarget, wide: true) { t in MediaZoomViewer(refs: t.refs, index: t.index) }
        // Share-as-story runs through the SAME composer as a camera story (filters, caption styling,
        // music, reframing) — the only difference is that the published body carries the source post's
        // ref, so the story deep-links back to it.
        .havenFullScreenCover(item: $storyShare) { target in
            StoryComposerView(draft: target.draft) { ref, caption, track in
                Task { @MainActor in
                    // A long video becomes up to 5 consecutive slides, as everywhere else. Every slide
                    // carries the embed, so the link back works whichever one you're looking at.
                    let parts = await MediaStore.shared.splitStoryVideo(ref)
                    for r in parts {
                        feed.postStory(media: [r],
                                       caption: StoryEmbed.encode(target.embed, caption: caption),
                                       music: track)
                    }
                    storyShare = nil
                }
            } onDone: { storyShare = nil }
        }
        .alert("Edit comment", isPresented: Binding(get: { editCommentId != nil }, set: { if !$0 { editCommentId = nil } })) {
            TextField("Comment", text: $editCommentText)
            Button("Save") { if let id = editCommentId { feed.edit(id, editCommentText, media: editCommentMedia) }; editCommentId = nil }
            Button("Cancel", role: .cancel) { editCommentId = nil }
        }
    }

    /// A shared location is encoded as a synthetic `geo:` ref inside `media` (index 0). It is NOT real
    /// media, so it must be drawn as a map and kept OUT of the photo grid / zoom viewer — otherwise it
    /// degrades to a forever-spinner tile (MediaStore has no file for it).
    /// Media slides the card actually renders. Drops location pins, synthetic markers, and
    /// original companions (those only surface via "Show original").

    /// A full-width media page's height: as tall as the media needs, capped. A page WIDER than the media's
    /// own shape is the point — the exposed strip either side is where the blurred backdrop shows.

    /// The page's ACTUAL aspect once it spans the card — what the letterbox test must compare against.


    /// True when a media set all share (near-)equal aspect ratios — such a set keeps its exact shape
    /// in the carousel (no backdrop needed, since nothing letterboxes).

    /// The carousel's page shape. A uniform set keeps its exact aspect; a MIXED set takes the TALLEST
    /// item's, so no page is ever cropped — clamped so one 9:16 clip can't squeeze the whole card into
    /// a narrow column (the remaining pages letterbox against their own blurred backdrop instead).

    /// A full-width swipeable pager. The visible page's video autoplays as you swipe
    /// (playVisibleVideo keys off `currentPage`), matching the single-media behavior.


    /// Horizontally-scrolling staggered gallery: items flow across two fixed-height rows and
    /// you swipe sideways through them. Each tile keeps its natural aspect (width = row · aspect).



    /// The on-disk file to hand to the system share sheet (video file, else the image).


    /// Super data saver (and normal) single-tap on an inline video.
    /// Under data saver a paused clip's first tap means "play" — mute alone left posters dead after
    /// download because `playVisibleVideo` never auto-starts in that mode.


    /// A `file_` zip attachment: document chip with share/save affordance.
    func fileAttachmentPage(_ ref: String) -> some View { PostFileAttachmentPage(ref: ref) }

    /// True when this page's media can't fill a `containerAspect`-shaped page — it letterboxes, exposing
    /// the card's grey behind it. A video whose poster hasn't been generated yet has no known aspect
    /// (singleAspect falls back to 4:3), so assume it letterboxes: that's the tall-clip case exactly.

    /// A blurred, cropped-to-fill copy of the media behind the fitted one — the letterboxed area reads as
    /// the media's own colors instead of the card's grey. A 64px thumbnail is all a heavy blur can show;
    /// for a video that thumbnail is its poster.
    ///
    /// The poster, NOT a second live layer: an AVPlayer only ever feeds ONE AVPlayerLayer, so hanging a
    /// second (fill-gravity) layer off the same player renders nothing — only the most recently associated
    /// layer draws. A blurred still is the honest trade: no second decode, and behind a 24pt blur the
    /// difference between a still and a moving copy isn't visible anyway.

    /// The carousel's per-page backdrop.
    ///
    /// This used to be gated on `letterboxes(ref, in: containerAspect)` as a perf tweak — "only pay
    /// for the blur when the page's media doesn't fill the page shape". That test is unsound, and it
    /// silently removed the backdrop from entire carousels:
    ///
    ///  • `containerAspect` is `pageAspect(carouselAspect)`, and `pageAspect` falls back to the RAW
    ///    aspect whenever `mediaWidth` is still 0 — which it is on the first layout pass, before the
    ///    preference reports the card's width. Comparing a photo's aspect against the shared aspect
    ///    *derived from that same photo* then matches, so the page that DEFINES the carousel shape
    ///    never got a backdrop.
    ///  • On any wide layout (iPad, landscape, macOS) `pageHeight` is capped at `singleMediaMaxHeight`,
    ///    so the page is far wider than the fitted image no matter what the aspects say. Every page
    ///    letterboxes; the comparison just couldn't see it.
    ///
    /// Single media never had this problem because it draws its backdrop unconditionally. Do the same
    /// here. The cost is one 200px bitmap blurred once per visible page (`.drawingGroup` rasterizes
    /// it), and carousel pages are lazy — which is a much better trade than a flat grey letterbox.




/// Shown for a media reference whose bytes haven't arrived yet, so the post doesn't look
    /// broken while it's still downloading from the sender, a relay, or the shared mailbox.

    /// The single-media tile's aspect ratio, taken from the image (or a video's thumbnail).

    /// The speaker chip over a video page — plus that page's Save/Share menu.
    func muteButton(_ ref: String) -> some View { PostMuteButton(item: item, ref: ref) }

    /// "Keep on this device" toggle — pins/unpins this ref in the device-local retention set so no
    /// cleanup (orphan sweep, age/size limit, or the cleanup screen) ever removes its bytes.


    /// Drive this card's media from whether it's the centered post: the active post
    /// plays its song + the visible carousel video; an inactive post pauses everything.


    /// Fully release this card's video players when it scrolls off-screen — pause, replace each item with
    /// nothing (frees the decode pipeline), remove the loop observers, and drop the dicts. Without this an
    /// off-screen card kept buffering video forever; combined with the leaked observers it ran to ~100 GB.


    @ViewBuilder private var avatar: some View {
        if item.isMe {
            MyAvatar(size: 34)
        } else {
            PeerAvatar(nodeHex: item.authorShort, name: authorName, size: 34)
        }
    }


    func singleAspect(_ ref: String) -> CGFloat { postSingleAspect(ref, in: item.media) }
    func letterboxes(_ ref: String, in containerAspect: CGFloat) -> Bool {
        postLetterboxes(ref, in: containerAspect)
    }
    func shareURL(_ ref: String) -> URL? { postShareURL(ref) }

    func keepOnDeviceButton(_ ref: String) -> some View { KeepOnDeviceButton(ref: ref) }

    /// Kept on the card: the single-video gesture branch and storyableMedia read them, and both are
    /// pure functions of item.media — no player state involved.
    var realMedia: [String] {
        MediaVariants.displayRefs(item.media).filter { SharedLocation.parse($0) == nil }
    }
    func isVideo(_ r: String) -> Bool { MediaKind(ref: r) == .video }
    var isSingleVideoPost: Bool {
        let m = realMedia
        return m.count == 1 && m.first.map(isVideo) == true
    }

    /// The media, as a CHILD VIEW.
    ///
    /// This is the last step of breaking PostCard up, and the one with a measurable point: the media
    /// owns its own state now (player cache, carousel page, measured width, data-saver taps), so
    /// paging a carousel or a width measurement landing re-renders the MEDIA — not the header,
    /// reactions and comments along with it. The playback lifecycle hooks moved with it, because they
    /// belong to the thing that owns the players.
    private var postMedia: some View {
        PostMediaView(item: item, onHeart: { heartIt() },
                      onToggleMute: { togglePostMute() }, zoomTarget: $zoomTarget)
    }

    private var header: some View {
        PostHeader(item: item, friendName: friendName, authorName: authorName,
                   storyableMedia: storyableMedia, onUnsend: onUnsend,
                   showEdit: $showEdit, showReport: $showReport, storyShare: $storyShare)
    }

    // Show only the most-reacted few chips so a post with many distinct emoji can't flood the row and
    // break the layout; the rest collapse into a "+N" chip that opens the full who-reacted sheet. A chip
    // the user owns is always kept visible (so they can untap it), even if it's not in the top counts.

    /// The most-reacted `cap` chips, always keeping the user's own (so they can untap it) — sorted by
    /// count descending. Used to bound both the post- and comment-level reaction rows.
    static func cappedReactions(_ reactions: [ReactionFfi], cap: Int) -> [ReactionFfi] {
        var shown = Array(reactions.sorted { $0.count > $1.count }.prefix(cap))
        if let mine = reactions.first(where: { $0.mine }), !shown.contains(where: { $0.emoji == mine.emoji }) {
            if shown.count >= cap { shown.removeLast() }
            shown.append(mine)
        }
        return shown
    }

    private var reactionsRow: some View {
        PostReactionsRow(reactions: item.reactions, onReact: onReact, onUnreact: onUnreact)
    }


    /// One comment: tappable avatar + name (→ profile), time, body, media, reactions.

    /// Reactions under a comment: existing reaction chips (tap to toggle your own, like the
    /// post-level row) plus a small react button that opens the emoji picker. The core
    /// `react`/`unreact` work on ANY event id, so a comment id is targeted exactly like a post.

    /// A commenter's avatar — mine is my real photo/emoji; others use their synced photo/emoji.

    /// Wrap a commenter's avatar/name so tapping opens their profile (no link for yourself).


    private var commentField: some View {
        PostCommentField(onSubmit: onComment, onFocus: onCommentFocus)
    }
}

/// Your profile / archive: every post you've shared, kept as a copy on your device.
/// Another person's profile — their posts + a stories ring row. Opened by tapping a
/// name or avatar anywhere.
/// A focused sheet for a single post with ALL its comments expanded, so you can read and
/// interact with just that post and its commenters (shown when a post has more than 3 comments).
struct PostCommentsSheet: View {
    let item: FeedItemFfi
    let friendName: String
    let onReact: (String) -> Void
    var onUnreact: (String) -> Void = { _ in }
    let onComment: (String, [String]) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void
    @ObservedObject private var feed = FeedStore.shared
    @Environment(\.dismiss) private var dismiss

    /// The live post, so comments you add in the sheet appear immediately.
    private var live: FeedItemFfi { feed.feedItems.first { $0.id == item.id } ?? item }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollViewReader { proxy in
                    ScrollView {
                        PostCard(item: live, friendName: friendName,
                                 onReact: onReact, onUnreact: onUnreact, onComment: onComment, onEdit: onEdit, onUnsend: onUnsend,
                                 expandAllComments: true,
                                 onCommentFocus: { focused in
                                     // Lift the reply field above the keyboard so typing is visible.
                                     if focused { withAnimation(HavenTheme.smooth) { proxy.scrollTo(live.id, anchor: .bottom) } }
                                 })
                            .id(live.id)
                            .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("Comments")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmLeading) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }.havenPausesPostAudio()
    }
}

struct UserProfileView: View {
    let authorHex: String
    let name: String
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @State private var showStories = false
    @State private var showNickname = false
    @State private var nicknameDraft = ""
    /// Post at the top edge — pinned so arriving posts don't shove the page (see `.scrollPosition`).
    @State private var anchoredPostId: String?

    /// Reflects a nickname edit live (the passed `name` is a snapshot).
    private var resolvedName: String { contacts.name(forNodePrefix: authorHex) ?? name }

    private var posts: [FeedItemFfi] {
        store.items.filter { $0.authorShort == authorHex && !$0.story && !$0.unsent }
    }
    private var userStories: [FeedItemFfi] {
        store.items.filter { $0.authorShort == authorHex && $0.story && !$0.unsent && !$0.media.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                // Lazy — see the note on ProfileView. A member who imported their own archive has as
                // many posts on this screen as you have on yours, and this list built all of them.
                LazyVStack(spacing: 16) {
                    VStack(spacing: 8) {
                        // Use the contact's real signed avatar/emoji (PeerAvatar resolves it from their
                        // card), falling back to the initial — not a hardcoded initial circle.
                        PeerAvatar(nodeHex: authorHex, name: resolvedName, size: 76)
                        HStack(spacing: 6) {
                            Text(resolvedName).font(.title3.bold())
                            Button { nicknameDraft = contacts.contacts.first { $0.idHex.hasPrefix(authorHex) }?.nickname ?? ""; showNickname = true } label: {
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(posts.count) post\(posts.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        if let card = contacts.card(forNodePrefix: authorHex) {
                            if let bio = card.bio, !bio.isEmpty {
                                Text(bio).font(.subheadline).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                            }
                            if let link = card.link, !link.isEmpty {
                                Button { LinkPresenter.shared.open(link) } label: {
                                    Label(link, systemImage: "link")
                                        .font(.footnote.weight(.medium)).foregroundStyle(HavenTheme.pink).lineLimit(1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                    if !userStories.isEmpty {
                        Button { showStories = true } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 58, height: 58)
                                    // This friend's profile picture, not their story media (identity chip).
                                    if let s = userStories.last {
                                        if s.isMe {
                                            HavenAvatar(image: ProfileStore.shared.avatar, emoji: ProfileStore.shared.emoji, size: 50)
                                        } else {
                                            PeerAvatar(nodeHex: s.authorShort,
                                                       name: ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? name, size: 50)
                                        }
                                    }
                                }
                                Text("\(userStories.count) active stor\(userStories.count == 1 ? "y" : "ies")").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .havenCard()
                        }
                        .buttonStyle(.plain)
                    }
                    if posts.isEmpty {
                        ContentUnavailableView("No posts yet", systemImage: "tray",
                                               description: Text("\(name)'s posts will appear here."))
                            .padding(.top, 30)
                    } else {
                        ForEach(posts, id: \.id) { item in
                            PostCard(
                                item: item, friendName: name,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onUnreact: { e in withAnimation(HavenTheme.bouncy) { store.unreact(item.id, e) } },
                                onComment: { b, m in withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { _ in },
                                onUnsend: { }
                            )
                            .equatable()
                            // Report center position so a profile post's video AUTO-PLAYS when centered,
                            // exactly like the main feed (the profile list was missing this, so videos here
                            // only ever played on a manual scrub).
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PostCenterKey.self, value: [item.id: geo.frame(in: .global).midY])
                            })
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(16)
            }
            // Hold the reader's place when posts arrive — same reasoning as the main feed: this
            // list is newest-first, so anything new is inserted ABOVE what is being read, and a
            // plain ScrollView keeps its offset rather than its content. Pinning the post at the
            // top edge means the page grows above it instead of under the reader.
            .scrollPosition(id: $anchoredPostId, anchor: .top)
            .onPreferenceChange(PostCenterKey.self) { centers in
                // The profile post nearest the vertical center becomes active → its video plays + loops.
                let target = PlatformScreen.contentCenterY
                let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                AudioCoordinator.shared.center(nearest?.key, container: "profile")
            }
                .environment(\.havenFeedContainer, "profile")
        }
        .navigationTitle(resolvedName)
        .havenInlineNavTitle()
        .toolbar {
            if let url = DeepLink.profileURL(authorHex) {
                ToolbarItem(placement: .havenTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .havenFullScreenCover(isPresented: $showStories) {
            StoryViewer(stories: userStories, index: 0, friendName: resolvedName)
        }
        .alert("Nickname", isPresented: $showNickname) {
            TextField("Nickname", text: $nicknameDraft)
            Button("Save") { ContactsStore.shared.setNickname(idHex: authorHex, nicknameDraft) }
            Button("Clear", role: .destructive) { ContactsStore.shared.setNickname(idHex: authorHex, "") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Set how \(name) shows up for you.") }
    }
}

/// Create a custom circle and pick which contacts go in it.
struct NewCircleView: View {
    var onCreate: (String, [String]) -> Void
    @ObservedObject private var contacts = ContactsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []

    var body: some View {
        #if os(macOS)
        // HavenMacSheet, not NavigationStack — a stack inside a macOS sheet paints a grey band above
        // (nav bar) and below (where macOS parks sheet toolbar items). Cancel is the glass X circle.
        HavenMacSheet("New circle") {
            memberColumn
        } footer: {
            Button("Create") { create() }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
        }
        .havenPausesPostAudio()
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                Form {
                    Section("Name") { TextField("Circle name (e.g. Family)", text: $name) }
                    Section("Who's in it") { memberRows }
                }
                .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New circle")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { dismiss() }.havenToolbarPill() }
                ToolbarItem(placement: .havenTrailing) {
                    Button("Create") { create() }
                    .havenToolbarPill(tint: HavenTheme.pink)
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .havenPausesPostAudio()
        #endif
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func create() {
        onCreate(trimmedName, Array(selected))
        dismiss()
    }

    /// macOS column: a Form can't lay out inside HavenMacSheet's ScrollView, so the same rows are
    /// hand-stacked with glass surfaces. Same bindings, same order as the iOS Form.
    @ViewBuilder private var memberColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Circle name (e.g. Family)", text: $name).havenPillField()
            Text("Who's in it").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            memberRows
        }
    }

    @ViewBuilder private var memberRows: some View {
        if contacts.contacts.isEmpty {
            Text("Add some people first.").foregroundStyle(.secondary)
        }
        ForEach(contacts.contacts) { c in
            Button {
                if selected.contains(c.idHex) { selected.remove(c.idHex) } else { selected.insert(c.idHex) }
            } label: {
                HStack(spacing: 12) {
                    Circle().fill(LinearGradient(colors: [HavenTheme.amber, HavenTheme.pink], startPoint: .top, endPoint: .bottom))
                        .frame(width: 34, height: 34)
                        .overlay(Text(String(c.displayName.prefix(1)).uppercased()).font(.subheadline.bold()).foregroundStyle(.white))
                    Text(c.displayName).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: selected.contains(c.idHex) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(c.idHex) ? HavenTheme.pink : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct ProfileView: View {
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var store = FeedStore.shared
    let friendName: String
    @State private var showStories = false
    @State private var storyIndex = 0

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                // LAZY, and on this screen that is the difference between working and being killed.
                //
                // This was a plain VStack, so opening the You tab BUILT EVERY POST AT ONCE — each
                // with its media, its blurred backdrop bitmap and its own view graph. With a handful
                // of posts nobody noticed. After an Instagram import there are hundreds, and the tab
                // spent ~59% CPU for two and a half minutes (a cpu_resource report whose samples are
                // 254 SwiftUICore / 160 UIKitCore / 103 QuartzCore / 43 AttributeGraph against 33 in
                // Haven's own code — a view graph being built, not work being done) and then the app
                // was killed for memory shortly after the tab appeared.
                //
                // The circle feed has been lazy all along; these two profile lists were simply never
                // given the same treatment, and no ordinary account had enough posts to expose it.
                LazyVStack(spacing: 16) {
                    header
                    if !store.myStories.isEmpty { storiesRow }
                    if store.myPosts.isEmpty {
                        ContentUnavailableView(
                            "No posts yet",
                            systemImage: "tray",
                            description: Text("Everything you share lives here — and a copy stays on your device.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(store.myPosts, id: \.id) { item in
                            PostCard(
                                item: item, friendName: friendName,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onUnreact: { e in withAnimation(HavenTheme.bouncy) { store.unreact(item.id, e) } },
                                onComment: { b, m in withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { b in withAnimation(HavenTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(HavenTheme.smooth) { store.unsend(item.id) } }
                            )
                            // Same reason the circle feed does it: FeedStore republishes constantly,
                            // and without this every republish re-evaluates a ~1,500-line body for
                            // every card on screen.
                            .equatable()
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Your posts")
        .havenInlineNavTitle()
        // DEBUG-only trace, because this screen is the one that gets the app killed and a memory
        // kill leaves nothing behind to read. Says what it is holding and how much headroom is
        // left, twice a second, so the last line before the process disappears is the evidence.
        .memoryTrace { "you-tab \(store.myPosts.count) posts / \(store.myStories.count) stories" }
        .havenFullScreenCover(isPresented: $showStories) {
            StoryViewer(stories: store.myStories, index: storyIndex, friendName: friendName)
        }
    }

    private var storiesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your stories").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy for the same reason as the list below it: an import that brought stories over
                // as kept stories can leave dozens here, and an eager HStack decodes a thumbnail for
                // every one of them the moment the tab opens — off-screen ones included.
                LazyHStack(spacing: 12) {
                    ForEach(Array(store.myStories.enumerated()), id: \.element.id) { idx, s in
                        Button { storyIndex = idx; showStories = true } label: {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 64, height: 64)
                                // Gallery of your own stories → each shows its OWN content thumbnail (matches
                                // the You tab). Off-main, flash-free via FeedImage.
                                if let ref = s.media.first {
                                    FeedImage(ref: ref, maxDimension: 160, contentMode: .fill) { Color.clear }
                                        .frame(width: 56, height: 56).clipShape(Circle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 76)
            Text(profile.displayName.isEmpty ? "You" : profile.displayName).font(.title3.bold())
            Text("\(store.myPosts.count) post\(store.myPosts.count == 1 ? "" : "s") · a copy lives on your device")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}
