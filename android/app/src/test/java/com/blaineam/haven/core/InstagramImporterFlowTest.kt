package com.blaineam.haven.core

import android.net.Uri
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/** The importer's state machine against real (synthetic) archives picked as `file://` documents. */
class InstagramImporterFlowTest {
    private lateinit var dir: File
    private lateinit var ctx: FakeContext
    private fun m(uri: String, ts: Long, title: String = "", genre: String? = null) = InstagramFixture.media(uri, ts, title, genre)
    private val I = InstagramImporter

    @Before fun setUp() {
        dir = Files.createTempDirectory("ig-flow").toFile()
        ctx = FakeContext()
        I.init(ctx)
        I.cancel()   // clears nothing, but makes sure a previous test's flag is a known value
        forceIdle()
    }
    @After fun tearDown() { dir.deleteRecursively(); ctx.filesDir.deleteRecursively() }

    private fun forceIdle() {
        I.stage.value = InstagramImporter.Stage.IDLE
        I.reset()
    }

    private fun uri(f: File) = Uri.parse("file://" + f.absolutePath)

    /** The importer works on a background coroutine; wait for the state it ends in (no fixed sleeps). */
    private fun await(what: String, cond: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (!cond()) { check(System.nanoTime() < deadline) { "timed out waiting for $what (stage=${I.stage.value})" }; Thread.onSpinWait() }
    }

    private fun archive(vararg stories: Pair<String, Long>): File = InstagramFixture.write(dir,
        stories = stories.map { m(it.first, it.second) },
        files = stories.associate { it.first to ByteArray(32) { 3 } })

    @Test fun picking_a_valid_archive_moves_to_the_preview_without_importing_anything() {
        I.read(ctx, uri(archive("media/a.jpg" to 10, "media/b.jpg" to 20)))
        await("preview") { I.stage.value == InstagramImporter.Stage.PREVIEWING }
        assertEquals(2, I.summary.value!!.items.size)
        assertNull(I.problem.value); assertFalse(I.isRunning)
        assertEquals(0, I.importedCount.intValue)
    }

    @Test fun an_html_export_fails_with_the_html_reason() {
        val zip = InstagramFixture.write(dir, extra = mapOf("your_instagram_activity/media/posts_1.html" to "<html/>".toByteArray()))
        I.read(ctx, uri(zip))
        await("failure") { I.stage.value == InstagramImporter.Stage.FAILED }
        assertEquals(InstagramImporter.Problem.HTML_EXPORT, I.problem.value)
    }

    @Test fun an_archive_with_no_posts_fails_with_no_content() {
        I.read(ctx, uri(InstagramFixture.write(dir, posts = emptyList(), stories = emptyList())))
        await("failure") { I.stage.value == InstagramImporter.Stage.FAILED }
        assertEquals(InstagramImporter.Problem.NO_CONTENT, I.problem.value)
    }

    @Test fun a_file_that_is_not_a_zip_is_unreadable() {
        val bad = File(dir, "bad.zip").also { it.writeText("nope") }
        I.read(ctx, uri(bad))
        await("failure") { I.stage.value == InstagramImporter.Stage.FAILED }
        assertEquals(InstagramImporter.Problem.UNREADABLE, I.problem.value)
    }

    @Test fun a_document_that_cannot_be_opened_at_all_is_unreadable() {
        I.read(ctx, Uri.parse("file://" + File(dir, "gone.zip").absolutePath))
        await("failure") { I.stage.value == InstagramImporter.Stage.FAILED }
        assertEquals(InstagramImporter.Problem.UNREADABLE, I.problem.value)
    }

    @Test fun reset_goes_back_to_the_walkthrough() {
        I.read(ctx, uri(archive("media/a.jpg" to 10)))
        await("preview") { I.stage.value == InstagramImporter.Stage.PREVIEWING }
        I.reset()
        assertEquals(InstagramImporter.Stage.IDLE, I.stage.value); assertNull(I.summary.value); assertNull(I.problem.value)
    }

    @Test fun running_before_a_preview_does_nothing() {
        I.run("circ")
        assertEquals(InstagramImporter.Stage.IDLE, I.stage.value)
        assertNull(ctx.prefs("haven.instagram.import").getString("pending", null))
    }

    @Test fun a_run_visits_every_item_checkpoints_and_clears_the_checkpoint_when_finished() {
        I.read(ctx, uri(archive("media/a.jpg" to 10, "media/b.jpg" to 20, "media/c.jpg" to 30)))
        await("preview") { I.stage.value == InstagramImporter.Stage.PREVIEWING }
        I.run("circ", includeStories = true)
        await("finish") { I.stage.value == InstagramImporter.Stage.FINISHED }
        assertEquals(3, I.total.intValue); assertEquals(3, I.done.intValue)
        // Nothing here can be staged on the JVM (no image codec, no engine), so every item is counted as skipped —
        // which is exactly how a failing item must behave: counted, never fatal to the run.
        assertEquals(0, I.importedCount.intValue); assertEquals(3, I.skippedCount.intValue)
        assertNull("finishing drops the checkpoint", ctx.prefs("haven.instagram.import").getString("pending", null))
    }

    @Test fun stories_are_left_out_unless_asked_for() {
        val zip = InstagramFixture.write(dir,
            posts = listOf(InstagramFixture.post(5, "p", listOf(m("media/p.jpg", 5)))),
            stories = listOf(m("media/s.jpg", 9)),
            files = mapOf("media/p.jpg" to ByteArray(4), "media/s.jpg" to ByteArray(4)))
        I.read(ctx, uri(zip))
        await("preview") { I.stage.value == InstagramImporter.Stage.PREVIEWING }
        I.run("circ", includeStories = false)
        await("finish") { I.stage.value == InstagramImporter.Stage.FINISHED }
        assertEquals(1, I.total.intValue)
    }

    @Test fun a_checkpoint_survives_to_be_resumed_and_an_unresolvable_one_is_quietly_dropped() {
        val prefs = ctx.prefs("haven.instagram.import")
        prefs.data["pending"] = I.encodePending(InstagramImporter.Pending("file://" + File(dir, "deleted.zip").absolutePath, "circ", false, false, 4))
        I.resumeIfNeeded()
        await("the stale checkpoint to be forgotten") { prefs.getString("pending", null) == null }
        assertEquals(InstagramImporter.Stage.IDLE, I.stage.value)
    }

    @Test fun a_checkpoint_past_the_last_item_is_dropped_rather_than_reimporting() {
        val zip = archive("media/a.jpg" to 10)
        val prefs = ctx.prefs("haven.instagram.import")
        prefs.data["pending"] = I.encodePending(InstagramImporter.Pending(uri(zip).toString(), "circ", true, false, done = 99))
        I.resumeIfNeeded()
        await("the finished checkpoint to be forgotten") { prefs.getString("pending", null) == null }
    }

    @Test fun a_resumed_import_starts_after_the_items_already_done() {
        val zip = archive("media/a.jpg" to 10, "media/b.jpg" to 20, "media/c.jpg" to 30)
        val prefs = ctx.prefs("haven.instagram.import")
        prefs.data["pending"] = I.encodePending(InstagramImporter.Pending(uri(zip).toString(), "circ", true, false, done = 2))
        I.resumeIfNeeded()
        await("finish") { I.stage.value == InstagramImporter.Stage.FINISHED }
        assertEquals(3, I.total.intValue); assertEquals(3, I.done.intValue)
        assertEquals("only the one remaining item was attempted", 1, I.skippedCount.intValue + I.importedCount.intValue)
        assertNotNull(I.summary.value)
    }
}
