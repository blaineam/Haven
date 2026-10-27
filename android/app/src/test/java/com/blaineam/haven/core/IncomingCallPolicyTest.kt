package com.blaineam.haven.core

import com.blaineam.haven.core.IncomingCallPolicy.Ring
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * What an incoming Haven call does on the phone (docs/ANDROID-CALLS.md): one CallStyle notification, a
 * ring that follows the user's ringer settings, and everything cleared the moment the call stops ringing.
 * Pure fakes — no Android runtime — plus source guards for the wiring a JVM test cannot execute.
 */
class IncomingCallPolicyTest {

    // ---- how to ring ----
    @Test fun ringerConstantsMatchTheFramework() {
        assertEquals(android.media.AudioManager.RINGER_MODE_SILENT, IncomingCallPolicy.RINGER_SILENT)
        assertEquals(android.media.AudioManager.RINGER_MODE_VIBRATE, IncomingCallPolicy.RINGER_VIBRATE)
        assertEquals(android.media.AudioManager.RINGER_MODE_NORMAL, IncomingCallPolicy.RINGER_NORMAL)
        assertEquals(android.app.NotificationManager.INTERRUPTION_FILTER_ALL, IncomingCallPolicy.FILTER_ALL)
    }

    @Test fun normalModeRingsAndVibratesOnlyWhenTheUserAsksForIt() {
        assertEquals(Ring.SOUND, IncomingCallPolicy.ringFor(IncomingCallPolicy.RINGER_NORMAL, false, IncomingCallPolicy.FILTER_ALL))
        assertEquals(Ring.SOUND_AND_VIBRATE, IncomingCallPolicy.ringFor(IncomingCallPolicy.RINGER_NORMAL, true, IncomingCallPolicy.FILTER_ALL))
    }

    @Test fun vibrateModeVibratesNeverASingleBuzzNeverSound() {
        val r = IncomingCallPolicy.ringFor(IncomingCallPolicy.RINGER_VIBRATE, false, IncomingCallPolicy.FILTER_ALL)
        assertEquals(Ring.VIBRATE, r)
        assertTrue(IncomingCallPolicy.vibrates(r)); assertFalse(IncomingCallPolicy.plays(r))
        // the pattern repeats from index 0 (see AndroidRinger) and is a real on/off cadence, not one buzz
        assertEquals(listOf(0L, 1000L, 1000L), IncomingCallPolicy.VIBRATION_PATTERN.toList())
    }

    @Test fun silentModeAndDoNotDisturbRingNothingButTheNotification() {
        assertEquals(Ring.NONE, IncomingCallPolicy.ringFor(IncomingCallPolicy.RINGER_SILENT, true, IncomingCallPolicy.FILTER_ALL))
        for (filter in listOf(2, 3, 4)) { // priority / none / alarms
            assertEquals(Ring.NONE, IncomingCallPolicy.ringFor(IncomingCallPolicy.RINGER_NORMAL, true, filter))
            assertEquals(Ring.NONE, IncomingCallPolicy.ringFor(IncomingCallPolicy.RINGER_VIBRATE, true, filter))
        }
    }

    @Test fun theRingIsCappedJustPastTheEngineRingTimeout() {
        assertTrue(IncomingCallPolicy.MAX_RING_MS > 60_000L)
    }

    // ---- the presenter, with fakes ----
    private class FakePoster : IncomingCallPolicy.Poster {
        val shown = mutableListOf<String>(); var cancels = 0
        override fun show(name: String) { shown += name }
        override fun cancel() { cancels++ }
    }
    private class FakeRinger : IncomingCallPolicy.Ringer {
        val started = mutableListOf<IncomingCallPolicy.Ring>(); var stops = 0
        override fun start(ring: IncomingCallPolicy.Ring) { started += ring }
        override fun stop() { stops++ }
    }
    private fun presenter(ring: IncomingCallPolicy.Ring = Ring.SOUND_AND_VIBRATE): Triple<IncomingCallPolicy.Presenter, FakePoster, FakeRinger> {
        val p = FakePoster(); val r = FakeRinger()
        return Triple(IncomingCallPolicy.Presenter(p, r) { ring }, p, r)
    }

