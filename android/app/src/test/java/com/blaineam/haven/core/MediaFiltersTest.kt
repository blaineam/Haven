package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The filter set and the GLSL generated from it (shared by the photo, video and live-preview paths). */
class MediaFiltersTest {
    private fun frag(f: HavenFilter) = FilterShader.fragmentFor(f.spec)

    @Test fun the_set_is_original_plus_ten_looks_with_unique_titles() {
        assertEquals(11, HavenFilter.all.size)
        assertEquals("Original", HavenFilter.ORIGINAL.title)
        assertEquals(HavenFilter.all.size, HavenFilter.all.map { it.title }.toSet().size)
        assertEquals(FilterSpec(), HavenFilter.ORIGINAL.spec)
    }

    @Test fun the_original_filter_is_a_pure_passthrough() {
        val s = frag(HavenFilter.ORIGINAL)
        assertTrue(s.contains("texture2D(sTexture, uv)"))
        for (op in listOf("rgb *=", "smoothstep", "mix(", "fract(", "distance(")) assertFalse("$op should be absent", s.contains(op))
        assertTrue(s.contains("gl_FragColor = vec4(clamp(rgb, 0.0, 1.0), c.a);"))
    }

    @Test fun every_filter_produces_a_complete_shader() {
        for (f in HavenFilter.all) {
            val s = frag(f)
            assertTrue(f.name, s.startsWith("precision mediump float;"))
            assertTrue(f.name, s.contains("uniform lowp sampler2D sTexture;"))
            assertEquals(f.name, s.count { it == '{' }, s.count { it == '}' })
            assertTrue(f.name, s.trimEnd().endsWith("}"))
        }
    }

    @Test fun the_camera_variant_samples_the_external_oes_texture() {
        val s = FilterShader.fragmentForOes(HavenFilter.VIVID.spec)
        assertTrue(s.startsWith("#extension GL_OES_EGL_image_external : require"))
        assertTrue(s.contains("uniform samplerExternalOES sTexture;"))
        assertFalse(s.contains("sampler2D"))
        assertTrue(FilterShader.CAMERA_VERTEX.contains("uTexMatrix"))
        assertTrue(FilterShader.VERTEX.contains("gl_Position = aPosition"))
    }

    @Test fun white_balance_warms_by_lifting_red_and_cutting_blue() {
        val warm = frag(HavenFilter.VIVID_WARM); val cool = frag(HavenFilter.VIVID_COOL)
        fun gains(s: String) = Regex("""rgb \*= vec3\(([\d.]+), ([\d.]+), ([\d.]+)\)""").find(s)!!.groupValues.drop(1).map { it.toDouble() }
        val (wr, _, wb) = gains(warm); val (cr, _, cb) = gains(cool)
        assertTrue(wr > 1.0 && wb < 1.0)
        assertTrue(cr < 1.0 && cb > 1.0)
    }

    @Test fun neutral_temperature_with_a_tint_still_shifts_the_green_channel() {
        val s = FilterShader.fragmentFor(FilterSpec(tint = 10.0))
        val g = Regex("""rgb \*= vec3\(([\d.]+), ([\d.]+), ([\d.]+)\)""").find(s)!!.groupValues[2].toDouble()
        assertTrue("positive tint is magenta: less green", g < 1.0)
    }

    @Test fun gains_are_clamped_for_extreme_temperatures() {
        val s = FilterShader.fragmentFor(FilterSpec(temperatureK = -30000.0))
        val r = Regex("""rgb \*= vec3\(([\d.]+), ([\d.]+), ([\d.]+)\)""").find(s)!!.groupValues
        assertEquals(1.6, r[1].toDouble(), 0.0001); assertEquals(0.5, r[3].toDouble(), 0.0001)
    }

    @Test fun monochrome_looks_replace_saturation_and_keep_brightness() {
        for (f in listOf(HavenFilter.MONO, HavenFilter.SILVERTONE, HavenFilter.NOIR)) {
            val s = frag(f)
            assertTrue(f.name, s.contains("float my = dot("))
            assertFalse("a mono look has no saturation/vibrance stage", s.contains("mix(vec3(gy)"))
        }
        // The tone multipliers are normalised to luma 1, so an all-neutral tone is exactly white-balanced grey.
        val neutral = Regex("""rgb = my \* vec3\(([\d.]+), ([\d.]+), ([\d.]+)\)""").find(frag(HavenFilter.MONO))!!.groupValues
        assertEquals(1.0, neutral[1].toDouble(), 0.0001); assertEquals(1.0, neutral[3].toDouble(), 0.0001)
        val warm = Regex("""rgb = my \* vec3\(([\d.]+), ([\d.]+), ([\d.]+)\)""").find(frag(HavenFilter.SILVERTONE))!!.groupValues
        assertTrue(warm[1].toDouble() > warm[3].toDouble())
        val cool = Regex("""rgb = my \* vec3\(([\d.]+), ([\d.]+), ([\d.]+)\)""").find(frag(HavenFilter.NOIR))!!.groupValues
        assertTrue(cool[1].toDouble() < cool[3].toDouble())
    }

    @Test fun film_look_adds_fade_grain_and_vignette_stages_in_order() {
        val s = frag(HavenFilter.KODAK_GOLD)
        val fade = s.indexOf("max(rgb, vec3("); val grain = s.indexOf("gl_FragCoord"); val vig = s.indexOf("distance(uv")
        assertTrue(fade in 0 until grain && grain < vig)
        assertTrue("grain must hash per pixel, not per uv", s.contains("dot(gl_FragCoord.xy"))
    }

    @Test fun highlight_and_shadow_shaping_only_appears_when_asked_for() {
        assertFalse(frag(HavenFilter.VIVID).contains("smoothstep(0.0, 0.5"))
        assertTrue(frag(HavenFilter.DRAMATIC).contains("smoothstep(0.0, 0.5"))
    }

    @Test fun contrast_and_brightness_bake_their_constants_into_the_shader() {
        val s = FilterShader.fragmentFor(FilterSpec(contrast = 1.5, brightness = 0.25))
        assertTrue(s.contains("(rgb - 0.5) * 1.50000 + 0.5 + 0.25000"))
    }

    /** `"%.5f".format(v)` follows the device locale: on a German or French phone it wrote `1,50000`, which is
     *  not a GLSL float literal, so the shader failed to compile and every filtered photo came out blank. */
    @Test fun shader_constants_use_a_dot_decimal_whatever_the_device_locale() {
        val saved = java.util.Locale.getDefault()
        try {
            for (loc in listOf(java.util.Locale.GERMANY, java.util.Locale.FRANCE, java.util.Locale("ar", "EG"))) {
                java.util.Locale.setDefault(loc)
                val s = frag(HavenFilter.KODAK_GOLD)
                assertFalse("$loc: decimal comma in shader", Regex("""\d,\d""").containsMatchIn(s))
                assertTrue("$loc", s.contains("0.96000"))
            }
        } finally { java.util.Locale.setDefault(saved) }
    }
}
