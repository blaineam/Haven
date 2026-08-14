package com.blaineam.haven.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateDpAsState
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.InstagramArchive
import com.blaineam.haven.core.InstagramImporter
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The guided "bring your Instagram posts over" flow. Apple parity: `InstagramImportView.swift`.
 *
 * Shaped by the fact that the user cannot get their posts out on demand: they request an export,
 * wait hours or days, and come back. So this WALKS — one step on screen at a time, each with a
 * single action — rather than presenting the whole procedure as a page of prose. The settings
 * Instagram asks for are shown as a checklist of value rows, not sentences, because that is how they
 * will be read: glanced at while looking at Instagram's form on another screen.
 *
 * Closing this screen is NOT cancelling the import. The job lives on [InstagramImporter] and keeps
 * running with the screen gone — that is the whole point of being able to browse — so leaving never
 * calls `reset()` on a running job. Only Stop cancels, and only after confirming.
 */
@Composable
fun InstagramImportScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val stage by InstagramImporter.stage
    val circleId = HavenNet.activeCircle.value
    val circleName = remember(circleId) {
        runCatching { HavenNet.circleName(circleId) }.getOrDefault("your circle")
    }

    HavenBackground {
        Column(Modifier.fillMaxSize().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(40.dp).clip(CircleShape).clickable {
                        if (!InstagramImporter.isRunning) InstagramImporter.reset()
                        onDone()
                    },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.common_close),
                         tint = HavenTheme.textPrimary)
                }
                Spacer(Modifier.size(6.dp))
                BrandText(stringResource(R.string.ig_import_title), fontSize = 22)
            }
            Spacer(Modifier.height(12.dp))

            when (stage) {
                InstagramImporter.Stage.IDLE,
                InstagramImporter.Stage.READING -> Walkthrough()
                InstagramImporter.Stage.PREVIEWING -> Preview(circleId, circleName)
                InstagramImporter.Stage.IMPORTING -> Running(onLeave = onDone)
                InstagramImporter.Stage.FINISHED -> Finished(circleName, onDone)
                InstagramImporter.Stage.FAILED -> Failure()
            }
        }
    }
}

// ---- Walkthrough (3 steps, one at a time) --------------------------------------------------------

private const val EXPORT_URL = "https://accountscenter.instagram.com/info_and_permissions/dyi/"

@Composable
private fun Walkthrough() {
    val pager = rememberPagerState(pageCount = { 3 })
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(bottom = 10.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            repeat(3) { i ->
                val on = pager.currentPage == i
                val w by animateDpAsState(if (on) 22.dp else 7.dp, label = "dot")
                Box(
                    Modifier.padding(horizontal = 3.5.dp).width(w).height(7.dp)
                        .background(
                            if (on) HavenTheme.pink else HavenTheme.textSecondary.copy(alpha = 0.3f),
                            RoundedCornerShape(50),
                        )
                )
            }
        }
        HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { page ->
            when (page) {
                0 -> StepOne { scope.launch { pager.animateScrollToPage(1) } }
                1 -> StepTwo { scope.launch { pager.animateScrollToPage(2) } }
                else -> StepThree()
            }
        }
    }
}

@Composable
private fun StepOne(onNext: () -> Unit) {
    val context = LocalContext.current
    StepBody(stringResource(R.string.ig_step1_title), stringResource(R.string.ig_step1_blurb)) {
        BrandButton(stringResource(R.string.ig_open_instagram)) { openExternal(context, EXPORT_URL) }
        Spacer(Modifier.height(14.dp))
        Text(stringResource(R.string.ig_pick_these), color = HavenTheme.textSecondary,
             fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
             modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(6.dp))
        Column(Modifier.fillMaxWidth().havenCard().padding(vertical = 4.dp)) {
            // JSON is the only one of these that cannot be recovered from later — an HTML export has
            // to be requested again from scratch — so it is the one rendered in the warning colour.
            SettingRow(stringResource(R.string.ig_setting_format),
                       stringResource(R.string.ig_setting_format_value), critical = true)
            SettingRow(stringResource(R.string.ig_setting_quality),
                       stringResource(R.string.ig_setting_quality_value))
            SettingRow(stringResource(R.string.ig_setting_range),
                       stringResource(R.string.ig_setting_range_value))
            SettingRow(stringResource(R.string.ig_setting_include),
                       stringResource(R.string.ig_setting_include_value))
        }
        Spacer(Modifier.height(10.dp))
        Text(stringResource(R.string.ig_json_warning), color = HavenTheme.amber, fontSize = 12.sp)
        Spacer(Modifier.height(14.dp))
        SecondaryButton(stringResource(R.string.ig_step1_next), onNext)
    }
}

