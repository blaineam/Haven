package com.blaineam.haven.core

/**
 * Pure state behind "Load history from your relays" (Apple `RelayHistoryProgress.swift` parity) — no
 * Android, no engine, so JVM unit tests cover it.
 */
data class RelayHistoryProgress(
    val phase: Phase = Phase.IDLE,
    val circlesDone: Int = 0,
    val circlesTotal: Int = 0,
    /** Mailbox entries the relays listed that this device had never ingested / fetched so far. */
    val entriesFound: Int = 0,
    val entriesChecked: Int = 0,
    /** NEW events on this device (engine event count after minus before). */
    val postsAdded: Int = 0,
    val unreadable: Int = 0,
    val waiting: Int = 0,
    val mediaDone: Int = 0,
    val mediaTotal: Int = 0,
    val mediaMissing: Int = 0,
    val relayErrors: Int = 0,
    val mediaDeferred: Boolean = false,
    val startedAtMs: Long = 0,
    val finishedAtMs: Long = 0,
) {
    enum class Phase(val raw: String) { IDLE("idle"), SCANNING("scanning"), RETRYING("retrying"), MEDIA("media"), DONE("done"), CANCELLED("cancelled") }

    sealed class Outcome {
        data class Added(val posts: Int, val media: Int) : Outcome()
        object UpToDate : Outcome()
        object Unreachable : Outcome()
    }

    val running: Boolean get() = phase == Phase.SCANNING || phase == Phase.RETRYING || phase == Phase.MEDIA

    /** 0…1: the scan is the first 60%, media the rest; an empty phase does not hold the bar still. */
    val fraction: Float get() {
        fun part(d: Int, t: Int) = if (t <= 0) 1f else minOf(1f, d.toFloat() / t)
        return when (phase) {
            Phase.IDLE -> 0f
            Phase.SCANNING -> 0.6f * part(circlesDone, circlesTotal) * 0.95f
            Phase.RETRYING -> 0.57f + 0.03f * part(entriesChecked, entriesFound)
            Phase.MEDIA -> 0.6f + 0.4f * part(mediaDone, mediaTotal)
            Phase.DONE, Phase.CANCELLED -> 1f
        }
    }

    val outcome: Outcome get() = when {
        postsAdded > 0 || mediaDone > 0 -> Outcome.Added(postsAdded, mediaDone)
        relayErrors > 0 && entriesFound == 0 && circlesTotal > 0 && relayErrors >= circlesTotal -> Outcome.Unreachable
        else -> Outcome.UpToDate
    }

    /** Relays are a mailbox, not an archive (30-day idle sweep): every finished run says so. */
    val showsRetentionCaveat: Boolean get() = phase == Phase.DONE
}

/** Pure planning helpers (Apple `RelayHistoryPlan` parity). */
object RelayHistoryPlan {
    /** Each key once, with every relay that listed it, first relay's keys first. */
    fun merge(perRelay: List<Pair<String, List<String>>>): List<Pair<String, List<String>>> {
        val nodes = LinkedHashMap<String, MutableList<String>>()
        for ((node, keys) in perRelay) for (k in keys) {
            val l = nodes.getOrPut(k) { mutableListOf() }
            if (node !in l) l.add(node)
        }
        return nodes.map { (k, v) -> k to v.toList() }
    }

    /** What to download for one circle: real bytes not held, not evicted; on a constrained link only
     *  the small companions (thumbs, previews, posters). */
    fun wanted(refs: List<String>, small: Set<String>, have: (String) -> Boolean, evicted: (String) -> Boolean,
               synthetic: (String) -> Boolean, constrained: Boolean): List<String> {
        val seen = HashSet<String>()
        return refs.filter { r ->
            !synthetic(r) && !have(r) && !evicted(r) && seen.add(r) && (!constrained || r in small)
        }
    }

    /** Media this run already brought onto the device without fetching it itself: refs NEW to the
     *  feed (not in [before], the refs it named when the run started — i.e. named by a recovered post
     *  or comment) that are on disk now. The ordinary ingest path auto-fetches a fresh post's media
     *  concurrently, so by the media phase it is often already there; the summary must still count it.
     *  Same synthetic / constrained rules as [wanted]; disjoint from it (that needs `!have`). */
    fun landed(refs: List<String>, small: Set<String>, before: Set<String>, have: (String) -> Boolean,
               synthetic: (String) -> Boolean, constrained: Boolean): List<String> {
        val seen = HashSet<String>()
        return refs.filter { r ->
            !synthetic(r) && r !in before && seen.add(r) && (!constrained || r in small) && have(r)
        }
    }
}
