package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.HandoffHost
import com.blaineam.haven.core.HavenKeys
import com.blaineam.haven.core.HistoryHandoff
import com.blaineam.haven.core.HistoryHandoffWire
import com.blaineam.haven.core.ItemKeyLookup
import com.blaineam.haven.core.ItemKeyResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.haven_ffi.Account
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.HistoryPageFfi
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * DECISIONS D26 + D27, the Android phone's half end to end with the REAL core: a friend's media from
 * before a linked device existed, one blob whole and one in two chunks on the relay. The phone's
 * senders answer the device's two requests; a device WITHOUT the account key reads the history pages
 * and then opens both old blobs with the keys. The lane and the relay are in memory (the relay
 * serves a suffix range as haven-relay does); everything cryptographic is the shipping library.
 */
@RunWith(AndroidJUnit4::class)
class HandoffRoundTripInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val dir = File(context.cacheDir, "handoff-roundtrip-${System.nanoTime()}").apply { mkdirs() }
    private val job = SupervisorJob()

    @After fun tearDown() {
        job.cancel()
        dir.deleteRecursively()
    }

    private class RangeRead(val key: String, val bytes: Int, val ranged: Boolean)

    private class Phone(val engine: HavenSocial, val deviceHex: String, val tmp: File) : HandoffHost {
        val lane = ConcurrentHashMap<String, ByteArray>()
        val relay = ConcurrentHashMap<String, ByteArray>()
        val reads = CopyOnWriteArrayList<RangeRead>()

        override fun ready() = true
        override fun accountHex() = engine.myNodeHex()
        override fun deviceHex() = deviceHex
        override fun holdsAccountSeed() = true
        override fun suspendHeavyIO() = false
        override suspend fun laneList(prefix: String) = lane.keys.filter { it.startsWith(prefix) }.sorted()
        override suspend fun laneGet(key: String) = lane[key]
        override suspend fun lanePut(key: String, data: ByteArray): Boolean { lane[key] = data; return true }
        override fun circleIds() = engine.circles().map { it.id }
        override fun accountDevices() = engine.deviceNodeIdsFor(engine.myNodeHex())
        override fun ingestOwnRoster(wire: ByteArray) = engine.ingestRosterWireStatus(wire).toInt()
        override fun historyEventCount(circleId: String) = engine.historyEventCount(circleId).toLong()
        override fun exportHistoryPage(circleId: String, beforeMs: Long, limit: Int): HistoryPageFfi =
            engine.exportHistoryPage(circleId, beforeMs.toULong(), limit.toUInt())
        override fun historyMediaRefs() =
            engine.historyMediaRefs(System.currentTimeMillis().toULong()).map { it.circleId to it.reference }
        override fun keptStoryMedia() = emptyList<String>()
        override fun localMediaSize(ref: String): Long? = null
        override fun sealMediaForHandoff(circleId: String, ref: String): File? = null
        override fun sealItemKeys(device: String, entries: List<ByteArray>) = engine.sealItemKeys(device, entries)
        override fun nudgeMyDevices() {}

        override suspend fun findItemKey(circleId: String, ref: String): ItemKeyResult {
            val reader = object : ItemKeyLookup.Reader {
                override suspend fun tail(key: String): ItemKeyLookup.Tail? {
                    val body = relay[key] ?: return null
                    val n = minOf(body.size, HistoryHandoffWire.KEY_TAIL_BYTES)
                    reads.add(RangeRead(key, n, ranged = true))
                    return ItemKeyLookup.Tail(body.copyOfRange(body.size - n, body.size), partial = n < body.size)
                }
                override suspend fun whole(key: String): ByteArray? =
                    relay[key]?.also { reads.add(RangeRead(key, it.size, ranged = false)) }
            }
            val key = ItemKeyLookup.fromDestination(reader, ref, 64L * 1024 * 1024) { engine.itemKeyFromTail(it) }
            return key?.let { ItemKeyResult.Found(it) } ?: ItemKeyResult.Missing
        }
    }

    private fun seed(start: Int) = ByteArray(32) { (start + it).toByte() }

    /** Roster and key commit first, so a page's events open on the first try. */
    private fun controlFirst(envs: List<ByteArray>) = envs.sortedBy {
        when (it.firstOrNull()?.toInt()) { 0x04 -> 0; 0x03 -> 1; else -> 2 }
    }

    @Test fun a_linked_device_without_the_account_key_gets_history_and_opens_old_media() = runBlocking {
        val account = Account.generate()
        val engine = HavenSocial(account.secretSeed())
        val phoneDevice = Account.fromSeed(seed(0x21))
        engine.useDeviceIdentity(seed(0x21))
        engine.registerDevice(phoneDevice.publicBundle(), "Android phone", 1uL)
        val friend = HavenSocial(Account.generate().secretSeed())
        engine.addContactBundle("default", friend.myBundle())
        friend.addContactBundle("default", engine.myBundle())
        val phone = Phone(engine, phoneDevice.nodeIdHex(), dir)

        // A friend's media from before the browser existed.
        val small = ByteArray(150_000) { 7 }
        val large = ByteArray(300_000) { it.toByte() }
        val sealedSmall = friend.sealCircleMedia("default", small)
        val sealedLarge = friend.sealCircleMedia("default", large)
        val cut = sealedLarge.size - 900   // a second chunk far shorter than the tail
        phone.relay[HavenKeys.mediaKey("img_small")] = sealedSmall
        phone.relay[HavenKeys.mediaKey("vid_large")] = HavenKeys.makeManifest(listOf(cut, 900))
        phone.relay[HavenKeys.mediaChunkKey("vid_large", 0)] = sealedLarge.copyOfRange(0, cut)
        phone.relay[HavenKeys.mediaChunkKey("vid_large", 1)] = sealedLarge.copyOfRange(cut, sealedLarge.size)
        val longAgo = (System.currentTimeMillis() - 90L * 24 * 3_600_000).toULong()
        friend.post("default", "before the browser", listOf("img_small", "vid_large", "img_gone"),
            null, null, false, false, longAgo)
        for (env in controlFirst(friend.syncEnvelopes("default"))) engine.receive("default", env)
        engine.post("default", "mine, also before", emptyList(), null, null, false, false, longAgo + 1uL)

        // The linked device: on the account's signed roster, holding no account key.
        val browserSeed = seed(0x73)
        val browserDevice = Account.fromSeed(browserSeed)
        assertTrue(engine.registerDevice(browserDevice.publicBundle(), "Tablet", 2uL).isNotEmpty())
        val browser = HavenSocial.newSeedless(engine.myBundle(), browserSeed)
        browser.createCircle("default", "Your circle")
        browser.addContactBundle("default", friend.myBundle())
        assertNull("no way in before the keys", browser.openCircleMedia("default", sealedSmall))
        assertNull(browser.itemKeyFromTail(sealedSmall))

        val acct = phone.accountHex()
        val me = phone.deviceHex
        val target = browserDevice.nodeIdHex()
        val at = System.currentTimeMillis()
        phone.lane[HistoryHandoffWire.requestKey(acct, target)] = HistoryHandoffWire.Request(target, at).encode()
        phone.lane[HistoryHandoffWire.keysRequestKey(acct, target)] =
            HistoryHandoffWire.KeysRequest(target, at).encode()

        val sender = HistoryHandoff(phone, File(dir, "state"), CoroutineScope(job + Dispatchers.IO), publish = {})
        var keys: HistoryHandoffWire.KeysManifest? = null
        var passes = 0
        while (keys?.complete != true && passes++ < 20) {
            sender.tick(60_000)
            keys = phone.lane[HistoryHandoffWire.keysManifestKey(acct, target, me)]
                ?.let { HistoryHandoffWire.KeysManifest.decode(it) }
        }

        // History pages: the linked device reads them and has both posts.
        val history = HistoryHandoffWire.Manifest.decode(phone.lane[HistoryHandoffWire.manifestKey(acct, target, me)]!!)!!
        assertTrue(history.complete)
        assertEquals(at, history.forRequest)
        for (n in 0 until history.pages) {
            val page = HistoryHandoffWire.decodePage(phone.lane[HistoryHandoffWire.pageKey(acct, target, me, history.run, n)]!!)!!
            browser.createCircle(page.circleId, page.circleId)
            for (env in controlFirst(page.envelopes)) runCatching { browser.receive(page.circleId, env) }
        }
        val bodies = browser.feed("default", (System.currentTimeMillis() + 60_000).toULong(), null).map { it.body }
        assertTrue("friend's post handed over: $bodies", "before the browser" in bodies)
        assertTrue("own post handed over: $bodies", "mine, also before" in bodies)

        // Media keys: the old blobs open.
        val m = requireNotNull(keys)
        assertTrue(m.complete)
        assertEquals(at, m.forRequest)
        assertEquals(m.total, m.done)
        assertEquals("the blob no relay holds is counted, not waited for", 1, m.missing)
        var received = 0u
        for (n in 0 until m.batches) {
            val grant = phone.lane[HistoryHandoffWire.keysBatchKey(acct, target, me, m.run, n)]
            assertNotNull(grant)
            received += browser.receiveItemKeys(grant!!)
        }
        assertEquals(2u, received)
        assertArrayEquals(small, browser.openCircleMedia("default", sealedSmall))
        assertArrayEquals(large, browser.openCircleMedia("default", sealedLarge))

        // Only the ends were read: never a whole blob or chunk.
        assertTrue(phone.reads.any { it.key == HavenKeys.mediaChunkKey("vid_large", 0) })
        assertTrue(phone.reads.all { it.ranged && it.bytes <= HistoryHandoffWire.KEY_TAIL_BYTES })
    }
}
