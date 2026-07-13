import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A simple, intuitive in-app camera: tap the shutter for a photo, hold it to record
/// video, tap to flip. Captures stay on-device (sandbox), registered in `MediaStore`
/// and only ever sent after being sealed E2E. (AVCaptureSession needs a real device.)
///
/// After a capture, a lightweight review sheet shows the shot with a live `FilterStrip` so the
/// user can pick a `HavenFilter` and tap "Use" — the chosen look is baked into the media before
/// it's handed back via `onCaptured`. Default `.original` keeps the prior behavior.
struct CameraView: View {
    var onCaptured: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reviewRefs: [String]?
    // Live filter: applied to the camera feed in real time and carried into the review sheet as
    // the default. `liveThumb` is a downscaled still off the live feed for the swatches.
    @State private var liveFilter: HavenFilter = .original
    @State private var liveThumb: PlatformImage?
    // The filter strip is COLLAPSED by default (matches the story camera) — an always-open strip
    // crowded the live view and collided with the shutter. Swipe left/right on the preview still
    // cycles filters without opening it; this toggle reveals the tappable swatches when wanted.
    @State private var showFilters = false

    var body: some View {
        // A GeometryReader that IGNORES the safe area fills the whole screen (so the camera reaches every
        // edge) yet still reports the true safe-area insets — which we pad the controls by, so the filter
        // toggle clears the status bar / Dynamic Island and the strip clears the home indicator. (The
        // controls previously measured from the screen top and jammed into the status bar.)
        GeometryReader { geo in
            ZStack {
                CameraCaptureRepresentable(filter: $liveFilter, onThumbnail: { liveThumb = $0 }) { refs in
                    reviewRefs = refs
                }

                // Filter toggle (top-right, clear of the UIKit close button at top-left) + a collapsible
                // strip floated ABOVE the shutter so swatches never cover it.
                #if !os(macOS)
                VStack {
                    HStack {
                        Spacer()
                        Button { withAnimation(.snappy) { showFilters.toggle() } } label: {
                            Image(systemName: "camera.filters")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(11)
                                .background(showFilters ? AnyShapeStyle(HavenTheme.brandHorizontal)
                                                        : AnyShapeStyle(.black.opacity(0.35)), in: Circle())
                        }
                        .padding(.trailing, 20)
                    }
                    .padding(.top, geo.safeAreaInsets.top + 8)   // honor the top safe area
                    Spacer()
                    if showFilters, let liveThumb {
                        FilterStrip(thumbnail: liveThumb, selection: $liveFilter)
                            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(.horizontal, 10)
                            .padding(.bottom, geo.safeAreaInsets.bottom + 100)   // clear the shutter + home indicator
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                #endif
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        // Lock to portrait like the story camera: the shutter/controls never move on rotation, while
        // the capture connection still follows the PHYSICAL device orientation (see shutter handlers),
        // so rotating the phone records landscape/portrait automatically without the button shifting.
        .portraitLocked()
        .havenFullScreenCover(item: Binding(get: { reviewRefs.map { CaptureBatch(refs: $0) } },
                                       set: { reviewRefs = $0?.refs })) { batch in
            CaptureReviewView(refs: batch.refs, initialFilter: liveFilter) { finalRefs in
                reviewRefs = nil
                // Camera captures are media you made in-app → Haven ▸ Shared (when Save to
                // Photos is on). Save the FILTERED result the user actually chose.
                for ref in finalRefs {
                    if let item = MediaStore.shared.item(ref) {
                        PhotoSaver.saveIfEnabled(item, to: .shared, circleId: FeedStore.shared.activeCircleId)
                    }
                }
                onCaptured(finalRefs)
                dismiss()
            } onRetake: {
                reviewRefs = nil
            }
        }
    }
}

/// Identifiable wrapper so a `[String]` batch can drive a `fullScreenCover(item:)`. The id is
/// DERIVED from the refs (not a fresh UUID): the cover's `item:` binding is recomputed on every
/// view update, and a new UUID each time made SwiftUI think the item changed — dismissing and
/// re-presenting the review sheet in a loop (the "keeps opening and closing" flicker).
private struct CaptureBatch: Identifiable {
    var id: String { refs.joined(separator: "|") }
    let refs: [String]
}

/// The raw UIKit capture controller. Hands fresh capture refs up to the SwiftUI review layer
/// instead of finishing immediately.
#if !os(macOS)
struct CameraCaptureRepresentable: UIViewControllerRepresentable {
    @Binding var filter: HavenFilter
    var onThumbnail: ((PlatformImage) -> Void)? = nil
    var onCaptured: ([String]) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCaptured = onCaptured
        vc.onThumbnail = onThumbnail
        vc.onFilterChanged = { [b = $filter] in b.wrappedValue = $0 }
        vc.liveFilter = filter
        return vc
    }
    func updateUIViewController(_ vc: CameraViewController, context: Context) {
        vc.onFilterChanged = { [b = $filter] in b.wrappedValue = $0 }
        if vc.liveFilter != filter { vc.liveFilter = filter }
    }
}
#endif

#if os(macOS)
/// Native macOS camera capture surface. Mirrors the iOS `CameraCaptureRepresentable` public
/// surface (`filter` binding, optional `onThumbnail`, `onCaptured: ([String]) -> Void`) so the
/// shared `CameraView` call site compiles unchanged.
///
/// A live, Metal-filtered camera preview (`FilteredCameraPreview`) with a `FilterStrip`, a shutter
/// (click = photo, click-and-hold = video), and a Close button. Stills go through
/// `AVCapturePhotoOutput`, video through `AVCaptureMovieFileOutput`; each is stored in `MediaStore`
/// and handed up via `onCaptured`, then filtered in the shared `CaptureReviewView`.
struct CameraCaptureRepresentable: View {
    @Binding var filter: HavenFilter
    var onThumbnail: ((PlatformImage) -> Void)? = nil
    var onCaptured: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = MacCameraEngine()
    @State private var liveThumb: PlatformImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if engine.ready {
                FilteredCameraPreview(tap: engine.frameTap, filter: filter,
                                      orientation: .up,
                                      onThumbnail: { img in liveThumb = img; onThumbnail?(img) })
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Starting camera…")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 12)
                Spacer()

                // Live filter strip (off the live feed thumbnail), like iOS.
                if let liveThumb {
                    FilterStrip(thumbnail: liveThumb, selection: $filter)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 10).padding(.bottom, 6)
                }

                // Shutter: click = photo, click-and-hold (≥0.35s) = video.
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 5).frame(width: 78, height: 78)
                    Circle().fill(engine.isRecording ? Color.red : Color.white)
                        .frame(width: engine.isRecording ? 40 : 62, height: engine.isRecording ? 40 : 62)
                        .animation(.spring(response: 0.3), value: engine.isRecording)
                }
                .contentShape(Circle())
                // CLICK = photo. The old code only had a LongPressGesture sequence, which needs a 0.35s
                // hold before it fires anything — so a normal click did nothing (couldn't take a photo).
                .onTapGesture {
                    guard engine.ready, !engine.isRecording, !engine.capturing else { return }
                    capture()
                }
                // CLICK-AND-HOLD (≥0.35s) = record video; release stops it.
                .gesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .onEnded { _ in
                            guard !engine.isRecording, !engine.capturing else { return }
                            engine.startRecording { url in finishVideo(url) }
                        }
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onEnded { _ in
                            if engine.isRecording { engine.stopRecording() }
                        }
                )
                .disabled(!engine.ready || engine.capturing)
                .padding(.bottom, 28)
            }
        }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }

    private func capture() {
        engine.capturePhoto { img in
            guard let img else { return }
            Task { @MainActor in
                let ref = MediaStore.shared.addImage(img)
                onCaptured([ref])
            }
        }
    }

    private func finishVideo(_ url: URL?) {
        guard let url else { return }
        Task { @MainActor in
            let ref = await MediaStore.shared.addVideo(url: url)
            onCaptured([ref])
        }
    }
}

