package com.blaineam.haven.core

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import android.view.Surface
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.GlRectDrawer
import org.webrtc.PeerConnectionFactory
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Real call media over the `/webrtc/hairpin` WebSocket — the TCP/TLS path that free Cloudflare
 * tunnels front (WSS is an HTTPS upgrade; only UDP TURN is impossible over the tunnel). When
 * WebRTC's own ICE cannot pair two hard-NAT peers, this relays the media itself so a call still
 * carries audio and video with zero router configuration.
 *
 * Android had none of this. [FabricIcePolicy] and [CallManager] both carried comments promising a
 * "path-proxy WebSocket hairpin for media" as the thing that makes host-only ICE survivable — the
 * promise was the comment; the code was never written. So an Android leg whose ICE failed had no
 * media path at all: the call rang, was accepted, and sat in "connecting" forever, while an
 * Apple↔Apple call in the same conditions completed over its hairpin. This is the port.
 *
 * It is a PARALLEL pipeline to WebRTC, not a plug-in to it — WebRTC exposes no PCM tap — so:
 *  • audio runs on its own [AudioRecord]/[AudioTrack] pair at 16 kHz mono, with the platform
 *    AEC/NS/AGC effects bound to the record session so a speakerphone call does not echo;
 *  • video reuses WebRTC's capture (a [VideoSink] on the local track) and its render (decoded
 *    frames pushed into a [VideoSource] whose track the existing call UI already draws), so only
 *    the transit hops onto the WebSocket.
 *
 * Wire frame — byte-for-byte Apple `CallMediaBridge`, or the two platforms cannot relay to each
 * other: `[type u8][seq u16 BE][ptsMs u32 BE]` then the payload. Real-time: loss is dropped, never
 * retried — a retry only adds latency.
 */
object CallMediaBridge {
    private const val TAG = "HavenHairpinMedia"

    // Frame types — the wire contract lives in [HairpinFrame] so a test can pin it.
    private const val TYPE_AUDIO: Byte = HairpinFrame.TYPE_AUDIO
    private const val TYPE_VIDEO_KEY: Byte = HairpinFrame.TYPE_VIDEO_KEY
    private const val TYPE_VIDEO_DELTA: Byte = HairpinFrame.TYPE_VIDEO_DELTA

    // Audio wire format — must match Apple's `wireFormat` (16 kHz mono Int16).
    private const val SAMPLE_RATE = 16_000
    private const val FRAME_SAMPLES = 320          // 20 ms
    private const val FRAME_BYTES = FRAME_SAMPLES * 2

    private lateinit var appContext: Context

    /** Remotes we are actively relaying to/from (ICE failed for these peers). */
    private val activePeers = HashSet<String>()
    private var audioSeq: Int = 0
    private var videoSeq: Int = 0

    // Audio
    private var recorder: AudioRecord? = null
    private var player: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var agc: AutomaticGainControl? = null
    private val capturing = AtomicBoolean(false)
    private val jitter = JitterBuffer()

    // Video encode (MediaCodec H.264) fed by an EGL renderer on the local WebRTC track.
    //
    // Guarded by [videoLock], NOT by the CallMediaBridge monitor. The VideoSink below runs on
    // WebRTC's capture thread at frame rate and can CREATE the codec (first frame, or a resolution
    // change); hangup releases it from whichever thread called deactivate/stopAll. Without a shared
    // lock those two race and the capture thread submits to a released MediaCodec — a native crash
    // at the moment you end a relayed video call. A separate lock keeps that contention off the
    // monitor that audio and frame ingest already take.
    private val videoLock = Any()
    @Volatile private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    @Volatile private var encoderRenderer: EglRenderer? = null
    private var localSink: VideoSink? = null
    private var localTrack: VideoTrack? = null
    private var encoderSize: Pair<Int, Int>? = null
    private var encoderCsd: ByteArray? = null       // SPS/PPS, prepended to every keyframe
    private val encoderDraining = AtomicBoolean(false)

