import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if os(iOS)
import MediaPlayer
#endif

#if !os(macOS)
/// Locks the app to portrait while a view is on screen (the story camera/composer must never
/// rotate), restoring free rotation when it leaves.
struct PortraitLock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                HavenAppDelegate.orientationLock = .portrait
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
                UIViewController.attemptRotationToDeviceOrientationCompat()
            }
            .onDisappear { HavenAppDelegate.orientationLock = .all }
    }
}
#else
/// macOS has no orientation lock — there's no rotation to constrain, so this is a no-op.
struct PortraitLock: ViewModifier {
    func body(content: Content) -> some View { content }
}
#endif

extension View {
    /// Lock this screen to portrait (no rotation).
    func portraitLocked() -> some View { modifier(PortraitLock()) }
}

#if !os(macOS)
extension UIViewController {
    static func attemptRotationToDeviceOrientationCompat() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
#endif

// A clean, modern story camera — tap the shutter for a photo, hold to record video —
// then a composer to add a song and a caption before sharing. No filters, no edit
// tools: just capture → caption → song → share, smooth and minimal.

// MARK: - Capture engine

#if !os(macOS)
@MainActor
final class CameraModel: NSObject, ObservableObject {
    // Capture session + outputs + device bookkeeping live exclusively on `queue` (serial), so they're
    // nonisolated(unsafe) — serialized by the queue, not the main actor. Only @Published UI state below
    // stays main-isolated.
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    // Retained but NO LONGER ADDED to the session on iOS (see StoryVideoRecorder) — kept only so the shared
    // stop()/configurePreviewConnection references compile; its connection is nil, so those calls no-op.
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "haven.camera")
    // Live filtered preview: frames are tapped here and rendered through FilterEngine by the
    // FilteredCameraPreview/MetalCameraPreview. The story camera is portrait-locked, so the
    // preview connection is always 90° (portrait), mirrored on the front camera.
    let frameTap = LiveFrameTap()   // @unchecked Sendable
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()
    // Video is recorded from the SAME live frame stream via AVAssetWriter (StoryVideoRecorder) instead of a
    // second AVCaptureMovieFileOutput — running a movie file output alongside the preview data output is
    // what iOS truncated ("records only ~0-1s"). Audio feeds the recorder from this data output.
    nonisolated(unsafe) private let audioDataOutput = AVCaptureAudioDataOutput()
    let recorder = StoryVideoRecorder()

    @Published var isRecording = false
    /// True from an auto-split stop until the segment is committed — keeps the progress bar's live slot
    /// visible across the async finalize gap so it doesn't collapse/rewind then jump to the next segment.
    @Published var finalizing = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var ready = false
    /// Seconds elapsed in the current recording (drives the capture progress bar + the cap).
    @Published var recordingSeconds = 0.0
    /// Current zoom as a "× lens" factor relative to the wide camera (0.5 = ultra-wide).
    @Published var zoom = 1.0
    /// The lens presets available on this device's back camera (e.g. [0.5, 1, 2]).
    @Published var lensPresets: [Double] = [1, 2]

