#if os(iOS)
import SwiftUI

/// Receives items handed off by the Share Extension (via the App Group inbox) and presents a small
/// sheet to send them as a post, a DM, or a story.
@MainActor
final class ShareRouter: ObservableObject {
    static let shared = ShareRouter()
    @Published var text = ""
    @Published var refs: [String] = []     // imported MediaStore refs (images/videos/documents)
    @Published var present = false
    /// The conversation the user picked in the share sheet's suggestion row, if they came in that
    /// way — see `ShareSuggestions`. When set, the sheet opens straight into that thread's composer
    /// instead of asking where the content should go.
    @Published var preselectedThread: String?
    /// The extension chose Story — open the story composer, not the routing list.
    @Published var openStoryDirectly = false
    /// The extension chose Post — hand the media to the feed's own composer, which is where the
    /// circle switcher, the song picker and the location toggle live. Consumed once by `FeedView`.
    struct PostDraft: Equatable { var text: String; var refs: [String] }
    @Published var postDraft: PostDraft?
    /// Set alongside `postDraft` so the app can switch to the circle tab.
    @Published var openPostComposer = false
    /// A caption typed in the extension, carried into whichever composer opens.
    @Published var pendingCaption = ""

    /// Drain the queue. Called on `haven://share` and on every foreground.
    ///
    /// **Every** queued share is processed, oldest first — not just the newest. Shares that only
    /// need sending (a DM the extension already addressed) go out immediately and silently, however
    /// many are waiting; the first one that needs the user, needs the user, so anything after it
    /// stays queued for the next pass rather than fighting over one sheet.
    func ingest() async {
        ShareInbox.sweepAbandoned()
        for queued in ShareInbox.drain() {
            // A composer is already up (our sheet, or the feed's own with a handed-over draft) —
            // the rest keep until it's done rather than clobbering unsent work.
            if present || postDraft != nil { return }
            let handled = await consume(queued)
            ShareInbox.clear(queued.id)
            // `consume` returning false means it raised UI; stop draining and let the user finish.
            if !handled { return }
        }
    }

    /// Import one share and act on it. Returns true when it was fully dealt with (sent, or nothing
    /// usable in it) and false when it put something on screen that the user has to finish.
    private func consume(_ queued: ShareInbox.Queued) async -> Bool {
        let payload = queued.payload
        var t = ""
        var imported: [String] = []
        for item in payload.items {
            switch item.kind {
            case .text:
                t = t.isEmpty ? item.text : t + "\n" + item.text
            case .image:
                if let url = ShareInbox.fileURL(item.file, in: queued.id), let data = try? Data(contentsOf: url),
                   let img = PlatformImage(data: data) {
                    imported.append(MediaStore.shared.addImage(img))
                }
            case .video:
                if let url = ShareInbox.fileURL(item.file, in: queued.id) {
                    let bundle = await MediaStore.shared.prepareVideo(url: url)
                    if !bundle.isEmpty { imported.append(contentsOf: bundle.mediaRefs) }
                }
            case .file:
                // A document rides as a `file_` attachment, exactly like one picked in-app. The
                // extension already copied it into the App Group, so this reads our own container.
                if let url = ShareInbox.fileURL(item.file, in: queued.id) {
                    let named = renamedForAttachment(url, to: item.name)
                    let ref = MediaStore.shared.addFile(url: named)
                    if named != url { try? FileManager.default.removeItem(at: named) }
                    if !ref.isEmpty { imported.append(ref) }
                }
            }
        }
        guard !t.isEmpty || !imported.isEmpty else { return true }
        text = t
        refs = imported

        // The extension already asked where this goes — act on it rather than asking again.
        if payload.route != .undecided { return deliver(payload) }

        // Only honor a suggested thread that still exists on this device and isn't locked — a stale
        // donation (thread since deleted, circle since locked) falls back to the normal sheet.
        preselectedThread = validThread(payload.targetCircleId)
        present = true
        return false
    }

