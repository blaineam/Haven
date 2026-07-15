package com.blaineam.haven.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet

/**
 * Honors the circle's federated sensitive-content flags.
 *
 * Apple platforms run the on-device analyzer (`SensitiveContentAnalysis`) and federate a
 * `SensitiveFlag` event to the circle precisely so members whose platform has NO classifier can
 * still blur — see `apple/HavenApp/SensitiveContent.swift`. Android has no system equivalent, so we
 * author no flags, but we HONOR every one we receive. Without this a poster marks something
 * sensitive on their iPhone and it lands full-frame on their friend's Android.
 *
 * The federated set is authoritative for EVERY ref in it, including your own posts: iOS's `scan`
 * parameter gates only whether the LOCAL analyzer runs, never whether a received flag blurs.
 */
object SensitiveFlags {
    /** refs per circle, cached like FeedStore.sensitiveCache — the FFI call walks the event log. */
    private val cache = HashMap<String, Set<String>>()
    private var version = -1

    /** Flagged refs for [circleId]. Cheap + cached; recomputed when the feed changes. */
    fun refs(circleId: String): Set<String> {
        val v = HavenNet.feedVersion.value
        if (v != version) { cache.clear(); version = v }   // a new event may BE a flag
        return cache.getOrPut(circleId) {
            runCatching { HavenNet.engine.sensitiveRefs(circleId).toSet() }.getOrDefault(emptySet())
        }
    }

    fun isSensitive(circleId: String, ref: String): Boolean = refs(circleId).contains(ref)
}

/**
 * Blurs [content] behind a "Sensitive Content / Tap to view" cover while [ref] is flagged in
 * [circleId], until the viewer taps to reveal. Copy + interaction match the iOS guard.
 *
 * Wrap the media where iOS wraps it (feed pages/tiles, chat bubbles, stories) — NOT the full-screen
 * viewer, which you only reach by a deliberate tap after revealing, same as iOS.
 *
 * [content] receives whether it is currently covered, so a caller can suppress work that a blur
 * can't hide — a video must not autoplay (with sound) behind the cover.
 */
@Composable
fun SensitiveGuard(
    circleId: String,
    ref: String,
    cornerRadius: Int = 10,
    content: @Composable (covered: Boolean) -> Unit,
) {
    val flagged = SensitiveFlags.isSensitive(circleId, ref)
    var revealed by remember(ref, circleId) { mutableStateOf(false) }
    val covered = flagged && !revealed
    Box {
        // Blur the media ITSELF, not just a scrim over it — a translucent panel you can read through
        // is a broken promise, not a cosmetic bug.
        Box(if (covered) Modifier.blur(22.dp) else Modifier) { content(covered) }
        // matchParentSize (BoxScope) sizes the cover to the MEDIA. fillMaxSize would resolve against
        // the parent's max constraints instead and spill past a tile that measured smaller.
        Box(Modifier.matchParentSize()) {
            AnimatedVisibility(visible = covered, exit = fadeOut(tween(200))) {
                Box(
                    Modifier.fillMaxSize()
                        .clip(RoundedCornerShape(cornerRadius.dp))
                        .background(HavenTheme.card.copy(alpha = 0.72f))
                        // No ripple + consume the tap: the FIRST tap reveals, it must not also open
                        // the viewer or trip the feed's double-tap-to-react.
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                            revealed = true
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(5.dp),
                        modifier = Modifier.padding(8.dp),
                    ) {
                        Icon(Icons.Filled.VisibilityOff, null, tint = HavenTheme.textSecondary, modifier = Modifier.size(22.dp))
                        Text("Sensitive Content", color = HavenTheme.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        Text("Tap to view", color = HavenTheme.textSecondary, fontSize = 11.sp)
                    }
                }
            }
        }
    }
}
