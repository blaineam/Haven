package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import uniffi.haven_ffi.AccountStateHandle
import uniffi.haven_ffi.CircleSyncRecord
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.S3ConfigFfi
import uniffi.haven_ffi.decodeCircleSync
import uniffi.haven_ffi.encodeCircleSync
import uniffi.haven_ffi.openAccountState
import uniffi.haven_ffi.s3Get
import uniffi.haven_ffi.s3List
import uniffi.haven_ffi.s3Put
import uniffi.haven_ffi.sealAccountState
import uniffi.haven_ffi.selfSyncSlotKey
import uniffi.haven_ffi.selfSyncSlotPrefix
import java.io.File
import java.security.SecureRandom

/**
 * Multi-device live sync — the Android counterpart of apple/HavenApp/SelfSync.swift (roadmap D16).
 *
 * Makes a user's OWN devices converge: each device writes a self-encrypted snapshot of its account
 * state to a per-account mailbox slot it owns, and merges its peers' slots. The merge is the CRDT in
 * `p2pcore::selfsync` (last-write-wins per key), exposed through the FFI (`AccountStateHandle`,
 * `sealAccountState`/`openAccountState`, `selfSyncSlotKey`). The relay only ever holds ciphertext
 * sealed with a key only this account's devices can derive.
 *
 * Scope: PROFILE (name/emoji/bio/link), GLOBAL SETTINGS, CONTACTS, the BLOCKED LIST, and CIRCLES
 * (name + member bundles + relay nodes). Scalar keys (profile/setting) apply via [get]; set-like
 * state (contacts/blocked) reconciles via [entries], with local removals propagated as tombstones.
 *
 * Transport: a RELAY (Haven relay node) OR a user-owned S3 bucket ([StorageStore]) — either alone
 * is enough, so self-sync works with no relay at all, matching iOS's `SharedStore.ownerS3()`. The
 * S3 path uses the FFI `s3List`/`s3Get`/`s3Put` against an arbitrary-key bucket with the FULL slot
 * keys (`haven/<account>/selfsync/<device>`).
 *
 * The encodings of profile/setting/blocked entries are byte-identical to iOS so the two platforms
 * converge on the same CRDT values (bool = 1 byte, retentionDays = Int32 LE). Circles use the
 * SHARED Rust encoder ([encodeCircleSync]/[decodeCircleSync]) so the circle bytes are identical on
 * iOS/Android/desktop with no hand-rolled JSON (fixes name-escaping drift).
 */
object SelfSyncCoordinator {

    private const val TAG = "SelfSync"
    private const val PREFS = "haven.selfsync"
    private const val KEY_DEVICE_ID = "haven.selfsync.deviceId"

    /** Namespaces whose keys are dynamic (set-like) — used to detect LOCAL removals so they
     *  propagate as tombstones (unblock, delete contact, LEAVE a circle). Scalar namespaces are
     *  never removed. */
    private val dynamicPrefixes = listOf("contact:", "blocked:", "circle:")

    private lateinit var appContext: Context
    private val mutex = Mutex()          // coalesce concurrent syncs (iOS `inFlight`)
    @Volatile private var initialized = false

