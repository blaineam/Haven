package com.blaineam.haven.core

/**
 * The pure rules behind Haven's Android Telecom integration (docs/ANDROID-CALLS.md) — the Android
 * counterpart of iOS's CallKit. No Android types, so every decision is covered by a plain JVM test.
 *
 * Haven registers a SELF-MANAGED phone account: the system (and the car) learn that a call exists,
 * its state and its audio route, while Haven keeps drawing its own call screen and owns the media
 * ([CallManager]). Telecom is an adapter around the engine, never a second state machine: the engine
 * stays the single source of truth for "is a call ringing / connected", and these types translate.
 */
object TelecomPolicy {
    /** The one phone account id; the handle is `ComponentName(HavenTelecomService) + this`. */
    const val ACCOUNT_ID = "haven-calls"

    /** Address scheme of a Haven call: `haven:<64-hex node id>`. */
    const val SCHEME = "haven"

    /** How long a placed call may wait for Telecom to hand the service its connection before we
     *  give up and dial through the legacy path — a call must never be lost to a slow system. */
    const val PLACE_TIMEOUT_MS = 3_000L

    /** Why a call ended — mapped 1:1 onto `android.telecom.DisconnectCause`. */
    enum class End { LOCAL, REMOTE, MISSED, REJECTED, BUSY, ERROR, CANCELED }

    // android.telecom.DisconnectCause codes (compile-time constants, copied so the mapping runs on a JVM).
    private const val CAUSE_ERROR = 1
    private const val CAUSE_LOCAL = 2
    private const val CAUSE_REMOTE = 3
    private const val CAUSE_CANCELED = 4
    private const val CAUSE_MISSED = 5
    private const val CAUSE_REJECTED = 6
    private const val CAUSE_BUSY = 7

    fun causeCode(end: End): Int = when (end) {
        End.LOCAL -> CAUSE_LOCAL
        End.REMOTE -> CAUSE_REMOTE
        End.MISSED -> CAUSE_MISSED
        End.REJECTED -> CAUSE_REJECTED
        End.BUSY -> CAUSE_BUSY
        End.ERROR -> CAUSE_ERROR
        End.CANCELED -> CAUSE_CANCELED
    }

    // android.telecom.CallAudioState route bits.
    const val ROUTE_EARPIECE = 1
    const val ROUTE_BLUETOOTH = 2
    const val ROUTE_WIRED_HEADSET = 4
    const val ROUTE_SPEAKER = 8

    /**
     * The Telecom route to ask for when Haven wants the speaker on/off, given what the system says
     * it supports. Speaker-off prefers an attached car/headset (Bluetooth, then wired) over the
     * earpiece — the same "external wins" rule as [CallRoutePolicy].
     */
    fun routeForSpeaker(speaker: Boolean, supportedMask: Int): Int = when {
        speaker -> ROUTE_SPEAKER
        supportedMask and ROUTE_BLUETOOTH != 0 -> ROUTE_BLUETOOTH
        supportedMask and ROUTE_WIRED_HEADSET != 0 -> ROUTE_WIRED_HEADSET
        else -> ROUTE_EARPIECE
    }

    /**
     * Follows route changes REPORTED by the system (the driver picking Bluetooth on the car's screen,
     * the user using the system call controls) without ever clobbering Haven's own default.
     *
     * A brand-new connection is first reported on Telecom's default route (earpiece), which is NOT
     * what the user chose and would flip a hands-free call to the earpiece. So a report is adopted
     * only after Haven has asked for a route ([request]) and the system has acknowledged exactly
     * that route once ([settled]); from then on any different route is an external request.
     */
    class RouteArbiter {
        private var requested: Int? = null
        private var settled = false

        /** Haven asked the system for [route] (default at media start, or a speaker tap). */
        fun request(route: Int) { requested = route; settled = false }

        /** The system reported [route]. Returns the speaker flag to adopt, or null to ignore it. */
        fun onSystemRoute(route: Int): Boolean? {
            val asked = requested ?: return null
            if (route == asked) { settled = true; return null }
            if (!settled) return null            // initial default / a stale report of the previous route
            requested = route                    // adopt: this is the new baseline
            return route == ROUTE_SPEAKER
        }

        fun reset() { requested = null; settled = false }
    }

    /** A Telecom incoming-connection request for a call that ended less than this ago is the caller giving up. */
    const val GONE_WINDOW_MS = 5_000L

    /** How long a connection created while the engine's state is still catching up is trusted before it is verified. */
    const val GRACE_MS = 1_500L

    enum class IncomingVerdict {
        /** The engine has a live call and Telecom has no connection for it yet: create the connection. */
        ACCEPT,
        /** The engine does not look live, but nothing says the call ended: create it and verify after [GRACE_MS]. */
        ACCEPT_WITH_GRACE,
        /** Telecom re-offered the call it already holds a connection for: keep the existing one. */
        REFUSE_DUPLICATE,
        /** The call ended moments ago (caller hung up / answered elsewhere): refuse, there is nothing to ring. */
        REFUSE_GONE,
    }

