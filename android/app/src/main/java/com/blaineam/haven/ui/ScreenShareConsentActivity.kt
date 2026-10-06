package com.blaineam.haven.ui

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import com.blaineam.haven.core.CallManager
import com.blaineam.haven.core.QaStats
import com.blaineam.haven.core.ScreenSharePolicy

/**
 * Hosts the system MediaProjection consent flow in its OWN task (see the manifest's taskAffinity).
 *
 * The consent dialog and the Android 14+ app chooser are system activities stacked on whichever
 * task asked for them. Asked from MainActivity, that was Haven's task — and MainActivity is
 * `singleTask`. Choosing "A single app" → Haven relaunches Haven's launcher intent, the singleTask
 * relaunch clears everything above MainActivity in its task, the chooser is destroyed before it can
 * report, and the share comes back RESULT_CANCELED ("I picked Haven and nothing happened"). From a
 * separate task the chooser survives Haven's task coming forward and hands the grant back here.
 *
 * The result is registered WITHOUT a lifecycle owner on purpose: when another app (or Haven's own
 * task) is brought forward by the chooser this activity is stopped, and the platform still delivers
 * the MediaProjection result to a stopped activity — a lifecycle-bound launcher would sit on it
 * until the user came back to a task that is excluded from recents.
 */
class ScreenShareConsentActivity : ComponentActivity() {
    private var launcher: ActivityResultLauncher<Intent>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Transparent bars over the call behind us, the non-deprecated way (the theme used to set
        // android:statusBarColor / navigationBarColor, which API 35 deprecates and ignores).
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val l = activityResultRegistry.register(RESULT_KEY, ActivityResultContracts.StartActivityForResult()) { r ->
            val outcome = ScreenSharePolicy.consentOutcome(r.resultCode, r.data != null)
            QaStats.shareConsent = outcome
            Log.i(ScreenSharePolicy.LOG_TAG, "consent result: $outcome")
            val data = r.data
            if (outcome == ScreenSharePolicy.CONSENT_GRANTED && data != null) CallManager.startScreenShare(r.resultCode, data)
            finish()
        }
        launcher = l
        // A recreated activity (rotation, process restore) already has the prompt up; the registry
        // restores the pending request under the same key.
        if (savedInstanceState == null) {
            val mpm = getSystemService(MediaProjectionManager::class.java)
            if (mpm == null) { finish(); return }
            QaStats.shareConsentAttempts++
            l.launch(mpm.createScreenCaptureIntent())
        }
    }

    override fun onDestroy() {
        launcher?.unregister()
        launcher = null
        super.onDestroy()
    }

    companion object {
        private const val RESULT_KEY = "haven.screenshare.consent"

        /** Ask the user to share their screen (the call's share button and the QA `screen_share` op). */
        fun launch(context: Context) {
            // NEW_TASK so the manifest's taskAffinity applies and the consent flow gets its own task.
            context.startActivity(Intent(context, ScreenShareConsentActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}
