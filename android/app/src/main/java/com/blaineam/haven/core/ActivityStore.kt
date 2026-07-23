package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import uniffi.haven_ffi.HavenSocial

/**
 * The in-app activity list — "who did what that concerns me", across every circle (parity with the
 * core `social.activity()` reducer the other platforms share).
 *
 * Two row sources merge here:
 *  • ENGINE rows: `social.activity()` reduces every circle's decrypted events (reactions/comments/
 *    votes on MY events, others' posts, stories, DMs) — recomputed off-main on a debounced poke
 *    from HavenNet's ingest paths, never persisted (the event log is the store).
 *  • APP rows: things the engine can't see — a new connection accepted, being added to a circle —
 *    recorded by HavenNet where it detects them, persisted as JSON in SharedPreferences.
 *
 * `seenAt` is the read watermark: rows newer than it badge the bell. It self-syncs across the
 * user's devices via `setting:activitySeenAt` (per-key MAX merge — reading on one device clears
 * the badge on the others, and no device can un-read another).
 */
object ActivityStore {
    private const val PREFS = "haven.activity"
    private const val KEY_SEEN_AT = "seenAt"
    private const val KEY_APP_ROWS = "appRows"
    private const val ENGINE_WINDOW_MS = 30L * 24 * 3600 * 1000   // a month of history is plenty

    /** One rendered row. [kind] is the core's ("react"|"comment"|"vote"|"post"|"story"|"dm") plus
     *  the app-layer "connect" and "circle". [targetId] = the parent post for reactions/comments. */
    data class Row(
        val id: String,
        val kind: String,
        val circleId: String,
        val actorHex: String,
        val actorShort: String,
        val targetId: String?,
        val snippet: String,
        val createdAt: Long,
        val emoji: String?,
    )

    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Bumped whenever [rows] or [seenAt] change so the bell badge + list recompose. */
    val version = mutableIntStateOf(0)

    /** Merged rows, newest-first. Read from the UI; refreshed off-main by [poke]. */
    @Volatile var rows: List<Row> = emptyList()
        private set

    @Volatile private var seenAtMs: Long = 0L
    @Volatile private var refreshPending = false

    fun init(context: Context) {
        if (this::appContext.isInitialized) return
        appContext = context.applicationContext
        seenAtMs = prefs.getLong(KEY_SEEN_AT, 0L)
        rows = loadAppRows()
    }

    private val ready get() = this::appContext.isInitialized

    // ---- Read watermark ------------------------------------------------------------------------

    fun seenAt(): Long = seenAtMs

    fun unseenCount(): Int = rows.count { it.createdAt > seenAtMs }

    /** The user looked at the list — everything currently shown is read. Self-syncs (MAX merge). */
    fun markSeen() {
        val now = System.currentTimeMillis()
        if (now <= seenAtMs) return
        seenAtMs = now
        if (ready) prefs.edit().putLong(KEY_SEEN_AT, now).apply()
        bump()
        // LOCAL read of the bell — nudge a debounced forced self-sync so the badge clears on my
        // other devices in seconds (applySyncedSeenAt, the remote path, never lands here).
        HavenNet.selfSyncNudge()
    }

    /** A sibling device's watermark arrived via self-sync — per-key MAX merge (monotonic). */
    fun applySyncedSeenAt(ms: Long) {
        if (ms <= seenAtMs) return
        seenAtMs = ms
        if (ready) prefs.edit().putLong(KEY_SEEN_AT, ms).apply()
        bump()
    }

    // ---- App-layer rows (connections / circle adds) --------------------------------------------

    /** A new connection was accepted — the engine has no event for it, so record it here. */
    fun noteConnection(idHex: String, name: String) {
        addAppRow(Row(
            id = "connect:$idHex",
            kind = "connect",
            circleId = "",
            actorHex = idHex,
            actorShort = idHex.take(8),
            targetId = null,
            snippet = name,
            createdAt = System.currentTimeMillis(),
            emoji = null,
        ))
    }

    /** This device learned it was added to a (new) circle. */
    fun noteCircleAdd(circleId: String, circleName: String) {
        addAppRow(Row(
            id = "circle:$circleId",
            kind = "circle",
            circleId = circleId,
            actorHex = "",
            actorShort = "",
            targetId = null,
            snippet = circleName,
            createdAt = System.currentTimeMillis(),
            emoji = null,
        ))
    }

    private fun addAppRow(row: Row) {
        if (!ready) return
        val existing = loadAppRows()
        if (existing.any { it.id == row.id }) return   // deduped on the stable id
        val next = (listOf(row) + existing).take(200)
        saveAppRows(next)
        poke(null)   // remerge (engine rows unchanged; social may be absent — app rows still land)
        bump()
    }

    private fun loadAppRows(): List<Row> {
        if (!ready) return emptyList()
        val raw = prefs.getString(KEY_APP_ROWS, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                Row(
                    id = o.optString("id"),
                    kind = o.optString("kind"),
                    circleId = o.optString("cid"),
                    actorHex = o.optString("actor"),
                    actorShort = o.optString("short"),
                    targetId = o.optString("target").takeIf { it.isNotEmpty() },
                    snippet = o.optString("snippet"),
                    createdAt = o.optLong("at"),
                    emoji = o.optString("emoji").takeIf { it.isNotEmpty() },
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun saveAppRows(rows: List<Row>) {
        val arr = JSONArray()
        for (r in rows) {
            arr.put(JSONObject()
                .put("id", r.id).put("kind", r.kind).put("cid", r.circleId)
                .put("actor", r.actorHex).put("short", r.actorShort)
                .put("target", r.targetId ?: "").put("snippet", r.snippet)
                .put("at", r.createdAt).put("emoji", r.emoji ?: ""))
        }
        runCatching { prefs.edit().putString(KEY_APP_ROWS, arr.toString()).apply() }
    }

    // ---- Engine rows ---------------------------------------------------------------------------

    /**
     * Something was ingested — recompute the merged list off-main, debounced so an ingest burst
     * costs one reduce, not one per envelope. `social.activity()` copies each circle's events out
     * under the lock and reduces with it released, so this never stalls the engine.
     */
    fun poke(social: HavenSocial?) {
        if (!ready || refreshPending) return
        refreshPending = true
        scope.launch {
            kotlinx.coroutines.delay(1_500)
            refreshPending = false
            refresh(social)
        }
    }

    private fun refresh(social: HavenSocial?) {
        val now = System.currentTimeMillis()
        val engineRows: List<Row> = if (social != null) {
            runCatching {
                social.activity(((now - ENGINE_WINDOW_MS).coerceAtLeast(0L)).toULong(), now.toULong())
            }.getOrDefault(emptyList()).map {
                Row(
                    id = it.id, kind = it.kind, circleId = it.circleId,
                    actorHex = it.actorHex, actorShort = it.actorShort,
                    targetId = it.targetId, snippet = it.snippet,
                    createdAt = it.createdAt.toLong(), emoji = it.emoji,
                )
            }
        } else rows.filter { it.kind !in setOf("connect", "circle") }   // keep last engine merge
        val merged = (engineRows + loadAppRows())
            .sortedWith(compareByDescending<Row> { it.createdAt }.thenBy { it.id })
            .take(500)
        if (merged != rows) {
            rows = merged
            bump()
        }
    }

    private fun bump() {
        scope.launch(Dispatchers.Main) { version.intValue++ }
    }
}
