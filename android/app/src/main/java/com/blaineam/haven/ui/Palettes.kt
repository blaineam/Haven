package com.blaineam.haven.ui

import kotlin.math.pow

/**
 * The curated palette set (docs/PALETTES.md), identical on every client. Pure Kotlin — no Compose,
 * no Android — so the lookup, fallback and contrast rules are unit-testable on the JVM.
 *
 * Each palette is three gradient stops; stop 2 is the tint. Colours are 0xRRGGBB ints.
 */
data class Palette(
    val id: String, val stop1: Int, val stop2: Int, val stop3: Int,
    /** True when white text on this palette's gradient must meet WCAG AA (Neutral). The gradient's
     *  stops are then deepened until white reads on every one; colourful palettes keep raw stops. */
    val strictAA: Boolean = false,
)

object Palettes {
    const val DEFAULT_ID = "sunset"

    val all: List<Palette> = listOf(
        Palette("sunset", 0x7C3AED, 0xEC4899, 0xF59E0B),
        Palette("ocean", 0x2563EB, 0x06B6D4, 0x14B8A6),
        Palette("forest", 0x047857, 0x10B981, 0x84CC16),
        Palette("rose", 0xBE123C, 0xF43F5E, 0xFB923C),
        Palette("ember", 0xB91C1C, 0xF97316, 0xFACC15),
        Palette("sky", 0x0EA5E9, 0x6366F1, 0xA78BFA),
        Palette("grape", 0x6D28D9, 0xA855F7, 0xF472B6),
        Palette("neutral", 0x404040, 0x737373, 0xA3A3A3, strictAA = true),
    )

    val default: Palette get() = all.first()

    /** The palette for a stored id; null, blank or an id from a newer build → [default]. */
    fun byId(id: String?): Palette = all.firstOrNull { it.id == id } ?: default

    /** Normalises a stored id to a known one (what [byId] would resolve it to). */
    fun normalizedId(id: String?): String = byId(id).id

    /** [stop] deepened toward black until white text on it reaches [min] contrast. */
    fun deepenForWhiteText(stop: Int, min: Double = AA_TEXT): Int {
        var t = 0.0
        var c = stop
        while (t <= 1.0 && contrast(c, 0xFFFFFF) < min) { t += 0.02; c = mix(stop, 0x000000, t) }
        return c
    }

    /** The gradient stops to PAINT for [p]: raw, or deepened for white text when [Palette.strictAA]. */
    fun gradientStops(p: Palette): Triple<Int, Int, Int> =
        if (!p.strictAA) Triple(p.stop1, p.stop2, p.stop3)
        else Triple(deepenForWhiteText(p.stop1), deepenForWhiteText(p.stop2), deepenForWhiteText(p.stop3))

    // ---- Contrast (WCAG 2.x) ------------------------------------------------------------------

    /** Surfaces text sits on, per mode: the card, and the (slightly darker/lighter) page backdrop. */
    const val LIGHT_BACKDROP = 0xF6F4FA
    const val LIGHT_CARD = 0xFFFFFF
    const val DARK_BACKDROP = 0x0B0B0F
    const val DARK_CARD = 0x16161D
    const val AA_TEXT = 4.5

    private fun lin(c: Int): Double {
        val s = c / 255.0
        return if (s <= 0.03928) s / 12.92 else ((s + 0.055) / 1.055).pow(2.4)
    }

    fun luminance(rgb: Int): Double =
        0.2126 * lin((rgb shr 16) and 0xFF) + 0.7152 * lin((rgb shr 8) and 0xFF) + 0.0722 * lin(rgb and 0xFF)

    fun contrast(a: Int, b: Int): Double {
        val la = luminance(a); val lb = luminance(b)
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }

    private fun mix(from: Int, to: Int, t: Double): Int {
        fun ch(shift: Int): Int {
            val f = (from shr shift) and 0xFF; val g = (to shr shift) and 0xFF
            return (f + (g - f) * t).toInt().coerceIn(0, 255)
        }
        return (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    }

    /**
     * [stop] nudged until it reaches [min] contrast on every surface in [surfaces] — darkened toward
     * black on a light mode, lightened toward white on a dark one. A stop that already passes is
     * returned untouched (so Sunset keeps its pink in dark mode). Derived from the stop, never a
     * per-palette override.
     */
    fun readable(stop: Int, dark: Boolean, min: Double = AA_TEXT): Int {
        val surfaces = if (dark) listOf(DARK_CARD, DARK_BACKDROP) else listOf(LIGHT_BACKDROP, LIGHT_CARD)
        val target = if (dark) 0xFFFFFF else 0x000000
        var t = 0.0
        var c = stop
        while (t <= 1.0 && surfaces.any { contrast(c, it) < min }) {
            t += 0.02
            c = mix(stop, target, t)
        }
        return c
    }
}
