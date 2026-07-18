import SwiftUI

/// Full post editor — change the text, add/remove media, and swap or remove the song.
/// Saves an Edit event that updates the post in place (keeps its id, time, and thread).
struct EditPostSheet: View {
    let item: FeedItemFfi
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var media: [String]
    @State private var track: TrackRefFfi?
    @State private var muteVideo: Bool
    @State private var showMedia = false
    @State private var showSongs = false

    init(item: FeedItemFfi) {
        self.item = item
        _text = State(initialValue: item.body)
        _media = State(initialValue: item.media)
        _track = State(initialValue: item.music)
        _muteVideo = State(initialValue: item.muteVideo)
    }

    var body: some View {
        Group {
            #if os(macOS)
            // A NavigationStack toolbar lands Cancel/Save on gray system bands here, so macOS gets
            // the sheet scaffold instead: gradient to the edges, Save in the footer.
            HavenMacSheet("Edit post") {
                editorColumn
            } footer: {
                Button("Save") { save() }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(isEmpty)
                    .opacity(isEmpty ? 0.5 : 1)
                    .keyboardShortcut(.defaultAction)
            }
            #else
            iosBody
            #endif
        }
        .sheet(isPresented: $showMedia) { MediaPicker { refs in media.append(contentsOf: refs) }.macSheetFrame() }
        .sheet(isPresented: $showSongs) { SongPicker { t in track = t }.macSheetFrame() }.havenPausesPostAudio()
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && media.isEmpty }

    #if !os(macOS)
    private var iosBody: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollView { editorColumn.padding(16) }
            }
            .navigationTitle("Edit post")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .havenCancelLeading) {
                    Button("Cancel") { dismiss() }.havenToolbarPill()
                }
                ToolbarItem(placement: .havenTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .havenToolbarPill(tint: HavenTheme.pink)
                        .disabled(isEmpty)
                }
            }
        }
    }
    #endif

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            // One glass surface — no system bezel inside a custom shape (house rule).
            TextField("Say something…", text: $text, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.plain)
                .padding(12)
                .havenGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(media, id: \.self) { ref in
                            if let img = MediaStore.shared.item(ref)?.image {
                                ZStack(alignment: .topTrailing) {
                                    Image(platformImage: img).resizable().scaledToFill()
                                        .frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 12))
                                    removeButton(ref)
                                }
                            } else if SharedLocation.parse(ref) != nil {
                                // The attached location is a synthetic `geo:` ref, not a real
                                // media file — render it as a removable chip so the user can
                                // actually turn location off when editing.
                                ZStack(alignment: .topTrailing) {
                                    VStack(spacing: 2) {
                                        Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                                        Text("Location").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 84, height: 84)
                                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                    removeButton(ref)
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button { showMedia = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                Button { showSongs = true } label: { Label(track == nil ? "Song" : "Change", systemImage: "music.note") }
                if track != nil {
                    Button(role: .destructive) { track = nil } label: { Image(systemName: "xmark.circle") }
                }
                Spacer()
            }
            .buttonStyle(.bordered).tint(HavenTheme.pink)

            if let t = track {
                Label("\(t.title) · \(t.artist)", systemImage: "music.note")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Video audio choice (only when a video is present and no song —
            // a song always plays over a muted video).
            if track == nil && media.contains(where: { MediaStore.shared.item($0)?.kind == .video }) {
                Toggle(isOn: Binding(get: { !muteVideo }, set: { muteVideo = !$0 })) {
                    Label(muteVideo ? "Video muted (silent)" : "Play video sound",
                          systemImage: muteVideo ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .tint(HavenTheme.pink)
            }
            Spacer(minLength: 0)
        }
    }

    /// The corner "x" on an attachment: a glass circle over the thumbnail — it floats on media, so
    /// the system gives it no glass of its own (and the old hand-rolled black disc was the
    /// "recreation" we're replacing). One surface, and .plain so macOS adds no bezel behind it.
    private func removeButton(_ ref: String) -> some View {
        Button { media.removeAll { $0 == ref } } label: { Image(systemName: "xmark") }
            .buttonStyle(GlassIconButtonStyle(size: 22, tint: .white))
            .padding(3)
    }

    private func save() {
        FeedStore.shared.edit(item.id, text.trimmingCharacters(in: .whitespacesAndNewlines),
                              media: media, music: track, muteVideo: muteVideo)
        dismiss()
    }
}
