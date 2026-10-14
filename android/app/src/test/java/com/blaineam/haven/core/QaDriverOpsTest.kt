package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.FeedItemFfi
import java.io.File

/**
 * The qa-cmd ops that drive the real author and call paths — the half of the driver the refusal-path tests cannot reach.
 * The engine accepts what it is asked to author ([FakeSocial.authorOk]) and the relay is in-process, so what each op
 * does shows up where the e2e fleet would look: the authored event, the relay mailbox, the call state.
 */
class QaDriverOpsTest {
    private val env = NetEnv()
    private val driver = QaDriver::class.java
    private val peer = "c3".repeat(32)

    @Before fun setUp() {
        env.up()
        driver.getDeclaredField("appContext").apply { isAccessible = true }.set(QaDriver, env.ctx)
        driver.getDeclaredField("wroteIdentity").apply { isAccessible = true }.setBoolean(QaDriver, true)   // no background identity/dump write
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u))
        env.social.members["default"] = listOf(peer)
        env.social.authorOk = "ENV-qa".toByteArray()
        env.social.authoredId = "post-qa"
        env.social.lenient = true
        HavenNet.contacts.add(Contact(peer, "Pat", "v"))
        CircleSettings.init(env.ctx); HiddenStore.init(env.ctx)
    }
    @After fun tearDown() { QaPerf.reset(); env.down() }

    private fun until(cond: () -> Boolean) = runBlocking { withTimeout(15_000) { while (!cond()) yield() } }
    private fun dispatch(json: String) {
        val m = driver.getDeclaredMethod("dispatch", String::class.java, JSONObject::class.java).apply { isAccessible = true }
        val cmd = JSONObject(json)
        try { m.invoke(QaDriver, cmd.optString("op").trim().lowercase(), cmd) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }
    private fun landed(envelope: String) = env.relay.store.containsKey(HavenKeys.mailboxKey("default", envelope.toByteArray()))
    private fun drainCallThread() {
        val h = CallManager::class.java.getDeclaredField("callHandler").apply { isAccessible = true }.get(CallManager)
        h.javaClass.getMethod("drainAll").invoke(h)
    }

    @Test fun post_and_story_ops_author_into_the_requested_circle_and_the_relay_receives_them() {
        dispatch("""{"op":"post","body":"hello from qa"}""")
        assertEquals("post", env.social.authored.last().verb)
        until { landed("ENV-qa") }
        dispatch("""{"op":"story","caption":"qa story"}""")
        assertEquals("story", env.social.authored.last().verb)
        assertEquals("qa story", env.social.authored.last().body)
    }

    @Test fun an_unknown_circle_id_keeps_the_default_target() {
        dispatch("""{"op":"post","body":"x","circle_id":"c1nonexistent"}""")
        assertEquals("default", env.social.authored.last().circleId)
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u), CircleInfoFfi("c1real", "Real", 2u))
        dispatch("""{"op":"post","body":"y","circle_id":"c1real"}""")
        assertEquals("c1real", env.social.authored.last().circleId)
    }

    @Test fun photo_media_is_staged_from_a_driver_file_and_the_post_carries_its_ref() {
        val photo = File(env.ctx.filesDir, "qa").apply { mkdirs() }.resolve("pic.jpg").apply { writeBytes(ByteArray(2000) { (it % 200).toByte() }) }
        dispatch("""{"op":"post","body":"with photo","photo_path":"${photo.absolutePath}"}""")
        val refs = env.social.authored.last().media
        assertEquals(1, refs.size)
        assertTrue(refs[0].startsWith("img_"))
        assertTrue(LocalMedia.has(refs[0]))
    }

    @Test fun the_file_op_stores_the_bytes_and_posts_them() {
        File(env.ctx.filesDir, "qa").apply { mkdirs() }.resolve("doc.bin").writeBytes(ByteArray(500) { 3 })
        dispatch("""{"op":"file","file_path":"doc.bin","body":"a file"}""")
        assertTrue(env.social.authored.last().media.single().startsWith("file_"))
        dispatch("""{"op":"file","file_path":"missing.bin"}""")
        assertEquals("a missing file posts nothing", 1, env.social.authored.size)
    }

    @Test fun a_video_request_with_no_video_path_is_skipped_rather_than_faked() {
        dispatch("""{"op":"post","body":"v","media":"video"}""")
        assertTrue(env.social.authored.last().media.isEmpty())
    }

    @Test fun a_dm_op_opens_the_thread_and_sends_to_a_known_contact_only() {
        dispatch("""{"op":"dm","dm_to":"${peer.uppercase()}","body":"hi pat"}""")
        assertEquals("hi pat", env.social.authored.last().body)
        assertEquals(HavenNet.dmCircleId(peer), env.social.authored.last().circleId)
        val before = env.social.authored.size
        dispatch("""{"op":"dm","dm_to":"${"e5".repeat(32)}","body":"nobody"}""")
        dispatch("""{"op":"dm","dm_to":"short","body":"nobody"}""")
        assertEquals(before, env.social.authored.size)
    }

    @Test fun react_and_comment_find_the_circle_that_holds_the_target() {
        env.social.feeds["default"] = listOf(
            FeedItemFfi("p7", "aaaaaaaa", false, 1uL, "hi", emptyList(), null, false, false, false, false, emptyList(), emptyList(), null))
        dispatch("""{"op":"react","target_id":"p7","emoji":"🔥"}""")
        assertEquals("react", env.social.authored.last().verb)
        assertEquals("🔥", env.social.authored.last().body)
        dispatch("""{"op":"react","target_id":"p7"}""")
        assertEquals("the default reaction", "❤️", env.social.authored.last().body)
        dispatch("""{"op":"comment","target_id":"p7","body":"nice"}""")
        assertEquals("comment", env.social.authored.last().verb)
        val n = env.social.authored.size
        dispatch("""{"op":"react","target_id":"nowhere"}""")
        dispatch("""{"op":"comment","target_id":"","body":"x"}""")
        assertEquals("no circle holds it: nothing authored", n, env.social.authored.size)
    }

    @Test fun music_post_builds_a_track_from_the_link() {
        dispatch("""{"op":"music_post","music":{"url":"https://example.org/t","title":"Song","artist":"Band"}}""")
        val a = env.social.authored.last()
        assertEquals("https://example.org/t", a.music?.catalogId)
        assertEquals("Song", a.music?.title)
        dispatch("""{"op":"music_post"}""")
        assertEquals("qa://track", env.social.authored.last().music?.catalogId)
    }

    @Test fun circle_ops_create_a_circle_and_invite_a_member() {
        env.social.ownedCircleId = "c1qa"
        dispatch("""{"op":"circle_create","name":"QA Friends"}""")
        assertTrue(env.social.calls.contains("createOwned QA Friends"))
        assertEquals("c1qa", HavenNet.activeCircle.value)
        dispatch("""{"op":"circle_create"}""")
        assertTrue(env.social.calls.contains("createOwned QA Circle"))
        dispatch("""{"op":"circle_invite","dm_to":"$peer"}""")
        assertTrue(env.social.calls.any { it.startsWith("add c1qa $peer") })
        val n = env.social.calls.size
        dispatch("""{"op":"circle_invite","dm_to":"bad"}""")
        assertEquals(n, env.social.calls.size)
        HavenNet.setActiveCircle("default")
    }

    @Test fun the_profile_op_saves_the_name_through_the_ui_path() {
        dispatch("""{"op":"profile","name":"  QA Name  "}""")
        assertEquals("QA Name", ProfileStore.get(env.ctx).displayName)
    }

    @Test fun wiring_a_relay_adopts_it_as_the_default_with_its_http_interface() {
        val hex = "9a".repeat(32)
        dispatch("""{"op":"wire_relay","hex":"$hex","urls":["http://relay.test:1"],"token":"tok","derp":"https://derp.test/"}""")
        val e = env.entries().getValue(hex)
        assertEquals(listOf("http://relay.test:1"), e.httpUrls)
        assertEquals("tok", e.httpToken)
        assertEquals("https://derp.test", e.derpUrl)
        assertEquals(hex, HavenNet.defaultRelay())
        val n = env.entries().size
        dispatch("""{"op":"wire_relay","hex":"short","urls":[]}""")
        assertEquals(n, env.entries().size)
    }

    @Test fun the_relay_link_op_is_remembered_for_the_dump() {
        dispatch("""{"op":"relay_link"}""")
        assertNotNull(driver.getDeclaredField("qaRelayLink").apply { isAccessible = true }.get(QaDriver))
    }

    @Test fun heavy_work_can_be_forced_and_lifted_and_perf_counters_zeroed() {
        dispatch("""{"op":"heavy_work_override","suspend":true,"reason":"qa-test"}""")
        assertTrue(HeavyWorkMonitor.current.suspendHeavyIO)
        dispatch("""{"op":"heavy_work_override","suspend":false}""")
        assertFalse(HeavyWorkMonitor.current.suspendHeavyIO)
        QaPerf.noteInboundChange("x")
        dispatch("""{"op":"perf_reset"}""")
        dispatch("""{"op":"dump"}""")
        dispatch("""{"op":"nonsense"}""")
        dispatch("""{"op":"mark_read"}""")
    }

    @Test fun the_call_ops_drive_the_call_manager_on_the_call_thread() {
        dispatch("""{"op":"call_speaker","on":false}""")
        assertTrue("nothing happens until the call thread runs it", CallManager.speakerOn.value)
        drainCallThread()
        assertFalse(CallManager.speakerOn.value)
        dispatch("""{"op":"call_speaker","on":false}""")   // already there: no toggle
        dispatch("""{"op":"call_route_legacy","on":true}""")
        drainCallThread()
        assertTrue(CallManager.qaForceLegacyRoute)
        dispatch("""{"op":"call_route_legacy","on":false}""")
        dispatch("""{"op":"call_accept"}""")   // nothing ringing: ignored
        dispatch("""{"op":"call","dm_to":"short"}""")
        dispatch("""{"op":"call_end"}""")
        drainCallThread()
        assertFalse(CallManager.qaForceLegacyRoute)
        assertTrue("ending a call hands the speaker default back", CallManager.speakerOn.value)
    }

    @Test fun the_screen_share_ops_reach_the_ui_through_the_main_handler() {
        val before = QaDriver.screenShareAsk.intValue
        dispatch("""{"op":"screen_share","on":true}""")
        dispatch("""{"op":"screen_perturb","on":true}""")
        val h = driver.getDeclaredField("handler").apply { isAccessible = true }.get(QaDriver)
        h.javaClass.getMethod("drain").invoke(h)
        assertEquals(before + 1, QaDriver.screenShareAsk.intValue)
        assertTrue(QaDriver.screenPerturb.value)
        dispatch("""{"op":"screen_perturb","on":false}""")
        dispatch("""{"op":"screen_share","on":false}""")
        h.javaClass.getMethod("drain").invoke(h)
        assertFalse(QaDriver.screenPerturb.value)
    }

    @Test fun approving_connections_with_none_pending_is_a_no_op() {
        dispatch("""{"op":"approve_connections"}""")
    }

    @Test fun the_identity_files_name_the_account_and_device() {
        driver.getDeclaredMethod("writeIdentity").apply { isAccessible = true }.invoke(QaDriver)
        val txt = File(env.ctx.filesDir, "qa/qa-device-hex.txt").readText().trim().lines()
        assertEquals(listOf(env.me, env.device), txt)
    }

    @Test fun the_haven_qa_link_pokes_the_consumer_and_other_links_are_not_ours() {
        assertTrue(QaDriver.handleUrl("haven://qa"))
        assertFalse(QaDriver.handleUrl("haven://post/abc"))
        assertFalse(QaDriver.handleUrl("https://qa"))
        assertFalse(QaDriver.handleUrl(null))
    }

    @Test fun the_poll_arms_on_resume_and_stops_on_pause() {
        QaDriver.onResume()
        assertTrue(driver.getDeclaredField("polling").apply { isAccessible = true }.getBoolean(QaDriver))
        QaDriver.onPause()
        assertFalse(driver.getDeclaredField("polling").apply { isAccessible = true }.getBoolean(QaDriver))
    }

    @Test fun a_staged_seed_is_only_ever_offered_to_an_install_that_has_no_identity() {
        val dir = File(env.ctx.filesDir, "qa").apply { mkdirs() }
        val seedFile = File(dir, "qa-seed.txt")
        QaDriver.adoptSeedIfPresent(env.ctx)                                   // nothing staged
        seedFile.writeText("not a seed")
        QaDriver.adoptSeedIfPresent(env.ctx)                                   // wrong shape: ignored
        assertTrue("the staged file is the harness's to manage", seedFile.exists())
    }
}
