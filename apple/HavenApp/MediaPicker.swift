import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

#if !os(macOS)

/// A friendly photo/video picker (Photos library). Works in the Simulator, so the
/// whole attach → seal → feed path is verifiable without a camera. Returns media
/// refs registered in `MediaStore`.
struct MediaPicker: UIViewControllerRepresentable {
    var onPicked: ([String]) -> Void
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
            let onPicked = parent.onPicked
            // KICK OFF every transfer NOW, while the picker's data connection is still live — the in-flight
            // loads survive dismissal. THEN dismiss immediately, so a big video copy never leaves the
            // picker frozen on screen ("can't select a video or dismiss"). Loading AFTER dismiss fails —
            // the Photos picker's out-of-process connection is gone, so nothing attaches (the build-142
            // regression). Results are recorded in selection order and delivered once the last finishes.
            guard !providers.isEmpty else { parent.dismiss(); return }
            let total = providers.count
            var slots = [String?](repeating: nil, count: total)
            var remaining = total
            let lock = NSLock()
            func record(_ index: Int, _ ref: String?) {
                lock.lock()
                slots[index] = ref
                remaining -= 1
                let done = remaining == 0
                lock.unlock()
                guard done else { return }
                let refs = slots.compactMap { $0 }
                DispatchQueue.main.async { if !refs.isEmpty { onPicked(refs) } }
            }
            for (i, provider) in providers.enumerated() {
                Coordinator.loadRef(from: provider) { ref in record(i, ref) }
            }
            parent.dismiss()
        }

        /// Heavy image DECODE is serialized on this queue so picking many high-res photos can't decode
        /// them all into memory at once (a past OOM). The lightweight data/file transfers still overlap.
        private static let decodeQueue = DispatchQueue(label: "haven.mediapicker.decode")

        /// Load one picker item to a stored media ref via completion handlers, so the transfer is
        /// initiated synchronously (connection still live) and survives the picker's dismissal.
        private static func loadRef(from provider: NSItemProvider, completion: @escaping (String?) -> Void) {
            if provider.canLoadObject(ofClass: PlatformImage.self) {
                // Load the raw data (not just a decoded image) so we can read the EXIF GPS before the
                // bytes are re-encoded (which strips it). The coord stays on-device.
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    decodeQueue.async {
                        if let data, let img = PlatformImage(data: data) {
                            let coord = MediaStore.gpsCoordinate(fromImageData: data)
                            DispatchQueue.main.async {
                                let ref = MediaStore.shared.addImage(img)
                                if let coord { MediaStore.shared.setLocation(coord, for: ref) }
                                completion(ref)
                            }
                        } else {
                            // Fallback: some providers only vend a decoded image (no GPS available then).
                            provider.loadObject(ofClass: PlatformImage.self) { obj, _ in
                                guard let img = obj as? PlatformImage else { completion(nil); return }
                                DispatchQueue.main.async { completion(MediaStore.shared.addImage(img)) }
                            }
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url else { completion(nil); return }
                    // Copy out of the temporary location before it's reclaimed.
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    try? FileManager.default.copyItem(at: url, to: dest)
                    Task { @MainActor in
                        let r = await MediaStore.shared.addVideo(url: dest)
                        if !r.isEmpty { completion(r) }   // "" = refused (over the length limit)
                    }
                }
            } else {
                completion(nil)
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
            // Load BEFORE dismissing — the item providers stop vending data once the picker is torn down,
            // so dismissing first attaches nothing. Then close.
            Task { @MainActor [weak self] in
                guard let self else { return }
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
                            let r = await MediaStore.shared.addVideo(url: dest)
                            if !r.isEmpty { refs.append(r) }   // "" = refused (over the length limit)
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

/// macOS file-browser picker (the "Files…" attach option) — pick photos/videos from anywhere on disk.
struct FilePicker: View {
    var onPicked: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .onAppear {
                DispatchQueue.main.async {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image, .movie]
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.message = "Choose photos or videos to share"
                    panel.prompt = "Add"
                    guard panel.runModal() == .OK else { dismiss(); return }
                    let urls = panel.urls
                    Task { @MainActor in
                        var refs: [String] = []
                        for url in urls {
                            let scoped = url.startAccessingSecurityScopedResource()
                            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                            if let type, type.conforms(to: .movie) {
                                let r = await MediaStore.shared.addVideo(url: url)
                                if !r.isEmpty { refs.append(r) }   // "" = refused (over the length limit)
                            } else if let img = PlatformImage(contentsOf: url) {
                                refs.append(MediaStore.shared.addImage(img))
                            }
                            if scoped { url.stopAccessingSecurityScopedResource() }
                        }
                        onPicked(refs)
                        dismiss()
                    }
                }
            }.havenPausesPostAudio()
    }
}

#endif
