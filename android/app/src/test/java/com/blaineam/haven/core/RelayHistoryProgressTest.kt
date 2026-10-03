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

    /** The e2e: ONE recovered photo post — photo + thumb + preview, all already fetched by the
     *  ordinary ingest path — is one item, done ("Added 2 posts and 1 photo", never 0, never 3). */
    @Test fun oneRecoveredPhotoWithCompanionsIsOneItem() {
        val cands = RelayHistoryPlan.mediaCandidates("c", listOf("p", "thumb:p:pt", "preview:p:pv"))
        assertEquals(setOf("p"), cands.filter { ':' !in it.ref }.map { it.item }.toSet())
        val plan = { have: Set<String>, constrained: Boolean ->
            RelayHistoryPlan.mediaPlan(cands, emptySet(), constrained, { it in have }, { false }, { ':' in it })
        }
        val all = plan(setOf("p", "pt", "pv"), false)
        assertEquals(listOf(1, 1, 0), listOf(all.landed, all.total, all.want.size))
        val p = RelayHistoryProgress(phase = RelayHistoryProgress.Phase.DONE, postsAdded = 2, mediaDone = all.landed, mediaTotal = all.total)
        assertEquals(RelayHistoryProgress.Outcome.Added(2, 1), p.outcome)

        // Nothing on disk yet: three refs fetched small-first, the item counts once.
        val none = plan(emptySet(), false)
        assertEquals(listOf(0, 1), listOf(none.landed, none.total))
        assertEquals(listOf("pv", "pt", "p"), none.want.map { it.ref })
        val t = RelayHistoryMediaTally(none)
        assertEquals(1, none.want.sumOf { t.record(it.item, true).first })

        // Only the full-size landed by another path: done up front, its companions never re-count.
        val full = plan(setOf("p"), false)
        assertEquals(listOf(1, 1, 2), listOf(full.landed, full.total, full.want.size))
        assertEquals(0 to 0, RelayHistoryMediaTally(full).record("p", true))

        // Constrained: the companion alone is the item.
        val lean = plan(setOf("pt"), true)
        assertEquals(listOf(1, 1, 1), listOf(lean.landed, lean.total, lean.want.size))
    }

    @Test fun mediaPlanIgnoresOldMediaAndCountsMissingItemsOnce() {
        val cands = RelayHistoryPlan.mediaCandidates("c",
            listOf("a", "thumb:a:at", "b", "thumb:b:bt", "gone", "x", "thumb:x:xt", "geo:1,2"))
        val plan = RelayHistoryPlan.mediaPlan(cands, setOf("a", "at", "gone", "x", "xt"), false,
            { it in setOf("at", "b", "bt") }, { it == "gone" }, { ':' in it })
        assertEquals(1, plan.landed)
        assertEquals(3, plan.total)
        assertEquals(listOf("xt", "a", "x"), plan.want.map { it.ref })
        val t = RelayHistoryMediaTally(plan)
        assertEquals(0 to 0, t.record("x", false))
        assertEquals(1 to 0, t.record("a", true))
        assertEquals(0 to 1, t.record("x", false))
    }
}
