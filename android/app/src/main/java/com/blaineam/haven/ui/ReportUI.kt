package com.blaineam.haven.ui

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.HiddenStore
import com.blaineam.haven.core.REPORT_REASONS
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.ReportFfi

// Decentralized moderation (parity with apple/HavenApp/ReportUI.swift — see docs/MODERATION.md).
// Haven circles have no owner and the developer holds no keys, so moderation is the members': a
// report is sealed to the WHOLE circle and every member acts with the power they already hold —
// hide for themselves, remove the author from their circle, or block. The only thing that ever
// leaves the circle is a content-free ledger entry: identity vs identity, action, category.

/** Report a post/message: pick a category, optionally add a note for the circle, optionally block
 *  the author in the same motion. Submitting hides the post for the reporter instantly. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportSheet(item: FeedItemFfi, circleId: String, authorName: String, onDismiss: () -> Unit) {
    var reason by remember { mutableStateOf<String?>(null) }
    var comment by remember { mutableStateOf("") }
    var alsoBlock by remember { mutableStateOf(false) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = HavenTheme.card,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Text("Report post", color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text("What's wrong with it?", color = HavenTheme.textSecondary, fontSize = 13.sp)
            Spacer(Modifier.height(10.dp))
            REPORT_REASONS.forEach { r ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 3.dp).clip(RoundedCornerShape(12.dp))
                        .background(if (reason == r) HavenTheme.pink.copy(alpha = 0.18f) else HavenTheme.background)
                        .clickable { reason = r }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(r, color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                    if (reason == r) Icon(Icons.Filled.CheckCircle, null, tint = HavenTheme.pink, modifier = Modifier.size(18.dp))
                }
            }
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(
                value = comment, onValueChange = { comment = it },
                placeholder = { Text("Add a note for your circle (optional)", fontSize = 13.sp) },
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), maxLines = 3,
                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink),
            )
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Also block $authorName", color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                Switch(
                    checked = alsoBlock, onCheckedChange = { alsoBlock = it },
                    colors = SwitchDefaults.colors(checkedTrackColor = HavenTheme.pink),
                )
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "Hides the post for you now; your circle sees the report. Nothing is ever logged.",
                color = HavenTheme.textSecondary, fontSize = 12.sp,
            )
            Spacer(Modifier.height(14.dp))
            BrandButton(text = "Report", modifier = Modifier.fillMaxWidth(), enabled = reason != null) {
                val author = HavenNet.report(circleId, item.id, reason ?: return@BrandButton, comment.trim())
                if (alsoBlock && author != null) HavenNet.block(author)
                onDismiss()
            }
        }
    }
}

/** Shown on a post that OTHER members reported — the circle's shared moderation signal. Each
 *  viewer decides for themselves: hide it, remove the author from their circle, or block. The
 *  reporter never sees this (the post is already hidden for them). */
@Composable
fun ReportedBanner(item: FeedItemFfi, circleId: String, authorName: String, reports: List<ReportFfi>) {
    var actMenu by remember(item.id) { mutableStateOf(false) }
    var confirmRemove by remember(item.id) { mutableStateOf(false) }
    val reporterNames = reports.map { r ->
        if (r.reporter.startsWith(HavenNet.nodeIdHex.take(8))) "You" else HavenNet.displayName(r.reporterShort)
    }.toSortedSet().joinToString(", ")
    val reasons = reports.map { it.reason }.distinct().joinToString(" · ")

    if (confirmRemove) {
        AlertDialog(
            onDismissRequest = { confirmRemove = false }, containerColor = HavenTheme.card,
            title = { Text("Remove $authorName from this circle?", color = HavenTheme.textPrimary, fontSize = 16.sp) },
            text = {
                Text("Their posts leave your view of the circle and they can't rejoin through you. Your own devices stay in sync.",
                    color = HavenTheme.textSecondary, fontSize = 13.sp)
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmRemove = false
                    reports.firstOrNull()?.author?.let { HavenNet.removeFromCircle(circleId, it) }
                }) { Text("Remove", color = Color(0xFFF87171)) }
            },
            dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancel", color = HavenTheme.textSecondary) } },
        )
    }

    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(Color(0xFFF59E0B).copy(alpha = 0.12f))
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Flag, null, tint = Color(0xFFF59E0B), modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text("Reported by $reporterNames", color = HavenTheme.textPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Text(reasons, color = HavenTheme.textSecondary, fontSize = 11.sp)
        }
        Box {
            Text("Act", color = HavenTheme.pink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { actMenu = true }.padding(6.dp))
            DropdownMenu(expanded = actMenu, onDismissRequest = { actMenu = false },
                modifier = Modifier.background(HavenTheme.card)) {
                DropdownMenuItem(
                    text = { Text("Hide for me", color = HavenTheme.textPrimary) },
                    onClick = { actMenu = false; HiddenStore.hide(item.id) },
                )
                DropdownMenuItem(
                    text = { Text("Remove $authorName from circle", color = Color(0xFFF87171)) },
                    onClick = { actMenu = false; confirmRemove = true },
                )
                DropdownMenuItem(
                    text = { Text("Block $authorName", color = Color(0xFFF87171)) },
                    onClick = {
                        actMenu = false
                        reports.firstOrNull()?.author?.let { HavenNet.block(it) }
                    },
                )
            }
        }
    }
}
