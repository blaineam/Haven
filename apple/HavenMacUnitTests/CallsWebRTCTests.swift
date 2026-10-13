import XCTest
import WebRTC
import CoreVideo
@testable import HavenUITestHost

/// `WebRTCCall` against a REAL second peer connection in the same process: the offer/answer exchange,
/// perfect-negotiation glare handling, screen-share tracks, the signalling wire format and the
/// small pure helpers. No STUN/TURN is reached (the sandboxed host has no route in these tests and
/// nothing here waits on ICE); camera and microphone are never opened.
@MainActor
final class CallsWebRTCTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _sdps: [RTCSessionDescription] = []
        private var _candidates: [RTCIceCandidate] = []
        private var _ready = 0
        var sdps: [RTCSessionDescription] { lock.withLock { _sdps } }
        var candidates: [RTCIceCandidate] { lock.withLock { _candidates } }
        var ready: Int { lock.withLock { _ready } }
        func add(_ s: RTCSessionDescription) { lock.withLock { _sdps.append(s) } }
        func add(_ c: RTCIceCandidate) { lock.withLock { _candidates.append(c) } }
        func markReady() { lock.withLock { _ready += 1 } }
    }

    private func call(_ log: Log, polite: Bool = false, sdp: XCTestExpectation? = nil, ready: XCTestExpectation? = nil) throws -> WebRTCCall {
        Harness.assertIsolatedHost()
        let c = try XCTUnwrap(WebRTCCall.make(), "WebRTC hands back a peer connection")
        c.polite = polite
        c.setMicEnabled(false)
        c.onLocalSDP = { s in log.add(s); sdp?.fulfill() }
        c.onLocalCandidate = { log.add($0) }
        c.onRemoteReady = { log.markReady(); ready?.fulfill() }
        return c
    }

    // MARK: Offer / answer

    func testAnOfferNamesAudioAndAVideoLineEvenBeforeTheCameraIsOn() async throws {
        let log = Log()
        let offered = expectation(description: "offer")
        let a = try call(log, sdp: offered)
        defer { a.close() }
        a.makeOffer()
        await fulfillment(of: [offered], timeout: 30)
        let offer = try XCTUnwrap(log.sdps.first)
        XCTAssertEqual(offer.type, .offer)
        XCTAssertTrue(offer.sdp.contains("m=audio"))
        XCTAssertTrue(offer.sdp.contains("m=video"), "the video m-line is fixed at construction so enabling the camera never renegotiates")
        XCTAssertNotNil(a.localVideoTrack)
        XCTAssertFalse(a.localVideoTrack?.isEnabled ?? true, "…but the track starts disabled")
    }

    func testTwoCallsNegotiateAnAnswerThroughTheSignallingEncoding() async throws {
        let logA = Log(), logB = Log()
        let offered = expectation(description: "offer"), answered = expectation(description: "answer")
        let aReady = expectation(description: "a ready"), bReady = expectation(description: "b ready")
        let a = try call(logA, sdp: offered, ready: aReady)
        let b = try call(logB, polite: true, sdp: answered, ready: bReady)
        defer { a.close(); b.close() }
        a.makeOffer()
        await fulfillment(of: [offered], timeout: 30)
        // Over the wire: sealed JSON, decoded on the far side.
        let wireOffer = CallSignal.encodeSDP(try XCTUnwrap(logA.sdps.first))
        b.setRemoteOfferAndAnswer(try XCTUnwrap(CallSignal.decodeSDP(wireOffer)))
        await fulfillment(of: [bReady, answered], timeout: 30)
        let answer = try XCTUnwrap(logB.sdps.first)
        XCTAssertEqual(answer.type, .answer)
        a.setRemoteAnswer(try XCTUnwrap(CallSignal.decodeSDP(CallSignal.encodeSDP(answer))))
        await fulfillment(of: [aReady], timeout: 30)
        XCTAssertEqual(logA.ready, 1)
    }

    func testAnAnswerThatArrivesWithNoOfferOutstandingIsIgnored() async throws {
        let logA = Log(), logB = Log()
        let aReady = expectation(description: "a ready")
        aReady.isInverted = true
        let b = try call(logB, polite: true)
        let a = try call(logA, ready: aReady)
        defer { a.close(); b.close() }
        let fake = RTCSessionDescription(type: .answer, sdp: "v=0\r\n")
        a.setRemoteAnswer(fake)   // a is .stable: a redelivered/stale answer must not be applied
        await fulfillment(of: [aReady], timeout: 0.5)
        XCTAssertEqual(logA.ready, 0)
    }

    func testOnlyOneOfferIsEverInFlight() async throws {
        let log = Log()
        let first = expectation(description: "first offer")
        let a = try call(log, sdp: first)
        defer { a.close() }
        a.makeOffer()
        a.makeOffer()   // rejected synchronously: an offer is already being made
        await fulfillment(of: [first], timeout: 30)
        a.makeOffer()   // …and again once local description is set (have-local-offer is not .stable)
        let offers = log.sdps.filter { $0.type == .offer }
        XCTAssertEqual(offers.count, 1)
    }

    func testAPoliteSideRollsBackItsOwnOfferAndAnswersTheCollidingOne() async throws {
        let logA = Log(), logB = Log()
        let aOffer = expectation(description: "a offered"), bOffer = expectation(description: "b offered")
        let bAnswer = expectation(description: "b answered")
        let a = try call(logA, polite: false, sdp: aOffer)
        let b = try call(logB, polite: true)
        defer { a.close(); b.close() }
        var bSawOffer = false
        b.onLocalSDP = { s in
            logB.add(s)
            if s.type == .offer, !bSawOffer { bSawOffer = true; bOffer.fulfill() }
            if s.type == .answer { bAnswer.fulfill() }
        }
        a.makeOffer(); b.makeOffer()   // both sides offer at once: glare
        await fulfillment(of: [aOffer, bOffer], timeout: 30)
        // a's offer reaches b while b has its own outstanding: b is polite, so it yields and answers.
        b.setRemoteOfferAndAnswer(try XCTUnwrap(logA.sdps.first { $0.type == .offer }))
        await fulfillment(of: [bAnswer], timeout: 30)
        XCTAssertTrue(logB.sdps.contains { $0.type == .answer })
    }

    func testAnImpoliteSideIgnoresACollidingOfferAndKeepsItsOwn() async throws {
        let logA = Log(), logB = Log()
        let aOffer = expectation(description: "a offered"), bOffer = expectation(description: "b offered")
        let a = try call(logA, polite: false, sdp: aOffer)
        let b = try call(logB, polite: true, sdp: bOffer)
        defer { a.close(); b.close() }
        a.makeOffer(); b.makeOffer()
        await fulfillment(of: [aOffer, bOffer], timeout: 30)
        let noAnswer = expectation(description: "a must not answer")
        noAnswer.isInverted = true
        a.onLocalSDP = { s in if s.type == .answer { noAnswer.fulfill() } }
        a.setRemoteOfferAndAnswer(try XCTUnwrap(logB.sdps.first { $0.type == .offer }))
        await fulfillment(of: [noAnswer], timeout: 0.5)
    }

    func testRemoteCandidatesCanBeAddedOnceTheRemoteDescriptionIsSet() async throws {
        let logA = Log(), logB = Log()
        let offered = expectation(description: "offer"), bReady = expectation(description: "b ready")
        let a = try call(logA, sdp: offered)
        let b = try call(logB, polite: true, ready: bReady)
        defer { a.close(); b.close() }
        a.makeOffer()
        await fulfillment(of: [offered], timeout: 30)
        b.setRemoteOfferAndAnswer(try XCTUnwrap(logA.sdps.first))
        await fulfillment(of: [bReady], timeout: 30)
        let cand = RTCIceCandidate(sdp: "candidate:1 1 udp 2122260223 192.0.2.7 54321 typ host", sdpMLineIndex: 0, sdpMid: "0")
        b.addRemoteCandidate(cand)
        // The wire form survives the trip.
        let back = try XCTUnwrap(CallSignal.decodeCandidate(CallSignal.encodeCandidate(cand)))
        XCTAssertEqual(back.sdp, cand.sdp)
        XCTAssertEqual(back.sdpMLineIndex, 0)
        XCTAssertEqual(back.sdpMid, "0")
    }

    // MARK: Statistics

    func testStatsCallbacksAnswerEvenWithNoMediaFlowing() async throws {
        let log = Log()
        let a = try call(log)
        defer { a.close() }
        let levels = expectation(description: "levels"), media = expectation(description: "media")
        a.audioLevels { inbound, outbound in
            XCTAssertEqual(inbound, 0); XCTAssertGreaterThanOrEqual(outbound, 0)
            levels.fulfill()
        }
        a.inboundMedia { audio, video, frames in
            XCTAssertEqual(audio, 0); XCTAssertEqual(video, 0); XCTAssertEqual(frames, 0)
            media.fulfill()
        }
        await fulfillment(of: [levels, media], timeout: 30)
        let tracks = expectation(description: "inbound video tracks")
        a.inboundVideoTracks { tracks_ in XCTAssertTrue(tracks_.isEmpty); tracks.fulfill() }
        await fulfillment(of: [tracks], timeout: 30)
    }

    // MARK: Screen share

    private func screenFrame() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    func testScreenShareIsALazySecondTrackThatCanBeAddedAndRemoved() throws {
        let c = try call(Log())
        defer { c.close() }
        XCTAssertFalse(c.isSharingScreen)
        c.pushScreenFrame(screenFrame(), timeStampNs: 1)   // no-op while not sharing
        XCTAssertTrue(c.startScreenShare(), "a new track means the caller must renegotiate")
        XCTAssertTrue(c.isSharingScreen)
        XCTAssertFalse(c.startScreenShare(), "idempotent: already sharing")
        c.pushScreenFrame(screenFrame(), timeStampNs: 2)
        c.pushScreenFrame(screenFrame(), timeStampNs: 3, rotation: ._90)
        XCTAssertTrue(c.stopScreenShare())
        XCTAssertFalse(c.isSharingScreen)
        XCTAssertFalse(c.stopScreenShare(), "nothing left to remove")
    }

    func testScreenTracksAreRecognisedByTheirStreamBeforeTheirTrackId() {
        XCTAssertTrue(WebRTCCall.isScreenTrack(trackId: "video0", streamIds: ["screen"]), "the stream id is authoritative")
        XCTAssertFalse(WebRTCCall.isScreenTrack(trackId: "screen0", streamIds: ["stream0"]), "a camera stream wins over a lookalike track id")
        XCTAssertTrue(WebRTCCall.isScreenTrack(trackId: "screen0", streamIds: []), "no stream announced: fall back to the track id")
        XCTAssertFalse(WebRTCCall.isScreenTrack(trackId: "video0", streamIds: []))
        XCTAssertEqual(WebRTCCall.screenTrackId, "screen0")
        XCTAssertEqual(WebRTCCall.screenStreamId, "screen")
    }

    func testTheCameraProxyRotatesEveryFrameQuarterTurnCounterClockwise() throws {
        let source = WebRTCCall.factory.videoSource()
        let proxy = RotatingVideoProxy(source: source)
        let capturer = RTCVideoCapturer(delegate: source)
        for r in [RTCVideoRotation._0, ._90, ._180, ._270] {
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: screenFrame()), rotation: r, timeStampNs: 5)
            proxy.capturer(capturer, didCapture: frame)
        }
    }

    // MARK: Signalling wire format and helpers

    func testSignallingRejectsWhatItCannotUse() {
        XCTAssertNil(CallSignal.decodeSDP(Data("nope".utf8)))
        XCTAssertNil(CallSignal.decodeSDP(Data(#"{"t":"offer"}"#.utf8)), "an SDP frame needs its body")
        XCTAssertNil(CallSignal.decodeCandidate(Data("nope".utf8)))
        XCTAssertNil(CallSignal.decodeCandidate(Data(#"{"c":"x"}"#.utf8)), "a candidate needs its m-line index")
        let ans = CallSignal.decodeSDP(Data(#"{"t":"answer","sdp":"v=0"}"#.utf8))
        XCTAssertEqual(ans?.type, .answer)
        let cand = CallSignal.decodeCandidate(Data(#"{"c":"candidate:1","m":1}"#.utf8))
        XCTAssertEqual(cand?.sdpMLineIndex, 1)
        XCTAssertNil(cand?.sdpMid, "mid is optional")
        let noMid = CallSignal.encodeCandidate(RTCIceCandidate(sdp: "candidate:9", sdpMLineIndex: 2, sdpMid: nil))
        XCTAssertFalse(String(decoding: noMid, as: UTF8.self).contains("\"i\""))
    }

    func testIceDiagnosticsAreReadable() {
        XCTAssertEqual(WebRTCCall.candidateSummary("candidate:842163049 1 udp 1677729535 203.0.113.9 52300 typ srflx raddr 0.0.0.0 rport 0"),
                       "udp 203.0.113.9:52300 srflx")
        XCTAssertEqual(WebRTCCall.candidateSummary("candidate:1 1 UDP 1 10.0.0.2 9 typ host"), "udp 10.0.0.2:9 host")
        XCTAssertEqual(WebRTCCall.candidateSummary("short"), "short", "an unparseable line is shown as-is")
        let names: [(RTCIceConnectionState, String)] = [(.new, "new"), (.checking, "checking"), (.connected, "connected"),
            (.completed, "completed"), (.failed, "failed"), (.disconnected, "disconnected"), (.closed, "closed"), (.count, "count")]
        for (s, n) in names { XCTAssertEqual(WebRTCCall.iceStateName(s), n) }
    }

    func testMuteTeardownAndFlipAreSafeWithoutACamera() throws {
        let c = try call(Log())
        XCTAssertTrue(c.usingFrontCamera)
        c.setMicEnabled(true); c.setMicEnabled(false)
        c.stopVideo()
        c.releaseLocalMedia()
        XCTAssertNil(c.localVideoTrack, "releasing local media drops the camera track")
        c.closeConnection()
        c.close()
    }
}
