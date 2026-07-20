package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.blaineam.haven.core.EditCarry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.haven_ffi.Account
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.TrackRefFfi

/**
 * Editing an item's TEXT must not delete its attachments — for the author or for anyone else.
 *
 * This is the guard on a real data-loss bug: `HavenNet.editPost` defaulted media to `emptyList()`,
 * music to `null` and muteVideo to `false`, and the DM editor called the short form. Because an
 * Edit event RESTATES an item rather than patching it (`core/haven-p2p/src/social.rs`,
 * `EventKind::Edit` assigns all four fields), fixing a typo in a message deleted its photo and its
 * song — not only locally, but on every device that ingested the edit, with nothing to restore
 * from.
 *
 * So these run two identities against the real core, and assert on the RECIPIENT's feed. That is
 * the half that matters and the half a local-only test would miss: the author's own copy and the
 * member's copy are both rebuilt from the same event, so if the event is lossy, everyone loses it.
 *
 * [anEditBuiltTheOldWayWipesThemForEveryone] is the negative control — it pins the reducer
 * behaviour that makes the rest of this necessary, so that if Edit ever becomes a real patch, the
 * test that says "you must carry attachments forward" fails loudly instead of quietly overstaying.
 */
@RunWith(AndroidJUnit4::class)
class EditCarryInstrumentedTest {

    private val photo = "blob-photo-1"
    private val video = "blob-video-2"
    private val track = TrackRefFfi(
        catalogId = "1440857781", title = "Motion Picture Soundtrack",
        artist = "Radiohead", artworkUrl = "https://example.invalid/art.jpg", durationMs = 428_000UL,
    )

    /** Alice and Bob in a circle, with Alice's post carrying a photo, a muted video and a track. */
    private class Thread {
        val alice = Account.generate()
        val bob = Account.generate()
        val aliceSocial = HavenSocial(alice.secretSeed())
        val bobSocial = HavenSocial(bob.secretSeed())

        init {
            aliceSocial.addContactBundle("default", bobSocial.myBundle())
            bobSocial.addContactBundle("default", aliceSocial.myBundle())
        }

        /** Hand everything Alice has produced so far to Bob. */
        fun deliver() {
            for (env in aliceSocial.syncEnvelopes("default")) bobSocial.receive("default", env)
        }

        fun aliceFeed() = aliceSocial.feed("default", 9_000UL, null)
        fun bobSees(id: String) = bobSocial.feed("default", 9_000UL, null).firstOrNull { it.id == id }
    }

    private fun postWithEverything(t: Thread): String {
        t.aliceSocial.post(
            "default", "at the lake", listOf(photo, video), track,
            null, false, /* muteVideo = */ true, 1_000UL,
        )
        t.deliver()
        val mine = t.aliceFeed().first { it.body == "at the lake" }
        // Sanity: the fixture must actually carry what the test claims to protect, or every
        // assertion below is vacuously green.
        assertEquals(listOf(photo, video), mine.media)
        assertNotNull("fixture must attach a track", mine.music)
        assertTrue("fixture must attach a MUTED video", mine.muteVideo)
        return mine.id
    }

    // ---- The regression ----------------------------------------------------------------------

    @Test fun editingThePostTextKeepsItsPhotosTrackAndMuteFlagForTheRecipient() {
        val t = Thread()
        val id = postWithEverything(t)

        // Exactly what HavenNet.editPost now does: resolve what to restate off the item itself,
        // rather than trusting the editor to hand it back.
        val keep = EditCarry.forEvent(t.aliceFeed(), id)
        assertNotNull("the item must resolve, or editPost drops the edit", keep)
        t.aliceSocial.edit("default", id, "at the lake ☀️", keep!!.media, keep.music, keep.muteVideo, 2_000UL)
        t.deliver()

        val theirs = t.bobSees(id)
        assertNotNull("bob must still see the post", theirs)
        assertTrue("the text edit must land", theirs!!.edited)
        assertEquals("at the lake ☀️", theirs.body)
        // The three that used to vanish.
        assertEquals("editing the caption deleted the attachments for the recipient",
            listOf(photo, video), theirs.media)
        assertEquals("editing the caption deleted the attached track for the recipient",
            track.catalogId, theirs.music?.catalogId)
        assertTrue("editing the caption un-muted the video for the recipient", theirs.muteVideo)
    }

    @Test fun editingADmMessageKeepsItsAttachments() {
        // The path that was actually broken: a DM is a Post under a `dm:` circle, and the DM editor
        // called editPost with body only. Same circle machinery, so the same guard applies.
        val t = Thread()
        val id = postWithEverything(t)

        val keep = EditCarry.forEvent(t.aliceFeed(), id)!!
        t.aliceSocial.edit("default", id, "typo fixed", keep.media, keep.music, keep.muteVideo, 2_000UL)
        t.deliver()

        assertEquals(listOf(photo, video), t.bobSees(id)!!.media)
        assertEquals(track.catalogId, t.bobSees(id)!!.music?.catalogId)
    }

    @Test fun aTextEditOfAnItemWithNoAttachmentsIsStillJustATextEdit() {
        // The carry-forward must not invent attachments on the ordinary case.
        val t = Thread()
        t.aliceSocial.post("default", "no attachments", emptyList(), null, null, false, false, 1_000UL)
        t.deliver()
        val id = t.aliceFeed().first { it.body == "no attachments" }.id

        val keep = EditCarry.forEvent(t.aliceFeed(), id)!!
        assertTrue(keep.media.isEmpty()); assertNull(keep.music); assertFalse(keep.muteVideo)
        t.aliceSocial.edit("default", id, "still none", keep.media, keep.music, keep.muteVideo, 2_000UL)
        t.deliver()

        val theirs = t.bobSees(id)!!
        assertEquals("still none", theirs.body)
        assertTrue(theirs.media.isEmpty())
        assertNull(theirs.music)
    }

    @Test fun anUnknownEventResolvesToNullSoTheEditIsDroppedRatherThanWiping() {
        // editPost returns early on null. The alternative — falling back to "no attachments" —
        // is the bug itself, so this pins the failure direction.
        val t = Thread()
        postWithEverything(t)
        assertNull(EditCarry.forEvent(t.aliceFeed(), "not-an-event-id"))
    }

    // ---- Negative control: why the above has to exist -----------------------------------------

    @Test fun anEditBuiltTheOldWayWipesThemForEveryone() {
        val t = Thread()
        val id = postWithEverything(t)

        // The pre-fix call: HavenNet.editPost(circleId, postId, body) with the old defaults.
        t.aliceSocial.edit("default", id, "at the lake ☀️", emptyList(), null, false, 2_000UL)
        t.deliver()

        val theirs = t.bobSees(id)!!
        assertTrue("an Edit REPLACES rather than patches — if this now fails, the reducer merges " +
            "and EditCarry can be simplified away", theirs.media.isEmpty())
        assertNull(theirs.music)
        assertFalse(theirs.muteVideo)
    }
}
