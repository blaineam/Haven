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

    /** One blob of mine whose stored bytes are above target. */
    data class Candidate(
        val ref: String,
        val circleId: String,
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

    /** Total bytes of everything still waiting. */
    val pendingBytes: Long get() = candidates.value.sumOf { it.shape.bytes }

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
     * Apply the batch's old-ref → new-ref swap to one media array.
     *
     * ORDER IS PRESERVED and anything not swapped passes through untouched — including synthetic
     * `geo:` location pins, which ride in the same array and carry no bytes. Getting this wrong
     * would silently reorder or drop attachments on a post the user never edited.
     */
    fun rewriteMedia(media: List<String>, swap: Map<String, String>): List<String> =
        media.map { swap[it] ?: it }

    /** Biggest first: the win is dominated by a handful of videos, so a user who runs one batch and
     *  stops should still have captured most of the saving. */
    fun ordered(found: List<Candidate>): List<Candidate> = found.sortedByDescending { it.shape.bytes }

    /** Room for the decrypt (≈[bytes]), the encoded output, and a margin. Filling the disk in a loop
     *  is the other way a job like this ruins someone's day. Unknown free space does NOT block. */
    fun hasDiskHeadroom(freeBytes: Long, bytes: Long): Boolean =
        freeBytes <= 0L || freeBytes > bytes + MediaTargets.MAX_VIDEO_BYTES + DISK_MARGIN_BYTES

    // ---- Scan -----------------------------------------------------------------------------------

    /**
     * Find my shared media that is above target.
     *
     * TWO SIGNALS, and how they combine is not the obvious reading. AGE
     * ([MediaOptimizationTarget.LEGACY_CUTOFF_MS]) is a fact about provenance: media shared before
     * that instant cannot have come from the current encoder. SHAPE
     * ([MediaOptimizationTarget.judgeVideo] / [MediaOptimizationTarget.judgeImage]) is a fact about
     * the bytes. SHAPE alone is dispositive and AGE is only REPORTED — age would exclude media shared
     * after the cutoff with auto-optimize off, which is half the population this button exists for,
     * and would include media already at target that would gain nothing. Asking the file is strictly
     * better than asking the calendar.
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
            // Earliest time each ref was shared by me, and the circle it can be decrypted with. A ref
            // used by several posts is ONE encode.
            val firstShared = HashMap<String, Long>()
            val circleOf = HashMap<String, String>()
            for (t in HavenNet.reoptimizeTargets()) {
                for (ref in t.media) {
                    // geo: pins et al. carry no bytes; audio is provably at target on Android (see
                    // MediaOptimizationTarget.judgeAudio); a skipped ref has already been decided.
                    if (LocalMedia.isSynthetic(ref) || LocalMedia.isAudio(ref)) continue
                    if (skipped.contains(ref)) continue
                    val prev = firstShared[ref]
                    if (prev == null || t.createdAtMs < prev) firstShared[ref] = t.createdAtMs
                    circleOf.putIfAbsent(ref, t.circleId)
                }
            }

            val found = ArrayList<Candidate>()
            for ((ref, sinceMs) in firstShared) {
                if (cancelRequested) break
                val circleId = circleOf[ref] ?: continue
                // Only refs whose bytes are actually HERE. One that has been evicted or never arrived
                // can't be re-encoded from nothing, and re-downloading a 320 MB blob in order to
                // shrink it is a decision for the user, not for a settings button.
                val sealed = LocalMedia.sealedSize(ref)
                if (sealed <= 0) continue
                // Free gate on the SEALED length before any decrypt — see the class doc.
                if (sealed < MediaOptimizationTarget.MINIMUM_INTERESTING_BYTES) continue
                val shape = probe(circleId, ref) ?: continue
                if (!shape.aboveTarget) continue
                found.add(Candidate(ref, circleId, shape, sinceMs,
                    MediaOptimizationTarget.isLegacyByAge(sinceMs)))
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

    /** Re-encode up to [BATCH_LIMIT] candidates and re-share every post that named them. */
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
            // old ref -> new ref. Built across the WHOLE batch, then applied in ONE pass, so a post
            // with three rewritten photos gets a single edit rather than three.
            val swap = LinkedHashMap<String, String>()
            // old ref -> the circle its NEW blob is sealed to. See the scoping note at the apply below.
            val sealedTo = HashMap<String, String>()

            for (c in batch) {
                if (cancelRequested) { stopped = "Stopped."; break }
                if (!hasDiskHeadroom(LocalMedia.usableSpaceBytes(), c.shape.bytes)) {
                    stopped = "Stopped — not enough free space to re-encode safely."
                    break
                }
                currentLabel.value = if (LocalMedia.isVideo(c.ref)) "video" else "photo"

                // PLAINTEXT sizes on both sides. Comparing the new blob's sealed file length against
                // the old blob's plaintext length would compare two different quantities; the AEAD
                // overhead is small, but the shrink rule is the one thing here that must be exact.
                val encoded = encode(c)
                val newRef = encoded?.first
                val newBytes = encoded?.second ?: -1L
                if (newRef == null || newRef == c.ref || newBytes <= 0) {
                    skip(c.ref)
                    doneCount.intValue++
                    yield()
                    continue
                }
                // A rewrite that doesn't clearly win is worse than none: every member pays a
                // re-download for nothing. Drop it and never offer this ref again.
                if (!MediaOptimizationTarget.keepsNewEncode(c.shape.bytes, newBytes)) {
                    android.util.Log.i("Reoptimize",
                        "${c.ref.take(12)} came back no smaller (${newBytes} vs ${c.shape.bytes}) — keeping the original")
                    LocalMedia.delete(newRef)
                    skip(c.ref)
                    doneCount.intValue++
                    yield()
                    continue
                }
                before += c.shape.bytes
                after += newBytes
                swap[c.ref] = newRef
                sealedTo[c.ref] = c.circleId
                doneCount.intValue++
                yield()   // cancellation point + let the UI breathe between items
            }

            // Apply. Targets are re-read NOW rather than reused from the scan: minutes have passed,
            // and a post edited or retracted in the meantime must be edited against its CURRENT
            // state, not a stale copy that would silently revert the user's own change.
            //
            // SCOPED TO THE CIRCLE THE NEW BLOB WAS SEALED TO — an Android-only constraint with no
            // counterpart on iOS, which keeps media plaintext at rest. Here `LocalMedia.store` seals
            // to ONE circle and there is one file per ref, so a blob encoded while walking circle A
            // opens with A's key and only A's. If the same ref was also shared into circle B and we
            // rewrote B's post too, B's copy of the post would name a blob this device cannot open —
            // a placeholder where the user's own photo used to be. So B keeps naming the OLD ref,
            // which still exists and still works; it simply misses this round's saving.
            var reshared = 0
            if (swap.isNotEmpty()) {
                for (t in HavenNet.reoptimizeTargets()) {
                    val applicable = swap.filterKeys { sealedTo[it] == t.circleId }
                    if (t.media.none { applicable.containsKey(it) }) continue
                    if (HavenNet.applyReoptimized(t, rewriteMedia(t.media, applicable))) reshared++
                }
            }

            lastSummary.value = if (swap.isEmpty()) "Nothing could be made smaller"
            else "${swap.size} item${plural(swap.size)} re-shared across $reshared post${plural(reshared)} · " +
                "${fmt(before)} → ${fmt(after)} (${pct(before, after)}% smaller)"
            android.util.Log.i("Reoptimize", lastSummary.value ?: "")
            lastWarning.value = stopped
        } finally {
            running.value = false
            currentLabel.value = ""
            // Released BEFORE the re-scan below, which takes the latch itself.
            inFlight.set(false)
        }
        // Re-scan so the remaining count is honest, and so anything just rewritten drops off the
        // list (nothing references the old ref any more, so it is no longer one of my shared items).
        scan()
    }

    /**
     * Re-encode one blob through the SAME entry points a brand-new attachment uses — that is the
     * whole point of `forceOptimize` on [readVideoBytes] and of the explicit target arguments to
     * [downscaleJpeg]. Not a parallel encoder: when [MediaTargets] changes again, old media follows
     * automatically. Returns (new ref, PLAINTEXT byte count), or null if nothing usable came out.
     */
    private fun encode(c: Candidate): Pair<String, Long>? {
        if (LocalMedia.isVideo(c.ref)) {
            val cached = LocalMedia.hasPlainCache(c.ref, "mp4")
            val src = LocalMedia.videoFile(c.circleId, c.ref) ?: return null
            val out = runCatching {
                readVideoBytes(appContext, Uri.fromFile(src), MediaTargets.MAX_VIDEO_BYTES,
                    forceOptimize = true)
            }.getOrNull()
            if (!cached) LocalMedia.dropPlainCache(c.ref, "mp4")
            if (out == null || out.isEmpty()) return null
            return LocalMedia.store(c.circleId, out, isVideo = true) to out.size.toLong()
        }
        val src = LocalMedia.load(c.circleId, c.ref) ?: return null
        val out = downscaleJpeg(src, MediaTargets.STILL_LONG_EDGE,
            MediaTargets.STILL_JPEG_QUALITY) ?: return null
        if (out.isEmpty()) return null
        return LocalMedia.store(c.circleId, out, isVideo = false) to out.size.toLong()
    }

    // ---- Formatting -----------------------------------------------------------------------------

    private fun plural(n: Int) = if (n == 1) "" else "s"

    fun fmt(bytes: Long): String =
        if (::appContext.isInitialized) android.text.format.Formatter.formatFileSize(appContext, bytes)
        else "$bytes B"

    fun pct(before: Long, after: Long): Int =
        if (before > 0) maxOf(0, 100 - (after * 100 / before).toInt()) else 0
}
