import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

#if !os(macOS)

/// A friendly photo/video picker (Photos library). Works in the Simulator, so the
/// whole attach → seal → feed path is verifiable without a camera. Returns media
/// refs registered in `MediaStore`.
///
/// Delivery is INCREMENTAL. `onSelected` fires the moment the person taps Add with how many items
/// they chose, before a byte has been read — the composer draws one placeholder per item so a
/// seven-photo pick is visibly "working" instead of a sheet that closed on nothing. Then every item
/// is read and optimized OFF the main thread (`MediaStore.prepareImage`) and handed over as it
/// lands, in selection order (`onPicked` + `onSettled`), each one replacing a placeholder. The old
/// shape waited for the LAST item and then appended the whole batch at once: with 48 MP ProRAW
/// frames that was half a minute of nothing, so the person picked again, and again, and every one
/// of those abandoned batches kept decoding on the main thread long after the post went out.
struct MediaPicker: UIViewControllerRepresentable {
    var onPicked: ([String]) -> Void
    /// How many items were chosen (called once, on main, before the sheet closes).
    var onSelected: ((Int) -> Void)? = nil
    /// How many chosen items each `onPicked` batch settles — equal to the placeholders to retire.
    /// An item that failed to load settles too (with no refs), so the count always reaches zero.
    var onSettled: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 30
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker
        private var finished = false
        init(_ parent: MediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Tapping "Add" more than once before the picker dismissed fired this delegate twice, so
            // every selected item was added to the post 2× (the doubled photos/videos). Process the
            // selection exactly once.
            guard !finished else { return }
            finished = true
            let providers = results.map(\.itemProvider)
            // KICK OFF every transfer NOW, while the picker's data connection is still live — the in-flight
            // loads survive dismissal. THEN dismiss immediately, so a big video copy never leaves the
            // picker frozen on screen ("can't select a video or dismiss"). Loading AFTER dismiss fails —
            // the Photos picker's out-of-process connection is gone, so nothing attaches (the build-142
            // regression).
            guard !providers.isEmpty else { parent.dismiss(); return }
            let total = providers.count
            parent.onSelected?(total)
            // The circle's optimize setting is main-actor state; read it once here and carry it to the
            // decode queue rather than hopping back for every item.
            let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
            let batch = Batch(total: total, onPicked: parent.onPicked, onSettled: parent.onSettled)
            for (i, provider) in providers.enumerated() {
                Coordinator.loadRefs(from: provider, optimize: optimize) { refs in batch.record(i, refs) }
            }
            parent.dismiss()
        }

        /// Selection-ordered, incremental delivery. Slot `i` holds item `i`'s refs once it lands; every
        /// time the DONE prefix grows, the newly contiguous slots go out as one batch. Item 3 landing
        /// before item 1 waits for item 1 — a photo never jumps ahead of the one picked before it.
        private final class Batch: @unchecked Sendable {
            private let lock = NSLock()
            private var slots: [[String]?]
            private var delivered = 0
            private let onPicked: ([String]) -> Void
            private let onSettled: ((Int) -> Void)?
            private let startedAt = Date()
            init(total: Int, onPicked: @escaping ([String]) -> Void, onSettled: ((Int) -> Void)?) {
                slots = Array(repeating: nil, count: total)
                self.onPicked = onPicked; self.onSettled = onSettled
            }
            func record(_ index: Int, _ refs: [String]) {
                lock.lock()
                slots[index] = refs
                var flat: [String] = []
                var settled = 0
                while delivered < slots.count, let s = slots[delivered] {
                    flat.append(contentsOf: s); settled += 1; delivered += 1
                }
                let done = delivered == slots.count
                let elapsed = Date().timeIntervalSince(startedAt)
                lock.unlock()
                guard settled > 0 else { return }
                if done {
                    HavenLog.sync(String(format: "picker: %d item(s) prepared in %.1fs", slots.count, elapsed))
                }
                DispatchQueue.main.async { [onPicked, onSettled] in
                    if !flat.isEmpty { onPicked(flat) }
                    onSettled?(settled)
                }
            }
        }

