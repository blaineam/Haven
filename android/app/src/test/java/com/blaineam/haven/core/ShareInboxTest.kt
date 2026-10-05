package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Content shared into Haven from the system share sheet, waiting for the routing sheet. */
class ShareInboxTest {
    @After fun reset() { ShareInbox.clear(); DmDrafts.consumeOpenThread() }

    @Test fun `an empty share without a target is ignored`() {
        ShareInbox.offer(ShareInbox.Payload(text = "  "))
        assertNull(ShareInbox.pending)
    }

    @Test fun `a direct-share target alone is kept even with no content`() {
        ShareInbox.offer(ShareInbox.Payload(targetCircleId = "dm:abc"))
        assertEquals("dm:abc", ShareInbox.pending?.targetCircleId)
    }

    @Test fun `a second share before consumption merges instead of replacing`() {
        ShareInbox.offer(ShareInbox.Payload(text = "look", media = listOf("m1")))
        ShareInbox.offer(ShareInbox.Payload(text = "https://example.com", media = listOf("m2"), targetCircleId = "dm:x"))
        val p = ShareInbox.pending!!
        assertEquals("look\nhttps://example.com", p.text)
        assertEquals(listOf("m1", "m2"), p.media)
        assertEquals("dm:x", p.targetCircleId)
    }

    @Test fun `a later share without a target keeps the earlier target`() {
        ShareInbox.offer(ShareInbox.Payload(text = "a", targetCircleId = "dm:first"))
        ShareInbox.offer(ShareInbox.Payload(text = "b"))
        assertEquals("dm:first", ShareInbox.pending?.targetCircleId)
    }

    @Test fun `consume hands the share over exactly once`() {
        ShareInbox.offer(ShareInbox.Payload(media = listOf("m")))
        assertEquals(listOf("m"), ShareInbox.consume()?.media)
        assertNull(ShareInbox.consume())
        assertNull(ShareInbox.pending)
    }

    @Test fun `DM drafts are staged per thread and taken once`() {
        DmDrafts.stage("dm:a", "about your post: https://x/#p/c.p")
        DmDrafts.stage("", "ignored")
        DmDrafts.stage("dm:b", "   ")
        assertEquals("dm:a", DmDrafts.consumeOpenThread())
        assertNull(DmDrafts.consumeOpenThread())
        assertNull(DmDrafts.takeDraft("dm:b"))
        assertEquals("about your post: https://x/#p/c.p", DmDrafts.takeDraft("dm:a"))
        assertNull(DmDrafts.takeDraft("dm:a"))
    }
}
