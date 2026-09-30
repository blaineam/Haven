package com.blaineam.haven.core

import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The launch ANR (e2e 2026-09-30): RootScreen booted the engine ON MAIN while SyncWorker held
 * HavenNet.init's monitor, so main parked for 13.7 s and input dispatch timed out. [EngineBoot.offMain]
 * must keep a single-threaded "main" free to run other work while the boot waits on that lock.
 */
class EngineBootTest {

    @Test
    fun mainStaysResponsiveWhileBootWaitsOnAHeldInitLock() = runBlocking {
        val mainExec = Executors.newSingleThreadExecutor { r -> Thread(r, "fake-main") }
        val main = mainExec.asCoroutineDispatcher()
        val workerExec = Executors.newSingleThreadExecutor { r -> Thread(r, "fake-worker") }
        val worker = workerExec.asCoroutineDispatcher()
        val initLock = Any()
        val lockHeld = CountDownLatch(1)
        val release = CountDownLatch(1)
        // "SyncWorker": inside init, holding the monitor.
        val holder = Thread {
            synchronized(initLock) { lockHeld.countDown(); release.await(10, TimeUnit.SECONDS) }
        }.apply { start() }
        assertTrue(lockHeld.await(5, TimeUnit.SECONDS))
        try {
            val bootThread = CompletableDeferred<String>()
            val scope = CoroutineScope(main)
            // "RootScreen LaunchedEffect": boots via EngineBoot, then continues on main.
            val boot = scope.launch {
                EngineBoot.offMain(worker) { synchronized(initLock) { bootThread.complete(Thread.currentThread().name) } }
                assertEquals("fake-main", Thread.currentThread().name)
            }
            // A frame / input event posted to main while the boot is parked on the lock must run now.
            val frame = CompletableDeferred<Unit>()
            scope.launch { frame.complete(Unit) }
            withTimeout(2_000) { frame.await() }
            assertTrue("boot must still be waiting on the held lock", boot.isActive)
            release.countDown()
            withTimeout(5_000) { boot.join() }
            assertNotEquals("fake-main", bootThread.await())
        } finally {
            release.countDown(); holder.join(5_000)
            main.close(); worker.close()
        }
    }

    @Test
    fun resultIsReturnedToTheCaller() = runBlocking {
        assertEquals(42, EngineBoot.offMain { 42 })
    }
}
