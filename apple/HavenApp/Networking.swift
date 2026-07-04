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
