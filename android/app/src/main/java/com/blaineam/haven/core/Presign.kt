package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * The member side of the iOS pre-signed-URL S3 mailbox (PresignStore). The bucket owner mints a
 * pool of scoped, expiring pre-signed URLs and ships the bootstrap GET URL over frame 20 (sealed).
 * Members never see credentials — they PUT/LIST/GET via the pre-signed URLs over plain HTTPS.
 *
 *   pool JSON (sealed, at the bootstrap URL): { circleId, expires, puts:{memberHex:[PUT]},
 *                                               gets:{key:GET}, listURL }
 *   event keys: haven/mailbox/<circle>/<memberHex>/<n>
 */
object Presign {
    private const val TAG = "Presign"
    private lateinit var prefs: android.content.SharedPreferences
    private val pools = HashMap<String, Pool>()

    class Pool(val expires: Double, val puts: Map<String, List<String>>, val gets: Map<String, String>, val listURL: String)

    fun init(context: Context) {
        if (this::prefs.isInitialized) return
        prefs = context.applicationContext.getSharedPreferences("haven.presign", Context.MODE_PRIVATE)
    }

    fun hasBootstrap(circleId: String): Boolean = prefs.getString("boot.$circleId", null) != null
    fun anyBootstrap(): Boolean = prefs.all.keys.any { it.startsWith("boot.") }

    fun setBootstrap(circleId: String, url: String) {
        prefs.edit().putString("boot.$circleId", url).apply()
        pools.remove(circleId)   // force refetch
    }

    /** All circle ids we hold a bootstrap for. */
    fun circles(): List<String> = prefs.all.keys.filter { it.startsWith("boot.") }.map { it.removePrefix("boot.") }

    private fun pool(circleId: String): Pool? {
        pools[circleId]?.let { if (it.expires > nowSec() + 60) return it }
        val boot = prefs.getString("boot.$circleId", null) ?: return null
        val sealed = httpGet(boot) ?: return null
        val data = runCatching { HavenNet.engine.openCircleMedia(circleId, sealed) }.getOrNull() ?: return null
        val p = runCatching { parsePool(String(data, Charsets.UTF_8)) }.getOrNull() ?: return null
        pools[circleId] = p
        return p
    }

    private fun parsePool(json: String): Pool {
        val o = JSONObject(json)
        val putsObj = o.getJSONObject("puts")
        val puts = HashMap<String, List<String>>()
        putsObj.keys().forEach { k ->
            val arr = putsObj.getJSONArray(k)
            puts[k] = (0 until arr.length()).map { arr.getString(it) }
        }
        val getsObj = o.getJSONObject("gets")
        val gets = HashMap<String, String>()
        getsObj.keys().forEach { k -> gets[k] = getsObj.getString(k) }
        return Pool(o.optDouble("expires", 0.0), puts, gets, o.optString("listURL", ""))
    }

    /** Upload a sealed envelope to my next free PUT slot. Returns true if it landed. */
    fun uploadEvent(circleId: String, myHex: String, env: ByteArray): Boolean {
        val p = pool(circleId) ?: return false
        val mine = p.puts[myHex] ?: return false
        val used = prefs.getInt("used.$circleId", 0)
        if (used >= mine.size) return false   // exhausted until the owner re-mints
        if (!httpPut(mine[used], env)) return false
        prefs.edit().putInt("used.$circleId", used + 1).apply()
        return true
    }

    /** Poll: list the mailbox prefix, GET each key we haven't seen, return (key, env) pairs. */
    fun poll(circleId: String, seen: Set<String>): List<Pair<String, ByteArray>> {
        val p = pool(circleId) ?: return emptyList()
        if (p.listURL.isEmpty()) return emptyList()
        val xml = httpGet(p.listURL)?.let { String(it, Charsets.UTF_8) } ?: return emptyList()
        val keys = Regex("<Key>([^<]+)</Key>").findAll(xml).map { it.groupValues[1] }.toList()
        val out = ArrayList<Pair<String, ByteArray>>()
        for (key in keys) {
            if (seen.contains(key)) continue
            val getUrl = p.gets[key] ?: continue   // owner pre-minted a GET for every slot
            val env = httpGet(getUrl) ?: continue
            out.add(key to env)
        }
        return out
    }

    fun reset() {
        if (this::prefs.isInitialized) prefs.edit().clear().commit()
        pools.clear()
    }

    // --- plain HTTPS against pre-signed URLs (no creds, no SigV4) ---

    private fun httpGet(url: String): ByteArray? = runCatching {
        if (HavenOffline.enabled) return null   // haven_no_net: no pre-signed bucket reads
        val c = (URL(url).openConnection() as HttpURLConnection).apply { connectTimeout = 8000; readTimeout = 12000 }
        if (c.responseCode in 200..299) c.inputStream.use { it.readBytes() } else null
    }.getOrElse { Log.d(TAG, "GET failed: ${it.message}"); null }

    private fun httpPut(url: String, body: ByteArray): Boolean = runCatching {
        if (HavenOffline.enabled) return false   // haven_no_net: no pre-signed bucket writes
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "PUT"; doOutput = true; connectTimeout = 8000; readTimeout = 20000
            setRequestProperty("Content-Type", "application/octet-stream")
        }
        c.outputStream.use { it.write(body) }
        c.responseCode in 200..299
    }.getOrElse { Log.d(TAG, "PUT failed: ${it.message}"); false }

    private fun nowSec(): Double = System.currentTimeMillis() / 1000.0
}