    nonisolated(unsafe) private var device: AVCaptureDevice?
    nonisolated(unsafe) private var usingUltraWide = false
    nonisolated(unsafe) private var onPhoto: ((PlatformImage) -> Void)?
    nonisolated(unsafe) private var onVideo: ((URL) -> Void)?
    nonisolated(unsafe) private var recordTimer: Timer?
    /// When the current clip hits this many seconds, recording auto-stops (the 90s total cap).
    nonisolated(unsafe) private var capSeconds = StoryCaptureModel.maxTotal

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        frameTap.recorder = recorder   // the tap writes live frames + routes audio to the recorder while recording
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.configureInputs(position: .back)
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            if self.session.canAddOutput(self.videoDataOutput) {
                self.videoDataOutput.wireLivePreview(tap: self.frameTap, queue: self.queue)
                self.session.addOutput(self.videoDataOutput)
            }
            if self.session.canAddOutput(self.audioDataOutput) {
                self.audioDataOutput.setSampleBufferDelegate(self.frameTap, queue: self.queue)
                self.session.addOutput(self.audioDataOutput)
            }
            self.session.commitConfiguration()
            self.configurePreviewConnection()
            if !self.session.isRunning { self.session.startRunning() }
            Task { @MainActor in self.ready = true }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            // Fully tear the session down so the camera device is released and the iOS "in use"
            // (green) indicator goes off — stopRunning alone keeps inputs/outputs (and the device)
            // attached. Removing inputs releases the underlying AVCaptureDevice.
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            self.device = nil
        }
    }

    private func configureInputs(position: AVCaptureDevice.Position) {
        for input in session.inputs { session.removeInput(input) }
        // Pick the lens: the ultra-wide (0.5×) when selected and available, else the wide camera.
        let type: AVCaptureDevice.DeviceType = (position == .back && usingUltraWide && hasUltraWide(position))
            ? .builtInUltraWideCamera : .builtInWideAngleCamera
        let cam = AVCaptureDevice.default(type, for: .video, position: position)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        if let cam, let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            device = cam
            try? cam.lockForConfiguration()
            cam.videoZoomFactor = 1.0
            cam.unlockForConfiguration()
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        configurePreviewConnection(position: position)
        Task { @MainActor in self.refreshLensPresets(position: position) }
    }

    /// Orient (portrait) + mirror (front) the live-preview data-output connection AND the still/movie
    /// capture connections, so captured media isn't sideways and the front camera matches the
    /// (mirrored) preview. Safe to call before an output is added (no connection yet → no-op).
    private func configurePreviewConnection(position: AVCaptureDevice.Position? = nil) {
        let pos = position ?? self.position
        let mirrorFront = pos == .front
        // FILE outputs honor rotation+mirror (captured media upright). The PREVIEW data output does
        // NOT reliably rotate its buffers, so the Metal preview orients the CIImage via `.oriented()`
        // (FilteredCameraPreview.orientation = havenCameraOrientation). Leave the data output alone.
        photoOutput.connection(with: .video)?.applyPreviewOrientation(angle: 90, mirroredFront: mirrorFront)
        movieOutput.connection(with: .video)?.applyPreviewOrientation(angle: 90, mirroredFront: mirrorFront)
    }

    private func hasUltraWide(_ position: AVCaptureDevice.Position) -> Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) != nil
    }

    /// The lens-button presets for the current camera: 0.5× if an ultra-wide exists, then 1×/2×
    /// (and 3× when the optics allow). The front camera has no lenses.
    @MainActor private func refreshLensPresets(position: AVCaptureDevice.Position) {
        guard position == .back else { lensPresets = []; zoom = 1.0; return }
        var presets: [Double] = []
        if hasUltraWide(position) { presets.append(0.5) }
        presets.append(1)
        let maxZ = device?.maxAvailableVideoZoomFactor ?? 1
        if maxZ >= 2 { presets.append(2) }
        if maxZ >= 3 { presets.append(3) }
        lensPresets = presets
        zoom = usingUltraWide ? 0.5 : 1.0
    }

    /// Pinch / lens-button zoom. `factor` is the "× lens" value (0.5 = ultra-wide, 1 = wide, …).
    func setZoom(_ factor: Double) {
        let pos = position
        queue.async { [weak self] in
            guard let self else { return }
            let wantUltra = (factor < 1.0) && self.hasUltraWide(pos)
            if wantUltra != self.usingUltraWide {
                // Crossing the 0.5×/1× boundary swaps the physical lens.
                self.usingUltraWide = wantUltra
                self.session.beginConfiguration()
                self.configureInputs(position: pos)
                self.session.commitConfiguration()
            }
            guard let dev = self.device else { return }
            // On the wide lens, digital zoom = factor; on ultra-wide, 0.5×→1× maps to 1.0→… .
            let base = self.usingUltraWide ? max(factor / 0.5, 1.0) : factor
            let clamped = max(dev.minAvailableVideoZoomFactor, min(base, min(dev.maxAvailableVideoZoomFactor, 8)))
            try? dev.lockForConfiguration()
            dev.videoZoomFactor = clamped
            dev.unlockForConfiguration()
            Task { @MainActor in self.zoom = factor }
        }
    }

    func flip() {
        position = (position == .back) ? .front : .back
        let pos = position
        usingUltraWide = false   // start each camera at 1× wide
        zoom = 1.0
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configureInputs(position: pos)
            self.session.commitConfiguration()
        }
    }

    func capturePhoto(_ completion: @escaping (PlatformImage) -> Void) {
        onPhoto = completion
        let settings = AVCapturePhotoSettings()
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Start recording a clip via the AVAssetWriter recorder (fed from the live frame stream — no movie
    /// file output to conflict). `maxSeconds` caps THIS clip; recording auto-stops when it's reached.
    func startRecording(maxSeconds: Double = StoryCaptureModel.maxTotal, _ completion: @escaping (URL) -> Void) {
        guard !recorder.isRecording, maxSeconds > 0.3 else { return }
        onVideo = completion
        capSeconds = maxSeconds
        recordingSeconds = 0
        finalizing = false   // the next segment is starting → drop the held-over slot from the last one
        // Orient each recorded frame upright like the preview. Record RAW (filterSpec = original): the
        // composer/export bakes the chosen look exactly as before, so it isn't double-applied.
        recorder.orientation = havenCameraOrientation(position: position)
        recorder.filterSpec = HavenFilter.original.spec
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story_\(UUID().uuidString).mov")
        recorder.begin(to: url)
        isRecording = true
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recordingSeconds += 0.1
                if self.recordingSeconds >= self.capSeconds { self.stopRecording() }
            }
        }
    }

    func stopRecording() {
        recordTimer?.invalidate(); recordTimer = nil
        guard recorder.isRecording else { isRecording = false; finalizing = false; return }
        // Hold `recordingSeconds` (and mark finalizing) so the progress bar keeps showing this clip's slot
        // through the async finalize gap — the completion (finishVideo) commits the segment + resets it,
        // so the bar never briefly drops the just-recorded segment.
        isRecording = false
        finalizing = true
        let cb = onVideo; onVideo = nil
        Task { [weak self] in
            guard let self else { return }
            let url = await self.recorder.finish()
            if let url, let cb { await MainActor.run { cb(url) } }
        }
    }

    /// Clear any stuck recording state left by an aborted take. Called on the camera's onAppear so
    /// re-entering always starts from a clean slate.
    func resetRecordingState() {
        recordTimer?.invalidate(); recordTimer = nil
        recordingSeconds = 0
        finalizing = false
        if recorder.isRecording { Task { _ = await recorder.finish() } }
        isRecording = false
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let img = PlatformImage(data: data) else { return }
        Task { @MainActor in self.onPhoto?(img) }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.onVideo?(outputFileURL) }
    }
}
#else
/// Native macOS capture engine. Mirrors the iOS `CameraModel` public surface (same `@Published`
/// members + methods) backed by a real `AVCaptureSession`: stills via `AVCapturePhotoOutput`,
/// video via `AVCaptureMovieFileOutput`. `flip()` swaps the device when a Mac has more than one
/// camera (else no-op). `setZoom` is best-effort and no-ops on Macs without ramp-able zoom.
@MainActor
final class CameraModel: NSObject, ObservableObject {
    // The capture session, its outputs, the frame tap and all device bookkeeping live exclusively on
    // `queue` (a serial DispatchQueue), so they're nonisolated(unsafe) — access is serialized by the
    // queue, not the main actor. Only the @Published UI state below stays main-actor isolated.
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "haven.camera.mac")
    // Live filtered preview: frames are tapped here and rendered through FilterEngine by the
    // FilteredCameraPreview/MetalCameraPreview (same pipeline as iOS — only the view layer differs).
    let frameTap = LiveFrameTap()   // @unchecked Sendable — crosses to the camera queue freely
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()

    @Published var isRecording = false
    /// True from an auto-split stop until the segment is committed — keeps the progress bar's live slot
    /// visible across the async finalize gap so it doesn't collapse/rewind then jump to the next segment.
    @Published var finalizing = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var ready = false
    @Published var recordingSeconds = 0.0
    @Published var zoom = 1.0
    // Macs typically have a single fixed-zoom FaceTime camera, so there are no lens presets.
    @Published var lensPresets: [Double] = []

    nonisolated(unsafe) private var device: AVCaptureDevice?
    /// All video-capable devices on this Mac, in discovery order. `flip()` cycles through these.
    nonisolated(unsafe) private var availableDevices: [AVCaptureDevice] = []
    nonisolated(unsafe) private var deviceIndex = 0
    nonisolated(unsafe) private var onPhoto: ((PlatformImage) -> Void)?
    nonisolated(unsafe) private var onVideo: ((URL) -> Void)?
    nonisolated(unsafe) private var recordTimer: Timer?
    nonisolated(unsafe) private var capSeconds = StoryCaptureModel.maxTotal

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        queue.async { [weak self] in
            guard let self else { return }
            self.discoverDevices()
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.configureInputs()
            // Order matters on macOS: a session caps how many outputs it accepts, and whichever is
            // added last can be rejected. videoDataOutput MUST win — it feeds both the live preview and
            // (via frameTap.latest) the photo capture. movieOutput is next for video; photoOutput is
            // last and optional (we capture stills from the frame tap, not it).
            if self.session.canAddOutput(self.videoDataOutput) {
                self.videoDataOutput.wireLivePreview(tap: self.frameTap, queue: self.queue)
                self.session.addOutput(self.videoDataOutput)
            }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
            Task { @MainActor in self.ready = true }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            // Fully release the capture device so the macOS camera indicator goes off.
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            self.device = nil
        }
    }

    nonisolated private func discoverDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified)
        availableDevices = session.devices
        if availableDevices.isEmpty, let def = AVCaptureDevice.default(for: .video) {
            availableDevices = [def]
        }
    }

    nonisolated private func configureInputs() {
        for input in session.inputs { session.removeInput(input) }
        let cam = availableDevices.indices.contains(deviceIndex)
            ? availableDevices[deviceIndex]
            : AVCaptureDevice.default(for: .video)
        if let cam, let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            device = cam
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }
    }

    /// Mac cameras expose no ramp-able zoom factor (`videoZoomFactor` and the
    /// min/max-available-zoom APIs are iOS-only), so zoom is a no-op on macOS — we just keep the
    /// published value in sync for the UI.
    func setZoom(_ factor: Double) {
        Task { @MainActor in self.zoom = factor }
    }

    /// Switch to the next video device when the Mac has more than one; otherwise a no-op.
    func flip() {
        guard availableDevices.count > 1 else { return }
        deviceIndex = (deviceIndex + 1) % availableDevices.count
        // `position` is largely cosmetic on macOS, but keep it toggling so the UI mirroring logic
        // that reads it stays sensible.
        position = (position == .back) ? .front : .back
        zoom = 1.0
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configureInputs()
            self.session.commitConfiguration()
        }
    }

    func capturePhoto(_ completion: @escaping (PlatformImage) -> Void) {
        // macOS: AVCapturePhotoOutput frequently fails to deliver when an AVCaptureMovieFileOutput is
        // attached to the same session — the delegate gets an error and we'd silently produce nothing,
        // i.e. "the camera only records video, never takes a picture". Grab the still straight from the
        // live preview frame instead; it's the same raw frame iOS's photo path returns and it's always
        // there once the session is running.
        if let ci = frameTap.latest {
            let ctx = CIContext()
            if let cg = ctx.createCGImage(ci, from: ci.extent) {
                let img = NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height))
                completion(img)
                return
            }
        }
        // Fallback if no frame has arrived yet.
        onPhoto = completion
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func startRecording(maxSeconds: Double = StoryCaptureModel.maxTotal, _ completion: @escaping (URL) -> Void) {
        guard !movieOutput.isRecording, maxSeconds > 0.3 else { return }
        onVideo = completion
        capSeconds = maxSeconds
        recordingSeconds = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story_\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recordingSeconds += 0.1
                if self.recordingSeconds >= self.capSeconds { self.stopRecording() }
            }
        }
    }

    func stopRecording() {
        recordTimer?.invalidate(); recordTimer = nil
        recordingSeconds = 0            // reset the live counter so the next take's progress bar starts clean
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        isRecording = false
    }

    /// Clear any stuck recording state left by an aborted take (app backgrounded mid-record, a delegate
    /// that never fired). Called on the camera's onAppear so re-entering always starts from a clean slate.
    func resetRecordingState() {
        recordTimer?.invalidate(); recordTimer = nil
        recordingSeconds = 0
        if movieOutput.isRecording { movieOutput.stopRecording() }
        isRecording = false
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let img = PlatformImage(data: data) else { return }
        Task { @MainActor in self.onPhoto?(img) }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.onVideo?(outputFileURL) }
    }
}
#endif

