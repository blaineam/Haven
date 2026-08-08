package com.blaineam.haven.ui

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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.blaineam.haven.R
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.Contact
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.SafetyWords

/**
 * Your circle — see who's in it and manage them (message, block). The Android counterpart of the
 * iOS CircleView. Reached from the You tab.
 */
@Composable
fun PeopleScreen(onAddFriend: () -> Unit, onClose: () -> Unit) {
    val contacts = HavenNet.contacts
    var dm by remember { mutableStateOf<Pair<String, Contact>?>(null) }
    var confirmBlock by remember { mutableStateOf<Contact?>(null) }
    var confirmRemove by remember { mutableStateOf<Contact?>(null) }

    val thread = dm
    if (thread != null) {
        DmThread(circleId = thread.first, partner = thread.second, onBack = { dm = null })
        return
    }

    HavenBackground {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 16.dp, top = 14.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { onClose() }, contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.common_back), tint = HavenTheme.textPrimary)
                }
                Spacer(Modifier.size(4.dp))
                BrandText(stringResource(R.string.people_title), fontSize = 24)
                Spacer(Modifier.weight(1f))
                Text(stringResource(R.string.people_invite), color = HavenTheme.pink, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onAddFriend() }.padding(8.dp))
            }

            if (contacts.isEmpty()) {
                Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center) {
                    Text(stringResource(R.string.people_empty_title), color = HavenTheme.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))
                    Text(stringResource(R.string.people_empty_body),
                        color = HavenTheme.textSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
                }
            } else {
                LazyColumn(contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(contacts, key = { it.idHex }) { c ->
                        Row(Modifier.fillMaxWidth().havenCard().padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                            HavenAvatar(c.idHex, c.name, 44.dp)
                            Spacer(Modifier.size(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(c.name, color = HavenTheme.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                                Text(SafetyWords.phrase(c.verifyHex), color = HavenTheme.textSecondary, fontSize = 11.sp, maxLines = 1)
                            }
                            Box(Modifier.size(40.dp).clip(CircleShape).clickable { dm = HavenNet.startDm(c) to c },
                                contentAlignment = Alignment.Center) {
                                Icon(Icons.Filled.Chat, stringResource(R.string.people_message), tint = HavenTheme.pink)
                            }
                            Text(stringResource(R.string.common_remove), color = HavenTheme.textSecondary, fontSize = 13.sp,
                                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { confirmRemove = c }.padding(8.dp))
                            Text(stringResource(R.string.people_block), color = Color(0xFFF87171), fontSize = 13.sp,
                                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { confirmBlock = c }.padding(8.dp))
                        }
                    }
                }
            }
        }
    }

    confirmBlock?.let { c ->
        AlertDialog(
            onDismissRequest = { confirmBlock = null },
            containerColor = HavenTheme.card,
            title = { Text(stringResource(R.string.people_block_confirm_title, c.name), color = HavenTheme.textPrimary) },
            text = { Text(stringResource(R.string.people_block_confirm_body),
                color = HavenTheme.textSecondary) },
            confirmButton = { TextButton(onClick = { HavenNet.block(c.idHex); confirmBlock = null }) {
                Text(stringResource(R.string.people_block), color = Color(0xFFF87171)) } },
            dismissButton = { TextButton(onClick = { confirmBlock = null }) { Text(stringResource(R.string.common_cancel), color = HavenTheme.pink) } },
        )
    }

    confirmRemove?.let { c ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            containerColor = HavenTheme.card,
            title = { Text(stringResource(R.string.people_remove_confirm_title, c.name), color = HavenTheme.textPrimary) },
            text = { Text(stringResource(R.string.people_remove_confirm_body),
                color = HavenTheme.textSecondary) },
            confirmButton = { TextButton(onClick = { HavenNet.removeFromCircle(c.idHex); confirmRemove = null }) {
                Text(stringResource(R.string.common_remove), color = HavenTheme.pink) } },
            dismissButton = { TextButton(onClick = { confirmRemove = null }) { Text(stringResource(R.string.common_cancel), color = HavenTheme.pink) } },
        )
    }
}
