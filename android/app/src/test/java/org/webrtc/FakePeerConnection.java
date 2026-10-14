package org.webrtc;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

/**
 * JVM test double for the native-backed {@link PeerConnection}. It models only what Haven's signalling logic observes:
 * the signalling state machine (stable / have-local-offer / have-remote-offer), the SDP and candidate calls, and when each
 * completion callback fires. With {@link #autoRun} off, completions are queued so a test can interleave them the way the
 * real signalling thread races with the network (an answer arriving before setLocalDescription(offer) finished, glare).
 */
public class FakePeerConnection extends PeerConnection {
    public final PeerConnection.Observer observer;
    public final PeerConnection.RTCConfiguration config;
    public PeerConnection.SignalingState state = PeerConnection.SignalingState.STABLE;
    public boolean autoRun = true;
    public final ArrayDeque<Runnable> pending = new ArrayDeque<>();
    public final List<String> log = new ArrayList<>();
    public final List<IceCandidate> candidates = new ArrayList<>();
    public final List<MediaStreamTrack> addedTracks = new ArrayList<>();
    public RtpSender nextSender;
    public RTCStatsReport stats = new RTCStatsReport(0, new java.util.HashMap<String, RTCStats>());
    public boolean failStats;
    public int disposeCount;
    private int sdpCounter;

    public FakePeerConnection(PeerConnection.Observer observer, PeerConnection.RTCConfiguration config) {
        super(1L);
        this.observer = observer;
        this.config = config;
    }

    private void later(Runnable r) {
        if (autoRun) r.run(); else pending.add(r);
    }

    /** Run everything queued, including what running it queues. */
    public void pump() {
        while (!pending.isEmpty()) pending.poll().run();
    }

    /** Run exactly one queued completion. */
    public void pumpOne() {
        Runnable r = pending.poll();
        if (r != null) r.run();
    }

    @Override public PeerConnection.SignalingState signalingState() { return state; }

    @Override public void createOffer(SdpObserver o, MediaConstraints c) {
        log.add("createOffer");
        final String sdp = "offer-sdp-" + (++sdpCounter);
        later(() -> o.onCreateSuccess(new SessionDescription(SessionDescription.Type.OFFER, sdp)));
    }

    @Override public void createAnswer(SdpObserver o, MediaConstraints c) {
        log.add("createAnswer");
        final String sdp = "answer-sdp-" + (++sdpCounter);
        later(() -> o.onCreateSuccess(new SessionDescription(SessionDescription.Type.ANSWER, sdp)));
    }

    @Override public void setLocalDescription(SdpObserver o, SessionDescription sd) {
        log.add("setLocal " + sd.type);
        later(() -> {
            switch (sd.type) {
                case OFFER: state = PeerConnection.SignalingState.HAVE_LOCAL_OFFER; break;
                default: state = PeerConnection.SignalingState.STABLE; break;   // answer or rollback
            }
            o.onSetSuccess();
        });
    }

    @Override public void setRemoteDescription(SdpObserver o, SessionDescription sd) {
        log.add("setRemote " + sd.type + " " + sd.description);
        later(() -> {
            state = sd.type == SessionDescription.Type.OFFER
                    ? PeerConnection.SignalingState.HAVE_REMOTE_OFFER
                    : PeerConnection.SignalingState.STABLE;
            o.onSetSuccess();
        });
    }

    @Override public boolean addIceCandidate(IceCandidate c) {
        candidates.add(c);
        return true;
    }

    @Override public RtpSender addTrack(MediaStreamTrack t, List<String> streamIds) {
        log.add("addTrack " + t.id() + " " + streamIds);
        addedTracks.add(t);
        return nextSender;
    }

    @Override public boolean removeTrack(RtpSender s) {
        log.add("removeTrack");
        return true;
    }

    @Override public void getStats(RTCStatsCollectorCallback cb) {
        if (failStats) throw new IllegalStateException("stats unavailable");
        cb.onStatsDelivered(stats);
    }

    @Override public void dispose() { disposeCount++; }

    @Override public void close() { log.add("close"); }
}
