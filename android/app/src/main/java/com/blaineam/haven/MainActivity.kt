package com.blaineam.haven

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import android.net.Uri
import androidx.core.content.IntentCompat
import com.blaineam.haven.core.DemoEnv
import com.blaineam.haven.core.HavenNet
import com.blaineam.haven.core.InviteInbox
import com.blaineam.haven.core.LocalMedia
import com.blaineam.haven.core.ShareInbox
import com.blaineam.haven.core.isVideoUri
import com.blaineam.haven.core.loadAndDownscale
import com.blaineam.haven.core.readVideoBytes
import com.blaineam.haven.ui.HavenAppTheme
import com.blaineam.haven.ui.RootScreen

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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
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
            // A haven:// or https invite link the app was opened with (tap in a browser/DM) —
            // parity with the iOS URL-scheme flow: route to the Connect screen, prefilled.
            Intent.ACTION_VIEW -> InviteInbox.offer(intent.data?.toString())
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
        val refs = uris.mapNotNull { uri ->
            if (isVideoUri(this, uri)) readVideoBytes(this, uri)?.let { LocalMedia.store(cid, it, isVideo = true) }
            else loadAndDownscale(this, uri)?.let { LocalMedia.store(cid, it) }
        }
        ShareInbox.offerMedia(refs)
    }
}
