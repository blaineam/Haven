package com.blaineam.haven.core

import android.content.Context
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap

/**
 * Stores contacts' profile cards — a base64 JPEG avatar + emoji, keyed by node id — so the feed,
 * people list, story tray, and profile can show real photo avatars (iOS parity). Avatars ride the
 * already-signed profile card (`verifyProfileCard`); we just persist + decode them here. Lookups
 * accept a full node-id hex OR the short prefix the feed carries (`authorShort`).
 */
object AvatarStore {
    private lateinit var avatars: android.content.SharedPreferences   // idHex -> base64 jpeg
    private lateinit var emojis: android.content.SharedPreferences    // idHex -> emoji
    private val decoded = HashMap<String, ImageBitmap?>()
    val version = mutableStateOf(0)                                   // bump to recompose avatar UI

    fun init(context: Context) {
        if (this::avatars.isInitialized) return
        val c = context.applicationContext
        avatars = c.getSharedPreferences("haven.avatars", Context.MODE_PRIVATE)
        emojis = c.getSharedPreferences("haven.avatar.emoji", Context.MODE_PRIVATE)
    }

    private val ready get() = this::avatars.isInitialized

    /** Record a contact's profile card (from verifyProfileCard / demo). Empty values are ignored. */
    fun put(idHex: String, avatarB64: String, emoji: String) {
        if (!ready) return
        if (avatarB64.isNotBlank()) {
            avatars.edit().putString(idHex, avatarB64).apply(); decoded.remove(idHex)
        }
        if (emoji.isNotBlank()) emojis.edit().putString(idHex, emoji).apply()
        version.value++
    }

    private fun keyFor(idOrShort: String): String? {
        if (!ready || idOrShort.isBlank()) return null
        avatars.all.keys.firstOrNull { it == idOrShort }?.let { return it }
        return avatars.all.keys.firstOrNull { it.startsWith(idOrShort) || idOrShort.startsWith(it) }
    }

    /** The decoded avatar for a full id or short prefix, or null. */
    fun image(idOrShort: String): ImageBitmap? {
        val key = keyFor(idOrShort) ?: return null
        return decoded.getOrPut(key) {
            runCatching {
                val bytes = Base64.decode(avatars.getString(key, ""), Base64.DEFAULT)
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            }.getOrNull()
        }
    }

    /** The stored emoji for a full id or short prefix (empty if none). */
    fun emoji(idOrShort: String): String {
        if (!ready) return ""
        val key = emojis.all.keys.firstOrNull { it == idOrShort || it.startsWith(idOrShort) || idOrShort.startsWith(it) } ?: return ""
        return emojis.getString(key, "") ?: ""
    }

    fun clear() {
        if (ready) { avatars.edit().clear().commit(); emojis.edit().clear().commit() }
        decoded.clear(); version.value++
    }
}
