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
        let dms = store.dmCircles.map {
            SiriCallTarget.DM(id: $0.id, members: store.dmMemberHexes($0.id),
                              locked: CircleSettingsStore.shared.biometricRequired($0.id))
        }
        let contact = (activity.interaction?.intent as? INStartCallIntent)?.contacts?.first
        guard let cid = SiriCallTarget.resolve(userInfo: activity.userInfo,
                                               contactHandle: contact?.personHandle?.value ?? contact?.customIdentifier,
                                               dms: dms) else {
            HavenLog.call("siri call: no callable conversation for the request")
            return
        }
        CallManager.shared.startCall(participants: store.dmMemberHexes(cid), name: store.dmPartnerName(cid))
    }
}
#endif
