import SwiftUI
import AVKit
import Combine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Full-screen story viewer: progress bars, auto-advance, tap left/right to navigate,
/// captions, and the song the author attached (played while you watch).
/// Stories are ordinary posts flagged `story` with a 24h retention, so they expire
/// on their own — no special server, just the existing retention rule.
struct StoryViewer: View {
    /// The clip's video track with its audio DROPPED, so a story playing under a song owns no audio
    /// track at all. See the call site for why muting is not sufficient. Returns nil if the asset
    /// can't be rebuilt, in which case the caller falls back to a plain muted player.
    private static func videoOnlyAsset(_ url: URL) async -> AVAsset? {
        await HavenAVComposition.videoOnly(from: AVURLAsset(url: url))
    }

    let stories: [FeedItemFfi]
    @State var index: Int
    let friendName: String
    /// Observed so the Keep pill re-renders the moment it's toggled.
    @ObservedObject private var kept = KeptStoriesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var player: AVPlayer?
    @State private var endObserver: Any?   // the loop observer's token — MUST be removed or the player leaks
    @State private var slideDuration = 5.0   // photos 5s; videos last their clip (≤15s)
    @State private var profilePeer: StoryProfile?   // tapped a sharer → peek their profile
    /// Set when the story's cloud badge is tapped — "which relays actually hold this?" (DM parity).
    @State private var backupDetailRefs: BackupRefs?
    @State private var paused = false               // paused while the profile sheet is up
    @State private var dragOffset: CGFloat = 0      // swipe-down-to-dismiss
    @State private var replyText = ""
    @State private var replySent = false
    @State private var waitingMedia: String?   // a story whose bytes are still downloading
    @State private var retryCounter = 0

    /// The ref a story actually RENDERS.
    ///
    /// NOT `media.first`. A video story travels with its poster still and that still is published
    /// FIRST (`[poster, posterMarker, clip]`, the order `composeVideoMedia`/`withPosterCompanions`
    /// build), so `media.first` is the poster — taking it renders a video story as a frozen frame,
    /// which is the "it shared my video as a photo" report. `displayRefs` drops posters, thumbs,
    /// originals and markers and leaves the playable ref.
    private func displayRef(_ s: FeedItemFfi) -> String? {
        MediaVariants.displayRefs(s.media).first ?? s.media.first
    }

