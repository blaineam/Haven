package com.blaineam.haven.core

import android.util.Log
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject
import uniffi.haven_ffi.LinkConstraint
import uniffi.haven_ffi.RelayHistoryItem
import uniffi.haven_ffi.RelayHistoryPlanner

/**
 * "Load history from your relays" — a user-triggered deep pass over every circle's relay mailbox
 * (Apple `RelayHistoryResync` parity). The planner + ingested-key journal is core
 * (`RelayHistoryPlanner`); this drives it: full listing per (circle, relay) → fetch in bounded
 * batches → ingest control-plane first → save the engine → THEN commit the batch to the journal and
 * the seen-set; one retry pass for what parked; then the media the feed names, relay-first. Never
 * seals, uploads, fans out or pushes. Cancel stops between batches; a re-run resumes.
 */
object RelayHistoryResync {
    private const val TAG = "RelayHistory"
    const val BATCH = 24
    private const val FETCH_CONCURRENCY = 4

    val progress = mutableStateOf(RelayHistoryProgress())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var job: Job? = null
    @Volatile private var plannerRef: RelayHistoryPlanner? = null

    private fun planner(): RelayHistoryPlanner =
        plannerRef ?: synchronized(this) {
            plannerRef ?: RelayHistoryPlanner(HavenNet.historyJournalFile.absolutePath).also { plannerRef = it }
        }

    private fun update(f: (RelayHistoryProgress) -> RelayHistoryProgress) {
        synchronized(this) { progress.value = f(progress.value) }
    }

    /** Why it can't start right now: "satellite" (low-data policy denies history backfill there),
     *  "norelay" (no circle reads from a relay), or null. */
    fun unavailableReason(): String? {
        if (LowDataMonitor.effective.value == LinkConstraint.ULTRA) return "satellite"
        if (HavenNet.historySocial == null) return "norelay"
        if (HavenNet.historyCircleIds().none { HavenNet.historyRelayNodes(it).isNotEmpty() }) return "norelay"
        return null
    }

    fun start() {
        if (job?.isActive == true || unavailableReason() != null) return
        update { RelayHistoryProgress(phase = RelayHistoryProgress.Phase.SCANNING, startedAtMs = System.currentTimeMillis()) }
        Log.i(TAG, "relay history: start")
        job = scope.launch { runCatching { run() }.onFailure { Log.e(TAG, "relay history failed", it) } }
    }

    fun cancel() { job?.cancel() }

    fun dismiss() { if (!progress.value.running) update { RelayHistoryProgress() } }

    fun resetJournal() {
        cancel()
        runCatching { planner().reset() }
        update { RelayHistoryProgress() }
    }

    private data class Pending(val circle: String, val key: String, val nodes: List<String>)

    private suspend fun run() {
        val social = HavenNet.historySocial ?: return
        val circles = HavenNet.historyCircleIds().filter { HavenNet.historyRelayNodes(it).isNotEmpty() }
        update { it.copy(circlesTotal = circles.size) }
        fun events() = circles.sumOf { runCatching { social.historyEventCount(it).toLong() }.getOrDefault(0L) }
        val before = events()
        // The media the feed already names: anything outside it at the end came from this run.
        val refsBefore = namedMedia(circles, social).mapTo(HashSet()) { it.ref }
        val retry = ArrayList<Pending>()
        var landed = false
        for (cid in circles) {
            if (job?.isCancelled == true) break
            val perRelay = ArrayList<Pair<String, List<String>>>()
            var listedAny = false
            for (node in HavenNet.historyRelayNodes(cid)) {
                val keys = HavenNet.historyList(cid, node) ?: continue
                listedAny = true
                perRelay.add(node to planner().plan(cid, keys))
            }
            if (!listedAny) update { it.copy(relayErrors = it.relayErrors + 1) }
            val work = RelayHistoryPlan.merge(perRelay).map { Pending(cid, it.first, it.second) }
            update { it.copy(entriesFound = it.entriesFound + work.size) }
            for (batch in work.chunked(BATCH)) {
                if (job?.isCancelled == true) break
                val r = ingest(batch, counting = true)
                retry += r.first
                if (r.second) landed = true
            }
            update { it.copy(circlesDone = it.circlesDone + 1) }
            if (landed) HavenNet.historyLanded()
        }
        if (job?.isCancelled != true && retry.isNotEmpty()) {
            update { it.copy(phase = RelayHistoryProgress.Phase.RETRYING) }
            var still = 0
            for (batch in retry.chunked(BATCH)) {
                if (job?.isCancelled == true) break
                val r = ingest(batch, counting = false)
                still += r.first.size
                if (r.second) landed = true
            }
            update { it.copy(waiting = still) }
        }
        update { it.copy(postsAdded = maxOf(0, (events() - before).toInt())) }
        if (landed) HavenNet.historyLanded()
        Log.i(TAG, "relay history: scan done ${progress.value}")
        if (job?.isCancelled != true) {
            update { it.copy(phase = RelayHistoryProgress.Phase.MEDIA) }
            fetchMedia(circles, social, refsBefore)
        }
        update {
            it.copy(phase = if (job?.isCancelled == true) RelayHistoryProgress.Phase.CANCELLED else RelayHistoryProgress.Phase.DONE,
                finishedAtMs = System.currentTimeMillis())
        }
        Log.i(TAG, "relay history: finished ${progress.value}")
    }

