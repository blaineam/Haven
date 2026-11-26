package com.blaineam.haven.core

import android.util.Log
import androidx.compose.runtime.mutableStateOf
import com.blaineam.haven.core.HistoryHandoffWire as HW
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.HistoryPageFfi
import java.io.File

/** What the senders need from the app. [HavenNet] is the real one; tests supply their own. */
interface HandoffHost {
    /** The engine is up with its circles and there is an account lane to talk over. */
    fun ready(): Boolean
    fun accountHex(): String
    fun deviceHex(): String
    /** Only a device holding the account key serves: it holds the history, opens a blob's
     *  recipient entry and signs a key batch. */
    fun holdsAccountSeed(): Boolean
    /** A call, Battery Saver or heat: heavy work waits. */
    fun suspendHeavyIO(): Boolean

    suspend fun laneList(prefix: String): List<String>
    suspend fun laneGet(key: String): ByteArray?
    suspend fun lanePut(key: String, data: ByteArray): Boolean

    fun circleIds(): List<String>
    /** Device ids my account-signed roster lists. */
    fun accountDevices(): List<String>
    /** Union-merge another of my devices' roster. -1 refused, 0 already current, 1 changed. */
    fun ingestOwnRoster(wire: ByteArray): Int
    fun historyEventCount(circleId: String): Long
    /** One page of a circle's history, re-sealed; key material it minted is saved before return. */
    fun exportHistoryPage(circleId: String, beforeMs: Long, limit: Int): HistoryPageFfi?
    /** `(circle, ref)` of every blob my circles' posts name, newest first. */
    fun historyMediaRefs(): List<Pair<String, String>>
    /** Media lists of the stories kept to my profile. */
    fun keptStoryMedia(): List<String>
    /** Size of my local copy of [ref], or null when this device does not hold it. */
    fun localMediaSize(ref: String): Long?
    /** My local copy of [ref] sealed to [circleId] in a temp file, which the caller deletes. */
    fun sealMediaForHandoff(circleId: String, ref: String): File?
    suspend fun findItemKey(circleId: String, ref: String): ItemKeyResult
    fun sealItemKeys(device: String, entries: List<ByteArray>): ByteArray?
    /** "Look at the account lane now" to my other devices. */
    fun nudgeMyDevices()
}

/**
 * Hands another device of MY account the account's history through the relay, so the two never have
 * to be awake at the same time (docs/DECISIONS.md D26). Android is the SOURCE half of Apple
 * `HistoryHandoff.swift` / core `historyhandoff.rs`: it answers a linked browser's (or a new
 * phone's) request with pages, newest first, one circle at a time in turn, and puts a page's media
 * on the relay when a phone says it could not get it directly. [MediaKeysSender] runs on the same
 * ticks and shares the banner.
 */
