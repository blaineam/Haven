package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.blaineam.haven.R
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet

/**
 * "Where is this post actually stored?" — tap the cloud indicator to find out. Apple parity
 * (`BackupDetailView`); Android and desktop had no equivalent at all, so the only way to learn which
 * relay held what on this platform was to read logcat.
 *
 * The indicator answers yes/no. That was enough right up until the day it said yes and nobody could
 * fetch anything: every blob had reached a relay, the relay was the one running inside the author's
 * own app, and the tick had no way to say so.
 *
 * Grouped by RELAY, not by attachment: the per-attachment shape repeats an identical block once per
 * photo, and the one fact that matters — which relay is missing copies — has to be reassembled by
 * eye. A count per relay says the same thing in one line and still names a partial failure exactly
 * ("3 of 4").
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupDetailSheet(refs: List<String>, circleId: String, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val ownRelayHex = remember { HavenNet.ownHostedRelayHex() }

    // Every relay worth a row: the ones this circle publishes to, PLUS any that already hold a copy.
    // Naming a circle relay that holds nothing is the case you most need to see.
    val rows = remember(refs, circleId) {
        val dests = LinkedHashSet<String>()
        dests.addAll(HavenNet.circleRelayHexes(circleId))
        refs.forEach { dests.addAll(HavenNet.mediaBackupDestinations(it)) }
        dests.sorted().map { dest ->
            dest to refs.count { HavenNet.mediaBackupDestinations(it).contains(dest) }
        }
    }

    /** Nothing but our own in-process relay holds a full set — it looks backed up and is in fact
     *  unreachable to everyone else. */
    val strandedOnOwnRelay = remember(rows) {
        val remoteComplete = rows.any { it.first != ownRelayHex && it.second == refs.size }
        val ownHasAny = rows.any { it.first == ownRelayHex && it.second > 0 }
        ownHasAny && !remoteComplete
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState,
                     containerColor = HavenTheme.card) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Text(stringResource(R.string.backup_title),
                color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text(if (refs.size == 1) stringResource(R.string.backup_one_attachment) else stringResource(R.string.backup_n_attachments, refs.size),
                color = HavenTheme.textSecondary, fontSize = 12.sp)
            Spacer(Modifier.height(14.dp))

            if (rows.isEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.RadioButtonUnchecked, null,
                        tint = HavenTheme.textSecondary, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(10.dp))
                    Text(stringResource(R.string.backup_no_relay), color = HavenTheme.textSecondary, fontSize = 14.sp)
                }
            }
            rows.forEach { (dest, have) ->
                val isOwn = dest == ownRelayHex
                val all = have == refs.size
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                        Icon(
                            when {
                                have == 0 -> Icons.Filled.RadioButtonUnchecked
                                isOwn -> Icons.Filled.Smartphone
                                all -> Icons.Filled.CheckCircle
                                else -> Icons.Filled.Warning
                            },
                            null,
                            tint = when {
                                have == 0 -> HavenTheme.textSecondary
                                isOwn -> Color(0xFFF59E0B)
                                all -> Color(0xFF22C55E)
                                else -> Color(0xFFF59E0B)
                            },
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.size(10.dp))
                        Text(relayLabel(dest), color = HavenTheme.textPrimary, fontSize = 14.sp, maxLines = 1)
                    }
                    Text(
                        statusText(have, refs.size, isOwn),
                        color = HavenTheme.textSecondary, fontSize = 12.sp,
                    )
                }
            }

            if (strandedOnOwnRelay) {
                Spacer(Modifier.height(10.dp))
                Box(Modifier.fillMaxWidth().background(Color(0x22F59E0B)).padding(10.dp)) {
                    Text(stringResource(R.string.backup_stranded),
                        color = Color(0xFFF59E0B), fontSize = 12.sp)
                }
            }
        }
    }
}

@Composable
private fun statusText(have: Int, total: Int, isOwn: Boolean): String {
    if (have == 0) return stringResource(R.string.backup_no_copy)
    val count = if (have == total) stringResource(R.string.backup_all) else stringResource(R.string.backup_x_of_y, have, total)
    return if (isOwn) stringResource(R.string.backup_on_this_device, count) else count
}

/** A relay's friendly name, falling back to a short hex. An S3 destination is stored by bucket
 *  rather than node hex, so it is already readable. */
@Composable
private fun relayLabel(dest: String): String {
    val known = runCatching { HavenNet.relayName(dest) }.getOrNull()
    if (!known.isNullOrBlank()) return known
    if (dest.contains("/") || dest.contains(".")) return dest   // s3-style destination
    return stringResource(R.string.backup_relay_short, dest.take(8))
}
