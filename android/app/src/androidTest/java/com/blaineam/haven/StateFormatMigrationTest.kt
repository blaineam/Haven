package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.blaineam.haven.core.StateFiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.haven_ffi.HavenSocial
import java.io.File

/**
 * 2.0.1 writes the persisted engine state's byte fields as base64 instead of decimal arrays. A
 * state file an older build left on disk (assets/legacy_decimal_state.bin = the core's real 1.0.6
 * fixture, same decimal form 2.0.0 wrote) must load through HavenNet's file path, be rewritten
 * compact on the next save, and reload with the same circles and posts.
 */
@RunWith(AndroidJUnit4::class)
class StateFormatMigrationTest {

    // The fixture's own identity (core/haven-ffi/tests/state_size.rs).
    private fun engine(state: ByteArray?): HavenSocial {
        val s = HavenSocial(ByteArray(32) { 1 })
        assertTrue(s.useDeviceIdentity(ByteArray(32) { 91 }))
        state?.let { s.importState(it) }
        return s
    }

    private fun view(s: HavenSocial) = s.circles().map { c ->
        Triple(c.id, c.memberCount.toInt(), s.feed(c.id, 10_000_000UL, null).size)
    }

    @Test fun a_decimal_array_state_file_loads_and_saves_compact() {
        val inst = InstrumentationRegistry.getInstrumentation()
        val legacy = inst.context.assets.open("legacy_decimal_state.bin").use { it.readBytes() }
        val file = File(inst.targetContext.cacheDir, "state-format-migration.bin")

        StateFiles.writeAtomic(file, legacy)            // what 2.0.0 left on disk
        val old = engine(file.readBytes())
        val before = view(old)
        assertTrue("legacy state loaded no posts", before.isNotEmpty() && before.any { it.third > 0 })

        StateFiles.writeAtomic(file, old.exportState()) // the next save
        val compact = file.readBytes()
        assertTrue("${compact.size} bytes vs ${legacy.size} legacy", compact.size * 2 < legacy.size)

        assertEquals(before, view(engine(file.readBytes())))
        file.delete()
    }
}
