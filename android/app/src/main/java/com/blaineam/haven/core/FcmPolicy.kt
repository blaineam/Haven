package com.blaineam.haven.core

/**
 * The pure rules of the optional FCM wake-up, kept free of Firebase so they are unit-tested.
 *
 * The push is a CONTENT-FREE doorbell: the worker sends `w=1` (and `c=1` for a call) and nothing else;
 * the app then pulls and decrypts the real message from its relay. Google sees timing and the device
 * token — the same as Apple sees for APNs — and never a byte of content.
 */
object FcmPolicy {
    const val PREF = "haven.fcm"
    const val KEY = "enabled"

    /** What the registration signature covers. The prefix keeps this message space disjoint from an
     *  APNs registration and from a /flag, so none of those signatures can be replayed as this one. */
    fun registrationMaterial(token: String) = "fcm-v1:$token"

    /** Firebase is initialised only when the user opted in, the build carries the owner's Firebase
     *  values, and Google Play services exist on the phone (no-op on GrapheneOS / de-Googled ROMs). */
    fun shouldRun(optedIn: Boolean, configured: Boolean, playServices: Boolean) =
        optedIn && configured && playServices

    fun configured(projectId: String, appId: String, apiKey: String, senderId: String) =
        projectId.isNotBlank() && appId.isNotBlank() && apiKey.isNotBlank() && senderId.isNotBlank()

    fun isWake(data: Map<String, String>) = data["w"] == "1"
    fun isCall(data: Map<String, String>) = data["c"] == "1"
}
