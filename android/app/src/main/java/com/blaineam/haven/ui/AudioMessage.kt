package com.blaineam.haven.ui

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaPlayer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.blaineam.haven.core.AudioRecorder
import com.blaineam.haven.core.LocalMedia
import kotlinx.coroutines.delay

/** A play/pause pill for a received voice message (decrypts the aud_ ref + plays via MediaPlayer).
 *  `contentColor` is the ENCLOSING surface's foreground — the pill rides inside a DM bubble that is
 *  either a pink fill (white content) or a theme card (themed content). */
@Composable
fun AudioPlayerPill(
    circleId: String,
    ref: String,
    modifier: Modifier = Modifier,
    contentColor: Color = HavenTheme.textPrimary,
) {
    var playing by remember(ref) { mutableStateOf(false) }
    val player = remember(ref) { MediaPlayer() }
    val context = LocalContext.current
    val attrs = remember {
        android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
    }
    // Focus now goes through the app-wide coordinator, which supplies the listener this pill never
    // had: it used to TAKE the route and never react to losing it, so a call arriving mid-message
    // left the voice note talking underneath it. `speech = true` asks the system to pause rather
    // than duck — a ducked voice note is just an unintelligible one.
    val holder = remember(ref) {
        object : com.blaineam.haven.core.AudioFocus.Holder {
            override fun onPause() { runCatching { player.pause() }; playing = false }
            override fun onDuck() {}   // speech is never ducked; see above
            override fun onResume() {}  // a half-heard message is restarted by hand, not resumed at us
            override fun onStop() { runCatching { player.pause() }; playing = false }
        }
    }
    DisposableEffect(ref) {
        onDispose {
            runCatching { player.release() }
            com.blaineam.haven.core.AudioFocus.abandon(context, holder)
        }
    }
    androidx.compose.foundation.layout.Row(
        modifier.clip(RoundedCornerShape(20.dp)).background(contentColor.copy(alpha = 0.18f))
            .clickable {
                if (playing) { runCatching { player.pause() }; playing = false }
                else {
                    val f = LocalMedia.audioFile(circleId, ref)
                    if (f != null) runCatching {
                        // Set the media audio attributes + take audio focus BEFORE start, or the clip
                        // played silently (the Android analog of iOS not activating the audio session).
                        player.reset()
                        player.setAudioAttributes(attrs)
                        player.setDataSource(f.absolutePath)
                        player.prepare()
                        // A refusal means something that outranks a voice note is using the route —
                        // don't start on top of it.
                        if (!com.blaineam.haven.core.AudioFocus.request(context, holder, speech = true)) {
                            return@runCatching
                        }
                        // A voice note and a story's song are both Haven making noise; the newer one wins.
                        MusicPlayer.stop()
                        player.start()
                        player.setOnCompletionListener {
                            playing = false
                            com.blaineam.haven.core.AudioFocus.abandon(context, holder)
                        }
                        playing = true
                    }
                }
            }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, stringResource(R.string.audio_play), tint = contentColor, modifier = Modifier.size(20.dp))
        Spacer(Modifier.size(8.dp))
        Text(stringResource(R.string.audio_voice_message), color = contentColor, fontSize = 13.sp)
    }
}

/** A tap-to-record sheet; on Send, stores the clip as an aud_ ref and hands it back. */
@Composable
fun VoiceRecorderDialog(circleId: String, onDone: (String) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val recorder = remember { AudioRecorder(context) }
    var recording by remember { mutableStateOf(false) }
    var elapsed by remember { mutableStateOf(0) }
    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) { recorder.start(); recording = true }
    }
    LaunchedEffect(recording) { while (recording) { delay(1000); elapsed += 1 } }
    AlertDialog(
        onDismissRequest = { recorder.cancel(); onDismiss() },
        confirmButton = {
            TextButton(enabled = recording, onClick = {
                val f = recorder.stop(); recording = false
                if (f != null) onDone(LocalMedia.storeAudio(circleId, f.readBytes())) else onDismiss()
            }) { Text(stringResource(R.string.common_send), color = HavenTheme.pink) }
        },
        dismissButton = { TextButton(onClick = { recorder.cancel(); onDismiss() }) { Text(stringResource(R.string.common_cancel)) } },
        title = { Text(if (recording) stringResource(R.string.audio_recording, elapsed) else stringResource(R.string.audio_voice_message)) },
        text = {
            Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
                Icon(
                    if (recording) Icons.Filled.Stop else Icons.Filled.Mic, stringResource(R.string.audio_record),
                    tint = HavenTheme.pink,
                    modifier = Modifier.size(64.dp).clickable {
                        if (!recording) {
                            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                                recorder.start(); recording = true
                            } else permLauncher.launch(Manifest.permission.RECORD_AUDIO)
                        }
                    },
                )
            }
        },
    )
}
