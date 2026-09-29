package com.blaineam.haven.core

import com.blaineam.haven.BuildConfig
import org.json.JSONObject

/**
 * QA counters exported by the DEBUG qa dump (docs/QA.md): the relay-first media path (e2e step
 * `relayfirst`, Apple `QaMediaStats` parity) and the call screen-share lifecycle (step
 * `screenshare`). Recorded from the serve / receive / author / capture paths — several threads,
 * hence the lock. Every entry point is a no-op in release, like [QaDriver].
 */
object QaStats {
    private val lock = Any()
    private val counts = HashMap<String, Long>()
    private var lastDecline = ""
    private var seq = 0L
    /** ref → sequence of its FIRST authored enqueue; event id → sequence of its broadcast. */
    private val enqueuedAt = HashMap<String, Long>()
    private val broadcastAt = HashMap<String, Long>()

    fun bump(key: String, n: Long = 1) {
        if (!BuildConfig.DEBUG) return
        synchronized(lock) { counts[key] = (counts[key] ?: 0L) + n }
    }

    fun count(key: String): Long = synchronized(lock) { counts[key] ?: 0L }

    fun declined(why: String) {
        if (!BuildConfig.DEBUG) return
        synchronized(lock) { counts["serve_declined"] = (counts["serve_declined"] ?: 0L) + 1; lastDecline = why }
    }

    /** Friend asks answered with a direct STREAM: by what the ref is and why no hint answered it. */
    private val directByRole = HashMap<String, Long>()
    private val directByWhy = HashMap<String, Long>()
    private val directRecent = ArrayList<JSONObject>()

    fun directServe(ref: String, role: String, why: String) {
        if (!BuildConfig.DEBUG) return
        synchronized(lock) {
            directByRole[role] = (directByRole[role] ?: 0L) + 1
            directByWhy[why] = (directByWhy[why] ?: 0L) + 1
            directRecent += JSONObject().put("ref", ref.take(16)).put("role", role).put("why", why)
                .put("at_ms", System.currentTimeMillis())
            while (directRecent.size > 20) directRecent.removeAt(0)
        }
    }

    fun authoredEnqueued(refs: List<String>) {
        if (!BuildConfig.DEBUG) return
        synchronized(lock) {
            seq++
            counts["authored_refs_enqueued"] = (counts["authored_refs_enqueued"] ?: 0L) + refs.size
            for (r in refs) if (r !in enqueuedAt) enqueuedAt[r] = seq
            if (enqueuedAt.size > 5000) enqueuedAt.clear()
        }
    }

    fun broadcast(eventId: String?) {
        if (!BuildConfig.DEBUG || eventId.isNullOrEmpty()) return
        synchronized(lock) {
            seq++
            if (eventId !in broadcastAt) broadcastAt[eventId] = seq
            if (broadcastAt.size > 5000) broadcastAt.clear()
        }
    }

    /** The dump's `relay_first` object. [ownPosts] = (event id, real media refs) of MY posts: each
     *  broadcast this launch must have had every ref enqueued for the relay first. */
    fun relayFirst(ownPosts: List<Pair<String, List<String>>>): JSONObject = synchronized(lock) {
        var checked = 0; var early = 0
        for ((id, refs) in ownPosts) {
            if (refs.isEmpty()) continue
            val b = broadcastAt[id] ?: continue
            checked++
            if (refs.any { (enqueuedAt[it] ?: Long.MAX_VALUE) > b }) early++
        }
        val o = JSONObject()
        for (k in listOf("served_direct_friend", "served_direct_friend_bytes", "served_direct_own",
            "relay_hints_sent", "relay_hints_deferred", "received_via_relay", "received_via_direct",
            "media_requests_from_friends", "serve_declined", "authored_refs_enqueued",
            "pending_enrollment_refusals")) o.put(k, counts[k] ?: 0L)
        o.put("last_decline", lastDecline)
        o.put("served_direct_friend_by_role", JSONObject(HashMap(directByRole)))
        o.put("served_direct_friend_by_why", JSONObject(HashMap(directByWhy)))
        o.put("served_direct_friend_recent", org.json.JSONArray(ArrayList(directRecent)))
        o.put("authored_media_posts_checked", checked)
        o.put("broadcast_before_enqueue", early)
        val c = HeavyWorkMonitor.current
        o.put("heavy_work", JSONObject()
            .put("suspended", c.suspendHeavyIO)
            .put("friend_serving", c.peerServingAllowedForFriends)
            .put("reason", c.reason)
            .put("forced", c.forced))
        o
    }

    // ---- launch timing (e2e `launch` step): ms since PROCESS START, first occurrence only -------

    private val marks = HashMap<String, Long>()

    fun mark(name: String) {
        if (!BuildConfig.DEBUG) return
        val t = android.os.SystemClock.uptimeMillis() - android.os.Process.getStartUptimeMillis()
        synchronized(lock) { if (name !in marks) marks[name] = t }
    }

    fun launch(): JSONObject = synchronized(lock) {
        JSONObject()
            .put("first_feed_rendered_ms", marks["first_feed_rendered"] ?: JSONObject.NULL)
            .put("process_start_ms", System.currentTimeMillis() -
                (android.os.SystemClock.uptimeMillis() - android.os.Process.getStartUptimeMillis()))
    }

    // ---- screen share (CallManager / WebRTCPeer / ConnectionService) ---------------------------

    @Volatile var shareFgsReady: Boolean? = null
    /** Wall-clock ms the mediaProjection FGS promotion landed, and how long it took. */
    @Volatile var shareFgsReadyAtMs = 0L
    @Volatile var shareFgsWaitMs = -1L
    /** Wall-clock ms ScreenCapturerAndroid.startCapture ran (must be AFTER the FGS was ready). */
    @Volatile var shareCaptureStartAtMs = 0L
    @Volatile var shareCaptureW = 0
    @Volatile var shareCaptureH = 0
    @Volatile var shareSenderParamsOk: Boolean? = null
    @Volatile var shareStartError = ""
    /** Last MediaProjection consent outcome: "granted", "denied(<resultCode>)", or "" (none yet). */
    @Volatile var shareConsent = ""
    /** Consent prompts launched this process (the qa `screen_share` op + the call UI button). */
    @Volatile var shareConsentAttempts = 0
    /** Share starts that reached CallManager.startScreenShare (i.e. consent was granted). */
    @Volatile var shareAttempts = 0
    private val encoders = ArrayList<String>()

    fun noteEncoder(desc: String) {
        if (!BuildConfig.DEBUG) return
        synchronized(lock) { encoders += desc; if (encoders.size > 16) encoders.removeAt(0) }
    }

    fun encoders(): List<String> = synchronized(lock) { encoders.toList() }

    /** A new share attempt: forget the previous one's evidence. */
    fun resetShare() {
        shareAttempts++
        shareFgsReady = null; shareFgsReadyAtMs = 0; shareFgsWaitMs = -1; shareCaptureStartAtMs = 0
        shareCaptureW = 0; shareCaptureH = 0; shareSenderParamsOk = null; shareStartError = ""
    }
}
