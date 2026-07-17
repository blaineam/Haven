package com.blaineam.haven.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddReaction
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.AccessTime
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.foundation.lazy.grid.items as gridItems
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.ProfileStore
import com.blaineam.haven.core.PendingRequest
import com.blaineam.haven.core.SyncMetrics
import com.blaineam.haven.core.loadAndDownscale
import com.blaineam.haven.core.nowMs
import kotlinx.coroutines.launch
import uniffi.haven_ffi.CircleUpgradeOffer
import uniffi.haven_ffi.FeedItemFfi

/** The Circle (feed) — real posts from the shared engine, a composer, and pending requests. */
@Composable
fun CircleScreen(onAddFriend: () -> Unit) {
    val context = LocalContext.current
    var draft by remember { mutableStateOf("") }
    // Staged media for the next post — photos/videos AND a `geo:` location ref (multi-attach, iOS parity).
    val pendingMedia = remember { androidx.compose.runtime.mutableStateListOf<String>() }
    var pendingMusic by remember { mutableStateOf<uniffi.haven_ffi.TrackRefFfi?>(null) }
    var showMusicDialog by remember { mutableStateOf(false) }
    // A link shared into Haven from another app prefills the composer.
    val sharedText = com.blaineam.haven.core.ShareInbox.pending
    LaunchedEffect(sharedText) {
        if (!sharedText.isNullOrBlank()) {
            draft = if (draft.isBlank()) sharedText else "$draft $sharedText"
            com.blaineam.haven.core.ShareInbox.take()
        }
    }
    // Photos/videos shared in from another app attach to the next post.
    val sharedMedia = com.blaineam.haven.core.ShareInbox.pendingMedia
    LaunchedEffect(sharedMedia) {
        if (sharedMedia.isNotEmpty()) {
            pendingMedia.addAll(com.blaineam.haven.core.ShareInbox.takeMedia())
        }
    }
    val profile = remember { com.blaineam.haven.core.ProfileStore.get(context) }
    val version by HavenNet.feedVersion          // recompose when the feed changes
    val circlesVersion by HavenNet.circlesVersion
    val active by HavenNet.activeCircle
    val circleSettingsVersion by com.blaineam.haven.core.CircleSettings.version
    val showHidden by com.blaineam.haven.core.HiddenStore.showHidden
    val hiddenCount = com.blaineam.haven.core.HiddenStore.hidden.size
    // Viewing a circle's feed is the purge hook: really drop expired events + GC their media blobs
    // (throttled inside — once per circle per app session).
    LaunchedEffect(active) { HavenNet.maybePurgeExpiredMedia(active) }
    val items: List<FeedItemFfi> = remember(version, active, profile.retentionDays, circleSettingsVersion, circlesVersion, HavenNet.blocked.size, showHidden, hiddenCount) {
        // Per-circle auto-delete override (falls back to the app-wide retention default).
        val raw = runCatching { HavenNet.engine.feed(active, nowMs(), com.blaineam.haven.core.CircleSettings.retentionSecs(active)) }.getOrDefault(emptyList())
        // Hide posts from blocked people and from anyone no longer in this circle (removed members),
        // so a removal actually clears their content even if a later sync re-ingests their old events.
        // null = the lookup failed (don't blank the feed); empty list = a genuine solo circle (hide
        // everyone else). My own posts always stay.
        val memberHexes: List<String>? = runCatching { HavenNet.membersOf(active).map { it.idHex } }.getOrNull()
        raw.filter { fi ->
            val allowedAuthor = when {
                fi.isMe -> true
                HavenNet.blocked.any { it.startsWith(fi.authorShort) } -> false
                memberHexes == null -> true   // membership lookup failed — don't hide everything
                else -> memberHexes.any { it.startsWith(fi.authorShort) }
            }
            // Personal per-post hide (reversible via the "show hidden" toggle).
            allowedAuthor && (showHidden || !com.blaineam.haven.core.HiddenStore.isHidden(fi.id))
        }
    }
    val storyGroups = remember(items) { groupStories(items) }
    // Stories live in the tray, not the list. Unsent posts are gone too — a "Message unsent" tombstone
    // in the feed is clutter, not information (PostCard still renders it for a deep link / comment sheet).
    val posts = remember(items) { items.filter { !it.story && !it.unsent } }
    // Reports filed by ANY member — the circle's shared moderation signal, grouped per post.
    val reportsByTarget = remember(version, active) { HavenNet.reports(active) }
    var viewingStory by remember { mutableStateOf<Int?>(null) }
    var showStoryCamera by remember { mutableStateOf(false) }
    var showPostCamera by remember { mutableStateOf(false) }   // in-app camera capture for a post
    var disappearSecs by remember { mutableStateOf<ULong?>(null) }  // disappearing post (retention)
    var showDisappearMenu by remember { mutableStateOf(false) }
    var showSchedule by remember { mutableStateOf(false) }   // "send later" dialog
    var cameraForPost by remember { mutableStateOf(false) }
    val camPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants[android.Manifest.permission.CAMERA] == true) { if (cameraForPost) showPostCamera = true else showStoryCamera = true }
    }
    fun openCamera(forPost: Boolean) {
        cameraForPost = forPost
        if (androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA)
            == android.content.pm.PackageManager.PERMISSION_GRANTED) { if (forPost) showPostCamera = true else showStoryCamera = true }
        else camPermission.launch(arrayOf(android.Manifest.permission.CAMERA, android.Manifest.permission.RECORD_AUDIO))
    }
    fun openStoryCamera() = openCamera(false)
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) { uris ->
        val cid = HavenNet.activeCircle.value
        uris.forEach { uri ->
            val ref = if (com.blaineam.haven.core.isVideoUri(context, uri))
                com.blaineam.haven.core.readVideoBytes(context, uri)?.let { LocalMedia.store(cid, it, isVideo = true) }
            else loadAndDownscale(context, uri)?.let { LocalMedia.store(cid, it) }
            if (ref != null) pendingMedia.add(ref)
        }
    }
    // Location: best-effort current location → a geo: ref appended to the post (iOS parity).
    val locPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants.values.any { it }) com.blaineam.haven.core.LocationShare.currentRef(context)?.let { pendingMedia.add(it) }
    }
    fun attachLocation() {
        val fine = androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val coarse = androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (fine || coarse) com.blaineam.haven.core.LocationShare.currentRef(context)?.let { pendingMedia.add(it) }
        else locPermission.launch(arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION, android.Manifest.permission.ACCESS_COARSE_LOCATION))
    }

    HavenBackground {
        Column(Modifier.fillMaxSize().imePadding()) {
            // Title bar (compact — every vertical pixel counts on phones).
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 10.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircleSwitcher(active, circlesVersion)
                Spacer(Modifier.weight(1f))
                ConnectionDot()
                Box(
                    Modifier.size(40.dp).clip(CircleShape).clickable { onAddFriend() },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.PersonAdd, "Add a friend", tint = HavenTheme.pink) }
            }

            val lockV by com.blaineam.haven.core.CircleLock.version
            val locked = remember(active, lockV) { com.blaineam.haven.core.CircleLock.needsUnlock(active) }
            if (locked) {
                // A locked circle hides EVERYTHING in it — stories, posts and the composer — until unlock.
                Column(Modifier.fillMaxWidth().weight(1f).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Text("🔒", fontSize = 48.sp)
                    Spacer(Modifier.height(12.dp))
                    Text("This circle is locked", color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(6.dp))
                    Text("Stories, posts and messages stay hidden until you unlock.",
                        color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(16.dp))
                    BrandButton(text = "Unlock", modifier = Modifier.fillMaxWidth(0.6f)) {
                        (context as? androidx.fragment.app.FragmentActivity)?.let {
                            com.blaineam.haven.core.CircleLock.authenticate(it, active) {}
                        }
                    }
                }
            } else {
                // Exactly ONE post plays its video at a time — the one nearest the viewport centre
                // (iOS AudioCoordinator/centeredPostId parity). derivedStateOf so a scroll only
                // recomposes the two cards whose active-ness actually flipped, not the feed per frame.
                val feedState = androidx.compose.foundation.lazy.rememberLazyListState()
                val centeredPost by remember(feedState) {
                    androidx.compose.runtime.derivedStateOf {
                        val info = feedState.layoutInfo
                        val mid = (info.viewportStartOffset + info.viewportEndOffset) / 2
                        // Posts are the only items keyed by a String (their id) — the tray/banner
                        // items carry Compose's generated keys, so they can never become active.
                        info.visibleItemsInfo
                            .filter { it.key is String }
                            .minByOrNull { kotlin.math.abs(it.offset + it.size / 2 - mid) }
                            ?.key as? String
                    }
                }
                // Stories + pending scroll WITH the posts so there's maximum room to browse.
                LazyColumn(
                    Modifier.fillMaxWidth().weight(1f),
                    state = feedState,
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    item { StoriesTray(groups = storyGroups, onAddStory = { openStoryCamera() }, onOpen = { viewingStory = it }) }
                    if (HavenNet.pending.isNotEmpty()) item {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { HavenNet.pending.forEach { PendingCard(it) } }
                    }
                    // Renders nothing unless someone has offered to carry this circle onto an owned one.
                    item { CircleUpgradeBanner(active) }
                    // Renders nothing until the circle outgrows a pair and still has no relay of its own.
                    item { RelayNudgeBanner(active) }
                    if (posts.isEmpty()) item {
                        Column(Modifier.fillMaxWidth().height(260.dp).padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                            Text("Nothing here yet", color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.height(8.dp))
                            Text(
                                if (HavenNet.contacts.isEmpty())
                                    "Add a friend to start sharing.\nEverything you post is end-to-end encrypted to your circle."
                                else "Say something to your circle below.",
                                color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center,
                            )
                        }
                    } else items(posts, key = { it.id }) {
                        PostCard(it, active, reportsByTarget[it.id].orEmpty(), videoActive = it.id == centeredPost)
                    }
                }
            }

            if (!locked) {
            // Staged media preview (multiple photos/videos + a location pin), each removable.
            if (pendingMedia.isNotEmpty()) {
                androidx.compose.foundation.lazy.LazyRow(
                    Modifier.fillMaxWidth().padding(start = 16.dp, bottom = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(pendingMedia.size) { i ->
                        val ref = pendingMedia[i]
                        Box {
                            when {
                                com.blaineam.haven.core.LocationShare.isLocation(ref) ->
                                    Box(Modifier.size(64.dp).clip(RoundedCornerShape(12.dp)).background(HavenTheme.card),
                                        contentAlignment = Alignment.Center) {
                                        Icon(Icons.Filled.Place, "Location", tint = HavenTheme.pink, modifier = Modifier.size(26.dp))
                                    }
                                LocalMedia.isVideo(ref) ->
                                    Box(Modifier.size(64.dp).clip(RoundedCornerShape(12.dp)).background(HavenTheme.card),
                                        contentAlignment = Alignment.Center) {
                                        Icon(Icons.Filled.Videocam, "Video", tint = HavenTheme.textPrimary, modifier = Modifier.size(26.dp))
                                    }
                                else -> MediaImage(active, ref, Modifier.size(64.dp).clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Crop)
                            }
                            // White-on-black-scrim over the media thumb — not a theme surface.
                            Text("✕", color = Color.White, fontSize = 13.sp,
                                modifier = Modifier.align(Alignment.TopEnd).padding(3.dp).clip(CircleShape)
                                    .background(Color.Black.copy(alpha = 0.6f)).clickable { pendingMedia.remove(ref) }
                                    .padding(horizontal = 6.dp, vertical = 1.dp))
                        }
                    }
                }
            }
            // Staged music chip.
            pendingMusic?.let { m ->
                Row(Modifier.padding(start = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.pink, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("${m.title} · ${m.artist}", color = HavenTheme.textPrimary, fontSize = 12.sp, maxLines = 1)
                    Spacer(Modifier.size(8.dp))
                    Text("✕", color = HavenTheme.textSecondary, fontSize = 14.sp,
                        modifier = Modifier.clickable { pendingMusic = null })
                }
            }
            // Composer options: camera · photo/video · music · disappearing (iOS parity).
            Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 2.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { openCamera(true) },
                    contentAlignment = Alignment.Center) { Icon(Icons.Filled.PhotoCamera, "Camera", tint = HavenTheme.pink) }
                Box(Modifier.size(40.dp).clip(CircleShape).clickable {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.AddPhotoAlternate, "Add photo or video", tint = HavenTheme.pink) }
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { showMusicDialog = true },
                    contentAlignment = Alignment.Center) { Icon(Icons.Filled.MusicNote, "Add a song", tint = HavenTheme.pink) }
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { attachLocation() },
                    contentAlignment = Alignment.Center) { Icon(Icons.Filled.Place, "Share location", tint = HavenTheme.pink) }
                Box(Modifier.size(40.dp).clip(CircleShape).clickable {
                    if (draft.isNotBlank() || pendingMedia.isNotEmpty()) showSchedule = true
                }, contentAlignment = Alignment.Center) { Icon(Icons.Filled.Schedule, "Schedule send", tint = HavenTheme.pink) }
                Spacer(Modifier.weight(1f))
                SyncStatusBadge(active)
                Box {
                    Row(Modifier.clip(CircleShape)
                        .background(if (disappearSecs != null) HavenTheme.pink.copy(alpha = 0.2f) else Color.Transparent)
                        .clickable { showDisappearMenu = true }.padding(horizontal = 10.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Timer, "Disappearing",
                            tint = if (disappearSecs != null) HavenTheme.pink else HavenTheme.textSecondary, modifier = Modifier.size(18.dp))
                        if (disappearSecs != null) { Spacer(Modifier.size(4.dp)); Text(disappearLabel(disappearSecs!!), fontSize = 12.sp, color = HavenTheme.pink) }
                    }
                    DropdownMenu(expanded = showDisappearMenu, onDismissRequest = { showDisappearMenu = false }) {
                        listOf<Pair<String, ULong?>>(
                            "Don't disappear" to null, "After 1 hour" to 3_600uL,
                            "After 1 day" to 86_400uL, "After 1 week" to 604_800uL,
                        ).forEach { (label, secs) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { disappearSecs = secs; showDisappearMenu = false })
                        }
                    }
                }
            }
            // Composer text + send.
            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 2.dp, bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = draft, onValueChange = { draft = it },
                    placeholder = { Text("Share with your circle…") },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(22.dp), maxLines = 4,
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                )
                Spacer(Modifier.size(8.dp))
                val canPost = draft.isNotBlank() || pendingMedia.isNotEmpty() || pendingMusic != null
                // The glyph is white-on-brand-gradient — never themed.
                Box(Modifier.size(48.dp).clip(CircleShape).background(HavenTheme.brandHorizontal)
                    .clickable(enabled = canPost) {
                        HavenNet.post(active, draft.trim(), pendingMedia.toList(), pendingMusic, retentionSecs = disappearSecs)
                        draft = ""; pendingMedia.clear(); pendingMusic = null; disappearSecs = null
                    }, contentAlignment = Alignment.Center) { Icon(Icons.AutoMirrored.Filled.Send, "Post", tint = Color.White) }
            }
            }
        }

    }

    // Full-screen overlays (a borderless Dialog draws above the tab bar — true full-screen).
    viewingStory?.let { start ->
        FullScreenOverlay(onDismiss = { viewingStory = null }) {
            StoryViewer(groups = storyGroups, startGroup = start, onClose = { viewingStory = null })
        }
    }
    if (showStoryCamera) {
        FullScreenOverlay(onDismiss = { showStoryCamera = false }) {
            StoryCameraScreen(onClose = { showStoryCamera = false })
        }
    }
    if (showPostCamera) {
        // In-app camera for a POST: a capture is attached to the composer (stored under the active
        // circle's key) — no story editor.
        FullScreenOverlay(onDismiss = { showPostCamera = false }) {
            StoryCameraScreen(
                onClose = { showPostCamera = false },
                storeCircle = active,
                onCaptured = { ref, _ -> pendingMedia.add(ref); showPostCamera = false },
            )
        }
    }
    if (showMusicDialog) {
        FullScreenOverlay(onDismiss = { showMusicDialog = false }) {
            MusicSearchSheet(
                onPick = { track -> pendingMusic = track; showMusicDialog = false },
                onDismiss = { showMusicDialog = false },
            )
        }
    }
    if (showSchedule) {
        fun doSchedule(sendAtMs: Long) {
            com.blaineam.haven.core.ScheduledStore.schedule(active, draft.trim(), pendingMedia.toList(), disappearSecs, sendAtMs)
            draft = ""; pendingMedia.clear(); pendingMusic = null; disappearSecs = null; showSchedule = false
        }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showSchedule = false }, containerColor = HavenTheme.card,
            title = { Text("Send later", color = HavenTheme.textPrimary) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Posts from this phone when the time comes (it catches up next time you open Haven).",
                        color = HavenTheme.textSecondary, fontSize = 12.sp)
                    val now = java.util.Calendar.getInstance()
                    fun at(addDays: Int, hour: Int): Long = (java.util.Calendar.getInstance().apply {
                        add(java.util.Calendar.DAY_OF_YEAR, addDays); set(java.util.Calendar.HOUR_OF_DAY, hour)
                        set(java.util.Calendar.MINUTE, 0); set(java.util.Calendar.SECOND, 0)
                    }).timeInMillis
                    val eveningToday = at(0, 19)
                    listOfNotNull(
                        "In 1 hour" to (now.timeInMillis + 3_600_000L),
                        if (eveningToday > now.timeInMillis) "This evening (7 PM)" to eveningToday else null,
                        "Tomorrow morning (9 AM)" to at(1, 9),
                    ).forEach { (label, ms) ->
                        Text(label, color = HavenTheme.pink, fontSize = 15.sp,
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { doSchedule(ms) }.padding(vertical = 10.dp))
                    }
                    Text("Pick a date & time…", color = HavenTheme.textPrimary, fontSize = 15.sp,
                        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable {
                            val c = java.util.Calendar.getInstance()
                            android.app.DatePickerDialog(context, { _, y, mo, d ->
                                android.app.TimePickerDialog(context, { _, h, mi ->
                                    val cal = java.util.Calendar.getInstance().apply { set(y, mo, d, h, mi, 0) }
                                    if (cal.timeInMillis > System.currentTimeMillis()) doSchedule(cal.timeInMillis)
                                }, c.get(java.util.Calendar.HOUR_OF_DAY), c.get(java.util.Calendar.MINUTE), false).show()
                            }, c.get(java.util.Calendar.YEAR), c.get(java.util.Calendar.MONTH), c.get(java.util.Calendar.DAY_OF_MONTH))
                                .apply { datePicker.minDate = System.currentTimeMillis() }.show()
                        }.padding(vertical = 10.dp))
                }
            },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { showSchedule = false }) { Text("Cancel", color = HavenTheme.textSecondary) } },
        )
    }
}

