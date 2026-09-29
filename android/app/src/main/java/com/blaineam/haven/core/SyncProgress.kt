package com.blaineam.haven.core

/**
 * Pure decisions behind the sync / transfer progress UI (Apple `SyncProgress.swift` parity) — no
 * Android, no engine, so JVM unit tests cover them.
 *
 * Field report: "The app has UX for showing sync statuses and progress but it doesn't appear to
 * actually ever progress at all and just disappears after a bit." On Android the composer pill's
 * SYNCING branch was unreachable (syncStatus only ever returned SYNCED or LOCAL), media spinners came
 * down on a fixed 45s timer or the moment a relay reassembly stalled, and "received" only counted
 * peer reassemblies.
 */

/** Authored events still on their way to a mailbox, per circle (user content only — epoch-head
 *  upkeep rides the same upload but is never counted). A "session" runs from the first pending
 *  item to the queue draining, so "Sending 2 of 5" counts every item of one burst. */
data class UploadProgress(
    val pendingByCircle: Map<String, Int> = emptyMap(),
    /** Of the pending items, how many have failed at least once and are retrying (in backoff or in a retry attempt). */
    val retryingByCircle: Map<String, Int> = emptyMap(),
    val sessionTotalByCircle: Map<String, Int> = emptyMap(),
    val sessionDoneByCircle: Map<String, Int> = emptyMap(),
    /** Media blobs of just-authored posts still headed for a relay, per circle. The event lands in
     *  well under a second; the photo or video is what takes time. Apple parity. */
    val mediaPendingByCircle: Map<String, Int> = emptyMap(),
) {
    /** Authored EVENTS still waiting for a mailbox. */
    fun pending(circleId: String) = pendingByCircle[circleId] ?: 0
    /** Authored media blobs still waiting for a relay. */
    fun mediaPending(circleId: String) = mediaPendingByCircle[circleId] ?: 0
    /** Everything of yours the pill is waiting on. */
    fun totalPending(circleId: String) = pending(circleId) + mediaPending(circleId)
}

/** What the composer pill says for one circle. */
sealed class SyncBadgeState {
    data object Synced : SyncBadgeState()
    data class Sending(val done: Int, val total: Int) : SyncBadgeState()
    data class Retrying(val pending: Int) : SyncBadgeState()
    data object Local : SyncBadgeState()

    companion object {
        fun derive(p: UploadProgress, circleId: String, hostsRelay: Boolean, hasRelay: Boolean,
                   nearbyConnected: Boolean, online: Boolean): SyncBadgeState {
            if (hostsRelay) return Synced
            val pending = p.totalPending(circleId)
            // No relay: posts go best-effort straight to whoever's reachable — nothing to track.
            if (!hasRelay || pending == 0) {
                return if (hasRelay || nearbyConnected || online) Synced else Local
            }
            if (!online && !nearbyConnected) return Local
            val retrying = p.retryingByCircle[circleId] ?: 0
            if (retrying >= pending) return Retrying(pending)
            val total = maxOf(p.sessionTotalByCircle[circleId] ?: 0, pending)
            val done = (p.sessionDoneByCircle[circleId] ?: 0).coerceIn(0, total)
            return Sending(done, total)
        }
    }

    /** The QA dump's word for the state (docs/QA.md "Progress fields"). */
    val dumpState: String
        get() = when (this) {
            Synced -> "synced"
            is Sending -> "syncing"
            is Retrying -> "retrying"
            Local -> "local"
        }

    /** Finer than [dumpState]. */
    val detail: String
        get() = when (this) {
            Synced -> "synced"
            is Sending -> "sending $done/$total"
            is Retrying -> "retrying $pending"
            Local -> "local"
        }
}

/**
 * Bounded log of the pill's transitions (QA dump `sync_badge_history`, Apple parity). A small
 * post's upload starts and finishes between two harness samples; recording every change where it
 * happens makes "synced → syncing → synced" provable instead of a race.
 */
class SyncBadgeHistory {
    data class Entry(val circle: String, val state: String, val detail: String, val pending: Int, val atMs: Long)

    private val entries = ArrayList<Entry>()

    @Synchronized fun entries(): List<Entry> = entries.toList()

    /** Append when what the pill shows changed (same circle, state, detail and count = no entry). */
    @Synchronized fun record(circle: String, badge: SyncBadgeState, pending: Int, atMs: Long) {
        val e = Entry(circle, badge.dumpState, badge.detail, pending, atMs)
        val last = entries.lastOrNull()
        if (last != null && last.copy(atMs = e.atMs) == e) return
        entries += e
        while (entries.size > CAP) entries.removeAt(0)
    }

    fun toJson(): org.json.JSONArray = org.json.JSONArray().apply {
        for (e in entries()) put(org.json.JSONObject().put("circle", e.circle).put("state", e.state)
            .put("detail", e.detail).put("pending", e.pending).put("atMs", e.atMs))
    }

    companion object { const val CAP = 20 }
}

/**
 * No-progress watchdog for one media transfer: a spinner comes down when bytes arrive or when none
 * have for [NO_PROGRESS_MS] — never on a fixed timer. `busy` (a relay restore in flight, which says
 * nothing until a chunk lands) holds the clock.
 */
class TransferStallWatch(progress: Int, nowMs: Long) {
    var lastProgress = progress; private set
    var lastProgressAt = nowMs; private set

    /** True once the transfer has made no progress for [NO_PROGRESS_MS]. */
    fun observe(progress: Int, nowMs: Long, busy: Boolean = false): Boolean {
        if (progress > lastProgress || busy) {
            lastProgress = maxOf(lastProgress, progress)
            lastProgressAt = nowMs
            return false
        }
        if (progress < lastProgress) lastProgress = progress   // a restarted partial is not progress
        return nowMs - lastProgressAt >= NO_PROGRESS_MS
    }

    companion object { const val NO_PROGRESS_MS = 45_000L }
}

/** Media refs wanted and not held yet — "media waiting". Joins on discovery, leaves on arrival,
 *  give-up, or a later check finding it held; a scan's own `missing` size is not a stable count. */
class MediaWantedSet {
    private val refs = LinkedHashSet<String>()
    @get:Synchronized val count: Int get() = refs.size
    @Synchronized fun snapshot(): Set<String> = refs.toSet()
    @Synchronized fun discover(found: Iterable<String>) { for (r in found) if (refs.size < CAP) refs.add(r) }
    /** The bytes landed. True if it was wanted. */
    @Synchronized fun arrived(ref: String): Boolean = refs.remove(ref)
    @Synchronized fun gaveUp(ref: String) { refs.remove(ref) }
    @Synchronized fun prune(held: (String) -> Boolean) { refs.removeAll { held(it) } }

    companion object { const val CAP = 5_000 }
}
