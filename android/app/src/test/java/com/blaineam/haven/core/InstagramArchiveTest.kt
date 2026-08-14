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

    /** The archive the exact counts below were derived from. Pinned BY NAME on purpose: the test
     *  used to take whatever `instagram-*.zip` in Downloads was newest, so the moment a second,
     *  larger export was downloaded the fixed expectations described a different file and the test
     *  went red without a line of parser code changing. */
    private val validatedArchive = "instagram-helloblainemiller-2026-08-13-aMY9uKNj.zip"

    private fun archive(): File? {
        val explicit = System.getProperty("haven.ig.archive")
        if (explicit != null) return File(explicit).takeIf { it.isFile }
        val downloads = File(System.getProperty("user.home"), "Downloads")
        return downloads.listFiles { f: File -> f.name.startsWith("instagram-") && f.extension == "zip" }
            ?.maxByOrNull { it.lastModified() }
    }

    /** The pinned archive, or null. Only the count assertions need this one specific file. */
    private fun validated(): File? {
        val explicit = System.getProperty("haven.ig.archive")
        if (explicit != null) return File(explicit).takeIf { it.isFile }
        return File(File(System.getProperty("user.home"), "Downloads"), validatedArchive).takeIf { it.isFile }
    }

    /** Holds for ANY export, so a fresh download is still checked: every referenced file resolves,
     *  and carousels expand (media outnumber items). These are the invariants that actually break
     *  an import, and they do not depend on which archive is present. */
    @Test
    fun `any export parses coherently`() {
        val file = archive()
        assumeTrue("no Instagram archive present", file != null)
        val s = InstagramArchive.read(file!!)
        assertEquals("unresolved media references", 0, s.missing.size)
        assertTrue("carousels expand", s.mediaCount > s.items.size)
        // 1e12 ms is 2001, and any Instagram post is later than that; the same instant in SECONDS
        // would be ~1.5e9, three orders of magnitude below. This discriminates the two units, which
        // is what the check is for — the pinned test's tighter 1.6e12 bound describes ITS archive,
        // and a fresh export that reaches further back is not a parser fault.
        assertTrue("timestamps are ms", s.earliest!! > 1_000_000_000_000L)
    }

    @Test
    fun `parses a real export the same way Apple does`() {
        val file = validated()
        assumeTrue("validated archive ($validatedArchive) not present", file != null)

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
