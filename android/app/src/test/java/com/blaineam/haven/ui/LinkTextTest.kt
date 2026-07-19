package com.blaineam.haven.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The previewed-url strip. Pinned down because the strip and the preview card must pick the SAME
 * url out of a body — they used to use two separate regexes, and a strip that disagrees with the
 * card by a character leaves a shard of URL sitting in the sentence.
 */
class LinkTextTest {
    private val post = "https://wemiller.com/apps/haven/open/#p/abc.def"

    @Test fun stripsOnlyThePreviewedUrl() {
        // The SECOND link gets no card of its own, so it has to survive.
        assertEquals(
            "look at this and also https://example.com/x",
            bodyWithoutPreviewedUrl("look at this $post and also https://example.com/x"),
        )
    }

    @Test fun linkOnlyBodyBecomesEmpty() {
        // The surface then renders just the card.
        assertEquals("", bodyWithoutPreviewedUrl(post))
        assertEquals("", bodyWithoutPreviewedUrl("  $post  "))
    }

    @Test fun tidiesTheWhitespaceTheRemovalLeaves() {
        assertEquals("what do you think?", bodyWithoutPreviewedUrl("what do you $post think?"))
        assertEquals("hey\n\nthoughts?", bodyWithoutPreviewedUrl("hey\n\n$post\n\nthoughts?"))
    }

    @Test fun bodyWithoutAnyUrlIsUntouched() {
        assertEquals("no links  here\n\n\nat all", bodyWithoutPreviewedUrl("no links  here\n\n\nat all"))
    }

    @Test fun stripAgreesWithTheCardsUrl() {
        val body = "see $post now"
        val url = firstUrl(body)
        assertEquals(post, url)
        assertEquals("see now", bodyWithoutPreviewedUrl(body))
    }
}
