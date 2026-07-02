package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy

/**
 * Offline mesh over Nearby Connections (BLE + Wi-Fi) — the Android take on the iOS
 * MultipeerConnectivity path. Carries the SAME Haven frames as iroh, so a nearby phone with no
 * internet still exchanges posts/handshakes. Opt-in (Settings) and fully self-contained so it can
 * never destabilize the online transport. Verified delivery needs two nearby devices.
 */
object NearbyTransport {
    private const val TAG = "NearbyMesh"
    private const val SERVICE_ID = "com.blaineam.haven.mesh"
    private val strategy = Strategy.P2P_CLUSTER

    private var client: ConnectionsClient? = null
    private var ctx: Context? = null
    private val endpoints = mutableSetOf<String>()

    /** True if at least one nearby peer is currently connected (a post would reach them immediately). */
    fun hasConnectedPeers(): Boolean = endpoints.isNotEmpty()
    var active = false; private set

    /** Outbound bridge: HavenNet calls this to flood a frame to all nearby peers. */
    fun broadcast(frame: ByteArray) {
        val c = client ?: return
        val payload = Payload.fromBytes(frame)
        endpoints.toList().forEach { runCatching { c.sendPayload(it, payload) } }
    }

    /** True if the runtime perms Nearby needs are already granted (so we can auto-start on launch). */
    fun hasPermissions(context: Context): Boolean {
        val perms = if (android.os.Build.VERSION.SDK_INT >= 33)
            arrayOf(android.Manifest.permission.BLUETOOTH_ADVERTISE, android.Manifest.permission.BLUETOOTH_CONNECT,
                android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.NEARBY_WIFI_DEVICES)
        else arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        return perms.all {
            androidx.core.content.ContextCompat.checkSelfPermission(context, it) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    fun start(context: Context) {
        if (active) return
        val appCtx = context.applicationContext
        ctx = appCtx
        val c = Nearby.getConnectionsClient(appCtx)
        client = c
        active = true
        c.startAdvertising(endpointName, SERVICE_ID, lifecycle, AdvertisingOptions.Builder().setStrategy(strategy).build())
            .addOnFailureListener { Log.w(TAG, "advertise failed: ${it.message}") }
        c.startDiscovery(SERVICE_ID, discovery, DiscoveryOptions.Builder().setStrategy(strategy).build())
            .addOnFailureListener { Log.w(TAG, "discovery failed: ${it.message}") }
        Log.i(TAG, "nearby mesh started")
    }

    fun stop() {
        client?.apply { stopAdvertising(); stopDiscovery(); stopAllEndpoints() }
        endpoints.clear()
        SyncMetrics.setNearbyPeers(0)
        active = false
        client = null
    }

    /** Per-DEVICE endpoint name (account id + this device's id) so two of the user's own seed-copies
     *  don't advertise an identical name on the mesh and fail to disambiguate / connect. */
    private val endpointName: String
        get() = HavenNet.nodeIdHex.take(12) + ":" + SelfSyncCoordinator.deviceHex.take(12)

    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            if (info.serviceId == SERVICE_ID) {
                client?.requestConnection(endpointName, endpointId, lifecycle)
            }
        }
        override fun onEndpointLost(endpointId: String) { endpoints.remove(endpointId) }
    }

    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            client?.acceptConnection(endpointId, payloads)   // trust handled at the Haven crypto layer
        }
        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            if (resolution.status.isSuccess) {
                endpoints.add(endpointId)
                SyncMetrics.setNearbyPeers(endpoints.size)   // observable → the connection chip lights up
                HavenNet.onNearbyConnected()   // say hello over the new link
            }
        }
        override fun onDisconnected(endpointId: String) {
            endpoints.remove(endpointId)
            SyncMetrics.setNearbyPeers(endpoints.size)
        }
    }

    private val payloads = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            // viaNearby = true: a Hello from an unknown node over proximity must not spawn a request.
            payload.asBytes()?.let { HavenNet.onInbound(it, viaNearby = true) }
        }
        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {}
    }
}
