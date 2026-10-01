package com.blaineam.haven.core

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Where the app's launch path boots the engine: NEVER on the caller's (main) thread.
 *
 * `HavenNet.init` is `@Synchronized` and does seconds of work on a cold or busy device (engine
 * construct, state import, device registration, SharedPreferences fsyncs). It is ALSO entered by
 * `SyncWorker` on a WorkManager thread. When RootScreen's LaunchedEffect called it on main while the
 * worker was mid-init, main parked on the monitor — the e2e emulator (2026-09-30 06:25) logged
 * "Long monitor contention with owner DefaultDispatcher-worker-1 … in HavenNet.init for 13.713s" and
 * then an ANR ("Waited 5035ms for FocusEvent", 20 s to process it). Hopping to [worker] keeps main
 * free to draw and take input whichever thread wins the lock; the caller resumes on its own
 * dispatcher once the engine is up, so the start/CallManager steps that follow are unchanged.
 */
object EngineBoot {
    suspend fun <T> offMain(worker: CoroutineDispatcher = Dispatchers.Default, block: () -> T): T =
        withContext(worker) { block() }

    /** One serial thread for fire-and-forget boots from non-suspending main-thread entry points
     *  (a Service's onStartCommand): repeated starts queue behind each other instead of racing,
     *  and `HavenNet.init` is idempotent, so a second boot finds the engine ready and returns. */
    private val bootExec = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "haven-engine-boot").apply { isDaemon = true }
    }

    /** Run [block] on the boot thread and return immediately. Failures are logged, never thrown
     *  into the caller — a boot that fails here is retried by the next start, like a failed init. */
    fun background(block: () -> Unit) {
        bootExec.execute {
            runCatching(block).onFailure { android.util.Log.w("EngineBoot", "background boot failed", it) }
        }
    }
}
