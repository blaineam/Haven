package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rule that repairs an archive imported twice — the SAME rule iOS applies, because both sweep
 * the same circle and a disagreement would have one device withdrawing posts the other keeps.
 *
 * Mirrors `apple/HavenLogicTests/PostDedupeTests.swift` case for case, including the two that were
 * found the hard way on a real device: media refs change on re-import, and a post's item count is
 * not stable when poster generation fails.
 */
class PostDedupeTest {

    private fun post(id: String, at: ULong, body: String, n: Int = 1, hash: ULong? = null) =
        PostDedupe.Candidate(id = id, createdAt = at, body = body, mediaCount = n, mediaHash = hash)

    @Test
    fun `the same archive imported twice is deduplicated`() {
        val posts = listOf(
            post("a1", 1_600_000_000_000uL, "Sunset at the lake"),
            post("a2", 1_600_000_086_000uL, "Coffee"),
            post("b1", 1_600_000_000_000uL, "Sunset at the lake"),
            post("b2", 1_600_000_086_000uL, "Coffee"),
        )
        assertEquals(listOf("b1", "b2"), PostDedupe.duplicates(posts))
    }

    @Test
    fun `three imports leave one`() {
        val posts = (0..2).map { post("run$it", 1_600_000_000_000uL, "Same post") }
        assertEquals(listOf("run1", "run2"), PostDedupe.duplicates(posts))
    }

    @Test
    fun `same second different captions are not merged`() {
        val posts = listOf(
            post("x", 1_600_000_000_000uL, "First"),
            post("y", 1_600_000_000_000uL, "Second"),
        )
        assertTrue(PostDedupe.duplicates(posts).isEmpty())
    }

    @Test
    fun `caption comparison ignores whitespace and case`() {
        val posts = listOf(
            post("a", 1_600_000_000_000uL, "Sunset  at   the lake"),
            post("b", 1_600_000_000_000uL, "  sunset at the lake  "),
        )
        assertEquals(listOf("b"), PostDedupe.duplicates(posts))
    }

    @Test
    fun `similar but different captions are not merged`() {
        val posts = listOf(
            post("a", 1_600_000_000_000uL, "Day 1 at the lake"),
            post("b", 1_600_000_000_000uL, "Day 2 at the lake"),
        )
        assertTrue(PostDedupe.duplicates(posts).isEmpty())
    }

    @Test
    fun `text only posts are never swept`() {
        val posts = listOf(
            post("a", 1_600_000_000_000uL, "gm", n = 0),
            post("b", 1_600_000_000_000uL, "gm", n = 0),
        )
        assertTrue(PostDedupe.duplicates(posts).isEmpty())
    }

    @Test
    fun `an ordinary feed is untouched`() {
        val posts = (0 until 50).map {
            post("p$it", 1_600_000_000_000uL + (it * 60_000).toULong(), "post $it")
        }
        assertTrue(PostDedupe.duplicates(posts).isEmpty())
    }

    // --- Visual confirmation -------------------------------------------------

    /** Instagram exports capture time in SECONDS, so a burst shares a bucket. The pictures decide. */
    @Test
    fun `same second different pictures are not merged even with no caption`() {
        val posts = listOf(
            post("a", 1_600_000_000_000uL, "", hash = 0uL),
            post("b", 1_600_000_000_000uL, "", hash = ULong.MAX_VALUE),
        )
        assertTrue(PostDedupe.duplicates(posts).isEmpty())
    }

    @Test
    fun `a re-encoded copy is still caught`() {
        val posts = listOf(
            post("first", 1_600_000_000_000uL, "Lake", hash = 0x0F0F0F0F0F0F0F0FuL),
            post("reimport", 1_600_000_000_000uL, "Lake", hash = 0x0F0F0F0F0F0F0F0BuL),
        )
        assertEquals(listOf("reimport"), PostDedupe.duplicates(posts))
    }

    @Test
    fun `identical captions do not override different pictures`() {
        val posts = listOf(
            post("a", 1_600_000_000_000uL, "Same caption", hash = 0uL),
            post("b", 1_600_000_000_000uL, "Same caption", hash = ULong.MAX_VALUE),
        )
        assertTrue(PostDedupe.duplicates(posts).isEmpty())
    }

    /** The bug that let most duplicates through: a poster that failed to generate changes the count. */
    @Test
    fun `a poster that failed to generate does not hide the duplicate`() {
        val posts = listOf(
            post("first", 1_600_000_000_000uL, "", n = 2, hash = 0x0F0F0F0F0F0F0F0FuL),
            post("reimport", 1_600_000_000_000uL, "", n = 1, hash = 0x0F0F0F0F0F0F0F0FuL),
        )
        assertEquals(listOf("reimport"), PostDedupe.duplicates(posts))
    }

    @Test
    fun `without hashes the count must agree`() {
        val posts = listOf(
            post("a", 1_600_000_000_000uL, "trip", n = 1),
            post("b", 1_600_000_000_000uL, "trip", n = 4),
        )
        assertTrue(PostDedupe.duplicates(posts).isEmpty())
    }

    // --- The hash itself -----------------------------------------------------

    @Test
    fun `dHash is stable and distinguishes structure`() {
        val gradient = IntArray(PerceptualHash.WIDTH * PerceptualHash.HEIGHT) { it * 3 % 256 }
        val reversed = IntArray(gradient.size) { 255 - gradient[it] }
        val a = PerceptualHash.dHashFromGray(gradient)!!
        val b = PerceptualHash.dHashFromGray(gradient)!!
        val c = PerceptualHash.dHashFromGray(reversed)!!
        assertEquals(a, b)
        assertEquals(0, PerceptualHash.distance(a, b))
        assertTrue(PerceptualHash.distance(a, c) > PerceptualHash.DUPLICATE_THRESHOLD)
    }
}