// MARK: - Live preview

#if !os(macOS)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#else
/// Native macOS live camera preview: a layer-backed NSView hosting an
/// `AVCaptureVideoPreviewLayer` for the model's session.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.attach(session: session)
        return v
    }
    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    final class PreviewNSView: NSView {
        private var preview: AVCaptureVideoPreviewLayer?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func attach(session: AVCaptureSession) {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            self.layer?.addSublayer(layer)
            preview = layer
        }
        override func layout() {
            super.layout()
            preview?.frame = bounds
        }
    }
}
#endif

/// Shared placeholder shown wherever live camera capture isn't yet available on macOS.
private struct CameraUnavailablePlaceholder: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.85))
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.7))
                Text("Not available on Mac yet").font(.headline).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

// MARK: - Multi-clip capture model

/// Accumulates the video clips captured for one story session. Each clip is a separate story
/// (split into 15s chunks at share); the whole session is capped at 90s combined.
@MainActor
final class StoryCaptureModel: ObservableObject {
    nonisolated static let maxTotal = 90.0    // 90s combined, hard cap (labeled in the camera)
    nonisolated static let chunk = 15.0       // each segment records at most 15s (auto-splits while holding)
    static let maxSegments = 8                // …and no more than 8 segments in one go, whichever comes first
    /// The cap shown to the user, e.g. "1:30". Seconds under a minute show as "Ns".
    static var maxLabel: String { let s = Int(maxTotal); return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60) }

    struct Segment: Identifiable { let id = UUID(); let ref: String; let duration: Double; let thumb: PlatformImage? }
    @Published var segments: [Segment] = []

    var total: Double { segments.reduce(0) { $0 + $1.duration } }
    var remaining: Double { max(0, Self.maxTotal - total) }
    /// Full when EITHER limit is hit: the 2-minute total, or 8 segments. A short segment counts against the
    /// 8 but barely against the 2 minutes — so the segment cap is usually the binding one.
    var isFull: Bool { remaining < 0.5 || segments.count >= Self.maxSegments }
    /// Room left for the NEXT clip — the 15s segment cap, clamped to whatever's left of the 2-minute total.
    var nextClipCap: Double { min(Self.chunk, remaining) }

    func add(ref: String, duration: Double, thumb: PlatformImage?) {
        segments.append(Segment(ref: ref, duration: min(max(duration, 0.1), Self.chunk), thumb: thumb))
    }
    func remove(_ id: UUID) { segments.removeAll { $0.id == id } }
    func clear() { segments.removeAll() }
}

// MARK: - Camera screen

#if !os(macOS)
struct StoryCameraView: View {
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    /// Hides the dual-camera (front+back PiP) entry point — its multi-cam preview renders black on
    /// device. Flip to true once the dual preview is properly wired.
    private static let dualCameraEnabled = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraModel()
    @StateObject private var dual = DualCameraRecorder()
    @StateObject private var capture = StoryCaptureModel()
    @State private var pressing = false
    @State private var startedVideo = false   // this press became a video hold (auto-splits into 15s segments)
    @State private var showLibrary = false
    @State private var showReview = false
    @State private var draft: StoryDraft?
    @State private var dualMode = false
    @State private var pipCorner: PiPCorner = .bottomRight
    @State private var pinchBaseZoom = 1.0     // zoom at the start of a pinch
    @State private var recordStartZoom = 1.0   // zoom when a hold-to-record drag began
    // Live filter applied to the camera feed, carried into the composer as the default look.
    @State private var liveFilter: HavenFilter = .original
    @State private var liveThumb: PlatformImage?
    @State private var showLiveFilters = false
    @State private var filterNameShown = false

    private let minZoom = 0.5, maxZoom = 8.0
    private var isRec: Bool { dualMode ? dual.isRecording : cam.isRecording }
    private var recSecs: Double { dualMode ? dual.recordingSeconds : cam.recordingSeconds }
    /// Show the live progress slot while recording OR while an auto-split segment is finalizing, so the bar
    /// holds the just-recorded clip's slot steady until it becomes a committed segment (no drop-then-jump).
    private var showLiveSlot: Bool { isRec || (!dualMode && cam.finalizing) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if dualMode {
                DualCameraPreview(recorder: dual, corner: pipCorner).ignoresSafeArea()
            } else {
                FilteredCameraPreview(tap: cam.frameTap, filter: liveFilter,
                                      orientation: havenCameraOrientation(position: cam.position),
                                      onThumbnail: { liveThumb = $0 }).ignoresSafeArea()
                    // Pinch anywhere on the preview to zoom.
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { v in cam.setZoom(min(maxZoom, max(minZoom, pinchBaseZoom * v))) }
                        .onEnded { _ in pinchBaseZoom = cam.zoom })
                    // Swipe left/right on the PREVIEW to flip filters — but only when the filter strip is
                    // hidden. While the strip is open this simultaneousGesture fought its horizontal scroll
                    // (every swipe both scrolled AND cycled the filter), which is why scrolling it felt
                    // stuck and took way too much dragging.
                    .simultaneousGesture(showLiveFilters ? nil : DragGesture(minimumDistance: 24)
                        .onEnded { v in
                            guard abs(v.translation.width) > abs(v.translation.height) * 1.5,
                                  abs(v.translation.width) > 44 else { return }
                            cycleLiveFilter(v.translation.width < 0 ? liveFilter.next : liveFilter.prev)
                        })
            }

