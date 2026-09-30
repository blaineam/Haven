package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
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
}
