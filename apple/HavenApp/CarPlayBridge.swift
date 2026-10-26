#if os(iOS)
import Combine
import Foundation

/// Keeps the car and Siri in step with the app, from inside the app process:
///
///   * **publishes** the privacy-filtered `MessagingSnapshot` into the App Group whenever the feed,
///     read marks, lock set or privacy settings change (debounced - a burst of inbound events is one
///     write), which is all `HavenIntents` can see;
///   * **drains** the `SiriRequest`s the Intents extension queued (send a message, mark read) and
///     rings the extension's doorbell back so Siri only says "sent" once that is true.
///
/// CarPlay itself (`CarPlaySceneDelegate`) reads the stores directly; this is the cross-process half.
@MainActor
final class CarPlayBridge {
    static let shared = CarPlayBridge()
    private init() {}

    private var cancellables = Set<AnyCancellable>()
    private var requestToken: SiriRequestSignal.Token?
    private var started = false
    private var draining = false

    func start() {
        guard !started else { return }
        started = true
        Publishers.MergeMany([
            FeedStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            DMReadStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            CircleSettingsStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SettingsStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .seconds(1.0), scheduler: RunLoop.main)
        .sink { [weak self] in self?.publish() }
        .store(in: &cancellables)
        // The doorbell fires on an arbitrary thread; hop to the main actor to drain.
        requestToken = SiriRequestSignal.observe(SiriRequestSignal.request) { [weak self] in
            Task { @MainActor in self?.drain() }
        }
        publish()
        drain()
    }

    /// The "CarPlay and Siri messages" switch flipped.
    func settingChanged() {
        if SettingsStore.shared.carPlayAndSiri { publish() } else { wipe() }
    }

    /// Account reset / switch off: nothing may outlive the account in the shared container.
    func wipe() {
        MessagingSnapshotStore.clear()
        SiriRequestQueue.clear()
    }

    func publish() {
        guard SettingsStore.shared.carPlayAndSiri else { wipe(); return }
        guard FeedStore.shared.isConfigured else { return }
        let snapshot = MessagingSnapshot.build(threads: MessagingThreads.current(),
                                               detail: MessagingThreads.privacyDetail,
                                               now: UInt64(Date().timeIntervalSince1970 * 1000))
        MessagingSnapshotStore.write(snapshot)
    }

    /// Apply whatever Siri queued. Safe to call any time and from several places (launch, foreground,
    /// engine ready, doorbell): a request that can't be applied yet (engine not up) stays queued.
    func drain() {
        guard !draining, SettingsStore.shared.carPlayAndSiri, FeedStore.shared.isConfigured else { return }
        draining = true
        defer { draining = false }
        var handled = false
        for (file, request) in SiriRequestQueue.pending() {
            let locked = CircleSettingsStore.shared.biometricRequired(request.conversationId)
            switch request.kind {
            case .markRead:
                if !locked {
                    let newest = FeedStore.shared.messages(in: request.conversationId).map(\.createdAt).max() ?? 0
                    DMReadStore.shared.markRead(request.conversationId, newestMessageAt: newest)
                }
                SiriRequestQueue.complete(file)
                handled = true
            case .send:
                // A locked conversation can't be written to without Face ID (the extension refuses
                // too; this is the belt to its braces) - drop the request rather than retry forever.
                if locked || FeedStore.shared.dmCircles.allSatisfy({ $0.id != request.conversationId }) {
                    SiriRequestQueue.complete(file)
                    handled = true
                } else if FeedStore.shared.sendMessage(to: request.conversationId, request.text, media: [], music: nil) {
                    SiriRequestQueue.complete(file)
                    handled = true
                }
            }
        }
        if handled { SiriRequestSignal.post(SiriRequestSignal.ack) }
    }
}
#endif
