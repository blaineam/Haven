package com.blaineam.haven.core

import java.text.Normalizer

/**
 * The pure rules behind "Hey Google, send a message to Blaine on Haven" (docs/ASSISTANT.md) — no
 * Android types, so every decision is covered by a plain JVM test.
 *
 * Assistant's `actions.intent.CREATE_MESSAGE` capability (res/xml/shortcuts.xml) launches
 * [MainActivity] with an explicit intent carrying the spoken recipient ([EXTRA_NAME]) and, when the
 * user said one, the message body ([EXTRA_TEXT]). What Haven does with it is decided here:
 *
 *  * the recipient is resolved against the user's own contacts and group threads with the same tiered
 *    idea as Apple's `ContactMatching` (exact name > every spoken word is a word of the name >
 *    prefix / initial like "Tracy M" > a spelling guess) — the best tier present wins and only a real
 *    tie asks the user, so "Tracy" never offers "Troy";
 *  * when Assistant already matched one of our published shortcuts it passes the SHORTCUT ID (the
 *    `dm:` circle id) as the recipient — an exact circle id wins outright;
 *  * the message is only ever **staged in the composer** — never sent from the intent. An explicit
 *    intent to an exported activity can be fired by any app on the phone (and `haven://` links by any
 *    web page), so nothing that arrives this way may speak as the user without a tap. Sending by
 *    voice stays on the car/notification REPLY path ([CarMessaging]), whose PendingIntents only
 *    Haven itself can fire.
 *
 * Locked circles are never candidates: a locked conversation must not be confirmed to exist, opened,
 * or have text staged into it by a voice command.
 */
object AssistantRoute {
    /** Custom action on the explicit intent in `shortcuts.xml`; must match the `android:action` there. */
    const val ACTION = "com.blaineam.haven.action.ASSISTANT_MESSAGE"
    /** `message.recipient.name` — the spoken name, or the matched shortcut id. */
    const val EXTRA_NAME = "name"
    /** `message.text` — the message body, when the user said one. */
    const val EXTRA_TEXT = "text"

    /** The built-in intent and parameter names `shortcuts.xml` and the dynamic shortcuts bind to. */
    const val CAPABILITY_CREATE_MESSAGE = "actions.intent.CREATE_MESSAGE"
    const val PARAM_RECIPIENT_NAME = "message.recipient.name"

    /** Same cap as a car reply: an unreviewed wall of text is not staged either. */
    const val MAX_TEXT_CHARS = CarMessaging.MAX_REPLY_CHARS

    /** One thing the user can message. [names] is the display name plus aliases (first name, …). */
    data class Candidate(
        val circleId: String,
        val names: List<String>,
        /** A group DM — loses a tie to a 1:1 thread with the same name. */
        val group: Boolean = false,
    )

    sealed interface Plan {
        /** Open [circleId]'s thread; [draft] (nullable) is staged in its composer, never sent. */
        data class Open(val circleId: String, val draft: String?) : Plan

        /**
         * No single recipient — nothing named, nothing found, or a genuine tie. Open the Messages
         * list so the user picks. [tied] are the circle ids that tied (empty for none / not named).
         */
        data class Pick(val tied: List<String>) : Plan
    }

    fun plan(name: String?, text: String?, candidates: List<Candidate>): Plan {
        val draft = sanitizeText(text)
        val spoken = name?.trim().orEmpty()
        if (spoken.isEmpty()) return Plan.Pick(emptyList())

        // Assistant matched one of our dynamic shortcuts → it hands back the shortcut id.
        candidates.firstOrNull { it.circleId == spoken }?.let { return Plan.Open(it.circleId, draft) }

        val hits = match(spoken, candidates)
        return when (hits.size) {
            0 -> Plan.Pick(emptyList())
            1 -> Plan.Open(hits[0].circleId, draft)
            else -> Plan.Pick(hits.map { it.circleId })
        }
    }