/** Circle roster + settings (iOS parity): rename, see members, remove/block a member, leave. */
@Composable
private fun CircleManageSheet(circleId: String, onDismiss: () -> Unit) {
    val circlesVersion by HavenNet.circlesVersion
    val version by HavenNet.feedVersion
    var name by remember { mutableStateOf(HavenNet.circleName(circleId)) }
    val members = remember(circlesVersion, version, circleId) { HavenNet.membersOf(circleId) }
    val isDefault = circleId == com.blaineam.haven.core.DEFAULT_CIRCLE
    val cs = com.blaineam.haven.core.CircleSettings
    val csVersion by cs.version
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss, containerColor = HavenTheme.card,
        title = { Text("Circle settings", color = HavenTheme.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!isDefault) {
                    OutlinedTextField(
                        value = name, onValueChange = { name = it }, singleLine = true,
                        label = { Text("Circle name") }, modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                    )
                }
                // Per-circle media overrides (parity with iOS "Media in this circle"). Each falls
                // back to the app-wide default in Settings unless pinned here.
                key(csVersion) {
                    Text("Media in this circle", color = HavenTheme.textSecondary, fontSize = 12.sp)
                    OverrideRow("Save your posts", cs.saveOwnOverride(circleId)) { cs.setSaveOwn(circleId, it) }
                    OverrideRow("Save others' posts", cs.saveOthersOverride(circleId)) { cs.setSaveOthers(circleId, it) }
                    OverrideRow("Auto-optimize media", cs.optimizeOverride(circleId)) { cs.setOptimize(circleId, it) }
                    RetentionOverrideRow(cs.retentionOverride(circleId)) { cs.setRetention(circleId, it) }
                    Text("Override the app-wide Photos / optimize / auto-delete defaults just for this circle.",
                        color = HavenTheme.textSecondary, fontSize = 11.sp)
                }
                // Per-circle relay OVERRIDE: pick which CONFIGURED relays this circle uses. Adding /
                // removing relays lives under Settings ▸ Relays — not here.
                CircleRelaySection(circleId)
                Text("Members (${members.size})", color = HavenTheme.textSecondary, fontSize = 12.sp)
                if (members.isEmpty()) {
                    Text("No one else yet — invite a friend to this circle.", color = HavenTheme.textSecondary, fontSize = 13.sp)
                }
                members.forEach { m ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        HavenAvatar(m.idHex, m.name, size = 30.dp)
                        Spacer(Modifier.size(8.dp))
                        Text(m.name, color = HavenTheme.textPrimary, modifier = Modifier.weight(1f), maxLines = 1)
                        Text("Remove", color = HavenTheme.pink, fontSize = 13.sp,
                            modifier = Modifier.clickable { HavenNet.removeFromCircle(circleId, m.idHex) }.padding(horizontal = 6.dp, vertical = 4.dp))
                        Text("Block", color = Color(0xFFEF4444), fontSize = 13.sp,
                            modifier = Modifier.clickable { HavenNet.block(m.idHex) }.padding(horizontal = 6.dp, vertical = 4.dp))
                    }
                }
            }
        },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = {
                if (!isDefault && name.isNotBlank()) HavenNet.renameCircle(circleId, name.trim())
                onDismiss()
            }) { Text("Done", color = HavenTheme.pink) }
        },
        dismissButton = {
            if (!isDefault) androidx.compose.material3.TextButton(onClick = { HavenNet.leaveCircle(circleId); onDismiss() }) {
                Text("Leave circle", color = Color(0xFFEF4444))
            }
        },
    )
}

/** Tri-state per-circle override: Auto (inherit global) / On / Off. */
@Composable
private fun OverrideRow(label: String, current: Boolean?, onSet: (Boolean?) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = HavenTheme.textPrimary, fontSize = 13.sp, modifier = Modifier.weight(1f), maxLines = 1)
        OverrideSeg("Auto", current == null) { onSet(null) }
        OverrideSeg("On", current == true) { onSet(true) }
        OverrideSeg("Off", current == false) { onSet(false) }
    }
}

