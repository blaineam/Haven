package com.blaineam.haven.core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.math.max

/**
 * On-device media store: photos are content-addressed (sha-256 of the plaintext, so the id is
 * the same on every device — ready for the cross-device MediaReq/Chunk fetch later) and kept
 * **sealed at rest** to the circle, mirroring the iOS MediaStore. Cross-device transfer of the
 * bytes themselves is the remaining Wave-3 piece (mailbox / type-3/5 frames).
 */
object LocalMedia {
    private lateinit var dir: File

    fun init(context: Context) {
        dir = File(context.applicationContext.filesDir, "media").apply { mkdirs() }
    }

    /** Above this plaintext size, seal file→file (off-heap) instead of holding the sealed envelope in RAM. */
    private const val SEAL_TO_FILE_THRESHOLD = 4 * 1024 * 1024

    /**
     * Seal [bytes] to the at-rest file [dst] for [circleId]. LARGE blobs are sealed file→file in NATIVE
     * memory (`sealCircleMediaFile`) so the whole ~2× sealed envelope never lands on the managed heap — an
     * in-memory `sealCircleMedia` of a big video allocated the entire sealed buffer at once and OOM-crashed
     * low-heap phones (the same trap iOS fixed by sealing to a temp file in `backup()`). Small payloads seal
     * in-memory (simpler, no temp file). On any seal failure we fall back to writing the plaintext, exactly
     * as the prior in-memory path did, so media is never silently dropped.
     */
    private fun sealToFile(circleId: String, bytes: ByteArray, dst: File) {
        if (bytes.size > SEAL_TO_FILE_THRESHOLD) {
            val tmp = File(dst.parentFile, "${dst.name}.plain.tmp")
            val ok = runCatching {
                tmp.writeBytes(bytes)
                HavenNet.engine.sealCircleMediaFile(circleId, tmp.absolutePath, dst.absolutePath)
            }.getOrDefault(false)
            runCatching { tmp.delete() }
            if (ok && dst.exists()) return
            // Seal-to-file failed → fall through to the in-memory path (then raw plaintext).
        }
        val toWrite = runCatching { HavenNet.engine.sealCircleMedia(circleId, bytes) }.getOrNull() ?: bytes
        runCatching { dst.writeBytes(toWrite) }
    }

    /**
     * Store plaintext bytes sealed to [circleId]; returns a media ref. Videos are tagged "v:" so
     * the feed renders them as players (images stay bare for backward compatibility).
     */
    fun store(circleId: String, bytes: ByteArray, isVideo: Boolean = false): String {
        // Mint the SAME ref scheme as iOS (apple/HavenApp/Media.swift): the kind is encoded in the
        // prefix so a recipient on either platform knows how to render it. iOS hard-rejects any ref
        // without an img_/vid_/aud_ prefix, so bare hashes were being dropped cross-platform.
        val ref = (if (isVideo) "vid_" else "img_") + sha256Hex(bytes)
        sealToFile(circleId, bytes, mediaFile(ref))   // large blobs seal file→file (off-heap) to avoid OOM
        return ref
    }

    /** Store a recorded voice message; returns an `aud_` ref (sealed at rest like other media). */
    fun storeAudio(circleId: String, bytes: ByteArray): String {
        val ref = "aud_" + sha256Hex(bytes)
        sealToFile(circleId, bytes, mediaFile(ref))   // large blobs seal file→file (off-heap) to avoid OOM
        return ref
    }

    /** Decrypt an audio ref to a cache file MediaPlayer can read; null if missing. */
    fun audioFile(circleId: String, ref: String): File? {
        val bytes = load(circleId, ref) ?: return null
        val out = File(dir.parentFile, "${storageKey(ref)}.m4a")
        if (!out.exists()) runCatching { out.writeBytes(bytes) }
        return if (out.exists()) out else null
    }

    fun isVideo(ref: String): Boolean = ref.startsWith("vid_") || ref.startsWith("v:")
    fun isAudio(ref: String): Boolean = ref.startsWith("aud_")

