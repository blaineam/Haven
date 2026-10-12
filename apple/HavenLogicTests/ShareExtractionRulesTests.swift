import XCTest
import UniformTypeIdentifiers

/// What the Share Extension decides about each attachment. A misclassification turns a real document
/// into a `file:///` text nobody can open, or a snippet into a .txt attachment.
final class ShareExtractionRulesTests: XCTestCase {
    private typealias R = ShareExtractionRules

    /// A provider that conforms to every type in `types` (and their supertypes, as real providers do).
    private func conforms(_ types: [UTType]) -> (UTType) -> Bool {
        { wanted in types.contains { $0.conforms(to: wanted) } }
    }

    func testMoviesAreVideoEvenWhenTheyAlsoVendAURL() {
        XCTAssertEqual(R.classify(conforms: conforms([.quickTimeMovie])), .video)
        XCTAssertEqual(R.classify(conforms: conforms([.mpeg4Movie, .url])), .video)
    }

    func testImagesAreImages() {
        XCTAssertEqual(R.classify(conforms: conforms([.jpeg])), .image)
        XCTAssertEqual(R.classify(conforms: conforms([.png, .url])), .image, "concrete media wins over the URL fallback")
        XCTAssertEqual(R.classify(conforms: conforms([.heic])), .image)
    }

    func testFileURLBeatsURLSoADocumentStaysAnAttachment() {
        // A document shared from Files conforms to both `public.file-url` and `public.url`.
        let kind = R.classify(conforms: conforms([.fileURL]))
        XCTAssertEqual(kind, .document(typeIdentifier: UTType.fileURL.identifier))
    }

    func testPlainDataIsADocumentButTextAndLinksAreNot() {
        XCTAssertEqual(R.classify(conforms: conforms([.pdf])), .document(typeIdentifier: UTType.data.identifier))
        XCTAssertEqual(R.classify(conforms: conforms([.zip])), .document(typeIdentifier: UTType.data.identifier))
        XCTAssertEqual(R.classify(conforms: conforms([.url])), .url, "a web link belongs in the message body")
        XCTAssertEqual(R.classify(conforms: conforms([.plainText])), .text,
                       "plain text also conforms to public.data but stays a message body")
        XCTAssertEqual(R.classify(conforms: conforms([.utf8PlainText])), .text)
    }

    func testUnknownThingsAreUnsupported() {
        XCTAssertEqual(R.classify(conforms: { _ in false }), .unsupported)
        XCTAssertNil(R.documentTypeIdentifier(conforms: { _ in false }))
    }

    func testDocumentTypeIdentifierRules() {
        XCTAssertEqual(R.documentTypeIdentifier(conforms: conforms([.fileURL])), "public.file-url")
        XCTAssertEqual(R.documentTypeIdentifier(conforms: conforms([.data])), "public.data")
        XCTAssertNil(R.documentTypeIdentifier(conforms: conforms([.url])))
        XCTAssertNil(R.documentTypeIdentifier(conforms: conforms([.text])))
    }

    // MARK: Names

    func testStagedNames() {
        XCTAssertEqual(R.videoName(index: 0, pathExtension: "mp4"), "vid-0.mp4")
        XCTAssertEqual(R.videoName(index: 3, pathExtension: ""), "vid-3.mov", "an extensionless clip is staged as .mov")
        XCTAssertEqual(R.imageName(index: 2), "img-2.dat")
        XCTAssertEqual(R.documentName(index: 1, pathExtension: "pdf"), "doc-1.pdf")
        XCTAssertEqual(R.documentName(index: 4, pathExtension: ""), "doc-4")
    }

    func testIndicesKeepMixedSharesFromColliding() {
        let names = [R.videoName(index: 0, pathExtension: "mov"), R.imageName(index: 1), R.documentName(index: 2, pathExtension: "pdf")]
        XCTAssertEqual(Set(names).count, 3)
    }

    func testOriginalDocumentNamePrefersTheSenders() {
        XCTAssertEqual(R.originalDocumentName(suggested: "Q3 Report.pdf", fileName: "abc-123.pdf"), "Q3 Report.pdf")
        XCTAssertEqual(R.originalDocumentName(suggested: nil, fileName: "abc-123.pdf"), "abc-123.pdf")
    }

    // MARK: Previews

    func testPreviewCap() {
        XCTAssertTrue(R.canAddPreview(currentCount: 0))
        XCTAssertTrue(R.canAddPreview(currentCount: 9))
        XCTAssertFalse(R.canAddPreview(currentCount: 10), "the extension has a tight memory budget")
    }

    func testPreviewScaleFitsTheLongEdgeAndNeverEnlarges() {
        XCTAssertEqual(R.previewScale(width: 4000, height: 2000), 0.05, accuracy: 0.0001)
        XCTAssertEqual(R.previewScale(width: 1000, height: 4000), 0.05, accuracy: 0.0001)
        XCTAssertEqual(R.previewScale(width: 100, height: 50), 1, "a small image is not blown up")
        XCTAssertEqual(R.previewScale(width: 0, height: 0), 1, "degenerate sizes do not divide by zero")
        XCTAssertEqual(R.previewScale(width: 200, height: 200), 1)
    }

    // MARK: Donated conversation

    func testConversationIdFromIntent() {
        XCTAssertEqual(R.conversationId(fromIntent: "dm:aa-bb"), "dm:aa-bb")
        XCTAssertNil(R.conversationId(fromIntent: "default"), "a foreign identifier is never trusted")
        XCTAssertNil(R.conversationId(fromIntent: ""))
        XCTAssertNil(R.conversationId(fromIntent: nil))
    }
}