@Composable
private fun OverrideSeg(text: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        text,
        color = if (selected) HavenTheme.textPrimary else HavenTheme.textSecondary,
        fontSize = 12.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
        modifier = Modifier.clip(RoundedCornerShape(6.dp))
            .background(if (selected) HavenTheme.pink.copy(alpha = 0.28f) else Color.Transparent)
            .clickable { onClick() }.padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

/**
 * Per-circle relay OVERRIDE: toggle which of your CONFIGURED relays this circle uses. Adding /
 * removing / configuring relays lives under Settings ▸ Relays — this only SELECTS among the ones you
 * already configured. The all-circles default always applies (shown but locked). Parity with iOS
 * `CircleRelayOverrideSection`, wired to HavenNet's per-circle relay associations.
 */
@Composable
private fun CircleRelaySection(circleId: String) {
    val relaysVersion by HavenNet.relaysVersion
    val configured = remember(relaysVersion) { HavenNet.allRelayEntries().filter { it.active } }
    val explicit = remember(relaysVersion, circleId) { HavenNet.explicitRelaysForCircle(circleId).toSet() }
    val default = remember(relaysVersion) { HavenNet.defaultRelay() }

    Text("Relays for this circle", color = HavenTheme.textSecondary, fontSize = 12.sp)
    if (configured.isEmpty()) {
        Text("No relays configured. Add one under Settings ▸ Relays so this circle's posts reach people who were offline.",
            color = HavenTheme.textSecondary, fontSize = 11.sp)
        return
    }
    configured.forEach { e ->
        val isDefault = default == e.hex
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(e.name, color = HavenTheme.textPrimary, fontSize = 13.sp, maxLines = 1)
                if (isDefault) Text("Default — inherited by every circle", color = HavenTheme.textSecondary, fontSize = 10.sp)
            }
            androidx.compose.material3.Switch(
                checked = explicit.contains(e.hex) || isDefault,
                enabled = !isDefault,   // the default is always on; manage it under Settings ▸ Relays
                onCheckedChange = { on -> HavenNet.setCircleRelay(circleId, e.hex, on) },
                colors = androidx.compose.material3.SwitchDefaults.colors(
                    checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
            )
        }
    }
    Text("Choose which configured relays this circle uses. The default relay (if set) always applies — change it under Settings ▸ Relays.",
        color = HavenTheme.textSecondary, fontSize = 11.sp)
}

/** Per-circle auto-delete override: Auto (inherit) / Keep forever / 1d / 1w / 30d / 1yr. */
@Composable
private fun RetentionOverrideRow(currentDays: Int?, onSet: (Int?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val label = when (currentDays) {
        null -> "Auto"; 0 -> "Keep forever"; 1 -> "After 1 day"; 7 -> "After 1 week"
        30 -> "After 30 days"; 365 -> "After 1 year"; else -> "After $currentDays days"
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("Auto-delete old posts", color = HavenTheme.textPrimary, fontSize = 13.sp, modifier = Modifier.weight(1f), maxLines = 1)
        Box {
            Text(label, color = HavenTheme.pink, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable { open = true }.padding(horizontal = 8.dp, vertical = 4.dp))
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                val opts = listOf<Pair<String, Int?>>(
                    "Auto (use default)" to null, "Keep forever" to 0, "After 1 day" to 1,
                    "After 1 week" to 7, "After 30 days" to 30, "After 1 year" to 365,
                )
                opts.forEach { (t, v) ->
                    DropdownMenuItem(text = { Text(t) }, onClick = { onSet(v); open = false })
                }
            }
        }
    }
}

/** Short label for a disappearing-post window (mirrors the composer chip). */
private fun disappearLabel(secs: ULong): String = when (secs) {
    3_600uL -> "1h"; 86_400uL -> "1d"; 604_800uL -> "1w"; else -> "${secs / 3_600uL}h"
}

/** Hosts content in a borderless full-screen dialog window so it covers the bottom tab bar too. */
@Composable
fun FullScreenOverlay(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    androidx.compose.ui.window.Dialog(
        onDismissRequest = onDismiss,
        properties = androidx.compose.ui.window.DialogProperties(
            usePlatformDefaultWidth = false, dismissOnClickOutside = false,
            // decorFitsSystemWindows=false or this Dialog reports EVERY window inset as 0 —
            // measured live: navBottom=0 imeBottom=0 statusTop=0. That makes navigationBarsPadding()
            // and imePadding() SILENT NO-OPS for anything inside, which is why the story viewer's
            // reply row sat under the gesture pill and could never lift above the keyboard. Content
            // here already asks for the insets it wants; this is what lets those requests be heard.
            decorFitsSystemWindows = false,
        ),
    ) {
        Box(Modifier.fillMaxSize().background(HavenTheme.background)) { content() }
    }
}

@Composable
private fun PendingCard(req: PendingRequest) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            .havenCard().padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("${req.name} wants to connect", color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text("Safety: ${com.blaineam.haven.core.SafetyWords.phrase(req.verifyHex)}",
                color = HavenTheme.textSecondary, fontSize = 11.sp)
        }
        Text("Accept", color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.approve(req) }.padding(8.dp))
        Text("Ignore", color = HavenTheme.textSecondary,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.dismiss(req) }.padding(8.dp))
    }
}

/** The marker an owned circle's id carries. Kept next to the UI that reasons about it; the core mints
 *  and verifies these ids — nothing here should ever try to construct one. */
private const val OWNED_CIRCLE_PREFIX = "c1"

/**
 * Carrying an older circle onto one with a verified owner.
 *
 * Circles made before 1.0.7 have no owner — nothing recorded who created them, because until the
 * group became shared it never mattered. Without an owner there's nobody a circle can check a removal
 * against, so those circles keep the encryption they already have rather than moving to the newer
 * group layer.
 *
 * The way across is an offer: whoever made the circle offers a replacement whose id is tied to them,
 * and each member decides whether to follow it. That decision is deliberately a person's, not the
 * app's: the offer is signed, and we can prove it really came from whoever signed it and that the
 * replacement is genuinely theirs — but nothing can prove they made the ORIGINAL circle, since it
 * never had an owner to record. So we show who is asking and let the user choose. If two people both
 * claim it, both are shown; the app picks neither.
 */
@Composable
private fun CircleUpgradeBanner(circleId: String) {
    // Following an offer stands up a new circle (circles); an offer ARRIVING is inbound traffic (feed).
    val circlesV by HavenNet.circlesVersion
    val feedV by HavenNet.feedVersion
    val offers = remember(circleId, circlesV, feedV) { HavenNet.pendingCircleUpgrades(circleId) }
    // Offers from OTHER people — mine need no confirmation (I made the offer).
    val theirs = offers.filter { !it.mine }

    if (theirs.isNotEmpty()) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { theirs.forEach { FollowUpgradeCard(circleId, it) } }
        return
    }
    // Can I offer to upgrade this one? Only a shared circle I made. `default` is your own personal
    // circle and `dm:` threads are two-party (both sides derive the same id, and there's nobody to
    // remove), so neither has anything to gain here.
    val iCanOffer = HavenNet.selfSyncCreatedCircle(circleId) &&
        !circleId.startsWith(OWNED_CIRCLE_PREFIX) && circleId != DEFAULT_CIRCLE && !circleId.startsWith("dm:") &&
        offers.none { it.mine }
    if (iCanOffer) OfferUpgradeCard(circleId)
}

/** Someone is asking us to follow their replacement. Named, never auto-accepted. */
@Composable
private fun FollowUpgradeCard(circleId: String, offer: CircleUpgradeOffer) {
    // Everything in this banner is white-on-brand-gradient — never themed.
    Row(
        Modifier.fillMaxWidth()
            .background(HavenTheme.brandHorizontal, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.VerifiedUser, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("${HavenNet.displayName(offer.fromHex)} is upgrading “${offer.name}”",
                color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(2.dp))
            // Say plainly what we can and can't vouch for — the user is the one deciding.
            Text(
                "They say they made this circle. We can't check that, so only follow if that's right — whoever you follow will be able to remove people.",
                color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp,
            )
        }
        Spacer(Modifier.width(8.dp))
        UpgradeAction("Follow") { HavenNet.followCircleUpgrade(circleId, offer.newCircleId) }
    }
}

/** I made this circle — offer its replacement. */
@Composable
private fun OfferUpgradeCard(circleId: String) {
    Row(
        Modifier.fillMaxWidth()
            .background(HavenTheme.brandHorizontal, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, tint = Color.White, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("Upgrade this circle", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(2.dp))
            Text(
                "Give it a verified owner, so removing someone cuts them off for good. Everyone here will be asked to follow.",
                color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp,
            )
        }
        Spacer(Modifier.width(8.dp))
        UpgradeAction("Upgrade") { HavenNet.offerCircleUpgrade(circleId) }
    }
}

/** The banner's action pill — solid white on the gradient, so it reads as the prominent action. */
@Composable
private fun UpgradeAction(text: String, onClick: () -> Unit) {
    Text(
        text,
        color = HavenTheme.violet, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.White)
            .clickable { onClick() }.padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

/**
 * Decode a stored (sealed) media id into an Image thumbnail, off the main thread. IMAGES are decoded
 * DOWNSAMPLED; VIDEOS get a poster frame via MediaMetadataRetriever (never decoded as an image — that
 * both fails and reads the whole file into RAM, which OOM-crashed the feed on low-heap phones when a
 * large synced video rendered). Media too big to decrypt on this device yields no bitmap: we show a
 * plain tile (a video overlays its play glyph) instead of an endless spinner.
 */
@Composable
fun MediaImage(circleId: String, id: String, modifier: Modifier = Modifier,
               contentScale: ContentScale = ContentScale.FillWidth) {
    val (bmp, done) = rememberMediaBitmap(circleId, id)
    MediaBitmapContent(circleId, id, bmp, done, modifier, contentScale)
}

/** Decrypt + decode a media ref's bitmap off the main thread, ONCE per (ref, circle) — `load()` is a
 *  full AEAD open of the whole file, so anything that wants these pixels shares this rather than
 *  asking again. Returns the bitmap (null = nothing to show) plus a done flag, so a caller can tell
 *  "still loading" from "there is no bitmap". */
@Composable
private fun rememberMediaBitmap(circleId: String, ref: String, reloadKey: Any? = null): Pair<ImageBitmap?, Boolean> {
    var bmp by remember(ref, circleId) { mutableStateOf<ImageBitmap?>(null) }
    var done by remember(ref, circleId) { mutableStateOf(false) }
    // Re-attempt whenever the feed bumps WHILE we still have nothing to show — this is how a tile
    // whose bytes were missing (still syncing, or a just-tapped "Download") flips to the real image
    // once the blob lands, without navigating away. It's cheap: with a bitmap already in hand the
    // guard below skips the decrypt entirely, so an established image never re-decodes on a bump.
    val fv = com.blaineam.haven.core.HavenNet.feedVersion.value
    // `reloadKey` re-asks WITHOUT clearing what's already drawn: a video's poster only becomes
    // readable once the clip has been decrypted to cache, and blinking the page out to go fetch it
    // would be worse than showing it a beat late.
    LaunchedEffect(ref, circleId, reloadKey, if (bmp == null) fv else 0) {
        if (bmp != null) return@LaunchedEffect   // already have pixels — a feed bump is a no-op here
        val b = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val raw = if (LocalMedia.isVideo(ref)) LocalMedia.videoPoster(circleId, ref)
                      else LocalMedia.imageBitmap(circleId, ref)
            raw?.asImageBitmap()
        }
        if (b != null || !done) bmp = b
        done = true
    }
    return bmp to done
}

