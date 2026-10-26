package com.blaineam.haven.ui

/** One circle the composer can post to: id + the name to show (nickname-aware, resolved by the caller). */
data class PostTarget(val id: String, val name: String)

/**
 * Selection rules for the long-press "Post to N circles" sheet. Pure, so the rules are unit-tested
 * on the JVM. A plain tap on Post never touches any of this — it posts to the active circle only.
 *
 * Media is NOT a limit: attachments are sealed once for every chosen circle (one blob, one upload —
 * see HavenNet.postToCircles), so every circle is selectable with or without attachments.
 */
object MultiCircle {
    const val HINT_AFTER_POSTS = 3

    /** Circles offered: everything except DMs (`dm:` ids) and duplicates, in the caller's order. */
    fun targets(all: List<PostTarget>): List<PostTarget> =
        all.filter { !it.id.startsWith("dm:") }.distinctBy { it.id }

    /** The sheet opens with only the current circle checked (empty if it isn't postable, e.g. a DM). */
    fun initialSelection(active: String, targets: List<PostTarget>): Set<String> =
        if (targets.any { it.id == active }) setOf(active) else emptySet()

    fun toggle(selection: Set<String>, id: String): Set<String> =
        if (id in selection) selection - id else selection + id

    /** The circles to author into, active first then the sheet's order; unknown/DM ids are dropped. */
    fun orderedForPosting(selection: Set<String>, targets: List<PostTarget>, active: String): List<String> {
        val ids = targets.map { it.id }.filter { it in selection }
        return if (active in ids) listOf(active) + ids.filter { it != active } else ids
    }

    /** One-time tip: only for people in 2+ circles, after a few posts, never twice. */
    fun shouldShowHint(circleCount: Int, textPostsMade: Int, alreadyShown: Boolean): Boolean =
        !alreadyShown && circleCount >= 2 && textPostsMade >= HINT_AFTER_POSTS
}
