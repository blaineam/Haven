import AVFoundation
import MediaPlayer
import MusicKit
import SwiftUI

/// Parse a track's encoded id "<storeID>~<persistentID>" (either part may be absent).
func trackIds(_ catalogId: String) -> (store: String?, pid: UInt64?) {
    let parts = catalogId.split(separator: "~", maxSplits: 1, omittingEmptySubsequences: false)
    let store = parts.first.map(String.init).flatMap { ($0.isEmpty || $0 == "0") ? nil : $0 }
    let pid = parts.count > 1 ? UInt64(parts[1]) : nil
    return (store, pid)
}

#if os(iOS)
/// The exact library song matching a persistent id, if it exists on this device.
/// (`MPMediaQuery`/`MPMediaItem` are iOS/Catalyst-only.)
@MainActor func librarySong(_ pid: UInt64) -> MPMediaItem? {
    let q = MPMediaQuery.songs()
    q.addFilterPredicate(MPMediaPropertyPredicate(value: pid, forProperty: MPMediaItemPropertyPersistentID))
    return q.items?.first
}

/// Whether a local-library song with this persistent id exists — WITHOUT touching the main thread or
/// returning a non-Sendable `MPMediaItem`. `MPMediaQuery.items` scans the whole songs table synchronously;
/// running it inline on the main actor was the residual scroll hitch when the feed settled on a music post,
/// so the feed probes existence off-main (only a Bool crosses back) and lets MediaPlayer load the queue.
/// `MPMediaQuery` is safe to run off the main thread.
nonisolated func librarySongExists(_ pid: UInt64) -> Bool {
    let q = MPMediaQuery.songs()
    q.addFilterPredicate(MPMediaPropertyPredicate(value: pid, forProperty: MPMediaItemPropertyPersistentID))
    return q.items?.isEmpty == false
}
#else
/// Native macOS has no `MPMediaQuery`; the on-device library isn't reachable. Catalog tracks
/// (MusicKit) still play. Returns nil so library-only playback paths fall through.
@MainActor func librarySong(_ pid: UInt64) -> Never? { nil }
#endif

/// An in-app song picker that lets you choose a song to attach to a post. Each viewer plays
/// it through their own Apple Music, so Haven shares the *reference*, not the file.
///
/// On iOS/Catalyst you can also browse **Your Library** and hear a preview before picking. On
/// native macOS, `MPMediaQuery`/`MPMusicPlayerController` are unavailable, so the picker is
/// **Apple Music catalog**-only (search + pick; in-picker preview is an iOS feature).
struct SongPicker: View {
    var onPick: (TrackRefFfi) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable { case library = "Your Library", catalog = "Apple Music" }
    #if os(iOS)
    @State private var source: Source = .library
    #else
    @State private var source: Source = .catalog
    #endif
    @State private var query = ""
    @State private var previewing: String?          // unified key: persistentID or catalog id
    @State private var catalog: [MusicKit.Song] = []
    @State private var catalogNote: String?
    @State private var searchTask: Task<Void, Never>?
    #if os(macOS)
    private let macPreviewPlayer = AVPlayer()   // catalog preview clips (no MPMusicPlayerController on Mac)
    #endif

    #if os(iOS)
    @State private var libraryDenied = false
    @State private var songs: [MPMediaItem] = []
    @State private var hiddenLibraryCount = 0
    private let preview = MPMusicPlayerController.applicationMusicPlayer