@Composable
private fun StepTwo(onNext: () -> Unit) {
    StepBody(stringResource(R.string.ig_step2_title), stringResource(R.string.ig_step2_blurb)) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Bullet(stringResource(R.string.ig_step2_bullet1))
            Bullet(stringResource(R.string.ig_step2_bullet2))
            Bullet(stringResource(R.string.ig_step2_bullet3))
        }
        Spacer(Modifier.height(18.dp))
        SecondaryButton(stringResource(R.string.ig_step2_next), onNext)
    }
}

@Composable
private fun StepThree() {
    val context = LocalContext.current
    val reading = InstagramImporter.stage.value == InstagramImporter.Stage.READING
    // OPEN_DOCUMENT, not GET_CONTENT: only its grant can be persisted, and without a persisted grant
    // an import cannot be resumed after the app is killed — which for a multi-hour job is the
    // difference between a feature and a demo.
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) InstagramImporter.read(context, uri)
    }
    StepBody(stringResource(R.string.ig_step3_title), stringResource(R.string.ig_step3_blurb)) {
        if (reading) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp,
                                          color = HavenTheme.pink)
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.ig_reading), color = HavenTheme.textPrimary, fontSize = 15.sp)
            }
        } else {
            BrandButton(stringResource(R.string.ig_choose_file)) {
                runCatching { picker.launch(ZIP_MIME_TYPES) }
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(stringResource(R.string.ig_filename_hint), color = HavenTheme.textSecondary,
             fontSize = 12.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

/** Every MIME a .zip is handed to us as. `octet-stream` is in here because plenty of providers
 *  (mail attachments especially) never sniff the file and report exactly that — leaving it out
 *  greys the user's own archive out in the picker, with no way to tell them why. */
private val ZIP_MIME_TYPES = arrayOf(
    "application/zip", "application/x-zip-compressed", "multipart/x-zip", "application/octet-stream",
)

@Composable
private fun StepBody(title: String, blurb: String, content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(10.dp))
        Text(title, color = HavenTheme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold,
             textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(blurb, color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
        Spacer(Modifier.height(18.dp))
        content()
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun SettingRow(label: String, value: String, critical: Boolean = false) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = if (critical) HavenTheme.amber else HavenTheme.textSecondary,
             fontSize = 14.sp,
             fontWeight = if (critical) FontWeight.Bold else FontWeight.Normal)
    }
}

@Composable
private fun Bullet(text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Box(Modifier.padding(top = 6.dp).size(5.dp).clip(CircleShape).background(HavenTheme.pink))
        Spacer(Modifier.width(10.dp))
        Text(text, color = HavenTheme.textPrimary, fontSize = 14.sp)
    }
}

/** A quieter companion to [BrandButton] — "next", "choose another file", the ones that must not
 *  compete with the step's real action. */
@Composable
private fun SecondaryButton(text: String, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(50))
            .background(HavenTheme.textSecondary.copy(alpha = 0.14f))
            .clickable { onClick() }
            .padding(vertical = 13.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
    }
}

// ---- Preview — nothing publishes until this is confirmed -----------------------------------------

