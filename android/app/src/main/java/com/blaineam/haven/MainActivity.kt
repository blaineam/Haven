package com.blaineam.haven

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import android.net.Uri
import androidx.core.content.IntentCompat
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
        when (intent?.action) {
            // A haven:// or https link the app was opened with (tap in a browser/DM). Invites and
            // post links share a domain AND both ride the #fragment, so discriminate on grammar
            // BEFORE routing — otherwise a post link lands in Connect and dies there.
            Intent.ACTION_VIEW -> {
                val link = intent.data?.toString()
                val post = DeepLink.parsePost(link)
                if (post != null) PostLinkInbox.offer(post) else InviteInbox.offer(link)
            }
            Intent.ACTION_SEND -> {
                if (intent.type?.startsWith("text") == true) {
                    ShareInbox.offer(intent.getStringExtra(Intent.EXTRA_TEXT))
                } else {
                    IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                        ?.let { ingestSharedMedia(listOf(it)) }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    ?.let { ingestSharedMedia(it) }
            }
        }
    }

    /** Stage shared content-URIs into LocalMedia (we hold temporary read grants for the intent's
     *  life, so copy the bytes now) and hand the refs to the composer. */
    private fun ingestSharedMedia(uris: List<Uri>) {
        val cid = HavenNet.activeCircle.value
        val refs = uris.flatMap { uri ->
            if (isVideoUri(this, uri)) LocalMedia.prepareVideo(this, uri, cid).mediaRefs
            else loadAndDownscale(this, uri)?.let { listOf(LocalMedia.store(cid, it)) } ?: emptyList()
        }
        ShareInbox.offerMedia(refs)
    }
}
