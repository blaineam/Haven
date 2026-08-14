package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.Image
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.size
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import com.blaineam.haven.core.MediaLimits
import com.blaineam.haven.core.MediaReoptimizer
import com.blaineam.haven.core.PinnedMediaStore
import com.blaineam.haven.core.DeviceCredentialStore
import com.blaineam.haven.core.DeviceRosterManager
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.RosterDevice
import com.blaineam.haven.core.ProfileStore
import com.blaineam.haven.core.StorageStore
import com.blaineam.haven.core.startOver
import androidx.compose.ui.res.stringResource
import com.blaineam.haven.R
import com.blaineam.haven.support.SupportSettingsSection

/** Settings (the ⚙️ behind You): retention, blocked people, start over. Parity with iOS SettingsView. */
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.get(context) }
    var retention by remember { mutableIntStateOf(profile.retentionDays) }
    var confirmReset by remember { mutableStateOf(false) }
    var showTransfer by remember { mutableStateOf(false) }
    var showRestore by remember { mutableStateOf(false) }
    var report by remember { mutableStateOf<uniffi.haven_ffi.SelfTestReport?>(null) }
    val core = remember { com.blaineam.haven.core.HavenCore.get(context) }
    // null = the top-level category list; otherwise the open sub-section (iOS-style nested settings).
    var section by remember { mutableStateOf<String?>(null) }
    val sectionTitle = when (section) {
        "privacy" -> stringResource(R.string.settings_section_privacy); "connection" -> stringResource(R.string.settings_section_connection)
        "relays" -> stringResource(R.string.settings_section_relays)
        "blocked" -> stringResource(R.string.settings_section_blocked); "diagnostics" -> stringResource(R.string.settings_section_diagnostics)
        "identity" -> stringResource(R.string.settings_section_identity); "managemedia" -> stringResource(R.string.settings_section_managemedia)
        "support" -> stringResource(R.string.support_header); else -> stringResource(R.string.common_settings)
    }

    val options = listOf(
        0 to stringResource(R.string.settings_retention_forever),
        7 to stringResource(R.string.settings_retention_1_week),
        30 to stringResource(R.string.settings_retention_1_month),
        90 to stringResource(R.string.settings_retention_3_months),
        365 to stringResource(R.string.settings_retention_1_year),
    )

    // Settings is hosted in a Dialog, whose own back press closes the whole screen — which skipped
    // a level whenever a sub-section was open. Pop the section first, exactly like the ← does; with
    // no section open the Dialog's handling takes over and back leaves Settings.
    androidx.activity.compose.BackHandler(enabled = section != null) {
        section = if (section == "managemedia") "connection" else null
    }

    HavenBackground {
        // "Manage media" owns its own LazyColumn scroll, so it must NOT sit inside this verticalScroll
        // (nesting a lazy list in a scrollable column throws on the infinite-height constraint).
        val manageMedia = section == "managemedia"
        // Bottom padding on the CONTENT (after the scroll), not on the viewport.
        //
        // navigationBarsPadding() before verticalScroll was tried and did nothing: inside a Dialog
        // the reported inset is frequently zero, so shrinking the viewport by it shrinks it by
        // nothing and the last row still ends under the gesture bar. Padding the scrollable content
        // is scrollable space regardless of what the inset reports, which is the property needed
        // here. navigationBarsPadding() stays as well, so a device that DOES report a taller bar
        // (three-button nav) gets that too.
        Column(Modifier.fillMaxSize()
            .statusBarsPadding()
            .then(if (manageMedia) Modifier else Modifier.verticalScroll(rememberScrollState()))
            .navigationBarsPadding()
            .padding(20.dp)
            .padding(bottom = 56.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable {
                    // "Manage media" is nested under Connection — back returns there, not to the top.
                    section = when (section) { "managemedia" -> "connection"; null -> { onBack(); null }; else -> null }
                },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.common_back), tint = HavenTheme.textPrimary)
                }
                Spacer(Modifier.size(6.dp))
                BrandText(sectionTitle, fontSize = 24)
            }

            Spacer(Modifier.height(20.dp))

            // ── Top-level category list (iOS-style) ──
            if (section == null) {
                SettingsCategory(stringResource(R.string.settings_section_privacy), stringResource(R.string.settings_category_privacy_subtitle)) { section = "privacy" }
                SettingsCategory(stringResource(R.string.settings_section_relays), stringResource(R.string.settings_category_relays_subtitle)) { section = "relays" }
                SettingsCategory(stringResource(R.string.settings_section_connection), stringResource(R.string.settings_category_connection_subtitle)) { section = "connection" }
                // Not a nested section: the walkthrough is hosted by RootScreen (the progress banner
                // has to be able to reopen it from any tab, long after Settings is gone), and this
                // screen is a Dialog — anything raised behind it would be invisible. So the row
                // raises the sheet and CLOSES Settings, which is also what the user wants: they are
                // done with settings, they are importing now.
                SettingsCategory(stringResource(R.string.ig_settings_row), stringResource(R.string.ig_settings_row_subtitle)) {
                    com.blaineam.haven.core.InstagramImporter.showSheet.value = true
                    onBack()
                }
                SettingsCategory(stringResource(R.string.settings_section_identity), stringResource(R.string.settings_category_identity_subtitle)) { section = "identity" }
                SettingsCategory(stringResource(R.string.settings_section_diagnostics), stringResource(R.string.settings_category_diagnostics_subtitle)) { section = "diagnostics" }
                SettingsCategory(stringResource(R.string.settings_section_blocked),
                    if (HavenNet.blocked.isEmpty()) stringResource(R.string.settings_no_one_blocked_subtitle)
                    else stringResource(R.string.settings_blocked_count, HavenNet.blocked.size)) { section = "blocked" }
                SettingsCategory(stringResource(R.string.support_header),
                    stringResource(R.string.support_category_subtitle)) { section = "support" }
            }

            // ── Feedback & Support (MillerKit parity: guided email templates + rate/other apps) ──
            if (section == "support") {
                SupportSettingsSection()
            }

            if (section == "privacy") {
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.settings_auto_delete_posts), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.settings_auto_delete_posts_desc),
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(10.dp))
                options.forEach { (days, label) ->
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                            .clickable { retention = days; profile.setRetention(days) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(18.dp).clip(CircleShape)
                            .androidxRing(retention == days), contentAlignment = Alignment.Center) {
                            if (retention == days) Box(Modifier.size(10.dp).clip(CircleShape)
                                .androidxFill())
                        }
                        Spacer(Modifier.size(12.dp))
                        Text(label, color = HavenTheme.textPrimary, fontSize = 15.sp)
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.settings_photos_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.settings_photos_desc), color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                SettingSwitch(stringResource(R.string.settings_save_my_posts), profile.saveMyPosts) { profile.saveMyPosts = it }
                SettingSwitch(stringResource(R.string.settings_save_others_posts), profile.saveOthersPosts) { profile.saveOthersPosts = it }
                SettingSwitch(stringResource(R.string.settings_auto_optimize_media), profile.autoOptimize) { profile.autoOptimize = it }
                SettingSwitch(stringResource(R.string.settings_also_send_original), profile.sendOriginal) { profile.sendOriginal = it }
                SettingSwitch(stringResource(R.string.settings_super_data_saver), profile.superDataSaver) { profile.superDataSaver = it }
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.settings_notification_previews), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.settings_notification_previews_desc), color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(4.dp))
                val detailOptions = listOf(
                    "full" to stringResource(R.string.settings_notif_full_previews),
                    "private" to stringResource(R.string.settings_notif_name_type_only),
                    "minimal" to stringResource(R.string.settings_notif_minimal),
                )
                detailOptions.forEach { (value, label) ->
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        androidx.compose.material3.RadioButton(
                            selected = profile.notificationDetail == value,
                            onClick = { profile.notificationDetail = value },
                        )
                        Text(label, color = HavenTheme.textPrimary, fontSize = 14.sp)
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.settings_share_sheet_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Spacer(Modifier.height(4.dp))
                Text(
                    stringResource(R.string.settings_share_sheet_desc),
                    color = HavenTheme.textSecondary, fontSize = 12.sp,
                )
                SettingSwitch(stringResource(R.string.settings_suggest_conversations), profile.shareSuggestions) { profile.shareSuggestions = it }
            }
            }  // end Privacy

            // ── Relays hub (Settings ▸ Relays) — manage every configured relay ──
            if (section == "relays") {
                RelaysHubCard(context)
            }

            // ── Manage media (Settings ▸ Connection ▸ Storage ▸ Manage media) — size-sorted cleanup ──
            if (manageMedia) {
                Box(Modifier.weight(1f).fillMaxWidth()) { MediaCleanupScreen() }
            }

            if (section == "connection") {
            StorageSyncCard(context)

            Spacer(Modifier.height(16.dp))
            MediaCleanupCard(onManageMedia = { section = "managemedia" })

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.settings_stay_connected_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.settings_stay_connected_desc),
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                var stayOn by remember { mutableStateOf(com.blaineam.haven.core.ConnectionService.isEnabled(context)) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.settings_realtime_connection), color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                    androidx.compose.material3.Switch(
                        checked = stayOn,
                        onCheckedChange = { on -> com.blaineam.haven.core.ConnectionService.setEnabled(context, on); stayOn = on },
                        colors = androidx.compose.material3.SwitchDefaults.colors(
                            checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
                    )
                }
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.settings_nearby_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.settings_nearby_desc),
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                var nearbyOn by remember { mutableStateOf(HavenNet.nearbyWanted()) }
                val nearbyPerms = androidx.activity.compose.rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()) { grants ->
                    if (grants.values.all { it }) { HavenNet.enableNearby(); nearbyOn = true }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.settings_nearby_sharing), color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                    androidx.compose.material3.Switch(
                        checked = nearbyOn,
                        onCheckedChange = { on ->
                            if (on) {
                                val perms = if (android.os.Build.VERSION.SDK_INT >= 33)
                                    arrayOf(android.Manifest.permission.BLUETOOTH_ADVERTISE, android.Manifest.permission.BLUETOOTH_CONNECT,
                                        android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.NEARBY_WIFI_DEVICES)
                                else arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
                                nearbyPerms.launch(perms)
                            } else { HavenNet.disableNearby(); nearbyOn = false }
                        },
                        colors = androidx.compose.material3.SwitchDefaults.colors(
                            checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
                    )
                }
            }

            }  // end Connection

            if (section == "blocked") {
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.settings_section_blocked), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(6.dp))
                if (HavenNet.blocked.isEmpty()) {
                    Text(stringResource(R.string.settings_no_one_blocked_period), color = HavenTheme.textSecondary, fontSize = 13.sp)
                } else {
                    HavenNet.blocked.forEach { idHex ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(idHex.take(16) + "…", color = HavenTheme.textPrimary, fontSize = 13.sp)
                            Spacer(Modifier.size(8.dp))
                            Text(stringResource(R.string.settings_unblock), color = HavenTheme.pink, fontSize = 13.sp,
                                modifier = Modifier.clickable { HavenNet.unblock(idHex) })
                        }
                    }
                }
            }

            }  // end Blocked

            if (section == "diagnostics") {
            // Under the hood (identity hex + safety words + crypto).
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.settings_under_the_hood), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(stringResource(R.string.settings_your_id_label), color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text(core.nodeIdHex.take(24) + "…", color = HavenTheme.textPrimary, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
                Spacer(Modifier.height(6.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(stringResource(R.string.settings_safety_words_label), color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text(com.blaineam.haven.core.SafetyWords.phrase(core.verificationHex), color = HavenTheme.textPrimary, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
                Spacer(Modifier.height(10.dp))
                Text(stringResource(R.string.settings_encryption_desc),
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                LearnMoreLink("encryption")
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                BrandButton(text = stringResource(R.string.settings_run_privacy_check)) { report = core.runSelfTest() }
                report?.let { r ->
                    Spacer(Modifier.height(14.dp))
                    SettingsCheck(stringResource(R.string.settings_check_identity_yours), r.identityOk)
                    SettingsCheck(stringResource(R.string.settings_check_stuff_locked), r.hybridKemOk)
                    SettingsCheck(stringResource(R.string.settings_check_messages_signed), r.signatureOk)
                    SettingsCheck(stringResource(R.string.settings_check_invite_links_safe), r.linkOk)
                    Spacer(Modifier.height(8.dp))
                    Text(r.summary, color = if (r.allOk) Color(0xFF34D399) else Color(0xFFF87171),
                        fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                }
            }

            }  // end Diagnostics

            if (section == "identity") {
            // Move to another device / restore here.
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text(stringResource(R.string.settings_your_identity_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.settings_your_identity_desc),
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(10.dp))
                // A seedless device holds no seed to move — hide the seed-export path there.
                if (!core.seedless) {
                    Text(stringResource(R.string.settings_move_to_another_device_link), color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showTransfer = true }.padding(vertical = 8.dp))
                }
                Text(stringResource(R.string.settings_restore_identity_here), color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showRestore = true }.padding(vertical = 8.dp))
            }

            Spacer(Modifier.height(16.dp))
            AuthorizedDevicesCard()

            Spacer(Modifier.height(24.dp))
            Text(stringResource(R.string.settings_start_over_new_identity), color = Color(0xFFF87171), fontWeight = FontWeight.Medium,
                fontSize = 15.sp, modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { confirmReset = true }.padding(8.dp))
            }  // end Identity
        }
    }

    // Transfer: show this identity's seed QR for the new device to scan.
    if (showTransfer) {
        FullScreenOverlay(onDismiss = { showTransfer = false }) {
            val core = remember { com.blaineam.haven.core.HavenCore.get(context) }
            val qr = rememberQr(core.exportSeedUri())
            Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.common_done), color = HavenTheme.textSecondary, modifier = Modifier.align(Alignment.End).clickable { showTransfer = false }.padding(8.dp))
                Spacer(Modifier.height(12.dp))
                BrandText(stringResource(R.string.settings_move_to_another_device_title), fontSize = 22)
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.settings_transfer_instructions),
                    color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(20.dp))
                qr?.let { androidx.compose.foundation.Image(it, stringResource(R.string.settings_identity_transfer_qr_desc),
                    Modifier.size(260.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF101018)).padding(8.dp)) }
            }
        }
    }
    // Restore: scan a seed QR from another device, adopt it, restart clean.
    if (showRestore) {
        FullScreenOverlay(onDismiss = { showRestore = false }) {
            QrScannerScreen(
                onResult = { text ->
                    showRestore = false
                    if (text.startsWith("haven-seed:") && com.blaineam.haven.core.HavenCore.get(context).importSeed(text)) {
                        HavenNet.reset()
                        com.blaineam.haven.core.restartApp(context)
                    }
                },
                onCancel = { showRestore = false },
            )
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            containerColor = HavenTheme.card,
            title = { Text(stringResource(R.string.settings_start_over_question), color = HavenTheme.textPrimary) },
            text = {
                Text(stringResource(R.string.settings_start_over_warning),
                    color = HavenTheme.textSecondary)
            },
            confirmButton = {
                TextButton(onClick = { startOver(context) }) {
                    Text(stringResource(R.string.settings_erase_everything), color = Color(0xFFF87171))
                }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text(stringResource(R.string.common_cancel), color = HavenTheme.pink) } },
        )
    }
}

