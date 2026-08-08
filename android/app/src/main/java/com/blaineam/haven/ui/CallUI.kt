package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items as lazyItems
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material.icons.filled.StopScreenShare
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.PhoneInTalk
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.blaineam.haven.core.Contact
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.blaineam.haven.R
import com.blaineam.haven.core.CallManager
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

/**
 * Renders one WebRTC video track in a SurfaceViewRenderer it owns, attaching/detaching the sink
 * across recomposition so tracks bind reliably.
 */
@Composable
fun CallVideoTile(track: VideoTrack?, modifier: Modifier = Modifier, mirror: Boolean = false, fit: Boolean = false) {
    val context = LocalContext.current
    val view = remember {
        SurfaceViewRenderer(context).apply {
            init(CallManager.eglBase.eglBaseContext, null)
            setEnableHardwareScaler(true)
            setMirror(mirror)
            // Screen shares aspect-FIT (show the whole screen, letterboxed); camera tiles fill.
            setScalingType(if (fit) RendererCommon.ScalingType.SCALE_ASPECT_FIT else RendererCommon.ScalingType.SCALE_ASPECT_FILL)
        }
    }
    AndroidView(factory = { view }, modifier = modifier)
    DisposableEffect(track) {
        track?.addSink(view)
        onDispose { runCatching { track?.removeSink(view) } }
    }
    DisposableEffect(Unit) { onDispose { runCatching { view.release() } } }
}

/** Returns a launcher that requests camera+mic, then starts a call to the given participants. */
@Composable
fun rememberCallStarter(): (List<String>, String) -> Unit {
    val pending = remember { androidx.compose.runtime.mutableStateOf<Pair<List<String>, String>?>(null) }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        if (grants.values.all { it }) pending.value?.let { (o, n) -> CallManager.startCall(o, n) }
        pending.value = null
    }
    return { others, name ->
        pending.value = others to name
        launcher.launch(arrayOf(android.Manifest.permission.CAMERA, android.Manifest.permission.RECORD_AUDIO))
    }
}

/**
 * The in-call palette. Fixed, NOT the [HavenTheme] tokens: the call surface is deliberately black in
 * BOTH modes, so it needs dark-mode colours even when the app is light. `HavenTheme.card` here was a
 * live light-mode bug — it resolves to pure white, which collided with the white "on" chip state and
 * made [RoundButton]'s `bg == card` tint test true for every chip, painting white glyphs on white.
 */
private val CallChip = Color(0xFF16161D)
private val CallSecondary = Color(0xFF9A9AA8)

/** The call overlay: incoming ring, or the in-call mesh grid. Mounted at the app root. */
@Composable
fun CallOverlay() {
    val ringing by CallManager.ringing
    val inCall by CallManager.inCall
    val connecting by CallManager.connecting
    val minimized by CallManager.minimized

    // Hold the screen on for as long as a call is up. The wake lock in CallManager keeps the CPU
    // alive so audio keeps flowing, but the display still times out mid-call and the user is left
    // tapping the phone awake to reach Mute or Hang up — every other calling app on the platform
    // keeps the screen lit, and the proximity sensor handles the ear case for us.
    val active = ringing || inCall || connecting
    val view = androidx.compose.ui.platform.LocalView.current
    androidx.compose.runtime.DisposableEffect(active) {
        val window = (view.context as? android.app.Activity)?.window
        if (active) window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // Back during a call minimizes it (the same thing the ⌄ control does) rather than dropping out
    // of Haven with the call still up. A RINGING call swallows back entirely: neither answering nor
    // declining should be something you do by accident on the way out of the app.
    androidx.activity.compose.BackHandler(enabled = (inCall || connecting) && !minimized) {
        CallManager.minimized.value = true
    }
    androidx.activity.compose.BackHandler(enabled = ringing && !inCall) { /* absorb */ }

    when {
        ringing && !inCall -> IncomingCall()
        (inCall || connecting) && minimized -> Unit   // shown as a nav-bar "Call" tab (see RootScreen)
        inCall || connecting -> InCall()
    }
}

/** A small floating call tile (the rest of the app stays usable); tap to return, or end. */
@Composable
private fun MinimizedCall() {
    val name by CallManager.peerName
    val firstRemote = CallManager.participants.firstOrNull()?.let { CallManager.remoteVideo[it] }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Row(
            Modifier.padding(top = 48.dp).clip(RoundedCornerShape(16.dp)).background(Color(0xE6000000))
                .clickable { CallManager.minimized.value = false }.padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(50.dp, 66.dp).clip(RoundedCornerShape(10.dp)).background(CallChip)) {
                CallVideoTile(firstRemote, Modifier.fillMaxSize())
            }
            Spacer(Modifier.size(10.dp))
            Column {
                Text(name.ifBlank { stringResource(R.string.call_haven_call) }, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(stringResource(R.string.call_tap_to_return), color = CallSecondary, fontSize = 11.sp)
            }
            Spacer(Modifier.size(12.dp))
            Box(Modifier.size(40.dp).clip(CircleShape).background(Color(0xFFEF4444)).clickable { CallManager.hangup() },
                contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.CallEnd, stringResource(R.string.call_end), tint = Color.White, modifier = Modifier.size(20.dp))
            }
        }
    }
}