    /**
     * Whether to create a connection when Telecom asks for an incoming one (`onCreateIncomingConnection`).
     *
     * The old rule was "refuse unless the engine says ringing right now", which is wrong in two directions:
     * it refused a call the user had already ANSWERED in-app before the system got here (and so left a live
     * call with no Telecom connection), and it refused whenever the engine's state had not yet caught up.
     * It is right only for a call that really ended. So:
     *
     *  * a live engine call is accepted — unless Telecom already holds a connection for that SAME call
     *    ([hasLiveSession] && [sameCall]), which is a duplicate offer and keeps the existing connection;
     *  * a live session for a DIFFERENT call is stale (its end event never arrived) — the caller ends it
     *    first, then this decides as if there were none;
     *  * an engine that is not live but ended a call ≤ [GONE_WINDOW_MS] ago is the caller giving up: refuse;
     *  * anything else is engine-state lag or an unknown: accept and verify after [GRACE_MS] rather than
     *    drop a call that may be ringing.
     *
     * Refusing NEVER removes the ring: the notification and ring come from the engine path
     * ([CallManager.incoming] -> [IncomingCallUi]), not from Telecom.
     */
    fun decideIncoming(engineLive: Boolean, hasLiveSession: Boolean, sameCall: Boolean, msSinceEnd: Long?): IncomingVerdict {
        if (hasLiveSession && sameCall) return IncomingVerdict.REFUSE_DUPLICATE
        if (engineLive) return IncomingVerdict.ACCEPT
        if (msSinceEnd != null && msSinceEnd <= GONE_WINDOW_MS) return IncomingVerdict.REFUSE_GONE
        return IncomingVerdict.ACCEPT_WITH_GRACE
    }

    /** What the engine side of a call offers the connection (answer / hang up), as plain callbacks. */
    interface Engine {
        fun accept()
        fun decline()
        fun hangup()
    }

    /** What the Telecom `Connection` offers the session (state changes pushed to the system). */
    interface Port {
        fun setDialing()
        fun setRinging()
        fun setActive()
        fun setDisconnected(causeCode: Int)
        fun destroy()
    }

    /**
     * One call's Telecom connection: system events (answer, reject, disconnect, abort) drive the
     * engine; engine events (connected, ended) drive the system. Each direction is guarded so the
     * echo of our own change never loops back, and nothing happens after the call ended.
     */
    class Session(private val port: Port, private val engine: Engine, val outgoing: Boolean) {
        var active = false; private set
        var ended = false; private set

        init { if (outgoing) port.setDialing() else port.setRinging() }

        // ---- System → engine ----
        /** The car / headset / system answered. */
        fun onSystemAnswer() { if (!ended && !active && !outgoing) engine.accept() }

        /** The car / system declined the ringing call. */
        fun onSystemReject() { if (!ended && !active && !outgoing) engine.decline() }

        /** The system ended the call (hang up from the car, headset or system controls). */
        fun onSystemDisconnect() { if (!ended) engine.hangup() }

        /** Abandoned before connecting (outgoing cancelled from the system side). */
        fun onSystemAbort() { if (!ended) engine.hangup() }

        // ---- Engine → system ----
        fun onEngineActive() { if (!ended && !active) { active = true; port.setActive() } }

        fun onEngineEnded(end: End) {
            if (ended) return
            ended = true
            port.setDisconnected(causeCode(end))
            port.destroy()
        }
    }

    /** What the placement of an outgoing call did, for [Placer]. */
    interface Gateway {
        /** Ask Telecom to place the call; throws if Telecom refuses outright. */
        fun placeCall(token: Long)

        /** Run [block] after [delayMs] on a thread the placer owns. */
        fun schedule(delayMs: Long, block: () -> Unit)

        /** Dial through the legacy (non-Telecom) path. */
        fun dialDirect()
    }

    /**
     * Places one outgoing call through Telecom with a guaranteed fallback: if Telecom throws, never
     * hands the service a connection in time, or reports the call failed, Haven dials the old way
     * exactly once. A connection that arrives AFTER the fallback fired is refused, so one tap can
     * never become two calls.
     */
    class Placer(private val gateway: Gateway) {
        private var token = 0L
        private var waiting: Long? = null

        /** The service is creating a connection for the pending call; true = go ahead, false = too late. */
        @Synchronized fun onConnectionRequested(): Boolean {
            val t = waiting ?: return false
            waiting = null
            return t == token
        }

        fun place() {
            val t = startWaiting()
            try {
                gateway.placeCall(t)
            } catch (e: Exception) {
                fallback(t); return
            }
            gateway.schedule(PLACE_TIMEOUT_MS) { fallback(t) }
        }

        /** Telecom told the service it could not create the outgoing connection. */
        fun onRefused() { currentWaiting()?.let { fallback(it) } }

        @Synchronized private fun startWaiting(): Long { val t = ++token; waiting = t; return t }

        @Synchronized private fun currentWaiting(): Long? = waiting

        private fun fallback(t: Long) {
            if (!claim(t)) return
            gateway.dialDirect()
        }

        /** Take the single fallback for [t]; false when the connection already arrived or it was taken. */
        @Synchronized private fun claim(t: Long): Boolean {
            if (waiting != t) return false
            waiting = null
            return true
        }
    }
}
