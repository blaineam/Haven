package com.blaineam.haven.core

/**
 * The pure rules behind Haven's Android Auto CAR APP — the Calls screen the head unit draws with the
 * Car App Library's templates (docs/ANDROID-CALLS.md; the sibling of Apple's CarPlay Calls tab).
 * No Android types here, so every decision is covered by a plain JVM test; the Android glue
 * (`car/`) only turns these values into templates.
 *
 * What Android Auto shows, by design:
 *  * **Recents** — people Haven can call, most recently active conversation first;
 *  * **Contacts** — everyone Haven can call, A→Z;
 *  * a row is a name and an avatar. NEVER message text (this is a screen on a moving car's display);
 *  * a tap DIALS — there is no contact card in between (CarPlay parity: `CarPlayTemplates` rows dial
 *    on tap) — and goes out through the same Telecom path as the in-app Call button and
 *    "Hey Google, call Tracy on Haven" ([CallManager.startCall]).
 *
 * Who is callable is decided where the candidates are built ([CarCallSource]): 1:1 contacts only,
 * never yourself, a blocked contact or a biometric-locked conversation — exactly the
 * [AssistantLaunch.callCandidates] rule.
 */
object CarCalls {
    const val TAB_RECENTS = "recents"
    const val TAB_CONTACTS = "contacts"

    /** `TabTemplate` needs Car App API level 6; older hosts get one list with two sections instead. */
    const val TAB_TEMPLATE_API_LEVEL = 6

    /** The most rows we ever ask the host for, however generous its [content limit][androidx.car.app.constraints.ConstraintManager]. */
    const val MAX_ROWS = 100

    /** A callable person: [circleId] is the `dm:` circle, [hex] the account id the call is dialed to. */
    data class Person(val circleId: String, val hex: String, val name: String, val lastActivityMs: Long)

    /** One row on the head unit. */
    data class Entry(val circleId: String, val hex: String, val name: String)

    sealed interface Snapshot {
        /** The engine is booting (a cold start) — the screen shows the host's spinner. */
        data object Loading : Snapshot

        /** No account yet (onboarding not finished) — nothing to call; the phone has to finish setup. */
        data object NeedsSetup : Snapshot

        /** The callable people; the screen cuts the lists to the host's per-template item limit. */
        data class Ready(val people: List<Person>) : Snapshot
    }

    private fun Person.entry() = Entry(circleId, hex, name.ifBlank { FALLBACK_NAME })
    private const val FALLBACK_NAME = "Friend"

    /**
     * Callable people ordered by their latest conversation activity, newest first; people with no
     * activity at all are not "recent". A tie (the same millisecond) falls back to the name, then the
     * id, so the order is deterministic. At most [max] rows.
     */
    fun recents(people: List<Person>, max: Int): List<Entry> =
        people.asSequence()
            .distinctBy { it.hex.lowercase() }
            .filter { it.lastActivityMs > 0 }
            .sortedWith(compareByDescending<Person> { it.lastActivityMs }.thenBy { it.name.lowercase() }.thenBy { it.hex })
            .take(clamp(max))
            .map { it.entry() }
            .toList()

    /** Everyone callable, A→Z (case-insensitive, accents folded), at most [max] rows. */
    fun contacts(people: List<Person>, max: Int): List<Entry> =
        people.asSequence()
            .distinctBy { it.hex.lowercase() }
            .sortedWith(compareBy<Person> { sortKey(it.name) }.thenBy { it.hex })
            .take(clamp(max))
            .map { it.entry() }
            .toList()

    /** True when [people] has more callable contacts than the host lets one list show ([max]) — the screen then offers search. */
    fun truncated(people: List<Person>, max: Int): Boolean =
        people.distinctBy { it.hex.lowercase() }.size > clamp(max)

    /**
     * Typed / spoken search over the callable people, using the same tiered matcher as "call Tracy on
     * Haven" ([AssistantRoute.match]) so "tra" finds Tracy by prefix and "Tracy" never offers Troy.
     * A blank query is the A→Z list. At most [max] rows.
     */
    fun search(people: List<Person>, query: String, max: Int): List<Entry> {
        val q = query.trim()
        if (q.isEmpty()) return contacts(people, max)
        val byCircle = people.associateBy { it.circleId }
        val candidates = people.map { AssistantRoute.Candidate(it.circleId, AssistantRoute.recipientNames(it.name)) }
        val hits = AssistantRoute.match(q, candidates).mapNotNull { byCircle[it.circleId] }
        return contacts(hits, max)
    }

    /** One or two letters for an avatar with no photo: first letters of the first and last word. */
    fun initials(name: String): String {
        val words = name.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return "?"
        val first = words.first().first()
        val last = if (words.size > 1) words.last().first() else null
        return (listOfNotNull(first, last)).joinToString("").uppercase()
    }

    // ------------------------------------------------------------------------ placing a call

    /** What a tap on a row does, decided before any side effect. */
    enum class Gate {
        /** Dial now (Telecom first, the direct path if Telecom refuses — [CallManager.startCall]). */
        DIAL,

        /** A Haven call is already live — a second one would be refused; show the live call instead. */
        BUSY,

        /** Dialing needs the microphone and it isn't granted — ask for it on the phone, then dial. */
        NEEDS_MIC,
    }

    fun gate(callActive: Boolean, micGranted: Boolean): Gate = when {
        callActive -> Gate.BUSY
        !micGranted -> Gate.NEEDS_MIC
        else -> Gate.DIAL
    }

    /** How long we wait for a tapped call to show any sign of life before leaving the "Calling…" screen. */
    const val CALL_START_GRACE_MS = 15_000L

    enum class Phase {
        /** Dialing / ringing / connecting. */
        CALLING,

        /** Established. */
        ON_CALL,

        /** Over (or it never started) — leave the in-call screen. */
        ENDED,
    }

    /**
     * The in-call screen's phase from the engine's three flags. [everActive] is true once the call has
     * been in progress at least once; a call that was live and no longer is has ENDED, and one that
     * never showed any sign of life within [CALL_START_GRACE_MS] (Telecom refused, mic denied on the
     * phone) has too — the screen must not sit on "Calling…" forever.
     */
    fun phase(ringing: Boolean, connecting: Boolean, inCall: Boolean, everActive: Boolean, waitedMs: Long): Phase = when {
        inCall -> Phase.ON_CALL
        ringing || connecting -> Phase.CALLING
        everActive -> Phase.ENDED
        waitedMs >= CALL_START_GRACE_MS -> Phase.ENDED
        else -> Phase.CALLING
    }

    // ------------------------------------------------------------------------ helpers

    private fun clamp(max: Int) = max.coerceIn(1, MAX_ROWS)

    private fun sortKey(name: String): String =
        java.text.Normalizer.normalize(name.ifBlank { FALLBACK_NAME }.trim(), java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "")
            .lowercase()
}
