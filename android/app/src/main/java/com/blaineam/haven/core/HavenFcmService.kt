package com.blaineam.haven.core

import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives the content-free FCM doorbell. The push carries nothing readable: on a wake we simply run
 * the same mailbox pull the periodic worker does (which also drains the live-call lane), so a
 * message or ring that arrived while the process was dead is fetched and decrypted locally, then
 * notified through the normal inbound path.
 */
class HavenFcmService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        if (FcmPolicy.shouldRun(FcmPush.isEnabled(this), FcmPush.configured(), true)) HavenNet.registerAndroidPushToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (!FcmPolicy.isWake(message.data)) return
        if (!FcmPush.isEnabled(this)) return   // opted out since the token was issued — ignore
        // Expedited so it runs now even though FCM only gives a few seconds of service time.
        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
            "haven.fcm.wake", ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<SyncWorker>()
                .setInputData(androidx.work.workDataOf(SyncWorker.EXTRA_PUSH_WAKE to true))
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build())
    }
}