@Composable
private fun Preview(circleId: String, circleName: String) {
    val context = LocalContext.current
    val s = InstagramImporter.summary.value ?: return
    var includeStories by remember { mutableStateOf(false) }
    /** Off by default — it attaches a GUESS, so it should be asked for, not assumed. */
    var matchSongs by remember { mutableStateOf(false) }
    val storyCount = remember(s) { s.count(InstagramArchive.Kind.STORY) }
    val willImport = if (includeStories) s.items.size else s.items.size - storyCount

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
            Text(stringResource(R.string.ig_in_your_archive), color = HavenTheme.textPrimary,
                 fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Spacer(Modifier.height(8.dp))
            CountRow(stringResource(R.string.ig_posts), s.count(InstagramArchive.Kind.POST).toString())
            CountRow(stringResource(R.string.ig_reels), s.count(InstagramArchive.Kind.REEL).toString())
            CountRow(stringResource(R.string.ig_media), s.mediaCount.toString())
            CountRow(stringResource(R.string.ig_size),
                     android.text.format.Formatter.formatShortFileSize(context, s.totalBytes))
            val a = s.earliest
            val b = s.latest
            if (a != null && b != null) {
                CountRow(stringResource(R.string.ig_spans),
                         stringResource(R.string.ig_spans_fmt, monthYear(a), monthYear(b)))
            }
        }

        if (s.missing.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.ig_missing_fmt, s.missing.size),
                     color = HavenTheme.amber, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.ig_missing_footer), color = HavenTheme.textSecondary,
                     fontSize = 12.sp)
            }
        }

        // Stories are OPT-IN and the copy has to say WHY, because the archive's contents are not what
        // the user assumes: Instagram keeps every story ever posted, and the export marks none of
        // them as having reached a Highlight.
        if (storyCount > 0) {
            Spacer(Modifier.height(14.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                ToggleRow(stringResource(R.string.ig_include_stories_fmt, storyCount),
                          includeStories) { includeStories = it }
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.ig_stories_footer_fmt, circleName),
                     color = HavenTheme.textSecondary, fontSize = 12.sp)
            }
        }

        Spacer(Modifier.height(14.dp))
        Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
            ToggleRow(stringResource(R.string.ig_match_songs), matchSongs) { matchSongs = it }
            Spacer(Modifier.height(4.dp))
            Text(stringResource(R.string.ig_match_songs_footer), color = HavenTheme.textSecondary,
                 fontSize = 12.sp)
        }

        Spacer(Modifier.height(18.dp))
        BrandButton(
            if (willImport == 1) stringResource(R.string.ig_import_one)
            else stringResource(R.string.ig_import_many_fmt, willImport)
        ) {
            InstagramImporter.run(circleId, includeStories = includeStories, matchSongs = matchSongs)
        }
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.ig_import_footer_fmt, circleName),
             color = HavenTheme.textSecondary, fontSize = 12.sp)

        Spacer(Modifier.height(18.dp))
        SecondaryButton(stringResource(R.string.ig_choose_different)) { InstagramImporter.reset() }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun CountRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = HavenTheme.textSecondary, fontSize = 14.sp)
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = HavenTheme.textPrimary, fontSize = 15.sp,
             fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        Switch(
            checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedThumbColor = Color.White,
                                           checkedTrackColor = HavenTheme.pink),
        )
    }
}

private fun monthYear(ms: Long): String =
    SimpleDateFormat("MMM yyyy", Locale.getDefault()).format(Date(ms))

// ---- Running / done / failed ---------------------------------------------------------------------

