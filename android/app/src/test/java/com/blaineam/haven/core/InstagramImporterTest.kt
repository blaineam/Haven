package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The DECISIONS the importer makes, tested without a device, an archive, or a network.
 *
 * Every case here is one that cost a real bug on Apple. The staging pipeline they drive (zip read →
 * downscale/transcode → seal → publish) needs MediaCodec and the engine and is covered on a device;
 * what is testable off-device is the part that decides WHAT gets published, IN WHAT ORDER, and WHERE
 * a killed import picks back up — which is also the part that has actually been wrong.
 */
class InstagramImporterTest {

    private fun item(
        kind: InstagramArchive.Kind,
        atSeconds: Long,
        media: List<String> = listOf("media/posts/$atSeconds.jpg"),
        body: String = "",
        genre: String? = null,
    ) = InstagramArchive.Item(kind, atSeconds * 1000, body, media, genre)

    /** Chronological, the way `InstagramArchive.read` returns them. */
    private val chronological = listOf(
        item(InstagramArchive.Kind.POST, 1_600_000_000),
        item(InstagramArchive.Kind.STORY, 1_610_000_000),
        item(InstagramArchive.Kind.REEL, 1_620_000_000),
        item(InstagramArchive.Kind.POST, 1_630_000_000, media = listOf("a.jpg", "b.jpg", "c.jpg")),
    )

    // ---- Ordering: the one that made the feed jump -----------------------------------------------

    @Test
    fun `imports newest first`() {
        // The feed is newest-first (haven-p2p map_feed ends `order.iter().rev()`), so an
        // oldest-first import inserts every post ABOVE what the reader is looking at. Reversed, each
        // post is older than the last and lands BELOW them, where it costs them nothing.
        val ordered = InstagramImporter.orderedItems(chronological, includeStories = false)
        val times = ordered.map { it.createdAt }
        assertEquals(times.sortedDescending(), times)
        assertEquals(1_630_000_000_000L, ordered.first().createdAt)
    }

    @Test
    fun `stories are excluded by default and included only when asked for`() {
        // Instagram auto-archives EVERY story, and the export marks none of them as a Highlight — so
        // the default has to be off or years of deliberately-expired stories come back.
        val without = InstagramImporter.orderedItems(chronological, includeStories = false)
        assertEquals(3, without.size)
        assertTrue(without.none { it.kind == InstagramArchive.Kind.STORY })

        val with = InstagramImporter.orderedItems(chronological, includeStories = true)
        assertEquals(4, with.size)
        assertEquals(1, with.count { it.kind == InstagramArchive.Kind.STORY })
        // Still newest-first with stories mixed in.
        assertEquals(with.map { it.createdAt }.sortedDescending(), with.map { it.createdAt })
    }

    @Test
    fun `ordering never touches the source list`() {
        // `run` is called more than once against one parsed summary (preview, then a resume), so a
        // reversal that mutated the summary would silently flip the order on the second pass.
        val copy = chronological.toList()
        InstagramImporter.orderedItems(chronological, includeStories = true)
        InstagramImporter.orderedItems(chronological, includeStories = false)
        assertEquals(copy, chronological)
    }

    @Test
    fun `a carousel stays one item`() {
        // Not "does the parser find all three" (InstagramArchiveTest owns that) — that the RUNNER
        // never splits an album, because splitting it is what would turn one post into three.
        val ordered = InstagramImporter.orderedItems(chronological, includeStories = false)
        val carousel = ordered.first { it.mediaNames.size > 1 }
        assertEquals(listOf("a.jpg", "b.jpg", "c.jpg"), carousel.mediaNames)
        assertEquals(1, ordered.count { it.mediaNames.contains("a.jpg") })
    }

    // ---- Resume: the index has to mean the same thing on both runs -------------------------------

    @Test
    fun `resume starts where the checkpoint stopped`() {
        val p = InstagramImporter.Pending("content://x", "circle", false, false, done = 7)
        // `done` counts items FINISHED, so it is also the index of the next one — off by one here
        // either re-imports the last post or drops one.
        assertEquals(7, InstagramImporter.resumeStart(p, itemCount = 20))
    }

    @Test
    fun `a finished checkpoint resumes nothing`() {
        val p = InstagramImporter.Pending("content://x", "circle", false, false, done = 20)
        assertNull(InstagramImporter.resumeStart(p, itemCount = 20))
        // A checkpoint recorded against a LARGER selection (stories were on, then off) must not run
        // off the end of the list.
        assertNull(InstagramImporter.resumeStart(p.copy(done = 40), itemCount = 20))
        assertNull(InstagramImporter.resumeStart(p.copy(done = 0), itemCount = 0))
    }

    @Test
    fun `a negative or fresh checkpoint starts at zero`() {
        val p = InstagramImporter.Pending("content://x", "circle", false, false, done = 0)
        assertEquals(0, InstagramImporter.resumeStart(p, itemCount = 5))
        assertEquals(0, InstagramImporter.resumeStart(p.copy(done = -3), itemCount = 5))
    }

    @Test
    fun `the checkpoint round-trips`() {
        val p = InstagramImporter.Pending(
            uri = "content://com.android.providers.downloads.documents/document/42",
            circleId = "circle-abc", includeStories = true, matchSongs = true, done = 113)
        assertEquals(p, InstagramImporter.decodePending(InstagramImporter.encodePending(p)))
    }

