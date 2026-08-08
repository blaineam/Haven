package com.blaineam.haven.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.R
import com.blaineam.haven.core.HavenCore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.SafetyWords
import uniffi.haven_ffi.LinkInfo
import uniffi.haven_ffi.parseLink

/**
 * Invite / Add a friend — the Android ConnectView. Show my QR for them to scan, or scan/paste
 * theirs to start the handshake. Parity with iOS ConnectView.
 *
 * Both halves surface SafetyWords, because comparing them out loud IS the out-of-band check that
 * defeats a MITM on the invite — it only works if it happens HERE, at the moment of adding, not
 * buried in Settings. So a resolved link is never added until the user has seen the other side's
 * words and confirmed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectScreen(initialLink: String? = null, onDone: () -> Unit) {
    val context = LocalContext.current
    val core = remember { HavenCore.get(context) }
    val uri = remember { HavenNet.inviteUri() }
    val qr = rememberQr(uri)
    var mode by remember { mutableIntStateOf(0) }
    var pasted by remember { mutableStateOf("") }
    var found by remember { mutableStateOf<LinkInfo?>(null) }
    var foundLink by remember { mutableStateOf("") }   // the RAW link — carries the ?d= dial hints
    var added by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var showScanner by remember { mutableStateOf(false) }

    // Hoisted here (composable scope) because `lookup` and the permission/onAdd callbacks below are
    // plain non-composable lambdas — stringResource can't be called from inside them.
    val invalidLinkMsg = stringResource(R.string.connect_invalid_link)
    val cameraPermissionMsg = stringResource(R.string.connect_camera_permission_needed)
    val connectFailedMsg = stringResource(R.string.connect_start_failed)

    // Resolve a link into the confirm step. Deliberately does NOT connect — the user has to read
    // the safety words first.
    fun lookup(link: String) {
        val trimmed = link.trim()
        val info = runCatching { parseLink(trimmed) }.getOrNull()
        if (info == null) {
            problem = invalidLinkMsg
        } else {
            problem = null
            foundLink = trimmed
            found = info
        }
    }

    // A haven:// / invite-page link the app was OPENED with (deep link), handed down by RootScreen —
    // prefill and resolve, parity with iOS's incomingLink flow (which also stops at the safety-word
    // check). Keyed on the link itself, so a second invite arriving while this sheet is already up
    // re-resolves to the new one instead of leaving the previous card on screen.
    LaunchedEffect(initialLink) {
        if (!initialLink.isNullOrBlank()) {
            mode = 1
            lookup(initialLink)
        }
    }

    val camPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) showScanner = true
        else problem = cameraPermissionMsg
    }
    fun launchScanner() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
            showScanner = true
        else camPermission.launch(Manifest.permission.CAMERA)
    }

    if (showScanner) {
        QrScannerScreen(
            onResult = { text -> showScanner = false; mode = 1; lookup(text) },
            onCancel = { showScanner = false },
        )
        return
    }

    HavenBackground {
        Column(
            Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(8.dp))
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf(
                    stringResource(R.string.connect_invite_a_friend),
                    stringResource(R.string.connect_add_a_friend),
                ).forEachIndexed { i, label ->
                    SegmentedButton(
                        selected = mode == i,
                        onClick = { mode = i },
                        shape = SegmentedButtonDefaults.itemShape(index = i, count = 2),
                        colors = SegmentedButtonDefaults.colors(
                            activeContainerColor = HavenTheme.pink.copy(alpha = 0.18f),
                            activeContentColor = HavenTheme.pink,
                            inactiveContentColor = HavenTheme.textSecondary,
                        ),
                    ) { Text(label, fontSize = 13.sp) }
                }
            }
            Spacer(Modifier.height(20.dp))

            if (mode == 0) {
                InviteCard(uri = uri, qr = qr, myWords = SafetyWords.words(core.verificationHex))
            } else {
                val info = found
                when {
                    added -> AddedCard()
                    info != null -> FoundCard(
                        info = info,
                        onAdd = {
                            // Re-parses the same link internally; passing the RAW link keeps the
                            // ?d= device hints that make the first dial reachable.
                            added = HavenNet.connectByLink(foundLink)
                            if (!added) problem = connectFailedMsg
                        },
                        onCancel = { found = null; pasted = ""; foundLink = "" },
                    )
                    else -> AddCard(
                        pasted = pasted,
                        onPastedChange = { pasted = it },
                        problem = problem,
                        onScan = { launchScanner() },
                        onFind = { lookup(pasted) },
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
            // Always offer the way out. This used to be `if (!added)`, which hid Done in the ONE
            // state that has no other action: after "Invite sent" the card is terminal — no cancel,
            // no back — so the only way off this screen was to force-quit the app.
            Text(
                stringResource(R.string.common_done),
                color = if (added) HavenTheme.textPrimary else HavenTheme.textSecondary,
                fontSize = if (added) 16.sp else 14.sp,
                fontWeight = if (added) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onDone() }.padding(8.dp),
            )
        }
    }
}

/** My QR + share link + my own safety words, for the person doing the inviting. */
@Composable
private fun InviteCard(uri: String, qr: androidx.compose.ui.graphics.ImageBitmap?, myWords: List<String>) {
    val context = LocalContext.current
    Column(
        Modifier.fillMaxWidth().havenCard().padding(18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        BrandText(stringResource(R.string.connect_invite_someone_you_trust), fontSize = 22)
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.connect_invite_instructions),
            color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))
        if (qr != null) {
            // encodeQr draws WHITE modules on transparent, so the tile behind it must stay dark in
            // BOTH themes — a light backdrop renders the code invisible, not merely low-contrast.
            Image(
                bitmap = qr,
                contentDescription = stringResource(R.string.connect_qr_content_description),
                modifier = Modifier.size(220.dp).clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFF101018)).padding(8.dp),
            )
        }
        Spacer(Modifier.height(16.dp))
        // The raw URL used to be printed here, truncated to 2 lines — unreadable and unusable.
        BrandButton(text = stringResource(R.string.connect_share_invite_link)) { shareInvite(context, uri) }
        Spacer(Modifier.height(16.dp))
        SafetyCard(
            title = stringResource(R.string.connect_your_safety_words),
            words = myWords,
            note = stringResource(R.string.connect_my_words_note),
        )
    }
}

