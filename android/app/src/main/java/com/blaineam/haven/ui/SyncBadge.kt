package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.SyncBadgeState

/** The pill's text for a state — what the user reads, and what the Compose test asserts. */
@Composable
fun syncBadgeLabel(state: SyncBadgeState): String = when (state) {
    SyncBadgeState.Synced -> stringResource(R.string.sync_badge_synced)
    is SyncBadgeState.Sending -> stringResource(R.string.sync_badge_sending, state.done, state.total)
    is SyncBadgeState.Retrying -> stringResource(R.string.sync_badge_retrying, state.pending)
    SyncBadgeState.Local -> stringResource(R.string.circle_device_only)
}

/** The stateless composer pill (the stateful wrapper lives in CircleScreen). Test tag `syncBadge`. */
@Composable
fun SyncBadgePill(state: SyncBadgeState, onClick: () -> Unit) {
    val color = when (state) {
        SyncBadgeState.Synced -> Color(0xFF34D399)
        is SyncBadgeState.Sending -> Color(0xFFF59E0B)
        is SyncBadgeState.Retrying -> Color(0xFFF97316)
        SyncBadgeState.Local -> Color(0xFFEF4444)
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .testTag("syncBadge")
            .padding(horizontal = 6.dp)
            .clip(RoundedCornerShape(50))
            .clickable(onClick = onClick)
            .background(HavenTheme.card)
            .padding(horizontal = 9.dp, vertical = 4.dp),
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Spacer(Modifier.size(5.dp))
        Text(syncBadgeLabel(state), color = HavenTheme.textSecondary, fontSize = 11.sp)
    }
}