@Composable
private fun IncomingCall() {
    val name by CallManager.peerName
    // Opaque: this overlays the live feed, and the 5% that used to show through leaked post
    // content behind the ring screen (iOS had the same bug, far worse over its light gradient).
    Box(Modifier.fillMaxSize().consumesTaps().background(Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            ConstellationMark(Modifier.size(72.dp), color = Color.White)   // fixed-black ring surface
            Spacer(Modifier.height(20.dp))
            Text(name.ifBlank { stringResource(R.string.call_incoming_call) }, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(4.dp))
            Text(stringResource(R.string.call_haven_call), color = CallSecondary, fontSize = 14.sp)
            Spacer(Modifier.height(48.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                RoundButton(Icons.Filled.CallEnd, Color(0xFFEF4444), stringResource(R.string.call_decline)) { CallManager.decline() }
                RoundButton(Icons.Filled.Videocam, Color(0xFF22C55E), stringResource(R.string.call_accept)) { CallManager.accept() }
            }
        }
    }
}

@Composable
private fun InCall() {
    val name by CallManager.peerName
    val micOn by CallManager.micOn
    val cameraOn by CallManager.cameraOn
    val speakerOn by CallManager.speakerOn
    val participants = CallManager.participants
    val remote = CallManager.remoteVideo
    val sharing by CallManager.screenShare
    var showAddPeople by remember { mutableStateOf(false) }
    val context = androidx.compose.ui.platform.LocalContext.current
    if (showAddPeople) AddToCallPicker(onDismiss = { showAddPeople = false })
    // System MediaProjection consent → start the screen capture on approval.
    val projectionLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()) { result ->
        val data = result.data
        if (result.resultCode == android.app.Activity.RESULT_OK && data != null) {
            CallManager.startScreenShare(result.resultCode, data)
        }
    }

    // A peer sharing their screen takes over the main view (aspect-fit, whole screen visible).
    val screenShareEntry = CallManager.remoteScreen.entries.firstOrNull { it.value != null }
    Box(Modifier.fillMaxSize().consumesTaps().background(Color.Black)) {
        when {
            screenShareEntry != null -> {
                CallVideoTile(screenShareEntry.value, Modifier.fillMaxSize(), fit = true)
                Text(stringResource(R.string.call_screen_share_notice, screenShareEntry.key.take(6)),
                    color = Color.White, fontSize = 12.sp,
                    modifier = Modifier.align(Alignment.TopCenter).padding(top = 64.dp)
                        .clip(RoundedCornerShape(8.dp)).background(Color.Black.copy(alpha = 0.5f)).padding(horizontal = 10.dp, vertical = 4.dp))
            }
            participants.isEmpty() -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.call_connecting), color = Color.White, fontSize = 18.sp)
                }
            }
            participants.size == 1 -> {
                // 1:1 — the other person fills the screen edge-to-edge (no tile margin or name badge),
                // matching iOS. Their camera fills, or the brand gradient + avatar if the camera is off.
                CallTile(participants[0], remote, fill = true, showName = false, Modifier.fillMaxSize())
            }
            else -> {
                // Group — a rounded-corner grid of branded tiles, each with the person's name badge.
                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(participants, key = { it }) { hex ->
                        CallTile(hex, remote, fill = false, showName = true, Modifier.aspectRatio(0.8f))
                    }
                }
            }
        }

        // Local self-preview.
        Box(
            Modifier.align(Alignment.TopEnd).padding(12.dp).size(96.dp, 132.dp)
                .clip(RoundedCornerShape(12.dp)).background(CallChip),
        ) { CallVideoTile(CallManager.localVideo, Modifier.fillMaxSize(), mirror = true) }

        // Title + minimize (return to the app while the call continues).
        Row(Modifier.align(Alignment.TopStart).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.4f))
                .clickable { CallManager.minimized.value = true }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.KeyboardArrowDown, stringResource(R.string.call_minimize), tint = Color.White)
            }
            Spacer(Modifier.size(10.dp))
            Text(name.ifBlank { stringResource(R.string.call_haven_call) }, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }

        // Controls — TWO rows, matching iOS: media toggles up top, call actions (share / add /
        // hang up) below. A single row of 7 buttons was wider than any phone screen, which
        // silently pushed the share-screen and HANG-UP buttons off the right edge.
        Column(
            Modifier.align(Alignment.BottomCenter).padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                RoundButton(if (micOn) Icons.Filled.Mic else Icons.Filled.MicOff,
                    if (micOn) CallChip else Color.White, stringResource(R.string.call_mic)) { CallManager.toggleMic() }
                RoundButton(if (speakerOn) Icons.Filled.VolumeUp else Icons.Filled.PhoneInTalk,
                    if (speakerOn) Color.White else CallChip, if (speakerOn) stringResource(R.string.call_speaker_on) else stringResource(R.string.call_speaker_off)) {
                    CallManager.toggleSpeaker()
                }
                RoundButton(if (cameraOn) Icons.Filled.Videocam else Icons.Filled.VideocamOff,
                    if (cameraOn) CallChip else Color.White, stringResource(R.string.call_camera)) { CallManager.toggleCamera() }
                if (cameraOn) {
                    RoundButton(Icons.Filled.Cameraswitch, CallChip, stringResource(R.string.call_flip)) { CallManager.switchCamera() }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                RoundButton(if (sharing) Icons.Filled.StopScreenShare else Icons.Filled.ScreenShare,
                    if (sharing) Color.White else CallChip, stringResource(R.string.call_share_screen)) {
                    if (sharing) CallManager.stopScreenShare()
                    else {
                        val mpm = context.getSystemService(android.content.Context.MEDIA_PROJECTION_SERVICE)
                            as android.media.projection.MediaProjectionManager
                        projectionLauncher.launch(mpm.createScreenCaptureIntent())
                    }
                }
                RoundButton(Icons.Filled.PersonAdd, CallChip, stringResource(R.string.call_add_people),
                    enabled = CallManager.addableContacts().isNotEmpty()) { showAddPeople = true }
                RoundButton(Icons.Filled.CallEnd, Color(0xFFEF4444), stringResource(R.string.call_end)) { CallManager.hangup() }
            }
        }
    }
}

