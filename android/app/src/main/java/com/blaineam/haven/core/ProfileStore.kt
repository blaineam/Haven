package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONObject

/**
 * Lightweight observable profile + onboarding state, the Android counterpart of the iOS
 * ProfileStore. Backed by plain SharedPreferences (non-secret display data); the identity
 * itself lives in [HavenCore] / the Keystore.
 */
class ProfileStore private constructor(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("haven.profile", Context.MODE_PRIVATE)

    var onboarded by mutableStateOf(prefs.getBoolean(KEY_ONBOARDED, false))
        private set
    var displayName by mutableStateOf(prefs.getString(KEY_NAME, "") ?: "")
    var bio by mutableStateOf(prefs.getString(KEY_BIO, "") ?: "")
    var link by mutableStateOf(prefs.getString(KEY_LINK, "") ?: "")
    var emoji by mutableStateOf(prefs.getString(KEY_EMOJI, "🌅") ?: "🌅")
    /** Base64 of a small JPEG avatar (empty = none); rides the signed profile card to the circle. */
    var avatarB64 by mutableStateOf(prefs.getString(KEY_AVATAR, "") ?: "")

    /** Auto-expire posts older than this many days (0 = keep forever). Parity with iOS retention. */
    var retentionDays by mutableStateOf(prefs.getInt(KEY_RETENTION, 0))

    // Save-to-Photos + media optimization (iOS Settings parity). Observable + persisted on set.
    private val _saveMyPosts = mutableStateOf(prefs.getBoolean(KEY_SAVE_MINE, false))
    private val _saveOthersPosts = mutableStateOf(prefs.getBoolean(KEY_SAVE_OTHERS, false))
    private val _autoOptimize = mutableStateOf(prefs.getBoolean(KEY_OPTIMIZE, true))
    var saveMyPosts: Boolean
        get() = _saveMyPosts.value
        set(v) { _saveMyPosts.value = v; prefs.edit().putBoolean(KEY_SAVE_MINE, v).apply(); stampSetting(TS_SAVE) }
    var saveOthersPosts: Boolean
        get() = _saveOthersPosts.value
        set(v) { _saveOthersPosts.value = v; prefs.edit().putBoolean(KEY_SAVE_OTHERS, v).apply(); stampSetting(TS_SAVE_OTHERS) }
    var autoOptimize: Boolean
        get() = _autoOptimize.value
        set(v) { _autoOptimize.value = v; prefs.edit().putBoolean(KEY_OPTIMIZE, v).apply(); stampSetting(TS_OPT) }
    // Global "play video sound" toggle (iOS parity): videos start muted; tapping any video unmutes ALL.
    private val _videoSoundOn = mutableStateOf(prefs.getBoolean(KEY_VIDEO_SOUND, false))
    var videoSoundOn: Boolean
        get() = _videoSoundOn.value
        set(v) { _videoSoundOn.value = v; prefs.edit().putBoolean(KEY_VIDEO_SOUND, v).apply() }

    /** Super data saver — posters only, no autoplay (iOS SettingsStore.superDataSaver). Device-local. */
    private val _superDataSaver = mutableStateOf(prefs.getBoolean(KEY_DATA_SAVER, false))
    var superDataSaver: Boolean
        get() = _superDataSaver.value
        set(v) { _superDataSaver.value = v; prefs.edit().putBoolean(KEY_DATA_SAVER, v).apply() }

    /** Also keep camera original beside optimized video (iOS sendOriginal). Device-local. */
    private val _sendOriginal = mutableStateOf(prefs.getBoolean(KEY_SEND_ORIGINAL, false))
    var sendOriginal: Boolean
        get() = _sendOriginal.value
        set(v) { _sendOriginal.value = v; prefs.edit().putBoolean(KEY_SEND_ORIGINAL, v).apply() }

    /**
     * Notification preview detail: "full" | "private" | "minimal" (iOS SharedNotificationPrivacy).
     * Device-local; applied when posting local banners.
     */
    private val _notificationDetail = mutableStateOf(prefs.getString(KEY_NOTIF_DETAIL, "full") ?: "full")
    var notificationDetail: String
        get() = _notificationDetail.value
        set(v) {
            val n = when (v) { "private", "minimal" -> v; else -> "full" }
            _notificationDetail.value = n
            prefs.edit().putString(KEY_NOTIF_DETAIL, n).apply()
        }

    /** Retention as a seconds value for the engine's feed() call (null = keep forever). */
    fun retentionSecs(): ULong? = if (retentionDays <= 0) null else (retentionDays.toLong() * 86_400L).toULong()

    fun setRetention(days: Int) {
        retentionDays = days
        prefs.edit().putInt(KEY_RETENTION, days).apply()
        stampSetting(TS_RET)
    }

    // ---- LAST-WRITER-WINS stamps (multi-device sync) -----------------------------------------------
    //
    // Per-field profile-edit timestamps + per-key synced-setting timestamps, so two of the user's own
    // devices resolve an edit by WHO CHANGED IT LAST rather than who synced last (the endless profile /
    // settings ping-pong). Stamped ONLY on a real LOCAL edit — a value applied FROM sync must not
    // re-stamp (that kept the cycle going), guarded by [applyingRemote]. The setting keys are the iOS
    // storage-key strings so `setting-at:<key>` is byte-identical cross-platform. Mirrors iOS
    // ProfileStore.fieldTs + SettingsStore.settingTs.
    private val fieldTs = HashMap<String, Long>()
    private val settingTs = HashMap<String, Long>()
    private var applyingRemote = false

    init { loadStamps() }

    private fun loadStamps() {
        readMap(prefs.getString(KEY_FIELD_TS, null), fieldTs)
        readMap(prefs.getString(KEY_SETTING_TS, null), settingTs)
    }
    private fun readMap(raw: String?, into: HashMap<String, Long>) {
        into.clear()
        raw ?: return
        runCatching { val o = JSONObject(raw); for (k in o.keys()) into[k] = o.getLong(k) }
    }
    private fun persistFieldTs() {
        prefs.edit().putString(KEY_FIELD_TS, JSONObject(fieldTs as Map<*, *>).toString()).apply()
    }
    private fun persistSettingTs() {
        prefs.edit().putString(KEY_SETTING_TS, JSONObject(settingTs as Map<*, *>).toString()).apply()
    }
    private fun stampField(field: String) {
        if (applyingRemote) return
        fieldTs[field] = System.currentTimeMillis(); persistFieldTs()
    }
    private fun stampSetting(key: String) {
        if (applyingRemote) return
        settingTs[key] = System.currentTimeMillis(); persistSettingTs()
    }
    fun fieldTimestamp(field: String): Long = fieldTs[field] ?: 0L
    fun settingTimestamp(key: String): Long = settingTs[key] ?: 0L

    /** Apply a REMOTE profile field only if its timestamp is NEWER than our local edit (LWW). The write
     *  goes through the normal setter (UI refreshes) but is flagged so it isn't re-stamped. Returns
     *  whether applied. */
    fun applyRemoteField(field: String, value: String, ts: Long): Boolean {
        if (ts <= fieldTimestamp(field)) return false
        applyingRemote = true
        when (field) {
            "name" -> if (value != displayName) displayName = value
            "emoji" -> if (value.isNotEmpty() && value != emoji) emoji = value // never a blank emoji (has a default)
            "bio" -> if (value != bio) bio = value
            "link" -> if (value != link) link = value
        }
        save()
        applyingRemote = false
        fieldTs[field] = ts; persistFieldTs()
        return true
    }

    /** Apply a REMOTE synced-setting bool only if newer than ours (LWW). */
    fun applyRemoteSettingBool(key: String, value: Boolean, ts: Long): Boolean {
        if (ts <= settingTimestamp(key)) return false
        applyingRemote = true
        when (key) {
            TS_SAVE -> if (value != saveMyPosts) saveMyPosts = value
            TS_SAVE_OTHERS -> if (value != saveOthersPosts) saveOthersPosts = value
            TS_OPT -> if (value != autoOptimize) autoOptimize = value
        }
        applyingRemote = false
        settingTs[key] = ts; persistSettingTs()
        return true
    }
    /** Apply a REMOTE retention value only if newer than ours (LWW). */
    fun applyRemoteRetention(days: Int, ts: Long): Boolean {
        if (ts <= settingTimestamp(TS_RET)) return false
        applyingRemote = true
        if (days != retentionDays) setRetention(days)
        applyingRemote = false
        settingTs[TS_RET] = ts; persistSettingTs()
        return true
    }

    fun completeOnboarding(name: String, emoji: String) {
        displayName = name
        this.emoji = emoji
        onboarded = true
        prefs.edit()
            .putString(KEY_NAME, name)
            .putString(KEY_EMOJI, emoji)
            .putBoolean(KEY_ONBOARDED, true)
            .apply()
        stampField("name"); stampField("emoji")
    }

    /** Mark onboarding done WITHOUT setting a name/emoji — used when linking an existing identity
     *  (its profile arrives via multi-device sync, or the user edits it later). */
    fun markOnboarded() {
        onboarded = true
        prefs.edit().putBoolean(KEY_ONBOARDED, true).apply()
    }

    fun save() {
        // Stamp each field the user actually CHANGED (LWW), by comparing against the last-persisted
        // value — the Android equivalent of iOS's per-field didSet stamping. A no-op under applyingRemote
        // (a sync-applied write must not look like a fresh local edit).
        if (!applyingRemote) {
            if (displayName != (prefs.getString(KEY_NAME, "") ?: "")) stampField("name")
            if (bio != (prefs.getString(KEY_BIO, "") ?: "")) stampField("bio")
            if (link != (prefs.getString(KEY_LINK, "") ?: "")) stampField("link")
            if (emoji != (prefs.getString(KEY_EMOJI, "🌅") ?: "🌅")) stampField("emoji")
        }
        prefs.edit()
            .putString(KEY_NAME, displayName)
            .putString(KEY_BIO, bio)
            .putString(KEY_LINK, link)
            .putString(KEY_EMOJI, emoji)
            .putString(KEY_AVATAR, avatarB64)
            .apply()
        // Keep AvatarStore in sync so my avatar never diverges between the You tab and the feed
        // (some edit paths call save() rather than setAvatar()).
        runCatching { AvatarStore.put(HavenNet.nodeIdHex, avatarB64, emoji) }
    }

    /** Set + persist my avatar, and mirror it into [AvatarStore] so my own posts show it too. */
    fun setAvatar(base64: String) {
        avatarB64 = base64
        prefs.edit().putString(KEY_AVATAR, base64).apply()
        AvatarStore.put(HavenNet.nodeIdHex, base64, emoji)
    }

    fun reset() {
        onboarded = false
        displayName = ""
        bio = ""
        emoji = "🌅"
        fieldTs.clear(); settingTs.clear()
        prefs.edit().clear().apply()
    }

    companion object {
        private const val KEY_ONBOARDED = "onboarded"
        private const val KEY_NAME = "name"
        private const val KEY_BIO = "bio"
        private const val KEY_LINK = "link"
        private const val KEY_EMOJI = "emoji"
        private const val KEY_AVATAR = "avatar"
        private const val KEY_RETENTION = "retentionDays"
        private const val KEY_SAVE_MINE = "saveMyPosts"
        private const val KEY_SAVE_OTHERS = "saveOthersPosts"
        private const val KEY_OPTIMIZE = "autoOptimize"
        private const val KEY_VIDEO_SOUND = "videoSoundOn"
        private const val KEY_DATA_SAVER = "superDataSaver"
        private const val KEY_SEND_ORIGINAL = "sendOriginal"
        private const val KEY_NOTIF_DETAIL = "notificationDetail"
        private const val KEY_FIELD_TS = "profileFieldTs"
        private const val KEY_SETTING_TS = "settingTs"
        // Synced-setting LWW keys — the iOS storage-key strings, so `setting-at:<key>` interoperates.
        const val TS_SAVE = "haven.saveToPhotos"
        const val TS_SAVE_OTHERS = "haven.saveOthersToPhotos"
        const val TS_OPT = "haven.autoOptimize"
        const val TS_RET = "haven.retentionDays"

        @Volatile private var instance: ProfileStore? = null
        fun get(context: Context): ProfileStore =
            instance ?: synchronized(this) {
                instance ?: ProfileStore(context).also { instance = it }
            }
    }
}
