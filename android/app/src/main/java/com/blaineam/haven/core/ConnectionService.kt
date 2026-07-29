package com.blaineam.haven.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * The serverless equivalent of iOS's APNs relay: a foreground service that keeps the Haven process
 * (and its iroh node) alive so inbound posts/DMs/calls arrive in REAL TIME and fire local
 * notifications — no FCM, no Google, no push server. Opt-in ("Stay connected" in Settings); when
 * off, the WorkManager periodic sync still catches up every ~15 min.
 */
class ConnectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        // Screen-sharing in a call needs the foreground service to carry the mediaProjection type
        // (Android 14+ requires it before MediaProjection can capture). We add it to the running
        // data-sync service while a share is active.
        val projection = intent?.getBooleanExtra(EXTRA_PROJECTION, false) == true
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                if (projection) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                // Read the FLAG, not just this intent's extra: the service gets (re)started for
                // several unrelated reasons during a call, and any plain restart that dropped the
                // microphone type would cut capture mid-call exactly as if it were never declared.
                if (micWanted && Build.VERSION.SDK_INT >= 34) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIF_ID, notification(), type)
            } else {
                startForeground(NOTIF_ID, notification())
            }
        } catch (e: Exception) {
            // Android 15 caps a dataSync FGS at ~6h/day; once exhausted, startForeground throws
            // ForegroundServiceStartNotAllowedException. Don't crash — keep the node running as a plain
            // background service; the WorkManager periodic sync still catches up every ~15 min.
            Log.w(TAG, "foreground start blocked, running in background: ${e.message}")
            HavenNet.init(applicationContext); HavenNet.start()
            return START_STICKY
        }
        HavenNet.init(applicationContext)
        HavenNet.start()
        return START_STICKY
    }

    /**
     * Android 15+: the dataSync time budget is about to expire. Stop foreground GRACEFULLY here, or
     * the system kills us with ForegroundServiceDidNotStopInTimeException (a hard crash). Background
     * delivery falls back to the periodic WorkManager sync.
     */
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "dataSync FGS time limit reached — stopping foreground")
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        stopSelf()
    }

    private fun notification(): Notification {
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, open ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Haven is connected")
            .setContentText("Receiving posts, messages and calls in real time")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pi)
            .build()
    }

    companion object {
        private const val TAG = "ConnectionService"
        private const val CHANNEL = "haven.connection"
        private const val NOTIF_ID = 42
        private const val EXTRA_PROJECTION = "projection"
        private const val PREF = "haven.fg"
        private const val KEY = "enabled"

        private fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(CHANNEL, "Connection", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while Haven stays connected in the background"
                    setShowBadge(false)
                }
                ctx.getSystemService(NotificationManager::class.java)?.createNotificationChannel(ch)
            }
        }

        // Default ON: a P2P app is most useful staying reachable for the circle. Users who turn
        // it off have that choice persisted (false is written explicitly).
        fun isEnabled(ctx: Context): Boolean =
            ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).getBoolean(KEY, true)

        fun setEnabled(ctx: Context, on: Boolean) {
            ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
            if (on) start(ctx) else stop(ctx)
        }

        fun start(ctx: Context) {
            // NEVER let this kill the app.
            //
            // Android refuses `startForegroundService` while the process is background-restricted
            // and signals it by THROWING `ForegroundServiceStartNotAllowedException`. Uncaught, that
            // takes the whole process down — and the moment it is most likely is exactly the moment
            // it hurts most: coming to the foreground to answer a call. The app died mid-call, so
            // the far end never got a hangup and sat there believing the call was still up, while
            // the user saw the call vanish having touched nothing.
            //
            // "Stay connected" failing to start is a degraded state, not a fatal one: the periodic
            // sync still runs and the next foreground pass retries. Log it and carry on.
            runCatching {
                ContextCompat.startForegroundService(ctx, Intent(ctx, ConnectionService::class.java))
            }.onFailure {
                android.util.Log.w("ConnectionService",
                    "foreground service start refused (${it.javaClass.simpleName}) — staying on periodic sync")
            }
        }

        /** True while a call holds the mic. Sticky across service restarts — see onStartCommand. */
        @Volatile private var micWanted = false

        /** (Re)start the service carrying the `microphone` type, so capture survives the user
         *  switching apps. Android 14+ cuts a backgrounded app's mic unless a foreground service
         *  declares it; the symptom is one-way audio — they hear you fine, you hear nothing back. */
        fun startForCall(ctx: Context) {
            micWanted = true
            runCatching {
                ContextCompat.startForegroundService(ctx, Intent(ctx, ConnectionService::class.java))
            }.onFailure {
                android.util.Log.w("ConnectionService", "call service start refused: ${it.message}")
            }
        }

        /** Drop the mic type when the call ends — holding it idle is a standing privacy indicator. */
        fun endCall(ctx: Context) {
            if (!micWanted) return
            micWanted = false
            // Only re-assert the plain service if the user actually wants it running; otherwise a
            // call would silently switch "Stay connected" on for them.
            if (ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).getBoolean(KEY, false)) start(ctx)
            else stop(ctx)
        }

        /** (Re)start the foreground service with the mediaProjection type added — call right before
         *  starting a screen-share capture so Android 14+ permits MediaProjection. */
        fun startForProjection(ctx: Context) {
            // Same guard as [start]: a refused promotion must not crash a live call.
            runCatching {
                ContextCompat.startForegroundService(
                    ctx, Intent(ctx, ConnectionService::class.java).putExtra(EXTRA_PROJECTION, true))
            }.onFailure {
                android.util.Log.w("ConnectionService", "projection service start refused: ${it.message}")
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, ConnectionService::class.java))
        }

        /** Called on app launch — restore the service if the user left it on. */
        fun restoreIfEnabled(ctx: Context) {
            if (isEnabled(ctx)) start(ctx)
        }
    }
}
