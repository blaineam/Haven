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
     *     --es haven_qa_dm_to 7cef8803… --es haven_qa_dm 'DmMtx_120000'
     * Avoids fragile camera automation for stories and contact-picker automation for DMs.
     */
    private fun handleQaExtras(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent == null) return
        android.util.Log.i("HavenQA", "handleQaExtras ready=${HavenNet.isReady}")
        intent.getStringExtra("haven_qa_story")?.trim()?.takeIf { it.isNotEmpty() }?.let { body ->
            runCatching { HavenNet.postStory(body, null) }
            android.util.Log.i("HavenQA", "postStory body=${body.take(40)}")
        }
        intent.getStringExtra("haven_qa_post")?.trim()?.takeIf { it.isNotEmpty() }?.let { body ->
            runCatching { HavenNet.post(HavenNet.activeCircle.value, body) }
            android.util.Log.i("HavenQA", "post body=${body.take(40)}")
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
                HavenNet.post(cid, dmBody)
                android.util.Log.i("HavenQA", "dm to=${dmTo.take(8)} circle=${cid.take(24)} body=${dmBody.take(40)}")
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
