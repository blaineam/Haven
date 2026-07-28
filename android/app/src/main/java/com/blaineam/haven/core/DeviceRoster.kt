package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.Account
import uniffi.haven_ffi.issueDeviceCredential
import uniffi.haven_ffi.signDeviceList
import uniffi.haven_ffi.HavenSocial

/**
 * Multi-device parity with iOS [DeviceRoster.swift]. The signed-credential crypto lives in the SHARED
 * Rust core (uniffi `issueDeviceCredential`/`signDeviceList`, `social.setMyDeviceRoster`), so this is the
 * Kotlin manager + key store over it — the credential/list bytes are identical across iOS/Android/desktop.
 *
 * A linked device acts under its OWN device key plus an account-signed credential, so the primary can
 * authorize it and **revoke it individually** without rotating the master seed.
 */

/** This device's OWN keypair — distinct from the account master seed, never synced, never leaves it. */
object DeviceKeyStore {
    private const val PREFS = "haven.deviceKey"
    private const val KEY_SEED = "deviceSeed"
    private lateinit var appContext: Context

    fun init(ctx: Context) { appContext = ctx.applicationContext }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** This device's stable device Account — created once (device-local, never synced). */
    fun deviceAccount(): Account {
        val stored = prefs.getString(KEY_SEED, null)
        if (stored != null) {
            val seed = android.util.Base64.decode(stored, android.util.Base64.NO_WRAP)
            runCatching { return Account.fromSeed(seed) }
        }
        val fresh = Account.generate()
        prefs.edit().putString(KEY_SEED, android.util.Base64.encodeToString(fresh.secretSeed(), android.util.Base64.NO_WRAP)).apply()
        return fresh
    }

    fun deviceNodeHex(): String = deviceAccount().nodeIdHex()
    fun deviceBundle(): ByteArray = deviceAccount().publicBundle()
    /** A friendly label for this device (shown in "Authorized devices"). */
    val deviceName: String get() = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim()

    fun clear() { runCatching { prefs.edit().clear().commit() } }
}

/** This device's account-signed credential (proof it's authorized), stored once enrollment grants it. */
object DeviceCredentialStore {
    private const val PREFS = "haven.deviceCred"
    private const val KEY = "credential"
    private lateinit var appContext: Context

    fun init(ctx: Context) { appContext = ctx.applicationContext }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    val authorized = mutableStateOf(false)

    fun load(): ByteArray? = prefs.getString(KEY, null)?.let { android.util.Base64.decode(it, android.util.Base64.NO_WRAP) }
    fun save(cred: ByteArray) {
        prefs.edit().putString(KEY, android.util.Base64.encodeToString(cred, android.util.Base64.NO_WRAP)).apply()
        authorized.value = true
    }
    fun isAuthorized(): Boolean = prefs.contains(KEY)
    fun clear() { prefs.edit().remove(KEY).commit(); authorized.value = false }
    fun refresh() { authorized.value = isAuthorized() }
}

/** One device in the account's roster (for the Authorized-Devices UI). */
data class RosterDevice(
    val nodeHex: String,
    val name: String,
    val isThisDevice: Boolean,
    val isPrimary: Boolean,
)

/**
 * Maintains the account's signed device roster on the **primary** (the master-seed holder). The roster =
 * the account key as "device #0" plus each linked device's own key. Issuing/revoking re-signs a versioned
 * DeviceList + per-device credentials and pushes them to the engine (`setMyDeviceRoster`).
 */
object DeviceRosterManager {
    private const val PREFS = "haven.deviceRoster"
    private const val KEY = "rosterV2"
    private lateinit var appContext: Context

    private data class Entry(val bundle: ByteArray, val name: String, val isPrimary: Boolean)
    private val entries = HashMap<String, Entry>()
    private val revoked = HashSet<String>()
    private var version: ULong = 0u
    private var primaryHex = ""

    /** Observable for the UI. */
    val devices = mutableStateListOf<RosterDevice>()

    fun init(ctx: Context) { appContext = ctx.applicationContext; load(); rebuild() }
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isEnabled(): Boolean = version > 0u

    /** Turn multi-device on: register the account key as the primary "device #0". Idempotent. */
    fun enable(social: HavenSocial?, accountSeed: ByteArray, accountBundle: ByteArray, accountHex: String): Boolean {
        primaryHex = accountHex
        if (entries[accountHex] == null) {
            entries[accountHex] = Entry(accountBundle, "Primary (this account's master key)", true)
        }
        return resign(social, accountSeed)
    }

    /** Authorize a newly-linked device. Returns that device's credential (to hand back), or null. */
    fun addLinkedDevice(bundle: ByteArray, nodeHex: String, name: String, social: HavenSocial?, accountSeed: ByteArray): ByteArray? {
        revoked.remove(nodeHex)
        entries[nodeHex] = Entry(bundle, name, false)
        if (!resign(social, accountSeed)) return null
        val now = System.currentTimeMillis() / 1000
        return runCatching { issueDeviceCredential(accountSeed, bundle, name, now.toULong()) }.getOrNull()
    }

