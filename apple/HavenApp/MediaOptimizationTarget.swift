import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// What "already optimized" looks like, and how to tell by LOOKING at a file.
///
/// Today's encoder rewrite gave the posting path an explicit target (see `VideoEncoder`): 1080p
/// H.264 @ 4.5 Mbps, stills at 1600px JPEG q0.62, audio AAC 96k. Everything shared before that —
/// and anything shared at any time with auto-optimize OFF — went out at whatever the camera or the
/// sender's file happened to be. A real device is sitting on 53 items / 1.3 GB with single videos at
/// 320 MB, all from the old path. This is the predicate the "re-optimize" run uses to find them.
///
/// Deliberately dependency-free (AVFoundation/ImageIO/Foundation only — no MediaStore, no FeedStore,
/// no SwiftUI), for the same reason `VideoEncoder` is: it can be compiled and RUN standalone with
/// `swiftc` against real files in haven-media before it is trusted to decide what gets rewritten.
/// The last encoder that skipped that step was wired into the posting path unrun and deadlocked on
/// every clip with audio.
enum MediaOptimizationTarget {

    // MARK: - The targets
    //
    // Stills live here rather than in MediaStore so the probe and the producer cannot drift:
    // MediaStore.optimizedImageMaxDimension/Quality alias these. Video targets come straight from
    // `VideoEncoder`, which is the thing that actually emits them.

    static let imageMaxDimension: CGFloat = 1600
    static let imageQuality: CGFloat = 0.62
    static let videoMaxDimension: CGFloat = 1920

