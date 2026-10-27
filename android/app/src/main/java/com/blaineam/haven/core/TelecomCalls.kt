package com.blaineam.haven.core

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log

/**
 * Haven's calls as first-class SYSTEM calls (docs/ANDROID-CALLS.md) — the Android counterpart of the
 * iOS CallKit provider. A self-managed [PhoneAccount] tells Telecom (and through it the car, Bluetooth
 * headsets and the system call controls) that a Haven call exists, what state it is in and where its
 * audio goes. Haven still draws its own call screen and owns the media: [CallManager] stays the single
 * source of truth, this object only translates in both directions.
 *
 *  * UI / notification / voice-started calls go out through [place] (`TelecomManager.placeCall`); the
 *    system hands [HavenTelecomService] a connection and the engine dials from there.
 *  * Incoming calls are reported with [reportIncoming] (`addNewIncomingCall`) after the engine has
 *    started ringing; the existing full-screen notification remains the incoming UI.
 *  * Answer / reject / hang-up from the car or a headset drive the engine ([TelecomPolicy.Session]);
 *    engine connect / end drive the system.
 *  * Telecom is an ADDITION, never a dependency: if it is unavailable, refuses, or never answers the
 *    call falls back to the legacy direct path ([TelecomPolicy.Placer]).
 */
object TelecomCalls {
    private const val TAG = "TelecomCalls"

    @Volatile private var appContext: Context? = null
    @Volatile private var registered = false
    private val main = Handler(Looper.getMainLooper())
    private val arbiter = TelecomPolicy.RouteArbiter()

    @Volatile private var session: TelecomPolicy.Session? = null
    @Volatile private var connection: HavenConnection? = null

    private class Pending(val others: List<String>, val name: String, val session: String?, val placer: TelecomPolicy.Placer)
    @Volatile private var pending: Pending? = null

    /** Register the self-managed phone account (idempotent). Returns false when the platform refuses. */
    fun register(context: Context): Boolean {
        return runCatching {
            val ctx = context.applicationContext
            val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val account = PhoneAccount.builder(handle(ctx), "Haven")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .addSupportedUriScheme(TelecomPolicy.SCHEME)
                .setShortDescription("Haven calls")
                .build()
            tm.registerPhoneAccount(account)
            appContext = ctx
            registered = true
            true
        }.getOrElse {
            Log.w(TAG, "phone account refused (${it.javaClass.simpleName}) — calls use the direct path: ${it.message}")
            registered = false
            false
        }
    }

    fun handle(ctx: Context): PhoneAccountHandle =
        PhoneAccountHandle(ComponentName(ctx, HavenTelecomService::class.java), TelecomPolicy.ACCOUNT_ID)

    // ---------------------------------------------------------------- outgoing

