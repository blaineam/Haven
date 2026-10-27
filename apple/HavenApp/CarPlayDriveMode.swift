#if os(iOS)
import CarPlay

/// Whether message TEXT may be shown on the car's display.
///
/// CarPlay has no public "parked / driving" API. The one signal an app gets is
/// `CPSessionConfiguration.limitedUserInterfaces`: a vehicle that restricts long lists and/or the
/// keyboard while it moves reports `.lists` / `.keyboard`, and clears them when it is parked. So:
///   * any reported limit  -> `.driving`: no message text on screen, only names, unread counts and the
///     actions (Read to me / Reply / Call);
///   * no limit reported   -> `.parked`: the recent messages are shown.
/// A car (or the CarPlay simulator) that never reports a limit therefore always looks parked - there is
/// nothing more to go on, and the docs say so (docs/CARPLAY.md).
enum CarPlayDriveMode: Equatable {
    case parked
    case driving

    /// The pure decision: is the vehicle limiting its UI at all?
    static func mode(limitsActive: Bool) -> CarPlayDriveMode { limitsActive ? .driving : .parked }

    static func mode(for limits: CPLimitableUserInterface) -> CarPlayDriveMode { mode(limitsActive: !limits.isEmpty) }

    var showsMessageText: Bool { self == .parked }
}
#endif