    @Test fun anIncomingCallPostsExactlyOneNotificationAndStartsOneRing() {
        val (pr, poster, ringer) = presenter()
        pr.onRinging("Tracy")
        assertEquals(listOf("Tracy"), poster.shown)
        assertEquals(listOf(Ring.SOUND_AND_VIBRATE), ringer.started)
        assertTrue(pr.ringing)
    }

    @Test fun aSecondRingingReportNeitherDoublePostsNorRingsAgain() {
        val (pr, poster, ringer) = presenter()
        pr.onRinging("Tracy"); pr.onRinging("Tracy")
        assertEquals(1, poster.shown.size); assertEquals(1, ringer.started.size)
    }

    @Test fun onShowIncomingCallUiReassertsTheNotificationWithoutRingingAgain() {
        val (pr, poster, ringer) = presenter()
        pr.onRinging("Tracy")
        pr.onShowUiRequested("Tracy"); pr.onShowUiRequested("Tracy")
        assertEquals(listOf("Tracy", "Tracy", "Tracy"), poster.shown)   // same notification id: an update
        assertEquals("the ring starts once", 1, ringer.started.size)
    }

    @Test fun theRingDoesNotWaitForOnShowIncomingCallUi() {
        val (pr, poster, ringer) = presenter()
        pr.onRinging("Tracy")                       // engine / onCreateIncomingConnection — no Telecom UI callback at all
        assertEquals(1, poster.shown.size); assertEquals(1, ringer.started.size)
    }

    @Test fun aLateOnShowIncomingCallUiAfterTheCallEndedNeverResurrectsTheRing() {
        val (pr, poster, ringer) = presenter()
        pr.onRinging("Tracy"); pr.onEnded()
        pr.onShowUiRequested("Tracy")
        assertEquals(1, poster.shown.size); assertEquals(1, ringer.started.size)
        assertFalse(pr.ringing)
    }

    @Test fun answeringDecliningHangingUpOrTimingOutCancelsTheNotificationAndStopsTheRing() {
        // every one of these ends is CallManager -> Notifications.clearIncomingCall -> onEnded
        repeat(4) {
            val (pr, poster, ringer) = presenter()
            pr.onRinging("Tracy"); pr.onEnded()
            assertEquals(1, poster.cancels); assertEquals(1, ringer.stops)
            assertFalse(pr.ringing)
        }
    }

    @Test fun endingWhenNothingRingsIsHarmlessAndStillStopsEverything() {
        val (pr, poster, ringer) = presenter()
        pr.onEnded(); pr.onEnded()
        assertEquals(2, poster.cancels); assertEquals(2, ringer.stops)
    }

    @Test fun aSecondCallAfterTheFirstEndedRingsAgain() {
        val (pr, poster, ringer) = presenter()
        pr.onRinging("A"); pr.onEnded(); pr.onRinging("B")
        assertEquals(listOf("A", "B"), poster.shown); assertEquals(2, ringer.started.size)
    }

    @Test fun theRingStyleIsReadWhenTheCallStartsNotWhenThePresenterIsBuilt() {
        var ring = Ring.NONE
        val p = FakePoster(); val r = FakeRinger()
        val pr = IncomingCallPolicy.Presenter(p, r) { ring }
        ring = Ring.VIBRATE            // the user flipped the switch before the call
        pr.onRinging("Tracy")
        assertEquals(listOf(Ring.VIBRATE), r.started)
    }

