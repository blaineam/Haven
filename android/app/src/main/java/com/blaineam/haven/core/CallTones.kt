package com.blaineam.haven.core

import android.media.AudioManager
import android.media.ToneGenerator
import android.util.Log

/**
 * The caller's ringback ("dial tone" while the far end rings) — Apple `CallTones.startRingback` parity. Without
 * it an Android→iPhone call is dead silence until someone answers, which reads as "the call didn't go out".
 * Plays the platform's standard ringback on the voice-call stream and stops the moment the call connects,
 * ends, or fails. One generator at a time; start/stop are idempotent and never throw.
 */
object CallTones {
    private const val TAG = "CallTones"
    private var gen: ToneGenerator? = null

    /** The rule, pure so it is tested: only the CALLER hears ringback, only while still dialing. */
    fun shouldPlayRingback(isCaller: Boolean, connecting: Boolean, inCall: Boolean) = isCaller && connecting && !inCall

    @Synchronized
    fun startRingback() {
        if (gen != null) return
        gen = runCatching {
            ToneGenerator(AudioManager.STREAM_VOICE_CALL, 70).also { it.startTone(ToneGenerator.TONE_SUP_RINGTONE) }
        }.onFailure { Log.w(TAG, "ringback unavailable: ${it.message}") }.getOrNull()
    }

    @Synchronized
    fun stop() {
        val g = gen ?: return
        gen = null
        runCatching { g.stopTone(); g.release() }
    }
}
