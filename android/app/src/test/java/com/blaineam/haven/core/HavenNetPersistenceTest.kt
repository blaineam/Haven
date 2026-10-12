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
import java.io.File

/** What HavenNet writes to SharedPreferences / disk and reads back on the next launch. */
@OptIn(ExperimentalCoroutinesApi::class)
class HavenNetPersistenceTest {
    private lateinit var ctx: FakeContext
    private val net = HavenNet::class.java

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        field("appContext").set(HavenNet, ctx)
        LocalMedia.init(ctx)
    }
    @After fun tearDown() { Dispatchers.resetMain(); ctx.filesDir.deleteRecursively() }

    private fun field(name: String) = net.getDeclaredField(name).apply { isAccessible = true }
    private fun call(name: String, vararg args: Any?): Any? =
        net.declaredMethods.first { it.name == name && it.parameterCount == args.size }
            .apply { isAccessible = true }.invoke(HavenNet, *args)
    private val prefs get() = ctx.prefs("haven.contacts")
    private val hexA = "aa".repeat(32)
    private val hexB = "bb".repeat(32)

    // ---- contacts & blocked ------------------------------------------------------------------

    @Test fun contacts_round_trip_through_prefs() {
        HavenNet.contacts.clear()
        HavenNet.contacts.addAll(listOf(Contact(hexA, "Ana", "v1"), Contact(hexB, "Ben", "")))
        call("saveContacts")
        HavenNet.contacts.clear()
        call("loadContacts")
        assertEquals(listOf(Contact(hexA, "Ana", "v1"), Contact(hexB, "Ben", "")), HavenNet.contacts.toList())
        HavenNet.contacts.clear()
    }

    @Test fun a_corrupt_contact_list_leaves_the_current_one_alone() {
        HavenNet.contacts.clear(); HavenNet.contacts.add(Contact(hexA, "Ana", ""))
        prefs.data["contacts"] = "{broken"
        call("loadContacts")
        assertEquals(1, HavenNet.contacts.size)
        prefs.data.remove("contacts")
        call("loadContacts")   // nothing stored: no-op
        assertEquals(1, HavenNet.contacts.size)
        HavenNet.contacts.clear()
    }

    @Test fun the_blocked_list_round_trips() {
        HavenNet.blocked.clear(); HavenNet.blocked.addAll(listOf(hexA, hexB))
        call("saveBlocked")
        HavenNet.blocked.clear()
        call("loadBlocked")
        assertEquals(listOf(hexA, hexB), HavenNet.blocked.toList())
        prefs.data["blocked"] = "nope"
        call("loadBlocked")
        assertEquals("a corrupt blob changes nothing", listOf(hexA, hexB), HavenNet.blocked.toList())
        HavenNet.blocked.clear()
    }

    // ---- invite device hints --------------------------------------------------------------------

    @Test fun device_hints_are_lowercased_deduplicated_capped_and_persisted() {
        (field("deviceHints").get(HavenNet) as MutableMap<*, *>).clear()
        HavenNet.recordDeviceHints(hexA.uppercase(), listOf(hexB.uppercase(), hexB, "tooshort"))
        assertEquals(listOf(hexB), call("deviceHintsFor", hexA) as List<*>)
        val saved = JSONObject(prefs.getString("deviceHints", "{}")!!)
        assertEquals(1, saved.getJSONArray(hexA).length())
        HavenNet.recordDeviceHints(hexA, emptyList())              // nothing to record
        HavenNet.recordDeviceHints(hexA, listOf(hexB))             // already known: no rewrite
        val ids = (0 until 10).map { "%02x".format(it + 16).repeat(32) }
        HavenNet.recordDeviceHints(hexA, ids)
        val hints = call("deviceHintsFor", hexA) as List<*>
        assertEquals("only the 8 newest are kept", 8, hints.size)
        assertEquals(ids.last(), hints.last())
    }

    @Test fun device_hints_reload_after_a_restart() {
        (field("deviceHints").get(HavenNet) as MutableMap<*, *>).clear()
        prefs.data["deviceHints"] = JSONObject().put(hexA, JSONArray(listOf(hexB))).toString()
        call("loadDeviceHints")
        assertEquals(listOf(hexB), call("deviceHintsFor", hexA.uppercase()) as List<*>)
        assertEquals(emptyList<String>(), call("deviceHintsFor", hexB) as List<*>)
    }

    // ---- durable media-backup queue ---------------------------------------------------------------

    private fun resetBackupQueue() {
        (field("pendingBackups").get(HavenNet) as MutableSet<*>).clear()
        field("pendingBackupsLoaded").setBoolean(HavenNet, false)
    }

    @Test fun a_queued_backup_is_durable_before_it_is_uploaded() {
        resetBackupQueue()
        call("addPendingBackup", "img_x", "circ")
        assertTrue(HavenNet.hasPendingBackup("img_x"))
        assertFalse(HavenNet.hasPendingBackup("img_y"))
        assertEquals("circ", call("pendingBackupCircle", "img_x"))
        assertNull(call("pendingBackupCircle", "img_nope"))
        assertEquals(setOf("img_x|circ"), ctx.prefs("haven.mediabackup.queue").getStringSet("pending", mutableSetOf()))
    }

    @Test fun a_backup_persisted_by_a_previous_session_is_found_again() {
        ctx.prefs("haven.mediabackup.queue").data["pending"] = setOf("img_old|c1")
        resetBackupQueue()
        assertTrue(HavenNet.hasPendingBackup("img_old"))
        assertEquals("c1", call("pendingBackupCircle", "img_old"))
    }

    @Test fun adding_the_same_backup_twice_keeps_one_entry() {
        resetBackupQueue()
        call("addPendingBackup", "img_x", "circ"); call("addPendingBackup", "img_x", "circ")
        assertEquals(1, ctx.prefs("haven.mediabackup.queue").getStringSet("pending", mutableSetOf())!!.size)
    }

    // ---- quarantined (unopenable) media ------------------------------------------------------------

    private fun unopenable() = field("unopenableMedia").get(HavenNet) as MutableSet<*>

    @Test fun the_first_launch_of_a_new_repair_epoch_gives_parked_refs_another_try() {
        unopenable().clear()
        prefs.data["unopenableMedia"] = setOf("img_stuck"); prefs.data["unopenableEpoch"] = 1
        call("loadUnopenable")
        assertTrue(unopenable().isEmpty())
        assertFalse(prefs.data.containsKey("unopenableMedia"))
        assertEquals(2, prefs.getInt("unopenableEpoch", 0))
    }

    @Test fun within_an_epoch_parked_refs_stay_parked_but_empty_files_are_not_a_verdict() {
        unopenable().clear()
        File(ctx.filesDir, "media/img_empty").writeBytes(ByteArray(0))
        File(ctx.filesDir, "media/img_real").writeBytes(byteArrayOf(1, 2, 3))
        prefs.data["unopenableEpoch"] = 2
        prefs.data["unopenableMedia"] = setOf("img_empty", "img_real", "img_absent")
        call("loadUnopenable")
        assertEquals(setOf("img_real", "img_absent"), unopenable().toSet())
        assertFalse("the empty file was dropped so the sweep refetches it", LocalMedia.has("img_empty"))
        unopenable().clear()
    }
}
