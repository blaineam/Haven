package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.zip.ZipInputStream

/**
 * Small encoders the seedless invite link and the demo/share paths lean on. They are private to their
 * files, so they are reached by reflection; each is pinned to an external reference (RFC 4648 vectors,
 * the zip format) rather than to its own output.
 */
class AccountLinkEncodingTest {
    private fun top(cls: String, name: String, vararg args: Any?): Any? {
        val m = Class.forName(cls).declaredMethods.first { it.name == name && it.parameterCount == args.size }
        m.isAccessible = true
        return try { m.invoke(null, *args) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }
    private fun base32(s: String) = top("com.blaineam.haven.core.HavenCoreKt", "base32NoPad", s.toByteArray()) as String

    @Test fun base32_matches_the_rfc4648_vectors_without_padding() {
        assertEquals("", base32(""))
        assertEquals("MY", base32("f"))
        assertEquals("MZXQ", base32("fo"))
        assertEquals("MZXW6", base32("foo"))
        assertEquals("MZXW6YQ", base32("foob"))
        assertEquals("MZXW6YTB", base32("fooba"))
        assertEquals("MZXW6YTBOI", base32("foobar"))
    }

    @Test fun a_32_byte_id_encodes_to_52_characters_of_the_alphabet() {
        val s = top("com.blaineam.haven.core.HavenCoreKt", "base32NoPad", ByteArray(32) { it.toByte() }) as String
        assertEquals(52, s.length)
        assertTrue(s.all { it in 'A'..'Z' || it in '2'..'7' })
    }

    @Test fun hex_decodes_pairs_and_refuses_an_odd_length() {
        assertArrayEquals(byteArrayOf(0, 0x0f, 0xff.toByte(), 0x80.toByte()),
            top("com.blaineam.haven.core.HavenCoreKt", "hexToBytes", "000fff80") as ByteArray)
        assertArrayEquals(ByteArray(0), top("com.blaineam.haven.core.HavenCoreKt", "hexToBytes", "") as ByteArray)
        try { top("com.blaineam.haven.core.HavenCoreKt", "hexToBytes", "abc"); fail("odd length must be refused") }
        catch (e: IllegalArgumentException) { assertEquals("odd-length hex", e.message) }
    }

    @Test fun the_demo_seed_bytes_are_deterministic_and_wrap_at_256() {
        val m = DemoSeeder::class.java.getDeclaredMethod("seedData", Int::class.javaPrimitiveType).apply { isAccessible = true }
        val a = m.invoke(DemoSeeder, 7) as ByteArray
        assertEquals(32, a.size)
        assertEquals(7.toByte(), a[0]); assertEquals(38.toByte(), a[31])
        assertArrayEquals(a, m.invoke(DemoSeeder, 7) as ByteArray)
        val w = m.invoke(DemoSeeder, 250) as ByteArray
        assertEquals("wraps past 0xFF", 0.toByte(), w[6])
    }

    @Test fun a_demo_ago_stamp_counts_back_from_now_and_never_goes_negative() {
        // ULong return: the compiled method name is mangled and the value comes back as a plain long.
        val m = DemoSeeder::class.java.declaredMethods.first { it.name.startsWith("msAgo") }.apply { isAccessible = true }
        val before = System.currentTimeMillis()
        val t = m.invoke(DemoSeeder, 10) as Long
        val after = System.currentTimeMillis()
        assertTrue(t in (before - 600_000 - 1)..(after - 600_000 + 1))
        assertEquals("an absurd age floors at the epoch", 0L, m.invoke(DemoSeeder, Int.MAX_VALUE / 30) as Long)
    }

    @Test fun a_shared_file_is_wrapped_in_a_zip_that_keeps_its_name_and_bytes() {
        val act = sun.misc.Unsafe::class.java.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
            .let { it as sun.misc.Unsafe }.allocateInstance(Class.forName("com.blaineam.haven.MainActivity"))
        val m = act.javaClass.getDeclaredMethod("zipped", String::class.java, ByteArray::class.java).apply { isAccessible = true }
        val payload = ByteArray(5000) { (it * 31).toByte() }
        val zip = m.invoke(act, "notes.final.txt", payload) as ByteArray
        ZipInputStream(zip.inputStream()).use { zin ->
            val e = zin.nextEntry!!
            assertEquals("notes.final.txt", e.name)
            assertArrayEquals(payload, zin.readBytes())
            assertEquals(null, zin.nextEntry)
        }
    }
}
