package com.blaineam.haven.core

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Periodic background sync (serverless, like the iOS BGAppRefreshTask): poll the circle relay
 * mailbox and post local notifications for anything new. Min interval on Android is 15 minutes.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        // haven_no_net: `HavenApplication.onCreate` schedules this, and that Application is created
        // in the instrumented-test process too — so on a device carrying a real identity this was a
        // periodic mailbox poll running underneath `connectedDebugAndroidTest`.
        if (HavenOffline.enabled) return Result.success()
        // A push wake (FcmPush) starts a UI-less process: bring the call stack up BEFORE the first poll, or an
        // incoming call frame is consumed with no router and the ring is lost (see CallRuntime.ensureReadyNow).
        if (inputData.getBoolean(EXTRA_PUSH_WAKE, false)) CallRuntime.ensureReadyNow(applicationContext)
        runCatching {
            HavenNet.init(applicationContext)
            HavenNet.pollMailbox()
            // Retry any of MY media whose blob never reached a relay (e.g. a story posted just before the
            // app was killed, its upload cut off mid-flight). The pending queue is persisted, so this
            // background pass can finish it even when the app isn't in the foreground.
            HavenNet.drainPersistedBackups()
        }
        return Result.success()
    }

    companion object {
        /** Input flag set by [HavenFcmService]: this run was started by a content-free push wake. */
        const val EXTRA_PUSH_WAKE = "push_wake"

        fun schedule(context: Context) {
            Notifications.ensureChannel(context)
            if (HavenOffline.enabled) return   // haven_no_net: nothing periodic to enqueue
            val req = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                "haven.sync", ExistingPeriodicWorkPolicy.KEEP, req,
            )
        }
    }
}
