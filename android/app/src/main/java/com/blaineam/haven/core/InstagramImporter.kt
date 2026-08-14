package com.blaineam.haven.core

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import uniffi.haven_ffi.TrackRefFfi
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

/**
 * Runs an Instagram archive import: stage each item's media through Haven's normal compose path,
 * then author the post silently and backdated. Apple parity: `InstagramImporter.swift`, whose header
 * is the spec for this file — only the decisions that DIFFER because this is Android are re-argued
 * here.
 *
 * Deliberately reuses [LocalMedia.prepareVideo] / [downscaleJpeg] + [LocalMedia.store] rather than
 * writing archive bytes straight into the store. Those are what apply the optimize ladder, mint the
 * ≤32 KB thumb companion, and cut a poster still for every video — so imported media behaves like
 * media the user posted by hand instead of becoming a second class of blob nothing else understands.
 *
 * THREADING. Nothing here may touch the main looper: reading one entry is a disk read plus a CRC
 * over the whole entry, and an import is hundreds of those plus a MediaCodec transcode each. The
 * whole loop lives on [scope] (IO), and every store this writes ([HavenNet], [LocalMedia],
 * [KeptStoriesStore]) is already safe off-main — the only main-thread hop in the whole feature is
 * the one [HavenNet.afterAuthor] does for itself to bump `feedVersion`. Compose snapshot state is
 * thread-safe to write, which is what lets the progress fields below be set from the loop directly.
 *
 * ANDROID-ONLY: THE ARCHIVE IS A CONTENT URI, NOT A FILE.
 *
 * Apple's picker hands back a security-scoped URL that a `ZipReader` can open. Android's hands back
 * a `content://` document, and [InstagramArchive] (already landed and tested) reads a [File] via
 * `java.util.zip.ZipFile`, which needs random access to a real path. [openSource] bridges that, in
 * the order that costs the least — see its own note. A 1.28 GB export is exactly the size at which
 * "just copy it into the sandbox" is not free, so the copy is the LAST resort, not the first.
 */
object InstagramImporter {

    enum class Stage { IDLE, READING, PREVIEWING, IMPORTING, FINISHED, FAILED }

    /** Why an archive could not be used. The parser's three reasons plus the one only Android has. */
    enum class Problem { UNREADABLE, HTML_EXPORT, NO_CONTENT, NO_SPACE }

    // ---- Observable state (Compose reads these directly) ----------------------------------------

    val stage = mutableStateOf(Stage.IDLE)
    val summary = mutableStateOf<InstagramArchive.Summary?>(null)
    val done = mutableIntStateOf(0)
    val total = mutableIntStateOf(0)
    val importedCount = mutableIntStateOf(0)
    val skippedCount = mutableIntStateOf(0)
    val problem = mutableStateOf<Problem?>(null)

    /**
     * True while an import is running — the app-wide banner watches this, and the walkthrough uses
     * it to offer "browse while it runs" rather than holding the user on a progress bar.
     */
    val isRunning: Boolean get() = stage.value == Stage.IMPORTING

    /**
     * Whether the walkthrough should be on screen. A flag on the importer rather than a callback
     * threaded through Settings: the sheet is raised from two unrelated places (the Settings row and
     * the progress banner, which lives in a different tab's chrome), and both are asking the SAME
     * global job to show itself. Owning it here is what lets the banner reopen a running import from
     * anywhere without either surface knowing the other exists.
     */
    val showSheet = mutableStateOf(false)

    // ---- Wiring ---------------------------------------------------------------------------------

    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var cancelled = false
    private var archiveUri: Uri? = null

    fun init(ctx: Context) {
        appContext = ctx.applicationContext
    }

    private val initialized: Boolean get() = ::appContext.isInitialized

    // ---- Resume across launches -----------------------------------------------------------------

    /**
     * Everything needed to pick a half-finished import back up after the app is killed.
     *
     * The archive is stored as its document URI with a PERSISTED read grant (taken in [read]) — the
     * Android analogue of Apple's security-scoped bookmark, and the reason the picker is
     * `OPEN_DOCUMENT` rather than `GET_CONTENT`: only the former's grant survives a relaunch.
     *
     * [done] is an index into the deterministic item order — see `InstagramArchive.read`, which
     * sorts with a tiebreak precisely so this index means the same thing on every run.
     */
    data class Pending(
        val uri: String,
        val circleId: String,
        val includeStories: Boolean,
        val matchSongs: Boolean,
        val done: Int,
    )

