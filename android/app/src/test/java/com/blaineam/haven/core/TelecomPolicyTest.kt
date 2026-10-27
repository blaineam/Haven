package com.blaineam.haven.core

import android.telecom.DisconnectCause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Telecom adapter's decisions (docs/ANDROID-CALLS.md), against fakes — no Android runtime needed. */
class TelecomPolicyTest {
    // ---- cause mapping: our copy of the DisconnectCause codes must be the platform's ----
    @Test fun endCausesMapOntoThePlatformDisconnectCodes() {
        assertEquals(DisconnectCause.LOCAL, TelecomPolicy.causeCode(TelecomPolicy.End.LOCAL))
        assertEquals(DisconnectCause.REMOTE, TelecomPolicy.causeCode(TelecomPolicy.End.REMOTE))
        assertEquals(DisconnectCause.MISSED, TelecomPolicy.causeCode(TelecomPolicy.End.MISSED))
        assertEquals(DisconnectCause.REJECTED, TelecomPolicy.causeCode(TelecomPolicy.End.REJECTED))
        assertEquals(DisconnectCause.BUSY, TelecomPolicy.causeCode(TelecomPolicy.End.BUSY))
        assertEquals(DisconnectCause.ERROR, TelecomPolicy.causeCode(TelecomPolicy.End.ERROR))
        assertEquals(DisconnectCause.CANCELED, TelecomPolicy.causeCode(TelecomPolicy.End.CANCELED))
    }

    @Test fun routeBitsMatchCallAudioState() {
        assertEquals(android.telecom.CallAudioState.ROUTE_EARPIECE, TelecomPolicy.ROUTE_EARPIECE)
        assertEquals(android.telecom.CallAudioState.ROUTE_BLUETOOTH, TelecomPolicy.ROUTE_BLUETOOTH)
        assertEquals(android.telecom.CallAudioState.ROUTE_WIRED_HEADSET, TelecomPolicy.ROUTE_WIRED_HEADSET)
        assertEquals(android.telecom.CallAudioState.ROUTE_SPEAKER, TelecomPolicy.ROUTE_SPEAKER)
    }

    // ---- which route to ask for ----
    @Test fun speakerOnAsksForTheSpeaker() {
        assertEquals(TelecomPolicy.ROUTE_SPEAKER, TelecomPolicy.routeForSpeaker(true, 0xF))
    }

    @Test fun speakerOffPrefersCarBluetoothThenWiredThenEarpiece() {
        assertEquals(TelecomPolicy.ROUTE_BLUETOOTH, TelecomPolicy.routeForSpeaker(false, 0xF))
        assertEquals(TelecomPolicy.ROUTE_WIRED_HEADSET,
            TelecomPolicy.routeForSpeaker(false, TelecomPolicy.ROUTE_WIRED_HEADSET or TelecomPolicy.ROUTE_EARPIECE))
        assertEquals(TelecomPolicy.ROUTE_EARPIECE,
            TelecomPolicy.routeForSpeaker(false, TelecomPolicy.ROUTE_EARPIECE or TelecomPolicy.ROUTE_SPEAKER))
        assertEquals(TelecomPolicy.ROUTE_EARPIECE, TelecomPolicy.routeForSpeaker(false, 0))
    }

    // ---- following the system's route without clobbering Haven's default ----
    @Test fun theFirstReportedRouteBeforeAnyRequestIsIgnored() {
        val a = TelecomPolicy.RouteArbiter()
        assertNull("Telecom's default earpiece must not flip a hands-free call", a.onSystemRoute(TelecomPolicy.ROUTE_EARPIECE))
    }

    @Test fun anUnsettledMismatchIsIgnored() {
        val a = TelecomPolicy.RouteArbiter()
        a.request(TelecomPolicy.ROUTE_SPEAKER)
        // the system still reports its default for a beat — not an external request yet
        assertNull(a.onSystemRoute(TelecomPolicy.ROUTE_EARPIECE))
    }

    @Test fun afterTheSystemAcknowledgesOurRouteALaterChangeIsAdopted() {
        val a = TelecomPolicy.RouteArbiter()
        a.request(TelecomPolicy.ROUTE_SPEAKER)
        assertNull(a.onSystemRoute(TelecomPolicy.ROUTE_SPEAKER))       // settled
        assertEquals(false, a.onSystemRoute(TelecomPolicy.ROUTE_BLUETOOTH))   // driver picked the car
        assertNull("same route again is not news", a.onSystemRoute(TelecomPolicy.ROUTE_BLUETOOTH))
        assertEquals(true, a.onSystemRoute(TelecomPolicy.ROUTE_SPEAKER))      // and back to the speaker
    }

