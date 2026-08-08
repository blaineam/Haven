package com.blaineam.haven.core

import android.content.Context
import android.util.Base64
import android.util.Log
import com.blaineam.haven.BuildConfig
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.CircleUpgradeOffer
import uniffi.haven_ffi.HavenNode
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.InboundListener
import uniffi.haven_ffi.RelayClient
import uniffi.haven_ffi.httpAuthHeader
import uniffi.haven_ffi.parseLink
import java.io.File
import java.security.MessageDigest

private const val TAG = "HavenNet"

/** Contacts whose rosters we pull per sync pass, and how long before re-asking the same one.
 *  Both exist to keep an unresolvable contact from being re-dialled every tick forever — see the
 *  bounding note where the pull is kicked off. */
private const val ROSTER_PULL_PER_PASS = 3
private const val ROSTER_PULL_BACKOFF_MS = 600_000L   // 10 min

/** How long before re-asking the public directory about the same account (`resolveMissingDeviceIds`).
 *  Most contacts have simply never published, so an unthrottled lookup would fire a DNS round-trip
 *  per member per sync tick and learn nothing. iOS parity. */
private const val DISCOVERY_RETRY_MS = 600_000L   // 10 min

/** Events per circle handed to my own other devices by the catch-up sweep. Bounded because the
 *  sweep RE-SEALS every envelope it sends — real CPU per item, not a cheap re-broadcast. */
private const val OWN_DEVICE_CATCHUP_LIMIT = 50u
const val DEFAULT_CIRCLE = "default"

/** A known contact (their verified identity + display name). */
data class Contact(val idHex: String, val name: String, val verifyHex: String)

/** Someone who said hello but we haven't approved yet. */
data class PendingRequest(
    val idHex: String, val name: String, val verifyHex: String, val bundle: ByteArray,
    /** The circle grant the held hello carried — approval applies THIS circle, not just default
     *  (an invite into a named circle used to land its approved member in default only). */
    val circleId: String = DEFAULT_CIRCLE, val circleName: String = "",
)

/**
 * Live media-sync counters, kept OUT of [HavenNet.feedVersion] so incrementing them never
 * re-renders the feed (that was the sync-time lag on iOS). Only the tap-to-open sync-detail
 * sheet observes these, so a burst of media events recomposes just that sheet — parity with the
 * iOS `SyncMetrics` observable (FeedView.swift). Backed by Compose `mutableIntStateOf` so a
 * Composable that reads them is scoped to only itself.
 */
object SyncMetrics {
    val mediaOut = mutableIntStateOf(0)       // media items served/pushed to a requester
    val mediaIn = mutableIntStateOf(0)        // media items fully received + stored
    val mediaPending = mutableIntStateOf(0)   // media refs still missing locally
    val nearbyPeers = mutableIntStateOf(0)    // connected nearby-mesh peers (Android↔Android)
    // Bumped on any sync I/O so the UI can show a LIVE "syncing now" pulse even between the
    // coarse pending/in/out counters — the "something is actively happening" signal.
    val lastActivityMs = mutableStateOf(0L)

    fun incOut() { mediaOut.intValue += 1; poke() }
    fun incIn() { mediaIn.intValue += 1; poke() }
    fun setPending(n: Int) { mediaPending.intValue = n }
    fun setNearbyPeers(n: Int) { nearbyPeers.intValue = n }
    /** Mark that sync I/O just happened (a put/get/list/chunk) — drives the live activity pulse. */
    fun poke() { lastActivityMs.value = System.currentTimeMillis() }
}

/**
 * The Android counterpart of the iOS FeedStore networking core: owns the [HavenSocial] engine
 * and the [HavenNode] iroh transport, speaks the byte-exact [Wire] protocol, and drives the
 * Hello/Event handshake so an Android phone forms circles and exchanges posts with an iPhone.
 *
 * Connect model (one approval, MITM-guarded):
 *   - Scanning a friend's QR records "I initiated <node>, expect <verifyHex>" and sends them a
 *     Hello (carrying our bundle) over iroh.
 *   - An inbound Hello from a node we initiated, whose bundle hash matches, is auto-accepted.
 *   - An inbound Hello we did NOT initiate becomes a [pending] request for the user to approve.
 */
object HavenNet : InboundListener {
    private lateinit var appContext: Context
    private lateinit var core: HavenCore
    private lateinit var profile: ProfileStore
    private lateinit var social: HavenSocial
    private var node: HavenNode? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    /** DERP URLs the live messaging node was bound with (fabric soft-rebind). */
    @Volatile private var fabricBoundUrls: List<String> = emptyList()
    @Volatile private var fabricRebindGen: Long = 0
    @Volatile private var fabricRebindInFlight: Boolean = false

    // Observable UI state.
    val contacts: SnapshotStateList<Contact> = mutableStateListOf()
    val pending: SnapshotStateList<PendingRequest> = mutableStateListOf()
    val blocked: SnapshotStateList<String> = mutableStateListOf()
    var internetActive = mutableStateOf(false); private set
    var started = mutableStateOf(false); private set
    var feedVersion = mutableStateOf(0); private set   // bump to recompose the feed
    var relayActive = mutableStateOf(false); private set
    @Volatile var isForeground = false   // set by the UI lifecycle; suppresses notifications when open   // true once a mailbox put/get succeeds

    // Circle relay/mailbox: circleId -> ORDERED list of relay node hexes. Posts are mirrored to
    // every relay (redundancy) and read from all of them (graceful fallback if one is down) —
    // parity with the desktop `relays: HashMap<String, Vec<String>>`.
    private val relayNodes = HashMap<String, MutableList<String>>()
    /** Relays the user explicitly FORGOT/deactivated — auto-learn (frame-19 announce / SelfSync) must
     *  not resurrect a *deactivated* relay passively, or Forget is a visible no-op. A deliberate
     *  re-announce DOES reactivate it (handleRelayNode). Cleared on explicit re-adoption / reactivation.
     *  Mirrors iOS `suppressed`. */
    private val suppressedRelays = mutableSetOf<String>()

    /** When each relay was FORGOTTEN (unix ms), for LWW against a re-announce's addedAt. A re-add
     *  NEWER than the forget reactivates; a forget newer than the last add keeps it dead — so a relay's
     *  owner merely REOPENING the app (re-announcing the relay's older adoption time) can't resurrect a
     *  relay the user deleted. Mirrors iOS `forgotAt`. */
    private val forgotAtRelays = HashMap<String, Long>()

    /** Relays we deliberately RE-ADDED after a deletion (hex → re-add unix ms). Published via self-sync as
     *  a CLEAR so a sibling's stale deletion tombstone doesn't re-forget a relay we brought back — without
     *  it a grow-only relay tombstone would re-forget a re-added relay on every sibling's sync pass, forever
     *  (the "I delete a relay and it keeps coming back" bug in reverse). Mirrors iOS `clearedRelayForgets`. */
    private val clearedRelayForgets = HashMap<String, Long>()

    private fun relayForgottenAtMs(hex: String): Long = forgotAtRelays[hex.lowercase()] ?: 0L
    private fun relayAddedAtMs(hex: String): Long = relayEntries[hex]?.addedAtMs ?: 0L

    /**
     * One configured relay: a Haven relay node (isS3=false) or an S3 bucket transport (isS3=true).
     * `hex` is the 64-char node id for a Haven relay, or a synthetic "s3:<bucket>" id for an S3 entry,
     * so the same map can address both kinds. DEACTIVATE-NOT-ERASE: "removing" a relay flips `active`
     * to false and keeps the config (name + which circles use it) so it can be reactivated without
     * re-pasting. Only [purgeStaleRelays] erases — and only entries that are BOTH inactive AND unseen
     * for > 7 days. Mirrors iOS `RelayEntry`/`RelayMailboxStore`.
     */
    data class RelayEntry(
        val hex: String,
        val name: String,
        val active: Boolean,
        val lastSeenMs: Long,
        val isS3: Boolean,
        /** Plain-HTTP interface of this relay (LAN + optional public URLs) — the DEFAULT cross-NAT
         *  media transport (the iroh blob ALPN drops datagrams on pure-relay cross-NAT paths).
         *  Learned from the sealed announce; empty = iroh-only relay. */
        val httpUrls: List<String> = emptyList(),
        /** Shared relay secret folded into each request signature (travels ONLY inside sealed
         *  announces, and is never put on the wire — see httpAuth). */
        val httpToken: String = "",
        /** When this relay was last (re-)ADOPTED (unix ms). Rides the announce so a member who FORGOT
         *  it earlier reactivates only on a NEWER re-add (LWW); a stale echo carries the older stamp and
         *  loses. 0 = unknown (legacy). Mirrors iOS `RelayEntry.addedAtMs`. */
        val addedAtMs: Long = 0,
        /** Public HTTPS URL of this relay's embedded iroh-relay (DERP) fabric role. When set, peers
         *  prefer it over n0 for NAT fallback. Empty = use n0 (or another relay's DERP). */
        val derpUrl: String = "",
        /** Public TURN URLs for WebRTC ICE (`turn:host:port`). */
        val turnUrls: List<String> = emptyList(),
        /** TURN username (default `haven`). */
        val turnUser: String = "",
        /** TURN password (long-lived secret). Travels only inside sealed announces. */
        val turnPass: String = "",
    )
    /** Per-relay metadata records, keyed by hex. The config survives deactivation here. */
    /**
     * ConcurrentHashMap, not HashMap. This is written from the sync loop and every inbound frame
     * handler (relay announces, health probes, adoptions) and read from the Compose UI thread by the
     * Relays hub. A plain HashMap resizing under a concurrent read hands back garbage — including a
     * NULL for a value the type system swears is non-null — and that is precisely how opening
     * Settings crashed:
     *
     *   NullPointerException: 'boolean RelayEntry.getActive()' on a null object reference
     *     at HavenNet$allRelayEntries$$inlined$compareByDescending$1.compare
     *     at SettingsScreenKt.RelaysHubCard
     *
     * ConcurrentHashMap also forbids null values outright, so the corruption cannot reappear in that
     * shape even if a new write path is added later.
     */
    private val relayEntries = java.util.concurrent.ConcurrentHashMap<String, RelayEntry>()
    /** The all-circles default relay (every present + future circle inherits it). "" = none. */
    private var defaultRelayHex: String = ""
    /** Erase inactive+unseen relay entries after this long (parity with iOS staleAfterMs). */
    private val RELAY_STALE_AFTER_MS = 7L * 24 * 3600 * 1000
    private val relayClients = HashMap<String, RelayClient>()
    private val relayMutex = Mutex()

    // Mailbox keys already ingested or confirmed uploaded — PERSISTED (parity with iOS). In-memory
    // only, every cold start treated the whole mailbox as new and re-downloaded + re-verified every
    // envelope (a real circle had accumulated ~6700 entries for 88 events → a 30-second cold start,
    // all burned on crypto for duplicates the engine then dropped). Loaded lazily, saved debounced.
    private val seenMailbox = HashSet<String>()
    private var seenMailboxLoaded = false
    private var seenMailboxSavePending = false
    private val seenMailboxFile: File get() = File(appContext.filesDir, "haven_mailbox_seen.txt")
    private fun ensureSeenMailboxLoaded() {
        if (seenMailboxLoaded) return
        seenMailboxLoaded = true
        runCatching { if (seenMailboxFile.exists()) seenMailbox.addAll(seenMailboxFile.readLines().filter { it.isNotBlank() }) }
    }
    /** Record a mailbox key as seen and schedule one debounced save for the burst. */
    private fun markMailboxSeen(key: String) {
        ensureSeenMailboxLoaded()
        // Always insert into the in-memory set first so concurrent 2s live-call pollers cannot
        // re-process the same key while a disk save is pending.
        val inserted = synchronized(seenMailbox) { seenMailbox.add(key) }
        if (!inserted) return
        if (seenMailboxSavePending) return
        seenMailboxSavePending = true
        scope.launch {
            kotlinx.coroutines.delay(2_000)
            seenMailboxSavePending = false
            val snap = synchronized(seenMailbox) { seenMailbox.joinToString("\n") }
            runCatching { seenMailboxFile.writeText(snap) }
        }
    }

    private fun isMailboxSeen(key: String): Boolean {
        ensureSeenMailboxLoaded()
        return synchronized(seenMailbox) { seenMailbox.contains(key) }
    }

    /** Force the (debounced-elsewhere) seen-set to disk now. */
    private fun saveSeenMailboxNow() {
        val snap = synchronized(seenMailbox) { seenMailbox.joinToString("\n") }
        runCatching { seenMailboxFile.writeText(snap) }
    }

    /**
     * ONE-SHOT repair for keys the old poll loop wrongly marked seen. It used to
     * `markMailboxSeen` BEFORE `receive()` ran, so an envelope that arrived before its key commit
     * (or its sender's roster) was buffered — or dropped — and its key was still burned as seen,
     * never to be retried: the classic "banner arrived, message didn't" shape. Forget DM content
     * keys (where the symptom bites — a DM has exactly two members, so a commit-before-content
     * race is common) so the next poll re-GETs them and the mark-after-ingest contract takes over;
     * keep `__live__` (claimed call frames must not re-dispatch). Deliberately NOT every circle's
     * content: a key whose envelope DID ingest re-downloads as a duplicate (receive() == false)
     * and is never re-marked, so a full forget would turn every poll into a full mailbox
     * re-download. Mirrors iOS `SharedStore.repairLinkedHostMailboxSeenOnce`.
     */
    /** ONE-SHOT storm-burn repair (iOS `repairStormBurnedSeenOnce` parity): builds that marked
     * keys seen before the engine state persisted burned keys whose events -- including friends'
     * KEY COMMITS -- never landed when a kill hit the gap. Clear the whole mailbox seen-set once
     * (live-call lanes kept) so everything re-drains under mark-after-persist. */
    private fun repairStormBurnedSeenOnce() {
        val flag = "haven.repair.stormBurnedSeen.v1"
        if (prefs.getBoolean(flag, false)) return
        prefs.edit().putBoolean(flag, true).apply()
        ensureSeenMailboxLoaded()
        val removed = synchronized(seenMailbox) {
            val before = seenMailbox.size
            seenMailbox.retainAll { it.contains("/__live__/") }
            before - seenMailbox.size
        }
        if (removed > 0) {
            Log.i(TAG, "mailbox seen: storm-burn repair forgot $removed keys -- full re-drain")
            saveSeenMailboxNow()
        }
    }

    private fun repairMailboxSeenOnce() {
        val flag = "haven.repair.mailboxSeen.v1"
        if (!prefs.getBoolean(flag, false)) {
            prefs.edit().putBoolean(flag, true).apply()
            ensureSeenMailboxLoaded()
            val removed = synchronized(seenMailbox) {
                val before = seenMailbox.size
                seenMailbox.retainAll { key ->
                    // Keep non-DM and live-call frames; drop DM content + hellos so commits re-apply.
                    if (!key.contains("/dm:") && !key.contains("/dm%3A")) return@retainAll true
                    key.contains("/__live__/")
                }
                before - seenMailbox.size
            }
            if (removed > 0) {
                Log.i(TAG, "mailbox seen: one-shot repair forgot $removed DM keys (mark-after-ingest)")
                saveSeenMailboxNow()
            }
        }
        // ONE-SHOT #2: forget every seen `__hello__` key (the DM repair above only covered `dm:`
        // circles). Senders used to park hellos on transport/device-id slots; the poll filed those
        // as "someone else's — just mark" and burned the key, so the account-slot re-address never
        // got a second look at hellos already fetched — and a hello whose [handleHello] bailed
        // early (a removal tombstone since lifted, a bundle race) was burned the same way. That is
        // a circle INVITE lost to the seen-set. Hellos are idempotent to re-handle (acceptContact
        // upserts, the pending list dedupes, the reply path no-ops for known contacts), so the
        // price is one re-GET per hello blob, once.
        val helloFlag = "haven.repair.helloSeen.v1"
        if (!prefs.getBoolean(helloFlag, false)) {
            prefs.edit().putBoolean(helloFlag, true).apply()
            ensureSeenMailboxLoaded()
            val removed = synchronized(seenMailbox) {
                val before = seenMailbox.size
                seenMailbox.removeAll { it.contains("/__hello__/") }
                before - seenMailbox.size
            }
            if (removed > 0) {
                Log.i(TAG, "mailbox seen: one-shot repair forgot $removed hello keys (account-slot re-claim)")
                saveSeenMailboxNow()
            }
        }
        // ONE-SHOT #3 (v2): earlier builds also marked hellos seen at CLAIM time even when
        // [handleHello] HELD them (connection-approval gate, transient engine failure) — the
        // circle grant riding the hello was consumed without ever applying (the E2E-stub
        // "invite never lands" symptom). Now that routeMailboxEntry marks only CONSUMED hellos,
        // sweep the polluted marks once more so grants still sitting in a mailbox (own store or
        // a friend's relay) get re-offered and re-judged. Re-handling is idempotent for the same
        // reasons as #2. Mirrors iOS SharedStore.repairHelloSeenOnce v2.
        val helloFlagV2 = "haven.repair.helloSeen.v2"
        if (!prefs.getBoolean(helloFlagV2, false)) {
            prefs.edit().putBoolean(helloFlagV2, true).apply()
            ensureSeenMailboxLoaded()
            val removed = synchronized(seenMailbox) {
                val before = seenMailbox.size
                seenMailbox.removeAll { it.contains("/__hello__/") }
                before - seenMailbox.size
            }
            if (removed > 0) {
                Log.i(TAG, "mailbox seen: hello repair v2 forgot $removed keys (mark-on-consume)")
                saveSeenMailboxNow()
            }
        }
    }

    /**
     * Per-relay exponential-backoff health (5s → 5m), keyed by node hex — drives graceful
     * fallback. A relay that fails to connect/put/list/get is parked in a backoff window so we
     * stop hammering a dead relay and quietly use the others, then retry it later so a relay that
     * comes back is picked up again automatically. Mirror of desktop relayhealth.rs.
     */
    private class RelayHealth {
        var fails = 0
        var nextRetryMs = 0L   // earliest epoch-ms we'll try again; 0 = available now
        fun available(nowMs: Long): Boolean = nowMs >= nextRetryMs
        var lastSuccessMs = 0L   // proof-of-life stamp; gates what we re-announce to the circle
        fun recordSuccess() { fails = 0; nextRetryMs = 0L; lastSuccessMs = System.currentTimeMillis() }
        fun provenAlive(nowMs: Long, withinMs: Long): Boolean =
            lastSuccessMs > 0 && nowMs - lastSuccessMs <= withinMs
        fun recordFailure(nowMs: Long) {
            fails += 1
            // Don't park a relay on the FIRST failure — a single transient miss/timeout mid-transfer (common
            // over a DERP relay for a large chunked video) shouldn't lock the relay out for the rest of the
            // sync, stranding every remaining chunk with client=NULL. Only start backing off on sustained
            // failure. With the reused warm BlobClient connection, retrying costs no new dial.
            if (fails < 2) { nextRetryMs = 0L; return }
            val shift = minOf(fails - 2, 6)   // cap the exponent so the shift never overflows
            val backoff = minOf(BASE_BACKOFF_MS shl shift, MAX_BACKOFF_MS)
            nextRetryMs = nowMs + backoff
        }
        companion object {
            const val BASE_BACKOFF_MS = 1_500L      // 2nd failure → 1.5s cool-off (gentle; reused conn)
            const val MAX_BACKOFF_MS = 120_000L     // capped at 2 minutes
        }
    }
    private val relayHealth = HashMap<String, RelayHealth>()

    // node ids we initiated a connect to (scanned their QR) → expected verify hash.
    //
    // PERSISTED, and re-sent on the sync cadence until they answer. Both matter, and neither used
    // to be true: this was an in-memory map written once by connectByLink and never touched again,
    // so adding a friend sent exactly ONE hello. If the reply didn't make it back on that single
    // attempt the handshake was simply dead — no retry, ever — and Android kills backgrounded
    // processes readily, which dropped the map entirely and cost a late hello-back its auto-accept.
    //
    // A one-shot dial is worst exactly where friendships start: the other side has to TAP APPROVE,
    // which takes seconds to minutes, and a peer on cellular sits behind CGNAT with no inbound
    // reachability — the NAT binding our single hello opened is long gone by the time they answer,
    // and a new friendship has no relay mailbox to fall back on. iOS never hit this because adding
    // by link records a CONTACT immediately, which enrols it in the every-tick hello sweep; Android
    // deliberately waits for the hello-back before creating one, so it fell out of every retry path.
    // Re-sending keeps punching an outbound hole so their delayed answer has somewhere to land.
    private val initiated = HashMap<String, String>()
    private val initiatedAt = HashMap<String, Long>()
    /** Stop re-dialling a handshake nobody ever answered (they declined, or the link went stale). */
    private val initiatedTtlMs = 48L * 60 * 60 * 1000

    private fun loadInitiated() {
        val raw = prefs.getString("initiated", null) ?: return
        runCatching {
            val o = org.json.JSONObject(raw)
            for (k in o.keys()) {
                val e = o.getJSONObject(k)
                initiated[k] = e.optString("v", "")
                initiatedAt[k] = e.optLong("t", System.currentTimeMillis())
            }
        }
    }
    private fun saveInitiated() {
        val o = org.json.JSONObject()
        for ((k, v) in initiated) {
            o.put(k, org.json.JSONObject().put("v", v).put("t", initiatedAt[k] ?: System.currentTimeMillis()))
        }
        prefs.edit().putString("initiated", o.toString()).apply()
    }
    private fun forgetInitiated(idHex: String) {
        // Both removes must run — `or` here would bind tighter than `!=` and reparse the whole
        // thing as `remove(idHex) != (null or ...)`.
        val hadKey = initiated.remove(idHex) != null
        val hadStamp = initiatedAt.remove(idHex) != null
        if (hadKey || hadStamp) saveInitiated()
    }

    // Keyed by node id so a NEW identity never inherits a previous identity's events (the social
    // store isn't tied to the seed otherwise — that let an old friendship's posts leak in).
    private val stateFile: File get() = File(appContext.filesDir, "haven_social_state_${core.nodeIdHex}.bin")
    private val legacyStateFile: File get() = File(appContext.filesDir, "haven_social_state.bin")
    private val prefs get() = appContext.getSharedPreferences("haven.contacts", Context.MODE_PRIVATE)

    @Volatile private var ready = false

    @Synchronized
    fun init(context: Context) {
        if (ready) return   // atomic: never expose half-initialized state to a concurrent caller
        appContext = context.applicationContext
        // Must run before any iroh/TLS networking, or the node panics on Android.
        NativeBridge.ensureAndroidContext(appContext)
        core = HavenCore.get(appContext)
        profile = ProfileStore.get(appContext)
        DeviceKeyStore.init(appContext)   // needed by the seedless engine constructor below
        // Engine boot mode (plan §5): a SEEDLESS device has no account master seed — it constructs the
        // engine from the account PUBLIC bundle + its own device seed (the device identity is baked in),
        // and NEVER registers a device or registers for push (the primary owns those). A seeded/legacy
        // device keeps today's path: engine over the account seed, then adopt the device identity.
        social = if (core.seedless) {
            HavenSocial.newSeedless(core.bundle, DeviceKeyStore.deviceAccount().secretSeed())
        } else {
            HavenSocial(core.seed)
        }
        LocalMedia.init(appContext)
        Presign.init(appContext)
        CircleLock.init(appContext)
        CircleRemovals.init(appContext)
        ContactRemovals.init(appContext)
        CircleDeletion.init(appContext)
        // Engine runs on this device's UNIQUE identity (parity with iOS configure()); account id stays the
        // sealing/trust anchor + contact handle. Friends resolve it to our device node id via the roster.
        // newSeedless already baked the device identity in, so only the seeded path adopts it here.
        if (!core.seedless) social.useDeviceIdentity(DeviceKeyStore.deviceAccount().secretSeed())
        DeviceCredentialStore.init(appContext)
        DeviceRosterManager.init(appContext)
        SelfSyncCoordinator.init(appContext)
        SelfSyncKeyStore.init(appContext)   // 1.0.7 self-sync key rotation state (docs/SWITCH-FLIP-1.0.7.md §6)
        DmPins.init(appContext)
        DmRead.init(appContext)
        PinnedMediaStore.init(appContext)   // device-pin retention exemption (storage management)
        KeptStoriesStore.init(appContext)   // stories held on my profile past the 24h window
        EvictedMediaStore.init(appContext)  // deliberately-removed refs (no auto-refetch)
        MediaWantedStore.init(appContext)   // refs whose author we asked to put back (frames 31/32)
        ActivityStore.init(appContext)      // in-app activity list (engine rows + connection/circle rows)
        MediaLimits.init(appContext)        // local age/size caps
        // Persisted don't-retry set ONLY. Deliberately starts nothing: the re-optimize pass has no
        // timer, no launch hook and no WorkManager job — a button is its only caller (see the
        // BOUNDING note in MediaReoptimizer).
        MediaReoptimizer.init(appContext)
        ReassemblyStore.init(appContext)    // half-finished media transfers, so they resume not restart
        restoreReassemblies()
        restoreState()
        if (core.seedless) {
            // A seedless device cannot mint a roster or an account-signed profile card. Install the
            // primary's grant: the roster wire VERBATIM (incl. capability trailer — A3) so the engine
            // authorizes this device + rebroadcasts the exact bytes, and the account-signed credential.
            // (The primary's signed profile CARD arrives via self-sync / full-state and is installed by
            // setCachedProfile as soon as we hold it — D8.) NEVER register_device / re-sign anything.
            SeedlessStore.rosterWire()?.let { wire -> runCatching { social.ingestRosterWire(wire) } }
            SeedlessStore.credential()?.let { DeviceCredentialStore.save(it) }
        } else {
            // Self-register AFTER importing persisted state (parity with iOS): registering first wrote a
            // fresh v1 roster that restoreState's higher-version-wins restore then clobbered — so a stale
            // revocation of our own device id in the persisted roster could never be cleared. Registering
            // against the imported roster makes the re-authorization a version-bumped update that
            // propagates (see DeviceList::merge).
            social.registerDevice(DeviceKeyStore.deviceBundle(), DeviceKeyStore.deviceName,
                                  (System.currentTimeMillis() / 1000).toULong())
        }
        loadContacts()
        loadDeviceHints()
        loadInitiated()   // an unanswered handshake must outlive the process that started it
        loadUnopenable()  // don't re-download blobs that already failed to open once
        loadBlocked()
        loadRelayNodes()
        purgeStaleRelays()   // erase relays inactive AND unseen > 7 days (config else survives)
        if (core.seedless) {
            // Adopt the grant's bootstrap relays (AFTER loadRelayNodes, which would else clear them) so
            // the FIRST self-sync has a transport to pull the primary's slot from — the absence-as-
            // deletion guard depends on that slot arriving before any local diff. Later relays converge
            // via the primary's self-synced circle records. Skipped if already adopted (idempotent).
            for (r in SeedlessStore.relays()) {
                val hex = r.trim().lowercase()
                if (hex.length == 64 && !hex.startsWith("s3:") && !relayEntries.containsKey(hex)) {
                    runCatching { adoptRelay(hex, setDefault = defaultRelayHex.isEmpty()) }
                }
            }
        }
        // Restore the last-selected circle (if it still exists), so it survives relaunch.
        val savedCircle = prefs.getString("activeCircle", DEFAULT_CIRCLE) ?: DEFAULT_CIRCLE
        activeCircle.value = if (savedCircle == DEFAULT_CIRCLE ||
            runCatching { social.circles().any { it.id == savedCircle } }.getOrDefault(false)
        ) savedCircle else DEFAULT_CIRCLE
        // 1.0.7 crypto switch-flip: turn ON the new keying now that the engine + device identity + roster
        // are up (docs/SWITCH-FLIP-1.0.7.md). These switches are NOT persisted in the engine, so this runs
        // on EVERY launch. Everything is gated in core — inert (byte-identical to 1.0.6) until a circle /
        // the own-device fleet is fully capable.
        applyCryptoSwitches()
        ready = true
        // Tell the UI the engine exists now.
        //
        // init() is driven from a LaunchedEffect, so it necessarily runs AFTER the first composition:
        // CircleScreen has already called engine.feed() once, caught the lateinit failure, and cached
        // the empty result in a remember() keyed on feedVersion/circlesVersion. Nothing here moved
        // either key, so that empty feed was final — the circle stayed blank until some unrelated
        // event bumped the version, or until the user left the tab and came back and the remember
        // was rebuilt from scratch. (Which is exactly the "tap Messages, tap Circle, now it loads"
        // workaround testers found.) One bump at the end of boot re-reads everything.
        scope.launch(Dispatchers.Main) { feedVersion.value++; circlesVersion.value++ }
    }

    /**
     * Re-apply the (non-persisted) 1.0.7 crypto enablers — called from [init] on every launch since the
     * engine is rebuilt each process. Mirrors docs/SWITCH-FLIP-1.0.7.md steps 2–6:
     *  - §3/§4: MLS keying master switch + seed-drop account-key retirement.
     *  - §2: re-pin the creator on every circle I created (the authority root; not persisted as a keying
     *        decision — it rides the authenticated circle definition).
     *  - §5: mark `dm:` circles as per-message live lanes.
     *  - §1: one-time migration of an existing multi-device account to a device-only roster.
     */
    private fun applyCryptoSwitches() {
        // §3 — MLS keying master switch (both device kinds; gated + all-joined inside core).
        runCatching { social.setMlsKeying(true) }
        // §4 — seed-drop account-key RETIREMENT. A seedless device never runs the primary-only content
        // retirement switch, but every device mirrors the self-sync rotation intent (a reader-side op).
        SelfSyncKeyStore.retireSwitchOn = true
        if (!core.seedless) runCatching { social.setSeedDropRetire(true) }
        // §2 + §5 — per-circle re-application.
        val created = createdCircles()
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            if (c.id.startsWith("dm:")) runCatching { social.setCircleLiveLane(c.id, true) }
            if (!core.seedless && created.contains(c.id)) runCatching { social.setCircleCreator(c.id, nodeIdHex) }
        }
        // Collapse any upgraded/duplicated circle at launch into a single row (LWW deletion tombstone).
        reconcileSupersededCircles()
        // §1 — existing multi-device upgraders shed the legacy bare account leaf ONCE.
        maybeRetireAccountLeaf()
        // 1.0.8 — overwrite media a 1.0.7 build device-signed + froze, so friends can open it (once).
        maybeResealOwnMedia()
    }

    /**
     * 1.0.8 media recovery — run ONCE. A 1.0.7 build device-signed my posted media and, because a blob
     * is content-addressed + write-once, froze it so friends could never open it. The core fix re-seals
     * account-signed; this force-re-uploads my OWN media (only what I still hold the plaintext for) to
     * overwrite the stale frozen blob on every reachable destination. Sticky SharedPreferences latch —
     * a fresh 1.0.8+ install never posted a bad blob. Mirrors iOS `MediaRecovery` / desktop
     * `maybe_reseal_own_media`.
     */
    @Volatile private var resealInFlight = false
    private fun maybeResealOwnMedia() {
        if (cryptoPrefs.getBoolean("mediaResealedV108", false) || resealInFlight) return
        resealInFlight = true
        // A content-addressed blob is only repairable by the force-overwrite (normal backfill sees the
        // frozen blob as "present" and skips it forever), and the overwrite lands only on destinations
        // reachable during the pass — so RETRY across launches until every held ref is confirmed on ≥1
        // dest. Capped so a user with no reachable destination (nothing uploaded, nothing to repair)
        // still stops. Runs in a coroutine, one blob at a time (peak RAM ≈ one media file).
        scope.launch {
            val seen = HashSet<String>()
            val held = ArrayList<Pair<String, String>>()   // (circleId, ref) I still hold the plaintext for
            for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
                val feed = runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())
                for (item in feed) {
                    if (!item.isMe) continue
                    for (r in item.media) if (!LocalMedia.isSynthetic(r) && LocalMedia.has(r) && seen.add(r)) held.add(c.id to r)
                    for (cm in item.comments) {
                        if (!cm.isMe) continue
                        for (r in cm.media) if (!LocalMedia.isSynthetic(r) && LocalMedia.has(r) && seen.add(r)) held.add(c.id to r)
                    }
                }
            }
            val done = HashSet(cryptoPrefs.getStringSet("mediaResealRefs", emptySet()) ?: emptySet())
            for ((cid, r) in held) {
                if (done.contains(r)) continue
                if (uploadMedia(cid, r, force = true)) done.add(r)   // a dest accepted the fresh blob → repaired
            }
            val attempts = cryptoPrefs.getInt("mediaResealAttempts", 0) + 1
            // Latch when every repairable ref is confirmed, or after enough tries that a still-failing
            // ref is almost certainly un-repairable (its destination is gone / was never reachable).
            val latched = held.all { done.contains(it.second) } || attempts >= 10
            cryptoPrefs.edit()
                .putStringSet("mediaResealRefs", done)
                .putInt("mediaResealAttempts", attempts)
                .putBoolean("mediaResealedV108", latched)
                .apply()
            if (held.isNotEmpty()) android.util.Log.i("MediaSync", "media recovery: ${done.size}/${held.size} authored blobs re-sealed + overwritten (attempt $attempts)")
            resealInFlight = false
        }
    }

    /** SharedPreferences-backed set of circle ids THIS device created — the circles it may pin itself as
     *  creator of on every launch (§2). Circles created by peers are learned out-of-band by core. */
    private val cryptoPrefs get() = appContext.getSharedPreferences("haven.crypto", Context.MODE_PRIVATE)
    private fun createdCircles(): Set<String> = cryptoPrefs.getStringSet("createdCircles", emptySet()) ?: emptySet()
    /** Did THIS device create [id]? Used by self-sync to stamp the circle's authority-root creator (§2) so
     *  it travels with the authenticated circle definition to my other devices. */
    fun selfSyncCreatedCircle(id: String): Boolean = createdCircles().contains(id)
    private fun markCreatedCircle(id: String) {
        val next = HashSet(createdCircles()); next.add(id)
        cryptoPrefs.edit().putStringSet("createdCircles", next).apply()
    }

    /**
     * MIGRATION (§1) — an existing multi-device account carries a legacy `{account, device}` roster that
     * is grow-only and cannot silently shrink to device-only, so live keying + account-key retirement
     * would strand it at `shadow`. `retire_account_leaf()` mints a higher-version, account-signed roster
     * with the sticky `account-leaf-retired` flag so the roster reaches the device-only shape live keying
     * requires. Gated + idempotent in core (a no-op until the fleet is fully capable), guarded here by a
     * one-time SharedPreferences flag. A fresh device-only install registers device-only from day one and
     * skips this entirely. Absence never retires — this is a POSITIVE, versioned signal only.
     */
    private fun maybeRetireAccountLeaf() {
        if (core.seedless) return                                   // primary-only op (holds the seed)
        if (cryptoPrefs.getBoolean("accountLeafRetired", false)) return
        if (!DeviceRosterManager.isEnabled()) return                // no legacy multi-device roster to shrink
        // Already device-only (a prior launch retired it, or register_device emitted it) — record + done.
        if (runCatching { social.accountLeafRetired() }.getOrDefault(false)) {
            cryptoPrefs.edit().putBoolean("accountLeafRetired", true).apply(); return
        }
        // Gated + idempotent: returns false until the fleet is device-capable — retry on the next launch.
        if (runCatching { social.retireAccountLeaf() }.getOrDefault(false)) {
            cryptoPrefs.edit().putBoolean("accountLeafRetired", true).apply()
            // Rebroadcast the device-only (higher-version) roster wire so peers learn the retirement. The
            // sync loop reads myDeviceRosterWire() fresh each pass; also kick a relay publish once started.
            scope.launch { runCatching { publishDeviceRoster() } }
        }
    }

    /** Start the iroh node and begin syncing. Safe to call repeatedly. */
    fun start() {
        if (node != null) return
        bumpActivity()   // seed activity NOW so launch starts at tight cadence (idle=huge would else max-back-off)
        // DIAGNOSTIC: capture iroh/noq connection-level logs to filesDir/iroh-trace.log BEFORE the node starts.
        runCatching { uniffi.haven_ffi.initLogging(appContext.filesDir.path) }
        scope.launch {
            try {
                // Fabric before bind: prefs may already know circle DERP from a prior session.
                // apply_derp_urls is process-wide and only affects this HavenNode if set before start
                // (iroh RelayMap is construct-time).
                refreshHavenFabric()
                // TRANSPORT = per-DEVICE seed → unique per-device relay/node id (never the account id). The
                // self-connect leak is defended at the haven-net core (Node refuses to dial our own node id).
                node = HavenNode.start(DeviceKeyStore.deviceAccount().secretSeed(), this@HavenNet)
                fabricBoundUrls = activeFabricUrls()
                withContext(Dispatchers.Main) { started.value = true }
                Log.i(TAG, "node started: ${node?.nodeIdHex()}")
                publishAccountDevices()   // account id -> my device ids, so contacts can dial me relay-free
                // Matrix QA: dump our public identity so Scripts/qa-exchange-bundles.sh can seed iOS,
                // and ingest qa-peer-bundle.bin if the driver staged a sim peer (HTTP-mailbox stub path
                // where HELLO cannot dial). Without mutual addContactBundle reverse media never opens.
                runCatching {
                    val b = social.myBundle()
                    if (b.isNotEmpty()) {
                        java.io.File(appContext.filesDir, "qa-my-bundle.bin").writeBytes(b)
                        val name = ProfileStore.get(appContext).displayName.ifBlank { "EmuPeer" }
                        java.io.File(appContext.filesDir, "qa-my-name.txt").writeText(name)
                        Log.i("HavenQA", "qa-my-bundle written bytes=${b.size} name=$name account=${social.myNodeHex().take(12)}")
                    }
                }
                runCatching { ingestQaPeerBundle() }
                // REACHABILITY PROBE: dump this node's ticket (published addrs + DERP relay url) so we can SEE
                // whether the Android node has an internet-reachable path — the same probe as the Mac. If the
                // Nokia has a DERP url and the Mac has a DERP url, they SHOULD reach each other; a timeout then
                // is a code path difference, not the network. Pull: adb shell run-as ... cat files/node-ticket.txt
                scope.launch {
                    for (d in listOf(0L, 3000L, 8000L, 20000L)) {
                        delay(d)
                        val t = runCatching { node?.ticket() }.getOrNull() ?: ""
                        val rep = "nodeId=${node?.nodeIdHex()}\naccount=${runCatching { social.myNodeHex() }.getOrNull()}\nticketLen=${t.length}\nticket=$t\n"
                        runCatching { java.io.File(appContext.filesDir, "node-ticket.txt").writeText(rep) }
                        Log.i("MediaSync", "node TICKET len=${t.length}")
                    }
                }
                syncWithContacts()
                pollMailbox()
                requestMissingMedia()   // back-fill media for posts already in the feed
                drainPersistedBackups() // finish any of MY media uploads killed mid-flight last session
                runCatching { publishDeviceRoster() } // authorize this device on HTTP mailbox relays
            } catch (e: Throwable) {
                Log.e(TAG, "node start failed", e)
            }
        }
        startMailboxLoop()
    }

    // Adaptive sync cadence (device-heat control). The loop keeps a cheap 10s heartbeat, but the
    // EXPENSIVE work (contact hello+roster fan-out, relay re-announce, mailbox poll, mesh dials) only
    // runs when it's DUE. When the app is idle — foregrounded but nothing arriving/authored — the
    // due-interval STRETCHES, so an idle phone isn't blasting hello+roster to every contact every tick
    // (the main heat source). Any real activity (foreground, an authored post, an arriving message, a
    // nearby peer connecting) resets it to the tight base cadence, and pushes still wake the app for
    // immediacy either way. Parity with iOS FeedStore (build 178): sync base 20s, poll base 30s.
    @Volatile private var lastActivityMs = 0L
    @Volatile private var nextSyncDueMs = 0L
    @Volatile private var nextPollDueMs = 0L
    /**
     * Base cadence stretched by idle time, thermal pressure, and super data saver
     * (iOS FeedStore.adaptiveInterval parity).
     */
    private fun adaptiveInterval(base: Long): Long {
        val idle = System.currentTimeMillis() - lastActivityMs
        var mult = when {
            idle < 180_000 -> 1L
            idle < 900_000 -> 3L
            else -> 6L
        }
        // Thermal: PowerManager.getCurrentThermalStatus (API 29+)
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            val pm = appContext.getSystemService(android.content.Context.POWER_SERVICE) as? android.os.PowerManager
            when (pm?.currentThermalStatus) {
                android.os.PowerManager.THERMAL_STATUS_SEVERE,
                android.os.PowerManager.THERMAL_STATUS_CRITICAL,
                android.os.PowerManager.THERMAL_STATUS_EMERGENCY,
                android.os.PowerManager.THERMAL_STATUS_SHUTDOWN -> mult *= 2
                android.os.PowerManager.THERMAL_STATUS_MODERATE -> mult = (mult * 3) / 2
            }
        }
        if (runCatching { ProfileStore.get(appContext).superDataSaver }.getOrDefault(false)) {
            mult = (mult * 3) / 2
        }
        return base * mult.coerceAtLeast(1L)
    }
    /**
     * How long until the next MAILBOX poll — deliberately not [adaptiveInterval].
     *
     * Both buckets shared one stretch, and that conflates two very different costs. The SYNC bucket
     * is a fan-out (hello + roster to every contact, relay re-announce, mesh dials) — the radio
     * traffic that cooks phones, and it should keep stretching hard. The POLL bucket is one LIST of
     * our own mailbox: cheap, and the only thing that makes a post a relay already holds actually
     * appear on this device. Stretching it while the user is watching the screen buys almost no
     * battery and costs exactly the latency people notice. Capped at 2× base while foregrounded;
     * backgrounded, the full stretch stands, because then nobody is waiting and push wakes us.
     * iOS parity (FeedStore.mailboxPollInterval).
     */
    private fun mailboxPollInterval(base: Long): Long {
        val full = adaptiveInterval(base)
        return if (isForeground) minOf(full, base * 2) else full
    }

    /** Mark "something is happening" → snap both timers back to their tight base cadence immediately. */
    fun bumpActivity() {
        lastActivityMs = System.currentTimeMillis()
        nextSyncDueMs = 0
        nextPollDueMs = 0
    }
    /** Mark "a user is actively LOOKING" without forcing any work: the idle stretch resets, and
     *  an already-stretched due time is clamped down to the tight base — so the next pass runs at
     *  real active cadence, but nothing runs early. QA `dump` uses this (docs/QA.md "qa-cmd v2"):
     *  a reader's convergence is measured at the poll an active user would actually get, so
     *  forcing one here would fake the measured latency. */
    fun markUserActive() {
        lastActivityMs = System.currentTimeMillis()
        val now = lastActivityMs
        nextSyncDueMs = minOf(nextSyncDueMs, now + adaptiveInterval(20_000))
        nextPollDueMs = minOf(nextPollDueMs, now + mailboxPollInterval(30_000))
    }
    /** Author-side nudge: run a mailbox poll NOW instead of at the next due heartbeat, so a
     *  just-authored burst uploads/fans out (mesh + multi-device self-sync ride pollMailbox)
     *  immediately. Coalesces — an in-flight nudge absorbs the burst — and the pass counts as
     *  the due poll so the heartbeat doesn't immediately repeat it. */
    @Volatile private var pollNowJob: Job? = null
    fun pollMailboxNow() {
        if (!ready) return
        if (pollNowJob?.isActive == true) return
        pollNowJob = scope.launch {
            nextPollDueMs = System.currentTimeMillis() + mailboxPollInterval(30_000)
            runCatching { pollMailbox() }
        }
    }

    /** Adaptive-cadence loop: 10s heartbeat, expensive work only when due so an idle phone stays cool. */
    private var loopStarted = false
    private fun startMailboxLoop() {
        if (loopStarted) return
        loopStarted = true
        // Fast live-call lane (2s) for invite/accept/sdp when iroh dial is down.
        scope.launch {
            while (true) {
                delay(2_000)
                if (!ready) continue
                runCatching { pollLiveCallFrames() }
                // Same cadence as the call lane: notice a call whose peers are all gone and end it,
                // or a lost hangup leaves the device permanently "in a call" and unable to ring.
                runCatching { CallManager.noticeStuckCall() }
            }
        }
        scope.launch {
            while (true) {
                delay(10_000)
                val nowMs = System.currentTimeMillis()
                // Sync bucket (base 20s): greet contacts (Hello keeps connections warm; full history
                // re-send + own-media relay backfill are throttled internally), re-announce our relay so
                // peers that weren't connected at relay start still learn it (iOS reannounceOwnRelay
                // parity), retry any incomplete media transfer (pull from relay AND re-request from
                // peers), push own media to nearby siblings, and GC relays inactive + unseen > 7 days.
                // This fan-out is the primary heat source, so it backs off hardest when idle.
                if (nowMs >= nextSyncDueMs) {
                    nextSyncDueMs = nowMs + adaptiveInterval(20_000)
                    runCatching { syncWithContacts() }
                    runCatching { requestMissingMedia() }
                    runCatching { pushOwnMediaNearby() }
                    runCatching { purgeStaleRelays() }
                    runCatching { maybeWeeklyMediaSweep() }   // orphaned media blobs (at most once a week)
                    runCatching { enforceLocalLimits() }      // age/size caps (throttled ~10 min)
                }
                // Poll bucket (base 30s): pull the circle relay/mailbox so posts arrive even when peers
                // aren't both online (pollMailbox also drives mesh + multi-device self-sync internally).
                if (nowMs >= nextPollDueMs) {
                    nextPollDueMs = nowMs + mailboxPollInterval(30_000)
                    runCatching { pollMailbox() }
                }
            }
        }
    }

    val nodeIdHex: String get() = core.nodeIdHex

    /** The shareable invite link, carrying my device node id(s) as `?d=` dial hints — the scanner's
     *  only reachable ids for me until my signed roster arrives (device-seed transport bootstrap). */
    fun inviteUri(): String {
        val acct = nodeIdHex.lowercase()
        val mine = LinkedHashSet<String>()
        runCatching { mine.add(social.myDeviceNodeHex()) }
        for (d in runCatching { social.deviceNodeIdsFor(acct) }.getOrDefault(emptyList())) {
            if (d.lowercase() != acct) mine.add(d)
        }
        return InviteHints.embed(core.inviteUri(), mine.toList())
    }

    // ---- Multi-circle ----

    val activeCircle = mutableStateOf(DEFAULT_CIRCLE)
    var circlesVersion = mutableStateOf(0); private set

    /** Non-DM circles, for the feed switcher. Filters any tombstone-deleted circle (belt-and-suspenders:
     *  a sync race can re-materialize one before its `circle-deleted:` record applies). */
    fun feedCircles(): List<uniffi.haven_ffi.CircleInfoFfi> =
        runCatching {
            social.circles().filter { !it.id.startsWith("dm:") && !CircleDeletion.isDeleted(it.id) }
        }.getOrDefault(emptyList())

    /**
     * Collapse any SUPERSEDED legacy circle (one carried onto a creator-bound successor via upgrade or
     * follow) into a single row, and heal duplicates that already exist. Converts the engine's per-device
     * `supersededCircleIds()` signal into the SAME synced, LWW deletion tombstone used for deleting a
     * circle — so self-sync honors it on every device and can never resurrect the legacy row. Mirrors iOS
     * FeedStore.refreshCircles. Runs at launch, after an upgrade/follow, and on each self-sync apply.
     */
    fun reconcileSupersededCircles() {
        val superseded = runCatching { social.supersededCircleIds() }.getOrDefault(emptyList())
        if (superseded.isEmpty()) return
        var changed = false
        for (legacy in superseded) {
            if (CircleDeletion.isDeleted(legacy)) continue
            val successor = runCatching { social.circleSuccessor(legacy) }.getOrNull() // capture BEFORE leaving
            CircleDeletion.markDeleted(legacy)               // LWW tombstone → syncs to all my devices
            runCatching { social.leaveCircle(legacy) }       // drop the duplicate row from the engine
            if (activeCircle.value == legacy) activeCircle.value = successor ?: DEFAULT_CIRCLE
            changed = true
        }
        if (changed) { persist(); bumpCircles() }
    }

    /** What to SHOW a circle as: my own private nickname if I've set one, else its real name. The
     *  real name is what travels on the wire and what everyone else sees — renaming it for myself
     *  must never rename it for them, so the nickname is resolved only here, at display time. */
    fun circleName(id: String): String =
        CircleSettings.displayName(id, realCircleName(id))

    /** The circle's name as it actually is on the wire — for the rename field (which edits the shared
     *  name) and for anything that PUTS a name on the wire, where a private nickname must not leak. */
    fun realCircleName(id: String): String =
        runCatching { social.circles().firstOrNull { it.id == id }?.name }.getOrNull() ?: "My Circle"

    fun createCircle(name: String): String {
        // Mint a creator-BOUND id: it commits to this account, so every member establishes the circle's
        // creator from the id itself rather than from a claim on the wire. This also pins + announces
        // the creator, so no separate setCircleCreator call is needed here.
        val id = social.createCircleOwned(name)
        // §2 — remembered so the pin is re-applied on every launch (it isn't persisted as a keying decision).
        markCreatedCircle(id)
        CircleDeletion.markRecreated(id)   // a freshly-created circle is not deleted (LWW)
        persist(); bumpCircles()
        setActiveCircle(id)
        selfSyncNudge()   // a new circle should appear on my other devices in seconds, not minutes
        return id
    }

    // ---- Carrying an older circle onto one with a verified owner -------------------------

    /** Upgrade offers on [circleId] I haven't followed — "so-and-so says this circle's replacement is
     *  theirs". Each is verified as genuinely from its signer, but NOT as proof they made the circle:
     *  legacy circles never recorded an owner, so nothing can establish that. The user decides — see
     *  CircleUpgradeBanner. More than one offer is a legitimate state; all of them are surfaced. */
    fun pendingCircleUpgrades(circleId: String): List<CircleUpgradeOffer> =
        runCatching { social.pendingCircleUpgrades(circleId) }.getOrDefault(emptyList())

    /** A legacy circle with no verified owner yet — the app can offer to upgrade it, and the offer is
     *  shown to ANY member (no device records who made a pre-1.0.7 circle; the follow side names each
     *  claimant). Excludes owned (`c1`) ids, the personal `default` circle, and two-party `dm:` threads.
     *  Empty circle admins is the core's authoritative "no owner root yet" signal — so this no longer
     *  depends on the per-device created-circles record that legacy circles never had. */
    fun circleIsUpgradable(circleId: String): Boolean {
        if (circleId.startsWith("c1") || circleId == DEFAULT_CIRCLE || circleId.startsWith("dm:")) return false
        return runCatching { social.circleAdmins(circleId).isEmpty() }.getOrDefault(false)
    }

    /** Offer to carry a circle I made onto its replacement: mints the replacement, carries the members
     *  over, and puts the signed offer on the old circle's lane. Returns the replacement's id. */
    fun offerCircleUpgrade(circleId: String): String? {
        val id = runCatching { social.upgradeCircle(circleId) }.getOrNull() ?: return null
        // §2 — remembered so the pin is re-applied on every launch, like any circle I made.
        markCreatedCircle(id)
        CircleDeletion.markRecreated(id)          // the fresh successor is not deleted (LWW)
        reconcileSupersededCircles()              // collapse the now-superseded legacy circle to one row
        persist(); bumpCircles()
        setActiveCircle(id)
        selfSyncNudge()   // the successor + supersession tombstone travel to my other devices now
        return id
    }

    /** Follow someone's offer: stand up the replacement and pin them as its verified owner. Only ever
     *  called from an explicit tap — the banner has already named who is claiming the circle, because
     *  nothing can prove the claim and whoever is followed can remove people. */
    fun followCircleUpgrade(circleId: String, newCircleId: String): Boolean {
        val ok = runCatching { social.acceptCircleUpgrade(circleId, newCircleId) }.getOrDefault(false)
        if (!ok) return false
        CircleDeletion.markRecreated(newCircleId)   // the fresh successor is not deleted (LWW)
        reconcileSupersededCircles()                // collapse the now-superseded legacy circle to one row
        persist(); bumpCircles()
        setActiveCircle(newCircleId)
        selfSyncNudge()   // the followed successor + supersession tombstone travel now
        return true
    }

    /**
     * §2 — delegate circle admin to a member (creator/admin only; account-signed, higher-version-wins,
     * propagates on the control lane). Admin authority is what gates [mlsRemoveMember]. Call this on an
     * admin promotion. Returns whether the grant was authored (false if unauthorized / seedless).
     */
    fun promoteCircleAdmin(circleId: String, contactHex: String): Boolean {
        if (core.seedless) return false                             // account-key holder only
        val ok = runCatching { social.grantCircleAdmin(circleId, contactHex) }.getOrDefault(false)
        if (ok) { persist(); scope.launch { runCatching { SelfSyncCoordinator.sync(social) } } }
        return ok
    }

    fun renameCircle(id: String, name: String) {
        runCatching { social.renameCircle(id, name) }; persist(); bumpCircles()
        selfSyncNudge()   // the new name rides the circle: record to my other devices now
    }

    fun leaveCircle(id: String) {
        if (id == DEFAULT_CIRCLE) return
        CircleDeletion.markDeleted(id)   // LWW tombstone so a sibling's circle: record can't re-create it
        runCatching { social.leaveCircle(id) }
        if (activeCircle.value == id) activeCircle.value = DEFAULT_CIRCLE
        persist(); bumpCircles()
        selfSyncNudge()   // the deletion tombstone travels now, before a sibling can re-broadcast the row
    }

    /** Add an existing contact to a circle + greet them there so it forms on their side. */
    fun addToCircle(circleId: String, contactIdHex: String) {
        CircleRemovals.remove(circleId, contactIdHex)   // deliberate re-add un-bans them (parity with iOS)
        runCatching { social.clearCircleRemoval(circleId, contactIdHex) }   // …and lift the engine tombstone
        runCatching { social.addExistingToCircle(circleId, contactIdHex) }
        persist(); bumpCircles()
        sendHello(circleId, contactIdHex)
        selfSyncNudge()   // membership change (add / re-add) — push to my other devices now
    }

    fun setActiveCircle(id: String) {
        activeCircle.value = id
        prefs.edit().putString("activeCircle", id).apply()   // survive relaunch
    }

    private fun bumpCircles() { scope.launch(Dispatchers.Main) { circlesVersion.value++ } }

    /** Resolve a feed item's short author id (8 hex) to the contact's FULL node id, or null if we
     *  don't hold them. The short id is all a feed item carries, but anything addressed to a person
     *  (a DM, a sealed frame) needs the full hex. Mirrors iOS `ContactsStore.idHex(forNodePrefix:)`. */
    fun idHexFor(authorShort: String): String? =
        if (authorShort.isEmpty()) null else contacts.firstOrNull { it.idHex.startsWith(authorShort) }?.idHex

    /** Is this full node id someone in my circles? */
    fun isContact(hex: String): Boolean = contacts.any { it.idHex.equals(hex, ignoreCase = true) }

    /** Resolve a feed item's short author id (8 hex) to a contact's display name. */
    fun displayName(authorShort: String): String =
        contacts.firstOrNull { it.idHex.startsWith(authorShort) }?.name
            ?: if (authorShort.length >= 6) "Someone (${authorShort.take(6)})" else authorShort

    // ---- Inbound dispatch (called off-main by the Rust node) -----------------------------

    override fun onInbound(fromHex: String, payload: ByteArray) =
        onInbound(payload, viaNearby = false, senderDevice = fromHex.ifEmpty { null })

    /** [viaNearby] = arrived over the local proximity mesh. A Hello from an UNKNOWN node over nearby
     *  must NOT spawn a connection request (proximity != intent to connect — that was request spam);
     *  only targeted iroh/relay invites prompt. */
    /** [senderDevice] = the AUTHENTICATED transport id the frame arrived from (null for nearby /
     *  relay-unwrapped frames). A direct HELLO teaches us a dialable device id for its account —
     *  the reply-path bootstrap (an invitee holds no invite hints for the initiator). */
    fun onInbound(payload: ByteArray, viaNearby: Boolean, senderDevice: String? = null) {
        if (payload.isEmpty()) return
        val type = payload[0].toInt() and 0xFF
        val body = payload.copyOfRange(1, payload.size)
        // Call frames lead with a 64-char sender hex — drop blocked senders early (parity with iOS).
        if (type in intArrayOf(Wire.MEDIA_REQ, Wire.MEDIA_RESUME_REQ, CallWire.INVITE, CallWire.ACCEPT,
                CallWire.HANGUP, CallWire.OFFER,
                CallWire.ANSWER, CallWire.ICE, CallWire.GROUP_INVITE, CallWire.CAMERA,
                Wire.MEDIA_WANTED, Wire.MEDIA_AVAILABLE)) {
            if (body.size >= 64) {
                val head = String(body.copyOfRange(0, 64), Charsets.UTF_8)
                if (head.length == 64 && blocked.contains(head)) return
            }
        }
        scope.launch {
            withContext(Dispatchers.Main) { internetActive.value = true }
            when (type) {
                Wire.HELLO -> handleHello(body, viaNearby, senderDevice)
                Wire.DEVICE_ENROLL -> handleEnrollmentRequest(body)
                Wire.DEVICE_GRANT -> handleDeviceGrant(body)
                Wire.SEEDLESS_ENROLL_REQ -> handleSeedlessEnrollRequest(body)
                Wire.SEEDLESS_ENROLL_GRANT -> handleSeedlessEnrollGrant(body)
                Wire.EVENT -> handleEvent(body, senderDevice, viaNearby)
                Wire.RELAY_NODE -> handleRelayNode(body)
                Wire.RELAY -> handleRelay(body, viaNearby)
                Wire.PRESIGN -> handlePresignBootstrap(body)
                Wire.MEDIA_REQ -> handleMediaRequest(body)
                // 33 = the same ask carrying a bitmap of what the requester already holds, so we serve
                // only the holes. Plaintext with frame 3's blocked-sender check for the reason in Wire.
                Wire.MEDIA_RESUME_REQ -> handleMediaResumeRequest(body)
                Wire.MEDIA_CHUNK -> handleMediaChunk(body)
                Wire.DEVICE_ROSTER -> handleDeviceRosterAnnounce(body)
                // 30 (handled-elsewhere) rides the same sealed+signed path: it can silence a ringing
                // device, so it must be no more forgeable than an invite or a hangup. 22 (camera
                // state) was declared and handled in CallManager but never routed here, so a peer
                // turning their camera off left everyone staring at a frozen last frame.
                CallWire.INVITE, CallWire.ACCEPT, CallWire.HANGUP, CallWire.OFFER,
                CallWire.ANSWER, CallWire.ICE, CallWire.GROUP_INVITE, CallWire.HANDLED_ELSEWHERE,
                CallWire.CAMERA ->
                    withContext(Dispatchers.Main) { callRouter?.invoke(type, body) }
                // 31/32 are media frames, not call signaling, so they're handled here rather than in
                // CallManager — but they borrow the call path's sealing because one asks an author to
                // spend upload bandwidth and the other triggers a notification and a fetch.
                Wire.MEDIA_WANTED -> handleMediaWanted(body)
                Wire.MEDIA_AVAILABLE -> withContext(Dispatchers.Main) { handleMediaAvailable(body) }
                else -> Log.d(TAG, "ignoring frame type $type (not yet handled)")
            }
        }
    }

    /** CallManager registers here to receive call frames (kept as a hook to avoid a hard dependency). */
    var callRouter: ((type: Int, body: ByteArray) -> Unit)? = null

    /** Send a call signaling frame to one node (used by CallManager): direct AND live-forwarded
     *  through the circle relays (frame 9 — the relay host unwraps + sends it onward over its own
     *  connections). Cross-NAT fallback: a callee whose direct dial back to the caller fails still
     *  lands the ACCEPT within the ring window (the push rings, but the answer path was direct-only). */
    fun sendCallFrame(type: Int, payload: ByteArray, toNodeHex: String) {
        val frame = Wire.frame(type, payload)
        sendFrame(type, payload, toNodeHex)
        val dests = LinkedHashSet<String>()
        // Prefer roster device ids for this account; fall back to account hex + invite hints.
        dests.addAll(runCatching { social.deviceNodeIdsFor(toNodeHex) }.getOrDefault(emptyList()))
        dests.add(toNodeHex.lowercase())
        if (dests.size <= 1) dests.addAll(deviceHintsFor(toNodeHex))
        if (dests.isEmpty()) dests.add(toNodeHex)
        originateRelayInternet(dests.toList(), frame)
        // HTTP live-lane when iroh dial is unreachable (mailbox __live__/<dest>/).
        // Only fan out to account + roster devices — not every historical hint (floods ICE/answer).
        val liveDests = LinkedHashSet<String>()
        liveDests.add(toNodeHex.lowercase())
        liveDests.addAll(runCatching { social.deviceNodeIdsFor(toNodeHex) }.getOrDefault(emptyList()))
        if (liveDests.size <= 1) liveDests.addAll(deviceHintsFor(toNodeHex).take(2))
        scope.launch { uploadLiveCallFrame(liveDests.toList(), frame) }
    }

    /** PUT sealed call wire frames under haven/mailbox/<circle>/__live__/<dest>/<hash>. */
    private suspend fun uploadLiveCallFrame(dests: List<String>, frame: ByteArray) {
        if (!ready || dests.isEmpty() || frame.isEmpty()) return
        val circles = LinkedHashSet<String>()
        circles.add(DEFAULT_CIRCLE)
        runCatching {
            for (c in social.circles()) {
                if (c.id.startsWith("dm:")) circles.add(c.id)
            }
        }
        val h = MessageDigest.getInstance("SHA-256").digest(frame)
            .joinToString("") { "%02x".format(it) }
        val cleanDests = dests.map { it.lowercase() }.filter { it.length == 64 }.distinct()
        if (cleanDests.isEmpty()) return
        for (circleId in circles) {
            for (dest in cleanDests) {
                val key = "haven/mailbox/$circleId/__live__/$dest/$h"
                var landed = false
                for (nodeHex in relaysFor(circleId)) {
                    if (nodeHex.startsWith("s3:")) continue
                    val entry = relayEntries[nodeHex] ?: continue
                    if (entry.httpToken.isEmpty()) continue
                    for (base in httpUrlsFor(entry)) {
                        val r = relayHttpPut(base, entry.httpToken, key, frame)
                        if (r.isSuccess) {
                            landed = true
                            markRelayOk(nodeHex)
                            Log.i(TAG, "live-call http-put OK type=${frame[0].toInt() and 0xFF} to=${dest.take(8)} relay=${nodeHex.take(8)}")
                            break
                        }
                        if (r.exceptionOrNull() is RelayForbidden) {
                            noteRefused(nodeHex, "live-call put")
                            break
                        }
                        markHttpUrlBad(base)
                    }
                    if (landed) break
                }
                // Do NOT markSeen on put — the destination must still be able to list+ingest.
                // (Content-addressed keys make re-puts idempotent without a local skip.)
            }
        }
    }

    /** Poll __live__/<me>/ call frames and dispatch to callRouter. */
    private suspend fun pollLiveCallFrames(): Boolean {
        if (!ready) return false
        ensureSeenMailboxLoaded()
        val meDev = runCatching { social.myDeviceNodeHex() }.getOrDefault("").lowercase()
        val meAcct = nodeIdHex.lowercase()
        val mine = listOf(meDev, meAcct).filter { it.length == 64 }.distinct()
        if (mine.isEmpty()) return false
        val circles = LinkedHashSet<String>()
        circles.add(DEFAULT_CIRCLE)
        runCatching { for (c in social.circles()) circles.add(c.id) }
        var changed = false
        val callTypes = setOf(
            CallWire.INVITE, CallWire.ACCEPT, CallWire.HANGUP, CallWire.OFFER,
            CallWire.ANSWER, CallWire.ICE, CallWire.GROUP_INVITE,
            CallWire.HANDLED_ELSEWHERE, CallWire.CAMERA,
        )
        for (circleId in circles) {
            val relays = relaysFor(circleId).toMutableList()
            if (defaultRelayHex.isNotEmpty()) relays.add(defaultRelayHex)
            for (nodeHex in relays.distinct()) {
                if (nodeHex.startsWith("s3:")) continue
                val entry = relayEntries[nodeHex] ?: continue
                if (entry.httpToken.isEmpty()) continue
                for (who in mine) {
                    val prefix = "haven/mailbox/$circleId/__live__/$who/"
                    // Delta-LIST: echo the last digest for this (relay, prefix) so the idle 2s/12s
                    // sweeps of every DM×device lane collapse to bodiless 204s — this LIST was ~98%
                    // of the path-proxy log (the __live__ storm).
                    val digestKey = "$nodeHex|$prefix"
                    for (base in httpUrlsFor(entry)) {
                        val cached = synchronized(mailboxListDigests) { mailboxListDigests[digestKey] }
                        val listed = relayHttpListDelta(base, entry.httpToken, prefix, cached)
                        if (listed.isFailure) {
                            if (listed.exceptionOrNull() is RelayForbidden) break
                            markHttpUrlBad(base)
                            continue
                        }
                        markRelayOk(nodeHex)
                        val (keys, respDigest) = listed.getOrDefault(null to null)
                        if (keys == null) break   // 204: unchanged key set — nothing to GET
                        for (key in keys) {
                            // Claim the key immediately so a concurrent 2s poll cannot double-dispatch.
                            if (isMailboxSeen(key)) continue
                            markMailboxSeen(key)
                            val env = relayHttpGet(base, entry.httpToken, key).getOrNull() ?: continue
                            if (env.isEmpty()) continue
                            val type = env[0].toInt() and 0xFF
                            val body = env.copyOfRange(1, env.size)
                            if (type in callTypes) {
                                withContext(Dispatchers.Main) { callRouter?.invoke(type, body) }
                                Log.i(TAG, "live-call http-ingest type=$type key=${key.substringAfterLast('/').take(12)}")
                                changed = true
                            }
                        }
                        // Every listed key was claimed above, so the digest may be committed — a 204
                        // next poll skips nothing we still owe a GET.
                        if (!respDigest.isNullOrEmpty()) synchronized(mailboxListDigests) {
                            mailboxListDigests[digestKey] = respDigest
                            if (mailboxListDigests.size > 500) mailboxListDigests.clear()
                        }
                        break
                    }
                }
            }
        }
        return changed
    }

    // ---- "Tell me when this media is back" (frames 31/32; iOS parity) ---------------------

    /** Body of both media frames: `[hex64 me][LP ref][LP circleId][LP postId]`. */
    private fun mediaFrameBody(ref: String, circleId: String, postId: String): ByteArray {
        val out = ArrayList<Byte>()
        nodeIdHex.toByteArray(Charsets.UTF_8).forEach { out.add(it) }
        Wire.lpAppend(out, ref.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, circleId.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, postId.toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    /** (from, ref, circleId, postId) — null if the frame is malformed. */
    private fun parseMediaFrame(body: ByteArray): Quadruple? {
        if (body.size <= 64) return null
        val from = runCatching { String(body.copyOfRange(0, 64), Charsets.UTF_8) }.getOrNull() ?: return null
        if (from.length != 64) return null
        val r = Wire.Reader(body, 64)
        val ref = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        val circleId = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        val postId = r.lp()?.let { String(it, Charsets.UTF_8) } ?: return null
        if (ref.isEmpty() || circleId.isEmpty()) return null
        return Quadruple(from.lowercase(), ref, circleId, postId)
    }

    private data class Quadruple(val from: String, val ref: String, val circleId: String, val postId: String)

    /**
     * Ask a post's AUTHOR to re-upload media a relay has swept, and remember that I asked.
     *
     * The request rides the sealed frame path, which means the circle mailbox carries it: an author
     * who is offline for a week gets it the moment they next sync. That is the whole mechanism —
     * nothing is parked on a relay by hand, and no relay change was needed.
     */
    fun requestMediaWhenAvailable(ref: String, circleId: String, postId: String, authorShort: String,
                                  manual: Boolean = false) {
        val authorHex = idHexFor(authorShort)
        if (authorHex == null) {
            // MINE, AND THIS DEVICE HAS NO COPY. `idHexFor` cannot resolve me — I am not my own
            // contact — so a post I authored on ANOTHER of my devices landed here and gave up, every
            // time, including behind the "Notify me when it's back" button. "My own media needs
            // nobody's permission" is true of the ACCOUNT and false of the DEVICE: the device that
            // holds it is the one to ask. (Apple parity: `requestMediaWhenAvailable`.)
            val mine = authorShort.isEmpty() || social.myNodeHex().startsWith(authorShort, ignoreCase = true)
            if (mine && !LocalMedia.has(ref)) {
                Log.i(TAG, "media-wanted ${ref.take(10)}: MINE but no plaintext here — asking my other devices")
                MediaWantedStore.add(ref, manualAsk = manual)
                val ask = nodeIdHex.toByteArray(Charsets.UTF_8) + ref.toByteArray(Charsets.UTF_8)
                liveDeliverToMyDevices(Wire.MEDIA_REQ, ask)
                return
            }
            Log.i(TAG, "media-wanted ${ref.take(10)}: author not resolvable — cannot ask")
            return
        }
        // `manual` rides into the store, which persists it — an author offline for a week must
        // still be able to earn the notification a person actually asked for.
        MediaWantedStore.add(ref, manualAsk = manual)
        CallManager.sealedSend(Wire.MEDIA_WANTED, mediaFrameBody(ref, circleId, postId), authorHex)
        Log.i(TAG, "media-wanted ${ref.take(10)} → author ${authorHex.take(8)}")
    }

    /**
     * Author side: someone wants media from a post of mine that a relay no longer holds. If I still
     * have the original, put it back on a relay we share and tell them when it lands.
     *
     * This is the point of the feature: media stays reachable for as long as its AUTHOR keeps a
     * copy, rather than for as long as a relay's retention window.
     */
    /** Refs we've recently put back, and refs a re-upload is in flight for. A frame 31 costs the
     *  RECIPIENT a full blob upload, so an unbounded one-upload-per-frame handler is a bandwidth
     *  amplifier a circle member can point at us. Within the cooldown we answer from what we already
     *  did — re-sending frame 32 is cheap and is the honest answer, because the blob really is back. */
    private val mediaServedAt = LinkedHashMap<String, Long>()
    private val mediaServing = HashSet<String>()
    private const val MEDIA_RESERVE_COOLDOWN_MS = 10 * 60 * 1000L

    private suspend fun handleMediaWanted(sealedBody: ByteArray) {
        val body = CallManager.openSealed(Wire.MEDIA_WANTED, sealedBody) ?: return
        val f = parseMediaFrame(body) ?: return
        if (!isContact(f.from)) return   // only my circle may ask
        // Only serve a circle they're actually in — a request NAMES a circle, and naming one is not
        // the same as belonging to it.
        val members = runCatching { social.contactNodeIds(f.circleId) }.getOrDefault(emptyList())
        if (members.none { it.equals(f.from, ignoreCase = true) || it.lowercase().startsWith(f.from.take(16)) }) {
            Log.i(TAG, "media-wanted ${f.ref.take(10)} from ${f.from.take(8)} — not a member of ${f.circleId.take(12)}, ignoring")
            return
        }
        if (!LocalMedia.has(f.ref)) {
            Log.i(TAG, "media-wanted ${f.ref.take(10)} from ${f.from.take(8)} — I don't hold it either")
            return
        }
        // Holding the SEALED blob is not enough to repair it — see the iOS handler. The asker almost
        // certainly is not one of its recipients, and only a FRESH seal from the PLAINTEXT can add
        // them. If we cannot open our own copy we cannot re-seal it, and answering would put back
        // byte-identical bytes and report success. Stay quiet so the ask reaches a device that can.
        if (LocalMedia.load(f.circleId, f.ref) == null) {
            Log.i(TAG, "media-wanted ${f.ref.take(10)} from ${f.from.take(8)} — cannot open our own copy; cannot re-seal, not answering")
            return
        }
        // Already put this one back a moment ago (or two people asked at once): don't pay for the
        // upload again, just answer. The blob is on the relay either way, which is all 32 claims.
        val now = System.currentTimeMillis()
        val servedRecently = synchronized(mediaServedAt) {
            val at = mediaServedAt[f.ref]
            at != null && now - at < MEDIA_RESERVE_COOLDOWN_MS
        }
        if (servedRecently) {
            CallManager.sealedSend(Wire.MEDIA_AVAILABLE, mediaFrameBody(f.ref, f.circleId, f.postId), f.from)
            Log.i(TAG, "media-wanted ${f.ref.take(10)}: served recently — re-answering without re-upload")
            return
        }
        if (!synchronized(mediaServing) { mediaServing.add(f.ref) }) {
            Log.i(TAG, "media-wanted ${f.ref.take(10)}: re-upload already in flight — dropping duplicate ask")
            return
        }
        Log.i(TAG, "media-wanted ${f.ref.take(10)} from ${f.from.take(8)} — re-uploading to a shared relay")
        // force = true: the "already has it" probe consults a ledger and the relay's own answer, and
        // a relay that has SWEPT the blob is exactly the case where both can say "held" and skip the
        // upload the asker is waiting for.
        val ok = try {
            uploadMedia(f.circleId, f.ref, force = true, reseal = true)
        } finally {
            synchronized(mediaServing) { mediaServing.remove(f.ref) }
        }
        if (!ok) {
            Log.i(TAG, "media-wanted ${f.ref.take(10)}: re-upload failed — they'll re-ask")
            return
        }
        synchronized(mediaServedAt) {
            mediaServedAt[f.ref] = now
            while (mediaServedAt.size > 500) mediaServedAt.remove(mediaServedAt.keys.first())
        }
        CallManager.sealedSend(Wire.MEDIA_AVAILABLE, mediaFrameBody(f.ref, f.circleId, f.postId), f.from)
        Log.i(TAG, "media-wanted ${f.ref.take(10)}: back on a relay, told ${f.from.take(8)}")
    }

    /**
     * Author-side push-ahead: a FRESH post's blob just reached a relay (priority backup lane) —
     * proactively tell the whole circle with the SAME frame-32 shape as the ask-back reply, plus a
     * silent push so a backgrounded member wakes and prefetches. This is what makes media drop in
     * WITH the post instead of on the recipient's next missing-media sweep. postId is best-effort
     * (a deep-link nicety); the receiver keys on the ref. Apple FeedStore.announceMediaLanded.
     */
    private fun announceMediaLanded(ref: String, circleId: String) {
        val postId = runCatching {
            social.feed(circleId, nowMs(), null).firstOrNull { item ->
                item.isMe && (item.media.contains(ref) ||
                    MediaVariants.allThumbs(item.media).contains(ref) ||
                    item.media.mapNotNull { MediaVariants.parsePoster(it)?.second }.contains(ref))
            }?.id
        }.getOrNull() ?: ""
        val body = mediaFrameBody(ref, circleId, postId)
        for (member in runCatching { social.contactNodeIds(circleId) }.getOrDefault(emptyList())) {
            CallManager.sealedSend(Wire.MEDIA_AVAILABLE, body, member)
            pushWake(member, ciphertextB64 = null, eventB64 = null, silent = true)
        }
        Log.i(TAG, "media-landed ${ref.take(10)} announced to circle ${circleId.take(12)}")
    }

    /** Per-ref throttle for acting on unsolicited frame-32 announces (the author push-ahead). */
    private val announcedMediaAt = HashMap<String, Long>()

    /** Requester side: media I asked about is back. Notify with a deep link straight to the post. */
    private fun handleMediaAvailable(sealedBody: ByteArray) {
        val body = CallManager.openSealed(Wire.MEDIA_AVAILABLE, sealedBody) ?: return
        val f = parseMediaFrame(body) ?: return
        if (!isContact(f.from)) return
        if (!MediaWantedStore.isWanted(f.ref)) {
            // Not something we asked for → an author's push-ahead announce (their fresh post's
            // media just landed on a relay). Prefetch it anyway — bounded, deduped, and data-saver
            // aware (videos stay tap-to-play under super data saver). No notification: the POST's
            // banner is the news; this is just its media arriving on time. Apple parity.
            if (LocalMedia.isSynthetic(f.ref) || LocalMedia.has(f.ref) ||
                EvictedMediaStore.contains(f.ref)) return
            val saver = runCatching { ProfileStore.get(appContext).superDataSaver }.getOrDefault(false)
            if (saver && !(f.ref.startsWith("img_") || f.ref.startsWith("i:") ||
                    f.ref.startsWith("aud_") || f.ref.startsWith("a:") || f.ref.startsWith("file_"))) return
            val now = System.currentTimeMillis()
            synchronized(announcedMediaAt) {
                val last = announcedMediaAt[f.ref]
                if (last != null && now - last < 60_000) return
                announcedMediaAt[f.ref] = now
                if (announcedMediaAt.size > 500) announcedMediaAt.clear()
            }
            synchronized(fastReq) { fastReq.remove(f.ref) }   // it's on a relay NOW — restart the lane
            waitingForSenderMedia.remove(f.ref)
            val cid = if (runCatching { social.circles() }.getOrDefault(emptyList())
                    .any { it.id == f.circleId }) f.circleId else activeCircle.value
            enqueueRestore(cid, f.ref)
            Log.i(TAG, "media-available ${f.ref.take(10)}: announced by ${f.from.take(8)} — prefetching")
            return
        }
        MediaWantedStore.clear(f.ref)
        unavailableMedia.remove(f.ref)
        waitingForSenderMedia.remove(f.ref)
        synchronized(fastReq) { fastReq.remove(f.ref) }
        EvictedMediaStore.clear(f.ref)
        // A blob we HOLD but cannot open must be dropped before the pull, or nothing happens:
        // downloadEvicted returns early on `LocalMedia.has(ref)`, so the reader kept its broken
        // copy and ignored the very re-seal it just asked for. The author only re-uploads because
        // we said we could not read it, so the local bytes are exactly the ones to discard.
        // `false` (opened for no circle) AND `null` (could not even be judged — a legacy JSON
        // envelope too large to parse) both mean "the copy we hold is no use to us". Only the
        // false case was handled, so a blob that failed to PARSE kept its broken bytes forever and
        // ignored the very re-seal it asked for — the last stuck video on a real device.
        if (LocalMedia.has(f.ref) && LocalMedia.opensForAnyCircle(f.ref) != true) {
            Log.i(TAG, "media-available ${f.ref.take(10)}: dropping our unreadable copy so the re-seal can land")
            LocalMedia.delete(f.ref)
            unopenableMedia.remove(f.ref)
            saveUnopenable()
        }
        downloadEvicted(f.ref)   // pull it now, while we know it's there
        // Silent unless the user personally asked. The automatic sweep repairs media constantly and
        // nobody needs to be told; they need the picture to appear, which it now does.
        if (!MediaWantedStore.takeManual(f.ref)) {
            Log.i(TAG, "media-wanted ${f.ref.take(10)}: author says it's back — fetching (automatic, no notification)")
            return
        }
        val who = displayName(f.from.take(8))
        Notifications.notify(
            appContext,
            "Media is available again",
            "$who put back the media you asked for.",
            deepLink = if (f.postId.isEmpty()) null else DeepLink.internalPostUrl(f.circleId, f.postId),
        )
        Log.i(TAG, "media-wanted ${f.ref.take(10)}: author says it's back — fetching")
    }

    // ---- Frame-9 mesh relay (internet live-forward; wire parity with iOS emitRelay) --------
    //   [16B msgId][1B ttl][1B destCount][32B × dest][inner frame]

    private val seenRelay = LinkedHashSet<String>()

    private fun hexToBytes32(hex: String): ByteArray? {
        if (hex.length != 64) return null
        return runCatching { ByteArray(32) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() } }.getOrNull()
    }
    private fun bytesToHex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    /** Originate a live frame-9 forward of [inner] to [dests] via up to 3 adopted internet relays. */
    private fun originateRelayInternet(dests: List<String>, inner: ByteArray) {
        val destBytes = dests.mapNotNull { hexToBytes32(it) }
        if (destBytes.isEmpty()) return
        val msgId = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        seenRelay.add(bytesToHex(msgId))   // don't reprocess our own
        if (seenRelay.size > 2000) seenRelay.clear()
        val out = java.io.ByteArrayOutputStream()
        out.write(msgId); out.write(4); out.write(minOf(destBytes.size, 255))
        for (d in destBytes.take(255)) out.write(d)
        out.write(inner)
        val p = out.toByteArray()
        val mineAcct = nodeIdHex.lowercase()
        val mineDev = runCatching { social.myDeviceNodeHex() }.getOrDefault("").lowercase()
        var sent = 0
        for (relayHex in relayNodes.values.flatten().distinct()) {
            val h = relayHex.lowercase()
            if (h.startsWith("s3:") || h == mineAcct || h == mineDev) continue
            sendFrame(Wire.RELAY, p, relayHex)
            if (++sent >= 3) break
        }
    }

    /** Frame-9 mesh relay: process the inner frame if we're a destination, and forward it onward
     *  to the other destinations (we may be the relay host the sender hopped through). */
    private fun handleRelay(body: ByteArray, viaNearby: Boolean) {
        if (body.size < 18) return
        val key = bytesToHex(body.copyOfRange(0, 16))
        if (!seenRelay.add(key)) return   // dedup / loop protection
        if (seenRelay.size > 2000) { seenRelay.clear(); seenRelay.add(key) }
        val ttl = body[16].toInt() and 0xFF
        val destCount = body[17].toInt() and 0xFF
        var off = 18
        if (body.size < off + destCount * 32) return
        val dests = ArrayList<String>(destCount)
        repeat(destCount) {
            dests.add(bytesToHex(body.copyOfRange(off, off + 32)))
            off += 32
        }
        val inner = body.copyOfRange(off, body.size)
        if (inner.isEmpty()) return
        val meAcct = nodeIdHex.lowercase()
        val meDev = runCatching { social.myDeviceNodeHex() }.getOrDefault("").lowercase()
        if (dests.any { it.lowercase() == meAcct || it.lowercase() == meDev }) onInbound(inner, viaNearby)
        if (ttl <= 0) return
        val n = node ?: return
        for (dest in dests) {
            val d = dest.lowercase()
            if (d == meAcct || d == meDev) continue
            scope.launch { runCatching { n.sendToNode(dest, inner) } }
        }
    }

    /** Outcome of ingesting one HELLO. [consumed] = true when the hello was APPLIED or
     *  deliberately dropped — safe for a mailbox caller to mark its slot seen. False means NOT
     *  applied (held for connection approval, transient engine failure): the mailbox slot must
     *  stay UNCLAIMED so a later poll retries — once the gate clears (user approves, contacts
     *  converge) the SAME slot re-processes and the circle grant riding it finally applies.
     *  Marking held hellos seen is exactly how the E2E stub's circle invite evaporated: claimed
     *  at fetch, quarantined at the approval gate, seen forever. [why] feeds the one-line claim
     *  log in pollMailbox (iOS pullMailbox parity). */
    private data class HelloOutcome(val consumed: Boolean, val why: String)

    private fun handleHello(payload: ByteArray, viaNearby: Boolean = false, senderDevice: String? = null): HelloOutcome {
        val hello = Wire.parseHello(payload) ?: return HelloOutcome(true, "malformed")
        val idHex = nodeHex(hello.bundle)
        if (blocked.contains(idHex)) return HelloOutcome(true, "blocked")   // a blocked node can't handshake back in
        // A hello delivered DIRECTLY teaches us the sender's dialable device id for this account —
        // the reply-path bootstrap (their signed roster supersedes; a wrong hint only misroutes
        // sealed frames, same trust model as invite-link hints).
        if (senderDevice != null && senderDevice.length == 64 && !senderDevice.equals(idHex, ignoreCase = true)) {
            recordDeviceHints(idHex, listOf(senderDevice))
        }
        val actualVerify = runCatching { social.bundleVerificationHex(hello.bundle) }.getOrNull()
            ?: return HelloOutcome(true, "malformed")
        val name = runCatching { social.verifyProfile(hello.bundle, hello.signedProfile) }.getOrNull() ?: "Someone"
        // Capture the full profile card (avatar + emoji) so the feed/people/story-tray show real photos.
        runCatching { social.verifyProfileCard(hello.bundle, hello.signedProfile) }.getOrNull()
            ?.let { AvatarStore.put(idHex, it.avatar, it.emoji) }

        // DM circles encode both full node ids — only those two may ever join (MITM/contamination guard).
        if (hello.circleId.startsWith("dm:") && !dmAllows(hello.circleId, idHex)) return HelloOutcome(true, "dm-third-party")
        // A member you explicitly removed from THIS circle must NOT auto-rejoin on their handshake
        // (parity with iOS). A removed person keeps broadcasting Hellos — they don't know they're gone —
        // and without this guard the "already a contact" branch below silently re-added them to the very
        // circle you removed them from, so the removal never stuck. A deliberate re-add clears the
        // tombstone (addToCircle), so this only blocks the unsolicited rejoin.
        // ...but silently DROPPING it made a removal permanent AND mutual. Clearing the tombstone
        // only ever happens on YOUR side when YOU re-add them, so once two people had removed each
        // other neither could reconnect by any route: their deliberate request died on your
        // tombstone, yours died on theirs, and both sides just saw "waiting" forever. Ask instead
        // of dropping — consent is still required, nothing auto-rejoins, and approving clears the
        // tombstone. Proximity and DM hellos keep dropping: neither is a deliberate request.
        if (isRemovedFromCircle(hello.circleId, idHex)) {
            if (viaNearby || hello.circleId.startsWith("dm:")) return HelloOutcome(true, "removed-from-circle")
            scope.launch(Dispatchers.Main) {
                if (pending.none { it.idHex == idHex }) {
                    pending.add(PendingRequest(idHex, name, actualVerify, hello.bundle, hello.circleId, hello.circleName))
                }
            }
            // NOT consumed — the circle grant must survive until the user decides (stranger parity).
            return HelloOutcome(false, "removed-needs-approval")
        }
        // A verified Hello forms the circle on our side if we don't have it yet (matches iOS).
        val isNewCircle = hello.circleId != DEFAULT_CIRCLE && !hello.circleId.startsWith("dm:") &&
            runCatching { social.circles() }.getOrDefault(emptyList()).none { it.id == hello.circleId }
        runCatching { social.createCircle(hello.circleId, hello.circleName) }
        // App-layer activity row: being added to a circle has no engine event to reduce.
        if (isNewCircle) ActivityStore.noteCircleAdd(hello.circleId, hello.circleName)
        // §5 — a dm: circle formed inbound is a live lane too (re-applied on launch by applyCryptoSwitches).
        if (hello.circleId.startsWith("dm:")) runCatching { social.setCircleLiveLane(hello.circleId, true) }

        val expected = initiated[idHex]
        if (expected != null) {
            // We scanned them first — auto-accept iff the bundle hash matches what the QR promised.
            if (expected.isNotEmpty() && expected != actualVerify) {
                Log.w(TAG, "verify mismatch for $idHex — dropping (possible MITM)")
                return HelloOutcome(true, "verify-mismatch")   // deliberate drop — the QR promise is firm
            }
            acceptContact(hello.circleId, hello.bundle, idHex, name, actualVerify, helloBack = true)
            forgetInitiated(idHex)
            return HelloOutcome(true, "applied")
        }
        if (contacts.any { it.idHex == idHex }) {
            // Already a contact (e.g. their Hello-back) — make sure their bundle is in the circle.
            // This is also where a formerly-HELD hello lands after approval: the retained mailbox
            // slot re-processes and the ORIGINAL circle grant it carries applies right here.
            if (runCatching { social.addContactBundle(hello.circleId, hello.bundle) }.isFailure) {
                return HelloOutcome(false, "engine-add-failed")   // transient — leave the slot for the next poll
            }
            return HelloOutcome(true, "applied")
        }
        // A hello carrying a DEVICE bundle of an account we ALREADY know is not a new person. A linked
        // (seedless) device signs with its own key and carries its OWN bundle, so without this it lands
        // as a SECOND contact for someone we're already connected to: a connection request from an
        // identity we're already connected to, which — once accepted — shows as "Someone" and is never
        // online, because a contact record built from a device id names no account to route to.
        //
        // The device→account mapping comes from their ACCOUNT-SIGNED roster (verify_devroster), so a
        // stranger cannot claim to be somebody's device; an unknown device id maps to nothing and still
        // takes the normal approval path below. iOS parity.
        val ownerAccount = runCatching { social.accountForDevice(idHex) }.getOrNull()?.lowercase()
        if (ownerAccount != null && !ownerAccount.equals(idHex, ignoreCase = true)) {
            recordDeviceHints(ownerAccount, listOf(idHex))
            Log.i(TAG, "hello from ${idHex.take(8)} is a DEVICE of known account ${ownerAccount.take(8)} — recorded as their device, not a new contact")
            return HelloOutcome(true, "known-device")
        }
        // ENGINE-KNOWN MEMBER: the ENGINE already lists this account in one of my circles — an
        // established relationship (I invited or approved them, possibly on a linked device before
        // the contacts list converged, or the list lagged a restore). They are not "someone new":
        // re-gating them as a stranger strands every hello they send — the circle grant riding the
        // hello was quarantined as a pending request nobody acted on, and the circle never formed.
        // Same principle as the device-of-known-account rule above, at account level. Adopt the
        // contact record and continue the normal handshake. A contact the user explicitly REMOVED
        // (LWW tombstone) still takes the approval path. (iOS handleHello parity.)
        val engineKnows = !ContactRemovals.isRemoved(idHex) &&
            runCatching { social.circles() }.getOrDefault(emptyList()).any { c ->
                runCatching { social.contactNodeIds(c.id) }.getOrDefault(emptyList())
                    .any { it.equals(idHex, ignoreCase = true) }
            }
        if (engineKnows) {
            Log.i(TAG, "hello from ${idHex.take(8)} is an engine-known circle member — adopted as contact, handshake continues")
            acceptContact(hello.circleId, hello.bundle, idHex, name, actualVerify, helloBack = true)
            return HelloOutcome(true, "applied")
        }
        // Unknown sender on a non-DM circle → a request to approve — UNLESS it merely arrived over the
        // proximity mesh (nearby ≠ intent to connect; that flooded the user with spurious requests).
        if (viaNearby) return HelloOutcome(true, "nearby-stranger")
        if (!hello.circleId.startsWith("dm:")) {
            scope.launch(Dispatchers.Main) {
                if (pending.none { it.idHex == idHex }) {
                    pending.add(PendingRequest(idHex, name, actualVerify, hello.bundle, hello.circleId, hello.circleName))
                }
            }
        }
        // NOT consumed: the circle grant this hello carries must survive until the user decides.
        // Approval re-processes the retained mailbox slot on the next poll (the already-a-contact
        // branch above) and applies the ORIGINAL grant; a dm: stranger holds the same way until
        // they become a contact. Marking held hellos seen is how invites used to evaporate.
        return HelloOutcome(false, "held-for-approval")
    }

    // ---- DMs (a DM is a private 2-person circle, id encodes both node ids) ----------------

    /** Deterministic DM circle id — identical on both sides (full sorted node ids). */
    fun dmCircleId(idHex: String): String {
        val pair = listOf(nodeIdHex, idHex).sorted()
        return "dm:${pair[0]}-${pair[1]}"
    }

    private fun dmAllows(circleId: String, nodeHex: String): Boolean {
        // 2+ members so group DMs are admitted too; the sender must be one of the encoded members.
        val parts = circleId.removePrefix("dm:").split("-")
        return parts.size >= 2 && parts.contains(nodeHex)
    }

    /** Open (or create) a DM with a known contact; returns the dm circle id. */
    fun startDm(contact: Contact): String {
        val id = dmCircleId(contact.idHex)
        CircleDeletion.markRecreated(id)   // re-opening a DM lifts any prior deletion (LWW)
        runCatching { social.createCircle(id, contact.name) }
        runCatching { social.addExistingToCircle(id, contact.idHex) }
        runCatching { social.setCircleLiveLane(id, true) }   // §5 — dm: circle → per-message forward secrecy
        persist()
        sendHello(id, contact.idHex)
        selfSyncNudge()   // the new DM (+ any lifted deletion) appears on my other devices in seconds
        return id
    }

    /**
     * Matrix QA: if the driver staged `files/qa-peer-bundle.bin` (+ optional name), add that peer
     * as a contact so reverse posts/stories/DMs/media can open without a live HELLO dial.
     */
    private fun ingestQaPeerBundle() {
        if (!BuildConfig.DEBUG) return
        val f = java.io.File(appContext.filesDir, "qa-peer-bundle.bin")
        if (!f.isFile || f.length() == 0L) return
        val bundle = f.readBytes()
        val name = java.io.File(appContext.filesDir, "qa-peer-name.txt")
            .takeIf { it.isFile }?.readText()?.trim().orEmpty().ifBlank { "SimPeer" }
        val hex = runCatching { social.addContactBundle(DEFAULT_CIRCLE, bundle) }.getOrNull()
        if (hex.isNullOrEmpty()) {
            Log.w("HavenQA", "qa-peer-bundle addContactBundle failed")
            return
        }
        // Surface in the contacts list with a friendly name when possible.
        runCatching {
            val c = contacts.firstOrNull { it.idHex.equals(hex, ignoreCase = true) }
            if (c != null && name.isNotEmpty()) {
                // Profile name often arrives via signed card later; log for the matrix driver.
            }
        }
        Log.i("HavenQA", "qa-peer-bundle ingested hex=${hex.take(12)} name=$name")
        // One-shot: avoid re-adding every launch if the peer re-seals.
        f.delete()
    }

    /** Deterministic GROUP-DM circle id — sorted full node ids of every member (me + others), so the
     *  same set of people always maps to the same thread on every device. */
    fun groupDMCircleId(otherHexes: List<String>): String {
        val all = (otherHexes + nodeIdHex).map { it.lowercase() }.distinct().sorted()
        return "dm:" + all.joinToString("-")
    }

    /** The member node ids encoded in a dm: circle id (includes me). */
    fun dmMemberHexes(circleId: String): List<String> =
        circleId.removePrefix("dm:").split("-").filter { it.length == 64 }

    /** A friendly title for a dm thread: the OTHER members' display names, joined. */
    fun dmPartnerName(circleId: String): String {
        val others = dmMemberHexes(circleId).filter { it != nodeIdHex.lowercase() }
        if (others.isEmpty()) return "You"
        return others.joinToString(", ") { hex -> displayName(hex.take(8)) }
    }

    /** Existing GROUP-DM threads (dm: circles with 3+ members) as (circleId, title) for the thread list. */
    fun groupDmThreads(): List<Pair<String, String>> =
        runCatching { social.circles() }.getOrDefault(emptyList())
            .filter { it.id.startsWith("dm:") && dmMemberHexes(it.id).size > 2 }
            .map { it.id to dmPartnerName(it.id) }

    /** Newest message time (ms) in a DM circle, honoring the cleared-before watermark; 0 if empty. */
    fun lastActivity(circleId: String): ULong =
        messages(circleId).maxOfOrNull { it.createdAt } ?: 0UL

    /** Open (or create) a GROUP DM with 2+ contacts; returns the dm circle id. */
    fun startGroupDM(contacts: List<Contact>): String {
        if (contacts.size == 1) return startDm(contacts[0])
        val id = groupDMCircleId(contacts.map { it.idHex })
        val title = contacts.joinToString(", ") { it.name }
        CircleDeletion.markRecreated(id)   // re-opening a group DM lifts any prior deletion (LWW)
        runCatching { social.createCircle(id, title) }
        runCatching { social.setCircleLiveLane(id, true) }   // §5 — group dm: circle → live lane
        for (c in contacts) runCatching { social.addExistingToCircle(id, c.idHex) }
        persist()
        for (c in contacts) sendHello(id, c.idHex)
        selfSyncNudge()   // the new group DM appears on my other devices in seconds
        return id
    }

    /** The messages of a circle (a DM thread), oldest→newest for chat display. Hides anything older
     *  than this DM's "cleared before" watermark so re-starting a (deterministic-id) DM shows fresh. */
    fun messages(circleId: String): List<uniffi.haven_ffi.FeedItemFfi> {
        maybePurgeExpiredMedia(circleId)   // really drop expired events + GC their blobs (throttled)
        // Honor this DM's viewer auto-delete window, same as the posts feed (CircleScreen) and iOS
        // (`messages(in:)`). A DM is a Post under a `dm:` circle, so both the sender's disappearing timer
        // and the viewer's retention setting apply; passing `null` here silently exempted DM threads.
        val all = runCatching { social.feed(circleId, nowMs(), CircleSettings.retentionSecs(circleId)) }.getOrDefault(emptyList())
            .sortedBy { it.createdAt }
        val cutoff = dmClearedBefore(circleId) ?: return all
        return all.filter { it.createdAt >= cutoff }
    }

    // ---- DM "cleared before" watermark ------------------------------------------------------------
    // Deleting a DM records now() here (persisted). Because a DM's circle id is deterministic,
    // re-starting/re-syncing it re-fetches the old messages (true network deletion is impossible in
    // P2P); the watermark hides everything from before the clear so a re-started DM shows fresh.
    private val dmPrefs get() = appContext.getSharedPreferences("haven.dm", Context.MODE_PRIVATE)

    /** Inbound messages in a DM newer than its READ watermark (see [DmRead]) — the row badge count. */
    fun unreadMessages(circleId: String): Int {
        val wm = DmRead.watermark(circleId)
        return messages(circleId).count { !it.isMe && !it.unsent && it.createdAt > wm }
    }

    /** The user is viewing a DM thread: advance its read watermark past the newest visible message
     *  (clears its badge here and, via self-sync, on the user's other devices). */
    fun markThreadRead(circleId: String) {
        DmRead.markRead(circleId, messages(circleId).maxOfOrNull { it.createdAt } ?: 0UL)
    }

    /** Messages-tab badge: the number of CONVERSATIONS with unread messages. Watermark-based, not a
     *  session counter — it survives relaunch and clears only as threads are actually read. */
    fun unreadDmConversations(): Int =
        runCatching { social.circles() }.getOrDefault(emptyList())
            .count { it.id.startsWith("dm:") && unreadMessages(it.id) > 0 }

    /** The "cleared before" watermark (ms) for a DM circle, or null if never cleared. */
    fun dmClearedBefore(circleId: String): ULong? {
        val v = dmPrefs.getLong("cleared.$circleId", -1L)
        return if (v < 0L) null else v.toULong()
    }

    private fun clearDmBefore(circleId: String) {
        dmPrefs.edit().putLong("cleared.$circleId", nowMs().toLong()).apply()
    }

    /** True if [circleId] is a GROUP dm (3+ members including me), for per-message sender labels. */
    fun isGroupDm(circleId: String): Boolean =
        circleId.startsWith("dm:") && dmMemberHexes(circleId).size > 2

    /** Delete a whole DM conversation locally: watermark it (so re-syncing/re-starting won't restore
     *  the old thread) and leave the circle. */
    fun deleteConversation(circleId: String) {
        if (!circleId.startsWith("dm:")) return
        clearDmBefore(circleId)
        CircleDeletion.markDeleted(circleId)   // LWW tombstone so a sibling can't restore the deleted DM
        runCatching { social.leaveCircle(circleId) }
        if (activeCircle.value == circleId) activeCircle.value = DEFAULT_CIRCLE
        persist(); bumpCircles(); scope.launch(Dispatchers.Main) { feedVersion.value++ }
        selfSyncNudge()   // the deletion tombstone travels now, before a sibling can re-broadcast the DM
        // No share tile for a conversation that's gone. Guarded: this can run before `init` on a
        // sync-driven path, and `appContext` is lateinit.
        runCatching { ShareShortcuts.remove(appContext, circleId) }
    }

    /** Send a text DM into a circle and deliver it to the partner. */
    fun sendDm(circleId: String, body: String, media: List<String> = emptyList(),
               music: uniffi.haven_ffi.TrackRefFfi? = null, retentionSecs: ULong? = null) {
        if (body.isBlank() && media.isEmpty() && music == null) return
        val withThumbs = withThumbMarkers(media)
        val ts = nowMs()
        // retentionSecs != null → a disappearing message (auto-expires in the feed reducer, iOS parity).
        val env = runCatching {
            social.post(circleId, body, withThumbs, music, retentionSecs, false, false, ts)
        }.getOrNull() ?: return
        // The engine derives event ids internally (BLAKE3 at author time) — read back the id of the
        // message just created so the sealed banner's `p` deep-link opens THIS thread entry (Apple
        // FeedStore.sendMessage parity). Best-effort: null keeps the legacy circle route.
        val postId = runCatching { social.lastAuthoredEventId(circleId, ts) }.getOrNull()
        afterAuthor(circleId, env,
            PushBanner.forPost(circleId, circleName(circleId), body, withThumbs, story = false, postId = postId))
        enqueueAuthoredMedia(circleId, withThumbs)   // priority lane, thumbs first
        // Sending into a thread is what makes it "recent" — republish so the Direct Share row is
        // ordered by the conversations the user is actually in.
        runCatching { ShareShortcuts.refresh(appContext) }
    }

    /**
     * Reply to someone's story → opens a DM with them and ATTACHES the story's media (re-sealed to
     * the DM circle) so the author knows exactly which story you mean. Returns the DM circle id.
     */
    fun replyToStory(authorShort: String, storyMediaRef: String?, text: String): String? {
        val contact = contacts.firstOrNull { it.idHex.startsWith(authorShort) } ?: return null
        val dmCircle = startDm(contact)
        val media = storyMediaRef?.let { ref ->
            LocalMedia.loadAnyCircle(ref)?.let { listOf(LocalMedia.store(dmCircle, it, isVideo = LocalMedia.isVideo(ref))) }
        } ?: emptyList()
        sendDm(dmCircle, text, media)
        return dmCircle
    }

    /**
     * DM a post's author ABOUT that post, from the post's ⋯ menu — opens (or reuses) the DM and
     * STAGES a draft referencing the post. Sends nothing.
     *
     * It used to re-seal the post's media into the DM circle and send it immediately, which
     * published a message the user had not written yet. Referencing a post is the start of a
     * message, not one. The reference is the post's LINK: a draft that re-seals a whole video into
     * the DM does that work before the user has decided to send anything, and the link opens the
     * real post — media and all — for anyone already in the circle. (The link is a pointer, not a
     * capability; see [DeepLink].)
     *
     * Returns the DM circle id, or null if the author isn't a contact we hold. The caller routes to
     * the Messages surface — NOT [setActiveCircle], which points the CIRCLE selector at a `dm:` id
     * and drops the user into the feed layout instead of the conversation.
     */
    fun messageAuthor(authorShort: String, circleId: String, postId: String): String? {
        val contact = contacts.firstOrNull { it.idHex.startsWith(authorShort) } ?: return null
        val dmCircle = startDm(contact)
        DeepLink.postUrl(circleId, postId)?.let { DmDrafts.stage(dmCircle, it) }
        return dmCircle
    }

    /** [senderDevice] = the authenticated transport id this frame arrived from (null for nearby /
     *  relay-unwrapped frames), used to tell a CONTACT's delivery apart from one of my own devices'. */
    private fun handleEvent(payload: ByteArray, senderDevice: String? = null, viaNearby: Boolean = false) {
        val ev = Wire.parseEvent(payload) ?: return
        // Did this come from one of MY devices? Those already have it. Do NOT treat viaNearby as
        // own-device: Multipeer also carries CONTACT content when a friend is in the room, and
        // suppressing fan-out there left my other linked devices (off-mesh) without the event.
        // Loop safety is `receive` returning true only for NEW events.
        val mineAcct = runCatching { social.myNodeHex() }.getOrNull()?.lowercase()
        val mineDev = runCatching { social.myDeviceNodeHex() }.getOrNull()?.lowercase()
        val fromOwnDevice = senderDevice?.let { s ->
            val l = s.lowercase()
            l == mineAcct || l == mineDev || myOtherDeviceTargets().any { it == l }
        } ?: false
        val changed = runCatching { social.receive(ev.circleId, ev.envelope) }.getOrDefault(false)
        if (changed) {
            // FAN OUT to my other devices. A sender dials the device ids ITS copy of my roster
            // resolves — often just one — so a DM delivered straight to my tablet never reached my
            // phone. The send path has always done this for my OWN posts; the receive path must for
            // CONTACT posts too. Volume is bounded by real new-event traffic.
            if (!fromOwnDevice) {
                liveDeliverToMyDevices(Wire.EVENT, payload)
                // …and a silent push with the inline envelope for my POCKETED devices — live
                // delivery only reaches siblings that are online right now (iOS parity).
                pushSyncSelf(ev.envelope)
                // Internet/relay only: Multipeer already flooded the local mesh. Sealed — only
                // circle members + my own devices open it; helps a Multipeer sibling that has no
                // good internet path to the same mailbox.
                if (!viaNearby && NearbyTransport.active) {
                    NearbyTransport.broadcast(Wire.frame(Wire.EVENT, payload))
                }
            }
            bumpActivity()   // a live event arrived → keep sync tight while the conversation is active
            persist()
            scope.launch(Dispatchers.Main) { feedVersion.value++ }
            requestMissingMedia()   // fetch any photos/videos the new post references
            notifyInbound(ev.circleId)
            ActivityStore.poke(social)   // fresh rows for the bell (debounced engine reduce)
        }
    }

    /** Post a local notification for new inbound content when the app isn't foreground.
     *  Guarded two ways (this fired on ANY changed envelope — history backfill, epoch-rotation
     *  re-seals, key commits — so the same "new message" notified again and again):
     *  1. FRESH only — the circle's newest inbound item must be < 10 min old; an old message
     *     resurfacing is never worth a banner.
     *  2. Deduped on the newest item's id, PERSISTED — one banner per actual message, across
     *     relaunches and across however many envelopes/relays re-deliver it. */
    private fun notifyInbound(circleId: String) {
        if (isForeground) return
        val feed = runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList())
        val newest = feed.filter { !it.isMe }.maxByOrNull { it.createdAt } ?: return
        if (nowMs() - newest.createdAt > 600_000uL) return   // 10 min (ULong math; skew-safe enough)
        if (!markNotified("$circleId:${newest.id}")) return
        // PREFETCH-BEFORE-NOTIFY: kick the message's media fetches (poster/thumb first, data-saver
        // rules) so the bytes are downloading — often landed — by the time the user taps the
        // banner. Concurrent with the notify below (the restore queue drains off this thread);
        // covers both the FGS ingest path (handleEvent → here) and the SyncWorker poll.
        run {
            val saver = runCatching { ProfileStore.get(appContext).superDataSaver }.getOrDefault(false)
            val wanted = if (saver) MediaVariants.dataSaverPrefetchRefs(newest.media) else newest.media
            val ordered = MediaVariants.allThumbs(newest.media) +
                newest.media.mapNotNull { MediaVariants.parsePoster(it)?.second } + wanted
            for (ref in ordered.distinct()) {
                if (!LocalMedia.isSynthetic(ref) && !LocalMedia.has(ref) &&
                    !EvictedMediaStore.contains(ref) && !unopenableMedia.contains(ref)) {
                    enqueueRestore(circleId, ref)
                }
            }
        }
        // Kind-aware copy (parity with Apple PushBanner / desktop notify_circle). A reaction or
        // story must never say "Someone posted in your circle".
        val circleName = runCatching { social.circles() }.getOrDefault(emptyList())
            .firstOrNull { it.id == circleId }?.name ?: "your circle"
        val authorName = displayName(newest.authorShort).ifEmpty { "Someone" }
        val media = newest.media
        val copy = when {
            newest.story -> PushBanner.forPost(circleId, circleName, newest.body, media, story = true)
            // Pure reaction bumps often leave body empty with a reaction list on the item.
            newest.body.isBlank() && newest.reactions.isNotEmpty() && media.isEmpty() -> {
                val e = newest.reactions.firstOrNull()?.emoji.orEmpty()
                PushBanner.forReaction(e, circleId)
            }
            else -> PushBanner.forPost(circleId, circleName, newest.body, media, story = false)
        }
        val detail = runCatching { ProfileStore.get(appContext).notificationDetail }.getOrDefault("full")
        val (useName, body) = PushBanner.displayBody(copy.body, copy.privateBody, copy.kind, detail)
        Notifications.notify(
            appContext,
            title = if (useName) authorName else "Haven",
            body = body,
            // Tap-target: a DM opens its Messages THREAD; a circle post/story opens the exact post
            // (Apple DeepLink.interactionLink parity). Routed through MainActivity.handleShare, so
            // one route table — and the circle-lock rules — govern links from every source.
            deepLink = DeepLink.interactionLink(circleId, newest.id),
        )
    }

    /** Record a notification dedupe key; false if already notified. Persisted (capped — the
     *  10-minute recency guard above is what really stops ancient items from re-notifying). */
    private fun markNotified(key: String): Boolean {
        val cur = prefs.getStringSet("notifiedIds", emptySet())?.toMutableSet() ?: mutableSetOf()
        if (!cur.add(key)) return false
        if (cur.size > 800) { cur.clear(); cur.add(key) }
        prefs.edit().putStringSet("notifiedIds", cur).apply()
        return true
    }

    // ---- Outbound ------------------------------------------------------------------------

    /** Begin a connect from a scanned/pasted haven:// invite. */
    fun connectByLink(uri: String): Boolean {
        val trimmed = uri.trim()
        val info = runCatching { parseLink(trimmed) }.getOrNull() ?: return false
        // Scanning an invite is a DELIBERATE add: clear any old removal tombstone, or their hellos
        // stay dropped (handleHello guard) and self-sync re-severs them (re-add never sticks).
        CircleRemovals.remove(DEFAULT_CIRCLE, info.idHex)
        runCatching { social.clearCircleRemoval(DEFAULT_CIRCLE, info.idHex) }   // lift the engine tombstone too
        // Store the invite's device-id hints BEFORE the hello, so the very first dial can reach
        // their device (their account id resolves to no node post-device-seed).
        recordDeviceHints(info.idHex, InviteHints.extract(trimmed))
        initiated[info.idHex] = info.verificationHex
        initiatedAt[info.idHex] = System.currentTimeMillis()
        saveInitiated()   // survive the process death Android hands out freely
        sendHello(DEFAULT_CIRCLE, info.idHex)
        return true
    }

    // ---- Invite device-id hints (roster-bootstrap bridge) --------------------------------

    /** Device ids learned from a contact's INVITE LINK (`?d=` — see InviteHints). The only dialable
     *  ids for a device-seed friend until their signed roster (frame 27) arrives — which the hint
     *  itself makes possible. Keyed by lowercased account hex; persisted as JSON. */
    private val deviceHints = HashMap<String, List<String>>()
    private fun loadDeviceHints() {
        val raw = prefs.getString("deviceHints", null) ?: return
        runCatching {
            val o = org.json.JSONObject(raw)
            for (k in o.keys()) {
                val arr = o.getJSONArray(k)
                deviceHints[k] = (0 until arr.length()).map { arr.getString(it) }
            }
        }
    }
    private fun saveDeviceHints() {
        val o = org.json.JSONObject()
        for ((k, v) in deviceHints) o.put(k, JSONArray(v))
        prefs.edit().putString("deviceHints", o.toString()).apply()
    }
    fun recordDeviceHints(accountHex: String, ids: List<String>) {
        if (ids.isEmpty()) return
        val key = accountHex.lowercase()
        val cur = LinkedHashSet(deviceHints[key] ?: emptyList())
        val before = cur.size
        for (d in ids.map { it.lowercase() }) if (d.length == 64) cur.add(d)
        if (cur.size == before) return   // no-op for already-known hints (fires per hello)
        deviceHints[key] = cur.toList().takeLast(8)
        saveDeviceHints()
    }
    private fun deviceHintsFor(accountHex: String): List<String> =
        deviceHints[accountHex.lowercase()] ?: emptyList()

    // ---- Account device discovery (relay-optional reachability) --------------------------

    /** Publish my account -> device-id mapping to the public directory, so a contact who holds only
     *  my account id can dial one of my devices with NO relay in common. Fire-and-forget; the
     *  publisher re-publishes on its own TTL for as long as the node lives. iOS parity. */
    private fun publishAccountDevices() {
        val n = node ?: return
        scope.launch {
            runCatching { n.publishAccountDevices(social) }
                .onSuccess { if (it.isNotEmpty()) Log.i(TAG, "discovery published devices=${it.size}") }
                .onFailure { Log.w(TAG, "discovery publish failed: ${it.message}") }   // additive - never fatal
        }
    }

    /** Accounts we have asked the directory about recently, so a sync tick does not re-query a
     *  contact who simply has not published (every pre-discovery install - the common case). */
    private val discoveryAskedAt = HashMap<String, Long>()

    /** Look up device ids for contacts we have NO way to dial - no signed roster, no invite hint,
     *  just an account id that is not a transport address. Without this such a contact is only
     *  reachable through a relay both sides happen to share; with it, two online devices can find
     *  each other and let iroh hole-punch. Results land in the same hint store the invite `?d=` ids
     *  use - a dial hint, never an authorization. */
    private fun resolveMissingDeviceIds(accounts: List<String>) {
        val n = node ?: return
        val now = System.currentTimeMillis()   // NOT nowMs() — that returns ULong; this map is Long
        val ask = accounts.filter { a ->
            val key = a.lowercase()
            val at = discoveryAskedAt[key]
            if (at != null && now - at < DISCOVERY_RETRY_MS) false else { discoveryAskedAt[key] = now; true }
        }
        if (ask.isEmpty()) return
        scope.launch {
            var learned = false
            for (a in ask) {
                val ids = runCatching { n.resolveAccountDevices(a) }.getOrNull() ?: continue
                if (ids.isEmpty()) continue
                learned = true
                Log.i(TAG, "discovery resolved ${a.take(8)} devices=${ids.size}")
                recordDeviceHints(a, ids)
            }
            // A peer we could not reach a moment ago is reachable NOW. Don't make them wait for the
            // next sync tick and the announce cadence to find that out: sync tight and re-announce our
            // relays immediately, which is exactly what a peer with no relay in common is missing.
            if (learned) {
                bumpActivity()
                reannounceOwnRelay()
                syncWithContacts()
            }
        }
    }

    /** Approve a pending request: add them, persist, and Hello back so they auto-accept us. */
    fun approve(req: PendingRequest) {
        // Approving IS a deliberate re-add — clear any old removal tombstone or their hellos stay
        // dropped (handleHello guard) and self-sync re-severs them on every pass.
        CircleRemovals.remove(DEFAULT_CIRCLE, req.idHex)
        runCatching { social.clearCircleRemoval(DEFAULT_CIRCLE, req.idHex) }   // lift the engine tombstone too
        acceptContact(DEFAULT_CIRCLE, req.bundle, req.idHex, req.name, req.verifyHex, helloBack = true)
        // Apply the ORIGINAL circle grant the held hello carried — approval used to collapse every
        // request to the default circle, so an invite into a named circle never formed it on our
        // side. The retained mailbox slot re-applies the same grant on the next poll (hello claim
        // discipline); doing it here makes approval immediate and covers direct/iroh hellos that
        // have no mailbox slot to retry.
        if (req.circleId != DEFAULT_CIRCLE && !req.circleId.startsWith("dm:")) {
            CircleRemovals.remove(req.circleId, req.idHex)
            runCatching { social.clearCircleRemoval(req.circleId, req.idHex) }
            runCatching { social.createCircle(req.circleId, req.circleName.ifBlank { "Circle" }) }
            if (runCatching { social.addContactBundle(req.circleId, req.bundle) }.isSuccess) {
                sendHello(req.circleId, req.idHex)   // mutual: they learn we accepted the grant
            }
            feedVersion.value++; circlesVersion.value++; persist()
        }
        pending.removeAll { it.idHex == req.idHex }
    }

    fun dismiss(req: PendingRequest) { pending.removeAll { it.idHex == req.idHex } }

    /** Block a node: purge from every circle, drop from contacts, ignore future frames.
     *
     *  Entirely local — a block never leaves the device (audit F1). Deciding you don't want to see
     *  someone is nobody's business but yours; only an explicit report notifies the developer. */
    fun block(idHex: String) {
        runCatching { social.blockMember(idHex) }
        contacts.removeAll { it.idHex == idHex }
        ContactRemovals.markRemoved(idHex)   // LWW contact tombstone so the removal sticks fleet-wide
        pending.removeAll { it.idHex == idHex }
        if (blocked.none { it == idHex }) blocked.add(idHex)
        saveContacts(); saveBlocked(); persist()
    }

    /** Remove someone from the current circle WITHOUT blocking them (parity with iOS). */
    fun removeFromCircle(idHex: String) = removeFromCircle(activeCircle.value, idHex)

    /** Remove a member from a SPECIFIC circle (roster management). */
    fun removeFromCircle(circleId: String, idHex: String) {
        // Record the severance so it (a) propagates to our own devices as an explicit removal and
        // (b) survives the additive re-sync (applyLocal won't re-add anyone in CircleRemovals).
        CircleRemovals.add(circleId, idHex)
        runCatching { social.removeFromCircle(circleId, idHex) }
        feedVersion.value++; circlesVersion.value++; persist()
        // Re-lock the relay mailbox to the remaining members so the removed person can no longer
        // pull this circle's future media from the relay. (Already-delivered, locally-cached media
        // can't be clawed back — a fundamental P2P limit — but the epoch key rotates so they can't
        // read anything new.)
        authorizeMembership()
        selfSyncNudge()   // the severance record travels to my other devices now
    }

    /** True if [hex] was explicitly removed from [circleId] (severance) — don't dial / show them there. */
    fun isRemovedFromCircle(circleId: String, hex: String): Boolean = CircleRemovals.contains(circleId, hex)

    // ---- Multi-device roster (iOS-parity; the signed-credential crypto lives in the shared core) ----

    /** Turn THIS device into the primary (master-key holder) that authorizes/revokes the others. A
     *  seedless device holds no master seed and can never be the primary — no-op there. */
    fun enableDeviceRoster() {
        if (core.seedless) return
        DeviceRosterManager.enable(social, core.seed, core.bundle, nodeIdHex)
    }

    /** Ask the primary (over nearby + iroh) to authorize this device with its own revocable key. */
    fun requestDeviceEnrollment() {
        val out = ArrayList<Byte>()
        Wire.lpAppend(out, DeviceKeyStore.deviceBundle())
        Wire.lpAppend(out, DeviceKeyStore.deviceName.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, DeviceKeyStore.deviceNodeHex().toByteArray(Charsets.UTF_8))
        val payload = out.toByteArray()
        NearbyTransport.broadcast(Wire.frame(Wire.DEVICE_ENROLL, payload))
        runCatching { sendFrame(Wire.DEVICE_ENROLL, payload, nodeIdHex) }   // also the iroh path to my own devices
    }

    /** Revoke a linked device (primary only) — it can decrypt nothing posted afterward. Rotates the
     *  self-sync key too (inside DeviceRosterManager.revoke, §6) so the revoked device also loses its
     *  read/LWW-write access to our account-state channel; publish the rotated-key grants promptly. */
    fun revokeDevice(nodeHex: String) {
        if (core.seedless) return   // only the seed-holding primary revokes
        DeviceRosterManager.revoke(nodeHex, social, core.seed)
        scope.launch { runCatching { SelfSyncCoordinator.sync(social) } }   // publish the rotated-key grants
    }

    /** Step this device down from being the primary (e.g. the wrong device claimed the role). */
    fun stepDownAsPrimary() {
        DeviceRosterManager.stepDown()
    }

    /** I hold the master seed → authorize the requesting device: issue its credential, add it to my
     *  signed roster, send the grant back, and push my state so it backfills. */
    private fun handleEnrollmentRequest(payload: ByteArray) {
        if (core.seedless) return   // only a seed-holding primary answers enrollment (legacy 24/25 path)
        val r = Wire.Reader(payload)
        val bundle = r.lp() ?: return
        val name = r.lp()?.toString(Charsets.UTF_8) ?: "Device"
        val hex = r.lp()?.toString(Charsets.UTF_8) ?: return
        if (hex.isEmpty() || hex == DeviceKeyStore.deviceNodeHex()) return   // not my own device's request
        DeviceRosterManager.enable(social, core.seed, core.bundle, nodeIdHex)
        val cred = DeviceRosterManager.addLinkedDevice(bundle, hex, name, social, core.seed) ?: return
        val out = ArrayList<Byte>()
        Wire.lpAppend(out, hex.toByteArray(Charsets.UTF_8))
        Wire.lpAppend(out, cred)
        val grant = out.toByteArray()
        NearbyTransport.broadcast(Wire.frame(Wire.DEVICE_GRANT, grant))
        runCatching { sendFrame(Wire.DEVICE_GRANT, grant, nodeIdHex) }
        scope.launch { runCatching { SelfSyncCoordinator.sync(social) } }   // push my profile + posts
    }

    /** I'm the requesting device → store the credential the primary issued for my key. */
    private fun handleDeviceGrant(payload: ByteArray) {
        val r = Wire.Reader(payload)
        val hex = r.lp()?.toString(Charsets.UTF_8) ?: return
        val cred = r.lp() ?: return
        if (hex != DeviceKeyStore.deviceNodeHex()) return   // not for me
        DeviceCredentialStore.save(cred)
        scope.launch(Dispatchers.Main) { feedVersion.value++ }
    }

    // ---- Seedless enrollment (seed-drop S4, plan §3/§4) ----------------------------------------
    //   New devices get a device key + credential + granted self-sync key and NEVER the seed. The
    //   request is self-authenticating (MAC under the ticket secret) and the grant carries everything
    //   a seedless device needs. Frames 28/29 sit alongside the legacy seeded 24/25 path, which stays
    //   working for old links during the transition.

    /** Single-use enrollment tickets this primary is currently offering, keyed by secret hex. */
    private val pendingTickets = HashMap<String, uniffi.haven_ffi.EnrollTicketFfi>()
    /** The ticket secret hex the pending (confirm-gated) request matched. */
    private var pendingRequestSecret: String? = null
    /** The ticket the new device is currently linking against (null = not linking). */
    private var pendingLinkTicket: uniffi.haven_ffi.EnrollTicketFfi? = null
    private val TICKET_TTL_SECS: ULong = 600u   // 10-minute single-use window (plan §3.2)

    /** A frame-28 request the primary must confirm before granting (plan §4.2). */
    data class SeedlessEnrollPrompt(val deviceHex: String, val name: String, val deviceBundle: ByteArray)

    /** PRIMARY: the `haven-enroll:` QR text currently offered ("" = none). */
    val seedlessTicketUri = mutableStateOf("")
    /** PRIMARY: a pending enroll request awaiting the user's confirm (null = none). */
    val seedlessPendingRequest = mutableStateOf<SeedlessEnrollPrompt?>(null)
    /** NEW DEVICE: request sent, awaiting the grant. */
    val seedlessLinking = mutableStateOf(false)
    /** NEW DEVICE: last linking error to surface (null = none). */
    val seedlessLinkError = mutableStateOf<String?>(null)

    /**
     * PRIMARY: mint a fresh single-use enrollment ticket and return its `haven-enroll:` QR text. Only a
     * seed-holding device that is (or becomes) the primary can authorize — a seedless device returns
     * null. Registers this device as the primary (device #0 = the account key) if it isn't already.
     */
    fun enrollMintTicket(): String? {
        if (core.seedless) return null
        DeviceRosterManager.enable(social, core.seed, core.bundle, nodeIdHex)
        val primaryDevice = hexToBytes32(runCatching { social.myDeviceNodeHex() }.getOrDefault("")) ?: return null
        val relays = allRelays().filter { !it.startsWith("s3:") }.take(4)
        val now = System.currentTimeMillis() / 1000
        val ticket = runCatching {
            uniffi.haven_ffi.enrollIssueTicket(core.bundle, primaryDevice, now.toULong(), relays)
        }.getOrNull() ?: return null
        pendingTickets[bytesToHex(ticket.secret)] = ticket
        val uri = runCatching { uniffi.haven_ffi.enrollTicketEncode(ticket) }.getOrNull() ?: return null
        scope.launch(Dispatchers.Main) { seedlessTicketUri.value = uri }
        return uri
    }

    /** PRIMARY: cancel the pending ticket (closing the QR sheet without a link). */
    fun cancelSeedlessTicket() {
        pendingRequestSecret?.let { pendingTickets.remove(it) }
        pendingTickets.clear()
        pendingRequestSecret = null
        scope.launch(Dispatchers.Main) { seedlessTicketUri.value = ""; seedlessPendingRequest.value = null }
    }

    /** PRIMARY: a frame-28 request arrived — verify its MAC against each live ticket, and on a match
     *  surface a confirm sheet (only an explicit confirm issues the grant). */
    private fun handleSeedlessEnrollRequest(body: ByteArray) {
        if (core.seedless) return   // only a seed-holding primary authorizes
        val now = (System.currentTimeMillis() / 1000).toULong()
        for ((secretHex, ticket) in pendingTickets.toMap()) {
            if (runCatching { uniffi.haven_ffi.enrollTicketIsExpired(ticket, now, TICKET_TTL_SECS) }.getOrDefault(true)) {
                pendingTickets.remove(secretHex); continue
            }
            val req = runCatching {
                uniffi.haven_ffi.enrollVerifyRequest(ticket.secret, body, now, TICKET_TTL_SECS)
            }.getOrNull() ?: continue
            pendingRequestSecret = secretHex
            val deviceHex = nodeHex(req.deviceBundle)
            scope.launch(Dispatchers.Main) {
                seedlessPendingRequest.value = SeedlessEnrollPrompt(deviceHex, req.name, req.deviceBundle)
            }
            return
        }
    }

    /** PRIMARY: the user confirmed the prompt → issue the credential, union the device into the signed
     *  roster, seal the self-sync-key grant, send frame-29 (nearby + directed), consume the ticket, and
     *  push full state so the new device backfills. */
    fun confirmSeedlessEnroll() {
        if (core.seedless) return
        val prompt = seedlessPendingRequest.value ?: return
        val secretHex = pendingRequestSecret ?: return
        val ticket = pendingTickets[secretHex] ?: return
        scope.launch(Dispatchers.Main) { seedlessPendingRequest.value = null }
        scope.launch {
            // Union the device into MY signed roster (re-signs the DeviceList incl. this device, so the
            // grant's is_authorized(device) check passes) BEFORE reading the wire we ship in the grant.
            DeviceRosterManager.enable(social, core.seed, core.bundle, nodeIdHex)
            DeviceRosterManager.addLinkedDevice(prompt.deviceBundle, prompt.deviceHex, prompt.name, social, core.seed)
                ?: return@launch
            val rosterWire = runCatching { social.myDeviceRosterWire() }.getOrDefault(ByteArray(0))
            if (rosterWire.isEmpty()) return@launch
            val now = (System.currentTimeMillis() / 1000).toULong()
            val relays = allRelays().filter { !it.startsWith("s3:") }.take(4)
            val grant = runCatching {
                uniffi.haven_ffi.enrollAssembleGrant(core.seed, ticket.secret, prompt.deviceBundle,
                    prompt.name, now, rosterWire, relays)
            }.getOrNull() ?: return@launch
            NearbyTransport.broadcast(Wire.frame(Wire.SEEDLESS_ENROLL_GRANT, grant))
            runCatching { sendFrame(Wire.SEEDLESS_ENROLL_GRANT, grant, prompt.deviceHex) }
            pendingTickets.remove(secretHex)
            pendingRequestSecret = null
            scope.launch(Dispatchers.Main) { seedlessTicketUri.value = "" }
            runCatching { SelfSyncCoordinator.sync(social) }   // push my profile + posts to the new device
        }
    }

    /** PRIMARY: dismiss the confirm prompt without granting. */
    fun dismissSeedlessEnroll() {
        pendingRequestSecret = null
        scope.launch(Dispatchers.Main) { seedlessPendingRequest.value = null }
    }

    /**
     * NEW DEVICE: parse a scanned/pasted `haven-enroll:` ticket and send frame-28 to the primary over
     * both rails (nearby broadcast + directed iroh to the primary's device id), then enter linking mode.
     * Idempotent / re-scannable. Returns false if the text isn't a valid ticket.
     */
    fun beginSeedlessLink(text: String): Boolean {
        val ticket = runCatching { uniffi.haven_ffi.enrollTicketParse(text.trim()) }.getOrNull() ?: return false
        pendingLinkTicket = ticket
        scope.launch(Dispatchers.Main) { seedlessLinkError.value = null; seedlessLinking.value = true }
        val now = (System.currentTimeMillis() / 1000).toULong()
        val req = runCatching {
            uniffi.haven_ffi.enrollBuildRequest(ticket.secret, DeviceKeyStore.deviceBundle(),
                DeviceKeyStore.deviceName, now)
        }.getOrNull() ?: run {
            scope.launch(Dispatchers.Main) { seedlessLinking.value = false; seedlessLinkError.value = "Couldn't build the link request." }
            return false
        }
        NearbyTransport.broadcast(Wire.frame(Wire.SEEDLESS_ENROLL_REQ, req))
        val primaryHex = bytesToHex(ticket.primaryDevice)
        scope.launch { runCatching { sendFrame(Wire.SEEDLESS_ENROLL_REQ, req, primaryHex) } }
        return true
    }

    /** NEW DEVICE: cancel an in-progress seedless link (back out of the waiting screen). */
    fun cancelSeedlessLink() {
        pendingLinkTicket = null
        scope.launch(Dispatchers.Main) { seedlessLinking.value = false }
    }

    /**
     * NEW DEVICE: accept a frame-29 grant. `enrollOpenGrant` runs ALL FOUR acceptance checks (MAC +
     * account bundle vs ticket, credential names this device, roster authorizes it, self-sync grant
     * opens with our device key); any failure leaves us in linking mode (idempotent, re-scannable) —
     * never a half-identity. On success we persist the grant, discard the throwaway account seed, reset
     * the self-sync base (absence-as-deletion guard — the primary's pushed slot seeds it BEFORE any
     * local diff), and restart into seedless mode.
     */
    private fun handleSeedlessEnrollGrant(body: ByteArray) {
        val ticket = pendingLinkTicket ?: return   // not currently linking (a grant meant for a sibling)
        val grant = runCatching {
            uniffi.haven_ffi.enrollOpenGrant(DeviceKeyStore.deviceAccount().secretSeed(), ticket, body)
        }.getOrNull() ?: return
        val accountNodeHex = bytesToHex(ticket.accountId)
        val accountVerifyHex = bytesToHex(ticket.verification)
        // installSeedless writes the grant + resets the self-sync base (SelfSyncCoordinator
        // beginSeedlessEnrollment) so the first sync ADDS the primary's slot rather than tombstoning.
        HavenCore.installSeedless(appContext, grant, accountNodeHex, accountVerifyHex)
        ProfileStore.get(appContext).markOnboarded()
        pendingLinkTicket = null
        scope.launch(Dispatchers.Main) {
            seedlessLinking.value = false
            restartApp(appContext)   // re-enter init() in seedless mode
        }
    }

    /** True on a seedless device (no account master seed) — surfaces to the UI + self-sync. */
    val isSeedless: Boolean get() = core.seedless
    /** The granted 32-byte self-sync key (seedless only; null on a seeded/legacy device). */
    val selfSyncKey: ByteArray? get() = if (core.seedless) SeedlessStore.selfSyncKey() else null

    /** The members of a circle, with resolved display names — for the roster/management UI. */
    fun membersOf(circleId: String): List<Contact> =
        runCatching { social.contactNodeIds(circleId) }.getOrDefault(emptyList())
            .map { hex -> contacts.firstOrNull { it.idHex == hex } ?: Contact(hex, displayName(hex), "") }

    /** Node ids to DIAL to reach a circle's members: each member's ACCOUNT id (the user-facing contact
     *  handle; still reaches a peer on the pre-device-seed build where account id == node id) PLUS their
     *  DEVICE node ids from the signed roster — the actual reachable transport id, since under device-seed a
     *  friend's account id no longer resolves to any node. Deduped, self-excluded. Parity with iOS dialTargets. */
    private fun dialTargets(circleId: String): List<String> {
        val mineAcct = runCatching { social.myNodeHex() }.getOrNull()?.lowercase()
        val mineDev = runCatching { social.myDeviceNodeHex() }.getOrNull()?.lowercase()
        val out = LinkedHashSet<String>()
        fun add(h: String) { val l = h.lowercase(); if (l != mineAcct && l != mineDev) out.add(h) }
        val undialable = ArrayList<String>()
        for (a in runCatching { social.contactNodeIds(circleId) }.getOrDefault(emptyList())) {
            add(a)
            val devices = runCatching { social.deviceNodeIdsFor(a) }.getOrDefault(emptyList())
            for (d in devices) add(d)
            val hints = deviceHintsFor(a)
            for (h in hints) add(h)   // invite-link hints (until their roster lands)
            // Nothing but the account id, which is an identity and not an address: this member is
            // unreachable except through a shared relay. Ask the public directory for their devices.
            if (hints.isEmpty() && devices.all { it.lowercase() == a.lowercase() }) undialable.add(a)
        }
        if (undialable.isNotEmpty()) resolveMissingDeviceIds(undialable)
        return out.toList()
    }

    /** My OWN other devices' transport ids — the live-delivery fan-out set (D16 Phase 4b).
     *  Excludes this device (dialing our own id loops iroh's path discovery unboundedly — the
     *  self-connect leak) and the account id (a contact handle that resolves to NO endpoint under
     *  per-device transport seeds, so dialing it is a guaranteed timeout, not a sibling).
     *  Parity with iOS myOtherDeviceTargets. */
    /** My OWN other devices' node ids — who to tell when a ringing call has been handled here.
     *  Empty until their roster is known, which is the honest answer: with no roster there is no way
     *  to address them. iOS FeedStore.myOtherDeviceHexes parity. */
    fun myOtherDeviceHexes(): List<String> = myOtherDeviceTargets()

    private fun myOtherDeviceTargets(): List<String> {
        val mineAcct = runCatching { social.myNodeHex() }.getOrNull()?.lowercase() ?: return emptyList()
        val mineDev = runCatching { social.myDeviceNodeHex() }.getOrNull()?.lowercase()
        val out = LinkedHashSet<String>()
        for (d in runCatching { social.deviceNodeIdsFor(mineAcct) }.getOrDefault(emptyList())) {
            val l = d.lowercase()
            if (l.length == 64 && l != mineAcct && l != mineDev) out.add(l)
        }
        // Invite/device hints for MY account until self-sync merges the signed own-roster.
        for (h in deviceHintsFor(mineAcct)) {
            val l = h.lowercase()
            if (l.length == 64 && l != mineAcct && l != mineDev) out.add(l)
        }
        return out.toList()
    }

    /** Push a frame straight to my own other devices while they're online (see `haven_net::livedelivery`).
     *  Best-effort by contract: a sibling that's asleep is the EXPECTED case, not an error — the caller's
     *  durable mailbox path always runs regardless of what happens here. */
    private fun liveDeliverToMyDevices(type: Int, payload: ByteArray) {
        for (t in myOtherDeviceTargets()) sendFrame(type, payload, t)
    }

    /** Batched [liveDeliverToMyDevices] — ONE coroutine for MANY frames rather than one per frame.
     *  The catch-up sweep hands over dozens of envelopes at once, and [sendFrame] launches a
     *  coroutine per call: spawning one each would be a needless pile of concurrent dials at the
     *  same few devices, which is precisely the shape that drives iroh path-discovery churn. Sends
     *  sequentially inside a single coroutine instead. Best-effort by contract — a sleeping sibling
     *  is the EXPECTED case, and the durable mailbox path is unaffected. */
    private fun liveDeliverManyToMyDevices(type: Int, payloads: List<ByteArray>) {
        val targets = myOtherDeviceTargets()
        if (targets.isEmpty() || payloads.isEmpty()) return
        val n = node ?: return
        val frames = payloads.map { Wire.frame(type, it) }
        scope.launch {
            for (t in targets) for (f in frames) runCatching { n.sendToNode(t, f) }
        }
    }

    fun unblock(idHex: String) {
        blocked.removeAll { it == idHex }
        saveBlocked()
    }

    private fun acceptContact(
        circleId: String, bundle: ByteArray, idHex: String, name: String, verifyHex: String, helloBack: Boolean,
    ) {
        runCatching { social.addContactBundle(circleId, bundle) }
        ContactRemovals.markReadded(idHex)   // a deliberate (re-)add lifts any contact tombstone (LWW)
        // App-layer activity row: a new connection has no engine event to reduce.
        if (contacts.none { it.idHex == idHex }) ActivityStore.noteConnection(idHex, name)
        scope.launch(Dispatchers.Main) {
            // Upsert: refresh the name/verify on re-add (a removed-then-readded contact must stop
            // resolving to "Someone" — iOS does the same via syncUpsert).
            val i = contacts.indexOfFirst { it.idHex == idHex }
            if (i >= 0) contacts[i] = Contact(idHex, name, verifyHex) else contacts.add(Contact(idHex, name, verifyHex))
            saveContacts()
        }
        persist()
        if (helloBack) {
            sendHello(circleId, idHex)
            // I'm the accepter sharing history → make sure the relay holds it ASAP so the new member
            // can pull from the relay if the direct back-fill doesn't reach them.
            scope.launch { backfillHistoryToRelay(circleId) }
        }
    }

    /** Send our Hello + (optionally) back-fill this circle's events to one node. */
    /** [resendHistory] gates the full per-contact history re-blast. When false we send only the cheap
     *  Hello + relay announce (keeps connections warm) — the history is throttled (see [syncWithContacts]). */
    private fun sendHello(circleId: String, toNodeHex: String, resendHistory: Boolean = true) {
        val hello = helloPayload(circleId) ?: return
        sendFrame(Wire.HELLO, hello, toNodeHex)
        // Store-and-forward the same hello through the circle mailbox (iOS putHello parity): the
        // direct frame reaches nobody when iroh can't dial the peer — cross-NAT is exactly where a
        // circle invite used to die. Addressed to the member's ACCOUNT hex, the one slot every one
        // of their devices claims at the mailbox; a transport/device id goes stale with a re-minted
        // bundle and parks the invite on a slot nobody polls.
        val acct = runCatching { social.accountForDevice(toNodeHex) }.getOrNull() ?: toNodeHex
        scope.launch { runCatching { putHelloMailbox(circleId, acct, hello) } }
        if (resendHistory) {
            val envs = runCatching { social.syncEnvelopes(circleId) }.getOrDefault(emptyList())
            for (env in envs) sendFrame(Wire.EVENT, Wire.eventPayload(circleId, env), toNodeHex)
        }
        // Tell this peer about the circle relays WE have proof of life for (a successful op within
        // 5 min) — plus the relay this device hosts (announced by reannounceOwnRelay). Announcing
        // every relay ever LEARNED made dead relay ids echo around the mesh forever: each member
        // re-broadcast them and receivers reactivated them. A live relay is re-proven constantly
        // by the mailbox poll, so this gates nothing real.
        val nowMs = System.currentTimeMillis()
        for (nodeHex in relaysFor(circleId)) {
            if (relayHealth[nodeHex]?.provenAlive(nowMs, 300_000) != true) continue
            val sealed = relayAnnounceBlob(circleId, nodeHex)
            if (sealed != null) sendFrame(Wire.RELAY_NODE, Wire.eventPayload(circleId, sealed), toNodeHex)
        }
    }

    /** Periodic/triggered sync: greet every contact so circles form + back-fill.
     *
     *  Re-blasting our ENTIRE history (every post → every contact) on every tick flooded the network
     *  with hundreds of thousands of frames, drowning real delivery (the iOS "nothing communicates"
     *  bug). The Hello goes out every tick (cheap, keeps connections warm + bootstraps); the full
     *  per-contact history re-send is throttled to ~once per 3 min — offline members get history from
     *  the mailbox/relay, and a freshly-added contact is back-filled directly by acceptContact. */
    private var lastHistoryResendMs: Long = 0
    private var lastMediaBackfillMs: Long = 0
    /** Last frame-19 re-announce. Must not ride every sync tick (radio + seal cost → heat). */
    private var lastRelayReannounceMs: Long = 0
    /** Last own-device catch-up sweep. Throttled hard (5 min): it re-seals every envelope it sends,
     *  so it must NOT ride the sync tick. See the sweep in [syncWithContacts] for why it exists. */
    private var lastOwnDeviceCatchupMs: Long = 0
    private var ownDeviceCatchupInFlight = false
    fun syncWithContacts() {
        if (!ready) return
        val nowMs = System.currentTimeMillis()
        val resendHistory = nowMs - lastHistoryResendMs > 180_000   // ~3 min, not every tick
        val snapshot = dialTargets(DEFAULT_CIRCLE)   // account id (handle) + device ids (actual reach)
        // Proactively announce MY device roster (type 27) so a friend can AUTHORIZE + dial my specific device
        // under the per-device transport — without it a freshly-flipped device stays "forbidden" at friends'
        // relays (the roster rode only rare circle key-commits before). Small, signed, idempotent. iOS parity.
        val rosterWire = runCatching { social.myDeviceRosterWire() }.getOrDefault(ByteArray(0))
        for (idHex in snapshot) {
            sendHello(DEFAULT_CIRCLE, idHex, resendHistory = resendHistory)
            if (rosterWire.isNotEmpty()) sendFrame(Wire.DEVICE_ROSTER, rosterWire, idHex)
        }
        // Re-greet anyone we've asked to connect who hasn't answered yet. They are NOT contacts —
        // Android waits for the hello-back before creating one — so `snapshot` above skips them
        // entirely, which left the initial hello as a single unrepeated shot. Their approval is a
        // human tapping a button minutes later, and on cellular they're behind CGNAT with no
        // inbound reachability and no relay mailbox yet, so that one hole we punched has closed by
        // the time they answer. Re-punching each cycle is what gives their reply a path home.
        if (initiated.isNotEmpty()) {
            val expired = ArrayList<String>()
            for ((hex, _) in initiated) {
                if (nowMs - (initiatedAt[hex] ?: nowMs) > initiatedTtlMs) { expired.add(hex); continue }
                if (contacts.any { it.idHex.equals(hex, ignoreCase = true) }) { expired.add(hex); continue }
                sendHello(DEFAULT_CIRCLE, hex)
                if (rosterWire.isNotEmpty()) sendFrame(Wire.DEVICE_ROSTER, rosterWire, hex)
            }
            for (hex in expired) forgetInitiated(hex)
        }
        // Bootstrap device-id exchange over the RELAY: a friend who flipped to the per-device transport no
        // longer resolves by account id, but their relay node (== their device messaging endpoint, one-endpoint
        // design) does. Push my roster there so they learn + authorize my device id — that's what then lets me
        // read their mailbox (fetch their media). Parity with iOS. Skip s3 pseudo-relays + my own node.
        if (rosterWire.isNotEmpty()) {
            val myNode = runCatching { node?.nodeIdHex() }.getOrNull()
            val relayTargets = LinkedHashSet<String>()
            for (c in runCatching { social.circles() }.getOrDefault(emptyList()))
                for (r in relaysFor(c.id)) if (!r.startsWith("s3:") && r != myNode) relayTargets.add(r)
            for (r in relayTargets) sendFrame(Wire.DEVICE_ROSTER, rosterWire, r)
        }
        // Teach each relay this circle's MEMBERS, not just OUR devices. The roster above says "these
        // are my device ids"; it cannot say "this new person belongs here", so a contact invited
        // after the operator pasted the relay link was refused by that relay permanently — every
        // media fetch, mailbox put and devroster read forbidden, which looks like broken sync rather
        // than a membership gap. `RelayAuth::learn` has always accepted this from a member the relay
        // already serves; the verb simply had no caller on any platform. iOS FeedStore.enrollMembers
        // parity. Refused harmlessly when we are the unauthorized one.
        enrollCircleMembers()
        // PULL the rosters we're MISSING. Announcing ours (frame 27, above) only works when the contact
        // is DIRECTLY reachable; between two CGNAT networks it never lands in either direction, so
        // neither side can resolve the other's devices — and a device-signed call frame, the ACCEPT
        // included, then fails the declared-vs-signer check and is dropped as a forgery. Their roster is
        // already sitting on the relay, so ask for it. Cheap and idempotent: only contacts we currently
        // can't resolve, and the ingest is a no-op once we hold it.
        //
        // STRICTLY BOUNDED, and it must stay that way. A contact whose roster is on NO relay never
        // becomes resolvable, so an unguarded version re-asks them forever: one pass per sync tick,
        // every relay, per contact, with long network timeouts — so passes overlap and pile up
        // without limit. That is a dial storm, and iroh answers a dial storm with unbounded
        // path-discovery churn (the self-connect leak / open_path_on_conn OOM already on record).
        // It took a Mac to 28 GB before it was caught. One pass at a time, a few per pass, long
        // per-contact backoff.
        if (!rosterPullInFlight) {
            // UNRESOLVABLE contacts first — we know nothing but their account id, so nothing works
            // for them at all. But do NOT stop there, which is what this used to do:
            //
            //     .filter { deviceNodeIdsFor(hex).all { it == hex } }   // "know nothing about them"
            //
            // Holding SOME device for a contact was treated as knowing their CURRENT devices, so a
            // roster could never be refreshed — only discovered. A contact who starts a new identity,
            // adds a device, or re-installs then has a device id we will never learn, and anything
            // sealed under it is unopenable forever: `open_circle_media` resolves a device sender
            // through the verified roster and returns None when it can't. Media from that contact
            // fails 100% while their TEXT still arrives (events don't need the device roster) —
            // which reads as "decryption is broken" rather than "our roster is stale".
            //
            // The dial-storm guards that matter are unchanged and must stay: one pass in flight,
            // ROSTER_PULL_PER_PASS per pass, and a 10-minute per-contact backoff. Stale contacts ride
            // the same budget, behind the unresolvable ones.
            val resolvable = { hex: String ->
                runCatching { social.deviceNodeIdsFor(hex) }.getOrDefault(emptyList())
                    .any { !it.equals(hex, ignoreCase = true) }
            }
            val candidates = contacts.map { it.idHex }.filter { rosterPullDue(it) }
            val due = (candidates.filterNot(resolvable) + candidates.filter(resolvable))
                .take(ROSTER_PULL_PER_PASS)
            if (due.isNotEmpty()) {
                rosterPullInFlight = true
                Log.i(TAG, "devroster: pulling ${due.size} contact roster(s) from relays: ${due.map { it.take(8) }}")
                scope.launch {
                    try {
                        for (hex in due) {
                            noteRosterPullAttempt(hex)
                            runCatching { fetchContactRoster(hex) }
                        }
                    } finally {
                        rosterPullInFlight = false
                    }
                }
            }
        }
        if (resendHistory) lastHistoryResendMs = nowMs
        // Own-device catch-up over the INTERNET. The receive-time fan-out (handleEvent) only helps
        // events arriving from NOW ON — a DM already sitting on one device and missing from another
        // stays missing, because handleEvent never runs for it again. A catch-up covering all authors
        // existed only over the NEARBY transport, gated on a sibling being physically connected, so
        // two devices on different networks never reconciled at all.
        //
        // BOUNDED, deliberately, and it must stay that way:
        //  - only when I actually HAVE other devices (no targets → no work at all),
        //  - at most OWN_DEVICE_CATCHUP_LIMIT events per circle,
        //  - no more often than every 5 minutes — this re-seals per envelope, so it is real CPU and
        //    battery and must not ride the sync tick,
        //  - a single in-flight guard, so slow passes cannot overlap and pile up (the roster-pull
        //    dial-storm shape documented above),
        //  - batched into ONE coroutine per sweep via liveDeliverManyToMyDevices, not one dial per
        //    envelope.
        // Siblings dedupe on receive, so repeating a sweep is harmless.
        if (!ownDeviceCatchupInFlight &&
            nowMs - lastOwnDeviceCatchupMs > 300_000 &&
            myOtherDeviceTargets().isNotEmpty()
        ) {
            lastOwnDeviceCatchupMs = nowMs
            ownDeviceCatchupInFlight = true
            val cids = runCatching { social.circles().map { it.id } }.getOrDefault(emptyList())
            scope.launch {
                try {
                    for (cid in cids) {
                        // ALL authors — the point is my friends' messages that reached one device only.
                        val envs = runCatching {
                            social.exportRecentEnvelopes(cid, OWN_DEVICE_CATCHUP_LIMIT)
                        }.getOrDefault(emptyList())
                        if (envs.isNotEmpty()) {
                            liveDeliverManyToMyDevices(Wire.EVENT, envs.map { Wire.eventPayload(cid, it) })
                        }
                    }
                } finally {
                    ownDeviceCatchupInFlight = false
                }
            }
        }
        // Throttle frame-19 re-announce to ~3 min (parity with iOS heat fix). Fresh peers still get
        // it on nearby connect / adopt; this is only the periodic safety net.
        if (nowMs - lastRelayReannounceMs > 180_000) {
            lastRelayReannounceMs = nowMs
            reannounceOwnRelay()
        }
        // Push MY media up to every circle relay periodically (idempotent — skips blobs already present),
        // so a sibling reading the relay finds it. The nearby chunk path is unreliable; the relay is durable.
        if (nowMs - lastMediaBackfillMs > 120_000) {
            lastMediaBackfillMs = nowMs
            // Event envelopes at most DAILY (persisted across launches): re-uploads are idempotent
            // now (deterministic envelopes + the persisted seen-set), but the re-seal is still a
            // hybrid signature per event — not something to burn every 2 minutes. Before this
            // gate, every 2-minute tick re-sealed the whole history into fresh envelope bytes →
            // a new mailbox entry per event per tick, the bloat behind the slow cold start.
            // Media stays on the 2-minute cadence (its backup queue skips blobs already present).
            val eventsToo = nowMs - prefs.getLong("lastEventBackfillMs", 0L) > 86_400_000L
            if (eventsToo) prefs.edit().putLong("lastEventBackfillMs", nowMs).apply()
            scope.launch { runCatching { for (c in social.circles()) backfillMailbox(c.id, eventsToo = eventsToo) } }
            // Re-publish our account-signed device roster to every known relay, so a HEADLESS relay (which
            // only knows account ids from its operator link) authorizes THIS device's id and stops
            // ERR-forbidding our mailbox ops — the "my own NAS relay rejects my phone" fix. iOS
            // SharedStore.publishDeviceRoster parity.
            scope.launch { runCatching { publishDeviceRoster() } }
        }
    }

    /**
     * Publish this device's account-signed device roster to every known relay under
     * `haven/devroster/<accountHex>`. A device connects to a relay AS its DEVICE id, but a HEADLESS relay
     * only knows ACCOUNT ids (from the operator's link), so without this it ERR-forbids every one of the
     * account's devices' mailbox ops. The wire (from [HavenSocial.exportOwnRoster]) carries the account
     * bundle + an account-SIGNED DeviceList, so the relay verifies it WITHOUT decrypting anything and then
     * authorizes the account's device ids (haven-net verify_devroster). The key is permission-free, so
     * this write is allowed BEFORE authorization (the bootstrap). Idempotent + cheap; called on the sync
     * timer so a restarted relay re-learns our devices promptly. iOS SharedStore.publishDeviceRoster parity.
     */
    // Relays that already hold this exact roster, and when we confirmed it. A roster is ~30 KB (each
    // device credential carries a hybrid PQ signature), and this ran on the sync tick against EVERY
    // relay — tens of KB every couple of minutes, per relay, forever, whether or not anything had
    // changed. That is what produced "relay put timed out" / ConnectionLost in the field logs and
    // starved the rest of sync. Content is what matters, so key on the wire's hash: an unchanged
    // roster is re-sent only after ROSTER_REPUBLISH_MS as liveness, and any CHANGE republishes
    // immediately. iOS SharedStore.rosterPublished parity.
    private val rosterPublished = HashMap<String, Pair<Int, Long>>()   // node → (wire hash, confirmed at)
    private val rosterRepublishMs = 1_800_000L   // 30 min

    private suspend fun publishDeviceRoster(force: Boolean = false) {
        val r = runCatching { social.exportOwnRoster() }.getOrDefault(emptyList()).firstOrNull() ?: return
        val wire = r.wire
        if (wire.isEmpty()) return
        val key = "haven/devroster/${r.accountHex}"
        val wireHash = wire.contentHashCode()
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        var skipped = 0
        for (nodeHex in allRelays()) {
            if (nodeHex.startsWith("s3:")) continue
            // Our OWN hosted relay: write straight into the local store (no iroh self-dial).
            if (hostedHex != null && nodeHex == hostedHex) { runCatching { relayHost?.localPut(key, wire) }; continue }
            // Already holds these exact bytes and confirmed recently → nothing to say.
            val seen = rosterPublished[nodeHex]
            if (!force && seen != null && seen.first == wireHash &&
                System.currentTimeMillis() - seen.second < rosterRepublishMs) { skipped++; continue }
            // Relay HTTP interface first (the reliable cross-NAT path), else the iroh dial.
            val entry = relayEntries[nodeHex]
            if (entry != null && entry.httpToken.isNotEmpty()) {
                var done = false
                var refused = false
                for (base in httpUrlsFor(entry)) {
                    val r = relayHttpPut(base, entry.httpToken, key, wire)
                    if (r.isSuccess) {
                        markRelaySeen(nodeHex); rosterPublished[nodeHex] = wireHash to System.currentTimeMillis()
                        // A 200 does NOT prove the relay STORED this roster. `verify_devroster_put`
                        // answers an out-of-date version with AuthOnly: it takes our signed device
                        // ids into the auth union, keeps the NEWER blob on disk, and still replies
                        // 200 OK ("the PUT was legitimate; the relay just had a newer blob").
                        //
                        // So the R6 rollback remedy below never fired — it keys off a REFUSAL, and
                        // there isn't one. We recorded success, never adopted the newer roster, and
                        // re-published the same stale bytes on the next pass, forever. That is the
                        // relay's endless "devroster PUT lost version race" line, and the device
                        // stayed unauthorized the whole time.
                        //
                        // Only pay for this when there IS a problem: if the relay is still refusing
                        // us elsewhere, a 200 here is suspect, so pull back what it actually holds.
                        if (refusedStreak.containsKey(nodeHex)) {
                            adoptNewerOwnRosterAndRetry(nodeHex, key, wire, RelayForbidden())
                        }
                        done = true; break
                    }
                    // The devroster key is permission-FREE, so a refusal here is the relay rejecting our
                    // SIGNATURE, not our membership — noteRefused would only schedule a heal that repeats
                    // this very publish. Still never back the URL off: this is the one write that
                    // authorizes all the others, and sealing it for two minutes is how a device stays
                    // unauthorized (and unable to upload) far longer than it needs to.
                    if (r.exceptionOrNull() is RelayForbidden) refused = true else markHttpUrlBad(base)
                }
                if (done) continue
                if (refused) {
                    // The relay REJECTED our signed roster on the reliable rung. On HTTP-only
                    // reachability (emulator NAT, CGNAT both ends) the iroh fallback below dies in
                    // discovery ("dial in cooldown") and never surfaces the refusal — so the R6
                    // rollback remedy must hook HERE too, or a device that fell behind the fleet
                    // roster can never re-authorize (its selfsync + uploads stay 403 forever).
                    adoptNewerOwnRosterAndRetry(nodeHex, key, wire, RelayForbidden())
                    continue
                }
            }
            val client = relayClientFor(nodeHex) ?: continue
            runCatching { client.put(key, wire) }
                .onSuccess {
                    markRelayOk(nodeHex); rosterPublished[nodeHex] = wireHash to System.currentTimeMillis()
                    Log.i(TAG, "devroster put OK relay=${nodeHex.take(8)} — relay should now authorize our device")
                }
                .onFailure {
                    relayFailed(nodeHex)
                    Log.i(TAG, "devroster put FAIL relay=${nodeHex.take(8)}: ${it.message}")
                    adoptNewerOwnRosterAndRetry(nodeHex, key, wire, it)
                }
        }
        if (skipped > 0) Log.i(TAG, "devroster: $skipped relay(s) already hold this exact roster — not re-sending ${wire.size} B each")
    }

    /**
     * Recover from a REFUSED publish of our own roster.
     *
     * `verify_devroster_put` applies a rollback defense: a validly-signed roster whose version is
     * strictly OLDER than the one already stored is refused (audit R6). That is correct against
     * replay, but it deadlocks a device that has simply fallen behind — say another of our devices
     * published a newer version. The publish is the BOOTSTRAP that authorizes this device, so being
     * refused means the device can never become authorized, and every later op (media PUT, media GET,
     * frame-9 call forwarding) is forbidden too — which is why the callee's ACCEPT never arrives and
     * the call never connects. [healForbiddenRelays] cannot help: it answers a refusal by
     * re-publishing, and the publish is what is refused.
     *
     * So adopt what we're being out-versioned by, then publish again at that version. Pulling our own
     * roster back is safe for the same reason the relay's own check is: [fetchContactRoster] ingests
     * through `ingestRosterWire`, which verifies the ACCOUNT signature, and only our account key could
     * have produced it — a relay can serve it, never forge it. iOS
     * SharedStore.adoptNewerOwnRosterAndRetry parity.
     */
    /** Last member-enroll per circle — the member set changes rarely, so once per 10 min is plenty. */
    private val lastEnrollMs = java.util.concurrent.ConcurrentHashMap<String, Long>()

    /**
     * Tell every relay serving a circle who its members are, so a peer the operator never listed in
     * the relay link is still served. Best-effort: a relay that refuses (because WE are the one it
     * doesn't serve) or that predates the verb just keeps its existing set.
     */
    private fun enrollCircleMembers() {
        val nowMs = System.currentTimeMillis()
        val myAcct = runCatching { social.myNodeHex() }.getOrNull()?.lowercase() ?: return
        val myNode = runCatching { node?.nodeIdHex() }.getOrNull()?.lowercase()
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            val relays = relaysFor(c.id).filter { !it.startsWith("s3:") && it.length == 64 }
            if (relays.isEmpty()) continue
            if (nowMs - (lastEnrollMs[c.id] ?: 0L) < 600_000) continue
            // Rule (2) of `learn`: name OURSELVES or the relay declines the whole request.
            val members = LinkedHashSet<String>()
            members.add(myAcct)
            myNode?.let { members.add(it) }
            for (t in dialTargets(c.id)) members.add(t.lowercase())
            if (members.size <= 1) continue
            lastEnrollMs[c.id] = nowMs
            val list = members.toList()
            scope.launch {
                for (hex in relays) {
                    val client = relayClientFor(hex) ?: continue
                    val ok = runCatching { client.enrollMembers(c.id, list) }.getOrDefault(false)
                    if (ok) Log.i(TAG, "enrolled ${list.size} members of ${c.id} at ${hex.take(8)}")
                }
            }
        }
    }

    private suspend fun adoptNewerOwnRosterAndRetry(nodeHex: String, key: String, sent: ByteArray, error: Throwable) {
        // RelayForbidden is the HTTP rung's refusal (its message says "refused", not "forbidden").
        if (error !is RelayForbidden && error.message?.lowercase()?.contains("forbidden") != true) return
        val acct = runCatching { social.exportOwnRoster() }.getOrDefault(emptyList()).firstOrNull()?.accountHex ?: return
        Log.i(TAG, "devroster refused by ${nodeHex.take(8)} — pulling the newer roster it holds and re-publishing")
        if (!fetchContactRoster(acct)) {
            Log.i(TAG, "devroster: could not read our own stored roster back from any relay — still unauthorized on ${nodeHex.take(8)}")
            return
        }
        val fresh = runCatching { social.exportOwnRoster() }.getOrDefault(emptyList()).firstOrNull() ?: return
        if (fresh.wire.contentEquals(sent)) {
            Log.i(TAG, "devroster: adopted roster is identical to the one refused — refusal is NOT a version rollback on ${nodeHex.take(8)}")
            return
        }
        // Re-publish at the adopted version — HTTP rung first (the reliable cross-NAT path, and the
        // only one on an HTTP-only reachability), then the iroh dial (original behavior).
        val entry = relayEntries[nodeHex]
        if (entry != null && entry.httpToken.isNotEmpty()) {
            for (base in httpUrlsFor(entry)) {
                val r = relayHttpPut(base, entry.httpToken, key, fresh.wire)
                if (r.isSuccess) {
                    markRelaySeen(nodeHex); rosterPublished[nodeHex] = fresh.wire.contentHashCode() to System.currentTimeMillis()
                    Log.i(TAG, "devroster http-put OK relay=${nodeHex.take(8)} after adopting its newer roster — this device is authorized again")
                    return
                }
                if (r.exceptionOrNull() !is RelayForbidden) markHttpUrlBad(base)
            }
        }
        val client = relayClientFor(nodeHex) ?: return
        runCatching { client.put(key, fresh.wire) }
            .onSuccess {
                markRelayOk(nodeHex); rosterPublished[nodeHex] = fresh.wire.contentHashCode() to System.currentTimeMillis()
                Log.i(TAG, "devroster put OK relay=${nodeHex.take(8)} after adopting its newer roster — this device is authorized again")
            }
            .onFailure { Log.i(TAG, "devroster STILL refused by ${nodeHex.take(8)} after adopting: ${it.message}") }
    }

    /**
     * PULL a CONTACT's device roster from the relays and ingest it — the missing half of
     * [publishDeviceRoster], which only ever PUSHED our own.
     *
     * The only other way to learn a contact's roster is frame 27, sent over a DIRECT iroh send on the
     * periodic sweep. That never arrives when neither peer is directly reachable — two CGNAT networks,
     * Starlink being the everyday case. Without their roster `accountForDevice` cannot map their
     * signing device to their account, so every device-signed call frame they send us fails the
     * declared-vs-signer check in [CallManager.openCallFrame] and is discarded as a forgery. That is
     * precisely "the callee answers, the caller sits on Calling forever": their ACCEPT arrives and we
     * throw it away. The relay has been holding their roster the whole time — nobody ever asked for it.
     *
     * Safe against a hostile relay: `ingestRosterWire` verifies the ACCOUNT signature over the
     * DeviceList itself and refuses anything that doesn't bind to the account named in the key, so a
     * relay can serve these bytes but cannot forge or alter them. iOS SharedStore.fetchContactRoster
     * parity.
     */
    /** True while a roster-pull pass is running — see the bounding note at the call site. */
    @Volatile private var rosterPullInFlight = false
    /** When each contact's roster was last ASKED for, so an unresolvable contact costs ~nothing. */
    private val rosterPullAt = mutableMapOf<String, Long>()

    /**
     * A roster just landed, so senders we could not resolve a moment ago may be resolvable now.
     *
     * Blobs that failed to open were parked in [unopenableMedia] and deliberately not re-fetched
     * this session — correct when the BYTES are bad, wrong when the bytes were fine and we simply
     * could not resolve who sealed them. Learning a device roster is exactly the event that changes
     * that answer, so clear the parking lot and let the next sweep try again; anything genuinely
     * corrupt just fails once more and parks itself right back.
     */
    private fun onRosterLearned() {
        val n = unopenableMedia.size
        if (n == 0) return
        // Re-OPEN the bytes we kept rather than clearing the parking lot. Clearing only un-skipped
        // the refs so the next sweep re-downloaded them — which never helped, because the reason
        // they failed was the key, not the bytes.
        Log.i(TAG, "roster learned — re-opening $n quarantined media ref(s)")
        retryParkedOpens()
    }

    private fun rosterPullDue(accountHex: String): Boolean {
        val last = synchronized(rosterPullAt) { rosterPullAt[accountHex.lowercase()] } ?: return true
        return System.currentTimeMillis() - last > ROSTER_PULL_BACKOFF_MS
    }

    private fun noteRosterPullAttempt(accountHex: String) {
        synchronized(rosterPullAt) {
            rosterPullAt[accountHex.lowercase()] = System.currentTimeMillis()
            if (rosterPullAt.size > 500) rosterPullAt.clear()
        }
    }

    suspend fun fetchContactRoster(accountHex: String): Boolean {
        val acct = accountHex.lowercase()
        if (acct.length != 64) return false
        val key = "haven/devroster/$acct"
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        // Our own hosted store first — no dial, and a relay-hosting device usually already holds it.
        if (hostedHex != null) {
            val wire = runCatching { relayHost?.localGet(key) }.getOrNull()
            if (wire != null && wire.isNotEmpty() && runCatching { social.ingestRosterWire(wire) }.getOrDefault(false)) {
                Log.i(TAG, "devroster PULLED ${acct.take(8)} from own store — their devices are now resolvable")
                authorizeMembership()
                onRosterLearned()
                return true
            }
        }
        for (nodeHex in allRelays()) {
            if (nodeHex.startsWith("s3:")) continue
            if (hostedHex != null && nodeHex == hostedHex) continue
            val entry = relayEntries[nodeHex]
            if (entry != null && entry.httpToken.isNotEmpty()) {
                for (base in httpUrlsFor(entry)) {
                    val r = relayHttpGet(base, entry.httpToken, key)
                    // A refusal here routes through noteRefused, so a relay that doesn't know us yet
                    // triggers a roster publish rather than a backoff — the same self-heal as media.
                    if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "devroster read for ${acct.take(8)}"); continue }
                    if (r.isFailure) { markHttpUrlBad(base); continue }
                    val wire = r.getOrNull()
                    // Say WHICH of the two failures happened. "no PULLED line" covered both "the
                    // relay doesn't have it" and "we fetched it and could not ingest it", which need
                    // completely different fixes.
                    if (wire == null || wire.isEmpty()) {
                        Log.i(TAG, "devroster MISS ${acct.take(8)} at ${nodeHex.take(8)} — relay has no roster for them")
                    } else if (!runCatching { social.ingestRosterWire(wire) }.getOrDefault(false)) {
                        Log.w(TAG, "devroster INGEST REJECTED ${acct.take(8)} from ${nodeHex.take(8)} (${wire.size} B) — bytes arrived but the engine refused them")
                    }
                    if (wire != null && wire.isNotEmpty() && runCatching { social.ingestRosterWire(wire) }.getOrDefault(false)) {
                        markRelaySeen(nodeHex)
                        Log.i(TAG, "devroster PULLED ${acct.take(8)} from relay ${nodeHex.take(8)}")
                        authorizeMembership()
                        onRosterLearned()
                        return true
                    }
                }
            }
            val client = relayClientFor(nodeHex) ?: continue
            val wire = runCatching { client.get(key) }.getOrNull()
            if (wire != null && wire.isNotEmpty() && runCatching { social.ingestRosterWire(wire) }.getOrDefault(false)) {
                markRelayOk(nodeHex)
                Log.i(TAG, "devroster PULLED ${acct.take(8)} from relay ${nodeHex.take(8)} (dial)")
                authorizeMembership()
                return true
            }
        }
        return false
    }

    private fun helloPayload(circleId: String): ByteArray? {
        val name = profile.displayName.ifBlank { "Someone" }
        val circleName = social.circles().firstOrNull { it.id == circleId }?.name ?: "My Circle"
        val bundle = social.myBundle()
        val signed = social.mySignedProfile(name, profile.bio, profile.link, profile.avatarB64, profile.emoji)
        return Wire.helloPayload(circleId, circleName, bundle, signed)
    }

    /** Mailbox hello key — `haven/mailbox/<circle>/__hello__/<toAcct>/<fromAcct>/<sha256>`, the
     *  layout [pollMailbox] claims on the receiving side (iOS helloMailboxKey parity). Content-
     *  addressed over the hello body: the profile signature is deterministic, so the digest is
     *  stable across sync ticks and re-offers dedupe instead of minting a fresh key per pass. */
    private fun helloMailboxKey(circleId: String, toHex: String, fromHex: String, body: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(body).joinToString("") { "%02x".format(it) }
        return "haven/mailbox/$circleId/__hello__/${toHex.lowercase()}/${fromHex.lowercase()}/$digest"
    }

    /** `<relayHex>|<key>` pairs that LANDED. The re-offer skip is per-RELAY, deliberately NOT the
     *  global seen-set: a relay adopted AFTER a hello landed elsewhere must still be offered it,
     *  or the invite sits where the invitee never polls (the late-relay hole). In-memory only —
     *  a re-offer after relaunch is one idempotent content-addressed PUT per relay. */
    private val helloOffered = HashSet<String>()

    /**
     * Store-and-forward a HELLO through every relay serving the circle, for the peer iroh cannot
     * dial (cross-NAT — the lane a circle invite rides when the two networks never touch directly).
     * [toAccountHex] MUST be the member's ACCOUNT hex: every one of their devices claims the
     * account slot at the mailbox ([pollMailbox]'s meAcct check), while a transport/device id can
     * go stale with a re-minted bundle and strand the invite. iOS SharedStore.putHello parity,
     * plus the iroh-dial rung so a NAS relay that announces no HTTP interface still carries it.
     */
    private suspend fun putHelloMailbox(circleId: String, toAccountHex: String, hello: ByteArray) {
        val to = toAccountHex.trim().lowercase()
        if (to.length != 64) return
        if (to == nodeIdHex.lowercase()) return   // never hello ourselves
        val key = helloMailboxKey(circleId, to, nodeIdHex, hello)
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        for (nodeHex in relaysFor(circleId)) {
            if (nodeHex.startsWith("s3:")) continue   // presign pools carry events; hellos ride relay mailboxes
            val offered = "$nodeHex|$key"
            if (synchronized(helloOffered) { offered in helloOffered }) continue
            var landed = false
            if (hostedHex != null && nodeHex == hostedHex) {
                // Our OWN hosted relay: straight into the local store (no self-dial).
                landed = runCatching { relayHost?.localPut(key, hello) == true }.getOrDefault(false)
            } else {
                // Relay HTTP interface first (the reliable cross-NAT path), else the iroh dial.
                var forbidden = false
                val entry = relayEntries[nodeHex]
                if (entry != null) {
                    for (base in httpUrlsFor(entry)) {
                        val r = relayHttpPut(base, entry.httpToken, key, hello)
                        if (r.isSuccess) { markRelaySeen(nodeHex); landed = true; break }
                        // Refused = the relay doesn't know this device yet. The iroh path runs the
                        // same membership gate, so don't burn a dial on it — publish the roster
                        // (noteRefused → heal) and let the next tick's re-offer land.
                        if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "hello put"); forbidden = true; break }
                        markHttpUrlBad(base)
                    }
                }
                if (!landed && !forbidden) {
                    val client = relayClientFor(nodeHex) ?: continue
                    runCatching { client.put(key, hello) }
                        .onSuccess { markRelayOk(nodeHex); landed = true }
                        .onFailure { Log.d(TAG, "hello mailbox put failed ($nodeHex): ${it.message}"); relayFailed(nodeHex) }
                }
            }
            if (landed) {
                synchronized(helloOffered) {
                    if (helloOffered.size > 4000) helloOffered.clear()   // bound (tiny in practice)
                    helloOffered.add(offered)
                }
                markMailboxSeen(key)   // our own poll must not re-download our own hello
                Log.i(TAG, "hello mailbox-put to=${to.take(8)} circle=${circleId.take(12)} relay=${nodeHex.take(8)}")
            }
        }
    }

    /**
     * Expand a compose-time media list with `thumb:` pairing markers for photos whose tiny
     * companion was minted at attach time (LocalMedia.store). The marker joins the SIGNED list —
     * same pattern as `poster:` — so old clients simply ignore it. The bare thumb ref is
     * deliberately NOT listed: receivers learn it from the marker, so a legacy carousel never
     * shows a duplicate tiny slide. Apple FeedStore.withThumbMarkers parity.
     */
    private fun withThumbMarkers(media: List<String>): List<String> {
        if (media.isEmpty()) return media
        val out = ArrayList(media)
        for (ref in media) {
            if (!ref.startsWith("img_")) continue
            if (MediaVariants.thumbFor(ref, media) != null) continue
            val t = LocalMedia.thumbCompanion(ref) ?: continue
            if (LocalMedia.has(t)) out.add(MediaVariants.thumbMarker(ref, t))
        }
        return out
    }

    /** Queue a just-authored event's media for relay backup: PRIORITY lane (ahead of any backfill
     *  backlog), thumbs first, then posters, then content — so the placeholder-feeding bytes land
     *  before the big blobs start. Apple FeedStore.enqueueAuthoredMedia parity. */
    private fun enqueueAuthoredMedia(circleId: String, media: List<String>) {
        for (ref in MediaVariants.allThumbs(media) + MediaVariants.uploadOrder(media)) {
            enqueueBackup(circleId, ref, priority = true)
        }
    }

    /** Author a post in a circle and broadcast the sealed event to its members. */
    fun post(circleId: String, body: String, media: List<String> = emptyList(),
             music: uniffi.haven_ffi.TrackRefFfi? = null, retentionSecs: ULong? = null) {
        if (body.isBlank() && media.isEmpty() && music == null) return
        val withThumbs = withThumbMarkers(media)
        val ts = nowMs()
        val env = runCatching {
            // retentionSecs != null → a disappearing post (auto-expires in the feed reducer, iOS parity).
            social.post(circleId, body, withThumbs, music, retentionSecs, false, false, ts)
        }.getOrNull() ?: return
        // Read back the engine-derived id of the post just authored so the sealed banner carries `p`
        // (exact tap route on the recipient — Apple FeedStore.post parity). Best-effort: null keeps
        // the legacy circle route.
        val postId = runCatching { social.lastAuthoredEventId(circleId, ts) }.getOrNull()
        afterAuthor(circleId, env,
            PushBanner.forPost(circleId, circleName(circleId), body, withThumbs, story = false, postId = postId))
        enqueueAuthoredMedia(circleId, withThumbs)   // serialized priority lane: thumbs → posters → blobs
        // A post the engine accepted is Haven's one "significant action" for the rating gates.
        com.blaineam.haven.support.RatingManager.recordSignificantAction(appContext)
        // "Save my posts to Photos" (per-circle override, falling back to the app-wide default).
        if (media.isNotEmpty() && CircleSettings.saveOwn(circleId))
            scope.launch { media.forEach { MediaSaver.autoSave(appContext, it) } }
    }

    /** Build a portable track reference from a shared streaming link (YouTube/Spotify/etc.). */
    fun trackFromLink(url: String, title: String, artist: String): uniffi.haven_ffi.TrackRefFfi =
        uniffi.haven_ffi.TrackRefFfi(
            catalogId = url, title = title.ifBlank { "Shared track" },
            artist = artist, artworkUrl = "", durationMs = 0UL,
        )

    /** Post a story (a post with the story flag + 24h retention; auto-expires). [circleId] lets a
     *  caller aim it at a specific circle (qa-cmd `circle_id`); the UI's story path stays default. */
    /**
     * Give a VIDEO story its poster still — parity with Apple `CameraView.withPosterCompanions`.
     *
     * A story carries ONE media ref (each clip is its own story), so a video story published as a
     * bare `vid_` ref leaves three things with nothing to work with:
     *  - the viewer has no still to draw and spins for as long as the whole clip takes to transfer;
     *  - [enqueueAuthoredMedia] uploads posters/thumbs AHEAD of big blobs so the placeholder bytes
     *    land first — with no poster there are none;
     *  - data-saver prefetch skips full videos by contract and falls back to the declared poster.
     *
     * Idempotent: a ref that already declares a poster passes through, non-video refs are untouched.
     */
    private fun withPosterCompanions(circleId: String, refs: List<String>): List<String> {
        val out = ArrayList<String>()
        for (ref in refs) {
            if (!LocalMedia.isVideo(ref) || MediaVariants.posterFor(ref, refs) != null) { out.add(ref); continue }
            LocalMedia.ensurePosterImage(circleId, ref)?.let { poster ->
                out.add(poster)
                out.add(MediaVariants.posterMarker(ref, poster))
            }
            out.add(ref)
        }
        return out
    }

    fun postStory(body: String, mediaId: String?, music: uniffi.haven_ffi.TrackRefFfi? = null,
                  circleId: String = DEFAULT_CIRCLE) {
        if (body.isBlank() && mediaId == null && music == null) return
        val media = withPosterCompanions(circleId, withThumbMarkers(listOfNotNull(mediaId)))
        val ts = nowMs()
        val env = runCatching {
            social.post(circleId, body, media, music, 86_400UL, true, false, ts)
        }.getOrNull() ?: return
        val postId = runCatching { social.lastAuthoredEventId(circleId, ts) }.getOrNull()   // best-effort `p` tag (see `post`)
        afterAuthor(circleId, env,
            PushBanner.forPost(circleId, circleName(circleId), body, media, story = true, postId = postId))
        enqueueAuthoredMedia(circleId, media)   // priority lane: the story's blob beats any backfill
    }

    /** React / unreact / comment on a post — author + broadcast, same as a post. */
    fun react(circleId: String, postId: String, emoji: String) {
        val env = runCatching { social.react(circleId, postId, emoji, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env, PushBanner.forReaction(emoji, circleId, postId))
    }

    fun unreact(circleId: String, postId: String, emoji: String) {
        val env = runCatching { social.unreact(circleId, postId, emoji, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)   // retracting carries no news — silent wake only
    }

    fun comment(circleId: String, postId: String, body: String, media: List<String> = emptyList()) {
        // A media-only reply (a photo or a voice note with no text) is valid — iOS allows it too.
        if (body.isBlank() && media.isEmpty()) return
        val env = runCatching { social.comment(circleId, postId, body, media, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env, PushBanner.forComment(body, circleId, circleName(circleId), postId))
        media.forEach { enqueueBackup(circleId, it, priority = true) }   // a fresh reply's media beats backfill
    }

    /**
     * Edit your own post or message — text only. Attachments are carried through untouched.
     *
     * An Edit event RESTATES the whole item: the reducer overwrites body/media/music/muteVideo from
     * it rather than merging (`haven-p2p/src/social.rs`, `EventKind::Edit`). That is deliberate —
     * it is what lets re-optimize re-point an item at smaller bytes ([applyReoptimized]) — but it
     * means anything the edit does not carry forward is DELETED, for the author and for every
     * member of the circle, permanently.
     *
     * So this reads the attachments back off the item instead of taking them from the caller. The
     * previous signature defaulted them to `emptyList()`/`null`/`false` and trusted each editor to
     * remember; the post editor did, the DM editor did not, and editing a message's text deleted
     * its photo and its track for everyone in the thread. Nothing a text editor can pass should be
     * able to do that, so it can no longer pass anything: a caller that means to REPLACE media
     * calls [social].edit directly, the way [applyReoptimized] does.
     *
     * Blocking (feed() re-opens every envelope in the circle) — same as the other author paths.
     */
    fun editPost(circleId: String, postId: String, body: String) {
        // viewerRetentionSecs null: retention only hides items from MY feed. Resolving through a
        // filtered feed would miss an item the viewer can no longer see and fall back to "wipe".
        val feed = runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList())
        // No match means we could not read what to preserve. Dropping the edit is the safe failure:
        // the user retypes, versus the attachments being gone from everyone's device.
        val keep = EditCarry.forEvent(feed, postId) ?: return
        val env = runCatching {
            social.edit(circleId, postId, body, keep.media, keep.music, keep.muteVideo, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    // ---- Re-optimize media I already shared ----------------------------------------------------
    //
    // These two live here rather than in MediaReoptimizer.kt only because `social`, `afterAuthor` and
    // `enqueueBackup` are private to this object. Everything else about the feature — deciding what
    // needs rewriting, encoding it, driving the UI — is in that file. iOS parity:
    // FeedStore.reoptimizeTargets / applyReoptimized.

    /**
     * Every post and comment I AUTHORED that carries real media, across every circle including DMs.
     *
     * AUTHORED, because re-optimizing means re-publishing: [applyReoptimized] writes an Edit event,
     * and an Edit is signed by the author and rejected by the reducer unless the signer matches
     * (`haven-p2p/src/social.rs`: `if it.author == e.author`). I cannot re-point someone else's post
     * at new bytes and must not be able to. So this shrinks what I put INTO my circles; media others
     * sent me is left exactly as it arrived — the local caps and the orphan sweep are the answer there.
     *
     * Stories are excluded: they expire on their own, so rewriting one spends an encode and a
     * re-upload on bytes that are about to be dropped anyway. Unsent (retracted) items too.
     *
     * Blocking (feed() re-opens every envelope) — call off the main thread.
     */
    fun reoptimizeTargets(): List<MediaReoptimizer.Target> {
        if (!ready) return emptyList()
        val out = ArrayList<MediaReoptimizer.Target>()
        val now = nowMs()
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            // viewerRetentionSecs null: retention hides old posts from MY feed, but they are still
            // live on everyone else's devices and still costing them the old bytes.
            for (item in runCatching { social.feed(c.id, now, null) }.getOrDefault(emptyList())) {
                if (item.isMe && !item.unsent && !item.story && item.media.isNotEmpty()) {
                    out.add(MediaReoptimizer.Target(c.id, item.id, item.body, item.media,
                        item.music, item.muteVideo, item.createdAt.toLong()))
                }
                for (cm in item.comments) {
                    if (cm.isMe && !cm.unsent && cm.media.isNotEmpty()) {
                        out.add(MediaReoptimizer.Target(c.id, cm.id, cm.body, cm.media,
                            null, false, cm.createdAt.toLong()))
                    }
                }
            }
        }
        return out
    }

    /**
     * Re-point one of my posts/comments at the newly-encoded refs and re-share it.
     *
     * This is an ordinary Edit — the same event the edit sheet writes when you change a caption. The
     * reducer keeps the item's id, author, thread position and ORIGINAL createdAt and touches only
     * body/media/music, so nobody's feed reorders. The new blob is then queued for the relay exactly
     * as a fresh post's would be, so members who are offline right now still find it waiting.
     *
     * NOT SILENT-FLAGGED, because on Android there is nothing to flag: unlike iOS, the author path
     * ([afterAuthor]) sends no push and seals no banner — the *recipient* decides, in [notifyInbound],
     * which is gated on the circle's newest INBOUND item being under 10 minutes old AND not already
     * notified under its (unchanged) event id. A re-shared old post satisfies neither, so it cannot
     * raise a banner. Marking it on the wire would mean a new frame or a new field, which this feature
     * is explicitly not allowed to invent.
     *
     * Deliberately does NOT delete the old blob. A member who is offline right now still holds the
     * PRE-edit post naming the old ref; deleting the bytes hands them a permanently broken post. The
     * old bytes retire the ordinary way, via the weekly orphan sweep ([cleanupUnusedMedia]), which
     * already skips anything a live event references and gives partials a grace window. The saving
     * lands slightly later; nothing breaks in the gap.
     */
    fun applyReoptimized(target: MediaReoptimizer.Target, media: List<String>): Boolean {
        if (!ready) return false
        val env = runCatching {
            social.edit(target.circleId, target.eventId, target.body, media,
                target.music, target.muteVideo, nowMs())
        }.getOrNull() ?: return false
        afterAuthor(target.circleId, env)
        media.forEach { enqueueBackup(target.circleId, it) }
        return true
    }

    /** Unsend (delete) your own post; broadcasts the unsend event. */
    fun unsendPost(circleId: String, postId: String) {
        val env = runCatching { social.unsend(circleId, postId, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    /**
     * File a report against a post/message (decentralized moderation — docs/MODERATION.md): hide
     * it locally right away (the reporter never sees it again), broadcast the sealed report to the
     * whole circle, and append a content-free identity-vs-identity entry to the developer ledger.
     * Returns the reported author's FULL node hex (resolved by the core from the event log) so the
     * caller can offer block-in-the-same-motion.
     */
    fun report(circleId: String, target: String, reason: String, comment: String): String? {
        val env = runCatching { social.report(circleId, target, reason, comment, nowMs()) }.getOrNull() ?: return null
        afterAuthor(circleId, env)
        HiddenStore.hide(target)
        val author = runCatching { social.reports(circleId) }.getOrDefault(emptyList())
            .firstOrNull { it.target == target }?.author
        // The ledger row is account-signed (worker verifies against the account node id). A seedless
        // device holds no account key, so it files the in-circle report (above) but not the ledger row
        // — the primary owns account-signed artifacts (D10). Every seeded member can still ledger it.
        core.account?.let { ModerationLedger.report(it, author ?: "", reason) }
        return author
    }

    /** Reports filed in a circle by ANY member, grouped by the reported event id. Circles have no
     *  owner — every member sees every report and acts with the power they already hold. */
    fun reports(circleId: String): Map<String, List<uniffi.haven_ffi.ReportFfi>> =
        runCatching { social.reports(circleId) }.getOrDefault(emptyList()).groupBy { it.target }

    /** Persist, bump the feed, and broadcast a freshly-authored sealed envelope to members.
     *  [banner] = the kind-aware push copy for members' lock screens (null → a silent
     *  content-available wake only, e.g. an edit/unsend that carries no news). */
    private fun afterAuthor(circleId: String, env: ByteArray, banner: PushBanner.Copy? = null) {
        bumpActivity()   // I just posted/messaged → keep sync tight
        persist()
        scope.launch(Dispatchers.Main) { feedVersion.value++ }
        val payload = Wire.eventPayload(circleId, env)
        for (idHex in dialTargets(circleId)) sendFrame(Wire.EVENT, payload, idHex)
        // Live delivery (D16 Phase 4b): dialTargets deliberately excludes us, so my OTHER devices only
        // ever learned about this from the mailbox poll (30s+, stretching to 180s when idle). Hand it to
        // them now while they're online. Strictly an optimisation — the uploadEvent below is
        // unconditional and stays what a sleeping/not-yet-linked device gets. iOS parity.
        liveDeliverToMyDevices(Wire.EVENT, payload)
        // Store-and-forward via the circle relay so offline members still get it. The epoch HEAD
        // (roster + current key commit) rides along: with the full-history backfill throttled to
        // daily, a relay-only peer could otherwise pull this event long before the commit that opens
        // it (it would sit in their pending-epoch buffer). Cheap — the commit is cached until the
        // epoch/recipient set changes, and the persisted seen-set dedupes the re-upload. iOS parity.
        scope.launch {
            for (head in runCatching { social.exportEpochHead(circleId) }.getOrDefault(emptyList())) {
                uploadEvent(circleId, head)
            }
            uploadEvent(circleId, env)
        }
        // Push leg (Apple PushManager.wake/syncSelf parity): the blind worker forwards a banner
        // SEALED + SIGNED to each recipient (their NSE decrypts and verifies it really came from
        // us) plus the base64 sealed event inline, so an offline iPhone/Mac member gets a real
        // banner AND ingests the event with no mailbox round-trip. And a silent syncSelf so my own
        // pocketed devices catch up immediately. Android recipients keep polling (no FCM by
        // design) — this leg is for the members who DO hold push tokens.
        scope.launch {
            pushSyncSelf(env)
            val eventB64 = Base64.encodeToString(env, Base64.NO_WRAP)
            val notifJson = banner?.let { bannerJson(it, circleId) }
            for (member in runCatching { social.contactNodeIds(circleId) }.getOrDefault(emptyList())) {
                val sealed = notifJson?.let {
                    runCatching { social.sealSignedNotification(member, it) }.getOrNull()
                }
                pushWake(
                    member,
                    ciphertextB64 = sealed?.let { Base64.encodeToString(it, Base64.NO_WRAP) },
                    eventB64 = eventB64,
                    silent = sealed == null,
                )
            }
        }
        // Nearby mesh (never DMs — they stay point-to-point, matching iOS).
        if (NearbyTransport.active && !circleId.startsWith("dm:")) {
            NearbyTransport.broadcast(Wire.frame(Wire.EVENT, payload))
        }
    }

    // ---- Push relay leg (blind Cloudflare Worker; Apple PushManager parity) ---------------------

    /** The Apple `PushBanner.jsonObject` shape (`{t,b,bp,c,k,e?,p?}`) — sealed per recipient below
     *  so the worker never sees it and the recipient's NSE verifies the signer. `p` = the authored/
     *  PARENT post id, so the recipient's tap opens the exact post (Apple parity). */
    private fun bannerJson(copy: PushBanner.Copy, circleId: String): ByteArray? = runCatching {
        val o = JSONObject()
            .put("t", profile.displayName.ifBlank { "Someone" })
            .put("b", copy.body)
            .put("bp", copy.privateBody)
            .put("c", circleId)
            .put("k", copy.kind)
        copy.emoji?.let { o.put("e", it) }
        copy.postId?.takeIf { it.isNotEmpty() }?.let { o.put("p", it) }
        o.toString().toByteArray(Charsets.UTF_8)
    }.getOrNull()

    /** Ask the push relay to wake a (possibly offline) peer. [ciphertextB64] = the banner sealed to
     *  THAT peer (worker forwards it blind); null + [silent] = a bannerless content-available wake. */
    private fun pushWake(nodeId: String, ciphertextB64: String?, eventB64: String?, silent: Boolean) {
        if (nodeId.isEmpty()) return
        val body = JSONObject().put("nodeId", nodeId).put("ciphertext", ciphertextB64 ?: "_")
        if (eventB64 != null) body.put("event", eventB64)
        if (silent) body.put("silent", true)
        pushPost("/notify", body)
    }

    /** Multi-device: deliver an envelope to my OWN other devices' push tokens — a silent
     *  content-available push (no self-notify), inline event, no mailbox round-trip. */
    private fun pushSyncSelf(env: ByteArray) {
        pushPost("/notify", JSONObject()
            .put("nodeId", accountNodeHex)
            .put("event", Base64.encodeToString(env, Base64.NO_WRAP))
            .put("silent", true))
    }

    /** Fire-and-forget POST to the push worker ([PUSH_RELAY]) — failures only log (polling is the
     *  fallback lane, exactly as on Apple when push is unconfigured). */
    private fun pushPost(path: String, body: JSONObject) {
        val payload = body.toString().toByteArray(Charsets.UTF_8)
        scope.launch {
            runCatching {
                val c = (java.net.URL(PUSH_RELAY + path).openConnection() as java.net.HttpURLConnection).apply {
                    requestMethod = "POST"; doOutput = true; connectTimeout = 8000; readTimeout = 8000
                    setRequestProperty("Content-Type", "application/json")
                }
                try {
                    c.outputStream.use { it.write(payload) }
                    val code = c.responseCode
                    if (code != 200) Log.d(TAG, "push $path HTTP $code")
                } finally { c.disconnect() }
            }.onFailure { Log.d(TAG, "push $path failed: ${it.message}") }
        }
    }

    // ---- Nearby offline mesh (opt-in) ----

    private fun nearbyPrefs() = appContext.getSharedPreferences("haven.nearby", Context.MODE_PRIVATE)
    fun enableNearby() { nearbyPrefs().edit().putBoolean("on", true).apply(); NearbyTransport.start(appContext) }
    fun disableNearby() { nearbyPrefs().edit().putBoolean("on", false).apply(); NearbyTransport.stop() }
    fun nearbyActive(): Boolean = NearbyTransport.active
    /** The user's persisted intent — default ON for a P2P app. */
    fun nearbyWanted(): Boolean = nearbyPrefs().getBoolean("on", true)

    /** Honest nearby-mesh state for the sync UI, so the user knows WHY it is / isn't connected. */
    enum class NearbyState { CONNECTED, SEARCHING, NO_PERMISSION, OFF }
    fun nearbyState(): NearbyState = when {
        SyncMetrics.nearbyPeers.intValue > 0 -> NearbyState.CONNECTED
        !nearbyWanted() -> NearbyState.OFF
        !NearbyTransport.hasPermissions(appContext) -> NearbyState.NO_PERMISSION
        else -> NearbyState.SEARCHING
    }
    /** On launch: auto-start Nearby if wanted (default) and the perms are already granted. */
    fun restoreNearbyIfWanted() {
        if (nearbyWanted() && NearbyTransport.hasPermissions(appContext)) runCatching { NearbyTransport.start(appContext) }
    }

    /** A nearby peer just connected — greet over the mesh + back-fill the open circle. */
    fun onNearbyConnected() {
        bumpActivity()   // a peer just appeared → sync tight for the catch-up burst
        val hello = helloPayload(DEFAULT_CIRCLE) ?: return
        NearbyTransport.broadcast(Wire.frame(Wire.HELLO, hello))
        for (env in runCatching { social.syncEnvelopes(DEFAULT_CIRCLE) }.getOrDefault(emptyList())) {
            NearbyTransport.broadcast(Wire.frame(Wire.EVENT, Wire.eventPayload(DEFAULT_CIRCLE, env)))
        }
        reannounceOwnRelay()                 // a freshly-connected sibling/friend immediately learns this host's relay
        pushOwnMediaNearby(freshPeer = true) // a newly-connected sibling has nothing — push it my media now
    }

    /**
     * Re-emit the host's OWN relay id (frame 19) to every circle over nearby + to contacts via iroh,
     * WITHOUT the heavy backfill of [adoptRelay]. Frame 19 used to fire only once at relay start, so a
     * sibling/friend that wasn't reachable at that instant never learned the relay (the "sees the Mac
     * nearby but won't show its relay" bug). Cheap (one sealed announce per circle), so it's safe every
     * sync tick + on each connect. iOS reannounceOwnRelay parity.
     */
    private fun reannounceOwnRelay() {
        val hex = runCatching { relayHost?.nodeIdHex() }.getOrNull() ?: return
        if (hex.length != 64) return
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            val sealed = relayAnnounceBlob(c.id, hex) ?: continue
            val frame = Wire.eventPayload(c.id, sealed)  // [LP cid][sealed] — same layout as frame 19
            if (NearbyTransport.active) NearbyTransport.broadcast(Wire.frame(Wire.RELAY_NODE, frame))
            for (idHex in dialTargets(c.id)) {
                sendFrame(Wire.RELAY_NODE, frame, idHex)
            }
        }
    }

    /**
     * Opportunistically PUSH the media I hold to nearby own devices, symmetric-sealed to my account
     * (only my own devices can open it). Rides the nearby mesh — the reliable own-device channel when
     * iroh is blocked — so a linked sibling gets my photos WITHOUT relying on the request/response
     * round-trip (which delivers 0 chunks in practice). Deduplicated (each ref pushed once per peer
     * session) + budgeted + rate-limited (25s/ref); every item is an independent send so one large/slow
     * item can't stall the rest. [freshPeer] re-pushes everything for a newly-connected sibling.
     * All file-read + seal + I/O runs OFF the main thread (the [scope] is Dispatchers.IO). iOS parity.
     */
    private fun pushOwnMediaNearby(freshPeer: Boolean = false) {
        if (!ready || !NearbyTransport.active) return
        val me = runCatching { social.myNodeHex() }.getOrNull() ?: return
        if (freshPeer) pushedNearby.clear()
        val refs = LinkedHashSet<String>()
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            val feed = runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())
            for (item in feed) { refs.addAll(item.media); item.comments.forEach { refs.addAll(it.media) } }
        }
        var budget = 10   // a few per pass — paced so the nearby link isn't flooded; the rest follow next tick
        for (ref in refs) {
            if (budget <= 0) break
            if (pushedNearby.contains(ref) || LocationShare.isLocation(ref)) continue
            if (!LocalMedia.has(ref)) continue
            pushedNearby.add(ref)
            if (!shouldServeNearby(ref)) continue
            // Guarded like the request-driven serves: this runs off a TICK, so without it a slow push
            // that hasn't finished by the next pass gets a second copy of itself started on top.
            val bytes = LocalMedia.loadAnyCircle(ref) ?: continue
            serveOnce(ref, me) { sendMediaChunks(ref, bytes, me) }
            budget--
        }
        if (pushedNearby.size > 5000) pushedNearby.clear()
    }

    /**
     * Rate-limit serving a media ref over nearby: a waiting sibling re-requests every cycle, so without
     * this the same blobs were re-served hundreds of times, flooding the serial send queue so NOTHING
     * drained. One serve per ref per 25s lets the queue clear and chunks really deliver. iOS shouldServeNearby.
     */
    private fun shouldServeNearby(ref: String): Boolean {
        val nowMs = System.currentTimeMillis()
        servedAt[ref]?.let { if (nowMs - it < 25_000) return false }
        servedAt[ref] = nowMs
        if (servedAt.size > 4000) servedAt.clear()
        return true
    }

    /**
     * Symmetric key derived from the ACCOUNT seed — both of the user's own devices derive the identical
     * key, so own-device media chunks sealed with it ALWAYS open on the sibling. KEM-sealing-to-self was
     * unreliable (per-device engine identity made decap fail), which is why media between a user's own
     * devices never decrypted. Mirrors the (working) self-sync slot's account-derived key.
     * HKDF-SHA256(ikm=accountSeed, salt="haven-own-media-v1", info=empty, len=32). iOS ownMediaKey parity.
     */
    private val ownMediaKey: javax.crypto.spec.SecretKeySpec? by lazy {
        // Derived from the account SEED, which a seedless device doesn't hold — its own-device media
        // rides the normal circle-media path (device-bundle-sealed) instead. Returns null there.
        if (core.seedless) return@lazy null
        runCatching {
            val seed = core.seed
            val salt = "haven-own-media-v1".toByteArray(Charsets.UTF_8)
            // HKDF-Extract: PRK = HMAC-SHA256(salt, ikm).
            val extractMac = javax.crypto.Mac.getInstance("HmacSHA256")
            extractMac.init(javax.crypto.spec.SecretKeySpec(salt, "HmacSHA256"))
            val prk = extractMac.doFinal(seed)
            // HKDF-Expand: T(1) = HMAC-SHA256(PRK, info | 0x01); 32 bytes = one block, info empty.
            val expandMac = javax.crypto.Mac.getInstance("HmacSHA256")
            expandMac.init(javax.crypto.spec.SecretKeySpec(prk, "HmacSHA256"))
            val okm = expandMac.doFinal(byteArrayOf(0x01))
            javax.crypto.spec.SecretKeySpec(okm.copyOf(32), "AES")
        }.getOrNull()
    }

    /** AES-GCM seal with the own-media key. Output = [12-byte nonce][ciphertext+16-byte tag] (CryptoKit
     *  `.combined` layout, so iOS opens Android chunks and vice-versa). */
    private fun sealOwnMedia(plain: ByteArray): ByteArray? {
        val key = ownMediaKey ?: return null
        return runCatching {
            val nonce = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key, javax.crypto.spec.GCMParameterSpec(128, nonce))
            nonce + cipher.doFinal(plain)
        }.getOrNull()
    }

    /** AES-GCM open with the own-media key (null if it isn't an own-media chunk → caller falls back to KEM). */
    private fun openOwnMedia(sealed: ByteArray): ByteArray? {
        val key = ownMediaKey ?: return null
        if (sealed.size < 12 + 16) return null
        return runCatching {
            val nonce = sealed.copyOfRange(0, 12)
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(javax.crypto.Cipher.DECRYPT_MODE, key, javax.crypto.spec.GCMParameterSpec(128, nonce))
            cipher.doFinal(sealed, 12, sealed.size - 12)
        }.getOrNull()
    }

    // ---- Circle relay / mailbox (store-and-forward, so posts cross even when not both online) ----

    /**
     * The sealed frame-19 payload for one relay: the legacy bare 64-hex node id, or — when we know the
     * relay's plain-HTTP interface — a JSON `{"node":hex,"urls":[…],"token":…}` so members learn the
     * reliable cross-NAT media path too. Sealed to the circle either way; legacy receivers that expect
     * a bare hex simply ignore the JSON form (wrong length), so mixed versions stay compatible.
     */
    private fun relayAnnounceBlob(circleId: String, nodeHex: String): ByteArray? {
        val e = relayEntries[nodeHex]
        val addedAt = e?.addedAtMs ?: 0L
        val hasHttp = e != null && e.httpUrls.isNotEmpty() && e.httpToken.isNotEmpty()
        // Always carry the adoption timestamp so receivers can LWW a stale tombstone. Use the JSON form
        // whenever we have EITHER an HTTP interface or a non-zero adoption stamp; a legacy receiver
        // ignores JSON it can't read as a bare hex (wrong length), so mixed versions stay compatible.
        val hasDerp = e != null && e.derpUrl.isNotEmpty()
        val hasTurn = e != null && e.turnUrls.isNotEmpty()
        val payload = if (hasHttp || addedAt > 0 || hasDerp || hasTurn) {
            org.json.JSONObject().put("node", nodeHex).put("addedAt", addedAt).apply {
                if (hasHttp) { put("urls", JSONArray(e!!.httpUrls)); put("token", e.httpToken) }
                if (hasDerp) put("derp", e!!.derpUrl)
                if (hasTurn) {
                    put("turn", JSONArray(e!!.turnUrls))
                    if (e.turnUser.isNotEmpty()) put("turnUser", e.turnUser)
                    if (e.turnPass.isNotEmpty()) put("turnPass", e.turnPass)
                }
            }.toString().toByteArray(Charsets.UTF_8)
        } else nodeHex.toByteArray(Charsets.UTF_8)
        return runCatching { social.sealCircleMedia(circleId, payload) }.getOrNull()
    }

    /** Frame 19: [LP circleId][sealCircleMedia(relay node hex | {"node","urls","token"} JSON)].
     *  Store the relay (+ its HTTP interface when announced) + backfill/poll. */
    private fun handleRelayNode(body: ByteArray) {
        val r = Wire.Reader(body)
        val cidBytes = r.lp() ?: return
        val circleId = String(cidBytes, Charsets.UTF_8)
        val sealed = r.rest()
        if (circleId.isEmpty() || sealed.isEmpty()) return
        val opened = runCatching { social.openCircleMediaSender(circleId, sealed) }.getOrNull() ?: return
        val announcerHex = opened.senderHex.lowercase()   // authenticated envelope sender (account id)
        val text = String(opened.data, Charsets.UTF_8).trim()
        // Extended announce: JSON {node, urls, token, derp, turn, turnUser, turnPass}.
        var announcedUrls: List<String> = emptyList()
        var announcedToken = ""
        var announcedAddedAt = 0L
        var announcedDerp: String? = null
        var announcedTurn: List<String> = emptyList()
        var announcedTurnUser = ""
        var announcedTurnPass = ""
        val nodeHex: String = if (text.startsWith("{")) {
            val o = runCatching { JSONObject(text) }.getOrNull() ?: return
            announcedUrls = o.optJSONArray("urls")?.let { a ->
                (0 until a.length()).mapNotNull { i -> a.optString(i).takeIf { u -> u.startsWith("http") } }
            } ?: emptyList()
            announcedToken = o.optString("token", "")
            announcedAddedAt = o.optLong("addedAt", 0L)
            val d = o.optString("derp", "").trim()
            if (d.startsWith("http")) announcedDerp = d.trimEnd('/')
            announcedTurn = o.optJSONArray("turn")?.let { a ->
                (0 until a.length()).mapNotNull { i ->
                    a.optString(i).takeIf { u -> u.startsWith("turn:") || u.startsWith("turns:") }
                }
            } ?: o.optString("turn", "").takeIf { it.startsWith("turn:") || it.startsWith("turns:") }
                ?.let { listOf(it) } ?: emptyList()
            announcedTurnUser = o.optString("turnUser", "")
            announcedTurnPass = o.optString("turnPass", "")
            if (announcedTurnUser.isEmpty() && announcedTurn.isNotEmpty()) announcedTurnUser = "haven"
            if (announcedTurnPass.isEmpty() && announcedTurn.isNotEmpty() && announcedToken.isNotEmpty()) {
                announcedTurnPass = announcedToken
            }
            o.optString("node", "").trim().lowercase()
        } else text.lowercase()
        if (nodeHex.length != 64) return
        // A contact RE-ANNOUNCED a circle relay. Reactivating a deactivated/forgotten entry is allowed
        // ONLY when the announce comes from the relay's OWNER — the announced id is one of the sender's
        // own authorized device ids (their in-app relay; that's what lets your Mac's relay come back on
        // your phone when the Mac itself re-announces it), or their account id (legacy account-id
        // relay). A THIRD-PARTY echo must never resurrect it: every member re-announces every relay
        // they hold proof-of-life for, so a relay the user deliberately deleted — but which is still
        // RUNNING somewhere (an old docker container, a forgotten daemon) — bounced back within one
        // sync tick, forever. Non-owner announces of a tombstoned relay are dropped; brand-new relays
        // still auto-pool below. iOS parity.
        if (suppressedRelays.contains(nodeHex)) {
            // The user DELIBERATELY DELETED this relay. It comes back ONLY on a genuine re-add whose
            // adoption stamp is NEWER than our deletion (pure LWW) — NOT because its owner merely
            // reopened the app (that re-announces the relay's ORIGINAL, older adoption time). A stale
            // third-party echo and a legacy announce (addedAt=0) also lose. iOS parity (the "deleted
            // relays came back when mom opened the app" fix).
            if (announcedAddedAt <= relayForgottenAtMs(nodeHex)) return
            reactivateRelay(nodeHex, adoptedAtMs = announcedAddedAt)
        } else if (!isRelayActive(nodeHex)) {
            // Merely INACTIVE (deactivated, not deleted) — the owner may bring it back, or a newer
            // re-add. Keeps a Mac's relay coming back on the phone when the Mac re-announces it.
            val ownerDevices = runCatching { social.deviceNodeIdsFor(announcerHex) }
                .getOrDefault(emptyList()).map { it.lowercase() }
            val announcerOwnsRelay = nodeHex == announcerHex || nodeHex in ownerDevices
            val newerReAdd = announcedAddedAt > 0 && announcedAddedAt > relayForgottenAtMs(nodeHex)
            if (!announcerOwnsRelay && !newerReAdd) return
            reactivateRelay(nodeHex, adoptedAtMs = announcedAddedAt)
        }
        // A contact advertised their circle relay → ADD it to our redundant set for this circle,
        // so members automatically pool relays (more redundancy, no manual setup). Append, never
        // replace — parity with desktop handle_relay_node. Propagate the announced adoption stamp
        // (not now()) so the freshest legit re-add flows without any echo fabricating a new timestamp.
        val list = relayNodes.getOrPut(circleId) { mutableListOf() }
        ensureRelayEntry(nodeHex, isS3 = false, activate = true, adoptedAtMs = announcedAddedAt)
        // Record the relay's announced HTTP media interface (the reliable cross-NAT path).
        if (announcedUrls.isNotEmpty() && announcedToken.isNotEmpty()) {
            val e = relayEntries[nodeHex]
            if (e != null && (e.httpUrls != announcedUrls || e.httpToken != announcedToken)) {
                relayEntries[nodeHex] = e.copy(httpUrls = announcedUrls, httpToken = announcedToken)
                saveRelayNodes()
                Log.i(TAG, "learned relay http interface for ${nodeHex.take(8)}: ${announcedUrls.size} url(s)")
            }
            // New/rotated free CF hostname — stop skipping the old cool-down window (iOS parity).
            for (u in announcedUrls) httpUrlBad.remove(u)
        }
        // Haven fabric: DERP URL so peers prefer this box over n0 for live NAT.
        if (announcedDerp != null) {
            val e = relayEntries[nodeHex]
            if (e != null && e.derpUrl != announcedDerp) {
                relayEntries[nodeHex] = e.copy(derpUrl = announcedDerp)
                saveRelayNodes()
                refreshHavenFabric()
                Log.i(TAG, "learned relay DERP fabric for ${nodeHex.take(8)}: $announcedDerp")
            }
        }
        if (announcedTurn.isNotEmpty()) {
            val e = relayEntries[nodeHex]
            if (e != null && (e.turnUrls != announcedTurn || e.turnUser != announcedTurnUser || e.turnPass != announcedTurnPass)) {
                relayEntries[nodeHex] = e.copy(
                    turnUrls = announcedTurn,
                    turnUser = announcedTurnUser,
                    turnPass = announcedTurnPass,
                )
                saveRelayNodes()
                refreshHavenFabric()
                Log.i(TAG, "learned relay TURN for ${nodeHex.take(8)}: ${announcedTurn.size} url(s)")
            }
        }
        scope.launch(Dispatchers.Main) { bumpRelays() }   // recompose the Relays hub off the inbound thread
        // SUPERSEDE stale account-id relays: under the per-device transport a relay is ALWAYS a device id,
        // never an account id. A relay-list entry equal to a member's (or our own) ACCOUNT id is a dead
        // pre-device-seed leftover — nothing serves it and every media fetch burns a 30s timeout on it (the
        // "2 relays, one is the account id" bug). Learning a real device relay makes them obsolete → drop
        // them so the reachable device relay is what gets dialed. iOS parity; safe under the 154 cutover.
        val staleAccounts = (runCatching { social.contactNodeIds(circleId) }.getOrDefault(emptyList()) +
                             listOf(runCatching { social.myNodeHex() }.getOrDefault(""))).map { it.lowercase() }.toSet()
        var supersededAny = false
        for (a in staleAccounts) if (a.length == 64 && a != nodeHex && list.remove(a)) { suppressedRelays.add(a); supersededAny = true }
        if (supersededAny) saveRelayNodes()
        if (list.contains(nodeHex)) { saveRelayNodes(); return }
        list.add(nodeHex)
        saveRelayNodes()
        Log.i(TAG, "learned relay for $circleId: ${nodeHex.take(8)}")
        scope.launch {
            backfillMailbox(circleId)   // upload everything I've already posted here
            pollMailbox()
        }
    }

    // ---- Relay interface self-heal (rotated/never-learned HTTP front doors) ----------------------

    /** Last self-heal fetch attempt per relay (unix ms), so a media-miss storm can't hammer the
     *  same relay. Mirrors iOS `relayInterfaceRefreshMs`. */
    private val relayInterfaceRefreshMs = HashMap<String, Long>()

    /**
     * Fetch a relay's SELF-PUBLISHED interface (`haven/relay/__interface__` — its current public
     * HTTP URLs + token + DERP/TURN, written by the relay process at startup) over the iroh
     * channel that still works, and adopt it exactly like a frame-19 announce. This is the
     * self-heal for the failure that stranded media while posts flowed: a CLI relay restart
     * rotates its free-tunnel URL, every client keeps polling the mailbox over iroh (fine) and
     * fetching media over a front door that no longer exists (dead) — and the paste-wire flow
     * only ever ran once at adopt time. After adopting we re-announce, so members with no iroh
     * reach — including builds older than this one — learn the URL from the mailbox. iOS
     * `refreshRelayInterfaceIfNeeded` parity.
     */
    private fun refreshRelayInterfaceIfNeeded(nodeHex: String, force: Boolean = false) {
        val lower = nodeHex.trim().lowercase()
        if (lower.length != 64) return   // s3: pseudo-relays have no iroh side to ask
        // Only when we hold no HTTP interface, or every URL we hold is unusable from here
        // (bad window / LAN-implausible — httpUrlsFor is the one "usable" judge) — OR when a caller
        // has just WATCHED the front door fail (`force`).
        //
        // Holding a URL is not evidence it works, and this guard used to treat it as if it were.
        // A rotated free-tunnel hostname stays a well-formed public https URL forever, so
        // `httpUrlsFor` keeps calling it usable; meanwhile neither failure mode marks it bad — a
        // 404 is read as "the relay lacks this blob" and a 403 as "the relay is healthy, we're not
        // authorized". Nothing could ever make the held set empty, so the one mechanism that can
        // learn the new hostname over iroh was permanently unreachable. The relay self-heals on
        // restart exactly as designed; the client just refused to ask. The 5-minute throttle below
        // is what keeps `force` cheap.
        val held = relayEntries[lower]
        if (!force && held != null && httpUrlsFor(held).isNotEmpty()) return
        val nowMs = System.currentTimeMillis()
        synchronized(relayInterfaceRefreshMs) {
            if (nowMs - (relayInterfaceRefreshMs[lower] ?: 0L) < 300_000) return
            relayInterfaceRefreshMs[lower] = nowMs
        }
        scope.launch {
            val client = relayClientFor(lower) ?: return@launch
            val data = runCatching { client.get("haven/relay/__interface__") }.getOrNull() ?: return@launch
            val o = runCatching { JSONObject(String(data, Charsets.UTF_8)) }.getOrNull() ?: return@launch
            // A relay may only describe ITSELF — the key is served from its own store, but
            // never adopt a doc whose node field disagrees with who we asked.
            if (o.optString("node", "").trim().lowercase() != lower) return@launch
            val urls = o.optJSONArray("urls")?.let { a ->
                (0 until a.length()).mapNotNull { i -> a.optString(i).takeIf { u -> u.startsWith("http") } }
            } ?: emptyList()
            val token = o.optString("token", "")
            if (urls.isEmpty() || token.isEmpty()) return@launch
            Log.i(TAG, "relay interface ${lower.take(10)}: learned ${urls.size} url(s) over iroh — adopting + re-announcing")
            ensureRelayEntry(lower, isS3 = false, activate = true)
            relayEntries[lower]?.let { relayEntries[lower] = it.copy(httpUrls = urls, httpToken = token) }
            // Rotated hostname — stop skipping the old cool-down window.
            for (u in urls) httpUrlBad.remove(u)
            val derp = o.optString("derp", "").trim()
            if (derp.startsWith("http")) {
                relayEntries[lower]?.let { relayEntries[lower] = it.copy(derpUrl = derp.trimEnd('/')) }
            }
            val turn = o.optJSONArray("turn")?.let { a ->
                (0 until a.length()).mapNotNull { i ->
                    a.optString(i).takeIf { u -> u.startsWith("turn:") || u.startsWith("turns:") }
                }
            } ?: emptyList()
            if (turn.isNotEmpty()) {
                // Same credential defaults as the frame-19/paste parsers of this JSON shape.
                val turnUser = o.optString("turnUser", "").ifEmpty { "haven" }
                val turnPass = o.optString("turnPass", "").ifEmpty { token }
                relayEntries[lower]?.let {
                    relayEntries[lower] = it.copy(turnUrls = turn, turnUser = turnUser, turnPass = turnPass)
                }
            }
            saveRelayNodes()
            if (derp.startsWith("http") || turn.isNotEmpty()) refreshHavenFabric()
            withContext(Dispatchers.Main) { bumpRelays() }
            // React like a frame-19 that taught us a public URL: pull what we were missing and
            // push what the circle was missing, then re-announce so everyone else learns it too.
            val circles = relayNodes.toMap().filterValues { it.contains(lower) }.keys
            for (cid in circles) {
                // Sealed frame-19 with the freshly-learned interface — members with no iroh reach
                // to this relay learn the rotated URL from us (nearby + direct; the sync tick's
                // proven-alive re-announce keeps propagating it from here on).
                val sealed = relayAnnounceBlob(cid, lower)
                if (sealed != null) {
                    val frame = Wire.eventPayload(cid, sealed)  // [LP cid][sealed] — same layout as frame 19
                    if (NearbyTransport.active) NearbyTransport.broadcast(Wire.frame(Wire.RELAY_NODE, frame))
                    for (idHex in dialTargets(cid)) sendFrame(Wire.RELAY_NODE, frame, idHex)
                }
                backfillMailbox(cid)
                backfillHistoryToRelay(cid)
            }
            reannounceOwnRelay()
            pollMailbox()
        }
    }

    /** Frame 20: [LP circleId][sealCircleMedia(bootstrap GET URL)] for the S3 pre-signed pool. */
    private fun handlePresignBootstrap(body: ByteArray) {
        val r = Wire.Reader(body)
        val cidBytes = r.lp() ?: return
        val circleId = String(cidBytes, Charsets.UTF_8)
        val sealed = r.rest()
        if (circleId.isEmpty() || sealed.isEmpty()) return
        val open = runCatching { social.openCircleMedia(circleId, sealed) }.getOrNull() ?: return
        val url = String(open, Charsets.UTF_8).trim()
        if (!url.startsWith("http")) return
        Presign.setBootstrap(circleId, url)
        Log.i(TAG, "adopted S3 presign pool for $circleId")
        scope.launch { backfillMailbox(circleId); pollMailbox() }
    }

    /**
     * Adopt a relay node for all circles (Settings paste) — ADDED to the redundant set, not
     * replacing existing relays — + tell contacts via frame 19. Adopt several for redundancy.
     * This is the EXPLICIT path, so it CLEARS any suppression AND reactivates the entry.
     */
    /** This circle's relay LINK — hand it to a `haven-relay` daemon / the Docker relay
     *  (`haven-relay run --link <link>`); it then prints a node id you paste back via adoptRelay.
     *  Carries only the circle tag + public member node ids (no key material). Parity with iOS. */
    fun relayLink(circleId: String = activeCircle.value): String? = runCatching {
        val members = social.contactNodeIds(circleId).toMutableList()
        runCatching { social.myNodeHex() }.getOrNull()?.let { members.add(it) }
        uniffi.haven_ffi.makeRelayLink(circleId, members)
    }.getOrNull()

    /**
     * Adopt a relay. Accepts either a bare 64-hex node id, or the JSON interface blob printed by
     * `haven-relay` (`{"node","urls","token","derp","turn",…}`) so HTTP media + DERP + TURN are
     * learned in one paste and re-announced to the circle (frame 19).
     */
    fun adoptRelay(nodeHex: String, name: String? = null, setDefault: Boolean = false) {
        val raw = nodeHex.trim()
        var hex = raw.lowercase()
        var urls: List<String> = emptyList()
        var token = ""
        var derp = ""
        var turnUrls: List<String> = emptyList()
        var turnUser = ""
        var turnPass = ""
        if (raw.startsWith("{")) {
            val o = runCatching { JSONObject(raw) }.getOrNull() ?: return
            hex = o.optString("node", "").trim().lowercase()
            urls = o.optJSONArray("urls")?.let { a ->
                (0 until a.length()).mapNotNull { i -> a.optString(i).takeIf { u -> u.startsWith("http") } }
            } ?: emptyList()
            token = o.optString("token", "")
            derp = o.optString("derp", "").trim().trimEnd('/')
            turnUrls = o.optJSONArray("turn")?.let { a ->
                (0 until a.length()).mapNotNull { i ->
                    a.optString(i).takeIf { u -> u.startsWith("turn:") || u.startsWith("turns:") }
                }
            } ?: emptyList()
            turnUser = o.optString("turnUser", "")
            turnPass = o.optString("turnPass", "")
            if (turnUser.isEmpty() && turnUrls.isNotEmpty()) turnUser = "haven"
            if (turnPass.isEmpty() && turnUrls.isNotEmpty() && token.isNotEmpty()) turnPass = token
        }
        if (hex.length != 64) return
        unforgetRelay(hex)   // explicit adoption overrides a prior Forget + records a re-add CLEAR for self-sync
        ensureRelayEntry(hex, name = name, isS3 = false, activate = true)   // adoptedAtMs=0 → stamp now()
        if (urls.isNotEmpty() && token.isNotEmpty()) {
            val e = relayEntries[hex]
            if (e != null) relayEntries[hex] = e.copy(httpUrls = urls, httpToken = token)
        }
        if (derp.isNotEmpty()) {
            val e = relayEntries[hex]
            if (e != null) relayEntries[hex] = e.copy(derpUrl = derp)
        }
        if (turnUrls.isNotEmpty()) {
            val e = relayEntries[hex]
            if (e != null) relayEntries[hex] = e.copy(turnUrls = turnUrls, turnUser = turnUser, turnPass = turnPass)
        }
        if (derp.isNotEmpty() || turnUrls.isNotEmpty()) {
            refreshHavenFabric()
        }
        if (setDefault) defaultRelayHex = hex
        scope.launch {
            for (c in social.circles()) {
                val cid = c.id
                val list = relayNodes.getOrPut(cid) { mutableListOf() }
                if (!list.contains(hex)) list.add(hex)
                // Tell members (sealed) so they use the same mailbox + fabric.
                val sealed = relayAnnounceBlob(cid, hex)
                if (sealed != null) {
                    val frame = Wire.eventPayload(cid, sealed)  // [LP cid][sealed] — same layout as frame 19
                    for (idHex in dialTargets(cid)) sendFrame(Wire.RELAY_NODE, frame, idHex)
                }
                backfillMailbox(cid)
            }
            saveRelayNodes()
            withContext(Dispatchers.Main) { bumpRelays() }
            pollMailbox()
        }
    }

    /**
     * Add an S3 bucket as a (store-and-forward) relay: persist its creds via [StorageStore], record a
     * RelayEntry(isS3=true) so it shows in the Relays list, and associate it with every circle. The
     * secret lives in StorageStore (the device-local creds store), never in the relays prefs. Mirrors
     * iOS `addS3Relay` — represented as a synthetic "s3:<bucket>" relay id.
     */
    fun addS3Relay(config: StorageStore.Config, name: String?, setDefault: Boolean) {
        if (!config.isConfigured) return
        StorageStore.save(appContext, config)
        val hex = "s3:${config.bucket.trim()}"
        unforgetRelay(hex)   // explicit re-add overrides a prior Forget + records a self-sync CLEAR
        ensureRelayEntry(hex, name = name, isS3 = true, activate = true)
        if (setDefault) defaultRelayHex = hex
        scope.launch {
            for (c in social.circles()) {
                val list = relayNodes.getOrPut(c.id) { mutableListOf() }
                if (!list.contains(hex)) list.add(hex)
                backfillMailbox(c.id)
            }
            saveRelayNodes()
            withContext(Dispatchers.Main) { bumpRelays() }
            pollMailbox()
        }
    }

    /**
     * DEACTIVATE a relay across EVERY circle (non-destructive): flip active=false, KEEP its name +
     * circle associations, suppress passive auto-relearn while inactive, and drop its cached
     * connection + health. The config survives so it can be reactivated later. Mirrors iOS `forget`.
     */
    fun forgetRelay(nodeHex: String) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        scope.launch {
            val e = relayEntries[hex]
            relayEntries[hex] = if (e != null) e.copy(active = false)
                else RelayEntry(hex, shortRelayName(hex), false, relayNow(), hex.startsWith("s3:"))
            // Keep relayNodes + the default intact — only the active flag changes. relaysFor() already
            // filters inactive entries out, so it stops being dialed/served immediately.
            suppressedRelays.add(hex)   // tombstone so passive auto-learn can't resurrect it
            forgotAtRelays[hex] = relayNow()   // LWW: a re-announce only wins if (re-)added AFTER this
            clearedRelayForgets.remove(hex)   // a fresh deletion supersedes any prior re-add clear
            saveRelayNodes()
            relayMutex.withLock {
                runCatching { relayClients.remove(hex)?.close() }
                relayHealth.remove(hex)
            }
            invalidateListDigests(hex)   // its cached LIST digests describe a relay we no longer read
            withContext(Dispatchers.Main) { bumpRelays() }
        }
    }

    /** Reactivate a deactivated relay: flip active=true + clear its suppression so it's dialed again.
     *  `adoptedAtMs`: 0 = explicit local reactivation (stamp now()); non-zero = the announce's stamp. */
    fun reactivateRelay(nodeHex: String, adoptedAtMs: Long = 0) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        unforgetRelay(hex)   // clears suppression/forget + records a re-add CLEAR so self-sync supersedes a stale sibling tombstone
        ensureRelayEntry(hex, activate = true, adoptedAtMs = adoptedAtMs)
        relayHealth.remove(hex)   // clear stale backoff so it's retried immediately
        saveRelayNodes()
        bumpRelays()
    }

    /** Clear a relay's FORGOTTEN tombstone (an explicit adoption / reactivation overrides a prior Forget)
     *  and — when it WAS forgotten — record the re-add as a CLEAR (hex → now) so self-sync supersedes a
     *  sibling's stale deletion tombstone instead of the grow-only tombstone re-forgetting it forever.
     *  Mirrors iOS `unforget`. Caller persists via saveRelayNodes(). */
    private fun unforgetRelay(hex: String) {
        val hadTombstone = suppressedRelays.remove(hex)
        val hadForget = forgotAtRelays.remove(hex) != null
        if (hadTombstone || hadForget) clearedRelayForgets[hex] = relayNow()
    }

    /** ERASE a relay for good — its associations across every circle, its entry, the default, caches. */
    fun eraseRelayNow(nodeHex: String) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        scope.launch {
            val servedCircles = relayNodes.filterValues { it.contains(hex) }.keys.toList()
            for (list in relayNodes.values) list.removeAll { it == hex }
            relayNodes.entries.removeAll { it.value.isEmpty() }
            // Archive BEFORE the entry and its associations are gone — afterwards there is nothing
            // left to reconstruct it from. Note relayNodes was already swept above, so the circle list
            // is captured from the pre-sweep snapshot taken at the top of this block.
            relayEntries[hex]?.let { e ->
                erasedRelays[hex] = ErasedRelay(e, servedCircles, defaultRelayHex == hex, relayNow())
                pruneErasedRelays()
            }
            if (defaultRelayHex == hex) defaultRelayHex = ""
            relayEntries.remove(hex)
            suppressedRelays.add(hex)
            forgotAtRelays[hex] = relayNow()   // LWW deletion stamp (a later re-add can still supersede)
            clearedRelayForgets.remove(hex)   // a fresh deletion supersedes any prior re-add clear
            forgetBackedUp(hex)   // relay gone for good → re-mirror if a relay with this id ever returns
            saveRelayNodes()
            relayMutex.withLock {
                runCatching { relayClients.remove(hex)?.close() }
                relayHealth.remove(hex)
            }
            withContext(Dispatchers.Main) { bumpRelays() }
        }
    }

    /** Rename a relay (user-facing label only). */
    fun renameRelay(nodeHex: String, name: String) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        val trimmed = name.trim()
        val e = relayEntries[hex] ?: return
        if (trimmed.isEmpty()) return
        relayEntries[hex] = e.copy(name = trimmed)
        saveRelayNodes(); bumpRelays()
    }

    /** Pick a relay as the all-circles default (or null to clear it). */
    fun setDefaultRelay(nodeHex: String?) {
        val hex = nodeHex?.let { if (it.startsWith("s3:")) it else it.trim().lowercase() }
        if (hex != null) ensureRelayEntry(hex, activate = true)
        defaultRelayHex = hex ?: ""
        saveRelayNodes(); bumpRelays()
    }

    /** Toggle whether a single configured relay applies to one circle (per-circle override). */
    fun setCircleRelay(circleId: String, nodeHex: String, on: Boolean) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        if (on) {
            val list = relayNodes.getOrPut(circleId) { mutableListOf() }
            if (!list.contains(hex)) list.add(hex)
        } else {
            relayNodes[circleId]?.removeAll { it == hex }
            if (relayNodes[circleId]?.isEmpty() == true) relayNodes.remove(circleId)
        }
        saveRelayNodes(); bumpRelays()
        scope.launch { if (on) backfillMailbox(circleId); pollMailbox() }
    }

    /** The relays EXPLICITLY associated with this circle (no default fallback, INCLUDING inactive). */
    fun explicitRelaysForCircle(circleId: String): List<String> = relayNodes[circleId]?.toList() ?: emptyList()

    // ---- RelayEntry bookkeeping (deactivate-not-erase model) ----

    /** Epoch-ms as a Long for relay bookkeeping (the top-level nowMs() returns ULong for the FFI). */
    private fun relayNow() = System.currentTimeMillis()

    private fun shortRelayName(hex: String): String =
        if (hex.startsWith("s3:")) "S3 · " + hex.removePrefix("s3:").take(16)
        else "Relay · " + hex.take(8) + "…"

    /** True when a relay is recorded + currently active. Unknown hexes are treated active (nothing breaks). */
    fun isRelayActive(hex: String): Boolean = relayEntries[hex]?.active ?: true

    /** Create-or-update a RelayEntry. `activate` flips it on; lastSeen is stamped now on first create.
     *  `adoptedAtMs`: 0 = explicit local adoption (stamp now()); non-zero = the announce's adoption
     *  stamp (propagate it, don't invent a fresh one — inventing now() on every echo would let a stale
     *  relay's re-announce keep beating a user's forget = the zombie loop). Adoption stamp only moves
     *  FORWARD (max). Mirrors iOS `ensureEntry(adoptedAtMs:)`. */
    private fun ensureRelayEntry(hex: String, name: String? = null, isS3: Boolean = false, activate: Boolean = false, adoptedAtMs: Long = 0) {
        val e = relayEntries[hex]
        relayEntries[hex] = if (e != null) {
            e.copy(
                name = if (!name.isNullOrBlank()) name else e.name,
                active = if (activate) true else e.active,
                addedAtMs = if (adoptedAtMs > 0) maxOf(e.addedAtMs, adoptedAtMs) else e.addedAtMs,
            )
        } else {
            RelayEntry(hex, if (name.isNullOrBlank()) shortRelayName(hex) else name, true, relayNow(), isS3,
                addedAtMs = if (adoptedAtMs > 0) adoptedAtMs else relayNow())
        }
        saveRelayNodes()
    }

    /** Stamp a relay as just-seen (a successful op) — persisted so "last seen" survives a restart. */
    private fun markRelaySeen(hex: String) {
        val e = relayEntries[hex] ?: return
        relayEntries[hex] = e.copy(lastSeenMs = relayNow())
        saveRelayNodes()
    }

    /** Ensure every relay referenced by relayNodes / the default has a RelayEntry (legacy migration). */
    private fun migrateRelayEntries() {
        var changed = false
        val known = HashSet<String>()
        for (list in relayNodes.values) known.addAll(list)
        if (defaultRelayHex.isNotEmpty()) known.add(defaultRelayHex)
        for (hex in known) if (relayEntries[hex] == null) {
            relayEntries[hex] = RelayEntry(hex, shortRelayName(hex), true, relayNow(), hex.startsWith("s3:"))
            changed = true
        }
        if (changed) saveRelayNodes()
    }

    /** ERASE only entries that are BOTH inactive AND unseen > 7 days. Called on launch + the sync timer. */
    fun purgeStaleRelays() {
        val cutoff = relayNow()
        val dead = relayEntries.values.filter { !it.active && (cutoff - it.lastSeenMs) > RELAY_STALE_AFTER_MS }
        for (e in dead) eraseRelayNow(e.hex)
    }

    /** Every configured relay (active + inactive), active-first then by name — for the Relays hub. */
    fun allRelayEntries(): List<RelayEntry> = relayEntries.values.toList().sortedWith(
        // Snapshot to a list BEFORE sorting: sorting a live map view lets entries move underneath the
        // comparator, and a comparator that sees an inconsistent set is how TimSort throws.
        compareByDescending<RelayEntry> { it.active }.thenBy { it.name.lowercase() }
    )

    // ---- Deleted-relay archive (undo for "Delete now") -----------------------------------
    //
    // eraseRelayNow drops the entry, every circle association and the default pick, and a relay is a
    // 64-character node id — not something anyone re-adds from memory. Archive enough to put it back.
    // Apple parity (RelayMailboxStore.erasedRelays / restoreErased).

    data class ErasedRelay(val entry: RelayEntry, val circles: List<String>, val wasDefault: Boolean, val erasedAt: Long)

    private val erasedRelays = LinkedHashMap<String, ErasedRelay>()
    private const val ERASED_KEEP_MAX = 12
    private const val ERASED_TTL_MS = 30L * 24 * 60 * 60 * 1000

    /** Deleted relays that can still be brought back, newest deletion first. */
    fun erasedRelayList(): List<ErasedRelay> {
        val cutoff = relayNow() - ERASED_TTL_MS
        return erasedRelays.values.filter { it.erasedAt > cutoff }.sortedByDescending { it.erasedAt }
    }

    /** Undo a "Delete now": put the entry, its circle associations and (if it held it) the default
     *  back, clearing the suppression + deletion stamps so the next self-sync pass cannot read our own
     *  tombstone and delete it again. */
    fun restoreErasedRelay(nodeHex: String) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        val rec = erasedRelays.remove(hex) ?: return
        scope.launch {
            val now = relayNow()
            relayEntries[hex] = rec.entry.copy(active = true, lastSeenMs = now, addedAtMs = now)
            for (cid in rec.circles) {
                val list = relayNodes.getOrPut(cid) { mutableListOf() }
                if (!list.contains(hex)) list.add(hex)
            }
            if (rec.wasDefault && defaultRelayHex.isEmpty()) defaultRelayHex = hex
            suppressedRelays.remove(hex)
            forgotAtRelays.remove(hex)
            clearedRelayForgets[hex] = now   // publish an explicit CLEAR so a sibling's tombstone loses
            forgetBackedUp(hex)              // its copy of our media may be stale or gone — re-mirror
            relayMutex.withLock { relayHealth.remove(hex) }
            saveRelayNodes()
            withContext(Dispatchers.Main) { bumpRelays() }
        }
    }

    /** Forget an archived deletion for good (the user chose not to keep the undo around). */
    fun dropErasedRelay(nodeHex: String) {
        if (erasedRelays.remove(nodeHex) == null) return
        saveRelayNodes(); bumpRelays()
    }

    private fun pruneErasedRelays() {
        val cutoff = relayNow() - ERASED_TTL_MS
        erasedRelays.entries.removeAll { it.value.erasedAt <= cutoff }
        while (erasedRelays.size > ERASED_KEEP_MAX) {
            val oldest = erasedRelays.values.minByOrNull { it.erasedAt } ?: break
            erasedRelays.remove(oldest.entry.hex)
        }
    }

    /** The all-circles default relay hex, or null. */
    fun defaultRelay(): String? = defaultRelayHex.ifEmpty { null }

    /** Bump so the relay-settings UI recomposes after the adopted set / health changes. */
    var relaysVersion = mutableStateOf(0); private set
    private fun bumpRelays() { relaysVersion.value++ }

    /** The redundant ACTIVE relay set for a circle: its own list plus the all-circles default (deduped).
     *  Deactivated relays are filtered out so they aren't dialed/served, but their config survives. */
    private fun relaysFor(circleId: String): List<String> {
        // `relayStoodDown` matters far more here than in [allRelays]: this is the hot path (mailbox
        // list/put, selfsync, hello, live-call, media fetch). Gating only [allRelays] meant the
        // stand-down was computed, logged, and then ignored by nearly every request that mattered.
        val out = (relayNodes[circleId] ?: emptyList())
            .filter { isRelayActive(it) && !relayStoodDown(it) }.toMutableList()
        if (defaultRelayHex.isNotEmpty() && isRelayActive(defaultRelayHex) &&
            !relayStoodDown(defaultRelayHex) && !out.contains(defaultRelayHex))
            out.add(defaultRelayHex)
        return out
    }

    /** Every distinct ACTIVE relay across all circles + the default — for mesh sync / active transport. */
    private fun allRelays(): List<String> {
        // `relayStoodDown` drops relays that are refusing us outright. They stay ACTIVE and
        // configured — this is not a health verdict — they are just not worth a request until the
        // backoff expires. See noteRefused for why a refusal cannot be retried out of existence.
        val out = relayNodes.values.flatten()
            .filter { isRelayActive(it) && !relayStoodDown(it) }
            .distinct().toMutableList()
        if (defaultRelayHex.isNotEmpty() && isRelayActive(defaultRelayHex) &&
            !relayStoodDown(defaultRelayHex) && !out.contains(defaultRelayHex))
            out.add(defaultRelayHex)
        return out
    }

    /** Every distinct ACTIVE relay this device knows — every active relay ENTRY (INCLUDING those
     *  learned from a sealed announce but not yet wired to any circle), plus every relay referenced
     *  by a circle, plus the all-circles default; deduped, inactive/forgotten excluded. Unlike
     *  [allRelays] (per-circle associations + default only) this also folds in announce-learned
     *  entries, so a selfsync-learned circle with no relay association can still fall back to the
     *  relay it demonstrably reaches. Mirrors desktop `all_active_relay_hexes` / iOS `allRelays()`. */
    private fun allActiveRelayHexes(): List<String> {
        val out = LinkedHashSet<String>()
        for (e in relayEntries.values) if (e.active) out.add(e.hex)
        for (hex in relayNodes.values.flatten()) if (isRelayActive(hex)) out.add(hex)
        if (defaultRelayHex.isNotEmpty() && isRelayActive(defaultRelayHex)) out.add(defaultRelayHex)
        return out.toList()
    }

    private fun relayAvailable(nodeHex: String): Boolean =
        relayHealth[nodeHex]?.available(System.currentTimeMillis()) ?: true

    private fun markRelayOk(nodeHex: String) {
        relayHealth.getOrPut(nodeHex) { RelayHealth() }.recordSuccess()
        markRelaySeen(nodeHex)   // stamp lastSeen so the stale-clock only ticks while truly unseen
        // It answered — so whatever it was refusing us for is over. Drop the stand-down immediately
        // rather than making the user wait out a backoff the relay has already stopped earning.
        noteRelayAccepted(nodeHex)
    }

    private fun markRelayFail(nodeHex: String) {
        relayHealth.getOrPut(nodeHex) { RelayHealth() }.recordFailure(System.currentTimeMillis())
    }

    /** (nodeHex, reachable, isHostedByUs) for every distinct adopted relay — for the UI. */
    fun relaysDetail(): List<Triple<String, Boolean, Boolean>> {
        val hosted = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        return allRelays().map { hex ->
            Triple(hex, relayAvailable(hex), hosted == hex)
        }
    }

    // ---- Hosting: run the circle's relay in-process on this device ----

    private var relayHost: uniffi.haven_ffi.RelayServerHandle? = null
    val hosting = mutableStateOf(false)

    /** Start serving the circle's mailbox from this device + adopt it for every circle. The relay now
     *  ATTACHES to the messaging node's endpoint (one iroh node, two ALPNs) — running a second in-process
     *  iroh node made iroh churn paths unboundedly (the tens-of-GB leak). Relay id == account node id. */
    /**
     * How much of your circles' media this device is willing to keep, and for how long. Hosting a
     * relay used to mean volunteering the whole disk with no way to say otherwise — the FFI simply
     * never exposed the retention haven-net has supported all along. `0` on either means "no limit"
     * for that dimension; with both set the sweep applies whichever frees space first.
     *
     * Defaults are deliberately generous but finite: an unbounded default is how a helpful relay
     * quietly eats a phone. The mailbox TTL is deliberately NOT exposed — undelivered messages are a
     * delivery guarantee, not disposable cache.
     *
     * Read at ATTACH time, so a change applies when the relay next starts; the UI says so rather
     * than pretending a live change took effect.
     */
    const val DEFAULT_MEDIA_MAX_AGE_DAYS = 30
    const val DEFAULT_MEDIA_MAX_BYTES = 32L * 1024 * 1024 * 1024   // 32 GB

    var relayMediaMaxAgeDays: Int
        get() = prefs.getInt("relay.mediaMaxAgeDays", DEFAULT_MEDIA_MAX_AGE_DAYS)
        set(v) { prefs.edit().putInt("relay.mediaMaxAgeDays", v.coerceAtLeast(0)).apply(); bumpRelays() }

    var relayMediaMaxBytes: Long
        get() = prefs.getLong("relay.mediaMaxBytes", DEFAULT_MEDIA_MAX_BYTES)
        set(v) { prefs.edit().putLong("relay.mediaMaxBytes", v.coerceAtLeast(0)).apply(); bumpRelays() }

    fun startHosting() {
        if (relayHost != null) return
        val n = node ?: run {
            // Node not up yet — retry shortly; the relay can't exist without the node to attach to.
            scope.launch(Dispatchers.Main) { delay(1000); startHosting() }
            return
        }
        scope.launch {
            val dir = File(appContext.filesDir, "relay").apply { mkdirs() }.absolutePath
            // attachWithLimits, not attach: attach runs media UNLIMITED, which is the whole disk.
            val h = runCatching {
                uniffi.haven_ffi.RelayServerHandle.attachWithLimits(
                    n, dir,
                    relayMediaMaxAgeDays.toUInt(),
                    relayMediaMaxBytes.toULong(),
                )
            }.getOrElse { Log.e(TAG, "relay host attach failed", it); return@launch }
            relayHost = h
            withContext(Dispatchers.Main) { hosting.value = true }
            val nodeHex = h.nodeIdHex()   // == the account node id now
            Log.i(TAG, "hosting circle relay (shared endpoint): ${nodeHex.take(8)}")
            authorizeMembership()   // lock the mailbox to circle members before announcing it
            startRelayHttp(h, nodeHex)   // plain-HTTP media interface (the reliable cross-NAT path)
            adoptRelay(nodeHex)     // use it + tell contacts via frame 19
        }
    }

    /**
     * Serve the hosted relay's store over plain HTTP — the DEFAULT cross-NAT media transport (the
     * iroh blob ALPN drops datagrams on pure-relay cross-NAT paths, so blob dials that must cross a
     * NAT stall ~30s and die). Gated on a per-request signature over the caller's transport key +
     * circle membership — the same check the iroh path runs; the frame-19 token is mixed into that
     * signature rather than sent, so it is a pre-filter and never the authorization. The reachable URLs (LAN + an optional
     * user-configured public URL for port-forward/reverse-proxy/tunnel setups, prefs key
     * `relayPublicUrl`) are stored on our own RelayEntry so every announce carries them.
     */
    private suspend fun startRelayHttp(h: uniffi.haven_ffi.RelayServerHandle, nodeHex: String) {
        val token = relayHttpToken()
        // serveHttp returns the bound port (UShort). Try the fixed port first; if it's taken, fall
        // back to an ephemeral one (0.0.0.0:0). null from BOTH → serve failed.
        val port: Int = (runCatching { h.serveHttp("0.0.0.0:$RELAY_HTTP_PORT", token) }.getOrNull()
            ?: runCatching { h.serveHttp("0.0.0.0:0", token) }.getOrNull())?.toInt()
            ?: run { Log.e(TAG, "relay http serve failed"); return }
        val urls = relayHttpUrls(port)
        if (urls.isEmpty()) { Log.w(TAG, "relay http up on :$port but no reachable URL found"); return }
        Log.i(TAG, "relay http interface on :$port → $urls")
        val e = relayEntries[nodeHex]
        relayEntries[nodeHex] = (e ?: RelayEntry(nodeHex, shortRelayName(nodeHex), true, relayNow(), false))
            .copy(httpUrls = urls, httpToken = token)
        saveRelayNodes()
    }

    private val RELAY_HTTP_PORT = 8674

    /** The persisted bearer token for OUR hosted relay's HTTP interface (generated once). */
    private fun relayHttpToken(): String {
        prefs.getString("relayHttpToken", null)?.takeIf { it.isNotEmpty() }?.let { return it }
        val bytes = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
        val tok = bytes.joinToString("") { "%02x".format(it) }
        prefs.edit().putString("relayHttpToken", tok).apply()
        return tok
    }

    /**
     * What we tell the circle they can reach this relay's HTTP interface at.
     *
     * A configured public URL wins OUTRIGHT — LAN addresses are not appended to it. The operator has
     * said how members reach this box; adding `192.168.x` behind that only gives every remote member
     * something to try and time out on, which is precisely the failure the CLI relay never had: it
     * announces nothing unless told, so callers go straight to the path that works.
     *
     * With no public URL we still announce LAN addresses, because a member on the SAME network should
     * use them — that is the fast local path and it genuinely works. Remote members discard them on
     * receipt ([httpUrlsFor] keeps a private address only when we are on that /24), so the useless
     * case is filtered by the side that can actually tell. Mirrors iOS `RelayHost.reachableHttpUrls`.
     */
    private fun relayHttpUrls(port: Int): List<String> {
        prefs.getString("relayPublicUrl", null)?.trim()?.takeIf { it.startsWith("http") }
            ?.let { return listOf(it.trimEnd('/')) }
        return lanIPv4s().map { "http://$it:$port" }
    }

    /** Every up, non-loopback, non-link-local IPv4 on this device (iOS `RelayHost.lanIPv4s`). */
    private fun lanIPv4s(): List<String> {
        val out = LinkedHashSet<String>()
        runCatching {
            for (ni in java.net.NetworkInterface.getNetworkInterfaces()) {
                if (!ni.isUp || ni.isLoopback) continue
                for (addr in ni.inetAddresses) {
                    if (addr is java.net.Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        addr.hostAddress?.let { out.add(it) }
                    }
                }
            }
        }
        return out.toList()
    }

    /**
     * Lock each circle's relay mailbox to its members (+ sibling relays) so only members can read or
     * enumerate it — a stranger who learns the relay id gets nothing (audit transport-F4). Called on
     * host start and on membership refresh. Invoked reflectively because the committed bindings
     * (haven_ffi.kt) predate `authorizeCircle`; it activates once android/build-rust.sh regenerates
     * them and no-ops harmlessly until then (parity with meshSync's reflective syncFrom).
     */
    private fun authorizeMembership() {
        val host = relayHost ?: return
        val authorize = runCatching {
            host.javaClass.methods.firstOrNull { it.name == "authorizeCircle" && it.parameterTypes.size == 3 }
        }.getOrNull() ?: return
        val me = runCatching { social.myNodeHex() }.getOrNull() ?: ""
        val myDev = runCatching { social.myDeviceNodeHex() }.getOrNull() ?: ""
        for (c in runCatching { social.circles() }.getOrNull().orEmpty()) {
            val accounts = social.contactNodeIds(c.id).toMutableList()
            if (me.isNotEmpty() && !accounts.contains(me)) accounts.add(me)
            // Authorize each member by their DEVICE node ids too (per-device transport — a peer connects as
            // its device id), keeping the account id for any pre-multidevice peer. Includes MY device id so a
            // sibling can read. De-duplicated. Parity with iOS circleMemberships(); without it a friend on
            // the device transport is "forbidden" at our relay even after we hold their roster.
            val ids = LinkedHashSet<String>()
            for (a in accounts) {
                ids.add(a)
                runCatching { social.deviceNodeIdsFor(a) }.getOrDefault(emptyList()).forEach { ids.add(it) }
            }
            if (myDev.isNotEmpty()) ids.add(myDev)
            runCatching { authorize.invoke(host, c.id, ids.toList(), relaysFor(c.id)) }
        }
    }

    /** A friend announced their signed device roster (type 27). Ingest it so we learn their DEVICE node ids,
     *  then refresh our relay's circle authorization — else a friend on the per-device transport connects
     *  with a device id our member list doesn't recognize and every fetch is "forbidden". */
    private fun handleDeviceRosterAnnounce(body: ByteArray) {
        if (runCatching { social.ingestRosterWire(body) }.getOrDefault(false)) authorizeMembership()
    }

    fun stopHosting() {
        runCatching { relayHost?.close() }
        relayHost = null
        hosting.value = false
    }

    /**
     * Mesh anti-entropy: if we host an in-app relay, pull every sealed blob each adopted SIBLING
     * relay holds that we lack, so the mailbox self-replicates across relays — any relay can then
     * join/leave freely without losing the circle's data. Parity with desktop engine.mesh_sync.
     *
     * Calls the core's `RelayServerHandle::sync_from(peerNodeHex) -> u32` FFI per sibling. The
     * generated uniffi bindings (haven_ffi.kt) currently PREDATE sync_from (they only expose
     * nodeIdHex), so we invoke it reflectively: this compiles + runs against the current .so once
     * the bindings are regenerated (android/build-rust.sh), and no-ops harmlessly until then.
     */
    /** Hand each relay the circle's full relay list so replication is symmetric. Best-effort and
     *  silent: an older relay has no such verb and simply keeps its configured peer set. */
    private suspend fun teachSiblingRelays(pool: List<String>) {
        val hexes = pool.distinct().filter { it.length == 64 }
        if (hexes.size < 2) return   // nothing to teach when we're the only relay
        val circleIds = runCatching { social.circles().map { it.id } }.getOrDefault(emptyList())
        if (circleIds.isEmpty()) return
        for (target in hexes) {
            val client = relayClientFor(target) ?: continue
            for (cid in circleIds) {
                runCatching { client.teachRelays(cid, hexes.filter { it != target }) }
            }
        }
    }

    private suspend fun meshSync() {
        val host = relayHost ?: return
        authorizeMembership()   // keep the allow-list fresh as membership / relays change
        val myHex = runCatching { host.nodeIdHex() }.getOrNull() ?: return
        val syncFrom = runCatching {
            host.javaClass.methods.firstOrNull {
                it.name == "syncFrom" && it.parameterTypes.size == 1 &&
                    it.parameterTypes[0] == String::class.java
            }
        }.getOrNull() ?: return   // bindings predate sync_from — skip until regenerated
        // Teach every relay in the pool about the others. We already pull from all of them; a
        // HEADLESS relay knew only the `--peer` hexes its operator typed, so it never pulled back
        // and anything uploaded while it was offline stayed missing there. Apple parity.
        teachSiblingRelays(allRelays().filter { it.length == 64 } + myHex)
        for (peer in allRelays()) {
            if (peer == myHex || !relayAvailable(peer)) continue
            val pulled = runCatching {
                // sync_from is `async fn` → uniffi generates a `suspend` method, surfaced over JNA
                // as a method returning a value (the bindings drive the future). Reflective call.
                when (val r = syncFrom.invoke(host, peer)) {
                    is Number -> r.toLong()
                    else -> 0L
                }
            }.getOrDefault(0L)
            if (pulled > 0L) {
                markRelayOk(peer)
                withContext(Dispatchers.Main) { relayActive.value = true }
            }
        }
    }

    private suspend fun relayClientFor(nodeHex: String): RelayClient? = relayMutex.withLock {
        relayClients[nodeHex]?.let { return it }
        // NEVER dial our OWN account node id. Relays now share the account node id, and same-account
        // sibling devices share it too — so dialing it is a self-dial, which sends iroh's path discovery
        // into a tight loop (open_path_on_all_conns), exploding memory by tens of GB — THE runaway leak.
        // We never need a client to ourselves. (Was guarded ONLY while hosting, so a non-hosting device —
        // or a second device — still self-dialed.) Same root cause + fix as iOS/macOS.
        val mine = runCatching { node?.nodeIdHex() ?: social.myNodeHex() }.getOrNull()?.trim()?.lowercase()
        if (!mine.isNullOrEmpty() && nodeHex.trim().lowercase() == mine) return null
        // We CONNECT as our ACCOUNT identity (core.seed) below, so dialing a relay whose id == our own ACCOUNT
        // id is the account dialing itself — the same path-discovery runaway. Under device-seed transport the
        // guard above only catches our DEVICE id, so a stale relay entry equal to our account id would leak.
        val myAccount = runCatching { social.myNodeHex() }.getOrNull()?.trim()?.lowercase()
        if (!myAccount.isNullOrEmpty() && nodeHex.trim().lowercase() == myAccount) return null
        if (runCatching { relayHost?.nodeIdHex() }.getOrNull() == nodeHex && nodeHex.isNotEmpty()) return null
        // Skip a relay that's in its backoff window — try the others instead.
        if (!relayAvailable(nodeHex)) return null
        // Dial over our NODE's WARM, DERP-established endpoint (node.relayClient) instead of a fresh
        // RelayClient.connect endpoint that cold-starts DERP on every fetch — the reason cross-network relay
        // GETs timed out (30s) while messaging showed "Connected · Relay". Reusing the warm endpoint is what
        // lets media actually fetch over the internet. Parity with the iOS RelayHost change.
        val c = runCatching { node?.relayClient(nodeHex) }.getOrNull()
        if (c == null) { markRelayFail(nodeHex); return null }
        markRelayOk(nodeHex)
        relayClients[nodeHex] = c
        c
    }

    /** On a put/list/get failure: back the relay off and drop its cached connection. */
    private suspend fun relayFailed(nodeHex: String) = relayMutex.withLock {
        markRelayFail(nodeHex)
        runCatching { relayClients.remove(nodeHex)?.close() }
        Unit
    }

    private fun mailboxKey(circleId: String, env: ByteArray): String {
        val h = MessageDigest.getInstance("SHA-256").digest(env).joinToString("") { "%02x".format(it) }
        return "haven/mailbox/$circleId/$h"
    }

    /** Drop a sealed event into the circle's mailbox (Haven relay node and/or S3 pre-signed pool). */
    private suspend fun uploadEvent(circleId: String, env: ByteArray) {
        // Skip anything already confirmed in a mailbox: envelopes re-seal deterministically now, so
        // a backfill reproduces the same content-addressed key and the persisted seen-set makes the
        // whole re-upload a no-op instead of a network sweep (and, before determinism, a fresh
        // mailbox entry per event per run — the bloat behind the slow cold start).
        val key = mailboxKey(circleId, env)
        ensureSeenMailboxLoaded()
        var landed = false
        // S3 pre-signed pool (the BYO-bucket path many circles use).
        if (Presign.hasBootstrap(circleId)) {
            if (Presign.uploadEvent(circleId, nodeIdHex, env)) {
                landed = true
                withContext(Dispatchers.Main) { relayActive.value = true }
            }
        }
        // Mirror to EVERY configured Haven relay (redundancy). Content-addressed keys make
        // re-puts idempotent, and a relay in backoff is skipped — graceful fallback.
        // SYMMETRIC with pollMailbox's ephemeral fallback: a selfsync-learned circle whose winning
        // record carried an EMPTY relay list has NO key in relayNodes, so relaysFor() is empty and
        // an authored event (post OR reaction/comment — all funnel through afterAuthor) would upload
        // to ZERO relays; relay-only members (cross-NAT peers, the matrix stub) would never receive
        // it. Fall back to every ACTIVE relay this device knows (s3 handled by the Presign leg
        // above). Ephemeral by design: never writes relayNodes.
        val relayHexes = relaysFor(circleId).ifEmpty {
            if (relayNodes.containsKey(circleId)) emptyList()
            else allActiveRelayHexes().filter { !it.startsWith("s3:") }
        }
        // One info line per authored upload so a future empty-relay-set drop (relays=0 → nothing
        // reaches relay-only members) is visible in logcat instead of silently vanishing.
        Log.i(TAG, "uploadEvent circle=${circleId.take(16)} relays=${relayHexes.size}")
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        // PER-(relay,key) skip (iOS parity): the old global "seen once anywhere -> skip forever"
        // starved every relay adopted, recovered, or GC-swept AFTER a key first landed. The
        // epoch-head KEY COMMIT has a stable content-addressed key, so it landed once long ago
        // and never reached the relay a peer actually polls -- their copy of every event sealed
        // under that epoch buffered in pending_epoch forever (the content blackout's sender half).
        val unlanded = relayHexes.filter { !seenMailbox.contains("put:$it|$key") }
        if (relayHexes.isNotEmpty() && unlanded.isEmpty()) return
        for (nodeHex in unlanded) {
            // S3-bucket relay (store-and-forward): PUT the sealed blob straight into the bucket via the
            // direct S3 FFI using the device-local creds (StorageStore). Content-addressed key.
            if (nodeHex.startsWith("s3:")) {
                val cfg = StorageStore.s3Config(appContext) ?: continue
                runCatching { uniffi.haven_ffi.s3Put(cfg, key, env) }
                    .onSuccess { landed = true; markRelaySeen(nodeHex); markMailboxSeen("put:$nodeHex|$key"); withContext(Dispatchers.Main) { relayActive.value = true } }
                    .onFailure { Log.d(TAG, "s3 relay put failed ($nodeHex): ${it.message}") }
                continue
            }
            // Our OWN hosted relay: store directly into the local mailbox (no iroh self-dial).
            if (hostedHex != null && nodeHex == hostedHex) {
                runCatching { relayHost?.localPut(key, env) }.onSuccess { landed = true; markMailboxSeen("put:$nodeHex|$key") }
                withContext(Dispatchers.Main) { relayActive.value = true }
                continue
            }
            // Relay HTTP interface FIRST (the reliable cross-NAT path — a cloudflared / free-CF /
            // LAN-NAS relay never iroh-dials), else the iroh dial. Same ladder as hello-put + the
            // mailbox poll. uploadEvent was the one mailbox-WRITE path still iroh-only, so an
            // authored envelope (post OR reaction/comment) could only ride the iroh blob ALPN —
            // which drops on pure-relay cross-NAT paths — and never reached an HTTP-only relay:
            // relay-only members (cross-NAT peers, the matrix stub) lost this device's events. The
            // send half of the poll side's "put via HTTP, polled via iroh, nothing landed" fix.
            var putOk = false
            val entry = relayEntries[nodeHex]
            if (entry != null) {
                for (base in httpUrlsFor(entry)) {
                    val r = relayHttpPut(base, entry.httpToken, key, env)
                    if (r.isSuccess) {
                        markRelayOk(nodeHex); landed = true; putOk = true
                        markMailboxSeen("put:$nodeHex|$key")
                        withContext(Dispatchers.Main) { relayActive.value = true }
                        break
                    }
                    // Same store behind every URL — a membership refusal stands; don't fall through
                    // to iroh (it runs the same gate) and let the roster republish + next tick land.
                    if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "mailbox put"); putOk = true; break }
                    markHttpUrlBad(base)
                }
            }
            if (!putOk) {
                val client = relayClientFor(nodeHex) ?: continue
                runCatching { client.put(key, env) }
                    .onSuccess {
                        landed = true
                        markRelayOk(nodeHex)
                        markMailboxSeen("put:$nodeHex|$key")
                        withContext(Dispatchers.Main) { relayActive.value = true }
                    }
                    .onFailure { Log.d(TAG, "mailbox put failed ($nodeHex): ${it.message}"); relayFailed(nodeHex) }
            }
        }
        if (landed) markMailboxSeen(key)
    }

    /** Re-upload every post I authored in a circle (for members who were offline when I posted).
     *  `eventsToo = false` skips the event re-seal (a hybrid signature per event) and only enqueues
     *  media — used by the 2-minute sync tick, which needs media freshness but not a daily-enough
     *  event sweep. */
    private suspend fun backfillMailbox(circleId: String, eventsToo: Boolean = true) {
        // Mirror uploadEvent's fallback: a selfsync-learned circle with no relayNodes association
        // still has somewhere to land if this device knows any active relay, so the catch-up sweep
        // must not short-circuit it the way a truly relay-less, S3-less circle is skipped.
        val hasRelay = relaysFor(circleId).isNotEmpty() ||
            (!relayNodes.containsKey(circleId) && allActiveRelayHexes().any { !it.startsWith("s3:") })
        if (!hasRelay && !Presign.hasBootstrap(circleId)) return
        if (eventsToo) {
            val envs = runCatching { social.exportMyEnvelopes(circleId) }.getOrDefault(emptyList())
            for (env in envs) uploadEvent(circleId, env)
            // TOUCH the same refs on every relay so mailbox GC keeps them (uploadEvent is
            // seen-set-skipped once an envelope landed ONCE — without this, nothing would ever
            // refresh a live entry and the relay's 30-day TTL would eat real history). Misses
            // are re-PUT, so the daily refresh also repairs a relay that lost our entries.
            refreshMailboxKeys(circleId, envs)
        }
        // Also push the media bytes of anything I've posted here that I still hold locally — through
        // the serial media queue so several circles backfilling at once can't stack full blobs in RAM.
        val feed = runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList())
        for (item in feed) if (item.isMe) item.media.forEach { if (LocalMedia.has(it)) enqueueBackup(circleId, it) }
    }

    /** Refresh the liveness of my envelopes on every iroh relay serving a circle — ONE batched
     *  TOUCH per relay; the relay bumps their GC clocks and replies with the keys it does NOT
     *  hold, which are re-PUT (refresh doubles as repair). Deliberately ignores the seen-set:
     *  "seen" means uploaded once, and this exists precisely to re-assert what already exists.
     *  S3 pseudo-relays have no GC, and our own hosted relay is touched locally (no self-dial). */
    private suspend fun refreshMailboxKeys(circleId: String, envs: List<ByteArray>) {
        if (envs.isEmpty()) return
        val byKey = envs.associateBy { mailboxKey(circleId, it) }
        val keys = byKey.keys.toList()
        val prefix = "haven/mailbox/$circleId/"
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        for (nodeHex in relaysFor(circleId)) {
            if (nodeHex.startsWith("s3:")) continue
            if (hostedHex != null && nodeHex == hostedHex) {
                val misses = runCatching { relayHost?.localTouch(keys) }.getOrNull() ?: continue
                for (k in misses) byKey[k]?.let { env -> runCatching { relayHost?.localPut(k, env) } }
                continue
            }
            val client = relayClientFor(nodeHex) ?: continue
            val result = runCatching { client.touch(prefix, keys) }
            val misses = result.getOrNull()
            if (misses == null) {
                // Unreachable, or a pre-GC relay without TOUCH — it isn't sweeping, skip safely.
                Log.d(TAG, "mailbox touch failed ($nodeHex): ${result.exceptionOrNull()?.message}")
                continue
            }
            markRelayOk(nodeHex)
            for (k in misses) byKey[k]?.let { env -> runCatching { client.put(k, env) } }
        }
    }

    /** Ensure the relay holds this circle's FULL history (every event + every media blob I hold,
     *  not just my own) ASAP, so a newly-added member who can't receive it directly can pull it from
     *  the relay — no fragmented posts. Parity with iOS backfillMailboxMedia. No-op without a mailbox. */
    private suspend fun backfillHistoryToRelay(circleId: String) {
        if (relaysFor(circleId).isEmpty() && !Presign.hasBootstrap(circleId)) return
        for (env in runCatching { social.syncEnvelopes(circleId) }.getOrDefault(emptyList())) {
            uploadEvent(circleId, env)
        }
        val refs = LinkedHashSet<String>()
        val feed = runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList())
        for (item in feed) {
            refs.addAll(item.media)
            item.comments.forEach { refs.addAll(it.media) }
        }
        // Serialized: enqueue each blob to the single media queue so the whole-library backfill (and
        // any concurrent per-circle backfills) load at most one full media file into RAM at a time.
        for (ref in refs) if (LocalMedia.has(ref)) enqueueBackup(circleId, ref)
    }

    /** Control-plane keys rank first — they unlock everything else (iOS pullMailbox parity). */
    private fun mailboxKeyRank(key: String): Int = when {
        key.contains("/__hello__/") -> 0
        key.contains("/__relay__/") -> 1
        else -> 2
    }

    /** Poll every circle's mailbox; ingest envelopes we haven't seen. */
    suspend fun pollMailbox() {
        if (!ready) return
        // SINGLE-FLIGHT (iOS parity): overlapping sweeps both LIST before either finishes
        // marking, so they GET + ingest the same backlog twice — with a big backlog that
        // stacks duplicate work faster than it drains (the 55 GB relay-hosting-Mac spiral).
        // A poll that arrives mid-sweep coalesces into ONE follow-up sweep.
        if (!pollMailboxInFlight.compareAndSet(false, true)) {
            pollMailboxQueued.set(true)
            return
        }
        try {
            pollMailboxOnce()
            while (pollMailboxQueued.compareAndSet(true, false)) pollMailboxOnce()
        } finally {
            pollMailboxInFlight.set(false)
        }
    }

    private val pollMailboxInFlight = java.util.concurrent.atomic.AtomicBoolean(false)
    private val launchHeadsPublished = java.util.concurrent.atomic.AtomicBoolean(false)
    private val pollMailboxQueued = java.util.concurrent.atomic.AtomicBoolean(false)

    private suspend fun pollMailboxOnce() {
        ensureSeenMailboxLoaded()
        repairMailboxSeenOnce()
        repairStormBurnedSeenOnce()
        // Publish every circle's epoch HEAD (roster + current key commit) once per launch (iOS
        // parity): a member who hasn't posted since a relay was adopted/recovered/GC-swept never
        // re-offers the commit, and peers buffer every event of theirs forever. Cheap: cached
        // commit + per-(relay,key) upload marks make repeats a no-op.
        if (launchHeadsPublished.compareAndSet(false, true)) {
            for (cid in runCatching { social.circles().map { it.id } }.getOrDefault(emptyList())) {
                for (head in runCatching { social.exportEpochHead(cid) }.getOrDefault(emptyList())) {
                    uploadEvent(cid, head)
                }
            }
        }
        var changed = false
        // Whether ANY receive() ran this pass. receive() can change engine state without reporting
        // a new event — an envelope that arrives before its key commit is BUFFERED in
        // pending_epoch and returns false — so persisting only `if (changed)` dropped those
        // buffers on process death and the eventual commit had nothing left to unlock (delivery
        // gap; mirror of desktop engine.rs pollMailbox).
        var receiveRan = false
        // NEW envelopes this pass — fan out to my other linked devices after ingest. Mailbox was
        // the hole in receive-time fan-out: a friend's post landed on whichever of my devices
        // polled first and never reached the rest when their mailbox auth/relay set differed.
        val newlyIngested = ArrayList<Pair<String, ByteArray>>()
        fun ingestMailboxEnv(circleId: String, env: ByteArray): Boolean {
            receiveRan = true
            if (!runCatching { social.receive(circleId, env) }.getOrDefault(false)) return false
            newlyIngested.add(circleId to env)
            notifyInbound(circleId)
            return true
        }
        val meAcct = nodeIdHex.lowercase()
        val meDev = runCatching { social.myDeviceNodeHex() }.getOrDefault("").lowercase()
        /**
         * Claim ONLY hellos addressed to one of MY ids: my account hex (the canonical slot) or my
         * transport device id (transition senders addressed per dial target). A hello addressed
         * to any OTHER id — another member, a sibling device, a STALE id of mine — is not ours to
         * touch. The old "someone else's — just mark" burned those slots forever on whichever
         * device polled first, which is exactly how circle invites vanished; leave them for their
         * owners (or the relay TTL). Non-hello keys always pass (iOS shouldFetchHello parity).
         */
        fun helloSlotIsMine(key: String): Boolean {
            val marker = "/__hello__/"
            val i = key.indexOf(marker)
            if (i < 0) return true
            val to = key.substring(i + marker.length).substringBefore('/').lowercase()
            return to == meAcct || to == meDev
        }
        /**
         * Route ONE fetched mailbox blob and answer whether its key may be marked seen.
         *  • `__hello__` addressed to me → [handleHello]; marked seen ONLY when CONSUMED (applied
         *    or deliberately dropped) — a HELD hello (approval gate, engine hiccup) keeps its
         *    mailbox slot so the next poll retries; marking it here is how a circle grant riding
         *    a hello from a not-yet-approved contact evaporated forever (E2E stub / hosting-Mac
         *    symptom, iOS pullMailbox parity). Addressed to someone else → untouched, never marked.
         *  • `__relay__` → the durable frame-19 relay announce ([handleRelayNode]) — friends who
         *    can't iroh-dial the host still learn the relay + public media URL from the mailbox.
         *  • content → `receive()`; marked ONLY on a successful ingest, so an envelope buffered
         *    ahead of its key commit is retried instead of burned (desktop engine.rs parity —
         *    the old mark-at-fetch is what left DMs delivered-but-invisible).
         */
        suspend fun routeMailboxEntry(circleId: String, key: String, env: ByteArray): Boolean {
            when {
                key.contains("/__hello__/") -> {
                    val parts = key.split("/")
                    val i = parts.indexOf("__hello__")
                    val toShort = if (i >= 0 && parts.size > i + 1) parts[i + 1].take(8) else "?"
                    val fromShort = if (i >= 0 && parts.size > i + 2) parts[i + 2].take(8) else "?"
                    if (!helloSlotIsMine(key)) {
                        // Belt-and-suspenders for envelopes that reached here through an older
                        // fetch path — the poll loops below skip these before the GET.
                        Log.i(TAG, "hello claim SKIPPED (addressed to $toShort, not me) from=$fromShort circle=${circleId.take(12)}")
                        return false
                    }
                    val outcome = handleHello(env, viaNearby = false, senderDevice = null)
                    // The claim decision, visible: consumed slots are marked seen, held ones retry.
                    Log.i(TAG, "hello claim ${if (outcome.consumed) "CONSUMED" else "HELD"} (${outcome.why}) from=$fromShort to=$toShort circle=${circleId.take(12)}")
                    return outcome.consumed
                }
                key.contains("/__relay__/") -> {
                    handleRelayNode(env)
                    return true
                }
                else -> {
                    if (ingestMailboxEnv(circleId, env)) { changed = true; return true }
                    // Duplicate (nothing changed), BUFFERED durably in pending_epoch (persisted
                    // below — receiveRan), or garbage that identical bytes can never improve: mark
                    // seen either way. Leaving false-returns unseen re-fetched and re-decrypted the
                    // same envelopes on every poll forever once slot convergence made re-applied
                    // key commits honest no-ops (the instant-beachball / 6 GB relay-hosting Mac).
                    return true
                }
            }
        }
        // S3 pre-signed pools (the BYO-bucket path).
        for (circleId in Presign.circles()) {
            val items = runCatching { Presign.poll(circleId, seenMailbox) }.getOrDefault(emptyList())
            if (items.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
            for ((key, env) in items.sortedBy { mailboxKeyRank(it.first) }) {
                if (key.contains("/__live__/")) continue   // call frames — the in-call poll's lane
                if (!helloSlotIsMine(key)) continue         // another id's hello slot — not ours to claim (or burn)
                if (routeMailboxEntry(circleId, key, env)) pendingSeenMarks.add(key)
            }
        }
        // (circleId, relayNodeHex) for every circle × every configured relay — reading from all of
        // them means a message present on ANY reachable relay still arrives. seenMailbox is keyed
        // by the content-addressed key, so the same envelope mirrored on several relays is
        // ingested exactly once (dedup by content key).
        val relayTargets: List<Pair<String, String>> = relayNodes.toMap()
            .flatMap { (cid, list) -> list.filter { isRelayActive(it) }.map { cid to it } }
            .let { base ->
                // The all-circles default applies to every circle that hasn't already listed it.
                val def = defaultRelayHex
                if (def.isNotEmpty() && isRelayActive(def)) {
                    val extra = relayNodes.keys.filter { cid -> base.none { it.first == cid && it.second == def } }
                        .map { it to def }
                    base + extra
                } else base
            }
            .let { base ->
                // Circles the ENGINE holds but no relay announce / synced circle record has wired
                // yet — a fresh selfsync-learned circle whose winning record carried an EMPTY relay
                // list. Un-polled they stay content-less forever (the linked-device receive gap that
                // matches the upload gap above), so read them from every ACTIVE relay this device
                // knows. Ephemeral by design: relayNodes only ever learns real associations from
                // announces/sync, never these fallback guesses. Symmetric with uploadEvent + desktop
                // engine.rs poll_mailbox.
                val actives = allActiveRelayHexes().filter { !it.startsWith("s3:") }
                if (actives.isEmpty()) base
                else {
                    val engineCircles = runCatching { social.circles().map { it.id } }.getOrDefault(emptyList())
                    val extra = engineCircles
                        .filter { cid -> !relayNodes.containsKey(cid) }
                        .flatMap { cid -> actives.map { cid to it } }
                    base + extra
                }
            }
        for ((circleId, nodeHex) in relayTargets) {
            // S3-bucket relay: LIST + GET via the direct S3 FFI (store-and-forward poll).
            if (nodeHex.startsWith("s3:")) {
                val cfg = StorageStore.s3Config(appContext) ?: continue
                val prefix = "haven/mailbox/$circleId/"
                val keys = runCatching { uniffi.haven_ffi.s3List(cfg, prefix) }.getOrNull() ?: continue
                markRelaySeen(nodeHex)
                if (keys.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
                // Control-plane first (hello → relay → content) — LIST order is a store walk, and
                // without the sort a cold device buffers content ahead of the commit that opens it.
                // `__live__` keys are unclaimed call frames — never content; fed to receive() they
                // fail every poll forever, so they stay out of the batch entirely (iOS parity).
                for (s3key in keys.sortedBy { mailboxKeyRank(it) }) {
                    if (s3key.contains("/__live__/")) continue
                    if (!helloSlotIsMine(s3key)) continue   // another id's hello slot — skip before the GET
                    if (seenMailbox.contains(s3key)) continue
                    val env = runCatching { uniffi.haven_ffi.s3Get(cfg, s3key) }.getOrNull() ?: continue
                    if (routeMailboxEntry(circleId, s3key, env)) pendingSeenMarks.add(s3key)
                }
                continue
            }
            val prefix = "haven/mailbox/$circleId/"
            val client = relayClientFor(nodeHex)
            var keys: List<String>? = null
            var httpBase: String? = null
            if (client != null) {
                keys = runCatching { client.list(prefix) }.getOrNull()
                if (keys == null) relayFailed(nodeHex)
                else {
                    markRelayOk(nodeHex)
                    // We reached this relay over iroh but may hold no usable HTTP interface for
                    // it — exactly the state a restarted CLI relay (rotated free-tunnel URL)
                    // leaves every client in, where mailbox flows and MEDIA silently dies (the
                    // blob dial drops cross-NAT). Fetch its self-published interface and adopt +
                    // re-announce (guarded + throttled inside; no-op while HTTP works).
                    refreshRelayInterfaceIfNeeded(nodeHex)
                }
            }
            // iroh unreachable (dial backoff / no addressing — emulator NAT, CGNAT both ends) →
            // the relay's signed-HTTP interface, the reliable cross-NAT path. Without this rung
            // store-and-forward CONTENT only ever rode the dial, so an HTTP-only device polled
            // "successfully" forever while its mailbox sat full on the relay (iOS pullMailbox
            // parity — same ladder as devroster/media/`__live__`).
            val entry = relayEntries[nodeHex]
            if (keys == null && entry != null && entry.httpToken.isNotEmpty()) {
                for (base in httpUrlsFor(entry)) {
                    val r = relayHttpListDelta(base, entry.httpToken, prefix, digest = null)
                    if (r.isSuccess) {
                        keys = r.getOrNull()?.first ?: emptyList()
                        httpBase = base
                        markRelaySeen(nodeHex)
                        Log.d(TAG, "mailbox http-list ${keys.size} keys circle=${circleId.take(12)} via $base")
                        break
                    }
                    if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "mailbox list"); break }
                    Log.d(TAG, "mailbox http-list failed via $base: ${r.exceptionOrNull()?.message}")
                    markHttpUrlBad(base)
                }
            }
            if (keys == null) continue
            if (keys.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
            // Same shape as the S3 branch: skip unclaimed live-call frames, control-plane first,
            // and mark a content key seen ONLY once its envelope actually ingested.
            for (key in keys.sortedBy { mailboxKeyRank(it) }) {
                if (key.contains("/__live__/")) continue
                if (!helloSlotIsMine(key)) continue   // another id's hello slot — skip before the GET
                if (seenMailbox.contains(key)) continue
                val env = (if (httpBase != null) relayHttpGet(httpBase, entry!!.httpToken, key).getOrNull()
                           else runCatching { client!!.get(key) }.getOrNull()) ?: continue
                if (routeMailboxEntry(circleId, key, env)) pendingSeenMarks.add(key)
            }
        }
        // HTTP live-lane call frames when iroh dial is down.
        if (pollLiveCallFrames()) {
            changed = true
            bumpActivity()
        }
        // Mesh: if we host a relay, pull from each adopted sibling so the mailbox self-replicates.
        meshSync()
        // Multi-device self-sync: converge this user's OWN devices (profile/settings/contacts/
        // blocked/circles) over the same relays. Has its own transport + in-flight guard, and a
        // refresh trigger (selfSyncDidApply) when a peer device's state arrives.
        runCatching { SelfSyncCoordinator.sync(social) }
        // Persist whenever ANY receive ran — even a "nothing changed" pass may have buffered
        // envelopes into pending_epoch, and those buffers must survive process death.
        if (receiveRan && !changed) persist()
        if (changed) {
            // Fan out friend content that only this device pulled from the mailbox.
            if (newlyIngested.isNotEmpty()) {
                liveDeliverManyToMyDevices(
                    Wire.EVENT,
                    newlyIngested.map { (cid, env) -> Wire.eventPayload(cid, env) },
                )
                if (NearbyTransport.active) {
                    for ((cid, env) in newlyIngested) {
                        NearbyTransport.broadcast(Wire.frame(Wire.EVENT, Wire.eventPayload(cid, env)))
                    }
                }
                // Multi-device: a silent content-available push carries each envelope to my OWN
                // other devices' tokens, so a pocketed sibling ingests without waiting out its
                // next mailbox poll (Apple PushManager.syncSelf parity).
                for ((_, env) in newlyIngested.take(20)) pushSyncSelf(env)
            }
            bumpActivity()   // a message arrived → keep sync tight while the conversation is live
            persist()
            withContext(Dispatchers.Main) { feedVersion.value++ }
            requestMissingMedia()
            ActivityStore.poke(social)   // fresh rows for the bell without a per-envelope reduce
        }
        // Seen-marks STRICTLY AFTER whichever persist() above landed the engine state (iOS
        // parity). Marking inline put the seen file ahead of the engine save; a kill in that gap
        // durably marked keys whose events -- including friends' KEY COMMITS -- never landed, and
        // all content beneath the push layer went dark fleet-wide.
        for (k in pendingSeenMarks) markMailboxSeen(k)
        pendingSeenMarks.clear()
    }

    private val pendingSeenMarks = mutableListOf<String>()

    // ---- Cross-device media bytes (frame 3 request / frame 5 sealed chunks), like iOS ----

    // 32KB chunks transmit reliably over a slow BLE-only nearby link (larger frames overflowed the
    // reliable-send buffer and were silently dropped, so own-device media never arrived). iOS parity.
    private val mediaChunkSize = 32 * 1024

    /** A transfer in progress. Chunks live POSITIONALLY in [part] (seek to index × chunkSize), never
     *  in RAM: the old HashMap<Int, ByteArray> cost ~3× the media size to finish and had an OOM guard
     *  that SILENTLY DROPPED anything over a quarter of the heap, so a big video on a small phone
     *  could never arrive at all. [got] is the bitmap of what's landed, mirrored to [ReassemblyStore]
     *  so a 99%-complete transfer resumes after a restart instead of going back to chunk 0. */
    private class IncomingMedia(val part: java.io.File, val total: Int) { val got = HashSet<Int>() }

    /** Reassembly state, GUARDED BY [incomingLock]. Inbound frames are handled on Dispatchers.IO, so
     *  several threads touch this at once; the neighbouring maps here predate that realization and are
     *  still bare (see the note in [shouldServeNearby]). */
    private val incomingMedia = HashMap<String, IncomingMedia>()
    private val incomingLock = Any()
    /** Refs with a frame-33 fallback timer already armed — one per ref, never one per inbound request,
     *  so a peer cannot make us spawn coroutines. Guarded by [incomingLock]. */
    private val resumeFallbackPending = HashSet<String>()
    private val requestedRefs = HashSet<String>()
    private val mediaReqAt = HashMap<String, Long>()   // ref -> last direct-request ms (5-min throttle)
    private val servedAt = HashMap<String, Long>()      // ref -> last nearby-serve ms (25s rate-limit)
    private val pushedNearby = HashSet<String>()        // refs already pushed to nearby siblings this session

    private fun mediaKey(ref: String) = "haven/media/$ref"
    // Chunks live in a SIBLING dir "<ref>.p/", not nested under the manifest key "haven/media/<ref>":
    // a disk relay maps each key segment to a directory, so "<ref>/<i>" would force "<ref>" to be both a
    // manifest FILE and a chunk DIRECTORY (a collision that fails the manifest write). "<ref>.p" is distinct.
    private fun mediaChunkKey(ref: String, i: Int) = "haven/media/$ref.p/$i"

    // ---- Chunked media transfer (large-blob fix) -----------------------------------------------
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB (core/haven-net). Large sealed videos (600 MB+)
    // stored as ONE blob under "haven/media/<ref>" exceed that → a GET truncates and the receiver can't
    // play them (photos, ~5 MB, worked). Fix: slice the SEALED bytes into 8 MB chunks under
    // "haven/media/<ref>/<i>" and store a tiny manifest under "haven/media/<ref>". Download fetches
    // chunks IN ORDER and appends to a temp file on disk (streaming — never the whole blob in RAM).
    // Small media (<= one chunk) stays a single sealed blob (no manifest) for back-compat. The format is
    // BYTE-IDENTICAL to iOS/macOS + desktop (same 8 MB size, key scheme, and manifest bytes).
    private val mediaChunkBytes = MediaUploadPlan.CHUNK_BYTES   // 8 MB — under MAX_BLOB, memory-safe
    // 9-byte ASCII magic marking a manifest. A sealed envelope is JSON starting with '{', so no collision.
    private val manifestMagic = "HVCHUNK1\n".toByteArray(Charsets.US_ASCII)

    private fun makeManifest(sizes: List<Int>): ByteArray {
        val json = org.json.JSONObject()
            .put("v", 1).put("chunks", sizes.size).put("total", sizes.sum())
            .put("sizes", org.json.JSONArray(sizes))
        return manifestMagic + json.toString().toByteArray(Charsets.UTF_8)
    }
    /**
     * True when a destination holds a COMPLETE copy of [ref] — every chunk, not merely the manifest.
     *
     * A probe that asks only "is `haven/media/<ref>` there?" cannot tell a finished upload from a
     * manifest stranded over a partial chunk set, and answering yes to the second is PERMANENT: the
     * ref goes into the backup ledger ([markBackedUp]), no later pass revisits it, and the missing
     * windows are never sent again. Readers then stall on the same absent chunk on every retry until
     * the post gives up as "no longer available", while this device goes on showing it as safely
     * backed up. Field case (Apple, 2026-08-07): a 5-chunk video whose relay copy held chunks 0–2,
     * stuck for days with the original sitting on the author's other device.
     *
     * [head] is whatever the destination returned for the manifest key; null = it holds nothing. A
     * non-manifest head means a small unchunked blob, whose presence IS completeness.
     *
     * Otherwise probe the LAST window only. An upload that dies partway leaves a TAIL of missing
     * chunks, so one probe catches that whole class at O(1) instead of N round-trips against a
     * 137-window video. Mirror of iOS `SharedStore.holdsCompleteBlob`; the relay-side guarantee that
     * mesh replication never CREATES a mid-blob hole lives in `haven-net::pull_missing_from_peer`.
     */
    private suspend fun holdsCompleteBlob(ref: String, head: ByteArray?, has: suspend (String) -> Boolean): Boolean {
        if (head == null) return false
        val chunks = parseManifest(head) ?: return true
        return has(mediaChunkKey(ref, chunks - 1))
    }

    /** If [blob] is a chunk manifest, return its chunk count; else null (legacy/small single blob). */
    private fun parseManifest(blob: ByteArray): Int? {
        if (blob.size <= manifestMagic.size) return null
        for (i in manifestMagic.indices) if (blob[i] != manifestMagic[i]) return null
        return runCatching {
            val body = String(blob, manifestMagic.size, blob.size - manifestMagic.size, Charsets.UTF_8)
            org.json.JSONObject(body).getInt("chunks").takeIf { it > 0 }
        }.getOrNull()
    }

    // ---- Serial media-transfer queue (OOM guard) ------------------------------------------------
    // Backups (uploadMedia) and relay restores (fetchMediaFromRelay) each load a FULL media blob
    // into memory (sealed bytes; backup also seals a copy → ~2×). These used to be fired one
    // coroutine PER media ref (restore: requestMissingMedia) and from many concurrent backfill sites
    // (backup), so once a device held a lot of media — own-device media sync now backfills the whole
    // library — HUNDREDS of full blobs loaded into RAM at once. On iOS that hit ~3.4 GB → jetsam; on
    // the far-smaller-RAM Android targets it OOM-crashes worse. Route EVERY media transfer through a
    // single serial consumer so peak memory is ~one blob, not the whole library. Mirrors iOS
    // SharedStore.MediaBackupQueue (enqueue(ref, circleId); one drain loop runs them one at a time).
    private sealed class MediaJob(val ref: String, val circleId: String) {
        /** [priority] = a just-authored event's media (drained ahead of any backfill backlog);
         *  [atMs] = when it was enqueued, so a landed PRIORITY blob that is still fresh announces
         *  itself to the circle (frame 32) instead of waiting out everyone's missing-media sweep. */
        class Backup(ref: String, circleId: String, val force: Boolean = false,
                     val priority: Boolean = false, val atMs: Long = 0L) : MediaJob(ref, circleId)
        class Restore(ref: String, circleId: String) : MediaJob(ref, circleId)
    }
    // Unlimited buffer + a single consumer = strictly serial; the dedup set + cap below bound it.
    // The priority channel is drained FIRST: without it a fresh story's blob queued behind a long
    // historical backfill and friends saw the post minutes before its media could possibly land.
    private val mediaQueue = Channel<MediaJob>(Channel.UNLIMITED)
    private val mediaPriorityQueue = Channel<MediaJob>(Channel.UNLIMITED)
    private val mediaQueueKeys = LinkedHashSet<String>()   // in-flight/pending de-dup ("B|ref|cid" / "R|ref|cid")
    private val mediaQueueLock = Any()
    @Volatile private var mediaQueueStarted = false

    /** Start the single drain coroutine that processes media transfers one blob at a time. */
    private fun ensureMediaQueueDraining() {
        if (mediaQueueStarted) return
        synchronized(mediaQueueLock) {
            if (mediaQueueStarted) return
            mediaQueueStarted = true
        }
        scope.launch {
            while (true) {
                // Strict priority: exhaust the just-authored lane before touching the backlog.
                val job = mediaPriorityQueue.tryReceive().getOrNull()
                    ?: kotlinx.coroutines.selects.select {
                        mediaPriorityQueue.onReceive { it }
                        mediaQueue.onReceive { it }
                    }
                val key = jobKey(job)
                // Process ONE blob at a time — peak memory ≈ a single media file, not the library.
                runCatching {
                    when (job) {
                        is MediaJob.Backup -> {
                            // Retry-until-confirmed: only DROP the durable pending entry once the blob has
                            // actually landed on a relay. A failed pass leaves it persisted, so the next
                            // start / background sync / 2-min backfill retries it — the media reaches a
                            // relay even if the app was killed the instant after the post was made.
                            val landed = uploadMedia(job.circleId, job.ref, job.force)
                            if (landed && !job.force) {
                                clearPendingBackup(job.ref, job.circleId)
                                // A FRESH post's blob just landed on a relay — tell the circle so their
                                // devices prefetch NOW instead of on their next missing-media sweep
                                // (frame 32; Apple MediaBackupQueue drain parity).
                                if (job.priority && job.atMs > 0 &&
                                    System.currentTimeMillis() - job.atMs < 600_000) {
                                    announceMediaLanded(job.ref, job.circleId)
                                }
                            }
                        }
                        is MediaJob.Restore -> {
                            // A relay REFUSED us rather than lacking the blob: publish our device roster
                            // to it and try once more. Without this the fetch degrades to a peer ask that
                            // only works while the author happens to be online — which is exactly how
                            // media a few days old became permanently unreachable while fresh media
                            // (author still around) looked fine.
                            val got = (fetchMediaFromRelay(job.circleId, job.ref) ||
                                (healForbiddenRelays() && fetchMediaFromRelay(job.circleId, job.ref))) &&
                                acceptFetchedBlob(job.ref, job.circleId)
                            if (got) {
                                mediaArrived(job.ref)
                                withContext(Dispatchers.Main) { feedVersion.value++ }
                            }
                        }
                    }
                }
                synchronized(mediaQueueLock) { mediaQueueKeys.remove(key) }
            }
        }
    }

    private fun jobKey(job: MediaJob) =
        (if (job is MediaJob.Backup) (if (job.force) "BF|" else "B|") else "R|") + job.ref + "|" + job.circleId

    /** Enqueue a media blob to mirror to the circle's relays — serialized (one in RAM at a time).
     *  [force] = the 1.0.8 recovery overwrite (bypass the "already held?" probe + ledger).
     *  [priority] = just-authored media — rides the fast lane ahead of any backfill backlog and
     *  announces itself to the circle the moment it lands (frame 32). */
    private fun enqueueBackup(circleId: String, ref: String, force: Boolean = false, priority: Boolean = false) {
        if (LocalMedia.isSynthetic(ref)) return   // geo: pins et al. carry no bytes — never relay-storable
        // Record the job DURABLY before the in-memory Channel enqueue, so a story's blob still reaches a
        // relay even if the app is killed the instant after posting. The Channel (mediaQueue) is
        // in-memory only; without this persisted list, a backup enqueued but not yet drained was lost on
        // app kill and — since posting a story and immediately locking the phone is the whole point of a
        // story — the envelope reached the relay (viewers saw the story) but the blob never did. The
        // recovery-overwrite path (force) isn't persisted here: it has its own sticky latch
        // (mediaResealRefs) and must not resurrect across launches once done.
        if (!force) addPendingBackup(ref, circleId)
        val job = MediaJob.Backup(ref, circleId, force, priority,
            atMs = if (priority) System.currentTimeMillis() else 0L)
        if (!offerMediaJob(jobKey(job))) return
        ensureMediaQueueDraining()
        (if (priority) mediaPriorityQueue else mediaQueue).trySend(job)
    }

    /** Enqueue a missing media blob to fetch from the circle's relays — serialized (one at a time). */
    private fun enqueueRestore(circleId: String, ref: String) {
        if (LocalMedia.isSynthetic(ref)) return   // geo: pins et al. carry no bytes — nothing to fetch
        val job = MediaJob.Restore(ref, circleId)
        if (!offerMediaJob(jobKey(job))) return
        ensureMediaQueueDraining()
        mediaQueue.trySend(job)
    }

    /** Returns true if [key] is newly accepted (dedup + bounded so the queue can't grow unbounded). */
    private fun offerMediaJob(key: String): Boolean = synchronized(mediaQueueLock) {
        if (!mediaQueueKeys.add(key)) return false   // already pending/in-flight → drop duplicate
        // Bound the in-flight set itself: forget the oldest keys past the cap. Their jobs still drain
        // (the Channel is the source of truth); we only stop deduping ancient refs to cap this set.
        while (mediaQueueKeys.size > 20_000) {
            val it = mediaQueueKeys.iterator(); it.next(); it.remove()
        }
        true
    }

    // ---- Durable media-backup queue -------------------------------------------------------------
    // The in-memory Channel (mediaQueue) above serializes uploads for the OOM guard, but it does NOT
    // survive the process. This set persists the "still needs to reach a relay" jobs to
    // SharedPreferences so a blob mid-upload when the app was killed is retried on the next start /
    // background sync, and a failed upload is retried rather than dropped (a job is cleared ONLY once
    // uploadMedia confirms it landed on a relay). Keyed "ref|cid". Mirrors iOS SharedStore.
    // MediaBackupQueue (persisted queue + drainPersisted + retry-until-confirmed).
    private val pendingBackups = LinkedHashSet<String>()
    private var pendingBackupsLoaded = false
    private val pendingBackupsLock = Any()
    private fun pbKey(ref: String, cid: String) = "$ref|$cid"
    private fun pendingBackupPrefs() = appContext.getSharedPreferences("haven.mediabackup.queue", Context.MODE_PRIVATE)
    private fun ensurePendingBackups() {
        if (pendingBackupsLoaded) return
        synchronized(pendingBackupsLock) {
            if (pendingBackupsLoaded) return
            runCatching { pendingBackups.addAll(pendingBackupPrefs().getStringSet("pending", emptySet()) ?: emptySet()) }
            pendingBackupsLoaded = true
        }
    }
    private fun savePendingBackupsLocked() {
        runCatching { pendingBackupPrefs().edit().putStringSet("pending", HashSet(pendingBackups)).apply() }
    }
    private fun addPendingBackup(ref: String, cid: String) {
        ensurePendingBackups()
        synchronized(pendingBackupsLock) {
            if (pendingBackups.add(pbKey(ref, cid))) {
                while (pendingBackups.size > 10_000) { val it = pendingBackups.iterator(); it.next(); it.remove() }
                savePendingBackupsLocked()
            }
        }
    }
    private fun clearPendingBackup(ref: String, cid: String) {
        ensurePendingBackups()
        synchronized(pendingBackupsLock) {
            if (pendingBackups.remove(pbKey(ref, cid))) savePendingBackupsLocked()
        }
    }

    /** Whether a specific blob is still waiting to reach a relay — drives the per-post upload indicator. */
    fun hasPendingBackup(ref: String): Boolean {
        ensurePendingBackups()
        return synchronized(pendingBackupsLock) { pendingBackups.any { it.substringBeforeLast('|') == ref } }
    }

    /** Re-enqueue every backup persisted from a prior session — called on start and from the background
     *  SyncWorker so media that was mid-upload when the app was killed still reaches a relay. Idempotent:
     *  offerMediaJob de-dups, and uploadMedia skips anything the ledger already confirms. */
    fun drainPersistedBackups() {
        ensurePendingBackups()
        val jobs = synchronized(pendingBackupsLock) { pendingBackups.toList() }
        for (k in jobs) {
            val ref = k.substringBeforeLast('|'); val cid = k.substringAfterLast('|')
            if (ref.isNotEmpty() && cid.isNotEmpty()) enqueueBackup(cid, ref)
        }
    }

    /** True once a blob is confirmed on at least one relay/S3 destination (any dest — the post
     *  indicator only cares THAT it durably landed, not where). Public accessor over the backup ledger,
     *  mirroring iOS MediaBackupLedger.hasAny. */
    fun isMediaBackedUpAny(ref: String): Boolean {
        ensureLedger()
        return backedUp.any { it.substringAfterLast('|') == ref }
    }

    /** The node id of the relay THIS device is hosting in-process, or "" when we host none. */
    fun ownHostedRelayHex(): String = runCatching { relayHost?.nodeIdHex() }.getOrNull().orEmpty()

    /**
     * Confirmed somewhere a DIFFERENT DEVICE can read it — what "backed up" should have meant.
     *
     * [isMediaBackedUpAny] counts our own in-process relay, and writing to that is a LOCAL FILE COPY:
     * it never crosses the network and cannot fail. So a post whose media only ever reached this
     * device's own relay showed a confident "backed up" tick while no one else could fetch it — a
     * user watching checked icons on every post while their friends saw nothing. An indicator that
     * cannot distinguish "safe" from "only I have it" is worse than none: it is why the failure went
     * unnoticed for hours.
     *
     * Our own relay is excluded even though it MAY be reachable by others (LAN, or a public URL),
     * because we cannot tell from here — and the honest failure is to under-claim, not over-claim.
     * iOS `MediaBackupLedger.hasAnyRemote` parity.
     */
    fun isMediaBackedUpRemote(ref: String, ownRelayHex: String): Boolean {
        ensureLedger()
        return backedUp.any { it.substringAfterLast('|') == ref && it.substringBeforeLast('|') != ownRelayHex }
    }

    /** Whether a circle has any relay (or S3) to back media up to — the gate for showing the indicator. */
    fun circleHasRelay(circleId: String): Boolean = mediaRelaysFor(circleId).isNotEmpty()

    /** Every destination confirmed to hold [ref]. iOS `MediaBackupLedger.destinations` parity. */
    fun mediaBackupDestinations(ref: String): List<String> {
        ensureLedger()
        return backedUp.filter { it.substringAfterLast('|') == ref }
            .map { it.substringBeforeLast('|') }
            .distinct()
    }

    /** The relays this circle publishes to — the other half of the which-relays-hold-this answer.
     *  A circle relay holding NOTHING is the case you most need to see, and a list of confirmations
     *  alone can never show it. */
    fun circleRelayHexes(circleId: String): List<String> = mediaRelaysFor(circleId)

    /** A relay's friendly name, or "" when this device holds no entry for it. */
    fun relayName(hex: String): String = relayEntries[hex]?.name.orEmpty()

    // ---- Media GC (purge-linked deletion + orphan sweep) -------------------------------------
    // `feed()` only HIDES expired posts; `purgeExpired` really drops the events and returns their
    // media refs so the blobs (sealed store + decrypted playback caches) finally leave disk too.
    // Deletion is gated on an in-use check — the same photo may ride another live post (any circle,
    // DMs included), a comment, or a scheduled send, and those keep their bytes.

    /** Circles already purged this app session (purging is idempotent; once per session is plenty). */
    private val purgedMediaCircles = mutableSetOf<String>()

    /** Really delete expired content for a circle and GC the blobs the purge orphaned. Call from the
     *  feed/messages display paths — throttled to once per circle per app session so recompositions
     *  never re-run engine purges. */
    fun maybePurgeExpiredMedia(circleId: String) {
        if (!ready) return
        synchronized(purgedMediaCircles) { if (!purgedMediaCircles.add(circleId)) return }
        scope.launch {
            val purged = runCatching {
                social.purgeExpired(circleId, CircleSettings.retentionSecs(circleId), nowMs())
            }.getOrDefault(emptyList())
            if (purged.isEmpty()) return@launch
            // Persist FIRST: once the blobs are gone, the purged events must not resurrect from a
            // stale state file and re-request their (now deleted) media forever.
            persist()
            // Built AFTER the purge, so this circle's dropped events no longer count as users.
            val inUse = mediaInUseKeys()
            var freed = 0L
            for (ref in purged) {
                if (LocalMedia.isSynthetic(ref)) continue
                if (LocalMedia.normalizedKeys(ref).none { it in inUse }) freed += LocalMedia.delete(ref)
            }
            if (freed > 0) Log.i("MediaGC", "purge $circleId: freed ${freed}B")
        }
    }

    /** Every on-disk key a live event still references: every circle's feed (retention null —
     *  expired-but-unpurged events keep their bytes until purged) + every comment + scheduled sends.
     *  Blocking (feed() re-opens every envelope) — call off the main thread. */
    private fun mediaInUseKeys(): Set<String> {
        val keys = HashSet<String>()
        fun add(r: String) { if (!LocalMedia.isSynthetic(r)) keys.addAll(LocalMedia.normalizedKeys(r)) }
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            val feed = runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())
            for (item in feed) {
                item.media.forEach(::add)
                item.comments.forEach { cm -> cm.media.forEach(::add) }
            }
        }
        ScheduledStore.items.forEach { it.media.forEach(::add) }
        // Device-pinned blobs are cleanup-exempt regardless of referencedness — union their on-disk
        // keys so the orphan sweep + purge GC never delete a "kept" blob. MUST stay in lockstep with
        // the limit-sweep skip-set in enforceLocalLimits (both take PinnedMediaStore.inUseKeys()).
        keys.addAll(PinnedMediaStore.inUseKeys())
        return keys
    }

    /** Delete every stored blob no event anywhere references (Settings' "Clean up unused media" and
     *  the weekly sweep). Blocking — call off the main thread. Returns (bytesFreed, filesRemoved). */
    fun cleanupUnusedMedia(): Pair<Long, Int> {
        if (!ready) return 0L to 0
        // Expire abandoned partials FIRST (24h of no progress, part file included) so the sweep sees
        // them as plain orphans, then spare the ones still live — a 99%-complete download waiting for
        // its last chunk is not leaked scratch, and deleting it is what made large media restart forever.
        runCatching { ReassemblyStore.prune() }
        val result = LocalMedia.sweepOrphans(
            mediaInUseKeys(),
            liveParts = runCatching { ReassemblyStore.liveParts() }.getOrDefault(emptyMap()),
        )
        if (result.second > 0) Log.i("MediaGC", "sweep: freed ${result.first}B across ${result.second} files")
        return result
    }

    private val gcPrefs get() = appContext.getSharedPreferences("haven.mediagc", Context.MODE_PRIVATE)
    @Volatile private var weeklySweepInFlight = false

    /** Run the orphan sweep at most once a week (persisted stamp), piggybacked on the sync loop. */
    private fun maybeWeeklyMediaSweep() {
        if (!ready || weeklySweepInFlight) return
        val last = gcPrefs.getLong("lastSweep", 0L)
        if (System.currentTimeMillis() - last < 7L * 24 * 3600 * 1000) return
        weeklySweepInFlight = true
        scope.launch {
            runCatching { cleanupUnusedMedia() }
            gcPrefs.edit().putLong("lastSweep", System.currentTimeMillis()).apply()
            weeklySweepInFlight = false
        }
    }

    // ---- Storage management: size-sorted inventory, device pins, local caps, on-demand refetch ----
    // Mirrors iOS FeedStore.mediaInventory / deleteSelectedMedia / enforceLocalLimits / downloadEvicted.

    /** One row of the "Manage media" screen: a stored blob, its size, and the post/DM/comment it
     *  belongs to (best-effort). [orphan] = no live event references it (free to delete). [pinned] =
     *  kept on this device, shown ineligible for cleanup. [circleId] backs the thumbnail decrypt. */
    data class MediaInventoryRow(
        val key: String,          // on-disk storage key — the delete/pin/thumbnail arg (a real ref or bare hash)
        val bytes: Long,
        val mtimeMs: Long,
        val isVideo: Boolean,
        val isAudio: Boolean,
        val circleId: String?,
        val circleName: String,
        val snippet: String?,
        val orphan: Boolean,
        val pinned: Boolean,
    )

    /** Every stored media blob, joined to the post/DM/comment that references it (best-effort), sorted
     *  by size DESCENDING for the "Manage media" screen. A blob no live event names is an ORPHAN
     *  ("Unused", or "Scheduled to send" if a queued post holds it). DM circle ids ("dm:") label
     *  "Direct message". Deleting a row here frees only local bytes — the event stays. Blocking. */
    fun mediaInventory(): List<MediaInventoryRow> {
        if (!ready) return emptyList()
        val circleNames = HashMap<String, String>()
        val scheduledKeys = HashSet<String>()
        ScheduledStore.items.forEach { it.media.forEach { r -> scheduledKeys.addAll(LocalMedia.normalizedKeys(r)) } }
        // key (on-disk storage key) -> owning event (first/newest wins).
        val owner = HashMap<String, Triple<String, String, Long>>()  // key -> (circleId, snippet, ts)
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            circleNames[c.id] = c.name
            val feed = runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())
            for (item in feed) {
                fun attribute(refs: List<String>, body: String, ts: ULong) {
                    val snip = body.take(80)
                    for (r in refs) for (k in LocalMedia.normalizedKeys(r)) if (!owner.containsKey(k)) {
                        owner[k] = Triple(c.id, snip, ts.toLong())
                    }
                }
                attribute(item.media, item.body, item.createdAt)
                item.comments.forEach { cm -> attribute(cm.media, cm.body, cm.createdAt) }
            }
        }
        return LocalMedia.storedBlobs().map { blob ->
            val isVideo = LocalMedia.isVideo(blob.key)
            val isAudio = LocalMedia.isAudio(blob.key)
            val pinned = PinnedMediaStore.isPinned(blob.key)
            val o = owner[blob.key]
            if (o != null) {
                val isDM = o.first.startsWith("dm:")
                MediaInventoryRow(
                    key = blob.key, bytes = blob.bytes, mtimeMs = blob.mtimeMs, isVideo = isVideo, isAudio = isAudio,
                    circleId = o.first,
                    circleName = if (isDM) "Direct message" else (circleNames[o.first] ?: "A circle"),
                    snippet = o.second.ifEmpty { null }, orphan = false, pinned = pinned,
                )
            } else {
                val scheduled = LocalMedia.normalizedKeys(blob.key).any { it in scheduledKeys }
                MediaInventoryRow(
                    key = blob.key, bytes = blob.bytes, mtimeMs = blob.mtimeMs, isVideo = isVideo, isAudio = isAudio,
                    circleId = null,
                    circleName = if (scheduled) "Scheduled to send" else "Unused",
                    snippet = null, orphan = !scheduled, pinned = pinned,
                )
            }
        }.sortedByDescending { it.bytes }
    }

    /** Delete the LOCAL blobs for these rows (the event/metadata stays). A key a live event still
     *  references is recorded in the evicted set with its size, so it renders as a "Download X MB"
     *  placeholder instead of being auto-refetched (that would undo the cleanup). Pinned rows are
     *  skipped. Returns freed bytes. Blocking — call off the main thread. */
    fun deleteSelectedMedia(rows: List<MediaInventoryRow>): Long {
        if (!ready) return 0L
        val inUse = mediaInUseKeys()
        var freed = 0L
        for (row in rows) {
            if (row.pinned) continue
            val referenced = LocalMedia.normalizedKeys(row.key).any { it in inUse }
            freed += LocalMedia.delete(row.key)
            if (referenced) EvictedMediaStore.mark(row.key, row.bytes)
        }
        return freed
    }

    // ---- Local limits (#4) — age/size caps ------------------------------------------------------
    @Volatile private var lastLimitSweepAt = 0L
    @Volatile private var limitSweepInFlight = false

    /** Enforce the device-local age/size caps (Settings ▸ Storage). Deletes local blobs (metadata stays
     *  → placeholder) oldest-first, skipping pinned + in-flight media. [force] bypasses the throttle
     *  (used when the setting changes). No-op when both caps are off. */
    fun enforceLocalLimits(force: Boolean = false) {
        if (!ready || limitSweepInFlight) return
        val maxDays = MediaLimits.maxDays
        val maxGB = MediaLimits.maxGB
        if (maxDays <= 0 && maxGB <= 0) return
        val nowMs = System.currentTimeMillis()
        if (!force && nowMs - lastLimitSweepAt < 600_000L) return   // at most every 10 min otherwise
        lastLimitSweepAt = nowMs
        limitSweepInFlight = true
        scope.launch {
            val r = runCatching {
                val pinnedKeys = PinnedMediaStore.inUseKeys()   // MUST mirror mediaInUseKeys' pin union
                val inUse = mediaInUseKeys()
                LocalMedia.performLimitSweep(maxDays, maxGB, pinnedKeys, inUse)
            }.getOrNull()
            limitSweepInFlight = false
            if (r != null && r.second > 0) {
                for ((key, bytes) in r.third) EvictedMediaStore.mark(key, bytes)
                Log.i("MediaGC", "limit sweep: freed ${r.first}B across ${r.second} files")
            }
        }
    }

    // ---- On-demand download of an evicted blob (#3) ---------------------------------------------

    /** Refs a Download tap is actively fetching, and refs the relay no longer has — drive the
     *  placeholder's spinner / "no longer available" states. Compose-observable. */
    val downloadingMedia = mutableStateListOf<String>()
    val unavailableMedia = mutableStateListOf<String>()

    /** Relays were reachable and NONE holds the blob — we're waiting on the SENDER's device to
     *  upload it. Drives the placeholder's honest "Waiting for sender…" state (Apple parity). */
    val waitingForSenderMedia = mutableStateListOf<String>()

    /** Chunk progress for large chunked relay restores (ref → done/total) — the placeholder's i/n. */
    val mediaRestoreProgress = androidx.compose.runtime.mutableStateMapOf<String, Pair<Int, Int>>()

    /** thumb companion learned from `thumb:` markers while scanning feeds (content ref → thumb ref)
     *  — how a placeholder six composables deep finds its blurred backdrop without the media list. */
    private val thumbOfContent = java.util.Collections.synchronizedMap(HashMap<String, String>())
    fun thumbRefFor(ref: String): String? = thumbOfContent[ref]

    /** The bytes for [ref] just landed — clear every transient placeholder state it held. */
    private fun mediaArrived(ref: String) {
        scope.launch(Dispatchers.Main) {
            downloadingMedia.remove(ref)
            waitingForSenderMedia.remove(ref)
            unavailableMedia.remove(ref)
            mediaRestoreProgress.remove(ref)
        }
        synchronized(fastReq) { fastReq.remove(ref) }
    }

    /** Relays answered and none holds it — an honest different truth from "downloading" (we
     *  aren't) and from "gone forever" (it never arrived anywhere). */
    private fun noteMediaMissingOnRelays(ref: String) {
        if (LocalMedia.has(ref)) return
        scope.launch(Dispatchers.Main) {
            if (!waitingForSenderMedia.contains(ref)) waitingForSenderMedia.add(ref)
        }
    }

    /** Honest progress for the placeholder: i/n while a chunked blob reassembles. */
    private fun noteRestoreProgress(ref: String, done: Int, total: Int) {
        scope.launch(Dispatchers.Main) {
            mediaRestoreProgress[ref] = done to total
            if (!downloadingMedia.contains(ref)) downloadingMedia.add(ref)   // a chunked pull IS a download
        }
    }

    private fun clearRestoreProgress(ref: String) {
        scope.launch(Dispatchers.Main) {
            mediaRestoreProgress.remove(ref)
            downloadingMedia.remove(ref)
        }
    }

    /** User tapped "Download" on a placeholder for a blob we deliberately evicted: clear the eviction
     *  (so the normal missing-media path may fetch it), request it now (relay restore + a direct peer
     *  ask), and surface a spinner. If it hasn't arrived in ~45s, mark it unavailable. */
    fun downloadEvicted(ref: String) {
        EvictedMediaStore.clear(ref)
        unavailableMedia.remove(ref)
        // A tap retry restarts every lane from the top: the fresh-lane schedule, the session
        // unopenable mark (the author may have re-sealed the stored copy since), and the waiting
        // state (Apple parity).
        waitingForSenderMedia.remove(ref)
        unopenableMedia.remove(ref)
        synchronized(fastReq) { fastReq.remove(ref) }
        if (LocalMedia.has(ref)) return
        if (!downloadingMedia.contains(ref)) downloadingMedia.add(ref)
        // Find the circle that references this ref (for the relay restore key + a scoped direct ask).
        val circleId = runCatching {
            social.circles().firstOrNull { c ->
                social.feed(c.id, nowMs(), null).any { item ->
                    item.media.contains(ref) || item.comments.any { it.media.contains(ref) }
                }
            }?.id
        }.getOrNull()
        if (circleId != null) enqueueRestore(circleId, ref)   // relay-first (mailbox → HTTP → S3 → iroh)
        // Direct peer ask (tiny frame, no blob in RAM) — same per-ref request requestMissingMedia makes.
        val payload = nodeIdHex.toByteArray(Charsets.UTF_8) + ref.toByteArray(Charsets.UTF_8)
        askForMedia(ref, payload, contacts.map { it.idHex })   // resumes from a partial when we hold one
        scope.launch {
            kotlinx.coroutines.delay(45_000)
            downloadingMedia.remove(ref)
            if (!LocalMedia.has(ref)) { if (!unavailableMedia.contains(ref)) unavailableMedia.add(ref) }
        }
    }

    // ---- Missing-media fetch lanes (fresh vs old; Apple FeedStore parity) -----------------------
    //
    // FRESH lane: refs referenced by events created < 5 min ago retry on a fast bounded backoff
    // (5s → 10s → 20s → 45s → 90s, then park) with their OWN 5s re-sweep — so a post's media drops
    // in seconds after the author's upload lands, instead of waiting out the flat 5-min throttle.
    // The fresh state is in-memory: freshness itself expires in minutes.
    private val FRESH_EVENT_MS = 5 * 60_000L
    private val FAST_STEPS = longArrayOf(5_000, 10_000, 20_000, 45_000, 90_000)
    private val fastReq = HashMap<String, Pair<Int, Long>>()   // ref -> (attempts, dueMs)
    @Volatile private var fastSweepArmed = false

    /** Keep a 5s re-sweep alive exactly while fresh refs are still retrying. */
    private fun armFastMediaSweep() {
        if (fastSweepArmed) return
        fastSweepArmed = true
        scope.launch {
            delay(5_000)
            fastSweepArmed = false
            requestMissingMedia()
        }
    }

    /** Fetch missing feed media: try the circle relay (haven/media/<ref>) first, then ask contacts. */
    fun requestMissingMedia() {
        if (!ready) return
        // OFF-THREAD, always. requestMissingMedia is called from the main thread (foreground
        // resume, feed refresh), and an open-probe is real crypto over real bytes — on a mid-range
        // phone with a 167 MB blob that is a visible UI freeze. It also decrypts file→file for a
        // large blob, which is disk-bound on top. Nothing here needs to be synchronous.
        if (verifySweepDue()) scope.launch(Dispatchers.IO) { runCatching { verifyHeldMedia() } }
        val myHex = nodeIdHex
        val nowMs = System.currentTimeMillis()
        val now = nowMs()
        val missing = LinkedHashMap<String, Pair<String, Boolean>>()   // ref -> (circleId, fresh)
        val thumbs = LinkedHashMap<String, String>()   // thumb ref -> circleId (prefetched unconditionally)
        for (c in social.circles()) {
            val feed = runCatching { social.feed(c.id, now, null) }.getOrDefault(emptyList())
            for (item in feed) {
                // FRESH = the referencing event is < 5 min old — its media rides the fast lane.
                val fresh = now >= item.createdAt && (now - item.createdAt) < FRESH_EVENT_MS.toULong()
                // Skip synthetic refs (geo: location pins): they carry no fetchable bytes, so counting
                // them keeps the pending metric pinned above 0 forever and fires a doomed fetch each sweep.
                // Skip refs the user DELIBERATELY evicted ("Manage media" / local-limit sweep): auto-
                // refetching would silently undo the freed space. They re-download only on an explicit
                // "Download" tap (downloadEvicted clears the eviction first), and are excluded from the
                // pending metric too (never added to `missing`). Media never evicted still fetches.
                // Skip refs whose relay copy was found and could not be opened (acceptFetchedBlob):
                // re-fetching them just re-downloads the same unopenable bytes; only the author's
                // re-seal fixes them, and the set is dropped on restart so a repair is picked up.
                // [unopenableMedia] is deliberately NOT a gate here — it gates the RELAY half of the
                // fetch instead (see [enqueueRestore] below). The flag means "the stored copy we
                // downloaded could not be decrypted", which is a statement about a relay blob and
                // nothing else. Excluding the ref from the scan also silenced the PEER ask, which
                // travels a different lane under a different key (the account-derived own-media key)
                // and is frequently the one that works — so a relay copy sealed to a recipient set
                // we're not in would kill an own-device transfer that was actively succeeding,
                // mid-flight, with nothing left to re-ask. (Apple hit exactly that: a peer transfer
                // died at 823/1231 chunks the instant a relay copy failed to open.)
                fun consider(ref: String) {
                    if (LocalMedia.isSynthetic(ref) || LocalMedia.has(ref) ||
                        EvictedMediaStore.contains(ref)) return
                    val prior = missing[ref]
                    if (prior == null || (fresh && !prior.second)) missing[ref] = c.id to fresh
                }
                item.media.forEach { consider(it) }
                // Thumb companions: remember the pairing (feeds the blurred placeholder) and
                // prefetch for EVERY post regardless of lane/data saver — ≤32KB by contract.
                for (m in item.media) {
                    MediaVariants.parseThumb(m)?.let { (content, thumb) ->
                        thumbOfContent[content] = thumb
                        if (!LocalMedia.has(thumb) && !unopenableMedia.contains(thumb)) thumbs[thumb] = c.id
                    }
                    // POSTERS ride the same lane as thumbs — a poster is a small still, not a video.
                    // Left in the general `missing` map it queues behind full-size clips, so a video
                    // tile has no poster for as long as the backlog takes and falls back to
                    // generating one locally: expensive (a decode session per attempt) and pointless,
                    // because the sender already cut one and shipped it. iOS parity.
                    for (m in item.media) {
                        MediaVariants.parsePoster(m)?.let { (_, poster) ->
                            if (!LocalMedia.has(poster) && !unopenableMedia.contains(poster)) {
                                thumbs[poster] = c.id
                            }
                        }
                    }
                }
                item.comments.forEach { cm -> cm.media.forEach { consider(it) } }
            }
        }
        SyncMetrics.setPending(missing.size)   // media refs still missing locally (iOS nbMediaPending)
        // Per-circle breakdown. A whole-set count hid the thing that mattered: every ref in flight
        // belonged to `default` and not one came from a dm: circle, so DM media was never being
        // ASKED for — which looks identical to "DM media won't decrypt" from the outside.
        run {
            val byCircle = missing.values.groupingBy { it.first }.eachCount()
            val items = runCatching { social.circles() }.getOrDefault(emptyList()).associate { c ->
                c.id.take(24) to runCatching { social.feed(c.id, now, null) }.getOrDefault(emptyList())
                    .sumOf { it.media.size + it.comments.sumOf { cm -> cm.media.size } }
            }
            android.util.Log.i("MediaSync", "missing by circle=${byCircle.mapKeys { it.key.take(24) }} | mediaRefsInFeed=$items")
        }
        android.util.Log.i("MediaSync", "requestMissing missing=${missing.size} firstFew=${missing.keys.take(3)} defaultRelay=${defaultRelayHex.take(12)} relayNodes=${relayNodes.mapValues { it.value.map { n -> n.take(10) } }}")
        // THROTTLE: a missing ref used to be direct-requested from EVERY contact on every sweep, so a
        // backlog of missing media flooded the network with hundreds of thousands of frames per cycle
        // (drowning real delivery — the iOS flood bug). Direct-request each ref at most once per 5 min and
        // only a handful per cycle; the content-addressed relay/mailbox restore below is the real path and
        // is idempotent, so it carries the bulk without flooding. FRESH refs bypass the 5-min throttle on
        // their own bounded schedule (FAST_STEPS) — that is what makes media drop in WITH the post.
        var directBudget = 8
        var fastActive = false
        // ROUND-ROBIN ACROSS CIRCLES. `missing` is insertion-ordered, and the restore queue below is
        // SERIALIZED — one blob at a time — so whichever circle is enumerated first owns the queue.
        // In practice that was `default` with 45 refs, every one of them old media this device can
        // never open (it was not a recipient when they were sealed). They fail, get dropped, and are
        // re-added by the very next scan, so a DM's 2 refs sat behind a permanently doomed backlog
        // and were never requested at all. That is indistinguishable, from the outside, from "DM
        // media won't decrypt" — but nothing was ever fetched to decrypt.
        //
        // Interleaving by circle bounds the damage a stuck circle can do to the others: a backlog
        // still drains slowly, but it can no longer starve a conversation that is working fine.
        val byCircleQueues = missing.entries.groupBy { it.value.first }.values.map { it.toMutableList() }
        val ordered = ArrayList<Map.Entry<String, Pair<String, Boolean>>>(missing.size)
        var idx = 0
        while (ordered.size < missing.size) {
            var moved = false
            for (q in byCircleQueues) {
                if (idx < q.size) { ordered.add(q[idx]); moved = true }
            }
            if (!moved) break
            idx++
        }
        for ((ref, info) in ordered.map { it.key to it.value }) {
            val (circleId, fresh) = info
            if (fresh) {
                val st = synchronized(fastReq) { fastReq[ref] } ?: (0 to 0L)
                if (st.first >= FAST_STEPS.size) continue   // fast rounds spent — parked (ages into old lane)
                fastActive = true
                if (nowMs < st.second) continue             // not due yet
                synchronized(fastReq) {
                    fastReq[ref] = (st.first + 1) to (nowMs + FAST_STEPS[st.first])
                    if (fastReq.size > 500) fastReq.keys.retainAll(missing.keys)
                }
                // The relay half only for refs whose stored copy opened (or was never tried): re-pulling
                // a blob we already know we cannot decrypt repairs nothing and costs a full download
                // each sweep. The peer ask below always goes out — see `consider`.
                if (!unopenableMedia.contains(ref)) enqueueRestore(circleId, ref)
                requestedRefs.add(ref)
                val payload = myHex.toByteArray(Charsets.UTF_8) + ref.toByteArray(Charsets.UTF_8)
                askForMedia(ref, payload, contacts.map { it.idHex })
                continue
            }
            // SERIALIZED RESTORE: the relay fetch loads a FULL blob into RAM, so it goes through the
            // single media-transfer queue (one blob at a time) instead of one concurrent coroutine per
            // missing ref — which used to pull the whole library into memory at once and OOM-crash.
            if (!unopenableMedia.contains(ref)) enqueueRestore(circleId, ref)
            // AN ACTIVE PEER TRANSFER GETS A FASTER HEARTBEAT THAN THE 5-MINUTE COOLDOWN.
            //
            // That cooldown is sized for a ref nobody is sending: don't nag. A partial that is still
            // GROWING is the opposite case — the bytes are arriving, but a serve is ONE pass over the
            // file and then it ends, so the remainder only moves if we ask again. At five minutes a
            // large video crawls, and a pass that ends near the tail looks stopped entirely. (Apple:
            // a transfer sat at 1101/1231 with the sender online and holding the rest, because nothing
            // re-asked.) [askForMedia] upgrades to frame 33, so each heartbeat costs the sender only
            // the windows we still lack.
            val inFlight = synchronized(incomingLock) {
                incomingMedia[ref]?.let { it.got.isNotEmpty() && it.got.size < it.total } ?: false
            }
            val cooldown = if (inFlight) 10_000L else 300_000L
            val stale = (mediaReqAt[ref]?.let { nowMs - it > cooldown } ?: true)
            val allowDirect = stale && directBudget > 0
            if (!allowDirect) continue
            // Peer re-request (tiny frame, no blob in RAM) stays direct but throttled/budgeted so we
            // never flood; the content-addressed relay restore above is the real, memory-bounded path.
            mediaReqAt[ref] = nowMs; directBudget--
            requestedRefs.add(ref)
            val payload = myHex.toByteArray(Charsets.UTF_8) + ref.toByteArray(Charsets.UTF_8)
            askForMedia(ref, payload, contacts.map { it.idHex })   // resumes from a partial when we hold one
        }
        if (fastActive) armFastMediaSweep()
        // Thumbs: no lanes, no data-saver gate — they are what makes the loading placeholder look
        // like the photo. The restore queue's own dedup bounds the re-asks.
        for ((t, cid) in thumbs) enqueueRestore(cid, t)
        if (mediaReqAt.size > 4000) mediaReqAt.clear()   // bound the throttle map
    }

    /**
     * Relay order for MEDIA transfers: relays with a plain-HTTP interface FIRST (the DEFAULT
     * cross-NAT media transport), then S3 buckets (only present when the user configured one —
     * rare), then iroh-only relays. HTTP/S3 are plain HTTP(S) so they traverse ANY NAT; the iroh
     * blob ALPN (haven/blob/1) is kept as an opportunistic fast-path only: the noq/iroh fork drops
     * its outbound SendDatagram over a pure-relay (cross-NAT) path, so a blob dial that has to
     * cross a NAT stalls 30s and dies while messaging on the same relay path works. Stable sort.
     */
    // Relay node ids to MIRROR media to / FETCH media from — the circle's own relays PLUS every other
    // known ACTIVE relay. Media keys (haven/media/<ref>) are content-addressed AND permission-free on a
    // relay (unlike mailbox keys, which are circle-membership gated — a relay can ERR-forbid a device for
    // messages while still storing its media), so a blob may safely live on ANY relay the members can
    // reach. Broadening beyond the circle's own (possibly all-NAT'd) relays is what lands media when a
    // circle's relays are all offline/unreachable but some OTHER known relay is reachable — that relay
    // accepts the media even though it forbids the device's mailbox writes. Content-addressed keys make
    // the extra puts idempotent, unreachable relays fail fast + back off, and mesh anti-entropy replicates
    // the blob onto the circle's own relays once they return. allRelays() is already active-only. Mailbox/
    // message paths stay on relaysFor(circleId) — those keys ARE permission-gated. iOS SharedStore.mediaDests
    // parity (s3: pseudo-nodes are kept here because Android's upload/fetch handle them in-list).
    private fun mediaRelaysFor(circleId: String): List<String> {
        val nodes = LinkedHashSet<String>()
        nodes.addAll(relaysFor(circleId))
        nodes.addAll(allRelays())
        return nodes.sortedByDescending { hex ->
            when {
                // Rank on URLs we could actually USE (httpUrlsFor drops a LAN address we aren't on),
                // or an unreachable 192.168.x announce still sorts a relay to the front of the media
                // order and every operation pays its connect timeout before falling through to iroh.
                relayEntries[hex]?.let { httpUrlsFor(it).isNotEmpty() } == true -> 2
                hex.startsWith("s3:") -> 1
                else -> 0
            }
        }
    }

    // ---- Relay plain-HTTP media interface (client side) ------------------------------------------
    // GET/PUT against a relay's HTTP interface (see core httprelay.rs): `<base>/k/<key>`. Result
    // semantics: failure = URL unreachable (back it off + try the next URL), success(null) = relay
    // reached but doesn't hold the key (a real MISS — the iroh path serves the same store, so don't
    // bother dialing it for the same key).
    //
    // AUTHORIZATION: each request is SIGNED by this device's transport key rather than gated on a
    // shared bearer token. The relay verifies the signature to learn WHO is asking, then runs the
    // same circle-membership check as the iroh path. The frame-19 token is mixed into the signed
    // transcript instead of being sent, so it never crosses the wire.
    //
    // The seed MUST be the one HavenNode.start binds the transport to (DeviceKeyStore's per-device
    // seed), or the relay sees a node id in no roster and answers 403.

    private val httpUrlBad = HashMap<String, Long>()   // url -> retry-after epoch ms (2-min backoff)

    /**
     * The relay's usable HTTP URLs from where WE are — empty means "iroh-only", which is the honest
     * answer rather than a fast path that cannot work.
     *
     * PRIVATE addresses are dropped unless we are on that subnet ourselves. A relay hosted in the app
     * announces every LAN IPv4 it has, which is right for a member on the same network and useless to
     * everyone else — a `192.168.4.x` URL cannot be reached from a `10.0.0.x` network, ever. Those
     * URLs are tried FIRST anyway (HTTP is the preferred media path, see mediaRelaysFor), so every
     * remote member burned a connect attempt and a timeout per operation on an address that could
     * never work, then fell through to iroh in a worse state. In one 20-minute field window every
     * single media failure was this.
     *
     * It is also why the Dockerised NAS relay behaved better than the in-app relays: it announces no
     * HTTP interface at all, so callers go straight to the path that works. iOS
     * `RelayMailboxStore.httpInterface` parity.
     */
    private fun httpUrlsFor(e: RelayEntry): List<String> =
        if (e.httpToken.isEmpty()) emptyList()
        else e.httpUrls.filter { urlPlausiblyReachable(it) && (httpUrlBad[it] ?: 0L) < System.currentTimeMillis() }

    /** Is this URL worth trying from where we are? Public hosts always; a private address only when
     *  one of our own interfaces sits on the same /24. The rule itself lives in [RelayUrls] (pure +
     *  unit-tested); this only supplies where "here" currently is. */
    private fun urlPlausiblyReachable(url: String): Boolean =
        RelayUrls.plausiblyReachable(url, RelayUrls.prefixes(lanIPv4s()))
    private fun markHttpUrlBad(url: String) {
        httpUrlBad[url] = System.currentTimeMillis() + 120_000
        // The fabric filters on this same signal, so re-apply it now rather than waiting for the
        // next unrelated relay edit — this is the moment rendezvous should stop using a dead host.
        refreshHavenFabric()
    }

    private fun httpKeyUrl(base: String, key: String) = "${base.trimEnd('/')}/k/${android.net.Uri.encode(key, "/")}"

    /**
     * Sign ONE request. Never cache the result: it carries a timestamp, a one-shot nonce and a
     * digest of THIS body, so a reused header is a replay and the relay refuses it. `key` is the raw
     * (un-encoded) store key — the relay percent-decodes the path before it verifies.
     */
    private fun httpAuth(token: String, method: String, key: String, body: ByteArray): String? =
        runCatching {
            httpAuthHeader(DeviceKeyStore.deviceAccount().secretSeed(), token, method, key, body)
        }.getOrNull()

    /**
     * The relay REFUSED us — it is reachable and healthy, we are simply not (yet) a member it
     * recognizes. Distinct from a transport failure because the remedies are opposite: a broken
     * endpoint should be backed off, whereas a refusal should trigger a device-roster publish and a
     * retry. Folding the two together is what made a permissions problem present as MISSING media:
     * the 403 became a plain failure → markHttpUrlBad → the relay was skipped for two minutes → the
     * blob was reported as absent, while it sat on that relay's disk the whole time. iOS
     * SharedStore.RelayForbidden parity.
     */
    class RelayForbidden : java.io.IOException("relay refused (401/403)")

    private fun relayHttpGet(base: String, token: String, key: String): Result<ByteArray?> = runCatching {
        val auth = httpAuth(token, "GET", key, ByteArray(0)) ?: throw java.io.IOException("cannot sign relay GET")
        val c = (java.net.URL(httpKeyUrl(base, key)).openConnection() as java.net.HttpURLConnection).apply {
            connectTimeout = 4000; readTimeout = 60000
            setRequestProperty("Authorization", auth)
        }
        try {
            when (c.responseCode) {
                in 200..299 -> c.inputStream.use { it.readBytes() }
                404 -> null
                401, 403 -> throw RelayForbidden()
                else -> throw java.io.IOException("http ${c.responseCode}")
            }
        } finally { c.disconnect() }
    }

    /** LIST keys under a prefix via the relay's plain-HTTP interface (`GET /l/<prefix>`). */
    private fun relayHttpList(base: String, token: String, prefix: String): Result<List<String>> =
        relayHttpListDelta(base, token, prefix, digest = null).map { it.first ?: emptyList() }

    /** Last-seen LIST digest per `(relay node, prefix)`. Only committed once a listing's keys were
     *  fully processed — otherwise a 204 on the next poll would hide keys we still owe a GET. */
    private val mailboxListDigests = HashMap<String, String>()

    /** Drop cached LIST digests whose keys start with [nodeHex] (relay forgotten/erased) or every
     *  digest when the seen-set is reset — the next poll must re-list in full. */
    private fun invalidateListDigests(nodeHex: String? = null) {
        synchronized(mailboxListDigests) {
            if (nodeHex == null) mailboxListDigests.clear()
            else mailboxListDigests.keys.removeAll { it.startsWith("$nodeHex|") }
        }
    }

    /**
     * Delta-LIST (the radio saver, core httprelay.rs `X-Haven-List-Digest`): echo the last-seen
     * digest for this prefix and an UNCHANGED key set comes back as a bodiless 204 (`first ==
     * null`) instead of the same list again. A 200 carries the fresh keys plus the digest to echo
     * next time. A relay that doesn't speak the header simply never answers 204 and never hands us
     * a digest — today's behavior. Apple SharedStore.httpListDelta parity.
     */
    private fun relayHttpListDelta(base: String, token: String, prefix: String,
                                   digest: String?): Result<Pair<List<String>?, String?>> = runCatching {
        val auth = httpAuth(token, "GET", prefix, ByteArray(0))
            ?: throw java.io.IOException("cannot sign relay LIST")
        val root = base.trimEnd('/')
        val url = "$root/l/${java.net.URLEncoder.encode(prefix, "UTF-8").replace("+", "%20")}"
        val c = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
            connectTimeout = 4000; readTimeout = 30000
            setRequestProperty("Authorization", auth)
            if (!digest.isNullOrEmpty()) setRequestProperty("X-Haven-List-Digest", digest)
        }
        try {
            val respDigest = c.getHeaderField("X-Haven-List-Digest")?.trim()?.takeIf { it.isNotEmpty() }
            when (c.responseCode) {
                204 -> null to respDigest   // nothing new — skip the GETs
                in 200..299 -> {
                    val text = c.inputStream.bufferedReader().use { it.readText() }
                    text.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList() to respDigest
                }
                401, 403 -> throw RelayForbidden()
                else -> throw java.io.IOException("http list ${c.responseCode}")
            }
        } finally { c.disconnect() }
    }

    // ---- Relay refusal self-heal (iOS SharedStore.noteRefused / healForbiddenRelays parity) ------
    //
    // Relays that have refused us since our roster last reached them. A refusal is NOT a dead
    // endpoint — it means the relay has never been told this DEVICE id belongs to our account, so
    // `blob_forbidden` denies us before it ever considers the key (audit F4 extended that gate to
    // `haven/media/`, which is why media a few days old became unreachable while fresh media, whose
    // author was usually still online to answer peer-to-peer, looked fine). Publishing the
    // account-signed roster is precisely the remedy, so record the refusal and fix the CAUSE rather
    // than backing off from a relay that is working perfectly.
    private val rosterNeeded = LinkedHashSet<String>()
    private var lastHealMs: Long = 0

    /**
     * How long a relay that keeps refusing us is left alone, and how many refusals in a row we have
     * taken from it.
     *
     * A refusal is not an outage and must not mark the relay dead — that part of the design is right.
     * But "not an outage" was read as "no backoff at all", so a relay that will NEVER authorize us
     * got hit by every mailbox put, every list, every hello, every self-sync pass, several times a
     * second, forever. On a real phone that is a hot device and a flat battery: 140 refusals in one
     * log buffer, and a Nokia 6.1 that rebooted itself mid-test.
     *
     * The self-heal cannot rescue this case either. It answers a refusal by republishing our device
     * roster — but the relay already HELD our exact roster ("1 relay(s) already hold this exact
     * roster"), because the refusal is not about the roster. The relay simply does not serve this
     * account. Asking harder cannot fix that, so the honest behaviour is to ask rarely.
     */
    private val refusedUntilMs = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val refusedStreak = java.util.concurrent.ConcurrentHashMap<String, Int>()
    private const val REFUSED_GRACE = 3          // genuine roster gaps heal within a few attempts
    private const val REFUSED_BACKOFF_MIN_MS = 30_000L
    private const val REFUSED_BACKOFF_MAX_MS = 600_000L

    private fun noteRefused(nodeHex: String, what: String) {
        synchronized(rosterNeeded) { rosterNeeded.add(nodeHex) }
        val streak = refusedStreak.merge(nodeHex, 1) { a, b -> a + b } ?: 1
        // The first few refusals are free: that is the window in which publishing our roster
        // genuinely fixes things, and backing off early would slow down the case that DOES heal.
        if (streak >= REFUSED_GRACE) {
            val backoff = (REFUSED_BACKOFF_MIN_MS shl (streak - REFUSED_GRACE).coerceAtMost(5))
                .coerceAtMost(REFUSED_BACKOFF_MAX_MS)
            val until = System.currentTimeMillis() + backoff
            val prev = refusedUntilMs.put(nodeHex, until)
            // Log the transition, not every refusal — the spam was itself part of the cost.
            if (prev == null || prev < System.currentTimeMillis()) {
                Log.i(TAG, "relay ${nodeHex.take(8)} refused $streak× — standing down ${backoff / 1000}s " +
                    "(not an outage; it does not authorize this device)")
            }
            return
        }
        Log.i(TAG, "relay ${nodeHex.take(8)} REFUSED $what — not an outage; our device id isn't authorized there yet")
    }

    /** True while a relay is in refusal backoff — skip it rather than spending a request on a no. */
    private fun relayStoodDown(nodeHex: String): Boolean =
        (refusedUntilMs[nodeHex] ?: 0L) > System.currentTimeMillis()

    /** A relay answered us properly again — forget the refusal history entirely. */
    private fun noteRelayAccepted(nodeHex: String) {
        if (refusedStreak.remove(nodeHex) != null) refusedUntilMs.remove(nodeHex)
    }

    /** Re-publish our device roster to every relay that refused us, so the next attempt is allowed.
     *  True if anything was published (i.e. a retry is worth making). Rate-limited to 30s: a relay
     *  that refuses us for some OTHER reason must not turn every media miss into a publish storm. */
    private suspend fun healForbiddenRelays(): Boolean {
        val nodes = synchronized(rosterNeeded) {
            if (rosterNeeded.isEmpty() || System.currentTimeMillis() - lastHealMs < 30_000) return false
            // Only relays whose stand-down has EXPIRED are due for another attempt.
            //
            // This used to take every refusing relay and then clear its `refusedUntilMs` outright, on
            // the reasoning that the stand-down must not block its own remedy. But this runs every
            // 30s, so it deleted the backoff it had just armed — a 600s stand-down lasted about
            // fifteen seconds, and the device went right back to hammering a relay that will never
            // say yes. That is the phone getting hot. The remedy still gets through; it just waits
            // its turn like everything else, and each refusal makes the next wait longer.
            val due = rosterNeeded.filter { !relayStoodDown(it) }
            if (due.isEmpty()) return false
            lastHealMs = System.currentTimeMillis()
            rosterNeeded.removeAll(due.toSet())
            due
        }
        Log.i(TAG, "re-publishing device roster after refusal from [${nodes.joinToString(",") { it.take(8) }}]")
        // force: a refusal means the relay does NOT have a usable roster from us, so the
        // "already holds these bytes" skip must not suppress the very publish that fixes it.
        runCatching { publishDeviceRoster(force = true) }
        return true
    }

    /**
     * PUT one key. success = stored; failure([RelayForbidden]) = the relay is up and will take this
     * write the moment it knows this device; any other failure = unreachable. The same three-way split
     * [relayHttpGet] needs, for the mirror-image reason: a device that has never been authorized cannot
     * upload at all, and a 403 read as an outage backs off the very relay the write needs — so the blob
     * never lands, and the damage surfaces much later as a fetch that genuinely 404s. A real absence,
     * manufactured by a permissions problem. iOS SharedStore.httpPut parity.
     */
    private fun relayHttpPut(base: String, token: String, key: String, body: ByteArray): Result<Unit> = runCatching {
        // Digest over the EXACT bytes written below — `body` is streamed verbatim, unmodified.
        val auth = httpAuth(token, "PUT", key, body) ?: throw java.io.IOException("no device key to sign PUT")
        val c = (java.net.URL(httpKeyUrl(base, key)).openConnection() as java.net.HttpURLConnection).apply {
            requestMethod = "PUT"; doOutput = true; connectTimeout = 4000; readTimeout = 120000
            setRequestProperty("Authorization", auth)
            setRequestProperty("Content-Type", "application/octet-stream")
            setFixedLengthStreamingMode(body.size)
        }
        try {
            c.outputStream.use { it.write(body) }
            val code = c.responseCode
            when {
                code in 200..299 -> Unit
                code == 401 || code == 403 -> throw RelayForbidden()
                else -> throw java.io.IOException("relay PUT HTTP $code")
            }
        } finally { c.disconnect() }
    }

    /** PUT one media blob (chunked wire format) to a relay's HTTP interface. Three-way — see [relayHttpPut].
     *  [sealFp] identifies the bytes being sent, so an interrupted upload can resume against them and
     *  only against them; see [MediaUploadPlan] for why "the relay already has window i" is not on its
     *  own a reason to skip it. */
    private suspend fun httpUploadMedia(e: RelayEntry, nodeHex: String, ref: String, key: String, blob: ByteArray,
                                        chunked: Boolean, sealFp: String = "", force: Boolean = false): Result<Unit> {
        var last: Result<Unit> = Result.failure(java.io.IOException("relay has no usable HTTP interface"))
        for (base in httpUrlsFor(e)) {
            val r = if (chunked) {
                val ranges = chunkOffsets(blob.size)
                // A relay already holding the leading windows of an attempt that got cut short is asked
                // rather than re-sent. The manifest is still written at the end — it is what makes the
                // blob readable, and an interrupted attempt never got that far.
                val skip = resumeSkip(nodeHex, ref, sealFp, ranges.size, force) { i ->
                    relayHttpGet(base, e.httpToken, mediaChunkKey(ref, i)).getOrNull() != null
                }
                val sizes = ArrayList<Int>()
                var acc: Result<Unit> = Result.success(Unit)
                for ((i, range) in ranges.withIndex()) {
                    val (from, to) = range
                    if (i >= skip) {
                        acc = relayHttpPut(base, e.httpToken, mediaChunkKey(ref, i), blob.copyOfRange(from, to))
                        if (acc.isFailure) break
                    }
                    sizes.add(to - from)
                    recordUploaded(nodeHex, ref, sealFp, i + 1)
                }
                if (acc.isFailure) acc
                else relayHttpPut(base, e.httpToken, key, makeManifest(sizes)).onSuccess { clearUploaded(nodeHex, ref) }
            } else {
                relayHttpPut(base, e.httpToken, key, blob)
            }
            if (r.isSuccess) return r
            last = r
            // Reachable and healthy — it just doesn't know us. Backing off here would strand our media
            // on a relay that would happily store it once authorized.
            if (r.exceptionOrNull() !is RelayForbidden) markHttpUrlBad(base)
        }
        return last
    }

    /** Mirror a sealed media blob to EVERY circle relay (HTTP first — see mediaRelaysFor). */
    // Persistent "already uploaded this blob here" ledger — content-addressed media keys never change,
    // so a confirmed upload is permanent (no staleness). Stops the every-cycle backfill from re-reading
    // + re-uploading blobs a relay already holds ("the phone constantly sends media the relay has").
    private val backedUp = HashSet<String>()
    private var backedUpLoaded = false
    private fun ensureLedger() {
        if (backedUpLoaded) return
        runCatching { backedUp.addAll(appContext.getSharedPreferences("haven.mediabackup", Context.MODE_PRIVATE).getStringSet("done", emptySet()) ?: emptySet()) }
        backedUpLoaded = true
    }
    private fun isBackedUp(node: String, ref: String): Boolean { ensureLedger(); return backedUp.contains("$node|$ref") }
    private fun markBackedUp(node: String, ref: String) {
        ensureLedger()
        if (backedUp.add("$node|$ref")) {
            while (backedUp.size > 20_000) { val it = backedUp.iterator(); it.next(); it.remove() }
            runCatching { appContext.getSharedPreferences("haven.mediabackup", Context.MODE_PRIVATE).edit().putStringSet("done", HashSet(backedUp)).apply() }
        }
    }
    /**
     * Forget every confirmation for ONE ref, so the next pass re-probes every destination instead of
     * trusting a verdict that has since turned out to be wrong.
     *
     * The ledger is otherwise write-once, which is right while a stored blob is immutable AND
     * complete — and wrong the moment one isn't. A relay copy missing chunks is never re-examined, so
     * it stays broken forever while this device keeps reporting the post as safely backed up. The
     * complement of [forgetBackedUp], which drops a whole destination rather than one ref.
     */
    private fun forgetBackedUpRef(ref: String) {
        ensureLedger()
        if (backedUp.removeAll { it.endsWith("|$ref") }) {
            runCatching { appContext.getSharedPreferences("haven.mediabackup", Context.MODE_PRIVATE).edit().putStringSet("done", HashSet(backedUp)).apply() }
        }
    }

    /** Forget a relay's upload confirmations (it was forgotten/erased) so we re-mirror if it returns. */
    private fun forgetBackedUp(node: String) {
        ensureLedger()
        if (backedUp.removeAll { it.startsWith("$node|") }) {
            runCatching { appContext.getSharedPreferences("haven.mediabackup", Context.MODE_PRIVATE).edit().putStringSet("done", HashSet(backedUp)).apply() }
        }
    }

    /**
     * [force] = the 1.0.8 media-recovery path: skip every "already held?" probe and the persisted
     * ledger, and OVERWRITE the blob on every reachable destination. A blob is content-addressed +
     * write-once, so a 1.0.7 build that device-signed it froze it forever; the only cure is to
     * re-seal (now account-signed, done by the core fix) and overwrite the stored copy.
     */
    /** `reseal` seals afresh from the plaintext instead of re-sending the stored seal. `force` only
     *  bypasses the "already uploaded" ledger — it re-PUTs the SAME bytes, which repairs nothing when
     *  the thing that changed is the RECIPIENT SET. Media is sealed once and never re-sealed, so a
     *  member who joined after a blob was posted is not one of its recipients and can never open it;
     *  answering their ask with the old seal reports success while fixing nothing. */
    suspend fun uploadMedia(circleId: String, ref: String, force: Boolean = false,
                            reseal: Boolean = false): Boolean {
        if (uploadMediaOnce(circleId, ref, force, reseal)) return true
        // Nothing took the blob and at least one relay REFUSED it rather than being down: publish our
        // roster to the refusers and try once more, exactly as the Restore job does for the read side. A
        // device that has never been authorized anywhere otherwise never gets its FIRST blob up — and
        // because that upload failure is invisible, the damage surfaces much later as a fetch that
        // genuinely 404s, an absence manufactured entirely by a permissions problem.
        return healForbiddenRelays() && uploadMediaOnce(circleId, ref, force, reseal)
    }

    /** Re-seal a blob we authored from its plaintext, and replace our at-rest copy with the new
     *  envelope. Null when we cannot (no plaintext, or too large to open in RAM on this device) —
     *  the caller then falls back to the stored seal, which is no worse than before. */
    private fun resealFromPlaintext(circleId: String, ref: String): ByteArray? {
        val plain = LocalMedia.load(circleId, ref)
        if (plain == null) {
            Log.i(TAG, "reseal ${ref.take(10)}: cannot open our own copy (missing, or too big for RAM) — sending the stored seal")
            return null
        }
        val fresh = runCatching { social.sealCircleMedia(circleId, plain) }.getOrNull()
        if (fresh == null) {
            Log.w(TAG, "reseal ${ref.take(10)}: re-seal failed — sending the stored seal")
            return null
        }
        LocalMedia.writeRawSealed(ref, fresh)   // keep our copy consistent with what peers now hold
        Log.i(TAG, "reseal ${ref.take(10)}: sealed afresh to the circle's current members (${plain.size}B plain → ${fresh.size}B)")
        return fresh
    }

    private suspend fun uploadMediaOnce(circleId: String, ref: String, force: Boolean = false,
                                        reseal: Boolean = false): Boolean {
        // Skip entirely if every destination already has this blob (before the expensive rawSealed read).
        val dests = mediaRelaysFor(circleId)
        if (!force && dests.isNotEmpty() && dests.all { isBackedUp(it, ref) }) return true
        val key = mediaKey(ref)
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        var landed = false   // a destination holds it (probe hit) or accepted it (upload)

        // ---- Probe phase: NO blob read. The media key is content-addressed (independent of the
        // sealed bytes), so every unconfirmed destination can be asked "do you already hold it?"
        // BEFORE the full sealed file is loaded into RAM — a large video used to be re-read every
        // backfill pass just to discover every unconfirmed relay was unreachable/in backoff. Only
        // a destination that is REACHABLE and MISSING the blob justifies the read below; probe hits
        // go straight into the ledger, unreachable relays wait for a later pass.
        val uploadS3 = ArrayList<Pair<String, uniffi.haven_ffi.S3ConfigFfi>>()   // "s3:" pseudo-node → cfg
        val uploadLocal = ArrayList<String>()                                 // own hosted relay
        val uploadHttp = ArrayList<Pair<String, RelayEntry>>()                // node → HTTP interface
        val uploadDial = ArrayList<Pair<String, RelayClient>>()               // node → connected client
        for (nodeHex in dests) {
            if (!force && isBackedUp(nodeHex, ref)) { landed = true; continue }   // already confirmed on this relay
            // S3-BUCKET relay: probe via the S3 FFI (relayClientFor can't dial an "s3:" pseudo-node).
            // success(bytes) = already mirrored, success(null) = reachable miss, failure = unreachable.
            if (nodeHex.startsWith("s3:")) {
                val cfg = StorageStore.s3Config(appContext) ?: continue
                if (force) { uploadS3.add(nodeHex to cfg); continue }   // overwrite, no probe
                runCatching { uniffi.haven_ffi.s3Get(cfg, key) }.onSuccess { head ->
                    // COMPLETE, not merely present — see holdsCompleteBlob.
                    val complete = holdsCompleteBlob(ref, head) { k ->
                        runCatching { uniffi.haven_ffi.s3Get(cfg, k) }.getOrNull() != null
                    }
                    if (complete) { markRelaySeen(nodeHex); markBackedUp(nodeHex, ref); landed = true }
                    else {
                        if (head != null) Log.i("MediaSync", "probe ref=${ref.take(12)} s3: manifest present but chunks INCOMPLETE — re-uploading")
                        uploadS3.add(nodeHex to cfg)
                    }
                }
                continue
            }
            // Our OWN hosted relay: the local store answers instantly (never dial/HTTP ourselves).
            if (hostedHex != null && nodeHex == hostedHex) {
                // COMPLETE, not merely present — see holdsCompleteBlob. localHas answers the chunk
                // probes from the store index rather than reading an 8 MB window per question.
                val head = if (force) null else relayHost?.localGet(key)
                if (head != null && holdsCompleteBlob(ref, head) { k -> relayHost?.localHas(k) == true }) {
                    markBackedUp(nodeHex, ref); landed = true
                } else {
                    if (head != null) Log.i("MediaSync", "probe ref=${ref.take(12)} own-relay: manifest present but chunks INCOMPLETE — re-uploading")
                    uploadLocal.add(nodeHex)
                }
                continue
            }
            // Relay HTTP interface — a reachable relay is authoritative (the iroh path serves the
            // SAME store): hit → ledger, 404 → upload over HTTP; only unreachable falls to the dial.
            val entry = relayEntries[nodeHex]
            if (entry != null) {
                if (force) {
                    // Overwrite over the HTTP interface without asking whether it's held; a mid-upload
                    // failure below falls back to the iroh dial (same store).
                    if (httpUrlsFor(entry).isNotEmpty()) { uploadHttp.add(nodeHex to entry); continue }
                } else {
                    var resolved = false
                    for (base in httpUrlsFor(entry)) {
                        val r = relayHttpGet(base, entry.httpToken, key)
                        // Reachable and healthy — it just doesn't know us. Backing off here would
                        // strand our media on a relay that would happily store it once authorized.
                        if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "media probe"); continue }
                        if (r.isFailure) { markHttpUrlBad(base); continue }
                        // COMPLETE, not merely present — see holdsCompleteBlob. The extra GET of the
                        // final window is paid at most once per (ref, relay): a copy that checks out
                        // goes into the ledger and is never probed again.
                        val head = r.getOrNull()
                        val complete = holdsCompleteBlob(ref, head) { k ->
                            relayHttpGet(base, entry.httpToken, k).getOrNull() != null
                        }
                        if (complete) { markRelaySeen(nodeHex); markBackedUp(nodeHex, ref); landed = true }
                        else {
                            if (head != null) Log.i("MediaSync", "probe ref=${ref.take(12)} relay=${nodeHex.take(8)}: manifest present but chunks INCOMPLETE — re-uploading")
                            uploadHttp.add(nodeHex to entry)
                        }
                        resolved = true
                        break
                    }
                    if (resolved) continue
                }
            }
            val client = relayClientFor(nodeHex) ?: continue   // honors backoff — skip WITHOUT reading
            if (force) { uploadDial.add(nodeHex to client); continue }
            runCatching {
                if (client.has(key)) {
                    markRelayOk(nodeHex)
                    // COMPLETE, not merely present — see holdsCompleteBlob. `has` carries no bytes,
                    // so the manifest is only fetched once chunk 0 proves the blob is chunked (and
                    // the manifest key therefore tiny rather than a whole media file).
                    val head = if (client.has(mediaChunkKey(ref, 0))) client.get(key) else ByteArray(0)
                    if (holdsCompleteBlob(ref, head) { k -> client.has(k) }) {
                        markBackedUp(nodeHex, ref); landed = true
                    } else {
                        Log.i("MediaSync", "probe ref=${ref.take(12)} relay=${nodeHex.take(8)}: manifest present but chunks INCOMPLETE — re-uploading")
                        uploadDial.add(nodeHex to client)
                    }
                } else uploadDial.add(nodeHex to client)
            }.onFailure { relayFailed(nodeHex) }
        }
        if (uploadS3.isEmpty() && uploadLocal.isEmpty() && uploadHttp.isEmpty() && uploadDial.isEmpty()) return landed

        // ---- Read the sealed blob, now known to be needed by at least one reachable destination.
        // A repair must produce NEW bytes: open our own copy and seal it again, so the fresh envelope
        // addresses the circle's CURRENT members. Re-sending rawSealed() would hand back the very
        // recipient list that already excluded the asker.
        val blob = (if (reseal) resealFromPlaintext(circleId, ref) else null)
            ?: LocalMedia.rawSealed(ref) ?: return landed
        val chunked = blob.size > mediaChunkBytes
        val ranges = chunkOffsets(blob.size)
        val sizes = ranges.map { it.second - it.first }
        // Identity of the exact bytes being uploaded. A destination's stored windows may only be
        // skipped if WE put them there from THESE bytes: the at-rest blob for a ref is not immutable
        // (re-storing the same plaintext, or repairing a blob that won't decrypt, re-seals it under
        // the same ref with a fresh nonce and usually an identical length), and another device of this
        // account may have uploaded the same ref from a seal of its own. Splicing across two seals
        // yields a blob of exactly the right length that decrypts to nothing — silently, and
        // permanently, since the key is content-addressed and write-once. See MediaUploadPlan.
        val fp = if (chunked) MediaUploadPlan.sealFingerprint(blob) else ""
        for ((nodeHex, cfg) in uploadS3) {
            runCatching {
                if (chunked) {
                    val skip = resumeSkip(nodeHex, ref, fp, ranges.size, force) { i ->
                        uniffi.haven_ffi.s3Get(cfg, mediaChunkKey(ref, i)) != null
                    }
                    for ((i, r) in ranges.withIndex()) {
                        if (i >= skip) uniffi.haven_ffi.s3Put(cfg, mediaChunkKey(ref, i), blob.copyOfRange(r.first, r.second))
                        recordUploaded(nodeHex, ref, fp, i + 1)
                    }
                    uniffi.haven_ffi.s3Put(cfg, key, makeManifest(sizes))
                    clearUploaded(nodeHex, ref)
                } else {
                    uniffi.haven_ffi.s3Put(cfg, key, blob)
                }
            }.onSuccess { markRelaySeen(nodeHex); markBackedUp(nodeHex, ref); landed = true }
                .onFailure { android.util.Log.d(TAG, "s3 media put failed ($nodeHex): ${it.message}") }
        }
        // Our OWN hosted relay: write straight into the local store.
        for (nodeHex in uploadLocal) {
            runCatching {
                if (chunked) {
                    val skip = resumeSkip(nodeHex, ref, fp, ranges.size, force) { i ->
                        relayHost?.localGet(mediaChunkKey(ref, i)) != null
                    }
                    for ((i, r) in ranges.withIndex()) {
                        if (i >= skip) relayHost?.localPut(mediaChunkKey(ref, i), blob.copyOfRange(r.first, r.second))
                        recordUploaded(nodeHex, ref, fp, i + 1)
                    }
                    relayHost?.localPut(key, makeManifest(sizes))
                    clearUploaded(nodeHex, ref)
                } else {
                    relayHost?.localPut(key, blob)
                }
            }.onSuccess { markBackedUp(nodeHex, ref); landed = true }
        }
        // Relay HTTP interface — the DEFAULT cross-NAT path. Success = done for this relay
        // (the iroh path serves the same store); a mid-upload failure falls back to the iroh put.
        for ((nodeHex, entry) in uploadHttp) {
            val r = httpUploadMedia(entry, nodeHex, ref, key, blob, chunked, fp, force)
            if (r.isSuccess) {
                markRelaySeen(nodeHex); markBackedUp(nodeHex, ref); landed = true
                android.util.Log.i("MediaSync", "HTTP uploaded ref=$ref to ${nodeHex.take(8)}")
                continue
            }
            if (r.exceptionOrNull() is RelayForbidden) {
                // The iroh dial goes through the SAME membership gate, so falling back to it only
                // repeats the refusal. Record it and let the heal + retry in [uploadMedia] publish
                // our roster first, so the retry is allowed.
                noteRefused(nodeHex, "media upload ${ref.take(10)}")
                continue
            }
            relayClientFor(nodeHex)?.let { uploadDial.add(nodeHex to it) }
        }
        for ((nodeHex, client) in uploadDial) {
            runCatching {
                if (chunked) {
                    // `has` is an exact, cheap existence check here — no download, unlike the S3/HTTP probes.
                    val skip = resumeSkip(nodeHex, ref, fp, ranges.size, force) { i -> runCatching { client.has(mediaChunkKey(ref, i)) }.getOrDefault(false) }
                    for ((i, r) in ranges.withIndex()) {
                        if (i >= skip) client.put(mediaChunkKey(ref, i), blob.copyOfRange(r.first, r.second))
                        recordUploaded(nodeHex, ref, fp, i + 1)
                    }
                    client.put(key, makeManifest(sizes))
                    clearUploaded(nodeHex, ref)
                } else {
                    client.put(key, blob)
                }
            }
                .onSuccess { markRelayOk(nodeHex); markBackedUp(nodeHex, ref); landed = true }
                .onFailure { relayFailed(nodeHex) }
        }
        return landed
    }

    /** Byte ranges of each 8 MB chunk over a blob of [size] bytes: list of (from, toExclusive). */
    private fun chunkOffsets(size: Int): List<Pair<Int, Int>> = MediaUploadPlan.windows(size)

    // ---- Resumable chunked upload (iOS SharedStore.putMediaFile parity) --------------------------
    //
    // Ask a destination which leading windows it already holds and send only the rest, so an upload
    // that keeps getting interrupted CONVERGES instead of restarting at window 0 forever. The two
    // halves of that decision — the prefix scan and the seal-fingerprint guard that keeps it from
    // silently corrupting the blob — live in [MediaUploadPlan]; read the trap described there before
    // touching any of this.

    /**
     * How far a chunked upload of a ref got on ONE destination, and from WHICH sealed bytes:
     * `"<node>|<ref>"` -> `"<sha256 of the seal>:<windows written>"`.
     *
     * Per DESTINATION, not per ref, because progress is per destination — and the fingerprint travels
     * with it because windows written from a different seal must never be counted (see
     * [MediaUploadPlan]). Persisted because the interruption this feature exists for is the app being
     * KILLED; an in-memory record would be empty exactly when the decision gets made.
     *
     * Written after each window, which is nothing beside the 8 MB PUT it follows. Losing the last
     * write or two to a kill is harmless in the only direction that matters: it UNDERSTATES progress,
     * costing a re-sent window, and can never overstate it.
     */
    private val uploadProgress = HashMap<String, String>()
    private var uploadProgressLoaded = false
    private fun uploadPrefs() = appContext.getSharedPreferences("haven.mediabackup", Context.MODE_PRIVATE)
    private fun ensureUploadProgress() {
        if (uploadProgressLoaded) return
        runCatching {
            for (e in uploadPrefs().getStringSet("resume", emptySet()) ?: emptySet()) {
                val i = e.lastIndexOf('=')
                if (i > 0) uploadProgress[e.substring(0, i)] = e.substring(i + 1)
            }
        }
        uploadProgressLoaded = true
    }
    /** (fingerprint, windows) this destination was last given for [ref], or null if we have no record. */
    private fun uploadedSoFar(node: String, ref: String): Pair<String, Int>? {
        ensureUploadProgress()
        val v = uploadProgress["$node|$ref"] ?: return null
        val i = v.lastIndexOf(':')
        if (i <= 0) return null
        return v.substring(0, i) to (v.substring(i + 1).toIntOrNull() ?: return null)
    }
    private fun recordUploaded(node: String, ref: String, fp: String, windows: Int) {
        ensureUploadProgress()
        if (uploadProgress.put("$node|$ref", "$fp:$windows") == "$fp:$windows") return
        // Bounded like every other durable record here. Eviction only costs a full re-upload of a
        // long-idle ref (the safe direction — see MediaUploadPlan), never correctness.
        while (uploadProgress.size > 2_000) { val it = uploadProgress.keys.iterator(); it.next(); it.remove() }
        runCatching {
            uploadPrefs().edit()
                .putStringSet("resume", uploadProgress.entries.map { "${it.key}=${it.value}" }.toHashSet()).apply()
        }
    }
    /** A finished upload needs no resume record; drop it rather than let it age out of the cap. */
    private fun clearUploaded(node: String, ref: String) {
        ensureUploadProgress()
        if (uploadProgress.remove("$node|$ref") == null) return
        runCatching {
            uploadPrefs().edit()
                .putStringSet("resume", uploadProgress.entries.map { "${it.key}=${it.value}" }.toHashSet()).apply()
        }
    }

    /**
     * How many leading windows to SKIP for one destination: the ones we ourselves wrote there from
     * these exact sealed bytes ([MediaUploadPlan.trustedPrefix]) AND that it still holds. The probe is
     * the second half — a relay may have swept the chunks since — and it stops at the first miss, so
     * with no prior progress this costs ONE probe. That is what makes it affordable on destinations
     * (S3, a relay's HTTP interface) whose only existence check is a full GET.
     *
     * A probe that THROWS counts as a miss: an unreachable destination must re-send, never skip.
     */
    private suspend fun resumeSkip(node: String, ref: String, fp: String, total: Int, force: Boolean,
                                   held: suspend (Int) -> Boolean): Int {
        val prior = uploadedSoFar(node, ref)
        val trusted = MediaUploadPlan.trustedPrefix(force, prior?.first, fp, prior?.second ?: 0, total)
        if (trusted == 0) return 0
        val probed = ArrayList<Boolean>()
        for (i in 0 until trusted) {
            val h = runCatching { held(i) }.getOrDefault(false)
            probed.add(h)
            if (!h) break
        }
        val skip = MediaUploadPlan.skipCount(probed)
        if (skip > 0) {
            android.util.Log.i("MediaSync", "resumed upload to ${node.take(8)}: $skip/$total windows already stored")
        }
        return skip
    }

    /**
     * Refs whose stored copy was FOUND on a relay and could not be opened — the bytes are bad, not
     * missing (see [acceptFetchedBlob]). Deliberately in-memory only: a restart, or an author who
     * re-seals and overwrites the blob, both deserve another attempt. Its whole job is to stop the
     * 20-second sweep re-downloading the same unopenable bytes forever.
     */
    private val unopenableMedia = java.util.Collections.synchronizedSet(HashSet<String>())

    /**
     * Gate a just-fetched sealed blob on it actually OPENING before we call the fetch a success.
     *
     * A relay serves opaque bytes, so "the GET returned 200" is not "the media arrived". When the
     * bytes are there and cannot be decrypted for ANY of our circles, the stored copy is BAD, not
     * missing — and until now that was a permanent, silent dead end here: the unopenable blob was
     * written to disk, [LocalMedia.has] began answering true, the ref dropped out of
     * [requestMissingMedia], and the post kept a broken placeholder forever with nothing logged.
     *
     * The most likely way a blob gets into this state is a resumed chunked upload that stitched
     * windows from two DIFFERENT seals: sealing is not byte-stable (per-recipient key material plus a
     * fresh nonce), so the result reassembles to exactly the right length and decrypts to nothing.
     * That is fixed at the source now (a seal is reused across retries), but blobs written during the
     * window are still out there.
     *
     * So: say what actually happened, drop the bad bytes rather than let them masquerade as held
     * media, and remember the ref for this session. Only the AUTHOR can really repair it — they still
     * hold the plaintext, and their forced re-seal ([maybeResealOwnMedia] / uploadMedia(force=true))
     * overwrites the stored copy — so the skip is deliberately not persisted.
     *
     * A blob we cannot JUDGE (no circles loaded yet) is kept and reported as fetched: under-claiming
     * corruption is the safe direction. iOS `SharedStore.restore`'s "found … but OPEN FAILED" branch.
     */
    private fun acceptFetchedBlob(ref: String, circleId: String? = null): Boolean {
        val opens = LocalMedia.opensForAnyCircle(ref) ?: return true
        if (opens) { if (unopenableMedia.remove(ref)) saveUnopenable(); return true }
        android.util.Log.w("MediaSync",
            "media restore ${ref.take(12)}: fetched but OPEN FAILED for every circle — " +
            "QUARANTINED (bytes kept; will re-open, not re-download, once a key/roster lands)")
        // KEEP THE BYTES. "Opens for no circle I currently hold" is NOT proof the bytes are bad —
        // it is equally "I do not have that key yet", and deleting on that reading destroyed data
        // that would have opened minutes later. [onRosterLearned] already existed to retry exactly
        // this case and could never work, because the bytes it wanted to re-read were gone: all a
        // retry could do was re-download the same blob from the same relay.
        //
        // Quarantining instead makes recovery FREE (a local decrypt attempt, no network) and makes
        // the failure survivable: 46 refs on one device had each been re-downloaded on every launch,
        // failed, and re-parked, with the sweep reporting `missing=0` the whole time.
        unopenableMedia.add(ref)
        saveUnopenable()
        // ON DEMAND, and only on demand: ask the AUTHOR to re-seal this one ref. Frame 31 already
        // carries exactly this request (sealed + signed, and it rides the circle mailbox so an
        // author offline for a week gets it on their next sync), and the author side answers with
        // uploadMedia(force = true) — a FRESH seal, which is precisely what repairs a blob stitched
        // from two different seals. Nothing is re-uploaded unless a reader actually found a broken
        // copy, so a healthy fleet pays nothing.
        askAuthorToReseal(ref, circleId)
        return false
    }

    /** One re-seal ask per ref per hour: the sweep revisits a broken ref constantly, and the author
     *  should not be asked to spend an upload every time it does. */
    /** The author now REPAIRS on the first ask for a ref it has not re-sealed, rather than answering
     *  from a timer, so this no longer has to dodge their window — it only paces retries for a blob
     *  whose first repair genuinely did not help. Kept modest, and capped by RESEAL_MAX_TRIES, so a
     *  blob that will never converge cannot bill its author a full re-seal on a loop.
     *
     *  (Was 11 min to sit just outside the author's 10-minute cache: a workaround for the bug that
     *  is now fixed at the source.)
     */
    private val RESEAL_ASK_COOLDOWN_MS = 15L * 60 * 1000
    /** Probed at least once since launch — a second probe answers the same question. */
    private val probedThisSession = java.util.Collections.synchronizedSet(HashSet<String>())
    /** Probing is ONCE per ref per session, so the total cost is the size of the library, not a
     *  rate — spreading it thinner does not save work, it just delays every repair behind it. At 2
     *  per 2 minutes a 57-item library took an hour to notice its broken items; this covers it in a
     *  few minutes and then goes quiet for the rest of the session. */
    private val VERIFY_PER_SWEEP = 8
    /** Probing costs a decrypt each, so it runs on a slow cadence rather than every sweep — the
     *  library still converges, just without competing with the UI for CPU and disk. */
    private val VERIFY_SWEEP_INTERVAL_MS = 30_000L
    private var lastVerifySweepAt = 0L
    private fun verifySweepDue(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastVerifySweepAt < VERIFY_SWEEP_INTERVAL_MS) return false
        lastVerifySweepAt = now
        return true
    }
    private val resealAskedAt = HashMap<String, Long>()
    private val resealTries = HashMap<String, Int>()
    private val RESEAL_MAX_TRIES = 3

    /**
     * The point of USE reporting a failure, which no sweep can match for accuracy: the tile tried to
     * resolve this ref and got nothing back. A blob can slip past [verifyHeldMedia] — the probe is
     * bounded, and a large legacy envelope can fail in ways the probe reports as "cannot judge" —
     * but a tile that came up empty for media we HOLD is unambiguous. Ask the author to re-seal it.
     */
    fun noteMediaUnreadable(ref: String, circleId: String) {
        if (!ready || LocalMedia.isSynthetic(ref) || !LocalMedia.has(ref)) return
        Log.w(TAG, "tile could not resolve ${ref.take(10)} though we hold it — asking the author to re-seal")
        scope.launch(Dispatchers.IO) { runCatching { askAuthorToReseal(ref, circleId) } }
    }

    private fun askAuthorToReseal(ref: String, circleId: String?) {
        val now = System.currentTimeMillis()
        synchronized(resealAskedAt) {
            val last = resealAskedAt[ref]
            if (last != null && now - last < RESEAL_ASK_COOLDOWN_MS) return
            // BOUNDED. Every ask makes the AUTHOR re-read, re-seal and re-upload the whole file —
            // hundreds of MB for a video. A blob that will never converge (its author no longer
            // holds the plaintext, say) would otherwise bill them that cost every cooldown, forever,
            // on battery and data. After a few honest attempts, stop and wait for something to
            // actually change: a restart, or a new epoch/roster, both of which clear this.
            val tries = (resealTries[ref] ?: 0) + 1
            if (tries > RESEAL_MAX_TRIES) {
                if (tries == RESEAL_MAX_TRIES + 1) {
                    Log.i(TAG, "reseal ${ref.take(10)}: $RESEAL_MAX_TRIES attempts made no difference — parking it rather than re-billing the author")
                }
                resealTries[ref] = tries
                return
            }
            resealTries[ref] = tries
            resealAskedAt[ref] = now
            while (resealAskedAt.size > 500) resealAskedAt.remove(resealAskedAt.keys.first())
            while (resealTries.size > 500) resealTries.remove(resealTries.keys.first())
        }
        val circleIds = if (circleId != null) listOf(circleId)
            else runCatching { social.circles().map { it.id } }.getOrDefault(emptyList())
        for (cid in circleIds) {
            val feed = runCatching { social.feed(cid, nowMs(), null) }.getOrDefault(emptyList())
            for (item in feed) {
                if (item.media.contains(ref)) {
                    // My own post: I hold the only plaintext, so there is nobody to ask — a forced
                    // re-upload from here is the repair, not a request.
                    if (item.isMe) {
                        scope.launch { runCatching { uploadMedia(cid, ref, force = true, reseal = true) } }
                        Log.i(TAG, "quarantine ${ref.take(10)}: my own post — re-sealing it myself")
                    } else {
                        requestMediaWhenAvailable(ref, cid, item.id, item.authorShort)
                    }
                    return
                }
                val cm = item.comments.firstOrNull { it.media.contains(ref) } ?: continue
                if (cm.isMe) {
                    scope.launch { runCatching { uploadMedia(cid, ref, force = true, reseal = true) } }
                } else {
                    requestMediaWhenAvailable(ref, cid, item.id, cm.authorShort)
                }
                return
            }
        }
        Log.i(TAG, "quarantine ${ref.take(10)}: no post references it — cannot identify an author to ask")
    }

    /** Persisted across restarts: re-downloading a blob that will fail to open again is pure waste,
     *  and the in-memory set meant every launch paid for all of them a second time. */
    /** Bump when a release changes what a parked ref is worth retrying. Persisting the quarantine
     *  stopped the pointless re-downloads, but it also means a ref parked by an OLDER build is never
     *  reconsidered — including after a release that can finally repair it. A repair the user can
     *  never reach is not a repair, so an upgrade empties the lot once and lets them prove
     *  themselves again; anything still broken re-parks on its next sweep at no extra cost. */
    private val quarantineEpoch = 2

    private fun loadUnopenable() {
        val seen = prefs.getInt("unopenableEpoch", 0)
        if (seen != quarantineEpoch) {
            val n = prefs.getStringSet("unopenableMedia", emptySet())?.size ?: 0
            prefs.edit().remove("unopenableMedia").putInt("unopenableEpoch", quarantineEpoch).apply()
            if (n > 0) Log.i(TAG, "quarantine: cleared $n parked ref(s) for the new repair path — they get one more try")
            return
        }
        val saved = prefs.getStringSet("unopenableMedia", emptySet()) ?: return
        if (saved.isNotEmpty()) unopenableMedia.addAll(saved)
    }
    private fun saveUnopenable() {
        prefs.edit().putStringSet("unopenableMedia", HashSet(unopenableMedia)).apply()
    }

    /**
     * Re-attempt the OPEN (never the download) for every quarantined ref. Cheap and local: the bytes
     * are already here, so a key we have since learned turns a broken tile into a working one with
     * no network at all. A ref whose bytes have gone missing is un-parked so the normal sweep can
     * fetch it again; genuinely corrupt bytes just fail and stay parked.
     */
    /** Refs already verified openable — never re-tested. */
    private val verifiedOpen = java.util.Collections.synchronizedSet(HashSet<String>())
    private var verifyCursor = 0

    /**
     * HELD is not the same as READABLE, and only one of those is what a user sees.
     *
     * `LocalMedia.has(ref)` answers "the bytes are on disk", so a blob we hold but cannot open is
     * excluded from the missing sweep AND from every repair path — which is exactly how a device
     * sat at `missing=0` while showing 23 broken tiles. Media is sealed once to a fixed recipient
     * list and never re-sealed, so a member who joined after a post can never open its media: the
     * bytes arrive perfectly and decrypt to nothing, forever, with nothing reporting it.
     *
     * So: actually TEST a few held refs each sweep, and ask the author to re-seal the ones that fail.
     * Bounded to [VERIFY_PER_SWEEP] because an open attempt is real crypto over real bytes; a pass
     * costs a few refs and the whole library converges over a handful of sweeps.
     */
    private fun verifyHeldMedia() {
        val refs = ArrayList<Pair<String, String>>()   // ref → circleId
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            for (item in runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())) {
                for (r in item.media) {
                    if (LocalMedia.isSynthetic(r) || verifiedOpen.contains(r) || !LocalMedia.has(r)) continue
                    // Big blobs are probed too — skipping them by size switched off repair for
                    // precisely the files still broken (the videos), which is the opposite of the
                    // goal. The cost is controlled by probing each ref at most ONCE per session
                    // instead: one decrypt answers the question, and re-asking it every sweep is
                    // what made this expensive, not the file size.
                    if (probedThisSession.contains(r)) continue
                    refs.add(r to c.id)
                }
            }
        }
        if (refs.isEmpty()) return
        Log.i(TAG, "verify sweep: ${refs.size} held ref(s) not yet probed this session")
        if (verifyCursor >= refs.size) verifyCursor = 0
        var tested = 0
        while (tested < VERIFY_PER_SWEEP && verifyCursor < refs.size) {
            val (ref, cid) = refs[verifyCursor]; verifyCursor++; tested++
            probedThisSession.add(ref)
            when (LocalMedia.opensForAnyCircle(ref)) {
                true -> verifiedOpen.add(ref)
                false -> {
                    // Say WHICH stage refuses it. A bare "did not open" is what made this take all night.
                    val why = runCatching {
                        val sealed = LocalMedia.rawSealed(ref)
                        if (sealed == null) "too-big-to-read-in-ram"
                        else social.mediaOpenDiagnosis(cid, sealed)
                    }.getOrElse { "diag-failed: ${it.message}" }
                    Log.w(TAG, "held-but-unreadable ${ref.take(10)} — $why")
                    askAuthorToReseal(ref, cid)
                }
                null -> {}   // cannot judge yet (no circles loaded / bytes vanished) — try again later
            }
        }
    }

    private fun retryParkedOpens() {
        val parked = synchronized(unopenableMedia) { unopenableMedia.toList() }
        if (parked.isEmpty()) return
        var opened = 0
        var regone = 0
        for (r in parked) {
            val verdict = LocalMedia.opensForAnyCircle(r)
            if (verdict == true) { unopenableMedia.remove(r); opened++ }
            else if (verdict == null && !LocalMedia.has(r)) { unopenableMedia.remove(r); regone++ }
        }
        if (opened > 0 || regone > 0) {
            saveUnopenable()
            Log.i(TAG, "quarantine retry: $opened now open, $regone lost their bytes (will re-fetch), ${unopenableMedia.size} still parked")
        }
    }

    private suspend fun fetchMediaFromRelay(circleId: String, ref: String): Boolean {
        val key = mediaKey(ref)   // "haven/media/<ref>" — matches the iOS S3 upload key
        val relays = mediaRelaysFor(circleId)   // S3/HTTP first (default), iroh blob = fast-path
        val mineId = runCatching { node?.nodeIdHex() ?: social.myNodeHex() }.getOrNull()?.take(12)
        android.util.Log.i("MediaSync", "fetch ref=$ref circle=$circleId relays=${relays.map { it.take(12) }} mine=$mineId")
        // Try each relay in turn; the first that has the (manifest or) blob wins (graceful fallback).
        for (nodeHex in relays) {
            // S3-BUCKET relay: fetch via the S3 FFI. relayClientFor can't dial an "s3:" pseudo-node, so
            // WITHOUT this branch media stored in S3 was NEVER fetched per-ref — the mailbox poll has an
            // S3 branch (so posts synced) but this media fetch did not, so videos + large photos that
            // can't inline never arrived. THE "posts sync but recent videos won't play on Android" bug.
            if (nodeHex.startsWith("s3:")) {
                val cfg = StorageStore.s3Config(appContext) ?: continue
                val head = runCatching { uniffi.haven_ffi.s3Get(cfg, key) }.getOrNull() ?: continue
                val ok = reassembleInto(ref, head) { i -> runCatching { uniffi.haven_ffi.s3Get(cfg, mediaChunkKey(ref, i)) }.getOrNull() }
                if (!ok) continue
                markRelaySeen(nodeHex)
                android.util.Log.i("MediaSync", "S3 fetched ref=$ref headBytes=${head.size}")
                return true
            }
            // Relay HTTP interface — the DEFAULT cross-NAT path. A reachable relay that answers 404
            // is a real MISS: the iroh blob path serves the SAME store, so skip the doomed ~30s dial
            // for this relay and move on. Only an UNREACHABLE URL falls through to the iroh dial.
            val entry = relayEntries[nodeHex]
            val httpBases = entry?.let { httpUrlsFor(it) } ?: emptyList()
            var httpMiss = false
            var httpDone = false
            for (base in httpBases) {
                val r = relayHttpGet(base, entry!!.httpToken, key)
                // A REFUSAL is not a miss and not an outage: never markHttpUrlBad (the relay is
                // healthy) and never set httpMiss (or the iroh fallback below is skipped too and a
                // permissions failure is laundered into "nobody has it").
                if (r.exceptionOrNull() is RelayForbidden) {
                    noteRefused(nodeHex, "media fetch ${ref.take(10)}")
                    // A 403 proves something IS answering as a relay behind this hostname, so the
                    // base is alive even though this request was refused.
                    noteFabricBaseAlive(base)
                    // ...but we hold a bearer token that should not be refused, so also re-read the
                    // interface doc over iroh in case the token/URL pair moved on.
                    refreshRelayInterfaceIfNeeded(nodeHex, force = true)
                    continue
                }
                if (r.isFailure) {
                    android.util.Log.i("MediaSync", "  http $base unreachable (${r.exceptionOrNull()?.message})")
                    markHttpUrlBad(base)
                    // Unreachable front door == unreachable DERP: it is the same hostname. Let the
                    // fabric fall back to n0 rather than staying pinned to a host that is gone.
                    noteFabricBaseDead(base)
                    continue
                }
                val head = r.getOrNull()
                if (head == null) {
                    // A 404 is ambiguous: either this relay genuinely lacks the blob, or the
                    // hostname was rotated away and the tunnel provider is 404ing EVERYTHING at a
                    // name that no longer routes anywhere. Distinguish by asking for a key the
                    // relay always serves — if its own interface doc is missing too, we are not
                    // talking to the relay at all.
                    val iface = relayHttpGet(base, entry.httpToken, "haven/relay/__interface__")
                    if (iface.isSuccess && iface.getOrNull() != null) noteFabricBaseAlive(base)
                    else if (iface.exceptionOrNull() !is RelayForbidden) noteFabricBaseDead(base)
                    refreshRelayInterfaceIfNeeded(nodeHex, force = true)
                    httpMiss = true; break
                }
                val ok = reassembleInto(ref, head) { i -> relayHttpGet(base, entry.httpToken, mediaChunkKey(ref, i)).getOrNull() }
                if (!ok) continue
                markRelaySeen(nodeHex)
                android.util.Log.i("MediaSync", "HTTP fetched ref=$ref via $base headBytes=${head.size}")
                httpDone = true
                break
            }
            if (httpDone) return true
            if (httpMiss) { android.util.Log.i("MediaSync", "  node=${nodeHex.take(12)} http MISS — skipping iroh dial"); continue }
            val client = relayClientFor(nodeHex)
            if (client == null) { android.util.Log.i("MediaSync", "  node=${nodeHex.take(12)} client=NULL (self-dial guard / backoff / connect-fail)"); continue }
            val head = runCatching { client.get(key) }.getOrNull()
            android.util.Log.i("MediaSync", "  node=${nodeHex.take(12)} got=${head?.size ?: -1}")
            if (head == null) { relayFailed(nodeHex); continue }
            val ok = reassembleInto(ref, head) { i -> runCatching { client.get(mediaChunkKey(ref, i)) }.getOrNull() }
            if (!ok) { relayFailed(nodeHex); continue }
            markRelayOk(nodeHex)
            return true
        }
        // Say WHICH it was. Reporting a permissions failure as absence is what made this read as data
        // loss for days — the blob was on the relay the whole time and the device simply wasn't
        // allowed to ask for it.
        if (synchronized(rosterNeeded) { rosterNeeded.isEmpty() }) {
            android.util.Log.i("MediaSync", "fetch ref=$ref NOT FOUND — no relay served it")
            // Honest placeholder state: the relays answered and none holds it — we are waiting on
            // the SENDER to put it (back) up, which is a different thing from "downloading" or
            // "gone forever" (Apple noteMediaMissingOnRelays parity).
            noteMediaMissingOnRelays(ref)
            // A full miss is ALSO the signature of a relay whose HTTP front door we can't use
            // (rotated tunnel / never learned): the blob may sit on a relay we only failed to
            // ASK properly. Try to fetch each dest relay's self-published interface over iroh —
            // if one lands, the retry path finds the blob and the URL gets re-announced.
            // (s3: pseudo-relays and our own hosted node are skipped inside.)
            for (hex in relays) refreshRelayInterfaceIfNeeded(hex)
        } else {
            android.util.Log.i("MediaSync", "fetch ref=$ref REFUSED by ${synchronized(rosterNeeded) { rosterNeeded.size }} relay(s) — not missing; re-publishing our roster so the retry is allowed")
        }
        return false
    }

    // ---- Resumable chunked relay restore (.part bookkeeping; Apple SharedStore parity) ----------
    //
    // A chunked relay download used to be all-or-nothing: any chunk miss threw the temp file away,
    // so a 600 MB video over a flaky tunnel restarted from chunk 0 every retry — the mirror image
    // of the upload-resume problem (frame-33 peer resume already fixed the peer path). Chunks are
    // fetched IN ORDER and appended, so resume state is just "how many leading chunks are in the
    // .part file", persisted in a sidecar next to it. The manifest's chunk count keys validity: a
    // count mismatch (a different seal uploaded meanwhile) discards the partial.

    private fun restorePartsDir(): File =
        File(appContext.filesDir, "relay-parts").apply { mkdirs() }
    private fun restorePartFile(ref: String): File {
        val safe = MessageDigest.getInstance("SHA-256").digest(ref.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }.take(32)
        return File(restorePartsDir(), "$safe.part")
    }
    private fun restoreMetaFile(ref: String): File = File(restorePartFile(ref).path + ".meta")
    /**
     * Identity of the exact sealed bytes a manifest describes.
     *
     * Two seals of the SAME media are not byte-identical — the envelope carries per-recipient key
     * material and a fresh nonce — and their chunk COUNT is normally identical, so the count cannot
     * tell them apart. A partial built from one seal must never be continued from another: the result
     * reassembles to a plausible length and decrypts to nothing. (Observed on Apple: windows 0-2 from
     * one relay's seal plus 3-4 from another's produced 40,352,062 bytes against a manifest declaring
     * 40,342,326, and failed to open for every circle.) The manifest encodes the per-window sizes and
     * the total, so hashing it distinguishes the seals. Mirror of iOS `SharedStore.manifestFingerprint`
     * and desktop `manifest_fingerprint`.
     */
    private fun manifestFingerprint(head: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(head)
            .joinToString("") { "%02x".format(it) }.take(16)

    /**
     * Leading chunks of THIS seal already in the .part file. [fp] is what makes that "of this seal"
     * rather than merely "of something with the same number of windows" — see [manifestFingerprint].
     * A sidecar written by an older build carries no fingerprint and so fails the match and restarts,
     * which is the safe direction.
     */
    private fun loadRestorePart(ref: String, chunks: Int, fp: String): Int = runCatching {
        val meta = restoreMetaFile(ref).takeIf { it.exists() }?.readText()?.trim() ?: return 0
        val parts = meta.split(':')
        val c = parts.getOrNull(0)?.toIntOrNull()
        val got = parts.getOrNull(1)?.toIntOrNull()
        val recordedFp = parts.getOrNull(2) ?: ""
        if (c != chunks || recordedFp != fp || got == null || got <= 0 || got > chunks) return 0
        if (!restorePartFile(ref).exists()) return 0
        got
    }.getOrDefault(0)
    private fun saveRestorePart(ref: String, chunks: Int, got: Int, fp: String) {
        runCatching { restoreMetaFile(ref).writeText("$chunks:$got:$fp") }
    }
    private fun clearRestorePart(ref: String) {
        runCatching { restorePartFile(ref).delete() }
        runCatching { restoreMetaFile(ref).delete() }
    }
    /** Reclaim abandoned partials (untouched > 7 days) — cheap, once per process. */
    @Volatile private var sweptRestoreParts = false
    private fun sweepRestorePartsOnce() {
        if (sweptRestoreParts) return
        sweptRestoreParts = true
        scope.launch {
            runCatching {
                val cutoff = System.currentTimeMillis() - 7L * 86_400_000
                restorePartsDir().listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
            }
        }
    }

    /**
     * Persist a fetched media [head] for [ref]. If [head] is a chunk manifest, fetch each chunk via
     * [getChunk] and APPEND it to a PERSISTENT .part file on disk (streaming — the full sealed blob
     * is never held in RAM), then adopt it. Otherwise [head] IS the sealed blob (legacy/small).
     * RESUMABLE: the sidecar records how many leading chunks landed, so a retry after a mid-download
     * failure fetches only the missing chunks instead of restarting a multi-hundred-MB pull.
     * Returns false on any missing chunk so the caller can try the next relay (the partial is KEPT).
     */
    private suspend fun reassembleInto(ref: String, head: ByteArray, getChunk: suspend (Int) -> ByteArray?): Boolean {
        val count = parseManifest(head)
        if (count == null) { LocalMedia.writeRawSealed(ref, head); return true }
        sweepRestorePartsOnce()
        // Every window of this reassembly must come from ONE seal — see [manifestFingerprint]. The
        // caller retries against the NEXT relay's own head on failure, and a fingerprint mismatch
        // restarts the partial rather than silently splicing two envelopes together.
        val fp = manifestFingerprint(head)
        val part = restorePartFile(ref)
        var have = loadRestorePart(ref, count, fp)
        if (have == 0) {
            // No (valid) partial — start fresh.
            runCatching { part.delete() }
            runCatching { part.createNewFile() }
        } else {
            android.util.Log.i("MediaSync", "reassemble ref=$ref resuming at chunk $have/$count")
        }
        for (i in have until count) {
            val chunk = getChunk(i)
            if (chunk == null || !LocalMedia.appendSealedPart(part, chunk)) {
                // KEEP the partial + sidecar — the next attempt resumes from `have`.
                clearRestoreProgress(ref)
                android.util.Log.i("MediaSync", "reassemble ref=$ref STALLED at chunk $i/$count — partial kept for resume")
                return false
            }
            have = i + 1
            saveRestorePart(ref, count, have, fp)
            noteRestoreProgress(ref, have, count)   // honest i/n for the placeholder
        }
        clearRestoreProgress(ref)
        val ok = LocalMedia.adoptSealedPart(ref, part)
        clearRestorePart(ref)
        android.util.Log.i("MediaSync", "reassemble ref=$ref chunks=$count adopted=$ok")
        return ok
    }

    /** Refs whose relay backup a direct ask has already prompted us to re-check. */
    private val backupReverifiedAt = LinkedHashMap<String, Long>()

    /**
     * A peer asked us DIRECTLY for a blob we hold — meaning they could not fetch it from any relay we
     * share. That is the only signal in the system that a STORED copy has gone bad, and until now
     * nothing listened to it: the backup ledger is write-once, so a relay copy that is missing chunks
     * stays missing forever while this device goes on showing the post as safely backed up.
     *
     * Throttled to once an hour per ref — an unreachable peer re-asks on a timer, and a re-verify must
     * never become a re-upload storm. Deliberately NOT `force`: this is a probe, and it re-uploads
     * only the windows a destination actually turns out to lack (see [holdsCompleteBlob]).
     * Apple parity: `FeedStore.reverifyBackupAfterDirectAsk`.
     */
    private fun reverifyBackupAfterDirectAsk(ref: String) {
        if (LocalMedia.isSynthetic(ref)) return
        // `System.currentTimeMillis()`, not `nowMs()` — the latter is ULong (it feeds the FFI's
        // timestamps); this is a plain wall-clock throttle, like `mediaServedAt`.
        val now = System.currentTimeMillis()
        synchronized(backupReverifiedAt) {
            val at = backupReverifiedAt[ref]
            if (at != null && now - at < 3_600_000L) return
            backupReverifiedAt[ref] = now
            while (backupReverifiedAt.size > 2_000) {
                val it = backupReverifiedAt.iterator(); it.next(); it.remove()
            }
        }
        val circleId = runCatching {
            social.circles().firstOrNull { c ->
                social.feed(c.id, nowMs(), null).any { item ->
                    item.media.contains(ref) || item.comments.any { it.media.contains(ref) }
                }
            }?.id
        }.getOrNull() ?: return
        forgetBackedUpRef(ref)   // the verdict we're re-testing
        Log.i("MediaSync", "media REQ ${ref.take(10)}: asked directly for media we backed up — re-probing its relay copies")
        enqueueBackup(circleId, ref)
    }

    /** Frame 3: [hex64 requester][ref]. If we hold the bytes, stream them back as sealed chunks. */
    private fun handleMediaRequest(body: ByteArray) {
        if (body.size <= 64) return
        val requester = String(body.copyOfRange(0, 64), Charsets.UTF_8)
        if (requester.length != 64) return
        val ref = String(body.copyOfRange(64, body.size), Charsets.UTF_8)
        if (ref.isEmpty() || !LocalMedia.has(ref)) return
        // They had to come to US for bytes we already backed up — so no relay served them. That is a
        // signal about our own backup, not just a request to answer.
        reverifyBackupAfterDirectAsk(ref)
        // Rate-limit: a waiting requester re-asks every cycle, so without this we re-served the same blobs
        // hundreds of times and flooded the send queue so nothing drained. One serve per ref per 25s.
        if (!shouldServeNearby(ref)) return
        val bytes = LocalMedia.loadAnyCircle(ref) ?: return
        serveOnce(ref, requester) { sendMediaChunks(ref, bytes, requester) }
    }

    /**
     * Serves currently streaming, keyed `ref|requester`.
     *
     * A serve is slow by construction, so the requester re-asks while it waits — and without this that
     * second request happily started ANOTHER full serve of the same file. Three or four pile up,
     * compete for the same link, and none of them finishes, so the media never arrives and the
     * requester asks again. Forever. (iOS hit exactly this: one video re-requested 16 times in 20
     * minutes; fixed there in c67226c.) During a transfer, doing nothing IS the correct response —
     * the bytes are already on their way, and if they stop, the resume request picks up the holes.
     */
    private val servingNow = HashSet<String>()

    /** Run [body] as the one serve for this (ref, requester), or drop it if one is already running. */
    private fun serveOnce(ref: String, requesterHex: String, body: suspend () -> Unit) {
        val key = "$ref|$requesterHex"
        synchronized(servingNow) {
            if (!servingNow.add(key)) {
                Log.i("MediaSync", "serve ref=${ref.take(12)} — already streaming to ${requesterHex.take(8)}, ignoring")
                return
            }
        }
        scope.launch {
            try { body() } finally { synchronized(servingNow) { servingNow.remove(key) } }
        }
    }

    /**
     * Stream [bytes] to [requesterHex] as individually-sealed 32KB chunks. OWN-device requests (the
     * requester is my own account) are symmetric-sealed with the account-derived key so they ALWAYS open
     * on a sibling (KEM-to-self decap is unreliable); a friend requester gets a per-recipient KEM seal.
     * Runs on the IO scope — file read + seal happen off the main thread (heavy streaming caused severe
     * UI lag on iOS when on-main). iOS sendMediaChunks parity.
     *
     * [missing] (from a resume request, frame 33) restricts the stream to the chunks the requester
     * says it still needs. Skipping costs nothing — no copy, no seal, no send — so a transfer that
     * died on its last chunk costs one chunk to finish rather than the whole file again. Null sends
     * everything, which is what a first request (frame 3) always means.
     */
    private suspend fun sendMediaChunks(
        ref: String, bytes: ByteArray, requesterHex: String, missing: Set<Int>? = null,
    ) {
        val total = maxOf(1, (bytes.size + mediaChunkSize - 1) / mediaChunkSize)
        SyncMetrics.incOut()   // a media item is being served/pushed (iOS nbMediaOut += 1)
        val refBytes = ref.toByteArray(Charsets.UTF_8)
        val isOwn = runCatching { social.myNodeHex() }.getOrNull() == requesterHex
        var index = 0
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + mediaChunkSize, bytes.size)
            if (missing != null && index !in missing) { offset = end; index++; continue }
            val chunk = bytes.copyOfRange(offset, end)
            val sealed = if (isOwn) sealOwnMedia(chunk) else runCatching { social.sealMedia(requesterHex, chunk) }.getOrNull()
            if (sealed == null) {
                // A failed seal abandons the transfer MID-FILE, leaving the requester with a partial
                // set it can't complete on its own — say which chunk rather than stopping silently.
                // (With resume that partial is no longer a dead end: it re-asks for exactly the holes.)
                Log.w("MediaSync", "serve ref=${ref.take(12)} → ${requesterHex.take(8)}: seal FAILED at chunk $index; transfer abandoned")
                return
            }
            sendFrameAwait(Wire.MEDIA_CHUNK, chunkFrame(refBytes, index, total, sealed), requesterHex)
            offset = end; index++
        }
    }

    private fun chunkFrame(refBytes: ByteArray, index: Int, total: Int, sealed: ByteArray): ByteArray {
        val out = ArrayList<Byte>(2 + refBytes.size + 8 + sealed.size)
        out.add((refBytes.size and 0xFF).toByte()); out.add(((refBytes.size ushr 8) and 0xFF).toByte())
        refBytes.forEach { out.add(it) }
        for (v in intArrayOf(index, total)) {
            out.add((v and 0xFF).toByte()); out.add(((v ushr 8) and 0xFF).toByte())
            out.add(((v ushr 16) and 0xFF).toByte()); out.add(((v ushr 24) and 0xFF).toByte())
        }
        sealed.forEach { out.add(it) }
        return out.toByteArray()
    }

    /** Frame 5: reassemble sealed chunks; store the media when complete. */
    private fun handleMediaChunk(body: ByteArray) {
        if (body.size < 2) return
        val refLen = (body[0].toInt() and 0xFF) or ((body[1].toInt() and 0xFF) shl 8)
        if (body.size < 2 + refLen + 8) return
        val ref = String(body.copyOfRange(2, 2 + refLen), Charsets.UTF_8)
        var off = 2 + refLen
        fun u32(): Int {
            val v = (body[off].toInt() and 0xFF) or ((body[off + 1].toInt() and 0xFF) shl 8) or
                ((body[off + 2].toInt() and 0xFF) shl 16) or ((body[off + 3].toInt() and 0xFF) shl 24)
            off += 4; return v
        }
        val index = u32(); val total = u32()
        val sealed = body.copyOfRange(off, body.size)
        // Bound every peer-controlled field before it indexes a file offset or sizes an allocation.
        if (ref.isEmpty() || total <= 0 || total > MediaResume.MAX_CHUNKS) return
        if (index < 0 || index >= total) return
        if (LocalMedia.has(ref)) return
        // Own-device chunks are symmetric (account-key) sealed; friend chunks are KEM. Try the cheap
        // symmetric open first, then fall back to the engine's KEM open. iOS handleMediaChunk parity.
        val plain = openOwnMedia(sealed) ?: runCatching { social.openMedia(sealed) }.getOrNull() ?: return
        // An over-long chunk would spill past its slot and corrupt the NEXT chunk's bytes, which the
        // content-address check would then blame on the whole transfer. Refuse it instead.
        if (plain.isEmpty() || plain.size > mediaChunkSize) return
        val entry = synchronized(incomingLock) {
            val existing = incomingMedia[ref]
            if (existing != null && existing.total == total) existing else {
                // A total that disagrees with the one we're reassembling against means the sender is
                // serving different bytes — the old partial's indices point at a different file, so
                // start clean rather than interleaving two files into one.
                existing?.let { runCatching { it.part.delete() } }
                val fresh = IncomingMedia(LocalMedia.newPlainPart(ref), total)
                incomingMedia[ref] = fresh
                // Registered the moment it starts, so even a transfer interrupted seconds in has a
                // durable home to resume into (and the orphan sweep knows to spare its part file).
                ReassemblyStore.note(ref, fresh.part.name, total, MediaResume.bitmap(emptySet(), total), force = true)
                fresh
            }
        }
        // Bytes FIRST, bookkeeping second — and never the other way round. Persisted progress may lag
        // the file (ReassemblyStore debounces), and that is only safe in one direction: understating
        // what we hold costs one re-sent chunk, while recording a chunk we never wrote would leave a
        // hole nothing ever asks for again.
        if (!LocalMedia.writePartAt(entry.part, index.toLong() * mediaChunkSize, plain)) return
        val complete = synchronized(incomingLock) {
            entry.got.add(index)
            if (entry.got.size < entry.total) {
                ReassemblyStore.note(ref, entry.part.name, entry.total, MediaResume.bitmap(entry.got, entry.total))
                false
            } else {
                incomingMedia.remove(ref)   // detach first so a failure below can't leak the entry
                true
            }
        }
        if (!complete) return
        // Whether the adopt succeeds or rejects the bytes on a digest mismatch, this reassembly is
        // over: on rejection the part file is already gone, so leaving the record behind would
        // resurrect a bitmap whose bytes no longer exist and stall the ref forever.
        val ok = LocalMedia.adoptPlainPart(DEFAULT_CIRCLE, ref, entry.part)
        ReassemblyStore.clear(ref)
        if (!ok) return
        SyncMetrics.incIn()   // a media item was fully received + stored (iOS nbMediaIn += 1)
        scope.launch(Dispatchers.Main) { feedVersion.value++ }
        // "Save others' posts to Photos" — per-circle override (received media stores under the
        // default circle), falling back to the app-wide default.
        if (CircleSettings.saveOthers(DEFAULT_CIRCLE)) scope.launch { MediaSaver.autoSave(appContext, ref) }
    }

    /**
     * Frame 33 — a RESUME request: serve only the chunks the requester says it is still missing.
     *
     * Skipping is free (no copy, no seal, no send), so finishing a transfer that died on its last
     * chunk costs one chunk instead of the whole file again. Frame 3 is untouched and still means
     * "send everything", which is what a first request always means and what every un-upgraded peer
     * in the field will keep sending.
     */
    private fun handleMediaResumeRequest(body: ByteArray) {
        val req = MediaResume.decode(body) ?: return
        if (!LocalMedia.has(req.ref)) return
        if (!shouldServeNearby(req.ref)) return
        val bytes = LocalMedia.loadAnyCircle(req.ref) ?: return
        val total = maxOf(1, (bytes.size + mediaChunkSize - 1) / mediaChunkSize)
        // A declared total that disagrees with ours means their partial was built against different
        // bytes, so their bitmap indexes something else and honouring it would leave permanent holes.
        // Send everything and let the content-address check at adopt decide which copy is real.
        // Expanding their bitmap only HERE — after the totals agree — is what bounds the work by a file
        // we hold rather than by the chunk count the peer declared (see MediaResume.Request).
        val missing = if (total == req.total) {
            val theirs = MediaResume.indices(req.bitmap, total)
            (0 until total).filterNot { it in theirs }.toSet()
        } else null
        if (missing != null && missing.isEmpty()) return   // they have it all; the last chunk is in flight
        Log.i("MediaSync", "resume ref=${req.ref.take(12)} from=${req.requesterHex.take(8)}: ${missing?.size ?: total}/$total chunks still needed")
        serveOnce(req.ref, req.requesterHex) { sendMediaChunks(req.ref, bytes, req.requesterHex, missing) }
    }

    /**
     * Ask for [ref]: frame 33 with our bitmap when we hold a partial, else the plain frame 3.
     *
     * An un-upgraded peer drops frame 33 on the floor and says nothing, so silence is the only signal
     * we get — hence the timed fallback to a full request. ONE bounded coroutine per ref (see
     * [resumeFallbackPending]); a peer re-requesting cannot pile these up.
     */
    private fun askForMedia(ref: String, plainPayload: ByteArray, targets: List<String>) {
        val myHex = nodeIdHex
        val resume = synchronized(incomingLock) {
            val e = incomingMedia[ref]
            if (e == null || e.got.isEmpty() || e.total <= 0) null
            else MediaResume.encode(myHex, ref, e.total, e.got)
        }
        // MY OWN DEVICES GET THE ASK TOO. [targets] is the contact list, and my own devices are not
        // contacts — they live in the account's device roster. Without this a phone and a desktop on
        // the same account could each be holding what the other needs, both online, with no lane
        // between them: the fetch just kept "asking peers" that could never answer. (Apple parity:
        // `FeedStore.askForMedia`.)
        if (resume == null) {
            for (idHex in targets) sendFrame(Wire.MEDIA_REQ, plainPayload, idHex)
            liveDeliverToMyDevices(Wire.MEDIA_REQ, plainPayload)
            return
        }
        for (idHex in targets) sendFrame(Wire.MEDIA_RESUME_REQ, resume, idHex)
        liveDeliverToMyDevices(Wire.MEDIA_RESUME_REQ, resume)
        val before = synchronized(incomingLock) {
            if (!resumeFallbackPending.add(ref)) return
            incomingMedia[ref]?.got?.size ?: 0
        }
        scope.launch {
            kotlinx.coroutines.delay(8_000)
            synchronized(incomingLock) { resumeFallbackPending.remove(ref) }
            if (LocalMedia.has(ref)) return@launch
            if (synchronized(incomingLock) { incomingMedia[ref]?.got?.size ?: 0 } != before) return@launch
            Log.i("MediaSync", "resume ref=${ref.take(12)}: no answer to frame 33 — falling back to a full request")
            for (idHex in targets) sendFrame(Wire.MEDIA_REQ, plainPayload, idHex)
            liveDeliverToMyDevices(Wire.MEDIA_REQ, plainPayload)
        }
    }

    /** Pick half-finished transfers back up at launch instead of restarting them from chunk 0.
     *  Must run BEFORE anything can sweep scratch, or the 99%-complete file is deleted as an orphan. */
    private fun restoreReassemblies() {
        for (r in runCatching { ReassemblyStore.restore() }.getOrDefault(emptyList())) {
            val part = LocalMedia.partFile(r.part)
            // Adopted while we were away (relay restore, a sibling device) — drop the scratch.
            if (LocalMedia.has(r.ref)) {
                runCatching { part.delete() }
                ReassemblyStore.clear(r.ref)
                continue
            }
            val got = MediaResume.indices(r.got, r.total)
            synchronized(incomingLock) {
                incomingMedia[r.ref] = IncomingMedia(part, r.total).also { it.got.addAll(got) }
            }
            Log.i("MediaSync", "resume restored ref=${r.ref.take(12)}: ${got.size}/${r.total} chunks already on disk")
        }
    }

    /**
     * Send a frame and WAIT for it, instead of firing a coroutine that outlives the caller.
     *
     * [sendFrame] launches per call, which is right for one-off frames and very wrong for a serve
     * loop: a 200 MB video is ~6,400 chunks, each launching a coroutine holding its own 32 KB frame
     * copy, for every device on the roster. Nothing awaited them, so the loop ran to completion in
     * milliseconds and left tens of thousands of queued sends holding the entire file in memory —
     * an unbounded backlog that gets worse the slower the link is.
     *
     * Awaiting each send makes the serve loop self-pacing: it cannot outrun the transport, memory
     * stays at one chunk, and the rate matches the actual link rather than a fixed sleep (which would
     * be both slower than necessary on a fast link and still unbounded on a slow one).
     */
    private suspend fun sendFrameAwait(type: Int, payload: ByteArray, toNodeHex: String) {
        val n = node ?: return
        val frame = Wire.frame(type, payload)
        val targets = LinkedHashSet(
            runCatching { social.deviceNodeIdsFor(toNodeHex) }
                .getOrNull()?.takeIf { it.isNotEmpty() } ?: listOf(toNodeHex)
        )
        targets.addAll(deviceHintsFor(toNodeHex))
        for (t in targets) runCatching { n.sendToNode(t, frame) }
    }

    private fun sendFrame(type: Int, payload: ByteArray, toNodeHex: String) {
        val n = node ?: return
        val frame = Wire.frame(type, payload)
        scope.launch {
            // Transport edge (parity with iOS sendIroh): callers address an ACCOUNT id so the
            // social/allow logic stays on account ids; expand to that account's authorized DEVICE
            // ids here — under device-seed transport the account id alone resolves to NO node, so
            // an unexpanded send (calls' accept/ICE, media requests) silently reaches nobody.
            // deviceNodeIdsFor is identity for an unknown/device-id input, so pre-expanded callers
            // (dialTargets) stay correct.
            val targets = LinkedHashSet(
                runCatching { social.deviceNodeIdsFor(toNodeHex) }
                    .getOrNull()?.takeIf { it.isNotEmpty() } ?: listOf(toNodeHex)
            )
            // Invite-link dial hints bridge the roster bootstrap: until this contact's signed
            // roster lands, their account id resolves to no node — the hint is the only real id.
            targets.addAll(deviceHintsFor(toNodeHex))
            var lastErr: String? = null
            var anyOk = false
            for (t in targets) {
                runCatching { n.sendToNode(t, frame) }
                    .onSuccess { anyOk = true }
                    .onFailure { lastErr = it.message }
            }
            if (!anyOk) Log.d(TAG, "send type=$type to ${toNodeHex.take(8)} failed: $lastErr")
        }
    }

    // ---- Persistence ---------------------------------------------------------------------

    private fun persist() {
        runCatching { stateFile.writeBytes(social.exportState()) }
            .onFailure { Log.e(TAG, "persist failed", it) }
    }

    private fun restoreState() {
        // Migrate the old shared (un-keyed) state into THIS identity's keyed file once, then delete
        // the shared file so no future identity can pick it up.
        if (!stateFile.exists() && legacyStateFile.exists()) {
            runCatching { social.importState(legacyStateFile.readBytes()) }
            runCatching { stateFile.writeBytes(social.exportState()) }
            runCatching { legacyStateFile.delete() }
            return
        }
        if (stateFile.exists()) {
            runCatching { social.importState(stateFile.readBytes()) }
                .onFailure { Log.e(TAG, "restore failed", it) }
        }
    }

    private fun loadContacts() {
        val raw = prefs.getString("contacts", null) ?: return
        runCatching {
            val arr = JSONArray(raw)
            contacts.clear()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                contacts.add(Contact(o.getString("id"), o.getString("name"), o.optString("v", "")))
            }
        }
    }

    private fun saveContacts() {
        val arr = JSONArray()
        contacts.forEach { arr.put(JSONObject().put("id", it.idHex).put("name", it.name).put("v", it.verifyHex)) }
        prefs.edit().putString("contacts", arr.toString()).apply()
    }

    private fun loadBlocked() {
        val raw = prefs.getString("blocked", null) ?: return
        runCatching {
            val arr = JSONArray(raw)
            blocked.clear()
            for (i in 0 until arr.length()) blocked.add(arr.getString(i))
        }
    }

    private fun saveBlocked() {
        val arr = JSONArray()
        blocked.forEach { arr.put(it) }
        prefs.edit().putString("blocked", arr.toString()).apply()
    }

    /**
     * Load the redundant relay set. New format is `relays` (circleId -> JSON array of node hexes).
     * The legacy `relayNodes` (circleId -> single node hex string) is migrated in idempotently:
     * each legacy entry is appended to the list if not already present. The migration re-runs
     * harmlessly on every load until the next [saveRelayNodes] clears the legacy key.
     */
    private fun loadRelayNodes() {
        relayNodes.clear()
        suppressedRelays.clear()
        forgotAtRelays.clear()
        clearedRelayForgets.clear()
        relayEntries.clear()
        defaultRelayHex = prefs.getString("relayDefault", "") ?: ""
        prefs.getString("relaysSuppressed", null)?.let { raw ->
            runCatching { val a = JSONArray(raw); for (i in 0 until a.length()) suppressedRelays.add(a.getString(i)) }
        }
        prefs.getString("relaysForgotAt", null)?.let { raw ->
            runCatching { val o = JSONObject(raw); o.keys().forEach { k -> forgotAtRelays[k] = o.getLong(k) } }
        }
        prefs.getString("relaysClearedForgot", null)?.let { raw ->
            runCatching { val o = JSONObject(raw); o.keys().forEach { k -> clearedRelayForgets[k] = o.getLong(k) } }
        }
        // MIGRATION: relays deleted BEFORE the deletion-timestamp existed are in `suppressed` but have no
        // `forgotAt`. Without a deletion time the LWW gate can't tell a real re-add from a mere reopen, so
        // those old deletions leaked back. Stamp them "deleted now" so a re-announce carrying the relay's
        // ORIGINAL (older) adoption time loses. Mirrors iOS. */
        run {
            var migrated = false
            val nowStamp = relayNow()
            for (hex in suppressedRelays) if (forgotAtRelays[hex] == null) { forgotAtRelays[hex] = nowStamp; migrated = true }
            if (migrated) saveRelayNodes()
        }
        // New multi-relay format.
        prefs.getString("relays", null)?.let { raw ->
            runCatching {
                val o = JSONObject(raw)
                o.keys().forEach { cid ->
                    val arr = o.getJSONArray(cid)
                    val list = mutableListOf<String>()
                    for (i in 0 until arr.length()) {
                        val hex = arr.getString(i)
                        if (hex.isNotEmpty() && !list.contains(hex)) list.add(hex)
                    }
                    if (list.isNotEmpty()) relayNodes[cid] = list
                }
            }
        }
        // Idempotent migration of the legacy single-relay-per-circle map.
        prefs.getString("relayNodes", null)?.let { raw ->
            runCatching {
                val o = JSONObject(raw)
                o.keys().forEach { cid ->
                    val hex = o.getString(cid)
                    if (hex.isNotEmpty()) {
                        val list = relayNodes.getOrPut(cid) { mutableListOf() }
                        if (!list.contains(hex)) list.add(hex)
                    }
                }
            }
        }
        // Load persisted per-relay RelayEntry records (deactivate-not-erase metadata).
        prefs.getString("relayEntries", null)?.let { raw ->
            runCatching {
                val a = JSONArray(raw)
                for (i in 0 until a.length()) {
                    val o = a.getJSONObject(i)
                    val hex = o.getString("hex")
                    relayEntries[hex] = RelayEntry(
                        hex = hex,
                        name = o.optString("name", shortRelayName(hex)),
                        active = o.optBoolean("active", true),
                        lastSeenMs = o.optLong("lastSeenMs", relayNow()),
                        isS3 = o.optBoolean("isS3", hex.startsWith("s3:")),
                        httpUrls = o.optJSONArray("httpUrls")?.let { a ->
                            (0 until a.length()).mapNotNull { i -> a.optString(i).takeIf { it.isNotEmpty() } }
                        } ?: emptyList(),
                        httpToken = o.optString("httpToken", ""),
                        addedAtMs = o.optLong("addedAtMs", 0L),
                        derpUrl = o.optString("derpUrl", "").trim().trimEnd('/'),
                        turnUrls = o.optJSONArray("turnUrls")?.let { a ->
                            (0 until a.length()).mapNotNull { i ->
                                a.optString(i).takeIf { u -> u.startsWith("turn:") || u.startsWith("turns:") }
                            }
                        } ?: emptyList(),
                        turnUser = o.optString("turnUser", ""),
                        turnPass = o.optString("turnPass", ""),
                    )
                }
            }
        }
        prefs.getString("relaysErased", null)?.let { raw ->
            runCatching {
                val a = JSONArray(raw)
                for (i in 0 until a.length()) {
                    val o = a.getJSONObject(i)
                    val hex = o.getString("hex")
                    erasedRelays[hex] = ErasedRelay(
                        entry = RelayEntry(
                            hex = hex,
                            name = o.optString("name", shortRelayName(hex)),
                            active = false,
                            lastSeenMs = o.optLong("erasedAt", relayNow()),
                            isS3 = o.optBoolean("isS3", hex.startsWith("s3:")),
                            httpUrls = o.optJSONArray("httpUrls")?.let { arr ->
                                (0 until arr.length()).mapNotNull { j -> arr.optString(j).takeIf { it.isNotEmpty() } }
                            } ?: emptyList(),
                            httpToken = o.optString("httpToken", ""),
                            derpUrl = o.optString("derpUrl", ""),
                        ),
                        circles = o.optJSONArray("circles")?.let { arr ->
                            (0 until arr.length()).mapNotNull { j -> arr.optString(j).takeIf { it.isNotEmpty() } }
                        } ?: emptyList(),
                        wasDefault = o.optBoolean("wasDefault", false),
                        erasedAt = o.optLong("erasedAt", relayNow()),
                    )
                }
                pruneErasedRelays()
            }
        }
        // Migrate any relay that only exists in relayNodes/the default into a RelayEntry.
        migrateRelayEntries()
        refreshHavenFabric()
    }

    /**
     * Push live DERP URLs into SharedPreferences for [CallManager] ICE **and** into the Rust
     * process policy via [uniffi.haven_ffi.applyDerpUrls]. Also persists circle TURN for WebRTC.
     * When a messaging node is already live on a different map, schedules a debounced soft rebind.
     */
    private fun refreshHavenFabric() {
        if (!this::appContext.isInitialized) return
        val urls = activeFabricUrls()
        val turnUrls = linkedSetOf<String>()
        var turnUser = ""
        var turnPass = ""
        for (e in relayEntries.values) {
            if (!e.active || e.turnUrls.isEmpty()) continue
            turnUrls.addAll(e.turnUrls)
            if (turnUser.isEmpty() && e.turnUser.isNotEmpty() && e.turnPass.isNotEmpty()) {
                turnUser = e.turnUser
                turnPass = e.turnPass
            }
        }
        appContext.getSharedPreferences("haven.fabric", android.content.Context.MODE_PRIVATE)
            .edit()
            .putStringSet("derpUrls", urls.toSet())
            .putStringSet("turnUrls", turnUrls)
            .putString("turnUser", turnUser)
            .putString("turnPass", turnPass)
            .apply()
        // Sorted list for stable policy; empty → n0 only.
        runCatching { uniffi.haven_ffi.applyDerpUrls(urls) }
        scheduleFabricRebindIfNeeded(urls)
    }

    /**
     * DERP bases we have WATCHED fail. Excluded from the fabric until the cool-down expires.
     *
     * A custom DERP that is merely *configured* was treated as a working one, and that is how a
     * single stale hostname took the whole device offline: a free-tunnel URL rotates, iroh stays
     * pinned to the dead one, peers never rendezvous, and everything downstream of p2p — contact
     * announces (which carry the NEW hostname), DMs, media — stops. Every recovery path needed the
     * fabric that the dead URL had just broken, so nothing could climb out.
     *
     * Dropping a dead base is safe in the direction that matters: [refreshHavenFabric] falls back
     * to n0 when the list is empty, so the worst case of a false positive is public rendezvous
     * instead of the NAS's — which is exactly how the device re-learns the new hostname and gets
     * its own fabric back.
     */
    private val derpDeadUntilMs = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val DERP_DEAD_MS = 300_000L

    /** The front door answered — it is a relay, not a rotated hostname. */
    fun noteFabricBaseAlive(url: String) { derpDeadUntilMs.remove(url.trimEnd('/')) }

    /** The front door did not answer as a relay. Stand it down so the fabric can fall back to n0. */
    private fun noteFabricBaseDead(url: String) {
        val u = url.trimEnd('/')
        if (u.isEmpty()) return
        val prev = derpDeadUntilMs.put(u, System.currentTimeMillis() + DERP_DEAD_MS)
        if (prev == null || prev < System.currentTimeMillis()) {
            Log.i(TAG, "fabric base $u looks gone — falling back to n0 rendezvous so peers can " +
                "reach us again (and so an announce can teach us the current hostname)")
            refreshHavenFabric()
        }
    }

    private fun fabricBaseAlive(url: String): Boolean {
        val u = url.trimEnd('/')
        if ((derpDeadUntilMs[u] ?: 0L) > System.currentTimeMillis()) return false
        // Reuse what the HTTP layer already learned. DERP and the front door are the SAME hostname,
        // so a base sitting in the http bad-window is a base we have just failed to reach — and
        // that is precisely when rendezvous must not stay pinned to it. Without this the evidence
        // existed and went unused: once the URL was marked bad, `httpUrlsFor` returned empty, the
        // HTTP branch stopped running altogether, and nothing was left to notice the host was gone.
        val bad = httpUrlBad[u] ?: httpUrlBad[url] ?: 0L
        return bad <= System.currentTimeMillis()
    }

    private fun activeFabricUrls(): List<String> =
        relayEntries.values
            .filter { it.active && it.derpUrl.isNotEmpty() && fabricBaseAlive(it.derpUrl) }
            .map { it.derpUrl }
            .toSortedSet()
            .toList()

    private fun scheduleFabricRebindIfNeeded(urls: List<String>) {
        if (node == null || urls.isEmpty() || urls == fabricBoundUrls || fabricRebindInFlight) return
        val gen = synchronized(this) { fabricRebindGen += 1; fabricRebindGen }
        Log.i(TAG, "fabric rebind scheduled (urls=${urls.size})")
        scope.launch {
            delay(2_000)
            if (gen != fabricRebindGen) return@launch
            rebindTransportForFabric()
        }
    }

    /**
     * Stop the messaging node fully, re-apply fabric, start again, re-attach relay host if needed.
     * Must not dual-bind the same device seed (iroh same-key scar).
     */
    private suspend fun rebindTransportForFabric() {
        if (fabricRebindInFlight) return
        val target = activeFabricUrls()
        if (target.isEmpty() || target == fabricBoundUrls) return
        fabricRebindInFlight = true
        try {
            Log.i(TAG, "fabric rebind starting…")
            val wasHosting = relayHost != null
            if (wasHosting) {
                runCatching { relayHost?.disable() }
                relayHost = null
                withContext(Dispatchers.Main) { hosting.value = false }
            }
            val old = node
            node = null
            withContext(Dispatchers.Main) { started.value = false; internetActive.value = false }
            if (old != null) {
                runCatching { old.shutdown() }
                delay(250)
            }
            runCatching { uniffi.haven_ffi.applyDerpUrls(activeFabricUrls()) }
            node = HavenNode.start(DeviceKeyStore.deviceAccount().secretSeed(), this@HavenNet)
            fabricBoundUrls = activeFabricUrls()
            withContext(Dispatchers.Main) { started.value = true; internetActive.value = true }
            Log.i(TAG, "fabric rebind ok urls=${fabricBoundUrls.size}")
            publishAccountDevices()   // the record is per-endpoint - re-publish on the new node
            if (wasHosting) {
                // Light re-attach (same as startHosting but without re-adopt storm).
                val n = node
                if (n != null) {
                    val dir = File(appContext.filesDir, "relay").apply { mkdirs() }.absolutePath
                    val h = runCatching {
                        uniffi.haven_ffi.RelayServerHandle.attachWithLimits(
                            n, dir,
                            relayMediaMaxAgeDays.toUInt(),
                            relayMediaMaxBytes.toULong(),
                        )
                    }.getOrNull()
                    if (h != null) {
                        relayHost = h
                        withContext(Dispatchers.Main) { hosting.value = true }
                        authorizeMembership()
                        val token = relayHttpToken()
                        runCatching { h.serveHttp("0.0.0.0:$RELAY_HTTP_PORT", token) }
                            .recoverCatching { h.serveHttp("0.0.0.0:0", token) }
                        reannounceOwnRelay()
                    }
                }
            } else {
                reannounceOwnRelay()
            }
            syncWithContacts()
            // Catch learns that arrived during rebind.
            scheduleFabricRebindIfNeeded(activeFabricUrls())
        } catch (e: Throwable) {
            Log.e(TAG, "fabric rebind failed", e)
        } finally {
            fabricRebindInFlight = false
        }
    }

    /** QA driver only (DEBUG): wire a relay entry + make it the all-circles default — the same
     *  state a sealed announce builds, minus the announce. Prefs-file surgery from the harness
     *  raced the app's own rewrites (the classic silent no-relay leg); going through this API
     *  is authoritative and persists like any UI-adopted relay. [derp] mirrors the announce's
     *  `derp` field: without it the emulator has no addressing route to the stub's node id (no
     *  n0 record) and every iroh dial dies in discovery — refreshHavenFabric would also rewrite
     *  `haven.fabric` from the entries and wipe any hand-patched DERP set. */
    fun qaWireRelay(hex: String, urls: List<String>, token: String, derp: String = "") {
        val now = System.currentTimeMillis()
        relayEntries[hex] = RelayEntry(
            hex = hex, name = "QA wired", active = true, lastSeenMs = now, isS3 = false,
            httpUrls = urls, httpToken = token, addedAtMs = now,
            derpUrl = derp.trim().trimEnd('/'),
        )
        val list = relayNodes.getOrPut("default") { mutableListOf() }
        if (!list.contains(hex)) list.add(hex)
        defaultRelayHex = hex
        saveRelayNodes()
        if (derp.isNotBlank()) refreshHavenFabric()
        pollMailboxNow()
    }

    private fun saveRelayNodes() {
        val o = JSONObject()
        relayNodes.forEach { (k, v) -> o.put(k, JSONArray().apply { v.forEach { put(it) } }) }
        val entriesArr = JSONArray()
        relayEntries.values.forEach { e ->
            entriesArr.put(JSONObject().apply {
                put("hex", e.hex); put("name", e.name); put("active", e.active)
                put("lastSeenMs", e.lastSeenMs); put("isS3", e.isS3)
                if (e.httpUrls.isNotEmpty()) put("httpUrls", JSONArray(e.httpUrls))
                if (e.httpToken.isNotEmpty()) put("httpToken", e.httpToken)
                if (e.addedAtMs > 0) put("addedAtMs", e.addedAtMs)
                if (e.derpUrl.isNotEmpty()) put("derpUrl", e.derpUrl)
                if (e.turnUrls.isNotEmpty()) put("turnUrls", JSONArray(e.turnUrls))
                if (e.turnUser.isNotEmpty()) put("turnUser", e.turnUser)
                if (e.turnPass.isNotEmpty()) put("turnPass", e.turnPass)
            })
        }
        val erasedArr = JSONArray()
        erasedRelays.values.forEach { r ->
            erasedArr.put(JSONObject().apply {
                put("hex", r.entry.hex); put("name", r.entry.name); put("isS3", r.entry.isS3)
                put("erasedAt", r.erasedAt); put("wasDefault", r.wasDefault)
                put("circles", JSONArray(r.circles))
                if (r.entry.httpUrls.isNotEmpty()) put("httpUrls", JSONArray(r.entry.httpUrls))
                if (r.entry.httpToken.isNotEmpty()) put("httpToken", r.entry.httpToken)
                if (r.entry.derpUrl.isNotEmpty()) put("derpUrl", r.entry.derpUrl)
            })
        }
        val forgotAtJson = JSONObject().apply { forgotAtRelays.forEach { (k, v) -> put(k, v) } }
        val clearedForgotJson = JSONObject().apply { clearedRelayForgets.forEach { (k, v) -> put(k, v) } }
        // Write the new format and clear the legacy key (completes the migration).
        prefs.edit()
            .putString("relays", o.toString())
            .putString("relaysSuppressed", JSONArray().apply { suppressedRelays.forEach { put(it) } }.toString())
            .putString("relaysForgotAt", forgotAtJson.toString())
            .putString("relaysClearedForgot", clearedForgotJson.toString())
            .putString("relayEntries", entriesArr.toString())
            .putString("relaysErased", erasedArr.toString())
            .putString("relayDefault", defaultRelayHex)
            .remove("relayNodes").apply()
    }

    /** Whether any circle has a mailbox configured — Haven relay node or S3 pool (UI indicator). */
    fun hasRelay(): Boolean = relayNodes.values.any { it.isNotEmpty() } || Presign.anyBootstrap()

    fun reset() {
        contacts.clear(); pending.clear(); blocked.clear()
        initiated.clear(); initiatedAt.clear(); saveInitiated()
        relayNodes.clear(); relayClients.clear(); relayHealth.clear(); seenMailbox.clear()
        runCatching { seenMailboxFile.delete() }   // a new identity must not inherit the seen-set
        invalidateListDigests()   // a fresh seen-set must re-list everything (no 204 short-circuit)
        relayEntries.clear(); suppressedRelays.clear(); forgotAtRelays.clear(); clearedRelayForgets.clear(); erasedRelays.clear(); defaultRelayHex = ""
        Presign.reset()
        CircleLock.reset()
        AvatarStore.clear()
        DmRead.wipe()   // a new identity must not inherit read watermarks (or the old seed)
        relayActive.value = false
        activeCircle.value = DEFAULT_CIRCLE
        prefs.edit().clear().apply()
        runCatching { stateFile.delete() }
        runCatching { legacyStateFile.delete() }
        feedVersion.value++
    }

    val engine: HavenSocial get() = social

    // ---- Self-sync (multi-device convergence) accessors ----------------------------------
    //
    // The SelfSyncCoordinator runs inside pollMailbox() and reaches the relay transport + the
    // local stores through these. It is the Android counterpart of apple/HavenApp/SelfSync.swift;
    // all the surfaces it needs (private clients/health/relay set) are exposed here so the
    // coordinator stays a self-contained file.

    /** This device's account seed + node id (for sealing/slot keys). */
    val accountSeed: ByteArray get() = core.seed
    val accountBundle: ByteArray get() = core.bundle   // account PUBLIC bundle — opens rotated-key grants (§6)
    val accountNodeHex: String get() = core.nodeIdHex

    /** Every distinct adopted relay across all circles (public mirror of [allRelays]). */
    fun selfSyncRelays(): List<String> = allRelays()

    /** The relay node hexes that hold a given circle's mailbox (iOS RelayMailboxStore.relays(forCircle:)). */
    fun relaysForCircle(circleId: String): List<String> = relaysFor(circleId)

    /** How reachable a circle's posts are right now, for the composer's green/yellow/red light. */
    enum class SyncStatus { SYNCED, SYNCING, LOCAL }

    /** SYNCED = a relay holds it for offline members, or a nearby member is connected right now.
     *  SYNCING = the nearby mesh is up but no peer is connected yet. LOCAL = device-only (no relay,
     *  no mesh) — the post won't leave this device until one comes online. */
    fun syncStatus(circleId: String): SyncStatus = when {
        NearbyTransport.hasConnectedPeers() -> SyncStatus.SYNCED        // a member is right here
        relaysForCircle(circleId).isNotEmpty() -> SyncStatus.SYNCED     // a relay holds it for offline members
        internetActive.value -> SyncStatus.SYNCED                       // online: best-effort iroh delivery, no nag
        else -> SyncStatus.LOCAL                                        // offline + no relay/peer = device-only
    }

    /** Add a relay node to a circle's redundant set + persist (additive, never replaces). Used by self-sync. */
    fun selfSyncAddRelay(circleId: String, nodeHex: String) {
        val hex = nodeHex.trim().lowercase()
        if (hex.length != 64) return
        if (suppressedRelays.contains(hex) || !isRelayActive(hex)) return   // deactivated — don't auto-resurrect
        ensureRelayEntry(hex, isS3 = false, activate = false)
        val list = relayNodes.getOrPut(circleId) { mutableListOf() }
        if (!list.contains(hex)) { list.add(hex); saveRelayNodes() }
    }

    // ---- Relay deletion LWW self-sync (iOS SelfSync + RelayHost parity) -------------------------

    /** Every relay we've forgotten with its deletion ms — self-synced (as `relay-removal:<hex>` = 8-byte
     *  LE ms) so a deletion PROPAGATES to my other devices. iOS `forgottenRelays`. */
    fun relayForgottenRecords(): Map<String, Long> = HashMap(forgotAtRelays)

    /** Relays we deliberately re-added (hex → re-add ms) — self-synced (as `relay-readd:<hex>` = 8-byte LE
     *  ms) so a sibling's stale deletion tombstone can't re-forget them. iOS `clearedRelayForgetRecords`. */
    fun relayClearedForgetRecords(): Map<String, Long> = HashMap(clearedRelayForgets)

    /** Apply a relay-deletion tombstone learned from another of my devices (LWW): forget the relay locally
     *  IFF the sibling's deletion is NEWER than our own adoption / re-add of it — so a deletion on one
     *  device drops the relay on all of them, but a device that legitimately RE-ADDED it later keeps it.
     *  A passive re-announce NEVER auto-resurrects it (only an explicit re-add newer than this delete).
     *  Idempotent. iOS `applyForgottenTombstone`. */
    fun applyRelayForgottenTombstone(nodeHex: String, atMs: Long) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        if (atMs <= 0L) return
        if (relayAddedAtMs(hex) > atMs) return                        // a newer local re-add wins
        if ((clearedRelayForgets[hex] ?: 0L) > atMs) return           // a newer local re-add CLEAR wins
        if ((forgotAtRelays[hex] ?: 0L) >= atMs) return               // already forgotten at/after this time
        relayEntries[hex]?.let { relayEntries[hex] = it.copy(active = false) }
        suppressedRelays.add(hex)
        forgotAtRelays[hex] = atMs
        clearedRelayForgets.remove(hex)   // stop re-broadcasting a clear this newer deletion supersedes
        forgetBackedUp(hex)
        saveRelayNodes()
        scope.launch {
            relayMutex.withLock {
                runCatching { relayClients.remove(hex)?.close() }
                relayHealth.remove(hex)
            }
            withContext(Dispatchers.Main) { bumpRelays() }
        }
    }

    /** Apply a relay-deletion CLEAR (re-add) from another device — un-forget the relay so it can be
     *  re-learned (via the owner's re-announce / the additive circle record) — but ONLY when the re-add is
     *  NEWER than our local deletion (LWW). A re-add older than our forget loses and the relay stays gone.
     *  Idempotent. iOS `applyClearedRelayForget`. */
    fun applyRelayClearedForget(nodeHex: String, atMs: Long) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        if (atMs <= 0L) return
        if ((forgotAtRelays[hex] ?: 0L) > atMs) return   // our local deletion is newer → the delete wins
        // Already cleared at/after this time and not currently forgotten → nothing to do.
        if (!suppressedRelays.contains(hex) && forgotAtRelays[hex] == null && (clearedRelayForgets[hex] ?: 0L) >= atMs) return
        suppressedRelays.remove(hex)
        forgotAtRelays.remove(hex)
        clearedRelayForgets[hex] = maxOf(clearedRelayForgets[hex] ?: 0L, atMs)
        saveRelayNodes()
        scope.launch(Dispatchers.Main) { bumpRelays() }
    }

    /** Roster-publish heal for self-sync refusals (desktop `poll_self_sync` parity): re-publish our
     *  device roster to every relay that 403'd this pass, so the NEXT pass converges instead of
     *  refusing forever. Rate-limited inside [healForbiddenRelays]; no-op when nothing refused.
     *  Without this the selfsync ladder's [noteRefused] calls were write-only on Android — only the
     *  MEDIA paths ever healed, so a device the relay had never seen 403'd self-sync indefinitely. */
    suspend fun selfSyncHealRefusals(): Boolean = healForbiddenRelays()

    /** Connect (cached) to a relay, honoring backoff. Public wrapper so the coordinator can list/get/put. */
    suspend fun selfSyncRelayClient(nodeHex: String): RelayClient? = relayClientFor(nodeHex)
    suspend fun selfSyncRelayFailed(nodeHex: String) = relayFailed(nodeHex)
    fun selfSyncRelayOk(nodeHex: String) = markRelayOk(nodeHex)

    // ---- Self-sync transport ladder (parity with the mailbox paths) --------------------------
    //
    // The coordinator's RelayTransport used relayClientFor ONLY, so a relay this device cannot
    // iroh-dial — an HTTP-only announce, a dial in backoff, our own hosted relay (self-dial
    // guard) — silently carried NO self-sync slots: two linked devices sharing only a friend's
    // relay never converged ("my devices each receive different things"). These rungs mirror the
    // devroster/mailbox ladder: own local store, then the signed-HTTP interface (httpAuthHeader —
    // per-request node-key signature, token folded in and never sent), with the iroh dial staying
    // the coordinator's first remote choice. A 403 routes through noteRefused → roster publish →
    // retry, never a URL backoff (the refusal IS the thing a roster publish fixes).

    /** Our own hosted relay's store for self-sync slots (no self-dial). Null unless we host [nodeHex]. */
    fun selfSyncLocalStore(nodeHex: String): uniffi.haven_ffi.RelayServerHandle? =
        relayHost?.takeIf { runCatching { it.nodeIdHex() }.getOrNull() == nodeHex }

    /** LIST self-sync slot keys over the relay's signed-HTTP interface. Null = no usable interface. */
    fun selfSyncHttpList(nodeHex: String, prefix: String): List<String>? {
        val entry = relayEntries[nodeHex] ?: return null
        val bases = httpUrlsFor(entry)
        if (bases.isEmpty()) { Log.d(TAG, "selfsync http-list: no usable base for ${nodeHex.take(8)}") }
        for (base in bases) {
            val r = relayHttpList(base, entry.httpToken, prefix)
            if (r.isSuccess) {
                markRelaySeen(nodeHex)
                Log.d(TAG, "selfsync http-list ${r.getOrNull()?.size ?: -1} keys via $base")
                return r.getOrNull()
            }
            if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "selfsync list"); return null }
            Log.d(TAG, "selfsync http-list failed via $base: ${r.exceptionOrNull()?.message}")
            markHttpUrlBad(base)
        }
        return null
    }

    /** GET one self-sync slot over the relay's signed-HTTP interface (null = miss or unreachable). */
    fun selfSyncHttpGet(nodeHex: String, key: String): ByteArray? {
        val entry = relayEntries[nodeHex] ?: return null
        for (base in httpUrlsFor(entry)) {
            val r = relayHttpGet(base, entry.httpToken, key)
            if (r.isSuccess) { markRelaySeen(nodeHex); return r.getOrNull() }
            if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "selfsync slot get"); return null }
            markHttpUrlBad(base)
        }
        return null
    }

    /** PUT one self-sync slot over the relay's signed-HTTP interface. */
    fun selfSyncHttpPut(nodeHex: String, key: String, data: ByteArray): Boolean {
        val entry = relayEntries[nodeHex] ?: return false
        for (base in httpUrlsFor(entry)) {
            val r = relayHttpPut(base, entry.httpToken, key, data)
            if (r.isSuccess) { markRelaySeen(nodeHex); return true }
            if (r.exceptionOrNull() is RelayForbidden) { noteRefused(nodeHex, "selfsync slot put"); return false }
            markHttpUrlBad(base)
        }
        return false
    }

    // ---- Local store mutation for self-sync apply() --------------------------------------

    /** Upsert a contact from a converged self-sync entry (no networking). A removed contact must not be
     *  resurrected by sync (contacts sync additive-only — the tombstone is what makes a delete stick). */
    fun selfSyncUpsertContact(c: Contact) {
        if (ContactRemovals.isRemoved(c.idHex)) return
        val idx = contacts.indexOfFirst { it.idHex == c.idHex }
        if (idx >= 0) {
            if (contacts[idx] != c) { contacts[idx] = c; saveContacts() }
        } else {
            contacts.add(c); saveContacts()
        }
    }

    /** Remove a contact the converged state no longer holds (tombstoned on another device). */
    fun selfSyncRemoveContact(idHex: String) {
        if (contacts.removeAll { it.idHex == idHex }) saveContacts()
    }

    /** Block/unblock to reconcile the converged blocked set (no engine purge — pure list reconcile). */
    fun selfSyncSetBlocked(idHex: String, blockedNow: Boolean) {
        if (blockedNow) {
            if (blocked.none { it == idHex }) { blocked.add(idHex); saveBlocked() }
        } else {
            if (blocked.removeAll { it == idHex }) saveBlocked()
        }
    }

    /** A snapshot of contacts/blocked for the coordinator's currentLocal(). */
    fun selfSyncContactsSnapshot(): List<Contact> = contacts.toList()
    fun selfSyncBlockedSnapshot(): List<String> = blocked.toList()

    /** Persist the engine state + recompose the feed/circle UI after self-sync applied changes. */
    fun selfSyncDidApply() {
        reconcileSupersededCircles()   // an upgrade synced from another device may have superseded a circle
        persist()
        scope.launch(Dispatchers.Main) { feedVersion.value++; circlesVersion.value++ }
    }

    // ---- Self-sync nudge (debounced local-mutation push) ---------------------------------

    /** Debounce window for [selfSyncNudge] — long enough to coalesce a burst of edits (typing out a
     *  profile, pinning a few DMs) into ONE forced pass, short enough that the user's other devices
     *  see the change in seconds. */
    private const val SELF_SYNC_NUDGE_MS = 4_000L

    @Volatile private var selfSyncNudgeJob: Job? = null

    /**
     * A LOCAL mutation of self-sync-carried state just happened (profile/settings edit, circle
     * create/membership change, DM pin/read, retention change) — schedule ONE forced self-sync pass
     * in [SELF_SYNC_NUDGE_MS] so the edit reaches the user's other devices in seconds instead of
     * waiting out the periodic pollMailbox cadence (30s base, STRETCHED to minutes when idle).
     *
     * Coalescing: further mutations inside the window ride the already-scheduled shot (the timer is
     * NOT restarted, so a burst can't starve the push past the window). Fires ONLY on real local
     * mutations — sync-applied values go through applyingRemote/applySynced paths that never land
     * here — so an idle device schedules nothing and the adaptive-cadence heat work stands. The
     * forced pass pushes through MODERATE thermal (the user asked for this edit) but yields at
     * SEVERE+ — there the change rides the next periodic pass instead. The periodic cadence itself
     * is untouched.
     */
    fun selfSyncNudge() {
        if (!ready) return   // pre-start edits (onboarding) publish on the launch pollMailbox pass
        if (selfSyncNudgeJob?.isActive == true) return   // one shot already pending — this burst rides it
        selfSyncNudgeJob = scope.launch {
            delay(SELF_SYNC_NUDGE_MS)
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                val pm = appContext.getSystemService(android.content.Context.POWER_SERVICE) as? android.os.PowerManager
                when (pm?.currentThermalStatus) {
                    android.os.PowerManager.THERMAL_STATUS_SEVERE,
                    android.os.PowerManager.THERMAL_STATUS_CRITICAL,
                    android.os.PowerManager.THERMAL_STATUS_EMERGENCY,
                    android.os.PowerManager.THERMAL_STATUS_SHUTDOWN -> return@launch
                    else -> {}
                }
            }
            runCatching { SelfSyncCoordinator.sync(social, force = true) }
        }
    }

    // ---- Demo seeding support (DEBUG-only; see DemoSeed.kt) ------------------------------
    //
    // These thin hooks let DemoSeed populate the same in-memory state the live handshake would,
    // without any networking. They are harmless in a real launch (only called when demo is on).

    /** True once [init] has run, so the seeder can drive the engine. */
    val isReady: Boolean get() = ready

    /** Register a synthetic contact (name + verified id) directly, as if a handshake completed. */
    fun demoAddContact(idHex: String, name: String, verifyHex: String) {
        if (idHex.isEmpty()) return
        if (contacts.none { it.idHex == idHex }) contacts.add(Contact(idHex, name, verifyHex))
    }

    /** Persist the engine state the seeder authored into (idempotent within a launch). */
    fun demoPersist() = persist()

    /** Present the seeded demo as a healthy, connected app for screenshots (no live node). */
    fun demoMarkConnected() {
        started.value = true
        internetActive.value = true
        relayActive.value = true
    }

    /** Recompose the feed/circle switcher after the seeder authored content. */
    fun demoRefresh() {
        bumpCircles()
        feedVersion.value++
    }
}

/** node-id hex = first 32 bytes of the bundle, lowercase hex (matches iOS nodeHex). */
fun nodeHex(bundle: ByteArray): String =
    bundle.take(32).joinToString("") { "%02x".format(it.toInt() and 0xFF) }

fun nowMs(): ULong = System.currentTimeMillis().toULong()