    private const val PREFS = "haven.instagram.import"
    private const val K_PENDING = "pending"

    /** JSON rather than five keys, so the encode/decode round-trip is one testable pure function. */
    fun encodePending(p: Pending): String = JSONObject()
        .put("uri", p.uri)
        .put("circleId", p.circleId)
        .put("includeStories", p.includeStories)
        .put("matchSongs", p.matchSongs)
        .put("done", p.done)
        .toString()

    /** Null when the record is absent or unreadable. `matchSongs` defaults so a checkpoint written
     *  before song matching existed still decodes (Apple's `Pending` defaults it for the same
     *  reason). */
    fun decodePending(s: String?): Pending? {
        if (s.isNullOrBlank()) return null
        return runCatching {
            val o = JSONObject(s)
            val uri = o.optString("uri")
            if (uri.isBlank()) return null
            Pending(
                uri = uri,
                circleId = o.optString("circleId"),
                includeStories = o.optBoolean("includeStories", false),
                matchSongs = o.optBoolean("matchSongs", false),
                done = o.optInt("done", 0),
            )
        }.getOrNull()
    }

    private fun savePending(p: Pending) {
        if (!initialized) return
        runCatching {
            appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(K_PENDING, encodePending(p)).apply()
        }
    }

    private fun loadPending(): Pending? {
        if (!initialized) return null
        return decodePending(
            runCatching {
                appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(K_PENDING, null)
            }.getOrNull()
        )
    }

    private fun clearPending() {
        if (!initialized) return
        runCatching {
            appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(K_PENDING).apply()
        }
        // The staged copy exists only to serve a job; with the job gone it is a gigabyte of cache.
        runCatching { stagedFile().delete() }
    }

    /**
     * Where a resumed run should start, or null when there is nothing left to do.
     *
     * Pure so the off-by-one that would either re-import the last post or skip one is testable
     * without an archive.
     */
    fun resumeStart(pending: Pending, itemCount: Int): Int? {
        if (itemCount <= 0) return null
        val at = pending.done.coerceAtLeast(0)
        return if (at >= itemCount) null else at
    }

    /**
     * Restart an import interrupted by the app being killed or swiped away. Called on launch, after
     * [HavenNet] is up (publishing needs the engine).
     *
     * Silent when there is nothing pending, and silent when the archive no longer resolves — the
     * user may have deleted it, and nagging about that on every cold start would be worse than
     * quietly forgetting an import they can simply run again.
     */
    fun resumeIfNeeded() {
        if (!initialized || isRunning) return
        val p = loadPending() ?: return
        scope.launch {
            val uri = runCatching { Uri.parse(p.uri) }.getOrNull() ?: run { clearPending(); return@launch }
            val parsed = parse(uri)
            val s = (parsed as? Parsed.Ok)?.summary ?: run { clearPending(); return@launch }
            val items = orderedItems(s.items, p.includeStories)
            val start = resumeStart(p, items.size) ?: run { clearPending(); return@launch }
            archiveUri = uri
            summary.value = s
            problem.value = null
            stage.value = Stage.PREVIEWING          // `run` requires this state
            run(p.circleId, p.includeStories, p.matchSongs, startAt = start)
        }
    }

    // ---- Preview --------------------------------------------------------------------------------

    private sealed interface Parsed {
        data class Ok(val summary: InstagramArchive.Summary) : Parsed
        data class Bad(val problem: Problem) : Parsed
    }

    /**
     * Parse the picked archive and move to the preview. Nothing publishes until the user confirms
     * there.
     */
    fun read(context: Context, uri: Uri) {
        if (!initialized) init(context)
        cancelled = false
        problem.value = null
        summary.value = null
        stage.value = Stage.READING
        // Persist the read grant NOW, while we still hold it: without this the URI is unusable after
        // a relaunch and the whole resume path is dead. Best-effort — a provider that refuses to
        // persist still allows this session's import, it just can't survive being killed.
        runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        scope.launch {
            when (val parsed = parse(uri)) {
                is Parsed.Ok -> {
                    archiveUri = uri
                    summary.value = parsed.summary
                    stage.value = Stage.PREVIEWING
                }
                is Parsed.Bad -> {
                    problem.value = parsed.problem
                    stage.value = Stage.FAILED
                }
            }
        }
    }

