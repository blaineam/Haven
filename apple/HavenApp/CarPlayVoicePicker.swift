#if os(iOS)
import AVFoundation
import SwiftUI

/// Settings > Car and Siri > Read-aloud voice. "Match system" (the default) or one exact installed voice.
/// Lists the voices for the user's preferred languages; a tap selects AND plays a short sample, so the
/// choice is made by ear.
struct CarPlayVoicePickerView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var voices: [CarPlayVoice.Info] = []
    private let synth = AVSpeechSynthesizer()

    /// Summary for the Settings row.
    static func summary(_ id: String) -> String {
        guard id != CarPlayVoice.matchSystem else { return String(localized: "Match system", table: "Messaging") }
        return CarPlayVoice.installed().first { $0.id == id }?.name ?? String(localized: "Match system", table: "Messaging")
    }

    var body: some View {
        List {
            Section {
                row(title: String(localized: "Match system", table: "Messaging"), id: CarPlayVoice.matchSystem, sample: nil)
            } footer: {
                Text("Uses your accessibility speech settings when VoiceOver or Speak Screen is on, otherwise the best voice you have installed for the message's language. iOS doesn't let apps read the voice chosen in Settings > Accessibility > Spoken Content, so pick one below to use that exact voice.", tableName: "Messaging")
            }
            Section {
                ForEach(voices, id: \.id) { v in
                    row(title: CarPlayVoice.label(v), id: v.id, sample: v)
                }
            } header: {
                Text("Voices", tableName: "Messaging")
            } footer: {
                Text("Download Enhanced or Premium voices in Settings > Accessibility > Spoken Content > Voices; they sound much more natural.", tableName: "Messaging")
            }
        }
        .navigationTitle(Text("Read-aloud voice", tableName: "Messaging"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { voices = Self.listed(selected: settings.carPlayVoiceId) }
        .onDisappear { synth.stopSpeaking(at: .immediate) }
    }

    private func row(title: String, id: String, sample: CarPlayVoice.Info?) -> some View {
        Button {
            settings.carPlayVoiceId = id
            speakSample(sample)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if settings.carPlayVoiceId == id { Image(systemName: "checkmark").foregroundStyle(HavenTheme.pink) }
            }
        }
    }

    private func speakSample(_ v: CarPlayVoice.Info?) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: String(localized: "Hi, this is how Haven will read your messages.", table: "Messaging"))
        if let v { u.voice = AVSpeechSynthesisVoice(identifier: v.id) } else { CarPlayVoice.apply(to: u, preferredId: CarPlayVoice.matchSystem) }
        synth.speak(u)
    }

    /// Voices for the languages the user reads (plus the one currently selected, wherever it is from),
    /// best quality first.
    static func listed(selected: String) -> [CarPlayVoice.Info] {
        let codes = Set(Locale.preferredLanguages.map(CarPlayVoice.base))
        return CarPlayVoice.installed()
            .filter { !$0.isNovelty && (codes.contains(CarPlayVoice.base($0.language)) || $0.id == selected) }
            .sorted { a, b in
                if CarPlayVoice.base(a.language) != CarPlayVoice.base(b.language) { return a.language < b.language }
                if a.quality != b.quality { return a.quality > b.quality }
                return a.name < b.name
            }
    }
}
#endif
