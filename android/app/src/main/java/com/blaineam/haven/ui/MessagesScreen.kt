package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.Contact
import com.blaineam.haven.core.HavenNet
import kotlinx.coroutines.launch

/** Messages tab — a list of people to DM, then a chat thread. DM = private 2-person circle. */
@Composable
fun MessagesScreen() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val lockV by com.blaineam.haven.core.CircleLock.version
    if (remember(lockV) { com.blaineam.haven.core.CircleLock.needsUnlock(com.blaineam.haven.core.DEFAULT_CIRCLE) }) {
        HavenBackground {
            Column(Modifier.fillMaxSize().padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Text("🔒", fontSize = 48.sp)
                Spacer(Modifier.height(12.dp))
                Text("Messages are locked", color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(6.dp))
                Text("Unlock your circle to see your private chats.", color = HavenTheme.textSecondary,
                    fontSize = 13.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Spacer(Modifier.height(16.dp))
                BrandButton(text = "Unlock", modifier = Modifier.fillMaxWidth(0.6f)) {
                    (context as? androidx.fragment.app.FragmentActivity)?.let {
                        com.blaineam.haven.core.CircleLock.authenticate(it, com.blaineam.haven.core.DEFAULT_CIRCLE) {}
                    }
                }
            }
        }
        return
    }
    var openThread by remember { mutableStateOf<Pair<String, Contact>?>(null) }

    // Somewhere else in the app staged a DM draft (today: "Message the author" on a post) — open
    // that thread here, exactly as picking it from the list would. RootScreen has already switched
    // to this tab; the composer picks the staged text up in DmThread. iOS parity (MessagesView's
    // onReceive of DMDraftStore.openThread).
    val pendingThread by com.blaineam.haven.core.DmDrafts.openThread
    androidx.compose.runtime.LaunchedEffect(pendingThread) {
        com.blaineam.haven.core.DmDrafts.consumeOpenThread()?.let { cid ->
            val others = HavenNet.dmMemberHexes(cid).filter { !it.equals(HavenNet.nodeIdHex, true) }
            HavenNet.contacts.firstOrNull { c -> others.any { it.equals(c.idHex, true) } }
                ?.let { openThread = cid to it }
        }
    }

    val thread = openThread
    // System back leaves the conversation the same way the ← in its header does, instead of leaving
    // the app (see the back-navigation note in RootScreen).
    androidx.activity.compose.BackHandler(enabled = thread != null) { openThread = null }
    if (thread == null) {
        ThreadList(onOpen = { cid, partner -> openThread = cid to partner })
    } else {
        DmThread(circleId = thread.first, partner = thread.second, onBack = { openThread = null })
    }
}

/** A row in the Messages list: a 1:1 DM (with a [contact]) or a group DM (contact == null). */
private data class Conversation(
    val circleId: String,
    val title: String,
    val contact: Contact?,   // non-null for a 1:1 (drives the avatar + opening the thread)
    val preview: String,     // newest message, one line (iOS rowLabel parity); "" = nothing said yet
    val lastActivity: ULong,
    val unread: Int,         // inbound messages newer than the thread's read watermark
)

/** The partner Contact behind a 1:1 dm circle — the real contact when we still know them, else a
 *  stand-in from the id encoded in the circle itself (a removed friend's thread still opens). */
private fun dmPartner(circleId: String): Contact? {
    val hex = HavenNet.dmMemberHexes(circleId).firstOrNull { !it.equals(HavenNet.nodeIdHex, true) }
        ?: return null
    return HavenNet.contacts.firstOrNull { it.idHex.equals(hex, true) }
        ?: Contact(hex, HavenNet.dmPartnerName(circleId), "")
}

