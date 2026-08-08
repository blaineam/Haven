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
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
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
                ) { Icon(Icons.Filled.Add, stringResource(R.string.story_add_to_your_story), tint = HavenTheme.pink) }
                Spacer(Modifier.height(4.dp))
                androidx.compose.material3.Text(stringResource(R.string.story_your_story), color = HavenTheme.textSecondary, fontSize = 11.sp)
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
                    // The feed ring is an IDENTITY chip → show the sharer's profile picture (mine, or the
                    // friend's synced avatar), not the story media. The media is what you see when you open
                    // it; the "Your stories" gallery (You tab) is the one that shows per-story content
                    // thumbnails. (iOS parity: FeedView.storyThumb.)
                    HavenAvatar(
                        g.authorShort,
                        if (g.isMe) stringResource(R.string.story_you) else com.blaineam.haven.core.HavenNet.displayName(g.authorShort),
                        56.dp, isMe = g.isMe,
                    )
                }
                Spacer(Modifier.height(4.dp))
                androidx.compose.material3.Text(
                    if (g.isMe) stringResource(R.string.story_you) else com.blaineam.haven.core.HavenNet.displayName(g.authorShort),
                    color = HavenTheme.textPrimary, fontSize = 11.sp, maxLines = 1,
                )
            }
        }
    }
}

/** Full-screen story viewer: progress bars, tap right/left to advance, auto-advance. */
/** A small translucent pill button for the story header (Keep / Delete).
 *
 *  [tint] colours the label so a toggle's state is legible at a glance — a control that looks
 *  identical whether or not it is on reads as a dead button, which is exactly the complaint Keep
 *  drew. Wrapped in [minimumInteractiveComponentSize] so the tappable area is the platform minimum
 *  rather than the drawn glyph: these sit over a full-screen gesture surface, and a hit region that
 *  collapses to the text is how a control ends up showing its press effect and doing nothing. */
@Composable
private fun StoryActionChip(label: String, tint: Color = Color.White, onClick: () -> Unit) {
    Box(
        Modifier.minimumInteractiveComponentSize(),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.material3.Text(
            // Story chrome sits on the story media — always white unless a toggle tints it.
            label, color = tint, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(50))
                .background(Color.White.copy(alpha = 0.22f))
                .clickable { onClick() }
                .padding(horizontal = 12.dp, vertical = 5.dp),
        )
    }
}

/**
 * The song attached to a story, over the story. Names the track while it plays and opens the real
 * one on tap — the 30s preview Android can play is a taste, not the record.
 *
 * [resolved] is the viewer's already-completed lookup, passed in rather than re-fetched: this pill
 * must not turn one resolve into two.
 */
