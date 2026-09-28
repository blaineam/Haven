package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Test

class DialOrderTest {
    private val acct = "a".repeat(64)
    private val dev1 = "1".repeat(64)
    private val dev2 = "2".repeat(64)
    private val hint = "b".repeat(64)

    /** Brand-new friend: no roster (engine answers [account]) but an invite hint — dial the hint only. */
    @Test fun newFriendDialsHintOnly() =
        assertEquals(listOf(hint), DialOrder.targets(acct, listOf(acct), listOf(hint)))

    /** Roster known, no hint: devices first, account id kept LAST. */
    @Test fun rosterKeepsAccountLast() =
        assertEquals(listOf(dev1, dev2, acct), DialOrder.targets(acct, listOf(dev1, dev2, acct), emptyList()))

    /** Hints first, then devices; account dropped; case folded + de-duplicated. */
    @Test fun hintsFirstDeduped() =
        assertEquals(listOf(hint, dev1), DialOrder.targets(acct.uppercase(), listOf(dev1, acct, hint.uppercase()), listOf(hint)))

    /** Nothing but the account: it is the only handle there is. */
    @Test fun accountOnlyFallback() =
        assertEquals(listOf(acct), DialOrder.targets(acct, emptyList(), emptyList()))
}