/** The newest message as one line — what iOS's rowLabel shows (unsent / secret never leak content). */
private fun previewOf(circleId: String): String {
    val last = HavenNet.messages(circleId).maxByOrNull { it.createdAt } ?: return ""
    return when {
        last.unsent -> "Message unsent"
        com.blaineam.haven.core.SecretMessages.isSecret(last.body) -> "🔒 Secret message"
        else -> last.body
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ThreadList(onOpen: (String, Contact) -> Unit) {
    val contacts = HavenNet.contacts
    val version by HavenNet.feedVersion
    val readTick by com.blaineam.haven.core.DmRead.version
    val circlesVersion by HavenNet.circlesVersion
    val pins = com.blaineam.haven.core.DmPins.pinned
    var showPicker by remember { mutableStateOf(false) }

    // Real CONVERSATIONS, not the address book: every dm: circle that actually exists (iOS
    // `store.dmCircles`). Listing a row per contact turned Messages into a second contact list and
    // buried the two threads you actually have. Sorted newest-first; pinned (max 6) float to the top.
    val conversations = remember(version, readTick, circlesVersion, contacts, pins.toList()) {
        val all = runCatching { HavenNet.engine.circles() }.getOrDefault(emptyList())
            .filter { it.id.startsWith("dm:") }
            .map { c ->
                val partner = if (HavenNet.isGroupDm(c.id)) null else dmPartner(c.id)
                Conversation(
                    c.id, HavenNet.dmPartnerName(c.id), partner, previewOf(c.id),
                    HavenNet.lastActivity(c.id), HavenNet.unreadMessages(c.id),
                )
            }
        val byId = all.associateBy { it.circleId }
        val pinned = pins.mapNotNull { byId[it] }   // pin order, still-present only
        val rest = all.filter { !pins.contains(it.circleId) }.sortedByDescending { it.lastActivity }
        pinned to rest
    }
    val pinnedConvos = conversations.first
    val restConvos = conversations.second

    if (showPicker) {
        NewMessagePicker(
            onDismiss = { showPicker = false },
            onStart = { picks ->
                showPicker = false
                // One pick = a 1:1, 2+ = a group (startGroupDM funnels a single pick back to startDm).
                val cid = HavenNet.startGroupDM(picks)
                onOpen(cid, if (picks.size == 1) picks[0] else Contact("", picks.joinToString(", ") { it.name }, ""))
            },
        )
    }
    HavenBackground {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, top = 16.dp, bottom = 8.dp, end = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BrandText("Messages", fontSize = 26)
                Spacer(Modifier.weight(1f))
                if (contacts.isNotEmpty()) {
                    Box(Modifier.clip(CircleShape).clickable { showPicker = true }.padding(6.dp)) {
                        Icon(Icons.Filled.Edit, "New message", tint = HavenTheme.pink)
                    }
                }
            }
            if (contacts.isEmpty() || (pinnedConvos.isEmpty() && restConvos.isEmpty())) {
                Column(
                    Modifier.fillMaxSize().padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text(if (contacts.isEmpty()) "No one to message yet" else "No messages yet",
                        color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if (contacts.isEmpty()) "Add a friend from the Circle tab, then DM them here."
                        else "Tap the pencil to start one.",
                        color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center,
                    )
                }
            } else {
                val open: (Conversation) -> Unit = { conv ->
                    onOpen(conv.circleId, conv.contact ?: Contact("", conv.title, ""))
                }
                LazyColumn(
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(pinnedConvos, key = { "pin:" + it.circleId }) { conv ->
                        ConversationRow(conv, pinned = true, onOpen = { open(conv) })
                    }
                    items(restConvos, key = { it.circleId }) { conv ->
                        ConversationRow(conv, pinned = false, onOpen = { open(conv) })
                    }
                }
            }
        }
    }
}

