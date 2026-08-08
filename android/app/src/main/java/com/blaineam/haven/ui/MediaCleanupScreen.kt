package com.blaineam.haven.ui

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.PinnedMediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The size-sorted storage manager (Settings ▸ Storage ▸ Manage media). Every cached photo/video/audio
 * blob, largest first, each mapped to the post/DM it belongs to (or flagged Unused). Multi-select to
 * free space; per-item "Keep on this device" pins a blob so no cleanup ever removes it. Deleting frees
 * only the LOCAL bytes — the post stays and re-renders as a downloadable placeholder. Mirrors iOS
 * `MediaCleanupView`.
 */
@Composable
fun MediaCleanupScreen() {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    // Observe pins so a toggle recomposes the "Kept" state without a full re-measure.
    PinnedMediaStore.refs.size
    var rows by remember { mutableStateOf<List<HavenNet.MediaInventoryRow>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    val selection = remember { mutableStateListOf<String>() }
    var reloadTick by remember { mutableStateOf(0) }

    LaunchedEffect(reloadTick) {
        loading = true
        val fresh = withContext(Dispatchers.IO) { runCatching { HavenNet.mediaInventory() }.getOrDefault(emptyList()) }
        rows = fresh
        val present = fresh.map { it.key }.toSet()
        selection.retainAll { it in present }
        loading = false
    }

    val totalBytes = rows.sumOf { it.bytes }
    val keptBytes = rows.filter { it.pinned }.sumOf { it.bytes }
    val selectedBytes = rows.filter { it.key in selection }.sumOf { it.bytes }

    fun fmt(b: Long) = android.text.format.Formatter.formatShortFileSize(context, b)

    Column(Modifier.fillMaxSize()) {
        when {
            loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = HavenTheme.pink, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
                    Spacer(Modifier.height(10.dp))
                    Text(stringResource(R.string.cleanup_measuring), color = HavenTheme.textSecondary, fontSize = 13.sp)
                }
            }
            rows.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.cleanup_no_cached_media), color = HavenTheme.textSecondary, fontSize = 14.sp)
            }
            else -> {
                LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                    item {
                        Column(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
                            val itemCountText = stringResource(
                                if (rows.size == 1) R.string.cleanup_item_count_one else R.string.cleanup_item_count_other,
                                rows.size,
                            )
                            Text(
                                stringResource(R.string.cleanup_items_summary, itemCountText, fmt(totalBytes)) +
                                    if (keptBytes > 0) stringResource(R.string.cleanup_kept_suffix, fmt(keptBytes)) else "",
                                color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                stringResource(R.string.cleanup_footer_note),
                                color = HavenTheme.textSecondary, fontSize = 12.sp,
                            )
                        }
                    }
                    items(rows, key = { it.key }) { row ->
                        MediaInventoryRowView(
                            row = row,
                            selected = row.key in selection,
                            onToggleSelect = {
                                if (row.pinned) return@MediaInventoryRowView
                                if (row.key in selection) selection.remove(row.key) else selection.add(row.key)
                            },
                            onTogglePin = {
                                PinnedMediaStore.togglePin(listOf(row.key))
                                selection.remove(row.key)   // a newly-pinned row can't stay selected
                                // Re-flag rows in place without a full re-measure.
                                rows = rows.map { if (it.key == row.key) it.copy(pinned = PinnedMediaStore.isPinned(it.key)) else it }
                            },
                            fmt = ::fmt,
                        )
                    }
                }
                if (selection.isNotEmpty()) {
                    Box(
                        Modifier.fillMaxWidth().padding(vertical = 8.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(if (working) HavenTheme.textSecondary else HavenTheme.pink)
                            .clickable(enabled = !working) {
                                working = true
                                scope.launch {
                                    val chosen = rows.filter { it.key in selection && !it.pinned }
                                    withContext(Dispatchers.IO) { runCatching { HavenNet.deleteSelectedMedia(chosen) } }
                                    selection.clear()
                                    working = false
                                    reloadTick++
                                }
                            }
                            .padding(vertical = 14.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (working) stringResource(R.string.cleanup_removing)
                            else stringResource(R.string.cleanup_remove_button, selection.size, fmt(selectedBytes)),
                            color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MediaInventoryRowView(
    row: HavenNet.MediaInventoryRow,
    selected: Boolean,
    onToggleSelect: () -> Unit,
    onTogglePin: () -> Unit,
    fmt: (Long) -> String,
) {
    // Decode a thumbnail once per key, off the main thread.
    var thumb by remember(row.key) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(row.key) {
        thumb = withContext(Dispatchers.IO) { runCatching { LocalMedia.thumbnail(row.key) }.getOrNull() }
    }
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { onToggleSelect() }.padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Selection toggle — pinned rows are ineligible (a pin glyph instead of a checkbox).
        Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
            if (row.pinned) {
                Icon(Icons.Filled.PushPin, stringResource(R.string.cleanup_cd_kept), tint = HavenTheme.pink, modifier = Modifier.size(20.dp))
            } else {
                Icon(
                    if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                    if (selected) stringResource(R.string.cleanup_cd_selected) else stringResource(R.string.cleanup_cd_not_selected),
                    tint = if (selected) HavenTheme.pink else HavenTheme.textSecondary,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
        Spacer(Modifier.size(10.dp))
        // Thumbnail (image/poster) or a kind glyph.
        Box(Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)).background(HavenTheme.card),
            contentAlignment = Alignment.Center) {
            val t = thumb
            if (t != null) {
                androidx.compose.foundation.Image(
                    t.asImageBitmap(), stringResource(R.string.cleanup_cd_thumbnail),
                    modifier = Modifier.fillMaxSize(),
                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                )
                if (row.isVideo) Icon(Icons.Filled.PlayCircle, null, tint = Color.White.copy(alpha = 0.9f), modifier = Modifier.size(20.dp))
            } else {
                Icon(
                    when { row.isAudio -> Icons.Filled.Audiotrack; row.isVideo -> Icons.Filled.Videocam; else -> Icons.Filled.Photo },
                    null, tint = HavenTheme.textSecondary, modifier = Modifier.size(22.dp),
                )
            }
        }
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(row.circleName, color = HavenTheme.textPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp, maxLines = 1)
            val sub = row.snippet ?: if (row.orphan) stringResource(R.string.cleanup_orphan_note) else null
            if (sub != null) {
                Text(sub, color = HavenTheme.textSecondary, fontSize = 12.sp, maxLines = 1)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.cleanup_size_ago, fmt(row.bytes), relativeAgoMs(row.mtimeMs)), color = HavenTheme.textSecondary, fontSize = 11.sp)
                if (row.pinned) {
                    Spacer(Modifier.size(6.dp))
                    Text(stringResource(R.string.cleanup_kept_badge), color = HavenTheme.pink, fontWeight = FontWeight.SemiBold, fontSize = 11.sp)
                }
            }
        }
        Spacer(Modifier.size(8.dp))
        // Per-row "Keep on this device" toggle.
        Box(Modifier.size(36.dp).clip(CircleShape).clickable { onTogglePin() }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.PushPin, if (row.pinned) stringResource(R.string.cleanup_cd_stop_keeping) else stringResource(R.string.cleanup_cd_keep_on_device),
                tint = if (row.pinned) HavenTheme.pink else HavenTheme.textSecondary, modifier = Modifier.size(18.dp))
        }
    }
}

/** Compact "3d ago"-style relative time from an epoch-ms timestamp (row mtime). */
private fun relativeAgoMs(ms: Long): String {
    val diff = System.currentTimeMillis() - ms
    if (diff < 0) return "now"
    val s = diff / 1000
    return when {
        s < 45 -> "just now"
        s < 3600 -> "${s / 60}m ago"
        s < 86_400 -> "${s / 3600}h ago"
        s < 604_800 -> "${s / 86_400}d ago"
        else -> "${s / 604_800}w ago"
    }
}
