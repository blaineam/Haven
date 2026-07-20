package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The field failure this encodes: an app-hosted relay on `192.168.4.x` announced that address to
 * members sitting on `10.0.0.x`. HTTP is the PREFERRED media path, so every remote member burned a
 * connect and a timeout per operation on an address that could never work before falling through to
 * iroh. Dropping it here is what makes the in-app relay behave like the CLI relay, which never had
 * the bug because it announces nothing unless told.
 */
class RelayUrlsTest {

    private val onTenDotZero = RelayUrls.prefixes(listOf("10.0.0.7"))

    @Test fun `a private address on a foreign subnet is never tried`() {
        assertFalse(RelayUrls.plausiblyReachable("http://192.168.4.21:8674", onTenDotZero))
        assertFalse(RelayUrls.plausiblyReachable("http://172.16.9.3:8674", onTenDotZero))
        assertFalse(RelayUrls.plausiblyReachable("http://10.9.9.9:8674", onTenDotZero))
    }

    @Test fun `a private address on our own 24 is the fast local path and is kept`() {
        assertTrue(RelayUrls.plausiblyReachable("http://10.0.0.5:8674", onTenDotZero))
        val onLan = RelayUrls.prefixes(listOf("192.168.4.99", "10.0.0.7"))
        assertTrue(RelayUrls.plausiblyReachable("http://192.168.4.21:8674", onLan))
        assertTrue(RelayUrls.plausiblyReachable("http://10.0.0.5:8674", onLan))
    }

    @Test fun `public addresses and hostnames are always worth a try`() {
        assertTrue(RelayUrls.plausiblyReachable("http://203.0.113.9:8674", onTenDotZero))
        assertTrue(RelayUrls.plausiblyReachable("https://relay.example.com", onTenDotZero))
        assertTrue(RelayUrls.plausiblyReachable("https://relay.example.com:8674/", onTenDotZero))
        // 172.x outside 16..31 is public space, not private.
        assertTrue(RelayUrls.plausiblyReachable("http://172.32.0.1:8674", onTenDotZero))
    }

    @Test fun `an unparseable url is not tried`() {
        assertFalse(RelayUrls.plausiblyReachable("not a url", onTenDotZero))
        assertFalse(RelayUrls.plausiblyReachable("", onTenDotZero))
    }

    @Test fun `prefixes ignores anything that is not a dotted quad`() {
        assertEquals(setOf("10.0.0"), RelayUrls.prefixes(listOf("10.0.0.7", "fe80::1", "garbage")))
    }
}
