package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R

/**
 * Long-press on Post: a checklist of the user's circles (the current one pre-checked, DMs excluded)
 * and a "Post to N circles" button. Pure UI over its parameters — the caller authors the post once per
 * returned id — so it can be driven in a Compose test without an engine. See [MultiCircle] for the rules.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PostToCirclesSheet(
    targets: List<PostTarget>,
    activeId: String,
    hasBlobMedia: Boolean,
    onDismiss: () -> Unit,
    onPost: (List<String>) -> Unit,
) {
    val rows = remember(targets) { MultiCircle.targets(targets) }
    var selection by remember(rows, activeId) { mutableStateOf(MultiCircle.initialSelection(activeId, rows)) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = HavenTheme.card,
        modifier = Modifier.testTag("postCirclesSheet"),
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Text(stringResource(R.string.composer_circles_sheet_title), color = HavenTheme.textPrimary,
                fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            if (hasBlobMedia) {
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.composer_circles_media_note), color = HavenTheme.textSecondary, fontSize = 12.sp)
            }
            Spacer(Modifier.height(10.dp))
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
                rows.forEach { t ->
                    val enabled = MultiCircle.isSelectable(t.id, activeId, hasBlobMedia)
                    val checked = t.id in selection
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 3.dp).clip(RoundedCornerShape(12.dp))
                            .background(if (checked) HavenTheme.pink.copy(alpha = 0.14f) else HavenTheme.background)
                            .alpha(if (enabled) 1f else 0.45f)
                            .clickable(enabled = enabled) { selection = MultiCircle.toggle(selection, t.id, activeId, hasBlobMedia) }
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                            .testTag("postCircle:${t.id}"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(
                            checked = checked, enabled = enabled,
                            onCheckedChange = { selection = MultiCircle.toggle(selection, t.id, activeId, hasBlobMedia) },
                            colors = CheckboxDefaults.colors(checkedColor = HavenTheme.pink),
                        )
                        Text(t.name, color = HavenTheme.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                        if (t.id == activeId) Text(stringResource(R.string.composer_circles_current),
                            color = HavenTheme.textSecondary, fontSize = 12.sp)
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
            BrandButton(
                text = if (selection.size == 1) stringResource(R.string.composer_circles_post_button_one)
                else stringResource(R.string.composer_circles_post_button, selection.size),
                enabled = selection.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().testTag("postCirclesConfirm"),
            ) { onPost(MultiCircle.orderedForPosting(selection, rows, activeId)) }
        }
    }
}
