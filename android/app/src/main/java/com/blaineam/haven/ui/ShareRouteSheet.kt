package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.CircleLock
import com.blaineam.haven.core.Contact
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.MediaVariants
import com.blaineam.haven.core.ShareInbox

/**
 * Where should something shared into Haven from another app go? — the Android counterpart of
 * Apple's `ShareRouteView`.
 *
 * Shared content used to land silently in the Circle composer, which meant it always became a post
 * in whatever circle happened to be active and could never be sent to one person. This asks: a post
 * in a circle, a story, or a conversation.
 *
 * When the share arrived through the Direct Share row ([ShareInbox.Payload.targetCircleId] is set),
 * the destination is already chosen and this opens straight into that thread's composer.
 */
@Composable
fun ShareRouteSheet(payload: ShareInbox.Payload, onDone: () -> Unit) {
    // A conversation named by a Direct Share tap is only honored if it still exists here and isn't
    // locked — a stale shortcut (thread since deleted, circle since locked) falls back to the sheet.
    val preselected = remember(payload.targetCircleId) {
        payload.targetCircleId?.takeIf { id ->
            runCatching { HavenNet.engine.circles() }.getOrDefault(emptyList()).any { it.id == id } &&
                !CircleLock.isLocked(id)
        }
    }
    var route by remember { mutableStateOf(preselected?.let { Route.Dm(it) } ?: Route.Choose) }
    var storyRef by remember { mutableStateOf<String?>(null) }

    val ref = storyRef
    if (ref != null) {
        StoryEditor(ref = ref, isVideo = LocalMedia.isVideo(ref), onClose = { storyRef = null; onDone() })
        return
    }

    HavenBackground {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, top = 16.dp, bottom = 8.dp, end = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BrandText(
                    when (val r = route) {
                        Route.Choose -> "Share to Haven"
                        Route.Post -> "Share as post"
                        is Route.Dm -> HavenNet.dmPartnerName(r.circleId)
                        Route.PickPerson -> "Send to"
                    },
                    fontSize = 24, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "Cancel", color = HavenTheme.textSecondary, fontSize = 15.sp,
                    modifier = Modifier.clickable { ShareInbox.clear(); onDone() }.padding(8.dp),
                )
            }
            when (val r = route) {
                Route.Choose -> ChooseRoute(
                    payload = payload,
                    onPost = { route = Route.Post },
                    onDm = { route = Route.PickPerson },
                    onThread = { route = Route.Dm(it) },
                    // A story always lives in the default circle (StoryEditor and `postStory` both
                    // assume it), so re-seal the shared blob there before handing it over —
                    // otherwise the story posts with media nobody, including us, can open.
                    onStory = { storyRef = resealed(listOf(it), DEFAULT_CIRCLE).firstOrNull() },
                )
                Route.Post -> SendStep(payload, Target.Circles, onSent = onDone)
                Route.PickPerson -> SendStep(payload, Target.People, onSent = onDone)
                is Route.Dm -> SendStep(payload, Target.Thread(r.circleId), onSent = onDone)
            }
        }
    }
}

private sealed interface Route {
    data object Choose : Route
    data object Post : Route
    data object PickPerson : Route
    data class Dm(val circleId: String) : Route
}

/** What the send step is choosing between. */
private sealed interface Target {
    /** Pick one of your circles and post there. */
    data object Circles : Target
    /** Pick a conversation (or someone you haven't messaged yet). */
    data object People : Target
    /** Already decided — a Direct Share tap or the Recent strip. */
    data class Thread(val circleId: String) : Target
}

