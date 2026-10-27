package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The privacy + ordering rules of the Android Auto Messages tab ([CarConversations]) — docs/CAR-PARITY.md. */
class CarConversationsTest {
    private val generic = "New message"

    private fun msg(text: String, ts: Long, fromMe: Boolean = false, read: Boolean = false, who: String = "tracy") =
        CarConversations.Msg(senderKey = who, senderName = who.replaceFirstChar { it.uppercase() }, text = text, timestampMs = ts, fromMe = fromMe, read = read || fromMe)

    private fun thread(id: String, title: String, vararg m: CarConversations.Msg, locked: Boolean = false, group: Boolean = false, hex: String? = "hex-$id") =
        CarConversations.Thread(id, title, if (group) null else hex, group, locked, m.toList())

    private fun rows(threads: List<CarConversations.Thread>, detail: String = "full", on: Boolean = true, max: Int = 10) =
        CarConversations.rows(threads, detail, on, generic, max)

    @Test fun `the switch off hands the host nothing`() {
        assertTrue(rows(listOf(thread("dm:a", "Tracy", msg("hi", 1))), on = false).isEmpty())
    }

    @Test fun `only DM threads are listed`() {
        val rows = rows(listOf(thread("c-circle", "My Circle", msg("post", 1)), thread("dm:a", "Tracy", msg("hi", 2))))
        assertEquals(listOf("dm:a"), rows.map { it.circleId })
    }

    @Test fun `a locked conversation is omitted entirely - not even its name is offered`() {
        val rows = rows(listOf(thread("dm:a", "Tracy", msg("secret", 1), locked = true), thread("dm:b", "Troy", msg("hi", 2))))
        assertEquals(listOf("dm:b"), rows.map { it.circleId })
        assertFalse(rows.any { r -> r.title == "Tracy" || r.messages.any { it.text.contains("secret") } })
    }

    @Test fun `full detail hands over the real texts oldest first and caps them at five`() {
        val ms = (1..8).map { msg("m$it", it.toLong() * 10) }.toTypedArray()
        val r = rows(listOf(thread("dm:a", "Tracy", *ms))).single()
        assertFalse(r.redacted)
        assertEquals(listOf("m4", "m5", "m6", "m7", "m8"), r.messages.map { it.text })
    }

    @Test fun `private and minimal never let a real text reach the host`() {
        for (level in listOf("private", "minimal")) {
            val r = rows(listOf(thread("dm:a", "Tracy", msg("my bank pin is 1234", 5), msg("call me", 6))), detail = level).single()
            assertTrue(r.redacted)
            assertEquals(listOf(generic), r.messages.map { it.text })
            assertFalse(r.messages.any { it.text.contains("1234") || it.text.contains("call me") })
            assertEquals("the unread count survives redaction", 2, r.unread)
            assertFalse("an unread thread reads as unread", r.messages.single().read)
        }
    }

    @Test fun `an unknown detail level is treated as redacted not as full`() {
        val r = rows(listOf(thread("dm:a", "Tracy", msg("hello", 1))), detail = "").single()
        assertTrue(r.redacted)
    }

    @Test fun `a redacted group thread does not leak sender names`() {
        val r = rows(listOf(thread("dm:g", "Tracy, Troy", msg("x", 1, who = "tracy"), msg("y", 2, who = "troy"), group = true)), detail = "minimal").single()
        assertTrue(r.isGroup)
        assertEquals("Tracy, Troy", r.messages.single().senderName)   // the conversation title, never a per-message sender
    }

    @Test fun `unread counts only incoming messages past the watermark`() {
        val r = rows(listOf(thread("dm:a", "Tracy", msg("old", 1, read = true), msg("mine", 2, fromMe = true), msg("new1", 3), msg("new2", 4)))).single()
        assertEquals(2, r.unread)
    }

    @Test fun `newest conversation first, ties by title then id`() {
        val rows = rows(listOf(
            thread("dm:a", "Tracy", msg("a", 10)), thread("dm:b", "Troy", msg("b", 30)),
            thread("dm:c", "Amy", msg("c", 10)),
        ))
        assertEquals(listOf("dm:b", "dm:c", "dm:a"), rows.map { it.circleId })
    }

    @Test fun `empty or blank-only threads are not rows - the library rejects an empty message list`() {
        val rows = rows(listOf(thread("dm:a", "Tracy"), thread("dm:b", "Troy", msg("  ", 1)), thread("dm:c", "Amy", msg("hi", 2))))
        assertEquals(listOf("dm:c"), rows.map { it.circleId })
        assertTrue(rows.all { it.messages.isNotEmpty() })
    }

    @Test fun `duplicate threads collapse and the host limit is respected`() {
        val ts = (1..15).map { thread("dm:$it", "P$it", msg("x", it.toLong())) } + thread("dm:1", "P1 again", msg("y", 99))
        val out = rows(ts, max = 4)
        assertEquals(4, out.size)
        assertEquals(out.size, out.map { it.circleId }.toSet().size)
        assertEquals(CarConversations.MAX_THREADS, rows(ts, max = 500).size)
        assertEquals(1, rows(ts, max = 0).size)
    }

    @Test fun `my own messages are listed as mine and never count unread`() {
        val r = rows(listOf(thread("dm:a", "Tracy", msg("hi tracy", 1, fromMe = true)))).single()
        assertTrue(r.messages.single().fromMe)
        assertEquals(0, r.unread)
    }

    @Test fun `the Messages tab needs the switch and API level 7`() {
        assertTrue(CarConversations.tabVisible(7, true))
        assertTrue(CarConversations.tabVisible(9, true))
        assertFalse(CarConversations.tabVisible(6, true))
        assertFalse(CarConversations.tabVisible(7, false))
    }

    @Test fun `a thread id is a dm circle id like the notification path`() {
        assertTrue(CarConversations.isDmThread("dm:abc"))
        assertFalse(CarConversations.isDmThread("default"))
        assertEquals(CarMessaging.isDm("dm:x"), CarConversations.isDmThread("dm:x"))
    }
}
