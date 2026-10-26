package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** A local remove/re-add always beats the previous decision, even inside one clock millisecond. */
class ContactRemovalsOrderingTest {
    private lateinit var ctx: FakeContext
    private val hex = "dd".repeat(32)

    @Before fun setUp() { ctx = FakeContext(); ContactRemovals.init(ctx); ContactRemovals.clear() }
    @After fun tearDown() { ContactRemovals.clear(); ctx.filesDir.deleteRecursively() }

    @Test fun a_remove_right_after_a_readd_always_wins() {
        repeat(5_000) {
            ContactRemovals.markReadded(hex); ContactRemovals.markRemoved(hex)
            assertTrue("iteration $it", ContactRemovals.isRemoved(hex))
        }
    }

    @Test fun a_readd_right_after_a_remove_always_wins() {
        repeat(5_000) {
            ContactRemovals.markRemoved(hex); ContactRemovals.markReadded(hex)
            assertFalse("iteration $it", ContactRemovals.isRemoved(hex))
        }
    }
}
