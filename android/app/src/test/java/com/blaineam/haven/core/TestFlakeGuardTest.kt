package com.blaineam.haven.core

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Keeps the classic flake sources out of the unit-test tree (the owner requires that NO test is flaky):
 *  - `Thread.sleep` — a fixed wait is either too short on a loaded box or slow everywhere; wait on a
 *    condition with a deadline, or use virtual time (`runTest`);
 *  - unseeded randomness (`Random()`, `Math.random()`, `UUID.randomUUID()` driving an assertion) — a seeded
 *    `Random(n)` is fine;
 *  - hard-coded `/tmp` paths shared between runs/forks — use `Files.createTempDirectory`.
 * Scanned from source, like [MainThreadEngineAccessTest].
 */
class TestFlakeGuardTest {
    private fun repoRoot(): File {
        var d = File(System.getProperty("user.dir")!!)
        while (!File(d, "android/app/src/test/java").isDirectory) {
            d = d.parentFile ?: error("cannot locate repo root from ${System.getProperty("user.dir")}")
        }
        return d
    }

    private val tests get() = File(repoRoot(), "android/app/src/test/java")

    private fun offenders(pattern: Regex): List<String> =
        tests.walkTopDown().filter { it.isFile && it.extension == "kt" && it.name != "TestFlakeGuardTest.kt" }.flatMap { f ->
            f.readLines().mapIndexedNotNull { i, l ->
                if (!l.trimStart().startsWith("//") && pattern.containsMatchIn(l)) "${f.name}:${i + 1}: ${l.trim()}" else null
            }
        }.toList()

    @Test fun `no test sleeps for a fixed time`() {
        val o = offenders(Regex("""Thread\s*\.\s*sleep|TimeUnit\.\w+\.sleep|SystemClock\.sleep"""))
        assertTrue("fixed sleeps make tests flaky; wait on a condition with a deadline:\n${o.joinToString("\n")}", o.isEmpty())
    }

    @Test fun `no test uses unseeded randomness`() {
        val o = offenders(Regex("""\bRandom\(\)|Math\.random\(\)|Random\.Default|\bkotlin\.random\.Random\.next"""))
        assertTrue("seed it (Random(42)) so a failure reproduces:\n${o.joinToString("\n")}", o.isEmpty())
    }

    @Test fun `no test writes to a hard-coded tmp path`() {
        val o = offenders(Regex("""File\(\s*"/(private/)?(var/)?tmp"""))
        assertTrue("use Files.createTempDirectory:\n${o.joinToString("\n")}", o.isEmpty())
    }
}
