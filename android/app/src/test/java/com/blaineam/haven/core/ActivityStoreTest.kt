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
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The activity bell: read watermark (monotonic, synced), app-layer rows, and the engine/app merge. */
@OptIn(ExperimentalCoroutinesApi::class)
class ActivityStoreTest {
    private lateinit var ctx: FakeContext

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
    }
    @After fun tearDown() { Dispatchers.resetMain() }

    /** ActivityStore is a one-shot singleton (`init` ignores a second call); reset it by reflection. */
    private fun boot(prefsInit: FakePrefs.() -> Unit = {}) {
        val c = ActivityStore::class.java
        c.getDeclaredField("appContext").apply { isAccessible = true }.set(ActivityStore, null)
        // refreshPending=true parks poke(): its debounced background refresh (1.5 s of real time) would
        // otherwise land in a LATER test and rewrite `rows` under it. Tests call refresh() directly.
        c.getDeclaredField("refreshPending").apply { isAccessible = true }.setBoolean(ActivityStore, true)
        ctx.prefs("haven.activity").prefsInit()
        ActivityStore.init(ctx)
    }

    private fun refresh() {
        ActivityStore::class.java.getDeclaredMethod("refresh", uniffi.haven_ffi.HavenSocial::class.java)
            .apply { isAccessible = true }.invoke(ActivityStore, null)
    }

    private fun row(id: String, kind: String, at: Long) = JSONObject()
        .put("id", id).put("kind", kind).put("cid", "c").put("actor", "ab").put("short", "ab")
        .put("target", "").put("snippet", id).put("at", at).put("emoji", "")

    private fun storedRows(): JSONArray = JSONArray(ctx.prefs("haven.activity").getString("appRows", "[]"))

    @Test fun init_restores_the_watermark_and_app_rows() {
        boot {
            data["seenAt"] = 1_000L
            data["appRows"] = JSONArray().put(row("connect:aa", "connect", 500)).put(row("circle:x", "circle", 2_000)).toString()
        }
        assertEquals(1_000L, ActivityStore.seenAt())
        assertEquals(2, ActivityStore.rows.size)
        assertEquals("only rows newer than the watermark badge the bell", 1, ActivityStore.unseenCount())
    }

    @Test fun mark_seen_moves_the_watermark_forward_persists_and_clears_the_badge() {
        boot { data["appRows"] = JSONArray().put(row("connect:aa", "connect", 1)).toString() }
        assertEquals(1, ActivityStore.unseenCount())
        val before = System.currentTimeMillis()
        ActivityStore.markSeen()
        assertTrue(ActivityStore.seenAt() >= before)
        assertEquals(0, ActivityStore.unseenCount())
        assertEquals(ActivityStore.seenAt(), ctx.prefs("haven.activity").getLong("seenAt", 0))
    }

    @Test fun a_synced_watermark_only_ever_moves_forward() {
        boot { data["seenAt"] = 5_000L }
        ActivityStore.applySyncedSeenAt(4_000)
        assertEquals("a sibling cannot un-read what this device has read", 5_000L, ActivityStore.seenAt())
        ActivityStore.applySyncedSeenAt(5_000)
        assertEquals(5_000L, ActivityStore.seenAt())
        ActivityStore.applySyncedSeenAt(9_000)
        assertEquals(9_000L, ActivityStore.seenAt())
        assertEquals(9_000L, ctx.prefs("haven.activity").getLong("seenAt", 0))
    }

    @Test fun a_connection_is_recorded_once_per_person() {
        boot()
        ActivityStore.noteConnection("abcdef0123456789", "Ana")
        ActivityStore.noteConnection("abcdef0123456789", "Ana again")
        val rows = storedRows()
        assertEquals(1, rows.length())
        val r = rows.getJSONObject(0)
        assertEquals("connect:abcdef0123456789", r.getString("id"))
        assertEquals("connect", r.getString("kind")); assertEquals("Ana", r.getString("snippet"))
        assertEquals("abcdef01", r.getString("short"))
    }

    @Test fun being_added_to_a_circle_is_recorded_once_per_circle() {
        boot()
        ActivityStore.noteCircleAdd("circ-1", "Family")
        ActivityStore.noteCircleAdd("circ-1", "Family")
        ActivityStore.noteCircleAdd("circ-2", "Friends")
        assertEquals(setOf("circle:circ-1", "circle:circ-2"), (0 until storedRows().length()).map { storedRows().getJSONObject(it).getString("id") }.toSet())
    }

    @Test fun app_rows_are_capped_at_200_keeping_the_newest() {
        boot {
            val arr = JSONArray(); for (i in 0 until 200) arr.put(row("circle:old$i", "circle", i.toLong()))
            data["appRows"] = arr.toString()
        }
        ActivityStore.noteConnection("ff".repeat(32), "New")
        val rows = storedRows()
        assertEquals(200, rows.length())
        assertEquals("the newest goes first", "connect:" + "ff".repeat(32), rows.getJSONObject(0).getString("id"))
    }

    @Test fun refresh_merges_newest_first_with_ties_broken_by_id() {
        boot {
            data["appRows"] = JSONArray().put(row("b", "connect", 10)).put(row("a", "circle", 10)).put(row("z", "connect", 99)).toString()
        }
        refresh()
        assertEquals(listOf("z", "a", "b"), ActivityStore.rows.map { it.id })
    }

    @Test fun corrupt_stored_rows_are_ignored() {
        boot { data["appRows"] = "{definitely not an array" }
        assertTrue(ActivityStore.rows.isEmpty())
        boot { data["appRows"] = JSONArray().put("junk").put(row("ok", "connect", 1)).toString() }
        assertEquals(listOf("ok"), ActivityStore.rows.map { it.id }.filter { it == "ok" })
    }

    @Test fun nothing_is_recorded_before_init() {
        val c = ActivityStore::class.java
        c.getDeclaredField("appContext").apply { isAccessible = true }.set(ActivityStore, null)
        ActivityStore.noteConnection("aa".repeat(32), "x")   // must not throw
        ActivityStore.markSeen()
        assertFalse(ctx.prefs("haven.activity").data.containsKey("appRows"))
    }
}
