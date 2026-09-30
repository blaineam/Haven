package com.blaineam.haven.core

import java.io.File

/**
 * The QA channel's one write primitive (DEBUG dump + identity files under `filesDir/qa/`).
 *
 * tmp + rename in the SAME dir, so the harness's `run-as cat` sees the old file or the new one,
 * never half of one. Hardened after the 2026-09-30 gate, where the dump froze and the only trace
 * was a one-line message with no cause:
 *  - the parent dir is re-created on every attempt — the harness's recovery wipes the drop files
 *    and an `rm -rf files/qa` must not turn every later dump into FileNotFoundException;
 *  - each attempt uses its own tmp name, so a stale `<name>.tmp` left by a killed process (or one
 *    the harness is deleting at that instant) cannot collide with it;
 *  - a failed attempt is retried ([attempts] total) and every failure is REPORTED with its
 *    exception, so logcat names the cause instead of "failed".
 * Returns null on success, else the last failure.
 */
object QaFiles {
    fun writeAtomically(
        dest: File,
        text: String,
        attempts: Int = 3,
        onFailure: (attempt: Int, error: Throwable) -> Unit = { _, _ -> },
    ): Throwable? {
        var last: Throwable? = null
        for (attempt in 1..attempts.coerceAtLeast(1)) {
            val dir = dest.absoluteFile.parentFile
            val tmp = File(dir, "${dest.name}.${attempt}.${System.nanoTime()}.tmp")
            val r = runCatching {
                dir?.mkdirs()
                tmp.writeText(text)
                if (!tmp.renameTo(dest)) {
                    // A rename refused in place (e.g. dest became a directory): write it directly.
                    // Not atomic, but a frozen channel is worse than one torn read, which the
                    // harness already retries.
                    dest.writeText(text)
                }
            }
            runCatching { if (tmp.exists()) tmp.delete() }
            if (r.isSuccess && dest.isFile) return null
            last = r.exceptionOrNull() ?: IllegalStateException("${dest.path} is not a file after the write")
            onFailure(attempt, last)
            if (attempt < attempts) runCatching { Thread.sleep(50L * attempt) }
        }
        return last
    }
}
