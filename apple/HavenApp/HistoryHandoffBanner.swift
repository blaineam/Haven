import SwiftUI

/// Progress of the history handoff (HistoryHandoff.swift), over the feed on BOTH devices: the new one
/// sees its history arriving, the old one sees that it is sending — which is when keeping Haven open
/// (or the phone on a charger) makes it go faster. Hidden when there is nothing to report.
struct HistoryHandoffBanner: View {
    @ObservedObject private var handoff = HistoryHandoff.shared

    var body: some View {
        if handoff.status.phase != .idle {
            HistoryHandoffProgress(status: handoff.status, onDismiss: { handoff.dismissReceived() })
                .padding(14)
                .background(HavenTheme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
                .transition(.opacity)
        }
    }
}

/// The shared progress row — the feed banner and Settings ▸ Devices both show it.
struct HistoryHandoffProgress: View {
    let status: HistoryHandoff.Status
    var onDismiss: (() -> Void)? = nil

    private var icon: String {
        switch status.phase {
        case .received: return "checkmark.circle.fill"
        case .sending: return "arrow.up.circle"
        default: return "clock.arrow.2.circlepath"
        }
    }

    private var title: LocalizedStringKey {
        switch status.phase {
        case .waitingForSource: return "Waiting for your other device"
        case .receiving: return "Bringing over your history"
        case .received: return "Your history is here"
        case .sending: return "Sending history to your new device"
        case .idle: return ""
        }
    }

    private var detail: LocalizedStringKey {
        switch status.phase {
        case .waitingForSource:
            return "Open Haven on your other device, or leave it on a charger — it starts on its next wake."
        case .receiving where status.mediaTotal > 0:
            return "\(min(status.done, max(status.total, status.done))) of \(max(status.total, status.done)) posts and messages · \(min(status.mediaDone, status.mediaTotal)) of \(status.mediaTotal) photos and videos"
        case .receiving, .sending:
            if status.total > 0 {
                return "\(min(status.done, status.total)) of \(status.total) posts and messages"
            }
            return "\(status.done) posts and messages so far"
        case .received:
            return "Everything from your other device has arrived."
        case .idle:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).opacity(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if status.phase == .received, let onDismiss {
                    Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Dismiss"))
                }
            }
            switch status.phase {
            case .receiving, .sending:
                if let f = status.fraction {
                    ProgressView(value: f).tint(.white)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(.white)
                }
            case .waitingForSource:
                ProgressView().progressViewStyle(.linear).tint(.white)
            default:
                EmptyView()
            }
        }
    }
}
