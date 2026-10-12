package com.blaineam.haven.core

import com.blaineam.haven.core.InstagramArchive.Failure
import com.blaineam.haven.core.InstagramArchive.Kind
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The export parser against synthetic archives (the real-export test skips when none is on disk). */
class InstagramArchiveSyntheticTest {
    private lateinit var dir: File
    private fun m(uri: String, ts: Long, title: String = "", genre: String? = null) = InstagramFixture.media(uri, ts, title, genre)
    private val bytes = ByteArray(10) { 1 }

    @Before fun setUp() { dir = Files.createTempDirectory("ig-archive").toFile() }
    @After fun tearDown() { dir.deleteRecursively() }

    private fun failure(f: () -> Unit): Failure.Reason {
        try { f() } catch (e: Failure) { return e.kind }
        fail("expected a Failure"); error("unreachable")
    }

    @Test fun posts_stories_and_reels_become_items_sorted_by_time_in_milliseconds() {
        val zip = InstagramFixture.write(dir,
            posts = listOf(InstagramFixture.post(300, "A post", listOf(m("media/p1.jpg", 300)))),
            stories = listOf(m("media/s1.jpg", 100, "story")),
            reels = listOf(listOf(m("media/r1.mp4", 200, "reel"))),
            files = mapOf("media/p1.jpg" to bytes, "media/s1.jpg" to bytes, "media/r1.mp4" to bytes))
        val s = InstagramArchive.read(zip)
        assertEquals(listOf(Kind.STORY, Kind.REEL, Kind.POST), s.items.map { it.kind })
        assertEquals(listOf(100_000L, 200_000L, 300_000L), s.items.map { it.createdAt })
        assertEquals(100_000L, s.earliest); assertEquals(300_000L, s.latest)
        assertEquals(1, s.count(Kind.POST)); assertEquals(1, s.count(Kind.REEL)); assertEquals(1, s.count(Kind.STORY))
        assertEquals(3, s.mediaCount); assertEquals(30L, s.totalBytes); assertTrue(s.missing.isEmpty())
    }

    @Test fun a_carousel_stays_one_post_with_every_album_member_in_order() {
        val zip = InstagramFixture.write(dir,
            posts = listOf(InstagramFixture.post(10, "Album",
                listOf(m("media/a1.jpg", 10), m("media/a2.jpg", 10), m("media/a3.jpg", 10), m("media/a1.jpg", 10)))),
            files = mapOf("media/a1.jpg" to bytes, "media/a2.jpg" to bytes, "media/a3.jpg" to bytes))
        val item = InstagramArchive.read(zip).items.single()
        assertEquals("deduped by uri, album order kept", listOf("media/a1.jpg", "media/a2.jpg", "media/a3.jpg"), item.mediaNames)
    }

    @Test fun album_members_hung_off_a_nested_chain_are_found_too() {
        // Only the cover sits under the top-level media list; photos 2..N hang off a nested dict chain.
        val zip = InstagramFixture.write(dir,
            posts = listOf(InstagramFixture.post(10, "Album", listOf(m("media/a1.jpg", 10)),
                nested = listOf(m("media/a2.jpg", 10), m("media/a3.jpg", 10)))),
            files = mapOf("media/a1.jpg" to bytes, "media/a2.jpg" to bytes, "media/a3.jpg" to bytes))
        val item = InstagramArchive.read(zip).items.single()
        assertEquals(setOf("media/a1.jpg", "media/a2.jpg", "media/a3.jpg"), item.mediaNames.toSet())
        assertEquals(3, item.mediaNames.size)
    }

    @Test fun subtitle_sidecars_are_not_post_media() {
        val zip = InstagramFixture.write(dir,
            posts = listOf(InstagramFixture.post(10, "Clip", listOf(m("media/c.mp4", 10), m("media/c.srt", 10), m("media/c.vtt", 10)))),
            files = mapOf("media/c.mp4" to bytes))
        assertEquals(listOf("media/c.mp4"), InstagramArchive.read(zip).items.single().mediaNames)
    }

    @Test fun drafts_were_never_published_so_they_are_never_imported() {
        val zip = InstagramFixture.write(dir, posts = listOf(
            InstagramFixture.post(10, "Draft", listOf(m("media/d.jpg", 10)), draft = true),
            InstagramFixture.post(20, "Real", listOf(m("media/r.jpg", 20)))),
            files = mapOf("media/d.jpg" to bytes, "media/r.jpg" to bytes))
        assertEquals(listOf("Real"), InstagramArchive.read(zip).items.map { it.body })
    }

    @Test fun a_post_without_a_timestamp_borrows_its_first_media_time_and_title() {
        val zip = InstagramFixture.write(dir, posts = listOf(
            InstagramFixture.post(null, "", listOf(m("media/x.jpg", 77, "from media")))), files = mapOf("media/x.jpg" to bytes))
        val i = InstagramArchive.read(zip).items.single()
        assertEquals(77_000L, i.createdAt); assertEquals("from media", i.body)
    }

