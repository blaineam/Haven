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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore

/** Edit your business card — name, emoji, bio (parity with the iOS EditProfileSheet). */
@Composable
fun EditProfileScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.get(context) }
    var name by remember { mutableStateOf(profile.displayName) }
    var bio by remember { mutableStateOf(profile.bio) }
    var link by remember { mutableStateOf(profile.link) }
    var emoji by remember { mutableStateOf(profile.emoji) }
    var avatarB64 by remember { mutableStateOf(profile.avatarB64) }
    val emojis = listOf("🌅", "🌙", "⭐️", "🔥", "🌊", "🌸", "🦊", "🐦", "🍃", "💜", "🐺", "🎧")
    val avatarBmp = remember(avatarB64) {
        if (avatarB64.isBlank()) null else runCatching {
            val b = android.util.Base64.decode(avatarB64, android.util.Base64.DEFAULT)
            android.graphics.BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap()
        }.getOrNull()
    }
    val pickAvatar = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) com.blaineam.haven.core.loadAvatarB64(context, uri)?.let { avatarB64 = it }
    }

    HavenBackground {
        Column(Modifier.fillMaxSize().imePadding().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).clip(CircleShape).clickable { onDone() },
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.common_back), tint = HavenTheme.textPrimary)
                }
                Spacer(Modifier.size(6.dp))
                BrandText(stringResource(R.string.profile_title), fontSize = 24)
            }
            Spacer(Modifier.height(20.dp))

            // Photo avatar (tap to choose) with an emoji fallback below.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(72.dp).clip(CircleShape).background(HavenTheme.brand)
                    .clickable { pickAvatar.launch(androidx.activity.result.PickVisualMediaRequest(
                        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    contentAlignment = Alignment.Center) {
                    when {
                        avatarBmp != null -> androidx.compose.foundation.Image(avatarBmp, stringResource(R.string.profile_avatar),
                            Modifier.fillMaxSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                        else -> Text(emoji, fontSize = 34.sp)
                    }
                }
                Spacer(Modifier.size(14.dp))
                Column {
                    Text(if (avatarB64.isBlank()) stringResource(R.string.profile_add_photo) else stringResource(R.string.profile_change_photo), color = HavenTheme.pink, fontSize = 14.sp,
                        modifier = Modifier.clickable { pickAvatar.launch(androidx.activity.result.PickVisualMediaRequest(
                            androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly)) })
                    if (avatarB64.isNotBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(stringResource(R.string.common_remove), color = HavenTheme.textSecondary, fontSize = 13.sp,
                            modifier = Modifier.clickable { avatarB64 = "" })
                    }
                }
            }
            Spacer(Modifier.height(18.dp))

            Text(stringResource(R.string.profile_your_face), color = HavenTheme.textSecondary, fontSize = 13.sp)
            Spacer(Modifier.height(8.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(emojis.size) { i ->
                    val e = emojis[i]
                    Box(
                        Modifier.size(48.dp).border(
                            width = if (e == emoji) 2.dp else 0.dp,
                            color = if (e == emoji) HavenTheme.pink else Color.Transparent,
                            shape = CircleShape,
                        ).clickable { emoji = e },
                        contentAlignment = Alignment.Center,
                    ) { Text(e, fontSize = 26.sp) }
                }
            }

            Spacer(Modifier.height(18.dp))
            OutlinedTextField(
                value = name, onValueChange = { name = it }, label = { Text(stringResource(R.string.profile_name)) },
                singleLine = true, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = bio, onValueChange = { bio = it }, label = { Text(stringResource(R.string.profile_bio)) },
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), maxLines = 3,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = link, onValueChange = { link = it }, label = { Text(stringResource(R.string.profile_link)) }, singleLine = true,
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = HavenTheme.pink, cursorColor = HavenTheme.pink, focusedLabelColor = HavenTheme.pink),
            )

            Spacer(Modifier.height(24.dp))
            BrandButton(text = stringResource(R.string.common_save), enabled = name.isNotBlank()) {
                profile.displayName = name.trim()
                profile.bio = bio.trim()
                profile.link = link.trim()
                profile.emoji = emoji
                profile.save()
                profile.setAvatar(avatarB64)   // persist + mirror into AvatarStore + re-share
                HavenNet.syncWithContacts()    // re-share the updated business card
                onDone()
            }
        }
    }
}
