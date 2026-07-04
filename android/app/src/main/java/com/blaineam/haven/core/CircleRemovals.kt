package com.blaineam.haven.core

import android.content.Context

/**
 * Members the user has EXPLICITLY removed from a circle. Recorded so the removal (a) propagates to the
 * user's OTHER devices via self-sync as intentional `removal:<circleId>|<hex>` records — NOT inferred
 * from a peer's absence — and (b) survives an additive re-sync: [SelfSyncCoordinator] will not re-add
 * anyone listed here (anti-reinflation), and their posts/calls in that circle are filtered out.
 *
 * A removal is LWW per entry, never undone by absence: a DELIBERATE re-add moves the entry to the
 * CLEARED set, which self-sync publishes as `removal:<key> = 0` — an explicit newer write that
 * supersedes the stale removal record on the user's other devices. (Grow-only removals re-severed a
 * re-added friend on every sibling sync pass, forever.) Mirrors iOS `ConnectionsStore.circleRemovals`.
 */
object CircleRemovals {
    private const val PREFS = "haven.circleRemovals"
    private const val KEY = "removed" // Set<"circleId|hex">
    private const val KEY_CLEARED = "cleared" // Set<"circleId|hex"> — deliberately re-added
    private lateinit var appContext: Context

    fun init(ctx: Context) { appContext = ctx.applicationContext }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun key(circleId: String, hex: String) = "$circleId|${hex.lowercase()}"

    /** Every removal as "circleId|hex". */
    fun all(): Set<String> = prefs.getStringSet(KEY, emptySet())?.toSet() ?: emptySet()

    /** Every deliberately-cleared removal as "circleId|hex" (published as removal:<key> = 0). */
    fun allCleared(): Set<String> = prefs.getStringSet(KEY_CLEARED, emptySet())?.toSet() ?: emptySet()

    fun add(circleId: String, hex: String) {
        if (hex.isBlank()) return
        val k = key(circleId, hex)
        val s = all().toMutableSet()
        val c = allCleared().toMutableSet()
        val changed = s.add(k) or c.remove(k)
        if (changed) prefs.edit().putStringSet(KEY, s).putStringSet(KEY_CLEARED, c).apply()
    }

    fun contains(circleId: String, hex: String): Boolean = all().contains(key(circleId, hex))

    /** Re-allow a member into a circle — ONLY when the user deliberately re-adds them. Recorded in the
     *  CLEARED set even if THIS device holds no removal (a sibling might), so the clear propagates.
     *  Mirrors iOS `ConnectionsStore.clearCircleRemoval`. */
    fun remove(circleId: String, hex: String) {
        if (hex.isBlank()) return
        val k = key(circleId, hex)
        val s = all().toMutableSet()
        val c = allCleared().toMutableSet()
        val changed = s.remove(k) or c.add(k)
        if (changed) prefs.edit().putStringSet(KEY, s).putStringSet(KEY_CLEARED, c).apply()
    }

    /** The removed member hexes for one circle. */
    fun forCircle(circleId: String): Set<String> =
        all().asSequence().filter { it.startsWith("$circleId|") }.map { it.substringAfter("|") }.toSet()

    /** True if [hex] is removed from ANY circle (used to hide their posts feed-wide). */
    fun isRemovedAnywhere(hex: String): Boolean {
        val h = "|${hex.lowercase()}"
        return all().any { it.endsWith(h) }
    }

    fun clear() { runCatching { prefs.edit().clear().apply() } }
}
