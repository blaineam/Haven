package com.blaineam.haven.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.blaineam.haven.core.DemoEnv
import com.blaineam.haven.core.DemoSeeder
import com.blaineam.haven.core.HavenCore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore

private enum class Tab(val label: String, val icon: ImageVector) {
    Circle("Circle", Icons.Filled.AutoAwesome),
    Messages("Messages", Icons.Filled.Forum),
    You("You", Icons.Filled.Person),
}

/** Map the DEBUG `haven_tab` launch extra to the starting tab (null = default to Circle). */
private fun demoTab(): Tab? = when (DemoEnv.tab) {
    "circle" -> Tab.Circle
    "messages" -> Tab.Messages
    "you" -> Tab.You
    else -> null
}

/** Top-level: onboarding gates the app, then the 3-tab scaffold (parity with iOS RootView). */
@Composable
fun RootScreen() {
    val context = LocalContext.current
    val profile = remember { ProfileStore.get(context) }

    // DEBUG-only demo mode: seed the synthetic dataset once and jump straight into the app
    // (skip onboarding), without ever requiring the live P2P node.
    if (DemoEnv.isDemo) {
        LaunchedEffect(Unit) {
            HavenNet.init(context)
            DemoSeeder.seed(context)
            if (!DemoEnv.noNet) HavenNet.start()
        }
        MainScaffold()
        return
    }

    Crossfade(targetState = profile.onboarded, label = "root") { onboarded ->
        if (!onboarded) {
            OnboardingScreen { name, emoji ->
                HavenCore.get(context)           // generate + persist identity on first run
                profile.completeOnboarding(name, emoji)
            }
        } else {
            MainScaffold()
        }
    }
}

@Composable
private fun MainScaffold() {
    val context = LocalContext.current
    var tab by remember { mutableStateOf(demoTab() ?: Tab.Circle) }
    var showConnect by remember { mutableStateOf(false) }

    // Deep-linked invite (haven:// or the invite web page) → surface the Connect screen, which
    // consumes the pending link and connects (parity with iOS's incomingLink flow).
    LaunchedEffect(com.blaineam.haven.core.InviteInbox.pending) {
        if (com.blaineam.haven.core.InviteInbox.pending != null) showConnect = true
    }

    // Bring the transport up once we're past onboarding; re-sync on resume. In demo mode the
    // RootScreen LaunchedEffect already did init/seed, and `haven_no_net` keeps the node offline.
    LaunchedEffect(Unit) {
        if (DemoEnv.isDemo) {
            if (!DemoEnv.noNet) {
                HavenNet.start()
                com.blaineam.haven.core.CallManager.init(context, HavenNet.nodeIdHex)
            }
        } else {
            HavenNet.init(context)
            HavenNet.start()
            com.blaineam.haven.core.CallManager.init(context, HavenNet.nodeIdHex)
            com.blaineam.haven.core.ConnectionService.restoreIfEnabled(context)
            HavenNet.restoreNearbyIfWanted()   // default-on; auto-starts when perms already granted
        }
    }
    // Notification permission on Android 13+ (no-op below).
    val notifPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(Unit) {
        if (android.os.Build.VERSION.SDK_INT >= 33) notifPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val obs = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    HavenNet.isForeground = true; HavenNet.syncWithContacts(); HavenNet.requestMissingMedia()
                    com.blaineam.haven.core.ScheduledStore.fireDue()   // post anything now due
                }
                Lifecycle.Event.ON_PAUSE -> {
                    HavenNet.isForeground = false
                    MusicPlayer.stop()   // don't leave a 30s song preview playing after leaving the app
                }
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
    }

    Scaffold(
        containerColor = HavenTheme.background,
        bottomBar = {
            // Hide the tab bar while the keyboard is up so the composer sits flush on it (no
            // tab-bar-height gap above the keyboard, matching iOS).
            val imeUp = androidx.compose.foundation.layout.WindowInsets.ime
                .getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0
            val inCall by com.blaineam.haven.core.CallManager.inCall
            val callMinimized by com.blaineam.haven.core.CallManager.minimized
            if (!imeUp) NavigationBar(containerColor = HavenTheme.card) {
                val navColors = NavigationBarItemDefaults.colors(
                    selectedIconColor = HavenTheme.pink,
                    selectedTextColor = HavenTheme.pink,
                    indicatorColor = HavenTheme.pink.copy(alpha = 0.14f),
                    unselectedIconColor = HavenTheme.textSecondary,
                    unselectedTextColor = HavenTheme.textSecondary,
                )
                // Messages tab badge = CONVERSATIONS with unread messages (per-thread read watermarks
                // in DmRead, iOS parity). Opening the tab clears nothing — each thread clears as it's
                // actually viewed. Recomputes on new messages (feedVersion) and on reads (DmRead.version,
                // which self-sync also bumps when another device reads a thread).
                val feedTick by HavenNet.feedVersion
                val readTick by com.blaineam.haven.core.DmRead.version
                val unreadDms = remember(feedTick, readTick) { HavenNet.unreadDmConversations() }
                Tab.entries.forEach { t ->
                    // Badge the Circle tab with the number of pending connection requests (parity with
                    // iOS, which badges the circle tab). `pending` is a SnapshotStateList so this updates live.
                    val badgeCount = when (t) {
                        Tab.Circle -> HavenNet.pending.size
                        Tab.Messages -> unreadDms
                        else -> 0
                    }
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tab = t },
                        icon = {
                            if (badgeCount > 0) {
                                androidx.compose.material3.BadgedBox(
                                    badge = { androidx.compose.material3.Badge(containerColor = HavenTheme.pink) { Text("$badgeCount") } },
                                ) { Icon(t.icon, contentDescription = t.label) }
                            } else {
                                Icon(t.icon, contentDescription = t.label)
                            }
                        },
                        label = { Text(t.label) },
                        colors = navColors,
                    )
                }
                // A minimized call shows as a "Call" tab to the right of You (iOS parity), not a banner.
                if (inCall && callMinimized) {
                    NavigationBarItem(
                        selected = false,
                        onClick = { com.blaineam.haven.core.CallManager.minimized.value = false },
                        icon = { Icon(Icons.Filled.Call, contentDescription = "Return to call", tint = HavenTheme.pink) },
                        label = { Text("Call", color = HavenTheme.pink) },
                        colors = navColors,
                    )
                }
            }
        },
    ) { inner ->
        Box(Modifier.fillMaxSize().padding(inner)) {
            when (tab) {
                Tab.Circle -> CircleScreen(onAddFriend = { showConnect = true })
                Tab.Messages -> MessagesScreen()
                Tab.You -> YouScreen(onAddFriend = { showConnect = true })
            }
        }
    }

    // Connect sheet (full-screen slide-up).
    AnimatedVisibility(
        visible = showConnect,
        enter = slideInVertically { it },
        exit = slideOutVertically { it },
    ) {
        ConnectScreen(onDone = { showConnect = false })
    }

    // Call overlay (incoming ring / in-call mesh grid) sits above everything.
    CallOverlay()
}