/** A tappable top-level settings category row (iOS-style nested navigation). */
@Composable
private fun SettingsCategory(title: String, subtitle: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().havenCard().clickable { onClick() }.padding(16.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
            Spacer(Modifier.height(2.dp))
            Text(subtitle, color = HavenTheme.textSecondary, fontSize = 12.sp)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = HavenTheme.textSecondary)
    }
    Spacer(Modifier.height(12.dp))
}

private fun Modifier.androidxRing(on: Boolean): Modifier =
    this.border(2.dp, if (on) HavenTheme.pink else HavenTheme.textSecondary, CircleShape)

private fun Modifier.androidxFill(): Modifier = this.background(HavenTheme.pink)

@Composable
private fun SettingsCheck(title: String, ok: Boolean) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(if (ok) "✓" else "✗", color = if (ok) Color(0xFF34D399) else Color(0xFFF87171),
            fontSize = 16.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.size(10.dp))
        Text(title, color = HavenTheme.textPrimary, fontSize = 14.sp)
    }
}

/** Storage housekeeping: the size-sorted "Manage media" screen, device-pin count, the local age/size
 *  caps, and the on-demand orphan sweep. Parity with iOS Settings ▸ Storage. */
@Composable
private fun MediaCleanupCard(onManageMedia: () -> Unit) {
    val context = LocalContext.current
    var cleaning by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    // Observe pins + limit selections so the card reflects live state.
    val pinnedCount = com.blaineam.haven.core.PinnedMediaStore.refs.size
    val maxDays = com.blaineam.haven.core.MediaLimits.maxDaysState.intValue
    val maxGB = com.blaineam.haven.core.MediaLimits.maxGBState.intValue
    LaunchedEffect(cleaning) {
        if (!cleaning) return@LaunchedEffect
        val r = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching { HavenNet.cleanupUnusedMedia() }.getOrDefault(0L to 0)
        }
        result = if (r.second == 0) context.getString(R.string.settings_nothing_to_clean_up)
        else {
            val size = android.text.format.Formatter.formatFileSize(context, r.first)
            if (r.second == 1) context.getString(R.string.settings_media_freed_one, size, r.second)
            else context.getString(R.string.settings_media_freed_other, size, r.second)
        }
        cleaning = false
    }
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(stringResource(R.string.settings_storage_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.settings_storage_desc),
            color = HavenTheme.textSecondary, fontSize = 12.sp)

        // Manage media (size-sorted cleanup screen) + kept count.
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { onManageMedia() }
            .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.settings_section_managemedia), color = HavenTheme.pink, fontWeight = FontWeight.Medium, fontSize = 14.sp,
                modifier = Modifier.weight(1f))
            if (pinnedCount > 0) {
                Text(stringResource(R.string.settings_pinned_count, pinnedCount), color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.size(6.dp))
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = HavenTheme.textSecondary)
        }

        // Local age/size caps (default OFF). Least space wins — see LocalMedia.performLimitSweep.
        Spacer(Modifier.height(6.dp))
        StorageLimitPicker(
            label = stringResource(R.string.settings_delete_older_than_label),
            options = listOf(
                0 to stringResource(R.string.settings_never),
                30 to stringResource(R.string.settings_days_30),
                90 to stringResource(R.string.settings_days_90),
                180 to stringResource(R.string.settings_months_6),
                365 to stringResource(R.string.settings_year_1),
            ),
            selected = maxDays,
            onSelect = { com.blaineam.haven.core.MediaLimits.setMaxDays(it) },
        )
        Spacer(Modifier.height(6.dp))
        StorageLimitPicker(
            label = stringResource(R.string.settings_keep_under_label),
            options = listOf(
                0 to stringResource(R.string.settings_no_limit),
                1 to stringResource(R.string.settings_gb_1),
                2 to stringResource(R.string.settings_gb_2),
                5 to stringResource(R.string.settings_gb_5),
                10 to stringResource(R.string.settings_gb_10),
                25 to stringResource(R.string.settings_gb_25),
            ),
            selected = maxGB,
            onSelect = { com.blaineam.haven.core.MediaLimits.setMaxGB(it) },
        )
        Text(stringResource(R.string.settings_caps_desc),
            color = HavenTheme.textSecondary, fontSize = 11.sp)

        // On-demand orphan sweep.
        Spacer(Modifier.height(10.dp))
        Text(
            if (cleaning) stringResource(R.string.settings_cleaning_up) else stringResource(R.string.settings_clean_up_unused_media),
            color = if (cleaning) HavenTheme.textSecondary else HavenTheme.pink,
            fontWeight = FontWeight.Medium, fontSize = 14.sp,
            modifier = Modifier
                .clip(RoundedCornerShape(10.dp))
                .clickable(enabled = !cleaning) { result = null; cleaning = true }
                .padding(vertical = 8.dp),
        )
        result?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, color = HavenTheme.textSecondary, fontSize = 12.sp)
        }

        // Re-optimize media I already shared. Sits ALONGSIDE "Clean up unused media", never instead
        // of it — they solve opposite halves of the problem: cleanup frees bytes on THIS device only,
        // re-optimize shrinks what everyone in the circle is holding. iOS briefly lost the cleanup
        // control when this row took its slot; both belong here.
        Spacer(Modifier.height(10.dp))
        ReoptimizeMediaRow()

        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.settings_cleanup_reoptimize_desc),
            color = HavenTheme.textSecondary, fontSize = 11.sp,
        )
    }
}

