package org.webrtc;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * JVM test doubles for the small native-backed WebRTC objects Haven's call code touches (tracks, senders, receivers,
 * streams). The real constructors reach into the native library, so instances are allocated without running them; each
 * double answers only the accessors the app reads.
 */
public final class FakeRtp {
    private FakeRtp() {}

    @SuppressWarnings("unchecked")
    private static <T> T alloc(Class<T> c) {
        try {
            Class<?> uc = Class.forName("sun.misc.Unsafe");
            Field f = uc.getDeclaredField("theUnsafe");
            f.setAccessible(true);
            return (T) uc.getMethod("allocateInstance", Class.class).invoke(f.get(null), c);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(e);
        }
    }

    public static FakeVideoTrack videoTrack(String id) {
        FakeVideoTrack t = alloc(FakeVideoTrack.class);
        t.trackId = id;
        return t;
    }

    public static AudioSource audioSource() { return alloc(FakeAudioSource.class); }

    public static FakeAudioTrack audioTrack(String id) {
        FakeAudioTrack t = alloc(FakeAudioTrack.class);
        t.trackId = id;
        t.enabled = true;
        return t;
    }

    public static FakeSender sender() {
        FakeSender s = alloc(FakeSender.class);
        s.params = new RtpParameters("tx", null, null, new ArrayList<RtpParameters.HeaderExtension>(),
                new ArrayList<RtpParameters.Encoding>(Collections.singletonList(new RtpParameters.Encoding("r", true, 1.0))),
                new ArrayList<RtpParameters.Codec>());
        return s;
    }

    public static FakeReceiver receiver(String id, MediaStreamTrack track) {
        FakeReceiver r = alloc(FakeReceiver.class);
        r.receiverId = id;
        r.receiverTrack = track;
        return r;
    }

    public static FakeStream stream(String id) {
        FakeStream s = alloc(FakeStream.class);
        s.streamId = id;
        return s;
    }

    public static class FakeVideoTrack extends VideoTrack {
        public String trackId;
        public boolean enabled = true;
        public FakeVideoTrack() { super(1L); }
        @Override public String id() { return trackId; }
        @Override public boolean enabled() { return enabled; }
        @Override public boolean setEnabled(boolean e) { enabled = e; return true; }
        @Override public void dispose() {}
    }

    public static class FakeAudioSource extends AudioSource {
        public FakeAudioSource() { super(1L); }
    }

    public static class FakeAudioTrack extends AudioTrack {
        public String trackId;
        public boolean enabled = true;
        public FakeAudioTrack() { super(1L); }
        @Override public String id() { return trackId; }
        @Override public boolean enabled() { return enabled; }
        @Override public boolean setEnabled(boolean e) { enabled = e; return true; }
        @Override public void dispose() {}
    }

    public static class FakeSender extends RtpSender {
        public RtpParameters params;
        public boolean accepted = true;
        public FakeSender() { super(1L); }
        @Override public RtpParameters getParameters() { return params; }
        @Override public boolean setParameters(RtpParameters p) { params = p; return accepted; }
        @Override public String id() { return "sender"; }
    }

    public static class FakeReceiver extends RtpReceiver {
        public String receiverId;
        public MediaStreamTrack receiverTrack;
        public FakeReceiver() { super(1L); }
        @Override public String id() { return receiverId; }
        @Override public MediaStreamTrack track() { return receiverTrack; }
    }

    public static class FakeStream extends MediaStream {
        public String streamId;
        public FakeStream() { super(1L); }
        @Override public String getId() { return streamId; }
    }

    /** Streams as the observer receives them. */
    public static MediaStream[] streams(String... ids) {
        List<MediaStream> out = new ArrayList<>();
        for (String id : ids) out.add(stream(id));
        return out.toArray(new MediaStream[0]);
    }
}
