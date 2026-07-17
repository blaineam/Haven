package com.blaineam.haven.core

import android.content.Context
import uniffi.haven_ffi.HavenSocial
import uniffi.haven_ffi.mintSelfSyncKey
import uniffi.haven_ffi.openSelfSyncKeyEpochGrant
import uniffi.haven_ffi.sealSelfSyncKeyEpochGrant
import uniffi.haven_ffi.selfSyncKeyShouldRotate

/**
 * 1.0.7 self-sync key rotation — docs/SWITCH-FLIP-1.0.7.md §6, the Android counterpart of the concurrent
 * Apple wiring. The account-state self-sync channel (`self/<account>/state/<device>`) must rotate its key
 * on **every device revocation**, or a revoked device keeps reading + LWW-writing our account state
 * forever. This store holds the current rotated `(epoch, key)` this device honors and, on the primary, the
 * freshly-sealed per-device grants queued for publication to the transport ([SelfSyncCoordinator]).
 *
 * Gated EXACTLY like account-key retirement (§6 "the gate mirrors retirement exactly"): the FFI
 * [selfSyncKeyShouldRotate] returns true only when the retire switch is ON **and** the fleet is fully
 * seed-drop-capable — approximated client-side by `account_leaf_retired` (the roster-level signal that no
 * own device still depends on the seed-derived key). Until then every byte on the self-sync wire stays v0
 * (seed-derived `sealAccountState`/`openAccountState`) and is byte-identical to 1.0.6. A rotated key only
 * ever comes into existence when a revocation mints one, so the v1 path never engages prematurely.
 *
 * The seed key passed to `openAccountStateDual` is ALWAYS empty on the v1 path here: the gate requires the
 * account leaf to already be retired, i.e. we are past the transition window and v0 authority is dropped.
 */
object SelfSyncKeyStore {
    private const val PREFS = "haven.selfsynckey"
    private const val KEY_EPOCH = "epoch"
    private const val KEY_KEY = "key"
    private const val KEY_PENDING = "pendingGrants"

    private lateinit var appContext: Context
    @Volatile var initialized = false; private set

    /** Session mirror of the fleet's rotation intent (NON-persisted; re-applied on launch like the
     *  set_seed_drop_retire engine switch). Set true on every device — the reader side of rotation is not
     *  a primary-only op, and the core gate still holds everything inert until the fleet is capable. */
    @Volatile var retireSwitchOn = false

    fun init(ctx: Context) {
        if (initialized) return
        appContext = ctx.applicationContext
        initialized = true
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun currentEpoch(): ULong = if (initialized) prefs.getLong(KEY_EPOCH, 0L).toULong() else 0u

    fun currentKey(): ByteArray? = if (!initialized) null else
        prefs.getString(KEY_KEY, null)
            ?.let { runCatching { android.util.Base64.decode(it, android.util.Base64.NO_WRAP) }.getOrNull() }
            ?.takeIf { it.size == 32 }

    /** The rotation gate — retire switch ON **and** the account leaf retired (fleet fully capable). */
    private fun gate(social: HavenSocial?): Boolean {
        val retired = runCatching { social?.accountLeafRetired() ?: false }.getOrDefault(false)
        return selfSyncKeyShouldRotate(retireSwitchOn, retired)
    }

    /** True when the reader/sealer should run the v1 (epoch-keyed) path: the gate is met AND a rotated key
     *  actually exists (minted by the primary on a revocation, or adopted from a grant). Until a revocation
     *  mints a key this stays false → the v0 seed-derived channel, byte-identical to 1.0.6. */
    fun rotationEngaged(social: HavenSocial?): Boolean = currentKey() != null && gate(social)

    /**
     * PRIMARY, on a device revocation: mint a fresh 32-byte key, bump the epoch, seal an epoch grant to
     * every STILL-authorized device bundle, and persist the new `(epoch, key)` + the grants to publish.
     * The just-revoked device is simply not a grant recipient — it keeps only the stale key. Gated — a
     * no-op (false) until the fleet is fully capable, so a mixed/legacy fleet keeps the v0 channel.
     *
     * Grants are queued keyed by the recipient's device hex so each lands in its own canonical mailbox
     * slot (`self/<account>/keygrant/<device>`) on publication — the same per-device transport as state.
     */
    fun rotateForRevocation(social: HavenSocial?, accountSeed: ByteArray, survivorBundles: List<ByteArray>): Boolean {
        if (!initialized || !gate(social)) return false
        val newKey = runCatching { mintSelfSyncKey() }.getOrNull()?.takeIf { it.size == 32 } ?: return false
        val newEpoch = currentEpoch() + 1u
        val grants = LinkedHashMap<String, ByteArray>()
        for (b in survivorBundles) {
            val devHex = nodeHex(b)
            if (devHex.length != 64) continue
            runCatching { sealSelfSyncKeyEpochGrant(accountSeed, b, newEpoch, newKey) }.getOrNull()?.let { grants[devHex] = it }
        }
        save(newEpoch, newKey)
        savePending(grants)
        return true
    }

    /**
     * READER (any non-minting device): adopt the highest-epoch grant addressed to THIS device from the
     * published set, learning the current rotated key. A grant sealed to another device (or forged) fails
     * to open and is ignored. Returns true if a newer key was adopted.
     */
    fun adopt(deviceSeed: ByteArray, accountBundle: ByteArray, envelopes: List<ByteArray>): Boolean {
        if (!initialized || envelopes.isEmpty()) return false
        var bestEpoch = currentEpoch()
        var bestKey: ByteArray? = null
        for (e in envelopes) {
            val g = runCatching { openSelfSyncKeyEpochGrant(deviceSeed, accountBundle, e) }.getOrNull() ?: continue
            if (g.key.size == 32 && g.epoch > bestEpoch) { bestEpoch = g.epoch; bestKey = g.key }
        }
        val k = bestKey ?: return false
        save(bestEpoch, k)
        return true
    }

    /** The sealed grants the primary still needs to publish, keyed by recipient device hex (empty once
     *  published + cleared). Each is written to its own `self/<account>/keygrant/<device>` slot. */
    fun pendingGrants(): Map<String, ByteArray> {
        if (!initialized) return emptyMap()
        val s = prefs.getString(KEY_PENDING, null) ?: return emptyMap()
        return runCatching {
            val obj = org.json.JSONObject(s)
            val out = LinkedHashMap<String, ByteArray>()
            for (k in obj.keys()) out[k] = android.util.Base64.decode(obj.getString(k), android.util.Base64.NO_WRAP)
            out
        }.getOrDefault(emptyMap())
    }

    fun clearPendingGrants() { if (initialized) prefs.edit().remove(KEY_PENDING).apply() }

    private fun save(epoch: ULong, key: ByteArray) {
        prefs.edit()
            .putLong(KEY_EPOCH, epoch.toLong())
            .putString(KEY_KEY, android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP))
            .apply()
    }

    private fun savePending(grants: Map<String, ByteArray>) {
        val obj = org.json.JSONObject()
        for ((devHex, g) in grants) obj.put(devHex, android.util.Base64.encodeToString(g, android.util.Base64.NO_WRAP))
        prefs.edit().putString(KEY_PENDING, obj.toString()).apply()
    }

    /** Wipe on factory reset / identity change (parity with SelfSyncCoordinator.reset). */
    fun clear() { if (initialized) runCatching { prefs.edit().clear().apply() } }
}
