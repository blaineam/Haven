import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if !os(macOS)
/// A live camera QR scanner. Calls `onFound` once with the decoded string, then the
/// caller dismisses. Reads both `https://…/#…` and `haven://invite#…` invite links.
struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onFound = { context.coordinator.handle($0) }
        return vc
    }

    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class Coordinator {
        private let onFound: (String) -> Void
        private var fired = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }
        func handle(_ code: String) {
            guard !fired else { return }
            fired = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFound(code)
        }
    }
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        teardownSession()
    }

    // SwiftUI dismissing the sheet hosting this controller may not always route through
    // viewWillDisappear, so also tear the session down on dealloc. Both paths are idempotent.
    deinit { teardownSession() }

    /// Fully stop + release the capture session so the iOS "in use" (green) indicator goes off.
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

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue, !value.isEmpty else { return }
        teardownSession()
        onFound?(value)
    }
}
#endif

#if os(macOS)
import Vision

/// Native macOS live camera QR scanner. The old version used `AVCaptureMetadataOutput` configured for
/// `.qr`, which is unreliable on the Mac webcam (the `.qr` type often never becomes available, so it
/// never detected anything). This version pulls raw frames via `AVCaptureVideoDataOutput` and runs
/// Vision's `VNDetectBarcodesRequest` on each — Vision QR detection is solid on macOS. `onFound` fires
/// exactly once, on the main actor, with the decoded value.
struct QRScannerView: NSViewRepresentable {
    var onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeNSView(context: Context) -> ScannerNSView {
        let v = ScannerNSView()
        v.start(coordinator: context.coordinator)
        return v
    }

    func updateNSView(_ nsView: ScannerNSView, context: Context) {}

    static func dismantleNSView(_ nsView: ScannerNSView, coordinator: Coordinator) {
        nsView.stop()
    }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let onFound: (String) -> Void
        private var fired = false
        weak var view: ScannerNSView?
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !fired, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])
            try? handler.perform([request])
            guard let payload = (request.results?.first)?.payloadStringValue, !payload.isEmpty else { return }
            fired = true
            view?.stop()
            Task { @MainActor in self.onFound(payload) }
        }
    }
}

/// A layer-backed NSView that owns the capture session + preview layer for the QR scanner.
final class ScannerNSView: NSView {
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "haven.qrscanner.session")
    private let frameQueue = DispatchQueue(label: "haven.qrscanner.frames")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start(coordinator: QRScannerView.Coordinator) {
        coordinator.view = self
        havenCameraUIOpen += 1   // a viewfinder is up — post music stays silent behind it
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.sessionQueue.async { self.configure(coordinator: coordinator) }
        }
    }

    private func configure(coordinator: QRScannerView.Coordinator) {
        session.beginConfiguration()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        output.setSampleBufferDelegate(coordinator, queue: frameQueue)
        session.addOutput(output)
        session.commitConfiguration()

        Task { @MainActor in
            let layer = AVCaptureVideoPreviewLayer(session: self.session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = self.bounds
            self.layer?.addSublayer(layer)
            self.preview = layer
        }

        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        havenCameraUIOpen = max(0, havenCameraUIOpen - 1)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
    }

    override func layout() {
        super.layout()
        preview?.frame = bounds
    }
}
#endif
