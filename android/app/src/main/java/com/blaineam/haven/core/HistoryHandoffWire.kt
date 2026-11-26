package com.blaineam.haven.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * The wire format of the two hand-offs between devices of ONE account: history pages
 * (docs/DECISIONS.md D26) and per-item media keys (D27). Everything lives on the account lane
 * (`haven/self/<account>/…`). Apple `HistoryHandoffWire.swift` and core `historyhandoff.rs` /
 * `mediakeys.rs` match these byte for byte; Android is a SOURCE only. Pure Kotlin (org.json), so
 * the JVM unit tests cover it without a device.
 */
object HistoryHandoffWire {
    // ---- history keys -------------------------------------------------------------------------
    fun lane(acct: String) = "haven/self/${acct.lowercase()}/"
    fun requestPrefix(acct: String) = lane(acct) + "history-req/"
    fun requestKey(acct: String, target: String) = requestPrefix(acct) + target.lowercase()
    fun manifestPrefix(acct: String, target: String) = lane(acct) + "history-m/${target.lowercase()}/"
    fun manifestKey(acct: String, target: String, source: String) = manifestPrefix(acct, target) + source.lowercase()
    private fun runPrefix(acct: String, target: String, source: String, run: String) =
        lane(acct) + "history/${target.lowercase()}/${source.lowercase()}/$run/"
    fun pageKey(acct: String, target: String, source: String, run: String, n: Int) =
        runPrefix(acct, target, source, run) + n

    // ---- media relay fallback (a phone target asks for a page's media on the relay) -----------
    fun needPrefix(acct: String, target: String, source: String, run: String) =
        lane(acct) + "history-need/${target.lowercase()}/${source.lowercase()}/$run/"
    fun mediaChunkKey(acct: String, target: String, source: String, run: String, ref: String, i: Int) =
        runPrefix(acct, target, source, run) + "m/${keySafe(ref)}/$i"
    fun mediaReadyKey(acct: String, target: String, source: String, run: String, page: Int) =
        runPrefix(acct, target, source, run) + "mready/$page"

    /** Refs are `<kind>:<hash>`: relay path segments stay plain ASCII (no dots, so no `..`). */
    fun keySafe(ref: String): String = buildString {
        for (c in ref) append(if (c.code < 128 && (c.isLetterOrDigit() || c == '-')) c else '_')
    }

    // ---- per-item media key keys --------------------------------------------------------------
    fun keysRequestPrefix(acct: String) = lane(acct) + "media-keys-req/"
    fun keysRequestKey(acct: String, target: String) = keysRequestPrefix(acct) + target.lowercase()
    fun keysManifestPrefix(acct: String, target: String) = lane(acct) + "media-keys-m/${target.lowercase()}/"
    fun keysManifestKey(acct: String, target: String, source: String) =
        keysManifestPrefix(acct, target) + source.lowercase()
    fun keysBatchKey(acct: String, target: String, source: String, run: String, n: Int) =
        lane(acct) + "media-keys/${target.lowercase()}/${source.lowercase()}/$run/$n"

    // ---- limits -------------------------------------------------------------------------------
    /** Events per page (Apple `pageEvents`, core `PAGE_EVENTS`). */
    const val PAGE_EVENTS = 120
    /** A source whose manifest has not moved for this long is presumed gone. */
    const val STALE_SOURCE_MS = 45L * 60 * 1000
    /** A run or key job older than this is dropped. */
    const val ABANDONED_MS = 3L * 24 * 3_600_000
    /** After the last thing went up, the sending banner stays this long. */
    const val SENDING_LINGER_MS = 120L * 1000
    const val MEDIA_CHUNK_BYTES = 8 * 1024 * 1024
    /** Blobs per key batch. */
    const val KEY_BATCH = 40
    /** The closing bytes of a blob read first: its signature and about fifty recipient entries. */
    const val KEY_TAIL_BYTES = 64 * 1024

    // ---- records ------------------------------------------------------------------------------

