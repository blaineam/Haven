package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.blaineam.haven.core.DeepLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A link we can emit but not re-open would be worse than none — so every case here goes out through
 * `postUrl` and back in through the real `parsePost`. Instrumented, not a unit test: `parsePost`
 * leans on `android.net.Uri`, which is a no-op stub off-device.
 */
@RunWith(AndroidJUnit4::class)
class DeepLinkInstrumentedTest {

    private fun roundTrip(circleId: String, postId: String) {
        val url = DeepLink.postUrl(circleId, postId)
        assertNotNull("no link emitted for $circleId / $postId", url)
        val back = DeepLink.parsePost(url)
        assertNotNull("emitted a link our own parser rejects: $url", back)
        assertEquals(circleId, back!!.circleId)
        assertEquals(postId, back.postId)
    }

    @Test fun plain_ids_round_trip() =
        roundTrip("default", "4a8befcbc6ecd7332c0a433d92e5117c")

    /** The reason the emitter can't use `Uri.encode`: its unreserved set keeps `.` literal, which
     *  would slide the `<circle>.<post>` split and hand the parser the wrong circle. */
    @Test fun dotted_ids_do_not_move_the_split() =
        roundTrip("my.circle.v2", "post.42")

    /** `/` would end the fragment's first segment; `#` would start a second fragment. */
    @Test fun delimiter_chars_round_trip() =
        roundTrip("a/b#c", "d/e#f")

    @Test fun unicode_ids_round_trip() = roundTrip("círculo 🏠", "posté")

    @Test fun payload_rides_the_fragment_so_the_host_never_sees_it() {
        val url = DeepLink.postUrl("default", "abc123")!!
        // Everything before '#' is what wemiller.com's access log would get — it must not name the post.
        val sentToHost = url.substringBefore('#')
        assertEquals("https://wemiller.com/apps/haven/", sentToHost)
        assertTrue("post id leaked outside the fragment: $url", !sentToHost.contains("abc123"))
    }

    @Test fun empty_ids_emit_nothing() {
        assertEquals(null, DeepLink.postUrl("", "abc"))
        assertEquals(null, DeepLink.postUrl("default", ""))
    }
}
