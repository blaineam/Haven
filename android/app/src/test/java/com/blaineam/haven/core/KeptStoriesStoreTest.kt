package com.blaineam.haven.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Kept stories: pinning, tombstoned per-entry LWW sync, persistence, and the iOS-compatible wire. */
class KeptStoriesStoreTest {
    private lateinit var ctx: FakeContext

    @Before fun setUp() {
        ctx = FakeContext()
        PinnedMediaStore.init(ctx)
        KeptStoriesStore.init(ctx)
    }

    private fun keep(id: String, media: List<String> = listOf("img_$id"), at: Long = 100) =
        KeptStoriesStore.keep(id, "body $id", media, at, null)

    private fun wire(vararg kept: JSONObject, removed: Map<String, Long> = emptyMap()): ByteArray {
        val root = JSONObject()
        root.put("kept", JSONArray(kept.toList()))
        val rem = JSONObject(); for ((k, v) in removed) rem.put(k, v)
        root.put("removed", rem)
        return root.toString().toByteArray()
    }

    private fun entry(id: String, keptAt: Long?, media: List<String> = listOf("img_$id"), createdAt: Long = 50) =
        JSONObject().put("id", id).put("body", "b").put("media", JSONArray(media)).put("createdAt", createdAt)
            .also { if (keptAt != null) it.put("keptAt", keptAt) }

    @Test fun keep_snapshots_pins_media_and_is_idempotent() {
        keep("a")
        keep("a")   // second keep is ignored
        assertEquals(1, KeptStoriesStore.all().size)
        assertTrue(KeptStoriesStore.isKept("a"))
        assertTrue(PinnedMediaStore.isPinned("img_a"))
        assertEquals("body a", KeptStoriesStore.get("a")?.body)
        assertNull(KeptStoriesStore.get("zzz"))
        assertNull(KeptStoriesStore.get("a")!!.music())
    }

    @Test fun all_is_newest_first_by_story_creation_time() {
        keep("old", at = 10); keep("new", at = 30); keep("mid", at = 20)
        assertEquals(listOf("new", "mid", "old"), KeptStoriesStore.all().map { it.id })
    }

    @Test fun unkeep_releases_pin_unless_another_kept_story_shares_the_blob() {
        keep("a", media = listOf("img_shared", "img_onlyA"))
        keep("b", media = listOf("img_shared"))
        KeptStoriesStore.unkeep("a")
        assertFalse(PinnedMediaStore.isPinned("img_onlyA"))
        assertTrue("shared blob still needed by b", PinnedMediaStore.isPinned("img_shared"))
        KeptStoriesStore.unkeep("b")
        assertFalse(PinnedMediaStore.isPinned("img_shared"))
        KeptStoriesStore.unkeep("never-kept")   // no-op, no crash
    }

    @Test fun toggle_flips_between_kept_and_not() {
        KeptStoriesStore.toggle("t", "b", listOf("img_t"), 1, null)
        assertTrue(KeptStoriesStore.isKept("t"))
        KeptStoriesStore.toggle("t", "b", listOf("img_t"), 1, null)
        assertFalse(KeptStoriesStore.isKept("t"))
    }

    @Test fun state_survives_a_restart() {
        keep("a"); keep("b"); KeptStoriesStore.unkeep("b")
        KeptStoriesStore.init(FakeContext(ctx.allPrefs))   // new process, same prefs
        assertEquals(listOf("a"), KeptStoriesStore.all().map { it.id })
        // The tombstone survived too: a stale sibling copy of b must not resurrect it.
        assertFalse(KeptStoriesStore.applySyncedJson(wire(entry("b", keptAt = 1))))
        assertFalse(KeptStoriesStore.isKept("b"))
    }

    @Test fun init_tolerates_corrupt_prefs() {
        ctx.prefs("haven.stories.kept").data["kept"] = "{not json"
        ctx.prefs("haven.stories.kept").data["removed"] = "[[["
        KeptStoriesStore.init(ctx)
        assertTrue(KeptStoriesStore.all().isEmpty())
    }

    @Test fun nothing_to_say_publishes_nothing() {
        assertNull("a fresh device must not blank a sibling's collection", KeptStoriesStore.toJsonBytes())
        keep("a")
        assertNotNull(KeptStoriesStore.toJsonBytes())
    }

    @Test fun a_tombstone_alone_is_still_published() {
        keep("a"); KeptStoriesStore.unkeep("a")
        val root = JSONObject(String(KeptStoriesStore.toJsonBytes()!!))
        assertEquals(0, root.getJSONArray("kept").length())
        assertTrue(root.getJSONObject("removed").has("a"))
    }

    @Test fun wire_format_omits_absent_optionals_like_swift_and_round_trips() {
        keep("a")
        val o = JSONObject(String(KeptStoriesStore.toJsonBytes()!!)).getJSONArray("kept").getJSONObject(0)
        assertEquals("a", o.getString("id"))
        assertTrue(o.has("keptAt"))
        for (k in listOf("musicCatalogId", "musicTitle", "musicArtist", "musicArtworkUrl", "musicDurationMs"))
            assertFalse("$k must be omitted when absent", o.has(k))
    }