    // ---- Memory guard (low-heap devices) --------------------------------------------------------
    // Decrypt (openCircleMedia) is all-in-RAM: it takes the whole sealed blob and returns the whole
    // plaintext, so peak memory is ~2× the media size. On a low-heap phone (e.g. the Nokia 6.1's
    // ~512 MB heap) a large synced VIDEO (400 MB+) blows the heap the instant the feed tries to render
    // or play it — an OutOfMemoryError that crashes the app ON LAUNCH (the feed renders immediately).
    // Since a device physically cannot decrypt media larger than its heap can hold, we SKIP such media
    // gracefully (return null) rather than crash. It still lives sealed on disk + on the relay, and a
    // higher-memory device (iPhone/Mac/desktop) plays it fine.

    /** Max plaintext we'll hold in RAM to decrypt for display/playback — a quarter of this process's
     *  max heap, so decrypt's ~2× peak stays well under the limit. */
    fun maxInMemoryBytes(): Long = Runtime.getRuntime().maxMemory() / 4

    /** The at-rest sealed file size for [ref] (≈ plaintext size; AEAD overhead is a few bytes), or -1. */
    fun sealedSize(ref: String): Long {
        val f = mediaFile(ref)
        return if (f.exists()) f.length() else -1L
    }

    /** True when [ref] exists and is small enough to safely decrypt into RAM on this device. */
    fun fitsInMemory(ref: String): Boolean {
        val s = sealedSize(ref)
        return s in 0..maxInMemoryBytes()
    }
    // Strip the kind prefix (ours or iOS's) to the ref's unique part — the content hash. NOT a
    // storage key on its own: it is kind-BLIND, so img_X and vid_X reduce to the same string
    // (see [storageKey]). Legacy v:/i: kept for already-stored local media.
    private fun bareId(ref: String): String =
        ref.removePrefix("v:").removePrefix("i:")
            .removePrefix("img_").removePrefix("vid_").removePrefix("aud_")

    /**
     * The on-disk key for [ref] — the content hash QUALIFIED BY KIND, so a photo and a video can
     * never share a file. The single-letter legacy schemes normalize onto their modern key (`v:X`
     * and `vid_X` name the same media). Kindless legacy refs — bare content hashes, the scheme we
     * minted before iOS parity — have no kind to qualify with and keep the bare key they were
     * written under.
     */
    private fun storageKey(ref: String): String = when {
        ref.startsWith("img_") || ref.startsWith("i:") -> "img_${bareId(ref)}"
        ref.startsWith("vid_") || ref.startsWith("v:") -> "vid_${bareId(ref)}"
        ref.startsWith("aud_") -> "aud_${bareId(ref)}"
        else -> bareId(ref)
    }

    /**
     * The sealed at-rest file for [ref], adopting a legacy bare-key file on first touch.
     *
     * The store predates ref prefixes: files were named by the bare content hash — the ref *was* the
     * filename — so when the img_/vid_/aud_ scheme landed, [bareId] stripped the kind back off purely
     * to keep resolving those existing files. That threw away the one bit telling a photo from a
     * video: `img_X` and `vid_X` shared one file and whichever was written last served ITS bytes for
     * BOTH refs (the demo's ridge photo, rendered as a black video frame). Keys are kind-qualified
     * now, and media already cached under the old scheme is RENAMED into place rather than orphaned.
     * A legacy key is ambiguous by construction, so on the pathological pair the first ref to ask
     * claims it and the other reads as missing — and re-fetches — instead of being handed the wrong
     * bytes, which is the corruption this fixes.
     */
    private fun mediaFile(ref: String): File {
        val f = File(dir, storageKey(ref))
        if (f.exists()) return f
        val legacy = File(dir, bareId(ref))
        if (legacy != f && legacy.exists()) runCatching { legacy.renameTo(f) }
        return f
    }

    /** Load + decrypt a stored media ref, or null if we don't have it (or it's too big to hold in
     *  RAM on this device — see [fitsInMemory]; oversized media is skipped, never OOM-crashed). */
    fun load(circleId: String, ref: String): ByteArray? {
        val f = mediaFile(ref)
        if (!f.exists()) return null
        if (f.length() > maxInMemoryBytes()) return null   // too big to decrypt in RAM here → skip
        val stored = f.readBytes()
        return runCatching { HavenNet.engine.openCircleMedia(circleId, stored) }.getOrNull() ?: stored
    }