            VStack {
                captureProgress   // segmented bars (story-viewer style) + live recording fill
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                    Spacer()
                    // Always label the story's max length; when it's reached, call it out.
                    Text(capture.isFull ? "Max length · \(StoryCaptureModel.maxLabel)" : "\(StoryCaptureModel.maxLabel) max")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(capture.isFull ? 1 : 0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    HStack(spacing: 10) {
                        // Dual-camera (front + back PiP) toggle is DISABLED: the multi-cam preview
                        // renders black on device (the two preview connections aren't wired) and the
                        // feature added little. The recorder code stays for a future proper rebuild;
                        // the entry point is hidden so the normal camera always works.
                        if Self.dualCameraEnabled && DualCameraRecorder.isSupported {
                            Button { toggleDual() } label: {
                                Image(systemName: dualMode ? "person.2.fill" : "person.2")
                                    .font(.title3.weight(.semibold)).foregroundStyle(dualMode ? HavenTheme.pink : .white)
                                    .padding(10).background(.black.opacity(0.35), in: Circle())
                            }
                        }
                        if !dualMode {
                            Button { withAnimation(HavenTheme.smooth) { showLiveFilters.toggle() } } label: {
                                Image(systemName: "camera.filters").font(.title3.weight(.semibold))
                                    .foregroundStyle(liveFilter != .original ? HavenTheme.pink : .white)
                                    .padding(10).background(.black.opacity(0.35), in: Circle())
                            }
                            Button { cam.flip() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3.weight(.semibold))
                                    .foregroundStyle(.white).padding(10).background(.black.opacity(0.35), in: Circle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4)
                if dualMode { cornerPicker.padding(.top, 8) }
                Spacer()
                // Hide ALL zoom UI (slider + lens buttons) while filming AND across the auto-split finalize
                // gap (recording || finalizing) — otherwise the controls flashed back between segments and
                // the reflow made the progress bar appear to vanish. Zoom while recording is swipe-up on the
                // shutter (see `shutter`). Shown only when idle (not long-holding).
                if !dualMode && !isRec && !cam.finalizing { zoomControls }
                if !dualMode && filterNameShown {
                    Text(liveFilter.title)
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
                if !dualMode && showLiveFilters, let liveThumb {
                    FilterStrip(thumbnail: liveThumb, selection: $liveFilter)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 12).padding(.bottom, 20)   // clear the shutter — don't crowd it
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomBar
            }
        }
        .havenStatusBarHidden()
        .portraitLocked()
        .onAppear { cam.start(); cam.resetRecordingState() }
        .onDisappear { cam.stop(); dual.stop() }
        .sheet(isPresented: $showLibrary) {
            MediaPicker { refs in
                if let ref = refs.first { draft = StoryDraft(mediaRef: ref) }
            }
        }
        .havenFullScreenCover(isPresented: $showReview) {
            StoryReviewView(capture: capture,
                            onCaptureMore: { showReview = false },
                            onNext: {
                                showReview = false
                                let refs = capture.segments.map(\.ref)
                                // Let the review cover finish dismissing before presenting the composer.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { draft = StoryDraft(refs: refs) }
                            })
        }
        .havenFullScreenCover(item: $draft) { d in
            StoryComposerView(draft: d, initialFilter: liveFilter) { ref, caption, track in
                onShare(ref, caption, track)
            } onDone: {
                dismiss()   // close the camera once everything's shared
            }
        }
    }

    /// Story-viewer-style segmented progress: one filled bar per captured clip (width ∝ its
    /// 15s share), plus the live recording filling the next bar, all within the 90s budget.
    private var captureProgress: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let slots = capture.segments.map { $0.duration } + (showLiveSlot ? [recSecs] : [])
            let totalW = geo.size.width
            HStack(spacing: spacing) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, dur in
                    Capsule().fill(.white)
                        .frame(width: max(4, totalW * CGFloat(dur / StoryCaptureModel.maxTotal)))
                }
                Capsule().fill(.white.opacity(0.25))   // remaining budget
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 3)
        }
        .frame(height: 3)
        .padding(.horizontal, 12).padding(.top, 8)
        .opacity(capture.segments.isEmpty && !cam.isRecording && !cam.finalizing ? 0 : 1)
    }

    /// Zoom UI for the single camera: a photo zoom slider (when not recording) + lens buttons.
    /// During recording you zoom by swiping up/down on the shutter (see `shutter`).
    @ViewBuilder private var zoomControls: some View {
        if cam.position == .back {
            VStack(spacing: 10) {
                if !isRec {
                    HStack(spacing: 10) {
                        Image(systemName: "minus.magnifyingglass").font(.caption).foregroundStyle(.white)
                        Slider(value: Binding(get: { cam.zoom }, set: { cam.setZoom($0) }), in: minZoom...maxZoom)
                            .tint(.white)
                        Image(systemName: "plus.magnifyingglass").font(.caption).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 44)
                }
                if !cam.lensPresets.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(cam.lensPresets, id: \.self) { p in
                            let on = abs(cam.zoom - p) < 0.06
                            Button { cam.setZoom(p) } label: {
                                Text(lensLabel(p)).font(.caption2.weight(.bold))
                                    .foregroundStyle(on ? .black : .white)
                                    .frame(width: on ? 42 : 36, height: on ? 42 : 36)
                                    .background(Circle().fill(on ? Color.white : Color.black.opacity(0.4)))
                            }
                        }
                    }
                    .animation(.snappy, value: cam.zoom)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func lensLabel(_ p: Double) -> String {
        p < 1 ? "0.5×" : "\(Int(p))×"
    }

    private var bottomBar: some View {
        HStack {
            Button { showLibrary = true } label: {
                Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            Spacer()
            VStack(spacing: 6) {
                shutter
                // Subtext hint (reserved height, opacity-toggled so the shutter never shifts): only before
                // the first capture and while idle, so a new user knows tap = photo, hold = video.
                Text("Tap for photo · Hold for video")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 3).background(.black.opacity(0.3), in: Capsule())
                    .opacity(!isRec && !cam.finalizing && capture.segments.isEmpty ? 1 : 0)
            }
            Spacer()
            // Review/Next: appears once at least one clip is captured.
            if !capture.segments.isEmpty {
                Button { showReview = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(HavenTheme.pink)
                        Text("\(capture.segments.count)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(4).background(Circle().fill(.black)).offset(x: 4, y: -4)
                    }
                    .frame(width: 52, height: 52)
                }
            } else {
                Color.clear.frame(width: 52, height: 52)   // balance
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
    }

    private var shutter: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 5).frame(width: 82, height: 82)
            Circle().fill(isRec ? Color.red : Color.white)
                .frame(width: isRec ? 38 : 68, height: isRec ? 38 : 68)
                .animation(.spring(response: 0.3), value: isRec)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !pressing && !capture.isFull {
                        pressing = true
                        recordStartZoom = cam.zoom
                        // Hold ≳0.25s → start video; a quick release before that is a photo (single-camera
                        // only — dual-camera is hold-to-record video). 0.25s (was 0.35) makes the hold-to-
                        // record feel responsive without turning a quick photo tap into a stray clip.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            guard pressing, !isRec, !capture.isFull else { return }
                            startedVideo = true   // this press is a VIDEO hold → release stops, never a photo
                            // Each clip records at most 15s (nextClipCap); if the user keeps holding past
                            // that, finishVideo auto-starts the next segment — so a long hold auto-splits.
                            if dualMode { dual.corner = pipCorner; dual.startRecording(maxSeconds: capture.nextClipCap) { url in finishVideo(url) } }
                            else { cam.startRecording(maxSeconds: capture.nextClipCap) { url in finishVideo(url) } }
                        }
                    }
                    // Swipe up/down while hold-recording → zoom (single camera). Up = zoom in.
                    if isRec && !dualMode {
                        let span = maxZoom - minZoom
                        let target = recordStartZoom + (-v.translation.height / 260.0) * span
                        cam.setZoom(min(maxZoom, max(minZoom, target)))
                    }
                }
                .onEnded { _ in
                    pressing = false
                    // A VIDEO hold (startedVideo): stop the current clip; the auto-split gap may have
                    // isRec momentarily false, so gate on startedVideo — NOT isRec — so a release during
                    // that gap doesn't fall through and snap a stray PHOTO. A quick tap (never started
                    // video) takes a photo.
                    if startedVideo {
                        if isRec { dualMode ? dual.stopRecording() : cam.stopRecording() }
                        startedVideo = false
                    } else if !dualMode && !capture.isFull && capture.segments.isEmpty {
                        // Instagram-style: the FIRST shutter action locks the mode. A tap taken before any
                        // video is a photo story; once video segments exist the story is video-only, so a
                        // stray tap is ignored (no photo, no jarring jump to the editor mid-capture).
                        cam.capturePhoto { img in finishPhoto(img) }
                    }
                }
        )
    }

    /// Switch between single and dual (front+back PiP) capture, starting/stopping the sessions.
    private func toggleDual() {
        guard !isRec else { return }
        dualMode.toggle()
        if dualMode { cam.stop(); dual.start() } else { dual.stop(); cam.start() }
    }

    /// Pick which corner the front-facing PiP renders in (dual mode).
    private var cornerPicker: some View {
        HStack(spacing: 10) {
            ForEach(PiPCorner.allCases) { c in
                Button { pipCorner = c; dual.corner = c } label: {
                    Image(systemName: c.icon).font(.title3)
                        .foregroundStyle(pipCorner == c ? HavenTheme.pink : .white)
                        .frame(width: 40, height: 40).background(.black.opacity(0.35), in: Circle())
                }
            }
        }
    }

    /// Apply a swiped-to live filter and briefly flash its name.
    private func cycleLiveFilter(_ filter: HavenFilter) {
        withAnimation(HavenTheme.smooth) { liveFilter = filter; filterNameShown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.3)) { if liveFilter == filter { filterNameShown = false } }
        }
    }

    private func finishPhoto(_ img: PlatformImage) {
        // A photo is a single-frame story → straight to the composer (no multi-clip stacking).
        draft = StoryDraft(mediaRef: MediaStore.shared.addImage(img))
    }
    private func finishVideo(_ url: URL) {
        // A captured clip becomes a pending segment; stay in the camera to add more (or review).
        Task { @MainActor in
            // Duration from the ORIGINAL recorded file (finalized in the recording delegate). A fumbled
            // hold that barely started yields a sub-0.3s clip — SKIP it rather than add a 0-second black
            // segment that also poisons `remaining` and dead-locks the shutter (the "won't record" bug).
            let raw = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            guard raw.isFinite, raw >= 0.3 else {
                // A sub-0.3s fumble — but if the user is still holding with room left, resume the next
                // segment so a brief hiccup doesn't abandon a continuous hold.
                if pressing, !capture.isFull { cam.startRecording(maxSeconds: capture.nextClipCap) { u in finishVideo(u) } }
                else { cam.finalizing = false; cam.recordingSeconds = 0 }
                return
            }
            // Grab a poster from the recorded file NOW (one fast frame, off the slow transcode path) so the
            // segment thumbnail is never a black placeholder while the final blob re-encodes.
            let poster = await Task.detached { MediaStore.poster(for: url) }.value
            let ref = await MediaStore.shared.addVideo(url: url)
            capture.add(ref: ref, duration: raw, thumb: poster ?? MediaStore.shared.item(ref)?.image)   // add clamps to 15s
            // Continuous hold auto-splits: if the finger is still down and a cap isn't hit, immediately
            // record the next 15s segment (startRecording clears finalizing + resets the counter, so the
            // committed segment replaces the held slot in ONE render — no drop). When a cap IS hit or the
            // finger is up, clear the held slot cleanly (the segment is now committed).
            if pressing, !capture.isFull {
                cam.startRecording(maxSeconds: capture.nextClipCap) { u in finishVideo(u) }
            } else {
                cam.finalizing = false; cam.recordingSeconds = 0
                if capture.isFull { showReview = true }
            }
        }
    }
}
#else
/// Native macOS story camera. Keeps the iOS initializer signature (`onShare`) so call sites
/// compile unchanged. A live (Metal-filtered) preview + capture controls (click = photo, hold =
/// video) feed the shared `StoryCaptureModel` / `StoryReviewView` / `StoryComposerView` flow,
/// ending in `onShare`. Matches iOS feature-for-feature except for the iOS-only optics
/// (lens presets / pinch zoom) and dual camera, which Macs don't support.
struct StoryCameraView: View {
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraModel()
    @StateObject private var capture = StoryCaptureModel()
    @State private var showReview = false
    @State private var draft: StoryDraft?
    // Live filter applied to the camera feed, carried into the composer as the default look.
    @State private var liveFilter: HavenFilter = .original
    @State private var liveThumb: PlatformImage?
    @State private var showLiveFilters = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cam.ready {
                // Live, Metal-backed filtered preview (same FilterEngine pipeline as iOS).
                FilteredCameraPreview(tap: cam.frameTap, filter: liveFilter,
                                      orientation: havenCameraOrientation(position: cam.position),
                                      onThumbnail: { liveThumb = $0 }).ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Starting camera…").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }

            VStack {
                HStack {
                    // Shared `CameraChromeButton` (see CameraView.swift) — same glass chips the macOS
                    // post camera uses, so the two cameras' top rows are identical by construction.
                    CameraChromeButton(symbol: "xmark") { dismiss() }
                    Spacer()
                    // Always label the story's max length; when it's reached, call it out.
                    Text(capture.isFull ? "Max length · \(StoryCaptureModel.maxLabel)" : "\(StoryCaptureModel.maxLabel) max")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(capture.isFull ? 1 : 0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    if cam.ready {
                        HStack(spacing: 10) {
                            CameraChromeButton(symbol: "camera.filters", active: liveFilter != .original) {
                                withAnimation(HavenTheme.smooth) { showLiveFilters.toggle() }
                            }
                            CameraChromeButton(symbol: "arrow.triangle.2.circlepath.camera") { cam.flip() }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12)
                Spacer()
                if showLiveFilters, let liveThumb {
                    FilterStrip(thumbnail: liveThumb, selection: $liveFilter)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 12).padding(.bottom, 20)   // clear the shutter — don't crowd it
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomBar
            }
        }
        .portraitLocked()
        .onAppear { cam.start(); cam.resetRecordingState() }
        .onDisappear { cam.stop() }
        .havenFullScreenCover(isPresented: $showReview) {
            StoryReviewView(capture: capture,
                            onCaptureMore: { showReview = false },
                            onNext: {
                                showReview = false
                                let refs = capture.segments.map(\.ref)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { draft = StoryDraft(refs: refs) }
                            })
        }
        .havenFullScreenCover(item: $draft) { d in
            StoryComposerView(draft: d, initialFilter: liveFilter) { ref, caption, track in
                onShare(ref, caption, track)
            } onDone: {
                dismiss()
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Color.clear.frame(width: 52, height: 52)   // balance
            Spacer()
            shutter
            Spacer()
            if !capture.segments.isEmpty {
                Button { showReview = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(HavenTheme.pink)
                        Text("\(capture.segments.count)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(4).background(Circle().fill(.black)).offset(x: 4, y: -4)
                    }
                    .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
    }

    /// Click = photo, click-and-hold = record video. (No pinch/lens zoom — Macs lack the optics.)
    private var shutter: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 5).frame(width: 82, height: 82)
            Circle().fill(cam.isRecording ? Color.red : Color.white)
                .frame(width: cam.isRecording ? 38 : 68, height: cam.isRecording ? 38 : 68)
                .animation(.spring(response: 0.3), value: cam.isRecording)
        }
        .contentShape(Circle())
        // CLICK = photo. The LongPressGesture-only sequence needed a 0.35s hold before doing anything, so
        // a normal click never took a photo on macOS.
        .onTapGesture {
            guard cam.ready, !cam.isRecording, !capture.isFull else { return }
            cam.capturePhoto { img in finishPhoto(img) }
        }
        // CLICK-AND-HOLD (≥0.35s) = record; release stops it.
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    guard !capture.isFull, !cam.isRecording else { return }
                    cam.startRecording(maxSeconds: capture.remaining) { url in finishVideo(url) }
                }
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onEnded { _ in
                    if cam.isRecording { cam.stopRecording() }
                }
        )
        .disabled(!cam.ready)
    }

    private func finishPhoto(_ img: PlatformImage) {
        draft = StoryDraft(mediaRef: MediaStore.shared.addImage(img))
    }
    private func finishVideo(_ url: URL) {
        Task { @MainActor in
            // Duration from the ORIGINAL recorded file (finalized in the recording delegate). A fumbled
            // hold that barely started yields a sub-0.3s clip — SKIP it rather than add a 0-second black
            // segment that also poisons `remaining` and dead-locks the shutter (the "won't record" bug).
            let raw = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            guard raw.isFinite, raw >= 0.3 else { return }
            // Grab a poster from the recorded file NOW (one fast frame, off the slow transcode path) so the
            // segment thumbnail is never a black placeholder while the final blob re-encodes.
            let poster = await Task.detached { MediaStore.poster(for: url) }.value
            let ref = await MediaStore.shared.addVideo(url: url)
            // Clamp so a long take can't push the total past the 90s cap (belt for isFull).
            let dur = min(raw, max(0.3, capture.remaining))
            capture.add(ref: ref, duration: dur, thumb: poster ?? MediaStore.shared.item(ref)?.image)
            if capture.isFull { showReview = true }
        }
    }
}
#endif

// MARK: - Draft + composer

struct StoryDraft: Identifiable {
    let id = UUID()
    let refs: [String]                         // one (photo / single clip) or many (multi-clip)
    init(mediaRef: String) { refs = [mediaRef] }
    init(refs: [String]) { self.refs = refs.isEmpty ? [""] : refs }
    var mediaRef: String { refs.first ?? "" }  // the preview frame
}

/// After capture: preview the shot, add a caption, pick a song, then share. A caption + song
/// apply to every clip in a multi-clip story.
struct StoryComposerView: View {
    let draft: StoryDraft
    var onShare: (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    /// `initialFilter` seeds the picker with the look that was live on the camera, so a story
    /// framed with a filter keeps it by default (the composer still lets you change it).
    init(draft: StoryDraft, initialFilter: HavenFilter = .original,
         onShare: @escaping (_ mediaRef: String, _ caption: String, _ track: TrackRefFfi?) -> Void,
         onDone: @escaping () -> Void = {}) {
        self.draft = draft
        self.onShare = onShare
        self.onDone = onDone
        _filter = State(initialValue: initialFilter)
        // Filters stay hidden until the user taps the filter button — even if a live filter was carried
        // over from capture (the chosen look is still applied to the media; only the picker strip hides).
        _showFilters = State(initialValue: false)
    }

    @State private var caption = ""
    @State private var track: TrackRefFfi?
    @State private var showSongs = false
    @State private var showFilters: Bool
    @State private var filter: HavenFilter
    @State private var sharing = false
    @State private var editingCaption = false
    @State private var captionSpec = StoryCaptions.Spec()
    @State private var musicStartMs = 0.0
    @State private var songPreviewing = false
    /// The "usable section" the story actually plays: for a VIDEO story, the video's own length (so the
    /// song preview loops the SAME window that ships and shares the video's loop period); for a photo, the
    /// story's default slide length. Clamped to a sane preview range.
    @State private var sectionLenMs: Double = 15_000
    @State private var previewLoopTimer: Timer?
    @State private var kbHeight: CGFloat = 0   // live keyboard height (the editor ignores the safe area)
    // Accumulators so pinch/drag continue from the current framing each gesture.
    @State private var mediaBaseScale: CGFloat = 1
    @State private var mediaBaseOffX: CGFloat = 0
    @State private var mediaBaseOffY: CGFloat = 0
    @FocusState private var captionFocused: Bool

    var body: some View {
      // Capture the REAL device safe-area insets at the root, before any child `.ignoresSafeArea()`
      // collapses them. The controls layer re-applies these so it never lands under the notch / Dynamic
      // Island / home indicator, while the media behind it still fills the screen edge-to-edge.
      GeometryReader { proxy in
        let safeInsets = proxy.safeAreaInsets
        ZStack {
            Color.black.ignoresSafeArea()
            media.ignoresSafeArea()

            // A full-screen layer: tap toggles caption editing; pinch/drag reframes the media
            // (only when not editing, so the gestures don't fight the keyboard/caption).
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture {
                        if editingCaption { captionFocused = false; editingCaption = false }
                        else { editingCaption = true }
                    }
                    .gesture(editingCaption ? nil : SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { v in captionSpec.mediaScale = min(max(1, mediaBaseScale * v), 4) }
                            .onEnded { _ in mediaBaseScale = captionSpec.mediaScale },
                        DragGesture()
                            .onChanged { v in
                                captionSpec.mediaOffX = mediaBaseOffX + v.translation.width / max(geo.size.width, 1)
                                captionSpec.mediaOffY = mediaBaseOffY + v.translation.height / max(geo.size.height, 1)
                            }
                            .onEnded { _ in mediaBaseOffX = captionSpec.mediaOffX; mediaBaseOffY = captionSpec.mediaOffY }
                    ))
            }

            // Caption overlay (Instagram-style: tap to type, sits over the media).
            // Centered, but lifted into the visible area above the keyboard while editing.
            if editingCaption {
                VStack {
                    Spacer()
                    // Live preview that EXACTLY equals the final caption: render the real
                    // StyledCaption as the visible layer, with an invisible TextField on top that
                    // only captures keystrokes + shows the caret. (Styling a vertical-axis TextField
                    // directly never matched — `fixedSize` either ballooned it to a full-height bar
                    // or collapsed it to an empty sliver. This sidesteps that entirely.)
                    ZStack {
                        StyledCaption(text: caption.isEmpty ? " " : caption, spec: captionSpec)
                        TextField("", text: $caption, axis: .vertical)
                            .focused($captionFocused)
                            .textFieldStyle(.plain)   // no macOS field chrome (the black box over the media)
                            .multilineTextAlignment(.center)
                            .font(StoryCaptions.font(captionSpec))
                            .foregroundStyle(.clear)   // glyphs hidden (StyledCaption shows them); caret stays
                            .tint(.white)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 24)
                    .onAppear {
                        // Focus must be set *after* the field is in the hierarchy.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { captionFocused = true }
                    }
                    Spacer()
                }
                .offset(y: -kbHeight / 2)
                .animation(.easeOut(duration: 0.25), value: kbHeight)
            } else if !caption.isEmpty {
                // Draggable: position the caption anywhere; the spot travels with the story.
                GeometryReader { geo in
                    StyledCaption(text: caption, spec: captionSpec)
                        .padding(.horizontal, 12)
                        .position(x: captionSpec.x * geo.size.width, y: captionSpec.y * geo.size.height)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    captionSpec.x = min(max(0.12, v.location.x / geo.size.width), 0.88)
                                    captionSpec.y = min(max(0.10, v.location.y / geo.size.height), 0.90)
                                }
                        )
                        .onTapGesture { editingCaption = true }
                }
            }

