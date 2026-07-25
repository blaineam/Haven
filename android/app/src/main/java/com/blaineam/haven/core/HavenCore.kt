package com.blaineam.haven.core

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import uniffi.haven_ffi.Account
import uniffi.haven_ffi.SelfTestReport
import uniffi.haven_ffi.selfTest

/**
 * The Android counterpart of the iOS AccountStore: owns the on-device identity (a 32-byte
 * master seed), persists it encrypted-at-rest in the Android Keystore, and hands out the
 * Rust [Account] object from the shared `haven_ffi` core.
 *
 * Mirrors the iOS keychain rule from memory: a *locked* read must never be confused with an
 * *absent* key, or we'd overwrite a real identity with a throwaway one. EncryptedSharedPreferences
 * does not have the pre-unlock window the iOS Keychain does, but we keep the same "only generate
 * when truly absent" contract.
 */
class HavenCore private constructor(
    private val prefs: SharedPreferences,
) {
    /** True on a SEEDLESS device — enrolled via `haven-enroll:`, holding the account PUBLIC bundle +
     *  a granted self-sync key but NO account master seed (seed-drop S4). Fixed for this process; a
     *  mode flip (enroll / Start over) restarts the app. */
    val seedless: Boolean = SeedlessStore.isSeedless()

    /** The live account identity. `null` on a seedless device (no master seed exists there). Loaded
     *  from disk if present, otherwise freshly generated + saved (seeded devices only). */
    val account: Account? = loadOrCreate()

    /** The account master seed. Only valid on a SEEDED device — every caller branches on [seedless]
     *  first, so this never runs on a seedless device (it would have no seed to return). */
    val seed: ByteArray get() = account?.secretSeed()
        ?: throw IllegalStateException("no account seed on a seedless device")
    /** The account PUBLIC bundle — from the live identity (seeded) or the stored grant (seedless). */
    val bundle: ByteArray get() = account?.publicBundle() ?: SeedlessStore.accountBundle()
        ?: throw IllegalStateException("no account bundle")
    /** The account node id hex (the user-facing contact handle) — works in both modes. */
    val nodeIdHex: String get() = account?.nodeIdHex() ?: SeedlessStore.accountNodeHex()
    /** The account bundle verification hex (16-byte tamper hash) — works in both modes. */
    val verificationHex: String get() = account?.verificationHex() ?: SeedlessStore.accountVerifyHex()

    /** A shareable invite link — the https website form pointing at the static site (parity with iOS),
     *  so opening it in a browser lands on wemiller.com/apps/haven, which resolves /#<id>.<verify> into
     *  an "open in Haven" page. The id + verify ride in the URL fragment and never reach a server. On a
     *  seedless device (no [account]) the link is rebuilt from the account bundle bytes (same base32
     *  <id>.<verify> payload) so sharing your handle still works. */
    fun inviteUri(): String =
        account?.havenLink("wemiller.com/apps/haven/open") ?: seedlessWebLink()

    /** Rebuild the `https://…/#<base32 id>.<base32 verify>` link for a seedless device from the stored
     *  account bundle, matching core `HavenLink::to_web` (base32-nopad of the raw id + verification). */
    private fun seedlessWebLink(): String {
        val id = runCatching { seedlessIdBytes() }.getOrNull()
        val verify = runCatching { seedlessVerifyBytes() }.getOrNull()
        if (id == null || verify == null) return "https://wemiller.com/apps/haven"
        return "https://wemiller.com/apps/haven/open/#${base32NoPad(id)}.${base32NoPad(verify)}"
    }
    private fun seedlessIdBytes(): ByteArray = hexToBytes(SeedlessStore.accountNodeHex())
    private fun seedlessVerifyBytes(): ByteArray = hexToBytes(SeedlessStore.accountVerifyHex())

    /** Run the on-device privacy self-test (identity / seal-open / signing / link parsing). */
    fun runSelfTest(): SelfTestReport = selfTest()

    /** Wipe the identity and start over (parity with iOS "Start over"). Clears BOTH the seeded master
     *  seed and any seedless grant, so the next launch onboards fresh. */
    fun reset() {
        prefs.edit().remove(KEY_SEED).apply()
        SeedlessStore.clear()
    }

    /** A QR/transfer payload carrying this identity's master seed (to adopt on another device). Only a
     *  SEEDED (primary/legacy) device can export a seed — a seedless device never holds one. */
    fun exportSeedUri(): String = "haven-seed:" + Base64.encodeToString(seed, Base64.NO_WRAP)

    /** Adopt a seed scanned from another device. Returns true if it was a valid 32-byte seed. */
    fun importSeed(uri: String): Boolean {
        val b64 = uri.trim().removePrefix("haven-seed:")
        val s = runCatching { Base64.decode(b64, Base64.NO_WRAP) }.getOrNull() ?: return false
        if (s.size != 32) return false
        prefs.edit().putString(KEY_SEED, Base64.encodeToString(s, Base64.NO_WRAP)).apply()
        // Adopting a DIFFERENT identity: clear the self-sync base so this device doesn't diff its (about
        // to be reloaded) empty engine against the old identity's base and tombstone the new account.
        runCatching { SelfSyncCoordinator.reset() }
        return true
    }

    private fun loadOrCreate(): Account? {
        // A seedless device holds NO master seed — its identity is the granted public bundle. Never
        // generate a seed here, or we'd manufacture a throwaway account over a real seedless one.
        if (seedless) return null
        val stored = prefs.getString(KEY_SEED, null)
        if (stored != null) {
            val seed = Base64.decode(stored, Base64.NO_WRAP)
            return Account.fromSeed(seed)
        }
        val acct = Account.generate()
        prefs.edit()
            .putString(KEY_SEED, Base64.encodeToString(acct.secretSeed(), Base64.NO_WRAP))
            .apply()
        return acct
    }

    companion object {
        private const val PREFS_NAME = "haven.identity"
        private const val KEY_SEED = "master_seed_b64"

        @Volatile private var instance: HavenCore? = null

        fun get(context: Context): HavenCore =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        /**
         * DEBUG/QA only: write a master seed straight to the identity prefs BEFORE the singleton is
         * built, so the first [get] adopts it via [loadOrCreate] instead of minting a throwaway.
         * `importSeed` on an already-built instance only rewrites prefs — the live `account` field
         * keeps the minted identity until a restart that the QA boot flow never does. No-op if the
         * singleton is already live or an identity already exists. Returns true when the seed landed.
         */
        fun qaPreseed(context: Context, seedB64: String): Boolean {
            if (instance != null) return false
            // MUST go through [identityPrefs]. This used to open PREFS_NAME as a PLAIN
            // SharedPreferences while every reader opens it as EncryptedSharedPreferences — and
            // encrypted prefs encrypt the KEY NAMES too, so the plaintext "master_seed_b64" was
            // invisible to loadOrCreate(). It minted a throwaway account, wrote that back encrypted,
            // and logged "joining the fleet account" anyway. Every Android E2E leg therefore ran under
            // a stray account that shared nothing with the fleet, so the whole Android column of the
            // suite was scoring propagation failures that could never have succeeded. (It also wrote
            // an account master seed to disk in cleartext.)
            val p = runCatching { identityPrefs(context.applicationContext) }.getOrNull() ?: return false
            if (!p.getString(KEY_SEED, null).isNullOrEmpty()) return false
            val s = runCatching { Base64.decode(seedB64.trim(), Base64.NO_WRAP) }.getOrNull() ?: return false
            if (s.size != 32) return false
            return p.edit().putString(KEY_SEED, Base64.encodeToString(s, Base64.NO_WRAP)).commit()
        }

        /**
         * Adopt an accepted enrollment grant and become a seedless device. Persists the grant via
         * [SeedlessStore], discards the throwaway account master seed generated at first run (so the
         * next launch boots seedless), and resets the self-sync base — the absence-as-deletion guard,
         * so a freshly-enrolled empty device never diffs against a stale base and tombstones the
         * account. The caller restarts the app afterward (mode is fixed per process).
         */
        fun installSeedless(
            context: Context,
            grant: uniffi.haven_ffi.EnrollGrantFfi,
            accountNodeHex: String,
            accountVerifyHex: String,
        ) {
            val appContext = context.applicationContext
            SeedlessStore.init(appContext)
            SeedlessStore.install(grant, accountNodeHex, accountVerifyHex)
            // Discard the random account seed created on first run — this device is now seedless.
            get(appContext).prefs.edit().remove(KEY_SEED).apply()
            // Clear the self-sync base + arm the additive-only guard so the first pass ADDS the primary's
            // pushed slot rather than diffing an empty engine and tombstoning (mirrors importSeed's base
            // reset, extended for seedless).
            runCatching { SelfSyncCoordinator.init(appContext) }
            runCatching { SelfSyncCoordinator.beginSeedlessEnrollment() }
        }

        private fun build(appContext: Context): HavenCore = HavenCore(identityPrefs(appContext))

        /** The identity store. EVERY reader and writer must go through this — see [qaPreseed]. */
        private fun identityPrefs(appContext: Context): SharedPreferences {
            SeedlessStore.init(appContext)
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            return EncryptedSharedPreferences.create(
                appContext,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }
    }
}

// ---- base32 / hex helpers (link rebuild for seedless devices) --------------------------------

private const val BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

/** RFC4648 base32 WITHOUT padding — byte-identical to core's `data_encoding::BASE32_NOPAD`. */
private fun base32NoPad(data: ByteArray): String {
    val sb = StringBuilder((data.size * 8 + 4) / 5)
    var buffer = 0
    var bits = 0
    for (b in data) {
        buffer = (buffer shl 8) or (b.toInt() and 0xFF)
        bits += 8
        while (bits >= 5) {
            bits -= 5
            sb.append(BASE32_ALPHABET[(buffer ushr bits) and 0x1F])
        }
    }
    if (bits > 0) sb.append(BASE32_ALPHABET[(buffer shl (5 - bits)) and 0x1F])
    return sb.toString()
}

private fun hexToBytes(hex: String): ByteArray {
    require(hex.length % 2 == 0) { "odd-length hex" }
    return ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
