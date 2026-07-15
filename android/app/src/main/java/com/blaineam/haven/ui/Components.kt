package com.blaineam.haven.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.min

/** The Haven mark: a little constellation of connected people (matches the app icon). Defaults to the
 *  theme's primary ink; callers drawing it on a fixed dark surface (the call screen) pass white. */
@Composable
fun ConstellationMark(modifier: Modifier = Modifier, color: Color = HavenTheme.textPrimary) {
    val nodes = listOf(
        Offset(50f, 53f), Offset(50f, 24f), Offset(23f, 46f),
        Offset(77f, 46f), Offset(34f, 75f), Offset(66f, 75f),
    )
    val edges = listOf(0 to 1, 0 to 2, 0 to 3, 0 to 4, 0 to 5, 1 to 2, 1 to 3, 2 to 4, 3 to 5)
    Canvas(modifier) {
        val s = min(size.width, size.height) / 100f
        fun p(o: Offset) = Offset(o.x * s, o.y * s)
        edges.forEach { (a, b) ->
            drawLine(color.copy(alpha = 0.65f), p(nodes[a]), p(nodes[b]), strokeWidth = 1.6f * s)
        }
        nodes.forEachIndexed { i, n ->
            drawCircle(color, radius = (if (i == 0) 7f else 5f) * s, center = p(n))
        }
    }
}

/** A prominent brand-gradient pill button. */
@Composable
fun BrandButton(
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .fillMaxWidth()
            .background(HavenTheme.brandHorizontal, RoundedCornerShape(50))
            .clickable(enabled = enabled) { onClick() }
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            // White-on-brand-gradient — never themed.
            color = Color.White.copy(alpha = if (enabled) 1f else 0.6f),
            fontWeight = FontWeight.SemiBold,
            fontSize = 16.sp,
        )
    }
}

/** Gradient title text helper (approximated with the brand pink — Compose can't fill text
 *  with a Brush before API differences, so we use the dominant brand hue). */
@Composable
fun BrandText(text: String, modifier: Modifier = Modifier, fontSize: Int = 34) {
    Text(
        text,
        modifier = modifier,
        color = HavenTheme.pink,
        fontWeight = FontWeight.Bold,
        fontSize = fontSize.sp,
        textAlign = TextAlign.Center,
    )
}
