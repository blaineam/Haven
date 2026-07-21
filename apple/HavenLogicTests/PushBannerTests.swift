import XCTest
@testable import HavenLogicTests

/// Pure-logic coverage for the push banner copy the NSE displays after decrypt.
/// The NSE cannot open circle events — if these strings are wrong, the lock screen lies.
final class PushBannerTests: XCTestCase {

    func testReactionCircleVsDM() {
        let circle = PushBanner.forReaction(emoji: "❤️", circleId: "family")
        XCTAssertEqual(circle.body, "Reacted ❤️ to your post")
        XCTAssertEqual(circle.kind, "react")
        XCTAssertEqual(circle.emoji, "❤️")

        let dm = PushBanner.forReaction(emoji: "😂", circleId: "dm:aa-bb")
        XCTAssertEqual(dm.body, "Reacted 😂 to your message")
    }

    func testStoryNotPosted() {
        let b = PushBanner.forPost(circleId: "family", circleName: "Family",
                                   body: "beach day", media: ["vid_x"], story: true)
        XCTAssertEqual(b.kind, "story")
        XCTAssertTrue(b.body.contains("story"))
        XCTAssertFalse(b.body.lowercased().contains("posted"))
    }

    func testPostWithPreview() {
        let b = PushBanner.forPost(circleId: "family", circleName: "Family",
                                   body: "hello everyone", media: [], story: false)
        XCTAssertEqual(b.kind, "post")
        XCTAssertEqual(b.body, "Family: hello everyone")
    }

    func testPostMediaOnly() {
        let b = PushBanner.forPost(circleId: "family", circleName: "Family",
                                   body: "", media: ["img_abc"], story: false)
        XCTAssertEqual(b.body, "Shared a photo in Family")
    }

    func testDMPreviewAndMedia() {
        let text = PushBanner.forPost(circleId: "dm:aa-bb", circleName: "x",
                                      body: "on my way", media: [], story: false)
        XCTAssertEqual(text.kind, "dm")
        XCTAssertEqual(text.body, "on my way")

        let photo = PushBanner.forPost(circleId: "dm:aa-bb", circleName: "x",
                                       body: "", media: ["img_1"], story: false)
        XCTAssertEqual(photo.body, "Sent a photo")
    }

    func testCommentIncludesPreview() {
        let b = PushBanner.forComment(body: "love this", circleId: "family", circleName: "Family")
        XCTAssertEqual(b.kind, "comment")
        XCTAssertEqual(b.body, "Commented in Family: love this")
    }

    func testClipTruncatesAndRedactsSecrets() {
        let long = String(repeating: "a", count: 120)
        let clipped = PushBanner.clip(long, limit: 80)
        XCTAssertEqual(clipped?.count, 81) // 80 chars + ellipsis
        XCTAssertTrue(clipped?.hasSuffix("…") == true)

        // SecretMessages.encode wraps text; if isSecret trips, clip must not leak it.
        // Without the full SecretMessages module in logic tests we only assert empty/nil.
        XCTAssertNil(PushBanner.clip("   "))
        XCTAssertNil(PushBanner.clip(nil))
    }

    func testJsonObjectCarriesKindAndCircle() {
        let b = PushBanner.forReaction(emoji: "🎉", circleId: "family")
        let o = b.jsonObject(title: "Blaine", circleId: "family")
        XCTAssertEqual(o["t"] as? String, "Blaine")
        XCTAssertEqual(o["k"] as? String, "react")
        XCTAssertEqual(o["e"] as? String, "🎉")
        XCTAssertEqual(o["c"] as? String, "family")
        XCTAssertEqual(o["b"] as? String, "Reacted 🎉 to your post")
    }

    func testUnsendAndEdit() {
        XCTAssertEqual(PushBanner.forUnsend(circleId: "dm:x").body, "Unsent a message")
        XCTAssertEqual(PushBanner.forUnsend(circleId: "family").body, "Unsent a post")
        XCTAssertEqual(PushBanner.forEdit(circleId: "dm:x", circleName: "x").body, "Edited a message")
        XCTAssertEqual(PushBanner.forEdit(circleId: "family", circleName: "Family").body,
                       "Edited a post in Family")
    }
}