    fun init(context: Context) {
        if (initialized) return
        appContext = context.applicationContext
        initialized = true
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Last converged state, persisted so we can detect what changed locally (LWW only advances a
     *  key's stamp when its value actually changes — otherwise two devices would ping-pong). */
    private val baseFile: File get() = File(appContext.filesDir, "haven-selfsync.bin")

    /** Erase this device's self-sync base — on factory reset or when adopting a DIFFERENT identity, so a
     *  freshly-restored device never diffs its empty engine against a STALE base and tombstones the whole
     *  account (the data-loss bug). */
    fun reset() { runCatching { baseFile.delete() } }

    /**
     * A stable **per-device** id. All of a user's devices share the account seed (same node id), so
     * each physical device needs its own id to own a sync slot and to break LWW ties. Random 32
     * bytes, generated once, stored device-local in SharedPreferences (hex), NEVER synced.
     */
    private val deviceId: ByteArray by lazy {
        val hex = prefs.getString(KEY_DEVICE_ID, null)
        val existing = hex?.let { fromHex(it) }
        if (existing != null && existing.size == 32) {
            existing
        } else {
            val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
            prefs.edit().putString(KEY_DEVICE_ID, toHex(bytes)).apply()
            bytes
        }
    }

    /** Stable per-DEVICE hex (distinct from the account/node id, which all of a user's devices share).
     *  Used to disambiguate own devices on the proximity mesh so two seed-copies don't advertise an
     *  identical endpoint name and fail to connect. */
    val deviceHex: String get() = toHex(deviceId)

    // MARK: state <-> CRDT mapping

    /**
     * The current local state as namespaced key -> value bytes (no stamps). [social] contributes
     * circle structure; without it, circles are simply not snapshotted.
     */
    private fun currentLocal(social: HavenSocial?): Map<String, ByteArray> {
        val m = LinkedHashMap<String, ByteArray>()
        val p = ProfileStore.get(appContext)
        m["profile:name"] = p.displayName.toByteArray(Charsets.UTF_8)
        m["profile:emoji"] = p.emoji.toByteArray(Charsets.UTF_8)
        m["profile:bio"] = p.bio.toByteArray(Charsets.UTF_8)
        m["profile:link"] = p.link.toByteArray(Charsets.UTF_8)
        // Settings live on ProfileStore on Android. Use iOS's exact key names where the concept
        // matches. (Android has no "silent" — skip it.)
        m["setting:saveToPhotos"] = byteArrayOf(if (p.saveMyPosts) 1 else 0)
        m["setting:saveOthersToPhotos"] = byteArrayOf(if (p.saveOthersPosts) 1 else 0)
        m["setting:autoOptimize"] = byteArrayOf(if (p.autoOptimize) 1 else 0)
        m["setting:retentionDays"] = int32LE(p.retentionDays)
        // DM read watermarks — reading a thread on one device clears its badge on the others. JSON
        // map circleId → unix-ms (the iOS wire format), merged per-key MAX on apply (monotonic —
        // no device can un-read another). Never published empty (a fresh device changes nothing).
        DmRead.toJsonBytes()?.let { m["setting:dmLastRead"] = it }
        // Roster: contacts (full card) + blocked list.
        for (c in HavenNet.selfSyncContactsSnapshot()) {
            m["contact:${c.idHex}"] = encodeContact(c)
        }
        for (hex in HavenNet.selfSyncBlockedSnapshot()) {
            m["blocked:$hex"] = byteArrayOf(1)
        }
        // Explicit circle severances — LWW per entry: 1 = removed, 0 = deliberately re-added. The 0
        // write is what lets a re-add stick fleet-wide (grow-only removals re-severed a re-added
        // friend on every sibling sync pass). Never inferred from member absence.
        for (entry in CircleRemovals.all()) {
            m["removal:$entry"] = byteArrayOf(1)
        }
        for (entry in CircleRemovals.allCleared()) {
            m["removal:$entry"] = byteArrayOf(0)
        }
        // Relay DELETIONS — LWW by the forget timestamp, so deleting a relay on one device drops it on all
        // of them (and stops a sibling re-announcing it). Value = 8-byte LE forgotAt (ms). Without this the
        // deletion was device-local and a sibling kept the relay active + re-announcing it (deleted relays
        // keep returning). iOS SelfSync parity.
        for ((hex, ms) in HavenNet.relayForgottenRecords()) m["relay-removal:$hex"] = int64LE(ms)
        // …and re-adds under a DISTINCT key carrying their OWN re-add timestamp (NOT a bare 0), so a delete
        // and a re-add resolve by LWW on the semantic time (newest wins) instead of a grow-only clear always
        // winning — the "I delete a relay and it keeps coming back" fix. iOS SelfSync parity.
        for ((hex, ms) in HavenNet.relayClearedForgetRecords()) m["relay-readd:$hex"] = int64LE(ms)
        // Circles: name + member bundles + relay nodes, so another device can reconstruct each
        // circle and seal to every member. Encoded by the SHARED Rust encoder so the bytes are
        // identical across iOS/Android/desktop (member set is authoritative — see applyLocal).
        if (social != null) {
            for (ci in runCatching { social.circles() }.getOrDefault(emptyList())) {
                val members = runCatching { social.circleMemberBundles(ci.id) }.getOrDefault(emptyList())
                val relays = HavenNet.relaysForCircle(ci.id)
                m["circle:${ci.id}"] = runCatching { encodeCircleSync(ci.name, members, relays) }.getOrNull()
                    ?: continue
            }
            // Contact device ROSTERS — so a freshly-linked device learns which device ids to DIAL/seal for
            // each friend directly from a sibling that already knows them, instead of dialing dead account
            // ids and timing out (the regression that made friend comms fail on a new device). Keyed by
            // account hex so a newer roster version replaces the old. Additive (never tombstoned).
            for (r in runCatching { social.exportContactRosters() }.getOrDefault(emptyList())) {
                m["roster:${r.accountHex}"] = r.wire
            }
            // My OWN device roster — fixes the own-device bootstrap deadlock (a sibling device that's
            // never nearby and shares no relay never learned THIS device's id, so its relay rejected us
            // with ERR forbidden and our relay-deletion tombstones never propagated). Shares the roster:
            // namespace so the ingest loop union-merges our device id into the sibling's own-account list.
            for (r in runCatching { social.exportOwnRoster() }.getOrDefault(emptyList())) {
                m["roster:${r.accountHex}"] = r.wire
            }
        }
        return m
    }

    /**
     * Write a merged state back into the local stores (only when a value actually differs, to avoid
     * feedback loops through the stores' observers).
     */
    private fun applyLocal(h: AccountStateHandle, social: HavenSocial?) {
        val p = ProfileStore.get(appContext)
        strValue(h, "profile:name")?.let { if (it != p.displayName) { p.displayName = it; p.save() } }
        strValue(h, "profile:emoji")?.let { if (it != p.emoji) { p.emoji = it; p.save() } }
        strValue(h, "profile:bio")?.let { if (it != p.bio) { p.bio = it; p.save() } }
        strValue(h, "profile:link")?.let { if (it != p.link) { p.link = it; p.save() } }

        boolValue(h, "setting:saveToPhotos")?.let { if (it != p.saveMyPosts) p.saveMyPosts = it }
        boolValue(h, "setting:saveOthersToPhotos")?.let { if (it != p.saveOthersPosts) p.saveOthersPosts = it }
        boolValue(h, "setting:autoOptimize")?.let { if (it != p.autoOptimize) p.autoOptimize = it }
        h.get("setting:retentionDays")?.let { v ->
            if (v.size == 4) {
                val n = int32LEValue(v)
                if (n != p.retentionDays) p.setRetention(n)
            }
        }
        // DM read watermarks from my other devices: per-key MAX merge (monotonic — always safe).
        // DmRead bumps its own version on change, so unread badges recompose by themselves.
        h.get("setting:dmLastRead")?.let { DmRead.applySyncedJson(it) }

        // Roster reconciliation (set-like — enumerate the converged state via entries()).
        val live = h.entries()

        // Contact rosters synced from another of my devices → ingest so THIS device can also dial + seal to
        // each friend's CURRENT devices (verified against the account bundle carried inside the wire). This
        // is what lets a freshly-linked device reach friends it never contacted directly — it inherits their
        // device ids from a sibling. Idempotent + version-checked in the engine, so a stale roster can't roll
        // anything back. Additive (roster: is never in dynamicPrefixes, so it's never tombstoned).
        if (social != null) {
            for (e in live) if (e.key.startsWith("roster:")) {
                runCatching { social.ingestRosterWire(e.value) }
            }
        }

        // Contacts: upsert everything present; drop locals the converged state no longer has
        // (a contact deleted on another device propagated as a tombstone).
        val wantContacts = HashMap<String, Contact>()
        for (e in live) if (e.key.startsWith("contact:")) {
            decodeContact(e.value)?.let { wantContacts[it.idHex] = it }
        }
        for (c in wantContacts.values) HavenNet.selfSyncUpsertContact(c)
        // ADDITIVE ONLY — never remove a contact a peer simply doesn't list. Absence-based removal made a
        // freshly-restored (empty) device wipe the primary's contacts/circles/posts. (Same data-loss bug
        // fixed on iOS.) Real deletions propagate as explicit, intentional records, not from absence.

        // Blocked list: reconcile both directions.
        val wantBlocked = HashSet<String>()
        for (e in live) if (e.key.startsWith("blocked:")) {
            wantBlocked.add(e.key.removePrefix("blocked:"))
        }
        val haveBlocked = HavenNet.selfSyncBlockedSnapshot().toHashSet()
        for (hex in wantBlocked - haveBlocked) HavenNet.selfSyncSetBlocked(hex, true)
        for (hex in haveBlocked - wantBlocked) HavenNet.selfSyncSetBlocked(hex, false)

        // Explicit circle severances synced from our other devices: value 1 → record locally so the
        // member won't be re-added below + apply the removal to the circle here too. Value 0 → the
        // removal was deliberately CLEARED (re-added) on another device: un-ban locally and never
        // re-sever; the member bundle comes back via the additive circle: record.
        for (e in live) if (e.key.startsWith("removal:")) {
            val body = e.key.removePrefix("removal:")
            val cid = body.substringBefore("|")
            val hex = body.substringAfter("|", "")
            if (cid.isNotEmpty() && hex.isNotEmpty()) {
                if (e.value.firstOrNull()?.toInt() == 0) {
                    if (CircleRemovals.contains(cid, hex)) CircleRemovals.remove(cid, hex)
                } else {
                    CircleRemovals.add(cid, hex)
                    if (social != null) runCatching { social.removeFromCircle(cid, hex) }
                }
            }
        }

        // Relay delete vs re-add from any of my devices, resolved by LWW on the SEMANTIC timestamp (delete
        // time vs re-add time) — NOT by which device synced last. Gather both sides, newest wins per relay.
        // Applied BEFORE the circle: records below re-add relays, so a relay whose newest verdict is
        // "deleted" stays gone. A passive re-announce never auto-resurrects it. iOS SelfSync parity.
        val relayRemovalMs = HashMap<String, Long>()
        val relayReaddMs = HashMap<String, Long>()
        for (e in live) if (e.value.size == 8) {
            when {
                e.key.startsWith("relay-removal:") -> {
                    val hex = e.key.removePrefix("relay-removal:")
                    if (hex.isNotEmpty()) relayRemovalMs[hex] = maxOf(relayRemovalMs[hex] ?: 0L, int64LEValue(e.value))
                }
                e.key.startsWith("relay-readd:") -> {
                    val hex = e.key.removePrefix("relay-readd:")
                    if (hex.isNotEmpty()) relayReaddMs[hex] = maxOf(relayReaddMs[hex] ?: 0L, int64LEValue(e.value))
                }
            }
        }
        for (hex in (relayRemovalMs.keys + relayReaddMs.keys)) {
            val del = relayRemovalMs[hex] ?: 0L
            val readd = relayReaddMs[hex] ?: 0L
            if (del > readd) HavenNet.applyRelayForgottenTombstone(hex, del)   // deleted, newer than any re-add
            else if (readd > 0L) HavenNet.applyRelayClearedForget(hex, readd)  // re-added, newer than any delete
        }

        // Circles: reconcile each synced circle — create it + register every member's bundle so this
        // device can seal to them, and record its relay mailbox(es). ADDITIVE in v1 (no absence-based
        // leave/prune — see the strictly-additive note below).
        if (social != null) {
            val existing = runCatching { social.circles() }.getOrDefault(emptyList())
            for (e in live) if (e.key.startsWith("circle:")) {
                val id = e.key.removePrefix("circle:")
                val cs = decodeCircleSync(e.value) ?: continue
                runCatching { social.createCircle(id, cs.name) }   // no-op if it already exists
                val cur = existing.firstOrNull { it.id == id }
                if (cur != null && cur.name != cs.name) runCatching { social.renameCircle(id, cs.name) }

                // STRICTLY ADDITIVE: register every synced member's bundle (no-op if already present).
                // We do NOT remove members or leave circles based on a peer's absence — that is exactly
                // what wiped accounts when a freshly-restored (empty) device synced. Explicit circle-leave
                // / member-removal must be driven by an intentional action, not inferred from absence.
                for (bundle in cs.memberBundles) {
                    if (CircleRemovals.contains(id, nodeHex(bundle))) continue // severed — never re-add
                    runCatching { social.addContactBundle(id, bundle) }
                }
                for (node in cs.relays) HavenNet.selfSyncAddRelay(id, node)
            }
        }
    }

    // MARK: sync

    /**
     * One full sync pass: fold local changes into the base with fresh stamps, merge every peer slot,
     * apply the converged result locally, persist, and re-publish our own slot. Safe to call on a
     * timer; coalesces if already running. No-op without an account or any transport (relay OR S3).
     * Returns true if the merge brought in changes from another device (so the caller can refresh).
     */
    suspend fun sync(social: HavenSocial?): Boolean {
        if (!initialized) return false
        if (mutex.isLocked) return false   // coalesce (iOS `inFlight`)
        return mutex.withLock { syncLocked(social) }
    }

    /**
     * A self-sync transport: list/get/put the per-device slots. Either a Haven RELAY node or a
     * user-owned S3 bucket — self-sync needs only ONE, matching iOS's relay-or-ownerS3() choice.
     */
    private interface Transport {
        suspend fun list(prefix: String): List<String>?
        suspend fun get(key: String): ByteArray?
        suspend fun put(key: String, data: ByteArray): Boolean
    }

    private class RelayTransport(val nodeHex: String) : Transport {
        override suspend fun list(prefix: String): List<String>? {
            val client = HavenNet.selfSyncRelayClient(nodeHex) ?: return null
            val keys = runCatching { client.list(prefix) }.getOrNull()
            if (keys == null) HavenNet.selfSyncRelayFailed(nodeHex) else HavenNet.selfSyncRelayOk(nodeHex)
            return keys
        }
        override suspend fun get(key: String): ByteArray? {
            val client = HavenNet.selfSyncRelayClient(nodeHex) ?: return null
            return runCatching { client.get(key) }.getOrNull()
        }
        override suspend fun put(key: String, data: ByteArray): Boolean {
            val client = HavenNet.selfSyncRelayClient(nodeHex) ?: return false
            return runCatching { client.put(key, data) }
                .onSuccess { HavenNet.selfSyncRelayOk(nodeHex) }
                .onFailure { Log.d(TAG, "slot put failed ($nodeHex): ${it.message}"); HavenNet.selfSyncRelayFailed(nodeHex) }
                .isSuccess
        }
    }

    private class S3Transport(val config: S3ConfigFfi) : Transport {
        override suspend fun list(prefix: String): List<String>? =
            runCatching { s3List(config, prefix) }.getOrElse { Log.d(TAG, "s3 list failed: ${it.message}"); null }
        override suspend fun get(key: String): ByteArray? =
            runCatching { s3Get(config, key) }.getOrNull()
        override suspend fun put(key: String, data: ByteArray): Boolean =
            runCatching { s3Put(config, key, data) }
                .onFailure { Log.d(TAG, "s3 put failed: ${it.message}") }
                .isSuccess
    }

    private suspend fun syncLocked(social: HavenSocial?): Boolean {
        val seed = HavenNet.accountSeed
        val accountHex = HavenNet.accountNodeHex
        if (accountHex.isEmpty()) return false

        // Transports = every relay (existing) + the user's own S3 bucket if configured. Self-sync
        // now works with a relay OR an S3 bucket (no relay required) — matching iOS/desktop.
        val transports = ArrayList<Transport>()
        for (nodeHex in HavenNet.selfSyncRelays()) transports.add(RelayTransport(nodeHex))
        StorageStore.s3Config(appContext)?.let { transports.add(S3Transport(it)) }
        if (transports.isEmpty()) return false   // nothing to sync over

        // 1. Base = last converged state (or empty).
        val base: AccountStateHandle = run {
            val data = runCatching { if (baseFile.exists()) baseFile.readBytes() else null }.getOrNull()
            if (data != null) runCatching { AccountStateHandle.fromBytes(data) }.getOrNull() ?: AccountStateHandle()
            else AccountStateHandle()
        }

        // 2. Fold in whatever changed locally since last sync (stamp = now, this device).
        val now = System.currentTimeMillis().toULong()
        val local = currentLocal(social)
        for ((key, value) in local) {
            if (!value.contentEquals(base.get(key))) {
                runCatching { base.set(key, value, now, deviceId) }
            }
        }
        // Detect local removals in dynamic namespaces and tombstone them so the removal propagates —
        // BUT NOT when the engine looks freshly-empty (no circles locally while the base still has
        // circles). That signature is a just-restored / unready device, and tombstoning there is exactly
        // what wiped accounts. In that state we only ADD, never remove.
        val localHasCircle = local.keys.any { it.startsWith("circle:") }
        val baseHasCircle = base.entries().any { it.key.startsWith("circle:") }
        if (localHasCircle || !baseHasCircle) {
            for (e in base.entries()) {
                if (dynamicPrefixes.any { e.key.startsWith(it) } && !local.containsKey(e.key)) {
                    runCatching { base.remove(e.key, now, deviceId) }
                }
            }
        }

        // Snapshot post-fold so we can tell whether the merge below actually brought anything new.
        val preMerge = base.toBytes()

        // 3. Pull + merge every peer slot from every transport (FULL keys: haven/<slot>).
        val prefix = "haven/" + selfSyncSlotPrefix(accountHex)
        val ownKey = "haven/" + selfSyncSlotKey(accountHex, deviceHex)
        for (t in transports) {
            val keys = t.list(prefix) ?: continue
            for (key in keys) {
                if (key == ownKey) continue
                val blob = t.get(key) ?: continue
                val peer = runCatching { openAccountState(seed, blob) }.getOrNull() ?: continue
                base.merge(peer)
            }
        }

        val changed = !base.toBytes().contentEquals(preMerge)

        // 4. Apply the converged state locally + persist the new base.
        applyLocal(base, social)
        runCatching { baseFile.writeBytes(base.toBytes()) }
            .onFailure { Log.e(TAG, "persist base failed", it) }
        if (changed) HavenNet.selfSyncDidApply()

        // 5. Re-publish our own slot (sealed) to every transport for redundancy.
        val sealed = runCatching { sealAccountState(seed, base) }.getOrNull() ?: return changed
        for (t in transports) t.put(ownKey, sealed)
        return changed
    }

    // MARK: encodings (byte-identical to iOS)

    /** Stable Android contact JSON. Need NOT match iOS (structs differ) — just stable on Android. */
    private fun encodeContact(c: Contact): ByteArray =
        JSONObject().apply {
            put("id_hex", c.idHex)
            put("name", c.name)
            put("verify", c.verifyHex)
        }.toString().toByteArray(Charsets.UTF_8)

    private fun decodeContact(bytes: ByteArray): Contact? = runCatching {
        val o = JSONObject(String(bytes, Charsets.UTF_8))
        Contact(o.getString("id_hex"), o.optString("name", ""), o.optString("verify", ""))
    }.getOrNull()

    private fun int32LE(v: Int): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(),
        ((v ushr 8) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(),
        ((v ushr 24) and 0xFF).toByte(),
    )

    private fun int32LEValue(b: ByteArray): Int =
        (b[0].toInt() and 0xFF) or
            ((b[1].toInt() and 0xFF) shl 8) or
            ((b[2].toInt() and 0xFF) shl 16) or
            ((b[3].toInt() and 0xFF) shl 24)

    /** 8-byte little-endian encoding of an unsigned ms timestamp (byte-identical to iOS's LE UInt64). */
    private fun int64LE(v: Long): ByteArray = ByteArray(8) { i -> ((v ushr (i * 8)) and 0xFF).toByte() }

    private fun int64LEValue(b: ByteArray): Long {
        var v = 0L
        for (i in 0 until 8) v = v or ((b[i].toLong() and 0xFF) shl (i * 8))
        return v
    }

    private fun boolValue(h: AccountStateHandle, key: String): Boolean? {
        val v = h.get(key) ?: return null
        if (v.isEmpty()) return null
        return v[0].toInt() == 1
    }

    private fun strValue(h: AccountStateHandle, key: String): String? =
        h.get(key)?.let { String(it, Charsets.UTF_8) }

    // MARK: hex helpers

    private fun toHex(b: ByteArray): String =
        b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun fromHex(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        var i = 0
        while (i < hex.length) {
            val byte = hex.substring(i, i + 2).toIntOrNull(16) ?: return null
            out[i / 2] = byte.toByte()
            i += 2
        }
        return out
    }
}