    /// Act on a decision made in the extension.
    ///
    /// Returns **true only when the share is finished** — i.e. a DM that actually went out. `post`
    /// and `story` open Haven's own composer (that's the point: circle picker, music, location,
    /// story layout), so they return false, which tells the drain loop to stop and let the user
    /// finish. A DM whose thread has since vanished or been locked also returns false and falls
    /// back to the in-app sheet rather than being dropped.
    private func deliver(_ payload: ShareInbox.Payload) -> Bool {
        let store = FeedStore.shared
        let body = [payload.caption, text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let target = payload.targetCircleId
        switch payload.route {
        case .undecided:
            return false
        case .story:
            pendingCaption = body
            preselectedThread = nil
            openStoryDirectly = true
            present = true
            return false
        case .post:
            // Straight into the feed's own composer, with the media and caption already loaded —
            // no sheet at all, because everything a post needs (circle, music, location, schedule)
            // is already attached to that composer and a second one would only be a worse copy.
            postDraft = PostDraft(text: body, refs: refs)
            openPostComposer = true
            text = ""; refs = []
            return false
        case .dm:
            // A thread that vanished or got locked between the share sheet opening and Haven coming
            // up. Rare, but the answer is to ask, not to send somewhere unintended.
            guard store.circles.contains(where: { $0.id == target }),
                  !CircleSettingsStore.shared.biometricRequired(target) else {
                preselectedThread = nil
                present = true
                return false
            }
            store.sendMessage(to: target, body, media: refs, music: nil)
            // Sent outright — clear state so the next queued share starts clean, WITHOUT touching
            // `present` (nothing was ever shown for this one).
            text = ""; refs = []; pendingCaption = ""
            return true
        }
    }

    /// The feed composer took the draft. Clearing it releases the drain loop for whatever else is
    /// queued behind this share.
    func consumePostDraft() {
        postDraft = nil
        openPostComposer = false
        Task { await ingest() }
    }

    func dismiss() {
        present = false; text = ""; refs = []
        preselectedThread = nil; openStoryDirectly = false; openPostComposer = false; pendingCaption = ""
        // Anything that piled up behind this one now gets its turn.
        Task { await ingest() }
    }

    /// `MediaStore.addFile` derives the attachment's name from the file on disk, and the inbox name
    /// is a collision-proof placeholder (`doc-0.pdf`). Put the sender's own filename back before
    /// handing it over, so the recipient sees what was actually shared.
    private func renamedForAttachment(_ url: URL, to original: String) -> URL {
        let clean = original
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != url.lastPathComponent else { return url }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.prefix(8) + "-" + clean)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return url }
        return dest
    }

    private func validThread(_ id: String) -> String? {
        guard id.hasPrefix("dm:"),
              FeedStore.shared.dmCircles.contains(where: { $0.id == id }),
              !CircleSettingsStore.shared.biometricRequired(id) else { return nil }
        return id
    }
}

/// Small thumbnail for an imported ref — a still for media, a labeled card for a document.
private struct ShareThumb: View {
    let ref: String
    var body: some View {
        if let m = MediaStore.shared.item(ref), let img = m.image {
            Image(platformImage: img).resizable().scaledToFill()
        } else {
            Color(.secondarySystemBackground)
                .overlay(Image(systemName: MediaKind(ref: ref) == .file ? "doc.fill" : "doc")
                    .foregroundStyle(.secondary))
        }
    }
}

/// Newest message time in a thread, for recency ordering. A plain function with a written-out
/// return type: both call sites sort on it, and inlining it made the surrounding expression large
/// enough to trip the type-checker's budget on some Xcode versions.
private enum ShareRouteRanking {
    @MainActor static func lastActivity(_ circleId: String) -> UInt64 {
        let stamps: [UInt64] = FeedStore.shared.messages(in: circleId).map(\.createdAt)
        return stamps.max() ?? 0
    }
}

/// One tappable conversation in the sheet's "Recent" strip.
private struct RecentThreadTile: View {
    let circleId: String
    @ObservedObject private var store = FeedStore.shared

    var body: some View {
        let name = store.displayName(forCircle: circleId)
        VStack(spacing: 6) {
            PeerAvatar(nodeHex: store.dmPartnerHex(circleId) ?? "", name: name, size: 52)
            Text(name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 64)
        }
    }
}

/// The routing sheet: pick where the shared content goes.
struct ShareRouteView: View {
    @ObservedObject private var router = ShareRouter.shared
    @ObservedObject private var store = FeedStore.shared
    @State private var showStory = false