    // Video decode → inject into a VideoSource per remote so the call UI renders it.
    private class RemoteVideo(
        val decoder: MediaCodec,
        val helper: SurfaceTextureHelper,
        val surface: Surface,
        val source: VideoSource,
        val track: VideoTrack,
    )
    private val remoteVideo = HashMap<String, RemoteVideo>()
    /** Remotes whose decoder is still waiting for its first keyframe (deltas are unusable alone). */
    private val awaitingKeyframe = HashSet<String>()

    /** Last time a relay frame arrived from each peer — the relay's own liveness signal. */
    private val lastInboundAt = HashMap<String, Long>()

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /**
     * Seconds since we last heard anything from [remote] over the relay, or null if it is not being
     * relayed / has never been heard from. The ICE watchdog deliberately never drops a peer we are
     * relaying (ICE sits failed BECAUSE we relayed), so this is the only thing that can notice a
     * relayed far end that simply vanished.
     */
    @Synchronized
    fun silenceSecs(remote: String): Long? {
        if (!activePeers.contains(remote)) return null
        val t = lastInboundAt[remote] ?: return null
        return (System.currentTimeMillis() - t) / 1000
    }

    @Synchronized
    fun isRelaying(remote: String): Boolean = activePeers.contains(remote)

    @Synchronized
    fun anyRelaying(): Boolean = activePeers.isNotEmpty()

    // ---- Lifecycle ----------------------------------------------------------------------------

    /**
     * Begin relaying media to [remote] over the hairpin (called when its ICE path fails). Starts the
     * audio pipeline on the first peer and silences WebRTC's own (dead) audio so the two do not
     * fight for the microphone. Idempotent.
     */
    @Synchronized
    fun activate(
        remote: String,
        sessionId: String,
        me: String,
        localVideoTrack: VideoTrack?,
        eglBase: EglBase,
        factory: PeerConnectionFactory,
    ) {
        CallHairpin.onBinary = { r, d -> ingest(r, d) }
        CallHairpin.open(appContext, sessionId, me, remote)
        if (!activePeers.add(remote)) return
        Log.i(TAG, "hairpin media: activating relay for ${remote.take(8)}")
        if (activePeers.size == 1) {
            CallManager.setNativeAudioSuspendedForHairpin(true)   // hand the mic to our recorder
            startAudio()
        }
        ensureRemoteVideo(remote, eglBase, factory)
        localVideoTrack?.let { attachLocalVideo(it, eglBase) }
    }

    /** Stop relaying to [remote] (its ICE recovered, or the peer left). */
    @Synchronized
    fun deactivate(remote: String) {
        if (!activePeers.remove(remote)) return
        lastInboundAt.remove(remote)
        Log.i(TAG, "hairpin media: deactivating relay for ${remote.take(8)}")
        tearDownRemoteVideo(remote)
        if (activePeers.isEmpty()) {
            stopAllInternal()
            CallManager.setNativeAudioSuspendedForHairpin(false)   // give the mic back
        }
    }

    @Synchronized
    fun stopAll() {
        val wasActive = activePeers.isNotEmpty()
        activePeers.clear()
        lastInboundAt.clear()
        stopAllInternal()
        if (wasActive) CallManager.setNativeAudioSuspendedForHairpin(false)
        CallHairpin.onBinary = null
    }

    private fun stopAllInternal() {
        stopAudio()
        detachLocalVideo()
        remoteVideo.keys.toList().forEach { tearDownRemoteVideo(it) }
        awaitingKeyframe.clear()
    }

    /** The decoded remote video track for a peer, if the relay is producing one. */
    @Synchronized
    fun remoteVideoTrack(remote: String): VideoTrack? = remoteVideo[remote]?.track

