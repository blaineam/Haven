package com.blaineam.haven.core

/**
 * Who gets the speakers inside the full-screen media viewer.
 *
 * The Kotlin twin of Apple's `ViewerAudioPolicy` — same field names, same rule, tested against the
 * same table — because there is no shared layer between the two UIs to put it in and this is exactly
 * the kind of rule that drifts silently once it lives as branches in two view bodies.
 *
 * THE RULE, in the order it was asked for:
 *
 *  * a post's song keeps playing when you open its photos full screen — the viewer is the same post,
 *    bigger, not a sheet covering it;
 *  * a video page whose clip carries its OWN audible sound takes the stage, and the song comes back
 *    the moment you page off it;
 *  * a clip that cannot be heard — a screen recording, a time-lapse, one the author muted — never
 *    takes anything from the song;
 *  * the song chip mutes the song, the speaker chip mutes the clip, and an explicit tap on the
 *    speaker outranks the automatic choice for the rest of the viewer's life;
 *  * a live call outranks everything. (Apple also weighs its app-wide silent switch here; Android
 *    has no such single switch — the device-mute question is asked per surface, by `deviceSilenced`,
 *    which is why `appSilent` is simply false on this side.)
 */
data class ViewerAudioPolicy(
    /** Is there a song to play at all? False for media with no post behind it (a DM attachment, a
     *  comment's photo) and under super data saver, which never streams a song anywhere. */
    val hasSong: Boolean = false,
    /** The viewer's own song mute — not a global one. */
    val musicMuted: Boolean = false,
    val onVideoPage: Boolean = false,
    /** Probed from the file, not guessed from the extension: "is a video" and "makes sound" are
     *  different questions. */
    val clipCarriesAudio: Boolean = false,
    val authorMutedVideo: Boolean = false,
    /** A tap on the speaker chip. Null until the user taps, so paging decides on its own until then. */
    val explicitVideoChoice: Boolean? = null,
    /** The persisted, app-wide "video sound is on" choice the feed's speaker writes. */
    val globalVideoSoundOn: Boolean = false,
    val appSilent: Boolean = false,
    val callActive: Boolean = false,
) {
    /** Would this page's clip take the stage if sound were on? */
    val clipWantsStage: Boolean get() = onVideoPage && clipCarriesAudio && !authorMutedVideo

    /** Is the clip's own audio wanted on this page? With a song in play the clip takes over
     *  automatically; with no song this is the plain global choice, so a DM video in this viewer
     *  behaves exactly as it did before any of this existed. */
    val videoSoundAllowed: Boolean
        get() = explicitVideoChoice ?: if (hasSong) clipWantsStage else globalVideoSoundOn

    /** May the page's player actually make noise? */
    val videoAudible: Boolean get() = videoSoundAllowed && !appSilent && !callActive

    /** Is the song audible right now — or ducked under a clip that took the stage? */
    val musicAudible: Boolean
        get() = hasSong && !musicMuted && !(clipWantsStage && videoAudible) && !appSilent && !callActive

    /** Quiet because a clip is talking over it rather than because anyone muted it. Worth
     *  distinguishing: the chip otherwise reads as "you muted this" when the video simply started. */
    val musicDucked: Boolean get() = hasSong && !musicMuted && clipWantsStage && videoAudible
}
