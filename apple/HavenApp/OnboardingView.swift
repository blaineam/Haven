import SwiftUI

/// A warm, plain-language first run: welcome → pick your name & avatar → how it
/// works → into the app.
struct OnboardingView: View {
    @ObservedObject var profile: ProfileStore
    var accountStore: AccountStore
    @State private var step = 0
    @State private var name = ""
    @State private var emoji = "🌿"
    @State private var pickedImage: PlatformImage?
    @State private var showPhotoPicker = false
    @State private var showRestore = false
    @State private var showLink = false

    var body: some View {
        ZStack {
            HavenBackground()
            VStack {
                content
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
                    .id(step)
                Spacer()
                controls
            }
            .padding(24)
            // A single readable column no matter the window: macOS windows are arbitrarily wide,
            // and unconstrained steps smeared the emoji grid and pill buttons across the full
            // 1440pt+ width. The column centers itself in whatever space the window offers.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showRestore) {
            NavigationStack {
                RestoreIdentityView(accountStore: accountStore) {
                    withAnimation(HavenTheme.smooth) { profile.onboarded = true }
                }
            }
            .macSheetFrame()   // gradient to the sheet's edges + a usable size on macOS
        }
        .sheet(isPresented: $showLink) {
            NavigationStack {
                // Seed-drop S4: the seedless "Link a device" path (auto-detects a legacy seed code too).
                EnrollScanView(accountStore: accountStore) {
                    withAnimation(HavenTheme.smooth) { profile.onboarded = true }
                }
            }
            .macSheetFrame()
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: pickName
        case 2: howItWorks
        default: terms
        }
    }

    /// Final step (App Review 1.2): agreeing to the zero-tolerance terms IS the door into Haven —
    /// the button below says "I agree" and there is no other way through.
    private var terms: some View {
        ScrollView { TermsContent() }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Circle()
                .fill(HavenTheme.brand)
                .frame(width: 112, height: 112)
                .overlay(ConstellationMark().frame(width: 66, height: 66))
                .shadow(color: HavenTheme.pink.opacity(0.4), radius: 20, y: 10)
            BrandText(text: "Welcome to Haven")
            Text("A private little place for the people you love.\nNo ads. No tracking. No strangers. Just your people.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // THREE paths, each named for what it DOES. Previously this screen offered "Link a
            // device" and "Restore my identity from a code" as small secondary links, with starting
            // fresh as the unlabelled default — so the one destructive-ish choice (moving an account)
            // and the one additive choice (adding a device) read as the same kind of thing, and
            // neither said what happens to the device you already have. Each option now states its
            // consequence in the subtitle, because that is the part people get wrong.
            VStack(spacing: 12) {
                onboardingChoice(
                    title: "I'm new to Haven",
                    subtitle: "Create a brand-new identity on this device.",
                    icon: "sparkles",
                    action: advance)
                onboardingChoice(
                    title: "Add this as another of my devices",
                    subtitle: "Use my existing Haven account here too. My other device stays signed in, and both stay in sync.",
                    icon: "laptopcomputer.and.iphone",
                    action: { showLink = true })
                onboardingChoice(
                    title: "Move my account to this device",
                    subtitle: "Bring my identity over from another device using a transfer code. Use this when replacing a device, not when adding one.",
                    icon: "arrow.right.circle",
                    action: { showRestore = true })
            }
            .padding(.horizontal, 8)
            Spacer()
        }
    }

    /// One onboarding path: what it's called, and — the part that actually prevents mistakes — what
    /// it does to the device you already have.
    @ViewBuilder
    private func onboardingChoice(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(HavenTheme.pink)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)   // the card IS the button — no macOS bezel behind it
    }

    private var pickName: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("What should your\npeople call you?")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            HavenAvatar(image: pickedImage, emoji: emoji, size: 96)
                .shadow(color: HavenTheme.pink.opacity(0.3), radius: 12, y: 6)
            Button { showPhotoPicker = true } label: {
                Label(pickedImage == nil ? "Add a photo" : "Change photo", systemImage: "photo")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered).tint(HavenTheme.pink)
            .sheet(isPresented: $showPhotoPicker) { SingleImagePicker { pickedImage = $0 } }

            // ONE surface: plain field style + a single glass capsule. (The default macOS field
            // style drew its own bezel + focus ring INSIDE the capsule — doubled chrome.)
            TextField("Your name or nickname", text: $name)
                .font(.title3)
                .multilineTextAlignment(.center)
                .havenPillField()
                .padding(.horizontal, 20)

            Text(pickedImage == nil ? "Or pick an emoji" : "Emoji (shown if you remove your photo)")
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(ProfileStore.avatarChoices, id: \.self) { e in
                    Text(e).font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .background(emoji == e ? AnyShapeStyle(HavenTheme.brandHorizontal.opacity(0.25)) : AnyShapeStyle(Color(.secondarySystemFill)), in: Circle())
                        .overlay(Circle().strokeBorder(emoji == e ? HavenTheme.pink : .clear, lineWidth: 2))
                        .onTapGesture { withAnimation(HavenTheme.snappy) { emoji = e } }
                }
            }
            Spacer()
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("How Haven works")
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .center)
            point("🔒", "Private by design", "Everything you share is locked so only the people in your circle can ever see it.")
            point("🚫", "No ads, no tracking", "There's no algorithm and no company watching. Haven doesn't collect anything about you.")
            point("🤝", "You choose your circle", "Nothing happens with strangers. You invite the people you want, one at a time.")
            Spacer()
        }
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(icon).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            // Step 0 now offers the three paths as explicit choices, so a generic "Get started"
            // underneath them would be a fourth, ambiguous door onto the same screen.
            if step != 0 {
                Button(action: advance) {
                    Text(step == 3 ? "I agree — enter Haven" : "Continue")
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(step == 1 && name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(step == 1 && name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }

            HStack(spacing: 7) {
                ForEach(0..<4) { i in
                    Capsule()
                        .fill(i == step ? AnyShapeStyle(HavenTheme.brandHorizontal) : AnyShapeStyle(Color(.tertiaryLabel)))
                        .frame(width: i == step ? 22 : 7, height: 7)
                        .animation(HavenTheme.bouncy, value: step)
                }
            }
        }
    }

    private func advance() {
        if step == 1 {
            profile.displayName = name.trimmingCharacters(in: .whitespaces)
            profile.emoji = emoji
            if let pickedImage { profile.setAvatar(pickedImage) }
        }
        if step >= 3 {
            TermsStore.shared.accept()   // "I agree" — the only door in (App Review 1.2)
            withAnimation(HavenTheme.smooth) { profile.onboarded = true }
        } else {
            withAnimation(HavenTheme.smooth) { step += 1 }
        }
    }
}
