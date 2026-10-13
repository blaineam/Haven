package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * HavenNet rules that run entirely on local state (prefs + in-memory lists) — contact lookups,
 * the notification de-dupe set, the hosted relay's bearer token and the URLs it announces.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetLocalRulesTest {
    private lateinit var ctx: FakeContext
    private val net = HavenNet::class.java
    private val hexA = "aa".repeat(32)
    private val hexB = "ab".repeat(32)

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        field("appContext").set(HavenNet, ctx)
        field("notifiedMigrated").setBoolean(HavenNet, false)
        HavenNet.contacts.clear()
    }
    @After fun tearDown() { HavenNet.contacts.clear(); Dispatchers.resetMain(); ctx.filesDir.deleteRecursively() }

    private fun field(name: String) = net.getDeclaredField(name).apply { isAccessible = true }
    @Suppress("UNCHECKED_CAST")
    private fun <T> call(name: String, vararg args: Any?): T =
        try {
            net.declaredMethods.first { it.name == name && it.parameterCount == args.size }
                .apply { isAccessible = true }.invoke(HavenNet, *args) as T
        } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }

    // ---- contact lookups ------------------------------------------------------------------------

    @Test fun a_short_author_id_resolves_to_the_contact_it_prefixes() {
        HavenNet.contacts.addAll(listOf(Contact(hexA, "Ana", ""), Contact(hexB, "Ben", "")))
        assertEquals(hexA, HavenNet.idHexFor(hexA.take(8)))
        assertEquals("Ben", HavenNet.displayName(hexB.take(8)))
        assertNull("an empty short id matches nobody", HavenNet.idHexFor(""))
        assertNull(HavenNet.idHexFor("ffffffff"))
    }

    @Test fun an_unknown_author_is_shown_as_someone_with_a_short_tag() {
        assertEquals("Someone (cdcdcd)", HavenNet.displayName("cdcdcdcd"))
        assertEquals("a1b2", HavenNet.displayName("a1b2"))   // too short to tag: shown as is
    }

    @Test fun is_contact_ignores_case() {
        HavenNet.contacts.add(Contact(hexA, "Ana", ""))
        assertTrue(HavenNet.isContact(hexA.uppercase()))
        assertFalse(HavenNet.isContact(hexB))
    }

    // ---- notification de-dupe -------------------------------------------------------------------

    @Test fun a_notification_key_fires_once() {
        assertTrue(call<Boolean>("markNotified", "c1:p1"))
        assertFalse(call<Boolean>("markNotified", "c1:p1"))
        assertTrue(call<Boolean>("markNotified", "c1:p2"))
        val saved = ctx.prefs("haven.notified").getStringSet("notifiedIds", null)!!
        assertEquals(setOf("c1:p1", "c1:p2"), saved)
    }

    @Test fun the_dedupe_set_resets_instead_of_growing_without_bound() {
        val big = (0 until 800).map { "c:$it" }.toSet()
        ctx.prefs("haven.notified").data["notifiedIds"] = big
        field("notifiedMigrated").setBoolean(HavenNet, true)
        assertTrue(call<Boolean>("markNotified", "c:new"))
        assertEquals("past 800 the set restarts from the new key", setOf("c:new"),
            ctx.prefs("haven.notified").getStringSet("notifiedIds", null))
    }

    @Test fun the_legacy_dedupe_set_moves_out_of_the_contacts_file_once() {
        ctx.prefs("haven.contacts").data["notifiedIds"] = setOf("old:1")
        assertFalse("a key from the legacy set is still a repeat", call<Boolean>("markNotified", "old:1"))
        assertFalse(ctx.prefs("haven.contacts").contains("notifiedIds"))
        assertEquals(setOf("old:1"), ctx.prefs("haven.notified").getStringSet("notifiedIds", null))
    }

    // ---- hosted relay HTTP interface ------------------------------------------------------------

    @Test fun the_relay_token_is_minted_once_and_persisted() {
        val t = call<String>("relayHttpToken")
        assertTrue("32 lowercase hex chars", Regex("[0-9a-f]{32}").matches(t))
        assertEquals(t, call<String>("relayHttpToken"))
        assertEquals(t, ctx.prefs("haven.contacts").getString("relayHttpToken", null))
        ctx.prefs("haven.contacts").data["relayHttpToken"] = "fixed"
        assertEquals("fixed", call<String>("relayHttpToken"))
    }

    @Test fun a_configured_public_url_is_announced_alone_without_its_trailing_slash() {
        ctx.prefs("haven.contacts").data["relayPublicUrl"] = "  https://relay.example.org/  "
        assertEquals(listOf("https://relay.example.org"), call<List<String>>("relayHttpUrls", 8674))
    }

    @Test fun a_public_url_that_is_not_http_is_ignored_and_lan_addresses_carry_the_port() {
        ctx.prefs("haven.contacts").data["relayPublicUrl"] = "ftp://nope"
        val urls = call<List<String>>("relayHttpUrls", 8674)
        assertTrue(urls.all { Regex("""http://\d+\.\d+\.\d+\.\d+:8674""").matches(it) })
        assertFalse("loopback is never announced", urls.any { it.startsWith("http://127.") })
        assertFalse("link-local is never announced", urls.any { it.startsWith("http://169.254.") })
        assertEquals("no duplicates", urls.distinct(), urls)
    }
}