    private fun parse(bytes: ByteArray): JSONObject? =
        runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull()
    private fun JSONObject.bytes() = toString().toByteArray(Charsets.UTF_8)
    private fun JSONObject.optBool(name: String): Boolean? = if (has(name) && !isNull(name)) optBoolean(name) else null
    private fun JSONObject.optLongOrNull(name: String): Long? = if (has(name) && !isNull(name)) optLong(name) else null

    /** The history ask. Android reads these; it never writes one. */
    data class Request(
        val device: String,
        val at: Long,
        val done: Boolean? = null,
        /** The asking device's account-signed roster wire, base64. */
        val roster: String? = null,
        val cancelled: Boolean? = null,
    ) {
        fun encode(): ByteArray = JSONObject().put("v", 1).put("device", device).put("at", at)
            .putOpt("done", done).putOpt("roster", roster).putOpt("cancelled", cancelled).bytes()

        companion object {
            fun decode(b: ByteArray): Request? = parse(b)?.let { o ->
                runCatching {
                    Request(o.getString("device"), o.getLong("at"), o.optBool("done"),
                        o.optString("roster").ifEmpty { null }, o.optBool("cancelled"))
                }.getOrNull()
            }
        }
    }

    /** A source's progress on one history run. */
    data class Manifest(
        val run: String,
        val source: String,
        val forRequest: Long,
        val pages: Int,
        val complete: Boolean,
        val updatedAt: Long?,
        val totalEvents: Long? = null,
        val servedEvents: Long? = null,
        val cancelled: Boolean? = null,
    ) {
        fun isLive(now: Long): Boolean = complete || now - (updatedAt ?: 0L) < STALE_SOURCE_MS

        fun encode(): ByteArray = JSONObject().put("v", 1).put("run", run).put("source", source)
            .put("forRequest", forRequest).put("pages", pages).put("complete", complete)
            .putOpt("updatedAt", updatedAt).putOpt("totalEvents", totalEvents)
            .putOpt("servedEvents", servedEvents).putOpt("cancelled", cancelled).bytes()

        companion object {
            fun decode(b: ByteArray): Manifest? = parse(b)?.let { o ->
                runCatching {
                    Manifest(o.getString("run"), o.getString("source"), o.getLong("forRequest"), o.getInt("pages"),
                        o.getBoolean("complete"), o.optLongOrNull("updatedAt"), o.optLongOrNull("totalEvents"),
                        o.optLongOrNull("servedEvents"), o.optBool("cancelled"))
                }.getOrNull()
            }
        }
    }

    data class KeysRequest(val device: String, val at: Long, val done: Boolean? = null) {
        fun encode(): ByteArray =
            JSONObject().put("v", 1).put("device", device).put("at", at).putOpt("done", done).bytes()

        companion object {
            fun decode(b: ByteArray): KeysRequest? = parse(b)?.let { o ->
                runCatching { KeysRequest(o.getString("device"), o.getLong("at"), o.optBool("done")) }.getOrNull()
            }
        }
    }

    data class KeysManifest(
        val run: String,
        val source: String,
        val forRequest: Long,
        val batches: Int,
        val complete: Boolean,
        val updatedAt: Long,
        val total: Int,
        val done: Int,
        val missing: Int,
    ) {
        fun isLive(now: Long): Boolean = complete || now - updatedAt < STALE_SOURCE_MS

        fun encode(): ByteArray = JSONObject().put("v", 1).put("run", run).put("source", source)
            .put("forRequest", forRequest).put("batches", batches).put("complete", complete)
            .put("updatedAt", updatedAt).put("total", total).put("done", done).put("missing", missing).bytes()

        companion object {
            fun decode(b: ByteArray): KeysManifest? = parse(b)?.let { o ->
                runCatching {
                    KeysManifest(o.getString("run"), o.getString("source"), o.getLong("forRequest"),
                        o.getInt("batches"), o.getBoolean("complete"), o.getLong("updatedAt"), o.getInt("total"),
                        o.getInt("done"), o.getInt("missing"))
                }.getOrNull()
            }
        }
    }

    /** One media blob a page names: content ref and size (the target's progress + wait budgets). */
    data class MediaItem(val ref: String, val size: Long)

