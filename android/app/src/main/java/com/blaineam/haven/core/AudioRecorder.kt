package com.blaineam.haven.core

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import java.io.File

/**
 * Records a short voice message to an m4a/AAC temp file (parity with iOS AudioRecorder). The bytes
 * are treated like any other media — sealed E2E and sent as an `aud_` ref. Needs RECORD_AUDIO.
 */
class AudioRecorder(private val context: Context) {
    private var recorder: MediaRecorder? = null
    var outputFile: File? = null
        private set

    fun start() {
        val f = File(context.cacheDir, "voice_${System.nanoTime()}.m4a")
        outputFile = f
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context)
        else @Suppress("DEPRECATION") MediaRecorder()
        r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        // Mono, explicitly — a voice note upmixed to stereo is twice the bytes for no information.
        // Apple's standalone-audio ceiling is MediaTargets.STANDALONE_AUDIO_BITRATE (96k) for FILES
        // shared in; this recorder is mono speech and already sits below it, so it is NOT raised to
        // meet the target — that would make every voice note bigger to hit a number.
        r.setAudioChannels(1)
        r.setAudioSamplingRate(MediaTargets.AUDIO_SAMPLE_RATE)
        r.setAudioEncodingBitRate(MediaTargets.VOICE_NOTE_BITRATE)
        r.setOutputFile(f.absolutePath)
        runCatching { r.prepare(); r.start() }
        recorder = r
    }

    /** Stop + return the recorded file (or null on failure / too-short clip). */
    fun stop(): File? {
        val r = recorder ?: return null
        recorder = null
        runCatching { r.stop() }
        runCatching { r.release() }
        val f = outputFile
        return if (f != null && f.exists() && f.length() > 0) f else null
    }

    fun cancel() {
        runCatching { recorder?.stop() }
        runCatching { recorder?.release() }
        recorder = null
        outputFile?.delete()
        outputFile = null
    }
}
