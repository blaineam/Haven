package com.blaineam.haven

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import android.net.Uri
import androidx.core.content.IntentCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.blaineam.haven.core.DeepLink
import com.blaineam.haven.core.DemoEnv
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.InviteInbox
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.PostLinkInbox
import com.blaineam.haven.core.ShareInbox
import com.blaineam.haven.core.isVideoUri
import com.blaineam.haven.core.loadAndDownscale
import com.blaineam.haven.ui.HavenAppTheme
import com.blaineam.haven.ui.RootScreen
import com.blaineam.haven.BuildConfig

class MainActivity : FragmentActivity() {
    // Nearby (Bluetooth/Wi-Fi mesh) is default-ON, but the Settings toggle only requests its runtime
    // permissions when the user flips it — which they never do since it's already on, so the perms
    // were never granted and nearby never started (it silently showed "just Relay"). Request them
    // once on launch when nearby is wanted but ungranted, then start the mesh.
    private val nearbyPermLauncher = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants.values.all { it }) HavenNet.restoreNearbyIfWanted()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        DemoEnv.configure(intent)   // DEBUG-only: arms demo mode from launch-intent extras
        if (BuildConfig.DEBUG) {
            // qa-cmd v2 driver (docs/QA.md): adopt the fleet seed BEFORE anything boots the engine
            // (RootScreen inits HavenNet from whatever identity exists once we setContent below).
            com.blaineam.haven.core.QaDriver.adoptSeedIfPresent(this)
            com.blaineam.haven.core.QaDriver.start(this)
        }
        handleShare(intent)
        maybeRequestNearby()
        setContent {
            HavenAppTheme {
                RootScreen()
            }
        }
        // DEBUG matrix QA: retry until HavenNet is ready (init is async from Application).
        if (BuildConfig.DEBUG) scheduleQaExtras(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShare(intent)
        if (BuildConfig.DEBUG) scheduleQaExtras(intent)
    }

    override fun onResume() {
        super.onResume()
        // (Foreground state itself is owned by RootScreen's lifecycle observer — `HavenNet.isForeground`.)
        // qa-cmd v2: the 1.5s drop-file poll runs only while the app is foregrounded (DEBUG only —
        // QaDriver no-ops in release).
        com.blaineam.haven.core.QaDriver.onResume()
    }

    override fun onPause() {
        super.onPause()
        com.blaineam.haven.core.QaDriver.onPause()
    }

    /** Poll until [HavenNet.isReady], then run [handleQaExtras] (DEBUG matrix only). */
    private fun scheduleQaExtras(intent: Intent?, attempt: Int = 0) {
        if (!BuildConfig.DEBUG || intent == null) return
        if (HavenNet.isReady) {
            handleQaExtras(intent)
            return
        }
        if (attempt > 50) {
            android.util.Log.w("HavenQA", "gave up waiting for HavenNet.isReady")
            return
        }
        window.decorView.postDelayed({ scheduleQaExtras(intent, attempt + 1) }, 200)
    }

    /**
     * Matrix / multi-device QA hooks (DEBUG only). Launch with e.g.:
     *   adb shell am start -n com.blaineam.haven/.MainActivity \
     *     --es haven_qa_story 'StoryMtx_120000' \
     *     --es haven_qa_dm_to 7cef8803… --es haven_qa_dm 'DmMtx_120000' \
     *     --es haven_qa_media photo|video \
     *     --es haven_qa_photo_path /sdcard/…/qa-photo.jpg \
     *     --es haven_qa_video_path /sdcard/…/qa-clip.mp4
     * Media attach avoids camera/picker automation; paths optional when media=photo (synthetic).
     */
    private fun handleQaExtras(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent == null) return
        android.util.Log.i("HavenQA", "handleQaExtras ready=${HavenNet.isReady}")
        val mediaKind = intent.getStringExtra("haven_qa_media")?.trim()?.lowercase().orEmpty()
        val photoPath = intent.getStringExtra("haven_qa_photo_path")?.trim().orEmpty()
        val videoPath = intent.getStringExtra("haven_qa_video_path")?.trim().orEmpty()
        val mediaRefs = runCatching { qaBuildMediaRefs(mediaKind, photoPath, videoPath) }
            .onFailure { android.util.Log.w("HavenQA", "media build failed: ${it.message}") }
            .getOrDefault(emptyList())
        if (mediaRefs.isNotEmpty()) {
            android.util.Log.i("HavenQA", "media refs=${mediaRefs.joinToString { it.take(16) }}")
        }

        intent.getStringExtra("haven_qa_story")?.trim()?.takeIf { it.isNotEmpty() }?.let { body ->
            runCatching {
                if (mediaRefs.isEmpty()) HavenNet.postStory(body, null)
                else HavenNet.postStory(body, mediaRefs.first())
            }
            android.util.Log.i("HavenQA", "postStory body=${body.take(40)} media=${mediaRefs.size}")
        }
        intent.getStringExtra("haven_qa_post")?.trim()?.takeIf { it.isNotEmpty() }?.let { body ->
            runCatching {
                HavenNet.post(HavenNet.activeCircle.value, body, media = mediaRefs)
            }
            android.util.Log.i("HavenQA", "post body=${body.take(40)} media=${mediaRefs.size}")
        }
        val dmTo = intent.getStringExtra("haven_qa_dm_to")?.trim()?.lowercase().orEmpty()
        val dmBody = intent.getStringExtra("haven_qa_dm")?.trim().orEmpty()
        if (dmTo.length == 64 && dmBody.isNotEmpty()) {
            runCatching {
                val contact = HavenNet.contacts.firstOrNull { it.idHex.equals(dmTo, ignoreCase = true) }
                    ?: run {
                        android.util.Log.w("HavenQA", "dm: no contact ${dmTo.take(8)} — add via qa-peer/HELLO first")
                        return@runCatching
                    }
                val cid = HavenNet.startDm(contact)
                HavenNet.post(cid, dmBody, media = mediaRefs)
                android.util.Log.i("HavenQA", "dm to=${dmTo.take(8)} circle=${cid.take(24)} body=${dmBody.take(40)} media=${mediaRefs.size}")
            }.onFailure { android.util.Log.w("HavenQA", "dm failed: ${it.message}") }
        }
        intent.getStringExtra("haven_qa_call_to")?.trim()?.lowercase()?.takeIf { it.length == 64 }?.let { peer ->
            runCatching {
                val contact = HavenNet.contacts.firstOrNull { it.idHex.equals(peer, ignoreCase = true) }
                    ?: run {
                        android.util.Log.w("HavenQA", "call: no contact ${peer.take(8)}")
                        return@runCatching
                    }
                val name = contact.name.ifBlank { "Friend" }
                com.blaineam.haven.core.CallManager.startCall(listOf(peer), name)
                android.util.Log.i("HavenQA", "call_to=${peer.take(8)} name=$name")
            }.onFailure { android.util.Log.w("HavenQA", "call failed: ${it.message}") }
        }
    }

    /** Build content-addressed media refs for matrix QA (DEBUG). */
    private fun qaBuildMediaRefs(kind: String, photoPath: String, videoPath: String): List<String> {
        val cid = HavenNet.activeCircle.value.ifBlank { "default" }
        val out = ArrayList<String>()
        val photoFile = photoPath.takeIf { it.isNotEmpty() }?.let { java.io.File(it) }
        if (photoFile != null && photoFile.isFile) {
            val bytes = photoFile.readBytes()
            out += com.blaineam.haven.core.LocalMedia.store(cid, bytes, isVideo = false)
            android.util.Log.i("HavenQA", "photo_path → ${out.last().take(16)}")
        } else if (kind == "photo") {
            val bmp = android.graphics.Bitmap.createBitmap(640, 480, android.graphics.Bitmap.Config.ARGB_8888)
            bmp.eraseColor(android.graphics.Color.rgb(30, 144, 255))
            val baos = java.io.ByteArrayOutputStream()
            bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, baos)
            bmp.recycle()
            out += com.blaineam.haven.core.LocalMedia.store(cid, baos.toByteArray(), isVideo = false)
            android.util.Log.i("HavenQA", "synthetic photo → ${out.last().take(16)}")
        }
        val videoFile = videoPath.takeIf { it.isNotEmpty() }?.let { java.io.File(it) }
        if (videoFile != null && videoFile.isFile) {
            val prepared = com.blaineam.haven.core.LocalMedia.prepareVideo(
                this, android.net.Uri.fromFile(videoFile), cid,
            )
            if (prepared.videoRef.isNotEmpty()) {
                out += prepared.mediaRefs
                android.util.Log.i("HavenQA", "video_path → ${prepared.videoRef.take(16)} n=${prepared.mediaRefs.size}")
            } else {
                val bytes = videoFile.readBytes()
                out += com.blaineam.haven.core.LocalMedia.store(cid, bytes, isVideo = true)
                android.util.Log.i("HavenQA", "video_path raw store → ${out.last().take(16)}")
            }
        } else if (kind == "video") {
            val staged = java.io.File(filesDir, "qa-clip.mp4")
            if (staged.isFile) {
                val prepared = com.blaineam.haven.core.LocalMedia.prepareVideo(
                    this, android.net.Uri.fromFile(staged), cid,
                )
                if (prepared.videoRef.isNotEmpty()) {
                    out += prepared.mediaRefs
                    android.util.Log.i("HavenQA", "staged video → ${prepared.videoRef.take(16)}")
                }
            } else {
                android.util.Log.w("HavenQA", "video requested but no path/fixture — skip")
            }
        }
        return out
    }

    /** Ask for the nearby-mesh perms once (per install) when nearby is wanted but not yet granted,
     *  so the default-on mesh actually starts. If denied, the Settings toggle stays the manual path.
     *  Reads the pref DIRECTLY (not via HavenNet) — this runs in onCreate, before HavenNet.init(). */
    private fun maybeRequestNearby() {
        val prefs = getSharedPreferences("haven.nearby", MODE_PRIVATE)
        if (!prefs.getBoolean("on", true)) return   // nearby is default-on
        val perms = if (android.os.Build.VERSION.SDK_INT >= 33)
            arrayOf(android.Manifest.permission.BLUETOOTH_ADVERTISE, android.Manifest.permission.BLUETOOTH_CONNECT,
                android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.NEARBY_WIFI_DEVICES)
        else arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        val missing = perms.any {
            androidx.core.content.ContextCompat.checkSelfPermission(this, it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (!missing) return
        if (prefs.getBoolean("asked", false)) return   // ask once; don't nag on every launch
        prefs.edit().putBoolean("asked", true).apply()
        runCatching { nearbyPermLauncher.launch(perms) }
    }

    /** Text / links / photos / videos shared into Haven → prefill the composer + attach media. */
    private fun handleShare(intent: Intent?) {
        // Answered from the incoming-call notification. Handled HERE, in the activity, because the
        // OS blocks a background receiver from starting one — so the notification action launches
        // us with this extra and we accept once we are actually on screen. That ordering is what
        // makes the call and its UI arrive together instead of a call connecting invisibly.
        if (intent?.getBooleanExtra(com.blaineam.haven.core.Notifications.EXTRA_ANSWER_CALL, false) == true) {
            intent.removeExtra(com.blaineam.haven.core.Notifications.EXTRA_ANSWER_CALL)
            runCatching { com.blaineam.haven.core.Notifications.clearIncomingCall(this) }
            runCatching { com.blaineam.haven.core.CallManager.accept() }
        }
        when (intent?.action) {
            // A haven:// or https link the app was opened with (tap in a browser/DM, or one of our
            // own notifications). Invites and post links share a domain AND both ride the
            // #fragment, so discriminate on grammar BEFORE routing — otherwise a post link lands
            // in Connect and dies there. `m/` (DM thread) and `c/` (circle) are notification
            // tap-targets (DeepLink.interactionLink) — one route table for every link source.
            Intent.ACTION_VIEW -> {
                val link = intent.data?.toString()
                // qa-cmd v2 (DEBUG only): `haven://qa` pokes the drop-file consumer and is never
                // routed further — parity with iOS FeedStore.handleMatrixQaURL.
                if (com.blaineam.haven.core.QaDriver.handleUrl(link)) return
                val dm = DeepLink.parseDm(link)
                val circle = DeepLink.parseCircle(link)
                val post = DeepLink.parsePost(link)
                when {
                    // Open the Messages THREAD: RootScreen switches to the Messages tab on this
                    // signal and MessagesScreen consumes it to open the conversation.
                    dm != null -> com.blaineam.haven.core.DmDrafts.openThread.value = dm.circleId
                    // Switch to the circle's feed — RootScreen honors CircleLock.needsUnlock the
                    // same way the post path does (the lock screen takes over, never a peek).
                    circle != null -> com.blaineam.haven.core.CircleLinkInbox.offer(circle)
                    post != null -> PostLinkInbox.offer(post)
                    else -> InviteInbox.offer(link)
                }
            }
            Intent.ACTION_SEND -> {
                // A share can carry BOTH a stream and text (a photo with a caption, a document with
                // a link) — take whichever parts are there instead of treating them as exclusive.
                val stream = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                ingestShare(intent, listOfNotNull(stream))
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                ingestShare(intent, streams ?: emptyList())
            }
        }
    }

    /**
     * Stage a share: copy every shared content-URI into [LocalMedia] and hand the whole thing to
     * [ShareInbox], which raises the routing sheet.
     *
     * Off the main thread on purpose. We hold read grants only for the life of the intent, so the
     * bytes must be copied now — but "now" can mean a full MediaCodec transcode of a video or a
     * multi-hundred-megabyte file read, and doing that on the looper is an ANR. The text and the
     * chosen conversation are offered immediately so the sheet opens right away; the media refs
     * follow and merge into the same pending share.
     */
    private fun ingestShare(intent: Intent, uris: List<Uri>) {
        // A Direct Share tap names the conversation the user picked — the shortcut id IS the dm:
        // circle id we published (see ShareShortcuts).
        val target = intent.getStringExtra(ShortcutManagerCompat.EXTRA_SHORTCUT_ID)
            ?.takeIf { it.startsWith("dm:") }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        ShareInbox.offer(ShareInbox.Payload(text = text, targetCircleId = target))
        if (uris.isEmpty()) return
        lifecycleScope.launch(Dispatchers.IO) {
            val cid = HavenNet.activeCircle.value
            val refs = uris.flatMap { uri -> stage(uri, cid) }
            if (refs.isNotEmpty()) withContext(Dispatchers.Main) {
                ShareInbox.offer(ShareInbox.Payload(media = refs, targetCircleId = target))
            }
        }
    }

    /** One shared URI → media refs. Photos downscale, videos transcode, and anything else becomes a
     *  `file_` attachment so a PDF or a spreadsheet arrives intact. */
    private fun stage(uri: Uri, circleId: String): List<String> = runCatching {
        if (isVideoUri(this, uri)) return@runCatching LocalMedia.prepareVideo(this, uri, circleId).mediaRefs
        val mime = contentResolver.getType(uri).orEmpty()
        if (mime.startsWith("image/")) {
            loadAndDownscale(this, uri)?.let { return@runCatching listOf(LocalMedia.store(circleId, it)) }
        }
        // Not something we can render — send it as a document.
        //
        // Checked BEFORE reading, not after: `storeFile` seals from a ByteArray, so the file has to
        // fit in the heap twice over, and a phone that reads a 400 MB attachment just to discover it
        // is too big has already died doing it. `maxInMemoryBytes` is the same quarter-heap budget
        // the decrypt path uses; the absolute ceiling matches Apple's `FileArchive.maxSourceBytes`
        // so neither platform can post an attachment the other refuses to open.
        val cap = minOf(MAX_SHARED_FILE_BYTES, LocalMedia.maxInMemoryBytes())
        val size = sizeOf(uri)
        if (size > cap) return@runCatching emptyList()
        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: return@runCatching emptyList()
        if (bytes.size > cap) return@runCatching emptyList()   // unknown size up front (size < 0)
        // An archive is already in the right shape — don't nest it in a second one (Apple's
        // `MediaStore.addFile` makes the same exception).
        val isZip = mime == "application/zip" || displayName(uri).endsWith(".zip", ignoreCase = true)
        listOf(LocalMedia.storeFile(circleId, if (isZip) bytes else zipped(displayName(uri), bytes)))
    }.getOrDefault(emptyList())

    /**
     * Wrap a shared document in a ZIP, the way Apple's `MediaStore.addFile` does.
     *
     * A `file_` ref carries no filename or type on the wire, so every client writes it out with a
     * `.zip` extension — an Apple recipient of a bare PDF would save `something.zip` that isn't a
     * zip and wouldn't open anywhere. Wrapping keeps the original name and extension INSIDE the
     * archive, which is the only place they survive the trip.
     */
    private fun zipped(name: String, bytes: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream(bytes.size + 512)
        java.util.zip.ZipOutputStream(out).use { zip ->
            zip.putNextEntry(java.util.zip.ZipEntry(name))
            zip.write(bytes)
            zip.closeEntry()
        }
        return out.toByteArray()
    }

    /** The filename the source app gave a shared document, or a neutral fallback. */
    private fun displayName(uri: Uri): String {
        val queried = runCatching {
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        }.getOrNull()
        return (queried ?: uri.lastPathSegment.orEmpty())
            .substringAfterLast('/')
            .trim()
            .ifBlank { "attachment" }
    }

    /** Declared byte size of a content URI, or -1 when the provider won't say. */
    private fun sizeOf(uri: Uri): Long = runCatching {
        contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
    }.getOrDefault(-1L)

    private companion object {
        /** 512 MB — the same ceiling Apple's `FileArchive.maxSourceBytes` enforces. */
        const val MAX_SHARED_FILE_BYTES = 512L * 1024 * 1024
    }
}
