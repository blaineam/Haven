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
    private const val KEY_MANUAL = "refs.manual"
    private lateinit var appContext: Context

    /** Insertion-ordered so the bound below drops the OLDEST ask, not an arbitrary one. */
    private val wanted = LinkedHashSet<String>()

    /** The subset a PERSON asked for by tapping "Ask for it back". Only these earn a notification
     *  when the author answers: the held-but-unreadable sweep asks automatically, and plumbing that
     *  announces itself 30 times in a sweep is spam. `wanted` cannot answer "did the user ask?"
     *  because both writers use it.
     *
     *  PERSISTED, unlike the in-memory set this replaces: an author can be offline for a week, and a
     *  manual ask that stops earning its notification because the app restarted is the same bug from
     *  the other side. (Apple and desktop persist theirs too — one behaviour, three platforms.) */
    private val manual = LinkedHashSet<String>()

    /** Bumped on every add/clear so a @Composable placeholder recomposes when its state changes. */
    val version = mutableIntStateOf(0)

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        wanted.clear()
        runCatching { wanted.addAll(prefs.getStringSet(KEY, emptySet()) ?: emptySet()) }
        manual.clear()
        runCatching { manual.addAll(prefs.getStringSet(KEY_MANUAL, emptySet()) ?: emptySet()) }
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun persist() {
        prefs.edit().putStringSet(KEY, HashSet(wanted)).putStringSet(KEY_MANUAL, HashSet(manual)).apply()
        version.intValue += 1
    }

    @Synchronized fun isWanted(ref: String): Boolean = wanted.contains(ref)

    /** Did a PERSON ask for this one? Drives the notification AND the "we'll tell you when it's
     *  back" promise — neither belongs to an automatic repair. */
    @Synchronized fun isManuallyWanted(ref: String): Boolean = manual.contains(ref)

    /** Consume the manual flag: true only if a person asked. One ask earns at most one notice. */
    @Synchronized fun takeManual(ref: String): Boolean {
        if (!manual.remove(ref)) return false
        persist()
        return true
    }

    @Synchronized fun add(ref: String, manualAsk: Boolean = false) {
        if (manualAsk && manual.add(ref)) {
            while (manual.size > 500) manual.remove(manual.first())
            persist()
        }
        if (!wanted.add(ref)) return
        // Bounded: someone who taps this on everything shouldn't grow an unbounded list, and the
        // oldest asks are the least likely to still matter.
        while (wanted.size > 500) wanted.remove(wanted.first())
        persist()
    }

    /** It arrived (or the ask is moot) — stop tracking it. */
    @Synchronized fun clear(ref: String) {
        val hadManual = manual.remove(ref)
        if (wanted.remove(ref) || hadManual) persist()
    }
}
