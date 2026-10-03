import Foundation
#if os(iOS)
import CallKit
#endif

/// Live feed for `HeavyWorkPolicy`: Haven call state, any OTHER call on the device (CXCallObserver —
/// cellular, FaceTime, other VoIP apps; no permission needed), thermal state, and Low Power Mode.
///
/// `current` is a lock-free snapshot readable from any thread, the same shape as
/// `NearbyTransport.handoffBoost`: the media serve loops run on background queues and check it per
/// chunk so a transfer that started before a call stops when the call starts (the requester resumes
/// it later with frame 33, from exactly where it stopped).
///
/// When the gate LIFTS, the deferred work is kicked immediately rather than waiting for its timers:
/// missing-media prefetch, and the relay upload queue.
@MainActor
final class HeavyWorkMonitor: NSObject {
    static let shared = HeavyWorkMonitor()

    /// The most recent sample. Written only on the main actor; read anywhere (a stale read by one
    /// chunk is harmless — the next chunk sees the new value).
    nonisolated(unsafe) static private(set) var current = HeavyWorkPolicy.Conditions()

    #if os(iOS)
    private let callObserver = CXCallObserver()
    #endif
    private var started = false

    /// Begin observing. Idempotent; call once the app is up.
    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HeavyWorkMonitor.shared.refresh() }
        }
        nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in HeavyWorkMonitor.shared.refresh() }
        }
        #if os(iOS)
        callObserver.setDelegate(self, queue: .main)
        #endif
        refresh()
    }

    private func sample() -> HeavyWorkPolicy.Conditions {
        var c = HeavyWorkPolicy.Conditions()
        c.havenCall = CallManager.shared.callInProgress
        #if os(iOS)
        c.systemCall = callObserver.calls.contains { !$0.hasEnded }
        #endif
        c.heat = HeavyWorkPolicy.Heat(ProcessInfo.processInfo.thermalState)
        c.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if DEBUG
        c.forced = qaForcedReason
        #endif
        return c
    }

    #if DEBUG
    /// `heavy_work_override` qa op: force `suspendHeavyIO` with this reason ("" lifts it).
    private var qaForcedReason = ""
    func qaOverride(suspend: Bool, reason: String) {
        qaForcedReason = suspend ? (reason.isEmpty ? "qa" : reason) : ""
        refresh()
    }
    #endif

    /// Re-sample now. Cheap; call on any event that might change the answer (call start/end).
    func refresh() {
        let old = Self.current
        let new = sample()
        guard new != old else { return }
        Self.current = new
        if new.suspendHeavyIO != old.suspendHeavyIO || new.peerServingAllowedForFriends != old.peerServingAllowedForFriends {
            HavenLog.net("heavy-work gate: suspend=\(new.suspendHeavyIO) friendServe=\(new.peerServingAllowedForFriends) [\(new.reason)]")
        }
        // A lift (or a partial lift, e.g. serious → fair) → resume what was parked.
        // Cooling from .fair to .nominal lifts background mirroring (`backgroundMirrorAllowed`).
        let lifted = (old.suspendHeavyIO && !new.suspendHeavyIO) || (old.pauseEverything && !new.pauseEverything)
            || (!old.backgroundMirrorAllowed && new.backgroundMirrorAllowed)
        if lifted { FeedStore.shared.heavyWorkLifted() }
    }
}

#if os(iOS)
extension HeavyWorkMonitor: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in HeavyWorkMonitor.shared.refresh() }
    }
}
#endif