/** The first screen: a preview of what's being shared, recent conversations, and the three routes. */
@Composable
private fun ChooseRoute(
    payload: ShareInbox.Payload,
    onPost: () -> Unit,
    onDm: () -> Unit,
    onThread: (String) -> Unit,
    onStory: (String) -> Unit,
) {
    val active = HavenNet.activeCircle.value
    val display = remember(payload.media) { MediaVariants.displayRefs(payload.media) }
    // A story is a single visual — offer it only when there's something to look at.
    val storyable = display.firstOrNull { !LocalMedia.isFile(it) && !LocalMedia.isAudio(it) }

    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        if (display.isNotEmpty()) {
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(display.size) { i -> ComposerAttachmentTile(active, display[i], size = 70.dp) }
                }
                Spacer(Modifier.size(12.dp))
            }
        }
        if (payload.text.isNotBlank()) {
            item {
                Text(
                    payload.text, color = HavenTheme.textSecondary, fontSize = 14.sp,
                    maxLines = 4, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                        .background(HavenTheme.card).padding(12.dp),
                )
                Spacer(Modifier.size(12.dp))
            }
        }
        val recents = recentThreads()
        if (recents.isNotEmpty()) {
            item {
                Text("Recent", color = HavenTheme.textSecondary, fontSize = 13.sp,
                     modifier = Modifier.padding(bottom = 8.dp))
                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(recents.size) { i ->
                        val id = recents[i]
                        val title = HavenNet.dmPartnerName(id)
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.width(66.dp).clip(RoundedCornerShape(12.dp))
                                .clickable { onThread(id) }.padding(vertical = 4.dp),
                        ) {
                            HavenAvatar(idOrShort = partnerHex(id), name = title, size = 48.dp)
                            Spacer(Modifier.size(6.dp))
                            Text(title, color = HavenTheme.textPrimary, fontSize = 11.sp,
                                 maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
                Spacer(Modifier.size(16.dp))
            }
        }
        item { RouteRow("📣", "Share as post", "Post it to one of your circles", onPost) }
        item { RouteRow("💬", "Send as direct message", "Pick a conversation or someone new", onDm) }
        if (storyable != null) {
            item { RouteRow("✨", "Create story", "Add a caption and share for 24 hours") { onStory(storyable) } }
        }
    }
}

@Composable
private fun RouteRow(glyph: String, title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp).clip(RoundedCornerShape(14.dp))
            .background(HavenTheme.card).clickable { onClick() }.padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(glyph, fontSize = 22.sp)
        Spacer(Modifier.size(12.dp))
        Column {
            Text(title, color = HavenTheme.textPrimary, fontSize = 15.sp)
            Text(subtitle, color = HavenTheme.textSecondary, fontSize = 12.sp)
        }
    }
}

