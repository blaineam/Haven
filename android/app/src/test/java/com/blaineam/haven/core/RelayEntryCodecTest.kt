package com.blaineam.haven.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A relay's persisted config must survive a save/load round trip field for field. */
class RelayEntryCodecTest {
    private val hex = "ab".repeat(32)
    private val full = HavenNet.RelayEntry(
        hex = hex, name = "Home NAS", active = false, lastSeenMs = 1_700_000_000_000, isS3 = false,
        httpUrls = listOf("https://r.example", "http://10.0.0.5:8080"), httpToken = "tok", addedAtMs = 1_699_000_000_000,
        derpUrl = "https://derp.example", turnUrls = listOf("turn:t.example:3478"), turnUser = "haven", turnPass = "pw",
    )

    @Test fun every_field_round_trips() {
        assertEquals(full, RelayEntryCodec.decode(RelayEntryCodec.encode(full), nowMs = 1))
    }

    @Test fun empty_optionals_are_not_written() {
        val o = RelayEntryCodec.encode(HavenNet.RelayEntry(hex, "n", true, 5, false))
        for (k in listOf("httpUrls", "httpToken", "addedAtMs", "derpUrl", "turnUrls", "turnUser", "turnPass"))
            assertFalse("$k should be omitted", o.has(k))
        assertTrue(o.getBoolean("active"))
    }

    @Test fun a_minimal_record_takes_defaults_and_the_supplied_clock() {
        val e = RelayEntryCodec.decode(JSONObject().put("hex", hex), nowMs = 777)
        assertEquals("Relay · abababab…", e.name)
        assertTrue(e.active); assertEquals(777L, e.lastSeenMs); assertFalse(e.isS3)
        assertEquals(0L, e.addedAtMs); assertEquals("", e.derpUrl)
    }

    @Test fun s3_pseudo_relays_are_recognised_from_the_id() {
        val e = RelayEntryCodec.decode(JSONObject().put("hex", "s3:my-bucket"), 1)
        assertTrue(e.isS3)
        assertEquals("S3 · my-bucket", e.name)
        assertEquals("S3 · " + "x".repeat(16), RelayEntryCodec.shortName("s3:" + "x".repeat(40)))
    }

    @Test fun decode_cleans_stored_urls() {
        val o = JSONObject(RelayEntryCodec.encode(full).toString())
        o.put("derpUrl", " https://derp.example/ ")
        o.put("httpUrls", org.json.JSONArray(listOf("https://a", "", "https://b")))
        o.put("turnUrls", org.json.JSONArray(listOf("turn:a", "stun:b", "turns:c")))
        val e = RelayEntryCodec.decode(o, 1)
        assertEquals("https://derp.example", e.derpUrl)
        assertEquals(listOf("https://a", "https://b"), e.httpUrls)
        assertEquals(listOf("turn:a", "turns:c"), e.turnUrls)
    }

    @Test(expected = org.json.JSONException::class)
    fun a_record_without_an_id_is_corrupt() { RelayEntryCodec.decode(JSONObject().put("name", "x"), 1) }
}
