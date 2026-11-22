import Foundation

/// The encoder's output targets, split from `VideoEncoder` (AVAssetWriter + the app's image shims) so
/// `MediaOptimizationTarget` — which measures files against them — stays dependency-free and testable.
enum VideoEncoderTargets {
    /// 1080p H.264, SDR. With the audio below this is 2.53 Mbps overall: the longest clip allowed
    /// (15 minutes) comes to about 285 MB, under the 300 MB the owner set as the most a video may
    /// cost a circle, and a few seconds comes to a megabyte or two. It was 4.5 Mbps (520 MB for
    /// the same clip) until 2.2.2.
    static let videoBitrate = 2_400_000
    /// What a finished video may measure overall, audio and container included: bytes × 8 ÷
    /// seconds. 2.65 Mbps is 298 MB for fifteen minutes. `VideoEncoder.encode` encodes again until
    /// its output is under this.
    static let overallCeiling = 2_650_000
    /// VideoToolbox `DataRateLimits` (`[bytes, seconds]`) for an encode aiming at `bitrate`: at
    /// most 10% over it in any three seconds.
    static func dataRateLimits(for bitrate: Int) -> [Int] { [bitrate / 8 * 3 * 11 / 10, 3] }
    /// Transparent for speech, and usually far leaner than the camera's original track.
    static let audioBitrate = 128_000
    /// Target for audio-only files. Speech-friendly and a fraction of an uncompressed source.
    static let standaloneAudioBitrate = 96_000
}
