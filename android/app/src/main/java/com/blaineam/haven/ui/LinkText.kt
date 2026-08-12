package com.blaineam.haven.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.TextUnit
import com.blaineam.haven.core.DeepLink
import com.blaineam.haven.core.PostLinkInbox

/**
 * THE url regex — one definition for every surface that scans a body for links.
 *
 * It used to be duplicated (a subtly different copy lived in LinkPreview.kt), which is fine while
 * you only *find* links and a disaster once you *remove* one: the preview card and the strip below
 * must agree on the match byte-for-byte, or the strip lands off by a character and leaves a shard
 * of URL in the sentence. Any new surface scans through here.
 */
val URL_REGEX = Regex("""https?://[^\s]+""")

/** The link a preview card would show for [text] — the FIRST url — or null if there is none. */
fun firstUrl(text: String): String? = URL_REGEX.find(text)?.value

/**
 * Body text as it should be DISPLAYED next to a link preview card: the previewed url removed, and
 * the whitespace it left behind tidied. Parity with iOS `LinkScanner.stripping`.
 *
 * The card already names the destination, more legibly, so leaving the raw url in the copy just
 * repeats it — and a shared post link is long enough to swamp the sentence around it. Only the
 * PREVIEWED (first) url is removed: a second link has no card of its own, so removing it would lose
 * it entirely. A body that was ONLY a link comes back empty, and the surface renders just the card.
 *
 * Only call this where a card is actually shown — strip without a card and the link is simply gone.
 */
fun bodyWithoutPreviewedUrl(text: String): String {
    val url = firstUrl(text) ?: return text
    val at = text.indexOf(url)
    if (at < 0) return text
    var out = text.removeRange(at, at + url.length)
    // Collapse the doubled spaces / stranded blank lines the removal can leave mid-sentence.
    while (out.contains("  ")) out = out.replace("  ", " ")
    while (out.contains("\n\n\n")) out = out.replace("\n\n\n", "\n\n")
    return out.trim()
}

/**
 * Open a URL from inside Haven: a HAVEN link routes in-app, anything else opens in Chrome Custom
 * Tabs (falling back to the system browser).
 *
 * A Haven post link never reaches a browser. Haven's own links are web-routed so they survive being
 * shared anywhere, but that meant tapping one INSIDE Haven loaded the landing page — which then
 * offers an "Open in Haven" button that can do nothing, because you are already in Haven looking at
 * a web view of your own content. The link's whole purpose is the destination it names, and in here
 * we can just go there. Routed through [PostLinkInbox], the same road an external ACTION_VIEW
 * intent takes (MainActivity.handleShare), so there is exactly one post-link destination.
 *
 * Centralised here on purpose: every link tap in the app funnels through this function, so no
 * surface can miss the fix. [openExternal] is the deliberate exception — a music provider's link is
 * meant to leave for its app.
 */
fun openInApp(context: Context, url: String) {
    val uri = Uri.parse(if (url.startsWith("http")) url else "https://$url")
    DeepLink.parseStory(uri.toString())?.let {
        com.blaineam.haven.core.StoryLinkInbox.offer(it); return
    }
    DeepLink.parsePost(uri.toString())?.let { PostLinkInbox.offer(it); return }
    runCatching { CustomTabsIntent.Builder().build().launchUrl(context, uri) }
        .onFailure { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) } }
}

/** Open a URL externally (ACTION_VIEW) so an installed provider app (Spotify/YouTube/Music) catches it. */
fun openExternal(context: Context, url: String) {
    val uri = Uri.parse(if (url.startsWith("http")) url else "https://$url")
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        .onFailure { openInApp(context, url) }
}

/**
 * Renders body text with tappable links (http/https) that open in the in-app browser — parity with
 * iOS link rendering. Plain text otherwise. YouTube and any other URLs are just links.
 */
@Composable
fun LinkedText(text: String, color: Color, fontSize: TextUnit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    if (!URL_REGEX.containsMatchIn(text)) {
        Text(text, color = color, fontSize = fontSize, modifier = modifier)
        return
    }
    val annotated = buildAnnotatedString {
        var last = 0
        for (m in URL_REGEX.findAll(text)) {
            if (m.range.first > last) append(text.substring(last, m.range.first))
            withLink(
                LinkAnnotation.Url(
                    m.value,
                    TextLinkStyles(SpanStyle(color = HavenTheme.pink, textDecoration = TextDecoration.Underline)),
                ) { openInApp(context, m.value) },
            ) { append(m.value) }
            last = m.range.last + 1
        }
        if (last < text.length) append(text.substring(last))
    }
    Text(annotated, color = color, fontSize = fontSize, modifier = modifier)
}