/** The states of a media bitmap: the image, a graceful missing-media placeholder (bytes absent), a
 *  plain tile (bytes present but undrawable — e.g. an un-played video's missing poster), or a spinner. */
@Composable
private fun MediaBitmapContent(circleId: String, ref: String, bmp: ImageBitmap?, done: Boolean,
                               modifier: Modifier, contentScale: ContentScale) {
    // Observe the evicted-store version so this recomposes when a "Download" tap clears an eviction.
    com.blaineam.haven.core.EvictedMediaStore.version.value
    val hasBytes = remember(ref, com.blaineam.haven.core.HavenNet.feedVersion.value) { LocalMedia.has(ref) }
    when {
        bmp != null -> Image(bmp, contentDescription = "Photo", modifier = modifier, contentScale = contentScale)
        // Finished loading with no bitmap AND the bytes aren't on disk → the graceful placeholder
        // (a "Download N" affordance for a deliberately-evicted blob, a spinner while it's fetching,
        // or "No longer available"), NOT a perpetual blank spinner.
        done && !hasBytes -> MissingMediaPlaceholder(circleId, ref, LocalMedia.isVideo(ref), modifier)
        // Finished with bytes present but no bitmap (video with no poster yet, or too big to decode
        // here) → a plain tile. MediaThumb/MediaPage overlay the play glyph for videos.
        done -> Box(modifier.background(HavenTheme.card))
        else -> Box(modifier.background(HavenTheme.card), contentAlignment = Alignment.Center) {
            androidx.compose.material3.CircularProgressIndicator(
                color = HavenTheme.pink, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
        }
    }
}

/** A graceful placeholder for a referenced blob whose bytes aren't on disk. Four states, mirroring
 *  iOS `MissingMediaPlaceholder`:
 *   • deliberately evicted ("Manage media" / limit sweep) → a "Download N" affordance (re-fetches on tap);
 *   • actively downloading (post-tap) → a spinner;
 *   • relay/peers no longer have it → "No longer available" + Retry;
 *   • simply still syncing (never evicted) → the plain "still loading" spinner. */
@Composable
private fun MissingMediaPlaceholder(circleId: String, ref: String, isVideo: Boolean, modifier: Modifier) {
    val context = LocalContext.current
    // Observe live download state + the evicted-store version so the tile reacts to taps/timeouts.
    com.blaineam.haven.core.EvictedMediaStore.version.value
    val downloading = com.blaineam.haven.core.HavenNet.downloadingMedia.contains(ref)
    val unavailable = com.blaineam.haven.core.HavenNet.unavailableMedia.contains(ref)
    val evictedBytes = com.blaineam.haven.core.EvictedMediaStore.size(ref)
    Box(modifier.background(HavenTheme.card), contentAlignment = Alignment.Center) {
        when {
            downloading -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                androidx.compose.material3.CircularProgressIndicator(
                    color = HavenTheme.pink, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                Spacer(Modifier.height(8.dp))
                Text("Downloading…", color = HavenTheme.textSecondary, fontSize = 12.sp)
            }
            unavailable -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.WifiOff, null, tint = HavenTheme.textSecondary, modifier = Modifier.size(28.dp))
                Spacer(Modifier.height(6.dp))
                Text("No longer available", color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(6.dp))
                Text("Retry", color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp))
                        .clickable { com.blaineam.haven.core.HavenNet.downloadEvicted(ref) }
                        .padding(horizontal = 10.dp, vertical = 4.dp))
            }
            evictedBytes != null -> Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.clip(RoundedCornerShape(12.dp))
                    .clickable { com.blaineam.haven.core.HavenNet.downloadEvicted(ref) }
                    .padding(12.dp),
            ) {
                Icon(Icons.Filled.Download, null, tint = HavenTheme.pink, modifier = Modifier.size(34.dp))
                Spacer(Modifier.height(6.dp))
                Text("Download ${android.text.format.Formatter.formatShortFileSize(context, evictedBytes)}",
                    color = HavenTheme.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(2.dp))
                Text("Removed to save space", color = HavenTheme.textSecondary, fontSize = 11.sp)
            }
            else -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                androidx.compose.material3.CircularProgressIndicator(
                    color = HavenTheme.pink, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                Spacer(Modifier.height(8.dp))
                Text(if (isVideo) "Video still loading…" else "Media still loading…",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
            }
        }
    }
}

/** A small media thumbnail (image or a video tile with a play glyph), tappable to open. */
@Composable
private fun MediaThumb(circleId: String, ref: String, modifier: Modifier, onOpen: () -> Unit) {
    Box(modifier.clip(RoundedCornerShape(12.dp)).clickable { onOpen() }) {
        // Honors a flag federated by a member whose platform has an analyzer (iOS parity).
        SensitiveGuard(circleId, ref, cornerRadius = 12) { _ ->
            Box(Modifier.fillMaxSize()) {
                MediaImage(circleId, ref, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                // Glyph only when the bytes are here — else the missing-media placeholder owns the tile.
                if (LocalMedia.isVideo(ref) && LocalMedia.has(ref)) {
                    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
                        // White-on-scrim over media — not a theme surface.
                        Icon(Icons.Filled.PlayCircle, "Play", tint = Color.White, modifier = Modifier.size(40.dp))
                    }
                }
            }
        }
    }
}

/** Renders a `geo:` location ref as a chip; tap to open the spot in the system maps app. */
@Composable
fun LocationChip(ref: String) {
    val context = LocalContext.current
    val pin = com.blaineam.haven.core.LocationShare.parse(ref) ?: return
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(HavenTheme.card)
        .clickable {
            // Prefer the native maps app via a geo: URI, but many devices (e.g. the Nokia 6.1 with
            // no Google Maps) have NOTHING registered for the bare geo: scheme, so the intent silently
            // no-ops. Resolve first; if nothing handles it (or it throws), fall back to a plain
            // https maps URL any browser can open.
            val geoUri = android.net.Uri.parse("geo:${pin.lat},${pin.lon}?q=${pin.lat},${pin.lon}(${android.net.Uri.encode(pin.label)})")
            val geoIntent = android.content.Intent(android.content.Intent.ACTION_VIEW, geoUri)
            val handled = geoIntent.resolveActivity(context.packageManager) != null &&
                runCatching { context.startActivity(geoIntent) }.isSuccess
            if (!handled) {
                val webUri = android.net.Uri.parse(
                    "https://www.google.com/maps/search/?api=1&query=${pin.lat},${pin.lon}")
                runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, webUri)) }
            }
        }
        .padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(36.dp).clip(CircleShape).background(HavenTheme.pink.copy(alpha = 0.2f)), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Place, null, tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.size(10.dp))
        Column(Modifier.weight(1f)) {
            Text(pin.label, color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium, maxLines = 1)
            Text("Tap to open in Maps", color = HavenTheme.textSecondary, fontSize = 11.sp)
        }
    }
}

/** A ref's aspect ratio (w/h), or null while it's still being read / unknowable. Resolved off the
 *  main thread; LocalMedia.pixelSize memoizes, so a scroll back doesn't re-decrypt. */
@Composable
private fun rememberAspect(circleId: String, ref: String): Float? {
    var aspect by remember(ref, circleId) { mutableStateOf<Float?>(null) }
    LaunchedEffect(ref, circleId) {
        aspect = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            LocalMedia.pixelSize(circleId, ref)?.let { (w, h) -> if (h > 0) w.toFloat() / h else null }
        }
    }
    return aspect
}

private const val DEFAULT_ASPECT = 4f / 3f

/** Above this sealed size the feed won't autoplay a clip. Scrolling past something shouldn't buy a
 *  hundreds-of-MB native decrypt + cache write the user never asked for; over the cap the page keeps
 *  its poster + play glyph and the tap-to-open viewer (an explicit intent) does the work instead. */
private const val FEED_AUTOPLAY_MAX_BYTES = 128L * 1024 * 1024

/** Tallest a feed media tile may get before it starts eating the whole screen (iOS parity: a portrait
 *  phone lets a tall photo fill the column; wider layouts fit it inside a shorter cap). */
@Composable
private fun mediaMaxHeight(): androidx.compose.ui.unit.Dp {
    val cfg = androidx.compose.ui.platform.LocalConfiguration.current
    return if (cfg.screenWidthDp < cfg.screenHeightDp) 620.dp else 420.dp
}

/**
 * The carousel's page shape (parity with iOS `carouselAspect`). A uniform set keeps its exact aspect;
 * a MIXED set takes the TALLEST item's so no page is ever cropped — clamped so one 9:16 clip can't
 * squeeze the whole card into a narrow column (the other pages letterbox onto their backdrop instead).
 */
private fun carouselAspect(aspects: List<Float>): Float {
    val first = aspects.firstOrNull() ?: return DEFAULT_ASPECT
    val tallest = aspects.minOrNull() ?: DEFAULT_ASPECT
    val uniform = aspects.all { kotlin.math.abs(it - first) < 0.06f }
    return if (uniform) tallest else tallest.coerceIn(0.8f, 1.91f)
}

/**
 * A blurred, centre-cropped copy of the media filling the page behind the fitted copy, so a
 * letterboxed portrait reads as an extension of the content instead of a slab of card grey.
 *
 * The source is the page's OWN bitmap, not a second load: it's already resident, it costs no extra
 * decrypt, and the backdrop therefore cannot go missing while the page has something to draw. On 31+
 * `Modifier.blur` is a RenderEffect on a graphicsLayer — it blurs the (page-sized) layer, so a bigger
 * source costs nothing. Below 31 there's no RenderEffect and Modifier.blur silently no-ops, so fake it
 * by upscaling a tiny copy — derived once per bitmap, never per frame.
 */
@Composable
private fun MediaBackdrop(source: ImageBitmap, modifier: Modifier = Modifier) {
    val blurable = android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S
    val src = if (blurable) source else remember(source) { source.downscaled(24) }
    Image(
        src, contentDescription = null,
        modifier = modifier.then(if (blurable) Modifier.blur(24.dp) else Modifier),
        contentScale = ContentScale.Crop,   // fill the page; the fitted copy sits on top
    )
}

/** A tiny copy of a bitmap — the pre-31 blur stand-in, where the upscale itself IS the blur. */
private fun ImageBitmap.downscaled(maxDim: Int): ImageBitmap {
    val b = asAndroidBitmap()
    val s = maxDim.toFloat() / maxOf(b.width, b.height)
    if (s >= 1f) return this
    return android.graphics.Bitmap
        .createScaledBitmap(b, maxOf(1, (b.width * s).toInt()), maxOf(1, (b.height * s).toInt()), true)
        .asImageBitmap()
}

/**
 * One media page: the item fitted WHOLE inside a `containerAspect`-shaped box over its own blurred
 * backdrop, so the letterboxed area reads as the media's own colours instead of the card's grey.
 * The backdrop is drawn ONLY on a real aspect mismatch — media that already fills pays nothing.
 *
 * A video autoplays inline only while [playing] — i.e. only the visible page of the ONE centred post
 * (see the feed's `centeredPost`). A LazyColumn composes several posts at once, so playing every
 * composed page would mean N MediaPlayers decoding while you scroll; iOS avoids that same cost by
 * only ever playing the centred card's visible page. Everything else stays a poster + play glyph.
 */
