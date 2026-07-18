package com.blaineam.haven.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.blaineam.haven.core.DEFAULT_CIRCLE
import com.blaineam.haven.core.FilterSpec
import com.blaineam.haven.core.GlPhotoFilter
import com.blaineam.haven.core.HavenFilter
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.VideoFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

// The WIRE palette/typography (StoryCaptions) — indexes ride the encoded caption, so the picker
// must use the same tables as every viewer on every platform.
private val capColors = StoryCaptions.colors
private val fontFamilies = StoryCaptions.fontFamilies
private fun typefaceFor(i: Int): Typeface = when (i % fontFamilies.size) {
    1 -> Typeface.create(Typeface.SERIF, Typeface.BOLD)
    2 -> Typeface.create("cursive", Typeface.BOLD)
    3 -> Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    4 -> Typeface.create(Typeface.DEFAULT_BOLD, Typeface.BOLD)
    else -> Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
}

/** iOS-style caption looks. */
private enum class CapStyle(val label: String) { PLAIN("Plain"), SHADOW("Shadow"), GLOW("Glow"), NEON("Neon"), HIGHLIGHT("Mark") }

/** Black text on light colors, white on dark — so highlighted text is always legible. */
private fun contrastOn(c: Color): Color =
    if (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.6) Color.Black else Color.White

private data class LiveCap(val textColor: Color, val shadow: Shadow?, val bg: Color)
private fun liveCap(style: CapStyle, color: Color): LiveCap = when (style) {
    CapStyle.PLAIN -> LiveCap(color, Shadow(Color.Black.copy(alpha = 0.55f), Offset(0f, 2f), 8f), Color.Transparent)
    CapStyle.SHADOW -> LiveCap(color, Shadow(Color.Black.copy(alpha = 0.85f), Offset(4f, 4f), 2f), Color.Transparent)
    CapStyle.GLOW -> LiveCap(color, Shadow(color.copy(alpha = 0.95f), Offset(0f, 0f), 22f), Color.Transparent)
    CapStyle.NEON -> LiveCap(Color.White, Shadow(color, Offset(0f, 0f), 28f), Color.Transparent)
    CapStyle.HIGHLIGHT -> LiveCap(contrastOn(color), null, color)
}

/**
 * iOS-style story editor: the 11-filter set (incl. Kodak Gold) on photos AND videos, a styled caption
 * (color · plain/shadow/glow/neon/highlight · font · size · drag), and a clean control stack so nothing
 * overlaps. Photos preview through the real GLSL filter; video autoplays (no chrome) and the filter is
 * baked on share. Filter + styled caption are baked into the bytes so recipients see the exact look.
 */
