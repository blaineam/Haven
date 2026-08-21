package com.blaineam.haven.ui

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Android's `%d` formatter takes an `Integer`. A Kotlin `UInt` BOXES as `kotlin.UInt`, which is not
 * an `Integer`, so `Resources.getString(id, uintValue)` throws `IllegalFormatConversionException` —
 * at render time, on the device, with no compiler warning anywhere, because `stringResource` and
 * `getString` both take `vararg Any`.
 *
 * uniffi maps every Rust `u32`/`u64` to `UInt`/`ULong`, so any FFI count handed straight to a
 * format string is a latent crash. One did ship: `CircleScreen`'s switcher rendered
 * `circle_name_member_count` with `CircleFfi.memberCount`, and opening the circle dropdown killed
 * the app instantly and repeatedly — "Haven is not responding on nearly every launch", and every
 * post that arrived while it was dead went unread.
 *
 * The type system cannot catch this, so the source is scanned instead: no unsigned FFI field may
 * appear as an argument to a format-string call. Add `.toInt()` / `.toLong()` at the call site.
 */
class FormatArgTypeTest {

    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/main/java").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return d
    }

    /** Field names the uniffi bindings declare as unsigned — read from the generated source. */
    private fun unsignedFfiFields(bindings: File): Set<String> =
        Regex("""var `([A-Za-z0-9_]+)`: kotlin\.(?:UInt|ULong|UByte|UShort)""")
            .findAll(bindings.readText())
            .map { it.groupValues[1] }
            .toSet()

    @Test
    fun `no unsigned ffi value is handed to a format string`() {
        val root = repoRoot()
        val bindings = File(root, "android/app/src/main/java/uniffi/haven_ffi/haven_ffi.kt")
        assertTrue("generated uniffi bindings are missing: $bindings", bindings.isFile)

        val unsigned = unsignedFfiFields(bindings)
        assertTrue("expected the bindings to declare SOME unsigned fields; the scan is vacuous otherwise",
                   unsigned.isNotEmpty())

        // Only calls that actually format: `stringResource(R.string.x, …)` / `getString(R.string.x, …)`
        // / `String.format(…)`. A bare one-argument lookup has no format args and cannot throw.
        val formatCall = Regex("""(?:stringResource|getString)\(\s*R\.string\.[A-Za-z0-9_]+\s*,|String\.format\(""")
        val offenders = mutableListOf<String>()

        File(root, "android/app/src/main/java/com/blaineam/haven").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .forEach { f ->
                f.readLines().forEachIndexed { i, line ->
                    if (!formatCall.containsMatchIn(line)) return@forEachIndexed
                    for (field in unsigned) {
                        // `.field` used as a value, NOT already converted.
                        val used = Regex("""\.$field\b(?!\s*\.\s*to(?:Int|Long|String)\b)""")
                        if (used.containsMatchIn(line)) {
                            offenders += "${f.relativeTo(root)}:${i + 1}  .$field  ->  ${line.trim()}"
                        }
                    }
                }
            }

        assertTrue(
            "unsigned FFI value(s) passed to a format string — these throw " +
                "IllegalFormatConversionException at render time. Convert with .toInt()/.toLong():\n" +
                offenders.joinToString("\n"),
            offenders.isEmpty(),
        )
    }
}
