package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Secret (tap-to-reveal, screenshot-protected) message marker — wire-compatible with iOS + desktop. */
class SecretMessagesTest {
    @Test fun `encoded text is secret and decodes back`() {
        val body = SecretMessages.encode("the surprise is Tuesday")
        assertTrue(SecretMessages.isSecret(body))
        assertEquals("the surprise is Tuesday", SecretMessages.text(body))
    }

    @Test fun `wire form is STX followed by the text (iOS and desktop parity)`() {
        assertEquals("\u0002hi", SecretMessages.encode("hi"))
        assertTrue(SecretMessages.isSecret("\u0002from an iPhone"))
    }

    @Test fun `plain messages are untouched`() {
        assertFalse(SecretMessages.isSecret("hello"))
        assertEquals("hello", SecretMessages.text("hello"))
        assertFalse(SecretMessages.isSecret(""))
        // A story caption marker (SOH) is not a secret marker.
        assertFalse(SecretMessages.isSecret("\u0001cap\u0001x"))
    }

    @Test fun `only the leading marker is stripped`() {
        assertEquals("\u0002inner", SecretMessages.text(SecretMessages.encode("\u0002inner")))
        assertEquals("", SecretMessages.text(SecretMessages.encode("")))
    }
}
