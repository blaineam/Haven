package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Podcasts
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.blaineam.haven.R
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.RelayNudge

/**
 * The relay nudge — a per-circle dismissable banner in the feed plus a walkthrough. Ports the
 * BEHAVIOUR of iOS `RelayNudge.swift`; the look follows Android's own idiom (brand-gradient card +
 * a Material 3 bottom sheet), not Liquid Glass.
 *
 * Every claim in the walkthrough copy is bounded by what the code actually does — see
 * `relay/README.md`, `docs/SECURITY.md`, `docs/GROUP-KEYING.md`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RelayNudgeBanner(circleId: String) {
    // All four feed the gate — observed so adopting a relay, hosting one, or a member joining
    // re-evaluates it without the feed having to know any of that.
    val nudgeV by RelayNudge.version
    val relaysV by HavenNet.relaysVersion
    val hosting by HavenNet.hosting
    val circlesV by HavenNet.circlesVersion
    var showWalkthrough by remember { mutableStateOf(false) }

    val show = remember(circleId, nudgeV, relaysV, hosting, circlesV) { RelayNudge.shouldShow(circleId) }
    if (!show) return

    // Everything in this banner is white-on-brand-gradient — never themed.
    Row(
        Modifier.fillMaxWidth()
            .background(HavenTheme.brandHorizontal, RoundedCornerShape(16.dp))
            .clickable { showWalkthrough = true }
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Podcasts, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.nudge_banner_title), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(2.dp))
            Text(
                stringResource(R.string.nudge_banner_body),
                color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp,
            )
        }
        Spacer(Modifier.width(8.dp))
        Box(
            Modifier.size(26.dp).clip(CircleShape)
                .background(Color.White.copy(alpha = 0.18f))
                .clickable { RelayNudge.dismiss(circleId) },   // one-way: never nag again for this circle
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.nudge_dismiss), tint = Color.White, modifier = Modifier.size(15.dp)) }
    }

    if (showWalkthrough) {
        ModalBottomSheet(
            onDismissRequest = { showWalkthrough = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            // background, not card: the points inside are havenCard()s, which would vanish against
            // a card-coloured sheet.
            containerColor = HavenTheme.background,
        ) { RelayWalkthrough(onDone = { showWalkthrough = false }) }
    }
}

@Composable
private fun RelayWalkthrough(onDone: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.nudge_walkthrough_title), color = HavenTheme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold)

        Point(Icons.Filled.Inbox, stringResource(R.string.nudge_p1_title),
            stringResource(R.string.nudge_p1_body))
        Point(Icons.Filled.PhotoLibrary, stringResource(R.string.nudge_p2_title),
            stringResource(R.string.nudge_p2_body))
        Point(Icons.Filled.Hub, stringResource(R.string.nudge_p3_title),
            stringResource(R.string.nudge_p3_body))
        Point(Icons.Filled.Lock, stringResource(R.string.nudge_p4_title),
            stringResource(R.string.nudge_p4_body))

        Header(stringResource(R.string.nudge_how_header))
        Point(Icons.Filled.Smartphone, stringResource(R.string.nudge_p5_title),
            stringResource(R.string.nudge_p5_body))
        Point(Icons.Filled.Terminal, stringResource(R.string.nudge_p6_title),
            stringResource(R.string.nudge_p6_body))

        Header(stringResource(R.string.nudge_count_header))
        Point(Icons.Filled.Key, stringResource(R.string.nudge_p7_title),
            // "Remove", NOT "add or remove": rotate_epoch fires on removal, on device-roster changes,
            // and on the periodic rotate_circle — never on adding a member. Claiming add rotates would
            // imply a new member is fenced off from earlier posts. They aren't.
            stringResource(R.string.nudge_p7_body))
        Point(Icons.Filled.Science, stringResource(R.string.nudge_p8_title),
            stringResource(R.string.nudge_p8_body),
            learnMore = "encryption")

        Spacer(Modifier.height(4.dp))
        BrandButton(text = stringResource(R.string.nudge_use_phone)) {
            HavenNet.startHosting()   // hosting adopts + announces itself to the circles — see startHosting
            onDone()
        }
        Text(stringResource(R.string.common_not_now), color = HavenTheme.textSecondary, fontSize = 14.sp,
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { onDone() }.padding(10.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
private fun Header(text: String) {
    Text(text, color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(top = 6.dp, start = 4.dp))
}

@Composable
private fun Point(icon: ImageVector, title: String, body: String, learnMore: String? = null) {
    Row(
        Modifier.fillMaxWidth().havenCard().padding(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(3.dp))
            Text(body, color = HavenTheme.textSecondary, fontSize = 12.sp)
            learnMore?.let { anchor ->
                val context = androidx.compose.ui.platform.LocalContext.current
                Spacer(Modifier.height(3.dp))
                Text(stringResource(R.string.nudge_learn_more), color = HavenTheme.pink, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable { openInApp(context, "https://wemiller.com/apps/haven/docs/#$anchor") })
            }
        }
    }
}
