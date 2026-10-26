package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateOf
import com.blaineam.haven.ui.MultiCircle

/** Counts plain Post taps and remembers whether the one-time "press and hold Post" tip was shown. */
object MultiCircleHint {
    private const val PREFS = "haven.multicircle"
    private var appContext: Context? = null
    private val prefs get() = appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Observable: the composer recomposes when the tip should appear / is dismissed. */
    val version = mutableStateOf(0)

    fun init(ctx: Context) { appContext = ctx.applicationContext }

    fun notePost() {
        val p = prefs ?: return
        if (p.getBoolean("shown", false)) return
        p.edit().putInt("posts", p.getInt("posts", 0) + 1).apply()
        version.value++
    }

    fun shouldShow(circleCount: Int): Boolean {
        val p = prefs ?: return false
        return MultiCircle.shouldShowHint(circleCount, p.getInt("posts", 0), p.getBoolean("shown", false))
    }

    /** Dismissed, or the user found the gesture themselves: never show again. */
    fun markShown() { prefs?.edit()?.putBoolean("shown", true)?.apply(); version.value++ }
}
