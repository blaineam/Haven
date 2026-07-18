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
        fun schedule(context: Context) {
            Notifications.ensureChannel(context)
            val req = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                "haven.sync", ExistingPeriodicWorkPolicy.KEEP, req,
            )
        }
    }
}
