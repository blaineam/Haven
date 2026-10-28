package com.blaineam.haven.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * LOCAL-ONLY index of the copies of one multi-circle post ("Post to N circles").
 *
 * A multi-circle post is authored as N independent events, one per circle, with nothing on the wire
 * linking them. To let an edit of one copy reach every other copy automatically, the device that posted
 * remembers which (circle, event id) pairs belong together. Nothing here is sent anywhere; posts made
 * before this index existed (or on another device) simply have no group and edit one circle only.
 *
 * Capped at [MAX_GROUPS], oldest evicted first. Persisted as JSON in SharedPreferences.
 */
object MultiPostGroups {
    const val MAX_GROUPS = 500
    private const val PREFS = "haven.multiPostGroups"
    private const val KEY = "groups"

    data class Member(val circleId: String, val eventId: String)

    private lateinit var appContext: Context
    private val groups = ArrayList<List<Member>>()   // oldest first
    @Volatile private var loaded = false

    /** (Re)bind to [ctx] and reload from disk. */
    @Synchronized fun init(ctx: Context) {
        appContext = ctx.applicationContext
        groups.clear(); loaded = false
        load()
    }

    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized private fun load() {
        if (loaded) return
        loaded = true
        if (!this::appContext.isInitialized) return
        val raw = prefs.getString(KEY, null) ?: return
        runCatching {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val g = arr.getJSONArray(i)
                val members = (0 until g.length()).map {
                    val o = g.getJSONObject(it); Member(o.getString("c"), o.getString("e"))
                }
                if (members.size >= 2) groups += members
            }
        }
    }

    @Synchronized private fun persist() {
        if (!this::appContext.isInitialized) return
        val arr = JSONArray()
        for (g in groups) arr.put(JSONArray().also { a ->
            g.forEach { a.put(JSONObject().put("c", it.circleId).put("e", it.eventId)) }
        })
        prefs.edit().putString(KEY, arr.toString()).apply()
    }

    /** Record one group. Needs at least two distinct circles with real ids, else nothing is stored. */
    @Synchronized fun register(members: List<Member>) {
        load()
        val clean = members.filter { it.circleId.isNotBlank() && it.eventId.isNotBlank() }.distinct()
        if (clean.map { it.circleId }.distinct().size < 2) return
        groups += clean
        while (groups.size > MAX_GROUPS) groups.removeAt(0)
        persist()
    }

    /** The OTHER copies of the post identified by ([circleId], [eventId]); empty when it has no group. */
    @Synchronized fun siblingsOf(circleId: String, eventId: String): List<Member> {
        load()
        val g = groups.firstOrNull { grp -> grp.any { it.circleId == circleId && it.eventId == eventId } }
            ?: return emptyList()
        return g.filter { !(it.circleId == circleId && it.eventId == eventId) }
    }

    /** Forget one copy (its circle is gone). A group left with a single copy is dropped. */
    @Synchronized fun forget(member: Member) {
        load()
        val it = groups.listIterator()
        var changed = false
        while (it.hasNext()) {
            val g = it.next()
            if (member !in g) continue
            changed = true
            val rest = g - member
            if (rest.size >= 2) it.set(rest) else it.remove()
        }
        if (changed) persist()
    }

    @Synchronized fun count(): Int { load(); return groups.size }

    @Synchronized fun clear() {
        groups.clear(); loaded = true
        if (this::appContext.isInitialized) runCatching { prefs.edit().remove(KEY).apply() }
    }
}
