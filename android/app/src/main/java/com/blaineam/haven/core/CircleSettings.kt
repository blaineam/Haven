package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateOf

/**
 * Per-circle overrides for the media defaults that otherwise live in [ProfileStore] (save-to-Photos,
 * auto-optimize, auto-delete/retention). Mirrors iOS `CircleSettings.swift`: each circle either
 * inherits the app-wide default (no entry) or pins its own value. The resolved getters fall back to
 * the global setting when a circle has no override.
 */
object CircleSettings {
    private var prefs: android.content.SharedPreferences? = null
    private var appContext: Context? = null

    /** Bumps on any change so Compose feeds/sheets recompose. */
    val version = mutableStateOf(0)
    private fun bump() { version.value++ }

    fun init(context: Context) {
        if (prefs != null) return
        appContext = context.applicationContext
        prefs = context.applicationContext.getSharedPreferences("haven.circle.settings", Context.MODE_PRIVATE)
    }

    private fun profile() = ProfileStore.get(appContext!!)

    // --- Bool overrides (save-own / save-others / optimize): null = inherit global. ---
    private fun boolOverride(key: String, c: String): Boolean? =
        prefs?.let { if (it.contains("$key.$c")) it.getBoolean("$key.$c", false) else null }
    private fun setBool(key: String, c: String, v: Boolean?) {
        prefs?.edit()?.apply { if (v == null) remove("$key.$c") else putBoolean("$key.$c", v) }?.apply()
        bump()
    }

    fun saveOwnOverride(c: String) = boolOverride("saveOwn", c)
    fun saveOthersOverride(c: String) = boolOverride("saveOthers", c)
    fun optimizeOverride(c: String) = boolOverride("optimize", c)
    fun setSaveOwn(c: String, v: Boolean?) = setBool("saveOwn", c, v)
    fun setSaveOthers(c: String, v: Boolean?) = setBool("saveOthers", c, v)
    fun setOptimize(c: String, v: Boolean?) = setBool("optimize", c, v)

    /** Resolved values used at the consumption points (override ?? global default). */
    fun saveOwn(c: String): Boolean = boolOverride("saveOwn", c) ?: runCatching { profile().saveMyPosts }.getOrDefault(false)
    fun saveOthers(c: String): Boolean = boolOverride("saveOthers", c) ?: runCatching { profile().saveOthersPosts }.getOrDefault(false)
    fun optimize(c: String): Boolean = boolOverride("optimize", c) ?: runCatching { profile().autoOptimize }.getOrDefault(true)

    // --- Retention override (days): null = inherit global. ---
    fun retentionOverride(c: String): Int? =
        prefs?.let { if (it.contains("retention.$c")) it.getInt("retention.$c", 0) else null }
    fun setRetention(c: String, days: Int?) {
        prefs?.edit()?.apply { if (days == null) remove("retention.$c") else putInt("retention.$c", days) }?.apply()
        bump()
    }
    fun retentionDays(c: String): Int = retentionOverride(c) ?: runCatching { profile().retentionDays }.getOrDefault(0)
    /** Seconds for the engine feed() call (null = keep forever), per circle. */
    fun retentionSecs(c: String): ULong? {
        val n = retentionDays(c); return if (n <= 0) null else (n.toLong() * 86_400L).toULong()
    }

    // --- My own name for a circle (local only — never sent, never synced to members) ---

    /**
     * What *I* call this circle, if I've renamed it for myself. `null` = use the circle's real name.
     *
     * Purely local, exactly like a contact nickname: it never leaves this account, so renaming a
     * circle for myself can't rename it for everyone else in it. The circle's real name stays
     * authoritative on the wire — this only changes what I see, and only at DISPLAY time.
     */
    fun nickname(c: String): String? =
        prefs?.getString("nickname.$c", null)?.trim()?.takeIf { it.isNotEmpty() }

    /** The name to SHOW for a circle: my nickname if I set one, else its real name. Every display
     *  site should go through this (or [HavenNet.circleName]) so a renamed circle doesn't revert
     *  wherever one was missed. */
    fun displayName(c: String, real: String): String = nickname(c) ?: real

    /** Set — or clear, with a blank string — my own name for a circle. */
    fun setNickname(c: String, v: String) {
        val trimmed = v.trim()
        prefs?.edit()?.apply { if (trimmed.isEmpty()) remove("nickname.$c") else putString("nickname.$c", trimmed) }?.apply()
        bump()
    }

    fun hasAnyOverride(c: String): Boolean =
        saveOwnOverride(c) != null || saveOthersOverride(c) != null ||
            optimizeOverride(c) != null || retentionOverride(c) != null
}
