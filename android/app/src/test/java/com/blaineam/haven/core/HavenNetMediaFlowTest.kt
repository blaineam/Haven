package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.SignedCallFrame
import uniffi.haven_ffi.FeedItemFfi
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/**
 * Missing media end to end against an in-process relay: the sweep that asks for it, the serialized queue that fetches
 * it, the open that accepts or quarantines it, and the author-side frames (31/32) that put a swept blob back. Sealing
 * is faked as a visible prefix so what was opened, and for whom, can be asserted.
 */
@Suppress("UNCHECKED_CAST")
class HavenNetMediaFlowTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)
    private val plain = ByteArray(300) { (it * 7 % 251).toByte() }
    private lateinit var ref: String
    private val seal = "SEALED:".toByteArray()

    @Before fun setUp() {
        env.up()
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u))
        env.social.members["default"] = listOf(peer)
        env.social.sealMedia = { _, d -> seal + d }
        env.social.openMedia = { _, s -> if (s.size > seal.size && s.copyOf(seal.size).contentEquals(seal)) s.copyOfRange(seal.size, s.size) else null }
        env.social.sealCall = { _, _, d -> byteArrayOf(9) + d }
        HavenNet.contacts.add(Contact(peer, "Pat", "v"))
        ref = "img_" + java.security.MessageDigest.getInstance("SHA-256").digest(plain).joinToString("") { "%02x".format(it) }
    }
    @After fun tearDown() { env.down() }

    private fun post(media: List<String>, at: Long = System.currentTimeMillis(), mine: Boolean = false, author: String = peer.take(8)) =
        FeedItemFfi("p1", author, mine, at.toULong(), "hello", media, null, false, false, false, false, emptyList(), emptyList(), null)

    private fun sealedBlob() = seal + plain
    private fun lane() { (CallManager::class.java.getDeclaredField("sendLane").apply { isAccessible = true }.get(CallManager) as ExecutorService).submit {}.get(10, TimeUnit.SECONDS) }
    private fun sealedTypes() = env.social.sealedCalls.map { it.second.toInt() to it.first }
    private fun until(cond: () -> Boolean) = runBlocking { withTimeout(15_000) { while (!cond()) yield() } }

    // ---- fetch + accept -------------------------------------------------------------------------

    @Test fun a_blob_the_relay_holds_is_fetched_and_accepted_when_it_opens_for_a_circle() {
        env.relay.store["haven/media/$ref"] = sealedBlob()
        assertTrue(NetEnv.call("fetchAndAccept", "default", ref) as Boolean)
        assertTrue(LocalMedia.has(ref))
        assertArrayEquals(sealedBlob(), LocalMedia.rawSealed(ref))
        assertTrue("it was judged against the circles this device holds", env.social.openedMedia.contains("default"))
    }

    @Test fun a_blob_that_opens_for_no_circle_is_quarantined_and_the_author_is_asked_to_reseal() {
        env.social.openMedia = { _, _ -> null }
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        env.relay.store["haven/media/$ref"] = "garbage".toByteArray()
        assertFalse(NetEnv.call("fetchAndAccept", "default", ref) as Boolean)
        assertTrue("the bytes are kept: not opening is not proof they are bad", LocalMedia.has(ref))
        assertTrue((NetEnv.field("unopenableMedia").get(HavenNet) as Set<*>).contains(ref))
        lane()
        assertTrue("frame 31 to the post's author", sealedTypes().contains(Wire.MEDIA_WANTED to peer))
        assertTrue(MediaWantedStore.isWanted(ref))
    }

    @Test fun the_author_is_asked_once_per_cooldown_and_never_more_than_three_times() {
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        repeat(2) { NetEnv.call("askAuthorToReseal", ref, "default") }
        lane()
        assertEquals("the cooldown paces a second ask", 1, sealedTypes().count { it.first == Wire.MEDIA_WANTED })
        val asked = NetEnv.field("resealAskedAt").get(HavenNet) as MutableMap<*, *>
        repeat(5) { asked.clear(); NetEnv.call("askAuthorToReseal", ref, "default") }
        lane()
        assertEquals("a ref that never converges stops billing its author", 3, sealedTypes().count { it.first == Wire.MEDIA_WANTED })
    }

    @Test fun a_ref_no_post_references_cannot_be_asked_about() {
        NetEnv.call("askAuthorToReseal", ref, null)
        lane()
        assertTrue(env.social.sealedCalls.isEmpty())
    }

    @Test fun my_own_post_is_repaired_by_re_sealing_it_myself_not_by_asking() {
        env.social.feeds["default"] = listOf(post(listOf(ref), mine = true))
        NetEnv.call("askAuthorToReseal", ref, "default")
        lane()
        assertTrue(env.social.sealedCalls.isEmpty())
    }

    @Test fun a_comments_media_is_asked_of_the_comments_author() {
        val comment = uniffi.haven_ffi.FeedCommentFfi("c1", peer.take(8), false, 1uL, "hi", listOf(ref), false, false, emptyList())
        env.social.feeds["default"] = listOf(post(emptyList()).copy(comments = listOf(comment)))
        NetEnv.call("askAuthorToReseal", ref, "default")
        lane()
        assertTrue(sealedTypes().contains(Wire.MEDIA_WANTED to peer))
    }

    @Test fun a_tile_that_cannot_resolve_media_we_hold_asks_the_author_to_reseal() {
        assertTrue(LocalMedia.writeRawSealed(ref, sealedBlob()))
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        HavenNet.noteMediaUnreadable(ref, "default")
        until { env.social.sealedCalls.isNotEmpty() }
        lane()
        assertTrue(sealedTypes().contains(Wire.MEDIA_WANTED to peer))
    }

    @Test fun a_tile_for_media_we_do_not_hold_asks_nobody() {
        HavenNet.noteMediaUnreadable(ref, "default")
        lane()
        assertTrue(env.social.sealedCalls.isEmpty())
    }

    @Test fun asking_for_media_that_is_mine_with_no_copy_here_asks_my_other_devices() {
        val mine = HavenNet.nodeIdHex
        HavenNet.requestMediaWhenAvailable(ref, "default", "p1", mine.take(8))
        assertTrue(MediaWantedStore.isWanted(ref))
        assertTrue("never the stranger path", env.social.sealedCalls.isEmpty())
    }

    @Test fun asking_for_media_whose_author_cannot_be_resolved_does_nothing() {
        HavenNet.requestMediaWhenAvailable(ref, "default", "p1", "ffffffff")
        assertFalse(MediaWantedStore.isWanted(ref))
    }

    @Test fun a_manual_ask_is_remembered_as_one_a_person_made() {
        HavenNet.requestMediaWhenAvailable(ref, "default", "p1", peer.take(8), manual = true)
        assertTrue(MediaWantedStore.isManuallyWanted(ref))
        lane()
        assertTrue(sealedTypes().contains(Wire.MEDIA_WANTED to peer))
    }

    // ---- the sweep and the serialized queue -------------------------------------------------------

    @Test fun the_missing_media_sweep_fetches_a_posts_blob_through_the_queue() {
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        env.relay.store["haven/media/$ref"] = sealedBlob()
        HavenNet.requestMissingMedia()
        until { LocalMedia.has(ref) }
        assertArrayEquals(sealedBlob(), LocalMedia.rawSealed(ref))
    }

    @Test fun media_already_held_is_not_asked_for() {
        assertTrue(LocalMedia.writeRawSealed(ref, sealedBlob()))
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        HavenNet.requestMissingMedia()
        assertTrue(env.relay.hits.none { it.path.contains(ref) })
    }

    @Test fun backfilled_history_is_lazy_but_its_tiny_companions_are_not() {
        val thumbRef = "img_" + "ab".repeat(16)
        val old = System.currentTimeMillis() - 40L * 24 * 3600 * 1000
        env.social.feeds["default"] = listOf(post(listOf(ref, MediaVariants.thumbMarker(ref, thumbRef), thumbRef), at = old))
        env.relay.store["haven/media/$thumbRef"] = seal + byteArrayOf(1)
        val fetched = env.relay.latchForGet(thumbRef)
        HavenNet.requestMissingMedia()
        assertTrue("the thumb prefetches for every post", fetched.await(10, TimeUnit.SECONDS))
        assertTrue("the full photo of old history waits for a tap", env.relay.hits.none { it.path.contains("/k/haven/media/$ref") })
    }

    @Test fun a_sweep_before_the_engine_is_ready_does_nothing() {
        NetEnv.field("ready").setBoolean(HavenNet, false)
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        HavenNet.requestMissingMedia()
        assertTrue(env.relay.hits.isEmpty())
    }

    @Test fun downloading_an_evicted_blob_restarts_every_lane() {
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        env.relay.store["haven/media/$ref"] = sealedBlob()
        EvictedMediaStore.mark(ref, 300L)
        HavenNet.downloadEvicted(ref)
        assertFalse("the eviction is lifted by the explicit tap", EvictedMediaStore.contains(ref))
    }

    // ---- author side: a swept blob put back (frames 31/32) ---------------------------------------------

    private fun frame(from: String = peer, circle: String = "default", postId: String = "p1") {
        env.social.openCall = { _, _ -> SignedCallFrame(from, HavenKeys.mediaFrameBody(from, ref, circle, postId)) }
    }
    private fun wanted() = NetEnv.call("handleMediaWanted", byteArrayOf(1))
    private fun available() = NetEnv.call("handleMediaAvailable", byteArrayOf(1))

    private fun hold() { LocalMedia.store("default", plain) }

    @Test fun a_friend_asking_for_media_i_hold_gets_it_re_sealed_back_on_a_relay_and_is_told() {
        hold()
        frame()
        wanted()
        lane()
        val onRelay = env.relay.store["haven/media/$ref"]
        assertNotNull("re-sealed afresh from the plaintext and uploaded", onRelay)
        assertTrue(sealedTypes().contains(Wire.MEDIA_AVAILABLE to peer))
    }

    @Test fun a_second_ask_soon_after_is_answered_without_paying_for_another_upload() {
        hold(); frame()
        wanted(); lane()
        env.relay.hits.clear(); env.social.sealedCalls.clear()
        wanted(); lane()
        assertTrue(env.relay.puts().isEmpty())
        assertTrue(sealedTypes().contains(Wire.MEDIA_AVAILABLE to peer))
    }

    @Test fun an_ask_for_media_i_do_not_hold_or_cannot_open_gets_no_answer() {
        frame()
        wanted(); lane()
        assertTrue("I don't hold it either", env.social.sealedCalls.isEmpty())
        assertTrue(LocalMedia.writeRawSealed(ref, "{\"sealed\":true}".toByteArray()))
        wanted(); lane()
        assertTrue("cannot re-seal what I cannot open", env.social.sealedCalls.isEmpty())
    }

    @Test fun an_ask_from_a_non_contact_or_a_non_member_or_for_a_failed_upload_is_not_served() {
        hold()
        frame(from = "e5".repeat(32))
        wanted(); lane()
        assertTrue("a stranger", env.social.sealedCalls.isEmpty())
        env.social.members["default"] = emptyList()
        frame()
        wanted(); lane()
        assertTrue("naming a circle is not belonging to it", env.social.sealedCalls.isEmpty())
        env.social.members["default"] = listOf(peer)
        env.relay.forceStatus = 500
        wanted(); lane()
        assertTrue("an upload that failed is not announced as back", env.social.sealedCalls.none { it.second.toInt() == Wire.MEDIA_AVAILABLE })
    }

    @Test fun a_duplicate_ask_while_the_re_upload_is_in_flight_is_dropped() {
        hold(); frame()
        (NetEnv.field("mediaServing").get(HavenNet) as MutableSet<String>).add(ref)
        wanted(); lane()
        assertTrue(env.relay.puts().isEmpty())
    }

    @Test fun an_unopenable_media_frame_is_ignored() {
        env.social.openCall = null
        wanted(); available(); lane()
        assertTrue(env.social.sealedCalls.isEmpty())
    }

    @Test fun media_i_asked_about_coming_back_is_fetched_and_a_silent_repair_stays_silent() {
        MediaWantedStore.add(ref)
        env.social.feeds["default"] = listOf(post(listOf(ref)))
        frame()
        available()
        assertFalse("the wanted flag is consumed", MediaWantedStore.isWanted(ref))
    }

    @Test fun an_unsolicited_announce_from_the_author_prefetches_the_media_once() {
        frame()
        env.relay.store["haven/media/$ref"] = sealedBlob()
        val fetched = env.relay.latchForGet(ref)
        available()
        assertTrue(fetched.await(10, TimeUnit.SECONDS))
        available()   // the 60 s throttle: the same ref is not re-queued
    }

    @Test fun an_announce_for_media_already_held_or_from_a_stranger_changes_nothing() {
        hold()
        frame()
        available()
        frame(from = "e5".repeat(32))
        available()
        assertTrue(env.relay.hits.none { it.path.contains("/k/haven/media/") })
    }

    // ---- ledger ----------------------------------------------------------------------------------------

    @Test fun the_backup_ledger_answers_where_a_blob_is_confirmed() {
        hold()
        assertTrue(runBlocking { HavenNet.uploadMedia("default", ref) })
        assertTrue(HavenNet.isMediaBackedUpAny(ref))
        assertEquals(listOf(env.relayHex), HavenNet.mediaBackupDestinations(ref))
        assertTrue(HavenNet.isMediaBackedUpRemote(ref, ownRelayHex = "00".repeat(32)))
        assertFalse("our own hosted relay does not count as safe", HavenNet.isMediaBackedUpRemote(ref, ownRelayHex = env.relayHex))
        assertTrue(HavenNet.circleHasRelay("default"))
        assertEquals(listOf(env.relayHex), HavenNet.circleRelayHexes("default"))
        assertEquals("r", HavenNet.relayName(env.relayHex))
        assertEquals("", HavenNet.relayName("12".repeat(32)))
        assertEquals("", HavenNet.ownHostedRelayHex())
    }

    @Test fun a_tile_that_comes_on_screen_without_its_bytes_fetches_them_and_asks_only_once_a_minute() {
        env.relay.store["haven/media/$ref"] = sealedBlob()
        HavenNet.requestMediaOnView("default", ref)
        until { LocalMedia.has(ref) }
        env.relay.hits.clear()
        HavenNet.requestMediaOnView("default", ref)   // held now: nothing to ask for
        EvictedMediaStore.mark("img_" + "cd".repeat(32), 10L)
        HavenNet.requestMediaOnView("default", "img_" + "cd".repeat(32))   // deliberately evicted: its tile offers Download instead
        assertTrue(env.relay.hits.isEmpty())
    }

    // ---- held but unreadable ----------------------------------------------------------------------------

    @Test fun the_verify_sweep_probes_held_media_once_and_asks_the_author_to_reseal_what_will_not_open() {
        hold()
        val broken = "img_" + "bb".repeat(32)
        assertTrue(LocalMedia.writeRawSealed(broken, "{\"sealed\":\"junk\"}".toByteArray()))
        env.social.feeds["default"] = listOf(post(listOf(ref, broken)))
        NetEnv.call("verifyHeldMedia")
        lane()
        assertTrue("a readable blob is remembered as fine", (NetEnv.field("verifiedOpen").get(HavenNet) as Set<*>).contains(ref))
        assertTrue((NetEnv.field("probedThisSession").get(HavenNet) as Set<*>).containsAll(listOf(ref, broken)))
        assertTrue("and the unreadable one is repaired by its author", sealedTypes().contains(Wire.MEDIA_WANTED to peer))
        env.social.sealedCalls.clear()
        NetEnv.call("verifyHeldMedia")
        lane()
        assertTrue("each ref is probed at most once per session", env.social.sealedCalls.isEmpty())
    }

    @Test fun parked_media_is_re_opened_locally_when_a_key_arrives_and_lost_bytes_are_un_parked() {
        val parked = NetEnv.field("unopenableMedia").get(HavenNet) as MutableSet<String>
        hold()
        parked.add(ref)                                   // parked earlier, now readable
        val gone = "img_" + "dd".repeat(32)
        parked.add(gone)                                  // parked, and the bytes have since vanished
        NetEnv.call("retryParkedOpens")
        assertFalse(parked.contains(ref)); assertFalse(parked.contains(gone))
    }

    @Test fun my_own_authored_media_is_force_re_uploaded_once_and_the_recovery_latches() {
        hold()
        env.social.feeds["default"] = listOf(post(listOf(ref), mine = true))
        NetEnv.field("resealInFlight").setBoolean(HavenNet, false)
        NetEnv.call("maybeResealOwnMedia")
        val prefs = env.ctx.prefs("haven.crypto")
        until { prefs.getBoolean("mediaResealedV108", false) }
        assertNotNull(env.relay.store["haven/media/$ref"])
        assertTrue(prefs.getStringSet("mediaResealRefs", mutableSetOf<String>())!!.contains(ref))
        NetEnv.call("maybeResealOwnMedia")   // latched: never again
        assertEquals(1, prefs.getInt("mediaResealAttempts", 0))
    }
}
