package com.blaineam.haven.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet

/**
 * Invite / Add a friend — the Android ConnectView. Show my QR for them to scan, or scan/paste
 * theirs to start the handshake (HavenNet.connectByLink). Parity with iOS ConnectView.
 */
@Composable
fun ConnectScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val uri = remember { HavenNet.inviteUri() }
    val qr = rememberQr(uri)
    var pasted by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }
    var showScanner by remember { mutableStateOf(false) }

    // A haven:// / invite-page link the app was OPENED with (deep link) — prefill and connect
    // immediately, parity with iOS's incomingLink flow.
    LaunchedEffect(Unit) {
        com.blaineam.haven.core.InviteInbox.consume()?.let { link ->
            status = if (HavenNet.connectByLink(link)) "Invite sent — waiting for them to accept."
            else "That didn't look like a Haven invite."
        }
    }

    val camPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) showScanner = true
        else status = "Camera permission is needed to scan."
    }
    fun launchScanner() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
            showScanner = true
        else camPermission.launch(Manifest.permission.CAMERA)
    }

    if (showScanner) {
        QrScannerScreen(
            onResult = { text ->
                showScanner = false
                status = if (HavenNet.connectByLink(text)) "Invite sent — waiting for them to accept."
                else "That didn't look like a Haven invite."
            },
            onCancel = { showScanner = false },
        )
        return
    }

    HavenBackground {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(8.dp))
            BrandText("Add a friend", fontSize = 26)
            Spacer(Modifier.height(6.dp))
            Text(
                "Have them scan this, or scan theirs. Your keys never leave your phone.",
                color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(20.dp))

            // My QR.
            Column(
                Modifier.fillMaxWidth().havenCard().padding(18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                if (qr != null) {
                    Image(
                        bitmap = qr,
                        contentDescription = "Your Haven invite QR code",
                        modifier = Modifier.size(240.dp).clip(RoundedCornerShape(12.dp))
                            .background(Color(0xFF101018)).padding(8.dp),
                    )
                }
                Spacer(Modifier.height(10.dp))
                Text(uri, color = HavenTheme.textSecondary, fontSize = 11.sp, textAlign = TextAlign.Center, maxLines = 2)
            }

            Spacer(Modifier.height(20.dp))
            BrandButton(text = "Scan their QR") { launchScanner() }

            Spacer(Modifier.height(16.dp))
            OutlinedTextField(
                value = pasted,
                onValueChange = { pasted = it },
                label = { Text("…or paste an invite link") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink,
                    cursorColor = HavenTheme.pink,
                    focusedLabelColor = HavenTheme.pink,
                ),
            )
            if (pasted.isNotBlank()) {
                Spacer(Modifier.height(10.dp))
                BrandButton(text = "Connect") {
                    status = if (HavenNet.connectByLink(pasted)) "Invite sent — waiting for them to accept."
                    else "That didn't look like a Haven invite."
                    pasted = ""
                }
            }

            status?.let {
                Spacer(Modifier.height(14.dp))
                Text(it, color = HavenTheme.pink, fontSize = 13.sp, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.height(24.dp))
            Text("Done", color = HavenTheme.textSecondary, fontSize = 14.sp,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onDone() }.padding(8.dp))
        }
    }
}
