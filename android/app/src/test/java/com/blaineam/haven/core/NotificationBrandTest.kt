package com.blaineam.haven.core

import com.blaineam.haven.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Haven's notification surfaces wear the Haven brand, not Android's stock glyphs: the small icons are the
 * constellation mark as monochrome (white-on-transparent) vectors, tinted by the palette accent. Source
 * scans guard the wiring so a stock `android.R.drawable.*` can't creep back into a builder.
 */
class NotificationBrandTest {
    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return d
    }
    private val main get() = File(repoRoot(), "android/app/src/main")
    private fun src(rel: String) = File(main, "java/com/blaineam/haven/$rel").readText()
    private fun drawable(name: String) = File(main, "res/drawable/$name.xml").readText()

    @Test fun noStockFrameworkDrawableRemainsInAnyNotificationOrCarSource() {
        val offenders = File(main, "java").walkTopDown().filter { it.extension == "kt" }
            .filter { it.readText().contains("android.R.drawable.") }.map { it.name }.toList()
        assertTrue("stock android.R.drawable icons still used in: $offenders", offenders.isEmpty())
    }

    @Test fun everyNotificationBuilderUsesTheBrandIconAndAccent() {
        for (f in listOf("core/Notifications.kt", "core/CarNotifications.kt", "core/ConnectionService.kt")) {
            val s = src(f)
            assertTrue("$f must use NotificationBrand small icons", s.contains("NotificationBrand.SMALL_ICON"))
            assertTrue("$f must tint with NotificationBrand.accent()", s.contains("NotificationBrand.accent()"))
        }
        assertTrue("calls use the call glyph", src("core/Notifications.kt").contains("NotificationBrand.SMALL_ICON_CALL"))
    }

    @Test fun theTelecomAccountWearsTheBrandIcon() {
        val s = src("core/TelecomCalls.kt")
        assertTrue(s.contains(".setIcon(") && s.contains("NotificationBrand.SMALL_ICON_CALL"))
        assertTrue(s.contains(".setHighlightColor(NotificationBrand.accent())"))
    }

    @Test fun monochromeIconsAreVectorsPaintedOnlyWhite() {
        val mono = listOf("ic_stat_haven", "ic_stat_haven_call", "ic_action_reply", "ic_action_mark_read",
            "ic_car_contacts", "ic_car_messages", "ic_car_recents")
        for (n in mono) {
            val x = drawable(n)
            assertTrue("$n must be a vector", x.contains("<vector"))
            assertFalse("$n must not use gradients", x.contains("<gradient") || x.contains("aapt:attr"))
            val colours = Regex("""(?:fillColor|strokeColor)="([^"]+)"""").findAll(x).map { it.groupValues[1].uppercase() }.toSet()
            assertTrue("$n paints only white: $colours", colours.all { it == "#FFFFFFFF" || it == "#00000000" })
            assertTrue("$n is 24dp", x.contains("""android:width="24dp"""") && x.contains("""android:height="24dp""""))
        }
    }

    @Test fun smallIconsAreTheHavenConstellationAndHandsetVariant() {
        assertTrue("the mark has 6 nodes", Regex("a[0-9.]+,[0-9.]+ 0,1,0").findAll(drawable("ic_stat_haven")).count() >= 12)
        assertTrue("the call glyph keeps a handset", drawable("ic_stat_haven_call").contains("c1.44,2.83"))
        assertNotEquals(R.drawable.ic_stat_haven, R.drawable.ic_stat_haven_call)
        assertEquals(R.drawable.ic_stat_haven, NotificationBrand.SMALL_ICON)
        assertEquals(R.drawable.ic_stat_haven_call, NotificationBrand.SMALL_ICON_CALL)
    }

    @Test fun betaEntryIconsUseTheBrandGradient() {
        for (n in listOf("ic_car_entry_calls", "ic_car_entry_messages")) {
            val x = drawable(n).uppercase()
            assertTrue("$n uses the Sunset brand stops", x.contains("#FF7C3AED") && x.contains("#FFEC4899") && x.contains("#FFF59E0B"))
        }
    }

    @Test fun accentIsThePaletteTintStopAndNeutralStaysGrey() {
        assertEquals(0xFFEC4899.toInt(), NotificationBrand.accent("sunset"))   // stop 2
        assertEquals(0xFF06B6D4.toInt(), NotificationBrand.accent("ocean"))
        val n = NotificationBrand.accent("neutral")
        assertEquals("neutral is opaque", 0xFF, (n ushr 24) and 0xFF)
        assertEquals("neutral is grey", (n shr 16) and 0xFF, (n shr 8) and 0xFF)
        assertEquals("neutral is grey", (n shr 8) and 0xFF, n and 0xFF)
        assertEquals("unknown ids fall back to the default palette", NotificationBrand.accent("sunset"), NotificationBrand.accent("nope"))
    }
}
