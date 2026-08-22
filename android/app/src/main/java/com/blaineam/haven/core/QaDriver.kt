package com.blaineam.haven.core

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.blaineam.haven.BuildConfig
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import uniffi.haven_ffi.LinkConstraint

/**
 * qa-cmd v2 — the Android leg of the cross-platform QA driver contract (docs/QA.md).
 * DEBUG builds only; every entry point below is a no-op in release.
 *
 * Consumes a one-shot `/sdcard/Download/qa-cmd.json` drop file (deleted after one consume) on
 * (a) a 1.5s poll while the app is foregrounded and (b) the `haven://qa` deep link, then answers
 * with `/sdcard/Download/qa-dump-<applicationId>.json` — refreshed after every op and on
 * `{"op":"dump"}`. Ops call the SAME HavenNet paths the UI uses (post / postStory / sendDm /
 * react / comment / ProfileStore.save + syncWithContacts / createCircle / addToCircle /
 * storeFile / markThreadRead), so a green E2E run exercises real author paths, not a test lane.
 * Content ops honor an explicit `circle_id` (known circles only; missing/unknown → the same
 * target the UI would use). Active-cadence honesty: every mutating op bumps activity + polls the
 * mailbox now; `dump` only marks the user active (see [apply]).
 *
 * Fleet plumbing (Scripts/qa-e2e-bootstrap.sh):
 *  - `/sdcard/Download/qa-seed.txt` (`haven-seed:…`) is adopted at startup IF this install has no
 *    identity yet — the same restore path Onboarding uses — so the emulator joins the fleet
 *    account. An onboarded (or seedless) install is NEVER overwritten.
 *  - `/sdcard/Download/qa-device-hex.txt` gets the account + device transport hexes at startup so
 *    the harness can authorize this device on the HavenStub relay (HTTP signs as the device id).
 *
 * Scoped storage: on API 30+ the app owns the files it creates in Download/, but the adb-staged
 * inputs (qa-cmd.json, qa-seed.txt, fixture media) belong to the shell — the DEBUG manifest adds
 * MANAGE_EXTERNAL_STORAGE and the harness grants it via
 * `adb shell appops set com.blaineam.haven MANAGE_EXTERNAL_STORAGE allow`. `/data/local/tmp/<name>`
 * is accepted as a fallback for every staged input (the older matrix scripts' convention).
 */
object QaDriver {
    private const val TAG = "HavenQA"
    private const val POLL_MS = 1_500L

    private val downloads = File("/sdcard/Download")
    private val fallbackDir = File("/data/local/tmp")

