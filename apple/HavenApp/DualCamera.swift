import SwiftUI
import AVFoundation
import CoreImage

/// Which corner the front-facing ("your expression") view is composited into.
enum PiPCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top-left"
        case .topRight: return "Top-right"
        case .bottomLeft: return "Bottom-left"
        case .bottomRight: return "Bottom-right"
        }
    }
    var icon: String {
        switch self {
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        }
    }
}

#if !os(macOS)

/// Records the back + front cameras simultaneously (`AVCaptureMultiCamSession`) and encodes the
/// **front** camera as a picture-in-picture in a chosen corner of the **back** footage — so the
/// user can capture their reaction alongside what they're filming. Compositing is per-frame with
/// Core Image into an `AVAssetWriter`. Requires a multi-cam-capable device (iPhone XS+); callers
/// check `DualCameraRecorder.isSupported` and fall back to the single camera.
///
/// Not `@MainActor`: the capture delegates run on `queue`, so all writer/compositing state is
/// touched only there; the few `@Published` UI fields are bounced to the main thread.
final class DualCameraRecorder: NSObject, ObservableObject {
    static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    let session = AVCaptureMultiCamSession()
    @Published var isRecording = false
    @Published var recordingSeconds = 0.0
    /// Read on `queue`; set from the UI before recording starts.
    var corner: PiPCorner = .bottomRight

    let backLayer = AVCaptureVideoPreviewLayer()
    let frontLayer = AVCaptureVideoPreviewLayer()

    private let backOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "haven.dualcam")
    private let ciContext = CIContext()
    private let canvas = CGSize(width: 1080, height: 1920)   // portrait

    // Capture-queue-only state.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writing = false
    private var sessionStarted = false
    private var latestFront: CVPixelBuffer?
    private var capSeconds = StoryCaptureModel.maxTotal
    private var onVideo: ((URL) -> Void)?

    private var recordTimer: Timer?

    func start() {
        guard Self.isSupported else { return }
        havenCaptureOwnsAudioSession = true   // camera owns the audio route; post music stays silent
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        queue.async { [weak self] in self?.configure() }
    }

    func stop() {
        havenCaptureOwnsAudioSession = false   // release the audio route back to playback
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            // Fully tear the multi-cam session down so BOTH camera devices are released and the iOS
            // "in use" (green) indicator goes off. With no-connection inputs/outputs we must also
            // remove the connections we added.
            self.session.beginConfiguration()
            for conn in self.session.connections { self.session.removeConnection(conn) }
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
        }
    }

    private func configure() {
        session.beginConfiguration()
        addCamera(.back, output: backOutput, preview: backLayer)
        addCamera(.front, output: frontOutput, preview: frontLayer)
        if let mic = AVCaptureDevice.default(for: .audio),
           let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                audioOutput.setSampleBufferDelegate(self, queue: queue)
            }
        }
        backLayer.videoGravity = .resizeAspectFill
        frontLayer.videoGravity = .resizeAspectFill
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }

    private func addCamera(_ pos: AVCaptureDevice.Position, output: AVCaptureVideoDataOutput,
                           preview: AVCaptureVideoPreviewLayer) {
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input),
              session.canAddOutput(output) else { return }
        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(output)
        output.setSampleBufferDelegate(self, queue: queue)
        guard let port = input.ports(for: .video, sourceDeviceType: dev.deviceType, sourceDevicePosition: pos).first
        else { return }
        let conn = AVCaptureConnection(inputPorts: [port], output: output)
        if session.canAddConnection(conn) { session.addConnection(conn) }
        let pl = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
        if session.canAddConnection(pl) { session.addConnection(pl) }
    }

    func startRecording(maxSeconds: Double, _ completion: @escaping (URL) -> Void) {
        guard !isRecording, maxSeconds > 0.3 else { return }
        onVideo = completion
        recordingSeconds = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story_dual_\(UUID().uuidString).mov")
        queue.async { [weak self] in
            self?.capSeconds = maxSeconds
            self?.setupWriter(url: url)
            self?.writing = true
        }
        isRecording = true
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds += 0.1
            if self.recordingSeconds >= maxSeconds { self.stopRecording() }
        }
    }

    func stopRecording() {
        recordTimer?.invalidate(); recordTimer = nil
        guard isRecording else { return }
        isRecording = false
        queue.async { [weak self] in
            guard let self, self.writing, let writer = self.writer else { return }
            self.writing = false
            self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
            let url = writer.outputURL
            writer.finishWriting {
                self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
                self.sessionStarted = false
                let cb = self.onVideo
                DispatchQueue.main.async { cb?(url) }
            }
        }
    }

    private func setupWriter(url: URL) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width, AVVideoHeightKey: canvas.height,
        ])
        vInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.width,
            kCVPixelBufferHeightKey as String: canvas.height,
        ])
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 96000,
        ])
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) { writer.add(vInput) }
        if writer.canAdd(aInput) { writer.add(aInput) }
        writer.startWriting()
        self.writer = writer; self.videoInput = vInput; self.audioInput = aInput; self.adaptor = adaptor
    }

    /// Composite the back frame (full) with the latest front frame (PiP in `corner`).
    private func composite(back: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var backImg = CIImage(cvPixelBuffer: back)
        let bScale = max(canvas.width / backImg.extent.width, canvas.height / backImg.extent.height)
        backImg = backImg.transformed(by: CGAffineTransform(scaleX: bScale, y: bScale))
        backImg = backImg.cropped(to: CGRect(origin: .zero, size: canvas))

        var out = backImg
        if let front = latestFront {
            let f = CIImage(cvPixelBuffer: front)
            let pipW = canvas.width * 0.3, pipH = canvas.height * 0.3
            let s = max(pipW / f.extent.width, pipH / f.extent.height)
            let scaled = f.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let cropped = scaled.cropped(to: CGRect(x: scaled.extent.minX, y: scaled.extent.minY, width: pipW, height: pipH))
            let m: CGFloat = 36
            let x: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? m : canvas.width - pipW - m
            let y: CGFloat = (corner == .bottomLeft || corner == .bottomRight) ? m : canvas.height - pipH - m
            let placed = cropped.transformed(by: CGAffineTransform(translationX: x - cropped.extent.minX,
                                                                   y: y - cropped.extent.minY))
            out = placed.composited(over: backImg)
        }

        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { return nil }
        ciContext.render(out, to: buffer)
        return buffer
    }
}

