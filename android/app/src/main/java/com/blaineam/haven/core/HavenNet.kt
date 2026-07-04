package com.blaineam.haven.core

import android.content.Context
import android.util.Base64
import android.util.Log
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.HavenNode
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.InboundListener
import uniffi.haven_ffi.RelayClient
import uniffi.haven_ffi.parseLink
import java.io.File
import java.security.MessageDigest

private const val TAG = "HavenNet"
const val DEFAULT_CIRCLE = "default"

/** A known contact (their verified identity + display name). */
data class Contact(val idHex: String, val name: String, val verifyHex: String)

/** Someone who said hello but we haven't approved yet. */
data class PendingRequest(val idHex: String, val name: String, val verifyHex: String, val bundle: ByteArray)

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
        /** Bearer token the relay's HTTP interface requires (travels ONLY inside sealed announces). */
        val httpToken: String = "",
    )
    /** Per-relay metadata records, keyed by hex. The config survives deactivation here. */
    private val relayEntries = HashMap<String, RelayEntry>()
    /** The all-circles default relay (every present + future circle inherits it). "" = none. */
    private var defaultRelayHex: String = ""
    /** Erase inactive+unseen relay entries after this long (parity with iOS staleAfterMs). */
    private val RELAY_STALE_AFTER_MS = 7L * 24 * 3600 * 1000
    private val relayClients = HashMap<String, RelayClient>()
    private val relayMutex = Mutex()
    private val seenMailbox = HashSet<String>()

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
        fun recordSuccess() { fails = 0; nextRetryMs = 0L }
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
    private val initiated = HashMap<String, String>()

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
        social = HavenSocial(core.seed)
        LocalMedia.init(appContext)
        Presign.init(appContext)
        CircleLock.init(appContext)
        CircleRemovals.init(appContext)
        DeviceKeyStore.init(appContext)
        // Engine runs on this device's UNIQUE identity (parity with iOS configure()); account id stays the
        // sealing/trust anchor + contact handle. Friends resolve it to our device node id via the roster.
        social.useDeviceIdentity(DeviceKeyStore.deviceAccount().secretSeed())
        social.registerDevice(DeviceKeyStore.deviceBundle(), DeviceKeyStore.deviceName,
                              (System.currentTimeMillis() / 1000).toULong())
        DeviceCredentialStore.init(appContext)
        DeviceRosterManager.init(appContext)
        SelfSyncCoordinator.init(appContext)
        DmPins.init(appContext)
        restoreState()
        loadContacts()
        loadDeviceHints()
        loadBlocked()
        loadRelayNodes()
        purgeStaleRelays()   // erase relays inactive AND unseen > 7 days (config else survives)
        // Restore the last-selected circle (if it still exists), so it survives relaunch.
        val savedCircle = prefs.getString("activeCircle", DEFAULT_CIRCLE) ?: DEFAULT_CIRCLE
        activeCircle.value = if (savedCircle == DEFAULT_CIRCLE ||
            runCatching { social.circles().any { it.id == savedCircle } }.getOrDefault(false)
        ) savedCircle else DEFAULT_CIRCLE
        ready = true
    }

    /** Start the iroh node and begin syncing. Safe to call repeatedly. */
    fun start() {
        if (node != null) return
        // DIAGNOSTIC: capture iroh/noq connection-level logs to filesDir/iroh-trace.log BEFORE the node starts.
        runCatching { uniffi.haven_ffi.initLogging(appContext.filesDir.path) }
        scope.launch {
            try {
                // TRANSPORT = per-DEVICE seed → unique per-device relay/node id (never the account id). The
                // self-connect leak is defended at the haven-net core (Node refuses to dial our own node id).
                node = HavenNode.start(DeviceKeyStore.deviceAccount().secretSeed(), this@HavenNet)
                withContext(Dispatchers.Main) { started.value = true }
                Log.i(TAG, "node started: ${node?.nodeIdHex()}")
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
            } catch (e: Throwable) {
                Log.e(TAG, "node start failed", e)
            }
        }
        startMailboxLoop()
    }

    /** Poll the circle relay/mailbox every 15s so posts arrive even when peers aren't both online. */
    private var loopStarted = false
    private fun startMailboxLoop() {
        if (loopStarted) return
        loopStarted = true
        scope.launch {
            while (true) {
                delay(15_000)
                runCatching { pollMailbox() }
                // Greet contacts (Hello every tick keeps connections warm; full history re-send +
                // own-media relay backfill are throttled internally) and re-announce our relay so peers
                // that weren't connected at relay start still learn it (iOS reannounceOwnRelay parity).
                runCatching { syncWithContacts() }
                // Persistently retry any media an interrupted nearby/iroh transfer left incomplete —
                // pull from the circle relay AND re-request from peers every tick until nothing is
                // missing, so posts never stay fragmented (parity with iOS).
                runCatching { requestMissingMedia() }
                // Proactively push the media we hold to nearby own devices (the reliable own-device
                // channel) so a sibling gets our photos without relying on request/response.
                runCatching { pushOwnMediaNearby() }
                // GC relays that have been inactive + unseen > 7 days (active-but-unreachable kept).
                runCatching { purgeStaleRelays() }
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

    /** Non-DM circles, for the feed switcher. */
    fun feedCircles(): List<uniffi.haven_ffi.CircleInfoFfi> =
        runCatching { social.circles().filter { !it.id.startsWith("dm:") } }.getOrDefault(emptyList())

    fun circleName(id: String): String =
        runCatching { social.circles().firstOrNull { it.id == id }?.name }.getOrNull() ?: "My Circle"

    fun createCircle(name: String): String {
        val id = "circle-${nodeIdHex.take(8)}-${System.nanoTime()}"
        runCatching { social.createCircle(id, name) }
        persist(); bumpCircles()
        setActiveCircle(id)
        return id
    }

    fun renameCircle(id: String, name: String) {
        runCatching { social.renameCircle(id, name) }; persist(); bumpCircles()
    }

    fun leaveCircle(id: String) {
        if (id == DEFAULT_CIRCLE) return
        runCatching { social.leaveCircle(id) }
        if (activeCircle.value == id) activeCircle.value = DEFAULT_CIRCLE
        persist(); bumpCircles()
    }

    /** Add an existing contact to a circle + greet them there so it forms on their side. */
    fun addToCircle(circleId: String, contactIdHex: String) {
        CircleRemovals.remove(circleId, contactIdHex)   // deliberate re-add un-bans them (parity with iOS)
        runCatching { social.addExistingToCircle(circleId, contactIdHex) }
        persist(); bumpCircles()
        sendHello(circleId, contactIdHex)
    }

    fun setActiveCircle(id: String) {
        activeCircle.value = id
        prefs.edit().putString("activeCircle", id).apply()   // survive relaunch
    }

    private fun bumpCircles() { scope.launch(Dispatchers.Main) { circlesVersion.value++ } }

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
        if (type in intArrayOf(Wire.MEDIA_REQ, CallWire.INVITE, CallWire.ACCEPT, CallWire.HANGUP, CallWire.OFFER,
                CallWire.ANSWER, CallWire.ICE, CallWire.GROUP_INVITE)) {
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
                Wire.EVENT -> handleEvent(body)
                Wire.RELAY_NODE -> handleRelayNode(body)
                Wire.RELAY -> handleRelay(body, viaNearby)
                Wire.PRESIGN -> handlePresignBootstrap(body)
                Wire.MEDIA_REQ -> handleMediaRequest(body)
                Wire.MEDIA_CHUNK -> handleMediaChunk(body)
                Wire.DEVICE_ROSTER -> handleDeviceRosterAnnounce(body)
                CallWire.INVITE, CallWire.ACCEPT, CallWire.HANGUP, CallWire.OFFER,
                CallWire.ANSWER, CallWire.ICE, CallWire.GROUP_INVITE ->
                    withContext(Dispatchers.Main) { callRouter?.invoke(type, body) }
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
        sendFrame(type, payload, toNodeHex)
        val dests = LinkedHashSet<String>()
        dests.addAll(runCatching { social.deviceNodeIdsFor(toNodeHex) }.getOrDefault(emptyList()))
        if (dests.isEmpty()) dests.add(toNodeHex)
        dests.addAll(deviceHintsFor(toNodeHex))
        originateRelayInternet(dests.toList(), Wire.frame(type, payload))
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

    private fun handleHello(payload: ByteArray, viaNearby: Boolean = false, senderDevice: String? = null) {
        val hello = Wire.parseHello(payload) ?: return
        val idHex = nodeHex(hello.bundle)
        if (blocked.contains(idHex)) return   // a blocked node can't handshake back in
        // A hello delivered DIRECTLY teaches us the sender's dialable device id for this account —
        // the reply-path bootstrap (their signed roster supersedes; a wrong hint only misroutes
        // sealed frames, same trust model as invite-link hints).
        if (senderDevice != null && senderDevice.length == 64 && !senderDevice.equals(idHex, ignoreCase = true)) {
            recordDeviceHints(idHex, listOf(senderDevice))
        }
        val actualVerify = runCatching { social.bundleVerificationHex(hello.bundle) }.getOrNull() ?: return
        val name = runCatching { social.verifyProfile(hello.bundle, hello.signedProfile) }.getOrNull() ?: "Someone"
        // Capture the full profile card (avatar + emoji) so the feed/people/story-tray show real photos.
        runCatching { social.verifyProfileCard(hello.bundle, hello.signedProfile) }.getOrNull()
            ?.let { AvatarStore.put(idHex, it.avatar, it.emoji) }

        // DM circles encode both full node ids — only those two may ever join (MITM/contamination guard).
        if (hello.circleId.startsWith("dm:") && !dmAllows(hello.circleId, idHex)) return
        // A member you explicitly removed from THIS circle must NOT auto-rejoin on their handshake
        // (parity with iOS). A removed person keeps broadcasting Hellos — they don't know they're gone —
        // and without this guard the "already a contact" branch below silently re-added them to the very
        // circle you removed them from, so the removal never stuck. A deliberate re-add clears the
        // tombstone (addToCircle), so this only blocks the unsolicited rejoin.
        if (isRemovedFromCircle(hello.circleId, idHex)) return
        // A verified Hello forms the circle on our side if we don't have it yet (matches iOS).
        runCatching { social.createCircle(hello.circleId, hello.circleName) }

        val expected = initiated[idHex]
        if (expected != null) {
            // We scanned them first — auto-accept iff the bundle hash matches what the QR promised.
            if (expected.isNotEmpty() && expected != actualVerify) {
                Log.w(TAG, "verify mismatch for $idHex — dropping (possible MITM)")
                return
            }
            acceptContact(hello.circleId, hello.bundle, idHex, name, actualVerify, helloBack = true)
            initiated.remove(idHex)
            return
        }
        if (contacts.any { it.idHex == idHex }) {
            // Already a contact (e.g. their Hello-back) — make sure their bundle is in the circle.
            runCatching { social.addContactBundle(hello.circleId, hello.bundle) }
            return
        }
        // Unknown sender on a non-DM circle → a request to approve — UNLESS it merely arrived over the
        // proximity mesh (nearby ≠ intent to connect; that flooded the user with spurious requests).
        if (viaNearby) return
        if (!hello.circleId.startsWith("dm:")) {
            scope.launch(Dispatchers.Main) {
                if (pending.none { it.idHex == idHex }) {
                    pending.add(PendingRequest(idHex, name, actualVerify, hello.bundle))
                }
            }
        }
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
        runCatching { social.createCircle(id, contact.name) }
        runCatching { social.addExistingToCircle(id, contact.idHex) }
        persist()
        sendHello(id, contact.idHex)
        return id
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
        runCatching { social.createCircle(id, title) }
        for (c in contacts) runCatching { social.addExistingToCircle(id, c.idHex) }
        persist()
        for (c in contacts) sendHello(id, c.idHex)
        return id
    }

    /** The messages of a circle (a DM thread), oldest→newest for chat display. Hides anything older
     *  than this DM's "cleared before" watermark so re-starting a (deterministic-id) DM shows fresh. */
    fun messages(circleId: String): List<uniffi.haven_ffi.FeedItemFfi> {
        val all = runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList())
            .sortedBy { it.createdAt }
        val cutoff = dmClearedBefore(circleId) ?: return all
        return all.filter { it.createdAt >= cutoff }
    }

    // ---- DM "cleared before" watermark ------------------------------------------------------------
    // Deleting a DM records now() here (persisted). Because a DM's circle id is deterministic,
    // re-starting/re-syncing it re-fetches the old messages (true network deletion is impossible in
    // P2P); the watermark hides everything from before the clear so a re-started DM shows fresh.
    private val dmPrefs get() = appContext.getSharedPreferences("haven.dm", Context.MODE_PRIVATE)

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
        runCatching { social.leaveCircle(circleId) }
        if (activeCircle.value == circleId) activeCircle.value = DEFAULT_CIRCLE
        persist(); bumpCircles(); scope.launch(Dispatchers.Main) { feedVersion.value++ }
    }

    /** Send a text DM into a circle and deliver it to the partner. */
    fun sendDm(circleId: String, body: String, media: List<String> = emptyList(),
               music: uniffi.haven_ffi.TrackRefFfi? = null, retentionSecs: ULong? = null) {
        if (body.isBlank() && media.isEmpty() && music == null) return
        // retentionSecs != null → a disappearing message (auto-expires in the feed reducer, iOS parity).
        val env = runCatching {
            social.post(circleId, body, media, music, retentionSecs, false, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
        media.forEach { enqueueBackup(circleId, it) }   // serialized: one blob in RAM at a time
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

    private fun handleEvent(payload: ByteArray) {
        val ev = Wire.parseEvent(payload) ?: return
        val changed = runCatching { social.receive(ev.circleId, ev.envelope) }.getOrDefault(false)
        if (changed) {
            persist()
            scope.launch(Dispatchers.Main) { feedVersion.value++ }
            requestMissingMedia()   // fetch any photos/videos the new post references
            notifyInbound(ev.circleId)
        }
    }

    /** Post a local notification for new inbound content when the app isn't foreground. */
    private fun notifyInbound(circleId: String) {
        if (isForeground) return
        val isDm = circleId.startsWith("dm:")
        Notifications.notify(
            appContext,
            title = if (isDm) "New message" else "New in your circle",
            body = if (isDm) "You have a new Haven message" else "Someone posted in your circle",
        )
    }

    // ---- Outbound ------------------------------------------------------------------------

    /** Begin a connect from a scanned/pasted haven:// invite. */
    fun connectByLink(uri: String): Boolean {
        val trimmed = uri.trim()
        val info = runCatching { parseLink(trimmed) }.getOrNull() ?: return false
        // Scanning an invite is a DELIBERATE add: clear any old removal tombstone, or their hellos
        // stay dropped (handleHello guard) and self-sync re-severs them (re-add never sticks).
        CircleRemovals.remove(DEFAULT_CIRCLE, info.idHex)
        // Store the invite's device-id hints BEFORE the hello, so the very first dial can reach
        // their device (their account id resolves to no node post-device-seed).
        recordDeviceHints(info.idHex, InviteHints.extract(trimmed))
        initiated[info.idHex] = info.verificationHex
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

    /** Approve a pending request: add them, persist, and Hello back so they auto-accept us. */
    fun approve(req: PendingRequest) {
        // Approving IS a deliberate re-add — clear any old removal tombstone or their hellos stay
        // dropped (handleHello guard) and self-sync re-severs them on every pass.
        CircleRemovals.remove(DEFAULT_CIRCLE, req.idHex)
        acceptContact(DEFAULT_CIRCLE, req.bundle, req.idHex, req.name, req.verifyHex, helloBack = true)
        pending.removeAll { it.idHex == req.idHex }
    }

    fun dismiss(req: PendingRequest) { pending.removeAll { it.idHex == req.idHex } }

    /** Block a node: purge from every circle, drop from contacts, ignore future frames. */
    fun block(idHex: String) {
        runCatching { social.blockMember(idHex) }
        contacts.removeAll { it.idHex == idHex }
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
    }

    /** True if [hex] was explicitly removed from [circleId] (severance) — don't dial / show them there. */
    fun isRemovedFromCircle(circleId: String, hex: String): Boolean = CircleRemovals.contains(circleId, hex)

    // ---- Multi-device roster (iOS-parity; the signed-credential crypto lives in the shared core) ----

    /** Turn THIS device into the primary (master-key holder) that authorizes/revokes the others. */
    fun enableDeviceRoster() {
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

    /** Revoke a linked device (primary only) — it can decrypt nothing posted afterward. */
    fun revokeDevice(nodeHex: String) {
        DeviceRosterManager.revoke(nodeHex, social, core.seed)
    }

    /** Step this device down from being the primary (e.g. the wrong device claimed the role). */
    fun stepDownAsPrimary() {
        DeviceRosterManager.stepDown()
    }

    /** I hold the master seed → authorize the requesting device: issue its credential, add it to my
     *  signed roster, send the grant back, and push my state so it backfills. */
    private fun handleEnrollmentRequest(payload: ByteArray) {
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
        for (a in runCatching { social.contactNodeIds(circleId) }.getOrDefault(emptyList())) {
            add(a)
            for (d in runCatching { social.deviceNodeIdsFor(a) }.getOrDefault(emptyList())) add(d)
            for (h in deviceHintsFor(a)) add(h)   // invite-link hints (until their roster lands)
        }
        return out.toList()
    }

    fun unblock(idHex: String) {
        blocked.removeAll { it == idHex }
        saveBlocked()
    }

    private fun acceptContact(
        circleId: String, bundle: ByteArray, idHex: String, name: String, verifyHex: String, helloBack: Boolean,
    ) {
        runCatching { social.addContactBundle(circleId, bundle) }
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
        if (resendHistory) {
            val envs = runCatching { social.syncEnvelopes(circleId) }.getOrDefault(emptyList())
            for (env in envs) sendFrame(Wire.EVENT, Wire.eventPayload(circleId, env), toNodeHex)
        }
        // Tell this peer about EVERY relay I know for the circle, so we pool all mailboxes.
        for (nodeHex in relaysFor(circleId)) {
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
        if (resendHistory) lastHistoryResendMs = nowMs
        reannounceOwnRelay()   // frame 19 was a one-shot at relay start; re-emit so peers reliably learn it
        // Push MY media up to every circle relay periodically (idempotent — skips blobs already present),
        // so a sibling reading the relay finds it. The nearby chunk path is unreliable; the relay is durable.
        if (nowMs - lastMediaBackfillMs > 120_000) {
            lastMediaBackfillMs = nowMs
            scope.launch { runCatching { for (c in social.circles()) backfillMailbox(c.id) } }
        }
    }

    private fun helloPayload(circleId: String): ByteArray? {
        val name = profile.displayName.ifBlank { "Someone" }
        val circleName = social.circles().firstOrNull { it.id == circleId }?.name ?: "My Circle"
        val bundle = social.myBundle()
        val signed = social.mySignedProfile(name, profile.bio, profile.link, profile.avatarB64, profile.emoji)
        return Wire.helloPayload(circleId, circleName, bundle, signed)
    }

    /** Author a post in a circle and broadcast the sealed event to its members. */
    fun post(circleId: String, body: String, media: List<String> = emptyList(),
             music: uniffi.haven_ffi.TrackRefFfi? = null, retentionSecs: ULong? = null) {
        if (body.isBlank() && media.isEmpty() && music == null) return
        val env = runCatching {
            // retentionSecs != null → a disappearing post (auto-expires in the feed reducer, iOS parity).
            social.post(circleId, body, media, music, retentionSecs, false, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
        media.forEach { enqueueBackup(circleId, it) }   // serialized: push photos/videos to the relay, one blob in RAM at a time
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

    /** Post a story (a post with the story flag + 24h retention; auto-expires). */
    fun postStory(body: String, mediaId: String?, music: uniffi.haven_ffi.TrackRefFfi? = null) {
        if (body.isBlank() && mediaId == null && music == null) return
        val env = runCatching {
            social.post(DEFAULT_CIRCLE, body, listOfNotNull(mediaId), music, 86_400UL, true, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(DEFAULT_CIRCLE, env)
        mediaId?.let { enqueueBackup(DEFAULT_CIRCLE, it) }   // serialized: one blob in RAM at a time
    }

    /** React / unreact / comment on a post — author + broadcast, same as a post. */
    fun react(circleId: String, postId: String, emoji: String) {
        val env = runCatching { social.react(circleId, postId, emoji, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    fun unreact(circleId: String, postId: String, emoji: String) {
        val env = runCatching { social.unreact(circleId, postId, emoji, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    fun comment(circleId: String, postId: String, body: String) {
        if (body.isBlank()) return
        val env = runCatching { social.comment(circleId, postId, body, emptyList(), nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    /** Edit your own post's text; broadcasts the edit event. */
    fun editPost(circleId: String, postId: String, body: String) {
        val env = runCatching {
            social.edit(circleId, postId, body, emptyList(), null, false, nowMs())
        }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    /** Unsend (delete) your own post; broadcasts the unsend event. */
    fun unsendPost(circleId: String, postId: String) {
        val env = runCatching { social.unsend(circleId, postId, nowMs()) }.getOrNull() ?: return
        afterAuthor(circleId, env)
    }

    /** Persist, bump the feed, and broadcast a freshly-authored sealed envelope to members. */
    private fun afterAuthor(circleId: String, env: ByteArray) {
        persist()
        scope.launch(Dispatchers.Main) { feedVersion.value++ }
        val payload = Wire.eventPayload(circleId, env)
        for (idHex in dialTargets(circleId)) sendFrame(Wire.EVENT, payload, idHex)
        // Store-and-forward via the circle relay so offline members still get it.
        scope.launch { uploadEvent(circleId, env) }
        // Nearby mesh (never DMs — they stay point-to-point, matching iOS).
        if (NearbyTransport.active && !circleId.startsWith("dm:")) {
            NearbyTransport.broadcast(Wire.frame(Wire.EVENT, payload))
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
            scope.launch { sendMediaChunks(ref, LocalMedia.loadAnyCircle(ref) ?: return@launch, me) }
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
        val payload = if (e != null && e.httpUrls.isNotEmpty() && e.httpToken.isNotEmpty()) {
            org.json.JSONObject()
                .put("node", nodeHex)
                .put("urls", JSONArray(e.httpUrls))
                .put("token", e.httpToken)
                .toString().toByteArray(Charsets.UTF_8)
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
        val open = runCatching { social.openCircleMedia(circleId, sealed) }.getOrNull() ?: return
        val text = String(open, Charsets.UTF_8).trim()
        // Extended announce: JSON {node, urls, token} carries the relay's HTTP media interface.
        var announcedUrls: List<String> = emptyList()
        var announcedToken = ""
        val nodeHex: String = if (text.startsWith("{")) {
            val o = runCatching { JSONObject(text) }.getOrNull() ?: return
            announcedUrls = o.optJSONArray("urls")?.let { a ->
                (0 until a.length()).mapNotNull { i -> a.optString(i).takeIf { u -> u.startsWith("http") } }
            } ?: emptyList()
            announcedToken = o.optString("token", "")
            o.optString("node", "").trim().lowercase()
        } else text.lowercase()
        if (nodeHex.length != 64) return
        // A contact (often your OWN other device) RE-ANNOUNCED their circle relay. Previously a relay
        // the user had deactivated/forgot stayed in `suppressed` and was permanently ignored here — so
        // deleting your Mac's relay on your phone meant it never came back even when the Mac re-announced
        // it. Now a deliberate re-announce REACTIVATES the existing inactive entry (clears suppression +
        // active=true) rather than being dropped, so own-device / re-announced relays can resurface.
        if (suppressedRelays.contains(nodeHex) || !isRelayActive(nodeHex)) {
            suppressedRelays.remove(nodeHex)
            ensureRelayEntry(nodeHex, activate = true)
            relayHealth.remove(nodeHex)
        }
        // A contact advertised their circle relay → ADD it to our redundant set for this circle,
        // so members automatically pool relays (more redundancy, no manual setup). Append, never
        // replace — parity with desktop handle_relay_node.
        val list = relayNodes.getOrPut(circleId) { mutableListOf() }
        ensureRelayEntry(nodeHex, isS3 = false, activate = true)
        // Record the relay's announced HTTP media interface (the reliable cross-NAT path).
        if (announcedUrls.isNotEmpty() && announcedToken.isNotEmpty()) {
            val e = relayEntries[nodeHex]
            if (e != null && (e.httpUrls != announcedUrls || e.httpToken != announcedToken)) {
                relayEntries[nodeHex] = e.copy(httpUrls = announcedUrls, httpToken = announcedToken)
                saveRelayNodes()
                Log.i(TAG, "learned relay http interface for ${nodeHex.take(8)}: ${announcedUrls.size} url(s)")
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

    fun adoptRelay(nodeHex: String, name: String? = null, setDefault: Boolean = false) {
        val hex = nodeHex.trim().lowercase()
        if (hex.length != 64) return
        suppressedRelays.remove(hex)   // explicit adoption overrides a prior Forget
        ensureRelayEntry(hex, name = name, isS3 = false, activate = true)
        if (setDefault) defaultRelayHex = hex
        scope.launch {
            for (c in social.circles()) {
                val cid = c.id
                val list = relayNodes.getOrPut(cid) { mutableListOf() }
                if (!list.contains(hex)) list.add(hex)
                // Tell members (sealed) so they use the same mailbox.
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
        suppressedRelays.remove(hex)
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
            saveRelayNodes()
            relayMutex.withLock {
                runCatching { relayClients.remove(hex)?.close() }
                relayHealth.remove(hex)
            }
            withContext(Dispatchers.Main) { bumpRelays() }
        }
    }

    /** Reactivate a deactivated relay: flip active=true + clear its suppression so it's dialed again. */
    fun reactivateRelay(nodeHex: String) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        suppressedRelays.remove(hex)
        ensureRelayEntry(hex, activate = true)
        relayHealth.remove(hex)   // clear stale backoff so it's retried immediately
        saveRelayNodes()
        bumpRelays()
    }

    /** ERASE a relay for good — its associations across every circle, its entry, the default, caches. */
    fun eraseRelayNow(nodeHex: String) {
        val hex = if (nodeHex.startsWith("s3:")) nodeHex else nodeHex.trim().lowercase()
        scope.launch {
            for (list in relayNodes.values) list.removeAll { it == hex }
            relayNodes.entries.removeAll { it.value.isEmpty() }
            if (defaultRelayHex == hex) defaultRelayHex = ""
            relayEntries.remove(hex)
            suppressedRelays.add(hex)
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

    /** Create-or-update a RelayEntry. `activate` flips it on; lastSeen is stamped now on first create. */
    private fun ensureRelayEntry(hex: String, name: String? = null, isS3: Boolean = false, activate: Boolean = false) {
        val e = relayEntries[hex]
        relayEntries[hex] = if (e != null) {
            e.copy(
                name = if (!name.isNullOrBlank()) name else e.name,
                active = if (activate) true else e.active,
            )
        } else {
            RelayEntry(hex, if (name.isNullOrBlank()) shortRelayName(hex) else name, true, relayNow(), isS3)
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
    fun allRelayEntries(): List<RelayEntry> = relayEntries.values.sortedWith(
        compareByDescending<RelayEntry> { it.active }.thenBy { it.name.lowercase() }
    )

    /** The all-circles default relay hex, or null. */
    fun defaultRelay(): String? = defaultRelayHex.ifEmpty { null }

    /** Bump so the relay-settings UI recomposes after the adopted set / health changes. */
    var relaysVersion = mutableStateOf(0); private set
    private fun bumpRelays() { relaysVersion.value++ }

    /** The redundant ACTIVE relay set for a circle: its own list plus the all-circles default (deduped).
     *  Deactivated relays are filtered out so they aren't dialed/served, but their config survives. */
    private fun relaysFor(circleId: String): List<String> {
        val out = (relayNodes[circleId] ?: emptyList()).filter { isRelayActive(it) }.toMutableList()
        if (defaultRelayHex.isNotEmpty() && isRelayActive(defaultRelayHex) && !out.contains(defaultRelayHex))
            out.add(defaultRelayHex)
        return out
    }

    /** Every distinct ACTIVE relay across all circles + the default — for mesh sync / active transport. */
    private fun allRelays(): List<String> {
        val out = relayNodes.values.flatten().filter { isRelayActive(it) }.distinct().toMutableList()
        if (defaultRelayHex.isNotEmpty() && isRelayActive(defaultRelayHex) && !out.contains(defaultRelayHex))
            out.add(defaultRelayHex)
        return out
    }

    private fun relayAvailable(nodeHex: String): Boolean =
        relayHealth[nodeHex]?.available(System.currentTimeMillis()) ?: true

    private fun markRelayOk(nodeHex: String) {
        relayHealth.getOrPut(nodeHex) { RelayHealth() }.recordSuccess()
        markRelaySeen(nodeHex)   // stamp lastSeen so the stale-clock only ticks while truly unseen
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
    fun startHosting() {
        if (relayHost != null) return
        val n = node ?: run {
            // Node not up yet — retry shortly; the relay can't exist without the node to attach to.
            scope.launch(Dispatchers.Main) { delay(1000); startHosting() }
            return
        }
        scope.launch {
            val dir = File(appContext.filesDir, "relay").apply { mkdirs() }.absolutePath
            val h = runCatching { uniffi.haven_ffi.RelayServerHandle.attach(n, dir) }
                .getOrElse { Log.e(TAG, "relay host attach failed", it); return@launch }
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
     * NAT stall ~30s and die). Bearer-token gated; the token travels only inside the sealed frame-19
     * announce, so only circle members ever hold it. The reachable URLs (LAN + an optional
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

    /** URLs peers can reach our HTTP interface at: every non-loopback IPv4 + the optional public URL. */
    private fun relayHttpUrls(port: Int): List<String> {
        val out = LinkedHashSet<String>()
        // A user-configured public URL (port-forward / reverse proxy / tunnel) goes FIRST — it's the
        // one that works across the internet; LAN addresses follow for same-network peers.
        prefs.getString("relayPublicUrl", null)?.trim()?.takeIf { it.startsWith("http") }?.let { out.add(it.trimEnd('/')) }
        runCatching {
            for (ni in java.net.NetworkInterface.getNetworkInterfaces()) {
                if (!ni.isUp || ni.isLoopback) continue
                for (addr in ni.inetAddresses) {
                    if (addr is java.net.Inet4Address && !addr.isLoopbackAddress) {
                        out.add("http://${addr.hostAddress}:$port")
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
        // S3 pre-signed pool (the BYO-bucket path many circles use).
        if (Presign.hasBootstrap(circleId)) {
            if (Presign.uploadEvent(circleId, nodeIdHex, env)) {
                withContext(Dispatchers.Main) { relayActive.value = true }
            }
        }
        // Mirror to EVERY configured Haven relay (redundancy). Content-addressed keys make
        // re-puts idempotent, and a relay in backoff is skipped — graceful fallback.
        val key = mailboxKey(circleId, env)
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        for (nodeHex in relaysFor(circleId)) {
            // S3-bucket relay (store-and-forward): PUT the sealed blob straight into the bucket via the
            // direct S3 FFI using the device-local creds (StorageStore). Content-addressed key.
            if (nodeHex.startsWith("s3:")) {
                val cfg = StorageStore.s3Config(appContext) ?: continue
                runCatching { uniffi.haven_ffi.s3Put(cfg, key, env) }
                    .onSuccess { markRelaySeen(nodeHex); withContext(Dispatchers.Main) { relayActive.value = true } }
                    .onFailure { Log.d(TAG, "s3 relay put failed ($nodeHex): ${it.message}") }
                continue
            }
            // Our OWN hosted relay: store directly into the local mailbox (no iroh self-dial).
            if (hostedHex != null && nodeHex == hostedHex) {
                runCatching { relayHost?.localPut(key, env) }
                withContext(Dispatchers.Main) { relayActive.value = true }
                continue
            }
            val client = relayClientFor(nodeHex) ?: continue
            runCatching { client.put(key, env) }
                .onSuccess {
                    markRelayOk(nodeHex)
                    withContext(Dispatchers.Main) { relayActive.value = true }
                }
                .onFailure { Log.d(TAG, "mailbox put failed ($nodeHex): ${it.message}"); relayFailed(nodeHex) }
        }
    }

    /** Re-upload every post I authored in a circle (for members who were offline when I posted). */
    private suspend fun backfillMailbox(circleId: String) {
        if (relaysFor(circleId).isEmpty() && !Presign.hasBootstrap(circleId)) return
        val envs = runCatching { social.exportMyEnvelopes(circleId) }.getOrDefault(emptyList())
        for (env in envs) uploadEvent(circleId, env)
        // Also push the media bytes of anything I've posted here that I still hold locally — through
        // the serial media queue so several circles backfilling at once can't stack full blobs in RAM.
        val feed = runCatching { social.feed(circleId, nowMs(), null) }.getOrDefault(emptyList())
        for (item in feed) if (item.isMe) item.media.forEach { if (LocalMedia.has(it)) enqueueBackup(circleId, it) }
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

    /** Poll every circle's mailbox; ingest envelopes we haven't seen. */
    suspend fun pollMailbox() {
        if (!ready) return
        var changed = false
        // S3 pre-signed pools (the BYO-bucket path).
        for (circleId in Presign.circles()) {
            val items = runCatching { Presign.poll(circleId, seenMailbox) }.getOrDefault(emptyList())
            if (items.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
            for ((key, env) in items) {
                seenMailbox.add(key)
                if (runCatching { social.receive(circleId, env) }.getOrDefault(false)) {
                    changed = true; notifyInbound(circleId)
                }
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
        for ((circleId, nodeHex) in relayTargets) {
            // S3-bucket relay: LIST + GET via the direct S3 FFI (store-and-forward poll).
            if (nodeHex.startsWith("s3:")) {
                val cfg = StorageStore.s3Config(appContext) ?: continue
                val prefix = "haven/mailbox/$circleId/"
                val keys = runCatching { uniffi.haven_ffi.s3List(cfg, prefix) }.getOrNull() ?: continue
                markRelaySeen(nodeHex)
                if (keys.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
                for (s3key in keys) {
                    if (seenMailbox.contains(s3key)) continue
                    val env = runCatching { uniffi.haven_ffi.s3Get(cfg, s3key) }.getOrNull() ?: continue
                    seenMailbox.add(s3key)
                    if (runCatching { social.receive(circleId, env) }.getOrDefault(false)) {
                        changed = true; notifyInbound(circleId)
                    }
                }
                continue
            }
            val client = relayClientFor(nodeHex) ?: continue
            val prefix = "haven/mailbox/$circleId/"
            val keys = runCatching { client.list(prefix) }.getOrNull()
            if (keys == null) { relayFailed(nodeHex); continue }
            markRelayOk(nodeHex)
            if (keys.isNotEmpty()) withContext(Dispatchers.Main) { relayActive.value = true }
            for (key in keys) {
                if (seenMailbox.contains(key)) continue
                val env = runCatching { client.get(key) }.getOrNull() ?: continue
                seenMailbox.add(key)
                if (runCatching { social.receive(circleId, env) }.getOrDefault(false)) {
                    changed = true
                    notifyInbound(circleId)
                }
            }
        }
        // Mesh: if we host a relay, pull from each adopted sibling so the mailbox self-replicates.
        meshSync()
        // Multi-device self-sync: converge this user's OWN devices (profile/settings/contacts/
        // blocked/circles) over the same relays. Has its own transport + in-flight guard, and a
        // refresh trigger (selfSyncDidApply) when a peer device's state arrives.
        runCatching { SelfSyncCoordinator.sync(social) }
        if (changed) {
            persist()
            withContext(Dispatchers.Main) { feedVersion.value++ }
            requestMissingMedia()
        }
    }

    // ---- Cross-device media bytes (frame 3 request / frame 5 sealed chunks), like iOS ----

    // 32KB chunks transmit reliably over a slow BLE-only nearby link (larger frames overflowed the
    // reliable-send buffer and were silently dropped, so own-device media never arrived). iOS parity.
    private val mediaChunkSize = 32 * 1024
    private class IncomingMedia(val total: Int) { val chunks = HashMap<Int, ByteArray>() }
    private val incomingMedia = HashMap<String, IncomingMedia>()
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
    private val mediaChunkBytes = 8 * 1024 * 1024   // 8 MB — under MAX_BLOB, memory-safe
    // 9-byte ASCII magic marking a manifest. A sealed envelope is JSON starting with '{', so no collision.
    private val manifestMagic = "HVCHUNK1\n".toByteArray(Charsets.US_ASCII)

    private fun makeManifest(sizes: List<Int>): ByteArray {
        val json = org.json.JSONObject()
            .put("v", 1).put("chunks", sizes.size).put("total", sizes.sum())
            .put("sizes", org.json.JSONArray(sizes))
        return manifestMagic + json.toString().toByteArray(Charsets.UTF_8)
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
        class Backup(ref: String, circleId: String) : MediaJob(ref, circleId)
        class Restore(ref: String, circleId: String) : MediaJob(ref, circleId)
    }
    // Unlimited buffer + a single consumer = strictly serial; the dedup set + cap below bound it.
    private val mediaQueue = Channel<MediaJob>(Channel.UNLIMITED)
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
            for (job in mediaQueue) {
                val key = jobKey(job)
                // Process ONE blob at a time — peak memory ≈ a single media file, not the library.
                runCatching {
                    when (job) {
                        is MediaJob.Backup -> uploadMedia(job.circleId, job.ref)
                        is MediaJob.Restore -> {
                            if (fetchMediaFromRelay(job.circleId, job.ref)) {
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
        (if (job is MediaJob.Backup) "B|" else "R|") + job.ref + "|" + job.circleId

    /** Enqueue a media blob to mirror to the circle's relays — serialized (one in RAM at a time). */
    private fun enqueueBackup(circleId: String, ref: String) {
        if (LocalMedia.isSynthetic(ref)) return   // geo: pins et al. carry no bytes — never relay-storable
        val job = MediaJob.Backup(ref, circleId)
        if (!offerMediaJob(jobKey(job))) return
        ensureMediaQueueDraining()
        mediaQueue.trySend(job)
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

    /** Fetch missing feed media: try the circle relay (haven/media/<ref>) first, then ask contacts. */
    fun requestMissingMedia() {
        if (!ready) return
        val myHex = nodeIdHex
        val missing = LinkedHashMap<String, String>()   // ref -> circleId
        for (c in social.circles()) {
            val feed = runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())
            for (item in feed) {
                // Skip synthetic refs (geo: location pins): they carry no fetchable bytes, so counting
                // them keeps the pending metric pinned above 0 forever and fires a doomed fetch each sweep.
                item.media.forEach { if (!LocalMedia.isSynthetic(it) && !LocalMedia.has(it)) missing.putIfAbsent(it, c.id) }
                item.comments.forEach { cm -> cm.media.forEach { if (!LocalMedia.isSynthetic(it) && !LocalMedia.has(it)) missing.putIfAbsent(it, c.id) } }
            }
        }
        SyncMetrics.setPending(missing.size)   // media refs still missing locally (iOS nbMediaPending)
        android.util.Log.i("MediaSync", "requestMissing missing=${missing.size} firstFew=${missing.keys.take(3)} defaultRelay=${defaultRelayHex.take(12)} relayNodes=${relayNodes.mapValues { it.value.map { n -> n.take(10) } }}")
        // THROTTLE: a missing ref used to be direct-requested from EVERY contact on every sweep, so a
        // backlog of missing media flooded the network with hundreds of thousands of frames per cycle
        // (drowning real delivery — the iOS flood bug). Direct-request each ref at most once per 5 min and
        // only a handful per cycle; the content-addressed relay/mailbox restore below is the real path and
        // is idempotent, so it carries the bulk without flooding.
        val nowMs = System.currentTimeMillis()
        var directBudget = 8
        for ((ref, circleId) in missing) {
            // SERIALIZED RESTORE: the relay fetch loads a FULL blob into RAM, so it goes through the
            // single media-transfer queue (one blob at a time) instead of one concurrent coroutine per
            // missing ref — which used to pull the whole library into memory at once and OOM-crash.
            enqueueRestore(circleId, ref)
            val stale = (mediaReqAt[ref]?.let { nowMs - it > 300_000 } ?: true)
            val allowDirect = stale && directBudget > 0
            if (!allowDirect) continue
            // Peer re-request (tiny frame, no blob in RAM) stays direct but throttled/budgeted so we
            // never flood; the content-addressed relay restore above is the real, memory-bounded path.
            mediaReqAt[ref] = nowMs; directBudget--
            requestedRefs.add(ref)
            val payload = myHex.toByteArray(Charsets.UTF_8) + ref.toByteArray(Charsets.UTF_8)
            for (idHex in contacts.map { it.idHex }) sendFrame(Wire.MEDIA_REQ, payload, idHex)
        }
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
    private fun mediaRelaysFor(circleId: String): List<String> =
        relaysFor(circleId).sortedByDescending { hex ->
            when {
                relayEntries[hex]?.httpUrls?.isNotEmpty() == true -> 2
                hex.startsWith("s3:") -> 1
                else -> 0
            }
        }

    // ---- Relay plain-HTTP media interface (client side) ------------------------------------------
    // GET/PUT against a relay's HTTP interface (see core httprelay.rs): `<base>/k/<key>` with the
    // relay's bearer token. Result semantics: failure = URL unreachable (back it off + try the next
    // URL), success(null) = relay reached but doesn't hold the key (a real MISS — the iroh path
    // serves the same store, so don't bother dialing it for the same key).

    private val httpUrlBad = HashMap<String, Long>()   // url -> retry-after epoch ms (2-min backoff)
    private fun httpUrlsFor(e: RelayEntry): List<String> =
        if (e.httpToken.isEmpty()) emptyList()
        else e.httpUrls.filter { (httpUrlBad[it] ?: 0L) < System.currentTimeMillis() }
    private fun markHttpUrlBad(url: String) { httpUrlBad[url] = System.currentTimeMillis() + 120_000 }

    private fun httpKeyUrl(base: String, key: String) = "${base.trimEnd('/')}/k/${android.net.Uri.encode(key, "/")}"

    private fun relayHttpGet(base: String, token: String, key: String): Result<ByteArray?> = runCatching {
        val c = (java.net.URL(httpKeyUrl(base, key)).openConnection() as java.net.HttpURLConnection).apply {
            connectTimeout = 4000; readTimeout = 60000
            setRequestProperty("Authorization", "Bearer $token")
        }
        try {
            when (c.responseCode) {
                in 200..299 -> c.inputStream.use { it.readBytes() }
                404 -> null
                else -> throw java.io.IOException("http ${c.responseCode}")
            }
        } finally { c.disconnect() }
    }

    private fun relayHttpPut(base: String, token: String, key: String, body: ByteArray): Boolean = runCatching {
        val c = (java.net.URL(httpKeyUrl(base, key)).openConnection() as java.net.HttpURLConnection).apply {
            requestMethod = "PUT"; doOutput = true; connectTimeout = 4000; readTimeout = 120000
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Content-Type", "application/octet-stream")
            setFixedLengthStreamingMode(body.size)
        }
        try {
            c.outputStream.use { it.write(body) }
            c.responseCode in 200..299
        } finally { c.disconnect() }
    }.getOrDefault(false)

    /** PUT one media blob (chunked wire format) to a relay's HTTP interface. True if it landed. */
    private fun httpUploadMedia(e: RelayEntry, ref: String, key: String, blob: ByteArray, chunked: Boolean): Boolean {
        for (base in httpUrlsFor(e)) {
            val ok = if (chunked) {
                val sizes = ArrayList<Int>()
                var all = true
                for ((i, range) in chunkOffsets(blob.size).withIndex()) {
                    val (from, to) = range
                    if (!relayHttpPut(base, e.httpToken, mediaChunkKey(ref, i), blob.copyOfRange(from, to))) { all = false; break }
                    sizes.add(to - from)
                }
                all && relayHttpPut(base, e.httpToken, key, makeManifest(sizes))
            } else {
                relayHttpPut(base, e.httpToken, key, blob)
            }
            if (ok) return true
            markHttpUrlBad(base)
        }
        return false
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
    /** Forget a relay's upload confirmations (it was forgotten/erased) so we re-mirror if it returns. */
    private fun forgetBackedUp(node: String) {
        ensureLedger()
        if (backedUp.removeAll { it.startsWith("$node|") }) {
            runCatching { appContext.getSharedPreferences("haven.mediabackup", Context.MODE_PRIVATE).edit().putStringSet("done", HashSet(backedUp)).apply() }
        }
    }

    suspend fun uploadMedia(circleId: String, ref: String) {
        // Skip entirely if every destination already has this blob (before the expensive rawSealed read).
        val dests = mediaRelaysFor(circleId)
        if (dests.isNotEmpty() && dests.all { isBackedUp(it, ref) }) return
        val blob = LocalMedia.rawSealed(ref) ?: return
        val key = mediaKey(ref)
        val chunked = blob.size > mediaChunkBytes
        val hostedHex = runCatching { relayHost?.nodeIdHex() }.getOrNull()
        for (nodeHex in dests) {
            if (isBackedUp(nodeHex, ref)) continue   // already confirmed on this relay
            // S3-BUCKET relay: put via the S3 FFI (relayClientFor can't dial an "s3:" pseudo-node).
            if (nodeHex.startsWith("s3:")) {
                val cfg = StorageStore.s3Config(appContext) ?: continue
                runCatching {
                    if (chunked) {
                        val sizes = chunkOffsets(blob.size).mapIndexed { i, (from, to) ->
                            uniffi.haven_ffi.s3Put(cfg, mediaChunkKey(ref, i), blob.copyOfRange(from, to)); to - from
                        }
                        uniffi.haven_ffi.s3Put(cfg, key, makeManifest(sizes))
                    } else {
                        uniffi.haven_ffi.s3Put(cfg, key, blob)
                    }
                }.onSuccess { markRelaySeen(nodeHex); markBackedUp(nodeHex, ref) }
                    .onFailure { android.util.Log.d(TAG, "s3 media put failed ($nodeHex): ${it.message}") }
                continue
            }
            // Our OWN hosted relay: write straight into the local store (never dial/HTTP ourselves).
            if (hostedHex != null && nodeHex == hostedHex) {
                runCatching {
                    if (chunked) {
                        val sizes = chunkOffsets(blob.size).mapIndexed { i, (from, to) ->
                            relayHost?.localPut(mediaChunkKey(ref, i), blob.copyOfRange(from, to)); to - from
                        }
                        relayHost?.localPut(key, makeManifest(sizes))
                    } else {
                        relayHost?.localPut(key, blob)
                    }
                }.onSuccess { markBackedUp(nodeHex, ref) }
                continue
            }
            // Relay HTTP interface — the DEFAULT cross-NAT path. Success = done for this relay
            // (the iroh path serves the same store); unreachable → fall back to the iroh put.
            val entry = relayEntries[nodeHex]
            if (entry != null && httpUrlsFor(entry).isNotEmpty()) {
                if (httpUploadMedia(entry, ref, key, blob, chunked)) {
                    markRelaySeen(nodeHex); markBackedUp(nodeHex, ref)
                    android.util.Log.i("MediaSync", "HTTP uploaded ref=$ref to ${nodeHex.take(8)}")
                    continue
                }
            }
            val client = relayClientFor(nodeHex) ?: continue
            runCatching {
                if (chunked) {
                    val sizes = chunkOffsets(blob.size).mapIndexed { i, (from, to) ->
                        client.put(mediaChunkKey(ref, i), blob.copyOfRange(from, to)); to - from
                    }
                    client.put(key, makeManifest(sizes))
                } else {
                    client.put(key, blob)
                }
            }
                .onSuccess { markRelayOk(nodeHex); markBackedUp(nodeHex, ref) }
                .onFailure { relayFailed(nodeHex) }
        }
    }

    /** Byte ranges of each 8 MB chunk over a blob of [size] bytes: list of (from, toExclusive). */
    private fun chunkOffsets(size: Int): List<Pair<Int, Int>> {
        val out = ArrayList<Pair<Int, Int>>()
        var off = 0
        while (off < size) { val end = minOf(off + mediaChunkBytes, size); out.add(off to end); off = end }
        return out
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
                if (r.isFailure) {
                    android.util.Log.i("MediaSync", "  http $base unreachable (${r.exceptionOrNull()?.message})")
                    markHttpUrlBad(base); continue
                }
                val head = r.getOrNull()
                if (head == null) { httpMiss = true; break }
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
        android.util.Log.i("MediaSync", "fetch ref=$ref FAILED — no relay served it")
        return false
    }

    /**
     * Persist a fetched media [head] for [ref]. If [head] is a chunk manifest, fetch each chunk via
     * [getChunk] and APPEND it to a temp file on disk (streaming — the full sealed blob is never held in
     * RAM), then adopt it. Otherwise [head] IS the sealed blob (legacy/small). Returns false on any
     * missing chunk so the caller can try the next relay.
     */
    private suspend fun reassembleInto(ref: String, head: ByteArray, getChunk: suspend (Int) -> ByteArray?): Boolean {
        val count = parseManifest(head)
        if (count == null) { LocalMedia.writeRawSealed(ref, head); return true }
        val part = LocalMedia.newSealedPart(ref)
        for (i in 0 until count) {
            val chunk = getChunk(i)
            if (chunk == null || !LocalMedia.appendSealedPart(part, chunk)) {
                runCatching { part.delete() }
                android.util.Log.i("MediaSync", "reassemble ref=$ref FAILED at chunk $i/$count")
                return false
            }
        }
        val ok = LocalMedia.adoptSealedPart(ref, part)
        if (!ok) runCatching { part.delete() }
        android.util.Log.i("MediaSync", "reassemble ref=$ref chunks=$count adopted=$ok")
        return ok
    }

    /** Frame 3: [hex64 requester][ref]. If we hold the bytes, stream them back as sealed chunks. */
    private fun handleMediaRequest(body: ByteArray) {
        if (body.size <= 64) return
        val requester = String(body.copyOfRange(0, 64), Charsets.UTF_8)
        if (requester.length != 64) return
        val ref = String(body.copyOfRange(64, body.size), Charsets.UTF_8)
        if (ref.isEmpty() || !LocalMedia.has(ref)) return
        // Rate-limit: a waiting requester re-asks every cycle, so without this we re-served the same blobs
        // hundreds of times and flooded the send queue so nothing drained. One serve per ref per 25s.
        if (!shouldServeNearby(ref)) return
        val bytes = LocalMedia.loadAnyCircle(ref) ?: return
        scope.launch { sendMediaChunks(ref, bytes, requester) }
    }

    /**
     * Stream [bytes] to [requesterHex] as individually-sealed 32KB chunks. OWN-device requests (the
     * requester is my own account) are symmetric-sealed with the account-derived key so they ALWAYS open
     * on a sibling (KEM-to-self decap is unreliable); a friend requester gets a per-recipient KEM seal.
     * Runs on the IO scope — file read + seal happen off the main thread (heavy streaming caused severe
     * UI lag on iOS when on-main). iOS sendMediaChunks parity.
     */
    private suspend fun sendMediaChunks(ref: String, bytes: ByteArray, requesterHex: String) {
        val total = maxOf(1, (bytes.size + mediaChunkSize - 1) / mediaChunkSize)
        SyncMetrics.incOut()   // a media item is being served/pushed (iOS nbMediaOut += 1)
        val refBytes = ref.toByteArray(Charsets.UTF_8)
        val isOwn = runCatching { social.myNodeHex() }.getOrNull() == requesterHex
        var index = 0
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + mediaChunkSize, bytes.size)
            val chunk = bytes.copyOfRange(offset, end)
            val sealed = if (isOwn) sealOwnMedia(chunk) else runCatching { social.sealMedia(requesterHex, chunk) }.getOrNull()
            if (sealed == null) return
            sendFrame(Wire.MEDIA_CHUNK, chunkFrame(refBytes, index, total, sealed), requesterHex)
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
        if (ref.isEmpty() || total <= 0 || LocalMedia.has(ref)) return
        // Own-device chunks are symmetric (account-key) sealed; friend chunks are KEM. Try the cheap
        // symmetric open first, then fall back to the engine's KEM open. iOS handleMediaChunk parity.
        val plain = openOwnMedia(sealed) ?: runCatching { social.openMedia(sealed) }.getOrNull() ?: return
        val entry = incomingMedia.getOrPut(ref) { IncomingMedia(total) }
        entry.chunks[index] = plain
        if (entry.chunks.size >= entry.total) {
            incomingMedia.remove(ref)   // detach first so a failure below can't leak the chunk map
            val totalSize = entry.chunks.values.sumOf { it.size }
            // OOM GUARD: sealCircleMedia needs the WHOLE plaintext in memory, so storing a media costs
            // ~3× its size (chunk map + full array + sealed output). A large (e.g. 146 MB) iOS video
            // therefore crashed the app with OutOfMemoryError mid-call. Skip anything too big to hold
            // safely, free each chunk as we copy to halve the peak, and catch any residual OOM rather
            // than letting it take the whole process (and the call/foreground service) down.
            val safeCap = (Runtime.getRuntime().maxMemory() / 4)
            if (totalSize <= 0 || totalSize > safeCap) { entry.chunks.clear(); return }
            val ok = runCatching {
                val full = ByteArray(totalSize)
                var p = 0
                for (i in 0 until entry.total) {
                    val c = entry.chunks.remove(i) ?: continue   // free each chunk as it's copied
                    c.copyInto(full, p); p += c.size
                }
                LocalMedia.storeUnderRef(DEFAULT_CIRCLE, ref, full)
            }.isSuccess
            entry.chunks.clear()
            if (!ok) return
            SyncMetrics.incIn()   // a media item was fully received + stored (iOS nbMediaIn += 1)
            scope.launch(Dispatchers.Main) { feedVersion.value++ }
            // "Save others' posts to Photos" — per-circle override (received media stores under the
            // default circle), falling back to the app-wide default.
            if (CircleSettings.saveOthers(DEFAULT_CIRCLE)) scope.launch { MediaSaver.autoSave(appContext, ref) }
        }
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
        relayEntries.clear()
        defaultRelayHex = prefs.getString("relayDefault", "") ?: ""
        prefs.getString("relaysSuppressed", null)?.let { raw ->
            runCatching { val a = JSONArray(raw); for (i in 0 until a.length()) suppressedRelays.add(a.getString(i)) }
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
                    )
                }
            }
        }
        // Migrate any relay that only exists in relayNodes/the default into a RelayEntry.
        migrateRelayEntries()
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
            })
        }
        // Write the new format and clear the legacy key (completes the migration).
        prefs.edit()
            .putString("relays", o.toString())
            .putString("relaysSuppressed", JSONArray().apply { suppressedRelays.forEach { put(it) } }.toString())
            .putString("relayEntries", entriesArr.toString())
            .putString("relayDefault", defaultRelayHex)
            .remove("relayNodes").apply()
    }

    /** Whether any circle has a mailbox configured — Haven relay node or S3 pool (UI indicator). */
    fun hasRelay(): Boolean = relayNodes.values.any { it.isNotEmpty() } || Presign.anyBootstrap()

    fun reset() {
        contacts.clear(); pending.clear(); blocked.clear(); initiated.clear()
        relayNodes.clear(); relayClients.clear(); relayHealth.clear(); seenMailbox.clear()
        relayEntries.clear(); suppressedRelays.clear(); defaultRelayHex = ""
        Presign.reset()
        CircleLock.reset()
        AvatarStore.clear()
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

    /** Connect (cached) to a relay, honoring backoff. Public wrapper so the coordinator can list/get/put. */
    suspend fun selfSyncRelayClient(nodeHex: String): RelayClient? = relayClientFor(nodeHex)
    suspend fun selfSyncRelayFailed(nodeHex: String) = relayFailed(nodeHex)
    fun selfSyncRelayOk(nodeHex: String) = markRelayOk(nodeHex)

    // ---- Local store mutation for self-sync apply() --------------------------------------

    /** Upsert a contact from a converged self-sync entry (no networking). */
    fun selfSyncUpsertContact(c: Contact) {
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
        persist()
        scope.launch(Dispatchers.Main) { feedVersion.value++; circlesVersion.value++ }
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
