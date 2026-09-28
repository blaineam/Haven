package com.blaineam.haven.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Group
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.HavenNet

/**
 * Who a circle post (or a reply on one) actually reaches — surfaced right at the composer.
 *
 * People posted private things to the WHOLE circle believing they were writing to one person: the
 * audience was implicit in the circle switcher. So the composer now says it out loud (an "Everyone in
 * <Circle> · N people" chip, a placeholder naming the circle, a labeled Post button), and the first post
 * in each circle with more than one other person asks once, offering "Send privately instead…".
 * iOS parity: apple/HavenApp/ComposerAudience.swift.
 */
object ComposerAudience {
    private const val PREFS = "haven_audience_ack"
    private const val KEY = "acked"

    /** Long circle names would push the placeholder / button label off the line — keep the start. */
    fun shortName(name: String, max: Int = 22): String =
        if (name.length > max) name.take(max - 1).trimEnd() + "…" else name

    /** Everyone OTHER than me a post here reaches: my contacts for My Circle, else the circle's
     *  members minus me and anyone I've blocked. */
    fun othersCount(circleId: String): Int {
        if (circleId == DEFAULT_CIRCLE) return HavenNet.contacts.size
        val me = HavenNet.nodeIdHex
        return runCatching { HavenNet.membersOf(circleId) }.getOrDefault(emptyList())
            .map { it.idHex }.distinct()
            .count { hex -> !hex.equals(me, true) && HavenNet.blocked.none { it.equals(hex, true) } }
    }

    fun isAcknowledged(context: Context, circleId: String): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet(KEY, emptySet())!!.contains(circleId)

    fun acknowledge(context: Context, circleId: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = prefs.getStringSet(KEY, emptySet())!!.toMutableSet()
        if (now.add(circleId)) prefs.edit().putStringSet(KEY, now).apply()
    }

    /** Ask once per circle, and only when the post really fans out (more than one other person). */
    fun needsConfirmation(context: Context, circleId: String, othersCount: Int): Boolean =
        !circleId.startsWith("dm:") && othersCount > 1 && !isAcknowledged(context, circleId)

    /** Open (or reuse) the DM with [picks] and carry [text] into its composer; RootScreen switches
     *  to Messages when DmDrafts.openThread is set. */
    fun sendPrivately(picks: List<com.blaineam.haven.core.Contact>, text: String) {
        if (picks.isEmpty()) return
        val cid = HavenNet.startGroupDM(picks)
        openThread(cid, text)
    }

    fun openThread(dmCircleId: String, text: String = "") {
        if (text.isNotBlank()) com.blaineam.haven.core.DmDrafts.stage(dmCircleId, text)
        else com.blaineam.haven.core.DmDrafts.openThread.value = dmCircleId
    }
}

@Composable
fun peopleText(n: Int): String =
    if (n == 1) stringResource(R.string.composer_one_person) else stringResource(R.string.composer_n_people, n)

@Composable
fun audienceSummary(circle: String, count: Int): String =
    if (count > 0) stringResource(R.string.composer_audience_everyone_count, circle, peopleText(count))
    else stringResource(R.string.composer_audience_everyone, circle)

/** The compact "👥 Everyone in Family · 6 people ▾" chip above the feed composer. Its menu is the
 *  always-there door to a private message. */
@Composable
fun ComposerAudienceChip(circleName: String, count: Int, onSendPrivately: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val full = audienceSummary(circleName, count)
    val a11y = stringResource(R.string.composer_audience_cd, full)
    Box {
        Row(
            Modifier.clip(CircleShape)
                .background(HavenTheme.card.copy(alpha = 0.7f))
                .border(1.dp, HavenTheme.cardBorder, CircleShape)
                .clickable { menu = true }
                .padding(start = 10.dp, end = 4.dp, top = 4.dp, bottom = 4.dp)
                .semantics { contentDescription = a11y },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Group, null, tint = HavenTheme.textSecondary, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(5.dp))
            Text(audienceSummary(ComposerAudience.shortName(circleName), count),
                color = HavenTheme.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(Icons.Filled.ArrowDropDown, null, tint = HavenTheme.textSecondary, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, modifier = Modifier.background(HavenTheme.card)) {
            DropdownMenuItem(
                text = { Text(full, color = HavenTheme.textSecondary, fontSize = 12.sp) },
                onClick = {}, enabled = false,
            )
            DropdownMenuItem(
                leadingIcon = { Icon(Icons.AutoMirrored.Filled.Chat, null, tint = HavenTheme.pink) },
                text = { Text(stringResource(R.string.composer_send_privately), color = HavenTheme.textPrimary) },
                onClick = { menu = false; onSendPrivately() },
            )
        }
    }
}

/** One-time per-circle "this goes to everyone" check before the first post there. */
@Composable
fun AudienceConfirmDialog(
    circleName: String, count: Int,
    onPost: () -> Unit, onSendPrivately: () -> Unit, onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss, containerColor = HavenTheme.card,
        title = { Text(stringResource(R.string.audience_confirm_title, circleName), color = HavenTheme.textPrimary) },
        text = {
            androidx.compose.foundation.layout.Column {
                Text(stringResource(R.string.audience_confirm_body, circleName, peopleText(count)), color = HavenTheme.textSecondary)
                Spacer(Modifier.size(12.dp))
                TextButton(onClick = onSendPrivately) {
                    Text(stringResource(R.string.audience_confirm_private), color = HavenTheme.pink)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onPost) {
                Text(stringResource(R.string.audience_confirm_post), color = HavenTheme.pink, fontWeight = FontWeight.SemiBold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel), color = HavenTheme.textSecondary) }
        },
    )
}