extension DualCameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Already on `queue` (the delegate queue) — touch capture state directly.
        if output === audioOutput {
            guard writing, sessionStarted, let a = audioInput, a.isReadyForMoreMediaData else { return }
            a.append(sampleBuffer)
            return
        }
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if output === frontOutput { latestFront = px; return }
        // Back frame drives the timeline + compositing.
        guard writing, let writer = writer, let adaptor = adaptor, let v = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted { writer.startSession(atSourceTime: pts); sessionStarted = true }
        guard v.isReadyForMoreMediaData, let composed = composite(back: px) else { return }
        adaptor.append(composed, withPresentationTime: pts)
    }
}

/// Live preview of the dual-camera session: back full-screen with the front PiP in the chosen corner.
struct DualCameraPreview: UIViewRepresentable {
    let recorder: DualCameraRecorder
    let corner: PiPCorner

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        recorder.backLayer.frame = v.bounds
        recorder.frontLayer.cornerRadius = 14
        recorder.frontLayer.masksToBounds = true
        v.layer.addSublayer(recorder.backLayer)
        v.layer.addSublayer(recorder.frontLayer)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {
        recorder.backLayer.frame = v.bounds
        let w = v.bounds.width * 0.3, h = v.bounds.height * 0.3, m: CGFloat = 16
        let x = (corner == .topLeft || corner == .bottomLeft) ? m : v.bounds.width - w - m
        let y = (corner == .topLeft || corner == .topRight) ? m : v.bounds.height - h - m
        recorder.frontLayer.frame = CGRect(x: x, y: y, width: w, height: h)
    }
}

#endif

#if os(macOS)

/// macOS stub: `AVCaptureMultiCamSession` (dual-camera PiP capture) does not exist on macOS.
/// Mirrors the iOS `DualCameraRecorder` public surface read elsewhere in the app, as inert defaults.
final class DualCameraRecorder: NSObject, ObservableObject {
    static var isSupported: Bool { false }

    @Published var isRecording = false
    @Published var recordingSeconds = 0.0
    /// Set from the UI before recording starts; inert on macOS.
    var corner: PiPCorner = .bottomRight

    func start() {}
    func stop() {}
    func startRecording(maxSeconds: Double, _ completion: @escaping (URL) -> Void) {}
    func stopRecording() {}
}

/// macOS stub preview: renders a dark placeholder since there is no live dual-camera session.
struct DualCameraPreview: View {
    let recorder: DualCameraRecorder
    let corner: PiPCorner

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
    }
}

#endif