/** One conversation row. Tap to open; long-press for pin/unpin (max 6) + delete. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ConversationRow(conv: Conversation, pinned: Boolean, onOpen: () -> Unit) {
    var showMenu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                .combinedClickable(onClick = onOpen, onLongClick = { showMenu = true })
                .havenCard().padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (conv.contact != null) {
                HavenAvatar(idOrShort = conv.contact.idHex, name = conv.contact.name, size = 40.dp)
            } else {
                Box(Modifier.size(40.dp).clip(CircleShape).background(HavenTheme.card),
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Group, null, tint = HavenTheme.pink, modifier = Modifier.size(22.dp))
                }
            }
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f)) {
                Text(conv.title, color = HavenTheme.textPrimary, fontSize = 16.sp,
                    fontWeight = if (conv.unread > 0) FontWeight.Bold else FontWeight.Medium, maxLines = 1)
                if (conv.preview.isNotBlank()) {
                    Text(conv.preview, fontSize = 13.sp, maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        color = if (conv.unread > 0) HavenTheme.textPrimary else HavenTheme.textSecondary)
                }
            }
            if (conv.unread > 0) {
                UnreadBadge(conv.unread)
                Spacer(Modifier.size(8.dp))
            }
            if (pinned) {
                Icon(Icons.Filled.PushPin, "Pinned", tint = HavenTheme.pink, modifier = Modifier.size(16.dp))
            }
        }
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            val isPinned = com.blaineam.haven.core.DmPins.isPinned(conv.circleId)
            val canPin = isPinned || !com.blaineam.haven.core.DmPins.isFull
            DropdownMenuItem(
                enabled = canPin,
                text = { Text(if (isPinned) "Unpin" else "Pin") },
                onClick = { com.blaineam.haven.core.DmPins.toggle(conv.circleId); showMenu = false },
            )
            DropdownMenuItem(
                text = { Text("Delete conversation", color = HavenTheme.pink) },
                onClick = { showMenu = false; confirmDelete = true },
            )
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            containerColor = HavenTheme.card,
            title = { Text("Delete conversation?", color = HavenTheme.textPrimary) },
            text = { Text("This hides the messages on this device. Re-starting the chat won't restore them.",
                color = HavenTheme.textSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    com.blaineam.haven.core.DmPins.unpin(conv.circleId)
                    HavenNet.deleteConversation(conv.circleId)
                    confirmDelete = false
                }) { Text("Delete", color = HavenTheme.pink) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("Cancel", color = HavenTheme.textSecondary) }
            },
        )
    }
}

/** Unread-count pill for conversation rows (and anywhere else a count belongs). iOS parity. */
@Composable
fun UnreadBadge(count: Int) {
    Box(
        Modifier.defaultMinSize(minWidth = 20.dp, minHeight = 20.dp)
            .clip(RoundedCornerShape(10.dp)).background(HavenTheme.pink)
            .padding(horizontal = if (count > 9) 6.dp else 0.dp),
        contentAlignment = Alignment.Center,
    ) {
        // White-on-pink-fill, not a theme surface — stays white in both modes.
        Text(if (count > 99) "99+" else "$count", color = Color.White,
            fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

/** Pick who to message: one contact for a 1:1, two or more for a group DM. This is the ONLY way into
 *  a new thread now that the list shows conversations rather than the whole address book. */
@Composable
private fun NewMessagePicker(onDismiss: () -> Unit, onStart: (List<Contact>) -> Unit) {
    val contacts = HavenNet.contacts
    val picked = remember { mutableStateListOf<String>() }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = HavenTheme.card,
        title = { Text("New message", color = HavenTheme.textPrimary) },
        text = {
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                items(contacts, key = { it.idHex }) { c ->
                    val on = picked.contains(c.idHex)
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .clickable { if (on) picked.remove(c.idHex) else picked.add(c.idHex) }
                            .padding(vertical = 8.dp, horizontal = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        HavenAvatar(idOrShort = c.idHex, name = c.name, size = 34.dp)
                        Spacer(Modifier.size(10.dp))
                        Text(c.name, color = HavenTheme.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                        Icon(
                            if (on) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                            null, tint = if (on) HavenTheme.pink else HavenTheme.textSecondary,
                        )
                    }
                }
            }
        },
        confirmButton = {
            val ready = picked.isNotEmpty()
            Text(
                if (ready) "Start (${picked.size})" else "Pick someone",
                color = if (ready) HavenTheme.pink else HavenTheme.textSecondary,
                modifier = Modifier.clickable(enabled = ready) {
                    onStart(contacts.filter { picked.contains(it.idHex) })
                }.padding(8.dp),
            )
        },
        dismissButton = {
            Text("Cancel", color = HavenTheme.textSecondary,
                modifier = Modifier.clickable { onDismiss() }.padding(8.dp))
        },
    )
}

@Composable
fun DmThread(circleId: String, partner: Contact, onBack: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var draft by remember { mutableStateOf("") }
    // A draft staged elsewhere ("Message the author" on a post) lands in the composer, UNSENT.
    // Appended rather than assigned, so re-entering a thread can't discard something half-typed.
    androidx.compose.runtime.LaunchedEffect(circleId) {
        com.blaineam.haven.core.DmDrafts.takeDraft(circleId)?.let { staged ->
            draft = if (draft.isBlank()) staged else "$draft\n$staged"
        }
    }
    // Full media array for the next send (may include poster/orig markers for videos).
    var pendingMedia by remember { mutableStateOf<List<String>>(emptyList()) }
    var pendingMusic by remember { mutableStateOf<uniffi.haven_ffi.TrackRefFfi?>(null) }
    var showMusicDialog by remember { mutableStateOf(false) }
    var showVoice by remember { mutableStateOf(false) }
    // In-app camera for a DM. Posts have had this since day one (CircleScreen `openCamera(true)`);
    // a DM could only ever attach from the gallery, so capturing something to send meant leaving
    // Haven, shooting in the system camera, coming back and picking it out of the roll.
    var showDmCamera by remember { mutableStateOf(false) }
    val dmCamPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { grants -> if (grants[android.Manifest.permission.CAMERA] == true) showDmCamera = true }
    fun openDmCamera() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.CAMERA
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        ) showDmCamera = true
        else dmCamPermission.launch(
            arrayOf(android.Manifest.permission.CAMERA, android.Manifest.permission.RECORD_AUDIO)
        )
    }
    var secretMode by remember { mutableStateOf(false) }
    var disappearSecs by remember { mutableStateOf<ULong?>(null) }
    var editingId by remember { mutableStateOf<String?>(null) }
    var showOptions by remember { mutableStateOf(false) }
    val version by HavenNet.feedVersion
    val msgs = remember(version, circleId) { HavenNet.messages(circleId) }
    // The user is viewing this thread: advance its read watermark on open AND whenever a message
    // arrives while it's open (keyed on version), plus once more on the way out — so backing out
    // never leaves a stale badge for a conversation the user just watched. iOS parity
    // (onAppear/onChange/onDisappear in DMThreadView).
    androidx.compose.runtime.LaunchedEffect(version, circleId) { HavenNet.markThreadRead(circleId) }
    androidx.compose.runtime.DisposableEffect(circleId) {
        onDispose { HavenNet.markThreadRead(circleId) }
    }
    val isGroup = remember(circleId) { HavenNet.isGroupDm(circleId) }
    val relayReachable by HavenNet.relayActive
    // Attaching to a DM encodes exactly like a post does, so it leaves the main thread the same way
    // — see MediaProcessing. This callback arrives on the main looper.
    val mediaScope = androidx.compose.runtime.rememberCoroutineScope()
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            mediaScope.launch {
                val refs = com.blaineam.haven.core.MediaProcessing.processing {
                    if (com.blaineam.haven.core.isVideoUri(context, uri)) {
                        com.blaineam.haven.core.LocalMedia.prepareVideo(context, uri, circleId).mediaRefs
                    } else {
                        com.blaineam.haven.core.loadAndDownscale(context, uri)
                            ?.let { listOf(com.blaineam.haven.core.LocalMedia.store(circleId, it)) }
                            ?: emptyList()
                    }
                }
                if (refs.isNotEmpty()) pendingMedia = refs
            }
        }
    }

    HavenBackground {
        // imePadding() lifts the composer above the on-screen keyboard so the focused
        // text field stays visible (parity with CircleScreen / StoryEditor).
        Column(Modifier.fillMaxSize().imePadding()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 8.dp, end = 16.dp, top = 14.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { onBack() },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = HavenTheme.textPrimary)
                }
                Spacer(Modifier.size(4.dp))
                HavenAvatar(idOrShort = partner.idHex, name = partner.name, size = 32.dp)
                Spacer(Modifier.size(8.dp))
                Text(partner.name, color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                val startCall = rememberCallStarter()
                Box(Modifier.size(40.dp).clip(CircleShape).clickable {
                    // Ring every member of the thread (the whole group for a group DM; just the one
                    // partner for a 1:1). Removed/blocked members are excluded by the call layer.
                    val ring = HavenNet.dmMemberHexes(circleId).filter { it != HavenNet.nodeIdHex.lowercase() }
                    startCall(if (ring.isNotEmpty()) ring else listOf(partner.idHex), partner.name)
                }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Videocam, "Video call", tint = HavenTheme.pink)
                }
            }

            // A chat opens at the NEWEST message. The list had no state at all, so it opened at the
            // top — the oldest thing ever said — and every conversation began with a scroll down
            // past history to find out what had just arrived.
            val listState = androidx.compose.foundation.lazy.rememberLazyListState()
            // `feedVersion` also bumps when MEDIA lands, which matters here: a photo bubble is a
            // placeholder until its bytes arrive, then grows to full height. Scrolling once on open
            // lands correctly against the placeholder and is then pushed off the bottom as every
            // image resolves — the thread drifts up by exactly the height the media gained. Re-anchor
            // on the same signal that changed the heights.
            val mediaTick by HavenNet.feedVersion
            androidx.compose.runtime.LaunchedEffect(circleId, msgs.size, mediaTick) {
                if (msgs.isEmpty()) return@LaunchedEffect
                // Follow new messages only when the reader is ALREADY at the bottom. Yanking someone
                // back down while they are reading history is worse than making them scroll.
                val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index
                val atBottom = last == null || last >= msgs.lastIndex - 1
                if (!atBottom) return@LaunchedEffect
                listState.scrollToItem(msgs.lastIndex)
                // One more pass after layout settles: an image that finishes decoding during this
                // frame changes its bubble's height after the scroll has already been resolved.
                kotlinx.coroutines.delay(120)
                listState.scrollToItem(msgs.lastIndex)
            }
            LazyColumn(
                Modifier.fillMaxWidth().weight(1f),
                state = listState,
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(msgs, key = { it.id }) { m ->
                    Bubble(m, circleId = circleId, isGroup = isGroup, relayReachable = relayReachable, onEdit = { msg ->
                        editingId = msg.id; secretMode = com.blaineam.haven.core.SecretMessages.isSecret(msg.body)
                        draft = com.blaineam.haven.core.SecretMessages.text(msg.body)
                    })
                }
            }

            // Shown while the attachment is still encoding — before this, picking a video in a DM
            // looked identical to the picker having silently failed.
            MediaProcessingCard(Modifier.padding(horizontal = 16.dp))

            // EVERY staged attachment, each removable — this drew only `firstOrNull()` with no remove
            // control, so a second photo (or a file, or a voice note) was staged and about to send with
            // nothing on screen saying so. A staged video now shows its poster instead of a generic
            // camera glyph, and an attachment with no pixels yet still gets a labelled tile rather than
            // vanishing. Apple parity (`ComposerAttachmentTile`).
            val stagedDm = com.blaineam.haven.core.MediaVariants.displayRefs(pendingMedia)
            if (stagedDm.isNotEmpty()) {
                androidx.compose.foundation.lazy.LazyRow(
                    Modifier.fillMaxWidth().padding(start = 16.dp, bottom = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(stagedDm.size) { i ->
                        val ref = stagedDm[i]
                        ComposerAttachmentTile(circleId, ref) {
                            pendingMedia = pendingMedia -
                                com.blaineam.haven.core.MediaVariants.companionRefs(ref, pendingMedia).toSet()
                        }
                    }
                }
            }
            pendingMusic?.let { m ->
                Row(Modifier.padding(start = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    MusicChip(m)
                    Icon(Icons.Filled.Close, "Remove song", tint = HavenTheme.textPrimary,
                        modifier = Modifier.padding(start = 6.dp).size(18.dp).clickable { pendingMusic = null })
                }
            }
            if (editingId != null) {
                Row(Modifier.padding(start = 16.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Editing message", color = HavenTheme.pink, fontSize = 12.sp)
                    Spacer(Modifier.size(10.dp))
                    Text("Cancel", color = HavenTheme.textSecondary, fontSize = 12.sp,
                        modifier = Modifier.clickable { editingId = null; draft = ""; secretMode = false })
                }
            }

            // ONE attachment button, not five (iOS Messages parity — a single `plus.circle.fill`
            // menu). Camera / photo / song / voice / secret / disappearing each owned a fixed 40dp
            // slot, so 200dp of a phone's ~360dp bar was spent before the field was measured: the
            // composer was a ~80dp stub you could not read your own sentence in, and it got worse on
            // any device with a larger display size. Everything they did now lives in this menu.
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(contentAlignment = Alignment.Center) {
                    Box(Modifier.size(40.dp).clip(CircleShape).clickable { showOptions = true },
                        contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.AddCircle, "Attach", tint = HavenTheme.pink)
                    }
                    DropdownMenu(expanded = showOptions, onDismissRequest = { showOptions = false }) {
                        DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.AddPhotoAlternate, null, tint = HavenTheme.pink) },
                            text = { Text("Photo or video") },
                            onClick = {
                                showOptions = false
                                picker.launch(androidx.activity.result.PickVisualMediaRequest(
                                    androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                            })
                        DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.PhotoCamera, null, tint = HavenTheme.pink) },
                            text = { Text("Camera") },
                            onClick = { showOptions = false; openDmCamera() })
                        DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.Mic, null, tint = HavenTheme.pink) },
                            text = { Text("Voice message") },
                            onClick = { showOptions = false; showVoice = true })
                        DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.pink) },
                            text = { Text("Song") },
                            onClick = { showOptions = false; showMusicDialog = true })
                        androidx.compose.material3.HorizontalDivider(color = HavenTheme.cardBorder)
                        DropdownMenuItem(
                            text = { Text(if (secretMode) "✓ Secret message" else "Secret message") },
                            onClick = { secretMode = !secretMode; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == null) "✓ Don't disappear" else "Don't disappear") },
                            onClick = { disappearSecs = null; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == 3_600UL) "✓ Disappear · 1 hour" else "Disappear · 1 hour") },
                            onClick = { disappearSecs = 3_600UL; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == 86_400UL) "✓ Disappear · 1 day" else "Disappear · 1 day") },
                            onClick = { disappearSecs = 86_400UL; showOptions = false })
                        DropdownMenuItem(
                            text = { Text(if (disappearSecs == 604_800UL) "✓ Disappear · 1 week" else "Disappear · 1 week") },
                            onClick = { disappearSecs = 604_800UL; showOptions = false })
                    }
                }
                // Disappearing is the one menu choice with no other trace on screen — a sent message
                // looks identical either way — so it keeps a chip out here.
                disappearSecs?.let { secs ->
                    Text(dmDisappearLabel(secs), color = HavenTheme.pink, fontSize = 11.sp,
                        maxLines = 1, softWrap = false,
                        modifier = Modifier.padding(end = 2.dp))
                }
                Spacer(Modifier.size(4.dp))
                OutlinedTextField(
                    value = draft, onValueChange = { draft = it },
                    placeholder = { Text(if (secretMode) "Secret message…" else "Message…") },
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(22.dp), maxLines = 4,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
                )
                Spacer(Modifier.size(8.dp))
                val canSend = draft.isNotBlank() || pendingMedia.isNotEmpty() || pendingMusic != null
                Box(
                    Modifier.size(48.dp).clip(CircleShape).background(HavenTheme.brandHorizontal)
                        .clickable(enabled = canSend) {
                            val body = if (secretMode && draft.isNotBlank())
                                com.blaineam.haven.core.SecretMessages.encode(draft.trim()) else draft.trim()
                            val eid = editingId
                            if (eid != null) HavenNet.editPost(circleId, eid, body)
                            else HavenNet.sendDm(circleId, body, pendingMedia, pendingMusic, disappearSecs)
                            // disappearSecs stays sticky for the conversation (iOS parity); reset the rest.
                            draft = ""; pendingMedia = emptyList(); pendingMusic = null; secretMode = false; editingId = null
                        },
                    contentAlignment = Alignment.Center,
                    // White-on-brand-gradient — never themed.
                ) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Color.White) }
            }
        }
        if (showMusicDialog) {
            MusicSearchSheet(onPick = { pendingMusic = it; showMusicDialog = false }, onDismiss = { showMusicDialog = false })
        }
        if (showDmCamera) {
            // Same capture surface as a post; the ref is stored under THIS dm: circle so the
            // attachment seals to the conversation, then staged in the composer for review rather
            // than sent immediately.
            FullScreenOverlay(onDismiss = { showDmCamera = false }) {
                StoryCameraScreen(
                    onClose = { showDmCamera = false },
                    storeCircle = circleId,
                    onCaptured = { ref, _ -> pendingMedia = pendingMedia + ref; showDmCamera = false },
                )
            }
        }
        if (showVoice) {
            VoiceRecorderDialog(circleId,
                onDone = { ref -> HavenNet.sendDm(circleId, "", listOf(ref)); showVoice = false },
                onDismiss = { showVoice = false })
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Bubble(
    m: uniffi.haven_ffi.FeedItemFfi,
    circleId: String,
    isGroup: Boolean = false,
    relayReachable: Boolean = false,
    onEdit: ((uniffi.haven_ffi.FeedItemFfi) -> Unit)? = null,
) {
    val mine = m.isMe
    val text = m.body
    var showReact by remember(m.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        // In a group DM, label each INCOMING message with who sent it (parity with iOS).
        if (isGroup && !mine) {
            Text(
                HavenNet.displayName(m.authorShort), color = HavenTheme.pink,
                fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 4.dp, bottom = 2.dp),
            )
        }
        // MY bubble is a pink FILL (white content, both modes); theirs is a theme card (themed content).
        val bubbleContent = if (mine) Color.White else HavenTheme.textPrimary
        Column(
            Modifier.widthIn(max = 280.dp).clip(RoundedCornerShape(18.dp))
                .background(if (mine) HavenTheme.pink else HavenTheme.card)
                .combinedClickable(onClick = {}, onLongClick = { showReact = true })
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            // `displayRefs`, not the raw list (iOS Messages.swift `dmMedia`). A shared image travels
            // with companions — `thumb:<ref>:<thumb>`, `orig:`, `poster:` — which are MARKERS, not
            // blobs. Iterating the raw list drew one tile per entry, so a single sent photo showed
            // two stacked tiles, and the marker one span forever: there is no blob at that ref to
            // fetch, so its spinner could never resolve. The composer path already collapsed these
            // (line ~476); only the received bubble was left rendering them.
            com.blaineam.haven.core.MediaVariants.displayRefs(m.media).forEach { ref ->
                when {
                    com.blaineam.haven.core.LocalMedia.isAudio(ref) -> AudioPlayerPill(circleId, ref, contentColor = bubbleContent)
                    // Honors a flag federated by a member whose platform has an analyzer (iOS
                    // Messages.swift:457,468 wraps the same two cases at radius 14).
                    com.blaineam.haven.core.LocalMedia.isVideo(ref) ->
                        SensitiveGuard(circleId, ref, cornerRadius = 14) { covered ->
                            // A blur hides the picture, not the sound — don't play a covered clip.
                            if (covered) Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(12.dp)).background(HavenTheme.card))
                            else VideoTile(circleId, ref, Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)))
                        }
                    else -> SensitiveGuard(circleId, ref, cornerRadius = 14) { _ ->
                        MediaImage(circleId, ref, Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)))
                    }
                }
                if (text.isNotBlank() || m.music != null) Spacer(Modifier.size(6.dp))
            }
            if (text.isNotBlank()) {
                if (com.blaineam.haven.core.SecretMessages.isSecret(text)) SecretBubble(text, bubbleContent)
                else LinkedText(text, color = bubbleContent, fontSize = 15.sp)
            }
            // A shared song renders as the same chip as in the feed.
            m.music?.let { mus ->
                if (text.isNotBlank()) Spacer(Modifier.size(6.dp))
                MusicChip(mus)
            }
        }
        // Reactions on this message — tap one to toggle yours (long-press the bubble to add).
        if (m.reactions.isNotEmpty()) {
            Row(Modifier.padding(top = 3.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                m.reactions.forEach { r ->
                    Box(
                        Modifier.clip(RoundedCornerShape(12.dp)).background(HavenTheme.card)
                            .clickable {
                                if (r.mine) HavenNet.unreact(circleId, m.id, r.emoji)
                                else HavenNet.react(circleId, m.id, r.emoji)
                            }
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                    ) { Text("${r.emoji} ${r.count}", fontSize = 12.sp, color = HavenTheme.textPrimary) }
                }
            }
        }
        // Timestamp + (for own, sent messages) a delivery checkmark: outline when sent, filled when
        // the circle's relay accepted it (store-and-forward delivered). Parity with iOS Messages.
        Row(
            Modifier.padding(top = 3.dp, start = 4.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(msgTime(m.createdAt), color = HavenTheme.textSecondary, fontSize = 10.sp)
            if (m.edited && !m.unsent) Text("edited", color = HavenTheme.textSecondary, fontSize = 10.sp)
            if (mine && !m.unsent) {
                Icon(
                    if (relayReachable) Icons.Filled.DoneAll else Icons.Filled.Check,
                    contentDescription = if (relayReachable) "Delivered" else "Sent",
                    tint = if (relayReachable) HavenTheme.pink else HavenTheme.textSecondary,
                    modifier = Modifier.size(12.dp),
                )
            }
        }
    }
    if (showReact) {
        AlertDialog(
            onDismissRequest = { showReact = false },
            confirmButton = { TextButton(onClick = { showReact = false }) { Text("Close", color = HavenTheme.pink) } },
            text = {
                Column {
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        listOf("❤️", "😂", "👍", "🎉", "😮", "😢", "🔥").forEach { e ->
                            Text(e, fontSize = 28.sp, modifier = Modifier.clickable {
                                HavenNet.react(circleId, m.id, e); showReact = false
                            })
                        }
                    }
                    // Your own message: edit (text) or delete.
                    if (mine) {
                        Spacer(Modifier.size(14.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                            if (text.isNotBlank()) Text("Edit", color = HavenTheme.pink, fontSize = 15.sp,
                                modifier = Modifier.clickable { onEdit?.invoke(m); showReact = false })
                            Text("Delete", color = HavenTheme.pink, fontSize = 15.sp,
                                modifier = Modifier.clickable { HavenNet.unsendPost(circleId, m.id); showReact = false })
                        }
                    }
                }
            },
        )
    }
}

/** Short relative timestamp for a message (now / 5m / 3h / 2d / 1w). */
private fun msgTime(createdAtMs: kotlin.ULong): String {
    val diff = System.currentTimeMillis() - createdAtMs.toLong()
    if (diff < 0) return "now"
    val s = diff / 1000
    return when {
        s < 5 -> "now"
        s < 60 -> "${s}s"
        s < 3600 -> "${s / 60}m"
        s < 86_400 -> "${s / 3600}h"
        s < 604_800 -> "${s / 86_400}d"
        s < 2_592_000 -> "${s / 604_800}w"
        else -> "${s / 2_592_000}mo"
    }
}

/** Compact label for the DM composer's disappearing chip ("1h" / "1d" / "1w"). */
private fun dmDisappearLabel(secs: kotlin.ULong): String = when (secs) {
    3_600UL -> "⏱ 1h"; 86_400UL -> "⏱ 1d"; 604_800UL -> "⏱ 1w"
    else -> "⏱ ${secs / 3_600UL}h"
}
