package com.blaineam.haven.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.HistoryHandoff

/**
 * Progress of what this phone is sending to another device of mine — history pages (D26) and the
 * keys to older media (D27) — with "Cancel transfer". Apple parity: `HistoryHandoffBanner.swift`.
 * While it is sending, the screen stays on: a phone that locks stops the transfer. Renders nothing
 * when there is nothing to report. Sits with [ImportBanner] above the tab bar, never over the
 * composer.
 */
@Composable
fun HistoryHandoffBanner(modifier: Modifier = Modifier) {
    val status by HistoryHandoff.banner
    val view = LocalView.current
    val sending = status.phase == HistoryHandoff.Phase.SENDING
    DisposableEffect(sending) {
        if (sending) view.keepScreenOn = true
        onDispose { if (sending) view.keepScreenOn = false }
    }
    AnimatedVisibility(
        visible = status.phase != HistoryHandoff.Phase.IDLE,
        enter = slideInVertically { it } + fadeIn(),
        exit = slideOutVertically { it } + fadeOut(),
        modifier = modifier,
    ) {
        HistoryHandoffCard(
            status,
            onCancel = { HistoryHandoff.shared?.cancelTransfer() },
            onDismiss = { HistoryHandoff.shared?.dismiss() },
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

/** The card itself, stateless but for its own confirmation, so a test can drive every phase. */
@Composable
fun HistoryHandoffCard(
    status: HistoryHandoff.Status,
    onCancel: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var confirming by remember { mutableStateOf(false) }
    val sending = status.phase == HistoryHandoff.Phase.SENDING
    Column(
        modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(HavenTheme.card)
            .border(1.dp, HavenTheme.pink.copy(alpha = 0.25f), RoundedCornerShape(16.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .testTag("historyHandoffBanner"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (sending) Icons.Filled.Upload else Icons.Filled.Cancel, contentDescription = null,
                tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(11.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(if (sending) R.string.handoff_sending_title else R.string.handoff_cancelled_title),
                    color = HavenTheme.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Text(handoffDetail(status), color = HavenTheme.textSecondary, fontSize = 11.sp)
            }
            if (!sending) {
                IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.handoff_dismiss),
                        tint = HavenTheme.textSecondary, modifier = Modifier.size(18.dp))
                }
            }
        }
        if (sending) {
            // The counts replaced the "keep it open" advice in the detail line; it still matters.
            if (status.total + status.mediaTotal > 0) {
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.handoff_keep_open), color = HavenTheme.textSecondary, fontSize = 11.sp)
            }
            Spacer(Modifier.height(8.dp))
            val fraction = status.fraction
            if (fraction != null) {
                LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth(),
                    color = HavenTheme.pink, trackColor = HavenTheme.textSecondary.copy(alpha = 0.25f))
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(),
                    color = HavenTheme.pink, trackColor = HavenTheme.textSecondary.copy(alpha = 0.25f))
            }
            TextButton(onClick = { confirming = true }, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(R.string.handoff_cancel), color = HavenTheme.pink, fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold)
            }
        }
    }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text(stringResource(R.string.handoff_confirm_title)) },
            text = { Text(stringResource(R.string.handoff_cancelled_here)) },
            confirmButton = {
                TextButton(onClick = { confirming = false; onCancel() }) {
                    Text(stringResource(R.string.handoff_confirm_stop))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) {
                    Text(stringResource(R.string.handoff_confirm_keep))
                }
            },
        )
    }
}

@Composable
private fun handoffDetail(s: HistoryHandoff.Status): String {
    if (s.phase == HistoryHandoff.Phase.CANCELLED) {
        return stringResource(
            if (s.cancelledRemotely) R.string.handoff_cancelled_there else R.string.handoff_cancelled_here)
    }
    val done = minOf(s.done, maxOf(s.total, s.done))
    val media = minOf(s.mediaDone, s.mediaTotal)
    return when {
        s.total == 0L && s.mediaTotal > 0 -> stringResource(R.string.handoff_media_fmt, media, s.mediaTotal)
        s.mediaTotal > 0 -> stringResource(R.string.handoff_both_fmt, done, maxOf(s.total, s.done), media, s.mediaTotal)
        s.total > 0 -> stringResource(R.string.handoff_posts_fmt, minOf(s.done, s.total), s.total)
        else -> stringResource(R.string.handoff_keep_open)
    }
}
