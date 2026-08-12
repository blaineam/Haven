package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.CircleSettings
import com.blaineam.haven.core.DeepLink
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.KeptStoriesStore
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.MediaVariants
import com.blaineam.haven.core.StoryLinkInbox
import com.blaineam.haven.core.nowMs
import kotlinx.coroutines.delay
import uniffi.haven_ffi.FeedItemFfi

/**
 * Deep-linked story (`haven://s/…` or web `#s/…`) — parity with iOS `StoryLinkView`.
 * Live story → full StoryViewer (music, framing, progress). Author-kept snapshot after
 * the 24h window still opens. Otherwise "Story expired".
 */
@Composable
fun StoryLinkScreen(circleId: String, postId: String, onDone: () -> Unit) {
    androidx.activity.compose.BackHandler { onDone() }
    val version by HavenNet.feedVersion
    @Suppress("UNUSED_EXPRESSION") KeptStoriesStore.version.intValue
    var settled by remember { mutableStateOf(false) }

    val resolved = remember(version, circleId, postId, KeptStoriesStore.version.intValue) {
        resolveStory(circleId, postId)
    }

    LaunchedEffect(circleId, postId) {
        if (resolved != null) { settled = true; return@LaunchedEffect }
        var grace = 4.0
        var ticks = 0
        while (grace > 0 && ticks < 80) {
            if (resolveStory(circleId, postId) != null) { settled = true; return@LaunchedEffect }
            delay(250)
            ticks++
            grace -= 0.25
        }
        settled = true
    }

    if (resolved != null) {
        // Single-story group so the viewer has progress bars / music / reply chrome.
        val group = StoryGroup(
            authorShort = resolved.authorShort,
            isMe = resolved.isMe,
            items = listOf(resolved),
        )
        StoryViewer(groups = listOf(group), startGroup = 0, onClose = onDone)
    } else if (!settled) {
        Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = HavenTheme.pink)
        }
    } else {
        Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.padding(32.dp),
            ) {
                Text("⏱", fontSize = 40.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    stringResource(R.string.story_no_longer_available),
                    color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    stringResource(R.string.story_expired_body),
                    color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                Text(
                    stringResource(R.string.common_done),
                    color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .clickable { onDone() }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
            }
        }
    }
}

/**
 * Tall portrait tile for a story reference in a DM bubble — parity with iOS `StoryReplyCard`.
 * Tap opens [StoryLinkInbox] → [StoryLinkScreen].
 */
@Composable
fun StoryReplyCard(circleId: String, postId: String, modifier: Modifier = Modifier) {
    val version by HavenNet.feedVersion
    @Suppress("UNUSED_EXPRESSION") KeptStoriesStore.version.intValue
    var settled by remember { mutableStateOf(false) }
    val story = remember(version, circleId, postId, KeptStoriesStore.version.intValue) {
        resolveStory(circleId, postId)
    }
    LaunchedEffect(circleId, postId) {
        if (story != null) { settled = true; return@LaunchedEffect }
        delay(1500)
        settled = true
    }
    val width = 128.dp
    val openable = story != null
    Box(
        modifier
            .width(width)
            .aspectRatio(9f / 16f)
            .clip(RoundedCornerShape(14.dp))
            .background(HavenTheme.card)
            .then(
                if (openable) Modifier.clickable {
                    StoryLinkInbox.offer(DeepLink.Story(circleId, postId))
                } else Modifier
            ),
        contentAlignment = Alignment.Center,
    ) {
        when {
            story != null -> {
                val ref = storyThumbRef(story)
                if (ref != null) {
                    MediaImage(
                        circleId,
                        ref,
                        Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                }
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.15f)),
                )
                Text("▶", color = Color.White, fontSize = 22.sp)
            }
            !settled -> CircularProgressIndicator(color = HavenTheme.pink, modifier = Modifier.width(24.dp))
            else -> Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.padding(10.dp),
            ) {
                Text("⏱", fontSize = 20.sp)
                Spacer(Modifier.height(6.dp))
                Text(
                    stringResource(R.string.story_no_longer_available),
                    color = HavenTheme.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

private const val STORY_LIFETIME_MS = 24L * 60 * 60 * 1000

/** Live (within 24h) or author-kept snapshot for [postId]. Hard 24h window even if still in feed. */
fun resolveStory(circleId: String, postId: String): FeedItemFfi? {
    if (KeptStoriesStore.isKept(postId)) {
        val k = KeptStoriesStore.get(postId)
        if (k != null && k.media.isNotEmpty()) {
            return FeedItemFfi(
                id = k.id,
                authorShort = HavenNet.nodeIdHex.take(12),
                isMe = true,
                createdAt = k.createdAt.toULong(),
                body = k.body,
                media = k.media,
                music = k.music(),
                edited = false,
                unsent = false,
                story = true,
                muteVideo = false,
                comments = emptyList(),
                reactions = emptyList(),
                poll = null,
            )
        }
    }
    val live = runCatching {
        // Retention-free so we can apply the story window ourselves.
        HavenNet.engine.feed(circleId, nowMs(), null)
            .firstOrNull { it.id == postId && it.story && !it.unsent && it.media.isNotEmpty() }
    }.getOrNull()
        ?: runCatching {
            HavenNet.engine.feed(circleId, nowMs(), CircleSettings.retentionSecs(circleId))
                .firstOrNull { it.id == postId && it.story && !it.unsent && it.media.isNotEmpty() }
        }.getOrNull()
    if (live != null) {
        val age = nowMs() - live.createdAt.toLong()
        if (age > STORY_LIFETIME_MS) return null
        return live
    }
    return null
}

private fun storyThumbRef(item: FeedItemFfi): String? {
    val media = item.media
    val video = media.firstOrNull { LocalMedia.isVideo(it) }
    if (video != null) return MediaVariants.posterFor(video, media) ?: video
    return MediaVariants.displayRefs(media).firstOrNull()
}