    /** Written once page n's media is on the relay; rewritten after each upload, `complete` last. */
    data class MediaReady(val items: List<Pair<String, Int>>, val complete: Boolean) {
        fun encode(): ByteArray = JSONObject().put("v", 1)
            .put("items", JSONArray(items.map { JSONObject().put("ref", it.first).put("chunks", it.second) }))
            .put("complete", complete).bytes()
    }

    /** The content refs behind a page's signed media lists: every variant marker expands to the
     *  blobs it pairs, plain entries pass through. Deduped, in order. Synthetic entries (a location
     *  pin) name no blob. */
    fun blobRefs(entries: List<String>): List<String> {
        val out = LinkedHashSet<String>()
        for (e in entries) {
            val pair = MediaVariants.parsePoster(e) ?: MediaVariants.parseThumb(e)
                ?: MediaVariants.parsePreview(e) ?: MediaVariants.parseOriginal(e)
            if (pair != null) { out.add(pair.first); out.add(pair.second) }
            else if (!LocalMedia.isSynthetic(e)) out.add(e)
        }
        out.remove("")
        return out.toList()
    }

    /** The end of a chunked blob: the end of the chunk before the last, then the last. */
    fun joinTail(before: ByteArray?, last: ByteArray): ByteArray {
        if (before == null || last.size >= KEY_TAIL_BYTES) return last
        val from = maxOf(0, before.size - (KEY_TAIL_BYTES - last.size))
        return before.copyOfRange(from, before.size) + last
    }

    // ---- page codec ---------------------------------------------------------------------------
    //
    //   "HVH2" ‖ u16 circle-id length ‖ circle id ‖ u32 count ‖ count × (u32 length ‖ envelope)
    //          ‖ u32 media count ‖ count × (u16 ref length ‖ ref ‖ u64 size), little-endian.
    //   "HVH1" is the same without the media list. One circle per page.

    private fun ByteArrayOutputStream.le(v: Long, bytes: Int) {
        for (i in 0 until bytes) write(((v ushr (8 * i)) and 0xFF).toInt())
    }

    fun encodePage(circleId: String, envelopes: List<ByteArray>, media: List<MediaItem> = emptyList()): ByteArray {
        val out = ByteArrayOutputStream()
        out.write("HVH2".toByteArray())
        val cid = circleId.toByteArray(Charsets.UTF_8)
        out.le(cid.size.toLong(), 2); out.write(cid)
        out.le(envelopes.size.toLong(), 4)
        for (e in envelopes) { out.le(e.size.toLong(), 4); out.write(e) }
        out.le(media.size.toLong(), 4)
        for (m in media) {
            val r = m.ref.toByteArray(Charsets.UTF_8)
            out.le(r.size.toLong(), 2); out.write(r); out.le(maxOf(0L, m.size), 8)
        }
        return out.toByteArray()
    }

    class Page(val circleId: String, val envelopes: List<ByteArray>, val media: List<MediaItem>)

    /** For the tests, which read back what this device uploaded. Null = not a page. */
    fun decodePage(data: ByteArray): Page? {
        if (data.size < 10) return null
        val v2 = String(data, 0, 4, Charsets.ISO_8859_1) == "HVH2"
        if (!v2 && String(data, 0, 4, Charsets.ISO_8859_1) != "HVH1") return null
        var i = 4
        fun take(n: Long): ByteArray? {
            if (n < 0 || n > data.size - i) return null
            return data.copyOfRange(i, i + n.toInt()).also { i += n.toInt() }
        }
        fun uint(n: Int): Long? = take(n.toLong())?.let { s ->
            (0 until n).fold(0L) { acc, k -> acc or ((s[k].toLong() and 0xFF) shl (8 * k)) }
        }
        val cid = String(take(uint(2) ?: return null) ?: return null, Charsets.UTF_8)
        val count = uint(4) ?: return null
        if (count > data.size / 4) return null
        val envs = ArrayList<ByteArray>()
        repeat(count.toInt()) { envs.add(take(uint(4) ?: return null) ?: return null) }
        val media = ArrayList<MediaItem>()
        if (v2) {
            val mc = uint(4) ?: return null
            if (mc > data.size / 10) return null
            repeat(mc.toInt()) {
                val ref = take(uint(2) ?: return null) ?: return null
                media.add(MediaItem(String(ref, Charsets.UTF_8), uint(8) ?: return null))
            }
        }
        return Page(cid, envs, media)
    }

