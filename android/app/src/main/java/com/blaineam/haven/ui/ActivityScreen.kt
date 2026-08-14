package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.HowToVote
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.ActivityStore
import com.blaineam.haven.core.CircleLinkInbox
import com.blaineam.haven.core.DeepLink
import com.blaineam.haven.core.DmDrafts
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.PostLinkInbox

/**
 * The in-app activity list behind the bell: who reacted to / commented on / voted on MY posts,
 * new posts/stories/DMs, connections and circle adds — reduced by the shared core
 * (`social.activity()`) plus the app-layer rows [ActivityStore] records.
 *
 * Rows jump via the EXISTING routes only (no routing of its own): posts/comments/reactions offer
 * [PostLinkInbox] (RootScreen presents the post, circle lock honored), DMs stage
 * [DmDrafts.openThread] (RootScreen switches to Messages), connections open the Connect sheet.
 */
@Composable
fun ActivityScreen(onDone: () -> Unit, onConnect: () -> Unit) {
    ActivityStore.version.intValue
    val rows = ActivityStore.rows
    // Capture the watermark AS OPENED so unseen rows stay highlighted while you look at them,
    // then mark everything seen (clears the bell badge here and — via self-sync — everywhere).
    val openedSeenAt = remember { ActivityStore.seenAt() }
    LaunchedEffect(Unit) { ActivityStore.markSeen() }

    HavenBackground {
        // statusBarsPadding on the CONTENT, not the background: the glow should still run
        // edge-to-edge, but the header must not sit under the status bar. Drawn under it, the
        // system bar's window swallows taps — which is why the close button here looked dead
        // (CircleScreen's fullscreen viewer already carries the same note).
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.activity_title), color = HavenTheme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDone) {
                    Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.common_close), tint = HavenTheme.textSecondary)
                }
            }
            if (rows.isEmpty()) {
                Column(
                    Modifier.fillMaxSize().padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(Icons.Filled.Notifications, null, tint = HavenTheme.textSecondary, modifier = Modifier.size(40.dp))
                    Spacer(Modifier.height(10.dp))
                    Text(stringResource(R.string.activity_empty_title), color = HavenTheme.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        stringResource(R.string.activity_empty_subtitle),
                        color = HavenTheme.textSecondary, fontSize = 13.sp,
                    )
                }
            } else {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
                    items(rows, key = { it.id + it.circleId }) { row ->
                        ActivityRow(row, unseen = row.createdAt > openedSeenAt) {
                            when {
                                // A connection row opens the Connect sheet (people live there).
                                row.kind == "connect" -> { onConnect(); return@ActivityRow }
                                // Being added to a circle → that circle's feed.
                                row.kind == "circle" -> CircleLinkInbox.offer(DeepLink.Circle(row.circleId))
                                // ANYTHING in a `dm:` circle opens the THREAD — decided by the circle
                                // id, not by `kind`, which is the rule iOS has always used
                                // (`DeepLink.interactionLink` branches on the `dm:` prefix before it
                                // looks at anything else).
                                //
                                // Branching on `kind` alone only caught kind == "dm", i.e. the message
                                // itself. A REACTION or COMMENT on a message carries kind "react" /
                                // "comment" with the dm: circle id, so it fell through to the post
                                // branch and tried to open a DM message as a feed post — which is why
                                // activity rows all behaved like posts.
                                row.circleId.startsWith("dm:") -> DmDrafts.openThread.value = row.circleId
                                // Stories open the story viewer (music/progress), not a feed post.
                                row.kind == "story" -> com.blaineam.haven.core.StoryLinkInbox.offer(
                                    DeepLink.Story(row.circleId, row.id))
                                // Posts, and reactions/comments/votes on MY posts → the post itself.
                                else -> PostLinkInbox.offer(
                                    DeepLink.Post(row.circleId, row.targetId ?: row.id))
                            }
                            onDone()
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ActivityRow(row: ActivityStore.Row, unseen: Boolean, onTap: () -> Unit) {
    val someone = stringResource(R.string.activity_someone)
    val actorName = when (row.kind) {
        "connect" -> row.snippet.ifBlank { someone }
        "circle" -> row.snippet.ifBlank { stringResource(R.string.activity_a_circle) }
        else -> HavenNet.displayName(row.actorShort).ifEmpty { someone }
    }
    val line = when (row.kind) {
        "react" -> stringResource(R.string.activity_reacted_fmt, row.emoji ?: "❤️")
        "comment" -> if (row.snippet.isBlank()) stringResource(R.string.activity_commented_on_post) else stringResource(R.string.activity_commented_fmt, row.snippet)
        "vote" -> stringResource(R.string.activity_voted)
        "story" -> stringResource(R.string.activity_shared_story)
        // A group thread says so — "sent you a message" is wrong when it went to everyone.
        "dm" -> if (row.snippet.isBlank()) {
            if (com.blaineam.haven.core.PushBanner.isGroupDm(row.circleId)) stringResource(R.string.activity_messaged_group)
            else stringResource(R.string.activity_sent_message)
        } else row.snippet
        "connect" -> stringResource(R.string.activity_now_connected)
        "circle" -> stringResource(R.string.activity_added_to_circle)
        else -> if (row.snippet.isBlank()) stringResource(R.string.activity_shared_something) else row.snippet
    }
    Row(
        Modifier.fillMaxWidth()
            .clickable { onTap() }
            .padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(40.dp).clip(CircleShape)
                .background(HavenTheme.pink.copy(alpha = if (unseen) 0.28f else 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                when (row.kind) {
                    "react" -> Icons.Filled.Favorite
                    "comment" -> Icons.Filled.ChatBubble
                    "vote" -> Icons.Filled.HowToVote
                    "dm" -> Icons.Filled.Forum
                    "connect" -> Icons.Filled.PersonAdd
                    "circle" -> Icons.Filled.AutoAwesome
                    else -> Icons.Filled.AutoAwesome
                },
                contentDescription = null, tint = HavenTheme.pink, modifier = Modifier.size(20.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(actorName, color = HavenTheme.textPrimary, fontSize = 14.sp,
                fontWeight = if (unseen) FontWeight.Bold else FontWeight.SemiBold, maxLines = 1,
                overflow = TextOverflow.Ellipsis)
            Text(line, color = HavenTheme.textSecondary, fontSize = 13.sp, maxLines = 2,
                overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(10.dp))
        Text(relativeTimeShortMs(row.createdAt), color = HavenTheme.textSecondary, fontSize = 11.sp)
        if (unseen) {
            Spacer(Modifier.width(8.dp))
            Box(Modifier.size(8.dp).clip(RoundedCornerShape(4.dp)).background(HavenTheme.pink))
        }
    }
}

/** Compact relative timestamp (now / 5m / 3h / 2d / 1w), same idiom as the feed's. */
private fun relativeTimeShortMs(createdAtMs: Long): String {
    val diff = System.currentTimeMillis() - createdAtMs
    if (diff < 0) return "now"
    val s = diff / 1000
    return when {
        s < 45 -> "now"
        s < 3600 -> "${s / 60}m"
        s < 86_400 -> "${s / 3600}h"
        s < 604_800 -> "${s / 86_400}d"
        else -> "${s / 604_800}w"
    }
}
