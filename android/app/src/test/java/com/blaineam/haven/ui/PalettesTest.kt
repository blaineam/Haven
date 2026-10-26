package com.blaineam.haven.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PalettesTest {
    @Test fun lookupAndFallback() {
        assertEquals("ocean", Palettes.byId("ocean").id)
        assertEquals("sunset", Palettes.byId(null).id)
        assertEquals("sunset", Palettes.byId("").id)
        assertEquals("sunset", Palettes.byId("from-a-newer-build").id)
        assertEquals("sunset", Palettes.normalizedId("OCEAN"))   // ids are exact, lowercase
        assertEquals(8, Palettes.all.size)
        assertEquals(8, Palettes.all.map { it.id }.toSet().size)
    }

    @Test fun specStopsMatch() {
        val n = Palettes.byId("neutral")
        assertEquals(listOf(0x404040, 0x737373, 0xA3A3A3), listOf(n.stop1, n.stop2, n.stop3))
        val s = Palettes.default
        assertEquals(listOf(0x7C3AED, 0xEC4899, 0xF59E0B), listOf(s.stop1, s.stop2, s.stop3))
    }

    @Test fun accentMeetsAAInBothModesForEveryPalette() {
        for (p in Palettes.all) for (dark in listOf(true, false)) {
            val c = Palettes.readable(p.stop2, dark)
            val surfaces = if (dark) listOf(Palettes.DARK_CARD, Palettes.DARK_BACKDROP)
                           else listOf(Palettes.LIGHT_CARD, Palettes.LIGHT_BACKDROP)
            for (bg in surfaces) assertTrue("${p.id} dark=$dark ${Integer.toHexString(c)}", Palettes.contrast(c, bg) >= 4.5)
        }
    }

    @Test fun passingStopIsUntouched() {
        assertEquals(0xEC4899, Palettes.readable(0xEC4899, dark = true))
    }

    @Test fun neutralGradientCarriesWhiteTextAtAA() {
        val (a, b, c) = Palettes.gradientStops(Palettes.byId("neutral"))
        for (x in listOf(a, b, c)) assertTrue(Palettes.contrast(x, 0xFFFFFF) >= 4.5)
        // Colourful palettes keep their raw stops (the default look is unchanged).
        val s = Palettes.default
        assertEquals(Triple(s.stop1, s.stop2, s.stop3), Palettes.gradientStops(s))
    }

    @Test fun appIconPlan() {
        val (on, off) = AppIcon.plan("grape")
        assertEquals("com.blaineam.haven.LauncherAliasGrape", on)
        assertEquals(7, off.size)
        assertTrue(on !in off)
        assertEquals("com.blaineam.haven.LauncherAliasSunset", AppIcon.plan("bogus").first)
    }
}
