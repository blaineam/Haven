package com.blaineam.haven

import android.app.Application
import android.content.Context
import android.os.Bundle
import androidx.test.runner.AndroidJUnitRunner
import com.blaineam.haven.core.HavenOffline

/**
 * The instrumentation runner for `connectedDebugAndroidTest` — it exists to arm [HavenOffline]
 * before anything else in the process runs. This is the Android counterpart of
 * `app.launchEnvironment["HAVEN_NO_NET"] = "1"` in `HavenUITests.swift`.
 *
 * Why a runner and not a `@Before`: the app process is shared by every test, and the very first
 * thing it does is `HavenApplication.onCreate`, which schedules [com.blaineam.haven.core.SyncWorker]
 * — a periodic mailbox poll and backup drain. A per-test hook runs far too late, and a per-test hook
 * is also something each new test has to remember. [onCreate] here runs before the Application is
 * instantiated, so the whole process is hermetic by construction.
 *
 * That matters because these tests run on a device that carries a **real** identity: an emulator
 * that has ever been used for QA holds relay records in prefs, and the relay HTTP lane needs no iroh
 * node to use them. Apple's UI tests learned this the hard way — a stranger's inbound hello raised a
 * live connection request in the middle of a run and made an assertion flaky.
 *
 * `-e haven_no_net false` turns it back off for a test run that genuinely wants the wire.
 */
class HavenTestRunner : AndroidJUnitRunner() {

    /** What this run decided, so [newApplication] re-asserts the decision rather than overriding it. */
    private var offline = true

    override fun onCreate(arguments: Bundle?) {
        // Default ON: a test that wants the network must ask for it, never the other way round.
        offline = arguments?.getString("haven_no_net") != "false"
        HavenOffline.set(offline)
        super.onCreate(arguments)
    }

    /**
     * Belt and braces: the Application is instantiated from here, so re-assert the gate immediately
     * before `onCreate` runs rather than trusting the ordering above to never change.
     */
    override fun newApplication(cl: ClassLoader?, className: String?, context: Context?): Application {
        HavenOffline.set(offline)
        return super.newApplication(cl, className, context)
    }
}
