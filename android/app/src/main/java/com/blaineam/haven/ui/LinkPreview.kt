package com.blaineam.haven.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL

private data class OgPreview(val title: String, val desc: String, val domain: String, val image: ImageBitmap?)

private class CacheEntry(val preview: OgPreview?, val at: Long)

private const val CACHE_MAX_ENTRIES = 64
private const val NEGATIVE_TTL_MS = 10 * 60 * 1000L

/**
 * Bounded, access-ordered cache of fetched previews.
 *
 * Was a plain `HashMap` that never evicted and cached failures forever: browse a busy circle and it
 * grew for the life of the process, holding a decoded bitmap per entry, and a site that was down
 * once stayed "dead" until the app restarted. Now it is an LRU with a hard entry cap, and negative
 * results expire so a transient failure is not permanent.
 */
private val ogCache = object : LinkedHashMap<String, CacheEntry>(16, 0.75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CacheEntry>): Boolean =
        size > CACHE_MAX_ENTRIES
}

private fun cachedPreview(url: String): CacheEntry? = synchronized(ogCache) {
    val e = ogCache[url] ?: return null
    // Negative entries go stale; successful ones are worth keeping for the session.
    if (e.preview == null && System.currentTimeMillis() - e.at > NEGATIVE_TTL_MS) {
        ogCache.remove(url)
        return null
    }
    e
}

private fun cachePreview(url: String, preview: OgPreview?) {
    synchronized(ogCache) { ogCache[url] = CacheEntry(preview, System.currentTimeMillis()) }
}

/**
 * A tappable Open Graph preview card for the first link in [text] (title + thumbnail + domain).
 *
 * The card ALWAYS renders once there is a url — Open Graph metadata only upgrades it. It used to
 * disappear entirely when the fetch failed or the page carried no tags, which was harmless while
 * the body still showed the raw link, but the body now STRIPS the previewed url (see
 * [bodyWithoutPreviewedUrl]); a card that can vanish would take the only copy of the link with it,
 * and a link-only post would render blank. So the title falls back to the domain and then to the
 * url itself, matching iOS `LinkPreviewCard.displayTitle`.
 *
 * NOTHING IS FETCHED UNTIL YOU ASK FOR IT. The metadata fetch used to fire from `LaunchedEffect` as
 * soon as the card scrolled into view, which handed any circle member a network primitive aimed at
 * the RECIPIENT's device: putting a link in a message made the reader's phone connect to it on
 * render, with no tap. That leaks the reader's IP and the moment they read (a read receipt nobody
 * consented to), and points their device at whatever host the sender named. Loading is now behind
 * an explicit "Load preview" tap, so the socket only opens for a link this person chose to expand.
 * [LinkSafety] then vets where it is allowed to go.
 *
 * Uses the shared [URL_REGEX] so the url it previews is byte-identical to the one the body strips.
 */
