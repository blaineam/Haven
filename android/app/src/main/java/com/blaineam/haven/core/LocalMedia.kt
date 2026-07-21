package com.blaineam.haven.core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaFormat
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.min

/**
 * On-device media store: photos are content-addressed (sha-256 of the plaintext, so the id is
 * the same on every device — ready for the cross-device MediaReq/Chunk fetch later) and kept
 * **sealed at rest** to the circle, mirroring the iOS MediaStore. Cross-device transfer of the
 * bytes themselves is the remaining Wave-3 piece (mailbox / type-3/5 frames).
 *
 * Being content-addressed was never enough on its own: nothing CHECKED that the bytes behind a ref
 * were the bytes it named. A relay operator — always an ordinary circle member — could PUT one
 * member's sealed blob at another member's ref, and every client rendered it: the seal opens, the
 * signature verifies, the sender is a member, and nobody ever hashed the plaintext back against the
 * ref. Signing a post but not binding its media meant whoever stored the bytes chose what the post
 * showed. [verifiesRef] is that missing check, applied on every read (see [load]).
 */
object LocalMedia {
    private lateinit var dir: File

    /** Decrypted playback caches (videoFile/audioFile output). These used to be written LOOSE in
     *  filesDir — OUTSIDE the media dir — so [clear] never removed them and PLAINTEXT media survived
     *  "start over" (a privacy bug). New caches land in this dedicated subdir, which clear() and the
     *  orphan sweep both cover; reads still check the old loose location first (compat), and clear()
     *  removes the loose stragglers too. */
    private lateinit var plainDir: File

