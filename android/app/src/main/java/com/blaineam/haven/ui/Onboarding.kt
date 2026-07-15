package com.blaineam.haven.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenCore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore
import com.blaineam.haven.core.restartApp

/**
 * First-run welcome, gating the app (parity with the iOS OnboardingView). The identity is
 * generated lazily by HavenCore the moment we touch it; here we collect a name + emoji so the
 * circle has a friendly face.
 */
@Composable
fun OnboardingScreen(onDone: (name: String, emoji: String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var emoji by remember { mutableStateOf("🌅") }
    val emojis = listOf("🌅", "🌙", "⭐️", "🔥", "🌊", "🌸", "🦊", "🐦", "🍃", "💜")

    val context = LocalContext.current
    var showLink by remember { mutableStateOf(false) }
    var showScan by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var linkError by remember { mutableStateOf(false) }

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
            Spacer(Modifier.height(36.dp))

            Text(
                "Pick a face",
                color = HavenTheme.textPrimary,
                fontSize = 14.sp,
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
            BrandButton(
                text = "Create my Haven",
                enabled = name.isNotBlank(),
            ) { onDone(name.trim(), emoji) }
            Spacer(Modifier.height(6.dp))
            TextButton(onClick = { code = ""; linkError = false; showLink = true }) {
                Text("Already use Haven? Link this device", color = HavenTheme.pink, fontSize = 14.sp)
            }
            Spacer(Modifier.height(10.dp))
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
    }
}