@Composable
fun LinkPreviewCard(text: String, modifier: Modifier = Modifier) {
    val url = remember(text) { firstUrl(text) } ?: return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var preview by remember(url) { mutableStateOf(cachedPreview(url)?.preview) }
    var loaded by remember(url) { mutableStateOf(cachedPreview(url) != null) }
    var loading by remember(url) { mutableStateOf(false) }

    val host = remember(url) { runCatching { URL(url).host.removePrefix("www.") }.getOrDefault("") }
    val p = preview ?: OgPreview(title = "", desc = "", domain = host, image = null)
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(HavenTheme.background)
            .clickable { openInApp(context, url) },
    ) {
        p.image?.let {
            Image(it, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxWidth().height(160.dp))
        }
        Column(Modifier.padding(12.dp)) {
            Text(p.title.ifBlank { p.domain.ifBlank { url } }, color = HavenTheme.textPrimary,
                fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 2)
            if (p.desc.isNotBlank()) {
                Text(p.desc, color = HavenTheme.textSecondary, fontSize = 12.sp, maxLines = 2)
            }
            if (p.domain.isNotBlank()) Text(p.domain, color = HavenTheme.pink, fontSize = 11.sp)

            // The load affordance sits INSIDE the card but carries its own click, so the card's own
            // tap still means "open the link" — one control, one meaning.
            if (!loaded) {
                Row(
                    Modifier.padding(top = 8.dp).clip(RoundedCornerShape(8.dp))
                        .clickable(enabled = !loading) {
                            loading = true
                            scope.launch {
                                val p2 = withContext(Dispatchers.IO) { runCatching { fetchOg(url) }.getOrNull() }
                                cachePreview(url, p2)
                                preview = p2
                                loaded = true
                                loading = false
                            }
                        },
                ) {
                    Text(
                        if (loading) "Loading preview…" else "Load preview",
                        color = HavenTheme.pink, fontSize = 11.sp,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
            }
        }
    }
}

/**
 * Pull Open Graph metadata for [url], having first established that [url] is somewhere we are
 * willing to send this device.
 *
 * Every network read here goes through [LinkSafety.openVetted]: public destinations only, redirects
 * followed by hand and re-vetted per hop, and a real streaming byte ceiling rather than a truncation
 * applied after the whole response is already in memory.
 */
private fun fetchOg(url: String): OgPreview? {
    val bytes = LinkSafety.openVetted(url, LinkSafety.MAX_HTML_BYTES, "text/html,application/xhtml+xml")
        ?: return null
    val html = bytes.toString(Charsets.UTF_8)

    fun meta(prop: String): String? =
        Regex("""<meta[^>]{0,400}?(?:property|name)=["']$prop["'][^>]{0,400}?content=["']([^"']{0,2000})["']""", RegexOption.IGNORE_CASE)
            .find(html)?.groupValues?.get(1)
            ?: Regex("""<meta[^>]{0,400}?content=["']([^"']{0,2000})["'][^>]{0,400}?(?:property|name)=["']$prop["']""", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)

    val title = meta("og:title")
        ?: Regex("""<title[^>]{0,400}>([^<]{0,2000})</title>""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
        ?: ""
    val desc = meta("og:description") ?: meta("description") ?: ""
    val domain = runCatching { URL(url).host.removePrefix("www.") }.getOrDefault("")
    val imgUrl = meta("og:image")
    val image = imgUrl?.let { iu ->
        runCatching {
            // The poster is a SECOND peer-controlled url — it is chosen by the page, which was
            // chosen by the sender — so it gets the same treatment as the page itself rather than
            // being handed straight to the network stack.
            val abs = if (iu.startsWith("http")) iu else if (iu.startsWith("//")) "https:$iu" else URL(URL(url), iu).toString()
            LinkSafety.openVetted(abs, LinkSafety.MAX_IMAGE_BYTES, "image/*")?.let { raw ->
                decodeBounded(raw)
            }
        }.getOrNull()
    }
    if (title.isBlank() && image == null) return null
    return OgPreview(unescape(title), unescape(desc), domain, image)
}

/** Largest poster we will rasterize, per side. A card shows it 160dp tall; anything beyond this is a bomb. */
private const val MAX_IMAGE_DIMENSION = 2048

/**
 * Decode a poster from bytes we already capped, refusing absurd dimensions.
 *
 * A byte cap alone does not bound the decode: a couple of hundred KB of PNG can declare enormous
 * dimensions and allocate gigabytes when rasterized. So the header is measured first and the pixels
 * are only committed to if the size is sane, downsampling toward the ~160dp the card actually draws.
 */
private fun decodeBounded(raw: ByteArray): ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
    val w = bounds.outWidth
    val h = bounds.outHeight
    if (w <= 0 || h <= 0 || w > MAX_IMAGE_DIMENSION || h > MAX_IMAGE_DIMENSION) return null
    var sample = 1
    while (w / sample > 1024 || h / sample > 1024) sample *= 2
    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    return BitmapFactory.decodeByteArray(raw, 0, raw.size, opts)?.asImageBitmap()
}

private fun unescape(s: String) = s
    .replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'")
    .replace("&lt;", "<").replace("&gt;", ">")
