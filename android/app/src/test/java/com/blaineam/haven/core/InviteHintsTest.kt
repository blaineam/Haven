package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Device-id dial hints on invite links. A freshly added internet friend is unreachable until a dial
 * hint works (the roster-bootstrap deadlock), and the hint must stay invisible to OLD parsers that
 * only read the `#` fragment. The golden vector is shared with apple/HavenLogicTests/InviteHintsTests
 * so a link minted on one platform is read identically on the other.
 */
class InviteHintsTest {
    private val a = "a".repeat(64)
    private val b = "0123456789abcdef".repeat(4)
    private val link = "haven://u/abcd#VERIFY"

    @Test fun `golden vector shared with iOS`() {
        assertEquals("haven://u/abcd?d=$a,$b#VERIFY", InviteHints.embed(link, listOf(a, b)))
    }

    @Test fun `embed then extract round trips and keeps the fragment intact`() {
        val out = InviteHints.embed(link, listOf(a, b))
        assertEquals(listOf(a, b), InviteHints.extract(out))
        assertTrue(out.endsWith("#VERIFY"))
        assertEquals("the fragment old parsers read is unchanged", link.substringAfter('#'), out.substringAfter('#'))
    }

    @Test fun `embed caps at four hints and drops malformed ids`() {
        val ids = (0 until 6).map { it.toString().repeat(64) } + "short"
        val out = InviteHints.embed(link, ids)
        assertEquals(InviteHints.MAX_HINTS, InviteHints.extract(out).size)
        assertTrue(!out.contains("short"))
    }

    @Test fun `embed leaves links it cannot safely extend unchanged`() {
        assertEquals(link, InviteHints.embed(link, emptyList()))
        assertEquals(link, InviteHints.embed(link, listOf("nothex")))
        assertEquals("haven://u/abcd", InviteHints.embed("haven://u/abcd", listOf(a)))           // no fragment
        assertEquals("haven://u/x?t=1#V", InviteHints.embed("haven://u/x?t=1#V", listOf(a)))     // already a query
    }

    @Test fun `extract lowercases, filters non-hex and ignores a question mark inside the fragment`() {
        assertEquals(listOf(a), InviteHints.extract("haven://u/x?d=${a.uppercase()},zz,${"g".repeat(64)}#V"))
        assertEquals(emptyList<String>(), InviteHints.extract("haven://u/x#V?d=$a"))
        assertEquals(emptyList<String>(), InviteHints.extract("haven://u/x#V"))
        assertEquals(listOf(b), InviteHints.extract("https://example.com/u/x?t=abc&d=$b#V"))
    }
}
