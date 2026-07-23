package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateListOf

/**
 * Up to 6 pinned DM conversations, kept at the top of the Messages list (iMessage-style).
 * Order in the list is pin order; persisted so pins survive relaunch. Mirrors iOS `DMPinStore`.
 *
 * Backed by a Compose [mutableStateListOf] so the Messages screen recomposes on pin/unpin.
 */
object DmPins {
    const val MAX_PINS = 6
    private const val PREFS = "haven.dm"
    private const val KEY = "pinned" // ordered, newline-joined circle ids
    private const val SEP = "\n"     // a DM circle id is "dm:" + hex, so newline never collides
    private lateinit var appContext: Context

    /** Observable pin order (most-important first). Read from a @Composable to react to changes. */
    val pinned = mutableStateListOf<String>()

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        pinned.clear()
        pinned.addAll(load())
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun load(): List<String> =
        prefs.getString(KEY, null)?.split(SEP)?.filter { it.isNotEmpty() } ?: emptyList()
    private fun persist() { prefs.edit().putString(KEY, pinned.joinToString(SEP)).apply() }

    fun isPinned(id: String): Boolean = pinned.contains(id)
    val isFull: Boolean get() = pinned.size >= MAX_PINS

    /** Pin (if room) or unpin a conversation. */
    fun toggle(id: String) {
        if (pinned.remove(id)) { persist(); HavenNet.selfSyncNudge() }
        else if (pinned.size < MAX_PINS) { pinned.add(id); persist(); HavenNet.selfSyncNudge() }
    }

    fun unpin(id: String) { if (pinned.remove(id)) { persist(); HavenNet.selfSyncNudge() } }

    /** Commit a user-chosen order (from a rearrange mode). Keeps only ids that are still pinned. */
    fun setOrder(ids: List<String>) {
        val kept = ids.filter { pinned.contains(it) }
        val rest = pinned.filter { !kept.contains(it) }
        pinned.clear(); pinned.addAll(kept + rest); persist()
        HavenNet.selfSyncNudge()   // local pin reorder — push to my other devices now (LWW)
    }

    /** Adopt the self-synced pin order (plain LWW — the CRDT already resolved which device wrote
     *  last). Applied only when it differs so the stores' observers never ping-pong. */
    fun applySynced(ids: List<String>) {
        val next = ids.filter { it.isNotEmpty() }.distinct().take(MAX_PINS)
        if (next == pinned.toList()) return
        pinned.clear(); pinned.addAll(next); persist()
    }
}
