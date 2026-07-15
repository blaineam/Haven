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
            Text("Give this circle a relay", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(2.dp))
            Text(
                "A few of you are here now — a relay holds your sealed posts so nobody has to be online at the same time.",
                color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp,
            )
        }
        Spacer(Modifier.width(8.dp))
        Box(
            Modifier.size(26.dp).clip(CircleShape)
                .background(Color.White.copy(alpha = 0.18f))
                .clickable { RelayNudge.dismiss(circleId) },   // one-way: never nag again for this circle
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Close, contentDescription = "Dismiss", tint = Color.White, modifier = Modifier.size(15.dp)) }
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
        Text("Set up a relay", color = HavenTheme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold)

        Point(Icons.Filled.Inbox, "Nobody has to be online at once",
            "Your posts and media are uploaded sealed. Anyone in the circle picks them up whenever they next open Haven — even if you've long since closed the app.")
        Point(Icons.Filled.PhotoLibrary, "Photos and videos actually arrive",
            "Media is fetched from the relay instead of waiting on the person who posted it, so it still lands when two phones' networks can't reach each other directly.")
        Point(Icons.Filled.Hub, "It routes around home routers",
            "When a member can't be dialed directly, the relay forwards their sealed messages onward. No port forwarding, no domain, no ports to open.")
        Point(Icons.Filled.Lock, "The relay can't read a thing",
            "It only ever holds sealed blobs and a tiny routing header — destination node ids, a hop budget, and a de-duplication id. No content key ever goes near it, so hosting one can never turn it into a reader.")

        Header("How to set one up")
        Point(Icons.Filled.Smartphone, "The easy way — this phone",
            "One tap below and this phone holds the circle's sealed mailbox. It serves while Haven is open, or in the background if Real-time connection is on — fine on a charger, but a computer or a Raspberry Pi left running is the real fix. Turn it off any time under Settings ▸ Relays.")
        Point(Icons.Filled.Terminal, "Or a spare machine",
            "On a Mac, Linux box, or Raspberry Pi, one line installs it:\ncurl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh\n\nOn Windows, in PowerShell:\nirm https://wemiller.com/apps/haven/relay/install.ps1 | iex\n\nIt sets itself to start on every reboot, then prints a node id. Add it under Settings ▸ Relays ▸ Add a relay.")

        Header("What everyone in the circle can count on")
        Point(Icons.Filled.Key, "Only the people you added can read it",
            // "Remove", NOT "add or remove": rotate_epoch fires on removal, on device-roster changes,
            // and on the periodic rotate_circle — never on adding a member. Claiming add rotates would
            // imply a new member is fenced off from earlier posts. They aren't.
            "Everything you post is sealed on your device to your circle's members. Remove someone and the circle's key rotates, so they can't read anything posted afterwards.")
        Point(Icons.Filled.Science, "Encrypted for the long haul",
            "Haven pairs today's proven encryption with post-quantum encryption — X25519 with ML-KEM-768, signed with Ed25519 and ML-DSA-65. An attacker has to break both halves, so ciphertext saved today isn't a bet on a future quantum computer. No promises beyond that: keys live on your devices, and Haven never holds them.")

        Spacer(Modifier.height(4.dp))
        BrandButton(text = "Use this phone as the relay") {
            HavenNet.startHosting()   // hosting adopts + announces itself to the circles — see startHosting
            onDone()
        }
        Text("Not now", color = HavenTheme.textSecondary, fontSize = 14.sp,
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
private fun Point(icon: ImageVector, title: String, body: String) {
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
        }
    }
}