/**
 * Settings ▸ Storage's re-optimize action. TWO TAPS BY DESIGN: the first measures and TELLS you what
 * it found, the second commits. A button that silently re-encoded a gigabyte and re-published a year
 * of posts on one tap would be the wrong shape of thing entirely.
 *
 * The Android counterpart of iOS `ReoptimizeMediaRow`. Reads [MediaReoptimizer]'s state directly —
 * the object outlives this composable, so a run keeps going (and keeps reporting) if the user
 * navigates away and comes back.
 */
@Composable
private fun ReoptimizeMediaRow() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val scanning = MediaReoptimizer.scanning.value
    val running = MediaReoptimizer.running.value
    val candidates = MediaReoptimizer.candidates.value
    val busy = scanning || running

    val title = when {
        scanning -> stringResource(R.string.settings_checking_shared_media)
        running -> stringResource(
            R.string.settings_reoptimizing_progress,
            minOf(MediaReoptimizer.doneCount.intValue + 1, MediaReoptimizer.batchCount.intValue),
            MediaReoptimizer.batchCount.intValue, MediaReoptimizer.currentLabel.value,
        )
        candidates.isEmpty() -> stringResource(R.string.settings_reoptimize_already_shared)
        else -> {
            val n = minOf(candidates.size, MediaReoptimizer.BATCH_LIMIT)
            val posters = candidates.count { it.work == MediaReoptimizer.Work.POSTER_ONLY }
            val shrinks = candidates.size - posters
            when {
                shrinks == 0 -> {
                    val posterN = minOf(posters, n)
                    if (posterN == 1) stringResource(R.string.settings_add_posters_one, posterN)
                    else stringResource(R.string.settings_add_posters_other, posterN)
                }
                posters == 0 ->
                    if (n == 1) stringResource(R.string.settings_shrink_reshare_one, n)
                    else stringResource(R.string.settings_shrink_reshare_other, n)
                else ->
                    if (n == 1) stringResource(R.string.settings_improve_items_one, n)
                    else stringResource(R.string.settings_improve_items_other, n)
            }
        }
    }

    Row(Modifier.fillMaxWidth()
        .clip(RoundedCornerShape(10.dp))
        .clickable(enabled = !busy) {
            scope.launch {
                if (MediaReoptimizer.candidates.value.isEmpty()) MediaReoptimizer.scan()
                else MediaReoptimizer.run()
            }
        }
        .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = if (busy) HavenTheme.textSecondary else HavenTheme.pink,
            fontWeight = FontWeight.Medium, fontSize = 14.sp, modifier = Modifier.weight(1f))
        if (busy) CircularProgressIndicator(Modifier.size(16.dp), color = HavenTheme.textSecondary, strokeWidth = 2.dp)
    }

    if (running) {
        Text(stringResource(R.string.settings_stop_after_this_one), color = HavenTheme.textSecondary, fontSize = 12.sp,
            modifier = Modifier.clip(RoundedCornerShape(10.dp))
                .clickable { MediaReoptimizer.cancel() }.padding(vertical = 6.dp))
    }

    MediaReoptimizer.lastWarning.value?.let {
        Spacer(Modifier.height(4.dp))
        Text(it, color = HavenTheme.pink, fontSize = 12.sp)
    }
    val summary = MediaReoptimizer.lastSummary.value
    if (summary != null && !running) {
        Spacer(Modifier.height(4.dp))
        Text(summary, color = HavenTheme.textSecondary, fontSize = 12.sp)
    }
    if (candidates.isNotEmpty() && !running) {
        val total = candidates.size
        val batch = minOf(total, MediaReoptimizer.BATCH_LIMIT)
        val legacy = candidates.count { it.legacyByAge }
        val posters = MediaReoptimizer.posterOnlyCount
        val shrinks = total - posters
        val size = android.text.format.Formatter.formatFileSize(context, MediaReoptimizer.pendingBytes)
        var s = ""
        if (shrinks > 0) {
            s = if (shrinks == 1) stringResource(R.string.settings_media_share_item_one, shrinks, size)
                else stringResource(R.string.settings_media_share_item_other, shrinks, size)
        }
        if (posters > 0) {
            val p = if (posters == 1) stringResource(R.string.settings_media_poster_missing_one, posters)
                else stringResource(R.string.settings_media_poster_missing_other, posters)
            s = if (s.isEmpty()) p else "$s · $p"
        }
        if (legacy > 0) s += " · " + stringResource(R.string.settings_media_legacy_suffix, legacy)
        if (batch < total) s += stringResource(R.string.settings_media_batch_suffix, batch)
        Spacer(Modifier.height(4.dp))
        Text(s, color = HavenTheme.textSecondary, fontSize = 11.sp)
    } else if (MediaReoptimizer.hasScanned.value && !busy && summary == null) {
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.settings_media_all_optimized),
            color = HavenTheme.textSecondary, fontSize = 11.sp)
    }
}

