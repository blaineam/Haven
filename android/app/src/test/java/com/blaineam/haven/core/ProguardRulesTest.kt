package com.blaineam.haven.core

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The release build is R8-minified, and a few things find classes by NAME at runtime. R8 can't see
 * those lookups, so proguard-rules.pro has to name them — and a list kept by hand drifts. These
 * checks fail the JVM suite the moment a by-name lookup gains an entry the rules don't cover.
 */
class ProguardRulesTest {

    /** Gradle runs unit tests with the module (android/app) as the working directory. */
    private val rules: String by lazy {
        val f = listOf(File("proguard-rules.pro"), File("app/proguard-rules.pro")).first { it.isFile }
        f.readText()
    }

    @Test fun every_compose_state_holder_keeps_its_name() {
        // ComposeStateHolders.initOnMain() does Class.forName("com.blaineam.haven.core.$name"); a
        // renamed class makes that silently fail and brings back the off-main state-creation crash.
        val missing = ComposeStateHolders.CLASSES.filter { name ->
            !Regex("""(?m)^-keep(names)?\s+class\s+com\.blaineam\.haven\.core\.${Regex.escape(name)}\b""").containsMatchIn(rules)
        }
        assertTrue("proguard-rules.pro is missing -keepnames for: $missing", missing.isEmpty())
    }

    @Test fun jna_and_uniffi_lookups_are_kept() {
        for (needle in listOf(
            "-keep class com.sun.jna.** { *; }",
            "-keep class * extends com.sun.jna.Structure { *; }",
            "-keep interface * extends com.sun.jna.Callback { *; }",
            "-keep class * implements com.sun.jna.Callback { *; }",
            "-keep class uniffi.haven_ffi.UniffiLib { *; }",
            "-keep class com.blaineam.haven.core.NativeBridge",
            "-keep class com.blaineam.haven.core.SyncWorker",
        )) assertTrue("proguard-rules.pro lost: $needle", rules.contains(needle))
    }
}
