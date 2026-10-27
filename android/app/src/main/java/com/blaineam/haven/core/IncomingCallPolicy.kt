package com.blaineam.haven.core

/**
 * What an incoming Haven call does on the phone, as pure rules (no Android types) so they are covered by
 * a plain JVM test. docs/ANDROID-CALLS.md.
 *
 * A SELF-MANAGED Telecom call draws and rings NOTHING: Telecom only tracks the call's state. The app
 * must post its own incoming-call notification AND ring on its own, and must do both whether or not
 * Telecom ever calls `onShowIncomingCallUi` (it did not on a real phone). Before this, the ring was the
 * notification channel's sound — a ONE-SHOT, silenced entirely when the ring stream is muted, and a single
 * one-second buzz in vibrate mode — so a phone left on vibrate "never rang" (2026-10-27: STREAM_RING muted,
 * `shouldNotificationSoundPlay false`, the heads-up was there for five seconds and then answered by tap).
 */
object IncomingCallPolicy {
    /** What to play while ringing. */
    enum class Ring { SOUND_AND_VIBRATE, SOUND, VIBRATE, NONE }

    // android.media.AudioManager ringer modes / android.app.NotificationManager filter (copied: JVM-testable).
    const val RINGER_SILENT = 0
    const val RINGER_VIBRATE = 1
    const val RINGER_NORMAL = 2
    const val FILTER_ALL = 1

    /** Vibration while ringing: 1 s on, 1 s off, repeating from the start (index 0). */
    val VIBRATION_PATTERN = longArrayOf(0, 1000, 1000)

    /** A hard stop for a ring that nobody ended — just past the engine's 60 s callee ring timeout. */
    const val MAX_RING_MS = 70_000L

    /**
     * How to ring, from the user's own settings. Normal: the ringtone (plus vibration when they have
     * "vibrate for calls" on). Vibrate mode: vibrate, repeatedly — never a single buzz. Silent, or Do Not
     * Disturb filtering interruptions: nothing but the notification itself.
     */
    fun ringFor(ringerMode: Int, vibrateWhenRinging: Boolean, interruptionFilter: Int): Ring = when {
        interruptionFilter != FILTER_ALL -> Ring.NONE
        ringerMode == RINGER_NORMAL -> if (vibrateWhenRinging) Ring.SOUND_AND_VIBRATE else Ring.SOUND
        ringerMode == RINGER_VIBRATE -> Ring.VIBRATE
        else -> Ring.NONE
    }

    fun plays(ring: Ring) = ring == Ring.SOUND || ring == Ring.SOUND_AND_VIBRATE
    fun vibrates(ring: Ring) = ring == Ring.VIBRATE || ring == Ring.SOUND_AND_VIBRATE

    /** Posts / removes the incoming-call notification (CallStyle, full-screen intent, Answer/Decline). */
    interface Poster {
        fun show(name: String)
        fun cancel()
    }

    /** Plays / stops the ring (looping sound and/or repeating vibration). */
    interface Ringer {
        fun start(ring: Ring)
        fun stop()
    }

    /**
     * One incoming call's presentation. The notification is posted — and the ring started — the moment the
     * call is known ([onRinging]); Telecom's `onShowIncomingCallUi` is only an extra trigger that re-asserts
     * the notification ([onShowUiRequested]) and never rings a second time. Every way a call stops being
     * ringing (answered, declined, hung up, timed out, failed) goes through [onEnded].
     */
    class Presenter(
        private val poster: Poster,
        private val ringer: Ringer,
        private val ringProvider: () -> Ring,
    ) {
        var ringing = false; private set

        /** The call just started ringing. Idempotent: a second report neither re-rings nor double-posts. */
        fun onRinging(name: String) {
            if (ringing) return
            ringing = true
            poster.show(name)
            ringer.start(ringProvider())
        }

        /**
         * Telecom asked Haven to show its incoming-call UI: re-assert the notification (same id), no second
         * ring. Ignored once the call is no longer ringing — a late callback must never resurrect a ring.
         */
        fun onShowUiRequested(name: String) {
            if (ringing) poster.show(name)
        }

        /** Answered, declined, remote hang-up, timeout, failure: remove the notification and stop the ring. */
        fun onEnded() {
            ringing = false
            poster.cancel()
            ringer.stop()
        }
    }
}
