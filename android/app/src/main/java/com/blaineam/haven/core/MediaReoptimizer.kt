package com.blaineam.haven.core

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield

/**
 * Re-encode media I ALREADY shared, and re-share it, so the whole circle gets the smaller copy.
 * The Android port of Apple `MediaReoptimizer` (apple/HavenApp/MediaReoptimize.swift), whose header
 * comment is the spec for this file; the design argument is not repeated here, only the decisions
 * that differ because this is Android.
 *
 * The compression rewrite in [MediaTargets] only ever applied to the next thing you post. Everything
 * already out there stayed exactly as big as it was — and every member of those circles is holding
 * the same bytes. Nothing in the app could ever make that better; the only lever was deleting it.
 * This is that lever.
 *
 *
 * THE HARD PART: a ref IS the digest of its bytes.
 *
 * [LocalMedia] names a blob by the sha-256 of its plaintext, and that is load-bearing security, not
 * a naming convention: it is what stops a relay operator (always an ordinary circle member) from
 * PUTting their bytes at someone else's ref and having every client render it — see
 * `LocalMedia.verifiesRef`, checked on every read. So re-encoding is not an in-place operation. New
 * bytes are, by construction, a NEW ADDRESS.
 *
 * The three ways out, and why only one survives:
 *
 *  1. An alias table ("ref A now means the bytes at ref B"). Rejected outright — that is precisely
 *     the indirection content addressing exists to forbid. Whoever controls the table controls what
 *     a signed post displays, and the signature stops binding the media.
 *  2. Keep both, prefer the smaller. Rejected — it makes the saving imaginary. Both blobs stay
 *     referenced so neither can ever be swept, and every member now stores the original AND the copy.
 *  3. EDIT THE POST to point at the new ref. Chosen. See [HavenNet.applyReoptimized].
 *
 * Two consequences fall straight out of (3), and both are load-bearing: only MY OWN posts and
 * comments are eligible (an Edit is author-signed), and THE OLD BLOB IS NOT DELETED HERE (a member
 * who is offline still holds the pre-edit post naming the old ref). Both are argued where they are
 * enforced, in [HavenNet.reoptimizeTargets] and [HavenNet.applyReoptimized].
 *
 *
 * BOUNDING. This encodes video, which means it is the exact shape of task that has cost this
 * codebase a machine before. So: it never starts on its own (no timer, no launch hook, no
 * `WorkManager` job — the only caller is a button in Settings ▸ Storage), it runs at most
 * [BATCH_LIMIT] items per tap and then STOPS and asks again, it is cancellable between items, it
 * refuses to start an item without disk headroom, and [running] admits exactly one encode at a time.
 *
 *
 * ANDROID-ONLY: PROBING COSTS A DECRYPT.
 *
 * iOS keeps media plaintext at rest (file-protection does the work), so its probe is a header read.
 * Android keeps it SEALED — the plaintext only exists at open time. So scanning has to decrypt.
 * Three things keep that honest:
 *
 *  - The [MediaOptimizationTarget.MINIMUM_INTERESTING_BYTES] gate is applied to the SEALED file
 *    length first, which is free (AEAD overhead is a few bytes), so the long tail of small stuff is
 *    dropped before any decrypt happens at all.
 *  - Videos decrypt through `openCircleMediaFile`, which runs in NATIVE memory straight to a file —
 *    a 320 MB clip never touches the managed heap.
 *  - A plaintext cache this pass CREATED is deleted again the moment it is done with
 *    ([LocalMedia.dropPlainCache]), so scanning a 1.3 GB library does not leave 1.3 GB of decrypted
 *    video on disk. A cache that was already there (the clip has been played) is left alone.
 */
object MediaReoptimizer {

    /**
     * One tap = at most this many items, then it stops and reports. Identical to iOS. A large clip
     * takes tens of seconds, so a full batch is minutes, not hours, and the user is never more than
     * one batch away from an idle app.
     */
    const val BATCH_LIMIT = 25

    /** Cap on the persisted skip set, so the don't-retry list cannot itself become the leak. */
    const val SKIP_CAP = 500

    /** Refuse to start an item without room for the decrypt, the output, and a margin. */
    const val DISK_MARGIN_BYTES = 512L * 1024 * 1024

    private const val PREFS = "haven.reoptimize"
    private const val K_SKIP = "skip"

