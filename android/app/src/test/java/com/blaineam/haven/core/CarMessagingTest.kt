package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android Auto messaging rules: what may reach the car, and what a reply from it may do. */
class CarMessagingTest {
    private val hexA = "a".repeat(64)
    private val hexB = "b".repeat(64)
    private val hexMe = "c".repeat(64)
    private val dm = "dm:$hexA-$hexMe"
    private val groupDm = "dm:$hexA-$hexB-$hexMe"

    private fun msg(text: String, t: Long = 1_000L, who: String = hexA) =
        CarMessaging.Msg(who, "Maya", text, t)

    private fun input(
        circleId: String = dm, kind: String = "dm", locked: Boolean = false,
        detail: String = "full", carEnabled: Boolean = true,
        messages: List<CarMessaging.Msg> = listOf(msg("hello")),
    ) = CarMessaging.Input(circleId, kind, locked, detail, carEnabled, "Maya, Theo", messages)

    // ---- what is shown on the car ------------------------------------------------------------

    @Test fun `a plain inbound DM at full previews is a car conversation`() {
        val p = CarMessaging.plan(input())
        assertTrue(p is CarMessaging.Plan.Messaging)
        p as CarMessaging.Plan.Messaging
        assertEquals(dm, p.circleId)
        assertFalse(p.isGroup)
        assertNull("a 1:1 thread is titled by its sender, not a conversation title", p.title)
        assertEquals(listOf("hello"), p.messages.map { it.text })
    }

    @Test fun `a group DM is flagged as a group and titled`() {
        val p = CarMessaging.plan(input(circleId = groupDm)) as CarMessaging.Plan.Messaging
        assertTrue(p.isGroup)
        assertEquals("Maya, Theo", p.title)
    }

