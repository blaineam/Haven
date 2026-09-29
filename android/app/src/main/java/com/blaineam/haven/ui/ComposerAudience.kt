package com.blaineam.haven.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Group
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.Contact
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
    fun sendPrivately(picks: List<Contact>, text: String) {
        if (picks.isEmpty()) return
        val cid = HavenNet.startGroupDM(picks)
        openThread(cid, text)
    }

    fun openThread(dmCircleId: String, text: String = "") {
        if (text.isNotBlank()) com.blaineam.haven.core.DmDrafts.stage(dmCircleId, text)
        else com.blaineam.haven.core.DmDrafts.openThread.value = dmCircleId
    }
}

/** Reply placeholder: names the circle when it fits (<= 14 chars), else the plain "Reply to everyone…". */
@Composable
fun replyPlaceholder(circle: String): String =
    if (circle.length <= 14) stringResource(R.string.circle_reply_placeholder_named, circle)
    else stringResource(R.string.circle_reply_placeholder_generic)

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
                .background(HavenTheme.card)   // opaque: readable over any photo, light or dark
                .border(1.dp, HavenTheme.cardBorder, CircleShape)
                .clickable { menu = true }
                .padding(start = 10.dp, end = 4.dp, top = 4.dp, bottom = 4.dp)
                .semantics { contentDescription = a11y }
                .testTag("composeAudience"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Group, null, tint = HavenTheme.pink, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(5.dp))
            Text(audienceSummary(ComposerAudience.shortName(circleName), count),
                color = HavenTheme.textPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
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
                TextButton(onClick = onSendPrivately, modifier = Modifier.testTag("audienceConfirmPrivate")) {
                    Text(stringResource(R.string.audience_confirm_private), color = HavenTheme.pink)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onPost, modifier = Modifier.testTag("audienceConfirmPost")) {
                Text(stringResource(R.string.audience_confirm_post), color = HavenTheme.pink, fontWeight = FontWeight.SemiBold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.testTag("audienceConfirmCancel")) {
                Text(stringResource(R.string.common_cancel), color = HavenTheme.textSecondary)
            }
        },
    )
}

/**
 * The feed composer's audience flow: the chip, the text field ("Post to everyone…"), the labeled Post
 * pill, the one-time per-circle confirmation and the "Send privately…" picker. Pure UI over its
 * parameters — the caller owns the draft and does the actual posting / DM hand-off — so it can be
 * driven in a Compose test without a live engine.
 *
 * [onSendPrivately] gets the picked people and the trimmed draft; the caller opens the thread with it
 * and clears its draft. [privatePicker] is the contact picker (the Messages one by default).
 */
@Composable
fun AudienceComposerBar(
    circleId: String,
    circleName: String,
    count: Int,
    draft: String,
    onDraftChange: (String) -> Unit,
    canPost: Boolean,
    onPost: () -> Unit,
    onSendPrivately: (picks: List<Contact>, text: String) -> Unit,
    privatePicker: @Composable (onDismiss: () -> Unit, onStart: (List<Contact>) -> Unit) -> Unit =
        { onDismiss, onStart -> NewMessagePicker(onDismiss = onDismiss, onStart = onStart) },
) {
    val context = LocalContext.current
    var confirm by remember { mutableStateOf(false) }
    var picker by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        // Say out loud who this reaches — the audience used to be implicit in the circle switcher,
        // and people posted private things to the whole circle meaning to write to one person.
        Row(Modifier.fillMaxWidth().padding(start = 14.dp, end = 12.dp, top = 2.dp)) {
            ComposerAudienceChip(circleName, count) { picker = true }
        }
        // Composer text + send.
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 2.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = draft, onValueChange = onDraftChange,
                placeholder = { Text(stringResource(R.string.composer_placeholder)) },   // the chip above names the circle
                modifier = Modifier.weight(1f).testTag("composeField"), shape = RoundedCornerShape(22.dp), maxLines = 4,
                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
            )
            Spacer(Modifier.size(8.dp))
            // Labeled "Post", not a bare paper plane: the plane is what a private message's send
            // looks like, and this goes to the whole circle. White-on-brand-gradient — never themed.
            val postCd = stringResource(R.string.composer_post_cd_named, circleName)
            Box(Modifier.height(48.dp).clip(CircleShape).background(HavenTheme.brandHorizontal)
                .clickable(enabled = canPost) {
                    if (ComposerAudience.needsConfirmation(context, circleId, count)) confirm = true
                    else onPost()
                }
                .padding(horizontal = 18.dp)
                .semantics { contentDescription = postCd }
                .testTag("composeSend"),
                contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.composer_post_button), color = Color.White,
                    fontSize = 15.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
    if (confirm) {
        AudienceConfirmDialog(
            circleName = circleName, count = count,
            onPost = { confirm = false; ComposerAudience.acknowledge(context, circleId); onPost() },
            onSendPrivately = { confirm = false; picker = true },
            onDismiss = { confirm = false },
        )
    }
    if (picker) {
        // Attachments stay in the composer; only the words travel to the private thread.
        privatePicker({ picker = false }) { picks ->
            picker = false
            if (picks.isNotEmpty()) onSendPrivately(picks, draft.trim())
        }
    }
}
