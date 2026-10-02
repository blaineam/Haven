package com.blaineam.haven.core

import com.blaineam.haven.core.SeedlessLinkStarter.State
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The first-run seedless link used to boot the engine inline from the Link button — on main. The
 * starter must run boot+link on its worker, report BOOTING → SENT / INVALID_CODE / FAILED, allow a
 * retry after a failure, and never run two boots at once.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SeedlessLinkStarterTest {

    private fun TestScope.starter(link: (String) -> Boolean): SeedlessLinkStarter {
        val d = StandardTestDispatcher(testScheduler)
        return SeedlessLinkStarter(CoroutineScope(d), d, link)
    }

    @Test
    fun `a valid code goes booting then sent, with the trimmed text`() = kotlinx.coroutines.test.runTest {
        var got: String? = null
        val s = starter { got = it; true }
        assertEquals(State.IDLE, s.state.value)
        assertTrue(s.begin("  haven-enroll:abc \n"))
        assertEquals(State.BOOTING, s.state.value)
        advanceUntilIdle()
        assertEquals(State.SENT, s.state.value)
        assertEquals("haven-enroll:abc", got)
        s.reset()
        assertEquals(State.IDLE, s.state.value)
    }

    @Test
    fun `an unusable code is reported as invalid, not a failure`() = kotlinx.coroutines.test.runTest {
        val s = starter { false }
        s.begin("nope")
        advanceUntilIdle()
        assertEquals(State.INVALID_CODE, s.state.value)
    }

    @Test
    fun `a boot that throws fails, and a retry can succeed`() = kotlinx.coroutines.test.runTest {
        val calls = AtomicInteger()
        val s = starter { if (calls.incrementAndGet() == 1) error("engine construct failed") else true }
        s.begin("haven-enroll:x")
        advanceUntilIdle()
        assertEquals(State.FAILED, s.state.value)
        assertTrue("retry after a failure must be accepted", s.begin("haven-enroll:x"))
        advanceUntilIdle()
        assertEquals(State.SENT, s.state.value)
        assertEquals(2, calls.get())
    }

    @Test
    fun `only one boot is in flight at a time`() = kotlinx.coroutines.test.runTest {
        val calls = AtomicInteger()
        val s = starter { calls.incrementAndGet(); true }
        assertTrue(s.begin("haven-enroll:a"))
        assertFalse("a second tap while booting must be refused", s.begin("haven-enroll:a"))
        s.reset()   // reset must not clobber a boot in flight
        assertEquals(State.BOOTING, s.state.value)
        runCurrent()
        advanceUntilIdle()
        assertEquals(1, calls.get())
        assertEquals(State.SENT, s.state.value)
    }

    @Test
    fun `the link never runs on the calling thread, which stays free while it blocks`() = runBlocking {
        val main = Executors.newSingleThreadExecutor { Thread(it, "fake-main") }
        val worker = Executors.newSingleThreadExecutor { Thread(it, "fake-worker") }
        val mainScope = CoroutineScope(main.asCoroutineDispatcher())
        val release = CountDownLatch(1)
        var linkThread: String? = null
        val s = SeedlessLinkStarter(mainScope, worker.asCoroutineDispatcher()) {
            linkThread = Thread.currentThread().name
            release.await(10, TimeUnit.SECONDS)   // a slow boot
            true
        }
        try {
            main.submit { s.begin("haven-enroll:z") }.get()
            withTimeout(5_000) { s.state.first { it == State.BOOTING } }
            // While the "boot" is blocked, main still runs other work promptly (input, frames).
            val mainRan = main.submit<Boolean> { true }.get(2, TimeUnit.SECONDS)
            assertTrue(mainRan)
            release.countDown()
            withTimeout(5_000) { s.state.first { it == State.SENT } }
            // (Debug coroutine names are appended to the thread name: compare the prefix.)
            assertTrue("link ran on $linkThread", linkThread!!.startsWith("fake-worker"))
        } finally {
            release.countDown()
            mainScope.cancel()
            main.shutdownNow(); worker.shutdownNow()
        }
    }
}