            VStack {
                if !editingCaption { topControls } else { editingTopBar }
                Spacer()
                if let track {
                    nowPlayingChip(track)
                    if track.durationMs > 16000 && !editingCaption { musicSectionSlider(track) }
                }
                // Caption style controls sit as a bar right above the keyboard while editing.
                if editingCaption { captionStyleControls.padding(.bottom, 8) }
                if !editingCaption && showFilters { filterBar.padding(.bottom, 8) }
                if !editingCaption { shareBar }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // pin controls to the screen, never the media's size
            // The media + black backdrop `.ignoresSafeArea()`, which expands THIS ZStack to the full
            // screen — so the controls VStack (maxHeight .infinity) fills into the notch / Dynamic Island
            // and the home-indicator strip, jamming the X button and Share bar into the unsafe regions.
            // Re-inset the controls by the real device insets captured at the root (`safeInsets`) so they
            // land back inside the visible area, while the media stays edge-to-edge behind them.
            .padding(.top, safeInsets.top)   // topControls adds its own +8 below this
            .padding(.bottom, editingCaption ? kbHeight : safeInsets.bottom + 8)
            .padding(.horizontal, max(safeInsets.leading, safeInsets.trailing))   // landscape/side insets
            // Opt out of SwiftUI's automatic keyboard avoidance — otherwise it stacks on top of
            // our manual kbHeight lift and shoves the controls to the top of the screen.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(.easeOut(duration: 0.25), value: kbHeight)
        }
        .havenStatusBarHidden()
        .portraitLocked()
        .modifier(KeyboardHeightObserver(kbHeight: $kbHeight))
        .sheet(isPresented: $showSongs) {
            SongPicker { t in track = t }
        }
        .task { await loadSectionLen() }   // size the song's usable section to the video's own length
      }
      // NB: no `.ignoresSafeArea()` on the GeometryReader itself — it must stay inset so `proxy.safeAreaInsets`
      // reports the real device insets. The media/backdrop reach the screen edges via their own `.ignoresSafeArea()`.
    }

    private var media: some View {
        StoryMediaCanvas(mediaRef: draft.mediaRef,
                         scale: captionSpec.mediaScale, offX: captionSpec.mediaOffX, offY: captionSpec.mediaOffY,
                         filter: filter)
    }

    /// While editing the caption, the top bar is just a Done button — the styling lives in the
    /// bar above the keyboard.
    private var editingTopBar: some View {
        HStack {
            Spacer()
            Button { captionFocused = false; editingCaption = false } label: {
                Text("Done").font(.headline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.black.opacity(0.4), in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var topControls: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            controlButton("Aa", system: nil) {
                editingCaption = true
            }
            controlButton(nil, system: "camera.filters") {
                withAnimation(HavenTheme.smooth) { showFilters.toggle() }
            }
            .overlay(alignment: .topTrailing) {
                if filter != .original {
                    Circle().fill(HavenTheme.pink).frame(width: 10, height: 10).offset(x: 2, y: -2)
                }
            }
            controlButton(nil, system: track == nil ? "music.note" : "music.note.list") {
                showSongs = true
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    /// Live filter chooser under the preview. Uses the preview frame (photo / video poster) as
    /// the thumbnail; the chosen look is baked into every shared ref at share time.
    @ViewBuilder private var filterBar: some View {
        if let thumb = MediaStore.shared.item(draft.mediaRef)?.image {
            FilterStrip(thumbnail: thumb, selection: $filter)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func controlButton(_ text: String?, system: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let text { Text(text).font(.headline.weight(.bold)) }
                else if let system { Image(systemName: system).font(.title3.weight(.semibold)) }
            }
            .foregroundStyle(.white).frame(width: 42, height: 42)
            .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)   // no macOS rectangular button chrome behind the circle
    }

    /// Caption editing controls: tap-through typography, highlight toggle, color row.
    private var captionStyleControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { captionSpec.cycleFont() } label: {
                    Text("Aa").font(.headline.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.black.opacity(0.4), in: Circle())
                }
                // Cycle the caption style (plain → glow → shadow → neon → highlight), like the font.
                Button { captionSpec.cycleStyle() } label: {
                    VStack(spacing: 1) {
                        Image(systemName: captionSpec.style.icon).font(.subheadline)
                        Text(captionSpec.style.label).font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(.black.opacity(0.4), in: Circle())
                }
                // Size slider — the caption scale travels to viewers in the spec.
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size.smaller").font(.caption).foregroundStyle(.white)
                    Slider(value: $captionSpec.size, in: StoryCaptions.minSize...StoryCaptions.maxSize)
                        .tint(HavenTheme.pink)
                    Image(systemName: "textformat.size.larger").font(.body).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            CaptionColorRow(spec: $captionSpec)
        }
    }

    /// A clean HUD to scrub + preview WHICH part of the song plays with the story. The window equals the
    /// story's usable section (the video's length), and the preview loops just that window so you hear
    /// exactly what ships, on repeat, matching the video's loop.
    private func musicSectionSlider(_ t: TrackRefFfi) -> some View {
        let maxStart = Double(max(1, Int(t.durationMs) - Int(sectionLenMs)))
        return HStack(spacing: 12) {
            Button { toggleSongPreview(t) } label: {
                Image(systemName: songPreviewing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Int((sectionLenMs / 1000).rounded()))s clip from \(fmtTime(musicStartMs))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                Slider(value: $musicStartMs, in: 0...maxStart) { editing in
                    if !editing && songPreviewing { seekPreview() }
                }
                .tint(HavenTheme.pink)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16).padding(.bottom, 8)
        .onChange(of: musicStartMs) { if songPreviewing { seekPreview() } }
        .onDisappear { stopSongPreview() }
    }

#if os(iOS)
    private func toggleSongPreview(_ t: TrackRefFfi) {
        let player = MPMusicPlayerController.applicationMusicPlayer
        if songPreviewing { stopSongPreview(); return }
        let ids = trackIds(t.catalogId)
        if let pid = ids.pid, let item = librarySong(pid) { player.setQueue(with: MPMediaItemCollection(items: [item])) }
        else if let store = ids.store { player.setQueue(with: [store]) }
        player.play()
        player.currentPlaybackTime = musicStartMs / 1000
        songPreviewing = true
        // Loop JUST the usable section: when playback runs past the section end, seek back to the start,
        // so the preview repeats the exact window that ships (and shares the video's loop period).
        previewLoopTimer?.invalidate()
        previewLoopTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            let end = (musicStartMs + sectionLenMs) / 1000
            if player.currentPlaybackTime >= end || player.currentPlaybackTime < (musicStartMs / 1000) - 0.5 {
                player.currentPlaybackTime = musicStartMs / 1000
            }
        }
    }
    private func stopSongPreview() {
        previewLoopTimer?.invalidate(); previewLoopTimer = nil
        if songPreviewing { MPMusicPlayerController.applicationMusicPlayer.stop() }
        songPreviewing = false
    }
    private func seekPreview() {
        MPMusicPlayerController.applicationMusicPlayer.currentPlaybackTime = musicStartMs / 1000
    }
    /// Size the song's usable section to the STORY's own length: a video story's section is the video's
    /// duration (so the loop matches the clip that ships), clamped to a 3–15s preview range; a photo keeps
    /// the 15s default. Runs off-main to read the asset, then updates on the main actor.
    private func loadSectionLen() async {
        guard let m = MediaStore.shared.item(draft.mediaRef), m.kind == .video, let url = m.videoURL else { return }
        let secs = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        guard secs.isFinite, secs > 0 else { return }
        let clamped = min(15.0, max(3.0, secs))
        await MainActor.run {
            sectionLenMs = clamped * 1000
            // Keep the chosen start valid for the new (possibly larger) window.
            musicStartMs = min(musicStartMs, Double(max(1, Int(track?.durationMs ?? 0) - Int(sectionLenMs))))
        }
    }
#else
    // MediaPlayer (MPMusicPlayerController) is unavailable on native macOS — no-op previews.
    private func toggleSongPreview(_ t: TrackRefFfi) {}
    private func stopSongPreview() { songPreviewing = false }
    private func seekPreview() {}
    private func loadSectionLen() async {}
#endif
    private func fmtTime(_ ms: Double) -> String {
        let s = Int(ms / 1000); return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The track with the chosen section start baked in (artworkUrl = "start:<ms>").
    private func trackForShare() -> TrackRefFfi? {
        guard let t = track else { return nil }
        guard musicStartMs > 0 else { return t }
        return TrackRefFfi(catalogId: t.catalogId, title: t.title, artist: t.artist,
                           artworkUrl: "start:\(Int(musicStartMs))", durationMs: t.durationMs)
    }

    private func nowPlayingChip(_ t: TrackRefFfi) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note").font(.caption)
            Text("\(t.title) · \(t.artist)").font(.caption.weight(.medium)).lineLimit(1)
            Button { track = nil } label: { Image(systemName: "xmark.circle.fill") }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.black.opacity(0.4), in: Capsule())
        .padding(.bottom, 12)
    }

    private var shareBar: some View {
        HStack {
            Spacer()
            Button { share() } label: {
                HStack(spacing: 8) {
                    if sharing {
                        ProgressView().tint(.white)
                    } else {
                        Text(draft.refs.count > 1 ? "Share \(draft.refs.count) stories" : "Share to story")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "arrow.right")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(HavenTheme.brandHorizontal, in: Capsule())
            }
            .disabled(sharing)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }

    /// Bake the chosen filter into every clip (photos rewrite in place, videos export a new
    /// filtered ref), then hand each off as its own story. `.original` is a no-op so existing
    /// capture behavior is unchanged.
    private func share() {
        guard !sharing else { return }
        sharing = true
        let body = StoryCaptions.encode(caption, captionSpec)
        let chosen = filter
        let track = trackForShare()
        let refs = draft.refs.filter { !$0.isEmpty }
        Task { @MainActor in
            for ref in refs {
                let outRef = await MediaStore.shared.applyFilter(chosen, to: ref)
                onShare(outRef, body, track)
            }
            sharing = false
            dismiss(); onDone()
        }
    }
}

/// Tracks the live keyboard height. On iOS/Catalyst it observes the system keyboard
/// notifications; on native macOS there is no software keyboard, so it's a no-op.
private struct KeyboardHeightObserver: ViewModifier {
    @Binding var kbHeight: CGFloat
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                if let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { kbHeight = f.height }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in kbHeight = 0 }
        #else
        content
        #endif
    }
}

/// Review captured story clips before sharing: swipe through each, trash any, capture more
/// (back to the camera), or continue to the composer.
struct StoryReviewView: View {
    @ObservedObject var capture: StoryCaptureModel
    var onCaptureMore: () -> Void
    var onNext: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !capture.segments.isEmpty {
                TabView(selection: $index) {
                    ForEach(Array(capture.segments.enumerated()), id: \.element.id) { i, seg in
                        StoryMediaCanvas(mediaRef: seg.ref).tag(i).ignoresSafeArea()
                    }
                }
                #if !os(macOS)
                // `.page` tabViewStyle (swipe between clips) is unavailable on native macOS.
                .havenPagedTabViewStyle(showsIndex: false)
                #endif
                .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button { dismiss(); onCaptureMore() } label: {
                        Image(systemName: "chevron.left").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    Text("\(capture.segments.count) clip\(capture.segments.count == 1 ? "" : "s") · \(Int(capture.total))s / 90s")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Button(role: .destructive) { trashCurrent() } label: {
                        Image(systemName: "trash.fill").font(.title3).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.4), in: Circle())
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
                Spacer()
                HStack {
                    Button { dismiss(); onCaptureMore() } label: {
                        Label("Capture more", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                    .disabled(capture.isFull).opacity(capture.isFull ? 0.5 : 1)
                    Spacer()
                    Button { onNext() } label: {
                        HStack(spacing: 8) { Text("Next").font(.subheadline.weight(.semibold)); Image(systemName: "arrow.right") }
                            .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
                            .background(HavenTheme.brandHorizontal, in: Capsule())
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
        }
        .havenStatusBarHidden()
        .portraitLocked()
    }

    private func trashCurrent() {
        guard capture.segments.indices.contains(index) else { return }
        capture.remove(capture.segments[index].id)
        if capture.segments.isEmpty { dismiss(); onCaptureMore() }
        else { index = min(index, capture.segments.count - 1) }
    }
}

/// A muted, looping video for the composer preview. When a `filter` is set, frames are run through
/// the SAME `FilterEngine` pipeline via an `AVVideoComposition` so the preview matches the live
/// camera AND the baked-on-export result (it used to play unfiltered, so filters looked like they
/// "didn't stick" on video clips).
#if !os(macOS)
struct LoopingVideo: UIViewRepresentable {
    let url: URL
    var fill: Bool = true   // false → fit (letterbox), e.g. show a landscape clip in full
    var filter: HavenFilter = .original
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.load(url, fill: fill, filter: filter)
        return v
    }
    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.update(filter: filter)
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var looper: Any?
        private var queue: AVQueuePlayer?
        private var asset: AVURLAsset?
        private var current: HavenFilter = .original
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func load(_ url: URL, fill: Bool, filter: HavenFilter) {
            let asset = AVURLAsset(url: url)
            self.asset = asset
            current = filter
            let item = Self.makeItem(asset: asset, filter: filter)
            // The queue MUST start empty: AVPlayerLooper enqueues copies of the templateItem itself.
            // Passing the same item to AVQueuePlayer(playerItem:) AND as the template makes the looper
            // re-insert an item already owned by the player → -[AVPlayer _insertItem:afterItem:] throws
            // (SIGABRT). Apple's documented pattern is an empty AVQueuePlayer().
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            playerLayer.player = queue
            playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            self.queue = queue
            queue.play()
        }

        /// Swap in a new filtered composition when the chosen look changes (rebuild the loop).
        func update(filter: HavenFilter) {
            guard filter != current, let asset, let queue else { return }
            current = filter
            let item = Self.makeItem(asset: asset, filter: filter)
            queue.removeAllItems()   // clear the previous looper's enqueued items before re-looping
            looper = AVPlayerLooper(player: queue, templateItem: item)
            queue.play()
        }

        private static func makeItem(asset: AVURLAsset, filter: HavenFilter) -> AVPlayerItem {
            let item = AVPlayerItem(asset: asset)
            guard filter != .original else { return item }
            let spec = filter.spec
            item.videoComposition = AVMutableVideoComposition(asset: asset) { request in
                let src = request.sourceImage.clampedToExtent()
                let out = FilterEngine.apply(spec, to: src).cropped(to: request.sourceImage.extent)
                request.finish(with: out, context: nil)
            }
            return item
        }
    }
}
#else
/// Native macOS muted, looping video preview. Mirrors the iOS `LoopingVideo` public props
/// (`url`, `fill`) using a layer-backed NSView wrapping an `AVQueuePlayer` + `AVPlayerLooper`
/// rendered through an `AVPlayerLayer`.
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    var fill: Bool = true   // false → fit (letterbox)
    var filter: HavenFilter = .original
    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.load(url, fill: fill, filter: filter)
        return v
    }
    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.update(filter: filter)
    }

    static func dismantleNSView(_ nsView: PlayerNSView, coordinator: ()) {
        nsView.stop()
    }

    final class PlayerNSView: NSView {
        private var looper: AVPlayerLooper?
        private var queue: AVQueuePlayer?
        private var playerLayer: AVPlayerLayer?
        private var asset: AVURLAsset?
        private var current: HavenFilter = .original
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func load(_ url: URL, fill: Bool, filter: HavenFilter) {
            let asset = AVURLAsset(url: url)
            self.asset = asset
            current = filter
            let item = Self.makeItem(asset: asset, filter: filter)
            // Empty queue — the looper enqueues copies of templateItem (see the iOS load() above).
            let q = AVQueuePlayer()
            q.isMuted = true
            looper = AVPlayerLooper(player: q, templateItem: item)
            let pl = AVPlayerLayer(player: q)
            pl.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            pl.frame = bounds
            self.layer?.addSublayer(pl)
            playerLayer = pl
            queue = q
            q.play()
        }
        func update(filter: HavenFilter) {
            guard filter != current, let asset, let queue else { return }
            current = filter
            queue.removeAllItems()   // clear the previous looper's enqueued items before re-looping
            looper = AVPlayerLooper(player: queue, templateItem: Self.makeItem(asset: asset, filter: filter))
            queue.play()
        }
        private static func makeItem(asset: AVURLAsset, filter: HavenFilter) -> AVPlayerItem {
            let item = AVPlayerItem(asset: asset)
            guard filter != .original else { return item }
            let spec = filter.spec
            item.videoComposition = AVMutableVideoComposition(asset: asset) { request in
                let src = request.sourceImage.clampedToExtent()
                let out = FilterEngine.apply(spec, to: src).cropped(to: request.sourceImage.extent)
                request.finish(with: out, context: nil)
            }
            return item
        }
        func stop() {
            queue?.pause()
            queue = nil
            looper = nil
        }
        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
        }
    }
}
#endif