    /// Unlocked DM threads, most recently active first — the same order the Messages list uses, and
    /// the in-app echo of the share sheet's own suggestion row.
    ///
    /// Written as statements with explicit types rather than one chained expression. The chain
    /// version (`.map` into an anonymous tuple, then `.filter`/`.sorted`/`.prefix`/`.map` over it)
    /// type-checked on some Xcode versions and blew the solver's budget on others — Xcode Cloud
    /// failed the iOS archive on it while a local Debug *and* Release build passed. Naming the
    /// intermediates costs nothing and takes the whole class of failure off the table.
    private var recentThreads: [String] {
        let unlocked: [String] = store.dmCircles
            .map(\.id)
            .filter { !CircleSettingsStore.shared.biometricRequired($0) }
        var active: [(id: String, at: UInt64)] = []
        for id in unlocked {
            let at = ShareRouteRanking.lastActivity(id)
            if at > 0 { active.append((id: id, at: at)) }
        }
        active.sort { $0.at > $1.at }
        return active.prefix(8).map(\.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                // Came in from a share-sheet suggestion: the destination is already decided, so skip
                // straight to writing the message.
                if let thread = router.preselectedThread {
                    ShareComposeStep(mode: .dm, preselected: thread)
                } else {
                    routeList
                }
            }
            // The extension picked Story: open its composer straight away rather than making the
            // user choose a destination they already chose.
            .onAppear { if router.openStoryDirectly { showStory = true } }
            // Backing out of the story composer used to reveal this sheet's routing list underneath
            // — a "where should this go?" question for content whose destination was already
            // chosen in the share sheet. When Story was the extension's choice there is nothing
            // sensible behind it, so closing the composer closes the whole thing.
            .onChange(of: showStory) { _, open in
                if !open, router.openStoryDirectly { router.dismiss() }
            }
            .havenFullScreenCover(isPresented: $showStory) {
                // `displayRefs`: a video is clip + poster + original, and the story composer wants
                // the clip, not its companions.
                StoryComposerView(draft: StoryDraft(refs: MediaVariants.displayRefs(router.refs))) { ref, caption, track in
                    Task { @MainActor in
                        // A long video becomes up to 5 consecutive story slides (same as the camera flow).
                        let parts = await MediaStore.shared.splitStoryVideo(ref)
                        for r in parts { store.postStory(media: [r], caption: caption, music: track) }
                        showStory = false; router.dismiss()
                    }
                } onDone: { showStory = false; router.dismiss() }
            }
        }
    }

    private var routeList: some View {
        List {
            if !router.refs.isEmpty {
                Section("Sharing") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // `displayRefs`, not the raw list. One shared VIDEO is three refs — the
                            // playable clip plus its poster and original companions — and drawing
                            // the array verbatim made a single clip look like three attachments,
                            // one of them a document icon. Same contract the feed renders under.
                            ForEach(MediaVariants.displayRefs(router.refs), id: \.self) { ref in
                                ShareThumb(ref: ref)
                                    .frame(width: 70, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if !router.text.isEmpty {
                Section("Text") { Text(router.text).font(.callout).lineLimit(5) }
            }
            if !recentThreads.isEmpty {
                Section("Recent") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(recentThreads, id: \.self) { id in
                                NavigationLink {
                                    ShareComposeStep(mode: .dm, preselected: id)
                                } label: {
                                    RecentThreadTile(circleId: id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            // The row icons are tinted EXPLICITLY. Inside a List, a `Label`'s systemImage picks up
            // the environment tint, which here is the system accent — so Haven's own sheet was
            // drawing stock iOS blue glyphs next to pink everything-else. A `.tint` on the row sets
            // the chevron/label colour, not the icon, so it has to be the icon that's coloured.
            Section {
                NavigationLink { ShareComposeStep(mode: .post) } label: {
                    routeLabel("Share as Post", systemImage: "square.and.pencil")
                }
                NavigationLink { ShareComposeStep(mode: .dm) } label: {
                    routeLabel("Send as Direct Message", systemImage: "bubble.left.and.bubble.right.fill")
                }
                if !router.refs.isEmpty {
                    Button { showStory = true } label: {
                        routeLabel("Create Story", systemImage: "camera.viewfinder")
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("Share to Haven")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { router.dismiss() }.tint(HavenTheme.pink)
            }
        }
    }

    private func routeLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(HavenTheme.pink)
                .frame(width: 24)
            Text(title).foregroundStyle(.primary)
        }
    }
}

/// Second step for the post / DM routes: pick a target + add a caption, then send.
///
/// A DM target is a **thread**, not a contact: that's what lets an existing group DM (a `dm:` circle
/// with three or more people) be a destination, and it's the same identifier the share sheet hands
/// back from a suggestion. Contacts you have no thread with yet are still offered — picking one
/// opens the DM the way the Messages tab would.
private struct ShareComposeStep: View {
    enum Mode { case post, dm }
    enum DMTarget: Equatable { case thread(String), contact(String) }

    let mode: Mode
    /// A thread chosen before this view appeared (share-sheet suggestion, or the Recent strip).
    var preselected: String? = nil

    @ObservedObject private var router = ShareRouter.shared
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @State private var caption = ""
    @State private var targetCircle = ""
    @State private var dmTarget: DMTarget?

    /// Existing unlocked threads, most recent first.
    private var threads: [String] {
        var ids: [String] = store.dmCircles
            .map(\.id)
            .filter { !CircleSettingsStore.shared.biometricRequired($0) }
        // Same reason as `recentThreads` above: kept as a statement, not folded into the chain.
        ids.sort { ShareRouteRanking.lastActivity($0) > ShareRouteRanking.lastActivity($1) }
        return ids
    }
    /// People you haven't started a thread with — so the picker isn't two rows for the same person.
    private var contactsWithoutThread: [Contact] {
        let existing = Set(threads)
        return contacts.contacts.filter { !existing.contains(store.dmCircleId(with: $0.idHex)) }
    }

    var body: some View {
        Form {
            Section { TextField("Add a caption…", text: $caption, axis: .vertical) }
            if mode == .post {
                Section("Circle") {
                    ForEach(store.feedCircles, id: \.id) { c in
                        row(c.name.isEmpty ? "Circle" : c.name, selected: targetCircle == c.id) { targetCircle = c.id }
                    }
                }
            } else {
                if !threads.isEmpty {
                    Section("Conversations") {
                        ForEach(threads, id: \.self) { id in
                            row(store.displayName(forCircle: id), selected: dmTarget == .thread(id)) {
                                dmTarget = .thread(id)
                            }
                        }
                    }
                }
                if !contactsWithoutThread.isEmpty {
                    Section("Other people") {
                        ForEach(contactsWithoutThread) { c in
                            row(c.displayName.isEmpty ? String(c.idHex.prefix(6)) : c.displayName,
                                selected: dmTarget == .contact(c.idHex)) {
                                dmTarget = .contact(c.idHex)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(mode == .post ? "Share as Post" : navTitleForDM)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Send") { send() }.disabled(!canSend) }
            // A preselected thread is the sheet's root, so it needs its own way out.
            if preselected != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { router.dismiss() } }
            }
        }
        .onAppear {
            if mode == .post, targetCircle.isEmpty { targetCircle = store.feedCircles.first?.id ?? "" }
            if mode == .dm, dmTarget == nil, let preselected { dmTarget = .thread(preselected) }
        }
    }

    private var navTitleForDM: String {
        if let preselected { return store.displayName(forCircle: preselected) }
        return "Direct Message"
    }

    private var canSend: Bool {
        let hasContent = !router.refs.isEmpty || !router.text.isEmpty || !caption.isEmpty
        return hasContent && (mode == .post ? !targetCircle.isEmpty : dmTarget != nil)
    }

    /// Caption first, then the shared text/link beneath it.
    private var composedText: String {
        [caption, router.text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func send() {
        switch mode {
        case .post:
            store.postScheduled(circleId: targetCircle, body: composedText, media: router.refs)
        case .dm:
            guard let dmTarget else { return }
            let circleId: String
            switch dmTarget {
            case .thread(let id):
                circleId = id
            case .contact(let hex):
                // No thread yet — open it exactly as the Messages tab does, so the peer gets the
                // hello and the circle is created on both sides before the message lands.
                circleId = store.startDM(with: hex, name: ContactsStore.shared.name(forNodePrefix: hex) ?? "Direct message")
            }
            store.sendMessage(to: circleId, composedText, media: router.refs, music: nil)
        }
        router.dismiss()
    }

    private func row(_ title: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            HStack {
                Text(title); Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(HavenTheme.pink) }
            }
        }
        .tint(.primary)
    }
}
#endif