    /** Candidates at the best tier that matches [spoken], best first; empty when nothing matches. */
    fun match(spoken: String, candidates: List<Candidate>): List<Candidate> {
        val s = tokens(spoken)
        if (s.isEmpty()) return emptyList()
        val scored = candidates.mapNotNull { c ->
            // names[0] is the real name; the rest are aliases (a first name), which may only ever
            // rank as "a word of the name" — so a contact literally called "Tracy" beats a
            // "Tracy Miller" whose alias is also "Tracy".
            val tier = c.names.withIndex().mapNotNull { (i, n) ->
                tier(s, tokens(n))?.let { t -> if (i == 0) t else maxOf(t, WORDS) }
            }.minOrNull() ?: return@mapNotNull null
            c to (tier + if (c.group) GROUP_PENALTY else 0)
        }
        val best = scored.minOfOrNull { it.second } ?: return emptyList()
        return scored.filter { it.second == best }.map { it.first }.distinctBy { it.circleId }
    }

    private const val GROUP_PENALTY = 10
    private const val EXACT = 0
    private const val WORDS = 1
    private const val PREFIX = 2
    private const val FUZZY = 3

    private fun tier(s: List<String>, n: List<String>): Int? {
        if (n.isEmpty()) return null
        if (s == n) return EXACT
        if (s.all { it in n }) return WORDS
        if (inOrder(s, n) { spoken, word -> word.startsWith(spoken) && (s.size > 1 || spoken.length >= 3) }) return PREFIX
        if (inOrder(s, n) { spoken, word -> fuzzyEqual(spoken, word) }) return FUZZY
        return null
    }

    /** Every spoken word pairs with a distinct word of the name, in the order spoken. */
    private fun inOrder(s: List<String>, n: List<String>, ok: (String, String) -> Boolean): Boolean {
        var from = 0
        for (spoken in s) {
            var hit = -1
            for (i in from until n.size) if (ok(spoken, n[i])) { hit = i; break }
            if (hit < 0) return false
            from = hit + 1
        }
        return true
    }

    /** One slip is fine from 4 letters, two from 7 — never so loose that Tracy reaches Troy. */
    private fun fuzzyEqual(a: String, b: String): Boolean {
        val limit = when { minOf(a.length, b.length) >= 7 -> 2; minOf(a.length, b.length) >= 4 -> 1; else -> 0 }
        if (limit == 0) return a == b
        if (kotlin.math.abs(a.length - b.length) > limit) return false
        return editDistance(a, b) <= limit
    }

    /** Optimal string alignment distance (insert / delete / substitute / adjacent swap = 1). */
    internal fun editDistance(a: String, b: String): Int {
        val d = Array(a.length + 1) { IntArray(b.length + 1) }
        for (i in 0..a.length) d[i][0] = i
        for (j in 0..b.length) d[0][j] = j
        for (i in 1..a.length) for (j in 1..b.length) {
            val cost = if (a[i - 1] == b[j - 1]) 0 else 1
            d[i][j] = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
                d[i][j] = minOf(d[i][j], d[i - 2][j - 2] + 1)
            }
        }
        return d[a.length][b.length]
    }

    /** Lower-case, accent-folded words: "Zoë  O'Brien" → [zoe, o, brien]. */
    internal fun tokens(raw: String): List<String> =
        Normalizer.normalize(raw, Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "")
            .lowercase()
            .replace(Regex("[^\\p{L}\\p{N}]+"), " ")
            .trim()
            .split(' ')
            .filter { it.isNotEmpty() }

    /** The body to stage: control characters dropped (newline and tab kept), trimmed, capped; null if blank. */
    fun sanitizeText(raw: String?): String? {
        val cleaned = raw.orEmpty().filter { it == '\n' || it == '\t' || !it.isISOControl() }.trim()
        if (cleaned.isEmpty()) return null
        return if (cleaned.length > MAX_TEXT_CHARS) cleaned.take(MAX_TEXT_CHARS) else cleaned
    }

    /** What a dynamic shortcut tells Assistant it can be called: the name, its first word, and aliases. */
    fun recipientNames(displayName: String): List<String> {
        val full = displayName.trim()
        if (full.isEmpty()) return emptyList()
        val first = full.split(Regex("\\s+")).first()
        return listOf(full, first).distinct()
    }
}