/** Scan or paste their link. */
@Composable
private fun AddCard(
    pasted: String,
    onPastedChange: (String) -> Unit,
    problem: String?,
    onScan: () -> Unit,
    onFind: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().havenCard().padding(18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        BrandText(stringResource(R.string.connect_add_a_friend), fontSize = 22)
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.connect_add_instructions),
            color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(16.dp))
        BrandButton(text = stringResource(R.string.connect_scan_qr_button)) { onScan() }
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.connect_or), color = HavenTheme.textSecondary, fontSize = 12.sp)
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = pasted,
            onValueChange = onPastedChange,
            label = { Text(stringResource(R.string.connect_paste_link_placeholder)) },
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
        if (problem != null) {
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.connect_problem_prefixed, problem),
                color = HavenTheme.amber, fontSize = 12.sp, textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.height(12.dp))
        BrandButton(text = stringResource(R.string.connect_find_my_friend_button), enabled = pasted.isNotBlank()) { onFind() }
    }
}

/** The verification step: THEIR safety words, before anything is added. */
@Composable
private fun FoundCard(info: LinkInfo, onAdd: () -> Unit, onCancel: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().havenCard().padding(18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        BrandText(stringResource(R.string.connect_found_someone), fontSize = 22)
        Spacer(Modifier.height(16.dp))
        SafetyCard(
            title = stringResource(R.string.connect_check_safety_words),
            words = SafetyWords.words(info.verificationHex),
            note = stringResource(R.string.connect_check_words_note),
        )
        Spacer(Modifier.height(16.dp))
        BrandButton(text = stringResource(R.string.connect_add_to_circle_button)) { onAdd() }
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.connect_name_appears_note),
            color = HavenTheme.textSecondary, fontSize = 12.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(10.dp))
        Text(stringResource(R.string.connect_words_dont_match_cancel), color = HavenTheme.textSecondary, fontSize = 13.sp,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onCancel() }.padding(8.dp))
    }
}

@Composable
private fun AddedCard() {
    Column(
        Modifier.fillMaxWidth().havenCard().padding(18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Filled.CheckCircle, null, tint = Color(0xFF34D399), modifier = Modifier.size(54.dp))
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.connect_invite_sent), color = HavenTheme.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(stringResource(R.string.connect_show_up_online),
            color = HavenTheme.textSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
    }
}

/**
 * The safety-word pills. Mirrors the iOS `safetyCard`: a tinted brand capsule per word, monospaced
 * so an ambiguous glyph can't turn a mismatch into a false match.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SafetyCard(title: String, words: List<String>, note: String) {
    val pill = remember {
        Brush.horizontalGradient(listOf(
            HavenTheme.violet.copy(alpha = 0.18f),
            HavenTheme.brandPink.copy(alpha = 0.18f),
            HavenTheme.amber.copy(alpha = 0.18f),
        ))
    }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
            .background(HavenTheme.background.copy(alpha = if (HavenTheme.isDark) 0.5f else 0.6f))
            .padding(14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, color = HavenTheme.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(10.dp))
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            words.forEach { w ->
                Text(
                    w,
                    color = HavenTheme.textPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(pill)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                )
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(note, color = HavenTheme.textSecondary, fontSize = 12.sp, textAlign = TextAlign.Center)
    }
}

/** Hand the invite link to the system share sheet — iOS's ShareLink. */
internal fun shareInvite(context: Context, uri: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, context.getString(R.string.connect_share_invite_text, uri))
    }
    context.startActivity(Intent.createChooser(send, context.getString(R.string.connect_share_chooser_title)))
}