// `Image(platformImage:)` is provided centrally in Platform.swift.

/// Renders story media inside the standard 9:16 canvas: the media is shown in **full** (fit),
/// centered, over a **blurred fill of itself** — so landscape (or any off-ratio) photos and
/// videos sit cleanly within the frame instead of cropping or leaving dead bands.
struct StoryMediaCanvas: View {
    let mediaRef: String
    /// Author's framing: zoom + normalized translation (fraction of canvas).
    var scale: CGFloat = 1
    var offX: CGFloat = 0
    var offY: CGFloat = 0
    /// Live preview-only filter, applied to both stills and video frames here for instant
    /// feedback; it is baked into the actual media bytes at share time. Defaults to `.original`.
    var filter: HavenFilter = .original

    /// The (optionally filtered) preview still for this ref.
    private func preview(_ img: PlatformImage) -> PlatformImage {
        filter == .original ? img : FilterEngine.apply(filter, to: img)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black   // base so there's never a transparent gap
                if let m = MediaStore.shared.item(mediaRef) {
                    let still = m.image.map(preview)
                    // Blurred fill backdrop, sized to the WHOLE canvas (the still covers photo
                    // + video). Explicit frame is what makes it fill instead of collapsing to
                    // the fit-image's height.
                    if let img = still {
                        Image(platformImage: img).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: 28)
                            .overlay(Color.black.opacity(0.28))
                    }
                    // Foreground: the media aspect-FILLS the canvas (full-bleed, overflow cropped),
                    // exactly matching the story PLAYER (StoryViewer uses VideoSurface fill +
                    // scaledToFill for images). Keeping the composer preview identical to the player
                    // means WYSIWYG — the author frames the media and positions the caption just as
                    // viewers will. The blurred backdrop stays as a safety base if fill leaves a gap.
                    Group {
                        if m.kind == .video, let url = m.videoURL {
                            // Video previews WITH the chosen filter (same FilterEngine pipeline,
                            // applied per-frame), matching the live camera and the baked export.
                            LoopingVideo(url: url, fill: true, filter: filter)
                        } else if let img = still {
                            Image(platformImage: img).resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .scaleEffect(scale)
                    .offset(x: offX * geo.size.width, y: offY * geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}