    @Test fun posts_with_no_media_or_no_time_are_dropped() {
        val zip = InstagramFixture.write(dir,
            posts = listOf(InstagramFixture.post(10, "empty", emptyList()), InstagramFixture.post(0, "no time", listOf(m("media/n.jpg", 0))),
                InstagramFixture.post(5, "ok", listOf(m("media/ok.jpg", 5)))),
            files = mapOf("media/ok.jpg" to bytes))
        assertEquals(listOf("ok"), InstagramArchive.read(zip).items.map { it.body })
    }

    @Test fun stories_and_reels_missing_a_uri_or_time_are_skipped() {
        val zip = InstagramFixture.write(dir,
            stories = listOf(m("", 10), m("media/no-ts.jpg", 0), m("media/ok.jpg", 9)),
            reels = listOf(listOf(m("", 5), m("media/r-no-ts.mp4", 0), m("media/r.mp4", 8))),
            files = mapOf("media/ok.jpg" to bytes, "media/r.mp4" to bytes))
        assertEquals(listOf("media/r.mp4", "media/ok.jpg"), InstagramArchive.read(zip).items.map { it.mediaNames.single() })
    }

    @Test fun equal_timestamps_are_ordered_by_media_name_so_a_resume_index_means_the_same_thing() {
        val zip = InstagramFixture.write(dir,
            stories = listOf(m("media/b.jpg", 50), m("media/a.jpg", 50), m("media/c.jpg", 50)),
            files = mapOf("media/a.jpg" to bytes, "media/b.jpg" to bytes, "media/c.jpg" to bytes))
        assertEquals(listOf("media/a.jpg", "media/b.jpg", "media/c.jpg"), InstagramArchive.read(zip).items.map { it.mediaNames.single() })
    }

    @Test fun media_the_zip_does_not_contain_is_reported_not_silently_lost() {
        val zip = InstagramFixture.write(dir, stories = listOf(m("media/here.jpg", 10), m("media/gone.jpg", 20)),
            files = mapOf("media/here.jpg" to ByteArray(7)))
        val s = InstagramArchive.read(zip)
        assertEquals(listOf("media/gone.jpg"), s.missing); assertEquals(2, s.mediaCount); assertEquals(7L, s.totalBytes)
    }

    @Test fun the_only_music_signal_is_the_genre_on_a_video() {
        val zip = InstagramFixture.write(dir,
            reels = listOf(listOf(m("media/r.mp4", 10, genre = "Pop"), m("media/q.mp4", 11))),
            files = mapOf("media/r.mp4" to bytes, "media/q.mp4" to bytes))
        assertEquals(listOf("Pop", null), InstagramArchive.read(zip).items.map { it.musicGenre })
    }

    @Test fun an_html_export_is_recognised_so_the_user_is_told_how_to_fix_it() {
        val zip = InstagramFixture.write(dir, extra = mapOf("your_instagram_activity/media/posts_1.html" to "<html/>".toByteArray()))
        assertEquals(Failure.Reason.HTML_EXPORT, failure { InstagramArchive.read(zip) })
    }

    @Test fun a_zip_that_is_neither_json_nor_html_is_unreadable() {
        val zip = InstagramFixture.write(dir, extra = mapOf("readme.txt" to bytes))
        assertEquals(Failure.Reason.UNREADABLE, failure { InstagramArchive.read(zip) })
    }

    @Test fun something_that_is_not_a_zip_at_all_is_unreadable() {
        val notZip = File(dir, "x.zip").also { it.writeText("plain text") }
        assertEquals(Failure.Reason.UNREADABLE, failure { InstagramArchive.read(notZip) })
        assertEquals(Failure.Reason.UNREADABLE, failure { InstagramArchive.read(File(dir, "missing.zip")) })
    }

    @Test fun a_json_export_with_nothing_in_it_has_no_content() {
        val zip = InstagramFixture.write(dir, posts = emptyList(), stories = emptyList())
        assertEquals(Failure.Reason.NO_CONTENT, failure { InstagramArchive.read(zip) })
    }

    @Test fun corrupt_json_files_are_treated_as_absent() {
        val zip = InstagramFixture.write(dir, stories = listOf(m("media/s.jpg", 5)), files = mapOf("media/s.jpg" to bytes),
            extra = mapOf("your_instagram_activity/media/posts.json" to "{not json".toByteArray(),
                "your_instagram_activity/media/reels.json" to "[]".toByteArray()))
        assertEquals(listOf(Kind.STORY), InstagramArchive.read(zip).items.map { it.kind })
    }

    @Test fun captions_double_encoded_as_latin1_are_restored() {
        assertEquals("Peña", InstagramArchive.igText("PeÃ±a"))
        assertEquals("plain ascii", InstagramArchive.igText("plain ascii"))
        assertEquals("", InstagramArchive.igText(null)); assertEquals("", InstagramArchive.igText(""))
        val zip = InstagramFixture.write(dir, stories = listOf(m("media/s.jpg", 5, "cafÃ©")), files = mapOf("media/s.jpg" to bytes))
        assertEquals("café", InstagramArchive.read(zip).items.single().body)
    }

    @Test fun an_empty_summary_has_no_bounds() {
        val s = InstagramArchive.Summary(emptyList(), 0, 0, emptyList())
        assertNull(s.earliest); assertNull(s.latest); assertFalse(s.items.isNotEmpty())
    }
}
