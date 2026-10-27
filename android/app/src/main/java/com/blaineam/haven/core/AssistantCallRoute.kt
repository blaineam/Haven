package com.blaineam.haven.core

/**
 * The pure rules behind "Hey Google, call Tracy on Haven" (docs/ASSISTANT.md) — no Android types, so
 * every decision is covered by a plain JVM test. The sibling of [AssistantRoute] (messages) and it
 * REUSES that tiered matcher, so "Tracy" / "Tracy M" / "Tracy Miller" resolve the way they do for
 * messages (and for Apple's `ContactMatching`) and "Tracy" never offers "Troy".
 *
 * Assistant's `actions.intent.CREATE_CALL` capability (res/xml/shortcuts.xml) launches
 * [MainActivity] with an explicit intent carrying the spoken participant ([EXTRA_NAME]) and the call
 * format ([EXTRA_FORMAT]). Unlike a message, a call can start from the intent — that is the whole
 * point of a voice command in a car — so the safety comes from WHO launched it instead:
 *
 *  * an explicit intent to an exported activity can be fired by any app on the phone, so the call is
 *    dialed immediately only when the launch is [trusted] (the Google app / Assistant, per the
 *    launching package — [isTrustedReferrer]); anything else (adb, another app, unknown) opens the
 *    conversation where the user taps Call themselves;
 *  * only a 1:1 contact is ever dialed — never a group thread, a locked or a blocked conversation
 *    (the candidate list excludes them, exactly as for messages);
 *  * only when no call is active (a second call would be refused anyway; the live call is shown);
 *  * Haven's voice calls are AUDIO: a video request is never auto-dialed (the thread opens instead);
 *  * a genuine tie asks (the Messages list), a name that matches nothing opens the list — never a
 *    guess, never a dissimilar name.
 */
object AssistantCallRoute {
    /** Custom action on the explicit intent in `shortcuts.xml`; must match the `android:action` there. */
    const val ACTION = "com.blaineam.haven.action.ASSISTANT_CALL"
    /** `call.participant.name` — the spoken name, or the matched shortcut id. */
    const val EXTRA_NAME = "callName"
    /** `call.callFormat` — "Audio" or "Video" (absent = audio). */
    const val EXTRA_FORMAT = "callFormat"

    /** The built-in intent and parameter names `shortcuts.xml` and the dynamic shortcuts bind to. */
    const val CAPABILITY_CREATE_CALL = "actions.intent.CREATE_CALL"
    const val PARAM_PARTICIPANT_NAME = "call.participant.name"
    const val PARAM_CALL_FORMAT = "call.callFormat"

    /** Launching packages whose intent we accept as a real voice command (the Google app hosts Assistant). */
    val TRUSTED_PACKAGES: Set<String> = setOf(
        "com.google.android.googlequicksearchbox",
        "com.google.android.apps.googleassistant",
    )

    /** One person Haven may call: a 1:1 contact only. [names] is the display name plus aliases. */
    data class Candidate(val circleId: String, val hex: String, val names: List<String>)

    sealed interface Plan {
        /** Dial [hex] now (the in-app call UI, with Hang up, appears). Only ever for a trusted launch. */
        data class Dial(val hex: String, val circleId: String) : Plan

        /** One person resolved but the call must NOT start from this intent — open their thread so the user taps Call. */
        data class Open(val circleId: String) : Plan

        /** No single person — nothing named, nothing found, or a genuine tie. Show the Messages list. */
        data class Pick(val tied: List<String>) : Plan

        /** A call is already live — bring it to the front, start nothing. */
        data object Busy : Plan
    }

    fun plan(name: String?, format: String?, trusted: Boolean, callActive: Boolean, candidates: List<Candidate>): Plan {
        val spoken = name?.trim().orEmpty()
        if (spoken.isEmpty()) return Plan.Pick(emptyList())

        // Assistant matched one of our dynamic shortcuts → it hands back the shortcut id (the dm: circle id).
        val hit = candidates.firstOrNull { it.circleId == spoken } ?: run {
            val matched = AssistantRoute.match(spoken, candidates.map { AssistantRoute.Candidate(it.circleId, it.names) })
            when (matched.size) {
                0 -> return Plan.Pick(emptyList())
                1 -> candidates.first { it.circleId == matched[0].circleId }
                else -> return Plan.Pick(matched.map { it.circleId })
            }
        }
        if (isVideo(format)) return Plan.Open(hit.circleId)
        if (callActive) return Plan.Busy
        return if (trusted) Plan.Dial(hit.hex, hit.circleId) else Plan.Open(hit.circleId)
    }

    /** Anything that says video is not auto-dialed; blank / "Audio" / unknown formats are an audio call. */
    fun isVideo(format: String?): Boolean = format?.trim()?.lowercase()?.contains("video") == true

    /**
     * Is [referrer] (the `android-app://<package>` URI of whoever launched the activity) the Google app
     * or the Assistant? Only the scheme and package are read — never a path, never an intent extra the
     * caller could have written. A null / malformed referrer is untrusted.
     */
    fun isTrustedReferrer(referrer: String?): Boolean {
        val uri = runCatching { java.net.URI(referrer ?: return false) }.getOrNull() ?: return false
        if (uri.scheme != "android-app") return false
        return uri.host in TRUSTED_PACKAGES
    }
}