    @Test fun `private and minimal previews show nothing on the car`() {
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(detail = "private")))
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(detail = "minimal")))
    }

    @Test fun `an unknown preview level fails closed`() {
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(detail = "bogus")))
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(detail = "")))
    }

    @Test fun `a locked circle is never shown even at full previews`() {
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(locked = true)))
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(locked = true, circleId = groupDm)))
    }

    @Test fun `the switch off keeps every message off the car`() {
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(carEnabled = false)))
    }

    @Test fun `calls reactions comments stories and posts never reach the car`() {
        for (kind in listOf("call", "react", "comment", "story", "post", "edit", "unsend", "")) {
            assertEquals(kind, CarMessaging.Plan.Plain, CarMessaging.plan(input(kind = kind)))
        }
    }

    @Test fun `a circle post is not a car conversation even with kind dm`() {
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(circleId = "default")))
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(circleId = "circle-1")))
    }

    @Test fun `no messages means no car notification`() {
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(messages = emptyList())))
        assertEquals(CarMessaging.Plan.Plain, CarMessaging.plan(input(messages = listOf(msg("   ")))))
    }

    @Test fun `messages are ordered oldest first and capped`() {
        val many = (1..10).map { msg("m$it", t = it * 100L) }.reversed()
        val p = CarMessaging.plan(input(messages = many)) as CarMessaging.Plan.Messaging
        assertEquals(CarMessaging.MAX_MESSAGES, p.messages.size)
        assertEquals(listOf("m5", "m6", "m7", "m8", "m9", "m10"), p.messages.map { it.text })
    }

    @Test fun `a locked circle's phone banner is demoted to minimal`() {
        assertEquals("minimal", CarMessaging.effectiveDetail("full", locked = true))
        assertEquals("minimal", CarMessaging.effectiveDetail("private", locked = true))
        assertEquals("full", CarMessaging.effectiveDetail("full", locked = false))
        assertEquals("private", CarMessaging.effectiveDetail("private", locked = false))
        // …and minimal carries neither the sender nor the text.
        val (useName, body) = PushBanner.displayBody("secret text", "Sent you a message", "dm",
            CarMessaging.effectiveDetail("full", locked = true))
        assertFalse(useName)
        assertEquals("New activity", body)
    }

    @Test fun `notification id is stable per conversation and distinct between them`() {
        assertEquals(CarMessaging.notificationId(dm), CarMessaging.notificationId(dm))
        assertNotEquals(CarMessaging.notificationId(dm), CarMessaging.notificationId(groupDm))
    }

    // ---- reply routing -----------------------------------------------------------------------

    @Test fun `a spoken reply to an unlocked DM is sent trimmed`() {
        val r = CarMessaging.routeReply(dm, "  on my way \n", locked = false, carEnabled = true)
        assertEquals(CarMessaging.Reply.Send(dm, "on my way"), r)
    }

    @Test fun `replies are refused when locked disabled empty or not a DM`() {
        assertEquals(CarMessaging.Reply.Reject("locked"), CarMessaging.routeReply(dm, "hi", true, true))
        assertEquals(CarMessaging.Reply.Reject("disabled"), CarMessaging.routeReply(dm, "hi", false, false))
        assertEquals(CarMessaging.Reply.Reject("empty"), CarMessaging.routeReply(dm, "  ", false, true))
        assertEquals(CarMessaging.Reply.Reject("empty"), CarMessaging.routeReply(dm, null, false, true))
        assertEquals(CarMessaging.Reply.Reject("not-a-dm"), CarMessaging.routeReply("default", "hi", false, true))
        assertEquals(CarMessaging.Reply.Reject("not-a-dm"), CarMessaging.routeReply(null, "hi", false, true))
        assertEquals(CarMessaging.Reply.Reject("too-long"),
            CarMessaging.routeReply(dm, "x".repeat(CarMessaging.MAX_REPLY_CHARS + 1), false, true))
    }

    @Test fun `mark read is allowed only for an unlocked DM while enabled`() {
        assertEquals(dm, CarMessaging.routeMarkRead(dm, locked = false, carEnabled = true))
        assertNull(CarMessaging.routeMarkRead(dm, locked = true, carEnabled = true))
        assertNull(CarMessaging.routeMarkRead(dm, locked = false, carEnabled = false))
        assertNull(CarMessaging.routeMarkRead("default", locked = false, carEnabled = true))
        assertNull(CarMessaging.routeMarkRead(null, locked = false, carEnabled = true))
    }

    // ---- execution (the receiver's body) -----------------------------------------------------

    private class Fake(var enabled: Boolean = true, val lockedIds: Set<String> = emptySet(),
                       val failSend: Boolean = false) : CarMessaging.Handlers {
        val events = mutableListOf<String>()
        override fun enabled() = enabled
        override fun locked(circleId: String) = circleId in lockedIds
        override fun send(circleId: String, text: String) {
            if (failSend) error("engine down")
            events += "send:$circleId:$text"
        }
        override fun markRead(circleId: String) { events += "read:$circleId" }
        override fun cancel(circleId: String) { events += "cancel:$circleId" }
        override fun log(message: String) { events += "log" }
    }

    @Test fun `a reply reaches the send path then marks read and clears the notification`() {
        val f = Fake()
        CarMessaging.execute(CarMessaging.ACTION_REPLY, dm, "running late", f)
        assertEquals(listOf("send:$dm:running late", "read:$dm", "cancel:$dm"), f.events)
    }

    @Test fun `a reply to a circle locked after posting is dropped and the notification withdrawn`() {
        val f = Fake(lockedIds = setOf(dm))
        CarMessaging.execute(CarMessaging.ACTION_REPLY, dm, "hi", f)
        assertTrue(f.events.none { it.startsWith("send:") })
        assertTrue(f.events.contains("cancel:$dm"))
    }

    @Test fun `a reply with the switch off sends nothing`() {
        val f = Fake(enabled = false)
        CarMessaging.execute(CarMessaging.ACTION_REPLY, dm, "hi", f)
        assertTrue(f.events.none { it.startsWith("send:") })
    }

    @Test fun `a failed send keeps the notification`() {
        val f = Fake(failSend = true)
        CarMessaging.execute(CarMessaging.ACTION_REPLY, dm, "hi", f)
        assertTrue(f.events.none { it.startsWith("cancel:") || it.startsWith("read:") })
    }

    @Test fun `mark as read advances the watermark and clears the notification`() {
        val f = Fake()
        CarMessaging.execute(CarMessaging.ACTION_MARK_READ, dm, null, f)
        assertEquals(listOf("read:$dm", "cancel:$dm"), f.events)
    }

    @Test fun `mark as read on a locked circle touches nothing but the notification`() {
        val f = Fake(lockedIds = setOf(dm))
        CarMessaging.execute(CarMessaging.ACTION_MARK_READ, dm, null, f)
        assertEquals(listOf("cancel:$dm"), f.events)
    }

    @Test fun `an unknown action is ignored`() {
        val f = Fake()
        CarMessaging.execute("com.example.OTHER", dm, "hi", f)
        assertTrue(f.events.isEmpty())
    }
}
