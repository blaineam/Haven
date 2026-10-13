package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.FeedCommentFfi
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.LinkConstraint
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * The qa-cmd v2 driver the e2e fleet leans on (docs/QA.md): op dispatch, the drop-file consume rules
 * and the dump it answers with. Run against [FakeSocial]; the ops that author through the real engine
 * (post / dm / react …) are covered only on their refusal paths here, because their happy path needs
 * the Rust node.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class QaDriverTest {
    private lateinit var ctx: FakeContext
    private lateinit var social: FakeSocial
    private val driver = QaDriver::class.java
    private val net = HavenNet::class.java
    private val me = "11".repeat(32)
    private val other = "22".repeat(32)

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        net.getDeclaredField("appContext").apply { isAccessible = true }.set(HavenNet, ctx)
        driver.getDeclaredField("appContext").apply { isAccessible = true }.set(QaDriver, ctx)
        driver.getDeclaredField("wroteIdentity").apply { isAccessible = true }.setBoolean(QaDriver, true)
        driver.getDeclaredField("badDropSig").apply { isAccessible = true }.set(QaDriver, null)
        LocalMedia.init(ctx); CircleDeletion.init(ctx)
        social = FakeSocial()
        net.getDeclaredField("social").apply { isAccessible = true }.set(HavenNet, social)
        setReady(false)
        HavenNet.contacts.clear()
        QaPerf.reset()
    }
    @After fun tearDown() {
        setReady(false); LowDataMonitor.debugForced = null; HavenNet.contacts.clear()
        Dispatchers.resetMain(); ctx.filesDir.deleteRecursively()
    }

    private fun setReady(v: Boolean) = net.getDeclaredField("ready").apply { isAccessible = true }.setBoolean(HavenNet, v)
    private fun invoke(name: String, vararg args: Any?): Any? {
        val m = driver.declaredMethods.first { it.name == name && it.parameterCount == args.size }.apply { isAccessible = true }
        return try { m.invoke(QaDriver, *args) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }
    private fun apply(json: String) { invoke("apply", JSONObject(json)) }
    private val qaDir get() = File(ctx.filesDir, "qa").apply { mkdirs() }

    private fun item(id: String, at: ULong, body: String = "", media: List<String> = emptyList(), me: Boolean = false,
                     story: Boolean = false, unsent: Boolean = false, comments: List<FeedCommentFfi> = emptyList()) =
        FeedItemFfi(id, "aaaaaaaa", me, at, body, media, null, false, unsent, story, false, comments, emptyList(), null)

    // ---- ops ------------------------------------------------------------------------------------

    @Test fun the_link_constraint_op_forces_and_releases_the_satellite_path() {
        apply("""{"op":"link_constraint","level":"ultra"}"""); assertEquals(LinkConstraint.ULTRA, LowDataMonitor.debugForced)
        apply("""{"op":"link_constraint","level":"LOW"}"""); assertEquals(LinkConstraint.LOW, LowDataMonitor.debugForced)
        apply("""{"op":"link_constraint","level":"normal"}"""); assertEquals(LinkConstraint.NORMAL, LowDataMonitor.debugForced)
        apply("""{"op":"link_constraint","level":"auto"}"""); assertNull(LowDataMonitor.debugForced)
        apply("""{"op":"link_constraint","level":"ultra"}"""); apply("""{"op":"link_constraint"}""")
        assertNull("anything else hands control back to the real monitor", LowDataMonitor.debugForced)
    }

    @Test fun ops_are_case_and_whitespace_insensitive_and_unknown_ones_are_harmless() {
        apply("""{"op":"  LINK_CONSTRAINT ","level":"ultra"}""")
        assertEquals(LinkConstraint.ULTRA, LowDataMonitor.debugForced)
        apply("""{"op":"no_such_op"}""")
        apply("""{}""")
        apply("""{"op":"dump"}""")
        apply("""{"op":"approve_connections"}""")   // nothing pending: approves nothing
    }

    @Test fun a_wire_relay_op_installs_a_default_relay_through_the_same_api_the_ui_uses() {
        val relay = "cd".repeat(32)
        net.getDeclaredField("relayJoinSeeded").apply { isAccessible = true }.setBoolean(HavenNet, false)
        net.getDeclaredField("lastRelayShape").apply { isAccessible = true }.set(HavenNet, null)
        apply("""{"op":"wire_relay","hex":"${relay.uppercase()}","urls":["http://10.0.2.2:8674"],"token":"tok"}""")
        val e = HavenNet.allRelayEntries().first { it.hex == relay }
        assertEquals(listOf("http://10.0.2.2:8674"), e.httpUrls); assertEquals("tok", e.httpToken); assertTrue(e.active)
        assertEquals(relay, HavenNet.defaultRelay())
    }

    @Test fun a_wire_relay_op_with_bad_arguments_changes_nothing() {
        val before = HavenNet.allRelayEntries().size
        apply("""{"op":"wire_relay","hex":"abc","urls":["http://x"]}""")
        apply("""{"op":"wire_relay","hex":"${"ef".repeat(32)}","urls":[]}""")
        assertEquals(before, HavenNet.allRelayEntries().size)
    }

    @Test fun refused_content_ops_author_nothing() {
        social.circleList = listOf(CircleInfoFfi("c1a", "A", 2u))
        // No contact → no DM; unknown / unheld target ids → no reaction or comment; bad invitee → no add.
        apply("""{"op":"dm","dm_to":"$other","body":"hi"}""")
        apply("""{"op":"react","target_id":"ghost"}""")
        apply("""{"op":"comment","target_id":"ghost","body":"x"}""")
        apply("""{"op":"circle_invite","dm_to":"short"}""")
        assertTrue(social.calls.isEmpty())
    }

    // ---- circle targeting -----------------------------------------------------------------------

    @Test fun an_explicit_circle_is_honored_only_when_the_device_holds_it() {
        social.circleList = listOf(CircleInfoFfi("c1held", "Held", 2u), CircleInfoFfi("c1gone", "Gone", 2u))
        CircleDeletion.markDeleted("c1gone")
        fun ask(id: String) = invoke("explicitCircle", JSONObject().put("circle_id", id))
        assertEquals("c1held", ask(" c1held "))
        assertNull("deleted circle", ask("c1gone"))
        assertNull("never heard of", ask("c1nope"))
        assertNull("no circle_id", invoke("explicitCircle", JSONObject()))
        social.failReads = true
        assertNull("engine down: keep the default target", ask("c1held"))
    }

    @Test fun a_post_id_resolves_to_the_circle_holding_it() {
        social.circleList = listOf(CircleInfoFfi("c1a", "A", 2u), CircleInfoFfi("c1b", "B", 2u))
        social.feeds["c1b"] = listOf(item("p-target", 5uL))
        assertEquals("c1b", invoke("circleOf", "p-target"))
        assertNull(invoke("circleOf", "p-missing"))
        assertNull(invoke("circleOf", ""))
        social.failReads = true
        assertNull(invoke("circleOf", "p-target"))
    }

    // ---- staged inputs --------------------------------------------------------------------------

    @Test fun staged_inputs_are_found_in_the_qa_dir_first_and_empty_files_do_not_count() {
        assertNull(invoke("staged", "qa-cmd.json"))
        File(ctx.filesDir, "qa-cmd.json").writeText("""{"op":"dump"}""")
        assertEquals(File(ctx.filesDir, "qa-cmd.json"), invoke("staged", "qa-cmd.json"))
        File(qaDir, "qa-cmd.json").writeText("""{"op":"perf_reset"}""")
        assertEquals("the app's own qa dir wins", File(qaDir, "qa-cmd.json"), invoke("staged", "qa-cmd.json"))
        File(qaDir, "empty.txt").writeText("")
        assertNull(invoke("staged", "empty.txt"))
    }

    @Test fun a_driver_path_resolves_directly_or_by_basename_from_the_staging_dirs() {
        val direct = File(ctx.filesDir, "photo.jpg").apply { writeText("x") }
        assertEquals(direct, invoke("resolve", direct.absolutePath))
        File(qaDir, "other.mp4").writeText("v")
        assertEquals(File(qaDir, "other.mp4"), invoke("resolve", "/sdcard/Download/other.mp4"))
        assertNull(invoke("resolve", "/nowhere/ghost.bin"))
        assertNull(invoke("resolve", "   "))
    }

    @Test fun only_fetchable_blobs_count_as_real_media_refs() {
        val real = invoke("realRefs", listOf("img_abc", "geo:1,2,x", "thumb:img_t", "vid_v")) as List<*>
        assertEquals(listOf("img_abc", "vid_v"), real)
    }

    // ---- the drop-file consumer -----------------------------------------------------------------

    private fun consume() { invoke("consume") }
    private val dump get() = File(qaDir, "qa-dump-${com.blaineam.haven.BuildConfig.APPLICATION_ID}.json")

    private fun awaitFile(f: File) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (!f.exists() && System.nanoTime() < deadline) Thread.onSpinWait()
        assertTrue("never produced ${f.name}", f.exists())
    }

    @Test fun nothing_is_consumed_before_the_engine_is_ready() {
        File(qaDir, "qa-cmd.json").writeText("""{"op":"perf_reset"}""")
        consume()
        assertTrue("an early drop is left for the next tick", File(qaDir, "qa-cmd.json").exists())
    }

    @Test fun a_broken_drop_gets_one_more_tick_then_is_discarded() {
        setReady(true)
        val f = File(qaDir, "qa-cmd.json").apply { writeText("{half-pushed") }
        consume(); assertTrue("might be mid adb push", f.exists())
        consume(); assertFalse("stable and still broken: discarded", f.exists())
    }

    @Test fun a_good_drop_is_deleted_applied_and_answered_with_a_dump() {
        setReady(true)
        social.circleList = listOf(CircleInfoFfi("c1fam", "Family", 3u))
        social.feeds["c1fam"] = listOf(item("p1", 10uL, body = "hello", me = true))
        LowDataMonitor.debugForced = null
        val f = File(qaDir, "qa-cmd.json").apply { writeText("""{"op":"link_constraint","level":"low"}""") }
        consume()
        assertFalse("one-shot: removed on consume", f.exists())
        awaitFile(dump)
        assertEquals(LinkConstraint.LOW, LowDataMonitor.debugForced)
        assertEquals("android", JSONObject(dump.readText()).getString("device"))
    }

    // ---- the dump -------------------------------------------------------------------------------

    @Test fun the_dump_describes_posts_circles_dms_and_contacts_the_way_the_harness_reads_them() {
        setReady(true)
        val dmId = "dm:$me-$other"
        HavenNet.contacts.add(Contact(other, "Ben", ""))
        social.circleList = listOf(CircleInfoFfi("c1fam", "Family", 3u), CircleInfoFfi(dmId, "dm", 2u), CircleInfoFfi("c1dead", "Dead", 1u))
        CircleDeletion.markDeleted("c1dead")
        val photo = "img_" + "a1".repeat(32)
        assertTrue(LocalMedia.writeRawSealed(photo, ByteArray(10) { 1 }))
        val comments = listOf(
            FeedCommentFfi("k1", "bbbbbbbb", false, 11uL, "nice", emptyList(), false, false, emptyList()),
            FeedCommentFfi("k2", "bbbbbbbb", false, 12uL, "retracted", emptyList(), false, true, emptyList()),
        )
        social.feeds["c1fam"] = listOf(
            item("p1", 10uL, body = "look", media = listOf(photo, "thumb:img_t:$photo"), me = true, comments = comments),
            item("p2", 20uL, body = "caption", story = true),
            item("p3", 30uL, body = "oops", unsent = true),
        )
        social.feeds[dmId] = listOf(item("m1", 40uL, body = "hey"), item("m2", 41uL, body = "gone", unsent = true))
        social.members["c1fam"] = listOf(other)

        invoke("writeDump")
        val o = JSONObject(dump.readText())
        assertEquals("android", o.getString("device"))

        val posts = o.getJSONArray("posts")
        assertEquals("unsent posts are not reported", 2, posts.length())
        val p1 = posts.getJSONObject(0)
        assertEquals("p1", p1.getString("id")); assertEquals("c1fam", p1.getString("circle")); assertFalse(p1.getBoolean("story"))
        assertTrue(p1.isNull("caption"))
        assertEquals(listOf(photo), (0 until p1.getJSONArray("media_refs").length()).map { p1.getJSONArray("media_refs").getString(it) })
        assertTrue("the blob is here", p1.getJSONArray("media_present").getBoolean(0))
        assertEquals(1, p1.getJSONArray("media_markers").length())
        assertEquals("a retracted comment is not reported", 1, p1.getJSONArray("comments").length())
        val p2 = posts.getJSONObject(1)
        assertTrue(p2.getBoolean("story")); assertEquals("caption", p2.getString("caption"))

        val circles = o.getJSONArray("circles")
        assertEquals("deleted circles and DMs are not circles", 1, circles.length())
        assertEquals("Family", circles.getJSONObject(0).getString("name"))
        assertEquals(other, circles.getJSONObject(0).getJSONArray("members").getString(0))

        val dms = o.getJSONObject("dms")
        // Keyed by the non-account members; this fixture has no account identity, so both ids appear.
        assertEquals(setOf("$me,$other"), dms.keys().asSequence().toSet())
        assertEquals("unsent messages are not reported", 1, dms.getJSONArray("$me,$other").length())

        assertEquals("Ben", o.getJSONArray("contacts").getJSONObject(0).getString("name"))
        assertTrue(o.has("perf")); assertTrue(o.has("relay_first")); assertTrue(o.has("launch")); assertTrue(o.has("call"))
        assertFalse("no call is up", o.getJSONObject("call").getBoolean("in_call"))
    }

    @Test fun the_dump_is_skipped_until_the_engine_is_ready() {
        invoke("writeDump")
        assertFalse(dump.exists())
    }

    @Test fun a_dump_write_failure_is_raised_not_swallowed() {
        setReady(true)
        // A directory squatting on the dump's name makes the atomic rename fail on every attempt.
        dump.mkdirs(); File(dump, "keep").writeText("x")
        try { invoke("writeDump"); org.junit.Assert.fail("a frozen channel must be loud") } catch (e: Exception) { /* expected */ }
    }
}
