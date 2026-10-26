import Foundation

/// Cross-process "doorbell" between the Intents extension and the app, over Darwin notifications
/// (no payload, no entitlement - the data travels through `SiriRequestQueue` in the App Group).
///
/// request: extension -> app, "there is something in the queue".
/// ack:     app -> extension, "I drained it", which lets Siri say "sent" only when that is true.
enum SiriRequestSignal {
    static let request = "com.blaineam.kith.siri.request"
    static let ack = "com.blaineam.kith.siri.ack"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Observation token; removing the observer happens in `cancel()`.
    final class Token {
        fileprivate let name: String
        fileprivate let box: Box
        fileprivate init(name: String, box: Box) { self.name = name; self.box = box }
        func cancel() {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                               Unmanaged.passUnretained(box).toOpaque(),
                                               CFNotificationName(name as CFString), nil)
        }
        deinit { cancel() }
    }
    fileprivate final class Box {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    /// `handler` runs on an arbitrary thread.
    static func observe(_ name: String, _ handler: @escaping () -> Void) -> Token {
        let box = Box(handler)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(box).toOpaque(),
                                        { _, observer, _, _, _ in
                                            guard let observer else { return }
                                            Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().handler()
                                        },
                                        name as CFString, nil, .deliverImmediately)
        return Token(name: name, box: box)
    }
}
