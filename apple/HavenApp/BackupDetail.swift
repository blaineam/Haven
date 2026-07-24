import SwiftUI

/// "Where is this post actually stored?" — tap the cloud indicator to find out.
///
/// The indicator answers yes/no. That was enough right up until the day it said yes and nobody could
/// fetch anything: every blob had reached a relay, the relay was the one running inside the author's
/// own app, and the tick had no way to say so. The only way to learn which relay held what was to
/// read the app's log stream. This is that answer, in the app.
///
/// Grouped by RELAY, not by attachment. The per-attachment shape repeated an identical block (and an
/// identical warning) once per photo — four photos meant four screens of the same sentence, and the
/// one fact that matters, "which relay is missing copies", had to be reassembled by eye. A count per
/// relay says the same thing in one line and still names a partial failure exactly ("3 of 4").
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

    /// Every relay worth a row: the ones this circle publishes to, plus any that already hold a copy.
    /// Naming a circle relay holding NOTHING is the case you most need to see, and a list of
    /// confirmations alone can never show it.
    private var rows: [(dest: String, have: Int)] {
        var dests = Set(relayStore.relays(forCircle: circleId))
        for ref in refs { dests.formUnion(MediaBackupLedger.destinations(for: ref)) }
        return dests.sorted().map { dest in
            (dest, refs.filter { MediaBackupLedger.destinations(for: $0).contains(dest) }.count)
        }
    }

    /// True when nothing but our own in-process relay holds a full set — the state where the post
    /// looks backed up and is in fact unreachable to everyone else.
    private var strandedOnOwnRelay: Bool {
        let remoteComplete = rows.contains { $0.dest != ownRelayHex && $0.have == refs.count }
        let ownHasAny = rows.contains { $0.dest == ownRelayHex && $0.have > 0 }
        return ownHasAny && !remoteComplete
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows, id: \.dest) { row in
                        relayRow(dest: row.dest, have: row.have)
                    }
                    if rows.isEmpty {
                        Label("Not on any relay yet", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                } header: {
                    Text(refs.count == 1 ? "1 attachment" : "\(refs.count) attachments")
                } footer: {
                    if strandedOnOwnRelay {
                        Text("Only this device's own relay has a copy, so nobody else can fetch it yet.")
                            .foregroundStyle(.orange)
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

    @ViewBuilder private func relayRow(dest: String, have: Int) -> some View {
        let isOwn = dest == ownRelayHex
        let all = have == refs.count
        HStack(spacing: 10) {
            Image(systemName: have == 0 ? "circle.dotted"
                            : (isOwn ? "externaldrive.badge.exclamationmark"
                                     : (all ? "checkmark.circle.fill" : "circle.lefthalf.filled")))
                .foregroundStyle(have == 0 ? Color.secondary : (isOwn ? Color.orange : (all ? Color.green : Color.orange)))
            Text(name(for: dest)).font(.callout)
            Spacer()
            Text(statusText(have: have, isOwn: isOwn))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusText(have: Int, isOwn: Bool) -> String {
        if have == 0 { return "No copy yet" }
        let count = have == refs.count ? "All" : "\(have) of \(refs.count)"
        return isOwn ? "\(count) · on this device" : count
    }

    /// A relay's friendly name, falling back to a short hex. An S3 destination is stored by bucket
    /// rather than node hex, so it is already readable.
    private func name(for dest: String) -> String {
        if let e = relayStore.entries[dest] { return e.name }
        if dest.contains("/") || dest.contains(".") { return dest }   // s3-style destination
        return "Relay · \(dest.prefix(8))…"
    }
}
