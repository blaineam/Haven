package com.blaineam.haven.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Live feed for [HeavyWorkPolicy] — Apple `HeavyWorkMonitor` parity. Samples the Haven call state,
 * any other call (the platform audio mode: IN_CALL / IN_COMMUNICATION / CALL_SCREENING — no phone
 * permission needed, unlike TelephonyManager's call state on API 31+), the PowerManager thermal
 * status, and Battery Saver.
 *
 * Entering suspension is caught by listeners (thermal, power-save broadcast, audio-mode on API 31+)
 * and by every [refresh] the serve / fetch paths make anyway. LEAVING it is also polled — every 20s,
 * and only while suspended — because a call ending on API < 31 has no callback, and the whole point
 * is to resume parked work promptly ([onLifted]).
 */
object HeavyWorkMonitor {
    private const val TAG = "HeavyWork"

    /** Latest sample; readable from any thread (the serve loops check it per chunk). */
    @Volatile var current: HeavyWorkPolicy.Conditions = HeavyWorkPolicy.Conditions()
        private set

    /** Called (on a background thread) when the gate lifts — resume parked media work. */
    @Volatile var onLifted: (() -> Unit)? = null

    private var appContext: Context? = null
    @Volatile private var started = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var liftPoller: Job? = null

    fun start(context: Context) {
        if (started) return
        synchronized(this) {
            if (started) return
            started = true
        }
        val ctx = context.applicationContext
        appContext = ctx
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        runCatching { pm?.addThermalStatusListener(ctx.mainExecutor) { refresh() } }
        runCatching {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) { refresh() }
            }
            val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else ctx.registerReceiver(receiver, filter)
        }
        if (Build.VERSION.SDK_INT >= 31) runCatching {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            am?.addOnModeChangedListener(ctx.mainExecutor) { refresh() }
        }
        refresh()
    }

    private fun sample(): HeavyWorkPolicy.Conditions {
        val ctx = appContext ?: return HeavyWorkPolicy.Conditions(havenCall = CallManager.callInProgress)
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val heat = when (runCatching { pm?.currentThermalStatus }.getOrNull()) {
            PowerManager.THERMAL_STATUS_LIGHT,
            PowerManager.THERMAL_STATUS_MODERATE -> HeavyWorkPolicy.Heat.FAIR
            PowerManager.THERMAL_STATUS_SEVERE -> HeavyWorkPolicy.Heat.SERIOUS
            PowerManager.THERMAL_STATUS_CRITICAL,
            PowerManager.THERMAL_STATUS_EMERGENCY,
            PowerManager.THERMAL_STATUS_SHUTDOWN -> HeavyWorkPolicy.Heat.CRITICAL
            else -> HeavyWorkPolicy.Heat.NOMINAL
        }
        val mode = runCatching { am?.mode }.getOrNull()
        val systemCall = mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION ||
            mode == AudioManager.MODE_CALL_SCREENING
        return HeavyWorkPolicy.Conditions(
            havenCall = runCatching { CallManager.callInProgress }.getOrDefault(false),
            systemCall = systemCall,
            heat = heat,
            powerSave = runCatching { pm?.isPowerSaveMode }.getOrNull() == true,
        )
    }

    /** Re-sample now (cheap: a few system-service getters). Returns the fresh conditions. */
    fun refresh(): HeavyWorkPolicy.Conditions {
        val new = sample()
        val old: HeavyWorkPolicy.Conditions
        synchronized(this) {
            old = current
            current = new
        }
        if (new == old) return new
        if (new.suspendHeavyIO != old.suspendHeavyIO ||
            new.peerServingAllowedForFriends != old.peerServingAllowedForFriends) {
            Log.i(TAG, "heavy-work gate: suspend=${new.suspendHeavyIO} friendServe=${new.peerServingAllowedForFriends} [${new.reason}]")
        }
        synchronized(this) {
            if (new.suspendHeavyIO && liftPoller?.isActive != true) {
                liftPoller = scope.launch {
                    while (current.suspendHeavyIO) { delay(20_000); refresh() }
                }
            }
        }
        val lifted = (old.suspendHeavyIO && !new.suspendHeavyIO) || (old.pauseEverything && !new.pauseEverything)
        if (lifted) scope.launch { runCatching { onLifted?.invoke() } }
        return new
    }
}