        /// Heavy image DECODE is serialized on this queue so picking many high-res photos can't decode
        /// them all into memory at once (a past OOM). The lightweight data/file transfers still overlap.
        /// `.userInitiated`: the person is watching placeholders and waiting on exactly this work.
        private static let decodeQueue = DispatchQueue(label: "haven.mediapicker.decode", qos: .userInitiated)

        /// The representation to ask the provider for. A rendered image (HEIC/JPEG) over a RAW one when
        /// the asset offers both; a ProRAW asset's `.current` representation is the 70 MB DNG, whose
        /// decode is the single most expensive thing this path can do. Nil when the item isn't an image.
        private static func preferredImageType(_ provider: NSItemProvider) -> String? {
            let images = provider.registeredTypeIdentifiers.compactMap(UTType.init).filter { $0.conforms(to: .image) }
            guard !images.isEmpty else {
                return provider.canLoadObject(ofClass: PlatformImage.self) ? UTType.image.identifier : nil
            }
            return (images.first { !$0.conforms(to: .rawImage) } ?? images[0]).identifier
        }

        /// Load one picker item to one or more stored media refs via completion handlers, so the
        /// transfer is initiated synchronously (connection still live) and survives the picker's
        /// dismissal. Videos return a bundle (poster + optimized + optional original).
        private static func loadRefs(from provider: NSItemProvider, optimize: Bool,
                                     completion: @escaping ([String]) -> Void) {
            if let type = preferredImageType(provider) {
                // FILE representation: the bytes stay on disk and ImageIO decodes them straight to the
                // target size, so a 48 MP frame never has to exist in memory as pixels. The URL is only
                // valid inside the handler — copy it out first.
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    guard let url else { loadImageData(from: provider, optimize: optimize, completion: completion); return }
                    let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pick_\(UUID().uuidString).\(ext)")
                    do { try FileManager.default.copyItem(at: url, to: tmp) } catch {
                        loadImageData(from: provider, optimize: optimize, completion: completion); return
                    }
                    decodeQueue.async {
                        let prepared = MediaStore.prepareImage(fileURL: tmp, optimize: optimize)
                        try? FileManager.default.removeItem(at: tmp)
                        guard let prepared else {
                            HavenLog.sync("picker: ImageIO could not read \(type); falling back to a decoded image")
                            loadImageData(from: provider, optimize: optimize, completion: completion); return
                        }
                        DispatchQueue.main.async { completion([MediaStore.shared.adopt(prepared)]) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url else { completion([]); return }
                    // Copy out of the temporary location before it's reclaimed.
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    try? FileManager.default.copyItem(at: url, to: dest)
                    Task { @MainActor in
                        let bundle = await MediaStore.shared.prepareVideo(url: dest)
                        TempSweep.discardIfTemp(dest)   // the copy is consumed (it used to live in tmp forever)
                        completion(bundle.isEmpty ? [] : bundle.mediaRefs)
                    }
                }
            } else {
                completion([])
            }
        }

        /// Fallbacks for a provider that won't vend a file: the raw bytes (still prepared off-main,
        /// GPS intact), then — some providers only vend a decoded image — the legacy on-main path
        /// (no GPS available then).
        private static func loadImageData(from provider: NSItemProvider, optimize: Bool,
                                          completion: @escaping ([String]) -> Void) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                decodeQueue.async {
                    if let data, let prepared = MediaStore.prepareImage(data: data, optimize: optimize) {
                        DispatchQueue.main.async { completion([MediaStore.shared.adopt(prepared)]) }
                    } else {
                        provider.loadObject(ofClass: PlatformImage.self) { obj, _ in
                            guard let img = obj as? PlatformImage else { completion([]); return }
                            DispatchQueue.main.async { completion([MediaStore.shared.addImage(img)]) }
                        }
                    }
                }
            }
        }
    }
}

#endif

#if os(macOS)

