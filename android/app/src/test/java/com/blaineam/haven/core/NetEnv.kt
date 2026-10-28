package com.blaineam.haven.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import java.lang.reflect.InvocationTargetException
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * One "booted HavenNet" for a JVM test: a context, a [FakeSocial] engine, a [FakeRelayServer] holding
 * the only relay, and the account identity wired in WITHOUT the Rust core (the engine handle that
 * [HavenCore] wraps cannot be built here, so the object is allocated blank and the account hex comes
 * from the seedless store the core falls back to). No iroh node exists, so every dial is skipped and the
 * relay's signed-HTTP lane is the only transport a test exercises.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NetEnv(
    val me: String = "a1".repeat(32),
    val device: String = "d1".repeat(32),
    val relayHex: String = "ab".repeat(32),
    val token: String = "relay-token",
) {
    val ctx = FakeContext()
    val social = FakeSocial()
    val relay = FakeRelayServer()

    private val savedSigner = HavenNet.httpAuthSigner
    private val savedPush = HavenNet.pushRelayBase

    fun up(withRelay: Boolean = true): NetEnv {
        PushPolicy.reset()   // the self-sync burst limiter is process-wide; every test starts with a full window
        Dispatchers.setMain(UnconfinedTestDispatcher())
        relay.start()
        HavenNet.pushRelayBase = relay.base   // never the real push worker
        social.myNode = me
        social.bundle = ByteArray(40) { 0x11 }
        social.signedProfile = byteArrayOf(1, 2, 3)
        social.myDevice = device
        set("appContext", ctx)
        set("social", social)
        set("profile", ProfileStore.get(ctx))
        val unsafe = sun.misc.Unsafe::class.java.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as sun.misc.Unsafe
        set("core", unsafe.allocateInstance(HavenCore::class.java))
        SeedlessStore::class.java.getDeclaredField("prefs").apply { isAccessible = true }
            .set(SeedlessStore, FakePrefs().also { it.data["account_node_hex"] = me })
        LocalMedia.init(ctx)
        CircleDeletion.init(ctx)
        DmRead.init(ctx)
        PinnedMediaStore.init(ctx)
        Presign.init(ctx)
        CircleRemovals.init(ctx)
        MediaWantedStore.init(ctx)
        EvictedMediaStore.init(ctx)
        ContactRemovals.init(ctx)
        ctx.filesDir.resolve("media").mkdirs()
        field("ready").setBoolean(HavenNet, true)
        field("keylessRescopeDelayMs").setLong(HavenNet, 3_600_000L)   // re-scope only when a test asks for it
        set("keylessWatch", KeylessScopeWatch())                        // and each test seeds its own
        HavenNet.isForeground = true   // notifications need a real Context; the foreground app posts none
        resetPollFlags()
        field("circlesCache").set(HavenNet, null)
        field("seenMailboxLoaded").setBoolean(HavenNet, true)
        field("sweptRestoreParts").setBoolean(HavenNet, true)
        field("backedUpLoaded").setBoolean(HavenNet, true)
        field("uploadProgressLoaded").setBoolean(HavenNet, true)
        field("lastHealMs").setLong(HavenNet, 0L)
        clearAll()
        HavenNet.httpAuthSigner = { t, method, _, body -> "Haven $t $method ${body.size}" }
        if (withRelay) addRelay()
        return this
    }

    /** The relay under test becomes the all-circles default, reachable over its HTTP interface. */
    fun addRelay(hex: String = relayHex, url: String = relay.base) {
        entries()[hex] = HavenNet.RelayEntry(hex, "r", true, 0, false, httpUrls = listOf(url), httpToken = token)
        HavenNet.setDefaultRelay(hex)
    }

    /**
     * Quiesce HavenNet's fire-and-forget work: cancel and join every job on its scope. A launched job that
     * outlives its test and then throws is an uncaught coroutine exception that kotlinx-coroutines-test
     * pins on whichever `runTest` runs next in the JVM, so no test is allowed to leave one running.
     */
    fun settle() {
        val job = (field("scope").get(HavenNet) as CoroutineScope).coroutineContext[Job] ?: return
        runBlocking {
            withTimeoutOrNull(20_000) {
                job.children.toList().forEach { it.cancel() }
                relay.stop()   // a job blocked in an HTTP call ignores cancellation until its socket closes
                job.children.toList().joinAll()
            }
        }
    }

    fun down() {
        settle()
        HavenNet.callRouter = null
        field("ready").setBoolean(HavenNet, false)
        HavenNet.isForeground = false
        resetPollFlags()
        field("circlesCache").set(HavenNet, null)
        clearAll()
        HavenNet.setDefaultRelay(null)
        HavenNet.httpAuthSigner = savedSigner
        HavenNet.pushRelayBase = savedPush
        Dispatchers.resetMain()
        ctx.filesDir.deleteRecursively()
    }

    private fun resetPollFlags() {
        for (flag in listOf("launchHeadsPublished", "pollMailboxInFlight", "pollMailboxQueued"))
            (field(flag).get(HavenNet) as java.util.concurrent.atomic.AtomicBoolean).set(false)
    }

    private fun clearAll() {
        (field("relayScope").get(HavenNet) as RelayScope).invalidate()   // membership snapshot is per-test state
        (field("resealPacing").get(HavenNet) as ResealPacing).clear()    // the global ask budget is per-test state
        for (name in listOf("relayEntries", "relayNodes", "seenMailbox", "refusedUntilMs", "refusedStreak", "httpUrlBad",
            "mailboxListDigests", "relayHealth", "pendingSeenMarks", "deviceHints", "initiated", "helloOffered",
            "backedUp", "uploadProgress", "scopeRefusedUntil", "rosterNeeded", "rosterPublished", "rosterPullAt",
            "lastEnrollMs", "lastEnrollRelays", "lastEnrollMembers", "lastEnrollLanded", "erasedRelays", "relayInterfaceRefreshMs", "replacedInterfaces",
            "mediaQueueKeys", "restoreInFlight", "fastReq", "mediaReqAt", "resealAskedAt", "resealTries", "unopenableMedia",
            "mediaServedAt", "mediaServing", "announcedMediaAt", "countedArrivals", "requestedRefs", "pendingBackups",
            "probedThisSession", "verifiedOpen", "fetchedFrom", "transferWatch", "waitingForSenderMedia", "unavailableMedia",
            "forgotAtRelays", "clearedRelayForgets", "suppressedRelays", "announcedRelayNodes", "seenRelay", "incomingMedia", "chunkProgressAt", "servedAt", "servingNow", "hintOnUpload", "backupReverifiedAt", "serveCircleCache", "serveRoleCache", "purgedMediaCircles", "derpDeadUntilMs", "initiatedAt", "historyAskedBefore")) {
            when (val v = field(name).get(HavenNet)) {
                is MutableMap<*, *> -> v.clear()
                is MutableCollection<*> -> v.clear()
            }
        }
        HavenNet.contacts.clear(); HavenNet.blocked.clear(); HavenNet.pending.clear()
        // The media queue has ONE consumer coroutine, started once per process. settle() cancels it, so the next
        // boot must be allowed to start its own, and nothing the old one left queued may run in the new one.
        field("mediaQueueStarted").setBoolean(HavenNet, false)
        for (ch in listOf("mediaQueue", "mediaPriorityQueue")) {
            val c = field(ch).get(HavenNet) as kotlinx.coroutines.channels.Channel<*>
            while (c.tryReceive().isSuccess) { /* drop */ }
        }
    }

    @Suppress("UNCHECKED_CAST")
    fun entries() = field("relayEntries").get(HavenNet) as MutableMap<String, HavenNet.RelayEntry>

    /** Associate [relayHex] with [circleId] the way a circle's relay announce does. */
    @Suppress("UNCHECKED_CAST")
    fun bindCircleRelay(circleId: String, hex: String = relayHex) {
        val m = field("relayNodes").get(HavenNet) as MutableMap<String, MutableList<String>>
        m.getOrPut(circleId) { RelayNodeMap.newList() }.add(hex)
    }

    fun seen(): MutableSet<*> = field("seenMailbox").get(HavenNet) as MutableSet<*>

    companion object {
        fun field(name: String) = HavenNet::class.java.getDeclaredField(name).apply { isAccessible = true }
        fun set(name: String, v: Any?) { field(name).set(HavenNet, v) }

        /** Call a private (optionally suspending) HavenNet function by name. */
        fun call(name: String, vararg args: Any?): Any? = callOn(HavenNet, name, *args)

        /** Call a private (optionally suspending) function of any object by name. */
        fun callOn(target: Any, name: String, vararg args: Any?): Any? {
            val plain = target.javaClass.declaredMethods.firstOrNull { it.name == name && it.parameterCount == args.size }
            val susp = target.javaClass.declaredMethods.firstOrNull {
                it.name == name && it.parameterCount == args.size + 1 && it.parameterTypes.last() == kotlin.coroutines.Continuation::class.java
            }
            return try {
                if (susp != null) runBlocking {
                    susp.isAccessible = true
                    suspendCancellableCoroutine<Any?> { c ->
                        try {
                            val r = susp.invoke(target, *args, c)
                            if (r !== COROUTINE_SUSPENDED) c.resume(r)
                        } catch (e: InvocationTargetException) { c.resumeWithException(e.targetException) }
                    }
                } else {
                    requireNotNull(plain) { "no ${target.javaClass.simpleName}.$name/${args.size}" }.apply { isAccessible = true }.invoke(target, *args)
                }
            } catch (e: InvocationTargetException) { throw e.targetException }
        }
    }
}
