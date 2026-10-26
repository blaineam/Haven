package com.blaineam.haven.ui

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Haven's design system — the single source of brand color, depth, motion and tactile
 * feel, ported from the iOS Theme.swift so the two platforms look like one product.
 */
object HavenTheme {
    /**
     * The selected palette id (docs/PALETTES.md, `appearance.palette`). Snapshot state, so every
     * token below that reads it recomposes live when [com.blaineam.haven.core.AppearancePrefs]
     * changes it. Unknown ids resolve to sunset in [palette].
     */
    var paletteId by mutableStateOf(Palettes.DEFAULT_ID)
        internal set

    val palette: Palette get() = Palettes.byId(paletteId)

    private fun c(rgb: Int) = Color(0xFF000000.toInt() or rgb)

    // The three raw stops (violet→stop1, pink→stop2, amber→stop3 in the old hard-coded names).
    val stop1: Color get() = c(palette.stop1)
    val stop2: Color get() = c(palette.stop2)
    val stop3: Color get() = c(palette.stop3)

    /** Semantic "warning" amber — NOT themed (docs/PALETTES.md: ok/warn/destructive stay fixed). */
    val warn = Color(0xFFF59E0B)

    /**
     * Which palette is live. [HavenAppTheme] drives this from the system setting; every colour
     * below reads it, so one write re-skins the whole app. A plain global (not a CompositionLocal)
     * because the tokens are read from non-@Composable Modifier builders like [havenCard] too.
     */
    var isDark by mutableStateOf(true)
        internal set

    /**
     * The interactive accent (stop 2): links, tints, small labels. Derived from the stop so the text
     * always clears WCAG AA on its surface — light mode deepens it (Sunset's #EC4899 → a deep pink,
     * 3.5:1 → 4.5:1+), dark mode lifts a too-dim stop (Neutral). A stop that already passes is untouched.
     */
    val pink: Color get() = c(Palettes.readable(palette.stop2, isDark))

    /** Stop 1 as TEXT/linework (contrast-derived like [pink]). */
    val accent1: Color get() = c(Palettes.readable(palette.stop1, isDark))

    /** Stop 1 as text on a fixed WHITE surface (a white pill), whichever mode is live. */
    val stop1OnWhite: Color get() = c(Palettes.readable(palette.stop1, false))

    /** Near-black grouped background (dark), or a violet-tinted off-white that keeps cards floating. */
    val background: Color get() = if (isDark) Color(0xFF0B0B0F) else Color(0xFFF6F4FA)
    val card: Color get() = if (isDark) Color(0xFF16161D) else Color.White
    val cardBorder: Color get() = if (isDark) Color(0x14FFFFFF) else Color(0x14000000)

    /** 6.5:1 on its own card in dark, 6.4:1 in light — deliberately matched across modes. */
    val textSecondary: Color get() = if (isDark) Color(0xFF9A9AA8) else Color(0xFF5F5D6B)

    /** Primary label. Use instead of a bare Color.White, which is invisible on a light card. */
    val textPrimary: Color get() = if (isDark) Color.White else Color(0xFF14131A)

    private fun gradientColors(): List<Color> =
        Palettes.gradientStops(palette).let { (a, b, d) -> listOf(c(a), c(b), c(d)) }

    /** The signature gradient (the app icon's stops for the selected palette). */
    val brand: Brush get() = Brush.linearGradient(
        colors = gradientColors(),
        start = Offset(0f, 0f),
        end = Offset.Infinite,
    )

    val brandHorizontal: Brush get() = Brush.horizontalGradient(gradientColors())

    // Motion vocabulary — a small set of springs used everywhere for cohesion.
    fun <T> bouncy() = spring<T>(dampingRatio = 0.68f, stiffness = Spring.StiffnessMediumLow)
    fun <T> smooth() = spring<T>(dampingRatio = 0.85f, stiffness = Spring.StiffnessLow)
    fun <T> snappy() = spring<T>(dampingRatio = 0.70f, stiffness = Spring.StiffnessMedium)
}

private fun onColor(rgb: Int): Color =
    if (Palettes.contrast(rgb, 0xFFFFFF) >= Palettes.contrast(rgb, 0x000000)) Color.White else Color(0xFF14131A)

private fun darkScheme(p: Palette) = darkColorScheme(
    primary = Color(0xFF000000.toInt() or Palettes.readable(p.stop2, true)),
    secondary = Color(0xFF000000.toInt() or p.stop1),
    tertiary = Color(0xFF000000.toInt() or p.stop3),
    background = Color(0xFF0B0B0F),
    surface = Color(0xFF16161D),
    onPrimary = onColor(Palettes.readable(p.stop2, true)),
    onBackground = Color.White,
    onSurface = Color.White,
)

// Not Material's stock light scheme: Haven is dark-leaning, so light keeps the tinted backdrop and
// the deepened accent rather than defaulting to purple-on-white. The accent is derived from the
// palette's stops (stop 3 deepened for text, as the old hand-picked amber-700 was).
private fun lightScheme(p: Palette) = lightColorScheme(
    primary = Color(0xFF000000.toInt() or Palettes.readable(p.stop2, false)),
    secondary = Color(0xFF000000.toInt() or Palettes.readable(p.stop1, false)),
    tertiary = Color(0xFF000000.toInt() or Palettes.readable(p.stop3, false)),
    background = Color(0xFFF6F4FA),
    surface = Color.White,
    onPrimary = onColor(Palettes.readable(p.stop2, false)),
    onBackground = Color(0xFF14131A),
    onSurface = Color(0xFF14131A),
)

@Composable
fun HavenAppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    // Publish BEFORE the children compose, so the first frame already paints the right palette
    // (a SideEffect would land a frame late and flash dark on a light device). Guarded so the
    // write only happens on an actual mode flip.
    if (HavenTheme.isDark != dark) HavenTheme.isDark = dark
    MaterialTheme(
        colorScheme = if (dark) darkScheme(HavenTheme.palette) else lightScheme(HavenTheme.palette),
        typography = Typography(),
        content = content,
    )
}

/** Soft branded backdrop: the base tint with two gentle brand glows. */
@Composable
fun HavenBackground(content: @Composable () -> Unit) {
    // The glows read far hotter over a light base (they tint toward the surface, not away from it),
    // so light halves them to a wash — the same mood without muddying the cards on top.
    val pinkGlow = if (HavenTheme.isDark) 0.20f else 0.10f
    val violetGlow = if (HavenTheme.isDark) 0.18f else 0.09f
    Box(Modifier.fillMaxSize().background(HavenTheme.background)) {
        Box(
            Modifier.fillMaxSize().background(
                Brush.radialGradient(
                    colors = listOf(HavenTheme.stop2.copy(alpha = pinkGlow), Color.Transparent),
                    center = Offset(900f, -40f),
                    radius = 1200f,
                )
            )
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.radialGradient(
                    colors = listOf(HavenTheme.stop1.copy(alpha = violetGlow), Color.Transparent),
                    center = Offset(40f, 300f),
                    radius = 1100f,
                )
            )
        )
        content()
    }
}

/** A floating, slightly-bordered card with soft depth. */
fun Modifier.havenCard(): Modifier = this
    .background(HavenTheme.card, RoundedCornerShape(24.dp))

@Composable
fun rememberPressInteraction() = MutableInteractionSource()
