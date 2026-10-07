import XCTest

/// A relayed call carries ONE video stream per peer; while that peer shares its screen the stream
/// is the screen, and it must land in the screen slot (2026-10-07: a relayed Android screen share
/// decoded 0 frames on the Mac — the relay's frames went to the camera tile and the stage stayed black).
final class HairpinVideoRoutingTests: XCTestCase {
    private func slots(cam: String?, screen: String?, hp: String?, relaying: Bool) -> (String?, String?) {
        let s = HairpinVideoRouting.slots(webrtcCamera: cam, webrtcScreen: screen, hairpin: hp, relaying: relaying)
        return (s.camera, s.screen)
    }

    func testDirectPathUsesSignalledTracks() {
        XCTAssertTrue(slots(cam: "cam", screen: "scr", hp: "hp", relaying: false) == ("cam", "scr"))
        XCTAssertTrue(slots(cam: "cam", screen: nil, hp: nil, relaying: false) == ("cam", nil))
    }

    func testRelayedCameraFillsTheCameraTile() {
        XCTAssertTrue(slots(cam: "cam", screen: nil, hp: "hp", relaying: true) == ("hp", nil))
        XCTAssertTrue(slots(cam: nil, screen: nil, hp: "hp", relaying: true) == ("hp", nil))
    }

    func testRelayedShareFillsTheScreenStageAndNeverTheCameraSlot() {
        XCTAssertTrue(slots(cam: "cam", screen: "scr", hp: "hp", relaying: true) == ("cam", "hp"))
    }

    func testBeforeTheFirstRelayedFrameTheSignalledTracksStay() {
        XCTAssertTrue(slots(cam: "cam", screen: "scr", hp: nil, relaying: true) == ("cam", "scr"))
    }

    func testStopSharingHandsTheStreamBackToTheCameraTile() {
        // Share ended (screen un-signalled) while still relaying.
        XCTAssertTrue(slots(cam: "cam", screen: nil, hp: "hp", relaying: true) == ("hp", nil))
    }
}
