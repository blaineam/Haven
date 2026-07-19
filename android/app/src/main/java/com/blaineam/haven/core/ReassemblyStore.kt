package com.blaineam.haven.core

import android.content.Context
import org.json.JSONObject

/**
 * Durable record of a half-finished peer-to-peer chunked media transfer, so a 99%-complete download
 * survives the process being killed instead of restarting from chunk 0. Mirrors iOS
 * `ReassemblyStore` (apple/HavenApp/MediaReassembly.swift).
 *
 * Android's receive path used to accumulate every chunk in a HashMap<Int, ByteArray> and only touch
 * disk once the whole thing had arrived — so the partial existed nowhere but RAM, and an OOM guard
 * SILENTLY DROPPED anything over a quarter of the heap. Chunks now land POSITIONALLY in a temp file
 * (`incoming_*.part`, seek to index × chunkSize), which both removes the memory cap and leaves a
 * sparse file with holes in exactly the right places. All this store adds is remembering, ACROSS
 * LAUNCHES, which holes.
 *
 * BOUNDED ON THREE AXES, because an unbounded fetch index has cost this project a machine before:
 * a transfer nobody has fed in [EXPIRY_MS] expires (record AND part file), the index itself is capped
 * at [MAX_RECORDS] with the oldest progress evicted first, and a record whose part file has vanished
 * is DROPPED rather than resumed into — a bitmap without its bytes is a lie that would leave the ref
 * permanently stalled.
 *
 * A partial can never be mistaken for a complete blob: it lives under `incoming_<key>_<nanos>.part`,
 * a name `LocalMedia.has(ref)` (which looks up the bare storage key) cannot produce.
 *
 * Every mutator is `@Synchronized`: this is touched from the Dispatchers.IO coroutines that handle
 * inbound frames, i.e. from several threads at once.
 */
object ReassemblyStore {
    /** Shares the media-GC prefs file rather than inventing another one (`lastSweep` lives here too). */
    private const val PREFS = "haven.mediagc"
    private const val KEY = "reassembly"

    /** Abandoned partials expire rather than accumulating: a transfer nobody has fed in a day is one
     *  whose sender is gone, and its bytes are just unaccountable disk. */
    const val EXPIRY_MS: Long = 24L * 3600 * 1000

    private const val MAX_RECORDS = 512

    /** The bitmap is rewritten as chunks land, so saving on every one would be pure write churn.
     *  Debounced instead. Persisted progress may therefore LAG the file by up to this long, which is
     *  safe in exactly ONE direction: understating what we have costs a re-sent chunk (a positional
     *  rewrite of identical bytes), while overstating it would leave a permanent hole. Which is why
     *  [note] is only ever called AFTER the chunk's bytes are on disk. */
    private const val SAVE_INTERVAL_MS = 2_000L

    /** [part] is the part file's NAME, not its path: filesDir is not guaranteed to be the same string
     *  on the next launch, so an absolute path recorded today may not resolve tomorrow. Rejoined via
     *  [LocalMedia.partFile]. [got] is the chunk bitmap; [updated] is epoch ms of the last chunk
     *  written, and drives the [EXPIRY_MS] abandonment. */
    data class Record(val ref: String, val part: String, val total: Int, val got: ByteArray, val updated: Long)

    private lateinit var appContext: Context
    private val records = HashMap<String, Record>()
    private var lastSaveAt = 0L

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        synchronized(this) {
            records.clear()
            runCatching {
                val json = prefs.getString(KEY, null) ?: return@runCatching
                val o = JSONObject(json)
                for (ref in o.keys()) {
                    val r = o.getJSONObject(ref)
                    val total = r.getInt("t")
                    val got = unhex(r.getString("g")) ?: continue
                    // Reject on the way IN as well as on the wire: a prefs file can be corrupt or
                    // hand-edited, and a bitmap that doesn't match its total indexes nothing real.
                    if (total < 1 || total > MediaResume.MAX_CHUNKS) continue
                    if (got.size != MediaResume.bitmapSize(total)) continue
                    records[ref] = Record(ref, r.getString("p"), total, got, r.getLong("u"))
                }
            }
        }
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Register a transfer that just started ([force]), or check-point one making progress.
     *  [got] must already be on disk — see [SAVE_INTERVAL_MS]. */
    @Synchronized fun note(ref: String, part: String, total: Int, got: ByteArray, force: Boolean = false) {
        val now = System.currentTimeMillis()
        records[ref] = Record(ref, part, total, got, now)
        // Bound the index: a peer that starts thousands of transfers we never finish must not grow
        // this without limit. Oldest progress goes first, and its scratch goes with it.
        if (records.size > MAX_RECORDS) {
            records.values.sortedBy { it.updated }.take(records.size - MAX_RECORDS).forEach { doomed ->
                records.remove(doomed.ref)
                runCatching { LocalMedia.partFile(doomed.part).delete() }
            }
        }
        if (force || now - lastSaveAt > SAVE_INTERVAL_MS) persist(now)
    }

    /** Forget a transfer — completed, or its partial rejected — and flush IMMEDIATELY, so a relaunch
     *  can never resurrect a reassembly whose bytes are already adopted (or already thrown away). */
    @Synchronized fun clear(ref: String) {
        if (records.remove(ref) == null) return
        persist(System.currentTimeMillis())
    }

    /** The transfers worth picking back up: part file still on disk, and progress inside [EXPIRY_MS].
     *  Anything else is dropped here (and its scratch deleted) rather than resumed into. */
    @Synchronized fun restore(): List<Record> = prune()

    /** Drop expired / vanished records, deleting the scratch of the expired ones. Returns what's left.
     *  Called before the orphan sweep so an abandoned partial is reclaimed at 24h of no progress
     *  rather than waiting out the sweep's 48h mtime grace. */
    @Synchronized fun prune(): List<Record> {
        val cutoff = System.currentTimeMillis() - EXPIRY_MS
        var changed = false
        val alive = ArrayList<Record>()
        for (r in records.values.toList()) {
            val f = LocalMedia.partFile(r.part)
            val exists = f.isFile
            if (!exists || r.updated < cutoff) {
                if (exists) runCatching { f.delete() }
                records.remove(r.ref)
                changed = true
                continue
            }
            alive.add(r)
        }
        if (changed) persist(System.currentTimeMillis())
        return alive
    }

    /** Part-file NAMES the orphan sweep must not reclaim → when each last made progress. The sweep
     *  spares anything still inside [EXPIRY_MS]: a 99%-complete download waiting for the rest is not
     *  leaked scratch, and deleting it was half of why large media never arrived. */
    @Synchronized fun liveParts(): Map<String, Long> = records.values.associate { it.part to it.updated }

    private fun persist(now: Long) {
        lastSaveAt = now
        val o = JSONObject()
        for ((ref, r) in records) {
            o.put(ref, JSONObject().put("p", r.part).put("t", r.total).put("g", hex(r.got)).put("u", r.updated))
        }
        prefs.edit().putString(KEY, o.toString()).apply()
    }

    // Hex rather than Base64 so the codec has no android.util dependency and the stored form is
    // eyeball-debuggable; a 1,600-chunk bitmap is 200 bytes → 400 chars, which prefs handles fine.
    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    private fun unhex(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        return runCatching {
            ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }
        }.getOrNull()
    }
}
