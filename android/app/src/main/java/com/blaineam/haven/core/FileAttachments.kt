package com.blaineam.haven.core

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File

/**
 * Opening a `file_` attachment someone sent you — the receiving half of Haven's document support.
 *
 * A `file_` blob is a **ZIP**, always: the ref carries no filename and no type on the wire, so the
 * document's real name and extension only survive inside an archive (Apple's `MediaStore.addFile`
 * and Android's share ingest both wrap on the way in). So opening one means: decrypt, look inside,
 * and hand the system the document rather than the wrapper — Android has no built-in zip viewer, so
 * handing it the `.zip` would be a dead end for the ordinary one-document case.
 *
 * The unwrapped file lands in a cache dir served by our [FileProvider], and the receiving app gets a
 * one-shot read grant. Nothing is written where another app could read it without that grant, and
 * the staged copy is disposable — Android reclaims the cache, and we clear stale entries ourselves.
 */
object FileAttachments {
    /** Where unwrapped attachments are staged for handoff. Matches `res/xml/file_paths.xml`. */
    private const val STAGING = "shared-files"

    /** What a `file_` attachment should be CALLED — the name inside the archive when there's exactly
     *  one, else the archive itself. Cheap: reads the central directory, never the entries. */
    fun displayName(context: Context, circleId: String, ref: String): String {
        val single = singleEntryName(bytes(circleId, ref) ?: return "attachment.zip")
        return single ?: "attachment.zip"
    }

    /**
     * Stage [ref] and open it with whatever app on the device handles it. Returns false when the
     * blob isn't on this device yet, is too large to decrypt here, or nothing can open it — the
     * caller shows the failure rather than this silently doing nothing.
     */
    fun open(context: Context, circleId: String, ref: String): Boolean {
        val uri = stage(context, circleId, ref) ?: return false
        val name = uri.lastPathSegment.orEmpty()
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeOf(name))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        // A chooser rather than a bare ACTION_VIEW: on a device with no handler for this type, an
        // unwrapped ACTION_VIEW throws ActivityNotFoundException, and the user deserves the "share
        // it somewhere that can" fallback instead of a crash or nothing at all.
        return runCatching {
            context.startActivity(Intent.createChooser(view, "Open with")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        }.getOrElse { share(context, uri, name) }
    }

    /** Hand the staged file to another app to keep (Files, Drive, mail) — the fallback when nothing
     *  on the device can VIEW this type, and a useful action in its own right. */
    fun share(context: Context, circleId: String, ref: String): Boolean {
        val uri = stage(context, circleId, ref) ?: return false
        return share(context, uri, uri.lastPathSegment.orEmpty())
    }

    private fun share(context: Context, uri: Uri, name: String): Boolean = runCatching {
        val send = Intent(Intent.ACTION_SEND)
            .setType(mimeOf(name))
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(Intent.createChooser(send, "Share file")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    }.getOrDefault(false)

    // MARK: - Staging

    /** Decrypt, unwrap, and write to the provider-served staging dir. Returns a content:// URI. */
    private fun stage(context: Context, circleId: String, ref: String): Uri? = runCatching {
        val blob = bytes(circleId, ref) ?: return@runCatching null
        val dir = File(context.cacheDir, STAGING).apply { mkdirs() }
        sweep(dir)
        // Ref-scoped subdirectory: two attachments can legitimately hold files with the SAME name,
        // and a flat dir would have the second silently overwrite the first while it was open.
        val slot = File(dir, LocalMedia.bareId(ref).take(16)).apply { mkdirs() }
        val name = singleEntryName(blob)
        val out: File
        if (name != null) {
            out = File(slot, name)
            java.util.zip.ZipInputStream(blob.inputStream()).use { zin ->
                zin.nextEntry ?: return@runCatching null
                out.outputStream().use { zin.copyTo(it) }
            }
        } else {
            out = File(slot, "attachment.zip")
            out.writeBytes(blob)
        }
        FileProvider.getUriForFile(context, "${context.packageName}.files", out)
    }.getOrNull()

    private fun bytes(circleId: String, ref: String): ByteArray? =
        LocalMedia.load(circleId, ref) ?: LocalMedia.loadAnyCircle(ref)

    /**
     * The name of the archive's only entry, or null when it holds anything other than exactly one
     * file (a zipped folder, a multi-file archive, or a blob that isn't a zip at all). Those are
     * handed over as the `.zip` — unwrapping a tree into a flat cache dir would lose its shape.
     */
    private fun singleEntryName(blob: ByteArray): String? = runCatching {
        var name: String? = null
        java.util.zip.ZipInputStream(blob.inputStream()).use { zin ->
            var entry = zin.nextEntry ?: return@runCatching null
            while (true) {
                if (entry.isDirectory) return@runCatching null
                if (name != null) return@runCatching null   // more than one file
                name = entry.name
                entry = zin.nextEntry ?: break
            }
        }
        // Zip entry names are attacker-controlled: a `../` in one is the classic Zip Slip, and this
        // one is written to disk. Keep the basename only, so the write can never leave the slot.
        name?.substringAfterLast('/')?.substringAfterLast('\\')?.takeIf { it.isNotBlank() }
    }.getOrNull()

    private fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    /** Drop staged copies older than an hour. They're handoff scratch, not storage, and leaving them
     *  means a decrypted document sits in the cache long after the app that opened it is gone. */
    private fun sweep(dir: File) {
        val cutoff = System.currentTimeMillis() - 60 * 60 * 1000
        dir.listFiles()?.forEach { slot ->
            if (slot.lastModified() < cutoff) runCatching { slot.deleteRecursively() }
        }
    }
}
