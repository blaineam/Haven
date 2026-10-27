package com.blaineam.haven.core

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.Person
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * Puts Haven's conversations in the Direct Share row at the top of every app's share sheet — the
 * Android sibling of Apple's `ShareSuggestions`.
 *
 * Android draws that row from **sharing shortcuts**: long-lived dynamic shortcuts, tagged with the
 * category declared by the `<share-target>` in `res/xml/shortcuts.xml`. The share sheet is drawn by
 * another process, often while Haven isn't running, so a conversation can only appear there if we
 * published it earlier. The shortcut id IS the `dm:` circle id, which comes straight back to us as
 * `EXTRA_SHORTCUT_ID` when the user taps it (see `MainActivity.ingestShare`).
 *
 * **What leaves Haven's own storage:** the conversation title and the partner's avatar, held by the
 * system's shortcut service so it can draw the row. No message content is published. Three things
 * are never published at all:
 *   * biometric-locked circles (a locked circle hides that it exists, which a tile bearing its name
 *     in every other app's share sheet would not),
 *   * anything while [ProfileStore.shareSuggestions] is off, and
 *   * group *circles* — only DMs, because a share suggestion is a "send to someone" affordance.
 */
object ShareShortcuts {
    /** Must match the `<category>` in `res/xml/shortcuts.xml`. */
    const val CATEGORY = "com.blaineam.haven.category.SHARE_TARGET"

    /** The platform's person-to-person thread category (Assistant reads it to rank conversations). */
    const val CONVERSATION_CATEGORY = "android.shortcut.conversation"

    /** How many conversations we keep published. The row only ever draws a handful, and the system
     *  caps dynamic shortcuts anyway — publishing the whole thread list would just spray names into
     *  the shortcut service for tiles nobody sees. */
    private const val MAX_PUBLISHED = 6

    /**
     * Republish the most recently active conversations, newest first. Cheap and idempotent; call it
     * on resume and after sending a DM.
     *
     * Rank matters: the system shows shortcuts in the order they were pushed, so pushing
     * oldest-first leaves the most recent conversation at the end of the row.
     */
    /** One serial background lane, so overlapping refreshes publish in order. */
    private val refreshLane = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "haven-share-shortcuts").apply { isDaemon = true }
    }

    fun refresh(context: Context) {
        val ctx = context.applicationContext
        // Decodes every DM thread (last activity) through the engine — never on main (ON_RESUME).
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            refreshLane.execute { runCatching { refresh(ctx) } }
            return
        }
        if (!ProfileStore.get(ctx).shareSuggestions) { removeAll(ctx); return }
        val threads = runCatching { HavenNet.engine.circles() }.getOrDefault(emptyList())
            .map { it.id }
            .filter { eligible(it) }
            .map { it to HavenNet.lastActivity(it) }
            .filter { it.second > 0uL }
            .sortedByDescending { it.second }
            .take(MAX_PUBLISHED)
            .map { it.first }

        // Retract anything that dropped out of the top N (deleted, locked, or just gone quiet) —
        // otherwise a conversation the user removed keeps its tile forever.
        val keep = threads.toSet()
        val stale = runCatching { ShortcutManagerCompat.getDynamicShortcuts(ctx) }.getOrDefault(emptyList())
            .map { it.id }
            .filter { it.startsWith("dm:") && it !in keep }
        if (stale.isNotEmpty()) runCatching { ShortcutManagerCompat.removeLongLivedShortcuts(ctx, stale) }

        // Reversed: the LAST push ranks highest, so the newest conversation ends up first.
        for (circleId in threads.reversed()) {
            runCatching { ShortcutManagerCompat.pushDynamicShortcut(ctx, shortcut(ctx, circleId)) }
        }
    }

    /**
     * Make sure [circleId] has a published sharing shortcut and say whether it does. A MessagingStyle
     * notification points at it (`setShortcutId`) so Assistant / Android Auto can resolve "reply to
     * Maya". Honors the same rules as [refresh]: nothing for a locked circle, a non-DM, or while
     * [ProfileStore.shareSuggestions] is off (turning that off erases published names, and a car
     * notification must not re-publish them) — in those cases the notification simply has no shortcut.
     */
    fun ensure(context: Context, circleId: String): Boolean {
        val ctx = context.applicationContext
        if (!eligible(circleId) || !ProfileStore.get(ctx).shareSuggestions) return false
        return runCatching { ShortcutManagerCompat.pushDynamicShortcut(ctx, shortcut(ctx, circleId)) }.isSuccess
    }

    /** Drop one conversation's tile — deleting the thread, or locking its circle, must take it out
     *  of the share sheet too, or the name outlives the thread it belonged to. */
    fun remove(context: Context, circleId: String) {
        val ctx = context.applicationContext
        runCatching { ShortcutManagerCompat.removeLongLivedShortcuts(ctx, listOf(circleId)) }
    }

    /** Erase every conversation we've published (setting turned off, or the account was wiped). */
    fun removeAll(context: Context) {
        val ctx = context.applicationContext
        runCatching { ShortcutManagerCompat.removeAllDynamicShortcuts(ctx) }
    }

    private fun eligible(circleId: String): Boolean =
        circleId.startsWith("dm:") && !CircleLock.isLocked(circleId)

    private fun shortcut(context: Context, circleId: String): ShortcutInfoCompat {
        val title = HavenNet.dmPartnerName(circleId)
        val others = HavenNet.dmMemberHexes(circleId).filter { !it.equals(HavenNet.nodeIdHex, true) }
        val people = others.map { hex ->
            Person.Builder()
                .setName(HavenNet.contacts.firstOrNull { it.idHex.equals(hex, true) }?.name ?: title)
                .setKey(hex)
                .apply { icon(hex)?.let { setIcon(it) } }
                .build()
        }
        // Tapping the shortcut from the launcher (rather than from a share) opens the thread — the
        // same `haven://m/<circleId>` route a notification tap uses.
        val open = Intent(Intent.ACTION_VIEW, Uri.parse("haven://m/$circleId"))
            .setPackage(context.packageName)
        // What Assistant may call this conversation: "Blaine" and "Blaine Miller" both reach it, so
        // "send a message to Blaine on Haven" resolves to this shortcut and hands us its id.
        val spoken = (people.mapNotNull { it.name?.toString() } + title)
            .flatMap { AssistantRoute.recipientNames(it) }.distinct()
        return ShortcutInfoCompat.Builder(context, circleId)
            .setShortLabel(title)
            .setLongLabel(title)
            .setLongLived(true)                 // required: the system keeps it past a cache refresh
            // CATEGORY matches <share-target> in res/xml/shortcuts.xml; the conversation category and
            // setIsConversation mark it as a person-to-person thread for Assistant and the share sheet.
            .setCategories(setOf(CATEGORY, CONVERSATION_CATEGORY))
            .setIsConversation()
            .setLocusId(LocusIdCompat(circleId))
            .setPersons(people.toTypedArray())
            .setIcon(icon(others.firstOrNull().orEmpty()) ?: fallbackIcon(context))
            .setIntent(open)
            .apply {
                if (spoken.isNotEmpty()) {
                    addCapabilityBinding(AssistantRoute.CAPABILITY_CREATE_MESSAGE, AssistantRoute.PARAM_RECIPIENT_NAME, spoken)
                }
            }
            .build()
    }

    /** A contact's avatar as a shortcut icon, or null when they haven't shared one. */
    private fun icon(hex: String): IconCompat? {
        if (hex.isBlank()) return null
        val bmp = AvatarStore.bitmap(hex) ?: return null
        return runCatching { IconCompat.createWithAdaptiveBitmap(bmp) }.getOrNull()
    }

    /** The app icon, for a conversation with no photo — a tile with no image at all reads as broken. */
    private fun fallbackIcon(context: Context): IconCompat =
        IconCompat.createWithResource(context, com.blaineam.haven.R.mipmap.ic_launcher)
}
