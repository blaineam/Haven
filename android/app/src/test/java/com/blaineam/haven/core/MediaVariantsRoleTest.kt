package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The relay-first serve resolves a requested blob to its circle through [MediaVariants.role].
 * Thumbs and previews are named ONLY inside their markers — `media.contains` missed them, the serve
 * found no circle, and streamed them to friends while the relay held them. Apple parity
 * (MediaVariantsTests.testRoleResolvesCompanionsNamedOnlyInsideMarkers).
 */
class MediaVariantsRoleTest {
    private val media = MediaVariants.composeVideoMedia("img_poster", "vid_opt", "vid_orig") + listOf(
        MediaVariants.thumbMarker("img_photo", "img_thumb"),
        MediaVariants.previewMarker("img_photo", "img_prev"),
        "img_photo",
    )

    @Test fun companions_resolve_to_their_kind() {
        assertFalse("precondition: the thumb is never listed bare", "img_thumb" in media)
        assertEquals("thumb", MediaVariants.role("img_thumb", media))
        assertEquals("preview", MediaVariants.role("img_prev", media))
        assertEquals("poster", MediaVariants.role("img_poster", media))
        assertEquals("original", MediaVariants.role("vid_orig", media))
    }

    @Test fun bare_content_and_strangers() {
        assertEquals("content", MediaVariants.role("vid_opt", media))
        assertEquals("content", MediaVariants.role("img_photo", media))
        assertNull(MediaVariants.role("img_elsewhere", media))
        assertNull(MediaVariants.role("", media))
    }
}