/** A labeled row that opens a dropdown of preset caps — the Android counterpart of iOS's Storage
 *  Pickers ("Delete local media older than" / "Keep local media under"). */
@Composable
private fun StorageLimitPicker(label: String, options: List<Pair<Int, String>>, selected: Int, onSelect: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.first == selected }?.second ?: options.first().second
    Box {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { open = true }
            .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text(current, color = HavenTheme.pink, fontWeight = FontWeight.Medium, fontSize = 14.sp)
        }
        androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (value, text) ->
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(text, color = if (value == selected) HavenTheme.pink else HavenTheme.textPrimary) },
                    onClick = { onSelect(value); open = false },
                )
            }
        }
    }
}

/** [StorageLimitPicker]'s shape, but generic over the value type — the relay's two limits are an Int
 *  (days) and a Long (bytes), and duplicating the whole picker to change one type would be worse. */
@Composable
private fun <T> RelayLimitRow(label: String, options: List<Pair<T, String>>, current: T, onSelect: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val shown = options.firstOrNull { it.first == current }?.second ?: options.first().second
    Box {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { open = true }
            .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text(shown, color = HavenTheme.pink, fontWeight = FontWeight.Medium, fontSize = 14.sp)
        }
        androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (value, text) ->
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(text, color = if (value == current) HavenTheme.pink else HavenTheme.textPrimary) },
                    onClick = { onSelect(value); open = false },
                )
            }
        }
    }
}

