package com.blaineam.haven.core

import java.util.concurrent.ConcurrentHashMap

/**
 * Which circles inherit the account-wide DEFAULT relay.
 *
 * The default relay is "applied to every circle, present and future". That is right for a relay the
 * user runs or chose, and wrong for a relay that is simply a FRIEND's (a friend-invite ticket's relay, a
 * wired/QA relay, one a friend announced for the circle we share): inheriting it puts a PRIVATE circle's
 * mailbox, enrollment and media on a relay whose operator is not in that circle. e2e `multirelay: no
 * private circle's media on a friend's relay that doesn't serve it` (A's private photo on B's relay):
 * the fleet's default was B's relay, A's new private circle inherited it, a sibling enrolled the circle
 * there, and self-sync (additive, never subtractive) wrote the inherited relay into the circle's
 * explicit list on every device — so flipping the default to A's own relay afterwards changed nothing.
 *
 * A relay is a friend's when its node id is a contact's account id or one of that contact's devices.
 * The default is withheld from circle X when it is a friend's relay AND that friend is not a member of
 * X. A relay nobody here knows as a contact's (own, hosted, cloud) is inherited by every circle as
 * before, and a friend's relay still serves every circle that friend is IN (the shared circle, DMs with
 * them) and any circle the user ticks it for explicitly — explicit assignment is never filtered.
 *
 * Mirrored by iOS `RelayDefaultScope` and desktop `relay_scope`.
 */
class RelayScope(private val now: () -> Long = System::currentTimeMillis, private val ttlMs: Long = 10_000L) {
    private class Snap(val at: Long, val friends: Set<String>, val members: ConcurrentHashMap<String, Set<String>>)
    @Volatile private var snap: Snap? = null

    /** Forget the cached membership (a contact was added/removed, a circle changed). */
    fun invalidate() { snap = null }

    /**
     * May [circleId] inherit the default relay [defaultHex]? [circleIds] lists every circle,
     * [membersOf] one circle's member node ids (contacts' account ids + their device ids, never mine).
     * Fail-open only for a relay no contact owns; a circle created after the snapshot is looked up
     * fresh, so a brand-new private circle is never judged against stale membership.
     */
    fun inherits(defaultHex: String, circleId: String, circleIds: () -> List<String>, membersOf: (String) -> Set<String>): Boolean {
        val def = defaultHex.lowercase()
        val t = now()
        var s = snap
        if (s == null || t - s.at > ttlMs || (!s.members.containsKey(circleId) && circleId !in circleIds())) {
            val m = ConcurrentHashMap<String, Set<String>>()
            val friends = HashSet<String>()
            for (c in circleIds()) { val ms = membersOf(c); m[c] = ms; friends.addAll(ms) }
            s = Snap(t, friends, m)
            snap = s
        }
        val mine = s.members.getOrPut(circleId) { membersOf(circleId) }
        return verdict(def, mine, s.friends)
    }

    /** Every circle's members (never me) from the snapshot, guaranteed to include [circleId]. */
    fun members(circleId: String, circleIds: () -> List<String>, membersOf: (String) -> Set<String>): Map<String, Set<String>> {
        inherits("", circleId, circleIds, membersOf)   // refreshes / learns the circle; the verdict is unused
        return HashMap(snap?.members ?: emptyMap())
    }

    companion object {
        /**
         * The relays a circle with NO relays of its own may be guessed onto (a self-sync-learned circle
         * whose record carried an empty list): a relay listed for another circle Y is usable only when
         * EVERYONE in Y is also in [circleId] — it exposes the circle to nobody it was not already shared
         * with. The old guess was "every active relay", which sent a private circle's mailbox reads to a
         * friend-operated standalone relay (R_C, whose node id is no contact's, so [verdict] cannot see
         * it); the transport then self-enrolled the circle there ("recover_forbidden") and the next media
         * upload was accepted. e2e `multirelay: … A private photo on R_C`.
         */
        fun fallback(circleId: String, members: Map<String, Set<String>>, lists: Map<String, List<String>>,
                     unwired: List<String> = emptyList()): List<String> {
            val mine = members[circleId] ?: emptySet()
            val out = LinkedHashSet<String>()
            out.addAll(unwired)   // a relay no circle lists was shared with nobody
            for ((y, relays) in lists) {
                if (y == circleId) continue
                if ((members[y] ?: emptySet()).all { it in mine }) out.addAll(relays)
            }
            return out.toList()
        }

        /** The pure rule: withheld iff [def] is a friend's node id and that friend is not in this circle. */
        fun verdict(def: String, circleMembers: Set<String>, friends: Set<String>): Boolean =
            !(def in friends && def !in circleMembers)
    }
}

/**
 * Event-driven re-scope of circles whose relay set can change under them.
 *
 * A circle with NO relay list of its own (a self-sync-learned circle whose record carried an empty list)
 * is guessed onto [RelayScope.fallback] relays, which is deliberately narrow (privacy). That set is
 * computed per call, so a relay learned LATER is picked up by the next poll — but an event authored
 * before it was learned had already uploaded to nowhere, and nothing re-uploaded it, so a private post
 * to my other devices read "never" until the 24h refresh. This remembers each circle's effective relay
 * set; [gained] returns the circles that were key-less at the last look and have since gained a relay
 * (a relay learned, the circle's record landing with its list, a default adopted) so the caller can
 * backfill exactly those — no polling, no widening of who is allowed to hold the circle.
 * The first call only seeds: a cold start's periodic backfill covers what was already there.
 */
class KeylessScopeWatch {
    /** One circle's effective relays and whether it had NO list of its own when observed. */
    data class Scope(val keyless: Boolean, val relays: Set<String>)

    private var seeded = false
    private var seen: Map<String, Scope> = emptyMap()

    @Synchronized
    fun gained(current: Map<String, Scope>): List<String> {
        val before = seen
        seen = current
        if (!seeded) { seeded = true; return emptyList() }
        val out = ArrayList<String>()
        for ((cid, now) in current) {
            val was = before[cid] ?: Scope(true, emptySet())   // a circle first seen after the seed
            if (was.keyless && now.relays.any { it !in was.relays }) out.add(cid)
        }
        return out
    }
}
