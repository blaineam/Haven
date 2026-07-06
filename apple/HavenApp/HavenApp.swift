import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if !os(macOS)
/// Receives the APNs device token + remote-notification wakes (SwiftUI App needs a delegate
/// for these callbacks).
final class HavenAppDelegate: NSObject, UIApplicationDelegate {
    /// The story camera locks this to `.portrait` so capture/compose never rotate; reset to
    /// `.all` elsewhere. Driven by `OrientationLock`.
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Start P2P networking immediately on launch — including a background VoIP wake — so an
        // incoming call answered from the CallKit screen can connect without the user first
        // opening the app. (Previously configure() only ran when the SwiftUI view appeared.)
        if let seed = AccountStore.storedSeed() {
            Task { @MainActor in FeedStore.shared.configure(seed: seed) }
        }
        // PushKit REQUIRES its registry to exist by the end of didFinishLaunching: a VoIP push
        // that launches the killed app in the BACKGROUND never renders a view, so the old
        // `.onAppear`-only startVoip() meant no registry existed, the queued call push had
        // nowhere to land, and the phone simply didn't ring unless Haven had been foregrounded
        // since boot. Synchronous on purpose (a queued Task can land after launch returns);
        // didFinishLaunching runs on the main thread, so main-actor isolation holds. The
        // onAppear call remains — startVoip is idempotent.
        MainActor.assumeIsolated { PushManager.shared.startVoip() }
        #if os(iOS)
        // Bring up the Apple Watch companion bridge (thin client over WCSession). No-op if
        // there's no paired Watch; it just vends recent threads + accepts quick replies.
        WatchSessionManager.shared.start()
        #endif
        #if targetEnvironment(macCatalyst)
        // Let the Mac app run as an invisible background relay (hide the dock icon when the window
        // is closed while serving as a relay; restore it on relaunch).
        MacAgent.installSceneObservers()
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.registered(deviceToken: deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // A silent push (e.g. multi-device self-sync) carries the sealed event inline but doesn't
        // run the NSE — stash it here so the app ingests it on the next sync.
        if let ev = userInfo["ev"] as? String, let env = Data(base64Encoded: ev) {
            SharedInbox.append(env: env)
        }
        // The storage-owner cron nudge → re-mint fresh pre-signed URLs in the background.
        if userInfo["remint"] != nil {
            Task { @MainActor in PresignStore.shared.remintAllOwned() }
        }
        Task { @MainActor in FeedStore.shared.forceSync(); completionHandler(.newData) }
    }
}
#else
/// Native macOS delegate — same APNs token + remote-notification handling via AppKit. No
/// orientation lock (irrelevant on Mac); no background-fetch completion handler on macOS.
final class HavenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let seed = AccountStore.storedSeed() {
            Task { @MainActor in FeedStore.shared.configure(seed: seed) }
        }
        // Resume serving as a circle relay if the user left it on (mirrors iOS startIfEnabled).
        Task { @MainActor in RelayHost.shared.startIfEnabled() }
    }

    /// When the relay is ON, closing the window must NOT quit — Haven keeps forwarding INVISIBLY (no
    /// dock icon, no menu bar); re-launching brings the window back. With the relay off it behaves like
    /// a normal Mac app and quits when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if RelayHost.shared.enabled { MacAgent.goInvisible(); return false }
        return true
    }

    /// Re-launching (or clicking the dock pin) while running invisibly: become a normal app again and
    /// open the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MacAgent.goVisible()
        return true   // let AppKit/SwiftUI restore or re-create the main window
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.registered(deviceToken: deviceToken) }
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if let ev = userInfo["ev"] as? String, let env = Data(base64Encoded: ev) {
            SharedInbox.append(env: env)
        }
        if userInfo["remint"] != nil {
            Task { @MainActor in PresignStore.shared.remintAllOwned() }
        }
        // macOS has no Notification Service Extension, so the relay sends a silent push carrying
        // the sealed banner `e`; decrypt it IN-PROCESS (same seed-only FFI the iOS NSE uses) and
        // post a local notification. The relay never sees plaintext. Locked circles are redacted.
        let isCall = userInfo["call"] != nil   // /call fallback (no PushKit on macOS)
        if let e = userInfo["e"] as? String, let sealed = Data(base64Encoded: e),
           let seed = SharedSeed.read(),
           let plain = openSealedWithSeed(seed: seed, sealed: sealed),
           let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] {
            let locked = (obj["c"] as? String).map { SharedLockedCircles.read().contains($0) } ?? false
            let title = locked ? "Haven" : ((obj["t"] as? String) ?? "Haven")
            let fallbackBody = isCall ? "📞 Incoming call — open Haven to answer" : "New message"
            let body = locked ? "New activity in a locked circle" : ((obj["b"] as? String) ?? fallbackBody)
            Task { @MainActor in NotificationManager.shared.notify(title: title, body: body, dedupeKey: e) }
        } else if isCall {
            // Call doorbell we couldn't decrypt (it's sealed+signed for the PushKit opener) —
            // still surface SOMETHING rather than staying silent.
            Task { @MainActor in
                NotificationManager.shared.notify(title: "Haven", body: "📞 Incoming call — open Haven to answer",
                                                  dedupeKey: "call:\(Date().timeIntervalSince1970)")
            }
        }
        Task { @MainActor in FeedStore.shared.forceSync() }
    }
}
#endif

