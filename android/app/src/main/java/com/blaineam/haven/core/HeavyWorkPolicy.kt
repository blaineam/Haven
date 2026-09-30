package com.blaineam.haven.core

/**
 * The pure half of "is this phone allowed to do heavy media I/O right now?" — Apple
 * `HeavyWorkPolicy.swift` parity (same rules, same thresholds, so both platforms answer alike).
 *
 * Field report (2026-09-28): a phone got hot DURING A CALL because Haven streamed a whole video
 * peer-to-peer to a friend — a KEM seal per 32 KB chunk — while the same blob sat on (or was minutes
 * from landing on) the user's relay. The rule encoded here: THE RELAY IS THE MEDIA PATH. Streaming
 * to a friend is the fallback for a circle with no relay (or a relay copy the requester provably
 * cannot read), and only while the device is cool, not in power-save, and not in any call.
 *
 * No Android imports: covered by plain JVM unit tests. [HeavyWorkMonitor] supplies live conditions.
 */
object HeavyWorkPolicy {
    /** PowerManager thermal status folded onto Apple's four levels. */
    enum class Heat { NOMINAL, FAIR, SERIOUS, CRITICAL }

    data class Conditions(
        /** A Haven call exists (ringing, connecting, or connected). */
        val havenCall: Boolean = false,
        /** Any other call on the device (the audio mode says IN_CALL / IN_COMMUNICATION). */
        val systemCall: Boolean = false,
        val heat: Heat = Heat.NOMINAL,
        /** Battery Saver. */
        val powerSave: Boolean = false,
        /** A forced suspension and its reason ("" = none) — only the DEBUG `heavy_work_override`
         *  qa op sets it, so the e2e suite can exercise the gate without a real call. */
        val forced: String = "",
    ) {
        /** Stop every deferrable heavy transfer: peer serving, backfill, full-size prefetch, handoff. */
        val suspendHeavyIO: Boolean
            get() = havenCall || systemCall || heat >= Heat.SERIOUS || powerSave || forced.isNotEmpty()

        /** Streaming to a FRIEND additionally needs a fully cool device — at FAIR the relay upload
         *  gets the budget, not peer serving. */
        val peerServingAllowedForFriends: Boolean get() = !suspendHeavyIO && heat < Heat.FAIR

        /** CRITICAL: everything waits, including uploading media you just authored. */
        val pauseEverything: Boolean get() = heat >= Heat.CRITICAL

        val reason: String
            get() = buildList {
                if (havenCall) add("haven-call")
                if (systemCall) add("system-call")
                if (heat >= Heat.FAIR) add("thermal=${heat.name.lowercase()}")
                if (powerSave) add("power-save")
                if (forced.isNotEmpty()) add("forced=$forced")
            }.joinToString(",")
    }

    data class ServeRequest(
        val isOwnDevice: Boolean,
        val isHandoffTarget: Boolean = false,
        /** Confirmed (backup ledger) on a relay another device can read. */
        val onRelay: Boolean,
        /** Queued / in flight in this device's relay upload queue. */
        val uploadPending: Boolean,
        /** The ref's circle has a relay/mailbox the requester can fetch from. */
        val circleHasRelay: Boolean,
        /** Relay hints (frame 32) already sent to this requester for this ref, recently. */
        val hintsAlreadySent: Int,
    )

    sealed class ServeDecision {
        object Stream : ServeDecision()
        object HintRelay : ServeDecision()
        object HintWhenUploaded : ServeDecision()
        data class Decline(val why: String) : ServeDecision()
    }

    const val MAX_RELAY_HINTS = 3
    const val FRESH_RELAY_PATIENCE_MS = 150_000L
    const val TARGETED_ASKS_BEFORE_BROADCAST = 2

    fun decideServe(r: ServeRequest, c: Conditions): ServeDecision {
        if (c.pauseEverything) return ServeDecision.Decline("critical-thermal")
        if (c.suspendHeavyIO) return ServeDecision.Decline("suspended(${c.reason})")
        if (r.isOwnDevice) {
            if (r.uploadPending && !r.isHandoffTarget && r.hintsAlreadySent < MAX_RELAY_HINTS) {
                return ServeDecision.HintWhenUploaded
            }
            return ServeDecision.Stream
        }
        if (r.circleHasRelay && r.hintsAlreadySent < MAX_RELAY_HINTS) {
            if (r.onRelay) return ServeDecision.HintRelay
            if (r.uploadPending) return ServeDecision.HintWhenUploaded
        }
        return if (c.peerServingAllowedForFriends) ServeDecision.Stream
        else ServeDecision.Decline("friend-serving-off(${c.reason.ifEmpty { "relay-first" }})")
    }

    /** Why a friend's ask ended in [ServeDecision.Stream] rather than a hint — QA attribution only
     *  (the e2e `relayfirst` step names the cause of any direct serve). Apple `streamReason` parity. */
    fun streamReason(r: ServeRequest, circleKnown: Boolean): String = when {
        r.isOwnDevice -> "own-device"
        !circleKnown -> "circle-unresolved"
        !r.circleHasRelay -> "circle-has-no-relay"
        r.hintsAlreadySent >= MAX_RELAY_HINTS -> "hints-exhausted"
        !r.onRelay && !r.uploadPending -> "not-on-relay-nor-queued"
        else -> "other"
    }

    /** May a relay miss fall through to a direct peer ask? Small companions (thumb/poster/preview,
     *  ≤32 KB) always may; a FRESH ref in a circle with a relay waits [FRESH_RELAY_PATIENCE_MS]. */
    fun mayDirectAskAfterRelayMiss(
        small: Boolean, circleHasRelay: Boolean, ageMs: Long?, userInitiated: Boolean, c: Conditions,
    ): Boolean {
        if (small) return true
        if (c.suspendHeavyIO) return false
        if (userInitiated) return true
        if (circleHasRelay && ageMs != null && ageMs < FRESH_RELAY_PATIENCE_MS) return false
        return true
    }

    /** Full-size prefetch pauses under suspend; thumbs never do. */
    fun prefetchAllowed(small: Boolean, c: Conditions): Boolean = small || !c.suspendHeavyIO

    /** Which backup jobs may run now: own fresh (priority) uploads continue through a call / power
     *  save / SERIOUS (they spare every future peer serve); backfill waits; CRITICAL stops both. */
    fun backupAllowed(priority: Boolean, c: Conditions): Boolean = when {
        c.pauseEverything -> false
        c.suspendHeavyIO -> priority
        else -> true
    }

    /**
     * May a blob leave this device over the current link (docs/PREVIEW-TIER-DESIGN.md §4.1)? On an
     * ultra-constrained link only satellite-safe media (a preview, or anything already inside the
     * preview budget) crosses — by EVERY path: the backup queue, a forced re-seal answering a
     * friend's media-wanted ask, a relay hint's promoted upload, a resume serve. Only the queue was
     * gated, so a friend's media-wanted ask put a 330 KB original on the relay mid-satellite-pass.
     * Held work is deferred, not dropped: the persisted backup re-runs when the link improves.
     * Apple `HeavyWorkPolicy.mayMoveOverLink` parity.
     */
    fun mayMoveOverLink(ultraConstrained: Boolean, satelliteSafe: Boolean): Boolean =
        !ultraConstrained || satelliteSafe
}
