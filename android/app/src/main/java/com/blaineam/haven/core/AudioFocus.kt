package com.blaineam.haven.core

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager

/**
 * The one place Haven asks Android for the audio route.
 *
 * Before this, the app's coordination was a one-directional star drawn by hand: video deferred to
 * `CallManager.callInProgress`, a song preview deferred to calls and open cameras, and a call
 * stopped the song. Nothing ever yielded to another APP — Haven would talk straight over a podcast,
 * and a phone call arriving mid-story left the song playing under it. The voice-note pill did
 * request focus, but registered no listener, so it only ever took the route and never gave it back.
 *
 * The house rule, and it is deliberately the same on every surface so the app behaves one way:
 *
 *  - **Transient loss** (a call, an alarm, a navigation prompt) → **PAUSE**, and resume on regain.
 *    Not duck: these are things you need to hear, and a story's song at 20% under a phone call is
 *    worse than silence.
 *  - **Transient loss that permits ducking** (a notification blip) → **DUCK** for music, and PAUSE
 *    for speech. A voice note ducked to 20% is unintelligible, so speech holders ask the system for
 *    `willPauseWhenDucked`, which converts those events into ordinary transient losses and means a
 *    speech [Holder] never sees [Holder.onDuck] at all.
 *  - **Permanent loss** (another app took over playback) → **STOP**, and do not come back. Resuming
 *    after a permanent loss is how an app ends up fighting Spotify.
 *
 * Holders are keyed by identity and dropped on [abandon] and on permanent loss, so the map is
 * bounded by what is currently on screen and cannot accumulate.
 */
object AudioFocus {
    /**
     * A thing that makes noise. Every callback arrives on the main thread (the platform posts to the
     * handler the request was built with), so implementations may touch Compose state directly.
     */
    interface Holder {
        /** Go quiet, but stay ready — [onResume] is coming. */
        fun onPause()

        /** Stay audible, get out of the way. Music only; speech holders are never sent this. */
        fun onDuck()

        /** The route is ours again: undo whatever [onPause] or [onDuck] did. */
        fun onResume()

        /** Gone for good. Stop, release, and do not resume. */
        fun onStop()
    }

    private val requests = HashMap<Holder, AudioFocusRequest>()

    private fun manager(context: Context) =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /**
     * Take the audio route for [holder]. Returns false if the system refused, in which case the
     * caller must NOT start playing — that refusal is the bound that keeps a story's song from
     * starting on top of a phone call.
     *
     * [speech] picks the voice-note treatment described above: spoken content is marked as such and
     * asks to be paused rather than ducked.
     */
    fun request(context: Context, holder: Holder, speech: Boolean = false): Boolean = synchronized(requests) {
        requests[holder]?.let { return true }   // already ours; don't ask twice
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(if (speech) AudioAttributes.CONTENT_TYPE_SPEECH else AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attrs)
            // Speech converts duck-permitted losses into plain transient ones (see the class doc).
            .setWillPauseWhenDucked(speech)
            .setOnAudioFocusChangeListener { change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS -> {
                        // Drop it first: the holder's onStop may re-enter through abandon(), and a
                        // permanent loss means the request is already dead to the system anyway.
                        synchronized(requests) { requests.remove(holder) }
                        holder.onStop()
                    }
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> holder.onPause()
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> holder.onDuck()
                    AudioManager.AUDIOFOCUS_GAIN -> holder.onResume()
                }
            }
            .build()
        val granted = runCatching {
            manager(context).requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }.getOrDefault(false)
        if (granted) requests[holder] = req
        return granted
    }

    /** Give the route back. Safe to call for a holder that never held it. */
    fun abandon(context: Context, holder: Holder) {
        val req = synchronized(requests) { requests.remove(holder) } ?: return
        runCatching { manager(context).abandonAudioFocusRequest(req) }
    }
}
