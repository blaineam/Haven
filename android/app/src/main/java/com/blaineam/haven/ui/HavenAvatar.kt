package com.blaineam.haven.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import com.blaineam.haven.core.AvatarStore
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.ProfileStore

/**
 * A circular avatar that prefers a real photo (from [AvatarStore]), then the person's emoji, then
 * their initial on the brand gradient — the Android counterpart of iOS's `HavenAvatar`.
 *
 * [idOrShort] is a full node-id hex or the short prefix the feed carries (`authorShort`).
 */
@Composable
fun HavenAvatar(idOrShort: String, name: String, size: Dp, isMe: Boolean = false, emojiOverride: String? = null) {
    val v by AvatarStore.version
    val context = LocalContext.current
    // HavenNet's `core` is lateinit, and the You header composes before HavenNet.init() — fall back
    // to the caller's id (which for isMe is the same node id, read straight off HavenCore).
    val key = if (isMe) runCatching { HavenNet.nodeIdHex }.getOrDefault(idOrShort) else idOrShort
    // For my own avatar, ProfileStore is the source of truth (what the You tab shows) — read it
    // directly so the feed/own-post avatar can't diverge from the profile picture.
    val myB64 = if (isMe) ProfileStore.get(context).avatarB64 else ""
    val img = remember(key, v, myB64) {
        if (isMe && myB64.isNotBlank()) decodeAvatarB64(myB64) ?: AvatarStore.image(key)
        else AvatarStore.image(key)
    }
    val emoji = when {
        emojiOverride != null -> emojiOverride
        isMe -> ProfileStore.get(context).emoji
        else -> AvatarStore.emoji(idOrShort)
    }
    Box(Modifier.size(size).clip(CircleShape).background(HavenTheme.brand), contentAlignment = Alignment.Center) {
        when {
            img != null -> Image(img, "Avatar", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            emoji.isNotBlank() -> Text(emoji, fontSize = (size.value * 0.5f).sp)
            // White-on-brand-gradient — never themed.
            else -> Text(name.take(1).uppercase().ifBlank { "•" }, color = Color.White,
                fontWeight = FontWeight.Bold, fontSize = (size.value * 0.4f).sp)
        }
    }
}

private fun decodeAvatarB64(b64: String): androidx.compose.ui.graphics.ImageBitmap? = runCatching {
    val bytes = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
}.getOrNull()