/// An AVCaptureSession-backed engine for the native macOS post-camera surface. Supports both
/// stills (`AVCapturePhotoOutput`) and video recording (`AVCaptureMovieFileOutput`), plus a live
/// filtered preview via the shared `LiveFrameTap` (rendered by `FilteredCameraPreview`).
@MainActor
final class MacCameraEngine: NSObject, ObservableObject {
    // Capture session + outputs live exclusively on `queue`, so they're nonisolated(unsafe) (access is
    // serialized by the queue, not the main actor). Only the @Published UI state stays main-isolated.
    nonisolated(unsafe) let session = AVCaptureSession()
    @Published var ready = false
    @Published var capturing = false
    @Published var isRecording = false

    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    /// Live filtered preview: tapped frames → FilterEngine → MetalCameraPreview (same as iOS).
    let frameTap = LiveFrameTap()   // @unchecked Sendable
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "haven.maccamera.session")
    nonisolated(unsafe) private var onPhoto: ((PlatformImage?) -> Void)?
    nonisolated(unsafe) private var onVideo: ((URL?) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            // The mic is needed for sound on recorded video; failure just yields a silent clip.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            self.queue.async { self.configure() }
        }
    }

    nonisolated private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        // videoDataOutput MUST be added first: a macOS session caps how many outputs it accepts and
        // rejects the last one. It feeds the live preview AND (via frameTap.latest) the photo capture.
        if session.canAddOutput(videoDataOutput) {
            videoDataOutput.wireLivePreview(tap: frameTap, queue: queue)
            session.addOutput(videoDataOutput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        Task { @MainActor in self.ready = true }
    }

    func stop() {
        queue.async { [weak self] in self?.teardownSession() }
    }

    nonisolated private func teardownSession() {
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
        // Release the camera device so the macOS camera indicator goes off.
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
    }

    func capturePhoto(_ completion: @escaping (PlatformImage?) -> Void) {
        guard !capturing, !isRecording else { return }
        // macOS: AVCapturePhotoOutput silently fails to deliver while an AVCaptureMovieFileOutput is on
        // the same session — the reason the Mac camera "can't take a single photo". Grab the still from
        // the live preview frame instead; always available once the session is running.
        if let ci = frameTap.latest {
            let ctx = CIContext()
            if let cg = ctx.createCGImage(ci, from: ci.extent) {
                completion(NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height)))
                return
            }
        }
        // Fallback if no frame has arrived yet.
        capturing = true
        onPhoto = completion
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    /// Start recording a clip to a temp `.mov`; `completion` fires with the file URL (or nil on
    /// failure) when recording stops. Mirrors the iOS `CameraViewController` recording API.
    func startRecording(_ completion: @escaping (URL?) -> Void) {
        guard !isRecording, !capturing else { return }
        onVideo = completion
        isRecording = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        queue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        queue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }
}