    /**
     * Start an outgoing call through Telecom. True = Telecom owns the start (the engine dials once
     * the system hands the service its connection, or via the fallback); false = not applicable, the
     * caller dials directly. Never true for "add people to the live call" or a duplicate tap.
     */
    fun place(others: List<String>, name: String, session: String?): Boolean {
        val ctx = appContext ?: return false
        if (!registered || others.isEmpty()) return false
        if (CallManager.callInProgress) return false
        if (pending != null) return true            // a second tap while the first is placing: swallow
        if (this.session?.ended == false) return false
        val gateway = object : TelecomPolicy.Gateway {
            override fun placeCall(token: Long) {
                val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                val extras = Bundle().apply {
                    putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle(ctx))
                }
                tm.placeCall(Uri.fromParts(TelecomPolicy.SCHEME, others.first(), null), extras)
            }
            override fun schedule(delayMs: Long, block: () -> Unit) { main.postDelayed(block, delayMs) }
            override fun dialDirect() {
                pending = null
                Log.w(TAG, "Telecom did not place the call — dialing directly")
                CallManager.startCallDirect(others, name, session)
            }
        }
        val placer = TelecomPolicy.Placer(gateway)
        pending = Pending(others, name, session, placer)
        placer.place()
        return true
    }

    /** [HavenTelecomService.onCreateOutgoingConnection]: the system is ready — build the connection, dial. */
    internal fun createOutgoing(): Connection {
        val p = pending
        if (p == null || !p.placer.onConnectionRequested()) {
            // The fallback already dialed (or this is a stray request) — never a second call.
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.CANCELED))
        }
        pending = null
        val conn = attach(outgoing = true, name = p.name)
        CallManager.startCallDirect(p.others, p.name, p.session)
        return conn
    }

    internal fun outgoingRefused() {
        val p = pending ?: return
        p.placer.onRefused()
    }

    // ---------------------------------------------------------------- incoming

    /** The engine just started ringing — tell Telecom. The notification already rings the phone. */
    fun reportIncoming() {
        val ctx = appContext ?: return
        if (!registered || session?.ended == false) return
        runCatching {
            val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.addNewIncomingCall(handle(ctx), Bundle())
        }.onFailure { Log.w(TAG, "incoming call not reported to Telecom: ${it.javaClass.simpleName}: ${it.message}") }
    }

    internal fun createIncoming(): Connection {
        // Busy (another Haven call is live) or it ended before the system got here: refuse cleanly.
        if (session?.ended == false) return Connection.createFailedConnection(DisconnectCause(DisconnectCause.BUSY))
        if (!CallManager.ringing.value) {
            Log.i(TAG, "incoming connection refused — the call is no longer ringing (caller gave up or answered in-app)")
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.CANCELED))
        }
        // The ring must NOT wait for Telecom's onShowIncomingCallUi (a self-managed call draws and rings
        // nothing, and the system did not call it on a real phone): make sure the notification + ring are
        // up now. Idempotent — the engine already started them when the invite arrived.
        appContext?.let { IncomingCallUi.ring(it, CallManager.peerName.value) }
        return attach(outgoing = false, name = CallManager.peerName.value)
    }

    internal fun incomingRefused() { Log.i(TAG, "Telecom refused the incoming call — the notification is still the UI") }

    /** The system asks Haven to show its incoming-call UI — the full-screen notification, re-posted. */
    internal fun showIncomingUi() {
        val ctx = appContext ?: return
        Log.i(TAG, "onShowIncomingCallUi — re-asserting the incoming-call notification")
        if (CallManager.ringing.value) IncomingCallUi.reassert(ctx, CallManager.peerName.value)
    }

    // ---------------------------------------------------------------- engine → system

    /** The call connected (answered here, or the far end accepted). */
    fun onEngineActive() { session?.onEngineActive() }

    /** The call ended for [end]; also drops a placement that never produced a connection. */
    fun onEngineEnded(end: TelecomPolicy.End) {
        session?.onEngineEnded(end)
        pending = null
        arbiter.reset()
    }

    // ---------------------------------------------------------------- audio route

    /** Haven picked a route (media start default, or the speaker button): tell the system the same. */
    fun mirrorSpeaker(speaker: Boolean) {
        val conn = connection ?: return
        if (session?.ended != false) return
        @Suppress("DEPRECATION")
        val mask = conn.callAudioState?.supportedRouteMask ?: 0
        val route = TelecomPolicy.routeForSpeaker(speaker, mask)
        arbiter.request(route)
        @Suppress("DEPRECATION")
        runCatching { conn.setAudioRoute(route) }
    }

    /** The system reported a route (the car's screen, system controls): adopt it when it is a real change. */
    @Suppress("DEPRECATION")
    internal fun onSystemAudioState(state: CallAudioState?) {
        val route = state?.route ?: return
        arbiter.onSystemRoute(route)?.let { CallManager.adoptSystemRoute(it) }
    }

    // ---------------------------------------------------------------- connection plumbing

    private fun attach(outgoing: Boolean, name: String): HavenConnection {
        val conn = HavenConnection()
        conn.setAudioModeIsVoip(true)
        conn.setCallerDisplayName(name.ifBlank { "Haven" }, TelecomManager.PRESENTATION_ALLOWED)
        conn.setAddress(Uri.fromParts(TelecomPolicy.SCHEME, "call", null), TelecomManager.PRESENTATION_ALLOWED)
        val engine = object : TelecomPolicy.Engine {
            override fun accept() { CallManager.accept() }
            override fun decline() { CallManager.decline() }
            override fun hangup() { CallManager.hangup() }
        }
        val s = TelecomPolicy.Session(ConnectionPort(conn), engine, outgoing)
        conn.session = s
        connection = conn
        session = s
        // The engine may already be connected if the user answered in-app before the system got here.
        if (CallManager.inCall.value) s.onEngineActive()
        return conn
    }

    private class ConnectionPort(private val c: Connection) : TelecomPolicy.Port {
        override fun setDialing() = c.setDialing()
        override fun setRinging() = c.setRinging()
        override fun setActive() = c.setActive()
        override fun setDisconnected(causeCode: Int) = c.setDisconnected(DisconnectCause(causeCode))
        override fun destroy() = c.destroy()
    }

    /** JVM-test seam: forget everything (state is process-wide). */
    internal fun resetForTest() {
        registered = false; appContext = null; session = null; connection = null; pending = null; arbiter.reset()
    }
}
