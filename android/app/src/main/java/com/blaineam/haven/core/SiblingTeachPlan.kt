package com.blaineam.haven.core

/**
 * What an in-app host teaches each relay about its siblings (iOS `SiblingTeachPlan` parity).
 *
 * PER CIRCLE: a relay taught a sibling for a circle lets that sibling replicate the circle's
 * mailbox, so each circle's relays learn only each other. The flat pool (every relay we know, for
 * every circle we are in) made a friend's relay adopted for ONE shared circle a mirror of the rest,
 * and kept it mirroring a circle after the circle's creator removed us from it.
 *
 * Returns target relay → [(circle, that circle's OTHER relays)]. A circle's relays are those it is
 * configured with that are live now, plus our own hosted relay ([myHex], which serves every circle
 * we are in). A circle with a single relay teaches nothing. Deterministic order.
 */
internal fun siblingTeachPlan(
    circleIds: List<String>,
    relaysFor: (String) -> List<String>,
    live: Set<String>,
    myHex: String,
): List<Pair<String, List<Pair<String, List<String>>>>> {
    val liveLc = live.map { it.lowercase() }.toSet()
    val byTarget = sortedMapOf<String, MutableList<Pair<String, List<String>>>>()
    for (cid in circleIds.toSortedSet()) {
        val set = relaysFor(cid).map { it.lowercase() }.filter { it in liveLc }.toMutableSet()
        if (myHex.length == 64) set.add(myHex.lowercase())
        if (set.size < 2) continue
        for (target in set.sorted()) {
            byTarget.getOrPut(target) { mutableListOf() }.add(cid to (set - target).sorted())
        }
    }
    return byTarget.map { (t, lessons) -> t to lessons.toList() }
}
