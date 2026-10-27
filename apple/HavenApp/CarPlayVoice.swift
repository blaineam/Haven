#if os(iOS)
import AVFoundation
import Foundation
import NaturalLanguage
import UIKit

/// Which voice Haven reads messages in, in the car.
///
/// iOS exposes no API that returns the voice chosen in Settings > Accessibility > Spoken Content, and a
/// bare `AVSpeechSynthesisVoice(language:)` returns the DEFAULT-quality voice for that language - the
/// robotic one, even when the user has downloaded an Enhanced/Premium one. So "Match system" means:
///   1. when VoiceOver / Speak Screen / Speak Selection is on, let the system apply the user's assistive
///      speech settings (`prefersAssistiveTechnologySettings`) - the one supported way to follow them;
///   2. otherwise the best INSTALLED voice (premium > enhanced > default) for the language of the message,
///      falling back to the system language. Novelty voices (Bubbles, Zarvox...) and Personal Voices are
///      never picked automatically.
/// A specific voice chosen in Haven Settings always wins, Personal Voice included (it is listed only
/// once the user has authorized Haven for Personal Voice in iOS Settings).
enum CarPlayVoice {
    /// The stored preference meaning "no explicit choice".
    static let matchSystem = ""

    enum Quality: Int, Comparable {
        case standard = 0, enhanced = 1, premium = 2
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    /// The facts the picker needs, detached from AVFoundation so the ordering is unit-tested.
    struct Info: Equatable {
        var id: String
        var name: String
        /// BCP-47, e.g. "en-US".
        var language: String
        var quality: Quality
        var isNovelty = false
        var isPersonal = false
    }

    /// The voice to use for `languages` (best first: the message's language, then the system's), or nil
    /// when nothing suitable is installed (the synthesizer then falls back to its own default).
    static func pick(from voices: [Info], preferredId: String, languages: [String]) -> Info? {
        if preferredId != matchSystem, let chosen = voices.first(where: { $0.id == preferredId }) { return chosen }
        let usable = voices.filter { !$0.isNovelty && !$0.isPersonal }
        for language in languages {
            let code = base(language)
            let sameLanguage = usable.filter { base($0.language) == code }
            guard !sameLanguage.isEmpty else { continue }
            return sameLanguage.sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let exactA = a.language.caseInsensitiveCompare(language) == .orderedSame
                let exactB = b.language.caseInsensitiveCompare(language) == .orderedSame
                if exactA != exactB { return exactA }
                if a.name != b.name { return a.name < b.name }
                return a.id < b.id
            }.first
        }
        return nil
    }

    /// Languages to try for one utterance: its own detected language (when we are confident), then the
    /// user's preferred languages in order.
    static func languageOrder(detected: String?, system: [String]) -> [String] {
        var out: [String] = []
        for l in [detected].compactMap({ $0 }) + system where !out.contains(l) { out.append(l) }
        return out
    }

    /// "en-US" / "en_US" / "en" -> "en".
    static func base(_ language: String) -> String {
        String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(language)).lowercased()
    }

    /// The text's language when the recognizer is confident, nil for short or ambiguous text.
    static func detectLanguage(of text: String) -> String? {
        guard text.count >= 12 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let top = r.languageHypotheses(withMaximum: 1).first, top.value >= 0.8 else { return nil }
        return top.key.rawValue
    }

    // MARK: AVFoundation bridge

    static func info(_ v: AVSpeechSynthesisVoice) -> Info {
        let quality: Quality
        switch v.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        var novelty = false, personal = false
        if #available(iOS 17.0, *) {
            novelty = v.voiceTraits.contains(.isNoveltyVoice)
            personal = v.voiceTraits.contains(.isPersonalVoice)
        }
        return Info(id: v.identifier, name: v.name, language: v.language, quality: quality, isNovelty: novelty, isPersonal: personal)
    }

    /// Installed voices (Personal Voices only once the user has authorized Haven for them).
    static func installed() -> [Info] {
        var voices = AVSpeechSynthesisVoice.speechVoices()
        if #available(iOS 17.0, *), AVSpeechSynthesizer.personalVoiceAuthorizationStatus != .authorized {
            voices = voices.filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        }
        return voices.map(info)
    }

    /// Whether the system's assistive speech settings are in play (so `prefersAssistiveTechnologySettings`
    /// would follow something the user actually configured).
    static var assistiveSpeechActive: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSpeakScreenEnabled || UIAccessibility.isSpeakSelectionEnabled
    }

    /// Configure one utterance's voice.
    static func apply(to utterance: AVSpeechUtterance, preferredId: String) {
        if preferredId == matchSystem, assistiveSpeechActive {
            utterance.prefersAssistiveTechnologySettings = true
            return
        }
        let languages = languageOrder(detected: detectLanguage(of: utterance.speechString), system: Locale.preferredLanguages)
        if let info = pick(from: installed(), preferredId: preferredId, languages: languages),
           let voice = AVSpeechSynthesisVoice(identifier: info.id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: languages.first ?? Locale.preferredLanguages.first)
        }
    }

    /// Human label for the picker: "Ava (Premium)".
    static func label(_ v: Info) -> String {
        switch v.quality {
        case .premium: return "\(v.name) (\(String(localized: "Premium", table: "Messaging")))"
        case .enhanced: return "\(v.name) (\(String(localized: "Enhanced", table: "Messaging")))"
        case .standard: return v.name
        }
    }
}
#endif
