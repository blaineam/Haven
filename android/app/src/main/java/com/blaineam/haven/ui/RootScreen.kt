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
import androidx.compose.material.icons.filled.Notifications
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
            OnboardingScreen { name, emoji, avatarB64 ->
                HavenCore.get(context)           // generate + persist identity on first run
                profile.completeOnboarding(name, emoji)
                // After completeOnboarding: setAvatar mirrors into AvatarStore under our node id,
                // which only exists once HavenCore has generated the identity above.
                if (avatarB64.isNotBlank()) profile.setAvatar(avatarB64)
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
    var showActivity by remember { mutableStateOf(false) }
    var openPost by remember { mutableStateOf<com.blaineam.haven.core.DeepLink.Post?>(null) }
    var pendingInvite by remember { mutableStateOf<String?>(null) }

    // Deep-linked invite (haven:// or the invite web page) → surface the Connect screen with the
    // link already resolved to its safety-word confirmation (parity with iOS's incomingLink flow).
    //
    // The link is taken from the inbox HERE and handed to ConnectScreen as an argument, rather than
    // ConnectScreen reaching into the global inbox itself. A single-consume global read from inside
    // a screen is only correct while exactly one copy of that screen can ever exist — the thing that
    // stopped being true whenever a second composition was alive, and the reason a tapped invite
    // opened Connect on the wrong tab. Now whoever gets the link owns it, and it lives in state until
    // the sheet is closed.
    LaunchedEffect(com.blaineam.haven.core.InviteInbox.pending) {
        com.blaineam.haven.core.InviteInbox.consume()?.let { pendingInvite = it; showConnect = true }
    }

    // Deep-linked post (https #p/<c>.<p> or legacy haven://p/<c>/<p>) → present that post.
    // A locked circle takes precedence: switch to it and let CircleScreen's lock screen take over
    // rather than revealing the post — a link can never be used to peek past the lock.
    LaunchedEffect(com.blaineam.haven.core.PostLinkInbox.pending) {
        com.blaineam.haven.core.PostLinkInbox.consume()?.let { p ->
            if (com.blaineam.haven.core.CircleLock.needsUnlock(p.circleId)) {
                HavenNet.setActiveCircle(p.circleId)
                tab = Tab.Circle
            } else openPost = p
        }
    }

    // Deep-linked circle (haven://c/<circleId> — a notification that only names the circle) →
    // switch to that circle's feed. Same lock rule as the post path: a locked circle switches to
    // its lock screen (CircleScreen gates itself on CircleLock), never past it.
    LaunchedEffect(com.blaineam.haven.core.CircleLinkInbox.pending) {
        com.blaineam.haven.core.CircleLinkInbox.consume()?.let { c ->
            HavenNet.setActiveCircle(c.circleId)
            tab = Tab.Circle
        }
    }

    // A DM draft staged from another surface ("Message the author" on a post) → go to the Messages
    // tab, where MessagesScreen consumes the signal and opens the thread with the draft waiting in
    // the composer. Only the TAB switch happens here; consuming is MessagesScreen's job, so this
    // can't race it away before that screen is composed.
    val stagedDm by com.blaineam.haven.core.DmDrafts.openThread
    LaunchedEffect(stagedDm) { if (stagedDm != null) tab = Tab.Messages }

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
                    HavenNet.bumpActivity()   // back to foreground → snap sync cadence tight
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

    // ---- System back ---------------------------------------------------------------------------
    //
    // Haven navigates by STATE, not by a fragment/activity stack, so the platform had nothing to pop
    // and every back press fell through to the activity: back closed the app from anywhere — a DM,
    // Settings, the Activity list, a tab that wasn't Circle. That is not how an Android app behaves.
    //
    // These handlers put the state back on the stack. Compose dispatches back to the MOST RECENTLY
    // composed enabled handler, so declaration order here IS priority order, innermost last: the tab
    // fallback is registered before the tab content (which adds its own, e.g. an open DM thread),
    // which is registered before the sheets below. Anything hosted in a FullScreenOverlay is a
    // Dialog and already handles back for itself.
    //
    // Circle is the root: back from there still leaves the app, which is the one case where exiting
    // is right.
    androidx.activity.compose.BackHandler(enabled = tab != Tab.Circle) { tab = Tab.Circle }

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
                // Activity bell: reactions/comments on MY posts, new posts/stories/DMs, connections
                // — badge = rows newer than the (self-synced) read watermark.
                com.blaineam.haven.core.ActivityStore.version.intValue
                val unseen = com.blaineam.haven.core.ActivityStore.unseenCount()
                NavigationBarItem(
                    selected = false,
                    onClick = { showActivity = true },
                    icon = {
                        if (unseen > 0) {
                            androidx.compose.material3.BadgedBox(
                                badge = { androidx.compose.material3.Badge(containerColor = HavenTheme.pink) { Text("$unseen") } },
                            ) { Icon(Icons.Filled.Notifications, contentDescription = "Activity") }
                        } else {
                            Icon(Icons.Filled.Notifications, contentDescription = "Activity")
                        }
                    },
                    label = { Text("Activity") },
                    colors = navColors,
                )
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

    // The three slide-up sheets are plain composables in this tree (not Dialogs), so each needs its
    // own back handler. Registered after the tab content, so an open sheet wins over it.
    androidx.activity.compose.BackHandler(enabled = showConnect) { showConnect = false }
    androidx.activity.compose.BackHandler(enabled = showActivity) { showActivity = false }
    androidx.activity.compose.BackHandler(enabled = openPost != null) { openPost = null }

    // Connect sheet (full-screen slide-up).
    AnimatedVisibility(
        visible = showConnect,
        enter = slideInVertically { it },
        exit = slideOutVertically { it },
    ) {
        ConnectScreen(initialLink = pendingInvite, onDone = { showConnect = false; pendingInvite = null })
    }

    // Activity sheet (same slide-up). Rows jump via the EXISTING routes: PostLinkInbox /
    // CircleLinkInbox (their LaunchedEffects above), DmDrafts.openThread (the Messages switch),
    // and showConnect — no routing of its own.
    AnimatedVisibility(
        visible = showActivity,
        enter = slideInVertically { it },
        exit = slideOutVertically { it },
    ) {
        ActivityScreen(
            onDone = { showActivity = false },
            onConnect = { showActivity = false; showConnect = true },
        )
    }

    // Deep-linked post sheet (same slide-up as Connect).
    val postSheet = openPost
    AnimatedVisibility(
        visible = postSheet != null,
        enter = slideInVertically { it },
        exit = slideOutVertically { it },
    ) {
        // Latch the post so it survives the exit animation — reading `openPost` directly would blank
        // the sheet the instant it's cleared, mid-slide.
        val shown = remember { mutableStateOf(postSheet) }
        if (postSheet != null) shown.value = postSheet
        shown.value?.let { PostLinkScreen(it.circleId, it.postId, onDone = { openPost = null }) }
    }

    // Call overlay (incoming ring / in-call mesh grid) sits above everything.
    CallOverlay()
}