@Composable
fun StoryEditor(ref: String, isVideo: Boolean, initialFilter: Int = 0, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var caption by remember { mutableStateOf("") }
    var music by remember { mutableStateOf<uniffi.haven_ffi.TrackRefFfi?>(null) }
    var pickSong by remember { mutableStateOf(false) }
    var capOffset by remember { mutableStateOf(Offset.Zero) }
    var colorIdx by remember { mutableStateOf(0) }
    var styleIdx by remember { mutableStateOf(0) }
    var fontIdx by remember { mutableStateOf(0) }
    var sizeSp by remember { mutableStateOf(30f) }
    var filterIdx by remember { mutableStateOf(initialFilter.coerceIn(0, HavenFilter.all.size - 1)) }
    var showColors by remember { mutableStateOf(false) }
    // Preview sound for the clip itself. A song and the clip's own audio can't share the preview, so
    // attaching a song silences the clip (the song is what a viewer will hear anyway) and removing the
    // song hands the clip its audio back — the toggle just says whether the author wants to hear it.
    // Off by default, matching iOS and desktop: opening the editor should never suddenly blare. The
    // clip was silent here before, so defaulting this on would have changed existing behaviour.
    var previewSound by remember { mutableStateOf(false) }
    var boxSize by remember { mutableStateOf(IntSize.Zero) }
    var sharing by remember { mutableStateOf(false) }
    var shareLabel by remember { mutableStateOf("Share to story") }
    // Pinch-zoom + drag to position the media within the story frame (baked into the share).
    var mediaScale by remember { mutableStateOf(1f) }
    var mediaOffset by remember { mutableStateOf(Offset.Zero) }
    val mediaTransform = rememberTransformableState { zoom, pan, _ ->
        mediaScale = (mediaScale * zoom).coerceIn(1f, 5f)
        mediaOffset += pan
    }

    val filter = HavenFilter.all[filterIdx]
    val style = CapStyle.entries[styleIdx % CapStyle.entries.size]
    val capColor = capColors[colorIdx % capColors.size]
    val lc = liveCap(style, capColor)

    // Source bitmap (photos) for filter preview + baking.
    var srcBmp by remember(ref) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(ref) {
        if (!isVideo) srcBmp = withContext(Dispatchers.IO) {
            LocalMedia.load(DEFAULT_CIRCLE, ref)?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() }
        }
    }
    // Live GL-filtered photo preview (recomputed when filter/source changes).
    var previewBmp by remember(ref) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(srcBmp, filterIdx) {
        val s = srcBmp ?: return@LaunchedEffect
        previewBmp = if (filter == HavenFilter.ORIGINAL) s
        else withContext(Dispatchers.Default) { runCatching { GlPhotoFilter.apply(s, filter.spec) }.getOrDefault(s) }
    }

    if (pickSong) {
        MusicSearchSheet(onPick = { music = it; pickSong = false }, onDismiss = { pickSong = false })
        return
    }

    Box(Modifier.fillMaxSize().background(Color.Black).onSizeChanged { boxSize = it }) {
        // ── Media (photo + video both preview the live filter) — pinch to zoom, drag to position;
        //    aspect-FILLS the frame (no squish/letterbox), and the transform is baked on share. ───
        Box(Modifier.fillMaxSize().transformable(mediaTransform)) {
            val mediaMod = Modifier.fillMaxSize().graphicsLayer(
                scaleX = mediaScale, scaleY = mediaScale,
                translationX = mediaOffset.x, translationY = mediaOffset.y,
            )
            if (isVideo) EditorVideo(ref, filter.spec, muted = music != null || !previewSound, mediaMod)
            else previewBmp?.let { Image(it.asImageBitmap(), "Story", mediaMod, contentScale = ContentScale.Crop) }
        }

        // ── Caption (lifts above the keyboard via imePadding) ──────────────────────────────
        Box(Modifier.fillMaxSize().imePadding()) {
            Box(
                Modifier.align(Alignment.Center)
                    .offset { IntOffset(capOffset.x.toInt(), capOffset.y.toInt()) }
                    .pointerInput(Unit) { detectDragGestures { _, drag -> capOffset += drag } }
                    .padding(horizontal = 24.dp),
            ) {
                BasicTextField(
                    value = caption, onValueChange = { caption = it },
                    textStyle = TextStyle(color = lc.textColor, fontSize = sizeSp.sp,
                        fontWeight = StoryCaptions.fontWeight(fontIdx % fontFamilies.size),
                        fontFamily = fontFamilies[fontIdx % fontFamilies.size], textAlign = TextAlign.Center, shadow = lc.shadow),
                    cursorBrush = SolidColor(HavenTheme.pink),
                    modifier = Modifier.wrapContentWidth().background(lc.bg, RoundedCornerShape(8.dp))
                        .padding(horizontal = if (lc.bg == Color.Transparent) 0.dp else 12.dp, vertical = if (lc.bg == Color.Transparent) 0.dp else 5.dp),
                    decorationBox = { inner ->
                        if (caption.isEmpty()) Text("Tap to type", color = Color.White.copy(alpha = 0.65f), fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        inner()
                    },
                )
            }
        }

        // ── Top bar: close + caption controls ──────────────────────────────────────────────
        Row(Modifier.align(Alignment.TopStart).statusBarsPadding().fillMaxWidth().padding(10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            CtlButton({ onClose() }) { Icon(Icons.Filled.Close, "Close", tint = Color.White) }
            // Preview sound — only meaningful for a clip with no song attached; once there IS a song the
            // clip is silenced either way, so the control would be a lie.
            if (isVideo && music == null) {
                Spacer(Modifier.size(8.dp))
                CtlButton({ previewSound = !previewSound }) {
                    Icon(
                        if (previewSound) Icons.AutoMirrored.Filled.VolumeUp else Icons.AutoMirrored.Filled.VolumeOff,
                        if (previewSound) "Mute preview" else "Unmute preview", tint = Color.White,
                    )
                }
            }
            Spacer(Modifier.weight(1f))
            CtlButton({ showColors = !showColors }) {
                Box(Modifier.size(22.dp).clip(CircleShape).background(capColor).border(1.5.dp, Color.White, CircleShape))
            }
            Spacer(Modifier.size(8.dp))
            // Style cycle — the "Aa" is drawn in the current style as a live hint.
            CtlButton({ styleIdx++ }) {
                Text("Aa", color = if (style == CapStyle.HIGHLIGHT) capColor else lc.textColor, fontWeight = FontWeight.Bold,
                    fontSize = 15.sp)
            }
            Spacer(Modifier.size(8.dp))
            CtlButton({ fontIdx++ }) { Text("Ag", color = Color.White, fontWeight = FontWeight.Bold, fontFamily = fontFamilies[fontIdx % fontFamilies.size]) }
            Spacer(Modifier.size(8.dp))
            CtlButton({ sizeSp = (sizeSp - 4f).coerceAtLeast(16f) }) { Text("A−", color = Color.White, fontSize = 13.sp) }
            Spacer(Modifier.size(8.dp))
            CtlButton({ sizeSp = (sizeSp + 4f).coerceAtMost(60f) }) { Text("A+", color = Color.White, fontSize = 15.sp) }
        }

        // Color swatches + the current style name (toggled under the top bar).
        if (showColors) {
            Column(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 60.dp, end = 10.dp),
                horizontalAlignment = Alignment.End) {
                Row(Modifier.clip(RoundedCornerShape(20.dp)).background(Color.Black.copy(alpha = 0.55f)).padding(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    capColors.forEachIndexed { i, c ->
                        Box(Modifier.size(26.dp).clip(CircleShape).background(c)
                            .border(if (i == colorIdx) 2.5.dp else 1.dp, Color.White.copy(alpha = if (i == colorIdx) 1f else 0.3f), CircleShape)
                            .clickable { colorIdx = i })
                    }
                }
                Spacer(Modifier.size(6.dp))
                Text(style.label, color = Color.White, fontSize = 12.sp,
                    modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 10.dp, vertical = 4.dp))
            }
        }

        // ── Bottom control stack: filter strip ABOVE the action row (no overlap) ───────────
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 24.dp)) {
            LazyRow(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(HavenFilter.all.size, key = { HavenFilter.all[it].name }) { i ->
                    val f = HavenFilter.all[i]
                    Text(f.title, color = Color.White, fontSize = 13.sp,
                        fontWeight = if (i == filterIdx) FontWeight.Bold else FontWeight.Normal,
                        modifier = Modifier.clip(RoundedCornerShape(16.dp))
                            .background(if (i == filterIdx) HavenTheme.pink else Color.Black.copy(alpha = 0.4f))
                            .clickable { filterIdx = i }.padding(horizontal = 14.dp, vertical = 8.dp))
                }
            }
            music?.let { m -> Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) { MusicChip(m) } }
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Row(Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.18f)).clickable { pickSong = true }
                    .padding(horizontal = 16.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.MusicNote, null, tint = Color.White, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text(if (music == null) "Music" else "Change", color = Color.White, fontSize = 14.sp)
                }
                Text(if (sharing) shareLabel else "Share to story", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(CircleShape).background(HavenTheme.brandHorizontal)
                        .clickable(enabled = !sharing) {
                            sharing = true
                            scope.launch {
                                // Resilient: a throw anywhere here (e.g. an OOM baking the photo or
                                // transcoding the video) used to leave `sharing=true` with onClose()
                                // never reached — an infinite spinner and no story. Always release the
                                // spinner; only close on success, else show an error so the user retries.
                                val ok = runCatching {
                                    if (isVideo) {
                                        shareLabel = "Applying filter…"
                                        val newRef = withContext(Dispatchers.IO) {
                                            val inFile = LocalMedia.videoFile(DEFAULT_CIRCLE, ref)
                                            if (inFile == null) ref else {
                                                val out = VideoFilter.transcode(context, inFile, filter.spec) { shareLabel = "Applying filter… ${(it * 100).toInt()}%" }
                                                if (out.absolutePath == inFile.absolutePath) ref
                                                else runCatching { LocalMedia.store(DEFAULT_CIRCLE, out.readBytes(), isVideo = true) }.getOrNull() ?: ref
                                            }
                                        }
                                        // Transcode is filter-only — a video's zoom/pan can't be baked
                                        // like a photo's, so the framing rides the wire fields instead
                                        // (viewers apply it, matching iOS).
                                        HavenNet.postStory(encodedCaption(caption, colorIdx, fontIdx, style, capOffset, boxSize, sizeSp, mediaScale, mediaOffset), newRef, music)
                                    } else {
                                        // Filter + the author's zoom/pan are pixel operations and stay
                                        // baked; the CAPTION rides the wire format instead (parity with
                                        // iOS/desktop) so every platform renders it live + identically.
                                        val baked = withContext(Dispatchers.IO) {
                                            bakePhoto(srcBmp, filter.spec, "", capColor, style, fontIdx, sizeSp, capOffset, boxSize, mediaScale, mediaOffset)
                                        }
                                        HavenNet.postStory(encodedCaption(caption, colorIdx, fontIdx, style, capOffset, boxSize, sizeSp), baked ?: ref, music)
                                    }
                                }.onFailure { android.util.Log.e("StoryEditor", "share to story failed", it) }.isSuccess
                                sharing = false
                                if (ok) onClose() else shareLabel = "Couldn't share — try again"
                            }
                        }.padding(horizontal = 26.dp, vertical = 13.dp))
            }
        }
    }
}