/// macOS photo/video picker — the **Photos library** (PHPickerViewController, macOS 13+), matching
/// iOS. (The file browser is a separate `FilePicker`, offered as the "Files…" attach option.)
struct MediaPicker: NSViewControllerRepresentable {
    var onPicked: ([String]) -> Void
    /// Same hooks as iOS (placeholders in the composer while the batch is read). The Mac path still
    /// loads before it dismisses, so the placeholders live only as long as that takes.
    var onSelected: ((Int) -> Void)? = nil
    var onSettled: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    func makeNSViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 30
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateNSViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker
        private var finished = false
        init(_ parent: MediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished else { return }
            finished = true
            let providers = results.map(\.itemProvider)
            parent.onSelected?(providers.count)
            // Load BEFORE dismissing — the item providers stop vending data once the picker is torn down,
            // so dismissing first attaches nothing. Then close.
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { parent.onSettled?(providers.count) }
                var refs: [String] = []
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                        let dest: URL? = await withCheckedContinuation { cont in
                            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                                guard let url else { cont.resume(returning: nil); return }
                                let dest = FileManager.default.temporaryDirectory
                                    .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                                try? FileManager.default.copyItem(at: url, to: dest)
                                cont.resume(returning: dest)
                            }
                        }
                        if let dest {
                            let bundle = await MediaStore.shared.prepareVideo(url: dest)
                            TempSweep.discardIfTemp(dest)   // the copy is consumed
                            if !bundle.isEmpty { refs.append(contentsOf: bundle.mediaRefs) }
                        }
                    } else if provider.canLoadObject(ofClass: PlatformImage.self) {
                        let img: PlatformImage? = await withCheckedContinuation { cont in
                            provider.loadObject(ofClass: PlatformImage.self) { obj, _ in cont.resume(returning: obj as? PlatformImage) }
                        }
                        if let img { refs.append(MediaStore.shared.addImage(img)) }
                    }
                }
                self.parent.onPicked(refs)
                self.parent.dismiss()
            }
        }
    }
}

/// macOS file-browser picker (the "Files…" attach option) — photos, videos, arbitrary files, and
/// folders (folders are zipped). Same surface as the iOS Files importer.
struct FilePicker: View {
    var onPicked: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .onAppear {
                DispatchQueue.main.async {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image, .movie, .item, .data, .archive]
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.message = "Choose photos, videos, files, or folders to share"
                    panel.prompt = "Add"
                    guard panel.runModal() == .OK else { dismiss(); return }
                    let urls = panel.urls
                    Task { @MainActor in
                        onPicked(await MediaImport.importURLs(urls))
                        dismiss()
                    }
                }
            }.havenPausesPostAudio()
    }
}

#endif

/// Shared import path for Files-app / NSOpenPanel picks: images, videos (with poster/original
/// bundle), and everything else as a zipped `file_` attachment (folders included).
@MainActor
enum MediaImport {
    static func importURLs(_ urls: [URL]) async -> [String] {
        var refs: [String] = []
        // Non-media files/folders are batched into ONE zip so attaching a folder + a PDF doesn't
        // produce two separate posts' worth of blobs when the user meant "these things".
        var archiveBatch: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                archiveBatch.append(url)
                continue
            }
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if let type, type.conforms(to: .movie) {
                let bundle = await MediaStore.shared.prepareVideo(url: url)
                if !bundle.isEmpty { refs.append(contentsOf: bundle.mediaRefs) }
            } else if let type, type.conforms(to: .image), let img = Self.loadImage(url) {
                refs.append(MediaStore.shared.addImage(img))
            } else {
                // Not an image/movie — zip it (and any siblings in the batch).
                archiveBatch.append(url)
            }
        }
        if !archiveBatch.isEmpty {
            let name = archiveBatch.count == 1
                ? archiveBatch[0].deletingPathExtension().lastPathComponent
                : "files"
            let ref = MediaStore.shared.addFileArchive(urls: archiveBatch, name: name)
            if !ref.isEmpty { refs.append(ref) }
        }
        return refs
    }

    private static func loadImage(_ url: URL) -> PlatformImage? {
        #if os(macOS)
        return PlatformImage(contentsOf: url)
        #else
        if let data = try? Data(contentsOf: url) { return PlatformImage(data: data) }
        return PlatformImage(contentsOfFile: url.path)
        #endif
    }
}
