package com.blaineam.haven.core

/**
 * A link grant (frame 29) that was issued, kept so it can be sent again.
 *
 * The grant goes out once, when the owner confirms. If it is lost on the way (the new device
 * reloading, either side changing network, a dropped connection) the new device keeps asking with
 * the same request, and a ticket that has been used answers nothing. So the primary remembers what
 * it issued and, for the ticket's remaining life, repeats it: to the device it was issued for and
 * to no other. Nothing new is signed and no confirmation is skipped. The owner already approved
 * exactly this device, and these are the bytes they approved.
 *
 * Same rule as the desktop engine (`EnrollAnswer::GrantAgain`) and iOS `IssuedEnrollGrant`.
 */
class IssuedEnrollGrant(
    val secret: ByteArray,
    val deviceHex: String,
    val grant: ByteArray,
    val issuedAt: Long,
) {
    /**
     * The grant to send again, if [request] is a genuine request under the same ticket, from the
     * same device, while the ticket would still have been live; null for anything else.
     * [verify] checks the request against the ticket secret and returns the asking device's
     * transport id (hex), or null when it does not verify.
     */
    fun repeatFor(request: ByteArray, now: Long, verify: (secret: ByteArray, wire: ByteArray, now: Long) -> String?): ByteArray? {
        if (now < issuedAt || now - issuedAt >= TTL_SECS) return null
        val asking = verify(secret, request, now) ?: return null
        return if (asking.equals(deviceHex, ignoreCase = true)) grant else null
    }

    companion object {
        const val TTL_SECS = 600L
    }
}
