import XCTest
#if os(iOS)
import AVFoundation
#endif

/// The rules that decide where a call's audio goes. The bug they pin: every audio start forced the
/// iPhone loudspeaker, overriding a connected car/Bluetooth/headset output (CarPlay call was
/// "super quiet", and the route picker offered nothing but speaker).
final class CallAudioRouteTests: XCTestCase {
    func testPhoneOwnPortsAreNotExternal() {
        XCTAssertFalse(CallAudioRoute.isExternal(portRaw: "Speaker"))
        XCTAssertFalse(CallAudioRoute.isExternal(portRaw: "Receiver"))
        XCTAssertFalse(CallAudioRoute.hasExternalOutput(portRaws: ["Receiver"]))
        XCTAssertFalse(CallAudioRoute.hasExternalOutput(portRaws: []))
    }

    func testCarBluetoothHeadsetAndAirPlayAreExternal() {
        // AVAudioSession.Port raw values: CarAudio, BluetoothHFP, BluetoothA2DP, BluetoothLE,
        // Headphones, AirPlay, USBAudio, HDMI, LineOut.
        for raw in ["CarAudio", "BluetoothHFP", "BluetoothA2DP", "BluetoothLE", "Headphones",
                    "AirPlay", "USBAudio", "HDMI", "LineOut"] {
            XCTAssertTrue(CallAudioRoute.isExternal(portRaw: raw), raw)
            XCTAssertTrue(CallAudioRoute.hasExternalOutput(portRaws: ["Receiver", raw]), raw)
        }
    }

    func testSpeakerIsTheDefaultOnlyWhenNothingExternalIsAttached() {
        XCTAssertTrue(CallAudioRoute.wantsSpeaker(userChoice: nil, externalActive: false))
        XCTAssertFalse(CallAudioRoute.wantsSpeaker(userChoice: nil, externalActive: true),
                       "a connected car must not be overridden by the default")
    }

    func testAnExplicitTapAlwaysWins() {
        XCTAssertTrue(CallAudioRoute.wantsSpeaker(userChoice: true, externalActive: true))
        XCTAssertFalse(CallAudioRoute.wantsSpeaker(userChoice: false, externalActive: false))
    }

    #if os(iOS)
    func testRawValuesMatchTheRealPorts() {
        XCTAssertEqual(AVAudioSession.Port.builtInSpeaker.rawValue, "Speaker")
        XCTAssertEqual(AVAudioSession.Port.builtInReceiver.rawValue, "Receiver")
        XCTAssertTrue(CallAudioRoute.isExternal(.carAudio))
        XCTAssertTrue(CallAudioRoute.isExternal(.bluetoothHFP))
        XCTAssertFalse(CallAudioRoute.isExternal(.builtInSpeaker))
    }

    func testDefaultToSpeakerBelongsOnlyToSpeakerMode() {
        XCTAssertTrue(CallAudioRoute.categoryOptions(speaker: true).contains(.defaultToSpeaker))
        XCTAssertFalse(CallAudioRoute.categoryOptions(speaker: false).contains(.defaultToSpeaker))
        for speaker in [true, false] {
            let o = CallAudioRoute.categoryOptions(speaker: speaker)
            XCTAssertTrue(o.contains(.allowBluetoothHFP))
            XCTAssertTrue(o.contains(.allowBluetoothA2DP))
        }
    }

    func testOnlyDeviceAttachDetachReroutes() {
        XCTAssertTrue(CallAudioRoute.reroutesAutomatically(reason: .newDeviceAvailable))
        XCTAssertTrue(CallAudioRoute.reroutesAutomatically(reason: .oldDeviceUnavailable))
        XCTAssertFalse(CallAudioRoute.reroutesAutomatically(reason: .categoryChange))
        XCTAssertFalse(CallAudioRoute.reroutesAutomatically(reason: .override))
    }
    #endif
}
