import SwiftUI
import UserNotifications

@main
struct HavenWatchApp: App {
    @StateObject private var client = WatchConnectivityClient.shared

    init() {
        WatchConnectivityClient.shared.start()
        // Don't raise the system permission prompt in the offline screenshot harness.
        if !WatchDemo.isOn {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchConversationsView()
                .environmentObject(client)
                .onAppear { client.refresh() }
        }
    }
}
