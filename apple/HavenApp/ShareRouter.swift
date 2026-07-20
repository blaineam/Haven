#if os(iOS)
import SwiftUI

/// Receives items handed off by the Share Extension (via the App Group inbox) and presents a small
/// sheet to send them as a post, a DM, or a story.
@MainActor
final class ShareRouter: ObservableObject {
    static let shared = ShareRouter()
    @Published var text = ""
    @Published var refs: [String] = []     // imported MediaStore refs (images/videos)
    @Published var present = false

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
                    let r = await MediaStore.shared.addVideo(url: url)
                    if !r.isEmpty { imported.append(r) }   // "" = refused (over the length limit)
                }
            }
        }
        ShareInbox.clear()
        guard !t.isEmpty || !imported.isEmpty else { return }
        text = t; refs = imported; present = true
    }

    func dismiss() { present = false; text = ""; refs = [] }
}

/// Small thumbnail for an imported ref.
private struct ShareThumb: View {
    let ref: String
    var body: some View {
        if let m = MediaStore.shared.item(ref), let img = m.image {
            Image(platformImage: img).resizable().scaledToFill()
        } else {
            Color(.secondarySystemBackground)
                .overlay(Image(systemName: "doc").foregroundStyle(.secondary))
        }
    }
}

/// The routing sheet: pick where the shared content goes.
struct ShareRouteView: View {
    @ObservedObject private var router = ShareRouter.shared
    @ObservedObject private var store = FeedStore.shared
    @State private var showStory = false

    var body: some View {
        NavigationStack {
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
}

/// Second step for the post / DM routes: pick a target + add a caption, then send.
private struct ShareComposeStep: View {
    enum Mode { case post, dm }
    let mode: Mode

    @ObservedObject private var router = ShareRouter.shared
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @State private var caption = ""
    @State private var targetCircle = ""
    @State private var targetContact = ""

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
                Section("To") {
                    ForEach(contacts.contacts) { c in
                        row(c.name.isEmpty ? String(c.idHex.prefix(6)) : c.name, selected: targetContact == c.idHex) {
                            targetContact = c.idHex
                        }
                    }
                }
            }
        }
        .navigationTitle(mode == .post ? "Share as Post" : "Direct Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Send") { send() }.disabled(!canSend) }
        }
        .onAppear {
            if mode == .post, targetCircle.isEmpty { targetCircle = store.feedCircles.first?.id ?? "" }
        }
    }

    private var canSend: Bool {
        let hasContent = !router.refs.isEmpty || !router.text.isEmpty || !caption.isEmpty
        return hasContent && (mode == .post ? !targetCircle.isEmpty : !targetContact.isEmpty)
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
            store.sendMessage(to: store.dmCircleId(with: targetContact), composedText, media: router.refs, music: nil)
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
