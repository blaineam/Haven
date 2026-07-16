package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf

/**
 * DEVICE-LOCAL age/size caps for cached media (Settings ▸ Connection ▸ Storage). The client sibling
 * of the relay's retention: old / excess cached blobs are evicted oldest-first so this device stays
 * under the caps — the posts stay and re-download on demand. Both default OFF (0 = no limit). Changing
 * either kicks an immediate enforcement pass. Mirrors iOS `SettingsStore.localMediaMaxDays/MaxGB`.
 */
object MediaLimits {
    private const val PREFS = "haven.medialimits"
    private const val K_DAYS = "maxDays"
    private const val K_GB = "maxGB"
    private lateinit var appContext: Context

    /** Observable so the Storage pickers reflect the current selection. */
    val maxDaysState = mutableIntStateOf(0)
    val maxGBState = mutableIntStateOf(0)

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        maxDaysState.intValue = prefs.getInt(K_DAYS, 0)
        maxGBState.intValue = prefs.getInt(K_GB, 0)
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    val maxDays: Int get() = maxDaysState.intValue
    val maxGB: Int get() = maxGBState.intValue

    fun setMaxDays(days: Int) {
        if (days == maxDaysState.intValue) return
        maxDaysState.intValue = days
        prefs.edit().putInt(K_DAYS, days).apply()
        HavenNet.enforceLocalLimits(force = true)
    }

    fun setMaxGB(gb: Int) {
        if (gb == maxGBState.intValue) return
        maxGBState.intValue = gb
        prefs.edit().putInt(K_GB, gb).apply()
        HavenNet.enforceLocalLimits(force = true)
    }
}
