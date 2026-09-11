import Foundation

/// Who gets the speakers inside the full-screen media viewer.
///
/// Pure data, deliberately: the rule reads as a table rather than as branches threaded through a
/// SwiftUI body, and it is the only part of this feature that can be tested without a device, a
/// music subscription, or an Apple Music catalog round trip. `MediaZoomViewer` fills it in from the
/// live state and reads the three answers back; Android's `MediaViewer` applies the same table in
/// Kotlin (there is no shared layer between the UIs to put it in).
///
/// THE RULE, in the order it was asked for:
///
///   * a post's song keeps playing when you open its photos full screen — the viewer is the same
///     post, bigger, not a sheet covering it;
///   * a video page whose clip carries its OWN audible sound takes the stage, and the song comes
///     back the moment you page off it;
///   * a clip that cannot be heard — a screen recording, a time-lapse, one the author muted — never
///     takes anything from the song;
///   * the music chip mutes the song, the speaker chip mutes the clip, and an explicit tap on the
///     speaker outranks the automatic choice for the rest of the viewer's life;
///   * the app-wide mute and a live call outrank everything.
struct ViewerAudioPolicy {
    /// Is there a song to play at all? False for a credit-only track (which names the music already
    /// inside the video — attribution, not a second source), for media with no post behind it, and
    /// under super data saver, which never streams a song anywhere.
    var hasSong = false
    /// The viewer's own music mute — not the app-wide one.
    var musicMuted = false
    var onVideoPage = false
    /// Probed from the file, not guessed from the extension: "is a video" and "makes sound" are
    /// different questions.
    var clipCarriesAudio = false
    var authorMutedVideo = false
    /// A tap on the speaker chip. Nil until the user taps, so paging decides on its own until then.
    var explicitVideoChoice: Bool?
    /// The persisted, app-wide "video sound is on" choice the feed's speaker writes.
    var globalVideoSoundOn = false
    var appSilent = false
    var callActive = false

    /// Would this page's clip take the stage if sound were on?
    var clipWantsStage: Bool { onVideoPage && clipCarriesAudio && !authorMutedVideo }

    /// Is the clip's own audio wanted on this page? With a song in play the clip takes over
    /// automatically; with no song this is the plain global choice, so a DM video in this viewer
    /// behaves exactly as it did before any of this existed.
    var videoSoundAllowed: Bool {
        if let explicitVideoChoice { return explicitVideoChoice }
        return hasSong ? clipWantsStage : globalVideoSoundOn
    }

    /// May the page's player actually make noise?
    var videoAudible: Bool { videoSoundAllowed && !appSilent && !callActive }

    /// Is the song audible right now — or ducked under a clip that took the stage?
    var musicAudible: Bool {
        hasSong && !musicMuted && !(clipWantsStage && videoAudible) && !appSilent && !callActive
    }

    /// Quiet because a clip is talking over it rather than because anyone muted it. Worth
    /// distinguishing: the chip otherwise reads as "you muted this" when the video simply started.
    var musicDucked: Bool { hasSong && !musicMuted && clipWantsStage && videoAudible }
}
