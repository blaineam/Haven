import Foundation

/// The encoder's output targets, split from `VideoEncoder` (AVAssetWriter + the app's image shims) so
/// `MediaOptimizationTarget` — which measures files against them — stays dependency-free and testable.
enum VideoEncoderTargets {
    /// 1080p at this rate is visually fine in a phone feed and roughly a third of a preset export.
    static let videoBitrate = 4_500_000
    /// Transparent for speech, and usually far leaner than the camera's original track.
    static let audioBitrate = 128_000
    /// Target for audio-only files. Speech-friendly and a fraction of an uncompressed source.
    static let standaloneAudioBitrate = 96_000
}