@Composable
private fun MediaPage(circleId: String, ref: String, containerAspect: Float?, playing: Boolean, onOpen: () -> Unit) {
    val aspect = rememberAspect(circleId, ref)
    val isVideo = LocalMedia.isVideo(ref)
    // Decrypting is what MAKES the poster + backdrop possible (videoPoster can only read an already
    // decrypted cache file), so the active page decrypts here rather than only inside VideoTile —
    // whose own videoFile() then just hits the cache. Never eager: only the ONE active page pays it.
    var vid by remember(ref, circleId) { mutableStateOf<java.io.File?>(null) }
    LaunchedEffect(ref, circleId, playing) {
        if (!playing || !isVideo || vid != null) return@LaunchedEffect
        // Scroll away first and this coroutine is cancelled — the assignment never lands and no
        // player is ever built for a page that's no longer active.
        vid = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val size = LocalMedia.sealedSize(ref)
            if (size > FEED_AUTOPLAY_MAX_BYTES) null else LocalMedia.videoFile(circleId, ref)
        }
    }
    // ONE decode for the page AND its backdrop — they draw the same pixels, so the backdrop can never
    // silently drop out from under media that IS showing. Re-asked once `vid` lands: that decrypt is
    // precisely what turns a video's poster from null into a real frame.
    val (bmp, done) = rememberMediaBitmap(circleId, ref, reloadKey = vid)
    // `containerAspect` MUST be the page's real (measured) shape, never the media's own — comparing the
    // media against itself always yields ~0 and the backdrop could never draw. null = draw it regardless
    // (the single-media path: if the media does fill the page, the backdrop is simply covered).
    val letterboxes = when {
        containerAspect == null -> true
        // An un-played video has no known aspect yet — assume it letterboxes; that's the tall-clip case.
        aspect == null -> isVideo
        else -> kotlin.math.abs(aspect - containerAspect) > 0.02f
    }
    // clip() keeps the fill copy from bleeding onto the neighbouring page.
    Box(Modifier.fillMaxSize().clip(RoundedCornerShape(16.dp)).clickable { onOpen() }) {
      // Honors a flag federated by a member whose platform has an analyzer (iOS parity). A covered
      // video must NOT autoplay: a blur hides the picture but not the sound.
      SensitiveGuard(circleId, ref, cornerRadius = 16) { covered ->
        val plays = playing && isVideo && vid != null && !covered
        Box(Modifier.fillMaxSize()) {
            // Drawn under everything and never clickable → it can't intercept a tap or the pager's drag.
            if (letterboxes && bmp != null) MediaBackdrop(bmp, Modifier.matchParentSize())
            if (plays) {
                // VideoTile fits the clip inside the bounds it's GIVEN (its own matrix transform), so
                // handing it the page verbatim letterboxes the video onto the backdrop exactly like a
                // photo — the page keeps its own pageHeight/pageAspect sizing either way.
                VideoTile(circleId, ref, Modifier.matchParentSize(), resolved = vid)
            } else {
                MediaBitmapContent(circleId, ref, bmp, done, Modifier.fillMaxSize(), ContentScale.Fit)
                // Suppress the play glyph while the bytes are absent — the missing-media placeholder
                // (Download / loading / unavailable) owns the tile then; a glyph on top would misread.
                if (isVideo && LocalMedia.has(ref)) {
                    // A scrim only behind the glyph — a full-page one would grey out the backdrop we just drew.
                    Box(Modifier.align(Alignment.Center).size(52.dp).clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.35f)), contentAlignment = Alignment.Center) {
                        // White-on-scrim over media — not a theme surface.
                        Icon(Icons.Filled.PlayCircle, "Play", tint = Color.White, modifier = Modifier.size(40.dp))
                    }
                }
            }
        }
      }
    }
}

/** A full-width swipeable pager with page dots — the ≤10-item layout, any mix of aspect ratios. */
@Composable
private fun MediaCarousel(circleId: String, refs: List<String>, videoActive: Boolean, onOpen: (Int) -> Unit) {
    val aspects = refs.map { rememberAspect(circleId, it) ?: DEFAULT_ASPECT }
    val aspect = carouselAspect(aspects)
    val pager = androidx.compose.foundation.pager.rememberPagerState(initialPage = 0) { refs.size }
    val cap = mediaMaxHeight()
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val h = minOf(cap, maxWidth / aspect)
        // The page's REAL shape — what each item letterboxes against. Equal to `aspect` until the cap
        // bites, and wider than it after.
        val pageAspect = maxWidth / h
        Box(Modifier.fillMaxWidth().height(h).clip(RoundedCornerShape(16.dp))) {
            androidx.compose.foundation.pager.HorizontalPager(state = pager, modifier = Modifier.fillMaxSize()) { page ->
                // Only the SETTLED page of an active card plays — the pager keeps neighbours composed
                // mid-swipe, and currentPage flips only once a page has actually won the viewport.
                MediaPage(circleId, refs[page], pageAspect, playing = videoActive && page == pager.currentPage) {
                    onOpen(page)
                }
            }
            Row(
                Modifier.align(Alignment.BottomCenter).padding(bottom = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                repeat(refs.size) { i ->
                    Box(
                        Modifier.size(6.dp).clip(CircleShape)
                            // Page dots sit on the media itself — always white.
                            .background(Color.White.copy(alpha = if (i == pager.currentPage) 0.95f else 0.4f)),
                    )
                }
            }
        }
    }
}

@Composable
fun MediaGallery(circleId: String, refs: List<String>, videoActive: Boolean = false, onOpen: (Int) -> Unit) {
    // A location-only post has a non-empty `media` but NO real media — anything here would be an
    // empty grey box, so it must render nothing at all.
    if (refs.isEmpty()) return
    if (refs.size == 1) {
        // Fit the media whole (no crop) inside a page that SPANS the card, as tall as the media needs
        // up to the cap — sizing the page to the media's aspect would shrink it to a narrow centre
        // column on a wide layout and put the card's grey either side of it. Backdrop always on: pass
        // null rather than the media's own aspect, which would compare against itself and never draw.
        val aspect = rememberAspect(circleId, refs[0]) ?: DEFAULT_ASPECT
        val cap = mediaMaxHeight()
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            Box(Modifier.fillMaxWidth().height(minOf(cap, maxWidth / aspect))) {
                MediaPage(circleId, refs[0], null, playing = videoActive) { onOpen(0) }
            }
        }
        return
    }
    if (refs.size <= 10) {
        // Mixed aspects no longer force the grid — each page fits inside a shared shape and its own
        // blurred backdrop masks the difference, which beats a 2-photo masonry.
        MediaCarousel(circleId, refs, videoActive, onOpen)
        return
    }
    androidx.compose.foundation.lazy.grid.LazyHorizontalGrid(
        rows = androidx.compose.foundation.lazy.grid.GridCells.Fixed(2),
        modifier = Modifier.fillMaxWidth().height(264.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        gridItems(refs) { ref ->
            MediaThumb(circleId, ref, Modifier.size(129.dp)) { onOpen(refs.indexOf(ref)) }
        }
    }
}

/** Full-screen media viewer: swipe between items, tap/back to close. */
@Composable
fun MediaViewer(circleId: String, refs: List<String>, startIndex: Int, onClose: () -> Unit) {
    val pager = androidx.compose.foundation.pager.rememberPagerState(initialPage = startIndex) { refs.size }
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var saved by remember { mutableStateOf(false) }
    // Pinch-to-zoom + pan on the current photo (parity with iOS PostMedia). Resets on page change; while
    // zoomed, drag pans the image instead of swiping to the next item.
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    LaunchedEffect(pager.currentPage) { scale = 1f; offset = Offset.Zero }
    // Tap-to-close applies to photo pages (tap the letterbox to dismiss); on a video page we let the
    // VideoView's own MediaController + the sound toggle own all taps, and dismissal goes through the
    // explicit Close button — otherwise a stray tap on the video would close the viewer.
    val onVideoPage = refs.getOrNull(pager.currentPage)?.let { LocalMedia.isVideo(it) } == true
    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .then(if (onVideoPage) Modifier else Modifier.clickable { onClose() }),
    ) {
        androidx.compose.foundation.pager.HorizontalPager(
            state = pager,
            modifier = Modifier.fillMaxSize(),
            userScrollEnabled = scale <= 1f,
        ) { page ->
            val ref = refs[page]
            android.util.Log.i("VideoTile", "VIEWER page=$page ref=$ref isVideo=${LocalMedia.isVideo(ref)}")
            if (LocalMedia.isVideo(ref)) {
                // Full-screen player: VideoTile autoplays (start() in onPreparedListener), loops, has an
                // onErrorListener logging to tag "VideoTile", and a sound toggle. This is why grid videos
                // opened via the pager now actually play instead of showing the play-glyph still.
                VideoTile(circleId, ref, Modifier.fillMaxSize())
            } else {
                MediaImage(
                    circleId, ref,
                    Modifier.fillMaxSize()
                        .pointerInput(Unit) {
                            detectTransformGestures { _, pan, zoom, _ ->
                                scale = (scale * zoom).coerceIn(1f, 5f)
                                offset = if (scale > 1f) offset + pan else Offset.Zero
                            }
                        }
                        .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
                    contentScale = ContentScale.Fit,
                )
            }
        }
        // statusBarsPadding: this viewer draws under the status bar, whose window swallows taps in
        // that strip — leaving Close visibly present but dead at its centre. Same bug the QR
        // scanner had.
        Box(Modifier.align(Alignment.TopStart).statusBarsPadding().padding(16.dp).size(42.dp).clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.4f)).clickable { onClose() }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Close, "Close", tint = Color.White)
        }
        // Top-right actions: keep-on-device (pin) + save to Photos.
        Row(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            // "Keep on this device" — exempts this blob from every cleanup path (device pin, #2). Reads
            // PinnedMediaStore.refs (observable) so the glyph reflects the current state.
            val curRef = refs.getOrNull(pager.currentPage)
            val pinned = curRef != null && com.blaineam.haven.core.PinnedMediaStore.refs.contains(curRef)
            Box(Modifier.size(42.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.4f))
                .clickable { curRef?.let { com.blaineam.haven.core.PinnedMediaStore.togglePin(listOf(it)) } },
                contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.PushPin, if (pinned) "Kept on this device" else "Keep on this device",
                    tint = if (pinned) HavenTheme.pink else Color.White)
            }
            // Save this item to Photos.
            Box(Modifier.size(42.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.4f))
                .clickable {
                    val ref = refs[pager.currentPage]
                    scope.launch {
                        saved = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            LocalMedia.loadAnyCircle(ref)?.let { com.blaineam.haven.core.MediaSaver.save(context, it, LocalMedia.isVideo(ref)) } ?: false
                        }
                    }
                }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Download, "Save to Photos", tint = Color.White)
            }
        }
        // The viewer's surface is Color.Black in both modes — all its chrome stays white.
        if (refs.size > 1) Text("${pager.currentPage + 1} / ${refs.size}", color = Color.White, fontSize = 13.sp,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 24.dp))
        if (saved) {
            LaunchedEffect(Unit) { kotlinx.coroutines.delay(1500); saved = false }
            Text("Saved to Photos ✓", color = Color.White, fontSize = 13.sp,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 40.dp).clip(RoundedCornerShape(20.dp))
                    .background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 16.dp, vertical = 8.dp))
        }
    }
}

