package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class CloseOnceTest {
    @Test
    fun teardownAndAnIceCallbackClosingTheSamePeerDisposeItOnce() {
        repeat(200) {
            val once = CloseOnce()
            val disposed = AtomicInteger(0)
            val go = CountDownLatch(1)
            // hangup's teardown (QA/UI thread) and onPeerIceStateOnMain → dropPeer (main) race.
            val a = thread { go.await(); once.close { disposed.incrementAndGet() } }
            val b = thread { go.await(); once.close { disposed.incrementAndGet() } }
            go.countDown(); a.join(); b.join()
            assertEquals("a disposed PeerConnection must never be disposed again", 1, disposed.get())
            assertTrue(once.isClosed)
        }
    }

    @Test
    fun aSecondCloseIsANoOp() {
        val once = CloseOnce()
        assertTrue(once.close {})
        assertFalse(once.close { error("must not run") })
    }

    @Test
    fun everyCallOpRunsOnMain() {
        for (op in listOf("call", "call_accept", "call_end", "call_speaker", "CALL_END ")) {
            assertTrue(op, QaOpThreads.needsMain(op))
        }
        assertFalse(QaOpThreads.needsMain("dump"))
        assertFalse(QaOpThreads.needsMain("post"))
    }
}