    @Test fun aNewRequestResetsSettling() {
        val a = TelecomPolicy.RouteArbiter()
        a.request(TelecomPolicy.ROUTE_SPEAKER); a.onSystemRoute(TelecomPolicy.ROUTE_SPEAKER)
        a.request(TelecomPolicy.ROUTE_BLUETOOTH)    // the speaker button
        assertNull("a stale report of the previous route is not an external change", a.onSystemRoute(TelecomPolicy.ROUTE_SPEAKER))
        assertNull(a.onSystemRoute(TelecomPolicy.ROUTE_BLUETOOTH))
    }

    @Test fun resetForgetsEverythingBetweenCalls() {
        val a = TelecomPolicy.RouteArbiter()
        a.request(TelecomPolicy.ROUTE_SPEAKER); a.onSystemRoute(TelecomPolicy.ROUTE_SPEAKER)
        a.reset()
        assertNull(a.onSystemRoute(TelecomPolicy.ROUTE_BLUETOOTH))
    }

    // ---- the connection's session ----
    private class FakePort : TelecomPolicy.Port {
        val log = mutableListOf<String>()
        override fun setDialing() { log += "dialing" }
        override fun setRinging() { log += "ringing" }
        override fun setActive() { log += "active" }
        override fun setDisconnected(causeCode: Int) { log += "disconnected:$causeCode" }
        override fun destroy() { log += "destroy" }
    }
    private class FakeEngine : TelecomPolicy.Engine {
        val log = mutableListOf<String>()
        override fun accept() { log += "accept" }
        override fun decline() { log += "decline" }
        override fun hangup() { log += "hangup" }
    }

    @Test fun anOutgoingSessionStartsDialingAnIncomingOneRinging() {
        val out = FakePort(); TelecomPolicy.Session(out, FakeEngine(), outgoing = true)
        val inc = FakePort(); TelecomPolicy.Session(inc, FakeEngine(), outgoing = false)
        assertEquals(listOf("dialing"), out.log)
        assertEquals(listOf("ringing"), inc.log)
    }

    @Test fun answeringFromTheCarAcceptsTheEngineCall() {
        val e = FakeEngine(); val s = TelecomPolicy.Session(FakePort(), e, outgoing = false)
        s.onSystemAnswer()
        assertEquals(listOf("accept"), e.log)
    }

    @Test fun decliningFromTheCarDeclinesTheEngineCall() {
        val e = FakeEngine(); val s = TelecomPolicy.Session(FakePort(), e, outgoing = false)
        s.onSystemReject()
        assertEquals(listOf("decline"), e.log)
    }

    @Test fun answerAndRejectAreIgnoredOnAnOutgoingOrAnAlreadyActiveCall() {
        val e = FakeEngine()
        val out = TelecomPolicy.Session(FakePort(), e, outgoing = true)
        out.onSystemAnswer(); out.onSystemReject()
        val inc = TelecomPolicy.Session(FakePort(), e, outgoing = false)
        inc.onEngineActive()
        inc.onSystemAnswer(); inc.onSystemReject()
        assertTrue(e.log.isEmpty())
    }

    @Test fun hangingUpFromTheSystemHangsUpTheEngine() {
        val e = FakeEngine(); val s = TelecomPolicy.Session(FakePort(), e, outgoing = true)
        s.onSystemDisconnect(); s.onSystemAbort()
        assertEquals(listOf("hangup", "hangup"), e.log)
    }

    @Test fun theEngineConnectingMakesTheSessionActiveExactlyOnce() {
        val p = FakePort(); val s = TelecomPolicy.Session(p, FakeEngine(), outgoing = true)
        s.onEngineActive(); s.onEngineActive()
        assertEquals(listOf("dialing", "active"), p.log)
        assertTrue(s.active)
    }