/** Caption + destination + Send. */
@Composable
private fun SendStep(payload: ShareInbox.Payload, target: Target, onSent: () -> Unit) {
    var caption by remember { mutableStateOf("") }
    var circleId by remember {
        mutableStateOf(
            when (target) {
                is Target.Thread -> target.circleId
                Target.Circles -> HavenNet.feedCircles().firstOrNull()?.id.orEmpty()
                Target.People -> ""
            },
        )
    }
    // Someone you have no thread with yet — the DM is opened at send time, not on selection, so
    // backing out of this screen doesn't leave a half-started conversation behind.
    var newContact by remember { mutableStateOf<Contact?>(null) }

    // Destination lists, resolved OUT here: a LazyColumn's item scope isn't composable, so
    // `remember` can't live inside it.
    val circles = remember { HavenNet.feedCircles().filter { !CircleLock.isLocked(it.id) } }
    val threads = remember { recentThreads(includeQuiet = true) }
    val freshContacts = remember(threads) {
        val started = threads.toSet()
        HavenNet.contacts.filter { HavenNet.dmCircleId(it.idHex) !in started }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        BasicTextField(
            value = caption,
            onValueChange = { caption = it },
            textStyle = TextStyle(color = HavenTheme.textPrimary, fontSize = 15.sp),
            cursorBrush = SolidColor(HavenTheme.pink),
            decorationBox = { field ->
                Box(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                        .background(HavenTheme.card).padding(12.dp),
                ) {
                    if (caption.isEmpty()) {
                        Text("Add a caption…", color = HavenTheme.textSecondary, fontSize = 15.sp)
                    }
                    field()
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.size(12.dp))

        LazyColumn(Modifier.weight(1f)) {
            when (target) {
                is Target.Thread -> Unit   // destination already decided
                Target.Circles -> items(circles.size) { i ->
                    val c = circles[i]
                    PickRow(HavenNet.circleName(c.id), circleId == c.id) { circleId = c.id }
                }
                Target.People -> {
                    if (threads.isNotEmpty()) {
                        item { SectionLabel("Conversations") }
                        items(threads.size) { i ->
                            val id = threads[i]
                            PickRow(HavenNet.dmPartnerName(id), circleId == id) {
                                circleId = id; newContact = null
                            }
                        }
                    }
                    if (freshContacts.isNotEmpty()) {
                        item { SectionLabel("Other people") }
                        items(freshContacts.size) { i ->
                            val c = freshContacts[i]
                            PickRow(c.name, newContact?.idHex == c.idHex) {
                                newContact = c; circleId = ""
                            }
                        }
                    }
                }
            }
        }

        val hasContent = payload.text.isNotBlank() || payload.media.isNotEmpty() || caption.isNotBlank()
        val ready = hasContent && (circleId.isNotBlank() || newContact != null)
        Text(
            "Send",
            color = if (ready) HavenTheme.pink else HavenTheme.textSecondary,
            fontSize = 16.sp,
            modifier = Modifier.align(Alignment.End).clickable(enabled = ready) {
                val body = listOf(caption.trim(), payload.text.trim())
                    .filter { it.isNotBlank() }.joinToString("\n")
                when (target) {
                    Target.Circles -> HavenNet.post(circleId, body, resealed(payload.media, circleId))
                    else -> {
                        val dm = newContact?.let { HavenNet.startDm(it) } ?: circleId
                        // sendDm republishes the Direct Share row itself — the thread just used is
                        // now the most recent one.
                        HavenNet.sendDm(dm, body, resealed(payload.media, dm))
                    }
                }
                ShareInbox.clear()
                onSent()
            }.padding(16.dp),
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, color = HavenTheme.textSecondary, fontSize = 12.sp,
         modifier = Modifier.padding(top = 12.dp, bottom = 4.dp))
}

@Composable
private fun PickRow(title: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { onClick() }
            .padding(vertical = 10.dp, horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = HavenTheme.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f),
             maxLines = 1, overflow = TextOverflow.Ellipsis)
        Icon(
            if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            null, tint = if (selected) HavenTheme.pink else HavenTheme.textSecondary,
        )
    }
}

/**
 * Unlocked DM threads, most recently active first — the in-app echo of the Direct Share row.
 * [includeQuiet] keeps threads nothing has been said in yet, which the full picker wants and the
 * "Recent" strip does not.
 */
private fun recentThreads(includeQuiet: Boolean = false): List<String> {
    val ranked = runCatching { HavenNet.engine.circles() }.getOrDefault(emptyList())
        .map { it.id }
        .filter { it.startsWith("dm:") && !CircleLock.isLocked(it) }
        .map { it to HavenNet.lastActivity(it) }
        .filter { includeQuiet || it.second > 0uL }
        .sortedByDescending { it.second }
        .map { it.first }
    return if (includeQuiet) ranked else ranked.take(8)
}

private fun partnerHex(circleId: String): String =
    HavenNet.dmMemberHexes(circleId).firstOrNull { !it.equals(HavenNet.nodeIdHex, true) }.orEmpty()

/**
 * Re-seal staged blobs under the destination circle's key.
 *
 * Media is sealed at rest, and the sealed bytes are what gets uploaded verbatim for the recipient —
 * so a blob staged while another circle was active is unreadable to everyone in the thread it's
 * being sent to. `storeUnderRef` re-seals in place and KEEPS the ref, which matters because the ref
 * prefix carries the kind: minting a fresh one via `store()` would turn a shared PDF (`file_…`) into
 * an image nobody can open. Synthetic poster/original markers have no blob and are passed through.
 */
private fun resealed(media: List<String>, circleId: String): List<String> {
    for (ref in media) {
        val bytes = LocalMedia.loadAnyCircle(ref) ?: continue
        LocalMedia.storeUnderRef(circleId, ref, bytes)
    }
    return media
}