@Composable
private fun StorySongPill(
    music: uniffi.haven_ffi.TrackRefFfi,
    resolved: com.blaineam.haven.core.MusicSearch.Track?,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val art = rememberArtwork(music.artworkUrl.ifBlank { resolved?.artworkUrl })
    // The store link when the author's client sent one (iOS sends a catalog id, desktop a URL),
    // otherwise the resolved preview's, otherwise a search for the title and artist.
    val q = remember(music.title, music.artist) {
        java.net.URLEncoder.encode("${music.title} ${music.artist}".trim(), "UTF-8")
    }
    val link = when {
        music.catalogId.startsWith("http") -> music.catalogId
        !resolved?.storeUrl.isNullOrBlank() -> resolved.storeUrl
        else -> "https://music.apple.com/search?term=$q"
    }
    Row(
        modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.42f))
            .clickable { openExternal(context, link) }
            .padding(start = 6.dp, end = 12.dp, top = 5.dp, bottom = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(Modifier.size(22.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center) {
            if (art != null) {
                androidx.compose.foundation.Image(
                    art, null, Modifier.size(22.dp),
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                )
            } else {
                Icon(Icons.Filled.MusicNote, null, tint = Color.White, modifier = Modifier.size(13.dp))
            }
        }
        androidx.compose.material3.Text(
            listOf(music.title, music.artist).filter { it.isNotBlank() }.joinToString(" · "),
            color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
            maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            modifier = Modifier.widthIn(max = 190.dp),
        )
    }
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
    // Instagram-style whole-user skips (a horizontal swipe, vs a tap that advances one story).
    // Left → the next person's first story (dismiss past the last person).
    fun skipToNextUser() {
        if (groupIdx + 1 < groups.size) { groupIdx++; itemIdx = 0 } else onClose()
    }
    // Right → restart this person if we're partway in, otherwise the previous person's first story.
    fun skipToPrevUser() {
        if (itemIdx > 0) itemIdx = 0
        else if (groupIdx > 0) { groupIdx--; itemIdx = 0 }
    }

    // HOLD to pause, release to resume. Press-and-hold used to CLOSE the viewer, which is neither
    // what the phones' story viewers do nor what anyone expects from holding a story.
    var heldPaused by remember { mutableStateOf(false) }

    // Auto-advance every 5s (paused while replying, or while held).
    LaunchedEffect(groupIdx, itemIdx, replying, heldPaused) {
        if (replying || heldPaused) return@LaunchedEffect
        delay(5000)
        advance()
    }

    // ── The author's song plays while you watch ──────────────────────────────────────────────────
    //
    // What Android can actually play is a 30s preview, not the track: there is no Apple Music
    // library to drive, so the song is resolved to an iTunes preview by title+artist, exactly as the
    // feed chip already does. Short of Apple's full-track playback, and honestly so — the pill says
    // "Preview" and offers to open the real thing.
    //
    // BOUNDED, because this is a network fetch triggered by watching a peer's content:
    //   · Keyed on the TRACK, not the story index, so flicking through a tray resolves once per
    //     distinct song rather than once per tap — and a run of stories sharing a song plays
    //     straight through instead of restarting on each advance.
    //   · Changing stories cancels the coroutine, so lookups never stack up.
    //   · MusicSearch.resolve is a bounded LRU that caches MISSES too, so an unresolvable song is
    //     asked about once, and the underlying request carries an 8s timeout.
    val storyContext = androidx.compose.ui.platform.LocalContext.current
    val music = item.music
    var preview by remember(music?.title, music?.artist) {
        mutableStateOf<com.blaineam.haven.core.MusicSearch.Track?>(null)
    }
    LaunchedEffect(music?.title, music?.artist) {
        if (music == null) { MusicPlayer.stop(); return@LaunchedEffect }
        // Stop the outgoing song before the lookup, or the previous story's music keeps playing
        // over this one for as long as the fetch takes.
        MusicPlayer.stop()
        val t = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.blaineam.haven.core.MusicSearch.resolve(music.title, music.artist)
        }
        preview = t
        t?.previewUrl?.let { MusicPlayer.play(storyContext, it) }
    }
    // Holding the story still holds the song still — the video pauses, and music that kept going
    // under a frozen frame would read as a bug.
    LaunchedEffect(heldPaused, replying) { MusicPlayer.setUserPaused(heldPaused || replying) }
    // Leaving the viewer by ANY route — close, swipe past the end, back out — takes the song with
    // it. Without this the story's music outlives the story.
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { MusicPlayer.stop() } }

    Box(Modifier.fillMaxSize().consumesTaps().background(Color.Black)) {
        // The navigation gestures live on THIS layer — the media, drawn beneath the controls — not on
        // the root Box that is an ancestor of every control.
        //
        // A drag recognizer on an ancestor of a button delays and then CANCELS the button's action:
        // the control highlights on touch-down and then does nothing, which is exactly how Keep and
        // Delete failed. Compose hit-tests child-first, so a perfectly clean tap on a chip was
        // consumed by the chip — but any few-px movement during the press was claimed by the
        // ancestor's horizontal-drag detector, which cancelled the chip's click. With the gestures
        // scoped to the media layer the controls have no gesture-bearing ancestor at all.
        Box(
            Modifier.fillMaxSize()
                .pointerInput(groupIdx, itemIdx, replying) {
                    detectTapGestures(
                        onTap = { o -> if (!replying) { if (o.x > size.width / 2) advance() else back() } },
                        // Hold-to-pause. `tryAwaitRelease` returns false when the press is CANCELLED
                        // (another gesture won the sequence) rather than throwing past the reset, so
                        // the pause always resolves — a paused-forever story was the failure mode on
                        // the Apple side when the release lived in a competing gesture's onEnded.
                        onPress = {
                            heldPaused = true
                            tryAwaitRelease()
                            heldPaused = false
                        },
                    )
                }
                // A horizontal SWIPE skips WHOLE users (Instagram-style), matching iOS Stories.swift
                // skipToNextUser/skipToPrevUser. Tap still advances one story at a time (above).
                .pointerInput(groupIdx, itemIdx) {
                    var dx = 0f
                    detectHorizontalDragGestures(
                        onDragStart = { dx = 0f },
                        onHorizontalDrag = { _, amount -> dx += amount },
                        onDragEnd = { if (dx <= -60f) skipToNextUser() else if (dx >= 60f) skipToPrevUser() },
                    )
                },
        ) {
        // Decoded once: the spec carries the caption style AND the author's media framing.
        val decoded = StoryCaptions.decode(item.body)
        // NOT media.first. A video story ships its poster still, published FIRST
        // ([poster, posterMarker, clip]), so the raw head is the poster — rendering it would show a
        // video story as a frozen frame. displayRefs drops posters/thumbs/originals/markers and
        // leaves the playable ref. Parity with Apple StoryViewer.displayRef.
        val mediaId = com.blaineam.haven.core.MediaVariants.displayRefs(item.media).firstOrNull()
            ?: item.media.firstOrNull()
        if (mediaId != null) {
            // The author's framing (zoom + pan) rides the caption spec — same application as iOS
            // (Stories.swift:120-121): scale about center, THEN translate by offX/offY fractions of
            // the container. graphicsLayer translation is unscaled parent-space px, matching
            // SwiftUI's .scaleEffect().offset() order.
            val tf = decoded.spec
            // Blurred backdrop beneath the framed media: an author who zoomed OUT (scale below 1)
            // deliberately stopped short of filling the frame so the item shows whole, and it should
            // sit over its own colors rather than over black bars. Only drawn when it can actually be
            // seen — at scale >= 1 the media covers it and this would be a wasted second decode.
            if (tf.mediaScale < 1f && !com.blaineam.haven.core.LocalMedia.isVideo(mediaId)) {
                MediaImage(DEFAULT_CIRCLE, mediaId,
                    Modifier.fillMaxSize().blur(36.dp).alpha(0.6f), ContentScale.Crop)
            }
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    // Scale → rotate → move, the order the composer applies them and the order the
                    // author's fingers did it in, so a story looks the same everywhere it's viewed.
                    scaleX = tf.mediaScale
                    scaleY = tf.mediaScale
                    rotationZ = Math.toDegrees(tf.mediaRotation.toDouble()).toFloat()
                    translationX = tf.mediaOffX * size.width
                    translationY = tf.mediaOffY * size.height
                },
            ) {
                // Honors a flag federated by a member whose platform has an analyzer. cornerRadius 0 —
                // a story is full-bleed, exactly as iOS passes it (Stories.swift:123).
                SensitiveGuard(DEFAULT_CIRCLE, mediaId, cornerRadius = 0) { covered ->
                    // A video story must play in a video view, not the image decoder (was rendering nothing).
                    if (com.blaineam.haven.core.LocalMedia.isVideo(mediaId)) {
                        // A blur hides the picture, not the sound — don't play a covered story.
                        if (covered) Box(Modifier.fillMaxSize().background(HavenTheme.card))
                        // Silent under the author's song, and silent if they muted it outright
                        // (muteVideo rode the wire unread until now). See VideoTile's forceMuted for
                        // why muting is sufficient here and the Apple video-only strip is not needed.
                        else VideoTile(DEFAULT_CIRCLE, mediaId, Modifier.fillMaxSize(),
                            forceMuted = item.music != null || item.muteVideo)
                    } else {
                        // MediaImage defaults to FillWidth, which letterboxed the story into black bands.
                        // A story is full-bleed on iOS (scaledToFill), so crop to the frame instead.
                        MediaImage(DEFAULT_CIRCLE, mediaId, Modifier.fillMaxSize(), ContentScale.Crop)
                    }
                }
            }
        }
        // The iOS-authored caption (was shown raw → gibberish): position + colour it, with
        // a highlight pill if that's the style.
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
        }   // ← end of the MEDIA layer. Everything below is chrome/controls, deliberately OUTSIDE it
            //   so no control has a gesture-bearing ancestor (see the note on the media layer).
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
            val authorName = if (group.isMe) stringResource(R.string.story_you)
                else com.blaineam.haven.core.HavenNet.displayName(group.authorShort)
            HavenAvatar(group.authorShort, authorName, 28.dp, isMe = group.isMe)
            androidx.compose.material3.Text(
                if (group.isMe) stringResource(R.string.story_your_story) else authorName,
                color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            )
            androidx.compose.material3.Text(
                storyAge(item.createdAt), color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp,
            )
        }
        // The song, named. Sits just under the author row and outside the gesture layer, so tapping
        // it opens the track rather than advancing the story.
        if (music != null) {
            StorySongPill(
                music = music,
                resolved = preview,
                modifier = Modifier.align(Alignment.TopStart).padding(start = 14.dp, top = 62.dp),
            )
        }
        Row(
            Modifier.align(Alignment.TopEnd).padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (group.isMe) {
                // KEEP is a TOGGLE that holds this story on MY PROFILE past the 24h window — it does
                // NOT re-publish it. It used to create a permanent post, which put the story back in
                // the circle feed as a new thing everyone saw again; wanting to hold on to something
                // yourself is a different act from sharing it twice. A kept story still leaves
                // everyone's story row on schedule — only profile surfaces revive the snapshot.
                //
                // Reading `version` here is what makes the chip recompose the instant it's toggled;
                // without it the label would never change and a working toggle would read as a dead
                // button, which is precisely the complaint this replaced.
                @Suppress("UNUSED_EXPRESSION") com.blaineam.haven.core.KeptStoriesStore.version.intValue
                val isKept = com.blaineam.haven.core.KeptStoriesStore.isKept(item.id)
                StoryActionChip(
                    if (isKept) stringResource(R.string.story_kept) else stringResource(R.string.story_keep),
                    tint = if (isKept) HavenTheme.pink else Color.White,
                ) {
                    com.blaineam.haven.core.KeptStoriesStore.toggle(
                        id = item.id,
                        body = item.body,
                        media = item.media,
                        createdAt = item.createdAt.toLong(),
                        music = item.music,
                    )
                }
                // Delete: unsend my own story everywhere it was shared.
                StoryActionChip(stringResource(R.string.common_delete)) { confirmDelete = true }
            }
            // The close glyph needs a real hit target: a bare 22sp Text with .clickable is tappable
            // only across the drawn glyph, far under the platform minimum, so most taps missed it.
            Box(
                Modifier.minimumInteractiveComponentSize().clip(CircleShape).clickable { onClose() },
                contentAlignment = Alignment.Center,
            ) {
                androidx.compose.material3.Text("✕", color = Color.White, fontSize = 22.sp)
            }
        }
        if (confirmDelete) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { confirmDelete = false },
                containerColor = HavenTheme.card,
                title = { androidx.compose.material3.Text(stringResource(R.string.story_delete_confirm_title), color = HavenTheme.textPrimary) },
                text = { androidx.compose.material3.Text(stringResource(R.string.story_delete_confirm_message), color = HavenTheme.textSecondary) },
                confirmButton = {
                    androidx.compose.material3.TextButton(onClick = {
                        com.blaineam.haven.core.HavenNet.unsendPost(com.blaineam.haven.core.DEFAULT_CIRCLE, item.id)
                        confirmDelete = false; onClose()
                    }) { androidx.compose.material3.Text(stringResource(R.string.story_delete_story), color = Color(0xFFEF4444)) }
                },
                dismissButton = {
                    androidx.compose.material3.TextButton(onClick = { confirmDelete = false }) {
                        androidx.compose.material3.Text(stringResource(R.string.common_cancel), color = HavenTheme.pink)
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
                            stringResource(R.string.story_reply_placeholder, com.blaineam.haven.core.HavenNet.displayName(group.authorShort)),
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
                        androidx.compose.material3.Icon(Icons.AutoMirrored.Filled.Send, stringResource(R.string.common_send), tint = Color.White)
                    }
                }
            }
        }
        if (sentNote) {
            LaunchedEffect(Unit) { delay(1600); sentNote = false }
            androidx.compose.material3.Text(
                stringResource(R.string.story_sent_privately), color = Color.White, fontSize = 14.sp,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 84.dp)
                    .clip(RoundedCornerShape(20.dp)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
    }
}
