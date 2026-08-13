import SwiftUI
import UniformTypeIdentifiers

/// The guided "bring your Instagram posts over" flow.
///
/// Shaped by the fact that the user cannot get their posts out on demand: they request an export,
/// wait hours or days, and come back. So this WALKS — one step on screen at a time, each with a
/// single action — rather than presenting the whole procedure as a page of prose. The settings
/// Instagram asks for are shown as a checklist of value rows, not sentences, because that is how
/// they will be read: glanced at while looking at Instagram's form on another screen.
struct InstagramImportView: View {
    let circleId: String
    let circleName: String

    @StateObject private var importer = InstagramImporter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var picking = false
    @State private var includeStories = false

    private let exportURL = URL(string: "https://accountscenter.instagram.com/info_and_permissions/dyi/")!

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                Group {
                    switch importer.phase {
                    case .idle, .reading:      walkthrough
                    case .previewing:          preview
                    case .importing:           running
                    case .finished:            finished
                    case .failed(let m):       failure(m)
                    }
                }
            }
            .navigationTitle("Import from Instagram")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { importer.reset(); dismiss() }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { importer.read(url) }
            }
        }
    }

    // MARK: - Walkthrough (3 steps, one at a time)

    private var walkthrough: some View {
        VStack(spacing: 0) {
            dots
            TabView(selection: $step) {
                stepOne.tag(0)
                stepTwo.tag(1)
                stepThree.tag(2)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == step ? HavenTheme.pink : Color.secondary.opacity(0.25))
                    .frame(width: i == step ? 22 : 7, height: 7)
                    .animation(.snappy, value: step)
            }
        }
        .padding(.top, 10)
    }

    private var stepOne: some View {
        stepBody(icon: "square.and.arrow.down.on.square", title: "Ask Instagram for your file",
                 blurb: "They build it and email you. It's the only way out — there's no direct connection.") {
            Link(destination: exportURL) {
                Label("Open Instagram", systemImage: "arrow.up.forward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HavenTheme.pink)
            .controlSize(.large)

            Text("Pick these on their page")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

            VStack(spacing: 0) {
                settingRow("Format", "JSON", critical: true)
                Divider().padding(.leading, 14)
                settingRow("Media quality", "High")
                Divider().padding(.leading, 14)
                settingRow("Date range", "All time")
                Divider().padding(.leading, 14)
                settingRow("Include", "Posts · Stories · Reels")
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Label("JSON is the one you can't get wrong — their HTML export has no data in it, and it can't be converted.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(.top, 2)

            nextButton("I've requested it")
        }
    }

    private var stepTwo: some View {
        stepBody(icon: "clock", title: "Wait for their email",
                 blurb: "Usually a few hours. Up to a few days for a big account — it's entirely on Instagram's side.") {
            VStack(alignment: .leading, spacing: 12) {
                bullet("You can close Haven. This picks up where you left off.")
                bullet("Their download link expires after a few days, so grab it when it lands.")
                bullet("Leave the file zipped — Haven reads it as-is.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            nextButton("I have the file")
        }
    }

    private var stepThree: some View {
        stepBody(icon: "doc.zipper", title: "Choose your archive",
                 blurb: "Read on this device. Nothing is uploaded anywhere, and nothing publishes until you say so.") {
            Button {
                picking = true
            } label: {
                Group {
                    if importer.phase == .reading {
                        HStack(spacing: 8) { ProgressView(); Text("Reading…") }
                    } else {
                        Label("Choose file", systemImage: "folder")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HavenTheme.pink)
            .controlSize(.large)
            .disabled(importer.phase == .reading)

            Text("It's named instagram-yourname-….zip")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Shared step chrome: icon, title, one line of context, then the step's own content.
    private func stepBody<C: View>(icon: String, title: String, blurb: String,
                                   @ViewBuilder content: () -> C) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(HavenTheme.pink)
                    .padding(.top, 24)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(blurb)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                content()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
    }

    private func settingRow(_ label: String, _ value: String, critical: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(critical ? .body.bold() : .body)
                .foregroundStyle(critical ? .orange : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(HavenTheme.pink)
            Text(text).font(.subheadline)
        }
    }

    private func nextButton(_ title: String) -> some View {
        Button {
            withAnimation(.snappy) { step += 1 }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.top, 6)
    }

    // MARK: - Preview — nothing publishes until this is confirmed

    @ViewBuilder private var preview: some View {
        if let s = importer.summary {
            Form {
                Section {
                    countRow("Posts", s.count(.post), "square.grid.2x2")
                    countRow("Reels", s.count(.reel), "play.rectangle")
                    countRow("Photos & videos", s.mediaCount, "photo.on.rectangle")
                    HStack {
                        Label("Size", systemImage: "internaldrive")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(s.totalBytes), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    if let a = s.earliest, let b = s.latest {
                        HStack {
                            Label("Spans", systemImage: "calendar")
                            Spacer()
                            Text("\(date(a)) – \(date(b))").foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("In your archive") }

                if !s.missing.isEmpty {
                    Section {
                        Label("\(s.missing.count) files are missing from the archive",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } footer: {
                        Text("The download probably didn't finish. Those posts are skipped.")
                    }
                }

                if s.count(.story) > 0 {
                    Section {
                        Toggle("Include \(s.count(.story)) stories", isOn: $includeStories)
                            .tint(HavenTheme.pink)
                    } footer: {
                        Text("Instagram archives **every** story automatically, so these are all of them — not just your Highlights, which the export doesn't mark. Included, they're saved to your profile only, never posted to \(circleName).")
                    }
                }

                Section {
                    Button {
                        importer.run(into: circleId, includeStories: includeStories)
                    } label: {
                        Label("Import \(importCount(s))", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HavenTheme.pink)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Posts land in \(circleName) with their original dates. Nobody is notified, and their phones only download a photo if they open it.")
                }

                Section {
                    Button("Choose a different file") { importer.reset() }
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func countRow(_ label: String, _ n: Int, _ icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text("\(n)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func importCount(_ s: InstagramArchive.Summary) -> String {
        let n = includeStories ? s.items.count : s.items.count - s.count(.story)
        return "\(n) item\(n == 1 ? "" : "s")"
    }

    private func date(_ ms: UInt64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            .formatted(.dateTime.year().month(.abbreviated))
    }

    // MARK: - Running / done / failed

    @ViewBuilder private var running: some View {
        if case .importing(let done, let total) = importer.phase {
            VStack(spacing: 16) {
                Text("\(done)")
                    .font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(total) imported").foregroundStyle(.secondary)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(HavenTheme.pink)
                    .padding(.horizontal, 46)
                Text("Each photo and video is optimized and encrypted here as it goes.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button("Stop", role: .destructive) { importer.cancel() }
                    .padding(.top, 4)
            }
            .animation(.snappy, value: done)
        }
    }

    @ViewBuilder private var finished: some View {
        if case .finished(let imported, let skipped) = importer.phase {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(.green)
                Text("\(imported) imported").font(.title2.bold())
                Text("They're in \(circleName), in date order.")
                    .foregroundStyle(.secondary)
                if skipped > 0 {
                    Text("\(skipped) skipped — their media was missing from the archive.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 34)
                }
                Button("Done") { importer.reset(); dismiss() }
                    .buttonStyle(.borderedProminent).tint(HavenTheme.pink)
                    .controlSize(.large).padding(.top, 6)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46)).foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("Try another file") { importer.reset() }
                .buttonStyle(.borderedProminent).tint(HavenTheme.pink)
                .controlSize(.large)
        }
    }
}