    @Test
    fun `a checkpoint written before song matching existed still decodes`() {
        // Same reason Apple defaults the field: a record from the previous build must resume rather
        // than be thrown away, which would restart a 372-item import from zero.
        val legacy = """{"uri":"content://x","circleId":"c","includeStories":false,"done":9}"""
        val p = InstagramImporter.decodePending(legacy)
        assertNotNull(p)
        assertEquals(9, p!!.done)
        assertFalse(p.matchSongs)
    }

    @Test
    fun `an absent or unusable checkpoint is simply nothing`() {
        // Resume must be SILENT when there is nothing to resume — this runs on every cold start.
        assertNull(InstagramImporter.decodePending(null))
        assertNull(InstagramImporter.decodePending(""))
        assertNull(InstagramImporter.decodePending("not json"))
        // A record with no archive to point at is not a resumable job.
        assertNull(InstagramImporter.decodePending("""{"circleId":"c","done":4}"""))
    }

    // ---- Songs: only into silence ----------------------------------------------------------------

    @Test
    fun `songs are suggested only for silent posts and only when asked for`() {
        // A reel's soundtrack is baked into the video and is what the user actually chose; layering a
        // guess over it is worse than adding nothing.
        assertTrue(InstagramImporter.wantsSuggestedSong(matchSongs = true, hasAudio = false))
        assertFalse(InstagramImporter.wantsSuggestedSong(matchSongs = true, hasAudio = true))
        // Off by default: the suggestion is a GUESS, so it is asked for, never assumed.
        assertFalse(InstagramImporter.wantsSuggestedSong(matchSongs = false, hasAudio = false))
        assertFalse(InstagramImporter.wantsSuggestedSong(matchSongs = false, hasAudio = true))
    }

    @Test
    fun `every attached song is remembered so the next post gets a different one`() {
        // The importer's half of the contract with SongSuggester.exclude. Without the accumulation
        // one search term per year meant ONE song across every silent post of that year.
        val used = HashSet<String>()
        InstagramImporter.rememberUsedSong(used, "https://music.example/1~")
        InstagramImporter.rememberUsedSong(used, "https://music.example/2~")
        assertEquals(setOf("https://music.example/1~", "https://music.example/2~"), used)
        // The same track twice is one entry, not two.
        InstagramImporter.rememberUsedSong(used, "https://music.example/1~")
        assertEquals(2, used.size)
    }

    @Test
    fun `a post that got no song does not poison the exclude set`() {
        // An empty id in `exclude` is a song the suggester would then try to avoid matching, for a
        // track that does not exist.
        val used = HashSet<String>()
        InstagramImporter.rememberUsedSong(used, null)
        InstagramImporter.rememberUsedSong(used, "")
        InstagramImporter.rememberUsedSong(used, "   ")
        assertTrue(used.isEmpty())
    }

    // ---- Kept-story identity: re-importing must not double anything ------------------------------

    @Test
    fun `a kept story's id is stable and derived from the archive`() {
        val story = item(InstagramArchive.Kind.STORY, 1_610_000_000, media = listOf("media/stories/x.jpg"))
        assertEquals("ig:media/stories/x.jpg", InstagramImporter.keptIdentity(story))
        // Stable across runs → KeptStoriesStore.keep is idempotent, so re-importing the same export
        // does not keep every story twice.
        assertEquals(InstagramImporter.keptIdentity(story), InstagramImporter.keptIdentity(story))
    }

    @Test
    fun `a story with no media still gets an id`() {
        val bare = InstagramArchive.Item(InstagramArchive.Kind.STORY, 1_610_000_000_000L, "hi",
                                        emptyList(), null)
        assertEquals("ig:1610000000000", InstagramImporter.keptIdentity(bare))
    }

    // ---- Which archive entries are videos --------------------------------------------------------

    @Test
    fun `video entries are recognised by extension, case and path insensitively`() {
        assertTrue(InstagramImporter.isVideoName("media/reels/202301/clip.mp4"))
        assertTrue(InstagramImporter.isVideoName("media/posts/OLD.MOV"))
        assertTrue(InstagramImporter.isVideoName("x.m4v"))
        assertFalse(InstagramImporter.isVideoName("media/posts/photo.jpg"))
        assertFalse(InstagramImporter.isVideoName("media/posts/photo.heic"))
        assertFalse(InstagramImporter.isVideoName("media/posts/photo.webp"))
    }

    @Test
    fun `a scratch clip always gets a usable extension`() {
        // The staged file's extension is what MediaMetadataRetriever and the transcoder sniff, so an
        // extensionless entry must not produce "igimport_<uuid>." with nothing after the dot.
        assertEquals("mp4", InstagramImporter.extensionOf("media/reels/no-extension"))
        assertEquals("mov", InstagramImporter.extensionOf("A.MOV"))
        // A dot in a DIRECTORY name is not an extension.
        assertEquals("mp4", InstagramImporter.extensionOf("media/2023.01/clip"))
        assertEquals("jpg", InstagramImporter.extensionOf("media/2023.01/clip.jpg"))
    }
}
