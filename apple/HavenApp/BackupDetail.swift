import SwiftUI

/// "Where is this post actually stored?" — tap the cloud indicator to find out.
///
/// The indicator answers yes/no. That was enough right up until the day it said yes and nobody could
/// fetch anything: every blob had reached a relay, the relay was the one running inside the author's
/// own app, and the tick had no way to say so. The only way to learn which relay held what was to
/// read the app's log stream. This is that answer, in the app, per blob and per relay.
///
/// Deliberately shows the media items SEPARATELY rather than a single summary. A post with three
/// photos where two landed and one didn't is the common shape of a partial failure, and a summary
/// rounds that to "not backed up", which sends you looking for a fault in the wrong place.
/// Identifiable wrapper so a DM row can drive `.sheet(item:)` — an array can't.
struct BackupRefs: Identifiable {
    let refs: [String]
    var id: String { refs.joined(separator: "|") }
}

struct BackupDetailView: View {
    let refs: [String]
    let circleId: String
    @ObservedObject private var relayStore = RelayMailboxStore.shared
    @Environment(\.dismiss) private var dismiss

    private var ownRelayHex: String { RelayHost.shared.serving ? RelayHost.shared.nodeId : "" }

    /// Relays this circle publishes to — so we can name the ones holding NOTHING, which is the case
    /// you most need to see and the one a list of confirmations alone can never show.
    private var circleRelays: [String] { relayStore.relays(forCircle: circleId) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(refs.enumerated()), id: \.offset) { idx, ref in
                    Section {
                        let dests = MediaBackupLedger.destinations(for: ref)
                        let remote = dests.filter { $0 != ownRelayHex }
                        if dests.isEmpty {
                            Label("Not on any relay yet", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary).font(.callout)
                        } else {
                            ForEach(dests.sorted(), id: \.self) { dest in
                                row(dest)
                            }
                        }
                        // Name the relays that should have it and don't. Without this the sheet can
                        // only report good news, and "nothing listed" reads as "nothing to say".
                        ForEach(circleRelays.filter { !dests.contains($0) }.sorted(), id: \.self) { missing in
                            HStack(spacing: 10) {
                                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name(for: missing)).font(.callout)
                                    Text("No copy yet").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !dests.isEmpty && remote.isEmpty {
                            Label("Only this device's own relay holds it — writing there is a local file copy, so nobody else can fetch it yet.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text(refs.count == 1 ? "This attachment" : "Attachment \(idx + 1) of \(refs.count)")
                    } footer: {
                        Text(ref.prefix(24) + "…").font(.system(.caption2, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Where this is stored")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private func row(_ dest: String) -> some View {
        let isOwn = dest == ownRelayHex
        HStack(spacing: 10) {
            Image(systemName: isOwn ? "externaldrive.badge.exclamationmark" : "checkmark.circle.fill")
                .foregroundStyle(isOwn ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(for: dest)).font(.callout)
                Text(isOwn ? "This device's own relay" : "Confirmed copy")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// A relay's friendly name, falling back to a short hex. An S3 destination is stored by bucket
    /// rather than node hex, so it is already readable.
    private func name(for dest: String) -> String {
        if let e = relayStore.entries[dest] { return e.name }
        if dest.contains("/") || dest.contains(".") { return dest }   // s3-style destination
        return "Relay · \(dest.prefix(8))…"
    }
}
