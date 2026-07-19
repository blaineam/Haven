package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf

/**
 * Media I've asked to be told about when it comes back.
 *
 * A relay sweeps media on the operator's retention, and a post outlives its blob — so "No longer
 * available" is a permanent dead end even though the AUTHOR usually still has the original sitting
 * on their device. This records that I want it, so I can be told when it returns.
 *
 * Deliberately just a local set of refs: the REQUEST itself travels as a sealed frame through the
 * circle's mailbox, which is already store-and-forward, so an author who is offline for a week
 * receives it the moment they next sync. Nothing needs to be parked on a relay by hand.
 *
 * Mirrors iOS `MediaWantedStore`.
 */
object MediaWantedStore {
    private const val PREFS = "haven.mediawanted"
    private const val KEY = "refs"
    private lateinit var appContext: Context

    /** Insertion-ordered so the bound below drops the OLDEST ask, not an arbitrary one. */
    private val wanted = LinkedHashSet<String>()

    /** Bumped on every add/clear so a @Composable placeholder recomposes when its state changes. */
    val version = mutableIntStateOf(0)

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        wanted.clear()
        runCatching { wanted.addAll(prefs.getStringSet(KEY, emptySet()) ?: emptySet()) }
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun persist() {
        prefs.edit().putStringSet(KEY, HashSet(wanted)).apply()
        version.intValue += 1
    }

    @Synchronized fun isWanted(ref: String): Boolean = wanted.contains(ref)

    @Synchronized fun add(ref: String) {
        if (!wanted.add(ref)) return
        // Bounded: someone who taps this on everything shouldn't grow an unbounded list, and the
        // oldest asks are the least likely to still matter.
        while (wanted.size > 500) wanted.remove(wanted.first())
        persist()
    }

    /** It arrived (or the ask is moot) — stop tracking it. */
    @Synchronized fun clear(ref: String) {
        if (wanted.remove(ref)) persist()
    }
}