extension MacCameraEngine: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img: PlatformImage? = photo.fileDataRepresentation().flatMap { PlatformImage(data: $0) }
        Task { @MainActor in
            self.capturing = false
            self.onPhoto?(img)
            self.onPhoto = nil
        }
    }
}

extension MacCameraEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.onVideo?(error == nil ? url : nil)
            self.onVideo = nil
        }
    }
}

/// A layer-backed NSView showing an `AVCaptureVideoPreviewLayer` for the given session.
struct MacCameraPreview: NSViewRepresentable {
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

/// Review a just-captured photo or video, pick a filter, then "Use" it. The filter is applied
/// via `MediaStore.applyFilter` (photos rewrite in place, videos export a filtered ref).
struct CaptureReviewView: View {
    let refs: [String]
    var onUse: ([String]) -> Void
    var onRetake: () -> Void

    @State private var filter: HavenFilter
    @State private var working = false

    /// `initialFilter` seeds the picker with whatever look was live on the camera, so the shot the
    /// user already framed with a filter keeps it by default.
    init(refs: [String], initialFilter: HavenFilter = .original,
         onUse: @escaping ([String]) -> Void, onRetake: @escaping () -> Void) {
        self.refs = refs
        self.onUse = onUse
        self.onRetake = onRetake
        _filter = State(initialValue: initialFilter)
    }