/** Pick a contact to add to the in-progress call. */
@Composable
private fun AddToCallPicker(onDismiss: () -> Unit) {
    val candidates = remember { CallManager.addableContacts() }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = HavenTheme.card,
        title = { Text(stringResource(R.string.call_add_to_call_title), color = HavenTheme.textPrimary) },
        text = {
            LazyColumn(Modifier.heightIn(max = 320.dp)) {
                lazyItems(candidates, key = { it.idHex }) { c: Contact ->
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .clickable { CallManager.addToCall(listOf(c.idHex)); onDismiss() }
                            .padding(vertical = 8.dp, horizontal = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        HavenAvatar(idOrShort = c.idHex, name = c.name, size = 34.dp)
                        Spacer(Modifier.size(10.dp))
                        Text(c.name, color = HavenTheme.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                        Icon(Icons.Filled.PersonAdd, null, tint = HavenTheme.pink)
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            Text(stringResource(R.string.common_done), color = HavenTheme.pink, modifier = Modifier.clickable { onDismiss() }.padding(8.dp))
        },
    )
}

/** One participant's tile — matches iOS: camera fills, or the brand sunset gradient + their profile
 *  photo centered when the camera's off. Group tiles get rounded corners + a name badge; the 1:1
 *  `fill` tile goes edge-to-edge with no badge. (Active-speaker highlight is TODO — needs audio-level
 *  plumbing on the Android CallManager, which doesn't track it yet.) */
@Composable
private fun CallTile(
    hex: String,
    remote: Map<String, VideoTrack?>,
    fill: Boolean,
    showName: Boolean,
    modifier: Modifier,
) {
    val name = com.blaineam.haven.core.HavenNet.displayName(hex.take(8))
    // Who is talking, so a group call doesn't make you guess. Only in the grid: with one remote
    // there is nobody to disambiguate, and CallManager doesn't even poll for it. Apple parity.
    val speaking = !fill && CallManager.activeSpeaker.value == hex
    val shaped = (if (fill) modifier else modifier.clip(RoundedCornerShape(16.dp)))
        .then(
            if (speaking) Modifier.border(2.dp, HavenTheme.pink, RoundedCornerShape(16.dp))
            else Modifier,
        )
    Box(shaped) {
        if (CallManager.remoteCameraOff.contains(hex)) {
            Box(Modifier.fillMaxSize().background(HavenTheme.brand), contentAlignment = Alignment.Center) {
                Box(Modifier.clip(CircleShape).border(2.dp, Color.White.copy(alpha = 0.25f), CircleShape)) {
                    HavenAvatar(hex.take(8), name, size = if (fill) 110.dp else 78.dp)
                }
            }
        } else {
            CallVideoTile(remote[hex], Modifier.fillMaxSize())
        }
        if (showName) {
            Text(
                name, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1,
                modifier = Modifier.align(Alignment.BottomStart).padding(8.dp)
                    .clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.4f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
        }
    }
}

@Composable
private fun RoundButton(icon: ImageVector, bg: Color, desc: String, enabled: Boolean = true, onClick: () -> Unit) {
    val faded = if (enabled) bg else bg.copy(alpha = 0.4f)
    Box(
        Modifier.size(60.dp).clip(CircleShape).background(faded).clickable(enabled = enabled) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, desc, modifier = Modifier.size(26.dp),
            tint = (if (bg == CallChip) Color.White else Color.Black).copy(alpha = if (enabled) 1f else 0.5f))
    }
}