    private var filteredLibrary: [MPMediaItem] {
        guard !query.isEmpty else { return songs }
        return songs.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query) ||
            ($0.artist ?? "").localizedCaseInsensitiveContains(query)
        }
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                VStack(spacing: 0) {
                    #if os(iOS)
                    Picker("", selection: $source) {
                        ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.top, 8)

                    if source == .library { libraryList } else { catalogList }
                    #else
                    catalogList
                    #endif
                }
            }
            .navigationTitle("Pick a song")
            #if os(iOS)
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { stopPreview(); dismiss() }.havenToolbarPill() } }
            .searchable(text: $query, prompt: source == .library ? "Search your music" : "Search Apple Music")
            .onAppear(perform: loadLibrary)
            #else
            .toolbar { ToolbarItem { Button("Cancel") { stopPreview(); dismiss() } } }
            .searchable(text: $query, prompt: "Search Apple Music")
            #endif
            .onDisappear(perform: stopPreview)
            .onChange(of: source) { _, s in
                stopPreview()
                if s == .catalog && !query.isEmpty { scheduleCatalogSearch() }
            }
            .onChange(of: query) { _, _ in if source == .catalog { scheduleCatalogSearch() } }
        }
        #if os(macOS)
        // A macOS sheet sizes to content; the song list collapsed to a sliver. Give it a real frame.
        .frame(minWidth: 460, idealWidth: 540, minHeight: 560, idealHeight: 660)
        #endif
        .havenPausesPostAudio()
    }

    // MARK: - Library (iOS/Catalyst only)

    #if os(iOS)
    @ViewBuilder private var libraryList: some View {
        if libraryDenied {
            ContentUnavailableView("Music access off", systemImage: "music.note.list",
                                   description: Text("Allow access to your music in Settings to pick a song."))
        } else {
            List {
                if hiddenLibraryCount > 0 {
                    Text("\(hiddenLibraryCount) song\(hiddenLibraryCount == 1 ? "" : "s") in your library aren't on Apple Music, so they can't be shared — your circle wouldn't be able to play them.")
                        .font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                ForEach(filteredLibrary, id: \.persistentID) { item in
                    songRow(title: item.title ?? "Unknown song", artist: item.artist ?? "", key: "\(item.persistentID)",
                            artwork: { libraryArtwork(item) },
                            onPreview: { togglePreviewLibrary(item) }, onUse: { chooseLibrary(item) })
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
    #endif

    // MARK: - Apple Music catalog (all platforms)

    @ViewBuilder private var catalogList: some View {
        if let note = catalogNote {
            ContentUnavailableView("Apple Music", systemImage: "music.note", description: Text(note))
        } else if catalog.isEmpty {
            ContentUnavailableView("Search Apple Music", systemImage: "magnifyingglass",
                                   description: Text("Find any song in the catalog."))
        } else {
            List(catalog, id: \.id) { song in
                songRow(title: song.title, artist: song.artistName, key: song.id.rawValue,
                        artwork: { catalogArtwork(song) },
                        onPreview: { togglePreviewCatalog(song) }, onUse: { chooseCatalog(song) })
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func songRow<A: View>(title: String, artist: String, key: String,
                                  @ViewBuilder artwork: () -> A,
                                  onPreview: @escaping () -> Void, onUse: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                artwork()
                // Tap the artwork (or the title, below) to preview; the play/pause sits on the artwork,
                // Apple-Music-style. macOS previews via AVPlayer + the catalog preview asset.
                Button(action: onPreview) {
                    Image(systemName: previewing == key ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { onPreview() }
            Spacer()
            Button("Use", action: onUse)
                .font(.subheadline.weight(.semibold)).tint(HavenTheme.pink).buttonStyle(.bordered)
        }
        .listRowBackground(Color.clear)
    }

    /// Placeholder tile when a song has no artwork.
    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.2))
            .overlay(Image(systemName: "music.note").font(.system(size: 18)).foregroundStyle(.secondary))
    }

    /// Apple Music catalog artwork via MusicKit's `ArtworkImage`.
    @ViewBuilder private func catalogArtwork(_ song: MusicKit.Song) -> some View {
        if let art = song.artwork {
            ArtworkImage(art, width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            artworkPlaceholder
        }
    }

    #if os(iOS)
    /// Library-song artwork rendered from the `MPMediaItem` (iOS/Catalyst only).
    @ViewBuilder private func libraryArtwork(_ item: MPMediaItem) -> some View {
        if let img = item.artwork?.image(at: CGSize(width: 88, height: 88)) {
            Image(uiImage: img).resizable().scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            artworkPlaceholder
        }
    }
    #endif

    // MARK: - Loading + search

    #if os(iOS)
    private func loadLibrary() {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { libraryDenied = true; return }
                let all = (MPMediaQuery.songs().items ?? []).sorted { ($0.title ?? "") < ($1.title ?? "") }
                // Only songs that exist in the Apple Music catalog can be shared — everyone
                // plays the reference through their own Apple Music. Drop library-only items
                // (imported/ripped tracks with no catalog id) so no one shares an unplayable song.
                songs = all.filter { Self.isCatalogPlayable($0) }
                hiddenLibraryCount = all.count - songs.count
            }
        }
    }

    /// Whether a library item is backed by an Apple Music catalog id (so others can play it).
    static func isCatalogPlayable(_ item: MPMediaItem) -> Bool {
        let sid = item.playbackStoreID
        return !sid.isEmpty && sid != "0"
    }
    #endif

    private func scheduleCatalogSearch() {
        searchTask?.cancel()
        let term = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)   // debounce keystrokes
            if Task.isCancelled { return }
            await runCatalogSearch(term)
        }
    }

    private func runCatalogSearch(_ term: String) async {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { catalog = []; catalogNote = nil; return }
        let status = await MusicAuthorization.request()
        guard status == .authorized else { catalogNote = "Allow Apple Music access to search the catalog."; return }
        do {
            var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            req.limit = 25
            let res = try await req.response()
            catalog = Array(res.songs)
            catalogNote = catalog.isEmpty ? "No songs found." : nil
        } catch {
            catalogNote = "Couldn't reach Apple Music — check your connection or subscription."
        }
    }

    // MARK: - Preview + choose

    #if os(iOS)
    private func togglePreviewLibrary(_ item: MPMediaItem) {
        let key = "\(item.persistentID)"
        if previewing == key { stopPreview() }
        else { preview.setQueue(with: MPMediaItemCollection(items: [item])); preview.play(); previewing = key }
    }
    private func togglePreviewCatalog(_ song: MusicKit.Song) {
        let key = song.id.rawValue
        if previewing == key { stopPreview() }
        else { preview.setQueue(with: [key]); preview.play(); previewing = key }
    }
    private func stopPreview() {
        if previewing != nil { preview.stop() }
        previewing = nil
    }
    private func chooseLibrary(_ item: MPMediaItem) {
        stopPreview()
        onPick(TrackRefFfi(
            catalogId: "\(item.playbackStoreID)~\(item.persistentID)",
            title: item.title ?? "Unknown song",
            artist: item.artist ?? "",
            artworkUrl: "",
            durationMs: UInt64(max(0, item.playbackDuration) * 1000)
        ))
        dismiss()
    }
    #else
    // Native macOS: preview the Apple Music catalog clip via AVPlayer (no MPMusicPlayerController).
    private func togglePreviewCatalog(_ song: MusicKit.Song) {
        let key = song.id.rawValue
        if previewing == key { stopPreview(); return }
        guard let url = song.previewAssets?.first?.url else { return }
        macPreviewPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        macPreviewPlayer.play()
        previewing = key
    }
    private func stopPreview() {
        macPreviewPlayer.pause()
        macPreviewPlayer.replaceCurrentItem(with: nil)
        previewing = nil
    }
    #endif

    private func chooseCatalog(_ song: MusicKit.Song) {
        stopPreview()
        // Catalog songs have no local persistent id — encode just the store id ("<id>~").
        onPick(TrackRefFfi(
            catalogId: "\(song.id.rawValue)~",
            title: song.title,
            artist: song.artistName,
            artworkUrl: "",
            durationMs: UInt64((song.duration ?? 0) * 1000)
        ))
        dismiss()
    }
}
