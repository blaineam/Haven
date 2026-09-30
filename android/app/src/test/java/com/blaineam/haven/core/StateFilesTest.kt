package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** The engine state is replaced whole, never truncated, and no temp file is left beside it. */
class StateFilesTest {
    @Test fun atomic_write_replaces_the_whole_file_and_leaves_no_temp() {
        val dir = Files.createTempDirectory("haven-state").toFile()
        val f = java.io.File(dir, "state.bin")
        StateFiles.writeAtomic(f, "first version, longer than the second".toByteArray())
        StateFiles.writeAtomic(f, "second".toByteArray())
        assertArrayEquals("second".toByteArray(), f.readBytes())
        assertFalse(java.io.File(dir, "state.bin.tmp-write").exists())
        dir.deleteRecursively()
    }

    /** persist() runs on several threads at once; every write must land whole, none may throw. */
    @Test fun concurrent_writers_never_fail_or_leave_a_partial_file() {
        val dir = Files.createTempDirectory("haven-state").toFile()
        val f = java.io.File(dir, "state.bin")
        val payloads = (0 until 6).map { n -> ByteArray(64 * 1024 + n) { n.toByte() } }
        val failures = java.util.concurrent.atomic.AtomicInteger()
        val threads = payloads.map { p ->
            Thread {
                repeat(40) { runCatching { StateFiles.writeAtomic(f, p) }.onFailure { failures.incrementAndGet() } }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertEquals(0, failures.get())
        val onDisk = f.readBytes()
        assertTrue(payloads.any { it.contentEquals(onDisk) })
        assertFalse(java.io.File(dir, "state.bin.tmp-write").exists())
        dir.deleteRecursively()
    }

    /** The snapshot is taken under the lock, so the file holds the LAST export, not a stale one. */
    @Test fun snapshot_is_taken_inside_the_write() {
        val dir = Files.createTempDirectory("haven-state").toFile()
        val f = java.io.File(dir, "state.bin")
        var version = 0
        StateFiles.writeAtomicFrom(f) { (++version).toString().toByteArray() }
        StateFiles.writeAtomicFrom(f) { (++version).toString().toByteArray() }
        assertArrayEquals("2".toByteArray(), f.readBytes())
        dir.deleteRecursively()
    }
}
