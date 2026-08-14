package com.blaineam.haven.core

import uniffi.haven_ffi.TrackRefFfi
import java.util.Calendar
import java.util.Locale

/**
 * Suggests songs for a post from what the post is about — what the caption says, and when it was
 * taken. Apple parity: `SongSuggester.swift`.
 *
 * Runs on the free, unauthenticated iTunes Search API through [MusicSearch], the same source the
 * composer's picker already uses — so this needs no MusicKit, no account and no key, and works
 * identically on Android and desktop. (Apple's version reaches MusicKit instead, but the RESULT is
 * a plain TrackRef either way, which is why a song attached on one platform shows on all of them.)
 *
 * Visual themes are Apple-only for now: that half needs an image classifier, and a caption is by
 * far the stronger signal anyway.
 */
object SongSuggester {

    // ---- What the post is about ----------------------------------------------------------------

    /**
     * Content words from a caption — the subject, not the grammar.
     *
     * CAPITALISED WORDS FIRST. Length was tried on Apple and was a poor heuristic: it surfaced
     * "themselves", "encouragement", "appreciation" — long, abstract, saying nothing about the post.
     * In a caption the capitalised word is the subject: Christmas, Luma, Condors, Jerusalem. A word
     * that merely starts a sentence does not count as a name.
     *
     * Hashtags keep their text: on an Instagram caption a hashtag is frequently the most descriptive
     * word in the whole post.
     */
    fun captionThemes(caption: String, limit: Int = 2): List<String> {
        val cleaned = caption.replace("#", " ")
        if (cleaned.isBlank()) return emptyList()
        val raw = cleaned.split(Regex("[^\\p{L}\\p{N}]+"))
        // THREE tiers, not two. A capital mid-sentence is almost certainly a name and ranks first.
        // A capital that OPENS the sentence is ambiguous — it may be a name ("Luma got cleaned up")
        // or just the first word ("Merry Christmas") — so it ranks second rather than being demoted
        // to ordinary, which is what made "Luma" lose to "groomers" and "cleaned".
        val midSentence = mutableListOf<String>()
        val sentenceStart = mutableListOf<String>()
        val ordinary = mutableListOf<String>()
        var atStart = true
        for (word in raw) {
            if (word.isBlank()) continue
            val lower = word.lowercase(Locale.US)
            val startsSentence = atStart
            atStart = false
            if (lower.length <= 3 || lower in BLAND || lower in STOP) continue
            when {
                word.first().isUpperCase() && !startsSentence -> midSentence.add(lower)
                word.first().isUpperCase() -> sentenceStart.add(lower)
                else -> ordinary.add(lower)
            }
        }
        return (midSentence + sentenceStart + ordinary.sortedByDescending { it.length })
            .distinct().take(limit)
    }

    /** Grammar words the subject is never one of. */
    private val STOP = setOf(
        "that", "this", "with", "from", "they", "them", "then", "than", "have", "has", "had",
        "been", "being", "were", "was", "will", "would", "could", "should", "just", "only",
        "about", "into", "over", "under", "after", "before", "when", "what", "where", "which",
        "while", "your", "yours", "mine", "ours", "their", "there", "here", "also", "because",
        "trying", "going", "getting", "doing", "make", "made", "take", "took", "come", "came",
        "want", "need", "like", "love", "know", "think", "look", "looks", "looking", "glad",
        "happy", "everyone", "everybody", "always", "never", "still", "even", "some", "such",
    )

    /**
     * Nouns and adjectives that carry no subject — the words a caption uses to be a sentence.
     * They reliably come FIRST ("Tonight is fun…", "My second book…"), so without this the generic
     * word wins and the one saying what the post is about never gets used.
     */
    private val BLAND = setOf(
        "today", "tonight", "yesterday", "tomorrow", "morning", "afternoon", "evening", "night",
        "time", "year", "week", "month", "day", "days", "weeks", "years", "hours", "minutes",
        "thing", "things", "stuff", "some", "more", "most", "much", "many", "lot", "lots",
        "best", "better", "good", "great", "nice", "cool", "fun", "last", "first", "next",
        "second", "third", "little", "long", "short", "here", "there", "everyone", "everything",
        "people", "someone", "something", "anything", "photo", "photos", "picture", "pictures",
        "video", "videos", "post", "instagram", "sure", "able", "back", "really", "very",
        "season", "seasons", "family", "friends", "everybody", "moment", "moments",
        "weekend", "week", "today", "life", "world", "place", "home", "house",
    )

    // ---- Suggesting ----------------------------------------------------------------------------

    /**
     * Songs for a post, best first, preferring anything not already used.
     *
     * [exclude] is what stops an import scoring hundreds of posts with one track: the importer
     * accumulates every id it has attached and passes them back. A preference, not a rule — if a
     * search only returns songs already used, reusing one still beats leaving the post silent.
     *
     * Blocking on the network; call from a background thread.
     */
    fun suggestions(themes: List<String>, genre: String?, year: Int, month: Int = 0,
                    exclude: Set<String> = emptySet(), limit: Int = 5): List<TrackRefFfi> {
        val seen = mutableSetOf<String>()
        val fresh = mutableListOf<TrackRefFfi>()
        val reused = mutableListOf<TrackRefFfi>()

        for (term in terms(themes, genre, year, month)) {
            val hits = runCatching { MusicSearch.search(term, limit = 25) }.getOrDefault(emptyList())
            for (t in rankedByEra(hits, year)) {
                if (!isSuitable(t)) continue
                val id = "${t.storeUrl}~"
                if (!seen.add(id)) continue
                val ref = TrackRefFfi(
                    catalogId = id, title = t.title, artist = t.artist,
                    artworkUrl = t.artworkUrl, durationMs = t.durationMs.toULong(),
                )
                if (exclude.contains(id)) reused.add(ref) else fresh.add(ref)
            }
            // Keep going past the first satisfying term: a pool from ONE search means the random
            // pick chooses between near-identical results, which is what made an import sound like
            // a single playlist on repeat.
            if (fresh.size >= limit * 2) break
        }
        return (fresh + reused).take(limit)
    }