    private fun parse(uri: Uri): Parsed {
        val src = try {
            openSource(uri)
        } catch (e: NoSpace) {
            return Parsed.Bad(Problem.NO_SPACE)
        } catch (e: Throwable) {
            return Parsed.Bad(Problem.UNREADABLE)
        }
        return src.use {
            try {
                Parsed.Ok(InstagramArchive.read(it.file))
            } catch (f: InstagramArchive.Failure) {
                Parsed.Bad(
                    when (f.kind) {
                        InstagramArchive.Failure.Reason.HTML_EXPORT -> Problem.HTML_EXPORT
                        InstagramArchive.Failure.Reason.NO_CONTENT -> Problem.NO_CONTENT
                        else -> Problem.UNREADABLE
                    }
                )
            } catch (t: Throwable) {
                Parsed.Bad(Problem.UNREADABLE)
            }
        }
    }

    /** Stop means STOP — see the mid-flight checks in [runLoop]. A cancel KEEPS the checkpoint, so
     *  this is really "pause": reopening the importer picks up where it stopped. */
    fun cancel() { cancelled = true }

    /** Forget the picked archive and go back to the walkthrough. Deliberately does NOT clear the
     *  checkpoint (Apple parity) — only finishing does. */
    fun reset() {
        if (isRunning) return
        cancelled = false
        summary.value = null
        archiveUri = null
        problem.value = null
        stage.value = Stage.IDLE
    }

    // ---- Import ---------------------------------------------------------------------------------

    /**
     * The publish order: NEWEST FIRST, the opposite of what reads naturally, and the reason the feed
     * stops jumping.
     *
     * The feed is newest-first (haven-p2p `map_feed` ends with `order.iter().rev()`). Importing
     * oldest-first therefore means every post published is NEWER than all the ones before it, so
     * each lands at the TOP of the list — directly above whatever the reader is looking at, shoving
     * the page down, hundreds of times. No amount of refresh throttling or scroll anchoring fixes
     * that; the content genuinely is arriving above them.
     *
     * Reversed, each post is OLDER than the last and lands at the BOTTOM, below the reader, where
     * new arrivals cost them nothing.
     *
     * Stories are excluded unless asked for, and that default is load-bearing: Instagram archives
     * EVERY story automatically, so `stories.json` is not "the ones you chose to keep" — it is all
     * of them, with nothing in the export marking which reached a Highlight.
     */
    fun orderedItems(items: List<InstagramArchive.Item>, includeStories: Boolean): List<InstagramArchive.Item> =
        (if (includeStories) items else items.filter { it.kind != InstagramArchive.Kind.STORY })
            .reversed()

    /**
     * Suggest a song ONLY into silence.
     *
     * A reel that shipped with its soundtrack keeps it — that audio is baked into the video and is
     * what the user actually chose; layering a guess over it would be worse than adding nothing.
     * (Apple can also IDENTIFY the baked-in audio with Shazam and attach it as a credit; there is no
     * equivalent on Android, so an audible post simply gets no chip.)
     */
    fun wantsSuggestedSong(matchSongs: Boolean, hasAudio: Boolean): Boolean = matchSongs && !hasAudio

    /**
     * Record a song this run has attached, so the next silent post prefers one not yet spoken for.
     *
     * Without the accumulation, one search term per year meant ONE song on every silent post of that
     * year — the import sounded like a single track on repeat. A null id (nothing came back, or the
     * search failed) must not enter the set: an empty string in `exclude` is a value the suggester
     * would then try to avoid matching, for a song that does not exist.
     */
    fun rememberUsedSong(used: MutableSet<String>, catalogId: String?): Set<String> {
        if (!catalogId.isNullOrBlank()) used.add(catalogId)
        return used
    }

    /**
     * Stable id for a kept story, derived from the archive entry it came from.
     *
     * [KeptStoriesStore.keep] is keyed on the original event id so a story is kept at most once — an
     * import has no Haven event to point at, so the archive path stands in. It is stable across
     * runs, which makes re-importing the same export idempotent instead of doubling every story.
     */
    fun keptIdentity(item: InstagramArchive.Item): String =
        "ig:" + (item.mediaNames.firstOrNull() ?: item.createdAt.toString())

