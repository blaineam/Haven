#if os(iOS)
import Foundation
import Intents

/// Places the Haven call Siri asked for ("call Maya on Haven", or the CarPlay call affordance). The
/// Intents extension only resolves the contact and answers `.continueInApp`; the app - which owns the
/// engine, WebRTC and CallKit - starts the call here, through the same `CallManager.startCall` every
/// in-app call button uses. CallKit then shows it on the car's display like any other phone call.
@MainActor
enum SiriCallRouter {
    static let activityType = "INStartCallIntent"

    static func handle(_ activity: NSUserActivity, retried: Bool = false) {
        let store = FeedStore.shared
        guard store.isConfigured else {
            // Cold launch from Siri: the engine boots asynchronously. Try once more when it is up.
            guard !retried else { return }
            store.configureForCurrentIdentity { handle(activity, retried: true) }
            return
        }
        let dms = currentDMs()
        let contact = (activity.interaction?.intent as? INStartCallIntent)?.contacts?.first
        guard let cid = SiriCallTarget.resolve(userInfo: activity.userInfo,
                                               contactHandle: contact?.personHandle?.value ?? contact?.customIdentifier,
                                               dms: dms) else {
            HavenLog.call("siri call: no callable conversation for the request")
            return
        }
        start(cid)
    }

    /// CarPlay's Calls tab: the same validation and the same call path as Siri's.
    static func place(conversationId: String) {
        guard FeedStore.shared.isConfigured,
              let cid = SiriCallTarget.resolve(userInfo: [SiriCallTarget.conversationKey: conversationId],
                                               contactHandle: nil, dms: currentDMs()) else {
            HavenLog.call("carplay call: conversation not callable")
            return
        }
        start(cid)
    }

    private static func currentDMs() -> [SiriCallTarget.DM] {
        let store = FeedStore.shared
        return store.dmCircles.map {
            SiriCallTarget.DM(id: $0.id, members: store.dmMemberHexes($0.id),
                              locked: CircleSettingsStore.shared.biometricRequired($0.id))
        }
    }

    /// `CallManager.startCall` begins audio-only (CXStartCallAction.isVideo == false, camera off); video is
    /// something the user turns on from the phone. That is what makes it safe to start from a car.
    private static func start(_ cid: String) {
        let store = FeedStore.shared
        CallManager.shared.startCall(participants: store.dmMemberHexes(cid), name: store.dmPartnerName(cid))
    }
}
#endif
