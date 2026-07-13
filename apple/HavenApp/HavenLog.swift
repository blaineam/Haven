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

    static func net(_ msg: String) { net.log("\(msg, privacy: .public)") }
    static func relay(_ msg: String) { relay.log("\(msg, privacy: .public)") }
    static func sync(_ msg: String) { sync.log("\(msg, privacy: .public)") }
    static func call(_ msg: String) { call.log("\(msg, privacy: .public)") }
}
