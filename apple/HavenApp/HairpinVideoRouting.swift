/// Which track each of a peer's two video SLOTS (camera tile, screen stage) shows.
///
/// When ICE can't pair two peers the hairpin relay carries the call (CallMediaBridge), and it
/// carries exactly ONE video stream per peer: whatever that peer is sending — its camera, or its
/// screen while it shares (Android's bridge swaps the relayed track; see `setLocalVideoTrack`).
/// The share itself is still SIGNALLED over WebRTC, so the screen track appears even though no
/// RTP will ever reach it. Routing the relayed video into the camera tile regardless left a
/// relayed screen share as a black stage with the shared screen squeezed into a thumbnail — and
/// the receiver decoded zero frames into the screen slot.
///
/// Pure value logic, generic over the track type, so HavenLogicTests covers it without WebRTC.
enum HairpinVideoRouting {
    struct Slots<Track> {
        var camera: Track?
        var screen: Track?
    }

    /// - Parameters:
    ///   - webrtcCamera / webrtcScreen: the tracks WebRTC signalled for this peer (nil when none).
    ///   - hairpin: the relay's decoded video track for this peer, once its first frame arrived.
    ///   - relaying: whether the relay is currently carrying this peer's media.
    static func slots<Track>(webrtcCamera: Track?, webrtcScreen: Track?, hairpin: Track?,
                             relaying: Bool) -> Slots<Track> {
        guard relaying, let hairpin else {
            // Direct path (or no relayed frame yet): WebRTC's own tracks, exactly as signalled.
            return Slots(camera: webrtcCamera, screen: webrtcScreen)
        }
        if webrtcScreen != nil {
            // Sharing: the one relayed stream IS the screen. The camera slot keeps its own
            // (signalled) track so the share never overwrites it.
            return Slots(camera: webrtcCamera, screen: hairpin)
        }
        return Slots(camera: hairpin, screen: nil)
    }
}