@main
struct HavenApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(HavenAppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(HavenAppDelegate.self) private var appDelegate
    #endif

    init() {
        // Register the background-refresh task at launch (required before didFinishLaunching).
        NotificationManager.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            #if DEBUG
            if ProcessInfo.processInfo.environment["HAVEN_CAPTION_HARNESS"] == "1" {
                CaptionHarness()
            } else if ProcessInfo.processInfo.environment["HAVEN_SCRIM_HARNESS"] == "1" {
                ScrimHarness()
            } else if ProcessInfo.processInfo.environment["HAVEN_OG_HARNESS"] == "1" {
                OGHarness()
            } else {
                mainRoot
            }
            #else
            mainRoot
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AudioCoordinator.shared.appBecameActive()   // allow playback again now we're foreground
                // Back to the foreground — if we're sitting on a locked circle, prompt at once.
                let cid = FeedStore.shared.activeCircleId
                if BiometricGate.shared.isLocked(cid) { BiometricGate.shared.unlock(cid) }
            case .background:
                // Only true backgrounding pauses + blocks audio. (.inactive is too twitchy on macOS — it
                // fires whenever the window loses key focus, which was stopping music in normal use. macOS
                // app-switch is handled by NSApplication.didResignActive in AudioCoordinator instead.)
                AudioCoordinator.shared.pauseForBackground()
                NotificationManager.shared.scheduleRefresh()
                BiometricGate.shared.relockAll()   // re-lock biometric circles on the way out
                Task { await BackgroundUploader.shared.flush() }   // finish pending mailbox uploads
            default: break
            }
        }

        // No menu-bar item: the relay's controls (run-as-relay, start-at-login) live in-app under
        // Settings, and when the window is closed while relaying the app runs fully invisibly (the
        // delegate drops the dock icon; re-launching restores the window).
    }

    @ViewBuilder private var mainRoot: some View {
        RootView()
            .onAppear {
                #if os(macOS)
                // Screenshot harness: force a 1440×900pt window (Retina 2× = 2880×1800 — the exact
                // App Store Mac canvas) so every capture is identically sized regardless of any
                // saved window frame from a previous launch.
                if DemoEnv.isDemo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let w = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
                            w.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)
                        }
                    }
                }
                #endif
                #if os(iOS)
                // Seed the post-audio autoplay default from the hardware silent switch on open:
                // silenced → start muted (no autoplay until the user taps unmute); ringer on →
                // autoplay until they mute. The user's in-app tap overrides for the session.
                SilentSwitch.detectSilenced { silenced in
                    if SettingsStore.shared.silent != silenced { SettingsStore.shared.silent = silenced }
                }
                #endif
                // Screenshot/offline harness: never raise the system notification prompt or
                // touch the push relay — it would photobomb the captures and needs the network.
                guard ProcessInfo.processInfo.environment["HAVEN_NO_NET"] != "1" else { return }
                NotificationManager.shared.requestAuthorization()
                PushManager.shared.start()   // register for real push via the relay
                PushManager.shared.startVoip()   // PushKit VoIP so calls ring from killed/locked
            }
    }
}

