package com.blaineam.haven.core

import android.content.Context

/**
 * The Android side of [CarConversations]: reads every DM thread (1:1 and group) with its recent
 * messages and read state. Blocking — boots the engine on a cold start and decodes each thread — so it
 * runs on the car session's background lane, never the car's main thread. Filtering and redaction are NOT
 * done here: [CarConversations.rows] owns them, so they stay covered by plain JVM tests.
 */
object CarConversationSource {
    /** The user's notification-preview level and the "Android Auto messages" switch. */
    data class Settings(val detail: String, val carEnabled: Boolean)

    fun settings(context: Context): Settings {
        val p = ProfileStore.get(context.applicationContext)
        return Settings(
            detail = runCatching { p.notificationDetail }.getOrDefault("full"),
            carEnabled = runCatching { p.androidAutoMessages }.getOrDefault(false),
        )
    }

    /** All DM threads, or null before onboarding (the phone has to finish setup first). */
    fun threads(context: Context): List<CarConversations.Thread>? {
        val app = context.applicationContext
        if (!ProfileStore.get(app).onboarded) return null
        HavenNet.init(app)
        val me = HavenNet.nodeIdHex
        val oneToOne = HavenNet.contacts.toList()
            .filter { !it.idHex.equals(me, true) && !HavenNet.blocked.contains(it.idHex) }
            .map { c -> Triple(HavenNet.dmCircleId(c.idHex), c.name.ifBlank { "Friend" }, c.idHex) }
        val groups = runCatching { HavenNet.groupDmThreads() }.getOrDefault(emptyList())
            .map { (id, title) -> Triple(id, title.ifBlank { "Group" }, null as String?) }
        return (oneToOne + groups).mapNotNull { (circleId, title, hex) ->
            val locked = CircleLock.isLocked(circleId)
            // A locked thread is never decoded at all — nothing about it is read, let alone offered.
            val msgs = if (locked) emptyList() else messagesOf(circleId)
            CarConversations.Thread(circleId, title, hex, isGroup = hex == null, locked = locked, messages = msgs)
        }
    }

    private fun messagesOf(circleId: String): List<CarConversations.Msg> {
        val mark = runCatching { DmRead.watermark(circleId) }.getOrDefault(0UL)
        val name = HavenNet.circleName(circleId)
        return HavenNet.messages(circleId).asSequence()
            .filter { !it.story && !it.unsent }
            .filter { it.body.isNotBlank() || it.media.isNotEmpty() }
            .sortedBy { it.createdAt }
            .toList()
            .takeLast(CarConversations.MAX_MESSAGES)
            .map { item ->
                val hex = HavenNet.contacts.firstOrNull { it.idHex.startsWith(item.authorShort) }?.idHex ?: item.authorShort
                CarConversations.Msg(
                    senderKey = hex,
                    senderName = HavenNet.displayName(item.authorShort).ifEmpty { "Someone" },
                    // PushBanner so a photo / voice note reads as "Sent a photo" instead of nothing.
                    text = PushBanner.forPost(circleId, name, item.body, item.media, story = false).body,
                    timestampMs = item.createdAt.toLong(),
                    fromMe = item.isMe,
                    read = item.isMe || item.createdAt <= mark,
                )
            }
    }
}