/** Live filter-applied, autoplaying, looping, chrome-free video preview. [muted] silences the clip's
 *  OWN audio without restarting it, so the loop survives a song being attached or removed. */
@Composable
private fun EditorVideo(ref: String, spec: FilterSpec, muted: Boolean, modifier: Modifier) {
    val file = remember(ref) { LocalMedia.videoFile(DEFAULT_CIRCLE, ref) }
    if (file == null) { Box(modifier.background(Color.Black)); return }
    AndroidView(
        modifier = modifier,
        factory = { ctx -> FilteredVideoView(ctx).also { it.setMuted(muted); it.play(file); it.setFilter(spec) } },
        update = { it.setFilter(spec); it.setMuted(muted) },
        onRelease = { it.release() },
    )
}

@Composable
private fun CtlButton(onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.42f)).clickable { onClick() },
        contentAlignment = Alignment.Center) { content() }
}

/**
 * Bake the GL filter, the user's media zoom/pan, and the styled caption into a story-frame-sized
 * photo (matching the on-screen frame's aspect, ~1080 wide) so the recipient sees the exact composition.
 * Returns the stored ref (or null on failure).
 */
private fun bakePhoto(
    srcBmp: Bitmap?, spec: FilterSpec, caption: String, capColor: Color, style: CapStyle,
    fontIdx: Int, sizeSp: Float, capOffset: Offset, boxSize: IntSize,
    mediaScale: Float, mediaOffset: Offset,
): String? {
    val src = srcBmp ?: return null
    if (boxSize.width <= 0 || boxSize.height <= 0) return null
    return runCatching {
        val filtered = GlPhotoFilter.apply(src, spec)
        val outW = 1080
        val outH = (outW.toFloat() * boxSize.height / boxSize.width).toInt().coerceAtLeast(1)
        val s = outW.toFloat() / boxSize.width   // on-screen px → output px
        val out = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(android.graphics.Color.BLACK)
        // Media: cover-fill the frame (matches ContentScale.Crop), then the user's pinch-zoom + pan.
        val m = maxOf(outW.toFloat() / filtered.width, outH.toFloat() / filtered.height) * mediaScale
        val drawW = filtered.width * m
        val drawH = filtered.height * m
        val left = outW / 2f - drawW / 2f + mediaOffset.x * s
        val top = outH / 2f - drawH / 2f + mediaOffset.y * s
        canvas.drawBitmap(filtered, null, android.graphics.RectF(left, top, left + drawW, top + drawH),
            Paint(Paint.FILTER_BITMAP_FLAG))
        // Caption (positions + size map from on-screen px via s).
        if (caption.isNotBlank()) {
            val textColor = if (style == CapStyle.NEON) android.graphics.Color.WHITE
                else if (style == CapStyle.HIGHLIGHT) contrastOn(capColor).toArgb() else capColor.toArgb()
            val tp = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = textColor; typeface = typefaceFor(fontIdx); textSize = sizeSp * 2.2f * s; textAlign = Paint.Align.CENTER
                when (style) {
                    CapStyle.PLAIN -> setShadowLayer(8f * s, 0f, 2f * s, android.graphics.Color.argb(140, 0, 0, 0))
                    CapStyle.SHADOW -> setShadowLayer(3f * s, 4f * s, 4f * s, android.graphics.Color.argb(220, 0, 0, 0))
                    CapStyle.GLOW -> setShadowLayer(22f * s, 0f, 0f, capColor.toArgb())
                    CapStyle.NEON -> setShadowLayer(28f * s, 0f, 0f, capColor.toArgb())
                    CapStyle.HIGHLIGHT -> {}
                }
            }
            val cx = outW / 2f + capOffset.x * s
            val cy = outH / 2f + capOffset.y * s
            val lines = caption.split("\n")
            val lh = tp.fontMetrics.let { it.descent - it.ascent } * 1.15f
            var y = cy - (lines.size - 1) * lh / 2f
            lines.forEach { line ->
                if (style == CapStyle.HIGHLIGHT) {
                    val w = tp.measureText(line)
                    val hp = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = capColor.toArgb() }
                    val pad = 18f * s
                    canvas.drawRoundRect(cx - w / 2 - pad, y + tp.fontMetrics.ascent - 8f * s,
                        cx + w / 2 + pad, y + tp.fontMetrics.descent + 8f * s, 16f * s, 16f * s, hp)
                }
                canvas.drawText(line, cx, y, tp)
                y += lh
            }
        }
        val bytes = ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
        LocalMedia.store(DEFAULT_CIRCLE, bytes)
    }.getOrNull()
}

