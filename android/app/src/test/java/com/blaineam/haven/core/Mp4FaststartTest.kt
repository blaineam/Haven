package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

/**
 * [Mp4Faststart] rewrites container bytes, so it gets a real test rather than "it compiled".
 *
 * These build MP4s by hand — small, but structurally honest ones: correct box headers, a real
 * `moov/trak/mdia/minf/stbl/stco` nest, and chunk offsets that genuinely point at the sample bytes
 * inside `mdat`. The central assertion is not "it produced output" but "the offsets still point at
 * the same bytes afterwards", which is the only thing that makes the file playable.
 */
class Mp4FaststartTest {

    // ---- builders ---------------------------------------------------------------------------

    private fun box(type: String, payload: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        val size = 8 + payload.size
        out.write(byteArrayOf(
            ((size shr 24) and 0xFF).toByte(), ((size shr 16) and 0xFF).toByte(),
            ((size shr 8) and 0xFF).toByte(), (size and 0xFF).toByte()))
        out.write(type.toByteArray(Charsets.US_ASCII))
        out.write(payload)
        return out.toByteArray()
    }

    private fun u32(v: Int) = byteArrayOf(
        ((v shr 24) and 0xFF).toByte(), ((v shr 16) and 0xFF).toByte(),
        ((v shr 8) and 0xFF).toByte(), (v and 0xFF).toByte())

    private fun stco(offsets: List<Int>): ByteArray {
        val p = ByteArrayOutputStream()
        p.write(u32(0))                 // version + flags
        p.write(u32(offsets.size))      // entry_count
        offsets.forEach { p.write(u32(it)) }
        return box("stco", p.toByteArray())
    }

    private fun co64(offsets: List<Long>): ByteArray {
        val p = ByteArrayOutputStream()
        p.write(u32(0))
        p.write(u32(offsets.size))
        offsets.forEach { o -> p.write(java.nio.ByteBuffer.allocate(8).putLong(o).array()) }
        return box("co64", p.toByteArray())
    }

    private fun moovWrapping(offsetBox: ByteArray): ByteArray =
        box("moov", box("trak", box("mdia", box("minf", box("stbl", offsetBox)))))

    private fun cat(vararg parts: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        parts.forEach { out.write(it) }
        return out.toByteArray()
    }

    /** Read a u32 at an absolute file offset. */
    private fun readU32(b: ByteArray, p: Int): Long =
        ((b[p].toLong() and 0xFF) shl 24) or ((b[p + 1].toLong() and 0xFF) shl 16) or
            ((b[p + 2].toLong() and 0xFF) shl 8) or (b[p + 3].toLong() and 0xFF)

    /** Absolute offset of the first `stco` entry in a file, found by walking to the box. */
    private fun firstStcoEntry(file: ByteArray): Long {
        val at = indexOfType(file, "stco")
        return readU32(file, at + 8 + 4 + 4)   // header + version/flags + entry_count
    }

    private fun indexOfType(b: ByteArray, type: String): Int {
        val t = type.toByteArray(Charsets.US_ASCII)
        for (i in 0..b.size - 8) {
            if (b[i + 4] == t[0] && b[i + 5] == t[1] && b[i + 6] == t[2] && b[i + 7] == t[3]) return i
        }
        error("no $type box")
    }

    private fun typeAt(b: ByteArray, p: Int) = String(b, p + 4, 4, Charsets.US_ASCII)

    // ---- tests ------------------------------------------------------------------------------

    /** The case that matters: MediaMuxer's output, with `moov` stranded at the end. */
    @Test
    fun `moov after mdat is moved to the front and offsets follow it`() {
        val ftyp = box("ftyp", "isom".toByteArray())
        val payload = ByteArray(64) { (it and 0xFF).toByte() }
        val mdat = box("mdat", payload)
        val mdatPayloadAt = ftyp.size + 8              // where the samples actually start
        val moov = moovWrapping(stco(listOf(mdatPayloadAt)))
        val src = cat(ftyp, mdat, moov)

        // Precondition: the offset really does point at the sample bytes.
        assertEquals(payload[0], src[firstStcoEntry(src).toInt()])

        val out = Mp4Faststart.relocate(src)!!

        assertEquals("length must be preserved exactly", src.size, out.size)
        assertEquals("ftyp stays first", "ftyp", typeAt(out, 0))
        assertEquals("moov comes second", "moov", typeAt(out, ftyp.size))
        assertEquals("mdat follows moov", "mdat", typeAt(out, ftyp.size + moov.size))

        // THE assertion: the chunk offset still lands on the same sample byte in the new layout.
        val newEntry = firstStcoEntry(out).toInt()
        assertEquals(mdatPayloadAt + moov.size, newEntry)
        assertArrayEquals(payload, out.copyOfRange(newEntry, newEntry + payload.size))
    }

