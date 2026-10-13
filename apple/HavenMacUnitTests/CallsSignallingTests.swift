import XCTest
import WebRTC
@testable import HavenUITestHost

/// The call state machine through the real stack: sealed + signed frames from a second identity go in
/// through `FeedStore`'s inbound path, and everything `CallManager` sends comes out as sealed frames on
/// the in-process relay's live-call lane, where the peer's own engine opens them. Media is a real
/// WebRTC peer connection per participant; no mic, camera, speaker or network is touched.
@MainActor
final class CallsSignallingTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayHex = String(repeating: "b8", count: 32)
    private var cm: CallManager { CallManager.shared }
    private var store: FeedStore { FeedStore.shared }
    private var me: String { store.myNodeHex }
    private var liveTestPeers: [WebRTCCall] = []

    // Peers whose account hex sorts above / below mine decide who sends the first offer.
    private static var above: Peer?
    private static var below: Peer?
    private static var third: Peer?

    override func setUp() async throws {
        _ = await Harness.feed()
        // A call that outlives the direct-media grace period races the hairpin relay, which would start
        // a voice-processing audio engine in this sandboxed host: never in a test.
        CallMediaBridge.suppressAudioEngineForTests = true
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        let r = RelayMailboxStore.shared
        r.add(circleId: "default", nodeHex: relayHex)
        r.setHttpInterface(relayHex, urls: [FakeWire.relayBase], token: "tok")
        RelayEnrollment.confirm(relayHex)
        endAnyCall()
        try await findPeers()
    }
    override func tearDown() async throws {
        endAnyCall()
        for c in liveTestPeers { c.close() }
        liveTestPeers = []
        let r = RelayMailboxStore.shared
        r.eraseNow(relayHex); r.dropErased(relayHex); r.unforget(relayHex)
        wire.uninstall()
        CallMediaBridge.suppressAudioEngineForTests = false
    }

    private func endAnyCall() { if cm.callInProgress { cm.endCall() } }

    private func findPeers() async throws {
        guard Self.above == nil || Self.below == nil else { return }
        var byte: UInt8 = 0x70
        while (Self.above == nil || Self.below == nil || Self.third == nil), byte < 0xE0 {
            let p = Peer(byte: byte, name: "Call peer \(byte)")
            if p.hex > me, Self.above == nil { Self.above = p }
            else if p.hex < me, Self.below == nil { Self.below = p }
            else if Self.third == nil, Self.above != nil || Self.below != nil { Self.third = p }
            byte += 1
        }
        for p in [Self.above, Self.below, Self.third].compactMap({ $0 }) { await p.befriend(store) }
    }
    private var above: Peer { Self.above! }
    private var below: Peer { Self.below! }
    private var third: Peer { Self.third! }

    // MARK: Helpers

    private func lp(_ s: String) -> Data { lp(Data(s.utf8)) }
    private func lp(_ d: Data) -> Data { Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)]) + d }
    private func readLP(_ d: Data, _ off: inout Int) -> String? {
        guard d.count >= off + 2 else { return nil }
        let n = Int(d[d.startIndex + off]) | Int(d[d.startIndex + off + 1]) << 8
        off += 2
        guard d.count >= off + n else { return nil }
        defer { off += n }
        return String(decoding: d.subdata(in: (d.startIndex + off)..<(d.startIndex + off + n)), as: UTF8.self)
    }
    private func session() -> String { cm.qaSnapshot()["session"] as? String ?? "" }

    /// A sealed + signed call frame from `peer` to me, delivered the way a transport would.
    private func inbound(_ type: UInt8, from peer: Peer, _ body: Data = Data()) throws {
        let sealed = try peer.engine.sealCallFrame(recipientNodeHex: me, frameType: type,
                                                    data: Data(peer.hex.utf8) + body)
        store.deliverFrameForTesting(Data([type]) + sealed)
    }

    /// What I sent `peer` of `type`, opened by the peer's own engine (so the seal and the signature are
    /// proven, not assumed). Each result is `[declared sender hex][body]`.
    private func sent(_ type: UInt8, to peer: Peer) -> [Data] {
        wire.relayKeys(prefix: "haven/mailbox/default/__live__/\(peer.hex.lowercased())/").compactMap { k in
            guard let f = wire.relayData(k), f.first == type,
                  let o = peer.engine.openCallFrame(frameType: type, blob: Data(f.dropFirst())) else { return nil }
            XCTAssertEqual(o.senderHex.lowercased(), me.lowercased(), "the proven signer is my account")
            return o.data
        }
    }
    private func waitSent(_ type: UInt8, to peer: Peer, _ what: String) async -> Data {
        await Harness.until(store, timeout: 45, what) { !self.sent(type, to: peer).isEmpty }
        return sent(type, to: peer).first ?? Data()
    }
    private func until(_ what: String, _ cond: @escaping @MainActor () -> Bool) async {
        await Harness.until(store, timeout: 45, what, cond)
    }

    /// Ring me from `peer` with a real group invite and answer it.
    private func answered(by peer: Peer, sid: String = "sess-\(UUID().uuidString.prefix(8))", roster: [String]? = nil) async throws -> String {
        let members = roster ?? [peer.hex, me]
        try inbound(21, from: peer, lp(sid) + lp("Group") + lp(members.joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970))))
        await until("the invite rings") { self.cm.ringing }
        cm.accept()
        return sid
    }

    /// The invite for `sid` was just (re)delivered. Frames are judged in order, so a DIFFERENT invite
    /// sent after it rings first-or-not: if the old session had rung, this one would be turned away.
    private func assertNoRing(for sid: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let next = "sess-sentinel-\(UUID().uuidString.prefix(6))"
        try inbound(21, from: third, lp(next) + lp("Group") + lp([third.hex, me].joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970))))
        await until("the sentinel invite rings") { self.session() == next }
        XCTAssertNotEqual(session(), sid, "the finished session did not ring again", file: file, line: line)
        cm.endCall()
    }

    // MARK: Outgoing

    func testAnOutgoingCallRingsItsInviteesWithTheSessionRosterAndSendTime() async throws {
        cm.startCall(participants: [above.hex], name: "Pal")
        XCTAssertTrue(cm.connecting); XCTAssertFalse(cm.inCall); XCTAssertTrue(cm.callInProgress)
        XCTAssertEqual(cm.peerName, "Pal")
        XCTAssertEqual(cm.participants, [above.hex])
        let body = await waitSent(21, to: above, "the group invite to reach the relay")
        XCTAssertEqual(String(decoding: body.prefix(64), as: UTF8.self), me, "the frame declares its sender")
        var off = 64
        let rest = body
        XCTAssertEqual(readLP(rest, &off), session(), "session id")
        XCTAssertEqual(readLP(rest, &off), "Pal", "group / partner name")
        XCTAssertEqual(Set((readLP(rest, &off) ?? "").split(separator: ",").map(String.init)), [me, above.hex], "full roster, me included")
        let ts = TimeInterval(readLP(rest, &off) ?? "") ?? 0
        XCTAssertLessThan(abs(Date().timeIntervalSince1970 - ts), 30, "the send time lets a receiver refuse a replay")
        XCTAssertEqual(cm.qaSnapshot()["connecting"] as? Bool, true)
    }

    func testHangingUpTellsEveryoneAndForgetsTheSession() async throws {
        cm.startCall(participants: [above.hex, third.hex], name: "Pair")
        let sid = session()
        XCTAssertFalse(sid.isEmpty)
        cm.endCall()
        XCTAssertFalse(cm.callInProgress); XCTAssertFalse(cm.connecting); XCTAssertFalse(cm.inCall)
        XCTAssertEqual(cm.participants, [])
        XCTAssertEqual(cm.peerName, "")
        XCTAssertEqual(session(), "")
        for p in [above, third] {
            let bye = await waitSent(12, to: p, "the hangup to reach \(p.name)")
            var off = 64
            XCTAssertEqual(readLP(bye, &off), sid, "the hangup names the session it ends")
        }
        cm.endCall()   // already over: idempotent
    }

    func testNobodyDialableMeansNoCall() {
        cm.startCall(participants: [], name: "x")
        cm.startCall(participants: ["", me, me.uppercased()], name: "me")
        XCTAssertFalse(cm.callInProgress, "calling only yourself is not a call")
        ConnectionsStore.shared.block(third.hex)
        defer { ConnectionsStore.shared.unblock(third.hex) }
        cm.startCall(participants: [third.hex], name: "blocked")
        XCTAssertFalse(cm.callInProgress, "a blocked person is never dialled")
        XCTAssertFalse(cm.addableContacts().contains { $0.hex == third.hex }, "…nor offered for adding")
    }

    func testASecondCallWhileOneIsActiveIsIgnored() {
        cm.startCall(participants: [above.hex], name: "First")
        let sid = session()
        cm.startCall(participants: [below.hex], name: "Second")
        XCTAssertEqual(session(), sid)
        XCTAssertEqual(cm.peerName, "First")
        XCTAssertEqual(cm.participants, [above.hex])
    }

    // MARK: Accept and the offer

    func testTheCalleeAcceptingMovesTheCallerInCallAndTheSmallerIdOffers() async throws {
        cm.startCall(participants: [above.hex], name: "Up")
        let sid = session()
        try inbound(11, from: above, lp(sid))
        await until("accept moves me in-call") { self.cm.inCall }
        XCTAssertFalse(cm.connecting)
        // An accept is app-level signalling: the label may only claim media from transport truth (an ICE
        // path that is up, or a relay carrying it) — never from the accept alone.
        let relayed = (cm.qaSnapshot()["hairpin_peers"] as? [String]) ?? []
        XCTAssertEqual(cm.mediaConnected, !relayed.isEmpty)
        let offer = await waitSent(16, to: above, "my offer")
        var off = 64
        XCTAssertEqual(readLP(offer, &off), sid)
        let json = offer.subdata(in: offer.startIndex.advanced(by: off)..<offer.endIndex)
        let sdp = try XCTUnwrap(CallSignal.decodeSDP(json))
        XCTAssertEqual(sdp.type, .offer)
        XCTAssertTrue(sdp.sdp.contains("m=audio"))
        XCTAssertTrue(sdp.sdp.contains("m=video"))
        let snap = cm.qaSnapshot()
        XCTAssertEqual(snap["in_call"] as? Bool, true)
        XCTAssertEqual(snap["participants"] as? [String], [above.hex])
        XCTAssertNotNil(snap["peers"])
    }

    func testAnAcceptForAnotherSessionOrAStrangerIsIgnored() async throws {
        cm.startCall(participants: [above.hex], name: "Up")
        try inbound(11, from: above, lp("some-other-session"))
        let stranger = String(repeating: "cd", count: 32)
        cm.handleAccept(Data(stranger.utf8) + lp(session()))
        cm.handleAccept(Data("short".utf8))
        // Nothing may have moved the call off Calling: let the async inbound path judge them first.
        try await barrier(above)
        XCTAssertTrue(cm.connecting)
        XCTAssertFalse(cm.inCall)
    }
    /// Frames are opened and dispatched on an async path. A camera-state frame from a roster member has
    /// an observable effect, so once it has landed every frame sent before it has been judged too.
    private func barrier(_ peer: Peer) async throws {
        try inbound(22, from: peer, lp(session()) + Data([0]))
        await until("the inbound queue to drain") { self.cm.remoteCameraOff.contains(peer.hex) }
    }

    // MARK: Incoming call, answerer side

    func testAnsweringARingingCallAcceptsAndAnswersTheCallersOffer() async throws {
        let sid = try await answered(by: below)
        XCTAssertTrue(cm.inCall); XCTAssertFalse(cm.ringing)
        let accept = await waitSent(11, to: below, "my accept")
        var off = 64
        XCTAssertEqual(readLP(accept, &off), sid, "the accept names the session")
        // The caller (smaller id) offers: play that part with a real peer connection.
        let remote = try XCTUnwrap(WebRTCCall.make()); liveTestPeers.append(remote)
        remote.setMicEnabled(false)
        let offered = expectation(description: "remote offer")
        let box = OfferBox()
        remote.onLocalSDP = { s in box.set(s); offered.fulfill() }
        remote.onLocalCandidate = { c in box.add(c) }
        remote.makeOffer()
        await fulfillment(of: [offered], timeout: 30)
        try inbound(16, from: below, lp(sid) + CallSignal.encodeSDP(box.sdp!))
        let answerBody = await waitSent(17, to: below, "my answer")
        var o2 = 64
        XCTAssertEqual(readLP(answerBody, &o2), sid)
        let answer = try XCTUnwrap(CallSignal.decodeSDP(answerBody.subdata(in: answerBody.startIndex.advanced(by: o2)..<answerBody.endIndex)))
        XCTAssertEqual(answer.type, .answer)
        let ready = expectation(description: "remote accepted my answer")
        remote.onRemoteReady = { ready.fulfill() }
        remote.setRemoteAnswer(answer)
        await fulfillment(of: [ready], timeout: 30)
        // Candidates before and after the description: buffered until it is set, then applied.
        for c in box.candidates { try inbound(18, from: below, lp(sid) + CallSignal.encodeCandidate(c)) }
        try inbound(18, from: below, lp(sid) + Data("{}".utf8))   // not a candidate: dropped
        try inbound(18, from: below, lp("wrong-session") + CallSignal.encodeCandidate(RTCIceCandidate(sdp: "candidate:1 1 udp 1 10.0.0.9 9 typ host", sdpMLineIndex: 0, sdpMid: "0")))
        XCTAssertTrue(cm.inCall)
    }

    func testAnOfferFromAStrangerOrForAnotherSessionNegotiatesNothing() async throws {
        let sid = try await answered(by: below)
        _ = await waitSent(11, to: below, "my accept")
        let remote = try XCTUnwrap(WebRTCCall.make()); liveTestPeers.append(remote)
        let offered = expectation(description: "offer")
        let box = OfferBox()
        remote.onLocalSDP = { s in box.set(s); offered.fulfill() }
        remote.makeOffer()
        await fulfillment(of: [offered], timeout: 30)
        let wrongSession = lp("not-" + sid) + CallSignal.encodeSDP(box.sdp!)
        try inbound(16, from: below, wrongSession)
        try inbound(16, from: third, lp(sid) + CallSignal.encodeSDP(box.sdp!))   // a contact, but not in this call's roster
        try inbound(17, from: below, lp(sid) + CallSignal.encodeSDP(box.sdp!))   // an answer with no offer outstanding
        try inbound(16, from: below, lp(sid) + Data("not json".utf8))
        try await barrier(below)
        XCTAssertTrue(sent(17, to: below).isEmpty, "none of those earned an answer")
        XCTAssertTrue(sent(17, to: third).isEmpty)
    }

    // MARK: Ending

    func testTheOnlyPeerHangingUpEndsTheCallButAStaleHangupDoesNot() async throws {
        let sid = try await answered(by: below)
        try inbound(12, from: below, lp("an-older-session"))
        try await barrier(below)
        XCTAssertTrue(cm.inCall, "a late BYE from a finished call must not hang up this one")
        try inbound(12, from: below, lp(sid))
        await until("the real hangup ends the call") { !self.cm.callInProgress }
        XCTAssertFalse(cm.inCall)
        XCTAssertEqual(session(), "")
    }

    func testOnePeerLeavingAGroupCallKeepsItGoingForTheRest() async throws {
        cm.startCall(participants: [above.hex, third.hex], name: "Trio")
        let sid = session()
        try inbound(11, from: above, lp(sid))
        await until("in call") { self.cm.inCall }
        XCTAssertEqual(Set(cm.participants), [above.hex, third.hex])
        try inbound(12, from: above, lp(sid))
        await until("above is dropped") { self.cm.participants == [self.third.hex] }
        XCTAssertTrue(cm.callInProgress, "one participant leaving does not end it for everyone")
        try inbound(12, from: third, lp(sid))
        await until("the last peer leaving ends it") { !self.cm.callInProgress }
    }

    func testARingingCallTheCallerGivesUpOnEndsAsMissed() async throws {
        let sid = "sess-missed-\(UUID().uuidString.prefix(6))"
        try inbound(21, from: below, lp(sid) + lp("Group") + lp([below.hex, me].joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970))))
        await until("ringing") { self.cm.ringing }
        try inbound(12, from: below, lp(sid))
        await until("the caller's hangup stops the ring") { !self.cm.ringing && !self.cm.callInProgress }
    }

    // MARK: Media path

    func testWhenDirectMediaNeverComesUpTheCallRacesTheHairpinRelay() async throws {
        let sid = try await answered(by: below)
        // This host can open no UDP socket, so ICE can never pair: after the direct-path grace period
        // the relay takes the call, exactly as it does for two phones behind hard NATs.
        await until("the hairpin relay takes the call") {
            ((self.cm.qaSnapshot()["hairpin_peers"] as? [String]) ?? []).contains(self.below.hex)
        }
        XCTAssertTrue(cm.mediaConnected, "a relay carrying the call IS media")
        XCTAssertTrue(cm.inCall); XCTAssertFalse(cm.connecting)
        XCTAssertTrue(CallMediaBridge.shared.activePeers.contains(below.hex))
        XCTAssertNil(CallMediaBridge.shared.silenceSecs(for: below.hex), "relayed but nothing heard yet")
        CallMediaBridge.shared.ingest(remote: below.hex, frame: CallMediaBridge.pack(.audio, seq: 1, ptsMs: 0, payload: Data(count: 640)))
        XCTAssertNotNil(CallMediaBridge.shared.silenceSecs(for: below.hex), "the relay's own liveness clock is running")
        let inbound = cm.qaSnapshot()
        XCTAssertGreaterThan(inbound["inbound_audio_bytes"] as? Int ?? 0, 0, "relayed audio counts as a real call's media")
        try self.inbound(12, from: below, lp(sid))
        await until("the peer leaving ends the call") { !self.cm.callInProgress }
        XCTAssertTrue(CallMediaBridge.shared.activePeers.isEmpty, "teardown stops the relay")
        XCTAssertFalse(cm.mediaConnected)
        XCTAssertEqual((cm.qaSnapshot()["hairpin_peers"] as? [String]) ?? ["x"], [])
    }

    // MARK: WebRTC's part, played against the real state machine

    private func videoTrack(_ id: String) -> RTCVideoTrack {
        WebRTCCall.factory.videoTrack(with: WebRTCCall.factory.videoSource(), trackId: id)
    }
    private func relayed() -> [String] { (cm.qaSnapshot()["hairpin_peers"] as? [String]) ?? [] }

    func testIceStatesDriveWhatTheCallLabelClaims() async throws {
        _ = try await answered(by: below)
        let call = try XCTUnwrap(cm.qaPeerCall(below.hex), "accepting built the pairwise connection")
        call.onStateChange?(.checking)
        call.onStateChange?(.disconnected)
        try await barrier(below)
        XCTAssertFalse(cm.mediaConnected, "checking/disconnected is not media")
        call.onStateChange?(.connected)
        await until("ICE connected reads as media") { self.cm.mediaConnected }
        call.onStateChange?(.completed)
        call.onStateChange?(.disconnected)
        await until("a drop reads as not connected") { !self.cm.mediaConnected }
        XCTAssertTrue(cm.inCall, "a blip does not end the call: the peer gets a grace period")
        call.onStateChange?(.connected)
        await until("recovery reads as media again") { self.cm.mediaConnected }
    }

    func testAFailedIcePathHandsTheCallToTheRelayAndRecoveryTakesItBack() async throws {
        _ = try await answered(by: below)
        let call = try XCTUnwrap(cm.qaPeerCall(below.hex))
        call.onStateChange?(.failed)
        await until("ICE failure engages the hairpin") { self.relayed().contains(self.below.hex) }
        XCTAssertTrue(cm.inCall); XCTAssertFalse(cm.connecting)
        XCTAssertTrue(CallMediaBridge.shared.activePeers.contains(below.hex))
        call.onStateChange?(.connected)
        await until("ICE recovery stands the relay down") { !self.relayed().contains(self.below.hex) }
        XCTAssertFalse(CallMediaBridge.shared.activePeers.contains(below.hex), "two media pipelines for one call is the heat bug")
        XCTAssertTrue(cm.mediaConnected, "WebRTC's own path carries it again")
    }

    func testAClosedConnectionDropsThePeerAndTheLastOneEndsTheCall() async throws {
        cm.startCall(participants: [above.hex, third.hex], name: "Trio")
        let sid = session()
        try inbound(11, from: above, lp(sid))
        try inbound(11, from: third, lp(sid))
        await until("both in") { self.cm.inCall && Set(self.cm.participants) == [self.above.hex, self.third.hex] }
        await until("both connections exist") { self.cm.qaPeerCall(self.above.hex) != nil && self.cm.qaPeerCall(self.third.hex) != nil }
        cm.qaPeerCall(above.hex)?.onStateChange?(.closed)
        await until("the closed peer is dropped") { self.cm.participants == [self.third.hex] }
        XCTAssertTrue(cm.callInProgress)
        cm.qaPeerCall(third.hex)?.onStateChange?(.closed)
        await until("nobody left ends the call") { !self.cm.callInProgress }
    }

    func testRemoteCameraAndScreenTracksLandInTheirOwnSlots() async throws {
        _ = try await answered(by: below)
        let call = try XCTUnwrap(cm.qaPeerCall(below.hex))
        let camera = videoTrack("cam"), screen = videoTrack("scr")
        call.onRemoteVideoTrack?(camera, false)
        call.onRemoteVideoTrack?(screen, true)
        await until("both tracks are published") { self.cm.remoteVideoTracks[self.below.hex] != nil && self.cm.remoteScreenTracks[self.below.hex] != nil }
        XCTAssertTrue(cm.remoteVideoTracks[below.hex] === camera)
        XCTAssertTrue(cm.remoteScreenTracks[below.hex] === screen, "a screen share must never overwrite the camera tile")
        let snap = cm.qaSnapshot()
        XCTAssertEqual(snap["remote_video_tracks"] as? [String], [below.hex])
        XCTAssertNotNil((snap["remote_tracks"] as? [String: Any])?[below.hex])
        call.onRemoteVideoTrackEnded?(true)
        await until("the share ends") { self.cm.remoteScreenTracks[self.below.hex] == nil }
        XCTAssertTrue(cm.remoteVideoTracks[below.hex] === camera, "…and the camera is untouched")
        call.onRemoteVideoTrackEnded?(false)
        await until("the camera ends") { self.cm.remoteVideoTracks[self.below.hex] == nil }
    }

    func testNoMediaClaimOutlivesTheCallThatEarnedIt() async throws {
        _ = try await answered(by: below)
        cm.qaPeerCall(below.hex)?.onStateChange?(.connected)
        await until("ICE connected") { self.cm.mediaConnected }
        cm.endCall()
        XCTAssertFalse(cm.callInProgress)
        XCTAssertFalse(cm.mediaConnected, "an idle phone is not 'connected'; the next call must not inherit the last one's ICE state")
        // …so the next call with the same person starts from 'connecting media', not 'Connected'.
        let sid = try await answered(by: below)
        XCTAssertFalse(sid.isEmpty)
        let relayedNow = relayed()
        XCTAssertEqual(cm.mediaConnected, !relayedNow.isEmpty)
    }

    // MARK: Active speaker

    func testTheActiveSpeakerNeedsTwoLoudPollsAndYieldsToQuiet() {
        XCTAssertNil(cm.activeSpeaker)
        cm.resolveActiveSpeaker(bestPeer: "p", bestRemote: 0.5, myLevel: 0)
        XCTAssertNil(cm.activeSpeaker, "one loud poll is a blip, not a speaker")
        cm.resolveActiveSpeaker(bestPeer: "p", bestRemote: 0.5, myLevel: 0)
        XCTAssertEqual(cm.activeSpeaker, "p")
        cm.resolveActiveSpeaker(bestPeer: "q", bestRemote: 0.6, myLevel: 0)
        XCTAssertEqual(cm.activeSpeaker, "p", "a challenger starts a fresh streak")
        cm.resolveActiveSpeaker(bestPeer: "q", bestRemote: 0.6, myLevel: 0)
        XCTAssertEqual(cm.activeSpeaker, "q")
        cm.resolveActiveSpeaker(bestPeer: "q", bestRemote: 0.01, myLevel: 0.01)
        XCTAssertNil(cm.activeSpeaker, "everybody under the threshold clears the highlight")
    }

    func testMyOwnVoiceCountsOnlyWhileIAmNotMuted() {
        cm.resolveActiveSpeaker(bestPeer: "p", bestRemote: 0.2, myLevel: 0.9)
        cm.resolveActiveSpeaker(bestPeer: "p", bestRemote: 0.2, myLevel: 0.9)
        XCTAssertEqual(cm.activeSpeaker, "", "the empty id is me")
        cm.toggleMute()
        defer { if cm.muted { cm.toggleMute() } }
        cm.resolveActiveSpeaker(bestPeer: "p", bestRemote: 0.2, myLevel: 0.9)
        cm.resolveActiveSpeaker(bestPeer: "p", bestRemote: 0.2, myLevel: 0.9)
        XCTAssertEqual(cm.activeSpeaker, "p", "a muted mic never lights my tile")
        cm.resolveActiveSpeaker(bestPeer: "", bestRemote: 0, myLevel: 0)
    }

    // MARK: Ring timeout and my other devices

    func testARingNobodyEndsIsGivenUpOnAsMissed() async throws {
        let sid = "sess-timeout-\(UUID().uuidString.prefix(6))"
        try inbound(21, from: below, lp(sid) + lp("Group") + lp([below.hex, me].joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970))))
        await until("ringing") { self.cm.ringing }
        cm.ringTimedOut()
        XCTAssertFalse(cm.ringing); XCTAssertFalse(cm.callInProgress)
        cm.ringTimedOut()   // nothing ringing: a no-op
        // The session is tombstoned: the caller's retransmitted invite must not ring it again.
        try inbound(21, from: below, lp(sid) + lp("Group") + lp([below.hex, me].joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970))))
        try await Task.yield()
        XCTAssertFalse(cm.ringing)
    }

    func testAnotherDeviceOfMineAnsweringSilencesMyRingForGoodAndNeverAnAnsweredCall() async throws {
        let sid = "sess-elsewhere-\(UUID().uuidString.prefix(6))"
        let invite = lp(sid) + lp("Group") + lp([below.hex, me].joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970)))
        try inbound(21, from: below, invite)
        await until("ringing") { self.cm.ringing }
        cm.handleHandledElsewhere(Data(third.hex.utf8) + lp(sid))   // not my account
        cm.handleHandledElsewhere(Data(me.utf8) + lp("other-session"))
        XCTAssertTrue(cm.ringing, "only MY account, for THIS session, may silence the ring")
        cm.handleHandledElsewhere(Data(me.utf8) + lp(sid))
        XCTAssertFalse(cm.ringing); XCTAssertFalse(cm.callInProgress)
        try inbound(21, from: below, invite)   // a late retransmit of the same invite
        try await assertNoRing(for: sid)
    }

    func testHandledElsewhereNeverHangsUpAConversationInProgress() async throws {
        let sid = try await answered(by: below)
        cm.handleHandledElsewhere(Data(me.utf8) + lp(sid))
        XCTAssertTrue(cm.inCall, "a late 'handled elsewhere' must not kill the call this device answered")
        cm.handleEndedElsewhere(Data(third.hex.utf8) + lp(sid))      // not my account
        cm.handleEndedElsewhere(Data(me.utf8) + lp("other-session"))
        cm.handleEndedElsewhere(Data(me.utf8))                        // no session field
        XCTAssertTrue(cm.inCall)
        cm.handleEndedElsewhere(Data(me.utf8) + lp(sid))              // the same call, ended on my other device
        XCTAssertFalse(cm.callInProgress, "an ENDED call tears down even a call this device answered")
    }

    // MARK: Glare

    func testTwoPeopleCallingEachOtherAtOnceAdoptASharedSession() async throws {
        cm.startCall(participants: [above.hex], name: "Up")
        XCTAssertTrue(cm.connecting)
        cm.handleInvite(Data(above.hex.utf8) + Data("Me".utf8))   // their legacy invite crosses mine
        let expected = "glare:\(min(me.lowercased(), above.hex.lowercased()))-\(max(me.lowercased(), above.hex.lowercased()))"
        XCTAssertEqual(session(), expected, "both ends derive the same id from the sorted pair")
        XCTAssertTrue(cm.inCall); XCTAssertFalse(cm.connecting); XCTAssertFalse(cm.ringing)
        let accept = await waitSent(11, to: above, "the accept that closes the glare")
        var off = 64
        XCTAssertEqual(readLP(accept, &off), expected)
    }

    // MARK: In-call controls and roster

    func testMuteSpeakerAndCameraStateWhileInACall() async throws {
        _ = try await answered(by: below)
        XCTAssertFalse(cm.muted)
        cm.toggleMute(); XCTAssertTrue(cm.muted)
        cm.toggleMute(); XCTAssertFalse(cm.muted)
        let speaker = cm.speakerOn
        cm.toggleSpeaker(); XCTAssertNotEqual(cm.speakerOn, speaker)
        cm.toggleSpeaker(); XCTAssertEqual(cm.speakerOn, speaker)
        try inbound(22, from: below, lp(session()) + Data([0]))
        await until("their camera reads off") { self.cm.remoteCameraOff.contains(self.below.hex) }
        try inbound(22, from: below, lp(session()) + Data([1]))
        await until("their camera reads on") { !self.cm.remoteCameraOff.contains(self.below.hex) }
        cm.handleCameraState(Data(third.hex.utf8) + Data([0]))   // not in the call: ignored
        XCTAssertFalse(cm.remoteCameraOff.contains(third.hex))
        XCTAssertEqual(cm.availableMicInputs().count, 0, "native macOS leaves device choice to the system")
        XCTAssertNil(cm.currentMicName)
        XCTAssertEqual(cm.currentOutputName, "Default")
    }

    func testAddingSomeoneToACallReRingsThemWithTheUpdatedRoster() async throws {
        let sid = try await answered(by: below)
        XCTAssertTrue(cm.addableContacts().contains { $0.hex == third.hex })
        cm.addToCall(third.hex)
        XCTAssertTrue(cm.participants.contains(third.hex))
        XCTAssertFalse(cm.addableContacts().contains { $0.hex == third.hex }, "already in the call")
        let invite = await waitSent(21, to: third, "the newcomer's invite")
        var off = 64
        XCTAssertEqual(readLP(invite, &off), sid, "they join the SAME session")
        _ = readLP(invite, &off)
        let roster = Set((readLP(invite, &off) ?? "").split(separator: ",").map(String.init))
        XCTAssertEqual(roster, [me, below.hex, third.hex], "the newcomer meshes with everyone already in")
        let before = cm.participants
        cm.addToCall(third.hex); cm.addToCall(me); cm.addToCall("")
        XCTAssertEqual(cm.participants, before, "no duplicates, no self, no blanks")
    }

    func testAGroupInviteForTheLiveSessionMergesTheRosterAndStaleOnesAreDropped() async throws {
        let sid = try await answered(by: below)
        try inbound(21, from: below, lp(sid) + lp("Group") + lp([below.hex, me, third.hex].joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970))))
        await until("the roster grows") { self.cm.participants.contains(self.third.hex) }
        // A replay older than the caller's whole dialling window never touches a live call.
        let old = UInt64(Date().timeIntervalSince1970) - 3_600
        try inbound(21, from: below, lp(sid) + lp("Group") + lp([below.hex, me, above.hex].joined(separator: ",")) + lp(String(old)))
        try await barrier(below)
        XCTAssertFalse(cm.participants.contains(above.hex))
    }

    // MARK: VoIP push ring

    func testAPushRingsWithAPlaceholderSessionThatTheRealInviteThenReplaces() async throws {
        cm.handleVoipPush(caller: VoipPushCaller(name: "Pushy", peerHex: below.hex))
        XCTAssertTrue(cm.ringing)
        XCTAssertEqual(session(), "push:\(below.hex)")
        XCTAssertEqual(cm.peerName, "Pushy")
        let sid = "sess-real-\(UUID().uuidString.prefix(6))"
        try inbound(21, from: below, lp(sid) + lp("Group") + lp([below.hex, me].joined(separator: ",")) + lp(String(UInt64(Date().timeIntervalSince1970))))
        await until("the real session is adopted") { self.session() == sid }
        XCTAssertTrue(cm.ringing)
        // A second push for the same caller while ringing is a duplicate, not a second call.
        cm.handleVoipPush(caller: VoipPushCaller(name: "Pushy", peerHex: below.hex))
        XCTAssertEqual(session(), sid)
    }

    func testPushesThatMustNotRingNeverDo() {
        cm.handleVoipPush(caller: nil)
        cm.handleVoipPush(caller: VoipPushCaller(name: "x", peerHex: "short"))
        cm.handleVoipPush(caller: VoipPushCaller(name: "me", peerHex: me))
        XCTAssertFalse(cm.ringing, "malformed or self-addressed")
        cm.startCall(participants: [above.hex], name: "Busy")
        cm.handleVoipPush(caller: VoipPushCaller(name: "other", peerHex: below.hex))
        XCTAssertEqual(cm.peerName, "Busy", "a push for a different call while on one is turned away")
        XCTAssertFalse(cm.ringing)
    }

    // MARK: Small surfaces

    func testNamesComeFromContactsAndFallBackToAShortHex() {
        XCTAssertEqual(cm.displayName(for: above.hex), ContactsStore.shared.name(forNodePrefix: above.hex) ?? String(above.hex.prefix(6)))
        let unknown = String(repeating: "ab", count: 32)
        XCTAssertEqual(cm.displayName(for: unknown), "ababab")
    }

    func testTheQaSnapshotAlwaysCarriesTheKeysTheHarnessReads() {
        cm.qaNoteCallEvent("probe")
        let snap = cm.qaSnapshot()
        for key in ["session", "last_event", "in_call", "connecting", "ringing", "video_on", "participants", "hairpin_peers",
                    "audio_unavailable", "audio_gate", "remote_video_tracks", "inbound_audio_bytes", "inbound_video_bytes",
                    "inbound_video_frames", "peers", "remote_tracks"] {
            XCTAssertNotNil(snap[key], key)
        }
        XCTAssertEqual(snap["last_event"] as? String, "probe")
        XCTAssertEqual(snap["in_call"] as? Bool, false)
    }

    func testTheForcedHairpinFlagOnlyHoldsInADebugLaunch() {
        XCTAssertEqual(CallManager.debugEnabled, ProcessInfo.processInfo.environment["DEBUG"] == "1")
        let saved = UserDefaults.standard.object(forKey: "haven.debug.forceHairpin")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "haven.debug.forceHairpin") } else { UserDefaults.standard.removeObject(forKey: "haven.debug.forceHairpin") } }
        CallManager.forceHairpin = true
        XCTAssertEqual(CallManager.forceHairpin, CallManager.debugEnabled, "a forgotten switch cannot outlive the debug launch that set it")
        CallManager.forceHairpin = false
        XCTAssertFalse(CallManager.forceHairpin)
    }

    func testCallsAreIdleWhenNothingIsHappening() {
        XCTAssertFalse(cm.callAudioAvailable && cm.callInProgress)
        XCTAssertFalse(cm.mediaConnected)
        XCTAssertFalse(cm.mediaFailed)
        XCTAssertNil(cm.localVideoTrack)
        XCTAssertEqual(cm.remoteVideoTracks.count, 0)
        XCTAssertEqual(cm.remoteScreenTracks.count, 0)
        XCTAssertFalse(cm.screenShareOn)
        cm.stopScreenShare()   // nothing shared: a no-op
        cm.flipCamera()        // camera off: a no-op
        cm.selectCamera("none")
        cm.syncIdleTimer()
    }
}

/// SDP and candidates produced on WebRTC's own queue, read back on the main actor.
private final class OfferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _sdp: RTCSessionDescription?
    private var _cands: [RTCIceCandidate] = []
    var sdp: RTCSessionDescription? { lock.withLock { _sdp } }
    var candidates: [RTCIceCandidate] { lock.withLock { _cands } }
    func set(_ s: RTCSessionDescription) { lock.withLock { _sdp = s } }
    func add(_ c: RTCIceCandidate) { lock.withLock { _cands.append(c) } }
}
