package com.blaineam.haven.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenCore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore
import com.blaineam.haven.core.loadAvatarB64
import com.blaineam.haven.core.restartApp

/**
 * First-run welcome, gating the app (parity with the iOS OnboardingView). The identity is
 * generated lazily by HavenCore the moment we touch it; here we collect a name, a photo and an
 * emoji so the circle has a friendly face.
 */
@Composable
fun OnboardingScreen(onDone: (name: String, emoji: String, avatarB64: String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var emoji by remember { mutableStateOf("🌅") }
    var avatarB64 by remember { mutableStateOf("") }
    val emojis = listOf("🌅", "🌙", "⭐️", "🔥", "🌊", "🌸", "🦊", "🐦", "🍃", "💜")

    val context = LocalContext.current
    val avatarBmp = remember(avatarB64) {
        if (avatarB64.isBlank()) null else runCatching {
            val b = android.util.Base64.decode(avatarB64, android.util.Base64.DEFAULT)
            android.graphics.BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap()
        }.getOrNull()
    }
    // The system photo picker — no storage permission, so first run never asks for one.
    val pickAvatar = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) loadAvatarB64(context, uri)?.let { avatarB64 = it }
    }
    var showLink by remember { mutableStateOf(false) }
    var showScan by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var linkError by remember { mutableStateOf(false) }
    // Seedless link (seed-drop S4): join an existing account WITHOUT copying the master seed.
    var showSeedless by remember { mutableStateOf(false) }
    var showSeedlessScan by remember { mutableStateOf(false) }
    var enrollCode by remember { mutableStateOf("") }
    var enrollError by remember { mutableStateOf(false) }
    val linking by HavenNet.seedlessLinking

    // Adopt an existing identity from a `haven-seed:` transfer code (paste or QR), then restart
    // into it. Returns false if the code is invalid. Profile name/emoji arrive via device sync.
    val adopt = { text: String ->
        val ok = text.trim().startsWith("haven-seed:") &&
            HavenCore.get(context).importSeed(text.trim())
        if (ok) {
            ProfileStore.get(context).markOnboarded()
            HavenNet.reset()
            restartApp(context)
        }
        ok
    }

    // Seedless link: bring up the transient engine + node (under a throwaway identity discarded on
    // enrollment), then send the frame-28 request. The grant handler flips this device into seedless
    // mode and restarts. Returns false if the text isn't a `haven-enroll:` ticket.
    val beginSeedless = { text: String ->
        HavenNet.init(context)
        HavenNet.start()
        HavenNet.beginSeedlessLink(text.trim())
    }

    HavenBackground {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            ConstellationMark(Modifier.size(96.dp))
            Spacer(Modifier.height(20.dp))
            BrandText("Haven", fontSize = 40)
            Spacer(Modifier.height(10.dp))
            Text(
                "Your friends and your family. That's the whole product.",
                color = HavenTheme.textSecondary,
                textAlign = TextAlign.Center,
                fontSize = 15.sp,
            )
            Spacer(Modifier.height(28.dp))

            // Your face: a real photo if you want one, the emoji otherwise (iOS parity).
            Box(
                Modifier.size(96.dp).clip(CircleShape).background(HavenTheme.brand)
                    .clickable { pickAvatar.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                contentAlignment = Alignment.Center,
            ) {
                if (avatarBmp != null) {
                    Image(avatarBmp, "Your photo", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                } else {
                    Text(emoji, fontSize = 44.sp)
                }
            }
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = {
                    pickAvatar.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }) {
                    Text(if (avatarB64.isBlank()) "Add a photo" else "Change photo", color = HavenTheme.pink, fontSize = 14.sp)
                }
                if (avatarB64.isNotBlank()) {
                    TextButton(onClick = { avatarB64 = "" }) {
                        Text("Remove", color = HavenTheme.textSecondary, fontSize = 14.sp)
                    }
                }
            }
            Spacer(Modifier.height(14.dp))

            Text(
                if (avatarB64.isBlank()) "Or pick an emoji" else "Emoji (shown if you remove your photo)",
                color = HavenTheme.textSecondary,
                fontSize = 13.sp,
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Start,
            )
            Spacer(Modifier.height(8.dp))
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                items(emojis.size) { i ->
                    val e = emojis[i]
                    val selected = e == emoji
                    Box(
                        Modifier
                            .size(48.dp)
                            .border(
                                width = if (selected) 2.dp else 0.dp,
                                color = if (selected) HavenTheme.pink else Color.Transparent,
                                shape = CircleShape,
                            )
                            .clickable { emoji = e },
                        contentAlignment = Alignment.Center,
                    ) { Text(e, fontSize = 26.sp) }
                }
            }

            Spacer(Modifier.height(24.dp))
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Your name") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink,
                    cursorColor = HavenTheme.pink,
                    focusedLabelColor = HavenTheme.pink,
                ),
            )
            Spacer(Modifier.height(28.dp))
            // THREE paths, each named for what it DOES. The two alternatives used to be small
            // secondary links under an unlabelled default, so the ADDITIVE choice (another device)
            // and the MIGRATING one (move the account) read as the same kind of thing, and neither
            // said what happens to the device you already have. That is the part people get wrong,
            // so each now states its consequence — in the same words the Devices screen uses, so the
            // two screens can be followed side by side.
            BrandButton(
                text = "I'm new to Haven",
                enabled = name.isNotBlank(),
            ) { onDone(name.trim(), emoji, avatarB64) }
            Spacer(Modifier.height(4.dp))
            Text(
                "Create a brand-new identity on this device, with the name and photo above.",
                color = HavenTheme.textSecondary, textAlign = TextAlign.Center, fontSize = 12.sp,
            )
            Spacer(Modifier.height(14.dp))
            OnboardingChoice(
                title = "Add this as another of my devices",
                subtitle = "Use my existing Haven account here too. My other device stays signed in, and both stay in sync.",
            ) { enrollCode = ""; enrollError = false; showSeedless = true }
            Spacer(Modifier.height(10.dp))
            OnboardingChoice(
                title = "Move my account to this device",
                subtitle = "Bring my identity here with a transfer code — for replacing a device, not adding one.",
            ) { code = ""; linkError = false; showLink = true }
            Spacer(Modifier.height(16.dp))
            Text(
                "No phone number. No email. Your keys never leave this device.",
                color = HavenTheme.textSecondary,
                textAlign = TextAlign.Center,
                fontSize = 12.sp,
            )
        }

        // Link an existing identity — paste the transfer code, or scan the other device's QR.
        if (showLink) {
            AlertDialog(
                onDismissRequest = { showLink = false },
                title = { Text("Link an existing identity") },
                text = {
                    Column {
                        Text(
                            "On your other device open You ▸ Link a new device, then paste the code here or scan its QR.",
                            color = HavenTheme.textSecondary,
                            fontSize = 13.sp,
                        )
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = code,
                            onValueChange = { code = it; linkError = false },
                            label = { Text("haven-seed:…") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = HavenTheme.pink,
                                cursorColor = HavenTheme.pink,
                                focusedLabelColor = HavenTheme.pink,
                            ),
                        )
                        if (linkError) {
                            Spacer(Modifier.height(6.dp))
                            Text("That isn't a valid transfer code.", color = HavenTheme.pink, fontSize = 12.sp)
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { if (!adopt(code)) linkError = true }) {
                        Text("Adopt", color = HavenTheme.pink)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showLink = false; showScan = true }) { Text("Scan QR") }
                },
            )
        }
        if (showScan) {
            FullScreenOverlay(onDismiss = { showScan = false }) {
                QrScannerScreen(
                    onResult = { text -> showScan = false; adopt(text) },
                    onCancel = { showScan = false },
                )
            }
        }

        // Seedless link — scan/paste the `haven-enroll:` code the OTHER device shows.
        if (showSeedless) {
            AlertDialog(
                onDismissRequest = { showSeedless = false },
                title = { Text("Link to your other device") },
                text = {
                    Column {
                        Text(
                            "On your current device: Settings ▸ Identity & devices ▸ Link a new device, then scan the code it shows. This device gets its own revocable key — never your master key.",
                            color = HavenTheme.textSecondary,
                            fontSize = 13.sp,
                        )
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = enrollCode,
                            onValueChange = { enrollCode = it; enrollError = false },
                            label = { Text("haven-enroll:…") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = HavenTheme.pink,
                                cursorColor = HavenTheme.pink,
                                focusedLabelColor = HavenTheme.pink,
                            ),
                        )
                        if (enrollError) {
                            Spacer(Modifier.height(6.dp))
                            Text("That isn't a valid link code.", color = HavenTheme.pink, fontSize = 12.sp)
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        if (beginSeedless(enrollCode)) showSeedless = false else enrollError = true
                    }) { Text("Link", color = HavenTheme.pink) }
                },
                dismissButton = {
                    TextButton(onClick = { showSeedless = false; showSeedlessScan = true }) { Text("Scan QR") }
                },
            )
        }
        if (showSeedlessScan) {
            FullScreenOverlay(onDismiss = { showSeedlessScan = false }) {
                QrScannerScreen(
                    onResult = { text -> showSeedlessScan = false; beginSeedless(text) },
                    onCancel = { showSeedlessScan = false },
                )
            }
        }

        // Waiting for the primary to confirm + send the grant. The grant handler restarts the app into
        // seedless mode; Cancel backs out (re-scannable — never a half-identity).
        if (linking) {
            FullScreenOverlay(onDismiss = { HavenNet.cancelSeedlessLink() }) {
                Column(
                    Modifier.fillMaxSize().padding(28.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    androidx.compose.material3.CircularProgressIndicator(color = HavenTheme.pink)
                    Spacer(Modifier.height(20.dp))
                    BrandText("Linking…", fontSize = 22)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Confirm “link this device” on your other phone. Keep both phones nearby and unlocked.",
                        color = HavenTheme.textSecondary, textAlign = TextAlign.Center, fontSize = 13.sp,
                    )
                    Spacer(Modifier.height(24.dp))
                    TextButton(onClick = { HavenNet.cancelSeedlessLink() }) {
                        Text("Cancel", color = HavenTheme.textSecondary)
                    }
                }
            }
        }
    }
}

/**
 * One onboarding path: what it's called, and — the part that actually prevents mistakes — what it
 * does to the device you already have. A card rather than a text link, so an alternative reads as a
 * real choice next to the primary button instead of fine print under it.
 */
@Composable
private fun OnboardingChoice(title: String, subtitle: String, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(HavenTheme.card)
            .clickable { onClick() }
            .padding(14.dp),
    ) {
        Text(title, color = HavenTheme.textPrimary, fontSize = 15.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold)
        Spacer(Modifier.height(3.dp))
        Text(subtitle, color = HavenTheme.textSecondary, fontSize = 12.sp)
    }
}