/**
 * BYO-storage (S3-compatible bucket) for multi-device self-sync — the Android counterpart of iOS's
 * owner-S3 transport. With these 5 fields, self-sync converges your own devices over your OWN bucket
 * with NO relay required (profile/settings/contacts/blocked/circles). Credentials stay on-device.
 */
@Composable
private fun StorageSyncCard(context: android.content.Context) {
    var saved by remember { mutableStateOf(StorageStore.load(context)) }
    var endpoint by remember { mutableStateOf(saved.endpoint) }
    var region by remember { mutableStateOf(saved.region) }
    var bucket by remember { mutableStateOf(saved.bucket) }
    var accessKey by remember { mutableStateOf(saved.accessKey) }
    var secretKey by remember { mutableStateOf(saved.secretKey) }

    val candidate = StorageStore.Config(endpoint, region, bucket, accessKey, secretKey)
    val dirty = candidate != saved

    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(stringResource(R.string.settings_sync_devices_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text(
            if (saved.isConfigured)
                stringResource(R.string.settings_sync_configured_desc)
            else stringResource(R.string.settings_sync_unconfigured_desc),
            color = HavenTheme.textSecondary, fontSize = 12.sp,
        )
        LearnMoreLink("byo")
        Spacer(Modifier.height(12.dp))

        StorageField(stringResource(R.string.settings_endpoint_label), endpoint) { endpoint = it }
        Spacer(Modifier.height(8.dp))
        StorageField(stringResource(R.string.settings_region_hint_label), region) { region = it }
        Spacer(Modifier.height(8.dp))
        StorageField(stringResource(R.string.settings_bucket_label), bucket) { bucket = it }
        Spacer(Modifier.height(8.dp))
        StorageField(stringResource(R.string.settings_access_key_label), accessKey) { accessKey = it }
        Spacer(Modifier.height(8.dp))
        StorageField(stringResource(R.string.settings_secret_key_label), secretKey, secret = true) { secretKey = it }

        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (saved.isConfigured) stringResource(R.string.settings_save_changes) else stringResource(R.string.common_save),
                color = if (dirty) HavenTheme.pink else HavenTheme.textSecondary,
                fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = dirty) {
                    StorageStore.save(context, candidate)
                    saved = StorageStore.load(context)
                }.padding(8.dp),
            )
            if (saved.isConfigured) {
                Spacer(Modifier.size(8.dp))
                Text(stringResource(R.string.common_remove), color = Color(0xFFF87171), fontSize = 14.sp,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable {
                        StorageStore.clear(context)
                        saved = StorageStore.load(context)
                        endpoint = ""; region = ""; bucket = ""; accessKey = ""; secretKey = ""
                    }.padding(8.dp))
            }
        }
    }
}

/**
 * The Relays hub (Settings ▸ Relays): one place to manage EVERY configured relay (active + inactive),
 * add unlimited new ones (a Haven relay node, or an S3 bucket as store-and-forward), pick the default
 * every future unconfigured circle inherits, and deactivate / reactivate / rename / delete-now each.
 * Removing a relay DEACTIVATES it (config survives) so it can come back; "Delete" erases it for good.
 * Parity with iOS `RelaysView` + the deactivate-not-erase model in HavenNet.
 */
