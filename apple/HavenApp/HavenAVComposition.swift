import AVFoundation

/// Sync helpers for building video-only compositions.
///
/// AVFoundation's modern `loadTracks` / `load(.duration)` APIs are async-only. Several call sites
/// (story viewer, looping preview) still need a synchronous composition for an already-on-disk
/// URL. This file is the single home for the legacy track accessors so deprecation noise stays
/// contained (and can be rewritten once those call sites go fully async).
enum HavenAVComposition {
    /// Copy only the video track of `asset` into a new composition (no audio).
    static func videoOnly(from asset: AVAsset) -> AVAsset? {
        let comp = AVMutableComposition()
        // Intentionally use the pre-iOS-16 sync accessors — see file header.
        let tracks = asset.tracks(withMediaType: .video)
        guard let vTrack = tracks.first,
              let cTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let duration = asset.duration
        let transform = vTrack.preferredTransform
        do {
            try cTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       of: vTrack, at: .zero)
        } catch { return nil }
        cTrack.preferredTransform = transform
        return comp
    }
}