@Composable
private fun Running(onLeave: () -> Unit) {
    val done by InstagramImporter.done
    val total by InstagramImporter.total
    var confirmStop by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
           horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(28.dp))
        Text("$done", color = HavenTheme.textPrimary, fontSize = 52.sp, fontWeight = FontWeight.SemiBold)
        Text(stringResource(R.string.ig_of_total_fmt, total), color = HavenTheme.textSecondary,
             fontSize = 14.sp)
        Spacer(Modifier.height(16.dp))
        LinearProgressIndicator(
            progress = { if (total > 0) done.toFloat() / total else 0f },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 30.dp).height(6.dp)
                .clip(RoundedCornerShape(50)),
            color = HavenTheme.pink,
            trackColor = HavenTheme.textSecondary.copy(alpha = 0.2f),
        )
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.ig_running_note), color = HavenTheme.textSecondary,
             fontSize = 12.sp, textAlign = TextAlign.Center,
             modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp))

        // The import does not need this screen — it runs on the InstagramImporter singleton, keeps
        // going while Haven is used normally, and resumes itself if the app is killed. So the primary
        // action here is to LEAVE, not to wait.
        Spacer(Modifier.height(22.dp))
        Box(Modifier.padding(horizontal = 30.dp)) {
            BrandButton(stringResource(R.string.ig_browse_while)) { onLeave() }
        }
        Spacer(Modifier.height(10.dp))
        Text(stringResource(R.string.ig_close_haven_too), color = HavenTheme.textSecondary,
             fontSize = 11.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())

        Spacer(Modifier.height(18.dp))
        // Stop is destructive and sits next to a progress bar, so it confirms.
        TextButton(onClick = { confirmStop = true }) {
            Text(stringResource(R.string.ig_stop), color = HavenTheme.amber)
        }
        Spacer(Modifier.height(24.dp))
    }

    if (confirmStop) {
        AlertDialog(
            onDismissRequest = { confirmStop = false },
            containerColor = HavenTheme.card,
            title = { Text(stringResource(R.string.ig_stop_title), color = HavenTheme.textPrimary) },
            text = {
                Text(stringResource(R.string.ig_stop_message_fmt, done), color = HavenTheme.textSecondary)
            },
            confirmButton = {
                TextButton(onClick = { confirmStop = false; InstagramImporter.cancel() }) {
                    Text(stringResource(R.string.ig_stop_confirm), color = HavenTheme.amber)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmStop = false }) {
                    Text(stringResource(R.string.ig_keep_going), color = HavenTheme.textPrimary)
                }
            },
        )
    }
}

@Composable
private fun Finished(circleName: String, onDone: () -> Unit) {
    val imported by InstagramImporter.importedCount
    val skipped by InstagramImporter.skippedCount
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(40.dp))
        Text(stringResource(R.string.ig_finished_fmt, imported), color = HavenTheme.textPrimary,
             fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.ig_finished_where_fmt, circleName),
             color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
        if (skipped > 0) {
            Spacer(Modifier.height(10.dp))
            Text(stringResource(R.string.ig_finished_skipped_fmt, skipped),
                 color = HavenTheme.textSecondary, fontSize = 12.sp, textAlign = TextAlign.Center,
                 modifier = Modifier.padding(horizontal = 24.dp))
        }
        Spacer(Modifier.height(24.dp))
        Box(Modifier.padding(horizontal = 30.dp)) {
            BrandButton(stringResource(R.string.common_done)) { InstagramImporter.reset(); onDone() }
        }
    }
}

@Composable
private fun Failure() {
    val problem = InstagramImporter.problem.value
    val message = when (problem) {
        InstagramImporter.Problem.HTML_EXPORT -> stringResource(R.string.ig_fail_html)
        InstagramImporter.Problem.NO_CONTENT -> stringResource(R.string.ig_fail_no_content)
        InstagramImporter.Problem.NO_SPACE -> stringResource(R.string.ig_fail_no_space)
        else -> stringResource(R.string.ig_fail_unreadable)
    }
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(40.dp))
        Text(message, color = HavenTheme.textPrimary, fontSize = 15.sp, textAlign = TextAlign.Center,
             modifier = Modifier.padding(horizontal = 20.dp))
        Spacer(Modifier.height(22.dp))
        Box(Modifier.padding(horizontal = 30.dp)) {
            BrandButton(stringResource(R.string.ig_try_another)) { InstagramImporter.reset() }
        }
    }
}
