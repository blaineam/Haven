package com.blaineam.haven

import android.content.Context
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.ConnectionService
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Android 15's dataSync time budget, for real, on the emulator. The budget is shrunk to a few
 * seconds with `device_config`, so the timeout that took ~6 h on users' phones fires mid-test.
 *
 * The bug this guards (Play vitals, 2026-10): the service only overrode the one-argument
 * `onTimeout(startId)`, which Android calls for shortService. dataSync gets `onTimeout(startId,
 * fgsType)`, whose default does nothing, so the service never left the foreground and the system
 * killed the app with ForegroundServiceDidNotStopInTimeException. A crash takes this test process
 * down with it, so "the test finished" is itself the main assertion.
 */
@RunWith(AndroidJUnit4::class)
class ConnectionServiceTimeoutTest {
    private val instr = InstrumentationRegistry.getInstrumentation()
    private val ctx: Context = instr.targetContext
    private val pkg = ctx.packageName

    private fun sh(cmd: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instr.uiAutomation.executeShellCommand(cmd)).use { it.readBytes().decodeToString() }

    /** (foreground, types) for ConnectionService, from `dumpsys activity services`; null when not running. */
    private fun state(): Pair<Boolean, Int>? {
        val dump = sh("dumpsys activity services $pkg/.core.ConnectionService")
        if (!dump.contains("ServiceRecord")) return null
        val fg = Regex("isForeground=(true|false)").find(dump)?.groupValues?.get(1) == "true"
        val types = Regex("(?:foregroundServiceType|types)=0x([0-9a-fA-F]+)").find(dump)?.groupValues?.get(1)?.toInt(16) ?: 0
        return fg to types
    }

    private fun waitFor(ms: Long, what: String, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { if (cond()) return; Thread.sleep(250) }
        throw AssertionError("timed out after ${ms}ms waiting for $what; service state = ${state()}")
    }

    @Before fun shrinkTheBudget() {
        assumeTrue("the dataSync budget exists from Android 15", Build.VERSION.SDK_INT >= 35)
        sh("device_config set_sync_disabled_for_tests until_reboot")
        sh("device_config put activity_manager data_sync_fgs_timeout_duration $BUDGET_MS")
        // Starting a foreground service from the background needs an exemption; the user's real
        // path is the app's own launch, which the call test drives through the activity.
        sh("cmd deviceidle tempwhitelist -d 120000 $pkg")
        ConnectionService.stop(ctx)
    }

    @After fun restore() {
        ConnectionService.endCall(ctx)
        ConnectionService.stop(ctx)
        sh("device_config delete activity_manager data_sync_fgs_timeout_duration")
        sh("device_config set_sync_disabled_for_tests none")
    }

    @Test fun idle_stay_connected_leaves_the_foreground_when_the_budget_runs_out_and_a_spent_budget_never_crashes() {
        // A fresh budget: bringing the app to the foreground resets it.
        ActivityScenario.launch(MainActivity::class.java).close()
        ConnectionService.start(ctx)
        waitFor(10_000, "the service to go foreground") { state()?.first == true }
        assertEquals("idle Stay connected is dataSync", DATA_SYNC, state()!!.second and DATA_SYNC)

        // The budget runs out → onTimeout(startId, fgsType) must stop us within seconds.
        waitFor(BUDGET_MS + 15_000, "the service to leave the foreground after the timeout") { state()?.first != true }

        // Budget now spent: a background restart is refused by startForeground. The service must
        // stop itself instead of lingering un-promoted (did-not-start-in-time kill ~10 s later).
        ConnectionService.start(ctx)
        Thread.sleep(15_000)
        assertFalse("a refused restart must not leave a foreground service behind", state()?.first == true)
    }

    @Test fun a_call_keeps_its_microphone_through_the_budget_and_never_holds_data_sync() {
        sh("pm grant $pkg android.permission.RECORD_AUDIO")
        val activity = ActivityScenario.launch(MainActivity::class.java)   // while-in-use: mic FGS needs a visible app
        try {
            ConnectionService.startForCall(ctx)
            waitFor(10_000, "the call's service to go foreground with the microphone type") {
                state()?.let { it.first && it.second and MIC != 0 } == true
            }
            assertEquals("a call on Android 15+ must not depend on the dataSync budget", 0, state()!!.second and DATA_SYNC)
            // Well past the budget: still foreground, still holding the mic.
            Thread.sleep(BUDGET_MS + 8_000)
            val s = state()
            assertTrue("the call's service is still foreground after the budget would have run out: $s", s?.first == true)
            assertTrue("…and still holds the microphone type: $s", (s?.second ?: 0) and MIC != 0)
        } finally {
            ConnectionService.endCall(ctx)
            activity.close()
        }
    }

    private companion object {
        const val BUDGET_MS = 8_000L
        const val DATA_SYNC = 0x1    // ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        const val MIC = 0x80         // ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    }
}