/** Feed-circle switcher: tap the title for a dropdown of your circles + "New circle". */
@Composable
private fun CircleSwitcher(activeId: String, circlesVersion: Int) {
    var menu by remember { mutableStateOf(false) }
    var showCreate by remember { mutableStateOf(false) }
    var showManage by remember { mutableStateOf(false) }
    val circles = remember(circlesVersion) { HavenNet.feedCircles() }
    val name = remember(activeId, circlesVersion) { HavenNet.circleName(activeId) }
    Box {
        Row(verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable { menu = true }) {
            BrandText(name, fontSize = 24)
            Icon(androidx.compose.material.icons.Icons.Filled.ArrowDropDown, "Switch circle", tint = HavenTheme.pink)
        }
        androidx.compose.material3.DropdownMenu(
            expanded = menu, onDismissRequest = { menu = false }, modifier = Modifier.background(HavenTheme.card),
        ) {
            circles.forEach { c ->
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("${c.name}  ·  ${c.memberCount}", color = HavenTheme.textPrimary) },
                    onClick = { HavenNet.setActiveCircle(c.id); menu = false },
                )
            }
            androidx.compose.material3.HorizontalDivider(color = HavenTheme.cardBorder)
            androidx.compose.material3.DropdownMenuItem(
                text = { Text("⚙️  Circle settings", color = HavenTheme.textPrimary) },
                onClick = { menu = false; showManage = true },
            )
            val locked = com.blaineam.haven.core.CircleLock.isLocked(activeId)
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(if (locked) "🔓 Unlock this circle" else "🔒 Lock this circle", color = HavenTheme.textPrimary) },
                onClick = { com.blaineam.haven.core.CircleLock.setLocked(activeId, !locked); menu = false },
            )
            val anyHidden = com.blaineam.haven.core.HiddenStore.hidden.size
            val showingHidden by com.blaineam.haven.core.HiddenStore.showHidden
            if (anyHidden > 0) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(if (showingHidden) "🙈  Hide hidden posts" else "👁  Show hidden posts ($anyHidden)", color = HavenTheme.textPrimary) },
                    onClick = { com.blaineam.haven.core.HiddenStore.toggleShowHidden(); menu = false },
                )
            }
            androidx.compose.material3.DropdownMenuItem(
                text = { Text("+ New circle", color = HavenTheme.pink) },
                onClick = { menu = false; showCreate = true },
            )
        }
    }
    if (showManage) CircleManageSheet(activeId) { showManage = false }
    if (showCreate) {
        var nm by remember { mutableStateOf("") }
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showCreate = false }, containerColor = HavenTheme.card,
            title = { Text("New circle", color = HavenTheme.textPrimary) },
            text = {
                OutlinedTextField(value = nm, onValueChange = { nm = it }, singleLine = true,
                    placeholder = { Text("Circle name") },
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink))
            },
            confirmButton = {
                androidx.compose.material3.TextButton(enabled = nm.isNotBlank(),
                    onClick = { HavenNet.createCircle(nm.trim()); showCreate = false }) {
                    Text("Create", color = HavenTheme.pink)
                }
            },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { showCreate = false }) { Text("Cancel", color = HavenTheme.textSecondary) } },
        )
    }
}

/** Live connection status: online (iroh) + every active transport (relay / nearby) + a live "syncing"
 *  pulse when media is actively transferring. Tap to open the sync-activity detail sheet. Mirrors the
 *  iOS connection chips but surfaces nearby + active sync, which were previously invisible. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionDot() {
    val online by HavenNet.internetActive
    val started by HavenNet.started
    val relay by HavenNet.relayActive
    val nearby = SyncMetrics.nearbyPeers.intValue
    val pending = SyncMetrics.mediaPending.intValue
    var showDetail by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.clip(RoundedCornerShape(50)).clickable { showDetail = true }.padding(start = 6.dp, end = 8.dp, top = 4.dp, bottom = 4.dp)) {
        // The node being up == connected to the iroh network; "Connecting" only during startup.
        val color = if (started) Color(0xFF34D399) else Color(0xFFF59E0B)
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Text(if (started) (if (online || relay || nearby > 0) "Connected" else "Online") else "Connecting",
            color = HavenTheme.textSecondary, fontSize = 11.sp)
        if (relay) Text("· Relay", color = Color(0xFF34D399), fontSize = 11.sp)
        if (nearby > 0) Text("· Nearby", color = Color(0xFF34D399), fontSize = 11.sp)
        // LIVE active-sync indicator — a small spinner + count whenever media is still transferring.
        if (pending > 0) {
            androidx.compose.material3.CircularProgressIndicator(
                color = Color(0xFFF59E0B), strokeWidth = 1.5.dp,
                modifier = Modifier.size(11.dp))
            Text("Syncing $pending", color = Color(0xFFF59E0B), fontSize = 11.sp)
        }
    }
    if (showDetail) {
        ModalBottomSheet(
            onDismissRequest = { showDetail = false },
            sheetState = rememberModalBottomSheetState(),
            containerColor = HavenTheme.card,
        ) { SyncDetailContent() }
    }
}

/** A small yellow/red pill by the composer: can this circle's posts actually reach others right now?
 *  Yellow = still syncing (mesh searching); red = device-only. When everything is SYNCED the pill
 *  collapses to nothing so it doesn't pad out the composer (iOS SyncStatusBadge parity). Tapping it
 *  opens a compact bottom sheet with the live sent / received / waiting counters. Polls every 2.5s. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SyncStatusBadge(circleId: String) {
    var status by remember(circleId) { mutableStateOf(HavenNet.syncStatus(circleId)) }
    var showDetail by remember { mutableStateOf(false) }
    LaunchedEffect(circleId) {
        while (true) {
            status = HavenNet.syncStatus(circleId)
            kotlinx.coroutines.delay(2500)
        }
    }
    // Only surface the pill when there's something to know. Collapse to nothing when fully synced.
    val (color, label) = when (status) {
        HavenNet.SyncStatus.SYNCED -> return
        HavenNet.SyncStatus.SYNCING -> Color(0xFFF59E0B) to "Syncing"
        HavenNet.SyncStatus.LOCAL -> Color(0xFFEF4444) to "Device only"
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(horizontal = 6.dp)
            .clip(RoundedCornerShape(50))
            .clickable { showDetail = true }
            .background(HavenTheme.card)
            .padding(horizontal = 9.dp, vertical = 4.dp),
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Spacer(Modifier.size(5.dp))
        Text(label, color = HavenTheme.textSecondary, fontSize = 11.sp)
    }
    if (showDetail) {
        ModalBottomSheet(
            onDismissRequest = { showDetail = false },
            sheetState = rememberModalBottomSheetState(),
            containerColor = HavenTheme.card,
        ) {
            SyncDetailContent()
        }
    }
}

/** The live "sync activity" detail behind the pill — surfaced only when the user taps it, so it's
 *  there to monitor a sync but never clutters (or re-renders) the feed otherwise. Reads the
 *  [SyncMetrics] Compose ints directly so a burst of media events recomposes ONLY this sheet
 *  (iOS SyncDetailView parity: sent / received / waiting + nearby-devices line + live caption). */
@Composable
private fun SyncDetailContent() {
    val out = SyncMetrics.mediaOut.intValue
    val inn = SyncMetrics.mediaIn.intValue
    val pending = SyncMetrics.mediaPending.intValue
    val nearbyPeers = SyncMetrics.nearbyPeers.intValue
    val relay by HavenNet.relayActive
    val online by HavenNet.internetActive
    val nearbyState = HavenNet.nearbyState()
    Column(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 28.dp, top = 4.dp),
    ) {
        Text("Sync activity", color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.size(6.dp))
        // The live headline: are we actively moving media right now, or idle/synced?
        Text(
            if (pending > 0) "Syncing $pending item${if (pending == 1) "" else "s"}…" else "Up to date",
            color = if (pending > 0) Color(0xFFF59E0B) else Color(0xFF34D399), fontSize = 13.sp,
        )
        Spacer(Modifier.size(14.dp))
        SyncDetailRow(Icons.Filled.ArrowUpward, "$out media sent")
        Spacer(Modifier.size(10.dp))
        SyncDetailRow(Icons.Filled.ArrowDownward, "$inn media received")
        Spacer(Modifier.size(10.dp))
        SyncDetailRow(Icons.Filled.AccessTime, "$pending media waiting")
        Spacer(Modifier.size(14.dp))
        androidx.compose.material3.HorizontalDivider(color = HavenTheme.cardBorder)
        Spacer(Modifier.size(14.dp))
        Text("Transports", color = HavenTheme.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.size(8.dp))
        // Which paths are actually carrying this device's sync right now.
        SyncDetailRow(
            if (online || relay) Icons.Filled.Wifi else Icons.Filled.WifiOff,
            when { relay -> "Relay / mailbox: active"; online -> "Internet (iroh): connected"; else -> "Internet: connecting…" },
            tint = if (online || relay) HavenTheme.pink else HavenTheme.textSecondary,
            valueColor = if (online || relay) HavenTheme.textPrimary else HavenTheme.textSecondary,
        )
        Spacer(Modifier.size(10.dp))
        val (nearbyIcon, nearbyText) = when (nearbyState) {
            HavenNet.NearbyState.CONNECTED -> Icons.Filled.Wifi to "Nearby: connected ($nearbyPeers device${if (nearbyPeers == 1) "" else "s"})"
            HavenNet.NearbyState.SEARCHING -> Icons.Filled.Wifi to "Nearby: searching… (Android-to-Android on this network)"
            HavenNet.NearbyState.NO_PERMISSION -> Icons.Filled.WifiOff to "Nearby: needs Bluetooth/Nearby permission"
            HavenNet.NearbyState.OFF -> Icons.Filled.WifiOff to "Nearby: off (enable in You ▸ Settings)"
        }
        SyncDetailRow(
            nearbyIcon, nearbyText,
            tint = if (nearbyState == HavenNet.NearbyState.CONNECTED) HavenTheme.pink else HavenTheme.textSecondary,
            valueColor = if (nearbyState == HavenNet.NearbyState.CONNECTED) HavenTheme.textPrimary else HavenTheme.textSecondary,
        )
        Spacer(Modifier.size(14.dp))
        Text(
            "Nearby is a direct phone-to-phone link between Android devices; iPhone/Mac use their own " +
            "nearby system, so cross-platform sync goes over the relay. Updates live.",
            color = HavenTheme.textSecondary, fontSize = 12.sp,
        )
    }
}

@Composable
private fun SyncDetailRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    tint: Color = HavenTheme.textSecondary,
    valueColor: Color = HavenTheme.textPrimary,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.size(10.dp))
        Text(text, color = valueColor, fontSize = 15.sp)
    }
}

/** Plays an attached video from its decrypted cache file, with controls. Videos start MUTED; the
 *  corner button toggles sound for ALL videos (global ProfileStore.videoSoundOn — iOS parity). */