/// An incoming invite link, wrapped so it can drive an item-based sheet.
struct PendingInvite: Identifiable {
    let id = UUID()
    let link: String
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var accountStore = AccountStore()
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @ObservedObject private var feedStore = FeedStore.shared
    @ObservedObject private var connections = ConnectionsStore.shared
    @ObservedObject private var linkPresenter = LinkPresenter.shared
    @ObservedObject private var deepLinks = DeepLinkRouter.shared
    #if os(iOS)
    @ObservedObject private var shareRouter = ShareRouter.shared   // share-sheet hand-off (iOS only)
    #endif
    @ObservedObject private var call = CallManager.shared          // drives the minimized "Call" tab

    @State private var tab = ProcessInfo.processInfo.environment["HAVEN_TAB"] ?? "circle"
    @State private var showConnect = false
    // Persisted so the "add your first friend" sheet shows once, not on every cold launch
    // (it was firing whenever you have no contacts yet).
    @AppStorage("haven.onboardInviteShown") private var didPrompt = false
    /// An incoming invite link. Driving the sheet from this *item* (not a separate bool)
    /// guarantees the ConnectView gets the link on the first open — `.sheet(isPresented:)`
    /// with a separate state captured a stale (nil) link, which is why it took two taps.
    @State private var pendingInvite: PendingInvite?

    /// Blur when the app isn't frontmost and the active circle is biometric-locked.
    private var shouldPrivacyBlur: Bool {
        scenePhase != .active && CircleSettingsStore.shared.biometricRequired(feedStore.activeCircleId)
    }

