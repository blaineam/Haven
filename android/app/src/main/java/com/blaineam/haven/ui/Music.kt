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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.MusicSearch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URL
import uniffi.haven_ffi.TrackRefFfi
import com.blaineam.haven.core.SongSuggester
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.foundation.layout.Arrangement

/** Tiny remote-image cache for album artwork (fetch + decode off-main). */
private val artCache = mutableStateMapOf<String, ImageBitmap?>()

@Composable
fun rememberArtwork(raw: String?): ImageBitmap? {
    // TrackRef has no field for a story's chosen section, so Apple encodes it into artworkUrl as
    // "start:<ms>" — and, since suggestions started carrying real artwork, as "start:<ms>;<url>".
    // A URL can neither begin with "start:" nor contain an unescaped ";", so the split is
    // unambiguous. Stripped HERE because every caller goes through this one function: without it a
    // story song authored on an iPhone hands us a string that is not a URL, URL() throws, and the
    // chip silently shows no art.
    val url = raw?.let {
        if (!it.startsWith("start:")) it
        else it.substringAfter(';', "")
    }
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

/**
 * A single shared MediaPlayer so only one 30s preview plays at a time — the chip's preview button,
 * and the song under a story you're watching.
 *
 * Holds real audio focus (see [com.blaineam.haven.core.AudioFocus]) rather than only consulting
 * Haven's own state: a phone call or another app's playback now pauses the song and gives it back,
 * and a refused request means it never starts at all.
 */
object MusicPlayer : com.blaineam.haven.core.AudioFocus.Holder {
    private var player: MediaPlayer? = null
    var playingUrl by mutableStateOf<String?>(null)
        private set

    /** The app context, kept so a focus callback can abandon without a composable in scope. */
    private var appContext: android.content.Context? = null

    /** Paused by focus loss (as opposed to by the user holding a story) — resume on regain. */
    private var pausedByFocus = false

    /** Paused because the viewer is holding the story still. Survives focus events independently. */
    private var pausedByUser = false

    private var ducked = false

    /** Full while we own the route outright, low while ducked under a notification. */
    private fun applyVolume() {
        val v = if (ducked) 0.2f else 1f
        runCatching { player?.setVolume(v, v) }
    }

    private fun resumeIfClear() {
        if (pausedByFocus || pausedByUser) return
        runCatching { player?.start() }
    }

    override fun onPause() { pausedByFocus = true; runCatching { player?.pause() } }

    override fun onDuck() { ducked = true; applyVolume() }

    override fun onResume() {
        ducked = false; applyVolume()
        pausedByFocus = false
        resumeIfClear()
    }

    override fun onStop() = stop()

    /**
     * Hold the song still while the viewer holds the story still, and let it go when they do.
     * Separate from focus pausing so releasing a hold during a phone call doesn't restart the song.
     */
    fun setUserPaused(paused: Boolean) {
        if (pausedByUser == paused) return
        pausedByUser = paused
        if (paused) runCatching { player?.pause() } else resumeIfClear()
    }

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

    /** The chip's play/pause button: start [url], or stop it if it's the one already playing. */
    fun toggle(context: android.content.Context, url: String) {
        if (playingUrl == url) { stop(); return }
        play(context, url)
    }

    /**
     * Start [url], replacing whatever was playing. A no-op if [url] is already the one playing, so a
     * story that carries the same song as the one before it plays straight through instead of
     * restarting on every advance.
     */
    fun play(context: android.content.Context, url: String) {
        if (playingUrl == url) return
        stop()
        // Call audio priority: never start a song preview while a call is ringing/connecting/live.
        if (com.blaineam.haven.core.CallManager.callInProgress) return
        if (cameraOpen) return   // a viewfinder owns the audio route while it's up
        appContext = context.applicationContext
        // Ask the SYSTEM, not just ourselves. A refusal here is what keeps a story's song off the
        // top of a call or another app's playback, and it must precede start().
        if (!com.blaineam.haven.core.AudioFocus.request(context, this)) return
        pausedByFocus = false; pausedByUser = false; ducked = false
        runCatching {
            player = MediaPlayer().apply {
                setDataSource(url)
                setOnCompletionListener { stop() }
                setOnPreparedListener {
                    applyVolume()
                    // A focus change can land between the request and prepare finishing; honour it
                    // rather than starting into a call that arrived while we were buffering.
                    resumeIfClear()
                }
                prepareAsync()
            }
            playingUrl = url
        }.onFailure { stop() }
    }

    fun stop() {
        runCatching { player?.release() }
        player = null
        playingUrl = null
        pausedByFocus = false; pausedByUser = false; ducked = false
        appContext?.let { com.blaineam.haven.core.AudioFocus.abandon(it, this) }
    }
}

/** Search-and-pick a song (iTunes Search), with a SUGGESTED tab driven by what the post says.
 *
 *  [caption] is the post being composed or edited. `SongSuggester` has existed here since the
 *  importer needed it — scoring hundreds of silent posts on caption + date — and the picker never
 *  offered it, so the only way to reach a song was to already know its name. Apple has had the tab
 *  for a while; this is parity, not a new capability, and it runs on the same free iTunes source
 *  both platforms search, so a song picked here is the same TrackRef a phone would attach.
 *
 *  [createdAtMs] lets an EDIT suggest for when the post was actually taken rather than for today —
 *  which matters most for imported posts, where those are years apart.
 */
@Composable
fun MusicSearchSheet(
    onPick: (TrackRefFfi) -> Unit,
    onDismiss: () -> Unit,
    caption: String = "",
    createdAtMs: Long? = null,
) {
    val sheetContext = LocalContext.current
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<MusicSearch.Track>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var suggestTab by remember { mutableStateOf(false) }
    var suggestions by remember { mutableStateOf<List<TrackRefFfi>>(emptyList()) }
    var suggesting by remember { mutableStateOf(false) }

    // Only when the tab is actually opened: this is a handful of network searches, and paying for
    // them on every composer open — when most posts get no song at all — would be rude.
    LaunchedEffect(suggestTab) {
        if (!suggestTab || suggestions.isNotEmpty()) return@LaunchedEffect
        suggesting = true
        suggestions = withContext(Dispatchers.IO) {
            val themes = SongSuggester.captionThemes(caption, 2)
            val (year, month) = SongSuggester.yearMonth(createdAtMs ?: System.currentTimeMillis())
            SongSuggester.suggestions(themes, null, year, month, emptySet(), limit = 12)
        }
        suggesting = false
    }

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
                BrandText(stringResource(R.string.music_add_song_title), fontSize = 24)
                Spacer(Modifier.weight(1f))
                Text(stringResource(R.string.common_done), color = HavenTheme.textSecondary, modifier = Modifier.clickable { onDismiss() }.padding(8.dp))
            }
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(false to R.string.music_tab_search, true to R.string.music_tab_suggested).forEach { (isSuggest, label) ->
                    val on = suggestTab == isSuggest
                    Text(
                        stringResource(label),
                        color = if (on) HavenTheme.textPrimary else HavenTheme.textSecondary,
                        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                        fontSize = 14.sp,
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (on) HavenTheme.card else androidx.compose.ui.graphics.Color.Transparent)
                            .clickable { suggestTab = isSuggest }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            if (suggestTab) {
                if (suggesting) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), color = HavenTheme.pink, strokeWidth = 2.dp)
                        Spacer(Modifier.size(10.dp))
                        Text(stringResource(R.string.music_finding_songs), color = HavenTheme.textSecondary, fontSize = 13.sp)
                    }
                } else if (suggestions.isEmpty()) {
                    Text(stringResource(R.string.music_no_suggestions), color = HavenTheme.textSecondary, fontSize = 13.sp)
                } else {
                    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 460.dp)) {
                        items(suggestions) { trk ->
                            Row(
                                Modifier.fillMaxWidth().clickable { MusicPlayer.stop(); onPick(trk) }
                                    .padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                val art = rememberArtwork(trk.artworkUrl)
                                Box(Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)).background(HavenTheme.card),
                                    contentAlignment = Alignment.Center) {
                                    if (art != null) Image(art, null, Modifier.size(48.dp), contentScale = ContentScale.Crop)
                                    else Icon(Icons.Filled.MusicNote, null, tint = HavenTheme.textSecondary)
                                }
                                Spacer(Modifier.size(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(trk.title, color = HavenTheme.textPrimary, fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium, maxLines = 1)
                                    Text(trk.artist, color = HavenTheme.textSecondary, fontSize = 12.sp, maxLines = 1)
                                }
                            }
                        }
                    }
                }
                return@Column
            }
            OutlinedTextField(
                value = query, onValueChange = { query = it },
                placeholder = { Text(stringResource(R.string.music_search_placeholder)) }, singleLine = true,
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
                            stringResource(R.string.music_cd_preview), tint = HavenTheme.pink,
                            modifier = Modifier.size(34.dp).clickable { MusicPlayer.toggle(sheetContext, t.previewUrl) },
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
        Text(stringResource(R.string.music_listen_on), color = HavenTheme.pink, fontSize = 11.sp,
            modifier = Modifier.clickable { open = true })
        androidx.compose.material3.DropdownMenu(
            expanded = open, onDismissRequest = { open = false },
            modifier = Modifier.background(HavenTheme.card),
        ) {
            val apple = if (music.catalogId.startsWith("http")) music.catalogId
                else "https://music.apple.com/search?term=$q"
            ProviderItem(stringResource(R.string.music_apple_music)) { openExternal(context, apple); open = false }
            ProviderItem(stringResource(R.string.music_spotify)) { openExternal(context, "https://open.spotify.com/search/$q"); open = false }
            ProviderItem(stringResource(R.string.music_youtube_music)) { openExternal(context, "https://music.youtube.com/search?q=$q"); open = false }
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
                stringResource(R.string.music_cd_play_preview), tint = HavenTheme.pink,
                modifier = Modifier.size(38.dp).clickable { MusicPlayer.toggle(context, previewUrl) },
            )
        }
    }
}