    /**
     * Publish every parsed item into [circleId]. [startAt] resumes a previous run; a fresh import
     * starts at 0.
     */
    fun run(circleId: String, includeStories: Boolean = false, matchSongs: Boolean = false,
            startAt: Int = 0) {
        val s = summary.value ?: return
        val uri = archiveUri ?: return
        if (stage.value != Stage.PREVIEWING) return
        val items = orderedItems(s.items, includeStories)
        cancelled = false
        done.intValue = startAt.coerceIn(0, items.size)
        total.intValue = items.size
        importedCount.intValue = 0
        skippedCount.intValue = 0
        stage.value = Stage.IMPORTING
        // Record the job BEFORE any work, so a kill on the very first item still resumes.
        val pending = Pending(uri.toString(), circleId, includeStories, matchSongs, startAt)
        savePending(pending)
        scope.launch { runLoop(uri, items, pending) }
    }

    private fun runLoop(uri: Uri, items: List<InstagramArchive.Item>, pending: Pending) {
        val circleId = pending.circleId
        val matchSongs = pending.matchSongs
        val startAt = pending.done
        val src = try {
            openSource(uri)
        } catch (t: Throwable) {
            problem.value = if (t is NoSpace) Problem.NO_SPACE else Problem.UNREADABLE
            stage.value = Stage.FAILED
            return
        }
        val zip = runCatching { ZipFile(src.file) }.getOrNull()
        if (zip == null) {
            src.close()
            problem.value = Problem.UNREADABLE
            stage.value = Stage.FAILED
            return
        }
        var imported = 0
        var skipped = 0
        // Every catalog id already attached this run. Passed back into the suggester so each post
        // takes the best song NOT yet spoken for — without this, one search term per year meant one
        // song for every silent post in that year.
        val usedSongs = HashSet<String>()
        try {
            val byName = HashMap<String, ZipEntry>()
            zip.entries().asSequence().forEach { byName[it.name] = it }
            for (idx in startAt until items.size) {
                if (cancelled) break
                val item = items[idx]
                // One item must never be able to take a 372-item import down with it. Staging is
                // decode + transcode over bytes from someone else's encoder, so it is exactly where
                // an OutOfMemoryError or a codec blow-up comes from — and losing the post is a far
                // better outcome than losing the run. A failure here yields no refs, so it is
                // COUNTED AS SKIPPED, which is what the finish screen already knows how to say.
                val staged = runCatching { stageItem(item, zip, byName, circleId) }
                    .getOrElse { StagedItem(emptyList(), false) }
                // Stop means STOP. Staging an item can take a minute (a video transcode), and the
                // check above happened before all of it — so hitting Stop must not finish the clip
                // AND publish it, which is not what "stop" looks like from the outside.
                if (cancelled) break
                if (staged.refs.isEmpty()) {
                    skipped++
                } else {
                    var music: TrackRefFfi? = null
                    if (wantsSuggestedSong(matchSongs, staged.hasAudio)) {
                        val (year, month) = SongSuggester.yearMonth(item.createdAt)
                        music = runCatching {
                            SongSuggester.song(
                                themes = SongSuggester.captionThemes(item.body),
                                genre = item.musicGenre, year = year, month = month,
                                exclude = usedSongs,
                            )
                        }.getOrNull()
                        rememberUsedSong(usedSongs, music?.catalogId)
                    }
                    // Stories, when the user opted in, land as KEPT stories rather than feed posts:
                    // a personal snapshot on their profile with its media pinned. Keeping
                    // deliberately does not republish, which is what makes this safe — nobody else's
                    // feed fills with someone's old stories, and the circle is not asked to carry
                    // them at all. Posts and reels ARE feed content and publish normally (silent +
                    // backdated).
                    if (item.kind == InstagramArchive.Kind.STORY) {
                        runCatching {
                            KeptStoriesStore.keep(keptIdentity(item), item.body, staged.refs,
                                                  item.createdAt, music)
                        }
                    } else {
                        runCatching {
                            HavenNet.postImported(
                                circleId = circleId, body = item.body, media = staged.refs,
                                music = music, story = false, createdAt = item.createdAt.toULong(),
                            )
                        }
                    }
                    imported++
                }
                // Checkpoint after EVERY item. The unit of work is one post, so the most a kill can
                // cost is the item in flight — re-importing that one is the failure mode we accept,
                // rather than re-importing all 300.
                done.intValue = idx + 1
                importedCount.intValue = imported
                skippedCount.intValue = skipped
                savePending(pending.copy(done = idx + 1))
            }
        } catch (t: Throwable) {
            // Anything the per-item guard did not already absorb (the zip going away underneath us,
            // the checkpoint write failing). The run stops, but it stops in a state the UI can
            // render and the checkpoint survives, so it can be picked up again.
            android.util.Log.w("HavenImport", "instagram import aborted: ${t.message}")
        } finally {
            runCatching { zip.close() }
            src.close()
            // ALWAYS leave a terminal stage. A throw that escaped here would strand `stage` on
            // IMPORTING forever — a progress banner counting to nothing, on every screen, until the
            // app is killed.
            importedCount.intValue = imported
            skippedCount.intValue = skipped
            // A cancel keeps the checkpoint, so "Stop" is really "pause" — the next launch picks it
            // up. Finishing clears it (and drops any staged copy of the archive).
            if (!cancelled && done.intValue >= items.size) clearPending()
            stage.value = Stage.FINISHED
        }
    }

