package com.blaineam.haven.core

import uniffi.haven_ffi.HistoryPageFfi
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/** The account lane, the engine and the relays as the hand-off senders see them, in memory. */
class FakeHandoffHost(private val tmp: File) : HandoffHost {
    val account = "a1".repeat(32)
    val me = "d1".repeat(32)
    val browser = "b2".repeat(32)

    val lane = ConcurrentHashMap<String, ByteArray>()
    val puts = CopyOnWriteArrayList<String>()
    /** No relay takes a write (offline). */
    @Volatile var offline = false
    var seed = true
    var hot = false
    var engineUp = true
    var devices = mutableListOf(me, browser)
    val ingested = CopyOnWriteArrayList<ByteArray>()
    var nudges = 0

    /** Per circle, its history as pages of `(createdAt, mediaEntries)` events, newest first. */
    val history = linkedMapOf<String, List<Pair<Long, List<String>>>>()
    var pageSize = 2
    var refs = listOf<Pair<String, String>>()
    var kept = listOf<String>()
    val local = HashMap<String, ByteArray>()
    val lookups = CopyOnWriteArrayList<String>()
    var lookup: (String) -> ItemKeyResult = { ItemKeyResult.Found(it.toByteArray()) }
    val sealedBatches = CopyOnWriteArrayList<Pair<String, List<String>>>()
    /** Runs inside every lane put — a test can cancel "while the network is busy". */
    var onPut: ((String) -> Unit)? = null

    override fun ready() = engineUp
    override fun accountHex() = account
    override fun deviceHex() = me
    override fun holdsAccountSeed() = seed
    override fun suspendHeavyIO() = hot

    override suspend fun laneList(prefix: String) = lane.keys.filter { it.startsWith(prefix) }.sorted()
    override suspend fun laneGet(key: String) = lane[key]
    override suspend fun lanePut(key: String, data: ByteArray): Boolean {
        if (offline) return false
        lane[key] = data
        puts.add(key)
        onPut?.invoke(key)
        return true
    }

    override fun circleIds() = history.keys.toList()
    override fun accountDevices(): List<String> = devices
    override fun ingestOwnRoster(wire: ByteArray): Int {
        ingested.add(wire)
        if (browser !in devices) devices.add(browser)
        return 1
    }

    override fun historyEventCount(circleId: String) = (history[circleId]?.size ?: 0).toLong()
    override fun exportHistoryPage(circleId: String, beforeMs: Long, limit: Int): HistoryPageFfi {
        val events = history[circleId].orEmpty().filter { beforeMs == 0L || it.first < beforeMs }.take(pageSize)
        return HistoryPageFfi(
            events.map { byteArrayOf(2) + "$circleId@${it.first}".toByteArray() },
            events.lastOrNull()?.first?.toULong() ?: 0uL,
            events.size.toUInt(),
            events.flatMap { it.second },
        )
    }

    override fun historyMediaRefs() = refs
    override fun keptStoryMedia() = kept
    override fun localMediaSize(ref: String) = local[ref]?.size?.toLong()
    override fun sealMediaForHandoff(circleId: String, ref: String): File? = local[ref]?.let { bytes ->
        File.createTempFile("sealed", null, tmp).apply { writeBytes("$circleId:".toByteArray() + bytes) }
    }

    override suspend fun findItemKey(circleId: String, ref: String): ItemKeyResult {
        lookups.add(ref)
        return lookup(ref)
    }

    override fun sealItemKeys(device: String, entries: List<ByteArray>): ByteArray {
        sealedBatches.add(device to entries.map { String(it) })
        return "grant:${entries.joinToString(",") { String(it) }}".toByteArray()
    }

    override fun nudgeMyDevices() { nudges++ }

    // ---- what the other device puts on the lane ------------------------------------------------

    fun ask(at: Long, done: Boolean? = null, cancelled: Boolean? = null, roster: String? = null) {
        lane[HistoryHandoffWire.requestKey(account, browser)] =
            HistoryHandoffWire.Request(browser, at, done, roster, cancelled).encode()
    }

    fun askKeys(at: Long, done: Boolean? = null) {
        lane[HistoryHandoffWire.keysRequestKey(account, browser)] =
            HistoryHandoffWire.KeysRequest(browser, at, done).encode()
    }

    fun manifest() = lane[HistoryHandoffWire.manifestKey(account, browser, me)]
        ?.let { HistoryHandoffWire.Manifest.decode(it) }

    fun keysManifest() = lane[HistoryHandoffWire.keysManifestKey(account, browser, me)]
        ?.let { HistoryHandoffWire.KeysManifest.decode(it) }

    fun page(run: String, n: Int) = lane[HistoryHandoffWire.pageKey(account, browser, me, run, n)]
        ?.let { HistoryHandoffWire.decodePage(it) }
}
