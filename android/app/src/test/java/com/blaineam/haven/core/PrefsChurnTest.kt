package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Test

class PrefsChurnTest {
    @Test fun summaryGroupsByFileBusiestFirst() {
        val line = PrefsChurn.summarize(mapOf(
            "haven.contacts\u0000relayEntries" to 2,
            "haven.contacts\u0000notifiedIds" to 3,
            "haven.mediabackup.queue\u0000pending" to 1,
        ))
        assertEquals("haven.contacts=5 [notifiedIds=3 relayEntries=2] haven.mediabackup.queue=1 [pending=1]", line)
    }

    @Test fun nothingToReportIsEmpty() {
        assertEquals("", PrefsChurn.summarize(emptyMap()))
    }
}
