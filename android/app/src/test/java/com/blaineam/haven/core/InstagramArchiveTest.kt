package com.blaineam.haven.core

import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/**
 * Parses a REAL Instagram export and checks the numbers against the Apple implementation.
 *
 * The archive is a local file (they are over a gigabyte and cannot be committed), so the test skips
 * itself when it is absent — useful on a machine that has one, harmless in CI. Point it elsewhere
 * with `-Dhaven.ig.archive=/path/to.zip`.
 *
 * The expectations are not invented: they are what the Swift parser produces for the same file, so
 * this fails if the two platforms ever disagree about what an archive contains.
 */
class InstagramArchiveTest {

    private fun archive(): File? {
        val explicit = System.getProperty("haven.ig.archive")
        if (explicit != null) return File(explicit).takeIf { it.isFile }
        val downloads = File(System.getProperty("user.home"), "Downloads")
        return downloads.listFiles { f: File -> f.name.startsWith("instagram-") && f.extension == "zip" }
            ?.maxByOrNull { it.lastModified() }
    }

    @Test
    fun `parses a real export the same way Apple does`() {
        val file = archive()
        assumeTrue("no Instagram archive present", file != null)

        val s = InstagramArchive.read(file!!)

        // Every referenced file must resolve, or the import would publish posts whose media can
        // never arrive.
        assertEquals("unresolved media references", 0, s.missing.size)

        assertEquals("posts", 203, s.count(InstagramArchive.Kind.POST))
        assertEquals("reels", 85, s.count(InstagramArchive.Kind.REEL))
        assertEquals("stories", 84, s.count(InstagramArchive.Kind.STORY))
        assertEquals("items", 372, s.items.size)

        // 1129 is the number that proves carousels are not truncated: only the album COVER sits
        // under the top-level "Media" label, so a parser that misses the nested chain reports 372.
        assertEquals("media files", 1129, s.mediaCount)

        assertTrue("captions", s.items.count { it.body.isNotBlank() } >= 300)
        assertTrue("music genres", s.items.count { it.musicGenre != null } >= 40)

        // Timestamps are SECONDS in the export and milliseconds in Haven.
        assertTrue("earliest is ms", s.earliest!! > 1_600_000_000_000L)
    }

    @Test
    fun `carousels stay a single post`() {
        val file = archive()
        assumeTrue("no Instagram archive present", file != null)
        val s = InstagramArchive.read(file!!)
        val biggest = s.items.maxByOrNull { it.mediaNames.size }!!
        assertTrue("largest album should hold many photos, got ${biggest.mediaNames.size}",
                   biggest.mediaNames.size >= 20)
    }

    @Test
    fun `double-encoded captions are repaired`() {
        // Exactly how "Peña" arrives in a real export.
        assertEquals("Peña", InstagramArchive.igText("PeÃ±a"))
        // Text that is already clean must survive untouched.
        assertEquals("Merry Christmas", InstagramArchive.igText("Merry Christmas"))
        assertEquals("", InstagramArchive.igText(null))
    }
}
