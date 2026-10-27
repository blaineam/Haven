package com.blaineam.haven.core

import androidx.core.app.NotificationCompat
import com.blaineam.haven.R
import com.blaineam.haven.ui.Palettes

/**
 * Haven's brand for every notification surface (status bar, lock screen, Android Auto, the Telecom
 * account chip): the constellation mark as a monochrome small icon, tinted by the user's palette.
 * Android renders small icons from their alpha channel only, so the icons are white-on-transparent
 * vectors and the colour comes from [accent] (the palette's tint stop; Neutral stays grey).
 */
object NotificationBrand {
    /** Messages, posts, the connection service — the plain constellation. */
    val SMALL_ICON = R.drawable.ic_stat_haven
    /** Calls — a handset with the constellation cluster. */
    val SMALL_ICON_CALL = R.drawable.ic_stat_haven_call

    /** The palette's tint stop as an opaque ARGB colour for [NotificationCompat.Builder.setColor]. */
    fun accent(paletteId: String = AppearancePrefs.palette): Int =
        Palettes.gradientStops(Palettes.byId(paletteId)).second or (0xFF shl 24)

    /** Brand a builder: the small icon plus the palette accent. */
    fun apply(b: NotificationCompat.Builder, call: Boolean = false): NotificationCompat.Builder =
        b.setSmallIcon(if (call) SMALL_ICON_CALL else SMALL_ICON).setColor(accent())
}