    /** Is this device still sending history? A run whose pages are all up is NOT, even though its
     *  record is kept until the other device says it has read everything (a browser may not for
     *  weeks). */
    fun stillSending(hasUnfinishedRun: Boolean, mediaAsked: Boolean, lastSentAt: Long, now: Long): Boolean =
        hasUnfinishedRun || mediaAsked || (lastSentAt > 0 && now >= lastSentAt && now - lastSentAt < SENDING_LINGER_MS)
}

/**
 * The cancel bookkeeping of the history hand-off on the SOURCE side (Apple `HandoffCancelLedger`):
 * which requests this device will not serve, the stop records still to publish, and the
 * "Transfer cancelled" banner. Persisted, so a cancelled transfer never resumes.
 */
class HandoffCancelLedger {
    enum class Banner { BY_THIS_DEVICE, BY_OTHER_DEVICE }
    enum class Verdict { SERVE, FINISHED, CANCELLED_BY_TARGET, DECLINED }
    data class Signal(val key: String, val body: ByteArray) {
        override fun equals(other: Any?) = other is Signal && other.key == key && other.body.contentEquals(body)
        override fun hashCode() = 31 * key.hashCode() + body.contentHashCode()
    }
    /** One run being stopped. */
    data class Run(val device: String, val requestAt: Long, val run: String, val pages: Int,
                   val totalEvents: Long, val servedEvents: Long)

    /** Per target device, the newest request this device will not serve. */
    val declined = HashMap<String, Long>()
    /** Lane records not published yet (the relay was unreachable when the user cancelled). */
    val pending = ArrayList<Signal>()
    var banner: Banner? = null

    fun acceptsServe(device: String, requestAt: Long): Boolean =
        declined[device.lowercase()]?.let { requestAt > it } ?: true

    fun verdict(device: String, request: HistoryHandoffWire.Request): Verdict = when {
        request.done == true -> Verdict.FINISHED
        !acceptsServe(device, request.at) -> Verdict.DECLINED
        request.cancelled == true -> Verdict.CANCELLED_BY_TARGET
        else -> Verdict.SERVE
    }

    fun decline(device: String, requestAt: Long) {
        val dev = device.lowercase()
        declined[dev] = maxOf(declined[dev] ?: 0L, requestAt)
    }

    /** Stop serving [runs]. [remote]: the other device cancelled, so nothing is published. */
    fun cancelAsSource(account: String, me: String, runs: List<Run>, remote: Boolean, now: Long) {
        for (r in runs) {
            decline(r.device, r.requestAt)
            if (remote) continue
            val m = HistoryHandoffWire.Manifest(r.run, me.lowercase(), r.requestAt, r.pages, false, now,
                r.totalEvents, r.servedEvents, cancelled = true)
            val signal = Signal(HistoryHandoffWire.manifestKey(account, r.device, me), m.encode())
            pending.removeAll { it.key == signal.key }
            pending.add(signal)
        }
        if (runs.isNotEmpty()) banner = if (remote) Banner.BY_OTHER_DEVICE else Banner.BY_THIS_DEVICE
    }

    fun toJson(): JSONObject = JSONObject()
        .put("declined", JSONObject(declined.toMap()))
        .put("pending", JSONArray(pending.map {
            JSONObject().put("key", it.key).put("body", String(it.body, Charsets.UTF_8))
        }))
        .putOpt("banner", banner?.name)

    fun load(o: JSONObject) {
        o.optJSONObject("declined")?.let { d -> for (k in d.keys()) declined[k] = d.getLong(k) }
        o.optJSONArray("pending")?.let { a ->
            for (i in 0 until a.length()) a.getJSONObject(i).let {
                pending.add(Signal(it.getString("key"), it.getString("body").toByteArray(Charsets.UTF_8)))
            }
        }
        banner = Banner.entries.firstOrNull { it.name == o.optString("banner") }
    }
}