    /** One item's staged media refs, in album order, plus whether ANY of them makes a sound. */
    private class StagedItem(val refs: List<String>, val hasAudio: Boolean)

    /**
     * Turn one parsed item's archive entries into Haven media refs, in album order.
     *
     * A carousel stays ONE post: every photo in the album is staged into the same list, so a
     * 20-photo Instagram carousel arrives as a 20-photo Haven post rather than 20 posts.
     */
    private fun stageItem(item: InstagramArchive.Item, zip: ZipFile,
                          byName: Map<String, ZipEntry>, circleId: String): StagedItem {
        val refs = ArrayList<String>()
        var anyAudio = false
        for (name in item.mediaNames) {
            // A 20-photo carousel is 20 encodes; a cancel should not have to wait out the album.
            if (cancelled) break
            val entry = byName[name] ?: continue
            if (isVideoName(name)) {
                // STREAMED to scratch, never read into a ByteArray: prepareVideo needs a Uri, and a
                // 300 MB clip held on the managed heap is the OOM this codebase has already paid for
                // once (see LocalMedia's memory guard).
                val scratch = File(appContext.cacheDir, "igimport_${UUID.randomUUID()}.${extensionOf(name)}")
                val spilled = runCatching {
                    zip.getInputStream(entry).use { input ->
                        scratch.outputStream().use { out -> input.copyTo(out, COPY_BUFFER) }
                    }
                    true
                }.getOrDefault(false)
                if (!spilled) { runCatching { scratch.delete() }; continue }
                try {
                    // Asked of the real file, before transcoding — "is it a video" and "does it make
                    // sound" are different questions. A screen recording, a time-lapse or a clip
                    // muted before posting is a silent video, and deserves a song as much as a photo.
                    if (hasAudioTrack(scratch)) anyAudio = true
                    // forceOptimize: an import is bulk media at someone else's encoder settings —
                    // running it through Haven's ladder is what stops a 1.2 GB archive landing on the
                    // relay as-is. alsoOriginal = false: shipping the originals too would double an
                    // already large import, for bytes that are themselves a compressed re-encode.
                    // prepareVideo also cuts the poster still, and returns poster-first mediaRefs, so
                    // a video tile has its still from the moment it arrives.
                    val prepared = runCatching {
                        LocalMedia.prepareVideo(appContext, Uri.fromFile(scratch), circleId,
                                                forceOptimize = true, alsoOriginal = false)
                    }.getOrNull()
                    if (prepared != null && !prepared.isEmpty) refs.addAll(prepared.mediaRefs)
                } finally {
                    runCatching { scratch.delete() }
                }
            } else {
                val bytes = runCatching { zip.getInputStream(entry).use { it.readBytes() } }.getOrNull()
                    ?: continue
                // The optimize ladder explicitly, not the circle's preference: forceOptimize is the
                // whole reason an import doesn't arrive at Instagram's byte sizes.
                val encoded = downscaleJpeg(bytes, MediaTargets.STILL_LONG_EDGE,
                                            MediaTargets.STILL_JPEG_QUALITY) ?: continue
                val ref = runCatching { LocalMedia.store(circleId, encoded, isVideo = false) }.getOrNull()
                if (ref != null) refs.add(ref)
            }
        }
        return StagedItem(refs, anyAudio)
    }