    /** Decrypt a video ref to a cache file VideoView/MediaPlayer can read; null if missing/undecodable.
     *  Decryption runs in NATIVE memory (openCircleMediaFile) straight to the cache file, so a
     *  hundreds-of-MB video that would OOM the ~512 MB Java heap (via [load]) decrypts fine — native
     *  allocations aren't bound by the managed-heap cap, only by physical RAM. The player then streams
     *  from the file, so the whole video is never held in the app's heap at once. */
    fun videoFile(circleId: String, ref: String): File? {
        val out = File(dir.parentFile, "${storageKey(ref)}.mp4")
        if (out.exists()) return out
        val sealed = mediaFile(ref)
        if (!sealed.exists()) return null
        val ok = runCatching {
            HavenNet.engine.openCircleMediaFile(circleId, sealed.absolutePath, out.absolutePath)
        }.getOrDefault(false)
        return if (ok && out.exists()) out else null
    }

    /** Decode a stored IMAGE ref to a DOWNSAMPLED bitmap (long edge ≤ [reqDim]) so even a large
     *  photo can't OOM the render. Null if missing, oversized (see the memory guard), or not an
     *  image. Videos must use [videoPoster] — decoding a video's bytes as a bitmap both fails and,
     *  worse, reads the whole file into RAM first (the launch-crash on low-heap phones). */
    fun imageBitmap(circleId: String, ref: String, reqDim: Int = 2048): Bitmap? {
        if (isVideo(ref) || isAudio(ref)) return null
        val bytes = load(circleId, ref) ?: return null   // size-guarded
        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / sample > reqDim) sample *= 2
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample })
        }.getOrNull()
    }

    /** A poster frame for a VIDEO ref, read via MediaMetadataRetriever — but ONLY from an already
     *  decrypted cache file (i.e. a video that's been opened/played once). We deliberately do NOT
     *  trigger a full decrypt just to draw a feed thumbnail (a 600 MB video would be needless heavy
     *  work per feed item); an un-played video shows the play-glyph tile until it's opened. */
    fun videoPoster(circleId: String, ref: String): Bitmap? {
        val file = File(dir.parentFile, "${storageKey(ref)}.mp4")
        if (!file.exists()) return null
        val mmr = android.media.MediaMetadataRetriever()
        return runCatching {
            mmr.setDataSource(file.absolutePath)
            mmr.getFrameAtTime(0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        }.getOrNull().also { runCatching { mmr.release() } }
    }

    /** Video pixel dimensions from MMR metadata, swapped when the clip carries a 90/270° rotation. */
    private fun mmrSize(mmr: android.media.MediaMetadataRetriever): Pair<Int, Int>? {
        fun tag(k: Int) = mmr.extractMetadata(k)?.toIntOrNull()
        val w = tag(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH) ?: return null
        val h = tag(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT) ?: return null
        if (w <= 0 || h <= 0) return null
        val rot = tag(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: 0
        return if (rot == 90 || rot == 270) h to w else w to h
    }

    /** Memoized: a ref's pixel size never changes, and the image path costs a full decrypt to read
     *  the header. Absent entries are cached as null too, so a missing ref isn't retried per scroll. */
    private val sizeCache = java.util.concurrent.ConcurrentHashMap<String, Pair<Int, Int>>()
    private val UNKNOWN_SIZE = 0 to 0   // a cached miss (ConcurrentHashMap can't hold a null value)

    /**
     * Pixel dimensions of a media ref, or null if unknown (bytes not here yet, oversized, or an
     * un-played video with no decrypted cache file). Callers treat null as "assume it letterboxes".
     * Blocking — call it off the main thread.
     */
    fun pixelSize(circleId: String, ref: String): Pair<Int, Int>? {
        sizeCache[ref]?.let { return if (it == UNKNOWN_SIZE) null else it }
        val size = if (isVideo(ref)) {
            val file = File(dir.parentFile, "${storageKey(ref)}.mp4")
            if (!file.exists()) null else {
                val mmr = android.media.MediaMetadataRetriever()
                runCatching { mmr.setDataSource(file.absolutePath); mmrSize(mmr) }
                    .getOrNull().also { runCatching { mmr.release() } }
            }
        } else {
            load(circleId, ref)?.let { bytes ->
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                if (bounds.outWidth > 0 && bounds.outHeight > 0) bounds.outWidth to bounds.outHeight else null
            }
        }
        // Memoize a MISS only when it can't later become a hit: an image whose bytes are already here
        // is undecodable for good, but a video is sizeless purely until it's decrypted to cache, and an
        // in-flight download hasn't landed yet — re-ask for those.
        if (size != null || (!isVideo(ref) && has(ref))) sizeCache[ref] = size ?: UNKNOWN_SIZE
        return size
    }

    fun has(ref: String): Boolean = mediaFile(ref).exists()

    /**
     * True if [ref] is a synthetic, non-fetchable attachment (e.g. a `geo:<lat>,<lon>,<label>`
     * location pin) rather than real media bytes. Location shares ride inside a post's `media`
     * array, but no peer or relay can EVER serve them — blobstore safe_path (core/haven-net) rejects
     * ':' in a key component, so such a key was never storable — so the missing-media sweeps would
     * re-enqueue a doomed S3-404 + ~30s iroh dial for them every cycle and the pending count would
     * never settle to 0. Real media refs are `img_`/`vid_`/`aud_` or a bare content hash; the legacy
     * single-letter media schemes `v:`/`i:`/`a:` stay fetchable, so we key off a MULTI-char URI
     * scheme (a ':' at index > 1) rather than a bare "contains ':'".
     */
    fun isSynthetic(ref: String): Boolean = ref.indexOf(':') > 1

    /** Load decrypted bytes trying each circle's key (for serving a media request). Null if the
     *  media is too big to hold in RAM here (skipped rather than OOM — a relay/other device serves it). */
    fun loadAnyCircle(ref: String): ByteArray? {
        val f = mediaFile(ref)
        if (!f.exists()) return null
        if (f.length() > maxInMemoryBytes()) return null
        val stored = f.readBytes()
        for (c in HavenNet.engine.circles()) {
            runCatching { HavenNet.engine.openCircleMedia(c.id, stored) }.getOrNull()?.let { return it }
        }
        return stored   // fall back to raw (was stored unsealed)
    }

    /** Store received plaintext bytes under an exact ref (sealed at rest to the circle). */
    fun storeUnderRef(circleId: String, ref: String, bytes: ByteArray) {
        sealToFile(circleId, bytes, mediaFile(ref))   // large blobs seal file→file (off-heap) to avoid OOM
    }

    /** The at-rest sealed blob for a ref — uploaded to the relay verbatim (same form iOS stores).
     *  Null when the blob is too big to hold in RAM on this device: a low-heap phone skips mirroring
     *  media it can't even load (the source device + relay already hold it) instead of OOM-crashing
     *  during background backfill. */
    fun rawSealed(ref: String): ByteArray? {
        val f = mediaFile(ref)
        if (!f.exists() || f.length() > maxInMemoryBytes()) return null
        return f.readBytes()
    }

    /** Write a sealed blob fetched from the relay straight to disk (load() opens it on read). */
    fun writeRawSealed(ref: String, blob: ByteArray) {
        runCatching { mediaFile(ref).writeBytes(blob) }
    }

    // ---- Chunked reassembly (large-media fix) ---------------------------------------------------
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB, so large sealed videos are transferred as 8 MB
    // chunks (see HavenNet.uploadMedia/fetchMediaFromRelay). On download we APPEND each chunk to a temp
    // file on disk — the full sealed blob is NEVER held in RAM at once (an earlier all-in-RAM reassemble
    // OOM-killed low-heap phones). Once every chunk has landed, adoptSealedPart moves it into place.

    /** A fresh empty temp file to reassemble an incoming chunked (sealed) transfer for [ref]. */
    fun newSealedPart(ref: String): File {
        val f = File(dir, "incoming_${storageKey(ref)}_${System.nanoTime()}.part")
        runCatching { f.delete() }
        runCatching { f.createNewFile() }
        return f
    }

    /** Append one sealed chunk's bytes to the temp reassembly file (streaming — no full blob in RAM). */
    fun appendSealedPart(part: File, bytes: ByteArray): Boolean =
        runCatching { java.io.FileOutputStream(part, true).use { it.write(bytes) }; true }.getOrDefault(false)

    /** Move a fully-reassembled sealed temp file into place under [ref] (load() opens it on read). */
    fun adoptSealedPart(ref: String, part: File): Boolean =
        runCatching {
            val dst = mediaFile(ref)   // adopts any legacy-key file first, so it isn't left orphaned
            runCatching { dst.delete() }
            part.renameTo(dst) || (part.copyTo(dst, overwrite = true).let { part.delete(); true })
        }.getOrDefault(false)

    /** Delete every stored media file (part of "start over"). */
    fun clear() {
        runCatching { dir.listFiles()?.forEach { it.delete() } }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

/** Read a picked video's raw bytes, capped to avoid huge attachments (default 60 MB). */
fun readVideoBytes(context: Context, uri: Uri, maxBytes: Int = 60 * 1024 * 1024): ByteArray? =
    runCatching {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val bytes = input.readBytes()
            if (bytes.size > maxBytes) null else bytes
        }
    }.getOrNull()

/** True if the picked uri is a video (by MIME type). */
fun isVideoUri(context: Context, uri: Uri): Boolean =
    context.contentResolver.getType(uri)?.startsWith("video") == true

/**
 * Read a picked image, fix its EXIF orientation, downscale to <= maxDim, and JPEG-compress.
 * Reads the URI's bytes ONCE (re-opening a picker content stream often fails → blank previews),
 * samples down to avoid OOM on large photos, and applies EXIF rotation (so photos aren't sideways).
 */
fun loadAndDownscale(
    context: Context, uri: Uri,
    // Optimize per the active circle's override (falls back to the app-wide default) — media is
    // picked while composing for that circle.
    // Auto-optimize → 2048px JPEG @ 70% (cross-platform share spec, iOS parity); off → original quality.
    // Either way we re-encode from a decoded bitmap, which bakes the rotation into the pixels AND strips
    // all EXIF (orientation, GPS, device) — so nothing sideways and no location leaks.
    maxDim: Int = if (CircleSettings.optimize(HavenNet.activeCircle.value)) 2048 else 4096,
    quality: Int = if (CircleSettings.optimize(HavenNet.activeCircle.value)) 70 else 95,
): ByteArray? = runCatching {
    val raw = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        ?: return null.also { android.util.Log.w("LocalMedia", "openInputStream null for $uri") }

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
    val longest = max(bounds.outWidth, bounds.outHeight).coerceAtLeast(1)
    var sample = 1
    while (longest / sample > maxDim) sample *= 2   // sample DOWN to ~maxDim — avoids OOM

    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    var bmp = BitmapFactory.decodeByteArray(raw, 0, raw.size, opts)
        ?: return null.also { android.util.Log.w("LocalMedia", "decode failed for $uri") }

    // Downscale the rest of the way if still over the cap.
    if (max(bmp.width, bmp.height) > maxDim) {
        val r = maxDim.toFloat() / max(bmp.width, bmp.height)
        bmp = Bitmap.createScaledBitmap(bmp, (bmp.width * r).coerceAtLeast(1f).toInt(), (bmp.height * r).coerceAtLeast(1f).toInt(), true)
    }
    // Apply EXIF orientation (gallery/camera photos are often rotated/mirrored in metadata).
    val rot = runCatching {
        val exif = androidx.exifinterface.media.ExifInterface(java.io.ByteArrayInputStream(raw))
        when (exif.getAttributeInt(androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION,
            androidx.exifinterface.media.ExifInterface.ORIENTATION_NORMAL)) {
            androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            androidx.exifinterface.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
    }.getOrDefault(0f)
    if (rot != 0f) {
        val m = android.graphics.Matrix().apply { postRotate(rot) }
        bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
    }

    ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()
}.getOrElse { android.util.Log.e("LocalMedia", "loadAndDownscale failed", it); null }

/**
 * A picked photo as a base64 JPEG ready for [ProfileStore.setAvatar] — null if the decode failed.
 *
 * 192px @ 70% is the iOS wire spec (Profile.swift `avatarBase64`): this blob rides the signed
 * profile card to every circle member, so it stays small on purpose. Onboarding and Edit profile
 * both go through here so the two can't drift.
 */
fun loadAvatarB64(context: Context, uri: Uri): String? =
    loadAndDownscale(context, uri, maxDim = 192, quality = 70)
        ?.let { android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP) }
