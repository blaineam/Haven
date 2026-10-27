package com.blaineam.haven.core

import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.PhoneAccountHandle

/**
 * The system's way into Haven's calls: Telecom binds this service (BIND_TELECOM_CONNECTION_SERVICE)
 * to ask for a [Connection] when Haven places or receives a call on its self-managed phone account.
 * All decisions live in [TelecomCalls] / [TelecomPolicy]; this class only forwards.
 *
 * Not to be confused with [ConnectionService] — Haven's "stay connected" foreground service (a
 * name that predates this one). That one keeps the process and the iroh node alive; this one is the
 * Telecom hook.
 */
class HavenTelecomService : android.telecom.ConnectionService() {
    override fun onCreate() {
        super.onCreate()
        // Telecom can bind this in a process nothing else started (no RootScreen to initialise the call
        // stack): bring it up, off this thread, so the connection callbacks below find a live CallManager.
        CallRuntime.whenReady(applicationContext) { }
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection = TelecomCalls.createOutgoing()

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) = TelecomCalls.outgoingRefused()

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection = TelecomCalls.createIncoming()

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) = TelecomCalls.incomingRefused()
}

/**
 * One Haven call as the system sees it. Self-managed, VoIP audio, no hold: the engine has no hold
 * state, so advertising the capability would let a car or headset put a call into a state Haven
 * cannot honour. System events go to the [TelecomPolicy.Session]; it, not this class, decides.
 */
class HavenConnection : Connection() {
    lateinit var session: TelecomPolicy.Session

    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = 0
    }

    override fun onAnswer() { session.onSystemAnswer() }
    override fun onAnswer(videoState: Int) { session.onSystemAnswer() }
    override fun onReject() { session.onSystemReject() }
    override fun onReject(replyMessage: String?) { session.onSystemReject() }
    override fun onDisconnect() { session.onSystemDisconnect() }
    override fun onAbort() { session.onSystemAbort() }
    override fun onShowIncomingCallUi() { TelecomCalls.showIncomingUi() }

    @Deprecated("Deprecated in Java")
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onCallAudioStateChanged(state: CallAudioState?) { TelecomCalls.onSystemAudioState(state) }
}
