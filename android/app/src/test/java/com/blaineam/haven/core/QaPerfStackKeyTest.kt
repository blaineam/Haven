package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** QaPerf's busy-stack sampler must name what a thread is DOING and skip threads that are idle. */
class QaPerfStackKeyTest {
    private fun f(cls: String, m: String, line: Int = 10) = StackTraceElement(cls, m, "X.kt", line)
    private fun native(cls: String, m: String) = StackTraceElement(cls, m, null, -2)

    @Test
    fun idleThreadsAreSkipped() {
        assertNull(QaPerf.stackKey(arrayOf(native("android.os.MessageQueue", "nativePollOnce"), f("android.os.Looper", "loop"))))
        assertNull(QaPerf.stackKey(arrayOf(native("jdk.internal.misc.Unsafe", "park"), f("java.util.concurrent.locks.LockSupport", "park"))))
        assertNull(QaPerf.stackKey(arrayOf(native("java.lang.Object", "wait"))))
        assertNull(QaPerf.stackKey(emptyArray()))
    }

    @Test
    fun appAndEngineFramesAreNamed() {
        val frames = arrayOf(
            native("com.sun.jna.Native", "invokePointer"),
            f("uniffi.haven_ffi.HavenSocial", "feed", 100),
            f("kotlinx.coroutines.DispatchedTask", "run"),
            f("com.blaineam.haven.ui.CircleScreenKt", "readFeed", 1500),
            f("com.blaineam.haven.core.ConflatedReadsKt", "conflatedReads", 24),
        )
        assertEquals("HavenSocial.feed:100 < CircleScreenKt.readFeed:1500 < ConflatedReadsKt.conflatedReads:24",
            QaPerf.stackKey(frames))
    }

    @Test
    fun frameworkOnlyStacksFallBackToTheTop() {
        val frames = arrayOf(f("androidx.compose.runtime.Recomposer", "compose", 5), f("android.view.Choreographer", "doFrame", 7))
        assertEquals("Recomposer.compose:5 < Choreographer.doFrame:7", QaPerf.stackKey(frames))
    }
}
