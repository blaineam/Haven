#if os(iOS)
import CarPlay
import UIKit

/// The car's display. CarPlay runs in the SAME process as the phone UI, so this scene reads the
/// same `FeedStore` the phone does. The scene is connected by the system (never by us) when the
/// phone is plugged into / wirelessly paired with a CarPlay head unit.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        HavenLog.sync("carplay: connected")
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        HavenLog.sync("carplay: disconnected")
    }
}
#endif
