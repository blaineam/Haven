package com.blaineam.haven.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.size
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Smartphone
import com.blaineam.haven.core.DeviceCredentialStore
import com.blaineam.haven.core.DeviceRosterManager
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.RosterDevice
import com.blaineam.haven.core.ProfileStore
import com.blaineam.haven.core.StorageStore
import com.blaineam.haven.core.startOver

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
        "privacy" -> "Privacy & content"; "connection" -> "Connection & relay"
        "relays" -> "Relays"
        "blocked" -> "Blocked people"; "diagnostics" -> "Security & diagnostics"
        "identity" -> "Identity & devices"; else -> "Settings"
    }

    val options = listOf(0 to "Keep forever", 7 to "After 1 week", 30 to "After 1 month", 90 to "After 3 months", 365 to "After 1 year")

    HavenBackground {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { if (section != null) section = null else onBack() },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = HavenTheme.textPrimary)
                }
                Spacer(Modifier.size(6.dp))
                BrandText(sectionTitle, fontSize = 24)
            }

            Spacer(Modifier.height(20.dp))

            // ── Top-level category list (iOS-style) ──
            if (section == null) {
                SettingsCategory("Privacy & content", "Auto-delete, save to Photos, optimize") { section = "privacy" }
                SettingsCategory("Relays", "Where your circles' sealed posts live for offline delivery") { section = "relays" }
                SettingsCategory("Connection & relay", "Background, nearby, storage") { section = "connection" }
                SettingsCategory("Identity & devices", "Your id, move/restore your account, start over") { section = "identity" }
                SettingsCategory("Security & diagnostics", "Safety words, privacy check, encryption") { section = "diagnostics" }
                SettingsCategory("Blocked people", if (HavenNet.blocked.isEmpty()) "No one blocked" else "${HavenNet.blocked.size} blocked") { section = "blocked" }
            }

            if (section == "privacy") {
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Auto-delete posts", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Old posts disappear on their own — locally and for everyone you share with.",
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
                Text("Photos", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Keep a copy in your gallery (Pictures/Haven).", color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                SettingSwitch("Save my posts to Photos", profile.saveMyPosts) { profile.saveMyPosts = it }
                SettingSwitch("Save others' posts to Photos", profile.saveOthersPosts) { profile.saveOthersPosts = it }
                SettingSwitch("Auto-optimize media (smaller, faster)", profile.autoOptimize) { profile.autoOptimize = it }
            }
            }  // end Privacy

            // ── Relays hub (Settings ▸ Relays) — manage every configured relay ──
            if (section == "relays") {
                RelaysHubCard(context)
            }

            if (section == "connection") {
            StorageSyncCard(context)

            Spacer(Modifier.height(16.dp))
            MediaCleanupCard()

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Stay connected", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Keep Haven connected in the background for instant posts, messages and calls — no server, no Google. Uses a little battery and shows an ongoing notification.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                var stayOn by remember { mutableStateOf(com.blaineam.haven.core.ConnectionService.isEnabled(context)) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Real-time connection", color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
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
                Text("Nearby (offline)", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Share with people right next to you over Bluetooth/Wi-Fi — no internet needed.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(8.dp))
                var nearbyOn by remember { mutableStateOf(HavenNet.nearbyWanted()) }
                val nearbyPerms = androidx.activity.compose.rememberLauncherForActivityResult(
                    androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()) { grants ->
                    if (grants.values.all { it }) { HavenNet.enableNearby(); nearbyOn = true }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Nearby sharing", color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
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
                Text("Blocked people", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(6.dp))
                if (HavenNet.blocked.isEmpty()) {
                    Text("No one blocked.", color = HavenTheme.textSecondary, fontSize = 13.sp)
                } else {
                    HavenNet.blocked.forEach { idHex ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(idHex.take(16) + "…", color = HavenTheme.textPrimary, fontSize = 13.sp)
                            Spacer(Modifier.size(8.dp))
                            Text("Unblock", color = HavenTheme.pink, fontSize = 13.sp,
                                modifier = Modifier.clickable { HavenNet.unblock(idHex) })
                        }
                    }
                }
            }

            }  // end Blocked

            if (section == "diagnostics") {
            // Under the hood (identity hex + safety words + crypto).
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Under the hood", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Your id", color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text(core.nodeIdHex.take(24) + "…", color = HavenTheme.textPrimary, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
                Spacer(Modifier.height(6.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Safety words", color = HavenTheme.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Text(com.blaineam.haven.core.SafetyWords.phrase(core.verificationHex), color = HavenTheme.textPrimary, fontSize = 13.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
                Spacer(Modifier.height(10.dp))
                Text("Haven uses hybrid post-quantum encryption (X25519 + ML-KEM-768, Ed25519 + ML-DSA). Your keys never leave this device.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
            }

            Spacer(Modifier.height(16.dp))
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                BrandButton(text = "Run privacy check") { report = core.runSelfTest() }
                report?.let { r ->
                    Spacer(Modifier.height(14.dp))
                    SettingsCheck("Identity is yours", r.identityOk)
                    SettingsCheck("Your stuff is locked (seal → open)", r.hybridKemOk)
                    SettingsCheck("Messages are signed", r.signatureOk)
                    SettingsCheck("Invite links are safe", r.linkOk)
                    Spacer(Modifier.height(8.dp))
                    Text(r.summary, color = if (r.allOk) Color(0xFF34D399) else Color(0xFFF87171),
                        fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                }
            }

            }  // end Diagnostics

            if (section == "identity") {
            // Move to another device / restore here.
            Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
                Text("Your identity", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text("Move your account to a new phone, or restore it here. Your keys never touch a server.",
                    color = HavenTheme.textSecondary, fontSize = 12.sp)
                Spacer(Modifier.height(10.dp))
                Text("Move to another device →", color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showTransfer = true }.padding(vertical = 8.dp))
                Text("Restore identity here →", color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { showRestore = true }.padding(vertical = 8.dp))
            }

            Spacer(Modifier.height(16.dp))
            AuthorizedDevicesCard()

            Spacer(Modifier.height(24.dp))
            Text("Start over (new identity)", color = Color(0xFFF87171), fontWeight = FontWeight.Medium,
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
                Text("Done", color = HavenTheme.textSecondary, modifier = Modifier.align(Alignment.End).clickable { showTransfer = false }.padding(8.dp))
                Spacer(Modifier.height(12.dp))
                BrandText("Move to another device", fontSize = 22)
                Spacer(Modifier.height(8.dp))
                Text("On your other phone: Settings → Restore identity here → scan this. Keep it private — anyone who scans it becomes you.",
                    color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                Spacer(Modifier.height(20.dp))
                qr?.let { androidx.compose.foundation.Image(it, "Identity transfer QR",
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
            title = { Text("Start over?", color = HavenTheme.textPrimary) },
            text = {
                Text("This permanently erases your identity, your whole circle, and every post on this device. The people you've connected with will no longer recognize you. This can't be undone.",
                    color = HavenTheme.textSecondary)
            },
            confirmButton = {
                TextButton(onClick = { startOver(context) }) {
                    Text("Erase everything", color = Color(0xFFF87171))
                }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel", color = HavenTheme.pink) } },
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

/** Storage housekeeping: run the media orphan sweep on demand and show what it freed.
 *  Parity with iOS Settings ▸ Storage ▸ "Clean up unused media". */
@Composable
private fun MediaCleanupCard() {
    val context = LocalContext.current
    var cleaning by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(cleaning) {
        if (!cleaning) return@LaunchedEffect
        val r = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching { HavenNet.cleanupUnusedMedia() }.getOrDefault(0L to 0)
        }
        result = if (r.second == 0) "Nothing to clean up"
        else "Freed ${android.text.format.Formatter.formatFileSize(context, r.first)} · ${r.second} file${if (r.second == 1) "" else "s"}"
        cleaning = false
    }
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text("Storage", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text("Remove media on this device that no post, message or scheduled send references anymore.",
            color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))
        Text(
            if (cleaning) "Cleaning up…" else "Clean up unused media",
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
        Text("Sync across your devices", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text(
            if (saved.isConfigured)
                "Using your own S3 bucket — your phones, tablets and computers stay in sync with no relay needed."
            else "Add your own S3-compatible bucket so your devices keep your profile, contacts and circles in sync — even with no relay. Credentials never leave this device.",
            color = HavenTheme.textSecondary, fontSize = 12.sp,
        )
        Spacer(Modifier.height(12.dp))

        StorageField("Endpoint (e.g. https://s3.us-east-1.amazonaws.com)", endpoint) { endpoint = it }
        Spacer(Modifier.height(8.dp))
        StorageField("Region (e.g. us-east-1)", region) { region = it }
        Spacer(Modifier.height(8.dp))
        StorageField("Bucket", bucket) { bucket = it }
        Spacer(Modifier.height(8.dp))
        StorageField("Access key", accessKey) { accessKey = it }
        Spacer(Modifier.height(8.dp))
        StorageField("Secret key", secretKey, secret = true) { secretKey = it }

        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (saved.isConfigured) "Save changes" else "Save",
                color = if (dirty) HavenTheme.pink else HavenTheme.textSecondary,
                fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = dirty) {
                    StorageStore.save(context, candidate)
                    saved = StorageStore.load(context)
                }.padding(8.dp),
            )
            if (saved.isConfigured) {
                Spacer(Modifier.size(8.dp))
                Text("Remove", color = Color(0xFFF87171), fontSize = 14.sp,
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
    val default = remember(relaysVersion) { HavenNet.defaultRelay() }
    val detail = remember(relaysVersion) { HavenNet.relaysDetail().associate { it.first to (it.second to it.third) } }
    var showAdd by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<String?>(null) }
    var renameText by remember { mutableStateOf("") }

    // This-device relay (the zero-setup path that makes this phone a relay).
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text("This device", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text("Turn this phone into a relay — sealed (unreadable) posts and media live here and re-serve to your circles when someone's been offline. Serves while Haven is open (or in the background if Real-time connection is on).",
            color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))
        val hosting by HavenNet.hosting
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Be a relay on this phone", color = HavenTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
            androidx.compose.material3.Switch(
                checked = hosting,
                onCheckedChange = { on -> if (on) HavenNet.startHosting() else HavenNet.stopHosting() },
                colors = androidx.compose.material3.SwitchDefaults.colors(
                    checkedThumbColor = Color.White, checkedTrackColor = HavenTheme.pink),
            )
        }
    }

    Spacer(Modifier.height(16.dp))

    // Configured relays (active + inactive).
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text(if (entries.isEmpty()) "Configured relays" else "Configured relays (${entries.size})",
            color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        Text("The default relay (★) is inherited by every circle that hasn't picked its own. Removing a relay DEACTIVATES it — its name and circle settings survive so you can turn it back on later. An inactive relay unseen for a week is cleaned up automatically.",
            color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))

        if (entries.isEmpty()) {
            Text("No relays configured yet. Add one below, or flip the toggle above to use this device.",
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

    Spacer(Modifier.height(16.dp))

    // Add relay (Haven node or S3 bucket).
    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { showAdd = !showAdd }.padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("Add relay", color = HavenTheme.pink, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = HavenTheme.pink)
        }
        if (!showAdd) {
            Spacer(Modifier.height(4.dp))
            Text("Add a Haven relay by node id, or bring your own S3 bucket as a store-and-forward relay.",
                color = HavenTheme.textSecondary, fontSize = 12.sp)
        } else {
            Spacer(Modifier.height(10.dp))
            AddRelayForm(context) { showAdd = false }
        }
    }

    if (renaming != null) {
        AlertDialog(
            onDismissRequest = { renaming = null }, containerColor = HavenTheme.card,
            title = { Text("Rename relay", color = HavenTheme.textPrimary) },
            text = {
                androidx.compose.material3.OutlinedTextField(
                    value = renameText, onValueChange = { renameText = it }, singleLine = true,
                    label = { Text("Name") }, modifier = Modifier.fillMaxWidth(),
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
                )
            },
            confirmButton = {
                TextButton(onClick = { renaming?.let { HavenNet.renameRelay(it, renameText) }; renaming = null }) {
                    Text("Save", color = HavenTheme.pink)
                }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancel", color = HavenTheme.textSecondary) } },
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
        !entry.active -> "Deactivated — config kept"
        entry.isS3 -> "S3 bucket · store-and-forward"
        hosted -> "This phone · ${if (reachable) "reachable" else "starting"}"
        reachable -> "Reachable"
        else -> "Unreachable — retrying"
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
                        text = { Text("Rename") }, onClick = { menu = false; onRename() })
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(if (isDefault) "Unset default" else "Make default") },
                        onClick = { menu = false; onSetDefault() })
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("Delete now", color = Color(0xFFF87171)) }, onClick = { menu = false; onDelete() })
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (entry.active) {
                RelayActionChip("Deactivate", HavenTheme.textSecondary, onDeactivate)
            } else {
                RelayActionChip("Reactivate", Color(0xFF34C759), onReactivate)
            }
            if (!isDefault) RelayActionChip("Set default", HavenTheme.pink, onSetDefault)
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
            RelayTypeSeg("Haven relay", !isS3) { isS3 = false }
            RelayTypeSeg("S3 bucket", isS3) { isS3 = true }
        }
        Spacer(Modifier.height(10.dp))
        StorageField("Name (optional)", name) { name = it }
        Spacer(Modifier.height(8.dp))
        SettingSwitch("Make the default for all circles", makeDefault) { makeDefault = it }
        Spacer(Modifier.height(8.dp))

        if (!isS3) {
            // Running your OWN relay (a haven-relay daemon or the Docker relay)? It needs THIS
            // circle's link first; it then prints a node id you paste below. Surface the copy here so
            // the two-step flow is discoverable (parity with iOS AddRelaySheet).
            var linkCopied by remember { mutableStateOf(false) }
            Text(if (linkCopied) "✓ Copied — run: haven-relay run --link …" else "Copy this circle's relay link",
                color = if (linkCopied) Color(0xFF34D399) else HavenTheme.pink, fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable {
                    HavenNet.relayLink()?.let {
                        (context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                            .setPrimaryClip(android.content.ClipData.newPlainText("haven relay link", it))
                        linkCopied = true
                    }
                }.padding(vertical = 6.dp))
            Text("For a haven-relay daemon or the Docker relay: copy this link, start the relay with it, then paste back the node id it prints below.",
                color = HavenTheme.textSecondary, fontSize = 11.sp)
            Spacer(Modifier.height(12.dp))
            StorageField("Relay node id (64 hex)", nodeInput) { nodeInput = it.trim() }
            Spacer(Modifier.height(6.dp))
            Text("Paste the node id printed by a haven-relay daemon, or another device that's acting as a relay. Connects over iroh — a live P2P relay.",
                color = HavenTheme.textSecondary, fontSize = 11.sp)
        } else {
            StorageField("Endpoint (e.g. https://s3.us-east-1.amazonaws.com)", endpoint) { endpoint = it }
            Spacer(Modifier.height(8.dp))
            StorageField("Region", region) { region = it }
            Spacer(Modifier.height(8.dp))
            StorageField("Bucket", bucket) { bucket = it }
            Spacer(Modifier.height(8.dp))
            StorageField("Access key id", accessKey) { accessKey = it }
            Spacer(Modifier.height(8.dp))
            StorageField("Secret access key", secret, secret = true) { secret = it }
            Spacer(Modifier.height(6.dp))
            Text("ⓘ Store-and-forward only: an S3 bucket holds sealed posts & media for offline delivery — it is NOT a live P2P relay (no realtime fan-out). Your secret stays in this device's secure storage, never on any server.",
                color = Color(0xFFFF9500), fontSize = 11.sp)
        }

        Spacer(Modifier.height(12.dp))
        val valid = if (isS3) s3Valid else havenValid
        Text("Add relay", color = if (valid) HavenTheme.pink else HavenTheme.textSecondary,
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
    LaunchedEffect(Unit) { DeviceCredentialStore.refresh() }

    Column(Modifier.fillMaxWidth().havenCard().padding(16.dp)) {
        Text("Authorized devices", color = HavenTheme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(Modifier.height(4.dp))
        val role = when {
            enabled -> "This is your primary device" to "It holds your master key and authorizes or revokes your other devices."
            authorized -> "This is a linked device" to "It holds a copy of your master key and syncs with your primary device, which can revoke it."
            else -> "This device isn’t linked yet" to "Make it your primary, or link it to the device that already is."
        }
        Text(role.first, color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Text(role.second, color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(10.dp))

        if (devices.isEmpty()) {
            Text("No devices linked yet.", color = HavenTheme.textSecondary, fontSize = 13.sp)
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
                            if (d.isPrimary) "Master key" else if (d.isThisDevice) "This device" else "Linked device",
                            color = HavenTheme.textSecondary, fontSize = 11.sp,
                        )
                    }
                    if (!d.isPrimary) {
                        Text(
                            "Revoke", color = Color(0xFFF87171), fontSize = 13.sp,
                            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { revokeTarget = d }.padding(6.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        if (!enabled) {
            Text(
                "Make this my primary device", color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { HavenNet.enableDeviceRoster(); enabled = DeviceRosterManager.isEnabled() }.padding(vertical = 8.dp),
            )
            Text(
                if (authorized) "Re-sync from my primary device" else "Make this a secure linked device",
                color = HavenTheme.pink, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { HavenNet.requestDeviceEnrollment() }.padding(vertical = 8.dp),
            )
        } else {
            Text(
                "This isn’t my primary device", color = Color(0xFFF87171), fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .clickable { HavenNet.stepDownAsPrimary(); enabled = DeviceRosterManager.isEnabled() }.padding(vertical = 8.dp),
            )
        }
    }

    revokeTarget?.let { t ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { revokeTarget = null }, containerColor = HavenTheme.card,
            title = { Text("Revoke “${t.name}”?", color = HavenTheme.textPrimary) },
            text = { Text("Revoking stops this device receiving what you post afterward — which cuts off a device that is simply lost or stolen. It can’t help if someone has extracted your master key from it: linked devices hold a copy of that key, and revoking doesn’t take it back. If that happened, the only remedy is to start a new identity.", color = HavenTheme.textSecondary) },
            confirmButton = {
                Text("Revoke device", color = Color(0xFFF87171),
                    modifier = Modifier.clickable { HavenNet.revokeDevice(t.nodeHex); revokeTarget = null }.padding(8.dp))
            },
            dismissButton = {
                Text("Cancel", color = HavenTheme.textSecondary, modifier = Modifier.clickable { revokeTarget = null }.padding(8.dp))
            },
        )
    }
}
