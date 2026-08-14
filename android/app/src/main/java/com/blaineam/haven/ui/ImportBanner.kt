package com.blaineam.haven.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.InstagramImporter

/**
 * The app-wide "still importing" strip. Apple parity: `ImportBanner.swift`.
 *
 * An archive import takes a long time — hundreds of photos and videos, each re-encoded and encrypted
 * on the device — and holding the user on a modal progress bar for all of it is the wrong trade
 * twice over: they cannot use Haven, and they cannot see the posts arriving, which is the whole
 * point of watching. So the import runs on [InstagramImporter] (independent of any composable) and
 * this strip is what remains on screen: small, tappable to reopen the full walkthrough, and present
 * wherever the user browses to — including after a relaunch, since the import resumes itself.
 *
 * WHERE IT GOES MATTERS. This must be placed inside the Scaffold's CONTENT, which is already inset
 * for the navigation bar — never in the `bottomBar` slot and never over the Scaffold as a whole. On
 * Apple the first cut overlaid the tab bar, so the app's own navigation was the thing the progress
 * indicator covered up; a background task must not cost you the tab bar. Renders NOTHING when no
 * import is running, so it can be dropped in unconditionally.
 */
@Composable
fun ImportBanner(modifier: Modifier = Modifier) {
    val done by InstagramImporter.done
    val total by InstagramImporter.total
    AnimatedVisibility(
        visible = InstagramImporter.isRunning,
        enter = slideInVertically { it } + fadeIn(),
        exit = slideOutVertically { it } + fadeOut(),
        modifier = modifier,
    ) {
        Row(
            Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(RoundedCornerShape(50))
                .background(HavenTheme.card)
                .border(1.dp, HavenTheme.pink.copy(alpha = 0.25f), RoundedCornerShape(50))
                .clickable { InstagramImporter.showSheet.value = true }
                .padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(
                progress = { if (total > 0) done.toFloat() / total else 0f },
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = HavenTheme.pink,
                trackColor = HavenTheme.textSecondary.copy(alpha = 0.25f),
            )
            Spacer(Modifier.width(11.dp))
            Column {
                Text(stringResource(R.string.ig_banner_title), color = HavenTheme.textPrimary,
                     fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Text(stringResource(R.string.ig_banner_progress_fmt, done, total),
                     color = HavenTheme.textSecondary, fontSize = 11.sp)
            }
            Spacer(Modifier.width(8.dp))
            Icon(Icons.Filled.KeyboardArrowUp, contentDescription = null,
                 tint = HavenTheme.textSecondary, modifier = Modifier.size(18.dp))
        }
    }
}