@Composable
fun VideoTile(
    circleId: String, ref: String, modifier: Modifier = Modifier,
    // A caller that already decrypted the clip (the feed, which needs the file for its poster anyway)
    // hands it over, so we skip a frame of the placeholder tile on top of its blurred backdrop.
    resolved: java.io.File? = null,
) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.get(context) }
    val soundOn = profile.videoSoundOn
    var file by remember(ref) { mutableStateOf(resolved) }
    val player = remember(ref) { mutableStateOf<android.media.MediaPlayer?>(null) }
    android.util.Log.i("VideoTile", "COMPOSE ref=$ref circle=${circleId.take(14)} isVideo=${LocalMedia.isVideo(ref)}")
    LaunchedEffect(ref, circleId) {
        if (file != null) return@LaunchedEffect
        file = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            LocalMedia.videoFile(circleId, ref)
        }
        android.util.Log.i("VideoTile", "FILE ref=$ref file=${file?.absolutePath ?: "NULL"} exists=${file?.exists() == true} size=${file?.length() ?: -1}")
    }
    // The feed swaps tiles in and out on every scroll, so a MediaPlayer that outlives its composable
    // would be a per-post decode leak. onSurfaceTextureDestroyed already releases, but it's the
    // VIEW's callback — this is the composition's own guarantee. Whichever fires first nulls the ref.
    androidx.compose.runtime.DisposableEffect(ref) {
        onDispose {
            player.value?.let { runCatching { it.release() } }
            player.value = null
            android.util.Log.i("VideoTile", "DISPOSE ref=$ref")
        }
    }
    // Re-apply the global mute state whenever it flips, a call starts/ends, or the player becomes
    // ready. While a call is ringing/connecting/live the video is FORCED silent (call audio
    // priority); reading callInProgress here subscribes this composable to the call state.
    val callActive = com.blaineam.haven.core.CallManager.callInProgress
    LaunchedEffect(soundOn, callActive, player.value) {
        val v = if (soundOn && !callActive) 1f else 0f
        runCatching { player.value?.setVolume(v, v) }
    }
    val f = file
    if (f == null) {
        Box(modifier.background(HavenTheme.card).padding(40.dp), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Videocam, "Video", tint = HavenTheme.textSecondary)
        }
    } else {
        Box(modifier) {
            // A TextureView (NOT VideoView/SurfaceView): a SurfaceView doesn't composite inside a Compose
            // overlay/Dialog (z-order + surface-lifecycle issues), so the old player showed a play glyph but
            // never rendered/played anything. A TextureView renders into the normal view hierarchy + we drive
            // playback with MediaPlayer directly, autoplaying + looping.
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    android.view.TextureView(ctx).apply {
                        val tv = this
                        // A TextureView STRETCHES the video to its bounds by default, squishing a 16:9 clip
                        // on a tall phone. Apply a transform that scales the video to FIT (letterbox) so its
                        // aspect ratio is preserved. Needs both the view size and the video size, so we call
                        // it once both are known (on prepared + on every size change).
                        fun applyAspect() {
                            val mp = player.value ?: return
                            val vw = mp.videoWidth; val vh = mp.videoHeight
                            val w = tv.width; val h = tv.height
                            if (vw <= 0 || vh <= 0 || w <= 0 || h <= 0) return
                            val scale = minOf(w.toFloat() / vw, h.toFloat() / vh)
                            // Correct the default stretch (view/video) back to a uniform `scale`, pivot center.
                            val m = android.graphics.Matrix()
                            m.setScale(scale * vw / w, scale * vh / h, w / 2f, h / 2f)
                            tv.setTransform(m)
                            tv.invalidate()
                        }
                        surfaceTextureListener = object : android.view.TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(st: android.graphics.SurfaceTexture, w: Int, h: Int) {
                                val mp = android.media.MediaPlayer()
                                runCatching {
                                    mp.setDataSource(f.absolutePath)
                                    mp.setSurface(android.view.Surface(st))
                                    mp.isLooping = true
                                    mp.setOnPreparedListener {
                                        val vol = if (profile.videoSoundOn && !com.blaineam.haven.core.CallManager.callInProgress) 1f else 0f
                                        it.setVolume(vol, vol)
                                        it.start()   // autoplay (iOS parity)
                                        applyAspect()   // video dimensions are known now → fix the squish
                                        android.util.Log.i("VideoTile", "playing ref=$ref ${it.videoWidth}x${it.videoHeight}")
                                    }
                                    // Some codecs report the real size only after the first frame decodes.
                                    mp.setOnVideoSizeChangedListener { _, _, _ -> applyAspect() }
                                    mp.setOnErrorListener { _, what, extra ->
                                        android.util.Log.e("VideoTile", "error what=$what extra=$extra ref=$ref path=${f.absolutePath}")
                                        false
                                    }
                                    mp.prepareAsync()
                                    player.value = mp
                                }.onFailure {
                                    android.util.Log.e("VideoTile", "setup failed ref=$ref path=${f.absolutePath}", it)
                                    runCatching { mp.release() }
                                }
                            }
                            override fun onSurfaceTextureSizeChanged(st: android.graphics.SurfaceTexture, w: Int, h: Int) { applyAspect() }
                            override fun onSurfaceTextureDestroyed(st: android.graphics.SurfaceTexture): Boolean {
                                runCatching { player.value?.release() }; player.value = null; return true
                            }
                            override fun onSurfaceTextureUpdated(st: android.graphics.SurfaceTexture) {}
                        }
                    }
                },
            )
            Box(
                Modifier.align(Alignment.BottomEnd).padding(8.dp).size(34.dp).clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.45f))
                    .clickable { profile.videoSoundOn = !profile.videoSoundOn },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (soundOn) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff,
                    "Toggle sound", tint = Color.White, modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

private val QUICK_EMOJI = listOf("❤️", "😂", "🔥", "👍", "🎉", "😮")

