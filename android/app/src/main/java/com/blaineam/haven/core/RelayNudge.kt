package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateOf

/**
 * The "your circle is big enough to want a relay" nudge — the gate + its dismissal state. Mirrors
 * iOS `RelayNudge.swift`.
 *
 * A circle with a handful of people stops being a two-phones-both-online proposition: the more
 * members, the less often everyone overlaps, and the longer a post waits for its author to come
 * back. A relay is the fix (`relay/README.md`).
 *
 * The bar is deliberately conservative: >2 OTHER members AND the circle has no relay of its OWN.
 * The all-circles default relay does NOT satisfy it — the point is to get this circle a mailbox
 * somebody in it actually runs, and the default is a global setting the user may never revisit.
 *
 * Dismissal is per-circle and final: nothing here ever un-dismisses, so the banner never nags.
 */
object RelayNudge {
    private var prefs: android.content.SharedPreferences? = null

    /** Bumps on dismissal so the feed recomposes and the banner leaves at once. */
    val version = mutableStateOf(0)

    /** Members beyond which a circle is "several people" rather than a pair — >2 OTHERS, i.e. at
     *  least four people counting you. */
    const val CONNECTION_THRESHOLD = 2
    private const val KEY = "dismissed"

    fun init(context: Context) {
        if (prefs != null) return
        prefs = context.applicationContext.getSharedPreferences("haven.relayNudge", Context.MODE_PRIVATE)
    }

    private fun dismissed(): Set<String> = prefs?.getStringSet(KEY, emptySet()) ?: emptySet()

    fun isDismissed(circleId: String): Boolean = dismissed().contains(circleId)

    fun dismiss(circleId: String) {
        prefs?.edit()?.putStringSet(KEY, dismissed() + circleId)?.apply()
        version.value++
    }

    /** Factory reset (mirrors [CircleLock.reset], wired into [startOver]). */
    fun reset() {
        prefs?.edit()?.clear()?.commit()
        version.value++
    }

    /**
     * The single gate the call site needs. True when this circle has grown past a pair, has no relay
     * of its own, isn't already served by this device, and the user hasn't waved it away.
     */
    fun shouldShow(circleId: String): Boolean {
        if (circleId.isEmpty() || isDismissed(circleId)) return false
        // This device relaying for the circle already counts as having one.
        if (HavenNet.hosting.value) return false
        // ACTIVE + explicitly associated only: an inherited default isn't this circle's own relay.
        // `explicitRelaysForCircle` never contains the default — only `relaysFor` merges that in.
        val own = HavenNet.explicitRelaysForCircle(circleId).filter { HavenNet.isRelayActive(it) }
        if (own.isNotEmpty()) return false
        // membersOf = the OTHER members (self is excluded), matching iOS's ">2 others" threshold.
        val others = runCatching { HavenNet.membersOf(circleId).size }.getOrDefault(0)
        return others > CONNECTION_THRESHOLD
    }
}
