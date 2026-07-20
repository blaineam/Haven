package com.blaineam.haven.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * "Preparing your video…" — shown while [com.blaineam.haven.core.MediaProcessing] has work in flight.
 *
 * Renders NOTHING when idle, so it can be dropped into a composer unconditionally.
 *
 * The point is to distinguish slow from broken. Without it, a 35-second transcode and a silently
 * failed attach are the same experience: you tap, and nothing appears. That ambiguity was reported
 * on iOS as "attaching a video never attaches anything" when the attach was in fact working.
 */
@Composable
fun MediaProcessingCard(modifier: Modifier = Modifier) {
    val n = com.blaineam.haven.core.MediaProcessing.inFlight
    if (n <= 0) return
    Surface(
        modifier = modifier.fillMaxWidth().padding(vertical = 6.dp),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Text(
                // Plural only when it's actually plural — "Preparing 1 items" reads like a bug.
                if (n == 1) "Preparing your media…" else "Preparing $n items…",
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}
