package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The full-screen viewer's audio rule, as a table — the Kotlin half of a pair. The Apple test file
 * (`ViewerAudioPolicyTests.swift`) asserts the same cases against the same field names, so a change
 * to one client's behaviour that is not made on the other shows up as a red test rather than as a
 * report from someone using the app.
 */
class ViewerAudioPolicyTest {

    /** A photo page under a song: the song plays. This is the whole point — it used to stop dead the
     *  moment a photo opened full screen. */
    @Test fun photoPageKeepsTheSongPlaying() {
        val p = ViewerAudioPolicy(hasSong = true, onVideoPage = false)
        assertTrue(p.musicAudible)
        assertFalse(p.videoAudible)
        assertFalse(p.musicDucked)
    }

    /** A video page whose clip carries sound takes the stage automatically — without the user having
     *  ever turned the global video-sound toggle on, which is off by default. */
    @Test fun audibleClipTakesTheStageFromTheSong() {
        val p = ViewerAudioPolicy(hasSong = true, onVideoPage = true, clipCarriesAudio = true,
            globalVideoSoundOn = false)
        assertTrue(p.videoAudible)
        assertFalse(p.musicAudible)
        assertTrue(p.musicDucked)   // ducked, not muted — the chip must say so
    }

    /** ...and gives it straight back on the next photo. */
    @Test fun songReturnsOnThePhotoAfterTheVideo() {
        val onVideo = ViewerAudioPolicy(hasSong = true, onVideoPage = true, clipCarriesAudio = true)
        assertFalse(onVideo.musicAudible)
        assertTrue(onVideo.copy(onVideoPage = false).musicAudible)
    }

    /** A SILENT video — a screen recording, a time-lapse, a clip muted before posting — has nothing
     *  to offer, so it must not silence the song on its way past. */
    @Test fun silentClipNeverTakesTheStage() {
        val p = ViewerAudioPolicy(hasSong = true, onVideoPage = true, clipCarriesAudio = false)
        assertTrue(p.musicAudible)
        assertFalse(p.videoAudible)
    }

    /** The author muted this post's video: the song is the audio they chose. */
    @Test fun authorMutedClipNeverTakesTheStage() {
        val p = ViewerAudioPolicy(hasSong = true, onVideoPage = true, clipCarriesAudio = true,
            authorMutedVideo = true)
        assertTrue(p.musicAudible)
        assertFalse(p.videoAudible)
    }

    /** The song chip mutes the song and nothing else — the clip on a video page is unaffected. */
    @Test fun songChipMutesOnlyTheSong() {
        val p = ViewerAudioPolicy(hasSong = true, musicMuted = true, onVideoPage = true,
            clipCarriesAudio = true)
        assertFalse(p.musicAudible)
        assertFalse(p.musicDucked)   // muted by the user, not ducked under the clip
        assertTrue(p.videoAudible)
    }

    /** An explicit tap on the speaker outranks the automatic duck, in both directions. */
    @Test fun explicitSpeakerChoiceOutranksTheAutomaticChoice() {
        val muted = ViewerAudioPolicy(hasSong = true, onVideoPage = true, clipCarriesAudio = true,
            explicitVideoChoice = false)
        assertFalse(muted.videoAudible)
        assertTrue(muted.musicAudible)   // the user muted the clip → the song comes back

        val unmuted = muted.copy(explicitVideoChoice = true)
        assertTrue(unmuted.videoAudible)
        assertFalse(unmuted.musicAudible)
    }

    /** With no song — a DM attachment, a comment photo, a post with no music — the viewer falls back
     *  to the plain global toggle it has always used. Muted by default, audible once tapped. */
    @Test fun noSongFallsBackToTheGlobalToggle() {
        val off = ViewerAudioPolicy(hasSong = false, onVideoPage = true, clipCarriesAudio = true,
            globalVideoSoundOn = false)
        assertFalse(off.videoAudible)
        assertFalse(off.musicAudible)
        assertTrue(off.copy(globalVideoSoundOn = true).videoAudible)
    }

    /** A live call outranks every rule above (and Apple's app-wide mute, where it has one). */
    @Test fun callAudioOutranksEverything() {
        val call = ViewerAudioPolicy(hasSong = true, onVideoPage = true, clipCarriesAudio = true,
            explicitVideoChoice = true, callActive = true)
        assertFalse(call.musicAudible)
        assertFalse(call.videoAudible)

        val silent = call.copy(callActive = false, appSilent = true)
        assertFalse(silent.musicAudible)
        assertFalse(silent.videoAudible)
    }

    /** The song and the clip are NEVER both audible — the doubled-audio bug this whole rule exists to
     *  avoid. Checked across every combination rather than argued about. */
    @Test fun songAndClipAreNeverBothAudible() {
        val bools = listOf(true, false)
        for (hasSong in bools) for (musicMuted in bools) for (onVideoPage in bools)
            for (clipCarriesAudio in bools) for (authorMuted in bools)
                for (choice in listOf(null, true, false)) for (global in bools)
                    for (silent in bools) for (call in bools) {
                        val p = ViewerAudioPolicy(hasSong, musicMuted, onVideoPage, clipCarriesAudio,
                            authorMuted, choice, global, silent, call)
                        assertFalse("song and its own clip both audible: $p",
                            p.musicAudible && p.videoAudible && p.clipWantsStage)
                    }
    }
}
