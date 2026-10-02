import XCTest

/// Apple holds media PLAINTEXT at rest. The held-media probe must judge a held file as plaintext —
/// it used to try to OPEN it as a seal, which fails for every plaintext file, so every held photo
/// (the device's own included) was reported "held-but-unreadable" and re-sealed by its author.
final class HeldMediaProbeTests: XCTestCase {
    func testMatchingDigestIsReadableWithoutAnyCrypto() {
        var crypto = 0
        let v = HeldMediaProbe.classify(digestMatches: true,
                                        opensAsSeal: { crypto += 1; return false },
                                        parsesAsEnvelope: { crypto += 1; return false })
        XCTAssertEqual(v, .readable, "own plaintext under its content address IS readable — the e2e regression")
        XCTAssertEqual(crypto, 0, "a matching digest needs no open attempt")
    }

    func testLegacyPlaintextIsReadable() {
        // `img_<uuid>`: no digest to check, bytes are not a seal → the plaintext a seal opened to.
        XCTAssertEqual(HeldMediaProbe.classify(digestMatches: nil, opensAsSeal: { false },
                                               parsesAsEnvelope: { false }), .readable)
    }

    func testSealedAtRestIsRepairedLocallyNotAskedFor() {
        XCTAssertEqual(HeldMediaProbe.classify(digestMatches: nil, opensAsSeal: { true },
                                               parsesAsEnvelope: { true }), .sealedAtRest)
        XCTAssertEqual(HeldMediaProbe.classify(digestMatches: false, opensAsSeal: { true },
                                               parsesAsEnvelope: { true }), .sealedAtRest)
    }

    func testOnlyAnUnopenableSealAsksTheAuthor() {
        XCTAssertEqual(HeldMediaProbe.classify(digestMatches: nil, opensAsSeal: { false },
                                               parsesAsEnvelope: { true }), .sealedUnopenable)
        XCTAssertEqual(HeldMediaProbe.classify(digestMatches: false, opensAsSeal: { false },
                                               parsesAsEnvelope: { true }), .sealedUnopenable)
    }

    func testWrongPlaintextIsCorruptNotResealed() {
        XCTAssertEqual(HeldMediaProbe.classify(digestMatches: false, opensAsSeal: { false },
                                               parsesAsEnvelope: { false }), .corrupt)
    }

    func testDiagnosisParseFailMeansPlaintext() {
        XCTAssertFalse(HeldMediaProbe.diagnosisSaysEnvelope("PARSE-FAIL bytes=1234 head=\"\\u{FFFD}\\u{FFFD}\""))
        XCTAssertTrue(HeldMediaProbe.diagnosisSaysEnvelope("sender=0123456789abcdef kind=member recipients=3 me_listed=false"))
        XCTAssertTrue(HeldMediaProbe.diagnosisSaysEnvelope("NO-SUCH-CIRCLE circle=x sender=0123456789abcdef"))
    }
}
