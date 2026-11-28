package com.blaineam.haven

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.blaineam.haven.core.Contact
import com.blaineam.haven.core.SelfSyncWire
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** `contact:` records between this app and the iPhone's and desktop's, through the real core. */
@RunWith(AndroidJUnit4::class)
class ContactSyncInstrumentedTest {
    // What Apple's JSONEncoder writes, and what a desktop app before the shared rules wrote.
    private val iphone = """{"idHex":"ab","name":"Hand Shake","authoritativeName":"Signed Name","verificationHex":"vv","avatarB64":"/9j/4AAQ"}""".toByteArray()
    private val desktop = """{"id_hex":"ab","name":"Signed Name","verify_hex":"vv","emoji":"","avatar":"","bio":"","link":""}""".toByteArray()
    private val mine = Contact("ab", "Signed Name", "vv")

    @Test fun an_iphones_and_a_desktops_contact_decode() {
        assertEquals(mine, SelfSyncWire.decodeContact(iphone))
        assertEquals(mine, SelfSyncWire.decodeContact(desktop))
        assertNull(SelfSyncWire.decodeContact("{\"future\":1}".toByteArray()))
    }

    @Test fun what_this_app_publishes_an_iphone_can_read_and_another_spelling_is_left_alone() {
        val own = SelfSyncWire.encodeContact(mine)
        val stamp = SelfSyncWire.valueToStamp("contact:ab", own, null)
        assertNotNull(stamp)
        val o = JSONObject(String(stamp!!))
        assertEquals("ab", o.getString("idHex"))
        assertEquals("Signed Name", o.getString("name"))
        assertNull(SelfSyncWire.valueToStamp("contact:ab", own, stamp))
        assertNull(SelfSyncWire.valueToStamp("contact:ab", own, iphone))
    }

    @Test fun a_rename_here_keeps_the_iphones_picture() {
        val renamed = SelfSyncWire.encodeContact(mine.copy(name = "New Name"))
        val stamp = SelfSyncWire.valueToStamp("contact:ab", renamed, iphone)!!
        assertEquals("/9j/4AAQ", JSONObject(String(stamp)).getString("avatarB64"))
        assertEquals("New Name", SelfSyncWire.decodeContact(stamp)!!.name)
    }

    @Test fun a_record_nothing_can_read_is_not_published_as_removed() {
        assertFalse(SelfSyncWire.mayTombstone("contact:ab", "{\"future\":1}".toByteArray()))
        assertTrue(SelfSyncWire.mayTombstone("contact:ab", iphone))
    }
}
