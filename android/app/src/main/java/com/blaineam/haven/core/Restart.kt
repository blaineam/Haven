package com.blaineam.haven.core

import android.content.Context
import android.content.Intent

/**
 * "Start over": wipe identity, profile, contacts, engine state and media, then relaunch the
 * app from a clean process so every singleton is rebuilt with a fresh identity (parity with the
 * iOS "Erase everything & start over"). A full process restart is the simplest way to guarantee
 * no stale in-memory account/engine survives.
 */
fun startOver(context: Context) {
    runCatching { HavenCore.get(context).reset() }
    runCatching { ProfileStore.get(context).reset() }
    runCatching { HavenNet.reset() }
    runCatching { LocalMedia.clear() }
    // Persistent side stores the engine/profile reset didn't cover — clear them too so nothing from the
    // old identity survives the wipe (in-memory state is gone via the hard process restart below).
    runCatching { AvatarStore.clear() }
    runCatching { CircleLock.reset() }
    runCatching { RelayNudge.reset() }
    runCatching { CircleRemovals.clear() }
    runCatching { ContactRemovals.clear() }
    runCatching { CircleDeletion.clear() }
    runCatching { Presign.reset() }
    runCatching { SelfSyncCoordinator.reset() }
    runCatching { DeviceKeyStore.clear() }
    runCatching { DeviceCredentialStore.clear() }
    runCatching { DeviceRosterManager.clear() }
    restartApp(context)
}

/** Relaunch the app from a clean process (used after adopting a transferred identity). */
fun restartApp(context: Context) {
    val ctx = context.applicationContext
    val intent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK) }
    ctx.startActivity(intent)
    Runtime.getRuntime().exit(0)
}