    private lateinit var appContext: Context
    private val handler = Handler(Looper.getMainLooper())
    /** Ops run serialized off-main — author paths block on the engine (feed() re-opens envelopes). */
    private val exec = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "haven-qa") }
    @Volatile private var polling = false
    @Volatile private var wroteIdentity = false
    /** Signature of a consumed drop we could NOT delete (the /data/local/tmp fallback is
     *  shell-owned) — guards against re-applying the same command every tick. */
    @Volatile private var undeletableSig: String? = null
    /** Signature of an unparseable drop — deleted only once it's stable across two ticks, so a
     *  file caught mid-`adb push` gets a second read instead of being discarded half-written. */
    @Volatile private var badDropSig: String? = null

    private val cmdFile get() = File(downloads, "qa-cmd.json")
    private val dumpFile get() = File(downloads, "qa-dump-${BuildConfig.APPLICATION_ID}.json")

    // ---- startup ---------------------------------------------------------------------------

    /**
     * QA seed adoption — MUST run before anything boots the engine (MainActivity.onCreate, before
     * setContent). If the harness staged `qa-seed.txt` and this install has no identity yet, adopt
     * it exactly like Onboarding's `adopt` (importSeed + markOnboarded); RootScreen then inits
     * HavenNet from the imported seed, so no restart is needed at this point in the lifecycle.
     * Never overwrites an existing identity: an onboarded or seedless install returns untouched.
     */
    fun adoptSeedIfPresent(context: Context) {
        if (!BuildConfig.DEBUG) return
        // filesDir first (the app can always read it; harness run-as-stages the seed there
        // because /sdcard grants aren't live at first boot and SELinux blocks /data/local/tmp);
        // fall back to the shell-staged locations. Uses the passed context — this runs before
        // start() sets appContext.
        val f = listOf(File(context.filesDir, "qa-seed.txt"), File(downloads, "qa-seed.txt"), File(fallbackDir, "qa-seed.txt"))
            .firstOrNull { runCatching { it.isFile && it.length() > 0 }.getOrDefault(false) } ?: return
        val profile = ProfileStore.get(context)
        if (profile.onboarded) return                               // identity in use — never overwrite
        val text = runCatching { f.readText() }.getOrNull()?.trim().orEmpty()
        if (!text.startsWith("haven-seed:")) return
        // Pre-seed the identity prefs BEFORE HavenCore is ever built (importSeed on a live
        // singleton only rewrites prefs — the running engine keeps the minted account until a
        // restart the QA boot never does, which is why the emulator ran under a stray account).
        if (HavenCore.qaPreseed(context, text.removePrefix("haven-seed:"))) {
            profile.markOnboarded()   // profile name/emoji arrive via device sync, like the UI path
            Log.i(TAG, "qa-seed pre-seeded — joining the fleet account")
        } else {
            Log.w(TAG, "qa-seed present but not adopted (identity already exists or invalid)")
        }
    }

    /** Arm the driver (MainActivity.onCreate, DEBUG only). Identity dump happens once ready. */
    fun start(context: Context) {
        if (!BuildConfig.DEBUG) return
        appContext = context.applicationContext
    }

    /** 1.5s drop-file poll — runs only while the app is foregrounded (MainActivity.onResume). */
    fun onResume() {
        if (!BuildConfig.DEBUG || polling) return
        polling = true
        handler.post(tick)
    }

    fun onPause() {
        polling = false
        handler.removeCallbacks(tick)
    }

    /** `haven://qa` — poke the consumer now. True when the link was ours (caller stops routing). */
    fun handleUrl(link: String?): Boolean {
        if (!BuildConfig.DEBUG) return false
        val uri = runCatching { Uri.parse(link?.trim().orEmpty()) }.getOrNull() ?: return false
        if (!uri.scheme.equals("haven", ignoreCase = true)) return false
        if (!uri.host.equals("qa", ignoreCase = true)) return false
        consume()
        return true
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!polling) return
            consume()
            handler.postDelayed(this, POLL_MS)
        }
    }

    // ---- consume + dispatch ----------------------------------------------------------------

    /** One-shot consume: read → delete → apply → refresh the dump. Left in place until HavenNet is
     *  ready so an early drop is honored on the next tick instead of being lost. */
    private fun consume() {
        if (!::appContext.isInitialized || !HavenNet.isReady) return
        if (!wroteIdentity) { wroteIdentity = true; exec.execute { writeIdentity() } }
        val f = staged("qa-cmd.json") ?: return
        val text = runCatching { f.readText() }.getOrNull() ?: return
        if (text.isBlank()) return
        val sig = "${f.absolutePath}:${f.lastModified()}:${f.length()}"
        val cmd = runCatching { JSONObject(text) }.getOrNull()
        if (cmd == null) {
            // Might be a half-pushed file — give it one more tick; a stable broken drop is discarded.
            if (sig == badDropSig) {
                runCatching { f.delete() }; badDropSig = null
                Log.w(TAG, "qa-cmd drop: invalid JSON — discarded")
            } else badDropSig = sig
            return
        }
        badDropSig = null
        if (!runCatching { f.delete() }.getOrDefault(false)) {
            if (sig == undeletableSig) return   // already applied this exact drop
            undeletableSig = sig
        }
        exec.execute {
            runCatching { apply(cmd) }
                .onFailure { Log.w(TAG, "qa-cmd ${cmd.optString("op")} failed: ${it.message}") }
            runCatching { writeDump() }
                .onFailure { Log.w(TAG, "qa-dump write failed: ${it.message}") }
        }
    }

    /** Every op that MUTATES state (i.e. everything but `dump`) — each stands in for a real user
     *  actively driving the app, so it snaps sync cadence tight and polls the mailbox now. */
    private val MUTATING_OPS = setOf(
        "post", "story", "dm", "react", "comment", "profile",
        "circle_create", "circle_invite", "file", "music_post", "mark_read", "wire_relay",
    )

    private fun apply(cmd: JSONObject) {
        val op = cmd.optString("op").trim().lowercase()
        Log.i(TAG, "qa-cmd op=$op body=${cmd.optString("body").take(40)}")
        // A qa op represents a user ACTIVELY using the app. Mutating ops reset the adaptive idle
        // stretch exactly like the foreground hook (RootScreen → bumpActivity) and — once the
        // author path has run — poll the mailbox NOW so the authored burst uploads immediately.
        // `dump` only marks the user active: forcing a poll there would fake the measured
        // convergence latency (a receiver must converge at its real active-cadence poll).
        val mutating = op in MUTATING_OPS
        if (mutating) HavenNet.bumpActivity() else if (op == "dump") HavenNet.markUserActive()
        try {
            dispatch(op, cmd)
        } finally {
            if (mutating) HavenNet.pollMailboxNow()
        }
    }

    private fun dispatch(op: String, cmd: JSONObject) {
        val body = cmd.optString("body")
        // Content ops author into an explicitly-requested KNOWN circle; a missing/unknown
        // `circle_id` keeps today's behavior (active circle; stories → the default circle).
        val explicit = explicitCircle(cmd)
        val circle = explicit ?: HavenNet.activeCircle.value
        when (op) {
            // QA: force the link constraint so the satellite path can be exercised off a satellite.
            // ULTRA is otherwise unreachable in an emulator — see LowDataMonitor.debugForced.
            // This whole driver is BuildConfig.DEBUG-gated already.
            // QA: approve every pending connection request.
            //
            // Nothing in the driver could do this, so a fleet where account B reached A's OTHER
            // devices as a stranger simply stopped — Android sat on an un-approvable "Matrix Stub
            // Host" request forever and every assertion about B's content failed for a reason that
            // had nothing to do with the product. An automated suite cannot wait for a tap.
            "approve_connections" -> {
                val reqs = HavenNet.pending.toList()
                reqs.forEach { runCatching { HavenNet.approve(it) } }
                Log.i("HavenQA", "approve_connections: approved ${reqs.size}")
            }
            "link_constraint" -> LowDataMonitor.debugForced = when (cmd.optString("level").lowercase()) {
                "ultra" -> LinkConstraint.ULTRA
                "low" -> LinkConstraint.LOW
                "normal" -> LinkConstraint.NORMAL
                else -> null   // "auto" (or anything else) hands control back to the real monitor
            }
            "post" -> HavenNet.post(circle, body, stageMedia(cmd, circle))
            "story" -> {
                val caption = cmd.optString("caption").ifEmpty { body }
                val storyCircle = explicit ?: DEFAULT_CIRCLE
                HavenNet.postStory(caption, stageMedia(cmd, storyCircle).firstOrNull(), circleId = storyCircle)
            }
            "dm" -> {
                val to = cmd.optString("dm_to").trim().lowercase()
                val contact = HavenNet.contacts.firstOrNull { it.idHex.equals(to, ignoreCase = true) }
                if (to.length != 64 || contact == null) {
                    Log.w(TAG, "qa dm: no contact ${to.take(8)} — add via qa-peer/HELLO first"); return
                }
                val cid = HavenNet.startDm(contact)
                HavenNet.sendDm(cid, body, stageMedia(cmd, cid))
            }
            "react" -> {
                val target = cmd.optString("target_id")
                val cid = circleOf(target) ?: run { Log.w(TAG, "qa react: no circle holds ${target.take(12)}"); return }
                HavenNet.react(cid, target, cmd.optString("emoji").ifEmpty { "❤️" })
            }
            "comment" -> {
                val target = cmd.optString("target_id")
                val cid = circleOf(target) ?: run { Log.w(TAG, "qa comment: no circle holds ${target.take(12)}"); return }
                HavenNet.comment(cid, target, body, stageMedia(cmd, cid))
            }
            "profile" -> {
                // The exact EditProfileScreen save path: mutate + save (LWW stamps) + re-share card.
                val profile = ProfileStore.get(appContext)
                profile.displayName = cmd.optString("name").trim()
                profile.save()
                HavenNet.syncWithContacts()
            }
            "circle_create" -> HavenNet.createCircle(cmd.optString("name").ifEmpty { "QA Circle" })
            "circle_invite" -> {
                val to = cmd.optString("dm_to").trim().lowercase()
                if (to.length == 64) HavenNet.addToCircle(circle, to)
                else Log.w(TAG, "qa circle_invite: bad dm_to")
            }
            "file" -> {
                val src = resolve(cmd.optString("file_path"))
                    ?: run { Log.w(TAG, "qa file: missing ${cmd.optString("file_path").take(60)}"); return }
                val ref = LocalMedia.storeFile(circle, src.readBytes())
                HavenNet.post(circle, body, listOf(ref))
            }
            "music_post" -> {
                val m = cmd.optJSONObject("music") ?: JSONObject()
                val track = HavenNet.trackFromLink(
                    m.optString("url").ifEmpty { "qa://track" },
                    m.optString("title"), m.optString("artist"),
                )
                HavenNet.post(circle, body, music = track)
            }
            "mark_read" -> HavenNet.markThreadRead(circle)
            "wire_relay" -> {
                val hex = cmd.optString("hex").lowercase()
                val urlsArr = cmd.optJSONArray("urls")
                val urls = if (urlsArr != null) (0 until urlsArr.length()).map { urlsArr.getString(it) } else emptyList()
                val token = cmd.optString("token")
                val derp = cmd.optString("derp")   // optional QA-DERP url (emulator → stub fabric route)
                if (hex.length == 64 && urls.isNotEmpty()) HavenNet.qaWireRelay(hex, urls, token, derp)
                else Log.w(TAG, "wire_relay: bad args hex=${hex.take(8)} urls=${urls.size}")
            }
            "dump" -> {}   // every branch refreshes the dump on the way out
            else -> Log.w(TAG, "qa-cmd unknown op=$op")
        }
    }

    /** An explicit `circle_id` from the drop, honored only when this device actually HOLDS that
     *  circle — unknown (or deleted) ids return null so the caller keeps today's default target
     *  instead of authoring into a void. */
    private fun explicitCircle(cmd: JSONObject): String? {
        val want = cmd.optString("circle_id").trim()
        if (want.isEmpty()) return null
        val known = runCatching { HavenNet.engine.circles() }.getOrDefault(emptyList())
            .any { it.id == want && !CircleDeletion.isDeleted(it.id) }
        if (!known) Log.w(TAG, "qa-cmd: unknown circle_id ${want.take(12)} — keeping the default target")
        return if (known) want else null
    }

    /** Which circle holds [postId] — reactions/comments arrive with only a target id. */
    private fun circleOf(postId: String): String? {
        if (postId.isEmpty()) return null
        val social = HavenNet.engine
        for (c in runCatching { social.circles() }.getOrDefault(emptyList())) {
            val feed = runCatching { social.feed(c.id, nowMs(), null) }.getOrDefault(emptyList())
            if (feed.any { it.id == postId }) return c.id
        }
        return null
    }

    // ---- media staging ---------------------------------------------------------------------

    /** `photo_path` / `video_path` point at adb-staged files (`media` kind falls back to a
     *  synthetic fixture) — mirrors MainActivity's v1 `qaBuildMediaRefs`, but drop-file driven. */
    private fun stageMedia(cmd: JSONObject, circleId: String): List<String> {
        val kind = cmd.optString("media").trim().lowercase()
        val out = ArrayList<String>()
        val photo = resolve(cmd.optString("photo_path"))
        if (photo != null) {
            out += LocalMedia.store(circleId, photo.readBytes(), isVideo = false)
        } else if (kind == "photo") {
            val bmp = android.graphics.Bitmap.createBitmap(640, 480, android.graphics.Bitmap.Config.ARGB_8888)
            bmp.eraseColor(android.graphics.Color.rgb(30, 144, 255))
            val baos = java.io.ByteArrayOutputStream()
            bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, baos)
            bmp.recycle()
            out += LocalMedia.store(circleId, baos.toByteArray(), isVideo = false)
        }
        val video = resolve(cmd.optString("video_path"))
        if (video != null) {
            val prepared = LocalMedia.prepareVideo(appContext, Uri.fromFile(video), circleId)
            if (!prepared.isEmpty) out += prepared.mediaRefs
            else out += LocalMedia.store(circleId, video.readBytes(), isVideo = true)
        } else if (kind == "video") {
            Log.w(TAG, "qa media: video requested but no video_path — skip")
        }
        if (out.isNotEmpty()) Log.i(TAG, "qa media refs=${out.joinToString { it.take(16) }}")
        return out
    }

    /** An adb-staged input by name: Download/ first, /data/local/tmp/ as the fallback. */
    private fun staged(name: String): File? {
        // The app can ALWAYS read its own filesDir; /sdcard needs a MANAGE_EXTERNAL_STORAGE
        // grant that may not be live at first boot, and SELinux blocks app reads of
        // /data/local/tmp on modern emulators — so a run-as-staged copy under filesDir is
        // the only path that reliably works for the boot-time seed. Prefer it.
        val filesCopy = if (::appContext.isInitialized) File(appContext.filesDir, name) else null
        return listOf(filesCopy, File(downloads, name), File(fallbackDir, name))
            .filterNotNull()
            .firstOrNull { runCatching { it.isFile && it.length() > 0 }.getOrDefault(false) }
    }

    /** A driver-supplied absolute path, or the same basename under the fallback dir. */
    private fun resolve(path: String): File? {
        val trimmed = path.trim()
        if (trimmed.isEmpty()) return null
        val f = File(trimmed)
        if (runCatching { f.isFile && f.canRead() }.getOrDefault(false)) return f
        return staged(f.name)
    }

    // ---- dump ------------------------------------------------------------------------------

    /** Account + device transport hexes, one per line — pulled + authorized by the bootstrap. */
    private fun writeIdentity() {
        runCatching {
            val account = HavenNet.accountNodeHex
            val device = runCatching { HavenNet.engine.myDeviceNodeHex() }.getOrDefault("")
            val lines = listOf(account, device).filter { it.length == 64 }.joinToString("\n")
            File(downloads, "qa-device-hex.txt").writeText(lines + "\n")
            Log.i(TAG, "qa-device-hex written account=${account.take(12)} device=${device.take(12)}")
        }.onFailure { Log.w(TAG, "qa-device-hex write failed: ${it.message}") }
        runCatching { writeDump() }   // a startup dump so the orchestrator's sanity check has one
    }

    /** The v2 dump: posts (with media presence), DMs by peer, profile, circles — same reads the
     *  UI does (engine.feed with the circle's retention; HavenNet.messages for DM watermarks). */
    private fun writeDump() {
        if (!HavenNet.isReady) return
        val social = HavenNet.engine
        val o = JSONObject()
            .put("device", "android")
            .put("account_hex", runCatching { HavenNet.accountNodeHex }.getOrDefault(""))
            .put("ts_ms", System.currentTimeMillis())

        val myAcct = runCatching { HavenNet.accountNodeHex }.getOrDefault("").lowercase()
        val all = runCatching { social.circles() }.getOrDefault(emptyList())
            .filter { !CircleDeletion.isDeleted(it.id) }

        val posts = JSONArray()
        val circles = JSONArray()
        for (c in all.filter { !it.id.startsWith("dm:") }) {
            val feed = runCatching {
                social.feed(c.id, nowMs(), CircleSettings.retentionSecs(c.id))
            }.getOrDefault(emptyList())
            for (item in feed) {
                if (item.unsent) continue
                posts.put(postRow(item, c.id))
            }
            circles.put(JSONObject()
                .put("id", c.id)
                .put("name", c.name)
                .put("members", JSONArray(HavenNet.membersOf(c.id).map { it.idHex })))
        }
        o.put("posts", posts)

        val dms = JSONObject()
        for (c in all.filter { it.id.startsWith("dm:") }) {
            val others = HavenNet.dmMemberHexes(c.id).filter { it.lowercase() != myAcct }
            val key = others.joinToString(",").ifEmpty { c.id }
            val rows = JSONArray()
            for (m in HavenNet.messages(c.id)) {
                if (m.unsent) continue
                rows.put(JSONObject()
                    .put("id", m.id)
                    .put("body", m.body)
                    .put("media_present", JSONArray(realRefs(m.media).map { LocalMedia.has(it) })))
            }
            dms.put(key, rows)
        }
        o.put("dms", dms)

        o.put("profile", JSONObject().put("name", ProfileStore.get(appContext).displayName))
        // Call state. Absent until now, which is why a stuck call could never be caught here: the
        // e2e call step only asserts on ios and stub, so this leg could sit in a DEAD call while the
        // suite reported green. Exactly that happened — an established call ended on iOS left
        // Android in a call with no way out, and only someone looking at the screen could tell.
        o.put("call", JSONObject()
            .put("ringing", runCatching { CallManager.ringing.value }.getOrDefault(false))
            .put("in_call", runCatching { CallManager.inCall.value }.getOrDefault(false))
            // WHICH session, and what this leg last applied. `in_call` alone cannot distinguish a
            // leg that ignored the teardown from one that is in a DIFFERENT session than the one
            // that ended — and every handler here is gated on the session id matching.
            .put("session", runCatching { CallManager.qaSessionId }.getOrDefault(""))
            .put("last_event", runCatching { CallManager.qaLastCallEvent }.getOrDefault("?")))
        o.put("circles", circles)
        // What the engine is HOLDING BACK. A short feed alone cannot distinguish "never arrived"
        // from "arrived and could not be opened", and those have opposite fixes — this leg once
        // read as a delivery failure while sitting on 8 parked envelopes.
        o.put("delivery", runCatching { JSONObject(social.diagDeliveryJson()) }.getOrNull())

        // App-owned file in Download/ (allowed on scoped storage); tmp+rename keeps reads whole.
        val tmp = File(downloads, dumpFile.name + ".tmp")
        tmp.writeText(o.toString())
        if (!tmp.renameTo(dumpFile)) { dumpFile.writeText(o.toString()); tmp.delete() }
    }

    private fun postRow(item: uniffi.haven_ffi.FeedItemFfi, circleId: String): JSONObject {
        val real = realRefs(item.media)
        val reactions = JSONObject()
        for (r in item.reactions) reactions.put(r.emoji, r.count.toInt())
        val comments = JSONArray()
        for (cm in item.comments) {
            if (cm.unsent) continue
            comments.put(JSONObject().put("id", cm.id).put("body", cm.body))
        }
        return JSONObject()
            .put("id", item.id)
            .put("body", item.body)
            .put("circle", circleId)
            .put("story", item.story)
            .put("caption", if (item.story) item.body else JSONObject.NULL)
            .put("media_refs", JSONArray(real))
            .put("media_present", JSONArray(real.map { LocalMedia.has(it) }))
            // Companion MARKERS (`preview:`/`thumb:`/`poster:`/`orig:`) and whether the blobs they
            // name are here. Apple and desktop already report these; Android never did, and that
            // alone made every satellite assertion against this leg UNPASSABLE — the orchestrator
            // resolves a post's content ref THROUGH its `preview:` marker, so with no markers the
            // predicate is false no matter what the device actually holds.
            //
            // It read as a delivery failure for several runs while the dump showed, in the same
            // breath, `media_present=[true]` and `parked=0`: the photo was here the whole time.
            .put("media_markers", JSONArray(item.media.filter { LocalMedia.isSynthetic(it) }))
            .put("companions_present", JSONObject().apply {
                for (m in item.media) {
                    val companion = MediaVariants.parsePreview(m)?.second
                        ?: MediaVariants.parseThumb(m)?.second
                        ?: MediaVariants.parsePoster(m)?.second
                        ?: MediaVariants.parseOriginal(m)?.second
                    if (companion != null) put(companion, LocalMedia.has(companion))
                }
            })
            .put("reactions", reactions)
            .put("comments", comments)
    }

    /** Fetchable blobs only — `thumb:`/`poster:`-style markers aren't bytes and must not be able
     *  to fail the orchestrator's media-blob gate. */
    private fun realRefs(media: List<String>): List<String> = media.filter { !LocalMedia.isSynthetic(it) }
}
