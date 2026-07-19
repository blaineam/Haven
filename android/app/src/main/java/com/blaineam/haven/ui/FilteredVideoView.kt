package com.blaineam.haven.ui

import android.content.Context
import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.util.Log
import android.view.Surface
import com.blaineam.haven.core.FilterShader
import com.blaineam.haven.core.FilterSpec
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * A live, filter-applied VIDEO preview: a [MediaPlayer] renders the clip into a SurfaceTexture, and
 * each frame is drawn through the SAME OES grading shader the camera/photo/transcode paths use — so
 * the editor shows the filter on the moving video in real time (the true live preview), autoplaying
 * and looping with no playback chrome. The same filter is baked into the file on share via the
 * MediaCodec transcode, so preview and output match exactly.
 */
class FilteredVideoView(context: Context) : GLSurfaceView(context) {
    private val renderer = VidRenderer()
    private var player: MediaPlayer? = null
    @Volatile private var file: File? = null
    /** Silent by default: the clip only gets the speaker once the composer says nothing else wants it
     *  (see [setMuted]). Two audio sources over one preview just interrupt each other. */
    @Volatile private var muted = true

    init {
        setEGLContextClientVersion(2)
        setRenderer(renderer)
        renderMode = RENDERMODE_WHEN_DIRTY
    }

    /** Start playing [f] through the current filter. Safe to call before the GL surface exists. */
    fun play(f: File) { file = f; renderer.maybeStart() }

    /** Swap the live filter; rebuilds the OES program on the GL thread. */
    fun setFilter(spec: FilterSpec) = queueEvent { renderer.setSpec(spec) }

    /** Mute/unmute the clip's own audio live. The composer mutes it while a song is attached (the song
     *  is what the viewer will hear) and restores it when the song is removed — without rebuilding the
     *  player, so the clip keeps looping through the change instead of restarting. */
    fun setMuted(m: Boolean) {
        muted = m
        runCatching { player?.setVolume(if (m) 0f else 1f, if (m) 0f else 1f) }
    }

    /** Jump the loop back to its FIRST FRAME, so it re-runs in step with a song that just changed.
     *
     *  A song picked while the loop is already several seconds in previews against an arbitrary
     *  moment of the clip — so the pairing the author approves is not the one that ships. Restarting
     *  both together is what makes the preview honest. Distinct from [setMuted], which deliberately
     *  does NOT restart: attaching a song both mutes AND restarts, but removing one should only
     *  unmute. */
    fun restart() {
        runCatching { player?.seekTo(0); player?.start() }
    }

    fun release() {
        runCatching { player?.stop(); player?.release() }
        player = null
    }

    override fun onDetachedFromWindow() { release(); super.onDetachedFromWindow() }

    private inner class VidRenderer : Renderer, SurfaceTexture.OnFrameAvailableListener {
        private var program = 0
        private var oesTex = 0
        private var surfaceTexture: SurfaceTexture? = null
        private val texMatrix = FloatArray(16)
        private var pendingSpec: FilterSpec = FilterSpec()
        private var builtSpec: FilterSpec? = null
        private var surfaceReady = false

        private val quad: FloatBuffer = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder())
            .asFloatBuffer().apply {
                put(floatArrayOf(-1f, -1f, 0f, 0f, 1f, -1f, 1f, 0f, -1f, 1f, 0f, 1f, 1f, 1f, 1f, 1f)); position(0)
            }

        fun setSpec(spec: FilterSpec) { pendingSpec = spec }

        /** Once both the GL surface and a file exist, build + start the player (on the main thread). */
        fun maybeStart() = post {
            val st = surfaceTexture ?: return@post
            val f = file ?: return@post
            if (player != null) return@post
            runCatching {
                player = MediaPlayer().apply {
                    setSurface(Surface(st))
                    setDataSource(f.absolutePath)
                    isLooping = true
                    setVolume(if (muted) 0f else 1f, if (muted) 0f else 1f)
                    setOnPreparedListener { it.start() }
                    prepareAsync()
                }
            }.onFailure { Log.e("FilteredVideoView", "player start failed", it) }
        }

        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            val tex = IntArray(1); GLES20.glGenTextures(1, tex, 0)
            oesTex = tex[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            buildProgram(pendingSpec)
            val st = SurfaceTexture(oesTex)
            st.setOnFrameAvailableListener(this)
            surfaceTexture = st
            surfaceReady = true
            maybeStart()
        }

        override fun onFrameAvailable(st: SurfaceTexture?) = requestRender()
        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) = GLES20.glViewport(0, 0, width, height)

        override fun onDrawFrame(gl: GL10?) {
            val st = surfaceTexture ?: return
            if (pendingSpec != builtSpec) buildProgram(pendingSpec)
            runCatching { st.updateTexImage(); st.getTransformMatrix(texMatrix) }.onFailure { return }
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "sTexture"), 0)
            GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTexMatrix"), 1, false, texMatrix, 0)
            val aPos = GLES20.glGetAttribLocation(program, "aPosition")
            val aTex = GLES20.glGetAttribLocation(program, "aTextureCoord")
            quad.position(0); GLES20.glEnableVertexAttribArray(aPos)
            GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
            quad.position(2); GLES20.glEnableVertexAttribArray(aTex)
            GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        }

        private fun buildProgram(spec: FilterSpec) {
            if (program != 0) GLES20.glDeleteProgram(program)
            val v = compile(GLES20.GL_VERTEX_SHADER, FilterShader.CAMERA_VERTEX)
            val f = compile(GLES20.GL_FRAGMENT_SHADER, FilterShader.fragmentForOes(spec))
            program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program, v); GLES20.glAttachShader(program, f); GLES20.glLinkProgram(program)
            GLES20.glDeleteShader(v); GLES20.glDeleteShader(f)
            Matrix.setIdentityM(texMatrix, 0)
            builtSpec = spec
        }

        private fun compile(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src); GLES20.glCompileShader(s)
            val ok = IntArray(1); GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) Log.e("FilteredVideoView", "compile: ${GLES20.glGetShaderInfoLog(s)}")
            return s
        }
    }
}
