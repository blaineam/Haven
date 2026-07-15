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
    val violet = Color(0xFF7C3AED)
    val amber = Color(0xFFF59E0B)

    /** The literal brand pink — the app icon's middle stop. Fixed in BOTH modes; see [pink]. */
    val brandPink = Color(0xFFEC4899)

    /**
     * Which palette is live. [HavenAppTheme] drives this from the system setting; every colour
     * below reads it, so one write re-skins the whole app. A plain global (not a CompositionLocal)
     * because the tokens are read from non-@Composable Modifier builders like [havenCard] too.
     */
    var isDark by mutableStateOf(true)
        internal set

    /**
     * The interactive accent: links, tints, small labels. Light mode deepens the brand pink to the
     * same hue's 700 step — #EC4899 only reaches 3.5:1 on a light surface (fails AA for body text)
     * where #BE185D reaches 6.0:1. [brand] still uses [brandPink], so the brand mark never shifts.
     */
    val pink: Color get() = if (isDark) brandPink else Color(0xFFBE185D)

    /** Near-black grouped background (dark), or a violet-tinted off-white that keeps cards floating. */
    val background: Color get() = if (isDark) Color(0xFF0B0B0F) else Color(0xFFF6F4FA)
    val card: Color get() = if (isDark) Color(0xFF16161D) else Color.White
    val cardBorder: Color get() = if (isDark) Color(0x14FFFFFF) else Color(0x14000000)

    /** 6.5:1 on its own card in dark, 6.4:1 in light — deliberately matched across modes. */
    val textSecondary: Color get() = if (isDark) Color(0xFF9A9AA8) else Color(0xFF5F5D6B)

    /** Primary label. Use instead of a bare Color.White, which is invisible on a light card. */
    val textPrimary: Color get() = if (isDark) Color.White else Color(0xFF14131A)

    /** The signature sunset gradient (matches the app icon) — brand identity, so never themed. */
    val brand = Brush.linearGradient(
        colors = listOf(violet, brandPink, amber),
        start = Offset(0f, 0f),
        end = Offset.Infinite,
    )

    val brandHorizontal = Brush.horizontalGradient(listOf(violet, brandPink, amber))

    // Motion vocabulary — a small set of springs used everywhere for cohesion.
    fun <T> bouncy() = spring<T>(dampingRatio = 0.68f, stiffness = Spring.StiffnessMediumLow)
    fun <T> smooth() = spring<T>(dampingRatio = 0.85f, stiffness = Spring.StiffnessLow)
    fun <T> snappy() = spring<T>(dampingRatio = 0.70f, stiffness = Spring.StiffnessMedium)
}

private val HavenDarkScheme = darkColorScheme(
    primary = HavenTheme.brandPink,
    secondary = HavenTheme.violet,
    tertiary = HavenTheme.amber,
    background = Color(0xFF0B0B0F),
    surface = Color(0xFF16161D),
    onPrimary = Color.White,
    onBackground = Color.White,
    onSurface = Color.White,
)

// Not Material's stock light scheme: Haven is dark-leaning, so light keeps the violet-tinted
// backdrop and the deepened accent rather than defaulting to purple-on-white.
private val HavenLightScheme = lightColorScheme(
    primary = Color(0xFFBE185D),
    secondary = HavenTheme.violet,
    tertiary = Color(0xFFB45309),   // amber-700; stock amber is 2.2:1 on white
    background = Color(0xFFF6F4FA),
    surface = Color.White,
    onPrimary = Color.White,
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
        colorScheme = if (dark) HavenDarkScheme else HavenLightScheme,
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
                    colors = listOf(HavenTheme.brandPink.copy(alpha = pinkGlow), Color.Transparent),
                    center = Offset(900f, -40f),
                    radius = 1200f,
                )
            )
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.radialGradient(
                    colors = listOf(HavenTheme.violet.copy(alpha = violetGlow), Color.Transparent),
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
