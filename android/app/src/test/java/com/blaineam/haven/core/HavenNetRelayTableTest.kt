package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/**
 * HavenNet's relay table — deactivate-not-erase, the deletion archive, and the last-writer-wins
 * tombstones that stop a deleted relay coming back. Driven through the public API against an
 * in-memory SharedPreferences; the engine, node and network are never touched.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetRelayTableTest {
    private lateinit var ctx: FakeContext
    private val relayA = "aa".repeat(32)
    private val relayB = "bb".repeat(32)
    private val day = 24L * 3600 * 1000

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        boot()
    }
    @After fun tearDown() { Dispatchers.resetMain() }

    private val net = HavenNet::class.java
    private fun field(name: String) = net.getDeclaredField(name).apply { isAccessible = true }
    private fun call(name: String) { net.getDeclaredMethod(name).apply { isAccessible = true }.invoke(HavenNet) }

    /** (Re)load the relay table from [ctx]'s prefs — what a process start does. */
    private fun boot() {
        field("appContext").set(HavenNet, ctx)
        Presign.init(ctx)
        field("relayJoinSeeded").setBoolean(HavenNet, false)   // load re-seeds the join snapshot: nothing "joins"
        field("lastRelayShape").set(HavenNet, null)            // the first save after load always writes
        (field("erasedRelays").get(HavenNet) as MutableMap<*, *>).clear()   // load() fills the archive but never empties it
        call("loadRelayNodes")
    }

    private val prefs get() = ctx.prefs("haven.contacts")

    /** The deletion paths finish on a background coroutine; each ends by bumping [HavenNet.relaysVersion]. */
    private fun settle(action: () -> Unit) {
        val before = HavenNet.relaysVersion.value
        action()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (HavenNet.relaysVersion.value == before) {
            check(System.nanoTime() < deadline) { "background relay work never finished" }
            Thread.onSpinWait()
        }
    }

    private fun entry(hex: String) = HavenNet.allRelayEntries().firstOrNull { it.hex == hex }

    private fun seedEntries(vararg e: HavenNet.RelayEntry, suppressed: List<String> = emptyList(), forgotAt: Map<String, Long> = emptyMap()) {
        prefs.data["relayEntries"] = JSONArray(e.map { RelayEntryCodec.encode(it) }).toString()
        prefs.data["relaysSuppressed"] = JSONArray(suppressed).toString()
        prefs.data["relaysForgotAt"] = JSONObject(forgotAt as Map<*, *>).toString()
        boot()
    }

    private fun relay(hex: String, active: Boolean = true, lastSeen: Long = System.currentTimeMillis(), name: String = "R") =
        HavenNet.RelayEntry(hex, name, active, lastSeen, isS3 = false)

    // ---- basics ------------------------------------------------------------------------------

    @Test fun a_fresh_install_knows_no_relays() {
        assertTrue(HavenNet.allRelayEntries().isEmpty())
        assertNull(HavenNet.defaultRelay())
        assertFalse(HavenNet.hasRelay())
    }

    @Test fun an_unknown_relay_counts_as_active_so_nothing_breaks() {
        assertTrue(HavenNet.isRelayActive(relayA))
    }

    @Test fun reactivating_creates_an_active_entry_with_a_short_name_and_persists_it() {
        HavenNet.reactivateRelay(relayA)
        val e = entry(relayA)!!
        assertTrue(e.active); assertEquals("Relay · aaaaaaaa…", e.name)
        assertTrue(e.addedAtMs > 0)
        assertTrue(prefs.getString("relayEntries", "")!!.contains(relayA))
    }

    @Test fun the_relay_table_survives_a_restart() {
        HavenNet.reactivateRelay(relayA); HavenNet.renameRelay(relayA, "Home NAS"); HavenNet.setDefaultRelay(relayB)
        boot()
        assertEquals("Home NAS", entry(relayA)!!.name)
        assertEquals(relayB, HavenNet.defaultRelay())
        assertEquals(setOf(relayA, relayB), HavenNet.allRelayEntries().map { it.hex }.toSet())
    }

    @Test fun the_default_relay_can_be_set_and_cleared_and_ids_are_normalised() {
        HavenNet.setDefaultRelay("  ${relayA.uppercase()} ")
        assertEquals(relayA, HavenNet.defaultRelay())
        assertTrue(entry(relayA)!!.active)
        HavenNet.setDefaultRelay("s3:my-bucket")
        assertEquals("s3 ids keep their case and shape", "s3:my-bucket", HavenNet.defaultRelay())
        HavenNet.setDefaultRelay(null)
        assertNull(HavenNet.defaultRelay())
        assertEquals("", prefs.getString("relayDefault", null))
    }

    @Test fun renaming_trims_ignores_blank_and_unknown() {
        HavenNet.reactivateRelay(relayA)
        HavenNet.renameRelay(relayA, "  Closet Pi  "); assertEquals("Closet Pi", entry(relayA)!!.name)
        HavenNet.renameRelay(relayA, "   "); assertEquals("Closet Pi", entry(relayA)!!.name)
        HavenNet.renameRelay(relayB, "Ghost"); assertNull(entry(relayB))
    }

    @Test fun the_hub_lists_active_relays_first_then_by_name() {
        seedEntries(relay(relayA, active = false, name = "Alpha"), relay(relayB, name = "zulu"), relay("cc".repeat(32), name = "Bravo"))
        assertEquals(listOf("Bravo", "zulu", "Alpha"), HavenNet.allRelayEntries().map { it.name })
    }

    @Test fun a_circles_explicit_relays_come_from_its_association_list() {
        prefs.data["relays"] = JSONObject().put("circ", JSONArray(listOf(relayA, relayA, relayB, ""))).toString()
        boot()
        assertEquals("duplicates and blanks are dropped on load", listOf(relayA, relayB), HavenNet.explicitRelaysForCircle("circ"))
        assertTrue("a relay referenced only by a circle still gets an entry", entry(relayB) != null)
        assertTrue(HavenNet.explicitRelaysForCircle("other").isEmpty())
        assertTrue(HavenNet.hasRelay())
    }

    @Test fun the_legacy_single_relay_per_circle_format_is_migrated() {
        prefs.data["relayNodes"] = JSONObject().put("circ", relayA).toString()
        boot()
        assertEquals(listOf(relayA), HavenNet.explicitRelaysForCircle("circ"))
        HavenNet.reactivateRelay(relayB)   // any save completes the migration
        assertFalse(prefs.data.containsKey("relayNodes"))
        assertTrue(prefs.getString("relays", "")!!.contains(relayA))
    }

    @Test fun removing_a_circle_association_keeps_the_relay_itself() {
        prefs.data["relays"] = JSONObject().put("circ", JSONArray(listOf(relayA))).toString()
        boot()
        HavenNet.setCircleRelay("circ", relayA, on = false)
        assertTrue(HavenNet.explicitRelaysForCircle("circ").isEmpty())
        assertTrue(entry(relayA) != null)
    }

    // ---- deactivate, never erase ----------------------------------------------------------------

    @Test fun forgetting_deactivates_keeps_the_config_and_records_a_deletion_stamp() {
        HavenNet.reactivateRelay(relayA); HavenNet.renameRelay(relayA, "Home")
        val before = System.currentTimeMillis()
        settle { HavenNet.forgetRelay(relayA) }
        val e = entry(relayA)!!
        assertFalse(e.active); assertEquals("Home", e.name)
        assertFalse(HavenNet.isRelayActive(relayA))
        assertTrue(HavenNet.relayForgottenRecords()[relayA]!! >= before)
        assertTrue(prefs.getString("relaysSuppressed", "")!!.contains(relayA))
    }

    @Test fun reactivating_after_a_forget_clears_the_tombstone_and_records_a_readd() {
        HavenNet.reactivateRelay(relayA)
        settle { HavenNet.forgetRelay(relayA) }
        HavenNet.reactivateRelay(relayA)
        assertTrue(HavenNet.isRelayActive(relayA))
        assertNull(HavenNet.relayForgottenRecords()[relayA])
        assertTrue("self-sync must be able to supersede a sibling's stale tombstone", HavenNet.relayClearedForgetRecords()[relayA]!! > 0)
    }

    @Test fun forgetting_a_relay_we_never_had_still_leaves_a_tombstone() {
        settle { HavenNet.forgetRelay("  ${relayB.uppercase()}  ") }
        assertFalse(entry(relayB)!!.active)
        assertTrue(HavenNet.relayForgottenRecords().containsKey(relayB))
    }

    // ---- erase + the undo archive ------------------------------------------------------------------

    @Test fun erasing_archives_the_relay_with_its_circles_and_default_and_removes_it() {
        prefs.data["relays"] = JSONObject().put("c1", JSONArray(listOf(relayA))).put("c2", JSONArray(listOf(relayA, relayB))).toString()
        boot()
        HavenNet.setDefaultRelay(relayA)
        settle { HavenNet.eraseRelayNow(relayA) }
        assertNull(entry(relayA)); assertNull("the default pick goes with it", HavenNet.defaultRelay())
        assertTrue(HavenNet.explicitRelaysForCircle("c1").isEmpty())
        assertEquals(listOf(relayB), HavenNet.explicitRelaysForCircle("c2"))
        val rec = HavenNet.erasedRelayList().single()
        assertEquals(relayA, rec.entry.hex); assertEquals(setOf("c1", "c2"), rec.circles.toSet()); assertTrue(rec.wasDefault)
        assertTrue(HavenNet.relayForgottenRecords().containsKey(relayA))
    }

    @Test fun restoring_an_erased_relay_puts_everything_back_and_clears_the_tombstone() {
        prefs.data["relays"] = JSONObject().put("c1", JSONArray(listOf(relayA))).toString()
        boot()
        HavenNet.setDefaultRelay(relayA)
        settle { HavenNet.eraseRelayNow(relayA) }
        settle { HavenNet.restoreErasedRelay(relayA) }
        assertTrue(entry(relayA)!!.active)
        assertEquals(relayA, HavenNet.defaultRelay())
        assertEquals(listOf(relayA), HavenNet.explicitRelaysForCircle("c1"))
        assertTrue(HavenNet.erasedRelayList().isEmpty())
        assertNull("our own tombstone must not delete it again on the next sync", HavenNet.relayForgottenRecords()[relayA])
        assertTrue(HavenNet.relayClearedForgetRecords()[relayA]!! > 0)
    }

    @Test fun dropping_an_archived_deletion_forgets_the_undo() {
        HavenNet.reactivateRelay(relayA)
        settle { HavenNet.eraseRelayNow(relayA) }
        HavenNet.dropErasedRelay(relayA)
        assertTrue(HavenNet.erasedRelayList().isEmpty())
        HavenNet.dropErasedRelay(relayA)   // already gone: no-op
    }

    @Test fun the_archive_survives_a_restart_and_restoring_something_unknown_does_nothing() {
        HavenNet.reactivateRelay(relayA)
        settle { HavenNet.eraseRelayNow(relayA) }
        boot()
        assertEquals(relayA, HavenNet.erasedRelayList().single().entry.hex)
        HavenNet.restoreErasedRelay(relayB)
        assertNull(entry(relayB))
    }

    @Test fun the_archive_keeps_the_twelve_newest_deletions() {
        repeat(14) { i ->
            val hex = "%02x".format(i + 1).repeat(32)
            HavenNet.reactivateRelay(hex)
            settle { HavenNet.eraseRelayNow(hex) }
        }
        assertEquals(12, HavenNet.erasedRelayList().size)
    }

    @Test fun purge_erases_only_relays_that_are_both_inactive_and_unseen_for_a_week() {
        val now = System.currentTimeMillis()
        seedEntries(
            relay(relayA, active = false, lastSeen = now - 8 * day),                  // dead + stale -> erased
            relay(relayB, active = false, lastSeen = now - 1 * day),                  // dead, but recent -> kept
            relay("cc".repeat(32), active = true, lastSeen = now - 30 * day),         // stale, but active -> kept
        )
        settle { HavenNet.purgeStaleRelays() }
        assertNull(entry(relayA))
        assertTrue(entry(relayB) != null); assertTrue(entry("cc".repeat(32)) != null)
        assertEquals(relayA, HavenNet.erasedRelayList().single().entry.hex)
    }

    // ---- last-writer-wins from my other devices -------------------------------------------------------

    @Test fun a_sibling_deletion_newer_than_our_adoption_drops_the_relay() {
        HavenNet.reactivateRelay(relayA)
        val future = System.currentTimeMillis() + 60_000
        settle { HavenNet.applyRelayForgottenTombstone(relayA, future) }
        assertFalse(HavenNet.isRelayActive(relayA))
        assertEquals(future, HavenNet.relayForgottenRecords()[relayA])
    }

    @Test fun a_sibling_deletion_older_than_our_readd_is_ignored() {
        HavenNet.reactivateRelay(relayA)
        HavenNet.applyRelayForgottenTombstone(relayA, 5_000)     // long before we adopted it
        HavenNet.applyRelayForgottenTombstone(relayA, 0)         // no timestamp: nothing to apply
        assertTrue(HavenNet.isRelayActive(relayA))
        assertNull(HavenNet.relayForgottenRecords()[relayA])
    }

    @Test fun applying_the_same_deletion_twice_changes_nothing() {
        HavenNet.reactivateRelay(relayA)
        val t = System.currentTimeMillis() + 60_000
        settle { HavenNet.applyRelayForgottenTombstone(relayA, t) }
        HavenNet.applyRelayForgottenTombstone(relayA, t)         // returns before launching anything
        HavenNet.applyRelayForgottenTombstone(relayA, t - 1)
        assertEquals(t, HavenNet.relayForgottenRecords()[relayA])
    }

    @Test fun a_newer_readd_lifts_our_deletion_and_an_older_one_does_not() {
        HavenNet.reactivateRelay(relayA)
        settle { HavenNet.forgetRelay(relayA) }
        val forgot = HavenNet.relayForgottenRecords()[relayA]!!
        HavenNet.applyRelayClearedForget(relayA, forgot - 1)     // older than our deletion: loses
        assertTrue(HavenNet.relayForgottenRecords().containsKey(relayA))
        settle { HavenNet.applyRelayClearedForget(relayA, forgot + 10) }
        assertNull(HavenNet.relayForgottenRecords()[relayA])
        assertEquals(forgot + 10, HavenNet.relayClearedForgetRecords()[relayA])
        HavenNet.applyRelayClearedForget(relayA, forgot + 5)     // already cleared later than this: no-op
        assertEquals(forgot + 10, HavenNet.relayClearedForgetRecords()[relayA])
    }

    @Test fun self_sync_never_resurrects_a_deactivated_relay_into_a_circle() {
        HavenNet.reactivateRelay(relayA)
        settle { HavenNet.forgetRelay(relayA) }
        HavenNet.selfSyncAddRelay("circ", relayA)
        assertTrue(HavenNet.explicitRelaysForCircle("circ").isEmpty())
        HavenNet.selfSyncAddRelay("circ", "tooshort")
        assertTrue(HavenNet.explicitRelaysForCircle("circ").isEmpty())
    }

    @Test fun self_sync_adds_a_new_relay_to_a_circle_once() {
        HavenNet.selfSyncAddRelay("circ", relayB.uppercase())
        HavenNet.selfSyncAddRelay("circ", relayB)
        assertEquals(listOf(relayB), HavenNet.explicitRelaysForCircle("circ"))
        assertTrue(entry(relayB) != null)
    }

    @Test fun a_deletion_recorded_without_a_stamp_is_given_one_on_load() {
        prefs.data["relaysSuppressed"] = JSONArray(listOf(relayA)).toString()
        val before = System.currentTimeMillis()
        boot()
        assertTrue("an old deletion must not leak back for lack of a timestamp", HavenNet.relayForgottenRecords()[relayA]!! >= before)
    }

    // ---- adopting a relay (the paste box) ------------------------------------------------------------------

    @Test fun pasting_a_bare_node_id_adopts_it_as_an_active_relay() {
        settle { HavenNet.adoptRelay("  ${relayA.uppercase()}  ", name = "Home") }
        val e = entry(relayA)!!
        assertTrue(e.active); assertEquals("Home", e.name)
        assertTrue(e.httpUrls.isEmpty())
    }

    @Test fun pasting_the_relays_interface_blob_learns_http_derp_and_turn_in_one_go() {
        val blob = JSONObject().put("node", relayB.uppercase())
            .put("urls", JSONArray(listOf("https://r.example", "gopher://nope")))
            .put("token", "tok").put("derp", " https://derp.example/ ")
            .put("turn", JSONArray(listOf("turn:t.example:3478", "stun:no"))).toString()
        settle { HavenNet.adoptRelay(blob, setDefault = true) }
        val e = entry(relayB)!!
        assertEquals(listOf("https://r.example"), e.httpUrls); assertEquals("tok", e.httpToken)
        assertEquals("https://derp.example", e.derpUrl)
        assertEquals(listOf("turn:t.example:3478"), e.turnUrls)
        assertEquals("haven", e.turnUser); assertEquals("tok", e.turnPass)
        assertEquals(relayB, HavenNet.defaultRelay())
    }

    @Test fun a_blob_without_urls_and_token_adds_no_http_interface() {
        settle { HavenNet.adoptRelay(JSONObject().put("node", relayA).put("urls", JSONArray(listOf("https://x"))).toString()) }
        assertTrue("urls without a token cannot be used", entry(relayA)!!.httpUrls.isEmpty())
    }

    @Test fun garbage_pastes_are_ignored() {
        HavenNet.adoptRelay("not a relay"); HavenNet.adoptRelay("{broken"); HavenNet.adoptRelay(""); HavenNet.adoptRelay("ab".repeat(31))
        assertTrue(HavenNet.allRelayEntries().isEmpty())
    }

    @Test fun adopting_a_deleted_relay_again_overrides_the_deletion() {
        HavenNet.reactivateRelay(relayA)
        settle { HavenNet.forgetRelay(relayA) }
        settle { HavenNet.adoptRelay(relayA) }
        assertTrue(HavenNet.isRelayActive(relayA))
        assertNull(HavenNet.relayForgottenRecords()[relayA])
        assertTrue(HavenNet.relayClearedForgetRecords()[relayA]!! > 0)
    }
}
