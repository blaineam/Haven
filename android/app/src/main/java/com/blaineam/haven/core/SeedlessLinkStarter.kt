package com.blaineam.haven.core

import android.content.Context
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * First-run seedless link, OFF main.
 *
 * Linking this phone as a new device of an existing account needs the transient engine + node up
 * before the frame-28 request can be built, and `HavenNet.init` is `@Synchronized` and takes seconds
 * on a cold or loaded device (see [EngineBoot]). The onboarding dialog used to run it inline from the
 * Link button — on main, at the one moment a new user cannot route around an ANR. The boot + request
 * now run on [worker] while the dialog shows [State.BOOTING]; the outcome comes back as a state:
 *
 *  - [State.SENT]: the request went out; HavenNet's `seedlessLinking` overlay takes over (as before);
 *  - [State.INVALID_CODE]: the text was not a usable `haven-enroll:` ticket (same as the old `false`);
 *  - [State.FAILED]: the boot itself threw — the user sees an error and can retry.
 *
 * Exactly one boot+link is in flight at a time: [begin] while [State.BOOTING] is refused, so a double
 * tap (or scan + tap) never races two requests. `HavenNet.init` stays idempotent, so a retry after a
 * failure re-enters it safely; the ordering init → start → beginSeedlessLink is unchanged.
 */
class SeedlessLinkStarter(
    private val scope: CoroutineScope,
    private val worker: CoroutineDispatcher = Dispatchers.Default,
    private val link: (String) -> Boolean,
) {
    enum class State { IDLE, BOOTING, SENT, INVALID_CODE, FAILED }

    private val _state = MutableStateFlow(State.IDLE)
    val state: StateFlow<State> = _state.asStateFlow()

    /** Start a boot+link for [text]. Returns false (and does nothing) if one is already in flight. */
    fun begin(text: String): Boolean {
        while (true) {
            val cur = _state.value
            if (cur == State.BOOTING) return false
            if (_state.compareAndSet(cur, State.BOOTING)) break
        }
        scope.launch {
            val outcome = runCatching { EngineBoot.offMain(worker) { link(text.trim()) } }
            _state.value = outcome.fold(
                onSuccess = { sent -> if (sent) State.SENT else State.INVALID_CODE },
                onFailure = { e ->
                    // Guarded: android.util.Log is a stub that throws in JVM unit tests.
                    runCatching { android.util.Log.w("SeedlessLink", "boot/link failed", e) }
                    State.FAILED
                },
            )
        }
        return true
    }

    /** Back to [State.IDLE] once the UI has consumed an outcome; a boot in flight is left alone. */
    fun reset() {
        while (true) {
            val cur = _state.value
            if (cur == State.BOOTING || cur == State.IDLE) return
            if (_state.compareAndSet(cur, State.IDLE)) return
        }
    }

    companion object {
        /** The production link: boot the engine, start the node, send the frame-28 request — all on
         *  the caller's thread, which [begin] guarantees is [worker], never main. */
        fun forApp(context: Context, scope: CoroutineScope): SeedlessLinkStarter {
            val app = context.applicationContext
            return SeedlessLinkStarter(scope) { text ->
                HavenNet.init(app)
                HavenNet.start()
                HavenNet.beginSeedlessLink(text)
            }
        }
    }
}
