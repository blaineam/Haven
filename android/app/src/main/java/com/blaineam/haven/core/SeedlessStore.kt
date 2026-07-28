package com.blaineam.haven.core

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import uniffi.haven_ffi.EnrollGrantFfi

/**
 * Persistence for a **seedless** device (seed-drop S4, `docs/SEEDLESS-ENROLLMENT-PLAN.md` §5, Android
 * column). A device enrolled via the `haven-enroll:` flow never receives the account master seed; it
 * operates under its OWN device key plus everything the primary granted it:
 *
 *   - the account **public** bundle (+ its node/verify hex, so the app knows the account handle without
 *     a seed),
 *   - the granted 32-byte **self-sync key** (seed-grade secret — decrypts all account state),
 *   - this device's account-signed **credential**,
 *   - the primary-signed device **roster wire** VERBATIM (incl. the SeedDropCapability trailer, so it
 *     rebroadcasts without re-encoding — A3), and
 *   - the bootstrap relays.
 *
 * All of it lives in [EncryptedSharedPreferences] (parity with iOS's keychain/SE stores). The
 * locked-read discipline from [HavenCore] applies verbatim: a *failed* read must NEVER be mistaken for
 * an *absent* value, or we'd clobber a real seedless identity with a throwaway one. Only [install] ever
 * writes, and only an explicit [clear] (Start over) ever erases — never a read path.
 */
object SeedlessStore {
    private const val PREFS = "haven.seedless"
    private const val KEY_BUNDLE = "account_bundle_b64"
    private const val KEY_NODE_HEX = "account_node_hex"
    private const val KEY_VERIFY_HEX = "account_verify_hex"
    private const val KEY_SELF_SYNC = "self_sync_key_b64"
    private const val KEY_CREDENTIAL = "credential_b64"
    private const val KEY_ROSTER = "roster_wire_b64"
    private const val KEY_RELAYS = "relays_json"

    private lateinit var prefs: SharedPreferences

    fun init(appContext: Context) {
        if (::prefs.isInitialized) return
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            appContext,
            PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** True once an enrollment grant has been installed — the app boots into seedless mode. A read
     *  failure is treated as "not seedless" only because EncryptedSharedPreferences has no pre-unlock
     *  window (see HavenCore); it is never used to DELETE a stored identity. */
    fun isSeedless(): Boolean =
        ::prefs.isInitialized && runCatching { prefs.contains(KEY_BUNDLE) }.getOrDefault(false)

    private fun bytes(key: String): ByteArray? =
        runCatching { prefs.getString(key, null)?.let { Base64.decode(it, Base64.NO_WRAP) } }.getOrNull()

    /** The account PUBLIC bundle (the seedless engine's `me_pub`). */
    fun accountBundle(): ByteArray? = bytes(KEY_BUNDLE)
    fun accountNodeHex(): String = runCatching { prefs.getString(KEY_NODE_HEX, null) }.getOrNull() ?: ""
    fun accountVerifyHex(): String = runCatching { prefs.getString(KEY_VERIFY_HEX, null) }.getOrNull() ?: ""

    /** The granted 32-byte self-sync key — seed-grade; used with seal/openAccountStateWithKey. */
    fun selfSyncKey(): ByteArray? = bytes(KEY_SELF_SYNC)?.takeIf { it.size == 32 }

    /** This device's account-signed credential. */
    fun credential(): ByteArray? = bytes(KEY_CREDENTIAL)

    /** The primary-signed roster wire VERBATIM (incl. capability trailer). */
    fun rosterWire(): ByteArray? = bytes(KEY_ROSTER)

    fun relays(): List<String> = runCatching {
        val raw = prefs.getString(KEY_RELAYS, null) ?: return emptyList()
        val a = JSONArray(raw)
        (0 until a.length()).map { a.getString(it) }
    }.getOrDefault(emptyList())

    /**
     * Persist an accepted enrollment grant. The SOLE writer. Called only after
     * [uniffi.haven_ffi.enrollOpenGrant] has passed all four acceptance checks (never partially), so a
     * failed/partial handshake leaves the previous state (usually absent) untouched — the device stays
     * in linking mode, re-scannable, never a half-identity.
     *
     * @param accountNodeHex hex of the account node id (from the ticket / bundle) — the account handle.
     * @param accountVerifyHex hex of the account bundle verification (16 bytes).
     */
    fun install(grant: EnrollGrantFfi, accountNodeHex: String, accountVerifyHex: String) {
        prefs.edit()
            .putString(KEY_BUNDLE, Base64.encodeToString(grant.accountBundle, Base64.NO_WRAP))
            .putString(KEY_NODE_HEX, accountNodeHex.lowercase())
            .putString(KEY_VERIFY_HEX, accountVerifyHex.lowercase())
            .putString(KEY_SELF_SYNC, Base64.encodeToString(grant.selfSyncKey, Base64.NO_WRAP))
            .putString(KEY_CREDENTIAL, Base64.encodeToString(grant.credential, Base64.NO_WRAP))
            .putString(KEY_ROSTER, Base64.encodeToString(grant.rosterWire, Base64.NO_WRAP))
            .putString(KEY_RELAYS, JSONArray(grant.relays).toString())
            .apply()
    }

    /** Wipe seedless state (Start over / adopting a different identity). Explicit writer only. */
    fun clear() { if (::prefs.isInitialized) runCatching { prefs.edit().clear().commit() } }
}