/** Map the editor's on-screen caption state to the normalized wire format (see StoryCaptions):
 *  position = fraction of the preview box from its top-left (drag offset is from center),
 *  size = multiplier on the 28-unit cross-platform base. Media framing (video only — photos bake
 *  it into pixels and send the identity defaults): scale as-is, pan normalized to the box the same
 *  way iOS does (offset px ÷ container size), since the editor's graphicsLayer translation and
 *  iOS's .offset() are both unscaled container-space px. */
private fun encodedCaption(
    caption: String, colorIdx: Int, fontIdx: Int, style: CapStyle,
    capOffset: Offset, boxSize: IntSize, sizeSp: Float,
    mediaScale: Float = 1f, mediaOffset: Offset = Offset.Zero,
): String {
    val wireStyle = when (style) {
        CapStyle.PLAIN -> StoryCaptions.CapStyle.PLAIN
        CapStyle.SHADOW -> StoryCaptions.CapStyle.SHADOW
        CapStyle.GLOW -> StoryCaptions.CapStyle.GLOW
        CapStyle.NEON -> StoryCaptions.CapStyle.NEON
        CapStyle.HIGHLIGHT -> StoryCaptions.CapStyle.HIGHLIGHT
    }
    val x = if (boxSize.width > 0) (0.5f + capOffset.x / boxSize.width) else 0.5f
    val y = if (boxSize.height > 0) (0.5f + capOffset.y / boxSize.height) else 0.5f
    return StoryCaptions.encode(
        caption, colorIdx % StoryCaptions.colors.size, fontIdx % StoryCaptions.fontFamilies.size, wireStyle,
        x = x.coerceIn(0f, 1f), y = y.coerceIn(0f, 1f),
        size = (sizeSp / 28f).coerceIn(0.6f, 1.9f),
        mediaScale = mediaScale,
        mediaOffX = if (boxSize.width > 0) mediaOffset.x / boxSize.width else 0f,
        mediaOffY = if (boxSize.height > 0) mediaOffset.y / boxSize.height else 0f,
    )
}
