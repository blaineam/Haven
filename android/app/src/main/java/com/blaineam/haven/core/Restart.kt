package com.blaineam.haven.core

import android.content.Context
import android.content.Intent

/**
 * "Start over": wipe identity, profile, contacts, engine state and media, then relaunch the
 * app from a clean process so every singleton is rebuilt with a fresh identity (parity with the
 * iOS "Erase everything & start over"). A full process restart is the simplest way to guarantee
 * no stale in-memory account/engine survives.
 */
/// Every store wiped below commits SYNCHRONOUSLY (`commit()`, not `apply()`), and it has to.
/// `apply()` queues the write and relies on the framework flushing it at a lifecycle boundary —
/// but [restartApp] ends the process with `Runtime.exit(0)`, which skips that flush entirely. So
/// the wipe raced the exit and routinely lost: `onboarded` stayed true in prefs, and "start over"
/// came back to the old identity's app with no welcome screen. Blocking here is correct — this is
/// a one-shot teardown, and the process is about to die anyway.
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
    // THE DEVICE IDENTITY MUST GO TOO — this is not optional and it is not cosmetic.
    //
    // "Start over" that keeps the device id produces a device whose id is unchanged while its
    // ACCOUNT is new, and every peer still maps that device to the OLD account. Their frames then
    // fail the declared-vs-signer check and are dropped as forgeries ("transport device X maps to
    // <old acct>, signer is <new acct>"), so calls hang up the instant they are answered, and media
    // sealed under it can never be opened by anyone. A reset that leaves a colliding identity behind
    // is worse than no reset at all, because the collision is invisible and outlives the app.
    //
    // These clears are also why they must be synchronous (see the note above): the seed surviving a
    // wipe is exactly what recreates the same device id on next launch.
    runCatching { DeviceKeyStore.clear() }
    runCatching { DeviceCredentialStore.clear() }
    runCatching { DeviceRosterManager.clear() }
    runCatching { SelfSyncKeyStore.clear() }
    runCatching { SeedlessStore.clear() }
    // The node ticket is the device's published address, derived from the key we just destroyed.
    // Leaving the file behind re-advertises an identity that no longer exists.
    runCatching { java.io.File(context.applicationContext.filesDir, "node-ticket.txt").delete() }
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