    private lateinit var appContext: Context
    private val prefs get() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
        skipped = prefs.getStringSet(K_SKIP, emptySet())?.toMutableSet() ?: mutableSetOf()
    }

    /** One post or comment of mine that carries media — everything an Edit needs to be written back
     *  unchanged except for the media array. iOS `ReoptimizeTarget`. */
    data class Target(
        val circleId: String,
        val eventId: String,
        val body: String,
        val media: List<String>,
        val music: uniffi.haven_ffi.TrackRefFfi?,
        val muteVideo: Boolean,
        val createdAtMs: Long,
    )

    /** Shrink the blob, or only publish a missing video poster (no re-transcode). */
    enum class Work { REENCODE, POSTER_ONLY }

    /** One blob of mine re-optimize can improve (smaller bytes and/or a missing video poster). */
    data class Candidate(
        val ref: String,
        val circleId: String,
        val work: Work,
        val shape: MediaOptimizationTarget.Shape,
        /** Timestamp of the oldest post/comment of mine that names it. */
        val firstSharedMs: Long,
        /** Shared before the encoder rewrite landed — REPORTED, not used as a gate. See [scan]. */
        val legacyByAge: Boolean,
    )

    // ---- Observable state (Compose reads these directly) ----------------------------------------

    val scanning = mutableStateOf(false)
    val running = mutableStateOf(false)
    val candidates = mutableStateOf<List<Candidate>>(emptyList())
    val doneCount = mutableIntStateOf(0)
    val batchCount = mutableIntStateOf(0)
    val currentLabel = mutableStateOf("")
    val lastSummary = mutableStateOf<String?>(null)
    /** Set when a run stopped for a reason the user needs to know (no disk, cancelled). */
    val lastWarning = mutableStateOf<String?>(null)
    /** Distinguishes "not measured yet" from "measured, and there is genuinely nothing to do" —
     *  otherwise a scan of a clean library looks identical to a button that did nothing. */
    val hasScanned = mutableStateOf(false)

    @Volatile private var cancelRequested = false

    /**
     * THE single-flight latch — "one encode in flight" is a hard requirement of this feature, not a
     * nicety, and [running] alone cannot enforce it: it is a Compose state read on one thread and
     * written on another, so two taps landing together can both observe `false` and both proceed.
     * `compareAndSet` closes that window. The disabled button is the polite guard; this is the real one.
     */
    private val inFlight = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Total bytes of shrink candidates still waiting (poster-only is a small JPEG). */
    val pendingBytes: Long
        get() = candidates.value.filter { it.work == Work.REENCODE }.sumOf { it.shape.bytes }

    val posterOnlyCount: Int
        get() = candidates.value.count { it.work == Work.POSTER_ONLY }

    fun cancel() { cancelRequested = true }

    // ---- Don't-retry set ------------------------------------------------------------------------
    //
    // A blob that failed to encode, or that came back no smaller, must not be offered again on every
    // scan forever — that would burn minutes of CPU per tap re-deciding the same thing, and for the
    // "already lean but HEVC" case the answer would never change. Persisted so it survives a
    // relaunch, and bounded so it cannot itself grow without limit.

    private var skipped: MutableSet<String> = mutableSetOf()

    /** Pure so the bound is testable: add [ref], then keep at most [cap] entries. */
    fun boundSkipSet(existing: Set<String>, ref: String, cap: Int = SKIP_CAP): Set<String> {
        val next = LinkedHashSet(existing)
        next.add(ref)
        return if (next.size <= cap) next else next.drop(next.size - cap).toSet()
    }

    private fun skip(ref: String) {
        skipped = boundSkipSet(skipped, ref).toMutableSet()
        // A DEFENSIVE COPY, not `skipped` itself: SharedPreferences keeps the Set instance you hand
        // it and serializes it later, so passing a set you go on to mutate is the classic way to get
        // a persisted value that doesn't match what you wrote.
        runCatching { prefs.edit().putStringSet(K_SKIP, HashSet(skipped)).apply() }
    }

    // ---- Pure helpers, split out so the parts that decide are testable off-device ----------------

    /**
     * Apply re-encode swaps and/or new video posters to one media array.
     * Delegates to [MediaVariants.rewriteMedia] so poster markers stay paired with the playable clip.
     */
    fun rewriteMedia(
        media: List<String>,
        swap: Map<String, String>,
        posters: Map<String, String> = emptyMap(),
    ): List<String> = MediaVariants.rewriteMedia(media, swap, posters)

    /** Re-encodes first (biggest), then poster-only. */
    fun ordered(found: List<Candidate>): List<Candidate> =
        found.sortedWith(
            compareBy<Candidate> { if (it.work == Work.REENCODE) 0 else 1 }
                .thenByDescending { it.shape.bytes },
        )

    /** Room for the decrypt (≈[bytes]), the encoded output, and a margin. Filling the disk in a loop
     *  is the other way a job like this ruins someone's day. Unknown free space does NOT block. */
    fun hasDiskHeadroom(freeBytes: Long, bytes: Long): Boolean =
        freeBytes <= 0L || freeBytes > bytes + MediaTargets.MAX_VIDEO_BYTES + DISK_MARGIN_BYTES

    // ---- Scan -----------------------------------------------------------------------------------

    /**
     * Find my shared media that is above target, **and** videos that never published a poster.
     *
     * SHAPE alone is dispositive for re-encode; AGE is only REPORTED. POSTER-ONLY is separate: a
     * video may already be at target (so it will never re-encode) yet still lack a
     * `poster:<video>:<image>` marker — super data saver needs that still. We cut a JPEG from the
     * existing file and edit the post without re-transcoding the clip.
     */
    suspend fun scan() = withContext(Dispatchers.IO) {
        if (!inFlight.compareAndSet(false, true)) return@withContext
        scanning.value = true
        lastWarning.value = null
        // Clear the cancel latch BEFORE the loop below reads it. run() finishes with a re-scan, so a
        // latch left set by "Stop after this one" would make that re-scan abort on its first item and
        // report a stale/empty remaining count. The Stop control only exists while a run is in flight.
        cancelRequested = false
        try {
            val firstShared = HashMap<String, Long>()
            val circleOf = HashMap<String, String>()
            val needsPoster = HashSet<String>()
            for (t in HavenNet.reoptimizeTargets()) {
                for (ref in t.media) {
                    if (LocalMedia.isSynthetic(ref) || LocalMedia.isAudio(ref)) continue
                    val prev = firstShared[ref]
                    if (prev == null || t.createdAtMs < prev) firstShared[ref] = t.createdAtMs
                    circleOf.putIfAbsent(ref, t.circleId)
                    if (LocalMedia.isVideo(ref) && MediaVariants.posterFor(ref, t.media) == null) {
                        needsPoster.add(ref)
                    }
                }
            }

            val found = ArrayList<Candidate>()
            for ((ref, sinceMs) in firstShared) {
                if (cancelRequested) break
                val circleId = circleOf[ref] ?: continue
                val sealed = LocalMedia.sealedSize(ref)
                if (sealed <= 0) continue
                val wantPoster = needsPoster.contains(ref) && !skipped.contains("poster:$ref")
                val aboveInteresting = sealed >= MediaOptimizationTarget.MINIMUM_INTERESTING_BYTES
                // Poster-only may be a small clip; re-encode still requires the free sealed gate.
                if (!aboveInteresting && !wantPoster) continue

                val shape = if (aboveInteresting || LocalMedia.isVideo(ref)) {
                    probe(circleId, ref)
                } else null
                val legacy = MediaOptimizationTarget.isLegacyByAge(sinceMs)
                if (shape != null && shape.aboveTarget && aboveInteresting && !skipped.contains(ref)) {
                    found.add(Candidate(ref, circleId, Work.REENCODE, shape, sinceMs, legacy))
                } else if (LocalMedia.isVideo(ref) && wantPoster) {
                    val s = shape ?: MediaOptimizationTarget.Shape(
                        bytes = sealed,
                        maxDimension = 0,
                        codec = "video",
                        bitrate = 0,
                        seconds = 0.0,
                        aboveTargetReason = null,
                    )
                    found.add(Candidate(ref, circleId, Work.POSTER_ONLY, s, sinceMs, legacy))
                }
            }
            candidates.value = ordered(found)
            hasScanned.value = true
        } finally {
            scanning.value = false
            inFlight.set(false)
        }
    }

    /** Decrypt just enough of [ref] to judge it, then put the disk back the way we found it. */
    private fun probe(circleId: String, ref: String): MediaOptimizationTarget.Shape? {
        if (LocalMedia.isVideo(ref)) {
            val cached = LocalMedia.hasPlainCache(ref, "mp4")
            val file = LocalMedia.videoFile(circleId, ref) ?: return null
            val shape = MediaOptimizationTarget.probeVideoFile(file)
            if (!cached) LocalMedia.dropPlainCache(ref, "mp4")
            return shape
        }
        val bytes = LocalMedia.load(circleId, ref) ?: return null   // size-guarded; oversized → skip
        return MediaOptimizationTarget.probeImageBytes(bytes)
    }

    // ---- Run ------------------------------------------------------------------------------------

    /** Re-encode / poster-fill up to [BATCH_LIMIT] candidates and re-share every post that named them. */
    suspend fun run() = withContext(Dispatchers.IO) {
        if (candidates.value.isEmpty()) return@withContext
        if (!inFlight.compareAndSet(false, true)) return@withContext
        running.value = true
        cancelRequested = false
        lastWarning.value = null
        doneCount.intValue = 0
        var stopped: String? = null
        try {
            val batch = candidates.value.take(BATCH_LIMIT)
            batchCount.intValue = batch.size
            var before = 0L
            var after = 0L
            val swap = LinkedHashMap<String, String>()
            val sealedTo = HashMap<String, String>()
            // old video ref -> poster image ref
            val posters = LinkedHashMap<String, String>()
            var postersAdded = 0

            for (c in batch) {
                if (cancelRequested) { stopped = "Stopped."; break }

                when (c.work) {
                    Work.POSTER_ONLY -> {
                        currentLabel.value = "poster"
                        if (!hasDiskHeadroom(LocalMedia.usableSpaceBytes(), 8L * 1024 * 1024)) {
                            stopped = "Stopped — not enough free space to re-encode safely."
                            break
                        }
                        val pRef = LocalMedia.ensurePosterImage(c.circleId, c.ref)
                        if (!pRef.isNullOrEmpty()) {
                            posters[c.ref] = pRef
                            sealedTo[c.ref] = c.circleId
                            postersAdded++
                        } else {
                            skip("poster:${c.ref}")
                        }
                        doneCount.intValue++
                        yield()
                    }
                    Work.REENCODE -> {
                        if (!hasDiskHeadroom(LocalMedia.usableSpaceBytes(), c.shape.bytes)) {
                            stopped = "Stopped — not enough free space to re-encode safely."
                            break
                        }
                        currentLabel.value = if (LocalMedia.isVideo(c.ref)) "video" else "photo"
                        val encoded = encode(c)
                        val newRef = encoded?.videoRef
                        val newBytes = encoded?.bytes ?: -1L
                        val posterRef = encoded?.posterRef
                        if (newRef == null || newRef == c.ref || newBytes <= 0) {
                            // Re-encode failed — still try a poster for videos that never published one.
                            if (LocalMedia.isVideo(c.ref)) {
                                LocalMedia.ensurePosterImage(c.circleId, c.ref)?.let {
                                    posters[c.ref] = it
                                    sealedTo[c.ref] = c.circleId
                                    postersAdded++
                                }
                            }
                            skip(c.ref)
                            doneCount.intValue++
                            yield()
                            continue
                        }
                        if (!MediaOptimizationTarget.keepsNewEncode(c.shape.bytes, newBytes)) {
                            android.util.Log.i(
                                "Reoptimize",
                                "${c.ref.take(12)} came back no smaller ($newBytes vs ${c.shape.bytes}) — keeping the original",
                            )
                            LocalMedia.delete(newRef)
                            if (LocalMedia.isVideo(c.ref)) {
                                LocalMedia.ensurePosterImage(c.circleId, c.ref)?.let {
                                    posters[c.ref] = it
                                    sealedTo[c.ref] = c.circleId
                                    postersAdded++
                                }
                            }
                            skip(c.ref)
                            doneCount.intValue++
                            yield()
                            continue
                        }
                        before += c.shape.bytes
                        after += newBytes
                        swap[c.ref] = newRef
                        sealedTo[c.ref] = c.circleId
                        if (!posterRef.isNullOrEmpty()) {
                            posters[c.ref] = posterRef
                            postersAdded++
                        } else if (LocalMedia.isVideo(c.ref)) {
                            LocalMedia.ensurePosterImage(c.circleId, newRef)?.let {
                                posters[c.ref] = it
                                postersAdded++
                            }
                        }
                        doneCount.intValue++
                        yield()
                    }
                }
            }

            // SCOPED TO THE CIRCLE THE NEW BLOB WAS SEALED TO (Android sealed-at-rest).
            var reshared = 0
            if (swap.isNotEmpty() || posters.isNotEmpty()) {
                for (t in HavenNet.reoptimizeTargets()) {
                    val applicableSwap = swap.filterKeys { sealedTo[it] == t.circleId }
                    val postPosters = HashMap<String, String>()
                    for ((oldV, pImg) in posters) {
                        if (sealedTo[oldV] != t.circleId) continue
                        if (!t.media.contains(oldV)) continue
                        val willSwap = applicableSwap.containsKey(oldV)
                        val missing = MediaVariants.posterFor(oldV, t.media) == null
                        if (willSwap || missing) postPosters[oldV] = pImg
                    }
                    if (t.media.none { applicableSwap.containsKey(it) } && postPosters.isEmpty()) continue
                    val media = rewriteMedia(t.media, applicableSwap, postPosters)
                    if (media != t.media && HavenNet.applyReoptimized(t, media)) reshared++
                }
            }

            lastSummary.value = when {
                swap.isEmpty() && postersAdded == 0 -> "Nothing could be improved"
                else -> {
                    val parts = ArrayList<String>()
                    if (swap.isNotEmpty()) {
                        parts.add(
                            "${swap.size} item${plural(swap.size)} smaller " +
                                "(${fmt(before)} → ${fmt(after)}, ${pct(before, after)}%)",
                        )
                    }
                    if (postersAdded > 0) {
                        parts.add("$postersAdded video poster${plural(postersAdded)} added")
                    }
                    parts.add("$reshared post${plural(reshared)} re-shared")
                    parts.joinToString(" · ")
                }
            }
            android.util.Log.i("Reoptimize", lastSummary.value ?: "")
            lastWarning.value = stopped
        } finally {
            running.value = false
            currentLabel.value = ""
            inFlight.set(false)
        }
        val raised = lastWarning.value
        scan()
        if (raised != null && lastWarning.value == null) lastWarning.value = raised
    }

    private data class Encoded(val videoRef: String, val bytes: Long, val posterRef: String?)

    /**
     * Re-encode through the same entry points as a brand-new attachment. Videos use [LocalMedia.prepareVideo]
     * so a poster still is produced for the media rewrite.
     */
    private fun encode(c: Candidate): Encoded? {
        if (LocalMedia.isVideo(c.ref)) {
            val cached = LocalMedia.hasPlainCache(c.ref, "mp4")
            val src = LocalMedia.videoFile(c.circleId, c.ref) ?: return null
            val prepared = runCatching {
                LocalMedia.prepareVideo(
                    appContext, Uri.fromFile(src), c.circleId,
                    forceOptimize = true,
                )
            }.getOrNull()
            if (!cached) LocalMedia.dropPlainCache(c.ref, "mp4")
            if (prepared == null || prepared.isEmpty) return null
            // Plaintext size of the new playable for the shrink check.
            val plain = LocalMedia.load(c.circleId, prepared.videoRef)?.size?.toLong()
                ?: LocalMedia.sealedSize(prepared.videoRef)
            return Encoded(prepared.videoRef, plain, prepared.posterRef)
        }
        val src = LocalMedia.load(c.circleId, c.ref) ?: return null
        val out = downscaleJpeg(src, MediaTargets.STILL_LONG_EDGE,
            MediaTargets.STILL_JPEG_QUALITY) ?: return null
        if (out.isEmpty()) return null
        val ref = LocalMedia.store(c.circleId, out, isVideo = false)
        return Encoded(ref, out.size.toLong(), null)
    }

    // ---- Formatting -----------------------------------------------------------------------------

    private fun plural(n: Int) = if (n == 1) "" else "s"

    fun fmt(bytes: Long): String =
        if (::appContext.isInitialized) android.text.format.Formatter.formatFileSize(appContext, bytes)
        else "$bytes B"

    fun pct(before: Long, after: Long): Int =
        if (before > 0) maxOf(0, 100 - (after * 100 / before).toInt()) else 0
}
