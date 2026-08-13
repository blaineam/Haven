import SwiftUI
import UniformTypeIdentifiers

/// The guided "bring your Instagram posts over" flow.
///
/// The shape of this screen is dictated by the shape of the task: the user cannot get their own
/// posts out of Instagram on demand. They have to request an export, wait hours or days for it to
/// be built, and come back. So this is a walkthrough that survives being left and returned to,
/// not a single form — and the one irreversible mistake (choosing HTML instead of JSON) is called
/// out where it is made, not in the error afterwards.
struct InstagramImportView: View {
    let circleId: String
    let circleName: String

    @StateObject private var importer = InstagramImporter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    /// Off by default on purpose — see `InstagramImporter.run(into:includeStories:)`.
    @State private var includeStories = false

    /// Button label reflects what will ACTUALLY be imported, so the count never contradicts the
    /// stories toggle sitting directly above it.
    private func importCount(_ s: InstagramArchive.Summary) -> String {
        let n = includeStories ? s.items.count : s.items.count - s.count(.story)
        return "\(n) item\(n == 1 ? "" : "s")"
    }

    /// Accounts Center → Your information and permissions → Download your information.
    private let exportURL = URL(string: "https://accountscenter.instagram.com/info_and_permissions/dyi/")!

    var body: some View {
        NavigationStack {
            Group {
                switch importer.phase {
                case .idle, .reading:      walkthrough
                case .previewing:          preview
                case .importing:           progress
                case .finished:            done
                case .failed(let message): failure(message)
                }
            }
            .navigationTitle("Import from Instagram")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { importer.reset(); dismiss() }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { importer.read(url) }
            }
        }
    }

    // MARK: - Step-by-step

    private var walkthrough: some View {
        Form {
            Section {
                Text("Haven can bring your Instagram posts, stories and reels across — with their captions, their photos and videos, and their original dates, so your history lands in \(circleName) in the right order.")
                Text("Instagram has no way to hand these over directly. You ask them for an export, they build it and email you, and then you come back here and give Haven the file.")
                    .foregroundStyle(.secondary)
            }

            Section("Step 1 — Ask Instagram for your export") {
                Link(destination: exportURL) {
                    Label("Open Instagram's download page", systemImage: "arrow.up.forward.app")
                }
                step(1, "Choose your account, then Some of your information.")
                step(2, "Tick Posts, Stories and Reels.")
                step(3, "Choose Download to device.")
                VStack(alignment: .leading, spacing: 6) {
                    Label("Set Format to JSON", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                    Text("This is the one mistake you cannot undo. Instagram's HTML export is a website for people to read — it holds no data Haven can import, and it cannot be converted. Getting it wrong means requesting the whole export again and waiting all over.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                step(4, "Set Media quality to High — this is the actual quality of what you import.")
                step(5, "Set Date range to All time, then submit.")
            }

            Section("Step 2 — Wait for their email") {
                Text("Usually a few hours; up to a few days for a large account. It is entirely on Instagram's side. You can close Haven — this page will be here when you come back.")
                Text("Their download link expires after a few days, so grab it when it arrives.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Step 3 — Come back with the file") {
                Text("Download the .zip and leave it zipped — Haven reads the archive directly, on this device. Nothing is uploaded anywhere.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    picking = true
                } label: {
                    if case .reading = importer.phase {
                        HStack { ProgressView(); Text("Reading archive…").padding(.leading, 6) }
                    } else {
                        Label("Choose archive…", systemImage: "doc.zipper")
                    }
                }
                .disabled(importer.phase == .reading)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.monospacedDigit().bold())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
        }
    }

    // MARK: - Preview (nothing is published until this is confirmed)

    @ViewBuilder private var preview: some View {
        if let s = importer.summary {
            Form {
                Section("Found in your archive") {
                    row("Posts", "\(s.count(.post))")
                    row("Reels", "\(s.count(.reel))")
                    row("Stories", "\(s.count(.story))")
                    row("Photos and videos", "\(s.mediaCount)")
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(s.totalBytes), countStyle: .file))
                    if let a = s.earliest, let b = s.latest { row("Dates", "\(date(a)) – \(date(b))") }
                }

                if !s.missing.isEmpty {
                    Section {
                        Label("\(s.missing.count) files are referenced but missing from the archive", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("That usually means the download didn't finish. Those posts will be skipped. You can import anyway, or download the archive again and start over.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if s.count(.story) > 0 {
                    Section {
                        Toggle("Also bring in \(s.count(.story)) stories", isOn: $includeStories)
                            .tint(HavenTheme.pink)
                    } header: { Text("Stories") }
                    footer: {
                        Text("Instagram archives **every** story you post, automatically — so this is all of them, not the ones you added to a Highlight. Your export doesn't record which were highlighted, so Haven can't tell them apart. Left off, they're skipped entirely. Turned on, they're saved as kept stories on your profile — yours to look back on, never published to \(circleName).")
                    }
                }

                Section {
                    Text("Posts and reels publish to \(circleName) with their original dates, so they slot into history rather than arriving as new posts today.")
                    Label("Nobody is notified", systemImage: "bell.slash")
                    Text("An import this size would otherwise fire a notification for every post. Members see them in the feed in their proper place, with no banners, and the full photo or video downloads for them only if they actually open it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        importer.run(into: circleId, includeStories: includeStories)
                    } label: {
                        Label("Import \(importCount(s))", systemImage: "square.and.arrow.down")
                    }
                    Button("Choose a different file") { importer.reset() }
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private func date(_ ms: UInt64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return d.formatted(.dateTime.year().month(.abbreviated))
    }

    // MARK: - Running

    @ViewBuilder private var progress: some View {
        if case .importing(let done, let total) = importer.phase {
            VStack(spacing: 18) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .padding(.horizontal, 40)
                Text("Importing \(done) of \(total)")
                    .font(.headline).monospacedDigit()
                Text("Each photo and video is optimized and encrypted on this device as it goes, so this takes a while for a large archive.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Stop") { importer.cancel() }
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var done: some View {
        if case .finished(let imported, let skipped) = importer.phase {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52)).foregroundStyle(.green)
                Text("Imported \(imported) posts").font(.title3.bold())
                if skipped > 0 {
                    Text("\(skipped) were skipped because their media was missing from the archive.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                Text("They're in \(circleName), in date order.")
                    .foregroundStyle(.secondary)
                Button("Done") { importer.reset(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46)).foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Try another file") { importer.reset() }
                .buttonStyle(.borderedProminent)
        }
    }
}
