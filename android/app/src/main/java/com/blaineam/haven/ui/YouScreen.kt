package com.blaineam.haven.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.material.icons.filled.Edit
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenCore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore

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
    var showEdit by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showPeople by remember { mutableStateOf(false) }
    var storyIndex by remember { mutableStateOf<Int?>(null) }   // non-null = viewer open at that story
    val contactCount = com.blaineam.haven.core.HavenNet.contacts.size
    val feedVersion by com.blaineam.haven.core.HavenNet.feedVersion
    val mine = remember(feedVersion) {
        runCatching {
            com.blaineam.haven.core.HavenNet.engine
                .feed(com.blaineam.haven.core.DEFAULT_CIRCLE, com.blaineam.haven.core.nowMs(), null)
                .filter { it.isMe && !it.unsent }
        }.getOrDefault(emptyList())
    }
    val myPosts = mine.filter { !it.story }
    // Stories expire on their own, so this section simply disappears when the last one ages out.
    val myStories = mine.filter { it.story }.sortedBy { it.createdAt }

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
            // Avatar — tap to edit your profile. Must go through HavenAvatar (which prefers the
            // real photo from ProfileStore): hand-rolling the emoji here meant the header showed
            // the 🌿 fallback while this same user's post bylines — which DO use HavenAvatar —
            // showed the photo, on one screen.
            Box(contentAlignment = Alignment.BottomEnd) {
                Box(Modifier.clip(CircleShape).clickable { showEdit = true }) {
                    // core.nodeIdHex, not HavenNet.nodeIdHex: this composes before HavenNet.init()
                    // and HavenNet's backing `core` is lateinit. Same value, always available.
                    HavenAvatar(core.nodeIdHex, profile.displayName, 92.dp, isMe = true)
                }
                // The pencil badge is the only hint the avatar is editable (iOS parity).
                Box(
                    Modifier.size(28.dp).clip(CircleShape).background(HavenTheme.background)
                        .padding(2.dp).clip(CircleShape).background(HavenTheme.pink)
                        .clickable { showEdit = true },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Edit, "Edit profile", tint = Color.White, modifier = Modifier.size(15.dp)) }
            }
            Spacer(Modifier.height(12.dp))
            Text(
                profile.displayName.ifBlank { "You" },
                color = HavenTheme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold,
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

            // Your stories — the disappearing half of your profile (iOS parity).
            if (myStories.isNotEmpty()) {
                Spacer(Modifier.height(20.dp))
                Text("Your stories", color = HavenTheme.textSecondary, fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(10.dp))
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    myStories.forEachIndexed { idx, s ->
                        Box(
                            Modifier.size(64.dp).clip(CircleShape).background(HavenTheme.brand)
                                .clickable { storyIndex = idx },
                            contentAlignment = Alignment.Center,
                        ) {
                            val mediaId = s.media.firstOrNull()
                            if (mediaId != null) {
                                MediaImage(com.blaineam.haven.core.DEFAULT_CIRCLE, mediaId,
                                    Modifier.size(56.dp).clip(CircleShape), ContentScale.Crop)
                            }
                        }
                    }
                }
            }

            // Your posts — this screen is your profile, like iOS.
            if (myPosts.isNotEmpty()) {
                Spacer(Modifier.height(20.dp))
                Text("Your posts", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp,
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
    storyIndex?.let { start ->
        val group = remember(myStories) {
            StoryGroup(myStories.first().authorShort, isMe = true, items = myStories)
        }
        FullScreenOverlay(onDismiss = { storyIndex = null }) {
            StoryViewer(groups = listOf(group), startGroup = 0,
                onClose = { storyIndex = null }, startItem = start)
        }
    }
}
