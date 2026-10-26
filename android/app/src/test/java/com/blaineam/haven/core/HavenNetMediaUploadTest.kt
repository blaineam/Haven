package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.ContactRosterWire

/**
 * Mirroring a sealed media blob to the relays: scope marker first, then a "do you already hold it, completely?"
 * probe, and only then the blob read and PUT. The relay is an in-process HTTP server, so the order and count of
 * requests are asserted on the wire.
 */
class HavenNetMediaUploadTest {
    private val env = NetEnv()
    private val ref = "img_0a0a0a0a0a0a0a0a"
    private val blob = ByteArray(2000) { (it % 251).toByte() }
    private val mediaKey = "haven/media/$ref"
    private val scopeKey = "haven/media/$ref.c/default"

    @Before fun setUp() {
        env.up()
        assertTrue(LocalMedia.writeRawSealed(ref, blob))
    }
    @After fun tearDown() { env.down() }

    private fun upload(force: Boolean = false, reseal: Boolean = false, circle: String = "default") =
        runBlocking { HavenNet.uploadMedia(circle, ref, force, reseal) }
    private fun putPaths() = env.relay.puts().map { java.net.URLDecoder.decode(it.path.removePrefix("/k/"), "UTF-8") }
    @Suppress("UNCHECKED_CAST")
    private fun backedUp() = NetEnv.field("backedUp").get(HavenNet) as MutableSet<String>

    @Test fun a_blob_is_scoped_to_its_circle_before_it_is_stored() {
        assertTrue(upload())
        assertArrayEquals(blob, env.relay.store[mediaKey])
        assertArrayEquals("1".toByteArray(), env.relay.store[scopeKey])
        assertEquals("the scope marker leads, so a relay that does not serve the circle never holds the blob",
            listOf(scopeKey, mediaKey), putPaths())
        assertTrue(backedUp().contains("${env.relayHex}|$ref"))
    }

    @Test fun a_confirmed_upload_is_never_repeated() {
        assertTrue(upload())
        env.relay.hits.clear()
        assertTrue(upload())
        assertTrue("the ledger answers before any request", env.relay.hits.isEmpty())
    }

    @Test fun a_relay_that_already_holds_the_whole_blob_costs_no_upload() {
        env.relay.store[mediaKey] = blob
        assertTrue(upload())
        assertEquals("only the scope marker is written", listOf(scopeKey), putPaths())
        assertTrue(backedUp().contains("${env.relayHex}|$ref"))
    }

    @Test fun a_second_circle_sharing_the_blob_is_scoped_in_without_a_second_upload() {
        // One blob sealed for two circles: the relay holds the bytes after the first circle's job, but the
        // second circle still needs its own scope marker — "already backed up" must not skip it.
        assertTrue(upload(circle = "default"))
        env.relay.hits.clear()
        assertTrue(upload(circle = "second"))
        assertEquals("only the new circle's scope marker moves; the blob is not re-sent",
            listOf("haven/media/$ref.c/second"), putPaths())
        assertArrayEquals("1".toByteArray(), env.relay.store["haven/media/$ref.c/second"])
        env.relay.hits.clear()
        assertTrue(upload(circle = "second"))
        assertTrue("once the scope is confirmed the ledger answers before any request", env.relay.hits.isEmpty())
    }

    @Test fun a_manifest_over_missing_chunks_is_re_uploaded() {
        env.relay.store[mediaKey] = HavenKeys.makeManifest(listOf(10, 10))
        env.relay.store["haven/media/$ref.p/0"] = ByteArray(10)   // chunk 1 never arrived
        assertTrue(upload())
        assertArrayEquals("an incomplete copy is replaced, not trusted", blob, env.relay.store[mediaKey])
    }

    @Test fun force_overwrites_without_asking_and_ignores_the_ledger() {
        assertTrue(upload())
        env.relay.hits.clear()
        env.relay.store[mediaKey] = ByteArray(5)
        assertTrue(upload(force = true))
        assertArrayEquals(blob, env.relay.store[mediaKey])
        assertTrue("no HEAD probe on a forced overwrite", env.relay.hits.none { it.method == "HEAD" })
    }

    @Test fun a_reseal_that_cannot_open_the_local_copy_sends_the_stored_seal() {
        assertTrue(upload(reseal = true))
        assertArrayEquals(blob, env.relay.store[mediaKey])
    }

    @Test fun a_blob_this_device_does_not_hold_uploads_nothing() {
        LocalMedia.delete(ref)
        assertFalse(upload())
        assertNull(env.relay.store[mediaKey])
    }

    @Test fun a_device_with_no_relay_has_nowhere_to_mirror() {
        env.entries().clear(); HavenNet.setDefaultRelay(null)
        assertFalse(upload())
        assertTrue(env.relay.hits.isEmpty())
    }

    @Test fun a_broken_relay_fails_the_upload_and_is_backed_off() {
        env.relay.forceStatus = 500
        assertFalse(upload())
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
        assertFalse(backedUp().contains("${env.relayHex}|$ref"))
    }

    @Test fun a_relay_that_refuses_us_triggers_a_roster_republish_and_one_retry() {
        env.social.ownRoster = listOf(ContactRosterWire(env.me, byteArrayOf(4, 4)))
        env.relay.forceStatus = 403
        assertFalse(upload())
        assertTrue("the refusal is healed by publishing our device roster", putPaths().contains("haven/devroster/${env.me}"))
        assertTrue("and it is not mistaken for an outage", (NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).isEmpty())
    }

    @Test fun a_relay_that_does_not_serve_the_circle_is_remembered_as_no_destination_for_it() {
        val other = FakeRelayServer().start()
        try {
            other.forceStatus = 403
            val b = "99".repeat(32)
            env.entries()[b] = HavenNet.RelayEntry(b, "o", true, 0, false, httpUrls = listOf(other.base), httpToken = env.token)
            env.bindCircleRelay("cX", b)   // serves another circle only: a mere extra mirror for this one
            assertTrue("our own relay still takes it", upload())
            assertTrue((NetEnv.field("scopeRefusedUntil").get(HavenNet) as Map<*, *>).containsKey("$b|default"))
            assertEquals("it got the scope marker and nothing else", listOf("/k/haven/media/$ref.c/default"), other.hits.map { java.net.URLDecoder.decode(it.path, "UTF-8") })
        } finally { other.stop() }
    }
}
