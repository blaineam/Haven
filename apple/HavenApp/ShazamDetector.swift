import Foundation
import AVFoundation
import ShazamKit

/// Identify the music already inside a video's audio, so an imported reel can CREDIT its song.
///
/// The Instagram export names no song (see `InstagramArchive`) — but the music itself is right there
/// in the video's audio track, and that is enough to recognise. This turns that audio into a Shazam
/// signature and asks the catalog what it is, which is the only way the real title and artist are
/// recoverable at all.
///
/// **Requires the ShazamKit App Service on the App ID** — enabled in the developer portal, and
/// nothing else. There is NO entitlements-file key for this: adding `com.apple.developer.shazamkit`
/// breaks signing outright ("not found and could not be included in profile"), and the profile never
/// carries the key, so its absence there says nothing about whether the capability is on. Signature
/// generation works regardless; only the catalog query depends on the service.
///
/// Results are CREDIT ONLY: see `TrackRefFfi.creditPrefix`. A detected song must never become a
/// second audio source over the video that already contains it.
enum ShazamDetector {

    /// Sampling the whole clip is wasted work — Shazam matches from a few seconds. This bounds both
    /// the read and the signature, which matters when it runs across a few hundred videos.
    static let maxSampleSeconds: Double = 12

    /// Below this there is not enough audio to fingerprint, and asking anyway just returns a
    /// confident-looking nothing. Instagram stories are frequently shorter than this, which is a
    /// large part of why a personal archive matches sparsely.
    static let minimumSeconds: Double = 3

    /// Identify the music in `url`, or nil if there's no audio, no match, or no entitlement.
    ///
    /// Never throws into the import: a failure here means a post without a song credit, which is
    /// exactly what the post had before, so it is not worth interrupting a 300-item run over.
    static func identify(_ url: URL) async -> TrackRefFfi? {
        await identifyDetailed(url).track
    }

    /// Same work, but says WHY it came back empty.
    ///
    /// "no match" and "never ran" are indistinguishable from the outside, and they call for
    /// completely different fixes — one is Shazam telling you the audio isn't in its catalog, the
    /// other is the audio never reaching Shazam at all. A run of no-matches returning in 0.0s is
    /// the second, and this is what tells them apart.
    static func identifyDetailed(_ url: URL) async -> (track: TrackRefFfi?, reason: String) {
        guard let signature = await signature(for: url) else {
            return (nil, await signatureFailureReason(url))
        }
        let session = SHSession()
        // `results` is an AsyncSequence property on the modern SDK; `match` feeds it. (There is no
        // `results(from:)` — that shape does not compile.)
        async let first: SHSession.Result? = {
            for await r in session.results { return r }
            return nil
        }()
        session.match(signature)
        let result = await first
        switch result {
        case .noMatch:            return (nil, "not in catalog")
        case .error(let e, _):    return (nil, "shazam error: \(e.localizedDescription)")
        case .none:               return (nil, "no result")
        case .match: break
        }
        guard case .match(let m) = result, let item = m.mediaItems.first,
              let title = item.title else { return (nil, "match had no title") }
        return (TrackRefFfi(
            catalogId: TrackRefFfi.creditPrefix + (item.appleMusicID ?? item.shazamID ?? title) + "~",
            title: title,
            artist: item.artist ?? "",
            artworkUrl: item.artworkURL?.absoluteString ?? "",
            durationMs: 0), "matched")
    }

    /// Why `signature(for:)` gave up — checked only on failure, so it costs nothing in the normal
    /// case. These are the guards that return instantly, which is exactly the 0.0s symptom.
    private static func signatureFailureReason(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return "no audio track"
        }
        let seconds = (try? await track.load(.timeRange).duration.seconds) ?? 0
        if seconds < minimumSeconds { return String(format: "audio only %.1fs (need %.0fs)", seconds, minimumSeconds) }
        return "could not read audio"
    }

    /// Build a Shazam signature from the first `maxSampleSeconds` of the file's audio.
    private static func signature(for url: URL) async -> SHSignature? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let generator = SHSignatureGenerator()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                         channels: 1, interleaved: false) else { return nil }
        var appended: Double = 0
        while appended < maxSampleSeconds, let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = AVAudioFrameCount(length / MemoryLayout<Float>.size)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData else { continue }
            buffer.frameLength = frames
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: channel[0])
            try? generator.append(buffer, at: nil)
            appended += Double(frames) / 44100
        }
        reader.cancelReading()
        let sig = generator.signature()
        // Shazam needs a few seconds of audio; a sub-second stub only produces false negatives.
        return sig.duration >= minimumSeconds ? sig : nil
    }
}

extension TrackRefFfi {
    /// Marks a track as CREDIT ONLY — "this is what's playing in the video", not "play this".
    ///
    /// Encoded in `catalogId` rather than added as a new field because `TrackRef` already syncs to
    /// Android and desktop untouched: the credit chip therefore appears for every member on every
    /// platform with no protocol change, and `title`/`artist` (which is all the chip draws) are
    /// separate fields that stay clean.
    ///
    /// The alternative — setting the normal `music` slot — makes `AudioCoordinator` silence the
    /// video and stream the song instead, i.e. replacing the real audio with a copy of itself.
    static var creditPrefix: String { "credit:" }

    var isCreditOnly: Bool { catalogId.hasPrefix(Self.creditPrefix) }

    /// The id with the credit marker removed, for opening the song in Apple Music.
    var creditFreeCatalogId: String {
        isCreditOnly ? String(catalogId.dropFirst(Self.creditPrefix.count)) : catalogId
    }
}
