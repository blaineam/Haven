package com.blaineam.haven.core

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.provider.MediaStore

/**
 * Saves media to the device gallery (Photos), the Android counterpart of iOS's "Save to Photos".
 * Uses MediaStore with a relative path + IS_PENDING, so on API 29+ (our minSdk) it needs NO runtime
 * permission. Files land in Pictures/Haven and Movies/Haven and dedupe by content hash so auto-save
 * never writes the same item twice.
 */
object MediaSaver {
    private val savedHashes = SharedCollections.set()   // session-level dedupe for auto-save (media lands on IO)

    /** Save [bytes] to the gallery. Returns true on success. */
    fun save(context: Context, bytes: ByteArray, isVideo: Boolean): Boolean = runCatching {
        val cr = context.applicationContext.contentResolver
        val stamp = System.currentTimeMillis()
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, if (isVideo) "haven_$stamp.mp4" else "haven_$stamp.jpg")
            put(MediaStore.MediaColumns.MIME_TYPE, if (isVideo) "video/mp4" else "image/jpeg")
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, if (isVideo) "Movies/Haven" else "Pictures/Haven")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val collection = if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val uri = cr.insert(collection, values) ?: return@runCatching false
        cr.openOutputStream(uri)?.use { it.write(bytes) } ?: return@runCatching false
        if (Build.VERSION.SDK_INT >= 29) {
            values.clear(); values.put(MediaStore.MediaColumns.IS_PENDING, 0); cr.update(uri, values, null, null)
        }
        true
    }.getOrDefault(false)

    /** Auto-save a media ref once (dedup by ref), loading + decrypting its bytes from any circle. */
    fun autoSave(context: Context, ref: String) {
        if (!savedHashes.add(ref)) return
        val bytes = LocalMedia.loadAnyCircle(ref) ?: run { savedHashes.remove(ref); return }
        if (!save(context, bytes, LocalMedia.isVideo(ref))) savedHashes.remove(ref)
    }
}
