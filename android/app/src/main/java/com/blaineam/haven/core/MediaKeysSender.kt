package com.blaineam.haven.core

import android.util.Log
import com.blaineam.haven.core.HistoryHandoffWire as HW
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Per-item media keys, sending side (docs/DECISIONS.md D27; core `mediakeys.rs` and Apple
 * `MediaKeys.swift` are the same job).
 *
 * A linked browser never holds the account key, and the circle keys that open older media are
 * deleted everywhere after a few rotations. This device holds the account key, so it can unwrap one
 * blob's own content key from the blob's last few kilobytes. It does that once for every blob the
 * account's posts name, newest first, and sends the keys signed by the account and sealed to that
 * browser alone. Nothing is uploaded again; the browser then loads from the relay.
 *
 * [HistoryHandoff] drives it, one pass at a time.
 */
class MediaKeysSender(
    private val host: HandoffHost,
    private val file: File,
    private val now: () -> Long = System::currentTimeMillis,
    private val onProgress: () -> Unit = {},
) {
    private class Job(
        val device: String,
        val requestAt: Long,
        val run: String,
        /** `(circle, ref)` still to go, newest first. */
        var left: List<Pair<String, String>>,
        val total: Int,
    ) {
        var missing = 0
        var batches = 0
        var complete = false
        /** The last pass could not finish a batch. Looking the same blobs up again is not progress:
         *  counted as such, it would keep the drive loop (and the screen) going for as long as one
         *  relay stayed away. In memory only. */
        var stalled = false

        fun toJson(): JSONObject = JSONObject().put("device", device).put("requestAt", requestAt).put("run", run)
            .put("left", JSONArray(left.map { JSONArray().put(it.first).put(it.second) }))
            .put("total", total).put("missing", missing).put("batches", batches).put("complete", complete)

        companion object {
            fun from(o: JSONObject): Job {
                val a = o.getJSONArray("left")
                val left = (0 until a.length()).map { a.getJSONArray(it).let { p -> p.getString(0) to p.getString(1) } }
                return Job(o.getString("device"), o.getLong("requestAt"), o.getString("run"), left, o.getInt("total"))
                    .also {
                        it.missing = o.optInt("missing")
                        it.batches = o.optInt("batches")
                        it.complete = o.optBoolean("complete")
                    }
            }
        }
    }

    private val lock = Any()
    private val jobs = HashMap<String, Job>()
    /** Requests the person stopped here ("device|at"): never served again. */
    private val declined = LinkedHashSet<String>()
    private var account = ""

    init {
        runCatching {
            val o = JSONObject(file.readText())
            account = o.optString("account")
            o.optJSONArray("declined")?.let { declined.addAll(it.strings()) }
            o.optJSONArray("jobs")?.let { a ->
                for (i in 0 until a.length()) Job.from(a.getJSONObject(i)).let { jobs[it.device] = it }
            }
        }
    }

    /** A file, not preferences: a large library's list of refs is hundreds of kilobytes. */
    private fun save() = synchronized(lock) {
        val o = JSONObject().put("account", account).put("declined", JSONArray(declined.toList()))
            .put("jobs", JSONArray(jobs.values.map { it.toJson() }))
        file.parentFile?.mkdirs()
        MediaFiles.writeAtomic(file, o.toString().toByteArray(Charsets.UTF_8))
        Unit
    }

    /** Any job still being worked through. */
    fun hasJobs(): Boolean = synchronized(lock) { jobs.values.any { !it.complete } }

    /** `(done, total)` of the unfinished job, for the transfer banner. */
    fun progress(): Pair<Int, Int>? = synchronized(lock) {
        jobs.values.firstOrNull { !it.complete }?.let { (it.total - it.left.size) to it.total }
    }

    /** "Cancel transfer": stop, and don't take these requests up again. */
    fun cancel() = synchronized(lock) {
        for (j in jobs.values) if (!j.complete) declined.add("${j.device}|${j.requestAt}")
        jobs.clear()
        save()
    }

    /** Identity switch / factory reset: a job belongs to one account. */
    fun reset() = synchronized(lock) {
        jobs.clear()
        declined.clear()
        account = ""
        file.delete()
        Unit
    }

    /** Answer open requests from my other devices until [deadline]. True if anything was sent. */
    suspend fun serve(deadline: Long): Boolean {
        // Only a device holding the account key can: it opens a recipient entry and signs a batch.
        if (!host.ready() || !host.holdsAccountSeed() || host.suspendHeavyIO()) return false
        val acct = host.accountHex().lowercase()
        if (acct.isEmpty() || host.circleIds().isEmpty()) return false
        val me = host.deviceHex().lowercase()
        synchronized(lock) {
            if (account != acct) {
                if (account.isNotEmpty()) { jobs.clear(); declined.clear() }
                account = acct
                save()
            }
            val cutoff = now() - HW.ABANDONED_MS
            if (jobs.values.removeAll { (it.run.toLongOrNull() ?: 0L) < cutoff }) save()
        }
        var did = false
        for (key in host.laneList(HW.keysRequestPrefix(acct))) {
            if (now() >= deadline) break
            val device = key.substringAfterLast('/').lowercase()
            if (device.length != 64 || device == me) continue
            val req = host.laneGet(key)?.let { HW.KeysRequest.decode(it) } ?: continue
            if (req.done == true) {
                synchronized(lock) { if (jobs.remove(device) != null) save() }
                continue
            }
            if (synchronized(lock) { "$device|${req.at}" in declined }) continue
            // Only a device the account's own signed roster lists (the core refuses to seal to any
            // other as well).
            if (host.accountDevices().none { it.equals(device, ignoreCase = true) }) continue
            var job = synchronized(lock) { jobs[device] }?.takeIf { it.requestAt == req.at }
            if (job == null) {
                if (anotherSourceSends(acct, device, req.at, me)) continue
                val items = ArrayList(host.historyMediaRefs())
                // Kept stories outlive their 24-hour post, so no post names their media any more.
                val named = items.mapTo(HashSet()) { it.second }
                items.addAll(HW.blobRefs(host.keptStoryMedia()).filterNot { it in named }.map { "default" to it })
                job = Job(device, req.at, now().toString(), items, items.size)
                synchronized(lock) { jobs[device] = job; save() }
                Log.i(TAG, "media keys: ${device.take(8)} asked — ${items.size} blobs")
            }
            if (job.complete) continue
            if (run(job, acct, me, deadline)) did = true
        }
        return did
    }

    private suspend fun anotherSourceSends(acct: String, target: String, request: Long, me: String): Boolean {
        for (key in host.laneList(HW.keysManifestPrefix(acct, target))) {
            val m = host.laneGet(key)?.let { HW.KeysManifest.decode(it) } ?: continue
            if (m.source.lowercase() != me && m.forRequest >= request && m.isLive(now())) return true
        }
        return false
    }

    /** Still this job: not cancelled or reset while a lookup was waiting on the network. */
    private fun isCurrent(job: Job) = synchronized(lock) { jobs[job.device] === job }

    private suspend fun run(job: Job, acct: String, me: String, deadline: Long): Boolean {
        var did = false
        var batchesThisPass = 0
        while (batchesThisPass < BATCHES_PER_PASS && job.left.isNotEmpty() && now() < deadline) {
            batchesThisPass++
            val batch = job.left.take(HW.KEY_BATCH)
            val entries = ArrayList<ByteArray>()
            var missing = 0
            for (group in batch.chunked(PARALLEL)) {
                if (host.suspendHeavyIO()) return did
                val found = coroutineScope {
                    group.map { (circle, ref) -> async { host.findItemKey(circle, ref) } }.awaitAll()
                }
                for (f in found) when (f) {
                    is ItemKeyResult.Found -> entries.add(f.entry)
                    ItemKeyResult.Missing -> missing++
                    ItemKeyResult.Unreachable -> {
                        // Leave the whole batch for a pass that can reach the relay.
                        job.stalled = true
                        if (isCurrent(job)) putManifest(job, acct, me)
                        return did
                    }
                }
                if (!isCurrent(job)) return did
                if (!job.stalled) onProgress()
            }
            if (entries.isNotEmpty()) {
                val grant = host.sealItemKeys(job.device, entries)
                if (grant == null) {
                    Log.w(TAG, "media keys: could not seal a batch to ${job.device.take(8)}")
                    job.stalled = true
                    return did
                }
                if (!host.lanePut(HW.keysBatchKey(acct, job.device, me, job.run, job.batches), grant)) {
                    job.stalled = true
                    return did
                }
            }
            synchronized(lock) {
                if (!isCurrent(job)) return did
                if (entries.isNotEmpty()) job.batches++
                job.left = job.left.drop(batch.size)
                job.missing += missing
                job.stalled = false
                save()
            }
            did = true
            putManifest(job, acct, me)
            onProgress()
        }
        if (job.left.isEmpty() && !job.complete && isCurrent(job)) {
            synchronized(lock) { job.complete = true; save() }
            putManifest(job, acct, me)
            onProgress()
            Log.i(TAG, "media keys: sent to ${job.device.take(8)} — ${job.total} blobs, ${job.missing} without a key")
            did = true
        }
        return did
    }

    private suspend fun putManifest(job: Job, acct: String, me: String) {
        val m = HW.KeysManifest(job.run, me, job.requestAt, job.batches, job.complete, now(),
            job.total, job.total - job.left.size, job.missing)
        host.lanePut(HW.keysManifestKey(acct, job.device, me), m.encode())
    }

    private companion object {
        const val TAG = "MediaKeys"
        /** Batches worked through per pass, and blobs looked up at once within one. */
        const val BATCHES_PER_PASS = 5
        const val PARALLEL = 4
    }
}
