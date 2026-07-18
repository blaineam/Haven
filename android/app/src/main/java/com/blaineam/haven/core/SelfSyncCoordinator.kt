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
import uniffi.haven_ffi.openAccountStateDual
import uniffi.haven_ffi.openAccountStateWithKey
import uniffi.haven_ffi.s3Get
import uniffi.haven_ffi.s3List
import uniffi.haven_ffi.s3Put
import uniffi.haven_ffi.sealAccountState
import uniffi.haven_ffi.sealAccountStateWithKey
import uniffi.haven_ffi.sealAccountStateWithKeyEpoch
import uniffi.haven_ffi.selfSyncGrantSlotKey
import uniffi.haven_ffi.selfSyncGrantSlotPrefix
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

    /** Persisted one-shot: while set, this (freshly-enrolled seedless) device NEVER tombstones — it only
     *  ADDS — until the primary's slot has been merged in. */
    private const val KEY_ENROLL_BASELINE = "seedless.awaiting.first.merge"

    /**
     * Seed-drop S4 absence-as-deletion guard (plan §7). A freshly-enrolled seedless device starts with an
     * EMPTY engine; if it diffed that against the base and pushed tombstones before ingesting the primary's
     * slot, it would wipe the account's circles/contacts. So on enrollment we (a) reset the base to empty
     * and (b) arm a persisted flag that FORCES additive-only self-sync until the primary's pushed slot has
     * been merged in — i.e. the base is initialized from the primary's first pushed slot BEFORE any local
     * diff can produce a removal. Called from HavenCore.installSeedless during grant acceptance.
     */
    fun beginSeedlessEnrollment() {
        reset()   // empty base — the first merge fills it from the primary's slot (never a stale diff)
        if (::appContext.isInitialized) runCatching { prefs.edit().putBoolean(KEY_ENROLL_BASELINE, true).apply() }
    }

    private fun awaitingEnrollBaseline(): Boolean =
        runCatching { prefs.getBoolean(KEY_ENROLL_BASELINE, false) }.getOrDefault(false)
    private fun clearEnrollBaseline() = runCatching { prefs.edit().remove(KEY_ENROLL_BASELINE).apply() }

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
        // Only broadcast NON-EMPTY profile scalars — a fresh/empty device must never stamp a blank value
        // that then wins last-writer-wins and REVERTS a sibling's real profile (absence is not
        // authoritative). Mirrors iOS SelfSync.currentLocal.
        if (p.displayName.isNotEmpty()) m["profile:name"] = p.displayName.toByteArray(Charsets.UTF_8)
        if (p.emoji.isNotEmpty()) m["profile:emoji"] = p.emoji.toByteArray(Charsets.UTF_8)
        if (p.bio.isNotEmpty()) m["profile:bio"] = p.bio.toByteArray(Charsets.UTF_8)
        if (p.link.isNotEmpty()) m["profile:link"] = p.link.toByteArray(Charsets.UTF_8)
        // LWW timestamps per profile field — so two of my devices resolve a profile edit by WHO EDITED
        // LAST, not who synced last (the endless profile ping-pong). See ProfileStore.fieldTs.
        for (f in listOf("name", "emoji", "bio", "link")) {
            val ts = p.fieldTimestamp(f); if (ts > 0) m["profile-at:$f"] = int64LE(ts)
        }
        // Settings live on ProfileStore on Android. Use iOS's exact key names where the concept
        // matches. (Android has no "silent" — skip it.)
        m["setting:saveToPhotos"] = byteArrayOf(if (p.saveMyPosts) 1 else 0)
        m["setting:saveOthersToPhotos"] = byteArrayOf(if (p.saveOthersPosts) 1 else 0)
        m["setting:autoOptimize"] = byteArrayOf(if (p.autoOptimize) 1 else 0)
        m["setting:retentionDays"] = int32LE(p.retentionDays)
        // LWW timestamps for the synced settings — resolved by WHO CHANGED it last, not who synced last.
        // The keys are the iOS storage-key strings so `setting-at:<key>` is byte-identical cross-platform.
        for (k in listOf(ProfileStore.TS_SAVE, ProfileStore.TS_SAVE_OTHERS, ProfileStore.TS_OPT, ProfileStore.TS_RET)) {
            val ts = p.settingTimestamp(k); if (ts > 0) m["setting-at:$k"] = int64LE(ts)
        }
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
        // Contact removals — LWW by timestamp (contacts sync additive-only, so a delete needs an explicit
        // newest-wins tombstone to stick fleet-wide). 8-byte LE ms per hex. Mirrors iOS.
        for ((hex, ms) in ContactRemovals.removedAtMap()) m["contact-removed:$hex"] = int64LE(ms)
        for ((hex, ms) in ContactRemovals.readdedAtMap()) m["contact-readd:$hex"] = int64LE(ms)
        // Whole-circle / DM deletions — LWW, so deleting a DM/circle on one device deletes it on all of
        // them instead of a sibling's `circle:` record re-creating it. 8-byte LE ms per circle id.
        for ((id, ms) in CircleDeletion.deletedAtMap()) m["circle-deleted:$id"] = int64LE(ms)
        for ((id, ms) in CircleDeletion.recreatedAtMap()) m["circle-recreated:$id"] = int64LE(ms)
        // Explicit circle severances — LWW by TIMESTAMP so a fresh removal beats a stale re-add and vice
        // versa (the fix for "removals don't sync / re-adds get re-severed"). Two distinct keys carry
        // their own 8-byte LE ms, resolved newest-wins on apply. Also still emit the legacy `removal:` =
        // 1/0 (derived from the current verdict) so a pre-LWW sibling keeps converging during the rollout —
        // those carry no time, so a new build treats them as ts=1 and they never override a real write.
        val cRemovedAt = CircleRemovals.removedAtMap()
        val cReaddedAt = CircleRemovals.readdedAtMap()
        for ((entry, ms) in cRemovedAt) m["circle-removed:$entry"] = int64LE(ms)
        for ((entry, ms) in cReaddedAt) m["circle-readd:$entry"] = int64LE(ms)
        for (entry in cRemovedAt.keys + cReaddedAt.keys) {
            val removed = (cRemovedAt[entry] ?: 0L) > (cReaddedAt[entry] ?: 0L)
            m["removal:$entry"] = byteArrayOf(if (removed) 1 else 0)
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
                // Don't re-broadcast a circle the user DELETED (LWW): its `circle-deleted:` record carries
                // the deletion, and re-emitting the `circle:` row would fight it every sync.
                if (CircleDeletion.isDeleted(ci.id)) continue
                val members = runCatching { social.circleMemberBundles(ci.id) }.getOrDefault(emptyList())
                val relays = HavenNet.relaysForCircle(ci.id)
                // AUDIT M2 (§2): stamp the DEFINITION-bound creator so the authority root travels with the
                // authenticated circle definition to my other devices. I only know it for circles I created
                // (creator = my account id); peer-created circles carry null and learn the root out-of-band.
                val creator: ByteArray? =
                    if (HavenNet.selfSyncCreatedCircle(ci.id)) fromHex(HavenNet.accountNodeHex) else null
                m["circle:${ci.id}"] = runCatching { encodeCircleSync(ci.name, members, relays, creator) }.getOrNull()
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
        // Read an 8-byte LE ms timestamp for a key (0 if absent / malformed).
        fun tsOf(key: String): Long = h.get(key)?.takeIf { it.size == 8 }?.let { int64LEValue(it) } ?: 0L
        // Profile fields are LAST-WRITER-WINS by per-field timestamp — a remote value is applied only if it
        // was edited MORE RECENTLY than our local one (ends the profile ping-pong). An untimestamped legacy
        // value maps to ts=1 (barely > 0) ONLY to SEED an empty local field; it never overwrites a
        // non-empty local. A real local edit (ts=now) always wins. Mirrors iOS SelfSync.applyLocal.
        strValue(h, "profile:name")?.let { s ->
            var ts = tsOf("profile-at:name")
            if (ts == 0L && p.fieldTimestamp("name") == 0L && p.displayName.isEmpty() && s.isNotEmpty()) ts = 1L
            p.applyRemoteField("name", s, ts)
        }
        strValue(h, "profile:emoji")?.let { s ->
            if (s.isNotEmpty()) p.applyRemoteField("emoji", s, tsOf("profile-at:emoji")) // emoji has a default
        }
        strValue(h, "profile:bio")?.let { s ->
            var ts = tsOf("profile-at:bio")
            if (ts == 0L && p.fieldTimestamp("bio") == 0L && p.bio.isEmpty() && s.isNotEmpty()) ts = 1L
            p.applyRemoteField("bio", s, ts)
        }
        strValue(h, "profile:link")?.let { s ->
            var ts = tsOf("profile-at:link")
            if (ts == 0L && p.fieldTimestamp("link") == 0L && p.link.isEmpty() && s.isNotEmpty()) ts = 1L
            p.applyRemoteField("link", s, ts)
        }

        // Settings are LWW by per-key timestamp — same fix as profiles. An untimestamped legacy record (old
        // peer) maps to ts=1 so it seeds a never-touched device but can never overwrite a real local edit.
        fun settingTs(key: String): Long = tsOf("setting-at:$key").let { if (it == 0L) 1L else it }
        boolValue(h, "setting:saveToPhotos")?.let { p.applyRemoteSettingBool(ProfileStore.TS_SAVE, it, settingTs(ProfileStore.TS_SAVE)) }
        boolValue(h, "setting:saveOthersToPhotos")?.let { p.applyRemoteSettingBool(ProfileStore.TS_SAVE_OTHERS, it, settingTs(ProfileStore.TS_SAVE_OTHERS)) }
        boolValue(h, "setting:autoOptimize")?.let { p.applyRemoteSettingBool(ProfileStore.TS_OPT, it, settingTs(ProfileStore.TS_OPT)) }
        h.get("setting:retentionDays")?.let { v ->
            if (v.size == 4) p.applyRemoteRetention(int32LEValue(v), settingTs(ProfileStore.TS_RET))
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

        // Contact removals — LWW by timestamp, applied BEFORE the upsert so a removed contact is
        // tombstoned and the upsert refuses to resurrect them (contacts are otherwise additive-only, which
        // is exactly why deletes never stuck on a multi-device account). Newest of removed-vs-readd wins.
        run {
            val removedMs = HashMap<String, Long>()
            val readdMs = HashMap<String, Long>()
            for (e in live) if (e.value.size == 8) {
                when {
                    e.key.startsWith("contact-removed:") -> {
                        val hex = e.key.removePrefix("contact-removed:")
                        if (hex.isNotEmpty()) removedMs[hex] = maxOf(removedMs[hex] ?: 0L, int64LEValue(e.value))
                    }
                    e.key.startsWith("contact-readd:") -> {
                        val hex = e.key.removePrefix("contact-readd:")
                        if (hex.isNotEmpty()) readdMs[hex] = maxOf(readdMs[hex] ?: 0L, int64LEValue(e.value))
                    }
                }
            }
            for (hex in removedMs.keys + readdMs.keys) {
                val rem = removedMs[hex] ?: 0L
                val readd = readdMs[hex] ?: 0L
                if (rem >= readd && rem > 0L) {
                    if (ContactRemovals.mergeRemovedAt(hex, rem)) HavenNet.selfSyncRemoveContact(hex)
                } else if (readd > 0L) {
                    ContactRemovals.mergeReaddedAt(hex, readd)
                }
            }
        }

        // Contacts: upsert everyone present that isn't tombstone-removed (selfSyncUpsertContact enforces
        // the tombstone). ADDITIVE ONLY — never drop a contact a peer simply doesn't list.
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

        // Circle severances synced from our other devices — resolved by LAST-WRITER-WINS on timestamps, so
        // a fresh removal beats a stale re-add and a fresh re-add beats an old removal. Gather both sides
        // from the timestamped keys (plus legacy `removal:` = 1/0 mapped to ts=1 so it loses to any real
        // write), pick the newest per key, then apply. This is the fix for "removals don't sync to my other
        // device" AND the older "a sibling re-severs a re-added friend". Mirrors iOS SelfSync.applyLocal.
        run {
            val removedMs = HashMap<String, Long>()
            val readdMs = HashMap<String, Long>()
            fun norm(entry: String): String {
                val bar = entry.indexOf('|'); if (bar < 0) return entry
                return entry.substring(0, bar) + "|" + entry.substring(bar + 1).lowercase()
            }
            for (e in live) {
                when {
                    e.key.startsWith("circle-removed:") && e.value.size == 8 -> {
                        val k = norm(e.key.removePrefix("circle-removed:"))
                        removedMs[k] = maxOf(removedMs[k] ?: 0L, int64LEValue(e.value))
                    }
                    e.key.startsWith("circle-readd:") && e.value.size == 8 -> {
                        val k = norm(e.key.removePrefix("circle-readd:"))
                        readdMs[k] = maxOf(readdMs[k] ?: 0L, int64LEValue(e.value))
                    }
                    e.key.startsWith("removal:") && e.value.size == 1 -> {   // legacy pre-LWW record → ts=1
                        val k = norm(e.key.removePrefix("removal:"))
                        if (e.value[0].toInt() == 1) removedMs[k] = maxOf(removedMs[k] ?: 0L, 1L)
                        else readdMs[k] = maxOf(readdMs[k] ?: 0L, 1L)
                    }
                }
            }
            for (key in removedMs.keys + readdMs.keys) {
                val bar = key.indexOf('|'); if (bar <= 0 || bar >= key.length - 1) continue
                val cid = key.substring(0, bar)
                val hex = key.substring(bar + 1)
                val rem = removedMs[key] ?: 0L
                val readd = readdMs[key] ?: 0L
                if (rem >= readd && rem > 0L) {
                    if (CircleRemovals.mergeRemovedAt(key, rem) && social != null) {
                        runCatching { social.removeFromCircle(cid, hex) }   // purge + engine tombstone
                    }
                } else if (readd > 0L) {
                    // Newest is a re-add: merge the client re-add ts. The engine tombstone is lifted ONLY by
                    // an explicit LOCAL re-add; the member's bundle comes back via the additive circle: record.
                    CircleRemovals.mergeReaddedAt(key, readd)
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

        // Whole-circle / DM deletions — LWW, applied BEFORE the circle: upsert. A deletion newer than any
        // re-creation deletes the circle locally too (so deleting a DM on one device deletes it on the
        // others); the circle: loop below then skips re-creating anything still tombstone-deleted.
        run {
            val deletedMs = HashMap<String, Long>()
            val recreatedMs = HashMap<String, Long>()
            for (e in live) if (e.value.size == 8) {
                when {
                    e.key.startsWith("circle-deleted:") -> {
                        val id = e.key.removePrefix("circle-deleted:")
                        if (id.isNotEmpty()) deletedMs[id] = int64LEValue(e.value)
                    }
                    e.key.startsWith("circle-recreated:") -> {
                        val id = e.key.removePrefix("circle-recreated:")
                        if (id.isNotEmpty()) recreatedMs[id] = int64LEValue(e.value)
                    }
                }
            }
            for (id in deletedMs.keys + recreatedMs.keys) {
                val del = deletedMs[id] ?: 0L
                val rec = recreatedMs[id] ?: 0L
                if (del >= rec && del > 0L) {
                    if (CircleDeletion.mergeDeletedAt(id, del) &&
                        social?.circles()?.any { it.id == id } == true) {
                        runCatching { social.leaveCircle(id) }
                    }
                } else if (rec > 0L) {
                    CircleDeletion.mergeRecreatedAt(id, rec)
                }
            }
        }

        // Circles: reconcile each synced circle — create it + register every member's bundle so this
        // device can seal to them, and record its relay mailbox(es). ADDITIVE in v1 (no absence-based
        // leave/prune — see the strictly-additive note below).
        if (social != null) {
            val existing = runCatching { social.circles() }.getOrDefault(emptyList())
            for (e in live) if (e.key.startsWith("circle:")) {
                val id = e.key.removePrefix("circle:")
                // Don't RESURRECT a circle/DM the user deleted (LWW): a sibling still listing it must not
                // re-create it every sync. A newer re-creation (merged above) lifts this.
                if (CircleDeletion.isDeleted(id)) continue
                val cs = decodeCircleSync(e.value) ?: continue
                runCatching { social.createCircle(id, cs.name) }   // no-op if it already exists
                val cur = existing.firstOrNull { it.id == id }
                if (cur != null && cur.name != cs.name) runCatching { social.renameCircle(id, cs.name) }
                // Pin the authority-root creator carried on the authenticated circle definition (§2) — a
                // sibling that created this circle stamped it, so this device learns the same root.
                cs.creator?.let { runCatching { social.setCircleCreator(id, toHex(it)) } }

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
        val accountHex = HavenNet.accountNodeHex
        if (accountHex.isEmpty()) return false
        // Seedless devices hold no account seed — they seal/open account state with the granted 32-byte
        // self-sync key (seal/openAccountStateWithKey) instead of deriving it from the seed. Slot keys
        // still key on the shared accountHex, so both device kinds converge on the same mailbox.
        val seedless = HavenNet.isSeedless
        val selfSyncKey = if (seedless) (HavenNet.selfSyncKey ?: return false) else null
        val seed = if (seedless) ByteArray(0) else HavenNet.accountSeed

        // Transports = every relay (existing) + the user's own S3 bucket if configured. Self-sync
        // now works with a relay OR an S3 bucket (no relay required) — matching iOS/desktop.
        val transports = ArrayList<Transport>()
        for (nodeHex in HavenNet.selfSyncRelays()) transports.add(RelayTransport(nodeHex))
        StorageStore.s3Config(appContext)?.let { transports.add(S3Transport(it)) }
        if (transports.isEmpty()) return false   // nothing to sync over

        // 1.0.7 self-sync key rotation (docs/SWITCH-FLIP-1.0.7.md §6). Before choosing the seal/open path,
        // a non-minting device adopts the current rotated key from any grant addressed to it (published by
        // the primary on the last revocation). Once the gate is met AND we hold a rotated key, the channel
        // runs the v1 (epoch-keyed) path with an EMPTY seed key — v0 authority is retired (§6 "empty vec
        // once v0 authority is retired"). Until a revocation mints a key, this stays v0 (byte-identical).
        // Grants ride the SAME per-device self-sync mailbox as state, at the canonical slot
        // `self/<account>/keygrant/<device>` (core `selfSyncGrantSlotKey`) — identical across iOS/desktop/
        // Android so a rotated key crosses platforms. List the whole keygrant prefix, then open only the
        // grant addressed to THIS device (a grant sealed to another device fails to open and is skipped).
        val grantPrefix = "haven/" + selfSyncGrantSlotPrefix(accountHex)
        run {
            val deviceSeed = DeviceKeyStore.deviceAccount().secretSeed()
            val accountBundle = HavenNet.accountBundle
            val envelopes = ArrayList<ByteArray>()
            for (t in transports) {
                val keys = t.list(grantPrefix) ?: continue
                for (key in keys) { t.get(key)?.let { envelopes.add(it) } }
            }
            if (envelopes.isNotEmpty()) SelfSyncKeyStore.adopt(deviceSeed, accountBundle, envelopes)
        }
        val rotation = SelfSyncKeyStore.rotationEngaged(social)
        val rotKey = SelfSyncKeyStore.currentKey()
        val rotEpoch = SelfSyncKeyStore.currentEpoch()

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
        // A freshly-enrolled seedless device NEVER tombstones until the primary's slot has merged in
        // (absence-as-deletion guard, plan §7) — even if a stray local circle appears, its empty roster
        // must not sever the account. The flag clears below once a merge actually brings peer state in.
        val enrollBaseline = awaitingEnrollBaseline()
        val localHasCircle = local.keys.any { it.startsWith("circle:") }
        val baseHasCircle = base.entries().any { it.key.startsWith("circle:") }
        if (!enrollBaseline && (localHasCircle || !baseHasCircle)) {
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
                val peer = runCatching {
                    when {
                        // v1 rotatable path: honor only the current epoch's key; a stale-epoch (revoked
                        // device's) write is refused. Empty seed key ⇒ legacy v0 blobs are refused too.
                        rotation && rotKey != null -> openAccountStateDual(blob, rotEpoch, rotKey, ByteArray(0))
                        seedless -> openAccountStateWithKey(selfSyncKey!!, blob)
                        else -> openAccountState(seed, blob)
                    }
                }.getOrNull() ?: continue
                base.merge(peer)
            }
        }

        val changed = !base.toBytes().contentEquals(preMerge)
        // The primary's slot has now been folded into the base — it's safe to leave additive-only mode
        // (subsequent local removals may propagate as tombstones like any seeded device).
        if (enrollBaseline && changed) clearEnrollBaseline()

        // 4. Apply the converged state locally + persist the new base.
        applyLocal(base, social)
        runCatching { baseFile.writeBytes(base.toBytes()) }
            .onFailure { Log.e(TAG, "persist base failed", it) }
        if (changed) HavenNet.selfSyncDidApply()

        // 5. Re-publish our own slot (sealed) to every transport for redundancy.
        val sealed = runCatching {
            when {
                rotation && rotKey != null -> sealAccountStateWithKeyEpoch(rotKey, rotEpoch, base)
                seedless -> sealAccountStateWithKey(selfSyncKey!!, base)
                else -> sealAccountState(seed, base)
            }
        }.getOrNull() ?: return changed
        for (t in transports) t.put(ownKey, sealed)

        // 6. Publish any freshly-minted rotation grants (primary side, §6) so every still-authorized device
        // learns the new key. Each grant goes to its recipient's canonical slot `self/<account>/keygrant/
        // <device>` (core `selfSyncGrantSlotKey`) — the same per-device transport iOS/desktop use. Cleared
        // once every grant is accepted by at least one transport (idempotent to re-publish).
        val pending = SelfSyncKeyStore.pendingGrants()
        if (pending.isNotEmpty()) {
            var allOk = true
            for ((devHex, blob) in pending) {
                val slot = "haven/" + selfSyncGrantSlotKey(accountHex, devHex)
                var ok = false
                for (t in transports) if (t.put(slot, blob)) ok = true
                if (!ok) allOk = false
            }
            if (allOk) SelfSyncKeyStore.clearPendingGrants()
        }
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
