package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The coordinator's own device-local state: the per-device id and the seedless-enrollment guard. */
class SelfSyncCoordinatorStateTest {
    // SelfSyncCoordinator is a one-shot singleton: init() keeps the FIRST context for the whole JVM.
    private val ctx = shared

    private val base get() = File(ctx.filesDir, "haven-selfsync.bin")

    @Test fun the_device_id_is_32_random_bytes_persisted_device_locally() {
        val hex = SelfSyncCoordinator.deviceHex
        assertEquals(64, hex.length)
        assertTrue(hex.all { it in '0'..'9' || it in 'a'..'f' })
        assertEquals("stable for the life of the process", hex, SelfSyncCoordinator.deviceHex)
        assertEquals("and written to prefs for the next launch", hex, ctx.prefs("haven.selfsync").getString("haven.selfsync.deviceId", null))
    }

    @Test fun reset_erases_the_converged_base() {
        base.writeBytes(byteArrayOf(1, 2, 3))
        SelfSyncCoordinator.reset()
        assertFalse(base.exists())
        SelfSyncCoordinator.reset()   // already gone: still fine
    }

    @Test fun seedless_enrollment_empties_the_base_and_arms_the_additive_only_guard() {
        base.writeBytes(byteArrayOf(9, 9, 9))
        SelfSyncCoordinator.beginSeedlessEnrollment()
        assertFalse("a fresh device must never diff its empty engine against a stale base", base.exists())
        assertTrue(ctx.prefs("haven.selfsync").getBoolean("seedless.awaiting.first.merge", false))
    }

    companion object {
        private val shared: FakeContext = FakeContext().also { SelfSyncCoordinator.init(it) }
    }
}
