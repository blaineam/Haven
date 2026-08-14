package com.blaineam.haven.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.loadAndDownscale
import com.blaineam.haven.core.LocationShare
import com.blaineam.haven.core.MediaVariants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.TrackRefFfi

/**
 * The FULL post editor — text, attachments, song and location. Apple parity: `EditPost.swift`.
 *
 * Android's editor was an inline text field with a Save label beside it, and [HavenNet.editPost]
 * deliberately accepts only a body: it re-reads the post's media and track through `EditCarry` and
 * restates them, precisely so a text editor cannot delete everyone's attachments by forgetting
 * them. That guard is right, and it is why this screen calls [HavenNet.editPostFull] instead —
 * changing the attachments has to be something a caller SAYS, not something it can do by accident.
 *
 * Companion refs are the sharp edge: a video's poster and a photo's thumb name their parent, so
 * removing a tile removes the whole family through [MediaVariants.companionRefs]. Dropping only the
 * parent would leave the array pointing at media the post no longer carries.
 */
@Composable
fun EditPostSheet(item: FeedItemFfi, circleId: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember(item.id) { mutableStateOf(item.body) }
    val media = remember(item.id) { mutableStateListOf<String>().apply { addAll(item.media) } }
    var music by remember(item.id) { mutableStateOf(item.music) }
    var muteVideo by remember(item.id) { mutableStateOf(item.muteVideo) }
    var showMusic by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }

    // Off the main looper: each picked item is a decode→downscale (or a full video transcode), and
    // this callback arrives on the main thread. The composer learned that the hard way.
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) { uris ->
        scope.launch(Dispatchers.IO) {
            uris.forEach { uri ->
                val refs = com.blaineam.haven.core.MediaProcessing.processing {
                    if (com.blaineam.haven.core.isVideoUri(context, uri)) {
                        LocalMedia.prepareVideo(context, uri, circleId).mediaRefs
                    } else {
                        loadAndDownscale(context, uri)?.let { listOf(LocalMedia.store(circleId, it)) }
                            ?: emptyList()
                    }
                }
                media.addAll(refs)
            }
        }
    }

    HavenBackground {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BrandText(stringResource(R.string.edit_post_title), fontSize = 24)
                Spacer(Modifier.weight(1f))
                Text(
                    stringResource(R.string.common_cancel),
                    color = HavenTheme.textSecondary,
                    modifier = Modifier.clickable { onDismiss() }.padding(8.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = text, onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
            )

            if (media.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                LazyRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    // displayRefs, so a poster/thumb companion does not draw a tile of its own.
                    val shown = MediaVariants.displayRefs(media)
                    items(shown.size) { i ->
                        val ref = shown[i]
                        if (LocationShare.isLocation(ref)) {
                            // The location is a synthetic ref rather than a file, and without a tile
                            // of its own there is no way to take a location back off a post.
                            Box {
                                Box(Modifier.size(64.dp).clip(RoundedCornerShape(12.dp)).background(HavenTheme.card),
                                    contentAlignment = Alignment.Center) {
                                    Icon(Icons.Filled.Place, null, tint = HavenTheme.pink, modifier = Modifier.size(26.dp))
                                }
                                Text("✕", color = Color.White, fontSize = 13.sp,
                                    modifier = Modifier.align(Alignment.TopEnd).padding(3.dp).clip(CircleShape)
                                        .background(Color.Black.copy(alpha = 0.6f))
                                        .clickable { media.remove(ref) }
                                        .padding(horizontal = 6.dp, vertical = 1.dp))
                            }
                        } else {
                            ComposerAttachmentTile(circleId, ref, size = 64.dp) {
                                media.removeAll(MediaVariants.companionRefs(ref, media))
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.clickable {
                    picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Photo, null, tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.size(6.dp))
                    Text(stringResource(R.string.edit_post_photos), color = HavenTheme.textPrimary, fontSize = 14.sp)
                }
                Row(Modifier.clickable { showMusic = true }.padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.size(6.dp))
                    Text(
                        stringResource(if (music == null) R.string.edit_post_song else R.string.edit_post_change_song),
                        color = HavenTheme.textPrimary, fontSize = 14.sp,
                    )
                }
                // A song always plays OVER a muted video, so the choice only exists without one.
                if (music == null && media.any { it.startsWith("v:") || it.startsWith("vid_") }) {
                    Row(Modifier.clickable { muteVideo = !muteVideo }.padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (muteVideo) Icons.Filled.VolumeOff else Icons.Filled.VolumeUp, null,
                            tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(
                            stringResource(if (muteVideo) R.string.edit_post_video_muted else R.string.edit_post_video_sound),
                            color = HavenTheme.textPrimary, fontSize = 14.sp,
                        )
                    }
                }
            }

            music?.let { trk ->
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val art = rememberArtwork(trk.artworkUrl)
                    Box(Modifier.size(36.dp).clip(RoundedCornerShape(7.dp)).background(HavenTheme.card),
                        contentAlignment = Alignment.Center) {
                        if (art != null) Image(art, null, Modifier.size(36.dp))
                        else Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.textSecondary)
                    }
                    Spacer(Modifier.size(10.dp))
                    Text("${trk.title} · ${trk.artist}", color = HavenTheme.textSecondary, fontSize = 13.sp,
                        modifier = Modifier.weight(1f), maxLines = 1)
                    Text("✕", color = HavenTheme.textSecondary, fontSize = 15.sp,
                        modifier = Modifier.clickable { music = null }.padding(8.dp))
                }
            }

            Spacer(Modifier.height(18.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Text(
                    stringResource(R.string.common_save),
                    color = if (busy) HavenTheme.textSecondary else HavenTheme.pink,
                    fontWeight = FontWeight.SemiBold, fontSize = 16.sp,
                    modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable(enabled = !busy) {
                        busy = true
                        // editPostFull, not editPost: this screen MEANS to replace the attachments,
                        // and the text-only path exists to stop callers doing that by accident.
                        scope.launch(Dispatchers.IO) {
                            HavenNet.editPostFull(circleId, item.id, text.trim(), media.toList(), music, muteVideo)
                            onDismiss()
                        }
                    }.padding(horizontal = 14.dp, vertical = 8.dp),
                )
            }
        }
    }

    if (showMusic) {
        FullScreenOverlay(onDismiss = { showMusic = false }) {
            MusicSearchSheet(
                onPick = { track -> music = track; showMusic = false },
                onDismiss = { showMusic = false },
                caption = text,
                createdAtMs = item.createdAt.toLong(),
            )
        }
    }
}