    /// Thumbnail for the strip: the first ref's still (photo or video poster).
    private var thumbnail: PlatformImage? { refs.first.flatMap { MediaStore.shared.item($0)?.image } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { onRetake() } label: {
                        Image(systemName: "chevron.left").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    Text("Retake or filter").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20).padding(.top, 8)

                // The preview (first ref). Photos preview the live look; videos play unfiltered
                // (the poster shows the look) and get the filter baked on export.
                if let ref = refs.first {
                    StoryMediaCanvas(mediaRef: ref, filter: filter)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                } else {
                    Spacer()
                }

                if let thumb = thumbnail {
                    FilterStrip(thumbnail: thumb, selection: $filter)
                }

                Button { use() } label: {
                    HStack(spacing: 8) {
                        if working { ProgressView().tint(.white) }
                        else {
                            Text(refs.count > 1 ? "Use \(refs.count)" : "Use")
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "checkmark")
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(HavenTheme.brandHorizontal, in: Capsule())
                }
                .disabled(working)
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 20)
            }
        }
        .havenStatusBarHidden()
    }

    private func use() {
        guard !working else { return }
        working = true
        let chosen = filter
        let input = refs
        Task { @MainActor in
            var out: [String] = []
            for ref in input { out.append(await MediaStore.shared.applyFilter(chosen, to: ref)) }
            working = false
            onUse(out)
        }
    }
}