    /** Revoke a device: drop it, bump the version, re-sign — it can decrypt nothing posted afterward. */
    fun revoke(nodeHex: String, social: HavenSocial?, accountSeed: ByteArray): Boolean {
        if (nodeHex == primaryHex) return false   // never revoke the master key
        entries.remove(nodeHex)
        revoked.add(nodeHex)
        val ok = resign(social, accountSeed)
        // 1.0.7 self-sync key rotation (docs/SWITCH-FLIP-1.0.7.md §6): the roster version just bumped and a
        // device was dropped — rotate the account-state self-sync key so the just-revoked device can no
        // longer open our state or LWW-write a stale copy. Grants are sealed to the STILL-authorized device
        // bundles only; the revoked device is simply not a recipient. Gated inside exactly like account-key
        // retirement — a no-op until the fleet is fully seed-drop-capable (v0 channel stays byte-identical).
        if (ok) runCatching { SelfSyncKeyStore.rotateForRevocation(social, accountSeed, activeLinkedBundles()) }
        return ok
    }

    /** Every currently-authorized LINKED device's public bundle (excludes the primary account key, which
     *  minted the key, and any revoked device). The grant recipients for a self-sync key rotation (§6). */
    fun activeLinkedBundles(): List<ByteArray> =
        entries.filter { (hex, e) -> !e.isPrimary && !revoked.contains(hex) }.map { it.value.bundle }

    /** Step DOWN as primary: forget this device's roster entirely (both devices share the seed, so the
     *  WRONG one can claim primary and get stuck). Reversible — re-link to the real primary afterward. */
    fun stepDown() {
        version = 0u; primaryHex = ""; entries.clear(); revoked.clear()
        DeviceCredentialStore.clear()
        rebuild(); save()
    }

    /** Re-issue every active device's credential + a fresh signed DeviceList and push to the engine. */
    private fun resign(social: HavenSocial?, accountSeed: ByteArray): Boolean {
        version += 1u
        val now = (System.currentTimeMillis() / 1000).toULong()
        val creds = ArrayList<ByteArray>()
        val activeIds = ArrayList<ByteArray>()
        for ((hex, e) in entries) {
            if (revoked.contains(hex)) continue
            val id = hexToBytes(hex) ?: continue
            activeIds.add(id)
            runCatching { issueDeviceCredential(accountSeed, e.bundle, e.name, now) }.getOrNull()?.let { creds.add(it) }
        }
        val revokedIds = revoked.mapNotNull { hexToBytes(it) }
        val list = runCatching { signDeviceList(accountSeed, version, now, activeIds, revokedIds) }.getOrNull() ?: return false
        val ok = runCatching { social?.setMyDeviceRoster(list, creds) ?: false }.getOrDefault(false)
        rebuild(); save()
        return ok
    }

    private fun rebuild() {
        val me = runCatching { DeviceKeyStore.deviceNodeHex() }.getOrDefault("")
        val accountHex = runCatching { HavenNet.nodeIdHex }.getOrDefault("")
        devices.clear()
        devices.addAll(
            entries.map { (hex, e) ->
                RosterDevice(hex, e.name, isThisDevice = hex == me || (e.isPrimary && accountHex == hex), isPrimary = e.isPrimary)
            }.sortedWith(compareBy({ if (it.isPrimary) 0 else 1 }, { it.name })),
        )
    }

    private fun hexToBytes(hex: String): ByteArray? {
        if (hex.length != 64) return null
        return runCatching { ByteArray(32) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() } }.getOrNull()
    }

    // MARK: persistence (JSON)
    private fun save() {
        val root = JSONObject()
        root.put("version", version.toLong())
        root.put("primaryHex", primaryHex)
        val es = JSONObject()
        for ((hex, e) in entries) {
            es.put(hex, JSONObject().apply {
                put("bundle", android.util.Base64.encodeToString(e.bundle, android.util.Base64.NO_WRAP))
                put("name", e.name)
                put("isPrimary", e.isPrimary)
            })
        }
        root.put("entries", es)
        root.put("revoked", JSONArray(revoked.toList()))
        prefs.edit().putString(KEY, root.toString()).apply()
    }

    private fun load() {
        val s = prefs.getString(KEY, null) ?: return
        runCatching {
            val root = JSONObject(s)
            version = root.optLong("version", 0).toULong()
            primaryHex = root.optString("primaryHex", "")
            revoked.clear()
            val rv = root.optJSONArray("revoked") ?: JSONArray()
            for (i in 0 until rv.length()) revoked.add(rv.getString(i))
            entries.clear()
            val es = root.optJSONObject("entries") ?: JSONObject()
            for (hex in es.keys()) {
                val e = es.getJSONObject(hex)
                entries[hex] = Entry(
                    android.util.Base64.decode(e.getString("bundle"), android.util.Base64.NO_WRAP),
                    e.optString("name", "Device"), e.optBoolean("isPrimary", false),
                )
            }
        }
    }

    fun clear() { runCatching { prefs.edit().clear().commit() }; version = 0u; primaryHex = ""; entries.clear(); revoked.clear(); rebuild() }
}