    @Test
    fun `64-bit co64 offsets are shifted too`() {
        val ftyp = box("ftyp", "isom".toByteArray())
        val payload = ByteArray(32) { 7 }
        val mdat = box("mdat", payload)
        val mdatPayloadAt = (ftyp.size + 8).toLong()
        val moov = moovWrapping(co64(listOf(mdatPayloadAt)))
        val src = cat(ftyp, mdat, moov)

        val out = Mp4Faststart.relocate(src)!!
        val at = indexOfType(out, "co64")
        val entry = java.nio.ByteBuffer.wrap(out, at + 8 + 4 + 4, 8).long
        assertEquals(mdatPayloadAt + moov.size, entry)
        assertEquals(payload[0], out[entry.toInt()])
    }

    /** Already streamable — rewriting would only risk breaking a correct file. */
    @Test
    fun `a file that is already faststart is left alone`() {
        val ftyp = box("ftyp", "isom".toByteArray())
        val moov = moovWrapping(stco(listOf(999)))
        val mdat = box("mdat", ByteArray(16))
        assertNull(Mp4Faststart.relocate(cat(ftyp, moov, mdat)))
    }

    @Test
    fun `a file with no moov or no mdat is refused rather than guessed at`() {
        val ftyp = box("ftyp", "isom".toByteArray())
        assertNull(Mp4Faststart.relocate(cat(ftyp, box("mdat", ByteArray(8)))))
        assertNull(Mp4Faststart.relocate(cat(ftyp, moovWrapping(stco(listOf(1))))))
    }

    /**
     * Fail closed on damage. A truncated or nonsensical box must return null so the caller keeps the
     * muxer's bytes — silently emitting a "repaired" file would be the worst possible outcome.
     */
    @Test
    fun `malformed input is refused, never half-rewritten`() {
        val ftyp = box("ftyp", "isom".toByteArray())
        val mdat = box("mdat", ByteArray(16))
        val moov = moovWrapping(stco(listOf(24)))
        val good = cat(ftyp, mdat, moov)

        assertNull("truncated file", Mp4Faststart.relocate(good.copyOfRange(0, good.size - 5)))

        val zeroSize = good.copyOf()
        zeroSize[0] = 0; zeroSize[1] = 0; zeroSize[2] = 0; zeroSize[3] = 3   // size < 8
        assertNull("absurd box size", Mp4Faststart.relocate(zeroSize))

        assertNull("empty", Mp4Faststart.relocate(ByteArray(0)))
        assertNull("garbage", Mp4Faststart.relocate(ByteArray(32) { 0xAB.toByte() }))
    }

    /**
     * A blind scan for the four bytes "stco" would corrupt any file whose sample data happens to
     * contain them. The walk is structural, so this must survive untouched.
     */
    @Test
    fun `sample data that spells stco is not mistaken for a real box`() {
        val ftyp = box("ftyp", "isom".toByteArray())
        val trap = "stco".toByteArray(Charsets.US_ASCII)
        val payload = ByteArray(64).also { trap.copyInto(it, 20) }
        val mdat = box("mdat", payload)
        val mdatPayloadAt = ftyp.size + 8
        val moov = moovWrapping(stco(listOf(mdatPayloadAt)))
        val src = cat(ftyp, mdat, moov)

        val out = Mp4Faststart.relocate(src)!!
        val newEntry = firstStcoEntry(out).toInt()
        assertArrayEquals("payload must be byte-identical", payload,
            out.copyOfRange(newEntry, newEntry + payload.size))
        assertTrue("the decoy bytes survive", out.copyOfRange(newEntry + 20, newEntry + 24)
            .contentEquals(trap))
    }

    /** Multiple chunks, the realistic case — every entry moves by the same delta. */
    @Test
    fun `every chunk offset in the table is shifted`() {
        val ftyp = box("ftyp", "isom".toByteArray())
        val payload = ByteArray(120) { (it and 0xFF).toByte() }
        val mdat = box("mdat", payload)
        val base = ftyp.size + 8
        val offsets = listOf(base, base + 30, base + 60, base + 90)
        val moov = moovWrapping(stco(offsets))
        val src = cat(ftyp, mdat, moov)

        val out = Mp4Faststart.relocate(src)!!
        val at = indexOfType(out, "stco") + 8 + 4
        assertEquals(offsets.size.toLong(), readU32(out, at))
        offsets.forEachIndexed { i, o ->
            assertEquals("entry $i", (o + moov.size).toLong(), readU32(out, at + 4 + i * 4))
        }
    }
}
