package com.blaineam.haven.core

import android.content.Context
import com.blaineam.haven.ui.AppIcon
import com.blaineam.haven.ui.HavenTheme
import com.blaineam.haven.ui.Palettes

/**
 * Per-device appearance settings (not self-synced in this wave — docs/PALETTES.md).
 * Key `appearance.palette`: one of the palette ids, default `sunset`, anything unknown → `sunset`.
 */
object AppearancePrefs {
    private const val PREFS = "haven.appearance"
    const val KEY_PALETTE = "appearance.palette"
    private var appContext: Context? = null

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        HavenTheme.paletteId = palette
    }

    /** The stored palette id, normalised. */
    val palette: String
        get() = Palettes.normalizedId(
            runCatching { appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)?.getString(KEY_PALETTE, null) }.getOrNull())

    /** Select [id]: persist, re-skin live (Compose recomposes off [HavenTheme.paletteId]) and switch
     *  the launcher icon to the matching alias. */
    fun setPalette(id: String) {
        val norm = Palettes.normalizedId(id)
        appContext?.let { c ->
            c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_PALETTE, norm).apply()
            AppIcon.apply(c, norm)
        }
        HavenTheme.paletteId = norm
    }
}
