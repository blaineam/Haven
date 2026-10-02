import Foundation

// MARK: - Why this exists
//
// Since iOS 13, PushKit TERMINATES the app (`-[PKPushRegistry _terminateAppIfThereAreUnhandledVoIPPushes]`
// → objc exception → abort) when a VoIP push is delivered and the app does not report a new
// incoming call to CallKit before the push's completion handler runs. There is no "ignore this
// push" option: every VoIP push must produce a `reportNewIncomingCall`, even one that should not
// ring. The standard pattern for those is "report, then end it immediately".
//
// The old handler only reported on the happy path. `reportIncomingFromPush` returned early when a
// call was already active (the sealed iroh invite usually beats the push, so the push for the SAME
// call found us already ringing), and `reportIncoming` skipped CallKit entirely wherever the in-app
// overlay rings instead (the simulator) — both left the push unreported, and PushKit killed the app.
//
// This file is the pure decision: given what the push said and what the call machine is doing,
// should we ring, re-report the call CallKit already knows about, or report-and-end a placeholder?
// Foundation only, so HavenLogicTests covers it on the host. CallManager executes the decision.

/// The caller fields a VoIP push carries once its sealed blob is opened.
struct VoipPushCaller: Equatable {
    var name: String
    var peerHex: String

    /// Parse the opened (authenticated) payload: `{"t": <caller name>, "h": <caller account hex>}`.
    /// `nil` for anything that isn't a JSON object of strings.
    static func parse(opened: Data) -> VoipPushCaller? {
        guard let obj = (try? JSONSerialization.jsonObject(with: opened)) as? [String: Any] else { return nil }
        let name = (obj["t"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Someone"
        let hex = (obj["h"] as? String) ?? ""
        return VoipPushCaller(name: name, peerHex: hex)
    }
}

/// What the call machine looks like when the push lands.
struct VoipPushCallState: Equatable {
    var active = false
    /// Participants of the active call (account hexes).
    var roster: Set<String> = []
    var myHex = ""
    var myDeviceHex = ""
    /// The active call has already been reported to CallKit under a UUID we still hold.
    var reportedToCallKit = false
    /// A session we tore down recently (decline/hang-up) — a late push for it must not re-ring.
    var recentlyEndedPeers: Set<String> = []
}

enum VoipPushAction: Equatable {
    enum RejectReason: String, Equatable {
        case malformed       // undecryptable / unsigned / no caller id — nothing to connect to
        case ownAccount      // our own account or device (another of my devices calling out)
        case recentlyEnded   // a late push for a call we already declined or hung up
        case busy            // a different call is in progress
        case duplicate       // the same call we're already ringing/in, not yet known to CallKit
    }
    /// A new incoming call: set up the session and ring.
    case ring(VoipPushCaller)
    /// The push is for the call CallKit already shows: re-report that same UUID (CallKit answers
    /// `callUUIDAlreadyExists`, which satisfies PushKit without a second call screen).
    case reReportExisting
    /// Report a throwaway call and end it at once — PushKit's mandatory report, no ring.
    case reportAndEnd(RejectReason)
}

enum VoipPushPolicy {
    static func decide(caller: VoipPushCaller?, state: VoipPushCallState) -> VoipPushAction {
        guard let caller, caller.peerHex.count == 64 else { return .reportAndEnd(.malformed) }
        let peer = caller.peerHex
        if peer == state.myHex || peer == state.myDeviceHex { return .reportAndEnd(.ownAccount) }
        if state.active {
            // Same call (the iroh invite got here first, a repeat push, or glare) vs another call.
            guard state.roster.contains(peer) else { return .reportAndEnd(.busy) }
            return state.reportedToCallKit ? .reReportExisting : .reportAndEnd(.duplicate)
        }
        if state.recentlyEndedPeers.contains(peer) { return .reportAndEnd(.recentlyEnded) }
        return .ring(caller)
    }
}
