package com.blaineam.haven.core

/**
 * Scheduling rules for the relay-restore queue — which lane a missing blob rides and the order a
 * sweep offers refs in. Pure so the rules are unit-tested; `HavenNet.requestMissingMedia` only
 * applies them.
 *
 * WHY THIS EXISTS (Nokia field report, fresh install on a busy circle): the core's `feed()` is
 * OLDEST-FIRST, and every restore — fresh media, tile thumbs and a week of doomed backlog alike —
 * went through ONE FIFO behind the oldest ref. On a fresh device every backlog ref is a relay MISS
 * (the blob was sealed before this device existed), ~0.11 s each, so the NEWEST post's media sat
 * behind ~875 misses (≈100 s) before its first byte was asked for, and the ≤32 KB thumbs that
 * make a tile look like the photo waited behind the full-size backlog too. Profile pictures took a
 * different path, which is why they loaded while post media did not.
 *
 * Apple parity: FeedStore.requestMissingMedia puts thumbs/previews/posters on a priority lane and
 * scans newest-first; this is the same policy.
 */
internal object MediaRestorePlan {
    enum class Lane { PRIORITY, BACKLOG }

    /** Newest posts whose thumbs/posters/previews ride the priority lane. Bounded so a huge feed's
     *  thumbs cannot starve fresh media (every priority job is a serial relay round-trip). */
    const val PRIORITY_THUMB_CAP = 120

    /** Full-size media: only a just-arrived (fresh) ref outranks the backlog. Everything else
     *  drains newest-first on the backlog lane. */
    fun fullSizeLane(fresh: Boolean): Lane = if (fresh) Lane.PRIORITY else Lane.BACKLOG

    /**
     * Small companions (thumb / poster / preview, ≤32 KB by contract). [rankNewestFirst] is the
     * 0-based position of the carrying post within its circle, newest = 0. A BACKFILLED post (older
     * than the lazy-media window) never rides the priority lane: its tile can wait, the recent
     * ones cannot.
     */
    fun thumbLane(rankNewestFirst: Int, backfill: Boolean): Lane =
        if (!backfill && rankNewestFirst < PRIORITY_THUMB_CAP) Lane.PRIORITY else Lane.BACKLOG

    /**
     * Round-robin across circles so one stuck circle cannot starve another, preserving each
     * circle's own order (callers pass newest-first lists).
     */
    fun <T> interleave(perCircle: List<List<T>>): List<T> {
        val total = perCircle.sumOf { it.size }
        val out = ArrayList<T>(total)
        var idx = 0
        while (out.size < total) {
            var moved = false
            for (q in perCircle) if (idx < q.size) { out.add(q[idx]); moved = true }
            if (!moved) break
            idx++
        }
        return out
    }
}

/**
 * "This relay base answered a liveness probe recently" memo. A media MISS used to cost TWO
 * requests — the blob GET and a `__interface__` GET to tell a genuine miss from a rotated tunnel
 * that 404s everything — so a fresh device's hopeless backlog paid that second round-trip per ref.
 * One recent proof of life covers every miss in the window. Only a positive answer is cached: a
 * dead base is re-probed every time so a recovery is seen at once.
 */
internal class AliveProbeCache(private val ttlMs: Long = 60_000L, private val clock: () -> Long = System::currentTimeMillis) {
    private val provenAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    fun recentlyAlive(base: String): Boolean {
        val at = provenAt[base.trimEnd('/')] ?: return false
        return clock() - at < ttlMs
    }

    fun noteAlive(base: String) {
        provenAt[base.trimEnd('/')] = clock()
        if (provenAt.size > 64) provenAt.entries.removeIf { clock() - it.value >= ttlMs }
    }

    fun forget(base: String) { provenAt.remove(base.trimEnd('/')) }
}
