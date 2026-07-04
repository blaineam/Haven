package com.blaineam.haven.core

import android.content.Context

/**
 * Members the user has EXPLICITLY removed from a circle. Recorded so the removal (a) propagates to the
 * user's OTHER devices via self-sync as intentional `removal:<circleId>|<hex>` records — NOT inferred
 * from a peer's absence — and (b) survives an additive re-sync: [SelfSyncCoordinator] will not re-add
 * anyone listed here (anti-reinflation), and their posts/calls in that circle are filtered out.
 *
 * Severing is grow-only: it is never undone just because another device still lists the member. Mirrors
 * the iOS `ConnectionsStore.circleRemovals`.
 */
object CircleRemovals {
    private const val PREFS = "haven.circleRemovals"
    private const val KEY = "removed" // Set<"circleId|hex">
    private lateinit var appContext: Context

    fun init(ctx: Context) { appContext = ctx.applicationContext }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun key(circleId: String, hex: String) = "$circleId|${hex.lowercase()}"

    /** Every removal as "circleId|hex". */
    fun all(): Set<String> = prefs.getStringSet(KEY, emptySet())?.toSet() ?: emptySet()

    fun add(circleId: String, hex: String) {
        if (hex.isBlank()) return
        val s = all().toMutableSet()
        if (s.add(key(circleId, hex))) prefs.edit().putStringSet(KEY, s).apply()
    }

    fun contains(circleId: String, hex: String): Boolean = all().contains(key(circleId, hex))

    /** Re-allow a member into a circle (clears the removal) — ONLY when the user deliberately re-adds
     *  them. Mirrors iOS `ConnectionsStore.clearCircleRemoval`. */
    fun remove(circleId: String, hex: String) {
        val s = all().toMutableSet()
        if (s.remove(key(circleId, hex))) prefs.edit().putStringSet(KEY, s).apply()
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