    /// The poster still declared for this story's clip, if any — what we can draw IMMEDIATELY while
    /// the video itself is still transferring.
    private func posterRef(_ s: FeedItemFfi) -> String? {
        guard let ref = displayRef(s) else { return nil }
        return MediaVariants.poster(for: ref, in: s.media)
    }
    @State private var confirmDeleteStory = false   // confirm unsending your own story
    @State private var heldPaused = false            // press-and-hold pauses the timer + video
    @FocusState private var replyFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    struct StoryProfile: Identifiable { let id = UUID(); let hex: String; let name: String }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, dragOffset / 500)).ignoresSafeArea()
            // MEDIA + navigation layer. The press-and-hold gesture is attached HERE, not to the whole
            // screen: a DragGesture(minimumDistance: 0) on a parent swallows the taps of Buttons
            // beneath it, so holding it at the top level meant Keep / delete / close never fired —
            // the tap fell through to the prev/next zones and the story just advanced. Scoping it to
            // the media area keeps hold-to-pause working everywhere it should while leaving the
            // overlay's controls genuinely tappable.
            Group {
                if stories.indices.contains(index) {
                    content(stories[index]).ignoresSafeArea()
                }
                // Prev/next tap zones. They deliberately do NOT span the full height: the strips the
                // header controls and the reply field occupy are carved out entirely, so a tap on
                // Keep / delete / close / reply cannot reach a navigation zone no matter how the
                // gesture arbitration resolves. Relying on Z-order alone did not hold — the controls
                // sit above these and taps still advanced the story — and "the button is on top" is
                // not worth debugging per-control when the zones simply have no business being under
                // them in the first place.
                VStack(spacing: 0) {
                    Color.clear.frame(height: 104).allowsHitTesting(false)   // header strip
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { prev() }
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { next() }
                    }
                    Color.clear.frame(height: 96).allowsHitTesting(false)    // reply / chip strip
                }
            }
            // Hold-to-pause via the PRESSING callback, not a zero-distance drag.
            //
            // The drag version set heldPaused on touch-DOWN and cleared it in onEnded — but when a
            // competing gesture won the sequence, onEnded never fired and the story stayed paused
            // forever ("it stopped progressing"). `pressing:` is always called with false when the
            // press resolves, however it resolves, so the pause can't stick.
            .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 30) {
                // Long press completed — nothing to do; pausing is handled by `pressing:`.
            } onPressingChanged: { down in
                if down { if !heldPaused { heldPaused = true; player?.pause() } }
                else if heldPaused { heldPaused = false; player?.play() }
            }
            // Swipe DOWN to dismiss; swipe LEFT/RIGHT to skip whole users (Instagram-style). Attached
            // HERE rather than to the whole screen: a drag recognizer on an ancestor of a Button
            // delays and then CANCELS the button's action — the button highlights on touch-down and
            // then does nothing, which is exactly how Keep and delete failed. The controls layer must
            // have no gesture-bearing ancestor at all.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in if v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width) { dragOffset = v.translation.height } }
                    .onEnded { v in
                        if abs(v.translation.width) > abs(v.translation.height), abs(v.translation.width) > 60 {
                            withAnimation(.spring()) { dragOffset = 0 }
                            if v.translation.width < 0 { skipToNextUser() } else { skipToPrevUser() }
                        } else if v.translation.height > 130 { dismiss() }
                        else { withAnimation(.spring()) { dragOffset = 0 } }
                    }
            )
            .offset(y: dragOffset)

            // CONTROLS layer, above the gesture layer so its buttons receive their own taps.
            Group {
                if stories.indices.contains(index) {
                    positionedCaption(stories[index])
                    overlay(stories[index])
                }
            }
            .offset(y: dragOffset)
        }
        .havenStatusBarHidden()
        // (Both gestures now live on the MEDIA layer — see the note there. Nothing gestural is
        // attached at this level, so the controls layer has no gesture-bearing ancestor at all.)
        .onAppear {
            // Silence whatever the feed was playing UNDERNEATH. A story covers the feed completely
            // and brings its own audio, so the post's video or song carrying on behind it means two
            // things playing at once with only one of them visible. The viewer manages its own
            // sound from here (see loadCurrent); this is only about what it is covering up.
            AudioCoordinator.shared.stopPostAudioForOverlay()
            loadCurrent()
        }
        .onDisappear { teardown() }
        // STOP WHEN THE APP IS NOT IN FRONT.
        //
        // `onDisappear` covers closing the viewer, but not leaving the app with it open — and a
        // story is a video plus, often, a song, so walking away left both running with nothing on
        // screen. The progress timer kept ticking too, so the story advanced through the whole
        // tray unwatched and the sound followed you out of the app.
        //
        // Reactivating resumes rather than restarting: `paused` is the viewer's own flag (a sheet, a
        // long-press), so it is respected here instead of being cleared.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Re-arm the current story rather than nudging a player whose song was stopped:
                // `MusicPlayback.stop()` clears the queued track, so there is nothing to resume.
                // Restarting the slide you were on is also the honest thing to show — you did not
                // watch the part that played while you were away.
                paused = false
                loadCurrent()
            } else {
                // MusicPlayback gates STARTING on `appFrontmost`, but nothing stopped what was
                // already running — so leaving the app with a story open left the clip and its song
                // playing to nobody, and the tick kept advancing the tray behind your back.
                paused = true
                player?.pause()
                MusicPlayback.shared.stop()
            }
        }
        // A call starting MID-story mutes the clip's own audio immediately (call audio priority);
        // MusicPlayback ducks itself, but this player is view-local so it must react here.
        .onReceive(CallManager.shared.objectWillChange) { _ in
            if CallManager.shared.callInProgress { player?.isMuted = true }
        }
        .onReceive(tick) { _ in
            // Waiting on media: re-check + re-request (~every 2s) until it arrives, then load.
            if let ref = waitingMedia {
                if MediaStore.shared.has(ref) { loadCurrent() }
                else { retryCounter += 1; if retryCounter % 40 == 0 { FeedStore.shared.requestMedia(ref) } }
                return
            }
            guard !paused, !heldPaused, !replyFocused else { return }
            progress += 0.05 / slideDuration
            if progress >= 1 { next() }
        }
        .sheet(item: $profilePeer, onDismiss: { paused = false; player?.play() }) { peer in
            NavigationStack { UserProfileView(authorHex: peer.hex, name: peer.name) }
        }
        // The cloud badge on your own story answers "did this reach a relay?" with one glyph. Tapping
        // it opens the same which-relays-hold-this sheet the feed post and DM indicators open — the
        // badge looked like a button everywhere else in the app and did nothing here.
        .sheet(item: $backupDetailRefs, onDismiss: { paused = false; player?.play() }) { b in
            BackupDetailView(refs: b.refs, circleId: FeedStore.shared.activeCircleId)
                .macSheetFrame()
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }

    @ViewBuilder private func content(_ s: FeedItemFfi) -> some View {
        if waitingMedia != nil {
            // Draw the poster under the spinner when we have it. A story's clip can take a while to
            // arrive — the poster is a fraction of the size and lands first — and a still with a
            // progress ring reads as "this is loading", where a black screen reads as "this is
            // broken". That was the report: stories stuck on a spinner that never finished.
            ZStack {
                if let p = posterRef(s), let img = MediaStore.shared.item(p)?.image {
                    Image(platformImage: img).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .overlay(Color.black.opacity(0.35))
                }
                downloading
            }
        } else {
            GeometryReader { geo in
                // The author's framing (zoom + reposition) travels in the caption spec.
                let tf = StoryCaptions.decode(StoryEmbed.strip(s.body)).spec
                ZStack {
                    // Blurred fill backdrop so off-ratio media (landscape, etc.) sits in the standard
                    // story frame instead of leaving plain black bands. The still covers photo + video.
                    if let ref = displayRef(s) ?? posterRef(s),
                       let img = MediaStore.shared.item(ref)?.image ?? posterRef(s).flatMap({ MediaStore.shared.item($0)?.image }) {
                        Image(platformImage: img).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 28).overlay(Color.black.opacity(0.28))
                    }
                    // FILL WHAT WAS FRAMED HERE; FIT WHAT WAS NOT.
                    //
                    // The composer draws the media full-bleed and the player has always matched it —
                    // that parity is the point, it is how an author frames a story and knows what
                    // viewers will see. So a story composed in Haven fills the canvas, edge to edge,
                    // exactly as its author left it.
                    //
                    // An IMPORTED story was never framed against this canvas. It is 9:16 out of
                    // Instagram, the phone is nearer 9:19.5, and filling that height overflows the
                    // width by about a fifth — taken off both sides, which slices the ends off text
                    // baked into the picture, and an Instagram story is mostly text baked into the
                    // picture. Nobody chose that crop, so it is not honoured: those fit, over their
                    // own blurred copy, the way the feed shows an off-ratio post.
                    //
                    // (I had this globally FIT for one build, which fixed the imported case by
                    // shrinking every story the author had deliberately framed full-bleed.)
                    //
                    // ORIGIN IS READ FROM THE ID, NOT THE CAPTION. My first attempt asked whether the
                    // story carried a caption spec, on the assumption that the composer always writes
                    // one. It does not: `StoryCaptions.encode` returns "" when there is no caption AND
                    // no reframing, so a story shot in Haven and posted without a caption is
                    // indistinguishable from an import by that test — which is exactly why one of two
                    // stories was fixed and the other stayed small. An imported story's kept identity
                    // is the archive's own entry path ("ig:…", see InstagramImporter.keptIdentity),
                    // which is never empty and owes nothing to what the author typed.
                    let fills = !wasImported(s)
                    framingProbe(s, fills: fills)
                    //
                    // Fill crops to the SCREEN's shape, and a phone is much taller than a story. An
                    // Instagram story is 9:16; this phone is roughly 9:19.5. Covering that height
                    // overflows the width by about a fifth, taken off both sides — which quietly
                    // slices the ends off any text baked into the picture, and Instagram stories are
                    // mostly text baked into the picture. Reported as the story being "expanded
                    // beyond the size of my iPhone".
                    //
                    // The blurred backdrop above exists precisely to fill what the media does not,
                    // and this is what the feed already does with an off-ratio post. The author's
                    // own framing (mediaScale) still applies on top, so a story deliberately zoomed
                    // in the editor still looks the way it was composed.
                    Group {
                        if let player {
                            VideoSurface(player: player, fill: fills)
                        } else if let ref = displayRef(s),
                                  let img = MediaStore.shared.item(ref)?.image
                                      ?? posterRef(s).flatMap({ MediaStore.shared.item($0)?.image }) {
                            Image(platformImage: img).resizable()
                                .aspectRatio(contentMode: fills ? .fill : .fit)
                        } else {
                            missing
                        }
                    }
                    // Scale, then rotate, then move — the order the fingers did it in. A scale BELOW 1
                    // deliberately stops short of filling the frame: that is how a landscape photo
                    // shows whole, sitting over the blurred backdrop above rather than being cropped
                    // to the portrait keyhole.
                    .scaleEffect(tf.mediaScale)
                    .rotationEffect(.radians(tf.mediaRotation))
                    .offset(x: tf.mediaOffX * geo.size.width, y: tf.mediaOffY * geo.size.height)
                    // Blur a sensitive received story (local SCA or a circle member's federated flag).
                    // The ref being RENDERED, not media.first — on a video story that is the poster,
                    // so the guard would scan and blur a different blob than the one on screen.
                    .sensitiveContentGuard(ref: displayRef(s) ?? "", circleId: FeedStore.shared.activeCircleId,
                                           scan: !s.isMe, cornerRadius: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
        }
    }

    private var downloading: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white).scaleEffect(1.3)
            Text("Downloading story…").foregroundStyle(.white.opacity(0.85)).font(.subheadline)
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            Text("Loading…").foregroundStyle(.white.opacity(0.6)).font(.caption)
        }
    }

    /// DEBUG probe: where the HUD actually lands.
    ///
    /// The song chip at the BOTTOM of this same VStack draws while the progress bars, avatar, keep,
    /// delete and close at the TOP of it do not — which can only mean the stack is taller than the
    /// space it was given and is overflowing upward, off the screen. Guessing at that twice is
    /// enough; this reports the geometry so the next change is aimed at a number.
    /// Did this story come from an archive import rather than Haven's own composer?
    ///
    /// Kept stories carry the identity they were kept under, and the importer keeps each one under
    /// its archive entry path. Nothing else in the app mints an id in that shape.
    private func wasImported(_ s: FeedItemFfi) -> Bool { s.id.hasPrefix("ig:") }

    /// DEBUG: which framing a story got, and why — so "too small" or "cut off" is answerable
    /// without another round trip.
    @ViewBuilder private func framingProbe(_ s: FeedItemFfi, fills: Bool) -> some View {
        #if DEBUG
        Color.clear.onAppear {
            HavenLog.sync("story-framing: \(fills ? "FILL (composed here)" : "FIT (imported)")"
                + " id=\(s.id.prefix(28))")
        }
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private func hudProbe() -> some View {
        #if DEBUG
        GeometryReader { g in
            Color.clear.onAppear {
                let f = g.frame(in: .global)
                HavenLog.sync(String(format: "story-hud: y=%.0f h=%.0f (screen h=%.0f) safeTop=%.0f safeBottom=%.0f",
                                     f.minY, f.height, PlatformScreen.bounds.height,
                                     g.safeAreaInsets.top, g.safeAreaInsets.bottom))
            }
        }
        #else
        EmptyView()
        #endif
    }

    /// DEBUG: where one HUD row lands, and how wide its pieces are.
    @ViewBuilder private func rowProbe(_ label: String, extra: String) -> some View {
        #if DEBUG
        GeometryReader { g in
            Color.clear.onAppear {
                let f = g.frame(in: .global)
                HavenLog.sync(String(format: "story-hud %@: x=%.0f y=%.0f w=%.0f h=%.0f  %@",
                                     label, f.minX, f.minY, f.width, f.height, extra))
            }
        }
        #else
        EmptyView()
        #endif
    }

    /// The most progress segments ever drawn, however many stories the tray holds.
    ///
    /// 225 of them is not a hypothetical: an imported archive puts every kept story in one tray, and
    /// at 4pt of spacing 225 segments need 896pt of SPACING ALONE. The HStack cannot be narrower
    /// than that, so it forced the whole HUD stack to 928pt on a 440pt screen — centred, which put
    /// x=-244 and hung the profile off the left edge and keep/delete/close off the right, while the
    /// segments themselves came out a seventh of a point wide. That is the entire "no story HUD"
    /// report: nothing was hidden or mispositioned, one row was simply too wide to fit and took the
    /// rest of the header with it. (Desktop hit exactly this and was windowed; iOS never was.)
    ///
    /// A window around the current story instead. Beyond a couple of dozen a progress bar has
    /// stopped conveying position anyway — the segments end up thinner than the gaps between them.
    private static let maxProgressSegments = 24

    /// The slice of stories the progress bar draws, kept centred on where you are.
    private var progressWindow: Range<Int> {
        let n = stories.count
        guard n > Self.maxProgressSegments else { return 0..<n }
        let half = Self.maxProgressSegments / 2
        let lo = max(0, min(index - half, n - Self.maxProgressSegments))
        return lo..<(lo + Self.maxProgressSegments)
    }

    private func overlay(_ s: FeedItemFfi) -> some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(progressWindow, id: \.self) { i in
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.3))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: geo.size.width * (i < index ? 1 : (i == index ? progress : 0)))
                            }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal).padding(.top, 12)
            .background(rowProbe("progress", extra: "segments=\(stories.count)"))
            HStack(spacing: 8) {
                if s.isMe {
                    sharerAvatar(s)
                    Text("Your story").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    // Same relay-backup signal as a feed post: while viewing your OWN story, show whether
                    // its photo/video has reached a relay yet (↑ uploading, ✓ backed up) — so "did my story
                    // actually sync?" has a visible answer instead of a guess.
                    // Always show backup state for own stories — hide-when-no-relay made "not
                    // syncing" look like "no indicator" (same bug as feed posts).
                    if !s.media.isEmpty {
                        TimelineView(.periodic(from: .now, by: 2.0)) { _ in
                            let blobs = s.media.filter { !MediaStore.isSynthetic($0) }
                            let cid = FeedStore.shared.activeCircleId
                            let hasRelay = !RelayMailboxStore.shared.relays(forCircle: cid).isEmpty
                                || SharedStore.hasMailbox(cid)
                            let own = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
                            let backed = !blobs.isEmpty && blobs.allSatisfy {
                                MediaBackupLedger.hasAnyRemote($0, ownRelayHex: own)
                            }
                            let icon = backed ? "checkmark.icloud.fill"
                                : (!hasRelay ? "exclamationmark.icloud" : "arrow.up.circle")
                            Image(systemName: icon)
                                .font(.caption2).foregroundStyle(.white.opacity(backed ? 0.9 : 0.75))
                                .help(backed ? "Backed up to a relay others can read"
                                      : (!hasRelay ? "No relay known — story only on this device"
                                         : "Uploading to a relay…"))
                                // Pad the hit area: a caption2 glyph is far below the 44pt target, and
                                // this one sits inches from the Keep/delete row.
                                .padding(6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // The viewer auto-advances on a timer — freeze it, or the sheet
                                    // ends up describing a story you are no longer on.
                                    paused = true
                                    player?.pause()
                                    backupDetailRefs = BackupRefs(refs: blobs)
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Shows which relays hold a copy")
                        }
                    }
                } else {
                    let name = ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName
                    Button {
                        paused = true
                        player?.pause()
                        profilePeer = StoryProfile(hex: s.authorShort, name: name)
                    } label: {
                        HStack(spacing: 8) {
                            sharerAvatar(s)
                            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                        .contentShape(Rectangle())   // .plain adds no hit shape — see the Keep pill
                    }
                    .buttonStyle(.plain)
                }
                Text(relativeTimeShort(s.createdAt)).font(.caption2).foregroundStyle(.white.opacity(0.7))
                Spacer()
                if s.isMe {
                    // KEEP is a toggle that holds this story on MY PROFILE past the 24h window — it
                    // does not re-publish it. It used to create a permanent post, which put the story
                    // back in the circle feed as a new thing everyone saw again; wanting to hold on to
                    // something yourself is a different act from sharing it twice. A kept story still
                    // leaves everyone's story row on schedule.
                    let isKept = kept.isKept(s.id)
                    Button {
                        kept.toggle(id: s.id,
                                    body: s.body,
                                    media: s.media,
                                    createdAt: s.createdAt,
                                    music: s.music)
                    } label: {
                        // Filled + "Kept" when it is; outline + "Keep" when it isn't — the state has to
                        // be readable at a glance, since the button previously looked identical either
                        // way and read as doing nothing at all.
                        Label(isKept ? "Kept" : "Keep", systemImage: isKept ? "bookmark.fill" : "bookmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isKept ? HavenTheme.pink : .white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            // Real glass, not a hand-rolled white scrim — and .plain so macOS
                            // paints no bezel behind the pill.
                            .havenGlass(in: Capsule())
                            // `.buttonStyle(.plain)` adds no implicit hit shape, so the tappable area
                            // collapsed to the drawn glyph and text — missing the pill's padding, and
                            // most taps with it. The close button worked precisely because it does NOT
                            // use .plain. Make the whole pill the target.
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.15), value: isKept)
                    .accessibilityLabel(isKept ? "Kept on your profile" : "Keep on your profile")
                    // Unsend (delete) your own story — removes it everywhere it was shared.
                    Button {
                        paused = true; player?.pause(); confirmDeleteStory = true
                    } label: {
                        Image(systemName: "trash").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .havenGlass(in: Capsule())
                            .contentShape(Capsule())   // see the Keep pill above
                    }
                    .buttonStyle(.plain)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(GlassIconButtonStyle(size: 30, tint: .white))
            }
            .padding(.horizontal).padding(.top, 4)
            .background(rowProbe("header", extra: "isMe=\(s.isMe)"))
            .confirmationDialog("Delete this story?", isPresented: $confirmDeleteStory, titleVisibility: .visible) {
                Button("Delete story", role: .destructive) {
                    FeedStore.shared.unsend(s.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { paused = false; player?.play() }
            } message: {
                Text("It will be removed from your story and for everyone you shared it with.")
            }
            Spacer()
            // Bottom controls sit over a fade-to-black scrim so the (white) song chip + reply
            // field stay legible even when the story image is near-white at the bottom.
            VStack(spacing: 0) {
                embedChip(s)
                if let m = s.music {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note").font(.caption)
                        Text("\(m.title) · \(m.artist)").font(.caption.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.bottom, 8)
                }
                // Reply to start a DM with the author (not on your own story). SwiftUI lifts
                // the focused field above the keyboard on its own — no manual offset (that
                // double-lifted it way too high).
                if !s.isMe {
                    storyReply(s).padding(.bottom, 18)
                } else {
                    Color.clear.frame(height: 18)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 64)
            .background(
                // Bleed the fade through the bottom safe area (home-indicator strip) so it covers
                // the FULL bottom of the image, not just down to the safe-area inset.
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            )
        }
        // CLAMP TO THE CONTAINER. `frame(maxWidth:)` only permits growth; it does not stop a child
        // whose minimum width exceeds the screen from widening the stack and pushing its own ends
        // off both edges — which is exactly what 225 progress segments did. containerRelativeFrame
        // imposes the container's width regardless of what the children would like, so no future row
        // can take the header off-screen again. (The same modifier, for the same reason, is on the
        // You tab's content lane.)
        #if os(iOS)
        .containerRelativeFrame(.horizontal)
        #endif
        .background(hudProbe())
    }

    /// "View post" — shown when this story was shared FROM a post, and taps through to that post.
    ///
    /// The chip is drawn from the embed token alone; it deliberately does NOT check whether the post is
    /// readable first. A pre-flight check would be a membership oracle — the chip's presence would tell
    /// the viewer whether the author's post exists and whether they can see it. Instead the tap always
    /// lands somewhere honest: `PostLinkView` renders the post if this device can decrypt it, and a
    /// plain "Post unavailable" if it can't (deleted, unsent, or not your circle). In practice the two
    /// audiences are the same set — a story goes to the circle its source post lives in — so this is the
    /// deleted/unsent case, not the access case.
    @ViewBuilder private func embedChip(_ s: FeedItemFfi) -> some View {
        if let ref = StoryEmbed.decode(s.body).ref {
            Button {
                openEmbeddedPost(ref)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.app.fill").font(.caption)
                    Text("View post").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .havenGlass(in: Capsule())
                .contentShape(Capsule())   // .plain adds no hit shape — see the Keep pill
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
    }

    /// Leave the viewer, then route to the post. Order matters: the story viewer is a full-screen cover
    /// and the deep-link destination is a SHEET on the root view, so raising it while the cover is still
    /// up gets swallowed. Dismiss first, let the cover finish animating out, then route.
    private func openEmbeddedPost(_ ref: StoryEmbed.Ref) {
        player?.pause()
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            DeepLinkRouter.shared.openPost(circleId: ref.circleId, postId: ref.postId)
        }
    }

    /// The caption rendered where the author dragged it (position travels in the spec).
    @ViewBuilder private func positionedCaption(_ s: FeedItemFfi) -> some View {
        let body = StoryEmbed.strip(s.body)
        if !body.isEmpty {
            let decoded = StoryCaptions.decode(body)
            GeometryReader { geo in
                StyledCaption(text: decoded.text, spec: decoded.spec)
                    .padding(.horizontal, 12)
                    .position(x: decoded.spec.x * geo.size.width, y: decoded.spec.y * geo.size.height)
            }
            .allowsHitTesting(false)   // never blocks taps/swipes
        }
    }

    private func storyReply(_ s: FeedItemFfi) -> some View {
        let name = ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName
        return HStack(spacing: 10) {
            TextField("", text: $replyText, prompt: Text("Reply to \(name)…").foregroundColor(.white.opacity(0.7)))
                .textFieldStyle(.plain)   // drop macOS's default field border so we don't double up with the capsule
                .foregroundStyle(.white).tint(.white)
                .focused($replyFocused)
                .submitLabel(.send)
                .onSubmit { sendReply(to: s) }
                // The story view isn't a scroll, so add a keyboard Done to dismiss it.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { replyFocused = false }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                // ONE surface: real glass. (Was a hand-rolled white scrim + its own stroked
                // capsule — two surfaces on one control.)
                .havenGlass(in: Capsule())
            if !replyText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { sendReply(to: s) } label: {
                    Image(systemName: "paperplane.fill").foregroundStyle(.white).padding(10)
                        .background(HavenTheme.brand, in: Circle())
                        .contentShape(Circle())   // .plain adds no hit shape — see the Keep pill
                }
                .buttonStyle(.plain)   // gradient circle is the surface; no bezel behind it
            }
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .top) {
            if replySent {
                Text("Sent ✓").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .offset(y: -34)
            }
        }
    }

    private func sendReply(to s: FeedItemFfi) {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let name = ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName
        guard let idHex = ContactsStore.shared.idHex(forNodePrefix: s.authorShort) else { return }
        let dm = FeedStore.shared.startDM(with: idHex, name: name)
        // Point at the story with a deep link (same idea as "Message the author" on a post) —
        // do NOT re-seal the media into the DM. The bubble renders a tall framed crop and opens
        // the real story viewer (music, caption, progress); when the story expires the card
        // becomes "Story expired" unless the author kept it. Cross-platform parity.
        let circleId = Self.circleId(forStoryId: s.id) ?? FeedStore.shared.activeCircleId
        let link = DeepLink.storyURL(circleId: circleId, postId: s.id)?.absoluteString
            ?? DeepLink.storyLink(circleId: circleId, postId: s.id)
        let body = text + "\n" + link
        FeedStore.shared.sendMessage(to: dm, body, media: [], music: nil)
        replyText = ""
        replyFocused = false
        withAnimation { replySent = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { withAnimation { replySent = false } }
        }
    }

    /// Which circle hosts this story id — active circle first, then every known circle.
    private static func circleId(forStoryId id: String) -> String? {
        let store = FeedStore.shared
        let active = store.activeCircleId
        if store.messages(in: active).contains(where: { $0.id == id }) { return active }
        for c in store.circles where store.messages(in: c.id).contains(where: { $0.id == id }) {
            return c.id
        }
        return nil
    }

    // MARK: - Playback per story

    private func loadCurrent() {
        // Stop the previous slide's audio so it never bleeds into the next, AND release its loop
        // observer — otherwise the observer's closure keeps the old AVPlayer (and its video decode
        // buffers) alive forever, looping/re-decoding off-screen. Every slide leaked one → tens of GB
        // overnight. (Same root cause as the PostCard fix; this site was missed.)
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player = nil
        // Clear a STUCK hold-to-pause: on macOS a tap-to-navigate cancels the 0-distance DragGesture's
        // onEnded, leaving heldPaused == true, which froze the progress timer (the last/only story then
        // never auto-advanced or dismissed). Reset it on every load.
        heldPaused = false
        guard stories.indices.contains(index) else { return }
        let s = stories[index]
        // The author's song plays while you watch; the video is muted under it.
        //
        // The session must be playback + mixWithOthers BEFORE either starts. A muted AVPlayer still
        // takes the audio session, and a non-mixing one suppresses Apple Music outright — which is
        // why a video story's song played in the composer (StoryCamera prepares the session) but went
        // silent in the viewer, which never did. Configuration is off-main and asynchronous, so start
        // the song in the completion: starting it on the next line races the session it depends on.
        #if os(iOS)
        if let m = s.music {
            ensureHavenPlaybackSession(force: true) { MusicPlayback.shared.play(m) }
        } else {
            MusicPlayback.shared.stop()
        }
        #else
        if let m = s.music { MusicPlayback.shared.play(m) } else { MusicPlayback.shared.stop() }
        #endif
        // If the bytes haven't arrived yet (a dropped chunk on a big video), wait and
        // actively re-request instead of hanging forever on a stale "Loading…".
        if let ref = displayRef(s), !MediaStore.shared.has(ref) {
            waitingMedia = ref
            retryCounter = 0
            FeedStore.shared.requestMedia(ref)
            // Pull the poster too. It is orders of magnitude smaller than the clip, so it lands
            // almost immediately and gives the viewer something real to show meanwhile — the
            // difference between a still with a spinner and a black "Downloading story…" screen
            // for the length of a video transfer.
            if let p = posterRef(s), !MediaStore.shared.has(p) { FeedStore.shared.requestMedia(p) }
            player = nil
            return
        }
        waitingMedia = nil
        if let ref = displayRef(s), let item = MediaStore.shared.item(ref),
           item.kind == .video, let url = item.videoURL {
            // Under a song, hand the player a VIDEO-ONLY composition rather than muting it.
            //
            // `isMuted` is not enough, and the composer already learned this the hard way: a player
            // that still OWNS an audio track joins the audio session, so the music player's start
            // interrupts it, anything that resumes it interrupts the song right back, and the two
            // ping-pong — which is why tapping a muted story video killed the song that was already
            // playing. With no audio track the clip can neither interrupt the song nor be
            // interrupted by it, and both simply run.
            let silentUnderSong = s.music != nil
            // Start playing IMMEDIATELY with the plain asset — stripping the audio track needs the
            // async track loaders, and making the viewer wait on them would put a blank frame at the
            // start of every story. Under a song the strip then swaps in below, preserving position.
            let p = AVPlayer(url: url)
            // Belt and braces: a call still takes priority, and a clip we couldn't strip stays muted.
            p.isMuted = silentUnderSong || CallManager.shared.callInProgress
            // Weak capture + keep the token so loadCurrent/teardown can remove it. A strong capture +
            // discarded token is exactly what leaked every story player forever.
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: p.currentItem, queue: .main) { [weak p] _ in
                p?.seek(to: .zero); p?.play()
            }
            player = p
            p.play()
            // Swap to the audio-free composition once it resolves. Muting alone is not enough (an
            // owned audio track still joins the session and ping-pongs with the music player), but it
            // holds the line until the composition is ready — and if it never resolves, muted IS the
            // fallback, exactly as before.
            if silentUnderSong {
                Task { @MainActor in
                    guard let stripped = await Self.videoOnlyAsset(url),
                          player === p else { return }   // slide moved on; this player is gone
                    let at = p.currentTime()
                    p.replaceCurrentItem(with: AVPlayerItem(asset: stripped))
                    // await, not fire-and-forget: in an async context this resolves to the async
                    // overload, and letting the seek finish before play() is what keeps the swap from
                    // being visible as a jump back to the start.
                    await p.seek(to: at)
                    p.play()
                }
            }
            // Let the slide last the clip's length, capped at the per-slide max.
            slideDuration = MediaStore.storySlideMax
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration) {
                    await MainActor.run { slideDuration = min(MediaStore.storySlideMax, max(2, d.seconds)) }
                }
            }
        } else {
            player = nil
            slideDuration = 5
        }
    }

    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        // Remove the loop observer by its TOKEN. The old `removeObserver(self)` never matched a
        // closure-based observer (it isn't registered against `self`), so the player leaked.
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player = nil
        MusicPlayback.shared.stop()
    }

    @ViewBuilder private func sharerAvatar(_ s: FeedItemFfi) -> some View {
        if s.isMe {
            HavenAvatar(image: ProfileStore.shared.avatar, emoji: ProfileStore.shared.emoji, size: 30)
        } else {
            // Use the SAME resolution as everywhere else in the app (their synced photo → emoji →
            // initial) instead of a hand-rolled initial circle, which never showed the friend's real
            // profile picture on their story screens.
            let name = ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName
            PeerAvatar(nodeHex: s.authorShort, name: name, size: 30)
        }
    }

    private func next() {
        progress = 0
        if index + 1 < stories.count { index += 1; loadCurrent() } else { dismiss() }
    }
    private func prev() {
        progress = 0
        if index > 0 { index -= 1; loadCurrent() }
    }

    /// The author of the story at `i` (users are runs of same-author entries in the flat list).
    private func author(_ i: Int) -> String { stories.indices.contains(i) ? stories[i].authorShort : "" }

    /// Swipe-left: skip the rest of THIS person's stories and jump to the next person's FIRST story. Past
    /// the last person, dismiss (Instagram-style).
    private func skipToNextUser() {
        let cur = author(index)
        if let nextStart = stories.indices.first(where: { $0 > index && stories[$0].authorShort != cur }) {
            progress = 0; index = nextStart; loadCurrent()
        } else {
            dismiss()
        }
    }
    /// Swipe-right: jump to the PREVIOUS person's first story (or the start of the current person's run if
    /// we're already partway into it).
    private func skipToPrevUser() {
        let cur = author(index)
        // Start of the current person's run.
        var runStart = index
        while runStart > 0, stories[runStart - 1].authorShort == cur { runStart -= 1 }
        if index > runStart {
            progress = 0; index = runStart; loadCurrent()   // partway in → restart this person
            return
        }
        // Already at this person's first story → go to the previous person's first story.
        guard runStart > 0 else { return }
        let prevAuthor = stories[runStart - 1].authorShort
        var prevStart = runStart - 1
        while prevStart > 0, stories[prevStart - 1].authorShort == prevAuthor { prevStart -= 1 }
        progress = 0; index = prevStart; loadCurrent()
    }
}