@Composable
private fun RelaysHubCard(context: android.content.Context) {
    val relaysVersion by HavenNet.relaysVersion
    val entries = remember(relaysVersion) { HavenNet.allRelayEntries() }
    val deleted = remember(relaysVersion) { HavenNet.erasedRelayList() }
    var showDeleted by remember { mutableStateOf(false) }
    val default = remember(relaysVersion) { HavenNet.defaultRelay() }
    val detail = remember(relaysVersion) { HavenNet.relaysDetail().associate { it.first to (it.second to it.third) } }
    var showAdd by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<String?>(null) }
    var renameText by remember { mutableStateOf("") }

    // This-device relay (the zero-setup path that makes this phone a relay).
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(stringResource(R.string.settings_this_device), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.settings_this_device_relay_desc),
            color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))
        val hosting by HavenNet.hosting
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.settings_be_a_relay_switch), color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
            androidx.compose.material3.Switch(
                checked = hosting,
                onCheckedChange = { on -> if (on) HavenNet.startHosting() else HavenNet.stopHosting() },
                colors = androidx.compose.material3.SwitchDefaults.colors(
                    checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
            )
        }
        // How much of your circles' media this phone is willing to hold, and for how long.
        // Volunteering a device shouldn't mean volunteering the whole disk.
        if (hosting) {
            Spacer(Modifier.height(12.dp))
            RelayLimitRow(
                label = stringResource(R.string.settings_keep_media_for_label),
                options = listOf(
                    7 to stringResource(R.string.settings_days_7),
                    30 to stringResource(R.string.settings_days_30),
                    90 to stringResource(R.string.settings_days_90),
                    365 to stringResource(R.string.settings_year_1),
                    0 to stringResource(R.string.settings_no_limit),
                ),
                current = HavenNet.relayMediaMaxAgeDays,
            ) { HavenNet.relayMediaMaxAgeDays = it }
            Spacer(Modifier.height(8.dp))
            RelayLimitRow(
                label = stringResource(R.string.settings_media_storage_limit_label),
                options = listOf(
                    2L shl 30 to stringResource(R.string.settings_gb_2), 8L shl 30 to stringResource(R.string.settings_gb_8),
                    32L shl 30 to stringResource(R.string.settings_gb_32),
                    128L shl 30 to stringResource(R.string.settings_gb_128), 0L to stringResource(R.string.settings_no_limit),
                ),
                current = HavenNet.relayMediaMaxBytes,
            ) { HavenNet.relayMediaMaxBytes = it }
            Spacer(Modifier.height(8.dp))
            Text(stringResource(R.string.settings_relay_limits_desc),
                color = HavenTheme.textSecondary, fontSize = 11.sp)
        }
    }

    Spacer(Modifier.height(16.dp))

    // Configured relays (active + inactive).
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(if (entries.isEmpty()) stringResource(R.string.settings_configured_relays) else stringResource(R.string.settings_configured_relays_count, entries.size),
            color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.settings_configured_relays_desc),
            color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))

        if (entries.isEmpty()) {
            Text(stringResource(R.string.settings_no_relays_yet),
                color = HavenTheme.textSecondary, fontSize = 13.sp)
        } else {
            entries.forEach { e ->
                val (reachable, hosted) = detail[e.hex] ?: (true to false)
                RelayRow(
                    entry = e, isDefault = (default == e.hex), reachable = reachable, hosted = hosted,
                    onDeactivate = { HavenNet.forgetRelay(e.hex) },
                    onReactivate = { HavenNet.reactivateRelay(e.hex) },
                    onSetDefault = { HavenNet.setDefaultRelay(if (default == e.hex) null else e.hex) },
                    onRename = { renaming = e.hex; renameText = e.name },
                    onDelete = { HavenNet.eraseRelayNow(e.hex) },
                )
            }
        }
    }

    // Deleted relays — the undo for "Delete now", which drops the entry, every circle association
    // and the default pick. A relay is a 64-character node id, not something anyone re-adds from
    // memory. Hidden entirely when there is nothing to recover. Apple parity (DeletedRelaysSection).
    if (deleted.isNotEmpty()) {
        Spacer(Modifier.height(16.dp))
        Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { showDeleted = !showDeleted }.padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_deleted_relays_count, deleted.size), color = HavenTheme.textPrimary,
                    fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.weight(1f))
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = HavenTheme.textSecondary)
            }
            if (!showDeleted) {
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.settings_deleted_relays_desc),
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
            } else {
                Spacer(Modifier.height(8.dp))
                deleted.forEach { rec ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(rec.entry.name.ifBlank { rec.entry.hex.take(12) + "…" },
                                color = HavenTheme.textPrimary, fontSize = 14.sp)
                            Text(
                                if (rec.circles.isEmpty()) rec.entry.hex.take(12) + "…"
                                else if (rec.circles.size == 1) stringResource(R.string.settings_relay_circle_count_one, rec.entry.hex.take(12), rec.circles.size)
                                else stringResource(R.string.settings_relay_circle_count_other, rec.entry.hex.take(12), rec.circles.size),
                                color = HavenTheme.textSecondary, fontSize = 11.sp)
                        }
                        TextButton(onClick = { HavenNet.restoreErasedRelay(rec.entry.hex) }) {
                            Text(stringResource(R.string.settings_restore), color = HavenTheme.pink, fontSize = 13.sp)
                        }
                        TextButton(onClick = { HavenNet.dropErasedRelay(rec.entry.hex) }) {
                            Text(stringResource(R.string.settings_forget), color = HavenTheme.textSecondary, fontSize = 13.sp)
                        }
                    }
                }
            }
        }
    }

    Spacer(Modifier.height(16.dp))

    // Add relay (Haven node or S3 bucket).
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { showAdd = !showAdd }.padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.settings_add_relay), color = HavenTheme.pink, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = HavenTheme.pink)
        }
        if (!showAdd) {
            Spacer(Modifier.height(4.dp))
            Text(stringResource(R.string.settings_add_relay_desc),
                color = HavenTheme.textSecondary, fontSize = 12.sp)
        } else {
            Spacer(Modifier.height(10.dp))
            AddRelayForm(context) { showAdd = false }
        }
    }

    if (renaming != null) {
        AlertDialog(
            onDismissRequest = { renaming = null }, containerColor = HavenTheme.card,
            title = { Text(stringResource(R.string.settings_rename_relay_title), color = HavenTheme.textPrimary) },
            text = {
                androidx.compose.material3.OutlinedTextField(
                    value = renameText, onValueChange = { renameText = it }, singleLine = true,
                    label = { Text(stringResource(R.string.settings_name_label)) }, modifier = Modifier.fillMaxWidth(),
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
                )
            },
            confirmButton = {
                TextButton(onClick = { renaming?.let { HavenNet.renameRelay(it, renameText) }; renaming = null }) {
                    Text(stringResource(R.string.common_save), color = HavenTheme.pink)
                }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text(stringResource(R.string.common_cancel), color = HavenTheme.textSecondary) } },
        )
    }
}

/** One relay row in the hub: status + labeled action buttons (deactivate/reactivate, default) + an
 *  overflow menu (rename / delete). Properly sized tappable controls — no tiny icon-only taps. */
@Composable
private fun RelayRow(
    entry: HavenNet.RelayEntry, isDefault: Boolean, reachable: Boolean, hosted: Boolean,
    onDeactivate: () -> Unit, onReactivate: () -> Unit, onSetDefault: () -> Unit,
    onRename: () -> Unit, onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val dotColor = when {
        !entry.active -> HavenTheme.textSecondary
        entry.isS3 -> Color(0xFF3B82F6)
        reachable -> Color(0xFF34C759)
        else -> Color(0xFFFF9500)
    }
    val status = when {
        !entry.active -> stringResource(R.string.settings_relay_deactivated)
        entry.isS3 -> stringResource(R.string.settings_relay_s3_bucket_status)
        hosted -> stringResource(R.string.settings_relay_this_phone_status,
            if (reachable) stringResource(R.string.settings_relay_reachable_lower) else stringResource(R.string.settings_relay_starting))
        reachable -> stringResource(R.string.settings_relay_status_reachable)
        else -> stringResource(R.string.settings_relay_unreachable)
    }
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(9.dp).clip(CircleShape).background(dotColor))
            Spacer(Modifier.size(10.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(entry.name, color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                    if (isDefault) { Spacer(Modifier.size(6.dp)); Text("★", color = HavenTheme.pink, fontSize = 13.sp) }
                }
                Text(status, color = HavenTheme.textSecondary, fontSize = 11.sp)
                Text(if (entry.isS3) entry.hex else entry.hex.take(16) + "…",
                    color = HavenTheme.textSecondary, fontSize = 11.sp,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
            }
            Box {
                Text("⋯", color = HavenTheme.textPrimary, fontSize = 22.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { menu = true }.padding(horizontal = 10.dp, vertical = 4.dp))
                androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(stringResource(R.string.settings_rename_menu_item)) }, onClick = { menu = false; onRename() })
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(if (isDefault) stringResource(R.string.settings_unset_default) else stringResource(R.string.settings_make_default)) },
                        onClick = { menu = false; onSetDefault() })
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(stringResource(R.string.settings_delete_now), color = Color(0xFFF87171)) }, onClick = { menu = false; onDelete() })
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (entry.active) {
                RelayActionChip(stringResource(R.string.settings_deactivate), HavenTheme.textSecondary, onDeactivate)
            } else {
                RelayActionChip(stringResource(R.string.settings_reactivate), Color(0xFF34C759), onReactivate)
            }
            if (!isDefault) RelayActionChip(stringResource(R.string.settings_set_default), HavenTheme.pink, onSetDefault)
        }
    }
}

