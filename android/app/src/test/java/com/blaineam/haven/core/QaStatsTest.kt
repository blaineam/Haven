package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The QA counters that e2e's `relayfirst` / `screenshare` steps score against. */
class QaStatsTest {
    // QaStats is a process-wide singleton, so every test uses its own keys / event ids.

    @Test fun bump_accumulates_and_count_defaults_to_zero() {
        assertEquals(0L, QaStats.count("t_bump_unseen"))
        QaStats.bump("t_bump"); QaStats.bump("t_bump", 4)
        assertEquals(5L, QaStats.count("t_bump"))
    }

    @Test fun declined_counts_and_remembers_the_last_reason() {
        val before = QaStats.count("serve_declined")
        QaStats.declined("not a friend"); QaStats.declined("paused")
        assertEquals(before + 2, QaStats.count("serve_declined"))
        assertEquals("paused", QaStats.relayFirst(emptyList()).getString("last_decline"))
    }

    @Test fun relay_first_flags_a_broadcast_that_beat_its_media_enqueue() {
        QaStats.broadcast("evt-early")                       // broadcast first...
        QaStats.authoredEnqueued(listOf("ref-early"))        // ...media enqueued after: a violation
        QaStats.authoredEnqueued(listOf("ref-ok"))           // enqueued first...
        QaStats.broadcast("evt-ok")                          // ...then broadcast: correct order
        val before = QaStats.relayFirst(emptyList())
        val o = QaStats.relayFirst(listOf(
            "evt-early" to listOf("ref-early"),
            "evt-ok" to listOf("ref-ok"),
            "evt-text-only" to emptyList(),                   // no media: not checked
            "evt-never-broadcast" to listOf("ref-x"),         // not broadcast this launch: skipped
        ))
        assertEquals(0, before.getInt("authored_media_posts_checked"))
        assertEquals(2, o.getInt("authored_media_posts_checked"))
        assertEquals(1, o.getInt("broadcast_before_enqueue"))
    }

    @Test fun first_enqueue_and_first_broadcast_win() {
        QaStats.authoredEnqueued(listOf("ref-first"))
        QaStats.broadcast("evt-first")
        QaStats.authoredEnqueued(listOf("ref-first"))        // re-enqueue must not move the stamp
        QaStats.broadcast("evt-first")
        QaStats.broadcast(null); QaStats.broadcast("")        // ignored
        val o = QaStats.relayFirst(listOf("evt-first" to listOf("ref-first")))
        assertEquals(0, o.getInt("broadcast_before_enqueue"))
    }

    @Test fun direct_serves_are_tallied_by_role_and_why_and_recent_is_capped() {
        repeat(25) { QaStats.directServe("ref-$it-0123456789abcdef-long", "photo", "no_hint") }
        QaStats.directServe("v", "video", "hint_expired")
        val o = QaStats.relayFirst(emptyList())
        assertTrue(o.getJSONObject("served_direct_friend_by_role").getLong("photo") >= 25)
        assertEquals(1L, o.getJSONObject("served_direct_friend_by_role").getLong("video"))
        assertTrue(o.getJSONObject("served_direct_friend_by_why").has("hint_expired"))
        val recent = o.getJSONArray("served_direct_friend_recent")
        assertEquals(20, recent.length())
        assertEquals("video", recent.getJSONObject(19).getString("role"))
        assertTrue(recent.getJSONObject(0).getString("ref").length <= 16)
    }

    @Test fun relay_first_always_reports_the_fixed_counter_set_and_heavy_work_state() {
        val o = QaStats.relayFirst(emptyList())
        for (k in listOf("served_direct_friend", "relay_hints_sent", "received_via_relay", "pending_enrollment_refusals"))
            assertTrue(k, o.has(k))
        assertTrue(o.getJSONObject("heavy_work").has("suspended"))
    }

    @Test fun encoder_log_keeps_the_latest_sixteen() {
        repeat(20) { QaStats.noteEncoder("enc$it") }
        val e = QaStats.encoders()
        assertEquals(16, e.size)
        assertEquals("enc19", e.last())
        assertFalse("enc0" in e)
    }

    @Test fun reset_share_counts_attempts_and_clears_the_previous_evidence() {
        QaStats.shareFgsReady = true; QaStats.shareCaptureW = 1080; QaStats.shareStartError = "boom"
        val n = QaStats.shareAttempts
        QaStats.resetShare()
        assertEquals(n + 1, QaStats.shareAttempts)
        assertEquals(null, QaStats.shareFgsReady)
        assertEquals(0, QaStats.shareCaptureW)
        assertEquals("", QaStats.shareStartError)
        assertEquals(-1L, QaStats.shareFgsWaitMs)
    }
}
