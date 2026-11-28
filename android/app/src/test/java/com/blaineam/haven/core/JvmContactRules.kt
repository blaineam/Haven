package com.blaineam.haven.core

import org.json.JSONObject

/** Stands in for the core's contact rules in JVM tests, which cannot load it. It reads only this
 *  app's own spelling; the rules themselves are tested in the core, and through the real core on an
 *  emulator (`ContactSyncInstrumentedTest`). */
internal object JvmContactRules : ContactRules {
    override fun read(record: ByteArray): Contact? = runCatching {
        val o = JSONObject(String(record, Charsets.UTF_8))
        Contact(o.getString("id_hex"), o.optString("name", ""), o.optString("verify", ""))
    }.getOrNull()

    override fun fold(local: ByteArray, base: ByteArray?): ByteArray? = if (local.contentEquals(base)) null else local

    override fun mayTombstone(base: ByteArray?): Boolean = base != null && read(base) != null
}