    fun init(context: Context) {
        val files = context.applicationContext.filesDir
        dir = File(files, "media").apply { mkdirs() }
        plainDir = File(files, "media-plain").apply { mkdirs() }
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
        // Record the shape AT INGEST: reading an image header here is a few microseconds on bytes we
        // already hold, and it means the feed can lay this item's card out at the correct height the
        // very first time it draws — no 4:3 placeholder that later snaps and shifts the cards below it.
        if (!isVideo) runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            recordPixelSize(ref, bounds.outWidth, bounds.outHeight)
        }
        return ref
    }

    /** Store a recorded voice message; returns an `aud_` ref (sealed at rest like other media). */
    fun storeAudio(circleId: String, bytes: ByteArray): String {
        val ref = "aud_" + sha256Hex(bytes)
        sealToFile(circleId, bytes, mediaFile(ref))   // large blobs seal file→file (off-heap) to avoid OOM
        return ref
    }

    /** The decrypted playback-cache file for [ref]: the legacy loose filesDir location if a cache
     *  already exists there (read-compat), else the media-plain/ subdir that clear() + the orphan
     *  sweep own. */
    private fun plainCacheFile(ref: String, ext: String): File {
        val key = storageKey(ref)
        val legacy = File(dir.parentFile, "$key.$ext")
        return if (legacy.exists()) legacy else File(plainDir, "$key.$ext")
    }

    /** Decrypt an audio ref to a cache file MediaPlayer can read; null if missing. */
    fun audioFile(circleId: String, ref: String): File? {
        val bytes = load(circleId, ref) ?: return null
        val out = plainCacheFile(ref, "m4a")
        if (!out.exists()) runCatching { out.writeBytes(bytes) }
        return if (out.exists()) out else null
    }

    fun isVideo(ref: String): Boolean = ref.startsWith("vid_") || ref.startsWith("v:")
    fun isFile(ref: String): Boolean = ref.startsWith("file_")
    fun isAudio(ref: String): Boolean = ref.startsWith("aud_")

    /** Does a decrypted playback cache ALREADY exist for [ref]? Used by the re-optimize pass to tell
     *  a cache it may reuse from one it is about to create (and must therefore clean up again). */
    fun hasPlainCache(ref: String, ext: String): Boolean = plainCacheFile(ref, ext).exists()

    /** Drop the decrypted playback cache for [ref]. The sealed blob is untouched; the next read
     *  simply decrypts again. The re-optimize pass calls this after probing/encoding a video it had
     *  to decrypt, so scanning a 1.3 GB library never leaves 1.3 GB of plaintext behind it. */
    fun dropPlainCache(ref: String, ext: String) {
        runCatching { plainCacheFile(ref, ext).delete() }
    }

    /** Free space on the volume holding the media store, for the re-optimize pass's headroom check. */
    fun usableSpaceBytes(): Long = runCatching { dir.usableSpace }.getOrDefault(0L)

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
    //
    // Public so the evicted-media store can match a recorded eviction across ref/bare-hash forms
    // (an event ref `img_<hash>` and an on-disk bare-hash stem name the same media) — mirrors iOS
    // `MediaStore.bareId` used by `EvictedMediaStore`.
    fun bareId(ref: String): String =
        ref.removePrefix("v:").removePrefix("i:")
            .removePrefix("img_").removePrefix("vid_").removePrefix("aud_").removePrefix("file_")

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
        ref.startsWith("file_") -> "file_${bareId(ref)}"
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
     *  RAM on this device — see [fitsInMemory]; oversized media is skipped, never OOM-crashed), or
     *  if the bytes we hold are not the bytes the ref names.
     *
     *  Verification lives on the READ side, not the write side, because media is kept SEALED at rest:
     *  the plaintext only exists at open time, so this is the one place it can be hashed without
     *  paying for a second decrypt. It also means a blob is checked at the point it is USED, so a
     *  tampered at-rest file is caught too, not just a swap in flight. */
    fun load(circleId: String, ref: String): ByteArray? {
        val f = mediaFile(ref)
        if (!f.exists()) return null
        if (f.length() > maxInMemoryBytes()) return null   // too big to decrypt in RAM here → skip
        val stored = f.readBytes()
        val opened = runCatching { HavenNet.engine.openCircleMedia(circleId, stored) }.getOrNull() ?: stored
        return checked(ref, opened)
    }

    /** Decrypt a video ref to a cache file VideoView/MediaPlayer can read; null if missing/undecodable.
     *  Decryption runs in NATIVE memory (openCircleMediaFile) straight to the cache file, so a
     *  hundreds-of-MB video that would OOM the ~512 MB Java heap (via [load]) decrypts fine — native
     *  allocations aren't bound by the managed-heap cap, only by physical RAM. The player then streams
     *  from the file, so the whole video is never held in the app's heap at once. */
    fun videoFile(circleId: String, ref: String): File? {
        val out = plainCacheFile(ref, "mp4")
        if (out.exists()) return out
        val sealed = mediaFile(ref)
        if (!sealed.exists()) return null
        val ok = runCatching {
            HavenNet.engine.openCircleMediaFile(circleId, sealed.absolutePath, out.absolutePath)
        }.getOrDefault(false)
        if (!ok || !out.exists()) return null
        // Hold the video to its ref too — a swapped 600 MB blob must not be handed to the player just
        // because it was too big to check in RAM. The digest streams off the decrypted file, so the
        // check costs no heap; a failure deletes the cache file rather than leaving it to be replayed.
        if (!verifiesRef(ref, out)) {
            android.util.Log.w("LocalMedia", "media REJECTED ${ref.take(12)}: decrypted video does not match its content address")
            runCatching { out.delete() }
            return null
        }
        return out
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
            // The header is already parsed — bank the TRUE dimensions (not the downsampled bitmap's,
            // whose power-of-two sampling rounds the aspect) so the feed never has to ask again.
            recordPixelSize(ref, bounds.outWidth, bounds.outHeight)
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
        val file = plainCacheFile(ref, "mp4")
        if (!file.exists()) return null
        val mmr = android.media.MediaMetadataRetriever()
        return runCatching {
            mmr.setDataSource(file.absolutePath)
            // The retriever is already open on this clip, so its dimensions cost nothing extra here —
            // and banking them means the clip's card is the right height before the poster ever draws.
            mmrSize(mmr)?.let { (w, h) -> recordPixelSize(ref, w, h) }
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
     *  the header. Absent entries are cached as null too, so a missing ref isn't retried per scroll.
     *  Backed by [sizeMapFile] so the map SURVIVES relaunch — see [loadSizeMapIfNeeded]. */
    private val sizeCache = java.util.concurrent.ConcurrentHashMap<String, Pair<Int, Int>>()
    private val UNKNOWN_SIZE = 0 to 0   // a cached miss (ConcurrentHashMap can't hold a null value)

    // ---- Persisted ref → pixel size -------------------------------------------------------------
    // A feed card's HEIGHT comes from its media's aspect. Held only in memory, that aspect was unknown
    // on the first composition after every launch, so each card laid out at the 4:3 fallback and then
    // snapped to its real shape once the size resolved off-thread — shoving everything below it down
    // the screen mid-scroll. The map is two integers per ref, so persisting it is nearly free and a
    // given item settles on its true height exactly once, ever.

    @Volatile private var sizeMapLoaded = false
    private val sizeMapSavePending = java.util.concurrent.atomic.AtomicBoolean(false)
    private val sizeMapSaver = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "haven-media-sizes").apply { isDaemon = true }
    }

    /** `<ref> <w> <h>` per line — a plain table rather than JSON, since that's all it ever holds. */
    private fun sizeMapFile(): File = File(dir.parentFile, "media-sizes.txt")

    @Synchronized
    private fun loadSizeMapIfNeeded() {
        if (sizeMapLoaded) return
        sizeMapLoaded = true
        runCatching {
            val f = sizeMapFile()
            if (!f.exists()) return@runCatching
            f.forEachLine { line ->
                val p = line.split(' ')
                if (p.size == 3) {
                    val w = p[1].toIntOrNull() ?: return@forEachLine
                    val h = p[2].toIntOrNull() ?: return@forEachLine
                    if (w > 0 && h > 0) sizeCache.putIfAbsent(p[0], w to h)
                }
            }
        }
    }

    /** Remember a ref's pixel size in memory and (debounced) on disk. Called wherever real pixels pass
     *  through — ingest, a decoded image, a video poster — so the feed knows the shape before it has to
     *  draw the item. Silently ignores non-sizes so a bad probe can't poison the map. */
    fun recordPixelSize(ref: String, w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        loadSizeMapIfNeeded()
        val size = w to h
        if (sizeCache.put(ref, size) == size) return   // unchanged → nothing new to persist
        if (!sizeMapSavePending.compareAndSet(false, true)) return
        runCatching {
            sizeMapSaver.schedule({
                sizeMapSavePending.set(false)
                runCatching {
                    val snapshot = sizeCache.entries
                        .filter { it.value != UNKNOWN_SIZE }
                        .joinToString("\n") { "${it.key} ${it.value.first} ${it.value.second}" }
                    val tmp = File(sizeMapFile().parentFile, "media-sizes.tmp")
                    tmp.writeText(snapshot)
                    if (!tmp.renameTo(sizeMapFile())) { sizeMapFile().writeText(snapshot); tmp.delete() }
                }
            }, 1, java.util.concurrent.TimeUnit.SECONDS)
        }.onFailure { sizeMapSavePending.set(false) }
    }

    /** The size we ALREADY know for [ref] — memory or the persisted map, never the filesystem. Safe to
     *  call from a composition: a caller uses it to lay out at the right shape on the FIRST pass, and
     *  falls back to [pixelSize] off-thread only when this misses. */
    fun cachedPixelSize(ref: String): Pair<Int, Int>? {
        loadSizeMapIfNeeded()
        return sizeCache[ref]?.takeIf { it != UNKNOWN_SIZE }
    }

    /** [cachedPixelSize] as an aspect ratio (w/h). */
    fun cachedAspect(ref: String): Float? =
        cachedPixelSize(ref)?.let { (w, h) -> if (h > 0) w.toFloat() / h else null }

    /**
     * Pixel dimensions of a media ref, or null if unknown (bytes not here yet, oversized, or an
     * un-played video with no decrypted cache file). Callers treat null as "assume it letterboxes".
     * Blocking — call it off the main thread.
     */
    fun pixelSize(circleId: String, ref: String): Pair<Int, Int>? {
        loadSizeMapIfNeeded()   // a size banked on a previous run answers without touching the media
        sizeCache[ref]?.let { return if (it == UNKNOWN_SIZE) null else it }
        val size = if (isVideo(ref)) {
            val file = plainCacheFile(ref, "mp4")
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
        if (size != null) recordPixelSize(ref, size.first, size.second)   // memory + disk
        else if (!isVideo(ref) && has(ref)) sizeCache[ref] = UNKNOWN_SIZE   // a miss, never persisted
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
     *  media is too big to hold in RAM here (skipped rather than OOM — a relay/other device serves it).
     *  Verified as well: we must never RE-SERVE a substituted blob onward under the ref it claims —
     *  that would make every honest device a second-hop launderer for the relay's swap. */
    fun loadAnyCircle(ref: String): ByteArray? {
        val f = mediaFile(ref)
        if (!f.exists()) return null
        if (f.length() > maxInMemoryBytes()) return null
        val stored = f.readBytes()
        for (c in HavenNet.engine.circles()) {
            runCatching { HavenNet.engine.openCircleMedia(c.id, stored) }.getOrNull()?.let { return checked(ref, it) }
        }
        return checked(ref, stored)   // fall back to raw (was stored unsealed)
    }

    /**
     * Does the sealed blob we hold for [ref] actually OPEN for one of our circles?
     *
     * `true`/`false` are answers; `null` means we CANNOT TELL and the caller must not condemn the
     * blob — no circles yet, or the file is too large to decrypt within this device's heap. A big
     * video is decrypted file→file in NATIVE memory (the same route [videoFile] uses) precisely so
     * "too big to check in RAM" doesn't become "declared corrupt", which would delete perfectly good
     * media on a low-heap phone.
     */
    fun opensForAnyCircle(ref: String): Boolean? {
        val f = mediaFile(ref)
        if (!f.exists()) return null
        val circles = runCatching { HavenNet.engine.circles() }.getOrDefault(emptyList())
        if (circles.isEmpty()) return null
        if (f.length() <= maxInMemoryBytes()) {
            val stored = f.readBytes()
            for (c in circles) {
                if (runCatching { HavenNet.engine.openCircleMedia(c.id, stored) }.getOrNull() != null) return true
            }
            return false
        }
        // Too big for the managed heap — decrypt to a scratch file off-heap instead of guessing.
        val probe = plainCacheFile(ref, "probe")
        try {
            for (c in circles) {
                val ok = runCatching {
                    HavenNet.engine.openCircleMediaFile(c.id, f.absolutePath, probe.absolutePath)
                }.getOrDefault(false)
                if (ok && probe.exists() && probe.length() > 0) return true
            }
            return false
        } finally {
            runCatching { probe.delete() }
        }
    }

    /** Store received plaintext bytes under an exact ref (sealed at rest to the circle). Bytes that
     *  don't account for [ref] are dropped at the door rather than sealed and kept. */
    fun storeUnderRef(circleId: String, ref: String, bytes: ByteArray) {
        if (checked(ref, bytes) == null) return
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

    /** Rejoin a persisted part-file NAME with this launch's media dir. [ReassemblyStore] records the
     *  name, not the path, because filesDir isn't guaranteed to be the same string next launch. */
    fun partFile(name: String): File = File(dir, name)

    /**
     * A fresh temp file for a POSITIONALLY-written peer-to-peer transfer (frame 5).
     *
     * Same `incoming_*.part` naming as the relay path — which is what keeps it out of [storedBlobs]
     * and, critically, out of [has]: `has` looks up the bare storage key, a name this can never
     * produce, so a partial can never be mistaken for a complete blob. Unlike the relay path's parts
     * this one holds PLAINTEXT (frame-5 chunks are opened before they land), so it is adopted by
     * [adoptPlainPart], not [adoptSealedPart].
     */
    fun newPlainPart(ref: String): File = newSealedPart(ref)

    /**
     * Write one chunk's bytes at [offset] in a reassembly part.
     *
     * POSITIONAL, not append (which is all [appendSealedPart] can do): peer chunks arrive out of
     * order, and a RESUMED transfer fills scattered holes in a file that already has most of its
     * bytes. Writing by position is also what lets the receive path hold nothing in RAM but the one
     * chunk in hand — the old in-memory map cost ~3× the media size and silently dropped anything
     * over a quarter of the heap.
     */
    fun writePartAt(part: File, offset: Long, bytes: ByteArray): Boolean =
        runCatching {
            java.io.RandomAccessFile(part, "rw").use { raf -> raf.seek(offset); raf.write(bytes) }
            true
        }.getOrDefault(false)

    /**
     * Adopt a fully-reassembled PLAINTEXT part under [ref]: verify it accounts for its content address
     * (streamed, so a 600 MB video costs no heap), then seal it file→file into place.
     *
     * The digest check is the same gate [storeUnderRef] applies — bytes that don't account for the ref
     * a signed post pointed at are dropped at the door rather than sealed and kept. A rejected or
     * unsealable part is deleted here, so the caller can clear its reassembly record knowing there is
     * nothing left to resume into.
     */
    fun adoptPlainPart(circleId: String, ref: String, part: File): Boolean {
        if (!verifiesRef(ref, part)) {
            android.util.Log.w("LocalMedia", "media REJECTED ${ref.take(12)}: reassembled part does not match its content address")
            runCatching { part.delete() }
            return false
        }
        val dst = mediaFile(ref)
        runCatching { dst.delete() }
        val sealed = runCatching {
            HavenNet.engine.sealCircleMediaFile(circleId, part.absolutePath, dst.absolutePath)
        }.getOrDefault(false) && dst.exists()
        // On a seal failure, move the verified plaintext into place rather than discarding a transfer
        // that just cost the sender the whole file — exactly what [sealToFile] falls back to, and
        // [load] reads a raw at-rest blob fine. Never a silent drop.
        if (!sealed) runCatching { part.renameTo(dst) }
        runCatching { part.delete() }
        return dst.exists()
    }

    /** Move a fully-reassembled sealed temp file into place under [ref] (load() opens it on read). */
    fun adoptSealedPart(ref: String, part: File): Boolean =
        runCatching {
            val dst = mediaFile(ref)   // adopts any legacy-key file first, so it isn't left orphaned
            runCatching { dst.delete() }
            part.renameTo(dst) || (part.copyTo(dst, overwrite = true).let { part.delete(); true })
        }.getOrDefault(false)

    // ---- Size-sorted inventory + local-limit sweep (storage management UX) ----------------------
    // The client sibling of the relay's retention: the "Manage media" screen lists every cached blob
    // largest-first, and the age/size caps evict oldest-first. Mirrors iOS `MediaStore.storedBlobs` +
    // `performLimitSweep` byte-for-byte (apple/HavenApp/Media.swift).

    /** One stored media blob: its on-disk storage key (a kind-prefixed ref or a bare content hash),
     *  sealed byte size, and last-modified time in ms. */
    data class StoredBlob(val key: String, val bytes: Long, val mtimeMs: Long)

    /** True when [name] is in-flight scratch that must never be counted as a stored blob or swept as an
     *  orphan candidate — a chunked-reassembly temp (`incoming_*.part`), a seal-to-file temp
     *  (`*.plain.tmp`), or a hidden dotfile. */
    private fun isScratchName(name: String): Boolean =
        name.startsWith("incoming_") || name.endsWith(".plain.tmp") || name.startsWith(".")

    /** Every stored SEALED blob (the `media/` dir) with its size + mtime, for the size-sorted cleanup
     *  screen and the local-limit sweep. Skips in-flight scratch + hidden files. Blocking — call off
     *  the main thread. Files in `dir` are named by their storage key with NO extension, so the file
     *  name IS the key. */
    fun storedBlobs(): List<StoredBlob> {
        val out = ArrayList<StoredBlob>()
        dir.listFiles()?.forEach { f ->
            if (!f.isFile || isScratchName(f.name)) return@forEach
            out.add(StoredBlob(f.name, f.length(), f.lastModified()))
        }
        return out
    }

    /** A small thumbnail bitmap for a stored blob (any circle) — a downsampled image, or a video's
     *  poster frame if the clip has already been decrypted to cache. Null for un-played videos / audio
     *  / undecodable blobs (the cleanup screen falls back to a glyph). Blocking — off the main thread. */
    fun thumbnail(ref: String, reqDim: Int = 160): Bitmap? {
        if (isAudio(ref)) return null
        if (isVideo(ref)) return videoPoster("", ref)   // videoPoster ignores the circle (reads plain cache)
        val bytes = loadAnyCircle(ref) ?: return null
        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / sample > reqDim) sample *= 2
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample })
        }.getOrNull()
    }

    /**
     * The client sibling of the relay's retention: evict this device's cached blobs by AGE then SIZE
     * (oldest first) until under the caps. Unlike the orphan sweep, a blob a live event still
     * references IS eligible here — it just becomes a re-downloadable placeholder (the caller records
     * such keys in the evicted set so they aren't auto-refetched). [pinnedKeys] (device pins, unioned
     * from [normalizedKeys]) and composer-staged / in-flight media (fresh mtime, [graceMs] window) are
     * never touched. [inUse] is passed only to decide which evicted keys to record. Returns freed
     * bytes/files + the referenced keys to mark evicted (on-disk key → last-known size). Mirrors iOS
     * `MediaStore.performLimitSweep`. Blocking — call off the main thread.
     */
    fun performLimitSweep(
        maxDays: Int, maxGB: Int, pinnedKeys: Set<String>, inUse: Set<String>,
        graceMs: Long = 48L * 3600 * 1000,
    ): Triple<Long, Int, Map<String, Long>> {
        if (maxDays <= 0 && maxGB <= 0) return Triple(0L, 0, emptyMap())
        data class Cand(val file: File, val key: String, val bytes: Long, val mtime: Long)
        val freshCutoff = System.currentTimeMillis() - graceMs
        val cands = ArrayList<Cand>()
        var pinnedBytes = 0L
        dir.listFiles()?.forEach { f ->
            if (!f.isFile || isScratchName(f.name)) return@forEach
            val bytes = f.length()
            if (f.name in pinnedKeys) { pinnedBytes += bytes; return@forEach }   // device-pinned: never evict
            if (f.lastModified() > freshCutoff) return@forEach                   // too fresh to judge
            cands.add(Cand(f, f.name, bytes, f.lastModified()))
        }
        var freed = 0L
        var files = 0
        val evict = HashMap<String, Long>()
        val deleted = HashSet<File>()
        fun remove(c: Cand) {
            if (!deleted.add(c.file)) return
            runCatching { c.file.delete() }
            freed += c.bytes; files++
            if (c.key in inUse) evict[c.key] = c.bytes
            sizeCache.remove(c.key)
        }
        if (maxDays > 0) {
            val ageCutoff = System.currentTimeMillis() - maxDays.toLong() * 86_400_000L
            for (c in cands) if (c.mtime < ageCutoff) remove(c)
        }
        if (maxGB > 0) {
            val cap = maxGB.toLong() * 1_000_000_000L
            val survivors = cands.filter { it.file !in deleted }.sortedBy { it.mtime }   // oldest first
            var total = pinnedBytes + survivors.sumOf { it.bytes }
            var i = 0
            while (total > cap && i < survivors.size) { remove(survivors[i]); total -= survivors[i].bytes; i++ }
        }
        return Triple(freed, files, evict)
    }

    // ---- Deletion & GC ---------------------------------------------------------------------------
    // Blobs never deleted themselves: `purgeExpired` drops the EVENTS but the sealed bytes (and,
    // worse, the DECRYPTED playback caches) lived forever. Deletion is ref-driven — the engine hands
    // back purged refs, HavenNet subtracts anything a live event anywhere still names, and the rest
    // is removed here. The orphan sweep covers what purging can't reach (unsent/abandoned staging,
    // legacy bare-hash files, caches for media that's long gone).

    /** Every on-disk name [ref] resolves to — the kind-qualified storage key plus the legacy bare
     *  key. One definition shared by [delete] and the sweep's keep-set so the two can't drift. */
    fun normalizedKeys(ref: String): Set<String> = setOf(storageKey(ref), bareId(ref))

    /** True when [stem] is shaped like one of our storage keys — a kind-prefixed ref or a bare
     *  64-hex content hash. Gates which loose filesDir files the cache cleanup may touch (filesDir
     *  also holds app state that must never be swept). */
    private fun isMediaKeyStem(stem: String): Boolean =
        stem.startsWith("img_") || stem.startsWith("vid_") || stem.startsWith("aud_") ||
            stem.startsWith("file_") ||
            (stem.length == 64 && stem.all { it in '0'..'9' || it in 'a'..'f' })

    /**
     * Store a zip (or any file blob) as a sealed `file_` content-addressed ref — parity with Apple
     * MediaKind.file. Callers zip folders first when needed.
     */
    fun storeFile(circleId: String, bytes: ByteArray): String {
        val ref = "file_" + sha256Hex(bytes)
        sealToFile(circleId, bytes, mediaFile(ref))
        return ref
    }

    /**
     * Full video attach (iOS `MediaStore.prepareVideo` parity): optimized playable ref + poster
     * still + optional camera original, with synthetic `poster:`/`orig:` markers via [MediaVariants].
     * Prefer this at compose time so super-data-saver clients can render without the video bytes.
     */
    data class PreparedVideo(
        val videoRef: String,
        val posterRef: String?,
        val originalRef: String?,
        val mediaRefs: List<String>,
    ) {
        val isEmpty: Boolean get() = videoRef.isEmpty()
    }

    fun prepareVideo(
        context: android.content.Context,
        uri: android.net.Uri,
        circleId: String,
        forceOptimize: Boolean = false,
        alsoOriginal: Boolean? = null,
    ): PreparedVideo {
        val empty = PreparedVideo("", null, null, emptyList())
        val optimize = forceOptimize ||
            runCatching { CircleSettings.optimize(circleId) }.getOrDefault(true)
        val optimized = readVideoBytes(context, uri, forceOptimize = forceOptimize) ?: return empty
        val videoRef = store(circleId, optimized, isVideo = true)

        // Poster still from the optimized bytes so data-saver clients can show a card without the clip.
        var posterRef: String? = null
        runCatching {
            val tmp = File.createTempFile("poster", ".mp4", context.cacheDir)
            try {
                tmp.writeBytes(optimized)
                val mmr = android.media.MediaMetadataRetriever()
                mmr.setDataSource(tmp.absolutePath)
                val frame = mmr.getFrameAtTime(0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                mmr.release()
                if (frame != null) {
                    val baos = java.io.ByteArrayOutputStream()
                    frame.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, baos)
                    posterRef = store(circleId, baos.toByteArray(), isVideo = false)
                }
            } finally {
                tmp.delete()
            }
        }

        val wantOriginal = alsoOriginal
            ?: (runCatching { ProfileStore.get(context).sendOriginal }.getOrDefault(false) || !optimize)
        var originalRef: String? = null
        if (wantOriginal && !forceOptimize) {
            // Camera original via lossless strip-remux (metadata gone); skip if same bytes as optimized.
            val orig = stripVideoMetadata(context, uri, MediaTargets.MAX_VIDEO_BYTES)
                ?: runCatching {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                }.getOrNull()
            if (orig != null && !orig.contentEquals(optimized)) {
                originalRef = store(circleId, orig, isVideo = true)
            }
        }

        val mediaRefs = MediaVariants.composeVideoMedia(posterRef, videoRef, originalRef)
        return PreparedVideo(videoRef, posterRef, originalRef, mediaRefs)
    }

    /** Remove [ref]'s sealed blob (modern + legacy key) AND its decrypted playback caches (both the
     *  media-plain/ subdir and the legacy loose filesDir location). Only call with refs no live
     *  event references — the caller owns the in-use check. Returns bytes freed. */
    fun delete(ref: String): Long {
        if (isSynthetic(ref)) return 0L
        var freed = 0L
        fun rm(f: File) {
            if (f.isFile) { freed += f.length(); runCatching { f.delete() } }
        }
        for (key in normalizedKeys(ref)) rm(File(dir, key))
        for (ext in listOf("mp4", "m4a")) {
            rm(File(dir.parentFile, "${storageKey(ref)}.$ext"))
            rm(File(plainDir, "${storageKey(ref)}.$ext"))
        }
        sizeCache.remove(ref)
        return freed
    }

    /** Delete every stored file whose key is not in [keepKeys] (built by the caller from every
     *  circle's feed + comments + scheduled sends via [normalizedKeys]). A GRACE window skips
     *  anything modified recently — media staged in a composer but not yet posted and in-flight
     *  `incoming_*.part` reassemblies have fresh mtimes and no referencing event YET; age, not
     *  referencedness, is what makes them safe to judge. Covers the sealed store, the media-plain/
     *  cache dir, and legacy loose caches in filesDir. Returns (bytesFreed, filesRemoved).
     *
     *  [liveParts] (part NAME → last-progress ms, from [ReassemblyStore]) are partials belonging to a
     *  RESUMABLE transfer: 99%-complete downloads waiting for the rest, not leaked scratch. Deleting
     *  them was the second half of why large media never arrived — the transfer survived the relaunch
     *  in principle, and then this sweep threw the bytes away. They are spared until abandoned, which
     *  ReassemblyStore.prune decides at 24h of no progress (well inside the 48h grace, so an abandoned
     *  partial is reclaimed there rather than lingering another day here). */
    fun sweepOrphans(
        keepKeys: Set<String>,
        graceMs: Long = 48L * 3600 * 1000,
        liveParts: Map<String, Long> = emptyMap(),
    ): Pair<Long, Int> {
        val now = System.currentTimeMillis()
        val cutoff = now - graceMs
        val abandoned = now - ReassemblyStore.EXPIRY_MS
        var bytes = 0L
        var files = 0
        fun rm(f: File) { bytes += f.length(); files++; runCatching { f.delete() } }
        // Sealed blobs (also retires stale incoming_*.part / *.plain.tmp scratch — never in the keep-set).
        dir.listFiles()?.forEach { f ->
            liveParts[f.name]?.let { progressed -> if (progressed > abandoned) return@forEach }
            if (f.isFile && f.lastModified() <= cutoff && f.name !in keepKeys) rm(f)
        }
        // Decrypted playback caches: ours entirely — keep iff the sealed key is kept.
        plainDir.listFiles()?.forEach { f ->
            val stem = f.name.substringBeforeLast('.')
            if (f.isFile && f.lastModified() <= cutoff && stem !in keepKeys) rm(f)
        }
        // Legacy loose caches in filesDir (pre-media-plain builds): only touch files SHAPED like our
        // caches — filesDir holds unrelated app state.
        dir.parentFile?.listFiles()?.forEach { f ->
            val n = f.name
            if (!f.isFile || !(n.endsWith(".mp4") || n.endsWith(".m4a"))) return@forEach
            val stem = n.dropLast(4)
            if (isMediaKeyStem(stem) && f.lastModified() <= cutoff && stem !in keepKeys) rm(f)
        }
        return bytes to files
    }

    /** Delete every stored media file (part of "start over") — the sealed store, the decrypted
     *  playback caches, AND the legacy loose caches that used to survive this (plaintext outliving
     *  a factory reset was a privacy bug). */
    fun clear() {
        runCatching { dir.listFiles()?.forEach { it.delete() } }
        runCatching { plainDir.listFiles()?.forEach { it.delete() } }
        runCatching {
            dir.parentFile?.listFiles()?.forEach { f ->
                val n = f.name
                if (f.isFile && (n.endsWith(".mp4") || n.endsWith(".m4a")) && isMediaKeyStem(n.dropLast(4))) {
                    f.delete()
                }
            }
        }
        sizeCache.clear()
        // The size map outlives an eviction on purpose, but "start over" wipes it with everything else —
        // otherwise a fresh install would carry a table of refs that no longer exist here.
        runCatching { sizeMapFile().delete() }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** Stream a file's digest in 1 MB windows — a hundreds-of-MB video must never be read into a
     *  ByteArray just to hash it (that's the managed-heap OOM this store spends so much effort
     *  avoiding elsewhere). Null if unreadable. */
    private fun sha256Hex(file: File): String? = runCatching {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { ins ->
            val buf = ByteArray(1024 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        md.digest().joinToString("") { "%02x".format(it) }
    }.getOrNull()

    /**
     * Is [ref] a content address — i.e. is there a digest in it to hold bytes to?
     *
     * False for the legacy UUID refs iOS used to mint and for synthetic attachments. This is the
     * migration hinge: verifiable refs are enforced, everything older is grandfathered, because
     * `img_<uuid>` contains nothing to check and the only alternative to accepting it is every
     * existing post's media going blank. It can't be abused to downgrade — the ref is a field of the
     * author-SIGNED post, so nobody can substitute a legacy-shaped ref without the author's key —
     * and the unverifiable population only shrinks, since minting is content-addressed everywhere now.
     * Mirrors `p2pcore::mediaref::is_verifiable`.
     */
    private fun isRefVerifiable(ref: String): Boolean {
        if (isSynthetic(ref)) return false
        val id = bareId(ref)
        return id.length == 64 && id.all { it in '0'..'9' || it in 'a'..'f' }
    }

    /** Do these plaintext bytes account for [ref]? True for legacy refs (nothing to check). */
    private fun verifiesRef(ref: String, plaintext: ByteArray): Boolean =
        !isRefVerifiable(ref) || sha256Hex(plaintext) == bareId(ref)

    /** [verifiesRef] for a decrypted file, streamed. Unreadable under a verifiable ref = fail closed. */
    private fun verifiesRef(ref: String, plaintext: File): Boolean =
        !isRefVerifiable(ref) || sha256Hex(plaintext) == bareId(ref)

    /** Gate plaintext on it accounting for the ref that named it. Null = a substitution: the seal
     *  opened, but these are not the bytes the signed post pointed at, so nothing may render them. */
    private fun checked(ref: String, plaintext: ByteArray): ByteArray? =
        if (verifiesRef(ref, plaintext)) plaintext else {
            android.util.Log.w("LocalMedia", "media REJECTED ${ref.take(12)}: ${plaintext.size}B do not match its content address")
            null
        }
}

/**
 * Read a picked video for posting. TWO privacy/size concerns are handled here, in order:
 *
 *  1. **Compression (optimize on — the default).** When the active circle's optimize setting is on,
 *     the clip is TRANSCODED to ≤1080p H.264 + copied audio via [transcodeVideo] (Android has no
 *     one-liner — it's a MediaCodec decode→encoder-input-surface pipeline). This matches Apple's
 *     `VideoEncoder`: 1080p H.264 at an EXPLICIT [MediaTargets.VIDEO_BITRATE] with the `moov` atom
 *     moved to the front ([Mp4Faststart]) — a full-HD re-encode, so a
 *     4K/200 MB original lands well under the cap and every recipient can decode it. Because the
 *     transcode writes a brand-new container via [MediaMuxer], it ALSO drops all identifying
 *     metadata (GPS included) — the same guarantee the strip-remux below gives.
 *
 *  2. **Metadata strip (always — parity with iOS).** If optimize is off, or the transcode fails for
 *     any reason (unsupported codec, encoder init, a stall), we fall back to the passthrough
 *     [stripVideoMetadata] remux: samples are copied verbatim (NO re-encode, same quality) into a
 *     fresh container that carries only the boxes we ask for. Location rides in the container's
 *     `loci`/`udta` userdata, which a new muxer emits only via `setLocation` — never called — so
 *     it's simply gone. The rotation hint IS carried across; it's display geometry, not an identifier.
 *
 * The 60 MB cap is applied AFTER whichever path ran (a transcoded clip is checked at its final size,
 * not its original). Falls back to the raw bytes only if BOTH the transcode and the remux fail
 * outright — the same "post something rather than nothing" tradeoff iOS makes, and the one path that
 * can still carry metadata (reachable only when AVFoundation's Android analogue can't process the
 * asset at all).
 *
 * Historical note: this used to hand the picker's raw bytes straight to [LocalMedia.store], so a clip
 * recorded with location on carried its capture coordinates to everyone in the circle.
 */
fun readVideoBytes(
    context: Context,
    uri: Uri,
    maxBytes: Int = MediaTargets.MAX_VIDEO_BYTES,
    // [MediaReoptimizer] re-encodes media I ALREADY shared, which by definition may have been shared
    // with the circle's optimize setting OFF — so it must not consult that setting again. It goes
    // through THIS function rather than a parallel encoder precisely so that when the targets change
    // again, old media follows automatically. Apple's `addVideo(forceOptimize:)` is the same lever.
    forceOptimize: Boolean = false,
): ByteArray? {
    // HARD LIMIT first, before any work: no amount of encoding makes a feature film reasonable to
    // hand a circle, and every member pays to store and move whatever this produces.
    //
    // Returning null IS the refusal channel on Android — every call site already treats null as
    // "skip this item" — so a refusal can never become a ref with no bytes behind it. A duration we
    // cannot read at all is NOT treated as a refusal: an unreadable header is usually an exotic
    // container, not a two-hour film, and failing closed there would reject legitimate media.
    val seconds = runCatching {
        android.media.MediaMetadataRetriever().use { r ->
            r.setDataSource(context, uri)
            r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.let { it / 1000.0 }
        }
    }.getOrNull()
    if (seconds != null && seconds > MediaTargets.MAX_VIDEO_SECONDS) {
        android.util.Log.w("LocalMedia",
            "video REJECTED — ${seconds.toInt()}s exceeds the ${MediaTargets.MAX_VIDEO_SECONDS}s limit")
        return null
    }
    // Optimize per the active circle's override (falls back to the app-wide default), same as photos
    // ([loadAndDownscale]) — media is picked while composing for that circle.
    val optimize = forceOptimize ||
        runCatching { CircleSettings.optimize(HavenNet.activeCircle.value) }.getOrDefault(true)
    // Source size, for the anti-inflation check below. Null when it can't be determined.
    val srcBytes = runCatching {
        context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
    }.getOrNull()?.takeIf { it > 0 }

    if (optimize) {
        // Transcode reads the source directly (MediaExtractor), NOT the capped raw read below — so a
        // large 4K original that would blow the cap is shrunk first, then checked against it. On any
        // failure it returns null and we fall through to the always-on metadata strip.
        transcodeVideo(context, uri, maxBytes)?.let { encoded ->
            // "Optimize" must never make a file BIGGER. [MediaTargets.VIDEO_BITRATE] is a target,
            // not a ceiling on the source: a clip that was already leaner than 4.5 Mbps — a short
            // screen recording, a 720p clip someone else already compressed, anything re-shared —
            // gets re-encoded UP to the target and grows, while also losing a generation of quality.
            // Caught by measurement, not review: the rotation test's 720p fixture went 0.48 MB in,
            // 0.59 MB out. `KEY_BIT_RATE` on the source format would have prevented it, but
            // MediaExtractor usually does not expose it, so the honest check is on the real output.
            //
            // Falling through hands the clip to the lossless strip-remux below, which still removes
            // GPS and still costs nothing in quality.
            if (srcBytes == null || encoded.size < srcBytes) return encoded
            android.util.Log.i("LocalMedia",
                "transcode produced ${encoded.size}B from a ${srcBytes}B source — keeping the " +
                    "original via strip-remux rather than inflating it")
        }
    }
    // Optimize off, or transcode failed: passthrough strip-remux (metadata gone, no re-encode). The raw
    // read here is capped, so an un-optimizable clip over the cap is rejected rather than sent huge.
    val raw = runCatching {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val bytes = input.readBytes()
            if (bytes.size > maxBytes) null else bytes
        }
    }.getOrNull() ?: return null
    return stripVideoMetadata(context, uri, maxBytes) ?: raw
}

/**
 * Transcode a picked video to a network-friendly ≤1080p H.264 MP4 (+ audio copied through), the
 * Android counterpart of iOS `MediaStore.optimizeVideo`. Returns the encoded bytes, or null on ANY
 * failure/stall so the caller falls back to the lossless metadata-strip remux.
 *
 * Pipeline: source → [MediaExtractor] → hardware [MediaCodec] decoder → the ENCODER'S INPUT SURFACE →
 * [MediaCodec] AVC encoder → [MediaMuxer]. Feeding the decoder straight into the encoder's input
 * surface means the BufferQueue backing that surface is sized to the encoder's configured (downscaled)
 * dimensions, so the frames are scaled to 1080p WITHOUT an OpenGL pass — the surface consumer does the
 * resize. The audio track is copied through verbatim (no re-encode). Rotation is preserved as a muxer
 * orientation hint (display geometry, not identity), never baked, so there's no GL and portrait clips
 * still play upright. The fresh muxer container carries no `loci`/`udta` userdata → GPS is gone.
 *
 * Off-heap by construction: frames live in the codecs' native buffers and the surface, never on the
 * managed heap, so this doesn't reintroduce the large-media OOM the sealed store works so hard to
 * avoid. A wall-clock stall guard turns a wedged codec into a fallback rather than a hang.
 */
private fun transcodeVideo(context: Context, uri: Uri, maxBytes: Int): ByteArray? {
    val out = File.createTempFile("xcode", ".mp4", context.cacheDir)
    var extractor: android.media.MediaExtractor? = null
    var audioEx: android.media.MediaExtractor? = null
    var decoder: android.media.MediaCodec? = null
    var encoder: android.media.MediaCodec? = null
    var muxer: android.media.MediaMuxer? = null
    var inputSurface: android.view.Surface? = null
    return try {
        extractor = android.media.MediaExtractor().apply { setDataSource(context, uri, null) }
        var videoTrack = -1
        var srcFormat: android.media.MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) { videoTrack = i; srcFormat = f; break }
        }
        if (videoTrack < 0 || srcFormat == null) return null
        val srcMime = srcFormat.getString(MediaFormat.KEY_MIME) ?: return null
        val srcW = srcFormat.getInteger(MediaFormat.KEY_WIDTH)
        val srcH = srcFormat.getInteger(MediaFormat.KEY_HEIGHT)
        if (srcW <= 0 || srcH <= 0) return null

        // Audio track (copied through). Its own extractor so track selection can't fight the video's.
        var audioTrack = -1
        var audioFormat: android.media.MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) { audioTrack = i; audioFormat = f; break }
        }

        // Fit within 1920x1080 (long×short edge), preserving aspect, never upscaling; even dims (H.264).
        fun even(v: Int) = (v and 1.inv()).coerceAtLeast(2)
        val srcLong = max(srcW, srcH).toDouble()
        val srcShort = min(srcW, srcH).toDouble()
        val scale = minOf(1.0,
            MediaTargets.VIDEO_LONG_EDGE / srcLong, MediaTargets.VIDEO_SHORT_EDGE / srcShort)
        val dstW = even((srcW * scale).toInt())
        val dstH = even((srcH * scale).toInt())

        // An EXPLICIT target rate — see [MediaTargets.VIDEO_BITRATE].
        //
        // This used to be "≈4 bits/pixel clamped to 2–8 Mbps", which reads adaptive and was not: at
        // 1920×1080 the formula yields 8.3 Mbps and clamps to the 8 Mbps ceiling, so every optimized
        // 1080p clip came out at the maximum. That is the Android half of the 320 MB-video problem.
        //
        // Still never INFLATE a source that was already leaner than the target — re-encoding a
        // 2 Mbps clip up to 4.5 would spend bytes to lose quality.
        val srcBitrate = if (srcFormat.containsKey(MediaFormat.KEY_BIT_RATE)) srcFormat.getInteger(MediaFormat.KEY_BIT_RATE) else Int.MAX_VALUE
        val bitrate = MediaTargets.VIDEO_BITRATE.coerceAtMost(srcBitrate)
        val fps = if (srcFormat.containsKey(MediaFormat.KEY_FRAME_RATE))
            srcFormat.getInteger(MediaFormat.KEY_FRAME_RATE).coerceIn(MediaTargets.VIDEO_FPS_MIN, MediaTargets.VIDEO_FPS_MAX)
        else MediaTargets.VIDEO_FPS_DEFAULT

        val outFormat = MediaFormat.createVideoFormat("video/avc", dstW, dstH).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, MediaTargets.VIDEO_I_FRAME_INTERVAL_SEC)
        }
        encoder = MediaCodec.createEncoderByType("video/avc")
        encoder.configure(outFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = encoder.createInputSurface()
        encoder.start()

        decoder = MediaCodec.createDecoderByType(srcMime)
        decoder.configure(srcFormat, inputSurface, null, 0)
        decoder.start()
        extractor.selectTrack(videoTrack)

        muxer = android.media.MediaMuxer(out.absolutePath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val rotation = if (srcFormat.containsKey(MediaFormat.KEY_ROTATION)) srcFormat.getInteger(MediaFormat.KEY_ROTATION) else runCatching {
            android.media.MediaMetadataRetriever().use { r ->
                r.setDataSource(context, uri)
                r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
            }
        }.getOrNull() ?: 0
        if (rotation != 0) muxer.setOrientationHint(rotation)

        val TIMEOUT = 10_000L
        val STALL_MS = 20_000L
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var decodeDone = false
        var encodeDone = false
        var muxerStarted = false
        var videoOut = -1
        var audioOut = -1
        var lastProgress = System.currentTimeMillis()

        while (!encodeDone) {
            if (System.currentTimeMillis() - lastProgress > STALL_MS)
                throw IllegalStateException("transcode stalled")

            // Feed the decoder.
            if (!inputDone) {
                val inIdx = decoder.dequeueInputBuffer(TIMEOUT)
                if (inIdx >= 0) {
                    val buf = decoder.getInputBuffer(inIdx)!!
                    val sz = extractor.readSampleData(buf, 0)
                    if (sz < 0) {
                        decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        decoder.queueInputBuffer(inIdx, 0, sz, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            // Drain the decoder → render into the encoder's input surface.
            if (!decodeDone) {
                val outIdx = decoder.dequeueOutputBuffer(info, TIMEOUT)
                if (outIdx >= 0) {
                    decoder.releaseOutputBuffer(outIdx, info.size > 0)   // render=true pushes to the surface
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        decodeDone = true
                        encoder.signalEndOfInputStream()
                    }
                    lastProgress = System.currentTimeMillis()
                }
            }

            // Drain the encoder → muxer.
            val encIdx = encoder.dequeueOutputBuffer(info, TIMEOUT)
            if (encIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (muxerStarted) throw IllegalStateException("format changed twice")
                videoOut = muxer.addTrack(encoder.outputFormat)
                if (audioFormat != null) audioOut = muxer.addTrack(audioFormat)
                muxer.start()
                muxerStarted = true
            } else if (encIdx >= 0) {
                val encBuf = encoder.getOutputBuffer(encIdx)!!
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0   // csd already in the track format
                if (info.size > 0 && muxerStarted) {
                    encBuf.position(info.offset)
                    encBuf.limit(info.offset + info.size)
                    muxer.writeSampleData(videoOut, encBuf, info)
                    lastProgress = System.currentTimeMillis()
                }
                encoder.releaseOutputBuffer(encIdx, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) encodeDone = true
            }
        }

        // Copy the audio track through verbatim (no re-encode). Written after the video samples — a
        // valid MP4 doesn't require cross-track interleave, and this keeps the loop above single-purpose.
        if (audioOut >= 0 && audioTrack >= 0) {
            audioEx = android.media.MediaExtractor().apply { setDataSource(context, uri, null) }
            audioEx.selectTrack(audioTrack)
            val cap = if (audioFormat!!.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
                audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE).coerceAtLeast(64 * 1024) else 256 * 1024
            val abuf = java.nio.ByteBuffer.allocate(cap)
            val ainfo = MediaCodec.BufferInfo()
            while (true) {
                val sz = audioEx.readSampleData(abuf, 0)
                if (sz < 0) break
                ainfo.offset = 0
                ainfo.size = sz
                ainfo.presentationTimeUs = audioEx.sampleTime
                ainfo.flags = audioEx.sampleFlags
                muxer.writeSampleData(audioOut, abuf, ainfo)
                audioEx.advance()
            }
        }

        muxer.stop()
        val muxed = out.readBytes()
        // Faststart: `moov` (the index) must precede `mdat`, or a streaming recipient has to fetch
        // the whole blob before the first frame renders. Apple gets this from
        // `shouldOptimizeForNetworkUse`; Android has no such API.
        //
        // MEASURED, not assumed: on API 35 `MediaMuxer` already emits `ftyp moov free mdat` — it
        // reserves an estimated `moov` up front and backfills it — so this call is a NO-OP on the
        // ordinary path and returns null. It is kept because that reservation is best-effort: when
        // MPEG4Writer cannot fit the real `moov` into the space it guessed, it falls back to writing
        // it last, and OEM muxers are not obliged to reserve at all. So this is a safety net that
        // costs one box walk and can only ever improve the layout — it returns null (keep the
        // muxer's bytes) for anything already correct or not fully understood.
        // See VideoTranscodeTargetTest.muxerOutputIsRewrittenIndexFirst, which asserts the
        // POSTCONDITION rather than the mechanism.
        val bytes = Mp4Faststart.relocate(muxed) ?: muxed
        if (bytes.size > maxBytes) null else bytes
    } catch (t: Throwable) {
        android.util.Log.w("LocalMedia", "video transcode failed (falling back to strip): ${t.message}")
        null
    } finally {
        runCatching { decoder?.stop() }; runCatching { decoder?.release() }
        runCatching { encoder?.stop() }; runCatching { encoder?.release() }
        runCatching { muxer?.release() }
        runCatching { inputSurface?.release() }
        runCatching { extractor?.release() }
        runCatching { audioEx?.release() }
        runCatching { out.delete() }
    }
}

/** The remux behind [readVideoBytes]. Null if the source can't be remuxed (caller falls back). */
private fun stripVideoMetadata(context: Context, uri: Uri, maxBytes: Int): ByteArray? {
    val out = File.createTempFile("strip", ".mp4", context.cacheDir)
    var extractor: android.media.MediaExtractor? = null
    var muxer: android.media.MediaMuxer? = null
    return try {
        extractor = android.media.MediaExtractor().apply { setDataSource(context, uri, null) }
        muxer = android.media.MediaMuxer(out.absolutePath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        // Map every source track to the output, remembering the largest sample so one buffer fits all.
        val trackMap = HashMap<Int, Int>()
        var bufSize = 256 * 1024
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(android.media.MediaFormat.KEY_MIME) ?: continue
            if (!mime.startsWith("video/") && !mime.startsWith("audio/")) continue  // drop timed-metadata tracks
            if (format.containsKey(android.media.MediaFormat.KEY_MAX_INPUT_SIZE)) {
                bufSize = max(bufSize, format.getInteger(android.media.MediaFormat.KEY_MAX_INPUT_SIZE))
            }
            trackMap[i] = muxer.addTrack(format)
            extractor.selectTrack(i)
        }
        if (trackMap.isEmpty()) return null

        // Preserve display rotation (geometry, not identity) — without it portrait clips play sideways.
        val rotation = runCatching {
            android.media.MediaMetadataRetriever().use { r ->
                r.setDataSource(context, uri)
                r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
            }
        }.getOrNull() ?: 0
        if (rotation != 0) muxer.setOrientationHint(rotation)

        muxer.start()
        val buffer = java.nio.ByteBuffer.allocate(bufSize)
        val info = android.media.MediaCodec.BufferInfo()
        while (true) {
            info.offset = 0
            info.size = extractor.readSampleData(buffer, 0)
            if (info.size < 0) break
            val dst = trackMap[extractor.sampleTrackIndex]
            if (dst != null) {
                info.presentationTimeUs = extractor.sampleTime
                info.flags = extractor.sampleFlags
                muxer.writeSampleData(dst, buffer, info)
            }
            extractor.advance()
        }
        muxer.stop()
        if (out.length() > maxBytes) null else out.readBytes()
    } catch (t: Throwable) {
        android.util.Log.w("LocalMedia", "video metadata strip failed: ${t.message}")
        null
    } finally {
        runCatching { muxer?.release() }
        runCatching { extractor?.release() }
        out.delete()
    }
}

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
    // Auto-optimize → 1600px JPEG @ 62% (cross-platform share spec, Apple parity — see MediaTargets);
    // off → original quality. Either way we re-encode from a decoded bitmap, which bakes the rotation
    // into the pixels AND strips all EXIF (orientation, GPS, device) — so nothing sideways and no
    // location leaks.
    maxDim: Int = if (CircleSettings.optimize(HavenNet.activeCircle.value))
        MediaTargets.STILL_LONG_EDGE else MediaTargets.STILL_LONG_EDGE_UNOPTIMIZED,
    quality: Int = if (CircleSettings.optimize(HavenNet.activeCircle.value))
        MediaTargets.STILL_JPEG_QUALITY else MediaTargets.STILL_JPEG_QUALITY_UNOPTIMIZED,
): ByteArray? {
    val raw = runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
        ?: return null.also { android.util.Log.w("LocalMedia", "openInputStream null for $uri") }
    return downscaleJpeg(raw, maxDim, quality)
}

/**
 * The producer half of [loadAndDownscale], on bytes already in hand.
 *
 * Split out for [MediaReoptimizer]: a stored blob is decrypted to a ByteArray, never to a content
 * URI, and round-tripping it through a temp file purely to satisfy a `Uri` parameter would be a
 * second copy of a photo for no reason. Both callers share ONE encoder, so a still re-optimized today
 * is byte-for-byte what the composer would produce for the same source — which is what makes the
 * probe's "already at target" verdict trustworthy on the second pass.
 */
fun downscaleJpeg(raw: ByteArray, maxDim: Int, quality: Int): ByteArray? = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
    val longest = max(bounds.outWidth, bounds.outHeight).coerceAtLeast(1)
    var sample = 1
    while (longest / sample > maxDim) sample *= 2   // sample DOWN to ~maxDim — avoids OOM

    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    var bmp = BitmapFactory.decodeByteArray(raw, 0, raw.size, opts)
        ?: return null.also { android.util.Log.w("LocalMedia", "image decode failed (${raw.size}B)") }

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
}.getOrElse { android.util.Log.e("LocalMedia", "downscaleJpeg failed", it); null }

/**
 * A picked photo as a base64 JPEG ready for [ProfileStore.setAvatar] — null if the decode failed.
 *
 * 192px @ 70% is the iOS wire spec (Profile.swift `avatarBase64`): this blob rides the signed
 * profile card to every circle member, so it stays small on purpose. Onboarding and Edit profile
 * both go through here so the two can't drift.
 */
fun loadAvatarB64(context: Context, uri: Uri): String? =
    loadAndDownscale(context, uri, maxDim = MediaTargets.AVATAR_LONG_EDGE, quality = MediaTargets.AVATAR_JPEG_QUALITY)
        ?.let { android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP) }
