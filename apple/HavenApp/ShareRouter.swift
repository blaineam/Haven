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

    /// Drain the inbox: import any media into MediaStore, stash the text, raise the sheet. Called on
    /// `haven://share` and on foreground (in case the open-URL didn't fire).
    func ingest() async {
        guard !present, let payload = ShareInbox.read() else { return }
        var t = ""
        var imported: [String] = []
        for item in payload.items {
            switch item.kind {
            case .text:
                t = t.isEmpty ? item.text : t + "\n" + item.text
            case .image:
                if let url = ShareInbox.fileURL(item.file), let data = try? Data(contentsOf: url),
                   let img = PlatformImage(data: data) {
                    imported.append(MediaStore.shared.addImage(img))
                }
            case .video:
                if let url = ShareInbox.fileURL(item.file) {
                    let bundle = await MediaStore.shared.prepareVideo(url: url)
                    if !bundle.isEmpty { imported.append(contentsOf: bundle.mediaRefs) }
                }
            case .file:
                // A document rides as a `file_` attachment, exactly like one picked in-app. The
                // extension already copied it into the App Group, so this reads our own container.
                if let url = ShareInbox.fileURL(item.file) {
                    let named = renamedForAttachment(url, to: item.name)
                    let ref = MediaStore.shared.addFile(url: named)
                    if named != url { try? FileManager.default.removeItem(at: named) }
                    if !ref.isEmpty { imported.append(ref) }
                }
            }
        }
        ShareInbox.clear()
        guard !t.isEmpty || !imported.isEmpty else { return }
        text = t
        refs = imported
        // Only honor a suggested thread that still exists on this device and isn't locked — a stale
        // donation (thread since deleted, circle since locked) falls back to the normal sheet.
        preselectedThread = validThread(payload.targetCircleId)
        present = true
    }

    func dismiss() { present = false; text = ""; refs = []; preselectedThread = nil }

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
    private var recentThreads: [String] {
        store.dmCircles
            .map(\.id)
            .filter { !CircleSettingsStore.shared.biometricRequired($0) }
            .map { (id: $0, at: store.messages(in: $0).map(\.createdAt).max() ?? 0) }
            .filter { $0.at > 0 }
            .sorted { $0.at > $1.at }
            .prefix(8)
            .map(\.id)
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
            .havenFullScreenCover(isPresented: $showStory) {
                StoryComposerView(draft: StoryDraft(refs: router.refs)) { ref, caption, track in
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
                            ForEach(router.refs, id: \.self) { ref in
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
            Section {
                NavigationLink { ShareComposeStep(mode: .post) } label: {
                    Label("Share as Post", systemImage: "square.and.pencil")
                }
                NavigationLink { ShareComposeStep(mode: .dm) } label: {
                    Label("Send as Direct Message", systemImage: "bubble.left.and.bubble.right.fill")
                }
                if !router.refs.isEmpty {
                    Button { showStory = true } label: {
                        Label("Create Story", systemImage: "camera.viewfinder")
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("Share to Haven")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { router.dismiss() } }
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
        store.dmCircles
            .map(\.id)
            .filter { !CircleSettingsStore.shared.biometricRequired($0) }
            .sorted { (store.messages(in: $0).map(\.createdAt).max() ?? 0) > (store.messages(in: $1).map(\.createdAt).max() ?? 0) }
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