/** The one-tap reactions offered on every card, next to the chips (iOS EmojiStore.frequent(3)). */
private val QUICK_REACT = listOf("❤️", "😂", "🎉")

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PostCard(
    item: FeedItemFfi,
    circleId: String = DEFAULT_CIRCLE,
    reports: List<uniffi.haven_ffi.ReportFfi> = emptyList(),
    // The feed passes true for the ONE centred card; single-post screens default to no autoplay.
    videoActive: Boolean = false,
) {
    val context = LocalContext.current
    var postMenu by remember(item.id) { mutableStateOf(false) }
    var showReport by remember(item.id) { mutableStateOf(false) }
    var commentDraft by remember(item.id) { mutableStateOf("") }
    var showPicker by remember(item.id) { mutableStateOf(false) }
    var showEdit by remember(item.id) { mutableStateOf(false) }
    var whoReacted by remember(item.id) { mutableStateOf<uniffi.haven_ffi.ReactionFfi?>(null) }
    var viewerStart by remember(item.id) { mutableStateOf<Int?>(null) }
    var commentPicker by remember(item.id) { mutableStateOf<String?>(null) }   // comment id being reacted to
    // Staged reply attachments (iOS `commentMedia`) — photos/videos via the picker, voice via the recorder.
    val commentMedia = remember(item.id) { androidx.compose.runtime.mutableStateListOf<String>() }
    var commentAttachMenu by remember(item.id) { mutableStateOf(false) }
    var showCommentRecorder by remember(item.id) { mutableStateOf(false) }
    var commentViewer by remember(item.id) { mutableStateOf<Pair<String, String>?>(null) }   // (circle, ref) being viewed
    // Same store-under-the-circle's-key flow as the post composer's picker.
    val commentPickerLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(4)) { uris ->
        uris.forEach { uri ->
            val ref = if (com.blaineam.haven.core.isVideoUri(context, uri))
                com.blaineam.haven.core.readVideoBytes(context, uri)?.let { LocalMedia.store(circleId, it, isVideo = true) }
            else loadAndDownscale(context, uri)?.let { LocalMedia.store(circleId, it) }
            if (ref != null) commentMedia.add(ref)
        }
    }
    viewerStart?.let { start ->
        FullScreenOverlay(onDismiss = { viewerStart = null }) {
            MediaViewer(circleId, item.media.filter { !com.blaineam.haven.core.LocationShare.isLocation(it) }, start) { viewerStart = null }
        }
    }

    whoReacted?.let { r ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { whoReacted = null }, containerColor = HavenTheme.card,
            title = { Text("${r.emoji}  ${r.count}", color = HavenTheme.textPrimary) },
            text = {
                Column {
                    r.authors.forEach { a ->
                        Text(if (a.startsWith(HavenNet.nodeIdHex.take(8))) "You" else HavenNet.displayName(a.take(8)),
                            color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.padding(vertical = 2.dp))
                    }
                }
            },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { whoReacted = null }) { Text("Done", color = HavenTheme.pink) } },
        )
    }

    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            HavenAvatar(item.authorShort, if (item.isMe) "You" else HavenNet.displayName(item.authorShort),
                34.dp, isMe = item.isMe)
            Spacer(Modifier.size(10.dp))
            Text(
                if (item.isMe) "You" else HavenNet.displayName(item.authorShort),
                color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                relativeTime(item.createdAt) + if (item.edited) " · edited" else "",
                color = HavenTheme.textSecondary, fontSize = 12.sp,
            )
            Box {
                Icon(androidx.compose.material.icons.Icons.Filled.MoreVert, "More",
                    tint = HavenTheme.textSecondary,
                    modifier = Modifier.padding(start = 4.dp).size(20.dp).clickable { postMenu = true })
                DropdownMenu(expanded = postMenu, onDismissRequest = { postMenu = false },
                    modifier = Modifier.background(HavenTheme.card)) {
                    // No link for an unsent post (nothing to land on), a story (gone by the time
                    // anyone taps), or a DM — a dm: circle id is literally both members' node ids,
                    // so the link would leak the pair to whoever you sent it to, and no one outside
                    // the DM could ever open it anyway.
                    val shareUrl = if (item.unsent || item.story || circleId.startsWith("dm:")) null
                                   else com.blaineam.haven.core.DeepLink.postUrl(circleId, item.id)
                    shareUrl?.let { url ->
                        DropdownMenuItem(
                            text = { Text("Share post", color = HavenTheme.textPrimary) },
                            onClick = { postMenu = false; sharePost(context, url) },
                        )
                        DropdownMenuItem(
                            text = { Text("Copy link", color = HavenTheme.textPrimary) },
                            onClick = { postMenu = false; copyPostLink(context, url) },
                        )
                    }
                    // Own-post actions live here, not in the card body — the body is for reacting and
                    // replying now (iOS keeps Edit/Unsend in this same ellipsis menu).
                    if (item.isMe) {
                        DropdownMenuItem(
                            text = { Text("Edit", color = HavenTheme.textPrimary) },
                            onClick = { postMenu = false; showEdit = true },
                        )
                        DropdownMenuItem(
                            text = { Text("Delete", color = Color(0xFFF87171)) },
                            onClick = { postMenu = false; HavenNet.unsendPost(circleId, item.id) },
                        )
                    }
                    val hidden = com.blaineam.haven.core.HiddenStore.isHidden(item.id)
                    DropdownMenuItem(
                        text = { Text(if (hidden) "Unhide post" else "Hide post", color = HavenTheme.textPrimary) },
                        onClick = {
                            if (hidden) com.blaineam.haven.core.HiddenStore.unhide(item.id)
                            else com.blaineam.haven.core.HiddenStore.hide(item.id)
                            postMenu = false
                        },
                    )
                    if (!item.isMe) DropdownMenuItem(
                        text = { Text("Report", color = Color(0xFFF87171)) },
                        onClick = { postMenu = false; showReport = true },
                    )
                }
            }
        }
        // Another member reported this post → surface the circle's shared moderation signal with
        // per-viewer actions (hide / remove from circle / block). The reporter themselves never
        // sees it — reporting hid the post for them. (Parity with iOS ReportedBanner.)
        if (!item.isMe && reports.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            ReportedBanner(item, circleId, HavenNet.displayName(item.authorShort), reports)
        }
        if (showReport) {
            ReportSheet(item, circleId, HavenNet.displayName(item.authorShort)) { showReport = false }
        }
        // An unsent post shows a placeholder and hides ALL affordances (media, reactions,
        // react/comment bar, composer) — parity with iOS, which renders "Message unsent" and
        // strips the interaction controls. Keep the author + timestamp row above.
        if (item.unsent) {
            Spacer(Modifier.height(8.dp))
            Text("Message unsent", color = HavenTheme.textSecondary, fontSize = 14.sp,
                fontStyle = androidx.compose.ui.text.font.FontStyle.Italic)
            return@Column
        }
        if (item.body.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            LinkedText(item.body, color = HavenTheme.textPrimary, fontSize = 15.sp)
            LinkPreviewCard(item.body, Modifier.padding(top = 10.dp))
        }

        // Location pins render as a tap-to-open-Maps chip; photos/videos as a gallery.
        item.media.filter { com.blaineam.haven.core.LocationShare.isLocation(it) }.forEach { ref ->
            Spacer(Modifier.height(10.dp))
            LocationChip(ref)
        }
        val mediaRefs = item.media.filter { !com.blaineam.haven.core.LocationShare.isLocation(it) }
        if (mediaRefs.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            // A card whose viewer is open stops autoplaying underneath it — one decode, not two.
            MediaGallery(circleId, mediaRefs, videoActive = videoActive && viewerStart == null) { viewerStart = it }
        }

        // Attached song — artwork + 30s preview playback, resolved via iTunes Search.
        item.music?.let { m ->
            Spacer(Modifier.height(10.dp))
            MusicChip(m)
        }

        // Reactions row (iOS `reactionsRow`): existing chips — tap toggles YOURS, long-press shows who
        // — then the one-tap quick reacts and a picker for anything else. The old "React" / "Comment"
        // text links made every reaction cost two taps and hid the reply behind a third.
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            item.reactions.forEach { r ->
                val mine = r.mine
                Box(
                    Modifier.padding(end = 6.dp).clip(RoundedCornerShape(20.dp))
                        .background(if (mine) HavenTheme.pink.copy(alpha = 0.25f) else HavenTheme.background)
                        .combinedClickable(
                            onClick = {
                                if (mine) HavenNet.unreact(circleId, item.id, r.emoji)
                                else HavenNet.react(circleId, item.id, r.emoji)
                            },
                            onLongClick = { whoReacted = r },
                        )
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                ) {
                    Text("${r.emoji} ${r.count}", fontSize = 13.sp,
                        color = if (mine) HavenTheme.pink else HavenTheme.textPrimary)
                }
            }
            Spacer(Modifier.weight(1f))
            QUICK_REACT.forEach { e ->
                Box(Modifier.clip(CircleShape).clickable { HavenNet.react(circleId, item.id, e) }.padding(5.dp)) {
                    Text(e, fontSize = 19.sp)
                }
            }
            Box(Modifier.clip(CircleShape).clickable { showPicker = !showPicker }.padding(5.dp)) {
                Icon(Icons.Filled.AddReaction, "More reactions", tint = HavenTheme.textSecondary,
                    modifier = Modifier.size(20.dp))
            }
        }
        if (showEdit) {
            var editText by remember(item.id) { mutableStateOf(item.body) }
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(value = editText, onValueChange = { editText = it },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(18.dp),
                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink))
                Text("Save", color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable {
                        HavenNet.editPost(circleId, item.id, editText.trim()); showEdit = false
                    }.padding(10.dp))
            }
        }
        if (showPicker) {
            var customEmoji by remember(item.id) { mutableStateOf("") }
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                QUICK_EMOJI.forEach { e ->
                    Box(
                        Modifier.clip(CircleShape).clickable {
                            HavenNet.react(circleId, item.id, e); showPicker = false
                        }.padding(6.dp),
                    ) { Text(e, fontSize = 22.sp) }
                }
            }
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = customEmoji,
                    onValueChange = { customEmoji = it },
                    placeholder = { Text("Any emoji…", fontSize = 13.sp) },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(18.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                )
                Text("Add", color = if (customEmoji.isNotBlank()) HavenTheme.pink else HavenTheme.textSecondary,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = customEmoji.isNotBlank()) {
                        HavenNet.react(circleId, item.id, customEmoji.trim()); customEmoji = ""; showPicker = false
                    }.padding(10.dp))
            }
        }

        // Comments.
        if (item.comments.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            item.comments.forEach { c ->
                Column(Modifier.padding(vertical = 2.dp)) {
                    // Tap-and-hold a comment to react to it (parity with iOS).
                    Row(Modifier.combinedClickable(onClick = {},
                        onLongClick = { commentPicker = if (commentPicker == c.id) null else c.id })) {
                        Text(if (c.isMe) "You: " else "${HavenNet.displayName(c.authorShort)}: ",
                            color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        Text(c.body, color = HavenTheme.textPrimary, fontSize = 13.sp)
                    }
                    // A reply's own attachments (iOS `commentMediaRow`): voice notes play inline, a
                    // photo/video opens the full-screen viewer.
                    if (!c.unsent && c.media.isNotEmpty()) {
                        Row(Modifier.padding(start = 4.dp, top = 3.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            c.media.forEach { ref ->
                                if (LocalMedia.isAudio(ref)) AudioPlayerPill(circleId, ref)
                                else MediaThumb(circleId, ref, Modifier.size(56.dp)) { commentViewer = circleId to ref }
                            }
                        }
                    }
                    if (c.reactions.isNotEmpty()) {
                        Row(Modifier.padding(start = 4.dp, top = 2.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            c.reactions.forEach { r ->
                                Box(Modifier.clip(RoundedCornerShape(16.dp))
                                    .background(if (r.mine) HavenTheme.pink.copy(alpha = 0.25f) else HavenTheme.background)
                                    .clickable {
                                        if (r.mine) HavenNet.unreact(circleId, c.id, r.emoji) else HavenNet.react(circleId, c.id, r.emoji)
                                    }.padding(horizontal = 8.dp, vertical = 3.dp)) {
                                    Text("${r.emoji} ${r.count}", fontSize = 12.sp, color = HavenTheme.textPrimary)
                                }
                            }
                        }
                    }
                    if (commentPicker == c.id) {
                        Row(Modifier.padding(top = 2.dp)) {
                            QUICK_EMOJI.forEach { e ->
                                Box(Modifier.clip(CircleShape).clickable {
                                    HavenNet.react(circleId, c.id, e); commentPicker = null
                                }.padding(5.dp)) { Text(e, fontSize = 20.sp) }
                            }
                        }
                    }
                }
            }
        }
        // The reply composer is ALWAYS on the card (iOS `commentField`) — replying was previously
        // invisible behind a "Comment" link, so nobody found it.
        Spacer(Modifier.height(8.dp))
        // Staged reply attachments, each removable (iOS `commentAttachChip`).
        if (commentMedia.isNotEmpty()) {
            androidx.compose.foundation.lazy.LazyRow(
                Modifier.fillMaxWidth().padding(bottom = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(commentMedia.size) { i ->
                    val ref = commentMedia[i]
                    Box {
                        when {
                            LocalMedia.isAudio(ref) ->
                                Box(Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)).background(HavenTheme.card),
                                    contentAlignment = Alignment.Center) {
                                    Icon(Icons.Filled.Mic, "Audio reply", tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
                                }
                            LocalMedia.isVideo(ref) ->
                                Box(Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)).background(HavenTheme.card),
                                    contentAlignment = Alignment.Center) {
                                    Icon(Icons.Filled.Videocam, "Video", tint = HavenTheme.textPrimary, modifier = Modifier.size(20.dp))
                                }
                            else -> MediaImage(circleId, ref, Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)),
                                contentScale = ContentScale.Crop)
                        }
                        // White-on-black-scrim over the thumb — not a theme surface.
                        Text("✕", color = Color.White, fontSize = 11.sp,
                            modifier = Modifier.align(Alignment.TopEnd).padding(2.dp).clip(CircleShape)
                                .background(Color.Black.copy(alpha = 0.6f)).clickable { commentMedia.remove(ref) }
                                .padding(horizontal = 5.dp, vertical = 1.dp))
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            // Attach affordance (iOS parity: paperclip → photo/video | audio). Same picker + recorder
            // the post composer and DM thread already use, so a reply's media rides the identical
            // store → seal → relay-backup path.
            Box {
                Icon(Icons.Filled.AttachFile, "Attach to reply", tint = HavenTheme.textSecondary,
                    modifier = Modifier.size(22.dp).clip(CircleShape).clickable { commentAttachMenu = true })
                DropdownMenu(expanded = commentAttachMenu, onDismissRequest = { commentAttachMenu = false },
                    modifier = Modifier.background(HavenTheme.card)) {
                    DropdownMenuItem(
                        text = { Text("Photo or video", color = HavenTheme.textPrimary) },
                        onClick = {
                            commentAttachMenu = false
                            commentPickerLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Audio reply", color = HavenTheme.textPrimary) },
                        onClick = { commentAttachMenu = false; showCommentRecorder = true },
                    )
                }
            }
            Spacer(Modifier.size(4.dp))
            OutlinedTextField(
                value = commentDraft, onValueChange = { commentDraft = it },
                placeholder = { Text("Add a reply…", fontSize = 13.sp) },
                modifier = Modifier.weight(1f), shape = RoundedCornerShape(18.dp), maxLines = 5,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
            )
            Spacer(Modifier.size(6.dp))
            // A media-only reply is valid, so an attachment alone arms Send.
            val canSend = commentDraft.isNotBlank() || commentMedia.isNotEmpty()
            Box(
                Modifier.size(34.dp).clip(CircleShape).clickable(enabled = canSend) {
                    HavenNet.comment(circleId, item.id, commentDraft.trim(), commentMedia.toList())
                    commentDraft = ""; commentMedia.clear()
                },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.ArrowCircleUp, "Send reply",
                    tint = if (canSend) HavenTheme.pink else HavenTheme.textSecondary,
                    modifier = Modifier.size(28.dp))
            }
        }
    }
    if (showCommentRecorder) {
        VoiceRecorderDialog(
            circleId = circleId,
            onDone = { ref -> commentMedia.add(ref); showCommentRecorder = false },
            onDismiss = { showCommentRecorder = false },
        )
    }
    commentViewer?.let { (cid, ref) ->
        FullScreenOverlay(onDismiss = { commentViewer = null }) {
            MediaViewer(cid, listOf(ref), 0) { commentViewer = null }
        }
    }
}

/** Compact relative timestamp for the feed (now / 5m / 3h / 2d / 1w), like the iOS feed. */
private fun relativeTime(createdAtMs: kotlin.ULong): String {
    val diff = System.currentTimeMillis() - createdAtMs.toLong()
    if (diff < 0) return "now"
    val s = diff / 1000
    return when {
        s < 45 -> "now"
        s < 3600 -> "${s / 60}m"
        s < 86_400 -> "${s / 3600}h"
        s < 604_800 -> "${s / 86_400}d"
        else -> "${s / 604_800}w"
    }
}

/** The share sheet is the point: a post link only earns its keep once it can reach a friend's
 *  Messages/Signal/mail, on whichever platform they're on. (Same idiom as YouScreen's invite.) */
private fun sharePost(context: android.content.Context, url: String) {
    val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(android.content.Intent.EXTRA_TEXT, url)
    }
    context.startActivity(android.content.Intent.createChooser(send, "Share post"))
}

private fun copyPostLink(context: android.content.Context, url: String) {
    (context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
        .setPrimaryClip(android.content.ClipData.newPlainText("haven post link", url))
    android.widget.Toast.makeText(context, "Link copied", android.widget.Toast.LENGTH_SHORT).show()
}
