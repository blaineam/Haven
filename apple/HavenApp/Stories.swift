import SwiftUI
import AVKit
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
    let stories: [FeedItemFfi]
    @State var index: Int
    let friendName: String
    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var player: AVPlayer?
    @State private var endObserver: Any?   // the loop observer's token — MUST be removed or the player leaks
    @State private var slideDuration = 5.0   // photos 5s; videos last their clip (≤15s)
    @State private var profilePeer: StoryProfile?   // tapped a sharer → peek their profile
    @State private var paused = false               // paused while the profile sheet is up
    @State private var dragOffset: CGFloat = 0      // swipe-down-to-dismiss
    @State private var replyText = ""
    @State private var replySent = false
    @State private var waitingMedia: String?   // a story whose bytes are still downloading
    @State private var retryCounter = 0
    @State private var confirmDeleteStory = false   // confirm unsending your own story
    @State private var heldPaused = false            // press-and-hold pauses the timer + video
    @FocusState private var replyFocused: Bool
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    struct StoryProfile: Identifiable { let id = UUID(); let hex: String; let name: String }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, dragOffset / 500)).ignoresSafeArea()
            Group {
                if stories.indices.contains(index) {
                    content(stories[index]).ignoresSafeArea()
                }
                // Prev/next tap zones — kept BELOW the overlay so the header's tappable
                // name/avatar + buttons receive their taps first.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { prev() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { next() }
                }
                if stories.indices.contains(index) {
                    positionedCaption(stories[index])
                    overlay(stories[index])
                }
            }
            .offset(y: dragOffset)
        }
        .havenStatusBarHidden()
        // Swipe DOWN to dismiss; swipe LEFT/RIGHT to skip whole users (Instagram-style — a horizontal
        // swipe jumps past the rest of THIS person's stories to the next/previous person's first story).
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
        // Press-and-hold anywhere to pause the timer + the video (Instagram-style); release resumes.
        // A quick tap still navigates via the prev/next zones (the brief pause is imperceptible).
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !heldPaused { heldPaused = true; player?.pause() } }
                .onEnded { _ in if heldPaused { heldPaused = false; player?.play() } }
        )
        .onAppear { loadCurrent() }
        .onDisappear { teardown() }
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
    }

    @ViewBuilder private func content(_ s: FeedItemFfi) -> some View {
        if waitingMedia != nil {
            downloading
        } else {
            GeometryReader { geo in
                // The author's framing (zoom + reposition) travels in the caption spec.
                let tf = StoryCaptions.decode(s.body).spec
                ZStack {
                    // Blurred fill backdrop so off-ratio media (landscape, etc.) sits in the standard
                    // story frame instead of leaving plain black bands. The still covers photo + video.
                    if let ref = s.media.first, let img = MediaStore.shared.item(ref)?.image {
                        Image(platformImage: img).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 28).overlay(Color.black.opacity(0.28))
                    }
                    Group {
                        if let player {
                            VideoSurface(player: player, fill: true)   // full-bleed, matching the editor
                        } else if let ref = s.media.first, let img = MediaStore.shared.item(ref)?.image {
                            Image(platformImage: img).resizable().scaledToFill()
                        } else {
                            missing
                        }
                    }
                    .scaleEffect(tf.mediaScale)
                    .offset(x: tf.mediaOffX * geo.size.width, y: tf.mediaOffY * geo.size.height)
                    // Blur a sensitive received story (local SCA or a circle member's federated flag).
                    .sensitiveContentGuard(ref: s.media.first ?? "", circleId: FeedStore.shared.activeCircleId,
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

    private func overlay(_ s: FeedItemFfi) -> some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(stories.indices, id: \.self) { i in
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
            HStack(spacing: 8) {
                if s.isMe {
                    sharerAvatar(s)
                    Text("Your story").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    // Same relay-backup signal as a feed post: while viewing your OWN story, show whether
                    // its photo/video has reached a relay yet (↑ uploading, ✓ backed up) — so "did my story
                    // actually sync?" has a visible answer instead of a guess.
                    if !s.media.isEmpty,
                       !RelayMailboxStore.shared.relays(forCircle: FeedStore.shared.activeCircleId).isEmpty {
                        TimelineView(.periodic(from: .now, by: 2.0)) { _ in
                            let blobs = s.media.filter { !MediaStore.isSynthetic($0) }
                            let backed = !blobs.isEmpty && blobs.allSatisfy { MediaBackupLedger.hasAny($0) }
                            Image(systemName: backed ? "checkmark.icloud.fill" : "arrow.up.circle")
                                .font(.caption2).foregroundStyle(.white.opacity(backed ? 0.9 : 0.7))
                                .help(backed ? "Backed up to a relay" : "Uploading to a relay…")
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
                    }
                    .buttonStyle(.plain)
                }
                Text(relativeTimeShort(s.createdAt)).font(.caption2).foregroundStyle(.white.opacity(0.7))
                Spacer()
                if s.isMe {
                    Button {
                        // Convert this story into a permanent (non-expiring) post.
                        FeedStore.shared.post(StoryCaptions.decode(s.body).text,
                                              media: s.media, music: s.music, retentionSecs: nil, story: false)
                        dismiss()
                    } label: {
                        Label("Keep", systemImage: "bookmark.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            // Real glass, not a hand-rolled white scrim — and .plain so macOS
                            // paints no bezel behind the pill.
                            .havenGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // Unsend (delete) your own story — removes it everywhere it was shared.
                    Button {
                        paused = true; player?.pause(); confirmDeleteStory = true
                    } label: {
                        Image(systemName: "trash").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .havenGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(GlassIconButtonStyle(size: 30, tint: .white))
            }
            .padding(.horizontal).padding(.top, 4)
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
    }

    /// The caption rendered where the author dragged it (position travels in the spec).
    @ViewBuilder private func positionedCaption(_ s: FeedItemFfi) -> some View {
        if !s.body.isEmpty {
            let decoded = StoryCaptions.decode(s.body)
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
        // Attach the story being replied to (its media) so the author knows which one — sendMessage
        // re-seals the media to the DM circle via SharedStore.backup. Cross-platform parity w/ Android.
        FeedStore.shared.sendMessage(to: dm, text, media: s.media, music: nil)
        replyText = ""
        replyFocused = false
        withAnimation { replySent = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { withAnimation { replySent = false } }
        }
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
        if let m = s.music { MusicPlayback.shared.play(m) } else { MusicPlayback.shared.stop() }
        // If the bytes haven't arrived yet (a dropped chunk on a big video), wait and
        // actively re-request instead of hanging forever on a stale "Loading…".
        if let ref = s.media.first, !MediaStore.shared.has(ref) {
            waitingMedia = ref
            retryCounter = 0
            FeedStore.shared.requestMedia(ref)
            player = nil
            return
        }
        waitingMedia = nil
        if let ref = s.media.first, let item = MediaStore.shared.item(ref),
           item.kind == .video, let url = item.videoURL {
            let p = AVPlayer(url: url)
            // Muted under the author's song — or while a call is ringing/live (call audio priority).
            p.isMuted = (s.music != nil) || CallManager.shared.callInProgress
            // Weak capture + keep the token so loadCurrent/teardown can remove it. A strong capture +
            // discarded token is exactly what leaked every story player forever.
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: p.currentItem, queue: .main) { [weak p] _ in
                p?.seek(to: .zero); p?.play()
            }
            player = p
            p.play()
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