#if !os(macOS)
final class CameraViewController: UIViewController,
    AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {

    var onCaptured: (([String]) -> Void)?
    var onThumbnail: ((PlatformImage) -> Void)?
    /// Fired when a swipe on the preview changes the filter, so the SwiftUI `FilterStrip` selection
    /// stays in sync.
    var onFilterChanged: ((HavenFilter) -> Void)?
    /// Live look applied to the Metal preview (and carried into the review sheet as the default).
    var liveFilter: HavenFilter = .original { didSet { metalPreview?.filter = liveFilter } }

    // Shutter press state (quick tap = photo, ≥0.35s hold = video).
    private var shutterHeld = false
    private var videoStarted = false

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    // Live filtered preview: frames tapped via a data output → FilterEngine → MTKView.
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let frameTap = LiveFrameTap()
    private let frameQueue = DispatchQueue(label: "haven.camera.frames")
    private var metalPreview: MetalCameraPreview?
    private var position: AVCaptureDevice.Position = .back
    /// The active camera device — kept so pinch-to-zoom can drive `videoZoomFactor` (mirrors the
    /// story camera, whose zoom gesture the post camera was missing).
    private var videoDevice: AVCaptureDevice?
    private var zoomBase: CGFloat = 1
    private let shutter = UIButton(type: .system)
    private let ring = UIView()
    private let filterNameLabel = UILabel()
    private var filterNameHide: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { if granted { self.configure() } else { self.dismiss(animated: true) } }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        buildControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        teardownSession()
    }

    // Belt-and-suspenders: SwiftUI dismissing the fullScreenCover/sheet hosting this controller may
    // not always route through viewWillDisappear, so also tear the session down on dealloc. Both
    // paths are idempotent.
    deinit { teardownSession() }

    /// Fully stop the capture session and release the camera device so the iOS "in use" (green)
    /// indicator goes off — not just stopRunning, which keeps inputs/outputs (and the device) bound.
    private func teardownSession() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        addCameraInput(position: position)
        if let mic = AVCaptureDevice.default(for: .audio),
           let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(videoDataOutput) {
            videoDataOutput.wireLivePreview(tap: frameTap, queue: frameQueue)
            session.addOutput(videoDataOutput)
        }
        session.commitConfiguration()
        configurePreviewConnection()

        // The live filtered preview replaces the old AVCaptureVideoPreviewLayer.
        frameTap.onThumbnail = { [weak self] in self?.onThumbnail?($0) }
        let mtk = MetalCameraPreview(tap: frameTap, device: MTLCreateSystemDefaultDevice())
        mtk.filter = liveFilter
        mtk.frame = view.bounds
        mtk.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(mtk, at: 0)
        mtk.orientation = position == .front ? .leftMirrored : .right   // pinned portrait; never rotates
        metalPreview = mtk

        // No device-orientation observer: the preview stays portrait-upright regardless of how the
        // phone is held; only the captured file follows the device (set at shutter/record time).
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    /// Orient + mirror the capture connections, and pin the live preview to PORTRAIT.
    ///
    /// The UI is portrait-locked (like the story camera), so the live feed must ALWAYS show reality
    /// upright — rotating the phone must NOT spin the preview. The video data-output delivers buffers
    /// in the sensor's fixed native orientation, so a FIXED portrait `.oriented()` (back `.right`,
    /// front `.leftMirrored` for a natural selfie) keeps the feed upright no matter how the device is
    /// held. (The previous code re-derived the preview orientation from `UIDevice.orientation` on every
    /// rotation, which is exactly what rotated the feed 90°.) The captured FILE still follows the
    /// physical device orientation — that's applied to the movie/photo connection at shutter/record
    /// time (see `shutterDown`/`shutterUp`) — so landscape recording keeps working.
    private func configurePreviewConnection() {
        let previewOrientation: CGImagePropertyOrientation = position == .front ? .leftMirrored : .right
        DispatchQueue.main.async { [weak self] in self?.metalPreview?.orientation = previewOrientation }
    }

    // No orientation observer: the preview is pinned to portrait, and capture orientation is set from
    // the live device orientation at shutter/record time — so nothing needs to re-run on rotation.

    private func addCameraInput(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.inputs.filter { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }
            .forEach { session.removeInput($0) }
        if session.canAddInput(input) { session.addInput(input) }
        videoDevice = device
        // Reset zoom to 1× on (re-)configure so a flip doesn't inherit the other lens's factor.
        do { try device.lockForConfiguration(); device.videoZoomFactor = 1; device.unlockForConfiguration() }
        catch { }
    }

    /// Pinch-to-zoom (copied from the story camera). Drives the device's `videoZoomFactor`; clamped
    /// to the lens's supported range, capped at 8×.
    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let dev = videoDevice else { return }
        if g.state == .began { zoomBase = dev.videoZoomFactor }
        guard g.state == .began || g.state == .changed else { return }
        let maxZ = min(dev.maxAvailableVideoZoomFactor, 8)
        let target = max(dev.minAvailableVideoZoomFactor, min(maxZ, zoomBase * g.scale))
        do { try dev.lockForConfiguration(); dev.videoZoomFactor = target; dev.unlockForConfiguration() }
        catch { }
    }

    private func buildControls() {
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 4
        ring.layer.cornerRadius = 39
        ring.isUserInteractionEnabled = false
        view.addSubview(ring)

        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 30
        // Press model (mirrors the story camera): a quick tap = photo, a held press (≥0.35s) =
        // video. Driven by touch-down/up rather than a tap-vs-longpress recognizer pair, which
        // contended and occasionally produced a 0-second clip.
        shutter.addTarget(self, action: #selector(shutterDown), for: .touchDown)
        shutter.addTarget(self, action: #selector(shutterUp),
                          for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(shutter)

        let flip = button(symbol: "arrow.triangle.2.circlepath.camera", action: #selector(flip))
        let close = button(symbol: "xmark", action: #selector(closeTapped))
        view.addSubview(flip); view.addSubview(close)

        // Swipe left/right anywhere on the preview to flip through filters (full-frame-rate, unlike
        // the thumbnail strip). The strip stays as a tappable menu and follows along.
        let swipeL = UISwipeGestureRecognizer(target: self, action: #selector(swipeFilterLeft))
        swipeL.direction = .left
        let swipeR = UISwipeGestureRecognizer(target: self, action: #selector(swipeFilterRight))
        swipeR.direction = .right
        view.addGestureRecognizer(swipeL); view.addGestureRecognizer(swipeR)

        // Pinch anywhere on the preview to zoom (copied from the story camera).
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))

        filterNameLabel.translatesAutoresizingMaskIntoConstraints = false
        filterNameLabel.textColor = .white
        filterNameLabel.font = .systemFont(ofSize: 15, weight: .bold)
        filterNameLabel.textAlignment = .center
        filterNameLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        filterNameLabel.layer.cornerRadius = 14
        filterNameLabel.layer.masksToBounds = true
        filterNameLabel.alpha = 0
        filterNameLabel.isUserInteractionEnabled = false
        view.addSubview(filterNameLabel)
        NSLayoutConstraint.activate([
            filterNameLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            filterNameLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 70),
            filterNameLabel.heightAnchor.constraint(equalToConstant: 28),
            filterNameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])

        NSLayoutConstraint.activate([
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            shutter.widthAnchor.constraint(equalToConstant: 60),
            shutter.heightAnchor.constraint(equalToConstant: 60),
            ring.centerXAnchor.constraint(equalTo: shutter.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 78),
            ring.heightAnchor.constraint(equalToConstant: 78),
            flip.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            flip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
        ])
    }

    private func button(symbol: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setImage(PlatformImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        b.layer.cornerRadius = 20
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    @objc private func shutterDown() {
        shutterHeld = true
        videoStarted = false
        // Only commit to video once the press has lasted ≥0.35s; a quick release before that is a
        // photo. Because video never starts on a quick tap, we can't produce a 0-second clip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.shutterHeld, !self.videoStarted else { return }
            self.videoStarted = true
            // Set the capture rotation from the CURRENT physical device orientation at record-start —
            // NOT just when `orientationChanged` fires. Recording in portrait without ever rotating the
            // phone previously left the movie connection at its configure-time (often invalid, pre-
            // session-running) angle, so the clip came out sideways. Re-applying here guarantees the
            // file matches how the device is physically held. Front camera is mirrored to match preview.
            if let conn = self.movieOutput.connection(with: .video) {
                let angle = havenPreviewRotationAngle()
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (self.position == .front)
                }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            self.ring.layer.borderColor = UIColor.systemPink.cgColor
        }
    }

    @objc private func shutterUp() {
        let wasHeld = shutterHeld
        shutterHeld = false
        ring.layer.borderColor = UIColor.white.cgColor
        if videoStarted {
            videoStarted = false
            if movieOutput.isRecording { movieOutput.stopRecording() }
        } else if wasHeld {
            // Released before the 0.35s video threshold → it's a photo. Orient the still to the
            // current physical device orientation (same reason as video: don't rely on a rotation
            // notification having fired) so a portrait shot isn't saved sideways.
            if let conn = photoOutput.connection(with: .video) {
                let angle = havenPreviewRotationAngle()
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            }
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    @objc private func flip() {
        position = (position == .back) ? .front : .back
        session.beginConfiguration()
        addCameraInput(position: position)
        session.commitConfiguration()
        configurePreviewConnection()   // front camera mirrors the live preview
    }

    @objc private func swipeFilterLeft() { cycleFilter(to: liveFilter.next) }
    @objc private func swipeFilterRight() { cycleFilter(to: liveFilter.prev) }

    /// Apply a new live filter from a swipe: update the Metal preview, sync the SwiftUI strip, and
    /// flash the filter's name.
    private func cycleFilter(to filter: HavenFilter) {
        liveFilter = filter            // didSet updates the Metal preview
        onFilterChanged?(filter)       // keep the FilterStrip selection in sync
        filterNameLabel.text = "  \(filter.title)  "
        filterNameHide?.cancel()
        UIView.animate(withDuration: 0.15) { self.filterNameLabel.alpha = 1 }
        let hide = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.filterNameLabel.alpha = 0 }
        }
        filterNameHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: hide)
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let img = PlatformImage(data: data) else { return }
        Task { @MainActor in
            let ref = MediaStore.shared.addImage(img)
            finish([ref])
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            let ref = await MediaStore.shared.addVideo(url: url)
            finish([ref])
        }
    }

    @MainActor private func finish(_ refs: [String]) {
        // Hand the fresh capture up to the SwiftUI review layer (filter pick happens there). The
        // controller stays alive behind the review cover so "Retake" returns straight here.
        // Save-to-Photos is deferred to after filtering (see CameraView.onCaptured callers).
        onCaptured?(refs)
    }
}
#endif
