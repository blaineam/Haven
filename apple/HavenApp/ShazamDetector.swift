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
    ///
    /// HARD CAP, half a second under the catalog's own maximum (12 s). The catalog accepts
    /// 3.0–12.0 s signatures and nothing else; appending whole reader buffers "until 12 s" overshot
    /// to 12.07–12.15 s, and every one of those came back as error 201 —
    /// `SHErrorCode.signatureDurationInvalid` — instantly and deterministically. That is the "50 of
    /// 81 in 0.0s" run: not a rate limit, a signature Shazam refused to look at. `signature(for:)`
    /// clamps the last buffer so `appended` can never exceed this.
    static let maxSampleSeconds: Double = {
        let catalogMax = SHSession().catalog.maximumQuerySignatureDuration
        return catalogMax > 1 ? min(12, catalogMax - 0.5) : 11.5
    }()

    /// Below this there is not enough audio to fingerprint, and asking anyway just returns a
    /// confident-looking nothing. Instagram stories are frequently shorter than this, which is a
    /// large part of why a personal archive matches sparsely.
    static let minimumSeconds: Double = 3

    /// How long to give the catalog before giving up. Successful matches land in about a second;
    /// anything past this is the session having quietly decided not to answer.
    static let matchTimeout: Double = 12

    /// Identify the music in `url`, or nil if there's no audio, no match, or no entitlement.
    ///
    /// Never throws into the import: a failure here means a post without a song credit, which is
    /// exactly what the post had before, so it is not worth interrupting a 300-item run over.
    static func identify(_ url: URL) async -> TrackRefFfi? {
        await identifyDetailed(url).track
    }

    /// Same work, but says WHY it came back empty — and whether asking again could change the answer.
    ///
    /// "no match" and "never ran" are indistinguishable from the outside, and they call for
    /// completely different fixes — one is Shazam telling you the audio isn't in its catalog, the
    /// other is the audio never reaching Shazam at all. A run of no-matches returning in 0.0s is
    /// the second, and this is what tells them apart.
    ///
    /// `retryable` is the ONLY thing the retry queue and the importer should key on: a transient
    /// refusal (202 `matchAttemptFailed`, 500 `internalError`, or a session that never answered)
    /// is worth another try later; "not in catalog", a bad signature (201), or a clip with no usable
    /// audio is an answer, and retrying an answer is just more heat.
    static func identifyDetailed(_ url: URL) async -> (track: TrackRefFfi?, reason: String, retryable: Bool) {
        guard let signature = await signature(for: url) else {
            return (nil, await signatureFailureReason(url), false)
        }
        await Throttle.shared.waitForTurn()
        let session = SHSession()
        // HARD BOUND, enforced here rather than by a caller's timeout.
        //
        // `session.results` is an AsyncSequence that is not guaranteed to yield: when Shazam is
        // unhappy it simply never produces a result, and awaiting it hangs forever. A caller
        // wrapping this in a task group cannot save itself either — a group awaits ALL its children
        // before returning, so cancelling the group does not unblock a child stuck on this. That is
        // exactly how an import came to a complete stop.
        //
        // A continuation with its own timer always resumes, exactly once, whatever the session does.
        let result: SHSession.Result? = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            let watcher = Task {
                for await r in session.results { gate.resume(r); break }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.matchTimeout) {
                gate.resume(nil)
                watcher.cancel()
            }
            session.match(signature)
        }
        switch result {
        case .noMatch:
            await Throttle.shared.succeeded()
            return (nil, "not in catalog", false)
        case .error(let e, _):
            let code = (e as NSError).code
            switch code {
            case 201:
                // SHErrorCode.signatureDurationInvalid: the signature is outside the catalog's 3–12 s
                // window. Deterministic and OUR fault (see maxSampleSeconds) — it was misread as a
                // rate limit for a long time because it returns in 0.0s. Never retry, never widen
                // the throttle: the service was not even asked.
                return (nil, "signature duration invalid (201) — \(e.localizedDescription)", false)
            case 202, 500:
                // matchAttemptFailed / internalError: the catalog was asked and did not answer.
                // Transient — back off and let the queue try again later.
                await Throttle.shared.failed(rateLimited: true)
                return (nil, "shazam refused (\(code)): \(e.localizedDescription)", true)
            default:
                await Throttle.shared.failed(rateLimited: false)
                return (nil, "shazam error (\(code)): \(e.localizedDescription)", false)
            }
        case .none:
            // The session never produced a result inside `matchTimeout` — the classic "quietly
            // decided not to answer". Worth one more try later.
            await Throttle.shared.failed(rateLimited: false)
            return (nil, "no result", true)
        case .match:
            await Throttle.shared.succeeded()
        }
        guard case .match(let m) = result, let item = m.mediaItems.first,
              let title = item.title else { return (nil, "match had no title", false) }
        return (TrackRefFfi(
            catalogId: TrackRefFfi.creditPrefix + (item.appleMusicID ?? item.shazamID ?? title) + "~",
            title: title,
            artist: item.artist ?? "",
            artworkUrl: item.artworkURL?.absoluteString ?? "",
            durationMs: 0), "matched", false)
    }

    /// The scan-ledger outcome for a miss, derived from the reason strings THIS file produces, so
    /// the strings and their meaning live in one place.
    static func ledgerOutcome(reason: String, retryable: Bool) -> ShazamScanOutcome {
        if retryable { return .transient }
        if reason.hasPrefix("not in catalog") || reason.hasPrefix("match had no title") { return .notInCatalog }
        if reason.hasPrefix("no audio track") || reason.hasPrefix("could not read audio") { return .noAudio }
        if reason.hasPrefix("audio only") { return .tooShort }
        if reason.hasPrefix("signature duration invalid") { return .badSignature }
        return .failed
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
            // CLAMP the last buffer to the cap: a whole reader buffer past the limit is what produced
            // 12.07–12.15 s signatures and the deterministic 201 (see maxSampleSeconds).
            let remaining = AVAudioFrameCount(max(0, (maxSampleSeconds - appended) * 44100))
            let frames = min(AVAudioFrameCount(length / MemoryLayout<Float>.size), remaining)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData else { continue }
            buffer.frameLength = frames
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: Int(frames) * MemoryLayout<Float>.size,
                                       destination: channel[0])
            try? generator.append(buffer, at: nil)
            appended += Double(frames) / 44100
        }
        reader.cancelReading()
        let sig = generator.signature()
        // Shazam needs a few seconds of audio; a sub-second stub only produces false negatives.
        return sig.duration >= minimumSeconds ? sig : nil
    }
}