    @Test fun aRemoteHangupDisconnectsWithRemoteAndDestroysOnce() {
        val p = FakePort(); val s = TelecomPolicy.Session(p, FakeEngine(), outgoing = true)
        s.onEngineActive()
        s.onEngineEnded(TelecomPolicy.End.REMOTE); s.onEngineEnded(TelecomPolicy.End.LOCAL)
        assertEquals(listOf("dialing", "active", "disconnected:${DisconnectCause.REMOTE}", "destroy"), p.log)
        assertTrue(s.ended)
    }

    @Test fun aMissedCallIsReportedAsMissed() {
        val p = FakePort(); val s = TelecomPolicy.Session(p, FakeEngine(), outgoing = false)
        s.onEngineEnded(TelecomPolicy.End.MISSED)
        assertEquals("disconnected:${DisconnectCause.MISSED}", p.log[1])
    }

    @Test fun nothingReachesTheEngineAfterTheCallEnded() {
        val e = FakeEngine(); val s = TelecomPolicy.Session(FakePort(), e, outgoing = false)
        s.onEngineEnded(TelecomPolicy.End.REJECTED)
        s.onSystemAnswer(); s.onSystemReject(); s.onSystemDisconnect(); s.onSystemAbort()
        assertTrue("the echo of our own disconnect must not loop back into a second hangup", e.log.isEmpty())
    }

    @Test fun aLateActiveAfterEndIsIgnored() {
        val p = FakePort(); val s = TelecomPolicy.Session(p, FakeEngine(), outgoing = false)
        s.onEngineEnded(TelecomPolicy.End.LOCAL); s.onEngineActive()
        assertFalse(p.log.contains("active"))
    }

    // ---- placing a call with a guaranteed fallback ----
    private class FakeGateway(var refuse: Boolean = false) : TelecomPolicy.Gateway {
        var placed = 0; var direct = 0
        val scheduled = mutableListOf<Pair<Long, () -> Unit>>()
        override fun placeCall(token: Long) { placed++; if (refuse) throw SecurityException("no MANAGE_OWN_CALLS") }
        override fun schedule(delayMs: Long, block: () -> Unit) { scheduled += delayMs to block }
        override fun dialDirect() { direct++ }
    }

    @Test fun whenTelecomHandsOverAConnectionNoFallbackFires() {
        val g = FakeGateway(); val p = TelecomPolicy.Placer(g)
        p.place()
        assertTrue(p.onConnectionRequested())
        g.scheduled.forEach { it.second() }          // the timeout fires afterwards
        assertEquals(1, g.placed); assertEquals(0, g.direct)
        assertEquals(TelecomPolicy.PLACE_TIMEOUT_MS, g.scheduled.single().first)
    }

    @Test fun whenTelecomRefusesOutrightTheCallDialsDirectlyOnce() {
        val g = FakeGateway(refuse = true); val p = TelecomPolicy.Placer(g)
        p.place()
        assertEquals(1, g.direct)
        assertTrue("no timeout is armed after a refusal", g.scheduled.isEmpty())
        assertFalse(p.onConnectionRequested())
    }

    @Test fun whenTelecomNeverAnswersTheTimeoutDialsDirectlyOnce() {
        val g = FakeGateway(); val p = TelecomPolicy.Placer(g)
        p.place()
        g.scheduled.single().second(); g.scheduled.single().second()
        assertEquals(1, g.direct)
    }

    @Test fun aConnectionThatArrivesAfterTheFallbackIsRefusedSoOneTapIsOneCall() {
        val g = FakeGateway(); val p = TelecomPolicy.Placer(g)
        p.place()
        g.scheduled.single().second()                 // fallback dialed
        assertFalse(p.onConnectionRequested())
        assertEquals(1, g.direct)
    }

    @Test fun theSystemReportingFailureFallsBackOnce() {
        val g = FakeGateway(); val p = TelecomPolicy.Placer(g)
        p.place()
        p.onRefused(); p.onRefused()
        g.scheduled.single().second()
        assertEquals(1, g.direct)
    }

    @Test fun aStrayConnectionRequestWithNothingPlacedIsRefused() {
        assertFalse(TelecomPolicy.Placer(FakeGateway()).onConnectionRequested())
    }

    @Test fun aSecondPlaceSupersedesTheFirstSoOnlyTheLatestCanConnect() {
        val g = FakeGateway(); val p = TelecomPolicy.Placer(g)
        p.place(); p.place()
        g.scheduled[0].second()                       // the first call's stale timeout: nothing
        assertEquals(0, g.direct)
        assertTrue(p.onConnectionRequested())
    }
}
