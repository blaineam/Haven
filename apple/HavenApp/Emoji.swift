import SwiftUI

/// Remembers which emoji you react with most, so your favorites are offered first.
@MainActor
final class EmojiStore: ObservableObject {
    static let shared = EmojiStore()
    @Published private(set) var counts: [String: Int]
    private let key = "haven.emojiCounts"

    private init() {
        counts = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    /// Factory-reset this store — clear recent-emoji counts (in-memory + persisted).
    func wipe() { counts = [:]; UserDefaults.standard.removeObject(forKey: key) }

    func record(_ e: String) {
        counts[e, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }

    /// Most-used first, topped up with sensible defaults so it's never empty.
    func frequent(_ n: Int = 6) -> [String] {
        var result = counts.sorted { $0.value > $1.value }.map(\.key)
        for d in ["❤️", "😂", "🎉", "👍", "🔥", "🥹", "😮", "😢", "🙏", "💯"] where !result.contains(d) {
            result.append(d)
        }
        return Array(result.prefix(n))
    }
}

/// A broad set of emoji to react with — practically "any" — grouped for browsing.
enum EmojiCatalog {
    static let groups: [(String, [String])] = [
        ("Smileys", "😀 😃 😄 😁 😆 🥹 😅 😂 🤣 🥲 ☺️ 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🥸 🤩 🥳 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🫡 🤭 🫢 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕".split(separator: " ").map(String.init)),
        ("Gestures", "👍 👎 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 🫵 👋 🤚 🖐 ✋ 🖖 👏 🙌 🫶 👐 🤲 🙏 ✍️ 💪 🦾 🤝 ❤️‍🔥 💯 🔥 ⭐️ 🌟 ✨ ⚡️ 💥 🎉 🎊".split(separator: " ").map(String.init)),
        ("Hearts", "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❤️‍🩹 💕 💞 💓 💗 💖 💘 💝 💟 ♥️".split(separator: " ").map(String.init)),
        ("Animals", "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐻‍❄️ 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🐤 🦆 🦉 🦄 🐝 🦋 🐢 🐙 🦕 🦖 🐬 🐳 🐠 🐡".split(separator: " ").map(String.init)),
        ("Food", "🍎 🍊 🍋 🍓 🫐 🍇 🍉 🍌 🍒 🍑 🥭 🍍 🥥 🥑 🍞 🧀 🥓 🍔 🍟 🍕 🌮 🌯 🍣 🍱 🍜 🍝 🍦 🍩 🍪 🎂 🍰 🧁 🍫 🍬 🍭 ☕️ 🍵 🍺 🍷 🥂 🍾".split(separator: " ").map(String.init)),
        ("Travel", "🚗 🏎 🚲 ✈️ 🚀 🛸 ⛵️ 🏖 🏔 🌋 🗺 🧭 🏕 🌅 🌄 🌠 🎆 🎇 🌈 ☀️ 🌙 ⭐️ 🌍".split(separator: " ").map(String.init)),
        ("Symbols", "💬 💭 🗯 ✅ ❌ ❓ ❗️ 💤 🆒 🆗 🔔 🎵 🎶 🏆 🥇 🎁 🎈 🎀 💎 👑 🔮 💡 ⏳".split(separator: " ").map(String.init)),
    ]
}

/// Reaction picker: your most-used first, then a full browseable set.
struct ReactionPicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = EmojiStore.shared

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        #if os(macOS)
        // The Mac sheet scaffold instead of a NavigationStack toolbar — its Done button landed on a
        // gray system band above the grid. The scaffold's glass close circle (and Esc) dismisses.
        HavenMacSheet("React") { grid }
        .havenPausesPostAudio()
        #else
        NavigationStack {
            ScrollView { grid.padding() }
            .navigationTitle("React")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmTrailing) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }
        .presentationDetents([.medium, .large])
        .havenPausesPostAudio()
        #endif
    }

    private var grid: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
            section("Frequently used", store.frequent(16))
            ForEach(EmojiCatalog.groups, id: \.0) { (name, emojis) in
                section(name, emojis)
            }
        }
    }

    private func section(_ title: String, _ emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, e in
                    Button {
                        store.record(e)
                        onPick(e)
                        dismiss()
                    } label: { Text(e).font(.system(size: 30)) }
                        // The glyph IS the button — without a style macOS bezels every emoji.
                        .buttonStyle(PressableStyle())
                }
            }
        }
    }
}
