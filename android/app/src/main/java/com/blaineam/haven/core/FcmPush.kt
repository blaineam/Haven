package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import com.blaineam.haven.BuildConfig
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging

/**
 * Optional, opt-in FCM wake-up (default OFF). See [FcmPolicy] for the privacy model and
 * docs/NOTIFICATIONS.md for the owner's setup. Everything here degrades to a no-op: no Firebase values
 * in the build, no Play services, or the user has not opted in → Firebase is never initialised and
 * [ConnectionService] carries delivery exactly as before.
 */
object FcmPush {
    private const val TAG = "FcmPush"

    fun isEnabled(ctx: Context): Boolean =
        ctx.getSharedPreferences(FcmPolicy.PREF, Context.MODE_PRIVATE).getBoolean(FcmPolicy.KEY, false)

    fun configured(): Boolean = FcmPolicy.configured(
        BuildConfig.FCM_PROJECT_ID, BuildConfig.FCM_APP_ID, BuildConfig.FCM_API_KEY, BuildConfig.FCM_SENDER_ID)

    fun playServices(ctx: Context): Boolean = runCatching {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS
    }.getOrDefault(false)

    /** Whether this build + phone CAN do FCM at all (drives whether Settings offers the switch). */
    fun available(ctx: Context): Boolean = configured() && playServices(ctx)

    fun setEnabled(ctx: Context, on: Boolean) {
        ctx.getSharedPreferences(FcmPolicy.PREF, Context.MODE_PRIVATE).edit().putBoolean(FcmPolicy.KEY, on).apply()
        if (on) sync(ctx) else disable(ctx)
    }

    /** Idempotent: (re)initialise Firebase and register the current token when opted in. Safe to call
     *  on every launch; does nothing (and touches no Firebase class) when it should not run. */
    fun sync(ctx: Context) {
        if (HavenOffline.enabled) return
        if (!FcmPolicy.shouldRun(isEnabled(ctx), configured(), playServices(ctx))) return
        runCatching {
            if (FirebaseApp.getApps(ctx).isEmpty()) {
                FirebaseApp.initializeApp(ctx, FirebaseOptions.Builder()
                    .setProjectId(BuildConfig.FCM_PROJECT_ID)
                    .setApplicationId(BuildConfig.FCM_APP_ID)
                    .setApiKey(BuildConfig.FCM_API_KEY)
                    .setGcmSenderId(BuildConfig.FCM_SENDER_ID)
                    .build())
            }
            val fm = FirebaseMessaging.getInstance()
            fm.isAutoInitEnabled = true
            fm.token.addOnSuccessListener { token -> if (!token.isNullOrEmpty()) HavenNet.registerAndroidPushToken(token) }
        }.onFailure { Log.w(TAG, "FCM init failed (${it.javaClass.simpleName}) — staying on the foreground service") }
    }

    /** Opt-out: drop the token so Google forgets this install; the worker prunes its copy on the next send. */
    private fun disable(ctx: Context) {
        runCatching {
            if (FirebaseApp.getApps(ctx).isNotEmpty()) {
                val fm = FirebaseMessaging.getInstance()
                fm.isAutoInitEnabled = false
                fm.deleteToken()
            }
        }
    }
}
