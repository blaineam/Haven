package com.blaineam.haven.core

import java.io.File
import java.io.FileOutputStream

/**
 * Crash-safe writes for the engine state file.
 *
 * `File.writeBytes` truncates first, so a kill mid-write (a crash, the OS reclaiming the process,
 * a force-stop) left an empty or partial state file that the next launch could not import — the
 * whole account's circles, keys and history. Temp file in the same directory, fsync, then rename:
 * a kill at any instant leaves either the old file or the new one. Desktop `store::write_atomic`
 * parity.
 *
 * Writes are SERIALIZED. `persist()` runs on whichever thread touched the engine — an inbound event
 * on an IO worker, a post on the QA/UI path, the upload loop's save-before-send — and they shared one
 * `.tmp-write` name: a second writer truncated the first one's temp mid-write, the first rename then
 * moved a half-written file into place, and the second rename failed outright (e2e 2026-09-30:
 * "rename haven_social_state_….bin.tmp-write → … failed" from handleEvent). [writeAtomicFrom] also
 * takes the snapshot INSIDE the lock, so the file on disk is always the newest export, never an older
 * one that happened to finish renaming last.
 */
object StateFiles {
    private val lock = Any()

    fun writeAtomic(target: File, bytes: ByteArray) = writeAtomicFrom(target) { bytes }

    /** Snapshot with [produce] and write it, both under the write lock. */
    fun writeAtomicFrom(target: File, produce: () -> ByteArray) {
        synchronized(lock) {
            val bytes = produce()
            val tmp = File(target.parentFile, target.name + ".tmp-write")
            FileOutputStream(tmp).use { out ->
                out.write(bytes)
                out.fd.sync()
            }
            if (!tmp.renameTo(target)) {
                tmp.delete()
                throw java.io.IOException("rename ${tmp.name} → ${target.name} failed")
            }
        }
    }
}
