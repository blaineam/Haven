package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PushPolicyTest {
    @Before fun setUp() { PushPolicy.reset() }
    @After fun tearDown() { PushPolicy.reset(); PushPolicy.now = { System.currentTimeMillis() } }

    @Test fun an_event_that_fits_the_worker_budget_is_inlined() {
        assertNotNull(PushPolicy.inline(ByteArray(2_000)))
    }

    @Test fun an_event_the_worker_would_drop_is_not_inlined() {
        assertNull(PushPolicy.inline(ByteArray(2_300)))
        assertNull(PushPolicy.inline(ByteArray(88_044)))
    }

    @Test fun the_inline_ceiling_matches_what_the_worker_accepts() {
        // push/worker.js drops an event once payload + event >= 3900 chars; we keep headroom for the banner.
        val src = java.io.File("../../push/worker.js").takeIf { it.exists() }?.readText()
            ?: java.io.File("../push/worker.js").takeIf { it.exists() }?.readText()
        if (src != null) assertTrue("worker budget moved — revisit PushPolicy.INLINE_MAX_B64", src.contains("< 3900"))
        assertTrue(PushPolicy.INLINE_MAX_B64 < 3900)
    }

    @Test fun a_burst_of_self_syncs_is_allowed_then_coalesced() {
        var t = 1_000L
        PushPolicy.now = { t }
        repeat(PushPolicy.SELF_SYNC_BURST) { assertTrue(PushPolicy.allowSelfSync()) }
        assertFalse("a catch-up stream is left to the mailbox poll", PushPolicy.allowSelfSync())
        t += PushPolicy.SELF_SYNC_WINDOW_MS
        assertTrue("the window slid", PushPolicy.allowSelfSync())
    }
}
