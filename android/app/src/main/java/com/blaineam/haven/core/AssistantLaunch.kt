package com.blaineam.haven.core

import android.content.Context
import androidx.compose.runtime.mutableIntStateOf

/**
 * The Android side of [AssistantRoute]: builds the candidate list from live app state and applies
 * the plan. Kept thin so every decision stays in the pure, JVM-tested [AssistantRoute].
 */
object AssistantLaunch {
    /** Bumped when a voice command could not pick one recipient — RootScreen opens the Messages tab. */
    val showMessages = mutableIntStateOf(0)

    /** Everyone Haven may message by voice: contacts (1:1) and group DM threads, never a locked circle. */
    fun candidates(): List<AssistantRoute.Candidate> {
        val me = HavenNet.nodeIdHex
        val people = HavenNet.contacts
            .filter { !it.idHex.equals(me, true) && !HavenNet.blocked.contains(it.idHex) }
            .mapNotNull { c ->
                val id = HavenNet.dmCircleId(c.idHex)
                if (CircleLock.isLocked(id)) null
                else AssistantRoute.Candidate(id, AssistantRoute.recipientNames(c.name))
            }
        val groups = runCatching { HavenNet.groupDmThreads() }.getOrDefault(emptyList())
            .filter { !CircleLock.isLocked(it.first) }
            .map { (id, title) ->
                AssistantRoute.Candidate(id, listOf(title) + title.split(",").map { it.trim() }, group = true)
            }
        return people + groups
    }

    /** Resolve one Assistant `CREATE_MESSAGE` request. Off the main thread: it boots the engine. */
    fun resolve(context: Context, name: String?, text: String?): AssistantRoute.Plan {
        HavenNet.init(context.applicationContext)
        return AssistantRoute.plan(name, text, candidates())
    }

    /** Apply a resolved plan — on the main thread ([DmDrafts] is read there). Never sends: see [AssistantRoute]. */
    fun apply(plan: AssistantRoute.Plan) {
        when (plan) {
            is AssistantRoute.Plan.Open ->
                if (plan.draft != null) DmDrafts.stage(plan.circleId, plan.draft)
                else DmDrafts.openThread.value = plan.circleId
            is AssistantRoute.Plan.Pick -> showMessages.intValue++
        }
    }

    // ---------------------------------------------------------------- "call <name> on Haven"

    /** Everyone Haven may call by voice: 1:1 contacts only — never a group thread, a locked or a blocked conversation. */
    fun callCandidates(): List<AssistantCallRoute.Candidate> {
        val me = HavenNet.nodeIdHex
        return HavenNet.contacts
            .filter { !it.idHex.equals(me, true) && !HavenNet.blocked.contains(it.idHex) }
            .mapNotNull { c ->
                val id = HavenNet.dmCircleId(c.idHex)
                if (CircleLock.isLocked(id)) null
                else AssistantCallRoute.Candidate(id, c.idHex, AssistantRoute.recipientNames(c.name))
            }
    }

    /** Resolve one Assistant `CREATE_CALL` request. Off the main thread: it boots the engine. */
    fun resolveCall(context: Context, name: String?, format: String?, trusted: Boolean): AssistantCallRoute.Plan {
        HavenNet.init(context.applicationContext)
        return AssistantCallRoute.plan(name, format, trusted, CallManager.callInProgress, callCandidates())
    }

    /**
     * Apply a resolved call plan — on the main thread. A dial needs the microphone: without the grant
     * the thread opens instead, where tapping Call runs the permission prompt (a voice launch from the
     * background cannot show it). The call itself goes out through Telecom ([CallManager.startCall]).
     */
    fun applyCall(context: Context, plan: AssistantCallRoute.Plan) {
        when (plan) {
            is AssistantCallRoute.Plan.Dial -> {
                val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                    context, android.Manifest.permission.RECORD_AUDIO,
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                if (!granted) { DmDrafts.openThread.value = plan.circleId; return }
                val name = HavenNet.contacts.firstOrNull { it.idHex.equals(plan.hex, true) }?.name.orEmpty().ifBlank { "Friend" }
                CallManager.startCall(listOf(plan.hex), name)
            }
            is AssistantCallRoute.Plan.Open -> DmDrafts.openThread.value = plan.circleId
            is AssistantCallRoute.Plan.Pick -> showMessages.intValue++
            AssistantCallRoute.Plan.Busy -> CallManager.minimized.value = false
        }
    }
}