    var body: some View {
        Group {
            if !profile.onboarded {
                OnboardingView(profile: profile, accountStore: accountStore)
                    .transition(.opacity)
            } else {
                main
            }
        }
        .animation(HavenTheme.smooth, value: profile.onboarded)
        // Privacy: while a biometric-locked circle is active, blur the app whenever it isn't
        // frontmost — this is what the app-switcher snapshot captures, so locked content never
        // leaks there. The lock screen takes over on return.
        .overlay {
            if shouldPrivacyBlur {
                PrivacyBlurView()
                    .transition(.opacity).ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: shouldPrivacyBlur)
        .onOpenURL { url in
            #if os(iOS)
            // The Share Extension handed off items via the App Group inbox — import + route them.
            if url.scheme == "haven", url.host == "share" {
                Task { await ShareRouter.shared.ingest() }
                return
            }
            #endif
            // Profile/post deep links (haven://u/… , haven://p/…) route in-app.
            if DeepLinkRouter.shared.handle(url, tab: &tab) { return }
            // Otherwise it's an invite link — "<id>.<verify>" in the URL fragment
            // (haven://invite#… or https://…/#…), so the web link loads on any static host.
            let s = url.absoluteString
            guard let frag = url.fragment, frag.contains(".") else { return }
            tab = "you"
            pendingInvite = PendingInvite(link: s)   // item-driven sheet → correct on first open
        }
        // Shared links open inside Haven (in-app browser) from anywhere — posts, comments, bios.
        .sheet(item: $linkPresenter.presented) { presented in
            InAppBrowserView(url: presented.url)
        }
        // Profile / specific-post deep links open as a sheet.
        .sheet(item: $deepLinks.route) { route in
            switch route {
            case .profile(let nodeHex):
                NavigationStack {
                    UserProfileView(authorHex: nodeHex,
                                    name: ContactsStore.shared.name(forNodePrefix: nodeHex) ?? "Profile")
                }
            case .post(let circleId, let postId):
                PostLinkView(circleId: circleId, postId: postId)
            }
        }
    }

    private var main: some View {
        TabView(selection: $tab) {
            FeedView(account: accountStore.account, seed: accountStore.account.secretSeed(), friendName: "Friend")
                .id(accountStore.account.nodeIdHex())
                .tag("circle")
                .tabItem { Label("Circle", systemImage: "sparkles") }
                // Pending circle-approval prompts surface on the Circle tab (that's where the
                // banner lives), alongside unseen posts — NOT on You.
                .badge(feedStore.unseenCircle + connections.pending.count)
            NavigationStack { MessagesView(account: accountStore.account) }
                .tag("messages")
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(feedStore.unseenMessages)
            YouView(
                account: accountStore.account,
                accountStore: accountStore,
                profile: profile,
                contacts: contacts,
                onReset: { accountStore.reset() }
            )
            .tag("you")
            .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
            // While a call is minimized, a green "Call" tab appears on the right — tap it to reopen
            // the call screen. (Selecting it just restores the call and bounces back to the prior tab.)
            if call.minimized && (call.inCall || call.connecting) {
                Color.clear
                    .tag("call")
                    .tabItem { Label("Call", systemImage: "phone.fill") }
            }
        }
        .tint(HavenTheme.pink)
        .onChange(of: tab) { old, t in
            if t == "call" {
                CallManager.shared.minimized = false   // reopen the full call screen…
                tab = old                               // …and don't actually leave the current tab
                return
            }
            if t == "circle" {
                feedStore.markCircleSeen()
                AudioCoordinator.shared.ensureMusicPlaying()    // back on the feed → resume the centered post's song
            } else {
                AudioCoordinator.shared.pauseForBackground()    // left the feed → silence post music + video
            }
            if t == "messages" { feedStore.markMessagesSeen() }
        }
        .overlay {
            CallOverlay()
                .animation(HavenTheme.smooth, value: CallManager.shared.connecting)
                .animation(HavenTheme.smooth, value: CallManager.shared.inCall)
                .animation(HavenTheme.smooth, value: CallManager.shared.ringing)
                .animation(HavenTheme.smooth, value: CallManager.shared.minimized)
        }
        // Manual "add a friend" (onboarding / the + button) — no incoming link.
        .sheet(isPresented: $showConnect) {
            ConnectView(account: accountStore.account, contacts: contacts, incomingLink: nil).macSheetFrame()
        }
        // Invite deep link — the item carries the link, so ConnectView gets it immediately.
        .sheet(item: $pendingInvite) { invite in
            ConnectView(account: accountStore.account, contacts: contacts, incomingLink: invite.link).macSheetFrame()
        }
        // Share-sheet hand-off: pick DM / post / story for items shared from another app.
        #if os(iOS)
        .sheet(isPresented: $shareRouter.present) { ShareRouteView() }
        #endif
        .onChange(of: scenePhase) { _, phase in
            // If we booted before the keychain was readable, swap the real identity back in
            // once we're active + unlocked (never silently keeps a throwaway identity).
            if phase == .active {
                accountStore.reloadIfTemporary()
                #if os(iOS)
                Task { await ShareRouter.shared.ingest() }   // foreground fallback if open-URL didn't fire
                #endif
            }
        }
        .onAppear {
            accountStore.reloadIfTemporary()
            FeedStore.shared.configure(seed: accountStore.account.secretSeed())
            // Screenshot harness: bring up the group-call overlay over the seeded feed.
            if DemoEnv.scene == .call { DemoSeeder.startDemoCall() }
            if ProcessInfo.processInfo.environment["HAVEN_OPEN_CONNECT"] == "1" {
                showConnect = true
                return
            }
            // Gently walk first-time users into adding their first person.
            guard !didPrompt,
                  contacts.contacts.isEmpty,
                  ProcessInfo.processInfo.environment["HAVEN_SKIP_ONBOARDING"] != "1"
            else { return }
            didPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showConnect = true }
        }
    }
}
