package com.blaineam.haven.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
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
    /** True once startForeground has succeeded for this instance (until it leaves the foreground). */
    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        // Screen-sharing in a call needs the foreground service to carry the mediaProjection type
        // (Android 14+ requires it before MediaProjection can capture). We add it to the running
        // data-sync service while a share is active.
        // Sticky like the mic: any unrelated restart during a share must keep the projection type,
        // or Android stops the MediaProjection out from under the capture.
        val projection = projectionWanted || intent?.getBooleanExtra(EXTRA_PROJECTION, false) == true
        try {
            // Types come from [ForegroundTypes]: during a call/share on Android 15+ there is no
            // dataSync, so the call's mic and capture never depend on the idle-sync time budget.
            // The flags (not just this intent's extra) decide: the service gets (re)started for
            // several unrelated reasons during a call, and any plain restart that dropped the
            // microphone type would cut capture mid-call exactly as if it were never declared.
            val type = ForegroundTypes.forState(Build.VERSION.SDK_INT, micWanted, projection)
            if (type != 0) startForeground(NOTIF_ID, notification(), type)
            else startForeground(NOTIF_ID, notification())
            inForeground = true
            if (projection) projectionReady(true)
        } catch (e: Exception) {
            if (projection) {
                Log.w(ScreenSharePolicy.LOG_TAG, "mediaProjection FGS promotion refused: ${e.javaClass.simpleName}: ${e.message}")
                projectionReady(false)
            }
            // Refused — most often Android 15's dataSync budget is used up for today
            // (ForegroundServiceStartNotAllowedException). Don't crash, and don't linger as a
            // started-but-never-foreground service either (that ends in a did-not-start-in-time
            // kill). The engine runs in the process regardless; the WorkManager periodic sync
            // catches up every ~15 min and the next launch tries again.
            bootEngine()
            // Mid-call and already foreground (e.g. the screen-share upgrade was refused): keep it
            // exactly as it is — stopping would take the call's mic with it.
            if (inForeground && (micWanted || projection)) return START_STICKY
            // Otherwise leave: never hold a call's mic type idle (a standing privacy indicator).
            Log.w(TAG, "foreground start refused (${e.javaClass.simpleName}) — stopping; periodic sync covers it: ${e.message}")
            if (inForeground) runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
            inForeground = false
            stopSelf()
            return START_NOT_STICKY
        }
        bootEngine()
        return START_STICKY
    }

    /**
     * Bring the engine up OFF the main thread. onStartCommand runs on main, and a sticky restart
     * (the process came back after a crash, or the system relaunched the service) reaches here
     * before anything else has booted the engine — so `HavenNet.init` ran its whole cold boot
     * (identity keystore, engine construct, state import) on main, parked behind the warm-up
     * thread's HavenCore monitor for 23.6 s on the e2e emulator (2026-10-01 08:45), and the input
     * dispatch / SystemJobService starts queued behind it timed out as ANRs. `start()` only arms
     * async lanes, so it is safe from the boot thread.
     */
    private fun bootEngine() {
        val app = applicationContext
        EngineBoot.background { HavenNet.init(app); HavenNet.start() }
    }

    /**
     * Android 15+: the dataSync time budget ran out. This is the callback the system actually
     * calls for dataSync (API 35, with the type) — the one-argument [onTimeout] below is only ever
     * called for shortService, so handling just that one let every long "Stay connected" session
     * end in ForegroundServiceDidNotStopInTimeException (Play vitals, 2026-10). We must leave the
     * foreground within seconds: during a call/share re-promote WITHOUT dataSync (the mic and
     * capture types have no budget); otherwise stop. Background delivery falls back to the periodic
     * WorkManager sync.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        val keep = ForegroundTypes.afterTimeout(Build.VERSION.SDK_INT, micWanted, projectionWanted)
        if (keep != null) {
            Log.w(TAG, "dataSync FGS time limit reached mid-call — keeping only the call's types")
            val ok = runCatching { startForeground(NOTIF_ID, notification(), keep) }.isSuccess
            if (ok) return
        }
        Log.w(TAG, "dataSync FGS time limit reached — stopping foreground")
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        inForeground = false
        stopSelf()
    }

    /** Android 14's timeout — only ever called for shortService, which Haven doesn't use. Same exit. */
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "FGS timeout — stopping foreground")
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        inForeground = false
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
            onMain { projectionWanted = false; projectionCallback = null }
            if (!micWanted) return
            micWanted = false
            // Only re-assert the plain service if the user actually wants it running; otherwise a
            // call would silently switch "Stay connected" on for them.
            if (ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).getBoolean(KEY, false)) start(ctx)
            else stop(ctx)
        }

        /** True while a screen share holds the projection type. Sticky — see onStartCommand. */
        @Volatile private var projectionWanted = false

        /** Waiting for [onStartCommand] to finish the mediaProjection promotion. Main thread only —
         *  CallManager calls in from its own call thread, so every projection entry point below
         *  re-posts itself to main IN ORDER via [onMain] (a start followed by a stop must not land
         *  as stop-then-start). */
        private var projectionCallback: ((Boolean) -> Unit)? = null
        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        private fun onMain(block: () -> Unit) {
            if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) block() else mainHandler.post(block)
        }
        private val projectionTimeout = Runnable { projectionReady(false) }
        /** onStartCommand runs on the main thread, but it is QUEUED behind whatever posted the
         *  start — normally it lands within a frame or two. Past this, give up waiting. */
        private const val PROJECTION_READY_TIMEOUT_MS = 3_000L

        private fun projectionReady(ok: Boolean) {
            mainHandler.removeCallbacks(projectionTimeout)
            val cb = projectionCallback ?: return
            projectionCallback = null
            if (!ok && !projectionWanted) return
            cb(ok)
        }

        /**
         * (Re)start the foreground service with the mediaProjection type added, and call [onReady]
         * (on the main thread) once `startForeground(…MEDIA_PROJECTION)` has actually RUN.
         *
         * Android 14+ throws a SecurityException from `getMediaProjection` unless a service of that
         * type is already in the foreground — and `startForegroundService` only QUEUES the start:
         * `onStartCommand` runs later on the main thread, i.e. only after the caller returns. The old
         * fire-and-continue version therefore started capture before the promotion every time,
         * swallowed the SecurityException, and burned the single-use consent token: the share
         * silently never started. [onReady] gets `false` if the promotion was refused or timed
         * out; the caller may still try (pre-14 does not need it).
         */
        fun startForProjection(ctx: Context, onReady: (Boolean) -> Unit) = onMain {
            projectionWanted = true
            projectionCallback?.invoke(false)   // a stale waiter never hangs
            projectionCallback = onReady
            mainHandler.removeCallbacks(projectionTimeout)
            mainHandler.postDelayed(projectionTimeout, PROJECTION_READY_TIMEOUT_MS)
            // Same guard as [start]: a refused promotion must not crash a live call.
            runCatching {
                ContextCompat.startForegroundService(
                    ctx, Intent(ctx, ConnectionService::class.java).putExtra(EXTRA_PROJECTION, true))
            }.onFailure {
                android.util.Log.w("ConnectionService", "projection service start refused: ${it.message}")
                mainHandler.post { projectionReady(false) }
            }
        }

        /** Drop the mediaProjection type when the share ends, keeping the call's own service. */
        fun stopProjection(ctx: Context) = onMain { stopProjectionOnMain(ctx) }

        private fun stopProjectionOnMain(ctx: Context) {
            if (!projectionWanted) return
            projectionWanted = false
            mainHandler.removeCallbacks(projectionTimeout)
            projectionCallback = null
            if (micWanted || ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).getBoolean(KEY, false)) {
                runCatching {
                    ContextCompat.startForegroundService(ctx, Intent(ctx, ConnectionService::class.java))
                }
            } else {
                stop(ctx)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, ConnectionService::class.java))
        }

        /** Called on app launch — restore the service if the user left it on. */
        fun restoreIfEnabled(ctx: Context) {
            // haven_no_net: this service exists to keep the iroh node alive (Haven has no FCM), and
            // under the flag there is no node to keep.
            if (HavenOffline.enabled) return
            if (isEnabled(ctx)) start(ctx)
        }
    }
}
