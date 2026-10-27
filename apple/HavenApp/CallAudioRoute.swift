import Foundation
#if os(iOS)
import AVFoundation
#endif

// Where a Haven call's audio goes, as pure decisions — no session is touched here, so the rules are
// unit-testable.
//
// The bug this exists for (CarPlay test, 2026-10-27): every audio start/recovery used to force
// `overrideOutputAudioPort(.speaker)` and `.defaultToSpeaker` unconditionally. That PINS output to
// the iPhone's loudspeaker no matter what the user is connected to: the car (CarPlay / Bluetooth),
// AirPods, a wired headset and AirPlay were all overridden, the route picker only ever showed
// "iPhone speaker" selected, and the call played out of a tiny speaker in a pocket while the
// microphone's echo canceller (which assumes the far end is the speaker) clipped the voice —
// "super quiet on both sides". An external output the user connected is their choice; the speaker
// is only the default when nothing else is attached, and an explicit tap on the speaker button
// always wins.
enum CallAudioRoute {
    /// `AVAudioSession.Port` raw values of the phone's OWN outputs ("Speaker", "Receiver"). The
    /// decisions work on raw strings so they compile and are unit-tested on macOS too, where
    /// AVAudioSession does not exist; the iOS wrappers below feed them real ports.
    static let ownPortRawValues: Set<String> = ["Speaker", "Receiver"]

    /// Anything that is not the phone's own receiver or loudspeaker: a car, Bluetooth, a headset,
    /// AirPlay, USB audio, HDMI. These are chosen by the user (by pairing, plugging in or
    /// connecting), so a call honors them.
    static func isExternal(portRaw: String) -> Bool { !ownPortRawValues.contains(portRaw) }

    static func hasExternalOutput(portRaws: [String]) -> Bool { portRaws.contains(where: { isExternal(portRaw: $0) }) }

    /// Speaker or not: the user's explicit choice wins; otherwise the speaker, unless an external
    /// output is attached (then it stays on that output).
    static func wantsSpeaker(userChoice: Bool?, externalActive: Bool) -> Bool {
        userChoice ?? !externalActive
    }

    #if os(iOS)
    static func isExternal(_ port: AVAudioSession.Port) -> Bool { isExternal(portRaw: port.rawValue) }

    static func hasExternalOutput(_ ports: [AVAudioSession.Port]) -> Bool {
        hasExternalOutput(portRaws: ports.map(\.rawValue))
    }

    /// Category options for a call. `.defaultToSpeaker` belongs ONLY to speaker mode — under it,
    /// "no override" means the speaker, which would again beat an attached car or headset.
    /// A2DP is allowed so an output-only Bluetooth speaker/receiver is usable for a call too.
    static func categoryOptions(speaker: Bool) -> AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        if speaker { o.insert(.defaultToSpeaker) }
        return o
    }

    /// A route change that can change what "attached" means (not a category flip or wake-from-sleep).
    static func reroutesAutomatically(reason: AVAudioSession.RouteChangeReason) -> Bool {
        reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
    }
    #endif
}
