import AVFoundation
import CoreImage

/// Re-encode a video to a network-friendly H.264 MP4 at an EXPLICIT bitrate.
///
/// Lives in its own file, free of any MediaStore/app dependency, so it can be compiled and RUN
/// standalone against a real video before it goes anywhere near the posting path. The first version
/// of this shipped unrun and deadlocked on every clip with an audio track — see `pump` below.
///
/// Why not `AVAssetExportSession`: its presets cap DIMENSIONS and then choose their own bitrate,
/// roughly 8 Mbps at 1080p. That is an archival setting applied to something meant to cross a
/// network, and it is why "auto-optimize" produced 320 MB clips. There is no API to ask a preset for
/// a bitrate, so targeting a size means driving `AVAssetWriter` directly.
enum VideoEncoder {

    /// 1080p at this rate is visually fine in a phone feed and roughly a third of a preset export.
    static let videoBitrate = 4_500_000
    /// Transparent for speech, and usually far leaner than the camera's original track.
    static let audioBitrate = 128_000

    /// Encode `src` to `dst`. Returns false on any failure — callers must keep a fallback path, so a
    /// video this cannot handle is still shareable rather than lost.
    static func encode(_ src: URL, to dst: URL, maxDimension: CGFloat = 1920) async -> Bool {
        try? FileManager.default.removeItem(at: dst)
        let asset = AVURLAsset(url: src)
        guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await vTrack.load(.naturalSize),
              let xf = try? await vTrack.load(.preferredTransform),
              let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: dst, fileType: .mp4)
        else { return false }

        // Display-oriented size, fitted in the box, even dimensions (H.264 requires even).
        let disp = natural.applying(xf)
        let dw = abs(disp.width), dh = abs(disp.height)
        guard dw > 0, dh > 0 else { return false }
        let fit = min(1, maxDimension / max(dw, dh))
        func even(_ v: CGFloat) -> CGFloat {
            let n = (v * fit).rounded(.down)
            return max(2, n - n.truncatingRemainder(dividingBy: 2))
        }
        let outW = even(dw), outH = even(dh)

        // BAKE the rotation into the pixels. Android ignores the transform tag, so a portrait iPhone
        // clip would arrive sideways; the composition renders each frame already display-oriented.
        let comp = AVMutableVideoComposition(asset: asset) { request in
            let img = request.sourceImage
            let s = min(outW / img.extent.width, outH / img.extent.height)
            request.finish(with: img.transformed(by: CGAffineTransform(scaleX: s, y: s)), context: nil)
        }
        comp.renderSize = CGSize(width: outW, height: outH)

        let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !vTracks.isEmpty else { return false }
        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: vTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = comp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { return false }
        reader.add(vOut)

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,          // H.264, not HEVC — Android decodes it
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,       // the whole point: an explicit rate
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
            ],
        ])
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { return false }
        writer.add(vIn)

        var aOut: AVAssetReaderTrackOutput?
        var aIn: AVAssetWriterInput?
        if let aTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            o.alwaysCopiesSampleData = false
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitrate,
            ])
            i.expectsMediaDataInRealTime = false
            if reader.canAdd(o), writer.canAdd(i) { reader.add(o); writer.add(i); aOut = o; aIn = i }
        }

        writer.shouldOptimizeForNetworkUse = true   // moov atom first → playback starts while streaming
        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        // BOTH tracks are pumped CONCURRENTLY, and that is not a nicety.
        //
        // AVAssetReader interleaves its outputs from one underlying read. Draining video to
        // completion while never touching audio blocks the reader as soon as its audio buffer fills —
        // the video pump then never finishes, its continuation never resumes, and the caller hangs
        // forever. Sequential pumping is exactly that bug, and it took out recording and attaching
        // entirely for any clip with sound, which is all of them.
        async let video: Void = pump(vIn, vOut, reader: reader, label: "video")
        if let aIn, let aOut {
            async let audio: Void = pump(aIn, aOut, reader: reader, label: "audio")
            _ = await (video, audio)
        } else {
            await video
        }

        guard reader.status != .failed else { writer.cancelWriting(); return false }
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// Feed one writer input from one reader output until it runs dry.
    ///
    /// `requestMediaDataWhenReady` re-invokes its block whenever the input drains, so the block can
    /// run many times; the continuation must be resumed exactly ONCE or the task traps. Hence the
    /// lock-guarded latch rather than a bare `c.resume()`.
    private static func pump(_ input: AVAssetWriterInput,
                             _ output: AVAssetReaderOutput,
                             reader: AVAssetReader,
                             label: String) async {
        let latch = ResumeOnce()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "haven.encode.\(label)")) {
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let buf = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        latch.fire { c.resume() }
                        return
                    }
                    if !input.append(buf) {
                        input.markAsFinished()
                        latch.fire { c.resume() }
                        return
                    }
                }
                // Input full: return and wait to be called again. Deliberately no resume here.
            }
        }
    }

    /// One-shot latch. `requestMediaDataWhenReady`'s block is re-entrant across queues, so a plain
    /// Bool would race and a double resume is a crash, not a warning.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire(_ body: () -> Void) {
            lock.lock()
            let first = !fired
            fired = true
            lock.unlock()
            if first { body() }
        }
    }
}