    @Test fun music_fields_round_trip_through_the_wire_and_rebuild_a_track_ref() {
        val e = entry("m", keptAt = 5).put("musicCatalogId", "cat1").put("musicTitle", "T")
            .put("musicArtist", "A").put("musicArtworkUrl", "u").put("musicDurationMs", 1234L)
        assertTrue(KeptStoriesStore.applySyncedJson(wire(e)))
        val m = KeptStoriesStore.get("m")!!.music()!!
        assertEquals("cat1", m.catalogId); assertEquals("T", m.title); assertEquals("A", m.artist)
        assertEquals("u", m.artworkUrl); assertEquals(1234L, m.durationMs.toLong())
        val out = JSONObject(String(KeptStoriesStore.toJsonBytes()!!)).getJSONArray("kept").getJSONObject(0)
        assertEquals(1234L, out.getLong("musicDurationMs"))
    }

    @Test fun sync_unions_stories_kept_on_different_devices_and_pins_arrivals() {
        keep("phone")
        assertTrue(KeptStoriesStore.applySyncedJson(wire(entry("tablet", keptAt = 7))))
        assertEquals(setOf("phone", "tablet"), KeptStoriesStore.all().map { it.id }.toSet())
        assertTrue(PinnedMediaStore.isPinned("img_tablet"))
    }

    @Test fun sync_newer_copy_replaces_older_and_older_is_ignored() {
        KeptStoriesStore.applySyncedJson(wire(entry("x", keptAt = 10).put("body", "v1")))
        assertTrue(KeptStoriesStore.applySyncedJson(wire(entry("x", keptAt = 20).put("body", "v2"))))
        assertEquals("v2", KeptStoriesStore.get("x")!!.body)
        assertFalse(KeptStoriesStore.applySyncedJson(wire(entry("x", keptAt = 15).put("body", "stale"))))
        assertEquals("v2", KeptStoriesStore.get("x")!!.body)
    }

    @Test fun sync_newer_tombstone_removes_local_copy_and_unpins() {
        KeptStoriesStore.applySyncedJson(wire(entry("x", keptAt = 10)))
        assertTrue(KeptStoriesStore.applySyncedJson(wire(removed = mapOf("x" to 99L))))
        assertFalse(KeptStoriesStore.isKept("x"))
        assertFalse(PinnedMediaStore.isPinned("img_x"))
    }

    @Test fun sync_older_tombstone_loses_to_a_more_recent_keep() {
        KeptStoriesStore.applySyncedJson(wire(entry("x", keptAt = 50)))
        // The tombstone is recorded (changed) but cannot remove the more recently kept copy.
        KeptStoriesStore.applySyncedJson(wire(removed = mapOf("x" to 5L)))
        assertTrue(KeptStoriesStore.isKept("x"))
    }

    @Test fun sync_entry_older_than_its_tombstone_is_skipped() {
        KeptStoriesStore.applySyncedJson(wire(removed = mapOf("x" to 100L)))
        assertFalse(KeptStoriesStore.applySyncedJson(wire(entry("x", keptAt = 40))))
        assertFalse(KeptStoriesStore.isKept("x"))
    }

    @Test fun legacy_entry_without_keptAt_falls_back_to_createdAt() {
        KeptStoriesStore.applySyncedJson(wire(removed = mapOf("x" to 60L)))
        // Story created at 50, un-kept at 60: a record from before syncing existed must lose to that tombstone.
        assertFalse(KeptStoriesStore.applySyncedJson(wire(entry("x", keptAt = null, createdAt = 50))))
        assertFalse(KeptStoriesStore.isKept("x"))
        // With no tombstone it is kept, and stays "legacy" (no keptAt invented for it).
        assertTrue(KeptStoriesStore.applySyncedJson(wire(entry("y", keptAt = null, createdAt = 70))))
        assertNull(KeptStoriesStore.get("y")!!.keptAt)
    }

    @Test fun rekeeping_clears_the_tombstone() {
        keep("a"); KeptStoriesStore.unkeep("a"); keep("a")
        val root = JSONObject(String(KeptStoriesStore.toJsonBytes()!!))
        assertFalse(root.getJSONObject("removed").has("a"))
    }

    @Test fun garbage_sync_payloads_are_rejected_without_touching_state() {
        keep("a")
        assertFalse(KeptStoriesStore.applySyncedJson("not json".toByteArray()))
        assertFalse(KeptStoriesStore.applySyncedJson("{}".toByteArray()))
        val bad = JSONObject().put("kept", JSONArray().put(JSONObject().put("body", "no id")).put("junk"))
        assertFalse(KeptStoriesStore.applySyncedJson(bad.toString().toByteArray()))
        assertEquals(1, KeptStoriesStore.all().size)
    }

    @Test fun tombstones_are_bounded_keeping_the_newest() {
        repeat(520) { i -> keep("s$i"); KeptStoriesStore.unkeep("s$i") }
        val rem = JSONObject(String(KeptStoriesStore.toJsonBytes()!!)).getJSONObject("removed")
        assertTrue("pruned well below 520, got ${rem.length()}", rem.length() <= 270)
    }

    @Test fun wipe_clears_memory_and_prefs() {
        keep("a")
        KeptStoriesStore.wipe()
        assertTrue(KeptStoriesStore.all().isEmpty())
        assertNull(KeptStoriesStore.toJsonBytes())
        assertFalse(ctx.prefs("haven.stories.kept").data.containsKey("kept"))
    }
}
