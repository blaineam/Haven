package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections

class SetSnapshotTest {
    /** Records whether the copy iterated while holding the set's own monitor. */
    private class LockProbe : AbstractMutableSet<String>() {
        private val backing = HashSet<String>()
        var iteratedHoldingLock: Boolean? = null
        override val size get() = backing.size
        override fun add(element: String) = backing.add(element)
        override fun iterator(): MutableIterator<String> {
            iteratedHoldingLock = Thread.holdsLock(this)
            return backing.iterator()
        }
    }

    @Test fun theCopyIsTakenUnderTheSetsOwnLock() {
        val probe = LockProbe().apply { add("a"); add("b") }
        val copy = snapshotOf(probe)
        assertEquals(setOf("a", "b"), copy)
        assertEquals(true, probe.iteratedHoldingLock)
    }

    @Test fun anUnlockedCopyIsWhatTheOldCodeDid() {
        // Documents the defect this guards: HashSet(set) iterates without the monitor.
        val probe = LockProbe().apply { add("a") }
        HashSet(probe)
        assertFalse(probe.iteratedHoldingLock!!)
    }

    @Test fun theCopyIsIndependentOfLaterWrites() {
        val live = Collections.synchronizedSet(HashSet<String>().apply { add("x") })
        val copy = snapshotOf(live)
        live.add("y")
        assertEquals(setOf("x"), copy)
        assertTrue(live.contains("y"))
    }
}
