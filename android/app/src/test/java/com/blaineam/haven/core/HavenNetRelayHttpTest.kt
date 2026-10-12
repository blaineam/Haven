package com.blaineam.haven.core

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import uniffi.haven_ffi.httpAuthHeader
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress
import java.net.URLDecoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The relay's plain-HTTP lane — signed GET / HEAD / PUT / LIST, the 404 / 401-403 / 5xx split, and the
 * resumable chunked upload — against a real in-process HTTP server standing in for `haven-relay`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetRelayHttpTest {
    private class Hit(val method: String, val path: String, val auth: String?, val digest: String?, val body: ByteArray)

    private lateinit var server: HttpServer
    private lateinit var base: String
    private val store = ConcurrentHashMap<String, ByteArray>()
    private val hits = CopyOnWriteArrayList<Hit>()
    @Volatile private var forceStatus: Int? = null
    @Volatile private var failPutsFrom: Int? = null      // PUT of chunk index >= this → 500
    @Volatile private var headStatus: Int? = null
    private val token = "relay-token"
    private val node = "ab".repeat(32)
    private lateinit var ctx: FakeContext
    private val net = HavenNet

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        HavenNet::class.java.getDeclaredField("appContext").apply { isAccessible = true }.set(HavenNet, ctx)
        (HavenNet::class.java.getDeclaredField("uploadProgress").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>).clear()
        HavenNet::class.java.getDeclaredField("uploadProgressLoaded").apply { isAccessible = true }.setBoolean(HavenNet, true)
        HavenNet.httpAuthSigner = { t, method, key, body -> "Haven $t $method ${body.size}" }
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { ex -> handle(ex) }
        server.start()
        base = "http://127.0.0.1:${server.address.port}"
    }

    @After fun tearDown() {
        server.stop(0)
        Dispatchers.resetMain()
        HavenNet.httpAuthSigner = { token, method, key, body ->
            runCatching { httpAuthHeader(DeviceKeyStore.deviceAccount().secretSeed(), token, method, key, body) }.getOrNull()
        }
        ctx.filesDir.deleteRecursively()
    }

    private fun handle(ex: HttpExchange) {
        val body = ex.requestBody.readBytes()
        val path = ex.requestURI.rawPath
        hits += Hit(ex.requestMethod, path, ex.requestHeaders.getFirst("Authorization"), ex.requestHeaders.getFirst("X-Haven-List-Digest"), body)
        val key = if (path.startsWith("/k/")) URLDecoder.decode(path.removePrefix("/k/"), "UTF-8") else null
        var status = forceStatus ?: 200
        var out = ByteArray(0)
        if (forceStatus == null) when {
            path.startsWith("/l/") -> {
                val prefix = URLDecoder.decode(path.removePrefix("/l/"), "UTF-8")
                val keys = store.keys.filter { it.startsWith(prefix) }.sorted()
                val digest = keys.joinToString(",").hashCode().toString()
                ex.responseHeaders.add("X-Haven-List-Digest", digest)
                if (ex.requestHeaders.getFirst("X-Haven-List-Digest") == digest) status = 204
                else out = (keys.joinToString("\n") + "\n\n").toByteArray()
            }
            ex.requestMethod == "HEAD" -> { headStatus?.let { status = it } ?: run { status = if (store.containsKey(key)) 200 else 404 } }
            ex.requestMethod == "GET" -> { val v = store[key]; if (v == null) status = 404 else out = v }
            ex.requestMethod == "PUT" -> {
                val idx = Regex("""\.p/(\d+)$""").find(key ?: "")?.groupValues?.get(1)?.toInt()
                if (idx != null && failPutsFrom != null && idx >= failPutsFrom!!) status = 500 else store[key!!] = body
            }
        }
        if (ex.requestMethod == "HEAD") ex.sendResponseHeaders(status, -1)
        else if (status == 204) ex.sendResponseHeaders(204, -1)
        else { ex.sendResponseHeaders(status, if (out.isEmpty()) -1 else out.size.toLong()); if (out.isNotEmpty()) ex.responseBody.use { it.write(out) } }
        ex.close()
    }

    // ---- PUT / GET ----------------------------------------------------------------------------

    @Test fun a_signed_put_then_get_round_trips_and_the_key_is_percent_encoded_with_slashes_kept() {
        assertTrue(net.relayHttpPut(base, token, "haven/mailbox/c 1/abc", "hello".toByteArray()).isSuccess)
        assertArrayEquals("hello".toByteArray(), net.relayHttpGet(base, token, "haven/mailbox/c 1/abc").getOrNull())
        assertEquals("/k/haven/mailbox/c%201/abc", hits.first().path)
        assertEquals("Haven relay-token PUT 5", hits[0].auth)
        assertEquals("Haven relay-token GET 0", hits[1].auth)
    }

    @Test fun a_missing_key_is_a_clean_miss_not_an_error() {
        val r = net.relayHttpGet(base, token, "haven/media/nope")
        assertTrue(r.isSuccess); assertNull(r.getOrNull())
    }

    @Test fun refusals_are_told_apart_from_outages() {
        forceStatus = 403
        assertTrue(net.relayHttpGet(base, token, "k").exceptionOrNull() is HavenNet.RelayForbidden)
        assertTrue(net.relayHttpPut(base, token, "k", byteArrayOf(1)).exceptionOrNull() is HavenNet.RelayForbidden)
        forceStatus = 401
        assertTrue("an unverifiable request is also a refusal", net.relayHttpGet(base, token, "k").exceptionOrNull() is HavenNet.RelayForbidden)
        forceStatus = 500
        val err = net.relayHttpGet(base, token, "k").exceptionOrNull()!!
        assertFalse(err is HavenNet.RelayForbidden); assertEquals("http 500", err.message)
        assertEquals("relay PUT HTTP 500", net.relayHttpPut(base, token, "k", byteArrayOf(1)).exceptionOrNull()!!.message)
    }

    @Test fun an_unreachable_relay_is_a_plain_failure() {
        val dead = "http://127.0.0.1:1"
        assertTrue(net.relayHttpGet(dead, token, "k").isFailure)
        assertTrue(net.relayHttpPut(dead, token, "k", byteArrayOf(1)).exceptionOrNull() !is HavenNet.RelayForbidden)
        assertTrue(net.relayHttpListDelta(dead, token, "p/", null).isFailure)
        assertEquals(MediaHolding.Head.UNREACHABLE, net.relayHttpHead(dead, token, "k"))
    }

    @Test fun without_a_device_key_nothing_is_sent() {
        HavenNet.httpAuthSigner = { _, _, _, _ -> null }
        assertEquals("cannot sign relay GET", net.relayHttpGet(base, token, "k").exceptionOrNull()!!.message)
        assertEquals("no device key to sign PUT", net.relayHttpPut(base, token, "k", byteArrayOf(1)).exceptionOrNull()!!.message)
        assertEquals("cannot sign relay LIST", net.relayHttpListDelta(base, token, "p/", null).exceptionOrNull()!!.message)
        assertEquals(MediaHolding.Head.UNREACHABLE, net.relayHttpHead(base, token, "k"))
        assertTrue("no request left the device", hits.isEmpty())
    }

    // ---- HEAD ----------------------------------------------------------------------------------

    @Test fun head_answers_present_absent_refused_unsupported_or_unreachable() {
        store["haven/media/here"] = byteArrayOf(1)
        assertEquals(MediaHolding.Head.PRESENT, net.relayHttpHead(base, token, "haven/media/here"))
        assertEquals(MediaHolding.Head.ABSENT, net.relayHttpHead(base, token, "haven/media/gone"))
        for ((code, want) in mapOf(403 to MediaHolding.Head.REFUSED, 401 to MediaHolding.Head.REFUSED,
            405 to MediaHolding.Head.UNSUPPORTED, 400 to MediaHolding.Head.UNSUPPORTED, 501 to MediaHolding.Head.UNSUPPORTED,
            500 to MediaHolding.Head.UNREACHABLE)) {
            headStatus = code
            assertEquals("HEAD $code", want, net.relayHttpHead(base, token, "haven/media/here"))
        }
        assertTrue(hits.all { it.method == "HEAD" })
    }

    @Test fun existence_uses_head_and_falls_back_to_get_only_where_head_is_unsupported() {
        store["haven/media/x.p/0"] = byteArrayOf(9)
        assertTrue(net.relayHttpExists(base, token, "haven/media/x.p/0"))
        assertFalse(net.relayHttpExists(base, token, "haven/media/x.p/1"))
        assertTrue("only HEADs so far", hits.all { it.method == "HEAD" })
        headStatus = 405
        assertTrue(net.relayHttpExists(base, token, "haven/media/x.p/0"))
        assertFalse(net.relayHttpExists(base, token, "haven/media/x.p/1"))
        assertTrue(hits.any { it.method == "GET" })
        headStatus = 403
        assertFalse("a refusal is not 'held'", net.relayHttpExists(base, token, "haven/media/x.p/0"))
    }

    // ---- LIST (delta) ----------------------------------------------------------------------------

    @Test fun a_listing_returns_keys_and_a_digest_and_an_unchanged_listing_is_a_bodiless_204() {
        store["haven/mailbox/c/a"] = byteArrayOf(1); store["haven/mailbox/c/b"] = byteArrayOf(2); store["haven/mailbox/other/z"] = byteArrayOf(3)
        val (keys, digest) = net.relayHttpListDelta(base, token, "haven/mailbox/c/", null).getOrThrow()
        assertEquals(listOf("haven/mailbox/c/a", "haven/mailbox/c/b"), keys)
        assertTrue(!digest.isNullOrEmpty())
        val again = net.relayHttpListDelta(base, token, "haven/mailbox/c/", digest).getOrThrow()
        assertNull("nothing new: skip the GETs", again.first)
        assertEquals(digest, hits.last().digest)
        store["haven/mailbox/c/c"] = byteArrayOf(4)
        assertEquals(3, net.relayHttpListDelta(base, token, "haven/mailbox/c/", digest).getOrThrow().first!!.size)
    }

    @Test fun the_plain_list_collapses_a_204_to_empty_and_refusals_surface() {
        assertEquals(emptyList<String>(), net.relayHttpList(base, token, "haven/mailbox/none/").getOrThrow())
        forceStatus = 403
        assertTrue(net.relayHttpList(base, token, "p/").exceptionOrNull() is HavenNet.RelayForbidden)
        forceStatus = 500
        assertEquals("http list 500", net.relayHttpList(base, token, "p/").exceptionOrNull()!!.message)
    }

    // ---- uploads --------------------------------------------------------------------------------------

    private fun entry(url: String = base) = HavenNet.RelayEntry(node, "r", true, 0, false, httpUrls = listOf(url), httpToken = token)
    /** A 5xx marks the URL bad for two minutes (the cool-down); a test that retries must lift it first. */
    private fun liftCooldown() = (HavenNet::class.java.getDeclaredField("httpUrlBad").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>).clear()

    private fun upload(blob: ByteArray, chunked: Boolean, fp: String = "fp", force: Boolean = false, e: HavenNet.RelayEntry = entry()) =
        runBlocking { net.httpUploadMedia(e, node, "vid_x", "haven/media/vid_x", blob, chunked, fp, force) }

    @Test fun a_small_blob_is_one_put_under_its_key() {
        val blob = ByteArray(1000) { 5 }
        assertTrue(upload(blob, chunked = false).isSuccess)
        assertArrayEquals(blob, store["haven/media/vid_x"])
        assertEquals(1, hits.count { it.method == "PUT" })
    }

    @Test fun a_large_blob_goes_up_in_windows_then_a_manifest() {
        val blob = ByteArray(MediaUploadPlan.CHUNK_BYTES * 2 + 1234) { (it % 251).toByte() }
        assertTrue(upload(blob, chunked = true).isSuccess)
        assertEquals(3, store.keys.count { it.startsWith("haven/media/vid_x.p/") })
        assertEquals(3, HavenKeys.parseManifest(store["haven/media/vid_x"]!!))
        val joined = (0 until 3).map { store["haven/media/vid_x.p/$it"]!! }.reduce { a, b -> a + b }
        assertArrayEquals(blob, joined)
        assertEquals("the manifest is written LAST", "/k/haven/media/vid_x", hits.last { it.method == "PUT" }.path)
    }

    @Test fun an_interrupted_upload_resumes_after_the_windows_the_relay_already_holds() {
        val blob = ByteArray(MediaUploadPlan.CHUNK_BYTES * 2 + 100) { (it % 199).toByte() }
        failPutsFrom = 2                                           // the third window dies
        assertTrue(upload(blob, chunked = true).isFailure)
        assertNull("no manifest over a partial blob", store["haven/media/vid_x"])
        failPutsFrom = null; hits.clear(); liftCooldown()
        assertTrue(upload(blob, chunked = true).isSuccess)
        val putChunks = hits.filter { it.method == "PUT" && it.path.contains(".p/") }.map { it.path.substringAfterLast('/') }
        assertEquals("only the missing window is re-sent", listOf("2"), putChunks)
        assertTrue("the earlier windows were confirmed with HEAD, not re-downloaded", hits.any { it.method == "HEAD" })
        assertEquals(3, HavenKeys.parseManifest(store["haven/media/vid_x"]!!))
    }

    @Test fun a_different_seal_never_resumes_from_another_seals_windows() {
        val blob = ByteArray(MediaUploadPlan.CHUNK_BYTES + 50) { 1 }
        failPutsFrom = 1
        assertTrue(upload(blob, chunked = true, fp = "seal-A").isFailure)
        failPutsFrom = null; hits.clear(); liftCooldown()
        assertTrue(upload(blob, chunked = true, fp = "seal-B").isSuccess)
        assertEquals("everything re-sent", 2, hits.count { it.method == "PUT" && it.path.contains(".p/") })
    }

    @Test fun force_re_sends_every_window() {
        val blob = ByteArray(MediaUploadPlan.CHUNK_BYTES + 50) { 2 }
        assertTrue(upload(blob, chunked = true).isSuccess)
        hits.clear()
        assertTrue(upload(blob, chunked = true, force = true).isSuccess)
        assertEquals(2, hits.count { it.method == "PUT" && it.path.contains(".p/") })
    }

    @Test fun a_refusing_relay_is_not_marked_bad_but_a_broken_one_is() {
        val bad = HavenNet::class.java.getDeclaredField("httpUrlBad").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>
        bad.clear()
        forceStatus = 403
        assertTrue(upload(byteArrayOf(1), chunked = false).exceptionOrNull() is HavenNet.RelayForbidden)
        assertTrue("reachable and healthy: it just does not know us yet", bad.isEmpty())
        forceStatus = 500
        assertTrue(upload(byteArrayOf(1), chunked = false).isFailure)
        assertTrue(bad.containsKey(base))
        bad.clear()
    }

    @Test fun an_entry_with_no_usable_interface_fails_without_a_request() {
        val r = upload(byteArrayOf(1), chunked = false, e = entry().copy(httpToken = ""))
        assertEquals("relay has no usable HTTP interface", r.exceptionOrNull()!!.message)
        assertTrue(hits.isEmpty())
    }

    // ---- refusal backoff -------------------------------------------------------------------------------

    private fun call(name: String, vararg args: Any?): Any? =
        HavenNet::class.java.declaredMethods.first { it.name == name && it.parameterCount == args.size }
            .apply { isAccessible = true }.invoke(HavenNet, *args)

    @Test fun repeated_refusals_stand_a_relay_down_after_a_short_grace() {
        val relay = "cd".repeat(32)
        (HavenNet::class.java.getDeclaredField("refusedStreak").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>).clear()
        (HavenNet::class.java.getDeclaredField("refusedUntilMs").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>).clear()
        repeat(2) { call("noteRefused", relay, "test"); assertFalse("grace: the first refusals are free", call("relayStoodDown", relay) as Boolean) }
        call("noteRefused", relay, "test")
        assertTrue("the third refusal in a row stands it down", call("relayStoodDown", relay) as Boolean)
        assertFalse("other relays are unaffected", call("relayStoodDown", "ef".repeat(32)) as Boolean)
    }

    // ---- QA counters ------------------------------------------------------------------------------------

    @Suppress("UNCHECKED_CAST")
    private fun relayEntries() = HavenNet::class.java.getDeclaredField("relayEntries").apply { isAccessible = true }.get(HavenNet) as MutableMap<String, HavenNet.RelayEntry>

    @Test fun the_qa_dump_counts_each_outcome_per_relay_and_reports_the_token_only_as_a_fingerprint() {
        val e = entry()
        relayEntries().clear(); relayEntries()[node] = e
        try {
            net.relayHttpPut(base, token, "k1", byteArrayOf(1)); net.relayHttpGet(base, token, "k1")
            net.relayHttpGet(base, token, "missing"); net.relayHttpHead(base, token, "k1"); net.relayHttpHead(base, token, "missing")
            net.relayHttpListDelta(base, token, "k", null)
            forceStatus = 403; net.relayHttpGet(base, token, "k1"); net.relayHttpPut(base, token, "k2", byteArrayOf(1))
            forceStatus = null
            val row = HavenNet.qaRelayStats().getJSONObject(0)
            assertEquals(node, row.getString("relay"))
            assertEquals(1, row.getInt("putOk")); assertEquals(1, row.getInt("getOk")); assertEquals(1, row.getInt("getMiss"))
            assertEquals(1, row.getInt("headOk")); assertEquals(1, row.getInt("headMiss")); assertEquals(1, row.getInt("listOk"))
            assertEquals(1, row.getInt("getRefused")); assertEquals(1, row.getInt("putRefused"))
            val fp = row.getString("tokenFp")
            assertEquals(12, fp.length); assertFalse(fp.contains(token))
            assertTrue(row.getBoolean("active"))
        } finally { relayEntries().clear() }
    }

    // ---- fetching media from a relay ---------------------------------------------------------------------

    private fun useAsDefaultRelay() {
        relayEntries().clear(); relayEntries()[node] = entry()
        HavenNet.setDefaultRelay(node)
        ctx.filesDir.resolve("media").mkdirs(); LocalMedia.init(ctx)
        (HavenNet::class.java.getDeclaredField("sweptRestoreParts").apply { isAccessible = true }).setBoolean(HavenNet, true)
        (HavenNet::class.java.getDeclaredField("refusedUntilMs").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>).clear()
        (HavenNet::class.java.getDeclaredField("refusedStreak").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>).clear()
        synchronized(HavenNet::class.java.getDeclaredField("rosterNeeded").apply { isAccessible = true }.get(HavenNet)) {
            (HavenNet::class.java.getDeclaredField("rosterNeeded").apply { isAccessible = true }.get(HavenNet) as MutableSet<*>).clear()
        }
        liftCooldown()
    }

    private fun fetch(ref: String) = runBlocking { net.fetchMediaFromRelay("circ", ref) }

    @Test fun a_small_blob_is_fetched_whole_and_stored() {
        useAsDefaultRelay()
        store["haven/media/img_small"] = "sealed-bytes".toByteArray()
        assertTrue(fetch("img_small"))
        assertArrayEquals("sealed-bytes".toByteArray(), LocalMedia.rawSealed("img_small"))
        assertEquals(1, hits.count { it.path == "/k/haven/media/img_small" })
    }

    @Test fun a_chunked_blob_is_fetched_window_by_window() {
        useAsDefaultRelay()
        val c = List(3) { i -> ByteArray(16) { (i * 40 + it).toByte() } }
        store["haven/media/vid_big"] = HavenKeys.makeManifest(c.map { it.size })
        c.forEachIndexed { i, b -> store["haven/media/vid_big.p/$i"] = b }
        assertTrue(fetch("vid_big"))
        assertArrayEquals(c.reduce { a, b -> a + b }, LocalMedia.rawSealed("vid_big"))
    }

    @Test fun a_blob_the_relay_does_not_hold_is_a_miss_that_waits_on_the_sender() {
        useAsDefaultRelay()
        assertFalse(fetch("img_absent"))
        assertFalse(LocalMedia.has("img_absent"))
        assertTrue("the placeholder says 'waiting for sender', not 'downloading'", HavenNet.waitingForSenderMedia.contains("img_absent"))
        assertTrue("it asked for the relay's interface doc to tell a miss from a dead hostname",
            hits.any { it.path == "/k/haven/relay/__interface__" })
    }

    @Test fun a_refusing_relay_is_reported_as_a_refusal_not_as_absence() {
        useAsDefaultRelay()
        forceStatus = 403
        assertFalse(fetch("img_refused"))
        assertFalse("not 'waiting for sender': the blob may be right there", HavenNet.waitingForSenderMedia.contains("img_refused"))
        val bad = HavenNet::class.java.getDeclaredField("httpUrlBad").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>
        assertTrue("a refusal is not an outage", bad.isEmpty())
    }

    @Test fun a_relay_that_cannot_be_reached_is_backed_off() {
        useAsDefaultRelay()
        relayEntries()[node] = entry("http://127.0.0.1:1")
        assertFalse(fetch("img_nowhere"))
        val bad = HavenNet::class.java.getDeclaredField("httpUrlBad").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>
        assertTrue(bad.containsKey("http://127.0.0.1:1"))
        liftCooldown()
    }

    // ---- authored events: the mailbox write path -------------------------------------------------------------

    private fun seenMailbox() = HavenNet::class.java.getDeclaredField("seenMailbox").apply { isAccessible = true }.get(HavenNet) as MutableSet<*>
    private fun prepareMailbox() {
        useAsDefaultRelay()
        Presign.init(ctx)
        seenMailbox().clear()
        HavenNet::class.java.getDeclaredField("seenMailboxLoaded").apply { isAccessible = true }.setBoolean(HavenNet, true)
    }
    private fun uploadEvent(env: ByteArray) = runBlocking { net.uploadEvent("circ", env) }

    @Test fun an_authored_event_lands_in_the_relays_mailbox_under_its_content_hash() {
        prepareMailbox()
        val env = "sealed event".toByteArray()
        assertTrue(uploadEvent(env))
        assertArrayEquals(env, store[HavenKeys.mailboxKey("circ", env)])
        assertTrue("the key is remembered so our own poll skips it", seenMailbox().contains(HavenKeys.mailboxKey("circ", env)))
    }

    @Test fun re_uploading_a_landed_event_costs_no_request() {
        prepareMailbox()
        val env = "sealed event".toByteArray()
        assertTrue(uploadEvent(env)); hits.clear()
        assertTrue(uploadEvent(env))
        assertTrue(hits.isEmpty())
    }

    @Test fun a_relay_that_refuses_us_does_not_count_as_landed_and_is_not_marked_bad() {
        prepareMailbox()
        forceStatus = 403
        assertFalse(uploadEvent("e".toByteArray()))
        val bad = HavenNet::class.java.getDeclaredField("httpUrlBad").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>
        assertTrue(bad.isEmpty())
    }

    @Test fun a_broken_relay_is_backed_off_and_the_event_stays_unlanded() {
        prepareMailbox()
        forceStatus = 500
        assertFalse(uploadEvent("e2".toByteArray()))
        val bad = HavenNet::class.java.getDeclaredField("httpUrlBad").apply { isAccessible = true }.get(HavenNet) as MutableMap<*, *>
        assertTrue(bad.containsKey(base)); liftCooldown()
    }

    @Test fun a_circle_with_no_relay_of_its_own_falls_back_to_every_active_relay() {
        prepareMailbox()
        HavenNet.setDefaultRelay(null)             // no default, no per-circle association...
        val env = "orphan circle".toByteArray()
        assertTrue("...but the device still knows an active relay", uploadEvent(env))
        assertTrue(store.containsKey(HavenKeys.mailboxKey("circ", env)))
    }

    @Test fun a_device_that_knows_no_relay_has_nowhere_to_put_it() {
        prepareMailbox()
        relayEntries().clear(); HavenNet.setDefaultRelay(null)
        assertFalse(uploadEvent("nowhere".toByteArray()))
        assertTrue(hits.isEmpty())
    }
}