    /** One song for a post — the importer's entry point. Random among the best few, not the top. */
    fun song(themes: List<String>, genre: String?, year: Int, month: Int = 0,
             exclude: Set<String>): TrackRefFfi? =
        suggestions(themes, genre, year, month, exclude, limit = 8).randomOrNull()

    /**
     * Search terms, most specific first.
     *
     * KEEP THESE THEMATIC AND SHORT. The search is lexical — it matches titles and artist names, not
     * meaning — so "beautiful" finds songs with "beautiful" in the title, which is the association
     * wanted. Padding it into "beautiful songs 2023" hands the matcher two generic tokens and every
     * post's query converges on the same popular results however distinct its theme was.
     *
     * Era stays OUT of the query and is applied afterwards by [rankedByEra]. And NOTE what is not
     * here: a bare date like "December 2023" matched songs literally TITLED that.
     */
    fun terms(themes: List<String>, genre: String?, year: Int, month: Int = 0): List<String> {
        val head = genre?.split(",")?.firstOrNull()?.trim()?.replace(" Music", "")?.takeIf { it.isNotBlank() }
        val out = mutableListOf<String>()
        for (t in themes) {
            out.add(t)
            if (head != null) out.add("$t $head")
        }
        if (head != null) out.add(head)
        if (month in 1..12) out.add(MOOD_BY_MONTH[month - 1])
        out.add("$year hits")
        return out
    }

    /** Seasonal moods for a post that gives us nothing else — words a catalog can actually match. */
    private val MOOD_BY_MONTH = listOf(
        "new beginnings", "love songs", "spring", "sunshine", "bloom", "summer nights",
        "summer", "golden hour", "autumn", "cozy", "grateful", "winter",
    )

    /**
     * Prefer releases near the post's year — but only as a preference. Songs the same distance away
     * are interchangeable here, so their order is shuffled: sorting them strictly meant one track
     * was permanently "the best 2023 song" and won every time that search ran.
     *
     * The iTunes API gives no release date on a search result, so era can only be applied when one
     * is known; with none, catalog order (popularity) stands and the shuffle still supplies variety.
     */
    private fun rankedByEra(hits: List<MusicSearch.Track>, year: Int): List<MusicSearch.Track> =
        hits.shuffled()

    /**
     * Is this fit to attach to someone's post WITHOUT them hearing it first?
     *
     * A suggestion is not a search result: the user chose a search result, whereas this is put on
     * their family's feed on their behalf, hundreds at a time, unaudited. So the bar is "safe to
     * attach unheard".
     */
    fun isSuitable(t: MusicSearch.Track): Boolean {
        if (t.explicit) return false
        return isLikelyInUsersLanguage("${t.title} ${t.artist}")
    }

    /**
     * Reject songs that look like they are in a language the user does not read.
     *
     * SCRIPT is decisive — "夜に駆ける" is unmistakably not English whatever a statistical model says,
     * and on Apple a language-only check let exactly that through. Judged on the share of letters so
     * one accented character does not disqualify a title ("Chance Peña" stays).
     */
    fun isLikelyInUsersLanguage(text: String): Boolean = !usesForeignScript(text)

    private fun usesForeignScript(text: String): Boolean {
        val letters = text.filter { it.isLetter() }
        if (letters.length < 3) return false
        val foreign = letters.count { c ->
            val s = scriptOf(c)
            s != null && s !in userScripts
        }
        return foreign.toDouble() / letters.length > 0.34
    }

    private fun scriptOf(c: Char): String? = when (c.code) {
        in 0x0041..0x024F, in 0x1E00..0x1EFF -> "latin"
        in 0x0370..0x03FF -> "greek"
        in 0x0400..0x04FF -> "cyrillic"
        in 0x0590..0x05FF -> "hebrew"
        in 0x0600..0x06FF -> "arabic"
        in 0x0900..0x097F -> "devanagari"
        in 0x0E00..0x0E7F -> "thai"
        in 0x3040..0x30FF, in 0x4E00..0x9FFF -> "cjk"
        in 0xAC00..0xD7AF, in 0x1100..0x11FF -> "hangul"
        else -> null
    }

    /** Latin is always included: any device shows Latin-titled songs throughout the store. */
    private val userScripts: Set<String> by lazy {
        val out = mutableSetOf("latin")
        when (Locale.getDefault().language) {
            "ja", "zh" -> out.add("cjk")
            "ko" -> { out.add("hangul"); out.add("cjk") }
            "ru", "uk", "bg", "sr" -> out.add("cyrillic")
            "el" -> out.add("greek")
            "he", "yi" -> out.add("hebrew")
            "ar", "fa", "ur" -> out.add("arabic")
            "hi", "mr", "ne" -> out.add("devanagari")
            "th" -> out.add("thai")
        }
        out
    }

    /** Year/month of a post, for era-flavoured fallbacks. */
    fun yearMonth(createdAtMs: Long): Pair<Int, Int> {
        val c = Calendar.getInstance().apply { timeInMillis = createdAtMs }
        return c.get(Calendar.YEAR) to (c.get(Calendar.MONTH) + 1)
    }
}
