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

    /** One media ref the feed names, tagged with the user-visible ITEM it belongs to: its primary
     *  ref. A small companion (thumb / preview / poster) names its primary through its marker. */
    data class MediaCandidate(val ref: String, val circle: String, val small: Boolean, val item: String)

    /** Every candidate one circle's raw feed refs name (posts + comments, markers included): the refs
     *  themselves plus their small companions, deduped, each tagged with its item. */
    fun mediaCandidates(circle: String, refs: List<String>): List<MediaCandidate> {
        val primary = HashMap<String, String>()
        for (r in refs) {
            (MediaVariants.parseThumb(r) ?: MediaVariants.parsePreview(r) ?: MediaVariants.parsePoster(r))
                ?.let { (content, small) -> primary.putIfAbsent(small, content) }
        }
        val smallList = MediaVariants.prefetchCompanions(refs)
        val small = smallList.toSet()
        return (refs + smallList).distinct().map { MediaCandidate(it, circle, it in small, primary[it] ?: it) }
    }

    /** The media phase's plan. The summary counts user-visible ITEMS, never refs: a photo, its thumb
     *  and its preview are one item. An item counts as done once ANY of its refs landed — on a
     *  constrained link only companions are considered at all, so the companion alone is the item; on
     *  a normal link a thumb that lands before the full-size file already shows the photo.
     *  [landed]: items new to the feed (not in `before` — a recovered post or comment named them)
     *  already with something on disk, done up front whichever path fetched them. [total]: [landed] +
     *  items with something to fetch. [want]: refs to fetch, small companions first (per ref). */
    data class MediaPlan(val landed: Int, val total: Int, val want: List<MediaCandidate>, internal val counted: Set<String>)

    /** `before` = every ref the feed named when the run STARTED. Same rules as [wanted]. */
    fun mediaPlan(candidates: List<MediaCandidate>, before: Set<String>, constrained: Boolean, have: (String) -> Boolean,
                  evicted: (String) -> Boolean, synthetic: (String) -> Boolean): MediaPlan {
        val present = LinkedHashMap<String, Boolean>()
        val missing = HashMap<String, MutableList<MediaCandidate>>()
        val taken = HashSet<String>()
        for (c in candidates) {
            if (synthetic(c.ref) || (constrained && !c.small) || !taken.add(c.ref)) continue
            present.putIfAbsent(c.item, false)
            if (have(c.ref)) present[c.item] = true
            else if (!evicted(c.ref)) missing.getOrPut(c.item) { mutableListOf() }.add(c)
        }
        var landed = 0
        var total = 0
        val counted = HashSet<String>()
        val want = ArrayList<MediaCandidate>()
        for ((item, has) in present) {
            val m = missing[item].orEmpty()
            if (has && item !in before) { landed++; total++; counted += item }
            else if (m.isNotEmpty()) total++
            want += m
        }
        return MediaPlan(landed, total, want.sortedBy { if (it.small) 0 else 1 }, counted)
    }
}

/** Per-ref fetch results → per-item counts: an item is done at its first ref that lands, missing once
 *  every one of its refs failed; an item counted up front never counts again. */
class RelayHistoryMediaTally(plan: RelayHistoryPlan.MediaPlan) {
    private val pending = HashMap<String, Int>().apply { plan.want.forEach { merge(it.item, 1, Int::plus) } }
    private val counted = HashSet(plan.counted)

    /** (done delta, missing delta) for one fetched ref of [item]. */
    fun record(item: String, ok: Boolean): Pair<Int, Int> {
        val left = maxOf(0, (pending[item] ?: 0) - 1)
        pending[item] = left
        return when {
            item in counted -> 0 to 0
            ok -> { counted += item; 1 to 0 }
            left == 0 -> { counted += item; 0 to 1 }
            else -> 0 to 0
        }
    }
}
