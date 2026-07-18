package com.blaineam.haven.ui

import android.graphics.BitmapFactory
import android.media.MediaPlayer
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.MusicSearch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URL
import uniffi.haven_ffi.TrackRefFfi

/** Tiny remote-image cache for album artwork (fetch + decode off-main). */
private val artCache = mutableStateMapOf<String, ImageBitmap?>()

@Composable
fun rememberArtwork(url: String?): ImageBitmap? {
    if (url.isNullOrBlank()) return null
    var bmp by remember(url) { mutableStateOf(artCache[url]) }
    LaunchedEffect(url) {
        if (artCache.containsKey(url)) { bmp = artCache[url]; return@LaunchedEffect }
        val b = withContext(Dispatchers.IO) {
            runCatching { URL(url).openStream().use { BitmapFactory.decodeStream(it) }?.asImageBitmap() }.getOrNull()
        }
        artCache[url] = b; bmp = b
    }
    return bmp
}

/** A single shared MediaPlayer so only one 30s preview plays at a time. */
object MusicPlayer {
    private var player: MediaPlayer? = null
    var playingUrl by mutableStateOf<String?>(null)
        private set

    /** How many viewfinders are currently on screen. A camera and a song preview both want the audio
     *  route, and a recording that picks up the song playing beside it bakes it into the clip — so a
     *  song must not start while any camera UI is up, and opening one stops what's playing. Counted
     *  rather than a flag: a camera can be replaced by another (flip to the post camera) without the
     *  first one's teardown clearing the second one's claim. */
    private var cameraSessions = 0
    val cameraOpen: Boolean get() = cameraSessions > 0

    /** A viewfinder appeared: stop the song outright (not pause — nothing may resume it behind the
     *  camera) and hold the block until [endCameraSession]. */
    fun beginCameraSession() { cameraSessions++; stop() }
    fun endCameraSession() { if (cameraSessions > 0) cameraSessions-- }

    fun toggle(url: String) {
        if (playingUrl == url) { stop(); return }
        stop()
        // Call audio priority: never start a song preview while a call is ringing/connecting/live.
        if (com.blaineam.haven.core.CallManager.callInProgress) return
        if (cameraOpen) return   // a viewfinder owns the audio route while it's up
        runCatching {
            player = MediaPlayer().apply {
                setDataSource(url)
                setOnCompletionListener { stop() }
                setOnPreparedListener { start() }
                prepareAsync()
            }
            playingUrl = url
        }
    }

    fun stop() {
        runCatching { player?.release() }
        player = null
        playingUrl = null
    }
}

/** Search-and-pick a song (iTunes Search). Replaces the old paste-a-link dialog. */
@Composable
fun MusicSearchSheet(onPick: (TrackRefFfi) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<MusicSearch.Track>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }

    LaunchedEffect(query) {
        if (query.isBlank()) { results = emptyList(); return@LaunchedEffect }
        kotlinx.coroutines.delay(350)   // debounce
        searching = true
        results = withContext(Dispatchers.IO) { MusicSearch.search(query) }
        searching = false
    }

    HavenBackground {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BrandText("Add a song", fontSize = 24)
                Spacer(Modifier.weight(1f))
                Text("Done", color = HavenTheme.textSecondary, modifier = Modifier.clickable { onDismiss() }.padding(8.dp))
            }
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = query, onValueChange = { query = it },
                placeholder = { Text("Search songs…") }, singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
            )
            Spacer(Modifier.height(12.dp))
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                items(results) { t ->
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            MusicPlayer.stop()
                            onPick(TrackRefFfi(
                                catalogId = t.storeUrl, title = t.title, artist = t.artist,
                                artworkUrl = t.artworkUrl, durationMs = t.durationMs.toULong()))
                        }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val art = rememberArtwork(t.artworkUrl)
                        Box(Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)).background(HavenTheme.card),
                            contentAlignment = Alignment.Center) {
                            if (art != null) Image(art, null, Modifier.size(48.dp), contentScale = ContentScale.Crop)
                            else Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.textSecondary)
                        }
                        Spacer(Modifier.size(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(t.title, color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                            Text(t.artist, color = HavenTheme.textSecondary, fontSize = 12.sp, maxLines = 1)
                        }
                        val isPlaying = MusicPlayer.playingUrl == t.previewUrl
                        Icon(
                            if (isPlaying) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                            "Preview", tint = HavenTheme.pink,
                            modifier = Modifier.size(34.dp).clickable { MusicPlayer.toggle(t.previewUrl) },
                        )
                    }
                }
            }
        }
    }
}

/** "Listen on ▾" — opens the song in the user's preferred provider app (Apple Music / Spotify /
 *  YouTube Music). Apple uses the exact store link; the others open a search for title+artist. */
@Composable
private fun ListenOnMenu(music: TrackRefFfi) {
    val context = LocalContext.current
    var open by remember { mutableStateOf(false) }
    val q = remember(music.title, music.artist) {
        java.net.URLEncoder.encode("${music.title} ${music.artist}".trim(), "UTF-8")
    }
    Box {
        Text("Listen on ▾", color = HavenTheme.pink, fontSize = 11.sp,
            modifier = Modifier.clickable { open = true })
        androidx.compose.material3.DropdownMenu(
            expanded = open, onDismissRequest = { open = false },
            modifier = Modifier.background(HavenTheme.card),
        ) {
            val apple = if (music.catalogId.startsWith("http")) music.catalogId
                else "https://music.apple.com/search?term=$q"
            ProviderItem("Apple Music") { openExternal(context, apple); open = false }
            ProviderItem("Spotify") { openExternal(context, "https://open.spotify.com/search/$q"); open = false }
            ProviderItem("YouTube Music") { openExternal(context, "https://music.youtube.com/search?q=$q"); open = false }
        }
    }
}

@Composable
private fun ProviderItem(label: String, onClick: () -> Unit) {
    androidx.compose.material3.DropdownMenuItem(
        text = { Text(label, color = HavenTheme.textPrimary) },
        onClick = onClick,
    )
}

/** The song chip in the feed: artwork + title/artist, a play button (30s preview), open-in-store. */
@Composable
fun MusicChip(music: TrackRefFfi, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var preview by remember(music.title, music.artist) { mutableStateOf<MusicSearch.Track?>(null) }
    LaunchedEffect(music.title, music.artist) {
        preview = withContext(Dispatchers.IO) { MusicSearch.resolve(music.title, music.artist) }
    }
    val art = rememberArtwork(music.artworkUrl.ifBlank { preview?.artworkUrl })
    val previewUrl = preview?.previewUrl
    val isPlaying = previewUrl != null && MusicPlayer.playingUrl == previewUrl

    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(HavenTheme.background).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)).background(HavenTheme.card),
            contentAlignment = Alignment.Center) {
            if (art != null) Image(art, null, Modifier.size(44.dp), contentScale = ContentScale.Crop)
            else Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.pink)
        }
        Spacer(Modifier.size(10.dp))
        Column(Modifier.weight(1f)) {
            Text(music.title, color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
            if (music.artist.isNotBlank())
                Text(music.artist, color = HavenTheme.textSecondary, fontSize = 12.sp, maxLines = 1)
            ListenOnMenu(music)
        }
        if (previewUrl != null) {
            Icon(
                if (isPlaying) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                "Play preview", tint = HavenTheme.pink,
                modifier = Modifier.size(38.dp).clickable { MusicPlayer.toggle(previewUrl) },
            )
        }
    }
}
