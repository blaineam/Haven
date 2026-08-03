import SwiftUI
import UIKit

/// The share sheet's own compose screen — caption, destination, send — drawn **inside the
/// extension** so tapping Haven opens something instead of just dismissing.
///
/// It deliberately does no sending. The extension has no identity, no engine and seconds to live;
/// what it produces is a decision, written to the App Group beside the media. The app performs the
/// sealed send (`ShareRouter.ingest`) the moment it comes up — which is immediately when the
/// extension manages to open it, and otherwise the next time the user opens Haven.
///
/// Destinations come from `SharedDestinations`, a snapshot the app leaves behind. If it's empty
/// (fresh install, app never opened since the update) the view says so and falls back to handing
/// the whole decision to the app rather than pretending there's nowhere to send.
struct ShareComposeView: View {
    /// Thumbnails for what's being shared (already extracted by the controller).
    let previews: [UIImage]
    /// How many attachments there are in total, including ones with no thumbnail (documents).
    let attachmentCount: Int
    /// The shared text/link, shown under the caption field.
    let sharedText: String
    /// A conversation chosen in the share sheet's suggestion row, if we were launched from one.
    let preselected: String?
    let onSend: (ShareInbox.Route, String, String) -> Void   // route, target circle id, caption
    let onCancel: () -> Void

    @State private var caption = ""
    @State private var target: String
    @State private var destinations: [SharedDestinations.Item] = []
    @State private var sending = false

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

    private var conversations: [SharedDestinations.Item] { destinations.filter(\.isDM) }
    private var circles: [SharedDestinations.Item] { destinations.filter { !$0.isDM } }
    private var chosen: SharedDestinations.Item? { destinations.first { $0.id == target } }
    private var canSend: Bool {
        !sending && !target.isEmpty && (attachmentCount > 0 || !sharedText.isEmpty || !caption.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !previews.isEmpty || attachmentCount > 0 {
                    Section("Sharing") { attachmentStrip }
                }
                Section {
                    TextField("Add a caption…", text: $caption, axis: .vertical)
                    if !sharedText.isEmpty {
                        Text(sharedText).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if destinations.isEmpty {
                    Section {
                        Text("Open Haven to choose where this goes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    if !conversations.isEmpty {
                        Section("Conversations") {
                            ForEach(conversations) { row($0) }
                        }
                    }
                    if !circles.isEmpty {
                        Section("Circles") {
                            ForEach(circles) { row($0) }
                        }
                    }
                    // A story has an editor (caption placement, a song) that belongs in the app —
                    // this picks the destination, and Haven opens that editor with the media loaded.
                    if attachmentCount > 0 {
                        Section {
                            Button {
                                target = Self.storyTarget
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "camera.viewfinder")
                                        .foregroundStyle(HavenShareTheme.pink).frame(width: 32)
                                    Text("Your story").foregroundStyle(.primary)
                                    Spacer()
                                    if target == Self.storyTarget {
                                        Image(systemName: "checkmark").foregroundStyle(HavenShareTheme.pink)
                                    }
                                }
                            }
                            .tint(.primary)
                        } footer: {
                            Text("Opens Haven's story editor with this ready to go.")
                        }
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
                    Button(sendLabel) { send() }
                        .fontWeight(.semibold)
                        .tint(HavenShareTheme.pink)
                        .disabled(!canSend && !destinations.isEmpty)
                }
            }
            .tint(HavenShareTheme.pink)
        }
        .onAppear { destinations = SharedDestinations.read() }
    }

    /// With no mirror to pick from, the only honest button is one that hands over to the app.
    private var sendLabel: String { destinations.isEmpty ? "Continue" : "Send" }

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

    private func row(_ item: SharedDestinations.Item) -> some View {
        Button {
            target = item.id
        } label: {
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

    /// Sentinel id for the story row — not a real circle, so it never collides with one.
    private static let storyTarget = "__haven.story__"

    private func send() {
        sending = true
        if target == Self.storyTarget { onSend(.story, "", caption); return }
        // No mirror → we genuinely don't know the destinations, so hand the whole decision over.
        guard !destinations.isEmpty, let chosen else {
            onSend(.undecided, "", caption)
            return
        }
        onSend(chosen.isDM ? .dm : .post, chosen.id, caption)
    }
}

/// A destination's face: the mirrored avatar, else a tinted monogram.
private struct DestinationAvatar: View {
    let item: SharedDestinations.Item

    var body: some View {
        if let url = SharedDestinations.avatarURL(item.avatarFile),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 32, height: 32).clipShape(Circle())
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
