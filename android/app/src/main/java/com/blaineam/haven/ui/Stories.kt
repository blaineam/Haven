package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.DEFAULT_CIRCLE
import kotlinx.coroutines.delay
import uniffi.haven_ffi.FeedItemFfi

/** One author's active stories, grouped for the tray + viewer. */
data class StoryGroup(val authorShort: String, val isMe: Boolean, val items: List<FeedItemFfi>)

/** Story age, matching iOS `relativeTimeShort` — stories only ever live 24h, so m/h is enough. */
private fun storyAge(createdAtMs: ULong): String {
    val secs = (System.currentTimeMillis() - createdAtMs.toLong()) / 1000
    return when {
        secs < 5 -> "now"
        secs < 60 -> "${secs}s"
        secs < 3600 -> "${secs / 60}m"
        secs < 86_400 -> "${secs / 3600}h"
        else -> "${secs / 86_400}d"
    }
}

fun groupStories(items: List<FeedItemFfi>): List<StoryGroup> =
    items.filter { it.story }
        .groupBy { it.authorShort }
        .map { (author, list) ->
            StoryGroup(author, list.first().isMe, list.sortedBy { it.createdAt })
        }
        .sortedByDescending { it.isMe }

/** Horizontal ring tray at the top of the feed. The first ring is "your story" (+). */
@Composable
fun StoriesTray(groups: List<StoryGroup>, onAddStory: () -> Unit, onOpen: (Int) -> Unit) {
    LazyRow(
        Modifier.fillMaxWidth().padding(vertical = 6.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.size(64.dp).clip(CircleShape).background(HavenTheme.card).clickable { onAddStory() },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Add, "Add to your story", tint = HavenTheme.pink) }
                Spacer(Modifier.height(4.dp))
                androidx.compose.material3.Text("Your story", color = HavenTheme.textSecondary, fontSize = 11.sp)
            }
        }
        items(groups.size) { idx ->
            val g = groups[idx]
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.size(64.dp).clip(CircleShape)
                        .background(HavenTheme.brandHorizontal).clickable { onOpen(idx) },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier.size(56.dp).clip(CircleShape).background(HavenTheme.card),
                        contentAlignment = Alignment.Center,
                    ) {
                        val first = g.items.firstOrNull()
                        val mediaId = first?.media?.firstOrNull()
                        if (mediaId != null) {
                            MediaImage(DEFAULT_CIRCLE, mediaId, Modifier.size(56.dp).clip(CircleShape))
                        } else {
                            androidx.compose.material3.Text(
                                if (g.isMe) "You" else g.authorShort.take(2),
                                color = HavenTheme.textPrimary, fontSize = 13.sp,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(4.dp))
                androidx.compose.material3.Text(
                    if (g.isMe) "You" else com.blaineam.haven.core.HavenNet.displayName(g.authorShort),
                    color = HavenTheme.textPrimary, fontSize = 11.sp, maxLines = 1,
                )
            }
        }
    }
}

/** Full-screen story viewer: progress bars, tap right/left to advance, auto-advance. */
/** A small translucent pill button for the story header (Keep / Delete). */
@Composable
private fun StoryActionChip(label: String, onClick: () -> Unit) {
    androidx.compose.material3.Text(
        // Story chrome sits on the story media — always white.
        label, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(50))
            .background(Color.White.copy(alpha = 0.22f))
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 5.dp),
    )
}

