package com.blaineam.haven.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.InetAddress

/**
 * The link preview is the one surface where a peer's message decides what our socket connects to,
 * so these cover the guard rails rather than the rendering: which destinations are refused, and
 * whether the size cap is real.
 *
 * Address predicates are fed literals so nothing here resolves DNS.
 */
class LinkSafetyTest {

    private fun addr(s: String): InetAddress = InetAddress.getByName(s)

    @Test fun `rejects loopback`() {
        assertFalse(LinkSafety.isPubliclyRoutable(addr("127.0.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("127.5.5.5")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("::1")))
    }

    @Test fun `rejects rfc1918 private space`() {
        assertFalse(LinkSafety.isPubliclyRoutable(addr("10.0.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("172.16.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("172.31.255.254")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("192.168.1.1")))
    }

    @Test fun `rejects link local including cloud metadata`() {
        assertFalse(LinkSafety.isPubliclyRoutable(addr("169.254.169.254")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("169.254.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("fe80::1")))
    }

    @Test fun `rejects cgnat`() {
        assertFalse(LinkSafety.isPubliclyRoutable(addr("100.64.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("100.127.255.255")))
        // Just outside the /10 — these are ordinary public addresses and must survive.
        assertTrue(LinkSafety.isPubliclyRoutable(addr("100.63.255.255")))
        assertTrue(LinkSafety.isPubliclyRoutable(addr("100.128.0.1")))
    }

    @Test fun `rejects reserved v4 ranges`() {
        assertFalse(LinkSafety.isPubliclyRoutable(addr("0.0.0.0")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("0.1.2.3")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("192.0.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("198.18.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("198.19.255.255")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("240.0.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("255.255.255.255")))
    }

    @Test fun `rejects ipv6 unique local`() {
        assertFalse(LinkSafety.isPubliclyRoutable(addr("fc00::1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("fd12:3456::1")))
    }

    @Test fun `rejects multicast`() {
        assertFalse(LinkSafety.isPubliclyRoutable(addr("224.0.0.1")))
        assertFalse(LinkSafety.isPubliclyRoutable(addr("ff02::1")))
    }

    @Test fun `allows ordinary public addresses`() {
        assertTrue(LinkSafety.isPubliclyRoutable(addr("1.1.1.1")))
        assertTrue(LinkSafety.isPubliclyRoutable(addr("8.8.8.8")))
        assertTrue(LinkSafety.isPubliclyRoutable(addr("93.184.216.34")))
        assertTrue(LinkSafety.isPubliclyRoutable(addr("2606:4700:4700::1111")))
    }

    @Test fun `syntax gate takes only http and https with a host`() {
        assertNull(LinkSafety.vetSyntax("file:///etc/passwd"))
        assertNull(LinkSafety.vetSyntax("ftp://example.com/x"))
        assertNull(LinkSafety.vetSyntax("not a url"))
        assertEquals("example.com", LinkSafety.vetSyntax("https://example.com/x")?.host)
        assertEquals("example.com", LinkSafety.vetSyntax("http://example.com")?.host)
    }

    @Test fun `read cap stops at the ceiling rather than truncating afterwards`() {
        val body = ByteArray(1024) { 'a'.code.toByte() }
        assertEquals(100, LinkSafety.readCapped(ByteArrayInputStream(body), 100).size)
        assertEquals(1024, LinkSafety.readCapped(ByteArrayInputStream(body), 4096).size)
    }

    @Test fun `read cap survives an endless stream`() {
        // The regression this guards: readBytes() on this never returns. readCapped must stop at the
        // cap having pulled exactly the cap, not "eventually, once the response ends".
        var served = 0
        val endless = object : InputStream() {
            override fun read(): Int { served++; return 'x'.code }
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                for (i in 0 until len) b[off + i] = 'x'.code.toByte()
                served += len
                return len
            }
        }
        val out = LinkSafety.readCapped(endless, 8192)
        assertEquals(8192, out.size)
        assertEquals(8192, served)
    }

    @Test fun `read cap preserves content exactly`() {
        val body = "hello world".toByteArray()
        assertArrayEquals(body, LinkSafety.readCapped(ByteArrayInputStream(body), 1024))
        assertArrayEquals("hello".toByteArray(), LinkSafety.readCapped(ByteArrayInputStream(body), 5))
    }
}
