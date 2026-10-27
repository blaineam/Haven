import XCTest

/// The ordering behind the CarPlay read-aloud voice: best installed quality for the message's language,
/// never a novelty or Personal voice by itself, an explicit choice always wins.
final class CarPlayVoiceTests: XCTestCase {
    private typealias V = CarPlayVoice.Info

    private let ava = V(id: "ava", name: "Ava", language: "en-US", quality: .premium)
    private let samantha = V(id: "sam", name: "Samantha", language: "en-US", quality: .standard)
    private let daniel = V(id: "dan", name: "Daniel", language: "en-GB", quality: .enhanced)
    private let kate = V(id: "kate", name: "Kate", language: "en-GB", quality: .standard)
    private let monica = V(id: "mon", name: "Mónica", language: "es-ES", quality: .enhanced)
    private let zarvox = V(id: "zar", name: "Zarvox", language: "en-US", quality: .premium, isNovelty: true)
    private let mine = V(id: "pv", name: "My Voice", language: "en-US", quality: .premium, isPersonal: true)

    func testPremiumBeatsEnhancedBeatsStandardForTheLanguage() {
        let all = [samantha, daniel, ava, kate]
        XCTAssertEqual(CarPlayVoice.pick(from: all, preferredId: "", languages: ["en-US"])?.id, "ava")
        XCTAssertEqual(CarPlayVoice.pick(from: [samantha, daniel, kate], preferredId: "", languages: ["en-US"])?.id, "dan",
                       "enhanced (en-GB) beats the default-quality en-US voice: the same language, better quality")
        XCTAssertEqual(CarPlayVoice.pick(from: [samantha, kate], preferredId: "", languages: ["en-GB"])?.id, "kate",
                       "equal quality: the exact region wins")
    }

    func testNoveltyAndPersonalVoicesAreNeverPickedAutomatically() {
        XCTAssertEqual(CarPlayVoice.pick(from: [zarvox, mine, samantha], preferredId: "", languages: ["en-US"])?.id, "sam")
        XCTAssertNil(CarPlayVoice.pick(from: [zarvox, mine], preferredId: "", languages: ["en-US"]))
    }

    func testAnExplicitChoiceAlwaysWinsEvenAPersonalVoiceOrAnotherLanguage() {
        XCTAssertEqual(CarPlayVoice.pick(from: [ava, mine, monica], preferredId: "pv", languages: ["en-US"])?.id, "pv")
        XCTAssertEqual(CarPlayVoice.pick(from: [ava, mine, monica], preferredId: "mon", languages: ["en-US"])?.id, "mon")
        XCTAssertEqual(CarPlayVoice.pick(from: [ava, samantha], preferredId: "gone", languages: ["en-US"])?.id, "ava",
                       "a voice that was uninstalled falls back to matching the system")
    }

    func testTheMessageLanguageComesBeforeTheSystemLanguage() {
        let all = [ava, monica]
        XCTAssertEqual(CarPlayVoice.pick(from: all, preferredId: "", languages: CarPlayVoice.languageOrder(detected: "es", system: ["en-US"]))?.id, "mon")
        XCTAssertEqual(CarPlayVoice.pick(from: [ava], preferredId: "", languages: CarPlayVoice.languageOrder(detected: "es", system: ["en-US"]))?.id, "ava",
                       "no Spanish voice installed: the system language")
        XCTAssertEqual(CarPlayVoice.languageOrder(detected: nil, system: ["en-US", "es-ES"]), ["en-US", "es-ES"])
        XCTAssertEqual(CarPlayVoice.languageOrder(detected: "en-US", system: ["en-US", "es-ES"]), ["en-US", "es-ES"])
    }

    func testLanguageBaseAndDetection() {
        XCTAssertEqual(CarPlayVoice.base("en-US"), "en")
        XCTAssertEqual(CarPlayVoice.base("pt_BR"), "pt")
        XCTAssertEqual(CarPlayVoice.base("ja"), "ja")
        XCTAssertNil(CarPlayVoice.detectLanguage(of: "ok"), "too short to trust")
        XCTAssertEqual(CarPlayVoice.detectLanguage(of: "Hey, I am running about ten minutes late, see you soon at the restaurant"), "en")
        XCTAssertEqual(CarPlayVoice.detectLanguage(of: "Hola, voy a llegar con diez minutos de retraso, nos vemos pronto en el restaurante"), "es")
    }

    func testNothingInstalledReturnsNilSoTheSynthesizerKeepsItsDefault() {
        XCTAssertNil(CarPlayVoice.pick(from: [], preferredId: "", languages: ["en-US"]))
    }
}
