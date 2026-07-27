package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * WebSocket call-media hairpin through the Haven path proxy (`/webrtc/hairpin`).
 *
 * Free Cloudflare tunnels front **HTTPS + WebSocket**, not UDP TURN. When the circle fabric has a
 * public HTTPS origin (the path-proxied DERP URL is also the media host), each peer opens a WSS per
 * remote and the proxy bipipes binary frames after a small JSON join.
 *
 * Stock WebRTC media still tries ICE first; this is the TCP/TLS fallback for hard NAT when TURN/UDP
 * is unavailable. Until now Android had no such fallback at all — the comments in [FabricIcePolicy]
 * and [CallManager] described one that had never been written — so an Android leg whose ICE could
 * not pair simply never connected, while an Apple↔Apple call in the same conditions survived. That
 * is the "calls to/from Android ring but accepting never fully connects" report.
 *
 * Wire-compatible with Apple `CallHairpin` by construction: same URL derivation, same join object,
 * same pairing predicate. [CallMediaBridge] owns the binary frame format.
 */
object CallHairpin {
    private const val TAG = "HavenHairpin"

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            // The relay is a bipipe with no application-level keepalive; a silent call leg (nobody
            // talking, camera off) must not look dead to an intermediary.
            .pingInterval(20, TimeUnit.SECONDS)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)   // a media socket is long-lived by definition
            .build()
    }

    private val sockets = HashMap<String, WebSocket>()
    private val paired = HashSet<String>()

    /** Delivered every inbound binary frame from a paired remote (the relay bipipes them opaque). */
    @Volatile var onBinary: ((remote: String, data: ByteArray) -> Unit)? = null

    /** Fired the instant a remote pairs, so the media bridge can start pushing frames. */
    @Volatile var onPaired: ((remote: String) -> Unit)? = null

    /**
     * Public fabric/media HTTPS base → `wss://…/webrtc/hairpin`. Pure string math so it is testable
     * without a live socket. Mirrors Apple `CallHairpin.hairpinURL(fromPublicBase:)`.
     */
    fun hairpinUrl(publicBase: String): String? {
        val t = publicBase.trim().trim('/')
        if (t.isEmpty()) return null
        val lower = t.lowercase()
        val scheme = when {
            lower.startsWith("https://") -> "wss"
            lower.startsWith("http://") -> "ws"
            else -> return null
        }
        val afterScheme = t.substringAfter("://")
        // Host[:port] only — drop any path the DERP URL carried; the hairpin has its own.
        val hostPort = afterScheme.substringBefore('/')
        if (hostPort.isEmpty()) return null
        return "$scheme://$hostPort/webrtc/hairpin"
    }

    /** Best fabric public base (the DERP URL doubles as the media origin when path-proxied). */
    fun fabricBase(context: Context): String? {
        val prefs = context.getSharedPreferences("haven.fabric", Context.MODE_PRIVATE)
        val derp = prefs.getStringSet("derpUrls", emptySet()).orEmpty()
        return derp.firstOrNull { it.startsWith("https://") || it.startsWith("http://") }
    }

    /** Open (or keep) a hairpin to [remote] for this call session. Idempotent per remote. */
    @Synchronized
    fun open(context: Context, sessionId: String, me: String, remote: String) {
        if (sessionId.isEmpty() || me.isEmpty() || remote.isEmpty() || me == remote) return
        if (sockets.containsKey(remote)) return
        val base = fabricBase(context) ?: run {
            Log.i(TAG, "no fabric public base — cannot hairpin to ${remote.take(8)}")
            return
        }
        val url = hairpinUrl(base) ?: return

        val req = Request.Builder().url(url).build()
        val ws = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                val join = JSONObject()
                    .put("v", 1)
                    .put("session", sessionId)
                    .put("peer", me)
                    .put("remote", remote)
                webSocket.send(join.toString())
                Log.i(TAG, "hairpin opening $url → ${remote.take(8)}…")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val obj = runCatching { JSONObject(text) }.getOrNull() ?: return
                // Apple's predicate, exactly: an explicit `paired`, or an `ok` that is not merely
                // "waiting for the other side".
                val isPaired = obj.optBoolean("paired", false) ||
                    (obj.optBoolean("ok", false) && !obj.optBoolean("waiting", false))
                if (isPaired) {
                    val fresh = synchronized(CallHairpin) { paired.add(remote) }
                    if (fresh) {
                        Log.i(TAG, "hairpin paired ${remote.take(8)}…")
                        onPaired?.invoke(remote)
                    }
                }
                obj.optString("err").takeIf { it.isNotEmpty() }?.let {
                    Log.w(TAG, "hairpin err ${remote.take(8)}: $it")
                }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                onBinary?.invoke(remote, bytes.toByteArray())
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "hairpin failed ${remote.take(8)}: ${t.message}")
                close(remote)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                close(remote)
            }
        })
        sockets[remote] = ws
    }

    fun openForRoster(context: Context, sessionId: String, me: String, others: Collection<String>) {
        others.filter { it != me }.forEach { open(context, sessionId, me, it) }
    }

    @Synchronized
    fun isPaired(remote: String): Boolean = paired.contains(remote)

    /**
     * Send one media frame to a paired remote. Fire-and-forget: real-time media tolerates loss, so a
     * failed send is dropped rather than retried — a retry only adds latency to a live call.
     */
    @Synchronized
    fun send(remote: String, data: ByteArray) {
        if (!paired.contains(remote)) return
        sockets[remote]?.send(ByteString.of(*data))
    }

    @Synchronized
    fun close(remote: String) {
        sockets.remove(remote)?.close(1000, null)
        paired.remove(remote)
    }

    @Synchronized
    fun closeAll() {
        sockets.values.forEach { it.close(1000, null) }
        sockets.clear()
        paired.clear()
    }
}
