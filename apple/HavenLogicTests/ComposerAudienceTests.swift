import XCTest

/// The composer says who a circle post reaches (2.0 "who sees your post"). The rule: name the circle
/// when it fits (≤ 14 characters), otherwise fall back to "everyone" — never silently truncate a
/// circle name into something that reads like a different audience.
final class ComposerAudienceTests: XCTestCase {

    func testPostPlaceholderNamesAShortCircle() {
        XCTAssertEqual(ComposerAudience.postPlaceholder("Family"), "Post to everyone in Family")
    }

    func testReplyPlaceholderNamesAShortCircle() {
        XCTAssertEqual(ComposerAudience.replyPlaceholder("Family"), "Reply to everyone in Family…")
    }

    func testFourteenCharactersIsTheLastLengthThatIsNamed() {
        let fourteen = String(repeating: "a", count: 14)
        let fifteen = String(repeating: "a", count: 15)
        XCTAssertEqual(ComposerAudience.postPlaceholder(fourteen), "Post to everyone in \(fourteen)")
        XCTAssertEqual(ComposerAudience.postPlaceholder(fifteen), "Post to everyone…")
        XCTAssertEqual(ComposerAudience.replyPlaceholder(fourteen), "Reply to everyone in \(fourteen)…")
        XCTAssertEqual(ComposerAudience.replyPlaceholder(fifteen), "Reply to everyone…")
    }

    func testLengthCountsCharactersNotBytes() {
        // Emoji / accented names are counted as the user sees them.
        let name = "Peña 👨‍👩‍👧"
        XCTAssertLessThanOrEqual(name.count, 14)
        XCTAssertEqual(ComposerAudience.postPlaceholder(name), "Post to everyone in \(name)")
    }

    func testPlaceholdersNeverClaimAPrivateAudience() {
        for name in ["Family", "A very long circle name indeed", ""] {
            for s in [ComposerAudience.postPlaceholder(name), ComposerAudience.replyPlaceholder(name)] {
                XCTAssertTrue(s.contains("everyone"), s)
            }
        }
    }
}