@Composable
private fun RelayActionChip(label: String, color: Color, onClick: () -> Unit) {
    Text(label, color = color, fontSize = 13.sp, fontWeight = FontWeight.Medium,
        modifier = Modifier.clip(RoundedCornerShape(8.dp))
            .border(1.dp, color.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .clickable { onClick() }.padding(horizontal = 12.dp, vertical = 8.dp))
}

/** The "Add relay" form: a Haven relay (paste a node id) OR an S3 bucket (with a store-and-forward
 *  disclaimer). The S3 secret goes to StorageStore (device-local creds), never the relays prefs. */
@Composable
private fun AddRelayForm(context: android.content.Context, onDone: () -> Unit) {
    var isS3 by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var makeDefault by remember { mutableStateOf(true) }
    var nodeInput by remember { mutableStateOf("") }
    var endpoint by remember { mutableStateOf("") }
    var region by remember { mutableStateOf("us-east-1") }
    var bucket by remember { mutableStateOf("") }
    var accessKey by remember { mutableStateOf("") }
    var secret by remember { mutableStateOf("") }

    val havenValid = nodeInput.trim().length == 64 && nodeInput.trim().all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
    val s3Valid = endpoint.isNotBlank() && bucket.isNotBlank() && accessKey.isNotBlank() && secret.isNotBlank()

    Column(Modifier.fillMaxWidth()) {
        // Type segmented toggle.
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            RelayTypeSeg(stringResource(R.string.settings_relay_type_haven), !isS3) { isS3 = false }
            RelayTypeSeg(stringResource(R.string.settings_relay_type_s3), isS3) { isS3 = true }
        }
        Spacer(Modifier.height(10.dp))
        StorageField(stringResource(R.string.settings_name_optional_label), name) { name = it }
        Spacer(Modifier.height(8.dp))
        SettingSwitch(stringResource(R.string.settings_make_default_for_circles), makeDefault) { makeDefault = it }
        Spacer(Modifier.height(8.dp))

        if (!isS3) {
            // Running your OWN relay (a haven-relay daemon or the Docker relay)? It needs THIS
            // circle's link first; it then prints a node id you paste below. Surface the copy here so
            // the two-step flow is discoverable (parity with iOS AddRelaySheet).
            var linkCopied by remember { mutableStateOf(false) }
            Text(if (linkCopied) stringResource(R.string.settings_relay_link_copied) else stringResource(R.string.settings_copy_relay_link),
                color = if (linkCopied) Color(0xFF34D399) else HavenTheme.pink, fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable {
                    HavenNet.relayLink()?.let {
                        (context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                            .setPrimaryClip(android.content.ClipData.newPlainText("haven relay link", it))
                        linkCopied = true
                    }
                }.padding(vertical = 6.dp))
            Text(stringResource(R.string.settings_relay_link_desc),
                color = HavenTheme.textSecondary, fontSize = 11.sp)
            Spacer(Modifier.height(12.dp))
            StorageField(stringResource(R.string.settings_relay_node_id_label), nodeInput) { nodeInput = it.trim() }
            Spacer(Modifier.height(6.dp))
            Text(stringResource(R.string.settings_relay_node_id_desc),
                color = HavenTheme.textSecondary, fontSize = 11.sp)
        } else {
            StorageField(stringResource(R.string.settings_endpoint_label), endpoint) { endpoint = it }
            Spacer(Modifier.height(8.dp))
            StorageField(stringResource(R.string.settings_region_label), region) { region = it }
            Spacer(Modifier.height(8.dp))
            StorageField(stringResource(R.string.settings_bucket_label), bucket) { bucket = it }
            Spacer(Modifier.height(8.dp))
            StorageField(stringResource(R.string.settings_access_key_id_label), accessKey) { accessKey = it }
            Spacer(Modifier.height(8.dp))
            StorageField(stringResource(R.string.settings_secret_access_key_label), secret, secret = true) { secret = it }
            Spacer(Modifier.height(6.dp))
            Text(stringResource(R.string.settings_s3_warning),
                color = Color(0xFFFF9500), fontSize = 11.sp)
        }

        Spacer(Modifier.height(12.dp))
        val valid = if (isS3) s3Valid else havenValid
        Text(stringResource(R.string.settings_add_relay), color = if (valid) HavenTheme.pink else HavenTheme.textSecondary,
            fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = valid) {
                if (isS3) {
                    val cfg = StorageStore.Config(endpoint.trim(),
                        region.ifBlank { "us-east-1" }.trim(), bucket.trim(), accessKey.trim(), secret)
                    HavenNet.addS3Relay(cfg, name.ifBlank { "S3 · ${bucket.trim()}" }, makeDefault)
                } else {
                    HavenNet.adoptRelay(nodeInput.trim().lowercase(), name.ifBlank { null }, makeDefault)
                }
                onDone()
            }.padding(horizontal = 12.dp, vertical = 8.dp))
    }
}

@Composable
private fun RelayTypeSeg(text: String, selected: Boolean, onClick: () -> Unit) {
    Text(text, color = if (selected) HavenTheme.textPrimary else HavenTheme.textSecondary,
        fontSize = 13.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
        modifier = Modifier.clip(RoundedCornerShape(8.dp))
            .background(if (selected) HavenTheme.pink.copy(alpha = 0.28f) else HavenTheme.cardBorder)
            .clickable { onClick() }.padding(horizontal = 14.dp, vertical = 8.dp))
}

@Composable
private fun StorageField(label: String, value: String, secret: Boolean = false, onChange: (String) -> Unit) {
    androidx.compose.material3.OutlinedTextField(
        value = value, onValueChange = onChange,
        label = { Text(label) }, singleLine = true,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation()
            else androidx.compose.ui.text.input.VisualTransformation.None,
        colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
            focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
    )
}

/** One-liner copy keeps the detail out of the card — "Learn more" opens the docs at [anchor]. */
@Composable
private fun LearnMoreLink(anchor: String) {
    val context = LocalContext.current
    Text(stringResource(R.string.settings_learn_more), color = HavenTheme.pink, fontSize = 12.sp, fontWeight = FontWeight.Medium,
        modifier = Modifier.clip(RoundedCornerShape(6.dp))
            .clickable { openInApp(context, "https://wemiller.com/apps/haven/docs/#$anchor") }
            .padding(vertical = 4.dp))
}

