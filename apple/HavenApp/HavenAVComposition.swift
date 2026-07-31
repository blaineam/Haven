import AVFoundation

/// Builds a video-only composition — the clip's picture with its audio track REMOVED.
///
/// Why removal and not muting: a player that still owns an audio track joins the audio session, so
/// starting the music player interrupts it and resuming it interrupts the song right back. The two
/// ping-pong about half a second apart, which is the "story plays for a moment then self-pauses"
/// behaviour. A composition with no audio track can neither interrupt nor be interrupted.
///
/// ASYNC, because the modern AVFoundation track accessors are: `loadTracks`, `load(.duration)` and
/// `load(.preferredTransform)` replaced sync properties deprecated since iOS 16 / macOS 13. The
/// callers stayed synchronous for a long time and this file existed to keep the deprecation noise in
/// one place; it now does the loading properly instead.
///
/// Callers do NOT await this per player item — `AVPlayerLooper` needs its template item
/// synchronously, and the story camera rebuilds items from a sync mute toggle. Resolve ONCE when the
/// asset is loaded, hold the result, and hand it to those sites. `nil` means "couldn't build one",
/// and every caller falls back to the original asset (muted), which is the pre-existing behaviour.
enum HavenAVComposition {
    /// Copy only the video track of `asset` into a new composition (no audio).
    static func videoOnly(from asset: AVAsset) async -> AVAsset? {
        let comp = AVMutableComposition()
        guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first ?? nil,
              let cTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        guard let duration = try? await asset.load(.duration),
              let transform = try? await vTrack.load(.preferredTransform)
        else { return nil }
        do {
            try cTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       of: vTrack, at: .zero)
        } catch { return nil }
        cTrack.preferredTransform = transform
        return comp
    }
}