    /** Fetch → ingest → save → commit. Returns (keys to retry, whether anything applied). */
    private suspend fun ingest(batch: List<Pending>, counting: Boolean): Pair<List<Pending>, Boolean> {
        val social = HavenNet.historySocial ?: return emptyList<Pending>() to false
        val sem = Semaphore(FETCH_CONCURRENCY)
        val got = kotlinx.coroutines.coroutineScope {
            batch.map { p ->
                async { sem.withPermit { p.nodes.firstNotNullOfOrNull { HavenNet.historyGet(it, p.key) } } }
            }.awaitAll()
        }
        val meta = batch.associateBy { it.key }
        val byCircle = LinkedHashMap<String, MutableList<RelayHistoryItem>>()
        batch.zip(got).forEach { (p, d) -> if (d != null) byCircle.getOrPut(p.circle) { mutableListOf() }.add(RelayHistoryItem(p.key, d)) }
        val retry = ArrayList<Pending>()
        val processed = ArrayList<String>()
        var changed = false
        var unreadable = 0
        for ((cid, items) in byCircle) {
            val r = planner().ingest(social, cid, items)
            unreadable += r.unreadable.toInt()
            if (r.applied.toInt() > 0) changed = true
            r.retry.mapNotNullTo(retry) { meta[it] }
            processed += r.processed
        }
        update { it.copy(entriesChecked = it.entriesChecked + if (counting) batch.size else 0, unreadable = it.unreadable + unreadable) }
        if (processed.isEmpty()) return retry to changed
        // Mark-after-persist: journal + seen-set learn a key only once its event is on disk.
        if (HavenNet.historySave()) {
            if (!planner().commitStaged()) planner().discardStaged()
            HavenNet.historyMarkSeen(processed)
        } else {
            planner().discardStaged()
        }
        return retry to changed
    }

    /** Every media candidate each circle's feed names (posts, comments, small companions), tagged
     *  with the user-visible item it belongs to. */
    private fun namedMedia(circles: List<String>, social: uniffi.haven_ffi.HavenSocial): List<RelayHistoryPlan.MediaCandidate> {
        val now = System.currentTimeMillis().toULong()
        return circles.flatMap { cid ->
            val refs = ArrayList<String>()
            for (item in runCatching { social.feed(cid, now, null) }.getOrDefault(emptyList())) {
                refs += item.media
                for (c in item.comments) refs += c.media
            }
            RelayHistoryPlan.mediaCandidates(cid, refs)
        }
    }

    /** "Photos and videos" = ITEMS this run brought onto the device (a photo and its thumb/preview are
     *  one): items new to the feed with something on disk now (whichever path fetched it) plus items
     *  this phase fetches itself. */
    private suspend fun fetchMedia(circles: List<String>, social: uniffi.haven_ffi.HavenSocial, before: Set<String>) {
        val constrained = LowDataMonitor.effective.value != LinkConstraint.NORMAL
        val plan = RelayHistoryPlan.mediaPlan(namedMedia(circles, social), before, constrained, { LocalMedia.has(it) },
            { EvictedMediaStore.contains(it) }, { LocalMedia.isSynthetic(it) })
        val tally = RelayHistoryMediaTally(plan)
        update { it.copy(mediaTotal = plan.total, mediaDone = plan.landed) }
        // ONE blob at a time: the media queue's OOM rule (a restore holds a whole sealed blob in RAM).
        for (w in plan.want) {
            if (job?.isCancelled == true) return
            var waited = 0
            while ((HeavyWorkMonitor.current.heat >= HeavyWorkPolicy.Heat.SERIOUS) && waited < 120 && job?.isCancelled != true) { delay(5_000); waited += 5 }
            if ((HeavyWorkMonitor.current.heat >= HeavyWorkPolicy.Heat.SERIOUS)) { update { it.copy(mediaDeferred = true) }; return }
            val ok = runCatching { HavenNet.historyFetchMedia(w.circle, w.ref) }.getOrDefault(false)
            val (done, missing) = tally.record(w.item, ok)
            update { it.copy(mediaDone = it.mediaDone + done, mediaMissing = it.mediaMissing + missing) }
        }
    }

    fun qaSnapshot(): JSONObject {
        val p = progress.value
        return JSONObject()
            .put("state", p.phase.raw).put("circles_done", p.circlesDone).put("circles_total", p.circlesTotal)
            .put("entries_found", p.entriesFound).put("entries_checked", p.entriesChecked)
            .put("posts_added", p.postsAdded).put("unreadable", p.unreadable).put("waiting", p.waiting)
            .put("media_done", p.mediaDone).put("media_total", p.mediaTotal).put("media_missing", p.mediaMissing)
            .put("relay_errors", p.relayErrors).put("started_ms", p.startedAtMs).put("finished_ms", p.finishedAtMs)
            .put("journal_keys", runCatching { planner().ingestedCount().toLong() }.getOrDefault(0L))
    }
}
