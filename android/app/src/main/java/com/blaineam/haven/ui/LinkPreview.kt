package com.blaineam.haven.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
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
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

private data class OgPreview(val title: String, val desc: String, val domain: String, val image: ImageBitmap?)

private val ogCache = HashMap<String, OgPreview?>()

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
 * Uses the shared [URL_REGEX] so the url it previews is byte-identical to the one the body strips.
 */
@Composable
fun LinkPreviewCard(text: String, modifier: Modifier = Modifier) {
    val url = remember(text) { firstUrl(text) } ?: return
    val context = LocalContext.current
    var preview by remember(url) { mutableStateOf(ogCache[url]) }

    LaunchedEffect(url) {
        if (ogCache.containsKey(url)) { preview = ogCache[url]; return@LaunchedEffect }
        val p = withContext(Dispatchers.IO) { runCatching { fetchOg(url) }.getOrNull() }
        ogCache[url] = p
        preview = p
    }

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
        }
    }
}

private fun fetchOg(url: String): OgPreview? {
    val conn = (URL(url).openConnection() as HttpURLConnection).apply {
        instanceFollowRedirects = true
        connectTimeout = 6000; readTimeout = 6000
        setRequestProperty("User-Agent", "Mozilla/5.0 (Haven)")
    }
    val html = conn.inputStream.use { it.readBytes().copyOf(256 * 1024).toString(Charsets.UTF_8) }
    fun meta(prop: String): String? =
        Regex("""<meta[^>]+(?:property|name)=["']$prop["'][^>]+content=["']([^"']+)["']""", RegexOption.IGNORE_CASE)
            .find(html)?.groupValues?.get(1)
            ?: Regex("""<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']$prop["']""", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)
    val title = meta("og:title") ?: Regex("""<title[^>]*>([^<]+)</title>""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1) ?: ""
    val desc = meta("og:description") ?: meta("description") ?: ""
    val domain = runCatching { URL(url).host.removePrefix("www.") }.getOrDefault("")
    val imgUrl = meta("og:image")
    val image = imgUrl?.let { iu ->
        runCatching {
            val ic = (URL(if (iu.startsWith("http")) iu else "https:$iu").openConnection() as HttpURLConnection).apply {
                connectTimeout = 6000; readTimeout = 6000
            }
            ic.inputStream.use { BitmapFactory.decodeStream(it) }?.asImageBitmap()
        }.getOrNull()
    }
    if (title.isBlank() && image == null) return null
    return OgPreview(unescape(title), unescape(desc), domain, image)
}

private fun unescape(s: String) = s
    .replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'")
    .replace("&lt;", "<").replace("&gt;", ">")
