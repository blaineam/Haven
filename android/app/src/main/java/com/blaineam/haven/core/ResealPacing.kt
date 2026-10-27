package com.blaineam.haven.core

/**
 * A global pace for "please re-seal this old blob for me" asks (frame 31 from the quarantine path).
 *
 * A device that joined a circle after its history was sealed holds hundreds or thousands of blobs it
 * can never open (`me_listed=false`: sealed to a recipient list that predates it, under epoch keys it
 * was not handed). Each blob is individually bounded ([HavenNet] cooldown + attempt cap) — but nothing
 * bounded them TOGETHER: one fresh install asked the author for ~180 re-seals in two minutes (734 live
 * puts), and every ask makes the AUTHOR's phone re-read, re-seal and re-upload the whole file. History
 * for a new member should trickle in at a pace the author can afford, not arrive as a stampede.
 *
 * A denied ask is simply not made: it does not consume a try or a cooldown, so the next sweep pass
 * offers it again. Sliding window, thread-safe.
 */
class ResealPacing(private val perWindow: Int = PER_WINDOW, private val windowMs: Long = WINDOW_MS) {
    private val stamps = ArrayDeque<Long>()

    @Synchronized
    fun tryAcquire(nowMs: Long): Boolean {
        while (stamps.isNotEmpty() && nowMs - stamps.first() >= windowMs) stamps.removeFirst()
        if (stamps.size >= perWindow) return false
        stamps.addLast(nowMs)
        return true
    }

    /** Forget every stamp (tests share one process-wide HavenNet; production never calls this). */
    @Synchronized
    fun clear() = stamps.clear()

    companion object {
        /** At most this many re-seal asks per [WINDOW_MS]: 360 an hour, ~8,600 a day — a big history in a
         *  couple of days, a phone-sized load on the author. */
        const val PER_WINDOW = 6
        const val WINDOW_MS = 60_000L
    }
}