@Composable
fun StoryViewer(groups: List<StoryGroup>, startGroup: Int, onClose: () -> Unit, startItem: Int = 0) {
    var groupIdx by remember { mutableIntStateOf(startGroup) }
    var itemIdx by remember { mutableIntStateOf(startItem) }
    var replyText by remember { mutableStateOf("") }
    var replying by remember { mutableStateOf(false) }   // pauses auto/tap-advance while typing
    var confirmDelete by remember { mutableStateOf(false) }
    var sentNote by remember { mutableStateOf(false) }
    val group = groups.getOrNull(groupIdx) ?: run { onClose(); return }
    val item = group.items.getOrNull(itemIdx) ?: run { onClose(); return }

    fun advance() {
        if (itemIdx + 1 < group.items.size) itemIdx++
        else if (groupIdx + 1 < groups.size) { groupIdx++; itemIdx = 0 }
        else onClose()
    }
    fun back() {
        if (itemIdx > 0) itemIdx--
        else if (groupIdx > 0) { groupIdx--; itemIdx = 0 }
    }

    // Auto-advance every 5s (paused while replying).
    LaunchedEffect(groupIdx, itemIdx, replying) {
        if (replying) return@LaunchedEffect
        delay(5000)
        advance()
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .pointerInput(groupIdx, itemIdx) {
                detectTapGestures(
                    onTap = { o -> if (!replying) { if (o.x > size.width / 2) advance() else back() } },
                    onLongPress = { onClose() },
                )
            },
    ) {
        val mediaId = item.media.firstOrNull()
        if (mediaId != null) {
            // Honors a flag federated by a member whose platform has an analyzer. cornerRadius 0 —
            // a story is full-bleed, exactly as iOS passes it (Stories.swift:123).
            SensitiveGuard(DEFAULT_CIRCLE, mediaId, cornerRadius = 0) { covered ->
                // A video story must play in a video view, not the image decoder (was rendering nothing).
                if (com.blaineam.haven.core.LocalMedia.isVideo(mediaId)) {
                    // A blur hides the picture, not the sound — don't play a covered story.
                    if (covered) Box(Modifier.fillMaxSize().background(HavenTheme.card))
                    else VideoTile(DEFAULT_CIRCLE, mediaId, Modifier.fillMaxSize())
                } else {
                    // MediaImage defaults to FillWidth, which letterboxed the story into black bands.
                    // A story is full-bleed on iOS (scaledToFill), so crop to the frame instead.
                    MediaImage(DEFAULT_CIRCLE, mediaId, Modifier.fillMaxSize(), ContentScale.Crop)
                }
            }
        }
        // Decode the iOS-authored caption (was shown raw → gibberish): position + colour it, with
        // a highlight pill if that's the style.
        val decoded = StoryCaptions.decode(item.body)
        if (decoded.text.isNotBlank()) {
            val spec = decoded.spec
            val isHl = spec.style == StoryCaptions.CapStyle.HIGHLIGHT
            val cfg = androidx.compose.ui.platform.LocalConfiguration.current
            val w = cfg.screenWidthDp.dp; val h = cfg.screenHeightDp.dp
            // NEON draws WHITE text with a colored halo (iOS parity); highlight gets contrast text.
            val baseColor = StoryCaptions.color(spec.colorIdx)
            val textColor = when {
                isHl -> StoryCaptions.highlightTextColor(spec.colorIdx)
                spec.style == StoryCaptions.CapStyle.NEON -> Color.White
                else -> baseColor
            }
            // Effect radii/offsets tuned to visually match the iOS renderer (Compose has ONE shadow
            // per TextStyle, so each style uses its dominant iOS layer): plain=black r4 legibility
            // shadow, glow=soft self-colored r8, shadow=tight black r2 offset(1.5,2)pt, neon=big
            // colored halo (iOS layers r6+r14 → r14 dominant).
            val captionShadow = when (spec.style) {
                StoryCaptions.CapStyle.PLAIN -> androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.55f), androidx.compose.ui.geometry.Offset.Zero, 4f * 3f)
                StoryCaptions.CapStyle.GLOW -> androidx.compose.ui.graphics.Shadow(baseColor.copy(alpha = 0.9f), androidx.compose.ui.geometry.Offset.Zero, 8f * 3f)
                StoryCaptions.CapStyle.NEON -> androidx.compose.ui.graphics.Shadow(baseColor, androidx.compose.ui.geometry.Offset.Zero, 14f * 3f)
                StoryCaptions.CapStyle.SHADOW -> androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.85f), androidx.compose.ui.geometry.Offset(1.5f * 3f, 2f * 3f), 2f * 3f)
                else -> null
            }
            androidx.compose.material3.Text(
                decoded.text,
                color = textColor,
                fontSize = (28 * spec.size).sp,
                fontWeight = StoryCaptions.fontWeight(spec.fontIdx),
                fontFamily = StoryCaptions.fontFamily(spec.fontIdx),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                style = androidx.compose.ui.text.TextStyle(shadow = captionShadow),
                modifier = Modifier.align(Alignment.Center)
                    .offset(x = w * (spec.x - 0.5f), y = h * (spec.y - 0.5f))
                    .then(if (isHl) Modifier.clip(RoundedCornerShape(8.dp)).background(StoryCaptions.color(spec.colorIdx)) else Modifier)
                    .padding(horizontal = if (isHl) 10.dp else 24.dp, vertical = if (isHl) 3.dp else 0.dp),
            )
        }
        // Progress bars (one per story in this group).
        Row(
            Modifier.fillMaxWidth().padding(top = 14.dp, start = 10.dp, end = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            group.items.indices.forEach { i ->
                Box(
                    Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp))
                        .background(if (i <= itemIdx) Color.White else Color.White.copy(alpha = 0.3f)),
                )
            }
        }
        // Who + when, over the media (iOS parity: avatar, name, age). Always white — this sits on
        // the story itself, not on a themed surface.
        Row(
            Modifier.align(Alignment.TopStart).padding(start = 14.dp, top = 26.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val authorName = if (group.isMe) "You"
                else com.blaineam.haven.core.HavenNet.displayName(group.authorShort)
            HavenAvatar(group.authorShort, authorName, 28.dp, isMe = group.isMe)
            androidx.compose.material3.Text(
                if (group.isMe) "Your story" else authorName,
                color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            )
            androidx.compose.material3.Text(
                storyAge(item.createdAt), color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp,
            )
        }
        Row(
            Modifier.align(Alignment.TopEnd).padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (group.isMe) {
                // Keep: turn this disappearing story into a permanent post (iOS parity).
                StoryActionChip("Keep") {
                    val text = StoryCaptions.decode(item.body).text
                    com.blaineam.haven.core.HavenNet.post(
                        com.blaineam.haven.core.DEFAULT_CIRCLE, text, item.media, item.music, null)
                    onClose()
                }
                // Delete: unsend my own story everywhere it was shared.
                StoryActionChip("Delete") { confirmDelete = true }
            }
            androidx.compose.material3.Text(
                "✕", color = Color.White, fontSize = 22.sp,
                modifier = Modifier.clickable { onClose() },
            )
        }
        if (confirmDelete) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { confirmDelete = false },
                containerColor = HavenTheme.card,
                title = { androidx.compose.material3.Text("Delete this story?", color = HavenTheme.textPrimary) },
                text = { androidx.compose.material3.Text("It will be removed from your story and for everyone you shared it with.", color = HavenTheme.textSecondary) },
                confirmButton = {
                    androidx.compose.material3.TextButton(onClick = {
                        com.blaineam.haven.core.HavenNet.unsendPost(com.blaineam.haven.core.DEFAULT_CIRCLE, item.id)
                        confirmDelete = false; onClose()
                    }) { androidx.compose.material3.Text("Delete story", color = Color(0xFFEF4444)) }
                },
                dismissButton = {
                    androidx.compose.material3.TextButton(onClick = { confirmDelete = false }) {
                        androidx.compose.material3.Text("Cancel", color = HavenTheme.pink)
                    }
                },
            )
        }

        // Reply privately — DMs the author with this story attached so they know which one.
        //
        // KNOWN BROKEN (needs a caller fix): the padding below is a no-op. This viewer is hosted in
        // FullScreenOverlay's Compose Dialog, whose window reports every inset as zero — measured on
        // a Pixel 8: navBottom=0 imeBottom=0 statusTop=0, with the root Box spanning the full 2399px
        // screen. So this row is laid out under the gesture pill (reply field measured 32px tall)
        // and cannot lift above the IME. The fix belongs in FullScreenOverlay (CircleScreen.kt):
        // DialogProperties(..., decorFitsSystemWindows = false), which restores inset dispatch and
        // makes these two modifiers behave as written. Deliberately NOT worked around with a manual
        // inset here — that would double-pad the row the moment the Dialog is fixed.
        if (!group.isMe) {
            Row(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().imePadding()
                    .padding(horizontal = 14.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicTextField(
                    value = replyText, onValueChange = { replyText = it },
                    textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                    cursorBrush = SolidColor(HavenTheme.pink),
                    modifier = Modifier.weight(1f).onFocusChanged { replying = it.isFocused }
                        .clip(RoundedCornerShape(24.dp)).border(1.dp, Color.White.copy(alpha = 0.45f), RoundedCornerShape(24.dp))
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    decorationBox = { inner ->
                        if (replyText.isEmpty()) androidx.compose.material3.Text(
                            "Reply to ${com.blaineam.haven.core.HavenNet.displayName(group.authorShort)}…",
                            color = Color.White.copy(alpha = 0.6f), fontSize = 15.sp)
                        inner()
                    },
                )
                if (replyText.isNotBlank()) {
                    Spacer(Modifier.size(8.dp))
                    Box(Modifier.size(44.dp).clip(CircleShape).background(HavenTheme.brandHorizontal).clickable {
                        com.blaineam.haven.core.HavenNet.replyToStory(group.authorShort, item.media.firstOrNull(), replyText.trim())
                        replyText = ""; replying = false; sentNote = true
                    }, contentAlignment = Alignment.Center) {
                        androidx.compose.material3.Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Color.White)
                    }
                }
            }
        }
        if (sentNote) {
            LaunchedEffect(Unit) { delay(1600); sentNote = false }
            androidx.compose.material3.Text(
                "Sent privately ✓", color = Color.White, fontSize = 14.sp,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 84.dp)
                    .clip(RoundedCornerShape(20.dp)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
    }
}
