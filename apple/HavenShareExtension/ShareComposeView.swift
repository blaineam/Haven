import SwiftUI
import UIKit

/// The share sheet's own compose screen — drawn **inside the extension** so tapping Haven opens
/// something instead of just dismissing.
///
/// **Where the line is drawn.** A direct message is finished here: it's a person and some words,
/// and making you open the app to type them defeats the point of a share sheet. A post or a story
/// is *not* — those have composers that own the circle picker, attached music, whether to include
/// your location, and (for a story) the whole layout editor. Rebuilding a lesser version of that
/// here would quietly cost you features, so those two routes carry the media into Haven's real
/// composer instead.
///
/// It never sends. The extension has no identity, no engine and seconds to live; what it produces is
/// a decision written to the App Group queue beside the media. `ShareRouter` acts on it when the app
/// is next frontmost.
struct ShareComposeView: View {
    let previews: [UIImage]
    let attachmentCount: Int
    let sharedText: String
    /// A conversation chosen in the share sheet's suggestion row, if we were launched from one.
    let preselected: String?
    let onSend: (ShareInbox.Route, String, String) -> Void   // route, target circle id, caption
    let onCancel: () -> Void

    @State private var caption = ""
    @State private var target: String
    @State private var conversations: [SharedDestinations.Item] = []

    init(previews: [UIImage], attachmentCount: Int, sharedText: String, preselected: String?,
         onSend: @escaping (ShareInbox.Route, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.previews = previews
        self.attachmentCount = attachmentCount
        self.sharedText = sharedText
        self.preselected = preselected
        self.onSend = onSend
        self.onCancel = onCancel
        _target = State(initialValue: preselected ?? "")
    }

    private var hasContent: Bool { attachmentCount > 0 || !sharedText.isEmpty || !caption.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if attachmentCount > 0 { Section("Sharing") { attachmentStrip } }
                Section {
                    TextField(target.isEmpty ? "Add a message…" : "Message", text: $caption, axis: .vertical)
                    if !sharedText.isEmpty {
                        Text(sharedText).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                // A post or a story goes to Haven's own composer — that's where the circle picker,
                // music and location live.
                Section {
                    handoffRow("Share as Post", systemImage: "square.and.pencil",
                               detail: "Pick a circle, add music or a location") {
                        onSend(.post, "", caption)
                    }
                    if attachmentCount > 0 {
                        handoffRow("Add to your Story", systemImage: "camera.viewfinder",
                                   detail: "Opens the story editor") {
                            onSend(.story, "", caption)
                        }
                    }
                }
                if conversations.isEmpty {
                    Section {
                        Text("Open Haven once to send directly to a conversation from here.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Send to") {
                        ForEach(conversations) { row($0) }
                    }
                }
            }
            .navigationTitle("Share to Haven")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.tint(HavenShareTheme.pink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSend(.dm, target, caption) }
                        .fontWeight(.semibold)
                        .tint(HavenShareTheme.pink)
                        .disabled(target.isEmpty || !hasContent)
                }
            }
            .tint(HavenShareTheme.pink)
        }
        .onAppear { conversations = SharedDestinations.read().filter(\.isDM) }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                // Documents have no thumbnail — say how many rather than showing nothing.
                if previews.count < attachmentCount {
                    let extra = attachmentCount - previews.count
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 64, height: 64)
                        .overlay {
                            VStack(spacing: 2) {
                                Image(systemName: "doc.fill").foregroundStyle(HavenShareTheme.pink)
                                Text(extra == attachmentCount ? "\(extra) file\(extra == 1 ? "" : "s")" : "+\(extra)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func handoffRow(_ title: String, systemImage: String, detail: String,
                            _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(HavenShareTheme.pink).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
        .disabled(!hasContent)
    }

    private func row(_ item: SharedDestinations.Item) -> some View {
        Button { target = item.id } label: {
            HStack(spacing: 10) {
                DestinationAvatar(item: item)
                Text(item.name).foregroundStyle(.primary)
                Spacer()
                if target == item.id {
                    Image(systemName: "checkmark").foregroundStyle(HavenShareTheme.pink)
                }
            }
        }
        .tint(.primary)
    }
}

/// A conversation's face: their photo, else the emoji they chose, else a monogram.
///
/// The emoji step is not decoration — it's how a good number of people are identified everywhere
/// else in Haven, and showing them a letter here made the share sheet the one place their friends
/// looked like strangers. Mirrors `PeerAvatar` in the app.
private struct DestinationAvatar: View {
    let item: SharedDestinations.Item

    var body: some View {
        if let url = SharedDestinations.avatarURL(item.avatarFile),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 32, height: 32).clipShape(Circle())
        } else if !item.emoji.isEmpty {
            Circle()
                .fill(Color(.secondarySystemBackground))
                .frame(width: 32, height: 32)
                .overlay { Text(item.emoji).font(.system(size: 17)) }
        } else {
            Circle()
                .fill(LinearGradient(colors: [HavenShareTheme.amber, HavenShareTheme.pink],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 32, height: 32)
                .overlay {
                    Text(String(item.name.prefix(1)))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
        }
    }
}

/// Haven's accent colours, duplicated here on purpose: the extension links its own tiny source set
/// and must not drag in the app's theme (and with it FeedStore, MediaStore, the FFI…). Keep in step
/// with `HavenTheme`.
enum HavenShareTheme {
    static let pink = Color(red: 0.925, green: 0.282, blue: 0.600)   // #EC4899
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)  // #F59E0B
}
