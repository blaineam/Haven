package com.blaineam.haven.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The cross-platform story-caption wire codec (identical to iOS StoryCaption.swift and the desktop
 * UI): `\u0001color,font,style,x,y,size,mediaScale,offX,offY[,rotation]\u0001text`.
 */
class StoryCaptionsTest {
    private val eps = 1e-3f

    @Test fun `encode then decode round trips every field`() {
        val body = StoryCaptions.encode("Hello", 3, 2, StoryCaptions.CapStyle.NEON, 0.25f, 0.75f, 1.5f,
            mediaScale = 0.8f, mediaOffX = -0.1f, mediaOffY = 0.2f, mediaRotation = 0.1234f)
        val d = StoryCaptions.decode(body)
        assertEquals("Hello", d.text)
        assertEquals(3, d.spec.colorIdx)
        assertEquals(2, d.spec.fontIdx)
        assertEquals(StoryCaptions.CapStyle.NEON, d.spec.style)
        assertEquals(0.25f, d.spec.x, eps); assertEquals(0.75f, d.spec.y, eps); assertEquals(1.5f, d.spec.size, eps)
        assertEquals(0.8f, d.spec.mediaScale, eps); assertEquals(-0.1f, d.spec.mediaOffX, eps)
        assertEquals(0.2f, d.spec.mediaOffY, eps); assertEquals(0.1234f, d.spec.mediaRotation, 1e-4f)
    }

    @Test fun `wire format is locale independent and fixed precision`() {
        val prev = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY)   // decimal comma would break every other platform
            assertEquals("\u00011,0,1,0.500,0.500,1.000,1.000,0.0000,0.0000,0.0000\u0001Hi",
                StoryCaptions.encode(" Hi ", 1, 0, StoryCaptions.CapStyle.GLOW, 0.5f, 0.5f, 1f))
        } finally { java.util.Locale.setDefault(prev) }
    }

    @Test fun `empty caption without framing encodes to nothing, framing alone still encodes`() {
        assertEquals("", StoryCaptions.encode("  ", 0, 0, StoryCaptions.CapStyle.GLOW, 0.5f, 0.5f, 1f))
        val framed = StoryCaptions.encode("", 0, 0, StoryCaptions.CapStyle.GLOW, 0.5f, 0.5f, 1f, mediaScale = 0.9f)
        assertEquals(0.9f, StoryCaptions.decode(framed).spec.mediaScale, eps)
        assertEquals("", StoryCaptions.decode(framed).text)
    }

    @Test fun `plain bodies and malformed prefixes decode as text`() {
        assertEquals("just text", StoryCaptions.decode("just text").text)
        assertEquals(StoryCaptions.Spec(), StoryCaptions.decode("just text").spec)
        assertEquals("no closing marker", StoryCaptions.decode("\u0001no closing marker").text)
    }

    @Test fun `legacy six-field bodies map the highlight bit and default the media framing`() {
        val hi = StoryCaptions.decode("\u00012,1,1,0.1,0.2,1.0\u0001old")
        assertEquals(StoryCaptions.CapStyle.HIGHLIGHT, hi.spec.style)
        assertEquals(1f, hi.spec.mediaScale, eps)
        assertEquals(0f, hi.spec.mediaRotation, eps)
        val plain = StoryCaptions.decode("\u00012,1,0,0.1,0.2,1.0\u0001old")
        assertEquals(StoryCaptions.CapStyle.GLOW, plain.spec.style)
    }

    @Test fun `nine-field bodies from older clients decode with zero rotation`() {
        val d = StoryCaptions.decode("\u00010,0,2,0.5,0.5,1.0,1.2,0.0,0.0\u0001x")
        assertEquals(StoryCaptions.CapStyle.SHADOW, d.spec.style)
        assertEquals(1.2f, d.spec.mediaScale, eps)
        assertEquals(0f, d.spec.mediaRotation, eps)
    }

    @Test fun `out of range indices are clamped, never crash`() {
        assertEquals(StoryCaptions.colors.last(), StoryCaptions.color(99))
        assertEquals(StoryCaptions.colors.first(), StoryCaptions.color(-5))
        StoryCaptions.fontFamily(42); StoryCaptions.fontWeight(-1)
        assertEquals(androidx.compose.ui.graphics.Color.Black, StoryCaptions.highlightTextColor(0))
        assertEquals(androidx.compose.ui.graphics.Color.White, StoryCaptions.highlightTextColor(1))
    }
}
