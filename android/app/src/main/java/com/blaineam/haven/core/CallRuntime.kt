package com.blaineam.haven.core

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executors

/**
 * Brings the engine, the network node and the call stack up in a process that was NOT started by
 * [MainActivity] — the head unit starting [com.blaineam.haven.car.HavenCarAppService] in a cold process,
 * Assistant launching a voice call before the UI composed. Normal startup does this in `RootScreen`
 * (`HavenNet.init` → `HavenNet.start` → `CallManager.init`); a process with no UI never runs that, so the
 * first call from the car reached `CallManager` with its `appContext` unset and crashed the car process
 * (`UninitializedPropertyAccessException`, found on the Desktop Head Unit).
 *
 * Every entry point that can place a call without the UI goes through [whenReady]; the ordering and the
 * failure handling are the pure [ensureReady], covered by JVM tests with a fake [Boot].
 */
object CallRuntime {
    private const val TAG = "CallRuntime"

    /** What bringing the process up needs — a seam so the orchestration is testable without an engine. */
    interface Boot {
        /** The call stack ([CallManager]) is already initialised. */
        fun callsReady(): Boolean

        /** An account exists; without one there is nothing to boot and nothing to call. */
        fun onboarded(): Boolean

        /** Idempotent, blocking: the engine and the network node. Never on the main thread. */
        fun bootEngine()

        /** Idempotent: [CallManager] against the booted engine. */
        fun initCalls()
    }

    /**
     * True when calls may be placed now. Boots what is missing, in order (engine → network → calls), and
     * NEVER throws: a failure, or no account yet, is `false` so the caller can show something graceful
     * instead of crashing the process.
     */
    fun ensureReady(boot: Boot): Boolean {
        if (boot.callsReady()) return true
        return runCatching {
            if (!boot.onboarded()) return@runCatching false
            boot.bootEngine()
            boot.initCalls()
            boot.callsReady()
        }.getOrElse { Log.w(TAG, "could not bring the call stack up: ${it.message}"); false }
    }

    private class ProdBoot(private val app: Context) : Boot {
        override fun callsReady() = CallManager.isReady
        override fun onboarded() = ProfileStore.get(app).onboarded
        override fun bootEngine() { HavenNet.init(app); HavenNet.start() }
        override fun initCalls() = CallManager.init(app, HavenNet.nodeIdHex)
    }

    /** One serial lane: concurrent callers wait their turn instead of booting twice. */
    private val lane = Executors.newSingleThreadExecutor { r -> Thread(r, "haven-call-runtime").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    /**
     * Make calls ready (off the calling thread — booting the engine blocks) and then run [then] on the
     * main thread with the result. Safe to call from the main thread.
     */
    fun whenReady(context: Context, then: (Boolean) -> Unit) {
        val app = context.applicationContext
        if (CallManager.isReady) { then(true); return }
        lane.execute {
            val ok = ensureReady(ProdBoot(app))
            main.post { then(ok) }
        }
    }
}
