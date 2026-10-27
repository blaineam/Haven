package com.blaineam.haven.core

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log

/**
 * The Android side of [IncomingCallPolicy]: the CallStyle notification ([Notifications.postIncomingCall])
 * and Haven's own looping ring. Independent of Telecom — the call rings from the moment the engine knows
 * about it, whether or not the system ever asks Haven to show its UI.
 */
object IncomingCallUi {
    private const val TAG = "IncomingCallUi"
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var presenter: IncomingCallPolicy.Presenter? = null
    @Volatile private var appContext: Context? = null

    private fun presenter(ctx: Context): IncomingCallPolicy.Presenter {
        presenter?.let { return it }
        val app = ctx.applicationContext
        appContext = app
        return synchronized(this) {
            presenter ?: IncomingCallPolicy.Presenter(
                poster = object : IncomingCallPolicy.Poster {
                    override fun show(name: String) = Notifications.postIncomingCall(app, name)
                    override fun cancel() = Notifications.cancelIncomingCall(app)
                },
                ringer = AndroidRinger(app),
                ringProvider = { currentRing(app) },
            ).also { presenter = it }
        }
    }

    /** The call is ringing: notification + ring, now. Idempotent. */
    fun ring(context: Context, name: String) { runCatching { presenter(context).onRinging(name) }
        .onFailure { Log.w(TAG, "incoming call UI failed: ${it.javaClass.simpleName}: ${it.message}") } }

    /** Telecom's `onShowIncomingCallUi`: re-assert the notification. Never rings again. */
    fun reassert(context: Context, name: String) { runCatching { presenter(context).onShowUiRequested(name) } }

    /** Answered / declined / ended: notification gone, ring stopped. Safe to call when nothing rings. */
    fun stop(context: Context) { runCatching { presenter(context).onEnded() } }

    private fun currentRing(ctx: Context): IncomingCallPolicy.Ring {
        val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val vibrateWhenRinging = runCatching {
            Settings.System.getInt(ctx.contentResolver, "vibrate_when_ringing", 0) != 0
        }.getOrDefault(false)
        val filter = if (Build.VERSION.SDK_INT >= 23) nm.currentInterruptionFilter else IncomingCallPolicy.FILTER_ALL
        return IncomingCallPolicy.ringFor(audio.ringerMode, vibrateWhenRinging, filter)
    }

    /** Looping system ringtone and/or a repeating vibration, as the user's ringer settings allow. */
    private class AndroidRinger(private val ctx: Context) : IncomingCallPolicy.Ringer {
        private var ringtone: Ringtone? = null
        private var vibrator: Vibrator? = null
        private val stopper = Runnable { stop() }
        private val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        override fun start(ring: IncomingCallPolicy.Ring) {
            stop()
            if (ring == IncomingCallPolicy.Ring.NONE) return
            if (IncomingCallPolicy.plays(ring)) runCatching {
                val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ringtone = RingtoneManager.getRingtone(ctx, uri)?.apply {
                    audioAttributes = attrs
                    if (Build.VERSION.SDK_INT >= 28) isLooping = true
                    play()
                }
            }.onFailure { Log.w(TAG, "ringtone failed: ${it.message}") }
            if (IncomingCallPolicy.vibrates(ring)) runCatching {
                val v = if (Build.VERSION.SDK_INT >= 31) {
                    (ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
                } else {
                    @Suppress("DEPRECATION") ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                }
                vibrator = v
                if (v.hasVibrator()) {
                    val effect = VibrationEffect.createWaveform(IncomingCallPolicy.VIBRATION_PATTERN, 0)
                    @Suppress("DEPRECATION") v.vibrate(effect, attrs)
                }
            }.onFailure { Log.w(TAG, "vibration failed: ${it.message}") }
            main.postDelayed(stopper, IncomingCallPolicy.MAX_RING_MS)
        }

        override fun stop() {
            main.removeCallbacks(stopper)
            runCatching { ringtone?.stop() }; ringtone = null
            runCatching { vibrator?.cancel() }; vibrator = null
        }
    }
}