    // ---- Audio --------------------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun startAudio() {
        if (capturing.get()) return
        val minIn = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minIn <= 0) { Log.w(TAG, "no usable AudioRecord buffer size"); return }
        val rec = runCatching {
            AudioRecord(
                // VOICE_COMMUNICATION is the source the platform routes AEC/NS through, and the same
                // one WebRTC's own ADM uses — so the effects below actually attach.
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minIn, FRAME_BYTES * 4),
            )
        }.getOrNull()
        if (rec == null || rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.w(TAG, "AudioRecord unavailable — relayed call will have no outbound audio")
            runCatching { rec?.release() }
            return
        }
        // Hardware echo cancellation / noise suppression / AGC where the device offers them. Without
        // AEC a speakerphone relay echoes badly — the remote hears themselves a beat later.
        runCatching {
            if (AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
            }
            if (NoiseSuppressor.isAvailable()) {
                ns = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
            }
            if (AutomaticGainControl.isAvailable()) {
                agc = AutomaticGainControl.create(rec.audioSessionId)?.apply { enabled = true }
            }
        }

        val minOut = AudioTrack.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val trk = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build())
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build())
                .setBufferSizeInBytes(maxOf(minOut, FRAME_BYTES * 8))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        }.getOrNull()
        if (trk == null) {
            Log.w(TAG, "AudioTrack unavailable — relayed call will have no inbound audio")
            runCatching { rec.release() }
            return
        }

        recorder = rec
        player = trk
        jitter.reset()
        runCatching { trk.play() }
        runCatching { rec.startRecording() }
        capturing.set(true)

        thread(name = "haven-hairpin-mic", isDaemon = true) {
            val buf = ByteArray(FRAME_BYTES)
            while (capturing.get()) {
                val n = runCatching { rec.read(buf, 0, FRAME_BYTES) }.getOrDefault(-1)
                if (n <= 0) { if (n < 0) break else continue }
                val payload = if (n == FRAME_BYTES) buf.copyOf() else buf.copyOf(n)
                synchronized(CallMediaBridge) {
                    if (activePeers.isNotEmpty()) {
                        audioSeq = (audioSeq + 1) and 0xFFFF
                        val frame = pack(TYPE_AUDIO, audioSeq, 0, payload)
                        activePeers.forEach { CallHairpin.send(it, frame) }
                    }
                }
            }
        }
    }

    private fun stopAudio() {
        capturing.set(false)
        runCatching { recorder?.stop() }; runCatching { recorder?.release() }; recorder = null
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        runCatching { aec?.release() }; aec = null
        runCatching { ns?.release() }; ns = null
        runCatching { agc?.release() }; agc = null
        jitter.reset()
    }

    private fun playAudio(seq: Int, payload: ByteArray) {
        val trk = player ?: return
        // Reorder within a small window so brief loss/jitter doesn't turn into stutter.
        for (ordered in jitter.push(seq, payload)) {
            runCatching { trk.write(ordered, 0, ordered.size) }
        }
    }

    // ---- Video encode (local) -----------------------------------------------------------------

    /**
     * Tap the local camera track and render its frames into the encoder's input Surface.
     *
     * Surface input rather than ByteBuffer input on purpose: the renderer applies the frame's
     * ROTATION on the GPU. Feeding I420 straight to the codec would ship the sensor orientation and
     * the far end would see a sideways call, and rotating 30 frames a second in Kotlin is not free.
     */
    private fun attachLocalVideo(track: VideoTrack, eglBase: EglBase) {
        if (localSink != null) return
        localTrack = track
        val sink = VideoSink { frame ->
            val w = frame.rotatedWidth
            val h = frame.rotatedHeight
            if (w <= 0 || h <= 0) return@VideoSink
            // `onFrame` only retains the buffer and posts to the renderer's own thread, so holding
            // the lock across it is cheap — and it is the only way the renderer cannot be released
            // between the check and the draw.
            synchronized(videoLock) {
                if (ensureEncoder(w, h, eglBase)) encoderRenderer?.onFrame(frame)
            }
        }
        track.addSink(sink)
        localSink = sink
    }

    private fun detachLocalVideo() {
        // Drop the sink FIRST and outside the lock: removeSink blocks until any in-flight delivery
        // returns, and that delivery is itself waiting on videoLock — taking the lock first would
        // deadlock hangup against the capture thread.
        localSink?.let { s -> runCatching { localTrack?.removeSink(s) } }
        localSink = null; localTrack = null
        synchronized(videoLock) {
            encoderDraining.set(false)   // stop the drain thread before the codec goes
            runCatching { encoderRenderer?.release() }; encoderRenderer = null
            runCatching { encoder?.stop() }; runCatching { encoder?.release() }; encoder = null
            runCatching { encoderSurface?.release() }; encoderSurface = null
            encoderSize = null; encoderCsd = null
        }
    }

    /** Create (or recreate on a size change) the H.264 encoder. Returns true when usable.
     *  MUST be called holding [videoLock] — it mutates the encoder/renderer/surface trio. */
    private fun ensureEncoder(width: Int, height: Int, eglBase: EglBase): Boolean {
        // Even dimensions only — H.264 4:2:0 cannot represent an odd width/height.
        val w = width and 1.inv()
        val h = height and 1.inv()
        if (w <= 0 || h <= 0) return false
        encoderSize?.let { if (it.first == w && it.second == h) return encoder != null }
        // Size changed (or first frame): rebuild.
        runCatching { encoderRenderer?.release() }; encoderRenderer = null
        runCatching { encoder?.stop() }; runCatching { encoder?.release() }; encoder = null
        runCatching { encoderSurface?.release() }; encoderSurface = null
        encoderCsd = null

        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            // Two seconds, matching Apple's 60-frame max keyframe interval at 30 fps. A relayed peer
            // that joins late (or drops a keyframe) recovers within that window.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // Apple's formula, so the two platforms look alike on the same link: ~0.11 bits per
            // pixel per frame at 30 fps, clamped so we never flood a WebSocket riding a tunnel.
            val target = (w.toDouble() * h * 30.0 * 0.11).coerceIn(600_000.0, 2_500_000.0)
            setInteger(MediaFormat.KEY_BIT_RATE, target.toInt())
            setInteger(MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            // High profile, not Baseline — Baseline has no CABAC and no 8x8 transform, so at the same
            // bitrate it looks visibly softer. Best-effort: some encoders reject the key outright.
            runCatching {
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
                setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
            }
        }
        val codec = runCatching {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also {
                it.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
        }.getOrElse { e ->
            Log.w(TAG, "H.264 encoder unavailable (${e.message}) — relayed call is audio-only")
            return false
        }
        val surface = runCatching { codec.createInputSurface() }.getOrNull() ?: run {
            runCatching { codec.release() }
            return false
        }
        runCatching { codec.start() }.onFailure {
            runCatching { surface.release() }; runCatching { codec.release() }
            return false
        }
        val renderer = EglRenderer("haven-hairpin-enc").apply {
            init(eglBase.eglBaseContext, EglBase.CONFIG_RECORDABLE, GlRectDrawer())
            createEglSurface(surface)
            // Scale/crop to fill the encoder surface exactly; the codec has a fixed frame size.
            setLayoutAspectRatio(w.toFloat() / h.toFloat())
        }
        encoder = codec; encoderSurface = surface; encoderRenderer = renderer
        encoderSize = w to h
        startEncoderDrain(codec)
        Log.i(TAG, "hairpin video encoder ${w}x$h up")
        return true
    }

    /** Pull encoded Annex-B frames off the codec and ship them. One thread per encoder instance. */
    private fun startEncoderDrain(codec: MediaCodec) {
        if (!encoderDraining.compareAndSet(false, true)) return
        thread(name = "haven-hairpin-enc", isDaemon = true) {
            val info = MediaCodec.BufferInfo()
            try {
                while (encoderDraining.get() && encoder === codec) {
                    // A throw here means the codec was released underneath us — stop, don't spin.
                    val idx = runCatching { codec.dequeueOutputBuffer(info, 20_000) }
                        .getOrElse { -0xBAD }
                    if (idx == -0xBAD) break
                    if (idx < 0) continue
                    val out: ByteBuffer? = runCatching { codec.getOutputBuffer(idx) }.getOrNull()
                    if (out != null && info.size > 0) {
                        val bytes = ByteArray(info.size)
                        out.position(info.offset); out.limit(info.offset + info.size)
                        out.get(bytes)
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            // SPS/PPS. Held and prepended to every keyframe so a decoder that joins
                            // (or resyncs) mid-call can start cold — Apple does the same.
                            encoderCsd = bytes
                        } else {
                            val isKey = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            val payload = if (isKey) (encoderCsd ?: ByteArray(0)) + bytes else bytes
                            synchronized(CallMediaBridge) {
                                if (activePeers.isNotEmpty()) {
                                    videoSeq = (videoSeq + 1) and 0xFFFF
                                    val frame = pack(
                                        if (isKey) TYPE_VIDEO_KEY else TYPE_VIDEO_DELTA,
                                        videoSeq, 0, payload)
                                    activePeers.forEach { CallHairpin.send(it, frame) }
                                }
                            }
                        }
                    }
                    runCatching { codec.releaseOutputBuffer(idx, false) }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            } finally {
                encoderDraining.set(false)
            }
        }
    }

    // ---- Inbound ------------------------------------------------------------------------------

    private fun ingest(remote: String, frame: ByteArray) {
        val parsed = unpack(frame) ?: return
        val (type, seq, payload) = parsed
        synchronized(CallMediaBridge) {
            if (!activePeers.contains(remote)) return
            lastInboundAt[remote] = System.currentTimeMillis()
        }
        when (type) {
            TYPE_AUDIO -> playAudio(seq, payload)
            TYPE_VIDEO_KEY, TYPE_VIDEO_DELTA -> decodeRemote(remote, payload, type == TYPE_VIDEO_KEY)
        }
    }

    /**
     * Feed one Annex-B access unit to this peer's decoder. Deltas before the first keyframe are
     * dropped: a decoder with no SPS/PPS cannot start, and handing it a delta first produces a
     * stream of errors rather than a picture.
     */
    private fun decodeRemote(remote: String, annexB: ByteArray, isKey: Boolean) {
        // Whole body under [videoLock]: this runs on the WebSocket thread while hangup releases the
        // decoder from another, and submitting to a released MediaCodec is a native crash. Lock
        // ORDER is always monitor → videoLock (see `ingest`, `deactivate`), never the reverse.
        synchronized(videoLock) {
            val rv = remoteVideo[remote] ?: return
            if (!isKey && awaitingKeyframe.contains(remote)) return
            if (isKey) awaitingKeyframe.remove(remote)
            val codec = rv.decoder
            val idx = runCatching { codec.dequeueInputBuffer(10_000) }.getOrDefault(-1)
            if (idx < 0) return
            val buf = runCatching { codec.getInputBuffer(idx) }.getOrNull() ?: return
            buf.clear()
            if (buf.capacity() < annexB.size) return
            buf.put(annexB)
            runCatching {
                codec.queueInputBuffer(idx, 0, annexB.size, System.nanoTime() / 1000, 0)
            }
        }
    }

    /**
     * Stand up a decoder for [remote] whose output Surface is driven by a [SurfaceTextureHelper], so
     * every decoded frame arrives as a WebRTC [org.webrtc.VideoFrame] with a texture buffer and can
     * be pushed straight into a [VideoSource]. The resulting track goes into the same map the call
     * UI already renders, so relayed video appears with no view changes.
     */
    private fun ensureRemoteVideo(remote: String, eglBase: EglBase, factory: PeerConnectionFactory) {
        synchronized(videoLock) { if (remoteVideo.containsKey(remote)) return }
        val helper = runCatching {
            SurfaceTextureHelper.create("haven-hairpin-dec-${remote.take(6)}", eglBase.eglBaseContext)
        }.getOrNull() ?: return
        val source = runCatching { factory.createVideoSource(false) }.getOrNull() ?: run {
            helper.dispose(); return
        }
        val track = runCatching {
            factory.createVideoTrack("hairpin-$remote", source)
        }.getOrNull() ?: run { helper.dispose(); return }

        val surface = Surface(helper.surfaceTexture)
        // 640x480 is only the decoder's initial hint — MediaCodec reconfigures itself from the SPS
        // in the first keyframe, so the real size follows whatever the sender is encoding.
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 640, 480)
        val codec = runCatching {
            MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also {
                it.configure(fmt, surface, null, 0)
                it.start()
            }
        }.getOrElse { e ->
            Log.w(TAG, "H.264 decoder unavailable for ${remote.take(8)} (${e.message})")
            runCatching { surface.release() }; helper.dispose()
            return
        }

        helper.startListening { videoFrame -> source.capturerObserver.onFrameCaptured(videoFrame) }
        source.capturerObserver.onCapturerStarted(true)
        synchronized(videoLock) {
            remoteVideo[remote] = RemoteVideo(codec, helper, surface, source, track)
            awaitingKeyframe.add(remote)
        }
        startDecoderDrain(remote, codec)
        CallManager.adoptHairpinRemoteVideo(remote, track)
        Log.i(TAG, "hairpin video decoder up for ${remote.take(8)}")
    }

    /** Release decoded frames to the Surface so the texture helper emits them as VideoFrames. */
    private fun startDecoderDrain(remote: String, codec: MediaCodec) {
        thread(name = "haven-hairpin-dec", isDaemon = true) {
            val info = MediaCodec.BufferInfo()
            while (true) {
                val alive = synchronized(videoLock) { remoteVideo[remote]?.decoder === codec }
                if (!alive) break
                // A throw here means the codec was released underneath us — stop, don't spin.
                val idx = runCatching { codec.dequeueOutputBuffer(info, 20_000) }.getOrElse { -0xBAD }
                if (idx == -0xBAD) break
                if (idx < 0) continue
                // render = true → the frame goes to the Surface, and the texture helper turns it
                // into a VideoFrame on the EGL thread.
                runCatching { codec.releaseOutputBuffer(idx, true) }
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        }
    }

    private fun tearDownRemoteVideo(remote: String) {
        val rv = synchronized(videoLock) {
            awaitingKeyframe.remove(remote)
            remoteVideo.remove(remote)
        } ?: return
        runCatching { rv.decoder.stop() }; runCatching { rv.decoder.release() }
        runCatching { rv.helper.stopListening() }; runCatching { rv.helper.dispose() }
        runCatching { rv.surface.release() }
        runCatching { rv.source.capturerObserver.onCapturerStopped() }
        CallManager.dropHairpinRemoteVideo(remote)
    }

    // ---- Wire format --------------------------------------------------------------------------

    private fun pack(type: Byte, seq: Int, ptsMs: Int, payload: ByteArray): ByteArray =
        HairpinFrame.pack(type, seq, ptsMs, payload)

    private fun unpack(d: ByteArray): Triple<Byte, Int, ByteArray>? = HairpinFrame.unpack(d)

    /**
     * Reorders audio frames within a small window and paces them out, so brief loss/jitter on the
     * WebSocket doesn't turn into stutter. Deliberately shallow (~60 ms) — a voice call values low
     * latency over gap-free playout. Mirrors Apple's `JitterBuffer`.
     */
    private class JitterBuffer {
        private val pending = HashMap<Int, ByteArray>()
        private var next: Int? = null
        private val depth = 3

        @Synchronized
        fun reset() { pending.clear(); next = null }

        @Synchronized
        fun push(seq: Int, payload: ByteArray): List<ByteArray> {
            pending[seq] = payload
            if (next == null && pending.size >= depth) next = pending.keys.min()
            val out = ArrayList<ByteArray>()
            while (true) {
                val n = next ?: break
                val hit = pending.remove(n) ?: break
                out.add(hit)
                next = (n + 1) and 0xFFFF
            }
            // A gap that never fills would stall playout forever — once we are holding more than the
            // window, skip ahead to the oldest frame we actually have.
            if (out.isEmpty() && pending.size > depth * 2) {
                next = pending.keys.min()
            }
            return out
        }
    }
}
