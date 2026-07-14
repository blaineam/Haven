package com.blaineam.haven.ui

import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenCore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore
import uniffi.haven_ffi.SelfTestReport

/**
 * The "You" screen — your profile + identity + an invite, plus the on-device privacy check.
 * This screen is the first proof that the shared Rust core runs on Android: the self-test
 * calls straight into haven_ffi.
 */
@Composable
fun YouScreen(onAddFriend: () -> Unit) {
    val context = LocalContext.current
    val core = remember { HavenCore.get(context) }
    val profile = remember { ProfileStore.get(context) }
    var report by remember { mutableStateOf<SelfTestReport?>(null) }
    var showEdit by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showPeople by remember { mutableStateOf(false) }
    val contactCount = com.blaineam.haven.core.HavenNet.contacts.size
    val feedVersion by com.blaineam.haven.core.HavenNet.feedVersion
    val myPosts = remember(feedVersion) {
        runCatching {
            com.blaineam.haven.core.HavenNet.engine
                .feed(com.blaineam.haven.core.DEFAULT_CIRCLE, com.blaineam.haven.core.nowMs(), null)
                .filter { it.isMe && !it.story && !it.unsent }
        }.getOrDefault(emptyList())
    }

    HavenBackground {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Top bar: settings gear (parity with the iOS You toolbar).
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { showSettings = true },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Settings, "Settings", tint = HavenTheme.textSecondary)
                }
            }
            // Avatar — tap to edit your profile.
            Box(
                Modifier
                    .size(92.dp)
                    .clip(CircleShape)
                    .background(HavenTheme.brand, CircleShape)
                    .clickable { showEdit = true },
                contentAlignment = Alignment.Center,
            ) { Text(profile.emoji, fontSize = 44.sp) }
            Spacer(Modifier.height(12.dp))
            Text(
                profile.displayName.ifBlank { "You" },
                color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold,
            )
            if (profile.bio.isNotBlank()) {
                Spacer(Modifier.height(6.dp))
                Text(profile.bio, color = HavenTheme.textSecondary, fontSize = 14.sp,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
            if (profile.link.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text("🔗 ${profile.link}", color = HavenTheme.pink, fontSize = 13.sp, maxLines = 1,
                    modifier = Modifier.clickable { openInApp(context, profile.link) })
            }
            Spacer(Modifier.height(4.dp))
            Text(
                if (contactCount == 0) "This is just for the people you choose."
                else "$contactCount ${if (contactCount == 1) "person" else "people"} in your circle  ›",
                color = HavenTheme.pink, fontSize = 13.sp,
                modifier = Modifier.clickable(enabled = contactCount > 0) { showPeople = true }.padding(4.dp),
            )

            Spacer(Modifier.height(24.dp))
            BrandButton(text = "Add a friend") { onAddFriend() }
            Spacer(Modifier.height(8.dp))
            Text("Share invite link", color = HavenTheme.pink, fontSize = 13.sp,
                modifier = Modifier.clickable { shareInvite(context, HavenNet.inviteUri()) }.padding(6.dp))

            // Your posts — this screen is your profile, like iOS.
            if (myPosts.isNotEmpty()) {
                Spacer(Modifier.height(20.dp))
                Text("Your posts", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp,
                    modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(10.dp))
                myPosts.forEach { post ->
                    PostCard(post)
                    Spacer(Modifier.height(12.dp))
                }
            }

            // (Under the hood + privacy check moved into Settings — nested where iOS keeps them.)
            Spacer(Modifier.height(24.dp))
        }
    }

    // Full-screen overlays (cover the tab bar — true full-screen, like iOS).
    if (showEdit) FullScreenOverlay(onDismiss = { showEdit = false }) { EditProfileScreen(onDone = { showEdit = false }) }
    if (showSettings) FullScreenOverlay(onDismiss = { showSettings = false }) { SettingsScreen(onBack = { showSettings = false }) }
    if (showPeople) FullScreenOverlay(onDismiss = { showPeople = false }) {
        PeopleScreen(onAddFriend = { showPeople = false; onAddFriend() }, onClose = { showPeople = false })
    }
}

@Composable
private fun Card(content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .havenCard()
            .padding(18.dp),
        content = content,
    )
}

@Composable
private fun KeyVal(key: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(key, color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Text(value, color = Color.White, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun CheckRow(title: String, ok: Boolean) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (ok) Icons.Filled.CheckCircle else Icons.Filled.Cancel,
            contentDescription = null,
            tint = if (ok) Color(0xFF34D399) else Color(0xFFF87171),
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.size(10.dp))
        Text(title, color = Color.White, fontSize = 14.sp)
    }
}

private fun shareInvite(context: android.content.Context, uri: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, "Add me on Haven: $uri")
    }
    context.startActivity(Intent.createChooser(send, "Invite to Haven"))
}
