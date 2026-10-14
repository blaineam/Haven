package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi

/**
 * What happens AFTER the engine accepts something I authored: persist, hand it to the relay mailbox with retry until
 * it lands, wake the members' push tokens and my own other devices, and keep the composer pill's progress honest.
 */
class HavenNetAuthorFlowTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)

    @Before fun setUp() {
        env.up()
        CircleSettings.init(env.ctx)
        HiddenStore.init(env.ctx)
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u))
        env.social.members["default"] = listOf(peer)
        env.social.authoredId = "post-1"
        HavenNet.contacts.add(Contact(peer, "Pat", "v"))
    }
    @After fun tearDown() { env.down() }

    private fun until(cond: () -> Boolean) = runBlocking { withTimeout(15_000) { while (!cond()) yield() } }
    private fun landed(envelope: ByteArray) = env.relay.store.containsKey(HavenKeys.mailboxKey("default", envelope))
    private fun pushes() = env.relay.hits.filter { it.method == "POST" && it.path == "/notify" }.map { JSONObject(String(it.body)) }
    private val stateFile get() = java.io.File(env.ctx.filesDir, "haven_social_state_${env.me}.bin")

    @Test fun a_post_is_saved_uploaded_to_the_relay_and_pushed_to_members_and_my_other_devices() {
        env.social.authorOk = "ENV-post".toByteArray()
        env.social.exported = byteArrayOf(4, 2)
        HavenNet.post("default", "hello circle")
        assertEquals("post", env.social.authored.single().verb)
        assertEquals("hello circle", env.social.authored.single().body)
        assertArrayEquals("the engine state is saved before anything leaves the device", byteArrayOf(4, 2), stateFile.readBytes())
        until { landed("ENV-post".toByteArray()) }
        until { pushes().any { it.optString("nodeId") == peer } && pushes().any { it.optString("nodeId") == env.me } }
        val own = pushes().first { it.optString("nodeId") == env.me }
        assertTrue("a silent wake for my own pocketed devices", own.optBoolean("silent"))
        assertEquals(java.util.Base64.getEncoder().encodeToString("ENV-post".toByteArray()), own.optString("event").replace("\n", ""))
    }

    @Test fun the_epoch_head_rides_along_with_the_event() {
        env.social.authorOk = "ENV-head".toByteArray()
        env.social.epochHeads["default"] = listOf("HEAD-1".toByteArray())
        HavenNet.post("default", "with a head")
        until { landed("ENV-head".toByteArray()) && landed("HEAD-1".toByteArray()) }
    }

    @Test fun a_blank_post_is_never_authored_and_a_refused_one_goes_nowhere() {
        HavenNet.post("default", "   ")
        assertTrue(env.social.authored.isEmpty())
        HavenNet.post("default", "refused by the engine")   // authorOk unset: the engine throws
        assertTrue(env.relay.hits.none { it.method == "PUT" })
    }

    @Test fun while_no_relay_takes_the_event_the_composer_pill_stays_pending() {
        env.social.authorOk = "ENV-stuck".toByteArray()
        env.relay.forceStatus = 500
        HavenNet.post("default", "will retry")
        until { HavenNet.authoredUploads.value.pending("default") >= 1 }
        assertEquals("still waiting on a mailbox, not silently dropped", 1, HavenNet.authoredUploads.value.pending("default"))
        assertFalse(landed("ENV-stuck".toByteArray()))
    }

    @Test fun every_author_verb_hands_its_envelope_to_the_relay() {
        val cases = listOf<Pair<String, () -> Unit>>(
            "ENV-react" to { HavenNet.react("default", "p1", "👍") },
            "ENV-unreact" to { HavenNet.unreact("default", "p1", "👍") },
            "ENV-comment" to { HavenNet.comment("default", "p1", "nice") },
            "ENV-edit" to { HavenNet.editPostFull("default", "p1", "edited", emptyList(), null, false) },
            "ENV-unsend" to { HavenNet.unsendPost("default", "p1") },
            "ENV-story" to { HavenNet.postStory("a story", null) },
        )
        for ((name, act) in cases) {
            env.social.authorOk = name.toByteArray()
            act()
            until { landed(name.toByteArray()) }
        }
        assertEquals(listOf("react", "unreact", "comment", "edit", "unsend", "story"), env.social.authored.map { it.verb })
    }

    @Test fun a_blank_comment_or_story_is_ignored() {
        env.social.authorOk = "x".toByteArray()
        HavenNet.comment("default", "p1", "")
        HavenNet.postStory("", null)
        assertTrue(env.social.authored.isEmpty())
    }

    @Test fun an_imported_post_is_authored_silently_with_its_original_date() {
        env.social.authorOk = "ENV-import".toByteArray()
        HavenNet.postImported("default", "from 2019", createdAt = 1_560_000_000_000uL)
        assertEquals("post", env.social.authored.single().verb)
        until { landed("ENV-import".toByteArray()) }
        until { pushes().isNotEmpty() }
        assertTrue("no banner for a back-catalogue: every wake is bannerless", pushes().all { it.optBoolean("silent") })
    }

    @Test fun a_blank_import_is_ignored() {
        HavenNet.postImported("default", " ", createdAt = 1uL)
        assertTrue(env.social.authored.isEmpty())
    }

    @Test fun a_report_hides_the_post_locally_and_broadcasts() {
        env.social.authorOk = "ENV-report".toByteArray()
        assertNull("the author could not be resolved from the log", HavenNet.report("default", "qa-report-target", "spam", "ad"))
        assertTrue(HiddenStore.isHidden("qa-report-target"))
        until { landed("ENV-report".toByteArray()) }
    }

    @Test fun a_dm_goes_out_like_a_post_and_replying_to_a_story_opens_the_thread_first() {
        env.social.authorOk = "ENV-dm".toByteArray()
        val dm = HavenNet.dmCircleId(peer)
        val dmEnv = "ENV-dm".toByteArray()
        HavenNet.sendDm(dm, "hi there")
        assertEquals("hi there", env.social.authored.single().body)
        until { env.relay.store.containsKey(HavenKeys.mailboxKey(dm, dmEnv)) }
        env.social.authored.clear()
        val opened = HavenNet.replyToStory(peer.take(8), null, "love it", storyPostId = "s1")
        assertEquals(dm, opened)
        assertTrue(env.social.authored.single().body.startsWith("love it"))
        assertNull("not a contact: no thread", HavenNet.replyToStory("eeeeeeee", null, "x"))
    }

    @Test fun messaging_an_author_about_a_post_stages_a_draft_and_sends_nothing() {
        val dm = HavenNet.messageAuthor(peer.take(8), "default", "p1")
        assertEquals(HavenNet.dmCircleId(peer), dm)
        assertEquals(dm, DmDrafts.openThread.value)
        assertTrue(env.social.authored.isEmpty())
        assertNull(HavenNet.messageAuthor("eeeeeeee", "default", "p1"))
    }
}
