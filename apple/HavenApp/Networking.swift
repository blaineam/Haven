import Foundation

/// Adapts the Rust `InboundListener` callback to a Swift closure. The Rust node calls
/// `onInbound` (off the main thread) for each inbound frame; FeedStore handles it.
/// `fromHex` is the sender's AUTHENTICATED transport node id (the iroh connection's remote
/// endpoint id), or "" when the frame wasn't received over a direct peer connection —
/// FeedStore uses it to learn a dialable device id for a contact from any direct hello.
final class InboundBridge: InboundListener {
    private let onData: @Sendable (String, Data) -> Void
    init(onData: @escaping @Sendable (String, Data) -> Void) { self.onData = onData }
    func onInbound(fromHex: String, payload: Data) { onData(fromHex, payload) }
}

/// Serializes engine-state exports + writes OFF the main actor. The exported state holds DECRYPTED
/// content + contacts + derived key material, so it stays protected at rest (readable only after
/// first unlock — the NSE/background can still reach it), never in a locked-device forensic image
/// or unencrypted backup. Being an actor, a burst of persist() calls runs one export at a time and
/// in order — an older export can never land after (and clobber) a newer one.
actor StatePersister {
    static let shared = StatePersister()
    func persist(social: HavenSocial, to url: URL) {
        try? social.exportState().write(to: url,
                                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