    // ---- nothing auto answers ----
    @Test fun anIncomingSessionIsOnlyEverActiveAfterTheEngineSaysSo() {
        val log = mutableListOf<String>()
        val port = object : TelecomPolicy.Port {
            override fun setDialing() { log += "dialing" }
            override fun setRinging() { log += "ringing" }
            override fun setActive() { log += "active" }
            override fun setDisconnected(causeCode: Int) { log += "disconnected" }
            override fun destroy() { log += "destroy" }
        }
        val engine = object : TelecomPolicy.Engine { override fun accept() {}; override fun decline() {}; override fun hangup() {} }
        val s = TelecomPolicy.Session(port, engine, outgoing = false)
        s.onSystemReject(); s.onSystemAbort()
        assertFalse("rejecting or aborting must never connect the call", log.contains("active"))
        assertEquals(listOf("ringing"), log.take(1))
    }

    // ---- wiring guards (source) ----
    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main").isDirectory) d = d.parentFile ?: error("no repo root")
        return d
    }
    private fun src(rel: String) = File(repoRoot(), "android/app/src/main/$rel").readText()

    @Test fun theNotificationIsACallStyleHighPriorityFullScreenCallThatNeverReAlerts() {
        val n = src("java/com/blaineam/haven/core/Notifications.kt")
        assertTrue(n.contains("NotificationCompat.CallStyle.forIncomingCall("))
        assertTrue(n.contains("setFullScreenIntent(full, true)"))
        assertTrue(n.contains("NotificationCompat.CATEGORY_CALL"))
        assertTrue(n.contains("PRIORITY_MAX"))
        assertTrue("a re-post must never alert again", n.contains("setOnlyAlertOnce(true)"))
    }

    @Test fun theCallChannelIsHighImportanceAndSilentBecauseHavenRingsItself() {
        val n = src("java/com/blaineam/haven/core/Notifications.kt")
        assertTrue(n.contains("\"haven.call.v2\""))
        assertTrue(n.contains("NotificationManager.IMPORTANCE_HIGH).apply"))
        assertTrue(n.contains("setSound(null, null)"))
        assertTrue(n.contains("enableVibration(false)"))
        assertTrue("the old noisy channel is deleted", n.contains("deleteNotificationChannel(LEGACY_CALL_CHANNEL)"))
    }

    @Test fun theManifestAllowsFullScreenIntentsAndVibration() {
        val m = src("AndroidManifest.xml")
        assertTrue(m.contains("android.permission.USE_FULL_SCREEN_INTENT"))
        assertTrue(m.contains("android.permission.VIBRATE"))
    }

    @Test fun everyWayACallStopsRingingClearsTheNotificationAndTheRing() {
        val cm = src("java/com/blaineam/haven/core/CallManager.kt")
        // accept and teardown (decline, hang-up, remote hang-up, timeout all end in teardown) both clear it
        assertEquals(2, Regex("""Notifications\.clearIncomingCall\(appContext\)""").findAll(cm).count())
        assertTrue(src("java/com/blaineam/haven/core/CallActionReceiver.kt").contains("Notifications.clearIncomingCall(app)"))
        assertTrue(src("java/com/blaineam/haven/core/Notifications.kt").contains("fun clearIncomingCall(context: Context) = IncomingCallUi.stop(context)"))
    }

    @Test fun theConnectionRingsFromOnCreateIncomingConnectionNotOnlyFromOnShowIncomingCallUi() {
        val t = src("java/com/blaineam/haven/core/TelecomCalls.kt")
        val create = t.substring(t.indexOf("internal fun createIncoming()"), t.indexOf("internal fun incomingRefused()"))
        assertTrue(create.contains("IncomingCallUi.ring("))
        assertTrue(t.contains("IncomingCallUi.reassert("))
        assertTrue("onShowIncomingCallUi is logged", t.contains("onShowIncomingCallUi"))
    }

    @Test fun nothingButTheSessionPortEverActivatesAConnection() {
        val offenders = File(repoRoot(), "android/app/src/main/java").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { Regex("""\bsetActive\(\)""").containsMatchIn(it.readText()) }
            .map { it.name }.toList()
        assertEquals("Connection.setActive() only in the Telecom port/session", setOf("TelecomCalls.kt", "TelecomPolicy.kt"), offenders.toSet())
    }
}