    // MARK: - Where "legacy" starts
    //
    // 2026-07-20 08:00 America/Los_Angeles: the moment the bitrate-controlled encoder landed in the
    // posting path. Anything created before this instant CANNOT have come from it.
    //
    // Built from components rather than a magic epoch number so the intent survives being read, and
    // pinned to the wall clock of the machine the change was made on — the cutoff is a fact about
    // this repository's history, not about the reader's time zone.
    static let legacyCutoff: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 20; c.hour = 8; c.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        return cal.date(from: c) ?? Date(timeIntervalSince1970: 1_784_559_600)   // == 2026-07-20 15:00Z
    }()

    /// Was this posted before the encoder rewrite?
    static func isLegacyByAge(createdAtMs: UInt64) -> Bool {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000) < legacyCutoff
    }

    // MARK: - Tolerances
    //
    // `AVVideoAverageBitRateKey` is a target the encoder averages towards, not a ceiling — a
    // high-motion clip legitimately overshoots, and the container adds its own overhead on top. If
    // the probe's threshold sat at the nominal rate, our OWN freshly-encoded output would come back
    // reading "above target" and the button would offer the same clip forever, re-encoding it on
    // every run. The headroom below is what makes a second pass a no-op, and it is measured, not
    // guessed: real encoder output lands around 4.5–5.0 Mbps overall against a 6.0 Mbps trigger.
    static let videoBitrateCeiling = Int(Double(VideoEncoder.videoBitrate + VideoEncoder.audioBitrate) * 1.30)
    /// Same idea for stills: JPEG q0.62 at 1600px measures well under 0.40 bytes per pixel.
    static let imageBytesPerPixelCeiling: Double = 0.40
    static let audioBitrateCeiling = Int(Double(VideoEncoder.standaloneAudioBitrate) * 1.60)
    /// Dimensions get 2% slack purely for even-number rounding in the encoder.
    static let dimensionSlack: CGFloat = 1.02

    /// Below this there is nothing worth winning, and a re-share costs every member in the circle an
    /// edit event plus a re-download. Small files are left exactly as they are.
    static let minimumInterestingBytes: Int64 = 200_000

    /// A re-encode that doesn't clearly win is worse than no re-encode: the whole circle re-downloads
    /// for nothing. The new bytes must be at least this much smaller to be adopted.
    static let requiredShrinkFactor: Double = 0.90

    // MARK: - The probe

    struct Shape: Sendable {
        var bytes: Int64
        /// Longest edge in pixels (0 for audio).
        var maxDimension: Int
        /// Container/codec four-char code as text ("avc1", "hvc1", "aac ") or an ImageIO UTI for stills.
        var codec: String
        /// Overall bits/second (0 for stills).
        var bitrate: Int
        var seconds: Double
        /// Nil when the file reads as already-at-target; otherwise WHY it is being rewritten.
        var aboveTargetReason: String?

        var aboveTarget: Bool { aboveTargetReason != nil }
        var summary: String {
            let mb = String(format: "%.1f", Double(bytes) / 1_048_576)
            if bitrate > 0 {
                return "\(mb) MB · \(codec) · \(maxDimension)px · \(bitrate / 1000) kbps"
            }
            return maxDimension > 0 ? "\(mb) MB · \(codec) · \(maxDimension)px" : "\(mb) MB · \(codec)"
        }
    }

    /// Inspect a stored blob. Kind comes from the FILE EXTENSION because that is what `MediaStore`
    /// guarantees on disk (`<ref>.jpg` / `.mp4` / `.m4a`) — and because deriving it here rather than
    /// taking a `MediaKind` parameter is what keeps this file free of any app dependency.
    ///
    /// Returns nil when the file cannot be read or judged at all; the caller leaves such blobs alone
    /// rather than guessing (fail closed — an unreadable file is not a re-encode candidate).
    static func probe(_ url: URL) async -> Shape? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              bytes > 0 else { return nil }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic":  return probeImage(url, bytes: Int64(bytes))
        case "mp4", "mov", "m4v":           return await probeVideo(url, bytes: Int64(bytes))
        case "m4a", "wav", "aiff", "caf", "mp3": return await probeAudio(url, bytes: Int64(bytes))
        default:                            return nil
        }
    }

    // MARK: Stills
    //
    // Two tells, and both matter. DIMENSIONS catch the obvious case — a 4032px camera original that
    // never went through the downscale. BYTES-PER-PIXEL catch the subtler one: a photo that IS
    // 1600px but was written at q0.95 (auto-optimize off) or arrived as a PNG/HEIC screenshot, where
    // the pixel count says nothing and only the density gives it away.
    private static func probeImage(_ url: URL, bytes: Int64) -> Shape? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let type = (CGImageSourceGetType(src) as String?) ?? "unknown"
        let maxDim = max(w, h)
        let bpp = Double(bytes) / Double(w * h)
        var shape = Shape(bytes: bytes, maxDimension: maxDim, codec: shortType(type),
                          bitrate: 0, seconds: 0, aboveTargetReason: nil)
        guard bytes >= minimumInterestingBytes else { return shape }
        if !type.hasSuffix("jpeg") {
            // The optimized path ALWAYS writes JPEG. Anything else here came in verbatim.
            shape.aboveTargetReason = "not a JPEG (\(shape.codec))"
        } else if CGFloat(maxDim) > imageMaxDimension * dimensionSlack {
            shape.aboveTargetReason = "\(maxDim)px, target \(Int(imageMaxDimension))px"
        } else if bpp > imageBytesPerPixelCeiling {
            shape.aboveTargetReason = String(format: "%.2f bytes/pixel, target ≤ %.2f",
                                             bpp, imageBytesPerPixelCeiling)
        }
        return shape
    }

    // MARK: Video
    //
    // CODEC is the strongest tell there is: the optimized path emits H.264 and nothing else (see
    // VideoEncoder — AVVideoCodecKey is hard-coded, because Android cannot be relied on to decode
    // HEVC). So an `hvc1`/`hev1` track is positive proof the file came from the passthrough remux or
    // the raw-copy fallback, i.e. auto-optimize was off or every export failed. Dimensions and
    // bitrate then catch H.264 files that came from the old preset export, which capped size but
    // picked its own ~8 Mbps rate.
    //
    // Bitrate is computed from FILE BYTES ÷ DURATION rather than `estimatedDataRate`, because that
    // is the number that actually costs the circle storage and transfer, container overhead and all.
    private static func probeVideo(_ url: URL, bytes: Int64) async -> Shape? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let xf = try? await track.load(.preferredTransform),
              let dur = try? await asset.load(.duration) else { return nil }
        let seconds = dur.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        let disp = natural.applying(xf)
        let maxDim = Int(max(abs(disp.width), abs(disp.height)).rounded())
        var codec = "unknown"
        if let fd = (try? await track.load(.formatDescriptions))?.first {
            codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
        }
        let bitrate = Int(Double(bytes) * 8 / seconds)
        var shape = Shape(bytes: bytes, maxDimension: maxDim, codec: codec,
                          bitrate: bitrate, seconds: seconds, aboveTargetReason: nil)
        guard bytes >= minimumInterestingBytes else { return shape }
        if codec != "avc1" {
            shape.aboveTargetReason = "\(codec), not H.264"
        } else if CGFloat(maxDim) > videoMaxDimension * dimensionSlack {
            shape.aboveTargetReason = "\(maxDim)px, target \(Int(videoMaxDimension))px"
        } else if bitrate > videoBitrateCeiling {
            shape.aboveTargetReason = "\(bitrate / 1000) kbps, target ≤ \(videoBitrateCeiling / 1000) kbps"
        }
        return shape
    }

    // MARK: Audio
    //
    // `addAudio` was a straight `copyItem` until today, so anything shared IN could be WAV/AIFF/ALAC
    // — uncompressed speech at tens of megabytes. Non-AAC is the tell; a fat AAC is caught on rate.
    private static func probeAudio(_ url: URL, bytes: Int64) async -> Shape? {
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first,
              let dur = try? await asset.load(.duration) else { return nil }
        let seconds = dur.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        var codec = "unknown"
        if let fd = (try? await track.load(.formatDescriptions))?.first {
            codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
        }
        let bitrate = Int(Double(bytes) * 8 / seconds)
        var shape = Shape(bytes: bytes, maxDimension: 0, codec: codec,
                          bitrate: bitrate, seconds: seconds, aboveTargetReason: nil)
        guard bytes >= minimumInterestingBytes else { return shape }
        // 'aac ' is the plain AAC-LC subtype; the AAC family shares the "aac" stem.
        if !codec.hasPrefix("aac") {
            shape.aboveTargetReason = "\(codec), not AAC"
        } else if bitrate > audioBitrateCeiling {
            shape.aboveTargetReason = "\(bitrate / 1000) kbps, target ≤ \(audioBitrateCeiling / 1000) kbps"
        }
        return shape
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
    /// "public.jpeg" → "jpeg", so the reason strings stay readable.
    private static func shortType(_ uti: String) -> String {
        uti.split(separator: ".").last.map(String.init) ?? uti
    }
}
