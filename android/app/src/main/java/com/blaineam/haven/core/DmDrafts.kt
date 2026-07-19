package com.blaineam.haven.core

import androidx.compose.runtime.mutableStateOf

/**
 * A DM composer draft handed over from somewhere else in the app, plus which thread to open next.
 * Mirrors iOS `DMDraftStore` (apple/HavenApp/Messages.swift).
 *
 * "Message the author" from a post used to start the DM, SEND the post's media immediately, and
 * switch the CIRCLE — so it published something the user hadn't written yet and dropped them into
 * the feed layout instead of their conversation. Referencing a post is the START of a message, not
 * one: the thread opens with the post already referenced and the cursor waiting, and the words stay
 * the user's.
 *
 * The reference is the post's LINK rather than its media: a draft that re-seals a whole video into
 * the DM circle does that work before the user has decided to send anything, and the link opens the
 * real post (with its media) for anyone in the circle.
 *
 * Deliberately transient and device-local — a half-staged reference is not worth persisting, let
 * alone self-syncing to the user's other devices, so there is no SharedPreferences backing here.
 */
object DmDrafts {
    /** Thread the app should open next, if any — consumed by MessagesScreen (Compose state so the
     *  Messages tab recomposes the moment a draft is staged from another tab). */
    val openThread = mutableStateOf<String?>(null)

    private val drafts = HashMap<String, String>()

    /** Stage [text] into [circleId]'s composer and ask the app to open that thread. */
    fun stage(circleId: String, text: String) {
        if (circleId.isEmpty() || text.isBlank()) return
        drafts[circleId] = text
        openThread.value = circleId
    }

    /** Take the staged draft for a thread (once) — the composer owns the text from then on. */
    fun takeDraft(circleId: String): String? = drafts.remove(circleId)

    /** Take the "open this thread next" signal (once). */
    fun consumeOpenThread(): String? = openThread.value.also { openThread.value = null }
}
