import Foundation

/// Which of my posts are the same post published twice — the repair for an archive imported twice.
///
/// Pure so it can be tested. The first version of this shipped inside FeedStore, keyed partly on
/// media refs, and found nothing: the importer re-encodes what it stages, re-encoding is not
/// reproducible (AVAssetExportSession stamps its own timestamps, posters are generated fresh), so
/// the same photo gets a different content hash on the second run. The sweep ran perfectly and did
/// nothing, and nothing said so. Keeping the rule here means it can be shown to work on inputs that
/// look like the real ones, instead of being believed.
enum PostDedupe {

    /// One post, reduced to what an import CANNOT change.
    struct Candidate {
        let id: String
        /// Capture time from the archive, backdated — identical on every import of the same export.
        let createdAt: UInt64
        /// Caption, copied verbatim out of the archive.
        let body: String
        /// How many items the post carries — separates a single photo from a carousel.
        let mediaCount: Int
        /// What the post's first picture LOOKS like (`PerceptualHash`), when it could be computed.
        ///
        /// This is the strong signal and the reason the sweep is safe. Content refs cannot be used —
        /// re-encoding changes them — but a perceptual hash survives a re-encode and does NOT match
        /// a different photo. Nil means "unknown", which downgrades to the caption test rather than
        /// assuming anything.
        var mediaHash: UInt64? = nil
    }

    /// Captions compared insensitive to whitespace and case. NOT a similarity score: the same
    /// caption through two import runs is byte-identical, so nothing fuzzy is needed — and a
    /// threshold that merges "similar" captions would delete posts that merely resemble each other.
    static func normalizedCaption(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    /// The coarse bucket: two posts can only be the same post if they were captured at the same
    /// moment. Cheap, and it does the elimination.
    ///
    /// ITEM COUNT IS NOT PART OF THIS, and that was a real bug: it caught only 30 duplicates out of
    /// an archive imported twice. A post's ref count is not stable across imports — a video
    /// contributes a poster ref only if poster generation SUCCEEDS, and it demonstrably does not
    /// always ("poster generation FAILED for … in EVERY config" appears throughout an import). One
    /// run yields two refs for a reel, the next yields one, the buckets differ, and the duplicate is
    /// invisible. Count survives as a confirmation signal below, where being wrong is safe.
    static func bucket(_ c: Candidate) -> String { "\(c.createdAt)" }

    /// Are these the same post published twice?
    ///
    /// Both must already share a bucket. Then:
    ///   • both hashes known → the PICTURES decide. This is the strong case: a re-encode of the same
    ///     photo lands within a couple of bits, a different photo does not come close. It also
    ///     rescues the weak spot in the timestamp — Instagram exports capture time in SECONDS, so two
    ///     posts from one burst can share a bucket, and the pictures say plainly that they are not
    ///     the same post even when both captions are empty.
    ///   • either hash unknown (a video with no poster yet, an evicted blob) → fall back to the
    ///     caption. Weaker, so it is the fallback and never an override.
    static func isDuplicate(_ a: Candidate, _ b: Candidate) -> Bool {
        if let ha = a.mediaHash, let hb = b.mediaHash {
            return PerceptualHash.looksLikeTheSamePicture(ha, hb)
        }
        // Nothing to look at — the caption has to carry it, and it is weak enough that the item
        // count is required to agree too. That pairing is why count is not in the bucket: here a
        // mismatch merely declines to merge, whereas in the bucket it hid the duplicate entirely.
        return normalizedCaption(a.body) == normalizedCaption(b.body) && a.mediaCount == b.mediaCount
    }

    /// Ids to withdraw, keeping the FIRST of each group — callers pass oldest-first so the copy that
    /// has been in the circle longest is the one that stays.
    ///
    /// Posts carrying no media are never returned: with nothing to look at, the only evidence is a
    /// timestamp and a caption, which is exactly where a repeat is most likely to be deliberate.
    static func duplicates(_ posts: [Candidate]) -> [String] {
        var kept: [String: [Candidate]] = [:]   // bucket → the posts we are keeping from it
        var doomed: [String] = []
        for p in posts where p.mediaCount > 0 {
            let key = bucket(p)
            if let group = kept[key], group.contains(where: { isDuplicate($0, p) }) {
                doomed.append(p.id)
            } else {
                kept[key, default: []].append(p)
            }
        }
        return doomed
    }
}
