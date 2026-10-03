package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Load history from your relays" (RelayHistory.kt) — Apple RelayHistoryProgressTests parity. */
class RelayHistoryProgressTest {
    @Test fun fractionIsMonotonicAndEmptyPhasesDoNotStall() {
        var p = RelayHistoryProgress(phase = RelayHistoryProgress.Phase.SCANNING, circlesTotal = 4)
        var last = p.fraction
        for (d in 1..4) { p = p.copy(circlesDone = d); assertTrue(p.fraction >= last); last = p.fraction }
        p = p.copy(phase = RelayHistoryProgress.Phase.RETRYING); assertTrue(p.fraction >= last); last = p.fraction
        p = p.copy(phase = RelayHistoryProgress.Phase.MEDIA); assertEquals(1f, p.fraction, 0.0001f)
        p = p.copy(mediaTotal = 10, mediaDone = 5); assertTrue(p.fraction in 0.6f..0.99f)
        assertEquals(1f, p.copy(phase = RelayHistoryProgress.Phase.DONE).fraction, 0f)
    }

    @Test fun outcomes() {
        val done = RelayHistoryProgress(phase = RelayHistoryProgress.Phase.DONE, circlesTotal = 2)
        assertEquals(RelayHistoryProgress.Outcome.UpToDate, done.outcome)
        assertEquals(RelayHistoryProgress.Outcome.Added(312, 1204), done.copy(postsAdded = 312, mediaDone = 1204).outcome)
        assertEquals(RelayHistoryProgress.Outcome.Unreachable, done.copy(relayErrors = 2).outcome)
        assertEquals(RelayHistoryProgress.Outcome.UpToDate, done.copy(relayErrors = 1).outcome)
        assertTrue(done.showsRetentionCaveat)
        assertFalse(done.copy(phase = RelayHistoryProgress.Phase.CANCELLED).showsRetentionCaveat)
        assertFalse(RelayHistoryProgress().running)
        assertTrue(RelayHistoryProgress(phase = RelayHistoryProgress.Phase.MEDIA).running)
    }

    @Test fun mergeDedupesAcrossRelaysInRelayOrder() {
        val m = RelayHistoryPlan.merge(listOf("r1" to listOf("a", "b"), "r2" to listOf("b", "c"), "r2" to listOf("b")))
        assertEquals(listOf("a", "b", "c"), m.map { it.first })
        assertEquals(listOf(listOf("r1"), listOf("r1", "r2"), listOf("r2")), m.map { it.second })
    }

    @Test fun wantedMediaRules() {
        val refs = listOf("full1", "thumb1", "geo:1,2", "held", "gone", "full1")
        val small = setOf("thumb1")
        val w = { constrained: Boolean ->
            RelayHistoryPlan.wanted(refs, small, { it == "held" }, { it == "gone" }, { it.startsWith("geo:") }, constrained)
        }
        assertEquals(listOf("full1", "thumb1"), w(false))
        assertEquals(listOf("thumb1"), w(true))
    }

    /** The e2e bug: a recovered photo post whose photo the ordinary ingest path had already fetched
     *  was never counted ("Added 2 posts and 0 photos and videos"). */
    @Test fun landedCountsRecoveredMediaAnotherPathAlreadyFetched() {
        val before = setOf("old", "gone")
        val onDisk = setOf("old", "new", "new.t")
        val refs = listOf("old", "gone", "new", "new.t", "new", "geo:1")
        val small = setOf("new.t")
        val l = { constrained: Boolean ->
            RelayHistoryPlan.landed(refs, small, before, { it in onDisk }, { it.startsWith("geo:") }, constrained)
        }
        assertEquals(listOf("new", "new.t"), l(false))
        assertEquals(listOf("new.t"), l(true))
        val wanted = RelayHistoryPlan.wanted(refs, small, { it in onDisk }, { false }, { it.startsWith("geo:") }, false)
        assertEquals(listOf("gone"), wanted)
        assertTrue(l(false).none { it in wanted })
        val p = RelayHistoryProgress(phase = RelayHistoryProgress.Phase.DONE, postsAdded = 2,
            mediaTotal = l(false).size + wanted.size, mediaDone = l(false).size)
        assertEquals(RelayHistoryProgress.Outcome.Added(2, 2), p.outcome)
        assertTrue(p.copy(phase = RelayHistoryProgress.Phase.MEDIA).fraction <= 1f)
    }
}
