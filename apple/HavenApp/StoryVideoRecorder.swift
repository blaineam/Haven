import AVFoundation
import CoreImage
import CoreMedia

/// Records the LIVE camera frames to a file via `AVAssetWriter` — the single-video-path replacement for
/// `AVCaptureMovieFileOutput`. Running a movie file output AND the live-preview `AVCaptureVideoDataOutput`
/// on the same session is exactly the configuration iOS truncates/interrupts recordings on (the "records
/// only ~0-1s" bug). Here the recording is driven from the SAME `LiveFrameTap` frame stream that feeds the
/// Metal preview, so what you record is exactly what you see — the chosen filter is baked in — and there
/// is no second video output to conflict. Audio comes from an `AVCaptureAudioDataOutput`.
///
/// All append/finish calls arrive on the camera's serial queue (the data outputs share it), so the writer
/// is only ever touched from one thread; the lock guards the cross-thread `begin`/`finish`/flag reads.
final class StoryVideoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false            // startSession(atSourceTime:) issued (first video frame seen)
    private var startPTS = CMTime.invalid
    private var outURL: URL?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private(set) var isRecording = false

    /// The look to bake into the recording + how to orient each frame upright — set by the camera before
    /// `begin` (and kept in sync as the live filter changes).
    var filterSpec: FilterSpec = HavenFilter.original.spec
    var orientation: CGImagePropertyOrientation = .right

    /// Start a new clip at `url`. Inputs are sized lazily from the first frame (so the recording matches
    /// whatever the sensor + orientation produce). Returns false if the writer couldn't be created.
    @discardableResult
    func begin(to url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        writer = w; outURL = url
        videoInput = nil; audioInput = nil; adaptor = nil
        started = false; startPTS = .invalid; isRecording = true
        return true
    }

    /// Append one live frame (already the raw sensor CIImage). Orients + filters it so the recording is
    /// WYSIWYG with the preview, then renders into a pooled pixel buffer and appends at the frame's PTS.
    func appendVideo(_ raw: CIImage, pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let writer else { return }
        // Orient upright (like the preview), bake the filter, and translate the extent to the origin so
        // the pixel buffer (origin 0) captures the whole frame rather than an offset crop.
        let oriented = raw.oriented(orientation)
        let filtered = FilterEngine.apply(filterSpec, to: oriented)
        let extent = filtered.extent
        guard extent.width >= 1, extent.height >= 1 else { return }
        let atOrigin = filtered.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))

        if videoInput == nil {
            let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
            let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            ])
            vin.expectsMediaDataInRealTime = true
            let adap = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100, AVEncoderBitRateKey: 96_000,
            ])
            ain.expectsMediaDataInRealTime = true
            if writer.canAdd(vin) { writer.add(vin) }
            if writer.canAdd(ain) { writer.add(ain) }
            videoInput = vin; adaptor = adap; audioInput = ain
            writer.startWriting()
        }
        if !started {
            writer.startSession(atSourceTime: pts)
            startPTS = pts; started = true
        }
        guard let adaptor, let vin = videoInput, vin.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else { return }
        ciContext.render(atOrigin, to: buffer,
                         bounds: CGRect(origin: .zero, size: extent.size), colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(buffer, withPresentationTime: pts)
    }

    /// Append one audio sample buffer — only after the video session has started AND the sample sits at or
    /// past the session start, or the writer rejects it.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, started, let ain = audioInput, ain.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, startPTS.isValid, CMTimeCompare(pts, startPTS) >= 0 else { return }
        ain.append(sampleBuffer)
    }

    /// Finish the clip and return its URL (nil if nothing usable was written). Resets for the next segment.
    func finish() async -> URL? {
        // NSLock must not be held across `await` (Swift 6). Snapshot under the lock, then finishWriting.
        enum Snapshot {
            case empty
            case ready(writer: AVAssetWriter, url: URL)
        }
        let snap: Snapshot = withLock {
            guard isRecording, let writer, let url = outURL, started else {
                self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
                self.isRecording = false; self.started = false
                return .empty
            }
            isRecording = false
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let w = writer
            return .ready(writer: w, url: url)
        }
        guard case .ready(let w, let url) = snap else { return nil }

        await w.finishWriting()
        let ok = (w.status == .completed)

        withLock {
            self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil; self.started = false
        }
        return ok ? url : nil
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
