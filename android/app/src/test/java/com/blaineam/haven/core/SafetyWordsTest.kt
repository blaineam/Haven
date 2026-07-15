package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** Locks the safe-words mapping to the iOS SafetyWords so a cross-platform verification matches. */
class SafetyWordsTest {
    @Test fun maps_bytes_to_words_like_ios() {
        // 76-word list; byte % 76 selects. 0x00 -> apple, 0x01 -> amber, 0x4c(76) wraps -> apple.
        assertEquals(listOf("apple", "amber", "anchor", "aspen"), SafetyWords.words("00010203"))
        assertEquals("apple", SafetyWords.words("4c").first())   // 76 % 76 == 0
        assertEquals("amber", SafetyWords.words("4d").first())   // 77 % 76 == 1
    }

    @Test fun takes_first_n_byte_pairs() {
        assertEquals(4, SafetyWords.words("aabbccddeeff0011", count = 4).size)
        assertEquals(3, SafetyWords.words("aabbcc", count = 4).size)
    }

    @Test fun phrase_joins_with_separator() {
        assertEquals("apple · amber", SafetyWords.phrase("0001", count = 2))
    }

    /**
     * Golden vectors produced by RUNNING apple/HavenApp/SafetyWords.swift, not by re-deriving the
     * rule here — a shared misreading of the spec would pass a hand-written test. A mismatch means
     * an Android user and an iPhone user compare different words for one identity, which would
     * teach them to wave through a real MITM warning.
     *
     * Inputs are even-length hex because that is what the shared core emits: both platforms read
     * verification_hex() from p2pcore-ffi, which hex-encodes a fixed-size digest.
     */
    @Test fun matches_ios_golden_vectors() {
        val ios = mapOf(
            "00" to "apple",
            "ff" to "fox",
            "0102030405" to "amber anchor aspen basil",
            "deadbeef" to "topaz deer leaf brook",
            "a1b2c3d4e5f60718" to "bloom finch mint sky",
            "000102030405060708090a0b0c0d0e0f" to "apple amber anchor aspen",
            "abcdef0123456789" to "daisy quail brook amber",
            "4c30224b" to "apple panda honey wren",
        )
        for ((hex, expected) in ios) {
            assertEquals("hex=$hex", expected, SafetyWords.words(hex).joinToString(" "))
        }
    }

    /** iOS uppercases nothing, but a link could still carry either case — both must agree. */
    @Test fun hex_case_does_not_change_words() {
        assertEquals(SafetyWords.words("abcdef0123456789"), SafetyWords.words("ABCDEF0123456789"))
    }
}
