import Foundation

/// What a HELD media file on this Apple device actually is — the question `verifyHeldMedia` asks.
///
/// Apple's `MediaStore` holds PLAINTEXT. Every inbound path (relay restore, peer chunks, own-device
/// sync, push scratch) opens the seal first and stores only what came out, and a ref is the sha-256
/// of that plaintext. Android holds the SEAL at rest, which is where `verifyHeldMedia` was ported
/// from — and the port kept Android's test: "does the held file open as a circle seal?". A plaintext
/// JPEG never does, so on Apple EVERY held ref failed the probe: the sweep logged
/// "held-but-unreadable" for photos rendering fine on screen (its own satellite photo included),
/// re-sealed its own media locally, and sent frame-31 re-seal asks that made Android and desktop
/// re-seal and re-upload perfectly good blobs to the relay (e2e gate-10: 29 false asks, 9 own
/// re-seals, 8+ remote re-uploads).
///
/// The Apple question is therefore not "does it open" but "is it the plaintext the ref names":
///   - content-addressed ref whose digest matches → READABLE. No crypto at all.
///   - bytes that open as a circle seal → SEALED AT REST (should not happen; a defensive repair —
///     store the opened plaintext in place, no peer involved).
///   - bytes that parse as a seal envelope but do not open → genuinely unreadable: ask the author,
///     which is the case the sweep exists for.
///   - content-addressed ref whose digest does NOT match → CORRUPT local copy: drop it so the
///     ordinary missing-media sweep re-fetches; a re-seal of these bytes would only spread them.
///   - legacy (non-content-addressed) ref that is not an envelope → READABLE: it is the plaintext a
///     seal opened to, and there is no digest to hold it to.
///
/// Pure and Foundation-only so HavenLogicTests covers it without the FFI. The later checks are
/// closures because each one costs more than the one before (a hash, then a parse, then an open).
enum HeldMediaVerdict: Equatable {
    case readable
    case sealedAtRest
    case sealedUnopenable
    case corrupt
}

enum HeldMediaProbe {
    /// - Parameters:
    ///   - digestMatches: `nil` when the ref is not content-addressed (legacy `img_<uuid>`), else
    ///     whether the held file's sha-256 equals the ref's digest.
    ///   - opensAsSeal: whether the bytes open as a seal for the post's circle (or any circle).
    ///   - parsesAsEnvelope: whether the bytes are a sealed-envelope encoding at all.
    static func classify(digestMatches: Bool?,
                         opensAsSeal: () -> Bool,
                         parsesAsEnvelope: () -> Bool) -> HeldMediaVerdict {
        if digestMatches == true { return .readable }
        if opensAsSeal() { return .sealedAtRest }
        if parsesAsEnvelope() { return .sealedUnopenable }
        return digestMatches == false ? .corrupt : .readable
    }

    /// `media_open_diagnosis` answers "PARSE-FAIL …" for bytes that are not a sealed envelope — the
    /// one stage that needs no keys, which is exactly the plaintext-vs-seal question.
    static func diagnosisSaysEnvelope(_ diagnosis: String) -> Bool {
        !diagnosis.hasPrefix("PARSE-FAIL")
    }
}
