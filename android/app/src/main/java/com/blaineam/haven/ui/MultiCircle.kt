package com.blaineam.haven.ui

/** One circle the composer can post to: id + the name to show (nickname-aware, resolved by the caller). */
data class PostTarget(val id: String, val name: String)

/**
 * Selection rules for the long-press "Post to N circles" sheet. Pure, so the rules are unit-tested
 * on the JVM. A plain tap on Post never touches any of this — it posts to the active circle only.
 *
 * Media rule: Haven seals each media blob under ONE circle's key, and the blob is stored by ref
 * (one file per ref, uploaded by ref), so the same photo cannot be readable in two circles at once on
 * this transport. While a photo/video/file is attached the sheet therefore only allows the circle the
 * media was staged in (the active one). Songs, locations and text carry no blob and go anywhere.
 */
object MultiCircle {
    const val HINT_AFTER_POSTS = 3

    /** Circles offered: everything except DMs (`dm:` ids) and duplicates, in the caller's order. */
    fun targets(all: List<PostTarget>): List<PostTarget> =
        all.filter { !it.id.startsWith("dm:") }.distinctBy { it.id }

    /** The sheet opens with only the current circle checked (empty if it isn't postable, e.g. a DM). */
    fun initialSelection(active: String, targets: List<PostTarget>): Set<String> =
        if (targets.any { it.id == active }) setOf(active) else emptySet()

    /** Whether [id] may be toggled. With blob media attached only [active] is allowed. */
    fun isSelectable(id: String, active: String, hasBlobMedia: Boolean): Boolean =
        !hasBlobMedia || id == active

    fun toggle(selection: Set<String>, id: String, active: String, hasBlobMedia: Boolean): Set<String> {
        if (!isSelectable(id, active, hasBlobMedia)) return selection
        return if (id in selection) selection - id else selection + id
    }

    /** The circles to author into, active first then the sheet's order; unknown/DM ids are dropped. */
    fun orderedForPosting(selection: Set<String>, targets: List<PostTarget>, active: String): List<String> {
        val ids = targets.map { it.id }.filter { it in selection }
        return if (active in ids) listOf(active) + ids.filter { it != active } else ids
    }

    /** One-time tip: only for people in 2+ circles, after a few posts, never twice. */
    fun shouldShowHint(circleCount: Int, textPostsMade: Int, alreadyShown: Boolean): Boolean =
        !alreadyShown && circleCount >= 2 && textPostsMade >= HINT_AFTER_POSTS
}
