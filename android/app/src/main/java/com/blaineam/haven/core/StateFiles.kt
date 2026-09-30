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
 */
object StateFiles {
    fun writeAtomic(target: File, bytes: ByteArray) {
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
