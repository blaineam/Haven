package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A link grant is sent once. If it is lost, the new device asks again with the same request, and
 * the primary must repeat the grant to that device and to no other. Before this a used ticket
 * answered nothing and a lost grant stranded the new device on "Linking…" for good.
 */
class IssuedEnrollGrantTest {
    private val secret = ByteArray(32) { 7 }
    private val grant = byteArrayOf(1, 2, 3, 4)
    private val mine = "ab".repeat(32)
    private val theirs = "cd".repeat(32)
    private val issued = IssuedEnrollGrant(secret, mine, grant, issuedAt = 1_000)

    /** A verifier that accepts a request only under the right secret and names who is asking. */
    private fun asking(deviceHex: String?) = { s: ByteArray, _: ByteArray, _: Long -> if (s.contentEquals(secret)) deviceHex else null }

    @Test fun the_approved_device_asking_again_is_sent_the_same_grant() {
        assertArrayEquals(grant, issued.repeatFor(byteArrayOf(9), 1_030, asking(mine)))
        assertArrayEquals(grant, issued.repeatFor(byteArrayOf(9), 1_030, asking(mine.uppercase())))
    }

    @Test fun another_device_under_the_same_ticket_gets_nothing() {
        assertNull(issued.repeatFor(byteArrayOf(9), 1_030, asking(theirs)))
    }

    @Test fun a_request_that_does_not_verify_gets_nothing() {
        assertNull(issued.repeatFor(byteArrayOf(9), 1_030, asking(null)))
    }

    @Test fun nothing_is_repeated_once_the_ticket_would_have_expired_or_before_it_existed() {
        assertNull(issued.repeatFor(byteArrayOf(9), 1_000 + IssuedEnrollGrant.TTL_SECS, asking(mine)))
        assertNull(issued.repeatFor(byteArrayOf(9), 999, asking(mine)))
        assertArrayEquals(grant, issued.repeatFor(byteArrayOf(9), 1_000 + IssuedEnrollGrant.TTL_SECS - 1, asking(mine)))
    }
}
