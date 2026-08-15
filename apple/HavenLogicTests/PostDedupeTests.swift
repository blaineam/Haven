import XCTest
@testable import HavenLogicTests

/// The rule that repairs an archive imported twice.
///
/// The first version of this keyed partly on MEDIA REFS and found nothing, because the importer
/// re-encodes what it stages and re-encoding is not reproducible — the same photo gets a different
/// content hash on the second run. The sweep ran and did nothing, twice, before that was noticed.
/// These cases are written from what an import actually produces, so the rule has to survive the
/// thing that defeated the last one.
final class PostDedupeTests: XCTestCase {

    private func post(_ id: String, _ at: UInt64, _ body: String, _ n: Int = 1) -> PostDedupe.Candidate {
        PostDedupe.Candidate(id: id, createdAt: at, body: body, mediaCount: n)
    }

    /// THE CASE THAT WAS BROKEN: same archive imported twice. Media refs differ between the runs
    /// (they are not an input here, which is the fix); capture time and caption do not.
    func testTheSameArchiveImportedTwiceIsDeduplicated() {
        let posts = [
            post("a1", 1_600_000_000_000, "Sunset at the lake"),
            post("a2", 1_600_000_086_000, "Coffee"),
            post("b1", 1_600_000_000_000, "Sunset at the lake"),   // second run
            post("b2", 1_600_000_086_000, "Coffee"),
        ]
        XCTAssertEqual(PostDedupe.duplicates(posts), ["b1", "b2"],
                       "the second import's copies should be withdrawn, the originals kept")
    }

    /// Three runs of the same import leave one post, not two.
    func testThreeImportsLeaveOne() {
        let posts = (0..<3).map { post("run\($0)", 1_600_000_000_000, "Same post") }
        XCTAssertEqual(PostDedupe.duplicates(posts), ["run1", "run2"])
    }

    /// Instagram exports capture time in SECONDS, so a burst can share a timestamp. A single photo
    /// and a carousel taken in the same second are different posts and must both survive.
    func testSameSecondDifferentItemCountsAreNotMerged() {
        let posts = [post("single", 1_600_000_000_000, "", 1), post("carousel", 1_600_000_000_000, "", 8)]
        XCTAssertTrue(PostDedupe.duplicates(posts).isEmpty)
    }

    /// Same second, same item count, DIFFERENT captions — two posts.
    func testSameSecondDifferentCaptionsAreNotMerged() {
        let posts = [post("x", 1_600_000_000_000, "First"), post("y", 1_600_000_000_000, "Second")]
        XCTAssertTrue(PostDedupe.duplicates(posts).isEmpty)
    }

    /// Captions are compared insensitive to whitespace and case, because that costs nothing and the
    /// same caption through two runs should match however it is spelled.
    func testCaptionComparisonIgnoresWhitespaceAndCase() {
        let posts = [
            post("a", 1_600_000_000_000, "Sunset  at   the lake"),
            post("b", 1_600_000_000_000, "  sunset at the lake  "),
        ]
        XCTAssertEqual(PostDedupe.duplicates(posts), ["b"])
    }

    /// NOT a similarity score. Two posts whose captions merely resemble each other are two posts,
    /// and a threshold that merged them would destroy content that cannot be recovered.
    func testSimilarButDifferentCaptionsAreNotMerged() {
        let posts = [
            post("a", 1_600_000_000_000, "Day 1 at the lake"),
            post("b", 1_600_000_000_000, "Day 2 at the lake"),
        ]
        XCTAssertTrue(PostDedupe.duplicates(posts).isEmpty)
    }

    /// Text-only posts are never swept: with no item count the key is weakest exactly where a repeat
    /// is most likely to be deliberate.
    func testTextOnlyPostsAreNeverSwept() {
        let posts = [post("a", 1_600_000_000_000, "gm", 0), post("b", 1_600_000_000_000, "gm", 0)]
        XCTAssertTrue(PostDedupe.duplicates(posts).isEmpty)
    }

    /// A genuine posting history — nothing shares a timestamp — is left entirely alone.
    func testAnOrdinaryFeedIsUntouched() {
        let posts = (0..<50).map { post("p\($0)", 1_600_000_000_000 + UInt64($0) * 60_000, "post \($0)") }
        XCTAssertTrue(PostDedupe.duplicates(posts).isEmpty)
    }
}

// MARK: - Visual confirmation

extension PostDedupeTests {

    private func hashed(_ id: String, _ at: UInt64, _ body: String, _ n: Int, _ hash: UInt64?) -> PostDedupe.Candidate {
        PostDedupe.Candidate(id: id, createdAt: at, body: body, mediaCount: n, mediaHash: hash)
    }

    /// THE HOLE THE PICTURES CLOSE: Instagram exports capture time in SECONDS, so a burst shares a
    /// timestamp. Two different photos, same second, both with no caption, would have been merged on
    /// timestamp alone — and merging them destroys a post that cannot be recovered.
    func testSameSecondDifferentPicturesAreNotMergedEvenWithNoCaption() {
        let posts = [
            hashed("a", 1_600_000_000_000, "", 1, 0x0000_0000_0000_0000),
            hashed("b", 1_600_000_000_000, "", 1, 0xFFFF_FFFF_FFFF_FFFF),
        ]
        XCTAssertTrue(PostDedupe.duplicates(posts).isEmpty,
                      "different pictures in the same second are different posts")
    }

    /// A re-encoded copy: same picture, a couple of bits different, captions identical.
    func testAReEncodedCopyIsStillCaught() {
        let posts = [
            hashed("first", 1_600_000_000_000, "Lake", 1, 0x0F0F_0F0F_0F0F_0F0F),
            hashed("reimport", 1_600_000_000_000, "Lake", 1, 0x0F0F_0F0F_0F0F_0F0B),  // 2 bits off
        ]
        XCTAssertEqual(PostDedupe.duplicates(posts), ["reimport"])
    }

    /// The pictures OVERRIDE an identical caption — same second, same caption, visibly different
    /// photos are two posts. Captions repeat; photographs do not.
    func testIdenticalCaptionsDoNotOverrideDifferentPictures() {
        let posts = [
            hashed("a", 1_600_000_000_000, "Same caption", 1, 0x0000_0000_0000_0000),
            hashed("b", 1_600_000_000_000, "Same caption", 1, 0xFFFF_FFFF_FFFF_FFFF),
        ]
        XCTAssertTrue(PostDedupe.duplicates(posts).isEmpty)
    }

    /// An unknown hash (a video with no poster generated yet) falls back to the caption rather than
    /// assuming either way.
    func testUnknownHashFallsBackToTheCaption() {
        let posts = [
            hashed("a", 1_600_000_000_000, "Reel", 1, nil),
            hashed("b", 1_600_000_000_000, "Reel", 1, nil),
        ]
        XCTAssertEqual(PostDedupe.duplicates(posts), ["b"])
    }
}
