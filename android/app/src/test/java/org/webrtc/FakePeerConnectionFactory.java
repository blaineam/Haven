package org.webrtc;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;

/**
 * JVM test double for {@link PeerConnectionFactory}, whose real constructor needs the native library. Instances come from
 * {@link #make()}, which skips the constructor entirely; it hands out {@link FakePeerConnection}s and remembers them.
 */
public class FakePeerConnectionFactory extends PeerConnectionFactory {
    public List<FakePeerConnection> made;
    public boolean refuse;

    private FakePeerConnectionFactory() { super(1L); }   // never runs: see make()

    public static FakePeerConnectionFactory make() {
        try {
            Class<?> uc = Class.forName("sun.misc.Unsafe");
            Field f = uc.getDeclaredField("theUnsafe");
            f.setAccessible(true);
            Object u = f.get(null);
            FakePeerConnectionFactory fac = (FakePeerConnectionFactory)
                    uc.getMethod("allocateInstance", Class.class).invoke(u, FakePeerConnectionFactory.class);
            fac.made = new ArrayList<>();
            return fac;
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(e);
        }
    }

    @Override public AudioSource createAudioSource(MediaConstraints constraints) { return FakeRtp.audioSource(); }

    @Override public AudioTrack createAudioTrack(String id, AudioSource source) { return FakeRtp.audioTrack(id); }

    @Override public PeerConnection createPeerConnection(PeerConnection.RTCConfiguration config, PeerConnection.Observer observer) {
        if (refuse) return null;
        FakePeerConnection pc = new FakePeerConnection(observer, config);
        made.add(pc);
        return pc;
    }
}