class HistoryHandoff(
    private val host: HandoffHost,
    private val dir: File,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val publish: (Status) -> Unit = { banner.value = it },
) {
    enum class Phase { IDLE, SENDING, CANCELLED }

    /** What the banner over the feed and Settings ▸ Devices show. */
    data class Status(
        val phase: Phase = Phase.IDLE,
        /** [Phase.CANCELLED] only: the OTHER device stopped it. */
        val cancelledRemotely: Boolean = false,
        val done: Long = 0,
        val total: Long = 0,
        val mediaDone: Int = 0,
        val mediaTotal: Int = 0,
    ) {
        val fraction: Float?
            get() = (total + mediaTotal).takeIf { it > 0 }
                ?.let { minOf(1f, (done + mediaDone).toFloat() / it.toFloat()) }
    }

    private class Serve(
        val device: String,
        val requestAt: Long,
        val run: String,
        val order: List<String>,
        var totalEvents: Long,
    ) {
        val cursors = HashMap<String, Long>()
        val finished = LinkedHashSet<String>()
        var pages = 0
        var complete = false
        var servedEvents = 0L
        var keptSent = false

        fun ledgerRun() = HandoffCancelLedger.Run(device, requestAt, run, pages, totalEvents, servedEvents)

        fun toJson(): JSONObject = JSONObject().put("device", device).put("requestAt", requestAt).put("run", run)
            .put("order", JSONArray(order)).put("cursors", JSONObject(cursors.toMap()))
            .put("finished", JSONArray(finished.toList())).put("pages", pages).put("complete", complete)
            .put("totalEvents", totalEvents).put("servedEvents", servedEvents).put("keptSent", keptSent)

        companion object {
            fun from(o: JSONObject) = Serve(o.getString("device"), o.getLong("requestAt"), o.getString("run"),
                o.getJSONArray("order").strings(), o.optLong("totalEvents")).also { s ->
                o.optJSONObject("cursors")?.let { c -> for (k in c.keys()) s.cursors[k] = c.getLong(k) }
                o.optJSONArray("finished")?.let { s.finished.addAll(it.strings()) }
                s.pages = o.optInt("pages")
                s.complete = o.optBoolean("complete")
                s.servedEvents = o.optLong("servedEvents")
                s.keptSent = o.optBoolean("keptSent")
            }
        }
    }

    /** Per-run media bookkeeping, in its own file: a big account names tens of thousands of blobs. */
    private class RunMedia {
        class PageMedia(val circle: String, val refs: List<String>)
        val pages = HashMap<Int, PageMedia>()
        val relayed = LinkedHashSet<Int>()
        val uploaded = HashMap<String, Int>()

        fun toJson(): JSONObject = JSONObject()
            .put("pages", JSONObject().also { o ->
                for ((n, p) in pages) o.put(n.toString(), JSONObject().put("circle", p.circle).put("refs", JSONArray(p.refs)))
            })
            .put("relayed", JSONArray(relayed.toList()))
            .put("uploaded", JSONObject(uploaded.toMap()))

        companion object {
            fun from(o: JSONObject) = RunMedia().also { r ->
                o.optJSONObject("pages")?.let { p ->
                    for (k in p.keys()) p.getJSONObject(k).let {
                        r.pages[k.toInt()] = PageMedia(it.getString("circle"), it.getJSONArray("refs").strings())
                    }
                }
                o.optJSONArray("relayed")?.let { a -> for (i in 0 until a.length()) r.relayed.add(a.getInt(i)) }
                o.optJSONObject("uploaded")?.let { u -> for (k in u.keys()) r.uploaded[k] = u.getInt(k) }
            }
        }
    }

    /** Guards every field below. Never held across a suspension. */
    private val lock = Any()
    private val serves = HashMap<String, Serve>()
    private var ledger = HandoffCancelLedger()
    /** The account the persisted runs belong to: a run is never carried into another identity. */
    private var account = ""
    private var lastSendingAt = 0L
    private var needsPending = false
    private val lastManifestTouch = HashMap<String, Long>()
    /** Blob refs named by the unfinished run's pages / sent so far — the banner's media count. */
    private var mediaNamed = HashSet<String>()
    private var mediaSent = HashSet<String>()

    /** One pass at a time; a cancel's publishing waits for the pass in flight to end. */
    private val passLock = Mutex()
    private var driver: Job? = null

    val keys = MediaKeysSender(host, File(dir, "media-keys.json"), now) { noteSendingKeys() }

    private val stateFile = File(dir, "history.json")

    init {
        dir.mkdirs()
        load()
        refresh()
    }

    // ---- persistence --------------------------------------------------------------------------

    private fun load() = synchronized(lock) {
        val o = runCatching { JSONObject(stateFile.readText()) }.getOrNull() ?: return@synchronized
        account = o.optString("account")
        runCatching {
            o.optJSONObject("ledger")?.let { ledger.load(it) }
            o.optJSONArray("serves")?.let { a ->
                for (i in 0 until a.length()) Serve.from(a.getJSONObject(i)).let { serves[it.device] = it }
            }
        }.onFailure { Log.w(TAG, "history hand-off state unreadable", it) }
    }

    private fun save() = synchronized(lock) {
        val o = JSONObject().put("account", account).put("ledger", ledger.toJson())
            .put("serves", JSONArray(serves.values.map { it.toJson() }))
        MediaFiles.writeAtomic(stateFile, o.toString().toByteArray(Charsets.UTF_8))
        Unit
    }

    /** Keep a run's progress, unless it was cancelled while the pass was waiting on the network. */
    private fun keep(run: Serve) {
        synchronized(lock) {
            if (!ledger.acceptsServe(run.device, run.requestAt)) return
            serves[run.device] = run
            save()
        }
        refresh()
    }

    private fun accepts(run: Serve) = synchronized(lock) { ledger.acceptsServe(run.device, run.requestAt) }

    private fun runMediaFile(device: String, run: String) = File(dir, "run-${device.take(16)}-$run.json")
    private fun loadRunMedia(r: Serve): RunMedia =
        runCatching { RunMedia.from(JSONObject(runMediaFile(r.device, r.run).readText())) }.getOrDefault(RunMedia())
    private fun saveRunMedia(m: RunMedia, r: Serve) {
        MediaFiles.writeAtomic(runMediaFile(r.device, r.run), m.toJson().toString().toByteArray(Charsets.UTF_8))
    }

    private fun drop(device: String) {
        synchronized(lock) {
            val old = serves.remove(device) ?: return
            runMediaFile(old.device, old.run).delete()
            lastManifestTouch.remove(device)
            save()
        }
        refresh()
    }

    // ---- status -------------------------------------------------------------------------------

    /** Devices this one is serving. Own-device media asks from them are streamed. */
    val handoffTargets: List<String> get() = synchronized(lock) { serves.keys.toList() }

    private fun stillSending(): Boolean = synchronized(lock) {
        HW.stillSending(serves.values.any { !it.complete }, needsPending, lastSendingAt, now())
    }

    fun status(): Status = synchronized(lock) {
        val progress = keys.progress()
        if (stillSending()) {
            var st = Status(Phase.SENDING)
            val run = serves.values.firstOrNull { !it.complete } ?: serves.values.firstOrNull()
            if (run != null) {
                st = st.copy(done = run.servedEvents, total = run.totalEvents)
                // Media is counted only when the other device is taking it from here: a browser
                // reads its photos from the relay, and "0 of 4,000 photos" would never move.
                if (needsPending || mediaSent.isNotEmpty()) {
                    st = st.copy(mediaDone = mediaSent.size, mediaTotal = mediaNamed.size)
                }
            }
            // With no posts left to send, what is going out is a browser's access to older media.
            if (serves.values.none { !it.complete } && !needsPending && progress != null) {
                st = st.copy(done = 0, total = 0, mediaDone = progress.first, mediaTotal = progress.second)
            }
            st
        } else {
            ledger.banner?.let {
                Status(Phase.CANCELLED, cancelledRemotely = it == HandoffCancelLedger.Banner.BY_OTHER_DEVICE)
            } ?: Status()
        }
    }

    fun refresh() = publish(status())

    /** This device did source work: a page, a relayed blob, or a direct media serve. A normal
     *  own-device media ask, with no run open, is not a hand-off. */
    fun noteSending(ref: String? = null) {
        synchronized(lock) {
            if (serves.isEmpty()) return
            lastSendingAt = now()
            if (ref != null && ref in mediaNamed) mediaSent.add(ref)
        }
        refresh()
    }

    private fun noteSendingKeys() {
        synchronized(lock) { lastSendingAt = now() }
        refresh()
    }

    fun dismiss() {
        synchronized(lock) { ledger.banner = null; save() }
        refresh()
    }

    // ---- cancelling ---------------------------------------------------------------------------

    /** "Cancel transfer": stop now, tell the other device over the account lane, and never take
     *  these requests up again. Works offline: the stop record waits and goes out later. */
    fun cancelTransfer() {
        val stopped: List<Serve>
        synchronized(lock) {
            val acct = host.accountHex()
            stopped = serves.values.toList()
            ledger.cancelAsSource(acct, host.deviceHex(), stopped.map { it.ledgerRun() }, remote = false, now = now())
            // Only media keys were still going out: just stop and say so.
            if (stopped.isEmpty()) ledger.banner = HandoffCancelLedger.Banner.BY_THIS_DEVICE
            serves.clear()
            lastSendingAt = 0
            needsPending = false
            mediaNamed = HashSet(); mediaSent = HashSet()
            save()
        }
        keys.cancel()
        refresh()
        scope.launch {
            // After any pass in flight has ended, so nothing of its lands after the stop.
            passLock.lock()
            try {
                publishPendingCancels()
                blankRelayedMedia(stopped)
            } finally {
                passLock.unlock()
            }
        }
    }

    suspend fun publishPendingCancels() {
        val queued = synchronized(lock) { ledger.pending.toList() }
        if (queued.isEmpty() || !host.ready()) return
        var sent = false
        for (s in queued) {
            if (!host.lanePut(s.key, s.body)) continue
            synchronized(lock) { ledger.pending.remove(s); save() }
            sent = true
        }
        if (sent) host.nudgeMyDevices()
    }

    /** Best effort: don't leave a stopped run's media parked on the relay. */
    private suspend fun blankRelayedMedia(runs: List<Serve>) {
        val me = host.deviceHex()
        val acct = host.accountHex()
        for (r in runs) {
            val m = loadRunMedia(r)
            runMediaFile(r.device, r.run).delete()
            for ((ref, chunks) in m.uploaded) {
                for (c in 0 until chunks) {
                    host.lanePut(HW.mediaChunkKey(acct, r.device, me, r.run, ref, c), ByteArray(0))
                }
            }
            for (n in m.relayed) host.lanePut(HW.mediaReadyKey(acct, r.device, me, r.run, n), ByteArray(0))
        }
    }

    /** Identity switch / factory reset: a run belongs to one account. */
    fun reset() {
        keys.reset()
        synchronized(lock) {
            for (r in serves.values) runMediaFile(r.device, r.run).delete()
            serves.clear()
            ledger = HandoffCancelLedger()
            account = ""
            lastSendingAt = 0
            needsPending = false
            lastManifestTouch.clear()
            mediaNamed = HashSet(); mediaSent = HashSet()
            stateFile.delete()
        }
        refresh()
    }

    // ---- driving it ---------------------------------------------------------------------------

    /** Run a pass now, and keep going back to back while something is moving (the mailbox poll
     *  alone stretches to minutes on an idle phone). A no-op while the loop already runs. */
    fun poke() {
        synchronized(lock) {
            if (driver?.isActive == true) return
            driver = scope.launch {
                while (isActive) {
                    val moved = runCatching { tick(25_000) }
                        .onFailure { if (it is kotlinx.coroutines.CancellationException) throw it; Log.w(TAG, "hand-off pass failed", it) }
                        .getOrDefault(false)
                    if (!stillSending()) break
                    delay(if (moved) 1_000L else 6_000L)
                }
                refresh()
            }
        }
    }

    /** One bounded step of both senders. Cheap with nothing to do: two LISTs of tiny prefixes.
     *  True if anything was uploaded. */
    suspend fun tick(budgetMs: Long, waitForTurn: Boolean = false): Boolean {
        if (waitForTurn) passLock.lock() else if (!passLock.tryLock()) return false
        try {
            publishPendingCancels()
            if (host.suspendHeavyIO() || !host.ready() || !host.holdsAccountSeed()) return false
            val deadline = now() + budgetMs
            var moved = serve(deadline)
            if (now() < deadline && keys.serve(deadline)) moved = true
            return moved
        } finally {
            passLock.unlock()
            refresh()
        }
    }

    // ---- source -------------------------------------------------------------------------------

    private suspend fun serve(deadline: Long): Boolean {
        val acct = host.accountHex().lowercase()
        if (acct.isEmpty() || host.circleIds().isEmpty()) return false
        val me = host.deviceHex().lowercase()
        synchronized(lock) {
            if (account != acct) {
                if (account.isNotEmpty()) { serves.clear(); ledger = HandoffCancelLedger() }
                account = acct
                save()
            }
        }
        // An abandoned run (the target never finished) is dropped after three days.
        val cutoff = now() - HW.ABANDONED_MS
        for (d in synchronized(lock) { serves.values.filter { (it.run.toLongOrNull() ?: 0L) < cutoff }.map { it.device } }) {
            drop(d)
        }
        var did = false
        for (key in host.laneList(HW.requestPrefix(acct))) {
            if (now() >= deadline) break
            val device = key.substringAfterLast('/').lowercase()
            if (device.length != 64 || device == me) continue
            val req = host.laneGet(key)?.let { HW.Request.decode(it) } ?: continue
            val verdict = synchronized(lock) { ledger.verdict(device, req) }
            if (verdict == HandoffCancelLedger.Verdict.FINISHED) { drop(device); continue }
            if (verdict == HandoffCancelLedger.Verdict.DECLINED) continue
            if (verdict == HandoffCancelLedger.Verdict.CANCELLED_BY_TARGET) {
                val old = synchronized(lock) {
                    val s = serves.remove(device)
                    if (s != null) {
                        ledger.cancelAsSource(acct, me, listOf(s.ledgerRun()), remote = true, now = now())
                        lastSendingAt = 0
                        needsPending = false
                    }
                    ledger.decline(device, req.at)
                    save()
                    s
                }
                if (old != null) blankRelayedMedia(listOf(old))
                continue
            }
            var run = synchronized(lock) { serves[device] }?.takeIf { it.requestAt == req.at }
            // Learn the new device first, so the key commit on every page is sealed to it. Only a
            // device the account's own signed roster lists is served: a page is sealed to devices
            // the roster names, never to a key that merely asks.
            if (run == null) {
                if (anotherSourceIsServing(acct, device, req.at, me)) continue
                req.roster?.let { b64 ->
                    runCatching { java.util.Base64.getDecoder().decode(b64) }.getOrNull()?.let { host.ingestOwnRoster(it) }
                }
            }
            if (host.accountDevices().none { it.equals(device, ignoreCase = true) }) continue
            if (run == null) {
                val order = host.circleIds()
                run = Serve(device, req.at, now().toString(), order, order.sumOf { host.historyEventCount(it) })
                synchronized(lock) {
                    ledger.banner = null
                    mediaNamed = HashSet(); mediaSent = HashSet()
                }
                keep(run)
                Log.i(TAG, "history hand-off: serving ${device.take(8)} — ${order.size} circles")
            }
            if (!accepts(run)) continue
            if (!run.complete && serveRun(run, acct, me, deadline)) did = true
            if (run.complete && !run.keptSent && now() < deadline && serveKeptStories(run, acct, me)) did = true
            // Heartbeat while the hand-off is unfinished: the target's "is the source awake?" test
            // is this timestamp, and direct media depends on it.
            val t = now()
            if (t - (synchronized(lock) { lastManifestTouch[device] } ?: 0L) > 30_000) {
                synchronized(lock) { lastManifestTouch[device] = t }
                putManifest(run, acct, me)
            }
            keep(run)
            if (now() < deadline && serveNeeds(run, acct, me, deadline)) did = true
        }
        return did
    }

    private suspend fun anotherSourceIsServing(acct: String, target: String, request: Long, me: String): Boolean {
        for (key in host.laneList(HW.manifestPrefix(acct, target))) {
            val m = host.laneGet(key)?.let { HW.Manifest.decode(it) } ?: continue
            if (m.source.lowercase() == me || m.forRequest < request) continue
            if (m.cancelled == true || m.isLive(now())) return true
        }
        return false
    }

    /** One page per circle in turn, newest first everywhere, so the new device sees what is recent
     *  in every circle before any circle's distant past. */
    private suspend fun serveRun(run: Serve, acct: String, me: String, deadline: Long): Boolean {
        var did = false
        while (!run.complete && now() < deadline && accepts(run)) {
            val pending = run.order.filterNot { it in run.finished }
            if (pending.isEmpty()) {
                run.complete = true
                keep(run)
                putManifest(run, acct, me)
                Log.i(TAG, "history hand-off: served ${run.device.take(8)} — ${run.pages} pages")
                break
            }
            for (cid in pending) {
                if (now() >= deadline || !accepts(run) || host.suspendHeavyIO()) return did
                // The engine went away (identity switch): resume from this cursor later.
                val page = host.exportHistoryPage(cid, run.cursors[cid] ?: 0L, HW.PAGE_EVENTS) ?: return did
                if (page.events == 0u) { run.finished.add(cid); continue }
                // Name the page's media this device holds, so a phone can ask for it.
                val media = HW.blobRefs(page.mediaRefs).mapNotNull { ref ->
                    host.localMediaSize(ref)?.let { HW.MediaItem(ref, it) }
                }
                val blob = HW.encodePage(cid, page.envelopes, media)
                // No relay took it: resume from this cursor on the next pass.
                if (!host.lanePut(HW.pageKey(acct, run.device, me, run.run, run.pages), blob)) return did
                if (!accepts(run)) return did
                if (media.isNotEmpty()) notePageMedia(run, run.pages, cid, media.map { it.ref })
                run.pages += 1
                run.servedEvents += page.events.toLong()
                run.cursors[cid] = page.oldestMs.toLong()
                synchronized(lock) { lastSendingAt = now() }
                keep(run)
                putManifest(run, acct, me)
                did = true
                delay(40)   // air between pages: each export holds the engine for real crypto
            }
        }
        return did
    }

    private fun notePageMedia(run: Serve, page: Int, circle: String, refs: List<String>) {
        val m = loadRunMedia(run)
        m.pages[page] = RunMedia.PageMedia(circle, refs)
        saveRunMedia(m, run)
        synchronized(lock) { mediaNamed.addAll(refs) }
    }

    /** Kept stories outlive their 24h post, so no history page names their media: one extra
     *  media-only page after the run's last. Sealed via the personal `default` circle. */
    private suspend fun serveKeptStories(run: Serve, acct: String, me: String): Boolean {
        val media = HW.blobRefs(host.keptStoryMedia()).mapNotNull { ref ->
            host.localMediaSize(ref)?.let { HW.MediaItem(ref, it) }
        }
        if (media.isEmpty()) { run.keptSent = true; return false }
        val cid = "default"
        val blob = HW.encodePage(cid, emptyList(), media)
        if (!host.lanePut(HW.pageKey(acct, run.device, me, run.run, run.pages), blob) || !accepts(run)) return false
        notePageMedia(run, run.pages, cid, media.map { it.ref })
        run.pages += 1
        run.keptSent = true
        synchronized(lock) { lastSendingAt = now() }
        keep(run)
        putManifest(run, acct, me)
        return true
    }

    private suspend fun putManifest(run: Serve, acct: String, me: String) {
        // Cancelled: the stop record is the last word — never overwrite it with a live one.
        if (!accepts(run)) return
        val m = HW.Manifest(run.run, me, run.requestAt, run.pages, run.complete, now(),
            run.totalEvents, run.servedEvents)
        host.lanePut(HW.manifestKey(acct, run.device, me), m.encode())
    }

    /** RELAY fallback for media: upload every page's blobs the target asked for, then mark the page
     *  ready. Resumable — what is already up is remembered per run. */
    private suspend fun serveNeeds(run: Serve, acct: String, me: String, deadline: Long): Boolean {
        val asked = host.laneList(HW.needPrefix(acct, run.device, me, run.run))
            .mapNotNull { k -> k.substringAfterLast('/').toIntOrNull()?.let { it to k } }
            .sortedBy { it.first }
        if (asked.isEmpty()) { synchronized(lock) { needsPending = false }; return false }
        val rm = loadRunMedia(run)
        fun notePending() = synchronized(lock) { needsPending = asked.any { it.first !in rm.relayed } }
        notePending()
        var did = false
        try {
            for ((n, key) in asked) {
                if (!accepts(run)) break
                if (n in rm.relayed) continue
                // A withdrawn need (empty body): the target got this page's media directly.
                val body = host.laneGet(key)
                if (body != null && body.isEmpty()) { rm.relayed.add(n); saveRunMedia(rm, run); continue }
                val pm = rm.pages[n]
                val ready = ArrayList<Pair<String, Int>>()
                for (ref in pm?.refs ?: emptyList()) {
                    val already = rm.uploaded[ref]
                    if (already != null) { ready.add(ref to already); continue }
                    if (now() >= deadline || !accepts(run) || host.suspendHeavyIO()) return did
                    if (host.localMediaSize(ref) == null) continue   // evicted since: not ours to send
                    // Held but not sealable right now, or no relay took it: resume on a later pass.
                    val chunks = uploadMedia(ref, pm!!.circle, acct, run, me) ?: return did
                    rm.uploaded[ref] = chunks
                    ready.add(ref to chunks)
                    saveRunMedia(rm, run)
                    did = true
                    noteSending(ref)
                    // Progressive: the target downloads while the rest of the page goes up.
                    host.lanePut(HW.mediaReadyKey(acct, run.device, me, run.run, n),
                        HW.MediaReady(ready, complete = false).encode())
                }
                if (!accepts(run)) break
                if (!host.lanePut(HW.mediaReadyKey(acct, run.device, me, run.run, n),
                        HW.MediaReady(ready, complete = true).encode())) break
                rm.relayed.add(n)
                saveRunMedia(rm, run)
                did = true
            }
        } finally {
            notePending()
        }
        return did
    }

    /** Seal one blob to a temp file and put it on the lane in fixed chunks — never the whole video
     *  in memory. Returns the chunk count, null if any step failed. */
    private suspend fun uploadMedia(ref: String, circle: String, acct: String, run: Serve, me: String): Int? {
        val sealed = host.sealMediaForHandoff(circle, ref) ?: return null
        try {
            var index = 0
            sealed.inputStream().use { input ->
                val buf = ByteArray(HW.MEDIA_CHUNK_BYTES)
                while (true) {
                    var filled = 0
                    while (filled < buf.size) {
                        val r = input.read(buf, filled, buf.size - filled)
                        if (r < 0) break
                        filled += r
                    }
                    if (filled == 0) break
                    if (!accepts(run)) return null
                    if (!host.lanePut(HW.mediaChunkKey(acct, run.device, me, run.run, ref, index),
                            buf.copyOf(filled))) return null
                    index++
                }
            }
            return index.takeIf { it > 0 }
        } finally {
            sealed.delete()
        }
    }

    companion object {
        private const val TAG = "HistoryHandoff"

        /** What the UI shows. */
        val banner = mutableStateOf(Status())

        /** Set once the engine is up ([HavenNet.init]). */
        @Volatile var shared: HistoryHandoff? = null
    }
}

internal fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
