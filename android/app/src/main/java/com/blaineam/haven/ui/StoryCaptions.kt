package com.blaineam.haven.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight

/**
 * The cross-platform story-caption codec + shared typography tables. Wire format (identical to
 * apple/HavenApp/StoryCaption.swift and desktop/ui/app.js):
 *    \u0001color,font,styleRaw,x,y,size,mediaScale,mediaOffX,mediaOffY\u0001text
 * All position/size values are NORMALIZED (x/y as fractions of the media rect; size as a
 * multiplier on a 28-unit base), so a caption authored on any platform renders in the same spot
 * at the same relative size everywhere. A plain body (no \u0001 prefix) is just the text.
 */
object StoryCaptions {
    // Must match iOS StoryCaptions.colors index-for-index (the color rides as an index on the wire).
    val colors = listOf(
        Color.White, Color.Black, Color(0xFFEC4899), Color(0xFF8B5CF6), Color(0xFFF59E0B),
        Color(0xFFEF4444), Color(0xFFF97316), Color(0xFF22C55E), Color(0xFF3B82F6),
        Color(0xFF06B6D4), Color(0xFFEAB308), Color(0xFF10B981),
    )

    /** Typography cycle — mirrors iOS fontStyles: default/bold, serif/bold, rounded/heavy,
     *  monospaced/bold, default/black. (Cursive stands in for iOS "rounded".) */
    val fontFamilies = listOf(
        FontFamily.SansSerif, FontFamily.Serif, FontFamily.Cursive, FontFamily.Monospace, FontFamily.SansSerif,
    )
    val fontWeights = listOf(
        FontWeight.Bold, FontWeight.Bold, FontWeight.ExtraBold, FontWeight.Bold, FontWeight.Black,
    )
    fun fontFamily(idx: Int): FontFamily = fontFamilies[idx.coerceIn(0, fontFamilies.size - 1)]
    fun fontWeight(idx: Int): FontWeight = fontWeights[idx.coerceIn(0, fontWeights.size - 1)]

    // iOS Style raw values: 0 plain · 1 glow · 2 shadow · 3 neon · 4 highlight.
    enum class CapStyle { PLAIN, GLOW, SHADOW, NEON, HIGHLIGHT }
    fun styleRaw(style: CapStyle): Int = when (style) {
        CapStyle.PLAIN -> 0; CapStyle.GLOW -> 1; CapStyle.SHADOW -> 2; CapStyle.NEON -> 3; CapStyle.HIGHLIGHT -> 4
    }

    data class Spec(
        val colorIdx: Int = 0,
        val fontIdx: Int = 0,
        val style: CapStyle = CapStyle.GLOW,
        val x: Float = 0.5f,
        val y: Float = 0.5f,
        val size: Float = 1f,
        // Author's media framing (wire fields 6-8): zoom about center + translation as a fraction
        // of the container. Absent on legacy/6-field bodies → identity (no reframing).
        val mediaScale: Float = 1f,
        val mediaOffX: Float = 0f,
        val mediaOffY: Float = 0f,
    )
    data class Decoded(val text: String, val spec: Spec)

    /** Mirror of iOS StoryCaptions.encode — color,font,style,x,y,size,mediaScale,mediaOffX,mediaOffY. */
    fun encode(
        caption: String, colorIdx: Int, fontIdx: Int, style: CapStyle,
        x: Float, y: Float, size: Float,
        mediaScale: Float = 1f, mediaOffX: Float = 0f, mediaOffY: Float = 0f,
    ): String {
        val t = caption.trim()
        val hasTransform = mediaScale != 1f || mediaOffX != 0f || mediaOffY != 0f
        if (t.isEmpty() && !hasTransform) return ""
        val extra = String.format(
            java.util.Locale.US, "%.3f,%.3f,%.3f,%.3f,%.4f,%.4f",
            x, y, size, mediaScale, mediaOffX, mediaOffY,
        )
        return "\u0001$colorIdx,$fontIdx,${styleRaw(style)},$extra\u0001$t"
    }

    fun decode(body: String): Decoded {
        if (!body.startsWith("\u0001")) return Decoded(body, Spec())
        val rest = body.substring(1)
        val sep = rest.indexOf('\u0001')
        if (sep < 0) return Decoded(rest, Spec())
        val n = rest.substring(0, sep).split(",")
        val text = rest.substring(sep + 1)
        var styleRaw = n.getOrNull(2)?.toIntOrNull() ?: 1
        // Back-compat: older stories stored a 0/1 highlight bit in exactly 6 fields.
        if ((styleRaw == 0 || styleRaw == 1) && n.size == 6) styleRaw = if (styleRaw == 1) 4 else 1
        val style = when (styleRaw) {
            0 -> CapStyle.PLAIN; 1 -> CapStyle.GLOW; 2 -> CapStyle.SHADOW; 3 -> CapStyle.NEON
            4 -> CapStyle.HIGHLIGHT; else -> CapStyle.GLOW
        }
        return Decoded(
            text,
            Spec(
                colorIdx = n.getOrNull(0)?.toIntOrNull() ?: 0,
                fontIdx = n.getOrNull(1)?.toIntOrNull() ?: 0,
                style = style,
                x = n.getOrNull(3)?.toFloatOrNull() ?: 0.5f,
                y = n.getOrNull(4)?.toFloatOrNull() ?: 0.5f,
                size = n.getOrNull(5)?.toFloatOrNull() ?: 1f,
                mediaScale = n.getOrNull(6)?.toFloatOrNull() ?: 1f,
                mediaOffX = n.getOrNull(7)?.toFloatOrNull() ?: 0f,
                mediaOffY = n.getOrNull(8)?.toFloatOrNull() ?: 0f,
            ),
        )
    }

    fun color(idx: Int): Color = colors[idx.coerceIn(0, colors.size - 1)]
    /** Highlight text needs a contrasting fill: dark text on light colors (white/cyan/yellow/mint). */
    fun highlightTextColor(idx: Int): Color =
        if (idx.coerceIn(0, colors.size - 1) in listOf(0, 9, 10, 11)) Color.Black else Color.White
}
