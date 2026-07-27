import Foundation
import os

/// Lightweight diagnostic logging for live multi-device / transport debugging. Streams to the unified log
/// under subsystem `com.blaineam.haven.diag`, so it's observable in real time with:
///     log stream --predicate 'subsystem == "com.blaineam.haven.diag"' --info --debug
/// Compiled in all configs but cheap; remove the call sites once the device-identity work is settled.
enum HavenLog {
    private static let net = Logger(subsystem: "com.blaineam.haven.diag", category: "net")
    private static let relay = Logger(subsystem: "com.blaineam.haven.diag", category: "relay")
    private static let sync = Logger(subsystem: "com.blaineam.haven.diag", category: "sync")
    private static let call = Logger(subsystem: "com.blaineam.haven.diag", category: "call")

    static func net(_ msg: String) { net.log("\(msg, privacy: .public)"); echo("net", msg) }
    static func relay(_ msg: String) { relay.log("\(msg, privacy: .public)"); echo("relay", msg) }
    static func sync(_ msg: String) { sync.log("\(msg, privacy: .public)"); echo("sync", msg) }
    static func call(_ msg: String) { call.log("\(msg, privacy: .public)"); echo("call", msg) }

    /// DEBUG builds also write to stdout, so a diagnostic is readable on a REAL DEVICE with
    /// `xcrun devicectl device process launch --console`.
    ///
    /// The unified log is the right destination and stays the primary one, but it is not reachable
    /// from a network-paired phone: `log stream` has no `--device-udid` on current macOS, and
    /// `idevicesyslog` returns nothing for this pairing. That left a device-only bug with no
    /// observable diagnostics at all — which is how the missing video poster got two wrong fixes
    /// before anyone saw a single line of what the app was actually doing.
    @inline(__always)
    private static func echo(_ category: String, _ msg: String) {
        #if DEBUG
        print("[haven.\(category)] \(msg)")
        #endif
    }
}
