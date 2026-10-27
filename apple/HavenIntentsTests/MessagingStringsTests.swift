import XCTest

/// The spoken/shown phrases ("Sent a photo", ...) ship in the six languages, in the bundle the car and
/// Siri actually read them from (the test bundle compiles the same `Messaging.xcstrings`).
final class MessagingStringsTests: XCTestCase {
    private let languages = ["de", "es", "it", "ja", "ko", "pt-BR"]
    private let keys = ["Locked", "New activity", "Message unsent", "Sent you a message", "You sent a message", "Sent a photo",
                        "Sent a video", "Sent a voice note", "Sent a file", "Shared a song", "Sent an attachment",
                        "Sent the group a photo", "Sent the group a voice note", "Messaged the group", "Messages", "Calls",
                        "No conversations yet", "Open Haven on your iPhone", "Turned off", "No one to call yet", "Haven audio call",
                        "Read new messages", "Read to me", "Haven reads them aloud", "Reply", "Say your message to Siri",
                        "Call on Haven", "Recent messages", "No messages yet", "You",
                        "Unlock this conversation in Haven on your iPhone.", "Nothing to read right now.",
                        "Message text is hidden by your notification privacy setting.",
                        "One new message from %@.", "%lld new messages from %@.", "Recent messages from %@.",
                        "No messages from %@ yet.", "%1$@ says: %2$@"]

    private func table(_ lang: String) -> [String: String]? {
        let bundle = Bundle(for: Self.self)
        guard let path = bundle.path(forResource: "Messaging", ofType: "strings", inDirectory: nil, forLocalization: lang) else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    func testEveryPhraseIsTranslatedInEveryShippedLanguage() {
        for lang in languages {
            guard let t = table(lang) else { return XCTFail("no Messaging table for \(lang)") }
            for k in keys {
                let v = t[k] ?? ""
                XCTAssertFalse(v.isEmpty, "\(lang): \(k)")
                XCTAssertNotEqual(v, k, "\(lang): \(k) is still English")
            }
        }
    }

    func testThePhotoLineIsClearInJapaneseAndGerman() {
        XCTAssertEqual(table("ja")?["Sent a photo"], "写真を送信しました")
        XCTAssertEqual(table("de")?["Sent a photo"], "Hat ein Foto gesendet")
    }

    func testBuiltInPhrasesMatchTheCatalogKeys() {
        // The Swift accessors are the catalog's keys (the English fallback), so a rename cannot orphan a translation.
        XCTAssertEqual(MessagingText.photo, "Sent a photo")
        XCTAssertEqual(MessagingText.locked, "Locked")
        XCTAssertEqual(MessagingText.groupVoice, "Sent the group a voice note")
    }
}
