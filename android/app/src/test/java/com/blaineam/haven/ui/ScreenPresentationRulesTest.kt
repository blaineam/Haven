package com.blaineam.haven.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.haven_ffi.FeedItemFfi

/**
 * The pure presentation rules inside the Compose screens (no Compose runtime needed): the story
 * tray grouping and age label, the message-time label, the DM disappearing chip, the media carousel
 * shape and the story-caption legibility rules. They are private to their files, so they are
 * reached by reflection on the file classes — the same rule the screens run.
 */
class ScreenPresentationRulesTest {
    private fun fileFn(cls: String, name: String, vararg args: Any?): Any? {
        val c = Class.forName("com.blaineam.haven.ui.$cls")
        val m = c.declaredMethods.first { (it.name == name || it.name.startsWith("$name-")) && it.parameterCount == args.size }
        m.isAccessible = true
        return try { m.invoke(null, *args) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }

    private fun item(id: String, author: String, at: ULong, me: Boolean = false, story: Boolean = true) = FeedItemFfi(
        id, author, me, at, "", emptyList(), null, false, false, story, false, emptyList(), emptyList(), null,
    )

    // ---- Stories --------------------------------------------------------------------------------

    @Test fun story_age_steps_through_now_seconds_minutes_hours_days() {
        val now = System.currentTimeMillis()
        fun age(agoSecs: Long) = fileFn("StoriesKt", "storyAge", now - agoSecs * 1000) as String
        assertEquals("now", age(0))
        assertEquals("now", age(2))
        assertEquals("30s", age(30))
        assertEquals("5m", age(5 * 60 + 3))
        assertEquals("3h", age(3 * 3600 + 20))
        assertEquals("2d", age(2 * 86_400 + 5))
    }

    @Test fun only_stories_are_grouped_per_author_oldest_first_with_mine_leading() {
        val items = listOf(
            item("b2", "bob", 300uL), item("p", "bob", 50uL, story = false),
            item("m1", "me", 200uL, me = true), item("b1", "bob", 100uL),
            item("a1", "ann", 150uL),
        )
        val groups = groupStories(items)
        assertEquals("a plain post is not a story", 3, groups.size)
        assertEquals("my own ring leads", "me", groups[0].authorShort); assertTrue(groups[0].isMe)
        val bob = groups.first { it.authorShort == "bob" }
        assertEquals("a ring plays oldest to newest", listOf("b1", "b2"), bob.items.map { it.id })
        assertEquals(listOf("ann", "bob"), groups.drop(1).map { it.authorShort }.sorted())
        assertTrue(groupStories(emptyList()).isEmpty())
        assertTrue(groupStories(listOf(item("p", "x", 1uL, story = false))).isEmpty())
    }

    // ---- Messages -------------------------------------------------------------------------------

    @Test fun message_time_reads_now_s_m_h_d_w_mo() {
        val now = System.currentTimeMillis()
        fun t(agoSecs: Long) = fileFn("MessagesScreenKt", "msgTime", now - agoSecs * 1000) as String
        assertEquals("now", t(1))
        assertEquals("45s", t(45))
        assertEquals("5m", t(5 * 60 + 1))
        assertEquals("3h", t(3 * 3600 + 1))
        assertEquals("2d", t(2 * 86_400 + 1))
        assertEquals("2w", t(2 * 604_800L + 1))
        assertEquals("2mo", t(2 * 2_592_000L + 1))
    }

    @Test fun a_message_stamped_in_the_future_reads_now() {
        val future = System.currentTimeMillis() + 60_000
        assertEquals("now", fileFn("MessagesScreenKt", "msgTime", future))
    }

    @Test fun the_dm_disappear_chip_names_the_preset_windows_and_falls_back_to_hours() {
        assertEquals("⏱ 1h", fileFn("MessagesScreenKt", "dmDisappearLabel", 3_600L))
        assertEquals("⏱ 1d", fileFn("MessagesScreenKt", "dmDisappearLabel", 86_400L))
        assertEquals("⏱ 1w", fileFn("MessagesScreenKt", "dmDisappearLabel", 604_800L))
        assertEquals("⏱ 12h", fileFn("MessagesScreenKt", "dmDisappearLabel", 43_200L))
    }

    // ---- Media carousel -------------------------------------------------------------------------

    private fun carousel(vararg a: Float) = fileFn("CircleScreenKt", "carouselAspect", a.toList()) as Float

    @Test fun a_uniform_set_keeps_its_exact_shape() {
        assertEquals(1.5f, carousel(1.5f, 1.52f, 1.49f), 0.02f)
        assertEquals(0.5625f, carousel(0.5625f), 1e-4f)   // a lone 9:16 clip is not clamped
    }

    @Test fun an_empty_set_uses_the_default_four_thirds() {
        assertEquals(4f / 3f, carousel(), 1e-4f)
    }

    @Test fun a_mixed_set_takes_the_tallest_but_is_clamped() {
        assertEquals("tallest wins, within the clamp", 0.9f, carousel(1.78f, 0.9f), 1e-4f)
        assertEquals("one 9:16 clip cannot squeeze the card", 0.8f, carousel(1.78f, 0.5625f), 1e-4f)
        assertEquals("never wider than 1.91", 1.91f, carousel(2.5f, 3.0f, 2.6f), 1e-4f)
    }

    // ---- Story editor caption legibility --------------------------------------------------------

    private fun contrastOn(c: Color): Color =
        Color((fileFn("StoryEditorKt", "contrastOn", c.value.toLong()) as Long).toULong())

    @Test fun highlight_text_is_black_on_light_and_white_on_dark() {
        assertEquals(Color.Black, contrastOn(Color.White))
        assertEquals(Color.Black, contrastOn(Color.Yellow))
        assertEquals(Color.White, contrastOn(Color.Black))
        assertEquals(Color.White, contrastOn(Color.Blue))
    }

    private fun capStyle(name: String): Any =
        Class.forName("com.blaineam.haven.ui.CapStyle").enumConstants.first { (it as Enum<*>).name == name }

    private fun liveCap(style: String, color: Color): Any = fileFn("StoryEditorKt", "liveCap", capStyle(style), color.value.toLong())!!

    @Test fun every_caption_style_resolves_to_a_look() {
        val red = Color.Red
        for (s in listOf("PLAIN", "SHADOW", "GLOW", "NEON", "HIGHLIGHT")) {
            val cap = liveCap(s, red)
            assertTrue(s, cap.javaClass.simpleName == "LiveCap")
        }
        // HIGHLIGHT is the only style with no shadow and a filled background; the rest never fill.
        fun shadow(c: Any) = c.javaClass.getDeclaredMethod("getShadow").also { it.isAccessible = true }.invoke(c)
        assertNull(shadow(liveCap("HIGHLIGHT", red)))
        for (s in listOf("PLAIN", "SHADOW", "GLOW", "NEON")) assertTrue(s, shadow(liveCap(s, red)) != null)
        assertSame(shadow(liveCap("PLAIN", red)).javaClass, shadow(liveCap("GLOW", red)).javaClass)
    }

    // ---- Instagram import -----------------------------------------------------------------------

    @Test fun the_import_range_labels_read_month_and_year() {
        val prev = java.util.Locale.getDefault()
        val tz = java.util.TimeZone.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.US)
            java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("UTC"))
            assertEquals("Mar 2021", fileFn("InstagramImportScreenKt", "monthYear", 1_615_800_000_000L))
            assertEquals("Jan 1970", fileFn("InstagramImportScreenKt", "monthYear", 0L))
        } finally { java.util.Locale.setDefault(prev); java.util.TimeZone.setDefault(tz) }
    }
}
