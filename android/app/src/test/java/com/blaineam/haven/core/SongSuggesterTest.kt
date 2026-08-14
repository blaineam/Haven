package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The DECISIONS the suggester makes, tested without a network or a device.
 *
 * Captions here are verbatim from a real Instagram export — including the ones that produced NO
 * themes on iOS, where NLTagger silently returns nothing. Android never had a tagger to depend on,
 * so this is the same word-splitting path Apple now falls back to, and it should reach the same
 * subjects.
 */
class SongSuggesterTest {

    @Test
    fun `pulls the subject out of real captions`() {
        assertEquals(listOf("christmas", "vinyl"),
                     SongSuggester.captionThemes("Christmas vinyl season"))
        // "Christmas" is a mid-sentence capital and therefore the subject; "Merry" only leads the
        // sentence, so it ranks behind it. Subject first is the point of the whole heuristic.
        assertEquals(listOf("christmas", "merry"),
                     SongSuggester.captionThemes("Merry Christmas Eve Everyone!"))
        assertEquals(listOf("luma", "groomers"),
                     SongSuggester.captionThemes("Luma got all cleaned up at the groomers yesterday and they did such a great job"))
        assertEquals(listOf("condors", "hockey"),
                     SongSuggester.captionThemes("Tonight is fun enjoying the Condors Hockey game with the fam"))
    }

    @Test
    fun `sentence-opening words are not treated as names`() {
        // "Tonight" is capitalised but only because it starts the sentence — and it is bland
        // besides. The subject is what should win.
        val themes = SongSuggester.captionThemes("Tonight is fun enjoying the Condors Hockey game")
        assertTrue("expected the subject, got $themes", themes.contains("condors"))
        assertFalse("bland opener should not win", themes.contains("tonight"))
    }

    @Test
    fun `search terms stay thematic and never encode a date`() {
        val terms = SongSuggester.terms(listOf("christmas"), null, 2023, month = 12)
        assertEquals("the theme alone must come first", "christmas", terms.first())
        // "December 2023" as a term matched songs literally TITLED that on Apple.
        assertTrue("no bare date may be searched", terms.none { it.contains("December 2023") })
        assertTrue("seasonal mood is the fallback", terms.contains("winter"))
    }

    @Test
    fun `explicit tracks are never suggested`() {
        val clean = MusicSearch.Track("Winter", "Two Feet", "", "p", "s", 1000, explicit = false)
        val dirty = MusicSearch.Track("Winter", "Two Feet", "", "p", "s", 1000, explicit = true)
        assertTrue(SongSuggester.isSuitable(clean))
        assertFalse(SongSuggester.isSuitable(dirty))
    }

    @Test
    fun `foreign scripts are rejected, accents are not`() {
        assertTrue("accented Latin must survive",
                   SongSuggester.isLikelyInUsersLanguage("The Mountain Is You Chance Peña"))
        assertTrue(SongSuggester.isLikelyInUsersLanguage("Counting My Blessings Seph Schlueter"))
        assertFalse(SongSuggester.isLikelyInUsersLanguage("夜に駆ける YOASOBI"))
        assertFalse(SongSuggester.isLikelyInUsersLanguage("Подмосковные вечера"))
        assertFalse(SongSuggester.isLikelyInUsersLanguage("아무노래 지코"))
    }
}