@Composable
private fun SettingSwitch(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        androidx.compose.material3.Switch(checked = checked, onCheckedChange = onChange,
            colors = androidx.compose.material3.SwitchDefaults.colors(
                checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink))
    }
}

/** iOS-parity "Authorized devices": this device's role + the signed roster, with revoke / enable /
 *  step-down / request-enrollment. The credential crypto lives in the shared core. */
@Composable
private fun AuthorizedDevicesCard() {
    val devices = DeviceRosterManager.devices
    var enabled by remember { mutableStateOf(DeviceRosterManager.isEnabled()) }
    val authorized by DeviceCredentialStore.authorized
    var revokeTarget by remember { mutableStateOf<RosterDevice?>(null) }
    val seedless = remember { HavenNet.isSeedless }
    val ticketUri by HavenNet.seedlessTicketUri            // "" while no ticket is offered
    val enrollPrompt by HavenNet.seedlessPendingRequest    // a new device asking to link (null = none)
    LaunchedEffect(Unit) { DeviceCredentialStore.refresh() }

    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(stringResource(R.string.settings_authorized_devices_header), color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        val role = when {
            seedless -> stringResource(R.string.settings_role_seedless_title) to stringResource(R.string.settings_role_seedless_desc)
            enabled -> stringResource(R.string.settings_role_primary_title) to stringResource(R.string.settings_role_primary_desc)
            authorized -> stringResource(R.string.settings_role_linked_title) to stringResource(R.string.settings_role_linked_desc)
            else -> stringResource(R.string.settings_role_unlinked_title) to stringResource(R.string.settings_role_unlinked_desc)
        }
        Text(role.first, color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Text(role.second, color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))

        if (devices.isEmpty()) {
            Text(stringResource(R.string.settings_no_devices_linked), color = HavenTheme.textSecondary, fontSize = 13.sp)
        } else {
            devices.forEach { d ->
                Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (d.isPrimary) Icons.Filled.Key else Icons.Filled.Smartphone, null,
                        tint = if (d.isPrimary) HavenTheme.pink else HavenTheme.textSecondary, modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.size(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(d.name, color = HavenTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                        Text(
                            if (d.isPrimary) stringResource(R.string.settings_master_key_label) else if (d.isThisDevice) stringResource(R.string.settings_this_device) else stringResource(R.string.settings_linked_device_label),
                            color = HavenTheme.textSecondary, fontSize = 11.sp,
                        )
                    }
                    if (!d.isPrimary) {
                        Text(
                            stringResource(R.string.settings_revoke), color = Color(0xFFF87171), fontSize = 13.sp,
                            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { revokeTarget = d }.padding(6.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        if (seedless) {
            // A seedless device can never hold the seed → never become primary. It only re-syncs.
            Text(
                stringResource(R.string.settings_resync_from_primary), color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.requestDeviceEnrollment() }.padding(vertical = 8.dp),
            )
        } else if (!enabled) {
            Text(
                stringResource(R.string.settings_make_primary_device), color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { HavenNet.enableDeviceRoster(); enabled = DeviceRosterManager.isEnabled() }.padding(vertical = 8.dp),
            )
            Text(
                if (authorized) stringResource(R.string.settings_resync_from_primary) else stringResource(R.string.settings_make_secure_linked_device),
                color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.requestDeviceEnrollment() }.padding(vertical = 8.dp),
            )
        } else {
            // Primary only (holds the seed): link a NEW device without ever sending it the seed. It gets
            // its own revocable device key + a granted sync key (seed-drop S4).
            Text(
                stringResource(R.string.settings_link_new_device_arrow), color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { HavenNet.enrollMintTicket() }.padding(vertical = 8.dp),
            )
            Text(
                stringResource(R.string.settings_not_primary_device), color = Color(0xFFF87171), fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { HavenNet.stepDownAsPrimary(); enabled = DeviceRosterManager.isEnabled() }.padding(vertical = 8.dp),
            )
        }
    }

    // PRIMARY: the `haven-enroll:` QR for a new device to scan (single-use, short expiry — treat like an
    // authorization credential). Sits over the card while a ticket is live.
    if (ticketUri.isNotEmpty()) {
        FullScreenOverlay(onDismiss = { HavenNet.cancelSeedlessTicket() }) {
            val qr = rememberQr(ticketUri)
            Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.common_done), color = HavenTheme.textSecondary,
                    modifier = Modifier.align(Alignment.End).clickable { HavenNet.cancelSeedlessTicket() }.padding(8.dp))
                Spacer(Modifier.height(12.dp))
                BrandText(stringResource(R.string.settings_link_new_device_title), fontSize = 22)
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.settings_enroll_qr_instructions),
                    color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(20.dp))
                qr?.let { Image(it, stringResource(R.string.settings_enroll_qr_desc),
                    Modifier.size(260.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF101018)).padding(8.dp)) }
            }
        }
    }

    // PRIMARY: a new device proved ticket possession — confirm before issuing its credential + grant.
    enrollPrompt?.let { p ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { HavenNet.dismissSeedlessEnroll() }, containerColor = HavenTheme.card,
            title = { Text(stringResource(R.string.settings_link_device_confirm_title, p.name), color = HavenTheme.textPrimary) },
            text = { Text(stringResource(R.string.settings_link_device_confirm_text, p.name), color = HavenTheme.textSecondary) },
            confirmButton = {
                Text(stringResource(R.string.settings_link_device_button), color = HavenTheme.pink,
                    modifier = Modifier.clickable { HavenNet.confirmSeedlessEnroll() }.padding(8.dp))
            },
            dismissButton = {
                Text(stringResource(R.string.common_not_now), color = HavenTheme.textSecondary,
                    modifier = Modifier.clickable { HavenNet.dismissSeedlessEnroll() }.padding(8.dp))
            },
        )
    }

    revokeTarget?.let { t ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { revokeTarget = null }, containerColor = HavenTheme.card,
            title = { Text(stringResource(R.string.settings_revoke_device_confirm_title, t.name), color = HavenTheme.textPrimary) },
            text = { Text(stringResource(R.string.settings_revoke_device_confirm_text), color = HavenTheme.textSecondary) },
            confirmButton = {
                Text(stringResource(R.string.settings_revoke_device_button), color = Color(0xFFF87171),
                    modifier = Modifier.clickable { HavenNet.revokeDevice(t.nodeHex); revokeTarget = null }.padding(8.dp))
            },
            dismissButton = {
                Text(stringResource(R.string.common_cancel), color = HavenTheme.textSecondary, modifier = Modifier.clickable { revokeTarget = null }.padding(8.dp))
            },
        )
    }
}