/// Resumes a continuation exactly once, from whichever of two racing paths gets there first.
///
/// Resuming a CheckedContinuation twice is a crash, and both the result handler and the timeout
/// legitimately fire on their own schedules — so the race needs arbitrating rather than assuming.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SHSession.Result?, Never>?

    init(_ continuation: CheckedContinuation<SHSession.Result?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: SHSession.Result?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Paces catalog requests so an import doesn't get itself throttled.
///
/// Shazam is built for a person tapping a button, not a loop asking 372 times as fast as it can. A
/// gap between requests, widening whenever the service actually refuses (202 / 500 / no answer),
/// keeps a long import from talking itself into a throttle. (The "201 on 50 of 81" run that
/// motivated this turned out to be the signature-length bug, not a rate limit — see
/// `maxSampleSeconds` — but the pacing is still right for a loop over hundreds of clips.)
actor ShazamThrottle {
    static let shared = ShazamThrottle()

    private var lastAttempt = Date.distantPast
    private var gap: TimeInterval = 2.0
    private static let minGap: TimeInterval = 2.0
    private static let maxGap: TimeInterval = 30.0

    func waitForTurn() async {
        let due = lastAttempt.addingTimeInterval(gap)
        let wait = due.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastAttempt = Date()
    }

    /// Ease back toward the floor — the service is answering again.
    func succeeded() { gap = max(Self.minGap, gap * 0.7) }

    /// Widen after a refusal. Doubling on a rate limit is the whole point; other failures nudge.
    func failed(rateLimited: Bool) {
        gap = min(Self.maxGap, rateLimited ? gap * 2 : gap * 1.2)
    }
}

private typealias Throttle = ShazamThrottle

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
