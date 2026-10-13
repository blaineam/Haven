package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/** The one-shot "forget burned mailbox keys" repairs: what each forgets, what it keeps, and that it runs once. */
class HavenNetSeenRepairTest {
    private lateinit var ctx: FakeContext
    private val net = HavenNet::class.java
    private fun field(n: String) = net.getDeclaredField(n).apply { isAccessible = true }
    private fun call(n: String) = net.declaredMethods.first { it.name == n && it.parameterCount == 0 }
        .apply { isAccessible = true }.invoke(HavenNet)
    @Suppress("UNCHECKED_CAST") private val seen get() = field("seenMailbox").get(HavenNet) as MutableSet<String>
    private val file get() = File(ctx.filesDir, "haven_mailbox_seen.txt")
    private val prefs get() = ctx.prefs("haven.contacts")

    private val dm = "haven/c/dm:abc/1"
    private val live = "haven/c/dm:abc/__live__/9"
    private val hello = "haven/c/__hello__/5"
    private val feed = "haven/c/feed/7"

    @Before fun setUp() {
        ctx = FakeContext()
        field("appContext").set(HavenNet, ctx)
        field("seenMailboxLoaded").set(HavenNet, true)   // don't read a stale file; we seed the set directly
        seen.clear(); seen.addAll(listOf(dm, live, hello, feed))
    }
    @After fun tearDown() { seen.clear(); field("seenMailboxLoaded").set(HavenNet, false); ctx.filesDir.deleteRecursively() }

    @Test fun the_dm_and_hello_repair_forgets_dm_content_and_hellos_but_keeps_live_frames_and_other_circles() {
        call("repairMailboxSeenOnce")
        assertEquals(setOf(live, feed), seen.toSet())
        assertEquals(setOf(live, feed), file.readLines().toSet())   // persisted, so a relaunch agrees
        assertTrue(prefs.getBoolean("haven.repair.mailboxSeen.v1", false))
        assertTrue(prefs.getBoolean("haven.repair.helloSeen.v1", false))
    }

    @Test fun the_repair_runs_once_so_later_keys_are_not_forgotten() {
        call("repairMailboxSeenOnce")
        seen.add(dm); seen.add(hello)
        call("repairMailboxSeenOnce")
        assertTrue(seen.containsAll(listOf(dm, hello)))
    }

    @Test fun the_storm_burn_repair_clears_everything_except_live_call_lanes_once() {
        call("repairStormBurnedSeenOnce")
        assertEquals(setOf(live), seen.toSet())
        assertEquals(listOf(live), file.readLines())
        seen.add(feed)
        call("repairStormBurnedSeenOnce")
        assertTrue(feed in seen)
        assertTrue(prefs.getBoolean("haven.repair.stormBurnedSeen.v1", false))
    }
}
