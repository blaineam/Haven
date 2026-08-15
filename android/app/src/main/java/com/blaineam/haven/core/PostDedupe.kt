package com.blaineam.haven.core

/**
 * Which of my posts are the same post published twice — the repair for an archive imported twice.
 *
 * A byte-for-byte port of `apple/HavenApp/PostDedupe.swift`, and it must stay that way: both
 * platforms sweep the same circle, so a rule that disagrees would have one device withdrawing posts
 * the other keeps. Kept pure so it can be unit-tested on the JVM.
 *
 * The history is worth knowing, because two obvious-looking keys were both wrong:
 *
 *  1. MEDIA REFS. A ref is a sha-256 of the plaintext, so sharing one means carrying the identical
 *     picture — true, and useless: the importer re-encodes everything it stages, and re-encoding is
 *     not reproducible. The second import mints different refs for the same photo. Found nothing.
 *  2. ITEM COUNT IN THE BUCKET. A video contributes a poster ref only when poster generation
 *     succeeds, and it does not always. One run yields two refs for a reel, the next yields one, and
 *     the duplicate becomes invisible. Caught 30 of an archive imported twice; the correct answer
 *     was 81.
 *
 * What survives a re-import is the archive's own data — the backdated capture time and the caption —
 * plus what the pictures LOOK like ([PerceptualHash]), which is the strong signal precisely because
 * it is indifferent to re-encoding.
 */
object PostDedupe {

    /** One post, reduced to what an import CANNOT change. */
    data class Candidate(
        val id: String,
        /** Capture time from the archive, backdated — identical on every import of the same export. */
        val createdAt: ULong,
        /** Caption, copied verbatim out of the archive. */
        val body: String,
        /** How many items the post carries. A confirmation signal only — see the note on [bucket]. */
        val mediaCount: Int,
        /** What the post's first picture looks like, when it could be computed; null = unknown. */
        val mediaHash: ULong? = null,
    )

    /**
     * Compared insensitive to whitespace and case. NOT a similarity score: the same caption through
     * two import runs is byte-identical, and a threshold that merged "similar" captions would delete
     * posts that merely resemble each other.
     */
    fun normalizedCaption(body: String): String =
        body.trim().replace(Regex("\\s+"), " ").lowercase()

    /**
     * Two posts can only be the same post if they were captured at the same moment.
     *
     * Item count is deliberately NOT here — see the class note; it hid most of the duplicates.
     */
    fun bucket(c: Candidate): String = c.createdAt.toString()

    /**
     * Both hashes known → the PICTURES decide, which also rescues the weak spot in the timestamp
     * (Instagram exports capture time in SECONDS, so a burst shares a bucket). Either unknown → fall
     * back to caption AND item count, which is weaker, so it is the fallback and never an override.
     */
    fun isDuplicate(a: Candidate, b: Candidate): Boolean {
        val ha = a.mediaHash
        val hb = b.mediaHash
        if (ha != null && hb != null) return PerceptualHash.looksLikeTheSamePicture(ha, hb)
        return normalizedCaption(a.body) == normalizedCaption(b.body) && a.mediaCount == b.mediaCount
    }

    /**
     * Ids to withdraw, keeping the FIRST of each group — callers pass oldest-first so the copy that
     * has been in the circle longest is the one that stays.
     *
     * Posts carrying no media are never returned: with nothing to look at, the only evidence is a
     * timestamp and a caption, which is exactly where a repeat is most likely to be deliberate.
     */
    fun duplicates(posts: List<Candidate>): List<String> {
        val kept = HashMap<String, MutableList<Candidate>>()
        val doomed = ArrayList<String>()
        for (p in posts) {
            if (p.mediaCount <= 0) continue
            val group = kept.getOrPut(bucket(p)) { ArrayList() }
            if (group.any { isDuplicate(it, p) }) doomed.add(p.id) else group.add(p)
        }
        return doomed
    }
}
