package com.blaineam.haven.core

/**
 * Which of my media refs the unsolicited own-device push ([HavenNet.pushOwnMediaNearby]) sends this
 * pass.
 *
 * That push streams full originals to every one of my devices over iroh — addressed to my ACCOUNT id,
 * which the transport expands to all my device ids, so it is not "nearby" at all once the mesh is up.
 * It was the one serve path the ultra-constrained gate never covered: with Android forced to
 * satellite, its 330 KB original reached the iPhone this way, the iPhone (on a normal link) backed it
 * up as its own, and the friend got the full photo mid-pass (e2e 2026-09-30, `satellite holds back
 * the full photo (android→)`). A ref the link may not carry is SKIPPED WITHOUT being marked pushed,
 * so the next pass after the link improves sends it — deferred, never dropped.
 *
 * Pure so the policy is testable: [alreadyPushed] is mutated for every ref this pass sends.
 */
object OwnMediaPush {
    fun pick(
        refs: Iterable<String>,
        alreadyPushed: MutableSet<String>,
        budget: Int,
        eligible: (String) -> Boolean,
        mayMoveOverLink: (String) -> Boolean,
    ): List<String> {
        val out = ArrayList<String>()
        for (ref in refs) {
            if (out.size >= budget) break
            if (ref in alreadyPushed || !eligible(ref)) continue
            if (!mayMoveOverLink(ref)) continue   // held for a better link — deliberately not marked
            alreadyPushed.add(ref)
            out.add(ref)
        }
        return out
    }
}