    /** Does this clip carry an audio track? Device-only (MediaMetadataRetriever); false if asked
     *  anywhere it isn't available, which is the safe answer — it only means a song is offered. */
    private fun hasAudioTrack(file: File): Boolean = runCatching {
        val mmr = android.media.MediaMetadataRetriever()
        try {
            mmr.setDataSource(file.absolutePath)
            mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
                .equals("yes", ignoreCase = true)
        } finally {
            runCatching { mmr.release() }
        }
    }.getOrDefault(false)

    // ---- Pure name helpers (shared with the tests) ----------------------------------------------

    fun extensionOf(name: String): String =
        name.substringAfterLast('/').substringAfterLast('.', "").lowercase().ifEmpty { "mp4" }

    fun isVideoName(name: String): Boolean = extensionOf(name) in VIDEO_EXTENSIONS

    private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "m4v")

    private const val COPY_BUFFER = 1 shl 20

    // ---- Getting a readable File out of a content:// document -----------------------------------

    /** Not enough room to stage a copy of the archive — the one failure only Android can have. */
    class NoSpace : Exception()

    /** A readable archive, plus whatever must stay open for it to remain readable. */
    private class Source(val file: File, private val pfd: ParcelFileDescriptor?) : Closeable {
        override fun close() { runCatching { pfd?.close() } }
    }

    private fun stagedFile(): File = File(appContext.cacheDir, "haven-ig-archive.zip")

    /** Refuse to stage a copy without this much room left over afterwards. */
    private const val SPACE_MARGIN = 128L * 1024 * 1024

    /**
     * Resolve a picked document to something [ZipFile] can open, cheapest first:
     *
     *  1. A `file://` URI is already a path.
     *  2. `/proc/self/fd/N` of the open descriptor. For a document backed by a real file — which is
     *     what Downloads and external storage hand back, i.e. where an Instagram export actually
     *     lives — this re-opens the SAME bytes with no copy at all. Verified by opening it as a zip
     *     rather than assumed, because a provider is free to hand back a pipe (a cloud document
     *     streamed on demand), where the path exists but is not seekable.
     *  3. A staged copy in the cache. Correct everywhere and the only option for a streaming
     *     provider, but it is a gigabyte of I/O and a gigabyte of disk, so it is the fallback and it
     *     checks for room first. Reused across a relaunch when it already matches the source size,
     *     so resuming does not copy the archive a second time.
     */
    private fun openSource(uri: Uri): Source {
        if (uri.scheme == "file") {
            val f = File(uri.path ?: "")
            if (f.isFile) return Source(f, null)
        }
        val resolver = appContext.contentResolver
        val pfd = runCatching { resolver.openFileDescriptor(uri, "r") }.getOrNull()
        if (pfd == null) {
            // The grant is gone (revoked, or never persisted). A staged copy from an earlier run is
            // still perfectly good bytes.
            val staged = stagedFile()
            if (staged.isFile && opensAsZip(staged)) return Source(staged, null)
            throw IllegalStateException("archive not readable")
        }
        val direct = File("/proc/self/fd/${pfd.fd}")
        if (opensAsZip(direct)) return Source(direct, pfd)

        val size = runCatching { pfd.statSize }.getOrDefault(-1L)
        val staged = stagedFile()
        if (staged.isFile && size > 0 && staged.length() == size && opensAsZip(staged)) {
            pfd.close()
            return Source(staged, null)
        }
        val room = staged.parentFile?.usableSpace ?: 0L
        if (size > 0 && room < size + SPACE_MARGIN) {
            pfd.close()
            throw NoSpace()
        }
        val copied = runCatching {
            ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input ->
                staged.outputStream().use { out -> input.copyTo(out, COPY_BUFFER) }
            }
            true
        }.getOrDefault(false)
        if (copied && opensAsZip(staged)) return Source(staged, null)
        runCatching { staged.delete() }
        throw IllegalStateException("archive not readable")
    }

    private fun opensAsZip(f: File): Boolean = runCatching {
        ZipFile(f).use { it.entries().hasMoreElements() }
    }.getOrDefault(false)
}
