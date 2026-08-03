package com.blaineam.haven.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.CircleSettings
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.nowMs

/**
 * A single post addressed by a deep link (`docs/LINK-SYSTEM.md`) — parity with iOS `PostLinkView`.
 *
 * The link is only a pointer, so resolution is an ordinary in-circle feed lookup: a device already
 * in the circle finds the post and decrypts it as usual, and everyone else falls through to "post
 * not found". Nothing here grants access.
 */
@Composable
fun PostLinkScreen(circleId: String, postId: String, onDone: () -> Unit) {
    // Back closes the post, not the app — this sheet is often the app's first screen (a link tapped
    // from a chat), so swallowing back here is the difference between "return to the feed" and "quit".
    androidx.activity.compose.BackHandler { onDone() }
    val version by HavenNet.feedVersion
    // Looked up UNFILTERED, unlike the feed: the user asked for this exact post, so a hidden one
    // still resolves and an unsent one resolves to its tombstone rather than a bare "not found".
    // An id that names a COMMENT resolves to the post that CARRIES it (iOS `FeedStore.post`). Comments
    // are not top-level feed items, so reacting to or replying to one produced an activity row and a
    // push whose target matched nothing here — every one of those taps said "post not found".
    val post = remember(version, circleId, postId) {
        runCatching {
            val items = HavenNet.engine.feed(circleId, nowMs(), CircleSettings.retentionSecs(circleId))
            items.firstOrNull { it.id == postId }
                ?: items.firstOrNull { item -> item.comments.any { it.id == postId } }
        }.getOrNull()
    }
    val reports = remember(version, circleId, postId) {
        runCatching { HavenNet.reports(circleId)[postId].orEmpty() }.getOrDefault(emptyList())
    }

    HavenBackground {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 12.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Post", color = HavenTheme.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                Text(
                    "Done", color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onDone() }.padding(8.dp),
                )
            }
            if (post != null) {
                LazyColumn(
                    Modifier.fillMaxWidth().weight(1f),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    // When the link named a comment, mark it — the post alone doesn't answer "which
                    // comment did they react to?" on a thread with a dozen of them.
                    item {
                        PostCard(post, circleId, reports,
                            highlightCommentId = if (post.id == postId) null else postId)
                    }
                }
            } else {
                // Not in the circle, unsent, or simply not synced to this device yet — all of which
                // are indistinguishable from here, and none of which are worth guessing about.
                Column(
                    Modifier.fillMaxWidth().weight(1f).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text("🔍", fontSize = 48.sp)
                    Spacer(Modifier.height(12.dp))
                    Text("Post not found", color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "It may have been unsent, or you're not in this circle. If it's new, it may not have reached this device yet.",
                        color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}
