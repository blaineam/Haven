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

    /** Move a fully-reassembled sealed temp file into place under [ref] (load() opens it on read). */
    fun adoptSealedPart(ref: String, part: File): Boolean =
        runCatching {
            val dst = mediaFile(ref)   // adopts any legacy-key file first, so it isn't left orphaned
            runCatching { dst.delete() }
            part.renameTo(dst) || (part.copyTo(dst, overwrite = true).let { part.delete(); true })
        }.getOrDefault(false)

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
            (stem.length == 64 && stem.all { it in '0'..'9' || it in 'a'..'f' })

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
     *  cache dir, and legacy loose caches in filesDir. Returns (bytesFreed, filesRemoved). */
    fun sweepOrphans(keepKeys: Set<String>, graceMs: Long = 48L * 3600 * 1000): Pair<Long, Int> {
        val cutoff = System.currentTimeMillis() - graceMs
        var bytes = 0L
        var files = 0
        fun rm(f: File) { bytes += f.length(); files++; runCatching { f.delete() } }
        // Sealed blobs (also retires stale incoming_*.part / *.plain.tmp scratch — never in the keep-set).
        dir.listFiles()?.forEach { f ->
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
 * Read a picked video, capped to avoid huge attachments (default 60 MB), with its identifying
 * container metadata REMOVED — GPS above all.
 *
 * This used to hand the picker's raw bytes straight to [LocalMedia.store], so a clip recorded with
 * location on carried its capture coordinates to everyone in the circle. Photos were stripped
 * ([loadAndDownscale] re-encodes from a decoded bitmap); video was the hole. iOS strips via
 * `AVAssetExportSession.metadataItemFilter`; this is the Android half.
 *
 * The strip is a [MediaExtractor] → [MediaMuxer] passthrough remux: samples are copied verbatim, so
 * there is NO re-encode (same codec, same quality, no CPU burn on a big clip), but the muxer writes a
 * fresh container and only the boxes we ask for. Location rides in the container's `loci`/`udta`
 * userdata, which a new muxer emits only via `setLocation` — never called here, so it's simply gone.
 * The rotation hint IS carried across ([MediaMuxer.setOrientationHint]); it's display geometry, not
 * an identifier, and dropping it would turn every portrait clip sideways.
 *
 * Falls back to the raw bytes only if the remux fails outright (an unmuxable source) — the same
 * "post something rather than nothing" tradeoff iOS makes, and the one path that can still carry
 * metadata.
 */
fun readVideoBytes(context: Context, uri: Uri, maxBytes: Int = 60 * 1024 * 1024): ByteArray? {
    val raw = runCatching {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val bytes = input.readBytes()
            if (bytes.size > maxBytes) null else bytes
        }
    }.getOrNull() ?: return null
    return stripVideoMetadata(context, uri, maxBytes) ?: raw
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
