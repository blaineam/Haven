package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class QaFilesTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun qaDir() = File(tmp.root, "files/qa")

    @Test
    fun writesAndReplacesLeavingNoTmp() {
        val dest = File(qaDir().apply { mkdirs() }, "qa-dump.json")
        assertNull(QaFiles.writeAtomically(dest, "one"))
        assertNull(QaFiles.writeAtomically(dest, "two"))
        assertEquals("two", dest.readText())
        assertEquals(listOf("qa-dump.json"), qaDir().list()!!.toList())
    }

    @Test
    fun recreatesAWipedDir() {
        // The harness recovery wipes the channel; the next dump must not die on a missing parent.
        val dest = File(qaDir(), "qa-dump.json")
        qaDir().deleteRecursively()
        assertNull(QaFiles.writeAtomically(dest, "fresh"))
        assertEquals("fresh", dest.readText())
    }

    @Test
    fun aStaleFixedTmpCannotBlockTheWrite() {
        // A killed writer (or the harness mid-`rm`) can leave `<name>.tmp` behind — even as a dir.
        val dest = File(qaDir().apply { mkdirs() }, "qa-dump.json")
        File(qaDir(), "qa-dump.json.tmp").mkdirs()
        assertNull(QaFiles.writeAtomically(dest, "ok"))
        assertEquals("ok", dest.readText())
    }

    @Test
    fun anUnwritableDestIsRetriedAndReportedWithItsCause() {
        // dest is a non-empty directory: neither the rename nor the direct write can land.
        val dest = File(qaDir(), "qa-dump.json").apply { mkdirs() }
        File(dest, "x").writeText("x")
        val seen = ArrayList<Int>()
        val err = QaFiles.writeAtomically(dest, "nope", attempts = 3) { attempt, _ -> seen += attempt }
        assertNotNull(err)
        assertEquals(listOf(1, 2, 3), seen)
        assertTrue("no tmp files left behind", qaDir().list()!!.none { it.endsWith(".tmp") })
    }
}
