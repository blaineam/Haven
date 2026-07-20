package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.blaineam.haven.core.MediaProcessing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The picker callbacks that encode video are delivered on the main looper, and the encode is a full
 * MediaCodec transcode. Running it there is an ANR, not jank — Android kills the app after 5s.
 *
 * These assert the two properties that stop that from coming back: the work leaves the main thread,
 * and the counter that drives the "Preparing…" card is always returned to zero.
 */
@RunWith(AndroidJUnit4::class)
class MediaProcessingThreadTest {

    /** The one that matters: called FROM main, the body must not RUN on main. */
    @Test
    fun encodingLeavesTheMainThread() = runBlocking {
        val mainLooper = android.os.Looper.getMainLooper().thread
        var ranOn: Thread? = null

        withContext(Dispatchers.Main) {
            assertEquals("precondition: we must be on main to prove we left it",
                mainLooper, Thread.currentThread())
            MediaProcessing.processing { ranOn = Thread.currentThread() }
        }

        assertTrue("processing{} must not execute on the main thread — that is the ANR",
            ranOn !== mainLooper)
    }

    /** A throwing encode must not strand the spinner on screen forever. */
    @Test
    fun theCounterIsReleasedEvenWhenTheEncodeThrows() = runBlocking {
        withContext(Dispatchers.Main) { assertEquals(0, MediaProcessing.inFlight) }
        try {
            MediaProcessing.processing { throw IllegalStateException("codec died") }
        } catch (_: IllegalStateException) {
        }
        withContext(Dispatchers.Main) {
            assertEquals("a failed encode must not leave the card up", 0, MediaProcessing.inFlight)
            assertFalse(MediaProcessing.isBusy)
        }
    }

    /** The picker takes up to 8 items in sequence; the card must survive the whole run. */
    @Test
    fun theCounterHoldsAcrossOverlappingEncodes() = runBlocking {
        val seen = mutableListOf<Int>()
        withContext(Dispatchers.Main) { assertEquals(0, MediaProcessing.inFlight) }
        MediaProcessing.processing {
            withContext(Dispatchers.Main) { seen.add(MediaProcessing.inFlight) }
            MediaProcessing.processing {
                withContext(Dispatchers.Main) { seen.add(MediaProcessing.inFlight) }
            }
        }
        assertEquals("nested encodes must count, not toggle", listOf(1, 2), seen)
        withContext(Dispatchers.Main) { assertEquals(0, MediaProcessing.inFlight) }
    }
}
