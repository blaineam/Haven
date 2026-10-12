package com.blaineam.haven.core

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences

/**
 * JVM stand-ins for the two Android objects the stores are built on — a Context that hands out
 * in-memory SharedPreferences (no Robolectric). Each [FakeContext] is one "app install": prefs
 * written through it are visible to a later [FakeContext] built from the same [prefs] map, which is
 * how the tests model a process restart.
 */
class FakePrefs : SharedPreferences {
    val data = LinkedHashMap<String, Any?>()
    var applyCount = 0
    private val listeners = LinkedHashSet<SharedPreferences.OnSharedPreferenceChangeListener>()

    override fun getAll(): MutableMap<String, *> = LinkedHashMap(data)
    override fun getString(key: String, defValue: String?): String? = data[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        (data[key] as? Set<String>)?.toMutableSet() ?: defValues
    override fun getInt(key: String, defValue: Int): Int = data[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long): Long = data[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float): Float = data[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean = data[key] as? Boolean ?: defValue
    override fun contains(key: String): Boolean = data.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener) { listeners.add(l) }
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener) { listeners.remove(l) }

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val staged = LinkedHashMap<String, Any?>()
        private val removals = LinkedHashSet<String>()
        private var clear = false
        override fun putString(key: String, value: String?) = apply { staged[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { staged[key] = values?.toSet() }
        override fun putInt(key: String, value: Int) = apply { staged[key] = value }
        override fun putLong(key: String, value: Long) = apply { staged[key] = value }
        override fun putFloat(key: String, value: Float) = apply { staged[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { staged[key] = value }
        override fun remove(key: String) = apply { removals.add(key); staged.remove(key) }
        override fun clear() = apply { clear = true }
        override fun commit(): Boolean { flush(); return true }
        override fun apply() { flush(); applyCount++ }
        private fun flush() {
            if (clear) data.clear()
            for (k in removals) data.remove(k)
            for ((k, v) in staged) if (v == null) data.remove(k) else data[k] = v
        }
    }
}

class FakeContext(
    val allPrefs: MutableMap<String, FakePrefs> = HashMap(),
    private val files: java.io.File = java.nio.file.Files.createTempDirectory("haven-ctx").toFile(),
) : ContextWrapper(null) {
    override fun getFilesDir(): java.io.File = files
    override fun getCacheDir(): java.io.File = java.io.File(files, "cache").apply { mkdirs() }
    fun prefs(name: String): FakePrefs = allPrefs.getOrPut(name) { FakePrefs() }
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = prefs(name)
    override fun getApplicationContext(): Context = this
}
